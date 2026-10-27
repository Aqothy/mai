package claudecode

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/provider/providertest"
)

type testInstance struct {
	*Instance
	events    *providertest.Recorder
	configDir string
}

func openTest(t *testing.T) testInstance {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	configDir := t.TempDir()
	config, err := json.Marshal(Config{Command: []string{executable}, Env: map[string]string{"CLAUDE_FAKE_CLI": "1", "GORACE": "atexit_sleep_ms=0"}, ConfigDir: configDir})
	if err != nil {
		t.Fatal(err)
	}
	events := providertest.NewRecorder()
	instance, err := OpenInstance(context.Background(), provider.InstanceSpec{InstanceID: "claude-code", Name: "Claude Code", Config: config}, provider.Host{Emit: events.Emit})
	if err != nil {
		t.Fatalf("OpenInstance: %v", err)
	}
	t.Cleanup(func() { _ = instance.Close() })
	return testInstance{Instance: instance, events: events, configDir: configDir}
}

// open opens a new session in a fresh workspace.
func (h testInstance) open(t *testing.T) (string, string) {
	t.Helper()
	cwd := t.TempDir()
	opened, err := h.Open(context.Background(), provider.OpenInput{Workspace: provider.Workspace{Cwd: cwd}})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	return opened.Session, cwd
}

// send sends text as a new message and returns its delivery ID.
func (h testInstance) send(t *testing.T, session, text string, steer bool) string {
	t.Helper()
	delivery := newSessionUUID()
	ack, err := h.Send(context.Background(), session, provider.SendInput{Delivery: delivery, Text: text, Steer: steer})
	if err != nil {
		t.Fatalf("Send %q: %v", text, err)
	}
	if ack.Turn != "" {
		t.Fatalf("ack = %#v; the echo names the turn", ack)
	}
	return delivery
}

func (h testInstance) request(t *testing.T, session string) provider.RequestOpened {
	t.Helper()
	return h.events.WaitFor(t, "a request", func(event provider.Event) bool {
		_, ok := event.Body.(provider.RequestOpened)
		return ok && event.Session == session
	}).Body.(provider.RequestOpened)
}

func (h testInstance) answer(t *testing.T, session string, request provider.RequestOpened, action string) {
	t.Helper()
	chosen, ok := request.Ask.Action(action)
	if !ok {
		t.Fatalf("request %#v offers no %q", request.Ask, action)
	}
	if err := h.Respond(context.Background(), session, request.Request, provider.RequestAnswer{Action: chosen}); err != nil {
		t.Fatalf("Respond: %v", err)
	}
}

func (h testInstance) history(t *testing.T, session string) provider.HistoryPage {
	t.Helper()
	page, err := h.History(context.Background(), session, provider.Workspace{}, "")
	if err != nil {
		t.Fatalf("History %s: %v", session, err)
	}
	return page
}

// requireLiveIsHistory checks that the session's live events fold to the
// turns its transcript replays, entry for entry.
func (h testInstance) requireLiveIsHistory(t *testing.T, session string) []provider.HistoryTurn {
	t.Helper()
	live, replayed := comparable(h.events.LiveTurns(session)), comparable(h.history(t, session).Turns)
	if !reflect.DeepEqual(live, replayed) {
		liveJSON, _ := json.MarshalIndent(live, "", "  ")
		replayedJSON, _ := json.MarshalIndent(replayed, "", "  ")
		t.Fatalf("live turns differ from history\nlive: %s\nhistory: %s", liveJSON, replayedJSON)
	}
	return replayed
}

// comparable drops the times, which live are the stream's and in replay the
// transcript's.
func comparable(turns []provider.HistoryTurn) []provider.HistoryTurn {
	out := slices.Clone(turns)
	for index := range out {
		out[index].StartedAt = time.Time{}
		out[index].Entries = slices.Clone(out[index].Entries)
		for entry := range out[index].Entries {
			out[index].Entries[entry].At = time.Time{}
		}
	}
	return out
}

func entryTexts(turn provider.HistoryTurn) []string {
	var texts []string
	for _, entry := range turn.Entries {
		texts = append(texts, string(entry.Kind)+":"+entry.Text)
	}
	return texts
}

func lines(t *testing.T, path string) []string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSpace(string(data)), "\n")
}

func TestOpenInstanceProbes(t *testing.T) {
	h := openTest(t)
	info := h.Info()
	if info.Status != provider.InstanceStatusInitialized || info.Auth.Status != provider.AuthStatusAuthenticated {
		t.Fatalf("info = %#v, want initialized and signed in from the probe", info)
	}
	if !reflect.DeepEqual(info.Capabilities, Driver.Static(provider.InstanceSpec{}).Capabilities) {
		t.Fatalf("capabilities = %#v, want the static ones", info.Capabilities)
	}
}

// A turn streams text and a tool, asks before running it, and ends as its
// transcript replays it, with the delivery's ID as the turn and the message.
func TestTurnStreamsWhatHistoryReplays(t *testing.T) {
	h := openTest(t)
	session, _ := h.open(t)
	delivery := h.send(t, session, "hello", false)
	request := h.request(t, session)
	if request.Turn != delivery || request.Entry != "toolu_1" {
		t.Fatalf("request = %#v, want the tool's in turn %s", request, delivery)
	}
	if _, ok := request.Ask.Action("acceptForSession"); !ok {
		t.Fatalf("actions = %#v, want a lasting approval for the suggested rule", request.Ask.Actions)
	}
	h.answer(t, session, request, "accept")
	h.events.WaitFor(t, "the turn to settle", providertest.Settled(delivery))

	started := h.events.WaitFor(t, "the turn to start", func(event provider.Event) bool {
		_, ok := event.Body.(provider.TurnStarted)
		return ok
	}).Body.(provider.TurnStarted)
	if started != (provider.TurnStarted{Turn: delivery, By: provider.TurnByClient, Delivery: delivery}) {
		t.Fatalf("started = %#v", started)
	}
	h.events.WaitFor(t, "streamed text", func(event provider.Event) bool {
		appended, ok := event.Body.(provider.TextAppended)
		return ok && appended.Entry == "msg_1/0" && appended.Text == "world"
	})
	turns := h.requireLiveIsHistory(t, session)
	if len(turns) != 1 || !slices.Equal(entryTexts(turns[0]), []string{"user_message:hello", "assistant_message:Hello world", "command_execution:", "assistant_message:Done"}) {
		t.Fatalf("turns = %#v", turns)
	}
	if user := turns[0].Entries[0]; user.Ref != delivery || user.Delivery != delivery {
		t.Fatalf("user entry = %#v, want the delivery's ref and ID", user)
	}
	if tool := turns[0].Entries[2]; tool.Ref != "toolu_1" || tool.Status != provider.ItemStatusCompleted || tool.Tool.Output != "hi" {
		t.Fatalf("tool = %#v", tool)
	}
	if found, err := h.Delivered(context.Background(), session, provider.DeliveryProbe{Delivery: delivery}); err != nil || found != provider.TriYes {
		t.Fatalf("Delivered = %v, %v; want yes", found, err)
	}
	if found, err := h.Delivered(context.Background(), session, provider.DeliveryProbe{Delivery: newSessionUUID()}); err != nil || found != provider.TriNo {
		t.Fatalf("Delivered of another message = %v, %v; want no", found, err)
	}
}

// A steer the CLI folds into the running query joins its turn; one the query
// missed starts the next turn, which its echo names.
func TestSteers(t *testing.T) {
	for _, tt := range []struct {
		name, text string
		joins      bool
	}{
		{"folded", "FOLD this in", true},
		{"missed", "after that", false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			h := openTest(t)
			session, _ := h.open(t)
			first := h.send(t, session, "SLOW", false)
			h.events.WaitFor(t, "the turn to start", func(event provider.Event) bool {
				started, ok := event.Body.(provider.TurnStarted)
				return ok && started.Turn == first
			})
			steer := h.send(t, session, tt.text, true)
			last := first
			if !tt.joins {
				last = steer
				started := h.events.WaitFor(t, "the steer's turn", func(event provider.Event) bool {
					started, ok := event.Body.(provider.TurnStarted)
					return ok && started.Turn == steer
				}).Body.(provider.TurnStarted)
				if started.Delivery != steer {
					t.Fatalf("started = %#v, want the steer's delivery", started)
				}
			}
			h.events.WaitFor(t, "the last turn to settle", providertest.Settled(last))
			turns := h.requireLiveIsHistory(t, session)
			want := [][]string{{"user_message:SLOW", "assistant_message:Working on it", "user_message:" + tt.text, "assistant_message:Folded in"}}
			if !tt.joins {
				want = [][]string{{"user_message:SLOW", "assistant_message:Working on it"}, {"user_message:after that", "assistant_message:Later reply"}}
			}
			if len(turns) != len(want) {
				t.Fatalf("turns = %#v, want %q", turns, want)
			}
			for index := range want {
				if !slices.Equal(entryTexts(turns[index]), want[index]) {
					t.Fatalf("turn %d = %q, want %q", index, entryTexts(turns[index]), want[index])
				}
			}
			if found, err := h.Delivered(context.Background(), session, provider.DeliveryProbe{Delivery: steer}); err != nil || found != provider.TriYes {
				t.Fatalf("Delivered steer = %v, %v", found, err)
			}
		})
	}
}

func TestSteerWithNoTurnRunningIsRefused(t *testing.T) {
	h := openTest(t)
	session, _ := h.open(t)
	_, err := h.Send(context.Background(), session, provider.SendInput{Delivery: newSessionUUID(), Text: "late", Steer: true})
	if !errors.Is(err, provider.ErrTurnNotRunning) {
		t.Fatalf("Send = %v, want ErrTurnNotRunning", err)
	}
}

// Output the CLI produces on its own, woken by a background task, is a turn
// of its own, the provider's.
func TestCLIStartedOutputGetsATurnOfItsOwn(t *testing.T) {
	for _, test := range []struct{ prompt, reply string }{
		{"WAKE", "Background task finished"},
		// The report shows in the subagent's own session, not as a prompt.
		{"HANDBACK", "The subagent said: report"},
	} {
		t.Run(test.prompt, func(t *testing.T) {
			h := openTest(t)
			session, _ := h.open(t)
			h.send(t, session, test.prompt, false)
			started := h.events.WaitFor(t, "the CLI's turn", func(event provider.Event) bool {
				started, ok := event.Body.(provider.TurnStarted)
				return ok && started.By == provider.TurnByProvider
			}).Body.(provider.TurnStarted)
			h.events.WaitFor(t, "its settle", providertest.Settled(started.Turn))
			turns := h.requireLiveIsHistory(t, session)
			if len(turns) != 2 || turns[1].Ref != started.Turn || !slices.Equal(entryTexts(turns[1]), []string{"assistant_message:" + test.reply}) {
				t.Fatalf("turns = %#v", turns)
			}
		})
	}
}

// A subagent streams into a session of its own, which its transcript
// replays, and its session's history names it.
func TestSubagentStreamsIntoItsOwnSession(t *testing.T) {
	// A subagent ends with its answer, or reports it through a tool.
	for _, prompt := range []string{"AGENT", "REPORT"} {
		t.Run(prompt, func(t *testing.T) {
			h := openTest(t)
			session, _ := h.open(t)
			delivery := h.send(t, session, prompt, false)
			h.events.WaitFor(t, "the turn to settle", providertest.Settled(delivery))
			key := session + "/agent-a1b2c3d4e5f6a7b8c"
			seen := h.events.WaitFor(t, "the subagent", func(event provider.Event) bool {
				_, ok := event.Body.(provider.SubagentSeen)
				return ok
			}).Body.(provider.SubagentSeen)
			if seen.Parent != session || seen.Item != "toolu_agent" || seen.Session != key || seen.AcceptsInput {
				t.Fatalf("seen = %#v", seen)
			}
			// The host learns of the session before anything streams into it.
			for _, event := range h.events.Snapshot() {
				if _, ok := event.Body.(provider.SubagentSeen); ok {
					break
				}
				if event.Session == key {
					t.Fatalf("%#v came before the subagent was named", event)
				}
			}
			turns := h.requireLiveIsHistory(t, key)
			if len(turns) != 1 || !slices.Equal(entryTexts(turns[0]), []string{"user_message:Look around", "command_execution:", "assistant_message:Found a README"}) || turns[0].State != provider.TurnCompleted {
				t.Fatalf("subagent turns = %#v", turns)
			}
			h.requireLiveIsHistory(t, session)
			page := h.history(t, session)
			if len(page.Subagents) != 1 || page.Subagents[0].Session != key || page.Subagents[0].Model != "fake-model" {
				t.Fatalf("subagents = %#v", page.Subagents)
			}
		})
	}
}

// A compaction shows once, and the message the CLI sends again after it
// doesn't show twice.
func TestCompactionAndTheResentMessageShowOnce(t *testing.T) {
	h := openTest(t)
	session, _ := h.open(t)
	delivery := h.send(t, session, "COMPACT", false)
	h.events.WaitFor(t, "the turn to settle", providertest.Settled(delivery))
	turns := h.requireLiveIsHistory(t, session)
	if len(turns) != 1 || !slices.Equal(entryTexts(turns[0]), []string{"user_message:COMPACT", "assistant_message:Before compacting", "context_compaction:"}) {
		t.Fatalf("turns = %q", entryTexts(turns[0]))
	}
}

// A background tool runs on after its turn until its task ends; StopItem
// stops it.
func TestBackgroundToolRunsUntilStopped(t *testing.T) {
	h := openTest(t)
	session, _ := h.open(t)
	delivery := h.send(t, session, "BACKGROUND", false)
	h.events.WaitFor(t, "the turn to settle", providertest.Settled(delivery))
	if turns := h.events.LiveTurns(session); turns[0].Entries[1].Status != provider.ItemStatusInProgress || !turns[0].Entries[1].Tool.Background {
		t.Fatalf("tool = %#v, want running in the background", turns[0].Entries[1])
	}
	if err := h.StopItem(context.Background(), session, "toolu_bg"); err != nil {
		t.Fatalf("StopItem: %v", err)
	}
	h.events.WaitFor(t, "the tool to stop", func(event provider.Event) bool {
		upserted, ok := event.Body.(provider.EntryUpserted)
		return ok && upserted.Entry.Ref == "toolu_bg" && upserted.Entry.Status == provider.ItemStatusInterrupted
	})
	h.requireLiveIsHistory(t, session)
}

func TestInterruptEndsTheTurnAsInterrupted(t *testing.T) {
	h := openTest(t)
	session, _ := h.open(t)
	delivery := h.send(t, session, "SLOW", false)
	h.events.WaitFor(t, "streamed text", func(event provider.Event) bool {
		_, ok := event.Body.(provider.EntryUpserted)
		return ok
	})
	if err := h.Interrupt(context.Background(), session, delivery); err != nil {
		t.Fatalf("Interrupt: %v", err)
	}
	settled := h.events.WaitFor(t, "the turn to settle", providertest.Settled(delivery)).Body.(provider.TurnSettled)
	if settled.State != provider.TurnInterrupted {
		t.Fatalf("settled = %#v", settled)
	}
	h.requireLiveIsHistory(t, session)
}

// Release ends a running turn as interrupted without closing the session as
// failed; an exit of the CLI's own does.
func TestReleaseAndExit(t *testing.T) {
	h := openTest(t)
	session, _ := h.open(t)
	delivery := h.send(t, session, "SLOW", false)
	h.events.WaitFor(t, "the turn to start", func(event provider.Event) bool {
		_, ok := event.Body.(provider.TurnStarted)
		return ok
	})
	if err := h.Release(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	if settled := h.events.WaitFor(t, "the settle", providertest.Settled(delivery)).Body.(provider.TurnSettled); settled.State != provider.TurnInterrupted {
		t.Fatalf("released turn = %#v", settled)
	}

	crashing, _ := h.open(t)
	crashed := h.send(t, crashing, "CRASH", false)
	if settled := h.events.WaitFor(t, "the settle", providertest.Settled(crashed)).Body.(provider.TurnSettled); settled.State != provider.TurnFailed {
		t.Fatalf("crashed turn = %#v", settled)
	}
	h.events.WaitFor(t, "the session to close", func(event provider.Event) bool {
		_, ok := event.Body.(provider.SessionClosed)
		return ok && event.Session == crashing
	})
	for _, event := range h.events.Snapshot() {
		if _, ok := event.Body.(provider.SessionClosed); ok && event.Session == session {
			t.Fatal("a released session closed as if it failed")
		}
	}
	if _, err := h.Send(context.Background(), crashing, provider.SendInput{Delivery: newSessionUUID(), Text: "again"}); err == nil {
		t.Fatal("Send to a closed session succeeded")
	}
}

func TestClearMovesToTheNewSession(t *testing.T) {
	h := openTest(t)
	session, _ := h.open(t)
	h.send(t, session, "CLEAR", false)
	replaced := h.events.WaitFor(t, "the replacement", func(event provider.Event) bool {
		_, ok := event.Body.(provider.SessionReplaced)
		return ok
	})
	if replaced.Session != session || replaced.Body.(provider.SessionReplaced).New != "22222222-2222-4222-8222-222222222222" {
		t.Fatalf("replaced = %#v", replaced)
	}
	if _, err := h.session("22222222-2222-4222-8222-222222222222"); err != nil {
		t.Fatalf("new session: %v", err)
	}
}

func TestSignedOutChangesTheInstance(t *testing.T) {
	h := openTest(t)
	session, _ := h.open(t)
	delivery := h.send(t, session, "SIGNED_OUT", false)
	changed := h.events.WaitFor(t, "the instance to change", func(event provider.Event) bool {
		_, ok := event.Body.(provider.InstanceChanged)
		return ok
	}).Body.(provider.InstanceChanged)
	if changed.Info.Auth.Status != provider.AuthStatusUnauthenticated {
		t.Fatalf("auth = %#v", changed.Info.Auth)
	}
	settled := h.events.WaitFor(t, "the settle", providertest.Settled(delivery)).Body.(provider.TurnSettled)
	if settled.State != provider.TurnFailed || !strings.Contains(settled.Error, "Invalid API key") {
		t.Fatalf("settled = %#v", settled)
	}
	h.requireLiveIsHistory(t, session)
}

func TestSettingsReachTheCLI(t *testing.T) {
	h := openTest(t)
	cwd := t.TempDir()
	opened, err := h.Open(context.Background(), provider.OpenInput{
		Workspace: provider.Workspace{Cwd: cwd}, Instructions: "Work in maiD.",
		MCP: &provider.MCPServer{Name: "maid", URL: "http://127.0.0.1:1/mcp", Headers: map[string]string{"Authorization": "Bearer secret"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	launch := strings.Join(lines(t, filepath.Join(cwd, fakeLaunchLog)), "\n")
	if !strings.Contains(launch, "--append-system-prompt Work in maiD.") || !strings.Contains(launch, "--mcp-config ") {
		t.Fatalf("launch = %q", launch)
	}
	config := strings.Fields(launch[strings.Index(launch, "--mcp-config ")+len("--mcp-config "):])[0]
	info, err := os.Stat(config)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("MCP config %s: %v %v, want the user's alone", config, info, err)
	}
	if err := h.Configure(context.Background(), opened.Session, provider.ConfigOptionSelection{OptionID: "effort", Value: "low"}); err != nil {
		t.Fatalf("Configure: %v", err)
	}
	if control := strings.Join(lines(t, filepath.Join(cwd, fakeControlLog)), "\n"); !strings.Contains(control, `"effortLevel":"low"`) {
		t.Fatalf("control = %s", control)
	}
	h.events.WaitFor(t, "the options", func(event provider.Event) bool {
		changed, ok := event.Body.(provider.ConfigChanged)
		effort, _ := provider.CurrentConfigString(changed.Options, "effort")
		return ok && effort == "low"
	})
	if err := h.Release(context.Background(), opened.Session); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(config); !os.IsNotExist(err) {
		t.Fatalf("MCP config outlived its process: %v", err)
	}
}

// A session whose transcript the CLI cleaned up opens as a new session under
// a new key, so the host knows its conversation is gone and catches it up;
// its history is not found.
func TestALostTranscriptOpensANewSession(t *testing.T) {
	h := openTest(t)
	session, cwd := h.open(t)
	delivery := h.send(t, session, "hello", false)
	h.answer(t, session, h.request(t, session), "accept")
	h.events.WaitFor(t, "the turn to settle", providertest.Settled(delivery))
	path, err := h.findTranscript(session)
	if err != nil {
		t.Fatal(err)
	}
	if err := h.Release(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if _, err := h.History(context.Background(), session, provider.Workspace{}, ""); !errors.Is(err, provider.ErrSessionNotFound) {
		t.Fatalf("History of the lost session = %v, want not found", err)
	}
	opened, err := h.Open(context.Background(), provider.OpenInput{Session: session, Workspace: provider.Workspace{Cwd: cwd}})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if opened.Session == session {
		t.Fatalf("reopened under the lost session's key %q, want a new one", session)
	}
	if launches := lines(t, filepath.Join(cwd, fakeLaunchLog)); strings.Contains(launches[len(launches)-1], "--resume") {
		t.Fatalf("launch = %q, want a new session, not a resume", launches[len(launches)-1])
	}
}

// Opening a chat again doesn't read a transcript that hasn't changed since
// a read found nothing new; one the CLI wrote to is read again.
func TestAnUnchangedTranscriptIsNotReadAgain(t *testing.T) {
	h := openTest(t)
	session, _ := h.open(t)
	delivery := h.send(t, session, "hello", false)
	h.answer(t, session, h.request(t, session), "accept")
	h.events.WaitFor(t, "the turn to settle", providertest.Settled(delivery))
	if err := h.Release(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	page, err := h.History(context.Background(), session, provider.Workspace{}, "")
	if err != nil || len(page.Turns) == 0 {
		t.Fatalf("History = %#v, %v", page, err)
	}
	marker := provider.Marker(page.Turns[len(page.Turns)-1].Ref)
	path, err := h.findTranscript(session)
	if err != nil {
		t.Fatal(err)
	}
	if page, err := h.History(context.Background(), session, provider.Workspace{}, marker); err != nil || len(page.Turns) != 0 {
		t.Fatalf("History after the last turn = %#v, %v; want nothing new", page, err)
	}
	if err := os.Chmod(path, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(path, 0o600) })
	if page, err := h.History(context.Background(), session, provider.Workspace{}, marker); err != nil || len(page.Turns) != 0 || page.Next != marker {
		t.Fatalf("History of the unchanged transcript = %#v, %v; want nothing new without reading it", page, err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(readFile(t, path), []byte(`{"type":"custom-title","customTitle":"Renamed"}`+"\n")...), 0); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0); err != nil {
		t.Fatal(err)
	}
	if _, err := h.History(context.Background(), session, provider.Workspace{}, marker); err == nil {
		t.Fatal("History of the changed transcript didn't read it")
	}
}

// Sessions are listed by title, renamed with a custom-title line, forked
// through a turn into the fork's workspace, and deleted.
func TestSessionsRenameForkDelete(t *testing.T) {
	h := openTest(t)
	session, cwd := h.open(t)
	first := h.send(t, session, "WAKE", false)
	h.events.WaitFor(t, "the CLI's turn to settle", func(event provider.Event) bool {
		settled, ok := event.Body.(provider.TurnSettled)
		return ok && strings.HasPrefix(settled.Turn, "wake:")
	})
	if err := h.Rename(context.Background(), session, "Named"); err != nil {
		t.Fatal(err)
	}
	summaries, err := h.Sessions(context.Background(), cwd)
	if err != nil || len(summaries) != 1 || summaries[0].SessionID != session || summaries[0].Title != "Named" {
		t.Fatalf("Sessions = %#v, %v", summaries, err)
	}
	if err := h.Release(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	forkCwd := t.TempDir()
	fork, err := h.Fork(context.Background(), provider.ForkInput{Session: session, Through: first, Workspace: provider.Workspace{Cwd: forkCwd}})
	if err != nil {
		t.Fatalf("Fork: %v", err)
	}
	forked := h.history(t, fork).Turns
	if len(forked) != 1 || !slices.Equal(entryTexts(forked[0]), []string{"user_message:WAKE", "assistant_message:Started a background task"}) {
		t.Fatalf("fork turns = %#v", forked)
	}
	if summaries, _ := h.Sessions(context.Background(), forkCwd); len(summaries) != 1 || summaries[0].Title != "Named (fork)" {
		t.Fatalf("fork summaries = %#v", summaries)
	}
	if err := h.Delete(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	if _, err := h.History(context.Background(), session, provider.Workspace{}, ""); !errors.Is(err, provider.ErrSessionNotFound) {
		t.Fatalf("History after delete = %v, want not found", err)
	}
}

func readFile(t *testing.T, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return data
}
