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

var nextRPCClientID atomic.Uint64

const (
	rpcOutboundQueueSize = 1024
)

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

	subscriptionsMu        sync.Mutex
	threadSubscriptions    map[orchestration.ThreadID]struct{}
	terminalSubscriptions  map[string]struct{}
	threadListSubscribed   bool
	terminalListSubscribed bool

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
	if err != nil {
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
	client := &rpcClient{
		id: fmt.Sprintf("client-%d", nextRPCClientID.Add(1)), conn: conn,
		outbound: make(chan rpcOutbound, rpcOutboundQueueSize), done: make(chan struct{}),
		threadSubscriptions:   make(map[orchestration.ThreadID]struct{}),
		terminalSubscriptions: make(map[string]struct{}),
	}
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
	// Cleanup is deliberately independent of who first closed the outbound
	// channel. Queue overflow can close it before socket teardown reaches this
	// path, and detaching the active sessions makes repeated cleanup harmless.
	go s.closeClientOptionsSessions(client)
	// Terminal subscriptions live on the connection and disappear with it;
	// shells remain alive in the terminal service. Each subscribed session
	// still needs its attachment count refreshed so detached agent runs can
	// report Done.
	for _, terminalID := range client.terminalSubscriptionIDs() {
		s.refreshTerminalAttachment(terminalID)
	}
}

// refreshTerminalAttachment re-derives whether any connected client remains
// attached to the terminal's live run.
func (s *Server) refreshTerminalAttachment(terminalID string) {
	session, err := s.terminals.service.Get(terminalID)
	if err != nil {
		return
	}
	session.SetAttached(len(s.terminalSubscribers(terminalID)) > 0)
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

// subscribeTerminal adds one terminal stream listener and reports whether it
// was newly added. The result lets failed create/relaunch calls roll back only
// the subscription they introduced.
func (c *rpcClient) subscribeTerminal(terminalID string) bool {
	c.subscriptionsMu.Lock()
	defer c.subscriptionsMu.Unlock()
	_, existed := c.terminalSubscriptions[terminalID]
	c.terminalSubscriptions[terminalID] = struct{}{}
	return !existed
}

func (c *rpcClient) unsubscribeTerminal(terminalID string) {
	c.subscriptionsMu.Lock()
	defer c.subscriptionsMu.Unlock()
	delete(c.terminalSubscriptions, terminalID)
}

func (c *rpcClient) subscribedTerminal(terminalID string) bool {
	c.subscriptionsMu.Lock()
	defer c.subscriptionsMu.Unlock()
	_, ok := c.terminalSubscriptions[terminalID]
	return ok
}

func (c *rpcClient) terminalSubscriptionIDs() []string {
	c.subscriptionsMu.Lock()
	defer c.subscriptionsMu.Unlock()
	ids := make([]string, 0, len(c.terminalSubscriptions))
	for terminalID := range c.terminalSubscriptions {
		ids = append(ids, terminalID)
	}
	return ids
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
	switch req.Method {
	case wire.MethodOrchestrationDispatchCommand:
		if !req.IsCall() {
			return nil, fmt.Errorf("%w: orchestration.dispatchCommand must be a request", jsonrpc2.ErrInvalidRequest)
		}
		var command orchestration.Command
		if err := decodeRPCParams(req, &command); err != nil {
			return nil, err
		}
		return h.server.orchestration.Dispatch(ctx, command)
	case wire.MethodOrchestrationSubscribeThread:
		var params orchestration.SubscribeThreadInput
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		if params.ThreadID == "" {
			return nil, fmt.Errorf("%w: subscribeThread requires threadId", jsonrpc2.ErrInvalidParams)
		}
		h.client.subscribeThread(params.ThreadID)
		snapshot, err := h.server.orchestration.SubscribeThread(params)
		if err != nil {
			h.client.unsubscribeThread(params.ThreadID)
			return nil, err
		}
		if h.afterThreadSnapshot != nil {
			h.afterThreadSnapshot(params.ThreadID)
		}
		return snapshot, nil
	case wire.MethodOrchestrationUnsubscribeThread:
		var params orchestration.SubscribeThreadInput
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		if params.ThreadID == "" {
			return nil, fmt.Errorf("%w: unsubscribeThread requires threadId", jsonrpc2.ErrInvalidParams)
		}
		h.client.unsubscribeThread(params.ThreadID)
		return nil, nil
	case wire.MethodOrchestrationGetItemDetail:
		var params orchestration.GetItemDetailInput
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		if params.ThreadID == "" || params.ItemID == "" {
			return nil, fmt.Errorf("%w: getItemDetail requires threadId and itemId", jsonrpc2.ErrInvalidParams)
		}
		return h.server.orchestration.GetItemDetail(params)
	case wire.MethodOrchestrationSubscribeThreadList:
		h.client.subscribeThreadList()
		return h.server.orchestration.ThreadListSnapshot(), nil
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
		return h.server.providerService.Authenticate(ctx, params.InstanceID, provider.AuthenticateInput{MethodID: params.MethodID, Secret: params.Secret})
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
		return h.server.providerService.ListSessions(ctx, params.InstanceID, params.Cwd)
	case wire.MethodProviderImportSession:
		var params wire.ProviderImportSessionParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		// An external session has no app-selected settings, so it resumes with
		// the provider's own model and configuration.
		threadID, imported, err := h.server.ImportProviderSession(ctx, params.InstanceID, params.Session, provider.StartSessionInput{})
		if err != nil {
			return nil, err
		}
		return wire.ProviderImportSessionResult{ThreadID: threadID, Imported: imported}, nil
	case wire.MethodProviderDeleteSession:
		var params wire.ProviderSessionParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return nil, h.server.providerService.DeleteSession(ctx, params.InstanceID, params.SessionID)
	case wire.MethodProviderCloseSession:
		var params wire.ProviderSessionParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return nil, h.server.providerService.CloseSession(ctx, params.InstanceID, params.SessionID)
	case wire.MethodProviderForkThread:
		var params wire.ProviderForkThreadParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		threadID, imported, err := h.server.ForkProviderThread(ctx, params.SourceThreadID)
		if err != nil {
			return nil, err
		}
		return wire.ProviderImportSessionResult{ThreadID: threadID, Imported: imported}, nil
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
		var params wire.TerminalAttachParams
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
	case wire.MethodTerminalTerminate:
		var params wire.TerminalIDParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return nil, h.server.terminateTerminal(params.TerminalID)
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
	case wire.MethodWorkspaceBrowseDirectories:
		var params wire.WorkspaceBrowseDirectoriesParams
		if err := decodeRPCParams(req, &params); err != nil {
			return nil, err
		}
		return h.server.browseWorkspaceDirectories(params)
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
			ConfigOptions:    append([]provider.ConfigOption(nil), current.configOptions...),
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
	opened, err := h.server.providerService.OpenOptionsSession(ctx, params.ProviderInstanceID, params.Cwd, callbacks)
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
		ConfigOptions:    append([]provider.ConfigOption(nil), opened.ConfigOptions...),
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

	options, err := h.server.providerService.SetOptionsSessionValue(ctx, snapshot.providerInstanceID, snapshot.handle, params.OptionID, params.Value)
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
		ConfigOptions:    append([]provider.ConfigOption(nil), options...),
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
			ConfigOptions:    append([]provider.ConfigOption(nil), options...),
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
	if err := h.server.providerService.CloseOptionsSession(ctx, entry.providerInstanceID, entry.handle); err != nil {
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
		if err := s.providerService.CloseOptionsSession(ctx, entry.providerInstanceID, entry.handle); err != nil {
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
//   - collapse provider history replay into one authoritative snapshot. A
//     replay can contain thousands of intermediate item updates even when its
//     final timeline has only a few dozen entries; sending those transient
//     states can overflow a healthy client's bounded outbound queue and make
//     the UI repeatedly render content that is immediately replaced.
func (s *Server) publishOrchestrationEvent(event orchestration.Event) {
	threadID := event.ThreadID()
	if threadID == "" {
		return
	}

	beginsHistoryReplay := event.Type == orchestration.EventThreadSessionPrepareRequested &&
		s.orchestration.ThreadHistoryRestorePending(threadID)
	endsHistoryReplay := event.EndsHistoryReplay()

	s.rpcMu.Lock()
	if beginsHistoryReplay {
		s.historyReplayCoalescing[threadID] = struct{}{}
	}
	_, suppressForHistoryReplay := s.historyReplayCoalescing[threadID]
	refreshAfterHistoryReplay := suppressForHistoryReplay && endsHistoryReplay
	if refreshAfterHistoryReplay {
		delete(s.historyReplayCoalescing, threadID)
	}

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

	if suppressForHistoryReplay && !refreshAfterHistoryReplay {
		return
	}
	if len(threadClients) == 0 && len(threadListClients) == 0 {
		return
	}

	if refreshAfterHistoryReplay {
		s.publishThreadRefresh(threadID, event.Sequence, threadClients, threadListClients)
		return
	}

	if len(threadClients) > 0 {
		clientEvent := orchestration.ProjectEventForClient(event)
		if params, ok := s.marshalNotification(orchestration.ThreadStreamItem{Kind: orchestration.StreamItemEvent, Event: &clientEvent}, wire.MethodOrchestrationSubscribeThread); ok {
			for _, client := range threadClients {
				client.notify(wire.MethodOrchestrationSubscribeThread, params)
			}
		}
	}
	if len(threadListClients) == 0 || !orchestration.ThreadListVisible(event) {
		return
	}
	s.publishThreadListUpsert(threadID, event.Sequence, threadListClients)
}

// publishThreadRefresh replaces every suppressed replay update with one final
// detail snapshot and one sidebar upsert. Internal engine listeners still see
// every replay event; only the client transport is coalesced.
func (s *Server) publishThreadRefresh(threadID orchestration.ThreadID, sequence uint64, threadClients, threadListClients []*rpcClient) {
	if len(threadClients) > 0 {
		item, err := s.orchestration.SubscribeThread(orchestration.SubscribeThreadInput{ThreadID: threadID})
		if err != nil {
			s.logger.Error("history replay snapshot failed", "thread", threadID, "error", err)
		} else if params, ok := s.marshalNotification(item, wire.MethodOrchestrationSubscribeThread); ok {
			for _, client := range threadClients {
				client.notify(wire.MethodOrchestrationSubscribeThread, params)
			}
		}
	}
	if len(threadListClients) > 0 {
		s.publishThreadListUpsert(threadID, sequence, threadListClients)
	}
}

func (s *Server) publishThreadListUpsert(threadID orchestration.ThreadID, sequence uint64, clients []*rpcClient) {
	entry, ok := s.orchestration.ThreadListEntry(threadID)
	if !ok {
		return
	}
	if params, ok := s.marshalNotification(orchestration.ThreadListStreamItem{Kind: orchestration.StreamItemThreadUpserted, Sequence: sequence, Thread: &entry}, wire.MethodOrchestrationSubscribeThreadList); ok {
		for _, client := range clients {
			client.notify(wire.MethodOrchestrationSubscribeThreadList, params)
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
		c.closeConnection("client outbound queue full", "method", method)
	}
}
