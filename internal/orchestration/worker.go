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
	if participant.worker == nil {
		participant.worker = &worker{}
	}
	w, id, instanceID := participant.worker, participant.ID, participant.Instance
	s.after(func() {
		w.enqueue(func() {
			ctx, cancel := context.WithTimeout(e.ctx, providerCallTimeout)
			defer cancel()
			var apply func(*step)
			if instance, generation, err := e.cfg.Providers.Instance(ctx, instanceID); err != nil {
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
	})
}
