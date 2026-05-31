package ipc

import (
	"encoding/json"
	"fmt"
	"net"
)

const DefaultSocketPath = "/tmp/maiD.sock"

const (
	ActionAgentInit         = "agent-init"
	ActionAgentAuthenticate = "agent-authenticate"
	ActionAgentLogout       = "agent-logout"
)

type Request struct {
	Action string          `json:"action"`
	Params json.RawMessage `json:"params,omitempty"`
}

type Response struct {
	OK      bool            `json:"ok"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

type AgentInitParams struct {
	Name    string   `json:"name"`
	Kind    string   `json:"kind,omitempty"`
	Command []string `json:"command"`
}

type AgentAuthenticateParams struct {
	Name     string `json:"name"`
	MethodID string `json:"methodId"`
}

type AgentLogoutParams struct {
	Name string `json:"name"`
}

func NewRequest(action string, params any) (Request, error) {
	req := Request{Action: action}
	if params == nil {
		return req, nil
	}

	data, err := json.Marshal(params)
	if err != nil {
		return Request{}, fmt.Errorf("marshal request params: %w", err)
	}
	req.Params = data
	return req, nil
}

func (r Request) DecodeParams(dst any) error {
	if len(r.Params) == 0 {
		return nil
	}
	if err := json.Unmarshal(r.Params, dst); err != nil {
		return fmt.Errorf("decode %s params: %w", r.Action, err)
	}
	return nil
}

func Send(socketPath string, req Request) (Response, error) {
	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		return Response{}, err
	}
	defer conn.Close()

	if err := json.NewEncoder(conn).Encode(req); err != nil {
		return Response{}, fmt.Errorf("send request: %w", err)
	}

	var resp Response
	if err := json.NewDecoder(conn).Decode(&resp); err != nil {
		return Response{}, fmt.Errorf("read response: %w", err)
	}
	return resp, nil
}
