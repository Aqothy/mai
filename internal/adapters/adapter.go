package adapters

import (
	"context"

	"github.com/Aqothy/maiD/internal/model"
)

type StartConnectionRequest struct {
	Name    string
	Kind    model.AgentKind
	Command []string
}

type ConnectionHandle interface {
	Info() model.AgentConnection
	Close() error
}

type Authenticator interface {
	Authenticate(ctx context.Context, methodID string) (model.AgentConnection, error)
	Logout(ctx context.Context) (model.AgentConnection, error)
}

type SessionManager interface {
	NewSession(ctx context.Context, req model.AgentSessionRequest) (model.AgentThread, error)
	LoadSession(ctx context.Context, req model.AgentSessionRequest) (model.AgentThread, error)
	ResumeSession(ctx context.Context, req model.AgentSessionRequest) (model.AgentThread, error)
	CloseSession(ctx context.Context, sessionID string) (model.AgentThread, error)
	ListSessions(ctx context.Context, req model.AgentSessionListRequest) (model.AgentThreadList, error)
}

type Adapter interface {
	StartConnection(ctx context.Context, req StartConnectionRequest) (ConnectionHandle, error)
}
