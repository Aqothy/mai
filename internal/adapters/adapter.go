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

type Adapter interface {
	StartConnection(ctx context.Context, req StartConnectionRequest) (ConnectionHandle, error)
}
