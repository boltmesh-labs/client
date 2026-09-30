//go:build linux

// The stream transport rung: the tunnel's WireGuard endpoint points at a
// loopback address, and an in-process bridge (internal/stream) carries those
// datagrams to the real server inside a TLS session that middleboxes treat as
// ordinary HTTPS. It is the rung for networks that block or fingerprint
// WireGuard's own UDP.
//
// One thing makes or break this file, and it is about the transport's own
// egress:
//
//  1. The bypass route. The bridge dials from this process like any other
//     socket, so its packets follow the normal routing table — which, once the
//     tunnel is up, routes them *into* the tunnel they carry. A host route for
//     the real server through the physical gateway is installed before wg-quick
//     runs.
//  2. The extra tables. wg-quick's strict-mode policy rules steer unmarked
//     packets into its own table before the main one, so a main-table pin
//     alone is not enough: the same host route is installed in every table
//     an `not fwmark` rule selects (see [pinTransportTables]).
package tunnel

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"strconv"
	"strings"

	"boltmeshd/internal/protocol"
	"boltmeshd/internal/stream"
)

// streamClient is the part of the in-process transport the Manager drives:
// its lifetime, and nothing else. The datagram path, the TLS session, and
// every credential decision belong to internal/stream; keeping the seam to
// the lifecycle is what lets the privileged route work be tested without a
// node.
type streamClient interface {
	Start()
	Stop() error
}

// liveTransport is a running stream transport and the routes pinned for it.
// The bridge itself belongs to internal/stream; this is only the daemon's
// record of it and of the state teardown has to undo.
type liveTransport struct {
	spec   protocol.TransportSpec
	client streamClient
	// pins are the host routes installed for the transport's server, in
	// every table they were installed in. Teardown removes exactly these.
	pins []transportPin
	// via/dev is the physical path the pins use, resolved once at up.
	via string
	dev string
}

// transportPin is one installed bypass route. table 0 is the main table;
// a non-zero table is one of wg-quick's own routing tables.
type transportPin struct {
	prefix string
	v6     bool
	table  int
}

// bringUpTransport starts the in-process stream transport and pins its server
// through the physical path. Called before wg-quick so the very first
// transport packet is already routed outside the tunnel.
//
// The transport binds its loopback socket before this returns, so the tunnel
// never meets a refused port; the TLS session behind it comes up on its own
// and the tunnel's own handshake timer covers the wait. That ordering is why
// there is no readiness wait here.
func (m *Manager) bringUpTransport(ctx context.Context, spec *protocol.TransportSpec) error {
	if err := spec.Validate(); err != nil {
		return &protocol.OpError{Code: protocol.CodeBadConfig, Err: err}
	}
	ipTool, err := m.tool(ipBinary)
	if err != nil {
		return err
	}
	client, err := m.streamTransport(spec, m.noteStreamSession)
	if err != nil {
		return &protocol.OpError{Code: protocol.CodeBadConfig, Err: err}
	}

	host, port := splitServer(spec.Server)
	ips, err := m.resolveServer(ctx, host)
	if err != nil {
		return err
	}
	if len(ips) == 0 {
		return fmt.Errorf("stream transport server %s resolved to no addresses", host)
	}

	// Pin the first address through the physical path and start; the rest of
	// the pins reuse the same via/dev.
	tr := &liveTransport{spec: *spec, client: client}
	for _, ip := range ips {
		via, dev, err := m.physicalRouteFor(ctx, ipTool, ip)
		if err != nil {
			return err
		}
		tr.via, tr.dev = via, dev
		mainPin := transportPin{prefix: hostPrefixFor(ip), v6: ip.To4() == nil}
		if err := m.pinRouteVia(ctx, ipTool, mainPin, via, dev); err != nil {
			return err
		}
		// Record it as a main-table pin so teardown removes exactly what was
		// installed, in every table.
		tr.pins = append(tr.pins, mainPin)
	}

	// Record the live transport before starting it: one that fails to start
	// must still be stoppable by the recovery pass.
	m.transport = tr
	client.Start()
	slog.Info(
		"stream transport started",
		"interface", m.iface,
		"listen", spec.Listen,
		"deliver", spec.Deliver,
		"server", net.JoinHostPort(host, port),
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

// pinTransportTables installs the bypass route in every routing table
// wg-quick's policy rules select for *unmarked* packets. Called right after
// wg-quick up: the rules (and their tables) only exist from that point on.
func (m *Manager) pinTransportTables(ctx context.Context) error {
	tr := m.transport
	if tr == nil {
		return nil
	}
	ipTool, err := m.tool(ipBinary)
	if err != nil {
		return err
	}
	tables, err := m.unmarkedRouteTables(ctx, ipTool)
	if err != nil {
		return err
	}
	// Snapshot the prefixes and copy them per table: the loop appends to
	// tr.pins, which would otherwise be the slice it is ranging over.
	prefixes := make([]transportPin, 0, len(tr.pins))
	prefixes = append(prefixes, tr.pins...)
	for _, table := range tables {
		for _, pin := range prefixes {
			withTable := pin
			withTable.table = table
			if err := m.pinRoute(ctx, ipTool, withTable); err != nil {
				return err
			}
			tr.pins = append(tr.pins, withTable)
		}
	}
	return nil
}

// downTransport stops the transport and removes the routes pinned for it.
// Idempotent: a no-op when no transport is live, and every step is
// best-effort-tolerated so one failure cannot strand the rest of the teardown.
func (m *Manager) downTransport(ctx context.Context) error {
	tr := m.transport
	if tr == nil {
		return nil
	}
	m.transport = nil

	var errs []error
	ipTool, ipErr := m.tool(ipBinary)
	// The transport stops first: once it is gone nothing can use the pinned
	// routes, so removing them is the safe order.
	if tr.client != nil {
		if err := tr.client.Stop(); err != nil {
			errs = append(errs, fmt.Errorf("stop stream transport: %w", err))
		}
	}
	if ipErr != nil {
		errs = append(errs, ipErr)
	} else {
		for _, pin := range tr.pins {
			if err := m.unpinRoute(ctx, ipTool, pin); err != nil {
				errs = append(errs, err)
			}
		}
	}
	if len(errs) > 0 {
		return &protocol.OpError{Code: protocol.CodeInternal, Err: errors.Join(errs...)}
	}
	return nil
}

// transportErrorCode reports the protocol code a transport failure should
// surface as. Only a bad-config error carries its own; anything else is a
// daemon fault by default. The client's reaction depends on the distinction —
// a bad spec means it must not retry this region, an internal error may be
// transient — so it is worth preserving rather than flattening.
func transportErrorCode(err error) string {
	var opErr *protocol.OpError
	if errors.As(err, &opErr) && opErr.Code == protocol.CodeBadConfig {
		return protocol.CodeBadConfig
	}
	return protocol.CodeInternal
}

// noteStreamSession records the transport's session transitions in the log.
//
// A session that will not come up is the interesting case, and it is *not* a
// tunnel failure: the client already demotes on its own health policy, and
// this path has no view of the tunnel's state to act on. So it logs and
// nothing else — the daemon does not second-guess the ladder.
func (m *Manager) noteStreamSession(up bool, err error) {
	if up {
		slog.Info("stream transport session established", "interface", m.iface)
		return
	}
	slog.Warn("stream transport session unavailable", "interface", m.iface, "error", err)
}

// pinRoute installs (replacing any existing) the bypass host route for one
// address in the main table or a named one.
func (m *Manager) pinRoute(ctx context.Context, ipTool string, pin transportPin) error {
	return m.pinRouteVia(ctx, ipTool, pin, m.transport.via, m.transport.dev)
}

// pinRouteVia is [Manager.pinRoute] with an explicit physical path, so the
// first pin works before the live transport is recorded.
func (m *Manager) pinRouteVia(ctx context.Context, ipTool string, pin transportPin, via, dev string) error {
	args := []string{"route", "replace", pin.prefix}
	if pin.v6 {
		args = append([]string{"-6"}, args...)
	}
	if via != "" {
		args = append(args, "via", via)
	}
	args = append(args, "dev", dev)
	if pin.table != 0 {
		args = append(args, "table", strconv.Itoa(pin.table))
	}
	if err := m.runWithTimeout(ctx, ipTool, args...); err != nil {
		return fmt.Errorf("pin bypass route %s: %w", pin.prefix, err)
	}
	return nil
}

// unpinRoute removes one bypass host route, tolerating an already-gone route
// (the goal is "no bypass route left", not one command per pin).
func (m *Manager) unpinRoute(ctx context.Context, ipTool string, pin transportPin) error {
	args := []string{"route", "del", pin.prefix}
	if pin.v6 {
		args = append([]string{"-6"}, args...)
	}
	if pin.table != 0 {
		args = append(args, "table", strconv.Itoa(pin.table))
	}
	if err := m.runWithTimeout(ctx, ipTool, args...); err != nil {
		if routeMissing(err) {
			return nil
		}
		return fmt.Errorf("remove bypass route %s: %w", pin.prefix, err)
	}
	return nil
}

// unmarkedRouteTables returns the non-main routing tables that wg-quick's
// policy rules select for packets *without* the interface's fwmark — which is
// every packet the transport's own dialer sends. Parsed from `ip rule show`
// rather than predicted from the interface name, so it stays correct across
// wg-quick versions and table-number choices.
func (m *Manager) unmarkedRouteTables(ctx context.Context, ipTool string) ([]int, error) {
	out, err := m.run(ctx, ipTool, "rule", "show")
	if err != nil {
		return nil, fmt.Errorf("read routing rules: %w", err)
	}
	return parseUnmarkedRuleTables(string(out)), nil
}

// parseUnmarkedRuleTables extracts the table of every `not … fwmark <mark> …
// table <id>` / `… lookup <id>` rule. A rule that selects packets *with* the
// mark (the device's own handshake path) is skipped: only the unmarked path
// is the liveTransport's, and wg-quick already handles the marked one.
func parseUnmarkedRuleTables(rules string) []int {
	var tables []int
	seen := map[int]bool{}
	for _, line := range strings.Split(rules, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 || !containsToken(fields, "not") {
			continue
		}
		// Require an fwmark selector: `not from all lookup local` is a real
		// rule but not one of the interface's tables.
		markIdx := indexToken(fields, "fwmark")
		if markIdx < 0 {
			continue
		}
		tableIdx := indexToken(fields, "table")
		keyword := "table"
		if tableIdx < 0 {
			tableIdx = indexToken(fields, "lookup")
			keyword = "lookup"
		}
		if tableIdx < 0 || tableIdx+1 >= len(fields) || tableIdx <= markIdx {
			continue
		}
		if keyword == "lookup" && fields[tableIdx-1] == "" {
			continue
		}
		id, err := strconv.Atoi(fields[tableIdx+1])
		if err != nil || id == 0 || seen[id] {
			continue // 0 is the main table (or "local"), already pinned
		}
		seen[id] = true
		tables = append(tables, id)
	}
	return tables
}

func containsToken(fields []string, want string) bool {
	return indexToken(fields, want) >= 0
}

func indexToken(fields []string, want string) int {
	for i, f := range fields {
		if f == want {
			return i
		}
	}
	return -1
}

// splitServer splits the transport's server into host and port. A bare host is
// legal (the envelope validation already rejected an empty or malformed one);
// stream transports all dial TLS, so 443 is the implied port.
func splitServer(server string) (string, string) {
	if host, port, err := net.SplitHostPort(server); err == nil {
		return strings.TrimSpace(host), port
	}
	return strings.TrimSpace(server), "443"
}

// resolveServer turns the server host into addresses. A literal IP needs no
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
