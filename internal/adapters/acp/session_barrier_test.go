package acp

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

func TestLoadSessionTimeoutCleansLoadState(t *testing.T) {
	agent := &fakeWireAgent{
		capabilities: map[string]any{"loadSession": true},
		onLoadSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			// Never respond: session/load must fail via the caller's context.
		},
	}
	h := newWireTestHandle(t, agent)
	recorder := &eventRecorder{}
	h.runtimeEventListener = recorder.listener

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, err := h.StartSession(ctx, provider.StartSessionInput{ThreadID: "thread-1", ResumeCursor: marshalRaw(map[string]string{"sessionId": "old"})}); err == nil {
		t.Fatal("StartSession err = nil, want load timeout")
	}
	if got := h.sessionIDForThread("thread-1"); got != "" {
		t.Fatalf("thread remains bound to %q after load timeout", got)
	}
	h.mu.Lock()
	session := h.sessions["old"]
	h.mu.Unlock()
	if session != nil {
		t.Fatalf("load timeout left session state %#v, want unbound", session)
	}
	if events := recorder.snapshot(); len(events) != 0 {
		t.Fatalf("events after failed load = %#v, want none", events)
	}
}

func TestAbandonSessionStreamReleasesBarrierWithoutDrain(t *testing.T) {
	h := newWireTestHandle(t, &fakeWireAgent{})
	stream := &sessionStream{
		sessionID: "old",
		session:   h.agent().AttachSession("old"),
		barriers:  make(map[string]*sessionBarrier),
	}
	h.bindSession("thread-old", "old")
	h.mu.Lock()
	h.sessions[stream.sessionID].stream = stream
	h.mu.Unlock()

	drained := make(chan struct{}, 1)
	errCh := make(chan error, 1)
	go func() {
		errCh <- h.awaitSessionBarrier(context.Background(), stream, func() { drained <- struct{}{} })
	}()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		h.mu.Lock()
		registered := len(stream.barriers) > 0
		h.mu.Unlock()
		if registered {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	h.mu.Lock()
	registered := len(stream.barriers) > 0
	h.mu.Unlock()
	if !registered {
		t.Fatal("timed out waiting for barrier registration")
	}

	cause := errors.New("session stream died")
	h.abandonSessionStream(stream, cause)
	select {
	case err := <-errCh:
		if !errors.Is(err, cause) {
			t.Fatalf("awaitSessionBarrier err = %v, want %v", err, cause)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for abandoned barrier to release")
	}
	select {
	case <-drained:
		t.Fatal("abandoned barrier ran drain callback")
	default:
	}
}

func TestResumeSessionBarrierTimeoutUnbindsSession(t *testing.T) {
	agent := &fakeWireAgent{
		capabilities: map[string]any{"sessionCapabilities": map[string]any{"resume": map[string]any{}}},
		onResumeSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			a.sendUpdate("old", agentMessageUpdate("msg-1", "resumed"))
			a.respond(id, map[string]any{"configOptions": wireModelConfigOptions("model-a")})
		},
	}
	h := newWireTestHandle(t, agent)
	entered := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	h.runtimeEventListener = func(provider.RuntimeEvent) {
		once.Do(func() {
			close(entered)
			<-release
		})
	}

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	errCh := make(chan error, 1)
	go func() {
		_, err := h.StartSession(ctx, provider.StartSessionInput{ThreadID: "thread-1", ResumeCursor: marshalRaw(map[string]string{"sessionId": "old"})})
		errCh <- err
	}()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for resume update to block the barrier")
	}
	select {
	case err := <-errCh:
		if err == nil || !strings.Contains(err.Error(), "context deadline") {
			t.Fatalf("StartSession err = %v, want barrier context deadline", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for StartSession to fail on resume barrier deadline")
	}
	if got := h.sessionIDForThread("thread-1"); got != "" {
		t.Fatalf("thread remains bound to %q after resume barrier timeout", got)
	}

	close(release)
}
