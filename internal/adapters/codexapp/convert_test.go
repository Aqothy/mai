package codexapp

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

func TestReplayPreservesClientIdentityWithoutParsingPromptText(t *testing.T) {
	var item appItem
	if err := json.Unmarshal([]byte(`{"type":"userMessage","id":"native-item","clientId":"maid:dispatch","content":[{"type":"text","text":"quoted context"}]}`), &item); err != nil {
		t.Fatal(err)
	}
	events := replayEvents("local", appThread{Turns: []appTurn{{ID: "turn", Status: "completed", Items: []appItem{item}}}})
	if len(events) != 3 || events[1].Payload.ClientMessageID != "maid:dispatch" || events[1].Payload.Detail != "quoted context" {
		t.Fatalf("replay identity: %#v", events)
	}
	item.ClientID = nil
	event, ok := runtimeEventFromItem("local", "turn", item, provider.RuntimeEventItemCompleted, time.Now())
	if !ok || event.Payload.ClientMessageID != "" || event.Payload.Presentation != nil {
		t.Fatal("legacy prompt was guessed into an annotation")
	}
}

func TestUserInputsFromTurnConvertsSkillsAndMedia(t *testing.T) {
	input := provider.SendTurnInput{
		Input: "Use $review, but not $reviewer or $disabled.",
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

	converted, err := userInputsFromTurn(input, skills)
	if err != nil {
		t.Fatal(err)
	}
	if len(converted) != 5 {
		t.Fatalf("converted input count = %d, want 5: %#v", len(converted), converted)
	}
	if converted[0].Type != "text" || converted[0].Text != input.Input || converted[0].TextElements == nil {
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
		if _, err := userInputsFromTurn(provider.SendTurnInput{Attachments: []provider.Attachment{attachment}}, nil); err == nil {
			t.Fatalf("attachment %#v unexpectedly accepted", attachment)
		}
	}
}

func TestLiveUserMessageItemIsNotReemitted(t *testing.T) {
	events := make(chan provider.RuntimeEvent, 1)
	h := &Instance{
		info:            provider.InstanceInfo{InstanceID: "codex-test", Name: "Codex", Driver: DriverKind},
		emit:            func(event provider.RuntimeEvent) { events <- event },
		sessionsByLocal: map[string]*sessionState{"local-thread": newSessionState("local-thread", "native-thread", "/tmp")},
		localByNative:   map[string]string{"native-thread": "local-thread"},
	}
	h.emitItem("item/started", "native-thread", "native-turn", appItem{Type: "userMessage", ID: "user-item"}, 0, 0)
	select {
	case event := <-events:
		t.Fatalf("live user message was reemitted: %#v", event)
	default:
	}
}

func TestSetConfigOptionValidatesCatalogAndNormalizesEffortForModel(t *testing.T) {
	models := []appModel{
		{Model: "model-a", SupportedReasoningEfforts: []appReasoningEffortOption{{ReasoningEffort: "medium"}, {ReasoningEffort: "high"}}, DefaultReasoningEffort: "medium", IsDefault: true},
		{Model: "model-b", SupportedReasoningEfforts: []appReasoningEffortOption{{ReasoningEffort: "low"}}, DefaultReasoningEffort: "low"},
	}
	session := newSessionState("local-thread", "native-thread", "/tmp")
	session.model = "model-a"
	session.effort = "high"
	h := &Instance{models: models, sessionsByLocal: map[string]*sessionState{"local-thread": session}}

	if err := h.SetConfigOption(context.Background(), provider.SetConfigOptionInput{ThreadID: "local-thread", OptionID: "model", Value: "model-b"}); err != nil {
		t.Fatalf("set model: %v", err)
	}
	if session.model != "model-b" || session.effort != "low" {
		t.Fatalf("normalized model/effort = %q/%q", session.model, session.effort)
	}
	if err := h.SetConfigOption(context.Background(), provider.SetConfigOptionInput{ThreadID: "local-thread", OptionID: "reasoning_effort", Value: "xhigh"}); err == nil {
		t.Fatal("unsupported effort was accepted")
	}
	if session.effort != "low" {
		t.Fatalf("rejected effort mutated session to %q", session.effort)
	}
	if err := h.SetConfigOption(context.Background(), provider.SetConfigOptionInput{ThreadID: "local-thread", OptionID: "model", Value: "missing"}); err == nil {
		t.Fatal("unsupported model was accepted")
	}
}

func TestProtocolDecodingRetainsUnknownFieldsAndReasoningContent(t *testing.T) {
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
	if !strings.Contains(string(thread.Raw), "futureThreadField") {
		t.Fatalf("thread raw JSON did not retain unknown field: %s", thread.Raw)
	}
	reasoning := thread.Turns[0].Items[0]
	if len(reasoning.ReasoningContent) != 1 || reasoning.ReasoningContent[0] != "Detail" {
		t.Fatalf("reasoning content = %#v", reasoning.ReasoningContent)
	}
	if !strings.Contains(string(reasoning.Raw), "futureItemField") {
		t.Fatalf("item raw JSON did not retain unknown field: %s", reasoning.Raw)
	}
	unknown := thread.Turns[0].Items[1]
	event, ok := runtimeEventFromItem("local-1", "local-turn-1", unknown, provider.RuntimeEventItemCompleted, time.Unix(1, 0))
	if !ok || event.Payload.ItemType != provider.ItemKindToolCall || event.Payload.ToolCall == nil || event.Payload.ToolCall.ProviderKind != "futureTool" {
		t.Fatalf("unknown item fallback = %#v, ok = %v", event, ok)
	}
}

func TestRuntimeEventFromItemNormalizesTools(t *testing.T) {
	exitCode := 0
	duration := int64(250)
	path := "/repo/README.md"
	query := "needle"
	command := appItem{
		Type: "commandExecution", ID: "cmd-1", Status: "completed",
		Command: "rg needle", Cwd: "/repo", AggregatedOutput: ptr("match"), ExitCode: &exitCode, DurationMS: &duration,
		CommandActions: []appCommandAction{{Type: "search", Path: &path, Query: &query}},
	}
	event, ok := runtimeEventFromItem("thread", "turn", command, provider.RuntimeEventItemCompleted, time.Unix(1, 0))
	if !ok {
		t.Fatal("command did not convert")
	}
	call := event.Payload.ToolCall
	if event.Payload.ItemType != provider.ItemKindCommandExecution || event.Payload.ItemStatus != provider.ItemStatusCompleted || call == nil {
		t.Fatalf("command payload = %#v", event.Payload)
	}
	if call.Action != provider.ToolActionSearch || call.Command != "rg needle" || call.Query != "needle" || call.Cwd != "/repo" || call.Output != "match" || call.ExitCode == nil || *call.ExitCode != 0 {
		t.Fatalf("command tool = %#v", call)
	}

	movePath := "/repo/new.swift"
	fileItem := appItem{Type: "fileChange", ID: "patch-1", Status: "completed", Changes: []appFileUpdateChange{{
		Path: "/repo/old.swift", Diff: "diff", Kind: appPatchChangeKind{Type: "update", MovePath: &movePath},
	}}}
	fileEvent, ok := runtimeEventFromItem("thread", "turn", fileItem, provider.RuntimeEventItemCompleted, time.Unix(2, 0))
	if !ok || fileEvent.Payload.ToolCall == nil || fileEvent.Payload.ToolCall.Action != provider.ToolActionMove {
		t.Fatalf("file event = %#v, ok = %v", fileEvent, ok)
	}
	changes := fileEvent.Payload.ToolCall.Changes
	if len(changes) != 1 || changes[0].Kind != provider.FileChangeMove || changes[0].MovePath != movePath {
		t.Fatalf("file changes = %#v", changes)
	}
}

func TestRuntimeEventFromItemNormalizesMCPResult(t *testing.T) {
	result := json.RawMessage(`{"content":[{"type":"text","text":"done"},{"type":"image","data":"aW1n","mimeType":"image/png"},{"type":"resource_link","uri":"https://example.test/spec","name":"spec","title":"Protocol","description":"Reference","mimeType":"text/html","size":42,"annotations":{"audience":["assistant"],"priority":0.8,"lastModified":"2026-08-20T00:00:00Z","_meta":{"hint":"read"}},"_meta":{"source":"mcp"}}],"structuredContent":null}`)
	readOnly := true
	item := appItem{
		Type: "mcpToolCall", ID: "mcp-1", Status: "completed", Server: "docs", Tool: "lookup", ReadOnlyHint: &readOnly, Result: result,
	}
	event, ok := runtimeEventFromItem("thread", "turn", item, provider.RuntimeEventItemCompleted, time.Unix(1, 0))
	if !ok || event.Payload.ToolCall == nil {
		t.Fatalf("MCP event = %#v, ok = %v", event, ok)
	}
	call := event.Payload.ToolCall
	if call.Action != provider.ToolActionRead || call.Namespace != "docs" || call.Name != "lookup" || call.Output != "done" {
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
	event, ok := runtimeEventFromItem("thread", "turn", item, provider.RuntimeEventItemCompleted, time.Unix(1, 0))
	if !ok || event.Payload.ToolCall == nil || len(event.Payload.ToolCall.Attachments) != 1 {
		t.Fatalf("image generation event = %#v, ok = %v", event, ok)
	}
	attachment := event.Payload.ToolCall.Attachments[0]
	if attachment.Kind != "image" || attachment.Data != "aW1hZ2U=" || attachment.MimeType != "image/png" || attachment.URI != "" {
		t.Fatalf("generated image attachment = %#v", attachment)
	}
}

func TestCompletedTextEmitsOnlyTheMissingStableTail(t *testing.T) {
	var events []provider.RuntimeEvent
	h := &Instance{
		emit:            func(event provider.RuntimeEvent) { events = append(events, event) },
		sessionsByLocal: map[string]*sessionState{},
		localByNative:   map[string]string{},
	}
	session := newSessionState("local-thread", "native-thread", "/tmp")
	h.bindSessionLocked(session)
	h.emitTextDelta(json.RawMessage(`{"threadId":"native-thread","turnId":"native-turn","itemId":"message-1","delta":"partial"}`), provider.RuntimeContentAssistantText, "")
	h.emitItem("item/completed", "native-thread", "native-turn", appItem{Type: "agentMessage", ID: "message-1", Status: "completed", Text: "partial answer"}, 0, 0)

	var deltas []string
	for _, event := range events {
		if event.Type == provider.RuntimeEventContentDelta {
			deltas = append(deltas, event.Payload.Delta)
		}
	}
	if len(deltas) != 2 || deltas[0] != "partial" || deltas[1] != " answer" {
		t.Fatalf("content deltas = %#v, want streamed prefix plus only the missing completed tail", deltas)
	}
}

func TestReplayEventsPreservesTurnAndItemOrder(t *testing.T) {
	started := float64(100)
	completed := float64(101)
	output := "ok"
	thread := appThread{ID: "native-thread", CreatedAt: 90, UpdatedAt: 101, Turns: []appTurn{{
		ID: "native-turn", Status: "completed", StartedAt: &started, CompletedAt: &completed,
		Items: []appItem{
			{Type: "userMessage", ID: "user", Content: []appUserInput{{Type: "text", Text: "hello"}}},
			{Type: "agentMessage", ID: "agent", Text: "answer"},
			{Type: "commandExecution", ID: "command", Status: "completed", Command: "pwd", AggregatedOutput: &output},
			{Type: "reasoning", ID: "reason", Summary: []string{"thinking"}},
		},
	}}}

	events := replayEvents("local-thread", thread)
	wantTypes := []provider.RuntimeEventType{
		provider.RuntimeEventTurnStarted,
		provider.RuntimeEventItemCompleted,
		provider.RuntimeEventContentDelta,
		provider.RuntimeEventItemCompleted,
		provider.RuntimeEventItemStarted,
		provider.RuntimeEventItemCompleted,
		provider.RuntimeEventContentDelta,
		provider.RuntimeEventItemCompleted,
		provider.RuntimeEventTurnCompleted,
	}
	if len(events) != len(wantTypes) {
		t.Fatalf("event count = %d, want %d: %#v", len(events), len(wantTypes), events)
	}
	for index, want := range wantTypes {
		if events[index].Type != want {
			t.Fatalf("event[%d].Type = %q, want %q", index, events[index].Type, want)
		}
		if events[index].ThreadID != "local-thread" || events[index].TurnID != "native-turn" || events[index].CreatedAt.IsZero() {
			t.Fatalf("event[%d] identity/timestamp = %#v", index, events[index])
		}
	}
	if events[1].Payload.Detail != "hello" || events[2].Payload.Delta != "answer" || events[6].Payload.Delta != "thinking" {
		t.Fatalf("replay content = %#v", events)
	}
	if events[len(events)-1].Payload.TurnState != provider.RuntimeTurnCompleted || !events[len(events)-1].CreatedAt.Equal(time.Unix(101, 0)) {
		t.Fatalf("turn completion = %#v", events[len(events)-1])
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
	if options[2].Choices[1].Description != "Most deliberate" {
		t.Fatalf("effort choice metadata = %#v", options[2].Choices[1])
	}

	fallback := configOptionsFromModels(models, "missing", "invalid", "invalid")
	if fallback[0].CurrentValue != "gpt-default" || fallback[1].CurrentValue != defaultServiceTier || fallback[2].CurrentValue != "medium" {
		t.Fatalf("fallback options = %#v", fallback)
	}
}

func TestSkillsFromResponseFallsBackToInterfaceDescriptionAndDeduplicates(t *testing.T) {
	response := skillsListResponse{Data: []appSkillsListEntry{
		{Cwd: "/a", Skills: []appSkill{{Name: "review", Description: "Review changes", Interface: &appSkillInterface{ShortDescription: "Short"}, Path: "/skills/review", Scope: "user", Enabled: true}}},
		{Cwd: "/b", Skills: []appSkill{{Name: "review", Description: "Duplicate", Path: "/skills/review", Scope: "user", Enabled: true}, {Name: "test", ShortDescription: "Run tests", Path: "/skills/test", Scope: "repo", Enabled: false}}},
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
	if state, terminal := turnState("cancelled"); !terminal || state != provider.RuntimeTurnCancelled {
		t.Fatalf("cancelled state = %q, %v", state, terminal)
	}
	if state, terminal := turnState("futureStatus"); terminal || state != "" {
		t.Fatalf("future state = %q, %v", state, terminal)
	}
	fallback := time.Unix(9, 0)
	if got := timeFromUnixMilliseconds(1_234.5, fallback); !got.Equal(time.Unix(1, 234_000_000)) {
		t.Fatalf("milliseconds = %s", got)
	}
	if got := timeFromUnixSeconds(nil, fallback); !got.Equal(fallback) {
		t.Fatalf("nil seconds = %s", got)
	}
}

func ptr(value string) *string { return &value }

func TestReasoningPartsStreamWithParagraphBreaksAndMatchCompletedSnapshot(t *testing.T) {
	var events []provider.RuntimeEvent
	h := &Instance{
		emit:            func(event provider.RuntimeEvent) { events = append(events, event) },
		sessionsByLocal: map[string]*sessionState{},
		localByNative:   map[string]string{},
	}
	h.bindSessionLocked(newSessionState("local-thread", "native-thread", "/tmp"))
	h.handleNotification("item/reasoning/summaryTextDelta", json.RawMessage(`{"threadId":"native-thread","turnId":"native-turn","itemId":"reason-1","delta":"**Planning**","summaryIndex":0}`))
	h.handleNotification("item/reasoning/summaryPartAdded", json.RawMessage(`{"threadId":"native-thread","turnId":"native-turn","itemId":"reason-1","summaryIndex":1}`))
	h.handleNotification("item/reasoning/summaryTextDelta", json.RawMessage(`{"threadId":"native-thread","turnId":"native-turn","itemId":"reason-1","delta":"**Check","summaryIndex":1}`))
	h.handleNotification("item/reasoning/summaryTextDelta", json.RawMessage(`{"threadId":"native-thread","turnId":"native-turn","itemId":"reason-1","delta":"ing**\n","summaryIndex":1}`))
	h.handleNotification("item/reasoning/textDelta", json.RawMessage(`{"threadId":"native-thread","turnId":"native-turn","itemId":"reason-1","delta":"raw thought","contentIndex":0}`))
	h.emitItem("item/completed", "native-thread", "native-turn", appItem{Type: "reasoning", ID: "reason-1", Status: "completed", Summary: []string{"**Planning**", "**Checking**"}, ReasoningContent: []string{"raw thought"}}, 0, 0)

	var deltas []string
	var completed *provider.RuntimeEvent
	for idx, event := range events {
		switch event.Type {
		case provider.RuntimeEventContentDelta:
			deltas = append(deltas, event.Payload.Delta)
		case provider.RuntimeEventItemCompleted:
			completed = &events[idx]
		}
	}
	want := []string{"**Planning**", "\n\n**Check", "ing**\n", "\nraw thought"}
	if strings.Join(deltas, "|") != strings.Join(want, "|") {
		t.Fatalf("reasoning deltas = %#v, want part breaks inserted live and no completion tail", deltas)
	}
	if completed == nil || completed.Payload.Detail != "**Planning**\n\n**Checking**\n\nraw thought" {
		t.Fatalf("completed reasoning event = %#v, want authoritative joined snapshot in Detail", completed)
	}
	if completed.Payload.Detail != strings.Join(deltas, "") {
		t.Fatalf("streamed text %q diverged from completed snapshot %q", strings.Join(deltas, ""), completed.Payload.Detail)
	}
}

func TestCommandOutputBeforeItemStartIsDropped(t *testing.T) {
	var events []provider.RuntimeEvent
	h := &Instance{
		emit:            func(event provider.RuntimeEvent) { events = append(events, event) },
		sessionsByLocal: map[string]*sessionState{},
		localByNative:   map[string]string{},
	}
	h.bindSessionLocked(newSessionState("local-thread", "native-thread", "/tmp"))
	h.emitCommandOutput(json.RawMessage(`{"threadId":"native-thread","turnId":"native-turn","itemId":"cmd-1","delta":"early"}`))
	if len(events) != 0 {
		t.Fatalf("output for an unknown item was emitted: %#v", events)
	}
	h.emitItem("item/started", "native-thread", "native-turn", appItem{Type: "commandExecution", ID: "cmd-1", Status: "inProgress", Command: "pwd"}, 0, 0)
	h.emitCommandOutput(json.RawMessage(`{"threadId":"native-thread","turnId":"native-turn","itemId":"cmd-1","delta":"/tmp"}`))
	last := events[len(events)-1]
	if last.Type != provider.RuntimeEventItemUpdated || last.Payload.ToolCall == nil || last.Payload.ToolCall.Output != "/tmp" || last.Payload.ToolCall.Name == "" {
		t.Fatalf("output update after item start = %#v, want merged into the started snapshot", last)
	}
}
