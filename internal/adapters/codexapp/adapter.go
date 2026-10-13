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
	"sync"
	"sync/atomic"
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

type sessionState struct {
	localThreadID  string
	nativeThreadID string
	cwd            string
	model          string
	effort         string
	serviceTier    string
	// permissions is the current permission preset, or customPermissions.
	// permissionsChanged is set when the user picked a preset that the next
	// turn/start must apply.
	permissions        string
	permissionsChanged bool
	skills             []provider.Skill
	configOptions      []provider.ConfigOption

	pending           *pendingTurn
	nativeToLocalTurn map[string]string
	localToNativeTurn map[string]string
	startedTurns      map[string]bool
	activeNativeTurn  string
	items             map[string]provider.ToolCall
	streamed          map[string]streamedItem
}

// streamedItem accumulates the live text deltas of one app-server item so
// item/completed can emit only the tail the stream has not delivered yet.
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
	localThread  string
	localTurn    string
	requestType  provider.RuntimeRequestType
	kind         pendingKind
	// form is an elicitation's form; nil for a URL elicitation.
	form *elicitation.Form
	// permissions is what a permissions request asks for, granted as is.
	permissions json.RawMessage
	// amendments are a command approval's extra options, which also add a
	// lasting rule, keyed by option id.
	amendments map[string]amendment
}

// amendment is a command approval option that approves and adds a rule.
type amendment struct {
	reply    any
	decision provider.ApprovalDecision
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
func (p *pendingApproval) reply(input provider.RespondToRequestInput) (map[string]any, provider.ApprovalDecision, error) {
	switch p.kind {
	case pendingElicitation:
		action := elicitation.ActionFor(input.Decision)
		reply := map[string]any{"action": action, "content": nil}
		if action == elicitation.ActionAccept && p.form != nil {
			content, err := p.form.Content(input.Answers)
			if err != nil {
				return nil, "", err
			}
			reply["content"] = content
		}
		return reply, action.Decision(), nil
	}
	if chosen, ok := p.amendments[input.OptionID]; ok {
		return map[string]any{"decision": chosen.reply}, chosen.decision, nil
	}
	// The other options are named after the decisions they make.
	decision := input.Decision
	if input.OptionID != "" {
		decision = provider.ApprovalDecision(input.OptionID)
	}
	switch decision {
	case provider.ApprovalDecisionAccept, provider.ApprovalDecisionAcceptForSession, provider.ApprovalDecisionDecline:
	default:
		decision = provider.ApprovalDecisionCancel
	}
	if p.kind == pendingPermissions {
		return permissionsReply(p.permissions, decision), decision, nil
	}
	return map[string]any{"decision": decision}, decision, nil
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
	mu     sync.Mutex
	info   provider.InstanceInfo
	emit   provider.RuntimeEventListener
	logger *slog.Logger

	ctx    context.Context
	cancel context.CancelFunc
	// requestNonce is random per instance; see requestID.
	requestNonce string
	// localIDs numbers the reports the adapter makes itself.
	localIDs atomic.Uint64
	process  *procgroup.Process
	rpc      *rpcClient

	sessionsByLocal  map[string]*sessionState
	localByNative    map[string]string
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

// stopGrace is how long app-server gets to exit on its own once stdin
// closes; it ends the commands it runs then, which a kill would orphan.
const stopGrace = 5 * time.Second

// drainTimeout bounds reading what an exited app-server wrote last.
const drainTimeout = 2 * time.Second

func (*Instance) ReplaysClientMessageIDs() bool { return true }

func OpenInstance(ctx context.Context, spec provider.InstanceSpec, emit provider.RuntimeEventListener) (*Instance, error) {
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
		emit:             emit,
		logger:           slog.Default().With("component", "codex-app-server", "providerInstance", spec.InstanceID),
		process:          process,
		requestNonce:     rand.Text()[:8],
		sessionsByLocal:  make(map[string]*sessionState),
		localByNative:    make(map[string]string),
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
		StartedAt: startedAt,
		Capabilities: provider.Capabilities{
			SessionList: true, SessionDelete: true, SessionClose: true,
			LoadReplay: true, Resume: true, Fork: true, Skills: true,
			Auth: true, Logout: true, ConfigOptions: true,
			// Stable app-server UserInput supports text, image, localImage,
			// audio, localAudio, skill, and mention. It has no embedded-resource
			// prompt variant, so do not advertise ACP-style embedded context.
			PromptContent: provider.PromptContentCapabilities{Image: true, Audio: true},
			ModelSwitch:   provider.ModelSwitchInSession,
		},
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
	h.mu.Unlock()
	h.rpc.fail(firstError(err, io.EOF))
	h.cancel()
	close(h.processDone)
}

func firstError(err, fallback error) error {
	if err != nil {
		return err
	}
	return fallback
}

func (h *Instance) handleTransportClosed(err error) {
	h.mu.Lock()
	h.transportClosed = true
	h.info.Status = provider.InstanceStatusExited
	h.info.PID = 0
	outcome := provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnFailed, Message: "Codex app-server disconnected unexpectedly"}
	if err != nil {
		outcome.Message += ": " + err.Error()
	}
	if h.closing {
		outcome = provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnCancelled}
	}
	// Running turns end, and so do pending ones: taking a pending turn makes
	// this its outcome, and a request still in flight then fails without
	// reporting it again (releaseTurn).
	type localTurn struct{ thread, turn string }
	var ended []localTurn
	for _, session := range h.sessionsByLocal {
		if nativeTurn := session.activeNativeTurn; nativeTurn != "" {
			ended = append(ended, localTurn{session.localThreadID, h.resolveTurnLocked(session, nativeTurn)})
		}
		if session.pending != nil {
			ended = append(ended, localTurn{session.localThreadID, session.pending.id})
			session.pending = nil
		}
		session.activeNativeTurn = ""
		session.streamed = make(map[string]streamedItem)
	}
	h.mu.Unlock()
	// Without a transport the process is useless; a malformed stream ends it.
	h.process.Kill()
	h.cancel()
	h.cancelPendingApprovals()
	for _, turn := range ended {
		h.endTurn(turn.thread, turn.turn, outcome)
	}
}

func (h *Instance) Close() error {
	h.closeOnce.Do(func() {
		h.mu.Lock()
		intentional := h.info.Status != provider.InstanceStatusExited
		h.closing = intentional
		h.mu.Unlock()
		h.cancelPendingApprovals()
		h.cancel()
		h.process.Stop(stopGrace)
		<-h.processDone
		h.mu.Lock()
		if !intentional {
			h.closeErr = h.processErr
		}
		h.mu.Unlock()
	})
	return h.closeErr
}

func newSessionState(localID, nativeID, cwd string) *sessionState {
	return &sessionState{
		localThreadID: localID, nativeThreadID: nativeID, cwd: cwd,
		nativeToLocalTurn: make(map[string]string), localToNativeTurn: make(map[string]string),
		startedTurns: make(map[string]bool), items: make(map[string]provider.ToolCall), streamed: make(map[string]streamedItem),
	}
}

func (h *Instance) bindSessionLocked(session *sessionState) {
	if old := h.sessionsByLocal[session.localThreadID]; old != nil && old.nativeThreadID != session.nativeThreadID {
		delete(h.localByNative, old.nativeThreadID)
	}
	h.sessionsByLocal[session.localThreadID] = session
	h.localByNative[session.nativeThreadID] = session.localThreadID
}

func (h *Instance) emitEvent(event provider.RuntimeEvent) {
	if h.emit == nil {
		return
	}
	if event.Provider == "" {
		event.Provider = DriverKind
	}
	if event.ProviderInstanceID == "" {
		event.ProviderInstanceID = h.info.InstanceID
	}
	if event.ProviderName == "" {
		event.ProviderName = h.info.Name
	}
	if event.CreatedAt.IsZero() {
		event.CreatedAt = time.Now()
	}
	h.emit(event)
}
