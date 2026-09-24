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
)

// Version is the wire-protocol version. Both sides reject mismatches so an
// app built against a newer protocol fails loudly instead of silently
// misbehaving against an old daemon.
const Version = 1

// Request-envelope limits. The ID is opaque correlation data, not free text:
// bounding its length and charset keeps it cheap to echo and impossible to
// smuggle control bytes or unbounded data through. Capabilities are short
// lowercase tokens, so they get the same treatment.
const (
	MaxIDLength  = 64
	MaxCaps      = 16
	MaxCapLength = 32
)

// Capability tokens the daemon advertises. Negotiation is informational and
// optional: the daemon always enforces request validation, and a client that
// does not send `caps` is unaffected.
const (
	// CapStrictValidation marks enforcement of the hardened request envelope
	// (required ID, config only for `up`, strict decoding).
	CapStrictValidation = "strict-validation"
	// CapCapabilities marks that the daemon advertises its capabilities.
	CapCapabilities = "caps"
)

// SupportedCapabilities lists the capability tokens this daemon understands.
// It is returned on `ping` so the client can advertise and inspect the
// intersection; the list is advisory, never a substitute for Version.
func SupportedCapabilities() []string {
	return []string{CapStrictValidation, CapCapabilities}
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
