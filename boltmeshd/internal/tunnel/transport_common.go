//go:build linux || windows

// The part of the stream transport every backend shares: turning the spec's
// server into the host to pin, building the in-process bridge, resolving the
// server through the backend's pre-tunnel resolver, and publishing the
// session's lifecycle.
//
// Scoped to the two backends that run a transport; see transport_state.go.
//
// Only this half is shared. Tearing the transport down is per-backend, because
// each backend unpins through its own route API — the Linux one through
// `ip rule` and the tables wg-quick's policy rules select, the Windows one
// through the IP forward table.

package tunnel

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"strings"

	"boltmesh/stream"
	"boltmeshd/internal/protocol"
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

// newStreamClient builds the in-process transport from a validated spec. The
// credentials are decoded here, once, and never logged: the log line above
// names the addresses only.
func newStreamClient(spec *protocol.TransportSpec, onSession func(bool, error)) (streamClient, error) {
	psk, err := spec.StreamPSK()
	if err != nil {
		return nil, err
	}
	clientID, err := spec.StreamClientID()
	if err != nil {
		return nil, err
	}
	pins, err := spec.StreamSPKIPins()
	if err != nil {
		return nil, err
	}
	return stream.NewClient(stream.ClientConfig{
		ListenAddr:  spec.Listen,
		DeliverAddr: spec.Deliver,
		ServerAddr:  spec.Server,
		ServerName:  spec.ServerName,
		SPKIPins:    pins,
		PSK:         psk,
		ClientID:    clientID,
		OnSession:   onSession,
	})
}

// resolveServer turns the server host into addresses. A literal IP needs no
// resolver; a hostname does, and the *current* (physical) resolver is the
// right one: the transport comes up before any tunnel DNS state exists.
func (m *Manager) resolveServer(ctx context.Context, host string) ([]net.IP, error) {
	if literal := net.ParseIP(host); literal != nil {
		return []net.IP{literal}, nil
	}
	resolver := m.resolveHost
	if resolver == nil {
		resolver = func(ctx context.Context, host string) ([]net.IP, error) {
			return net.DefaultResolver.LookupIP(ctx, "ip", host)
		}
	}
	ips, err := resolver(ctx, host)
	if err != nil {
		return nil, fmt.Errorf("resolve stream transport upstream %s: %w", host, err)
	}
	return ips, nil
}

// transportErrorCode reports the protocol code a transport failure should
// surface as. Only a bad-config error carries its own; anything else is a
// daemon fault by default. The client's reaction depends on the distinction —
// a bad spec means it must not retry this region, an internal error may be
// transient — so it is worth preserving rather than flattening.
func transportErrorCode(err error) string {
	var opErr *protocol.OpError
	if errors.As(err, &opErr) && opErr.Code == protocol.CodeBadConfig {
		return protocol.CodeBadConfig
	}
	return protocol.CodeInternal
}

// noteStreamSession records the transport's session transitions in the log
// and in the status the client reads.
//
// A session that will not come up is the interesting case, and it is *not* a
// tunnel failure: the client already demotes on its own health policy, and
// this path has no view of the tunnel's state to act on. So the daemon does
// not second-guess the ladder — but it does publish the transition, because
// the client's health policy needs to tell a stream rung still coming up
// (no completed end-to-end handshake yet) from one whose path has died.
//
// The nil guard is what keeps a teardown's callbacks from resurrecting
// state: downTransport clears streamSession before it stops the client,
// so a session the client reports on its way down finds nothing to
// write to and is dropped.
func (m *Manager) noteStreamSession(up bool, err error) {
	m.mu.Lock()
	if m.streamSession != nil {
		v := up
		m.streamSession = &v
	}
	m.mu.Unlock()
	if up {
		slog.Info("stream transport session established", "interface", m.iface)
		return
	}
	slog.Warn("stream transport session unavailable", "interface", m.iface, "error", err)
}

// streamSessionState projects the live stream transport's TLS session
// into a status field. It reads only streamSession — never the
// gate-guarded transport pointer — so the status path, which does not
// hold the up/down gate, cannot race a lifecycle mutation. It returns
// nil when no stream transport is live (the field is then omitted,
// which is how a native/awg rung — or a daemon that predates the
// field — reports "not a stream tunnel"), and a fresh pointer to the
// current session state otherwise, so the status owns its own value
// rather than aliasing the manager's.
func (m *Manager) streamSessionState() *bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.streamSession == nil {
		return nil
	}
	up := *m.streamSession
	return &up
}
