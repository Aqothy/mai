package codexapp

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// Turns are Codex's own: a turn's ref is its native id. A delivery waits as
// pending until Codex names the turn it started (the turn/start response, or
// turn/started for operations that don't name it), and that turn carries
// the delivery's ID.

// pendingTurn is a delivery whose turn Codex hasn't named yet.
type pendingTurn struct {
	delivery string
	awaits   awaiting
	// text is what was sent, for a command's own turn.
	text string
}

// awaiting is what names a pending delivery's turn.
type awaiting int

const (
	// awaitsCodexTurn: the next turn Codex starts.
	awaitsCodexTurn awaiting = iota
	// awaitsGoalUpdate: the thread/goal/updated of the user's goal change,
	// which then gets a turn of its own.
	awaitsGoalUpdate
	// awaitsResponse: the turn/start response, which names the running turn
	// the input joined; a turn Codex starts meanwhile (a goal continuing)
	// isn't the input's.
	awaitsResponse
)

// Send delivers input: a new turn (turn/start, which joins a turn Codex runs
// on its own), a steer into the running turn (turn/steer), or one of the
// adapter's slash commands.
func (h *Instance) Send(ctx context.Context, thread string, in provider.SendInput) (provider.SendAck, error) {
	command, args, isCommand := parseCommand(in)
	var input []appUserInput
	if !isCommand {
		// Converted first, so input Codex could never take claims no turn.
		var err error
		if input, err = userInputs(in, h.threadSkills(thread)); err != nil {
			return provider.SendAck{}, err
		}
	}
	if err := h.ensureLoaded(ctx, thread); err != nil {
		return provider.SendAck{}, err
	}
	h.mu.Lock()
	session := h.sessionLocked(thread)
	send := turnSend{thread: thread, delivery: in.Delivery, text: in.Text, args: args, cwd: session.cwd, running: session.activeTurn}
	if in.Steer {
		h.mu.Unlock()
		if send.running == "" {
			return provider.SendAck{}, fmt.Errorf("Codex thread %q: %w", thread, provider.ErrTurnNotRunning)
		}
		if isCommand {
			if !command.joinsTurn {
				// As in the Codex TUI, which disables these during a task.
				return provider.SendAck{}, fmt.Errorf("/%s can't run while Codex is working; send it once the turn ends", command.Name)
			}
			return command.run(h, ctx, send)
		}
		var response struct {
			TurnID string `json:"turnId"`
		}
		if err := h.rpc.call(ctx, "turn/steer", map[string]any{
			"threadId": thread, "expectedTurnId": send.running, "clientUserMessageId": in.Delivery, "input": input,
		}, &response); err != nil {
			if steerMissedTurn(err) {
				return provider.SendAck{}, fmt.Errorf("Codex thread %q turn %q: %w: %w", thread, send.running, provider.ErrTurnNotRunning, err)
			}
			return provider.SendAck{}, err
		}
		return provider.SendAck{Turn: send.running}, nil
	}
	if session.pending != nil {
		h.mu.Unlock()
		return provider.SendAck{}, fmt.Errorf("Codex thread %q is already starting a turn", thread)
	}
	if isCommand {
		if send.running != "" && !command.joinsTurn {
			h.mu.Unlock()
			return provider.SendAck{}, fmt.Errorf("/%s can't run while Codex is working; send it once the turn ends", command.Name)
		}
		h.mu.Unlock()
		return command.run(h, ctx, send)
	}
	awaits := awaitsCodexTurn
	if send.running != "" {
		awaits = awaitsResponse
	}
	session.pending = &pendingTurn{delivery: in.Delivery, awaits: awaits}
	model, effort, serviceTier := session.model, session.effort, session.serviceTier
	permissions, permissionsChanged := session.permissions, session.permissionsChanged
	requestSummaries := h.requestSummaries
	h.mu.Unlock()
	params := map[string]any{"threadId": thread, "clientUserMessageId": in.Delivery, "input": input}
	if model != "" {
		params["model"] = model
	}
	if effort != "" {
		params["effort"] = effort
	}
	if serviceTier != "" {
		params["serviceTier"] = serviceTier
	}
	if preset, ok := permissionPresetByID(permissions); ok && permissionsChanged {
		preset.setTurnParams(params)
	}
	if requestSummaries {
		// Every catalog model defaults to no reasoning summaries, which
		// would leave reasoning items empty.
		params["summary"] = "auto"
	}
	var response struct {
		Turn appTurn `json:"turn"`
	}
	err := h.rpc.call(ctx, "turn/start", params, &response)
	if err == nil && response.Turn.ID == "" {
		err = errors.New("turn/start returned an empty turn id")
	}
	if err != nil {
		h.dropPending(thread, in.Delivery)
		return provider.SendAck{}, err
	}
	if permissionsChanged {
		// turn/start settings stay for the rest of the thread.
		h.mu.Lock()
		if session.permissions == permissions {
			session.permissionsChanged = false
		}
		h.mu.Unlock()
	}
	return h.named(thread, in.Delivery, response.Turn.ID), nil
}

// named takes the turn a response named for a pending delivery, unless
// turn/started already did; a turn Codex was running on its own and the
// input joined stays the provider's.
func (h *Instance) named(thread, delivery, turn string) provider.SendAck {
	h.mu.Lock()
	session := h.sessionLocked(thread)
	joined := false
	typed := ""
	pending := session.pending != nil && session.pending.delivery == delivery
	if pending {
		typed = session.pending.text
		session.pending = nil
		joined = session.started[turn]
	}
	first := !session.started[turn]
	session.started[turn] = true
	if first {
		session.activeTurn = turn
	}
	h.mu.Unlock()
	if first {
		h.emit(thread, provider.TurnStarted{Turn: turn, By: provider.TurnByClient, Delivery: delivery})
	}
	if typed != "" {
		h.emitTyped(thread, turn, delivery, typed)
	}
	return provider.SendAck{Turn: turn, Joined: joined}
}

func (h *Instance) dropPending(thread, delivery string) {
	h.mu.Lock()
	if session := h.sessions[thread]; session != nil && session.pending != nil && session.pending.delivery == delivery {
		session.pending = nil
	}
	h.mu.Unlock()
}

// ensureLoaded resumes a thread maiD didn't open: a multi-agent v1 child,
// which takes input like any thread.
func (h *Instance) ensureLoaded(ctx context.Context, thread string) error {
	h.mu.Lock()
	session := h.sessions[thread]
	loaded := session != nil && session.loaded
	h.mu.Unlock()
	if loaded {
		return nil
	}
	_, err := h.Open(ctx, provider.OpenInput{Session: thread})
	return err
}

func (h *Instance) threadSkills(thread string) []provider.Skill {
	h.mu.Lock()
	defer h.mu.Unlock()
	if session := h.sessions[thread]; session != nil {
		return append([]provider.Skill(nil), session.skills...)
	}
	return nil
}

// Interrupt interrupts the turn; on a child thread it stops the child
// (turn_interrupt_inner applies no direct-input check).
func (h *Instance) Interrupt(ctx context.Context, thread, turn string) error {
	if turn == "" {
		h.mu.Lock()
		if session := h.sessions[thread]; session != nil {
			turn = session.activeTurn
		}
		h.mu.Unlock()
	}
	if turn == "" {
		return nil
	}
	return h.rpc.call(ctx, "turn/interrupt", map[string]any{"threadId": thread, "turnId": turn}, nil)
}

// reportTurn runs a turn of the adapter's own for a command Codex runs no
// turn for (/goal): the command as the user's message, its result as the
// answer.
func (h *Instance) reportTurn(send turnSend, report string) provider.SendAck {
	turn := "command:" + send.delivery
	h.emit(send.thread, provider.TurnStarted{Turn: turn, By: provider.TurnByClient, Delivery: send.delivery})
	h.emitTyped(send.thread, turn, send.delivery, send.text)
	h.emitReport(send.thread, turn, send.delivery, report)
	h.emit(send.thread, provider.TurnSettled{Turn: turn, State: provider.TurnCompleted})
	return provider.SendAck{Turn: turn}
}

// emitTyped shows the command a person typed as their message in turn.
// Codex keeps the operation, not what was typed, so the entry is Local.
func (h *Instance) emitTyped(thread, turn, delivery, text string) {
	for _, entry := range provider.UserMessageEntries("typed:"+delivery, turn, text, nil, delivery, time.Now()) {
		entry.Local = true
		h.emit(thread, provider.EntryUpserted{Entry: entry})
	}
}

// emitReport shows a command's result as an assistant message of turn. The
// result is the adapter's own, so the entry is Local.
func (h *Instance) emitReport(thread, turn, delivery, report string) {
	if report == "" {
		return
	}
	h.emit(thread, provider.EntryUpserted{Entry: provider.Entry{
		Ref: "report:" + delivery, Turn: turn, Kind: provider.ItemKindAssistantMessage, Status: provider.ItemStatusCompleted, Text: report, Local: true, At: time.Now(),
	}})
}

// finishGoalChange gives the user's goal change its turn on its
// thread/goal/updated. It runs on the notification reader, before any turn
// the change starts is read, so such a turn stays Codex's own.
func (h *Instance) finishGoalChange(thread string, goal appGoal) {
	h.mu.Lock()
	session := h.sessions[thread]
	if session == nil || session.pending == nil || session.pending.awaits != awaitsGoalUpdate {
		h.mu.Unlock()
		return
	}
	pending := session.pending
	session.pending = nil
	h.mu.Unlock()
	h.reportTurn(turnSend{thread: thread, delivery: pending.delivery, text: pending.text}, goalReport(goal))
}
