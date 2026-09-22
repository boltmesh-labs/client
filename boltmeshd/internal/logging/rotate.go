package logging

import (
	"fmt"
	"os"
	"sync"
)

// Defaults bounding the persistent failure log. Five files of at most five
// MiB each cap the on-disk footprint at ~25 MiB.
const (
	DefaultMaxBytes   int64 = 5 << 20
	DefaultMaxBackups       = 5
)

// rotatingWriter appends to one log file and rotates it once the next record
// would push it past maxBytes, keeping at most maxBackups rotated files
// (`path`, `path.1` … `path.N`, newest first). It is safe for concurrent use:
// slog handlers are called from every connection goroutine.
//
// Writes are best-effort. A rotation or reopen failure surfaces as a write
// error, which slog discards; a logging fault must never take the daemon down.
type rotatingWriter struct {
	path       string
	maxBytes   int64
	maxBackups int

	mu   sync.Mutex
	file *os.File
	size int64
}

func newRotatingWriter(path string, maxBytes int64, maxBackups int) (*rotatingWriter, error) {
	if maxBytes <= 0 {
		maxBytes = DefaultMaxBytes
	}
	if maxBackups < 0 {
		maxBackups = DefaultMaxBackups
	}
	w := &rotatingWriter{path: path, maxBytes: maxBytes, maxBackups: maxBackups}
	if err := w.open(); err != nil {
		return nil, err
	}
	// An already-oversized file (a crash between rotations, or a lowered cap)
	// is rotated before the next record so maxBytes stays a real ceiling.
	if w.size > 0 && w.size >= w.maxBytes {
		if err := w.rotate(); err != nil {
			return nil, err
		}
	}
	return w, nil
}

func (w *rotatingWriter) open() error {
	f, err := os.OpenFile(w.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	info, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return err
	}
	w.file = f
	w.size = info.Size()
	return nil
}

func (w *rotatingWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()

	if w.file == nil {
		if err := w.open(); err != nil {
			return 0, err
		}
	}
	// Rotate first: slog emits one whole record per Write, so the record must
	// not straddle two files.
	if w.size > 0 && w.size+int64(len(p)) > w.maxBytes {
		if err := w.rotate(); err != nil {
			return 0, err
		}
	}
	n, err := w.file.Write(p)
	w.size += int64(n)
	return n, err
}

func (w *rotatingWriter) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.file == nil {
		return nil
	}
	err := w.file.Close()
	w.file = nil
	return err
}

// rotate closes the active file and shifts `path` → `path.1`, `path.1` →
// `path.2` …, dropping anything past maxBackups. With maxBackups zero the
// active file is removed instead of retained.
func (w *rotatingWriter) rotate() error {
	if w.file != nil {
		if err := w.file.Close(); err != nil {
			return err
		}
		w.file = nil
	}

	if w.maxBackups > 0 {
		if err := os.Remove(backupPath(w.path, w.maxBackups)); err != nil && !os.IsNotExist(err) {
			return err
		}
		for i := w.maxBackups - 1; i >= 1; i-- {
			from := backupPath(w.path, i)
			if _, err := os.Stat(from); err != nil {
				continue
			}
			if err := os.Rename(from, backupPath(w.path, i+1)); err != nil {
				return err
			}
		}
		if err := os.Rename(w.path, backupPath(w.path, 1)); err != nil && !os.IsNotExist(err) {
			return err
		}
	} else if err := os.Remove(w.path); err != nil && !os.IsNotExist(err) {
		return err
	}

	w.size = 0
	return w.open()
}

func backupPath(path string, n int) string {
	return fmt.Sprintf("%s.%d", path, n)
}
