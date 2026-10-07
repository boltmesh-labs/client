//go:build windows

package tunnel

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	awgtun "github.com/amnezia-vpn/amneziawg-go/v3/tun"
	"golang.org/x/sys/windows"

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

	// cleanupTimeout bounds the recovery pass after a failed up. It must not
	// inherit an already-canceled request context, and the manager gate stays
	// held throughout so a retry cannot race the recovery.
	cleanupTimeout = 5 * time.Second
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

	// Stream transport: the in-process bridge carrying the tunnel's datagrams,
	// and the host routes pinned so its own egress stays outside the tunnel. The
	// bridge is not a privilege boundary — it binds a loopback port and dials
	// out — but the daemon owns its lifecycle because the tunnel's lifecycle is
	// the daemon's, and only the daemon can pin its egress. transport is nil
	// when none is live; routes is the seam over the IP forward table, replaced
	// by tests so sequencing is checkable without touching this machine's
	// routing. resolveHost is the pre-tunnel resolver, for the same reason the
	// Linux backend resolves through the physical one: the transport comes up
	// before any tunnel DNS state exists.
	transport       *liveTransport
	routes          windowsRoutes
	resolveHost     func(ctx context.Context, host string) ([]net.IP, error)
	streamTransport func(spec *protocol.TransportSpec, onSession func(bool, error)) (streamClient, error)

	// Userspace AmneziaWG data plane (obfuscated configs). mu guards the fields below —
	// the AWG device, its routes, and the stream transport's session state
	// (streamSession) — so the status path, which reads them without the up/down gate,
	// never races a lifecycle mutation. A nil awgDev means no userspace tunnel is live.
	// Unlike the kernel path, this data plane dies with the daemon process — closing the
	// Wintun handle deletes the adapter, and with it the address, the routes and the DNS
	// settings — so a stale config file after a restart is the only state that can
	// linger, plus the underlay host routes, which live on the physical interface (see
	// teardownObfuscated).
	mu                sync.Mutex
	awgDev            awgDevice
	awgEndpointRoutes []string
	// streamSession is the stream transport's TLS session state, a tri-state: nil when
	// no stream transport is live (the status then omits the field, which is how a
	// native/awg rung — or a daemon predating the field — reports "not a stream
	// tunnel"), and a pointer to the live session otherwise — false while the bridge's
	// session is still establishing, true once it has completed. The pointer is replaced
	// rather than mutated, so a status snapshot owns its own value. noteStreamSession
	// runs on the transport's own goroutine, and downTransport clears it before it
	// drops the transport, so a stale "established" can never outlive the transport
	// that produced it.
	streamSession *bool
	makeAwgTun    func(name string, mtu int) (awgtun.Device, error)
	makeAwgDevice func(awgtun.Device) (awgDevice, error)
	// loadWintun is the driver pin, behind a seam because the real one writes to
	// System32 and needs elevation — which is not a property the behaviour suite can be
	// run under. The pin has its own suite, including the elevated integration tests.
	loadWintun func() (windows.Handle, error)
	// netIf is the seam over the address and DNS entry points, replaced by tests so the
	// obfuscated bring-up can be exercised without reconfiguring this machine.
	netIf windowsNetIf
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
		routes:      liveWindowsRoutes{},
		resolveHost: func(ctx context.Context, host string) ([]net.IP, error) {
			return net.DefaultResolver.LookupIP(ctx, "ip", host)
		},
		streamTransport: newStreamClient,
		makeAwgTun:      awgtun.CreateTUN,
		makeAwgDevice:   newAwgDevice,
		loadWintun:      loadWintunDLL,
		netIf:           liveWindowsNetIf{},
	}
}

// Up validates the config, writes it to the protected path, and starts the
// tunnel service. Any existing tunnel is torn down first so the requested
// config is always the one applied.
func (m *Manager) Up(ctx context.Context, wgQuickConfig string, transport *protocol.TransportSpec) (*protocol.Status, error) {
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

	// An obfuscated config never reaches the WireGuard service: the kernel tunnel
	// driver has no concept of the AmneziaWG directives, and handing it a config
	// carrying them would only fail at start time. It runs the userspace AmneziaWG
	// device over a Wintun adapter instead — see tunnel_windows_awg.go.
	//
	// The dispatch has to come before anything the service needs. Locating
	// wireguard_svc.exe would fail the whole operation on a machine that has no
	// reason to have it, and a request the obfuscated path can serve is not a request
	// that depends on it.
	if awgObfuscated(parseWgQuick(wgQuickConfig)) {
		return m.upObfuscated(ctx, wgQuickConfig, transport)
	}

	// An obfuscated tunnel that is already up must be torn down before a native one
	// takes the interface name. Its Wintun adapter is a device of its own, separate from
	// the WireGuard service's, so neither would notice the other and both would go on
	// answering for the same interface. A lingering obfuscated config counts even with
	// no live device, for the reason Down's own dispatch gives.
	if m.awgLive() || m.staleObfuscatedConfig() {
		if err := m.teardownObfuscated(ctx); err != nil {
			return nil, err
		}
	}

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

	// A live transport is torn down before its config is replaced, for the same
	// reason the service is: the pinned routes outlive the daemon, so a retry
	// must not leave the previous tunnel's pins installed underneath the new
	// one. It comes before the service stop because the transport carries the
	// tunnel, not the other way round.
	if err := m.downTransport(ctx); err != nil {
		return nil, err
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

	// The transport and its bypass route come up *before* the service starts:
	// from the moment the tunnel adapter installs its default route, the
	// transport's own egress must already be pinned through the physical path
	// or its packets (and the WireGuard datagrams they carry) would loop back
	// into the tunnel. Windows matches the longest prefix first, so the /32 is
	// what keeps them out — but it has to exist first.
	if transport != nil {
		if err := m.bringUpTransport(ctx, transport); err != nil {
			cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), cleanupTimeout)
			defer cancel()
			// Keep the transport's own code: a spec or credential the client
			// got wrong is a bad config, not a daemon fault, and the client
			// decides what to do about each.
			code := transportErrorCode(err)
			if cleanupErr := m.downTransport(cleanupCtx); cleanupErr != nil {
				return nil, &protocol.OpError{
					Code: code,
					Err:  fmt.Errorf("stream transport: %w; cleanup failed: %w", err, cleanupErr),
				}
			}
			_ = os.Remove(m.configPath())
			return nil, &protocol.OpError{Code: code, Err: fmt.Errorf("stream transport: %w", err)}
		}
	}

	if err := m.service.start(ctx, exePath, []string{"-service", "-config-file=" + m.configPath()}); err != nil {
		// The service may have installed the adapter and its routes before
		// reporting failure, so the recovery stops the transport and sweeps its
		// pins rather than only removing the config file. The manager gate stays
		// held while it runs, so a retry cannot race it.
		cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), cleanupTimeout)
		defer cancel()
		if cleanupErr := m.downTransport(cleanupCtx); cleanupErr != nil {
			return nil, &protocol.OpError{
				Code: protocol.CodeInternal,
				Err:  fmt.Errorf("start tunnel service: %w; cleanup failed: %w", err, cleanupErr),
			}
		}
		_ = os.Remove(m.configPath())
		return nil, &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("start tunnel service: %w", err)}
	}
	return m.readServiceStatus(ctx)
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
	//
	// The userspace data plane is torn down by its own path first. A lingering
	// obfuscated config counts even with no live device: after a daemon restart
	// the adapter is gone, but the underlay host routes are not — they live on the
	// physical interface — and the config is the only record of them.
	if m.awgLive() || m.staleObfuscatedConfig() {
		if err := m.teardownObfuscated(ctx); err != nil {
			return nil, err
		}
		return m.readServiceStatus(ctx)
	}

	if err := m.service.stop(ctx); err != nil {
		return nil, &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("stop tunnel service: %w", err)}
	}
	// The transport goes down with the tunnel it carries, and its pinned routes
	// with it. This runs even when no transport is live in memory, because a
	// pin record left by a previous run is still a route installed.
	if err := m.downTransport(ctx); err != nil {
		return nil, err
	}
	_ = os.Remove(m.configPath())
	return m.readServiceStatus(ctx)
}

// Uninstall removes all state owned by the Windows tunnel. Callers must first
// quiesce the daemon so it cannot recreate the service or config. The tunnel
// must be stopped before its config is deleted, and the service registration
// must be gone before this method returns. That ordering is important during
// an upgrade: the old WireGuard process may still hold the config file open,
// and a service marked for deletion may otherwise outlive the helper
// executable.
func (m *Manager) Uninstall(ctx context.Context) error {
	// A live or stale userspace tunnel goes first: its teardown is the only thing that
	// sweeps the endpoint's underlay host routes, and those live on the physical
	// interface where they would outlive the client.
	if m.awgLive() || m.staleObfuscatedConfig() {
		if err := m.teardownObfuscated(ctx); err != nil {
			return fmt.Errorf("remove obfuscated tunnel: %w", err)
		}
	}
	// The transport goes next: its bypass routes point at the physical path,
	// and leaving them installed would keep exempting the node from every
	// tunnel on a machine that no longer has this client installed.
	if err := m.downTransport(ctx); err != nil {
		return fmt.Errorf("remove stream transport: %w", err)
	}
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
	// The record goes with them, or a later install would sweep pins it has no
	// memory of having installed.
	_ = os.Remove(m.transportPinPath())
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

// Status reports the OS view. An in-flight up takes precedence over SCM and
// device state so callers never observe an old or partially configured service
// as connected. A service that is not installed is disconnected, but any other
// stage-read failure is returned so the client treats it as unknown rather
// than as proof of death.
func (m *Manager) Status(ctx context.Context) (*protocol.Status, error) {
	if err := ctx.Err(); err != nil {
		return nil, statusReadError(err)
	}
	if m.busy.Load() {
		return &protocol.Status{
			Interface: m.iface,
			Stage:     protocol.StageConnecting,
		}, nil
	}
	return m.readServiceStatus(ctx)
}

// readServiceStatus bypasses the in-flight marker for Up and Down, whose
// lifecycle mutation is complete before they obtain their response status.
func (m *Manager) readServiceStatus(ctx context.Context) (*protocol.Status, error) {
	// A live userspace device is the whole truth: there is no service behind it, so
	// asking the Service Control Manager would report a tunnel that is up as one that
	// is not installed.
	if dev := m.liveAwgDevice(); dev != nil {
		return readObfuscatedStatus(ctx, m.iface, dev)
	}
	st := &protocol.Status{Interface: m.iface, Stage: protocol.StageDisconnected}
	stage, err := m.service.stage(ctx)
	if err != nil {
		return nil, &protocol.OpError{
			Code: protocol.CodeInternal,
			Err:  fmt.Errorf("read tunnel service: %w", err),
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, statusReadError(err)
	}
	switch stage {
	case protocol.StageConnected:
		st.Up = true
		st.Stage = protocol.StageConnected
	case protocol.StageConnecting:
		st.Stage = protocol.StageConnecting
		return st, nil
	default:
		return st, nil
	}
	// The stream transport's session state is independent of the
	// peer table read below, so it is reported on every connected
	// return path, including the one where the peer table is
	// unreadable but the tunnel is up.
	st.StreamSession = m.streamSessionState()

	peers, err := m.device.read(ctx, m.iface)
	if err != nil {
		if ctxErr := ctx.Err(); ctxErr != nil {
			return nil, statusReadError(ctxErr)
		}
		// Up, but handshake/counters unknown: keep reporting up.
		return st, nil
	}
	if err := ctx.Err(); err != nil {
		return nil, statusReadError(err)
	}
	applyPeers(st, peers)
	return st, nil
}

// streamSessionState projects the live stream transport's TLS session
// into a status field. It reads only streamSession — never the
// gate-guarded transport pointer — so the status path, which does not
// hold the up/down gate, cannot race a lifecycle mutation. It returns
// nil when no stream transport is live (the field is then omitted,
// which is how a native/awg rung — or a daemon that predates the
// field — reports "not a stream tunnel"), and a fresh pointer to the
// current session state otherwise, so the status owns its own value
// rather than aliasing the manager's.
func (m *Manager) streamSessionState() *bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.streamSession == nil {
		return nil
	}
	up := *m.streamSession
	return &up
}

func statusReadError(err error) error {
	return &protocol.OpError{
		Code: protocol.CodeInternal,
		Err:  fmt.Errorf("read tunnel status: %w", err),
	}
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
