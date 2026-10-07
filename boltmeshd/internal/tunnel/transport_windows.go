//go:build windows

// The stream transport rung on Windows: the tunnel's WireGuard endpoint points
// at a loopback address, and an in-process bridge (the shared stream package) carries
// those datagrams to the real node inside a TLS session that middleboxes treat
// as ordinary HTTPS.
//
// The bridge itself is platform-independent — the shared stream package has no build tags
// and compiles here unchanged. What this file owns is everything around it:
//
//  1. The bypass route. The bridge dials from the daemon like any other socket,
//     so once the tunnel adapter is up its packets follow the routing table into
//     the tunnel they carry. A host route for the node's real address through the
//     physical interface has to exist first.
//  2. When it exists. Before the tunnel service starts, always: Windows matches
//     the longest prefix first, so once the service installs its 0.0.0.0/0
//     route the only thing that can keep the transport's egress outside the
//     tunnel is a more specific entry, and there is a window between the
//     service coming up and the tunnel being usable that must not include the
//     bridge's first packets.
//
// Unlike Linux there is no fwmark policy-rule pass to mirror. The service's own
// route is a default route, and a /32 beats it on specificity alone, so
// [Manager.bringUpTransport] resolves the physical path once and pins it.
package tunnel

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"

	"boltmesh/stream"
	"boltmeshd/internal/protocol"
)

// streamClient is the part of the in-process transport the Manager drives: its
// lifetime, and nothing else. The datagram path, the TLS session, and every
// credential decision belong to the shared stream package; keeping the seam to the
// lifecycle is what lets the privileged route work be tested without a node.
type streamClient interface {
	Start()
	Stop() error
}

// liveTransport is a running stream transport and the destinations pinned for
// it. The bridge itself belongs to the shared stream package; this is only the daemon's
// record of it and of the state teardown has to undo.
type liveTransport struct {
	spec   protocol.TransportSpec
	client streamClient
	// pinned are the destinations a bypass route was installed for, in every
	// family. Teardown removes exactly these. Unlike Linux there is no per-table
	// fan-out: Windows has no fwmark-selected tables, so a /32 is installed
	// once and is specific enough to win on its own.
	pinned []net.IP
}

// bringUpTransport starts the in-process stream transport and pins its server
// through the physical path. Called before the tunnel service starts, so the
// very first transport packet is already routed outside the tunnel.
//
// The transport binds its loopback socket before this returns, so the tunnel
// never meets a refused port; the TLS session behind it comes up on its own and
// the tunnel's own handshake timer covers the wait. That ordering is why there
// is no readiness wait here.
func (m *Manager) bringUpTransport(ctx context.Context, spec *protocol.TransportSpec) error {
	if err := spec.Validate(); err != nil {
		return &protocol.OpError{Code: protocol.CodeBadConfig, Err: err}
	}
	client, err := m.streamTransport(spec, m.noteStreamSession)
	if err != nil {
		return &protocol.OpError{Code: protocol.CodeBadConfig, Err: err}
	}

	host, _ := splitServer(spec.Server)
	ips, err := m.resolveServer(ctx, host)
	if err != nil {
		return err
	}
	if len(ips) == 0 {
		return fmt.Errorf("stream transport server %s resolved to no addresses", host)
	}

	tr := &liveTransport{spec: *spec, client: client}
	for _, ip := range ips {
		// A loopback destination is resolved by the local table and is never
		// captured by a tunnel route, so it needs no pin — the same reasoning
		// the Linux obfuscated path applies to its own loopback endpoint.
		if ip.IsLoopback() {
			continue
		}
		route, err := m.routes.bestRoute(ip)
		if err != nil {
			return err
		}
		tr.pinned = append(tr.pinned, ip)
		// Record the pin before installing it, so a crash in between leaves a
		// route the record names rather than one nothing accounts for.
		if err := m.recordTransportPins(tr.pinned); err != nil {
			return err
		}
		if err := m.routes.addHostRoute(ip, route); err != nil {
			return err
		}
	}

	// Record the live transport before starting it: one that fails to start
	// must still be stoppable by the recovery pass. Seed the session state
	// to "establishing" here rather than waiting for the first OnSession
	// callback: the bridge reports a session transition only once a session
	// has *ended*, so the whole first establishment window — the window the
	// client's grace covers — would otherwise read as "no stream transport
	// at all".
	m.transport = tr
	m.mu.Lock()
	m.streamSession = new(bool)
	m.mu.Unlock()
	client.Start()
	slog.Info(
		"stream transport started",
		"interface", m.iface,
		"listen", spec.Listen,
		"deliver", spec.Deliver,
		"server", spec.Server,
	)
	return nil
}

// newStreamClient builds the in-process transport from a validated spec. The
// credentials are decoded here, once, and never logged: the log line above
// names the addresses only.
func newStreamClient(spec *protocol.TransportSpec, onSession func(bool, error)) (streamClient, error) {
	psk, err := spec.StreamPSK()
	if err != nil {
		return nil, err
	}
	clientID, err := spec.StreamClientID()
	if err != nil {
		return nil, err
	}
	pins, err := spec.StreamSPKIPins()
	if err != nil {
		return nil, err
	}
	return stream.NewClient(stream.ClientConfig{
		ListenAddr:  spec.Listen,
		DeliverAddr: spec.Deliver,
		ServerAddr:  spec.Server,
		ServerName:  spec.ServerName,
		SPKIPins:    pins,
		PSK:         psk,
		ClientID:    clientID,
		OnSession:   onSession,
	})
}

// downTransport stops the transport and removes the routes pinned for it.
// Idempotent: a no-op when no transport is live, and every step is
// best-effort-tolerated so one failure cannot strand the rest of the teardown.
//
// The pin set comes from the on-disk record when there is no live transport,
// not only from memory: a restart loses [liveTransport] while the routes it
// installed survive, and a memory-only sweep would strand a /32 that silently
// exempts the node from every tunnel after it.
func (m *Manager) downTransport(ctx context.Context) error {
	tr := m.transport
	if tr == nil && !m.transportPinsRecorded() {
		return nil
	}
	// Drop the session state before the transport pointer: from the
	// moment teardown begins the status must not report a live
	// transport's session, so a stale "established" can never
	// outlive the transport it came from. The transport pointer is
	// gate-guarded; this field is mu-guarded, so the status reader
	// and the teardown agree on it without either taking the gate.
	m.mu.Lock()
	m.streamSession = nil
	m.mu.Unlock()
	m.transport = nil

	var errs []error
	// The transport stops first: once it is gone nothing can use the pinned
	// routes, so removing them is the safe order.
	if tr != nil && tr.client != nil {
		if err := tr.client.Stop(); err != nil {
			errs = append(errs, fmt.Errorf("stop stream transport: %w", err))
		}
	}
	if err := ctx.Err(); err != nil {
		errs = append(errs, err)
	} else {
		for _, ip := range m.recordedTransportPins() {
			if err := m.routes.deleteHostRoute(ip); err != nil {
				errs = append(errs, err)
			}
		}
	}
	if len(errs) > 0 {
		return &protocol.OpError{Code: protocol.CodeInternal, Err: errors.Join(errs...)}
	}
	return m.removeTransportPinRecord()
}

// noteStreamSession records the transport's session transitions in the log
// and in the status the client reads.
//
// A session that will not come up is the interesting case, and it is *not* a
// tunnel failure: the client already demotes on its own health policy, and this
// path has no view of the tunnel's state to act on. So the daemon does not
// second-guess the ladder — but it does publish the transition, because the
// client's health policy needs to tell a stream rung still coming up (no
// completed end-to-end handshake yet) from one whose path has died.
//
// The nil guard keeps a teardown's callbacks from resurrecting state:
// downTransport clears streamSession before it stops the client, so a
// session the client reports on its way down finds nothing to write to
// and is dropped.
func (m *Manager) noteStreamSession(up bool, err error) {
	m.mu.Lock()
	if m.streamSession != nil {
		v := up
		m.streamSession = &v
	}
	m.mu.Unlock()
	if up {
		slog.Info("stream transport session established", "interface", m.iface)
		return
	}
	slog.Warn("stream transport session unavailable", "interface", m.iface, "error", err)
}

// recordTransportPins writes the pin record from the live set. A Windows pin is
// just the destination address: the /32 is installed once and wins on
// specificity, with no per-table fan-out to record.
func (m *Manager) recordTransportPins(pins []net.IP) error {
	lines := make([]string, 0, len(pins))
	for _, ip := range pins {
		lines = append(lines, encodePin(ip.String(), 0))
	}
	return m.writeTransportPinRecord(lines)
}

// recordedTransportPins reads the pin record back into the sweep shape. A line
// that does not decode to an address is skipped rather than failing the read: a
// partial sweep beats none, and [windowsRoutes.deleteHostRoute] already treats
// an absent route as success.
func (m *Manager) recordedTransportPins() []net.IP {
	lines := m.readTransportPinRecord()
	pins := make([]net.IP, 0, len(lines))
	for _, line := range lines {
		prefix, _, ok := decodePin(line)
		if !ok {
			continue
		}
		ip := net.ParseIP(prefix)
		if ip == nil {
			continue
		}
		pins = append(pins, ip)
	}
	return pins
}

// transportErrorCode reports the protocol code a transport failure should
// surface as. Only a bad-config error carries its own; anything else is a
// daemon fault by default. The client's reaction depends on the distinction — a
// bad spec means it must not retry this region, an internal error may be
// transient — so it is worth preserving rather than flattening.
func transportErrorCode(err error) string {
	var opErr *protocol.OpError
	if errors.As(err, &opErr) && opErr.Code == protocol.CodeBadConfig {
		return protocol.CodeBadConfig
	}
	return protocol.CodeInternal
}

// resolveServer // resolveServer turns the server host into addresses. A literal IP needs no
// resolver; a hostname does, and the *current* (physical) resolver is the
// right one: the transport comes up before any tunnel DNS state exists.
func (m *Manager) resolveServer(ctx context.Context, host string) ([]net.IP, error) {
	if literal := net.ParseIP(host); literal != nil {
		return []net.IP{literal}, nil
	}
	resolver := m.resolveHost
	if resolver == nil {
		resolver = func(ctx context.Context, host string) ([]net.IP, error) {
			return net.DefaultResolver.LookupIP(ctx, "ip", host)
		}
	}
	ips, err := resolver(ctx, host)
	if err != nil {
		return nil, fmt.Errorf("resolve stream transport upstream %s: %w", host, err)
	}
	return ips, nil
}
