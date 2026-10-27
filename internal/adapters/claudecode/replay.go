package claudecode

import (
	"encoding/json"
	"regexp"
	"strings"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// transcriptHistory is a session's history from its transcript: only the
// current conversation (see conversation), one turn per prompt, steers inside
// their turn, turns that were interrupted or failed as such, through the
// mapper the live session uses. agent names a subagent's transcript, whose
// turns are its runs. With running, the last turn is still running live.
func transcriptHistory(session, agent string, lines []transcriptLine, running bool) ([]provider.HistoryTurn, []provider.SubagentSeen) {
	var builder provider.HistoryBuilder
	var subagents []provider.SubagentSeen
	m := newMapper(session, func(body provider.EventBody, at time.Time) {
		if seen, ok := body.(provider.SubagentSeen); ok {
			subagents = append(subagents, seen)
		}
		builder.Add(provider.Event{At: at, Body: body})
	})
	m.agent = agent
	replayTranscript(m, lines, running, nil)
	return builder.Turns(), subagents
}

// turnEnd is the uuid of the last line of the turn ref, the line a fork
// through that turn ends at.
func turnEnd(lines []transcriptLine, ref string) (string, bool) {
	m := newMapper("", func(provider.EventBody, time.Time) {})
	ends := make(map[string]string)
	replayTranscript(m, lines, false, func(line transcriptLine) {
		if m.turn != "" && line.chained() {
			ends[m.turn] = line.UUID
		}
	})
	end, ok := ends[ref]
	return end, ok
}

// replayTranscript feeds the conversation's lines to the mapper, calling
// after with each line it took. Unless running, the last turn ended with the
// transcript.
func replayTranscript(m *mapper, lines []transcriptLine, running bool, after func(transcriptLine)) {
	onConversation := conversation(lines)
	var last time.Time
	at := func(stamp string) time.Time {
		if parsed, err := time.Parse(time.RFC3339Nano, stamp); err == nil {
			last = parsed
		}
		return last
	}
	for index, line := range lines {
		if line.IsSidechain && m.agent == "" || line.chained() && !onConversation[index] {
			continue
		}
		when := at(line.Timestamp)
		switch line.Type {
		case "system":
			if line.Subtype == "compact_boundary" {
				m.compaction(provider.ItemStatusCompleted, "", when)
			}
		case "attachment":
			if item := line.Attachment; item != nil && item.CommandMode == "task-notification" {
				// A background task that ended during a turn is queued as its
				// notification.
				prompt, _ := promptContent(userAPIMessage{Content: item.Prompt}.blocks())
				if notification, ok := parseTaskNotification(prompt); ok {
					m.taskEnded(notification, when)
				}
			}
			// A steer the CLI folded into a running query joins that turn,
			// as it did live.
			if text, attachments, ok := steeredPrompt(line.Attachment); ok {
				m.steer(firstNonEmpty(line.Attachment.SourceUUID, line.UUID), text, attachments, when)
			}
		case "user":
			replayUser(m, line, when)
		case "assistant":
			var api apiMessage
			if json.Unmarshal(line.Message, &api) != nil {
				continue
			}
			if line.IsAPIErrorMessage {
				// The CLI writes a failed API request as an assistant message
				// whose text is the error; the turn failed with it.
				m.ensureTurn(api.ID, when)
				for _, block := range api.Content {
					m.failed(block.Text)
				}
				continue
			}
			for _, block := range api.Content {
				m.assistant(firstNonEmpty(api.ID, line.UUID), block, when)
			}
		}
		if after != nil {
			after(line)
		}
	}
	if running {
		return
	}
	// Tools with no recorded result were cut off mid-flight.
	m.cutOff(last)
	m.endTurn(last)
}

func replayUser(m *mapper, line transcriptLine, at time.Time) {
	var api userAPIMessage
	if json.Unmarshal(line.Message, &api) != nil {
		return
	}
	blocks, text := api.blocks()
	hasToolResult := false
	for _, block := range blocks {
		if block.Type == "tool_result" {
			hasToolResult = true
			m.toolResult(block, line.ToolUseResult, at)
		}
	}
	if hasToolResult {
		return
	}
	// A background task that ended while the CLI was idle wakes it with its
	// notification.
	if content, _ := promptContent(blocks, text); content != "" {
		if notification, ok := parseTaskNotification(content); ok {
			m.taskEnded(notification, at)
		}
	}
	prompt := classifyUserLine(line, blocks, text)
	switch prompt.kind {
	case userLineHidden:
		// A local command's output ends what the command ran; the next
		// prompt is a query of its own.
		m.output = m.output || m.turn != ""
	case userLineInterrupt:
		m.interrupted()
	case userLineWake:
		m.wake(at)
	case userLinePrompt:
		m.prompt(line.UUID, prompt.text, prompt.attachments, at)
	}
}

// userLineKind is what a user line without tool results is to the
// conversation.
type userLineKind int

const (
	// userLineHidden is CLI bookkeeping written as a user message: local
	// command output, the compaction summary, meta lines.
	userLineHidden userLineKind = iota
	userLinePrompt
	// userLineWake is a message from elsewhere (a background task finishing)
	// that starts a turn with no prompt.
	userLineWake
	// userLineInterrupt is the marker the CLI writes when the user
	// interrupts a turn.
	userLineInterrupt
)

type userLine struct {
	kind        userLineKind
	text        string
	attachments []provider.Attachment
}

var (
	commandNamePattern = regexp.MustCompile(`<command-name>(.*?)</command-name>`)
	commandArgsPattern = regexp.MustCompile(`(?s)<command-args>(.*?)</command-args>`)
)

// classifyUserLine sorts a user line, following the lines the SDK's session
// listing skips. A slash command is written as markup; it shows as typed.
func classifyUserLine(line transcriptLine, blocks []contentBlock, text string) userLine {
	text, attachments := promptContent(blocks, text)
	trimmed := strings.TrimSpace(text)
	switch {
	// A message from elsewhere wakes the CLI even when it is a meta line,
	// as a background subagent's report is.
	case !line.Origin.fromUser():
		return userLine{kind: userLineWake}
	case line.IsMeta || line.IsCompactSummary || line.IsVisibleInTranscriptOnly:
		return userLine{kind: userLineHidden}
	case strings.HasPrefix(trimmed, "[Request interrupted by user"):
		return userLine{kind: userLineInterrupt}
	case strings.HasPrefix(trimmed, "<local-command-"):
		return userLine{kind: userLineHidden}
	case trimmed == "" && len(attachments) == 0:
		return userLine{kind: userLineHidden}
	}
	if match := commandNamePattern.FindStringSubmatch(trimmed); match != nil {
		text = strings.TrimSpace(match[1])
		if args := commandArgsPattern.FindStringSubmatch(trimmed); args != nil && strings.TrimSpace(args[1]) != "" {
			text += " " + strings.TrimSpace(args[1])
		}
	}
	return userLine{kind: userLinePrompt, text: text, attachments: attachments}
}
