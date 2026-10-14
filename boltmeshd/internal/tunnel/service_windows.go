//go:build windows

package tunnel

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"

	"boltmeshd/internal/protocol"
	"boltmeshd/internal/winsvc"
)

// winService drives the WireGuard tunnel through the Windows Service Control
// Manager. It runs inside boltmeshd, which runs as LocalSystem, so creating
// and starting the tunnel service needs no elevation of the app.
type winService struct {
	name string
}

func newWindowsService(name string) *winService {
	return &winService{name: name}
}

func (s *winService) openOrCreate(ctx context.Context, manager *mgr.Mgr, exe string, args []string) (*mgr.Service, error) {
	for {
		handle, err := manager.OpenService(s.name)
		if err == nil {
			return handle, nil
		}
		if winsvc.IsMarkedForDelete(err) {
			if err := winsvc.WaitForServiceGone(ctx, manager, s.name); err != nil {
				return nil, err
			}
			continue
		}
		if !winsvc.IsMissing(err) {
			return nil, fmt.Errorf("open service %s: %w", s.name, err)
		}

		created, err := manager.CreateService(s.name, exe, mgr.Config{
			DisplayName: s.name,
			Description: "BoltMesh WireGuard tunnel",
			StartType:   mgr.StartManual,
			// Match WireGuard for Windows' own tunnel service: unrestricted
			// service SID, so the Wintun adapter it creates is reachable by
			// the service it belongs to.
			SidType: windows.SERVICE_SID_TYPE_UNRESTRICTED,
		}, args...)
		if err == nil {
			return created, nil
		}
		if winsvc.IsMarkedForDelete(err) {
			if err := winsvc.WaitForServiceGone(ctx, manager, s.name); err != nil {
				return nil, err
			}
			continue
		}
		if errors.Is(err, windows.ERROR_SERVICE_EXISTS) {
			if err := winsvc.WaitForServiceRetry(ctx); err != nil {
				return nil, err
			}
			continue
		}
		return nil, fmt.Errorf("create service %s: %w", s.name, err)
	}
}

// start creates the tunnel service if it does not exist, then starts it and
// waits until it is running. A service left running from a previous session
// is stopped first, so the config file the caller wrote is the one applied.
func (s *winService) start(ctx context.Context, exe string, args []string) error {
	manager, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("connect to service manager: %w", err)
	}
	defer func() { _ = manager.Disconnect() }()

	for {
		handle, err := s.openOrCreate(ctx, manager, exe, args)
		if err != nil {
			return err
		}
		err = s.startHandle(ctx, handle, exe, args)
		_ = handle.Close()
		if err == nil {
			return nil
		}
		if winsvc.IsMarkedForDelete(err) {
			if err := winsvc.WaitForServiceGone(ctx, manager, s.name); err != nil {
				return err
			}
			continue
		}
		if winsvc.IsNotActive(err) || errors.Is(err, windows.ERROR_SERVICE_EXISTS) ||
			errors.Is(err, windows.ERROR_SERVICE_CANNOT_ACCEPT_CTRL) {
			if err := winsvc.WaitForServiceRetry(ctx); err != nil {
				return err
			}
			continue
		}
		return err
	}
}

func (s *winService) startHandle(ctx context.Context, handle *mgr.Service, exe string, args []string) error {
	// The service survives daemon upgrades and development rebuilds. Keep its
	// image path synchronized; otherwise SCM can retain a path to a deleted
	// build and StartService only reports ERROR_FILE_NOT_FOUND.
	if err := s.stopHandle(ctx, handle); err != nil {
		return fmt.Errorf("stop stale service %s: %w", s.name, err)
	}
	if err := s.updateCommand(handle, exe, args); err != nil {
		return err
	}

	if err := handle.Start(); err != nil && !errors.Is(err, windows.ERROR_SERVICE_ALREADY_RUNNING) {
		return fmt.Errorf("start service %s: %w", s.name, err)
	}
	return s.waitFor(ctx, handle, svc.Running)
}

func (s *winService) updateCommand(handle *mgr.Service, exe string, args []string) error {
	config, err := handle.Config()
	if err != nil {
		return fmt.Errorf("query service %s configuration: %w", s.name, err)
	}
	expected := serviceCommand(exe, args)
	if config.BinaryPathName == expected {
		return nil
	}
	config.BinaryPathName = expected
	if err := handle.UpdateConfig(config); err != nil {
		return fmt.Errorf("update service %s executable: %w", s.name, err)
	}
	return nil
}

func serviceCommand(exe string, args []string) string {
	command := make([]string, 0, len(args)+1)
	command = append(command, syscall.EscapeArg(exe))
	for _, arg := range args {
		command = append(command, syscall.EscapeArg(arg))
	}
	return strings.Join(command, " ")
}

// stop stops the tunnel service, leaving it registered so the next `up`
// reuses it (the config path never changes). It is idempotent: a missing or
// already-stopped service is success.
func (s *winService) stop(ctx context.Context) error {
	manager, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("connect to service manager: %w", err)
	}
	defer func() { _ = manager.Disconnect() }()

	handle, err := manager.OpenService(s.name)
	if err != nil {
		switch {
		case winsvc.IsMissing(err), winsvc.IsNotActive(err):
			// The service is absent or already stopped, so there is nothing
			// to stop.
			return nil
		case winsvc.IsMarkedForDelete(err):
			return winsvc.WaitForServiceGone(ctx, manager, s.name)
		default:
			return fmt.Errorf("open service %s: %w", s.name, err)
		}
	}
	defer func() { _ = handle.Close() }()

	return s.stopHandle(ctx, handle)
}

func (s *winService) stopHandle(ctx context.Context, handle *mgr.Service) error {
	ticker := time.NewTicker(winsvc.PollInterval)
	defer ticker.Stop()

	var processID uint32
	for {
		status, err := handle.Query()
		if err != nil {
			switch {
			case winsvc.IsMissing(err):
				return winsvc.WaitForProcessExit(ctx, processID)
			case winsvc.IsNotActive(err):
				// Re-query on the next tick; a stopped service may briefly
				// report ERROR_SERVICE_NOT_ACTIVE before its Stopped state.
			case !winsvc.IsMarkedForDelete(err):
				return fmt.Errorf("query service %s: %w", s.name, err)
			default:
				if err := winsvc.RequestStop(handle, s.name, svc.State(0)); err != nil {
					return err
				}
			}
		} else {
			if status.ProcessId != 0 {
				processID = status.ProcessId
			}
			switch status.State {
			case svc.Stopped:
				return winsvc.WaitForProcessExit(ctx, processID)
			case svc.StopPending:
				// The service has already accepted Stop. Poll until it
				// reports Stopped instead of sending duplicate controls.
			default:
				if err := winsvc.RequestStop(handle, s.name, status.State); err != nil {
					return err
				}
			}
		}

		select {
		case <-ctx.Done():
			return fmt.Errorf("wait for service %s to stop: %w", s.name, ctx.Err())
		case <-ticker.C:
		}
	}
}

// remove stops and deletes the tunnel service, then waits for SCM to finish
// deleting the registration. DeleteService only marks a service for deletion;
// returning while a handle or process still exists leaves the old service
// visible to the next install.
func (s *winService) remove(ctx context.Context) error {
	manager, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("connect to service manager: %w", err)
	}
	defer func() { _ = manager.Disconnect() }()

	handle, err := manager.OpenService(s.name)
	if err != nil {
		if winsvc.IsMissing(err) || winsvc.IsNotActive(err) {
			return nil
		}
		if winsvc.IsMarkedForDelete(err) {
			return winsvc.WaitForServiceGone(ctx, manager, s.name)
		}
		return fmt.Errorf("open service %s: %w", s.name, err)
	}

	if err := s.stopHandle(ctx, handle); err != nil {
		_ = handle.Close()
		return err
	}

	deleteErr := handle.Delete()
	closeErr := handle.Close()
	var errs []error
	if deleteErr != nil && !winsvc.IsMarkedForDelete(deleteErr) && !winsvc.IsMissing(deleteErr) {
		errs = append(errs, fmt.Errorf("delete service %s: %w", s.name, deleteErr))
	}
	if closeErr != nil &&
		!errors.Is(closeErr, windows.ERROR_INVALID_HANDLE) &&
		!winsvc.IsMissing(closeErr) &&
		!winsvc.IsMarkedForDelete(closeErr) {
		errs = append(errs, fmt.Errorf("close service %s: %w", s.name, closeErr))
	}
	if err := winsvc.WaitForServiceGone(ctx, manager, s.name); err != nil {
		errs = append(errs, err)
	}
	return errors.Join(errs...)
}

// stage reports the OS stage for the tunnel service. A missing or inactive
// service is disconnected, not an error.
func (s *winService) stage(ctx context.Context) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	manager, err := mgr.Connect()
	if err != nil {
		return "", fmt.Errorf("connect to service manager: %w", err)
	}
	defer func() { _ = manager.Disconnect() }()
	if err := ctx.Err(); err != nil {
		return "", err
	}

	handle, err := manager.OpenService(s.name)
	if err != nil {
		if winsvc.IsMissing(err) || winsvc.IsNotActive(err) {
			return protocol.StageDisconnected, nil
		}
		return "", fmt.Errorf("open service %s: %w", s.name, err)
	}
	defer func() { _ = handle.Close() }()
	if err := ctx.Err(); err != nil {
		return "", err
	}

	status, err := handle.Query()
	if err != nil {
		if ctxErr := ctx.Err(); ctxErr != nil {
			return "", ctxErr
		}
		return "", fmt.Errorf("query service %s: %w", s.name, err)
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	switch status.State {
	case svc.Running:
		return protocol.StageConnected, nil
	case svc.StartPending, svc.ContinuePending:
		return protocol.StageConnecting, nil
	default:
		return protocol.StageDisconnected, nil
	}
}

func (s *winService) waitFor(ctx context.Context, handle *mgr.Service, want svc.State) error {
	ticker := time.NewTicker(winsvc.PollInterval)
	defer ticker.Stop()

	for {
		status, err := handle.Query()
		if err != nil {
			if want == svc.Stopped && winsvc.IsMissing(err) {
				return nil
			}
			return fmt.Errorf("query service %s: %w", s.name, err)
		}
		if status.State == want {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("wait for service %s: %w", s.name, ctx.Err())
		case <-ticker.C:
		}
	}
}
