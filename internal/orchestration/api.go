package orchestration

import (
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

type ThreadListEntry struct {
	ID                  ThreadID                 `json:"id"`
	Draft               bool                     `json:"draft"`
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
	SnapshotSequence uint64 `json:"snapshotSequence"`
	Thread           Thread `json:"thread"`
}

type ThreadListSnapshot struct {
	SnapshotSequence uint64            `json:"snapshotSequence"`
	Threads          []ThreadListEntry `json:"threads"`
	UpdatedAt        time.Time         `json:"updatedAt"`
}

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
