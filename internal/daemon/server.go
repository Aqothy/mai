package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/Aqothy/maiD/internal/adapters"
	"github.com/Aqothy/maiD/internal/adapters/acp"
	"github.com/Aqothy/maiD/internal/ipc"
	"github.com/Aqothy/maiD/internal/model"
)

type Server struct {
	mu          sync.Mutex
	listener    net.Listener
	connections map[string]adapters.ConnectionHandle
}

func NewServer() *Server {
	return &Server{connections: make(map[string]adapters.ConnectionHandle)}
}

func (s *Server) Run(socketPath string) error {
	if socketPath == "" {
		socketPath = ipc.DefaultSocketPath
	}
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o755); err != nil {
		return fmt.Errorf("create socket dir: %w", err)
	}
	_ = os.Remove(socketPath)

	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		return err
	}
	s.listener = ln
	defer s.Close()

	for {
		conn, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		go s.handleConn(conn)
	}
}

func (s *Server) Close() error {
	var err error
	if s.listener != nil {
		err = s.listener.Close()
	}

	s.mu.Lock()
	handles := make([]adapters.ConnectionHandle, 0, len(s.connections))
	for _, handle := range s.connections {
		handles = append(handles, handle)
	}
	s.connections = make(map[string]adapters.ConnectionHandle)
	s.mu.Unlock()

	for _, handle := range handles {
		_ = handle.Close()
	}
	return err
}

func (s *Server) handleConn(conn net.Conn) {
	defer conn.Close()

	var req ipc.Request
	if err := json.NewDecoder(conn).Decode(&req); err != nil {
		writeResponse(conn, ipc.Response{OK: false, Message: err.Error()})
		return
	}

	writeResponse(conn, s.handle(req))
}

func (s *Server) handle(req ipc.Request) ipc.Response {
	switch req.Action {
	case ipc.ActionAgentInit:
		return s.handleAgentInit(req)
	case ipc.ActionAgentAuthenticate:
		return s.handleAgentAuthenticate(req)
	case ipc.ActionAgentLogout:
		return s.handleAgentLogout(req)
	case ipc.ActionSessionNew:
		return s.handleSessionNew(req)
	case ipc.ActionSessionLoad:
		return s.handleSessionLoad(req)
	case ipc.ActionSessionResume:
		return s.handleSessionResume(req)
	case ipc.ActionSessionClose:
		return s.handleSessionClose(req)
	case ipc.ActionSessionList:
		return s.handleSessionList(req)
	default:
		return ipc.Response{OK: false, Message: "unknown action: " + req.Action}
	}
}

func (s *Server) handleAgentInit(req ipc.Request) ipc.Response {
	var params ipc.AgentInitParams
	if err := req.DecodeParams(&params); err != nil {
		return fail(err)
	}
	if len(params.Command) == 0 {
		return ipc.Response{OK: false, Message: "agent init requires an ACP adapter command"}
	}
	name := params.Name
	if name == "" {
		name = filepath.Base(params.Command[0])
	}

	s.mu.Lock()
	if existing := s.connections[name]; existing != nil {
		info := existing.Info()
		s.mu.Unlock()
		return ok("agent already initialized "+name, info)
	}
	s.mu.Unlock()

	kind := model.AgentKind(params.Kind)
	if kind == "" {
		kind = model.AgentKindACP
	}
	adapter, err := adapterFor(kind)
	if err != nil {
		return fail(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	handle, err := adapter.StartConnection(ctx, adapters.StartConnectionRequest{Name: name, Kind: kind, Command: params.Command})
	if err != nil {
		return fail(err)
	}

	s.mu.Lock()
	s.connections[name] = handle
	s.mu.Unlock()
	return ok("initialized agent "+name, handle.Info())
}

func (s *Server) handleAgentAuthenticate(req ipc.Request) ipc.Response {
	var params ipc.AgentAuthenticateParams
	if err := req.DecodeParams(&params); err != nil {
		return fail(err)
	}
	if params.Name == "" {
		return ipc.Response{OK: false, Message: "agent authenticate requires a connection name"}
	}

	handle, err := s.connection(params.Name)
	if err != nil {
		return fail(err)
	}
	authenticator, supportsAuth := handle.(adapters.Authenticator)
	if !supportsAuth {
		return ipc.Response{OK: false, Message: "agent does not support authentication"}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	info, err := authenticator.Authenticate(ctx, params.MethodID)
	if err != nil {
		return fail(err)
	}
	return ok("authenticated agent "+params.Name, info)
}

func (s *Server) handleAgentLogout(req ipc.Request) ipc.Response {
	var params ipc.AgentLogoutParams
	if err := req.DecodeParams(&params); err != nil {
		return fail(err)
	}
	if params.Name == "" {
		return ipc.Response{OK: false, Message: "agent logout requires a connection name"}
	}

	handle, err := s.connection(params.Name)
	if err != nil {
		return fail(err)
	}
	authenticator, supportsAuth := handle.(adapters.Authenticator)
	if !supportsAuth {
		return ipc.Response{OK: false, Message: "agent does not support authentication"}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	info, err := authenticator.Logout(ctx)
	if err != nil {
		return fail(err)
	}
	return ok("logged out agent "+params.Name, info)
}

func (s *Server) handleSessionNew(req ipc.Request) ipc.Response {
	var params ipc.SessionNewParams
	if err := req.DecodeParams(&params); err != nil {
		return fail(err)
	}
	manager, err := s.sessionManager(params.Name)
	if err != nil {
		return fail(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	thread, err := manager.NewSession(ctx, model.AgentSessionRequest{Cwd: params.Cwd, Options: params.Options})
	if err != nil {
		return fail(err)
	}
	return ok("created session "+thread.ID, thread)
}

func (s *Server) handleSessionLoad(req ipc.Request) ipc.Response {
	var params ipc.SessionLoadParams
	if err := req.DecodeParams(&params); err != nil {
		return fail(err)
	}
	manager, err := s.sessionManager(params.Name)
	if err != nil {
		return fail(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	thread, err := manager.LoadSession(ctx, model.AgentSessionRequest{SessionID: params.SessionID, Cwd: params.Cwd, Options: params.Options})
	if err != nil {
		return fail(err)
	}
	return ok("loaded session "+thread.ID, thread)
}

func (s *Server) handleSessionResume(req ipc.Request) ipc.Response {
	var params ipc.SessionResumeParams
	if err := req.DecodeParams(&params); err != nil {
		return fail(err)
	}
	manager, err := s.sessionManager(params.Name)
	if err != nil {
		return fail(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	thread, err := manager.ResumeSession(ctx, model.AgentSessionRequest{SessionID: params.SessionID, Cwd: params.Cwd, Options: params.Options})
	if err != nil {
		return fail(err)
	}
	return ok("resumed session "+thread.ID, thread)
}

func (s *Server) handleSessionClose(req ipc.Request) ipc.Response {
	var params ipc.SessionCloseParams
	if err := req.DecodeParams(&params); err != nil {
		return fail(err)
	}
	manager, err := s.sessionManager(params.Name)
	if err != nil {
		return fail(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	thread, err := manager.CloseSession(ctx, params.SessionID)
	if err != nil {
		return fail(err)
	}
	return ok("closed session "+thread.ID, thread)
}

func (s *Server) handleSessionList(req ipc.Request) ipc.Response {
	var params ipc.SessionListParams
	if err := req.DecodeParams(&params); err != nil {
		return fail(err)
	}
	manager, err := s.sessionManager(params.Name)
	if err != nil {
		return fail(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	list, err := manager.ListSessions(ctx, model.AgentSessionListRequest{Cwd: params.Cwd, Cursor: params.Cursor, Options: params.Options})
	if err != nil {
		return fail(err)
	}
	return ok(fmt.Sprintf("listed %d sessions", len(list.Threads)), list)
}

func (s *Server) connection(name string) (adapters.ConnectionHandle, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	handle := s.connections[name]
	if handle == nil {
		return nil, fmt.Errorf("agent %q is not initialized", name)
	}
	return handle, nil
}

func (s *Server) sessionManager(name string) (adapters.SessionManager, error) {
	if name == "" {
		return nil, fmt.Errorf("session actions require a connection name")
	}
	handle, err := s.connection(name)
	if err != nil {
		return nil, err
	}
	manager, supportsSessions := handle.(adapters.SessionManager)
	if !supportsSessions {
		return nil, fmt.Errorf("agent does not support sessions")
	}
	return manager, nil
}

func adapterFor(kind model.AgentKind) (adapters.Adapter, error) {
	switch kind {
	case model.AgentKindACP:
		return acp.New(), nil
	default:
		return nil, fmt.Errorf("unsupported agent kind %q", kind)
	}
}

func writeResponse(conn net.Conn, resp ipc.Response) {
	_ = json.NewEncoder(conn).Encode(resp)
}

func ok(message string, data any) ipc.Response {
	var raw json.RawMessage
	if data != nil {
		raw, _ = json.Marshal(data)
	}
	return ipc.Response{OK: true, Message: message, Data: raw}
}

func fail(err error) ipc.Response {
	return ipc.Response{OK: false, Message: err.Error()}
}
