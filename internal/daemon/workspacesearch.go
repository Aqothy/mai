package daemon

import (
	"context"
	"errors"
	"fmt"

	"github.com/Aqothy/jsonrpc2"
	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/workspacesearch"
)

// searchWorkspaceFiles serves the composer `@file` picker. The root is
// canonical and allowed before the search service may create an index for
// it: a chat's cwd, or a draft's folder the engine allows. Query text is
// never logged.
func (s *Server) searchWorkspaceFiles(ctx context.Context, params wire.WorkspaceSearchFilesParams) (wire.WorkspaceSearchFilesResult, error) {
	hasThread := params.ThreadID != ""
	hasCwd := params.Cwd != ""
	if hasThread == hasCwd {
		return wire.WorkspaceSearchFilesResult{}, fmt.Errorf("%w: workspace.searchFiles requires exactly one of threadId or cwd", jsonrpc2.ErrInvalidParams)
	}

	var root string
	if hasThread {
		workspace, err := s.engine.Workspace(ctx, params.ThreadID)
		if err != nil {
			return wire.WorkspaceSearchFilesResult{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
		}
		root = workspace.Cwd
	} else {
		var err error
		if root, err = s.engine.WorkspaceRoot(ctx, params.Cwd); err != nil {
			return wire.WorkspaceSearchFilesResult{}, err
		}
	}

	result, err := s.workspaceSearch.Search(ctx, root, params.Query, params.Limit)
	if err != nil {
		if errors.Is(err, workspacesearch.ErrQueryTooLong) {
			return wire.WorkspaceSearchFilesResult{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
		}
		return wire.WorkspaceSearchFilesResult{}, err
	}

	entries := make([]wire.WorkspaceFileEntry, len(result.Entries))
	for i, entry := range result.Entries {
		entries[i] = wire.WorkspaceFileEntry{RelativePath: entry.RelativePath, DisplayName: entry.DisplayName}
	}
	return wire.WorkspaceSearchFilesResult{Entries: entries, Indexing: result.Indexing}, nil
}
