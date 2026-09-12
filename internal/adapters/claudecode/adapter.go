// Package claudecode adapts the Claude Code CLI's stream-json protocol (the
// same wire protocol the official Claude Agent SDKs speak) to maiD's
// provider-neutral runtime contract. Each thread owns one CLI subprocess; a
// short-lived probe process supplies the account, model catalog, and command
// list without making any API calls.
package claudecode

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

const DriverKind provider.DriverKind = "claude-code"

type Config struct {
	Command []string          `json:"command,omitempty"`
	Env     map[string]string `json:"env,omitempty"`
	// ConfigDir overrides CLAUDE_CONFIG_DIR. HOME is deliberately never
	// touched: overriding it breaks the macOS keychain OAuth lookup and the
	// CLI reports "Not logged in" even for a logged-in user.
	ConfigDir string `json:"configDir,omitempty"`
}

// sessionProcess owns one CLI subprocess. reaped/killedTree fence
// process-group cleanup exactly like codexapp: once Wait has reaped the
// leader its pid must never be signalled again because the OS may recycle it.
type sessionProcess struct {
	cmd        *exec.Cmd
	stdin      io.WriteCloser
	client     *streamClient
	done       chan struct{}
	reaped     bool
	killedTree bool
	closing    bool
}

type claudeSession struct {
	localThreadID   string
	nativeSessionID string
	cwd             string
	additionalDirs  []string
	model           string
	effort          string
	permissionMode  string
	skills          []provider.Skill
	configOptions   []provider.ConfigOption

	proc *sessionProcess

	// Claude Code has no native turn ids: a turn spans one queued user
	// message up to its result line. The daemon's turn ids are authoritative;
	// queuedTurns preserves FIFO order for messages sent while a turn runs.
	activeLocalTurn string
	queuedTurns     []string

	// Streaming state for the in-flight assistant message.
	toolStates   map[string]*toolState
	openBlocks   map[int]string
	streamedText map[string]string
	itemSeq      int

	// Usage carried across turns for live token reporting.
	contextWindow int
	costUSD       float64
}

type toolState struct {
	call        provider.ToolCall
	itemKind    provider.ItemKind
	title       string
	partialJSON string
	fingerprint string
	completed   bool
}

type pendingApproval struct {
	controlRequestID string
	requestID        string
	localThread      string
	localTurn        string
	requestType      provider.RuntimeRequestType
	toolName         string
	input            json.RawMessage
	suggestions      []json.RawMessage
	question         *askUserQuestion
	client           *streamClient
}

type optionsState struct {
	selectedModel  string
	selectedEffort string
	selectedMode   string
	options        []provider.ConfigOption
	callbacks      provider.OptionsSessionCallbacks
}

type Instance struct {
	mu     sync.Mutex
	info   provider.InstanceInfo
	config Config
	emit   provider.RuntimeEventListener
	logger *slog.Logger

	ctx    context.Context
	cancel context.CancelFunc

	sessionsByLocal  map[string]*claudeSession
	localByNative    map[string]string
	pendingApprovals map[string]*pendingApproval
	models           []sdkModel
	commands         []sdkCommand
	account          *sdkAccount
	options          map[string]*optionsState

	closeOnce sync.Once
	closeErr  error
}

func OpenInstance(ctx context.Context, spec provider.InstanceSpec, emit provider.RuntimeEventListener) (*Instance, error) {
	if spec.InstanceID == "" {
		return nil, fmt.Errorf("missing provider instance id")
	}
	config := Config{Command: []string{"claude"}}
	if len(spec.Config) > 0 {
		if err := json.Unmarshal(spec.Config, &config); err != nil {
			return nil, fmt.Errorf("decode Claude Code config: %w", err)
		}
	}
	if len(config.Command) == 0 {
		config.Command = []string{"claude"}
	}
	if spec.Name == "" {
		spec.Name = "Claude Code"
	}
	if _, err := exec.LookPath(config.Command[0]); err != nil {
		return nil, fmt.Errorf("locate Claude Code CLI %q: %w", config.Command[0], err)
	}

	h := &Instance{
		config:           config,
		emit:             emit,
		logger:           slog.Default().With("component", "claude-code", "providerInstance", spec.InstanceID),
		sessionsByLocal:  make(map[string]*claudeSession),
		localByNative:    make(map[string]string),
		pendingApprovals: make(map[string]*pendingApproval),
		options:          make(map[string]*optionsState),
	}
	h.ctx, h.cancel = context.WithCancel(context.Background())
	h.info = provider.InstanceInfo{
		InstanceID: spec.InstanceID,
		Name:       spec.Name,
		Driver:     DriverKind,
		Status:     provider.InstanceStatusConfigured,
		StartedAt:  time.Now(),
		Capabilities: provider.Capabilities{
			SessionList:           true,
			SessionDelete:         true,
			SessionClose:          true,
			LoadReplay:            true,
			Resume:                true,
			Fork:                  true,
			Skills:                true,
			ConfigOptions:         true,
			AdditionalDirectories: true,
			// The stream-json user message accepts base64 image blocks. Audio
			// and embedded-resource blocks are not part of the SDK prompt
			// surface, so they are not advertised.
			PromptContent: provider.PromptContentCapabilities{Image: true},
			ModelSwitch:   provider.ModelSwitchInSession,
		},
		Auth: provider.Auth{Status: provider.AuthStatusUnknown},
	}
	// The probe performs the SDK initialize handshake only — the CLI answers
	// it before any API request, so this is free and works logged-out too.
	if err := h.probe(ctx); err != nil {
		h.cancel()
		return nil, fmt.Errorf("initialize Claude Code CLI: %w", err)
	}
	h.mu.Lock()
	h.info.Status = provider.InstanceStatusInitialized
	h.info.InitializedAt = time.Now()
	h.mu.Unlock()
	return h, nil
}

func (h *Instance) Info() provider.InstanceInfo {
	h.mu.Lock()
	defer h.mu.Unlock()
	info := h.info
	info.Auth.Methods = append([]provider.AuthMethod(nil), h.info.Auth.Methods...)
	return info
}

func (h *Instance) Close() error {
	h.closeOnce.Do(func() {
		h.cancel()
		h.mu.Lock()
		sessions := make([]*claudeSession, 0, len(h.sessionsByLocal))
		for _, session := range h.sessionsByLocal {
			sessions = append(sessions, session)
		}
		h.info.Status = provider.InstanceStatusExited
		h.mu.Unlock()
		h.cancelPendingApprovals()
		for _, session := range sessions {
			h.stopProcess(session)
		}
	})
	return h.closeErr
}

// buildCommand assembles one CLI invocation with the shared stream-json flags.
func (h *Instance) buildCommand(cwd string, extra []string) *exec.Cmd {
	args := append([]string(nil), h.config.Command[1:]...)
	args = append(args,
		"--print",
		"--input-format", "stream-json",
		"--output-format", "stream-json",
		"--verbose",
	)
	args = append(args, extra...)
	command := exec.Command(h.config.Command[0], args...)
	command.Dir = cwd
	command.Stderr = os.Stderr
	env := append([]string(nil), os.Environ()...)
	if h.config.ConfigDir != "" {
		env = append(env, "CLAUDE_CONFIG_DIR="+h.config.ConfigDir)
	}
	for key, value := range h.config.Env {
		env = append(env, key+"="+value)
	}
	command.Env = env
	configureProcessGroup(command)
	return command
}

// configDir resolves where the CLI persists sessions and settings.
func (h *Instance) configDir() string {
	if h.config.ConfigDir != "" {
		return h.config.ConfigDir
	}
	if fromEnv := os.Getenv("CLAUDE_CONFIG_DIR"); fromEnv != "" {
		return fromEnv
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".claude")
}

func (h *Instance) sessionForLocal(localID string) (*claudeSession, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessionsByLocal[localID]
	if session == nil {
		return nil, fmt.Errorf("Claude Code thread %q is not bound", localID)
	}
	return session, nil
}

func (h *Instance) bindSessionLocked(session *claudeSession) {
	if old := h.sessionsByLocal[session.localThreadID]; old != nil && old.nativeSessionID != session.nativeSessionID {
		delete(h.localByNative, old.nativeSessionID)
	}
	h.sessionsByLocal[session.localThreadID] = session
	h.localByNative[session.nativeSessionID] = session.localThreadID
}

func newClaudeSession(localID, nativeID, cwd string) *claudeSession {
	return &claudeSession{
		localThreadID:   localID,
		nativeSessionID: nativeID,
		cwd:             cwd,
		toolStates:      make(map[string]*toolState),
		openBlocks:      make(map[int]string),
		streamedText:    make(map[string]string),
	}
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
