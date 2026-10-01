//go:build linux

// The on-disk record of the bypass routes a live stream transport pinned.
//
// The pin set cannot be re-derived from the config file the way an obfuscated
// tunnel's underlay routes are ([underlayPrefixesFromConfig]): a stream
// transport's config carries the *loopback bridge* as the peer endpoint, so the
// addresses actually pinned are the node's real upstream and appear nowhere in
// it. In-memory state is not enough either — the pins outlive the daemon, and
// a restart loses [liveTransport] while leaving both the routes and the tunnel
// they were cut around. Without this record a restarted daemon would skip the
// teardown entirely and strand a host route through the physical path, which
// silently exempts one destination from every future tunnel.
//
// So the record is written before each route is installed, not after: a crash
// between the two would leak a pin with no trace, while the reverse order
// strands a record naming a route that was never installed. Sweeping a route
// that is not there is already a no-op ([Manager.unpinRoute] tolerates it), so
// over-recording is the safe direction to err in.
package tunnel

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"

	"boltmeshd/internal/protocol"
)

// transportPinPath is the root-only record of the pinned prefixes and the
// routing tables they went into, one `prefix table` pair per line. It sits
// beside the config in the same service-owned directory and is removed only
// after every pin it names has been swept, mirroring the config file's own
// keep-until-clean rule.
func (m *Manager) transportPinPath() string {
	return m.configPath() + ".pins"
}

// recordTransportPins rewrites the record to match the live pin set. It is
// called before each install, so the file always names a superset of what is
// actually installed — see the file comment for why that ordering matters.
//
// A write failure is reported rather than logged: continuing would install a
// pin the daemon could no longer account for, which is the leak this record
// exists to prevent.
func (m *Manager) recordTransportPins(pins []transportPin) error {
	var b strings.Builder
	for _, pin := range pins {
		fmt.Fprintf(&b, "%s %d\n", pin.prefix, pin.table)
	}
	if err := os.WriteFile(m.transportPinPath(), []byte(b.String()), 0o600); err != nil {
		return &protocol.OpError{
			Code: protocol.CodeInternal,
			Err:  fmt.Errorf("record transport pins: %w", err),
		}
	}
	return nil
}

// recordedTransportPins reads the pin set back. A missing file is an empty set
// (a machine that never ran a stream transport, or one already swept); a
// malformed line is skipped rather than failing the read, because a partial
// sweep is better than none and the caller already tolerates routes that are
// gone.
func (m *Manager) recordedTransportPins() []transportPin {
	f, err := os.Open(m.transportPinPath())
	if err != nil {
		return nil
	}
	defer func() { _ = f.Close() }()

	var pins []transportPin
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) == 0 {
			continue
		}
		pin := transportPin{prefix: fields[0], v6: strings.Contains(fields[0], ":")}
		if len(fields) > 1 {
			table, convErr := strconv.Atoi(fields[1])
			if convErr != nil {
				continue
			}
			pin.table = table
		}
		pins = append(pins, pin)
	}
	return pins
}

// removeTransportPinRecord deletes the record. It runs only after every named
// pin has been swept, so an interrupted teardown leaves the record behind as
// the handle a retry needs — the same contract the config file keeps.
func (m *Manager) removeTransportPinRecord() error {
	if err := os.Remove(m.transportPinPath()); err != nil && !os.IsNotExist(err) {
		return &protocol.OpError{
			Code: protocol.CodeInternal,
			Err:  fmt.Errorf("remove transport pin record: %w", err),
		}
	}
	return nil
}
