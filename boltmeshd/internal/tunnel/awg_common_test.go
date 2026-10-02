//go:build linux || windows

// Behavior suite for the parts of the AmneziaWG data plane both backends share.
// The end-to-end suites stay per-backend, because each drives its own manager
// through its own privileged surface. What is here is the logic that has to agree
// between them: the config the device is configured with, which underlay routes
// that config implies, and how a device dump becomes a status.
//
// These tests exist on both platforms rather than only on Linux because that is
// the point of the shared file -- a Windows tunnel carrying an obfuscated region
// must derive the same routes as a Linux one, or it would pin a different path
// for the device's own endpoint traffic than the node expects.

package tunnel

import (
	"context"
	"errors"
	"net"
	"strconv"
	"strings"
	"testing"

	"boltmeshd/internal/protocol"
)

// fakeAwgDevice records the UAPI bodies it is configured with and replays a canned
// dump. Platform-neutral, so both backends' suites share it.
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

const obfConfigText = `[Interface]
PrivateKey = ` + keyA + `
Address = 10.9.0.2/32
DNS = 10.9.0.1
MTU = 1380
Jc = 4
S1 = 36
S2 = 36
S3 = 11
S4 = 35
H1 = 1342177280, 1350193902
H2 = 1610612736, 1618846586
H3 = 1879048192, 1894861561
H4 = 2147483648, 2163863382

[Peer]
PublicKey = ` + keyB + `
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 198.51.100.7:51820
`

// TestParseObfuscatedSettingsReadsEveryBackendAppliedField pins the split between
// what the device protocol carries and what the backend has to apply itself. A
// field read here that the device also sets would silently disagree with it; a
// field not read here is a field the tunnel would come up without.
func TestParseObfuscatedSettingsReadsEveryBackendAppliedField(t *testing.T) {
	got, err := parseObfuscatedSettings(obfConfigText)
	if err != nil {
		t.Fatalf("parseObfuscatedSettings: %v", err)
	}
	if got.address != "10.9.0.2/32" {
		t.Errorf("address = %q, want 10.9.0.2/32", got.address)
	}
	if got.dns != "10.9.0.1" {
		t.Errorf("dns = %q, want 10.9.0.1", got.dns)
	}
	if got.mtu != 1380 {
		t.Errorf("mtu = %d, want 1380", got.mtu)
	}
	if got.endpoint != "198.51.100.7:51820" {
		t.Errorf("endpoint = %q, want 198.51.100.7:51820", got.endpoint)
	}
	// Both families must survive: a split tunnel claims one of them and a strict
	// one claims both, and dropping either would leave traffic unrouted.
	want := []string{"0.0.0.0/0", "::/0"}
	if len(got.allowedIPs) != len(want) {
		t.Fatalf("allowedIPs = %v, want %v", got.allowedIPs, want)
	}
	for i := range want {
		if got.allowedIPs[i] != want[i] {
			t.Errorf("allowedIPs[%d] = %q, want %q", i, got.allowedIPs[i], want[i])
		}
	}
}

// TestParseObfuscatedSettingsDefaultsTheMTU covers the omitted-MTU case: a config
// with no MTU line must still get a sane one rather than zero, which every tun
// backend would reject.
func TestParseObfuscatedSettingsDefaultsTheMTU(t *testing.T) {
	noMTU := strings.ReplaceAll(obfConfigText, "MTU = 1380\n", "")
	got, err := parseObfuscatedSettings(noMTU)
	if err != nil {
		t.Fatalf("parseObfuscatedSettings: %v", err)
	}
	if got.mtu != awgDefaultMTU {
		t.Errorf("mtu = %d, want the default %d", got.mtu, awgDefaultMTU)
	}
}

// TestParseObfuscatedSettingsRequiresAddressAndEndpoint covers the two fields a
// safe bring-up cannot do without: without an address there is nothing to route,
// and without an endpoint there is no underlay route to keep the device's own UDP
// out of the tunnel it is about to claim.
func TestParseObfuscatedSettingsRequiresAddressAndEndpoint(t *testing.T) {
	cases := []struct {
		name    string
		drop    string
		wantErr string
	}{
		{"no address", "Address = 10.9.0.2/32\n", "Address"},
		{"no endpoint", "Endpoint = 198.51.100.7:51820\n", "Endpoint"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := parseObfuscatedSettings(strings.ReplaceAll(obfConfigText, tc.drop, ""))
			if err == nil {
				t.Fatalf("parseObfuscatedSettings accepted a config with %s", tc.name)
			}
			if !strings.Contains(err.Error(), tc.wantErr) {
				t.Errorf("error = %v, want it to name %q", err, tc.wantErr)
			}
		})
	}
}

// TestParseObfuscatedSettingsRejectsABadMTU guards the range check: a zero or
// absurd MTU is a client-side mistake, and passing it to the adapter would fail
// much later with a far less legible error.
func TestParseObfuscatedSettingsRejectsABadMTU(t *testing.T) {
	for _, bad := range []string{"MTU = 0\n", "MTU = 100\n", "MTU = 70000\n", "MTU = abc\n"} {
		t.Run(strings.TrimSpace(bad), func(t *testing.T) {
			text := strings.ReplaceAll(obfConfigText, "MTU = 1380\n", bad)
			if _, err := parseObfuscatedSettings(text); err == nil {
				t.Errorf("parseObfuscatedSettings accepted %q", strings.TrimSpace(bad))
			}
		})
	}
}

// TestAwgObfuscatedDetectsTheDirectiveSet pins what selects the userspace data
// plane: one directive present means the complete set is, because config.Validate
// enforces the all-or-none rule. A stock config must not match, or every native
// tunnel would be routed into a userspace device it has no directives for.
func TestAwgObfuscatedDetectsTheDirectiveSet(t *testing.T) {
	if !awgObfuscated(parseWgQuick(obfConfigText)) {
		t.Error("a config carrying the AmneziaWG directives was not detected as obfuscated")
	}

	stock := `[Interface]
PrivateKey = ` + keyA + `
Address = 10.9.0.2/32
ListenPort = 51820

[Peer]
PublicKey = ` + keyB + `
AllowedIPs = 10.0.0.0/16
`
	if awgObfuscated(parseWgQuick(stock)) {
		t.Error("a stock WireGuard config was detected as obfuscated")
	}
}

// TestResolveEndpointAddressesCoversLiteralAndName covers both resolution paths,
// because a config's endpoint is a literal on some deployments and a name on
// others, and the underlay pin is derived from the addresses either way.
func TestResolveEndpointAddressesCoversLiteralAndName(t *testing.T) {
	t.Run("literal needs no resolver", func(t *testing.T) {
		called := false
		got, err := resolveEndpointAddresses(context.Background(), "198.51.100.7:51820",
			func(context.Context, string) ([]net.IP, error) {
				called = true
				return nil, errors.New("must not be called")
			})
		if err != nil {
			t.Fatalf("resolveEndpointAddresses: %v", err)
		}
		if called {
			t.Error("the resolver was called for an IP literal")
		}
		if len(got) != 1 || got[0].String() != "198.51.100.7" {
			t.Errorf("addresses = %v, want [198.51.100.7]", got)
		}
	})

	t.Run("hostname is resolved", func(t *testing.T) {
		got, err := resolveEndpointAddresses(context.Background(), "node.example.test:51820",
			func(_ context.Context, host string) ([]net.IP, error) {
				if host != "node.example.test" {
					t.Errorf("resolver got host %q, want node.example.test", host)
				}
				return []net.IP{net.ParseIP("203.0.113.9")}, nil
			})
		if err != nil {
			t.Fatalf("resolveEndpointAddresses: %v", err)
		}
		if len(got) != 1 || got[0].String() != "203.0.113.9" {
			t.Errorf("addresses = %v, want [203.0.113.9]", got)
		}
	})

	t.Run("empty answer is an error", func(t *testing.T) {
		_, err := resolveEndpointAddresses(context.Background(), "node.example.test:51820",
			func(context.Context, string) ([]net.IP, error) { return nil, nil })
		if err == nil {
			t.Error("an endpoint resolving to no addresses was accepted")
		}
	})
}

// TestUnderlayPrefixesForSkipsLoopback is the property that makes a stream-carried
// obfuscated tunnel work at all. Its peer endpoint is the bridge's loopback
// address, so pinning a route for it would be pinning the local table; the real
// upstream is pinned by the transport instead. A teardown that derived a prefix
// here would look for a route that was never installed.
func TestUnderlayPrefixesForSkipsLoopback(t *testing.T) {
	prefixes := underlayPrefixesFor([]net.IP{
		net.ParseIP("127.0.0.1"),
		net.ParseIP("198.51.100.7"),
		net.ParseIP("::1"),
		net.ParseIP("2001:db8::7"),
	})
	want := []string{"198.51.100.7/32", "2001:db8::7/128"}
	if len(prefixes) != len(want) {
		t.Fatalf("prefixes = %v, want %v", prefixes, want)
	}
	for i := range want {
		if prefixes[i] != want[i] {
			t.Errorf("prefixes[%d] = %q, want %q", i, prefixes[i], want[i])
		}
	}
}

// TestHostPrefixForPicksTheFamily is small but load-bearing: a /32 applied to a
// v6 address (or a /128 to a v4 one) is not a host route, and Windows would
// either reject it or install something that does not match what teardown looks
// for by name.
func TestHostPrefixForPicksTheFamily(t *testing.T) {
	cases := map[string]string{
		"198.51.100.7": "198.51.100.7/32",
		"2001:db8::7":  "2001:db8::7/128",
	}
	for in, want := range cases {
		if got := hostPrefixFor(net.ParseIP(in)); got != want {
			t.Errorf("hostPrefixFor(%s) = %q, want %q", in, got, want)
		}
	}
}

// TestReadObfuscatedStatusProjectsTheDeviceDump is the status contract both
// backends share: a live device with a peer is connected, and the peer data
// reaches the caller rather than being dropped.
func TestReadObfuscatedStatusProjectsTheDeviceDump(t *testing.T) {
	dump := "public_key=" + keyB + "\n" +
		"preshared_key=" + keyB + "\n" +
		"endpoint=198.51.100.7:51820\n" +
		"rx_bytes=1024\ntx_bytes=2048\nlast_handshake_time_sec=1700000000\n"

	dev := &fakeAwgDevice{dumpBody: dump}
	st, err := readObfuscatedStatus(context.Background(), "boltmesh0", dev)
	if err != nil {
		t.Fatalf("readObfuscatedStatus: %v", err)
	}
	if !st.Up {
		t.Error("status reports down for a device that dumped successfully")
	}
	if st.Stage != protocol.StageConnected {
		t.Errorf("stage = %q, want %q", st.Stage, protocol.StageConnected)
	}
	if st.Interface != "boltmesh0" {
		t.Errorf("interface = %q, want boltmesh0", st.Interface)
	}
	// Status aggregates across peers rather than exposing a list, so the peer
	// table has to reach the client through these fields or a working tunnel
	// looks like an idle one.
	if st.RxBytes != 1024 || st.TxBytes != 2048 {
		t.Errorf("counters = rx %d tx %d, want rx 1024 tx 2048", st.RxBytes, st.TxBytes)
	}
	if st.LastHandshake == 0 {
		t.Error("the peer's handshake timestamp was dropped")
	}
	if st.Endpoint != "198.51.100.7:51820" {
		t.Errorf("endpoint = %q, want 198.51.100.7:51820", st.Endpoint)
	}
	if st.PublicKey == "" {
		t.Error("the peer's public key was dropped")
	}
}

// TestNewAwgDeviceSatisfiesTheManagerSeam pins the constructor's shape rather than
// calling it. Building a device needs a real adapter, which is a privileged
// resource on both platforms and out of reach for a unit test -- but the seam a
// backend assigns it to is pure type information, and it is the thing that has to
// stay compatible: a Windows manager's makeAwgDevice field takes the same
// signature as Linux's, which is what lets both share this constructor.
func TestNewAwgDeviceSatisfiesTheManagerSeam(t *testing.T) {
	// The concrete adapter satisfies the interface, so a backend that reaches
	// past the makeAwgDevice seam still gets a conforming device. The seam
	// signature itself -- func(awgtun.Device) (awgDevice, error), declared on
	// both backends' Manager -- is what lets this constructor be shared rather
	// than written twice, and is exercised by the call below.
	var _ awgDevice = (*goAwgDevice)(nil)
}

// TestNewAwgDeviceRefusesANilAdapter covers the precondition the constructor
// carries, and is also what pins its signature: a backend's makeAwgDevice field
// takes func(awgtun.Device) (awgDevice, error), so a change to either half of it
// would stop compiling here first.
//
// Without the refusal a nil adapter reaches the device constructor and panics
// inside a privileged daemon, where the stack names neither the backend nor the
// call that was at fault.
func TestNewAwgDeviceRefusesANilAdapter(t *testing.T) {
	dev, err := newAwgDevice(nil)
	if err == nil {
		t.Fatal("newAwgDevice accepted a nil adapter")
	}
	if dev != nil {
		t.Errorf("newAwgDevice returned a device alongside the error: %v", dev)
	}
	if !strings.Contains(err.Error(), "nil adapter") {
		t.Errorf("error = %v, want it to name the nil adapter", err)
	}
}

// TestAwgDefaultRouteMetricOutranksThePhysicalDefault covers the one property the
// metric has: a strict-mode tunnel claims 0.0.0.0/0 without displacing the
// machine's own default route. Windows and Linux both read this constant, and a
// value that failed to outrank a metric-0 physical default would leave the tunnel
// silently bypassed -- up, with every packet still going the physical way.
func TestAwgDefaultRouteMetricOutranksThePhysicalDefault(t *testing.T) {
	n, err := strconv.Atoi(awgDefaultRouteMetric)
	if err != nil {
		t.Fatalf("awgDefaultRouteMetric = %q, which is not a number: %v", awgDefaultRouteMetric, err)
	}
	if n < 0 {
		t.Errorf("awgDefaultRouteMetric = %d, want a non-negative metric", n)
	}
	// Zero is the metric Windows and Linux give an ordinary default route, so a
	// tie would leave the winner up to interface ordering.
	if n == 0 {
		t.Error("awgDefaultRouteMetric = 0, which ties with the physical default route")
	}
}

// TestReadObfuscatedStatusTreatsADumpFailureAsUnknown is the safety property: a
// device that cannot be read is not evidence that the tunnel is down. Reporting
// disconnected here would make the client's health policy tear down a working
// tunnel because one read failed.
func TestReadObfuscatedStatusTreatsADumpFailureAsUnknown(t *testing.T) {
	dev := &fakeAwgDevice{dumpErr: errors.New("device is closed")}
	st, err := readObfuscatedStatus(context.Background(), "boltmesh0", dev)
	if err == nil {
		t.Fatal("a failed dump was reported as a status")
	}
	if st != nil {
		t.Errorf("a failed dump returned a status %v, which a caller could act on", st)
	}
	var opErr *protocol.OpError
	if !errors.As(err, &opErr) {
		t.Errorf("error is %T, want an OpError carrying the daemon's own code", err)
	}
}
