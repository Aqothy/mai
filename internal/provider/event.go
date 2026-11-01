package provider

import "time"

// Event is one thing an instance reports. Events of one session arrive in
// provider order: a turn's TurnStarted before its entries, an entry's
// EntryUpserted before its TextAppended, a turn's entries before its
// TurnSettled.
type Event struct {
	// Session is the session key; empty for InstanceChanged.
	Session string
	At      time.Time
	Body    EventBody
}

// EventBody is exactly one of the event types below; consumers switch on it
// exhaustively.
type EventBody interface{ eventBody() }

// TurnSource says who started a turn.
type TurnSource string

const (
	// TurnByClient: a Send started it.
	TurnByClient TurnSource = "client"
	// TurnByProvider: the provider started it on its own (a background task
	// waking Claude, a Codex goal continuing, a subagent's task).
	TurnByProvider TurnSource = "provider"
)

type TurnStarted struct {
	Turn string
	By   TurnSource
	// Delivery is the SendInput.Delivery of the message that started it, for
	// a turn a Send started.
	Delivery string
}

type TurnSettled struct {
	Turn       string
	State      TurnState
	StopReason StopReason
	Error      string
}

// EntryUpserted carries a whole entry; it replaces any earlier one with its
// Ref.
type EntryUpserted struct{ Entry Entry }

// StreamKind is what streamed text adds to.
type StreamKind string

const (
	StreamAssistant StreamKind = "assistant"
	StreamReasoning StreamKind = "reasoning"
)

// TextAppended streams text onto an entry already upserted.
type TextAppended struct {
	Entry  string
	Turn   string
	Stream StreamKind
	Text   string
}

// RequestOpened: the agent asks the user something. Entry is the tool entry
// it is about, if any.
type RequestOpened struct {
	Request string
	Turn    string
	Entry   string
	Ask     Request
}

// RequestResolved: the request ended. Action is empty when it ended without
// an answer.
type RequestResolved struct {
	Request string
	Action  string
	Answers map[string][]string
}

// ConfigChanged replaces the session's options, commands or skills; a nil
// field is unchanged, an empty one cleared.
type ConfigChanged struct {
	Options  []ConfigOption
	Commands []SlashCommand
	Skills   []Skill
}

type PlanChanged struct{ Entries []PlanEntry }

// GoalChanged: the session's goal; nil when it has none.
type GoalChanged struct{ Goal *Goal }

type UsageChanged struct{ Usage TokenUsage }

// TitleChanged: the session got a title in the provider (one the user gave it
// in the provider's own tools, or the provider's).
type TitleChanged struct{ Title string }

// SessionReplaced: the conversation moved to a new session (Claude /clear).
type SessionReplaced struct{ New string }

// SessionClosed: the live session ended (its process exited, its connection
// closed) without Release. Error says why, when it failed.
type SessionClosed struct{ Error string }

// SubagentSeen names one of the provider's own subagents: a session of its own
// inside Parent's session, started by Parent's tool entry Item.
type SubagentSeen struct {
	Parent string
	Item   string
	// Session is the subagent's own session key.
	Session string
	Name    string
	Model   string
	// AcceptsInput: Send works on Session.
	AcceptsInput bool
}

// Warning is something the user should see that isn't part of the
// conversation the provider keeps (an API retry, a hook's notice).
type Warning struct {
	Turn    string
	Message string
}

type InstanceChanged struct{ Info InstanceInfo }

func (TurnStarted) eventBody()     {}
func (TurnSettled) eventBody()     {}
func (EntryUpserted) eventBody()   {}
func (TextAppended) eventBody()    {}
func (RequestOpened) eventBody()   {}
func (RequestResolved) eventBody() {}
func (ConfigChanged) eventBody()   {}
func (PlanChanged) eventBody()     {}
func (GoalChanged) eventBody()     {}
func (UsageChanged) eventBody()    {}
func (TitleChanged) eventBody()    {}
func (SessionReplaced) eventBody() {}
func (SessionClosed) eventBody()   {}
func (SubagentSeen) eventBody()    {}
func (Warning) eventBody()         {}
func (InstanceChanged) eventBody() {}
