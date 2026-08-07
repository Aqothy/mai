package agentrules

import (
	"slices"
	"testing"
)

// The OSC fixtures in this file document exactly which states Increment 8
// (title/progress evidence, no screen) recognizes; the screen fixtures
// document the Increment 9 states that need the detector VT. Patterns come
// from the recorded Herdr manifests embedded in manifests/.

func TestManifestsCompileAndCoverExpectedAgents(t *testing.T) {
	labels := Labels()
	expected := []string{
		"agy", "amp", "claude", "cline", "codex", "copilot", "cursor",
		"devin", "droid", "gemini", "grok", "hermes", "kilo", "kimi",
		"kiro", "maki", "opencode", "pi", "qodercli",
	}
	if !slices.Equal(labels, expected) {
		t.Fatalf("labels = %v, want %v", labels, expected)
	}
	for _, alias := range []string{"claude-code", "cursor-agent", "github-copilot", "antigravity"} {
		if !Known(alias) {
			t.Errorf("alias %q not known", alias)
		}
	}
}

func TestManifestCompatibilityIsValidated(t *testing.T) {
	tooNew := manifest{ID: "future", MinEngineVersion: manifestEngineVersion + 1}
	if _, err := compileManifest(tooNew); err == nil {
		t.Fatal("manifest requiring a newer engine compiled")
	}
	unsupportedRegion := manifest{
		ID:               "future",
		MinEngineVersion: manifestEngineVersion,
		Rules: []rule{{
			ID:     "future_region",
			State:  string(StateWorking),
			Region: "new_region(1)",
		}},
	}
	if _, err := compileManifest(unsupportedRegion); err == nil {
		t.Fatal("manifest with an unsupported region compiled")
	}
}

func TestCodexOSCTitleStates(t *testing.T) {
	cases := []struct {
		name  string
		title string
		want  State
		rule  string
	}{
		{"spinner frame is working", "⠋ Fix the auth bug — Codex", StateWorking, "osc_title_working"},
		{"action required is blocked", "Action Required: approve command", StateBlocked, "osc_title_blocked"},
		{"plain session title is idle", "Codex — maiD", StateIdle, "osc_title_idle"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := Detect("codex", Input{OSCTitle: tc.title})
			if d.State != tc.want || d.Rule != tc.rule {
				t.Fatalf("Detect = %+v, want state %s rule %s", d, tc.want, tc.rule)
			}
		})
	}
}

func TestCodexScreenStates(t *testing.T) {
	working := "› Explain the failure\n\n• Working (1m 16s • esc to interrupt)\n"
	if d := Detect("codex", Input{Screen: working}); d.State != StateWorking {
		t.Fatalf("working screen: %+v", d)
	}
	blocked := "• Working (4s • esc to interrupt)\n\nAllow command?\n" +
		"Press enter to confirm or esc to cancel\n"
	if d := Detect("codex", Input{Screen: blocked}); d.State != StateBlocked {
		t.Fatalf("blocked screen: %+v", d)
	}
}

func TestClaudeOSCStates(t *testing.T) {
	if d := Detect("claude", Input{OSCTitle: "⠂ refactor the reducer"}); d.State != StateWorking {
		t.Fatalf("braille title: %+v", d)
	}
	if d := Detect("claude", Input{OSCTitle: "✳ Claude Code"}); d.State != StateIdle {
		t.Fatalf("static ✳ title: %+v", d)
	}
	if d := Detect("claude", Input{OSCProgress: "4;0;"}); d.State != StateIdle {
		t.Fatalf("cleared progress: %+v", d)
	}
	// Claude leaves progress stuck at 4;3 while waiting for permission, and
	// keeps the ✳ idle title. Without screen evidence this reads as idle —
	// the documented gap that requires the Increment 9 screen source.
	if d := Detect("claude", Input{OSCTitle: "✳ Task", OSCProgress: "4;3;"}); d.State != StateIdle {
		t.Fatalf("stuck 4;3 progress with idle title: %+v", d)
	}
}

func TestClaudeScreenStates(t *testing.T) {
	blocker := "do you want to proceed?\n" +
		"bash command: rm -rf /tmp/test\n" +
		"❯ 1. Yes\n   2. No\n\n" +
		"Esc to cancel · Tab to amend · ctrl+e to explain\n"
	d := Detect("claude", Input{Screen: blocker, OSCTitle: "✳ Claude Code"})
	if d.State != StateBlocked {
		t.Fatalf("bash permission prompt must outrank idle title: %+v", d)
	}

	// The permission form after a horizontal rule beats stale stuck progress.
	form := "──────────\n  1. Yes\n  2. No\n\nEnter to select · ↑/↓ to navigate · Esc to cancel\n"
	d = Detect("claude", Input{Screen: form, OSCTitle: "✳ Task title", OSCProgress: "4;3;"})
	if d.State != StateBlocked {
		t.Fatalf("permission form must outrank stuck progress: %+v", d)
	}

	prompt := "● Finished the refactor\n\n" +
		"──────────────────────────────\n" +
		" ❯ try it out\n" +
		"──────────────────────────────\n"
	d = Detect("claude", Input{Screen: prompt})
	if d.State != StateIdle {
		t.Fatalf("live prompt box is idle: %+v", d)
	}
}

func TestClaudeTranscriptViewerKeepsPreviousState(t *testing.T) {
	viewer := "Showing detailed transcript\n\nctrl+o to toggle\n"
	d := Detect("claude", Input{Screen: viewer})
	if !d.SkipStateUpdate {
		t.Fatalf("transcript viewer must set SkipStateUpdate: %+v", d)
	}
}

func TestKnownAgentWithoutEvidenceIsUnknown(t *testing.T) {
	if d := Detect("claude", Input{}); d.State != StateUnknown {
		t.Fatalf("no evidence: %+v", d)
	}
}

func TestGenericFallbackCoversUnrecognizedAgents(t *testing.T) {
	if d := Detect("unknown", Input{OSCTitle: "⠧ building"}); d.State != StateWorking {
		t.Fatalf("generic spinner: %+v", d)
	}
	if d := Detect("unknown", Input{OSCProgress: "4;1;42"}); d.State != StateWorking {
		t.Fatalf("generic busy progress: %+v", d)
	}
	// Error/paused progress from an unrecognized program is too ambiguous
	// to claim the user's attention is needed.
	if d := Detect("unknown", Input{OSCProgress: "4;2"}); d.State != StateUnknown {
		t.Fatalf("generic error progress stays unknown: %+v", d)
	}
	if d := Detect("unknown", Input{OSCTitle: "vim README.md"}); d.State != StateUnknown {
		t.Fatalf("plain title stays unknown: %+v", d)
	}
}

func TestScreenRulesAreSkippedWithoutScreenSource(t *testing.T) {
	// claude's legacy_no_prompt_blocker uses a not-gate over the screen; with
	// no screen source it must not evaluate against an empty region.
	d := Detect("claude", Input{OSCTitle: "✳ Ready"})
	if d.State != StateIdle || d.Rule != "osc_title_idle" {
		t.Fatalf("screen rules leaked into OSC-only detection: %+v", d)
	}
}

func TestRegionBottomNonEmptyLines(t *testing.T) {
	content := "a\n\nb\nc\n\n"
	got, ok := regionText(Input{Screen: content}, "bottom_non_empty_lines(2)")
	if !ok || got != "b\nc\n\n" {
		t.Fatalf("bottom_non_empty_lines(2) = %q ok=%v", got, ok)
	}
	got, _ = regionText(Input{Screen: content}, "bottom_non_empty_lines(9)")
	if got != "a\n\nb\nc\n\n" {
		t.Fatalf("more than available = %q", got)
	}
}

func TestRegionPromptBoxBody(t *testing.T) {
	content := "before\n────\n ❯ type here\n────\n"
	got, ok := regionText(Input{Screen: content}, "prompt_box_body")
	if !ok || got != " ❯ type here\n" {
		t.Fatalf("prompt_box_body = %q ok=%v", got, ok)
	}
}

func TestRegionAfterLastHorizontalRule(t *testing.T) {
	content := "top\n──────\nmiddle\n────── tail\nbottom\n"
	got, ok := regionText(Input{Screen: content}, "after_last_horizontal_rule")
	if !ok || got != "bottom\n" {
		t.Fatalf("after_last_horizontal_rule = %q ok=%v", got, ok)
	}
}

func TestUnknownRegionMatchesNothing(t *testing.T) {
	if _, ok := regionText(Input{Screen: "x"}, "future_region(3)"); ok {
		t.Fatal("unknown region must not match")
	}
}
