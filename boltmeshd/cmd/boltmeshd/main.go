// Command boltmeshd is the privileged helper for the BoltMesh client.
//
// It owns the WireGuard interface lifecycle and all privileged reads, and
// exposes them to the unprivileged Flutter app over a local transport: a Unix
// socket on Linux (`wg-quick` + `wgctrl`), a named pipe on Windows (the
// WireGuard-for-Windows tunnel service + `wireguard.dll`). The app therefore
// never runs sudo, wg, wg-quick, or an elevated GUI.
package main

import (
	"flag"
	"fmt"
	"log/slog"
	"os"

	"boltmeshd/internal/tunnel"
)

// Build metadata, injected via -ldflags by the Makefile.
var (
	Version   = "dev"
	GitCommit = "unknown"
	BuildTime = "unknown"
)

// options holds the parsed command line. Only the fields relevant to the
// running OS have an effect; the rest keep the shared parser simple.
type options struct {
	socketPath  string
	socketGroup string
	pipeName    string
	iface       string
	configDir   string
	console     bool
	install     bool
	uninstall   bool
	showVersion bool
}

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
	opts := options{}
	fs.StringVar(&opts.socketPath, "socket", getEnv("BOLTMESHD_SOCKET", defaultSocketPath()), "Unix socket path (Linux)")
	fs.StringVar(&opts.socketGroup, "socket-group", getEnv("BOLTMESHD_SOCKET_GROUP", defaultSocketGroup()), "Group granted access to the socket (Linux; empty = root only)")
	fs.StringVar(&opts.pipeName, "pipe", getEnv("BOLTMESHD_PIPE", defaultPipeName()), "Named pipe path (Windows)")
	fs.StringVar(&opts.iface, "interface", getEnv("BOLTMESHD_INTERFACE", tunnel.DefaultInterface), "WireGuard interface name")
	fs.StringVar(&opts.configDir, "config-dir", getEnv("BOLTMESHD_CONFIG_DIR", tunnel.DefaultConfigDir), "Directory for the privileged wg-quick config")
	fs.BoolVar(&opts.console, "console", false, "Run in the foreground instead of as a service (Windows)")
	fs.BoolVar(&opts.install, "install", false, "Install and start the boltmeshd service, then exit (Windows)")
	fs.BoolVar(&opts.uninstall, "uninstall", false, "Stop and remove the boltmeshd service, then exit (Windows)")
	fs.BoolVar(&opts.showVersion, "version", false, "Print version and exit")
	_ = fs.Parse(os.Args[1:])

	configureLogging()

	if opts.showVersion {
		fmt.Printf("boltmeshd %s (%s, built %s)\n", Version, GitCommit, BuildTime)
		return
	}

	if err := run(opts); err != nil {
		slog.Error("boltmeshd stopped", "error", err)
		os.Exit(1)
	}
}
