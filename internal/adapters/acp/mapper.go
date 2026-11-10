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
	// Cancel is the turn maiD cancelled.
	Cancel string     `json:"cancel,omitempty"`
	Stop   *stopFrame `json:"stop,omitempty"`
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
type mapper struct {
	// turn is the running turn's ref; empty between turns.
	turn string
	// found counts the turns the agent ran without a prompt from maiD (a
	// session/load replay's turns, output between prompts), naming them.
	found int
	// cancelled: the running turn was cancelled, so only tool updates still
	// count (the ACP spec's cancellation rule).
	cancelled bool
	// loaded: the running turn came from a session/load replay.
	loaded bool
	// messages counts the turn's message entries, naming them.
	messages int
	open     *openMessage
	// user accumulates a replayed user message.
	user *provider.Entry
	// tools are the turn's tool calls, by tool call id.
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
		m.beginTurn(f.Prompt.Turn, false)
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
	case f.Update != nil:
		var update schema.SessionUpdate
		if json.Unmarshal(f.Update, &update) == nil {
			m.applyUpdate(emit, f.At, update)
		}
	}
	return events
}

func (m *mapper) beginTurn(ref string, loaded bool) {
	m.turn, m.cancelled, m.loaded, m.messages = ref, false, loaded, 0
	m.open, m.user = nil, nil
	m.tools = make(map[string]*mappedTool)
}

// endTurn settles the running turn: its open message and replayed user
// message complete, and tools still running end with the turn.
func (m *mapper) endTurn(emit func(provider.EventBody), settled provider.TurnSettled) {
	if m.turn == "" {
		return
	}
	m.closeMessage(emit)
	m.closeUser(emit)
	if settled.State != provider.TurnCompleted {
		status := provider.ItemStatusInterrupted
		if settled.State == provider.TurnFailed {
			status = provider.ItemStatusFailed
		}
		for _, tool := range m.tools {
			if tool.entry.Status == provider.ItemStatusInProgress {
				tool.entry.Status = status
				emit(provider.EntryUpserted{Entry: tool.entry})
			}
		}
	}
	settled.Turn = m.turn
	emit(settled)
	m.turn = ""
}

// ensureTurn starts a turn for agent output outside any: a session/load
// replay's turn or output between prompts.
func (m *mapper) ensureTurn(emit func(provider.EventBody), loaded bool) {
	if m.turn != "" {
		return
	}
	m.found++
	m.beginTurn("found-"+strconv.Itoa(m.found), loaded)
	emit(provider.TurnStarted{Turn: m.turn, By: provider.TurnByProvider})
}

func (m *mapper) applyUpdate(emit func(provider.EventBody), at time.Time, u schema.SessionUpdate) {
	switch u.SessionUpdate {
	case schema.SessionUpdateUserMessageChunk:
		// During a prompt maiD sent, the agent echoes it; the prompt frame
		// already gave its entries. Otherwise it is a replayed prompt, which
		// starts a turn of its own.
		if m.turn != "" && !m.loaded {
			return
		}
		if m.user == nil {
			m.endTurn(emit, provider.TurnSettled{State: provider.TurnCompleted})
			m.ensureTurn(emit, true)
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
		m.ensureTurn(emit, false)
		kind, stream := provider.ItemKindAssistantMessage, provider.StreamAssistant
		text, _ := u.TextChunk()
		if u.SessionUpdate == schema.SessionUpdateAgentThoughtChunk {
			kind, stream = provider.ItemKindReasoning, provider.StreamReasoning
			// session/load replays thoughts without the separators the live
			// stream has, which would run their paragraphs together.
			if m.loaded && text != "" && !strings.HasSuffix(text, "\n") {
				text += "\n\n"
			}
		}
		attachments := attachmentsFromACPContent(u)
		if m.open != nil && m.open.entry.Kind != kind {
			m.closeMessage(emit)
		}
		if m.open == nil {
			m.messages++
			m.open = &openMessage{entry: provider.Entry{
				Ref: m.turn + "/m" + strconv.Itoa(m.messages), Turn: m.turn, Kind: kind,
				Status: provider.ItemStatusInProgress, Text: text, Attachments: attachments, At: at,
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
		m.closeUser(emit)
		m.ensureTurn(emit, false)
		m.closeMessage(emit)
		id := toolCallIDValue(u.ToolCallID)
		if id == "" {
			return
		}
		tool := m.tools[id]
		if u.SessionUpdate == schema.SessionUpdateToolCall || tool == nil {
			// A fresh tool_call reusing an id starts a new run of the tool.
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
