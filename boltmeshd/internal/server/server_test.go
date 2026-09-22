//go:build linux

package server

import (
	"bufio"
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
	mu       sync.Mutex
	upConfig string
	status   protocol.Status
	upErr    error
	downErr  error
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

func (f *fakeManager) Status() *protocol.Status { return &f.status }

type testClient struct {
	t    *testing.T
	conn net.Conn
	r    *bufio.Reader
}

func newClient(t *testing.T, m Manager) *testClient {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.sock")
	ln, err := Listen(path, "")
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}
	srv := New(m, slog.New(slog.NewTextHandler(io.Discard, nil)))
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
