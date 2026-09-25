package tunnel

import (
	"encoding/base64"
	"encoding/hex"
	"strings"
	"testing"
	"time"
)

// Valid WireGuard key material. These are the RFC 7748 test vectors' shape
// (any 32 bytes decode); the translator only checks length/encoding, never key
// agreement. keyA/keyB and validConfig come from testconfig_test.go.
const (
	testPrivateKeyB64 = keyA
	testServerKeyB64  = keyB
	testPresharedB64  = "FpCyhws9cxwWoV4xELtfJvjJN+zQVRPISllRWgeopVE="
)

func mustHex(t *testing.T, b64 string) string {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		t.Fatalf("decode key: %v", err)
	}
	return hex.EncodeToString(raw)
}

// validConfig plus the directives a full client config carries, so the
// Linux-only filtering has something to strip.
const uapiConfig = `[Interface]
PrivateKey = ` + testPrivateKeyB64 + `
Address = 10.8.0.5/32
DNS = 10.8.0.1
MTU = 1420
ListenPort = 0

[Peer]
PublicKey = ` + testServerKeyB64 + `
PresharedKey = ` + testPresharedB64 + `
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 203.0.113.10:51820
PersistentKeepalive = 25
`

func TestConfigToUAPI(t *testing.T) {
	got, err := ConfigToUAPI(uapiConfig)
	if err != nil {
		t.Fatalf("ConfigToUAPI: %v", err)
	}
	body := string(got)

	for _, want := range []string{
		"private_key=" + mustHex(t, testPrivateKeyB64),
		"public_key=" + mustHex(t, testServerKeyB64),
		"preshared_key=" + mustHex(t, testPresharedB64),
		"endpoint=203.0.113.10:51820",
		"persistent_keepalive_interval=25",
		"allowed_ip=0.0.0.0/0",
		"allowed_ip=::/0",
	} {
		if !strings.Contains(body, want+"\n") {
			t.Errorf("missing %q in:\n%s", want, body)
		}
	}
	if !strings.HasSuffix(body, "\n") {
		t.Error("UAPI body must end with a newline for the device to accept it")
	}
}

// The device rejects unknown keys, so the Linux-only directives must be
// dropped rather than forwarded. Forwarding them would make every macOS
// connect fail with a config error the client cannot fix.
func TestConfigToUAPIDropsLinuxOnlyDirectives(t *testing.T) {
	body, err := ConfigToUAPI(uapiConfig)
	if err != nil {
		t.Fatalf("ConfigToUAPI: %v", err)
	}
	for _, banned := range []string{"address=", "dns=", "mtu=", "fwmark=", "table="} {
		if strings.Contains(string(body), banned) {
			t.Errorf("Linux-only directive %q leaked into the UAPI body:\n%s", banned, body)
		}
	}
}

// The UAPI protocol is order-sensitive: a peer's public_key opens its block
// and the following lines belong to it.
func TestConfigToUAPIOrdersPeerBlock(t *testing.T) {
	body, err := ConfigToUAPI(uapiConfig)
	if err != nil {
		t.Fatalf("ConfigToUAPI: %v", err)
	}
	lines := strings.Split(strings.TrimSuffix(string(body), "\n"), "\n")
	pubAt, endpointAt := -1, -1
	for i, line := range lines {
		switch {
		case strings.HasPrefix(line, "public_key="):
			pubAt = i
		case strings.HasPrefix(line, "endpoint=") && endpointAt < 0:
			endpointAt = i
		}
	}
	if pubAt < 0 || endpointAt < 0 {
		t.Fatalf("expected public_key and endpoint in:\n%s", body)
	}
	if pubAt > endpointAt {
		t.Errorf("public_key must precede the peer fields it owns:\n%s", body)
	}
	if lines[0] != "private_key="+mustHex(t, testPrivateKeyB64) {
		t.Errorf("private_key must be set before peers, got %q", lines[0])
	}
}

func TestConfigToUAPIMultiplePeers(t *testing.T) {
	second := "[Peer]\n" +
		"PublicKey = " + testPresharedB64 + "\n" +
		"AllowedIPs = 10.8.0.0/24\n" +
		"Endpoint = [2001:db8::1]:51820\n"
	body, err := ConfigToUAPI(uapiConfig + second)
	if err != nil {
		t.Fatalf("ConfigToUAPI: %v", err)
	}
	if got := strings.Count(string(body), "public_key="); got != 2 {
		t.Errorf("want 2 peer blocks, got %d:\n%s", got, body)
	}
	// IPv6 endpoints keep their brackets so SplitHostPort can read them back.
	if !strings.Contains(string(body), "endpoint=[2001:db8::1]:51820") {
		t.Errorf("IPv6 endpoint lost its brackets:\n%s", body)
	}
}

func TestConfigToUAPIRejectsIncomplete(t *testing.T) {
	tests := map[string]string{
		"no private key": "[Interface]\nListenPort = 0\n\n[Peer]\nPublicKey = " + testServerKeyB64 + "\n",
		"no peer":        "[Interface]\nPrivateKey = " + testPrivateKeyB64 + "\n",
		"no peer key":    "[Interface]\nPrivateKey = " + testPrivateKeyB64 + "\n\n[Peer]\nAllowedIPs = 0.0.0.0/0\n",
		"bad endpoint": "[Interface]\nPrivateKey = " + testPrivateKeyB64 +
			"\n\n[Peer]\nPublicKey = " + testServerKeyB64 + "\nEndpoint = nocolon\n",
		"bad cidr": "[Interface]\nPrivateKey = " + testPrivateKeyB64 +
			"\n\n[Peer]\nPublicKey = " + testServerKeyB64 + "\nAllowedIPs = not-a-cidr\n",
		"bad keepalive": "[Interface]\nPrivateKey = " + testPrivateKeyB64 +
			"\n\n[Peer]\nPublicKey = " + testServerKeyB64 + "\nPersistentKeepalive = soon\n",
	}
	for name, cfg := range tests {
		t.Run(name, func(t *testing.T) {
			if _, err := ConfigToUAPI(cfg); err == nil {
				t.Error("expected an error")
			}
		})
	}
}

// A zero handshake is "unknown", never a fabricated epoch: the client treats
// a fabricated time as evidence the peer is alive.
func TestParseUAPIPeersZeroHandshakeStaysUnknown(t *testing.T) {
	dump := []byte(`{"listen_port":51820,"peers":[{
		"public_key":"` + mustHex(t, testServerKeyB64) + `",
		"endpoint":{"v4":"203.0.113.10:51820"},
		"last_handshake_time_sec":0,"last_handshake_time_nsec":0,
		"rx_bytes":10,"tx_bytes":20}]}`)

	peers, err := ParseUAPIPeers(dump)
	if err != nil {
		t.Fatalf("ParseUAPIPeers: %v", err)
	}
	if len(peers) != 1 {
		t.Fatalf("want 1 peer, got %d", len(peers))
	}
	if !peers[0].lastHandshake.IsZero() {
		t.Errorf("zero handshake must stay the zero time, got %v", peers[0].lastHandshake)
	}
	if peers[0].rxBytes != 10 || peers[0].txBytes != 20 {
		t.Errorf("counters not decoded: %+v", peers[0])
	}
	if peers[0].endpoint != "203.0.113.10:51820" {
		t.Errorf("endpoint not decoded: %q", peers[0].endpoint)
	}
}

func TestParseUAPIPeersReadsHandshake(t *testing.T) {
	when := time.Unix(1_700_000_000, 500).UTC()
	dump := FormatPeersAsUAPI(51820, []peer{{
		publicKey:     mustHex(t, testServerKeyB64),
		endpoint:      "203.0.113.10:51820",
		lastHandshake: when,
		rxBytes:       1,
		txBytes:       2,
	}})

	peers, err := ParseUAPIPeers(dump)
	if err != nil {
		t.Fatalf("ParseUAPIPeers: %v", err)
	}
	if len(peers) != 1 {
		t.Fatalf("want 1 peer, got %d", len(peers))
	}
	if !peers[0].lastHandshake.Equal(when) {
		t.Errorf("handshake round-trip: want %v, got %v", when, peers[0].lastHandshake)
	}
}

func TestParseUAPIPeersIPv6Endpoint(t *testing.T) {
	dump := FormatPeersAsUAPI(51820, []peer{{
		publicKey: mustHex(t, testServerKeyB64),
		endpoint:  "[2001:db8::1]:51820",
	}})
	peers, err := ParseUAPIPeers(dump)
	if err != nil {
		t.Fatalf("ParseUAPIPeers: %v", err)
	}
	if peers[0].endpoint != "[2001:db8::1]:51820" {
		t.Errorf("IPv6 endpoint round-trip: %q", peers[0].endpoint)
	}
}

// A peer with an unparseable key is skipped, not fatal: failing the whole
// status read would report an unknown tunnel for one odd entry.
func TestParseUAPIPeersSkipsUnparseableKey(t *testing.T) {
	dump := []byte(`{"peers":[
		{"public_key":"zzzz"},
		{"public_key":"` + mustHex(t, testServerKeyB64) + `","rx_bytes":5}]}`)

	peers, err := ParseUAPIPeers(dump)
	if err != nil {
		t.Fatalf("ParseUAPIPeers: %v", err)
	}
	if len(peers) != 1 || peers[0].rxBytes != 5 {
		t.Fatalf("want the one valid peer, got %+v", peers)
	}
}

func TestParseUAPIPeersRejectsGarbage(t *testing.T) {
	if _, err := ParseUAPIPeers([]byte("not json")); err == nil {
		t.Error("expected an error for a non-JSON dump")
	}
}

func TestParseUAPIPeersStableOrder(t *testing.T) {
	peers := []peer{
		{publicKey: "ff" + strings.Repeat("0", 62), rxBytes: 2},
		{publicKey: "00" + strings.Repeat("0", 62), rxBytes: 1},
	}
	dump := FormatPeersAsUAPI(51820, peers)
	first, err := ParseUAPIPeers(dump)
	if err != nil {
		t.Fatalf("ParseUAPIPeers: %v", err)
	}
	second, _ := ParseUAPIPeers(dump)
	for i := range first {
		if first[i].publicKey != second[i].publicKey {
			t.Fatal("peer order is not stable across reads")
		}
	}
	if first[0].publicKey >= first[1].publicKey {
		t.Errorf("peers should be sorted by key: %q then %q", first[0].publicKey, first[1].publicKey)
	}
}

func TestHexKeyAcceptsBothEncodings(t *testing.T) {
	want := mustHex(t, testServerKeyB64)
	for name, in := range map[string]string{
		"base64":      testServerKeyB64,
		"base64 trim": "  " + testServerKeyB64 + "  ",
		"hex":         want,
		"hex upper":   strings.ToUpper(want),
		"base64 raw":  strings.TrimRight(testServerKeyB64, "="),
	} {
		t.Run(name, func(t *testing.T) {
			got, err := hexKey(in)
			if err != nil {
				t.Fatalf("hexKey: %v", err)
			}
			if got != want {
				t.Errorf("want %q, got %q", want, got)
			}
		})
	}
	if _, err := hexKey(""); err == nil {
		t.Error("an empty key must be rejected")
	}
}

// A short base64 string decodes fine but is not a WireGuard key. Accepting it
// would push the failure to the device, which rejects the whole request
// rather than the one bad peer.
func TestHexKeyRejectsWrongLength(t *testing.T) {
	for name, in := range map[string]string{
		"3 bytes":   "zzzz",
		"16 bytes":  base64.StdEncoding.EncodeToString(make([]byte, 16)),
		"33 bytes":  base64.StdEncoding.EncodeToString(make([]byte, 33)),
		"hex short": strings.Repeat("ab", 31),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := hexKey(in); err == nil {
				t.Errorf("a %s key must be rejected", name)
			}
		})
	}
}
