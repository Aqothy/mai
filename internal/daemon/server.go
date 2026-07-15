package daemon

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/Aqothy/maiD/internal/adapters/acp"
	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/providerservice"
	"github.com/Aqothy/maiD/internal/store"
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
	logger *slog.Logger

	mu         sync.Mutex
	httpServer *http.Server

	ctx       context.Context
	ctxCancel context.CancelFunc

	providerService *providerservice.Service
	orchestration   *orchestration.Engine
	ingestion       *orchestration.ProviderRuntimeIngestion
	reactor         *orchestration.ProviderEventReactor

	metadataStore    *store.SQLite
	threadMetaWriter *threadMetaWriter

	rpcMu      sync.Mutex
	rpcClients map[string]*rpcClient

	closeOnce sync.Once
	closeErr  error
	// fatalErr, guarded by mu, records an orchestration invariant violation;
	// RunWebSocket returns it so main owns the process exit.
	fatalErr error
}

func NewServer() *Server {
	logger := newLoggerFromEnv()
	return newServer(logger, openMetadataStore(logger))
}

func newServer(logger *slog.Logger, metadata *store.SQLite) *Server {
	ctx, cancel := context.WithCancel(context.Background())
	s := &Server{logger: logger, rpcClients: make(map[string]*rpcClient), ctx: ctx, ctxCancel: cancel, metadataStore: metadata}
	s.orchestration = orchestration.NewEngine()
	s.orchestration.OnInvariantViolation(s.handleInvariantViolation)
	if metadata != nil {
		count, err := restorePersistedThreads(s.orchestration, metadata, metadata, logger)
		if err != nil {
			logger.Warn("restore persisted threads", "error", err)
		} else {
			logger.Info("restored persisted threads", "count", count)
		}
	}
	s.ingestion = orchestration.NewProviderRuntimeIngestion(s.orchestration)
	var providerOptions []providerservice.Option
	if metadata != nil {
		providerOptions = append(providerOptions, providerservice.WithRouteStore(metadata))
		s.threadMetaWriter = newThreadMetaWriter(s.orchestration, metadata, logger)
	}
	s.providerService = providerservice.New(openProviderInstance, providerOptions...)
	s.reactor = orchestration.NewProviderEventReactor(ctx, s.orchestration, s.providerService, s.ingestion)
	go s.ingestion.Run(ctx, s.providerService.Events())
	s.orchestration.OnEvent(func(event orchestration.Event) {
		s.logEvent(event)
		if s.threadMetaWriter != nil && orchestration.ThreadMetadataMayChange(event) {
			s.threadMetaWriter.markDirty(event.ThreadID())
		}
		s.publishOrchestrationEvent(event)
	})
	return s
}

func newLoggerFromEnv() *slog.Logger {
	level := slog.LevelInfo
	switch strings.ToLower(os.Getenv("MAID_LOG_LEVEL")) {
	case "debug":
		level = slog.LevelDebug
	case "warn", "warning":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	}
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))
}

// logEvent deliberately records only correlation metadata. Event payloads can
// contain prompts, tool output, attachments, and secrets and do not belong in
// routine daemon logs. Full events remain available through replay/diagnostics.
func (s *Server) logEvent(event orchestration.Event) {
	attrs := []any{
		"sequence", event.Sequence,
		"event", event.Type,
		"actor", event.Actor,
		"thread", event.ThreadID(),
	}
	if event.CommandID != "" {
		attrs = append(attrs, "command", event.CommandID)
	}

	// Streamed text and reasoning chunks are intentionally absent. They are
	// high-volume, may contain private content, and their lifecycle boundaries
	// are already represented by turn/session events.
	switch event.Type {
	case orchestration.EventThreadMessageSent:
		return
	case orchestration.EventThreadItemUpserted:
		item := event.Payload.Item
		if item == nil || item.TextDelta != "" {
			return
		}
		attrs = append(attrs, "item", item.ID, "kind", item.Kind, "status", item.Status, "turn", item.TurnID)
	case orchestration.EventThreadSessionStatusSet:
		if session := event.Payload.Session; session != nil {
			attrs = append(attrs, "provider", session.ProviderInstanceID, "status", session.Status, "turn", session.ActiveTurnID, "generation", session.ProviderGeneration)
		}
	case orchestration.EventThreadTurnStartRequested,
		orchestration.EventThreadTurnInterruptRequested,
		orchestration.EventThreadTurnInterruptConfirmed,
		orchestration.EventThreadTurnInterruptFailed:
		attrs = append(attrs, "turn", event.Payload.TurnID)
	case orchestration.EventThreadApprovalOpened, orchestration.EventThreadApprovalResolved:
		if approval := event.Payload.Approval; approval != nil {
			attrs = append(attrs, "request", approval.RequestID, "turn", approval.TurnID, "kind", approval.RequestType, "decision", approval.Decision)
		}
	case orchestration.EventThreadPlanUpdated:
		if plan := event.Payload.Plan; plan != nil {
			attrs = append(attrs, "entries", len(plan.Entries))
		}
	case orchestration.EventThreadConfigOptionsUpdated:
		attrs = append(attrs, "options", len(event.Payload.ConfigOptions))
	case orchestration.EventThreadSlashCommandsUpdated:
		attrs = append(attrs, "commands", len(event.Payload.SlashCommands))
	case orchestration.EventThreadTokenUsageUpdated:
		if usage := event.Payload.TokenUsage; usage != nil {
			attrs = append(attrs, "usedTokens", usage.UsedTokens)
		}
	}
	s.logger.Debug("orchestration event", attrs...)
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

	if s.threadMetaWriter != nil {
		<-s.orchestration.Stopped()
		s.threadMetaWriter.Close()
	}
	if s.metadataStore != nil {
		_ = s.metadataStore.Close()
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
	started := time.Now()
	info, err := s.providerService.StartInstance(ctx, spec, restart)
	if err == nil {
		s.logger.Info("provider started", "provider", spec.InstanceID, "driver", spec.Driver, "restart", restart, "duration", time.Since(started).Round(time.Millisecond))
	}
	return info, err
}
