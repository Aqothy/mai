package orchestration

import (
	"context"
	"encoding/json"
	"reflect"
	"slices"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// Client views. Required arrays are never null.

type ThreadStatus string

const (
	StatusRunning ThreadStatus = "running"
	// StatusWaiting: an agent asks the user something.
	StatusWaiting ThreadStatus = "waiting"
	// StatusHeld: deliveries wait for someone to release the thread.
	StatusHeld ThreadStatus = "held"
	StatusIdle ThreadStatus = "idle"
)

// Attention is what a thread, or a thread below it, needs from the user.
type Attention struct {
	// NeedsInput: an agent asks something, a delivery wasn't delivered, or
	// agents went back and forth too long.
	NeedsInput bool `json:"needsInput"`
	// Failed: its latest turn failed.
	Failed bool `json:"failed"`
	// Unread: it changed since the user last viewed it.
	Unread bool `json:"unread"`
}

type OriginSummary struct {
	Kind         OriginKind    `json:"kind"`
	Parent       ThreadID      `json:"parent,omitempty"`
	By           ParticipantID `json:"by,omitempty"`
	At           string        `json:"at,omitempty"`
	ForkedFrom   *ForkPoint    `json:"forkedFrom,omitempty"`
	AcceptsInput bool          `json:"acceptsInput"`
	Brief        string        `json:"brief,omitempty"`
}

type ParticipantSummary struct {
	ID       ParticipantID       `json:"id"`
	Instance provider.InstanceID `json:"instance"`
	Name     string              `json:"name"`
	Driver   provider.DriverKind `json:"driver"`
	Model    string              `json:"model,omitempty"`
}

// ThreadSummary is a thread in the thread list.
type ThreadSummary struct {
	ID           ThreadID             `json:"id"`
	Title        string               `json:"title"`
	Workspace    provider.Workspace   `json:"workspace"`
	Origin       OriginSummary        `json:"origin"`
	Participants []ParticipantSummary `json:"participants"`
	Address      ParticipantID        `json:"address,omitempty"`
	Status       ThreadStatus         `json:"status"`
	Hold         Hold                 `json:"hold,omitempty"`
	Attention    Attention            `json:"attention"`
	Children     int                  `json:"children"`
	CreatedAt    time.Time            `json:"createdAt"`
	UpdatedAt    time.Time            `json:"updatedAt"`
}

// ParticipantView is a participant with what its provider says now.
type ParticipantView struct {
	ParticipantSummary
	Settings []provider.ConfigOptionSelection `json:"settings"`
	// Options are its session's config options while it is live.
	Options  []provider.ConfigOption `json:"options"`
	Commands []provider.SlashCommand `json:"commands"`
	Skills   []provider.Skill        `json:"skills"`
	Goal     *provider.Goal          `json:"goal,omitempty"`
	Usage    *provider.TokenUsage    `json:"usage,omitempty"`
	Live     bool                    `json:"live"`
	Access   provider.AccessLevel    `json:"access,omitempty"`
}

type TurnView struct {
	ID          TurnID              `json:"id"`
	Participant ParticipantID       `json:"participant"`
	StartedBy   StartedBy           `json:"startedBy"`
	State       provider.TurnState  `json:"state"`
	StopReason  provider.StopReason `json:"stopReason,omitempty"`
	Error       string              `json:"error,omitempty"`
	StartedAt   time.Time           `json:"startedAt"`
	SettledAt   *time.Time          `json:"settledAt,omitempty"`
	Entries     []EntryView         `json:"entries"`
}

// EntryView is an entry, bounded: tool calls as previews, attachments
// without data, long envelopes cut. ThreadEntry reads the whole entry.
type EntryView struct {
	Ref             string                      `json:"ref"`
	Kind            provider.ItemKind           `json:"kind"`
	Status          provider.ItemStatus         `json:"status,omitempty"`
	Title           string                      `json:"title,omitempty"`
	Text            string                      `json:"text,omitempty"`
	Attachments     []provider.Attachment       `json:"attachments,omitempty"`
	Annotations     []provider.PromptAnnotation `json:"annotations,omitempty"`
	Tool            *ToolCallSummary            `json:"tool,omitempty"`
	Envelope        *provider.Envelope          `json:"envelope,omitempty"`
	Request         *provider.RequestRecord     `json:"request,omitempty"`
	Delivery        string                      `json:"delivery,omitempty"`
	At              time.Time                   `json:"at,omitzero"`
	DetailAvailable bool                        `json:"detailAvailable,omitempty"`
}

// ActorView names who sent a delivery.
type ActorView struct {
	Kind        ActorKind     `json:"kind"`
	Thread      ThreadID      `json:"thread,omitempty"`
	Participant ParticipantID `json:"participant,omitempty"`
	Name        string        `json:"name"`
}

type DeliveryView struct {
	ID          DeliveryID                  `json:"id"`
	To          ParticipantID               `json:"to"`
	From        ActorView                   `json:"from"`
	Kind        DeliveryKind                `json:"kind"`
	Mode        DeliveryMode                `json:"mode"`
	State       DeliveryState               `json:"state"`
	Text        string                      `json:"text,omitempty"`
	Attachments []provider.Attachment       `json:"attachments,omitempty"`
	Annotations []provider.PromptAnnotation `json:"annotations,omitempty"`
	Reason      string                      `json:"reason,omitempty"`
	Answers     DeliveryID                  `json:"answers,omitempty"`
	Turn        TurnID                      `json:"turn,omitempty"`
	CreatedAt   time.Time                   `json:"createdAt"`
	// Position orders the queue, lowest first.
	Position float64 `json:"position"`
}

type RequestView struct {
	ID          string           `json:"id"`
	Participant ParticipantID    `json:"participant"`
	Turn        TurnID           `json:"turn,omitempty"`
	Entry       string           `json:"entry,omitempty"`
	Ask         provider.Request `json:"ask"`
	OpenedAt    time.Time        `json:"openedAt"`
	// Answering is the action an answer chose while the provider takes it.
	Answering string `json:"answering,omitempty"`
}

// ThreadSnapshot is a thread as a subscriber starts from: the newest turns
// that fit its budget, older ones a ThreadTurns read away.
type ThreadSnapshot struct {
	Seq          uint64               `json:"seq"`
	Thread       ThreadSummary        `json:"thread"`
	Participants []ParticipantView    `json:"participants"`
	Turns        []TurnView           `json:"turns"`
	Older        TurnID               `json:"older,omitempty"`
	Queue        []DeliveryView       `json:"queue"`
	Requests     []RequestView        `json:"requests"`
	Children     []ThreadSummary      `json:"children"`
	Plan         []provider.PlanEntry `json:"plan"`
}

type ThreadEventKind string

const (
	EventEntry       ThreadEventKind = "entry"
	EventText        ThreadEventKind = "text"
	EventTurn        ThreadEventKind = "turn"
	EventDelivery    ThreadEventKind = "delivery"
	EventRequest     ThreadEventKind = "request"
	EventResolved    ThreadEventKind = "resolved"
	EventParticipant ThreadEventKind = "participant"
	EventThread      ThreadEventKind = "thread"
	EventChild       ThreadEventKind = "child"
	EventPlan        ThreadEventKind = "plan"
	// EventRefresh: the thread's history changed under the subscriber
	// (reconciled, rebuilt); it subscribes again.
	EventRefresh ThreadEventKind = "refresh"
	EventRemoved ThreadEventKind = "removed"
)

// ThreadEvent is one change to a subscribed thread, after the snapshot of Seq
// before it.
type ThreadEvent struct {
	Seq         uint64               `json:"seq"`
	Thread      ThreadID             `json:"thread"`
	Kind        ThreadEventKind      `json:"kind"`
	Turn        *TurnView            `json:"turn,omitempty"`
	Entry       *EntryView           `json:"entry,omitempty"`
	Text        *TextAppend          `json:"text,omitempty"`
	Delivery    *DeliveryView        `json:"delivery,omitempty"`
	Request     *RequestView         `json:"request,omitempty"`
	Resolved    *RequestResolution   `json:"resolved,omitempty"`
	Participant *ParticipantView     `json:"participant,omitempty"`
	Summary     *ThreadSummary       `json:"summary,omitempty"`
	Plan        []provider.PlanEntry `json:"plan,omitempty"`
}

// TextAppend streams text onto an entry of a turn.
type TextAppend struct {
	Turn   TurnID              `json:"turn"`
	Entry  string              `json:"entry"`
	Stream provider.StreamKind `json:"stream"`
	Text   string              `json:"text"`
}

type RequestResolution struct {
	Request string                 `json:"request"`
	Record  provider.RequestRecord `json:"record"`
}

type ThreadListKind string

const (
	ListSnapshot ThreadListKind = "snapshot"
	ListUpsert   ThreadListKind = "upsert"
	ListRemove   ThreadListKind = "remove"
)

// ThreadListItem is the thread list's snapshot or one change to it.
type ThreadListItem struct {
	Seq     uint64          `json:"seq"`
	Kind    ThreadListKind  `json:"kind"`
	Threads []ThreadSummary `json:"threads,omitempty"`
	Thread  *ThreadSummary  `json:"thread,omitempty"`
	Removed ThreadID        `json:"removed,omitempty"`
}

// Sink receives a subscriber's updates on the engine goroutine; it must not
// block.
type Sink interface {
	ThreadEvent(ThreadEvent)
	ThreadList(ThreadListItem)
}

type subscriber struct {
	sink    Sink
	list    bool
	threads map[ThreadID]bool
}

// Subscription is one client's updates.
type Subscription struct {
	e  *Engine
	id uint64
}

// Subscribe registers a sink that gets nothing until it subscribes to the
// list or threads.
func (e *Engine) Subscribe(sink Sink) *Subscription {
	id, _ := call(context.Background(), e, func(s *step) (uint64, error) {
		e.nextSub++
		e.subscribers[e.nextSub] = &subscriber{sink: sink, threads: make(map[ThreadID]bool)}
		return e.nextSub, nil
	})
	return &Subscription{e: e, id: id}
}

func (sub *Subscription) Close() {
	sub.e.post(func(s *step) { delete(sub.e.subscribers, sub.id) })
}

// List subscribes to the thread list and returns its snapshot.
func (sub *Subscription) List(ctx context.Context) (ThreadListItem, error) {
	e := sub.e
	return call(ctx, e, func(s *step) (ThreadListItem, error) {
		subscriber := e.subscribers[sub.id]
		if subscriber == nil {
			return ThreadListItem{}, errClosed
		}
		subscriber.list = true
		threads := make([]ThreadSummary, 0, len(e.threads))
		for _, thread := range e.threads {
			threads = append(threads, e.summary(thread))
		}
		slices.SortFunc(threads, func(a, b ThreadSummary) int { return b.UpdatedAt.Compare(a.UpdatedAt) })
		return ThreadListItem{Seq: e.seq, Kind: ListSnapshot, Threads: threads}, nil
	})
}

// snapshot budget: the newest turns up to these bounds.
const (
	snapshotTurns   = 40
	snapshotEntries = 600
)

// syncWait is how long Sync waits for a thread's sessions' history: reading
// what's new usually takes milliseconds, a rebuild longer.
const syncWait = 2 * time.Second

// Sync brings a thread's cache up to its sessions' history (turns run in the
// CLI, a rebuild for another adapter version) and returns once it has, or
// after syncWait; a read still going then refreshes the thread's
// subscribers when it ends. Clients call it before subscribing, and on
// returning to a chat they still watch, so a chat shows caught up.
func (e *Engine) Sync(ctx context.Context, id ThreadID) error {
	caughtUp, err := call(ctx, e, func(s *step) (chan struct{}, error) {
		thread, err := e.existing(id)
		if err != nil {
			return nil, err
		}
		return e.catchUp(s, thread), nil
	})
	if err != nil {
		return err
	}
	wait := time.NewTimer(syncWait)
	defer wait.Stop()
	select {
	case <-caughtUp:
	case <-wait.C:
	case <-ctx.Done():
		return ctx.Err()
	}
	return nil
}

// Thread subscribes to a thread and returns its snapshot from the cache, as
// Sync left it. Events after the snapshot's Seq follow; settled turns'
// entries are read from the cache off the engine, so opening a long chat
// costs the engine almost nothing.
func (sub *Subscription) Thread(ctx context.Context, id ThreadID) (ThreadSnapshot, error) {
	e := sub.e
	type captured struct {
		snapshot ThreadSnapshot
		load     []turnLoad
	}
	out, err := call(ctx, e, func(s *step) (captured, error) {
		subscriber := e.subscribers[sub.id]
		if subscriber == nil {
			return captured{}, errClosed
		}
		thread, err := e.existing(id)
		if err != nil {
			return captured{}, err
		}
		subscriber.threads[id] = true
		snapshot := ThreadSnapshot{
			Seq: e.seq, Thread: e.summary(thread), Participants: []ParticipantView{}, Queue: []DeliveryView{},
			Requests: []RequestView{}, Children: []ThreadSummary{}, Plan: slices.Clone(thread.plan),
		}
		if snapshot.Plan == nil {
			snapshot.Plan = []provider.PlanEntry{}
		}
		for _, pid := range thread.participants {
			snapshot.Participants = append(snapshot.Participants, e.participantView(e.participants[pid]))
		}
		for _, delivery := range thread.queue {
			snapshot.Queue = append(snapshot.Queue, e.deliveryView(delivery))
		}
		for _, request := range sortedRequests(thread) {
			snapshot.Requests = append(snapshot.Requests, requestView(request))
		}
		for _, child := range thread.children {
			if childThread := e.threads[child]; childThread != nil {
				snapshot.Children = append(snapshot.Children, e.summary(childThread))
			}
		}
		turns, err := e.db.threadTurns(e.ctx, id, nil, snapshotTurns+1)
		if err != nil {
			return captured{}, err
		}
		if len(turns) > snapshotTurns {
			turns = turns[1:]
			snapshot.Older = turns[0].ID
		}
		var load []turnLoad
		for index, turn := range turns {
			view := turnView(turn)
			if thread.entries != nil && thread.entries.turn == turn.ID {
				view.Entries = entryViews(thread.entries.list())
			} else if participant := e.participants[turn.Participant]; participant != nil {
				load = append(load, turnLoad{index: index, instance: participant.Instance, session: turn.Session, ref: turn.Ref})
			}
			snapshot.Turns = append(snapshot.Turns, view)
		}
		if snapshot.Turns == nil {
			snapshot.Turns = []TurnView{}
		}
		return captured{snapshot: snapshot, load: load}, nil
	})
	if err != nil {
		return ThreadSnapshot{}, err
	}
	snapshot := out.snapshot
	// Newest first, within the entry budget; the newest turn shows however
	// large it is.
	budget := snapshotEntries
	for index := len(out.load) - 1; index >= 0; index-- {
		load := out.load[index]
		entries, err := e.db.turnEntries(ctx, load.instance, load.session, load.ref)
		if err != nil {
			return ThreadSnapshot{}, err
		}
		if budget -= len(entries); budget < 0 && load.index+1 < len(snapshot.Turns) {
			snapshot.Turns = snapshot.Turns[load.index+1:]
			snapshot.Older = snapshot.Turns[0].ID
			break
		}
		snapshot.Turns[load.index].Entries = entryViews(entries)
	}
	return snapshot, nil
}

type turnLoad struct {
	index    int
	instance provider.InstanceID
	session  string
	ref      string
}

// Unsubscribe stops a thread's events.
func (sub *Subscription) Unsubscribe(id ThreadID) {
	sub.e.post(func(s *step) {
		if subscriber := sub.e.subscribers[sub.id]; subscriber != nil {
			delete(subscriber.threads, id)
		}
	})
}

// Turns pages a thread's turns before a turn, oldest first, from the cache.
func (e *Engine) Turns(ctx context.Context, id ThreadID, before TurnID, limit int) ([]TurnView, TurnID, error) {
	if limit <= 0 || limit > snapshotTurns {
		limit = snapshotTurns
	}
	var anchor *Turn
	if before != "" {
		turn, ok, err := e.db.turn(ctx, before)
		if err != nil {
			return nil, "", err
		}
		if !ok || turn.Thread != id {
			return nil, "", refused(CodeNotFound, "turn %q isn't in thread %q", before, id)
		}
		anchor = &turn
	}
	turns, err := e.db.threadTurns(ctx, id, anchor, limit+1)
	if err != nil {
		return nil, "", err
	}
	var older TurnID
	if len(turns) > limit {
		turns = turns[1:]
		older = turns[0].ID
	}
	instances, err := e.db.participantInstances(ctx, id)
	if err != nil {
		return nil, "", err
	}
	views := make([]TurnView, 0, len(turns))
	for _, turn := range turns {
		view := turnView(turn)
		entries, err := e.db.turnEntries(ctx, instances[turn.Participant], turn.Session, turn.Ref)
		if err != nil {
			return nil, "", err
		}
		view.Entries = entryViews(entries)
		views = append(views, view)
	}
	return views, older, nil
}

// Entry is one whole entry of a thread: a full tool output, diff or handoff.
func (e *Engine) Entry(ctx context.Context, id ThreadID, ref string) (provider.Entry, error) {
	type location struct {
		instance provider.InstanceID
		session  string
	}
	type found struct {
		entry     *provider.Entry
		locations []location
	}
	out, err := call(ctx, e, func(s *step) (found, error) {
		thread, err := e.existing(id)
		if err != nil {
			return found{}, err
		}
		if thread.entries != nil {
			if entry := thread.entries.byRef[ref]; entry != nil {
				copied := *entry
				return found{entry: &copied}, nil
			}
		}
		var locations []location
		for _, pid := range thread.participants {
			participant := e.participants[pid]
			if participant.Session != "" {
				locations = append(locations, location{participant.Instance, participant.Session})
			}
		}
		return found{locations: locations}, nil
	})
	if err != nil {
		return provider.Entry{}, err
	}
	if out.entry != nil {
		return *out.entry, nil
	}
	for _, location := range out.locations {
		if entry, ok, err := e.db.sessionEntry(ctx, location.instance, location.session, ref); err != nil {
			return provider.Entry{}, err
		} else if ok {
			return entry, nil
		}
	}
	// An entry of a session the participant has since left (/clear, a new
	// session) is found through its turn.
	if entry, ok, err := e.db.threadEntry(ctx, id, ref); err != nil || ok {
		return entry, err
	}
	return provider.Entry{}, refused(CodeNotFound, "entry %q isn't in thread %q", ref, id)
}

// findEntry is an entry of the thread's running turn, or of its cache.
func (e *Engine) findEntry(thread *threadState, ref string) (provider.Entry, *Turn, error) {
	if thread.entries != nil {
		if entry := thread.entries.byRef[ref]; entry != nil {
			return *entry, thread.latest, nil
		}
	}
	entry, ok, err := e.db.threadEntry(e.ctx, thread.ID, ref)
	if err != nil {
		return provider.Entry{}, nil, err
	}
	if !ok {
		return provider.Entry{}, nil, refused(CodeNotFound, "entry %q isn't in this chat", ref)
	}
	turn, found := e.turnOfEntry(thread, entry)
	if !found {
		return provider.Entry{}, nil, refused(CodeNotFound, "entry %q has no turn", ref)
	}
	return entry, turn, nil
}

func (e *Engine) turnOfEntry(thread *threadState, entry provider.Entry) (*Turn, bool) {
	for _, pid := range thread.participants {
		participant := e.participants[pid]
		if turn := e.turnFor(thread, participant, entry.Turn); turn != nil {
			return turn, true
		}
	}
	return nil, false
}

// Derived state.

func (e *Engine) status(thread *threadState) ThreadStatus {
	switch {
	case thread.running():
		return StatusRunning
	case len(thread.requests) > 0:
		return StatusWaiting
	// Held while anything waits on whoever may release it: queued messages,
	// or one that wasn't delivered.
	case thread.Hold != HoldNone && len(thread.queue) > 0:
		return StatusHeld
	}
	return StatusIdle
}

func (e *Engine) attention(thread *threadState) Attention {
	attention := Attention{
		Failed: thread.latest != nil && thread.latest.State == provider.TurnFailed,
		// A turn settled since a person last read it.
		Unread: thread.latest != nil && thread.latest.State.Settled() && thread.latest.SettledAt.After(thread.SeenAt),
	}
	for _, candidate := range append([]*threadState{thread}, e.descendants(thread)...) {
		if len(candidate.requests) > 0 || candidate.Hold == HoldHops || slices.ContainsFunc(candidate.queue, func(delivery *Delivery) bool { return delivery.State == DeliveryRefused }) {
			attention.NeedsInput = true
			break
		}
	}
	return attention
}

func (e *Engine) summary(thread *threadState) ThreadSummary {
	summary := ThreadSummary{
		ID: thread.ID, Title: thread.Title, Workspace: thread.Workspace, Address: thread.Address,
		Origin: OriginSummary{
			Kind: thread.Origin.Kind, Parent: thread.Origin.Parent, By: thread.Origin.By, At: thread.Origin.At,
			ForkedFrom: thread.Origin.ForkedFrom, AcceptsInput: thread.Origin.Kind != OriginNative || thread.Origin.AcceptsInput,
		},
		Participants: []ParticipantSummary{}, Status: e.status(thread), Hold: thread.Hold, Attention: e.attention(thread),
		Children: len(thread.children), CreatedAt: thread.CreatedAt, UpdatedAt: thread.UpdatedAt,
	}
	if thread.Workspace.AdditionalDirectories == nil {
		summary.Workspace.AdditionalDirectories = []string{}
	}
	if contract := thread.Origin.Contract; contract != nil {
		summary.Origin.Brief = contract.Brief
	}
	for _, pid := range thread.participants {
		summary.Participants = append(summary.Participants, e.participantSummary(e.participants[pid]))
	}
	return summary
}

func (e *Engine) participantSummary(participant *participantState) ParticipantSummary {
	info := e.instanceInfo(participant.Instance)
	summary := ParticipantSummary{ID: participant.ID, Instance: participant.Instance, Name: firstNonEmpty(info.Name, string(participant.Instance)), Driver: info.Driver}
	for _, option := range participant.options {
		if option.Category == provider.ConfigOptionCategoryModel {
			summary.Model, _ = option.CurrentValue.(string)
		}
	}
	if summary.Model == "" {
		for _, setting := range participant.Settings {
			if setting.Category == provider.ConfigOptionCategoryModel {
				summary.Model, _ = setting.Value.(string)
			}
		}
	}
	return summary
}

func (e *Engine) participantView(participant *participantState) ParticipantView {
	view := ParticipantView{
		ParticipantSummary: e.participantSummary(participant),
		Settings:           orEmpty(participant.Settings), Options: orEmpty(participant.options),
		Commands: orEmpty(participant.commands), Skills: orEmpty(participant.skills),
		Goal: participant.goal, Usage: participant.usage, Live: participant.live != nil, Access: e.accessLevel(participant),
	}
	return view
}

func orEmpty[T any](values []T) []T {
	if values == nil {
		return []T{}
	}
	return values
}

func turnView(turn Turn) TurnView {
	view := TurnView{
		ID: turn.ID, Participant: turn.Participant, StartedBy: turn.StartedBy, State: turn.State, StopReason: turn.StopReason,
		Error: turn.Error, StartedAt: turn.StartedAt, Entries: []EntryView{},
	}
	if !turn.SettledAt.IsZero() {
		settled := turn.SettledAt
		view.SettledAt = &settled
	}
	return view
}

// envelopePreviewBytes bounds an envelope's body in views; a handoff can be
// a whole conversation.
const envelopePreviewBytes = 2048

func entryView(entry provider.Entry) EntryView {
	view := EntryView{
		Ref: entry.Ref, Kind: entry.Kind, Status: entry.Status, Title: entry.Title, Text: entry.Text,
		Attachments: entry.Attachments, Annotations: entry.Annotations, Request: entry.Request, Delivery: entry.Delivery, At: entry.At,
	}
	if entry.Tool != nil {
		view.Tool = summarizeToolCall(entry.Tool)
		view.DetailAvailable = true
	}
	if entry.Envelope != nil {
		envelope := *entry.Envelope
		if len(envelope.Body) > envelopePreviewBytes {
			envelope.Body = provider.TruncateUTF8(envelope.Body, envelopePreviewBytes)
			view.DetailAvailable = true
		}
		view.Envelope = &envelope
	}
	return view
}

func entryViews(entries []provider.Entry) []EntryView {
	views := make([]EntryView, 0, len(entries))
	for _, entry := range entries {
		views = append(views, entryView(entry))
	}
	return views
}

func (e *Engine) deliveryView(delivery *Delivery) DeliveryView {
	return DeliveryView{
		ID: delivery.ID, To: delivery.To, Kind: delivery.Kind, Mode: delivery.Mode, State: delivery.State,
		From: ActorView{Kind: delivery.From.Kind, Thread: delivery.From.Thread, Participant: delivery.From.Participant, Name: e.senderName(delivery.From)},
		Text: delivery.Body.Text, Attachments: delivery.Body.Attachments, Annotations: delivery.Body.Annotations,
		Reason: delivery.Reason, Answers: delivery.Answers, Turn: delivery.Turn, CreatedAt: delivery.CreatedAt,
		Position: delivery.Position,
	}
}

func requestView(request *pendingRequest) RequestView {
	return RequestView{ID: request.ID, Participant: request.Participant, Turn: request.Turn, Entry: request.Entry, Ask: request.Ask, OpenedAt: request.OpenedAt, Answering: request.answering}
}

func sortedRequests(thread *threadState) []*pendingRequest {
	requests := make([]*pendingRequest, 0, len(thread.requests))
	for _, request := range thread.requests {
		requests = append(requests, request)
	}
	slices.SortFunc(requests, func(a, b *pendingRequest) int { return a.OpenedAt.Compare(b.OpenedAt) })
	return requests
}

// Notifications go out once their step committed, in order.

func (e *Engine) emit(s *step, thread ThreadID, event ThreadEvent) {
	event.Thread = thread
	s.after(func() {
		e.seq++
		event.Seq = e.seq
		for _, subscriber := range e.subscribers {
			if subscriber.threads[thread] {
				subscriber.sink.ThreadEvent(event)
			}
		}
	})
}

func (e *Engine) notifyEntry(s *step, thread *threadState, turn *Turn, entry provider.Entry) {
	view := entryView(entry)
	turnView := turnView(*turn)
	e.emit(s, thread.ID, ThreadEvent{Kind: EventEntry, Turn: &turnView, Entry: &view})
}

func (e *Engine) notifyText(s *step, thread *threadState, appended provider.TextAppended) {
	e.emit(s, thread.ID, ThreadEvent{Kind: EventText, Text: &TextAppend{Turn: thread.latest.ID, Entry: appended.Entry, Stream: appended.Stream, Text: appended.Text}})
}

func (e *Engine) notifyTurn(s *step, thread *threadState, turn *Turn) {
	view := turnView(*turn)
	e.emit(s, thread.ID, ThreadEvent{Kind: EventTurn, Turn: &view})
}

func (e *Engine) notifyDelivery(s *step, thread *threadState, delivery *Delivery) {
	view := e.deliveryView(delivery)
	e.emit(s, thread.ID, ThreadEvent{Kind: EventDelivery, Delivery: &view})
	e.wakeWaits(s)
}

func (e *Engine) notifyRequest(s *step, thread *threadState, request *pendingRequest, record *provider.RequestRecord) {
	if record != nil {
		e.emit(s, thread.ID, ThreadEvent{Kind: EventResolved, Resolved: &RequestResolution{Request: request.ID, Record: *record}})
		return
	}
	view := requestView(request)
	e.emit(s, thread.ID, ThreadEvent{Kind: EventRequest, Request: &view})
}

func (e *Engine) notifyParticipant(s *step, thread *threadState, participant *participantState) {
	view := e.participantView(participant)
	e.emit(s, thread.ID, ThreadEvent{Kind: EventParticipant, Participant: &view})
	s.touch(thread.ID)
}

func (e *Engine) notifyPlan(s *step, thread *threadState) {
	e.emit(s, thread.ID, ThreadEvent{Kind: EventPlan, Plan: orEmpty(slices.Clone(thread.plan))})
}

func (e *Engine) notifyRefresh(s *step, thread *threadState) {
	e.emit(s, thread.ID, ThreadEvent{Kind: EventRefresh})
}

func (e *Engine) notifyRemoved(s *step, id ThreadID) {
	e.emit(s, id, ThreadEvent{Kind: EventRemoved})
	delete(e.published, id)
	s.after(func() {
		e.seq++
		item := ThreadListItem{Seq: e.seq, Kind: ListRemove, Removed: id}
		for _, subscriber := range e.subscribers {
			delete(subscriber.threads, id)
			if subscriber.list {
				subscriber.sink.ThreadList(item)
			}
		}
	})
}

// publishSummaries sends the summaries a step changed: to the list, to the
// thread's own subscribers, and to its parent's as a child.
func (e *Engine) publishSummaries(s *step) {
	due := make(map[ThreadID]bool)
	for id := range s.changed {
		if thread := e.threads[id]; thread != nil {
			due[id] = true
			for _, ancestor := range e.ancestors(thread) {
				due[ancestor.ID] = true
			}
		}
	}
	for id := range due {
		thread := e.threads[id]
		summary := e.summary(thread)
		if published, ok := e.published[id]; ok && reflect.DeepEqual(published, summary) {
			continue
		}
		e.published[id] = summary
		copied := summary
		e.emit(s, id, ThreadEvent{Kind: EventThread, Summary: &copied})
		if parent := thread.Origin.Parent; parent != "" {
			child := summary
			e.emit(s, parent, ThreadEvent{Kind: EventChild, Summary: &child})
		}
		s.after(func() {
			e.seq++
			item := ThreadListItem{Seq: e.seq, Kind: ListUpsert, Thread: &copied}
			for _, subscriber := range e.subscribers {
				if subscriber.list {
					subscriber.sink.ThreadList(item)
				}
			}
		})
	}
}

// Attachment is one attachment's data, by ID.
func (e *Engine) Attachment(id string) (provider.Attachment, error) {
	data, err := e.attachments.read(id)
	if err != nil {
		return provider.Attachment{}, err
	}
	return provider.Attachment{ID: id, Data: data}, nil
}

// StoreAttachment keeps data in the attachment store and returns its ID.
func (e *Engine) StoreAttachment(data string) (string, error) { return e.attachments.write(data) }

func mustJSON(value any) json.RawMessage {
	raw, _ := json.Marshal(value)
	return raw
}
