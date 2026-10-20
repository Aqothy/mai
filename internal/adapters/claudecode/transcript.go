package claudecode

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Session transcripts live in <configDir>/projects/<sanitized cwd>/<id>.jsonl.
// These helpers follow the Agent SDK's session functions (sessions.py), which
// read the same files the CLI writes.

var sessionIDPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// maxSanitizedLength is where the CLI truncates a project directory name and
// appends a hash of the full path.
const maxSanitizedLength = 200

// sanitizePath mirrors the CLI's project directory name for a path: every
// non-alphanumeric character becomes '-'. Longer names are truncated and get
// a hash suffix that only the CLI computes (Bun.hash), so they are found by
// prefix (see projectDir).
func sanitizePath(path string) string {
	var builder strings.Builder
	for _, r := range path {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			builder.WriteRune(r)
		} else {
			// One '-' per UTF-16 code unit, as the CLI's regexp replaces.
			builder.WriteByte('-')
			if r > 0xFFFF {
				builder.WriteByte('-')
			}
		}
	}
	return builder.String()
}

// projectDir returns the existing project directory for cwd, or "". The CLI
// names it after the real path of its working directory, so symlinks in cwd
// (such as /tmp on macOS) are resolved first.
func (h *Instance) projectDir(cwd string) string {
	configDir := h.configDir()
	if configDir == "" || cwd == "" {
		return ""
	}
	if resolved, err := filepath.EvalSymlinks(cwd); err == nil {
		cwd = resolved
	}
	projects := filepath.Join(configDir, "projects")
	name := sanitizePath(cwd)
	if len(name) <= maxSanitizedLength {
		dir := filepath.Join(projects, name)
		if info, err := os.Stat(dir); err == nil && info.IsDir() {
			return dir
		}
		return ""
	}
	entries, err := os.ReadDir(projects)
	if err != nil {
		return ""
	}
	prefix := name[:maxSanitizedLength] + "-"
	for _, entry := range entries {
		if entry.IsDir() && strings.HasPrefix(entry.Name(), prefix) {
			return filepath.Join(projects, entry.Name())
		}
	}
	return ""
}

// findTranscript locates a session's transcript. Session ids are UUIDs, so
// searching every project directory finds it whatever cwd it was started in.
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
	return "", fmt.Errorf("Claude Code session %q has no transcript: %w", sessionID, os.ErrNotExist)
}

func (h *Instance) hasTranscript(sessionID string) bool {
	_, err := h.findTranscript(sessionID)
	return err == nil
}

func (h *Instance) readTranscript(sessionID string) ([]transcriptLine, error) {
	path, err := h.findTranscript(sessionID)
	if err != nil {
		return nil, err
	}
	return readTranscriptFile(path)
}

func readTranscriptFile(path string) ([]transcriptLine, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return parseTranscript(data), nil
}

// parseTranscript reads a transcript's lines, skipping any that aren't JSON
// (the CLI may be writing the last one).
func parseTranscript(data []byte) []transcriptLine {
	var lines []transcriptLine
	for _, raw := range bytes.Split(data, []byte("\n")) {
		var line transcriptLine
		if len(raw) == 0 || json.Unmarshal(raw, &line) != nil {
			continue
		}
		lines = append(lines, line)
	}
	return lines
}

// chained reports whether a line takes part in the uuid/parentUuid chain.
func (line transcriptLine) chained() bool {
	switch line.Type {
	case "user", "assistant", "system", "attachment", "progress":
		return line.UUID != ""
	default:
		return false
	}
}

// conversation returns the indexes of the chained lines on the session's
// current conversation, in file order. A transcript is a tree: rewinding to
// an earlier message (or editing it) starts a new branch and leaves the old
// one in the file. Like the SDK's get_session_messages, the conversation is
// the parentUuid chain from the newest main-chain leaf. Unlike it, the walk
// continues across compactions, so the whole history shows, and parallel tool calls the CLI writes as sibling
// lines are kept: the other content blocks of an assistant message on the
// chain, the results of their tool calls, and the commands queued off them.
func conversation(lines []transcriptLine) map[int]bool {
	byUUID := make(map[string]int)
	hasChild := make(map[string]bool)
	for index, line := range lines {
		if !line.chained() {
			continue
		}
		byUUID[line.UUID] = index
		if line.ParentUUID != "" {
			hasChild[line.ParentUUID] = true
		}
	}
	mainMessage := func(line transcriptLine) bool {
		return (line.Type == "user" || line.Type == "assistant") && !line.IsSidechain && !line.IsMeta && line.TeamName == ""
	}
	parentOf := func(index int) (int, bool) {
		line := lines[index]
		if parent, ok := byUUID[line.ParentUUID]; ok {
			return parent, true
		}
		if line.Type != "system" || line.Subtype != "compact_boundary" {
			return 0, false
		}
		// A compact boundary starts a new chain. The compacted conversation
		// ends at the newest main-chain message written before it (its
		// logicalParentUuid can name a message the CLI kept and rewrote
		// after the boundary instead).
		for previous := index - 1; previous >= 0; previous-- {
			if lines[previous].chained() && mainMessage(lines[previous]) {
				return previous, true
			}
		}
		return 0, false
	}

	// The leaf is the newest main-chain message among the chain ends.
	leaf, fallback := -1, -1
	for index, line := range lines {
		if !line.chained() || hasChild[line.UUID] {
			continue
		}
		current, seen := index, make(map[int]bool)
		for !seen[current] {
			seen[current] = true
			if candidate := lines[current]; candidate.Type == "user" || candidate.Type == "assistant" {
				if mainMessage(candidate) {
					leaf = max(leaf, current)
				} else {
					fallback = max(fallback, current)
				}
				break
			}
			parent, ok := parentOf(current)
			if !ok {
				break
			}
			current = parent
		}
	}
	if leaf < 0 {
		leaf = fallback
	}
	included := make(map[int]bool)
	for current := leaf; current >= 0 && !included[current]; {
		included[current] = true
		parent, ok := parentOf(current)
		if !ok {
			break
		}
		current = parent
	}

	messageIDs := make(map[string]bool)
	toolUseIDs := make(map[string]bool)
	for index := range included {
		if lines[index].Type == "assistant" {
			blocks := lines[index].assistantBlocks()
			messageIDs[blocks.id] = blocks.id != ""
			for _, id := range blocks.toolUseIDs {
				toolUseIDs[id] = true
			}
		}
	}
	// File order is creation order, so one pass sees parents before children.
	for index, line := range lines {
		if included[index] || !line.chained() || line.IsSidechain {
			continue
		}
		switch line.Type {
		case "assistant":
			blocks := line.assistantBlocks()
			if !messageIDs[blocks.id] {
				continue
			}
			for _, id := range blocks.toolUseIDs {
				toolUseIDs[id] = true
			}
		case "user":
			if !answersAny(line, toolUseIDs) {
				continue
			}
		case "attachment":
			if parent, ok := byUUID[line.ParentUUID]; !ok || !included[parent] {
				continue
			}
		default:
			continue
		}
		included[index] = true
	}
	return included
}

type assistantBlocks struct {
	id         string
	toolUseIDs []string
}

func (line transcriptLine) assistantBlocks() assistantBlocks {
	var api apiMessage
	if json.Unmarshal(line.Message, &api) != nil {
		return assistantBlocks{}
	}
	result := assistantBlocks{id: api.ID}
	for _, block := range api.Content {
		if block.ID != "" && strings.HasSuffix(block.Type, "tool_use") {
			result.toolUseIDs = append(result.toolUseIDs, block.ID)
		}
	}
	return result
}

// answersAny reports whether a user line carries a result for one of the
// tool calls.
func answersAny(line transcriptLine, toolUseIDs map[string]bool) bool {
	var api userAPIMessage
	if json.Unmarshal(line.Message, &api) != nil {
		return false
	}
	blocks, _ := api.blocks()
	for _, block := range blocks {
		if block.Type == "tool_result" && toolUseIDs[block.ToolUseID] {
			return true
		}
	}
	return false
}
