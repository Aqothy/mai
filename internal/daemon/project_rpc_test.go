package daemon

// Project RPC tests: the daemon's one project list, shared by every client
// and kept across restarts, and the rule that chats start only in projects.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
)

func projectPaths(list wire.ProjectList) []string {
	var paths []string
	for _, project := range list.Projects {
		paths = append(paths, project.Path)
	}
	return paths
}

// waitProjects waits until the client's latest project list is want.
func (c *recordingClient) waitProjects(t *testing.T, want ...string) {
	t.Helper()
	c.waitFor(t, "project list "+strings.Join(want, ", "), func() bool {
		return len(c.projectLists) > 0 && slices.Equal(projectPaths(c.projectLists[len(c.projectLists)-1]), want)
	})
}

// canonicalTempDir is a fresh directory by its canonical path, the path the
// daemon lists it under.
func canonicalTempDir(t *testing.T) string {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

// One client's change reaches every client's list; adding a folder from two
// clients at once makes one project; the list survives a restart.
func TestProjectListIsSharedAndSurvivesRestart(t *testing.T) {
	dir := t.TempDir()
	s := newTestServerAt(t, dir)
	url := newWSTestServer(t, s)
	mac, phone := dialRecordingClient(t, url), dialRecordingClient(t, url)

	// Nothing added yet is an empty list, never null.
	var raw json.RawMessage
	phone.call(t, wire.MethodProjectSubscribeList, wire.EmptyParams{}, &raw)
	if string(raw) != `{"projects":[]}` {
		t.Fatalf("empty project list = %s, want {\"projects\":[]}", raw)
	}
	var macList wire.ProjectList
	mac.call(t, wire.MethodProjectSubscribeList, wire.EmptyParams{}, &macList)

	// A symlink is added as the folder it points to.
	first := canonicalTempDir(t)
	alias := filepath.Join(t.TempDir(), "alias")
	if err := os.Symlink(first, alias); err != nil {
		t.Fatal(err)
	}
	if added := mac.addProject(t, alias); added != first {
		t.Fatalf("project.add of a symlink = %q, want %q", added, first)
	}
	phone.waitProjects(t, first)

	second := canonicalTempDir(t)
	var wg sync.WaitGroup
	added := make([]wire.Project, 2)
	for i, client := range []*recordingClient{mac, phone} {
		wg.Go(func() { client.call(t, wire.MethodProjectAdd, wire.ProjectParams{Path: second}, &added[i]) })
	}
	wg.Wait()
	if added[0] != added[1] {
		t.Fatalf("adding one folder at once from two clients = %+v and %+v, want one project", added[0], added[1])
	}
	mac.waitProjects(t, second, first)
	phone.waitProjects(t, second, first)

	phone.call(t, wire.MethodProjectRemove, wire.ProjectParams{Path: first}, nil)
	mac.waitProjects(t, second)
	phone.call(t, wire.MethodProjectRemove, wire.ProjectParams{Path: first}, nil)

	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	restarted := newRecordingClient(t, newTestServerAt(t, dir))
	var list wire.ProjectList
	restarted.call(t, wire.MethodProjectSubscribeList, wire.EmptyParams{}, &list)
	if !slices.Equal(projectPaths(list), []string{second}) || !list.Projects[0].AddedAt.Equal(added[0].AddedAt) {
		t.Fatalf("projects after restart = %+v, want %s added at %s", list.Projects, second, added[0].AddedAt)
	}
}

// project.add takes only an existing absolute directory.
func TestProjectAddRefusesWhatIsNoFolder(t *testing.T) {
	client := newRecordingClient(t, newTestServer(t))
	root := t.TempDir()
	file := filepath.Join(root, "file.txt")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	for name, path := range map[string]string{
		"empty":    "",
		"relative": "relative/path",
		"missing":  filepath.Join(root, "missing"),
		"file":     file,
	} {
		err := client.callErr(wire.MethodProjectAdd, wire.ProjectParams{Path: path}, nil)
		if code, reason := commandCode(err); code != invalidParamsCode || reason != orchestration.CodeInvalid {
			t.Errorf("project.add of the %s path = %v, want invalid params", name, err)
		}
	}
}

// A chat names its folder, which a project allows: the project itself or a
// folder inside it, or a folder a chat already works in. Removing a project
// leaves its chats.
func TestChatsStartOnlyInProjects(t *testing.T) {
	s := newTestServer(t)
	startFakeACPAgent(t, s, "agent")
	client := newRecordingClient(t, s)
	create := func(cwd string, additional ...string) (orchestration.CommandResult, error) {
		return client.commandErr(wire.CommandParams{CreateThread: &orchestration.CreateThread{
			Workspace:   provider.Workspace{Cwd: cwd, AdditionalDirectories: additional},
			Participant: orchestration.NewParticipant{Instance: "agent"},
		}})
	}
	refusedNotInProject := func(what, folder string, err error) {
		t.Helper()
		code, reason := commandCode(err)
		if code != invalidParamsCode || reason != orchestration.CodeInvalid || !strings.Contains(err.Error(), folder) || !strings.Contains(err.Error(), "project") {
			t.Fatalf("%s = %v, want refused naming %s and projects", what, err, folder)
		}
	}

	base := canonicalTempDir(t)
	project, inside, sibling := filepath.Join(base, "proj"), filepath.Join(base, "proj", "app"), filepath.Join(base, "proj2")
	for _, folder := range []string{inside, sibling} {
		if err := os.MkdirAll(folder, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	_, err := create(project)
	refusedNotInProject("a chat in a folder that is no project", project, err)
	_, err = create("")
	if code, _ := commandCode(err); code != invalidParamsCode {
		t.Fatalf("a chat without a folder = %v, want invalid params", err)
	}

	client.addProject(t, project)
	chat, err := create(inside)
	if err != nil {
		t.Fatalf("a chat inside a project: %v", err)
	}
	_, err = create(sibling)
	refusedNotInProject("a chat in a sibling sharing the project's prefix", sibling, err)
	_, err = create(project, sibling)
	refusedNotInProject("an additional directory outside the projects", sibling, err)

	client.call(t, wire.MethodProjectRemove, wire.ProjectParams{Path: project}, nil)
	var threads orchestration.ThreadListItem
	client.call(t, wire.MethodThreadSubscribeList, wire.EmptyParams{}, &threads)
	if len(threads.Threads) != 1 || threads.Threads[0].ID != chat.Thread {
		t.Fatalf("threads after removing their project = %+v, want the chat", threads.Threads)
	}
	if _, err := create(inside); err != nil {
		t.Fatalf("a chat where a chat already works: %v", err)
	}
	_, err = create(project)
	refusedNotInProject("a chat in a removed project", project, err)
}
