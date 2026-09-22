//go:build windows

package server

import (
	"fmt"
	"net"

	"github.com/Microsoft/go-winio"
)

// pipeSDDL is the discretionary ACL applied to the daemon's pipe. Full
// control goes to SYSTEM (the daemon's own account) and the built-in
// Administrators, and read/write to Interactive Users. This is the closest
// Windows analogue of the Linux `boltmesh` group: the app's user must be
// logged in, but the pipe is not world-writable.
const pipeSDDL = "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)"

// ListenPipe binds the daemon's named pipe. It returns a net.Listener so the
// shared newline-JSON framing in [Server.Serve] is reused verbatim; only the
// transport differs from the Linux Unix socket.
func ListenPipe(name string) (net.Listener, error) {
	ln, err := winio.ListenPipe(name, &winio.PipeConfig{
		SecurityDescriptor: pipeSDDL,
		InputBufferSize:    64 * 1024,
		OutputBufferSize:   64 * 1024,
	})
	if err != nil {
		return nil, fmt.Errorf("listen on %s: %w", name, err)
	}
	return ln, nil
}
