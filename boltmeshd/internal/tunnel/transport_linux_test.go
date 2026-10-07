//go:build linux

// Behavior suite for the stream transport rung. The transport itself is a
// fake — its lifecycle is two calls, and the shared stream package has its own suite —
// while the privileged work (pinning and removing routes, ordering against
// wg-quick) goes through the same recorded run seam the wg-quick suite uses.
package tunnel

import (
	"context"
	"encoding/base64"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"

	"boltmeshd/internal/protocol"
)

type transportRunCall struct {
	name  string
	args  []string
	input string
}

func (c transportRunCall) String() string {
	if c.input != "" {
		return c.name + " " + strings.Join(c.args, " ") + " < " + c.input
	}
	return c.name + " " + strings.Join(c.args, " ")
}

// wgQuickRuleOutput is a realistic `ip rule show` for a strict-mode
// wg-quick setup: the unmarked path goes to table 51820, the marked
// (device) path to the same table with the default suppressed, and the
// main table last.
const wgQuickRuleOutput = `0:	from all lookup local
32765:	not from all fwmark 0xca6c lookup 51820
32766:	from all lookup 51820 suppress_prefixlength 0
32767:	from all lookup main suppress_prefixlength 0
`

// fakeStream is the transport double: it records the credentials it was built
// from and counts its lifecycle, so the privileged side can be tested without
// a node or a real TLS session.
type fakeStream struct {
	spec      protocol.TransportSpec
	started   int
	stopped   int
	onSession func(bool, error)
}

func (f *fakeStream) Start() { f.started++ }

func (f *fakeStream) Stop() error {
	f.stopped++
	return nil
}

type transportHarness struct {
	m       *Manager
	calls   *[]transportRunCall
	dev     *fakeAwgDevice
	streams []*fakeStream
	// buildErr, when set, fails the transport constructor: the stand-in for
	// a bad listen address or an unresolvable node.
	buildErr error
	// passSpec records the spec handed to the constructor, so the test can
	// assert the daemon did not rewrite the client's credentials.
	passSpec *protocol.TransportSpec
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

// streamConfig points the peer at the loopback listen address and pins the
// local listen port, as the client does for the stream rung. The pinned port
// is what the transport delivers the node's datagrams to, so it cannot be
// left to the kernel's choice.
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

// obfuscatedStreamConfig is [streamConfig] plus a complete AmneziaWG
// obfuscation set: the conf a client builds for the stream rung on an
// obfuscated region. The inner datagrams carry the region's directives — the
// node's AmneziaWG device drops stock ones — while the peer endpoint is still
// the bridge's loopback address.
const obfuscatedStreamConfig = `[Interface]
PrivateKey = ` + keyA + `
ListenPort = 51820
Address = 10.8.0.5/32
DNS = 10.8.0.1
Jc = 3
Jmin = 40
Jmax = 70
S1 = 15
S2 = 17
S3 = 10
S4 = 5
H1 = 115-120
H2 = 130
H3 = 150-160
H4 = 171

[Peer]
PublicKey = ` + keyB + `
Endpoint = 127.0.0.1:51821
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
`

func newTransportHarness(t *testing.T, linkUp bool) *transportHarness {
	t.Helper()
	// Reuse the AWG harness's kernel-device double so Status has a reader.
	awg := newAwgHarness(t)
	m := awg.m
	m.lookup = func(name string) (string, error) { return name, nil }
	m.linkExists = func(string) bool { return linkUp }
	calls := &[]transportRunCall{}
	m.run = func(_ context.Context, name string, args ...string) ([]byte, error) {
		*calls = append(*calls, transportRunCall{name: name, args: args})
		if len(args) >= 2 && args[0] == "rule" && args[1] == "show" {
			return []byte(wgQuickRuleOutput), nil
		}
		if len(args) >= 2 && args[0] == "route" && args[1] == "get" {
			return []byte("203.0.113.10 via 192.168.1.1 dev eth0 src 192.168.1.5"), nil
		}
		return []byte("ok"), nil
	}
	h := &transportHarness{m: m, calls: calls, dev: awg.dev}
	m.streamTransport = func(spec *protocol.TransportSpec, onSession func(bool, error)) (streamClient, error) {
		if h.buildErr != nil {
			return nil, h.buildErr
		}
		// Copy: the Manager keeps its own reference in forwarder.spec, and a
		// test that mutates the spec afterwards must not reach into it.
		held := *spec
		h.passSpec = &held
		f := &fakeStream{spec: held, onSession: onSession}
		h.streams = append(h.streams, f)
		return f, nil
	}
	return h
}

func (h *transportHarness) callStrings() []string {
	out := make([]string, 0, len(*h.calls))
	for _, c := range *h.calls {
		out = append(out, c.String())
	}
	return out
}

func (h *transportHarness) has(name string, args ...string) bool {
	for _, c := range *h.calls {
		if c.name == name && strings.Join(c.args, " ") == strings.Join(args, " ") {
			return true
		}
	}
	return false
}

func (h *transportHarness) up(t *testing.T) {
	t.Helper()
	if _, err := h.m.Up(context.Background(), streamConfig, streamSpec()); err != nil {
		t.Fatalf("Up = %v, want nil", err)
	}
}

func TestUpWithStreamTransportPinsServerBeforeWgQuick(t *testing.T) {
	h := newTransportHarness(t, false)
	h.up(t)

	// The bypass route must be installed before wg-quick runs: from the
	// moment the tunnel's routes exist, the transport's egress would be
	// routed into the tunnel it carries.
	var pinIdx, wgIdx = -1, -1
	for i, c := range *h.calls {
		if c.name == "ip" && strings.HasPrefix(strings.Join(c.args, " "), "route replace 203.0.113.10/32") && pinIdx < 0 {
			pinIdx = i
		}
		if c.name == wgQuickBinary && wgIdx < 0 {
			wgIdx = i
		}
	}
	if pinIdx < 0 {
		t.Fatalf("bypass route never pinned:\n%v", h.callStrings())
	}
	if wgIdx < 0 {
		t.Fatalf("wg-quick never ran:\n%v", h.callStrings())
	}
	if pinIdx > wgIdx {
		t.Errorf("bypass route pinned after wg-quick up (call %d > %d):\n%v", pinIdx, wgIdx, h.callStrings())
	}
	if !h.has("ip", "route", "replace", "203.0.113.10/32", "via", "192.168.1.1", "dev", "eth0") {
		t.Errorf("bypass route not pinned through the physical path:\n%v", h.callStrings())
	}
	// wg-quick saw a config whose endpoint is the loopback listen address.
	if !h.has(wgQuickBinary, "up", h.m.configPath()) {
		t.Errorf("wg-quick up missing:\n%v", h.callStrings())
	}
}

func TestUpStartsTheTransportWithTheClientsOwnCredentials(t *testing.T) {
	h := newTransportHarness(t, false)
	spec := streamSpec()
	if _, err := h.m.Up(context.Background(), streamConfig, spec); err != nil {
		t.Fatalf("Up = %v, want nil", err)
	}
	if len(h.streams) != 1 {
		t.Fatalf("transport built %d times, want 1", len(h.streams))
	}
	if h.streams[0].started != 1 {
		t.Errorf("transport started %d times, want 1", h.streams[0].started)
	}
	// The daemon must not rewrite what the client sent: the pin set, the PSK,
	// and the client id are the control plane's, not the daemon's.
	got := h.passSpec
	if got.Listen != spec.Listen || got.Deliver != spec.Deliver || got.Server != spec.Server {
		t.Errorf("daemon rewrote the addresses: %+v", got)
	}
	if got.PSK != spec.PSK || got.ClientID != spec.ClientID || len(got.SPKIPins) != 1 || got.SPKIPins[0] != spec.SPKIPins[0] {
		t.Errorf("daemon rewrote the credentials: %+v", got)
	}
	// And they are the ones that decode to the sizes the derivation needs.
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

func TestUpWithStreamTransportPinsWgQuickTables(t *testing.T) {
	h := newTransportHarness(t, false)
	h.up(t)

	// wg-quick's strict-mode rules steer *unmarked* packets (the transport)
	// into its own table before the main one, so the bypass route has to
	// exist there too.
	if !h.has("ip", "rule", "show") {
		t.Errorf("routing rules never read:\n%v", h.callStrings())
	}
	if !h.has("ip", "route", "replace", "203.0.113.10/32", "via", "192.168.1.1", "dev", "eth0", "table", "51820") {
		t.Errorf("bypass route not pinned in the wg-quick table:\n%v", h.callStrings())
	}
	// It must not be pinned in the marked (device) path: wg-quick already
	// routes the device's own handshake out, and an extra pin there is
	// state nobody asked for.
	if h.has("ip", "route", "replace", "203.0.113.10/32", "via", "192.168.1.1", "dev", "eth0", "table", "51821") {
		t.Errorf("bypass route pinned in an unexpected table:\n%v", h.callStrings())
	}
}

func TestDownTearsDownTheTransportAndEveryPinnedRoute(t *testing.T) {
	h := newTransportHarness(t, true)
	h.up(t)
	*h.calls = (*h.calls)[:0]

	if _, err := h.m.Down(context.Background()); err != nil {
		t.Fatalf("Down = %v, want nil", err)
	}
	if h.streams[0].stopped != 1 {
		t.Errorf("transport stopped %d times, want exactly 1", h.streams[0].stopped)
	}
	// Both the main-table pin and the wg-quick-table pin are removed.
	if !h.has("ip", "route", "del", "203.0.113.10/32") {
		t.Errorf("main-table bypass route left behind:\n%v", h.callStrings())
	}
	if !h.has("ip", "route", "del", "203.0.113.10/32", "table", "51820") {
		t.Errorf("wg-quick-table bypass route left behind:\n%v", h.callStrings())
	}
	if h.m.transport != nil {
		t.Error("live transport marker survived a successful teardown")
	}
}

// TestStreamSessionStateTracksTheTransportLifecycle pins the tri-state the
// status reports for the stream rung, which is what lets the client tell a
// rung still coming up from one whose path has died. The transitions are the
// daemon's own: bring-up seeds "establishing" (the bridge reports a session
// only once one has ended), the callback flips it on establish and on drop,
// and teardown clears it so a stale "established" cannot outlive the
// transport that produced it.
func TestStreamSessionStateTracksTheTransportLifecycle(t *testing.T) {
	h := newTransportHarness(t, true)
	h.up(t)

	if st := h.m.streamSessionState(); st == nil || *st {
		t.Fatalf("after bring-up, streamSessionState = %v, want a live false", st)
	}

	// The session establishing is the client's grace window; the
	// first completed handshake ends it.
	h.streams[0].onSession(true, nil)
	if st := h.m.streamSessionState(); st == nil || !*st {
		t.Fatalf("after OnSession(true), streamSessionState = %v, want true", st)
	}

	// A session that drops reports "not established" again — but the
	// handshake is by then observed, so the client reads a dropped
	// session as a dead path, not a slow one.
	h.streams[0].onSession(false, errors.New("node dropped the session"))
	if st := h.m.streamSessionState(); st == nil || *st {
		t.Fatalf("after OnSession(false), streamSessionState = %v, want false", st)
	}

	if _, err := h.m.Down(context.Background()); err != nil {
		t.Fatalf("Down = %v, want nil", err)
	}
	if st := h.m.streamSessionState(); st != nil {
		t.Fatalf("after teardown, streamSessionState = %v, want nil", st)
	}
}

func TestUpWithStreamTransportTearsDownBeforeRetry(t *testing.T) {
	h := newTransportHarness(t, true)
	h.up(t)
	stoppedBefore := h.streams[0].stopped

	// A retry (native config, no transport) must not orphan the transport.
	if _, err := h.m.Up(context.Background(), validConfig, nil); err != nil {
		t.Fatalf("Up(native) = %v, want nil", err)
	}
	if h.streams[0].stopped != stoppedBefore+1 {
		t.Errorf("transport stopped %d times, want the retry to stop it once more (%d)", h.streams[0].stopped, stoppedBefore+1)
	}
	if h.m.transport != nil {
		t.Error("retry left a live transport marker")
	}
}

func TestUpObfuscatedWithStreamTransportCarriesTheRegionFormat(t *testing.T) {
	h := newTransportHarness(t, false)

	// An obfuscated region: the stream rung's conf carries the region's
	// directives and the bridge's loopback endpoint. The tunnel that rides the
	// stream is the obfuscated one, so the node's AmneziaWG device accepts it.
	if _, err := h.m.Up(context.Background(), obfuscatedStreamConfig, streamSpec()); err != nil {
		t.Fatalf("Up(obfuscated + transport) = %v, want nil", err)
	}

	// The obfuscated data plane is the one that came up: the device was
	// configured with the region's directives rather than skipped for the
	// transport.
	if len(h.dev.bodies) != 1 {
		t.Fatalf("device configured %d times, want 1", len(h.dev.bodies))
	}
	if !strings.Contains(h.dev.bodies[0], "jc=3") {
		t.Errorf("device configured without the obfuscation parameters:\n%s", h.dev.bodies[0])
	}
	// And the bridge is carrying that tunnel.
	if len(h.streams) != 1 || h.streams[0].started != 1 {
		t.Fatalf("transport built=%d started=%d, want 1/1", len(h.streams), h.streams[0].started)
	}

	// The transport's real upstream is pinned through the physical path...
	if !h.has("ip", "route", "replace", "203.0.113.10/32", "via", "192.168.1.1", "dev", "eth0") {
		t.Errorf("bypass route not pinned through the physical path:\n%v", h.callStrings())
	}
	// ...but the loopback peer endpoint needs no underlay route: loopback is
	// resolved by the local table and is never captured by a tunnel route.
	if h.has("ip", "route", "replace", "127.0.0.1/32") {
		t.Errorf("underlay route pinned for the loopback bridge:\n%v", h.callStrings())
	}

	// The bypass route must exist before the obfuscated path's default route:
	// from the moment that route exists, the transport's TLS egress would be
	// routed into the tunnel it carries.
	pinIdx, routeIdx := -1, -1
	for i, c := range *h.calls {
		joined := strings.Join(c.args, " ")
		if c.name == "ip" && strings.HasPrefix(joined, "route replace 203.0.113.10/32") && pinIdx < 0 {
			pinIdx = i
		}
		if c.name == "ip" && strings.HasPrefix(joined, "route replace default dev "+h.m.iface) && routeIdx < 0 {
			routeIdx = i
		}
	}
	if pinIdx < 0 || routeIdx < 0 {
		t.Fatalf("bypass pin=%d, tunnel default route=%d, want both:\n%v", pinIdx, routeIdx, h.callStrings())
	}
	if pinIdx > routeIdx {
		t.Errorf("bypass route pinned after the tunnel default route (%d > %d):\n%v", pinIdx, routeIdx, h.callStrings())
	}
}

func TestDownObfuscatedWithStreamTransportStopsTheBridge(t *testing.T) {
	h := newTransportHarness(t, false)
	if _, err := h.m.Up(context.Background(), obfuscatedStreamConfig, streamSpec()); err != nil {
		t.Fatalf("Up = %v, want nil", err)
	}

	if _, err := h.m.Down(context.Background()); err != nil {
		t.Fatalf("Down = %v, want nil", err)
	}
	// The bridge goes down with the tunnel it carries, and its bypass route is
	// swept, so a later start does not inherit a live transport or a stale pin.
	if h.streams[0].stopped != 1 {
		t.Errorf("transport stopped %d times, want 1", h.streams[0].stopped)
	}
	if h.dev.closed != 1 {
		t.Errorf("device closed %d times, want 1", h.dev.closed)
	}
	if h.m.transport != nil {
		t.Error("live transport marker survived teardown")
	}
	if !h.has("ip", "route", "del", "203.0.113.10/32") {
		t.Errorf("bypass route left behind:\n%v", h.callStrings())
	}
}

func TestUpWithStreamTransportRecoversWhenWgQuickFails(t *testing.T) {
	h := newTransportHarness(t, false)
	// Fail wg-quick only; the transport and its pins must still be swept.
	m := h.m
	run := m.run
	m.run = func(ctx context.Context, name string, args ...string) ([]byte, error) {
		*h.calls = append(*h.calls, transportRunCall{name: name, args: args})
		if name == wgQuickBinary {
			return nil, errors.New("wg-quick: bad config")
		}
		return run(ctx, name, args...)
	}

	_, err := m.Up(context.Background(), streamConfig, streamSpec())
	if err == nil {
		t.Fatal("Up = nil, want the wg-quick failure")
	}
	if h.streams[0].stopped != 1 {
		t.Errorf("transport stopped %d times after a failed up, want 1", h.streams[0].stopped)
	}
	if h.m.transport != nil {
		t.Error("a failed up left a live transport marker")
	}
	if !h.has("ip", "route", "del", "203.0.113.10/32") {
		t.Errorf("bypass route left behind after a failed up:\n%v", h.callStrings())
	}
}

func TestUpWithStreamTransportFailsClosedWhenTheTransportCannotBeBuilt(t *testing.T) {
	h := newTransportHarness(t, false)
	// A listen address the daemon cannot bind, or a credential it cannot
	// decode, must not bring a tunnel up on a dead loopback endpoint.
	h.buildErr = errors.New("bind 127.0.0.1:51821: address already in use")

	_, err := h.m.Up(context.Background(), streamConfig, streamSpec())
	if err == nil {
		t.Fatal("Up = nil, want the transport-construction failure")
	}
	var opErr *protocol.OpError
	if !errors.As(err, &opErr) || opErr.Code != protocol.CodeBadConfig {
		t.Fatalf("Up = %v, want a bad-config error", err)
	}
	// wg-quick never ran: the tunnel is not brought up on a dead transport.
	if h.has(wgQuickBinary) {
		t.Errorf("wg-quick ran despite an unbuildable transport:\n%v", h.callStrings())
	}
	if h.m.transport != nil {
		t.Error("a failed up left a live transport marker")
	}
}

func TestUpWithStreamTransportRejectsAnInvalidSpecBeforeAnything(t *testing.T) {
	h := newTransportHarness(t, false)
	// A spec the envelope rejects must not reach the transport at all: the
	// check is the daemon's own defence against a client that skips its own.
	spec := streamSpec()
	spec.SPKIPins = nil

	_, err := h.m.Up(context.Background(), streamConfig, spec)
	var opErr *protocol.OpError
	if !errors.As(err, &opErr) || opErr.Code != protocol.CodeBadConfig {
		t.Fatalf("Up(no pins) = %v, want a bad-config error", err)
	}
	if len(h.streams) != 0 {
		t.Error("a transport was built from a spec that failed validation")
	}
	if h.has("ip", "route", "replace", "203.0.113.10/32") {
		t.Error("a bypass route was pinned for a spec that failed validation")
	}
}

func TestUpWithStreamTransportResolvesTheServerThroughThePhysicalResolver(t *testing.T) {
	h := newTransportHarness(t, false)
	// A literal server address needs no resolver, so a machine with no DNS
	// configured at all can still come up on the rung.
	spec := streamSpec()
	spec.Server = "203.0.113.10:443"
	m := h.m
	m.resolveHost = func(context.Context, string) ([]net.IP, error) {
		t.Error("a literal server address must not hit the resolver")
		return nil, errors.New("unreachable")
	}
	if _, err := m.Up(context.Background(), streamConfig, spec); err != nil {
		t.Fatalf("Up = %v, want nil", err)
	}
}

// restart simulates a daemon restart: a fresh Manager over the same directory,
// with the in-memory transport state gone but the routes, the config file, and
// the pin record all still on disk. Every other seam is carried over so the
// only thing that changed is the lost state.
func (h *transportHarness) restart(t *testing.T) *transportHarness {
	t.Helper()
	m := NewManager(h.m.dir, h.m.iface)
	m.lookup = h.m.lookup
	m.linkExists = func(string) bool { return false }
	m.device = h.m.device
	m.resolveHost = h.m.resolveHost
	m.run = h.m.run
	m.streamTransport = h.m.streamTransport
	*h.calls = (*h.calls)[:0]
	return &transportHarness{m: m, calls: h.calls, dev: h.dev, streams: h.streams}
}

// The bypass routes outlive the daemon that installed them, so a restarted
// daemon has to sweep them from the on-disk record. Without it the pin survives
// every future connect and permanently exempts the node from the tunnel.
func TestDownAfterRestartSweepsTransportPinsFromTheRecord(t *testing.T) {
	h := newTransportHarness(t, false)
	h.up(t)

	restarted := h.restart(t)
	if restarted.m.transport != nil {
		t.Fatal("restart left in-memory transport state, so this proves nothing")
	}
	if _, err := restarted.m.Down(context.Background()); err != nil {
		t.Fatalf("Down after restart = %v, want nil", err)
	}

	// Both tables the original up pinned, and nothing invented.
	if !restarted.has("ip", "route", "del", "203.0.113.10/32") {
		t.Errorf("main-table bypass route left behind after a restart:\n%v", restarted.callStrings())
	}
	if !restarted.has("ip", "route", "del", "203.0.113.10/32", "table", "51820") {
		t.Errorf("wg-quick-table bypass route left behind after a restart:\n%v", restarted.callStrings())
	}
	if restarted.m.transportPinsRecorded() {
		t.Error("pin record survived a complete sweep")
	}
}

// The same leak through the retry path rather than an explicit disconnect: the
// next connect must sweep the previous tunnel's pins, not stack a second set on
// top of them.
func TestUpAfterRestartSweepsTheOldPinsBeforeInstallingNewOnes(t *testing.T) {
	h := newTransportHarness(t, false)
	h.up(t)

	restarted := h.restart(t)
	if _, err := restarted.m.Up(context.Background(), streamConfig, streamSpec()); err != nil {
		t.Fatalf("Up after restart = %v, want nil", err)
	}

	delIdx, replaceIdx := -1, -1
	for i, c := range *restarted.calls {
		joined := strings.Join(c.args, " ")
		if c.name == "ip" && strings.HasPrefix(joined, "route del 203.0.113.10/32") && delIdx < 0 {
			delIdx = i
		}
		if c.name == "ip" && strings.HasPrefix(joined, "route replace 203.0.113.10/32") && replaceIdx < 0 {
			replaceIdx = i
		}
	}
	if delIdx < 0 {
		t.Fatalf("stale bypass route never swept before the retry:\n%v", restarted.callStrings())
	}
	if replaceIdx < delIdx {
		t.Errorf("new pin installed before the stale one was swept (%d < %d):\n%v",
			replaceIdx, delIdx, restarted.callStrings())
	}
}

// The record must name a pin *before* it is installed, not after: a crash
// between the two leaks a route nothing accounts for. The ordering is checked
// from inside the install itself — read the record as the command runs, which
// is the only moment the two orderings differ. An install that then fails and
// gets swept by the recovery pass proves nothing about ordering, so this
// installs successfully and inspects the record mid-command.
func TestTransportPinRecordIsWrittenBeforeEachRouteIsInstalled(t *testing.T) {
	dir := t.TempDir()
	m := NewManager(dir, DefaultInterface)
	m.lookup = func(name string) (string, error) { return name, nil }
	m.linkExists = func(string) bool { return false }
	m.device = func(string) (*wgtypes.Device, error) { return nil, os.ErrNotExist }

	var atInstall []string
	m.run = func(_ context.Context, name string, args ...string) ([]byte, error) {
		if len(args) >= 2 && args[0] == "route" && args[1] == "get" {
			return []byte("203.0.113.10 via 192.168.1.1 dev eth0"), nil
		}
		if name == "ip" && len(args) >= 2 && args[0] == "route" && args[1] == "replace" {
			// Snapshot the record as the install is about to run.
			recorded, err := os.ReadFile(filepath.Join(dir, DefaultInterface+".conf.pins"))
			if err != nil {
				atInstall = append(atInstall, "READ ERROR: "+err.Error())
			} else {
				atInstall = append(atInstall, string(recorded))
			}
		}
		return []byte("ok"), nil
	}

	if _, err := m.Up(context.Background(), streamConfig, streamSpec()); err != nil {
		t.Fatalf("Up = %v, want nil", err)
	}

	if len(atInstall) == 0 {
		t.Fatal("no pin install observed")
	}
	for i, snapshot := range atInstall {
		if !strings.Contains(snapshot, "203.0.113.10/32") {
			t.Errorf("install %d ran before its pin was recorded; record read as:\n%s", i, snapshot)
		}
	}
}

// The record is a root-only file and must never carry anything credential-like.
// It names routes only, so a stray read cannot leak the PSK.
func TestTransportPinRecordHoldsOnlyRoutesAndNoCredentials(t *testing.T) {
	h := newTransportHarness(t, false)
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
	if !strings.Contains(text, "203.0.113.10/32") {
		t.Errorf("pin record does not name the pinned route:\n%s", text)
	}
}

// A plain tunnel never touches the pin record: no transport means no pins, and
// a stray record from an earlier transport must still be swept by the retry.
func TestUpWithoutTransportSweepsALingeringPinRecord(t *testing.T) {
	h := newTransportHarness(t, true)
	h.up(t)

	restarted := h.restart(t)
	// A native retry with no transport: the pins from the dead transport must
	// still go, or they outlive the tunnel that justified them.
	if _, err := restarted.m.Up(context.Background(), validConfig, nil); err != nil {
		t.Fatalf("Up(native after restart) = %v, want nil", err)
	}
	if !restarted.has("ip", "route", "del", "203.0.113.10/32") {
		t.Errorf("stale bypass route left behind by a native retry:\n%v", restarted.callStrings())
	}
}

func TestParseUnmarkedRuleTables(t *testing.T) {
	cases := []struct {
		name  string
		rules string
		want  []int
	}{
		{
			name:  "strict mode wg-quick table",
			rules: wgQuickRuleOutput,
			want:  []int{51820},
		},
		{
			name: "table keyword form",
			rules: `0:	from all lookup local
32765:	not from all fwmark 0xca6c table 51820
`,
			want: []int{51820},
		},
		{
			name: "marked rules and the main table are not the transport's path",
			rules: `0:	from all lookup local
32766:	from all lookup 51820 suppress_prefixlength 0
32767:	from all lookup main suppress_prefixlength 0
`,
			want: nil,
		},
		{
			name:  "duplicates collapse",
			rules: "1: not from all fwmark 0x1 lookup 100\n2: not from all fwmark 0x2 lookup 100\n",
			want:  []int{100},
		},
		{
			name:  "several unmarked tables",
			rules: "1: not from all fwmark 0x1 lookup 100\n2: not from all fwmark 0x2 lookup 200\n",
			want:  []int{100, 200},
		},
		{
			name:  "garbage yields nothing",
			rules: "not a rule at all\n",
			want:  nil,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := parseUnmarkedRuleTables(tc.rules)
			if len(got) != len(tc.want) {
				t.Fatalf("parseUnmarkedRuleTables = %v, want %v", got, tc.want)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Fatalf("parseUnmarkedRuleTables = %v, want %v", got, tc.want)
				}
			}
		})
	}
}

func TestSplitServerDefaultsToTLSPort(t *testing.T) {
	host, port := splitServer("vpn.example.net:8443")
	if host != "vpn.example.net" || port != "8443" {
		t.Errorf("splitServer(host:port) = %q,%q", host, port)
	}
	host, port = splitServer("vpn.example.net")
	if host != "vpn.example.net" || port != "443" {
		t.Errorf("splitServer(bare host) = %q,%q, want 443 default", host, port)
	}
	host, port = splitServer("[2001:db8::1]:443")
	if host != "2001:db8::1" || port != "443" {
		t.Errorf("splitServer(v6) = %q,%q", host, port)
	}
}
