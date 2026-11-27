//go:build darwin && arm64 && cgo

package daemon

// End-to-end workspace.searchFiles tests drive a live daemon over a real
// WebSocket the way the Swift composer does: thread-backed and draft-cwd
// searches against a real FFF index, plus the daemon's parameter validation.

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/Aqothy/maiD/api/wire"
)

func newWorkspaceFixture(t *testing.T) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatalf("resolve fixture root: %v", err)
	}
	target := filepath.Join(root, "clients", "swift", "PromptComposer.swift")
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatalf("mkdir fixture: %v", err)
	}
	if err := os.WriteFile(target, []byte("// fixture\n"), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	return root
}

// searchUntilWarm retries while the daemon reports Indexing, as pressing
// "Check Again" does in the app.
func searchUntilWarm(t *testing.T, client *recordingClient, params wire.WorkspaceSearchFilesParams) wire.WorkspaceSearchFilesResult {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for {
		var result wire.WorkspaceSearchFilesResult
		client.call(t, wire.MethodWorkspaceSearchFiles, params, &result)
		if !result.Indexing {
			return result
		}
		if time.Now().After(deadline) {
			t.Fatal("workspace index never finished its initial scan")
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestWorkspaceSearchFilesForDraftCwdAndThread(t *testing.T) {
	s := newTestServer(t)
	client := newRecordingClient(t, s)
	root := client.addProject(t, newWorkspaceFixture(t))

	result := searchUntilWarm(t, client, wire.WorkspaceSearchFilesParams{Cwd: root, Query: "promptcomp"})
	if len(result.Entries) == 0 {
		t.Fatal("expected a match for promptcomp")
	}
	entry := result.Entries[0]
	if entry.RelativePath != "clients/swift/PromptComposer.swift" || entry.DisplayName != "PromptComposer.swift" {
		t.Fatalf("unexpected entry: %+v", entry)
	}

	// A thread resolves the same workspace from its cwd.
	threadID := client.createThread(t, "claude-code", root).Thread
	result = searchUntilWarm(t, client, wire.WorkspaceSearchFilesParams{ThreadID: threadID, Query: "promptcomp"})
	if len(result.Entries) == 0 || result.Entries[0].RelativePath != "clients/swift/PromptComposer.swift" {
		t.Fatalf("unexpected thread-backed result: %+v", result.Entries)
	}
}

// A draft searches only where the daemon may work: a project or a folder
// inside one. Anything else is refused before an index is made for it.
func TestWorkspaceSearchFilesOnlyInProjects(t *testing.T) {
	s := newTestServer(t)
	client := newRecordingClient(t, s)
	base := canonicalTempDir(t)
	project, sibling := filepath.Join(base, "proj"), filepath.Join(base, "proj2")
	for _, root := range []string{project, sibling} {
		target := filepath.Join(root, "clients", "swift", "PromptComposer.swift")
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(target, []byte("// fixture\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	refused := func(what, cwd string) {
		t.Helper()
		var result wire.WorkspaceSearchFilesResult
		err := client.callErr(wire.MethodWorkspaceSearchFiles, wire.WorkspaceSearchFilesParams{Cwd: cwd, Query: "promptcomp"}, &result)
		if code, _ := commandCode(err); code != invalidParamsCode {
			t.Fatalf("search %s = %v, want invalid params", what, err)
		}
	}

	refused("in a folder that is no project", project)
	client.addProject(t, project)
	if result := searchUntilWarm(t, client, wire.WorkspaceSearchFilesParams{Cwd: project, Query: "promptcomp"}); len(result.Entries) == 0 {
		t.Fatal("search in a project found nothing")
	}
	inside := filepath.Join(project, "clients")
	if result := searchUntilWarm(t, client, wire.WorkspaceSearchFilesParams{Cwd: inside, Query: "promptcomp"}); len(result.Entries) == 0 || result.Entries[0].RelativePath != "swift/PromptComposer.swift" {
		t.Fatalf("search inside a project = %+v, want the file relative to the folder", result.Entries)
	}
	refused("in a sibling sharing the project's prefix", sibling)
	refused("above the project", base)
}

// Root and query validation is owned by workspacesearch; these cases cover
// the daemon's own threadId/cwd resolution.
func TestWorkspaceSearchFilesRejectsInvalidRequests(t *testing.T) {
	s := newTestServer(t)
	client := newRecordingClient(t, s)

	invalid := []struct {
		name   string
		params wire.WorkspaceSearchFilesParams
	}{
		{"neither threadId nor cwd", wire.WorkspaceSearchFilesParams{Query: "q"}},
		{"both threadId and cwd", wire.WorkspaceSearchFilesParams{ThreadID: "missing-thread", Cwd: t.TempDir(), Query: "q"}},
		{"unknown thread", wire.WorkspaceSearchFilesParams{ThreadID: "missing-thread", Query: "q"}},
	}
	for _, tc := range invalid {
		var result wire.WorkspaceSearchFilesResult
		if err := client.callErr(wire.MethodWorkspaceSearchFiles, tc.params, &result); err == nil {
			t.Errorf("%s: expected an error", tc.name)
		}
	}
}
