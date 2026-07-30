package orchestration

import (
	"encoding/json"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

func cloneRawMessage(value json.RawMessage) json.RawMessage {
	if len(value) == 0 {
		return nil
	}
	return append(json.RawMessage(nil), value...)
}

func cloneAttachments(values []provider.Attachment) []provider.Attachment {
	return append([]provider.Attachment(nil), values...)
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

func cloneSessionPtr(value *SessionBinding) *SessionBinding {
	if value == nil {
		return nil
	}
	clone := *value
	clone.ConfigOptions = cloneConfigOptions(value.ConfigOptions)
	clone.SlashCommands = cloneSlashCommands(value.SlashCommands)
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
