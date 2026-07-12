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

func cloneThread(thread Thread) Thread {
	thread.ModelSelection = cloneModelSelection(thread.ModelSelection)
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

func firstTime(value time.Time, fallback time.Time) time.Time {
	if value.IsZero() {
		return fallback
	}
	return value
}
