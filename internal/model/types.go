package model

import (
	"encoding/json"
	"time"
)

type AgentKind string

const AgentKindACP AgentKind = "acp"

type ConnectionStatus string

const (
	ConnectionStatusInitialized ConnectionStatus = "initialized"
	ConnectionStatusExited      ConnectionStatus = "exited"
)

type AgentCapabilities struct {
	SessionCreate bool `json:"sessionCreate,omitempty"`
	SessionList   bool `json:"sessionList,omitempty"`
	SessionLoad   bool `json:"sessionLoad,omitempty"`
	SessionResume bool `json:"sessionResume,omitempty"`
	SessionClose  bool `json:"sessionClose,omitempty"`
	Prompt        bool `json:"prompt,omitempty"`
	Cancel        bool `json:"cancel,omitempty"`
}

type AgentConnection struct {
	Name          string                     `json:"name"`
	Kind          AgentKind                  `json:"kind"`
	Command       []string                   `json:"command"`
	PID           int                        `json:"pid"`
	Status        ConnectionStatus           `json:"status"`
	StartedAt     time.Time                  `json:"startedAt"`
	InitializedAt time.Time                  `json:"initializedAt"`
	Capabilities  AgentCapabilities          `json:"capabilities"`
	Metadata      map[string]json.RawMessage `json:"metadata,omitempty"`
}

type AgentSessionRequest struct {
	SessionID string          `json:"sessionId,omitempty"`
	Cwd       string          `json:"cwd,omitempty"`
	Options   json.RawMessage `json:"options,omitempty"`
}

type AgentSessionListRequest struct {
	Cwd     string          `json:"cwd,omitempty"`
	Cursor  string          `json:"cursor,omitempty"`
	Options json.RawMessage `json:"options,omitempty"`
}

type AgentThread struct {
	AgentName        string          `json:"agentName"`
	AgentKind        AgentKind       `json:"agentKind"`
	ID               string          `json:"id"`
	BackendSessionID string          `json:"backendSessionId,omitempty"`
	Cwd              string          `json:"cwd,omitempty"`
	Title            *string         `json:"title,omitempty"`
	UpdatedAt        *string         `json:"updatedAt,omitempty"`
	Metadata         map[string]any  `json:"_meta,omitempty"`
	Raw              json.RawMessage `json:"raw,omitempty"`
}

type AgentThreadList struct {
	AgentName  string        `json:"agentName"`
	AgentKind  AgentKind     `json:"agentKind"`
	Threads    []AgentThread `json:"threads"`
	NextCursor *string       `json:"nextCursor,omitempty"`
}
