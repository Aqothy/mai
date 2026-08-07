package terminal

import (
	"sync"
	"testing"
	"time"
)

// detectorHarness drives a Detector with a controllable foreground group and
// process table, standing in for the PTY ioctl and /bin/ps.
type detectorHarness struct {
	mu       sync.Mutex
	fg       int
	table    map[int][]processInfo
	inspects int

	reports chan AgentReport
	d       *Detector
}

const harnessShellPGID = 100

func newDetectorHarness(t *testing.T) *detectorHarness {
	t.Helper()
	h := &detectorHarness{
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
			h.inspects++
			return h.table[pgid]
		},
		publish:           func(r AgentReport) { h.reports <- r },
		recheckInterval:   20 * time.Millisecond,
		settleInterval:    5 * time.Millisecond,
		idleStabilization: 30 * time.Millisecond,
	})
	t.Cleanup(h.d.Stop)
	return h
}

func (h *detectorHarness) setForeground(pgid int, procs ...processInfo) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.fg = pgid
	if procs != nil {
		h.table[pgid] = procs
	}
}

func (h *detectorHarness) inspectCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.inspects
}

// waitReport waits for the next published report matching the predicate,
// failing after a bounded timeout.
func (h *detectorHarness) waitReport(t *testing.T, what string, match func(AgentReport) bool) AgentReport {
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

func claudeProcs() []processInfo {
	return []processInfo{{pid: 200, argv: []string{"claude"}}}
}

func TestDetectorIdentifiesAgentAndWorkingTitle(t *testing.T) {
	h := newDetectorHarness(t)
	h.setForeground(200, claudeProcs()...)
	h.d.ObserveOutput([]byte("\x1b]0;⠋ fix the reducer\x07"))

	r := h.waitReport(t, "working report", func(r AgentReport) bool {
		return r.Activity == AgentActivityWorking
	})
	if r.Kind != AgentClaude {
		t.Fatalf("kind = %q", r.Kind)
	}
	if r.Title != "fix the reducer" {
		t.Fatalf("normalized title = %q", r.Title)
	}
}

func TestDetectorSpinnerFramesPublishOnce(t *testing.T) {
	h := newDetectorHarness(t)
	h.setForeground(200, claudeProcs()...)
	for _, frame := range []string{"⠋", "⠙", "⠹", "⠸", "⠼"} {
		h.d.ObserveOutput([]byte("\x1b]0;" + frame + " fix the reducer\x07"))
	}
	h.waitReport(t, "working report", func(r AgentReport) bool {
		return r.Activity == AgentActivityWorking
	})
	select {
	case r := <-h.reports:
		t.Fatalf("spinner frame churn republished: %+v", r)
	default:
	}
}

func TestDetectorForegroundShellClearsAgent(t *testing.T) {
	h := newDetectorHarness(t)
	h.d.SetAttached(true)
	h.setForeground(200, claudeProcs()...)
	h.d.ObserveOutput([]byte("\x1b]0;⠋ working\x07"))
	h.waitReport(t, "working", func(r AgentReport) bool { return r.Activity == AgentActivityWorking })

	h.setForeground(harnessShellPGID)
	h.d.ObserveOutput([]byte("$ "))
	r := h.waitReport(t, "cleared agent", func(r AgentReport) bool {
		return r.Activity == AgentActivityNone
	})
	if r.Kind != AgentNone {
		t.Fatalf("kind after shell foreground = %q", r.Kind)
	}
	if r.Title != "" {
		t.Fatalf("title after shell foreground = %q, want cleared", r.Title)
	}
}

func TestDetectorProcessInspectionDoesNotBlockOutputObservation(t *testing.T) {
	var mu sync.Mutex
	foreground := harnessShellPGID
	inspectionStarted := make(chan struct{})
	releaseInspection := make(chan struct{})
	d := newDetector(detectorConfig{
		shellPGID: harnessShellPGID,
		foregroundPGID: func() (int, bool) {
			mu.Lock()
			defer mu.Unlock()
			return foreground, true
		},
		inspectGroup: func(int) []processInfo {
			close(inspectionStarted)
			<-releaseInspection
			return claudeProcs()
		},
		publish: func(AgentReport) {},
	})
	t.Cleanup(d.Stop)
	t.Cleanup(func() { close(releaseInspection) })

	mu.Lock()
	foreground = 200
	mu.Unlock()
	returned := make(chan struct{})
	go func() {
		d.ObserveOutput([]byte("\x1b]0;⠋ working\x07"))
		close(returned)
	}()

	select {
	case <-returned:
	case <-time.After(250 * time.Millisecond):
		t.Fatal("ObserveOutput waited for process inspection")
	}
	select {
	case <-inspectionStarted:
	case <-time.After(time.Second):
		t.Fatal("detector worker did not start process inspection")
	}
}

func TestDetectorDetachedFinishBecomesDoneUntilAttach(t *testing.T) {
	h := newDetectorHarness(t)
	h.setForeground(200, claudeProcs()...)
	h.d.ObserveOutput([]byte("\x1b]0;⠋ working\x07"))
	h.waitReport(t, "working", func(r AgentReport) bool { return r.Activity == AgentActivityWorking })

	// The agent exits to the shell while no client is attached.
	h.setForeground(harnessShellPGID)
	h.d.ObserveOutput([]byte("$ "))
	r := h.waitReport(t, "done", func(r AgentReport) bool { return r.Activity == AgentActivityDone })
	if r.Kind != AgentClaude {
		t.Fatalf("done report keeps last agent kind, got %q", r.Kind)
	}

	// Attaching acknowledges done.
	h.d.SetAttached(true)
	h.waitReport(t, "acknowledged", func(r AgentReport) bool {
		return r.Activity == AgentActivityNone && r.Kind == AgentNone
	})
}

func TestDetectorDetachedIdleTransitionBecomesDone(t *testing.T) {
	h := newDetectorHarness(t)
	h.setForeground(200, claudeProcs()...)
	h.d.ObserveOutput([]byte("\x1b]0;⠋ working\x07"))
	h.waitReport(t, "working", func(r AgentReport) bool { return r.Activity == AgentActivityWorking })

	// The agent finishes its turn but stays in the foreground with an idle
	// title. Stabilization holds briefly, then done publishes because no
	// client is attached.
	h.d.ObserveOutput([]byte("\x1b]0;✳ fix the reducer\x07"))
	r := h.waitReport(t, "done", func(r AgentReport) bool { return r.Activity == AgentActivityDone })
	if r.Kind != AgentClaude {
		t.Fatalf("kind = %q", r.Kind)
	}

	// Attaching while the agent is still foreground resolves to idle.
	h.d.SetAttached(true)
	h.waitReport(t, "idle after attach", func(r AgentReport) bool {
		return r.Activity == AgentActivityIdle && r.Kind == AgentClaude
	})
}

func TestDetectorAttachedIdleTransitionStabilizes(t *testing.T) {
	h := newDetectorHarness(t)
	h.d.SetAttached(true)
	h.setForeground(200, claudeProcs()...)
	h.d.ObserveOutput([]byte("\x1b]0;⠋ working\x07"))
	h.waitReport(t, "working", func(r AgentReport) bool { return r.Activity == AgentActivityWorking })

	// A transient idle frame flips straight back to working: no idle report
	// may be published in between.
	h.d.ObserveOutput([]byte("\x1b]0;✳ blip\x07"))
	h.d.ObserveOutput([]byte("\x1b]0;⠙ working again\x07"))
	select {
	case r := <-h.reports:
		if r.Activity != AgentActivityWorking {
			t.Fatalf("transient idle leaked: %+v", r)
		}
	case <-time.After(100 * time.Millisecond):
	}

	// Sustained idle evidence commits after stabilization.
	h.d.ObserveOutput([]byte("\x1b]0;✳ finished\x07"))
	h.waitReport(t, "stable idle", func(r AgentReport) bool {
		return r.Activity == AgentActivityIdle
	})
}

func TestDetectorSilentExitCaughtByRecheck(t *testing.T) {
	h := newDetectorHarness(t)
	h.d.SetAttached(true)
	h.setForeground(200, claudeProcs()...)
	h.d.ObserveOutput([]byte("\x1b]0;⠋ working\x07"))
	h.waitReport(t, "working", func(r AgentReport) bool { return r.Activity == AgentActivityWorking })

	// The agent exits without producing output; only the periodic recheck
	// can observe the shell regaining the foreground.
	h.setForeground(harnessShellPGID)
	h.waitReport(t, "silent exit", func(r AgentReport) bool {
		return r.Activity == AgentActivityNone
	})
}

func TestDetectorInspectsOnlyOnForegroundChange(t *testing.T) {
	h := newDetectorHarness(t)
	h.setForeground(200, claudeProcs()...)
	for range 20 {
		h.d.ObserveOutput([]byte("chunk of ordinary output\r\n"))
	}
	h.waitReport(t, "identified", func(r AgentReport) bool { return r.Kind == AgentClaude })
	if got := h.inspectCount(); got != 1 {
		t.Fatalf("inspectGroup ran %d times for one foreground change", got)
	}
}

func TestDetectorUnknownForegroundUsesGenericSignals(t *testing.T) {
	h := newDetectorHarness(t)
	h.setForeground(300, processInfo{pid: 300, argv: []string{"somenewagent"}})
	h.d.ObserveOutput([]byte("\x1b]9;4;1;10\x07"))
	r := h.waitReport(t, "generic working", func(r AgentReport) bool {
		return r.Activity == AgentActivityWorking
	})
	if r.Kind != AgentUnknown {
		t.Fatalf("kind = %q", r.Kind)
	}
}

func TestNormalizeTitle(t *testing.T) {
	cases := []struct{ raw, want string }{
		{"⠋ fix the reducer", "fix the reducer"},
		{"✳ Claude Code", "Claude Code"},
		{"plain title", "plain title"},
		{"tabs\tand\nnewlines", "tabs and newlines"},
		{"bell\x07inside", "bell inside"},
		{"  spaced   out  ", "spaced out"},
		{"✳ · ⠙ only markers", "only markers"},
		{"", ""},
	}
	for _, tc := range cases {
		if got := normalizeTitle(tc.raw); got != tc.want {
			t.Errorf("normalizeTitle(%q) = %q, want %q", tc.raw, got, tc.want)
		}
	}
	long := normalizeTitle(string(make([]rune, 0, 0)) + strings200())
	if runes := []rune(long); len(runes) != normalizedTitleScalarCap {
		t.Errorf("cap = %d runes", len(runes))
	}
}

func strings200() string {
	runes := make([]rune, 200)
	for i := range runes {
		runes[i] = 'a'
	}
	return string(runes)
}
