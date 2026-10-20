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
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/Aqothy/maiD/internal/adapters/elicitation"
	"github.com/Aqothy/maiD/internal/adapters/procgroup"
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

// sessionProcess owns one CLI subprocess. done is closed once waitProcess
// has retired it; closing marks a deliberate stop.
type sessionProcess struct {
	process *procgroup.Process
	client  *streamClient
	done    chan struct{}
	closing bool
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

	// Claude Code has no native turn ids, so one turn id at a time stands for
	// the CLI's work: from the message that starts it to the result that ends
	// it. The CLI folds a message written mid-turn into the running query at
	// its next tool boundary and echoes it (--replay-user-messages); a message
	// it could not fold runs as one more query with its own result. So a
	// result that arrives while a written message is still unechoed does not
	// end the turn: the next result does.
	activeLocalTurn string
	// cliStartedTurn marks an activeLocalTurn the CLI began on its own, when
	// a background task or agent finishing woke it.
	cliStartedTurn bool
	// turnLine is the uuid of one of activeLocalTurn's transcript lines: the
	// prompt written to start it, or the first message of a turn the CLI
	// started. A fork through the turn ends at the turn's last line.
	turnLine      string
	unechoedInput map[string]bool

	// Streaming state for the in-flight assistant message.
	toolStates   map[string]*toolState
	openBlocks   map[int]string
	streamedText map[string]string
	itemSeq      int
	// seenAssistant holds the assistant messages already shown: after
	// /compact the CLI sends the last kept one again.
	seenAssistant map[string]bool
	// compactionItem is the item of a compaction in progress.
	compactionItem string
	// tasks is the plan the CLI keeps with its Task tools.
	tasks taskPlan
	// background holds the tools still running as background tasks, by
	// tool use id.
	background map[string]backgroundTool
	// title is the session title last published (see publishTitle).
	title string

	// activeModel is the model id the CLI reports it runs.
	activeModel string

	// Usage carried across turns for live token reporting.
	contextTokens int
	contextWindow int
	costUSD       float64
}

type toolState struct {
	call     provider.ToolCall
	itemKind provider.ItemKind
	title    string
	// input is the tool's latest parsed input.
	input       json.RawMessage
	partialJSON string
	fingerprint string
	// taskID is the CLI task the tool started (system/task_started), which
	// stop_task names.
	taskID string
}

// backgroundTool is a tool item that runs on as a background task after its
// turn, until the task's notification.
type backgroundTool struct {
	state *toolState
	turn  string
}

type pendingApproval struct {
	controlRequestID string
	requestID        string
	localThread      string
	localTurn        string
	requestType      provider.RuntimeRequestType
	input            json.RawMessage
	suggestions      []json.RawMessage
	// question is set for AskUserQuestion, reviewsPlan for ExitPlanMode, and
	// isElicitation for an MCP server's elicitation, with form set in form mode.
	question      *askUserQuestion
	reviewsPlan   bool
	isElicitation bool
	form          *elicitation.Form
	client        *streamClient
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
	// defaultPermissionMode is the mode a session starts in without a
	// selection, from the user's settings.
	defaultPermissionMode string
	options               map[string]*optionsState

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
			AdditionalDirectories: true,
			Auth:                  true,
			Logout:                true,
			// The stream-json user message accepts base64 image blocks. Audio
			// and embedded-resource blocks are not part of the SDK prompt
			// surface, so they are not advertised.
			PromptContent: provider.PromptContentCapabilities{Image: true},
		},
		Auth: provider.Auth{Status: provider.AuthStatusUnknown, Methods: claudeAuthMethods()},
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
		var stopped sync.WaitGroup
		for _, session := range sessions {
			stopped.Go(func() { h.stopProcess(session) })
		}
		stopped.Wait()
	})
	return h.closeErr
}

// startCLI starts one CLI process with the shared stream-json flags and its
// stream client, whose handlers must be set before client.start.
func (h *Instance) startCLI(cwd string, extra []string) (*procgroup.Process, *streamClient, error) {
	argv := h.cliArgv("--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose")
	argv = append(argv, extra...)
	command := exec.Command(argv[0], argv[1:]...)
	command.Dir = cwd
	command.Stderr = os.Stderr
	command.Env = h.commandEnv()
	process, err := procgroup.Start(command)
	if err != nil {
		return nil, nil, err
	}
	return process, newStreamClient(process.Stdout(), process.Stdin()), nil
}

// stopGrace is how long a stopped CLI gets to exit on its own after stdin
// closes; it flushes the session transcript then (as the SDKs wait for).
const stopGrace = 5 * time.Second

// drainTimeout bounds reading what an exited CLI wrote last.
const drainTimeout = 2 * time.Second

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
		seenAssistant:   make(map[string]bool),
		background:      make(map[string]backgroundTool),
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
