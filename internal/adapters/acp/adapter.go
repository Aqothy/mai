package acp

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/Aqothy/maiD/internal/adapters"
	acpclient "github.com/Aqothy/maiD/internal/adapters/acp/client"
	protocol "github.com/Aqothy/maiD/internal/adapters/acp/protocol"
	"github.com/Aqothy/maiD/internal/model"
)

type Adapter struct{}

func New() *Adapter { return &Adapter{} }

func (a *Adapter) StartConnection(ctx context.Context, req adapters.StartConnectionRequest) (adapters.ConnectionHandle, error) {
	if len(req.Command) == 0 {
		return nil, fmt.Errorf("missing ACP adapter command")
	}
	if req.Name == "" {
		req.Name = filepath.Base(req.Command[0])
	}

	startedAt := time.Now()
	cmd := exec.Command(req.Command[0], req.Command[1:]...)
	cmd.Stderr = os.Stderr

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

	client := acpclient.NewConnection(stdin, stdout)
	initResp, err := client.InitializeConnection(ctx)
	if err != nil {
		_ = client.Close()
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
		return nil, err
	}

	rawInit, _ := json.Marshal(initResp)
	h := &Handle{
		cmd:    cmd,
		client: client,
		info: model.AgentConnection{
			Name:          req.Name,
			Kind:          model.AgentKindACP,
			Command:       append([]string(nil), req.Command...),
			PID:           cmd.Process.Pid,
			Status:        model.ConnectionStatusInitialized,
			StartedAt:     startedAt,
			InitializedAt: client.InitializedAt,
			Capabilities:  capabilitySet(initResp.AgentCapabilities),
			Metadata:      metadataFromInitialize(initResp, rawInit),
		},
	}
	go h.wait()
	return h, nil
}

type Handle struct {
	mu     sync.Mutex
	cmd    *exec.Cmd
	client *acpclient.Connection
	info   model.AgentConnection
	once   sync.Once
}

func (h *Handle) Info() model.AgentConnection {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.info
}

func (h *Handle) Authenticate(ctx context.Context, methodID string) (model.AgentConnection, error) {
	resp, err := h.client.Authenticate(ctx, methodID)
	if err != nil {
		return model.AgentConnection{}, err
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	if h.info.Metadata == nil {
		h.info.Metadata = make(map[string]json.RawMessage)
	}
	now := time.Now()
	h.info.Metadata["authenticatedAt"] = marshalRaw(now)
	h.info.Metadata["authenticatedMethodId"] = marshalRaw(methodID)
	h.info.Metadata["authenticateResponse"] = marshalRaw(resp)
	return h.info, nil
}

func (h *Handle) Logout(ctx context.Context) (model.AgentConnection, error) {
	resp, err := h.client.Logout(ctx)
	if err != nil {
		return model.AgentConnection{}, err
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	if h.info.Metadata == nil {
		h.info.Metadata = make(map[string]json.RawMessage)
	}
	h.info.Metadata["loggedOutAt"] = marshalRaw(time.Now())
	h.info.Metadata["logoutResponse"] = marshalRaw(resp)
	return h.info, nil
}

func (h *Handle) NewSession(ctx context.Context, req model.AgentSessionRequest) (model.AgentThread, error) {
	options, err := decodeSessionOptions(req.Options)
	if err != nil {
		return model.AgentThread{}, err
	}
	resp, err := h.client.NewSession(ctx, protocol.NewSessionRequest{Cwd: req.Cwd, McpServers: options.MCPServers})
	if err != nil {
		return model.AgentThread{}, err
	}
	if resp.SessionId == "" {
		return model.AgentThread{}, fmt.Errorf("ACP session/new returned an empty session id")
	}
	return h.thread(string(resp.SessionId), req.Cwd, nil, nil, resp), nil
}

func (h *Handle) LoadSession(ctx context.Context, req model.AgentSessionRequest) (model.AgentThread, error) {
	options, err := decodeSessionOptions(req.Options)
	if err != nil {
		return model.AgentThread{}, err
	}
	sessionID := protocol.SessionId(req.SessionID)
	resp, err := h.client.LoadSession(ctx, protocol.LoadSessionRequest{SessionId: sessionID, Cwd: req.Cwd, McpServers: options.MCPServers})
	if err != nil {
		return model.AgentThread{}, err
	}
	return h.thread(req.SessionID, req.Cwd, nil, nil, resp), nil
}

func (h *Handle) ResumeSession(ctx context.Context, req model.AgentSessionRequest) (model.AgentThread, error) {
	options, err := decodeSessionOptions(req.Options)
	if err != nil {
		return model.AgentThread{}, err
	}
	sessionID := protocol.SessionId(req.SessionID)
	resp, err := h.client.ResumeSession(ctx, protocol.ResumeSessionRequest{SessionId: sessionID, Cwd: req.Cwd, McpServers: options.MCPServers})
	if err != nil {
		return model.AgentThread{}, err
	}
	return h.thread(req.SessionID, req.Cwd, nil, nil, resp), nil
}

func (h *Handle) CloseSession(ctx context.Context, sessionID string) (model.AgentThread, error) {
	resp, err := h.client.CloseSession(ctx, protocol.SessionId(sessionID))
	if err != nil {
		return model.AgentThread{}, err
	}
	return h.thread(sessionID, "", nil, nil, resp), nil
}

func (h *Handle) ListSessions(ctx context.Context, req model.AgentSessionListRequest) (model.AgentThreadList, error) {
	var cwd *string
	if req.Cwd != "" {
		cwd = &req.Cwd
	}
	var cursor *string
	if req.Cursor != "" {
		cursor = &req.Cursor
	}

	resp, err := h.client.ListSessions(ctx, protocol.ListSessionsRequest{Cwd: cwd, Cursor: cursor})
	if err != nil {
		return model.AgentThreadList{}, err
	}

	agentName := h.Info().Name
	threads := make([]model.AgentThread, 0, len(resp.Sessions))
	for _, session := range resp.Sessions {
		threads = append(threads, model.AgentThread{
			AgentName:        agentName,
			AgentKind:        model.AgentKindACP,
			ID:               string(session.SessionId),
			BackendSessionID: string(session.SessionId),
			Cwd:              session.Cwd,
			Title:            session.Title,
			UpdatedAt:        session.UpdatedAt,
			Metadata:         session.Meta,
		})
	}
	return model.AgentThreadList{AgentName: agentName, AgentKind: model.AgentKindACP, Threads: threads, NextCursor: resp.NextCursor}, nil
}

func (h *Handle) Close() error {
	h.once.Do(func() {
		_ = h.client.Close()
		if h.cmd.Process != nil {
			_ = h.cmd.Process.Kill()
		}
	})
	return nil
}

func (h *Handle) wait() {
	_ = h.cmd.Wait()
	_ = h.client.Close()
	h.mu.Lock()
	h.info.Status = model.ConnectionStatusExited
	h.mu.Unlock()
}

func (h *Handle) thread(sessionID string, cwd string, title *string, updatedAt *string, raw any) model.AgentThread {
	return model.AgentThread{
		AgentName:        h.Info().Name,
		AgentKind:        model.AgentKindACP,
		ID:               sessionID,
		BackendSessionID: sessionID,
		Cwd:              cwd,
		Title:            title,
		UpdatedAt:        updatedAt,
		Raw:              marshalRaw(raw),
	}
}

type sessionOptions struct {
	MCPServers []protocol.McpServer `json:"mcpServers,omitempty"`
}

func decodeSessionOptions(raw json.RawMessage) (sessionOptions, error) {
	if len(raw) == 0 {
		return sessionOptions{MCPServers: []protocol.McpServer{}}, nil
	}
	var options sessionOptions
	if err := json.Unmarshal(raw, &options); err != nil {
		return sessionOptions{}, fmt.Errorf("decode ACP session options: %w", err)
	}
	if options.MCPServers == nil {
		options.MCPServers = []protocol.McpServer{}
	}
	return options, nil
}

func capabilitySet(capabilities protocol.AgentCapabilities) model.AgentCapabilities {
	return model.AgentCapabilities{
		SessionCreate: true,
		SessionList:   capabilities.SessionCapabilities.List != nil,
		SessionLoad:   capabilities.LoadSession,
		SessionResume: capabilities.SessionCapabilities.Resume != nil,
		SessionClose:  capabilities.SessionCapabilities.Close != nil,
	}
}

func metadataFromInitialize(initResp protocol.InitializeResponse, rawInit json.RawMessage) map[string]json.RawMessage {
	metadata := map[string]json.RawMessage{
		"agentCapabilities": marshalRaw(initResp.AgentCapabilities),
		"authMethods":       marshalRaw(initResp.AuthMethods),
	}
	if initResp.AgentInfo != nil {
		metadata["agentInfo"] = marshalRaw(initResp.AgentInfo)
	}
	if len(rawInit) > 0 {
		metadata["rawInitialize"] = append(json.RawMessage(nil), rawInit...)
	}
	return metadata
}

func marshalRaw(value any) json.RawMessage {
	raw, _ := json.Marshal(value)
	return raw
}
