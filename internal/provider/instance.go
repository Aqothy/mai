package provider

import (
	"context"
	"encoding/json"
	"errors"
	"time"
)

// Driver makes instances of one kind (claude-code, codex, acp). A new
// provider is a new Driver.
type Driver struct {
	Open func(ctx context.Context, spec InstanceSpec, host Host) (Instance, error)
	// Static is what is known of an instance before it runs: its access modes
	// and the capabilities that don't wait for what it reports on start.
	Static func(spec InstanceSpec) InstanceInfo
}

// Host is what the daemon gives an instance.
type Host struct {
	// Emit receives the instance's events, in provider order per session.
	Emit func(Event)
	// Mirror keeps native frames of sessions the provider may lose or can't
	// replay. Nil when the daemon keeps none (tests).
	Mirror Mirror
}

// Mirror is durable, append-only storage of a session's native frames (the
// lines or notifications the provider itself would replay), kept by the host
// so a session's history survives the provider forgetting it. Frames are
// opaque to the host.
type Mirror interface {
	// Append adds frames after the session's earlier ones. It doesn't wait
	// for the write.
	Append(session string, frames []json.RawMessage)
	// Load returns the session's frames in the order appended, waiting for
	// earlier appends; none when nothing was mirrored.
	Load(ctx context.Context, session string) ([]json.RawMessage, error)
	// Fork copies a session's frames to another session.
	Fork(ctx context.Context, session, into string) error
	// Delete forgets the session's frames.
	Delete(ctx context.Context, session string) error
}

// Instance is one configured provider: a process, a connection or an SDK
// client. Every method exists on every instance; one its capabilities don't
// offer returns ErrUnsupported. Adapters embed Unsupported and override what
// they support. Sessions are named by their native keys (session keys).
type Instance interface {
	Info() InstanceInfo
	// Close shuts the instance down, ending its live sessions.
	Close() error

	// Live sessions.

	// Open starts a new session (empty Session) or resumes one. Opened.Session
	// differs from the one asked for when the provider started a new session
	// instead.
	Open(ctx context.Context, in OpenInput) (Opened, error)
	// Release frees a live session's process or load; the native session
	// stays. A running turn ends as interrupted.
	Release(ctx context.Context, session string) error
	// Send delivers a message: a new turn, or with Steer the running one.
	Send(ctx context.Context, session string, in SendInput) (SendAck, error)
	// Interrupt stops the turn. On a provider's own subagent it stops the
	// subagent.
	Interrupt(ctx context.Context, session, turn string) error
	Respond(ctx context.Context, session, request string, answer RequestAnswer) error
	Configure(ctx context.Context, session string, setting ConfigOptionSelection) error
	// StopItem stops a background task (ToolCall.Background) without its turn.
	StopItem(ctx context.Context, session, item string) error

	// Native sessions at rest.

	// History returns the session's turns after the marker, oldest first.
	// Workspace is where the session works, for providers that need it to
	// find or load the session.
	History(ctx context.Context, session string, workspace Workspace, after Marker) (HistoryPage, error)
	// Delivered says whether the session took a message.
	Delivered(ctx context.Context, session string, probe DeliveryProbe) (Tri, error)
	// Fork copies a session through one of its turns into a new session and
	// returns the new session's key.
	Fork(ctx context.Context, in ForkInput) (string, error)
	Sessions(ctx context.Context, cwd string) ([]SessionSummary, error)
	Delete(ctx context.Context, session string) error
	Rename(ctx context.Context, session, title string) error

	// Account and composer.

	Authenticate(ctx context.Context, in AuthenticateInput) (AuthenticationResult, error)
	Logout(ctx context.Context) (InstanceInfo, error)
	CompleteCommand(ctx context.Context, in CompleteCommandInput) ([]CommandCompletion, error)
	// OpenOptions makes a draft's settings, before any session exists.
	OpenOptions(ctx context.Context, cwd string, callbacks OptionsSessionCallbacks) (OptionsSession, error)
	SetOption(ctx context.Context, handle, option string, value any) ([]ConfigOption, error)
	CloseOptions(ctx context.Context, handle string) error
}

var (
	ErrUnsupported = errors.New("not supported by this provider")
	// ErrTurnNotRunning is returned (wrapped) by a steer whose turn already
	// ended at the provider.
	ErrTurnNotRunning = errors.New("turn is not running")
	// ErrSessionNotFound is returned (wrapped) for a session the provider no
	// longer has.
	ErrSessionNotFound = errors.New("session not found")
)

// Unsupported implements every Instance method except Info and Close by
// returning ErrUnsupported. Adapters embed it.
type Unsupported struct{}

func (Unsupported) Open(context.Context, OpenInput) (Opened, error) { return Opened{}, ErrUnsupported }
func (Unsupported) Release(context.Context, string) error           { return ErrUnsupported }
func (Unsupported) Send(context.Context, string, SendInput) (SendAck, error) {
	return SendAck{}, ErrUnsupported
}
func (Unsupported) Interrupt(context.Context, string, string) error { return ErrUnsupported }
func (Unsupported) Respond(context.Context, string, string, RequestAnswer) error {
	return ErrUnsupported
}
func (Unsupported) Configure(context.Context, string, ConfigOptionSelection) error {
	return ErrUnsupported
}
func (Unsupported) StopItem(context.Context, string, string) error { return ErrUnsupported }
func (Unsupported) History(context.Context, string, Workspace, Marker) (HistoryPage, error) {
	return HistoryPage{}, ErrUnsupported
}
func (Unsupported) Delivered(context.Context, string, DeliveryProbe) (Tri, error) {
	return TriUnknown, ErrUnsupported
}
func (Unsupported) Fork(context.Context, ForkInput) (string, error) { return "", ErrUnsupported }
func (Unsupported) Sessions(context.Context, string) ([]SessionSummary, error) {
	return nil, ErrUnsupported
}
func (Unsupported) Delete(context.Context, string) error         { return ErrUnsupported }
func (Unsupported) Rename(context.Context, string, string) error { return ErrUnsupported }
func (Unsupported) Authenticate(context.Context, AuthenticateInput) (AuthenticationResult, error) {
	return AuthenticationResult{}, ErrUnsupported
}
func (Unsupported) Logout(context.Context) (InstanceInfo, error) {
	return InstanceInfo{}, ErrUnsupported
}
func (Unsupported) CompleteCommand(context.Context, CompleteCommandInput) ([]CommandCompletion, error) {
	return nil, ErrUnsupported
}
func (Unsupported) OpenOptions(context.Context, string, OptionsSessionCallbacks) (OptionsSession, error) {
	return OptionsSession{}, ErrUnsupported
}
func (Unsupported) SetOption(context.Context, string, string, any) ([]ConfigOption, error) {
	return nil, ErrUnsupported
}
func (Unsupported) CloseOptions(context.Context, string) error { return ErrUnsupported }

// Workspace is where a session works: its cwd and more roots it may reach.
type Workspace struct {
	Cwd                   string   `json:"cwd"`
	AdditionalDirectories []string `json:"additionalDirectories,omitempty"`
}

type OpenInput struct {
	// Session is the session to resume; empty starts a new one.
	Session   string
	Workspace Workspace
	Settings  []ConfigOptionSelection
	// MCP is maiD's own MCP server for this session, when it has one.
	MCP *MCPServer
	// Instructions tell the agent how to work in maiD. Without
	// Capabilities.Instructions the daemon sends them with the first turn
	// instead and leaves this empty.
	Instructions string
}

// MCPServer is an MCP server a session is given: over HTTP at URL with
// Headers, or as a local process (Stdio) for agents without MCP over HTTP.
type MCPServer struct {
	Name    string
	URL     string
	Headers map[string]string
	Stdio   *TerminalCommand
}

type Opened struct {
	// Session is the key of the session opened: the one asked for, or a new
	// one when the provider couldn't resume it.
	Session  string
	Options  []ConfigOption
	Commands []SlashCommand
	Skills   []Skill
	Goal     *Goal
}

type SendInput struct {
	// Delivery is the daemon's ID of the message. A session with
	// Capabilities.MessageIDs keeps it (Delivered, Entry.Delivery).
	Delivery string
	// Text is what the session gets, envelopes included (Envelope).
	Text string
	// Attachments carry their data.
	Attachments []Attachment
	// Steer joins the running turn; ErrTurnNotRunning when none runs.
	Steer bool
}

type SendAck struct {
	// Turn is the ref of the turn the message started or joined. Empty when
	// the session reads the message later: then a TurnStarted or an entry
	// carrying the delivery names its turn.
	Turn string
	// Joined: it joined a turn the provider was already running on its own.
	Joined bool
}

// ForkInput forks Session through its turn Through into a new session that
// works in Workspace with Settings.
type ForkInput struct {
	Session   string
	Through   string
	Workspace Workspace
	Settings  []ConfigOptionSelection
}

// Marker is a position in a session's history: the ref of the last turn
// read. History after it returns the turns that follow (provider.After).
type Marker string

// HistoryPage is part of a session's history.
type HistoryPage struct {
	// Reset: the marker is unknown (the session was rewound or rewritten),
	// so Turns starts at the session's first turn.
	Reset bool
	// Turns are the turns after the marker, oldest first. The last may still
	// be running.
	Turns []HistoryTurn
	// Subagents are the provider's own subagents the turns started.
	Subagents []SubagentSeen
	// Next is the marker after Turns.
	Next Marker
	// More: more turns follow Next.
	More bool
}

type HistoryTurn struct {
	Ref string
	// StartedAt is zero when the provider keeps no start time.
	StartedAt  time.Time
	State      TurnState
	StopReason StopReason
	Error      string
	Entries    []Entry
}

// DeliveryProbe asks whether a session took a message.
type DeliveryProbe struct {
	// Delivery is the ID the message carried.
	Delivery string
	// Text is the text sent, for sessions that can't keep the ID.
	Text string
	// After is the session's last turn ref known before the message was
	// sent; empty when it had none.
	After string
}

// Tri is a yes, a no, or that the provider can't tell.
type Tri int

const (
	TriNo Tri = iota
	TriYes
	TriUnknown
)

// AccessLevel is how much a session may do without asking. Levels are
// ordered by Rank; the empty level is a mode nobody mapped.
type AccessLevel string

const (
	AccessUnknown  AccessLevel = ""
	AccessReadOnly AccessLevel = "read_only"
	AccessAsk      AccessLevel = "ask"
	AccessEdit     AccessLevel = "edit"
	AccessFull     AccessLevel = "full"
)

var accessRanks = map[AccessLevel]int{AccessUnknown: 0, AccessReadOnly: 1, AccessAsk: 2, AccessEdit: 3, AccessFull: 4}

// Known reports whether l is one of the levels.
func (l AccessLevel) Known() bool {
	_, ok := accessRanks[l]
	return ok
}

// Rank orders levels from unknown (0) to full; an unrecognized level ranks
// as full.
func (l AccessLevel) Rank() int {
	if rank, ok := accessRanks[l]; ok {
		return rank
	}
	return accessRanks[AccessFull]
}

// Exceeds reports whether l allows more than other.
func (l AccessLevel) Exceeds(other AccessLevel) bool { return l.Rank() > other.Rank() }

// Ceiling is the level used to bound others: an unmapped mode might allow
// anything, so it counts as full.
func (l AccessLevel) Ceiling() AccessLevel {
	if l == AccessUnknown || !l.Known() {
		return AccessFull
	}
	return l
}

// AccessModes says which config option sets a session's access and what
// level each of its values is. Values missing from Levels are AccessUnknown.
type AccessModes struct {
	Option string                 `json:"option"`
	Levels map[string]AccessLevel `json:"levels"`
}

// Level is the access the value of the option allows.
func (m *AccessModes) Level(settings []ConfigOptionSelection) AccessLevel {
	if m == nil {
		return AccessUnknown
	}
	for _, setting := range settings {
		if setting.OptionID == m.Option {
			if value, ok := setting.Value.(string); ok {
				return m.Levels[value]
			}
		}
	}
	return AccessUnknown
}
