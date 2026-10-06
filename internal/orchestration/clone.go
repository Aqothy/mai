package orchestration

import (
	"encoding/json"
	"slices"
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
		clone.Locations[index].Line = clonePtr(value.Locations[index].Line)
	}
	clone.Changes = append([]provider.FileChange(nil), value.Changes...)
	clone.Attachments = cloneAttachments(value.Attachments)
	clone.ExitCode = clonePtr(value.ExitCode)
	clone.DurationMilliseconds = clonePtr(value.DurationMilliseconds)
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

func cloneSessionPtr(value *SessionBinding) *SessionBinding {
	if value == nil {
		return nil
	}
	clone := *value
	clone.AdditionalDirectories = append([]string(nil), value.AdditionalDirectories...)
	clone.ConfigOptions = slices.Clone(value.ConfigOptions)
	clone.SlashCommands = slices.Clone(value.SlashCommands)
	clone.Skills = slices.Clone(value.Skills)
	clone.TokenUsage = clonePtr(value.TokenUsage)
	return &clone
}

func cloneTurnPtr(value *Turn) *Turn {
	if value == nil {
		return nil
	}
	clone := *value
	clone.StartedAt = clonePtr(value.StartedAt)
	clone.CompletedAt = clonePtr(value.CompletedAt)
	return &clone
}

func cloneTurns(turns []Turn) []Turn {
	if turns == nil {
		return nil
	}
	cloned := make([]Turn, len(turns))
	for index := range turns {
		cloned[index] = *cloneTurnPtr(&turns[index])
	}
	return cloned
}

// clonePtr copies the pointed-to value so the clone shares no mutable state.
func clonePtr[T any](value *T) *T {
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
