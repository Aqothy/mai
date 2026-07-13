// Package store persists thread and provider-session metadata.
// Conversation history remains provider-owned.
package store

import (
	"encoding/json"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// RouteRecord contains the metadata needed to restore a provider session route.
type RouteRecord struct {
	InstanceID        provider.InstanceID
	ProviderSessionID string
	ResumeCursor      json.RawMessage
	StartInput        provider.StartSessionInput
}

// RouteStore persists provider instance specs and thread-to-session routes.
type RouteStore interface {
	SaveRoute(threadID string, record RouteRecord) error
	DeleteRoute(threadID string) error
	LoadRoutes() (map[string]RouteRecord, error)

	SaveInstance(spec provider.InstanceSpec) error
	LoadInstances() ([]provider.InstanceSpec, error)
}

// ThreadMeta contains durable thread-list metadata.
type ThreadMeta struct {
	ThreadID           string
	Title              string
	Cwd                string
	ProviderInstanceID provider.InstanceID
	ModelSelection     *provider.ModelSelection
	CreatedAt          time.Time
	UpdatedAt          time.Time
}

// ThreadStore persists thread-list metadata.
type ThreadStore interface {
	UpsertThread(meta ThreadMeta) error
	ListThreads() ([]ThreadMeta, error)
}
