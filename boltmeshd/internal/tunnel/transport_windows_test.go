//go:build windows

// Behavior suite for the stream transport rung on Windows. The transport is a
// fake — its lifecycle is two calls, and internal/stream has its own suite — and
// the routing table is faked too, so the privileged work (pinning and removing
// host routes, ordering against the tunnel service) is checked without touching
// this machine's routes.
package tunnel

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"boltmeshd/internal/protocol"
)

// fakeRoutes records the routing work the transport asks for, and can be told to
// fail any step. It is the seam over the IP forward table.
type fakeRoutes struct {
	added   []net.IP
	deleted []net.IP
	routes  map[string]physicalRoute
	// prefixes records the tunnel-side installs, separately from the host pins: they
	// name a prefix and an interface rather than a single destination and a gateway,
	// and the obfuscated suite asserts on the shape.
	prefixes []string

	bestErr   error
	addErr    error
	deleteErr error
	// atAdd snapshots the pin record as each install runs, so a test can assert
	// the record was written first rather than after.
	atAdd func()
}

func newFakeRoutes() *fakeRoutes {
	return &fakeRoutes{routes: map[string]physicalRoute{}}
}

func (f *fakeRoutes) bestRoute(dst net.IP) (physicalRoute, error) {
	if f.bestErr != nil {
		return physicalRoute{}, f.bestErr
	}
	return physicalRoute{luid: 42, nextHop: net.ParseIP("192.168.1.1")}, nil
}

func (f *fakeRoutes) addHostRoute(dst net.IP, route physicalRoute) error {
	if f.atAdd != nil {
		f.atAdd()
	}
	if f.addErr != nil {
		return f.addErr
	}
	f.added = append(f.added, dst)
	f.routes[dst.String()] = route
	return nil
}

func (f *fakeRoutes) deleteHostRoute(dst net.IP) error {
	if f.deleteErr != nil {
		return f.deleteErr
	}
	f.deleted = append(f.deleted, dst)
	delete(f.routes, dst.String())
	return nil
}

func (f *fakeRoutes) installed() []string {
	out := make([]string, 0, len(f.routes))
	for ip := range f.routes {
		out = append(out, ip)
	}
	return out
}

func (f *fakeRoutes) addPrefixRoute(prefix net.IP, bits uint8, luid uint64, nextHop net.IP, metric uint32) error {
	if f.addErr != nil {
		return f.addErr
	}
	f.prefixes = append(f.prefixes, fmt.Sprintf("%s/%d on luid %d metric %d nextHop %v",
		prefix, bits, luid, metric, nextHop))
	return nil
}

func (f *fakeRoutes) deletePrefixRoute(prefix net.IP, bits uint8) error {
	if f.deleteErr != nil {
		return f.deleteErr
	}
	// Truncated to the prefix's own length, because the host routes this fake also
	// records are single addresses and one shape has to hold both.
	f.deleted = append(f.deleted, prefix[:bits/8])
	return nil
}

// fakeStream is the transport double: it counts its lifecycle so the privileged
// side can be tested without a node or a real TLS session.
type fakeStream struct {
	// spec is the spec the daemon built the transport from, so a test can check
	// the credentials were passed through unrewritten.
	spec    protocol.TransportSpec
	started int
	stopped int
	stopErr error
}

func (f *fakeStream) Start() { f.started++ }

func (f *fakeStream) Stop() error {
	f.stopped++
	return f.stopErr
}

type transportHarness struct {
	m        *Manager
	svc      *fakeService
	routes   *fakeRoutes
	stream   *fakeStream
	passSpec *protocol.TransportSpec
	// buildErr fails the transport constructor: the stand-in for a listen
	// address the daemon cannot bind.
	buildErr error
	// order records the sequence of privileged steps so ordering is assertable.
	order []string
}

func b64(n int) string { return base64.StdEncoding.EncodeToString(make([]byte, n)) }

func streamSpec() *protocol.TransportSpec {
	return &protocol.TransportSpec{
		Mode:       protocol.TransportModeStream,
		Listen:     "127.0.0.1:51821",
		Deliver:    "127.0.0.1:51820",
		Server:     "203.0.113.10:443",
		ServerName: "vpn.example.net",
		SPKIPins:   []string{b64(32)},
		PSK:        b64(32),
		ClientID:   b64(16),
	}
}

// streamConfig points the peer at the loopback listen address and pins the local
// listen port, as the client does for the stream rung. The pinned port is where
// the transport delivers the node's datagrams, so it cannot be left to the
// kernel's choice.
const streamConfig = `[Interface]
PrivateKey = ` + keyA + `
ListenPort = 51820
Address = 10.8.0.5/32
DNS = 10.8.0.1

[Peer]
PublicKey = ` + keyB + `
Endpoint = 127.0.0.1:51821
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
`

func newTransportHarness(t *testing.T) *transportHarness {
	t.Helper()
	m, svc, _ := newTestManager(t)
	h := &transportHarness{m: m, svc: svc, routes: newFakeRoutes(), stream: &fakeStream{}}
	m.routes = h.routes
	m.resolveHost = func(context.Context, string) ([]net.IP, error) {
		return []net.IP{net.ParseIP("203.0.113.10")}, nil
	}
	// The service records its own transitions so the two orderings that matter
	// (pin before start, sweep before retry) are assertable.
	svc.onStart = func() { h.order = append(h.order, "service-start") }
	svc.onStop = func() { h.order = append(h.order, "service-stop") }
	m.streamTransport = func(spec *protocol.TransportSpec, _ func(bool, error)) (streamClient, error) {
		if h.buildErr != nil {
			return nil, h.buildErr
		}
		held := *spec
		h.passSpec = &held
		h.stream.spec = held
		h.order = append(h.order, "transport-built")
		return h.stream, nil
	}
	h.routes.atAdd = func() { h.order = append(h.order, "route-add") }
	return h
}

func (h *transportHarness) up(t *testing.T) {
	t.Helper()
	if _, err := h.m.Up(context.Background(), streamConfig, streamSpec()); err != nil {
		t.Fatalf("Up = %v, want nil", err)
	}
}

// The bypass route must exist before the tunnel service starts: from the moment
// the adapter installs its default route, the transport's egress would follow it
// into the tunnel it carries.
func TestUpPinsTheServerBeforeStartingTheService(t *testing.T) {
	h := newTransportHarness(t)
	h.up(t)

	pinAt, startAt := -1, -1
	for i, step := range h.order {
		if step == "route-add" && pinAt < 0 {
			pinAt = i
		}
		if step == "service-start" && startAt < 0 {
			startAt = i
		}
	}
	if pinAt < 0 {
		t.Fatalf("bypass route never installed: %v", h.order)
	}
	if startAt < 0 {
		t.Fatalf("tunnel service never started: %v", h.order)
	}
	if pinAt > startAt {
		t.Errorf("bypass route installed after the service started (%d > %d): %v", pinAt, startAt, h.order)
	}
	if h.stream.started != 1 {
		t.Errorf("transport started %d times, want 1", h.stream.started)
	}
}

// A /32 through the physical interface is what keeps the transport's egress out
// of the tunnel on Windows: the longest prefix wins over the adapter's default
// route, with no fwmark table to mirror.
func TestUpPinsTheResolvedServerAddressNotTheLoopbackBridge(t *testing.T) {
	h := newTransportHarness(t)
	h.up(t)

	if len(h.routes.added) != 1 || h.routes.added[0].String() != "203.0.113.10" {
		t.Fatalf("pinned %v, want only the node's real address", h.routes.added)
	}
	if h.routes.added[0].IsLoopback() {
		t.Error("pinned the loopback bridge address, which needs no route")
	}
}

func TestUpStartsTheTransportWithTheClientsOwnCredentials(t *testing.T) {
	h := newTransportHarness(t)
	spec := streamSpec()
	if _, err := h.m.Up(context.Background(), streamConfig, spec); err != nil {
		t.Fatalf("Up = %v, want nil", err)
	}
	// The daemon must not rewrite what the client sent: the pin set, the PSK,
	// and the client id are the control plane's, not the daemon's.
	got := h.passSpec
	if got.Listen != spec.Listen || got.Deliver != spec.Deliver || got.Server != spec.Server {
		t.Errorf("daemon rewrote the addresses: %+v", got)
	}
	if got.PSK != spec.PSK || got.ClientID != spec.ClientID ||
		len(got.SPKIPins) != 1 || got.SPKIPins[0] != spec.SPKIPins[0] {
		t.Errorf("daemon rewrote the credentials: %+v", got)
	}
	if _, err := got.StreamPSK(); err != nil {
		t.Errorf("StreamPSK: %v", err)
	}
	if _, err := got.StreamClientID(); err != nil {
		t.Errorf("StreamClientID: %v", err)
	}
	if _, err := got.StreamSPKIPins(); err != nil {
		t.Errorf("StreamSPKIPins: %v", err)
	}
}

// Down sweeps the pin and stops the bridge: a route left installed would keep
// exempting the node from every tunnel after this one.
func TestDownStopsTheTransportAndSweepsThePinnedRoute(t *testing.T) {
	h := newTransportHarness(t)
	h.up(t)

	if _, err := h.m.Down(context.Background()); err != nil {
		t.Fatalf("Down = %v, want nil", err)
	}
	if h.stream.stopped != 1 {
		t.Errorf("transport stopped %d times, want exactly 1", h.stream.stopped)
	}
	if len(h.routes.deleted) != 1 || h.routes.deleted[0].String() != "203.0.113.10" {
		t.Errorf("swept %v, want the pinned address", h.routes.deleted)
	}
	if left := h.routes.installed(); len(left) != 0 {
		t.Errorf("bypass routes left installed: %v", left)
	}
	if h.m.transportPinsRecorded() {
		t.Error("pin record survived a complete sweep")
	}
}

// A retry must not leave the previous tunnel's pins installed underneath the
// new one — they outlive the daemon, so stacking them is how a stale exemption
// accumulates.
func TestUpTearsDownThePreviousTransportBeforeInstallingANewOne(t *testing.T) {
	h := newTransportHarness(t)
	h.up(t)
	stoppedBefore := h.stream.stopped
	h.order = nil

	// A native retry with no transport.
	if _, err := h.m.Up(context.Background(), validConfig, nil); err != nil {
		t.Fatalf("Up(native) = %v, want nil", err)
	}
	if h.stream.stopped != stoppedBefore+1 {
		t.Errorf("transport stopped %d times, want the retry to stop it once more (%d)",
			h.stream.stopped, stoppedBefore+1)
	}
	if left := h.routes.installed(); len(left) != 0 {
		t.Errorf("retry left bypass routes installed: %v", left)
	}
	if h.m.transport != nil {
		t.Error("retry left a live transport marker")
	}
}

// The pin record has to name a route before it is installed, or a crash in
// between leaks one nothing accounts for. Checked from inside the install, which
// is the only moment the two orderings differ.
func TestPinRecordIsWrittenBeforeTheRouteIsInstalled(t *testing.T) {
	h := newTransportHarness(t)
	path := filepath.Join(h.m.dir, DefaultInterface+".conf.pins")
	var atInstall string
	h.routes.atAdd = func() {
		data, err := os.ReadFile(path)
		if err != nil {
			atInstall = "READ ERROR: " + err.Error()
			return
		}
		atInstall = string(data)
	}
	h.up(t)

	if !strings.Contains(atInstall, "203.0.113.10") {
		t.Errorf("route installed before its pin was recorded; record read as:\n%s", atInstall)
	}
}

// The record carries routes only. A stray read must not be able to leak the
// credential the bridge authenticates with.
func TestPinRecordHoldsNoCredentials(t *testing.T) {
	h := newTransportHarness(t)
	h.up(t)

	data, err := os.ReadFile(h.m.transportPinPath())
	if err != nil {
		t.Fatalf("read pin record: %v", err)
	}
	text := string(data)
	for _, secret := range []string{h.passSpec.PSK, h.passSpec.ClientID, h.passSpec.ServerName} {
		if secret != "" && strings.Contains(text, secret) {
			t.Errorf("pin record leaked %q:\n%s", secret, text)
		}
	}
	if !strings.Contains(text, "203.0.113.10") {
		t.Errorf("pin record does not name the pinned route:\n%s", text)
	}
}

// The routes outlive the daemon, so a restarted daemon has to sweep them from
// the record: a memory-only sweep strands a /32 that permanently exempts the
// node from the tunnel.
func TestDownAfterRestartSweepsPinsFromTheRecord(t *testing.T) {
	h := newTransportHarness(t)
	h.up(t)

	// A fresh Manager over the same directory: in-memory transport state gone,
	// the routes and the record still there.
	restarted := NewManager(h.m.dir, DefaultInterface)
	restarted.service = h.svc
	restarted.routes = h.routes
	restarted.exeDir = h.m.exeDir
	restarted.stat = h.m.stat
	restarted.protectDir = h.m.protectDir
	restarted.protectFile = h.m.protectFile
	h.routes.deleted = nil

	if restarted.transport != nil {
		t.Fatal("restart left in-memory transport state, so this proves nothing")
	}
	if _, err := restarted.Down(context.Background()); err != nil {
		t.Fatalf("Down after restart = %v, want nil", err)
	}
	if len(h.routes.deleted) != 1 || h.routes.deleted[0].String() != "203.0.113.10" {
		t.Errorf("restarted daemon swept %v, want the recorded pin", h.routes.deleted)
	}
	if left := h.routes.installed(); len(left) != 0 {
		t.Errorf("bypass routes left installed after a restart: %v", left)
	}
	if restarted.transportPinsRecorded() {
		t.Error("pin record survived a complete sweep")
	}
}

// A native retry after a restart must still sweep the dead transport's pins.
func TestUpAfterRestartSweepsTheLingeringPin(t *testing.T) {
	h := newTransportHarness(t)
	h.up(t)

	restarted := NewManager(h.m.dir, DefaultInterface)
	restarted.service = h.svc
	restarted.routes = h.routes
	restarted.exeDir = h.m.exeDir
	restarted.stat = h.m.stat
	restarted.protectDir = h.m.protectDir
	restarted.protectFile = h.m.protectFile
	h.routes.deleted = nil

	if _, err := restarted.Up(context.Background(), validConfig, nil); err != nil {
		t.Fatalf("Up after restart = %v, want nil", err)
	}
	if len(h.routes.deleted) == 0 {
		t.Errorf("stale bypass route left behind by a native retry: still installed %v", h.routes.installed())
	}
}

// A service that fails to start must not leave the bridge running or its pins
// installed: the adapter may have come up before the failure was reported.
func TestUpRecoversWhenTheServiceFailsToStart(t *testing.T) {
	h := newTransportHarness(t)
	h.svc.startErr = errors.New("the service did not start")

	if _, err := h.m.Up(context.Background(), streamConfig, streamSpec()); err == nil {
		t.Fatal("Up = nil, want the service failure")
	}
	if h.stream.stopped != 1 {
		t.Errorf("transport stopped %d times after a failed up, want 1", h.stream.stopped)
	}
	if left := h.routes.installed(); len(left) != 0 {
		t.Errorf("bypass routes left installed after a failed up: %v", left)
	}
	if h.m.transport != nil {
		t.Error("a failed up left a live transport marker")
	}
}

// A transport that cannot be built must fail closed rather than bring the tunnel
// up on a dead loopback endpoint.
func TestUpFailsClosedWhenTheTransportCannotBeBuilt(t *testing.T) {
	h := newTransportHarness(t)
	h.buildErr = errors.New("bind 127.0.0.1:51821: address already in use")

	_, err := h.m.Up(context.Background(), streamConfig, streamSpec())
	if err == nil {
		t.Fatal("Up = nil, want the transport-construction failure")
	}
	var opErr *protocol.OpError
	if !errors.As(err, &opErr) || opErr.Code != protocol.CodeBadConfig {
		t.Errorf("error = %v, want bad_config so the client does not retry this region", err)
	}
	if h.svc.starts != 0 {
		t.Errorf("tunnel service started %d times despite no transport", h.svc.starts)
	}
}

// An invalid spec must be rejected before anything privileged happens.
func TestUpRejectsAnInvalidSpecBeforeTouchingAnything(t *testing.T) {
	h := newTransportHarness(t)
	spec := streamSpec()
	spec.SPKIPins = nil // a pinned stream with no pin is a stream to whoever answers

	_, err := h.m.Up(context.Background(), streamConfig, spec)
	var opErr *protocol.OpError
	if !errors.As(err, &opErr) || opErr.Code != protocol.CodeBadConfig {
		t.Fatalf("Up = %v, want bad_config", err)
	}
	if h.svc.starts != 0 || h.stream.started != 0 {
		t.Errorf("privileged work happened for an invalid spec: starts=%d transport=%d",
			h.svc.starts, h.stream.started)
	}
	if len(h.routes.installed()) != 0 {
		t.Error("a route was installed for an invalid spec")
	}
}

// An address that cannot be resolved must not leave a tunnel on a dead endpoint.
// The code is internal rather than bad-config on purpose: the server address
// comes from the control plane, so a name that does not resolve is the same
// transient DNS condition the client's health policy already retries — and it
// matches what the Linux backend reports for the identical failure.
//
// The spec carries a *hostname*, not an address: an IP literal short-circuits
// the resolver entirely, so testing this against a literal would never reach the
// failure being tested.
func TestUpFailsClosedWhenTheServerCannotBeResolved(t *testing.T) {
	h := newTransportHarness(t)
	spec := streamSpec()
	spec.Server = "node.example.net:443"
	h.m.resolveHost = func(context.Context, string) ([]net.IP, error) {
		return nil, errors.New("no such host")
	}

	_, err := h.m.Up(context.Background(), streamConfig, spec)
	var opErr *protocol.OpError
	if !errors.As(err, &opErr) || opErr.Code != protocol.CodeInternal {
		t.Fatalf("Up = %v, want an internal error (retryable), matching the Linux backend", err)
	}
	if h.svc.starts != 0 {
		t.Errorf("tunnel service started %d times with no reachable upstream", h.svc.starts)
	}
	if h.stream.started != 0 {
		t.Error("bridge started with no reachable upstream")
	}
}

// A literal server address needs no resolver, so a machine with no DNS
// configured can still come up on the rung.
func TestUpResolvesALiteralServerAddressWithoutTheResolver(t *testing.T) {
	h := newTransportHarness(t)
	spec := streamSpec()
	spec.Server = "203.0.113.10:443"
	h.m.resolveHost = func(context.Context, string) ([]net.IP, error) {
		t.Error("a literal server address must not hit the resolver")
		return nil, errors.New("unreachable")
	}
	if _, err := h.m.Up(context.Background(), streamConfig, spec); err != nil {
		t.Fatalf("Up = %v, want nil", err)
	}
}

// A route the daemon cannot sweep must be reported, and the record kept: an
// incomplete teardown that deletes the record would strand the route with
// nothing left naming it.
func TestDownKeepsTheRecordWhenARouteCannotBeSwept(t *testing.T) {
	h := newTransportHarness(t)
	h.up(t)
	h.routes.deleteErr = errors.New("access denied")

	if _, err := h.m.Down(context.Background()); err == nil {
		t.Fatal("Down = nil, want the sweep failure")
	}
	if !h.m.transportPinsRecorded() {
		t.Error("pin record deleted even though a route could not be swept")
	}
}

func TestSplitServerDefaultsToTLSPort(t *testing.T) {
	host, port := splitServer("vpn.example.net")
	if host != "vpn.example.net" || port != "443" {
		t.Fatalf("splitServer = %q, %q, want vpn.example.net 443", host, port)
	}
	host, port = splitServer("vpn.example.net:8443")
	if host != "vpn.example.net" || port != "8443" {
		t.Fatalf("splitServer = %q, %q, want vpn.example.net 8443", host, port)
	}
}
