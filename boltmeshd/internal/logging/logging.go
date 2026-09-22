// Package logging wires boltmeshd's structured logging: human-readable records
// on stdout (journald/dev) plus a durable JSON-lines file that keeps failures.
//
// The helper runs as a service. On Windows a service's stdout is discarded, and
// on Linux journald retention is often short, so a failure that leaves no trace
// once the process exits is effectively invisible. The file sink makes those
// failures durable and machine-readable without turning the console into a
// duplicate access log: only [slog.LevelWarn] and above are persisted.
package logging

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
)

// Options configures [Setup].
type Options struct {
	// ConsoleLevel is the minimum level written to Console. Failures are always
	// visible there too; this only raises the floor for noisier levels.
	ConsoleLevel slog.Level

	// Console receives the human-readable records. Defaults to os.Stdout.
	Console io.Writer

	// FilePath is the durable JSON-lines log file. Empty disables file logging.
	// Its parent directory must already exist (the daemon prepares it, so a
	// Windows ACL can be applied first).
	FilePath string

	// FileLevel is the minimum level persisted to FilePath. A zero value
	// selects the [slog.LevelWarn] default; set [slog.LevelDebug] to persist
	// everything.
	FileLevel slog.Level

	// MaxBytes and MaxBackups bound rotation. Zero values use
	// [DefaultMaxBytes] and [DefaultMaxBackups].
	MaxBytes   int64
	MaxBackups int
}

// Setup builds the daemon logger and the closer for its file sink. A console
// handler is always installed; a file handler is added when FilePath is set.
// When the file cannot be opened the console logger is still returned alongside
// the error, so a broken log target degrades instead of blocking startup. The
// caller must close a non-nil closer on shutdown.
func Setup(opts Options) (*slog.Logger, io.Closer, error) {
	console := opts.Console
	if console == nil {
		console = os.Stdout
	}
	handlers := []slog.Handler{
		slog.NewTextHandler(console, &slog.HandlerOptions{Level: opts.ConsoleLevel}),
	}

	var closer io.Closer
	var fileErr error
	if opts.FilePath != "" {
		fileLevel := opts.FileLevel
		if fileLevel == 0 {
			fileLevel = slog.LevelWarn
		}
		w, err := newRotatingWriter(opts.FilePath, opts.MaxBytes, opts.MaxBackups)
		if err != nil {
			fileErr = err
		} else {
			handlers = append(handlers, slog.NewJSONHandler(w, &slog.HandlerOptions{Level: fileLevel}))
			closer = w
		}
	}

	return slog.New(multiHandler(handlers)), closer, fileErr
}

// multiHandler fans one record out to every child handler that wants it. slog
// has no built-in tee, and this keeps the console and file levels independent.
type multiHandler []slog.Handler

func (m multiHandler) Enabled(ctx context.Context, level slog.Level) bool {
	for _, h := range m {
		if h.Enabled(ctx, level) {
			return true
		}
	}
	return false
}

func (m multiHandler) Handle(ctx context.Context, r slog.Record) error {
	var errs []error
	for _, h := range m {
		if !h.Enabled(ctx, r.Level) {
			continue
		}
		if err := h.Handle(ctx, r.Clone()); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

func (m multiHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	out := make(multiHandler, len(m))
	for i, h := range m {
		out[i] = h.WithAttrs(attrs)
	}
	return out
}

func (m multiHandler) WithGroup(name string) slog.Handler {
	out := make(multiHandler, len(m))
	for i, h := range m {
		out[i] = h.WithGroup(name)
	}
	return out
}
