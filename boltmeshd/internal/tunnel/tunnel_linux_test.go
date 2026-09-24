//go:build linux

package tunnel

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"

	"boltmeshd/internal/protocol"
)

type runCall struct {
	name string
	args []string
}

func mustKey(t *testing.T, encoded string) wgtypes.Key {
	t.Helper()
	key, err := wgtypes.ParseKey(encoded)
	if err != nil {
		t.Fatalf("ParseKey(%q) = %v", encoded, err)
	}
	return key
}

func deviceWithPeers(t *testing.T) *wgtypes.Device {
	t.Helper()
	return &wgtypes.Device{
		Name: DefaultInterface,
		Peers: []wgtypes.Peer{
			{
				PublicKey:         mustKey(t, keyB),
				Endpoint:          &net.UDPAddr{IP: net.ParseIP("203.0.113.10"), Port: 51820},
				LastHandshakeTime: time.Unix(1000, 0),
				ReceiveBytes:      100,
				TransmitBytes:     200,
			},
			{
				PublicKey:         mustKey(t, keyA),
				Endpoint:          &net.UDPAddr{IP: net.ParseIP("198.51.100.7"), Port: 1234},
				LastHandshakeTime: time.Unix(2000, 0),
				ReceiveBytes:      5,
				TransmitBytes:     6,
			},
		},
	}
}

func newTestManager(t *testing.T, linkUp bool, dev *wgtypes.Device, devErr error) *Manager {
	t.Helper()
	m := NewManager(t.TempDir(), DefaultInterface)
	// Passthrough resolver: tests assert on the bare tool names they already
	// know, while the real resolver is exercised by the findTool tests.
	m.lookup = func(name string) (string, error) { return name, nil }
	m.linkExists = func(string) bool { return linkUp }
	m.device = func(string) (*wgtypes.Device, error) { return dev, devErr }
	return m
}

func overrideToolDirs(t *testing.T, dirs []string) {
	t.Helper()
	old := toolDirs
	toolDirs = dirs
	t.Cleanup(func() { toolDirs = old })
}

func writeTool(t *testing.T, dir, name string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestFindToolUsesFixedDirectories(t *testing.T) {
	dir := t.TempDir()
	writeTool(t, dir, wgQuickBinary)
	overrideToolDirs(t, []string{dir, "/does/not/exist"})

	got, err := findTool(wgQuickBinary)
	if err != nil {
		t.Fatalf("findTool(%q) = %v", wgQuickBinary, err)
	}
	if want := filepath.Join(dir, wgQuickBinary); got != want {
		t.Fatalf("findTool = %q, want %q", got, want)
	}
}

func TestFindToolMissingIsAnError(t *testing.T) {
	overrideToolDirs(t, []string{t.TempDir()})

	if _, err := findTool(wgQuickBinary); err == nil {
		t.Fatal("findTool(missing) = nil, want error")
	}
}

func TestUpFailsWithoutWgQuickAndWritesNothing(t *testing.T) {
	m := newTestManager(t, false, deviceWithPeers(t), nil)
	m.lookup = findTool
	overrideToolDirs(t, []string{t.TempDir()})

	_, err := m.Up(context.Background(), validConfig)
	var opErr *protocol.OpError
	if !errors.As(err, &opErr) || opErr.Code != protocol.CodeInternal {
		t.Fatalf("Up(no wg-quick) = %v, want internal", err)
	}
	if _, statErr := os.Stat(m.configPath()); !os.IsNotExist(statErr) {
		t.Fatal("config written despite the tool being missing")
	}
}

func recordRuns() (*[]runCall, runFunc) {
	calls := &[]runCall{}
	run := func(_ context.Context, name string, args ...string) ([]byte, error) {
		*calls = append(*calls, runCall{name: name, args: args})
		return []byte("ok"), nil
	}
	return calls, run
}

func TestUpWritesConfigAndRunsWgQuick(t *testing.T) {
	m := newTestManager(t, false, deviceWithPeers(t), nil)
	calls, run := recordRuns()
	m.run = run

	status, err := m.Up(context.Background(), validConfig)
	if err != nil {
		t.Fatalf("Up() = %v", err)
	}
	if !status.Up || status.Stage != protocol.StageConnected {
		t.Fatalf("Up() status = %+v, want connected", status)
	}

	if len(*calls) != 1 || (*calls)[0].name != wgQuickBinary {
		t.Fatalf("calls = %+v, want one wg-quick invocation", *calls)
	}
	if got := (*calls)[0].args; len(got) != 2 || got[0] != "up" || got[1] != m.configPath() {
		t.Fatalf("wg-quick args = %v, want [up %s]", got, m.configPath())
	}

	data, err := os.ReadFile(m.configPath())
	if err != nil {
		t.Fatalf("config not written: %v", err)
	}
	if string(data) != validConfig {
		t.Fatal("written config does not match input")
	}
	info, err := os.Stat(m.configPath())
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("config mode = %o, want 600", perm)
	}
}

func TestUpRejectsInvalidConfigWithoutPrivilege(t *testing.T) {
	m := newTestManager(t, false, deviceWithPeers(t), nil)
	calls, run := recordRuns()
	m.run = run

	_, err := m.Up(context.Background(), "not a config")
	var opErr *protocol.OpError
	if !errors.As(err, &opErr) || opErr.Code != protocol.CodeBadConfig {
		t.Fatalf("Up(invalid) error = %v, want bad_config", err)
	}
	if len(*calls) != 0 {
		t.Fatalf("calls = %+v, want none", *calls)
	}
	if _, statErr := os.Stat(m.configPath()); !os.IsNotExist(statErr) {
		t.Fatal("config written for invalid input")
	}
}

func TestUpBouncesExistingLink(t *testing.T) {
	m := newTestManager(t, true, deviceWithPeers(t), nil)
	calls, run := recordRuns()
	m.run = run

	if _, err := m.Up(context.Background(), validConfig); err != nil {
		t.Fatalf("Up() = %v", err)
	}
	if len(*calls) != 3 {
		t.Fatalf("calls = %+v, want down, resolver cleanup, then up", *calls)
	}
	if (*calls)[0].args[0] != "down" || (*calls)[1].name != resolvconfBinary || (*calls)[2].args[0] != "up" {
		t.Fatalf("call order = %+v, want down, resolver cleanup, then up", *calls)
	}
}

// A config left on disk by an unclean exit must be overwritten, never
// appended to or reused.
func TestUpOverwritesStaleConfig(t *testing.T) {
	m := newTestManager(t, false, deviceWithPeers(t), nil)
	if err := os.WriteFile(m.configPath(), []byte("stale"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, run := recordRuns()
	m.run = run

	if _, err := m.Up(context.Background(), validConfig); err != nil {
		t.Fatalf("Up() = %v", err)
	}
	data, err := os.ReadFile(m.configPath())
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != validConfig {
		t.Fatal("Up did not overwrite the stale config")
	}
}

// A failed wg-quick up must not leave the privileged config behind.
func TestUpRemovesConfigWhenWgQuickUpFails(t *testing.T) {
	m := newTestManager(t, false, deviceWithPeers(t), nil)
	calls := &[]runCall{}
	m.run = func(_ context.Context, name string, args ...string) ([]byte, error) {
		*calls = append(*calls, runCall{name: name, args: args})
		if len(args) > 0 && args[0] == "up" {
			return []byte("boom"), errors.New("exit status 1")
		}
		if len(args) > 0 && args[0] == "down" {
			if _, statErr := os.Stat(m.configPath()); statErr != nil {
				t.Fatalf("config was removed before wg-quick down: %v", statErr)
			}
		}
		return nil, nil
	}

	_, err := m.Up(context.Background(), validConfig)
	var opErr *protocol.OpError
	if !errors.As(err, &opErr) || opErr.Code != protocol.CodeInternal {
		t.Fatalf("Up(failing wg-quick) = %v, want internal", err)
	}
	if _, statErr := os.Stat(m.configPath()); !os.IsNotExist(statErr) {
		t.Fatal("config left behind after a failed wg-quick up")
	}
	if len(*calls) != 3 {
		t.Fatalf("calls = %+v, want up, wg-quick down, then resolver cleanup", *calls)
	}
	if (*calls)[1].name != wgQuickBinary || (*calls)[1].args[0] != "down" {
		t.Fatalf("cleanup calls = %+v, want wg-quick down after failed up", *calls)
	}
	if (*calls)[2].name != resolvconfBinary {
		t.Fatalf("cleanup calls = %+v, want resolver cleanup after failed up", *calls)
	}
}

// Down must clean up a config orphaned by an unclean exit even when the
// interface is already gone (idempotent teardown).
func TestDownRemovesStaleConfigWhenLinkAbsent(t *testing.T) {
	m := newTestManager(t, false, nil, errors.New("no device"))
	if err := os.WriteFile(m.configPath(), []byte(validConfig), 0o600); err != nil {
		t.Fatal(err)
	}
	calls, run := recordRuns()
	m.run = run

	if _, err := m.Down(context.Background()); err != nil {
		t.Fatalf("Down() = %v", err)
	}
	if _, err := os.Stat(m.configPath()); !os.IsNotExist(err) {
		t.Fatal("stale config not removed by Down")
	}
	if len(*calls) != 1 || (*calls)[0].name != resolvconfBinary {
		t.Fatalf("calls = %+v, want resolver cleanup with the link absent", *calls)
	}
}

func TestDownIsIdempotentWhenAbsent(t *testing.T) {
	m := newTestManager(t, false, nil, errors.New("no device"))
	calls, run := recordRuns()
	m.run = run

	status, err := m.Down(context.Background())
	if err != nil {
		t.Fatalf("Down() = %v", err)
	}
	if status.Up || status.Stage != protocol.StageDisconnected {
		t.Fatalf("Down() status = %+v, want disconnected", status)
	}
	if len(*calls) != 1 || (*calls)[0].name != resolvconfBinary {
		t.Fatalf("calls = %+v, want resolver cleanup only", *calls)
	}
}

func TestDownUsesResolvectlWhenResolvconfIsUnavailable(t *testing.T) {
	m := newTestManager(t, false, nil, errors.New("no device"))
	m.lookup = func(name string) (string, error) {
		if name == resolvconfBinary {
			return "", errors.New("resolvconf is not installed")
		}
		return name, nil
	}
	calls, run := recordRuns()
	m.run = run

	if _, err := m.Down(context.Background()); err != nil {
		t.Fatalf("Down() = %v", err)
	}
	if len(*calls) != 1 || (*calls)[0].name != resolvectlBinary {
		t.Fatalf("calls = %+v, want resolvectl fallback", *calls)
	}
	if got := (*calls)[0].args; len(got) != 2 || got[0] != "revert" || got[1] != DefaultInterface {
		t.Fatalf("resolvectl args = %v, want [revert %s]", got, DefaultInterface)
	}
}

func TestDownFallsBackToLinkDelete(t *testing.T) {
	m := newTestManager(t, true, nil, errors.New("no device"))
	calls := &[]runCall{}
	m.run = func(_ context.Context, name string, args ...string) ([]byte, error) {
		*calls = append(*calls, runCall{name: name, args: args})
		if name == wgQuickBinary {
			return []byte("stale state"), errors.New("exit status 1")
		}
		return nil, nil
	}

	if _, err := m.Down(context.Background()); err != nil {
		t.Fatalf("Down() = %v", err)
	}
	if len(*calls) != 3 || (*calls)[1].name != ipBinary || (*calls)[2].name != resolvconfBinary {
		t.Fatalf("calls = %+v, want wg-quick down, ip link del, then resolver cleanup", *calls)
	}
	if _, err := os.Stat(m.configPath()); !os.IsNotExist(err) {
		t.Fatal("config not removed after down")
	}
}

func TestDownKeepsConfigWhenResolverCleanupFails(t *testing.T) {
	m := newTestManager(t, false, nil, errors.New("no device"))
	if err := os.WriteFile(m.configPath(), []byte(validConfig), 0o600); err != nil {
		t.Fatal(err)
	}
	m.run = func(_ context.Context, name string, _ ...string) ([]byte, error) {
		return nil, fmt.Errorf("resolver cleanup failed for %s", name)
	}

	if _, err := m.Down(context.Background()); err == nil {
		t.Fatal("Down() = nil, want resolver cleanup error")
	}
	if _, err := os.Stat(m.configPath()); err != nil {
		t.Fatalf("config was removed despite failed resolver cleanup: %v", err)
	}
}

func TestStatusAggregatesPeers(t *testing.T) {
	m := newTestManager(t, true, deviceWithPeers(t), nil)

	status := m.Status()
	if !status.Up || status.Stage != protocol.StageConnected {
		t.Fatalf("Status() = %+v, want connected", status)
	}
	if status.RxBytes != 105 || status.TxBytes != 206 {
		t.Fatalf("counters = rx %d tx %d, want 105/206", status.RxBytes, status.TxBytes)
	}
	if status.LastHandshake != 2000 {
		t.Fatalf("lastHandshake = %d, want 2000", status.LastHandshake)
	}
	if status.PublicKey != keyA {
		t.Fatalf("publicKey = %q, want the newest peer %q", status.PublicKey, keyA)
	}
	if status.Endpoint != "198.51.100.7:1234" {
		t.Fatalf("endpoint = %q, want 198.51.100.7:1234", status.Endpoint)
	}
}

func TestStatusReportsConnectingWhileBusy(t *testing.T) {
	m := newTestManager(t, false, nil, errors.New("no device"))
	m.busy.Store(true)

	if got := m.Status().Stage; got != protocol.StageConnecting {
		t.Fatalf("Stage = %q, want connecting", got)
	}
}

func TestCanceledUpCompletesCleanupBeforeReleasingGate(t *testing.T) {
	m := newTestManager(t, false, deviceWithPeers(t), nil)
	started := make(chan struct{})
	calls := &[]runCall{}
	m.run = func(ctx context.Context, name string, args ...string) ([]byte, error) {
		*calls = append(*calls, runCall{name: name, args: args})
		if len(args) > 0 && args[0] == "up" {
			close(started)
			<-ctx.Done()
			return nil, ctx.Err()
		}
		return nil, nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := m.Up(ctx, validConfig)
		done <- err
	}()
	<-started
	cancel()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("Up() = nil, want cancellation error")
		}
	case <-time.After(time.Second):
		t.Fatal("canceled Up did not finish bounded cleanup")
	}
	if len(*calls) != 3 {
		t.Fatalf("cleanup calls = %+v, want up, down, resolver", *calls)
	}
	if (*calls)[1].args[0] != "down" || (*calls)[2].name != resolvconfBinary {
		t.Fatalf("cleanup order = %+v, want down then resolver", *calls)
	}
	if _, err := os.Stat(m.configPath()); !os.IsNotExist(err) {
		t.Fatal("config remained after canceled Up cleanup")
	}
}

func TestRunCommandDeadlineKillsProcessGroup(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	started := time.Now()
	_, err := runCommand(ctx, "/bin/sh", "-c", "sleep 30 & wait")
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("runCommand() error = %v, want context deadline", err)
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("runCommand() took %s after cancellation", elapsed)
	}
}

func TestRunCommandKillsDescendantAfterLeaderExit(t *testing.T) {
	pidFile := filepath.Join(t.TempDir(), "child.pid")
	_, err := runCommand(
		context.Background(),
		"/bin/sh",
		"-c",
		fmt.Sprintf("sleep 60 & echo $! > %q", pidFile),
	)
	if !errors.Is(err, exec.ErrWaitDelay) {
		t.Fatalf("runCommand() error = %v, want exec.ErrWaitDelay", err)
	}

	data, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if err := syscall.Kill(pid, 0); errors.Is(err, syscall.ESRCH) {
			return
		}
		// A killed child may remain as a zombie until the reaper gets it; it
		// is no longer running privileged work in that state.
		if stat, statErr := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid)); statErr == nil {
			fields := strings.Fields(string(stat))
			if len(fields) > 2 && fields[2] == "Z" {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("descendant process %d survived command cleanup", pid)
}

func TestQueuedOperationCanBeCanceledBeforeEnteringManager(t *testing.T) {
	m := newTestManager(t, false, deviceWithPeers(t), nil)
	started := make(chan struct{})
	release := make(chan struct{})
	done := make(chan struct{})
	m.run = func(_ context.Context, _ string, _ ...string) ([]byte, error) {
		close(started)
		<-release
		return nil, nil
	}

	go func() {
		defer close(done)
		if _, err := m.Up(context.Background(), validConfig); err != nil {
			t.Errorf("Up() = %v", err)
		}
	}()
	<-started

	ctx, cancel := context.WithCancel(context.Background())
	downDone := make(chan error, 1)
	go func() {
		_, err := m.Down(ctx)
		downDone <- err
	}()
	cancel()

	var opErr *protocol.OpError
	if err := <-downDone; !errors.As(err, &opErr) || opErr.Code != protocol.CodeUnavailable {
		t.Fatalf("canceled Down() = %v, want unavailable without entering manager", err)
	}

	close(release)
	<-done
}
