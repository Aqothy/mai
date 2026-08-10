// Package workspacesearch owns the daemon's warm workspace file indexes:
// one FFF index per canonical workspace root, created lazily, evicted when
// idle, and closed on daemon shutdown. It backs the composer `@file` picker
// and is part of the trusted client/daemon API only — never an ACP
// capability or provider tool.
package workspacesearch

import "errors"

// Entry is one ranked file result. Paths are always relative to the
// workspace root; native scores and absolute paths stay server-private.
type Entry struct {
	RelativePath string
	DisplayName  string
}

// Result is one search response. Indexing reports that the workspace's
// initial scan is still running; Entries is empty in that case and the
// caller may simply retry.
type Result struct {
	Entries  []Entry
	Indexing bool
}

var (
	// ErrClosed is returned once the service has shut down.
	ErrClosed = errors.New("workspacesearch: service is closed")
	// ErrInvalidRoot rejects workspace roots that are not absolute paths to
	// existing directories.
	ErrInvalidRoot = errors.New("workspacesearch: invalid workspace root")
	// ErrQueryTooLong rejects queries above MaxQueryBytes.
	ErrQueryTooLong = errors.New("workspacesearch: query exceeds 256 bytes")
)

const (
	// DefaultLimit applies when a request omits its limit.
	DefaultLimit = 50
	// MaxLimit bounds the work a single request can ask for.
	MaxLimit = 100
	// MaxQueryBytes bounds the query in UTF-8 bytes.
	MaxQueryBytes = 256
)
