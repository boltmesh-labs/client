//go:build linux

package server

import (
	"net"
	"os"
	"path/filepath"
	"testing"
)

// Listen must reclaim the socket path after an unclean exit. A stale regular
// file (or dead UDS node) makes net.Listen fail, which would otherwise wedge
// every restart until an operator deletes it by hand.
func TestListenRemovesStalePath(t *testing.T) {
	t.Run("regular file", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "boltmeshd.sock")
		if err := os.WriteFile(path, []byte("stale"), 0o600); err != nil {
			t.Fatal(err)
		}

		ln, err := Listen(path, "")
		if err != nil {
			t.Fatalf("Listen(stale file) = %v", err)
		}
		t.Cleanup(func() { _ = ln.Close() })

		info, err := os.Stat(path)
		if err != nil {
			t.Fatalf("socket path missing after Listen: %v", err)
		}
		if info.Mode()&os.ModeSocket == 0 {
			t.Fatalf("path mode = %v, want a socket", info.Mode())
		}
	})

	t.Run("dead unix socket", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "boltmeshd.sock")
		// Bind then close without unlinking: the path survives as a dead
		// socket node, exactly what a killed daemon leaves behind.
		raw, err := net.Listen("unix", path)
		if err != nil {
			t.Fatalf("seed socket: %v", err)
		}
		if ul, ok := raw.(*net.UnixListener); ok {
			ul.SetUnlinkOnClose(false)
		}
		if err := raw.Close(); err != nil {
			t.Fatalf("close seed socket: %v", err)
		}
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("seed socket vanished early: %v", err)
		}

		ln, err := Listen(path, "")
		if err != nil {
			t.Fatalf("Listen(dead socket) = %v", err)
		}
		t.Cleanup(func() { _ = ln.Close() })

		conn, err := net.Dial("unix", path)
		if err != nil {
			t.Fatalf("dial rebound socket: %v", err)
		}
		_ = conn.Close()
	})
}
