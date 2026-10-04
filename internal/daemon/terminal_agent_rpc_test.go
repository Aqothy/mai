package daemon

// Agent activity tests: semantic agent activity flows to terminal-list
// subscribers while raw evidence stays out of the wire. The foreground job
// here is an unrecognized `sh` script, which exercises the generic
// spinner-title path; recognized-agent classification is covered by the
// agentrules fixtures.

import (
	"testing"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/terminal"
)

// spinnerTitleScript emits an OSC 0 title with a braille spinner frame from
// a non-shell foreground job, repeating so the detector's foreground probe
// cannot miss the job regardless of chunk timing, then exits back to zsh.
const spinnerTitleScript = "sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do printf \"\\033]0;⠋ agent task\\007\"; sleep 0.2; done'\n"

func waitForAgentActivity(t *testing.T, c *recordingClient, terminalID string, activity wire.TerminalAgentActivity) wire.TerminalSummary {
	t.Helper()
	return waitForListUpsert(t, c, func(s wire.TerminalSummary) bool {
		return s.TerminalID == terminalID && s.AgentActivity == activity
	})
}

// startSpinnerJob runs spinnerTitleScript in a terminal created by controller
// while observer watches the terminal list.
func startSpinnerJob(t *testing.T) (observer, controller *recordingClient, created wire.TerminalAttachSnapshot) {
	t.Helper()
	useQuietTestShell(t)
	s := newTestServer(t)
	t.Cleanup(func() { _ = s.Close() })
	url := newWSTestServer(t, s)

	observer = dialRecordingClient(t, url)
	subscribeTerminalListSnapshot(t, observer)

	controller = dialRecordingClient(t, url)
	created = createTestTerminal(t, controller)
	controller.notify(t, wire.MethodTerminalWrite, wire.TerminalWriteParams{
		TerminalID: created.Terminal.TerminalID,
		RunID:      created.RunID,
		Data:       []byte(spinnerTitleScript),
	})
	return observer, controller, created
}

func TestTerminalAgentActivityPublishesSemanticUpserts(t *testing.T) {
	observer, _, created := startSpinnerJob(t)
	terminalID := created.Terminal.TerminalID

	working := waitForAgentActivity(t, observer, terminalID, terminal.AgentActivityWorking)
	if working.AgentKind != terminal.AgentUnknown {
		t.Fatalf("agent kind = %q, want unknown for an unrecognized job", working.AgentKind)
	}
	if working.ObservedTitle != "agent task" {
		t.Fatalf("observed title = %q, want spinner frame stripped", working.ObservedTitle)
	}
	if working.AgentActivityUpdatedAt == nil {
		t.Fatal("working upsert missing agentActivityUpdatedAt")
	}
	// The detector's evidence must stay private: only the normalized title
	// crosses the wire, never the raw spinner frames or escape bytes.
	for _, item := range observer.listItemsSnapshot() {
		if item.Terminal != nil && item.Terminal.ObservedTitle != "" && item.Terminal.ObservedTitle != "agent task" {
			t.Fatalf("unexpected observed title %q", item.Terminal.ObservedTitle)
		}
	}

	// While a client remains attached, the job's exit clears the activity
	// instead of reporting done.
	cleared := waitForListUpsert(t, observer, func(sum wire.TerminalSummary) bool {
		return sum.TerminalID == terminalID &&
			sum.AgentActivity == terminal.AgentActivityNone &&
			sum.AgentKind == terminal.AgentNone
	})
	if cleared.Status != terminal.StatusRunning || cleared.ObservedTitle != "" {
		t.Fatalf("cleared upsert = status %s, observed title %q; want running with no title", cleared.Status, cleared.ObservedTitle)
	}
	if !cleared.UpdatedAt.Equal(working.UpdatedAt) {
		t.Fatal("agent activity change bumped updatedAt; rows must not reorder on activity")
	}
}

func TestTerminalAgentDoneWhileDetachedAndAttachAcknowledges(t *testing.T) {
	observer, controller, created := startSpinnerJob(t)
	terminalID := created.Terminal.TerminalID
	waitForAgentActivity(t, observer, terminalID, terminal.AgentActivityWorking)

	// Navigate away: the shell keeps running with no attached client, and
	// activity keeps updating server-side.
	controller.notify(t, wire.MethodTerminalDetach, wire.TerminalDetachParams{
		TerminalID: terminalID,
		RunID:      created.RunID,
	})

	// The job finishes while detached: the working run reports done and
	// holds it.
	done := waitForAgentActivity(t, observer, terminalID, terminal.AgentActivityDone)
	if done.AgentKind != terminal.AgentUnknown {
		t.Fatalf("done keeps the job's kind, got %q", done.AgentKind)
	}

	// Reattaching acknowledges done and returns the row to no activity.
	var attach wire.TerminalAttachSnapshot
	controller.call(t, wire.MethodTerminalAttach, wire.TerminalAttachParams{
		TerminalID: terminalID,
		Columns:    80,
		Rows:       24,
	}, &attach)
	if attach.Terminal.AgentActivity == terminal.AgentActivityDone {
		t.Fatal("attach snapshot still reports done after acknowledgment")
	}
	waitForListUpsert(t, observer, func(sum wire.TerminalSummary) bool {
		return sum.TerminalID == terminalID && sum.AgentActivity == terminal.AgentActivityNone
	})
}
