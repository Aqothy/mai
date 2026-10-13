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
	run       func(h *Instance, ctx context.Context, send turnSend) error
}

// turnSend is a prompt or command the user sent on a turn.
type turnSend struct {
	localThread  string
	turn         string
	nativeThread string
	cwd          string
	args         string
	placement    placement
}

const goalUsage = "[<objective>|clear|pause|resume]"

var commands = []command{
	{SlashCommand: provider.SlashCommand{Name: "compact", Description: "Summarize the conversation to free up context"}, run: (*Instance).runCompact},
	{
		SlashCommand: provider.SlashCommand{Name: "review", Description: "Review uncommitted changes, a branch's changes or a commit, or with your instructions", HasInput: true, InputHint: "<target or instructions>"},
		run:          (*Instance).runReview,
	},
	{
		SlashCommand: provider.SlashCommand{Name: "goal", Description: "Set a goal Codex keeps working toward, or show, pause, resume or clear it", HasInput: true, InputHint: goalUsage},
		joinsTurn:    true, run: (*Instance).runGoal,
	},
	{SlashCommand: provider.SlashCommand{Name: "shell", Description: "Run a shell command outside the sandbox", HasInput: true, InputHint: "<command>"}, joinsTurn: true, run: (*Instance).runShell},
}

// slashCommands are the commands as clients are offered them.
var slashCommands = func() []provider.SlashCommand {
	list := make([]provider.SlashCommand, len(commands))
	for index, command := range commands {
		list[index] = command.SlashCommand
	}
	return list
}()

// parseCommand finds the command a prompt runs, and its arguments. Text after
// a command that takes no input makes the prompt an ordinary one.
func parseCommand(input provider.SendTurnInput) (command, string, bool) {
	if len(input.Attachments) > 0 {
		return command{}, "", false
	}
	text := strings.TrimSpace(input.Input)
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

func (h *Instance) runCompact(ctx context.Context, send turnSend) error {
	return h.startOperation(ctx, send, "thread/compact/start", map[string]any{"threadId": send.nativeThread})
}

func (h *Instance) runShell(ctx context.Context, send turnSend) error {
	params := map[string]any{"threadId": send.nativeThread, "command": send.args}
	if send.placement != ownTurn {
		// The command runs inside the running turn and reports there.
		return h.rpc.call(ctx, "thread/shellCommand", params, nil)
	}
	return h.startOperation(ctx, send, "thread/shellCommand", params)
}

// startOperation runs an app-server operation that Codex runs as a turn,
// which takes the pending turn: review/start names it, and compaction and
// shell commands start it with turn/started.
func (h *Instance) startOperation(ctx context.Context, send turnSend, method string, params map[string]any) error {
	h.await(send, awaitsCodexTurn)
	var response struct {
		Turn *appTurn `json:"turn"`
	}
	if err := h.rpc.call(ctx, method, params, &response); err != nil {
		return h.refuse(send, err)
	}
	if response.Turn != nil {
		h.adoptTurn(send.localThread, send.turn, response.Turn.ID)
	}
	return nil
}

func (h *Instance) runGoal(ctx context.Context, send turnSend) error {
	action := parseGoalAction(send.args)
	if !action.sets() {
		report, err := h.readOrClearGoal(ctx, send.nativeThread, action)
		if err != nil {
			return h.refuse(send, err)
		}
		h.finishCommand(send, report)
		return nil
	}
	if send.placement == ownTurn {
		h.await(send, awaitsGoalUpdate)
	}
	goal, err := h.setGoal(ctx, send.nativeThread, action, send.args)
	if err != nil {
		return h.refuse(send, err)
	}
	if send.placement != ownTurn {
		h.finishCommand(send, goalReport(goal))
	}
	// Otherwise the change's thread/goal/updated finishes it.
	return nil
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
