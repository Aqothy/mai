// Package fff wraps the vendored FFF C library (third_party/fff) behind a
// narrow, memory-safe Go API. Only the path-search lifecycle needed by the
// composer file picker is exposed; glob, grep, directory, and query-history
// APIs stay unwrapped until a feature requires them. No C type or pointer
// escapes this package.
package fff

import (
	"context"
	"errors"
)

// ErrClosed is returned by every method called after Close.
var ErrClosed = errors.New("fff: index is closed")

// ErrUnavailable is returned by New on platforms or builds without the
// native FFF library (anything but a cgo macOS daemon build).
var ErrUnavailable = errors.New("fff: workspace file search requires the macOS cgo daemon build")

// FileMatch is one ranked path result, copied into Go-owned memory.
type FileMatch struct {
	// RelativePath is relative to the index root, e.g. "src/main.go".
	RelativePath string
	// DisplayName is the filename component, e.g. "main.go".
	DisplayName string
}

// ScanProgress reports the state of the index's initial scan and watcher.
type ScanProgress struct {
	ScannedFiles uint64
	Scanning     bool
	WatcherReady bool
}

// Finder is one warm FFF index rooted at a single workspace directory.
// Implementations are safe for concurrent use; Close is idempotent and
// serializes against in-flight calls.
type Finder interface {
	// WaitReady blocks until the initial workspace scan completes or ctx is
	// done. Searching before readiness is allowed but sees a partial index.
	WaitReady(ctx context.Context) error
	// SearchFiles runs one fuzzy path query and returns at most limit
	// matches in rank order. An empty query yields FFF's default ordering.
	SearchFiles(query string, limit int) ([]FileMatch, error)
	ScanProgress() (ScanProgress, error)
	Close() error
}
