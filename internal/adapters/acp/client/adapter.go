package client

import (
	"context"
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
	if err := c.conn.Call(ctx, "initialize", initReq).Await(ctx, &initResp); err != nil {
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
