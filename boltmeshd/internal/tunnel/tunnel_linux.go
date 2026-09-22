//go:build linux

package tunnel

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.zx2c4.com/wireguard/wgctrl"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"

	"boltmeshd/internal/config"
	"boltmeshd/internal/protocol"
)

const (
	// DefaultConfigDir holds the root-only wg-quick config. /run is a fresh
	// tmpfs each boot, which matches the daemon's stateless ownership of the
	// config.
	DefaultConfigDir = "/run/boltmesh"

	wgQuickBinary  = "wg-quick"
	ipBinary       = "ip"
	commandTimeout = 30 * time.Second
)

type runFunc func(ctx context.Context, name string, args ...string) ([]byte, error)

// Manager brings the interface up/down and reports its state. Construct with
// [NewManager]; tests replace the unexported seams.
type Manager struct {
	iface string
	dir   string

	// mu serializes up/down. TryLock (not Lock) is deliberate: a second
	// concurrent request gets `unavailable` immediately instead of piling up
	// behind a slow wg-quick.
	mu   sync.Mutex
	busy atomic.Bool

	run        runFunc
	linkExists func(name string) bool
	device     func(name string) (*wgtypes.Device, error)
}

// NewManager returns a Manager for iface storing its config in dir.
func NewManager(dir, iface string) *Manager {
	return &Manager{
		iface:      iface,
		dir:        dir,
		run:        runCommand,
		linkExists: linkExists,
		device:     queryDevice,
	}
}

// Up validates the config, writes it to the root-only path, and starts the
// tunnel. An existing tunnel is torn down first so the requested config is
// always the one applied (never two live tunnels).
func (m *Manager) Up(ctx context.Context, wgQuickConfig string) (*protocol.Status, error) {
	// Validate before taking the lock: a malformed config must not consume
	// the privileged operation slot or touch disk.
	if err := config.Validate(wgQuickConfig); err != nil {
		return nil, &protocol.OpError{Code: protocol.CodeBadConfig, Err: err}
	}

	if !m.mu.TryLock() {
		return nil, &protocol.OpError{
			Code: protocol.CodeUnavailable,
			Err:  errors.New("another tunnel operation is already in progress"),
		}
	}
	defer m.mu.Unlock()
	m.busy.Store(true)
	defer m.busy.Store(false)

	if m.linkExists(m.iface) {
		if err := m.down(ctx); err != nil {
			return nil, err
		}
	}
	if err := os.MkdirAll(m.dir, 0o755); err != nil {
		return nil, &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("create config dir: %w", err)}
	}
	if err := os.WriteFile(m.configPath(), []byte(wgQuickConfig), 0o600); err != nil {
		return nil, &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("write config: %w", err)}
	}
	if _, err := m.run(ctx, wgQuickBinary, "up", m.configPath()); err != nil {
		_ = os.Remove(m.configPath())
		return nil, &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("wg-quick up: %w", err)}
	}
	return m.Status(), nil
}

// Down tears the tunnel down. It is idempotent: true means no tunnel is
// running afterwards, including when it was already down.
func (m *Manager) Down(ctx context.Context) (*protocol.Status, error) {
	if !m.mu.TryLock() {
		return nil, &protocol.OpError{
			Code: protocol.CodeUnavailable,
			Err:  errors.New("another tunnel operation is already in progress"),
		}
	}
	defer m.mu.Unlock()

	// Deliberately no `busy` here: `busy` means "an up is in flight" and only
	// makes Status report `connecting`. During a down the device's own
	// presence is the right answer.
	if err := m.down(ctx); err != nil {
		return nil, err
	}
	return m.Status(), nil
}

// Status reports the OS view. Reads never fail the request: an unreadable or
// absent device resolves to the disconnected stage, which the client treats
// as "unknown", never as proof of death.
func (m *Manager) Status() *protocol.Status {
	st := &protocol.Status{Interface: m.iface, Stage: protocol.StageDisconnected}
	dev, err := m.device(m.iface)
	if err != nil {
		if m.busy.Load() {
			st.Stage = protocol.StageConnecting
		}
		return st
	}

	st.Up = true
	st.Stage = protocol.StageConnected
	peers := make([]peer, 0, len(dev.Peers))
	for i := range dev.Peers {
		p := &dev.Peers[i]
		endpoint := ""
		if p.Endpoint != nil {
			endpoint = p.Endpoint.String()
		}
		peers = append(peers, peer{
			publicKey:     p.PublicKey.String(),
			endpoint:      endpoint,
			lastHandshake: p.LastHandshakeTime,
			rxBytes:       p.ReceiveBytes,
			txBytes:       p.TransmitBytes,
		})
	}
	applyPeers(st, peers)
	return st
}

func (m *Manager) down(ctx context.Context) error {
	if !m.linkExists(m.iface) {
		_ = os.Remove(m.configPath())
		return nil
	}
	if _, err := m.run(ctx, wgQuickBinary, "down", m.configPath()); err != nil {
		// wg-quick can strand a link when its own bookkeeping is gone
		// (missing config, stale DNS). Delete the link directly so `down`
		// stays idempotent; addresses and routes die with the link.
		if _, delErr := m.run(ctx, ipBinary, "link", "del", m.iface); delErr != nil {
			return &protocol.OpError{
				Code: protocol.CodeInternal,
				Err:  fmt.Errorf("wg-quick down: %w; ip link del: %w", err, delErr),
			}
		}
	}
	_ = os.Remove(m.configPath())
	return nil
}

func (m *Manager) configPath() string {
	return filepath.Join(m.dir, m.iface+".conf")
}

func runCommand(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		if msg := strings.TrimSpace(string(out)); msg != "" {
			return out, fmt.Errorf("%w: %s", err, msg)
		}
		return out, err
	}
	return out, nil
}

func linkExists(name string) bool {
	_, err := net.InterfaceByName(name)
	return err == nil
}

func queryDevice(name string) (*wgtypes.Device, error) {
	client, err := wgctrl.New()
	if err != nil {
		return nil, err
	}
	defer func() { _ = client.Close() }()
	return client.Device(name)
}
