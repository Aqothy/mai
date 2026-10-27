// Package orchestration is maiD's core: the ledger of threads, participants,
// turns and deliveries, the session cache of what providers said, and the
// engine that turns commands, provider events and reactors into provider
// calls.
//
// The provider owns conversation content; maiD owns relationships and
// intents. Every agent's work is a thread, threads form a tree, one turn runs
// per thread, and every input to an agent is a delivery that takes effect
// exactly once.
package orchestration

import (
	"encoding/json"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

type (
	ThreadID      string
	ParticipantID string
	TurnID        string
	DeliveryID    string
	// DeviceID names a client device; one per connection until devices pair.
	DeviceID string
)

// Thread is a chat: one agent's work, or several agents' shared one.
type Thread struct {
	ID        ThreadID
	Title     string
	Workspace provider.Workspace
	Origin    Origin
	// Address is the participant the composer addresses by default: the last
	// addressed.
	Address ParticipantID
	// Hold says why queued deliveries wait for someone, and so who may
	// release them.
	Hold Hold
	// Policy bounds agent-started work under a root; nil means the defaults.
	Policy *TreePolicy
	// SeenAt is when a person last read it, on any device; zero when they
	// marked it unread.
	SeenAt    time.Time
	CreatedAt time.Time
	// UpdatedAt is the last turn or delivery.
	UpdatedAt time.Time
}

type OriginKind string

const (
	// OriginUser: a person started it, or imported a native session.
	OriginUser OriginKind = "user"
	// OriginSpawn: an agent or a person handed it work from its parent.
	OriginSpawn OriginKind = "spawn"
	// OriginNative: a provider's own subagent, recorded when seen.
	OriginNative OriginKind = "native"
)

type Origin struct {
	Kind OriginKind
	// Parent is the tree parent of a spawned or native thread; deleting it
	// deletes this thread.
	Parent ThreadID
	// By is the parent's participant that started it.
	By ParticipantID
	// At is the ref of the parent's entry that started it: the tool call.
	At string
	// ForkedFrom is the conversation it started from, any kind; a link,
	// cleared when that thread is deleted.
	ForkedFrom *ForkPoint
	// Contract is a spawned thread's.
	Contract *Contract
	// AcceptsInput: the provider takes input to a native subagent.
	AcceptsInput bool
}

type ForkPoint struct {
	Thread ThreadID `json:"thread"`
	// Turn is the last turn kept; empty when it kept none.
	Turn TurnID `json:"turn,omitempty"`
}

// WakeMode is when a spawned thread's parent hears from it.
type WakeMode string

const (
	// WakeSettled: when it is done, with its result.
	WakeSettled WakeMode = "settled"
	// WakeNeedsInput: also when it asks the user something.
	WakeNeedsInput WakeMode = "needsInput"
)

type Contract struct {
	Brief string `json:"brief"`
	// ResultSchema is a JSON Schema the child's reports must satisfy.
	ResultSchema json.RawMessage      `json:"resultSchema,omitempty"`
	Wake         WakeMode             `json:"wake,omitempty"`
	Access       provider.AccessLevel `json:"access,omitempty"`
}

// Hold says why a thread's queue waits.
type Hold string

const (
	HoldNone Hold = ""
	// HoldStoppedPerson: a person stopped it; only a person releases it.
	HoldStoppedPerson Hold = "stoppedPerson"
	// HoldStoppedAgent: an ancestor agent stopped it; an ancestor agent or a
	// person releases it.
	HoldStoppedAgent Hold = "stoppedAgent"
	// HoldFailed: a turn failed or was cut off (maiD or the agent stopped
	// mid-turn), or a message wasn't delivered; a person or an ancestor
	// agent releases it.
	HoldFailed Hold = "failed"
	// HoldHops: agents went back and forth too long without a person; only a
	// person releases it (Continue).
	HoldHops Hold = "hops"
)

// TreePolicy bounds agent-started work in a tree.
type TreePolicy struct {
	// MaxDepth is how many levels may be below the root.
	MaxDepth int `json:"maxDepth"`
	// MaxRunning is how many threads may run agent-started turns at once.
	MaxRunning int `json:"maxRunning"`
	// HopLimit is how many turns agents may start without a person.
	HopLimit int `json:"hopLimit"`
}

var defaultPolicy = TreePolicy{MaxDepth: 2, MaxRunning: 4, HopLimit: 8}

// Participant is one agent of a thread, with its own native session.
type Participant struct {
	ID       ParticipantID
	Thread   ThreadID
	Instance provider.InstanceID
	// Settings are its config options as last chosen: model, mode, effort.
	Settings []provider.ConfigOptionSelection
	// Session is its native session key; empty until a turn opens one.
	Session string
	// SeenThrough is the thread's last turn its session has seen.
	SeenThrough TurnID
}

type StartedBy string

const (
	// StartedByDelivery: a delivery started it.
	StartedByDelivery StartedBy = "delivery"
	// StartedByProvider: the provider started it on its own.
	StartedByProvider StartedBy = "provider"
	// StartedByFound: it was found in the native session (run in the CLI, or
	// inherited by a native fork).
	StartedByFound StartedBy = "found"
)

// Turn is one turn of one participant's session. A row exists only once the
// provider acknowledged it.
type Turn struct {
	ID          TurnID
	Thread      ThreadID
	Participant ParticipantID
	// Session is the native session it ran in; a participant's session can
	// change.
	Session   string
	Ref       string
	StartedBy StartedBy
	// ByAgent: an agent's or the daemon's delivery started it, so it counts
	// toward its tree's MaxRunning.
	ByAgent    bool
	Hops       int
	State      provider.TurnState
	StopReason provider.StopReason
	Error      string
	// Report is the last result its agent reported (a spawned thread's).
	Report    json.RawMessage
	StartedAt time.Time
	SettledAt time.Time
}

type DeliveryKind string

const (
	// KindPrompt is a person's.
	KindPrompt DeliveryKind = "prompt"
	// KindMessage is an agent's.
	KindMessage DeliveryKind = "message"
	// KindReply is the answer to a message.
	KindReply DeliveryKind = "reply"
	// KindNotice is the daemon's.
	KindNotice DeliveryKind = "notice"
)

type DeliveryMode string

const (
	ModeQueue DeliveryMode = "queue"
	ModeSteer DeliveryMode = "steer"
)

type DeliveryState string

const (
	DeliveryQueued    DeliveryState = "queued"
	DeliverySending   DeliveryState = "sending"
	DeliveryDelivered DeliveryState = "delivered"
	DeliveryRefused   DeliveryState = "refused"
	DeliveryCancelled DeliveryState = "cancelled"
)

// Delivery is one input to an agent.
type Delivery struct {
	ID     DeliveryID
	Thread ThreadID
	// To is fixed when queued, so switching the picker never retargets it.
	To   ParticipantID
	From Actor
	Kind DeliveryKind
	Mode DeliveryMode
	// Body is cleared once delivered: the native session has it. A prompt
	// with quotes keeps its text and quotes, which the session holds only as
	// text, so its cards show.
	Body  MessageBody
	State DeliveryState
	// Turn is the turn it started or joined, once delivered.
	Turn TurnID
	Hops int
	// Reason is why it was refused, shown with Retry.
	Reason string
	// WantsReply: a message whose sender gets the answer back.
	WantsReply bool
	// Answers is the message a reply answers; Answer is the answer.
	Answers  DeliveryID
	Answer   *Answer
	Position float64
	// Sent is when it last went to the provider.
	Sent      time.Time
	CreatedAt time.Time
}

type MessageBody struct {
	Text string `json:"text,omitempty"`
	// Attachments name attachment-store data by ID.
	Attachments []provider.Attachment       `json:"attachments,omitempty"`
	Annotations []provider.PromptAnnotation `json:"annotations,omitempty"`
}

// Answer is what a message got back.
type Answer struct {
	// Text is the answering thread's last assistant message, its failed
	// turn's error first.
	Text string `json:"text"`
	// Report is its agent's last report since the message.
	Report json.RawMessage    `json:"report,omitempty"`
	State  provider.TurnState `json:"state"`
	// Reported is false when a spawn's contract asked for a structured result
	// and the child never reported one.
	Reported bool `json:"reported"`
}

type ActorKind string

const (
	ActorDevice ActorKind = "device"
	ActorAgent  ActorKind = "agent"
	ActorDaemon ActorKind = "daemon"
)

// Actor is who issues a command or sends a delivery.
type Actor struct {
	Kind        ActorKind     `json:"kind"`
	Device      DeviceID      `json:"device,omitempty"`
	Thread      ThreadID      `json:"thread,omitempty"`
	Participant ParticipantID `json:"participant,omitempty"`
}

// key is the actor's identity for idempotency keys.
func (a Actor) key() string {
	switch a.Kind {
	case ActorAgent:
		return "agent:" + string(a.Participant)
	case ActorDevice:
		// Devices' keys are client-made UUIDs, so they share one space; a
		// retry after reconnecting finds its first result.
		return "device"
	default:
		return string(a.Kind)
	}
}

// Person is a device actor.
func Person(device DeviceID) Actor { return Actor{Kind: ActorDevice, Device: device} }

// Agent is an agent actor: the participant of thread whose agent called.
func Agent(thread ThreadID, participant ParticipantID) Actor {
	return Actor{Kind: ActorAgent, Thread: thread, Participant: participant}
}

var daemon = Actor{Kind: ActorDaemon}
