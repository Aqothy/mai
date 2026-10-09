package claudecode

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// REPLAY_PLACEHOLDER

// transcriptTailBytes is how much of a transcript's end is read for its
// title, which the CLI appends as the session goes on.
const transcriptTailBytes = 256 << 10

// transcriptSummary extracts a session's title and cwd cheaply, as the SDK's
// listSessions does: the cwd and first prompt live in the head of the file,
// the title in its tail. A session without a title is titled by its first
// prompt.
func transcriptSummary(path string) (title, cwd string) {
	file, err := os.Open(path)
	if err != nil {
		return "", ""
	}
	defer file.Close()
	firstPrompt := ""
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 1<<20), maxMessageBytes)
	for count := 0; scanner.Scan() && count < 400 && (cwd == "" || firstPrompt == ""); count++ {
		var line transcriptLine
		if json.Unmarshal(scanner.Bytes(), &line) != nil {
			continue
		}
		cwd = firstNonEmpty(cwd, line.Cwd)
		if firstPrompt == "" {
			firstPrompt = provider.PromptPreviewTitle(promptText(line))
		}
	}
	return firstNonEmpty(transcriptTitle(file), firstPrompt), cwd
}

// transcriptTitle is the session's title: the latest one the user chose
// (/rename, or a rename in maiD), else the latest the CLI generated.
func transcriptTitle(file *os.File) string {
	info, err := file.Stat()
	if err != nil {
		return ""
	}
	if _, err := file.Seek(max(info.Size()-transcriptTailBytes, 0), io.SeekStart); err != nil {
		return ""
	}
	customTitle, aiTitle := "", ""
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 1<<20), maxMessageBytes)
	for scanner.Scan() {
		var line transcriptLine
		// The first line of a mid-file tail is partial and fails to decode.
		if json.Unmarshal(scanner.Bytes(), &line) == nil {
			customTitle = firstNonEmpty(line.CustomTitle, customTitle)
			aiTitle = firstNonEmpty(line.AITitle, aiTitle)
		}
	}
	return firstNonEmpty(customTitle, aiTitle)
}

// promptText is the prompt a user line shows as, or "" when it is not one.
func promptText(line transcriptLine) string {
	if line.Type != "user" || line.IsSidechain {
		return ""
	}
	var api userAPIMessage
	if json.Unmarshal(line.Message, &api) != nil {
		return ""
	}
	blocks, text := api.blocks()
	for _, block := range blocks {
		if block.Type == "tool_result" {
			return ""
		}
	}
	prompt := classifyUserLine(line, blocks, text)
	if prompt.kind != userLinePrompt {
		return ""
	}
	return prompt.text
}

// promptContent is the text and images of a user prompt, given as content
// blocks or as plain text.
func promptContent(blocks []contentBlock, text string) (string, []provider.Attachment) {
	var attachments []provider.Attachment
	for _, block := range blocks {
		switch block.Type {
		case "text":
			if text != "" {
				text += "\n"
			}
			text += block.Text
		case "image":
			if block.Source != nil {
				attachments = append(attachments, provider.Attachment{Kind: provider.AttachmentImage, MimeType: block.Source.MediaType, Data: block.Source.Data})
			}
		}
	}
	return text, attachments
}

// steeredPrompt returns the prompt of a queued_command attachment the user
// sent, as opposed to commands the CLI queues itself (task notifications).
func steeredPrompt(item *transcriptItem) (string, []provider.Attachment, bool) {
	if item == nil || item.Type != "queued_command" || item.CommandMode != "prompt" || !item.Origin.fromUser() {
		return "", nil, false
	}
	text, attachments := promptContent(userAPIMessage{Content: item.Prompt}.blocks())
	if strings.TrimSpace(text) == "" && len(attachments) == 0 {
		return "", nil, false
	}
	return text, attachments, true
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
	if err := os.Remove(path); err != nil {
		return err
	}
	// Subagent transcripts live in a sibling <session id>/ directory.
	return os.RemoveAll(filepath.Join(filepath.Dir(path), sessionID))
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

// ForkSession copies the session into a new one, as the SDK's forkSession
// does: sidechain and progress lines are dropped, every message gets a new
// uuid with the parent chain kept, each records what it was forked from, and
// the fork is titled after its source.
func (h *Instance) ForkSession(_ context.Context, input provider.ForkSessionInput) (provider.ForkSessionResult, error) {
	if input.ProviderSessionID == "" {
		return provider.ForkSessionResult{}, fmt.Errorf("Claude Code fork requires a provider session id")
	}
	sourcePath, err := h.findTranscript(input.ProviderSessionID)
	if err != nil {
		return provider.ForkSessionResult{}, err
	}
	title, _ := transcriptSummary(sourcePath)
	data, err := os.ReadFile(sourcePath)
	if err != nil {
		return provider.ForkSessionResult{}, err
	}
	forkID, lines, err := forkLines(data, input.ProviderSessionID, firstNonEmpty(title, "Forked session")+" (fork)")
	if err != nil {
		return provider.ForkSessionResult{}, err
	}
	targetPath := filepath.Join(filepath.Dir(sourcePath), forkID+".jsonl")
	if err := writeNewFile(targetPath, append(bytes.Join(lines, []byte("\n")), '\n')); err != nil {
		return provider.ForkSessionResult{}, err
	}
	forkTitle, cwd := transcriptSummary(targetPath)
	return provider.ForkSessionResult{Summary: provider.SessionSummary{
		SessionID: forkID,
		Title:     forkTitle,
		Cwd:       cwd,
		UpdatedAt: time.Now().UTC().Format(time.RFC3339Nano),
	}}, nil
}

// forkLines is the SDK's _build_fork_lines: the fork's transcript lines for
// a source transcript, and the fork's session id. Values are kept as raw JSON
// so message content is copied byte for byte.
func forkLines(data []byte, sourceID, title string) (string, [][]byte, error) {
	type entry = map[string]json.RawMessage
	var transcript []entry
	var replacements []json.RawMessage
	for _, raw := range bytes.Split(data, []byte("\n")) {
		var line entry
		var head struct {
			Type         string            `json:"type"`
			UUID         string            `json:"uuid"`
			SessionID    string            `json:"sessionId"`
			IsSidechain  bool              `json:"isSidechain"`
			Replacements []json.RawMessage `json:"replacements"`
		}
		if json.Unmarshal(raw, &line) != nil || json.Unmarshal(raw, &head) != nil {
			continue
		}
		switch head.Type {
		case "user", "assistant", "attachment", "system", "progress":
			// Sidechains are subagent sessions with their own chains.
			if head.UUID != "" && !head.IsSidechain {
				transcript = append(transcript, line)
			}
		case "content-replacement":
			if head.SessionID == sourceID {
				replacements = append(replacements, head.Replacements...)
			}
		}
	}
	stringOf := func(line entry, key string) string {
		var value string
		_ = json.Unmarshal(line[key], &value)
		return value
	}
	newUUIDs := make(map[string]string, len(transcript))
	byUUID := make(map[string]entry, len(transcript))
	var writable []entry
	for _, line := range transcript {
		id := stringOf(line, "uuid")
		newUUIDs[id], byUUID[id] = newSessionUUID(), line
		// Progress lines are UI-only links of the chain; the fork skips them.
		if stringOf(line, "type") != "progress" {
			writable = append(writable, line)
		}
	}
	if len(writable) == 0 {
		return "", nil, fmt.Errorf("Claude Code session %q has no messages to fork", sourceID)
	}
	forkID := newSessionUUID()
	now := time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
	marshal := func(value any) json.RawMessage {
		encoded, _ := json.Marshal(value)
		return encoded
	}
	var lines [][]byte
	for index, original := range writable {
		id := stringOf(original, "uuid")
		var parent any
		for parentID := stringOf(original, "parentUuid"); parentID != ""; {
			ancestor, ok := byUUID[parentID]
			if !ok {
				break
			}
			if stringOf(ancestor, "type") != "progress" {
				parent = newUUIDs[parentID]
				break
			}
			parentID = stringOf(ancestor, "parentUuid")
		}
		forked := make(entry, len(original)+2)
		for key, value := range original {
			forked[key] = value
		}
		for _, key := range []string{"teamName", "agentName", "slug", "sourceToolAssistantUUID"} {
			delete(forked, key)
		}
		forked["uuid"] = marshal(newUUIDs[id])
		forked["parentUuid"] = marshal(parent)
		if logical := stringOf(original, "logicalParentUuid"); logical != "" {
			forked["logicalParentUuid"] = marshal(newUUIDs[logical])
		}
		forked["sessionId"] = marshal(forkID)
		forked["isSidechain"] = marshal(false)
		forked["forkedFrom"] = marshal(map[string]string{"sessionId": sourceID, "messageUuid": id})
		// The newest timestamp marks the leaf on resume.
		if index == len(writable)-1 || len(original["timestamp"]) == 0 {
			forked["timestamp"] = marshal(now)
		}
		lines = append(lines, marshal(forked))
	}
	if len(replacements) > 0 {
		lines = append(lines, marshal(map[string]any{"type": "content-replacement", "sessionId": forkID, "replacements": replacements, "uuid": newSessionUUID(), "timestamp": now}))
	}
	lines = append(lines, marshal(map[string]any{"type": "custom-title", "sessionId": forkID, "customTitle": title, "uuid": newSessionUUID(), "timestamp": now}))
	return forkID, lines, nil
}

// writeNewFile writes a file that must not exist yet.
func writeNewFile(path string, data []byte) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err := file.Write(data); err != nil {
		_ = file.Close()
		_ = os.Remove(path)
		return err
	}
	if err := file.Close(); err != nil {
		_ = os.Remove(path)
		return err
	}
	return nil
}

// RenameSession names the session as /rename does, with the custom-title
// line the SDK's renameSession appends to the transcript. A live CLI is told
// too, so its own title agrees. A session with no transcript yet has no
// messages to name; its next prompt starts one.
func (h *Instance) RenameSession(ctx context.Context, input provider.RenameSessionInput) error {
	h.mu.Lock()
	var proc *sessionProcess
	if session := h.sessionsByLocal[h.localByNative[input.ProviderSessionID]]; session != nil {
		proc = session.proc
	}
	h.mu.Unlock()
	if proc != nil {
		_ = proc.client.control(ctx, map[string]any{"subtype": "rename_session", "title": input.Title, "source": "host", "session_id": input.ProviderSessionID}, nil)
	}
	path, err := h.findTranscript(input.ProviderSessionID)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	line, err := json.Marshal(map[string]string{"type": "custom-title", "customTitle": input.Title, "sessionId": input.ProviderSessionID})
	if err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	if _, err := file.Write(append(line, '\n')); err != nil {
		_ = file.Close()
		return err
	}
	return file.Close()
}
