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

	"github.com/Aqothy/maiD/api/wire"
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
	}
	s.acpRegistry = newACPRegistry(ctx, dataDir, logger, s.publishACPRegistryList)
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
	engine, err = orchestration.Open(orchestration.Config{
		DB: metadata.DB(), Providers: s.providerService, DataDir: dataDir, Logger: logger,
	})
	if err != nil {
		cancel()
		_ = metadata.Close()
		return nil, err
	}
	s.engine = engine
	go s.watchEngine()
	go s.stopIdleProviders()
	for _, spec := range []provider.InstanceSpec{
		{InstanceID: "codex-app-server", Name: "Codex", Driver: codexapp.DriverKind},
		{InstanceID: "claude-code", Name: "Claude Code", Driver: claudecode.DriverKind},
	} {
		if err := s.providerService.RegisterManifestInstance(spec); err != nil {
			logger.Warn("register provider", "provider", spec.InstanceID, "error", err)
		}
	}
	if err := s.acpRegistry.pruneFiles(); err != nil {
		logger.Warn("delete removed ACP agents' files", "error", err)
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
	// Agents and terminal shells never survive daemon shutdown. Stop them at
	// once, so shutdown takes one grace, and wait for every process group to be
	// cleaned up before releasing clients and the store.
	var stopped sync.WaitGroup
	stopped.Go(s.terminals.service.Close)
	stopped.Go(s.acpRegistry.waitForJobs)
	s.providerService.Close()
	s.engine.Close()
	stopped.Wait()
	// Close streams before the process exits, so their clients hear why.
	for _, stream := range s.terminals.closeStreams() {
		<-stream.finished
	}
	s.workspaceSearch.Close()

	s.rpcMu.Lock()
	clients := make([]*rpcClient, 0, len(s.rpcClients))
	for _, client := range s.rpcClients {
		clients = append(clients, client)
	}
	s.rpcClients = make(map[string]*rpcClient)
	s.rpcMu.Unlock()

	// Close the sockets first: a client that stopped reading blocks the
	// connection's writes, and the connection's own Close waits for them.
	for _, client := range clients {
		_ = client.socket.CloseNow()
	}
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
	if err != nil {
		return result, err
	}
	if result.Terminal == nil {
		s.spreadAccountChange(instanceID)
		return result, nil
	}
	terminalID, err := s.startCommandTerminal("Sign in to "+result.Instance.Name, *result.Terminal, func(exitCode *int) {
		if exitCode == nil || *exitCode != 0 {
			s.logger.Info("terminal sign-in did not succeed", "provider", instanceID, "exitCode", exitCode)
			return
		}
		s.restartProviderWhenIdle(instanceID, func(ctx context.Context) error {
			_, err := s.providerService.RestartInstance(ctx, instanceID)
			return err
		})
	})
	if err != nil {
		return provider.AuthenticationResult{}, err
	}
	result.Challenge = &provider.AuthChallenge{Kind: provider.AuthKindTerminal, TerminalID: terminalID}
	return result, nil
}

// logoutProvider signs out of a provider.
func (s *Server) logoutProvider(ctx context.Context, instanceID provider.InstanceID) (provider.InstanceInfo, error) {
	info, err := s.providerService.Logout(ctx, instanceID)
	if err == nil {
		s.spreadAccountChange(instanceID)
	}
	return info, err
}

// spreadAccountChange restarts the instance's processes once idle when it has
// several: a sign-in or sign-out reaches only the process it ran on, and another
// folder's may keep the old account until it starts again.
func (s *Server) spreadAccountChange(instanceID provider.InstanceID) {
	if s.providerService.ProcessCount(instanceID) < 2 {
		return
	}
	go s.restartProviderWhenIdle(instanceID, func(ctx context.Context) error {
		_, err := s.providerService.RestartInstance(ctx, instanceID)
		return err
	})
}

// A process serving a folder stops after this long without work. Long enough
// for a conversation's pauses, since the next message then waits for a new
// process and session/resume.
const (
	providerIdleTimeout       = 10 * time.Minute
	providerIdleCheckInterval = time.Minute
)

func (s *Server) stopIdleProviders() {
	ticker := time.NewTicker(providerIdleCheckInterval)
	defer ticker.Stop()
	for {
		select {
		case <-s.ctx.Done():
			return
		case now := <-ticker.C:
			s.providerService.StopIdle(now.Add(-providerIdleTimeout), func(id provider.InstanceID, generation uint64) bool {
				return s.engine.ProcessBusy(s.ctx, id, generation)
			})
		}
	}
}

// restartProviderWhenIdle runs restart once no turn runs on the provider, and
// starts none until it's done, so a restart never cuts off a thread's turn.
func (s *Server) restartProviderWhenIdle(instanceID provider.InstanceID, restart func(context.Context) error) {
	resume, err := s.engine.PauseInstance(s.ctx, instanceID)
	if err != nil {
		return
	}
	defer resume()
	ctx, cancel := context.WithTimeout(s.ctx, 2*time.Minute)
	defer cancel()
	if err := restart(ctx); err != nil {
		s.logger.Warn("restart provider", "provider", instanceID, "error", err)
	}
}

// publishACPRegistryList tells every subscribed client. It never blocks: a
// client that can't keep up is closed and recovers from a fresh snapshot.
func (s *Server) publishACPRegistryList(list wire.ACPRegistryList) {
	s.rpcMu.Lock()
	defer s.rpcMu.Unlock()
	for _, client := range s.rpcClients {
		if client.subscribedACPRegistryList() {
			client.notify(wire.MethodACPRegistryList, list)
		}
	}
}

// installACPAgent starts or joins the job bringing an agent to the version the
// registry lists. The job outlives the call.
func (s *Server) installACPAgent(ctx context.Context, id string) error {
	job, err := s.acpRegistry.startInstall(ctx, id)
	if err != nil || job == nil {
		return err
	}
	go s.runACPInstall(job)
	return nil
}

// runACPInstall builds the new version and makes it the agent's definition
// before saying it is installed, so a client that sees that can start it.
func (s *Server) runACPInstall(job *acpInstallJob) {
	record, err := s.acpRegistry.build(job)
	if err == nil {
		err = s.providerService.RegisterManifestInstance(s.acpRegistry.instanceSpecForAgent(record))
	}
	s.acpRegistry.finish(job, err)
	if err != nil {
		s.logger.Warn("install ACP agent", "agent", job.agent.ID, "error", err)
		return
	}
	s.logger.Info("ACP agent installed", "agent", record.ID, "version", record.Version)
	// A running agent moves over once it has no turn. Only then is nothing
	// running from the old version, which can go.
	s.restartProviderWhenIdle(record.InstanceID, func(ctx context.Context) error {
		if err := s.providerService.ApplyPending(ctx, record.InstanceID); err != nil {
			return err
		}
		return s.acpRegistry.pruneAgent(record.ID)
	})
}

// requireACPAgentInstalled undoes a start that read the manifest before a
// removal finished. The manifest decides: the agent goes away again, and the
// removal deletes its files.
func (s *Server) requireACPAgentInstalled(id string, instanceID provider.InstanceID) error {
	_, installed, err := s.acpRegistry.installedAgent(id)
	if err != nil || installed {
		return err
	}
	if err := s.providerService.RemoveInstance(instanceID); err != nil {
		return err
	}
	return fmt.Errorf("ACP agent %q was removed", id)
}

// removeACPAgent stops a removed agent, then deletes its files. The id comes
// from a client, so only the manifest's id for it may name a directory; an
// agent that isn't installed has at most a failure or a first install to end.
func (s *Server) removeACPAgent(id string) error {
	agent, installed, err := s.acpRegistry.installedAgent(id)
	if err != nil {
		return err
	}
	if !installed {
		return s.acpRegistry.remove(id)
	}
	if s.engine.InstanceBusy(s.ctx, agent.InstanceID) {
		return &orchestration.CommandError{Code: orchestration.CodeInvalid, Message: fmt.Sprintf("%s is working on a turn. Stop it before removing the agent.", agent.Name)}
	}
	if err := s.acpRegistry.remove(agent.ID); err != nil {
		return err
	}
	s.logger.Info("ACP agent removed", "provider", agent.InstanceID)
	if err := s.providerService.RemoveInstance(agent.InstanceID); err != nil {
		return err
	}
	return s.acpRegistry.pruneAgent(agent.ID)
}

// updateCustomACPAgent saves a new definition, and moves a running agent onto
// it once its turns finish.
func (s *Server) updateCustomACPAgent(params wire.ACPCustomAgentUpdateParams) (wire.ACPRegistryAgent, error) {
	updated, err := s.acpRegistry.updateCustom(params)
	if err != nil {
		return wire.ACPRegistryAgent{}, err
	}
	spec, err := s.acpRegistry.instanceSpec(updated.ID)
	if err != nil {
		return wire.ACPRegistryAgent{}, err
	}
	if err := s.providerService.RegisterManifestInstance(spec); err != nil {
		return wire.ACPRegistryAgent{}, err
	}
	if err := s.requireACPAgentInstalled(updated.ID, updated.InstanceID); err != nil {
		return wire.ACPRegistryAgent{}, err
	}
	go s.restartProviderWhenIdle(updated.InstanceID, func(ctx context.Context) error {
		return s.providerService.ApplyPending(ctx, updated.InstanceID)
	})
	return updated, nil
}

// StartACPRegistryProvider starts an installed agent's process for cwd, or for
// no folder when cwd is empty. Installing is a job of its own, so this only ever
// launches what is on disk.
func (s *Server) StartACPRegistryProvider(ctx context.Context, registryID, cwd string) (provider.InstanceInfo, error) {
	spec, err := s.acpRegistry.instanceSpec(registryID)
	if err != nil {
		return provider.InstanceInfo{}, err
	}
	// The agent runs in cwd, so it is held to the same rule as a chat's working
	// directory.
	if cwd != "" {
		if cwd, err = s.engine.WorkspaceRoot(ctx, cwd); err != nil {
			return provider.InstanceInfo{}, err
		}
	}
	started := time.Now()
	info, err := s.providerService.StartManifestInstance(ctx, spec, cwd)
	s.logProviderStarted(spec, started, err)
	if removed := s.requireACPAgentInstalled(registryID, spec.InstanceID); removed != nil {
		return provider.InstanceInfo{}, removed
	}
	return info, err
}

func (s *Server) StartProvider(ctx context.Context, spec provider.InstanceSpec) (provider.InstanceInfo, error) {
	if spec.InstanceID != "" && spec.Name == "" && spec.Driver == "" && len(spec.Config) == 0 {
		return s.providerService.StartConfiguredInstance(ctx, spec.InstanceID, "")
	}
	if spec.InstanceID == "" {
		return provider.InstanceInfo{}, fmt.Errorf("provider start requires instanceId")
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	started := time.Now()
	info, err := s.providerService.StartInstance(ctx, spec)
	s.logProviderStarted(spec, started, err)
	return info, err
}

func (s *Server) logProviderStarted(spec provider.InstanceSpec, started time.Time, err error) {
	if err == nil {
		s.logger.Info("provider started", "provider", spec.InstanceID, "driver", spec.Driver, "duration", time.Since(started).Round(time.Millisecond))
	}
}
