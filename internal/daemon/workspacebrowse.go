package daemon

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/Aqothy/jsonrpc2"
	"github.com/Aqothy/maiD/api/wire"
)

const workspaceBrowsePathMaxBytes = 4_096

// browseWorkspaceDirectories backs folder selection in remote clients. It is
// intentionally read-only and returns directories only; project files remain
// behind the narrower workspace search API.
func (s *Server) browseWorkspaceDirectories(params wire.WorkspaceBrowseDirectoriesParams) (wire.WorkspaceBrowseDirectoriesResult, error) {
	requestedPath := strings.TrimSpace(params.Path)
	if len(requestedPath) > workspaceBrowsePathMaxBytes {
		return wire.WorkspaceBrowseDirectoriesResult{}, fmt.Errorf("%w: path exceeds %d bytes", jsonrpc2.ErrInvalidParams, workspaceBrowsePathMaxBytes)
	}

	resolvedPath, err := resolveWorkspaceBrowsePath(requestedPath)
	if err != nil {
		return wire.WorkspaceBrowseDirectoriesResult{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
	}
	info, err := os.Stat(resolvedPath)
	if err != nil {
		return wire.WorkspaceBrowseDirectoriesResult{}, fmt.Errorf("browse directory %q: %w", resolvedPath, err)
	}
	if !info.IsDir() {
		return wire.WorkspaceBrowseDirectoriesResult{}, fmt.Errorf("%w: path is not a directory", jsonrpc2.ErrInvalidParams)
	}

	dirEntries, err := os.ReadDir(resolvedPath)
	if err != nil {
		return wire.WorkspaceBrowseDirectoriesResult{}, fmt.Errorf("browse directory %q: %w", resolvedPath, err)
	}
	entries := make([]wire.WorkspaceDirectoryEntry, 0, len(dirEntries))
	for _, entry := range dirEntries {
		if !entry.IsDir() {
			continue
		}
		entries = append(entries, wire.WorkspaceDirectoryEntry{
			Name: entry.Name(),
			Path: filepath.Join(resolvedPath, entry.Name()),
		})
	}
	slices.SortFunc(entries, func(left, right wire.WorkspaceDirectoryEntry) int {
		if comparison := strings.Compare(strings.ToLower(left.Name), strings.ToLower(right.Name)); comparison != 0 {
			return comparison
		}
		return strings.Compare(left.Name, right.Name)
	})

	parentPath := filepath.Dir(resolvedPath)
	if parentPath == resolvedPath {
		parentPath = ""
	}
	return wire.WorkspaceBrowseDirectoriesResult{
		Path:       resolvedPath,
		ParentPath: parentPath,
		Entries:    entries,
	}, nil
}

func resolveWorkspaceBrowsePath(requestedPath string) (string, error) {
	if requestedPath == "" {
		homeDirectory, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("resolve home directory: %w", err)
		}
		return filepath.Clean(homeDirectory), nil
	}
	if !filepath.IsAbs(requestedPath) {
		return "", fmt.Errorf("path must be absolute")
	}
	return filepath.Clean(requestedPath), nil
}
