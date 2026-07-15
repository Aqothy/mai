package orchestration

import (
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// RestoredThread is one thread stub rehydrated from the metadata store: the
// sidebar fields only. History stays provider-owned — the timeline starts
// empty and is rebuilt by provider replay when the thread is reopened.
type RestoredThread struct {
	ThreadID           ThreadID
	Title              string
	Cwd                string
	ProviderInstanceID provider.InstanceID
	ModelSelection     *provider.ModelSelection
	CreatedAt          time.Time
	UpdatedAt          time.Time
}

// RestoreThreads seeds the projection with thread stubs at boot, before the
// daemon serves connections. No events are appended: a restart is a new epoch
// (sequences reset and clients resnapshot), so restored threads exist in the
// projection but not in this epoch's event log. Threads already present are
// left untouched.
func (e *Engine) RestoreThreads(threads []RestoredThread) {
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, thread := range threads {
		e.projection.restoreThread(thread)
	}
}

// restoreThread installs a stub with no session binding (idle) and an empty
// timeline, preserving the stored timestamps for sidebar ordering.
func (p *Projection) restoreThread(stub RestoredThread) {
	if stub.ThreadID == "" || p.threads[stub.ThreadID] != nil {
		return
	}
	title := stub.Title
	if title == "" {
		title = "Untitled thread"
	}
	p.threads[stub.ThreadID] = &Thread{
		ID:                   stub.ThreadID,
		Draft:                false,
		ReplayHistoryPending: true,
		Title:                title,
		ProviderInstanceID:   stub.ProviderInstanceID,
		ModelSelection:       cloneModelSelection(stub.ModelSelection),
		Cwd:                  stub.Cwd,
		Timeline:             Timeline{},
		CreatedAt:            stub.CreatedAt,
		UpdatedAt:            stub.UpdatedAt,
	}
	if stub.UpdatedAt.After(p.updatedAt) {
		p.updatedAt = stub.UpdatedAt
	}
}
