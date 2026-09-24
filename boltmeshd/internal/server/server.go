// Package server exposes the privileged tunnel surface over a Unix socket.
// It frames newline-delimited JSON, maps operational errors onto protocol
// error codes, and never blocks the listener on one slow operation.
package server

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"sync"
	"time"

	"boltmeshd/internal/protocol"
)

// maxRequestLine caps a single request line. It covers the largest config
// (config.MaxSize) plus JSON envelope overhead; anything larger is rejected
// without buffering it all.
const maxRequestLine = 128 * 1024

// requestTimeout is the daemon-side budget for one complete privileged
// operation, including bounded failure cleanup. It is longer than the Linux
// command budget and shorter than HelperClient.defaultCallTimeout, so the
// daemon normally produces a response before the client's transport backstop.
// The bounded request context is tied to the transport: expiration or a
// shorter client budget closes the connection and cancels the operation.
const requestTimeout = 40 * time.Second

// connectionIdleTimeout prevents a peer that opens a socket and never sends
// a newline from retaining a handler forever. It is intentionally longer than
// a request so a client can finish writing a large, valid config.
const connectionIdleTimeout = requestTimeout + 5*time.Second

// responseWriteTimeout prevents a client that stops reading from pinning a
// handler after the privileged operation has completed.
const responseWriteTimeout = 5 * time.Second

// maxConcurrentConnections bounds the resources retained by peers that open a
// connection and then stop making progress. A local client only needs a few
// concurrent exchanges; excess connections are closed as soon as they are
// accepted rather than queued behind the limit.
const maxConcurrentConnections = 32

// Manager is the tunnel surface the server serves. *tunnel.Manager satisfies
// it; tests substitute a fake.
type Manager interface {
	Up(ctx context.Context, wgQuickConfig string) (*protocol.Status, error)
	Down(ctx context.Context) (*protocol.Status, error)
	Status(ctx context.Context) (*protocol.Status, error)
}

// Server serves [Manager] over one or more connections.
type Server struct {
	manager Manager
	log     *slog.Logger
}

// New returns a Server for manager, logging operational failures to log.
func New(manager Manager, log *slog.Logger) *Server {
	return &Server{manager: manager, log: log}
}

// Serve accepts connections until ctx is canceled or the listener fails. It
// keeps at most maxConcurrentConnections active; excess connections are
// closed rather than queued.
func (s *Server) Serve(ctx context.Context, ln net.Listener) error {
	serveCtx, cancel := context.WithCancel(ctx)
	// Cancel must unblock Accept: closing the listener is what makes a
	// signal-triggered shutdown actually exit. The same context is canceled
	// for an unexpected listener failure so active privileged handlers unwind
	// before Serve returns.
	stop := context.AfterFunc(serveCtx, func() { _ = ln.Close() })
	var handlers sync.WaitGroup
	// A connection is assigned a slot before its handler is started. This
	// keeps both the handler and the request-reading goroutine bounded; an
	// idle peer cannot consume one goroutine per accepted socket indefinitely.
	slots := make(chan struct{}, maxConcurrentConnections)
	defer func() {
		cancel()
		stop()
		handlers.Wait()
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			if serveCtx.Err() != nil {
				// A canceled context is a clean shutdown, not a failure.
				return nil
			}
			return fmt.Errorf("accept: %w", err)
		}
		select {
		case slots <- struct{}{}:
		default:
			// Do not wait for a slot: a peer that opens more connections
			// than the limit is rejected without retaining its file
			// descriptor or named-pipe instance.
			_ = conn.Close()
			continue
		}
		handlers.Add(1)
		go func(conn net.Conn) {
			defer handlers.Done()
			defer func() { <-slots }()
			s.handle(serveCtx, conn)
		}(conn)
	}
}

func (s *Server) handle(parent context.Context, conn net.Conn) {
	// A client uses one connection for the request and closes it when its
	// deadline expires. Tie the request context to that connection so a
	// caller giving up also cancels the privileged operation.
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	defer func() { _ = conn.Close() }()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()

	reader := bufio.NewReaderSize(conn, maxRequestLine)
	writer := bufio.NewWriter(conn)

	for {
		if err := conn.SetReadDeadline(time.Now().Add(connectionIdleTimeout)); err != nil {
			return
		}
		line, tooLarge, err := readLine(reader)
		if errReset := conn.SetReadDeadline(time.Time{}); errReset != nil {
			return
		}
		if err != nil {
			return
		}
		if tooLarge {
			if err := writeBoundedResponse(conn, writer, protocol.Fail("", protocol.CodeBadRequest, "request too large")); err != nil {
				return
			}
			continue
		}
		line = bytes.TrimSpace(line)
		if len(line) == 0 {
			continue
		}

		var req protocol.Request
		dec := json.NewDecoder(bytes.NewReader(line))
		// Reject fields the daemon does not know: both sides ship together,
		// and an unknown field is far more likely a bug or a probe than a
		// forward-compatible extension.
		dec.DisallowUnknownFields()
		if err := dec.Decode(&req); err != nil {
			if err := writeBoundedResponse(conn, writer, protocol.Fail("", protocol.CodeBadRequest, "invalid JSON")); err != nil {
				return
			}
			continue
		}
		// Reject trailing tokens after the object so a line frames exactly one
		// request.
		if _, err := dec.Token(); !errors.Is(err, io.EOF) {
			if err := writeBoundedResponse(conn, writer, protocol.Fail("", protocol.CodeBadRequest, "trailing data after request")); err != nil {
				return
			}
			continue
		}
		if err := s.serveRequest(ctx, cancel, conn, reader, writer, &req); err != nil {
			return
		}
	}
}

// serveRequest dispatches one parsed request while watching the transport for
// an early client disconnect. The watcher is joined before this method
// returns so a closed connection cannot leave a read-ahead goroutine behind.
func (s *Server) serveRequest(
	ctx context.Context,
	cancel context.CancelFunc,
	conn net.Conn,
	reader *bufio.Reader,
	writer *bufio.Writer,
	req *protocol.Request,
) error {
	// Peek at the next byte while the operation runs. A read EOF is the
	// transport's cancellation signal; waiting for the next request in a
	// separate goroutine lets a closed client cancel ctx even though the
	// normal read loop is busy dispatching this request.
	if err := conn.SetReadDeadline(time.Now().Add(connectionIdleTimeout)); err != nil {
		return err
	}
	peekDone := make(chan error, 1)
	peekPending := true
	defer func() {
		if !peekPending {
			return
		}
		// Every early return must join the read-ahead goroutine before
		// releasing the connection slot. Closing the transport is what
		// wakes a blocked Peek on a client that went away.
		cancel()
		_ = conn.Close()
		<-peekDone
	}()
	go func() {
		_, err := reader.Peek(1)
		if errors.Is(err, bufio.ErrBufferFull) {
			// The next request is already buffered; this is not a
			// disconnect. The normal read loop can consume it after the
			// current response.
			err = nil
		} else if err != nil {
			cancel()
		}
		peekDone <- err
	}()

	if err := ctx.Err(); err != nil {
		return err
	}
	// The request budget belongs to the connection lifecycle, not just the
	// manager call. If the deadline expires (or the parent is canceled), the
	// callback closes the transport and prevents the handler from continuing
	// with a reusable connection.
	requestCtx, requestCancel := context.WithTimeout(ctx, requestTimeout)
	stopRequestClose := context.AfterFunc(requestCtx, cancel)
	resp := s.dispatch(requestCtx, req)
	// Stop the close callback before canceling the child on the normal path;
	// otherwise canceling the completed request would close a healthy
	// connection before its response is written.
	stopRequestClose()
	requestErr := requestCtx.Err()
	requestCancel()
	if requestErr != nil {
		return requestErr
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := writeBoundedResponse(conn, writer, resp); err != nil {
		return err
	}
	peekErr := <-peekDone
	peekPending = false
	if peekErr != nil {
		return peekErr
	}
	return conn.SetReadDeadline(time.Time{})
}

// dispatch executes one request using the bounded context prepared by
// serveRequest.
func (s *Server) dispatch(ctx context.Context, req *protocol.Request) protocol.Response {
	// Never echo an ID we would reject: a malformed or oversized ID is not
	// correlation data, and reflecting it is needless attacker-controlled
	// output.
	id := req.ID
	if !protocol.ValidID(id) {
		id = ""
	}

	if req.V != protocol.Version {
		return protocol.Fail(id, protocol.CodeBadRequest,
			fmt.Sprintf("unsupported protocol version %d", req.V))
	}
	if err := req.Validate(); err != nil {
		return protocol.Fail(id, protocol.CodeBadRequest, err.Error())
	}

	switch req.Op {
	case protocol.OpPing, protocol.OpStatus:
		status, err := s.manager.Status(ctx)
		if err != nil {
			return s.failure(id, req.Op, err)
		}
		if req.Op == protocol.OpPing {
			// `ping` is the negotiation entry point: it carries the daemon's
			// capability tokens alongside the status.
			return protocol.OKCapabilities(id, status)
		}
		return protocol.OK(id, status)
	case protocol.OpUp:
		status, err := s.manager.Up(ctx, *req.Config)
		if err != nil {
			return s.failure(id, "up", err)
		}
		return protocol.OK(id, status)
	case protocol.OpDown:
		status, err := s.manager.Down(ctx)
		if err != nil {
			return s.failure(id, "down", err)
		}
		return protocol.OK(id, status)
	default:
		// Validate already rejects unknown ops; kept for exhaustiveness.
		return protocol.Fail(id, protocol.CodeBadRequest, fmt.Sprintf("unsupported op %q", req.Op))
	}
}

func (s *Server) failure(id, op string, err error) protocol.Response {
	code := protocol.CodeInternal
	var opErr *protocol.OpError
	if errors.As(err, &opErr) {
		code = opErr.Code
	}
	s.log.Warn("tunnel operation failed", "op", op, "code", code, "error", err)
	return protocol.Fail(id, code, err.Error())
}

// readLine reads one newline-terminated line. It reports tooLarge (and
// discards the remainder to preserve framing) instead of buffering an
// unbounded request.
func readLine(reader *bufio.Reader) (line []byte, tooLarge bool, err error) {
	for {
		chunk, readErr := reader.ReadSlice('\n')
		if !tooLarge {
			line = append(line, chunk...)
			if len(line) > maxRequestLine {
				tooLarge = true
				line = nil
			}
		}
		switch {
		case readErr == nil:
			return line, tooLarge, nil
		case errors.Is(readErr, bufio.ErrBufferFull):
			continue
		default:
			return nil, false, readErr
		}
	}
}

func writeBoundedResponse(conn net.Conn, writer *bufio.Writer, resp protocol.Response) (err error) {
	if err = conn.SetWriteDeadline(time.Now().Add(responseWriteTimeout)); err != nil {
		return err
	}
	defer func() {
		if resetErr := conn.SetWriteDeadline(time.Time{}); err == nil {
			err = resetErr
		}
	}()
	return writeResponse(writer, resp)
}

func writeResponse(writer *bufio.Writer, resp protocol.Response) error {
	data, err := json.Marshal(resp)
	if err != nil {
		return err
	}
	if _, err := writer.Write(append(data, '\n')); err != nil {
		return err
	}
	return writer.Flush()
}
