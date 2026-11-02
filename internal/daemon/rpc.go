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

var (
	nextRPCClientID atomic.Uint64
	nextQuestionID  atomic.Uint64
)

const (
	// rpcOutboundQueueSize absorbs an agent's burst (thousands of tool
	// updates at once, which the engine turns into events faster than a
	// socket writes them) without closing a client that keeps up on average.
	rpcOutboundQueueSize = 4096
	// rpcConcurrentCalls bounds the calls one connection runs at once; a
	// further call waits in the connection's queue for a free slot.
	rpcConcurrentCalls = 32
)

// orderedRPCCalls run one at a time in wire order: the order of commands and
// subscriptions is the client's intent. They are all quick. Every other call
// runs concurrently so a slow provider, registry, or terminal operation
// cannot hold up the connection. Notifications (terminal input, resize,
// focus, detach) are always handled in wire order.
var orderedRPCCalls = map[string]bool{
	wire.MethodThreadCommand:         true,
	wire.MethodThreadSubscribe:       true,
	wire.MethodThreadUnsubscribe:     true,
	wire.MethodThreadSubscribeList:   true,
	wire.MethodTerminalSubscribeList: true,
	wire.MethodProjectSubscribeList:  true,
}

// maxInboundMessageBytes bounds a single client->daemon frame (commands with
// attachments are the big case). Outbound frames are unaffected.
const maxInboundMessageBytes = 32 << 20

// rpcPingInterval is how often the daemon pings each client, and how long it
// waits for the pong. TCP can't tell a half-open link (a phone that changed
// networks, a suspended app, a stalled proxy) from an idle one, so without a
// ping the daemon keeps a dead client's subscriptions and blocks on writes to
// it forever. Closing on a missed pong also bounds how late a request still
// buffered on that link can arrive.
const rpcPingInterval = 15 * time.Second

type rpcClient struct {
	id     string
	conn   *jsonrpc2.Connection
	socket *websocket.Conn
	logger *slog.Logger

	outbound chan rpcOutbound
	done     chan struct{}
	closed   atomic.Bool
	calls    chan struct{} // slots for concurrently running calls

	// subscription is the client's thread list and thread updates.
	subscription *orchestration.Subscription

	subscriptionsMu        sync.Mutex
	terminalListSubscribed bool

	// questions are the sign-in questions this client was asked and has not
	// answered, by request ID.
	questionsMu sync.Mutex
	questions   map[string]pendingQuestion

	optionsLifecycleMu   sync.Mutex
	optionsMu            sync.Mutex
	optionsSessions      map[provider.InstanceID]*clientOptionsSession
	nextOptionsSessionID atomic.Uint64
}

type clientOptionsSession struct {
	optionsSessionID   string
	providerInstanceID provider.InstanceID
	handle             string
	cwd                string
	configOptions      []provider.ConfigOption
	skills             []provider.Skill
}

type rpcOutbound struct {
	method string
	params any
}

type rpcHandler struct {
	server *Server
	client *rpcClient
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
	if err != nil {
		r.once.Do(func() { r.onDisconnect(err) })
	}
	return msg, err
}

func (s *Server) RunWebSocket(addr string) error {
	if addr == "" {
		addr = "127.0.0.1:8765"
	}
	srv := &http.Server{Addr: addr, Handler: s.handler()}
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

// handler serves the JSON-RPC connection and the terminal streams beside it.
func (s *Server) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /rpc", s.serveRPC)
	mux.HandleFunc("GET "+wire.TerminalStreamPath, s.serveTerminalStream)
	return mux
}

func (s *Server) serveRPC(w http.ResponseWriter, r *http.Request) {
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
			client = s.registerRPCClient(c, ws)
			return &rpcHandler{server: s, client: client}
		},
	})
	pingCtx, stopPinging := context.WithCancel(context.Background())
	// Bind ran inside NewConnection, so client is set.
	go s.keepAlive(pingCtx, ws, client.logger)
	_ = conn.Wait()
	stopPinging()
	if client != nil {
		s.disconnectRPCClient(client)
	}
}

// keepAlive closes the socket once a ping goes unanswered for one ping
// interval. Closing the socket itself, not the JSON-RPC connection,
// also fails writes blocked on the dead link, which the connection's own
// Close would wait for.
func (s *Server) keepAlive(ctx context.Context, ws *websocket.Conn, logger *slog.Logger) {
	ticker := time.NewTicker(s.pingInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		pingCtx, cancel := context.WithTimeout(ctx, s.pingInterval)
		err := ws.Ping(pingCtx)
		cancel()
		if err != nil {
			if ctx.Err() == nil {
				logger.Info("client stopped answering pings; closing connection", "error", err)
			}
			_ = ws.CloseNow()
			return
		}
	}
}

func (s *Server) registerRPCClient(conn *jsonrpc2.Connection, socket *websocket.Conn) *rpcClient {
	client := &rpcClient{
		id: fmt.Sprintf("client-%d", nextRPCClientID.Add(1)), conn: conn, socket: socket,
		outbound: make(chan rpcOutbound, rpcOutboundQueueSize), done: make(chan struct{}),
		calls:     make(chan struct{}, rpcConcurrentCalls),
		questions: make(map[string]pendingQuestion),
	}
	client.logger = s.logger.With("client", client.id)
	client.subscription = s.engine.Subscribe(client)
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
		client.subscription.Close()
	}
	// Cleanup is deliberately independent of who first closed the outbound
	// channel. Queue overflow can close it before socket teardown reaches this
	// path, and detaching the active sessions makes repeated cleanup harmless.
	go s.closeClientOptionsSessions(client)
	go s.detachClientTerminals(client)
}

func (c *rpcClient) closeOutbound() bool {
	if c.closed.CompareAndSwap(false, true) {
		close(c.done)
		return true
	}
	return false
}

// closeConnection closes a client whose outbound stream can no longer be
// delivered in order; it recovers by reconnecting for fresh snapshots.
func (c *rpcClient) closeConnection(reason string, attrs ...any) {
	if c.closeOutbound() {
		c.logger.Warn(reason+"; closing connection", attrs...)
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
				cancel()
				c.closeConnection("client notification failed", "method", msg.method, "error", err)
				return
			}
			cancel()
		}
	}
}

// ThreadEvent, ThreadList and ProjectList make the client an
// orchestration.Sink. They run on the engine goroutine and never block: a
// client that can't keep up is closed and recovers from fresh snapshots.
func (c *rpcClient) ThreadEvent(event orchestration.ThreadEvent) {
	c.notify(wire.MethodThreadEvent, event)
}

func (c *rpcClient) ThreadList(item orchestration.ThreadListItem) {
	c.notify(wire.MethodThreadList, item)
}

func (c *rpcClient) ProjectList(list orchestration.ProjectList) {
	c.notify(wire.MethodProjectList, list)
}

func (c *rpcClient) subscribeTerminalList() {
	c.subscriptionsMu.Lock()
	defer c.subscriptionsMu.Unlock()
	c.terminalListSubscribed = true
}

func (c *rpcClient) subscribedTerminalList() bool {
	c.subscriptionsMu.Lock()
	defer c.subscriptionsMu.Unlock()
	return c.terminalListSubscribed
}

// ask sends this client a question an agent asks during its sign-in and
// waits for the answer, until the sign-in ends or the client goes away.
// pendingQuestion is a sign-in question awaiting the client's answer.
type pendingQuestion struct {
	request provider.Request
	answer  chan provider.RequestAnswer
}

func (c *rpcClient) ask(ctx context.Context, instanceID provider.InstanceID, request provider.Request) (provider.RequestAnswer, error) {
	requestID := fmt.Sprintf("%s-question-%d", c.id, nextQuestionID.Add(1))
	answer := make(chan provider.RequestAnswer, 1)
	c.questionsMu.Lock()
	c.questions[requestID] = pendingQuestion{request: request, answer: answer}
	c.questionsMu.Unlock()
	defer func() {
		c.questionsMu.Lock()
		delete(c.questions, requestID)
		c.questionsMu.Unlock()
	}()
	c.notify(wire.MethodProviderQuestionAsked, wire.ProviderQuestion{InstanceID: instanceID, RequestID: requestID, Request: request})
	select {
	case response := <-answer:
		return response, nil
	case <-ctx.Done():
		return provider.RequestAnswer{}, ctx.Err()
	case <-c.done:
		return provider.RequestAnswer{}, fmt.Errorf("client disconnected")
	}
}

func (h *rpcHandler) Handle(ctx context.Context, req *jsonrpc2.Request) (result any, err error) {
	started := time.Now()
	// jsonrpc2 treats a non-nil result alongside a non-nil error as a handler
	// contract violation (logged via OnInternalError), so drop zero-value
	// results from pass-through calls like Dispatch/StartProvider on failure.
	defer func() {
		err = rpcError(err)
		attrs := []any{"method", req.Method, "duration", time.Since(started).Round(time.Millisecond), "client", h.client.id}
		if err != nil {
			result = nil
			attrs = append(attrs, "error", compactError(err))
			h.server.logger.Warn("RPC failed", attrs...)
			return
		}
		h.server.logger.Debug("RPC completed", attrs...)
	}()
	if req.IsCall() && !orderedRPCCalls[req.Method] {
		select {
		case h.client.calls <- struct{}{}:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		defer func() { <-h.client.calls }()
		jsonrpc2.Async(ctx)
	}
	switch req.Method {
	case wire.MethodThreadCommand:
		if !req.IsCall() {
			return nil, fmt.Errorf("%w: thread.command must be a request", jsonrpc2.ErrInvalidRequest)
		}
		var params wire.CommandParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		body, err := params.Body()
		if err != nil {
			return nil, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
		}
		return h.server.engine.Do(ctx, orchestration.Command{Key: params.Key, Actor: orchestration.Person(orchestration.DeviceID(h.client.id)), Body: body})
	case wire.MethodAttachmentUpload:
		var params wire.AttachmentUploadParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		if params.Data == "" {
			return nil, fmt.Errorf("%w: attachment.upload requires data", jsonrpc2.ErrInvalidParams)
		}
		id, err := h.server.engine.StoreAttachment(params.Data)
		if err != nil {
			return nil, err
		}
		return wire.AttachmentUploadResult{ID: id}, nil
	case wire.MethodAttachmentGet:
		var params wire.AttachmentParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.server.engine.Attachment(params.ID)
	case wire.MethodThreadSubscribe:
		var params wire.ThreadParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		if params.Thread == "" {
			return nil, fmt.Errorf("%w: thread.subscribe requires thread", jsonrpc2.ErrInvalidParams)
		}
		return h.client.subscription.Thread(ctx, params.Thread)
	case wire.MethodThreadUnsubscribe:
		var params wire.ThreadParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		h.client.subscription.Unsubscribe(params.Thread)
		return nil, nil
	case wire.MethodThreadSync:
		var params wire.ThreadParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return nil, h.server.engine.Sync(ctx, params.Thread)
	case wire.MethodThreadSubscribeList:
		return h.client.subscription.List(ctx)
	case wire.MethodProjectSubscribeList:
		return h.client.subscription.Projects(ctx)
	case wire.MethodProjectAdd:
		var params wire.ProjectParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.server.engine.AddProject(ctx, params.Path)
	case wire.MethodProjectRemove:
		var params wire.ProjectParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return nil, h.server.engine.RemoveProject(ctx, params.Path)
	case wire.MethodThreadTurns:
		var params wire.ThreadTurnsParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		turns, older, err := h.server.engine.Turns(ctx, params.Thread, params.Before, params.Limit)
		if err != nil {
			return nil, err
		}
		return wire.ThreadTurnsResult{Turns: turns, Older: older}, nil
	case wire.MethodThreadForkPreview:
		var params wire.ThreadForkPreviewParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.server.engine.ForkPreview(ctx, params.Thread, params.Through, params.Agent)
	case wire.MethodThreadEntry:
		var params wire.ThreadEntryParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.server.engine.Entry(ctx, params.Thread, params.Ref)
	case wire.MethodProviderStart:
		var params wire.ProviderStartParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.server.StartProvider(ctx, params.InstanceSpec, params.Restart)
	case wire.MethodProviderList:
		return h.server.providerService.ListInstances(), nil
	case wire.MethodACPRegistryList:
		return h.server.acpRegistry.list(ctx)
	case wire.MethodACPRegistryInstalled:
		return h.server.acpRegistry.installedAgents()
	case wire.MethodACPRegistryInstall:
		var params wire.ACPRegistryInstallParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		if params.RegistryID == "" {
			return nil, fmt.Errorf("%w: acp.registry.install requires registryId", jsonrpc2.ErrInvalidParams)
		}
		installed, err := h.server.acpRegistry.install(ctx, params.RegistryID)
		if err != nil {
			return nil, err
		}
		spec, err := h.server.acpRegistry.instanceSpec(installed.ID)
		if err != nil {
			return nil, err
		}
		if err := h.server.providerService.RegisterManifestInstance(spec); err != nil {
			return nil, err
		}
		return installed, nil
	case wire.MethodACPRegistryAddCustom:
		var params wire.ACPCustomAgentAddParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		if strings.TrimSpace(params.Name) == "" || strings.TrimSpace(params.Command) == "" {
			return nil, fmt.Errorf("%w: acp.registry.addCustom requires name and command", jsonrpc2.ErrInvalidParams)
		}
		return h.server.acpRegistry.addCustom(params)
	case wire.MethodACPRegistryStart:
		var params wire.ACPRegistryStartParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		if params.RegistryID == "" {
			return nil, fmt.Errorf("%w: acp.registry.start requires registryId", jsonrpc2.ErrInvalidParams)
		}
		return h.server.StartACPRegistryProvider(ctx, params.RegistryID, params.Restart)
	case wire.MethodProviderAuthenticate:
		var params wire.ProviderAuthenticateParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.server.authenticateProvider(ctx, params.InstanceID, provider.AuthenticateInput{
			MethodID: params.MethodID,
			Secret:   params.Secret,
			Ask: func(ctx context.Context, request provider.Request) (provider.RequestAnswer, error) {
				return h.client.ask(ctx, params.InstanceID, request)
			},
		})
	case wire.MethodProviderQuestionAnswer:
		var params wire.ProviderQuestionAnswerParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		h.client.questionsMu.Lock()
		defer h.client.questionsMu.Unlock()
		pending, ok := h.client.questions[params.RequestID]
		if !ok {
			return nil, fmt.Errorf("%w: question %q is not pending", jsonrpc2.ErrInvalidParams, params.RequestID)
		}
		action, ok := pending.request.Action(params.ActionID)
		if !ok {
			return nil, fmt.Errorf("%w: action %q was not offered for question %q", jsonrpc2.ErrInvalidParams, params.ActionID, params.RequestID)
		}
		if len(params.Answers) > 0 && !action.Submit {
			return nil, fmt.Errorf("%w: action %q of question %q takes no answers", jsonrpc2.ErrInvalidParams, params.ActionID, params.RequestID)
		}
		delete(h.client.questions, params.RequestID)
		pending.answer <- provider.RequestAnswer{Action: action, Answers: params.Answers}
		return nil, nil
	case wire.MethodProviderLogout:
		var params wire.ProviderInstanceParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.server.providerService.Logout(ctx, params.InstanceID)
	case wire.MethodProviderListSessions:
		var params wire.ProviderListSessionsParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		sessions, err := h.server.providerService.Sessions(ctx, params.InstanceID, params.Cwd)
		return append([]provider.SessionSummary{}, sessions...), err
	case wire.MethodProviderDeleteSession:
		var params wire.ProviderSessionParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return nil, h.server.providerService.DeleteSession(ctx, params.InstanceID, params.SessionID)
	case wire.MethodProviderOptionsGet:
		var params wire.ProviderOptionsGetParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.getProviderOptions(ctx, params)
	case wire.MethodProviderOptionsSet:
		var params wire.ProviderOptionsSetParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.setProviderOption(ctx, params)
	case wire.MethodTerminalCreate:
		var params wire.TerminalCreateParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.server.createTerminal(h.client, params)
	case wire.MethodTerminalAttach:
		var params wire.TerminalAttachParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.server.attachTerminal(h.client, params)
	case wire.MethodTerminalRelaunch:
		var params wire.TerminalRelaunchParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.server.relaunchTerminal(h.client, params)
	case wire.MethodTerminalDetach:
		var params wire.TerminalDetachParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		h.server.detachTerminal(h.client, params)
		return nil, nil
	case wire.MethodTerminalSubscribeList:
		return h.server.subscribeTerminalList(h.client), nil
	case wire.MethodTerminalRename:
		var params wire.TerminalRenameParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.server.renameTerminal(params)
	case wire.MethodTerminalDelete:
		var params wire.TerminalIDParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return nil, h.server.deleteTerminal(params.TerminalID)
	case wire.MethodTerminalWrite:
		var params wire.TerminalWriteParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return nil, h.server.writeTerminal(h.client, params)
	case wire.MethodTerminalResize:
		var params wire.TerminalResizeParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return nil, h.server.resizeTerminal(h.client, params)
	case wire.MethodTerminalFocus:
		var params wire.TerminalIDParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		h.server.focusTerminal(h.client, params.TerminalID)
		return nil, nil
	case wire.MethodWorkspaceBrowseDirectories:
		var params wire.WorkspaceBrowseDirectoriesParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.server.browseWorkspaceDirectories(params)
	case wire.MethodProviderCompleteCommand:
		var params wire.ProviderCompleteCommandParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.server.completeCommand(ctx, params)
	case wire.MethodWorkspaceSearchFiles:
		var params wire.WorkspaceSearchFilesParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.server.searchWorkspaceFiles(ctx, params)
	default:
		return nil, jsonrpc2.ErrNotHandled
	}
}

func (c *rpcClient) newOptionsSessionID() string {
	return fmt.Sprintf("%s-options-session-%d", c.id, c.nextOptionsSessionID.Add(1))
}

func (h *rpcHandler) getProviderOptions(ctx context.Context, params wire.ProviderOptionsGetParams) (wire.ProviderOptionsResult, error) {
	if params.ProviderInstanceID == "" || params.Cwd == "" {
		return wire.ProviderOptionsResult{}, fmt.Errorf("%w: provider.options.get requires providerInstanceId and cwd", jsonrpc2.ErrInvalidParams)
	}
	// The options session runs the agent in cwd, so it is held to the same
	// rule as a chat's working directory.
	cwd, err := h.server.engine.WorkspaceRoot(ctx, params.Cwd)
	if err != nil {
		return wire.ProviderOptionsResult{}, err
	}
	params.Cwd = cwd
	h.client.optionsLifecycleMu.Lock()
	defer h.client.optionsLifecycleMu.Unlock()
	if err := ctx.Err(); err != nil {
		return wire.ProviderOptionsResult{}, err
	}
	if h.client.closed.Load() {
		return wire.ProviderOptionsResult{}, fmt.Errorf("client disconnected")
	}

	h.client.optionsMu.Lock()
	if h.client.optionsSessions == nil {
		h.client.optionsSessions = make(map[provider.InstanceID]*clientOptionsSession)
	}
	current := h.client.optionsSessions[params.ProviderInstanceID]
	if current != nil && current.cwd == params.Cwd {
		result := wire.ProviderOptionsResult{
			OptionsSessionID: current.optionsSessionID,
			ConfigOptions:    append([]provider.ConfigOption{}, current.configOptions...),
			Skills:           append([]provider.Skill(nil), current.skills...),
		}
		h.client.optionsMu.Unlock()
		return result, nil
	}
	delete(h.client.optionsSessions, params.ProviderInstanceID)
	h.client.optionsMu.Unlock()
	if current != nil {
		go h.closeOptionsSession(*current)
	}

	optionsSessionID := h.client.newOptionsSessionID()
	callbacks := provider.OptionsSessionCallbacks{
		Updated: func(options []provider.ConfigOption) {
			h.publishOptionsUpdate(params.ProviderInstanceID, optionsSessionID, options)
		},
		Invalidated: func() {
			h.invalidateOptionsSession(params.ProviderInstanceID, optionsSessionID)
		},
	}
	opened, err := h.server.providerService.OpenOptions(ctx, params.ProviderInstanceID, params.Cwd, callbacks)
	if err != nil {
		return wire.ProviderOptionsResult{}, err
	}
	entry := &clientOptionsSession{
		optionsSessionID: optionsSessionID, providerInstanceID: params.ProviderInstanceID,
		handle: opened.Handle, cwd: params.Cwd,
		configOptions: append([]provider.ConfigOption(nil), opened.ConfigOptions...),
		skills:        append([]provider.Skill(nil), opened.Skills...),
	}
	h.client.optionsMu.Lock()
	if h.client.closed.Load() {
		h.client.optionsMu.Unlock()
		go h.closeOptionsSession(*entry)
		return wire.ProviderOptionsResult{}, fmt.Errorf("client disconnected")
	}
	h.client.optionsSessions[params.ProviderInstanceID] = entry
	h.client.optionsMu.Unlock()
	return wire.ProviderOptionsResult{
		OptionsSessionID: optionsSessionID,
		ConfigOptions:    append([]provider.ConfigOption{}, opened.ConfigOptions...),
		Skills:           append([]provider.Skill(nil), opened.Skills...),
	}, nil
}

func (h *rpcHandler) setProviderOption(ctx context.Context, params wire.ProviderOptionsSetParams) (wire.ProviderOptionsResult, error) {
	if params.OptionsSessionID == "" || params.OptionID == "" {
		return wire.ProviderOptionsResult{}, fmt.Errorf("%w: provider.options.set requires optionsSessionId and optionId", jsonrpc2.ErrInvalidParams)
	}
	h.client.optionsLifecycleMu.Lock()
	defer h.client.optionsLifecycleMu.Unlock()

	h.client.optionsMu.Lock()
	var entry *clientOptionsSession
	for _, candidate := range h.client.optionsSessions {
		if candidate.optionsSessionID == params.OptionsSessionID {
			entry = candidate
			break
		}
	}
	if entry == nil {
		h.client.optionsMu.Unlock()
		return wire.ProviderOptionsResult{}, fmt.Errorf("options session %q is no longer active", params.OptionsSessionID)
	}
	snapshot := *entry
	h.client.optionsMu.Unlock()

	options, err := h.server.providerService.SetOption(ctx, snapshot.providerInstanceID, snapshot.handle, params.OptionID, params.Value)
	if err != nil {
		return wire.ProviderOptionsResult{}, err
	}
	h.client.optionsMu.Lock()
	current := h.client.optionsSessions[snapshot.providerInstanceID]
	if current != entry || current.optionsSessionID != snapshot.optionsSessionID {
		h.client.optionsMu.Unlock()
		return wire.ProviderOptionsResult{}, fmt.Errorf("options session %q is no longer active", params.OptionsSessionID)
	}
	current.configOptions = append([]provider.ConfigOption(nil), options...)
	skills := append([]provider.Skill(nil), current.skills...)
	h.client.optionsMu.Unlock()
	return wire.ProviderOptionsResult{
		OptionsSessionID: snapshot.optionsSessionID,
		ConfigOptions:    append([]provider.ConfigOption{}, options...),
		Skills:           skills,
	}, nil
}

func (h *rpcHandler) publishOptionsUpdate(instanceID provider.InstanceID, optionsSessionID string, options []provider.ConfigOption) {
	h.client.optionsMu.Lock()
	current := h.client.optionsSessions[instanceID]
	active := current != nil && current.optionsSessionID == optionsSessionID
	var skills []provider.Skill
	if active {
		current.configOptions = append([]provider.ConfigOption(nil), options...)
		skills = append([]provider.Skill(nil), current.skills...)
	}
	h.client.optionsMu.Unlock()
	if active {
		h.client.notify(wire.MethodProviderOptionsUpdated, wire.ProviderOptionsResult{
			OptionsSessionID: optionsSessionID,
			ConfigOptions:    append([]provider.ConfigOption{}, options...),
			Skills:           skills,
		})
	}
}

func (h *rpcHandler) invalidateOptionsSession(instanceID provider.InstanceID, optionsSessionID string) {
	h.client.optionsMu.Lock()
	current := h.client.optionsSessions[instanceID]
	active := current != nil && current.optionsSessionID == optionsSessionID
	if active {
		delete(h.client.optionsSessions, instanceID)
	}
	h.client.optionsMu.Unlock()
	if active {
		h.client.notify(wire.MethodProviderOptionsInvalidated, wire.ProviderOptionsInvalidated{OptionsSessionID: optionsSessionID})
	}
}

func (h *rpcHandler) closeOptionsSession(entry clientOptionsSession) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := h.server.providerService.CloseOptions(ctx, entry.providerInstanceID, entry.handle); err != nil {
		h.client.logger.Debug("close disposable options session", "provider", entry.providerInstanceID, "error", compactError(err))
	}
}

func (s *Server) closeClientOptionsSessions(client *rpcClient) {
	client.optionsLifecycleMu.Lock()
	defer client.optionsLifecycleMu.Unlock()

	client.optionsMu.Lock()
	entries := make([]clientOptionsSession, 0, len(client.optionsSessions))
	for _, entry := range client.optionsSessions {
		entries = append(entries, *entry)
	}
	client.optionsSessions = nil
	client.optionsMu.Unlock()
	for _, entry := range entries {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		if err := s.providerService.CloseOptions(ctx, entry.providerInstanceID, entry.handle); err != nil {
			client.logger.Debug("close disposable options session", "provider", entry.providerInstanceID, "error", compactError(err))
		}
		cancel()
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
	if refusal, ok := errors.AsType[*orchestration.CommandError](err); ok {
		code := commandRefusedCode
		if refusal.Code == orchestration.CodeInvalid {
			code = invalidParamsCode
		}
		data, _ := json.Marshal(map[string]orchestration.ErrorCode{"code": refusal.Code})
		return &jsonrpc2.WireError{Code: code, Message: refusal.Message, Data: data}
	}
	return err
}

// JSON-RPC codes of a refused command; data.code says why
// (wire CommandErrorCode).
const (
	invalidParamsCode  int64 = -32602
	commandRefusedCode int64 = -32001
)

func decodeRPCParams(req *jsonrpc2.Request, dst any) error {
	if len(req.Params) == 0 {
		return nil
	}
	if err := json.Unmarshal(req.Params, dst); err != nil {
		return fmt.Errorf("%w: decode %s params: %v", jsonrpc2.ErrInvalidParams, req.Method, err)
	}
	return nil
}

// marshalNotification encodes a notification's params once for every
// subscriber.
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
		c.closeConnection("client outbound queue full", "method", method)
	}
}
