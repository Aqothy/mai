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
			ACP: &model.ACPMetadata{
				AgentInfo:         initResp.AgentInfo,
				AgentCapabilities: initResp.AgentCapabilities,
				AuthMethods:       initResp.AuthMethods,
				RawInitialize:     rawInit,
			},
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
	info := h.info
	info.Command = append([]string(nil), h.info.Command...)
	if h.info.ACP != nil {
		acp := *h.info.ACP
		if h.info.ACP.RawInitialize != nil {
			acp.RawInitialize = append(json.RawMessage(nil), h.info.ACP.RawInitialize...)
		}
		info.ACP = &acp
	}
	return info
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

func capabilitySet(agentCapabilities map[string]any) model.CapabilitySet {
	caps := model.CapabilitySet{
		Sessions: true,
		Prompt:   true,
		Cancel:   true,
	}

	if sessionCaps, ok := agentCapabilities["sessionCapabilities"].(map[string]any); ok {
		caps.Models = sessionCaps["setModel"] == true || sessionCaps["set_model"] == true
		caps.Modes = sessionCaps["setMode"] == true || sessionCaps["set_mode"] == true
	}

	return caps
}
