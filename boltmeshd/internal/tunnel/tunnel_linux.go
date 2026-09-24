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

	wgQuickBinary    = "wg-quick"
	ipBinary         = "ip"
	resolvconfBinary = "resolvconf"
	resolvectlBinary = "resolvectl"
	commandTimeout   = 30 * time.Second
)

// toolDirs are the only directories searched for the privileged tools the
// daemon executes. They are fixed, root-owned system paths on purpose: the
// daemon runs as root, so resolving a bare name through PATH on a manual
// launch would let a caller-influenced PATH (or a stray wg-quick in the
// working directory) execute as root. wg-quick's own child lookups (wg, ip,
// resolvconf) remain PATH-based — that is the tool's behaviour, not ours;
// resolver cleanup below resolves its tools through this fixed list.
var toolDirs = []string{"/usr/sbin", "/usr/bin", "/sbin", "/bin"}

// findTool returns the absolute path of name under [toolDirs], or an error
// when it is not installed there. Tests replace [toolDirs] with a temp dir.
func findTool(name string) (string, error) {
	for _, dir := range toolDirs {
		path := filepath.Join(dir, name)
		if info, err := os.Stat(path); err == nil && !info.IsDir() {
			return path, nil
		}
	}
	return "", fmt.Errorf("%s not found under %v (is wireguard-tools installed?)", name, toolDirs)
}

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
	lookup     func(name string) (string, error)
	linkExists func(name string) bool
	device     func(name string) (*wgtypes.Device, error)
}

// NewManager returns a Manager for iface storing its config in dir.
func NewManager(dir, iface string) *Manager {
	return &Manager{
		iface:      iface,
		dir:        dir,
		run:        runCommand,
		lookup:     findTool,
		linkExists: linkExists,
		device:     queryDevice,
	}
}

// tool resolves a privileged tool against [toolDirs]. Resolution happens per
// operation rather than at construction so a read-only status path never
// requires wireguard-tools to be installed.
func (m *Manager) tool(name string) (string, error) {
	path, err := m.lookup(name)
	if err != nil {
		return "", &protocol.OpError{Code: protocol.CodeInternal, Err: err}
	}
	return path, nil
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

	// Resolve before writing anything: a missing tool must not leave a
	// privileged config behind.
	wgQuick, err := m.tool(wgQuickBinary)
	if err != nil {
		return nil, err
	}
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
	if _, err := m.run(ctx, wgQuick, "up", m.configPath()); err != nil {
		// wg-quick can configure DNS before a later route or configuration
		// step fails. Its failure trap does not reliably remove that DNS
		// state, and deleting the config would prevent a proper down from
		// finding the interface. Keep the config until cleanup has finished.
		// The failed command may have exhausted the request context; give the
		// destructive cleanup its own bounded lifetime.
		cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), commandTimeout)
		defer cancel()
		if cleanupErr := m.cleanup(cleanupCtx, true); cleanupErr != nil {
			return nil, &protocol.OpError{
				Code: protocol.CodeInternal,
				Err:  fmt.Errorf("wg-quick up: %w; cleanup failed: %w", err, cleanupErr),
			}
		}
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
	// A normal down does not need to invoke wg-quick when the link is already
	// absent. The resolver cleanup still runs: deleting a link does not remove
	// a per-interface resolvconf/systemd-resolved entry.
	return m.cleanup(ctx, m.linkExists(m.iface))
}

// cleanup tears down the link and removes its resolver state. attemptDown is
// true when this is recovery after a failed wg-quick up, where the config must
// be offered to wg-quick even if the link has already disappeared.
//
// The config is removed only after all required cleanup has succeeded. Keeping
// it on an incomplete cleanup lets a later down retry the resolver cleanup
// instead of losing the only handle on the interface's state.
func (m *Manager) cleanup(ctx context.Context, attemptDown bool) error {
	linkPresent := m.linkExists(m.iface)
	var cleanupErrs []error

	if attemptDown {
		var downErr error
		wgQuick, err := m.tool(wgQuickBinary)
		if err != nil {
			downErr = err
		} else if _, err := m.run(ctx, wgQuick, "down", m.configPath()); err != nil {
			downErr = err
		}

		// wg-quick can strand a link when its own bookkeeping is gone
		// (missing config or stale state). If it could not tear the link down,
		// remove it directly; addresses and routes die with the link.
		if downErr != nil && linkPresent {
			if !m.linkExists(m.iface) {
				// wg-quick may have removed the link before reporting a
				// bookkeeping/DNS error. Treat that race as a completed link
				// teardown; resolver cleanup below is still required.
				downErr = nil
			} else {
				ip, ipErr := m.tool(ipBinary)
				if ipErr != nil {
					downErr = fmt.Errorf("wg-quick down: %w; locate ip: %w", downErr, ipErr)
				} else if _, delErr := m.run(ctx, ip, "link", "del", m.iface); delErr != nil {
					downErr = fmt.Errorf("wg-quick down: %w; ip link del: %w", downErr, delErr)
				} else {
					// The direct link deletion completed the link teardown even
					// though wg-quick's bookkeeping was stale.
					downErr = nil
				}
			}
		}

		// A down failure is expected when recovery follows a failed up and
		// the link is already gone. In that case resolver cleanup below is
		// still required, but there is no link error to report.
		if downErr != nil && linkPresent {
			cleanupErrs = append(cleanupErrs, downErr)
		}
	}

	if err := m.clearResolverState(ctx); err != nil {
		cleanupErrs = append(cleanupErrs, err)
	}
	if len(cleanupErrs) > 0 {
		return &protocol.OpError{
			Code: protocol.CodeInternal,
			Err:  errors.Join(cleanupErrs...),
		}
	}

	if err := os.Remove(m.configPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return &protocol.OpError{
			Code: protocol.CodeInternal,
			Err:  fmt.Errorf("remove config: %w", err),
		}
	}
	return nil
}

// clearResolverState removes the fixed interface's DNS entry independently of
// wg-quick. wg-quick's unset_dns is best effort (and its failure trap can skip
// it), while resolvconf state is independent of the link's lifetime. The
// systemd-resolved compatibility implementation of resolvconf covers the
// common case; resolvectl is a fallback for installations exposing only the
// native systemd-resolved tool.
func (m *Manager) clearResolverState(ctx context.Context) error {
	// A preceding wg-quick/ip cleanup may have consumed the operation
	// context. DNS removal is the safety-critical part, so give it a fresh
	// bounded context when the original one is already done.
	if ctx.Err() != nil {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(context.WithoutCancel(ctx), commandTimeout)
		defer cancel()
	}

	if path, err := m.lookup(resolvconfBinary); err == nil {
		if _, err := m.run(ctx, path, "-d", m.iface, "-f"); err != nil {
			return &protocol.OpError{
				Code: protocol.CodeInternal,
				Err:  fmt.Errorf("resolvconf cleanup: %w", err),
			}
		}
		return nil
	}

	// Some systemd-resolved installations expose resolvectl without the
	// resolvconf compatibility command. Use it only when resolvconf is not
	// installed; a failing resolvconf command is reported rather than being
	// papered over with a broader per-link revert.
	if path, err := m.lookup(resolvectlBinary); err == nil {
		if _, err := m.run(ctx, path, "revert", m.iface); err != nil {
			return &protocol.OpError{
				Code: protocol.CodeInternal,
				Err:  fmt.Errorf("resolvectl cleanup: %w", err),
			}
		}
		return nil
	}

	// Neither resolver tool is installed, so there is no resolver state for
	// wg-quick to have configured on this system.
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
