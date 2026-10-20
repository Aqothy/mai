package provider

import "strings"

// A fork that the provider can't make natively starts a new session and hands
// it the earlier conversation as text in front of the first prompt. The
// session keeps that text, so its replay splits it back out.
const (
	forkContextOpen     = "<forked_conversation>\n"
	forkContextClose    = "\n</forked_conversation>\n\n"
	forkContextPreamble = "This chat was forked from an earlier conversation, which went as follows. Continue from where it left off.\n\n"
	// forkContextEscaped keeps a closing tag inside the conversation from
	// ending it early.
	forkContextEscaped = "<\\/forked_conversation>"
)

// PromptWithForkContext is the prompt with the earlier conversation in front.
func PromptWithForkContext(conversation, prompt string) string {
	escaped := strings.ReplaceAll(conversation, strings.TrimSpace(forkContextClose), forkContextEscaped)
	return forkContextOpen + forkContextPreamble + escaped + forkContextClose + prompt
}

// SplitForkContext undoes PromptWithForkContext.
func SplitForkContext(text string) (conversation, prompt string, ok bool) {
	rest, ok := strings.CutPrefix(text, forkContextOpen)
	if !ok {
		return "", text, false
	}
	conversation, prompt, ok = strings.Cut(rest, forkContextClose)
	if !ok {
		return "", text, false
	}
	conversation = strings.TrimPrefix(conversation, forkContextPreamble)
	return strings.ReplaceAll(conversation, forkContextEscaped, strings.TrimSpace(forkContextClose)), prompt, true
}
