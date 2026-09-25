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
	"syscall"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"

	"boltmeshd/internal/protocol"
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

// quiesceRunningService stops an already-running daemon so the installer can
// take over its resources. Two things depend on it, and neither works without
// it:
//
//   - configureLogging replaces the log file, which fails with ACCESS_DENIED
//     while the old process still holds it open.
//   - A running service keeps its already-mapped image. openOrCreateService
//     repoints the registration at the new executable and installService
//     tolerates ERROR_SERVICE_ALREADY_RUNNING, so without a stop here an
//     upgrade reported success while the previous daemon kept serving. That
//     also means the new hardening code was never exercised on the machine.
//
// A service that is absent or already stopped is success, so a first install
// needs no special case.
func quiesceRunningService(opts options) error {
	if !opts.install {
		return nil
	}
	manager, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("connect to service manager: %w", err)
	}
	defer func() { _ = manager.Disconnect() }()

	ctx, cancel := context.WithTimeout(context.Background(), serviceOperationTimeout)
	defer cancel()

	handle, err := openDaemonService(ctx, manager)
	if err != nil {
		return fmt.Errorf("open the running %s service: %w", windowsServiceName, err)
	}
	if handle == nil {
		return nil
	}
	defer func() { _ = handle.Close() }()

	if err := stopAndWaitService(ctx, handle, windowsServiceName); err != nil {
		return fmt.Errorf("stop the running %s service: %w", windowsServiceName, err)
	}
	return nil
}

// run tears down a live tunnel, installs/uninstalls the service, runs in the
// foreground for development, or hands control to the service control manager.
func run(opts options) error {
	switch {
	case opts.cleanup:
		ctx, cancel := context.WithTimeout(context.Background(), serviceOperationTimeout)
		defer cancel()
		status, err := tunnel.NewManager(opts.configDir, opts.iface).Down(ctx)
		if err != nil {
			return fmt.Errorf("tunnel cleanup: %w", err)
		}
		if status == nil || status.Up || status.Stage != protocol.StageDisconnected {
			return errors.New("tunnel cleanup: tunnel remains active")
		}
		return nil
	case opts.install:
		return installService(opts)
	case opts.uninstall:
		return uninstallService(opts)
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

const (
	// SCM transitions are asynchronous. Keep the command bounded so a broken
	// service cannot make an installer wait forever, while still allowing a
	// WireGuard/daemon shutdown to finish normally.
	serviceOperationTimeout = 30 * time.Second
	servicePollInterval     = 250 * time.Millisecond
)

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

	ctx, cancel := context.WithTimeout(context.Background(), serviceOperationTimeout)
	defer cancel()

	for {
		handle, err := openOrCreateService(manager, exe)
		if err != nil {
			if isServiceMarkedForDelete(err) {
				if err := waitForServiceGone(ctx, manager, windowsServiceName); err != nil {
					return fmt.Errorf("wait for old service registration: %w", err)
				}
				continue
			}
			if isServiceAlreadyExists(err) || isServiceMissing(err) || isServiceNotActive(err) ||
				errors.Is(err, windows.ERROR_SERVICE_CANNOT_ACCEPT_CTRL) {
				if err := waitForServiceRetry(ctx); err != nil {
					return fmt.Errorf("wait to retry service installation: %w", err)
				}
				continue
			}
			return err
		}

		configureErr := configureServiceRecovery(handle)
		if configureErr == nil {
			if err := handle.Start(); err != nil && !errors.Is(err, windows.ERROR_SERVICE_ALREADY_RUNNING) {
				configureErr = err
			}
		}
		_ = handle.Close()
		if configureErr == nil {
			return nil
		}
		if isServiceMarkedForDelete(configureErr) {
			if err := waitForServiceGone(ctx, manager, windowsServiceName); err != nil {
				return fmt.Errorf("wait for old service registration: %w", err)
			}
			continue
		}
		if isServiceMissing(configureErr) || isServiceNotActive(configureErr) ||
			errors.Is(configureErr, windows.ERROR_SERVICE_CANNOT_ACCEPT_CTRL) {
			if err := waitForServiceRetry(ctx); err != nil {
				return fmt.Errorf("wait to retry service installation: %w", err)
			}
			continue
		}
		return fmt.Errorf("configure or start service %s: %w", windowsServiceName, configureErr)
	}
}

func updateServiceCommand(handle *mgr.Service, exe string) error {
	config, err := handle.Config()
	if err != nil {
		return fmt.Errorf("query service %s configuration: %w", windowsServiceName, err)
	}
	expected := syscall.EscapeArg(exe)
	if config.BinaryPathName == expected {
		return nil
	}
	config.BinaryPathName = expected
	if err := handle.UpdateConfig(config); err != nil {
		return fmt.Errorf("update service %s executable: %w", windowsServiceName, err)
	}
	return nil
}

func openOrCreateService(manager *mgr.Mgr, exe string) (*mgr.Service, error) {
	handle, err := manager.OpenService(windowsServiceName)
	if err == nil {
		// Updating the image path both keeps an idempotent install pointed at
		// the current executable and probes a registration that has already
		// been marked for deletion. Such a service can still be opened while
		// another handle is draining, but configuration and start operations
		// fail with ERROR_SERVICE_MARKED_FOR_DELETE.
		if err := updateServiceCommand(handle, exe); err != nil {
			if closeErr := handle.Close(); closeErr != nil &&
				!errors.Is(closeErr, windows.ERROR_INVALID_HANDLE) &&
				!isServiceMarkedForDelete(closeErr) &&
				!isServiceMissing(closeErr) {
				return nil, fmt.Errorf("close service %s: %w", windowsServiceName, closeErr)
			}
			return nil, err
		}
		return handle, nil
	}
	if isServiceMarkedForDelete(err) {
		return nil, fmt.Errorf("open service %s: %w", windowsServiceName, err)
	}
	if !isServiceMissing(err) {
		return nil, fmt.Errorf("open service %s: %w", windowsServiceName, err)
	}

	created, err := manager.CreateService(windowsServiceName, exe, mgr.Config{
		DisplayName: windowsServiceName,
		Description: "BoltMesh privileged VPN helper",
		StartType:   mgr.StartAutomatic,
	})
	if err != nil {
		return nil, fmt.Errorf("create service %s: %w", windowsServiceName, err)
	}
	slog.Info("installed service", "name", windowsServiceName)
	return created, nil
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

// uninstallService accepts the parsed options when available, while keeping
// the no-argument form useful to package callers that use the defaults.
func uninstallService(option ...options) error {
	opts := options{}
	if len(option) > 0 {
		opts = option[0]
	}
	return uninstallServiceWithOptions(opts)
}

func uninstallServiceWithOptions(opts options) error {
	manager, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("connect to service manager: %w", err)
	}
	defer func() { _ = manager.Disconnect() }()

	daemonCtx, daemonCancel := context.WithTimeout(context.Background(), serviceOperationTimeout)
	defer daemonCancel()

	// Quiesce the daemon before touching the tunnel. Otherwise a request that
	// is already in flight can recreate the tunnel service or rewrite its
	// private-key config while uninstall is removing them. Keep the daemon
	// registration around until the tunnel cleanup succeeds so a failed
	// uninstall remains retryable.
	daemon, err := openDaemonService(daemonCtx, manager)
	if err != nil {
		return err
	}
	daemonPresent := daemon != nil
	if daemon != nil {
		if err := stopAndWaitService(daemonCtx, daemon, windowsServiceName); err != nil {
			_ = daemon.Close()
			return fmt.Errorf("quiesce daemon service: %w", err)
		}
		// A recovery action can otherwise restart the daemon while the
		// tunnel is being removed. Disable it before releasing our handle.
		if err := daemon.ResetRecoveryActions(); err != nil &&
			!isServiceMarkedForDelete(err) &&
			!isServiceMissing(err) &&
			!errors.Is(err, windows.ERROR_INVALID_HANDLE) {
			_ = daemon.Close()
			return fmt.Errorf("disable daemon recovery: %w", err)
		}
		if err := daemon.Close(); err != nil &&
			!errors.Is(err, windows.ERROR_INVALID_HANDLE) &&
			!isServiceMarkedForDelete(err) &&
			!isServiceMissing(err) {
			return fmt.Errorf("close daemon service: %w", err)
		}
	}
	daemonCancel()

	dir, iface := opts.configDir, opts.iface
	if dir == "" {
		dir = tunnel.DefaultConfigDir
	}
	if iface == "" {
		iface = tunnel.DefaultInterface
	}
	tunnelCtx, tunnelCancel := context.WithTimeout(context.Background(), serviceOperationTimeout)
	if err := tunnel.NewManager(dir, iface).Uninstall(tunnelCtx); err != nil {
		tunnelCancel()
		return fmt.Errorf("remove tunnel; daemon remains stopped for retry: %w", err)
	}
	tunnelCancel()
	if !daemonPresent {
		return nil
	}

	// The daemon may have been restarted by SCM recovery while the tunnel was
	// being removed. Reopen and verify it is stopped before deleting it.
	deleteCtx, deleteCancel := context.WithTimeout(context.Background(), serviceOperationTimeout)
	defer deleteCancel()
	daemon, err = openDaemonService(deleteCtx, manager)
	if err != nil {
		return err
	}
	if daemon == nil {
		return nil
	}
	if err := deleteStoppedService(deleteCtx, manager, daemon); err != nil {
		return err
	}

	slog.Info("removed service", "name", windowsServiceName)
	return nil
}

func deleteStoppedService(ctx context.Context, manager *mgr.Mgr, handle *mgr.Service) error {
	if err := stopAndWaitService(ctx, handle, windowsServiceName); err != nil {
		_ = handle.Close()
		return fmt.Errorf("stop daemon service: %w", err)
	}
	if err := handle.ResetRecoveryActions(); err != nil &&
		!isServiceMarkedForDelete(err) &&
		!isServiceMissing(err) &&
		!errors.Is(err, windows.ERROR_INVALID_HANDLE) {
		_ = handle.Close()
		return fmt.Errorf("disable daemon recovery: %w", err)
	}

	deleteErr := handle.Delete()
	closeErr := handle.Close()
	var errs []error
	if deleteErr != nil && !isServiceMarkedForDelete(deleteErr) && !isServiceMissing(deleteErr) {
		errs = append(errs, fmt.Errorf("delete service %s: %w", windowsServiceName, deleteErr))
	}
	if closeErr != nil &&
		!errors.Is(closeErr, windows.ERROR_INVALID_HANDLE) &&
		!isServiceMarkedForDelete(closeErr) &&
		!isServiceMissing(closeErr) {
		errs = append(errs, fmt.Errorf("close service %s: %w", windowsServiceName, closeErr))
	}
	if err := waitForServiceGone(ctx, manager, windowsServiceName); err != nil {
		errs = append(errs, fmt.Errorf("wait for service %s deletion: %w", windowsServiceName, err))
	}
	return errors.Join(errs...)
}

func openDaemonService(ctx context.Context, manager *mgr.Mgr) (*mgr.Service, error) {
	for {
		handle, err := manager.OpenService(windowsServiceName)
		if err == nil {
			return handle, nil
		}
		if isServiceMissing(err) || isServiceNotActive(err) {
			return nil, nil
		}
		if !isServiceMarkedForDelete(err) {
			return nil, fmt.Errorf("open service %s: %w", windowsServiceName, err)
		}
		// A concurrent uninstall may have marked the service but still be
		// draining its process/handles. Retry until it is gone; if it remains
		// available, the next iteration obtains a handle and performs the stop.
		if err := waitForServiceRetry(ctx); err != nil {
			return nil, fmt.Errorf("open service %s: %w", windowsServiceName, err)
		}
	}
}

func stopAndWaitService(ctx context.Context, handle *mgr.Service, name string) error {
	ticker := time.NewTicker(servicePollInterval)
	defer ticker.Stop()

	var processID uint32
	for {
		status, err := handle.Query()
		if err != nil {
			switch {
			case isServiceMissing(err):
				return waitForProcessExit(ctx, processID)
			case isServiceNotActive(err):
				// Re-query on the next tick; a stopped service may briefly
				// report ERROR_SERVICE_NOT_ACTIVE before its Stopped state.
			case !isServiceMarkedForDelete(err):
				return fmt.Errorf("query service %s: %w", name, err)
			default:
				// A marked service can still be controllable through this handle.
				// Try the stop request and keep polling; if the registration
				// disappears, the next query completes the transition.
				if err := requestServiceStop(handle, name, svc.State(0)); err != nil {
					return err
				}
			}
		} else {
			if status.ProcessId != 0 {
				processID = status.ProcessId
			}
			switch status.State {
			case svc.Stopped:
				return waitForProcessExit(ctx, processID)
			case svc.StopPending:
				// The service has already accepted Stop. Do not send a
				// second control request while it is winding down.
			default:
				if err := requestServiceStop(handle, name, status.State); err != nil {
					return err
				}
			}
		}

		select {
		case <-ctx.Done():
			return fmt.Errorf("wait for service %s to stop: %w", name, ctx.Err())
		case <-ticker.C:
		}
	}
}

func requestServiceStop(handle *mgr.Service, name string, state svc.State) error {
	_, err := handle.Control(svc.Stop)
	if err == nil || errors.Is(err, windows.ERROR_SERVICE_NOT_ACTIVE) ||
		errors.Is(err, windows.ERROR_SERVICE_CANNOT_ACCEPT_CTRL) ||
		isServiceMarkedForDelete(err) {
		return nil
	}
	// A service in a start/continue transition may not yet advertise Stop;
	// retry after the next state query. For a steady active state, an
	// invalid-control response is a real stop failure.
	if errors.Is(err, windows.ERROR_INVALID_SERVICE_CONTROL) &&
		(state == svc.State(0) || state == svc.StartPending || state == svc.ContinuePending) {
		return nil
	}
	return fmt.Errorf("stop service %s: %w", name, err)
}

// waitForProcessExit closes the gap between SERVICE_STOPPED and the service
// process actually exiting. SCM can report STOPPED while the executable is
// still unwinding, which would otherwise leave a locked binary behind during
// an upgrade.
func waitForProcessExit(ctx context.Context, processID uint32) error {
	if processID == 0 {
		return nil
	}

	process, err := windows.OpenProcess(windows.SYNCHRONIZE, false, processID)
	if err != nil {
		if errors.Is(err, windows.ERROR_INVALID_PARAMETER) {
			// The process has already exited and its PID is no longer valid.
			return nil
		}
		return fmt.Errorf("open service process %d: %w", processID, err)
	}
	defer func() { _ = windows.CloseHandle(process) }()

	waitMilliseconds := uint32(servicePollInterval / time.Millisecond)
	for {
		result, err := windows.WaitForSingleObject(process, waitMilliseconds)
		if err != nil {
			return fmt.Errorf("wait for service process %d: %w", processID, err)
		}
		switch result {
		case windows.WAIT_OBJECT_0:
			return nil
		case uint32(windows.WAIT_TIMEOUT):
			// Check cancellation between bounded waits.
		default:
			return fmt.Errorf("wait for service process %d returned %#x", processID, result)
		}

		select {
		case <-ctx.Done():
			return fmt.Errorf("wait for service process %d: %w", processID, ctx.Err())
		default:
		}
	}
}

func waitForServiceGone(ctx context.Context, manager *mgr.Mgr, name string) error {
	ticker := time.NewTicker(servicePollInterval)
	defer ticker.Stop()

	for {
		handle, err := manager.OpenService(name)
		switch {
		case err == nil:
			_ = handle.Close()
		case isServiceMissing(err):
			return nil
		case !isServiceMarkedForDelete(err):
			return fmt.Errorf("check service %s deletion: %w", name, err)
		}

		select {
		case <-ctx.Done():
			return fmt.Errorf("wait for service %s to be deleted: %w", name, ctx.Err())
		case <-ticker.C:
		}
	}
}

func waitForServiceRetry(ctx context.Context) error {
	timer := time.NewTimer(servicePollInterval)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func isServiceMissing(err error) bool {
	return errors.Is(err, windows.ERROR_SERVICE_DOES_NOT_EXIST) ||
		errors.Is(err, windows.ERROR_SERVICE_NOT_FOUND)
}

func isServiceMarkedForDelete(err error) bool {
	return errors.Is(err, windows.ERROR_SERVICE_MARKED_FOR_DELETE)
}

func isServiceAlreadyExists(err error) bool {
	return errors.Is(err, windows.ERROR_SERVICE_EXISTS)
}

func isServiceNotActive(err error) bool {
	return errors.Is(err, windows.ERROR_SERVICE_NOT_ACTIVE)
}
