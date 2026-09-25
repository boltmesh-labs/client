//go:build linux

package server

import (
	"fmt"
	"net"
	"os"
	"strconv"
)

// Listen binds the daemon's Unix socket. When systemd socket activation
// provides a pre-bound descriptor (LISTEN_FDS/LISTEN_PID), that listener is
// adopted and its permissions are systemd's responsibility (see the unit's
// SocketMode/SocketGroup). Otherwise the socket is created and restricted by
// [bindSocket].
func Listen(path, group string) (net.Listener, error) {
	if ln, ok, err := activationListener(); err != nil {
		return nil, err
	} else if ok {
		return ln, nil
	}
	return bindSocket(path, group)
}

// activationListener returns systemd's pre-bound socket from fd 3 when this
// process was started by socket activation.
func activationListener() (net.Listener, bool, error) {
	if os.Getenv("LISTEN_FDS") != "1" {
		return nil, false, nil
	}
	if pid := os.Getenv("LISTEN_PID"); pid != "" && pid != strconv.Itoa(os.Getpid()) {
		return nil, false, nil
	}
	file := os.NewFile(uintptr(3), "boltmeshd.socket")
	ln, err := net.FileListener(file)
	_ = file.Close()
	if err != nil {
		return nil, false, fmt.Errorf("adopt activation socket: %w", err)
	}
	return ln, true, nil
}
