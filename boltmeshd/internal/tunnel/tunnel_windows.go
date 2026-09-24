//go:build windows

package tunnel

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
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
	wireguardDLL    = "wireguard.dll"
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
	// remove stops and deletes the tunnel service, waiting until its
	// registration has disappeared from the Service Control Manager.
	remove(ctx context.Context) error
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

	// gate serializes up/down. A bounded request waits for the current
	// operation (or its cancellation) instead of racing a retry against a
	// service start that may still be mutating tunnel state.
	gate operationGate
	busy atomic.Bool

	service tunnelService
	device  deviceReader
	exeDir  func() (string, error)
	stat    func(string) (os.FileInfo, error)

	// protectDir hardens the privileged config directory, and protectFile
	// hardens each fresh temporary file before its contents are written. Tests
	// replace them with no-ops so a temp dir is never locked down.
	protectDir  func(string) error
	protectFile func(string) error
}

// NewManager returns a Manager for iface storing its config in dir.
func NewManager(dir, iface string) *Manager {
	return &Manager{
		iface:       iface,
		dir:         dir,
		service:     newWindowsService(iface),
		device:      newWireGuardReader(),
		exeDir:      executableDir,
		stat:        os.Stat,
		protectDir:  protectConfigDir,
		protectFile: protectConfigFile,
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

	if !m.gate.acquire(ctx) {
		return nil, &protocol.OpError{
			Code: protocol.CodeUnavailable,
			Err:  operationUnavailable(ctx),
		}
	}
	defer m.gate.release()
	m.busy.Store(true)
	defer m.busy.Store(false)

	exePath, err := m.serviceExePath()
	if err != nil {
		return nil, err
	}
	// The directory is created, owner/DACL hardened, and checked for reparse
	// points before any config bytes are staged. os.MkdirAll/os.WriteFile are
	// deliberately not used on Windows: both can traverse or truncate an
	// object created by an unprivileged user before the daemon runs.
	if err := m.protectDir(m.dir); err != nil {
		return nil, &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("protect config dir: %w", err)}
	}

	// Stop the old service before replacing its fixed config path. A running
	// WireGuard service may hold the old file without delete sharing, which
	// would make an otherwise-correct atomic replacement fail.
	if err := m.service.stop(ctx); err != nil {
		return nil, &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("stop tunnel service: %w", err)}
	}
	if err := writePrivateFile(m.configPath(), []byte(wgQuickConfig), m.protectFile); err != nil {
		return nil, &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("write config: %w", err)}
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
	if !m.gate.acquire(ctx) {
		return nil, &protocol.OpError{
			Code: protocol.CodeUnavailable,
			Err:  operationUnavailable(ctx),
		}
	}
	defer m.gate.release()

	// Deliberately no `busy` here: `busy` means "an up is in flight" and only
	// makes Status report `connecting`. During a down the service's own
	// presence is the right answer.
	if err := m.service.stop(ctx); err != nil {
		return nil, &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("stop tunnel service: %w", err)}
	}
	_ = os.Remove(m.configPath())
	return m.Status(), nil
}

// Uninstall removes all state owned by the Windows tunnel. Callers must first
// quiesce the daemon so it cannot recreate the service or config. The tunnel
// must be stopped before its config is deleted, and the service registration
// must be gone before this method returns. That ordering is important during
// an upgrade: the old WireGuard process may still hold the config file open,
// and a service marked for deletion may otherwise outlive the helper
// executable.
func (m *Manager) Uninstall(ctx context.Context) error {
	// remove is deliberately one destructive operation: it stops the service,
	// waits for the service process to release the config, deletes the
	// registration, and waits until that registration is gone. Only then is it
	// safe to remove the private-key file.
	if err := m.service.remove(ctx); err != nil {
		return fmt.Errorf("remove tunnel service: %w", err)
	}
	if err := removeConfigFile(m.configPath()); err != nil {
		return fmt.Errorf("remove tunnel config: %w", err)
	}
	return nil
}

func removeConfigFile(path string) error {
	if err := rejectReparseFile(path); err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
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
	exe := filepath.Join(dir, wireguardSvcExe)
	if _, err := m.stat(exe); err != nil {
		return "", &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("locate WireGuard tunnel service %q: %w (copy wireguard_svc.exe and wireguard.dll beside boltmeshd.exe)", exe, err)}
	}
	dll := filepath.Join(dir, wireguardDLL)
	if _, err := m.stat(dll); err != nil {
		return "", &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("locate WireGuard runtime %q: %w (copy wireguard_svc.exe and wireguard.dll beside boltmeshd.exe)", dll, err)}
	}
	return exe, nil
}

func executableDir() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.Dir(exe), nil
}
