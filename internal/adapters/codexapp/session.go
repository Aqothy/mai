package codexapp

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

func (h *Instance) StartSession(ctx context.Context, input provider.StartSessionInput) (provider.StartSessionResult, error) {
	if input.ThreadID == "" {
		return provider.StartSessionResult{}, fmt.Errorf("Codex session requires threadId")
	}
	h.mu.Lock()
	if existing := h.sessionsByLocal[input.ThreadID]; existing != nil {
		session := h.providerSessionLocked(existing)
		h.mu.Unlock()
		return provider.StartSessionResult{Session: session, HistoryUnavailable: input.ReplayHistory}, nil
	}
	h.mu.Unlock()
	nativeID := input.ProviderSessionID
	if nativeID == "" && len(input.ResumeCursor) > 0 {
		_ = json.Unmarshal(input.ResumeCursor, &nativeID)
	}
	model, effort, serviceTier := modelEffortAndTier(input.ModelSelection, input.ConfigSelections)
	params := threadSettingsParams(model, effort, serviceTier)
	params["cwd"] = input.Cwd
	if preset, ok := selectedPermissions(input.ConfigSelections); ok {
		preset.setThreadParams(params)
	}
	var response threadStartResponse
	method := "thread/start"
	var provisional, previous *sessionState
	if nativeID != "" {
		method = "thread/resume"
		params["threadId"] = nativeID
		// Full-history hydration is deprecated; turns are paged below.
		params["excludeTurns"] = true
		provisional = newSessionState(input.ThreadID, nativeID, input.Cwd)
		provisional.model = model
		provisional.effort = effort
		provisional.serviceTier = serviceTier
		h.mu.Lock()
		previous = h.sessionsByLocal[input.ThreadID]
		h.bindSessionLocked(provisional)
		h.mu.Unlock()
	}
	rollbackProvisional := func() {
		if provisional == nil {
			return
		}
		h.mu.Lock()
		if h.sessionsByLocal[input.ThreadID] == provisional {
			delete(h.sessionsByLocal, input.ThreadID)
			if h.localByNative[nativeID] == input.ThreadID {
				delete(h.localByNative, nativeID)
			}
			if previous != nil {
				h.bindSessionLocked(previous)
			}
		}
		h.mu.Unlock()
	}
	if err := h.rpc.call(ctx, method, params, &response); err != nil {
		rollbackProvisional()
		return provider.StartSessionResult{}, err
	}
	if response.Thread.ID == "" {
		rollbackProvisional()
		return provider.StartSessionResult{}, fmt.Errorf("%s returned an empty thread id", method)
	}
	if nativeID != "" && response.Thread.ID != nativeID {
		rollbackProvisional()
		return provider.StartSessionResult{}, fmt.Errorf("thread/resume returned thread id %q, want %q", response.Thread.ID, nativeID)
	}
	if response.Cwd != "" {
		input.Cwd = response.Cwd
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

	if nativeID != "" && input.ReplayHistory {
		turns, err := h.listTurns(ctx, nativeID)
		if err != nil {
			rollbackProvisional()
			return provider.StartSessionResult{}, fmt.Errorf("read Codex thread history: %w", err)
		}
		response.Thread.Turns = turns
	}
	skills, _ := h.listSkills(ctx, []string{input.Cwd})
	h.mu.Lock()
	permissions := permissionsFor(response.ApprovalPolicy, response.Sandbox.Type)
	options := append(configOptionsFromModels(h.models, model, effort, serviceTier), permissionsOption(permissions))
	serviceTier, _ = provider.CurrentConfigString(options, "service_tier")
	session := provisional
	if session == nil {
		session = newSessionState(input.ThreadID, response.Thread.ID, input.Cwd)
	}
	session.cwd = input.Cwd
	session.model = model
	session.effort = effort
	session.serviceTier = serviceTier
	session.permissions = permissions
	session.skills = append([]provider.Skill(nil), skills...)
	session.configOptions = append([]provider.ConfigOption(nil), options...)
	for _, turn := range response.Thread.Turns {
		session.nativeToLocalTurn[turn.ID] = turn.ID
		session.localToNativeTurn[turn.ID] = turn.ID
		if turn.Status == "inProgress" {
			session.startedTurns[turn.ID] = true
			session.activeNativeTurn = turn.ID
		}
	}
	h.bindSessionLocked(session)
	providerSession := h.providerSessionLocked(session)
	h.mu.Unlock()
	result := provider.StartSessionResult{Session: providerSession}
	metadata := provider.RuntimeEvent{
		EventID: provider.RuntimeEventID("codex:meta:" + input.ThreadID + ":start"), Type: provider.RuntimeEventThreadMetadataUpdate,
		Provider: DriverKind, ThreadID: input.ThreadID, Payload: provider.RuntimeEventPayload{SlashCommands: slashCommands},
	}
	if input.ReplayHistory {
		// Same-thread setup events ride the replay batch, never the live sink.
		result.Replay = append(replayEvents(input.ThreadID, response.Thread), metadata)
	} else {
		h.emitEvent(metadata)
	}
	return result, nil
}

func (h *Instance) SendTurn(ctx context.Context, input provider.SendTurnInput) error {
	clientMessageID := input.ClientMessageID
	if clientMessageID == "" {
		clientMessageID = input.TurnID
	}
	h.mu.Lock()
	session := h.sessionsByLocal[input.ThreadID]
	if session == nil {
		h.mu.Unlock()
		return fmt.Errorf("Codex thread %q is not bound", input.ThreadID)
	}
	if input.Steer {
		nativeTurn := session.localToNativeTurn[input.TurnID]
		if nativeTurn == "" || nativeTurn != session.activeNativeTurn {
			h.mu.Unlock()
			return fmt.Errorf("Codex thread %q turn %q: %w", input.ThreadID, input.TurnID, provider.ErrTurnNotRunning)
		}
		nativeThread := session.nativeThreadID
		skills := append([]provider.Skill(nil), session.skills...)
		h.mu.Unlock()
		turnInput, err := userInputsFromTurn(input, skills)
		if err != nil {
			return err
		}
		var response struct {
			TurnID string `json:"turnId"`
		}
		if err := h.rpc.call(ctx, "turn/steer", map[string]any{
			"threadId":            nativeThread,
			"expectedTurnId":      nativeTurn,
			"clientUserMessageId": clientMessageID,
			"input":               turnInput,
		}, &response); err != nil {
			return err
		}
		if response.TurnID != nativeTurn {
			return fmt.Errorf("turn/steer returned unexpected turn id %q (active %q)", response.TurnID, nativeTurn)
		}
		return nil
	}
	if session.pendingLocalTurn != "" {
		h.mu.Unlock()
		return fmt.Errorf("Codex thread %q already has an active turn", input.ThreadID)
	}
	session.pendingLocalTurn = input.TurnID
	nativeThread := session.nativeThreadID
	model := session.model
	effort := session.effort
	serviceTier := session.serviceTier
	permissions, permissionsChanged := session.permissions, session.permissionsChanged
	requestSummaries := h.requestSummaries
	skills := append([]provider.Skill(nil), session.skills...)
	h.mu.Unlock()
	turnInput, err := userInputsFromTurn(input, skills)
	if err != nil {
		h.mu.Lock()
		if current := h.sessionsByLocal[input.ThreadID]; current != nil && current.pendingLocalTurn == input.TurnID {
			current.pendingLocalTurn = ""
		}
		h.mu.Unlock()
		return err
	}
	params := map[string]any{
		"threadId":            nativeThread,
		"clientUserMessageId": clientMessageID,
		"input":               turnInput,
	}
	if input.ModelSelection != nil && input.ModelSelection.Model != "" {
		model = input.ModelSelection.Model
	}
	if model != "" {
		params["model"] = model
	}
	if effort != "" {
		params["effort"] = effort
	}
	if serviceTier != "" {
		params["serviceTier"] = serviceTier
	}
	if preset, ok := permissionPresetByID(permissions); ok && permissionsChanged {
		preset.setTurnParams(params)
	}
	if requestSummaries {
		// Every catalog model defaults to no reasoning summaries, which
		// would leave reasoning items empty.
		params["summary"] = "auto"
	}
	release := func() {
		h.mu.Lock()
		if current := h.sessionsByLocal[input.ThreadID]; current != nil && current.pendingLocalTurn == input.TurnID {
			current.pendingLocalTurn = ""
		}
		h.mu.Unlock()
	}
	method, request := "turn/start", params
	if command, commandParams, ok := builtinCommand(input, nativeThread); ok {
		method, request = command, commandParams
	}
	var response struct {
		Turn appTurn `json:"turn"`
	}
	if err := h.rpc.call(ctx, method, request, &response); err != nil {
		release()
		return err
	}
	if method == "thread/compact/start" {
		// Compaction runs as a turn its turn/started notification starts.
		return nil
	}
	if response.Turn.ID == "" {
		release()
		return fmt.Errorf("%s returned an empty turn id", method)
	}
	if permissionsChanged && method == "turn/start" {
		// turn/start settings stay for the rest of the thread.
		h.mu.Lock()
		if session.permissions == permissions {
			session.permissionsChanged = false
		}
		h.mu.Unlock()
	}
	return h.emitTurnStarted(nativeThread, response.Turn.ID)
}

func (h *Instance) InterruptTurn(ctx context.Context, input provider.InterruptTurnInput) error {
	h.mu.Lock()
	session := h.sessionsByLocal[input.ThreadID]
	if session == nil {
		h.mu.Unlock()
		return fmt.Errorf("Codex thread %q is not bound", input.ThreadID)
	}
	nativeTurn := session.localToNativeTurn[input.TurnID]
	if nativeTurn == "" {
		nativeTurn = session.activeNativeTurn
	}
	nativeThread := session.nativeThreadID
	h.mu.Unlock()
	if nativeTurn == "" {
		return fmt.Errorf("Codex thread %q has no active turn", input.ThreadID)
	}
	return h.rpc.call(ctx, "turn/interrupt", map[string]any{"threadId": nativeThread, "turnId": nativeTurn}, nil)
}

func (h *Instance) StopSession(ctx context.Context, input provider.StopSessionInput) error {
	h.mu.Lock()
	session := h.sessionsByLocal[input.ThreadID]
	if session == nil {
		h.mu.Unlock()
		return nil
	}
	nativeThread := session.nativeThreadID
	activeNativeTurn := session.activeNativeTurn
	h.mu.Unlock()
	if activeNativeTurn != "" {
		if err := h.rpc.call(ctx, "turn/interrupt", map[string]any{"threadId": nativeThread, "turnId": activeNativeTurn}, nil); err != nil {
			h.mu.Lock()
			stillActive := h.sessionsByLocal[input.ThreadID] == session && session.activeNativeTurn == activeNativeTurn
			h.mu.Unlock()
			if stillActive {
				return err
			}
		}
	}
	if err := h.rpc.call(ctx, "thread/unsubscribe", map[string]any{"threadId": nativeThread}, nil); err != nil && !isRPCMethodNotFound(err) {
		return err
	}
	h.mu.Lock()
	if h.sessionsByLocal[input.ThreadID] == session {
		delete(h.sessionsByLocal, input.ThreadID)
		if h.localByNative[nativeThread] == input.ThreadID {
			delete(h.localByNative, nativeThread)
		}
	}
	approvals := make([]*pendingApproval, 0)
	for id, pending := range h.pendingApprovals {
		if pending.localThread == input.ThreadID {
			delete(h.pendingApprovals, id)
			approvals = append(approvals, pending)
		}
	}
	h.mu.Unlock()
	for _, pending := range approvals {
		_ = h.rpc.respond(pending.id, pending.cancelReply())
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRequestResolved, ThreadID: pending.localThread, TurnID: pending.localTurn, RequestID: pending.requestID, Payload: provider.RuntimeEventPayload{RequestType: pending.requestType, Decision: provider.ApprovalDecisionCancel, Cancelled: true}})
	}
	return nil
}

// providerSessionLocked snapshots the public projection of one live binding.
// The mutable maps remain owned by sessionState and are never exposed.
func (h *Instance) providerSessionLocked(session *sessionState) provider.Session {
	resumeCursor, _ := json.Marshal(session.nativeThreadID)
	return provider.Session{
		Provider: DriverKind, ProviderInstanceID: h.info.InstanceID,
		ProviderSessionID: session.nativeThreadID, ProviderName: h.info.Name,
		Cwd: session.cwd, ThreadID: session.localThreadID, ResumeCursor: resumeCursor,
		ConfigOptions: append([]provider.ConfigOption(nil), session.configOptions...),
		Skills:        append([]provider.Skill(nil), session.skills...),
	}
}

func (h *Instance) SetConfigOption(_ context.Context, input provider.SetConfigOptionInput) error {
	h.mu.Lock()
	session := h.sessionsByLocal[input.ThreadID]
	if session == nil {
		h.mu.Unlock()
		return fmt.Errorf("Codex thread %q is not bound", input.ThreadID)
	}
	value, ok := input.Value.(string)
	if !ok {
		h.mu.Unlock()
		return fmt.Errorf("Codex config option %q requires a string value", input.OptionID)
	}
	model := session.model
	effort := session.effort
	serviceTier := session.serviceTier
	permissions := session.permissions
	switch input.OptionID {
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
			return fmt.Errorf("Codex config option %q does not accept value %q", input.OptionID, value)
		}
		permissions = value
	default:
		h.mu.Unlock()
		return fmt.Errorf("Codex config option %q is not supported", input.OptionID)
	}
	options := append(configOptionsFromModels(h.models, model, effort, serviceTier), permissionsOption(permissions))
	current, present := provider.CurrentConfigString(options, input.OptionID)
	if !present || current != value {
		h.mu.Unlock()
		return fmt.Errorf("Codex config option %q does not accept value %q", input.OptionID, value)
	}
	model, _ = provider.CurrentConfigString(options, "model")
	effort, _ = provider.CurrentConfigString(options, "reasoning_effort")
	serviceTier, _ = provider.CurrentConfigString(options, "service_tier")
	session.model = model
	session.effort = effort
	session.serviceTier = serviceTier
	session.permissionsChanged = session.permissionsChanged || permissions != session.permissions
	session.permissions = permissions
	session.configOptions = options
	optionsSnapshot := append([]provider.ConfigOption(nil), session.configOptions...)
	h.mu.Unlock()
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventConfigOptionsUpdated, ThreadID: input.ThreadID, Payload: provider.RuntimeEventPayload{ConfigOptions: optionsSnapshot}})
	return nil
}

func (h *Instance) ListSessions(ctx context.Context, cwd string) ([]provider.SessionSummary, error) {
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

func (h *Instance) DeleteSession(ctx context.Context, sessionID string) error {
	return h.rpc.call(ctx, "thread/delete", map[string]any{"threadId": sessionID}, nil)
}

func (h *Instance) CloseSession(ctx context.Context, sessionID string) error {
	return h.rpc.call(ctx, "thread/unsubscribe", map[string]any{"threadId": sessionID}, nil)
}

func (h *Instance) ForkSession(ctx context.Context, input provider.ForkSessionInput) (provider.ForkSessionResult, error) {
	if input.ProviderSessionID == "" {
		return provider.ForkSessionResult{}, fmt.Errorf("Codex fork requires a provider session id")
	}
	// Codex keeps the fork loaded, so a later thread/resume cannot change its
	// settings; the fork itself must carry the source's model and reasoning.
	params := threadSettingsParams(modelEffortAndTier(input.ModelSelection, input.ConfigSelections))
	params["threadId"] = input.ProviderSessionID
	// The fork's history is read when its thread opens; full-history
	// hydration is deprecated.
	params["excludeTurns"] = true
	if preset, ok := selectedPermissions(input.ConfigSelections); ok {
		preset.setThreadParams(params)
	}
	var response threadStartResponse
	if err := h.rpc.call(ctx, "thread/fork", params, &response); err != nil {
		return provider.ForkSessionResult{}, err
	}
	if response.Thread.ID == "" {
		return provider.ForkSessionResult{}, fmt.Errorf("thread/fork returned an empty thread id")
	}
	return provider.ForkSessionResult{Summary: sessionSummaryFromThread(response.Thread)}, nil
}

// slashCommands are the app-server operations offered as slash commands.
var slashCommands = []provider.SlashCommand{
	{Name: "compact", Description: "Summarize the conversation to free up context"},
	{Name: "review", Description: "Review uncommitted changes, or the changes against a base branch", HasInput: true, InputHint: "[base branch]"},
}

// builtinCommand maps a prompt that is one of slashCommands to its
// app-server request.
func builtinCommand(input provider.SendTurnInput, threadID string) (string, map[string]any, bool) {
	if len(input.Attachments) > 0 {
		return "", nil, false
	}
	name, args, _ := strings.Cut(strings.TrimSpace(input.Input), " ")
	args = strings.TrimSpace(args)
	switch {
	case name == "/compact" && args == "":
		return "thread/compact/start", map[string]any{"threadId": threadID}, true
	case name == "/review":
		target := map[string]any{"type": "uncommittedChanges"}
		if args != "" {
			target = map[string]any{"type": "baseBranch", "branch": args}
		}
		return "review/start", map[string]any{"threadId": threadID, "target": target, "delivery": "inline"}, true
	}
	return "", nil, false
}

// listTurns pages a thread's turns, oldest first, with their items.
func (h *Instance) listTurns(ctx context.Context, threadID string) ([]appTurn, error) {
	params := map[string]any{"threadId": threadID, "sortDirection": "asc", "itemsView": "full", "limit": 100}
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
		if page.NextCursor == nil || *page.NextCursor == "" {
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

func modelEffortAndTier(selection *provider.ModelSelection, selections []provider.ConfigOptionSelection) (string, string, string) {
	model, effort, serviceTier := "", "", ""
	if selection != nil {
		model = selection.Model
	}
	for _, option := range selections {
		value, _ := option.Value.(string)
		switch option.OptionID {
		case "model":
			if value != "" {
				model = value
			}
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
	for local, session := range h.sessionsByLocal {
		cwds[session.cwd] = append(cwds[session.cwd], local)
	}
	h.mu.Unlock()
	for cwd, locals := range cwds {
		ctx, cancel := context.WithTimeout(h.ctx, 30*time.Second)
		skills, err := h.listSkills(ctx, []string{cwd})
		cancel()
		if err != nil {
			continue
		}
		for _, local := range locals {
			h.mu.Lock()
			if session := h.sessionsByLocal[local]; session != nil {
				session.skills = append([]provider.Skill(nil), skills...)
			}
			h.mu.Unlock()
			h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventThreadMetadataUpdate, ThreadID: local, Payload: provider.RuntimeEventPayload{Skills: skills}})
		}
	}
}

// RenameSession names the Codex thread, as the TUI's /rename does.
func (h *Instance) RenameSession(ctx context.Context, input provider.RenameSessionInput) error {
	return h.rpc.call(ctx, "thread/name/set", map[string]any{"threadId": input.ProviderSessionID, "name": input.Title}, nil)
}
