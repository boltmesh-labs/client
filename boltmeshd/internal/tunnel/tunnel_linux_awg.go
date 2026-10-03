//go:build linux

// This file is the userspace AmneziaWG data plane the Linux backend selects
// when the client's config carries the obfuscation directives. The kernel
// WireGuard module has no concept of them, so an obfuscated tunnel runs the
// AmneziaWG device in-process over a tun device instead — the same
// architecture the macOS backend uses for stock wireguard-go — and this file
// owns everything around it: the ip route plan that keeps the device's own
// endpoint traffic on the physical path, resolver state, and teardown.
//
// The device seam, the obfuscation settings and the status projection are shared
// with the Windows backend and live in awg_common.go.
package tunnel

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"strings"

	"boltmeshd/internal/protocol"
)

// liveAwgDevice returns the live userspace device, or nil when no userspace
// tunnel is running. Safe to call concurrently with an operation in flight;
// callers that mutate tunnel state hold the manager gate.
func (m *Manager) liveAwgDevice() awgDevice {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.awgDev
}

// awgLive reports whether a userspace tunnel is running.
func (m *Manager) awgLive() bool {
	return m.liveAwgDevice() != nil
}

// setAwgDevice marks a device as live together with the underlay endpoint
// prefixes its up planned, so a later teardown deletes exactly those routes
// even when the up itself fails part-way.
func (m *Manager) setAwgDevice(dev awgDevice, endpointPrefixes []string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.awgDev = dev
	m.awgEndpointRoutes = endpointPrefixes
}

// clearAwgDevice drops the live-device marker.
func (m *Manager) clearAwgDevice() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.awgDev = nil
}

// takeAwgEndpointRoutes hands out (and forgets) the planned underlay prefixes.
// A teardown that fails after taking them re-derives the prefixes from the
// lingering config file on its next attempt.
func (m *Manager) takeAwgEndpointRoutes() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	prefixes := m.awgEndpointRoutes
	m.awgEndpointRoutes = nil
	return prefixes
}

// ipRouteSpec is one family-aware `ip route` operation: v6 prefixes need the
// -6 selector or `ip` reads them as a syntax error.
type ipRouteSpec struct {
	v6   bool
	args []string // arguments after the `route` verb
}

// commandArgs renders the full `ip` argument list.
func (s ipRouteSpec) commandArgs() []string {
	args := make([]string, 0, len(s.args)+3)
	if s.v6 {
		args = append(args, "-6")
	}
	args = append(args, "route")
	return append(args, s.args...)
}

// obfRoutePlan is the route state an obfuscated up applies: the underlay host
// routes pinning every endpoint address through the physical path, and the
// tunnel routes mirroring the peer's AllowedIPs.
type obfRoutePlan struct {
	underlay []ipRouteSpec
	tunnel   []ipRouteSpec
	prefixes []string // underlay prefixes, for exact teardown
}

// failBeforeCreate reports a failure from a step that ran before anything was
// created, removing the config file that step wrote. A config left behind is the
// handle a later teardown — and a daemon that restarted and lost its in-memory
// state — both read as a live tunnel's.
func (m *Manager) failBeforeCreate(code string, err error) error {
	if rmErr := m.removeConfig(); rmErr != nil {
		return &protocol.OpError{Code: code, Err: errors.Join(err, rmErr)}
	}
	return &protocol.OpError{Code: code, Err: err}
}

// upObfuscated brings the userspace AmneziaWG tunnel up. Sequencing mirrors
// the native path: resolve tools before writing anything, down whatever is
// up, write the privileged config, then apply — and on any failure run a
// bounded recovery pass that keeps the config file until it has finished.
//
// A non-nil [transport] rides this tunnel: the stream bridge carries the
// obfuscated datagrams to the node, whose AmneziaWG device is what accepts
// them. It comes up before the tunnel routes for the same reason as the native
// path: from the moment this path's default route exists, the transport's own
// TLS egress must already be pinned through the physical path, or it would loop
// into the tunnel it carries.
func (m *Manager) upObfuscated(ctx context.Context, wgQuickConfig string, transport *protocol.TransportSpec) (*protocol.Status, error) {
	// The userspace data plane needs `ip`; resolve it before writing
	// anything, exactly like the native path resolves wg-quick.
	ipTool, err := m.tool(ipBinary)
	if err != nil {
		return nil, err
	}

	// Whatever kind of tunnel is currently up — userspace or kernel — the
	// requested config is always the one applied. A lingering config file
	// counts as up too: a daemon restart lost the in-memory state, and the
	// config is the handle on the underlay routes that must be swept. Skip
	// the down only when there is nothing of the sort: a fresh machine must
	// not run teardown commands.
	if m.awgLive() || m.linkExists(m.iface) || m.configExists() ||
		m.transport != nil || m.transportPinsRecorded() {
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

	// Translate and plan before creating anything, so a bad config or an
	// unreachable endpoint fails with nothing created but the file itself.
	settings, err := parseObfuscatedSettings(wgQuickConfig)
	if err != nil {
		return nil, m.failBeforeCreate(protocol.CodeBadConfig, err)
	}
	uapiBody, err := ConfigToUAPIWithObfuscation(wgQuickConfig)
	if err != nil {
		return nil, m.failBeforeCreate(protocol.CodeBadConfig, err)
	}
	// The endpoint resolves once, here: the underlay plan pins every address the
	// answer holds through the physical path, and the device is handed one
	// literal to dial (see obfuscatedUAPIEndpoint).
	ips, err := resolveEndpointAddresses(ctx, settings.endpoint, m.resolveHost)
	if err != nil {
		return nil, m.failBeforeCreate(protocol.CodeInternal, err)
	}
	if uapiBody, err = obfuscatedUAPIEndpoint(uapiBody, settings.endpoint, ips); err != nil {
		return nil, m.failBeforeCreate(protocol.CodeInternal, err)
	}
	routes, err := m.planObfuscatedRoutes(ctx, ipTool, settings, ips)
	if err != nil {
		return nil, m.failBeforeCreate(protocol.CodeInternal, err)
	}

	// The transport and its bypass route come up *before* the tunnel routes:
	// from the moment the obfuscated path's default route exists, the
	// transport's own TLS egress must already be pinned through the physical
	// path, or its packets (and the datagrams it carries) would loop back into
	// the tunnel. This mirrors the native path's bringUpTransport-before-
	// wg-quick ordering. There is no wg-quick here, so no pinTransportTables
	// pass either — that pass mirrors wg-quick's fwmark policy rules, and this
	// path installs metric-based routes instead.
	if transport != nil {
		if err := m.bringUpTransport(ctx, transport); err != nil {
			cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), cleanupTimeout)
			defer cancel()
			// Keep the transport's own code: a spec or credential the client
			// got wrong is a bad config, not a daemon fault.
			code := transportErrorCode(err)
			if cleanupErr := m.teardownObfuscated(cleanupCtx); cleanupErr != nil {
				return nil, &protocol.OpError{
					Code: code,
					Err:  fmt.Errorf("stream transport: %w; cleanup failed: %w", err, cleanupErr),
				}
			}
			return nil, &protocol.OpError{Code: code, Err: fmt.Errorf("stream transport: %w", err)}
		}
	}

	if err := m.startObfuscated(ctx, ipTool, uapiBody, settings, routes); err != nil {
		// Mirror the native path's bounded recovery: a partially applied
		// tunnel is torn down with a fresh deadline (the caller may already
		// have canceled), and the config file is kept until that cleanup has
		// finished so a later down can retry whatever it could not remove.
		cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), cleanupTimeout)
		defer cancel()
		if cleanupErr := m.teardownObfuscated(cleanupCtx); cleanupErr != nil {
			return nil, &protocol.OpError{
				Code: protocol.CodeInternal,
				Err:  fmt.Errorf("obfuscated up: %w; cleanup failed: %w", err, cleanupErr),
			}
		}
		return nil, &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("obfuscated up: %w", err)}
	}
	return m.readDeviceStatus(ctx)
}

// startObfuscated creates the tun, wires the device to it, and applies the
// planned network state around it. The device is marked live as soon as it
// exists, so every failure path after that point cleans up through the
// ordinary teardown instead of a hand-rolled sequence.
func (m *Manager) startObfuscated(ctx context.Context, ipTool string, uapiBody []byte, settings obfSettings, routes obfRoutePlan) error {
	tunDev, err := m.makeAwgTun(m.iface, settings.mtu)
	if err != nil {
		return fmt.Errorf("create tun %s: %w", m.iface, err)
	}
	dev, err := m.makeAwgDevice(tunDev)
	if err != nil {
		_ = tunDev.Close()
		return fmt.Errorf("start AmneziaWG device: %w", err)
	}
	m.setAwgDevice(dev, routes.prefixes)

	// Configure the peer before the network (the darwin ordering): the
	// device's own endpoint traffic must leave through the physical path,
	// which the underlay host routes pin before any tunnel route exists.
	if err := dev.configure(ctx, uapiBody); err != nil {
		return fmt.Errorf("configure device: %w", err)
	}
	if err := m.applyObfuscatedNetwork(ctx, ipTool, settings, routes); err != nil {
		return err
	}
	return nil
}

// applyObfuscatedNetwork installs the planned routes, address, link state,
// and resolver configuration, in that order.
func (m *Manager) applyObfuscatedNetwork(ctx context.Context, ipTool string, settings obfSettings, routes obfRoutePlan) error {
	// Underlay host routes first: once a tunnel route (or a strict-mode
	// default) claims the endpoint's prefix, the device's own UDP would loop
	// into the tunnel without the /32 (or /128) pin through the physical
	// path.
	for _, route := range routes.underlay {
		if err := m.runWithTimeout(ctx, ipTool, route.commandArgs()...); err != nil {
			return fmt.Errorf("pin endpoint route: %w", err)
		}
	}
	if err := m.runWithTimeout(ctx, ipTool, "address", "replace", settings.address, "dev", m.iface); err != nil {
		return fmt.Errorf("assign address: %w", err)
	}
	if err := m.runWithTimeout(ctx, ipTool, "link", "set", "dev", m.iface, "up"); err != nil {
		return fmt.Errorf("set link up: %w", err)
	}
	for _, route := range routes.tunnel {
		if err := m.runWithTimeout(ctx, ipTool, route.commandArgs()...); err != nil {
			return fmt.Errorf("install tunnel route: %w", err)
		}
	}
	return m.setResolverState(ctx, settings.dns)
}

// planObfuscatedRoutes plans the route state from the addresses the caller
// resolved for the endpoint, before anything is created: each one's physical
// path (fail closed when there is none — the tunnel could not work anyway), and
// one route per AllowedIP, with a strict-mode default claiming the default route
// at a metric that outranks the physical one.
func (m *Manager) planObfuscatedRoutes(ctx context.Context, ipTool string, settings obfSettings, ips []net.IP) (obfRoutePlan, error) {
	var plan obfRoutePlan

	for _, ip := range ips {
		// A loopback endpoint pins no underlay route: the local table resolves
		// it before any tunnel route exists and none captures it. That is the
		// stream-carried case, where the transport pins its real upstream.
		if ip.IsLoopback() {
			continue
		}
		via, dev, err := m.physicalRouteFor(ctx, ipTool, ip)
		if err != nil {
			return plan, err
		}
		args := []string{"replace", hostPrefixFor(ip)}
		if via != "" {
			args = append(args, "via", via)
		}
		args = append(args, "dev", dev)
		plan.underlay = append(plan.underlay, ipRouteSpec{v6: ip.To4() == nil, args: args})
		plan.prefixes = append(plan.prefixes, hostPrefixFor(ip))
	}

	for _, cidr := range settings.allowedIPs {
		_, ipnet, err := net.ParseCIDR(cidr)
		if err != nil {
			return plan, fmt.Errorf("invalid AllowedIP %q", cidr)
		}
		v6 := ipnet.IP.To4() == nil
		if ones, _ := ipnet.Mask.Size(); ones == 0 {
			plan.tunnel = append(plan.tunnel, ipRouteSpec{
				v6:   v6,
				args: []string{"replace", "default", "dev", m.iface, "metric", awgDefaultRouteMetric},
			})
			continue
		}
		plan.tunnel = append(plan.tunnel, ipRouteSpec{
			v6:   v6,
			args: []string{"replace", cidr, "dev", m.iface},
		})
	}
	return plan, nil
}

// physicalRouteFor asks the main table which physical path the endpoint
// address takes today (before any tunnel route exists) and returns the
// gateway and device that a host route must pin. Fail closed on a local
// address or an unreachable destination.
func (m *Manager) physicalRouteFor(ctx context.Context, ipTool string, ip net.IP) (via, dev string, err error) {
	getCtx, cancel := context.WithTimeout(ctx, commandTimeout)
	defer cancel()
	args := []string{"route", "get", ip.String()}
	if ip.To4() == nil {
		args = append([]string{"-6"}, args...)
	}
	out, err := m.run(getCtx, ipTool, args...)
	if err != nil {
		return "", "", fmt.Errorf("route get %s: %w", ip, err)
	}
	fields := strings.Fields(string(out))
	if len(fields) == 0 {
		return "", "", fmt.Errorf("route get %s: empty output", ip)
	}
	if fields[0] == "local" {
		return "", "", fmt.Errorf("endpoint %s is a local address", ip)
	}
	for i := 0; i+1 < len(fields); i++ {
		switch fields[i] {
		case "via":
			via = fields[i+1]
		case "dev":
			dev = fields[i+1]
		}
	}
	if dev == "" {
		return "", "", fmt.Errorf("route get %s: no device in output", ip)
	}
	return via, dev, nil
}

// setResolverState mirrors the wg-quick set_dns choice and stays symmetric
// with [Manager.clearResolverState]: the resolvconf compatibility command
// first (the systemd implementation covers the common installations), then
// resolvectl for systems exposing only the native systemd-resolved tool. With
// neither installed the tunnel carries no DNS — the same outcome a wg-quick
// tunnel would have there.
func (m *Manager) setResolverState(ctx context.Context, dns string) error {
	servers := strings.Fields(strings.ReplaceAll(dns, ",", " "))
	if len(servers) == 0 {
		return nil
	}
	if path, err := m.lookup(resolvconfBinary); err == nil {
		var input strings.Builder
		for _, server := range servers {
			fmt.Fprintf(&input, "nameserver %s\n", server)
		}
		if _, err := m.runInput(ctx, input.String(), path, "-a", m.iface, "-m", "0", "-x"); err != nil {
			return &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("resolvconf set: %w", err)}
		}
		return nil
	}
	if path, err := m.lookup(resolvectlBinary); err == nil {
		args := append([]string{"dns", m.iface}, servers...)
		if err := m.runWithTimeout(ctx, path, args...); err != nil {
			return &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("resolvectl set: %w", err)}
		}
		if err := m.runWithTimeout(ctx, path, "domain", m.iface, "~."); err != nil {
			return &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("resolvectl domain: %w", err)}
		}
		return nil
	}
	slog.Warn("no resolver tool installed; tunnel DNS not applied", "interface", m.iface)
	return nil
}

// teardownObfuscated tears the userspace data plane down and sweeps the state
// the OS does not remove by itself. The device is closed before the underlay
// routes are deleted: while the tunnel routes still exist, only a stopped
// data plane guarantees its own endpoint traffic cannot start looping into
// the tunnel. Closing the device removes the tun interface, and the kernel
// flushes its routes with it — which is why the underlay host routes (bound
// to the physical device, not the tun) are the only routes to delete
// explicitly.
//
// The config file is removed only after every cleanup step succeeded,
// mirroring the native path: an incomplete cleanup keeps the file as the
// recovery handle.
func (m *Manager) teardownObfuscated(ctx context.Context) error {
	dev := m.liveAwgDevice()
	var errs []error
	if dev != nil {
		if err := dev.close(); err != nil {
			errs = append(errs, err)
		}
	}
	m.clearAwgDevice()
	// The stream transport goes down with the tunnel it carries. No-op when no
	// transport is live (a plain obfuscated tunnel, or one started without a
	// transport).
	if err := m.downTransport(ctx); err != nil {
		errs = append(errs, err)
	}
	if err := m.clearObfuscatedUnderlay(ctx); err != nil {
		errs = append(errs, err)
	}
	if err := m.clearResolverState(ctx); err != nil {
		errs = append(errs, err)
	}
	if len(errs) > 0 {
		return &protocol.OpError{Code: protocol.CodeInternal, Err: errors.Join(errs...)}
	}
	if err := os.Remove(m.configPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("remove config: %w", err)}
	}
	return nil
}

// clearObfuscatedUnderlay removes the underlay host routes an obfuscated
// tunnel pinned through the physical path. They are bound to the physical
// device, so they survive the tun's death and must be deleted explicitly.
//
// With no in-memory prefixes (a daemon restart lost them), they are derived
// from the lingering config file; a failure to derive them is tolerated with
// a warning — the routes forward exactly where the main table would send
// that traffic anyway — while a failure to delete a known prefix is an error,
// keeping the config file behind as the retry handle.
func (m *Manager) clearObfuscatedUnderlay(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return fmt.Errorf("underlay route cleanup canceled: %w", err)
	}
	prefixes := m.takeAwgEndpointRoutes()
	if len(prefixes) == 0 {
		derived, err := m.underlayPrefixesFromConfig(ctx)
		if err != nil {
			slog.Warn("could not derive stale underlay routes from config", "error", err)
			return nil
		}
		prefixes = derived
	}
	if len(prefixes) == 0 {
		return nil
	}
	ipTool, err := m.tool(ipBinary)
	if err != nil {
		return err
	}
	var errs []error
	for _, prefix := range prefixes {
		spec := ipRouteSpec{v6: strings.Contains(prefix, ":"), args: []string{"del", prefix}}
		if err := m.runWithTimeout(ctx, ipTool, spec.commandArgs()...); err != nil {
			// Deleting a route that is no longer there is success: the goal
			// is "no underlay host route left", not "one command per
			// prefix". iproute2 reports a missing route as "No such
			// process".
			if routeMissing(err) {
				continue
			}
			errs = append(errs, fmt.Errorf("delete underlay route %s: %w", prefix, err))
		}
	}
	if len(errs) > 0 {
		return &protocol.OpError{Code: protocol.CodeInternal, Err: errors.Join(errs...)}
	}
	return nil
}

// routeMissing reports whether an `ip route del` error means the route was
// already gone.
func routeMissing(err error) bool {
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "no such process") || strings.Contains(msg, "not found")
}

// underlayPrefixesFromConfig re-derives the endpoint host route prefixes from
// a lingering config file: only an obfuscated config pins underlay routes.
func (m *Manager) underlayPrefixesFromConfig(ctx context.Context) ([]string, error) {
	data, err := os.ReadFile(m.configPath())
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	text := string(data)
	if !awgObfuscated(parseWgQuick(text)) {
		return nil, nil
	}
	settings, err := parseObfuscatedSettings(text)
	if err != nil {
		return nil, err
	}
	ips, err := resolveEndpointAddresses(ctx, settings.endpoint, m.resolveHost)
	if err != nil {
		return nil, err
	}
	return underlayPrefixesFor(ips), nil
}

// removeConfig deletes the privileged config file (best effort at call
// sites that already carry the primary error).
func (m *Manager) removeConfig() error {
	if err := os.Remove(m.configPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove config: %w", err)
	}
	return nil
}

// configExists reports whether the privileged config file is present — the
// marker of a tunnel (or a failed up) whose state may still need sweeping.
func (m *Manager) configExists() bool {
	_, err := os.Stat(m.configPath())
	return err == nil
}
