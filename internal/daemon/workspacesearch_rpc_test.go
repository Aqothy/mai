//go:build darwin && arm64 && cgo

package daemon

// End-to-end workspace.searchFiles tests drive a live daemon over a real
// WebSocket the way the Swift composer does: thread-backed and draft-cwd
// searches against a real FFF index, plus the parameter validation that must
// fail before any index is created.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/orchestration"
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

// searchUntilWarm retries while the daemon reports Indexing, bounded by the
// polling contract the client follows while a trigger stays active.
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
	s := newServer(newLoggerFromEnv(), nil)
	t.Cleanup(func() { _ = s.Close() })
	client := newRecordingClient(t, s)
	root := newWorkspaceFixture(t)

	result := searchUntilWarm(t, client, wire.WorkspaceSearchFilesParams{Cwd: root, Query: "promptcomp"})
	if len(result.Entries) == 0 {
		t.Fatal("expected a match for promptcomp")
	}
	entry := result.Entries[0]
	if entry.RelativePath != "clients/swift/PromptComposer.swift" || entry.DisplayName != "PromptComposer.swift" {
		t.Fatalf("unexpected entry: %+v", entry)
	}
	for _, entry := range result.Entries {
		if filepath.IsAbs(entry.RelativePath) || strings.HasPrefix(entry.RelativePath, "../") {
			t.Fatalf("entry escapes workspace root: %+v", entry)
		}
	}

	// A thread resolves the same workspace from its cwd.
	threadID := orchestration.NewThreadID()
	client.dispatch(t, orchestration.Command{
		Type:     orchestration.CommandThreadCreate,
		ThreadID: threadID,
		Title:    "workspace search fixture",
		Cwd:      root,
	})
	result = searchUntilWarm(t, client, wire.WorkspaceSearchFilesParams{ThreadID: threadID, Query: "promptcomp"})
	if len(result.Entries) == 0 || result.Entries[0].RelativePath != "clients/swift/PromptComposer.swift" {
		t.Fatalf("unexpected thread-backed result: %+v", result.Entries)
	}
}

func TestWorkspaceSearchFilesRejectsInvalidRequests(t *testing.T) {
	s := newServer(newLoggerFromEnv(), nil)
	t.Cleanup(func() { _ = s.Close() })
	client := newRecordingClient(t, s)
	root := newWorkspaceFixture(t)

	invalid := []struct {
		name   string
		params wire.WorkspaceSearchFilesParams
	}{
		{"neither threadId nor cwd", wire.WorkspaceSearchFilesParams{Query: "q"}},
		{"both threadId and cwd", wire.WorkspaceSearchFilesParams{ThreadID: orchestration.NewThreadID(), Cwd: root, Query: "q"}},
		{"unknown thread", wire.WorkspaceSearchFilesParams{ThreadID: orchestration.NewThreadID(), Query: "q"}},
		{"relative cwd", wire.WorkspaceSearchFilesParams{Cwd: "relative/path", Query: "q"}},
		{"missing directory", wire.WorkspaceSearchFilesParams{Cwd: filepath.Join(root, "does-not-exist"), Query: "q"}},
		{"oversized query", wire.WorkspaceSearchFilesParams{Cwd: root, Query: strings.Repeat("q", 257)}},
	}
	for _, tc := range invalid {
		var result wire.WorkspaceSearchFilesResult
		if err := client.callErr(wire.MethodWorkspaceSearchFiles, tc.params, &result); err == nil {
			t.Errorf("%s: expected an error", tc.name)
		}
	}
}
