//go:build linux

// The stream transport rung: the tunnel's WireGuard endpoint points at a
// loopback address, and a locally-run forwarder carries those datagrams to
// the real server over a stream that middleboxes treat as ordinary TLS. It
// is the rung for networks that block or fingerprint WireGuard's own UDP.
//
// Two things make or break this file, and both are about the forwarder's own
// egress:
//
//  1. The bypass route. The forwarder is an ordinary process, so its packets
//     follow the normal routing table — which, once the tunnel is up, routes
//     them *into* the tunnel they carry. A host route for the real server
//     through the physical gateway is installed before wg-quick runs.
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
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"boltmeshd/internal/protocol"
)

const (
	// forwarderReadyTimeout bounds how long an up waits for the forwarder's
	// local listener. It is started explicitly, so this only has to cover
	// process exec plus the tool's own startup; a forwarder that never binds
	// is a broken install, not a slow one.
	forwarderReadyTimeout = 5 * time.Second
	// forwarderReadyInterval is the poll cadence for the listener.
	forwarderReadyInterval = 100 * time.Millisecond
	// forwarderStopGrace bounds the wait for a forwarder that was asked to
	// stop before it is killed, so a clean exit is observed and an
	// unresponsive one cannot hold the tunnel teardown.
	forwarderStopGrace = 2 * time.Second
	// transportConfigSuffix names the forwarder's root-only document next to
	// the wg-quick config, so one directory owns the tunnel's state.
	transportConfigSuffix = ".forwarder.json"
)

// forwarder is a running stream forwarder and the routes pinned for it.
type forwarder struct {
	spec       protocol.TransportSpec
	configPath string
	stop       func() error
	// pins are the host routes installed for the forwarder's upstream, in
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

// forwarderConfigPath is where the forwarder's document is written, inside
// the daemon-owned config directory and root-only like the wg-quick config.
func (m *Manager) forwarderConfigPath() string {
	return m.configPath() + transportConfigSuffix
}

// bringUpTransport writes the forwarder's document, pins its upstream through
// the physical path, starts the forwarder, and waits for it to listen. Called
// before wg-quick so the very first forwarder packet is already routed
// outside the tunnel.
func (m *Manager) bringUpTransport(ctx context.Context, spec *protocol.TransportSpec) error {
	if err := spec.Validate(); err != nil {
		return &protocol.OpError{Code: protocol.CodeBadConfig, Err: err}
	}
	ipTool, err := m.tool(ipBinary)
	if err != nil {
		return err
	}
	// Resolve the binary before writing anything: a missing tool must not
	// leave a privileged config behind. Resolution is against the fixed tool
	// directories, never PATH — the daemon runs it as root.
	binary, err := m.tool(spec.Binary)
	if err != nil {
		return err
	}

	host, _ := splitUpstream(spec.Upstream)
	ips, err := m.resolveUpstream(ctx, host)
	if err != nil {
		return err
	}
	if len(ips) == 0 {
		return fmt.Errorf("stream transport upstream %s resolved to no addresses", host)
	}

	if err := os.MkdirAll(m.dir, 0o755); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}
	configPath := m.forwarderConfigPath()
	if err := os.WriteFile(configPath, []byte(spec.Config), 0o600); err != nil {
		return fmt.Errorf("write forwarder config: %w", err)
	}

	// Pin the first address through the physical path and start; the rest of
	// the pins reuse the same via/dev.
	fwd := &forwarder{spec: *spec, configPath: configPath}
	for _, ip := range ips {
		via, dev, err := m.physicalRouteFor(ctx, ipTool, ip)
		if err != nil {
			return err
		}
		fwd.via, fwd.dev = via, dev
		mainPin := transportPin{prefix: hostPrefixFor(ip), v6: ip.To4() == nil}
		if err := m.pinRouteVia(ctx, ipTool, mainPin, via, dev); err != nil {
			return err
		}
		// Record it as a main-table pin so teardown removes exactly what was
		// installed, in every table.
		fwd.pins = append(fwd.pins, mainPin)
	}

	stop, err := m.startForwarder(ctx, binary, configPath)
	if err != nil {
		return fmt.Errorf("start forwarder: %w", err)
	}
	fwd.stop = stop
	// Record the live forwarder *before* waiting for readiness: a forwarder
	// that never binds must still be stoppable by the recovery pass.
	m.fwd = fwd
	if err := m.waitForwarder(ctx, spec.Listen); err != nil {
		return fmt.Errorf("forwarder did not start listening on %s: %w", spec.Listen, err)
	}
	slog.Info(
		"stream forwarder started",
		"interface", m.iface,
		"listen", spec.Listen,
		"binary", spec.Binary,
	)
	return nil
}

// pinTransportTables installs the bypass route in every routing table
// wg-quick's policy rules select for *unmarked* packets. Called right after
// wg-quick up: the rules (and their tables) only exist from that point on.
func (m *Manager) pinTransportTables(ctx context.Context) error {
	fwd := m.fwd
	if fwd == nil {
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
	// fwd.pins, which would otherwise be the slice it is ranging over.
	prefixes := make([]transportPin, 0, len(fwd.pins))
	prefixes = append(prefixes, fwd.pins...)
	for _, table := range tables {
		for _, pin := range prefixes {
			withTable := pin
			withTable.table = table
			if err := m.pinRoute(ctx, ipTool, withTable); err != nil {
				return err
			}
			fwd.pins = append(fwd.pins, withTable)
		}
	}
	return nil
}

// downTransport stops the forwarder and removes the routes pinned for it,
// then deletes its root-only document. Idempotent: a no-op when no transport
// is live, and every step is best-effort-tolerated so one failure cannot
// strand the rest of the teardown.
func (m *Manager) downTransport(ctx context.Context) error {
	fwd := m.fwd
	if fwd == nil {
		return nil
	}
	m.fwd = nil

	var errs []error
	ipTool, ipErr := m.tool(ipBinary)
	// The forwarder stops first: once it is gone nothing can use the pinned
	// routes, so removing them is the safe order.
	if fwd.stop != nil {
		if err := fwd.stop(); err != nil {
			errs = append(errs, fmt.Errorf("stop forwarder: %w", err))
		}
	}
	if ipErr != nil {
		errs = append(errs, ipErr)
	} else {
		for _, pin := range fwd.pins {
			if err := m.unpinRoute(ctx, ipTool, pin); err != nil {
				errs = append(errs, err)
			}
		}
	}
	if err := os.Remove(fwd.configPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		errs = append(errs, fmt.Errorf("remove forwarder config: %w", err))
	}
	if len(errs) > 0 {
		return &protocol.OpError{Code: protocol.CodeInternal, Err: errors.Join(errs...)}
	}
	return nil
}

// pinRoute installs (replacing any existing) the bypass host route for one
// address in the main table or a named one.
func (m *Manager) pinRoute(ctx context.Context, ipTool string, pin transportPin) error {
	return m.pinRouteVia(ctx, ipTool, pin, m.fwd.via, m.fwd.dev)
}

// pinRouteVia is [Manager.pinRoute] with an explicit physical path, so the
// first pin works before the live forwarder is recorded.
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
// every packet a separate forwarder process sends. Parsed from `ip rule show`
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
// is the forwarder's, and wg-quick already handles the marked one.
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

// splitUpstream splits the transport's upstream into host and port. A bare
// host is legal (the envelope validation already rejected an empty or
// malformed one); stream transports all dial TLS, so 443 is the implied
// port.
func splitUpstream(upstream string) (string, string) {
	if host, port, err := net.SplitHostPort(upstream); err == nil {
		return strings.TrimSpace(host), port
	}
	return strings.TrimSpace(upstream), "443"
}

// resolveUpstream turns the upstream host into addresses. A literal IP needs
// no resolver; a hostname does, and the *current* (physical) resolver is the
// right one: the transport comes up before any tunnel DNS state exists.
func (m *Manager) resolveUpstream(ctx context.Context, host string) ([]net.IP, error) {
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

// startForwarderProcess launches the forwarder in its own process group, the
// same discipline as every other privileged exec: a group kill on stop so a
// descendant cannot outlive the tunnel, and no PATH lookup (the caller
// resolved the absolute path under the fixed tool directories).
func startForwarderProcess(ctx context.Context, binary, configPath string) (func() error, error) {
	// Detach from the request context: the forwarder must outlive the `up`
	// that started it and live until the matching down.
	cmd := exec.Command(binary, "--config", configPath)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	done := make(chan struct{})
	go func() {
		_ = cmd.Wait()
		close(done)
	}()
	var stopOnce sync.Once
	stop := func() error {
		var stopErr error
		stopOnce.Do(func() {
			// Ask first, then kill the group: a clean exit reclaims the
			// forwarder's own state, and the group kill bounds the wait.
			_ = cmd.Process.Signal(syscall.SIGTERM)
			select {
			case <-done:
			case <-time.After(forwarderStopGrace):
				stopErr = terminateProcessGroup(cmd)
			}
		})
		return stopErr
	}
	return stop, nil
}

// waitForwarderListen blocks until the forwarder accepts a TCP connection on
// addr or the timeout expires. TCP is the readiness signal because every
// stream forwarder exposes a local control/inbound listener; a UDP-only
// forwarder would need a different probe.
func waitForwarderListen(ctx context.Context, addr string) error {
	deadline := time.Now().Add(forwarderReadyTimeout)
	dialer := net.Dialer{Timeout: forwarderReadyInterval}
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		conn, err := dialer.DialContext(ctx, "tcp", addr)
		if err == nil {
			_ = conn.Close()
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("no listener on %s within %s", addr, forwarderReadyTimeout)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(forwarderReadyInterval):
		}
	}
}
