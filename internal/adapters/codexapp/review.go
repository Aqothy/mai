package codexapp

import (
	"context"
	"errors"
	"strings"
	"unicode"
)

// runReview reviews what the input names, in the terms of the Codex CLI's
// `codex review`: --uncommitted, --base BRANCH, --commit SHA, or custom
// review instructions.
func (h *Instance) runReview(ctx context.Context, send turnSend) error {
	target, err := reviewTarget(send.args)
	if err != nil {
		return h.refuse(send, err)
	}
	return h.startOperation(ctx, send, "review/start", map[string]any{"threadId": send.nativeThread, "target": target, "delivery": "inline"})
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

// cutWord splits off the first word of input and trims what follows.
func cutWord(input string) (string, string) {
	input = strings.TrimSpace(input)
	if index := strings.IndexFunc(input, unicode.IsSpace); index >= 0 {
		return input[:index], strings.TrimSpace(input[index:])
	}
	return input, ""
}
