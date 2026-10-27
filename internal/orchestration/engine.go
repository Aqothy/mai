package orchestration

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"runtime/debug"
	"sync"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// Providers gives the engine provider instances.
type Providers interface {
	// Instance returns the running instance, starting it when it isn't, and
	// its process generation.
	Instance(ctx context.Context, id provider.InstanceID) (provider.Instance, uint64, error)
	// Info describes a configured instance, running or not.
	Info(id provider.InstanceID) (provider.InstanceInfo, bool)
}

type Config struct {
	DB        *sql.DB
	Providers Providers
	// DataDir holds the attachment store.
	DataDir string
	// DefaultCwd is the workspace of a thread created without one.
	DefaultCwd string
	Logger     *slog.Logger
	// MCP is maiD's MCP server for a participant's session; nil while maiD
	// has none.
	MCP func(ThreadID, ParticipantID) *provider.MCPServer
	// Instructions tell agents with an MCP server how to work in maiD.
	Instructions string
}

// Engine owns the ledger, the session cache and all live orchestration state.
// One goroutine runs it: commands, provider events, provider call results and
// reads are steps on its queue, totally ordered. It never waits on a
// provider: calls run on per-participant workers and come back as steps.
type Engine struct {
	cfg         Config
	db          *db
	attachments *attachmentStore
	mirrors     *mirrorWriter
	logger      *slog.Logger

	ctx    context.Context
	cancel context.CancelFunc
	inbox  chan func(*step)
	done   chan struct{}
	// fatal is the error that stopped the engine.
	fatalMu sync.Mutex
	fatal   error

	// Everything below belongs to the engine goroutine.
	threads      map[ThreadID]*threadState
	participants map[ParticipantID]*participantState
	bySession    map[sessionKey]ParticipantID
	seq          uint64
	subscribers  map[uint64]*subscriber
	nextSub      uint64
	// orphans are events for sessions not known yet, kept while an Open on
	// their instance is in flight (Opened arrives after the session's first
	// events can).
	orphans []orphanEvent
	opening map[provider.InstanceID]int
	// published is each thread's summary as clients last got it.
	published map[ThreadID]ThreadSummary
	// waits are agents' wait calls.
	waits    map[uint64]*waiter
	nextWait uint64
	// dispatched are deliveries whose Send is in flight.
	dispatched map[DeliveryID]bool
	// noticed are the requests a spawner was told about (WakeNeedsInput).
	noticed map[string]bool
}

type orphanEvent struct {
	instance   provider.InstanceID
	generation uint64
	event      provider.Event
}

// Open loads the ledger, recovers from a crash and starts the engine.
func Open(cfg Config) (*Engine, error) {
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	database, err := openDB(cfg.DB)
	if err != nil {
		return nil, err
	}
	attachments, err := openAttachmentStore(cfg.DataDir)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	e := &Engine{
		cfg: cfg, db: database, attachments: attachments, logger: cfg.Logger.With("component", "orchestration"),
		ctx: ctx, cancel: cancel, inbox: make(chan func(*step), 1024), done: make(chan struct{}),
		threads: make(map[ThreadID]*threadState), participants: make(map[ParticipantID]*participantState),
		bySession: make(map[sessionKey]ParticipantID), subscribers: make(map[uint64]*subscriber),
		opening: make(map[provider.InstanceID]int), published: make(map[ThreadID]ThreadSummary),
		waits: make(map[uint64]*waiter), dispatched: make(map[DeliveryID]bool), noticed: make(map[string]bool),
	}
	e.mirrors = newMirrorWriter(database, e.logger)
	loaded, err := database.load(ctx)
	if err != nil {
		cancel()
		return nil, err
	}
	e.install(loaded)
	go e.mirrors.run(ctx)
	go e.run()
	// Recovery and every reactor run once at startup, so state left by a
	// crash converges.
	e.post(func(s *step) { e.recover(s) })
	return e, nil
}

// Mirror is the native mirror the engine keeps for an instance's adapter.
func (e *Engine) Mirror(instance provider.InstanceID) provider.Mirror {
	return &instanceMirror{writer: e.mirrors, instance: instance}
}

// Close stops the engine. Queued steps are dropped; queued mirror frames are
// written.
func (e *Engine) Close() {
	e.cancel()
	<-e.done
	<-e.mirrors.stopped
}

// Done closes once the engine stopped, on Close or a fatal error.
func (e *Engine) Done() <-chan struct{} { return e.done }

// Err is the fatal error that stopped the engine, if any.
func (e *Engine) Err() error {
	e.fatalMu.Lock()
	defer e.fatalMu.Unlock()
	return e.fatal
}

var errClosed = errors.New("orchestration engine is closed")

// post queues a step. It never blocks the engine goroutine itself: steps
// posted from it run after the current one.
func (e *Engine) post(fn func(*step)) bool {
	select {
	case e.inbox <- fn:
		return true
	case <-e.ctx.Done():
		return false
	}
}

// call runs fn as a step and waits for the value it produces.
func call[T any](ctx context.Context, e *Engine, fn func(*step) (T, error)) (T, error) {
	type outcome struct {
		value T
		err   error
	}
	result := make(chan outcome, 1)
	queued := e.post(func(s *step) {
		value, err := fn(s)
		// The caller hears only once the step's writes committed.
		s.after(func() { result <- outcome{value, err} })
	})
	var zero T
	if !queued {
		return zero, errClosed
	}
	select {
	case out := <-result:
		return out.value, out.err
	case <-ctx.Done():
		return zero, ctx.Err()
	case <-e.done:
		select {
		case out := <-result:
			return out.value, out.err
		default:
			return zero, errClosed
		}
	}
}

// flushInterval is how often running turns' entries are written to the
// session cache. A crash loses at most this much of a running turn, which
// reconciliation reads again where the provider keeps it.
const flushInterval = 250 * time.Millisecond

func (e *Engine) run() {
	defer close(e.done)
	ticker := time.NewTicker(flushInterval)
	defer ticker.Stop()
	for {
		select {
		case <-e.ctx.Done():
			return
		case fn := <-e.inbox:
			if !e.step(fn) {
				return
			}
		case <-ticker.C:
			if !e.step(func(s *step) { e.flushRunning(s) }) {
				return
			}
		}
	}
}

// step is one engine step: its writes commit together, then its effects run.
type step struct {
	e  *Engine
	tx *tx
	// touched are the threads the reactors still have to look at; changed
	// all the threads the step changed, for the thread list.
	touched map[ThreadID]bool
	changed map[ThreadID]bool
	effects []func()
	now     time.Time
}

func (s *step) touch(id ThreadID) {
	s.touched[id] = true
	s.changed[id] = true
}

// after runs fn once the step committed.
func (s *step) after(fn func()) { s.effects = append(s.effects, fn) }

// step runs fn and commits it, then runs the reactors for the threads it
// touched, each round its own commit, so reactors read what the step wrote.
// A crash between rounds reruns them at startup. A failed commit or a panic
// stops the engine: memory and storage may disagree, so going on could do
// anything twice.
func (e *Engine) step(fn func(*step)) (ok bool) {
	defer func() {
		if recovered := recover(); recovered != nil {
			e.stop(fmt.Errorf("orchestration step panicked: %v\n%s", recovered, debug.Stack()))
			ok = false
		}
	}()
	s := e.newStep()
	fn(s)
	if !e.finish(s) {
		return false
	}
	due := s.touched
	for round := 0; round < maxReactorRounds && len(due) > 0; round++ {
		r := e.newStep()
		e.react(r, due)
		if !e.finish(r) {
			return false
		}
		due = r.touched
	}
	return true
}

func (e *Engine) newStep() *step {
	return &step{e: e, tx: newTx(), touched: make(map[ThreadID]bool), changed: make(map[ThreadID]bool), now: time.Now()}
}

// finish publishes a step's summaries, commits it and runs its effects.
func (e *Engine) finish(s *step) bool {
	e.publishSummaries(s)
	if err := e.db.commit(e.ctx, s.tx); err != nil {
		if e.ctx.Err() == nil {
			e.stop(err)
		}
		return false
	}
	for _, effect := range s.effects {
		effect()
	}
	return true
}

func (e *Engine) stop(err error) {
	e.logger.Error("orchestration engine stopped", "error", err)
	e.fatalMu.Lock()
	if e.fatal == nil {
		e.fatal = err
	}
	e.fatalMu.Unlock()
	e.cancel()
}
