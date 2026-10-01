//go:build linux || windows

// The on-disk record of the bypass routes a live stream transport pinned.
//
// Scoped to the two backends that run a transport: darwin rejects the spec
// outright, so on that build every function here is dead and the unused linter
// says so.
//
// The pin set cannot be re-derived from the config file the way an obfuscated
// tunnel's underlay routes are ([underlayPrefixesFromConfig]): a stream
// transport's config carries the *loopback bridge* as the peer endpoint, so the
// addresses actually pinned are the node's real upstream and appear nowhere in
// it. In-memory state is not enough either — the pins outlive the daemon, and a
// restart loses [liveTransport] while leaving both the routes and the tunnel
// they were cut around. Without this record a restarted daemon would skip the
// teardown entirely and strand a host route through the physical path, which
// silently exempts one destination from every future tunnel.
//
// So the record is written before each route is installed, not after: a crash
// between the two would leak a pin with no trace, while the reverse order
// strands a record naming a route that was never installed. Sweeping a route
// that is not there is already a no-op on both platforms, so over-recording is
// the safe direction to err in.
//
// The encoding is platform-independent — one entry per line, fields separated
// by spaces — and the per-platform decode lives with the backend that installs
// the routes. Linux needs the routing table too, because it pins the same
// prefix in each table wg-quick's policy rules select; Windows needs only the
// address, because a /32 wins on specificity alone.
package tunnel

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"

	"boltmeshd/internal/protocol"
)

// transportPinPath is the root-only record, beside the config in the same
// service-owned directory. It is removed only after every pin it names has been
// swept, mirroring the config file's own keep-until-clean rule.
func (m *Manager) transportPinPath() string {
	return m.configPath() + ".pins"
}

// transportPinsRecorded reports whether a pin record exists, so a teardown with
// no in-memory transport still knows there is something to sweep.
func (m *Manager) transportPinsRecorded() bool {
	_, err := os.Stat(m.transportPinPath())
	return err == nil
}

// writeTransportPinRecord rewrites the record from already-encoded lines.
//
// A write failure is reported rather than logged: continuing would install a
// pin the daemon could no longer account for, which is the leak this record
// exists to prevent.
func (m *Manager) writeTransportPinRecord(lines []string) error {
	var b strings.Builder
	for _, line := range lines {
		b.WriteString(line)
		b.WriteByte('\n')
	}
	if err := os.WriteFile(m.transportPinPath(), []byte(b.String()), 0o600); err != nil {
		return &protocol.OpError{
			Code: protocol.CodeInternal,
			Err:  fmt.Errorf("record transport pins: %w", err),
		}
	}
	return nil
}

// readTransportPinRecord reads the recorded lines back. A missing file is empty
// (a machine that never ran a stream transport, or one already swept); a blank
// line is skipped. Truncation or corruption is deliberately not fatal: the
// caller decodes what it can and every platform's delete path already tolerates
// a route that is not there, so a partial sweep beats refusing to sweep at all.
func (m *Manager) readTransportPinRecord() []string {
	f, err := os.Open(m.transportPinPath())
	if err != nil {
		return nil
	}
	defer func() { _ = f.Close() }()

	var lines []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		if line := strings.TrimSpace(scanner.Text()); line != "" {
			lines = append(lines, line)
		}
	}
	return lines
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

// encodePin renders one pin for the record. Linux appends the routing table so
// a pin fanned across wg-quick's tables can be swept exactly; Windows passes
// the table as absent.
func encodePin(prefix string, table int) string {
	if table == 0 {
		return prefix
	}
	return prefix + " " + strconv.Itoa(table)
}

// decodePin parses one recorded line back into a prefix and table. A line with
// no table is the main table, which is what both platforms record for their
// primary entry.
func decodePin(line string) (prefix string, table int, ok bool) {
	fields := strings.Fields(line)
	if len(fields) == 0 {
		return "", 0, false
	}
	if len(fields) > 1 {
		parsed, err := strconv.Atoi(fields[1])
		if err != nil {
			return "", 0, false
		}
		return fields[0], parsed, true
	}
	return fields[0], 0, true
}
