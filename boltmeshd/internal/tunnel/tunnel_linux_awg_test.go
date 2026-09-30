//go:build linux

// Behavior suite for the userspace AmneziaWG data plane the Linux manager
// selects for obfuscated configs. The device, tun, and endpoint resolution
// are fakes; the ip/resolver command surface goes through the same recorded
// run seam the wg-quick suite uses.
package tunnel

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	awgtun "github.com/amnezia-vpn/amneziawg-go/v3/tun"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"

	"boltmeshd/internal/protocol"
)

// fakeAwgDevice records the UAPI bodies it is configured with and replays a
// canned dump.
type fakeAwgDevice struct {
	configureErr error
	dumpErr      error
	dumpBody     string
	bodies       []string
	closed       int
}

func (d *fakeAwgDevice) configure(_ context.Context, body []byte) error {
	d.bodies = append(d.bodies, string(body))
	return d.configureErr
}

func (d *fakeAwgDevice) dump(context.Context) ([]byte, error) {
	if d.dumpErr != nil {
		return nil, d.dumpErr
	}
	return []byte(d.dumpBody), nil
}

func (d *fakeAwgDevice) close() error {
	d.closed++
	return nil
}

// awgRunCall records one privileged tool invocation, including the stdin
// payload resolvconf reads.
type awgRunCall struct {
	name  string
	args  []string
	input string
}

func (c awgRunCall) String() string {
	return c.name + " " + strings.Join(c.args, " ")
}

// awgHarness wires a manager whose every privileged action is recorded, with
// route-get answered with a canned physical path.
type awgHarness struct {
	m          *Manager
	calls      *[]awgRunCall
	dev        *fakeAwgDevice
	tunCreates int
}

func newAwgHarness(t *testing.T) *awgHarness {
	t.Helper()
	dev := &fakeAwgDevice{
		dumpBody: "public_key=" + mustHex(t, keyB) + "\n" +
			"endpoint=203.0.113.10:51820\n" +
			"last_handshake_time_sec=1000\n" +
			"last_handshake_time_nsec=0\n" +
			"tx_bytes=200\nrx_bytes=100\n",
	}
	m := NewManager(t.TempDir(), DefaultInterface)
	// Passthrough tool resolution: the assertions know the bare names.
	m.lookup = func(name string) (string, error) { return name, nil }
	calls := &[]awgRunCall{}
	m.run = func(_ context.Context, name string, args ...string) ([]byte, error) {
		*calls = append(*calls, awgRunCall{name: name, args: args})
		if len(args) >= 2 && args[0] == "route" && args[1] == "get" {
			return []byte("203.0.113.10 via 192.168.1.1 dev eth0 src 192.168.1.5"), nil
		}
		return []byte("ok"), nil
	}
	m.runInput = func(_ context.Context, input string, name string, args ...string) ([]byte, error) {
		*calls = append(*calls, awgRunCall{name: name, args: args, input: input})
		return []byte("ok"), nil
	}
	m.linkExists = func(string) bool { return false }
	m.device = func(string) (*wgtypes.Device, error) { return nil, os.ErrNotExist }
	m.resolveHost = func(_ context.Context, _ string) ([]net.IP, error) {
		return []net.IP{net.ParseIP("198.51.100.20")}, nil
	}
	h := &awgHarness{m: m, calls: calls, dev: dev}
	m.makeAwgTun = func(_ string, _ int) (awgtun.Device, error) {
		h.tunCreates++
		return nil, nil
	}
	m.makeAwgDevice = func(awgtun.Device) (awgDevice, error) { return dev, nil }
	return h
}

func (h *awgHarness) callStrings() []string {
	out := make([]string, 0, len(*h.calls))
	for _, c := range *h.calls {
		out = append(out, c.String())
	}
	return out
}

func (h *awgHarness) findCall(name string, args ...string) bool {
	for _, c := range *h.calls {
		if c.name == name && strings.Join(c.args, " ") == strings.Join(args, " ") {
			return true
		}
	}
	return false
}

func TestUpObfuscatedConfiguresDeviceAndNetwork(t *testing.T) {
	h := newAwgHarness(t)

	st, err := h.m.Up(context.Background(), obfuscatedConfig)
	if err != nil {
		t.Fatalf("Up(obfuscatedConfig) = %v, want nil", err)
	}
	if !st.Up || st.Stage != protocol.StageConnected {
		t.Fatalf("want a connected tunnel, got %+v", st)
	}
	if st.PublicKey != keyB {
		t.Errorf("publicKey = %q, want the base64 peer key %q", st.PublicKey, keyB)
	}
	if st.Endpoint != "203.0.113.10:51820" {
		t.Errorf("endpoint = %q", st.Endpoint)
	}

	// The device is configured with the obfuscation-aware UAPI body.
	if len(h.dev.bodies) != 1 {
		t.Fatalf("device configured %d times, want 1", len(h.dev.bodies))
	}
	for _, want := range []string{
		"private_key=" + mustHex(t, keyA),
		"public_key=" + mustHex(t, keyB),
		"endpoint=203.0.113.10:51820",
		"jc=3", "jmin=40", "jmax=70",
		"s1=15", "s2=17", "s3=10", "s4=5",
		"h1=115-120", "h2=130", "h3=150-160", "h4=171",
	} {
		if !strings.Contains(h.dev.bodies[0], want+"\n") {
			t.Errorf("device body missing %q:\n%s", want, h.dev.bodies[0])
		}
	}

	// One tun, one device, and the exact privileged command sequence: plan
	// the endpoint's physical path, pin it, then address, link, routes, DNS.
	if h.tunCreates != 1 {
		t.Errorf("tun created %d times, want 1", h.tunCreates)
	}
	wantCalls := []string{
		"ip route get 203.0.113.10",
		"ip route replace 203.0.113.10/32 via 192.168.1.1 dev eth0",
		"ip address replace 10.8.0.5/32 dev boltmesh0",
		"ip link set dev boltmesh0 up",
		"ip route replace default dev boltmesh0 metric 1",
		"resolvconf -a boltmesh0 -m 0 -x",
	}
	if got := h.callStrings(); !equalStrings(got, wantCalls) {
		t.Errorf("calls =\n%v\nwant\n%v", got, wantCalls)
	}
	// The tunnel's DNS rides resolvconf's stdin.
	for _, c := range *h.calls {
		if c.name == resolvconfBinary && c.input != "nameserver 10.8.0.1\n" {
			t.Errorf("resolvconf input = %q, want the DNS directive", c.input)
		}
	}
	// wg-quick is never invoked by the userspace data plane.
	if h.findCall(wgQuickBinary) {
		t.Error("wg-quick must not be invoked for an obfuscated config")
	}

	// The privileged config is on disk for recovery, root-only.
	info, err := os.Stat(h.m.configPath())
	if err != nil {
		t.Fatalf("config file: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("config mode = %v, want 0600", info.Mode().Perm())
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestUpObfuscatedResolvesHostnameEndpoint(t *testing.T) {
	h := newAwgHarness(t)
	text := strings.Replace(obfuscatedConfig,
		"Endpoint = 203.0.113.10:51820", "Endpoint = vpn.example.net:51820", 1)

	if _, err := h.m.Up(context.Background(), text); err != nil {
		t.Fatalf("Up: %v", err)
	}
	if !h.findCall("ip", "route", "replace", "198.51.100.20/32", "via", "192.168.1.1", "dev", "eth0") {
		t.Errorf("resolved endpoint not pinned:\n%v", h.callStrings())
	}
	if !strings.Contains(h.dev.bodies[0], "endpoint=vpn.example.net:51820\n") {
		t.Errorf("device endpoint = %q", h.dev.bodies[0])
	}
}

func TestUpObfuscatedRejectsMissingEndpointBeforeCreatingAnything(t *testing.T) {
	h := newAwgHarness(t)
	text := strings.Replace(obfuscatedConfig, "Endpoint = 203.0.113.10:51820\n", "", 1)

	_, err := h.m.Up(context.Background(), text)
	var opErr *protocol.OpError
	if !errors.As(err, &opErr) || opErr.Code != protocol.CodeBadConfig {
		t.Fatalf("Up(no endpoint) = %v, want bad config", err)
	}
	if h.tunCreates != 0 || len(h.dev.bodies) != 0 {
		t.Error("a rejected config must not create a data plane")
	}
	if _, statErr := os.Stat(h.m.configPath()); !os.IsNotExist(statErr) {
		t.Error("config file left behind by a rejected config")
	}
}

func TestUpObfuscatedFailsClosedWhenEndpointUnreachable(t *testing.T) {
	h := newAwgHarness(t)
	h.m.run = func(_ context.Context, name string, args ...string) ([]byte, error) {
		*h.calls = append(*h.calls, awgRunCall{name: name, args: args})
		if len(args) >= 2 && args[0] == "route" && args[1] == "get" {
			return nil, errors.New("RTNETLINK answers: Network is unreachable")
		}
		return []byte("ok"), nil
	}

	_, err := h.m.Up(context.Background(), obfuscatedConfig)
	var opErr *protocol.OpError
	if !errors.As(err, &opErr) || opErr.Code != protocol.CodeInternal {
		t.Fatalf("Up(unreachable) = %v, want internal", err)
	}
	if h.tunCreates != 0 || len(h.dev.bodies) != 0 {
		t.Error("an unreachable endpoint must not create a data plane")
	}
	if _, statErr := os.Stat(h.m.configPath()); !os.IsNotExist(statErr) {
		t.Error("config file left behind by a failed plan")
	}
}

func TestUpObfuscatedFailedStartRunsBoundedRecovery(t *testing.T) {
	h := newAwgHarness(t)
	h.dev.configureErr = errors.New("device rejected the config")

	_, err := h.m.Up(context.Background(), obfuscatedConfig)
	var opErr *protocol.OpError
	if !errors.As(err, &opErr) || opErr.Code != protocol.CodeInternal {
		t.Fatalf("Up(failing device) = %v, want internal", err)
	}
	if !strings.Contains(err.Error(), "obfuscated up") {
		t.Errorf("error = %v, want the obfuscated-up context", err)
	}
	// The recovery pass closed the device and swept the routes it had planned.
	if h.dev.closed != 1 {
		t.Errorf("device closed %d times, want 1", h.dev.closed)
	}
	if !h.findCall("ip", "route", "del", "203.0.113.10/32") {
		t.Errorf("underlay route not deleted:\n%v", h.callStrings())
	}
	if !h.findCall(resolvconfBinary, "-d", "boltmesh0", "-f") {
		t.Errorf("resolver state not cleaned:\n%v", h.callStrings())
	}
	// The config is removed only once the recovery finished.
	if _, statErr := os.Stat(h.m.configPath()); !os.IsNotExist(statErr) {
		t.Error("config file left behind by a completed recovery")
	}
}

func TestUpObfuscatedKeepsConfigWhenRecoveryCannotFinish(t *testing.T) {
	h := newAwgHarness(t)
	h.dev.configureErr = errors.New("device rejected the config")
	// Every command after the plan fails, so the recovery cannot complete.
	h.m.run = func(_ context.Context, name string, args ...string) ([]byte, error) {
		*h.calls = append(*h.calls, awgRunCall{name: name, args: args})
		if len(args) >= 2 && args[0] == "route" && args[1] == "get" {
			return []byte("203.0.113.10 via 192.168.1.1 dev eth0"), nil
		}
		return nil, errors.New("broken system")
	}

	_, err := h.m.Up(context.Background(), obfuscatedConfig)
	if err == nil {
		t.Fatal("Up = nil, want the recovery failure")
	}
	if _, statErr := os.Stat(h.m.configPath()); os.IsNotExist(statErr) {
		t.Error("an incomplete cleanup must keep the config as the retry handle")
	}
}

func TestDownObfuscatedTearsEverythingDown(t *testing.T) {
	h := newAwgHarness(t)
	if _, err := h.m.Up(context.Background(), obfuscatedConfig); err != nil {
		t.Fatalf("Up: %v", err)
	}

	st, err := h.m.Down(context.Background())
	if err != nil {
		t.Fatalf("Down: %v", err)
	}
	if st.Up {
		t.Errorf("status after down = %+v, want a down tunnel", st)
	}
	if h.dev.closed != 1 {
		t.Errorf("device closed %d times, want exactly 1", h.dev.closed)
	}
	if !h.findCall("ip", "route", "del", "203.0.113.10/32") {
		t.Errorf("underlay route survives the teardown:\n%v", h.callStrings())
	}
	if !h.findCall(resolvconfBinary, "-d", "boltmesh0", "-f") {
		t.Errorf("resolver state survives the teardown:\n%v", h.callStrings())
	}
	if _, statErr := os.Stat(h.m.configPath()); !os.IsNotExist(statErr) {
		t.Error("config file survives a successful teardown")
	}
}

func TestStatusPrefersTheLiveUserspaceDevice(t *testing.T) {
	h := newAwgHarness(t)
	if _, err := h.m.Up(context.Background(), obfuscatedConfig); err != nil {
		t.Fatalf("Up: %v", err)
	}
	// The tun link exists (it is a netdev) and a kernel device read would
	// also succeed — the live userspace device must win either way.
	h.m.linkExists = func(string) bool { return true }
	h.m.device = func(string) (*wgtypes.Device, error) { return deviceWithPeers(t), nil }

	st, err := h.m.Status(context.Background())
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	// The wgctrl double's newest handshake belongs to keyA; the userspace
	// dump's only peer is keyB.
	if !st.Up || st.PublicKey != keyB {
		t.Errorf("status = %+v, want the userspace dump's peer", st)
	}
}

func TestNativeUpAfterObfuscatedTunnelBouncesIt(t *testing.T) {
	h := newAwgHarness(t)
	if _, err := h.m.Up(context.Background(), obfuscatedConfig); err != nil {
		t.Fatalf("Up(obfuscated): %v", err)
	}
	linkUp := true
	h.m.linkExists = func(string) bool { return linkUp }
	h.m.device = func(string) (*wgtypes.Device, error) { return deviceWithPeers(t), nil }

	if _, err := h.m.Up(context.Background(), validConfig); err != nil {
		t.Fatalf("Up(validConfig): %v", err)
	}
	if h.dev.closed != 1 {
		t.Errorf("the previous userspace tunnel was not torn down (closed=%d)", h.dev.closed)
	}
	if !h.findCall("ip", "route", "del", "203.0.113.10/32") {
		t.Errorf("the obfuscated underlay route was not swept:\n%v", h.callStrings())
	}
	if !h.findCall(wgQuickBinary, "up", h.m.configPath()) {
		t.Errorf("the native up never ran wg-quick:\n%v", h.callStrings())
	}
}

func TestObfuscatedUpAfterNativeTunnelBouncesIt(t *testing.T) {
	h := newAwgHarness(t)
	h.m.device = func(string) (*wgtypes.Device, error) { return deviceWithPeers(t), nil }
	if _, err := h.m.Up(context.Background(), validConfig); err != nil {
		t.Fatalf("Up(validConfig): %v", err)
	}
	if !h.findCall(wgQuickBinary, "up", h.m.configPath()) {
		t.Fatalf("the native up never ran wg-quick:\n%v", h.callStrings())
	}

	if _, err := h.m.Up(context.Background(), obfuscatedConfig); err != nil {
		t.Fatalf("Up(obfuscatedConfig): %v", err)
	}
	// The lingering native config is swept before the userspace up writes
	// its own; the underlay plan then applies.
	if !h.findCall(resolvconfBinary, "-d", "boltmesh0", "-f") {
		t.Errorf("the native tunnel's resolver state was not swept:\n%v", h.callStrings())
	}
	if !h.findCall("ip", "route", "replace", "203.0.113.10/32", "via", "192.168.1.1", "dev", "eth0") {
		t.Errorf("the underlay route was never pinned:\n%v", h.callStrings())
	}
	if h.tunCreates != 1 {
		t.Errorf("tun created %d times, want 1", h.tunCreates)
	}
}

func TestDownRecoversStaleUnderlayRoutesFromConfig(t *testing.T) {
	h := newAwgHarness(t)
	// A daemon restart: no live device, but the obfuscated config lingers
	// with the underlay host routes still installed.
	if err := os.MkdirAll(h.m.dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(h.m.configPath(), []byte(obfuscatedConfig), 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := h.m.Down(context.Background()); err != nil {
		t.Fatalf("Down: %v", err)
	}
	if !h.findCall("ip", "route", "del", "203.0.113.10/32") {
		t.Errorf("the stale underlay route was not recovered:\n%v", h.callStrings())
	}
	if _, statErr := os.Stat(h.m.configPath()); !os.IsNotExist(statErr) {
		t.Error("config file survives a successful stale-state recovery")
	}
}

func TestSplitTunnelRoutesMirrorAllowedIPs(t *testing.T) {
	h := newAwgHarness(t)
	text := strings.Replace(obfuscatedConfig,
		"AllowedIPs = 0.0.0.0/0", "AllowedIPs = 1.0.0.0/8, 8.8.8.8/32, fd00::/8", 1)

	if _, err := h.m.Up(context.Background(), text); err != nil {
		t.Fatalf("Up: %v", err)
	}
	for _, want := range []string{
		"ip route replace 1.0.0.0/8 dev boltmesh0",
		"ip route replace 8.8.8.8/32 dev boltmesh0",
	} {
		if !h.findCall("ip", strings.Split(strings.TrimPrefix(want, "ip "), " ")...) {
			t.Errorf("tunnel route missing %q:\n%v", want, h.callStrings())
		}
	}
	v6Found := false
	for _, c := range *h.calls {
		if c.name == "ip" && strings.Contains(c.String(), "route replace fd00::/8 dev boltmesh0") {
			v6Found = true
		}
	}
	if !v6Found {
		t.Errorf("IPv6 tunnel route missing:\n%v", h.callStrings())
	}
}

func TestUpObfuscatedRejectsBadMTU(t *testing.T) {
	h := newAwgHarness(t)
	text := strings.Replace(obfuscatedConfig, "DNS = 10.8.0.1", "DNS = 10.8.0.1\nMTU = 99", 1)

	_, err := h.m.Up(context.Background(), text)
	var opErr *protocol.OpError
	if !errors.As(err, &opErr) || opErr.Code != protocol.CodeBadConfig {
		t.Fatalf("Up(bad MTU) = %v, want bad config", err)
	}
	if h.tunCreates != 0 {
		t.Error("a bad MTU must not create a data plane")
	}
}

func TestObfuscatedConfigSurvivesReUp(t *testing.T) {
	h := newAwgHarness(t)
	for i := 0; i < 2; i++ {
		if _, err := h.m.Up(context.Background(), obfuscatedConfig); err != nil {
			t.Fatalf("Up #%d: %v", i+1, err)
		}
	}
	// The second up bounces the first: one device live, everything planned
	// exactly once per cycle, and the tun recreated.
	if h.dev.closed != 1 {
		t.Errorf("the first tunnel was not bounced (closed=%d)", h.dev.closed)
	}
	if h.tunCreates != 2 {
		t.Errorf("tun created %d times, want 2", h.tunCreates)
	}
	// Exactly one resolvconf -a per up, and one sweep between them.
	adds, dels := 0, 0
	for _, c := range *h.calls {
		if c.name == resolvconfBinary && len(c.args) > 0 && c.args[0] == "-a" {
			adds++
		}
		if c.name == resolvconfBinary && len(c.args) > 0 && c.args[0] == "-d" {
			dels++
		}
	}
	if adds != 2 || dels != 1 {
		t.Errorf("resolver calls: %d adds, %d dels, want 2 and 1:\n%v", adds, dels, h.callStrings())
	}
}

// Verify the config-dir path joins the interface name the same way the
// wg-quick path does (shared configPath method).
func TestObfuscatedConfigPathMatchesNativeLayout(t *testing.T) {
	h := newAwgHarness(t)
	want := filepath.Join(h.m.dir, h.m.iface+".conf")
	if got := h.m.configPath(); got != want {
		t.Errorf("configPath = %q, want %q", got, want)
	}
}
