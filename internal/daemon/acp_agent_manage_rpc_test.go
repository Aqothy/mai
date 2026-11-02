package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
)

func fakeCustomAgentParams(name, pidfile string) wire.ACPCustomAgentAddParams {
	return wire.ACPCustomAgentAddParams{
		Name: name, Command: os.Args[0],
		Args: []string{"-test.run=TestHelperProcess", "--", "-pidfile", pidfile},
		Env:  map[string]string{"MAID_DAEMON_ACP_HELPER": "1"},
	}
}

func providerListed(t *testing.T, c *recordingClient, id provider.InstanceID) bool {
	t.Helper()
	var infos []provider.InstanceInfo
	c.call(t, wire.MethodProviderList, nil, &infos)
	return slices.ContainsFunc(infos, func(info provider.InstanceInfo) bool { return info.InstanceID == id })
}

func installedNames(t *testing.T, c *recordingClient) []string {
	t.Helper()
	var agents []wire.ACPRegistryInstalledAgent
	c.call(t, wire.MethodACPRegistryInstalled, nil, &agents)
	names := []string{}
	for _, agent := range agents {
		names = append(names, agent.Name)
	}
	return names
}

func TestRemovingACustomAgentStopsItAndFreesItsName(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("MAID_DATA_DIR", dir)
	s := newTestServerAt(t, dir)
	client := dialRecordingClient(t, newWSTestServer(t, s))
	work := t.TempDir()
	pidfile := filepath.Join(work, "pid")

	var agent wire.ACPRegistryInstalledAgent
	client.call(t, wire.MethodACPRegistryAddCustom, fakeCustomAgentParams("Mistyped", pidfile), &agent)
	// A restart is what saves the instance's reference in the store.
	var info provider.InstanceInfo
	client.call(t, wire.MethodACPRegistryStart, wire.ACPRegistryStartParams{RegistryID: agent.ID, Restart: true}, &info)
	pid := readPID(t, pidfile)
	thread := client.createThread(t, info.InstanceID, work).Thread
	client.subscribe(t, thread)

	// A running turn refuses the removal, with a message for the user, and
	// leaves everything in place.
	blocked := client.deliver(t, thread, "block "+work).Delivery
	waitForFile(t, filepath.Join(work, "ready"))
	err := client.callErr(wire.MethodACPRegistryRemove, wire.ACPRegistryRemoveParams{RegistryID: agent.ID}, nil)
	if err == nil || !strings.Contains(err.Error(), "Mistyped is working on a turn") {
		t.Fatalf("remove during a turn = %v, want the turn named", err)
	}
	if got := installedNames(t, client); !slices.Equal(got, []string{"Mistyped"}) {
		t.Fatalf("installed after refused removal = %v", got)
	}
	if err := syscall.Kill(pid, 0); err != nil {
		t.Fatalf("refused removal ended the agent: %v", err)
	}
	if err := os.WriteFile(filepath.Join(work, "release"), []byte("finish"), 0o600); err != nil {
		t.Fatal(err)
	}
	client.waitSettled(t, thread, blocked)

	client.call(t, wire.MethodACPRegistryRemove, wire.ACPRegistryRemoveParams{RegistryID: agent.ID}, nil)
	waitUntil(t, "the agent to die", func() bool { return syscall.Kill(pid, 0) != nil })
	if got := installedNames(t, client); len(got) != 0 {
		t.Fatalf("installed after removal = %v", got)
	}
	if providerListed(t, client, info.InstanceID) {
		t.Fatal("provider.list still offers the removed agent")
	}
	// A second client's removal arriving late converges.
	client.call(t, wire.MethodACPRegistryRemove, wire.ACPRegistryRemoveParams{RegistryID: agent.ID}, nil)
	if err := client.callErr(wire.MethodACPRegistryStart, wire.ACPRegistryStartParams{RegistryID: agent.ID}, nil); err == nil {
		t.Fatal("started a removed agent")
	}

	// The chat stays readable; it just can't go on.
	if turns := client.subscribe(t, thread).Turns; len(turns) != 1 || turns[0].State != provider.TurnCompleted {
		t.Fatalf("turns after removal = %#v", turns)
	}
	refused := client.deliver(t, thread, "hello").Delivery
	event := client.waitEvent(t, "the message to be refused", func(event orchestration.ThreadEvent) bool {
		return event.Kind == orchestration.EventDelivery && event.Delivery.ID == refused && event.Delivery.State == orchestration.DeliveryRefused
	})
	if want := "The agent couldn't start: not installed"; event.Delivery.Reason != want {
		t.Fatalf("refusal reason = %q, want %q", event.Delivery.Reason, want)
	}

	// The name is free again, and the new agent is a different one.
	var again wire.ACPRegistryInstalledAgent
	client.call(t, wire.MethodACPRegistryAddCustom, fakeCustomAgentParams("Mistyped", pidfile), &again)
	if again.InstanceID == agent.InstanceID {
		t.Fatalf("new agent reused instance %s", again.InstanceID)
	}

	// The removal outlives the daemon.
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	restarted := newTestServerAt(t, dir)
	after := dialRecordingClient(t, newWSTestServer(t, restarted))
	if providerListed(t, after, agent.InstanceID) {
		t.Fatal("the removed agent came back with the daemon")
	}
	if got := installedNames(t, after); !slices.Equal(got, []string{"Mistyped"}) {
		t.Fatalf("installed after restart = %v", got)
	}
}

// A removal waits for a start in progress. That start must not report an agent
// that is about to go as started, and the agent must not survive.
func TestRemovingAnAgentDuringItsStartWins(t *testing.T) {
	s := newTestServer(t)
	s.acpRegistry = &acpRegistry{dataDir: t.TempDir(), npm: "npm"}
	client := dialRecordingClient(t, newWSTestServer(t, s))
	work := t.TempDir()
	started, gate, pidfile := filepath.Join(work, "started"), filepath.Join(work, "gate"), filepath.Join(work, "pid")
	// The agent's handshake, and so its start, can't finish until the gate opens.
	script := fmt.Sprintf(`touch %q; while [ ! -e %q ]; do sleep 0.05; done; exec "$0" -test.run=TestHelperProcess -- -pidfile %q`, started, gate, pidfile)

	var agent wire.ACPRegistryInstalledAgent
	client.call(t, wire.MethodACPRegistryAddCustom, wire.ACPCustomAgentAddParams{
		Name: "Raced", Command: "/bin/sh", Args: []string{"-c", script, os.Args[0]},
		Env: map[string]string{"MAID_DAEMON_ACP_HELPER": "1"},
	}, &agent)

	startErr := make(chan error, 1)
	go func() {
		startErr <- client.callErr(wire.MethodACPRegistryStart, wire.ACPRegistryStartParams{RegistryID: agent.ID}, nil)
	}()
	waitForFile(t, started)
	removeErr := make(chan error, 1)
	go func() {
		removeErr <- client.callErr(wire.MethodACPRegistryRemove, wire.ACPRegistryRemoveParams{RegistryID: agent.ID}, nil)
	}()
	waitUntil(t, "the agent to leave the manifest", func() bool { return len(installedNames(t, client)) == 0 })

	if err := os.WriteFile(gate, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := <-startErr; err == nil || !strings.Contains(err.Error(), "was removed") {
		t.Fatalf("start during a removal = %v, want it to report the removal", err)
	}
	if err := <-removeErr; err != nil {
		t.Fatalf("remove: %v", err)
	}
	pid := readPID(t, pidfile)
	waitUntil(t, "the agent to die", func() bool { return syscall.Kill(pid, 0) != nil })
	if providerListed(t, client, agent.InstanceID) {
		t.Fatal("provider.list offers the removed agent")
	}
}

func TestRemovingARegistryAgentDeletesOnlyItsFiles(t *testing.T) {
	body := `{"version":"1","agents":[
		{"id":"keep","name":"Keep","version":"1.0.0","distribution":{"npx":{"package":"keep-acp"}}},
		{"id":"drop","name":"Drop","version":"1.0.0","distribution":{"npx":{"package":"drop-acp"}}}
	]}`
	registry, _ := testRegistryServer(t, &body)
	s := newTestServer(t)
	s.acpRegistry = registry
	client := dialRecordingClient(t, newWSTestServer(t, s))

	files := map[string]string{}
	var drop wire.ACPRegistryInstalledAgent
	for _, id := range []string{"keep", "drop"} {
		var installed wire.ACPRegistryInstalledAgent
		client.call(t, wire.MethodACPRegistryInstall, wire.ACPRegistryInstallParams{RegistryID: id}, &installed)
		if id == "drop" {
			drop = installed
		}
		// Where npm puts what it downloads: the path the launch command names.
		spec, err := registry.instanceSpec(id)
		if err != nil {
			t.Fatal(err)
		}
		var config struct {
			Command []string `json:"command"`
		}
		if err := json.Unmarshal(spec.Config, &config); err != nil {
			t.Fatal(err)
		}
		cacheFlag := config.Command[slices.IndexFunc(config.Command, func(arg string) bool { return strings.HasPrefix(arg, "--cache=") })]
		files[id] = filepath.Join(strings.TrimPrefix(cacheFlag, "--cache="), "_npx", "hash", "package.json")
		if err := os.MkdirAll(filepath.Dir(files[id]), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(files[id], []byte("{}"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	client.call(t, wire.MethodACPRegistryRemove, wire.ACPRegistryRemoveParams{RegistryID: "drop"}, nil)
	if _, err := os.Stat(files["drop"]); !os.IsNotExist(err) {
		t.Fatalf("removed agent's download: stat err = %v, want not exist", err)
	}
	if _, err := os.Stat(files["keep"]); err != nil {
		t.Fatalf("other agent's download: %v", err)
	}
	if got := installedNames(t, client); !slices.Equal(got, []string{"Keep"}) {
		t.Fatalf("installed after removal = %v", got)
	}
	if providerListed(t, client, drop.InstanceID) {
		t.Fatal("provider.list still offers the removed agent")
	}

	// It can be installed again, on the same instance its chats name.
	var reinstalled wire.ACPRegistryInstalledAgent
	client.call(t, wire.MethodACPRegistryInstall, wire.ACPRegistryInstallParams{RegistryID: "drop"}, &reinstalled)
	if reinstalled.InstanceID != drop.InstanceID {
		t.Fatalf("reinstalled as %s, want %s", reinstalled.InstanceID, drop.InstanceID)
	}
}

// A daemon that dies between forgetting an agent and deleting its files
// finishes the job at startup, and leaves every listed agent's alone, including
// entries written before the manifest recorded a source.
func TestStartupDeletesFilesOfAgentsNoLongerInstalled(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("MAID_DATA_DIR", dir)
	registry := acpRegistry{dataDir: dir}
	for _, id := range []string{"gone", "listed"} {
		file := filepath.Join(registry.agentPrefixDir(id), "npm-cache", "file")
		if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	manifest := `[{"id":"listed","instanceId":"registry-listed","name":"Listed","source":"","version":"1.0.0","package":"p"}]`
	if err := os.WriteFile(registry.installedManifestPath(), []byte(manifest), 0o600); err != nil {
		t.Fatal(err)
	}
	newTestServerAt(t, dir)
	if _, err := os.Stat(registry.agentPrefixDir("gone")); !os.IsNotExist(err) {
		t.Fatalf("orphaned agent directory: stat err = %v, want not exist", err)
	}
	if _, err := os.Stat(filepath.Join(registry.agentPrefixDir("listed"), "npm-cache", "file")); err != nil {
		t.Fatalf("listed agent's files: %v", err)
	}
}

func TestEditingACustomAgentKeepsItsChatsAndMovesItToTheNewDefinition(t *testing.T) {
	s := newTestServer(t)
	registry := &acpRegistry{dataDir: t.TempDir(), npm: "npm"}
	s.acpRegistry = registry
	client := dialRecordingClient(t, newWSTestServer(t, s))
	work := t.TempDir()
	first, second := filepath.Join(work, "first-pid"), filepath.Join(work, "second-pid")

	params := fakeCustomAgentParams("Mistyped", first)
	params.Env["SECRET_TOKEN"] = "hunter2"
	params.Env["DROPPED"] = "x"
	var agent wire.ACPRegistryInstalledAgent
	client.call(t, wire.MethodACPRegistryAddCustom, params, &agent)
	if want := []string{"DROPPED", "MAID_DAEMON_ACP_HELPER", "SECRET_TOKEN"}; agent.Command != os.Args[0] || !slices.Equal(agent.EnvNames, want) {
		t.Fatalf("added = command %q env %v, want %q and %v", agent.Command, agent.EnvNames, os.Args[0], want)
	}
	var info provider.InstanceInfo
	client.call(t, wire.MethodACPRegistryStart, wire.ACPRegistryStartParams{RegistryID: agent.ID}, &info)
	firstPID := readPID(t, first)
	thread := client.createThread(t, info.InstanceID, work).Thread
	client.subscribe(t, thread)

	// A name another custom agent has is refused; its own isn't.
	var other wire.ACPRegistryInstalledAgent
	client.call(t, wire.MethodACPRegistryAddCustom, wire.ACPCustomAgentAddParams{Name: "Taken", Command: "x"}, &other)
	update := func(name, pidfile string) wire.ACPCustomAgentUpdateParams {
		return wire.ACPCustomAgentUpdateParams{
			RegistryID: agent.ID,
			ACPCustomAgentAddParams: wire.ACPCustomAgentAddParams{
				Name: name, Command: os.Args[0],
				Args: []string{"-test.run=TestHelperProcess", "--", "-pidfile", pidfile},
				Env:  map[string]string{"ADDED": "new"},
			},
			KeepEnv: []string{"MAID_DAEMON_ACP_HELPER", "SECRET_TOKEN"},
		}
	}
	if err := client.callErr(wire.MethodACPRegistryUpdateCustom, update("Taken", second), nil); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("rename onto another agent = %v, want already-exists", err)
	}

	// An edit during a turn waits for it.
	blocked := client.deliver(t, thread, "block "+work).Delivery
	waitForFile(t, filepath.Join(work, "ready"))
	var updated wire.ACPRegistryInstalledAgent
	client.call(t, wire.MethodACPRegistryUpdateCustom, update("Renamed", second), &updated)
	if updated.ID != agent.ID || updated.InstanceID != agent.InstanceID || updated.Name != "Renamed" {
		t.Fatalf("updated = %#v, want the same identity under the new name", updated)
	}
	if want := []string{"ADDED", "MAID_DAEMON_ACP_HELPER", "SECRET_TOKEN"}; !slices.Equal(updated.EnvNames, want) {
		t.Fatalf("env names = %v, want %v", updated.EnvNames, want)
	}
	if turns := client.subscribe(t, thread).Turns; len(turns) != 1 || turns[0].State != provider.TurnRunning {
		t.Fatalf("edit interrupted the turn: %#v", turns)
	}
	if err := syscall.Kill(firstPID, 0); err != nil {
		t.Fatalf("edit ended the agent mid-turn: %v", err)
	}
	if err := os.WriteFile(filepath.Join(work, "release"), []byte("finish"), 0o600); err != nil {
		t.Fatal(err)
	}
	if turn := client.waitSettled(t, thread, blocked); turn.State != provider.TurnCompleted {
		t.Fatalf("turn = %s, want completed", turn.State)
	}

	// Then the new definition runs, under the kept helper variable: the fake
	// agent only starts with it set.
	secondPID := readPID(t, second)
	if secondPID == firstPID {
		t.Fatal("the edit didn't start a new process")
	}
	waitUntil(t, "the old process to die", func() bool { return syscall.Kill(firstPID, 0) != nil })

	// The chat goes on, on the new process.
	if turn := client.waitSettled(t, thread, client.deliver(t, thread, "hello").Delivery); turn.State != provider.TurnCompleted {
		t.Fatalf("turn after the edit = %s, want completed", turn.State)
	}

	// Values never go over the wire, and did reach the manifest.
	var listed json.RawMessage
	client.call(t, wire.MethodACPRegistryInstalled, nil, &listed)
	if strings.Contains(string(listed), "hunter2") {
		t.Fatalf("installed list leaks an env value: %s", listed)
	}
	spec, err := registry.instanceSpec(agent.ID)
	if err != nil {
		t.Fatal(err)
	}
	var config struct {
		Env map[string]string `json:"env"`
	}
	if err := json.Unmarshal(spec.Config, &config); err != nil {
		t.Fatal(err)
	}
	if config.Env["SECRET_TOKEN"] != "hunter2" || config.Env["ADDED"] != "new" || config.Env["DROPPED"] != "" {
		t.Fatalf("env after edit = %v", config.Env)
	}

	if _, err := s.acpRegistry.updateCustom(wire.ACPCustomAgentUpdateParams{RegistryID: "missing", ACPCustomAgentAddParams: wire.ACPCustomAgentAddParams{Name: "x", Command: "y"}}); err == nil {
		t.Fatal("edited an agent that isn't installed")
	}
}

func TestRegistryAgentsCannotBeEdited(t *testing.T) {
	body := testACPRegistry
	registry, _ := testRegistryServer(t, &body)
	if _, err := registry.install(context.Background(), "example"); err != nil {
		t.Fatal(err)
	}
	_, err := registry.updateCustom(wire.ACPCustomAgentUpdateParams{RegistryID: "example", ACPCustomAgentAddParams: wire.ACPCustomAgentAddParams{Name: "x", Command: "/bin/sh"}})
	if err == nil || !strings.Contains(err.Error(), "can't be edited") {
		t.Fatalf("edit of a registry agent = %v, want refused", err)
	}
}
