package codexapp

import (
	"context"
	"fmt"
	"strings"
	"unicode"

	"github.com/Aqothy/maiD/internal/provider"
)

// command is a slash command the adapter runs with one of Codex's own
// operations; app-server leaves slash commands to its clients.
type command struct {
	provider.SlashCommand
	// joinsTurn says the command runs inside a turn Codex is running. The
	// others replace that turn, so they can't be steered into one.
	joinsTurn bool
	run       func(h *Instance, ctx context.Context, send turnSend) (provider.SendAck, error)
	// complete, if set, suggests the command's input.
	complete func(ctx context.Context, cwd, input string) []provider.CommandCompletion
}

// turnSend is a command sent to a thread: as its own turn, or into the turn
// running.
type turnSend struct {
	thread   string
	delivery string
	text     string
	cwd      string
	args     string
	// running is the turn Codex runs, which a command that joins runs in.
	running string
}

const goalUsage = "[<objective>|clear|pause|resume]"

var commands = []command{
	{SlashCommand: provider.SlashCommand{Name: "compact", Description: "Summarize the conversation to free up context"}, run: (*Instance).runCompact},
	{
		SlashCommand: provider.SlashCommand{Name: "review", Description: "Review uncommitted changes, a branch's changes or a commit, or with your instructions", HasInput: true, InputHint: "<target or instructions>"},
		run:          (*Instance).runReview, complete: completeReview,
	},
	{
		SlashCommand: provider.SlashCommand{Name: "goal", Description: "Set a goal Codex keeps working toward, or show, pause, resume or clear it", HasInput: true, InputHint: goalUsage},
		joinsTurn:    true, run: (*Instance).runGoal, complete: completeGoal,
	},
	{SlashCommand: provider.SlashCommand{Name: "shell", Description: "Run a shell command outside the sandbox", HasInput: true, InputHint: "<command>"}, joinsTurn: true, run: (*Instance).runShell},
}

// slashCommands are the commands as clients are offered them.
var slashCommands = func() []provider.SlashCommand {
	list := make([]provider.SlashCommand, len(commands))
	for index, command := range commands {
		list[index] = command.SlashCommand
		list[index].Completes = command.complete != nil
	}
	return list
}()

// CompleteCommand suggests input for a command that completes.
func (h *Instance) CompleteCommand(ctx context.Context, input provider.CompleteCommandInput) ([]provider.CommandCompletion, error) {
	for _, command := range commands {
		if command.Name == input.Command && command.complete != nil {
			return command.complete(ctx, input.Cwd, input.Input), nil
		}
	}
	return nil, nil
}

// parseCommand finds the command a prompt runs, and its arguments. Text after
// a command that takes no input makes the prompt an ordinary one.
func parseCommand(input provider.SendInput) (command, string, bool) {
	if len(input.Attachments) > 0 {
		return command{}, "", false
	}
	envelopes, own := provider.SplitMessage(input.Text)
	if len(envelopes) > 0 {
		// Only a person's own words run a command.
		return command{}, "", false
	}
	text := strings.TrimSpace(own)
	name, args := text, ""
	if index := strings.IndexFunc(text, unicode.IsSpace); index >= 0 {
		name, args = text[:index], strings.TrimSpace(text[index:])
	}
	if !strings.HasPrefix(name, "/") {
		return command{}, "", false
	}
	for _, command := range commands {
		if command.Name == name[1:] && (command.HasInput || args == "") {
			return command, args, true
		}
	}
	return command{}, "", false
}

func (h *Instance) runCompact(ctx context.Context, send turnSend) (provider.SendAck, error) {
	return h.startOperation(ctx, send, "thread/compact/start", map[string]any{"threadId": send.thread})
}

func (h *Instance) runShell(ctx context.Context, send turnSend) (provider.SendAck, error) {
	params := map[string]any{"threadId": send.thread, "command": send.args}
	if send.running != "" {
		// The command runs inside the running turn and reports there.
		if err := h.rpc.call(ctx, "thread/shellCommand", params, nil); err != nil {
			return provider.SendAck{}, err
		}
		h.emitTyped(send.thread, send.running, send.delivery, send.text)
		return provider.SendAck{Turn: send.running}, nil
	}
	return h.startOperation(ctx, send, "thread/shellCommand", params)
}

// startOperation runs an app-server operation that Codex runs as a turn,
// which carries the delivery: review/start names it, and compaction and shell
// commands start it with turn/started (the ack then names none).
func (h *Instance) startOperation(ctx context.Context, send turnSend, method string, params map[string]any) (provider.SendAck, error) {
	h.mu.Lock()
	h.sessionLocked(send.thread).pending = &pendingTurn{delivery: send.delivery, awaits: awaitsCodexTurn, text: send.text}
	h.mu.Unlock()
	var response struct {
		Turn *appTurn `json:"turn"`
	}
	if err := h.rpc.call(ctx, method, params, &response); err != nil {
		h.dropPending(send.thread, send.delivery)
		return provider.SendAck{}, err
	}
	if response.Turn != nil && response.Turn.ID != "" {
		return h.named(send.thread, send.delivery, response.Turn.ID), nil
	}
	return provider.SendAck{}, nil
}

// runGoal shows, clears, pauses, resumes or sets the goal. Inside a running
// turn its result joins that turn; otherwise it gets a turn of its own, once
// a change Codex reports (thread/goal/updated) is in.
func (h *Instance) runGoal(ctx context.Context, send turnSend) (provider.SendAck, error) {
	action := parseGoalAction(send.args)
	if !action.sets() {
		report, err := h.readOrClearGoal(ctx, send.thread, action)
		if err != nil {
			return provider.SendAck{}, err
		}
		return h.commandDone(send, report), nil
	}
	if send.running == "" {
		h.mu.Lock()
		h.sessionLocked(send.thread).pending = &pendingTurn{delivery: send.delivery, awaits: awaitsGoalUpdate, text: send.text}
		h.mu.Unlock()
	}
	goal, err := h.setGoal(ctx, send.thread, action, send.args)
	if err != nil {
		h.dropPending(send.thread, send.delivery)
		return provider.SendAck{}, err
	}
	if send.running != "" {
		return h.commandDone(send, goalReport(goal)), nil
	}
	// The change's thread/goal/updated gives it its turn.
	return provider.SendAck{}, nil
}

// commandDone reports a command's result: in the running turn it joined, or
// in a turn of its own.
func (h *Instance) commandDone(send turnSend, report string) provider.SendAck {
	if send.running != "" {
		h.emitTyped(send.thread, send.running, send.delivery, send.text)
		h.emitReport(send.thread, send.running, send.delivery, report)
		return provider.SendAck{Turn: send.running}
	}
	return h.reportTurn(send, report)
}

// goalAction is what a /goal command does, after the Codex TUI's /goal.
type goalAction int

const (
	goalShow goalAction = iota
	goalClear
	goalPause
	goalResume
	goalReplace
)

func parseGoalAction(args string) goalAction {
	switch strings.ToLower(args) {
	case "":
		return goalShow
	case "clear":
		return goalClear
	case "pause":
		return goalPause
	case "resume":
		return goalResume
	}
	return goalReplace
}

// sets reports whether the action goes through thread/goal/set.
func (a goalAction) sets() bool {
	return a == goalPause || a == goalResume || a == goalReplace
}

// readOrClearGoal shows or clears the thread's goal and returns the report.
func (h *Instance) readOrClearGoal(ctx context.Context, nativeThread string, action goalAction) (string, error) {
	if action == goalClear {
		var response struct {
			Cleared bool `json:"cleared"`
		}
		if err := h.rpc.call(ctx, "thread/goal/clear", map[string]any{"threadId": nativeThread, "origin": "user"}, &response); err != nil {
			return "", err
		}
		if !response.Cleared {
			return "No goal is set.", nil
		}
		return "Goal cleared.", nil
	}
	goal, err := h.currentGoal(ctx, nativeThread)
	if err != nil {
		return "", err
	}
	if goal == nil {
		return "No goal is set. Usage: /goal " + goalUsage, nil
	}
	return goalReport(*goal), nil
}

// setGoal pauses, resumes or replaces the thread's goal. Origin "user"
// records the change as the user's instruction in the thread; without it
// Codex treats the change as unauthorized by the user.
func (h *Instance) setGoal(ctx context.Context, nativeThread string, action goalAction, objective string) (appGoal, error) {
	params := map[string]any{"threadId": nativeThread, "origin": "user", "status": "active"}
	switch action {
	case goalPause:
		params["status"] = "paused"
	case goalReplace:
		// A new objective starts a fresh goal, as the TUI does once the user
		// confirms replacing one: updating the old goal would keep its usage,
		// so a goal that ran out of budget would stay out of budget.
		current, err := h.currentGoal(ctx, nativeThread)
		if err != nil {
			return appGoal{}, err
		}
		if current != nil {
			if err := h.rpc.call(ctx, "thread/goal/clear", map[string]any{"threadId": nativeThread, "origin": "user"}, nil); err != nil {
				return appGoal{}, err
			}
		}
		params["objective"] = objective
	}
	var response struct {
		Goal appGoal `json:"goal"`
	}
	if err := h.rpc.call(ctx, "thread/goal/set", params, &response); err != nil {
		return appGoal{}, err
	}
	return response.Goal, nil
}

func (h *Instance) currentGoal(ctx context.Context, nativeThread string) (*appGoal, error) {
	var response struct {
		Goal *appGoal `json:"goal"`
	}
	if err := h.rpc.call(ctx, "thread/goal/get", map[string]any{"threadId": nativeThread}, &response); err != nil {
		return nil, err
	}
	return response.Goal, nil
}

// completeGoal suggests the goal controls; anything else is an objective.
func completeGoal(_ context.Context, _, input string) []provider.CommandCompletion {
	return matching(input, []provider.CommandCompletion{
		{Input: "pause", Label: "Pause the goal"},
		{Input: "resume", Label: "Resume the goal"},
		{Input: "clear", Label: "Clear the goal"},
	})
}

// matching keeps the completions whose input or label starts with what was
// typed.
func matching(input string, completions []provider.CommandCompletion) []provider.CommandCompletion {
	typed := strings.ToLower(strings.TrimSpace(input))
	var kept []provider.CommandCompletion
	for _, completion := range completions {
		if strings.HasPrefix(strings.ToLower(completion.Input), typed) || strings.HasPrefix(strings.ToLower(completion.Label), typed) {
			kept = append(kept, completion)
		}
	}
	return kept
}

// goalReport describes a goal with the Codex TUI's status labels.
func goalReport(goal appGoal) string {
	label := goal.Status
	switch goal.Status {
	case "blocked":
		label = "stalled"
	case "usageLimited":
		label = "usage limited"
	case "budgetLimited":
		label = "limited by budget"
	}
	report := fmt.Sprintf("Goal %s: %s", label, goal.Objective)
	if goal.TokenBudget != nil {
		report += fmt.Sprintf("\n\nTokens: %d of %d.", goal.TokensUsed, *goal.TokenBudget)
	}
	return report
}
