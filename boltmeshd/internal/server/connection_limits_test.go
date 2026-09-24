package server

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"sync"
	"testing"
	"time"

	"boltmeshd/internal/protocol"
)

type limitTestManager struct{}

func (limitTestManager) Up(context.Context, string) (*protocol.Status, error) {
	return &protocol.Status{}, nil
}

func (limitTestManager) Down(context.Context) (*protocol.Status, error) {
	return &protocol.Status{}, nil
}

func (limitTestManager) Status() *protocol.Status { return &protocol.Status{} }

type boundedTestListener struct {
	conns    chan net.Conn
	accepted chan struct{}
	closed   chan struct{}
	once     sync.Once
}

func newBoundedTestListener() *boundedTestListener {
	return &boundedTestListener{
		conns:    make(chan net.Conn, maxConcurrentConnections+1),
		accepted: make(chan struct{}, maxConcurrentConnections+1),
		closed:   make(chan struct{}),
	}
}

func (l *boundedTestListener) Accept() (net.Conn, error) {
	select {
	case conn := <-l.conns:
		l.accepted <- struct{}{}
		return conn, nil
	case <-l.closed:
		return nil, net.ErrClosed
	}
}

func (l *boundedTestListener) Close() error {
	l.once.Do(func() { close(l.closed) })
	return nil
}

func (l *boundedTestListener) Addr() net.Addr { return boundedTestAddr{} }

func (l *boundedTestListener) add(conn net.Conn) bool {
	select {
	case l.conns <- conn:
		return true
	case <-l.closed:
		return false
	}
}

type boundedTestAddr struct{}

func (boundedTestAddr) Network() string { return "test-pipe" }
func (boundedTestAddr) String() string  { return "test-pipe" }

type deadlineTrackingConn struct {
	net.Conn
	readDeadlines  chan time.Time
	writeDeadlines chan time.Time
}

func newDeadlineTrackingConn(conn net.Conn) *deadlineTrackingConn {
	return &deadlineTrackingConn{
		Conn:           conn,
		readDeadlines:  make(chan time.Time, 8),
		writeDeadlines: make(chan time.Time, 8),
	}
}

func (c *deadlineTrackingConn) SetReadDeadline(deadline time.Time) error {
	c.readDeadlines <- deadline
	return c.Conn.SetReadDeadline(deadline)
}

func (c *deadlineTrackingConn) SetWriteDeadline(deadline time.Time) error {
	c.writeDeadlines <- deadline
	return c.Conn.SetWriteDeadline(deadline)
}

func waitForDeadline(t *testing.T, deadlines <-chan time.Time) time.Time {
	t.Helper()
	select {
	case deadline := <-deadlines:
		return deadline
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for a connection deadline")
		return time.Time{}
	}
}

func assertFutureDeadline(t *testing.T, deadline time.Time, max time.Duration) {
	t.Helper()
	if deadline.IsZero() {
		t.Fatal("connection deadline is zero")
	}
	remaining := time.Until(deadline)
	if remaining <= 0 || remaining > max+time.Second {
		t.Fatalf("connection deadline = %s from now, want at most %s", remaining, max)
	}
}

func waitForAccepts(t *testing.T, accepted <-chan struct{}, count int) {
	t.Helper()
	timer := time.NewTimer(2 * time.Second)
	defer timer.Stop()
	for i := 0; i < count; i++ {
		select {
		case <-accepted:
		case <-timer.C:
			t.Fatalf("timed out waiting for accept %d/%d", i+1, count)
		}
	}
}

func TestHandleSetsIdleReadAndResponseWriteDeadlines(t *testing.T) {
	t.Run("idle read", func(t *testing.T) {
		client, server := net.Pipe()
		tracked := newDeadlineTrackingConn(server)
		ctx, cancel := context.WithCancel(context.Background())
		t.Cleanup(func() {
			cancel()
			_ = client.Close()
			_ = server.Close()
		})
		done := make(chan struct{})
		go func() {
			New(limitTestManager{}, slog.New(slog.NewTextHandler(io.Discard, nil))).handle(ctx, tracked)
			close(done)
		}()

		assertFutureDeadline(t, waitForDeadline(t, tracked.readDeadlines), connectionIdleTimeout)
		cancel()
		_ = client.Close()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("handle did not stop after context cancellation")
		}
	})

	t.Run("response write", func(t *testing.T) {
		client, server := net.Pipe()
		tracked := newDeadlineTrackingConn(server)
		ctx, cancel := context.WithCancel(context.Background())
		t.Cleanup(func() {
			cancel()
			_ = client.Close()
			_ = server.Close()
		})
		done := make(chan struct{})
		go func() {
			New(limitTestManager{}, slog.New(slog.NewTextHandler(io.Discard, nil))).handle(ctx, tracked)
			close(done)
		}()

		exchangeDone := make(chan error, 1)
		go func() {
			if _, err := client.Write([]byte(`{"v":1,"id":"1","op":"ping"}` + "\n")); err != nil {
				exchangeDone <- err
				return
			}
			_, err := client.Read(make([]byte, 1024))
			exchangeDone <- err
		}()

		assertFutureDeadline(t, waitForDeadline(t, tracked.writeDeadlines), responseWriteTimeout)
		select {
		case err := <-exchangeDone:
			if err != nil {
				t.Fatal(err)
			}
		case <-time.After(time.Second):
			t.Fatal("ping exchange did not complete")
		}
		cancel()
		_ = client.Close()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("handle did not stop after context cancellation")
		}
	})
}

func TestServeCapsConcurrentConnections(t *testing.T) {
	ln := newBoundedTestListener()
	ctx, cancel := context.WithCancel(context.Background())
	served := make(chan error, 1)
	go func() {
		served <- New(limitTestManager{}, slog.New(slog.NewTextHandler(io.Discard, nil))).Serve(ctx, ln)
	}()

	clients := make([]net.Conn, 0, maxConcurrentConnections+1)
	servers := make([]net.Conn, 0, maxConcurrentConnections+1)
	addPair := func() net.Conn {
		t.Helper()
		client, server := net.Pipe()
		if !ln.add(server) {
			_ = client.Close()
			_ = server.Close()
			t.Fatal("listener closed while adding a test connection")
		}
		clients = append(clients, client)
		servers = append(servers, server)
		return client
	}

	t.Cleanup(func() {
		cancel()
		_ = ln.Close()
		for _, conn := range clients {
			_ = conn.Close()
		}
		for _, conn := range servers {
			_ = conn.Close()
		}
		select {
		case err := <-served:
			if err != nil {
				t.Errorf("Serve() = %v, want clean shutdown", err)
			}
		case <-time.After(time.Second):
			t.Error("Serve did not stop")
		}
	})

	for i := 0; i < maxConcurrentConnections; i++ {
		addPair()
		waitForAccepts(t, ln.accepted, 1)
	}

	extra := addPair()
	waitForAccepts(t, ln.accepted, 1)
	if err := extra.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		if errors.Is(err, io.ErrClosedPipe) || errors.Is(err, net.ErrClosed) {
			return
		}
		t.Fatal(err)
	}
	if _, err := extra.Read(make([]byte, 1)); err == nil {
		t.Fatal("connection over the limit remained open")
	} else {
		var netErr net.Error
		if errors.As(err, &netErr) && netErr.Timeout() {
			t.Fatal("connection over the limit was not closed before its read deadline")
		}
	}
}
