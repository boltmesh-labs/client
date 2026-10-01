package protocol

import (
	"encoding/base64"
	"runtime"
	"slices"
	"strings"
	"testing"
)

// A valid spec is the node credential set the control plane hands the client:
// a pinned certificate, a device PSK, and a device id.
func validTransport() *TransportSpec {
	return &TransportSpec{
		Mode:       TransportModeStream,
		Listen:     "127.0.0.1:51821",
		Deliver:    "127.0.0.1:51820",
		Server:     "vpn.example.net:443",
		ServerName: "vpn.example.net",
		SPKIPins:   []string{base64.StdEncoding.EncodeToString(make([]byte, 32))},
		PSK:        base64.StdEncoding.EncodeToString(make([]byte, 32)),
		ClientID:   base64.StdEncoding.EncodeToString(make([]byte, 16)),
	}
}

func TestTransportSpecValidateAcceptsStream(t *testing.T) {
	if err := validTransport().Validate(); err != nil {
		t.Fatalf("Validate(valid) = %v, want nil", err)
	}
}

func TestTransportSpecRejectsMalformed(t *testing.T) {
	shortPSK := base64.StdEncoding.EncodeToString(make([]byte, 16))
	longPSK := base64.StdEncoding.EncodeToString(make([]byte, 64))
	shortPin := base64.StdEncoding.EncodeToString(make([]byte, 20))
	notBase64 := "not base64 at all!!"
	cases := []struct {
		name string
		mut  func(*TransportSpec)
	}{
		{"unknown mode", func(s *TransportSpec) { s.Mode = "shadowsocks" }},
		{"empty mode", func(s *TransportSpec) { s.Mode = "" }},
		{"listen without port", func(s *TransportSpec) { s.Listen = "127.0.0.1" }},
		{"listen port zero", func(s *TransportSpec) { s.Listen = "127.0.0.1:0" }},
		{"listen port not a number", func(s *TransportSpec) { s.Listen = "127.0.0.1:https" }},
		// A non-loopback listen would point a root-owned daemon's tunnel at
		// a peer it should be routing around.
		{"listen not loopback", func(s *TransportSpec) { s.Listen = "10.0.0.1:51821" }},
		{"listen is a hostname", func(s *TransportSpec) { s.Listen = "localhost:51821" }},
		{"deliver without port", func(s *TransportSpec) { s.Deliver = "127.0.0.1" }},
		{"deliver port zero", func(s *TransportSpec) { s.Deliver = "127.0.0.1:0" }},
		// The reverse path must land on a local interface too, or the daemon
		// would inject the node's datagrams into the network.
		{"deliver not loopback", func(s *TransportSpec) { s.Deliver = "0.0.0.0:51820" }},
		{"deliver is a hostname", func(s *TransportSpec) { s.Deliver = "localhost:51820" }},
		{"server empty", func(s *TransportSpec) { s.Server = "" }},
		{"server with a control character", func(s *TransportSpec) { s.Server = "a\nb:443" }},
		{"server port zero", func(s *TransportSpec) { s.Server = "vpn.example.net:0" }},
		{"server name empty", func(s *TransportSpec) { s.ServerName = "" }},
		{"server name with a slash", func(s *TransportSpec) { s.ServerName = "a/b" }},
		{"server name too long", func(s *TransportSpec) { s.ServerName = strings.Repeat("a", MaxTransportServerName+1) }},
		// No pin would be a stream to whoever answers the port.
		{"no pins", func(s *TransportSpec) { s.SPKIPins = nil }},
		{"pin is not base64", func(s *TransportSpec) { s.SPKIPins = []string{notBase64} }},
		{"pin is not a sha-256 digest", func(s *TransportSpec) { s.SPKIPins = []string{shortPin} }},
		// Several pins are how a node rotates its key, but the list is not
		// an open one.
		{"too many pins", func(s *TransportSpec) { s.SPKIPins = make([]string, MaxTransportSPKIPins+1) }},
		{"psk empty", func(s *TransportSpec) { s.PSK = "" }},
		{"psk too short", func(s *TransportSpec) { s.PSK = shortPSK }},
		{"psk too long", func(s *TransportSpec) { s.PSK = longPSK }},
		{"psk not base64", func(s *TransportSpec) { s.PSK = notBase64 }},
		{"client id empty", func(s *TransportSpec) { s.ClientID = "" }},
		{"client id wrong size", func(s *TransportSpec) { s.ClientID = longPSK }},
		{"client id not base64", func(s *TransportSpec) { s.ClientID = notBase64 }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			spec := validTransport()
			tc.mut(spec)
			if err := spec.Validate(); err == nil {
				t.Fatalf("Validate(%s) = nil, want error", tc.name)
			}
		})
	}
}

func TestTransportSpecErrorsNeverEchoThePSK(t *testing.T) {
	// The PSK is a secret, and a rejected spec must not put it in an error
	// message that a caller might log.
	psk := base64.StdEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef"))
	for _, tc := range []struct {
		name string
		mut  func(*TransportSpec)
	}{
		{"wrong psk size", func(s *TransportSpec) { s.PSK = base64.StdEncoding.EncodeToString([]byte("short")) }},
		{"not base64", func(s *TransportSpec) { s.PSK = "not base64 at all!!" }},
		{"truncated", func(s *TransportSpec) { s.PSK = psk[:10] }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			spec := validTransport()
			spec.PSK = psk
			tc.mut(spec)
			err := spec.Validate()
			if err == nil {
				t.Fatal("Validate = nil, want error")
			}
			if strings.Contains(err.Error(), psk) || strings.Contains(err.Error(), "0123456789abcdef") {
				t.Fatalf("error leaked the PSK: %v", err)
			}
		})
	}
}

func TestTransportSpecDecodersReturnTheEncodedBytes(t *testing.T) {
	spec := validTransport()
	wantPSK := make([]byte, 32)
	wantPSK[0] = 0xaa
	wantID := make([]byte, 16)
	wantID[15] = 0xbb
	wantPin := make([]byte, 32)
	wantPin[31] = 0xcc
	spec.PSK = base64.StdEncoding.EncodeToString(wantPSK)
	spec.ClientID = base64.StdEncoding.EncodeToString(wantID)
	spec.SPKIPins = []string{base64.StdEncoding.EncodeToString(wantPin)}

	psk, err := spec.StreamPSK()
	if err != nil {
		t.Fatalf("StreamPSK: %v", err)
	}
	if string(psk) != string(wantPSK) {
		t.Errorf("StreamPSK = %x, want %x", psk, wantPSK)
	}
	id, err := spec.StreamClientID()
	if err != nil {
		t.Fatalf("StreamClientID: %v", err)
	}
	if string(id) != string(wantID) {
		t.Errorf("StreamClientID = %x, want %x", id, wantID)
	}
	pins, err := spec.StreamSPKIPins()
	if err != nil {
		t.Fatalf("StreamSPKIPins: %v", err)
	}
	if len(pins) != 1 || string(pins[0]) != string(wantPin) {
		t.Errorf("StreamSPKIPins = %x, want [%x]", pins, wantPin)
	}
}

func TestTransportSpecAcceptsBareServerHost(t *testing.T) {
	// A bare host is legal: stream transports all dial TLS, so 443 is the
	// implied port.
	spec := validTransport()
	spec.Server = "vpn.example.net"
	if err := spec.Validate(); err != nil {
		t.Fatalf("Validate(bare server) = %v, want nil", err)
	}
}

func TestTransportSpecAcceptsLoopbackNames(t *testing.T) {
	for _, listen := range []string{"127.0.0.1:51821", "127.0.0.53:1", "[::1]:51821"} {
		spec := validTransport()
		spec.Listen = listen
		if err := spec.Validate(); err != nil {
			t.Errorf("Validate(listen=%s) = %v, want nil", listen, err)
		}
	}
}

func TestRequestTransportOnlyAllowedForUp(t *testing.T) {
	transport := validTransport()
	for _, op := range []string{OpPing, OpStatus, OpDown} {
		req := Request{V: Version, ID: "r1", Op: op, Transport: transport}
		if err := req.Validate(); err == nil {
			t.Errorf("Validate(%s with transport) = nil, want error", op)
		}
	}
	req := Request{
		V:         Version,
		ID:        "r1",
		Op:        OpUp,
		Config:    strPtr("[Interface]\n"),
		Transport: transport,
	}
	if err := req.Validate(); err != nil {
		t.Errorf("Validate(up with transport) = %v, want nil", err)
	}
}

func TestRequestTransportInheritsEnvelopeValidation(t *testing.T) {
	req := Request{
		V:         Version,
		ID:        "r1",
		Op:        OpUp,
		Config:    strPtr("[Interface]\n"),
		Transport: validTransport(),
	}
	req.Transport.Mode = "wireguard-plus"
	if err := req.Validate(); err == nil {
		t.Fatal("a malformed transport must be rejected with the envelope")
	}
}

func TestSupportedCapabilitiesMatchThePlatformsTransport(t *testing.T) {
	// The client selects the stream rung only when it sees this token. So the
	// token must be present exactly where `up` can honour the spec, and absent
	// everywhere else: advertising it on Windows or macOS would let the client
	// pick a rung whose only possible outcome is a rejected spec.
	caps := SupportedCapabilities()
	advertised := slices.Contains(caps, CapStreamTransport)
	want := runtime.GOOS == "linux"
	if advertised != want {
		t.Fatalf("SupportedCapabilities() = %v, stream-transport advertised = %v, want %v (GOOS %s)",
			caps, advertised, want, runtime.GOOS)
	}
	// The always-on tokens are unconditional: a client relies on them to decide
	// whether it can talk to this daemon at all.
	for _, always := range []string{CapStrictValidation, CapCapabilities} {
		if !slices.Contains(caps, always) {
			t.Errorf("SupportedCapabilities() = %v, missing %q", caps, always)
		}
	}
	// And no duplicate tokens: a client intersects two lists, and a repeat
	// would make the intersection look larger than it is.
	seen := map[string]bool{}
	for _, c := range caps {
		if seen[c] {
			t.Errorf("SupportedCapabilities() = %v, duplicate token %q", caps, c)
		}
		seen[c] = true
	}
}

func strPtr(s string) *string { return &s }
