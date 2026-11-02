package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
)

// sessionRecords reads what -sessions logged.
func sessionRecords(t *testing.T, path string) []fakeSessionRecord {
	t.Helper()
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	var records []fakeSessionRecord
	for line := range strings.Lines(string(raw)) {
		var record fakeSessionRecord
		if err := json.Unmarshal([]byte(line), &record); err != nil {
			t.Fatalf("sessions log line %q: %v", line, err)
		}
		records = append(records, record)
	}
	return records
}

func processAlive(pid int) bool {
	return syscall.Kill(pid, 0) == nil
}

// stopIdleNow stops every process that may stop, as the daemon's ticker does
// once they've been idle long enough.
func stopIdleNow(t *testing.T, s *Server) {
	t.Helper()
	s.providerService.StopIdle(time.Now().Add(time.Hour), func(id provider.InstanceID, generation uint64) bool {
		return s.engine.ProcessBusy(s.ctx, id, generation)
	})
}

// A chat's agent runs in the chat's folder, whatever the spec lets it assume:
// each folder has its own process, and chats in one folder share it.
func TestAnAgentRunsOneProcessPerFolder(t *testing.T) {
	s := newTestServer(t)
	log := filepath.Join(t.TempDir(), "sessions")
	startFakeACPAgent(t, s, "agent", "-sessions", log, "-history", t.TempDir())
	client := newRecordingClient(t, s)
	first, second := client.addProject(t, t.TempDir()), client.addProject(t, t.TempDir())

	for _, folder := range []string{first, first, second} {
		thread := client.createThread(t, "agent", folder).Thread
		client.subscribe(t, thread)
		client.waitSettled(t, thread, client.deliver(t, thread, "hello").Delivery)
	}

	records := sessionRecords(t, log)
	if len(records) != 3 {
		t.Fatalf("sessions = %#v, want one for each chat", records)
	}
	for _, record := range records {
		if record.ProcessCwd != record.SessionCwd {
			t.Fatalf("session %#v runs in a process of another folder", record)
		}
	}
	if records[0].SessionCwd != first || records[1].SessionCwd != first || records[2].SessionCwd != second {
		t.Fatalf("session folders = %#v, want %s, %s, %s", records, first, first, second)
	}
	if records[0].PID != records[1].PID {
		t.Fatalf("chats in one folder ran on processes %d and %d, want one", records[0].PID, records[1].PID)
	}
	if records[0].PID == records[2].PID {
		t.Fatalf("chats in two folders share process %d", records[0].PID)
	}

	if _, err := s.providerService.RestartInstance(s.ctx, "agent"); err != nil {
		t.Fatal(err)
	}
	if processAlive(records[0].PID) || processAlive(records[2].PID) {
		t.Fatal("a restart left an old process running")
	}
}

// One folder's crash is that folder's: another's turn runs on, and the crashed
// folder's next message starts a new process there.
func TestACrashEndsOnlyItsFoldersProcess(t *testing.T) {
	s := newTestServer(t)
	work := t.TempDir()
	log := filepath.Join(work, "sessions")
	startFakeACPAgent(t, s, "agent", "-sessions", log, "-history", t.TempDir())
	client := newRecordingClient(t, s)
	running := client.createThread(t, "agent", t.TempDir()).Thread
	crashing := client.createThread(t, "agent", t.TempDir()).Thread
	client.subscribe(t, running)
	client.subscribe(t, crashing)
	blocked := client.deliver(t, running, "block "+work).Delivery
	waitForFile(t, filepath.Join(work, "ready"))
	client.waitSettled(t, crashing, client.deliver(t, crashing, "hello").Delivery)

	records := sessionRecords(t, log)
	if len(records) != 2 {
		t.Fatalf("sessions = %#v", records)
	}
	crashed := records[1]
	if err := syscall.Kill(crashed.PID, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	waitUntil(t, "a new process to replace the crashed one", func() bool {
		instance, _, err := s.providerService.Instance(s.ctx, "agent", crashed.SessionCwd)
		return err == nil && instance.Info().PID != crashed.PID
	})

	turn := client.waitSettled(t, crashing, client.deliver(t, crashing, "again").Delivery)
	if turn.State != provider.TurnCompleted {
		t.Fatalf("turn after the crash = %#v", turn)
	}
	if turns := client.subscribe(t, running).Turns; len(turns) != 1 || turns[0].State != provider.TurnRunning {
		t.Fatalf("the other folder's turn after the crash = %#v", turns)
	}
	latest := sessionRecords(t, log)
	if last := latest[len(latest)-1]; last.ProcessCwd != crashed.SessionCwd || last.PID == crashed.PID {
		t.Fatalf("session after the crash = %#v, want a new process in %s", last, crashed.SessionCwd)
	}
	if err := os.WriteFile(filepath.Join(work, "release"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	client.waitSettled(t, running, blocked)
}

// An idle process stops, and nobody can tell but for the wait: the chat shows
// no failure and its next message goes on in the same session. A process stays
// while a turn runs on it or a draft holds its settings.
func TestIdleProcessesStopWithoutAChatNoticing(t *testing.T) {
	s := newTestServer(t)
	work := t.TempDir()
	log := filepath.Join(work, "sessions")
	startFakeACPAgent(t, s, "agent", "-sessions", log, "-history", t.TempDir())
	client := newRecordingClient(t, s)
	idle := client.createThread(t, "agent", t.TempDir()).Thread
	running := client.createThread(t, "agent", t.TempDir()).Thread
	client.subscribe(t, idle)
	client.subscribe(t, running)
	client.waitSettled(t, idle, client.deliver(t, idle, "hello").Delivery)
	blocked := client.deliver(t, running, "block "+work).Delivery
	waitForFile(t, filepath.Join(work, "ready"))
	draftFolder := client.addProject(t, t.TempDir())
	drafter := newRecordingClient(t, s)
	drafter.call(t, wire.MethodProviderOptionsGet, wire.ProviderOptionsGetParams{ProviderInstanceID: "agent", Cwd: draftFolder}, nil)

	records := sessionRecords(t, log)
	if len(records) != 3 {
		t.Fatalf("sessions = %#v", records)
	}
	byFolder := map[string]fakeSessionRecord{}
	for _, record := range records {
		byFolder[record.SessionCwd] = record
	}
	idleRecord := records[0]
	stopIdleNow(t, s)

	waitUntil(t, "the idle process to stop", func() bool { return !processAlive(idleRecord.PID) })
	if !processAlive(byFolder[draftFolder].PID) {
		t.Fatal("a draft's process stopped")
	}
	runningRecord := records[1]
	if !processAlive(runningRecord.PID) {
		t.Fatal("a running turn's process stopped")
	}
	if turns := client.subscribe(t, idle).Turns; len(turns) != 1 || turns[0].State != provider.TurnCompleted {
		t.Fatalf("turns of the idle chat = %#v, want its finished turn untouched", turns)
	}
	if info, ok := s.providerService.Info("agent"); !ok || info.Status != provider.InstanceStatusInitialized {
		t.Fatalf("info with processes running = %#v, %v", info, ok)
	}

	turn := client.waitSettled(t, idle, client.deliver(t, idle, "again").Delivery)
	if turn.State != provider.TurnCompleted {
		t.Fatalf("turn on a stopped process = %#v", turn)
	}
	latest := sessionRecords(t, log)
	resumed := latest[len(latest)-1]
	if resumed.Session != idleRecord.Session || resumed.ProcessCwd != idleRecord.SessionCwd || resumed.PID == idleRecord.PID {
		t.Fatalf("resumed = %#v, want session %s on a new process in %s", resumed, idleRecord.Session, idleRecord.SessionCwd)
	}

	if err := os.WriteFile(filepath.Join(work, "release"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	client.waitSettled(t, running, blocked)
	_ = drafter.conn.Close()
	waitUntil(t, "every process to stop", func() bool {
		stopIdleNow(t, s)
		return !slices.ContainsFunc(sessionRecords(t, log), func(record fakeSessionRecord) bool { return processAlive(record.PID) })
	})
	// With none running, an agent is still known: not "exited", which would
	// hide it, and with its capabilities, which the engine consults.
	info, ok := s.providerService.Info("agent")
	if !ok || info.Status != provider.InstanceStatusConfigured || !info.Capabilities.Sessions {
		t.Fatalf("info with nothing running = %#v, %v", info, ok)
	}
}

// An agent that breaks ACP's unique session IDs costs the chat that got a used
// one its message. The daemon runs on and the other chat keeps its conversation.
func TestAReusedSessionIDCostsOnlyThatMessage(t *testing.T) {
	s := newTestServer(t)
	startFakeACPAgent(t, s, "agent")
	client := newRecordingClient(t, s)
	first := client.createThread(t, "agent", t.TempDir()).Thread
	second := client.createThread(t, "agent", t.TempDir()).Thread
	client.subscribe(t, first)
	client.subscribe(t, second)
	client.waitSettled(t, first, client.deliver(t, first, "hello").Delivery)

	refused := client.deliver(t, second, "hello").Delivery
	client.waitEvent(t, "the second chat's message to be refused", func(event orchestration.ThreadEvent) bool {
		return event.Thread == second && event.Kind == orchestration.EventDelivery && event.Delivery.ID == refused &&
			event.Delivery.State == orchestration.DeliveryRefused && strings.Contains(event.Delivery.Reason, "ID of another chat")
	})
	turn := client.waitSettled(t, first, client.deliver(t, first, "again").Delivery)
	if turn.State != provider.TurnCompleted {
		t.Fatalf("first chat's turn = %#v", turn)
	}
	if turns := client.subscribe(t, first).Turns; len(turns) != 2 {
		t.Fatalf("first chat's turns = %#v, want its own two", turns)
	}
}

// A sign-in outlives the process it ran on.
func TestAStoppedAgentStaysSignedIn(t *testing.T) {
	s := newTestServer(t)
	startFakeACPAgent(t, s, "agent")
	client := newRecordingClient(t, s)
	client.call(t, wire.MethodProviderAuthenticate, wire.ProviderAuthenticateParams{InstanceID: "agent", MethodID: "agent-login"}, nil)
	waitUntil(t, "the agent to stop", func() bool {
		stopIdleNow(t, s)
		return s.providerService.ProcessCount("agent") == 0
	})
	info, ok := s.providerService.Info("agent")
	if !ok || info.Status != provider.InstanceStatusConfigured || info.Auth.Status != provider.AuthStatusAuthenticated {
		t.Fatalf("info after stopping = %#v, %v", info, ok)
	}
}

// Agents run in other folders and get paths in the data directory, so a relative
// MAID_DATA_DIR has to become absolute.
func TestARelativeDataDirIsMadeAbsolute(t *testing.T) {
	base := canonicalTempDir(t)
	t.Chdir(base)
	t.Setenv("MAID_DATA_DIR", "scratch/data")
	dir, err := maidDataDir()
	if err != nil || dir != filepath.Join(base, "scratch", "data") {
		t.Fatalf("maidDataDir = %q, %v", dir, err)
	}
}

// A registry agent asked for a folder runs there, one asked for none runs in
// its install directory, and a folder outside every project is refused before
// anything runs in it.
func TestRegistryStartRunsWhereItIsAsked(t *testing.T) {
	dataDir := t.TempDir()
	s := newTestServerAt(t, dataDir)
	hosts := serveFakeACPHosts(t, s)
	work := t.TempDir()
	launches := filepath.Join(work, "launches")
	archive := hosts.put("downloads.test/agent.tar.gz", fakeAgentArchive(t, "1.0.0", launches))
	hosts.setIndex(fakeBinaryAgent("qa", "1.0.0", archive, ""))
	client := newRecordingClient(t, s)
	subscribeACP(t, client)
	refreshACP(t, client)
	installACP(t, client, "qa")
	client.waitACPState(t, "qa", wire.ACPAgentInstalled)
	folders := func() []string {
		raw, err := os.ReadFile(launches + ".cwd")
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			t.Fatal(err)
		}
		return strings.Fields(string(raw))
	}

	outside := canonicalTempDir(t)
	if err := client.callErr(wire.MethodACPRegistryStart, wire.ACPRegistryStartParams{RegistryID: "qa", Cwd: outside}, nil); err == nil || !strings.Contains(err.Error(), "project") {
		t.Fatalf("start outside every project = %v, want refused", err)
	}
	if got := folders(); got != nil {
		t.Fatalf("agent ran in %v after a refused start", got)
	}

	var info provider.InstanceInfo
	client.call(t, wire.MethodACPRegistryStart, wire.ACPRegistryStartParams{RegistryID: "qa"}, &info)
	dirs := installDirs(t, dataDir, "qa")
	installDir, err := filepath.EvalSymlinks(filepath.Join(dataDir, "agents", "registry", "qa", dirs[0]))
	if err != nil {
		t.Fatal(err)
	}
	if got := folders(); !slices.Equal(got, []string{installDir}) {
		t.Fatalf("agent asked for no folder ran in %v, want its install directory %s", got, installDir)
	}

	project := client.addProject(t, t.TempDir())
	client.call(t, wire.MethodACPRegistryStart, wire.ACPRegistryStartParams{RegistryID: "qa", Cwd: project}, &info)
	// Starting a folder again finds its process, and work of no folder takes
	// the one that runs.
	client.call(t, wire.MethodACPRegistryStart, wire.ACPRegistryStartParams{RegistryID: "qa", Cwd: project}, &info)
	client.call(t, wire.MethodACPRegistryStart, wire.ACPRegistryStartParams{RegistryID: "qa"}, &info)
	if got := folders(); !slices.Equal(got, []string{installDir, project}) {
		t.Fatalf("agent ran in %v, want %s and then %s", got, installDir, project)
	}
}

// An account change reaches an agent's process in every folder, and a listing
// shows the sessions of every process.
func TestEveryFoldersProcessFollowsTheAccountAndListsItsSessions(t *testing.T) {
	s := newTestServer(t)
	log := filepath.Join(t.TempDir(), "sessions")
	startFakeACPAgent(t, s, "agent", "-sessions", log, "-history", t.TempDir())
	client := newRecordingClient(t, s)
	first, second := client.addProject(t, t.TempDir()), client.addProject(t, t.TempDir())
	for _, folder := range []string{first, second} {
		thread := client.createThread(t, "agent", folder).Thread
		client.subscribe(t, thread)
		client.waitSettled(t, thread, client.deliver(t, thread, "hello").Delivery)
	}

	var sessions []provider.SessionSummary
	client.call(t, wire.MethodProviderListSessions, wire.ProviderListSessionsParams{InstanceID: "agent"}, &sessions)
	var listed []string
	for _, session := range sessions {
		listed = append(listed, session.Cwd)
	}
	slices.Sort(listed)
	want := []string{first, second}
	slices.Sort(want)
	if !slices.Equal(listed, want) {
		t.Fatalf("listed sessions in %v, want one in each of %v", listed, want)
	}

	records := sessionRecords(t, log)
	client.call(t, wire.MethodProviderAuthenticate, wire.ProviderAuthenticateParams{InstanceID: "agent", MethodID: "agent-login"}, nil)
	waitUntil(t, "both folders' processes to restart", func() bool {
		return !processAlive(records[0].PID) && !processAlive(records[1].PID)
	})
}

// An update reaches every folder, also when a chat in another folder starts on
// the new version while the old version's turn runs: only once no process runs
// from the old version do its files go.
func TestUpdateReachesEveryFolder(t *testing.T) {
	dataDir := t.TempDir()
	s := newTestServerAt(t, dataDir)
	hosts := serveFakeACPHosts(t, s)
	work := t.TempDir()
	launches := filepath.Join(work, "launches")
	// -history gives sessions ids unique across processes.
	history := t.TempDir()
	archive := func(version string) []byte {
		script := strings.Replace(fakeAgentScript(version, launches), " -- ", " -- -history "+history+" ", 1)
		return tarGz(t, map[string]string{"bin/agent": script})
	}
	v1 := hosts.put("downloads.test/v1.tar.gz", archive("1.0.0"))
	hosts.setIndex(fakeBinaryAgent("qa", "1.0.0", v1, ""))
	client := newRecordingClient(t, s)
	subscribeACP(t, client)
	refreshACP(t, client)
	installACP(t, client, "qa")
	client.waitACPState(t, "qa", wire.ACPAgentInstalled)
	busyFolder := client.addProject(t, work)
	var info provider.InstanceInfo
	client.call(t, wire.MethodACPRegistryStart, wire.ACPRegistryStartParams{RegistryID: "qa", Cwd: busyFolder}, &info)
	busy := client.createThread(t, info.InstanceID, busyFolder).Thread
	client.subscribe(t, busy)
	blocked := client.deliver(t, busy, "block "+work).Delivery
	waitForFile(t, filepath.Join(work, "ready"))
	oldDir := installDirs(t, dataDir, "qa")[0]

	v2 := hosts.put("downloads.test/v2.tar.gz", archive("2.0.0"))
	hosts.setIndex(fakeBinaryAgent("qa", "2.0.0", v2, ""))
	refreshACP(t, client)
	installACP(t, client, "qa")
	client.waitACPState(t, "qa", wire.ACPAgentInstalled)

	late := client.createThread(t, info.InstanceID, t.TempDir()).Thread
	client.subscribe(t, late)
	if turn := client.waitSettled(t, late, client.deliver(t, late, "hello").Delivery); turn.State != provider.TurnCompleted {
		t.Fatalf("turn on the new version = %s", turn.State)
	}
	if dirs := installDirs(t, dataDir, "qa"); !slices.Contains(dirs, oldDir) {
		t.Fatalf("install dirs = %v: the old version's files went while its turn ran", dirs)
	}
	if err := os.WriteFile(filepath.Join(work, "release"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	client.waitSettled(t, busy, blocked)

	// 1.0.0 in the busy folder, 2.0.0 in the late one, then 2.0.0 in the busy one.
	waitUntil(t, "the busy folder to move to the new version and the old files to go", func() bool {
		raw, _ := os.ReadFile(launches)
		dirs := installDirs(t, dataDir, "qa")
		return string(raw) == "1.0.0\n2.0.0\n2.0.0\n" && len(dirs) == 1 && dirs[0] != oldDir
	})
}

// A custom agent's relative command means from where the daemon runs, whichever
// folder the agent then runs in.
func TestARelativeCommandIsFromWhereTheDaemonRuns(t *testing.T) {
	daemonDir := canonicalTempDir(t)
	if err := os.Symlink(os.Args[0], filepath.Join(daemonDir, "agent")); err != nil {
		t.Fatal(err)
	}
	t.Chdir(daemonDir)
	s := newTestServer(t)
	config, err := json.Marshal(map[string]any{
		"command": []string{"./agent", "-test.run=TestHelperProcess", "--"},
		"env":     map[string]string{"MAID_DAEMON_ACP_HELPER": "1"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.StartProvider(s.ctx, provider.InstanceSpec{InstanceID: "agent", Name: "agent", Driver: "acp", Config: config}, false); err != nil {
		t.Fatalf("start: %v", err)
	}
	client := newRecordingClient(t, s)
	thread := client.createThread(t, "agent", t.TempDir()).Thread
	client.subscribe(t, thread)
	if turn := client.waitSettled(t, thread, client.deliver(t, thread, "hello").Delivery); turn.State != provider.TurnCompleted {
		t.Fatalf("turn = %#v", turn)
	}
}
