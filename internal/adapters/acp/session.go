// Session lifecycle for the ACP adapter: materializing the ACP session
// behind a thread (in-process reuse -> session/load / session/resume ->
// session/new), the session-management surface (session/list, /delete,
// /close), and per-session configuration state (config options, modes,
// model/mode preference application).
package acp

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	acp "github.com/Aqothy/go-acp"
	"github.com/Aqothy/go-acp/schema"
	"github.com/Aqothy/maiD/internal/provider"
)

// acpSession owns all per-session state for one live ACP session binding: the
// thread route, the ordered update stream, the registered turn, cached
// config/modes, the item-id scope, per-item tool reconciliation state, the
// load-replay flag, and pending permission requests. Unbinding a session is
// deleting this one entry (plus the thread index). All fields are guarded by
// Instance.mu.
type acpSession struct {
	id       string
	threadID string
	stream   *sessionStream
	// collector is the registered (newest) turn on the session; the in-flight
	// prompt's collector may lag it while a follow-up turn is queued (see
	// updateCollectorLocked).
	collector *promptCollector
	// scope prefixes ACP item ids before orchestration sees them; random so a
	// re-materialized session can never collide with an earlier binding.
	scope string
	// config/hasConfig cache the session's config options; hasConfig
	// distinguishes an explicit empty option set from "agent uses Session
	// Modes instead" (modes).
	config    []provider.ConfigOption
	hasConfig bool
	modes     *schema.SessionModeState
	// replayEvents is non-nil while session/load is collecting its ordered
	// update stream. StartSession returns the complete batch for display restore
	// and discards it for ordinary process recovery.
	replayEvents       []provider.RuntimeEvent
	toolStates         map[string]toolState
	pendingPermissions map[string]*pendingPermission
}

// sessionLocked returns the session struct for an ACP session id. h.mu must be
// held. Returns nil for unbound sessions — callers must treat that as "state
// must not be re-created" (stray updates can drain from a disposed stream
// after unbind).
func (h *Instance) sessionLocked(sessionID string) *acpSession {
	return h.sessions[sessionID]
}

func (h *Instance) sessionForThreadLocked(threadID string) *acpSession {
	sessionID := h.sessionsByThread[threadID]
	if sessionID == "" {
		return nil
	}
	return h.sessions[sessionID]
}

// StartSession resolves the ACP session backing a thread:
//
//  1. In-process resume — if this thread already has a live ACP session on this
//     connection, reuse it. An ACP session lives for the whole connection, so a
//     turn error/interrupt/re-start does NOT need a new session; only StopSession
//     unbinds.
//  2. Display restore — ReplayHistory prefers session/load and returns its replay.
//  3. Ordinary recovery — prefer session/resume, otherwise session/load while
//     dropping replay because orchestration already has the projection.
//  4. Otherwise create a new session.
func (h *Instance) StartSession(ctx context.Context, input provider.StartSessionInput) (provider.StartSessionResult, error) {
	if input.ThreadID == "" {
		return provider.StartSessionResult{}, fmt.Errorf("provider session start requires threadId")
	}

	if existing := h.sessionIDForThread(input.ThreadID); existing != "" {
		// StartSession is called before every prompt; once a thread has a live ACP
		// session, its provider-side config options are authoritative. Reapplying
		// runtime/default mode aliases here would overwrite user-selected options.
		// The stored model preference is best-effort here for the same reason the
		// new/load/resume paths downgrade it to a warning: failing hard would
		// brick the thread with the same error on every subsequent prompt.
		h.applyModelSelectionPreference(ctx, existing, input)
		return h.startWithoutHistory(input, h.sessionProjection(input, existing)), nil
	}

	if sessionID := resumeSessionID(input.ResumeCursor); sessionID != "" {
		if input.ReplayHistory {
			if h.supportsLoadSession() {
				if result, err := h.loadSession(ctx, input, sessionID); err == nil {
					return result, nil
				} else if !sessionNotFoundError(err) {
					return provider.StartSessionResult{}, err
				}
			}
			if h.supportsResumeSession() {
				if session, err := h.resumeSession(ctx, input, sessionID); err == nil {
					return h.startWithoutHistory(input, session), nil
				} else if !sessionNotFoundError(err) {
					return provider.StartSessionResult{}, err
				}
			}
		} else {
			if h.supportsResumeSession() {
				if session, err := h.resumeSession(ctx, input, sessionID); err == nil {
					return provider.StartSessionResult{Session: session}, nil
				} else if !sessionNotFoundError(err) {
					return provider.StartSessionResult{}, err
				}
			}
			if h.supportsLoadSession() {
				if result, err := h.loadSession(ctx, input, sessionID); err == nil {
					result.Replay = nil
					return result, nil
				} else if !sessionNotFoundError(err) {
					return provider.StartSessionResult{}, err
				}
			}
		}
		// Prior session is gone: fall through and create a fresh one. Other
		// load failures (auth/cwd/transport/transient) are surfaced so callers
		// do not silently lose provider context.
	}

	resp, err := h.agent().NewSession(ctx, schema.NewSessionRequest{CWD: input.Cwd, MCPServers: []schema.McpServer{}})
	if err != nil {
		return provider.StartSessionResult{}, acpRequestError(err)
	}
	if resp.SessionID == "" {
		return provider.StartSessionResult{}, fmt.Errorf("ACP session/new returned an empty session id")
	}
	sessionID := string(resp.SessionID)
	h.bindSession(input.ThreadID, sessionID)
	h.ensureSessionStream(sessionID)
	h.cacheSessionState(sessionID, resp.ConfigOptions, resp.Modes)
	h.applyInitialSessionPreferences(ctx, sessionID, input)
	return h.startWithoutHistory(input, h.sessionProjection(input, sessionID)), nil
}

func (h *Instance) startWithoutHistory(input provider.StartSessionInput, session provider.Session) provider.StartSessionResult {
	return provider.StartSessionResult{Session: session, HistoryUnavailable: input.ReplayHistory}
}

// loadSession resumes a prior ACP session via session/load. The thread->session
// route is bound and the session stream attached BEFORE awaiting the load so
// replayed session/update notifications resolve to this session. A barrier
// marker pushed after the load resolves marks the end of replay in-stream.
func (h *Instance) loadSession(ctx context.Context, input provider.StartSessionInput, sessionID string) (provider.StartSessionResult, error) {
	h.bindSession(input.ThreadID, sessionID)
	stream, _ := h.ensureSessionStream(sessionID)
	h.beginSessionLoad(sessionID)
	resp, err := h.agent().LoadSession(ctx, schema.LoadSessionRequest{SessionID: schema.SessionId(sessionID), CWD: input.Cwd, MCPServers: []schema.McpServer{}})
	if err != nil {
		h.unbindSessionID(sessionID)
		return provider.StartSessionResult{}, acpRequestError(err)
	}
	// Drain load replay before applying preferences, but keep capture active:
	// preference requests can themselves emit config updates or warnings and
	// those setup events must not overtake the returned history batch.
	if err := h.awaitSessionBarrier(ctx, stream, nil); err != nil {
		h.unbindSessionID(sessionID)
		return provider.StartSessionResult{}, fmt.Errorf("await ACP session/load replay drain: %w", err)
	}
	h.cacheSessionState(sessionID, resp.ConfigOptions, resp.Modes)
	h.applyInitialSessionPreferences(ctx, sessionID, input)
	var replay []provider.RuntimeEvent
	if err := h.awaitSessionBarrier(ctx, stream, func() { replay = h.finishSessionLoad(sessionID) }); err != nil {
		h.unbindSessionID(sessionID)
		return provider.StartSessionResult{}, fmt.Errorf("await ACP session setup drain: %w", err)
	}
	return provider.StartSessionResult{Session: h.sessionProjection(input, sessionID), Replay: replay}, nil
}

func (h *Instance) beginSessionLoad(sessionID string) {
	h.mu.Lock()
	if session := h.sessionLocked(sessionID); session != nil {
		session.replayEvents = make([]provider.RuntimeEvent, 0)
	}
	h.mu.Unlock()
}

func (h *Instance) finishSessionLoad(sessionID string) []provider.RuntimeEvent {
	var events []provider.RuntimeEvent
	h.mu.Lock()
	if session := h.sessionLocked(sessionID); session != nil {
		events = session.replayEvents
		session.replayEvents = nil
	}
	h.mu.Unlock()
	return events
}

// sessionNotFoundError reports whether the agent said the session no longer
// exists (ACP Resource not found, -32002). It is the trigger for every
// stale-session fallback: resume->load->new during StartSession, and unbinding a
// live-bound session whose prompt the agent rejected.
func sessionNotFoundError(err error) bool {
	var providerErr *provider.RequestError
	return errors.As(acpRequestError(err), &providerErr) && int64(providerErr.Code) == acp.CodeResourceNotFound
}

const acpSessionModeOptionID = "acp.session-mode"

func (h *Instance) cacheSessionState(sessionID string, configOptions []schema.SessionConfigOption, modes *schema.SessionModeState) {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessionLocked(sessionID)
	if session == nil {
		// A stray config_option_update draining from a disposed stream must
		// not re-materialize state for an unbound session.
		return
	}
	// Config options supersede Session Modes when both are supplied.
	if configOptions != nil {
		session.config = configOptionsFromACP(configOptions)
		session.hasConfig = true
		session.modes = nil
		return
	}
	session.config = nil
	session.hasConfig = false
	session.modes = nil
	if modes != nil {
		state := *modes
		state.AvailableModes = append([]schema.SessionMode(nil), modes.AvailableModes...)
		session.modes = &state
	}
}

func (h *Instance) combinedConfigOptions(sessionID string) []provider.ConfigOption {
	h.mu.Lock()
	session := h.sessionLocked(sessionID)
	var options []provider.ConfigOption
	present := false
	var modes schema.SessionModeState
	hasModes := false
	if session != nil {
		options, present = session.config, session.hasConfig
		if session.modes != nil {
			modes, hasModes = *session.modes, true
		}
	}
	h.mu.Unlock()
	if present {
		return append([]provider.ConfigOption{}, options...)
	}
	if !hasModes {
		return nil
	}
	choices := make([]provider.ConfigChoice, 0, len(modes.AvailableModes))
	for _, mode := range modes.AvailableModes {
		choices = append(choices, provider.ConfigChoice{Value: string(mode.ID), Label: mode.Name})
	}
	return []provider.ConfigOption{{ID: acpSessionModeOptionID, Type: provider.ConfigOptionTypeSelect, Category: provider.ConfigOptionCategoryMode, Label: "Mode", Choices: choices, CurrentValue: string(modes.CurrentModeID)}}
}

func (h *Instance) sessionProjection(input provider.StartSessionInput, sessionID string) provider.Session {
	info := h.Info()
	return provider.Session{
		Provider:           DriverKind,
		ProviderInstanceID: info.InstanceID,
		ProviderSessionID:  sessionID,
		ProviderName:       info.Name,
		Cwd:                input.Cwd,
		ThreadID:           input.ThreadID,
		ResumeCursor:       marshalRaw(map[string]string{"sessionId": sessionID}),
		ConfigOptions:      h.combinedConfigOptions(sessionID),
	}
}

func (h *Instance) StopSession(ctx context.Context, input provider.StopSessionInput) error {
	sessionID := h.sessionIDForThread(input.ThreadID)
	if sessionID == "" {
		return nil
	}
	h.mu.Lock()
	session := h.sessionLocked(sessionID)
	idle := session != nil && session.collector == nil && (session.stream == nil || (session.stream.active == nil && len(session.stream.queued) == 0))
	h.mu.Unlock()
	if idle {
		if h.sessionCapabilities().Close != nil {
			if _, err := h.agent().CloseSession(ctx, schema.CloseSessionRequest{SessionID: schema.SessionId(sessionID)}); err != nil {
				return acpRequestError(err)
			}
		}
		h.unbindSessionID(sessionID)
		return nil
	}
	if err := h.agent().Cancel(ctx, schema.CancelNotification{SessionID: schema.SessionId(sessionID)}); err != nil {
		// Keep both the binding and live turn state so callers can retry
		// cancellation without the adapter reporting a cancellation that the
		// agent never received.
		return acpRequestError(err)
	}
	cancels, _, dropped, stream := h.markPromptCancelled(sessionID, "")
	for _, cancel := range cancels {
		cancel()
	}
	if dropped != nil {
		h.settlePrompt(stream, dropped, schema.PromptResponse{}, nil)
	}
	h.unbindSessionID(sessionID)
	return nil
}

// ACP session-management calls are capability-gated; unsupported methods fail
// without contacting the agent. session/fork remains unstable and unsupported.
func (h *Instance) ListSessions(ctx context.Context, cwd string) ([]provider.SessionSummary, error) {
	if h.sessionCapabilities().List == nil {
		return nil, fmt.Errorf("ACP agent does not advertise session/list support")
	}
	req := schema.ListSessionsRequest{}
	if cwd != "" {
		req.CWD = &cwd
	}
	var sessions []provider.SessionSummary
	seenCursors := make(map[string]struct{})
	for {
		resp, err := h.agent().ListSessions(ctx, req)
		if err != nil {
			return nil, acpRequestError(err)
		}
		sessions = append(sessions, sessionSummariesFromACP(resp.Sessions)...)
		if resp.NextCursor == nil || *resp.NextCursor == "" {
			return sessions, nil
		}
		if _, seen := seenCursors[*resp.NextCursor]; seen {
			return nil, fmt.Errorf("ACP session/list repeated cursor %q", *resp.NextCursor)
		}
		seenCursors[*resp.NextCursor] = struct{}{}
		cursor := *resp.NextCursor
		req.Cursor = &cursor
	}
}

func (h *Instance) DeleteSession(ctx context.Context, sessionID string) error {
	if h.sessionCapabilities().Delete == nil {
		return fmt.Errorf("ACP agent does not advertise session/delete support")
	}
	if threadID := h.threadIDForSession(sessionID); threadID != "" {
		return fmt.Errorf("cannot delete ACP session %q while it is bound to thread %q", sessionID, threadID)
	}
	if _, err := h.agent().DeleteSession(ctx, schema.DeleteSessionRequest{SessionID: schema.SessionId(sessionID)}); err != nil {
		return acpRequestError(err)
	}
	h.unbindSessionID(sessionID)
	return nil
}

func (h *Instance) CloseSession(ctx context.Context, sessionID string) error {
	if h.sessionCapabilities().Close == nil {
		return fmt.Errorf("ACP agent does not advertise session/close support")
	}
	if threadID := h.threadIDForSession(sessionID); threadID != "" {
		return fmt.Errorf("cannot close ACP session %q while it is bound to thread %q", sessionID, threadID)
	}
	if _, err := h.agent().CloseSession(ctx, schema.CloseSessionRequest{SessionID: schema.SessionId(sessionID)}); err != nil {
		return acpRequestError(err)
	}
	h.unbindSessionID(sessionID)
	return nil
}

func (h *Instance) resumeSession(ctx context.Context, input provider.StartSessionInput, sessionID string) (provider.Session, error) {
	if input.ThreadID == "" {
		return provider.Session{}, fmt.Errorf("provider session resume requires threadId")
	}
	// Bind and attach the session stream before awaiting session/resume so any
	// in-flight session/update notifications can be routed to the thread,
	// matching the session/load replay barrier.
	h.bindSession(input.ThreadID, sessionID)
	stream, _ := h.ensureSessionStream(sessionID)
	resp, err := h.agent().ResumeSession(ctx, schema.ResumeSessionRequest{SessionID: schema.SessionId(sessionID), CWD: input.Cwd, MCPServers: []schema.McpServer{}})
	if err != nil {
		h.unbindSessionID(sessionID)
		return provider.Session{}, acpRequestError(err)
	}
	// Drain any updates the agent emitted before resolving the resume, so they
	// are delivered (routed to the thread) before the session is reported ready.
	if err := h.awaitSessionBarrier(ctx, stream, nil); err != nil {
		h.unbindSessionID(sessionID)
		return provider.Session{}, fmt.Errorf("await ACP session/resume drain: %w", err)
	}
	h.cacheSessionState(sessionID, resp.ConfigOptions, resp.Modes)
	h.applyInitialSessionPreferences(ctx, sessionID, input)
	return h.sessionProjection(input, sessionID), nil
}

func (h *Instance) agentCapabilities() schema.AgentCapabilities {
	h.mu.Lock()
	defer h.mu.Unlock()
	return agentCapabilitiesValue(h.initialize.AgentCapabilities)
}

func (h *Instance) sessionCapabilities() schema.SessionCapabilities {
	capabilities := h.agentCapabilities()
	if capabilities.SessionCapabilities == nil {
		return schema.SessionCapabilities{}
	}
	return *capabilities.SessionCapabilities
}

func (h *Instance) supportsLoadSession() bool {
	return boolValue(h.agentCapabilities().LoadSession)
}

func (h *Instance) supportsResumeSession() bool {
	return h.sessionCapabilities().Resume != nil
}

// unbindSessionLocked drops the session's entire state — one sessions entry
// plus the thread index — and marks its stream disposed. h.mu must be held;
// the caller disposes the returned stream outside the lock.
func (h *Instance) unbindSessionLocked(sessionID string) *sessionStream {
	session := h.sessionLocked(sessionID)
	if session == nil {
		return nil
	}
	delete(h.sessions, sessionID)
	if session.threadID != "" && h.sessionsByThread[session.threadID] == sessionID {
		delete(h.sessionsByThread, session.threadID)
	}
	stream := session.stream
	if stream != nil {
		stream.closed = true
		if stream.closeErr == nil {
			stream.closeErr = errSessionStreamClosed
		}
	}
	return stream
}

func (h *Instance) unbindSessionID(sessionID string) {
	h.mu.Lock()
	stream := h.unbindSessionLocked(sessionID)
	h.mu.Unlock()
	if stream != nil {
		stream.session.Dispose()
	}
}

func (h *Instance) applyInitialSessionPreferences(ctx context.Context, sessionID string, input provider.StartSessionInput) {
	// Model changes may replace the provider's advertised option set, so resolve
	// and apply the model before replaying selections against the refreshed set.
	h.applyModelSelectionPreference(ctx, sessionID, input)
	for _, selection := range input.ConfigSelections {
		if err := h.setSessionConfigOptionValue(ctx, sessionID, selection.OptionID, selection.Value); err != nil {
			h.emitRuntimeEventForSession(sessionID, provider.RuntimeEvent{
				EventID:   provider.RuntimeEventID(newID()),
				Type:      provider.RuntimeEventRuntimeWarning,
				Provider:  DriverKind,
				ThreadID:  input.ThreadID,
				CreatedAt: time.Now(),
				Payload:   provider.RuntimeEventPayload{Message: fmt.Sprintf("config option %q not restored: %v", selection.OptionID, err)},
			})
		}
	}
}

// applyModelSelectionPreference applies the thread's stored model preference
// best-effort: a preference the agent cannot satisfy surfaces as a runtime
// warning instead of failing session materialization (which would fail every
// prompt on the thread). The explicit SetConfigOption command path still fails
// loudly.
func (h *Instance) applyModelSelectionPreference(ctx context.Context, sessionID string, input provider.StartSessionInput) {
	if err := h.applyModelSelection(ctx, sessionID, input.ModelSelection); err != nil {
		h.emitRuntimeEventForSession(sessionID, provider.RuntimeEvent{
			EventID:   provider.RuntimeEventID(newID()),
			Type:      provider.RuntimeEventRuntimeWarning,
			Provider:  DriverKind,
			ThreadID:  input.ThreadID,
			CreatedAt: time.Now(),
			Payload:   provider.RuntimeEventPayload{Message: fmt.Sprintf("model preference not applied to session: %v", err)},
		})
	}
}

func (h *Instance) applyModelSelection(ctx context.Context, sessionID string, selection *provider.ModelSelection) error {
	if selection == nil {
		return nil
	}
	model := strings.TrimSpace(selection.Model)
	if model == "" {
		return nil
	}
	optionID, value, ok := h.resolveModelConfigChoice(sessionID, model)
	if !ok {
		return fmt.Errorf("no ACP model config option matches model %q", model)
	}
	if h.sessionConfigOptionAlreadyCurrent(sessionID, optionID, value) {
		return nil
	}
	return h.setSessionConfigOptionValue(ctx, sessionID, optionID, value)
}

// SetConfigOption sets a session configuration option (model, reasoning level,
// ...) via the stable session/set_config_option method and re-publishes the
// refreshed option set.
func (h *Instance) SetConfigOption(ctx context.Context, input provider.SetConfigOptionInput) error {
	if input.ThreadID == "" || input.OptionID == "" {
		return fmt.Errorf("provider set config option requires threadId and optionId")
	}
	sessionID := h.sessionIDForThread(input.ThreadID)
	if sessionID == "" {
		return fmt.Errorf("thread %q has no ACP session", input.ThreadID)
	}
	if err := h.setSessionConfigOptionValue(ctx, sessionID, input.OptionID, input.Value); err != nil {
		return err
	}
	h.emitConfigOptions(sessionID, h.combinedConfigOptions(sessionID))
	return nil
}

func (h *Instance) setSessionConfigOptionValue(ctx context.Context, sessionID string, optionID string, value any) error {
	if optionID == acpSessionModeOptionID {
		text, ok := value.(string)
		if !ok {
			return fmt.Errorf("ACP session mode %q requires a string value", optionID)
		}
		return h.setSessionModeValue(ctx, sessionID, schema.SessionModeId(text))
	}
	request := schema.SetSessionConfigOptionRequest{
		SessionID: schema.SessionId(sessionID),
		ConfigID:  schema.SessionConfigId(optionID),
		Value:     value,
	}
	switch value.(type) {
	case string:
	case bool:
		optionType := schema.SetSessionConfigOptionRequestTypeBoolean
		request.Type = &optionType
	default:
		return fmt.Errorf("ACP config option %q requires a string or boolean value", optionID)
	}
	resp, err := h.agent().SetSessionConfigOption(ctx, request)
	if err != nil {
		return acpRequestError(err)
	}
	h.cacheSessionState(sessionID, resp.ConfigOptions, nil)
	return nil
}

func (h *Instance) setSessionModeValue(ctx context.Context, sessionID string, modeID schema.SessionModeId) error {
	if _, err := h.agent().SetSessionMode(ctx, schema.SetSessionModeRequest{SessionID: schema.SessionId(sessionID), ModeID: modeID}); err != nil {
		return acpRequestError(err)
	}
	h.mu.Lock()
	if session := h.sessionLocked(sessionID); session != nil && session.modes != nil {
		session.modes.CurrentModeID = modeID
	}
	h.mu.Unlock()
	return nil
}

func (h *Instance) resolveModelConfigChoice(sessionID string, model string) (string, string, bool) {
	return h.resolveConfigChoice(sessionID, provider.ConfigOptionCategoryModel, []string{model})
}

func (h *Instance) resolveConfigChoice(sessionID string, category provider.ConfigOptionCategory, aliases []string) (string, string, bool) {
	var options []provider.ConfigOption
	h.mu.Lock()
	if session := h.sessionLocked(sessionID); session != nil {
		options = append(options, session.config...)
	}
	h.mu.Unlock()
	for _, option := range options {
		if option.Category != category || option.ID == "" {
			continue
		}
		if value, ok := configChoiceValue(option, aliases); ok {
			return option.ID, value, true
		}
	}
	return "", "", false
}

func configChoiceValue(option provider.ConfigOption, aliases []string) (string, bool) {
	for _, alias := range aliases {
		if alias == "" {
			continue
		}
		for _, choice := range option.Choices {
			if strings.EqualFold(choice.Value, alias) || strings.EqualFold(choice.Label, alias) {
				return choice.Value, true
			}
		}
		if current, ok := option.CurrentValue.(string); ok && strings.EqualFold(current, alias) {
			return current, true
		}
	}
	return "", false
}

func (h *Instance) sessionConfigOptionAlreadyCurrent(sessionID string, optionID string, value any) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessionLocked(sessionID)
	if session == nil {
		return false
	}
	for _, option := range session.config {
		if option.ID == optionID && option.CurrentValue == value {
			return true
		}
	}
	return false
}

func (h *Instance) emitConfigOptions(sessionID string, options []provider.ConfigOption) {
	if options == nil {
		options = []provider.ConfigOption{}
	}
	h.emitBoundRuntimeEventForSession(sessionID, provider.RuntimeEvent{
		EventID:   provider.RuntimeEventID(newID()),
		Type:      provider.RuntimeEventConfigOptionsUpdated,
		Provider:  DriverKind,
		CreatedAt: time.Now(),
		Payload:   provider.RuntimeEventPayload{ConfigOptions: options},
	})
}

// bindSession materializes (or re-routes) the session struct for a
// thread↔session binding. Per-session state (scope, tool states, pending
// permissions) lives on the struct, so a fresh binding always starts clean.
func (h *Instance) bindSession(threadID string, sessionID string) {
	h.mu.Lock()
	session := h.sessionLocked(sessionID)
	if session == nil {
		session = &acpSession{
			id:                 sessionID,
			toolStates:         make(map[string]toolState),
			pendingPermissions: make(map[string]*pendingPermission),
		}
		h.sessions[sessionID] = session
	}
	if session.threadID != "" && session.threadID != threadID && h.sessionsByThread[session.threadID] == sessionID {
		delete(h.sessionsByThread, session.threadID)
	}
	session.threadID = threadID
	h.sessionsByThread[threadID] = sessionID
	h.mu.Unlock()
}

func (h *Instance) sessionIDForThread(threadID string) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.sessionsByThread[threadID]
}

func (h *Instance) threadIDForSession(sessionID string) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	if session := h.sessionLocked(sessionID); session != nil {
		return session.threadID
	}
	return ""
}
