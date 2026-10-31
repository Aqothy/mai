package daemon

// What a terminal's program reports about itself (title, working directory,
// OSC 7501 status) reaches terminal-list subscribers that aren't attached,
// and the daemon's terminal alone answers the program's queries.

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/terminal"
)

func TestTerminalProgramReportsReachTheListWithoutAttaching(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	observer := dialRecordingClient(t, url)
	subscribeTerminalListSnapshot(t, observer)
	controller := dialRecordingClient(t, url)
	created := createTestTerminal(t, controller)
	terminalID, runID := created.Terminal.TerminalID, created.RunID

	// A right-to-left override in the message must not reach the list.
	message := base64.StdEncoding.EncodeToString([]byte("Apply\u202e patch?"))
	controller.writeTerminal(t, terminalID, runID,
		`printf '\033]0;✳ refactor task\007\033]7;file:///tmp/project\007`+
			`\033]7501;state=blocked:kind=permission:app=codex:msg=`+message+`\033\\'`+"\n")
	blocked := waitForListUpsert(t, observer, func(summary wire.TerminalSummary) bool {
		return summary.TerminalID == terminalID && summary.ProgramStatus != nil
	})
	status := blocked.ProgramStatus
	if status.State != terminal.ProgramBlocked || status.Need != terminal.ProgramNeedsPermission ||
		status.App != "codex" || status.Message != "Apply patch?" || status.Progress != nil {
		t.Fatalf("program status = %+v, want blocked on permission by codex: \"Apply patch?\"", *status)
	}
	if blocked.ProgramTitle != "refactor task" {
		t.Fatalf("program title = %q, want the spinner glyph stripped", blocked.ProgramTitle)
	}
	if !strings.HasSuffix(blocked.Pwd, "/tmp/project") {
		t.Fatalf("pwd = %q, want the shell's /tmp/project", blocked.Pwd)
	}

	// Done stays until someone looks: attaching clears it.
	controller.writeTerminal(t, terminalID, runID, `printf '\033]7501;state=done\033\\'`+"\n")
	waitForListUpsert(t, observer, func(summary wire.TerminalSummary) bool {
		return summary.TerminalID == terminalID && summary.ProgramStatus != nil &&
			summary.ProgramStatus.State == terminal.ProgramDone
	})
	viewer := dialRecordingClient(t, url)
	if attach := viewer.mustAttachTerminal(t, terminalID, 80, 24); attach.Terminal.ProgramStatus != nil {
		t.Fatalf("attach still shows %+v; attaching sees it", *attach.Terminal.ProgramStatus)
	}
	waitForListUpsert(t, observer, func(summary wire.TerminalSummary) bool {
		return summary.TerminalID == terminalID && summary.ProgramStatus == nil
	})
}

// Clients render the same output as the daemon but never answer it, so a
// device attributes query gets one reply however many views are attached.
// No view draws Kitty images, so the Kitty support query that programs send
// before it goes unanswered, which is how they detect it isn't supported.
func TestTerminalQueriesGetExactlyOneReply(t *testing.T) {
	for _, viewers := range []int{0, 1, 2} {
		t.Run(strings.Repeat("viewer", viewers), func(t *testing.T) {
			useQuietTestShell(t)
			s := newTestServer(t)
			defer s.Close()
			url := newWSTestServer(t, s)
			client := dialRecordingClient(t, url)
			created := createTestTerminal(t, client)
			terminalID, runID := created.Terminal.TerminalID, created.RunID
			if viewers == 2 {
				dialRecordingClient(t, url).mustAttachTerminal(t, terminalID, 80, 24)
			}

			// Ask, wait for every reply to arrive, then read them in one go.
			replies := filepath.Join(t.TempDir(), "replies")
			client.writeTerminal(t, terminalID, runID, "sleep 1; stty raw -echo; "+
				"printf '\\033_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\\033\\\\\\033[c'; sleep 1; "+
				"dd bs=256 count=1 2>/dev/null | od -An -tx1 > "+replies+"; stty sane\n")
			if viewers == 0 {
				client.notify(t, wire.MethodTerminalDetach, wire.TerminalDetachParams{TerminalID: terminalID})
			}
			var got string
			waitUntil(t, "the program's record of replies", func() bool {
				data, err := os.ReadFile(replies)
				got = strings.Join(strings.Fields(string(data)), " ")
				return err == nil && got != ""
			})
			// ESC [ ? 6 2 ; 2 2 ; 5 2 c: Ghostty's VT220 with color and clipboard.
			if want := "1b 5b 3f 36 32 3b 32 32 3b 35 32 63"; got != want {
				t.Fatalf("replies = %q, want exactly one %q", got, want)
			}
		})
	}
}

// Agents animate the start of their titles: Claude Code alternates ◐ ◑ and
// rests on ✳, Codex steps braille frames every 100 ms and blinks "[ ! ]" /
// "[ . ]" while it needs the user. The list shows the stable text once
// instead of an update per frame.
func TestTerminalTitleAnimationsDontChurnTheList(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	observer := dialRecordingClient(t, url)
	subscribeTerminalListSnapshot(t, observer)
	controller := dialRecordingClient(t, url)
	created := createTestTerminal(t, controller)
	terminalID := created.Terminal.TerminalID

	var script strings.Builder
	for _, title := range []string{
		"◐ Numbers in words", "◑ Numbers in words", "✳ Numbers in words",
		"⠋ Spell out 1–200 | maiD", "⠙ Spell out 1–200 | maiD", "Spell out 1–200 | maiD",
		"[ ! ] Action Required | maiD", "[ . ] Action Required | maiD", "[ ! ] Action Required | maiD",
		"end",
	} {
		script.WriteString(`printf '\033]0;` + title + `\007'; sleep 0.05; `)
	}
	controller.writeTerminal(t, terminalID, created.RunID, script.String()+"\n")
	waitForListUpsert(t, observer, func(summary wire.TerminalSummary) bool {
		return summary.TerminalID == terminalID && summary.ProgramTitle == "end"
	})

	var titles []string
	for _, item := range observer.listItemsSnapshot() {
		if item.Terminal != nil && item.Terminal.TerminalID == terminalID &&
			item.Terminal.ProgramTitle != "" && !slices.Contains(titles, item.Terminal.ProgramTitle) {
			titles = append(titles, item.Terminal.ProgramTitle)
		}
	}
	want := []string{"Numbers in words", "Spell out 1–200 | maiD", "Action Required | maiD", "end"}
	if !slices.Equal(titles, want) {
		t.Fatalf("list titles = %q, want %q", titles, want)
	}
}
