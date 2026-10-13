package daemon

import (
	"context"
	"fmt"

	"github.com/Aqothy/jsonrpc2"
	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/orchestration"
)

// completeCommand suggests a slash command's input from the thread's provider,
// which looks in the thread's workspace (a git repository's branches, say).
func (s *Server) completeCommand(ctx context.Context, params wire.ProviderCompleteCommandParams) ([]wire.CommandCompletion, error) {
	cwd, ok := s.orchestration.ThreadCwd(orchestration.ThreadID(params.ThreadID))
	if !ok {
		return nil, fmt.Errorf("%w: unknown thread %q", jsonrpc2.ErrInvalidParams, params.ThreadID)
	}
	params.Cwd = cwd
	completions, err := s.providerService.CompleteCommand(ctx, params)
	if err != nil {
		return nil, err
	}
	// Clients decode an array; a nil slice would encode as null.
	return append([]wire.CommandCompletion{}, completions...), nil
}
