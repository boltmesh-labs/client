package stream

import (
	"encoding/hex"
	"testing"
	"time"
)

// Golden vectors pin the wire format byte-for-byte. The node side in the
// agent repo (internal/stream) carries the *same* table: if either half
// changes a byte, one of the two suites fails, which is how cross-repo
// conformance is proven without a live node. Never "fix" a vector to match
// new output — that is a protocol change and needs both repos at once.
//
// The session key below is not just whatever the code printed: it was
// cross-checked against an independent HKDF-SHA256 (RFC 5869) implementation,
// because the derivation is the one piece here that is not stdlib. The proof
// tag is plain AES-256-GCM from the standard library, which is deterministic
// and identical on both sides.

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("bad hex: %v", err)
	}
	return b
}

// Fixed inputs: a 32-byte PSK, a 16-byte client id, a fixed 12-byte nonce,
// and a fixed hello timestamp so the AEAD output is deterministic
// (production nonces and timestamps are generated per connection).
const (
	vectorPSK       = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
	vectorCID       = "202122232425262728292a2b2c2d2e2f"
	vectorNonce     = "303132333435363738393a3b"
	vectorTimestamp = int64(1_700_000_000)
	// version 1, type 0x0001, payload length 0x28 (16-byte client id, 8-byte
	// timestamp, 16-byte AEAD tag), the client id, the timestamp, then the tag:
	// AES-256-GCM(key = HKDF-SHA256(psk, salt = client id,
	// "boltmesh-stream/1/session"), nonce = timestamp || zero-pad,
	// empty plaintext, aad = client id || timestamp).
	vectorHello     = "01000100000034" + vectorCID + "000000006553f100" + vectorNonce + "39dce2dc585d01b9ced35d5225579b2a"
	vectorHelloAck  = "01000200000000"
	vectorHelloFail = "01000400000003" + "6e6f70"
)

func vectorSessionKey(t *testing.T) []byte {
	t.Helper()
	key, err := DeriveSessionKey(mustHex(t, vectorPSK), mustHex(t, vectorCID))
	if err != nil {
		t.Fatalf("DeriveSessionKey: %v", err)
	}
	return key
}

func TestDeriveSessionKeyIsDeterministic(t *testing.T) {
	// The session key is HKDF-SHA256 over the PSK; pinned so a change to the
	// derivation breaks every vector in both repos rather than silently
	// producing a stream both halves can no longer authenticate.
	if got := hex.EncodeToString(vectorSessionKey(t)); got != "f5753f917b5c1eca9b62a1057a51f595c665bad4f65c054df11468f817ee5979" {
		t.Fatalf("session key = %s, want the pinned value", got)
	}
}

func TestBuildHelloMatchesVector(t *testing.T) {
	got, err := BuildHelloAt(
		vectorSessionKey(t),
		mustHex(t, vectorCID),
		vectorTimestamp,
		mustHex(t, vectorNonce),
	)
	if err != nil {
		t.Fatalf("BuildHelloAt: %v", err)
	}
	if hex.EncodeToString(got) != vectorHello {
		t.Fatalf("hello frame = %x, want the pinned vector %s", got, vectorHello)
	}
}

func TestVerifyHelloAcceptsTheVector(t *testing.T) {
	// The node half: the pinned vector must verify, with the client id
	// recovered from the payload.
	_, payload, err := parseFrame(mustHex(t, vectorHello))
	if err != nil {
		t.Fatalf("parseFrame: %v", err)
	}
	now := time.Unix(vectorTimestamp, 0)
	clientID, err := VerifyHello(mustHex(t, vectorPSK), payload, now)
	if err != nil {
		t.Fatalf("VerifyHello(vector) = %v, want nil", err)
	}
	if hex.EncodeToString(clientID) != vectorCID {
		t.Errorf("VerifyHello client id = %x, want %s", clientID, vectorCID)
	}
}

func TestVerifyHelloRejectsStaleAndWrongCredentials(t *testing.T) {
	_, payload, err := parseFrame(mustHex(t, vectorHello))
	if err != nil {
		t.Fatalf("parseFrame: %v", err)
	}
	at := func(offset time.Duration) time.Time { return time.Unix(vectorTimestamp, 0).Add(offset) }
	otherPSK := mustHex(t, "0f0e0d0c0b0a09080706050403020100"+"1f1e1d1c1b1a19181716151413121110")
	// Both edges of the window still accept: the bound exists to stop replays,
	// not to be strict about ordinary clock drift.
	for _, offset := range []time.Duration{0, HelloReplayWindow - time.Second, -HelloReplayWindow + time.Second} {
		if _, err := VerifyHello(mustHex(t, vectorPSK), payload, at(offset)); err != nil {
			t.Errorf("VerifyHello(offset %s) = %v, want nil", offset, err)
		}
	}
	cases := []struct {
		name    string
		psk     []byte
		payload []byte
		now     time.Time
	}{
		// A captured hello is worthless once the window closes: that is what
		// stops a replay from authenticating as the device later.
		{"stale", mustHex(t, vectorPSK), payload, at(HelloReplayWindow + time.Second)},
		{"stale in the past", mustHex(t, vectorPSK), payload, at(-HelloReplayWindow - time.Second)},
		{"wrong key", otherPSK, payload, at(0)},
		{"truncated", mustHex(t, vectorPSK), payload[:len(payload)-1], at(0)},
		{"empty", mustHex(t, vectorPSK), nil, at(0)},
	}
	for _, tc := range cases {
		if _, err := VerifyHello(tc.psk, tc.payload, tc.now); err == nil {
			t.Errorf("VerifyHello(%s) = nil, want ErrAuth", tc.name)
		}
	}
}

func TestBuildHelloAckAndFailMatchVectors(t *testing.T) {
	if got := hex.EncodeToString(BuildHelloAck()); got != vectorHelloAck {
		t.Errorf("hello-ack = %s, want %s", got, vectorHelloAck)
	}
	if got := hex.EncodeToString(BuildHelloFail("nop")); got != vectorHelloFail {
		t.Errorf("hello-fail = %s, want %s", got, vectorHelloFail)
	}
}

func TestKeyProofRoundTrips(t *testing.T) {
	key := vectorSessionKey(t)
	nonce := mustHex(t, vectorNonce)
	// The additional data is the client id and the hello timestamp, exactly as
	// they appear on the wire.
	aad := mustHex(t, vectorCID+"000000006553f100")
	proof, err := NewKeyProof(key, aad, nonce)
	if err != nil {
		t.Fatalf("NewKeyProof: %v", err)
	}
	if err := VerifyKeyProof(key, aad, nonce, proof); err != nil {
		t.Fatalf("VerifyKeyProof(valid) = %v, want nil", err)
	}
	// A proof must not verify under a different key, a different device id
	// (replay across devices), or a different nonce.
	otherKey := make([]byte, len(key))
	copy(otherKey, key)
	otherKey[0] ^= 0xff
	otherAAD := make([]byte, len(aad))
	copy(otherAAD, aad)
	otherAAD[0] ^= 0xff
	otherNonce := make([]byte, NonceSize)
	copy(otherNonce, nonce)
	otherNonce[0] ^= 0xff
	for name, args := range map[string]struct {
		key, aad, nonce, proof []byte
	}{
		"wrong key":      {otherKey, aad, nonce, proof},
		"wrong device":   {key, otherAAD, nonce, proof},
		"wrong nonce":    {key, aad, otherNonce, proof},
		"empty proof":    {key, aad, nonce, nil},
		"short proof":    {key, aad, nonce, proof[:len(proof)-1]},
		"oversize proof": {key, aad, nonce, append(append([]byte{}, proof...), 0)},
		// A different timestamp in the additional data must not verify: the
		// freshness window is authenticated, not just checked.
		"shifted aad": {key, mustHex(t, vectorCID+"000000006553f101"), nonce, proof},
	} {
		if err := VerifyKeyProof(args.key, args.aad, args.nonce, args.proof); err == nil {
			t.Errorf("VerifyKeyProof(%s) = nil, want ErrAuth", name)
		}
	}
}

func TestParseHelloRejectsMalformed(t *testing.T) {
	valid := mustHex(t, vectorHello)
	cases := []struct {
		name string
		in   []byte
	}{
		{"empty", nil},
		{"short header", valid[:4]},
		{"wrong version", append([]byte{0x02}, valid[1:]...)},
		{"wrong type", append(append([]byte{}, valid[:1]...), append([]byte{0x00, 0x03}, valid[3:]...)...)},
		{"length disagrees", append(append([]byte{}, valid[:3]...), append([]byte{0x00, 0x00, 0x35}, valid[7:]...)...)},
		{"truncated payload", valid[:len(valid)-1]},
	}
	for _, tc := range cases {
		if _, _, _, _, err := ParseHello(tc.in); err == nil {
			t.Errorf("ParseHello(%s) = nil error, want ErrProtocol", tc.name)
		}
	}
}

func TestBuildDatagramAndParse(t *testing.T) {
	payload := []byte("wireguard-datagram-bytes")
	frameBytes, err := BuildDatagram(payload)
	if err != nil {
		t.Fatalf("BuildDatagram: %v", err)
	}
	got, err := ParseDatagram(frameBytes)
	if err != nil {
		t.Fatalf("ParseDatagram: %v", err)
	}
	if string(got) != string(payload) {
		t.Errorf("round trip = %q, want %q", got, payload)
	}
	// An oversize datagram is refused rather than framed.
	if _, err := BuildDatagram(make([]byte, MaxDatagramSize+1)); err == nil {
		t.Error("BuildDatagram(oversize) = nil, want error")
	}
	// And a datagram frame is not a hello.
	if _, _, _, _, err := ParseHello(frameBytes); err == nil {
		t.Error("ParseHello(datagram) = nil error, want ErrProtocol")
	}
}

func TestReadFrameSplitsAStream(t *testing.T) {
	// Two frames back to back, as the connection loop sees them.
	var stream []byte
	a, _ := BuildDatagram([]byte("first"))
	b, _ := BuildDatagram([]byte("second"))
	stream = append(stream, a...)
	stream = append(stream, b...)

	typ, payload, rest, err := ReadFrame(stream)
	if err != nil {
		t.Fatalf("ReadFrame: %v", err)
	}
	if typ != TypeDatagram || string(payload) != "first" {
		t.Errorf("first frame = type 0x%04x %q", typ, payload)
	}
	typ, payload, rest, err = ReadFrame(rest)
	if err != nil {
		t.Fatalf("ReadFrame(second): %v", err)
	}
	if typ != TypeDatagram || string(payload) != "second" {
		t.Errorf("second frame = type 0x%04x %q", typ, payload)
	}
	if len(rest) != 0 {
		t.Errorf("rest = %q, want empty", rest)
	}
	// A partial frame is reported as incomplete, not misparsed.
	if _, _, _, err := ReadFrame(stream[:3]); err == nil {
		t.Error("ReadFrame(partial) = nil, want ErrProtocol")
	}
}

func TestReadFrameRejectsAbsurdLength(t *testing.T) {
	// A length field far past the limit must not make the reader wait for
	// (or allocate) that much: the limit is checked before the payload is
	// awaited.
	bad := []byte{Version, 0x00, 0x03, 0xff, 0xff, 0xff, 0xff}
	if _, _, _, err := ReadFrame(bad); err == nil {
		t.Error("ReadFrame(oversize length) = nil, want ErrProtocol")
	}
}

func TestDeriveSessionKeyRejectsBadSizes(t *testing.T) {
	if _, err := DeriveSessionKey(make([]byte, 31), make([]byte, ClientIDSize)); err == nil {
		t.Error("DeriveSessionKey(short psk) = nil, want error")
	}
	if _, err := DeriveSessionKey(make([]byte, PSKSize), make([]byte, 15)); err == nil {
		t.Error("DeriveSessionKey(short client id) = nil, want error")
	}
}
