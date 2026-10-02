//go:build windows

// This file is the userspace AmneziaWG data plane the Windows backend selects when
// the client's config carries the obfuscation directives. The WireGuard-for-Windows
// kernel service has no concept of them, so an obfuscated tunnel runs the AmneziaWG
// device in-process over a Wintun adapter instead — the same architecture the Linux
// backend uses over /dev/net/tun — and this file owns everything around it.
//
// What differs from the Linux backend is entirely the plumbing, and each difference
// has a reason rather than a preference:
//
//   - The adapter. awgtun.CreateTUN is the same call the Linux path makes, but on
//     Windows it is backed by Wintun, whose DLL is pinned to System32 by content hash
//     in wintun_windows.go. Nothing here may resolve that driver by name.
//   - Address and DNS. Windows has no `ip address` and no resolvconf, so both go
//     through IP Helper entry points bound by hand in netif_windows.go.
//   - Teardown is much shorter. Closing the device deletes the Wintun adapter, and an
//     adapter's addresses, routes and DNS settings go with it. The only state that
//     outlives it is the endpoint's underlay host route, which lives on the physical
//     interface and is swept explicitly.
//
// The device seam, the obfuscation settings and the status projection are shared with
// the Linux backend and live in awg_common.go.
package tunnel

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"strings"

	awgtun "github.com/amnezia-vpn/amneziawg-go/v3/tun"

	"boltmeshd/internal/protocol"
)

// awgTunnelRouteMetric is the metric given to the routes the tunnel installs.
//
// Unlike the transport's /32, a route the tunnel adds for AllowedIPs = 0.0.0.0/0 does
// compete for the default route, and it cannot win on prefix length because the
// physical default is the same length. Windows resolves that by metric, lower first,
// so this has to beat whatever the machine's own default route is set to rather than
// merely be present. It mirrors the Linux path's awgDefaultRouteMetric: both are
// separate literals because one is an `ip route` argument string and the other is a
// MIB_IPFORWARD_ROW2 field, and the shared constant would have to be a string to
// serve both.
const awgTunnelRouteMetric = 1

// liveAwgDevice returns the live userspace device, or nil when no userspace tunnel is
// running. Safe to call concurrently with an operation in flight; callers that mutate
// tunnel state hold the manager gate.
func (m *Manager) liveAwgDevice() awgDevice {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.awgDev
}

// awgLive reports whether a userspace tunnel is running.
func (m *Manager) awgLive() bool {
	return m.liveAwgDevice() != nil
}

// setAwgDevice marks a device as live together with the underlay endpoint prefixes
// its up planned, so a later teardown deletes exactly those routes even when the up
// itself failed part-way.
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

// takeAwgEndpointRoutes hands out (and forgets) the planned underlay prefixes. A
// teardown that fails after taking them re-derives the prefixes from the lingering
// config file on its next attempt.
func (m *Manager) takeAwgEndpointRoutes() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	prefixes := m.awgEndpointRoutes
	m.awgEndpointRoutes = nil
	return prefixes
}

// staleObfuscatedConfig reports whether the config on disk is an obfuscated one.
//
// This is the marker a daemon restart leaves behind, and it matters for two things the
// in-memory state cannot cover: the underlay host routes, which are bound to the
// physical interface and outlive the process that installed them, and the pin record.
// The Wintun adapter does not: its handle dies with the process and Windows removes it
// then, so there is no adapter to sweep.
func (m *Manager) staleObfuscatedConfig() bool {
	data, err := os.ReadFile(m.configPath())
	if err != nil {
		return false
	}
	return awgObfuscated(parseWgQuick(string(data)))
}

// awgUnderlayRoute is one endpoint address pinned through the physical path, with the
// path it was pinned through.
type awgUnderlayRoute struct {
	dst net.IP
	via physicalRoute
}

// awgTunnelRoute is one of the peer's AllowedIPs, resolved to a prefix to route into
// the tunnel.
type awgTunnelRoute = net.IPNet

// awgUnderlayPlan is the underlay host routes an obfuscated up installs. The prefixes
// are kept alongside so a teardown that has lost its in-memory state can still delete
// exactly what was installed.
type awgUnderlayPlan struct {
	routes   []awgUnderlayRoute
	prefixes []string
}

// upObfuscated brings the userspace AmneziaWG tunnel up. Sequencing mirrors the native
// path: down whatever is up, write the privileged config, plan before creating
// anything, start the transport, create the adapter, configure the device, apply the
// network — and on any failure run a bounded recovery pass that keeps the config file
// until it has finished.
//
// A non-nil transport rides this tunnel: the stream bridge carries the obfuscated
// datagrams to the node, whose AmneziaWG device is what accepts them. It comes up
// before the tunnel's routes for the same reason as the native path: from the moment
// this path's default route exists, the transport's own TLS egress must already be
// pinned through the physical path, or it would loop into the tunnel it carries.
func (m *Manager) upObfuscated(ctx context.Context, wgQuickConfig string, transport *protocol.TransportSpec) (*protocol.Status, error) {
	// Whatever kind of tunnel is currently up — userspace or kernel — the requested
	// config is always the one applied. A lingering config file counts as up too: a
	// daemon restart lost the in-memory state, and the config is the handle on the
	// underlay routes that must be swept. Skip the down only when there is nothing of
	// the sort: a fresh machine must not run teardown steps.
	if m.awgLive() || m.staleObfuscatedConfig() || m.transport != nil ||
		m.transportPinsRecorded() {
		if err := m.teardownObfuscated(ctx); err != nil {
			return nil, err
		}
	}
	if err := m.protectDir(m.dir); err != nil {
		return nil, &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("protect config dir: %w", err)}
	}
	if err := writePrivateFile(m.configPath(), []byte(wgQuickConfig), m.protectFile); err != nil {
		return nil, &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("write config: %w", err)}
	}

	// Translate and plan before creating anything, so a bad config or an unreachable
	// endpoint fails with nothing created but the file itself.
	settings, err := parseObfuscatedSettings(wgQuickConfig)
	if err != nil {
		return nil, m.badConfig(err)
	}
	uapiBody, err := ConfigToUAPIWithObfuscation(wgQuickConfig)
	if err != nil {
		return nil, m.badConfig(err)
	}
	underlay, err := m.planObfuscatedUnderlay(ctx, settings)
	if err != nil {
		if rmErr := removeConfigFile(m.configPath()); rmErr != nil {
			return nil, &protocol.OpError{Code: protocol.CodeInternal, Err: errors.Join(err, rmErr)}
		}
		return nil, &protocol.OpError{Code: protocol.CodeInternal, Err: err}
	}

	// The transport and its bypass route come up *before* the tunnel's routes: from
	// the moment this path's default route exists, the transport's own TLS egress must
	// already be pinned through the physical path, or its packets (and the datagrams
	// they carry) would loop back into the tunnel. This mirrors the native path's
	// bringUpTransport-before-service ordering, and for the same reason.
	if transport != nil {
		if err := m.bringUpTransport(ctx, transport); err != nil {
			cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), cleanupTimeout)
			defer cancel()
			// Keep the transport's own code: a spec or credential the client got
			// wrong is a bad config, not a daemon fault, and the client's reaction
			// to the two differs.
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

	if err := m.startObfuscated(ctx, uapiBody, settings, underlay); err != nil {
		// Mirror the native path's bounded recovery: a partially applied tunnel is torn
		// down with a fresh deadline (the caller may already have canceled), and the
		// config file is kept until that cleanup has finished so a later down can retry
		// whatever it could not remove.
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

	dev := m.liveAwgDevice()
	if dev == nil {
		return nil, &protocol.OpError{Code: protocol.CodeInternal, Err: errors.New("obfuscated up: device did not stay live")}
	}
	return readObfuscatedStatus(ctx, m.iface, dev)
}

// badConfig removes the config a rejected request wrote and reports the reason under
// the code the client acts on.
func (m *Manager) badConfig(err error) error {
	if rmErr := removeConfigFile(m.configPath()); rmErr != nil {
		return &protocol.OpError{Code: protocol.CodeBadConfig, Err: errors.Join(err, rmErr)}
	}
	return &protocol.OpError{Code: protocol.CodeBadConfig, Err: err}
}

// startObfuscated creates the adapter, wires the device to it, and applies the planned
// network state around it.
//
// The adapter is pinned to System32 first: the AmneziaWG device's own Wintun binding
// resolves "wintun.dll" by name at first use, and this is the only place the bytes it
// gets can be decided. Failing here, before anything is created, is why that ordering
// matters.
//
// The device is marked live as soon as it exists, so every failure path after that point
// cleans up through the ordinary teardown instead of a hand-rolled sequence.
func (m *Manager) startObfuscated(ctx context.Context, uapiBody []byte, settings obfSettings, underlay awgUnderlayPlan) error {
	if _, err := m.loadWintun(); err != nil {
		return fmt.Errorf("pin the tunnel driver: %w", err)
	}
	tunDev, err := m.makeAwgTun(m.iface, settings.mtu)
	if err != nil {
		return fmt.Errorf("create adapter %s: %w", m.iface, err)
	}
	luid, err := awgTunLUID(tunDev)
	if err != nil {
		_ = tunDev.Close()
		return err
	}
	dev, err := m.makeAwgDevice(tunDev)
	if err != nil {
		_ = tunDev.Close()
		return fmt.Errorf("start AmneziaWG device: %w", err)
	}
	m.setAwgDevice(dev, underlay.prefixes)

	// Configure the peer before the network (the darwin ordering): the device's own
	// endpoint traffic must leave through the physical path, which the underlay host
	// routes pin before any tunnel route exists.
	if err := dev.configure(ctx, uapiBody); err != nil {
		return fmt.Errorf("configure device: %w", err)
	}
	return m.applyObfuscatedNetwork(ctx, tunDev, luid, settings, underlay)
}

// awgTunLUID reads the Wintun adapter's identity, without which no address or route can
// be installed on it.
//
// The LUID is not part of the tun.Device interface the data plane is written against,
// so it comes from a type assertion against what the Windows implementation actually
// provides. A device without it is refused rather than accommodated: every later step
// needs it, so there is no partial path to fall back to.
func awgTunLUID(dev awgtun.Device) (uint64, error) {
	luid, ok := dev.(interface{ LUID() uint64 })
	if !ok {
		return 0, errors.New("adapter does not report an interface identifier")
	}
	id := luid.LUID()
	if id == 0 {
		return 0, errors.New("adapter reported interface identifier 0")
	}
	return id, nil
}

// applyObfuscatedNetwork installs the planned routes, address, and DNS, in that order.
//
// The underlay pins come first: once a tunnel route (or a strict-mode default) claims
// the endpoint's prefix, the device's own UDP would loop into the tunnel without the /32
// through the physical path.
//
// The address precedes the routes because Windows resolves a route's reachability
// against the interface's addresses: a route for 10.2.0.0/16 on an adapter holding
// nothing but 10.2.0.5/32 is a route the stack treats as dead.
func (m *Manager) applyObfuscatedNetwork(ctx context.Context, tunDev awgtun.Device, luid uint64, settings obfSettings, underlay awgUnderlayPlan) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	for _, route := range underlay.routes {
		if err := m.routes.addHostRoute(route.dst, route.via); err != nil {
			return fmt.Errorf("pin endpoint route: %w", err)
		}
	}

	ip, bits, err := addressPrefix(settings.address)
	if err != nil {
		return err
	}

	// The GUID is resolved before the address rather than after it. It is one lookup,
	// and what it buys is that an identity the IP Helper cannot resolve fails here —
	// with nothing installed on that interface — instead of surfacing as the address
	// call failing for a reason that names the address rather than the interface.
	guid, err := m.netIf.interfaceGUID(luid)
	if err != nil {
		return err
	}
	if err := m.netIf.addAddress(luid, ip, bits); err != nil {
		return fmt.Errorf("assign tunnel address: %w", err)
	}

	tunnel, err := tunnelRoutes(settings.allowedIPs)
	if err != nil {
		return err
	}
	for _, route := range tunnel {
		ones, _ := route.Mask.Size()
		if err := m.routes.addPrefixRoute(
			route.IP, uint8(ones), luid, nil, awgTunnelRouteMetric,
		); err != nil {
			return fmt.Errorf("install tunnel route: %w", err)
		}
	}

	servers := dnsServers(settings.dns)
	if len(servers) == 0 {
		// No resolver configured: the tunnel still routes, it just does not decide
		// names. Same outcome a wg-quick tunnel has with no DNS directive.
		slog.Warn("tunnel config carries no DNS server", "interface", m.iface)
		return nil
	}
	if err := m.netIf.setDNS(guid, servers); err != nil {
		return fmt.Errorf("apply tunnel DNS: %w", err)
	}
	return nil
}

// addressPrefix splits the Address directive into the address and the prefix length
// the address entry point wants. A bare address with no prefix length is accepted as a
// host address, which is the only meaning a /32-less directive can carry.
func addressPrefix(value string) (net.IP, uint8, error) {
	if strings.Contains(value, "/") {
		_, ipnet, err := net.ParseCIDR(value)
		if err != nil {
			return nil, 0, fmt.Errorf("invalid Address %q: %w", value, err)
		}
		bits, _ := ipnet.Mask.Size()
		return ipnet.IP, uint8(bits), nil
	}
	ip := net.ParseIP(strings.TrimSpace(value))
	if ip == nil {
		return nil, 0, fmt.Errorf("invalid Address %q", value)
	}
	if ip.To4() != nil {
		return ip, 32, nil
	}
	return ip, 128, nil
}

// dnsServers splits the DNS directive into resolvers. The client renders it
// comma-separated, and config validation has already rejected anything that is not an
// address, so a token that is not an IP can only have come from a hand-edited config
// and is dropped rather than sent.
func dnsServers(value string) []net.IP {
	fields := strings.FieldsFunc(value, func(r rune) bool {
		return r == ',' || r == ' ' || r == '\t' || r == '\n' || r == '\r'
	})
	servers := make([]net.IP, 0, len(fields))
	for _, field := range fields {
		if ip := net.ParseIP(field); ip != nil {
			servers = append(servers, ip)
		}
	}
	return servers
}

// tunnelRoutes turns the peer's AllowedIPs into prefixes to route into the tunnel.
//
// A prefix that will not parse fails the whole bring-up rather than being skipped.
// Config validation has already rejected a malformed AllowedIPs, so reaching here with
// one means the settings and the validator disagree — and a tunnel quietly missing a
// prefix it was configured to carry sends that traffic somewhere the user did not ask
// for, which is worse than not coming up.
//
// 0.0.0.0/0 needs no special case. It is installed as an ordinary prefix at a low
// metric, which is how this platform resolves a second default route: Windows compares
// metric once prefix length has tied.
func tunnelRoutes(allowedIPs []string) ([]awgTunnelRoute, error) {
	routes := make([]awgTunnelRoute, 0, len(allowedIPs))
	for _, cidr := range allowedIPs {
		_, ipnet, err := net.ParseCIDR(cidr)
		if err != nil {
			return nil, fmt.Errorf("invalid AllowedIP %q", cidr)
		}
		routes = append(routes, *ipnet)
	}
	return routes, nil
}

// planObfuscatedUnderlay resolves where the endpoint's traffic leaves before anything
// exists, failing closed when it cannot be found: the tunnel could not work anyway, and
// a plan built on a guess is a plan that loops the device's own packets into the tunnel
// it carries.
//
// A loopback endpoint pins no route at all. That is not a shortcut but the
// stream-carried case: the local table resolves loopback before any tunnel route is
// consulted and nothing captures it, while the transport's bring-up has already pinned
// the node's real upstream.
func (m *Manager) planObfuscatedUnderlay(ctx context.Context, settings obfSettings) (awgUnderlayPlan, error) {
	var plan awgUnderlayPlan
	ips, err := resolveEndpointAddresses(ctx, settings.endpoint, m.resolveHost)
	if err != nil {
		return plan, err
	}
	for _, ip := range ips {
		if ip.IsLoopback() {
			continue
		}
		via, err := m.routes.bestRoute(ip)
		if err != nil {
			return plan, fmt.Errorf("physical path for endpoint %s: %w", ip, err)
		}
		plan.routes = append(plan.routes, awgUnderlayRoute{dst: ip, via: via})
		plan.prefixes = append(plan.prefixes, hostPrefixFor(ip))
	}
	return plan, nil
}

// teardownObfuscated tears the userspace data plane down and sweeps the state the OS
// does not remove by itself.
//
// The device is closed before the underlay routes are deleted, and that order is the
// whole reason this teardown is so short. Closing it deletes the Wintun adapter; the
// tunnel's address, its routes, and its DNS settings are all properties of the adapter
// and go with it, so none of them is unwound here. What is left is the endpoint's
// underlay host route, which is bound to the physical interface and therefore outlives
// the adapter — while the tunnel routes are still installed it is the only thing keeping
// the device's own UDP out of the tunnel, so the adapter has to go first.
//
// The config file is removed only after every cleanup step succeeded, mirroring the
// native path: an incomplete cleanup keeps the file as the recovery handle, and it is
// also the only record of which underlay routes a restarted daemon should sweep.
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
	if len(errs) > 0 {
		return &protocol.OpError{Code: protocol.CodeInternal, Err: errors.Join(errs...)}
	}
	if err := removeConfigFile(m.configPath()); err != nil {
		return &protocol.OpError{Code: protocol.CodeInternal, Err: fmt.Errorf("remove config: %w", err)}
	}
	return nil
}

// clearObfuscatedUnderlay removes the underlay host routes an obfuscated tunnel pinned
// through the physical path.
//
// With no in-memory prefixes (a daemon restart lost them) they are derived from the
// lingering config file, because those routes outlive the process that installed them and
// nothing else records them. A failure to derive them is tolerated with a warning — the
// routes forward exactly where the main table would send that traffic anyway — while a
// failure to delete a known prefix is an error, keeping the config file behind as the
// retry handle.
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
	var errs []error
	for _, ip := range underlayAddresses(prefixes) {
		if err := m.routes.deleteHostRoute(ip); err != nil {
			errs = append(errs, fmt.Errorf("delete underlay route %s: %w", ip, err))
		}
	}
	if len(errs) > 0 {
		return &protocol.OpError{Code: protocol.CodeInternal, Err: errors.Join(errs...)}
	}
	return nil
}

// underlayAddresses turns the recorded prefixes back into the addresses to sweep.
//
// They are recorded in CIDR form ("203.0.113.10/32"), so they have to be parsed as
// prefixes rather than as addresses: net.ParseIP rejects the "/32", and a teardown that
// silently swept nothing would leave the one route that outlives the adapter installed
// on the physical interface forever, exempting the node from every future tunnel.
func underlayAddresses(prefixes []string) []net.IP {
	out := make([]net.IP, 0, len(prefixes))
	for _, prefix := range prefixes {
		if ip, _, err := net.ParseCIDR(prefix); err == nil {
			out = append(out, ip)
			continue
		}
		if ip := net.ParseIP(prefix); ip != nil {
			out = append(out, ip)
		}
	}
	return out
}

// underlayPrefixesFromConfig re-derives the endpoint host route prefixes from a
// lingering config file: only an obfuscated config pins underlay routes.
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
