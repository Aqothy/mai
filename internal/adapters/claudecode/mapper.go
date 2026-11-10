package claudecode

import (
	"encoding/json"
	"strconv"
	"strings"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// mapper maps one session's conversation to events: transcript lines in
// replay, the CLI's stream-json messages live. A transcript line and the live
// message it records carry the same uuid, API message id and content, and
// both go through these methods, so a turn's final entries and refs are the
// same either way (live text first streams onto the same refs).
//
// Refs: a prompt's turn and user message are its uuid (maiD sets it to the
// delivery ID); a steer is its message's uuid, which the transcript keeps as
// the queued_command's source_uuid; a turn the CLI started on its own is
// "wake:" and its first API message id; a text or thinking block is its API
// message id and the block's index; a tool is its tool_use id. A subagent's
// turns are its runs, "agent-run:<agent>:<n>".
type mapper struct {
	emit func(provider.EventBody, time.Time)
	// session is the session's key, which names its subagents'.
	session string
	// turn is the open turn: by whom, whether it showed output, and how it
	// ends.
	turn       string
	by         provider.TurnSource
	output     bool
	state      provider.TurnState
	stopReason provider.StopReason
	errorText  string
	// ordinals counts each API message's blocks, which name them. A message
	// is closed once another follows it; the CLI sends a closed one again
	// after /compact (and keeps a copy after a compact boundary).
	ordinals map[string]int
	message  string
	closed   map[string]bool
	// streaming is the API message streaming live; streams are its open
	// blocks, by index.
	streaming string
	streams   map[int]*stream
	tools     map[string]*mappedTool
	tasks     taskPlan
	// compactions counts the open turn's compactions, which name them;
	// compacting: one is in progress.
	compactions int
	compacting  bool
	// agent names a subagent's session, whose turns are runs.
	agent string
	runs  int
	// runPrompt: the open run waits for its prompt, which joins it.
	runPrompt bool
}

type mappedTool struct {
	state *toolState
	turn  string
	ref   string
	// partial is the input streamed so far.
	partial string
}

// stream is a block streaming live: text onto an entry, or a tool's input.
type stream struct {
	ref    string
	kind   provider.ItemKind
	shown  bool
	tool   *mappedTool
	format provider.StreamKind
}

func newMapper(session string, emit func(provider.EventBody, time.Time)) *mapper {
	return &mapper{
		emit: emit, session: session, ordinals: make(map[string]int), closed: make(map[string]bool),
		streams: make(map[int]*stream), tools: make(map[string]*mappedTool),
	}
}

func (m *mapper) startTurn(ref string, by provider.TurnSource, delivery string, at time.Time) {
	m.endTurn(at)
	m.turn, m.by, m.output, m.state, m.stopReason, m.errorText = ref, by, false, provider.TurnCompleted, "", ""
	m.compactions, m.compacting = 0, false
	m.emit(provider.TurnStarted{Turn: ref, By: by, Delivery: delivery}, at)
}

// endTurn settles the open turn as it ended.
func (m *mapper) endTurn(at time.Time) {
	if m.turn == "" {
		return
	}
	m.emit(provider.TurnSettled{Turn: m.turn, State: m.state, StopReason: m.stopReason, Error: m.errorText}, at)
	m.turn = ""
	clear(m.streams)
}

// settle ends the open turn with the state the CLI's result reports.
func (m *mapper) settle(state provider.TurnState, stopReason provider.StopReason, errorText string, at time.Time) {
	if m.turn == "" {
		return
	}
	m.state, m.stopReason, m.errorText = state, stopReason, errorText
	m.endTurn(at)
}

// startRun opens a subagent's next run; its prompt joins it.
func (m *mapper) startRun(at time.Time) {
	m.runs++
	m.startTurn("agent-run:"+m.agent+":"+strconv.Itoa(m.runs), provider.TurnByProvider, "", at)
	m.runPrompt = true
}

// prompt is a user's message that starts a turn: of the session, or a
// subagent's run. Messages the CLI reads together as one query are prompts
// in a row; the later ones join the first's turn, as their echoes do live.
func (m *mapper) prompt(uuid, text string, attachments []provider.Attachment, at time.Time) {
	switch {
	case m.agent != "":
		if !m.runPrompt {
			m.startRun(at)
		}
		m.runPrompt = false
		// Live, a run's prompt is the input of the tool that ran it: the
		// CLI streams none of the subagent's own lines.
		for _, entry := range provider.UserMessageEntries(m.turn+"/prompt", m.turn, text, attachments, "", at) {
			m.emit(provider.EntryUpserted{Entry: entry}, at)
		}
		return
	case m.turn != "" && m.by == provider.TurnByClient && !m.output && m.state == provider.TurnCompleted:
	default:
		m.startTurn(uuid, provider.TurnByClient, uuid, at)
	}
	m.userMessage(uuid, text, attachments, at)
}

// echo is the CLI taking a message maiD wrote into a query
// (--replay-user-messages): folded into the running one, the steer the
// transcript records as a queued command; else the prompt of the next.
func (m *mapper) echo(uuid, text string, attachments []provider.Attachment, at time.Time) {
	if m.turn != "" {
		m.steer(uuid, text, attachments, at)
		return
	}
	m.prompt(uuid, text, attachments, at)
}

// steer is a message folded into the running turn.
func (m *mapper) steer(uuid, text string, attachments []provider.Attachment, at time.Time) {
	if m.turn == "" {
		m.startTurn(uuid, provider.TurnByClient, uuid, at)
	}
	m.userMessage(uuid, text, attachments, at)
}

func (m *mapper) userMessage(uuid, text string, attachments []provider.Attachment, at time.Time) {
	for _, entry := range provider.UserMessageEntries(uuid, m.turn, text, attachments, uuid, at) {
		m.emit(provider.EntryUpserted{Entry: entry}, at)
	}
}

// wake: a message from elsewhere (a background task finishing) woke the
// CLI. What came before is over; its output starts a turn of its own.
func (m *mapper) wake(at time.Time) { m.endTurn(at) }

// ensureTurn opens a turn for output with none open: the CLI's own.
func (m *mapper) ensureTurn(messageID string, at time.Time) {
	if m.turn != "" {
		return
	}
	if m.agent != "" {
		m.startRun(at)
		return
	}
	m.startTurn("wake:"+messageID, provider.TurnByProvider, "", at)
}

// blockRef names an API message's next block.
func (m *mapper) blockRef(messageID string) string {
	index := m.ordinals[messageID]
	m.ordinals[messageID] = index + 1
	return messageID + "/" + strconv.Itoa(index)
}

// assistant is one block of an assistant message, whole.
func (m *mapper) assistant(messageID string, block contentBlock, at time.Time) {
	if m.closed[messageID] {
		return
	}
	if messageID != m.message {
		if m.message != "" {
			m.closed[m.message] = true
		}
		m.message = messageID
	}
	m.ensureTurn(messageID, at)
	m.output = true
	ref := m.blockRef(messageID)
	switch block.Type {
	case "text", "thinking":
		kind, text := provider.ItemKindAssistantMessage, block.Text
		if block.Type == "thinking" {
			kind, text = provider.ItemKindReasoning, block.Thinking
		}
		if text != "" {
			m.emit(provider.EntryUpserted{Entry: provider.Entry{Ref: ref, Turn: m.turn, Kind: kind, Status: provider.ItemStatusCompleted, Text: text, At: at}}, at)
		}
	case "tool_use", "server_tool_use", "mcp_tool_use":
		m.toolUse(block.ID, block.Name, block.Input, at)
	}
}

// streamStart opens a block of the live message: an entry its text streams
// onto (named as the whole block will be), or a tool whose input streams.
func (m *mapper) streamStart(messageID string, index int, block contentBlock, at time.Time) {
	if m.closed[messageID] {
		return
	}
	m.ensureTurn(messageID, at)
	m.output = true
	switch block.Type {
	case "text":
		m.streams[index] = &stream{ref: messageID + "/" + strconv.Itoa(index), kind: provider.ItemKindAssistantMessage, format: provider.StreamAssistant}
	case "thinking":
		m.streams[index] = &stream{ref: messageID + "/" + strconv.Itoa(index), kind: provider.ItemKindReasoning, format: provider.StreamReasoning}
	case "tool_use", "server_tool_use", "mcp_tool_use":
		m.streams[index] = &stream{tool: m.toolUse(block.ID, block.Name, block.Input, at)}
	}
}

// streamText streams text onto an open block. Its entry shows with its first
// text, so a block that streams none (redacted thinking) never shows.
func (m *mapper) streamText(index int, text string, at time.Time) {
	open := m.streams[index]
	if open == nil || open.tool != nil || text == "" {
		return
	}
	if !open.shown {
		open.shown = true
		m.emit(provider.EntryUpserted{Entry: provider.Entry{Ref: open.ref, Turn: m.turn, Kind: open.kind, Status: provider.ItemStatusInProgress, Text: text, At: at}}, at)
		return
	}
	m.emit(provider.TextAppended{Entry: open.ref, Turn: m.turn, Stream: open.format, Text: text}, at)
}

// streamInput streams a tool's input; it shows each time it parses anew.
func (m *mapper) streamInput(index int, partial string, at time.Time) {
	open := m.streams[index]
	if open == nil || open.tool == nil {
		return
	}
	tool := open.tool
	tool.partial += partial
	var input json.RawMessage
	if json.Unmarshal([]byte(tool.partial), &input) != nil || string(input) == string(tool.state.input) {
		return
	}
	m.toolUse(tool.ref, tool.state.call.ProviderKind, input, at)
}

func (m *mapper) streamStop(index int) { delete(m.streams, index) }

// toolUse records a tool call; a plan tool (TodoWrite) shows as the plan.
func (m *mapper) toolUse(id, name string, input json.RawMessage, at time.Time) *mappedTool {
	if tool := m.tools[id]; tool != nil {
		if string(input) == string(tool.state.input) {
			return tool
		}
		tool.state = rebuiltToolState(tool.state, input)
		if tool.state.itemKind == "" {
			if entries := planEntriesFromInput(input); entries != nil {
				m.emit(provider.PlanChanged{Entries: entries}, at)
			}
			return tool
		}
		m.toolEntry(tool, provider.ItemStatusInProgress, at)
		return tool
	}
	m.ensureTurn(id, at)
	tool := &mappedTool{state: newToolState(name, input), turn: m.turn, ref: id}
	m.tools[id] = tool
	if tool.state.itemKind == "" {
		if entries := planEntriesFromInput(input); entries != nil {
			m.emit(provider.PlanChanged{Entries: entries}, at)
		}
		return tool
	}
	m.toolEntry(tool, provider.ItemStatusInProgress, at)
	return tool
}

// rebuiltToolState is a tool's state from newer input, keeping a result
// already recorded.
func rebuiltToolState(state *toolState, input json.RawMessage) *toolState {
	rebuilt := newToolState(state.call.ProviderKind, input)
	rebuilt.call.Output = firstNonEmpty(state.call.Output, rebuilt.call.Output)
	rebuilt.call.Error = state.call.Error
	return rebuilt
}

func (m *mapper) toolEntry(tool *mappedTool, status provider.ItemStatus, at time.Time) {
	if tool.state.itemKind == "" {
		return
	}
	if tool.state.itemKind == provider.ItemKindAssistantMessage {
		if status == provider.ItemStatusInProgress {
			status = provider.ItemStatusCompleted
		}
		m.emit(provider.EntryUpserted{Entry: provider.Entry{Ref: tool.ref, Turn: tool.turn, Kind: provider.ItemKindAssistantMessage, Status: status, Text: tool.state.text, At: at}}, at)
		return
	}
	call := tool.state.call
	m.emit(provider.EntryUpserted{Entry: provider.Entry{
		Ref: tool.ref, Turn: tool.turn, Kind: tool.state.itemKind, Status: status, Title: tool.state.title, Tool: &call, At: at,
	}}, at)
}

// toolResult records a tool's result. One that started a background task
// runs on until the task's notification.
func (m *mapper) toolResult(block contentBlock, structured json.RawMessage, at time.Time) {
	tool := m.tools[block.ToolUseID]
	if tool == nil {
		return
	}
	if tool.state.itemKind == "" {
		delete(m.tools, block.ToolUseID)
		if !block.IsError && m.tasks.apply(tool.state.call.ProviderKind, tool.state.input, structured) {
			m.emit(provider.PlanChanged{Entries: m.tasks.entries()}, at)
		}
		return
	}
	status := tool.state.applyResult(block, structured)
	if status != provider.ItemStatusInProgress {
		delete(m.tools, block.ToolUseID)
	}
	m.toolEntry(tool, status, at)
	m.subagent(block.ToolUseID, structured, at)
}

// subagent names the subagent an Agent tool ran, from the tool's result.
func (m *mapper) subagent(toolUseID string, structured json.RawMessage, at time.Time) {
	var result struct {
		AgentID       string `json:"agentId"`
		Description   string `json:"description"`
		ResolvedModel string `json:"resolvedModel"`
	}
	if json.Unmarshal(structured, &result) != nil || result.AgentID == "" {
		return
	}
	// Nested subagents are keyed under the session too; the transcripts all
	// live in its subagents directory.
	root, _ := splitSubagentKey(m.session)
	m.emit(provider.SubagentSeen{
		Parent: m.session, Item: toolUseID, Session: subagentKey(root, result.AgentID),
		Name: result.Description, Model: result.ResolvedModel,
	}, at)
}

// subagentKey is the session key of a session's subagent.
func subagentKey(session, agent string) string { return session + "/agent-" + agent }

// taskEnded completes the tool whose background task ended, in the turn
// that started it. A tool running in the foreground is a task too, whose
// notification comes before its result; the result ends it.
func (m *mapper) taskEnded(notification taskNotification, at time.Time) {
	tool := m.tools[notification.ToolUseID]
	if tool == nil || !tool.state.call.Background {
		return
	}
	delete(m.tools, notification.ToolUseID)
	m.toolEntry(tool, tool.state.finish(notification), at)
}

// compaction shows a compaction of the open turn, named by its count in the
// turn: live it shows in progress first, replay has only its end.
func (m *mapper) compaction(status provider.ItemStatus, errorText string, at time.Time) {
	if m.turn == "" {
		return
	}
	// What the CLI keeps of the conversation it sends again after a
	// compaction.
	if m.message != "" {
		m.closed[m.message] = true
	}
	if !m.compacting {
		m.compactions++
	}
	m.compacting = status == provider.ItemStatusInProgress
	title := "Compacted context"
	switch status {
	case provider.ItemStatusInProgress:
		title = "Compacting context"
	case provider.ItemStatusFailed:
		title = trimmedOrDefault(errorText, "Compaction failed")
	}
	m.emit(provider.EntryUpserted{Entry: provider.Entry{
		Ref: "compaction:" + m.turn + ":" + strconv.Itoa(m.compactions), Turn: m.turn, Kind: provider.ItemKindContextCompaction, Status: status, Title: title, At: at,
	}}, at)
}

// interrupted: the user stopped the open turn.
func (m *mapper) interrupted() {
	if m.turn != "" {
		m.state = provider.TurnInterrupted
	}
}

// failed: the open turn failed with an API error.
func (m *mapper) failed(errorText string) {
	if m.turn != "" {
		m.state, m.errorText = provider.TurnFailed, firstNonEmpty(strings.TrimSpace(errorText), m.errorText)
	}
}

// cutOff ends tools still running when their session stopped.
func (m *mapper) cutOff(at time.Time) {
	for id, tool := range m.tools {
		delete(m.tools, id)
		m.toolEntry(tool, provider.ItemStatusInterrupted, at)
	}
}
