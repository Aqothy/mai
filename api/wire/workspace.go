package wire

import "github.com/Aqothy/maiD/internal/orchestration"

// Workspace browse and file-search methods back trusted client UI. They are
// part of the maiD client/daemon API only: never forwarded to ACP
// providers, registered as an ACP capability, or callable by a model.
const (
	MethodWorkspaceBrowseDirectories = "workspace.browseDirectories"
	MethodWorkspaceSearchFiles       = "workspace.searchFiles"
)

// WorkspaceBrowseDirectoriesParams identifies an absolute directory. An
// omitted path starts at the daemon user's home directory. Browsing is
// daemon-backed so remote clients select paths from the daemon's filesystem,
// not the client device.
type WorkspaceBrowseDirectoriesParams struct {
	Path string `json:"path,omitempty"`
}

// WorkspaceDirectoryEntry is one direct child directory.
type WorkspaceDirectoryEntry struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

// WorkspaceBrowseDirectoriesResult returns the normalized directory, its
// parent when one exists, and alphabetically sorted direct child directories.
type WorkspaceBrowseDirectoriesResult struct {
	Path       string                    `json:"path"`
	ParentPath string                    `json:"parentPath,omitempty"`
	Entries    []WorkspaceDirectoryEntry `json:"entries"`
}

// WorkspaceSearchFilesParams identifies one workspace and one fuzzy path
// query. Exactly one of ThreadID (existing thread; the daemon resolves the
// canonical cwd from orchestration state) or Cwd (local draft; validated
// like a thread-create cwd) must be set. Query is limited to 256 UTF-8
// bytes and may be empty for default ordering. An omitted Limit defaults to
// 50 and is clamped to 1...100.
type WorkspaceSearchFilesParams struct {
	ThreadID orchestration.ThreadID `json:"threadId,omitempty"`
	Cwd      string                 `json:"cwd,omitempty"`
	Query    string                 `json:"query"`
	Limit    int                    `json:"limit,omitempty"`
}

// WorkspaceFileEntry is one ranked result. RelativePath is normalized,
// relative to the workspace root, and never escapes it; native scores and
// absolute paths stay server-private.
type WorkspaceFileEntry struct {
	RelativePath string `json:"relativePath"`
	DisplayName  string `json:"displayName"`
}

// WorkspaceSearchFilesResult carries ranked, deduplicated entries. While the
// workspace's initial scan is still running the daemon returns Indexing true
// with no entries and no error; the client may retry while its trigger stays
// active.
type WorkspaceSearchFilesResult struct {
	Entries  []WorkspaceFileEntry `json:"entries"`
	Indexing bool                 `json:"indexing,omitempty"`
}
