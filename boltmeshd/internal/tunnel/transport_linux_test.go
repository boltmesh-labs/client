//go:build linux

// Behavior suite for the stream transport rung. The forwarder process and
// its readiness probe are fakes; the privileged work (writing the
// root-only document, pinning and removing routes) goes through the same
// recorded run seam the wg-quick suite uses.
package tunnel

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"

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

type transportHarness struct {
	m       *Manager
	calls   *[]transportRunCall
	dev     *fakeAwgDevice
	stopped int
	started []string // forwarder config paths passed to the start seam
	tunMade int
}

func streamSpec() *protocol.TransportSpec {
	return &protocol.TransportSpec{
		Mode:     protocol.TransportModeStream,
		Listen:   "127.0.0.1:51821",
		Upstream: "203.0.113.10:443",
		Config:   `{"inbounds":[{"type":"mixed"}]}`,
		Binary:   "boltmesh-forwarder",
	}
}

// nativeConfig points the peer at the loopback listen address, as the client
// does for the stream rung.
const streamConfig = `[Interface]
PrivateKey = ` + keyA + `
Address = 10.8.0.5/32
DNS = 10.8.0.1

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
	m.startForwarder = func(_ context.Context, _ string, configPath string) (func() error, error) {
		h.started = append(h.started, configPath)
		return func() error { h.stopped++; return nil }, nil
	}
	m.waitForwarder = func(context.Context, string) error { return nil }
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

func TestUpWithStreamTransportPinsUpstreamBeforeWgQuick(t *testing.T) {
	h := newTransportHarness(t, false)

	if _, err := h.m.Up(context.Background(), streamConfig, streamSpec()); err != nil {
		t.Fatalf("Up = %v, want nil", err)
	}

	// The bypass route must be installed before wg-quick runs: from the
	// moment the tunnel's routes exist, the forwarder's egress would be
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
	// The forwarder is started with the root-only document and waited for.
	if len(h.started) != 1 {
		t.Fatalf("forwarder started %d times, want 1", len(h.started))
	}
	info, err := os.Stat(h.started[0])
	if err != nil {
		t.Fatalf("forwarder config: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("forwarder config mode = %v, want 0600", info.Mode().Perm())
	}
	data, err := os.ReadFile(h.started[0])
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"type":"mixed"`) {
		t.Errorf("forwarder config document = %q, want the client's document verbatim", data)
	}
	// wg-quick saw a config whose endpoint is the loopback listen address.
	if !h.has(wgQuickBinary, "up", h.m.configPath()) {
		t.Errorf("wg-quick up missing:\n%v", h.callStrings())
	}
}

func TestUpWithStreamTransportPinsWgQuickTables(t *testing.T) {
	h := newTransportHarness(t, false)
	if _, err := h.m.Up(context.Background(), streamConfig, streamSpec()); err != nil {
		t.Fatalf("Up = %v, want nil", err)
	}

	// wg-quick's strict-mode rules steer *unmarked* packets (the forwarder)
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

func TestDownTearsDownForwarderAndEveryPinnedRoute(t *testing.T) {
	h := newTransportHarness(t, true)
	if _, err := h.m.Up(context.Background(), streamConfig, streamSpec()); err != nil {
		t.Fatalf("Up = %v, want nil", err)
	}
	*h.calls = (*h.calls)[:0]

	if _, err := h.m.Down(context.Background()); err != nil {
		t.Fatalf("Down = %v, want nil", err)
	}
	if h.stopped != 1 {
		t.Errorf("forwarder stopped %d times, want exactly 1", h.stopped)
	}
	// Both the main-table pin and the wg-quick-table pin are removed.
	if !h.has("ip", "route", "del", "203.0.113.10/32") {
		t.Errorf("main-table bypass route left behind:\n%v", h.callStrings())
	}
	if !h.has("ip", "route", "del", "203.0.113.10/32", "table", "51820") {
		t.Errorf("wg-quick-table bypass route left behind:\n%v", h.callStrings())
	}
	if _, err := os.Stat(h.m.forwarderConfigPath()); !os.IsNotExist(err) {
		t.Error("forwarder config survived a successful teardown")
	}
	if h.m.fwd != nil {
		t.Error("live forwarder marker survived a successful teardown")
	}
}

func TestUpWithStreamTransportTearsDownBeforeRetry(t *testing.T) {
	h := newTransportHarness(t, true)
	if _, err := h.m.Up(context.Background(), streamConfig, streamSpec()); err != nil {
		t.Fatalf("Up = %v, want nil", err)
	}
	stoppedBefore := h.stopped

	// A retry (native config, no transport) must not orphan the forwarder.
	if _, err := h.m.Up(context.Background(), validConfig, nil); err != nil {
		t.Fatalf("Up(native) = %v, want nil", err)
	}
	if h.stopped != stoppedBefore+1 {
		t.Errorf("forwarder stopped %d times, want the retry to stop it once more (%d)", h.stopped, stoppedBefore+1)
	}
	if h.m.fwd != nil {
		t.Error("retry left a live forwarder marker")
	}
}

func TestUpRejectsTransportWithObfuscatedConfig(t *testing.T) {
	h := newTransportHarness(t, false)
	// One rung at a time: a stream already carries the tunnel inside a
	// camouflaged stream, so the obfuscation parameters would be redundant.
	_, err := h.m.Up(context.Background(), obfuscatedConfig, streamSpec())
	var opErr *protocol.OpError
	if !errors.As(err, &opErr) || opErr.Code != protocol.CodeBadConfig {
		t.Fatalf("Up(obfuscated + transport) = %v, want bad config", err)
	}
	if h.tunMade != 0 || len(h.started) != 0 {
		t.Error("a rejected combination must not create a data plane or a forwarder")
	}
	if h.m.fwd != nil {
		t.Error("a rejected combination left a live forwarder marker")
	}
}

func TestUpWithStreamTransportRecoversWhenWgQuickFails(t *testing.T) {
	h := newTransportHarness(t, false)
	// Fail wg-quick only; the forwarder and its pins must still be swept.
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
	if h.stopped != 1 {
		t.Errorf("forwarder stopped %d times after a failed up, want 1", h.stopped)
	}
	if h.m.fwd != nil {
		t.Error("a failed up left a live forwarder marker")
	}
	if !h.has("ip", "route", "del", "203.0.113.10/32") {
		t.Errorf("bypass route left behind after a failed up:\n%v", h.callStrings())
	}
	if _, err := os.Stat(h.m.forwarderConfigPath()); !os.IsNotExist(err) {
		t.Error("forwarder config left behind after a failed up")
	}
}

func TestUpWithStreamTransportFailsClosedWhenForwarderNeverListens(t *testing.T) {
	h := newTransportHarness(t, false)
	h.m.waitForwarder = func(context.Context, string) error {
		return errors.New("no listener within 5s")
	}

	_, err := h.m.Up(context.Background(), streamConfig, streamSpec())
	if err == nil {
		t.Fatal("Up = nil, want the readiness failure")
	}
	// The recovery pass stops the forwarder it started rather than leaving
	// a process behind a "failed" up.
	if h.stopped != 1 {
		t.Errorf("forwarder stopped %d times, want 1", h.stopped)
	}
	// wg-quick never ran: the tunnel is not brought up on a dead forwarder.
	if h.has(wgQuickBinary) {
		t.Errorf("wg-quick ran despite an unready forwarder:\n%v", h.callStrings())
	}
}

func TestUpWithStreamTransportFailsClosedWithoutForwarderBinary(t *testing.T) {
	h := newTransportHarness(t, false)
	// A missing binary must not leave a privileged document behind, and
	// must never start a tunnel.
	h.m.lookup = func(name string) (string, error) {
		if name == streamSpec().Binary {
			return "", errors.New("not found under the fixed tool directories")
		}
		return name, nil
	}

	_, err := h.m.Up(context.Background(), streamConfig, streamSpec())
	if err == nil {
		t.Fatal("Up = nil, want the missing-binary failure")
	}
	if len(h.started) != 0 {
		t.Error("a forwarder was started without a resolvable binary")
	}
	if h.has(wgQuickBinary) {
		t.Errorf("wg-quick ran despite a missing forwarder binary:\n%v", h.callStrings())
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
			name: "marked rules and the main table are not the forwarder's path",
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

func TestSplitUpstreamDefaultsToTLSPort(t *testing.T) {
	host, port := splitUpstream("vpn.example.net:8443")
	if host != "vpn.example.net" || port != "8443" {
		t.Errorf("splitUpstream(host:port) = %q,%q", host, port)
	}
	host, port = splitUpstream("vpn.example.net")
	if host != "vpn.example.net" || port != "443" {
		t.Errorf("splitUpstream(bare host) = %q,%q, want 443 default", host, port)
	}
	host, port = splitUpstream("[2001:db8::1]:443")
	if host != "2001:db8::1" || port != "443" {
		t.Errorf("splitUpstream(v6) = %q,%q", host, port)
	}
}
