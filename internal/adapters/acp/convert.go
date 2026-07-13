package acp

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

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
	// the methods as actions and open the auth flow only when an
	// operation fails with auth_required, never off this status.
	status := provider.AuthStatusAuthenticated
	if len(initResp.AuthMethods) > 0 {
		status = provider.AuthStatusUnknown
	}
	return provider.Auth{Status: status, Methods: methods}
}

func capabilitySet(initResp schema.InitializeResponse) provider.Capabilities {
	capabilities := agentCapabilitiesValue(initResp.AgentCapabilities)
	prompt := schema.PromptCapabilities{}
	if capabilities.PromptCapabilities != nil {
		prompt = *capabilities.PromptCapabilities
	}
	mcp := schema.McpCapabilities{}
	if capabilities.MCPCapabilities != nil {
		mcp = *capabilities.MCPCapabilities
	}
	return provider.Capabilities{
		Resume: boolValue(capabilities.LoadSession) || sessionResumeSupported(capabilities),
		Auth:   hasStableAuthMethod(initResp.AuthMethods),
		Logout: capabilities.Auth != nil && capabilities.Auth.Logout != nil,
		PromptContent: provider.PromptContentCapabilities{
			Image:           boolValue(prompt.Image),
			Audio:           boolValue(prompt.Audio),
			EmbeddedContext: boolValue(prompt.EmbeddedContext),
		},
		// ACP exposes in-session model/config switching via session/set_config_option
		// (the actual model/mode lists, if any, arrive per session as ConfigOptions).
		ModelSwitch:     provider.ModelSwitchInSession,
		InteractionMode: true,
		MCP: provider.MCPCapabilities{
			HTTP: boolValue(mcp.HTTP),
			SSE:  boolValue(mcp.SSE),
		},
	}
}

func agentCapabilitiesValue(capabilities *schema.AgentCapabilities) schema.AgentCapabilities {
	if capabilities == nil {
		return schema.AgentCapabilities{}
	}
	return *capabilities
}

func sessionResumeSupported(capabilities schema.AgentCapabilities) bool {
	return capabilities.SessionCapabilities != nil && capabilities.SessionCapabilities.Resume != nil
}

func boolValue(value *bool) bool {
	return value != nil && *value
}

func metadataFromInitialize(initResp schema.InitializeResponse, rawInit json.RawMessage) map[string]json.RawMessage {
	metadata := map[string]json.RawMessage{
		"agentCapabilities": marshalRaw(agentCapabilitiesValue(initResp.AgentCapabilities)),
		"authMethods":       marshalRaw(initResp.AuthMethods),
	}
	if initResp.AgentInfo != nil {
		metadata["agentInfo"] = marshalRaw(initResp.AgentInfo)
	}
	if len(rawInit) > 0 {
		metadata["rawInitialize"] = append(json.RawMessage(nil), rawInit...)
	}
	return metadata
}

// contentBlocks builds the ACP prompt content. Text and resource_link are
// always allowed (baseline ACP); image/audio/embedded blocks are gated on the
// agent's advertised prompt-content capabilities.
func contentBlocks(input provider.SendTurnInput, caps provider.PromptContentCapabilities) ([]schema.ContentBlock, error) {
	blocks := make([]schema.ContentBlock, 0, len(input.Attachments)+1)
	if strings.TrimSpace(input.Input) != "" {
		blocks = append(blocks, schema.TextBlock(input.Input))
	}
	for i, attachment := range input.Attachments {
		if len(attachment.Raw) > 0 {
			return nil, fmt.Errorf("unsupported raw ACP attachment at index %d; use a generic attachment kind", i)
		}
		switch attachment.Kind {
		case "", "text":
			blocks = append(blocks, schema.TextBlock(attachment.Data))
		case "image":
			if !caps.Image {
				return nil, fmt.Errorf("ACP agent does not accept image content")
			}
			blocks = append(blocks, schema.ImageBlock(attachment.Data, attachment.MimeType))
		case "audio":
			if !caps.Audio {
				return nil, fmt.Errorf("ACP agent does not accept audio content")
			}
			blocks = append(blocks, schema.AudioBlock(attachment.Data, attachment.MimeType))
		case "resource", "embedded_context", "embeddedContext":
			if !caps.EmbeddedContext {
				return nil, fmt.Errorf("ACP agent does not accept embedded resource content")
			}
			if attachment.URI == "" {
				return nil, fmt.Errorf("ACP embedded resource requires a URI")
			}
			resource := &schema.EmbeddedResourceResource{URI: attachment.URI, MimeType: stringPtr(attachment.MimeType)}
			if strings.HasPrefix(attachment.MimeType, "text/") || attachment.MimeType == "application/json" || attachment.MimeType == "" {
				resource.Text = stringPtr(attachment.Data)
			} else {
				resource.Blob = stringPtr(attachment.Data)
			}
			blocks = append(blocks, schema.ContentBlock{Type: schema.ContentBlockTypeResource, Resource: resource})
		case "resource_link", "resourceLink":
			name := attachment.Name
			if name == "" {
				name = attachment.URI
			}
			block := schema.ResourceLinkBlock(name, attachment.URI)
			block.MimeType = stringPtr(attachment.MimeType)
			blocks = append(blocks, block)
		default:
			return nil, fmt.Errorf("unsupported generic attachment kind %q for ACP", attachment.Kind)
		}
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

func automaticPermissionResponse(req schema.RequestPermissionRequest, policy provider.ApprovalPolicy) (schema.RequestPermissionResponse, bool) {
	switch policy {
	case provider.ApprovalPolicyAllow:
		return allowPermissionResponse(req.Options), true
	case provider.ApprovalPolicyAllowEdits:
		if isConfidentEditPermission(req.ToolCall) {
			return allowOncePermissionResponse(req.Options)
		}
		return schema.RequestPermissionResponse{}, false
	case provider.ApprovalPolicyAsk:
		return schema.RequestPermissionResponse{}, false
	default:
		return rejectPermissionResponse(req.Options), true
	}
}

func allowPermissionResponse(options []schema.PermissionOption) schema.RequestPermissionResponse {
	if option, ok := choosePermissionOption(options, []schema.PermissionOptionKind{schema.PermissionOptionKindAllowAlways, schema.PermissionOptionKindAllowOnce}); ok {
		return selectedPermissionResponse(option.OptionID)
	}
	return cancelledPermissionResponse()
}

func allowOncePermissionResponse(options []schema.PermissionOption) (schema.RequestPermissionResponse, bool) {
	if option, ok := choosePermissionOption(options, []schema.PermissionOptionKind{schema.PermissionOptionKindAllowOnce}); ok {
		return selectedPermissionResponse(option.OptionID), true
	}
	return schema.RequestPermissionResponse{}, false
}

func rejectPermissionResponse(options []schema.PermissionOption) schema.RequestPermissionResponse {
	if option, ok := choosePermissionOption(options, []schema.PermissionOptionKind{schema.PermissionOptionKindRejectOnce, schema.PermissionOptionKindRejectAlways}); ok {
		return selectedPermissionResponse(option.OptionID)
	}
	return cancelledPermissionResponse()
}

func permissionResponseForDecision(options []schema.PermissionOption, decision provider.ApprovalDecision) schema.RequestPermissionResponse {
	var preferred []schema.PermissionOptionKind
	switch decision {
	case provider.ApprovalDecisionAccept:
		preferred = []schema.PermissionOptionKind{schema.PermissionOptionKindAllowOnce, schema.PermissionOptionKindAllowAlways}
	case provider.ApprovalDecisionAcceptForSession:
		preferred = []schema.PermissionOptionKind{schema.PermissionOptionKindAllowAlways, schema.PermissionOptionKindAllowOnce}
	case provider.ApprovalDecisionDecline:
		preferred = []schema.PermissionOptionKind{schema.PermissionOptionKindRejectOnce, schema.PermissionOptionKindRejectAlways}
	default:
		return cancelledPermissionResponse()
	}
	if option, ok := choosePermissionOption(options, preferred); ok {
		return selectedPermissionResponse(option.OptionID)
	}
	return cancelledPermissionResponse()
}

// permissionResponseForApproval answers with the client's exact option
// selection when one was made (RespondToRequest already validated it against
// the offered options); otherwise it maps the coarse decision onto the
// agent's options by kind.
func permissionResponseForApproval(options []schema.PermissionOption, response approvalResponse) schema.RequestPermissionResponse {
	if response.optionID != "" {
		return selectedPermissionResponse(schema.PermissionOptionId(response.optionID))
	}
	return permissionResponseForDecision(options, response.decision)
}

func hasPermissionOption(options []schema.PermissionOption, optionID string) bool {
	for _, option := range options {
		if string(option.OptionID) == optionID {
			return true
		}
	}
	return false
}

func choosePermissionOption(options []schema.PermissionOption, preferred []schema.PermissionOptionKind) (schema.PermissionOption, bool) {
	for _, kind := range preferred {
		for _, option := range options {
			if option.Kind == kind {
				return option, true
			}
		}
	}
	return schema.PermissionOption{}, false
}

func selectedPermissionResponse(optionID schema.PermissionOptionId) schema.RequestPermissionResponse {
	return schema.RequestPermissionResponse{Outcome: schema.RequestPermissionOutcome{Outcome: schema.RequestPermissionOutcomeOutcomeSelected, OptionID: &optionID}}
}

func cancelledPermissionResponse() schema.RequestPermissionResponse {
	return schema.RequestPermissionResponse{Outcome: schema.RequestPermissionOutcome{Outcome: schema.RequestPermissionOutcomeOutcomeCancelled}}
}

func selectedPermissionOptionID(resp schema.RequestPermissionResponse) (schema.PermissionOptionId, bool) {
	if resp.Outcome.Outcome != schema.RequestPermissionOutcomeOutcomeSelected || resp.Outcome.OptionID == nil {
		return "", false
	}
	return *resp.Outcome.OptionID, true
}

func permissionOptionsFromACP(options []schema.PermissionOption) []provider.ApprovalOption {
	converted := make([]provider.ApprovalOption, 0, len(options))
	for _, option := range options {
		converted = append(converted, provider.ApprovalOption{ID: string(option.OptionID), Name: option.Name, Kind: string(option.Kind), Raw: marshalRaw(option)})
	}
	return converted
}

func permissionRequestID(threadID string, toolCallID string) string {
	base := threadID
	if base == "" {
		base = "unknown"
	}
	if toolCallID == "" {
		return "permission:" + base
	}
	return "permission:" + base + ":" + toolCallID
}

func permissionDecisionFromResponse(options []schema.PermissionOption, resp schema.RequestPermissionResponse) (provider.ApprovalDecision, string) {
	optionID, ok := selectedPermissionOptionID(resp)
	if !ok {
		return provider.ApprovalDecisionCancel, ""
	}
	for _, option := range options {
		if option.OptionID != optionID {
			continue
		}
		switch option.Kind {
		case schema.PermissionOptionKindAllowAlways:
			return provider.ApprovalDecisionAcceptForSession, string(optionID)
		case schema.PermissionOptionKindAllowOnce:
			return provider.ApprovalDecisionAccept, string(optionID)
		case schema.PermissionOptionKindRejectAlways, schema.PermissionOptionKindRejectOnce:
			return provider.ApprovalDecisionDecline, string(optionID)
		}
	}
	return provider.ApprovalDecisionCancel, ""
}

func sessionRuntimeEvent(notification schema.SessionNotification) provider.RuntimeEvent {
	update := provider.RuntimeEvent{
		EventID:   provider.RuntimeEventID(newID()),
		Provider:  DriverKind,
		CreatedAt: time.Now(),
	}
	u := notification.Update
	switch u.SessionUpdate {
	case schema.SessionUpdateUserMessageChunk:
		update.Type = provider.RuntimeEventItemCompleted
		update.ItemID = messageID(u.MessageID)
		text, _ := u.TextChunk()
		update.Payload = provider.RuntimeEventPayload{ItemType: provider.ItemKindUserMessage, ItemStatus: provider.ItemStatusCompleted, Detail: text, Attachments: attachmentsFromACPContent(u), Data: marshalRaw(u.Content)}
	case schema.SessionUpdateAgentMessageChunk:
		update.Type = provider.RuntimeEventContentDelta
		update.ItemID = messageID(u.MessageID)
		text, _ := u.TextChunk()
		update.Payload = provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: text, Attachments: attachmentsFromACPContent(u), Data: marshalRaw(u.Content)}
	case schema.SessionUpdateAgentThoughtChunk:
		update.Type = provider.RuntimeEventContentDelta
		update.ItemID = messageID(u.MessageID)
		text, _ := u.TextChunk()
		update.Payload = provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentReasoningText, Delta: text, Attachments: attachmentsFromACPContent(u), Data: marshalRaw(u.Content)}
	case schema.SessionUpdateToolCall:
		update.Type = provider.RuntimeEventItemStarted
		update.ItemID = toolCallIDValue(u.ToolCallID)
		update.Payload = provider.RuntimeEventPayload{ItemType: itemKindFromToolKind(toolKindString(u.Kind)), ItemStatus: itemStatusFromACP(toolStatusString(u.Status)), Title: stringValue(u.Title), Data: toolCallData(u)}
	case schema.SessionUpdateToolCallUpdate:
		update.Type = provider.RuntimeEventItemUpdated
		update.ItemID = toolCallIDValue(u.ToolCallID)
		update.Payload = provider.RuntimeEventPayload{ItemType: itemKindFromToolKind(toolKindString(u.Kind)), ItemStatus: itemStatusFromACP(toolStatusString(u.Status)), Title: stringValue(u.Title), Data: toolCallData(u)}
	case schema.SessionUpdatePlan:
		update.Type = provider.RuntimeEventTurnPlanUpdated
		update.Payload = provider.RuntimeEventPayload{PlanEntries: planEntriesFromACP(u.Entries), Data: marshalRaw(schema.Plan{Entries: u.Entries})}
	case schema.SessionUpdateAvailableCommandsUpdate:
		update.Type = provider.RuntimeEventThreadMetadataUpdate
		update.Payload = provider.RuntimeEventPayload{SlashCommands: slashCommandsFromACP(u.AvailableCommands), Data: marshalRaw(schema.AvailableCommandsUpdate{AvailableCommands: u.AvailableCommands})}
	case schema.SessionUpdateSessionInfoUpdate:
		update.Type = provider.RuntimeEventThreadMetadataUpdate
		update.Payload = provider.RuntimeEventPayload{Title: stringValue(u.Title), Data: marshalRaw(schema.SessionInfoUpdate{Title: u.Title, UpdatedAt: u.UpdatedAt})}
	case schema.SessionUpdateUsageUpdate:
		update.Type = provider.RuntimeEventThreadTokenUsage
		update.Payload = provider.RuntimeEventPayload{TokenUsage: tokenUsageFromACP(u), Data: marshalRaw(usageUpdateFromACP(u))}
	default:
		update.Type = provider.RuntimeEventRuntimeWarning
		update.Payload = provider.RuntimeEventPayload{Message: "Unknown ACP session update", Data: marshalRaw(notification.Update)}
	}
	return update
}

func attachmentsFromACPContent(update schema.SessionUpdate) []provider.Attachment {
	block, ok := update.ContentBlock()
	if !ok {
		return nil
	}
	attachment := provider.Attachment{}
	switch block.Type {
	case schema.ContentBlockTypeImage, schema.ContentBlockTypeAudio:
		attachment.Kind = block.Type
		if block.Data != nil {
			attachment.Data = *block.Data
		}
		if block.MimeType != nil {
			attachment.MimeType = *block.MimeType
		}
	case schema.ContentBlockTypeResourceLink:
		attachment.Kind = "resource_link"
		if block.Name != nil {
			attachment.Name = *block.Name
		}
		if block.URI != nil {
			attachment.URI = *block.URI
		}
		if block.MimeType != nil {
			attachment.MimeType = *block.MimeType
		}
	case schema.ContentBlockTypeResource:
		if block.Resource == nil {
			return nil
		}
		attachment.Kind = "resource"
		attachment.URI = block.Resource.URI
		if block.Resource.MimeType != nil {
			attachment.MimeType = *block.Resource.MimeType
		}
		if block.Resource.Text != nil {
			attachment.Data = *block.Resource.Text
		} else if block.Resource.Blob != nil {
			attachment.Data = *block.Resource.Blob
		}
	default:
		return nil
	}
	return []provider.Attachment{attachment}
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

// toolCallData projects the tool-call fields of a session update into the raw
// item payload. ACP tool_call_update uses replacement semantics for content and
// locations: present-but-empty collections mean "clear this field" and must
// stay distinguishable from absent ones, so fields are only included when the
// update carried them.
func toolCallData(u schema.SessionUpdate) json.RawMessage {
	object := map[string]any{"toolCallId": u.ToolCallID}
	if u.Title != nil {
		object["title"] = *u.Title
	}
	if u.Kind != nil {
		object["kind"] = *u.Kind
	}
	if u.Status != nil {
		object["status"] = *u.Status
	}
	if u.Content != nil {
		object["content"] = u.Content
	}
	if u.Locations != nil {
		object["locations"] = u.Locations
	}
	if u.RawInput != nil {
		object["rawInput"] = u.RawInput
	}
	if u.RawOutput != nil {
		object["rawOutput"] = u.RawOutput
	}
	return marshalRaw(object)
}

func toolCallTitle(tool schema.ToolCallUpdate) string {
	if tool.Title != nil {
		return *tool.Title
	}
	return string(tool.ToolCallID)
}

func permissionRequestType(tool schema.ToolCallUpdate) provider.RuntimeRequestType {
	kind := toolKindString(tool.Kind)
	if hasTerminalContent(tool.Content) || kind == "execute" || kind == "terminal" || kind == "command" || kind == "shell" {
		return provider.RuntimeRequestCommandExecution
	}
	if kind == "read" {
		return provider.RuntimeRequestFileRead
	}
	if hasDiffContent(tool.Content) || kind == "edit" || kind == "patch" || kind == "file_change" || kind == "delete" || kind == "move" {
		return provider.RuntimeRequestFileChange
	}
	return provider.RuntimeRequestDynamicToolCall
}

func isConfidentEditPermission(tool schema.ToolCallUpdate) bool {
	if hasTerminalContent(tool.Content) {
		return false
	}
	kind := toolKindString(tool.Kind)
	switch kind {
	case "edit", "patch", "file_change":
		return true
	case "delete", "move", "execute", "terminal", "command", "shell", "read", "search", "fetch", "switch_mode", "think", "other":
		return false
	}
	return kind == "" && hasDiffContent(tool.Content)
}

func toolKindString(kind *schema.ToolKind) string {
	if kind == nil {
		return ""
	}
	return strings.ToLower(string(*kind))
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

func hasDiffContent(content []schema.ToolCallContent) bool {
	for _, block := range content {
		if block.Type == schema.ToolCallContentTypeDiff {
			return true
		}
	}
	return false
}

func hasTerminalContent(content []schema.ToolCallContent) bool {
	for _, block := range content {
		if block.Type == schema.ToolCallContentTypeTerminal {
			return true
		}
	}
	return false
}

func stringValue(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

func messageID(id *schema.MessageId) string {
	if id == nil {
		return ""
	}
	return string(*id)
}

func acpRequestError(err error) error {
	if err == nil {
		return nil
	}
	var wireErr *jsonrpc2.WireError
	if errors.As(err, &wireErr) {
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
		converted = append(converted, provider.SlashCommand{Name: command.Name, Description: command.Description, HasInput: command.Input != nil})
	}
	return converted
}

func usageUpdateFromACP(u schema.SessionUpdate) schema.UsageUpdate {
	return schema.UsageUpdate{Used: uint64Value(u.Used), Size: uint64Value(u.Size), Cost: u.Cost}
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

// isStableAuthMethod reports whether the advertised method is the stable
// agent-handled variant. The type field discriminates: absent (or empty) means
// agent; env_var/terminal are unstable client-driven methods maiD skips.
func isStableAuthMethod(method schema.AuthMethod) bool {
	return method.Type == nil || *method.Type == ""
}

func hasStableAuthMethod(methods []schema.AuthMethod) bool {
	for _, method := range methods {
		if isStableAuthMethod(method) && method.ID != "" {
			return true
		}
	}
	return false
}

func authMethodID(method schema.AuthMethod) string {
	if !isStableAuthMethod(method) {
		return ""
	}
	return string(method.ID)
}

func authMethodsFromACP(methods []schema.AuthMethod) []provider.AuthMethod {
	converted := make([]provider.AuthMethod, 0, len(methods))
	for _, method := range methods {
		if !isStableAuthMethod(method) {
			continue // skip unstable env/terminal auth methods
		}
		am := provider.AuthMethod{ID: string(method.ID), Name: method.Name}
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
			SessionID: string(session.SessionID),
			Title:     stringValue(session.Title),
			Cwd:       session.CWD,
			UpdatedAt: stringValue(session.UpdatedAt),
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
		var flattened []schema.SessionConfigSelectOption
		for _, group := range grouped {
			flattened = append(flattened, group.Options...)
		}
		return configChoicesFromOptions(flattened)
	}
	var ungrouped []schema.SessionConfigSelectOption
	if err := json.Unmarshal(raw, &ungrouped); err != nil {
		return nil
	}
	return configChoicesFromOptions(ungrouped)
}

func hasGroupedOptions(groups []schema.SessionConfigSelectGroup) bool {
	for _, group := range groups {
		if len(group.Options) > 0 || group.Group != "" {
			return true
		}
	}
	return false
}

func configChoicesFromOptions(options []schema.SessionConfigSelectOption) []provider.ConfigChoice {
	if len(options) == 0 {
		return nil
	}
	choices := make([]provider.ConfigChoice, 0, len(options))
	for _, option := range options {
		choices = append(choices, provider.ConfigChoice{Value: string(option.Value), Label: option.Name})
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

func resumeSessionID(cursor json.RawMessage) string {
	if len(cursor) == 0 {
		return ""
	}
	var payload struct {
		SessionId string `json:"sessionId"`
	}
	_ = json.Unmarshal(cursor, &payload)
	return payload.SessionId
}

func marshalRaw(value any) json.RawMessage {
	raw, _ := json.Marshal(value)
	return raw
}
