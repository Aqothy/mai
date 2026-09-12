package orchestration

import (
	"encoding/json"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

func cloneRawMessage(value json.RawMessage) json.RawMessage {
	return append(json.RawMessage(nil), value...)
}

func cloneAttachments(values []provider.Attachment) []provider.Attachment {
	if values == nil {
		return nil
	}
	cloned := make([]provider.Attachment, len(values))
	for index, value := range values {
		cloned[index] = value
		cloned[index].Annotations = cloneContentAnnotations(value.Annotations)
		cloned[index].Metadata = cloneMetadata(value.Metadata)
		cloned[index].ResourceMetadata = cloneMetadata(value.ResourceMetadata)
	}
	return cloned
}

func cloneContentAnnotations(value *provider.ContentAnnotations) *provider.ContentAnnotations {
	if value == nil {
		return nil
	}
	cloned := *value
	cloned.Audience = append([]string(nil), value.Audience...)
	cloned.Metadata = cloneMetadata(value.Metadata)
	return &cloned
}

func cloneMetadata(value map[string]any) map[string]any {
	if value == nil {
		return nil
	}
	cloned := make(map[string]any, len(value))
	for key, entry := range value {
		cloned[key] = cloneMetadataValue(entry)
	}
	return cloned
}

func cloneMetadataValue(value any) any {
	switch typed := value.(type) {
	case map[string]any:
		return cloneMetadata(typed)
	case []any:
		cloned := make([]any, len(typed))
		for index, entry := range typed {
			cloned[index] = cloneMetadataValue(entry)
		}
		return cloned
	case json.RawMessage:
		return cloneRawMessage(typed)
	case []byte:
		return append([]byte(nil), typed...)
	default:
		return value
	}
}

// cloneToolCall isolates a public thread snapshot from projection-owned state.
// Inside ingestion and projection, tool snapshots are immutable and shared.
func cloneToolCall(value *provider.ToolCall) *provider.ToolCall {
	if value == nil {
		return nil
	}
	clone := *value
	clone.Locations = append([]provider.ToolLocation(nil), value.Locations...)
	for index := range clone.Locations {
		if value.Locations[index].Line != nil {
			line := *value.Locations[index].Line
			clone.Locations[index].Line = &line
		}
	}
	clone.Changes = append([]provider.FileChange(nil), value.Changes...)
	clone.Attachments = cloneAttachments(value.Attachments)
	if value.ExitCode != nil {
		exitCode := *value.ExitCode
		clone.ExitCode = &exitCode
	}
	if value.DurationMilliseconds != nil {
		duration := *value.DurationMilliseconds
		clone.DurationMilliseconds = &duration
	}
	return &clone
}

func cloneItem(value Item) Item {
	clone := value
	clone.Payload = cloneRawMessage(value.Payload)
	clone.ToolCall = cloneToolCall(value.ToolCall)
	clone.ToolCallSummary = nil
	clone.DetailAvailable = false
	return clone
}

func cloneToolCallSummary(value *ToolCallSummary) *ToolCallSummary {
	if value == nil {
		return nil
	}
	clone := *value
	clone.Locations = append([]provider.ToolLocation(nil), value.Locations...)
	for index := range clone.Locations {
		clone.Locations[index].Line = cloneUint32Ptr(value.Locations[index].Line)
	}
	clone.Changes = append([]FileChangeSummary(nil), value.Changes...)
	clone.Attachments = append([]ToolAttachmentSummary(nil), value.Attachments...)
	clone.ExitCode = cloneIntPtr(value.ExitCode)
	clone.DurationMilliseconds = cloneInt64Ptr(value.DurationMilliseconds)
	return &clone
}

func cloneThread(thread Thread) Thread {
	thread.ModelSelection = cloneModelSelection(thread.ModelSelection)
	thread.AdditionalDirectories = append([]string(nil), thread.AdditionalDirectories...)
	thread.ConfigSelections = append([]provider.ConfigOptionSelection(nil), thread.ConfigSelections...)
	thread.Session = cloneSessionPtr(thread.Session)
	thread.LatestTurn = cloneTurnPtr(thread.LatestTurn)
	thread.Timeline = thread.Timeline.Clone()
	thread.Plan = clonePlanPtr(thread.Plan)
	return thread
}

func clonePlanPtr(value *Plan) *Plan {
	if value == nil {
		return nil
	}
	clone := *value
	clone.Entries = append([]provider.PlanEntry(nil), value.Entries...)
	return &clone
}

func cloneModelSelection(value *provider.ModelSelection) *provider.ModelSelection {
	if value == nil {
		return nil
	}
	clone := *value
	clone.Options = append([]byte(nil), value.Options...)
	return &clone
}

func cloneConfigOptions(options []provider.ConfigOption) []provider.ConfigOption {
	if options == nil {
		return nil
	}
	return append([]provider.ConfigOption{}, options...)
}

func cloneSlashCommands(commands []provider.SlashCommand) []provider.SlashCommand {
	if commands == nil {
		return nil
	}
	return append([]provider.SlashCommand{}, commands...)
}

func cloneSkills(skills []provider.Skill) []provider.Skill {
	if skills == nil {
		return nil
	}
	return append([]provider.Skill{}, skills...)
}

func cloneSessionPtr(value *SessionBinding) *SessionBinding {
	if value == nil {
		return nil
	}
	clone := *value
	clone.AdditionalDirectories = append([]string(nil), value.AdditionalDirectories...)
	clone.ConfigOptions = cloneConfigOptions(value.ConfigOptions)
	clone.SlashCommands = cloneSlashCommands(value.SlashCommands)
	clone.Skills = cloneSkills(value.Skills)
	if value.TokenUsage != nil {
		usage := *value.TokenUsage
		clone.TokenUsage = &usage
	}
	return &clone
}

func cloneTurnPtr(value *Turn) *Turn {
	if value == nil {
		return nil
	}
	clone := *value
	clone.StartedAt = cloneTimePtr(value.StartedAt)
	clone.CompletedAt = cloneTimePtr(value.CompletedAt)
	return &clone
}

func cloneTimePtr(value *time.Time) *time.Time {
	if value == nil {
		return nil
	}
	clone := *value
	return &clone
}

func cloneIntPtr(value *int) *int {
	if value == nil {
		return nil
	}
	clone := *value
	return &clone
}

func cloneInt64Ptr(value *int64) *int64 {
	if value == nil {
		return nil
	}
	clone := *value
	return &clone
}

func cloneUint32Ptr(value *uint32) *uint32 {
	if value == nil {
		return nil
	}
	clone := *value
	return &clone
}

func firstTime(value time.Time, fallback time.Time) time.Time {
	if value.IsZero() {
		return fallback
	}
	return value
}
