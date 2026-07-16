// Package store persists thread and provider-session metadata.
// Conversation history remains provider-owned.
package store

import (
	"encoding/json"
	"errors"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// ErrProviderSessionBound reports an attempt to bind one provider session to
// more than one maiD thread.
var ErrProviderSessionBound = errors.New("provider session is already bound")

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

// ImportStore atomically persists one externally owned provider session as a
// maiD thread. If the provider session was already imported, ImportThread
// returns its existing thread id and imported=false.
type ImportStore interface {
	ImportThread(meta ThreadMeta, route RouteRecord) (threadID string, imported bool, err error)
}
