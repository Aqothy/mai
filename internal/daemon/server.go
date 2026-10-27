package daemon

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/Aqothy/maiD/internal/adapters/claudecode"
	"github.com/Aqothy/maiD/internal/adapters/codexapp"
	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/providerservice"
	"github.com/Aqothy/maiD/internal/store"
	"github.com/Aqothy/maiD/internal/workspacesearch"
)

type Server struct {
	logger *slog.Logger

	mu         sync.Mutex
	httpServer *http.Server

	ctx       context.Context
	ctxCancel context.CancelFunc

	providerService *providerservice.Service
	acpRegistry     *acpRegistry
	engine          *orchestration.Engine
	metadataStore   *store.SQLite

	terminals *terminalRuntime

	// workspaceSearch owns the warm per-workspace FFF file indexes behind
	// workspace.searchFiles.
	workspaceSearch *workspacesearch.Service

	pingInterval time.Duration

	rpcMu      sync.Mutex
	rpcClients map[string]*rpcClient

	closeOnce sync.Once
	closeErr  error
	// fatalErr, guarded by mu, records the error that stopped the
	// orchestration engine; RunWebSocket returns it so main owns the exit.
	fatalErr error
}

// NewServer opens the data directory and starts the daemon's services.
func NewServer() (*Server, error) {
	logger := newLoggerFromEnv()
	dir, err := maidDataDir()
	if err != nil {
		return nil, err
	}
	return newServer(logger, dir, drivers)
}

// newServer starts the daemon on a data directory with drivers.
func newServer(logger *slog.Logger, dataDir string, drivers map[provider.DriverKind]provider.Driver) (*Server, error) {
	metadata, err := store.Open(filepath.Join(dataDir, "maid.db"))
	if err != nil {
		return nil, err
	}
	logger.Info("data directory opened", "path", dataDir)
	ctx, cancel := context.WithCancel(context.Background())
	s := &Server{
		logger:        logger,
		pingInterval:  rpcPingInterval,
		rpcClients:    make(map[string]*rpcClient),
		ctx:           ctx,
		ctxCancel:     cancel,
		metadataStore: metadata,
		acpRegistry:   newACPRegistry(),
	}
	s.terminals = newTerminalRuntime(metadata, logger)
	s.workspaceSearch = workspacesearch.NewService()
	// The engine and the providers need each other: the providers report to
	// the engine, which they don't call until it has started.
	var engine *orchestration.Engine
	s.providerService = providerservice.New(drivers, metadata, func(id provider.InstanceID) provider.Mirror { return engine.Mirror(id) }, providerservice.Sink{
		Event: func(instance provider.InstanceID, generation uint64, event provider.Event) {
			engine.ProviderEvent(instance, generation, event)
		},
		Gone: func(instance provider.InstanceID, generation uint64) { engine.InstanceGone(instance, generation) },
	}, logger)
	defaultCwd, _ := os.Getwd()
	engine, err = orchestration.Open(orchestration.Config{
		DB: metadata.DB(), Providers: s.providerService, DataDir: dataDir, DefaultCwd: defaultCwd, Logger: logger,
	})
	if err != nil {
		cancel()
		_ = metadata.Close()
		return nil, err
	}
	s.engine = engine
	go s.watchEngine()
	for _, spec := range []provider.InstanceSpec{
		{InstanceID: "codex-app-server", Name: "Codex", Driver: codexapp.DriverKind},
		{InstanceID: "claude-code", Name: "Claude Code", Driver: claudecode.DriverKind},
	} {
		if err := s.providerService.RegisterManifestInstance(spec); err != nil {
			logger.Warn("register provider", "provider", spec.InstanceID, "error", err)
		}
	}
	if specs, err := s.acpRegistry.instanceSpecs(); err != nil {
		logger.Warn("load installed ACP agent definitions", "error", err)
	} else {
		for _, spec := range specs {
			if err := s.providerService.RegisterManifestInstance(spec); err != nil {
				logger.Warn("register installed ACP agent", "provider", spec.InstanceID, "error", err)
			}
		}
	}
	return s, nil
}

// watchEngine shuts the daemon down when the engine stops on its own: its
// state can no longer be trusted, and main owns the process exit.
func (s *Server) watchEngine() {
	<-s.engine.Done()
	if err := s.engine.Err(); err != nil {
		s.mu.Lock()
		if s.fatalErr == nil {
			s.fatalErr = err
		}
		s.mu.Unlock()
		go s.Close()
	}
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
	s.ctxCancel()

	s.mu.Lock()
	httpServer := s.httpServer
	s.mu.Unlock()

	var err error
	if httpServer != nil {
		err = httpServer.Close()
	}
	s.providerService.Close()
	s.engine.Close()
	// Terminal shells never survive daemon shutdown; wait for every process
	// group to be cleaned up before releasing clients and the store.
	s.terminals.service.Close()
	s.workspaceSearch.Close()

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
	_ = s.metadataStore.Close()
	return err
}

// authenticateProvider signs in to a provider. A provider whose sign-in is an
// interactive program gets it run in a maiD terminal the client then opens;
// once it exits successfully the provider restarts, as soon as no turn is
// running on it, so it picks up the new credentials.
func (s *Server) authenticateProvider(ctx context.Context, instanceID provider.InstanceID, input provider.AuthenticateInput) (provider.AuthenticationResult, error) {
	result, err := s.providerService.Authenticate(ctx, instanceID, input)
	if err != nil || result.Terminal == nil {
		return result, err
	}
	terminalID, err := s.startCommandTerminal("Sign in to "+result.Instance.Name, *result.Terminal, func(exitCode *int) {
		if exitCode == nil || *exitCode != 0 {
			s.logger.Info("terminal sign-in did not succeed", "provider", instanceID, "exitCode", exitCode)
			return
		}
		s.restartProviderWhenIdle(instanceID)
	})
	if err != nil {
		return provider.AuthenticationResult{}, err
	}
	result.Challenge = &provider.AuthChallenge{Kind: provider.AuthKindTerminal, TerminalID: terminalID}
	return result, nil
}

// providerIdlePollInterval is how often a pending provider restart checks
// whether the provider's turns have finished.
const providerIdlePollInterval = time.Second

// restartProviderWhenIdle restarts a provider once no turn runs on it, so a
// restart never cuts off another thread's turn.
func (s *Server) restartProviderWhenIdle(instanceID provider.InstanceID) {
	ticker := time.NewTicker(providerIdlePollInterval)
	defer ticker.Stop()
	for s.engine.InstanceBusy(s.ctx, instanceID) {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
		}
	}
	ctx, cancel := context.WithTimeout(s.ctx, 2*time.Minute)
	defer cancel()
	if _, err := s.providerService.RestartInstance(ctx, instanceID); err != nil {
		s.logger.Warn("restart provider after terminal sign-in", "provider", instanceID, "error", err)
	}
}

func (s *Server) StartACPRegistryProvider(ctx context.Context, registryID string, restart bool) (provider.InstanceInfo, error) {
	spec, err := s.acpRegistry.instanceSpec(registryID)
	if err != nil {
		return provider.InstanceInfo{}, err
	}
	// npm may need to acquire the package before the agent can initialize.
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	started := time.Now()
	info, err := s.providerService.StartManifestInstance(ctx, spec, restart)
	s.logProviderStarted(spec, restart, started, err)
	return info, err
}

func (s *Server) StartProvider(ctx context.Context, spec provider.InstanceSpec, restart bool) (provider.InstanceInfo, error) {
	if spec.InstanceID != "" && spec.Name == "" && spec.Driver == "" && len(spec.Config) == 0 && !restart {
		return s.providerService.StartConfiguredInstance(ctx, spec.InstanceID)
	}
	if spec.InstanceID == "" {
		return provider.InstanceInfo{}, fmt.Errorf("provider start requires instanceId")
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	started := time.Now()
	info, err := s.providerService.StartInstance(ctx, spec, restart)
	s.logProviderStarted(spec, restart, started, err)
	return info, err
}

func (s *Server) logProviderStarted(spec provider.InstanceSpec, restart bool, started time.Time, err error) {
	if err == nil {
		s.logger.Info("provider started", "provider", spec.InstanceID, "driver", spec.Driver, "restart", restart, "duration", time.Since(started).Round(time.Millisecond))
	}
}
