// Package protocol defines the newline-delimited JSON wire format spoken
// between the BoltMesh Flutter client and boltmeshd over the Unix socket.
//
// One request per line, one response per line. The client sends the tunnel
// operation and (for `up`) the wg-quick config text it already builds; the
// daemon owns every privileged action and all privileged reads.
package protocol

import (
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
)

// Version is the wire-protocol version. Both sides reject mismatches so an
// app built against a newer protocol fails loudly instead of silently
// misbehaving against an old daemon.
const Version = 1

// Request-envelope limits. The ID is opaque correlation data, not free text:
// bounding its length and charset keeps it cheap to echo and impossible to
// smuggle control bytes or unbounded data through. Capabilities are short
// lowercase tokens, so they get the same treatment. The transport spec
// carries a small, fixed set of addresses and credentials, so it is bounded
// the same way.
const (
	MaxIDLength  = 64
	MaxCaps      = 16
	MaxCapLength = 32
	// MaxTransportPort bounds a transport port. Ports are uint16 by
	// construction; the upper bound only rejects the zero port, which is
	// never dialable.
	MaxTransportPort = 65535
	// MaxTransportServerName bounds the TLS server name (an SNI, so a
	// hostname or a short IP literal).
	MaxTransportServerName = 253
	// MaxTransportSPKIPins bounds how many certificate pins a node may
	// offer, so a node rotating its key can ship the next pin alongside the
	// current one without the field becoming an open list.
	MaxTransportSPKIPins = 4
	// MaxTransportSecretSize bounds a base64 credential field. The real
	// values are 32 bytes (32 base64 characters) and 16 bytes; the headroom
	// only exists so a future key size is not an envelope change.
	MaxTransportSecretSize = 128
)

// Transport modes. `stream` carries the tunnel's UDP datagrams inside a TLS
// session the daemon runs itself (for networks that block non-TLS WireGuard
// UDP, or fingerprint it). The WireGuard endpoint in the config is then a
// loopback address and `server` names the real node the session goes to.
const TransportModeStream = "stream"

// TransportSpec is the optional `up` transport the daemon must run for the
// tunnel: everything `internal/stream` needs to carry the tunnel's datagrams
// to the node, and the two local addresses it needs to do so.
//
// It is a credential set, not a program. The daemon runs the transport
// in-process (root-only, no external binary, so there is nothing to sign,
// ship, or fingerprint), which is why this carries the node's certificate
// pins and the device's pre-shared key instead of a configuration document.
// The client is the only side that knows those values, and it obtains them
// from the control plane the same way it obtains the tunnel's keys.
//
// Lifecycle is the daemon's because the tunnel's is: an app-restarted client
// would otherwise orphan the transport, and only the daemon can install the
// bypass route that keeps the transport's own egress out of the tunnel it
// carries.
//
// PSK is a secret: it is never logged, never echoed in an error, and never
// written to disk. It travels over the daemon's local socket, which is the
// same channel the tunnel's own private key already travels on.
type TransportSpec struct {
	// Mode is [TransportModeStream].
	Mode string `json:"mode"`
	// Listen is the loopback `host:port` the tunnel's peer Endpoint points
	// at: the transport's local inbound, where the tunnel's datagrams
	// arrive.
	Listen string `json:"listen"`
	// Deliver is the loopback `host:port` of the tunnel's own WireGuard
	// listen port, where the node's datagrams are handed back. It is
	// explicit because it cannot be derived: an interface with
	// ListenPort=0 takes an ephemeral port nobody can guess, so the client
	// pins the local port when it selects this transport.
	Deliver string `json:"deliver"`
	// Server is the `host[:port]` of the node's TLS endpoint, i.e. the real
	// server behind the stream. Its address family picks the family of the
	// bypass route; the port is optional (defaults to 443).
	Server string `json:"server"`
	// ServerName is the SNI to present and the name the certificate pin is
	// checked against.
	ServerName string `json:"server_name"`
	// SPKIPins are the SHA-256 digests of the node's leaf public key, base64
	// encoded. At least one is required: a pinned stream with no pin would be
	// a stream to whoever answers. Several are allowed so a node can rotate
	// its key without a client release.
	SPKIPins []string `json:"spki_sha256"`
	// PSK is the device's stream credential, base64. It authenticates the
	// tunnel to the node, so the node's port is not an open relay for anyone
	// who finds it.
	PSK string `json:"psk"`
	// ClientID is the device's stream identity, base64. The node looks the
	// PSK up by it; it is a random per-device id rather than the device UUID
	// so the node's table can be keyed without publishing stable identifiers.
	ClientID string `json:"client_id"`
}

// Validate checks the spec envelope. Callers have already run request
// validation, so this only covers the transport's own shape; failures are
// client programming errors ([CodeBadRequest]). No error here includes a
// credential value, so a rejected spec cannot leak the PSK into a log.
func (t *TransportSpec) Validate() error {
	if t.Mode != TransportModeStream {
		return fmt.Errorf("unsupported transport mode %q", t.Mode)
	}
	if err := validateLoopbackEndpoint("listen", t.Listen); err != nil {
		return err
	}
	if err := validateLoopbackEndpoint("deliver", t.Deliver); err != nil {
		return err
	}
	if err := validateServer("server", t.Server); err != nil {
		return err
	}
	if err := validateServerName(t.ServerName); err != nil {
		return err
	}
	if len(t.SPKIPins) == 0 {
		return errors.New("transport requires a certificate pin")
	}
	if len(t.SPKIPins) > MaxTransportSPKIPins {
		return errors.New("transport has too many certificate pins")
	}
	for _, pin := range t.SPKIPins {
		digest, err := decodeBase64(pin, MaxTransportSecretSize)
		if err != nil || len(digest) != sha256.Size {
			return errors.New("transport certificate pin is not a sha-256 digest")
		}
	}
	if err := validateCredential("psk", t.PSK); err != nil {
		return err
	}
	if _, err := t.StreamPSK(); err != nil {
		return err
	}
	if _, err := t.StreamClientID(); err != nil {
		return err
	}
	return nil
}

// StreamPSK decodes the device's pre-shared key. Sizes are checked here
// because the key derivation is the one thing that must not be attempted
// with the wrong amount of entropy.
func (t *TransportSpec) StreamPSK() ([]byte, error) {
	return decodeCredential("psk", t.PSK, 32)
}

// StreamClientID decodes the device's stream identity.
func (t *TransportSpec) StreamClientID() ([]byte, error) {
	return decodeCredential("client_id", t.ClientID, 16)
}

// StreamSPKIPins decodes the node's certificate pins.
func (t *TransportSpec) StreamSPKIPins() ([][]byte, error) {
	pins := make([][]byte, 0, len(t.SPKIPins))
	for i, pin := range t.SPKIPins {
		digest, err := decodeCredential(fmt.Sprintf("spki_sha256[%d]", i), pin, sha256.Size)
		if err != nil {
			return nil, err
		}
		pins = append(pins, digest)
	}
	return pins, nil
}

func validateCredential(field, value string) error {
	if value == "" {
		return fmt.Errorf("transport requires %s", field)
	}
	if len(value) > MaxTransportSecretSize {
		return fmt.Errorf("transport %s is too long", field)
	}
	return nil
}

// decodeCredential decodes a base64 credential of an exact size. The field
// name appears in errors; the value never does.
func decodeCredential(field, value string, size int) ([]byte, error) {
	decoded, err := decodeBase64(value, MaxTransportSecretSize)
	if err != nil {
		return nil, fmt.Errorf("transport %s is not base64", field)
	}
	if len(decoded) != size {
		return nil, fmt.Errorf("transport %s must decode to %d bytes, got %d", field, size, len(decoded))
	}
	return decoded, nil
}

func decodeBase64(value string, max int) ([]byte, error) {
	if len(value) > max {
		return nil, errors.New("base64 value is too long")
	}
	return base64.StdEncoding.DecodeString(value)
}

func validateServerName(name string) error {
	if name == "" {
		return errors.New("transport requires a server name")
	}
	if len(name) > MaxTransportServerName {
		return errors.New("transport server name is too long")
	}
	if strings.ContainsAny(name, " \t\r\n/\\") {
		return errors.New("transport server name is malformed")
	}
	return nil
}

// validateLoopbackEndpoint requires a loopback `host:port`, the only address
// the tunnel may be pointed at in stream mode: a non-loopback listen address
// would make the daemon (running as root) hand the tunnel a peer it should be
// routing around.
func validateLoopbackEndpoint(field, value string) error {
	host, port, err := net.SplitHostPort(value)
	if err != nil {
		return fmt.Errorf("transport %s must be host:port", field)
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	if ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("transport %s must be a loopback address", field)
	}
	if err := validatePort(field, port); err != nil {
		return err
	}
	return nil
}

func validateServer(field, value string) error {
	host, port, err := net.SplitHostPort(value)
	if err != nil {
		// A bare host is allowed: the port defaults to 443, which is the
		// only port a stream transport dials.
		host, port = value, "443"
	}
	if strings.TrimSpace(host) == "" {
		return fmt.Errorf("transport %s has no host", field)
	}
	if strings.ContainsAny(host, " \t\r\n") {
		return fmt.Errorf("transport %s has a malformed host", field)
	}
	return validatePort(field, port)
}

func validatePort(field, port string) error {
	n, err := strconv.Atoi(port)
	if err != nil || n <= 0 || n > MaxTransportPort {
		return fmt.Errorf("transport %s has an invalid port", field)
	}
	return nil
}

// Capability tokens the daemon advertises. Negotiation is informational and
// optional: the daemon always enforces request validation, and a client that
// does not send `caps` is unaffected.
const (
	// CapStrictValidation marks enforcement of the hardened request envelope
	// (required ID, config only for `up`, strict decoding).
	CapStrictValidation = "strict-validation"
	// CapCapabilities marks that the daemon advertises its capabilities.
	CapCapabilities = "caps"
	// CapStreamTransport marks that the daemon runs a stream transport's
	// stream transport for `up` and pins its server route. A client must
	// see this token before selecting the stream rung: without it the
	// transport would never start and the tunnel would sit on a dead
	// loopback endpoint.
	CapStreamTransport = "stream-transport"
)

// SupportedCapabilities lists the capability tokens this daemon understands.
// It is returned on `ping` so the client can advertise and inspect the
// intersection; the list is advisory, never a substitute for Version.
func SupportedCapabilities() []string {
	return []string{CapStrictValidation, CapCapabilities, CapStreamTransport}
}

// Operations.
const (
	OpPing   = "ping"
	OpStatus = "status"
	OpUp     = "up"
	OpDown   = "down"
)

// Stages the client maps onto its own VpnStage enum. The daemon reports the
// OS-level truth; the app keeps its phase/health state machine on top.
const (
	StageConnected    = "connected"
	StageConnecting   = "connecting"
	StageDisconnected = "disconnected"
)

// Error codes. `bad_config` is returned for a config that fails validation
// (never for a privileged-operation failure), so the client can distinguish
// a programming error from an environment problem.
const (
	CodeBadRequest  = "bad_request"
	CodeBadConfig   = "bad_config"
	CodeUnavailable = "unavailable"
	CodeInternal    = "internal"
)

// Request is one line from the client.
type Request struct {
	V  int    `json:"v"`
	ID string `json:"id"`
	Op string `json:"op"`
	// Config is nil when the field is omitted. A non-nil pointer preserves an
	// explicitly empty value, which remains distinct for envelope validation.
	Config *string  `json:"config,omitempty"`
	Caps   []string `json:"caps,omitempty"`
	// Transport is nil when the field is omitted: the tunnel runs on the
	// WireGuard data plane alone. A non-nil spec (stream mode) additionally
	// requires a local transport, which the daemon runs for the tunnel's
	// lifetime.
	Transport *TransportSpec `json:"transport,omitempty"`
}

// Validate checks the request envelope and rejects malformed field
// combinations before any privileged work is dispatched. Every failure is a
// client programming error and maps to [CodeBadRequest]; config *content*
// stays the domain of the config package ([CodeBadConfig]).
func (r *Request) Validate() error {
	if !ValidID(r.ID) {
		return errors.New("invalid request id")
	}
	switch r.Op {
	case OpPing, OpStatus, OpDown:
		if r.Config != nil {
			return fmt.Errorf("config is not allowed for op %q", r.Op)
		}
	case OpUp:
		if r.Config == nil || *r.Config == "" {
			return fmt.Errorf("op %q requires a config", r.Op)
		}
	default:
		return fmt.Errorf("unsupported op %q", r.Op)
	}
	// The transport rides the tunnel, so only `up` may carry one: a spec on a
	// status or down request would describe a transport the daemon is not
	// running.
	if r.Transport != nil {
		if r.Op != OpUp {
			return fmt.Errorf("transport is not allowed for op %q", r.Op)
		}
		if err := r.Transport.Validate(); err != nil {
			return err
		}
	}
	return validateCaps(r.Caps)
}

// ValidID reports whether id is a well-formed correlation identifier: 1 to
// [MaxIDLength] characters from `[A-Za-z0-9._:-]`. The empty ID is invalid;
// every request must be correlatable.
func ValidID(id string) bool {
	if id == "" || len(id) > MaxIDLength {
		return false
	}
	for i := 0; i < len(id); i++ {
		switch c := id[i]; {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '.', c == '_', c == '-', c == ':':
		default:
			return false
		}
	}
	return true
}

// validateCaps bounds the optional capability list: at most [MaxCaps] tokens
// of at most [MaxCapLength] lowercase letters, digits and hyphens.
func validateCaps(caps []string) error {
	if len(caps) > MaxCaps {
		return errors.New("too many capabilities")
	}
	for _, cap := range caps {
		if cap == "" || len(cap) > MaxCapLength {
			return fmt.Errorf("invalid capability %q", cap)
		}
		for i := 0; i < len(cap); i++ {
			c := cap[i]
			switch {
			case c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '-':
			default:
				return fmt.Errorf("invalid capability %q", cap)
			}
		}
	}
	return nil
}

// Error is the machine-readable failure attached to a response.
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// Status is the daemon's view of the tunnel. Zero-valued counters and a zero
// LastHandshake mean "unknown", never "dead" on their own — the client's
// policy decides.
type Status struct {
	Interface string `json:"interface"`
	Up        bool   `json:"up"`
	Stage     string `json:"stage"`

	// Endpoint and PublicKey describe the peer with the newest handshake.
	Endpoint  string `json:"endpoint,omitempty"`
	PublicKey string `json:"publicKey,omitempty"`

	// LastHandshake is unix seconds of the newest completed handshake, or 0
	// when no peer has ever handshook.
	LastHandshake int64 `json:"lastHandshake"`

	// RxBytes/TxBytes are summed across peers.
	RxBytes int64 `json:"rxBytes"`
	TxBytes int64 `json:"txBytes"`
}

// Response is one line to the client.
type Response struct {
	V      int      `json:"v"`
	ID     string   `json:"id"`
	OK     bool     `json:"ok"`
	Error  *Error   `json:"error,omitempty"`
	Status *Status  `json:"status,omitempty"`
	Caps   []string `json:"caps,omitempty"`
}

// OK builds a successful response carrying [Status].
func OK(id string, status *Status) Response {
	return Response{V: Version, ID: id, OK: true, Status: status}
}

// OKCapabilities builds a successful response that also advertises the
// daemon's capability tokens. Used for `ping`, the negotiation entry point.
func OKCapabilities(id string, status *Status) Response {
	resp := OK(id, status)
	resp.Caps = SupportedCapabilities()
	return resp
}

// Fail builds a failed response with the given code and message.
func Fail(id, code, message string) Response {
	return Response{
		V:     Version,
		ID:    id,
		OK:    false,
		Error: &Error{Code: code, Message: message},
	}
}

// OpError carries a protocol error code alongside a Go error, so the server
// can map operational failures onto the wire without inspecting strings.
type OpError struct {
	Code string
	Err  error
}

func (e *OpError) Error() string { return e.Err.Error() }

// Unwrap exposes the underlying error for errors.Is/As.
func (e *OpError) Unwrap() error { return e.Err }
