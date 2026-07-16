// Package providerservice owns provider runtime instances for the daemon.
//
// It is the daemon's seam to provider adapters: callers use provider-neutral,
// thread-scoped requests and never hold adapter-specific connection/session
// handles.
package providerservice

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/store"
)

// ProviderInstance is the provider adapter seam used by the Service. The
// interface is thread-scoped, not native-session-scoped: adapters own their
// protocol/session identifiers and expose only provider-neutral operations.
type ProviderInstance interface {
	Info() provider.InstanceInfo
	Close() error
	StartSession(ctx context.Context, input provider.StartSessionInput) (provider.StartSessionResult, error)
	// SendTurn dispatches a turn. It is asynchronous: the turn lifecycle
	// (turn.started/turn.completed) and all content are reported through runtime
	// events, so SendTurn returns once the turn is accepted/dispatched.
	SendTurn(ctx context.Context, input provider.SendTurnInput) error
	InterruptTurn(ctx context.Context, input provider.InterruptTurnInput) error
	SetConfigOption(ctx context.Context, input provider.SetConfigOptionInput) error
	RespondToRequest(ctx context.Context, input provider.RespondToRequestInput) error
	StopSession(ctx context.Context, input provider.StopSessionInput) error
}

type Authenticator interface {
	Authenticate(ctx context.Context, methodID string) (provider.InstanceInfo, error)
	Logout(ctx context.Context) (provider.InstanceInfo, error)
}

// SessionManager is an optional capability for adapters whose providers support
// session management (ACP session/list, /delete, /close). The Service
// type-asserts it; providers that don't implement it report "not supported".
type SessionManager interface {
	ListSessions(ctx context.Context, cwd string) ([]provider.SessionSummary, error)
	DeleteSession(ctx context.Context, sessionID string) error
	CloseSession(ctx context.Context, sessionID string) error
}

// InstanceFactory opens one concrete adapter instance. The daemon owns driver
// selection; providerservice supplies the per-instance event sink.
type InstanceFactory func(ctx context.Context, spec provider.InstanceSpec, emit provider.RuntimeEventListener) (ProviderInstance, error)

const runtimeEventBuffer = 256

type runtimeEventEnvelope struct {
	event      provider.RuntimeEvent
	instanceID provider.InstanceID
	generation uint64
}

type threadRoute struct {
	InstanceID        provider.InstanceID
	Generation        uint64
	ProviderSessionID string
	ResumeCursor      json.RawMessage
	StartInput        provider.StartSessionInput
}

// Service owns provider instances, thread routes, event generation fencing, and
// the runtime-event fan-in hub. Instances are keyed by InstanceID, so multiple
// instances of the same driver can coexist.
type Service struct {
	mu        sync.Mutex
	instances map[provider.InstanceID]ProviderInstance // live processes only
	// instanceSpecs includes persisted specs for instances that are still cold.
	instanceSpecs map[provider.InstanceID]provider.InstanceSpec
	threadRoutes  map[string]threadRoute
	startLocks    map[provider.InstanceID]*sync.RWMutex
	openInstance  InstanceFactory

	activeEventGenerations map[provider.InstanceID]uint64
	nextEventGeneration    uint64

	routeStore     store.RouteStore
	storeMu        sync.Mutex
	routeBindMu    sync.Mutex
	dirtyInstances map[provider.InstanceID]struct{}
	dirtyRoutes    map[string]struct{}

	// ingress is the fan-in hub: every instance's runtime events funnel here and
	// runHub forwards active-generation events to the single events channel
	// consumed by ProviderRuntimeIngestion. This keeps providerservice free of
	// any orchestration dependency.
	ingress chan runtimeEventEnvelope
	events  chan provider.RuntimeEvent

	closeOnce sync.Once
	closing   bool // guarded by mu; fences instance creation against Close
	closed    chan struct{}
	wg        sync.WaitGroup
}

// Option configures a Service.
type Option func(*Service)

// WithRouteStore enables persistence for routes and instance specs.
func WithRouteStore(routeStore store.RouteStore) Option {
	return func(s *Service) { s.routeStore = routeStore }
}

func New(openInstance InstanceFactory, opts ...Option) *Service {
	s := &Service{
		instances:              make(map[provider.InstanceID]ProviderInstance),
		instanceSpecs:          make(map[provider.InstanceID]provider.InstanceSpec),
		threadRoutes:           make(map[string]threadRoute),
		startLocks:             make(map[provider.InstanceID]*sync.RWMutex),
		openInstance:           openInstance,
		activeEventGenerations: make(map[provider.InstanceID]uint64),
		ingress:                make(chan runtimeEventEnvelope, runtimeEventBuffer),
		events:                 make(chan provider.RuntimeEvent, runtimeEventBuffer),
		closed:                 make(chan struct{}),
		dirtyInstances:         make(map[provider.InstanceID]struct{}),
		dirtyRoutes:            make(map[string]struct{}),
	}
	for _, opt := range opts {
		opt(s)
	}
	if s.routeStore != nil {
		s.restorePersistedState()
	}

	s.wg.Add(1)
	go s.runHub()
	return s
}

// restorePersistedState rehydrates thread routes and instance specs from the
// route store. It runs inside New, before the service is shared with any other
// goroutine, so the map writes need no locking. Instances stay cold — they
// respawn lazily on first use of a routed thread (ensureInstanceStarted). All
// restored routes share one generation that is never assigned to an instance,
// so withThreadInstance's stale-generation recovery re-runs StartSession with
// the stored start input and resume cursor before the first operation on the
// thread.
func (s *Service) restorePersistedState() {
	specs, err := s.routeStore.LoadInstances()
	if err != nil {
		log.Printf("providerservice: load persisted instance specs: %v", err)
	}
	for _, spec := range specs {
		s.instanceSpecs[spec.InstanceID] = cloneInstanceSpec(spec)
	}

	routes, err := s.routeStore.LoadRoutes()
	if err != nil {
		log.Printf("providerservice: load persisted thread routes: %v; route persistence disabled for this run", err)
		// A failed read is not proof that no routes exist. Freeze the durable
		// route table so live in-memory sessions cannot overwrite resumable state
		// that may become readable again on the next boot.
		s.routeStore = nil
		return
	}
	if len(routes) == 0 {
		return
	}
	restoredGeneration := s.allocateEventGeneration()
	for threadID, record := range routes {
		s.threadRoutes[threadID] = threadRoute{
			InstanceID:        record.InstanceID,
			Generation:        restoredGeneration,
			ProviderSessionID: record.ProviderSessionID,
			ResumeCursor:      append(json.RawMessage(nil), record.ResumeCursor...),
			StartInput:        persistentStartSessionInput(record.StartInput),
		}
	}
}

// ensureInstanceStarted lazily respawns a persisted provider instance on its
// first use after a daemon restart. A missing restored spec is not an error;
// the instance lookup downstream reports "not initialized" as before.
func (s *Service) ensureInstanceStarted(ctx context.Context, instanceID provider.InstanceID) error {
	s.mu.Lock()
	_, live := s.instances[instanceID]
	spec, restorable := s.instanceSpecs[instanceID]
	s.mu.Unlock()
	if live || !restorable {
		return nil
	}
	_, err := s.StartInstance(ctx, spec, false)
	return err
}

func (s *Service) persistThreadRoute(threadID string) {
	if s.routeStore == nil || threadID == "" {
		return
	}
	s.storeMu.Lock()
	defer s.storeMu.Unlock()
	s.dirtyRoutes[threadID] = struct{}{}
	s.flushPersistenceLocked()
}

func (s *Service) persistInstanceSpec(instanceID provider.InstanceID) {
	if s.routeStore == nil || instanceID == "" {
		return
	}
	s.storeMu.Lock()
	defer s.storeMu.Unlock()
	s.dirtyInstances[instanceID] = struct{}{}
	s.flushPersistenceLocked()
}

func (s *Service) flushPersistenceLocked() {
	for instanceID := range s.dirtyInstances {
		s.mu.Lock()
		spec, ok := s.instanceSpecs[instanceID]
		spec = cloneInstanceSpec(spec)
		s.mu.Unlock()
		if !ok {
			delete(s.dirtyInstances, instanceID)
			continue
		}
		if err := s.routeStore.SaveInstance(spec); err != nil {
			log.Printf("providerservice: persist instance %q spec: %v (will retry)", instanceID, err)
			continue
		}
		delete(s.dirtyInstances, instanceID)
	}

	for threadID := range s.dirtyRoutes {
		if s.persistThreadRouteLocked(threadID) {
			delete(s.dirtyRoutes, threadID)
		}
	}
}

func (s *Service) persistThreadRouteLocked(threadID string) bool {
	s.mu.Lock()
	route, ok := s.threadRoutes[threadID]
	if ok {
		route.ResumeCursor = append(json.RawMessage(nil), route.ResumeCursor...)
		route.StartInput = cloneStartSessionInput(route.StartInput)
	}
	s.mu.Unlock()

	if !ok {
		if err := s.routeStore.DeleteRoute(threadID); err != nil {
			log.Printf("providerservice: persist route for thread %q: %v (will retry)", threadID, err)
			return false
		}
		return true
	}
	if _, dirty := s.dirtyInstances[route.InstanceID]; dirty {
		return false
	}
	if err := s.routeStore.SaveRoute(threadID, store.RouteRecord{
		InstanceID:        route.InstanceID,
		ProviderSessionID: route.ProviderSessionID,
		ResumeCursor:      route.ResumeCursor,
		StartInput:        route.StartInput,
	}); err != nil {
		log.Printf("providerservice: persist route for thread %q: %v (will retry)", threadID, err)
		return false
	}
	return true
}

func (s *Service) Close() {
	s.closeOnce.Do(func() {
		// Mark the service first so a factory already in flight cannot install an
		// untracked process after the registry is drained.
		s.mu.Lock()
		s.closing = true
		s.mu.Unlock()

		close(s.closed)
		s.wg.Wait()
		// runHub has exited, so nothing sends to events anymore; closing it tells
		// the consumer (ingestion) the stream is over.
		close(s.events)

		if s.routeStore != nil {
			s.storeMu.Lock()
			s.flushPersistenceLocked()
			s.storeMu.Unlock()
		}

		s.mu.Lock()
		instances := make([]ProviderInstance, 0, len(s.instances))
		for _, instance := range s.instances {
			instances = append(instances, instance)
		}
		s.instances = make(map[provider.InstanceID]ProviderInstance)
		s.instanceSpecs = make(map[provider.InstanceID]provider.InstanceSpec)
		s.threadRoutes = make(map[string]threadRoute)
		s.activeEventGenerations = make(map[provider.InstanceID]uint64)
		s.mu.Unlock()

		for _, instance := range instances {
			_ = instance.Close()
		}
	})
}

// Events returns the generation-filtered runtime stream in hub order. Close
// closes it.
func (s *Service) Events() <-chan provider.RuntimeEvent {
	return s.events
}

// publish is the only sink the per-instance adapter listeners call. It blocks
// only until the buffered hub accepts the event (or the service closes), giving
// natural backpressure without dropping events.
func (s *Service) publish(envelope runtimeEventEnvelope) {
	select {
	case <-s.closed:
	case s.ingress <- envelope:
	}
}

func (s *Service) runHub() {
	defer s.wg.Done()
	for {
		select {
		case <-s.closed:
			return
		case envelope := <-s.ingress:
			if !s.eventGenerationAdmissible(envelope) {
				continue
			}
			select {
			case <-s.closed:
				return
			case s.events <- envelope.event:
			}
		}
	}
}

func (s *Service) allocateEventGeneration() uint64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.nextEventGeneration++
	return s.nextEventGeneration
}

func (s *Service) eventGenerationAdmissible(envelope runtimeEventEnvelope) bool {
	if envelope.instanceID == "" || envelope.generation == 0 {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.activeEventGenerations[envelope.instanceID] == envelope.generation {
		return true
	}
	// A replaced (dying) process may still settle work it started: terminal,
	// turn-scoped events are admitted because dropping one before the replacement
	// session binds would strand the old turn. The session binding carries its
	// process generation, so ingestion drops the event after a replacement has
	// actually rebound the thread. All non-terminal events from stale generations
	// stay dropped here.
	return terminalEventFromReplacedGeneration(envelope.event)
}

func terminalEventFromReplacedGeneration(event provider.RuntimeEvent) bool {
	if event.ThreadID == "" || event.TurnID == "" {
		return false
	}
	return event.Type == provider.RuntimeEventTurnCompleted || event.Type == provider.RuntimeEventRuntimeError
}

func (s *Service) startLock(instanceID provider.InstanceID) *sync.RWMutex {
	s.mu.Lock()
	defer s.mu.Unlock()
	lock := s.startLocks[instanceID]
	if lock == nil {
		lock = &sync.RWMutex{}
		s.startLocks[instanceID] = lock
	}
	return lock
}

func (s *Service) StartInstance(ctx context.Context, spec provider.InstanceSpec, restart bool) (provider.InstanceInfo, error) {
	action := "provider start"
	if restart {
		action = "provider restart"
	}
	if spec.InstanceID == "" {
		return provider.InstanceInfo{}, fmt.Errorf("%s requires a provider instance id", action)
	}
	if spec.Name == "" {
		spec.Name = string(spec.InstanceID)
	}
	if spec.Driver == "" {
		return provider.InstanceInfo{}, fmt.Errorf("%s requires a provider driver", action)
	}
	if s.openInstance == nil {
		return provider.InstanceInfo{}, fmt.Errorf("%s: no adapter factory configured", action)
	}
	spec = cloneInstanceSpec(spec)

	lock := s.startLock(spec.InstanceID)
	lock.Lock()
	defer lock.Unlock()

	s.mu.Lock()
	if s.closing {
		s.mu.Unlock()
		return provider.InstanceInfo{}, fmt.Errorf("%s: provider service is closed", action)
	}
	if existing := s.instances[spec.InstanceID]; existing != nil {
		info := existing.Info()
		if info.Status != provider.InstanceStatusExited {
			if !restart {
				existingSpec := s.instanceSpecs[spec.InstanceID]
				if existingSpec.Driver != spec.Driver {
					s.mu.Unlock()
					return provider.InstanceInfo{}, fmt.Errorf("provider instance %q is already initialized as %s; use restart to replace it", spec.InstanceID, existingSpec.Driver)
				}
				if !instanceSpecsEqual(existingSpec, spec) {
					s.mu.Unlock()
					return provider.InstanceInfo{}, fmt.Errorf("provider instance %q is already initialized with different configuration; use restart to replace it", spec.InstanceID)
				}
				s.mu.Unlock()
				return info, nil
			}
		}
	}
	s.mu.Unlock()

	generation := s.allocateEventGeneration()
	// The sink, not the event payload, is authoritative for source identity.
	// Its captured generation distinguishes a replacement process with the same
	// provider instance id from the stale process it replaced.
	emit := func(event provider.RuntimeEvent) {
		event.ProviderInstanceID = spec.InstanceID
		event.ProviderName = spec.Name
		event.Provider = spec.Driver
		event.Generation = generation
		s.publish(runtimeEventEnvelope{event: event, instanceID: spec.InstanceID, generation: generation})
	}

	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	instance, err := s.openInstance(ctx, cloneInstanceSpec(spec), emit)
	if err != nil {
		return provider.InstanceInfo{}, err
	}

	info := instance.Info()
	s.mu.Lock()
	if s.closing {
		s.mu.Unlock()
		_ = instance.Close()
		return provider.InstanceInfo{}, fmt.Errorf("%s: provider service is closed", action)
	}
	current := s.instances[spec.InstanceID]
	s.instances[spec.InstanceID] = instance
	s.instanceSpecs[spec.InstanceID] = cloneInstanceSpec(spec)
	s.activeEventGenerations[spec.InstanceID] = generation
	s.mu.Unlock()
	if current != nil && current != instance {
		_ = current.Close()
	}
	s.persistInstanceSpec(spec.InstanceID)
	return info, nil
}

func cloneInstanceSpec(spec provider.InstanceSpec) provider.InstanceSpec {
	spec.Config = append(json.RawMessage(nil), spec.Config...)
	return spec
}

func instanceSpecsEqual(a provider.InstanceSpec, b provider.InstanceSpec) bool {
	return a.InstanceID == b.InstanceID && a.Name == b.Name && a.Driver == b.Driver && jsonValuesEqual(a.Config, b.Config)
}

func jsonValuesEqual(a json.RawMessage, b json.RawMessage) bool {
	if len(a) == 0 || len(b) == 0 {
		return len(a) == len(b)
	}
	var av any
	var bv any
	if json.Unmarshal(a, &av) != nil || json.Unmarshal(b, &bv) != nil {
		return bytes.Equal(a, b)
	}
	return objectsEqual(av, bv)
}

func objectsEqual(a any, b any) bool {
	aJSON, aErr := json.Marshal(a)
	bJSON, bErr := json.Marshal(b)
	return aErr == nil && bErr == nil && bytes.Equal(aJSON, bJSON)
}

func (s *Service) Authenticate(ctx context.Context, instanceID provider.InstanceID, methodID string) (provider.InstanceInfo, error) {
	instance, err := s.instance(instanceID)
	if err != nil {
		return provider.InstanceInfo{}, err
	}
	authenticator, supportsAuth := instance.(Authenticator)
	if !supportsAuth {
		return provider.InstanceInfo{}, fmt.Errorf("provider does not support authentication")
	}
	return authenticator.Authenticate(ctx, methodID)
}

func (s *Service) Logout(ctx context.Context, instanceID provider.InstanceID) (provider.InstanceInfo, error) {
	instance, err := s.instance(instanceID)
	if err != nil {
		return provider.InstanceInfo{}, err
	}
	authenticator, supportsAuth := instance.(Authenticator)
	if !supportsAuth {
		return provider.InstanceInfo{}, fmt.Errorf("provider does not support authentication")
	}
	return authenticator.Logout(ctx)
}

func (s *Service) Info(instanceID provider.InstanceID) (provider.InstanceInfo, error) {
	instance, err := s.instance(instanceID)
	if err != nil {
		return provider.InstanceInfo{}, err
	}
	return instance.Info(), nil
}

func (s *Service) ListSessions(ctx context.Context, instanceID provider.InstanceID, cwd string) ([]provider.SessionSummary, error) {
	manager, err := s.sessionManager(instanceID)
	if err != nil {
		return nil, err
	}
	return manager.ListSessions(ctx, cwd)
}

// RegisterImportedSession installs an already-persisted external session route
// in the live registry. The metadata store owns the atomic thread+route write;
// this method only makes that committed route usable without a daemon restart.
func (s *Service) RegisterImportedSession(threadID string, instanceID provider.InstanceID, sessionID string, startInput provider.StartSessionInput) error {
	if threadID == "" || instanceID == "" || sessionID == "" {
		return fmt.Errorf("register imported provider session requires threadId, instanceId, and sessionId")
	}
	s.routeBindMu.Lock()
	defer s.routeBindMu.Unlock()
	s.mu.Lock()
	defer s.mu.Unlock()
	generation, ok := s.activeEventGenerations[instanceID]
	if !ok || s.instances[instanceID] == nil {
		return fmt.Errorf("provider instance %q is not initialized", instanceID)
	}
	if existing, ok := s.threadRoutes[threadID]; ok {
		if existing.InstanceID == instanceID && existing.ProviderSessionID == sessionID {
			return nil
		}
		return fmt.Errorf("thread %q already has a different provider session route", threadID)
	}
	for existingThreadID, route := range s.threadRoutes {
		if route.InstanceID == instanceID && route.ProviderSessionID == sessionID {
			return fmt.Errorf("provider session %q is already bound to thread %q", sessionID, existingThreadID)
		}
	}
	s.threadRoutes[threadID] = threadRoute{
		InstanceID:        instanceID,
		Generation:        generation,
		ProviderSessionID: sessionID,
		StartInput:        persistentStartSessionInput(startInput),
	}
	return nil
}

// sessionManageRPCTimeout prevents a hung agent from pinning daemon resources.
const sessionManageRPCTimeout = 60 * time.Second

func (s *Service) DeleteSession(ctx context.Context, instanceID provider.InstanceID, sessionID string) error {
	return s.manageSession(ctx, instanceID, sessionID, "delete", func(ctx context.Context, manager SessionManager) error {
		return manager.DeleteSession(ctx, sessionID)
	})
}

func (s *Service) CloseSession(ctx context.Context, instanceID provider.InstanceID, sessionID string) error {
	return s.manageSession(ctx, instanceID, sessionID, "close", func(ctx context.Context, manager SessionManager) error {
		return manager.CloseSession(ctx, sessionID)
	})
}

// The bound-session guard is best-effort against a concurrent bind. The adapter
// call deliberately runs outside instance locks, with a deadline, so a hung
// maintenance RPC cannot block thread work on that instance.
func (s *Service) manageSession(ctx context.Context, instanceID provider.InstanceID, sessionID string, action string, operation func(context.Context, SessionManager) error) error {
	if sessionID == "" {
		return fmt.Errorf("provider session %s requires sessionId", action)
	}
	manager, err := s.sessionManager(instanceID)
	if err != nil {
		return err
	}
	if threadID := s.boundThreadForProviderSession(instanceID, sessionID); threadID != "" {
		return fmt.Errorf("cannot %s provider session %q while it is bound to thread %q", action, sessionID, threadID)
	}
	ctx, cancel := context.WithTimeout(ctx, sessionManageRPCTimeout)
	defer cancel()
	return operation(ctx, manager)
}

func (s *Service) boundThreadForProviderSession(instanceID provider.InstanceID, sessionID string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	for threadID, route := range s.threadRoutes {
		if route.InstanceID == instanceID && route.ProviderSessionID == sessionID {
			return threadID
		}
	}
	return ""
}

func (s *Service) sessionManager(instanceID provider.InstanceID) (SessionManager, error) {
	instance, err := s.instance(instanceID)
	if err != nil {
		return nil, err
	}
	manager, ok := instance.(SessionManager)
	if !ok {
		return nil, fmt.Errorf("provider does not support session management")
	}
	return manager, nil
}

func (s *Service) ListInstances() []provider.InstanceInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	infos := make([]provider.InstanceInfo, 0, len(s.instances))
	for _, instance := range s.instances {
		infos = append(infos, instance.Info())
	}
	return infos
}

func (s *Service) StartSession(ctx context.Context, threadID string, input provider.StartSessionInput) (provider.StartSessionResult, error) {
	if threadID == "" {
		threadID = input.ThreadID
	}
	if threadID == "" {
		return provider.StartSessionResult{}, fmt.Errorf("provider start session requires threadId")
	}
	if input.ThreadID == "" {
		input.ThreadID = threadID
	}
	if input.ProviderInstanceID == "" {
		return provider.StartSessionResult{}, fmt.Errorf("provider start session requires providerInstanceId")
	}
	if err := s.ensureInstanceStarted(ctx, input.ProviderInstanceID); err != nil {
		return provider.StartSessionResult{}, err
	}
	if route := s.routeForThread(threadID); route.InstanceID != "" && route.InstanceID != input.ProviderInstanceID {
		_ = s.ReleaseSession(ctx, provider.StopSessionInput{ThreadID: threadID})
	}
	lock := s.startLock(input.ProviderInstanceID)
	lock.RLock()
	defer lock.RUnlock()

	result, _, _, err := s.startSessionOnCurrentInstance(ctx, threadID, input)
	return result, err
}

// Provider switching drops the old route before best-effort StopSession. A
// missing, exited, stale, or wedged old instance must not block the switch.
func (s *Service) releaseThreadRouteForSwitch(ctx context.Context, threadID string, route threadRoute) {
	instance, generation, err := s.instanceWithGeneration(route.InstanceID)

	s.mu.Lock()
	if current := s.threadRoutes[threadID]; current.InstanceID == route.InstanceID {
		delete(s.threadRoutes, threadID)
	}
	s.mu.Unlock()
	s.persistThreadRoute(threadID)

	if err != nil {
		return
	}
	if instance.Info().Status == provider.InstanceStatusExited {
		return
	}
	if route.Generation != 0 && route.Generation != generation {
		// The route points at a replaced process generation; the session died
		// with it, so there is no live provider session to stop.
		return
	}
	if err := instance.StopSession(ctx, provider.StopSessionInput{ThreadID: threadID}); err != nil {
		log.Printf("providerservice: best-effort release of thread %q previous session on instance %q failed: %v", threadID, route.InstanceID, err)
	}
}

// ReleaseSession drops a thread's current route and best-effort stops its old
// provider session. Provider switches call this as soon as the canonical
// thread projection clears the binding, rather than waiting for another turn.
func (s *Service) ReleaseSession(ctx context.Context, input provider.StopSessionInput) error {
	if input.ThreadID == "" {
		return nil
	}
	route := s.routeForThread(input.ThreadID)
	if route.InstanceID == "" {
		return nil
	}
	s.releaseThreadRouteForSwitch(ctx, input.ThreadID, route)
	return nil
}

func (s *Service) startSessionOnCurrentInstance(ctx context.Context, threadID string, input provider.StartSessionInput) (provider.StartSessionResult, ProviderInstance, uint64, error) {
	instance, generation, err := s.instanceWithGeneration(input.ProviderInstanceID)
	if err != nil {
		return provider.StartSessionResult{}, nil, 0, err
	}
	if route := s.routeForThread(threadID); route.InstanceID == input.ProviderInstanceID {
		if input.ProviderSessionID == "" {
			input.ProviderSessionID = route.ProviderSessionID
		}
		// Only a stale route needs its provider-owned preferences restored. Once
		// rebound to this generation, each new input remains authoritative.
		if route.Generation != generation {
			stored := route.StartInput
			if input.ModelSelection == nil {
				input.ModelSelection = stored.ModelSelection
			}
			if len(input.ConfigSelections) == 0 {
				input.ConfigSelections = stored.ConfigSelections
			}
			if len(input.Options) == 0 {
				input.Options = stored.Options
			}
		}
		if len(input.ResumeCursor) == 0 {
			input.ResumeCursor = append(json.RawMessage(nil), route.ResumeCursor...)
		}
	}
	result, err := instance.StartSession(ctx, input)
	if err != nil {
		return provider.StartSessionResult{}, nil, 0, err
	}
	info := instance.Info()
	for index := range result.Replay {
		result.Replay[index].Provider = info.Driver
		result.Replay[index].ProviderInstanceID = input.ProviderInstanceID
		result.Replay[index].ProviderName = info.Name
		result.Replay[index].Generation = generation
		result.Replay[index].ThreadID = threadID
	}
	// The requested/selected provider instance is the authoritative routing
	// identity. Adapter-returned sessions may be resumed from stale native state,
	// so never let their ProviderInstanceID rebind the thread route.
	result.Session.Provider = info.Driver
	result.Session.ProviderInstanceID = input.ProviderInstanceID
	result.Session.ProviderName = info.Name
	result.Session.Generation = generation
	if result.Session.ThreadID == "" {
		result.Session.ThreadID = threadID
	}
	if err := s.bindThreadSession(threadID, input.ProviderInstanceID, generation, result.Session.ProviderSessionID, result.Session.ResumeCursor, input); err != nil {
		return provider.StartSessionResult{}, nil, 0, err
	}
	return result, instance, generation, nil
}

func (s *Service) SendTurn(ctx context.Context, input provider.SendTurnInput) error {
	if input.ThreadID == "" {
		return fmt.Errorf("provider turn route requires threadId")
	}
	return s.withThreadInstance(ctx, input.ThreadID, true, "send", func(instance ProviderInstance) error {
		return instance.SendTurn(ctx, input)
	})
}

func (s *Service) withThreadInstance(ctx context.Context, threadID string, recoverStale bool, action string, operation func(ProviderInstance) error) error {
	if threadID == "" {
		return fmt.Errorf("provider thread route requires threadId")
	}
	for {
		route := s.routeForThread(threadID)
		if route.InstanceID == "" {
			return fmt.Errorf("thread %q has no provider session route", threadID)
		}
		lock := s.startLock(route.InstanceID)
		lockedInstanceID := route.InstanceID

		lock.RLock()
		instance, generation, err := s.instanceWithGeneration(lockedInstanceID)
		if err != nil {
			lock.RUnlock()
			return err
		}
		route = s.routeForThread(threadID)
		if route.InstanceID == "" {
			lock.RUnlock()
			return fmt.Errorf("thread %q has no provider session route", threadID)
		}
		if route.InstanceID != lockedInstanceID {
			lock.RUnlock()
			return fmt.Errorf("thread %q provider session route changed during %s", threadID, action)
		}
		if !recoverStale || route.Generation == 0 || route.Generation == generation {
			err = operation(instance)
			lock.RUnlock()
			return err
		}
		lock.RUnlock()

		lock.Lock()
		route = s.routeForThread(threadID)
		if route.InstanceID == "" {
			lock.Unlock()
			return fmt.Errorf("thread %q has no provider session route", threadID)
		}
		if route.InstanceID != lockedInstanceID {
			lock.Unlock()
			return fmt.Errorf("thread %q provider session route changed during %s", threadID, action)
		}
		_, generation, err = s.instanceWithGeneration(lockedInstanceID)
		if err != nil {
			lock.Unlock()
			return err
		}
		if route.Generation != 0 && route.Generation != generation {
			startInput := cloneStartSessionInput(route.StartInput)
			if startInput.ThreadID == "" {
				startInput.ThreadID = threadID
			}
			if startInput.ProviderInstanceID == "" {
				startInput.ProviderInstanceID = route.InstanceID
			}
			if len(startInput.ResumeCursor) == 0 && len(route.ResumeCursor) > 0 {
				startInput.ResumeCursor = append(json.RawMessage(nil), route.ResumeCursor...)
			}
			_, _, _, err = s.startSessionOnCurrentInstance(ctx, threadID, startInput)
			if err != nil {
				lock.Unlock()
				return err
			}
		}
		lock.Unlock()
	}
}

func (s *Service) InterruptTurn(ctx context.Context, input provider.InterruptTurnInput) error {
	return s.withThreadInstance(ctx, input.ThreadID, true, "interrupt", func(instance ProviderInstance) error {
		return instance.InterruptTurn(ctx, input)
	})
}

func (s *Service) SetConfigOption(ctx context.Context, input provider.SetConfigOptionInput) error {
	return s.withThreadInstance(ctx, input.ThreadID, true, "set config option", func(instance ProviderInstance) error {
		if err := instance.SetConfigOption(ctx, input); err != nil {
			return err
		}
		s.updateRouteStartInput(input.ThreadID, instance.Info().InstanceID, func(start *provider.StartSessionInput) {
			if input.Category == provider.ConfigOptionCategoryModel {
				model, ok := input.Value.(string)
				if !ok || model == "" {
					return
				}
				if start.ModelSelection == nil {
					start.ModelSelection = &provider.ModelSelection{}
				}
				start.ModelSelection.Model = model
				return
			}

			selection := provider.ConfigOptionSelection{OptionID: input.OptionID, Value: input.Value, Category: input.Category}
			for index := range start.ConfigSelections {
				if start.ConfigSelections[index].OptionID == input.OptionID {
					start.ConfigSelections[index] = selection
					return
				}
			}
			start.ConfigSelections = append(start.ConfigSelections, selection)
		})
		return nil
	})
}

// updateRouteStartInput persists a successful live-session preference for a
// future generation recovery. Callers invoke it inside withThreadInstance's
// generation read lock, making the provider mutation and recovery state one
// atomic operation relative to StartInstance.
func (s *Service) updateRouteStartInput(threadID string, instanceID provider.InstanceID, update func(*provider.StartSessionInput)) {
	s.mu.Lock()
	route, ok := s.threadRoutes[threadID]
	if !ok || route.InstanceID != instanceID {
		s.mu.Unlock()
		return
	}
	update(&route.StartInput)
	s.threadRoutes[threadID] = route
	s.mu.Unlock()
	s.persistThreadRoute(threadID)
}

func (s *Service) StopSession(ctx context.Context, input provider.StopSessionInput) error {
	err := s.withThreadInstance(ctx, input.ThreadID, false, "stop session", func(instance ProviderInstance) error {
		return instance.StopSession(ctx, input)
	})
	if err != nil {
		return err
	}
	// Stop unbinds the thread's provider session: drop the route so the next
	// turn's StartSession cannot auto-fill the stored resume cursor and reload
	// the stopped session — the contract is that the next turn starts fresh.
	s.mu.Lock()
	delete(s.threadRoutes, input.ThreadID)
	s.mu.Unlock()
	s.persistThreadRoute(input.ThreadID)
	return nil
}

func (s *Service) RespondToRequest(ctx context.Context, input provider.RespondToRequestInput) error {
	return s.withThreadInstance(ctx, input.ThreadID, true, "respond to request", func(instance ProviderInstance) error {
		return instance.RespondToRequest(ctx, input)
	})
}

func (s *Service) bindThreadSession(threadID string, instanceID provider.InstanceID, generation uint64, providerSessionID string, resumeCursor json.RawMessage, startInput provider.StartSessionInput) error {
	if threadID == "" || instanceID == "" {
		return nil
	}
	route := threadRoute{
		InstanceID:        instanceID,
		Generation:        generation,
		ProviderSessionID: providerSessionID,
		ResumeCursor:      append(json.RawMessage(nil), resumeCursor...),
		StartInput:        persistentStartSessionInput(startInput),
	}

	s.routeBindMu.Lock()
	defer s.routeBindMu.Unlock()
	s.mu.Lock()
	for existingThreadID, existing := range s.threadRoutes {
		if existingThreadID != threadID && existing.InstanceID == instanceID && existing.ProviderSessionID == providerSessionID && providerSessionID != "" {
			s.mu.Unlock()
			return fmt.Errorf("%w: provider session %q belongs to thread %q", store.ErrProviderSessionBound, providerSessionID, existingThreadID)
		}
	}
	s.mu.Unlock()

	return s.persistNewThreadRoute(threadID, route)
}

// persistNewThreadRoute reserves a provider session durably before publishing
// its live binding. Transient store failures retain the existing best-effort
// retry behavior; a uniqueness conflict must reject the second live owner.
func (s *Service) persistNewThreadRoute(threadID string, route threadRoute) error {
	publish := func() {
		s.mu.Lock()
		s.threadRoutes[threadID] = route
		s.mu.Unlock()
	}
	if s.routeStore == nil {
		publish()
		return nil
	}
	s.storeMu.Lock()
	defer s.storeMu.Unlock()
	s.flushPersistenceLocked()
	err := s.routeStore.SaveRoute(threadID, store.RouteRecord{
		InstanceID:        route.InstanceID,
		ProviderSessionID: route.ProviderSessionID,
		ResumeCursor:      route.ResumeCursor,
		StartInput:        route.StartInput,
	})
	if errors.Is(err, store.ErrProviderSessionBound) {
		return err
	}
	if err != nil {
		log.Printf("providerservice: persist route for thread %q: %v (will retry)", threadID, err)
		s.dirtyRoutes[threadID] = struct{}{}
		publish()
		return nil
	}
	delete(s.dirtyRoutes, threadID)
	publish()
	return nil
}

func (s *Service) routeForThread(threadID string) threadRoute {
	s.mu.Lock()
	defer s.mu.Unlock()
	route := s.threadRoutes[threadID]
	route.ResumeCursor = append(json.RawMessage(nil), route.ResumeCursor...)
	route.StartInput = cloneStartSessionInput(route.StartInput)
	return route
}

func (s *Service) instance(instanceID provider.InstanceID) (ProviderInstance, error) {
	instance, _, err := s.instanceWithGeneration(instanceID)
	return instance, err
}

func (s *Service) instanceWithGeneration(instanceID provider.InstanceID) (ProviderInstance, uint64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if instanceID == "" {
		return nil, 0, fmt.Errorf("provider lookup requires an instance id")
	}
	instance := s.instances[instanceID]
	if instance == nil {
		return nil, 0, fmt.Errorf("provider instance %q is not initialized", instanceID)
	}
	return instance, s.activeEventGenerations[instanceID], nil
}

func cloneStartSessionInput(input provider.StartSessionInput) provider.StartSessionInput {
	cloned := input
	cloned.ResumeCursor = append(json.RawMessage(nil), input.ResumeCursor...)
	cloned.Options = append(json.RawMessage(nil), input.Options...)
	cloned.ConfigSelections = append([]provider.ConfigOptionSelection(nil), input.ConfigSelections...)
	if input.ModelSelection != nil {
		model := *input.ModelSelection
		model.Options = append(json.RawMessage(nil), input.ModelSelection.Options...)
		cloned.ModelSelection = &model
	}
	return cloned
}

func persistentStartSessionInput(input provider.StartSessionInput) provider.StartSessionInput {
	cloned := cloneStartSessionInput(input)
	cloned.ProviderSessionID = ""
	cloned.ReplayHistory = false
	return cloned
}
