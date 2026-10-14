//go:build windows

// Package winsvc holds the Service Control Manager primitives shared by the
// boltmeshd daemon service and the WireGuard tunnel service it manages. Both
// run under SCM, so the polling, deletion and error-classification helpers live
// here rather than being duplicated in each caller.
package winsvc

import (
	"context"
	"errors"
	"fmt"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

// PollInterval bounds how often the SCM is polled while waiting for a
// start/stop transition.
const PollInterval = 250 * time.Millisecond

// RequestStop sends a stop control to handle, tolerating the responses that
// mean the service is already stopping or cannot accept controls yet. state is
// the state last reported by the SCM: a start/continue transition has not yet
// advertised Stop, so an invalid-control response there is a retry, not a
// failure.
func RequestStop(handle *mgr.Service, name string, state svc.State) error {
	_, err := handle.Control(svc.Stop)
	if err == nil || errors.Is(err, windows.ERROR_SERVICE_NOT_ACTIVE) ||
		errors.Is(err, windows.ERROR_SERVICE_CANNOT_ACCEPT_CTRL) ||
		IsMarkedForDelete(err) {
		return nil
	}
	if errors.Is(err, windows.ERROR_INVALID_SERVICE_CONTROL) &&
		(state == svc.State(0) || state == svc.StartPending || state == svc.ContinuePending) {
		return nil
	}
	return fmt.Errorf("stop service %s: %w", name, err)
}

// WaitForServiceGone polls until the service registration is deleted.
// DeleteService only marks a service for deletion, so a marked registration is
// expected until SCM finishes and its handle or process is gone.
func WaitForServiceGone(ctx context.Context, manager *mgr.Mgr, name string) error {
	ticker := time.NewTicker(PollInterval)
	defer ticker.Stop()

	for {
		handle, err := manager.OpenService(name)
		switch {
		case err == nil:
			_ = handle.Close()
		case IsMissing(err):
			return nil
		case !IsMarkedForDelete(err):
			return fmt.Errorf("check service %s deletion: %w", name, err)
		}

		select {
		case <-ctx.Done():
			return fmt.Errorf("wait for service %s to be deleted: %w", name, ctx.Err())
		case <-ticker.C:
		}
	}
}

// WaitForServiceRetry sleeps one poll interval so the caller can retry a
// transient SCM state without spinning.
func WaitForServiceRetry(ctx context.Context) error {
	timer := time.NewTimer(PollInterval)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

// WaitForProcessExit closes the gap between SERVICE_STOPPED and the service
// process actually exiting. SCM can report STOPPED while the executable is
// still unwinding, which would otherwise leave a locked binary or config file
// behind during an upgrade.
func WaitForProcessExit(ctx context.Context, processID uint32) error {
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

	waitMilliseconds := uint32(PollInterval / time.Millisecond)
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

// IsMissing reports whether err says the service registration does not exist.
func IsMissing(err error) bool {
	return errors.Is(err, windows.ERROR_SERVICE_DOES_NOT_EXIST) ||
		errors.Is(err, windows.ERROR_SERVICE_NOT_FOUND)
}

// IsMarkedForDelete reports whether err says the service is marked for
// deletion, meaning its registration still exists while another handle or
// process is draining.
func IsMarkedForDelete(err error) bool {
	return errors.Is(err, windows.ERROR_SERVICE_MARKED_FOR_DELETE)
}

// IsNotActive reports whether err says the service is not running.
func IsNotActive(err error) bool {
	return errors.Is(err, windows.ERROR_SERVICE_NOT_ACTIVE)
}
