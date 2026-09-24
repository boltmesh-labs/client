//go:build windows

package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"

	"boltmeshd/internal/server"
	"boltmeshd/internal/tunnel"
)

// windowsServiceName is the boltmeshd service itself (not the tunnel service,
// which the daemon creates on demand).
const windowsServiceName = "boltmeshd"

func defaultSocketPath() string  { return "" }
func defaultSocketGroup() string { return "" }
func defaultPipeName() string    { return `\\.\pipe\boltmesh\boltmeshd` }

// defaultLogFile is where failures are persisted, beside the privileged config
// under the machine-wide ProgramData directory.
func defaultLogFile() string {
	return filepath.Join(tunnel.DefaultConfigDir, "logs", "boltmeshd.log")
}

// prepareLogFile creates a fresh private log file in a verified directory.
// ProgramData's default ACE lets every local user read, and a pre-existing log
// may be user-owned or a reparse point. SecureLogFile rejects the latter and
// replaces the former before logging opens it in append mode.
func prepareLogFile(path string) error {
	return tunnel.SecureLogFile(path)
}

// prepareFilesystem runs before configureLogging, including for -install. It
// closes the pre-service window in which a standard user could pre-create the
// config directory or a junction at the configured path.
func prepareFilesystem(opts options) error {
	if opts.uninstall {
		return nil
	}
	if err := tunnel.ProtectDir(opts.configDir); err != nil {
		return fmt.Errorf("secure config directory %q: %w", opts.configDir, err)
	}
	return nil
}

// run installs/uninstalls the service, runs in the foreground for
// development, or hands control to the service control manager.
func run(opts options) error {
	switch {
	case opts.install:
		return installService(opts)
	case opts.uninstall:
		return uninstallService()
	case opts.console:
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
		defer stop()
		return serve(ctx, opts)
	}

	if err := svc.Run(windowsServiceName, &handler{opts: opts}); err != nil {
		return fmt.Errorf("run as a Windows service (use -console to run in the foreground): %w", err)
	}
	return nil
}

// serve binds the named pipe and serves the tunnel surface until ctx is
// canceled.
func serve(ctx context.Context, opts options) error {
	listener, err := server.ListenPipe(opts.pipeName)
	if err != nil {
		return fmt.Errorf("bind pipe: %w", err)
	}
	defer func() { _ = listener.Close() }()

	slog.Info("boltmeshd listening", "pipe", opts.pipeName, "interface", opts.iface, "version", Version)

	return server.New(tunnel.NewManager(opts.configDir, opts.iface), slog.Default()).Serve(ctx, listener)
}

// handler implements svc.Handler for the daemon service.
type handler struct {
	opts options
}

func (h *handler) Execute(_ []string, requests <-chan svc.ChangeRequest, changes chan<- svc.Status) (bool, uint32) {
	changes <- svc.Status{State: svc.StartPending}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	done := make(chan error, 1)
	go func() { done <- serve(ctx, h.opts) }()

	changes <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}

	for {
		select {
		case err := <-done:
			if err != nil {
				slog.Error("boltmeshd stopped", "error", err)
				return true, 1
			}
			return false, 0
		case request := <-requests:
			switch request.Cmd {
			case svc.Interrogate:
				changes <- request.CurrentStatus
			case svc.Stop, svc.Shutdown:
				changes <- svc.Status{State: svc.StopPending}
				cancel()
				<-done
				return false, 0
			}
		}
	}
}

func installService(opts options) error {
	// This is deliberately repeated at the elevated installation boundary,
	// even though prepareFilesystem also runs from main. It makes the
	// invariant explicit and keeps direct callers of installService safe.
	if err := tunnel.ProtectDir(opts.configDir); err != nil {
		return fmt.Errorf("secure config directory %q: %w", opts.configDir, err)
	}

	exe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("locate executable: %w", err)
	}
	manager, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("connect to service manager: %w", err)
	}
	defer func() { _ = manager.Disconnect() }()

	if existing, err := manager.OpenService(windowsServiceName); err == nil {
		_ = existing.Close()
	} else {
		created, err := manager.CreateService(windowsServiceName, exe, mgr.Config{
			DisplayName: windowsServiceName,
			Description: "BoltMesh privileged VPN helper",
			StartType:   mgr.StartAutomatic,
		})
		if err != nil {
			return fmt.Errorf("create service %s: %w", windowsServiceName, err)
		}
		_ = created.Close()
		slog.Info("installed service", "name", windowsServiceName)
	}

	handle, err := manager.OpenService(windowsServiceName)
	if err != nil {
		return fmt.Errorf("open service %s: %w", windowsServiceName, err)
	}
	defer func() { _ = handle.Close() }()
	if err := configureServiceRecovery(handle); err != nil {
		return fmt.Errorf("configure service %s: %w", windowsServiceName, err)
	}
	if err := handle.Start(); err != nil && !errors.Is(err, windows.ERROR_SERVICE_ALREADY_RUNNING) {
		return fmt.Errorf("start service %s: %w", windowsServiceName, err)
	}
	return nil
}

const serviceRecoveryResetPeriod = 24 * 60 * 60 // seconds

// serviceRecoveryActions is deliberately conservative: retry a daemon failure
// with increasing delays. If failures continue, the SCM repeats the final
// action; the reset period clears the failure count after a day of healthy
// service, so recovery remains automatic without a tight crash loop.
func serviceRecoveryActions() []mgr.RecoveryAction {
	return []mgr.RecoveryAction{
		{Type: mgr.ServiceRestart, Delay: 5 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 15 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 60 * time.Second},
	}
}

func configureServiceRecovery(handle *mgr.Service) error {
	if err := handle.SetRecoveryActions(serviceRecoveryActions(), serviceRecoveryResetPeriod); err != nil {
		return fmt.Errorf("configure service recovery actions: %w", err)
	}
	// Execute returns a non-zero service exit code for a serve failure. Ask
	// SCM to treat that explicit non-crash failure as recoverable too.
	if err := handle.SetRecoveryActionsOnNonCrashFailures(true); err != nil {
		return fmt.Errorf("configure service recovery trigger: %w", err)
	}
	return nil
}

func uninstallService() error {
	manager, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("connect to service manager: %w", err)
	}
	defer func() { _ = manager.Disconnect() }()

	handle, err := manager.OpenService(windowsServiceName)
	if err != nil {
		return nil // already gone
	}
	defer func() { _ = handle.Close() }()

	if status, err := handle.Query(); err == nil && status.State != svc.Stopped {
		if _, err := handle.Control(svc.Stop); err != nil && !errors.Is(err, windows.ERROR_SERVICE_NOT_ACTIVE) {
			return fmt.Errorf("stop service %s: %w", windowsServiceName, err)
		}
	}
	if err := handle.Delete(); err != nil && !errors.Is(err, windows.ERROR_SERVICE_MARKED_FOR_DELETE) {
		return fmt.Errorf("delete service %s: %w", windowsServiceName, err)
	}
	slog.Info("removed service", "name", windowsServiceName)
	return nil
}
