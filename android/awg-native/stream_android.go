package main

/*
#include <android/log.h>
#include <stdlib.h>
extern int awgProtectSocket(int fd);
*/
import "C"

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sync"
	"syscall"

	"boltmesh/stream"
)

// streamSpec mirrors TunnelTransport.toSpecJson in the Dart client, field for
// field. The credentials pass through exactly as the control plane issued them;
// listen and deliver are this client's contribution.
type streamSpec struct {
	Mode       string   `json:"mode"`
	Listen     string   `json:"listen"`
	Deliver    string   `json:"deliver"`
	Server     string   `json:"server"`
	ServerName string   `json:"server_name"`
	SPKIPins   []string `json:"spki_sha256"`
	PSK        string   `json:"psk"`
	ClientID   string   `json:"client_id"`
}

func (s streamSpec) clientConfig(onSession func(bool, error)) (stream.ClientConfig, error) {
	if s.Mode != "stream" {
		return stream.ClientConfig{}, fmt.Errorf("stream: unsupported mode %q", s.Mode)
	}
	pins := make([][]byte, 0, len(s.SPKIPins))
	for _, pin := range s.SPKIPins {
		raw, err := base64.StdEncoding.DecodeString(pin)
		if err != nil {
			return stream.ClientConfig{}, fmt.Errorf("stream: spki pin: %w", err)
		}
		pins = append(pins, raw)
	}
	psk, err := base64.StdEncoding.DecodeString(s.PSK)
	if err != nil {
		return stream.ClientConfig{}, fmt.Errorf("stream: psk: %w", err)
	}
	clientID, err := base64.StdEncoding.DecodeString(s.ClientID)
	if err != nil {
		return stream.ClientConfig{}, fmt.Errorf("stream: client id: %w", err)
	}
	return stream.ClientConfig{
		ListenAddr:  s.Listen,
		DeliverAddr: s.Deliver,
		ServerAddr:  s.Server,
		ServerName:  s.ServerName,
		SPKIPins:    pins,
		PSK:         psk,
		ClientID:    clientID,
		DialControl: protectDial,
		Logf:        streamLogf,
		OnSession:   onSession,
	}, nil
}

func streamLogf(format string, args ...any) {
	AndroidLogger{level: C.ANDROID_LOG_DEBUG, tag: cstring("AmneziaWG/boltmesh0-stream")}.Printf(format, args...)
}

// onStreamSession records the stream's TLS session transition against
// the handle it belongs to. The state is per-handle, not a single
// package global: the callback fires from the client's own goroutine,
// so a stream being torn down can report one last transition after the
// next stream has started, and that late report must not land in the
// live stream's state. A handle absent from the map has been stopped,
// so its callbacks are dropped.
//
// A session that will not come up is the interesting case, and it is
// *not* a tunnel failure: the client already demotes on its own health
// policy. But the client needs to tell a stream rung still coming up
// (no completed end-to-end handshake yet) from one whose path has died,
// so the transition is tracked for the status read.
func onStreamSession(handle int32, up bool, err error) {
	streamMu.Lock()
	if s, ok := streamSessions[handle]; ok && s != nil {
		v := up
		streamSessions[handle] = &v
	}
	streamMu.Unlock()
	if up {
		streamLogf("session established")
		return
	}
	streamLogf("session unavailable: %v", err)
}

// protectDial keeps the bridge's TLS socket off the tunnel it carries: the
// socket must be protected from this app's VpnService between socket() and
// connect(), the only window in which its route can still be chosen. A failure
// aborts the dial rather than connecting unprotected — a leak into the tunnel
// would defeat the rung and could not be retracted.
func protectDial(_, _ string, c syscall.RawConn) error {
	var protectErr error
	if err := c.Control(func(fd uintptr) {
		if C.awgProtectSocket(C.int(fd)) != 1 {
			protectErr = errors.New("the bridge socket could not be protected from the VPN")
		}
	}); err != nil {
		return err
	}
	return protectErr
}

// requireLiteralServer rejects a hostname. The Dart layer resolves the node to
// a literal address before the start, because once the tunnel is up this app's
// resolver follows it and dialing the node through the tunnel its stream is
// needed to bring up is a deadlock. Failing fast here turns a slip in that
// contract into an error instead of a stalled connect.
func requireLiteralServer(server string) error {
	host, _, err := net.SplitHostPort(server)
	if err != nil {
		return fmt.Errorf("stream: server must be host:port: %w", err)
	}
	if net.ParseIP(host) == nil {
		return fmt.Errorf("stream: server %q is not a literal address", host)
	}
	return nil
}

var (
	streamMu    sync.Mutex
	streamSeq   int32
	liveStreams = map[int32]*stream.Client{}
	// streamSessions is the TLS session state of each live
	// stream, guarded by streamMu. A nil-or-absent entry means
	// no stream is live (or its session state is unknown), which
	// is how a native or obfuscated rung reports "not a stream
	// tunnel"; a non-nil entry is a pointer to the live
	// session — false while the bridge's session is still
	// establishing, true once it has completed. The pointer is
	// replaced rather than mutated, so a status snapshot owns its
	// own value.
	streamSessions = map[int32]*bool{}
)

//export awgStartStream
func awgStartStream(specJSON string) int32 {
	var spec streamSpec
	if err := json.Unmarshal([]byte(specJSON), &spec); err != nil {
		streamLogf("start: bad spec: %v", err)
		return -1
	}
	if err := requireLiteralServer(spec.Server); err != nil {
		streamLogf("start: %v", err)
		return -1
	}
	// Reserve the handle before the client exists, so the session
	// callback — which fires from the client's own goroutine once
	// it starts — can name the stream it belongs to.
	streamMu.Lock()
	streamSeq++
	handle := streamSeq
	streamMu.Unlock()
	cfg, err := spec.clientConfig(func(up bool, err error) {
		onStreamSession(handle, up, err)
	})
	if err != nil {
		streamLogf("start: %v", err)
		return -1
	}
	client, err := stream.NewClient(cfg)
	if err != nil {
		streamLogf("start: %v", err)
		return -1
	}
	// Record the client and seed its session to "establishing"
	// before it starts: the bridge reports a session transition
	// only once a session has *ended*, so the whole first
	// establishment window — the window the client's grace
	// covers — would otherwise read as "no stream transport at
	// all".
	streamMu.Lock()
	liveStreams[handle] = client
	streamSessions[handle] = new(bool)
	streamMu.Unlock()
	client.Start()
	return handle
}

//export awgStopStream
func awgStopStream(handle int32) {
	streamMu.Lock()
	client := liveStreams[handle]
	delete(liveStreams, handle)
	// Drop the session state before the client is stopped, so a
	// stale "established" can never outlive the stream that
	// produced it and a teardown's late callbacks find nothing to
	// write to.
	delete(streamSessions, handle)
	streamMu.Unlock()
	if client != nil {
		_ = client.Stop()
	}
}

// awgStreamSession reports the stream's TLS session state: -1
// when no stream is live (the field is then omitted, which is how
// a native or obfuscated rung reports "not a stream tunnel"), 0
// while the bridge's session is still establishing, and 1 once it
// has completed. The Java side reads it through statusAwg so the
// app can tell a stream rung still coming up from a dead one.
//
//export awgStreamSession
func awgStreamSession(handle int32) int32 {
	streamMu.Lock()
	defer streamMu.Unlock()
	s, ok := streamSessions[handle]
	if !ok || s == nil {
		return -1
	}
	if *s {
		return 1
	}
	return 0
}
