package logging

import (
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSetupPersistsOnlyFailuresAsJSONL(t *testing.T) {
	path := filepath.Join(t.TempDir(), "boltmeshd.log")
	logger, closer, err := Setup(Options{FilePath: path, Console: io.Discard})
	if err != nil {
		t.Fatalf("Setup: %v", err)
	}
	t.Cleanup(func() { _ = closer.Close() })

	logger.Info("boltmeshd listening")
	logger.Warn("tunnel operation failed", "op", "up", "code", "unavailable")
	logger.Error("boltmeshd stopped", "error", "bind socket: denied")

	lines := strings.Split(strings.TrimSpace(readLog(t, path)), "\n")
	if len(lines) != 2 {
		t.Fatalf("persisted %d records, want 2 (Info must stay console-only): %q", len(lines), lines)
	}
	for i, line := range lines {
		var rec map[string]any
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			t.Fatalf("record %d is not JSON: %v (%q)", i, err, line)
		}
		if rec["msg"] == "" {
			t.Fatalf("record %d has no msg: %v", i, rec)
		}
	}
}

func TestSetupWritesInfoToConsole(t *testing.T) {
	var console strings.Builder
	logger, closer, err := Setup(Options{
		Console:      &console,
		ConsoleLevel: slog.LevelInfo,
		FilePath:     filepath.Join(t.TempDir(), "boltmeshd.log"),
	})
	if err != nil {
		t.Fatalf("Setup: %v", err)
	}
	t.Cleanup(func() { _ = closer.Close() })

	logger.Info("boltmeshd listening")
	if !strings.Contains(console.String(), "boltmeshd listening") {
		t.Fatalf("console = %q, want the Info record", console.String())
	}
}

func TestSetupWithoutFileHasNoCloser(t *testing.T) {
	logger, closer, err := Setup(Options{Console: io.Discard})
	if err != nil {
		t.Fatalf("Setup: %v", err)
	}
	if closer != nil {
		t.Fatalf("closer = %v, want nil when file logging is disabled", closer)
	}
	logger.Warn("still usable")
}

func TestSetupReportsUnopenableFileButKeepsLogger(t *testing.T) {
	path := filepath.Join(t.TempDir(), "missing", "boltmeshd.log")
	logger, closer, err := Setup(Options{FilePath: path, Console: io.Discard})
	if err == nil {
		t.Fatal("Setup succeeded, want an error for a missing parent directory")
	}
	if closer != nil {
		t.Fatalf("closer = %v, want nil on failure", closer)
	}
	if logger == nil {
		t.Fatal("logger = nil, want a console-only logger")
	}
	logger.Warn("console fallback works")
	if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
		t.Fatalf("log file exists after a failed setup: %v", statErr)
	}
}
