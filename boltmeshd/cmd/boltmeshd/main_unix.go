//go:build linux

package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"boltmeshd/internal/protocol"
	"boltmeshd/internal/server"
	"boltmeshd/internal/tunnel"
)

func defaultSocketPath() string  { return "/run/boltmesh/boltmeshd.sock" }
func defaultSocketGroup() string { return "boltmesh" }
func defaultPipeName() string    { return "" }

// defaultLogFile is where failures are persisted. The systemd unit owns the
// directory via LogsDirectory=boltmesh; this path is what it creates.
func defaultLogFile() string { return "/var/log/boltmesh/boltmeshd.log" }

// prepareLogFile ensures the log directory exists so [logging.Setup] can open
// the file (systemd already creates it; this covers a manual/dev launch).
// Permission hardening is the unit's LogsDirectoryMode plus the process umask.
func prepareLogFile(path string) error {
	if path == "" {
		return nil
	}
	return os.MkdirAll(filepath.Dir(path), 0o750)
}

// prepareFilesystem is a no-op on Unix. The Windows implementation hardens
// the machine-wide config directory before any privileged file operation.
func prepareFilesystem(_ options) error { return nil }

// tunnelCleanupTimeout is a little longer than the tunnel manager's command
// budget. The extra margin covers scheduling and the final device read while
// still keeping a stuck cleanup from outliving the systemd stop operation.
const tunnelCleanupTimeout = 35 * time.Second

// tunnelDowner is the part of tunnel.Manager needed by the shutdown path.
// Keeping the seam small makes it possible to test that shutdown uses a fresh
// context and does not accidentally reuse the already-canceled signal context.
type tunnelDowner interface {
	Down(context.Context) (*protocol.Status, error)
}

// cleanupTunnel tears down the interface, routes, and resolver state. It uses
// a fresh context deliberately: the daemon's signal context is canceled before
// Serve returns, while this safety-critical cleanup must still be allowed to
// finish. Manager.Down applies its own command bound; the outer timeout keeps
// the direct command-line and service-stop paths bounded as well. The returned
// status is checked so a successful command cannot hide a still-live interface.
func cleanupTunnel(manager tunnelDowner) error {
	ctx, cancel := context.WithTimeout(context.Background(), tunnelCleanupTimeout)
	defer cancel()
	status, err := manager.Down(ctx)
	if err != nil {
		return fmt.Errorf("tunnel cleanup: %w", err)
	}
	if status == nil {
		return errors.New("tunnel cleanup: manager returned no status")
	}
	if status.Up {
		return errors.New("tunnel cleanup: interface remains up")
	}
	if status.Stage != protocol.StageDisconnected {
		return fmt.Errorf("tunnel cleanup: tunnel remains in stage %q", status.Stage)
	}
	return nil
}

// cleanupFromOptions is used by systemd and package maintainer scripts, not by
// the socket protocol. Keep the direct command-line path root-only so adding a
// cleanup retry does not give every local user a new tunnel-shutdown DoS.
func cleanupFromOptions(opts options) error {
	if os.Geteuid() != 0 {
		return errors.New("tunnel cleanup requires root")
	}
	configDir := opts.configDir
	if configDir == "" {
		configDir = tunnel.DefaultConfigDir
	}
	iface := opts.iface
	if iface == "" {
		iface = tunnel.DefaultInterface
	}
	return cleanupTunnel(tunnel.NewManager(configDir, iface))
}

// serveWithCleanup keeps the server's handler barrier and the tunnel teardown
// in one testable sequence. In particular, Down must not run until Serve has
// canceled and joined all active request handlers.
func serveWithCleanup(ctx context.Context, manager server.Manager, listener net.Listener, log *slog.Logger) (err error) {
	defer func() {
		if cleanupErr := cleanupTunnel(manager); cleanupErr != nil {
			log.Error("tunnel shutdown cleanup failed", "error", cleanupErr)
			err = errors.Join(err, cleanupErr)
		}
	}()
	return server.New(manager, log).Serve(ctx, listener)
}

// run binds the Unix socket and serves until a signal arrives. It is separate
// from main so serveWithCleanup's tunnel teardown runs before any os.Exit. The
// teardown is deliberately after Serve has returned: Serve first cancels active
// handlers and waits for them, so a shutdown cannot race an in-flight up/down
// operation.
func run(opts options) error {
	if opts.cleanup {
		return cleanupFromOptions(opts)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	listener, err := server.Listen(opts.socketPath, opts.socketGroup)
	if err != nil {
		return fmt.Errorf("bind socket: %w", err)
	}
	defer func() { _ = listener.Close() }()

	manager := tunnel.NewManager(opts.configDir, opts.iface)
	slog.Info("boltmeshd listening", "socket", opts.socketPath, "interface", opts.iface, "version", Version)

	return serveWithCleanup(ctx, manager, listener, slog.Default())
}
