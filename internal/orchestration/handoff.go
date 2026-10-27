package orchestration

import (
	"fmt"
	"slices"
	"strconv"
	"strings"

	"github.com/Aqothy/maiD/internal/provider"
)

// handoffBudget bounds a handoff, about 16k tokens: the newest turns that
// fit, the chat's first message, and a note of what was left out.
const handoffBudget = 64_000

// handoff catches a participant up on the thread's turns its session hasn't
// seen: those after its SeenThrough that it didn't run in that
// session, or, for a session that has none of the chat, all of them.
// Computed from the cache when the turn starts, never stored.
func (e *Engine) handoff(thread *threadState, participant *participantState) (*provider.Envelope, error) {
	if thread.latest == nil || participant.SeenThrough == thread.latest.ID {
		// It has seen every turn, as one agent alone in a chat always has.
		return nil, nil
	}
	var seen *Turn
	if participant.SeenThrough != "" {
		turn, ok, err := e.db.turn(e.ctx, participant.SeenThrough)
		if err != nil {
			return nil, err
		}
		if ok {
			seen = &turn
		}
	}
	turns, err := e.db.threadTurnsAfter(e.ctx, thread.ID, seen)
	if err != nil {
		return nil, err
	}
	var missed []Turn
	for _, turn := range turns {
		if turn.State == provider.TurnRunning {
			continue
		}
		// Its session saw the turns it ran itself, unless they ran in a
		// session it lost.
		if turn.Participant == participant.ID && turn.Session == participant.Session {
			continue
		}
		missed = append(missed, turn)
	}
	if len(missed) == 0 {
		return nil, nil
	}
	body, err := e.transcript(missed, handoffBudget)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(body) == "" {
		return nil, nil
	}
	covers := "1 turn"
	if len(missed) != 1 {
		covers = strconv.Itoa(len(missed)) + " turns"
	}
	return &provider.Envelope{Kind: provider.EnvelopeHandoff, Thread: string(thread.ID), Covers: covers, Body: body}, nil
}

// transcript writes turns as a conversation a model can read: who said what,
// and each tool call with its bounded previews, the newest turns that fit
// budget, with the first message and a note of what was left out.
func (e *Engine) transcript(turns []Turn, budget int) (string, error) {
	// Newest first, reading only the turns that fit.
	var kept []string
	size, left := 0, 0
	for index := len(turns) - 1; index >= 0; index-- {
		block, err := e.turnBlock(turns[index])
		if err != nil {
			return "", err
		}
		if size+len(block) > budget {
			left = index + 1
			break
		}
		size += len(block)
		kept = append(kept, block)
	}
	slices.Reverse(kept)
	var text strings.Builder
	if left > 0 {
		// The chat's first request frames what follows it.
		for _, turn := range turns[:left] {
			block, err := e.turnBlock(turn)
			if err != nil {
				return "", err
			}
			if user, _, _ := strings.Cut(block, "\n\n"); strings.HasPrefix(user, "User:") {
				if len(user) <= budget/4 {
					text.WriteString(user + "\n\n")
				}
				break
			}
		}
		fmt.Fprintf(&text, "[%d earlier turns left out.]\n\n", left)
	}
	for _, block := range kept {
		if block != "" {
			text.WriteString(block + "\n\n")
		}
	}
	return strings.TrimSpace(text.String()), nil
}

// turnBlock is one turn of a transcript.
func (e *Engine) turnBlock(turn Turn) (string, error) {
	participant := e.participants[turn.Participant]
	if participant == nil {
		return "", nil
	}
	entries, err := e.db.turnEntries(e.ctx, participant.Instance, turn.Session, turn.Ref)
	if err != nil {
		return "", err
	}
	return turnText(e.instanceName(participant.Instance), turn, entries), nil
}

func turnText(agent string, turn Turn, entries []provider.Entry) string {
	var text strings.Builder
	add := func(heading, body string) {
		if body = strings.TrimSpace(body); body == "" {
			return
		}
		if text.Len() > 0 {
			text.WriteString("\n\n")
		}
		text.WriteString(heading + ":\n" + body)
	}
	for _, entry := range entries {
		switch entry.Kind {
		case provider.ItemKindUserMessage:
			add("User", promptText(entry.Text, entry.Annotations))
		case provider.ItemKindAssistantMessage:
			add(agent, entry.Text)
		case provider.ItemKindEnvelope:
			if envelope := entry.Envelope; envelope != nil {
				switch envelope.Kind {
				case provider.EnvelopeMessage, provider.EnvelopeReply, provider.EnvelopeNotice:
					add(firstNonEmpty(envelope.From, "maiD")+" ("+string(envelope.Kind)+")", envelope.Body)
				}
			}
		default:
			if entry.Tool != nil {
				add(agent+" ran a tool", toolText(entry))
			}
		}
	}
	if turn.State == provider.TurnFailed {
		add(agent+" failed", turn.Error)
	}
	return text.String()
}

func toolText(entry provider.Entry) string {
	summary := summarizeToolCall(entry.Tool)
	lines := []string{firstNonEmpty(entry.Title, summary.Name)}
	for _, field := range []string{summary.CommandPreview, summary.QueryPreview, summary.OutputPreview, summary.ErrorPreview} {
		if field = strings.TrimSpace(field); field != "" {
			lines = append(lines, field)
		}
	}
	for _, change := range summary.Changes {
		lines = append(lines, firstNonEmpty(string(change.Kind), "changed")+" "+change.Path)
	}
	return strings.Join(lines, "\n")
}
