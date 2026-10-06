package claudecode

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

var sessionIDPattern = regexp.MustCompile(`^[0-9a-fA-F-]{8,64}$`)

// mungeProjectPath mirrors the CLI's project directory encoding: every
// non-alphanumeric character becomes '-'.
func mungeProjectPath(cwd string) string {
	var builder strings.Builder
	for _, r := range cwd {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			builder.WriteRune(r)
		} else {
			builder.WriteByte('-')
		}
	}
	return builder.String()
}

func (h *Instance) projectDir(cwd string) string {
	configDir := h.configDir()
	if configDir == "" || cwd == "" {
		return ""
	}
	return filepath.Join(configDir, "projects", mungeProjectPath(cwd))
}

func (h *Instance) transcriptPath(cwd, sessionID string) string {
	dir := h.projectDir(cwd)
	if dir == "" || !sessionIDPattern.MatchString(sessionID) {
		return ""
	}
	return filepath.Join(dir, sessionID+".jsonl")
}

func (h *Instance) transcriptExists(cwd, sessionID string) bool {
	path := h.transcriptPath(cwd, sessionID)
	if path == "" {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

// findTranscript locates a transcript by session id across all project dirs.
func (h *Instance) findTranscript(sessionID string) (string, error) {
	if !sessionIDPattern.MatchString(sessionID) {
		return "", fmt.Errorf("invalid Claude Code session id %q", sessionID)
	}
	configDir := h.configDir()
	if configDir == "" {
		return "", fmt.Errorf("Claude Code config directory is unavailable")
	}
	projects := filepath.Join(configDir, "projects")
	entries, err := os.ReadDir(projects)
	if err != nil {
		return "", err
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		candidate := filepath.Join(projects, entry.Name(), sessionID+".jsonl")
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("Claude Code session %q has no transcript", sessionID)
}

func (h *Instance) readTranscript(cwd, sessionID string) ([]transcriptLine, error) {
	path := h.transcriptPath(cwd, sessionID)
	if path == "" || !h.transcriptExists(cwd, sessionID) {
		found, err := h.findTranscript(sessionID)
		if err != nil {
			return nil, err
		}
		path = found
	}
	return readTranscriptFile(path)
}

func readTranscriptFile(path string) ([]transcriptLine, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 1<<20), maxMessageBytes)
	var lines []transcriptLine
	for scanner.Scan() {
		raw := scanner.Bytes()
		if len(raw) == 0 {
			continue
		}
		var line transcriptLine
		if json.Unmarshal(raw, &line) != nil {
			continue
		}
		lines = append(lines, line)
	}
	return lines, scanner.Err()
}

// replayEventsFromTranscript rebuilds the canonical event stream from a
// persisted transcript. Event ids are deterministic and timestamps are nudged
// by microsecond offsets so ordering is stable, mirroring codexapp replay.
func replayEventsFromTranscript(threadID string, lines []transcriptLine) []provider.RuntimeEvent {
	events := make([]provider.RuntimeEvent, 0, len(lines))
	type replayTool struct {
		state  *toolState
		turnID string
		at     time.Time
	}
	pendingTools := make(map[string]*replayTool)
	currentTurn := ""
	title := ""
	var lastAt time.Time
	offset := 0

	nextAt := func(stamp string) time.Time {
		offset++
		if parsed, err := time.Parse(time.RFC3339Nano, stamp); err == nil {
			lastAt = parsed
			return parsed
		}
		return lastAt.Add(time.Duration(offset) * time.Microsecond)
	}
	eventID := func(turn, item, suffix string) provider.RuntimeEventID {
		return provider.RuntimeEventID("claude:replay:" + turn + ":" + item + ":" + suffix)
	}
	closeTurn := func(at time.Time) {
		if currentTurn == "" {
			return
		}
		events = append(events, provider.RuntimeEvent{
			EventID: eventID(currentTurn, "", "turn-completed"), Type: provider.RuntimeEventTurnCompleted,
			Provider: DriverKind, ThreadID: threadID, TurnID: currentTurn, CreatedAt: at.Add(time.Nanosecond),
			Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnCompleted},
		})
		currentTurn = ""
	}

	for _, line := range lines {
		if line.IsSidechain || line.IsMeta {
			continue
		}
		switch line.Type {
		case "ai-title":
			title = line.AITitle
		case "user":
			var api userAPIMessage
			if json.Unmarshal(line.Message, &api) != nil {
				continue
			}
			blocks, text := api.blocks()
			hasToolResult := false
			for _, block := range blocks {
				if block.Type == "tool_result" {
					hasToolResult = true
					pending := pendingTools[block.ToolUseID]
					if pending == nil || pending.state.itemKind == "" {
						continue
					}
					at := nextAt(line.Timestamp)
					output, attachments := toolResultContent(block.Content)
					status := provider.ItemStatusCompleted
					if block.IsError {
						status = provider.ItemStatusFailed
						pending.state.call.Error = boundedOutput(output)
					} else {
						pending.state.call.Output = boundedOutput(output)
					}
					pending.state.call.Attachments = append(pending.state.call.Attachments, attachments...)
					call := pending.state.call
					events = append(events, provider.RuntimeEvent{
						EventID: eventID(pending.turnID, block.ToolUseID, "completed"), Type: provider.RuntimeEventItemCompleted,
						Provider: DriverKind, ThreadID: threadID, TurnID: pending.turnID, ItemID: block.ToolUseID, CreatedAt: at,
						Payload: provider.RuntimeEventPayload{ItemType: pending.state.itemKind, ItemStatus: status, Title: pending.state.title, ToolCall: &call},
					})
					delete(pendingTools, block.ToolUseID)
				}
			}
			if hasToolResult {
				continue
			}
			promptText := text
			var attachments []provider.Attachment
			for _, block := range blocks {
				switch block.Type {
				case "text":
					if promptText != "" {
						promptText += "\n"
					}
					promptText += block.Text
				case "image":
					if block.Source != nil {
						attachments = append(attachments, provider.Attachment{Kind: "image", MimeType: block.Source.MediaType, Data: block.Source.Data})
					}
				}
			}
			if strings.TrimSpace(promptText) == "" && len(attachments) == 0 {
				continue
			}
			at := nextAt(line.Timestamp)
			closeTurn(at)
			currentTurn = firstNonEmpty(line.UUID, fmt.Sprintf("turn-%d", offset))
			events = append(events, provider.RuntimeEvent{
				EventID: eventID(currentTurn, "", "turn-started"), Type: provider.RuntimeEventTurnStarted,
				Provider: DriverKind, ThreadID: threadID, TurnID: currentTurn, CreatedAt: at,
			})
			events = append(events, provider.RuntimeEvent{
				EventID: eventID(currentTurn, currentTurn, "user"), Type: provider.RuntimeEventItemCompleted,
				Provider: DriverKind, ThreadID: threadID, TurnID: currentTurn, ItemID: "user:" + currentTurn, CreatedAt: at.Add(time.Nanosecond),
				Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindUserMessage, ItemStatus: provider.ItemStatusCompleted, Detail: promptText, Attachments: attachments},
			})
		case "assistant":
			if currentTurn == "" {
				continue
			}
			var api apiMessage
			if json.Unmarshal(line.Message, &api) != nil {
				continue
			}
			at := nextAt(line.Timestamp)
			for index, block := range api.Content {
				itemID := fmt.Sprintf("%s:%d", firstNonEmpty(line.UUID, api.ID), index)
				blockAt := at.Add(time.Duration(index) * time.Microsecond)
				switch block.Type {
				case "text":
					if block.Text == "" {
						continue
					}
					events = append(events, provider.RuntimeEvent{
						EventID: eventID(currentTurn, itemID, "content"), Type: provider.RuntimeEventContentDelta,
						Provider: DriverKind, ThreadID: threadID, TurnID: currentTurn, ItemID: itemID, CreatedAt: blockAt,
						Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: block.Text},
					})
					events = append(events, provider.RuntimeEvent{
						EventID: eventID(currentTurn, itemID, "completed"), Type: provider.RuntimeEventItemCompleted,
						Provider: DriverKind, ThreadID: threadID, TurnID: currentTurn, ItemID: itemID, CreatedAt: blockAt.Add(time.Nanosecond),
						Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindAssistantMessage, ItemStatus: provider.ItemStatusCompleted},
					})
				case "thinking":
					if block.Thinking == "" {
						continue
					}
					events = append(events, provider.RuntimeEvent{
						EventID: eventID(currentTurn, itemID, "content"), Type: provider.RuntimeEventContentDelta,
						Provider: DriverKind, ThreadID: threadID, TurnID: currentTurn, ItemID: itemID, CreatedAt: blockAt,
						Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentReasoningText, Delta: block.Thinking},
					})
				case "tool_use":
					state := newToolState(block.Name, block.Input)
					if state.itemKind == "" {
						if entries := planEntriesFromInput(block.Input); entries != nil {
							events = append(events, provider.RuntimeEvent{
								EventID: eventID(currentTurn, itemID, "plan"), Type: provider.RuntimeEventTurnPlanUpdated,
								Provider: DriverKind, ThreadID: threadID, TurnID: currentTurn, CreatedAt: blockAt,
								Payload: provider.RuntimeEventPayload{PlanEntries: entries},
							})
						}
						continue
					}
					call := state.call
					events = append(events, provider.RuntimeEvent{
						EventID: eventID(currentTurn, block.ID, "started"), Type: provider.RuntimeEventItemStarted,
						Provider: DriverKind, ThreadID: threadID, TurnID: currentTurn, ItemID: block.ID, CreatedAt: blockAt,
						Payload: provider.RuntimeEventPayload{ItemType: state.itemKind, ItemStatus: provider.ItemStatusInProgress, Title: state.title, ToolCall: &call},
					})
					pendingTools[block.ID] = &replayTool{state: state, turnID: currentTurn, at: blockAt}
				}
			}
		}
	}
	// Tools with no recorded result were cut off mid-flight.
	for id, pending := range pendingTools {
		call := pending.state.call
		events = append(events, provider.RuntimeEvent{
			EventID: eventID(pending.turnID, id, "completed"), Type: provider.RuntimeEventItemCompleted,
			Provider: DriverKind, ThreadID: threadID, TurnID: pending.turnID, ItemID: id, CreatedAt: pending.at.Add(time.Millisecond),
			Payload: provider.RuntimeEventPayload{ItemType: pending.state.itemKind, ItemStatus: provider.ItemStatusInterrupted, Title: pending.state.title, ToolCall: &call},
		})
	}
	closeTurn(lastAt.Add(time.Duration(offset+1) * time.Microsecond))
	if title != "" {
		events = append(events, provider.RuntimeEvent{
			EventID: provider.RuntimeEventID("claude:replay:title"), Type: provider.RuntimeEventThreadMetadataUpdate,
			Provider: DriverKind, ThreadID: threadID, CreatedAt: lastAt.Add(time.Duration(offset+2) * time.Microsecond),
			Payload: provider.RuntimeEventPayload{Title: title},
		})
	}
	return events
}

// transcriptSummary extracts the display title and cwd cheaply: the first
// prompt and metadata live in the head of the file; a generated ai-title line
// may appear anywhere in the first few hundred lines.
func transcriptSummary(path string) (title, cwd string) {
	file, err := os.Open(path)
	if err != nil {
		return "", ""
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 1<<20), maxMessageBytes)
	firstPrompt := ""
	for count := 0; scanner.Scan() && count < 400; count++ {
		var line transcriptLine
		if json.Unmarshal(scanner.Bytes(), &line) != nil {
			continue
		}
		if line.AITitle != "" {
			title = line.AITitle
		}
		if cwd == "" && line.Cwd != "" {
			cwd = line.Cwd
		}
		if firstPrompt == "" && line.Type == "user" && !line.IsMeta && !line.IsSidechain {
			var api userAPIMessage
			if json.Unmarshal(line.Message, &api) == nil {
				blocks, text := api.blocks()
				if text == "" {
					for _, block := range blocks {
						if block.Type == "text" && block.Text != "" {
							text = block.Text
							break
						}
					}
				}
				firstPrompt = provider.PromptPreviewTitle(text)
			}
		}
		if title != "" && cwd != "" && firstPrompt != "" {
			break
		}
	}
	if title == "" {
		title = firstPrompt
	}
	return title, cwd
}

func (h *Instance) ListSessions(_ context.Context, cwd string) ([]provider.SessionSummary, error) {
	configDir := h.configDir()
	if configDir == "" {
		return nil, fmt.Errorf("Claude Code config directory is unavailable")
	}
	var dirs []string
	if cwd != "" {
		dirs = []string{h.projectDir(cwd)}
	} else {
		projects := filepath.Join(configDir, "projects")
		entries, err := os.ReadDir(projects)
		if err != nil {
			if os.IsNotExist(err) {
				return []provider.SessionSummary{}, nil
			}
			return nil, err
		}
		for _, entry := range entries {
			if entry.IsDir() {
				dirs = append(dirs, filepath.Join(projects, entry.Name()))
			}
		}
	}
	summaries := make([]provider.SessionSummary, 0)
	for _, dir := range dirs {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, entry := range entries {
			name := entry.Name()
			if entry.IsDir() || !strings.HasSuffix(name, ".jsonl") {
				continue
			}
			sessionID := strings.TrimSuffix(name, ".jsonl")
			if !sessionIDPattern.MatchString(sessionID) {
				continue
			}
			path := filepath.Join(dir, name)
			title, sessionCwd := transcriptSummary(path)
			if sessionCwd == "" {
				sessionCwd = cwd
			}
			updatedAt := ""
			if info, err := entry.Info(); err == nil {
				updatedAt = info.ModTime().UTC().Format(time.RFC3339Nano)
			}
			summaries = append(summaries, provider.SessionSummary{
				SessionID: sessionID,
				Title:     title,
				Cwd:       sessionCwd,
				UpdatedAt: updatedAt,
			})
		}
	}
	sort.Slice(summaries, func(i, j int) bool { return summaries[i].UpdatedAt > summaries[j].UpdatedAt })
	return summaries, nil
}

func (h *Instance) DeleteSession(_ context.Context, sessionID string) error {
	path, err := h.findTranscript(sessionID)
	if err != nil {
		return err
	}
	h.mu.Lock()
	local := h.localByNative[sessionID]
	session := h.sessionsByLocal[local]
	h.mu.Unlock()
	if session != nil {
		h.stopProcess(session)
		h.mu.Lock()
		delete(h.sessionsByLocal, local)
		delete(h.localByNative, sessionID)
		h.mu.Unlock()
	}
	return os.Remove(path)
}

func (h *Instance) CloseSession(_ context.Context, sessionID string) error {
	h.mu.Lock()
	local := h.localByNative[sessionID]
	session := h.sessionsByLocal[local]
	h.mu.Unlock()
	if session == nil {
		return nil
	}
	h.stopProcess(session)
	h.mu.Lock()
	if h.sessionsByLocal[local] == session {
		delete(h.sessionsByLocal, local)
		if h.localByNative[sessionID] == local {
			delete(h.localByNative, sessionID)
		}
	}
	h.mu.Unlock()
	return nil
}

// ForkSession copies the transcript under a fresh session id, rewriting the
// per-line session id so the fork resumes independently of the original.
func (h *Instance) ForkSession(_ context.Context, input provider.ForkSessionInput) (provider.ForkSessionResult, error) {
	if input.ProviderSessionID == "" {
		return provider.ForkSessionResult{}, fmt.Errorf("Claude Code fork requires a provider session id")
	}
	sourcePath, err := h.findTranscript(input.ProviderSessionID)
	if err != nil {
		return provider.ForkSessionResult{}, err
	}
	forkID, err := newSessionUUID()
	if err != nil {
		return provider.ForkSessionResult{}, err
	}
	targetPath := filepath.Join(filepath.Dir(sourcePath), forkID+".jsonl")
	source, err := os.Open(sourcePath)
	if err != nil {
		return provider.ForkSessionResult{}, err
	}
	defer source.Close()
	target, err := os.OpenFile(targetPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return provider.ForkSessionResult{}, err
	}
	writer := bufio.NewWriter(target)
	scanner := bufio.NewScanner(source)
	scanner.Buffer(make([]byte, 0, 1<<20), maxMessageBytes)
	for scanner.Scan() {
		raw := scanner.Bytes()
		if len(raw) == 0 {
			continue
		}
		var line map[string]any
		if json.Unmarshal(raw, &line) == nil {
			if _, has := line["sessionId"]; has {
				line["sessionId"] = forkID
				if encoded, err := json.Marshal(line); err == nil {
					raw = encoded
				}
			}
		}
		if _, err := writer.Write(append(raw, '\n')); err != nil {
			_ = target.Close()
			_ = os.Remove(targetPath)
			return provider.ForkSessionResult{}, err
		}
	}
	if err := scanner.Err(); err != nil {
		_ = target.Close()
		_ = os.Remove(targetPath)
		return provider.ForkSessionResult{}, err
	}
	if err := writer.Flush(); err != nil {
		_ = target.Close()
		_ = os.Remove(targetPath)
		return provider.ForkSessionResult{}, err
	}
	if err := target.Close(); err != nil {
		_ = os.Remove(targetPath)
		return provider.ForkSessionResult{}, err
	}
	title, cwd := transcriptSummary(targetPath)
	return provider.ForkSessionResult{Summary: provider.SessionSummary{
		SessionID: forkID,
		Title:     title,
		Cwd:       cwd,
		UpdatedAt: time.Now().UTC().Format(time.RFC3339Nano),
	}}, nil
}
