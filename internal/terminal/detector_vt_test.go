package terminal

// Screen-accurate classification through the headless VT while no client is
// attached. Fixture text mirrors the recorded Herdr manifests the rules were
// written against.

import "testing"

// Claude's permission prompt cannot be recognized from title or progress —
// the title stays ✳ (idle) and progress sticks at 4;3. The screen rules
// must classify it as blocked while no client is attached.
func TestVTDetectorClaudeBlockedFromScreenWhileDetached(t *testing.T) {
	h := newVTDetectorHarness(t)
	h.setForeground(200, processInfo{pid: 200, argv: []string{"claude"}})
	h.d.ObserveOutput([]byte("\x1b]0;✳ Task\x07\x1b]9;4;3;\x07" +
		"do you want to proceed?\r\n" +
		"bash command: rm -rf /tmp/test\r\n" +
		"❯ 1. Yes\r\n   2. No\r\n\r\n" +
		"Esc to cancel · Tab to amend · ctrl+e to explain\r\n"))

	r := h.waitReport(t, "blocked", func(r AgentReport) bool {
		return r.Activity == AgentActivityBlocked
	})
	if r.Kind != AgentClaude {
		t.Fatalf("kind = %q", r.Kind)
	}
}

// A screen-only change with no title or foreground change must reach the
// classifier through the debounced scan path.
func TestVTDetectorScreenOnlyChangeClassifiesAfterDebounce(t *testing.T) {
	h := newVTDetectorHarness(t)
	h.setForeground(300, processInfo{pid: 300, argv: []string{"codex"}})
	// Foreground change publishes first (codex with no evidence → unknown).
	h.d.ObserveOutput([]byte("starting up\r\n"))

	// Codex working footer arrives as plain output: no OSC, no fg change.
	h.d.ObserveOutput([]byte("• Working (4s • esc to interrupt)\r\n"))
	r := h.waitReport(t, "screen working", func(r AgentReport) bool {
		return r.Activity == AgentActivityWorking
	})
	if r.Kind != AgentCodex {
		t.Fatalf("kind = %q", r.Kind)
	}
}

// Stale transcript text must not classify once the screen is cleared: the
// detector follows the current screen, not raw byte history.
func TestVTDetectorClearScreenDropsStaleEvidence(t *testing.T) {
	h := newVTDetectorHarness(t)
	h.setForeground(300, processInfo{pid: 300, argv: []string{"codex"}})
	h.d.ObserveOutput([]byte("• Working (4s • esc to interrupt)\r\n"))
	h.waitReport(t, "working", func(r AgentReport) bool {
		return r.Activity == AgentActivityWorking
	})

	// The TUI clears the working footer; the old bytes remain only in
	// history. Working must settle away even though the raw stream still
	// contains the footer text.
	h.d.ObserveOutput([]byte("\x1b[2J\x1b[H› \r\n"))
	h.waitReport(t, "unknown after clear", func(r AgentReport) bool {
		return r.Activity == AgentActivityUnknown
	})
}
