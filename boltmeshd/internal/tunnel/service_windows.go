//go:build windows

package tunnel

import (
	"context"
	"errors"
	"fmt"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"

	"boltmeshd/internal/protocol"
)

// servicePollInterval bounds how often the SCM is polled while waiting for a
// start/stop transition.
const servicePollInterval = 250 * time.Millisecond

// winService drives the WireGuard tunnel through the Windows Service Control
// Manager. It runs inside boltmeshd, which runs as LocalSystem, so creating
// and starting the tunnel service needs no elevation of the app.
type winService struct {
	name string
}

func newWindowsService(name string) *winService {
	return &winService{name: name}
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

	handle, err := manager.OpenService(s.name)
	if err != nil {
		handle, err = manager.CreateService(s.name, exe, mgr.Config{
			DisplayName: s.name,
			Description: "BoltMesh WireGuard tunnel",
			StartType:   mgr.StartManual,
			// Match WireGuard for Windows' own tunnel service: unrestricted
			// service SID, so the Wintun adapter it creates is reachable by
			// the service it belongs to.
			SidType: windows.SERVICE_SID_TYPE_UNRESTRICTED,
		}, args...)
		if err != nil {
			return fmt.Errorf("create service %s: %w", s.name, err)
		}
	}
	// The service survives daemon upgrades and development rebuilds. Keep its
	// image path synchronized; otherwise SCM can retain a path to a deleted
	// build and StartService only reports ERROR_FILE_NOT_FOUND.
	defer func() { _ = handle.Close() }()

	status, err := handle.Query()
	if err != nil {
		return fmt.Errorf("query service %s: %w", s.name, err)
	}
	if status.State != svc.Stopped {
		if _, err := handle.Control(svc.Stop); err != nil && !errors.Is(err, windows.ERROR_SERVICE_NOT_ACTIVE) {
			return fmt.Errorf("stop stale service %s: %w", s.name, err)
		}
		if err := s.waitFor(ctx, handle, svc.Stopped); err != nil {
			return err
		}
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
	command := syscall.EscapeArg(exe)
	for _, arg := range args {
		command += " " + syscall.EscapeArg(arg)
	}
	return command
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
		// No such service: nothing is running.
		return nil
	}
	defer func() { _ = handle.Close() }()

	status, err := handle.Query()
	if err != nil {
		return fmt.Errorf("query service %s: %w", s.name, err)
	}
	if status.State == svc.Stopped {
		return nil
	}
	if _, err := handle.Control(svc.Stop); err != nil && !errors.Is(err, windows.ERROR_SERVICE_NOT_ACTIVE) {
		return fmt.Errorf("stop service %s: %w", s.name, err)
	}
	return s.waitFor(ctx, handle, svc.Stopped)
}

// stage reports the OS stage for the tunnel service. A missing service is
// disconnected, not an error.
func (s *winService) stage(_ context.Context) (string, error) {
	manager, err := mgr.Connect()
	if err != nil {
		return "", fmt.Errorf("connect to service manager: %w", err)
	}
	defer func() { _ = manager.Disconnect() }()

	handle, err := manager.OpenService(s.name)
	if err != nil {
		return protocol.StageDisconnected, nil
	}
	defer func() { _ = handle.Close() }()

	status, err := handle.Query()
	if err != nil {
		return "", fmt.Errorf("query service %s: %w", s.name, err)
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
	for {
		status, err := handle.Query()
		if err != nil {
			return fmt.Errorf("query service %s: %w", s.name, err)
		}
		if status.State == want {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("wait for service %s: %w", s.name, ctx.Err())
		case <-time.After(servicePollInterval):
		}
	}
}
