// Native frames of an ACP session and their one mapping to provider events.
//
// ACP replays a session only through session/load, as one flat update stream
// whose fidelity varies by agent, and keeps no ids for prompts. So the adapter
// keeps its own native record in the host's mirror: every prompt it sends,
// every session/update the agent sends, every cancel and prompt end, as
// frames. Live events come from feeding each frame to the session's mapper,
// and History feeds the mirrored frames to a fresh one, so live and replay
// refs are equal by construction and a fixed mapping rebuilds old sessions.
package acp

import (
	"encoding/json"
	"strconv"
	"strings"
	"time"

	"github.com/Aqothy/go-acp/schema"
	"github.com/Aqothy/maiD/internal/provider"
)

// frame is one native record of an ACP session.
type frame struct {
	At     time.Time       `json:"at"`
	Prompt *promptFrame    `json:"prompt,omitempty"`
	Update json.RawMessage `json:"update,omitempty"`
	// Replay: Update came from a session/load replay.
	Replay bool `json:"replay,omitempty"`
	// Cancel is the turn maiD cancelled.
	Cancel string     `json:"cancel,omitempty"`
	Stop   *stopFrame `json:"stop,omitempty"`
	// Lost: maiD took the session up again; what was left open (a turn, a
	// tool call) ran where maiD no longer hears it, so it ends here.
	Lost bool `json:"lost,omitempty"`
}

// promptFrame is a prompt maiD sent: Turn is its ref, the delivery that
// carried it.
type promptFrame struct {
	Turn        string                `json:"turn"`
	Text        string                `json:"text,omitempty"`
	Attachments []provider.Attachment `json:"attachments,omitempty"`
}

// stopFrame ends a turn: a prompt's response, or the end of a session/load
// replay's last turn.
type stopFrame struct {
	Turn       string              `json:"turn"`
	State      provider.TurnState  `json:"state"`
	StopReason provider.StopReason `json:"stopReason,omitempty"`
	Error      string              `json:"error,omitempty"`
}

func encodeFrame(f frame) json.RawMessage {
	raw, _ := json.Marshal(f)
	return raw
}

// openMessage is the message entry text streams onto.
type openMessage struct {
	entry provider.Entry
}

// mapper turns an ACP session's frames into provider events. Its state is
// only what frames determine, so the same frames always map the same way.
//
// Only a prompt maiD sent runs a turn: it ends when the agent answers it.
// ACP v1 lets an agent send updates outside a prompt (claude-agent-acp's
// reply when a background task ends) but has no frame that would end a turn
// opened for them, so a chat would count as running until a prompt it can't
// send. So a turn the agent starts on its own (output outside a prompt, or a
// replayed prompt) is settled as it starts: its output up to the next prompt
// is one turn, and one a crash cut off shows completed. Its messages are
// complete as they stream, since nothing would complete them. ACP v2's
// foreground state reports when such work ends (ROADMAP.md, "ACP v2").
type mapper struct {
	// turn is the ref of the turn output goes to: a prompt the agent hasn't
	// answered, or one it started; empty once a turn ends (a prompt's
	// answer, a replay's end).
	turn string
	// running: turn is a prompt maiD sent.
	running bool
	// found counts the turns the agent started without a prompt from maiD
	// (a session/load replay's turns, output outside a prompt), naming them.
	found int
	// cancelled: the running prompt was cancelled, so only tool updates
	// still count until its answer (the ACP spec's cancellation rule).
	cancelled bool
	// messages counts the turn's message entries, naming them.
	messages int
	open     *openMessage
	// user accumulates a replayed user message.
	user *provider.Entry
	// tools are the turn's tool calls and the session's still running, by
	// tool call id, which ACP makes unique in a session (ToolCallId): one
	// that ends after a later turn began still ends its own card.
	tools map[string]*mappedTool
}

type mappedTool struct {
	entry provider.Entry
	patch *toolCallPatch
}

// apply maps one frame to the events it causes.
func (m *mapper) apply(f frame) []provider.Event {
	var events []provider.Event
	emit := func(body provider.EventBody) {
		events = append(events, provider.Event{At: f.At, Body: body})
	}
	switch {
	case f.Prompt != nil:
		m.endTurn(emit, provider.TurnSettled{State: provider.TurnCompleted})
		m.beginTurn(f.Prompt.Turn)
		m.running = true
		emit(provider.TurnStarted{Turn: m.turn, By: provider.TurnByClient, Delivery: f.Prompt.Turn})
		for _, entry := range provider.UserMessageEntries(m.turn+"/user", m.turn, f.Prompt.Text, f.Prompt.Attachments, f.Prompt.Turn, f.At) {
			emit(provider.EntryUpserted{Entry: entry})
		}
	case f.Cancel != "":
		if f.Cancel == m.turn {
			m.cancelled = true
		}
	case f.Stop != nil:
		if f.Stop.Turn == m.turn {
			m.endTurn(emit, provider.TurnSettled{State: f.Stop.State, StopReason: f.Stop.StopReason, Error: f.Stop.Error})
		}
	case f.Lost:
		m.endTurn(emit, provider.TurnSettled{State: provider.TurnInterrupted})
		for _, tool := range m.tools {
			if tool.entry.Status == provider.ItemStatusInProgress {
				tool.entry.Status = provider.ItemStatusInterrupted
				emit(provider.EntryUpserted{Entry: tool.entry})
			}
		}
	case f.Update != nil:
		var update schema.SessionUpdate
		if json.Unmarshal(f.Update, &update) == nil {
			m.applyUpdate(emit, f.At, f.Replay, update)
		}
	}
	return events
}

func (m *mapper) beginTurn(ref string) {
	m.turn, m.cancelled, m.messages = ref, false, 0
	m.open, m.user = nil, nil
	for id, tool := range m.tools {
		if tool.entry.Status != provider.ItemStatusInProgress {
			delete(m.tools, id)
		}
	}
}

// endTurn completes the turn's open message and replayed user message, and
// settles the prompt it runs, whose tools still running end with it.
func (m *mapper) endTurn(emit func(provider.EventBody), settled provider.TurnSettled) {
	if m.turn == "" {
		return
	}
	m.closeMessage(emit)
	m.closeUser(emit)
	if m.running {
		if settled.State != provider.TurnCompleted {
			status := provider.ItemStatusInterrupted
			if settled.State == provider.TurnFailed {
				status = provider.ItemStatusFailed
			}
			for _, tool := range m.tools {
				if tool.entry.Turn == m.turn && tool.entry.Status == provider.ItemStatusInProgress {
					tool.entry.Status = status
					emit(provider.EntryUpserted{Entry: tool.entry})
				}
			}
		}
		settled.Turn = m.turn
		emit(settled)
	}
	m.turn, m.running, m.cancelled = "", false, false
}

// leftOpen: a turn or a tool call is still open.
func (m *mapper) leftOpen() bool {
	if m.turn != "" {
		return true
	}
	for _, tool := range m.tools {
		if tool.entry.Status == provider.ItemStatusInProgress {
			return true
		}
	}
	return false
}

// foundTurn starts a turn the agent began without a prompt from maiD,
// settled at once.
func (m *mapper) foundTurn(emit func(provider.EventBody)) {
	m.found++
	m.beginTurn("found-" + strconv.Itoa(m.found))
	emit(provider.TurnStarted{Turn: m.turn, By: provider.TurnByProvider})
	emit(provider.TurnSettled{Turn: m.turn, State: provider.TurnCompleted})
}

// ensureTurn starts a turn for agent output outside any.
func (m *mapper) ensureTurn(emit func(provider.EventBody)) {
	if m.turn == "" {
		m.foundTurn(emit)
	}
}

func (m *mapper) applyUpdate(emit func(provider.EventBody), at time.Time, replay bool, u schema.SessionUpdate) {
	switch u.SessionUpdate {
	case schema.SessionUpdateUserMessageChunk:
		// During a prompt maiD sent, the agent echoes it; the prompt frame
		// already gave its entries. Otherwise it is a replayed prompt, which
		// starts a turn of its own.
		if m.running {
			return
		}
		if m.user == nil {
			m.endTurn(emit, provider.TurnSettled{State: provider.TurnCompleted})
			m.foundTurn(emit)
			m.user = &provider.Entry{At: at}
		}
		text, _ := u.TextChunk()
		m.user.Text += text
		m.user.Attachments = append(m.user.Attachments, attachmentsFromACPContent(u)...)
	case schema.SessionUpdateAgentMessageChunk, schema.SessionUpdateAgentThoughtChunk:
		if m.cancelled {
			return
		}
		m.closeUser(emit)
		m.ensureTurn(emit)
		kind, stream := provider.ItemKindAssistantMessage, provider.StreamAssistant
		text, _ := u.TextChunk()
		if u.SessionUpdate == schema.SessionUpdateAgentThoughtChunk {
			kind, stream = provider.ItemKindReasoning, provider.StreamReasoning
			// session/load replays thoughts without the separators the live
			// stream has, which would run their paragraphs together.
			if replay && text != "" && !strings.HasSuffix(text, "\n") {
				text += "\n\n"
			}
		}
		attachments := attachmentsFromACPContent(u)
		if m.open != nil && m.open.entry.Kind != kind {
			m.closeMessage(emit)
		}
		if m.open == nil {
			m.messages++
			status := provider.ItemStatusInProgress
			if !m.running {
				status = provider.ItemStatusCompleted
			}
			m.open = &openMessage{entry: provider.Entry{
				Ref: m.turn + "/m" + strconv.Itoa(m.messages), Turn: m.turn, Kind: kind,
				Status: status, Text: text, Attachments: attachments, At: at,
			}}
			emit(provider.EntryUpserted{Entry: m.open.entry})
			return
		}
		m.open.entry.Text += text
		if len(attachments) > 0 {
			m.open.entry.Attachments = append(m.open.entry.Attachments, attachments...)
			emit(provider.EntryUpserted{Entry: m.open.entry})
			return
		}
		if text != "" {
			emit(provider.TextAppended{Entry: m.open.entry.Ref, Turn: m.turn, Stream: stream, Text: text})
		}
	case schema.SessionUpdateToolCall, schema.SessionUpdateToolCallUpdate:
		id := toolCallIDValue(u.ToolCallID)
		if id == "" {
			return
		}
		if m.tools == nil {
			m.tools = make(map[string]*mappedTool)
		}
		tool := m.tools[id]
		fresh := u.SessionUpdate == schema.SessionUpdateToolCall || tool == nil
		if fresh || tool.entry.Turn == m.turn {
			// It follows what the turn said before it; an earlier turn's
			// tool leaves this turn's message open.
			m.closeUser(emit)
			m.closeMessage(emit)
		}
		if fresh {
			// A fresh tool_call reusing an id starts a new run of the tool;
			// an update to one goes to its card, in whichever turn it is.
			m.ensureTurn(emit)
			tool = &mappedTool{entry: provider.Entry{Ref: m.turn + "/tool/" + id, Turn: m.turn, Kind: provider.ItemKindToolCall, Status: provider.ItemStatusInProgress, At: at}}
			m.tools[id] = tool
		}
		tool.patch = tool.patch.overlay(toolCallPatchFromUpdate(u))
		if kind := itemKindFromToolKind(toolKindString(tool.patch.kind)); kind != "" {
			tool.entry.Kind = kind
		}
		if status := itemStatusFromACP(toolStatusString(tool.patch.status)); status != "" {
			tool.entry.Status = status
		}
		tool.entry.Title = stringValue(tool.patch.title)
		tool.entry.Tool = tool.patch.toolCall()
		emit(provider.EntryUpserted{Entry: tool.entry})
	case schema.SessionUpdatePlan:
		emit(provider.PlanChanged{Entries: planEntriesFromACP(u.Entries)})
	case schema.SessionUpdateAvailableCommandsUpdate:
		emit(provider.ConfigChanged{Commands: slashCommandsFromACP(u.AvailableCommands)})
	case schema.SessionUpdateSessionInfoUpdate:
		if title := stringValue(u.Title); title != "" {
			emit(provider.TitleChanged{Title: title})
		}
	case schema.SessionUpdateUsageUpdate:
		if usage := tokenUsageFromACP(u); usage != nil {
			emit(provider.UsageChanged{Usage: *usage})
		}
	}
}

func (m *mapper) closeMessage(emit func(provider.EventBody)) {
	if m.open == nil {
		return
	}
	m.open.entry.Status = provider.ItemStatusCompleted
	emit(provider.EntryUpserted{Entry: m.open.entry})
	m.open = nil
}

func (m *mapper) closeUser(emit func(provider.EventBody)) {
	if m.user == nil {
		return
	}
	for _, entry := range provider.UserMessageEntries(m.turn+"/user", m.turn, m.user.Text, m.user.Attachments, "", m.user.At) {
		emit(provider.EntryUpserted{Entry: entry})
	}
	m.user = nil
}

// history maps a session's frames to its turns.
func history(frames []json.RawMessage) (*mapper, []provider.HistoryTurn) {
	var m mapper
	var builder provider.HistoryBuilder
	for _, raw := range frames {
		var f frame
		if json.Unmarshal(raw, &f) != nil {
			continue
		}
		for _, event := range m.apply(f) {
			builder.Add(event)
		}
	}
	return &m, builder.Turns()
}
