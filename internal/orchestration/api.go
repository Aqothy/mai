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
	RuntimeMode         RuntimeMode              `json:"runtimeMode"`
	InteractionMode     ProviderInteractionMode  `json:"interactionMode"`
	Cwd                 string                   `json:"cwd,omitempty"`
	LatestTurn          *Turn                    `json:"latestTurn,omitempty"`
	CreatedAt           time.Time                `json:"createdAt"`
	UpdatedAt           time.Time                `json:"updatedAt"`
	Session             *SessionBinding          `json:"session,omitempty"`
	LatestUserMessageAt *time.Time               `json:"latestUserMessageAt,omitempty"`
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
	ThreadID ThreadID            `json:"threadId,omitempty"`
}

type SubscribeThreadInput struct {
	ThreadID ThreadID `json:"threadId"`
}

type ReplayEventsInput struct {
	FromSequenceExclusive uint64 `json:"fromSequenceExclusive"`
	// ThreadID, when set, restricts replay to one thread so a client catching up
	// on a single conversation doesn't download every thread's stream.
	ThreadID ThreadID `json:"threadId,omitempty"`
	// Limit, when > 0, caps the number of returned events (page size). The
	// client pages by re-requesting from the last received sequence.
	Limit int `json:"limit,omitempty"`
}
