// Package protocol defines the newline-delimited JSON wire format spoken
// between the BoltMesh Flutter client and boltmeshd over the Unix socket.
//
// One request per line, one response per line. The client sends the tunnel
// operation and (for `up`) the wg-quick config text it already builds; the
// daemon owns every privileged action and all privileged reads.
package protocol

import (
	"errors"
	"fmt"
	"net"
	"path/filepath"
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
// lowercase tokens, so they get the same treatment. The transport spec is
// the client's authored forwarder document plus the two addresses the
// daemon acts on, so it gets the same bounding.
const (
	MaxIDLength  = 64
	MaxCaps      = 16
	MaxCapLength = 32
	// MaxForwarderConfigSize bounds the opaque forwarder configuration
	// document. Real ones are a few KiB of JSON; 256 KiB is generous while
	// still refusing memory-exhaustion payloads (and it lands in a root-only
	// file).
	MaxForwarderConfigSize = 256 * 1024
	// MaxTransportListenPort / MaxTransportUpstreamPort bound the two
	// addresses. Ports are uint16 by construction; the upper bounds only
	// reject the zero port, which is never dialable.
	MaxTransportListenPort   = 65535
	MaxTransportUpstreamPort = 65535
)

// Transport modes. `stream` carries the tunnel's UDP datagrams inside a
// locally-run forwarder's stream transport (for networks that block
// non-TLS WireGuard UDP, or fingerprint it). The WireGuard endpoint in the
// config is then a loopback address and `upstream` names the real server the
// forwarder dials.
const TransportModeStream = "stream"

// TransportSpec is the optional `up` transport the daemon must run for the
// tunnel. The client authors both halves: `config` is the complete document
// handed to the forwarder binary verbatim (the client tracks that tool's
// schema, the daemon does not), while `listen` and `upstream` are the two
// addresses the daemon acts on itself — `listen` is what it waits for before
// reporting the tunnel up, and `upstream` is what it pins through the
// physical path so the forwarder's own egress can never loop into the tunnel
// it carries.
//
// The forwarder is not a privilege boundary (it binds a loopback port and
// dials out), but its lifecycle is owned by the daemon because the tunnel's
// is: an app-restarted client would otherwise orphan it, and only the daemon
// can install the bypass route.
type TransportSpec struct {
	// Mode is [TransportModeStream].
	Mode string `json:"mode"`
	// Listen is the loopback `host:port` the tunnel's peer Endpoint points
	// at (the forwarder's local inbound).
	Listen string `json:"listen"`
	// Upstream is the `host[:port]` the forwarder dials, i.e. the real
	// server endpoint behind the stream. Its address family picks the
	// family of the bypass route; the port is optional (defaults to 443).
	Upstream string `json:"upstream"`
	// Config is the forwarder's own configuration document, written to a
	// root-only file and passed to the binary by path.
	Config string `json:"config"`
	// Binary is the forwarder executable name, resolved under the daemon's
	// fixed tool directories (never PATH).
	Binary string `json:"binary"`
}

// Validate checks the spec envelope. Callers have already run request
// validation, so this only covers the transport's own shape; failures are
// client programming errors ([CodeBadRequest]).
func (t *TransportSpec) Validate() error {
	if t.Mode != TransportModeStream {
		return fmt.Errorf("unsupported transport mode %q", t.Mode)
	}
	if err := validateLoopbackEndpoint("listen", t.Listen); err != nil {
		return err
	}
	if err := validateUpstream("upstream", t.Upstream); err != nil {
		return err
	}
	if t.Binary == "" {
		return errors.New("transport requires a binary")
	}
	// A bare name only: the daemon resolves it under its fixed tool
	// directories, and a path would let the client choose the file the
	// daemon executes as root.
	if strings.ContainsAny(t.Binary, `/\`) || t.Binary != filepath.Base(t.Binary) {
		return errors.New("transport binary must be a bare name")
	}
	if len(t.Config) == 0 {
		return errors.New("transport requires a config document")
	}
	if len(t.Config) > MaxForwarderConfigSize {
		return errors.New("transport config is too large")
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

func validateUpstream(field, value string) error {
	host, port, err := net.SplitHostPort(value)
	if err != nil {
		// A bare host is allowed: the port defaults to 443 for stream
		// transports, which all dial TLS.
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
	if err != nil || n <= 0 || n > MaxTransportListenPort {
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
	// local forwarder for `up` and pins its upstream route. A client must
	// see this token before selecting the stream rung: without it the
	// forwarder would never start and the tunnel would sit on a dead
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
	// requires a local forwarder, which the daemon runs for the tunnel's
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
	// status or down request would describe a forwarder the daemon is not
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
