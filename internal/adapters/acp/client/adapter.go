package client

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"time"

	"github.com/Aqothy/jsonrpc2"
	protocol "github.com/Aqothy/maiD/internal/adapters/acp/protocol"
)

type Connection struct {
	InitializedAt time.Time                   `json:"initializedAt"`
	Initialize    protocol.InitializeResponse `json:"initialize"`

	conn *jsonrpc2.Connection
	io   *processStdio
}

func NewConnection(peerInput io.WriteCloser, peerOutput io.ReadCloser) *Connection {
	stdio := &processStdio{r: peerOutput, w: peerInput}
	conn := jsonrpc2.NewStreamConnection(context.Background(), stdio, jsonrpc2.ConnectionOptions{
		Framer:  jsonrpc2.NewNdFramer(),
		Handler: handler{},
		OnInternalError: func(err error) {
			log.Printf("acp jsonrpc internal error: %v", err)
		},
		OnNotificationError: func(err error) {
			log.Printf("acp notification error: %v", err)
		},
	})
	return &Connection{conn: conn, io: stdio}
}

func (c *Connection) InitializeConnection(ctx context.Context) (protocol.InitializeResponse, error) {
	title := "Mai Daemon"
	initReq := protocol.InitializeRequest{
		ProtocolVersion:    protocol.ProtocolVersionNumber,
		ClientCapabilities: protocol.ClientCapabilities{},
		ClientInfo:         &protocol.Implementation{Name: "maiD", Title: &title, Version: "0.1.0"},
	}

	var initResp protocol.InitializeResponse
	if err := c.conn.Call(ctx, protocol.AgentMethodInitialize, initReq).Await(ctx, &initResp); err != nil {
		return protocol.InitializeResponse{}, fmt.Errorf("ACP initialize failed: %w", err)
	}
	if initResp.ProtocolVersion != protocol.ProtocolVersionNumber {
		return protocol.InitializeResponse{}, fmt.Errorf("unsupported ACP protocol version %d", initResp.ProtocolVersion)
	}
	if initResp.AuthMethods == nil {
		initResp.AuthMethods = []protocol.AuthMethod{}
	}

	c.Initialize = initResp
	c.InitializedAt = time.Now()
	return initResp, nil
}

func (c *Connection) Authenticate(ctx context.Context, methodID string) (protocol.AuthenticateResponse, error) {
	resolvedMethodID, err := c.resolveAuthMethodID(methodID)
	if err != nil {
		return protocol.AuthenticateResponse{}, err
	}

	params := protocol.AuthenticateRequest{MethodId: resolvedMethodID}
	var resp protocol.AuthenticateResponse
	if err := c.conn.Call(ctx, protocol.AgentMethodAuthenticate, params).Await(ctx, &resp); err != nil {
		return protocol.AuthenticateResponse{}, fmt.Errorf("ACP authenticate failed: %w", err)
	}
	return resp, nil
}

func (c *Connection) Logout(ctx context.Context) (protocol.LogoutResponse, error) {
	if c.Initialize.AgentCapabilities.Auth.Logout == nil {
		return protocol.LogoutResponse{}, fmt.Errorf("ACP agent did not advertise logout capability")
	}

	var resp protocol.LogoutResponse
	if err := c.conn.Call(ctx, protocol.AgentMethodLogout, protocol.LogoutRequest{}).Await(ctx, &resp); err != nil {
		return protocol.LogoutResponse{}, fmt.Errorf("ACP logout failed: %w", err)
	}
	return resp, nil
}

func (c *Connection) resolveAuthMethodID(methodID string) (string, error) {
	if methodID == "" {
		return "", fmt.Errorf("ACP authenticate requires a method id")
	}
	for _, method := range c.Initialize.AuthMethods {
		if authMethodID(method) == methodID {
			return methodID, nil
		}
	}
	return "", fmt.Errorf("ACP auth method %q was not advertised", methodID)
}

func authMethodID(method protocol.AuthMethod) string {
	if method.Agent != nil {
		return method.Agent.Id
	}

	var raw struct {
		ID string `json:"id"`
	}
	data, err := json.Marshal(method)
	if err == nil {
		_ = json.Unmarshal(data, &raw)
	}
	return raw.ID
}

func (c *Connection) Close() error {
	return c.io.Close()
}

type handler struct{}

func (handler) Handle(_ context.Context, req *jsonrpc2.Request) (any, error) {
	if !req.IsCall() {
		log.Printf("acp notification %s: %s", req.Method, string(req.Params))
		return nil, nil
	}
	return nil, fmt.Errorf("%w: maiD does not implement ACP client method %s yet", jsonrpc2.ErrMethodNotFound, req.Method)
}
