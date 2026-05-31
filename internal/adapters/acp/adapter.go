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

func capabilitySet(_ protocol.AgentCapabilities) model.CapabilitySet {
	return model.CapabilitySet{
		Sessions: true,
		Prompt:   true,
		Cancel:   true,
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
