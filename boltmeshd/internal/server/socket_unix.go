//go:build linux

package server

import (
	"fmt"
	"net"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
)

// Listen binds the daemon's Unix socket. When systemd socket activation
// provides a pre-bound descriptor (LISTEN_FDS/LISTEN_PID), that listener is
// adopted and its permissions are systemd's responsibility (see the unit's
// SocketMode/SocketGroup). Otherwise the socket is created here and
// restricted to root:<group> 0660; an empty group falls back to root:root
// 0600.
func Listen(path, group string) (net.Listener, error) {
	if ln, ok, err := activationListener(); err != nil {
		return nil, err
	} else if ok {
		return ln, nil
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, fmt.Errorf("create socket dir: %w", err)
	}
	// Remove a stale socket left by an unclean exit; net.Listen fails on an
	// existing path.
	_ = os.Remove(path)
	ln, err := net.Listen("unix", path)
	if err != nil {
		return nil, fmt.Errorf("listen on %s: %w", path, err)
	}
	if err := restrictSocket(path, group); err != nil {
		_ = ln.Close()
		return nil, err
	}
	return ln, nil
}

func restrictSocket(path, group string) error {
	if group == "" {
		if err := os.Chmod(path, 0o600); err != nil {
			return fmt.Errorf("chmod socket: %w", err)
		}
		return nil
	}

	g, err := user.LookupGroup(group)
	if err != nil {
		return fmt.Errorf("socket group %q: %w", group, err)
	}
	gid, err := strconv.Atoi(g.Gid)
	if err != nil {
		return fmt.Errorf("socket group %q has non-numeric gid %q", group, g.Gid)
	}
	if err := os.Chown(path, 0, gid); err != nil {
		return fmt.Errorf("chown socket: %w", err)
	}
	if err := os.Chmod(path, 0o660); err != nil {
		return fmt.Errorf("chmod socket: %w", err)
	}
	return nil
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
