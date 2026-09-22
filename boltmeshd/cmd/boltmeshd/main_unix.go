//go:build linux

package main

import (
	"context"
	"fmt"
	"log/slog"
	"os/signal"
	"syscall"

	"boltmeshd/internal/server"
	"boltmeshd/internal/tunnel"
)

func defaultSocketPath() string  { return "/run/boltmesh/boltmeshd.sock" }
func defaultSocketGroup() string { return "boltmesh" }
func defaultPipeName() string    { return "" }

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
