//go:build darwin

package server

import "net"

// Listen binds the daemon's Unix socket.
//
// There is no socket activation on macOS: launchd has no equivalent of
// systemd's LISTEN_FDS, so the socket is always created here and restricted to
// root:<group> 0660 by [bindSocket] (an empty group falls back to root:root
// 0600). The LaunchDaemon runs as root, so the group is what limits access to
// the client.
func Listen(path, group string) (net.Listener, error) {
	return bindSocket(path, group)
}
