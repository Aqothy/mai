package codexapp

import (
	"fmt"

	"github.com/Aqothy/maiD/internal/provider"
)

// pendingTurn is a turn the user sent that no Codex turn carries yet. Whoever
// takes it from the session reports its outcome: the Codex turn that carries
// it, the command that ends it, or the failure that stops it.
type pendingTurn struct {
	id     string
	awaits awaiting
}

// awaiting is what takes a pending turn.
type awaiting int

const (
	// awaitsCodexTurn: the next turn Codex reports carries the user's input.
	awaitsCodexTurn awaiting = iota
	// awaitsGoalUpdate: the thread/goal/updated of the user's goal change.
	awaitsGoalUpdate
	// awaitsCommand: the command, once it ran or its questions were answered.
	awaitsCommand
)

// placement is how input the user sent meets Codex's turns.
type placement int

const (
	// ownTurn: the input starts a turn of its own, pending until taken.
	ownTurn placement = iota
	// steered: the user steered the input into the turn running.
	steered
	// tookOver: the input joined a turn Codex was running on its own, which
	// carries the user's turn from then on.
	tookOver
)

// beginTurnLocked starts the user's turn. When Codex is running a turn of its
// own (a goal continuing, say) and the input joins it, that turn continues as
// the user's: Codex's turn/start steers input into a running turn, and the
// shell and goal commands apply to it. It reports whether it handed the turn
// over; otherwise the turn is pending.
func beginTurnLocked(session *sessionState, turn string, awaits awaiting, joins bool) bool {
	if joins && session.activeNativeTurn != "" {
		handOffLocked(session, turn)
		return true
	}
	session.pending = &pendingTurn{id: turn, awaits: awaits}
	return false
}

// handOffLocked makes the turn Codex is running carry the local turn from
// here on, as the Claude Code adapter does for a turn the CLI started.
func handOffLocked(session *sessionState, turn string) {
	native := session.activeNativeTurn
	delete(session.localToNativeTurn, session.nativeToLocalTurn[native])
	session.nativeToLocalTurn[native] = turn
	session.localToNativeTurn[turn] = native
	session.startedTurns[turn] = true
}

// takePendingLocked takes the pending turn if it is still turn.
func takePendingLocked(session *sessionState, turn string) bool {
	if session.pending == nil || session.pending.id != turn {
		return false
	}
	session.pending = nil
	return true
}

// await sets what takes a command's pending turn, before the command hands
// work to Codex.
func (h *Instance) await(send turnSend, awaits awaiting) {
	h.mu.Lock()
	if session := h.sessionsByLocal[send.localThread]; session != nil && session.pending != nil && session.pending.id == send.turn {
		session.pending.awaits = awaits
	}
	h.mu.Unlock()
}

// releaseTurn takes back a pending turn whose request failed. It reports
// whether the caller still owned it and so reports the failure; a disconnect
// that took it first already ended the turn.
func (h *Instance) releaseTurn(localThread, turn string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessionsByLocal[localThread]
	return session != nil && takePendingLocked(session, turn)
}

// adoptTurn gives the turn a turn/start or review/start response names to
// the pending turn, unless a notification already did.
func (h *Instance) adoptTurn(localThread, turn, nativeTurn string) {
	h.mu.Lock()
	session := h.sessionsByLocal[localThread]
	if session == nil || !takePendingLocked(session, turn) {
		h.mu.Unlock()
		return
	}
	if previous := session.nativeToLocalTurn[nativeTurn]; previous != "" {
		// Codex steered the input into a turn it ran on its own, which ended
		// before this response was read.
		h.mu.Unlock()
		h.endTurn(localThread, turn, provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnCompleted})
		return
	}
	session.nativeToLocalTurn[nativeTurn] = turn
	session.localToNativeTurn[turn] = nativeTurn
	session.startedTurns[turn] = true
	session.activeNativeTurn = nativeTurn
	h.mu.Unlock()
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventTurnStarted, ThreadID: localThread, TurnID: turn})
}

// finishCommand reports what a command did and ends its turn. A command
// that joined a Codex turn only adds its report. One whose turn is
// pending ends it, unless Codex started a turn of its own meanwhile: the
// command then joined that turn, which continues as the user's.
func (h *Instance) finishCommand(send turnSend, report string) {
	if send.placement != ownTurn {
		h.emitReport(send.localThread, send.turn, report)
		return
	}
	h.mu.Lock()
	session := h.sessionsByLocal[send.localThread]
	if session == nil || !takePendingLocked(session, send.turn) {
		h.mu.Unlock()
		return
	}
	first := markStartedLocked(session, send.turn)
	joined := session.activeNativeTurn != ""
	if joined {
		handOffLocked(session, send.turn)
	}
	h.mu.Unlock()
	if first {
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventTurnStarted, ThreadID: send.localThread, TurnID: send.turn})
	}
	h.emitReport(send.localThread, send.turn, report)
	if !joined {
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventTurnCompleted, ThreadID: send.localThread, TurnID: send.turn, Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnCompleted}})
	}
}

// finishGoalChange finishes the user's goal change on its thread/goal/updated.
// It runs on the notification reader, before any turn the change starts is
// read, so such a turn stays Codex's own.
func (h *Instance) finishGoalChange(nativeThread string, goal appGoal) {
	h.mu.Lock()
	localThread := h.localByNative[nativeThread]
	session := h.sessionsByLocal[localThread]
	if session == nil || session.pending == nil || session.pending.awaits != awaitsGoalUpdate {
		h.mu.Unlock()
		return
	}
	turn := session.pending.id
	h.mu.Unlock()
	h.finishCommand(turnSend{localThread: localThread, turn: turn}, goalReport(goal))
}

// refuse reports input Codex did not take. A steer is only refused. A turn
// of its own fails through SendTurn's error, unless a disconnect took it
// first and already ended it. A turn that took over Codex's turn fails, and
// that turn, still running, is Codex's own again.
func (h *Instance) refuse(send turnSend, err error) error {
	switch send.placement {
	case steered:
		return err
	case tookOver:
		h.giveBack(send, err)
		return nil
	}
	if h.releaseTurn(send.localThread, send.turn) {
		return err
	}
	return nil
}

// giveBack ends a turn that took over Codex's turn as failed, and returns the
// turn, if it still runs, to Codex.
func (h *Instance) giveBack(send turnSend, err error) {
	h.mu.Lock()
	running := ""
	if session := h.sessionsByLocal[send.localThread]; session != nil {
		if native := session.localToNativeTurn[send.turn]; native != "" && native == session.activeNativeTurn {
			delete(session.localToNativeTurn, send.turn)
			session.nativeToLocalTurn[native] = native
			session.localToNativeTurn[native] = native
			running = native
		}
	}
	h.mu.Unlock()
	h.endTurn(send.localThread, send.turn, provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnFailed, Message: err.Error()})
	if running != "" {
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventTurnStarted, ThreadID: send.localThread, TurnID: running})
	}
}

// markStartedLocked records the start of a local turn and reports whether
// it is the first, which the caller then emits.
func markStartedLocked(session *sessionState, turn string) bool {
	if session.startedTurns[turn] {
		return false
	}
	session.startedTurns[turn] = true
	return true
}

// endTurn emits the start a local turn may still lack and its end.
func (h *Instance) endTurn(localThread, turn string, outcome provider.RuntimeEventPayload) {
	h.mu.Lock()
	first := false
	if session := h.sessionsByLocal[localThread]; session != nil {
		first = markStartedLocked(session, turn)
	}
	h.mu.Unlock()
	if first {
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventTurnStarted, ThreadID: localThread, TurnID: turn})
	}
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventTurnCompleted, ThreadID: localThread, TurnID: turn, Payload: outcome})
}

// emitReport shows a command's result, if it has one, as an assistant
// message.
func (h *Instance) emitReport(localThread, turn, report string) {
	if report == "" {
		return
	}
	itemID := fmt.Sprintf("codex:report:%s:%d", h.requestNonce, h.localIDs.Add(1))
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventContentDelta, ThreadID: localThread, TurnID: turn, ItemID: itemID, Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: report}})
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventItemCompleted, ThreadID: localThread, TurnID: turn, ItemID: itemID, Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindAssistantMessage, ItemStatus: provider.ItemStatusCompleted}})
}
