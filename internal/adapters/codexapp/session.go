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
	var goal *provider.RuntimeEvent
	if nativeID != "" {
		// A resumed thread may have a goal; it is only reported as it
		// changes, so read it once here.
		current, err := h.currentGoal(ctx, nativeID)
		if err != nil {
			h.logger.Warn("read Codex thread goal", "thread", nativeID, "error", err)
		} else if event, ok := goalEvent(input.ThreadID, current); ok {
			goal = &event
		}
	}
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
	setup := []provider.RuntimeEvent{metadata}
	if goal != nil {
		setup = append(setup, *goal)
	}
	if input.ReplayHistory {
		// Same-thread setup events ride the replay batch, never the live sink.
		result.Replay = append(replayEvents(input.ThreadID, response.Thread), setup...)
	} else {
		for _, event := range setup {
			h.emitEvent(event)
		}
	}
	return result, nil
}

func (h *Instance) SendTurn(ctx context.Context, input provider.SendTurnInput) error {
	clientMessageID := input.ClientMessageID
	if clientMessageID == "" {
		clientMessageID = input.TurnID
	}
	command, args, isCommand := parseCommand(input)
	var turnInput []appUserInput
	if !isCommand {
		// Converted first, so input Codex could never take claims no turn.
		var err error
		if turnInput, err = userInputsFromTurn(input, h.threadSkills(input.ThreadID)); err != nil {
			return err
		}
	}
	h.mu.Lock()
	session := h.sessionsByLocal[input.ThreadID]
	if session == nil {
		h.mu.Unlock()
		return fmt.Errorf("Codex thread %q is not bound", input.ThreadID)
	}
	send := turnSend{localThread: input.ThreadID, turn: input.TurnID, nativeThread: session.nativeThreadID, cwd: session.cwd, args: args}
	if input.Steer {
		nativeTurn := session.localToNativeTurn[input.TurnID]
		if nativeTurn == "" || nativeTurn != session.activeNativeTurn {
			h.mu.Unlock()
			return fmt.Errorf("Codex thread %q turn %q: %w", input.ThreadID, input.TurnID, provider.ErrTurnNotRunning)
		}
		h.mu.Unlock()
		send.placement = steered
		if isCommand {
			if !command.joinsTurn {
				// As in the Codex TUI, which disables these during a task.
				return fmt.Errorf("/%s can't run while Codex is working; send it once the turn ends", command.Name)
			}
			return command.run(h, ctx, send)
		}
		var response struct {
			TurnID string `json:"turnId"`
		}
		if err := h.rpc.call(ctx, "turn/steer", map[string]any{
			"threadId":            send.nativeThread,
			"expectedTurnId":      nativeTurn,
			"clientUserMessageId": clientMessageID,
			"input":               turnInput,
		}, &response); err != nil {
			if steerMissedTurn(err) {
				return fmt.Errorf("Codex thread %q turn %q: %w: %w", input.ThreadID, input.TurnID, provider.ErrTurnNotRunning, err)
			}
			return err
		}
		if response.TurnID != nativeTurn {
			return fmt.Errorf("turn/steer returned unexpected turn id %q (active %q)", response.TurnID, nativeTurn)
		}
		return nil
	}
	if session.pending != nil {
		h.mu.Unlock()
		return fmt.Errorf("Codex thread %q already has an active turn", input.ThreadID)
	}
	awaits, joins := awaitsCodexTurn, true
	if isCommand {
		awaits, joins = awaitsCommand, command.joinsTurn
	}
	if beginTurnLocked(session, input.TurnID, awaits, joins) {
		send.placement = tookOver
	}
	model := session.model
	effort := session.effort
	serviceTier := session.serviceTier
	permissions, permissionsChanged := session.permissions, session.permissionsChanged
	requestSummaries := h.requestSummaries
	h.mu.Unlock()
	if send.placement == tookOver {
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventTurnStarted, ThreadID: input.ThreadID, TurnID: input.TurnID})
	}
	if isCommand {
		return command.run(h, ctx, send)
	}
	params := map[string]any{
		"threadId":            send.nativeThread,
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
	// turn/start starts a turn, or steers the input into the one running.
	var response struct {
		Turn appTurn `json:"turn"`
	}
	if err := h.rpc.call(ctx, "turn/start", params, &response); err != nil {
		return h.refuse(send, err)
	}
	if response.Turn.ID == "" {
		return h.refuse(send, fmt.Errorf("turn/start returned an empty turn id"))
	}
	if permissionsChanged {
		// turn/start settings stay for the rest of the thread.
		h.mu.Lock()
		if session.permissions == permissions {
			session.permissionsChanged = false
		}
		h.mu.Unlock()
	}
	if send.placement == ownTurn {
		h.adoptTurn(send.localThread, send.turn, response.Turn.ID)
	}
	return nil
}

func (h *Instance) threadSkills(localThread string) []provider.Skill {
	h.mu.Lock()
	defer h.mu.Unlock()
	if session := h.sessionsByLocal[localThread]; session != nil {
		return append([]provider.Skill(nil), session.skills...)
	}
	return nil
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
	params["lastTurnId"] = input.ThroughTurnID
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
