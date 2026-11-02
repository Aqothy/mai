// Package providerservice owns the daemon's provider instances: their specs,
// their processes and their lifecycles. It starts instances lazily and
// restarts them, stamps each process's events with its generation, and says
// when a generation's process is gone. Sessions are orchestration's.
package providerservice

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/store"
)

// Sink receives instances' events and the end of their processes.
type Sink struct {
	// Event is one event of the process of generation.
	Event func(instance provider.InstanceID, generation uint64, event provider.Event)
	// Gone: the process of generation exited or was replaced.
	Gone func(instance provider.InstanceID, generation uint64)
}

type running struct {
	instance   provider.Instance
	generation uint64
	// ended reports the generation gone once, whether it exited or was
	// replaced first.
	ended sync.Once
}

// Service owns provider instances, keyed by InstanceID, so several instances
// of one driver coexist.
type Service struct {
	drivers map[provider.DriverKind]provider.Driver
	store   store.InstanceStore
	mirror  func(provider.InstanceID) provider.Mirror
	sink    Sink
	logger  *slog.Logger

	mu        sync.Mutex
	instances map[provider.InstanceID]*running
	// specs are every configured instance's, persisted or from a manifest.
	specs map[provider.InstanceID]provider.InstanceSpec
	// manifest instances are the daemon's own definitions, never persisted
	// with their config; pending holds a manifest update for a running one
	// until its next launch.
	manifest   map[provider.InstanceID]bool
	pending    map[provider.InstanceID]provider.InstanceSpec
	generation uint64
	// startLocks serialize an instance's launches.
	startLocks map[provider.InstanceID]*sync.Mutex
	closing    bool
}

// errNotInstalled reaches the user when a chat's agent has been removed.
var errNotInstalled = errors.New("not installed")

// New makes the service. mirror gives each instance's adapter its native
// mirror.
func New(drivers map[provider.DriverKind]provider.Driver, instances store.InstanceStore, mirror func(provider.InstanceID) provider.Mirror, sink Sink, logger *slog.Logger) *Service {
	if logger == nil {
		logger = slog.Default()
	}
	s := &Service{
		drivers: drivers, store: instances, mirror: mirror, sink: sink, logger: logger.With("component", "providerservice"),
		instances: make(map[provider.InstanceID]*running), specs: make(map[provider.InstanceID]provider.InstanceSpec),
		manifest: make(map[provider.InstanceID]bool), pending: make(map[provider.InstanceID]provider.InstanceSpec),
		startLocks: make(map[provider.InstanceID]*sync.Mutex),
	}
	if instances != nil {
		specs, err := instances.LoadInstances()
		if err != nil {
			s.logger.Warn("load persisted instance specs", "error", err)
		}
		for _, spec := range specs {
			s.specs[spec.InstanceID] = cloneSpec(spec)
		}
	}
	return s
}

// RegisterManifestInstance makes a daemon-owned definition available to
// start. Its config stays in memory.
func (s *Service) RegisterManifestInstance(spec provider.InstanceSpec) error {
	if spec.InstanceID == "" || spec.Driver == "" {
		return fmt.Errorf("a manifest provider needs an instance id and a driver")
	}
	if spec.Name == "" {
		spec.Name = string(spec.InstanceID)
	}
	lock := s.startLock(spec.InstanceID)
	lock.Lock()
	defer lock.Unlock()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.manifest[spec.InstanceID] = true
	if current := s.instances[spec.InstanceID]; current == nil || exited(current.instance) {
		s.specs[spec.InstanceID] = cloneSpec(spec)
		delete(s.pending, spec.InstanceID)
	} else {
		s.pending[spec.InstanceID] = cloneSpec(spec)
	}
	return nil
}

func exited(instance provider.Instance) bool {
	return instance.Info().Status == provider.InstanceStatusExited
}

// Instance returns the running instance, starting its spec when it isn't.
func (s *Service) Instance(ctx context.Context, id provider.InstanceID) (provider.Instance, uint64, error) {
	s.mu.Lock()
	current := s.instances[id]
	s.mu.Unlock()
	if current != nil && !exited(current.instance) {
		return current.instance, current.generation, nil
	}
	if _, err := s.StartConfiguredInstance(ctx, id); err != nil {
		return nil, 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	current = s.instances[id]
	if current == nil {
		return nil, 0, fmt.Errorf("provider instance %q is not running", id)
	}
	return current.instance, current.generation, nil
}

// Info describes a configured instance: its process's info when it runs,
// otherwise what its driver knows before it starts.
func (s *Service) Info(id provider.InstanceID) (provider.InstanceInfo, bool) {
	s.mu.Lock()
	current := s.instances[id]
	spec, configured := s.specs[id]
	s.mu.Unlock()
	if current != nil {
		return current.instance.Info(), true
	}
	if !configured {
		return provider.InstanceInfo{}, false
	}
	return s.staticInfo(spec), true
}

func (s *Service) staticInfo(spec provider.InstanceSpec) provider.InstanceInfo {
	info := provider.InstanceInfo{InstanceID: spec.InstanceID, Name: spec.Name, Driver: spec.Driver, Status: provider.InstanceStatusConfigured, Auth: provider.Auth{Status: provider.AuthStatusUnknown}}
	if driver, ok := s.drivers[spec.Driver]; ok && driver.Static != nil {
		static := driver.Static(spec)
		info.Capabilities, info.Access = static.Capabilities, static.Access
	}
	info.InstanceID, info.Name, info.Driver, info.Status = spec.InstanceID, spec.Name, spec.Driver, provider.InstanceStatusConfigured
	return info
}

// ListInstances is every configured instance, running or not.
func (s *Service) ListInstances() []provider.InstanceInfo {
	s.mu.Lock()
	ids := make([]provider.InstanceID, 0, len(s.specs))
	for id := range s.specs {
		ids = append(ids, id)
	}
	for id := range s.instances {
		if _, ok := s.specs[id]; !ok {
			ids = append(ids, id)
		}
	}
	s.mu.Unlock()
	infos := make([]provider.InstanceInfo, 0, len(ids))
	for _, id := range ids {
		if info, ok := s.Info(id); ok {
			infos = append(infos, info)
		}
	}
	return infos
}

func (s *Service) startLock(id provider.InstanceID) *sync.Mutex {
	s.mu.Lock()
	defer s.mu.Unlock()
	lock := s.startLocks[id]
	if lock == nil {
		lock = &sync.Mutex{}
		s.startLocks[id] = lock
	}
	return lock
}

// StartConfiguredInstance starts a configured instance that isn't running.
func (s *Service) StartConfiguredInstance(ctx context.Context, id provider.InstanceID) (provider.InstanceInfo, error) {
	s.mu.Lock()
	spec, configured := s.specs[id]
	if pending, ok := s.pending[id]; ok {
		spec, configured = pending, true
	}
	current := s.instances[id]
	s.mu.Unlock()
	if !configured {
		return provider.InstanceInfo{}, errNotInstalled
	}
	if current != nil && !exited(current.instance) {
		return current.instance.Info(), nil
	}
	return s.start(ctx, spec, false, false)
}

// StartInstance starts (or with restart replaces) an instance of spec. A
// user's spec persists; a manifest's config doesn't.
func (s *Service) StartInstance(ctx context.Context, spec provider.InstanceSpec, restart bool) (provider.InstanceInfo, error) {
	s.mu.Lock()
	manifest := s.manifest[spec.InstanceID]
	s.mu.Unlock()
	if manifest {
		reference := cloneSpec(spec)
		reference.Config = nil
		if s.store != nil {
			if err := s.store.SaveInstance(reference); err != nil {
				return provider.InstanceInfo{}, fmt.Errorf("persist manifest provider %q: %w", spec.InstanceID, err)
			}
		}
	}
	return s.start(ctx, spec, restart, !manifest)
}

// StartManifestInstance registers a manifest definition and starts it.
func (s *Service) StartManifestInstance(ctx context.Context, spec provider.InstanceSpec, restart bool) (provider.InstanceInfo, error) {
	if err := s.RegisterManifestInstance(spec); err != nil {
		return provider.InstanceInfo{}, err
	}
	if !restart {
		return s.StartConfiguredInstance(ctx, spec.InstanceID)
	}
	return s.StartInstance(ctx, spec, true)
}

// RestartInstance replaces a running instance with a new process of its
// spec, e.g. so an agent picks up a sign-in.
func (s *Service) RestartInstance(ctx context.Context, id provider.InstanceID) (provider.InstanceInfo, error) {
	s.mu.Lock()
	spec, ok := s.specs[id]
	if pending, has := s.pending[id]; has {
		spec, ok = pending, true
	}
	s.mu.Unlock()
	if !ok {
		return provider.InstanceInfo{}, fmt.Errorf("provider instance %q is not configured", id)
	}
	return s.start(ctx, spec, true, false)
}

// ApplyPending moves a running instance onto the definition registered while
// it ran, if there is one.
func (s *Service) ApplyPending(ctx context.Context, id provider.InstanceID) error {
	s.mu.Lock()
	spec, pending := s.pending[id]
	s.mu.Unlock()
	if !pending {
		return nil
	}
	_, err := s.start(ctx, spec, true, false)
	return err
}

// RemoveInstance ends the instance's process and forgets it, so it isn't
// offered or started again and doesn't come back with the daemon.
func (s *Service) RemoveInstance(id provider.InstanceID) error {
	lock := s.startLock(id)
	lock.Lock()
	defer lock.Unlock()
	s.mu.Lock()
	current := s.instances[id]
	delete(s.instances, id)
	delete(s.specs, id)
	delete(s.manifest, id)
	delete(s.pending, id)
	s.mu.Unlock()
	if current != nil {
		_ = current.instance.Close()
		s.gone(id, current)
	}
	if s.store != nil {
		if err := s.store.DeleteInstance(id); err != nil {
			return fmt.Errorf("forget provider %q: %w", id, err)
		}
	}
	return nil
}

func (s *Service) start(ctx context.Context, spec provider.InstanceSpec, restart, persist bool) (provider.InstanceInfo, error) {
	if spec.InstanceID == "" || spec.Driver == "" {
		return provider.InstanceInfo{}, fmt.Errorf("a provider needs an instance id and a driver")
	}
	if spec.Name == "" {
		spec.Name = string(spec.InstanceID)
	}
	driver, ok := s.drivers[spec.Driver]
	if !ok {
		return provider.InstanceInfo{}, fmt.Errorf("unsupported provider driver %q", spec.Driver)
	}
	lock := s.startLock(spec.InstanceID)
	lock.Lock()
	defer lock.Unlock()

	s.mu.Lock()
	if s.closing {
		s.mu.Unlock()
		return provider.InstanceInfo{}, fmt.Errorf("the provider service is closed")
	}
	// A caller that read a configured spec before taking the lock may have
	// raced its removal. Only persist brings a new instance into being.
	if _, configured := s.specs[spec.InstanceID]; !configured && !persist {
		s.mu.Unlock()
		return provider.InstanceInfo{}, errNotInstalled
	}
	current := s.instances[spec.InstanceID]
	if current != nil && !exited(current.instance) && !restart {
		existing := s.specs[spec.InstanceID]
		s.mu.Unlock()
		if !specsEqual(existing, spec) {
			return provider.InstanceInfo{}, fmt.Errorf("provider instance %q runs with another configuration; restart it to change it", spec.InstanceID)
		}
		return current.instance.Info(), nil
	}
	s.generation++
	launched := &running{generation: s.generation}
	s.mu.Unlock()

	id := spec.InstanceID
	host := provider.Host{Emit: func(event provider.Event) {
		if changed, ok := event.Body.(provider.InstanceChanged); ok && changed.Info.Status == provider.InstanceStatusExited {
			s.gone(id, launched)
		}
		if s.sink.Event != nil {
			s.sink.Event(id, launched.generation, event)
		}
	}}
	if s.mirror != nil {
		host.Mirror = s.mirror(id)
	}
	// A caller's deadline wins (npm-launched agents may install first);
	// otherwise a lazy start gets a bounded one.
	openCtx, cancel := ctx, func() {}
	if _, has := ctx.Deadline(); !has {
		openCtx, cancel = context.WithTimeout(ctx, 30*time.Second)
	}
	defer cancel()
	instance, err := driver.Open(openCtx, cloneSpec(spec), host)
	if err != nil {
		return provider.InstanceInfo{}, err
	}
	s.mu.Lock()
	if s.closing {
		s.mu.Unlock()
		_ = instance.Close()
		return provider.InstanceInfo{}, fmt.Errorf("the provider service is closed")
	}
	replaced := s.instances[id]
	launched.instance = instance
	s.instances[id] = launched
	s.specs[id] = cloneSpec(spec)
	if pending, ok := s.pending[id]; ok && specsEqual(pending, spec) {
		delete(s.pending, id)
	}
	s.mu.Unlock()
	if replaced != nil {
		_ = replaced.instance.Close()
		s.gone(id, replaced)
	}
	if persist && s.store != nil {
		if err := s.store.SaveInstance(spec); err != nil {
			s.logger.Warn("persist provider instance", "instance", id, "error", err)
		}
	}
	return instance.Info(), nil
}

func (s *Service) gone(id provider.InstanceID, process *running) {
	process.ended.Do(func() {
		if s.sink.Gone != nil {
			s.sink.Gone(id, process.generation)
		}
	})
}

// running is the instance's process, or an error saying it isn't running.
func (s *Service) runningInstance(id provider.InstanceID) (provider.Instance, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	current := s.instances[id]
	if current == nil {
		return nil, fmt.Errorf("provider instance %q is not running", id)
	}
	return current.instance, nil
}

// sessionCallTimeout bounds calls on behalf of a client, so a hung agent
// can't pin the connection's calls.
const sessionCallTimeout = 60 * time.Second

func (s *Service) Authenticate(ctx context.Context, id provider.InstanceID, input provider.AuthenticateInput) (provider.AuthenticationResult, error) {
	instance, _, err := s.Instance(ctx, id)
	if err != nil {
		return provider.AuthenticationResult{}, err
	}
	return instance.Authenticate(ctx, input)
}

func (s *Service) Logout(ctx context.Context, id provider.InstanceID) (provider.InstanceInfo, error) {
	instance, _, err := s.Instance(ctx, id)
	if err != nil {
		return provider.InstanceInfo{}, err
	}
	return instance.Logout(ctx)
}

// Sessions lists an instance's native sessions in cwd.
func (s *Service) Sessions(ctx context.Context, id provider.InstanceID, cwd string) ([]provider.SessionSummary, error) {
	instance, _, err := s.Instance(ctx, id)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, sessionCallTimeout)
	defer cancel()
	return instance.Sessions(ctx, cwd)
}

// DeleteSession deletes a native session from its provider.
func (s *Service) DeleteSession(ctx context.Context, id provider.InstanceID, session string) error {
	instance, _, err := s.Instance(ctx, id)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, sessionCallTimeout)
	defer cancel()
	return instance.Delete(ctx, session)
}

func (s *Service) CompleteCommand(ctx context.Context, id provider.InstanceID, input provider.CompleteCommandInput) ([]provider.CommandCompletion, error) {
	instance, err := s.runningInstance(id)
	if err != nil {
		return nil, err
	}
	return instance.CompleteCommand(ctx, input)
}

func (s *Service) OpenOptions(ctx context.Context, id provider.InstanceID, cwd string, callbacks provider.OptionsSessionCallbacks) (provider.OptionsSession, error) {
	instance, _, err := s.Instance(ctx, id)
	if err != nil {
		return provider.OptionsSession{}, err
	}
	return instance.OpenOptions(ctx, cwd, callbacks)
}

func (s *Service) SetOption(ctx context.Context, id provider.InstanceID, handle, option string, value any) ([]provider.ConfigOption, error) {
	instance, err := s.runningInstance(id)
	if err != nil {
		return nil, err
	}
	return instance.SetOption(ctx, handle, option, value)
}

func (s *Service) CloseOptions(ctx context.Context, id provider.InstanceID, handle string) error {
	instance, err := s.runningInstance(id)
	if err != nil {
		return nil
	}
	return instance.CloseOptions(ctx, handle)
}

// Close ends every instance's process.
func (s *Service) Close() {
	s.mu.Lock()
	s.closing = true
	instances := make([]*running, 0, len(s.instances))
	for _, current := range s.instances {
		instances = append(instances, current)
	}
	s.instances = make(map[provider.InstanceID]*running)
	s.mu.Unlock()
	var closed sync.WaitGroup
	for _, current := range instances {
		closed.Go(func() { _ = current.instance.Close() })
	}
	closed.Wait()
}

func cloneSpec(spec provider.InstanceSpec) provider.InstanceSpec {
	spec.Config = append(json.RawMessage(nil), spec.Config...)
	return spec
}

func specsEqual(a, b provider.InstanceSpec) bool {
	return a.InstanceID == b.InstanceID && a.Name == b.Name && a.Driver == b.Driver && jsonEqual(a.Config, b.Config)
}

func jsonEqual(a, b json.RawMessage) bool {
	if len(a) == 0 || len(b) == 0 {
		return len(a) == len(b)
	}
	var av, bv any
	if json.Unmarshal(a, &av) != nil || json.Unmarshal(b, &bv) != nil {
		return bytes.Equal(a, b)
	}
	aJSON, _ := json.Marshal(av)
	bJSON, _ := json.Marshal(bv)
	return bytes.Equal(aJSON, bJSON)
}
