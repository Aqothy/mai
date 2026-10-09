// Package acp adapts ACP agents to maiD's provider contract.
//
// Reasoning replay assumption: session/load replays agent thoughts as one
// agent_thought_chunk per thought with no separators, while live streams
// carry their own paragraph breaks. Replay therefore appends a paragraph
// break after every thought chunk (separateReplayReasoningBlocks). An agent
// that replays a single thought as several sub-newline chunks would gain
// spurious breaks; no supported agent (gemini-cli, claude-code-acp) does.
package acp

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sync"
	"time"

	acp "github.com/Aqothy/go-acp"
	"github.com/Aqothy/go-acp/schema"
	"github.com/Aqothy/maiD/internal/adapters/procgroup"
	"github.com/Aqothy/maiD/internal/provider"
)

const DriverKind provider.DriverKind = "acp"

// Config is the driver-owned provider.start configuration for an ACP process.
type Config struct {
	Command []string          `json:"command"`
	Env     map[string]string `json:"env,omitempty"`
}

// OpenInstance decodes the ACP configuration, starts the agent, initializes the
// connection, and publishes provider-neutral runtime events through emit.
func OpenInstance(ctx context.Context, spec provider.InstanceSpec, emit provider.RuntimeEventListener) (*Instance, error) {
	if spec.InstanceID == "" {
		return nil, fmt.Errorf("missing provider instance id")
	}
	if len(spec.Config) == 0 {
		return nil, fmt.Errorf("missing ACP config")
	}
	var config Config
	if err := json.Unmarshal(spec.Config, &config); err != nil {
		return nil, fmt.Errorf("decode ACP config: %w", err)
	}
	if len(config.Command) == 0 {
		return nil, fmt.Errorf("ACP config requires command")
	}
	if spec.Name == "" {
		spec.Name = filepath.Base(config.Command[0])
	}

	startedAt := time.Now()
	cmd := exec.Command(config.Command[0], config.Command[1:]...)
	cmd.Stderr = os.Stderr
	if len(config.Env) > 0 {
		cmd.Env = append([]string(nil), os.Environ()...)
		for key, value := range config.Env {
			cmd.Env = append(cmd.Env, key+"="+value)
		}
	}
	process, err := procgroup.Start(cmd)
	if err != nil {
		return nil, fmt.Errorf("start ACP agent: %w", err)
	}

	h := newInstance(emit)
	h.config = config
	h.process = process
	logger := slog.Default().With("component", "acp-sdk", "providerInstance", spec.InstanceID)
	if err := h.connectClient(acp.Combine(process.Stdout(), process.Stdin()), logger); err != nil {
		h.cancel()
		process.Stop(0)
		_ = process.Close()
		return nil, err
	}

	initResp, err := h.initializeConnection(ctx)
	if err != nil {
		h.cancel()
		_ = h.conn.Close()
		process.Stop(0)
		_ = process.Close()
		return nil, err
	}

	h.info = provider.InstanceInfo{
		InstanceID:    spec.InstanceID,
		Name:          spec.Name,
		Driver:        DriverKind,
		PID:           process.Pid(),
		Status:        provider.InstanceStatusInitialized,
		StartedAt:     startedAt,
		InitializedAt: h.initializedAt,
		Capabilities:  capabilitySet(initResp),
		Auth:          authStateFromACP(initResp),
	}
	go h.wait()
	return h, nil
}

type Instance struct {
	mu sync.Mutex
	// config is the agent's launch configuration, reused to run terminal
	// sign-in methods.
	config        Config
	process       *procgroup.Process
	conn          *acp.ClientConnection
	agentPeer     *acp.AgentPeer
	ctx           context.Context
	cancel        context.CancelFunc
	initializedAt time.Time
	initialize    schema.InitializeResponse
	info          provider.InstanceInfo

	// sessions holds all per-session state (stream, turn, config, scope, tool
	// reconciliation, pending permissions) keyed by ACP session id;
	// sessionsByThread is the thread->session index. Unbinding a session is
	// deleting its one entry plus the index entry.
	sessions         map[string]*acpSession
	sessionsByThread map[string]string

	runtimeEventListener provider.RuntimeEventListener
	once                 sync.Once
}

func newInstance(listener provider.RuntimeEventListener) *Instance {
	h := &Instance{
		runtimeEventListener: listener,
		sessions:             make(map[string]*acpSession),
		sessionsByThread:     make(map[string]string),
	}
	h.ctx, h.cancel = context.WithCancel(context.Background())
	return h
}

// connectClient wires the go-acp client app over the transport. Only the
// permission handler is registered: session/update is consumed through the
// SDK's session router (per-session ordered streams), and the ACP fs/terminal
// client methods stay unregistered on purpose — unregistered methods answer
// method-not-found, which is the product decision (no fs/terminal support).
func (h *Instance) connectClient(rwc io.ReadWriteCloser, logger *slog.Logger) error {
	app := acp.Client(acp.AppOptions{
		OnInternalError: func(err error) {
			logger.Error("ACP connection internal error", "error", err)
		},
		OnNotificationError: func(err error) {
			logger.Error("ACP notification handler error", "error", err)
		},
	}).OnRequestPermission(func(ctx context.Context, call acp.ClientRequest[schema.RequestPermissionRequest]) (schema.RequestPermissionResponse, error) {
		return h.requestPermission(ctx, call.Params)
	})
	acp.RegisterClientRequest(app, schema.ClientMethodElicitationCreate, func(ctx context.Context, call acp.ClientRequest[json.RawMessage]) (schema.CreateElicitationResponse, error) {
		return h.createElicitation(ctx, call.Params)
	})
	conn, err := app.Connect(h.ctx, rwc)
	if err != nil {
		return fmt.Errorf("connect ACP client: %w", err)
	}
	h.conn = conn
	h.agentPeer = conn.Agent()
	return nil
}

func (h *Instance) initializeConnection(ctx context.Context) (schema.InitializeResponse, error) {
	title := "Mai Daemon"
	terminalAuth := true
	initReq := schema.InitializeRequest{
		ProtocolVersion: schema.CurrentProtocolVersion,
		ClientInfo:      &schema.Implementation{Name: "maiD", Title: &title, Version: "0.1.0"},
		// fs and terminal stay unadvertised on purpose (see connectClient).
		ClientCapabilities: &schema.ClientCapabilities{
			Auth: &schema.AuthCapabilities{Terminal: &terminalAuth},
			Elicitation: &schema.ElicitationCapabilities{
				Form: &schema.ElicitationFormCapabilities{},
				URL:  &schema.ElicitationUrlCapabilities{},
			},
			Session: &schema.ClientSessionCapabilities{
				ConfigOptions: &schema.SessionConfigOptionsCapabilities{Boolean: &schema.BooleanConfigOptionCapabilities{}},
			},
		},
	}
	initResp, err := h.agentPeer.Initialize(ctx, initReq)
	if err != nil {
		return schema.InitializeResponse{}, fmt.Errorf("ACP initialize failed: %w", acpRequestError(err))
	}
	if initResp.ProtocolVersion != schema.CurrentProtocolVersion {
		return schema.InitializeResponse{}, fmt.Errorf("unsupported ACP protocol version %d", initResp.ProtocolVersion)
	}
	if initResp.AuthMethods == nil {
		initResp.AuthMethods = []schema.AuthMethod{}
	}
	h.mu.Lock()
	h.initialize = initResp
	h.initializedAt = time.Now()
	h.mu.Unlock()
	return initResp, nil
}

func (h *Instance) Info() provider.InstanceInfo {
	h.mu.Lock()
	defer h.mu.Unlock()
	return cloneInstanceInfo(h.info)
}

func cloneInstanceInfo(conn provider.InstanceInfo) provider.InstanceInfo {
	conn.Auth.Methods = append([]provider.AuthMethod(nil), conn.Auth.Methods...)
	return conn
}

// Authenticate signs in with an advertised method: agent methods run through
// ACP authenticate; terminal methods run the agent's own command with the
// method's args and env, which the host shows in a terminal.
func (h *Instance) Authenticate(ctx context.Context, input provider.AuthenticateInput) (provider.AuthenticationResult, error) {
	if input.Secret != "" {
		return provider.AuthenticationResult{}, fmt.Errorf("ACP sign-in methods take no secret")
	}
	method, ok := h.authMethod(input.MethodID)
	if !ok || !isSupportedAuthMethod(method) {
		return provider.AuthenticationResult{}, fmt.Errorf("ACP auth method %q was not advertised as a supported method", input.MethodID)
	}
	if !isAgentAuthMethod(method) {
		command := provider.TerminalCommand{Argv: append(slices.Clone(h.config.Command), method.Args...)}
		for _, env := range []map[string]string{h.config.Env, method.Env} {
			for _, key := range slices.Sorted(maps.Keys(env)) {
				command.Env = append(command.Env, key+"="+env[key])
			}
		}
		return provider.AuthenticationResult{Instance: h.Info(), Terminal: &command}, nil
	}
	if _, err := h.agentPeer.Authenticate(ctx, schema.AuthenticateRequest{MethodID: method.ID}); err != nil {
		return provider.AuthenticationResult{}, acpRequestError(err)
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.info.Auth.Status = provider.AuthStatusAuthenticated
	return provider.AuthenticationResult{Instance: cloneInstanceInfo(h.info)}, nil
}

func (h *Instance) authMethod(methodID string) (schema.AuthMethod, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, method := range h.initialize.AuthMethods {
		if string(method.ID) == methodID {
			return method, true
		}
	}
	return schema.AuthMethod{}, false
}

// noteAuthRequired records that the agent refused a request with
// auth_required, so clients offer sign-in for this provider.
func (h *Instance) noteAuthRequired(err error) {
	var requestErr *provider.RequestError
	if !errors.As(acpRequestError(err), &requestErr) || int64(requestErr.Code) != acp.CodeAuthentication {
		return
	}
	h.mu.Lock()
	h.info.Auth.Status = provider.AuthStatusUnauthenticated
	h.mu.Unlock()
}

func (h *Instance) Logout(ctx context.Context) (provider.InstanceInfo, error) {
	if !h.Info().Capabilities.Logout {
		return provider.InstanceInfo{}, fmt.Errorf("ACP agent did not advertise logout capability")
	}
	_, err := h.agentPeer.Logout(ctx, schema.LogoutRequest{})
	if err != nil {
		return provider.InstanceInfo{}, acpRequestError(err)
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	h.info.Auth.Status = provider.AuthStatusUnauthenticated
	return cloneInstanceInfo(h.info), nil
}

// stopGrace is how long the agent gets to exit on its own once stdin closes.
const stopGrace = 5 * time.Second

// drainTimeout bounds reading what an exited agent wrote last.
const drainTimeout = 2 * time.Second

func (h *Instance) Close() error {
	h.once.Do(func() {
		if h.cancel != nil {
			h.cancel()
		}
		if h.process != nil {
			h.process.Stop(stopGrace)
		}
		if h.conn != nil {
			_ = h.conn.Close()
		}
	})
	return nil
}

// wait retires the agent process once it exits, after the connection has
// read what the agent wrote last.
func (h *Instance) wait() {
	h.process.Drain(h.conn.Done(), drainTimeout)
	h.mu.Lock()
	h.info.Status = provider.InstanceStatusExited
	h.mu.Unlock()
}

func newID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	buf := make([]byte, 36)
	hex.Encode(buf[0:8], b[0:4])
	buf[8] = '-'
	hex.Encode(buf[9:13], b[4:6])
	buf[13] = '-'
	hex.Encode(buf[14:18], b[6:8])
	buf[18] = '-'
	hex.Encode(buf[19:23], b[8:10])
	buf[23] = '-'
	hex.Encode(buf[24:36], b[10:16])
	return string(buf)
}
