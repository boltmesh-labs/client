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
	"sync/atomic"
	"syscall"
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

	// commandTimeout bounds the complete lifecycle operation and each
	// privileged tool invocation within it. The server supplies a longer
	// request deadline for bounded failure cleanup; a caller's shorter
	// cancellation deadline still wins. The extra wait bound lets
	// CombinedOutput return even if a descendant outside the process group
	// keeps an output pipe open.
	commandTimeout   = 30 * time.Second
	cleanupTimeout   = 5 * time.Second
	commandWaitDelay = 1 * time.Second
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

	// gate serializes up/down. A bounded request waits for the current
	// operation (or its cancellation) instead of racing a retry against a
	// command that may still be mutating tunnel state.
	gate operationGate
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

// runWithTimeout applies the command budget at the manager boundary too, so
// injected run seams and future backends observe the same deadline as the
// production exec implementation.
func (m *Manager) runWithTimeout(ctx context.Context, name string, args ...string) error {
	commandCtx, cancel := context.WithTimeout(ctx, commandTimeout)
	defer cancel()
	_, err := m.run(commandCtx, name, args...)
	return err
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

	if !m.gate.acquire(ctx) {
		return nil, &protocol.OpError{
			Code: protocol.CodeUnavailable,
			Err:  operationUnavailable(ctx),
		}
	}
	defer m.gate.release()
	m.busy.Store(true)
	defer m.busy.Store(false)

	// Bound the whole lifecycle operation, not just one tool invocation. A
	// retry must not be able to enter while a sequence of down/up commands is
	// still consuming the manager gate.
	operationCtx, cancel := context.WithTimeout(ctx, commandTimeout)
	defer cancel()
	ctx = operationCtx

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
	if err := m.runWithTimeout(ctx, wgQuick, "up", m.configPath()); err != nil {
		// wg-quick can configure DNS before a later route or configuration
		// step fails. Its failure trap does not reliably remove that DNS
		// state, and deleting the config would prevent a proper down from
		// finding the interface. Keep the config until cleanup has finished.
		// A failed/canceled wg-quick may already have changed DNS or created a
		// link. Keep the config until a bounded recovery pass finishes, but do
		// not let that pass inherit an already-canceled request. The manager
		// gate remains held while cleanup runs, so a retry cannot race it.
		cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), cleanupTimeout)
		defer cancel()
		if cleanupErr := m.cleanup(cleanupCtx, true); cleanupErr != nil {
			return nil, &protocol.OpError{
				Code: protocol.CodeInternal,
				Err:  fmt.Errorf("wg-quick up: %w; cleanup failed: %w", err, cleanupErr),
			}
		}
		return nil, &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("wg-quick up: %w", err)}
	}
	return m.readDeviceStatus(ctx)
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

	operationCtx, cancel := context.WithTimeout(ctx, commandTimeout)
	defer cancel()
	ctx = operationCtx

	// Deliberately no `busy` here: `busy` means "an up is in flight" and only
	// makes Status report `connecting`. During a down the device's own
	// presence is the right answer.
	if err := m.down(ctx); err != nil {
		return nil, err
	}
	return m.readDeviceStatus(ctx)
}

// Status reports the OS view. An in-flight up takes precedence over the
// device so callers never observe the old or partially configured tunnel as
// connected. A missing device is disconnected, but any other read failure is
// returned so the client treats it as unknown rather than as proof of death.
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
	return m.readDeviceStatus(ctx)
}

// readDeviceStatus bypasses the in-flight marker for Up and Down, whose
// lifecycle mutation is complete before they obtain their response status.
func (m *Manager) readDeviceStatus(ctx context.Context) (*protocol.Status, error) {
	if err := ctx.Err(); err != nil {
		return nil, statusReadError(err)
	}
	st := &protocol.Status{Interface: m.iface, Stage: protocol.StageDisconnected}
	dev, err := m.device(m.iface)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return st, nil
		}
		return nil, &protocol.OpError{
			Code: protocol.CodeInternal,
			Err:  fmt.Errorf("query device %s: %w", m.iface, err),
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, statusReadError(err)
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
	return st, nil
}

func statusReadError(err error) error {
	return &protocol.OpError{
		Code: protocol.CodeInternal,
		Err:  fmt.Errorf("read tunnel status: %w", err),
	}
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
		} else if err := m.runWithTimeout(ctx, wgQuick, "down", m.configPath()); err != nil {
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
				} else if delErr := m.runWithTimeout(ctx, ip, "link", "del", m.iface); delErr != nil {
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
	// Do not resurrect resolver cleanup after the caller canceled. The
	// surviving config is deliberately retained so a later down retry can
	// perform this cleanup with a fresh, bounded request.
	if err := ctx.Err(); err != nil {
		return fmt.Errorf("resolver cleanup canceled: %w", err)
	}

	if path, err := m.lookup(resolvconfBinary); err == nil {
		if err := m.runWithTimeout(ctx, path, "-d", m.iface, "-f"); err != nil {
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
		if err := m.runWithTimeout(ctx, path, "revert", m.iface); err != nil {
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

func terminateProcessGroup(cmd *exec.Cmd) error {
	if cmd.Process == nil {
		return os.ErrProcessDone
	}
	if err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL); err != nil {
		if errors.Is(err, syscall.ESRCH) {
			return os.ErrProcessDone
		}
		return err
	}
	return nil
}

func runCommand(ctx context.Context, name string, args ...string) ([]byte, error) {
	// Keep the command deadline at the command boundary as well as in the
	// server request. This also protects direct Manager callers and cleanup
	// paths that do not pass through Server.dispatch.
	commandCtx, cancel := context.WithTimeout(ctx, commandTimeout)
	defer cancel()

	cmd := exec.CommandContext(commandCtx, name, args...)
	// wg-quick is a shell script and may leave children behind. Put the
	// command in its own process group so cancellation terminates descendants
	// too, rather than only the direct wg-quick process.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	// If a descendant escaped the group and keeps stdout/stderr open, do not
	// let CombinedOutput wait forever for the pipe to reach EOF.
	cmd.WaitDelay = commandWaitDelay
	cmd.Cancel = func() error { return terminateProcessGroup(cmd) }

	out, err := cmd.CombinedOutput()
	if errors.Is(err, exec.ErrWaitDelay) {
		// A shell can exit while a child keeps stdout/stderr open. WaitDelay
		// bounds the pipe wait; terminate the still-live group as well so an
		// orphan cannot continue privileged work after this call returns.
		_ = terminateProcessGroup(cmd)
	}
	if err != nil {
		// CommandContext reports signal termination when the process group is
		// killed. Preserve the useful deadline/cancellation cause for the
		// manager and wire error mapping.
		if commandCtx.Err() != nil {
			err = commandCtx.Err()
		}
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
