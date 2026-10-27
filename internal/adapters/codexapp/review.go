package codexapp

import (
	"context"
	"errors"
	"os/exec"
	"strings"
	"time"
	"unicode"

	"github.com/Aqothy/maiD/internal/provider"
)

// runReview reviews what the input names, in the terms of the Codex CLI's
// `codex review`: --uncommitted, --base BRANCH, --commit SHA, or custom
// review instructions.
func (h *Instance) runReview(ctx context.Context, send turnSend) (provider.SendAck, error) {
	target, err := reviewTarget(send.args)
	if err != nil {
		return provider.SendAck{}, err
	}
	return h.startOperation(ctx, send, "review/start", map[string]any{"threadId": send.thread, "target": target, "delivery": "inline"})
}

func reviewTarget(args string) (map[string]any, error) {
	flag, value := cutWord(args)
	switch flag {
	case "--uncommitted":
		if value == "" {
			return map[string]any{"type": "uncommittedChanges"}, nil
		}
	case "--base":
		if value != "" {
			return map[string]any{"type": "baseBranch", "branch": value}, nil
		}
	case "--commit":
		if value != "" {
			return map[string]any{"type": "commit", "sha": value}, nil
		}
	case "":
	default:
		return map[string]any{"type": "custom", "instructions": args}, nil
	}
	// The Codex CLI's own message for a review without a target.
	return nil, errors.New("Specify --uncommitted, --base, --commit, or provide custom review instructions")
}

// completeReview suggests what to review, as the Codex TUI's review menu
// offers it: the targets, then a base branch or a commit from git.
func completeReview(ctx context.Context, cwd, input string) []provider.CommandCompletion {
	if !strings.ContainsFunc(input, unicode.IsSpace) {
		return matching(input, []provider.CommandCompletion{
			{Input: "--base ", Label: "Against a base branch", Description: "PR style"},
			{Input: "--uncommitted", Label: "Uncommitted changes"},
			{Input: "--commit ", Label: "A commit"},
		})
	}
	flag, query := cutWord(input)
	var completions []provider.CommandCompletion
	switch flag {
	case "--base":
		current := strings.Join(git(ctx, cwd, "branch", "--show-current"), "")
		for _, branch := range git(ctx, cwd, "for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads") {
			if branch != current && containsFold(branch, query) {
				completions = append(completions, provider.CommandCompletion{Input: "--base " + branch, Label: branch})
			}
		}
	case "--commit":
		for _, line := range git(ctx, cwd, "log", "-n", "100", "--format=%H%x1f%s") {
			sha, subject, _ := strings.Cut(line, "\x1f")
			if containsFold(subject, query) || strings.HasPrefix(sha, query) {
				completions = append(completions, provider.CommandCompletion{Input: "--commit " + sha, Label: subject, Description: sha[:min(len(sha), 7)]})
			}
		}
	}
	return completions[:min(len(completions), 20)]
}

// cutWord splits off the first word of input and trims what follows.
func cutWord(input string) (string, string) {
	input = strings.TrimSpace(input)
	if index := strings.IndexFunc(input, unicode.IsSpace); index >= 0 {
		return input[:index], strings.TrimSpace(input[index:])
	}
	return input, ""
}

func containsFold(text, part string) bool {
	return strings.Contains(strings.ToLower(text), strings.ToLower(part))
}

// git runs a read-only git command in dir and returns its output lines; it
// returns none outside a repository or when git fails.
func git(ctx context.Context, dir string, args ...string) []string {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, "git", args...)
	command.Dir = dir
	output, err := command.Output()
	if err != nil {
		return nil
	}
	var lines []string
	for _, line := range strings.Split(string(output), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			lines = append(lines, line)
		}
	}
	return lines
}
