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

	"boltmeshd/internal/logging"
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
	logFile     string
	console     bool
	install     bool
	uninstall   bool
	showVersion bool
}

// getEnv returns an explicitly configured environment value, including an
// empty value. The fallback applies only when the variable is unset.
func getEnv(key, fallback string) string {
	if val, ok := os.LookupEnv(key); ok {
		return val
	}
	return fallback
}

// configureLogging installs the daemon logger: human-readable records on
// stdout (journald/dev) plus a durable JSON-lines file that persists failures
// across restarts. A log target that cannot be prepared or opened degrades to
// stdout-only instead of taking the daemon down.
func configureLogging(opts options) {
	level := slog.LevelInfo
	if err := level.UnmarshalText([]byte(getEnv("LOG_LEVEL", "INFO"))); err != nil {
		level = slog.LevelInfo
	}

	logFile := opts.logFile
	prepErr := prepareLogFile(logFile)
	if prepErr != nil {
		logFile = ""
	}

	logger, closer, setupErr := logging.Setup(logging.Options{
		ConsoleLevel: level,
		FilePath:     logFile,
	})
	slog.SetDefault(logger)
	// Writes are synchronous; the OS reclaims the descriptor at exit.
	_ = closer

	switch {
	case prepErr != nil:
		slog.Warn("file logging disabled", "path", opts.logFile, "error", prepErr)
	case setupErr != nil:
		slog.Warn("file logging disabled", "path", logFile, "error", setupErr)
	}
}

func main() {
	fs := flag.NewFlagSet("boltmeshd", flag.ExitOnError)
	opts := options{}
	fs.StringVar(&opts.socketPath, "socket", getEnv("BOLTMESHD_SOCKET", defaultSocketPath()), "Unix socket path (Linux)")
	fs.StringVar(&opts.socketGroup, "socket-group", getEnv("BOLTMESHD_SOCKET_GROUP", defaultSocketGroup()), "Group granted access to the socket (Linux; empty = root only)")
	fs.StringVar(&opts.pipeName, "pipe", getEnv("BOLTMESHD_PIPE", defaultPipeName()), "Named pipe path (Windows)")
	fs.StringVar(&opts.iface, "interface", getEnv("BOLTMESHD_INTERFACE", tunnel.DefaultInterface), "WireGuard interface name")
	fs.StringVar(&opts.configDir, "config-dir", getEnv("BOLTMESHD_CONFIG_DIR", tunnel.DefaultConfigDir), "Directory for the privileged wg-quick config")
	fs.StringVar(&opts.logFile, "log-file", getEnv("BOLTMESHD_LOG_FILE", defaultLogFile()), "Persistent JSON-lines failure log (empty disables file logging)")
	fs.BoolVar(&opts.console, "console", false, "Run in the foreground instead of as a service (Windows)")
	fs.BoolVar(&opts.install, "install", false, "Install and start the boltmeshd service, then exit (Windows)")
	fs.BoolVar(&opts.uninstall, "uninstall", false, "Stop and remove the BoltMesh helper and tunnel services, then exit (Windows)")
	fs.BoolVar(&opts.showVersion, "version", false, "Print version and exit")
	_ = fs.Parse(os.Args[1:])

	if opts.showVersion {
		fmt.Printf("boltmeshd %s (%s, built %s)\n", Version, GitCommit, BuildTime)
		return
	}

	// Configured after the version short-circuit so `--version` touches no
	// filesystem state. On Windows this also hardens the config directory
	// before the installer or service can open any file beneath it.
	if err := prepareFilesystem(opts); err != nil {
		fmt.Fprintf(os.Stderr, "boltmeshd: secure filesystem paths: %v\n", err)
		os.Exit(1)
	}
	configureLogging(opts)

	if err := run(opts); err != nil {
		slog.Error("boltmeshd stopped", "error", err)
		os.Exit(1)
	}
}
