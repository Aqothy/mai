// Session lifecycle for the ACP adapter: opening sessions (session/new,
// session/resume, session/load), their history from the mirror, session
// management (session/list, /delete, /close), and per-session configuration
// (config options, modes).
package acp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"
	"time"

	acp "github.com/Aqothy/go-acp"
	"github.com/Aqothy/go-acp/schema"
	"github.com/Aqothy/maiD/internal/provider"
)

// acpSession is one live ACP session: its ordered update stream, its
// mapper, the prompt in flight, cached configuration, pending requests. Fields
// are guarded by Instance.mu, except that record holds recordMu around the
// mapper so a session's events go out in frame order.
type acpSession struct {
	id     string
	stream *sessionStream
	// options is set for an options session, which reports to it instead of
	// emitting events.
	options *provider.OptionsSessionCallbacks

	// config/hasConfig cache the session's config options; hasConfig
	// distinguishes an explicit empty option set from "agent uses Session
	// Modes instead" (modes).
	config    []provider.ConfigOption
	hasConfig bool
	modes     *schema.SessionModeState
	commands  []provider.SlashCommand

	recordMu sync.Mutex
	mapper   *mapper
	// prompt is the turn whose prompt the agent runs; empty when none runs.
	prompt string
	// capture, while non-nil, collects a session/load replay's updates
	// instead of mapping them live.
	capture []json.RawMessage

	pendingPermissions map[string]*pendingPermission
}

// Open opens a session: resumed when the agent can (session/resume, else
// session/load), otherwise a new one.
func (h *Instance) Open(ctx context.Context, in provider.OpenInput) (provider.Opened, error) {
	opened, err := h.open(ctx, in)
	h.noteAuthRequired(err)
	return opened, err
}

func (h *Instance) open(ctx context.Context, in provider.OpenInput) (provider.Opened, error) {
	if in.Workspace.Cwd == "" {
		return provider.Opened{}, fmt.Errorf("ACP session requires a cwd")
	}
	if in.Session != "" {
		if h.live(in.Session) {
			return h.opened(in.Session), nil
		}
		switch err := h.resume(ctx, in); {
		case err == nil:
			h.applySettings(ctx, in.Session, in.Settings)
			return h.opened(in.Session), nil
		case !errors.Is(err, provider.ErrSessionNotFound):
			return provider.Opened{}, err
		}
		// The agent no longer has the session: a new one takes its place.
	}
	// Started, not created then attached: the agent may send the session's
	// commands and modes the moment it answers.
	active, err := h.agentPeer.StartSession(ctx, schema.NewSessionRequest{
		CWD:                   in.Workspace.Cwd,
		AdditionalDirectories: h.supportedAdditionalDirectories(in.Workspace.AdditionalDirectories),
		MCPServers:            h.mcpServers(in.MCP),
	})
	if err != nil {
		return provider.Opened{}, acpRequestError(err)
	}
	resp := active.NewSessionResponse()
	if resp.SessionID == "" {
		active.Dispose()
		return provider.Opened{}, fmt.Errorf("ACP session/new returned an empty session id")
	}
	sessionID := string(resp.SessionID)
	h.attach(sessionID, active, &mapper{}, nil)
	h.cacheSessionState(sessionID, resp.ConfigOptions, resp.Modes)
	h.applySettings(ctx, sessionID, in.Settings)
	return h.opened(sessionID), nil
}

// resume reopens a session the agent kept. Its mapper first replays the
// mirror so it continues where the session's frames left off. Without
// session/resume, session/load replays the conversation, which becomes the
// mirror's frames when there are none yet (a session maiD hasn't seen).
func (h *Instance) resume(ctx context.Context, in provider.OpenInput) error {
	frames, err := h.frames(ctx, in.Session)
	if err != nil {
		return err
	}
	restored, _ := history(frames)
	request := struct {
		cwd         string
		directories []string
		mcp         []schema.McpServer
	}{in.Workspace.Cwd, h.supportedAdditionalDirectories(in.Workspace.AdditionalDirectories), h.mcpServers(in.MCP)}
	if h.sessionCapabilities().Resume != nil {
		stream := h.attach(in.Session, nil, restored, nil)
		resp, err := h.agentPeer.ResumeSession(ctx, schema.ResumeSessionRequest{SessionID: schema.SessionId(in.Session), CWD: request.cwd, AdditionalDirectories: request.directories, MCPServers: request.mcp})
		if err == nil {
			// Updates the agent sent before answering are delivered first.
			err = h.awaitSessionBarrier(ctx, stream, nil)
		}
		if err != nil {
			h.detach(in.Session)
			return sessionError(err)
		}
		h.cacheSessionState(in.Session, resp.ConfigOptions, resp.Modes)
		return nil
	}
	if !h.supportsLoadSession() {
		return provider.ErrSessionNotFound
	}
	baseline := len(frames) == 0
	if err := h.load(ctx, in.Session, request.cwd, request.directories, request.mcp, baseline); err != nil {
		return err
	}
	if !baseline {
		h.mu.Lock()
		if session := h.sessions[in.Session]; session != nil {
			session.mapper = restored
		}
		h.mu.Unlock()
	}
	return nil
}

// load runs session/load. With baseline its replay becomes the session's
// first frames; otherwise the mirror already holds them and the replay is
// dropped.
func (h *Instance) load(ctx context.Context, sessionID, cwd string, directories []string, servers []schema.McpServer, baseline bool) error {
	stream := h.attach(sessionID, nil, &mapper{}, []json.RawMessage{})
	resp, err := h.agentPeer.LoadSession(ctx, schema.LoadSessionRequest{SessionID: schema.SessionId(sessionID), CWD: cwd, AdditionalDirectories: directories, MCPServers: servers})
	var replay []json.RawMessage
	if err == nil {
		err = h.awaitSessionBarrier(ctx, stream, func() {
			h.mu.Lock()
			if session := h.sessions[sessionID]; session != nil {
				replay, session.capture = session.capture, nil
			}
			h.mu.Unlock()
		})
	}
	if err != nil {
		h.detach(sessionID)
		return sessionError(err)
	}
	h.cacheSessionState(sessionID, resp.ConfigOptions, resp.Modes)
	if !baseline {
		return nil
	}
	at := time.Now()
	frames := make([]json.RawMessage, 0, len(replay)+1)
	for _, update := range replay {
		frames = append(frames, encodeFrame(frame{At: at, Update: update}))
	}
	h.mu.Lock()
	session := h.sessions[sessionID]
	h.mu.Unlock()
	if session == nil {
		return provider.ErrSessionNotFound
	}
	session.recordMu.Lock()
	defer session.recordMu.Unlock()
	for _, raw := range frames {
		var f frame
		_ = json.Unmarshal(raw, &f)
		session.mapper.apply(f)
	}
	// The replay's last turn ends with it.
	if turn := session.mapper.turn; turn != "" {
		stop := encodeFrame(frame{At: at, Stop: &stopFrame{Turn: turn, State: provider.TurnCompleted}})
		var f frame
		_ = json.Unmarshal(stop, &f)
		session.mapper.apply(f)
		frames = append(frames, stop)
	}
	if h.host.Mirror != nil {
		h.host.Mirror.Append(sessionID, frames)
	}
	return nil
}

// History maps the session's frames to turns. A session maiD never ran has
// none until session/load gives them: the session is loaded once, its replay
// kept as its first frames, and closed again where the agent allows.
func (h *Instance) History(ctx context.Context, sessionID string, workspace provider.Workspace, after provider.Marker) (provider.HistoryPage, error) {
	frames, err := h.frames(ctx, sessionID)
	if err != nil {
		return provider.HistoryPage{}, err
	}
	if len(frames) == 0 && !h.live(sessionID) && h.supportsLoadSession() && h.host.Mirror != nil {
		if err := h.load(ctx, sessionID, workspace.Cwd, h.supportedAdditionalDirectories(workspace.AdditionalDirectories), []schema.McpServer{}, true); err != nil {
			return provider.HistoryPage{}, err
		}
		h.closeAgentSession(ctx, sessionID)
		if frames, err = h.frames(ctx, sessionID); err != nil {
			return provider.HistoryPage{}, err
		}
	}
	_, turns := history(frames)
	return provider.After(turns, after), nil
}

// Delivered finds the prompt frame of the delivery: taken once the agent
// answered after it, not known while the prompt is the session's last frame.
func (h *Instance) Delivered(ctx context.Context, sessionID string, probe provider.DeliveryProbe) (provider.Tri, error) {
	if h.host.Mirror == nil {
		return provider.TriUnknown, nil
	}
	frames, err := h.frames(ctx, sessionID)
	if err != nil {
		return provider.TriUnknown, err
	}
	for index, raw := range frames {
		var f frame
		if json.Unmarshal(raw, &f) != nil || f.Prompt == nil || f.Prompt.Turn != probe.Delivery {
			continue
		}
		if index == len(frames)-1 {
			return provider.TriUnknown, nil
		}
		return provider.TriYes, nil
	}
	return provider.TriNo, nil
}

func (h *Instance) frames(ctx context.Context, sessionID string) ([]json.RawMessage, error) {
	if h.host.Mirror == nil {
		return nil, nil
	}
	return h.host.Mirror.Load(ctx, sessionID)
}

// Release ends the live session: a running prompt is cancelled, and the agent
// closes the session where it allows.
func (h *Instance) Release(ctx context.Context, sessionID string) error {
	if !h.live(sessionID) {
		return nil
	}
	h.mu.Lock()
	session := h.sessions[sessionID]
	prompt := session.prompt
	h.mu.Unlock()
	if prompt != "" {
		if err := h.Interrupt(ctx, sessionID, prompt); err != nil {
			return err
		}
	}
	h.closeAgentSession(ctx, sessionID)
	h.detach(sessionID)
	// The prompt's own end can't arrive once the stream is gone.
	h.settlePrompt(session, schema.PromptResponse{StopReason: schema.StopReasonCancelled}, nil)
	return nil
}

func (h *Instance) closeAgentSession(ctx context.Context, sessionID string) {
	if h.sessionCapabilities().Close != nil {
		_, _ = h.agentPeer.CloseSession(ctx, schema.CloseSessionRequest{SessionID: schema.SessionId(sessionID)})
	}
}

func (h *Instance) Sessions(ctx context.Context, cwd string) ([]provider.SessionSummary, error) {
	if h.sessionCapabilities().List == nil {
		return nil, provider.ErrUnsupported
	}
	req := schema.ListSessionsRequest{}
	if cwd != "" {
		req.CWD = &cwd
	}
	var sessions []provider.SessionSummary
	seenCursors := make(map[string]struct{})
	for {
		resp, err := h.agentPeer.ListSessions(ctx, req)
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

func (h *Instance) Delete(ctx context.Context, sessionID string) error {
	if h.sessionCapabilities().Delete == nil {
		return provider.ErrUnsupported
	}
	if h.live(sessionID) {
		if err := h.Release(ctx, sessionID); err != nil {
			return err
		}
	}
	if _, err := h.agentPeer.DeleteSession(ctx, schema.DeleteSessionRequest{SessionID: schema.SessionId(sessionID)}); err != nil && !sessionNotFoundError(err) {
		return acpRequestError(err)
	}
	if h.host.Mirror != nil {
		return h.host.Mirror.Delete(ctx, sessionID)
	}
	return nil
}

// Configure sets a config option (model, reasoning level, mode, …) and
// reports the refreshed options.
func (h *Instance) Configure(ctx context.Context, sessionID string, setting provider.ConfigOptionSelection) error {
	if !h.live(sessionID) {
		return fmt.Errorf("ACP session %q is not open", sessionID)
	}
	if err := h.setSessionConfigOptionValue(ctx, sessionID, setting.OptionID, setting.Value); err != nil {
		return err
	}
	h.emitConfigOptions(sessionID)
	return nil
}

func (h *Instance) OpenOptions(ctx context.Context, cwd string, callbacks provider.OptionsSessionCallbacks) (provider.OptionsSession, error) {
	opened, err := h.openOptions(ctx, cwd, callbacks)
	h.noteAuthRequired(err)
	return opened, err
}

func (h *Instance) openOptions(ctx context.Context, cwd string, callbacks provider.OptionsSessionCallbacks) (provider.OptionsSession, error) {
	if cwd == "" {
		return provider.OptionsSession{}, fmt.Errorf("provider options session requires cwd")
	}
	active, err := h.agentPeer.StartSession(ctx, schema.NewSessionRequest{CWD: cwd, MCPServers: []schema.McpServer{}})
	if err != nil {
		return provider.OptionsSession{}, acpRequestError(err)
	}
	resp := active.NewSessionResponse()
	sessionID := string(resp.SessionID)
	if sessionID == "" {
		active.Dispose()
		return provider.OptionsSession{}, fmt.Errorf("ACP session/new returned an empty session id")
	}
	h.attach(sessionID, active, &mapper{}, nil)
	h.mu.Lock()
	h.sessions[sessionID].options = &callbacks
	h.mu.Unlock()
	h.cacheSessionState(sessionID, resp.ConfigOptions, resp.Modes)
	return provider.OptionsSession{Handle: sessionID, ConfigOptions: h.combinedConfigOptions(sessionID)}, nil
}

func (h *Instance) SetOption(ctx context.Context, handle string, optionID string, value any) ([]provider.ConfigOption, error) {
	if !h.isOptionsSession(handle) {
		return nil, fmt.Errorf("ACP options session %q is not active", handle)
	}
	if err := h.setSessionConfigOptionValue(ctx, handle, optionID, value); err != nil {
		return nil, err
	}
	return h.combinedConfigOptions(handle), nil
}

func (h *Instance) CloseOptions(ctx context.Context, handle string) error {
	if !h.isOptionsSession(handle) {
		return nil
	}
	var closeErr error
	if h.sessionCapabilities().Close != nil {
		if _, err := h.agentPeer.CloseSession(ctx, schema.CloseSessionRequest{SessionID: schema.SessionId(handle)}); err != nil {
			closeErr = acpRequestError(err)
		}
	}
	h.detach(handle)
	return closeErr
}

func (h *Instance) isOptionsSession(handle string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessions[handle]
	return session != nil && session.options != nil
}

func (h *Instance) live(sessionID string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessions[sessionID]
	return session != nil && session.stream != nil && !session.stream.closed
}

// opened is a live session's state for Open's result. It is read after the
// state it reports changed, so an event the daemon gets before the result
// changes nothing the result doesn't already have.
func (h *Instance) opened(sessionID string) provider.Opened {
	options := h.combinedConfigOptions(sessionID)
	h.mu.Lock()
	defer h.mu.Unlock()
	opened := provider.Opened{Session: sessionID, Options: options}
	if session := h.sessions[sessionID]; session != nil {
		opened.Commands = slices.Clone(session.commands)
	}
	return opened
}

// attach makes sessionID live with its update stream: active, the stream
// StartSession made for a new session, or else a subscription made before
// the call that opens the session is awaited, so updates the agent sends
// during it are routed. A non-nil capture collects them unmapped.
func (h *Instance) attach(sessionID string, active *acp.ActiveSession, restored *mapper, capture []json.RawMessage) *sessionStream {
	h.mu.Lock()
	session := h.sessions[sessionID]
	if session == nil {
		session = &acpSession{id: sessionID, pendingPermissions: make(map[string]*pendingPermission)}
		h.sessions[sessionID] = session
	}
	session.mapper = restored
	session.capture = capture
	if session.stream != nil && !session.stream.closed {
		stream := session.stream
		h.mu.Unlock()
		if active != nil {
			active.Dispose()
		}
		return stream
	}
	if active == nil {
		active = h.agentPeer.AttachSession(schema.SessionId(sessionID))
	}
	stream := &sessionStream{
		sessionID: sessionID,
		session:   active,
		barriers:  make(map[string]*sessionBarrier),
	}
	session.stream = stream
	h.mu.Unlock()
	go h.consumeSessionStream(stream)
	return stream
}

// detach forgets a live session and disposes its stream.
func (h *Instance) detach(sessionID string) {
	h.mu.Lock()
	session := h.sessions[sessionID]
	delete(h.sessions, sessionID)
	var stream *sessionStream
	if session != nil {
		stream = session.stream
		if stream != nil {
			stream.closed = true
			if stream.closeErr == nil {
				stream.closeErr = errSessionStreamClosed
			}
		}
	}
	h.mu.Unlock()
	if stream != nil {
		stream.session.Dispose()
	}
}

// sessionError reports a session the agent no longer has as
// provider.ErrSessionNotFound.
func sessionError(err error) error {
	if sessionNotFoundError(err) {
		return fmt.Errorf("%w: %v", provider.ErrSessionNotFound, acpRequestError(err))
	}
	if errors.Is(err, provider.ErrSessionNotFound) {
		return err
	}
	return acpRequestError(err)
}

// sessionNotFoundError reports whether the agent said the session no longer
// exists (ACP Resource not found, -32002).
func sessionNotFoundError(err error) bool {
	var providerErr *provider.RequestError
	return errors.As(acpRequestError(err), &providerErr) && int64(providerErr.Code) == acp.CodeResourceNotFound
}

// mcpServers are the servers a session gets: maiD's own, over HTTP when the
// agent takes it, else as a stdio relay.
func (h *Instance) mcpServers(server *provider.MCPServer) []schema.McpServer {
	servers := []schema.McpServer{}
	if server == nil {
		return servers
	}
	if server.URL != "" && h.Info().Capabilities.MCP.HTTP {
		kind := schema.McpServerTypeHTTP
		url := server.URL
		headers := []schema.HttpHeader{}
		for name, value := range server.Headers {
			headers = append(headers, schema.HttpHeader{Name: name, Value: value})
		}
		slices.SortFunc(headers, func(a, b schema.HttpHeader) int { return strings.Compare(a.Name, b.Name) })
		return append(servers, schema.McpServer{Name: server.Name, Type: &kind, URL: &url, Headers: headers})
	}
	if server.Stdio == nil || len(server.Stdio.Argv) == 0 {
		return servers
	}
	command := server.Stdio.Argv[0]
	env := []schema.EnvVariable{}
	for _, pair := range server.Stdio.Env {
		name, value, _ := strings.Cut(pair, "=")
		env = append(env, schema.EnvVariable{Name: name, Value: value})
	}
	return append(servers, schema.McpServer{Name: server.Name, Command: &command, Args: append([]string{}, server.Stdio.Argv[1:]...), Env: env})
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

func (h *Instance) supportedAdditionalDirectories(directories []string) []string {
	if h.sessionCapabilities().AdditionalDirectories == nil || len(directories) == 0 {
		return nil
	}
	return append([]string(nil), directories...)
}

const acpSessionModeOptionID = "acp.session-mode"

func (h *Instance) cacheSessionState(sessionID string, configOptions []schema.SessionConfigOption, modes *schema.SessionModeState) {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessions[sessionID]
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
	session := h.sessions[sessionID]
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
		return []provider.ConfigOption{}
	}
	choices := make([]provider.ConfigChoice, 0, len(modes.AvailableModes))
	for _, mode := range modes.AvailableModes {
		description := ""
		if mode.Description != nil {
			description = *mode.Description
		}
		choices = append(choices, provider.ConfigChoice{Value: string(mode.ID), Label: mode.Name, Description: description})
	}
	return []provider.ConfigOption{{ID: acpSessionModeOptionID, Type: provider.ConfigOptionTypeSelect, Category: provider.ConfigOptionCategoryMode, Label: "Mode", Choices: choices, CurrentValue: string(modes.CurrentModeID)}}
}

// applySettings applies a session's chosen settings, the model first: a
// model can change which other options exist. A setting the agent refuses
// shows as a warning instead of failing the session.
func (h *Instance) applySettings(ctx context.Context, sessionID string, settings []provider.ConfigOptionSelection) {
	categories := make(map[string]provider.ConfigOptionCategory)
	for _, option := range h.combinedConfigOptions(sessionID) {
		categories[option.ID] = option.Category
	}
	ordered := slices.Clone(settings)
	slices.SortStableFunc(ordered, func(a, b provider.ConfigOptionSelection) int {
		aModel, bModel := categories[a.OptionID] == provider.ConfigOptionCategoryModel, categories[b.OptionID] == provider.ConfigOptionCategoryModel
		switch {
		case aModel && !bModel:
			return -1
		case bModel && !aModel:
			return 1
		}
		return 0
	})
	for _, setting := range ordered {
		if h.sessionConfigOptionAlreadyCurrent(sessionID, setting.OptionID, setting.Value) {
			continue
		}
		if err := h.setSessionConfigOptionValue(ctx, sessionID, setting.OptionID, setting.Value); err != nil {
			h.emit(sessionID, provider.Warning{Message: fmt.Sprintf("config option %q not restored: %v", setting.OptionID, err)})
		}
	}
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
		booleanType := schema.SetSessionConfigOptionRequestTypeBoolean
		request.Type = &booleanType
	default:
		return fmt.Errorf("ACP config option %q requires a string or boolean value", optionID)
	}
	resp, err := h.agentPeer.SetSessionConfigOption(ctx, request)
	if err != nil {
		return acpRequestError(err)
	}
	h.cacheSessionState(sessionID, resp.ConfigOptions, nil)
	return nil
}

// applyCurrentMode records an agent-initiated mode change. Agents that expose
// their mode as a config option may still report a change only through
// current_mode_update, so the mode-category option offering that mode is
// updated too. It reports whether any state changed.
func (h *Instance) applyCurrentMode(sessionID string, modeID schema.SessionModeId) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessions[sessionID]
	if session == nil {
		return false
	}
	if session.modes != nil {
		session.modes.CurrentModeID = modeID
		return true
	}
	for i := range session.config {
		option := &session.config[i]
		if option.Category != provider.ConfigOptionCategoryMode || option.Type != provider.ConfigOptionTypeSelect {
			continue
		}
		for _, choice := range option.Choices {
			if choice.Value == string(modeID) {
				option.CurrentValue = choice.Value
				return true
			}
		}
	}
	return false
}

func (h *Instance) setSessionModeValue(ctx context.Context, sessionID string, modeID schema.SessionModeId) error {
	if _, err := h.agentPeer.SetSessionMode(ctx, schema.SetSessionModeRequest{SessionID: schema.SessionId(sessionID), ModeID: modeID}); err != nil {
		return acpRequestError(err)
	}
	h.mu.Lock()
	if session := h.sessions[sessionID]; session != nil && session.modes != nil {
		session.modes.CurrentModeID = modeID
	}
	h.mu.Unlock()
	return nil
}

func (h *Instance) sessionConfigOptionAlreadyCurrent(sessionID string, optionID string, value any) bool {
	for _, option := range h.combinedConfigOptions(sessionID) {
		if option.ID == optionID && option.CurrentValue == value {
			return true
		}
	}
	return false
}

// emitConfigOptions reports the session's options: to an options session's
// callbacks, otherwise as an event.
func (h *Instance) emitConfigOptions(sessionID string) {
	options := h.combinedConfigOptions(sessionID)
	h.mu.Lock()
	var updated func([]provider.ConfigOption)
	if session := h.sessions[sessionID]; session != nil && session.options != nil {
		updated = session.options.Updated
	}
	h.mu.Unlock()
	if updated != nil {
		updated(options)
		return
	}
	h.emit(sessionID, provider.ConfigChanged{Options: options})
}

// emit reports one event of a live session that isn't an options session.
func (h *Instance) emit(sessionID string, body provider.EventBody) {
	h.mu.Lock()
	session := h.sessions[sessionID]
	options := session != nil && session.options != nil
	h.mu.Unlock()
	if session == nil || options || h.host.Emit == nil {
		return
	}
	h.host.Emit(provider.Event{Session: sessionID, At: time.Now(), Body: body})
}
