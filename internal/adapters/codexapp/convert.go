package codexapp

import (
	"encoding/json"
	"fmt"
	"net/url"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/Aqothy/maiD/internal/provider"
)

const appToolOutputLimit = 32 * 1024

// Codex uses this stable sentinel for the ordinary, non-priority tier. It is
// intentionally not included in model/list's optional serviceTiers catalog.
const defaultServiceTier = "default"

// userInputsFromTurn translates the provider-neutral prompt into Codex v2
// UserInput values. Skill references remain in the text for readable history
// and are additionally sent as structured skill values when they resolve to an
// enabled skill advertised for the session.
func userInputsFromTurn(input provider.SendTurnInput, skills []provider.Skill) ([]appUserInput, error) {
	converted := make([]appUserInput, 0, 1+len(input.Attachments)+len(skills))
	if input.Input != "" {
		converted = append(converted, appUserInput{
			Type:         "text",
			Text:         input.Input,
			TextElements: []appTextElement{},
		})
	}
	for _, skill := range referencedSkills(input.Input, skills) {
		converted = append(converted, appUserInput{Type: "skill", Name: skill.Name, Path: skill.Path})
	}
	for _, attachment := range input.Attachments {
		value, err := userInputFromAttachment(attachment)
		if err != nil {
			return nil, err
		}
		converted = append(converted, value)
	}
	return converted, nil
}

func referencedSkills(text string, skills []provider.Skill) []provider.Skill {
	type match struct {
		position int
		order    int
		skill    provider.Skill
	}
	matches := make([]match, 0)
	seen := make(map[string]struct{})
	for order, skill := range skills {
		name := strings.TrimSpace(skill.Name)
		path := strings.TrimSpace(skill.Path)
		if !skill.Enabled || name == "" || path == "" {
			continue
		}
		needle := "$" + name
		for searchFrom := 0; searchFrom < len(text); {
			relative := strings.Index(text[searchFrom:], needle)
			if relative < 0 {
				break
			}
			position := searchFrom + relative
			after := position + len(needle)
			if skillTokenBoundary(text, position, after) {
				key := name + "\x00" + path
				if _, exists := seen[key]; !exists {
					seen[key] = struct{}{}
					matches = append(matches, match{position: position, order: order, skill: skill})
				}
				break
			}
			searchFrom = after
		}
	}
	sort.SliceStable(matches, func(left, right int) bool {
		if matches[left].position != matches[right].position {
			return matches[left].position < matches[right].position
		}
		return matches[left].order < matches[right].order
	})
	result := make([]provider.Skill, 0, len(matches))
	for _, candidate := range matches {
		result = append(result, candidate.skill)
	}
	return result
}

func skillTokenBoundary(text string, start, end int) bool {
	if start > 0 {
		before, _ := utf8.DecodeLastRuneInString(text[:start])
		if isSkillTokenRune(before) {
			return false
		}
	}
	if end < len(text) {
		after, _ := utf8.DecodeRuneInString(text[end:])
		if isSkillTokenRune(after) {
			return false
		}
	}
	return true
}

func isSkillTokenRune(value rune) bool {
	return unicode.IsLetter(value) || unicode.IsDigit(value) || value == '_' || value == '-'
}

func userInputFromAttachment(attachment provider.Attachment) (appUserInput, error) {
	kind := strings.ToLower(strings.TrimSpace(attachment.Kind))
	switch kind {
	case "", "text":
		return appUserInput{Type: "text", Text: attachment.Data, TextElements: []appTextElement{}}, nil
	case "image", "local_image", "localimage":
		if kind != "image" {
			if path := firstAttachmentPath(attachment); path != "" {
				return appUserInput{Type: "localImage", Path: path}, nil
			}
			return appUserInput{}, fmt.Errorf("Codex local image attachment requires an absolute path")
		}
		if value := attachmentDataURL(attachment, "image/png"); value != "" {
			return appUserInput{Type: "image", URL: value}, nil
		}
		if path, local := localAttachmentPath(attachment.URI); local {
			return appUserInput{Type: "localImage", Path: path}, nil
		}
		return appUserInput{}, fmt.Errorf("Codex image attachment requires inline data or a local path; remote URLs are not supported")
	case "audio", "local_audio", "localaudio":
		if kind != "audio" {
			if path := firstAttachmentPath(attachment); path != "" {
				return appUserInput{Type: "localAudio", Path: path}, nil
			}
			return appUserInput{}, fmt.Errorf("Codex local audio attachment requires an absolute path")
		}
		if value := attachmentDataURL(attachment, "audio/mpeg"); value != "" {
			return appUserInput{Type: "audio", URL: value}, nil
		}
		if path, local := localAttachmentPath(attachment.URI); local {
			return appUserInput{Type: "localAudio", Path: path}, nil
		}
		return appUserInput{}, fmt.Errorf("Codex audio attachment requires inline data or a local path; remote URLs are not supported")
	case "skill":
		name := strings.TrimSpace(attachment.Name)
		path := strings.TrimSpace(attachment.URI)
		if name != "" && path != "" {
			return appUserInput{Type: "skill", Name: name, Path: path}, nil
		}
		return appUserInput{}, fmt.Errorf("Codex skill attachment requires a name and path")
	case "resource", "embedded_context", "embeddedcontext", "resource_link", "resourcelink":
		return appUserInput{}, fmt.Errorf("Codex app-server does not accept embedded-resource prompt attachments")
	default:
		return appUserInput{}, fmt.Errorf("Codex app-server does not accept attachment kind %q", attachment.Kind)
	}
}

func attachmentDataURL(attachment provider.Attachment, fallbackMIME string) string {
	data := strings.TrimSpace(attachment.Data)
	if data == "" {
		if strings.HasPrefix(strings.ToLower(strings.TrimSpace(attachment.URI)), "data:") {
			return strings.TrimSpace(attachment.URI)
		}
		return ""
	}
	if strings.HasPrefix(strings.ToLower(data), "data:") {
		return data
	}
	mimeType := strings.TrimSpace(attachment.MimeType)
	if mimeType == "" {
		mimeType = fallbackMIME
	}
	return "data:" + mimeType + ";base64," + data
}

func firstAttachmentPath(attachment provider.Attachment) string {
	if path, _ := localAttachmentPath(attachment.URI); path != "" {
		return path
	}
	if path, _ := localAttachmentPath(attachment.Data); path != "" {
		return path
	}
	if path, _ := localAttachmentPath(attachment.Name); path != "" {
		return path
	}
	return ""
}

func localAttachmentPath(value string) (string, bool) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", false
	}
	if strings.HasPrefix(strings.ToLower(value), "file://") {
		parsed, err := url.Parse(value)
		if err != nil || parsed.Path == "" {
			return "", false
		}
		path, err := url.PathUnescape(parsed.Path)
		if err != nil {
			path = parsed.Path
		}
		return path, true
	}
	if filepath.IsAbs(value) || isWindowsAbsolutePath(value) {
		return value, true
	}
	return "", false
}

func isWindowsAbsolutePath(value string) bool {
	return len(value) >= 3 && unicode.IsLetter(rune(value[0])) && value[1] == ':' && (value[2] == '\\' || value[2] == '/')
}

// replayEvents converts an app-server history snapshot into the same canonical
// event vocabulary used by live streaming. Started item events are included as
// chronology boundaries so text before a tool is committed before that tool.
func replayEvents(localThreadID string, thread appThread) []provider.RuntimeEvent {
	events := make([]provider.RuntimeEvent, 0)
	threadFallback := unixSeconds(thread.UpdatedAt)
	if threadFallback.IsZero() {
		threadFallback = unixSeconds(thread.CreatedAt)
	}
	for _, turn := range thread.Turns {
		turnID := turn.ID
		startedAt := timeFromUnixSeconds(turn.StartedAt, threadFallback)
		events = append(events, provider.RuntimeEvent{
			EventID:   replayEventID(turnID, "", "turn-started"),
			Type:      provider.RuntimeEventTurnStarted,
			Provider:  DriverKind,
			ThreadID:  localThreadID,
			TurnID:    turnID,
			CreatedAt: startedAt,
		})
		for index, original := range turn.Items {
			item := original
			if item.ID == "" {
				item.ID = fmt.Sprintf("%s:item:%d", turnID, index+1)
			}
			at := startedAt.Add(time.Duration(index+1) * time.Microsecond)
			switch item.Type {
			case "userMessage":
				if event, ok := runtimeEventFromItem(localThreadID, turnID, item, provider.RuntimeEventItemCompleted, at); ok {
					event.EventID = replayEventID(turnID, item.ID, "completed")
					events = append(events, event)
				}
			case "agentMessage":
				if item.Text != "" {
					events = append(events, replayContentEvent(localThreadID, turnID, item.ID, provider.RuntimeContentAssistantText, item.Text, at))
				}
				if event, ok := runtimeEventFromItem(localThreadID, turnID, item, provider.RuntimeEventItemCompleted, at.Add(time.Nanosecond)); ok {
					event.EventID = replayEventID(turnID, item.ID, "completed")
					events = append(events, event)
				}
			case "reasoning":
				if text := reasoningText(item); text != "" {
					events = append(events, replayContentEvent(localThreadID, turnID, item.ID, provider.RuntimeContentReasoningText, text, at))
				}
				// Preserve the same boundary as item/completed in the live
				// stream. Otherwise adjacent thoughts concatenate on reload
				// and every later reasoning segment receives a different ID.
				if event, ok := runtimeEventFromItem(localThreadID, turnID, item, provider.RuntimeEventItemCompleted, at.Add(time.Nanosecond)); ok {
					event.EventID = replayEventID(turnID, item.ID, "completed")
					events = append(events, event)
				}
			default:
				started := item
				started.Status = "inProgress"
				if event, ok := runtimeEventFromItem(localThreadID, turnID, started, provider.RuntimeEventItemStarted, at); ok {
					event.EventID = replayEventID(turnID, item.ID, "started")
					events = append(events, event)
				}
				if event, ok := runtimeEventFromItem(localThreadID, turnID, item, provider.RuntimeEventItemCompleted, at.Add(time.Nanosecond)); ok {
					event.EventID = replayEventID(turnID, item.ID, "completed")
					events = append(events, event)
				}
			}
		}
		if state, terminal := turnState(turn.Status); terminal {
			completedAt := timeFromUnixSeconds(turn.CompletedAt, startedAt.Add(time.Duration(len(turn.Items)+1)*time.Microsecond))
			payload := provider.RuntimeEventPayload{TurnState: state}
			if turn.Error != nil {
				payload.Message = strings.TrimSpace(turn.Error.Message)
				if payload.Detail == "" && turn.Error.AdditionalDetails != nil {
					payload.Detail = strings.TrimSpace(*turn.Error.AdditionalDetails)
				}
			}
			events = append(events, provider.RuntimeEvent{
				EventID:   replayEventID(turnID, "", "turn-completed"),
				Type:      provider.RuntimeEventTurnCompleted,
				Provider:  DriverKind,
				ThreadID:  localThreadID,
				TurnID:    turnID,
				CreatedAt: completedAt,
				Payload:   payload,
			})
		}
	}
	return events
}

func replayContentEvent(threadID, turnID, itemID string, kind provider.RuntimeContentStreamKind, delta string, at time.Time) provider.RuntimeEvent {
	return provider.RuntimeEvent{
		EventID:   replayEventID(turnID, itemID, "content"),
		Type:      provider.RuntimeEventContentDelta,
		Provider:  DriverKind,
		ThreadID:  threadID,
		TurnID:    turnID,
		ItemID:    itemID,
		CreatedAt: at,
		Payload: provider.RuntimeEventPayload{
			StreamKind: kind,
			Delta:      delta,
		},
	}
}

func replayEventID(turnID, itemID, suffix string) provider.RuntimeEventID {
	return provider.RuntimeEventID("codex:replay:" + turnID + ":" + itemID + ":" + suffix)
}

// runtimeEventFromItem converts one item lifecycle notification. Streaming
// text itself is carried by the app-server delta notifications; assistant item
// completion remains useful as the flush checkpoint for that stream.
func runtimeEventFromItem(localThreadID, localTurnID string, item appItem, eventType provider.RuntimeEventType, at time.Time) (provider.RuntimeEvent, bool) {
	if localThreadID == "" || item.Type == "" {
		return provider.RuntimeEvent{}, false
	}
	event := provider.RuntimeEvent{
		EventID:   provider.RuntimeEventID(fmt.Sprintf("codex:item:%s:%s:%s", localTurnID, item.ID, eventType)),
		Type:      eventType,
		Provider:  DriverKind,
		ThreadID:  localThreadID,
		TurnID:    localTurnID,
		ItemID:    item.ID,
		CreatedAt: at,
	}
	status := itemStatusFromApp(item.Status, eventType)
	switch item.Type {
	case "userMessage":
		text, attachments := userMessageContent(item.Content)
		clientID := ""
		if item.ClientID != nil {
			clientID = *item.ClientID
		}
		event.Payload = provider.RuntimeEventPayload{
			ClientMessageID: clientID,
			ItemType:        provider.ItemKindUserMessage,
			ItemStatus:      status,
			Detail:          text,
			Attachments:     attachments,
		}
	case "agentMessage":
		event.Payload = provider.RuntimeEventPayload{ItemType: provider.ItemKindAssistantMessage, ItemStatus: status}
	case "reasoning":
		event.Payload = provider.RuntimeEventPayload{ItemType: provider.ItemKindReasoning, ItemStatus: status, Detail: reasoningText(item)}
	case "plan":
		event.Payload = provider.RuntimeEventPayload{
			ItemType:   provider.ItemKindToolCall,
			ItemStatus: status,
			Title:      "Plan",
			ToolCall: &provider.ToolCall{
				Action:       provider.ToolActionThink,
				Name:         "Plan",
				ProviderKind: item.Type,
				Output:       boundedAppOutput(item.Text),
			},
		}
	case "commandExecution":
		event.Payload = toolPayload(item, provider.ItemKindCommandExecution, status, commandToolCall(item), "Ran command")
	case "fileChange":
		event.Payload = toolPayload(item, provider.ItemKindFileChange, status, fileChangeToolCall(item), "Changed files")
	case "mcpToolCall":
		title := strings.Trim(strings.TrimSpace(item.Server)+" · "+strings.TrimSpace(item.Tool), " ·")
		event.Payload = toolPayload(item, provider.ItemKindMCPToolCall, status, mcpToolCall(item), title)
	case "dynamicToolCall":
		title := strings.Trim(strings.TrimSpace(stringValue(item.Namespace))+" · "+strings.TrimSpace(item.Tool), " ·")
		event.Payload = toolPayload(item, provider.ItemKindToolCall, status, dynamicToolCall(item), title)
	case "collabAgentToolCall":
		event.Payload = toolPayload(item, provider.ItemKindToolCall, status, collabToolCall(item), collabTitle(item.Tool))
	case "subAgentActivity":
		event.Payload = toolPayload(item, provider.ItemKindToolCall, status, subagentToolCall(item), "Agent "+provider.HumanizeIdentifier(item.Kind))
	case "webSearch":
		event.Payload = toolPayload(item, provider.ItemKindWebSearch, status, webSearchToolCall(item), webSearchTitle(item))
	case "imageView":
		event.Payload = toolPayload(item, provider.ItemKindImageView, status, imageViewToolCall(item), "Viewed image")
	case "imageGeneration":
		event.Payload = toolPayload(item, provider.ItemKindImageGeneration, status, imageGenerationToolCall(item), "Generated image")
	case "contextCompaction":
		event.Payload = provider.RuntimeEventPayload{ItemType: provider.ItemKindContextCompaction, ItemStatus: status, Title: "Compacted context"}
	case "enteredReviewMode", "exitedReviewMode":
		event.Payload = toolPayload(item, provider.ItemKindToolCall, status, reviewModeToolCall(item), provider.HumanizeIdentifier(item.Type))
	case "sleep":
		event.Payload = toolPayload(item, provider.ItemKindToolCall, status, sleepToolCall(item), "Waited")
	default:
		event.Payload = provider.RuntimeEventPayload{
			ItemType:   provider.ItemKindToolCall,
			ItemStatus: status,
			Title:      provider.HumanizeIdentifier(item.Type),
			ToolCall: &provider.ToolCall{
				Action:       provider.ToolActionOther,
				Name:         provider.HumanizeIdentifier(item.Type),
				ProviderKind: item.Type,
			},
		}
	}
	return event, true
}

func toolPayload(item appItem, kind provider.ItemKind, status provider.ItemStatus, call *provider.ToolCall, title string) provider.RuntimeEventPayload {
	return provider.RuntimeEventPayload{
		ItemType:   kind,
		ItemStatus: status,
		Title:      strings.TrimSpace(title),
		ToolCall:   call,
	}
}

func commandToolCall(item appItem) *provider.ToolCall {
	call := &provider.ToolCall{
		Action:               commandAction(item.CommandActions),
		Name:                 "Command",
		ProviderKind:         item.Type,
		Command:              item.Command,
		Cwd:                  item.Cwd,
		Output:               boundedAppOutput(stringValue(item.AggregatedOutput)),
		ExitCode:             item.ExitCode,
		DurationMilliseconds: item.DurationMS,
	}
	for _, action := range item.CommandActions {
		if action.Path != nil && strings.TrimSpace(*action.Path) != "" {
			call.Locations = append(call.Locations, provider.ToolLocation{Path: strings.TrimSpace(*action.Path)})
		}
		if call.Query == "" && action.Query != nil {
			call.Query = strings.TrimSpace(*action.Query)
		}
	}
	return call
}

func commandAction(actions []appCommandAction) provider.ToolAction {
	if len(actions) == 0 {
		return provider.ToolActionExecute
	}
	result := provider.ToolActionRead
	for _, action := range actions {
		switch action.Type {
		case "read", "listFiles":
		case "search":
			if result == provider.ToolActionRead {
				result = provider.ToolActionSearch
			}
		default:
			return provider.ToolActionExecute
		}
	}
	return result
}

func fileChangeToolCall(item appItem) *provider.ToolCall {
	call := &provider.ToolCall{Action: provider.ToolActionEdit, Name: "File change", ProviderKind: item.Type}
	allDelete := len(item.Changes) > 0
	allMove := len(item.Changes) > 0
	for _, change := range item.Changes {
		converted := provider.FileChange{Path: change.Path, Diff: change.Diff}
		switch change.Kind.Type {
		case "add":
			converted.Kind = provider.FileChangeAdd
			allDelete = false
			allMove = false
		case "delete":
			converted.Kind = provider.FileChangeDelete
			allMove = false
		case "update":
			converted.Kind = provider.FileChangeUpdate
			allDelete = false
			if change.Kind.MovePath != nil && strings.TrimSpace(*change.Kind.MovePath) != "" {
				converted.Kind = provider.FileChangeMove
				converted.MovePath = strings.TrimSpace(*change.Kind.MovePath)
			} else {
				allMove = false
			}
		default:
			converted.Kind = provider.FileChangeUpdate
			allDelete = false
			allMove = false
		}
		call.Changes = append(call.Changes, converted)
		if change.Path != "" {
			call.Locations = append(call.Locations, provider.ToolLocation{Path: change.Path})
		}
	}
	if allDelete {
		call.Action = provider.ToolActionDelete
	} else if allMove {
		call.Action = provider.ToolActionMove
	}
	return call
}

func mcpToolCall(item appItem) *provider.ToolCall {
	call := &provider.ToolCall{
		Action:               provider.ToolActionFromName(item.Tool),
		Name:                 item.Tool,
		Namespace:            item.Server,
		ProviderKind:         item.Type,
		DurationMilliseconds: item.DurationMS,
	}
	if item.ReadOnlyHint != nil && *item.ReadOnlyHint && call.Action == provider.ToolActionOther {
		call.Action = provider.ToolActionRead
	}
	var result appMCPResult
	if len(item.Result) > 0 && string(item.Result) != "null" && json.Unmarshal(item.Result, &result) == nil {
		call.Output, call.Attachments = mcpResultContent(result)
	}
	if item.Error != nil {
		call.Error = strings.TrimSpace(item.Error.Message)
	}
	return call
}

func mcpResultContent(result appMCPResult) (string, []provider.Attachment) {
	parts := make([]string, 0)
	attachments := make([]provider.Attachment, 0)
	for _, raw := range result.Content {
		var content struct {
			Type        string         `json:"type"`
			Text        string         `json:"text"`
			Data        string         `json:"data"`
			MimeType    string         `json:"mimeType"`
			URI         string         `json:"uri"`
			Name        string         `json:"name"`
			Title       string         `json:"title"`
			Description string         `json:"description"`
			Size        int64          `json:"size"`
			Meta        map[string]any `json:"_meta"`
			Annotations *struct {
				Audience     []string       `json:"audience"`
				Priority     *float64       `json:"priority"`
				LastModified string         `json:"lastModified"`
				Meta         map[string]any `json:"_meta"`
			} `json:"annotations"`
		}
		if json.Unmarshal(raw, &content) != nil {
			continue
		}
		switch content.Type {
		case "text":
			if content.Text != "" {
				parts = append(parts, content.Text)
			}
		case "image", "audio":
			attachments = append(attachments, provider.Attachment{Kind: content.Type, Data: content.Data, MimeType: content.MimeType, URI: content.URI, Name: content.Name})
		case "resource_link":
			attachment := provider.Attachment{
				Kind: content.Type, URI: content.URI, Name: content.Name, Title: content.Title,
				Description: content.Description, MimeType: content.MimeType, Size: content.Size, Metadata: content.Meta,
			}
			if content.Annotations != nil {
				attachment.Annotations = &provider.ContentAnnotations{
					Audience: append([]string(nil), content.Annotations.Audience...), Priority: content.Annotations.Priority,
					LastModified: content.Annotations.LastModified, Metadata: content.Annotations.Meta,
				}
			}
			attachments = append(attachments, attachment)
		}
	}
	if len(parts) == 0 && len(result.StructuredContent) > 0 && string(result.StructuredContent) != "null" {
		parts = append(parts, compactRawJSON(result.StructuredContent))
	}
	return boundedAppOutput(strings.Join(parts, "\n")), attachments
}

func dynamicToolCall(item appItem) *provider.ToolCall {
	call := &provider.ToolCall{
		Action:               provider.ToolActionFromName(item.Tool),
		Name:                 item.Tool,
		Namespace:            stringValue(item.Namespace),
		ProviderKind:         item.Type,
		DurationMilliseconds: item.DurationMS,
	}
	var output []string
	for _, content := range item.ContentItems {
		switch content.Type {
		case "inputText":
			if content.Text != "" {
				output = append(output, content.Text)
			}
		case "inputImage":
			if attachment, ok := attachmentFromAppURL("image", content.ImageURL); ok {
				call.Attachments = append(call.Attachments, attachment)
			}
		case "inputAudio":
			if attachment, ok := attachmentFromAppURL("audio", content.AudioURL); ok {
				call.Attachments = append(call.Attachments, attachment)
			}
		}
	}
	call.Output = boundedAppOutput(strings.Join(output, "\n"))
	if item.Success != nil && !*item.Success {
		call.Error = "Tool call failed"
	}
	return call
}

func collabToolCall(item appItem) *provider.ToolCall {
	call := &provider.ToolCall{
		Action:       provider.ToolActionDelegate,
		Name:         item.Tool,
		Namespace:    "collaboration",
		ProviderKind: item.Type,
		Output:       boundedAppOutput(stringValue(item.Prompt)),
	}
	for _, threadID := range item.ReceiverThreadIDs {
		if strings.TrimSpace(threadID) != "" {
			call.Locations = append(call.Locations, provider.ToolLocation{Path: "thread:" + threadID})
		}
	}
	return call
}

func subagentToolCall(item appItem) *provider.ToolCall {
	return &provider.ToolCall{
		Action:       provider.ToolActionDelegate,
		Name:         provider.HumanizeIdentifier(item.Kind),
		Namespace:    "collaboration",
		ProviderKind: item.Type,
		Output:       strings.TrimSpace(item.AgentThreadID),
	}
}

func webSearchToolCall(item appItem) *provider.ToolCall {
	call := &provider.ToolCall{Action: provider.ToolActionSearch, Name: "Web search", ProviderKind: item.Type, Query: item.Query}
	if item.Action == nil {
		return call
	}
	switch item.Action.Type {
	case "openPage":
		call.Action = provider.ToolActionFetch
		call.Query = stringValue(item.Action.URL)
	case "findInPage":
		call.Action = provider.ToolActionSearch
		call.Query = stringValue(item.Action.Pattern)
		if call.Query == "" {
			call.Query = stringValue(item.Action.URL)
		}
	case "search":
		call.Query = stringValue(item.Action.Query)
		if call.Query == "" && len(item.Action.Queries) > 0 {
			call.Query = strings.Join(item.Action.Queries, ", ")
		}
	}
	return call
}

func webSearchTitle(item appItem) string {
	call := webSearchToolCall(item)
	if strings.TrimSpace(call.Query) != "" {
		return strings.TrimSpace(call.Query)
	}
	return "Web search"
}

func imageViewToolCall(item appItem) *provider.ToolCall {
	call := &provider.ToolCall{Action: provider.ToolActionView, Name: "Image", ProviderKind: item.Type}
	if strings.TrimSpace(item.Path) != "" {
		call.Locations = []provider.ToolLocation{{Path: item.Path}}
		call.Attachments = []provider.Attachment{{Kind: "image", URI: item.Path}}
	}
	return call
}

func imageGenerationToolCall(item appItem) *provider.ToolCall {
	call := &provider.ToolCall{Action: provider.ToolActionView, Name: "Image generation", ProviderKind: item.Type, Output: boundedAppOutput(stringValue(item.RevisedPrompt))}
	var generated string
	if len(item.Result) > 0 {
		_ = json.Unmarshal(item.Result, &generated)
	}
	if generated != "" {
		if strings.HasPrefix(strings.ToLower(strings.TrimSpace(generated)), "data:") {
			if attachment, ok := attachmentFromAppURL("image", generated); ok {
				call.Attachments = append(call.Attachments, attachment)
			}
		} else {
			call.Attachments = append(call.Attachments, provider.Attachment{Kind: "image", Data: generated, MimeType: "image/png"})
		}
	}
	if item.SavedPath != nil && strings.TrimSpace(*item.SavedPath) != "" {
		call.Attachments = append(call.Attachments, provider.Attachment{Kind: "image", URI: strings.TrimSpace(*item.SavedPath)})
	}
	return call
}

func reviewModeToolCall(item appItem) *provider.ToolCall {
	return &provider.ToolCall{
		Action:       provider.ToolActionSwitchMode,
		Name:         provider.HumanizeIdentifier(item.Type),
		ProviderKind: item.Type,
		Output:       boundedAppOutput(item.Review),
	}
}

func sleepToolCall(item appItem) *provider.ToolCall {
	return &provider.ToolCall{
		Action:               provider.ToolActionOther,
		Name:                 "Sleep",
		ProviderKind:         item.Type,
		DurationMilliseconds: item.DurationMS,
	}
}

func collabTitle(tool string) string {
	title := provider.HumanizeIdentifier(tool)
	if title == "" {
		return "Agent collaboration"
	}
	return title
}

func userMessageContent(inputs []appUserInput) (string, []provider.Attachment) {
	var text strings.Builder
	attachments := make([]provider.Attachment, 0)
	var skillNames []string
	for _, input := range inputs {
		switch input.Type {
		case "text":
			text.WriteString(input.Text)
		case "image":
			if attachment, ok := attachmentFromAppURL("image", input.URL); ok {
				attachments = append(attachments, attachment)
			}
		case "localImage":
			attachments = append(attachments, provider.Attachment{Kind: "image", URI: input.Path})
		case "audio":
			if attachment, ok := attachmentFromAppURL("audio", input.URL); ok {
				attachments = append(attachments, attachment)
			}
		case "localAudio":
			attachments = append(attachments, provider.Attachment{Kind: "audio", URI: input.Path})
		case "skill":
			if input.Name != "" {
				skillNames = append(skillNames, "$"+input.Name)
			}
		}
	}
	if text.Len() == 0 && len(skillNames) > 0 {
		text.WriteString(strings.Join(skillNames, " "))
	}
	return text.String(), attachments
}

func attachmentFromAppURL(kind, value string) (provider.Attachment, bool) {
	value = strings.TrimSpace(value)
	if value == "" {
		return provider.Attachment{}, false
	}
	if strings.HasPrefix(strings.ToLower(value), "data:") {
		if mimeType, data, ok := parseDataURL(value); ok {
			return provider.Attachment{Kind: kind, MimeType: mimeType, Data: data}, true
		}
	}
	return provider.Attachment{Kind: kind, URI: value}, true
}

func parseDataURL(value string) (mimeType, data string, ok bool) {
	header, payload, found := strings.Cut(value, ",")
	if !found || !strings.HasPrefix(strings.ToLower(header), "data:") {
		return "", "", false
	}
	metadata := header[len("data:"):]
	parts := strings.Split(metadata, ";")
	if len(parts) > 0 {
		mimeType = parts[0]
	}
	base64Encoded := false
	for _, part := range parts[1:] {
		if strings.EqualFold(part, "base64") {
			base64Encoded = true
			break
		}
	}
	if !base64Encoded {
		decoded, err := url.PathUnescape(payload)
		if err != nil {
			return "", "", false
		}
		return mimeType, decoded, true
	}
	return mimeType, payload, true
}

func reasoningText(item appItem) string {
	parts := make([]string, 0, len(item.Summary)+len(item.ReasoningContent))
	for _, part := range append(append([]string(nil), item.Summary...), item.ReasoningContent...) {
		part = strings.TrimSpace(part)
		if part != "" && (len(parts) == 0 || parts[len(parts)-1] != part) {
			parts = append(parts, part)
		}
	}
	return strings.Join(parts, "\n\n")
}

func turnState(status string) (provider.RuntimeTurnState, bool) {
	switch status {
	case "completed":
		return provider.RuntimeTurnCompleted, true
	case "failed":
		return provider.RuntimeTurnFailed, true
	case "interrupted":
		return provider.RuntimeTurnInterrupted, true
	case "cancelled", "canceled":
		return provider.RuntimeTurnCancelled, true
	default:
		return "", false
	}
}

func itemStatusFromApp(status string, eventType provider.RuntimeEventType) provider.ItemStatus {
	switch status {
	case "inProgress", "in_progress", "running":
		return provider.ItemStatusInProgress
	case "completed", "succeeded", "success":
		return provider.ItemStatusCompleted
	case "failed", "error":
		return provider.ItemStatusFailed
	case "interrupted", "cancelled", "canceled":
		return provider.ItemStatusInterrupted
	case "declined", "rejected":
		return provider.ItemStatusDeclined
	}
	switch eventType {
	case provider.RuntimeEventItemStarted:
		return provider.ItemStatusInProgress
	case provider.RuntimeEventItemCompleted:
		return provider.ItemStatusCompleted
	default:
		return ""
	}
}

func unixSeconds(value float64) time.Time {
	if value <= 0 {
		return time.Time{}
	}
	seconds := int64(value)
	nanoseconds := int64((value - float64(seconds)) * float64(time.Second))
	return time.Unix(seconds, nanoseconds).UTC()
}

func timeFromUnixSeconds(value *float64, fallback time.Time) time.Time {
	if value == nil {
		return fallback
	}
	converted := unixSeconds(*value)
	if converted.IsZero() {
		return fallback
	}
	return converted
}

func sessionSummaryFromThread(thread appThread) provider.SessionSummary {
	updatedAt := unixSeconds(thread.UpdatedAt)
	return provider.SessionSummary{
		SessionID: thread.ID,
		Title:     threadTitle(thread),
		Cwd:       thread.Cwd,
		UpdatedAt: formatOptionalTimestamp(updatedAt),
	}
}

func threadTitle(thread appThread) string {
	if thread.Name != nil && strings.TrimSpace(*thread.Name) != "" {
		return strings.TrimSpace(*thread.Name)
	}
	return provider.PromptPreviewTitle(thread.Preview)
}

func formatOptionalTimestamp(value time.Time) string {
	if value.IsZero() {
		return ""
	}
	return value.UTC().Format(time.RFC3339Nano)
}

func configOptionsFromModels(models []appModel, selectedModel, selectedEffort, selectedTier string) []provider.ConfigOption {
	visible := make([]appModel, 0, len(models))
	for _, model := range models {
		if !model.Hidden && modelSlug(model) != "" {
			visible = append(visible, model)
		}
	}
	if len(visible) == 0 {
		return []provider.ConfigOption{}
	}
	currentIndex := -1
	selectedModel = strings.TrimSpace(selectedModel)
	for index, model := range visible {
		if modelSlug(model) == selectedModel {
			currentIndex = index
			break
		}
	}
	if currentIndex < 0 {
		for index, model := range visible {
			if model.IsDefault {
				currentIndex = index
				break
			}
		}
	}
	if currentIndex < 0 {
		currentIndex = 0
	}
	current := visible[currentIndex]
	modelChoices := make([]provider.ConfigChoice, 0, len(visible))
	for _, model := range visible {
		label := strings.TrimSpace(model.DisplayName)
		if label == "" {
			label = modelSlug(model)
		}
		modelChoices = append(modelChoices, provider.ConfigChoice{
			Value:       modelSlug(model),
			Label:       label,
			Description: strings.TrimSpace(model.Description),
		})
	}
	options := []provider.ConfigOption{{
		ID:           "model",
		Type:         provider.ConfigOptionTypeSelect,
		Category:     provider.ConfigOptionCategoryModel,
		Label:        "Model",
		Description:  "Model used for this thread",
		Choices:      modelChoices,
		CurrentValue: modelSlug(current),
	}}
	if len(current.ServiceTiers) > 0 {
		tierChoices := make([]provider.ConfigChoice, 0, len(current.ServiceTiers)+1)
		tierChoices = append(tierChoices, provider.ConfigChoice{
			Value: defaultServiceTier, Label: "Standard", Description: "Standard speed and usage",
		})
		validTiers := make(map[string]struct{}, len(current.ServiceTiers)+1)
		validTiers[defaultServiceTier] = struct{}{}
		for _, tier := range current.ServiceTiers {
			value := strings.TrimSpace(tier.ID)
			if value == "" {
				continue
			}
			validTiers[value] = struct{}{}
			label := strings.TrimSpace(tier.Name)
			if label == "" {
				label = provider.HumanizeIdentifier(value)
			}
			tierChoices = append(tierChoices, provider.ConfigChoice{Value: value, Label: label, Description: strings.TrimSpace(tier.Description)})
		}
		tier := strings.TrimSpace(selectedTier)
		if _, valid := validTiers[tier]; !valid {
			tier = strings.TrimSpace(current.DefaultServiceTier)
		}
		if _, valid := validTiers[tier]; !valid {
			tier = defaultServiceTier
		}
		options = append(options, provider.ConfigOption{
			ID: "service_tier", Type: provider.ConfigOptionTypeSelect, Category: provider.ConfigOptionCategoryModelConfig,
			Label: "Service tier", Description: "Service tier used for this thread", Choices: tierChoices, CurrentValue: tier,
		})
	}
	if len(current.SupportedReasoningEfforts) == 0 {
		return options
	}
	effortChoices := make([]provider.ConfigChoice, 0, len(current.SupportedReasoningEfforts))
	validEffort := make(map[string]struct{}, len(current.SupportedReasoningEfforts))
	for _, effort := range current.SupportedReasoningEfforts {
		value := strings.TrimSpace(effort.ReasoningEffort)
		if value == "" {
			continue
		}
		validEffort[value] = struct{}{}
		effortChoices = append(effortChoices, provider.ConfigChoice{
			Value:       value,
			Label:       provider.HumanizeIdentifier(value),
			Description: strings.TrimSpace(effort.Description),
		})
	}
	if len(effortChoices) == 0 {
		return options
	}
	effort := strings.TrimSpace(selectedEffort)
	if _, valid := validEffort[effort]; !valid {
		effort = strings.TrimSpace(current.DefaultReasoningEffort)
	}
	if _, valid := validEffort[effort]; !valid {
		effort = effortChoices[0].Value
	}
	options = append(options, provider.ConfigOption{
		ID:           "reasoning_effort",
		Type:         provider.ConfigOptionTypeSelect,
		Category:     provider.ConfigOptionCategoryThoughtLevel,
		Label:        "Reasoning",
		Description:  "Reasoning effort used for this thread",
		Choices:      effortChoices,
		CurrentValue: effort,
	})
	return options
}

func modelSlug(model appModel) string {
	if strings.TrimSpace(model.Model) != "" {
		return strings.TrimSpace(model.Model)
	}
	return strings.TrimSpace(model.ID)
}

func skillsFromResponse(response skillsListResponse) []provider.Skill {
	result := make([]provider.Skill, 0)
	seen := make(map[string]struct{})
	for _, entry := range response.Data {
		for _, skill := range entry.Skills {
			name := strings.TrimSpace(skill.Name)
			path := strings.TrimSpace(skill.Path)
			if name == "" {
				continue
			}
			key := path
			if key == "" {
				key = strings.TrimSpace(skill.Scope) + "\x00" + name
			}
			if _, exists := seen[key]; exists {
				continue
			}
			seen[key] = struct{}{}
			shortDescription := strings.TrimSpace(skill.ShortDescription)
			if shortDescription == "" && skill.Interface != nil {
				shortDescription = strings.TrimSpace(skill.Interface.ShortDescription)
			}
			result = append(result, provider.Skill{
				Name:             name,
				Description:      strings.TrimSpace(skill.Description),
				ShortDescription: shortDescription,
				Path:             path,
				Scope:            strings.TrimSpace(skill.Scope),
				Enabled:          skill.Enabled,
			})
		}
	}
	return result
}

func providerFileChanges(changes []appFileUpdateChange) []provider.FileChange {
	converted := make([]provider.FileChange, 0, len(changes))
	for _, change := range changes {
		value := provider.FileChange{Path: change.Path, Diff: change.Diff}
		switch change.Kind.Type {
		case "add":
			value.Kind = provider.FileChangeAdd
		case "delete":
			value.Kind = provider.FileChangeDelete
		case "update":
			value.Kind = provider.FileChangeUpdate
			if change.Kind.MovePath != nil && strings.TrimSpace(*change.Kind.MovePath) != "" {
				value.Kind = provider.FileChangeMove
				value.MovePath = strings.TrimSpace(*change.Kind.MovePath)
			}
		default:
			value.Kind = provider.FileChangeUpdate
		}
		converted = append(converted, value)
	}
	return converted
}

func planEntriesFromApp(steps []appPlanStep) []provider.PlanEntry {
	entries := make([]provider.PlanEntry, 0, len(steps))
	for _, step := range steps {
		status := provider.PlanEntryStatusPending
		switch step.Status {
		case "inProgress", "in_progress":
			status = provider.PlanEntryStatusInProgress
		case "completed":
			status = provider.PlanEntryStatusCompleted
		}
		entries = append(entries, provider.PlanEntry{Content: step.Step, Status: status})
	}
	return entries
}

func boundedAppOutput(value string) string {
	if len(value) <= appToolOutputLimit {
		return value
	}
	cut := appToolOutputLimit
	for cut > 0 && !utf8.RuneStart(value[cut]) {
		cut--
	}
	return value[:cut]
}

func compactRawJSON(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var value any
	if json.Unmarshal(raw, &value) != nil {
		return ""
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return ""
	}
	return boundedAppOutput(string(encoded))
}

func stringValue(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}
