//go:build linux

package main

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"boltmeshd/internal/protocol"
)

type cleanupContextTestManager struct {
	ctx       context.Context
	ctxErr    error
	deadline  time.Time
	hasExpiry bool
	status    *protocol.Status
	err       error
}

func (m *cleanupContextTestManager) Down(ctx context.Context) (*protocol.Status, error) {
	m.ctx = ctx
	m.ctxErr = ctx.Err()
	m.deadline, m.hasExpiry = ctx.Deadline()
	if m.status != nil {
		return m.status, m.err
	}
	return &protocol.Status{Stage: protocol.StageDisconnected}, m.err
}

type shutdownSequenceTestManager struct {
	upStarted  chan struct{}
	upCanceled chan struct{}
	downCalled chan struct{}
}

func (m *shutdownSequenceTestManager) Up(ctx context.Context, _ string) (*protocol.Status, error) {
	close(m.upStarted)
	<-ctx.Done()
	close(m.upCanceled)
	return nil, ctx.Err()
}

func (m *shutdownSequenceTestManager) Down(context.Context) (*protocol.Status, error) {
	select {
	case <-m.upCanceled:
		close(m.downCalled)
		return &protocol.Status{Stage: protocol.StageDisconnected}, nil
	default:
		return nil, errors.New("Manager.Down ran before the active handler finished")
	}
}

func (m *shutdownSequenceTestManager) Status(context.Context) (*protocol.Status, error) {
	return &protocol.Status{Stage: protocol.StageDisconnected}, nil
}

func TestCleanupTunnelUsesFreshBoundedContext(t *testing.T) {
	manager := &cleanupContextTestManager{}
	if err := cleanupTunnel(manager); err != nil {
		t.Fatalf("cleanupTunnel() = %v", err)
	}
	if manager.ctx == nil {
		t.Fatal("cleanupTunnel did not call Manager.Down")
	}
	if manager.ctxErr != nil {
		t.Fatalf("cleanup context is already canceled: %v", manager.ctxErr)
	}
	if !manager.hasExpiry {
		t.Fatal("cleanup context has no deadline")
	}
	remaining := time.Until(manager.deadline)
	if remaining <= 0 || remaining > tunnelCleanupTimeout {
		t.Fatalf("cleanup deadline = %s, want (0, %s]", remaining, tunnelCleanupTimeout)
	}
}

func TestCleanupTunnelReturnsManagerError(t *testing.T) {
	want := errors.New("teardown failed")
	err := cleanupTunnel(&cleanupContextTestManager{err: want})
	if !errors.Is(err, want) {
		t.Fatalf("cleanupTunnel() = %v, want wrapped %v", err, want)
	}
}

func TestCleanupTunnelRejectsLiveStatus(t *testing.T) {
	manager := &cleanupContextTestManager{status: &protocol.Status{
		Up:    true,
		Stage: protocol.StageConnected,
	}}
	if err := cleanupTunnel(manager); err == nil {
		t.Fatal("cleanupTunnel() = nil for a still-connected tunnel")
	}
}

func TestCleanupFromOptionsRequiresRoot(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("test requires a non-root invocation")
	}
	if err := cleanupFromOptions(options{}); err == nil {
		t.Fatal("cleanupFromOptions() = nil for a non-root invocation")
	}
}

func TestServeWithCleanupWaitsForHandlersBeforeDown(t *testing.T) {
	path := filepath.Join(t.TempDir(), "shutdown.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = listener.Close() }()

	manager := &shutdownSequenceTestManager{
		upStarted:  make(chan struct{}),
		upCanceled: make(chan struct{}),
		downCalled: make(chan struct{}),
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		done <- serveWithCleanup(ctx, manager, listener, slog.New(slog.NewTextHandler(io.Discard, nil)))
	}()

	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close() }()
	if _, err := conn.Write([]byte("{\"v\":1,\"id\":\"1\",\"op\":\"up\",\"config\":\"[Interface]\\nPrivateKey = x\\n\"}\n")); err != nil {
		t.Fatal(err)
	}
	select {
	case <-manager.upStarted:
	case <-time.After(time.Second):
		t.Fatal("active handler did not start")
	}

	cancel()
	select {
	case <-manager.upCanceled:
	case <-time.After(time.Second):
		t.Fatal("shutdown did not cancel the active handler")
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("serveWithCleanup() = %v, want clean shutdown", err)
		}
	case <-time.After(time.Second):
		t.Fatal("serveWithCleanup did not wait for shutdown cleanup")
	}
	select {
	case <-manager.downCalled:
	default:
		t.Fatal("Manager.Down was not called after the handler completed")
	}
}
