package wire

import "github.com/Aqothy/maiD/internal/orchestration"

// Workspace file-search methods back the composer `@file` picker. They are
// part of the trusted maiD client/daemon API only: never forwarded to ACP
// providers, registered as an ACP capability, or callable by a model.
const (
	MethodWorkspaceSearchFiles = "workspace.searchFiles"
)

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
