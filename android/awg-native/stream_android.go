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

func (s streamSpec) clientConfig() (stream.ClientConfig, error) {
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
		OnSession:   onStreamSession,
	}, nil
}

func streamLogf(format string, args ...any) {
	AndroidLogger{level: C.ANDROID_LOG_DEBUG, tag: cstring("AmneziaWG/boltmesh0-stream")}.Printf(format, args...)
}

func onStreamSession(up bool, err error) {
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
	cfg, err := spec.clientConfig()
	if err != nil {
		streamLogf("start: %v", err)
		return -1
	}
	client, err := stream.NewClient(cfg)
	if err != nil {
		streamLogf("start: %v", err)
		return -1
	}
	client.Start()
	streamMu.Lock()
	defer streamMu.Unlock()
	streamSeq++
	handle := streamSeq
	liveStreams[handle] = client
	return handle
}

//export awgStopStream
func awgStopStream(handle int32) {
	streamMu.Lock()
	client := liveStreams[handle]
	delete(liveStreams, handle)
	streamMu.Unlock()
	if client != nil {
		_ = client.Stop()
	}
}
