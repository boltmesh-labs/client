// Package stream carries a WireGuard tunnel's UDP datagrams inside a TLS
// session, so a network that blocks or fingerprints WireGuard's own UDP
// sees one ordinary TLS connection to the node instead.
//
// This file is the wire format, and it is deliberately the whole protocol
// surface: a length-prefixed frame stream inside TLS, with a per-connection
// proof of a per-device pre-shared key. Everything else (framing, AEAD
// choices, the golden vectors in format_test.go) is pinned here so the node
// side in the agent repo can be proven byte-compatible by sharing those
// vectors rather than by a live node.
//
// Threat model: the TLS session and its certificate pin stop a middlebox from
// reading or impersonating the stream. The pre-shared key stops anyone who
// can reach the node's port from using it as an open relay — without it a
// captured endpoint would accept arbitrary datagrams. It is *not* an
// anti-probing construction: the node presents its own certificate, so an
// active prober sees a real TLS server that does not complete the handshake
// without the key. See the design note in README.md for what that does and
// does not buy.
package stream

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"time"
)

// Version is the frame-stream version. A peer that receives anything else
// closes the session: the framing is a closed protocol between two halves we
// own, so an unknown version is a mismatch, not a feature to negotiate.
const Version = 1

// Frame types. Data flows after the handshake; the handshake itself is
// client-initiated and the server answers with exactly one acknowledgement.
const (
	TypeHello     uint16 = 0x0001
	TypeHelloAck  uint16 = 0x0002
	TypeDatagram  uint16 = 0x0003
	TypeHelloFail uint16 = 0x0004
)

// Frame header: version, type, payload length.
const (
	headerSize     = 7
	MaxPayloadSize = 65535
	// MaxDatagramSize is the largest datagram payload the format carries.
	// It matches a WireGuard tunnel's MTU with room for the framing, so no
	// fragmentation logic is needed: the TLS/TCP layer segments below it.
	MaxDatagramSize = 1500
)

// PSK and identity sizes.
const (
	// PSKSize is the pre-shared key length (AES-256).
	PSKSize = 32
	// ClientIDSize identifies a device to the node's key lookup. It is a
	// random per-device id, not the device UUID, so the node's lookup table
	// can be keyed without publishing stable identifiers on the wire.
	ClientIDSize = 16
	// NonceSize / TagSize are the AEAD parameters for the key proof.
	NonceSize = 12
	TagSize   = 16
	// AuthInfoLen bounds a server's failure frame, which carries only a
	// short reason code.
	MaxAuthInfoLen = 64
)

// ErrProtocol reports a malformed or unexpected frame — never a transport
// error, so a caller can tell "the other end is not ours" from "the socket
// broke" and treat the first as a key/credential problem.
var ErrProtocol = errors.New("stream: protocol error")

// ErrAuth reports a rejected key proof. Both halves return it for a bad or
// unknown client, and neither distinguishes the two to the peer: a prober
// learns only that the session ended.
var ErrAuth = errors.New("stream: authentication failed")

// DeriveSessionKey derives the AES-256 session key from a device PSK with
// HKDF-SHA256, bound to the client id so a proof captured for one device
// cannot be replayed as another's. The info string is fixed forever: changing
// it changes the protocol.
func DeriveSessionKey(psk []byte, clientID []byte) ([]byte, error) {
	if len(psk) != PSKSize {
		return nil, fmt.Errorf("stream: psk must be %d bytes, got %d", PSKSize, len(psk))
	}
	if len(clientID) != ClientIDSize {
		return nil, fmt.Errorf("stream: client id must be %d bytes, got %d", ClientIDSize, len(clientID))
	}
	return hkdf(psk, clientID, []byte("boltmesh-stream/1/session"), 32)
}

// hkdf is HKDF-SHA256 (RFC 5869) over the PSK, with the client id as salt and
// a fixed info label.
func hkdf(ikm, salt, info []byte, length int) ([]byte, error) {
	extract := hmacSum(salt, ikm)
	// Single expand step: length is 32 bytes, one HMAC block.
	var out []byte
	var prev []byte
	for counter := byte(1); len(out) < length; counter++ {
		h := hmac.New(sha256.New, extract)
		h.Write(prev)
		h.Write(info)
		h.Write([]byte{counter})
		prev = h.Sum(nil)
		out = append(out, prev...)
	}
	return out[:length], nil
}

func hmacSum(key, data []byte) []byte {
	h := hmac.New(sha256.New, key)
	h.Write(data)
	return h.Sum(nil)
}

// NewKeyProof seals a key proof for [aad] under the session key. The nonce is
// read from crypto/rand, never derived, and the sealed plaintext is empty:
// the proof's value is the AEAD tag under a key only the two ends share, so a
// correct tag is the credential and nothing has to be decrypted to check it.
func NewKeyProof(sessionKey, aad, nonce []byte) ([]byte, error) {
	if len(nonce) != NonceSize {
		return nil, fmt.Errorf("stream: nonce must be %d bytes, got %d", NonceSize, len(nonce))
	}
	aead, err := newAEAD(sessionKey)
	if err != nil {
		return nil, err
	}
	return aead.Seal(nil, nonce, nil, aad), nil
}

// VerifyKeyProof checks a sealed proof under the session key, bound to the
// same additional data the client sealed. Constant-time: hmac.Equal, so a
// wrong key cannot be recovered a byte at a time.
func VerifyKeyProof(sessionKey, aad, nonce, proof []byte) error {
	if len(nonce) != NonceSize || len(proof) != TagSize {
		return ErrAuth
	}
	aead, err := newAEAD(sessionKey)
	if err != nil {
		return err
	}
	plain, err := aead.Open(nil, nonce, proof, aad)
	if err != nil || len(plain) != 0 {
		return ErrAuth
	}
	return nil
}

func newAEAD(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("stream: cipher: %w", err)
	}
	return cipher.NewGCM(block)
}

// helloLayout is the client id, a Unix-seconds timestamp, the AEAD nonce, and
// the sealed proof. The timestamp is bound into the AEAD's additional data
// rather than sealed inside it, so the node can check the freshness window
// *before* it verifies anything — which is what stops a captured hello from
// being replayed later. The nonce rides on the wire because a GCM tag can
// only be verified with the nonce that sealed it, and it must be unique per
// key: both properties, neither one guessed at the node.
const (
	timestampSize = 8
	helloSize     = ClientIDSize + timestampSize + NonceSize + TagSize
)

// helloAAD is the additional authenticated data for a hello: the client id and
// the timestamp, exactly as they appear on the wire.
func helloAAD(clientID []byte, timestamp uint64) []byte {
	aad := make([]byte, 0, ClientIDSize+timestampSize)
	aad = append(aad, clientID...)
	var ts [timestampSize]byte
	binary.BigEndian.PutUint64(ts[:], timestamp)
	return append(aad, ts[:]...)
}

// BuildHello assembles a client's hello frame: the device id, the timestamp
// the node will check for freshness, the AEAD nonce, and the sealed key proof
// over id and timestamp. [BuildHelloAt] takes the timestamp and nonce
// explicitly so the golden vectors are deterministic; production supplies the
// current time and a random nonce.
func BuildHello(sessionKey, clientID []byte) ([]byte, error) {
	nonce, err := RandomBytes(NonceSize)
	if err != nil {
		return nil, err
	}
	return BuildHelloAt(sessionKey, clientID, timeNow().Unix(), nonce)
}

// BuildHelloAt is [BuildHello] with explicit timestamp and nonce.
func BuildHelloAt(sessionKey, clientID []byte, timestamp int64, nonce []byte) ([]byte, error) {
	if len(clientID) != ClientIDSize {
		return nil, fmt.Errorf("stream: client id must be %d bytes, got %d", ClientIDSize, len(clientID))
	}
	if len(nonce) != NonceSize {
		return nil, fmt.Errorf("stream: nonce must be %d bytes, got %d", NonceSize, len(nonce))
	}
	ts := uint64(timestamp)
	proof, err := NewKeyProof(sessionKey, helloAAD(clientID, ts), nonce)
	if err != nil {
		return nil, err
	}
	payload := make([]byte, 0, helloSize)
	payload = append(payload, clientID...)
	var tsBytes [timestampSize]byte
	binary.BigEndian.PutUint64(tsBytes[:], ts)
	payload = append(payload, tsBytes[:]...)
	payload = append(payload, nonce...)
	payload = append(payload, proof...)
	return frame(TypeHello, payload), nil
}

// ParseHelloPayload splits a hello payload into its client id, timestamp,
// nonce, and proof.
func ParseHelloPayload(payload []byte) (clientID []byte, timestamp int64, nonce, proof []byte, err error) {
	if len(payload) != helloSize {
		return nil, 0, nil, nil, fmt.Errorf("%w: hello payload is %d bytes, want %d", ErrProtocol, len(payload), helloSize)
	}
	ts := int64(binary.BigEndian.Uint64(payload[ClientIDSize : ClientIDSize+timestampSize]))
	nonceStart := ClientIDSize + timestampSize
	return payload[:ClientIDSize], ts,
		payload[nonceStart : nonceStart+NonceSize],
		payload[nonceStart+NonceSize:], nil
}

// HelloReplayWindow bounds how stale a hello may be. The node accepts a hello
// whose timestamp is within this of its own clock, which is what stops a
// captured hello from being replayed to authenticate as that device later. It
// is generous enough for ordinary clock drift, and narrow enough that a
// capture is worthless within minutes.
const HelloReplayWindow = 5 * time.Minute

// VerifyHello authenticates a hello payload with a device PSK and returns the
// client id. The freshness check comes first: a stale or future hello is
// refused before any AEAD work, and every failure is reported as [ErrAuth] so
// a prober learns nothing about which check failed.
func VerifyHello(psk, payload []byte, now time.Time) ([]byte, error) {
	clientID, timestamp, nonce, proof, err := ParseHelloPayload(payload)
	if err != nil {
		return nil, ErrAuth
	}
	skew := now.Unix() - timestamp
	if skew < 0 {
		skew = -skew
	}
	if skew > int64(HelloReplayWindow/time.Second) {
		return nil, ErrAuth
	}
	sessionKey, err := DeriveSessionKey(psk, clientID)
	if err != nil {
		return nil, ErrAuth
	}
	if err := VerifyKeyProof(sessionKey, helloAAD(clientID, uint64(timestamp)), nonce, proof); err != nil {
		return nil, ErrAuth
	}
	return clientID, nil
}

// timeNow is the clock the hello path uses, indirected so tests can pin it.
var timeNow = time.Now

// ParseHello is the validating form of [ParseHelloPayload]: it checks the
// frame version, type, and length before splitting, so a malformed hello is a
// protocol error rather than a panic.
func ParseHello(frameBytes []byte) (clientID []byte, timestamp int64, nonce, proof []byte, err error) {
	typ, payload, err := parseFrame(frameBytes)
	if err != nil {
		return nil, 0, nil, nil, err
	}
	if typ != TypeHello {
		return nil, 0, nil, nil, fmt.Errorf("%w: expected hello, got type 0x%04x", ErrProtocol, typ)
	}
	return ParseHelloPayload(payload)
}

// frame renders one frame. Exported only through the typed builders; the
// golden-vector test uses it directly to check the header bytes.
func frame(typ uint16, payload []byte) []byte {
	out := make([]byte, headerSize+len(payload))
	out[0] = Version
	binary.BigEndian.PutUint16(out[1:3], typ)
	binary.BigEndian.PutUint32(out[3:7], uint32(len(payload)))
	copy(out[headerSize:], payload)
	return out
}

// parseFrame validates and splits one frame.
func parseFrame(b []byte) (typ uint16, payload []byte, err error) {
	if len(b) < headerSize {
		return 0, nil, fmt.Errorf("%w: frame header is %d bytes", ErrProtocol, len(b))
	}
	if b[0] != Version {
		return 0, nil, fmt.Errorf("%w: version %d is not supported", ErrProtocol, b[0])
	}
	typ = binary.BigEndian.Uint16(b[1:3])
	length := binary.BigEndian.Uint32(b[3:7])
	if length > MaxPayloadSize {
		return 0, nil, fmt.Errorf("%w: payload length %d exceeds %d", ErrProtocol, length, MaxPayloadSize)
	}
	if uint32(len(b)-headerSize) != length {
		return 0, nil, fmt.Errorf("%w: frame payload is %d bytes, header says %d", ErrProtocol, len(b)-headerSize, length)
	}
	return typ, b[headerSize:], nil
}

// ReadFrame reads exactly one frame from r's buffered contents. It is a
// helper for the two connection loops; the framing itself is in this file.
func ReadFrame(buf []byte) (typ uint16, payload []byte, rest []byte, err error) {
	if len(buf) < headerSize {
		return 0, nil, buf, fmt.Errorf("%w: incomplete header", ErrProtocol)
	}
	length := int(binary.BigEndian.Uint32(buf[3:7]))
	if length > MaxPayloadSize {
		return 0, nil, buf, fmt.Errorf("%w: payload length %d exceeds %d", ErrProtocol, length, MaxPayloadSize)
	}
	total := headerSize + length
	if len(buf) < total {
		return 0, nil, buf, fmt.Errorf("%w: incomplete payload", ErrProtocol)
	}
	typ, payload, err = parseFrame(buf[:total])
	if err != nil {
		return 0, nil, buf, err
	}
	return typ, payload, buf[total:], nil
}

// BuildHelloAck is the server's single acknowledgement of a verified hello.
func BuildHelloAck() []byte { return frame(TypeHelloAck, nil) }

// BuildHelloFail is the server's refusal: a short, non-committal reason. It
// carries no detail about which part failed.
func BuildHelloFail(info string) []byte {
	if len(info) > MaxAuthInfoLen {
		info = info[:MaxAuthInfoLen]
	}
	return frame(TypeHelloFail, []byte(info))
}

// BuildDatagram frames one WireGuard datagram.
func BuildDatagram(payload []byte) ([]byte, error) {
	if len(payload) > MaxDatagramSize {
		return nil, fmt.Errorf("stream: datagram is %d bytes, over the %d limit", len(payload), MaxDatagramSize)
	}
	return frame(TypeDatagram, payload), nil
}

// ParseDatagram validates a datagram frame and returns its payload.
func ParseDatagram(frameBytes []byte) ([]byte, error) {
	typ, payload, err := parseFrame(frameBytes)
	if err != nil {
		return nil, err
	}
	if typ != TypeDatagram {
		return nil, fmt.Errorf("%w: expected datagram, got type 0x%04x", ErrProtocol, typ)
	}
	return payload, nil
}

// RandomBytes reads n cryptographically random bytes. Both halves use it for
// nonces and client ids; a test failure to inject randomness is impossible by
// construction (no package-level source to swap).
func RandomBytes(n int) ([]byte, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return nil, fmt.Errorf("stream: random: %w", err)
	}
	return b, nil
}
