package provider

import "testing"

// Item titles and choice labels from every adapter share one sentence-case
// style, matching the adapters' literal titles ("Edited file", "Waited").
func TestHumanizeIdentifierUsesSentenceCase(t *testing.T) {
	for input, want := range map[string]string{
		"enteredReviewMode":       "Entered review mode",
		"max_turns":               "Max turns",
		"AskUserQuestion":         "Ask user question",
		"get-mcp-server.fetchURL": "Get MCP server fetch URL",
		"xhigh":                   "Extra high",
		"  ":                      "",
	} {
		if got := HumanizeIdentifier(input); got != want {
			t.Errorf("HumanizeIdentifier(%q) = %q, want %q", input, got, want)
		}
	}
}
