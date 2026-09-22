// Package protocol defines the newline-delimited JSON wire format spoken
// between the BoltMesh Flutter client and boltmeshd over the Unix socket.
//
// One request per line, one response per line. The client sends the tunnel
// operation and (for `up`) the wg-quick config text it already builds; the
// daemon owns every privileged action and all privileged reads.
package protocol

// Version is the wire-protocol version. Both sides reject mismatches so an
// app built against a newer protocol fails loudly instead of silently
// misbehaving against an old daemon.
const Version = 1

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
	V      int    `json:"v"`
	ID     string `json:"id"`
	Op     string `json:"op"`
	Config string `json:"config,omitempty"`
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
	V      int     `json:"v"`
	ID     string  `json:"id"`
	OK     bool    `json:"ok"`
	Error  *Error  `json:"error,omitempty"`
	Status *Status `json:"status,omitempty"`
}

// OK builds a successful response carrying [Status].
func OK(id string, status *Status) Response {
	return Response{V: Version, ID: id, OK: true, Status: status}
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
