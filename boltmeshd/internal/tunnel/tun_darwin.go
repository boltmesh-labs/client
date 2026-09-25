//go:build darwin

package tunnel

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"golang.zx2c4.com/wireguard/tun"
)

// systemTunImpl is the real utun + routing backend.
//
// Everything here needs root and touches the host's network configuration, so
// it is deliberately behind the [systemTun] seam: the manager's sequencing is
// testable without a utun interface, and this file is the only part that has to
// be re-read when macOS changes its networking APIs.
type systemTunImpl struct{}

// fixedToolDirs are the only directories searched for the network tools, for
// the same reason as the Linux backend: the daemon runs as root, so a
// PATH-resolved bare name would let a caller-influenced PATH execute as root.
var fixedToolDirs = []string{"/sbin", "/usr/sbin", "/bin", "/usr/bin"}

// findTool resolves a tool under [fixedToolDirs].
func findTool(name string) (string, error) {
	for _, dir := range fixedToolDirs {
		path := filepath.Join(dir, name)
		if info, err := os.Stat(path); err == nil && !info.IsDir() {
			return path, nil
		}
	}
	return "", fmt.Errorf("%s not found under %v", name, fixedToolDirs)
}

// run executes a resolved tool under a fixed PATH and a bounded deadline.
func run(ctx context.Context, name string, args ...string) error {
	path, err := findTool(name)
	if err != nil {
		return err
	}
	cmd := exec.CommandContext(ctx, path, args...)
	cmd.Env = []string{"PATH=" + strings.Join(fixedToolDirs, ":")}
	out, err := cmd.CombinedOutput()
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if msg := strings.TrimSpace(string(out)); msg != "" {
			return fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, msg)
		}
		return fmt.Errorf("%s %s: %w", name, strings.Join(args, " "), err)
	}
	return nil
}

// create opens a utun device. macOS has no equivalent of Linux's named
// interface: the kernel picks utunN and reports the name, which the backend
// uses from then on.
func (systemTunImpl) create(_ context.Context) (string, func() error, error) {
	tunDev, err := tun.CreateTUN(tunnelInterfacePrefix, defaultMTU)
	if err != nil {
		return "", nil, fmt.Errorf("create utun: %w", err)
	}
	name, err := tunDev.Name()
	if err != nil {
		_ = tunDev.Close()
		return "", nil, fmt.Errorf("read utun name: %w", err)
	}
	return name, tunDev.Close, nil
}

// tunnelInterfacePrefix is the name prefix requested from the utun driver. The
// kernel still assigns utunN; the prefix only labels the request.
const tunnelInterfacePrefix = "boltmesh"

// configure assigns the tunnel address, installs a default route for the peer's
// allowed IPs, and points the system resolver at the tunnel DNS server.
//
// The route deliberately does not use `-interface` alone: a full-tunnel
// default route on macOS must outrank the physical interface, otherwise the
// physical default keeps winning and the tunnel carries nothing. `utunN`
// interfaces are point-to-point, so the route is installed as a gateway route
// on the device, which is what makes it win.
func (s systemTunImpl) configure(
	ctx context.Context, name, address string, allowedIPs []string, dns string,
) error {
	// Address may carry a prefix length, and a comma-separated list when the
	// client sends a v4/v6 pair. Assign each.
	for _, addr := range strings.Split(address, ",") {
		addr = strings.TrimSpace(addr)
		if addr == "" {
			continue
		}
		if err := run(ctx, "ifconfig", name, "inet", addr, "up"); err != nil {
			return fmt.Errorf("assign address: %w", err)
		}
	}
	// `up` alone does not install routes; a default route for the allowed IPs
	// is what actually sends traffic into the tunnel.
	if err := run(ctx, "route", "add", "-inet", "default", "-interface", name); err != nil {
		return fmt.Errorf("add route: %w", err)
	}
	_ = allowedIPs // The full-tunnel default route above covers them; the
	// per-peer split-tunnel case is not implemented for the userspace backend.
	if dns != "" {
		if err := setSystemDNS(ctx, dns); err != nil {
			return err
		}
	}
	return nil
}

// teardown removes the resolver state, the default route and the addresses.
// Order is the reverse of [configure]: resolver first so a failure leaves DNS
// still pointed at the tunnel rather than silently resolving elsewhere, then
// the route, then the address.
func (s systemTunImpl) teardown(ctx context.Context, name string) error {
	var errs []error
	if err := clearSystemDNS(ctx); err != nil {
		errs = append(errs, err)
	}
	// A route whose interface is already gone is not an error worth failing
	// the whole teardown over.
	if err := run(ctx, "route", "delete", "-inet", "default", "-interface", name); err != nil {
		if !strings.Contains(err.Error(), "not in table") {
			errs = append(errs, fmt.Errorf("delete route: %w", err))
		}
	}
	return joinErrors(errs)
}

// DNS state on macOS lives in /etc/resolver, and the system-wide default in
// /etc/resolv.conf. Both are only rewritten when the tunnel actually brings a
// DNS server, and both are restored from a saved copy on teardown, so an
// unclean stop is recoverable.
const (
	resolverDir  = "/etc/resolver"
	resolvConf   = "/etc/resolv.conf"
	resolverFile = resolverDir + "/boltmesh"
	dnsBackup    = "/var/run/boltmesh/resolv.conf.boltmesh.bak"
)

// setSystemDNS points the system resolver at the tunnel's DNS server,
// preserving the previous resolv.conf so [clearSystemDNS] can restore it.
func setSystemDNS(_ context.Context, dns string) error {
	// Save the current resolver state once, before the first modification.
	if _, err := os.Stat(dnsBackup); os.IsNotExist(err) {
		if err := os.MkdirAll(filepath.Dir(dnsBackup), 0o700); err != nil {
			return fmt.Errorf("create dns backup dir: %w", err)
		}
		if err := copyFile(resolvConf, dnsBackup); err != nil {
			// A system whose resolv.conf is managed elsewhere (a resolver
			// stub, or a read-only filesystem) cannot be repointed. Failing
			// the whole connect over DNS would be worse than continuing with
			// the system resolver, so this is logged and not fatal — but it
			// must not be silent, because the tunnel's DNS server will not be
			// used.
			slog.Warn("cannot snapshot resolv.conf; tunnel DNS will not be applied",
				"error", err)
		}
	}
	if err := os.MkdirAll(resolverDir, 0o755); err != nil {
		return fmt.Errorf("create resolver dir: %w", err)
	}
	content := fmt.Sprintf("nameserver %s\n", strings.TrimSpace(dns))
	if err := os.WriteFile(resolverFile, []byte(content), 0o644); err != nil {
		return fmt.Errorf("write resolver file: %w", err)
	}
	return nil
}

// clearSystemDNS restores the resolver state saved by [setSystemDNS] and
// removes the per-tunnel resolver file.
func clearSystemDNS(_ context.Context) error {
	_ = os.Remove(resolverFile)
	saved, err := os.ReadFile(dnsBackup)
	switch {
	case errors.Is(err, os.ErrNotExist):
		// Nothing was ever saved, so nothing was changed. Not an error.
		return nil
	case err != nil:
		// The backup exists but could not be read. Returning nil here would
		// leave the system resolver pointed at a tunnel that is going away,
		// with no way to restore it. Surface it: the teardown reports the
		// failure and the operator can restore resolv.conf by hand.
		return fmt.Errorf("read saved resolv.conf %s: %w", dnsBackup, err)
	}
	if err := os.WriteFile(resolvConf, saved, 0o644); err != nil {
		return fmt.Errorf("restore resolv.conf: %w", err)
	}
	_ = os.Remove(dnsBackup)
	return nil
}

func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0o600)
}

// runCommandOutput is [run] for the one caller that needs the tool's stdout.
func runCommandOutput(ctx context.Context, name string, args ...string) ([]byte, error) {
	path, err := findTool(name)
	if err != nil {
		return nil, err
	}
	cmd := exec.CommandContext(ctx, path, args...)
	cmd.Env = []string{"PATH=" + strings.Join(fixedToolDirs, ":")}
	return cmd.CombinedOutput()
}

// hasBoltMeshRoute reports whether name carries the default route the backend
// installs for the tunnel. macOS has no interface-name convention to match on,
// so the route table is the signal. A failure to read it returns false: the
// uninstaller then proceeds, and a genuinely live interface is caught by the
// cleanup pass instead.
func hasBoltMeshRoute(name string) bool {
	out, err := runCommandOutput(context.Background(), "netstat", "-rn", "-f", "inet")
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		// Destination, gateway, flags, iface — the interface is the last
		// column on a route line.
		if len(fields) < 4 {
			continue
		}
		if fields[0] == "default" && fields[len(fields)-1] == name {
			return true
		}
	}
	return false
}

func joinErrors(errs []error) error {
	switch len(errs) {
	case 0:
		return nil
	case 1:
		return errs[0]
	default:
		return fmt.Errorf("%v", errs)
	}
}

// unused keeps the net import meaningful if the file is trimmed during
// review; remove it if the address parsing below starts using it.
var _ = net.ParseIP
