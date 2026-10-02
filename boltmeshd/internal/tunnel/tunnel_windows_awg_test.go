//go:build windows

// Behavior suite for the userspace AmneziaWG data plane the Windows manager selects for
// obfuscated configs. The device, adapter, and endpoint resolution are fakes; the
// routing table and the per-interface configuration go through the same recorded seams
// the transport suite uses.
//
// The assertions are about order and shape, not about Windows itself: that the endpoint
// is pinned before any route that could capture it, that the address lands before the
// routes that depend on it, and that a failure anywhere leaves nothing behind that a
// later down would not sweep.
package tunnel

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"strings"
	"testing"

	awgtun "github.com/amnezia-vpn/amneziawg-go/v3/tun"
	"golang.org/x/sys/windows"

	"boltmeshd/internal/protocol"
)

// fakeTun is an adapter double. It reports an interface identifier the way the Windows
// Wintun adapter does, because every address and route installed afterwards is addressed
// by that number.
type fakeTun struct {
	luid  uint64
	close func() error
}

func (f *fakeTun) File() *os.File                         { return nil }
func (f *fakeTun) Read([][]byte, []int, int) (int, error) { return 0, nil }
func (f *fakeTun) Write([][]byte, int) (int, error)       { return 0, nil }
func (f *fakeTun) MTU() (int, error)                      { return awgDefaultMTU, nil }
func (f *fakeTun) Name() (string, error)                  { return DefaultInterface, nil }
func (f *fakeTun) Events() <-chan awgtun.Event            { return nil }
func (f *fakeTun) BatchSize() int                         { return 1 }
func (f *fakeTun) LUID() uint64                           { return f.luid }

func (f *fakeTun) Close() error {
	if f.close != nil {
		return f.close()
	}
	return nil
}

// fakeNetIf records the address and DNS work, and can be told to fail any step.
type fakeNetIf struct {
	guid       windows.GUID
	guidErr    error
	addressErr error
	dnsErr     error

	guidCalls   []uint64
	addresses   []string
	dnsServers  []string
	dnsGuidSeen []windows.GUID
}

func (f *fakeNetIf) interfaceGUID(luid uint64) (windows.GUID, error) {
	f.guidCalls = append(f.guidCalls, luid)
	if f.guidErr != nil {
		return windows.GUID{}, f.guidErr
	}
	return f.guid, nil
}

func (f *fakeNetIf) addAddress(luid uint64, ip net.IP, bits uint8) error {
	if f.addressErr != nil {
		return f.addressErr
	}
	f.addresses = append(f.addresses, fmt.Sprintf("%s/%d on luid %d", ip, bits, luid))
	return nil
}

func (f *fakeNetIf) setDNS(guid windows.GUID, servers []net.IP) error {
	if f.dnsErr != nil {
		return f.dnsErr
	}
	f.dnsGuidSeen = append(f.dnsGuidSeen, guid)
	parts := make([]string, 0, len(servers))
	for _, ip := range servers {
		parts = append(parts, ip.String())
	}
	f.dnsServers = append(f.dnsServers, strings.Join(parts, ","))
	return nil
}

// awgHarness wires a manager whose every privileged action is recorded.
type awgHarness struct {
	m          *Manager
	svc        *fakeService
	routes     *fakeRoutes
	netIf      *fakeNetIf
	dev        *fakeAwgDevice
	tunCreates int
	pinWintun  func() (windows.Handle, error)
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
	// The ACL helpers are exercised by their own tests; no-op here so the temp config
	// dir stays writable.
	m.protectDir = func(string) error { return nil }
	m.protectFile = func(string) error { return nil }
	// The service is never started on this path, but these are still consulted by the
	// tests that cross over to a native config.
	m.exeDir = func() (string, error) { return `C:\app`, nil }
	m.stat = func(string) (os.FileInfo, error) { return nil, nil }

	svc := &fakeService{}
	routes := newFakeRoutes()
	netIf := &fakeNetIf{guid: windows.GUID{Data1: 0xabc}}
	h := &awgHarness{m: m, svc: svc, routes: routes, netIf: netIf, dev: dev}
	m.service = svc
	m.routes = routes
	m.netIf = netIf
	m.resolveHost = func(_ context.Context, _ string) ([]net.IP, error) {
		return []net.IP{net.ParseIP("198.51.100.20")}, nil
	}
	m.makeAwgTun = func(_ string, _ int) (awgtun.Device, error) {
		h.tunCreates++
		return &fakeTun{luid: 77}, nil
	}
	m.makeAwgDevice = func(awgtun.Device) (awgDevice, error) { return dev, nil }
	// The real pin copies wintun.dll into System32 and verifies it by hash, which needs
	// elevation. That has its own suite, including the elevated integration tests, so
	// the behaviour suite stands in a load that has already been verified.
	//
	// The indirection through h is deliberate: a test that reassigns h.pinWintun has to
	// take effect, and copying the function value into the Manager would freeze whatever
	// it was at construction time.
	h.pinWintun = func() (windows.Handle, error) { return 0, nil }
	m.loadWintun = func() (windows.Handle, error) { return h.pinWintun() }
	return h
}

func TestUpObfuscatedConfiguresDeviceAndNetwork(t *testing.T) {
	h := newAwgHarness(t)

	st, err := h.m.Up(context.Background(), obfuscatedConfig, nil)
	if err != nil {
		t.Fatalf("Up(obfuscatedConfig) = %v, want nil", err)
	}
	if !st.Up || st.Stage != protocol.StageConnected {
		t.Fatalf("want a connected tunnel, got %+v", st)
	}
	if st.PublicKey != keyB {
		t.Errorf("publicKey = %q, want the base64 peer key %q", st.PublicKey, keyB)
	}

	// The device is configured with the obfuscation-aware UAPI body, so the region's
	// directives reach the node's AmneziaWG device rather than a kernel tunnel.
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

	// One adapter, one device.
	if h.tunCreates != 1 {
		t.Errorf("adapter created %d times, want 1", h.tunCreates)
	}

	// The endpoint is pinned through the physical path, the address goes on the tunnel
	// adapter, the peer's AllowedIPs become routes on it, and DNS follows.
	if len(h.routes.added) != 1 || !h.routes.added[0].Equal(net.ParseIP("203.0.113.10")) {
		t.Errorf("underlay pins = %v, want one for the endpoint 203.0.113.10", h.routes.added)
	}
	if len(h.netIf.addresses) != 1 || h.netIf.addresses[0] != "10.8.0.5/32 on luid 77" {
		t.Errorf("addresses = %v, want the tunnel address on the adapter's LUID", h.netIf.addresses)
	}
	if len(h.routes.prefixes) != 1 {
		t.Fatalf("tunnel routes = %v, want one for AllowedIPs = 0.0.0.0/0", h.routes.prefixes)
	}
	if want := "0.0.0.0/0 on luid 77 metric 1 nextHop <nil>"; h.routes.prefixes[0] != want {
		t.Errorf("tunnel route = %q, want %q", h.routes.prefixes[0], want)
	}
	if len(h.netIf.dnsServers) != 1 || h.netIf.dnsServers[0] != "10.8.0.1" {
		t.Errorf("DNS servers = %v, want the config's 10.8.0.1", h.netIf.dnsServers)
	}
	if len(h.netIf.dnsGuidSeen) != 1 || h.netIf.dnsGuidSeen[0] != h.netIf.guid {
		t.Errorf("DNS was applied to %v, want the adapter GUID %v", h.netIf.dnsGuidSeen, h.netIf.guid)
	}

	// wg-quick's absence is the point: the WireGuard service must never be started for a
	// config the kernel driver cannot represent.
	if h.m.service.(*fakeService).starts != 0 {
		t.Error("the tunnel service was started for an obfuscated config")
	}

	// The privileged config is on disk for recovery.
	if _, err := os.Stat(h.m.configPath()); err != nil {
		t.Fatalf("config file: %v", err)
	}
}

func TestUpObfuscatedResolvesHostnameEndpoint(t *testing.T) {
	h := newAwgHarness(t)
	text := strings.Replace(obfuscatedConfig,
		"Endpoint = 203.0.113.10:51820", "Endpoint = vpn.example.net:51820", 1)

	if _, err := h.m.Up(context.Background(), text, nil); err != nil {
		t.Fatalf("Up: %v", err)
	}
	if len(h.routes.added) != 1 || !h.routes.added[0].Equal(net.ParseIP("198.51.100.20")) {
		t.Errorf("resolved endpoint not pinned: %v", h.routes.added)
	}
	if !strings.Contains(h.dev.bodies[0], "endpoint=vpn.example.net:51820\n") {
		t.Errorf("device endpoint = %q", h.dev.bodies[0])
	}
}

func TestUpObfuscatedPinsNothingForALoopbackEndpoint(t *testing.T) {
	h := newAwgHarness(t)
	// The stream-carried shape: the peer's endpoint is the local bridge, and the
	// transport's own bring-up pinned the node's real upstream.
	text := strings.Replace(obfuscatedConfig,
		"Endpoint = 203.0.113.10:51820", "Endpoint = 127.0.0.1:39735", 1)

	if _, err := h.m.Up(context.Background(), text, nil); err != nil {
		t.Fatalf("Up: %v", err)
	}
	if len(h.routes.added) != 0 {
		t.Errorf("loopback endpoint pinned routes: %v, want none", h.routes.added)
	}
	// The tunnel itself still comes up; it is only the underlay pin that is skipped.
	if len(h.netIf.addresses) != 1 {
		t.Errorf("addresses = %v, want the tunnel address installed", h.netIf.addresses)
	}
}

func TestUpObfuscatedRejectsMissingEndpointBeforeCreatingAnything(t *testing.T) {
	h := newAwgHarness(t)
	text := strings.Replace(obfuscatedConfig, "Endpoint = 203.0.113.10:51820\n", "", 1)

	_, err := h.m.Up(context.Background(), text, nil)
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

func TestUpObfuscatedFailsClosedWhenEndpointHasNoPhysicalPath(t *testing.T) {
	h := newAwgHarness(t)
	h.routes.bestErr = errors.New("GetBestRoute2: no route to host")

	_, err := h.m.Up(context.Background(), obfuscatedConfig, nil)
	var opErr *protocol.OpError
	if !errors.As(err, &opErr) || opErr.Code != protocol.CodeInternal {
		t.Fatalf("Up(unreachable) = %v, want internal", err)
	}
	if h.tunCreates != 0 || len(h.dev.bodies) != 0 {
		t.Error("an endpoint with no physical path must not create a data plane")
	}
	if _, statErr := os.Stat(h.m.configPath()); !os.IsNotExist(statErr) {
		t.Error("config file left behind by a failed plan")
	}
}

func TestUpObfuscatedPinsTheTunnelDriverFirst(t *testing.T) {
	h := newAwgHarness(t)
	var order []string
	h.pinWintun = func() (windows.Handle, error) {
		order = append(order, "pin-driver")
		return 0, nil
	}
	h.m.makeAwgTun = func(string, int) (awgtun.Device, error) {
		order = append(order, "create-adapter")
		return &fakeTun{luid: 77}, nil
	}

	if _, err := h.m.Up(context.Background(), obfuscatedConfig, nil); err != nil {
		t.Fatalf("Up: %v", err)
	}
	// The AmneziaWG device's Wintun binding resolves "wintun.dll" by name at first use,
	// so the verified copy has to be mapped before the adapter is created — otherwise the
	// driver that loads is whatever the search turned up.
	if len(order) != 2 || order[0] != "pin-driver" || order[1] != "create-adapter" {
		t.Errorf("order = %v, want the driver pinned before the adapter is created", order)
	}
}

func TestUpObfuscatedRefusesToStartWithoutTheDriverPin(t *testing.T) {
	h := newAwgHarness(t)
	h.pinWintun = func() (windows.Handle, error) {
		return 0, errors.New("vendored wintun.dll is unreadable")
	}

	_, err := h.m.Up(context.Background(), obfuscatedConfig, nil)
	if err == nil {
		t.Fatal("Up succeeded with the driver unpinned")
	}
	if !strings.Contains(err.Error(), "tunnel driver") {
		t.Errorf("error = %v, want it to name the driver pin", err)
	}
	if h.tunCreates != 0 {
		t.Error("an unpinned driver must not be followed by an adapter")
	}
}

func TestUpObfuscatedRefusesAnAdapterWithoutAnInterfaceID(t *testing.T) {
	h := newAwgHarness(t)
	// The LUID comes from a type assertion on the tun.Device interface, so an adapter
	// that does not provide one has to be refused rather than configured blind.
	h.m.makeAwgTun = func(string, int) (awgtun.Device, error) {
		h.tunCreates++
		return noLUIDTun{}, nil
	}

	_, err := h.m.Up(context.Background(), obfuscatedConfig, nil)
	if err == nil {
		t.Fatal("Up succeeded with an adapter reporting no interface identifier")
	}
	if !strings.Contains(err.Error(), "interface identifier") {
		t.Errorf("error = %v, want it to name the missing interface identifier", err)
	}
	if len(h.dev.bodies) != 0 {
		t.Error("no device should be started on an adapter with no identity")
	}
}

func TestUpObfuscatedFailedStartRunsBoundedRecovery(t *testing.T) {
	h := newAwgHarness(t)
	h.dev.configureErr = errors.New("device rejected the config")

	_, err := h.m.Up(context.Background(), obfuscatedConfig, nil)
	var opErr *protocol.OpError
	if !errors.As(err, &opErr) || opErr.Code != protocol.CodeInternal {
		t.Fatalf("Up(failing device) = %v, want internal", err)
	}
	if !strings.Contains(err.Error(), "obfuscated up") {
		t.Errorf("error = %v, want the obfuscated-up context", err)
	}
	// The recovery pass closed the device, which takes the adapter with it.
	if h.dev.closed != 1 {
		t.Errorf("device closed %d times, want 1", h.dev.closed)
	}
	// The underlay pin it had planned is swept explicitly: it lives on the physical
	// interface and does not die with the adapter.
	if len(h.routes.deleted) != 1 || !h.routes.deleted[0].Equal(net.ParseIP("203.0.113.10")) {
		t.Errorf("underlay pins swept = %v, want the endpoint's", h.routes.deleted)
	}
	if _, statErr := os.Stat(h.m.configPath()); !os.IsNotExist(statErr) {
		t.Error("config file left behind by a completed recovery")
	}
}

func TestUpObfuscatedKeepsConfigWhenRecoveryCannotFinish(t *testing.T) {
	h := newAwgHarness(t)
	h.dev.configureErr = errors.New("device rejected the config")
	h.routes.deleteErr = errors.New("forward table is locked")

	_, err := h.m.Up(context.Background(), obfuscatedConfig, nil)
	if err == nil {
		t.Fatal("Up = nil, want the recovery failure")
	}
	if _, statErr := os.Stat(h.m.configPath()); os.IsNotExist(statErr) {
		t.Error("an incomplete cleanup must keep the config as the retry handle")
	}
}

func TestUpObfuscatedRollsBackWhenTheAddressCannotBeAssigned(t *testing.T) {
	h := newAwgHarness(t)
	h.netIf.addressErr = errors.New("the interface has no room for another address")

	_, err := h.m.Up(context.Background(), obfuscatedConfig, nil)
	if err == nil {
		t.Fatal("Up succeeded with no address on the adapter")
	}
	if !strings.Contains(err.Error(), "assign tunnel address") {
		t.Errorf("error = %v, want it to name the address step", err)
	}
	// The address precedes the routes, so none were installed.
	if len(h.routes.prefixes) != 0 {
		t.Errorf("tunnel routes = %v, want none: the address comes first", h.routes.prefixes)
	}
	// And the endpoint pin it did install is swept.
	if len(h.routes.deleted) != 1 {
		t.Errorf("underlay pins swept = %v, want the one it installed", h.routes.deleted)
	}
}

func TestDownObfuscatedTearsEverythingDown(t *testing.T) {
	h := newAwgHarness(t)
	if _, err := h.m.Up(context.Background(), obfuscatedConfig, nil); err != nil {
		t.Fatalf("Up: %v", err)
	}

	st, err := h.m.Down(context.Background())
	if err != nil {
		t.Fatalf("Down: %v", err)
	}
	if st.Up {
		t.Errorf("status after down = %+v, want a down tunnel", st)
	}
	// Closing the device is what removes the adapter, and with it the address, the
	// tunnel's routes and the DNS servers. None of those is unwound by a separate call.
	if h.dev.closed != 1 {
		t.Errorf("device closed %d times, want exactly 1", h.dev.closed)
	}
	if h.netIf.dnsErr != nil && len(h.netIf.dnsServers) == 0 {
		t.Fatal("the test never applied DNS")
	}
	if len(h.routes.deleted) != 1 || !h.routes.deleted[0].Equal(net.ParseIP("203.0.113.10")) {
		t.Errorf("underlay pins swept = %v, want the endpoint's", h.routes.deleted)
	}
	if _, statErr := os.Stat(h.m.configPath()); !os.IsNotExist(statErr) {
		t.Error("config file survives a successful teardown")
	}
}

func TestStatusPrefersTheLiveUserspaceDevice(t *testing.T) {
	h := newAwgHarness(t)
	if _, err := h.m.Up(context.Background(), obfuscatedConfig, nil); err != nil {
		t.Fatalf("Up: %v", err)
	}

	st, err := h.m.Status(context.Background())
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	// There is no service behind this tunnel, so a status read through the Service
	// Control Manager would report a live tunnel as one that is not installed.
	if !st.Up || st.PublicKey != keyB {
		t.Errorf("status = %+v, want the userspace dump's peer", st)
	}
}

func TestNativeUpAfterObfuscatedTunnelBouncesIt(t *testing.T) {
	h := newAwgHarness(t)
	if _, err := h.m.Up(context.Background(), obfuscatedConfig, nil); err != nil {
		t.Fatalf("Up(obfuscated): %v", err)
	}
	svc := h.m.service.(*fakeService)
	svc.stageVal = protocol.StageConnected

	if _, err := h.m.Up(context.Background(), validConfig, nil); err != nil {
		t.Fatalf("Up(validConfig): %v", err)
	}
	// The userspace tunnel is torn down by its own path on the way, because its adapter
	// would otherwise be in the way of the service's.
	if h.dev.closed != 1 {
		t.Errorf("the previous userspace tunnel was not torn down (closed=%d)", h.dev.closed)
	}
	if len(h.routes.deleted) != 1 {
		t.Errorf("the obfuscated underlay pin was not swept: %v", h.routes.deleted)
	}
	if svc.starts != 1 {
		t.Errorf("the native up did not start the tunnel service: %d starts", svc.starts)
	}
}

func TestObfuscatedUpAfterNativeTunnelBouncesIt(t *testing.T) {
	h := newAwgHarness(t)
	svc := h.m.service.(*fakeService)
	if _, err := h.m.Up(context.Background(), validConfig, nil); err != nil {
		t.Fatalf("Up(validConfig): %v", err)
	}
	if svc.starts != 1 {
		t.Fatalf("the native up never ran the tunnel service: %d starts", svc.starts)
	}

	if _, err := h.m.Up(context.Background(), obfuscatedConfig, nil); err != nil {
		t.Fatalf("Up(obfuscatedConfig): %v", err)
	}
	// The service is stopped on the way through: a registered service left running
	// would keep the native adapter installed under the userspace one.
	if svc.stops == 0 {
		t.Error("the native tunnel service was not stopped before the userspace up")
	}
	if len(h.routes.added) != 1 {
		t.Errorf("the endpoint was not pinned: %v", h.routes.added)
	}
	if h.tunCreates != 1 {
		t.Errorf("adapter created %d times, want 1", h.tunCreates)
	}
}

func TestDownRecoversStaleUnderlayRoutesFromConfig(t *testing.T) {
	h := newAwgHarness(t)
	// A daemon restart: no live device and no adapter — the Wintun handle died with the
	// process — but the obfuscated config lingers with the underlay host routes still
	// installed on the physical interface.
	if err := os.MkdirAll(h.m.dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(h.m.configPath(), []byte(obfuscatedConfig), 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := h.m.Down(context.Background()); err != nil {
		t.Fatalf("Down: %v", err)
	}
	if len(h.routes.deleted) != 1 || !h.routes.deleted[0].Equal(net.ParseIP("203.0.113.10")) {
		t.Errorf("the stale underlay route was not recovered: %v", h.routes.deleted)
	}
	if _, statErr := os.Stat(h.m.configPath()); !os.IsNotExist(statErr) {
		t.Error("config file survives a successful stale-state recovery")
	}
}

func TestSplitTunnelRoutesMirrorAllowedIPs(t *testing.T) {
	h := newAwgHarness(t)
	text := strings.Replace(obfuscatedConfig,
		"AllowedIPs = 0.0.0.0/0", "AllowedIPs = 1.0.0.0/8, 8.8.8.8/32, fd00::/8", 1)

	if _, err := h.m.Up(context.Background(), text, nil); err != nil {
		t.Fatalf("Up: %v", err)
	}
	for _, want := range []string{
		"1.0.0.0/8 on luid 77 metric 1 nextHop <nil>",
		"8.8.8.8/32 on luid 77 metric 1 nextHop <nil>",
		"fd00::/8 on luid 77 metric 1 nextHop <nil>",
	} {
		if !containsStr(strings.Join(h.routes.prefixes, "\n"), want) {
			t.Errorf("tunnel route %q missing:\n%v", want, h.routes.prefixes)
		}
	}
}

func TestUpObfuscatedRejectsBadMTU(t *testing.T) {
	h := newAwgHarness(t)
	text := strings.Replace(obfuscatedConfig, "DNS = 10.8.0.1", "DNS = 10.8.0.1\nMTU = 99", 1)

	_, err := h.m.Up(context.Background(), text, nil)
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
		if _, err := h.m.Up(context.Background(), obfuscatedConfig, nil); err != nil {
			t.Fatalf("Up #%d: %v", i+1, err)
		}
	}
	// The second up bounces the first, and the pin it replaced is swept rather than
	// accumulating.
	if h.dev.closed != 1 {
		t.Errorf("the first tunnel was not bounced (closed=%d)", h.dev.closed)
	}
	if h.tunCreates != 2 {
		t.Errorf("adapter created %d times, want 2", h.tunCreates)
	}
	if len(h.routes.added) != 2 || len(h.routes.deleted) != 1 {
		t.Errorf("pins: %d added, %d deleted; want 2 and 1",
			len(h.routes.added), len(h.routes.deleted))
	}
}

func TestUninstallSweepsTheObfuscatedState(t *testing.T) {
	h := newAwgHarness(t)
	if _, err := h.m.Up(context.Background(), obfuscatedConfig, nil); err != nil {
		t.Fatalf("Up: %v", err)
	}
	if err := h.m.Uninstall(context.Background()); err != nil {
		t.Fatalf("Uninstall: %v", err)
	}
	// The pin record and the config go with it, so a later install cannot sweep routes
	// it has no memory of installing.
	if h.dev.closed != 1 {
		t.Errorf("device closed %d times, want 1", h.dev.closed)
	}
	if len(h.routes.deleted) != 1 {
		t.Errorf("underlay pins swept = %v, want the endpoint's", h.routes.deleted)
	}
	if _, statErr := os.Stat(h.m.configPath()); !os.IsNotExist(statErr) {
		t.Error("config file survives an uninstall")
	}
}

func TestTunnelRoutesFailClosedOnAnUnparseableAllowedIP(t *testing.T) {
	// Config validation should have caught this already. Reaching the installer with
	// one means the two disagree, and a tunnel quietly missing a prefix it was
	// configured to carry sends that traffic somewhere nobody asked for.
	if _, err := tunnelRoutes([]string{"0.0.0.0/0", "not-a-prefix"}); err == nil {
		t.Fatal("tunnelRoutes accepted an unparseable AllowedIP")
	}
	if _, err := tunnelRoutes(nil); err != nil {
		t.Errorf("tunnelRoutes(nil) = %v, want no error", err)
	}
}

func TestDnsServersDropsAnythingThatIsNotAnAddress(t *testing.T) {
	got := dnsServers("10.8.0.1, 10.8.0.2 fd00::1 nonsense")
	want := 3
	if len(got) != want {
		t.Errorf("dnsServers = %v, want %d addresses", got, want)
	}
	if !got[2].Equal(net.ParseIP("fd00::1")) {
		t.Errorf("dnsServers kept %v, want the IPv6 resolver", got[2])
	}
}

func TestAddressPrefixAcceptsABareAddress(t *testing.T) {
	ip, bits, err := addressPrefix("10.8.0.5")
	if err != nil {
		t.Fatalf("addressPrefix: %v", err)
	}
	if !ip.Equal(net.ParseIP("10.8.0.5")) || bits != 32 {
		t.Errorf("addressPrefix = %v/%d, want 10.8.0.5/32", ip, bits)
	}
	if _, bits, err = addressPrefix("fd00::1"); err != nil || bits != 128 {
		t.Errorf("addressPrefix(v6) bits = %d (%v), want 128", bits, err)
	}
	if _, _, err := addressPrefix("not-an-address"); err == nil {
		t.Error("addressPrefix accepted a non-address")
	}
}

// noLUIDTun is an adapter that does not report an interface identifier, which is what the
// type assertion in awgTunLUID has to cope with.
type noLUIDTun struct{}

func (noLUIDTun) File() *os.File                         { return nil }
func (noLUIDTun) Read([][]byte, []int, int) (int, error) { return 0, nil }
func (noLUIDTun) Write([][]byte, int) (int, error)       { return 0, nil }
func (noLUIDTun) MTU() (int, error)                      { return awgDefaultMTU, nil }
func (noLUIDTun) Name() (string, error)                  { return DefaultInterface, nil }
func (noLUIDTun) Events() <-chan awgtun.Event            { return nil }
func (noLUIDTun) BatchSize() int                         { return 1 }
func (noLUIDTun) Close() error                           { return nil }
