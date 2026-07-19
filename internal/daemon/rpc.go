package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/Aqothy/jsonrpc2"
	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
	"github.com/coder/websocket"
)

const (
	// Local handler/test names point at the canonical api/wire registry.
	RPCMethodOrchestrationDispatchCommand     = wire.MethodOrchestrationDispatchCommand
	RPCMethodOrchestrationReplayEvents        = wire.MethodOrchestrationReplayEvents
	RPCMethodOrchestrationSubscribeThreadList = wire.MethodOrchestrationSubscribeThreadList
	RPCMethodOrchestrationSubscribeThread     = wire.MethodOrchestrationSubscribeThread
	RPCMethodOrchestrationUnsubscribeThread   = wire.MethodOrchestrationUnsubscribeThread

	RPCMethodProviderStart         = wire.MethodProviderStart
	RPCMethodProviderList          = wire.MethodProviderList
	RPCMethodACPRegistryList       = wire.MethodACPRegistryList
	RPCMethodACPRegistryStart      = wire.MethodACPRegistryStart
	RPCMethodProviderAuthenticate  = wire.MethodProviderAuthenticate
	RPCMethodProviderLogout        = wire.MethodProviderLogout
	RPCMethodProviderListSessions  = wire.MethodProviderListSessions
	RPCMethodProviderImportSession = wire.MethodProviderImportSession
	RPCMethodProviderDeleteSession = wire.MethodProviderDeleteSession
	RPCMethodProviderCloseSession  = wire.MethodProviderCloseSession
)

type providerStartRPCParams = wire.ProviderStartParams
type acpRegistryStartParams = wire.ACPRegistryStartParams
type providerAuthenticateParams = wire.ProviderAuthenticateParams
type providerInstanceParams = wire.ProviderInstanceParams
type providerListSessionsParams = wire.ProviderListSessionsParams
type providerSessionParams = wire.ProviderSessionParams
type providerImportSessionParams = wire.ProviderImportSessionParams
type providerImportSessionResult = wire.ProviderImportSessionResult

var nextRPCClientID atomic.Uint64

const rpcOutboundQueueSize = 1024

// maxInboundMessageBytes bounds a single client->daemon frame (commands with
// attachments are the big case). Outbound frames are unaffected.
const maxInboundMessageBytes = 32 << 20

type rpcClient struct {
	id     string
	conn   *jsonrpc2.Connection
	logger *slog.Logger

	outbound chan rpcOutbound
	done     chan struct{}
	closed   atomic.Bool

	subscriptionsMu      sync.Mutex
	threadSubscriptions  map[orchestration.ThreadID]struct{}
	threadListSubscribed bool
}

type rpcOutbound struct {
	method string
	params any
}

type rpcHandler struct {
	server *Server
	client *rpcClient

	// afterThreadSnapshot is a test hook used to exercise subscribe snapshot/live-event ordering.
	afterThreadSnapshot func(orchestration.ThreadID)
}

type wsJSONRPC struct{ conn *websocket.Conn }

func (s wsJSONRPC) ReadMessage(ctx context.Context) ([]byte, error) {
	typ, data, err := s.conn.Read(ctx)
	if err != nil {
		return nil, err
	}
	if typ != websocket.MessageText {
		return nil, fmt.Errorf("expected text websocket message, got %v", typ)
	}
	return data, nil
}

func (s wsJSONRPC) WriteMessage(ctx context.Context, data []byte) error {
	return s.conn.Write(ctx, websocket.MessageText, data)
}

func (s wsJSONRPC) Close() error {
	return s.conn.Close(websocket.StatusNormalClosure, "")
}

type disconnectReader struct {
	reader       jsonrpc2.Reader
	once         sync.Once
	onDisconnect func(error)
}

func (r *disconnectReader) Read(ctx context.Context) (jsonrpc2.Message, error) {
	msg, err := r.reader.Read(ctx)
	if err != nil && r.onDisconnect != nil {
		r.once.Do(func() { r.onDisconnect(err) })
	}
	return msg, err
}

func (s *Server) RunWebSocket(addr string) error {
	if addr == "" {
		addr = "127.0.0.1:8765"
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /rpc", s.WebSocketHandler())
	srv := &http.Server{Addr: addr, Handler: mux}
	s.mu.Lock()
	s.httpServer = srv
	stopped := s.ctx.Err() != nil
	fatalErr := s.fatalErr
	s.mu.Unlock()
	if stopped {
		return fatalErr
	}
	defer s.Close()
	s.logger.Info("server listening", "http", "http://"+addr, "websocket", "ws://"+addr+"/rpc")
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	// A clean listener shutdown may still be a fatal one: an orchestration
	// invariant violation closes the server and is surfaced here so main —
	// the sole owner of process exit — can log.Fatal it.
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.fatalErr
}

func (s *Server) WebSocketHandler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ws, err := websocket.Accept(w, r, nil)
		if err != nil {
			s.logger.Warn("websocket accept failed", "error", err)
			return
		}
		// The library default (32KiB) is too small for real commands: a single
		// image attachment on thread.turn.start can be megabytes of base64.
		ws.SetReadLimit(maxInboundMessageBytes)
		socket := wsJSONRPC{conn: ws}
		reader, writer := jsonrpc2.NewWebSocketTransport(socket)
		var client *rpcClient
		reader = &disconnectReader{reader: reader, onDisconnect: func(error) {
			if client != nil {
				s.disconnectRPCClient(client)
			}
		}}
		conn := jsonrpc2.NewConnection(context.Background(), jsonrpc2.ConnectionConfig{
			Reader: reader,
			Writer: writer,
			Closer: socket,
			OnInternalError: func(err error) {
				s.logger.Error("JSON-RPC internal error", "error", err)
			},
			OnNotificationError: func(err error) {
				s.logger.Warn("JSON-RPC notification failed", "error", err)
			},
			Bind: func(c *jsonrpc2.Connection) jsonrpc2.Handler {
				client = s.registerRPCClient(c)
				return &rpcHandler{server: s, client: client}
			},
		})
		_ = conn.Wait()
		if client != nil {
			s.disconnectRPCClient(client)
		}
	}
}

func (s *Server) registerRPCClient(conn *jsonrpc2.Connection) *rpcClient {
	client := &rpcClient{id: fmt.Sprintf("client-%d", nextRPCClientID.Add(1)), conn: conn, outbound: make(chan rpcOutbound, rpcOutboundQueueSize), done: make(chan struct{}), threadSubscriptions: make(map[orchestration.ThreadID]struct{})}
	client.logger = s.logger.With("client", client.id)
	s.rpcMu.Lock()
	s.rpcClients[client.id] = client
	s.rpcMu.Unlock()
	client.logger.Info("client connected")
	go client.writeOutbound()
	return client
}

func (s *Server) disconnectRPCClient(client *rpcClient) {
	if client == nil {
		return
	}
	s.rpcMu.Lock()
	if s.rpcClients[client.id] == client {
		delete(s.rpcClients, client.id)
	}
	s.rpcMu.Unlock()
	if client.closeOutbound() {
		client.logger.Info("client disconnected")
	}
}

func (c *rpcClient) closeOutbound() bool {
	if c.closed.CompareAndSwap(false, true) {
		close(c.done)
		return true
	}
	return false
}

func (c *rpcClient) overflowClose(what string) {
	if c.closeOutbound() {
		c.logger.Warn("client outbound queue full; closing connection", "method", what)
		go func() { _ = c.conn.Close() }()
	}
}

func (c *rpcClient) writeOutbound() {
	for {
		select {
		case <-c.done:
			return
		case msg := <-c.outbound:
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			if err := c.conn.Notify(ctx, msg.method, msg.params); err != nil {
				c.logger.Warn("client notification failed", "method", msg.method, "error", err)
			}
			cancel()
		}
	}
}

func (c *rpcClient) subscribeThread(threadID orchestration.ThreadID) {
	c.subscriptionsMu.Lock()
	defer c.subscriptionsMu.Unlock()
	c.threadSubscriptions[threadID] = struct{}{}
}

func (c *rpcClient) unsubscribeThread(threadID orchestration.ThreadID) {
	c.subscriptionsMu.Lock()
	defer c.subscriptionsMu.Unlock()
	delete(c.threadSubscriptions, threadID)
}

func (c *rpcClient) subscribedThread(threadID orchestration.ThreadID) bool {
	c.subscriptionsMu.Lock()
	defer c.subscriptionsMu.Unlock()
	_, ok := c.threadSubscriptions[threadID]
	return ok
}

func (c *rpcClient) subscribeThreadList() {
	c.subscriptionsMu.Lock()
	defer c.subscriptionsMu.Unlock()
	c.threadListSubscribed = true
}

func (c *rpcClient) subscribedThreadList() bool {
	c.subscriptionsMu.Lock()
	defer c.subscriptionsMu.Unlock()
	return c.threadListSubscribed
}

func (h *rpcHandler) Handle(ctx context.Context, req *jsonrpc2.Request) (result any, err error) {
	started := time.Now()
	// jsonrpc2 treats a non-nil result alongside a non-nil error as a handler
	// contract violation (logged via OnInternalError), so drop zero-value
	// results from pass-through calls like Dispatch/StartProvider on failure.
	defer func() {
		err = rpcError(err)
		attrs := []any{"method", req.Method, "duration", time.Since(started).Round(time.Millisecond)}
		if h.client != nil && h.client.id != "" {
			attrs = append(attrs, "client", h.client.id)
		}
		if err != nil {
			result = nil
			attrs = append(attrs, "error", compactError(err))
			h.server.logger.Warn("RPC failed", attrs...)
			return
		}
		h.server.logger.Debug("RPC completed", attrs...)
	}()
	switch req.Method {
	case RPCMethodOrchestrationDispatchCommand:
		if !req.IsCall() {
			return nil, fmt.Errorf("%w: orchestration.dispatchCommand must be a request", jsonrpc2.ErrInvalidRequest)
		}
		var command orchestration.Command
		if err := decodeRPCParams(req, &command); err != nil {
			return nil, err
		}
		return h.server.orchestration.Dispatch(ctx, command)
	case RPCMethodOrchestrationReplayEvents:
		var params orchestration.ReplayEventsInput
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.server.orchestration.ReplayEvents(params), nil
	case RPCMethodOrchestrationSubscribeThread:
		var params orchestration.SubscribeThreadInput
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		if params.ThreadID == "" {
			return nil, fmt.Errorf("%w: subscribeThread requires threadId", jsonrpc2.ErrInvalidParams)
		}
		h.client.subscribeThread(params.ThreadID)
		snapshot, err := h.server.orchestration.ThreadSnapshot(params.ThreadID)
		if err != nil {
			h.client.unsubscribeThread(params.ThreadID)
			return nil, err
		}
		if h.afterThreadSnapshot != nil {
			h.afterThreadSnapshot(params.ThreadID)
		}
		return snapshot, nil
	case RPCMethodOrchestrationUnsubscribeThread:
		var params orchestration.SubscribeThreadInput
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		if params.ThreadID == "" {
			return nil, fmt.Errorf("%w: unsubscribeThread requires threadId", jsonrpc2.ErrInvalidParams)
		}
		h.client.unsubscribeThread(params.ThreadID)
		return nil, nil
	case RPCMethodOrchestrationSubscribeThreadList:
		h.client.subscribeThreadList()
		return h.server.orchestration.ThreadListSnapshot(), nil
	case RPCMethodProviderStart:
		var params providerStartRPCParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.server.StartProvider(ctx, params.InstanceSpec, params.Restart)
	case RPCMethodProviderList:
		return h.server.providerService.ListInstances(), nil
	case RPCMethodACPRegistryList:
		if h.server.acpRegistry == nil {
			return nil, fmt.Errorf("ACP registry is unavailable")
		}
		return h.server.acpRegistry.list(ctx)
	case RPCMethodACPRegistryStart:
		var params acpRegistryStartParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		if params.RegistryID == "" {
			return nil, fmt.Errorf("%w: acp.registry.start requires registryId", jsonrpc2.ErrInvalidParams)
		}
		return h.server.StartACPRegistryProvider(ctx, params.RegistryID, params.Restart)
	case RPCMethodProviderAuthenticate:
		var params providerAuthenticateParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.server.providerService.Authenticate(ctx, params.InstanceID, params.MethodID)
	case RPCMethodProviderLogout:
		var params providerInstanceParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.server.providerService.Logout(ctx, params.InstanceID)
	case RPCMethodProviderListSessions:
		var params providerListSessionsParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.server.providerService.ListSessions(ctx, params.InstanceID, params.Cwd)
	case RPCMethodProviderImportSession:
		var params providerImportSessionParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		threadID, imported, err := h.server.ImportProviderSession(ctx, params.InstanceID, params.Session)
		if err != nil {
			return nil, err
		}
		return providerImportSessionResult{ThreadID: threadID, Imported: imported}, nil
	case RPCMethodProviderDeleteSession:
		var params providerSessionParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return nil, h.server.providerService.DeleteSession(ctx, params.InstanceID, params.SessionID)
	case RPCMethodProviderCloseSession:
		var params providerSessionParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return nil, h.server.providerService.CloseSession(ctx, params.InstanceID, params.SessionID)
	default:
		return nil, jsonrpc2.ErrNotHandled
	}
}

func compactError(err error) string {
	message := strings.Join(strings.Fields(err.Error()), " ")
	const maxBytes = 512
	if len(message) > maxBytes {
		return message[:maxBytes] + "…"
	}
	return message
}

func rpcError(err error) error {
	if err == nil {
		return nil
	}
	if agentErr, ok := errors.AsType[*provider.RequestError](err); ok {
		return &jsonrpc2.WireError{Code: int64(agentErr.Code), Message: agentErr.Message, Data: agentErr.Data}
	}
	return err
}

func decodeRPCParams(req *jsonrpc2.Request, dst any) error {
	if len(req.Params) == 0 {
		return nil
	}
	if err := json.Unmarshal(req.Params, dst); err != nil {
		return fmt.Errorf("%w: decode %s params: %v", jsonrpc2.ErrInvalidParams, req.Method, err)
	}
	return nil
}

// publishOrchestrationEvent runs on the engine worker for EVERY event
// (including each streamed assistant delta), so it must stay cheap:
//   - collect subscribers first and bail before building anything nobody wants;
//   - marshal each notification ONCE and fan out the bytes, instead of
//     re-marshaling per client;
//   - build the thread-list item (a full-thread clone) only for thread-list-visible events.
func (s *Server) publishOrchestrationEvent(event orchestration.Event) {
	threadID := event.ThreadID()
	if threadID == "" {
		return
	}

	s.rpcMu.Lock()
	var threadClients, threadListClients []*rpcClient
	for _, client := range s.rpcClients {
		if client.subscribedThread(threadID) {
			threadClients = append(threadClients, client)
		}
		if client.subscribedThreadList() {
			threadListClients = append(threadListClients, client)
		}
	}
	s.rpcMu.Unlock()
	if len(threadClients) == 0 && len(threadListClients) == 0 {
		return
	}

	if len(threadClients) > 0 {
		if params, ok := s.marshalNotification(orchestration.ThreadStreamItem{Kind: "event", Event: &event}, RPCMethodOrchestrationSubscribeThread); ok {
			for _, client := range threadClients {
				client.notify(RPCMethodOrchestrationSubscribeThread, params)
			}
		}
	}
	if len(threadListClients) == 0 || !orchestration.ThreadListVisible(event) {
		return
	}
	entry, ok := s.orchestration.ThreadListEntry(threadID)
	if !ok {
		return
	}
	if params, ok := s.marshalNotification(orchestration.ThreadListStreamItem{Kind: "thread-upserted", Sequence: event.Sequence, Thread: &entry}, RPCMethodOrchestrationSubscribeThreadList); ok {
		for _, client := range threadListClients {
			client.notify(RPCMethodOrchestrationSubscribeThreadList, params)
		}
	}
}

func (s *Server) marshalNotification(item any, method string) (json.RawMessage, bool) {
	params, err := json.Marshal(item)
	if err != nil {
		s.logger.Error("notification encoding failed", "method", method, "error", err)
		return nil, false
	}
	return params, true
}

func (c *rpcClient) notify(method string, params any) {
	select {
	case <-c.done:
	case c.outbound <- rpcOutbound{method: method, params: params}:
	default:
		c.overflowClose(method)
	}
}
