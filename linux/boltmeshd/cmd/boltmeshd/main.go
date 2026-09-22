// Command boltmeshd is the privileged Linux helper for the BoltMesh client.
//
// It owns the WireGuard interface lifecycle and all device reads, exposing
// them to the unprivileged Flutter app over a Unix socket. The app therefore
// never runs sudo, wg, or wg-quick, and never touches a privileged interface.
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"boltmeshd/internal/server"
	"boltmeshd/internal/tunnel"
)

// Build metadata, injected via -ldflags by the Makefile.
var (
	Version   = "dev"
	GitCommit = "unknown"
	BuildTime = "unknown"
)

func getEnv(key, fallback string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return fallback
}

func configureLogging() {
	level := slog.LevelInfo
	if err := level.UnmarshalText([]byte(getEnv("LOG_LEVEL", "INFO"))); err != nil {
		level = slog.LevelInfo
	}
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: level})))
}

func main() {
	fs := flag.NewFlagSet("boltmeshd", flag.ExitOnError)
	socketPath := fs.String("socket", getEnv("BOLTMESHD_SOCKET", "/run/boltmesh/boltmeshd.sock"), "Unix socket path")
	iface := fs.String("interface", getEnv("BOLTMESHD_INTERFACE", tunnel.DefaultInterface), "WireGuard interface name")
	configDir := fs.String("config-dir", getEnv("BOLTMESHD_CONFIG_DIR", tunnel.DefaultConfigDir), "Directory for the root-only wg-quick config")
	socketGroup := fs.String("socket-group", getEnv("BOLTMESHD_SOCKET_GROUP", "boltmesh"), "Group granted access to the socket (empty = root only)")
	showVersion := fs.Bool("version", false, "Print version and exit")
	_ = fs.Parse(os.Args[1:])

	configureLogging()

	if *showVersion {
		fmt.Printf("boltmeshd %s (%s, built %s)\n", Version, GitCommit, BuildTime)
		return
	}

	if err := run(*socketPath, *iface, *configDir, *socketGroup); err != nil {
		slog.Error("boltmeshd stopped", "error", err)
		os.Exit(1)
	}
}

// run binds the socket and serves until a signal arrives. It is separate from
// main so signal cleanup (the deferred stop) runs before any os.Exit.
func run(socketPath, iface, configDir, socketGroup string) error {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	listener, err := server.Listen(socketPath, socketGroup)
	if err != nil {
		return fmt.Errorf("bind socket: %w", err)
	}
	defer func() { _ = listener.Close() }()

	slog.Info("boltmeshd listening", "socket", socketPath, "interface", iface, "version", Version)

	return server.New(tunnel.NewManager(configDir, iface), slog.Default()).Serve(ctx, listener)
}
