// Package codexapp adapts the stable Codex app-server protocol to maiD's
// provider-neutral runtime contract.
package codexapp

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

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
	skills         []provider.Skill
	configOptions  []provider.ConfigOption

	pendingLocalTurn  string
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
}

type optionsState struct {
	selectedModel  string
	selectedEffort string
	selectedTier   string
	callbacks      provider.OptionsSessionCallbacks
}

type Instance struct {
	mu     sync.Mutex
	info   provider.InstanceInfo
	emit   provider.RuntimeEventListener
	logger *slog.Logger

	ctx    context.Context
	cancel context.CancelFunc
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout io.ReadCloser
	rpc    *rpcClient

	sessionsByLocal  map[string]*sessionState
	localByNative    map[string]string
	pendingApprovals map[string]*pendingApproval
	models           []appModel
	options          map[string]*optionsState

	processDone     chan struct{}
	processErr      error
	closing         bool
	transportClosed bool
	// reaped/killedTree fence process-group cleanup. Once Wait has reaped the
	// leader its pid must never be signalled later by Close, because the OS may
	// recycle it for an unrelated process. A wrapper that exits before its real
	// app-server child is cleaned up once from waitProcess instead.
	reaped     bool
	killedTree bool
	closeOnce  sync.Once
	closeErr   error
}

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
	configureProcessGroup(command)
	stdin, err := command.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("open Codex app-server stdin: %w", err)
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return nil, fmt.Errorf("open Codex app-server stdout: %w", err)
	}
	if err := command.Start(); err != nil {
		_ = stdin.Close()
		_ = stdout.Close()
		return nil, fmt.Errorf("start %s: %w", filepath.Base(config.Command[0]), err)
	}

	h := &Instance{
		emit:   emit,
		logger: slog.Default().With("component", "codex-app-server", "providerInstance", spec.InstanceID),
		cmd:    command, stdin: stdin, stdout: stdout,
		sessionsByLocal:  make(map[string]*sessionState),
		localByNative:    make(map[string]string),
		pendingApprovals: make(map[string]*pendingApproval),
		options:          make(map[string]*optionsState),
		processDone:      make(chan struct{}),
	}
	h.ctx, h.cancel = context.WithCancel(context.Background())
	h.rpc = newRPCClient(stdout, stdin)
	h.rpc.onNotification = h.handleNotification
	h.rpc.onRequest = h.handleServerRequest
	h.rpc.onClose = h.handleTransportClosed
	h.info = provider.InstanceInfo{
		InstanceID: spec.InstanceID, Name: spec.Name, Driver: DriverKind,
		PID: command.Process.Pid, Status: provider.InstanceStatusConfigured,
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

	var response initializeResponse
	params := initializeParams{
		ClientInfo: appClientInfo{Name: "maiD", Title: "maiD", Version: "beta"},
		Capabilities: appClientCapabilities{
			ExperimentalAPI:    false,
			RequestAttestation: false,
		},
	}
	if err := h.rpc.call(ctx, "initialize", params, &response); err != nil {
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
	err := h.cmd.Wait()
	h.mu.Lock()
	h.reaped = true
	h.processErr = err
	h.info.Status = provider.InstanceStatusExited
	h.info.PID = 0
	killed := h.killedTree
	h.killedTree = true
	h.mu.Unlock()
	if !killed {
		killProcessTree(h.cmd)
	}
	if err == nil {
		err = io.EOF
	}
	h.rpc.fail(err)
	h.cancel()
	// Let the reader finish delivering its terminal notifications before
	// process cleanup is considered complete. Its close callback settles any
	// turns for which app-server could no longer send a completion.
	<-h.rpc.runDone
	close(h.processDone)
}

func (h *Instance) handleTransportClosed(err error) {
	h.mu.Lock()
	h.transportClosed = true
	h.info.Status = provider.InstanceStatusExited
	h.info.PID = 0
	closing := h.closing
	shouldKill := !h.reaped && !h.killedTree
	if shouldKill {
		h.killedTree = true
	}
	var activeTurns []provider.RuntimeEvent
	for _, session := range h.sessionsByLocal {
		if nativeTurn := session.activeNativeTurn; nativeTurn != "" {
			state := provider.RuntimeTurnFailed
			message := "Codex app-server disconnected unexpectedly"
			if err != nil {
				message += ": " + err.Error()
			}
			if closing {
				state, message = provider.RuntimeTurnCancelled, ""
			}
			activeTurns = append(activeTurns, provider.RuntimeEvent{
				Type: provider.RuntimeEventTurnCompleted, ThreadID: session.localThreadID,
				TurnID:  h.resolveTurnLocked(session, nativeTurn),
				Payload: provider.RuntimeEventPayload{TurnState: state, StopReason: "connection_closed", Message: message},
			})
		}
		// A pending turn/start is released by rpc.fail and its caller records
		// the dispatch error. Only already-started turns need an async outcome.
		session.activeNativeTurn = ""
		session.streamed = make(map[string]streamedItem)
	}
	h.mu.Unlock()
	if shouldKill {
		killProcessTree(h.cmd)
	}
	h.cancel()
	h.cancelPendingApprovals()
	for _, event := range activeTurns {
		h.emitEvent(event)
	}
}

func (h *Instance) Close() error {
	h.closeOnce.Do(func() {
		h.mu.Lock()
		intentional := h.info.Status != provider.InstanceStatusExited
		h.closing = intentional
		shouldKill := !h.reaped && !h.killedTree
		if shouldKill {
			h.killedTree = true
		}
		h.mu.Unlock()
		h.cancelPendingApprovals()
		h.cancel()
		_ = h.stdin.Close()
		_ = h.stdout.Close()
		if shouldKill {
			killProcessTree(h.cmd)
		}
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
