package provider

import "time"

// Entry is one thing in a session's conversation, in provider order: a
// message, a reasoning block, a tool call, a notice, an envelope, a request.
// It is the unit of the session cache, of display and of what agents read.
type Entry struct {
	// Ref is deterministic: the same live and in replay.
	Ref string `json:"ref"`
	// Turn is the ref of the turn it belongs to.
	Turn   string     `json:"turn"`
	Kind   ItemKind   `json:"kind"`
	Status ItemStatus `json:"status,omitempty"`
	Title  string     `json:"title,omitempty"`
	// Text is a message's, a reasoning block's or a notice's text.
	Text string `json:"text,omitempty"`
	// Attachments are a message's. In the session cache they are named by
	// ID, their data in the attachment store.
	Attachments []Attachment `json:"attachments,omitempty"`
	// Annotations are a person's quote cards. The session has them inlined
	// as text; the host restores them from the delivery that sent them.
	Annotations []PromptAnnotation `json:"annotations,omitempty"`
	Tool        *ToolCall          `json:"tool,omitempty"`
	Envelope    *Envelope          `json:"envelope,omitempty"`
	Request     *RequestRecord     `json:"request,omitempty"`
	// Delivery is the daemon's ID of the message a user message or envelope
	// came in, when the session keeps one.
	Delivery string `json:"delivery,omitempty"`
	// Local: the provider keeps no record of the entry (an adapter's own
	// command report, the command a person typed), so History never returns
	// it and the host keeps it as its own.
	Local bool      `json:"local,omitempty"`
	At    time.Time `json:"at,omitzero"`
}

// RequestRecord is what was asked of the user and how it was answered.
type RequestRecord struct {
	Request string  `json:"request"`
	Ask     Request `json:"ask"`
	// Action is the action chosen; empty when it ended unanswered.
	Action  string              `json:"action,omitempty"`
	Answers map[string][]string `json:"answers,omitempty"`
}

// EnvelopeKind is what an envelope carries.
type EnvelopeKind string

const (
	// EnvelopeHandoff catches the agent up on conversation it didn't see:
	// other agents' turns of its chat, or a fork's earlier conversation.
	EnvelopeHandoff EnvelopeKind = "handoff"
	// EnvelopeMessage is a message from another agent.
	EnvelopeMessage EnvelopeKind = "message"
	// EnvelopeReply is the answer to a message the agent sent.
	EnvelopeReply EnvelopeKind = "reply"
	// EnvelopeNotice is something the daemon tells the agent.
	EnvelopeNotice EnvelopeKind = "notice"
	// EnvelopeInstructions tells the agent how to work in maiD, for providers
	// without a system prompt the daemon can set.
	EnvelopeInstructions EnvelopeKind = "instructions"
)

// Envelope is a block maiD wraps around text it sends a session, so the
// sender stays known after any rebuild from the provider.
type Envelope struct {
	Kind EnvelopeKind `json:"kind"`
	// Delivery is the ID of the delivery it came in.
	Delivery string `json:"delivery,omitempty"`
	// From names the sender for display.
	From string `json:"from,omitempty"`
	// Thread is the sending thread.
	Thread string `json:"thread,omitempty"`
	// Covers says what a handoff covers ("4 turns").
	Covers string `json:"covers,omitempty"`
	// Answers is the message a reply answers.
	Answers string `json:"answers,omitempty"`
	Body    string `json:"body,omitempty"`
}
