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

type CapabilitySet struct {
	Sessions bool `json:"sessions"`
	Prompt   bool `json:"prompt"`
	Cancel   bool `json:"cancel"`
	Models   bool `json:"models,omitempty"`
	Modes    bool `json:"modes,omitempty"`
	Terminal bool `json:"terminal,omitempty"`
}

type ACPMetadata struct {
	AgentInfo         any             `json:"agentInfo,omitempty"`
	AgentCapabilities map[string]any  `json:"agentCapabilities,omitempty"`
	AuthMethods       []any           `json:"authMethods"`
	RawInitialize     json.RawMessage `json:"rawInitialize,omitempty"`
}

type AgentConnection struct {
	Name          string           `json:"name"`
	Kind          AgentKind        `json:"kind"`
	Command       []string         `json:"command"`
	PID           int              `json:"pid"`
	Status        ConnectionStatus `json:"status"`
	StartedAt     time.Time        `json:"startedAt"`
	InitializedAt time.Time        `json:"initializedAt"`
	Capabilities  CapabilitySet    `json:"capabilities"`

	ACP *ACPMetadata `json:"acp,omitempty"`
}
