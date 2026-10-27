package codexapp

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// Open starts a Codex thread, or resumes one; a thread app-server no longer
// has is replaced by a new one.
func (h *Instance) Open(ctx context.Context, in provider.OpenInput) (provider.Opened, error) {
	h.mu.Lock()
	if existing := h.sessions[in.Session]; in.Session != "" && existing != nil && existing.loaded {
		opened := h.openedLocked(existing)
		h.mu.Unlock()
		return opened, nil
	}
	h.mu.Unlock()
	model, effort, serviceTier := modelEffortAndTier(in.Settings)
	params := threadSettingsParams(model, effort, serviceTier)
	params["cwd"] = in.Workspace.Cwd
	if preset, ok := selectedPermissions(in.Settings); ok {
		preset.setThreadParams(params)
	}
	if in.Instructions != "" {
		params["developerInstructions"] = in.Instructions
	}
	if in.MCP != nil {
		config, _ := params["config"].(map[string]any)
		if config == nil {
			config = map[string]any{}
		}
		for key, value := range mcpConfig(*in.MCP) {
			config[key] = value
		}
		params["config"] = config
	}
	method := "thread/start"
	if in.Session != "" {
		method = "thread/resume"
		params["threadId"] = in.Session
		// Full-history hydration is deprecated; History pages turns.
		params["excludeTurns"] = true
	}
	var response threadStartResponse
	err := h.rpc.call(ctx, method, params, &response)
	if err != nil && in.Session != "" && threadMissing(err) {
		// The thread is gone: a new one takes its place.
		delete(params, "threadId")
		delete(params, "excludeTurns")
		method = "thread/start"
		err = h.rpc.call(ctx, method, params, &response)
	}
	if err != nil {
		return provider.Opened{}, err
	}
	if response.Thread.ID == "" {
		return provider.Opened{}, fmt.Errorf("%s returned an empty thread id", method)
	}
	if method == "thread/resume" && response.Thread.ID != in.Session {
		return provider.Opened{}, fmt.Errorf("thread/resume of %q returned thread %q", in.Session, response.Thread.ID)
	}
	cwd := in.Workspace.Cwd
	if response.Cwd != "" {
		cwd = response.Cwd
	}
	if response.Model != "" {
		model = response.Model
	}
	if response.ReasoningEffort != "" {
		effort = response.ReasoningEffort
	}
	serviceTier = strings.TrimSpace(response.ServiceTier)
	if serviceTier == "" {
		serviceTier = defaultServiceTier
	}
	skills, _ := h.listSkills(ctx, []string{cwd})
	var goal *provider.Goal
	if method == "thread/resume" {
		// A resumed thread may have a goal; it is only reported as it
		// changes, so read it once here.
		if current, err := h.currentGoal(ctx, response.Thread.ID); err != nil {
			h.logger.Warn("read Codex thread goal", "thread", response.Thread.ID, "error", err)
		} else {
			goal, _ = goalOf(current)
		}
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessionLocked(response.Thread.ID)
	permissions := permissionsFor(response.ApprovalPolicy, response.Sandbox.Type)
	session.configOptions = append(configOptionsFromModels(h.models, model, effort, serviceTier), permissionsOption(permissions))
	session.serviceTier, _ = provider.CurrentConfigString(session.configOptions, "service_tier")
	session.cwd, session.model, session.effort, session.permissions = cwd, model, effort, permissions
	session.skills = append([]provider.Skill(nil), skills...)
	session.loaded = true
	for _, turn := range response.Thread.Turns {
		if turn.Status == "inProgress" {
			session.started[turn.ID] = true
			session.activeTurn = turn.ID
		}
	}
	opened := h.openedLocked(session)
	opened.Goal = goal
	return opened, nil
}

func (h *Instance) openedLocked(session *sessionState) provider.Opened {
	return provider.Opened{
		Session:  session.thread,
		Options:  append([]provider.ConfigOption(nil), session.configOptions...),
		Commands: append([]provider.SlashCommand(nil), slashCommands...),
		Skills:   append([]provider.Skill(nil), session.skills...),
	}
}

// threadMissing reports whether app-server said a thread doesn't exist:
// "thread not found: <id>" or "no rollout found for thread id <id>"
// (app-server request_processors/thread_processor.rs).
func threadMissing(err error) bool {
	message := err.Error()
	return strings.Contains(message, "thread not found") || strings.Contains(message, "no rollout found for thread id")
}

// mcpConfig gives a thread maiD's MCP server through config overrides
// (config/src/overrides.rs): its tools run without asking, since they apply
// their own policy.
func mcpConfig(server provider.MCPServer) map[string]any {
	prefix := "mcp_servers." + server.Name + "."
	config := map[string]any{
		prefix + "url":                         server.URL,
		prefix + "tool_timeout_sec":            3600,
		prefix + "default_tools_approval_mode": "approve",
	}
	if len(server.Headers) > 0 {
		config[prefix+"http_headers"] = server.Headers
	}
	return config
}

// Release ends a turn the thread runs and stops following it; the thread
// stays in Codex.
func (h *Instance) Release(ctx context.Context, thread string) error {
	h.mu.Lock()
	session := h.sessions[thread]
	if session == nil {
		h.mu.Unlock()
		return nil
	}
	active := session.activeTurn
	h.mu.Unlock()
	if active != "" {
		if err := h.rpc.call(ctx, "turn/interrupt", map[string]any{"threadId": thread, "turnId": active}, nil); err != nil {
			return err
		}
	}
	if err := h.rpc.call(ctx, "thread/unsubscribe", map[string]any{"threadId": thread}, nil); err != nil && !isRPCMethodNotFound(err) {
		return err
	}
	h.mu.Lock()
	session.loaded = false
	h.mu.Unlock()
	h.cancelPendingApprovals(thread)
	return nil
}

// History reads the thread's turns from its rollout; it works on a thread
// app-server hasn't loaded.
func (h *Instance) History(ctx context.Context, thread string, _ provider.Workspace, after provider.Marker) (provider.HistoryPage, error) {
	turns, err := h.listTurns(ctx, thread, string(after))
	if err != nil {
		if threadMissing(err) {
			return provider.HistoryPage{}, fmt.Errorf("%w: %v", provider.ErrSessionNotFound, err)
		}
		return provider.HistoryPage{}, err
	}
	history, subagents := historyTurns(turns, time.Time{})
	page := provider.After(history, after)
	for _, seen := range subagents {
		seen.Parent = thread
		page.Subagents = append(page.Subagents, seen)
	}
	return page, nil
}

// Delivered finds the delivery's ID in the thread: a user message whose
// clientId it is (v2/item.rs), or a tool result that names it (a reply an
// agent's wait or read took).
func (h *Instance) Delivered(ctx context.Context, thread string, probe provider.DeliveryProbe) (provider.Tri, error) {
	turns, err := h.listTurns(ctx, thread, "")
	if err != nil {
		return provider.TriUnknown, err
	}
	for _, turn := range turns {
		for _, item := range turn.Items {
			if item.Type == "userMessage" && stringValue(item.ClientID) == probe.Delivery {
				return provider.TriYes, nil
			}
			if item.Type == "mcpToolCall" && strings.Contains(string(item.Result), probe.Delivery) {
				return provider.TriYes, nil
			}
		}
	}
	return provider.TriNo, nil
}

// Fork forks the thread through a turn (thread/fork with lastTurnId). Codex
// keeps the fork loaded, so a later thread/resume can't change its
// settings: the fork itself carries them.
func (h *Instance) Fork(ctx context.Context, in provider.ForkInput) (string, error) {
	params := threadSettingsParams(modelEffortAndTier(in.Settings))
	params["threadId"] = in.Session
	params["lastTurnId"] = in.Through
	params["excludeTurns"] = true
	if preset, ok := selectedPermissions(in.Settings); ok {
		preset.setThreadParams(params)
	}
	var response threadStartResponse
	if err := h.rpc.call(ctx, "thread/fork", params, &response); err != nil {
		return "", err
	}
	if response.Thread.ID == "" {
		return "", fmt.Errorf("thread/fork returned an empty thread id")
	}
	return response.Thread.ID, nil
}

func (h *Instance) Configure(_ context.Context, thread string, setting provider.ConfigOptionSelection) error {
	h.mu.Lock()
	session := h.sessions[thread]
	if session == nil || !session.loaded {
		h.mu.Unlock()
		return fmt.Errorf("Codex thread %q is not open", thread)
	}
	value, ok := setting.Value.(string)
	if !ok {
		h.mu.Unlock()
		return fmt.Errorf("Codex config option %q requires a string value", setting.OptionID)
	}
	model, effort, serviceTier, permissions := session.model, session.effort, session.serviceTier, session.permissions
	switch setting.OptionID {
	case "model":
		model = value
	case "reasoning_effort":
		effort = value
	case "service_tier":
		serviceTier = value
	case permissionsOptionID:
		// Only a preset can be chosen; the next turn applies it.
		if _, ok := permissionPresetByID(value); !ok {
			h.mu.Unlock()
			return fmt.Errorf("Codex config option %q does not accept value %q", setting.OptionID, value)
		}
		permissions = value
	default:
		h.mu.Unlock()
		return fmt.Errorf("Codex config option %q is not supported", setting.OptionID)
	}
	options := append(configOptionsFromModels(h.models, model, effort, serviceTier), permissionsOption(permissions))
	if current, present := provider.CurrentConfigString(options, setting.OptionID); !present || current != value {
		h.mu.Unlock()
		return fmt.Errorf("Codex config option %q does not accept value %q", setting.OptionID, value)
	}
	session.model, _ = provider.CurrentConfigString(options, "model")
	session.effort, _ = provider.CurrentConfigString(options, "reasoning_effort")
	session.serviceTier, _ = provider.CurrentConfigString(options, "service_tier")
	session.permissionsChanged = session.permissionsChanged || permissions != session.permissions
	session.permissions = permissions
	session.configOptions = options
	snapshot := append([]provider.ConfigOption(nil), options...)
	h.mu.Unlock()
	h.emit(thread, provider.ConfigChanged{Options: snapshot})
	return nil
}

func (h *Instance) Sessions(ctx context.Context, cwd string) ([]provider.SessionSummary, error) {
	var summaries []provider.SessionSummary
	var cursor any
	seenCursors := make(map[string]struct{})
	for {
		params := map[string]any{"limit": 100, "sortKey": "updated_at", "sortDirection": "desc"}
		if cwd != "" {
			params["cwd"] = cwd
		}
		if cursor != nil {
			params["cursor"] = cursor
		}
		var response threadListResponse
		if err := h.rpc.call(ctx, "thread/list", params, &response); err != nil {
			return nil, err
		}
		for _, thread := range response.Data {
			summaries = append(summaries, sessionSummaryFromThread(thread))
		}
		if response.NextCursor == nil || *response.NextCursor == "" {
			break
		}
		if _, seen := seenCursors[*response.NextCursor]; seen {
			return nil, fmt.Errorf("thread/list repeated cursor %q", *response.NextCursor)
		}
		seenCursors[*response.NextCursor] = struct{}{}
		cursor = *response.NextCursor
	}
	return summaries, nil
}

func (h *Instance) Delete(ctx context.Context, thread string) error {
	if err := h.rpc.call(ctx, "thread/delete", map[string]any{"threadId": thread}, nil); err != nil {
		return err
	}
	h.mu.Lock()
	delete(h.sessions, thread)
	h.mu.Unlock()
	return nil
}

// Rename names the Codex thread, as the TUI's /rename does.
func (h *Instance) Rename(ctx context.Context, thread, title string) error {
	return h.rpc.call(ctx, "thread/name/set", map[string]any{"threadId": thread, "name": title}, nil)
}

// listTurns reads a thread's turns, oldest first: all of them, or with after
// those past it and it. Opening a chat usually finds none or a few past the
// cache's, so it lists their IDs alone first and reads only those in full.
func (h *Instance) listTurns(ctx context.Context, threadID, after string) ([]appTurn, error) {
	if after == "" {
		return h.pageTurns(ctx, threadID, "full", 100, "")
	}
	recent, err := h.pageTurns(ctx, threadID, "notLoaded", 20, after)
	if err != nil {
		return nil, err
	}
	index := slices.IndexFunc(recent, func(turn appTurn) bool { return turn.ID == after })
	switch {
	case index < 0:
		return h.pageTurns(ctx, threadID, "full", 100, "")
	case index == len(recent)-1:
		// Nothing past it: the caller drops the turn itself, items and all.
		return recent[index:], nil
	}
	return h.pageTurns(ctx, threadID, "full", len(recent)-index, after)
}

// pageTurns pages a thread's turns newest first, back to until (all of them
// when it is empty), and returns them oldest first.
func (h *Instance) pageTurns(ctx context.Context, threadID, view string, limit int, until string) ([]appTurn, error) {
	params := map[string]any{"threadId": threadID, "sortDirection": "desc", "itemsView": view, "limit": limit}
	var turns []appTurn
	seenCursors := make(map[string]struct{})
	for {
		var page struct {
			Data       []appTurn `json:"data"`
			NextCursor *string   `json:"nextCursor"`
		}
		if err := h.rpc.call(ctx, "thread/turns/list", params, &page); err != nil {
			return nil, err
		}
		turns = append(turns, page.Data...)
		reached := until != "" && slices.ContainsFunc(page.Data, func(turn appTurn) bool { return turn.ID == until })
		if reached || page.NextCursor == nil || *page.NextCursor == "" {
			slices.Reverse(turns)
			return turns, nil
		}
		if _, seen := seenCursors[*page.NextCursor]; seen {
			return nil, fmt.Errorf("thread/turns/list repeated cursor %q", *page.NextCursor)
		}
		seenCursors[*page.NextCursor] = struct{}{}
		params["cursor"] = *page.NextCursor
	}
}

// threadSettingsParams are the thread/start, thread/resume and thread/fork
// settings overrides. Thread requests accept reasoning through config; only
// turn/start has a top-level effort field.
func threadSettingsParams(model, effort, serviceTier string) map[string]any {
	params := map[string]any{}
	if model != "" {
		params["model"] = model
	}
	if effort != "" {
		params["config"] = map[string]any{"model_reasoning_effort": effort}
	}
	if serviceTier != "" {
		params["serviceTier"] = serviceTier
	}
	return params
}

func modelEffortAndTier(selections []provider.ConfigOptionSelection) (string, string, string) {
	model, effort, serviceTier := "", "", ""
	for _, option := range selections {
		value, _ := option.Value.(string)
		switch option.OptionID {
		case "model":
			model = value
		case "reasoning_effort":
			effort = value
		case "service_tier":
			serviceTier = value
		}
	}
	return model, effort, serviceTier
}

func (h *Instance) refreshActiveSkills() {
	h.mu.Lock()
	cwds := make(map[string][]string)
	for thread, session := range h.sessions {
		if session.loaded {
			cwds[session.cwd] = append(cwds[session.cwd], thread)
		}
	}
	h.mu.Unlock()
	for cwd, threads := range cwds {
		ctx, cancel := context.WithTimeout(h.ctx, 30*time.Second)
		skills, err := h.listSkills(ctx, []string{cwd})
		cancel()
		if err != nil {
			continue
		}
		for _, thread := range threads {
			h.mu.Lock()
			if session := h.sessions[thread]; session != nil {
				session.skills = append([]provider.Skill(nil), skills...)
			}
			h.mu.Unlock()
			h.emit(thread, provider.ConfigChanged{Skills: skills})
		}
	}
}
