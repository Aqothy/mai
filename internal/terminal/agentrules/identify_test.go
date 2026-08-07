package agentrules

import "testing"

func TestIdentifyCommand(t *testing.T) {
	cases := []struct {
		name string
		argv []string
		want string
		ok   bool
	}{
		{"direct binary", []string{"claude"}, "claude", true},
		{"absolute path", []string{"/opt/homebrew/bin/codex", "resume"}, "codex", true},
		{"node wrapper", []string{"node", "/usr/local/bin/claude"}, "claude", true},
		{"node wrapper with flags", []string{"node", "--max-old-space-size=8192", "/usr/local/bin/codex"}, "codex", true},
		{"bun wrapper", []string{"bun", "/path/to/bin/amp"}, "amp", true},
		{"python versioned wrapper", []string{"python3.12", "/usr/local/bin/hermes"}, "hermes", true},
		{"alias resolves to canonical label", []string{"cursor-agent"}, "cursor", true},
		{"kiro cli alias", []string{"kiro-cli"}, "kiro", true},
		{"node running something else", []string{"node", "/srv/app/server.js"}, "", false},
		{"plain tool", []string{"vim", "README.md"}, "", false},
		{"empty argv", nil, "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := IdentifyCommand(tc.argv)
			if got != tc.want || ok != tc.ok {
				t.Fatalf("IdentifyCommand(%v) = %q,%v want %q,%v", tc.argv, got, ok, tc.want, tc.ok)
			}
		})
	}
}

func TestIdentifyGroupPrefersLeaderThenMembers(t *testing.T) {
	group := []GroupProcess{
		{PID: 10, Argv: []string{"-zsh"}},
		{PID: 12, Argv: []string{"node", "/tmp/mcp/bin/codex"}},
	}
	// The unrecognized leader falls back to a recognized member: agents
	// spawn MCP helpers inside their own group.
	if label, ok := IdentifyGroup(10, group); !ok || label != "codex" {
		t.Fatalf("member fallback = %q %v", label, ok)
	}

	leaderWins := []GroupProcess{
		{PID: 20, Argv: []string{"claude"}},
		{PID: 21, Argv: []string{"node", "/tmp/mcp/bin/codex"}},
	}
	if label, ok := IdentifyGroup(20, leaderWins); !ok || label != "claude" {
		t.Fatalf("leader preference = %q %v", label, ok)
	}

	if _, ok := IdentifyGroup(30, []GroupProcess{{PID: 30, Argv: []string{"vim"}}}); ok {
		t.Fatal("vim must not identify as an agent")
	}
}
