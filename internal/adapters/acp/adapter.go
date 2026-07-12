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
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	acp "github.com/Aqothy/go-acp"
	"github.com/Aqothy/go-acp/schema"
	"github.com/Aqothy/maiD/internal/provider"
)

const DriverKind provider.DriverKind = "acp"

// Config is the driver-owned provider.start configuration for an ACP process.
type Config struct {
	Command []string `json:"command"`
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
	configureProcessGroup(cmd)

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("open ACP stdin: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return nil, fmt.Errorf("open ACP stdout: %w", err)
	}
	if err := cmd.Start(); err != nil {
		_ = stdin.Close()
		_ = stdout.Close()
		return nil, fmt.Errorf("start ACP agent: %w", err)
	}

	h := newInstance(emit)
	h.cmd = cmd
	h.stdin = stdin
	h.stdout = stdout
	logger := slog.Default().With("component", "acp-sdk", "providerInstance", spec.InstanceID)
	if err := h.connectClient(acp.Combine(stdout, stdin), logger); err != nil {
		h.cancel()
		_ = h.closeIO()
		killProcessTree(cmd)
		_ = cmd.Wait()
		return nil, err
	}

	initResp, err := h.initializeConnection(ctx)
	if err != nil {
		h.cancel()
		_ = h.conn.Close()
		_ = h.closeIO()
		killProcessTree(cmd)
		_ = cmd.Wait()
		return nil, err
	}

	rawInit, _ := json.Marshal(initResp)
	h.info = provider.InstanceInfo{
		InstanceID:    spec.InstanceID,
		Name:          spec.Name,
		Driver:        DriverKind,
		PID:           cmd.Process.Pid,
		Status:        provider.InstanceStatusInitialized,
		StartedAt:     startedAt,
		InitializedAt: h.initializedAt,
		Capabilities:  capabilitySet(initResp),
		Auth:          authStateFromACP(initResp),
		Metadata:      metadataFromInitialize(initResp, rawInit),
	}
	go h.wait()
	return h, nil
}

type Instance struct {
	mu            sync.Mutex
	cmd           *exec.Cmd
	stdin         io.WriteCloser
	stdout        io.ReadCloser
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
	// reaped is set once wait() has reaped the agent process. From then on the
	// agent's pid and process group id may be recycled by unrelated processes,
	// so Close must no longer signal them. It is set (under mu) BEFORE wait
	// does any post-reap signalling, so Close can never observe a stale false
	// after the reap.
	reaped bool
	// killedTree coordinates Close and wait so at most one of them runs
	// killProcessTree. Guarded by mu.
	killedTree bool
	once       sync.Once
	closeErr   error
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
	conn, err := app.Connect(h.ctx, rwc)
	if err != nil {
		return fmt.Errorf("connect ACP client: %w", err)
	}
	h.conn = conn
	h.agentPeer = conn.Agent()
	return nil
}

func (h *Instance) agent() *acp.AgentPeer { return h.agentPeer }

func (h *Instance) initializeConnection(ctx context.Context) (schema.InitializeResponse, error) {
	title := "Mai Daemon"
	initReq := schema.InitializeRequest{
		ProtocolVersion:    schema.CurrentProtocolVersion,
		ClientCapabilities: &schema.ClientCapabilities{},
		ClientInfo:         &schema.Implementation{Name: "maiD", Title: &title, Version: "0.1.0"},
	}
	initResp, err := h.agent().Initialize(ctx, initReq)
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
	if conn.Metadata != nil {
		metadata := make(map[string]json.RawMessage, len(conn.Metadata))
		for key, value := range conn.Metadata {
			metadata[key] = append(json.RawMessage(nil), value...)
		}
		conn.Metadata = metadata
	}
	return conn
}

func (h *Instance) Authenticate(ctx context.Context, methodID string) (provider.InstanceInfo, error) {
	resolvedMethodID, err := h.resolveAuthMethodID(methodID)
	if err != nil {
		return provider.InstanceInfo{}, err
	}
	resp, err := h.agent().Authenticate(ctx, schema.AuthenticateRequest{MethodID: schema.AuthMethodId(resolvedMethodID)})
	if err != nil {
		return provider.InstanceInfo{}, acpRequestError(err)
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	if h.info.Metadata == nil {
		h.info.Metadata = make(map[string]json.RawMessage)
	}
	now := time.Now()
	h.info.Auth.Status = provider.AuthStatusAuthenticated
	h.info.Metadata["authenticatedAt"] = marshalRaw(now)
	h.info.Metadata["authenticatedMethodId"] = marshalRaw(resolvedMethodID)
	h.info.Metadata["authenticateResponse"] = marshalRaw(resp)
	return cloneInstanceInfo(h.info), nil
}

func (h *Instance) Logout(ctx context.Context) (provider.InstanceInfo, error) {
	if !h.Info().Capabilities.Logout {
		return provider.InstanceInfo{}, fmt.Errorf("ACP agent did not advertise logout capability")
	}
	resp, err := h.agent().Logout(ctx, schema.LogoutRequest{})
	if err != nil {
		return provider.InstanceInfo{}, acpRequestError(err)
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	if h.info.Metadata == nil {
		h.info.Metadata = make(map[string]json.RawMessage)
	}
	h.info.Auth.Status = provider.AuthStatusUnauthenticated
	h.info.Metadata["loggedOutAt"] = marshalRaw(time.Now())
	h.info.Metadata["logoutResponse"] = marshalRaw(resp)
	return cloneInstanceInfo(h.info), nil
}

func (h *Instance) Close() error {
	h.once.Do(func() {
		if h.cancel != nil {
			h.cancel()
		}
		if h.conn != nil {
			_ = h.conn.Close()
		}
		h.closeErr = h.closeIO()
		// Signal while holding mu: wait() sets reaped under the same lock as
		// the very first thing after cmd.Wait() returns, so a false reaped
		// here means the process is still un-reaped (at worst a zombie) and
		// its pid/pgid cannot have been recycled while we signal it.
		h.mu.Lock()
		if !h.reaped && !h.killedTree {
			h.killedTree = true
			killProcessTree(h.cmd)
		}
		h.mu.Unlock()
	})
	return h.closeErr
}

func (h *Instance) wait() {
	_ = h.cmd.Wait()
	// The leader is reaped: record that (and claim the kill) BEFORE any
	// signalling, so Close never signals a recycled pid/pgid and at most one
	// killProcessTree runs.
	h.mu.Lock()
	h.reaped = true
	h.info.Status = provider.InstanceStatusExited
	killed := h.killedTree
	h.killedTree = true
	h.mu.Unlock()
	if !killed {
		// Wrappers may background the real agent and exit first. Terminate the
		// process group immediately after reaping the leader, while its
		// descendants still make the group identity unambiguous.
		killProcessTree(h.cmd)
	}
	_ = h.closeIO()
}

func (h *Instance) closeIO() error {
	var errs []error
	if h.stdin != nil {
		errs = append(errs, h.stdin.Close())
	}
	if h.stdout != nil {
		errs = append(errs, h.stdout.Close())
	}
	return errors.Join(errs...)
}

func (h *Instance) resolveAuthMethodID(methodID string) (string, error) {
	if methodID == "" {
		return "", fmt.Errorf("ACP authenticate requires a method id")
	}
	h.mu.Lock()
	methods := append([]schema.AuthMethod(nil), h.initialize.AuthMethods...)
	h.mu.Unlock()
	for _, method := range methods {
		if authMethodID(method) == methodID {
			return methodID, nil
		}
	}
	return "", fmt.Errorf("ACP auth method %q was not advertised as a supported agent auth method", methodID)
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
