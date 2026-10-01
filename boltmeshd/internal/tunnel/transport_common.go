//go:build linux || windows

// The part of the stream transport every backend shares: turning the spec's
// server into the host to pin.
//
// Scoped to the two backends that run a transport; see transport_state.go.
//
// Only this half is shared. Resolving that host is per-backend, because each
// backend resolves through the resolver it already has — the Linux one through
// the system's, the Windows one through Go's — and neither shares the other's.

package tunnel

import (
	"net"
	"strings"
)

// splitServer splits the transport's server into host and port. A bare host is
// legal (the envelope validation already rejected an empty or malformed one);
// stream transports all dial TLS, so 443 is the implied port.
func splitServer(server string) (string, string) {
	if host, port, err := net.SplitHostPort(server); err == nil {
		return strings.TrimSpace(host), port
	}
	return strings.TrimSpace(server), "443"
}
