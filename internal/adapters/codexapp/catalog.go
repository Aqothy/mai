package codexapp

import (
	"context"
	"fmt"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

func (h *Instance) refreshModels(ctx context.Context) error {
	var models []appModel
	cursor := ""
	seenCursors := make(map[string]struct{})
	for {
		params := map[string]any{"limit": 100, "includeHidden": false}
		if cursor != "" {
			params["cursor"] = cursor
		}
		var response modelListResponse
		if err := h.rpc.call(ctx, "model/list", params, &response); err != nil {
			return err
		}
		models = append(models, response.Data...)
		if response.NextCursor == nil || *response.NextCursor == "" {
			break
		}
		if _, seen := seenCursors[*response.NextCursor]; seen {
			return fmt.Errorf("model/list repeated cursor %q", *response.NextCursor)
		}
		seenCursors[*response.NextCursor] = struct{}{}
		cursor = *response.NextCursor
	}
	h.mu.Lock()
	h.models = models
	h.mu.Unlock()
	return nil
}

func (h *Instance) listSkills(ctx context.Context, cwds []string) ([]provider.Skill, error) {
	var response skillsListResponse
	if err := h.rpc.call(ctx, "skills/list", map[string]any{"cwds": cwds}, &response); err != nil {
		return nil, err
	}
	return skillsFromResponse(response), nil
}

func (h *Instance) OpenOptionsSession(ctx context.Context, cwd string, callbacks provider.OptionsSessionCallbacks) (provider.OptionsSession, error) {
	h.mu.Lock()
	modelsMissing := len(h.models) == 0
	h.mu.Unlock()
	if modelsMissing {
		_ = h.refreshModels(ctx)
	}
	// Skills are cwd-scoped in app-server. Keep this lookup recoverable, just
	// like the catalog refresh above, so a transient skills/list failure does
	// not make the draft's model/configuration controls unavailable.
	skills, _ := h.listSkills(ctx, []string{cwd})
	h.mu.Lock()
	defer h.mu.Unlock()
	selectedModel := ""
	for _, model := range h.models {
		if model.IsDefault {
			selectedModel = model.Model
			break
		}
	}
	if selectedModel == "" && len(h.models) > 0 {
		selectedModel = h.models[0].Model
	}
	options := configOptionsFromModels(h.models, selectedModel, "", "")
	handle := fmt.Sprintf("codex-options-%d", time.Now().UnixNano())
	h.options[handle] = &optionsState{selectedModel: selectedModel, callbacks: callbacks}
	return provider.OptionsSession{
		Handle:        handle,
		ConfigOptions: append([]provider.ConfigOption(nil), options...),
		Skills:        append([]provider.Skill(nil), skills...),
	}, nil
}

func (h *Instance) SetOptionsSessionValue(_ context.Context, handle, optionID string, value any) ([]provider.ConfigOption, error) {
	h.mu.Lock()
	state := h.options[handle]
	if state == nil {
		h.mu.Unlock()
		return nil, fmt.Errorf("Codex options session %q is not open", handle)
	}
	text, ok := value.(string)
	if !ok {
		h.mu.Unlock()
		return nil, fmt.Errorf("Codex option %q requires a string value", optionID)
	}
	selectedModel := state.selectedModel
	selectedEffort := state.selectedEffort
	selectedTier := state.selectedTier
	switch optionID {
	case "model":
		selectedModel = text
	case "reasoning_effort":
		selectedEffort = text
	case "service_tier":
		selectedTier = text
	default:
		h.mu.Unlock()
		return nil, fmt.Errorf("Codex option %q is not supported", optionID)
	}
	options := configOptionsFromModels(h.models, selectedModel, selectedEffort, selectedTier)
	current, present := currentConfigString(options, optionID)
	if !present || current != text {
		h.mu.Unlock()
		return nil, fmt.Errorf("Codex option %q does not accept value %q", optionID, text)
	}
	state.selectedModel, _ = currentConfigString(options, "model")
	state.selectedEffort, _ = currentConfigString(options, "reasoning_effort")
	state.selectedTier, _ = currentConfigString(options, "service_tier")
	optionsSnapshot := append([]provider.ConfigOption(nil), options...)
	callback := state.callbacks.Updated
	h.mu.Unlock()
	if callback != nil {
		callback(optionsSnapshot)
	}
	return optionsSnapshot, nil
}

func (h *Instance) CloseOptionsSession(_ context.Context, handle string) error {
	h.mu.Lock()
	delete(h.options, handle)
	h.mu.Unlock()
	return nil
}
