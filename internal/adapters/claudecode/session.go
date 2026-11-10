package claudecode

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// Open starts a session's CLI, resuming its transcript. A session without
// one (it never ran, or the CLI cleaned it up) is a new session under a new
// key, so the host sees the conversation is gone and catches it up.
func (h *Instance) Open(ctx context.Context, in provider.OpenInput) (provider.Opened, error) {
	if in.Workspace.Cwd == "" {
		return provider.Opened{}, fmt.Errorf("Claude Code session requires cwd")
	}
	if _, agent := splitSubagentKey(in.Session); agent != "" {
		return provider.Opened{}, fmt.Errorf("Claude Code subagent %q takes no input of its own", in.Session)
	}
	key := in.Session
	h.mu.Lock()
	if existing := h.sessions[key]; key != "" && existing != nil {
		opened := h.openedLocked(existing)
		h.mu.Unlock()
		return opened, nil
	}
	h.mu.Unlock()
	if key != "" && !sessionIDPattern.MatchString(key) {
		return provider.Opened{}, fmt.Errorf("invalid Claude Code session id %q", key)
	}
	resume := key != "" && h.hasTranscript(key)
	if !resume {
		key = newSessionUUID()
	}
	model, effort, mode := settingsOf(in.Settings)
	session := &claudeSession{
		id: key, cwd: in.Workspace.Cwd, additionalDirs: append([]string(nil), in.Workspace.AdditionalDirectories...),
		model: model, effort: effort, permissionMode: mode, instructions: in.Instructions, mcp: in.MCP,
		unechoed: make(map[string]bool), tasks: make(map[string]string), subagents: make(map[string]*subagent),
	}
	session.live = newMapper(key, func(body provider.EventBody, at time.Time) { h.emitAt(session.id, body, at) })
	h.mu.Lock()
	if existing := h.sessions[key]; existing != nil {
		// Opened concurrently: one process per session.
		opened := h.openedLocked(existing)
		h.mu.Unlock()
		return opened, nil
	}
	h.sessions[key] = session
	h.mu.Unlock()
	if err := h.spawnProcess(ctx, session, resume); err != nil {
		h.mu.Lock()
		if h.sessions[key] == session {
			delete(h.sessions, key)
		}
		h.mu.Unlock()
		return provider.Opened{}, err
	}
	skills := h.scanSkills(session.cwd)
	h.mu.Lock()
	session.skills = skills
	session.options = h.configOptionsLocked(session.model, session.effort, session.permissionMode)
	opened := h.openedLocked(session)
	h.mu.Unlock()
	return opened, nil
}

func (h *Instance) openedLocked(session *claudeSession) provider.Opened {
	return provider.Opened{
		Session:  session.id,
		Options:  append([]provider.ConfigOption(nil), session.options...),
		Commands: slashCommandsFromSDK(h.commands),
		Skills:   append([]provider.Skill(nil), session.skills...),
	}
}

// spawnProcess launches the session's CLI process. Stream callbacks fence on
// the process pointer so a stale process can never touch a successor's state.
func (h *Instance) spawnProcess(ctx context.Context, session *claudeSession, resume bool) error {
	extra := []string{
		"--include-partial-messages",
		// Echoes each written message when the CLI takes it into a query,
		// which is how a message is known to have been read, and where.
		"--replay-user-messages",
		"--permission-prompt-tool", "stdio",
		// Enables bypassPermissions as a selectable mode without turning it
		// on: the mode still has to be chosen explicitly by the user.
		"--allow-dangerously-skip-permissions",
		// Newer models omit thinking text unless summaries are requested.
		// This only sets how thinking is shown; whether the model thinks is
		// still the user's setting.
		"--thinking-display", "summarized",
	}
	if resume {
		extra = append(extra, "--resume", session.id)
	} else {
		extra = append(extra, "--session-id", session.id)
	}
	if model := strings.TrimSpace(session.model); model != "" && model != "default" {
		extra = append(extra, "--model", model)
	}
	// "default" means model-selected effort, which is the CLI's behaviour
	// without the flag; it is not a value --effort accepts.
	if effort := strings.TrimSpace(session.effort); effort != "" && effort != "default" {
		extra = append(extra, "--effort", effort)
	}
	// Without a selection the CLI starts in the user's configured default
	// mode, which initialize reports below.
	if validPermissionMode(session.permissionMode) {
		extra = append(extra, "--permission-mode", session.permissionMode)
	}
	for _, dir := range session.additionalDirs {
		if strings.TrimSpace(dir) != "" {
			extra = append(extra, "--add-dir", dir)
		}
	}
	if session.instructions != "" {
		extra = append(extra, "--append-system-prompt", session.instructions)
	}
	mcpConfig := ""
	if session.mcp != nil {
		var err error
		if mcpConfig, err = writeMCPConfig(*session.mcp); err != nil {
			return err
		}
		extra = append(extra, "--mcp-config", mcpConfig)
	}

	process, client, err := h.startCLI(session.cwd, extra)
	if err != nil {
		removeFile(mcpConfig)
		return fmt.Errorf("start Claude Code CLI: %w", err)
	}
	proc := &sessionProcess{process: process, client: client, done: make(chan struct{}), mcpConfig: mcpConfig}
	proc.client.onMessage = func(message sdkMessage) { h.handleMessage(session, proc, message) }
	proc.client.onControlRequest = func(requestID string, request controlRequestBody, raw json.RawMessage) {
		h.handleControlRequest(session, proc, requestID, request, raw)
	}
	proc.client.onControlCancel = func(requestID string) { h.handleControlCancel(requestID) }
	proc.client.start()
	h.mu.Lock()
	session.proc = proc
	h.mu.Unlock()
	go h.waitProcess(session, proc)

	// The initialize handshake answers before any API call and refreshes the
	// cwd-scoped command list plus account/model catalog. Subagents' text
	// streams too, for their child threads.
	var initResponse initializeResponse
	if err := proc.client.control(ctx, map[string]any{"subtype": "initialize", "forwardSubagentText": true}, &initResponse); err != nil {
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
	if validPermissionMode(initResponse.CurrentPermissionMode) {
		session.permissionMode = initResponse.CurrentPermissionMode
	}
	h.mu.Unlock()
	return nil
}

// writeMCPConfig writes the session's MCP server as an --mcp-config file,
// readable only by the user since its headers carry credentials.
func writeMCPConfig(server provider.MCPServer) (string, error) {
	entry := map[string]any{"type": "http", "url": server.URL}
	if len(server.Headers) > 0 {
		entry["headers"] = server.Headers
	}
	if server.Stdio != nil {
		if len(server.Stdio.Argv) == 0 {
			return "", fmt.Errorf("MCP server %q has no command", server.Name)
		}
		entry = map[string]any{"type": "stdio", "command": server.Stdio.Argv[0], "args": server.Stdio.Argv[1:]}
		if len(server.Stdio.Env) > 0 {
			env := make(map[string]string, len(server.Stdio.Env))
			for _, pair := range server.Stdio.Env {
				name, value, _ := strings.Cut(pair, "=")
				env[name] = value
			}
			entry["env"] = env
		}
	}
	data, err := json.Marshal(map[string]any{"mcpServers": map[string]any{server.Name: entry}})
	if err != nil {
		return "", err
	}
	file, err := os.CreateTemp("", "maid-mcp-*.json")
	if err != nil {
		return "", fmt.Errorf("write MCP config: %w", err)
	}
	if _, err := file.Write(data); err != nil {
		_ = file.Close()
		removeFile(file.Name())
		return "", fmt.Errorf("write MCP config: %w", err)
	}
	if err := file.Close(); err != nil {
		removeFile(file.Name())
		return "", fmt.Errorf("write MCP config: %w", err)
	}
	return file.Name(), nil
}

func removeFile(path string) {
	if path != "" {
		_ = os.Remove(path)
	}
}

// waitProcess retires an exited process. A process that exited on its own
// closes its session; its open turn and tools end with it.
func (h *Instance) waitProcess(session *claudeSession, proc *sessionProcess) {
	// Deliver what the CLI wrote before exiting, such as the result or the
	// error that ends its turn, while it is still the session's process.
	proc.process.Drain(proc.client.done, drainTimeout)
	h.mu.Lock()
	closing := proc.closing
	current := session.proc == proc
	if current {
		session.proc = nil
		if !closing && h.sessions[session.id] == session {
			delete(h.sessions, session.id)
		}
	}
	h.mu.Unlock()
	proc.client.fail(firstError(proc.process.Err(), io.EOF))
	removeFile(proc.mcpConfig)
	h.cancelApprovalsForClient(proc.client)
	if current {
		state, reason := provider.TurnInterrupted, ""
		if !closing {
			state, reason = provider.TurnFailed, "Claude Code exited unexpectedly."
		}
		session.mapMu.Lock()
		// Background tasks end with the CLI that runs them.
		for _, sub := range session.subagents {
			sub.live.cutOff(time.Now())
			sub.live.settle(state, "", reason, time.Now())
		}
		session.live.cutOff(time.Now())
		session.live.settle(state, "", reason, time.Now())
		clear(session.unechoed)
		session.mapMu.Unlock()
		if !closing {
			h.emit(session.id, provider.SessionClosed{Error: reason})
		}
	}
	close(proc.done)
}

// stopProcess stops a session's CLI process if one is running, letting it
// exit on its own first, and returns once waitProcess has retired it.
func (h *Instance) stopProcess(session *claudeSession) {
	h.mu.Lock()
	proc := session.proc
	if proc == nil {
		h.mu.Unlock()
		return
	}
	proc.closing = true
	h.mu.Unlock()
	proc.process.Stop()
	<-proc.done
}

// Release stops the session's CLI; a running turn ends as interrupted.
func (h *Instance) Release(_ context.Context, key string) error {
	h.mu.Lock()
	session := h.sessions[key]
	delete(h.sessions, key)
	h.mu.Unlock()
	if session != nil {
		h.stopProcess(session)
	}
	return nil
}

// Send writes one user message to the session's CLI, with the delivery's ID
// as its uuid. The CLI reads it when it can: at once when idle, into the
// running query at its next tool boundary, or as the next query. Its echo
// then names its turn (mapper.echo), so the ack names none.
func (h *Instance) Send(_ context.Context, key string, in provider.SendInput) (provider.SendAck, error) {
	if !sessionIDPattern.MatchString(in.Delivery) {
		return provider.SendAck{}, fmt.Errorf("Claude Code message id %q is not a UUID", in.Delivery)
	}
	content, err := userContentBlocks(in.Text, in.Attachments)
	if err != nil {
		return provider.SendAck{}, err
	}
	session, err := h.session(key)
	if err != nil {
		return provider.SendAck{}, err
	}
	h.mu.Lock()
	proc := session.proc
	h.mu.Unlock()
	if proc == nil {
		return provider.SendAck{}, fmt.Errorf("Claude Code session %q: %w", key, provider.ErrSessionNotFound)
	}
	session.mapMu.Lock()
	defer session.mapMu.Unlock()
	busy := session.live.turn != ""
	if in.Steer && !busy {
		return provider.SendAck{}, fmt.Errorf("Claude Code session %q: %w", key, provider.ErrTurnNotRunning)
	}
	message := map[string]any{
		"type":               "user",
		"uuid":               in.Delivery,
		"session_id":         key,
		"parent_tool_use_id": nil,
		"message":            map[string]any{"role": "user", "content": content},
	}
	if busy {
		// Mid-query, the message joins the query at its next tool boundary.
		message["priority"] = "next"
	}
	session.unechoed[in.Delivery] = true
	// A failed write means the process is exiting; waitProcess closes it.
	if err := proc.client.send(message); err != nil {
		delete(session.unechoed, in.Delivery)
		return provider.SendAck{}, err
	}
	return provider.SendAck{}, nil
}

// Interrupt aborts the running query; on a subagent it stops the subagent's
// task. Messages queued behind the query survive and run next.
func (h *Instance) Interrupt(ctx context.Context, key, _ string) error {
	parent, agent := splitSubagentKey(key)
	session, err := h.session(parent)
	if err != nil {
		return err
	}
	h.mu.Lock()
	proc := session.proc
	h.mu.Unlock()
	if proc == nil {
		return nil
	}
	if agent != "" {
		return proc.client.control(ctx, map[string]any{"subtype": "stop_task", "task_id": agent}, nil)
	}
	session.mapMu.Lock()
	running := session.live.turn != ""
	session.mapMu.Unlock()
	if !running {
		return nil
	}
	return proc.client.control(ctx, map[string]any{"subtype": "interrupt"}, nil)
}

// StopItem stops the background task a tool started (stop_task). The task's
// notification then ends the tool's entry as interrupted.
func (h *Instance) StopItem(ctx context.Context, key, item string) error {
	session, err := h.session(key)
	if err != nil {
		return err
	}
	h.mu.Lock()
	proc := session.proc
	h.mu.Unlock()
	session.mapMu.Lock()
	task := session.tasks[item]
	session.mapMu.Unlock()
	if proc == nil || task == "" {
		return fmt.Errorf("Claude Code item %q is not a running background task", item)
	}
	return proc.client.control(ctx, map[string]any{"subtype": "stop_task", "task_id": task}, nil)
}

func (h *Instance) Configure(ctx context.Context, key string, setting provider.ConfigOptionSelection) error {
	session, err := h.session(key)
	if err != nil {
		return err
	}
	value, ok := setting.Value.(string)
	if !ok {
		return fmt.Errorf("Claude Code config option %q requires a string value", setting.OptionID)
	}
	h.mu.Lock()
	proc := session.proc
	h.mu.Unlock()
	switch setting.OptionID {
	case "model":
		h.mu.Lock()
		valid := modelValueValid(h.models, value)
		h.mu.Unlock()
		if !valid {
			return fmt.Errorf("Claude Code model %q is not available", value)
		}
		if proc != nil {
			var model any = value
			if value == "default" {
				model = nil
			}
			if err := proc.client.control(ctx, map[string]any{"subtype": "set_model", "model": model}, nil); err != nil {
				return err
			}
		}
		h.mu.Lock()
		session.model = value
		h.mu.Unlock()
	case "effort":
		h.mu.Lock()
		options := h.configOptionsLocked(session.model, value, session.permissionMode)
		h.mu.Unlock()
		if current, present := provider.CurrentConfigString(options, "effort"); !present || current != value {
			return fmt.Errorf("Claude Code config option %q does not accept value %q", setting.OptionID, value)
		}
		if proc != nil {
			// A null effortLevel returns to the model's default effort.
			var level any = value
			if value == "default" {
				level = nil
			}
			if err := proc.client.control(ctx, map[string]any{"subtype": "apply_flag_settings", "settings": map[string]any{"effortLevel": level}}, nil); err != nil {
				return err
			}
		}
		h.mu.Lock()
		session.effort = value
		h.mu.Unlock()
	case "permission_mode":
		if !validPermissionMode(value) {
			return fmt.Errorf("Claude Code config option %q does not accept value %q", setting.OptionID, value)
		}
		if proc != nil {
			if err := proc.client.control(ctx, map[string]any{"subtype": "set_permission_mode", "mode": value}, nil); err != nil {
				return err
			}
		}
		h.mu.Lock()
		session.permissionMode = value
		h.mu.Unlock()
	default:
		return fmt.Errorf("Claude Code config option %q is not supported", setting.OptionID)
	}
	h.mu.Lock()
	session.options = h.configOptionsLocked(session.model, session.effort, session.permissionMode)
	options := append([]provider.ConfigOption(nil), session.options...)
	h.mu.Unlock()
	h.emit(key, provider.ConfigChanged{Options: options})
	return nil
}

func settingsOf(settings []provider.ConfigOptionSelection) (model, effort, mode string) {
	for _, option := range settings {
		value, _ := option.Value.(string)
		switch option.OptionID {
		case "model":
			model = value
		case "effort":
			effort = value
		case "permission_mode":
			mode = value
		}
	}
	return model, effort, mode
}

func validPermissionMode(mode string) bool {
	switch mode {
	case "default", "acceptEdits", "auto", "bypassPermissions", "plan", "dontAsk":
		return true
	default:
		return false
	}
}

// splitSubagentKey splits a subagent's session key into its session's and
// its agent id; agent is empty for a session's own key.
func splitSubagentKey(key string) (session, agent string) {
	session, agent, found := strings.Cut(key, "/agent-")
	if !found {
		return key, ""
	}
	return session, agent
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
