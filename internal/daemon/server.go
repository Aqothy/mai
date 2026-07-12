package daemon

import (
	"context"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/Aqothy/maiD/internal/adapters/acp"
	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/providerservice"
)

// openProviderInstance maps a configured provider driver to its adapter.
// New drivers get a case here; providerservice supplies the runtime event sink.
func openProviderInstance(ctx context.Context, spec provider.InstanceSpec, emit provider.RuntimeEventListener) (providerservice.ProviderInstance, error) {
	switch spec.Driver {
	case acp.DriverKind:
		return acp.OpenInstance(ctx, spec, emit)
	default:
		return nil, fmt.Errorf("unsupported provider driver %q", spec.Driver)
	}
}

type Server struct {
	mu         sync.Mutex
	httpServer *http.Server

	ctx       context.Context
	ctxCancel context.CancelFunc

	providerService *providerservice.Service
	orchestration   *orchestration.Engine
	ingestion       *orchestration.ProviderRuntimeIngestion
	reactor         *orchestration.ProviderEventReactor

	rpcMu      sync.Mutex
	rpcClients map[string]*rpcClient

	closeOnce sync.Once
	closeErr  error
	// fatalErr, guarded by mu, records an orchestration invariant violation;
	// RunWebSocket returns it so main owns the process exit.
	fatalErr error
}

func NewServer() *Server {
	ctx, cancel := context.WithCancel(context.Background())
	s := &Server{rpcClients: make(map[string]*rpcClient), ctx: ctx, ctxCancel: cancel}
	s.orchestration = orchestration.NewEngine()
	s.orchestration.OnInvariantViolation(s.handleInvariantViolation)
	s.ingestion = orchestration.NewProviderRuntimeIngestion(s.orchestration)
	s.providerService = providerservice.New(openProviderInstance)
	s.reactor = orchestration.NewProviderEventReactor(ctx, s.orchestration, s.providerService)
	go s.ingestion.Run(ctx, s.providerService.Events())
	s.orchestration.OnEvent(func(event orchestration.Event) { s.publishOrchestrationEvent(event) })
	return s
}

// handleInvariantViolation preserves main's ownership of process exit while
// using normal shutdown to kill every group-isolated provider process.
func (s *Server) handleInvariantViolation(err *orchestration.InvariantViolationError) {
	s.mu.Lock()
	if s.fatalErr == nil {
		s.fatalErr = err
	}
	s.mu.Unlock()
	_ = s.Close()
}

// Close shuts the daemon down exactly once; concurrent callers block until the
// full shutdown has completed. The blocking matters: closing the HTTP listener
// makes RunWebSocket return and the process exit, so a second Close that
// returned before every provider instance was killed would let main exit
// mid-shutdown and leak group-isolated agent processes on SIGTERM.
func (s *Server) Close() error {
	s.closeOnce.Do(func() { s.closeErr = s.doClose() })
	return s.closeErr
}

func (s *Server) doClose() error {
	if s.ctxCancel != nil {
		s.ctxCancel()
	}

	s.mu.Lock()
	httpServer := s.httpServer
	s.mu.Unlock()

	var err error
	if httpServer != nil {
		err = httpServer.Close()
	}
	if s.orchestration != nil {
		s.orchestration.Close()
	}
	if s.providerService != nil {
		s.providerService.Close()
	}

	s.rpcMu.Lock()
	clients := make([]*rpcClient, 0, len(s.rpcClients))
	for _, client := range s.rpcClients {
		clients = append(clients, client)
	}
	s.rpcClients = make(map[string]*rpcClient)
	s.rpcMu.Unlock()

	for _, client := range clients {
		_ = client.conn.Close()
		client.closeOutbound()
	}
	return err
}

// StartProvider brings a provider instance online or restarts it.
func (s *Server) StartProvider(ctx context.Context, spec provider.InstanceSpec, restart bool) (provider.InstanceInfo, error) {
	if spec.InstanceID == "" {
		return provider.InstanceInfo{}, fmt.Errorf("provider start requires instanceId")
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	return s.providerService.StartInstance(ctx, spec, restart)
}
