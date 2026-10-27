package orchestration

import (
	"slices"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// threadState is a thread as the engine holds it: its row and what the
// reactors and the thread list need, never its conversation.
type threadState struct {
	Thread
	participants []ParticipantID
	children     []ThreadID
	// latest is the thread's latest turn; running when one runs.
	latest *Turn
	// queue holds deliveries not done with: queued, sending, refused, in
	// position order.
	queue []*Delivery
	// awaiting are delivered messages owed a reply, oldest first.
	awaiting []*Delivery
	// requests are what its agents ask the user, open now.
	requests map[string]*pendingRequest
	// entries are the running turn's entries, in order, until its settle
	// writes them; dirty ones are written by the next flush.
	entries *liveEntries
	// interrupting: an interrupt of the running turn was asked for, by a
	// person or an agent (who decides the hold left on its queue).
	interrupting *Actor
	plan         []provider.PlanEntry
	// caughtUp are opens waiting for its sessions' history reads to end.
	caughtUp []chan struct{}
}

// pendingRequest is an open provider request. Its callbacks live with the
// provider process, so it is never stored.
type pendingRequest struct {
	ID          string
	Participant ParticipantID
	Turn        TurnID
	Entry       string
	Ask         provider.Request
	OpenedAt    time.Time
	// answering is the action an answer chose, once sent and until the
	// provider resolves the request.
	answering string
}

// liveEntries are a running turn's entries.
type liveEntries struct {
	turn  TurnID
	order []string
	byRef map[string]*provider.Entry
	dirty map[string]bool
}

func newLiveEntries(turn TurnID) *liveEntries {
	return &liveEntries{turn: turn, byRef: make(map[string]*provider.Entry), dirty: make(map[string]bool)}
}

func (l *liveEntries) upsert(entry provider.Entry) {
	if _, ok := l.byRef[entry.Ref]; !ok {
		l.order = append(l.order, entry.Ref)
	}
	copied := entry
	l.byRef[entry.Ref] = &copied
	l.dirty[entry.Ref] = true
}

func (l *liveEntries) append(ref, text string) bool {
	entry := l.byRef[ref]
	if entry == nil {
		return false
	}
	entry.Text += text
	l.dirty[ref] = true
	return true
}

func (l *liveEntries) list() []provider.Entry {
	entries := make([]provider.Entry, 0, len(l.order))
	for _, ref := range l.order {
		entries = append(entries, *l.byRef[ref])
	}
	return entries
}

// participantState is a participant with its live session and what the
// provider last said about it.
type participantState struct {
	Participant
	live *liveSession
	// opening: an Open of its session is in flight.
	opening bool
	worker  *worker
	// What the provider says of its session, kept while it lives.
	options  []provider.ConfigOption
	commands []provider.SlashCommand
	skills   []provider.Skill
	goal     *provider.Goal
	usage    *provider.TokenUsage
	// reconciling: a History read of its session is in flight.
	reconciling bool
}

type liveSession struct {
	generation uint64
}

func (e *Engine) install(loaded state) {
	for _, thread := range loaded.threads {
		e.threads[thread.ID] = &threadState{Thread: thread, requests: make(map[string]*pendingRequest)}
	}
	for _, thread := range e.threads {
		if parent := e.threads[thread.Origin.Parent]; parent != nil {
			parent.children = append(parent.children, thread.ID)
		}
	}
	for _, participant := range loaded.participants {
		state := &participantState{Participant: participant}
		e.participants[participant.ID] = state
		if thread := e.threads[participant.Thread]; thread != nil {
			thread.participants = append(thread.participants, participant.ID)
		}
		if participant.Session != "" {
			e.bySession[sessionKey{participant.Instance, participant.Session}] = participant.ID
		}
	}
	for _, turn := range loaded.turns {
		thread := e.threads[turn.Thread]
		if thread == nil {
			continue
		}
		turn := turn
		if thread.latest == nil || turnBefore(*thread.latest, turn) || turn.State == provider.TurnRunning {
			thread.latest = &turn
		}
	}
	for _, delivery := range loaded.deliveries {
		thread := e.threads[delivery.Thread]
		if thread == nil {
			continue
		}
		delivery := delivery
		if delivery.State == DeliveryDelivered {
			thread.awaiting = append(thread.awaiting, &delivery)
		} else {
			thread.queue = append(thread.queue, &delivery)
		}
	}
	for _, thread := range e.threads {
		sortQueue(thread.queue)
		slices.SortFunc(thread.awaiting, func(a, b *Delivery) int { return a.CreatedAt.Compare(b.CreatedAt) })
	}
}

// turnBefore orders turns for display: by start time, then ID.
func turnBefore(a, b Turn) bool {
	if !a.StartedAt.Equal(b.StartedAt) {
		return a.StartedAt.Before(b.StartedAt)
	}
	return a.ID < b.ID
}

func sortQueue(queue []*Delivery) {
	slices.SortStableFunc(queue, func(a, b *Delivery) int {
		switch {
		case a.Position < b.Position:
			return -1
		case a.Position > b.Position:
			return 1
		}
		return 0
	})
}

// Writes. Each records the row in the step's transaction and marks its
// thread for the reactors and the thread list.

func (s *step) putThread(thread *threadState) {
	s.tx.threads[thread.ID] = thread.Thread
	s.touch(thread.ID)
}

func (s *step) putParticipant(participant *participantState) {
	s.tx.participants[participant.ID] = participant.Participant
	s.touch(participant.Thread)
}

func (s *step) putTurn(turn *Turn) {
	s.tx.turns[turn.ID] = *turn
	s.touch(turn.Thread)
}

func (s *step) dropTurn(thread ThreadID, turn TurnID) {
	s.tx.droppedTurns = append(s.tx.droppedTurns, turn)
	s.touch(thread)
}

func (s *step) putDelivery(delivery *Delivery) {
	s.tx.deliveries[delivery.ID] = *delivery
	s.touch(delivery.Thread)
}

func (s *step) putEntries(instance provider.InstanceID, session string, authored authorship, entries ...provider.Entry) {
	for _, entry := range entries {
		// What the provider keeps no record of is maiD's to keep.
		by := authored
		if entry.Local {
			by = authoredByMaid
		}
		s.tx.entries = append(s.tx.entries, cachedEntry{instance: instance, session: session, entry: entry, authored: by})
	}
}

// running reports whether a thread runs: a turn runs or a delivery is on its
// way to the provider.
func (t *threadState) running() bool {
	if t.latest != nil && t.latest.State == provider.TurnRunning {
		return true
	}
	for _, delivery := range t.queue {
		if delivery.State == DeliverySending {
			return true
		}
	}
	return false
}

func (t *threadState) runningTurn() *Turn {
	if t.latest != nil && t.latest.State == provider.TurnRunning {
		return t.latest
	}
	return nil
}

func (t *threadState) queued() []*Delivery {
	var queued []*Delivery
	for _, delivery := range t.queue {
		if delivery.State == DeliveryQueued {
			queued = append(queued, delivery)
		}
	}
	return queued
}

func (t *threadState) queueDelivery(id DeliveryID) *Delivery {
	for _, delivery := range t.queue {
		if delivery.ID == id {
			return delivery
		}
	}
	return nil
}

// dropFromQueue takes a delivery that is done with out of the queue.
func (t *threadState) dropFromQueue(id DeliveryID) {
	t.queue = slices.DeleteFunc(t.queue, func(delivery *Delivery) bool { return delivery.ID == id })
}

// root is the root of the thread's tree.
func (e *Engine) root(thread *threadState) *threadState {
	for thread.Origin.Parent != "" {
		parent := e.threads[thread.Origin.Parent]
		if parent == nil {
			break
		}
		thread = parent
	}
	return thread
}

// depth is how many levels the thread is below its root.
func (e *Engine) depth(thread *threadState) int {
	depth := 0
	for thread.Origin.Parent != "" {
		parent := e.threads[thread.Origin.Parent]
		if parent == nil {
			break
		}
		thread, depth = parent, depth+1
	}
	return depth
}

func (e *Engine) policy(thread *threadState) TreePolicy {
	if root := e.root(thread); root.Policy != nil {
		return *root.Policy
	}
	return defaultPolicy
}

// ancestors are the thread's parent, its parent, … up to the root.
func (e *Engine) ancestors(thread *threadState) []*threadState {
	var ancestors []*threadState
	for thread.Origin.Parent != "" {
		parent := e.threads[thread.Origin.Parent]
		if parent == nil {
			break
		}
		ancestors = append(ancestors, parent)
		thread = parent
	}
	return ancestors
}

// isAncestor reports whether ancestor is above thread in its tree.
func (e *Engine) isAncestor(ancestor ThreadID, thread *threadState) bool {
	for _, candidate := range e.ancestors(thread) {
		if candidate.ID == ancestor {
			return true
		}
	}
	return false
}

// descendants are every thread below the thread, depth first.
func (e *Engine) descendants(thread *threadState) []*threadState {
	var all []*threadState
	for _, id := range thread.children {
		if child := e.threads[id]; child != nil {
			all = append(all, child)
			all = append(all, e.descendants(child)...)
		}
	}
	return all
}

// busy reports whether a thread or, with descendants, any thread below it
// runs or has deliveries queued.
func (e *Engine) busy(thread *threadState, descendants bool) bool {
	if thread.running() || len(thread.queued()) > 0 {
		return true
	}
	if !descendants {
		return false
	}
	for _, child := range e.descendants(thread) {
		if child.running() || len(child.queued()) > 0 {
			return true
		}
	}
	return false
}

func (e *Engine) instanceInfo(id provider.InstanceID) provider.InstanceInfo {
	info, _ := e.cfg.Providers.Info(id)
	return info
}
