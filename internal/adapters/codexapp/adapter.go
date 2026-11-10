// Package codexapp adapts the stable Codex app-server protocol to maiD's
// provider-neutral runtime contract.
package codexapp

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/Aqothy/maiD/internal/adapters/elicitation"
	"github.com/Aqothy/maiD/internal/adapters/procgroup"
	"github.com/Aqothy/maiD/internal/provider"
)

const DriverKind provider.DriverKind = "codex-app-server"

type Config struct {
	Command []string          `json:"command,omitempty"`
	Env     map[string]string `json:"env,omitempty"`
}

// historyVersion changes whenever items map to entries differently.
const historyVersion = 1

// sessionState is one native thread (session key = thread id): one maiD
// opened, or a child thread its notifications name.
type sessionState struct {
	thread string
	cwd    string
	// loaded: maiD opened or resumed it, so it is subscribed and takes
	// turns; a child thread is known only through its notifications.
	loaded      bool
	model       string
	effort      string
	serviceTier string
	// permissions is the current permission preset, or customPermissions.
	// permissionsChanged is set when the user picked a preset that the next
	// turn/start must apply.
	permissions        string
	permissionsChanged bool
	skills             []provider.Skill
	configOptions      []provider.ConfigOption

	// pending is a delivery whose turn Codex hasn't named yet.
	pending *pendingTurn
	// activeTurn is the turn Codex runs on the thread.
	activeTurn string
	started    map[string]bool
	// entries are the entries of items still updating (a command's output),
	// by ref.
	entries  map[string]provider.Entry
	streamed map[string]streamedItem
}

// streamedItem accumulates the live text deltas of one app-server item.
// part identifies the reasoning part (summary or content index) the last
// delta belonged to; app-server streams parts back to back, so a part change
// is the only signal for the paragraph boundary the completed item will carry.
type streamedItem struct {
	text string
	part string
}

type pendingApproval struct {
	id           json.RawMessage
	rpcRequestID string
	requestID    string
	thread       string
	kind         pendingKind
	// form is an elicitation's form; nil for a URL elicitation.
	form *elicitation.Form
	// permissions is what a permissions request asks for, granted as is.
	permissions json.RawMessage
	// amendments are the replies of a command approval's actions that also
	// add a lasting rule, by action ID.
	amendments map[string]map[string]any
}

// pendingKind is what a server request asks, which decides its reply format.
type pendingKind int

const (
	// pendingApprovalRequest asks permission and is answered with a decision.
	pendingApprovalRequest pendingKind = iota
	// pendingElicitation is an MCP server's elicitation, answered with an
	// action and, for a form, content.
	pendingElicitation
	// pendingPermissions asks for more sandbox access, answered with the
	// permissions granted and for how long.
	pendingPermissions
)

// reply builds the server-request response for the user's answer.
func (p *pendingApproval) reply(input provider.RequestAnswer) (map[string]any, error) {
	if reply, ok := p.amendments[input.Action.ID]; ok {
		return reply, nil
	}
	switch p.kind {
	case pendingElicitation:
		if mode, ok := strings.CutPrefix(input.Action.ID, rememberActionPrefix); ok {
			return map[string]any{"action": elicitation.ActionAccept, "content": nil, "_meta": map[string]any{"persist": mode}}, nil
		}
		action, content, err := elicitation.Answer(p.form, input.Action, input.Answers)
		if err != nil {
			return nil, err
		}
		reply := map[string]any{"action": action, "content": nil}
		if content != nil {
			reply["content"] = content
		}
		return reply, nil
	case pendingPermissions:
		return permissionsReply(p.permissions, input.Action.Decision), nil
	default:
		// The other actions are named after Codex's own decisions.
		return map[string]any{"decision": input.Action.ID}, nil
	}
}

// cancelReply answers the request as cancelled, in its own format.
func (p *pendingApproval) cancelReply() map[string]any {
	switch p.kind {
	case pendingElicitation:
		return map[string]any{"action": elicitation.ActionCancel, "content": nil}
	case pendingPermissions:
		return permissionsReply(p.permissions, provider.ApprovalDecisionCancel)
	default:
		return map[string]any{"decision": "cancel"}
	}
}

type optionsState struct {
	selectedModel  string
	selectedEffort string
	selectedTier   string
	permissions    string
	callbacks      provider.OptionsSessionCallbacks
}

type Instance struct {
	provider.Unsupported

	mu     sync.Mutex
	info   provider.InstanceInfo
	host   provider.Host
	logger *slog.Logger

	ctx    context.Context
	cancel context.CancelFunc
	// requestNonce is random per instance; see requestID.
	requestNonce string
	process      *procgroup.Process
	rpc          *rpcClient

	sessions         map[string]*sessionState
	pendingApprovals map[string]*pendingApproval
	models           []appModel
	options          map[string]*optionsState
	// pendingLoginID is the browser or device-code sign-in in progress.
	pendingLoginID string
	// requestSummaries is set when the user's Codex configuration leaves
	// reasoning summaries to the model catalog, whose default is none.
	requestSummaries bool

	processDone     chan struct{}
	processErr      error
	closing         bool
	transportClosed bool
	closeOnce       sync.Once
	closeErr        error
}

// drainTimeout bounds reading what an exited app-server wrote last.
const drainTimeout = 2 * time.Second

// Driver is the Codex app-server driver.
var Driver = provider.Driver{
	Open: func(ctx context.Context, spec provider.InstanceSpec, host provider.Host) (provider.Instance, error) {
		return OpenInstance(ctx, spec, host)
	},
	Static: func(provider.InstanceSpec) provider.InstanceInfo {
		return provider.InstanceInfo{Capabilities: capabilities(), Access: accessModes()}
	},
}

func capabilities() provider.Capabilities {
	return provider.Capabilities{
		History: provider.HistoryExact, HistoryVersion: historyVersion,
		Resume: true, Fork: true, Steer: true, Subagents: true, Instructions: true, MessageIDs: true,
		MCP:      provider.MCPCapabilities{HTTP: true},
		Sessions: true, Delete: true, Rename: true, Auth: true, Logout: true, CommandCompletion: true,
		// Stable app-server UserInput supports text, image, localImage,
		// audio, localAudio, skill, and mention. It has no embedded-resource
		// prompt variant, so do not advertise ACP-style embedded context.
		PromptContent: provider.PromptContentCapabilities{Image: true, Audio: true},
	}
}

// accessModes rates Codex's permission presets.
func accessModes() *provider.AccessModes {
	return &provider.AccessModes{Option: permissionsOptionID, Levels: map[string]provider.AccessLevel{
		"read-only": provider.AccessReadOnly, "auto": provider.AccessEdit, "full-access": provider.AccessFull,
	}}
}

func OpenInstance(ctx context.Context, spec provider.InstanceSpec, host provider.Host) (*Instance, error) {
	if spec.InstanceID == "" {
		return nil, fmt.Errorf("missing provider instance id")
	}
	config := Config{Command: []string{"codex", "app-server"}}
	if len(spec.Config) > 0 {
		if err := json.Unmarshal(spec.Config, &config); err != nil {
			return nil, fmt.Errorf("decode Codex app-server config: %w", err)
		}
	}
	if len(config.Command) == 0 {
		config.Command = []string{"codex", "app-server"}
	}
	if spec.Name == "" {
		spec.Name = "Codex"
	}

	startedAt := time.Now()
	command := exec.Command(config.Command[0], config.Command[1:]...)
	command.Stderr = os.Stderr
	if len(config.Env) > 0 {
		command.Env = append([]string(nil), os.Environ()...)
		for key, value := range config.Env {
			command.Env = append(command.Env, key+"="+value)
		}
	}
	process, err := procgroup.Start(command)
	if err != nil {
		return nil, fmt.Errorf("start %s: %w", filepath.Base(config.Command[0]), err)
	}

	h := &Instance{
		host:             host,
		logger:           slog.Default().With("component", "codex-app-server", "providerInstance", spec.InstanceID),
		process:          process,
		requestNonce:     rand.Text()[:8],
		sessions:         make(map[string]*sessionState),
		pendingApprovals: make(map[string]*pendingApproval),
		options:          make(map[string]*optionsState),
		processDone:      make(chan struct{}),
	}
	h.ctx, h.cancel = context.WithCancel(context.Background())
	h.rpc = newRPCClient(process.Stdout(), process.Stdin())
	h.rpc.onNotification = h.handleNotification
	h.rpc.onRequest = h.handleServerRequest
	h.rpc.onClose = h.handleTransportClosed
	h.info = provider.InstanceInfo{
		InstanceID: spec.InstanceID, Name: spec.Name, Driver: DriverKind,
		PID: process.Pid(), Status: provider.InstanceStatusConfigured,
		StartedAt: startedAt, Capabilities: capabilities(), Access: accessModes(),
		Auth: provider.Auth{Status: provider.AuthStatusUnknown},
	}
	go h.rpc.run()
	go h.waitProcess()

	params := initializeParams{
		ClientInfo: appClientInfo{Name: "maiD", Title: "maiD", Version: "beta"},
		Capabilities: appClientCapabilities{
			ExperimentalAPI:    false,
			RequestAttestation: false,
		},
	}
	if err := h.rpc.call(ctx, "initialize", params, nil); err != nil {
		_ = h.Close()
		return nil, fmt.Errorf("initialize Codex app-server: %w", err)
	}
	if err := h.rpc.notify("initialized", nil); err != nil {
		_ = h.Close()
		return nil, fmt.Errorf("notify Codex app-server initialized: %w", err)
	}
	h.mu.Lock()
	if h.transportClosed {
		h.mu.Unlock()
		_ = h.Close()
		return nil, fmt.Errorf("Codex app-server connection closed during initialization")
	}
	h.info.Status = provider.InstanceStatusInitialized
	h.info.InitializedAt = time.Now()
	h.mu.Unlock()
	// Catalog/auth failures are recoverable (for example a login may be needed).
	if err := h.refreshAccount(ctx); err != nil {
		h.logger.Debug("read account", "error", err)
	}
	if err := h.refreshModels(ctx); err != nil {
		h.logger.Debug("list models", "error", err)
	}
	var effective configReadResponse
	if err := h.rpc.call(ctx, "config/read", map[string]any{}, &effective); err != nil {
		h.logger.Debug("read config", "error", err)
	} else {
		h.requestSummaries = effective.Config.ModelReasoningSummary == nil
	}
	return h, nil
}

func (h *Instance) Info() provider.InstanceInfo {
	h.mu.Lock()
	defer h.mu.Unlock()
	info := h.info
	info.Auth.Methods = append([]provider.AuthMethod(nil), h.info.Auth.Methods...)
	return info
}

func (h *Instance) waitProcess() {
	// Let the reader deliver what app-server wrote before exiting, such as
	// the turn completions, before cleanup is considered complete. Its close
	// callback settles any turns app-server could no longer complete.
	h.process.Drain(h.rpc.runDone, drainTimeout)
	err := h.process.Err()
	h.mu.Lock()
	h.processErr = err
	h.info.Status = provider.InstanceStatusExited
	h.info.PID = 0
	info := h.info
	h.mu.Unlock()
	h.rpc.fail(firstError(err, io.EOF))
	h.cancel()
	h.emit("", provider.InstanceChanged{Info: info})
	close(h.processDone)
}

func firstError(err, fallback error) error {
	if err != nil {
		return err
	}
	return fallback
}

// handleTransportClosed ends what app-server can no longer finish: running
// turns end, every open session closes, and requests end unanswered.
func (h *Instance) handleTransportClosed(err error) {
	h.mu.Lock()
	h.transportClosed = true
	h.info.Status = provider.InstanceStatusExited
	h.info.PID = 0
	settled := provider.TurnSettled{State: provider.TurnFailed, Error: "Codex app-server disconnected unexpectedly"}
	if err != nil {
		settled.Error += ": " + err.Error()
	}
	if h.closing {
		settled = provider.TurnSettled{State: provider.TurnInterrupted}
	}
	type ended struct{ session, turn string }
	var turns []ended
	var closed []string
	for _, session := range h.sessions {
		if session.activeTurn != "" {
			turns = append(turns, ended{session.thread, session.activeTurn})
		}
		if session.loaded {
			closed = append(closed, session.thread)
		}
		session.activeTurn, session.pending = "", nil
		session.streamed = make(map[string]streamedItem)
	}
	h.mu.Unlock()
	// Without a transport the process is useless; a malformed stream ends it.
	h.process.Kill()
	h.cancel()
	h.cancelPendingApprovals("")
	for _, turn := range turns {
		settled.Turn = turn.turn
		h.emit(turn.session, settled)
	}
	for _, session := range closed {
		h.emit(session, provider.SessionClosed{Error: settled.Error})
	}
}

func (h *Instance) Close() error {
	h.closeOnce.Do(func() {
		h.mu.Lock()
		intentional := h.info.Status != provider.InstanceStatusExited
		h.closing = intentional
		h.mu.Unlock()
		h.cancelPendingApprovals("")
		h.cancel()
		h.process.Stop()
		<-h.processDone
		h.mu.Lock()
		if !intentional {
			h.closeErr = h.processErr
		}
		h.mu.Unlock()
	})
	return h.closeErr
}

// sessionLocked is the state of a native thread, made the first time the
// thread is named. h.mu must be held.
func (h *Instance) sessionLocked(thread string) *sessionState {
	session := h.sessions[thread]
	if session == nil {
		session = &sessionState{
			thread: thread, started: make(map[string]bool),
			entries: make(map[string]provider.Entry), streamed: make(map[string]streamedItem),
		}
		h.sessions[thread] = session
	}
	return session
}

// emit reports one event of a session.
func (h *Instance) emit(session string, body provider.EventBody) {
	if h.host.Emit != nil {
		h.host.Emit(provider.Event{Session: session, At: time.Now(), Body: body})
	}
}
