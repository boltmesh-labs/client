package logging

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func readLog(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(data)
}

func TestRotatingWriterRotatesAtThreshold(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "boltmeshd.log")
	w, err := newRotatingWriter(path, 10, 2)
	if err != nil {
		t.Fatalf("newRotatingWriter: %v", err)
	}
	t.Cleanup(func() { _ = w.Close() })

	// Each record is nine bytes; the second write trips the ten-byte cap.
	for _, record := range []string{"aaaaaaaa", "bbbbbbbb", "cccccccc"} {
		if _, err := w.Write([]byte(record + "\n")); err != nil {
			t.Fatalf("write %q: %v", record, err)
		}
	}

	if got := strings.TrimSpace(readLog(t, path)); got != "cccccccc" {
		t.Fatalf("active log = %q, want cccccccc", got)
	}
	if got := strings.TrimSpace(readLog(t, path+".1")); got != "bbbbbbbb" {
		t.Fatalf("first backup = %q, want bbbbbbbb", got)
	}
	if got := strings.TrimSpace(readLog(t, path+".2")); got != "aaaaaaaa" {
		t.Fatalf("second backup = %q, want aaaaaaaa", got)
	}
}

func TestRotatingWriterDropsOldestBackup(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "boltmeshd.log")
	w, err := newRotatingWriter(path, 5, 1)
	if err != nil {
		t.Fatalf("newRotatingWriter: %v", err)
	}
	t.Cleanup(func() { _ = w.Close() })

	for _, record := range []string{"aaaa", "bbbb", "cccc"} {
		if _, err := w.Write([]byte(record + "\n")); err != nil {
			t.Fatalf("write %q: %v", record, err)
		}
	}

	if got := strings.TrimSpace(readLog(t, path)); got != "cccc" {
		t.Fatalf("active log = %q, want cccc", got)
	}
	if got := strings.TrimSpace(readLog(t, path+".1")); got != "bbbb" {
		t.Fatalf("first backup = %q, want bbbb", got)
	}
	if _, err := os.Stat(path + ".2"); !os.IsNotExist(err) {
		t.Fatalf("second backup exists, want capped at one: %v", err)
	}
}

func TestRotatingWriterRotatesOversizedFileOnOpen(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "boltmeshd.log")
	if err := os.WriteFile(path, []byte("0123456789"), 0o600); err != nil {
		t.Fatal(err)
	}

	w, err := newRotatingWriter(path, 5, 1)
	if err != nil {
		t.Fatalf("newRotatingWriter: %v", err)
	}
	t.Cleanup(func() { _ = w.Close() })

	if _, err := w.Write([]byte("new\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	if got := strings.TrimSpace(readLog(t, path)); got != "new" {
		t.Fatalf("active log = %q, want new", got)
	}
	if got := strings.TrimSpace(readLog(t, path+".1")); got != "0123456789" {
		t.Fatalf("backup = %q, want the oversized prior file", got)
	}
}

func TestRotatingWriterCreatesPrivateFile(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX file modes do not apply on Windows")
	}
	path := filepath.Join(t.TempDir(), "boltmeshd.log")
	w, err := newRotatingWriter(path, 0, 0)
	if err != nil {
		t.Fatalf("newRotatingWriter: %v", err)
	}
	t.Cleanup(func() { _ = w.Close() })

	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("log mode = %o, want 600", perm)
	}
}
