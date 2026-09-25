//go:build linux || darwin

package server

import (
	"fmt"
	"net"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
)

// bindSocket creates and restricts the daemon's Unix socket, returning a
// ready listener.
//
// It is split from Listen so each platform can offer its own activation
// strategy first: Linux may adopt a systemd-provided descriptor, while macOS
// (launchd, no equivalent in the job definition) always binds here.
//
// The socket is restricted to root:<group> 0660; an empty group falls back to
// root:root 0600.
func bindSocket(path, group string) (net.Listener, error) {
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
