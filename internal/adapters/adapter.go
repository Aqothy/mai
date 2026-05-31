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

type Adapter interface {
	StartConnection(ctx context.Context, req StartConnectionRequest) (ConnectionHandle, error)
}
