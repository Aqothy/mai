package codexapp

import (
	"context"
	"encoding/json"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/provider/providertest"
)

func TestUserInputsFromTurnConvertsSkillsAndMedia(t *testing.T) {
	input := provider.SendInput{
		Text: "Use $review, but not $reviewer or $disabled.",
		Attachments: []provider.Attachment{
			{Kind: "image", MimeType: "image/png", Data: "aW1hZ2U="},
			{Kind: "image", URI: "file:///tmp/a%20b.png"},
			{Kind: "audio", URI: "/tmp/clip.mp3"},
		},
	}
	skills := []provider.Skill{
		{Name: "review", Path: "/skills/review/SKILL.md", Enabled: true},
		{Name: "disabled", Path: "/skills/disabled/SKILL.md", Enabled: false},
	}

	converted, err := userInputs(input, skills)
	if err != nil {
		t.Fatal(err)
	}
	if len(converted) != 5 {
		t.Fatalf("converted input count = %d, want 5: %#v", len(converted), converted)
	}
	if converted[0].Type != "text" || converted[0].Text != input.Text || converted[0].TextElements == nil {
		t.Fatalf("text input = %#v", converted[0])
	}
	if converted[1].Type != "skill" || converted[1].Name != "review" || converted[1].Path != "/skills/review/SKILL.md" {
		t.Fatalf("skill input = %#v", converted[1])
	}
	if converted[2].Type != "image" || converted[2].URL != "data:image/png;base64,aW1hZ2U=" {
		t.Fatalf("inline image = %#v", converted[2])
	}
	if converted[3].Type != "localImage" || converted[3].Path != "/tmp/a b.png" {
		t.Fatalf("local image = %#v", converted[3])
	}
	if converted[4].Type != "localAudio" || converted[4].Path != "/tmp/clip.mp3" {
		t.Fatalf("audio = %#v", converted[4])
	}

	encoded, err := json.Marshal(converted[0])
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encoded), `"text_elements":[]`) {
		t.Fatalf("text input JSON = %s, want protocol text_elements array", encoded)
	}
	imageJSON, err := json.Marshal(converted[2])
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(imageJSON), "text_elements") || string(imageJSON) != `{"type":"image","url":"data:image/png;base64,aW1hZ2U="}` {
		t.Fatalf("image input JSON = %s", imageJSON)
	}
}

func TestUserInputsRejectUnsupportedRemoteAndEmbeddedAttachments(t *testing.T) {
	for _, attachment := range []provider.Attachment{
		{Kind: "image", URI: "https://example.test/image.png"},
		{Kind: "audio", URI: "https://example.test/audio.mp3"},
		{Kind: "resource", URI: "file:///tmp/context.txt", Data: "context"},
	} {
		if _, err := userInputs(provider.SendInput{Attachments: []provider.Attachment{attachment}}, nil); err == nil {
			t.Fatalf("attachment %#v unexpectedly accepted", attachment)
		}
	}
}

func TestSetConfigOptionValidatesCatalogAndNormalizesEffortForModel(t *testing.T) {
	models := []appModel{
		{Model: "model-a", SupportedReasoningEfforts: []appReasoningEffortOption{{ReasoningEffort: "medium"}, {ReasoningEffort: "high"}}, DefaultReasoningEffort: "medium", IsDefault: true},
		{Model: "model-b", SupportedReasoningEfforts: []appReasoningEffortOption{{ReasoningEffort: "low"}}, DefaultReasoningEffort: "low"},
	}
	h := &Instance{models: models, sessions: map[string]*sessionState{}}
	session := h.sessionLocked("native-thread")
	session.loaded = true
	session.model = "model-a"
	session.effort = "high"

	if err := h.Configure(context.Background(), "native-thread", provider.ConfigOptionSelection{OptionID: "model", Value: "model-b"}); err != nil {
		t.Fatalf("set model: %v", err)
	}
	if session.model != "model-b" || session.effort != "low" {
		t.Fatalf("normalized model/effort = %q/%q", session.model, session.effort)
	}
	if err := h.Configure(context.Background(), "native-thread", provider.ConfigOptionSelection{OptionID: "reasoning_effort", Value: "xhigh"}); err == nil {
		t.Fatal("unsupported effort was accepted")
	}
	if session.effort != "low" {
		t.Fatalf("rejected effort mutated session to %q", session.effort)
	}
	if err := h.Configure(context.Background(), "native-thread", provider.ConfigOptionSelection{OptionID: "model", Value: "missing"}); err == nil {
		t.Fatal("unsupported model was accepted")
	}
}

func TestProtocolDecodingToleratesUnknownFieldsAndItems(t *testing.T) {
	var thread appThread
	err := json.Unmarshal([]byte(`{
		"id":"thread-1","cwd":"/repo","createdAt":123,"updatedAt":456,
		"futureThreadField":{"enabled":true},
		"turns":[{"id":"turn-1","status":"completed","items":[
			{"type":"reasoning","id":"reason-1","summary":["Summary"],"content":["Detail"],"futureItemField":42},
			{"type":"futureTool","id":"future-1","futurePayload":{"value":1}}
		]}]
	}`), &thread)
	if err != nil {
		t.Fatal(err)
	}
	reasoning := thread.Turns[0].Items[0]
	if len(reasoning.ReasoningContent) != 1 || reasoning.ReasoningContent[0] != "Detail" {
		t.Fatalf("reasoning content = %#v", reasoning.ReasoningContent)
	}
	unknown := thread.Turns[0].Items[1]
	entry := completedEntry(t, unknown)
	if entry.Kind != provider.ItemKindToolCall || entry.Tool == nil || entry.Tool.ProviderKind != "futureTool" {
		t.Fatalf("unknown item fallback = %#v", entry)
	}
}

// completedEntry is the entry a completed item shows as.
func completedEntry(t *testing.T, item appItem) provider.Entry {
	t.Helper()
	entries := itemEntries("turn", item, completedStatus(item), time.Unix(1, 0))
	if len(entries) != 1 {
		t.Fatalf("item %#v made entries %#v, want one", item, entries)
	}
	return entries[0]
}

func TestItemEntriesNormalizeTools(t *testing.T) {
	exitCode := 0
	duration := int64(250)
	path := "/repo/README.md"
	query := "needle"
	command := appItem{
		Type: "commandExecution", ID: "cmd-1", Status: "completed",
		Command: "rg needle", Cwd: "/repo", AggregatedOutput: ptr("match"), ExitCode: &exitCode, DurationMS: &duration,
		CommandActions: []appCommandAction{{Type: "search", Path: &path, Query: &query}},
	}
	entry := completedEntry(t, command)
	call := entry.Tool
	if entry.Kind != provider.ItemKindCommandExecution || entry.Status != provider.ItemStatusCompleted || call == nil {
		t.Fatalf("command entry = %#v", entry)
	}
	if call.Action != provider.ToolActionSearch || call.Command != "rg needle" || call.Query != "needle" || call.Cwd != "/repo" || call.Output != "match" || call.ExitCode == nil || *call.ExitCode != 0 {
		t.Fatalf("command tool = %#v", call)
	}

	movePath := "/repo/new.swift"
	fileItem := appItem{Type: "fileChange", ID: "patch-1", Status: "completed", Changes: []appFileUpdateChange{{
		Path: "/repo/old.swift", Diff: "diff", Kind: appPatchChangeKind{Type: "update", MovePath: &movePath},
	}}}
	fileEntry := completedEntry(t, fileItem)
	if fileEntry.Tool == nil {
		t.Fatalf("file entry = %#v", fileEntry)
	}
	changes := fileEntry.Tool.Changes
	if len(changes) != 1 || changes[0].Kind != provider.FileChangeMove || changes[0].MovePath != movePath {
		t.Fatalf("file changes = %#v", changes)
	}
}

// Only Codex's own parsed commandActions state an action: all read/listFiles
// is read, all search is search, and anything mixed, unknown, or unparsed,
// like every non-command item, leaves it empty.
func TestItemEntriesStatedActions(t *testing.T) {
	commands := func(types ...string) appItem {
		item := appItem{Type: "commandExecution", ID: "cmd", Command: "cmd"}
		for _, actionType := range types {
			item.CommandActions = append(item.CommandActions, appCommandAction{Type: actionType})
		}
		return item
	}
	for _, tc := range []struct {
		name string
		item appItem
		want provider.ToolAction
	}{
		{"read", commands("read"), provider.ToolActionRead},
		{"read and list", commands("read", "listFiles"), provider.ToolActionRead},
		{"search", commands("search", "search"), provider.ToolActionSearch},
		{"read and search", commands("read", "search"), ""},
		{"read and unknown", commands("read", "unknown"), ""},
		{"unparsed", commands(), ""},
		{"mcp", appItem{Type: "mcpToolCall", ID: "mcp", Server: "github", Tool: "search_issues"}, ""},
	} {
		if entry := completedEntry(t, tc.item); entry.Tool == nil || entry.Tool.Action != tc.want {
			t.Errorf("%s: tool call = %#v, want action %q", tc.name, entry.Tool, tc.want)
		}
	}
}

func TestItemEntriesNormalizeMCPResult(t *testing.T) {
	result := json.RawMessage(`{"content":[{"type":"text","text":"done"},{"type":"image","data":"aW1n","mimeType":"image/png"},{"type":"resource_link","uri":"https://example.test/spec","name":"spec","title":"Protocol","description":"Reference","mimeType":"text/html","size":42,"annotations":{"audience":["assistant"],"priority":0.8,"lastModified":"2026-08-20T00:00:00Z","_meta":{"hint":"read"}},"_meta":{"source":"mcp"}}],"structuredContent":null}`)
	item := appItem{
		Type: "mcpToolCall", ID: "mcp-1", Status: "completed", Server: "docs", Tool: "lookup", Result: result,
	}
	call := completedEntry(t, item).Tool
	if call == nil {
		t.Fatal("MCP entry has no tool call")
	}
	if call.Namespace != "docs" || call.Name != "lookup" || call.Output != "done" {
		t.Fatalf("MCP call = %#v", call)
	}
	if len(call.Attachments) != 2 || call.Attachments[0].Kind != "image" || call.Attachments[0].Data != "aW1n" {
		t.Fatalf("MCP attachments = %#v", call.Attachments)
	}
	resource := call.Attachments[1]
	if resource.Title != "Protocol" || resource.Description != "Reference" || resource.Size != 42 || resource.Metadata["source"] != "mcp" || resource.Annotations == nil || resource.Annotations.Priority == nil || *resource.Annotations.Priority != 0.8 || resource.Annotations.Metadata["hint"] != "read" {
		t.Fatalf("MCP resource metadata = %#v", resource)
	}
}

func TestImageGenerationUsesInlineBase64Attachment(t *testing.T) {
	item := appItem{Type: "imageGeneration", ID: "image-1", Status: "completed", Result: json.RawMessage(`"aW1hZ2U="`)}
	entry := completedEntry(t, item)
	if entry.Tool == nil || len(entry.Tool.Attachments) != 1 {
		t.Fatalf("image generation entry = %#v", entry)
	}
	attachment := entry.Tool.Attachments[0]
	if attachment.Kind != "image" || attachment.Data != "aW1hZ2U=" || attachment.MimeType != "image/png" || attachment.URI != "" {
		t.Fatalf("generated image attachment = %#v", attachment)
	}
}

func TestHistoryTurnsKeepTurnAndItemOrder(t *testing.T) {
	started := float64(100)
	completed := float64(101)
	output := "ok"
	thread := appThread{ID: "native-thread", CreatedAt: 90, UpdatedAt: 101, Turns: []appTurn{{
		ID: "native-turn", Status: "completed", StartedAt: &started, CompletedAt: &completed,
		Items: []appItem{
			// The client identity comes from clientId, never from parsing prompt text.
			{Type: "userMessage", ID: "user", ClientID: ptr("maid:dispatch"), Content: []appUserInput{{Type: "text", Text: "hello"}}},
			{Type: "agentMessage", ID: "agent", Text: "answer"},
			{Type: "commandExecution", ID: "command", Status: "completed", Command: "pwd", AggregatedOutput: &output},
			{Type: "reasoning", ID: "reason", Summary: []string{"thinking"}},
		},
	}}}

	turns, _ := historyTurns(thread.Turns, time.Unix(90, 0))
	if len(turns) != 1 || turns[0].Ref != "native-turn" || turns[0].State != provider.TurnCompleted || !turns[0].StartedAt.Equal(time.Unix(100, 0)) {
		t.Fatalf("turns = %#v", turns)
	}
	var got []string
	for _, entry := range turns[0].Entries {
		got = append(got, entry.Ref+" "+string(entry.Kind)+" "+entry.Text)
	}
	if want := []string{"user user_message hello", "agent assistant_message answer", "command command_execution ", "reason reasoning thinking"}; !slices.Equal(got, want) {
		t.Fatalf("entries = %q, want %q", got, want)
	}
	if turns[0].Entries[0].Delivery != "maid:dispatch" {
		t.Fatalf("user entry = %#v, want the delivery its clientId names", turns[0].Entries[0])
	}
}

func TestConfigOptionsFromModelsUsesSelectedCatalogCapabilities(t *testing.T) {
	models := []appModel{
		{Model: "hidden", DisplayName: "Hidden", Hidden: true},
		{Model: "gpt-default", DisplayName: "GPT Default", IsDefault: true, DefaultReasoningEffort: "medium", SupportedReasoningEfforts: []appReasoningEffortOption{{ReasoningEffort: "low"}, {ReasoningEffort: "medium"}}, ServiceTiers: []appModelServiceTier{{ID: "priority", Name: "Fast", Description: "Faster responses"}}},
		{Model: "gpt-selected", DisplayName: "GPT Selected", Description: "Best for difficult work", DefaultReasoningEffort: "high", SupportedReasoningEfforts: []appReasoningEffortOption{{ReasoningEffort: "high"}, {ReasoningEffort: "xhigh", Description: "Most deliberate"}}, ServiceTiers: []appModelServiceTier{{ID: "priority", Name: "Fast", Description: "Fastest queue"}}},
	}
	options := configOptionsFromModels(models, "gpt-selected", "xhigh", "priority")
	if len(options) != 3 {
		t.Fatalf("options = %#v", options)
	}
	if options[0].ID != "model" || options[0].CurrentValue != "gpt-selected" || len(options[0].Choices) != 2 {
		t.Fatalf("model option = %#v", options[0])
	}
	if options[0].Choices[1].Description != "Best for difficult work" {
		t.Fatalf("model choice metadata = %#v", options[0].Choices[1])
	}
	if options[1].ID != "service_tier" || options[1].Category != provider.ConfigOptionCategoryModelConfig || options[1].CurrentValue != "priority" || len(options[1].Choices) != 2 || options[1].Choices[0].Value != defaultServiceTier || options[1].Choices[1].Description != "Fastest queue" {
		t.Fatalf("service tier option = %#v", options[1])
	}
	if options[2].ID != "reasoning_effort" || options[2].Category != provider.ConfigOptionCategoryThoughtLevel || options[2].CurrentValue != "xhigh" || len(options[2].Choices) != 2 {
		t.Fatalf("effort option = %#v", options[2])
	}
	// Unnamed choices carry no label, so clients display the raw value.
	if options[1].Choices[1].Label != "Fast" || options[2].Choices[1].Label != "" || options[2].Choices[1].Description != "Most deliberate" {
		t.Fatalf("effort choice metadata = %#v", options[2].Choices[1])
	}

	fallback := configOptionsFromModels(models, "missing", "invalid", "invalid")
	if fallback[0].CurrentValue != "gpt-default" || fallback[1].CurrentValue != defaultServiceTier || fallback[2].CurrentValue != "medium" {
		t.Fatalf("fallback options = %#v", fallback)
	}
}

func TestSkillsFromResponseFallsBackToInterfaceDescriptionAndDeduplicates(t *testing.T) {
	response := skillsListResponse{Data: []appSkillsListEntry{
		{Skills: []appSkill{{Name: "review", Description: "Review changes", Interface: &appSkillInterface{ShortDescription: "Short"}, Path: "/skills/review", Scope: "user", Enabled: true}}},
		{Skills: []appSkill{{Name: "review", Description: "Duplicate", Path: "/skills/review", Scope: "user", Enabled: true}, {Name: "test", ShortDescription: "Run tests", Path: "/skills/test", Scope: "repo", Enabled: false}}},
	}}
	skills := skillsFromResponse(response)
	if len(skills) != 2 {
		t.Fatalf("skills = %#v", skills)
	}
	if skills[0].ShortDescription != "Short" || !skills[0].Enabled || skills[1].Name != "test" || skills[1].Enabled {
		t.Fatalf("skills = %#v", skills)
	}
}

func TestTurnStateAndTimestampsAreUnknownTolerant(t *testing.T) {
	if state, terminal := turnState("cancelled"); !terminal || state != provider.TurnInterrupted {
		t.Fatalf("cancelled state = %q, %v", state, terminal)
	}
	if state, terminal := turnState("futureStatus"); terminal || state != "" {
		t.Fatalf("future state = %q, %v", state, terminal)
	}
	fallback := time.Unix(9, 0)
	if got := timeFromUnixSeconds(nil, fallback); !got.Equal(fallback) {
		t.Fatalf("nil seconds = %s", got)
	}
}

func ptr(value string) *string { return &value }

func TestCommandOutputBeforeItemStartIsDropped(t *testing.T) {
	events := providertest.NewRecorder()
	h := &Instance{host: provider.Host{Emit: events.Emit}, sessions: map[string]*sessionState{}}
	h.commandOutput(json.RawMessage(`{"threadId":"native-thread","turnId":"native-turn","itemId":"cmd-1","delta":"early"}`))
	if got := events.Snapshot(); len(got) != 0 {
		t.Fatalf("output for an unknown item was emitted: %#v", got)
	}
	h.item(false, "native-thread", "native-turn", appItem{Type: "commandExecution", ID: "cmd-1", Status: "inProgress", Command: "pwd"}, 0, 0)
	h.commandOutput(json.RawMessage(`{"threadId":"native-thread","turnId":"native-turn","itemId":"cmd-1","delta":"/tmp"}`))
	got := events.Snapshot()
	last, ok := got[len(got)-1].Body.(provider.EntryUpserted)
	if !ok || last.Entry.Tool == nil || last.Entry.Tool.Output != "/tmp" || last.Entry.Tool.Name == "" {
		t.Fatalf("output update after item start = %#v, want merged into the started entry", got[len(got)-1])
	}
}

// Clients only parse unified diffs: added and deleted files become whole-file
// hunks, and a move's diff loses the "Moved to" line Codex appends.
func TestProviderFileChangesAreUnifiedDiffs(t *testing.T) {
	moved := "/repo/new.go"
	changes := providerFileChanges([]appFileUpdateChange{
		{Path: "/repo/a.md", Kind: appPatchChangeKind{Type: "add"}, Diff: "# Title\n\n- item\n"},
		{Path: "/repo/b.txt", Kind: appPatchChangeKind{Type: "delete"}, Diff: "gone\n"},
		{Path: "/repo/old.go", Kind: appPatchChangeKind{Type: "update", MovePath: &moved}, Diff: "@@ -1 +1 @@\n-a\n+b\n\n\nMoved to: /repo/new.go"},
	})
	want := []provider.FileChange{
		{Path: "/repo/a.md", Kind: provider.FileChangeAdd, Diff: "@@ -0,0 +1,3 @@\n+# Title\n+\n+- item\n"},
		{Path: "/repo/b.txt", Kind: provider.FileChangeDelete, Diff: "@@ -1,1 +0,0 @@\n-gone\n"},
		{Path: "/repo/old.go", Kind: provider.FileChangeMove, MovePath: moved, Diff: "@@ -1 +1 @@\n-a\n+b\n"},
	}
	if !slices.Equal(changes, want) {
		t.Fatalf("changes = %#v", changes)
	}
}
