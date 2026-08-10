//go:build !darwin || !arm64 || !cgo

package fff

// New reports the feature unavailable. Workspace file search ships only in
// the cgo Apple Silicon macOS daemon build that links the vendored FFF library.
func New(string) (Finder, error) {
	return nil, ErrUnavailable
}
