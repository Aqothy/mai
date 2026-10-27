// Package claudecode adapts the Claude Code CLI's stream-json protocol (the
// same wire protocol the official Claude Agent SDKs speak) to maiD's provider
// contract. Each live session owns one CLI subprocess; a short-lived probe
// process supplies the account, model catalog, and command list without
// making any API calls. A session's transcript is its native history.
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

// historyVersion changes whenever transcripts map to entries differently.
const historyVersion = 1

type Config struct {
	Command []string          `json:"command,omitempty"`
	Env     map[string]string `json:"env,omitempty"`
	// ConfigDir overrides CLAUDE_CONFIG_DIR. HOME is deliberately never
	// touched: overriding it breaks the macOS keychain OAuth lookup and the
	// CLI reports "Not logged in" even for a logged-in user.
	ConfigDir string `json:"configDir,omitempty"`
}

// Driver is the Claude Code driver.
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
		MCP:                   provider.MCPCapabilities{HTTP: true, Stdio: true},
		AdditionalDirectories: true, Sessions: true, Delete: true, Rename: true, Auth: true, Logout: true,
		// The stream-json user message accepts base64 image blocks. Audio
		// and embedded-resource blocks are not part of the SDK prompt
		// surface, so they are not advertised.
		PromptContent: provider.PromptContentCapabilities{Image: true},
	}
}

// accessModes rates the CLI's permission modes. Plan mode and
// dontAsk refuse what isn't pre-approved; auto decides without asking.
func accessModes() *provider.AccessModes {
	return &provider.AccessModes{Option: "permission_mode", Levels: map[string]provider.AccessLevel{
		"plan": provider.AccessReadOnly, "dontAsk": provider.AccessReadOnly, "default": provider.AccessAsk,
		"acceptEdits": provider.AccessEdit, "auto": provider.AccessFull, "bypassPermissions": provider.AccessFull,
	}}
}

// sessionProcess owns one CLI subprocess. done is closed once waitProcess
// has retired it; closing marks a deliberate stop.
type sessionProcess struct {
	process *procgroup.Process
	client  *streamClient
	done    chan struct{}
	closing bool
	// mcpConfig is the file holding the session's MCP servers, removed with
	// the process.
	mcpConfig string
}

// claudeSession is a live session. Its mapper and the stream state are
// touched only by the process's reader, in read order; the rest under h.mu.
type claudeSession struct {
	id             string
	cwd            string
	additionalDirs []string
	model          string
	effort         string
	permissionMode string
	instructions   string
	mcp            *provider.MCPServer
	skills         []provider.Skill
	options        []provider.ConfigOption

	proc *sessionProcess

	// mapMu orders the live mapping: the reader maps and emits under it.
	mapMu sync.Mutex
	live  *mapper
	// unechoed are messages written that the CLI hasn't read yet.
	unechoed map[string]bool
	// tasks are the background tasks of running tools, by tool use id,
	// which stop_task names.
	tasks map[string]string
	// subagents are the session's subagents by the tool use that runs them.
	subagents map[string]*subagent

	// title is the session title last published (see publishTitle).
	title string
	// activeModel is the model id the CLI reports it runs.
	activeModel string
	// Usage carried across turns.
	contextTokens int
	contextWindow int
	costUSD       float64
}

// subagent is a provider subagent whose messages stream live.
type subagent struct {
	key  string
	live *mapper
}

type toolState struct {
	call     provider.ToolCall
	itemKind provider.ItemKind
	title    string
	// text is what a tool that delivers a message (SubagentHandback) said.
	text string
	// input is the tool's latest parsed input.
	input json.RawMessage
}

type pendingApproval struct {
	controlRequestID string
	requestID        string
	session          string
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
	provider.Unsupported

	mu     sync.Mutex
	info   provider.InstanceInfo
	config Config
	host   provider.Host
	logger *slog.Logger

	sessions         map[string]*claudeSession
	pendingApprovals map[string]*pendingApproval
	models           []sdkModel
	commands         []sdkCommand
	// defaultPermissionMode is the mode a session starts in without a
	// selection, from the user's settings.
	defaultPermissionMode string
	options               map[string]*optionsState
	// emptyReads are the transcripts whose last read found nothing new.
	emptyReads map[string]transcriptRead

	closeOnce sync.Once
}

func OpenInstance(ctx context.Context, spec provider.InstanceSpec, host provider.Host) (*Instance, error) {
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
		host:             host,
		logger:           slog.Default().With("component", "claude-code", "providerInstance", spec.InstanceID),
		sessions:         make(map[string]*claudeSession),
		pendingApprovals: make(map[string]*pendingApproval),
		options:          make(map[string]*optionsState),
		emptyReads:       make(map[string]transcriptRead),
	}
	h.info = provider.InstanceInfo{
		InstanceID: spec.InstanceID, Name: spec.Name, Driver: DriverKind,
		Status: provider.InstanceStatusConfigured, StartedAt: time.Now(),
		Capabilities: capabilities(), Access: accessModes(),
		Auth: provider.Auth{Status: provider.AuthStatusUnknown, Methods: claudeAuthMethods()},
	}
	// The probe performs the SDK initialize handshake only — the CLI answers
	// it before any API request, so this is free and works logged-out too.
	if err := h.probe(ctx); err != nil {
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
		h.mu.Lock()
		sessions := make([]*claudeSession, 0, len(h.sessions))
		for _, session := range h.sessions {
			sessions = append(sessions, session)
		}
		h.info.Status = provider.InstanceStatusExited
		h.mu.Unlock()
		var stopped sync.WaitGroup
		for _, session := range sessions {
			stopped.Go(func() { h.stopProcess(session) })
		}
		stopped.Wait()
	})
	return nil
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

// probeTimeout bounds the OpenInstance handshake when the caller supplied no
// deadline of its own.
const probeTimeout = 30 * time.Second

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

func (h *Instance) session(key string) (*claudeSession, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessions[key]
	if session == nil {
		return nil, fmt.Errorf("Claude Code session %q is not open", key)
	}
	return session, nil
}

func (h *Instance) emit(session string, body provider.EventBody) {
	h.emitAt(session, body, time.Now())
}

func (h *Instance) emitAt(session string, body provider.EventBody, at time.Time) {
	if h.host.Emit != nil {
		h.host.Emit(provider.Event{Session: session, At: at, Body: body})
	}
}
