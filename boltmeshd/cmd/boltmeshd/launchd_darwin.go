//go:build darwin

package main

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"boltmeshd/internal/tunnel"
)

// launchdLabel is the reverse-DNS label for the LaunchDaemon. It must match the
// Label key in the generated plist and is what `launchctl` addresses.
const launchdLabel = "com.boltmesh.boltmeshd"

// plistTemplate is the LaunchDaemon job definition. KeepLaunchAlive restarts
// the daemon after an unexpected exit; RunAtLoad starts it on install.
// StandardOutPath/StandardErrorPath duplicate the JSON-lines log for anything
// launchd itself reports (a crash before logging is configured, for instance).
const plistTemplate = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>` + launchdLabel + `</string>
	<key>ProgramArguments</key>
	<array>
		<string>%s</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>WorkingDirectory</key>
	<string>/</string>
	<key>StandardOutPath</key>
	<string>%s/launchd.log</string>
	<key>StandardErrorPath</key>
	<string>%s/launchd.log</string>
</dict>
</plist>
`

func plistPath() string { return filepath.Join(darwinPlistDir, launchdLabel+".plist") }

// launchctl talks to launchd over its Unix socket. It is the only supported
// way to load a job, and it requires root.
func launchctl(args ...string) ([]byte, error) {
	cmd := exec.Command("/bin/launchctl", args...)
	cmd.Env = []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin"}
	return cmd.CombinedOutput()
}

// daemonBinary resolves the absolute path of the running executable, so the
// plist does not depend on a PATH lookup at load time. launchd starts jobs
// with a minimal environment, and a relative path would resolve against
// `/` (the configured WorkingDirectory).
func daemonBinary() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	resolved, err := filepath.EvalSymlinks(exe)
	if errors.Is(err, os.ErrNotExist) {
		// A path that does not resolve yet is still a usable answer: the
		// installer may be staging the binary where it will live. Anything
		// else (a permission error, a symlink loop) would silently produce a
		// plist pointing at the wrong binary, so it is surfaced.
		return exe, nil
	}
	if err != nil {
		return "", fmt.Errorf("resolve daemon binary %q: %w", exe, err)
	}
	return resolved, nil
}

// installLaunchDaemon writes the plist and loads it. The existing job is
// booted out first so a reinstall cannot leave a stale process holding the old
// binary and the old socket, mirroring the Windows reinstall fix.
func installLaunchDaemon(opts options) error {
	if os.Geteuid() != 0 {
		return errors.New("install requires root")
	}
	if err := prepareLogFile(opts.logFile); err != nil {
		return fmt.Errorf("prepare log directory: %w", err)
	}

	// Boot out a previously loaded job before replacing the plist. A missing
	// job is the normal first-install case, so its error is not fatal.
	if out, err := launchctl("bootout", "system/"+launchdLabel); err != nil {
		if !strings.Contains(string(out), "could not find service") &&
			!strings.Contains(string(out), "No such process") {
			return fmt.Errorf("bootout existing daemon: %w: %s", err, out)
		}
	}

	exe, err := daemonBinary()
	if err != nil {
		return fmt.Errorf("resolve daemon binary: %w", err)
	}
	plist := fmt.Sprintf(plistTemplate, exe, darwinLogDir, darwinLogDir)

	path := plistPath()
	// Write via a temporary file and rename so launchd never reads a
	// half-written plist. The directory is root-owned, so the rename is
	// atomic with respect to any other actor.
	tmp, err := os.CreateTemp(darwinPlistDir, ".boltmeshd-*.plist")
	if err != nil {
		return fmt.Errorf("stage plist: %w", err)
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }()
	if _, err := tmp.WriteString(plist); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("write plist: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("write plist: %w", err)
	}
	if err := os.Chmod(tmpName, 0o644); err != nil {
		return fmt.Errorf("chmod plist: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("install plist: %w", err)
	}

	if out, err := launchctl("bootstrap", "system", path); err != nil {
		return fmt.Errorf("bootstrap daemon: %w: %s", err, out)
	}
	// bootstrap starts a RunAtLoad job; kickstart makes the intent explicit
	// and surfaces a job that loaded but refused to run.
	if out, err := launchctl("kickstart", "-k", "system/"+launchdLabel); err != nil {
		return fmt.Errorf("kickstart daemon: %w: %s", err, out)
	}
	return nil
}

// uninstallLaunchDaemon tears the tunnel down before removing the job, so a
// stopped daemon never orphans a live userspace device. It fails closed: if the
// job is still loaded, or the interface is still up, the removal is refused
// rather than completing with privileged state left behind.
func uninstallLaunchDaemon(opts options) error {
	if os.Geteuid() != 0 {
		return errors.New("uninstall requires root")
	}

	// Tear the tunnel down first, while the daemon is still running to service
	// the request if it is up. A daemon that is not running has nothing to tear
	// down, so only a genuinely live device must block removal.
	if err := cleanupFromOptions(opts); err != nil {
		if !errors.Is(err, errTunnelNotLoaded) {
			slog.Warn("tunnel cleanup during uninstall reported an error", "error", err)
		}
	}

	// bootout the job.
	if out, err := launchctl("bootout", "system/"+launchdLabel); err != nil {
		if !strings.Contains(string(out), "could not find service") &&
			!strings.Contains(string(out), "No such process") {
			return fmt.Errorf("bootout daemon: %w: %s", err, out)
		}
	}

	// Fail closed: if the job is still loaded, privileged state survives.
	if err := waitForJobGone(30 * time.Second); err != nil {
		return err
	}

	// A userspace device is a goroutine in the daemon, so a stopped daemon
	// cannot leave a live one behind. The utun interface, however, outlives the
	// process if the route was installed: refuse to finish while one is still
	// present rather than removing the job definition and stranding it.
	if name := tunnel.LiveTunnelInterface(); name != "" {
		return fmt.Errorf(
			"uninstall incomplete: tunnel interface %s is still present; "+
				"remove it (ifconfig %s down) before uninstalling", name, name)
	}

	if err := os.Remove(plistPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove plist: %w", err)
	}
	return nil
}

// errTunnelNotLoaded marks a cleanup that found no daemon to talk to. It is
// distinct from a cleanup that failed, so the uninstaller can tell "nothing
// was running" from "something is wrong".
var errTunnelNotLoaded = errors.New("tunnel cleanup: daemon not running")

// waitForJobGone polls until launchd no longer reports the job loaded. bootout
// is asynchronous, so removing the plist immediately could race a job that is
// still shutting down and would then keep running with no job definition.
func waitForJobGone(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		out, err := launchctl("print", "system/"+launchdLabel)
		if err != nil || !strings.Contains(string(out), "state = running") {
			if !strings.Contains(string(out), launchdLabel) {
				return nil
			}
			if err != nil {
				return fmt.Errorf("query daemon state: %w: %s", err, out)
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("daemon %s is still loaded after %s", launchdLabel, timeout)
		}
		time.Sleep(250 * time.Millisecond)
	}
}
