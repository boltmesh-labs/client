//go:build darwin

package tunnel

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"

	"boltmeshd/internal/config"
	"boltmeshd/internal/protocol"
)

// macOS has no kernel WireGuard module and `wgctrl` has no darwin backend, so
// this backend runs the WireGuard data plane in userspace over a `utun` device
// and drives it through the device's UAPI protocol — the same architecture the
// upstream WireGuard macOS app uses. The wg-quick text the client already sends
// is translated by [ConfigToUAPI].
//
// Because the data plane is a goroutine inside the daemon rather than a
// kernel module or a separate service, the process is the failure domain: a
// crash in the device takes the daemon with it, and launchd's KeepAlive
// restarts it. That is the same trade the Linux backend makes with a forked
// wg-quick, and it is why Down must always close the device.

const (
	// DefaultConfigDir holds the root-only wg-quick config, mirroring the
	// Linux location. It stays available through the stop sequence so Down
	// can tear the device down before package cleanup removes the directory.
	DefaultConfigDir = "/var/run/boltmesh"

	// defaultMTU matches the value the client puts in the wg-quick config.
	// A utun device defaults to 1500; WireGuard overhead means the tunnel
	// MTU must be lower or large packets fragment.
	defaultMTU = 1420

	// commandTimeout bounds the complete lifecycle operation, mirroring the
	// Linux budget so the client's request deadlines behave the same way.
	commandTimeout = 30 * time.Second

	// cleanupTimeout bounds the recovery pass after a failed up, which must
	// not inherit an already-canceled request context.
	cleanupTimeout = 5 * time.Second
)

// wireguardDevice is the seam over the userspace WireGuard device. The real
// implementation is a *device.Device; tests substitute a fake so the manager's
// sequencing can be exercised without a utun interface.
type wireguardDevice interface {
	// configure applies a UAPI `set=1` body.
	configure(ctx context.Context, body []byte) error
	// dump returns the UAPI `get=1` response.
	dump(ctx context.Context) ([]byte, error)
	// close shuts the device and its TUN down.
	close() error
}

// systemTun is the seam over the utun creation and the address/route work the
// device cannot do itself. Split out because it is the part that needs root and
// the part that is hardest to test.
type systemTun interface {
	// create opens a utun device and returns its OS name plus a closer.
	create(ctx context.Context) (name string, close func() error, err error)
	// configure assigns the tunnel addresses and routes, and points the
	// system resolver at the tunnel DNS server.
	configure(ctx context.Context, name string, address string, allowedIPs []string, dns string) error
	// teardown removes the addresses, routes and resolver state for name.
	teardown(ctx context.Context, name string) error
}

// Manager owns the userspace WireGuard device. Construct with [NewManager];
// tests replace the unexported seams.
type Manager struct {
	iface string
	dir   string

	// gate serializes up/down. A bounded request waits for the current
	// operation (or its cancellation) instead of racing a retry against a
	// device that may still be mutating tunnel state.
	gate operationGate
	busy atomic.Bool

	// device is the live userspace device, or nil when the tunnel is down.
	// Guarded by mu so Status can read it while an operation is in flight.
	mu     sync.Mutex
	device wireguardDevice
	// tunName is the OS interface name the live device was created with.
	tunName string

	makeTun    systemTun
	makeDevice func(tun.Device) (wireguardDevice, error)
}

// NewManager returns a Manager for iface storing its config in dir.
func NewManager(dir, iface string) *Manager {
	return &Manager{
		iface:      iface,
		dir:        dir,
		makeTun:    systemTunImpl{},
		makeDevice: newUserspaceDevice,
	}
}

func (m *Manager) configPath() string {
	return filepath.Join(m.dir, m.iface+".conf")
}

// liveDevice returns the current device, or nil when down.
func (m *Manager) liveDevice() (wireguardDevice, string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.device, m.tunName
}

func (m *Manager) setDevice(d wireguardDevice, name string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.device, m.tunName = d, name
}

func (m *Manager) clearDevice() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.device, m.tunName = nil, ""
}

// Up validates the config, starts a userspace device, and applies it. An
// existing tunnel is torn down first so the requested config is always the one
// applied (never two live devices).
func (m *Manager) Up(ctx context.Context, wgQuickConfig string) (*protocol.Status, error) {
	// Validate before taking the lock: a malformed config must not consume
	// the privileged operation slot or touch disk.
	if err := config.Validate(wgQuickConfig); err != nil {
		return nil, &protocol.OpError{Code: protocol.CodeBadConfig, Err: err}
	}
	// Translate before taking the lock for the same reason: an unsupported
	// directive must not disturb a working tunnel.
	body, err := ConfigToUAPI(wgQuickConfig)
	if err != nil {
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

	operationCtx, cancel := context.WithTimeout(ctx, commandTimeout)
	defer cancel()
	ctx = operationCtx

	// Any existing device is torn down first, so a requested config is
	// always the one applied.
	if err := m.down(ctx); err != nil {
		return nil, err
	}

	if err := os.MkdirAll(m.dir, 0o700); err != nil {
		return nil, &protocol.OpError{
			Code: protocol.CodeInternal,
			Err:  fmt.Errorf("create config dir: %w", err),
		}
	}
	if err := os.WriteFile(m.configPath(), []byte(wgQuickConfig), 0o600); err != nil {
		return nil, &protocol.OpError{
			Code: protocol.CodeInternal,
			Err:  fmt.Errorf("write config: %w", err),
		}
	}

	settings, err := parseClientSettings(wgQuickConfig)
	if err != nil {
		_ = os.Remove(m.configPath())
		return nil, &protocol.OpError{Code: protocol.CodeBadConfig, Err: err}
	}

	if err := m.start(ctx, body, settings); err != nil {
		// A partially-started device may already own the utun interface and
		// have installed routes. Run a bounded recovery pass on a context
		// that does not inherit the request's cancellation, so a canceled
		// request still leaves nothing behind. The gate stays held, so a
		// retry cannot race the recovery.
		cleanupCtx, cleanupCancel := context.WithTimeout(
			context.WithoutCancel(ctx), cleanupTimeout,
		)
		defer cleanupCancel()
		if cleanupErr := m.cleanup(cleanupCtx); cleanupErr != nil {
			return nil, &protocol.OpError{
				Code: protocol.CodeInternal,
				Err:  fmt.Errorf("start tunnel: %w; cleanup failed: %w", err, cleanupErr),
			}
		}
		_ = os.Remove(m.configPath())
		return nil, &protocol.OpError{
			Code: protocol.CodeInternal,
			Err:  fmt.Errorf("start tunnel: %w", err),
		}
	}
	return m.readDeviceStatus(ctx)
}

// start creates the utun device, applies the UAPI config, then installs the
// addresses and routes. The order matters: the device must know its peer before
// routes point traffic at it, or packets are black-holed until the first
// handshake.
func (m *Manager) start(ctx context.Context, body []byte, settings clientSettings) error {
	name, closeTun, err := m.makeTun.create(ctx)
	if err != nil {
		return fmt.Errorf("create utun device: %w", err)
	}

	// From here on any failure must close the utun, or a later retry leaks
	// an interface.
	device, err := m.newDeviceFor(name)
	if err != nil {
		_ = closeTun()
		return err
	}

	if err := device.configure(ctx, body); err != nil {
		_ = device.close()
		_ = closeTun()
		return fmt.Errorf("configure device: %w", err)
	}

	// Addresses and routes go in only after the device accepted its config.
	// A failure here leaves a configured device with no traffic path; the
	// caller's recovery pass tears both down.
	if err := m.makeTun.configure(
		ctx, name, settings.address, settings.allowedIPs, settings.dns,
	); err != nil {
		_ = device.close()
		_ = closeTun()
		return fmt.Errorf("configure interface: %w", err)
	}

	m.setDevice(&closableDevice{inner: device, tun: closeTun}, name)
	return nil
}

// newDeviceFor opens the utun and constructs the userspace device bound to it.
func (m *Manager) newDeviceFor(name string) (wireguardDevice, error) {
	// The utun already exists (makeTun.create made it), so reopen the same
	// name the kernel assigned rather than creating a second interface.
	tunDev, err := tun.CreateTUN(name, defaultMTU)
	if err != nil {
		return nil, fmt.Errorf("open utun %s: %w", name, err)
	}
	device, err := m.makeDevice(tunDev)
	if err != nil {
		_ = tunDev.Close()
		return nil, err
	}
	return device, nil
}

// closableDevice ties the userspace device's lifetime to the utun closer, so a
// single close removes both. Closing the device before the interface matters:
// a closed utun still has its routes installed.
type closableDevice struct {
	inner wireguardDevice
	tun   func() error
}

func (c *closableDevice) configure(ctx context.Context, body []byte) error {
	return c.inner.configure(ctx, body)
}

func (c *closableDevice) dump(ctx context.Context) ([]byte, error) {
	return c.inner.dump(ctx)
}

func (c *closableDevice) close() error {
	// Device first, then the interface: the reverse order would leave the
	// data plane reading a closed utun.
	err := c.inner.close()
	if tunErr := c.tun(); tunErr != nil && err == nil {
		err = tunErr
	}
	return err
}

// newUserspaceDevice wires a real wireguard-go device to a utun. The device
// owns the utun from here on: closing it closes both.
func newUserspaceDevice(tunDev tun.Device) (wireguardDevice, error) {
	logger := &device.Logger{
		// Route the data plane's own diagnostics into the daemon log instead
		// of discarding them, so a device-side failure is not invisible.
		Verbosef: func(format string, args ...any) {
			slog.Debug("wireguard: "+format, args...)
		},
		Errorf: func(format string, args ...any) {
			slog.Error("wireguard: "+format, args...)
		},
	}
	return &goDevice{
		inner: device.NewDevice(tunDev, conn.NewDefaultBind(), logger),
		tun:   tunDev,
	}, nil
}

// goDevice adapts a wireguard-go device to the [wireguardDevice] seam,
// translating the UAPI request/response framing into method calls.
type goDevice struct {
	inner *device.Device
	tun   tun.Device
}

func (d *goDevice) configure(ctx context.Context, body []byte) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return d.inner.IpcSet(string(body))
}

func (d *goDevice) dump(ctx context.Context) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	var out bytes.Buffer
	if err := d.inner.IpcGetOperation(&out); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

// close stops the device and then the utun. The device first: closing the
// utun while the data plane still reads it would panic in its read loop.
func (d *goDevice) close() error {
	d.inner.Close()
	if d.tun != nil {
		return d.tun.Close()
	}
	return nil
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

// down tears down whatever is live. It never fails on an absent device, so a
// repeated Disconnect is safe.
func (m *Manager) down(ctx context.Context) error {
	if device, _ := m.liveDevice(); device == nil {
		// Nothing live. A stale config file can still exist from an unclean
		// exit; remove it so the next up cannot read an old key.
		_ = os.Remove(m.configPath())
		return nil
	}
	return m.cleanup(ctx)
}

// cleanup removes the device and its network state. The config is removed only
// after the required teardown succeeded, so an incomplete cleanup leaves the
// one handle needed to retry it.
func (m *Manager) cleanup(ctx context.Context) error {
	device, name := m.liveDevice()
	var cleanupErrs []error

	if device != nil {
		// Addresses and routes go first: closing the device while routes
		// still point at it black-holes the user's traffic.
		if err := m.makeTun.teardown(ctx, name); err != nil {
			cleanupErrs = append(cleanupErrs, err)
		}
		if err := device.close(); err != nil {
			cleanupErrs = append(cleanupErrs, fmt.Errorf("close device: %w", err))
		}
		m.clearDevice()
	}

	if len(cleanupErrs) == 0 {
		if err := os.Remove(m.configPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
			cleanupErrs = append(cleanupErrs, fmt.Errorf("remove config: %w", err))
		}
	}
	if len(cleanupErrs) > 0 {
		return &protocol.OpError{
			Code: protocol.CodeInternal,
			Err:  errors.Join(cleanupErrs...),
		}
	}
	return nil
}

// Status reports the device view. An in-flight up takes precedence over the
// device so callers never observe the old or partially configured tunnel as
// connected.
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

// readDeviceStatus projects the live device's UAPI dump into the shared status
// shape. A device that is not running is disconnected, not an error: that is
// the normal state between connections.
func (m *Manager) readDeviceStatus(ctx context.Context) (*protocol.Status, error) {
	if err := ctx.Err(); err != nil {
		return nil, statusReadError(err)
	}
	st := &protocol.Status{Interface: m.iface, Stage: protocol.StageDisconnected}

	device, _ := m.liveDevice()
	if device == nil {
		return st, nil
	}
	dump, err := device.dump(ctx)
	if err != nil {
		// A read failure is unknown, never proof of death: the client
		// escalates on a missing device, and treating an unreadable device as
		// disconnected would tear down a working tunnel.
		return nil, &protocol.OpError{
			Code: protocol.CodeInternal,
			Err:  fmt.Errorf("read tunnel status: %w", err),
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, statusReadError(err)
	}
	peers, err := ParseUAPIPeers(dump)
	if err != nil {
		return nil, &protocol.OpError{
			Code: protocol.CodeInternal,
			Err:  err,
		}
	}

	st.Up = true
	st.Stage = protocol.StageConnected
	applyPeers(st, peers)
	return st, nil
}

func statusReadError(err error) error {
	return &protocol.OpError{
		Code: protocol.CodeInternal,
		Err:  fmt.Errorf("read tunnel status: %w", err),
	}
}

// clientSettings are the parts of the wg-quick config the device protocol does
// not carry and the backend must apply itself.
type clientSettings struct {
	address    string
	dns        string
	allowedIPs []string
}

// parseClientSettings pulls the address, DNS and allowed IPs out of a validated
// config. It is separate from [ConfigToUAPI] because the device rejects these
// directives as unknown, yet the backend still needs them.
func parseClientSettings(text string) (clientSettings, error) {
	var settings clientSettings
	for _, d := range parseWgQuick(text) {
		switch {
		case d.section == "interface" && d.key == "address":
			if settings.address == "" {
				settings.address = strings.TrimSpace(d.value)
			}
		case d.section == "interface" && d.key == "dns":
			if settings.dns == "" {
				settings.dns = strings.TrimSpace(d.value)
			}
		case d.section == "peer" && d.key == "allowedips":
			for _, cidr := range strings.Split(d.value, ",") {
				if cidr = strings.TrimSpace(cidr); cidr != "" {
					settings.allowedIPs = append(settings.allowedIPs, cidr)
				}
			}
		}
	}
	if settings.address == "" {
		return settings, errors.New("config is missing [Interface] Address")
	}
	return settings, nil
}

// LiveTunnelInterface returns the OS name of a utun interface that still
// carries a BoltMesh route, or "" when none does.
//
// The userspace device dies with the daemon process, but its utun interface and
// the default route installed for it do not necessarily: an unclean stop can
// leave the interface up with traffic still pointed at it. The uninstaller
// probes with this so it can fail closed instead of removing the job
// definition and stranding a live interface.
//
// Matching is by route rather than by name, because macOS assigns utunN and
// there is no fixed name to test for.
func LiveTunnelInterface() string {
	interfaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, iface := range interfaces {
		if !strings.HasPrefix(iface.Name, "utun") {
			continue
		}
		// An interface with our default route installed is ours; a utun with
		// no BoltMesh route belongs to some other VPN and is left alone.
		if hasBoltMeshRoute(iface.Name) {
			return iface.Name
		}
	}
	return ""
}
