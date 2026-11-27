package daemon

import (
	"context"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/provider"
)

// completeCommand suggests a slash command's input from a thread's agent,
// which looks in the thread's workspace (a git repository's branches, say).
func (s *Server) completeCommand(ctx context.Context, params wire.ProviderCompleteCommandParams) ([]wire.CommandCompletion, error) {
	agent, err := s.engine.ParticipantSession(ctx, params.Thread, params.Participant)
	if err != nil {
		return nil, err
	}
	completions, err := s.providerService.CompleteCommand(ctx, agent.Instance, provider.CompleteCommandInput{
		Session: agent.Session, Cwd: agent.Workspace.Cwd, Command: params.Command, Input: params.Input,
	})
	if err != nil {
		return nil, err
	}
	// Clients decode an array; a nil slice would encode as null.
	return append([]wire.CommandCompletion{}, completions...), nil
}
