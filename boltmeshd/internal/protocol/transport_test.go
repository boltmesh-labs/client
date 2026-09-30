package protocol

import (
	"strings"
	"testing"
)

func validTransport() *TransportSpec {
	return &TransportSpec{
		Mode:     TransportModeStream,
		Listen:   "127.0.0.1:51821",
		Upstream: "vpn.example.net:443",
		Config:   `{"inbounds":[]}`,
		Binary:   "boltmesh-forwarder",
	}
}

func TestTransportSpecValidateAcceptsStream(t *testing.T) {
	if err := validTransport().Validate(); err != nil {
		t.Fatalf("Validate(valid) = %v, want nil", err)
	}
}

func TestTransportSpecRejectsMalformed(t *testing.T) {
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
		{"upstream empty", func(s *TransportSpec) { s.Upstream = "" }},
		{"upstream with a control character", func(s *TransportSpec) { s.Upstream = "a\nb:443" }},
		{"empty binary", func(s *TransportSpec) { s.Binary = "" }},
		// A path would let the client choose the file the daemon runs as root.
		{"binary with a path", func(s *TransportSpec) { s.Binary = "../../usr/bin/evil" }},
		{"binary absolute", func(s *TransportSpec) { s.Binary = "/usr/bin/evil" }},
		{"empty config", func(s *TransportSpec) { s.Config = "" }},
		{"oversize config", func(s *TransportSpec) { s.Config = strings.Repeat("x", MaxForwarderConfigSize+1) }},
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

func TestTransportSpecAcceptsBareUpstreamHost(t *testing.T) {
	// A bare host is legal: stream transports all dial TLS, so 443 is the
	// implied port.
	spec := validTransport()
	spec.Upstream = "vpn.example.net"
	if err := spec.Validate(); err != nil {
		t.Fatalf("Validate(bare upstream) = %v, want nil", err)
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

func TestSupportedCapabilitiesAdvertisesStreamTransport(t *testing.T) {
	// The client only selects the stream rung when it sees this token;
	// without it the forwarder would never start and the tunnel would sit on
	// a dead loopback endpoint.
	for _, cap := range SupportedCapabilities() {
		if cap == CapStreamTransport {
			return
		}
	}
	t.Fatalf("SupportedCapabilities() = %v, missing %q", SupportedCapabilities(), CapStreamTransport)
}

func strPtr(s string) *string { return &s }
