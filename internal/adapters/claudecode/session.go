package claudecode

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/Aqothy/maiD/internal/adapters/procgroup"
	"github.com/Aqothy/maiD/internal/provider"
)

func (h *Instance) StartSession(ctx context.Context, input provider.StartSessionInput) (provider.StartSessionResult, error) {
	if input.ThreadID == "" {
		return provider.StartSessionResult{}, fmt.Errorf("Claude Code session requires threadId")
	}
	if input.Cwd == "" {
		return provider.StartSessionResult{}, fmt.Errorf("Claude Code session requires cwd")
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
	resuming := nativeID != ""
	if nativeID == "" {
		nativeID = newSessionUUID()
	}

	session := newClaudeSession(input.ThreadID, nativeID, input.Cwd)
	session.additionalDirs = append([]string(nil), input.AdditionalDirectories...)
	session.model, session.effort, session.permissionMode = modelEffortAndMode(input.ModelSelection, input.ConfigSelections)

	var replay []provider.RuntimeEvent
	historyUnavailable := false
	if input.ReplayHistory {
		transcript, err := h.readTranscript(session.cwd, nativeID)
		if err != nil {
			historyUnavailable = true
		} else {
			replay = replayEventsFromTranscript(input.ThreadID, transcript)
		}
	}

	h.mu.Lock()
	previous := h.sessionsByLocal[input.ThreadID]
	h.bindSessionLocked(session)
	h.mu.Unlock()
	rollback := func() {
		h.mu.Lock()
		if h.sessionsByLocal[input.ThreadID] == session {
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

	if err := h.spawnProcess(ctx, session, resuming); err != nil {
		rollback()
		return provider.StartSessionResult{}, err
	}

	skills := h.scanSkills(session.cwd)
	h.mu.Lock()
	options := h.configOptionsLocked(session.model, session.effort, session.permissionMode)
	session.skills = skills
	session.configOptions = options
	commands := slashCommandsFromSDK(h.commands)
	providerSession := h.providerSessionLocked(session)
	h.mu.Unlock()

	result := provider.StartSessionResult{Session: providerSession, HistoryUnavailable: historyUnavailable}
	metadata := provider.RuntimeEvent{
		EventID:  provider.RuntimeEventID("claude:meta:" + input.ThreadID + ":start"),
		Type:     provider.RuntimeEventThreadMetadataUpdate,
		ThreadID: input.ThreadID,
		Payload:  provider.RuntimeEventPayload{SlashCommands: commands, Skills: skills},
	}
	if input.ReplayHistory {
		// Same-thread setup events must ride the replay batch, never the live
		// sink, so a failed start cannot leak partial state.
		result.Replay = append(replay, metadata)
	} else {
		h.emitEvent(metadata)
	}
	return result, nil
}

// spawnProcess launches the per-thread CLI process. Callers must have bound
// the session already; stream callbacks fence on the process pointer so a
// stale process can never mutate a successor's state.
func (h *Instance) spawnProcess(ctx context.Context, session *claudeSession, resume bool) error {
	extra := []string{
		"--include-partial-messages",
		// Echoes each written message when the CLI takes it into a query,
		// which is how a steer is known to have joined the running turn.
		"--replay-user-messages",
		"--permission-prompt-tool", "stdio",
		// Enables bypassPermissions as a selectable mode without turning it
		// on: the mode still has to be chosen explicitly by the user.
		"--allow-dangerously-skip-permissions",
	}
	if resume && h.transcriptExists(session.cwd, session.nativeSessionID) {
		extra = append(extra, "--resume", session.nativeSessionID)
	} else {
		extra = append(extra, "--session-id", session.nativeSessionID)
	}
	if model := strings.TrimSpace(session.model); model != "" && model != "default" {
		extra = append(extra, "--model", model)
	}
	// "default" means model-selected effort, which is the CLI's behaviour
	// without the flag; it is not a value --effort accepts.
	if effort := strings.TrimSpace(session.effort); effort != "" && effort != "default" {
		extra = append(extra, "--effort", effort)
	}
	if mode := launchPermissionMode(session.permissionMode); mode != "" {
		extra = append(extra, "--permission-mode", mode)
	}
	for _, dir := range session.additionalDirs {
		if strings.TrimSpace(dir) != "" {
			extra = append(extra, "--add-dir", dir)
		}
	}

	command := h.buildCommand(session.cwd, extra)
	stdin, err := command.StdinPipe()
	if err != nil {
		return fmt.Errorf("open Claude Code stdin: %w", err)
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return fmt.Errorf("open Claude Code stdout: %w", err)
	}
	if err := command.Start(); err != nil {
		_ = stdin.Close()
		_ = stdout.Close()
		return fmt.Errorf("start Claude Code CLI: %w", err)
	}
	proc := &sessionProcess{cmd: command, stdin: stdin, effort: session.effort, done: make(chan struct{})}
	proc.client = newStreamClient(stdout, stdin)
	proc.client.onMessage = func(message sdkMessage) { h.handleMessage(session, proc, message) }
	proc.client.onControlRequest = func(requestID string, request controlRequestBody, raw json.RawMessage) {
		h.handleControlRequest(session, proc, requestID, request, raw)
	}
	proc.client.onControlCancel = func(requestID string) { h.handleControlCancel(requestID) }
	h.mu.Lock()
	session.proc = proc
	h.mu.Unlock()
	go h.waitProcess(session, proc)

	// The initialize handshake answers before any API call and refreshes the
	// cwd-scoped command list plus account/model catalog.
	var initResponse initializeResponse
	if err := proc.client.control(ctx, map[string]any{"subtype": "initialize"}, &initResponse); err != nil {
		h.stopProcess(session)
		return fmt.Errorf("initialize Claude Code session: %w", err)
	}
	h.mu.Lock()
	if len(initResponse.Commands) > 0 {
		h.commands = initResponse.Commands
	}
	if len(initResponse.Models) > 0 {
		h.models = initResponse.Models
	}
	h.updateAccountLocked(initResponse.Account)
	h.mu.Unlock()
	// An explicit "default" mode selection cannot ride the launch flag; apply
	// it through the control protocol instead.
	if session.permissionMode == "default" {
		_ = proc.client.control(ctx, map[string]any{"subtype": "set_permission_mode", "mode": "default"}, nil)
	}
	return nil
}

func (h *Instance) waitProcess(session *claudeSession, proc *sessionProcess) {
	err := proc.cmd.Wait()
	h.mu.Lock()
	proc.reaped = true
	killed := proc.killedTree
	proc.killedTree = true
	closing := proc.closing
	var endedTurn string
	if session.proc == proc {
		session.proc = nil
		endedTurn = session.activeLocalTurn
		session.endTurnLocked()
		session.resetStreamStateLocked()
	}
	h.mu.Unlock()
	if !killed {
		procgroup.Kill(proc.cmd)
	}
	proc.client.fail(firstError(err, io.EOF))
	h.cancelApprovalsForClient(proc.client)
	// The process is gone, so no result will end its turn. Settle it here on
	// every exit path, deliberate stops included, before stopProcess returns.
	if endedTurn != "" {
		payload := provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnInterrupted}
		if !closing {
			payload = provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnFailed, Message: "Claude Code process exited unexpectedly"}
		}
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventTurnCompleted, ThreadID: session.localThreadID, TurnID: endedTurn, Payload: payload})
	}
	close(proc.done)
}

// stopProcess tears down a session's CLI process if one is running and
// returns once waitProcess has retired it.
func (h *Instance) stopProcess(session *claudeSession) {
	h.mu.Lock()
	proc := session.proc
	if proc == nil {
		h.mu.Unlock()
		return
	}
	proc.closing = true
	shouldKill := !proc.reaped && !proc.killedTree
	if shouldKill {
		proc.killedTree = true
	}
	h.mu.Unlock()
	_ = proc.stdin.Close()
	if shouldKill {
		procgroup.Kill(proc.cmd)
	}
	<-proc.done
}

// SendTurn writes one user message to the session's CLI. A new turn starts
// when the CLI is idle, or replaces a turn the CLI started on its own; a steer
// joins the running turn and the CLI picks the boundary.
func (h *Instance) SendTurn(ctx context.Context, input provider.SendTurnInput) error {
	session, err := h.sessionForLocal(input.ThreadID)
	if err != nil {
		return err
	}
	h.mu.Lock()
	if err := sendConflictLocked(session, input); err != nil {
		h.mu.Unlock()
		return err
	}
	proc := session.proc
	model := session.model
	// Effort is a launch flag with no in-session control message: an idle
	// process launched with another effort is relaunched for this turn.
	relaunch := proc != nil && proc.effort != session.effort && session.activeLocalTurn == ""
	h.mu.Unlock()
	if relaunch {
		h.stopProcess(session)
		proc = nil
	}
	if proc == nil {
		if err := h.spawnProcess(ctx, session, true); err != nil {
			return err
		}
		h.mu.Lock()
		proc = session.proc
		h.mu.Unlock()
		if proc == nil {
			return fmt.Errorf("Claude Code process for thread %q exited during start", input.ThreadID)
		}
	}
	if !input.Steer && input.ModelSelection != nil && input.ModelSelection.Model != "" && input.ModelSelection.Model != model {
		if err := h.applyModel(ctx, session, input.ModelSelection.Model); err != nil {
			return err
		}
	}
	content, err := userContentBlocks(input)
	if err != nil {
		return err
	}
	uuid := newSessionUUID()

	h.mu.Lock()
	// The turn can end, or the CLI can start one, while the process spawns.
	if err := sendConflictLocked(session, input); err != nil {
		h.mu.Unlock()
		return err
	}
	// Once the turn is recorded, waitProcess ends it if the process exits; a
	// process that already exited would leave it running.
	if session.proc != proc {
		h.mu.Unlock()
		return fmt.Errorf("Claude Code process for thread %q exited during send", input.ThreadID)
	}
	busy := session.activeLocalTurn != ""
	replaced := ""
	if busy {
		if session.unechoedInput == nil {
			session.unechoedInput = make(map[string]bool)
		}
		session.unechoedInput[uuid] = true
		if !input.Steer {
			replaced = session.activeLocalTurn // the CLI's own turn ends where the user's begins
		}
	}
	if !input.Steer {
		session.activeLocalTurn = input.TurnID
		session.cliStartedTurn = false
	}
	nativeID := session.nativeSessionID
	h.mu.Unlock()

	message := map[string]any{
		"type":               "user",
		"uuid":               uuid,
		"session_id":         nativeID,
		"parent_tool_use_id": nil,
		"message": map[string]any{
			"role":    "user",
			"content": content,
		},
	}
	if busy {
		// The CLI is mid-query: the message waits for its next boundary.
		message["priority"] = "next"
	}
	// A failed write means the process is exiting; waitProcess ends the turn.
	if err := proc.client.send(message); err != nil {
		return err
	}
	if input.Steer {
		return nil
	}
	if replaced != "" {
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventTurnCompleted, ThreadID: input.ThreadID, TurnID: replaced, Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnCompleted}})
	}
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventTurnStarted, ThreadID: input.ThreadID, TurnID: input.TurnID})
	return nil
}

// sendConflictLocked rejects a steer whose turn is no longer running and a
// new turn while the user's previous one still runs.
func sendConflictLocked(session *claudeSession, input provider.SendTurnInput) error {
	switch {
	case input.Steer && session.activeLocalTurn != input.TurnID:
		return fmt.Errorf("Claude Code thread %q has no running turn %q to steer", session.localThreadID, input.TurnID)
	case !input.Steer && session.activeLocalTurn != "" && !session.cliStartedTurn:
		return fmt.Errorf("Claude Code thread %q already has a running turn", session.localThreadID)
	}
	return nil
}

func (h *Instance) InterruptTurn(ctx context.Context, input provider.InterruptTurnInput) error {
	session, err := h.sessionForLocal(input.ThreadID)
	if err != nil {
		return err
	}
	h.mu.Lock()
	proc := session.proc
	active := session.activeLocalTurn
	// cancel_queued drops the steers the CLI has not folded in yet, so the
	// aborted result ends the turn instead of waiting for their query.
	session.unechoedInput = nil
	h.mu.Unlock()
	if proc == nil || active == "" {
		return fmt.Errorf("Claude Code thread %q has no active turn", input.ThreadID)
	}
	return proc.client.control(ctx, map[string]any{"subtype": "interrupt", "cancel_queued": true}, nil)
}

func (h *Instance) StopSession(ctx context.Context, input provider.StopSessionInput) error {
	h.mu.Lock()
	session := h.sessionsByLocal[input.ThreadID]
	if session == nil {
		h.mu.Unlock()
		return nil
	}
	proc := session.proc
	active := session.activeLocalTurn
	h.mu.Unlock()
	if proc != nil && active != "" {
		if err := proc.client.control(ctx, map[string]any{"subtype": "interrupt", "cancel_queued": true}, nil); err != nil {
			h.mu.Lock()
			stillActive := h.sessionsByLocal[input.ThreadID] == session && session.activeLocalTurn == active && session.proc == proc
			h.mu.Unlock()
			if stillActive {
				h.logger.Debug("interrupt during stop", "error", err)
			}
		}
	}
	h.stopProcess(session)
	h.mu.Lock()
	if h.sessionsByLocal[input.ThreadID] == session {
		delete(h.sessionsByLocal, input.ThreadID)
		if h.localByNative[session.nativeSessionID] == input.ThreadID {
			delete(h.localByNative, session.nativeSessionID)
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
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRequestResolved, ThreadID: pending.localThread, TurnID: pending.localTurn, RequestID: pending.requestID, Payload: provider.RuntimeEventPayload{RequestType: pending.requestType, Decision: provider.ApprovalDecisionCancel, Cancelled: true}})
	}
	return nil
}

func (h *Instance) SetConfigOption(ctx context.Context, input provider.SetConfigOptionInput) error {
	session, err := h.sessionForLocal(input.ThreadID)
	if err != nil {
		return err
	}
	value, ok := input.Value.(string)
	if !ok {
		return fmt.Errorf("Claude Code config option %q requires a string value", input.OptionID)
	}
	switch input.OptionID {
	case "model":
		if err := h.applyModel(ctx, session, value); err != nil {
			return err
		}
	case "effort":
		h.mu.Lock()
		options := h.configOptionsLocked(session.model, value, session.permissionMode)
		current, present := provider.CurrentConfigString(options, "effort")
		if !present || current != value {
			h.mu.Unlock()
			return fmt.Errorf("Claude Code config option %q does not accept value %q", input.OptionID, value)
		}
		// Applied when the next turn starts (see SendTurn).
		session.effort = value
		h.mu.Unlock()
	case "permission_mode":
		if !validPermissionMode(value) {
			return fmt.Errorf("Claude Code config option %q does not accept value %q", input.OptionID, value)
		}
		h.mu.Lock()
		proc := session.proc
		h.mu.Unlock()
		if proc != nil {
			if err := proc.client.control(ctx, map[string]any{"subtype": "set_permission_mode", "mode": value}, nil); err != nil {
				return err
			}
		}
		h.mu.Lock()
		session.permissionMode = value
		h.mu.Unlock()
	default:
		return fmt.Errorf("Claude Code config option %q is not supported", input.OptionID)
	}
	h.mu.Lock()
	session.configOptions = h.configOptionsLocked(session.model, session.effort, session.permissionMode)
	snapshot := append([]provider.ConfigOption(nil), session.configOptions...)
	h.mu.Unlock()
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventConfigOptionsUpdated, ThreadID: input.ThreadID, Payload: provider.RuntimeEventPayload{ConfigOptions: snapshot}})
	return nil
}

// applyModel validates a model switch and applies it in-session when a
// process is live. It takes h.mu itself.
func (h *Instance) applyModel(ctx context.Context, session *claudeSession, model string) error {
	h.mu.Lock()
	valid := modelValueValid(h.models, model)
	proc := session.proc
	h.mu.Unlock()
	if !valid {
		return fmt.Errorf("Claude Code model %q is not available", model)
	}
	if proc != nil {
		payload := map[string]any{"subtype": "set_model", "model": model}
		if model == "default" {
			payload["model"] = nil
		}
		if err := proc.client.control(ctx, payload, nil); err != nil {
			return err
		}
	}
	h.mu.Lock()
	session.model = model
	h.mu.Unlock()
	return nil
}

// providerSessionLocked snapshots the public projection of one live binding.
func (h *Instance) providerSessionLocked(session *claudeSession) provider.Session {
	resumeCursor, _ := json.Marshal(session.nativeSessionID)
	return provider.Session{
		Provider:              DriverKind,
		ProviderInstanceID:    h.info.InstanceID,
		ProviderSessionID:     session.nativeSessionID,
		ProviderName:          h.info.Name,
		Cwd:                   session.cwd,
		AdditionalDirectories: append([]string(nil), session.additionalDirs...),
		ThreadID:              session.localThreadID,
		ResumeCursor:          resumeCursor,
		ConfigOptions:         append([]provider.ConfigOption(nil), session.configOptions...),
		Skills:                append([]provider.Skill(nil), session.skills...),
	}
}

func (s *claudeSession) endTurnLocked() {
	s.activeLocalTurn = ""
	s.cliStartedTurn = false
	s.unechoedInput = nil
}

func (s *claudeSession) resetStreamStateLocked() {
	s.toolStates = make(map[string]*toolState)
	s.openBlocks = make(map[int]string)
	s.streamedText = make(map[string]string)
}

func modelEffortAndMode(selection *provider.ModelSelection, selections []provider.ConfigOptionSelection) (string, string, string) {
	model, effort, mode := "", "", ""
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
		case "effort":
			effort = value
		case "permission_mode":
			mode = value
		}
	}
	return model, effort, mode
}

// launchPermissionMode maps a selected mode to a value the --permission-mode
// launch flag accepts. "default" is control-protocol-only and returns "".
func launchPermissionMode(mode string) string {
	switch mode {
	case "acceptEdits", "auto", "bypassPermissions", "plan", "dontAsk":
		return mode
	default:
		return ""
	}
}

func validPermissionMode(mode string) bool {
	switch mode {
	case "default", "acceptEdits", "auto", "bypassPermissions", "plan", "dontAsk":
		return true
	default:
		return false
	}
}

// newSessionUUID returns a random version 4 UUID; crypto/rand.Read never fails.
func newSessionUUID() string {
	var raw [16]byte
	_, _ = rand.Read(raw[:])
	raw[6] = (raw[6] & 0x0f) | 0x40
	raw[8] = (raw[8] & 0x3f) | 0x80
	encoded := hex.EncodeToString(raw[:])
	return strings.Join([]string{encoded[0:8], encoded[8:12], encoded[12:16], encoded[16:20], encoded[20:32]}, "-")
}

// probeTimeout bounds the OpenInstance handshake when the caller supplied no
// deadline of its own.
const probeTimeout = 30 * time.Second
