package orchestration

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"

	_ "modernc.org/sqlite"
)

// fakeInstance is an in-process provider. Its native sessions outlive the
// engine, as a real provider's do, so a test can restart the daemon.
type fakeInstance struct {
	provider.Unsupported

	mu       sync.Mutex
	info     provider.InstanceInfo
	emit     func(provider.Event)
	sessions map[string]*fakeSession
	live     map[string]bool
	opened   int
	// openGate, while set, holds Open until closed.
	openGate chan struct{}
	// onSend runs a sent message; the default answers it and ends the turn.
	onSend func(f *fakeInstance, session string, in provider.SendInput) (provider.SendAck, error)
	// interruptGate, when set, holds an interrupted turn's end until closed.
	interruptGate chan struct{}
	// received is every message sent, in order.
	received []fakeReceived
	// interrupts are the turns interrupted.
	interrupts []string
	responses  []provider.RequestAnswer
}

type fakeReceived struct {
	session string
	in      provider.SendInput
}

type fakeSession struct {
	turns     []provider.HistoryTurn
	delivered map[string]bool
}

func newFakeInstance(id provider.InstanceID, name string) *fakeInstance {
	return &fakeInstance{
		info: provider.InstanceInfo{
			InstanceID: id, Name: name, Driver: "fake", Status: provider.InstanceStatusInitialized,
			Capabilities: provider.Capabilities{History: provider.HistoryExact, HistoryVersion: 1, Resume: true, Fork: true, Steer: true, MessageIDs: true, Rename: true},
			Access: &provider.AccessModes{Option: "mode", Levels: map[string]provider.AccessLevel{
				"read": provider.AccessReadOnly, "ask": provider.AccessAsk, "edit": provider.AccessEdit, "full": provider.AccessFull,
			}},
		},
		sessions: make(map[string]*fakeSession),
		live:     make(map[string]bool),
	}
}

func (f *fakeInstance) Info() provider.InstanceInfo {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.info
}

func (f *fakeInstance) Close() error { return nil }

func (f *fakeInstance) Open(ctx context.Context, in provider.OpenInput) (provider.Opened, error) {
	f.mu.Lock()
	gate := f.openGate
	f.mu.Unlock()
	if gate != nil {
		select {
		case <-gate:
		case <-ctx.Done():
			return provider.Opened{}, ctx.Err()
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.opened++
	session := in.Session
	if session == "" || f.sessions[session] == nil {
		session = fmt.Sprintf("%s-session-%d", f.info.InstanceID, len(f.sessions)+1)
		f.sessions[session] = &fakeSession{delivered: make(map[string]bool)}
	}
	f.live[session] = true
	return provider.Opened{Session: session, Options: []provider.ConfigOption{{ID: "mode", Type: provider.ConfigOptionTypeSelect, Category: provider.ConfigOptionCategoryMode, CurrentValue: "full"}}}, nil
}

func (f *fakeInstance) Release(_ context.Context, session string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.live, session)
	return nil
}

func (f *fakeInstance) Send(ctx context.Context, session string, in provider.SendInput) (provider.SendAck, error) {
	f.mu.Lock()
	f.received = append(f.received, fakeReceived{session: session, in: in})
	onSend := f.onSend
	f.mu.Unlock()
	if onSend != nil {
		return onSend(f, session, in)
	}
	return f.answer(session, in, "answer to "+lastLine(in.Text))
}

func lastLine(text string) string {
	_, rest := provider.SplitMessage(text)
	if rest != "" {
		return rest
	}
	envelopes, _ := provider.SplitMessage(text)
	if len(envelopes) > 0 {
		return envelopes[len(envelopes)-1].Body
	}
	return text
}

// answer runs a turn that answers the message with text, as a provider
// would: started, the user's message and the answer, settled.
func (f *fakeInstance) answer(session string, in provider.SendInput, text string) (provider.SendAck, error) {
	turn := in.Delivery
	f.startTurn(session, turn, in)
	go func() {
		f.entry(session, provider.Entry{Ref: turn + "/a", Turn: turn, Kind: provider.ItemKindAssistantMessage, Status: provider.ItemStatusCompleted, Text: text})
		f.settle(session, turn, provider.TurnCompleted)
	}()
	return provider.SendAck{Turn: turn}, nil
}

// startTurn records and reports a turn a message started.
func (f *fakeInstance) startTurn(session, turn string, in provider.SendInput) {
	f.mu.Lock()
	native := f.sessions[session]
	native.delivered[in.Delivery] = true
	entries := provider.UserMessageEntries(turn+"/user", turn, in.Text, nil, in.Delivery, time.Time{})
	native.turns = append(native.turns, provider.HistoryTurn{Ref: turn, State: provider.TurnRunning, Entries: entries})
	f.mu.Unlock()
	f.send(session, provider.TurnStarted{Turn: turn, By: provider.TurnByClient, Delivery: in.Delivery})
	for _, entry := range entries {
		f.send(session, provider.EntryUpserted{Entry: entry})
	}
}

func (f *fakeInstance) entry(session string, entry provider.Entry) {
	f.mu.Lock()
	if native := f.sessions[session]; native != nil {
		for index := range native.turns {
			if native.turns[index].Ref == entry.Turn {
				turn := &native.turns[index]
				if at := slices.IndexFunc(turn.Entries, func(existing provider.Entry) bool { return existing.Ref == entry.Ref }); at >= 0 {
					turn.Entries[at] = entry
				} else {
					turn.Entries = append(turn.Entries, entry)
				}
			}
		}
	}
	f.mu.Unlock()
	f.send(session, provider.EntryUpserted{Entry: entry})
}

func (f *fakeInstance) settle(session, turn string, state provider.TurnState) {
	f.mu.Lock()
	if native := f.sessions[session]; native != nil {
		for index := range native.turns {
			if native.turns[index].Ref == turn {
				native.turns[index].State = state
			}
		}
	}
	f.mu.Unlock()
	f.send(session, provider.TurnSettled{Turn: turn, State: state})
}

func (f *fakeInstance) send(session string, body provider.EventBody) {
	f.mu.Lock()
	emit := f.emit
	f.mu.Unlock()
	if emit != nil {
		emit(provider.Event{Session: session, At: time.Now(), Body: body})
	}
}

func (f *fakeInstance) Interrupt(_ context.Context, session, turn string) error {
	f.mu.Lock()
	f.interrupts = append(f.interrupts, turn)
	f.mu.Unlock()
	go func() {
		if f.interruptGate != nil {
			<-f.interruptGate
		}
		f.settle(session, turn, provider.TurnInterrupted)
	}()
	return nil
}

func (f *fakeInstance) Respond(_ context.Context, session, request string, answer provider.RequestAnswer) error {
	f.mu.Lock()
	f.responses = append(f.responses, answer)
	f.mu.Unlock()
	go f.send(session, provider.RequestResolved{Request: request, Action: answer.Action.ID, Answers: answer.Answers})
	return nil
}

func (f *fakeInstance) Configure(context.Context, string, provider.ConfigOptionSelection) error {
	return nil
}

func (f *fakeInstance) History(_ context.Context, session string, _ provider.Workspace, after provider.Marker) (provider.HistoryPage, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	native := f.sessions[session]
	if native == nil {
		return provider.HistoryPage{}, provider.ErrSessionNotFound
	}
	return provider.After(slices.Clone(native.turns), after), nil
}

func (f *fakeInstance) Delivered(_ context.Context, session string, probe provider.DeliveryProbe) (provider.Tri, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if native := f.sessions[session]; native != nil && native.delivered[probe.Delivery] {
		return provider.TriYes, nil
	}
	return provider.TriNo, nil
}

func (f *fakeInstance) Fork(_ context.Context, in provider.ForkInput) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	source := f.sessions[in.Session]
	if source == nil {
		return "", provider.ErrSessionNotFound
	}
	fork := &fakeSession{delivered: make(map[string]bool)}
	for _, turn := range source.turns {
		copied := turn
		copied.Ref = "fork-" + turn.Ref
		copied.Entries = nil
		for _, entry := range turn.Entries {
			entry.Ref, entry.Turn = "fork-"+entry.Ref, copied.Ref
			copied.Entries = append(copied.Entries, entry)
		}
		fork.turns = append(fork.turns, copied)
		if turn.Ref == in.Through {
			break
		}
	}
	session := fmt.Sprintf("%s-session-%d", f.info.InstanceID, len(f.sessions)+1)
	f.sessions[session] = fork
	return session, nil
}

func (f *fakeInstance) Rename(context.Context, string, string) error { return nil }

func (f *fakeInstance) messages() []fakeReceived {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.received)
}

// fakeProviders serves fake instances; unavailable ones fail to start.
type fakeProviders struct {
	mu          sync.Mutex
	instances   map[provider.InstanceID]*fakeInstance
	unavailable map[provider.InstanceID]bool
	engine      *Engine
	generation  uint64
}

func newFakeProviders(instances ...*fakeInstance) *fakeProviders {
	providers := &fakeProviders{instances: make(map[provider.InstanceID]*fakeInstance), unavailable: make(map[provider.InstanceID]bool), generation: 1}
	for _, instance := range instances {
		providers.instances[instance.info.InstanceID] = instance
	}
	return providers
}

func (p *fakeProviders) Instance(_ context.Context, id provider.InstanceID, _ string) (provider.Instance, uint64, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	instance := p.instances[id]
	if instance == nil || p.unavailable[id] {
		return nil, 0, errors.New("instance unavailable")
	}
	engine, generation := p.engine, p.generation
	instance.mu.Lock()
	instance.emit = func(event provider.Event) { engine.ProviderEvent(id, generation, event) }
	instance.mu.Unlock()
	return instance, generation, nil
}

func (p *fakeProviders) Info(id provider.InstanceID) (provider.InstanceInfo, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	instance := p.instances[id]
	if instance == nil {
		return provider.InstanceInfo{}, false
	}
	return instance.Info(), true
}

// harness is an engine on a data directory that survives restarts.
type harness struct {
	t         *testing.T
	dir       string
	providers *fakeProviders
	engine    *Engine
	sub       *Subscription
	sink      *recordingSink
	device    Actor
}

func newHarness(t *testing.T, instances ...*fakeInstance) *harness {
	t.Helper()
	h := &harness{t: t, dir: t.TempDir(), providers: newFakeProviders(instances...), device: Person("test-device")}
	h.start()
	// Chats work in a project; the harness's chats work in its directory.
	project, err := h.engine.AddProject(context.Background(), h.dir)
	if err != nil {
		t.Fatal(err)
	}
	h.dir = project.Path
	return h
}

func (h *harness) start() {
	h.t.Helper()
	path := filepath.Join(h.dir, "maid.db")
	handle, err := sql.Open("sqlite", "file:"+url.PathEscape(path)+"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)&_txlock=immediate")
	if err != nil {
		h.t.Fatal(err)
	}
	engine, err := Open(Config{DB: handle, Providers: h.providers, DataDir: h.dir})
	if err != nil {
		h.t.Fatal(err)
	}
	h.providers.mu.Lock()
	h.providers.engine = engine
	h.providers.generation++
	h.providers.mu.Unlock()
	h.engine = engine
	h.sink = &recordingSink{}
	h.sub = engine.Subscribe(h.sink)
	h.t.Cleanup(func() {
		engine.Close()
		_ = handle.Close()
	})
}

// restart stops the engine as a crash would and starts it again on the
// same data.
func (h *harness) restart() {
	h.t.Helper()
	h.engine.Close()
	for _, instance := range h.providers.instances {
		instance.mu.Lock()
		instance.live = make(map[string]bool)
		instance.mu.Unlock()
	}
	h.start()
}

func (h *harness) do(body CommandBody) CommandResult {
	h.t.Helper()
	result, err := h.engine.Do(context.Background(), Command{Actor: h.device, Body: body})
	if err != nil {
		h.t.Fatalf("%T: %v", body, err)
	}
	return result
}

func (h *harness) doAs(actor Actor, body CommandBody) (CommandResult, error) {
	return h.engine.Do(context.Background(), Command{Actor: actor, Body: body})
}

// snapshot opens a thread as a client does: sync, then subscribe.
func (h *harness) snapshot(thread ThreadID) ThreadSnapshot {
	h.t.Helper()
	if err := h.engine.Sync(context.Background(), thread); err != nil {
		h.t.Fatalf("sync %s: %v", thread, err)
	}
	snapshot, err := h.sub.Thread(context.Background(), thread)
	if err != nil {
		h.t.Fatalf("subscribe %s: %v", thread, err)
	}
	return snapshot
}

// eventually waits until done holds.
func (h *harness) eventually(desc string, done func() bool) {
	h.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !done() {
		if time.Now().After(deadline) {
			h.t.Fatalf("timed out waiting for %s", desc)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// settledTurns waits until the thread has n settled turns and nothing
// running, and returns its snapshot.
func (h *harness) settledTurns(thread ThreadID, n int) ThreadSnapshot {
	h.t.Helper()
	var snapshot ThreadSnapshot
	h.eventually(fmt.Sprintf("%d settled turns of %s", n, thread), func() bool {
		snapshot = h.snapshot(thread)
		settled := 0
		for _, turn := range snapshot.Turns {
			if turn.State.Settled() {
				settled++
			}
		}
		return settled >= n && snapshot.Thread.Status != StatusRunning
	})
	return snapshot
}

// rerunRules changes a thread so the engine's rules run for it. Steps run one
// at a time and rules queue what they send within their step, so anything they
// would still send is in a snapshot taken after this.
func (h *harness) rerunRules(thread ThreadID) {
	h.t.Helper()
	read := true
	h.do(UpdateThread{Thread: thread, Read: &read})
}

// pauseWaiting reports whether the engine has one pause, not yet in effect.
func (h *harness) pauseWaiting() bool {
	h.t.Helper()
	waiting, err := call(context.Background(), h.engine, func(*step) (bool, error) {
		return len(h.engine.pauses) == 1 && !h.engine.pauses[0].active, nil
	})
	if err != nil {
		h.t.Fatal(err)
	}
	return waiting
}

func (h *harness) createThread(instance provider.InstanceID, prompt string) CommandResult {
	h.t.Helper()
	create := CreateThread{Workspace: provider.Workspace{Cwd: h.dir}, Participant: NewParticipant{Instance: instance}}
	if prompt != "" {
		create.Prompt = &MessageBody{Text: prompt}
	}
	return h.do(create)
}

type recordingSink struct {
	mu       sync.Mutex
	events   []ThreadEvent
	list     []ThreadListItem
	projects []ProjectList
}

func (r *recordingSink) ThreadEvent(event ThreadEvent) {
	r.mu.Lock()
	r.events = append(r.events, event)
	r.mu.Unlock()
}

func (r *recordingSink) ThreadList(item ThreadListItem) {
	r.mu.Lock()
	r.list = append(r.list, item)
	r.mu.Unlock()
}

func (r *recordingSink) ProjectList(list ProjectList) {
	r.mu.Lock()
	r.projects = append(r.projects, list)
	r.mu.Unlock()
}

func texts(turn TurnView) []string {
	var out []string
	for _, entry := range turn.Entries {
		switch {
		case entry.Text != "":
			out = append(out, string(entry.Kind)+": "+entry.Text)
		case entry.Envelope != nil:
			out = append(out, "envelope "+string(entry.Envelope.Kind)+": "+entry.Envelope.Body)
		}
	}
	return out
}

func joined(lines []string) string { return strings.Join(lines, " | ") }
