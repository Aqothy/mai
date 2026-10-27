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

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, err := h.Open(ctx, provider.OpenInput{Session: "old", Workspace: workspace}); err == nil {
		t.Fatal("Open err = nil, want load timeout")
	}
	h.mu.Lock()
	session := h.sessions["old"]
	h.mu.Unlock()
	if session != nil {
		t.Fatalf("load timeout left session state %#v, want none", session)
	}
	if events := h.events.Snapshot(); len(events) != 0 {
		t.Fatalf("events after failed load = %#v, want none", events)
	}
}

func TestAbandonSessionStreamReleasesBarrierWithoutDrain(t *testing.T) {
	h := newWireTestHandle(t, &fakeWireAgent{})
	stream := &sessionStream{
		sessionID: "old",
		session:   h.agentPeer.AttachSession("old"),
		barriers:  make(map[string]*sessionBarrier),
	}

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
	err := waitFor(t, errCh, "timed out waiting for abandoned barrier to release")
	if !errors.Is(err, cause) {
		t.Fatalf("awaitSessionBarrier err = %v, want %v", err, cause)
	}
	select {
	case <-drained:
		t.Fatal("abandoned barrier ran drain callback")
	default:
	}
}

// A resume whose updates can't be delivered before the caller's deadline
// fails, and leaves no live session behind.
func TestResumeSessionBarrierTimeoutDetachesSession(t *testing.T) {
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
	h.host.Emit = func(provider.Event) {
		once.Do(func() {
			close(entered)
			<-release
		})
	}

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	errCh := make(chan error, 1)
	go func() {
		_, err := h.Open(ctx, provider.OpenInput{Session: "old", Workspace: workspace})
		errCh <- err
	}()
	waitFor(t, entered, "timed out waiting for resume update to block the barrier")
	err := waitFor(t, errCh, "timed out waiting for Open to fail on resume barrier deadline")
	if err == nil || !strings.Contains(err.Error(), "context deadline") {
		t.Fatalf("Open err = %v, want barrier context deadline", err)
	}
	if h.live("old") {
		t.Fatal("session stayed live after the resume barrier timed out")
	}
	close(release)
}
