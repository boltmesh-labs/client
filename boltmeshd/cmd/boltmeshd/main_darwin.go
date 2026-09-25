//go:build darwin

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

// macOS paths. The daemon runs as root from a LaunchDaemon, so the config and
// the socket live in the same machine-wide, root-owned locations the Linux
// build uses. launchd has no LogsDirectory=, so the log directory is created
// here instead of being provided by the job definition.
const (
	darwinRuntimeDir = "/var/run/boltmesh"
	darwinLogDir     = "/var/log/boltmesh"
	darwinPlistDir   = "/Library/LaunchDaemons"
)

func defaultSocketPath() string  { return darwinRuntimeDir + "/boltmeshd.sock" }
func defaultSocketGroup() string { return "staff" }
func defaultPipeName() string    { return "" }

func defaultLogFile() string { return darwinLogDir + "/boltmeshd.log" }

// prepareLogFile creates the log directory so [logging.Setup] can open the
// file. The LaunchDaemon runs as root and the directory is root-owned 0750,
// matching the Linux unit's LogsDirectoryMode.
func prepareLogFile(path string) error {
	if path == "" {
		return nil
	}
	return os.MkdirAll(filepath.Dir(path), 0o750)
}

// prepareFilesystem creates the runtime directory holding the privileged
// config and the socket. Unlike Windows there is no pre-service window to
// close: the directory is created by the root-owned installer, and refusing to
// proceed if it is not already root-owned keeps a user-writable path from
// capturing the config.
func prepareFilesystem(opts options) error {
	if opts.cleanup {
		return nil
	}
	if err := ensureRootOwnedDir(opts.configDir); err != nil {
		return fmt.Errorf("secure config directory %q: %w", opts.configDir, err)
	}
	return nil
}

// ensureRootOwnedDir creates dir when absent and fails if it is present but
// not owned by root or writable by group/other. A user-writable config
// directory would let a standard account replace the wg-quick config the
// daemon later hands to a privileged reader.
func ensureRootOwnedDir(dir string) error {
	if dir == "" {
		return errors.New("config directory is empty")
	}
	info, err := os.Stat(dir)
	switch {
	case errors.Is(err, os.ErrNotExist):
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return err
		}
		info, err = os.Stat(dir)
		if err != nil {
			return err
		}
	case err != nil:
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("%s is not a directory", dir)
	}
	// Only the owner bit may be set; root must own it.
	if perm := info.Mode().Perm(); perm&0o077 != 0 {
		return fmt.Errorf("%s is accessible beyond its owner (mode %04o)", dir, perm)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return nil
	}
	if stat.Uid != 0 {
		return fmt.Errorf("%s is not owned by root (uid %d)", dir, stat.Uid)
	}
	return nil
}

// quiesceRunningService is a no-op: the installer stops the LaunchDaemon
// before replacing the binary, so there is no already-mapped image or held log
// file to release here.
func quiesceRunningService(_ options) error { return nil }

// tunnelCleanupTimeout mirrors the Linux budget: slightly longer than the
// tunnel manager's own command bound, so teardown is not cut short while
// the device is still shutting down.
const tunnelCleanupTimeout = 35 * time.Second

// tunnelDowner is the part of tunnel.Manager the shutdown path needs. The seam
// keeps it testable that shutdown uses a fresh context rather than the
// already-canceled signal context.
type tunnelDowner interface {
	Down(context.Context) (*protocol.Status, error)
}

// cleanupTunnel tears the tunnel down with a fresh context: the daemon's signal
// context is canceled before Serve returns, while this safety-critical
// teardown must still be allowed to finish. The status is checked so a
// successful command cannot hide a still-live device.
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

// cleanupFromOptions is used by the uninstaller and by a manual root run, not
// by the socket protocol. Kept root-only so a cleanup retry cannot become a
// tunnel-shutdown DoS for every local user.
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

// serveWithCleanup keeps the handler barrier and the tunnel teardown in one
// testable sequence. Down must not run until Serve has canceled and joined
// every active request handler.
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
// from main so serveWithCleanup's teardown runs before any os.Exit, and so the
// teardown is deliberately after Serve has returned: Serve first cancels
// active handlers and waits for them, so a shutdown cannot race an in-flight
// up/down.
func run(opts options) error {
	if opts.cleanup {
		return cleanupFromOptions(opts)
	}
	if opts.install {
		return installLaunchDaemon(opts)
	}
	if opts.uninstall {
		return uninstallLaunchDaemon(opts)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	listener, err := server.Listen(opts.socketPath, opts.socketGroup)
	if err != nil {
		return fmt.Errorf("bind socket: %w", err)
	}
	defer func() { _ = listener.Close() }()

	manager := tunnel.NewManager(opts.configDir, opts.iface)
	slog.Info("boltmeshd listening",
		"socket", opts.socketPath,
		"interface", opts.iface,
		"version", Version)

	return serveWithCleanup(ctx, manager, listener, slog.Default())
}
