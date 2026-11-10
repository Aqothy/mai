package acp

import (
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"

	"github.com/Aqothy/go-acp/schema"
	"github.com/Aqothy/jsonrpc2"
	"github.com/Aqothy/maiD/internal/provider"
)

func authStateFromACP(initResp schema.InitializeResponse) provider.Auth {
	methods := authMethodsFromACP(initResp.AuthMethods)
	// No advertised methods => the agent needs no client-driven auth. Advertised
	// methods say auth is AVAILABLE, not that it is required: ACP has no
	// auth-status probe, and agents (e.g. claude-code-acp) advertise their login
	// method even while already authenticated. So report unknown; clients render
	// the methods as actions, and the status turns unauthenticated once a
	// request fails with auth_required (noteAuthRequired).
	status := provider.AuthStatusAuthenticated
	if len(initResp.AuthMethods) > 0 {
		status = provider.AuthStatusUnknown
	}
	return provider.Auth{Status: status, Methods: methods}
}

// capabilitySet is what the agent offers. Sessions maiD ran rebuild from the
// mirror, so they keep their delivery IDs (MessageIDs) only with one; the
// agent's own replay rates only sessions run elsewhere.
func capabilitySet(initResp schema.InitializeResponse, mirrored bool) provider.Capabilities {
	capabilities := agentCapabilitiesValue(initResp.AgentCapabilities)
	prompt := schema.PromptCapabilities{}
	if capabilities.PromptCapabilities != nil {
		prompt = *capabilities.PromptCapabilities
	}
	mcp := schema.McpCapabilities{}
	if capabilities.MCPCapabilities != nil {
		mcp = *capabilities.MCPCapabilities
	}
	sessions := schema.SessionCapabilities{}
	if capabilities.SessionCapabilities != nil {
		sessions = *capabilities.SessionCapabilities
	}
	history := provider.HistoryNone
	if boolValue(capabilities.LoadSession) {
		history = provider.HistoryLossy
	}
	return provider.Capabilities{
		History:               history,
		HistoryVersion:        historyVersion,
		Resume:                sessions.Resume != nil || boolValue(capabilities.LoadSession),
		MessageIDs:            mirrored,
		MCP:                   provider.MCPCapabilities{HTTP: boolValue(mcp.HTTP), Stdio: true},
		AdditionalDirectories: sessions.AdditionalDirectories != nil,
		Sessions:              sessions.List != nil,
		Delete:                sessions.Delete != nil,
		Auth:                  hasSupportedAuthMethod(initResp.AuthMethods),
		Logout:                capabilities.Auth != nil && capabilities.Auth.Logout != nil,
		PromptContent: provider.PromptContentCapabilities{
			Image:           boolValue(prompt.Image),
			Audio:           boolValue(prompt.Audio),
			EmbeddedContext: boolValue(prompt.EmbeddedContext),
		},
	}
}

func agentCapabilitiesValue(capabilities *schema.AgentCapabilities) schema.AgentCapabilities {
	if capabilities == nil {
		return schema.AgentCapabilities{}
	}
	return *capabilities
}

func boolValue(value *bool) bool {
	return value != nil && *value
}

// contentBlocks builds the ACP prompt content. Text and resource_link are
// always allowed (baseline ACP); image/audio/embedded blocks are gated on the
// agent's advertised prompt-content capabilities.
func contentBlocks(input provider.SendInput, caps provider.PromptContentCapabilities) ([]schema.ContentBlock, error) {
	blocks := make([]schema.ContentBlock, 0, len(input.Attachments)+1)
	if strings.TrimSpace(input.Text) != "" {
		blocks = append(blocks, schema.TextBlock(input.Text))
	}
	for _, attachment := range input.Attachments {
		var block schema.ContentBlock
		switch attachment.Kind {
		case provider.AttachmentImage:
			if !caps.Image {
				return nil, fmt.Errorf("ACP agent does not accept image content")
			}
			block = schema.ImageBlock(attachment.Data, attachment.MimeType)
			block.URI = stringPtr(attachment.URI)
		case provider.AttachmentAudio:
			if !caps.Audio {
				return nil, fmt.Errorf("ACP agent does not accept audio content")
			}
			block = schema.AudioBlock(attachment.Data, attachment.MimeType)
		case provider.AttachmentResource:
			if !caps.EmbeddedContext {
				return nil, fmt.Errorf("ACP agent does not accept embedded resource content")
			}
			if attachment.URI == "" {
				return nil, fmt.Errorf("ACP embedded resource requires a URI")
			}
			resource := &schema.EmbeddedResourceResource{URI: attachment.URI, MimeType: stringPtr(attachment.MimeType), Meta: cloneMetadata(attachment.ResourceMetadata)}
			if strings.HasPrefix(attachment.MimeType, "text/") || attachment.MimeType == "application/json" || attachment.MimeType == "" {
				resource.Text = stringPtr(attachment.Data)
			} else {
				resource.Blob = stringPtr(attachment.Data)
			}
			block = schema.ContentBlock{Type: schema.ContentBlockTypeResource, Resource: resource}
		case provider.AttachmentResourceLink:
			name := attachment.Name
			if name == "" {
				name = attachment.URI
			}
			block = schema.ResourceLinkBlock(name, attachment.URI)
			block.MimeType = stringPtr(attachment.MimeType)
			block.Title = stringPtr(attachment.Title)
			block.Description = stringPtr(attachment.Description)
			if attachment.Size != 0 {
				size := attachment.Size
				block.Size = &size
			}
		default:
			return nil, fmt.Errorf("unsupported attachment kind %q for ACP", attachment.Kind)
		}
		block.Annotations = annotationsToACP(attachment.Annotations)
		block.Meta = cloneMetadata(attachment.Metadata)
		blocks = append(blocks, block)
	}
	if len(blocks) == 0 {
		return []schema.ContentBlock{schema.TextBlock("")}, nil
	}
	return blocks, nil
}

func stringPtr(value string) *string {
	if value == "" {
		return nil
	}
	return &value
}

// permissionResponseFor answers with the option the user chose, or as
// cancelled when the request ended without one.
func permissionResponseFor(response approvalResponse) schema.RequestPermissionResponse {
	if response.action.ID == "" {
		return cancelledPermissionResponse()
	}
	return selectedPermissionResponse(schema.PermissionOptionId(response.action.ID))
}

func selectedPermissionResponse(optionID schema.PermissionOptionId) schema.RequestPermissionResponse {
	return schema.RequestPermissionResponse{Outcome: schema.RequestPermissionOutcome{Outcome: schema.RequestPermissionOutcomeOutcomeSelected, OptionID: &optionID}}
}

func cancelledPermissionResponse() schema.RequestPermissionResponse {
	return schema.RequestPermissionResponse{Outcome: schema.RequestPermissionOutcome{Outcome: schema.RequestPermissionOutcomeOutcomeCancelled}}
}

func permissionRequestFromACP(message string, options []schema.PermissionOption) provider.Request {
	request := provider.Request{Message: message, Actions: make([]provider.RequestAction, 0, len(options))}
	for _, option := range options {
		request.Actions = append(request.Actions, provider.RequestAction{ID: string(option.OptionID), Label: option.Name, Decision: permissionDecision(option.Kind)})
	}
	return request
}

func permissionDecision(kind schema.PermissionOptionKind) provider.ApprovalDecision {
	switch kind {
	case schema.PermissionOptionKindAllowAlways:
		return provider.ApprovalDecisionAcceptForSession
	case schema.PermissionOptionKindAllowOnce:
		return provider.ApprovalDecisionAccept
	case schema.PermissionOptionKindRejectAlways, schema.PermissionOptionKindRejectOnce:
		return provider.ApprovalDecisionDecline
	default:
		return provider.ApprovalDecisionCancel
	}
}

func stopReasonFromACP(reason schema.StopReason) provider.StopReason {
	switch reason {
	case schema.StopReasonMaxTokens:
		return provider.StopReasonMaxTokens
	case schema.StopReasonMaxTurnRequests:
		return provider.StopReasonMaxTurnRequests
	case schema.StopReasonRefusal:
		return provider.StopReasonRefusal
	default:
		return ""
	}
}

func attachmentsFromACPContent(update schema.SessionUpdate) []provider.Attachment {
	block, ok := update.ContentBlock()
	if !ok {
		return nil
	}
	attachment, ok := attachmentFromACPBlock(block)
	if !ok {
		return nil
	}
	return []provider.Attachment{attachment}
}

func attachmentFromACPBlock(block schema.ContentBlock) (provider.Attachment, bool) {
	attachment := provider.Attachment{
		Annotations: annotationsFromACP(block.Annotations),
		Metadata:    cloneMetadata(block.Meta),
	}
	if block.Title != nil {
		attachment.Title = *block.Title
	}
	if block.Description != nil {
		attachment.Description = *block.Description
	}
	if block.Size != nil {
		attachment.Size = *block.Size
	}
	if block.URI != nil {
		attachment.URI = *block.URI
	}
	switch block.Type {
	case schema.ContentBlockTypeImage, schema.ContentBlockTypeAudio:
		attachment.Kind = provider.AttachmentImage
		if block.Type == schema.ContentBlockTypeAudio {
			attachment.Kind = provider.AttachmentAudio
		}
		if block.Data != nil {
			attachment.Data = *block.Data
		}
		if block.MimeType != nil {
			attachment.MimeType = *block.MimeType
		}
	case schema.ContentBlockTypeResourceLink:
		attachment.Kind = provider.AttachmentResourceLink
		if block.Name != nil {
			attachment.Name = *block.Name
		}
		if block.MimeType != nil {
			attachment.MimeType = *block.MimeType
		}
	case schema.ContentBlockTypeResource:
		if block.Resource == nil {
			return provider.Attachment{}, false
		}
		attachment.Kind = provider.AttachmentResource
		attachment.URI = block.Resource.URI
		attachment.ResourceMetadata = cloneMetadata(block.Resource.Meta)
		if block.Resource.MimeType != nil {
			attachment.MimeType = *block.Resource.MimeType
		}
		if block.Resource.Text != nil {
			attachment.Data = *block.Resource.Text
		} else if block.Resource.Blob != nil {
			attachment.Data = *block.Resource.Blob
		}
	default:
		return provider.Attachment{}, false
	}
	return attachment, true
}

func annotationsFromACP(value *schema.Annotations) *provider.ContentAnnotations {
	if value == nil {
		return nil
	}
	audience := make([]string, 0, len(value.Audience))
	for _, role := range value.Audience {
		audience = append(audience, string(role))
	}
	annotations := &provider.ContentAnnotations{
		Audience: audience,
		Priority: value.Priority,
		Metadata: cloneMetadata(value.Meta),
	}
	if value.LastModified != nil {
		annotations.LastModified = *value.LastModified
	}
	return annotations
}

func annotationsToACP(value *provider.ContentAnnotations) *schema.Annotations {
	if value == nil {
		return nil
	}
	audience := make([]schema.Role, 0, len(value.Audience))
	for _, role := range value.Audience {
		audience = append(audience, schema.Role(role))
	}
	return &schema.Annotations{
		Audience:     audience,
		Priority:     value.Priority,
		LastModified: stringPtr(value.LastModified),
		Meta:         cloneMetadata(value.Metadata),
	}
}

func cloneMetadata(value map[string]any) map[string]any {
	if len(value) == 0 {
		return nil
	}
	cloned := make(map[string]any, len(value))
	for key, entry := range value {
		cloned[key] = entry
	}
	return cloned
}

func itemKindFromToolKind(kind string) provider.ItemKind {
	switch kind {
	case "edit", "patch", "file_change", "delete", "move":
		return provider.ItemKindFileChange
	case "terminal", "execute", "command", "shell":
		return provider.ItemKindCommandExecution
	case "mcp":
		return provider.ItemKindMCPToolCall
	case "":
		return ""
	default:
		return provider.ItemKindToolCall
	}
}

func itemStatusFromACP(status string) provider.ItemStatus {
	switch status {
	case "completed":
		return provider.ItemStatusCompleted
	case "failed", "error":
		return provider.ItemStatusFailed
	case "cancelled", "interrupted":
		return provider.ItemStatusInterrupted
	case "declined":
		return provider.ItemStatusDeclined
	case "":
		return ""
	default:
		return provider.ItemStatusInProgress
	}
}

// toolCallPatch captures one ACP-native sparse tool_call/tool_call_update
// with typed fields and doubles as the adapter-private accumulated snapshot
// in reconcileToolState. ACP updates use replacement semantics per field:
// nil means "absent, keep the prior value" while present-but-empty
// collections mean "clear this field", so slices stay nil-vs-empty
// distinguishable. Typed accumulation replaces the earlier JSON overlay,
// which re-encoded the whole accumulated blob — including complete file
// old/new text — on every sparse update.
type toolCallPatch struct {
	title     *string
	name      *string
	kind      *schema.ToolKind
	status    *schema.ToolCallStatus
	content   []schema.ToolCallContent
	locations []schema.ToolCallLocation
	// rawInput is retained only in the adapter-private snapshot so
	// command/query/cwd can be normalized. It is never copied into the public
	// ToolCall.
	rawInput any
	// rawOutput backfills ToolCall.Output when the agent sends no textual
	// content blocks — without client terminal support, command output often
	// arrives only here. Only bounded text is ever extracted from it.
	rawOutput any
	// terminalOutput accumulates codex-acp's `_meta.terminal_output_delta`
	// chunks (its output channel for clients without terminal support); a
	// patch carries just the new chunk, which overlay appends.
	terminalOutput string
	// exitCode comes from codex-acp's `_meta.terminal_exit`.
	exitCode *int
}

// toolCallPatchFromUpdate extracts the sparse patch a tool_call or
// tool_call_update carried; any other session update yields nil.
func toolCallPatchFromUpdate(u schema.SessionUpdate) *toolCallPatch {
	switch u.SessionUpdate {
	case schema.SessionUpdateToolCall, schema.SessionUpdateToolCallUpdate:
	default:
		return nil
	}
	output, exitCode := terminalMeta(u.Meta)
	return &toolCallPatch{
		title:          u.Title,
		name:           u.Name,
		terminalOutput: output,
		exitCode:       exitCode,
		kind:           u.Kind,
		status:         toolCallStatus(u.Status),
		content:        toolCallContentFromAny(u.Content),
		locations:      u.Locations,
		rawInput:       u.RawInput,
		rawOutput:      u.RawOutput,
	}
}

// toolCallContentFromAny converts the transport's generically decoded content
// collection into typed ACP content, preserving the present-but-empty versus
// absent distinction. One bounded re-encode of the patch's own content is the
// only conversion cost; accumulated state is never re-encoded.
func toolCallContentFromAny(value any) []schema.ToolCallContent {
	if value == nil {
		return nil
	}
	raw, err := json.Marshal(value)
	if err != nil {
		return nil
	}
	var content []schema.ToolCallContent
	if err := json.Unmarshal(raw, &content); err != nil {
		return nil
	}
	if content == nil {
		content = []schema.ToolCallContent{}
	}
	return content
}

// overlay lays a sparse patch over the accumulated snapshot. It is a shallow,
// ACP-shaped overlay — nested collections are whole ACP structures and are
// always replaced wholesale.
func (s *toolCallPatch) overlay(patch *toolCallPatch) *toolCallPatch {
	if s == nil {
		return patch
	}
	if patch == nil {
		return s
	}
	if patch.title != nil {
		s.title = patch.title
	}
	if patch.kind != nil {
		s.kind = patch.kind
	}
	if patch.status != nil {
		s.status = patch.status
	}
	if patch.content != nil {
		s.content = patch.content
	}
	if patch.locations != nil {
		s.locations = patch.locations
	}
	if patch.rawInput != nil {
		s.rawInput = patch.rawInput
	}
	if patch.rawOutput != nil {
		s.rawOutput = patch.rawOutput
	}
	if patch.name != nil {
		s.name = patch.name
	}
	if patch.exitCode != nil {
		s.exitCode = patch.exitCode
	}
	if room := toolOutputCharacterLimit - len(s.terminalOutput); room > 0 && patch.terminalOutput != "" {
		s.terminalOutput += provider.TruncateUTF8(patch.terminalOutput, room)
	}
	return s
}

// terminalMeta reads codex-acp's command output conventions from a tool
// update's `_meta`: `terminal_output_delta: {data}` chunks and
// `terminal_exit: {exit_code}`. They are not part of the ACP spec, but they
// are the only place codex-acp reports output to a client that, like maiD,
// does not advertise terminals.
func terminalMeta(meta map[string]any) (string, *int) {
	var output string
	if delta, ok := meta["terminal_output_delta"].(map[string]any); ok {
		output, _ = delta["data"].(string)
	}
	var exitCode *int
	if exit, ok := meta["terminal_exit"].(map[string]any); ok {
		if code, ok := exit["exit_code"].(float64); ok {
			value := int(code)
			exitCode = &value
		}
	}
	return output, exitCode
}

// toolCall converts the accumulated adapter-private snapshot into the public
// neutral snapshot. It runs only after sparse ACP updates have been overlaid
// by reconcileToolState.
func (s *toolCallPatch) toolCall() *provider.ToolCall {
	if s == nil {
		return nil
	}
	providerKind := strings.ToLower(strings.TrimSpace(toolKindString(s.kind)))
	call := &provider.ToolCall{
		Action:       toolActionFromACP(providerKind),
		Name:         stringValue(s.name),
		ProviderKind: providerKind,
		ExitCode:     s.exitCode,
		Locations:    toolLocationsFromACP(s.locations),
		Changes:      toolChangesFromACP(s.content, providerKind),
		Attachments:  toolAttachmentsFromACP(s.content),
		Output:       toolTextFromACP(s.content),
	}
	if call.Output != "" {
		// ACP text content is Markdown; terminal and raw output are not.
		call.OutputFormat = provider.OutputFormatMarkdown
	}
	if call.Output == "" {
		call.Output = s.terminalOutput
	}
	if call.Output == "" {
		call.Output = rawOutputText(s.rawOutput)
	}
	call.Output = provider.TruncateUTF8(call.Output, toolOutputCharacterLimit)
	call.Command, call.Query, call.Cwd = toolInputDetails(s.rawInput)
	return call
}

// toolOutputCharacterLimit bounds retained tool output regardless of whether
// it arrived as content blocks or a raw provider blob. Generous enough for
// real command output, small enough that per-item snapshots stay cheap to
// re-emit on every sparse update.
const toolOutputCharacterLimit = 16_384

func rawOutputText(raw any) string {
	switch value := raw.(type) {
	case string:
		return value
	case map[string]any:
		if text, ok := value["output"].(string); ok && text != "" {
			return text
		}
		stdout, _ := value["stdout"].(string)
		stderr, _ := value["stderr"].(string)
		if stdout != "" || stderr != "" {
			switch {
			case stdout == "":
				return stderr
			case stderr == "":
				return stdout
			case strings.HasSuffix(stdout, "\n"):
				return stdout + stderr
			default:
				return stdout + "\n" + stderr
			}
		}
		for _, key := range []string{"text", "content"} {
			if text, ok := value[key].(string); ok && text != "" {
				return text
			}
		}
	}
	return ""
}

// toolActionFromACP keeps only the actions ACP's tool kind states; every
// other kind leaves the action empty.
func toolActionFromACP(kind string) provider.ToolAction {
	switch kind {
	case "read":
		return provider.ToolActionRead
	case "search":
		return provider.ToolActionSearch
	default:
		return ""
	}
}

func toolLocationsFromACP(locations []schema.ToolCallLocation) []provider.ToolLocation {
	if locations == nil {
		return nil
	}
	converted := make([]provider.ToolLocation, 0, len(locations))
	for _, location := range locations {
		converted = append(converted, provider.ToolLocation{
			Path: location.Path,
			Line: location.Line,
		})
	}
	return converted
}

func toolAttachmentsFromACP(content []schema.ToolCallContent) []provider.Attachment {
	if content == nil {
		return nil
	}
	attachments := make([]provider.Attachment, 0)
	for _, entry := range content {
		if entry.Type != schema.ToolCallContentTypeContent || entry.Content == nil {
			continue
		}
		if attachment, ok := attachmentFromACPBlock(*entry.Content); ok {
			attachments = append(attachments, attachment)
		}
	}
	return attachments
}

func toolTextFromACP(content []schema.ToolCallContent) string {
	var parts []string
	for _, entry := range content {
		if entry.Type == schema.ToolCallContentTypeContent && entry.Content != nil &&
			entry.Content.Type == schema.ContentBlockTypeText && entry.Content.Text != nil {
			parts = append(parts, *entry.Content.Text)
		}
	}
	return strings.Join(parts, "\n")
}

func toolChangesFromACP(content []schema.ToolCallContent, kind string) []provider.FileChange {
	if content == nil {
		return nil
	}
	changes := make([]provider.FileChange, 0)
	for _, entry := range content {
		if entry.Type != schema.ToolCallContentTypeDiff {
			continue
		}
		change := provider.FileChange{Kind: fileChangeKindFromACP(kind)}
		if entry.Path != nil {
			change.Path = *entry.Path
		}
		if entry.OldText != nil {
			change.OldText = *entry.OldText
		}
		if entry.NewText != nil {
			change.NewText = *entry.NewText
		}
		changes = append(changes, change)
	}
	return changes
}

func fileChangeKindFromACP(kind string) provider.FileChangeKind {
	switch kind {
	case "delete":
		return provider.FileChangeDelete
	case "move":
		return provider.FileChangeMove
	default:
		return provider.FileChangeUpdate
	}
}

func toolInputDetails(raw any) (command, query, cwd string) {
	input, ok := raw.(map[string]any)
	if !ok {
		return "", "", ""
	}
	command = commandValue(input["command"])
	if command == "" {
		command = commandValue(input["cmd"])
	}
	if command == "" {
		executable, _ := input["executable"].(string)
		command = strings.TrimSpace(strings.TrimSpace(executable) + " " + commandValue(input["args"]))
	}
	queryInput, _ := input["query"].(string)
	query = strings.TrimSpace(queryInput)
	if query == "" {
		pattern, _ := input["pattern"].(string)
		query = strings.TrimSpace(pattern)
	}
	cwdInput, _ := input["cwd"].(string)
	return command, query, strings.TrimSpace(cwdInput)
}

func commandValue(value any) string {
	switch typed := value.(type) {
	case string:
		return strings.TrimSpace(typed)
	case []any:
		parts := make([]string, 0, len(typed))
		for _, part := range typed {
			if text, ok := part.(string); ok && strings.TrimSpace(text) != "" {
				parts = append(parts, strings.TrimSpace(text))
			}
		}
		return strings.Join(parts, " ")
	default:
		return ""
	}
}

func toolCallTitle(tool schema.ToolCallUpdate) string {
	if tool.Title != nil {
		return *tool.Title
	}
	return string(tool.ToolCallID)
}

func toolKindString(kind *schema.ToolKind) string {
	if kind == nil {
		return ""
	}
	return strings.ToLower(string(*kind))
}

// toolCallStatus types a session update's status, which the schema shares
// between tool calls and compactions.
func toolCallStatus(status *string) *schema.ToolCallStatus {
	if status == nil {
		return nil
	}
	typed := schema.ToolCallStatus(*status)
	return &typed
}

func toolStatusString(status *schema.ToolCallStatus) string {
	if status == nil {
		return ""
	}
	return string(*status)
}

func toolCallIDValue(id *schema.ToolCallId) string {
	if id == nil {
		return ""
	}
	return string(*id)
}

func stringValue(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

func acpRequestError(err error) error {
	if err == nil {
		return nil
	}
	if wireErr, ok := errors.AsType[*jsonrpc2.WireError](err); ok {
		return &provider.RequestError{Code: int(wireErr.Code), Message: wireErr.Message, Data: wireErr.Data}
	}
	return err
}

// configOptionsFromACP maps ACP session config options into the generic
// provider vocabulary. Malformed and unsupported descriptors are skipped.
func configOptionsFromACP(options []schema.SessionConfigOption) []provider.ConfigOption {
	if options == nil {
		return nil
	}
	converted := make([]provider.ConfigOption, 0, len(options))
	for _, option := range options {
		convertedOption := provider.ConfigOption{
			ID:          string(option.ID),
			Type:        provider.ConfigOptionType(option.Type),
			Category:    configOptionCategory(option.Category),
			Label:       option.Name,
			Description: stringValue(option.Description),
		}
		switch option.Type {
		case schema.SessionConfigOptionTypeSelect:
			current, ok := configStringValue(option.CurrentValue)
			if !ok {
				continue
			}
			convertedOption.CurrentValue = current
			convertedOption.Choices = configChoices(option.Options)
		case schema.SessionConfigOptionTypeBoolean:
			current, ok := option.CurrentValue.(bool)
			if !ok {
				continue
			}
			convertedOption.CurrentValue = current
		default:
			continue
		}
		converted = append(converted, convertedOption)
	}
	if len(converted) == 0 {
		return []provider.ConfigOption{}
	}
	return converted
}

func slashCommandsFromACP(commands []schema.AvailableCommand) []provider.SlashCommand {
	converted := make([]provider.SlashCommand, 0, len(commands))
	for _, command := range commands {
		convertedCommand := provider.SlashCommand{Name: command.Name, Description: command.Description, HasInput: command.Input != nil}
		if command.Input != nil {
			convertedCommand.InputHint = command.Input.Hint
		}
		converted = append(converted, convertedCommand)
	}
	return converted
}

func tokenUsageFromACP(u schema.SessionUpdate) *provider.TokenUsage {
	usage := &provider.TokenUsage{UsedTokens: int(uint64Value(u.Used)), MaxTokens: int(uint64Value(u.Size))}
	if u.Cost != nil {
		usage.Cost = u.Cost.Amount
		usage.Currency = u.Cost.Currency
	}
	return usage
}

func uint64Value(value *uint64) uint64 {
	if value == nil {
		return 0
	}
	return *value
}

// isAgentAuthMethod reports whether the method is the agent-handled variant
// (type absent or empty), which runs through `authenticate`.
func isAgentAuthMethod(method schema.AuthMethod) bool {
	return method.Type == nil || *method.Type == ""
}

// isSupportedAuthMethod reports whether maiD can run the method: agent-handled
// ones, or terminal ones run in a maiD terminal.
func isSupportedAuthMethod(method schema.AuthMethod) bool {
	return method.ID != "" && (isAgentAuthMethod(method) || stringValue(method.Type) == schema.AuthMethodTypeTerminal)
}

func hasSupportedAuthMethod(methods []schema.AuthMethod) bool {
	return slices.ContainsFunc(methods, isSupportedAuthMethod)
}

func authMethodsFromACP(methods []schema.AuthMethod) []provider.AuthMethod {
	converted := make([]provider.AuthMethod, 0, len(methods))
	for _, method := range methods {
		if !isSupportedAuthMethod(method) {
			continue
		}
		am := provider.AuthMethod{ID: string(method.ID), Name: method.Name}
		if !isAgentAuthMethod(method) {
			am.Kind = provider.AuthKindTerminal
		}
		if method.Description != nil {
			am.Description = *method.Description
		}
		converted = append(converted, am)
	}
	if len(converted) == 0 {
		return nil
	}
	return converted
}

func sessionSummariesFromACP(sessions []schema.SessionInfo) []provider.SessionSummary {
	converted := make([]provider.SessionSummary, 0, len(sessions))
	for _, session := range sessions {
		converted = append(converted, provider.SessionSummary{
			SessionID:             string(session.SessionID),
			Title:                 stringValue(session.Title),
			Cwd:                   session.CWD,
			AdditionalDirectories: append([]string(nil), session.AdditionalDirectories...),
			UpdatedAt:             stringValue(session.UpdatedAt),
		})
	}
	return converted
}

func planEntriesFromACP(entries []schema.PlanEntry) []provider.PlanEntry {
	if len(entries) == 0 {
		return nil
	}
	converted := make([]provider.PlanEntry, 0, len(entries))
	for _, entry := range entries {
		converted = append(converted, provider.PlanEntry{Content: entry.Content, Priority: provider.PlanEntryPriority(entry.Priority), Status: provider.PlanEntryStatus(entry.Status)})
	}
	return converted
}

func configOptionCategory(category *schema.SessionConfigOptionCategory) provider.ConfigOptionCategory {
	if category == nil {
		return provider.ConfigOptionCategoryOther
	}
	switch *category {
	case schema.SessionConfigOptionCategoryModel:
		return provider.ConfigOptionCategoryModel
	case schema.SessionConfigOptionCategoryMode:
		return provider.ConfigOptionCategoryMode
	case schema.SessionConfigOptionCategoryModelConfig:
		return provider.ConfigOptionCategoryModelConfig
	case schema.SessionConfigOptionCategoryThoughtLevel:
		return provider.ConfigOptionCategoryThoughtLevel
	default:
		return provider.ConfigOptionCategoryOther
	}
}

// configChoices decodes the schema's untyped select options: either a flat
// []SessionConfigSelectOption or grouped []SessionConfigSelectGroup.
func configChoices(options schema.SessionConfigSelectOptions) []provider.ConfigChoice {
	raw := marshalRaw(options)
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	var grouped []schema.SessionConfigSelectGroup
	if err := json.Unmarshal(raw, &grouped); err == nil && hasGroupedOptions(grouped) {
		var choices []provider.ConfigChoice
		for _, group := range grouped {
			choices = append(choices, configChoicesFromOptions(group.Options, string(group.Group), group.Name)...)
		}
		return choices
	}
	var ungrouped []schema.SessionConfigSelectOption
	if err := json.Unmarshal(raw, &ungrouped); err != nil {
		return nil
	}
	return configChoicesFromOptions(ungrouped, "", "")
}

func hasGroupedOptions(groups []schema.SessionConfigSelectGroup) bool {
	for _, group := range groups {
		if len(group.Options) > 0 || group.Group != "" {
			return true
		}
	}
	return false
}

func configChoicesFromOptions(options []schema.SessionConfigSelectOption, group, groupLabel string) []provider.ConfigChoice {
	if len(options) == 0 {
		return nil
	}
	choices := make([]provider.ConfigChoice, 0, len(options))
	for _, option := range options {
		description := ""
		if option.Description != nil {
			description = *option.Description
		}
		choices = append(choices, provider.ConfigChoice{Value: string(option.Value), Label: option.Name, Description: description, Group: group, GroupLabel: groupLabel})
	}
	return choices
}

func configStringValue(value any) (string, bool) {
	switch v := value.(type) {
	case nil:
		// An agent may omit currentValue entirely; keep the option with no
		// selection instead of hiding the whole control.
		return "", true
	case string:
		return v, true
	case schema.SessionConfigValueId:
		return string(v), true
	default:
		return "", false
	}
}

func marshalRaw(value any) json.RawMessage {
	raw, _ := json.Marshal(value)
	return raw
}
