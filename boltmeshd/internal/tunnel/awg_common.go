//go:build linux || windows

// This file holds the parts of the userspace AmneziaWG data plane that do not
// depend on the operating system: the device seam, the obfuscation settings a
// backend must apply itself, and the status projection.
//
// They live here rather than in either backend because both need them and neither
// owns them. The obfuscated path on Linux runs the device over a /dev/net/tun;
// on Windows it runs the same device over a Wintun adapter, because the
// WireGuard-for-Windows kernel service has no concept of the obfuscation
// directives. What differs is the adapter, the address/route plumbing and the
// resolver -- all of which are per-backend. The crypto, the wire format, and the
// config translation are identical, and duplicating those would be duplicating
// the part that has to match the node byte for byte.

package tunnel

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"strconv"
	"strings"

	awgconn "github.com/amnezia-vpn/amneziawg-go/v3/conn"
	awgdevice "github.com/amnezia-vpn/amneziawg-go/v3/device"
	awgtun "github.com/amnezia-vpn/amneziawg-go/v3/tun"

	"boltmeshd/internal/protocol"
)

const (
	// awgDefaultMTU matches the value the native path's wg-quick file would
	// derive for a WireGuard tunnel on an ordinary 1500-byte link.
	awgDefaultMTU = 1420

	// awgDefaultRouteMetric outranks any pre-existing default route so a
	// strict-mode tunnel (0.0.0.0/0, ::/0) claims the default without
	// replacing the physical one.
	awgDefaultRouteMetric = "1"
)

// awgObfuscated reports whether a validated config carries the AmneziaWG
// obfuscation directives. [config.Validate] enforces the all-or-none rule, so
// one directive present means the complete set is; this only decides which data
// plane the config belongs to.
func awgObfuscated(directives []uapiDirective) bool {
	for _, d := range directives {
		if d.section == "interface" && awgDirectiveNames[d.key] {
			return true
		}
	}
	return false
}

// awgDevice is the seam over the in-process AmneziaWG device: UAPI
// request/response framing translated into method calls, with the close ordering
// owned by the adapter.
type awgDevice interface {
	configure(ctx context.Context, body []byte) error
	dump(ctx context.Context) ([]byte, error)
	close() error
}

// newAwgDevice wires a real AmneziaWG device to its adapter. The device owns the
// adapter from here on: closing it closes both.
//
// A nil adapter is refused rather than passed through: the device constructor
// dereferences it immediately, so the alternative is a panic inside a privileged
// daemon with a stack that names neither the backend nor the call. Both backends
// reach this through a seam that can fail, and making the adapter's own
// precondition part of that is where the error belongs.
func newAwgDevice(tunDev awgtun.Device) (awgDevice, error) {
	if tunDev == nil {
		return nil, errors.New("amneziawg: nil adapter")
	}
	logger := &awgdevice.Logger{
		// Route the data plane's own diagnostics into the daemon log instead
		// of discarding them, so a device-side failure is not invisible.
		Verbosef: func(format string, args ...any) {
			slog.Debug("amneziawg: "+format, args...)
		},
		Errorf: func(format string, args ...any) {
			slog.Error("amneziawg: "+format, args...)
		},
	}
	return &goAwgDevice{
		inner: awgdevice.NewDevice(tunDev, awgconn.NewDefaultBind(), logger),
		tun:   tunDev,
	}, nil
}

// goAwgDevice adapts an AmneziaWG device to the [awgDevice] seam.
type goAwgDevice struct {
	inner *awgdevice.Device
	tun   awgtun.Device
}

func (d *goAwgDevice) configure(ctx context.Context, body []byte) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := d.inner.IpcSet(string(body)); err != nil {
		return err
	}
	// The device is brought up here, explicitly, and not left to an event.
	//
	// A fresh AmneziaWG device starts down, and a peer is only started when the device
	// is up -- so until this call the device reads its adapter, finds every packet
	// belongs to a peer that was never started, and drops them. No handshake is ever
	// attempted, so every counter stays at zero and the tunnel looks configured.
	//
	// Linux does not need the call: its adapter reports a link-up event, and the
	// device's own event reader brings it up in response. Windows' Wintun adapter never
	// reports one -- its event channel carries MTU updates and nothing else -- so there
	// the device would stay down for the life of the process with every other step
	// reporting success. Relying on a platform event one backend does not deliver is
	// the defect; this is the same end state either way, and Up is idempotent.
	return d.inner.Up()
}

func (d *goAwgDevice) dump(ctx context.Context) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	out, err := d.inner.IpcGet()
	if err != nil {
		return nil, err
	}
	return []byte(out), nil
}

func (d *goAwgDevice) close() error {
	// Device first, then the adapter: the reverse order would leave the data
	// plane reading a closed adapter. Closing the adapter removes the interface;
	// the OS flushes its routes with it.
	d.inner.Close()
	return d.tun.Close()
}

// obfSettings are the parts of an obfuscated wg-quick config the device
// protocol does not carry and the backend must apply itself: the address, the
// resolver, the peer's AllowedIPs, the endpoint (the underlay host route needs
// it) and the MTU (the adapter is created with it).
type obfSettings struct {
	address    string
	dns        string
	allowedIPs []string
	endpoint   string
	mtu        int
}

// parseObfuscatedSettings pulls the backend-applied settings out of a validated
// obfuscated config. It is separate from [ConfigToUAPI] because the device
// rejects these directives as unknown, yet the backend still needs them. The
// endpoint is required: the underlay host route is what keeps the device's own
// UDP out of the tunnel, and a config without it cannot come up safely on this
// data plane.
//
// The default MTU reserves the transport padding (S4) on top of the fixed
// encapsulation awgDefaultMTU already accounts for. AmneziaWG prepends S4 bytes
// to every transport packet (amneziawg-go device/send.go), so a full-size
// packet padded by the server's generated S4 would otherwise exceed a
// 1500-byte underlay and every send fails with EMSGSIZE. An explicit MTU line
// still wins: a caller that knows its path sets it.
func parseObfuscatedSettings(text string) (obfSettings, error) {
	var settings obfSettings
	// S4 pads every transport packet ahead of WireGuard's own encapsulation.
	// Zero when absent — a config that pads nothing.
	padding := 0
	mtuSet := false
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
		case d.section == "interface" && d.key == "s4":
			s4, err := strconv.Atoi(strings.TrimSpace(d.value))
			if err != nil || s4 < 0 {
				return settings, fmt.Errorf("invalid S4 %q", d.value)
			}
			padding = s4
		case d.section == "interface" && d.key == "mtu":
			mtu, err := strconv.Atoi(strings.TrimSpace(d.value))
			if err != nil || mtu < 576 || mtu > 65535 {
				return settings, fmt.Errorf("invalid Mtu %q", d.value)
			}
			settings.mtu = mtu
			mtuSet = true
		case d.section == "peer" && d.key == "allowedips":
			for _, cidr := range strings.Split(d.value, ",") {
				if cidr = strings.TrimSpace(cidr); cidr != "" {
					settings.allowedIPs = append(settings.allowedIPs, cidr)
				}
			}
		case d.section == "peer" && d.key == "endpoint":
			if settings.endpoint == "" {
				endpoint, err := normalizeEndpoint(d.value)
				if err != nil {
					return settings, err
				}
				settings.endpoint = endpoint
			}
		}
	}
	if !mtuSet {
		settings.mtu = awgDefaultMTU - padding
		if settings.mtu < 576 {
			settings.mtu = 576
		}
	}
	if settings.address == "" {
		return settings, errors.New("config is missing [Interface] Address")
	}
	if settings.endpoint == "" {
		return settings, errors.New("config is missing [Peer] Endpoint")
	}
	return settings, nil
}

// hostPrefixFor renders the host route prefix for one endpoint address.
func hostPrefixFor(ip net.IP) string {
	if ip.To4() == nil {
		return ip.String() + "/128"
	}
	return ip.String() + "/32"
}

// resolveEndpointAddresses resolves an obfuscated config's endpoint to the
// addresses whose underlay routes keep the device's own UDP out of the tunnel.
//
// A literal is used as-is. A loopback address resolves to itself and needs no
// underlay route at all: loopback is resolved by the local table before any
// tunnel route and is never captured by one, which is exactly the situation for a
// stream-carried tunnel, whose peer endpoint is the bridge's loopback address
// while the real upstream is pinned separately by the transport's own bring-up.
func resolveEndpointAddresses(ctx context.Context, endpoint string, resolve func(context.Context, string) ([]net.IP, error)) ([]net.IP, error) {
	host, _, err := net.SplitHostPort(endpoint)
	if err != nil {
		return nil, fmt.Errorf("invalid Endpoint %q: %w", endpoint, err)
	}
	if literal := net.ParseIP(host); literal != nil {
		return []net.IP{literal}, nil
	}
	ips, err := resolve(ctx, host)
	if err != nil {
		return nil, fmt.Errorf("resolve endpoint %s: %w", host, err)
	}
	if len(ips) == 0 {
		return nil, fmt.Errorf("endpoint %s resolved to no addresses", host)
	}
	return ips, nil
}

// obfuscatedUAPIEndpoint rewrites the peer's endpoint in a rendered UAPI body to
// the literal address the obfuscated data plane can be configured with, given the
// addresses [endpoint] resolved to.
//
// A name is never handed to the device: amneziawg-go parses a peer endpoint
// through conn.Bind.ParseEndpoint, and neither bind resolves one — StdNetBind is
// netip.ParseAddrPort, and WinRingBind is getaddrinfo with AI_NUMERICHOST, which
// rejects a name with WSAHOST_NOT_FOUND. The daemon has already resolved the
// endpoint for its underlay route, so the literal goes to the device instead of
// the name, which also makes the address it dials provably one the underlay plan
// pinned a route for.
//
// An endpoint that is already an IP literal is left alone, which covers both a node
// handed out by address and the stream-carried loopback bridge. A name that
// resolved to nothing but loopback is an error rather than a pass-through, so the
// invariant holds unconditionally: this body never carries a name.
//
// IPv4 wins over IPv6 when the answer holds both. A dual-A/AAAA record on a host
// with broken v6 connectivity is the common shape, and resolver order is not a
// statement about which family is reachable: RFC 6724 sorting puts v6 first on most
// hosts, so picking the first answer would dial an address the network cannot carry
// while a working v4 pin sits in the same underlay plan unused. This mirrors the
// Android layer, which prefers v4 for the same DNS64 and IPv6-NAT reasons
// (`InetEndpoint.getResolved`). A v6-only node still gets its v6: the fallback is
// the first non-loopback answer, not a v4 requirement.
func obfuscatedUAPIEndpoint(body []byte, endpoint string, ips []net.IP) ([]byte, error) {
	host, _, err := net.SplitHostPort(endpoint)
	if err != nil {
		return nil, fmt.Errorf("invalid Endpoint %q: %w", endpoint, err)
	}
	if net.ParseIP(host) != nil {
		return body, nil
	}
	addr := dialAddress(ips)
	if addr == "" {
		return nil, fmt.Errorf("endpoint %s resolved only to loopback", host)
	}
	return setUAPIEndpoint(body, host, addr)
}

// dialAddress picks the address the device should dial from a resolved set: the
// first IPv4 answer, or the first non-loopback answer when there is none.
//
// Loopback is skipped in both passes. It is the stream-carried shape, where the
// peer's endpoint is the local bridge and the transport pinned the node's real
// upstream — and a name that resolved only to loopback is a configuration that
// cannot work, which the caller reports rather than dialing.
func dialAddress(ips []net.IP) string {
	for _, ip := range ips {
		if ip.To4() != nil && !ip.IsLoopback() {
			return ip.String()
		}
	}
	for _, ip := range ips {
		if !ip.IsLoopback() {
			return ip.String()
		}
	}
	return ""
}

// setUAPIEndpoint replaces the host of every peer endpoint in a rendered UAPI body
// that names [host] with [addr], keeping each line's own port.
//
// Only matching lines are rewritten, so a config whose other peers dial elsewhere
// stays correct rather than being repointed. A body with no matching line is an
// error: it would leave the name in place for the device to reject.
func setUAPIEndpoint(body []byte, host, addr string) ([]byte, error) {
	lines := strings.Split(string(body), "\n")
	matched := false
	for i, line := range lines {
		value, ok := strings.CutPrefix(line, "endpoint=")
		if !ok {
			continue
		}
		lineHost, port, err := net.SplitHostPort(value)
		if err != nil || !strings.EqualFold(lineHost, host) {
			continue
		}
		lines[i] = "endpoint=" + net.JoinHostPort(addr, port)
		matched = true
	}
	if !matched {
		return nil, fmt.Errorf("config carries no endpoint for %s", host)
	}
	return []byte(strings.Join(lines, "\n")), nil
}

// underlayPrefixesFor derives the underlay host route prefixes an obfuscated
// config pinned, for a teardown that has lost its in-memory state. Loopback
// endpoints are skipped: they never had one.
func underlayPrefixesFor(ips []net.IP) []string {
	prefixes := make([]string, 0, len(ips))
	for _, ip := range ips {
		if ip.IsLoopback() {
			continue
		}
		prefixes = append(prefixes, hostPrefixFor(ip))
	}
	return prefixes
}

// readObfuscatedStatus projects the live device's dump into a status. A dump
// failure is unknown, never proof of death: the caller must not mistake it
// for a disconnected tunnel.
func readObfuscatedStatus(ctx context.Context, iface string, dev awgDevice) (*protocol.Status, error) {
	if err := ctx.Err(); err != nil {
		return nil, statusReadError(err)
	}
	st := &protocol.Status{Interface: iface, Stage: protocol.StageDisconnected}
	data, err := dev.dump(ctx)
	if err != nil {
		return nil, &protocol.OpError{
			Code: protocol.CodeInternal,
			Err:  fmt.Errorf("dump obfuscated device: %w", err),
		}
	}
	peers, err := ParseUAPIPeersText(data)
	if err != nil {
		return nil, &protocol.OpError{
			Code: protocol.CodeInternal,
			Err:  fmt.Errorf("parse obfuscated device state: %w", err),
		}
	}
	st.Up = true
	st.Stage = protocol.StageConnected
	applyPeers(st, peers)
	return st, nil
}
