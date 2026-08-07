package terminal

// Increment 9 tests: screen-accurate classification through the headless VT
// while no client is attached. Fixture text mirrors the recorded Herdr
// manifests the rules were written against.

import (
	"sync"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/terminal/vtscreen"
)

type vtDetectorHarness struct {
	mu    sync.Mutex
	fg    int
	table map[int][]processInfo

	reports chan AgentReport
	d       *Detector
}

func newVTDetectorHarness(t *testing.T) *vtDetectorHarness {
	t.Helper()
	screen, err := vtscreen.New(80, 24)
	if err != nil {
		t.Fatalf("vtscreen.New: %v", err)
	}
	h := &vtDetectorHarness{
		fg:      harnessShellPGID,
		table:   make(map[int][]processInfo),
		reports: make(chan AgentReport, 64),
	}
	h.d = newDetector(detectorConfig{
		shellPGID: harnessShellPGID,
		foregroundPGID: func() (int, bool) {
			h.mu.Lock()
			defer h.mu.Unlock()
			return h.fg, true
		},
		inspectGroup: func(pgid int) []processInfo {
			h.mu.Lock()
			defer h.mu.Unlock()
			return h.table[pgid]
		},
		screen:            screen,
		publish:           func(r AgentReport) { h.reports <- r },
		recheckInterval:   20 * time.Millisecond,
		settleInterval:    5 * time.Millisecond,
		idleStabilization: 30 * time.Millisecond,
		scanDebounce:      10 * time.Millisecond,
		scanForce:         50 * time.Millisecond,
	})
	t.Cleanup(h.d.Stop)
	return h
}

func (h *vtDetectorHarness) setForeground(pgid int, procs ...processInfo) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.fg = pgid
	if procs != nil {
		h.table[pgid] = procs
	}
}

func (h *vtDetectorHarness) waitReport(t *testing.T, what string, match func(AgentReport) bool) AgentReport {
	t.Helper()
	deadline := time.After(2 * time.Second)
	for {
		select {
		case r := <-h.reports:
			if match(r) {
				return r
			}
		case <-deadline:
			t.Fatalf("timed out waiting for %s; last state %+v", what, h.d.Report())
		}
	}
}

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
