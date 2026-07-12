// Ordered session streams for the ACP adapter: the per-session update queue,
// prompt stop markers, and load/resume replay barriers.
package acp

import (
	"context"
	"errors"
	"sync/atomic"

	acp "github.com/Aqothy/go-acp"
	"github.com/Aqothy/go-acp/schema"
)

var errSessionStreamClosed = errors.New("ACP session stream closed")

// sessionStream owns one ACP session's ordered inbound stream: the SDK routes
// session/update notifications synchronously on the read loop into the
// ActiveSession queue, and prompt resolutions arrive as in-queue Stop markers.
// One consumer goroutine per stream dequeues in wire order, so a turn's final
// updates are always processed before its turn.completed, and load-replay
// classification ends exactly at the in-queue barrier marker.
type sessionStream struct {
	sessionID string
	session   *acp.ActiveSession
	// closed is set when the stream consumer terminates or the stream is
	// disposed. It prevents a SendTurn racing with abandonment from appending a
	// prompt whose Stop marker can never be delivered. Guarded by Instance.mu.
	closed   bool
	closeErr error
	// active is the one prompt dispatched to the agent, awaiting its in-queue
	// Stop marker; queued holds prompts accepted while it runs. The stream
	// consumer is the only dispatcher of queued prompts, so prompts on one
	// session never overlap at the agent. Both are guarded by Instance.mu.
	active *pendingPrompt
	queued []*pendingPrompt
	// barriers maps PushMarker tags to waiters. The drain side effect runs only
	// when the marker is dequeued; stream abandonment only releases the waiter.
	// Guarded by Instance.mu.
	barriers map[string]*sessionBarrier
}

type pendingPrompt struct {
	threadID  string
	turnID    string
	collector *promptCollector
	blocks    []schema.ContentBlock
}

type sessionBarrier struct {
	done    chan struct{}
	onDrain func()
	active  atomic.Bool
}

func newSessionBarrier(onDrain func()) *sessionBarrier {
	barrier := &sessionBarrier{done: make(chan struct{}), onDrain: onDrain}
	barrier.active.Store(true)
	return barrier
}

func (b *sessionBarrier) drain() {
	if !b.active.CompareAndSwap(true, false) {
		return
	}
	if b.onDrain != nil {
		b.onDrain()
	}
	close(b.done)
}

func (b *sessionBarrier) abandon() {
	if b.active.CompareAndSwap(true, false) {
		close(b.done)
	}
}

// ensureSessionStream attaches an ActiveSession for a BOUND session
// (subscribing to its update stream) and starts its consumer. Attaching before
// a session/load or session/resume call is what routes updates replayed while
// the call is in flight. Returns created=false when the session already has a
// live stream, and nil when the session is not bound (callers bind first).
func (h *Instance) ensureSessionStream(sessionID string) (*sessionStream, bool) {
	h.mu.Lock()
	session := h.sessionLocked(sessionID)
	if session == nil {
		h.mu.Unlock()
		return nil, false
	}
	if session.stream != nil {
		stream := session.stream
		h.mu.Unlock()
		return stream, false
	}
	stream := &sessionStream{
		sessionID: sessionID,
		session:   h.agent().AttachSession(schema.SessionId(sessionID)),
		barriers:  make(map[string]*sessionBarrier),
	}
	session.stream = stream
	h.mu.Unlock()
	go h.consumeSessionStream(stream)
	return stream, true
}

func (h *Instance) sessionStreamFor(sessionID string) *sessionStream {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessionLocked(sessionID)
	if session == nil || session.stream == nil || session.stream.closed {
		return nil
	}
	return session.stream
}

// consumeSessionStream is the per-session consumer: updates, prompt Stops, and
// barrier markers arrive in ONE ordered stream. A NextUpdate error means the
// stream terminated (disposed, connection closed, or handle shutdown).
func (h *Instance) consumeSessionStream(stream *sessionStream) {
	for {
		msg, err := stream.session.NextUpdate(h.ctx)
		if err != nil {
			h.abandonSessionStream(stream, err)
			return
		}
		switch msg.Kind {
		case acp.ActiveSessionMessageUpdate:
			h.handleACPSessionUpdate(msg.Notification)
		case acp.ActiveSessionMessageStop:
			if rec := h.takeActivePrompt(stream); rec != nil {
				h.settlePrompt(stream, rec, msg.Response, msg.Err)
			}
		case acp.ActiveSessionMessageMarker:
			h.mu.Lock()
			barrier := stream.barriers[msg.Marker]
			delete(stream.barriers, msg.Marker)
			h.mu.Unlock()
			if barrier != nil {
				barrier.drain()
			}
		}
	}
}

// abandonSessionStream settles everything still waiting on a terminated
// stream: in-flight prompts settle with the termination error (so a killed
// agent process fails the turn instead of hanging it), and barrier waiters are
// released without running drain-only side effects.
func (h *Instance) abandonSessionStream(stream *sessionStream, cause error) {
	if cause == nil {
		cause = errSessionStreamClosed
	}
	h.mu.Lock()
	stream.closed = true
	stream.closeErr = cause
	active := stream.active
	queued := append([]*pendingPrompt(nil), stream.queued...)
	stream.active = nil
	stream.queued = nil
	barriers := make([]*sessionBarrier, 0, len(stream.barriers))
	for tag, barrier := range stream.barriers {
		barriers = append(barriers, barrier)
		delete(stream.barriers, tag)
	}
	// Unbind only while this stream is still the registered one: a session that
	// was already stopped/rebound may have a replacement stream whose bindings
	// must survive this (older) stream's abandonment.
	if session := h.sessionLocked(stream.sessionID); session != nil && session.stream == stream {
		h.unbindSessionLocked(stream.sessionID)
	}
	h.mu.Unlock()
	stream.session.Dispose()
	if active != nil {
		h.settlePrompt(stream, active, schema.PromptResponse{}, cause)
	}
	// The active prompt settles its collector. Settle one representative prompt
	// for every other queued collector; additional queued prompts share that
	// turn lifecycle and need no duplicate completion.
	settled := make(map[*promptCollector]struct{})
	if active != nil {
		settled[active.collector] = struct{}{}
	}
	for _, rec := range queued {
		if _, ok := settled[rec.collector]; ok {
			continue
		}
		settled[rec.collector] = struct{}{}
		h.settlePrompt(stream, rec, schema.PromptResponse{}, cause)
	}
	for _, barrier := range barriers {
		barrier.abandon()
	}
}

func (h *Instance) takeActivePrompt(stream *sessionStream) *pendingPrompt {
	h.mu.Lock()
	defer h.mu.Unlock()
	rec := stream.active
	stream.active = nil
	return rec
}

// awaitSessionBarrier pushes a marker through the session's update queue and
// blocks until the consumer dequeues it. Because the SDK routes updates
// synchronously on the read loop, every notification the agent sent before the
// marker was pushed is processed before onDrain runs, and onDrain completes
// before later queued session messages can be consumed. If the caller's context
// expires first, the marker callback is unregistered so a late marker cannot
// run post-failure session materialization work.
func (h *Instance) awaitSessionBarrier(ctx context.Context, stream *sessionStream, onDrain func()) error {
	tag := newID()
	barrier := newSessionBarrier(onDrain)
	h.mu.Lock()
	if stream.closed {
		err := stream.closeErr
		h.mu.Unlock()
		return err
	}
	stream.barriers[tag] = barrier
	h.mu.Unlock()
	stream.session.PushMarker(tag)
	cancelBarrier := func(err error) error {
		if barrier.active.CompareAndSwap(true, false) {
			h.mu.Lock()
			delete(stream.barriers, tag)
			h.mu.Unlock()
			return err
		}
		// The consumer won the race and is closing done now; report success or
		// the stream close error instead of a spurious timeout.
		<-barrier.done
		return h.sessionBarrierCloseErr(stream)
	}
	select {
	case <-barrier.done:
		return h.sessionBarrierCloseErr(stream)
	case <-ctx.Done():
		return cancelBarrier(ctx.Err())
	case <-h.ctx.Done():
		return cancelBarrier(h.ctx.Err())
	}
}

func (h *Instance) sessionBarrierCloseErr(stream *sessionStream) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if stream.closed {
		return stream.closeErr
	}
	return nil
}
