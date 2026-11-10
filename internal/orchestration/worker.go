package orchestration

import (
	"context"
	"sync"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// worker runs one participant's provider calls in order (Open before Send),
// off the engine; participants don't wait on each other. A job's outcome
// comes back to the engine as a step.
type worker struct {
	mu      sync.Mutex
	jobs    []func()
	running bool
}

// providerCallTimeout bounds one provider call, so a hung agent can't hold a
// participant's later calls forever. Opening a session spawns a process and
// may take a while; npm-launched agents may first install.
const providerCallTimeout = 2 * time.Minute

func (w *worker) enqueue(job func()) {
	w.mu.Lock()
	w.jobs = append(w.jobs, job)
	if w.running {
		w.mu.Unlock()
		return
	}
	w.running = true
	w.mu.Unlock()
	go w.drain()
}

func (w *worker) drain() {
	for {
		w.mu.Lock()
		if len(w.jobs) == 0 {
			w.running = false
			w.mu.Unlock()
			return
		}
		job := w.jobs[0]
		w.jobs = w.jobs[1:]
		w.mu.Unlock()
		job()
	}
}

// providerCall runs call on the participant's worker once the step commits,
// with its instance, and applies the step call returns. When the instance
// can't run, unavailable applies instead. A participant gone by then drops the
// outcome.
func (s *step) providerCall(participant *participantState, call func(ctx context.Context, instance provider.Instance, generation uint64) func(*step), unavailable func(*step, error)) {
	e := s.e
	id, instanceID, folder := participant.ID, participant.Instance, e.threads[participant.Thread].Workspace.Cwd
	s.onWorker(participant, func() {
		ctx, cancel := context.WithTimeout(e.ctx, providerCallTimeout)
		defer cancel()
		var apply func(*step)
		if instance, generation, err := e.cfg.Providers.Instance(ctx, instanceID, folder); err != nil {
			apply = func(s *step) { unavailable(s, err) }
		} else {
			apply = call(ctx, instance, generation)
		}
		if apply == nil {
			return
		}
		e.post(func(s *step) {
			if e.participants[id] == nil {
				return
			}
			apply(s)
		})
	})
}

// releaseUnlessTaken hands the engine a session a provider call made, and
// releases it unless take reports that a chat took it. The call's outcome
// isn't returned to providerCall for this, which drops it once the
// participant is gone (its chat deleted), and nothing else knows of the
// session then.
func (e *Engine) releaseUnlessTaken(instance provider.Instance, session string, take func(*step) bool) {
	taken := make(chan bool, 1)
	if !e.post(func(s *step) { taken <- take(s) }) {
		return
	}
	select {
	case kept := <-taken:
		if session != "" && !kept {
			// The call's own time is spent by now.
			ctx, cancel := context.WithTimeout(e.ctx, providerCallTimeout)
			defer cancel()
			_ = instance.Release(ctx, session)
		}
	case <-e.done:
	}
}

// onWorker runs job on the participant's worker once the step commits.
func (s *step) onWorker(participant *participantState, job func()) {
	if participant.worker == nil {
		participant.worker = &worker{}
	}
	w := participant.worker
	s.after(func() { w.enqueue(job) })
}
