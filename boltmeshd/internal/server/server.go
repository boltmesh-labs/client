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
	"time"

	"boltmeshd/internal/protocol"
)

// maxRequestLine caps a single request line. It covers the largest config
// (config.MaxSize) plus JSON envelope overhead; anything larger is rejected
// without buffering it all.
const maxRequestLine = 128 * 1024

// requestTimeout bounds one privileged operation so a wedged wg-quick cannot
// hold a client forever. It is slightly longer than the tunnel command
// timeout so the daemon's own diagnostic wins the race.
const requestTimeout = 35 * time.Second

// Manager is the tunnel surface the server serves. *tunnel.Manager satisfies
// it; tests substitute a fake.
type Manager interface {
	Up(ctx context.Context, wgQuickConfig string) (*protocol.Status, error)
	Down(ctx context.Context) (*protocol.Status, error)
	Status() *protocol.Status
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

// Serve accepts connections until ctx is canceled or the listener fails.
func (s *Server) Serve(ctx context.Context, ln net.Listener) error {
	// Cancel must unblock Accept: closing the listener is what makes a
	// signal-triggered shutdown actually exit.
	stop := context.AfterFunc(ctx, func() { _ = ln.Close() })
	defer stop()

	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				// A canceled context is a clean shutdown, not a failure.
				return nil
			}
			return fmt.Errorf("accept: %w", err)
		}
		go s.handle(ctx, conn)
	}
}

func (s *Server) handle(ctx context.Context, conn net.Conn) {
	defer func() { _ = conn.Close() }()
	reader := bufio.NewReaderSize(conn, maxRequestLine)
	writer := bufio.NewWriter(conn)

	for {
		line, tooLarge, err := readLine(reader)
		if err != nil {
			return
		}
		if tooLarge {
			if err := writeResponse(writer, protocol.Fail("", protocol.CodeBadRequest, "request too large")); err != nil {
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
			if err := writeResponse(writer, protocol.Fail("", protocol.CodeBadRequest, "invalid JSON")); err != nil {
				return
			}
			continue
		}
		// Reject trailing tokens after the object so a line frames exactly one
		// request.
		if _, err := dec.Token(); !errors.Is(err, io.EOF) {
			if err := writeResponse(writer, protocol.Fail("", protocol.CodeBadRequest, "trailing data after request")); err != nil {
				return
			}
			continue
		}
		if err := writeResponse(writer, s.dispatch(ctx, &req)); err != nil {
			return
		}
	}
}

func (s *Server) dispatch(parent context.Context, req *protocol.Request) protocol.Response {
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

	ctx, cancel := context.WithTimeout(parent, requestTimeout)
	defer cancel()

	switch req.Op {
	case protocol.OpPing:
		// `ping` is the negotiation entry point: it carries the daemon's
		// capability tokens alongside the status.
		return protocol.OKCapabilities(id, s.manager.Status())
	case protocol.OpStatus:
		return protocol.OK(id, s.manager.Status())
	case protocol.OpUp:
		status, err := s.manager.Up(ctx, req.Config)
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
