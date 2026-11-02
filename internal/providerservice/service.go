// Package providerservice owns the daemon's provider instances: their specs,
// their processes and their lifecycles. It starts instances lazily and
// restarts them, stamps each process's events with its generation, and says
// when a generation's process is gone. Sessions are orchestration's.
package providerservice

import (
	"bytes"
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"maps"
	"slices"
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
	// spec is the definition it runs.
	spec provider.InstanceSpec
	// lastUsed is guarded by Service.mu.
	lastUsed time.Time
	// ended reports the generation gone once, whether it exited or was
	// replaced first.
	ended sync.Once
}

// processKey names a process of an instance. Folder is empty for a driver with
// one process for every folder, and for work that belongs to no folder.
type processKey struct {
	id     provider.InstanceID
	folder string
}

type optionsKey struct {
	id     provider.InstanceID
	handle string
}

// Service owns provider instances, keyed by InstanceID, so several instances
// of one driver coexist. An instance of a Driver.PerFolder driver is a process
// per folder in use.
type Service struct {
	drivers map[provider.DriverKind]provider.Driver
	store   store.InstanceStore
	mirror  func(provider.InstanceID) provider.Mirror
	sink    Sink
	logger  *slog.Logger

	mu        sync.Mutex
	processes map[processKey]*running
	// known is what an instance's last stopped process reported, for when none
	// runs.
	known map[provider.InstanceID]provider.InstanceInfo
	// options are the processes holding options sessions, which a draft needs
	// for as long as it stays open.
	options map[optionsKey]*running
	// specs are every configured instance's, persisted or from a manifest.
	specs map[provider.InstanceID]provider.InstanceSpec
	// manifest instances are the daemon's own definitions, never persisted
	// with their config; pending holds a manifest update for a running one
	// until a process launches on it.
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
		processes: make(map[processKey]*running), known: make(map[provider.InstanceID]provider.InstanceInfo),
		options: make(map[optionsKey]*running), specs: make(map[provider.InstanceID]provider.InstanceSpec),
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
	if len(s.aliveLocked(spec.InstanceID)) == 0 {
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

// aliveLocked is the instance's processes that haven't exited, newest first.
func (s *Service) aliveLocked(id provider.InstanceID) []*running {
	var alive []*running
	for key, process := range s.processes {
		if key.id == id && !exited(process.instance) {
			alive = append(alive, process)
		}
	}
	slices.SortFunc(alive, func(a, b *running) int { return cmp.Compare(b.generation, a.generation) })
	return alive
}

// keyLocked names the process that serves folder.
func (s *Service) keyLocked(id provider.InstanceID, folder string) processKey {
	if !s.drivers[s.specs[id].Driver].PerFolder {
		folder = ""
	}
	return processKey{id, folder}
}

// servingLocked is the running process that serves folder. Work of no folder
// takes any, the newest: starting an agent just for it would be a waste.
func (s *Service) servingLocked(id provider.InstanceID, folder string) *running {
	if folder == "" {
		if alive := s.aliveLocked(id); len(alive) > 0 {
			return alive[0]
		}
		return nil
	}
	current := s.processes[s.keyLocked(id, folder)]
	if current == nil || exited(current.instance) {
		return nil
	}
	return current
}

// Instance returns the running process that serves folder, starting one when
// there is none, and its generation. An empty folder is work of no folder.
func (s *Service) Instance(ctx context.Context, id provider.InstanceID, folder string) (provider.Instance, uint64, error) {
	process, err := s.process(ctx, id, folder)
	if err != nil {
		return nil, 0, err
	}
	return process.instance, process.generation, nil
}

func (s *Service) process(ctx context.Context, id provider.InstanceID, folder string) (*running, error) {
	s.mu.Lock()
	current := s.servingLocked(id, folder)
	if current != nil {
		current.lastUsed = time.Now()
		s.mu.Unlock()
		return current, nil
	}
	s.mu.Unlock()
	if _, err := s.StartConfiguredInstance(ctx, id, folder); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	current = s.servingLocked(id, folder)
	if current == nil {
		return nil, fmt.Errorf("provider instance %q is not running", id)
	}
	return current, nil
}

// ProcessCount is how many of the instance's processes run.
func (s *Service) ProcessCount(id provider.InstanceID) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.aliveLocked(id))
}

// Info describes a configured instance: its newest process's info when one
// runs, otherwise what its last process reported or, before any has run, what
// its driver knows.
func (s *Service) Info(id provider.InstanceID) (provider.InstanceInfo, bool) {
	s.mu.Lock()
	var current *running
	if alive := s.aliveLocked(id); len(alive) > 0 {
		current = alive[0]
	} else {
		// All that remain have exited: the newest says so.
		for key, process := range s.processes {
			if key.id == id && (current == nil || process.generation > current.generation) {
				current = process
			}
		}
	}
	known, reported := s.known[id]
	spec, configured := s.specs[id]
	s.mu.Unlock()
	switch {
	case current != nil:
		return current.instance.Info(), true
	case reported:
		known.Status, known.PID = provider.InstanceStatusConfigured, 0
		return known, true
	case !configured:
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
	for key := range s.processes {
		if _, ok := s.specs[key.id]; !ok && !slices.Contains(ids, key.id) {
			ids = append(ids, key.id)
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

// StartConfiguredInstance starts the process that serves folder of a configured
// instance, unless it is running.
func (s *Service) StartConfiguredInstance(ctx context.Context, id provider.InstanceID, folder string) (provider.InstanceInfo, error) {
	s.mu.Lock()
	spec, configured := s.specs[id]
	if pending, ok := s.pending[id]; ok {
		spec, configured = pending, true
	}
	current := s.servingLocked(id, folder)
	s.mu.Unlock()
	if !configured {
		return provider.InstanceInfo{}, errNotInstalled
	}
	if current != nil {
		return current.instance.Info(), nil
	}
	return s.start(ctx, spec, folder, false, false)
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
	if restart {
		return s.replaceProcesses(ctx, spec, !manifest)
	}
	return s.start(ctx, spec, "", false, !manifest)
}

// StartManifestInstance registers a manifest definition and starts its process
// for folder.
func (s *Service) StartManifestInstance(ctx context.Context, spec provider.InstanceSpec, folder string) (provider.InstanceInfo, error) {
	if err := s.RegisterManifestInstance(spec); err != nil {
		return provider.InstanceInfo{}, err
	}
	return s.StartConfiguredInstance(ctx, spec.InstanceID, folder)
}

// replaceProcesses replaces each of the instance's running processes with one
// of spec, or starts one when none runs.
func (s *Service) replaceProcesses(ctx context.Context, spec provider.InstanceSpec, persist bool) (provider.InstanceInfo, error) {
	folders := s.folders(spec.InstanceID, func(*running) bool { return true })
	if len(folders) == 0 {
		folders = []string{""}
	}
	return s.replaceIn(ctx, spec, folders, persist)
}

// folders are where the instance's running processes that match serve.
func (s *Service) folders(id provider.InstanceID, match func(*running) bool) []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	var folders []string
	for key, process := range s.processes {
		if key.id == id && !exited(process.instance) && match(process) {
			folders = append(folders, key.folder)
		}
	}
	return folders
}

func (s *Service) replaceIn(ctx context.Context, spec provider.InstanceSpec, folders []string, persist bool) (provider.InstanceInfo, error) {
	var info provider.InstanceInfo
	var failed error
	for _, folder := range folders {
		started, err := s.start(ctx, spec, folder, true, persist)
		if err != nil {
			failed = errors.Join(failed, err)
			continue
		}
		info = started
	}
	return info, failed
}

// RestartInstance replaces a running instance's processes with new ones of its
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
	return s.replaceProcesses(ctx, spec, false)
}

// ApplyPending moves the instance's processes onto the definition registered
// while they ran. One that started since already runs it, so a process is
// replaced by what it runs, not by whether an update is still pending.
func (s *Service) ApplyPending(ctx context.Context, id provider.InstanceID) error {
	s.mu.Lock()
	spec, ok := s.specs[id]
	if pending, has := s.pending[id]; has {
		spec, ok = pending, true
	}
	s.mu.Unlock()
	if !ok {
		return nil
	}
	folders := s.folders(id, func(process *running) bool { return !specsEqual(process.spec, spec) })
	_, err := s.replaceIn(ctx, spec, folders, false)
	return err
}

// RemoveInstance ends the instance's processes and forgets it, so it isn't
// offered or started again and doesn't come back with the daemon.
func (s *Service) RemoveInstance(id provider.InstanceID) error {
	lock := s.startLock(id)
	lock.Lock()
	defer lock.Unlock()
	s.mu.Lock()
	var ended []*running
	for key, process := range s.processes {
		if key.id == id {
			ended = append(ended, process)
			delete(s.processes, key)
		}
	}
	delete(s.specs, id)
	delete(s.manifest, id)
	delete(s.pending, id)
	delete(s.known, id)
	s.mu.Unlock()
	for _, process := range ended {
		_ = process.instance.Close()
		s.gone(id, process)
	}
	if s.store != nil {
		if err := s.store.DeleteInstance(id); err != nil {
			return fmt.Errorf("forget provider %q: %w", id, err)
		}
	}
	return nil
}

func (s *Service) start(ctx context.Context, spec provider.InstanceSpec, folder string, restart, persist bool) (provider.InstanceInfo, error) {
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
	if !driver.PerFolder {
		folder = ""
	}
	key := processKey{spec.InstanceID, folder}
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
	current := s.processes[key]
	if current != nil && !exited(current.instance) && !restart {
		s.mu.Unlock()
		if !specsEqual(current.spec, spec) {
			return provider.InstanceInfo{}, fmt.Errorf("provider instance %q runs with another configuration; restart it to change it", spec.InstanceID)
		}
		return current.instance.Info(), nil
	}
	s.generation++
	launched := &running{generation: s.generation}
	s.mu.Unlock()

	id := spec.InstanceID
	host := provider.Host{Folder: folder, Emit: func(event provider.Event) {
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
	// A caller's deadline wins; otherwise a lazy start gets a bounded one.
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
	replaced := s.processes[key]
	launched.instance = instance
	launched.spec = cloneSpec(spec)
	launched.lastUsed = time.Now()
	s.processes[key] = launched
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
	s.mu.Lock()
	maps.DeleteFunc(s.options, func(_ optionsKey, holder *running) bool { return holder == process })
	s.mu.Unlock()
	process.ended.Do(func() {
		if s.sink.Gone != nil {
			s.sink.Gone(id, process.generation)
		}
	})
}

// StopIdle ends the processes of per-folder drivers unused since before that
// have no work, so an agent's cost follows the folders in use. A chat's next
// message resumes its session on a new process. busy says whether a turn runs
// on a process.
func (s *Service) StopIdle(before time.Time, busy func(provider.InstanceID, uint64) bool) {
	s.mu.Lock()
	idle := maps.Clone(s.processes)
	maps.DeleteFunc(idle, func(key processKey, process *running) bool {
		return !s.drivers[s.specs[key.id].Driver].PerFolder || !process.lastUsed.Before(before)
	})
	s.mu.Unlock()
	for key, process := range idle {
		// Outside mu: busy asks the engine, which asks this service.
		working := busy(key.id, process.generation)
		s.mu.Lock()
		if working || slices.Contains(slices.Collect(maps.Values(s.options)), process) {
			// A turn that just ended counts as use, or it would end its process.
			process.lastUsed = time.Now()
			s.mu.Unlock()
			continue
		}
		if s.processes[key] != process || !process.lastUsed.Before(before) {
			s.mu.Unlock()
			continue
		}
		s.known[key.id] = process.instance.Info()
		delete(s.processes, key)
		s.mu.Unlock()
		_ = process.instance.Close()
		s.gone(key.id, process)
	}
}

// sessionCallTimeout bounds calls on behalf of a client, so a hung agent
// can't pin the connection's calls.
const sessionCallTimeout = 60 * time.Second

func (s *Service) Authenticate(ctx context.Context, id provider.InstanceID, input provider.AuthenticateInput) (provider.AuthenticationResult, error) {
	instance, _, err := s.Instance(ctx, id, "")
	if err != nil {
		return provider.AuthenticationResult{}, err
	}
	return instance.Authenticate(ctx, input)
}

func (s *Service) Logout(ctx context.Context, id provider.InstanceID) (provider.InstanceInfo, error) {
	instance, _, err := s.Instance(ctx, id, "")
	if err != nil {
		return provider.InstanceInfo{}, err
	}
	return instance.Logout(ctx)
}

// Sessions lists an instance's native sessions in cwd, or in every folder when
// cwd is empty. Every process is asked: an agent may know only the sessions of
// its own process or folder.
func (s *Service) Sessions(ctx context.Context, id provider.InstanceID, cwd string) ([]provider.SessionSummary, error) {
	if _, err := s.process(ctx, id, ""); err != nil {
		return nil, err
	}
	s.mu.Lock()
	alive := s.aliveLocked(id)
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, sessionCallTimeout)
	defer cancel()
	type session struct{ id, cwd string }
	seen := make(map[session]bool)
	var sessions []provider.SessionSummary
	var failed error
	listed := false
	for _, process := range alive {
		found, err := process.instance.Sessions(ctx, cwd)
		if err != nil {
			failed = err
			continue
		}
		listed = true
		for _, summary := range found {
			// By folder too: an agent may reuse ids across its processes.
			if key := (session{summary.SessionID, summary.Cwd}); !seen[key] {
				seen[key] = true
				sessions = append(sessions, summary)
			}
		}
	}
	if !listed {
		return nil, failed
	}
	return sessions, nil
}

// DeleteSession deletes a native session from its provider.
func (s *Service) DeleteSession(ctx context.Context, id provider.InstanceID, session string) error {
	instance, _, err := s.Instance(ctx, id, "")
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, sessionCallTimeout)
	defer cancel()
	// The session may be live on the process of its folder.
	s.mu.Lock()
	alive := s.aliveLocked(id)
	s.mu.Unlock()
	for _, process := range alive {
		if process.instance != instance {
			if err := process.instance.Release(ctx, session); err != nil {
				return err
			}
		}
	}
	return instance.Delete(ctx, session)
}

func (s *Service) CompleteCommand(ctx context.Context, id provider.InstanceID, input provider.CompleteCommandInput) ([]provider.CommandCompletion, error) {
	s.mu.Lock()
	current := s.processes[s.keyLocked(id, input.Cwd)]
	s.mu.Unlock()
	if current == nil {
		return nil, fmt.Errorf("provider instance %q is not running", id)
	}
	return current.instance.CompleteCommand(ctx, input)
}

func (s *Service) OpenOptions(ctx context.Context, id provider.InstanceID, cwd string, callbacks provider.OptionsSessionCallbacks) (provider.OptionsSession, error) {
	process, err := s.process(ctx, id, cwd)
	if err != nil {
		return provider.OptionsSession{}, err
	}
	opened, err := process.instance.OpenOptions(ctx, cwd, callbacks)
	if err != nil {
		return provider.OptionsSession{}, err
	}
	s.mu.Lock()
	s.options[optionsKey{id, opened.Handle}] = process
	s.mu.Unlock()
	return opened, nil
}

func (s *Service) SetOption(ctx context.Context, id provider.InstanceID, handle, option string, value any) ([]provider.ConfigOption, error) {
	s.mu.Lock()
	process := s.options[optionsKey{id, handle}]
	s.mu.Unlock()
	if process == nil {
		return nil, fmt.Errorf("provider instance %q has no options session %q", id, handle)
	}
	return process.instance.SetOption(ctx, handle, option, value)
}

func (s *Service) CloseOptions(ctx context.Context, id provider.InstanceID, handle string) error {
	s.mu.Lock()
	process := s.options[optionsKey{id, handle}]
	delete(s.options, optionsKey{id, handle})
	s.mu.Unlock()
	if process == nil {
		return nil
	}
	return process.instance.CloseOptions(ctx, handle)
}

// Close ends every instance's process.
func (s *Service) Close() {
	s.mu.Lock()
	s.closing = true
	instances := slices.Collect(maps.Values(s.processes))
	s.processes = make(map[processKey]*running)
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
