//go:build linux

package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

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

// run binds the Unix socket and serves until a signal arrives. It is separate
// from main so signal cleanup (the deferred stop) runs before any os.Exit.
func run(opts options) error {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	listener, err := server.Listen(opts.socketPath, opts.socketGroup)
	if err != nil {
		return fmt.Errorf("bind socket: %w", err)
	}
	defer func() { _ = listener.Close() }()

	slog.Info("boltmeshd listening", "socket", opts.socketPath, "interface", opts.iface, "version", Version)

	return server.New(tunnel.NewManager(opts.configDir, opts.iface), slog.Default()).Serve(ctx, listener)
}
