package orchestration

import (
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

type ThreadListEntry struct {
	ID                  ThreadID                 `json:"id"`
	Title               string                   `json:"title"`
	ProviderInstanceID  provider.InstanceID      `json:"providerInstanceId,omitempty"`
	ModelSelection      *provider.ModelSelection `json:"modelSelection,omitempty"`
	Cwd                 string                   `json:"cwd,omitempty"`
	LatestTurn          *Turn                    `json:"latestTurn,omitempty"`
	CreatedAt           time.Time                `json:"createdAt"`
	UpdatedAt           time.Time                `json:"updatedAt"`
	Session             *SessionBinding          `json:"session,omitempty"`
	HasPendingApprovals bool                     `json:"hasPendingApprovals"`
}

type ThreadDetailSnapshot struct {
	// HistoryRestorePending is true while the daemon's persisted metadata stub
	// has not yet been fully materialized from provider-owned history.
	// Omission means ready, preserving compatibility with older clients.
	HistoryRestorePending bool   `json:"historyRestorePending,omitempty"`
	SnapshotSequence      uint64 `json:"snapshotSequence"`
	Thread                Thread `json:"thread"`
}

type ThreadListSnapshot struct {
	SnapshotSequence uint64            `json:"snapshotSequence"`
	Threads          []ThreadListEntry `json:"threads"`
	UpdatedAt        time.Time         `json:"updatedAt"`
}

// StreamItemKind is an alias, not a defined type, for the same reason as
// CommandType: the wire field stays a plain string so an unknown kind decodes
// and is ignored instead of failing the whole notification.
type StreamItemKind = string

// Clients branch on these rather than on which optional field is populated.
const (
	StreamItemSnapshot       StreamItemKind = "snapshot"
	StreamItemEvent          StreamItemKind = "event"
	StreamItemThreadUpserted StreamItemKind = "thread-upserted"
)

type ThreadStreamItem struct {
	Kind     string                `json:"kind"`
	Snapshot *ThreadDetailSnapshot `json:"snapshot,omitempty"`
	Event    *Event                `json:"event,omitempty"`
}

type ThreadListStreamItem struct {
	Kind     string              `json:"kind"`
	Snapshot *ThreadListSnapshot `json:"snapshot,omitempty"`
	Sequence uint64              `json:"sequence,omitempty"`
	Thread   *ThreadListEntry    `json:"thread,omitempty"`
}

type SubscribeThreadInput struct {
	ThreadID ThreadID `json:"threadId"`
}

type GetItemDetailInput struct {
	ThreadID ThreadID `json:"threadId"`
	ItemID   string   `json:"itemId"`
}
