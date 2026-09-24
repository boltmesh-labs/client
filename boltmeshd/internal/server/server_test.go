//go:build linux

package server

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"boltmeshd/internal/protocol"
)

type fakeManager struct {
	mu        sync.Mutex
	upConfig  string
	status    protocol.Status
	statusErr error
	upErr     error
	downErr   error
}

func (f *fakeManager) Up(_ context.Context, wgQuickConfig string) (*protocol.Status, error) {
	if f.upErr != nil {
		return nil, f.upErr
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.upConfig = wgQuickConfig
	return &f.status, nil
}

func (f *fakeManager) Down(context.Context) (*protocol.Status, error) {
	if f.downErr != nil {
		return nil, f.downErr
	}
	return &f.status, nil
}

func (f *fakeManager) Status(context.Context) (*protocol.Status, error) {
	if f.statusErr != nil {
		return nil, f.statusErr
	}
	return &f.status, nil
}

type cancelOnContextManager struct {
	started  chan struct{}
	canceled chan struct{}
}

func (m *cancelOnContextManager) Up(ctx context.Context, _ string) (*protocol.Status, error) {
	close(m.started)
	<-ctx.Done()
	close(m.canceled)
	return nil, ctx.Err()
}

func (m *cancelOnContextManager) Down(ctx context.Context) (*protocol.Status, error) {
	<-ctx.Done()
	return nil, ctx.Err()
}

func (m *cancelOnContextManager) Status(context.Context) (*protocol.Status, error) {
	return &protocol.Status{Interface: "boltmesh0", Stage: protocol.StageDisconnected}, nil
}

type testClient struct {
	t    *testing.T
	conn net.Conn
	r    *bufio.Reader
}

func newClient(t *testing.T, m Manager) *testClient {
	t.Helper()
	return newClientLogging(t, m, slog.New(slog.NewTextHandler(io.Discard, nil)))
}

// newClientLogging is newClient with an injectable logger, so a test can
// capture the server's operational-failure records.
func newClientLogging(t *testing.T, m Manager, log *slog.Logger) *testClient {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.sock")
	ln, err := Listen(path, "")
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}
	srv := New(m, log)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = srv.Serve(ctx, ln)
	}()

	conn, err := net.Dial("unix", path)
	if err != nil {
		cancel()
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() {
		_ = conn.Close()
		_ = ln.Close()
		cancel()
		<-done
	})
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	return &testClient{t: t, conn: conn, r: bufio.NewReader(conn)}
}

func (c *testClient) sendRaw(line string) {
	c.t.Helper()
	if _, err := c.conn.Write([]byte(line + "\n")); err != nil {
		c.t.Fatalf("write: %v", err)
	}
}

func (c *testClient) read() protocol.Response {
	c.t.Helper()
	line, err := c.r.ReadBytes('\n')
	if err != nil {
		c.t.Fatalf("read: %v", err)
	}
	var resp protocol.Response
	if err := json.Unmarshal(line, &resp); err != nil {
		c.t.Fatalf("unmarshal %q: %v", line, err)
	}
	return resp
}

func (c *testClient) request(req protocol.Request) protocol.Response {
	c.t.Helper()
	data, err := json.Marshal(req)
	if err != nil {
		c.t.Fatal(err)
	}
	c.sendRaw(string(data))
	return c.read()
}

func TestPingReturnsStatus(t *testing.T) {
	m := &fakeManager{status: protocol.Status{Interface: "boltmesh0", Up: true, Stage: protocol.StageConnected}}
	c := newClient(t, m)

	resp := c.request(protocol.Request{V: protocol.Version, ID: "1", Op: protocol.OpPing})
	if !resp.OK || resp.Status == nil || resp.Status.Interface != "boltmesh0" {
		t.Fatalf("ping response = %+v", resp)
	}
}

func TestStatusReadFailureIsNotReportedAsDisconnected(t *testing.T) {
	want := &protocol.OpError{Code: protocol.CodeInternal, Err: errors.New("SCM read failed")}
	c := newClient(t, &fakeManager{statusErr: want})

	for _, op := range []string{protocol.OpPing, protocol.OpStatus} {
		resp := c.request(protocol.Request{V: protocol.Version, ID: "1", Op: op})
		if resp.OK || resp.Status != nil || resp.Error == nil {
			t.Fatalf("%s response = %+v, want error without status", op, resp)
		}
		if resp.Error.Code != protocol.CodeInternal {
			t.Fatalf("%s error code = %q, want internal", op, resp.Error.Code)
		}
	}
}

func TestUpPassesConfigThrough(t *testing.T) {
	m := &fakeManager{status: protocol.Status{Up: true, Stage: protocol.StageConnected}}
	c := newClient(t, m)

	const cfg = "[Interface]\nPrivateKey = x\n"
	resp := c.request(protocol.Request{V: protocol.Version, ID: "1", Op: protocol.OpUp, Config: cfg})
	if !resp.OK {
		t.Fatalf("up response = %+v", resp)
	}
	if m.upConfig != cfg {
		t.Fatalf("manager config = %q, want %q", m.upConfig, cfg)
	}
}

func TestOpErrorMapsToWireCode(t *testing.T) {
	m := &fakeManager{upErr: &protocol.OpError{Code: protocol.CodeBadConfig, Err: errors.New("nope")}}
	c := newClient(t, m)

	resp := c.request(protocol.Request{V: protocol.Version, ID: "1", Op: protocol.OpUp, Config: "x"})
	if resp.OK || resp.Error == nil || resp.Error.Code != protocol.CodeBadConfig {
		t.Fatalf("response = %+v, want bad_config", resp)
	}
}

func TestClosingClientCancelsPrivilegedOperation(t *testing.T) {
	m := &cancelOnContextManager{
		started:  make(chan struct{}),
		canceled: make(chan struct{}),
	}
	c := newClient(t, m)
	c.sendRaw(`{"v":1,"id":"1","op":"up","config":"[Interface]\nPrivateKey = x\n"}`)

	select {
	case <-m.started:
	case <-time.After(time.Second):
		t.Fatal("manager did not start the operation")
	}
	if err := c.conn.Close(); err != nil {
		t.Fatal(err)
	}

	select {
	case <-m.canceled:
	case <-time.After(time.Second):
		t.Fatal("closing the client did not cancel the operation")
	}
}

func TestServeWaitsForHandlersOnShutdown(t *testing.T) {
	m := &cancelOnContextManager{
		started:  make(chan struct{}),
		canceled: make(chan struct{}),
	}
	path := filepath.Join(t.TempDir(), "shutdown.sock")
	ln, err := Listen(path, "")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = ln.Close() }()

	ctx, cancel := context.WithCancel(context.Background())
	served := make(chan error, 1)
	go func() { served <- New(m, slog.New(slog.NewTextHandler(io.Discard, nil))).Serve(ctx, ln) }()

	conn, err := net.Dial("unix", path)
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	defer func() { _ = conn.Close() }()
	if _, err := conn.Write([]byte(`{"v":1,"id":"1","op":"up","config":"x"}` + "\n")); err != nil {
		cancel()
		t.Fatal(err)
	}
	select {
	case <-m.started:
	case <-time.After(time.Second):
		cancel()
		t.Fatal("manager did not start")
	}

	cancel()
	select {
	case err := <-served:
		if err != nil {
			t.Fatalf("Serve() = %v, want clean shutdown", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Serve returned before active handler finished")
	}
	select {
	case <-m.canceled:
	case <-time.After(time.Second):
		t.Fatal("shutdown did not cancel active handler")
	}
}

func TestVersionMismatchRejected(t *testing.T) {
	c := newClient(t, &fakeManager{})

	resp := c.request(protocol.Request{V: protocol.Version + 1, ID: "1", Op: protocol.OpPing})
	if resp.OK || resp.Error == nil || resp.Error.Code != protocol.CodeBadRequest {
		t.Fatalf("response = %+v, want bad_request", resp)
	}
}

func TestUnknownOpRejected(t *testing.T) {
	c := newClient(t, &fakeManager{})

	resp := c.request(protocol.Request{V: protocol.Version, ID: "1", Op: "bogus"})
	if resp.OK || resp.Error == nil || resp.Error.Code != protocol.CodeBadRequest {
		t.Fatalf("response = %+v, want bad_request", resp)
	}
}

func TestInvalidJSONKeepsFraming(t *testing.T) {
	c := newClient(t, &fakeManager{})

	c.sendRaw("this is not json")
	if resp := c.read(); resp.OK || resp.Error == nil || resp.Error.Code != protocol.CodeBadRequest {
		t.Fatalf("first response = %+v, want bad_request", resp)
	}
	if resp := c.request(protocol.Request{V: protocol.Version, ID: "2", Op: protocol.OpPing}); !resp.OK {
		t.Fatalf("second response = %+v, want ok", resp)
	}
}

func TestOversizeRequestKeepsFraming(t *testing.T) {
	c := newClient(t, &fakeManager{})

	c.sendRaw(`{"v":1,"id":"1","op":"up","config":"` + strings.Repeat("x", maxRequestLine) + `"}`)
	if resp := c.read(); resp.OK || resp.Error == nil || resp.Error.Code != protocol.CodeBadRequest {
		t.Fatalf("first response = %+v, want bad_request", resp)
	}
	if resp := c.request(protocol.Request{V: protocol.Version, ID: "2", Op: protocol.OpPing}); !resp.OK {
		t.Fatalf("second response = %+v, want ok", resp)
	}
}

// rejected asserts that req is rejected with bad_request, then confirms the
// connection still frames the next request.
func rejected(t *testing.T, c *testClient, req protocol.Request) protocol.Response {
	t.Helper()
	resp := c.request(req)
	if resp.OK || resp.Error == nil || resp.Error.Code != protocol.CodeBadRequest {
		t.Fatalf("response = %+v, want bad_request", resp)
	}
	if next := c.request(protocol.Request{V: protocol.Version, ID: "999", Op: protocol.OpPing}); !next.OK {
		t.Fatalf("follow-up response = %+v, want ok", next)
	}
	return resp
}

func TestEmptyIDRejected(t *testing.T) {
	resp := rejected(t, newClient(t, &fakeManager{}), protocol.Request{V: protocol.Version, Op: protocol.OpPing})
	if resp.ID != "" {
		t.Fatalf("rejected response echoed id %q, want empty", resp.ID)
	}
}

func TestOverlongIDRejected(t *testing.T) {
	resp := rejected(t, newClient(t, &fakeManager{}), protocol.Request{
		V:  protocol.Version,
		ID: strings.Repeat("a", protocol.MaxIDLength+1),
		Op: protocol.OpPing,
	})
	if resp.ID != "" {
		t.Fatalf("rejected response echoed id %q, want empty", resp.ID)
	}
}

func TestInvalidIDCharactersRejected(t *testing.T) {
	resp := rejected(t, newClient(t, &fakeManager{}), protocol.Request{
		V:  protocol.Version,
		ID: "a b",
		Op: protocol.OpPing,
	})
	if resp.ID != "" {
		t.Fatalf("rejected response echoed id %q, want empty", resp.ID)
	}
}

func TestConfigRejectedForNonUpOps(t *testing.T) {
	for _, op := range []string{protocol.OpPing, protocol.OpStatus, protocol.OpDown} {
		t.Run(op, func(t *testing.T) {
			// A well-formed ID is echoed even on rejection, so the client can
			// correlate the failure to its request.
			resp := rejected(t, newClient(t, &fakeManager{}), protocol.Request{
				V:      protocol.Version,
				ID:     "1",
				Op:     op,
				Config: "x",
			})
			if resp.ID != "1" {
				t.Fatalf("rejected response id = %q, want %q", resp.ID, "1")
			}
		})
	}
}

func TestUpRequiresConfig(t *testing.T) {
	m := &fakeManager{}
	rejected(t, newClient(t, m), protocol.Request{V: protocol.Version, ID: "1", Op: protocol.OpUp})
	if m.upConfig != "" {
		t.Fatalf("manager was called with %q", m.upConfig)
	}
}

func TestUnknownFieldRejected(t *testing.T) {
	c := newClient(t, &fakeManager{})

	c.sendRaw(`{"v":1,"id":"1","op":"ping","bogus":true}`)
	if resp := c.read(); resp.OK || resp.Error == nil || resp.Error.Code != protocol.CodeBadRequest {
		t.Fatalf("response = %+v, want bad_request", resp)
	}
	if next := c.request(protocol.Request{V: protocol.Version, ID: "2", Op: protocol.OpPing}); !next.OK {
		t.Fatalf("follow-up response = %+v, want ok", next)
	}
}

func TestTrailingDataRejected(t *testing.T) {
	c := newClient(t, &fakeManager{})

	c.sendRaw(`{"v":1,"id":"1","op":"ping"} {"v":1}`)
	if resp := c.read(); resp.OK || resp.Error == nil || resp.Error.Code != protocol.CodeBadRequest {
		t.Fatalf("response = %+v, want bad_request", resp)
	}
	if next := c.request(protocol.Request{V: protocol.Version, ID: "2", Op: protocol.OpPing}); !next.OK {
		t.Fatalf("follow-up response = %+v, want ok", next)
	}
}

func TestResponseEchoesRequestID(t *testing.T) {
	c := newClient(t, &fakeManager{status: protocol.Status{Interface: "boltmesh0"}})

	resp := c.request(protocol.Request{V: protocol.Version, ID: "abc-123", Op: protocol.OpPing})
	if !resp.OK || resp.ID != "abc-123" {
		t.Fatalf("response = %+v, want echoed id", resp)
	}
}

func TestPingAdvertisesCapabilities(t *testing.T) {
	c := newClient(t, &fakeManager{})

	resp := c.request(protocol.Request{V: protocol.Version, ID: "1", Op: protocol.OpPing})
	if !containsCap(resp.Caps, protocol.CapCapabilities) {
		t.Fatalf("ping caps = %v, want capabilities token", resp.Caps)
	}
	// `status` stays lean: no capability list on every read.
	status := c.request(protocol.Request{V: protocol.Version, ID: "2", Op: protocol.OpStatus})
	if len(status.Caps) != 0 {
		t.Fatalf("status caps = %v, want none", status.Caps)
	}
}

func containsCap(caps []string, token string) bool {
	for _, cap := range caps {
		if cap == token {
			return true
		}
	}
	return false
}

func TestValidCapsAccepted(t *testing.T) {
	c := newClient(t, &fakeManager{})

	resp := c.request(protocol.Request{
		V:    protocol.Version,
		ID:   "1",
		Op:   protocol.OpPing,
		Caps: []string{protocol.CapStrictValidation},
	})
	if !resp.OK {
		t.Fatalf("response = %+v, want ok", resp)
	}
}

// TestFailureRecordIsStructured pins the persisted failure-log contract: the
// daemon emits one machine-readable record per privileged-operation failure,
// carrying the op and code but never the client's config (which holds the
// WireGuard private key).
func TestFailureRecordIsStructured(t *testing.T) {
	var buf bytes.Buffer
	m := &fakeManager{upErr: &protocol.OpError{
		Code: protocol.CodeInternal,
		Err:  errors.New("wg-quick up: exit status 1"),
	}}
	c := newClientLogging(t, m, slog.New(slog.NewJSONHandler(&buf, &slog.HandlerOptions{Level: slog.LevelWarn})))

	const secretConfig = "[Interface]\nPrivateKey = super-secret-key\n"
	resp := c.request(protocol.Request{V: protocol.Version, ID: "1", Op: protocol.OpUp, Config: secretConfig})
	if resp.OK || resp.Error == nil || resp.Error.Code != protocol.CodeInternal {
		t.Fatalf("response = %+v, want internal failure", resp)
	}

	var rec map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(buf.Bytes()), &rec); err != nil {
		t.Fatalf("failure record is not JSON: %v (%q)", err, buf.String())
	}
	if rec["msg"] != "tunnel operation failed" {
		t.Fatalf("record msg = %v, want tunnel operation failed", rec["msg"])
	}
	if rec["op"] != protocol.OpUp || rec["code"] != protocol.CodeInternal {
		t.Fatalf("record = %v, want op=up code=internal", rec)
	}
	if strings.Contains(buf.String(), "super-secret-key") || strings.Contains(buf.String(), "PrivateKey") {
		t.Fatalf("failure record leaked the config: %s", buf.String())
	}
}
