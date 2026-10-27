// Ordered session streams for the ACP adapter: the per-session update queue,
// prompt stop markers, and barriers.
package acp

import (
	"context"
	"errors"
	"sync/atomic"

	acp "github.com/Aqothy/go-acp"
	"github.com/Aqothy/go-acp/schema"
	"github.com/Aqothy/maiD/internal/provider"
)

var errSessionStreamClosed = errors.New("ACP session stream closed")

// sessionStream owns one ACP session's ordered inbound stream: the SDK routes
// session/update notifications synchronously on the read loop into the
// ActiveSession queue, and prompt resolutions arrive as in-queue Stop markers.
// One consumer goroutine per stream dequeues in wire order, so a turn's final
// updates are always processed before it settles.
type sessionStream struct {
	sessionID string
	session   *acp.ActiveSession
	// closed is set when the stream consumer terminates or the stream is
	// disposed. Guarded by Instance.mu.
	closed   bool
	closeErr error
	// barriers maps PushMarker tags to waiters. The drain side effect runs only
	// when the marker is dequeued; stream abandonment only releases the waiter.
	// Guarded by Instance.mu.
	barriers map[string]*sessionBarrier
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

func (h *Instance) sessionStreamFor(sessionID string) *sessionStream {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessions[sessionID]
	if session == nil || session.stream == nil || session.stream.closed {
		return nil
	}
	return session.stream
}

func (h *Instance) sessionFor(stream *sessionStream) *acpSession {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessions[stream.sessionID]
	if session == nil || session.stream != stream {
		return nil
	}
	return session
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
			if session := h.sessionFor(stream); session != nil {
				h.handleUpdate(session, msg.Notification)
			}
		case acp.ActiveSessionMessageStop:
			if session := h.sessionFor(stream); session != nil {
				h.settlePrompt(session, msg.Response, msg.Err)
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

// abandonSessionStream ends a terminated stream: a running prompt fails with
// the termination (a killed agent fails the turn instead of hanging it),
// barrier waiters are released, and a session the daemon still had open is
// reported closed.
func (h *Instance) abandonSessionStream(stream *sessionStream, cause error) {
	if cause == nil {
		cause = errSessionStreamClosed
	}
	h.mu.Lock()
	disposed := stream.closed
	stream.closed = true
	if stream.closeErr == nil {
		stream.closeErr = cause
	}
	barriers := make([]*sessionBarrier, 0, len(stream.barriers))
	for tag, barrier := range stream.barriers {
		barriers = append(barriers, barrier)
		delete(stream.barriers, tag)
	}
	session := h.sessions[stream.sessionID]
	if session != nil && session.stream != stream {
		session = nil
	}
	var invalidated func()
	if session != nil {
		delete(h.sessions, stream.sessionID)
		if session.options != nil {
			invalidated = session.options.Invalidated
		}
	}
	h.mu.Unlock()
	stream.session.Dispose()
	for _, barrier := range barriers {
		barrier.abandon()
	}
	if session == nil {
		return
	}
	if invalidated != nil {
		invalidated()
		return
	}
	h.settlePrompt(session, schema.PromptResponse{}, cause)
	if !disposed && h.host.Emit != nil {
		h.host.Emit(provider.Event{Session: stream.sessionID, Body: provider.SessionClosed{Error: acpRequestError(cause).Error()}})
	}
}

// awaitSessionBarrier pushes a marker through the session's update queue and
// blocks until the consumer dequeues it. Because the SDK routes updates
// synchronously on the read loop, every notification the agent sent before the
// marker was pushed is processed before onDrain runs, and onDrain completes
// before later queued session messages can be consumed. If the caller's context
// expires first, the marker callback is unregistered so a late marker cannot
// run post-failure work.
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
