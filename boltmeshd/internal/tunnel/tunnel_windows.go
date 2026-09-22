//go:build windows

package tunnel

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"

	"boltmeshd/internal/config"
	"boltmeshd/internal/protocol"
)

const (
	// wireguardSvcExe is the bundled WireGuard-for-Windows tunnel service
	// host. It performs every adapter/Wintun/address/route/DNS action from
	// the wg-quick config file; the daemon only creates and starts the
	// service that runs it. The client can never influence the binary path,
	// which is what keeps a LocalSystem service from becoming an arbitrary
	// code-execution primitive.
	wireguardSvcExe = "wireguard_svc.exe"
)

// DefaultConfigDir is the directory holding the privileged wg-quick config.
// ProgramData is machine-wide and SYSTEM-owned, matching the daemon's
// ownership of the config on Linux.
var DefaultConfigDir = defaultConfigDir()

func defaultConfigDir() string {
	if base := os.Getenv("ProgramData"); base != "" {
		return filepath.Join(base, "BoltMesh")
	}
	return `C:\ProgramData\BoltMesh`
}

// tunnelService is the seam over the Windows Service Control Manager. The
// real implementation lives in service_windows.go; tests substitute a fake.
type tunnelService interface {
	// start creates the tunnel service (if absent) pointing at exe+args and
	// starts it, waiting until it is running. A stale running service is
	// stopped first so the caller's config file is the one read.
	start(ctx context.Context, exe string, args []string) error
	// stop stops the tunnel service, leaving it registered for reuse.
	// Idempotent: a missing or already-stopped service is success.
	stop(ctx context.Context) error
	// stage reports the OS-level tunnel stage (protocol.Stage*).
	stage(ctx context.Context) (string, error)
}

// deviceReader reads the live peer table of the tunnel adapter.
type deviceReader interface {
	read(ctx context.Context, iface string) ([]peer, error)
}

// Manager owns the Windows tunnel service lifecycle. Construct with
// [NewManager]; tests replace the unexported seams.
type Manager struct {
	iface string
	dir   string

	// mu serializes up/down. TryLock (not Lock) is deliberate: a second
	// concurrent request gets `unavailable` immediately instead of piling up
	// behind a slow service start.
	mu   sync.Mutex
	busy atomic.Bool

	service tunnelService
	device  deviceReader
	exeDir  func() (string, error)
}

// NewManager returns a Manager for iface storing its config in dir.
func NewManager(dir, iface string) *Manager {
	return &Manager{
		iface:   iface,
		dir:     dir,
		service: newWindowsService(iface),
		device:  newWireGuardReader(),
		exeDir:  executableDir,
	}
}

// Up validates the config, writes it to the protected path, and starts the
// tunnel service. Any existing tunnel is torn down first so the requested
// config is always the one applied.
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

	exePath, err := m.serviceExePath()
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(m.dir, 0o755); err != nil {
		return nil, &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("create config dir: %w", err)}
	}
	if err := os.WriteFile(m.configPath(), []byte(wgQuickConfig), 0o600); err != nil {
		return nil, &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("write config: %w", err)}
	}

	// Tear down any running tunnel so the restarted service reads the file
	// just written (the config path is fixed, so a live service would
	// otherwise keep the previous contents).
	if err := m.service.stop(ctx); err != nil {
		return nil, &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("stop tunnel service: %w", err)}
	}
	if err := m.service.start(ctx, exePath, []string{"-service", "-config-file=" + m.configPath()}); err != nil {
		_ = os.Remove(m.configPath())
		return nil, &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("start tunnel service: %w", err)}
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
	// makes Status report `connecting`. During a down the service's own
	// presence is the right answer.
	if err := m.service.stop(ctx); err != nil {
		return nil, &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("stop tunnel service: %w", err)}
	}
	_ = os.Remove(m.configPath())
	return m.Status(), nil
}

// Status reports the OS view. Reads never fail the request: an unreadable or
// absent service resolves to the disconnected stage, which the client treats
// as "unknown", never as proof of death. A running service with unreadable
// counters still reports up, so a wedged device read cannot masquerade as a
// dead tunnel.
func (m *Manager) Status() *protocol.Status {
	st := &protocol.Status{Interface: m.iface, Stage: protocol.StageDisconnected}
	stage, err := m.service.stage(context.Background())
	if err != nil {
		if m.busy.Load() {
			st.Stage = protocol.StageConnecting
		}
		return st
	}
	switch stage {
	case protocol.StageConnected:
		st.Up = true
		st.Stage = protocol.StageConnected
	case protocol.StageConnecting:
		st.Stage = protocol.StageConnecting
		return st
	default:
		if m.busy.Load() {
			st.Stage = protocol.StageConnecting
		}
		return st
	}

	peers, err := m.device.read(context.Background(), m.iface)
	if err != nil {
		// Up, but handshake/counters unknown: keep reporting up.
		return st
	}
	applyPeers(st, peers)
	return st
}

func (m *Manager) configPath() string {
	return filepath.Join(m.dir, m.iface+".conf")
}

func (m *Manager) serviceExePath() (string, error) {
	dir, err := m.exeDir()
	if err != nil {
		return "", &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("locate helper directory: %w", err)}
	}
	return filepath.Join(dir, wireguardSvcExe), nil
}

func executableDir() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.Dir(exe), nil
}
