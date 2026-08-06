package daemon

// End-to-end workspace.searchFiles tests drive a live daemon over a real
// WebSocket the way the Swift composer does: thread-backed and draft-cwd
// searches against a real FFF index, plus the parameter validation that must
// fail before any index is created.

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/jsonrpc2"
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
func searchUntilWarm(t *testing.T, conn *jsonrpc2.Connection, params wire.WorkspaceSearchFilesParams) wire.WorkspaceSearchFilesResult {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		var result wire.WorkspaceSearchFilesResult
		err := conn.Call(ctx, RPCMethodWorkspaceSearchFiles, params).Await(ctx, &result)
		cancel()
		if err != nil {
			t.Fatalf("workspace.searchFiles: %v", err)
		}
		if !result.Indexing {
			return result
		}
		if time.Now().After(deadline) {
			t.Fatal("workspace index never finished its initial scan")
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestWorkspaceSearchFilesForDraftCwd(t *testing.T) {
	s := newServer(newLoggerFromEnv(), nil)
	t.Cleanup(func() { _ = s.Close() })
	conn := newRPCTestClient(t, s, rpcTestClientHandler{})
	root := newWorkspaceFixture(t)

	result := searchUntilWarm(t, conn, wire.WorkspaceSearchFilesParams{Cwd: root, Query: "promptcomp"})
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
}

func TestWorkspaceSearchFilesForExistingThread(t *testing.T) {
	s := newServer(newLoggerFromEnv(), nil)
	t.Cleanup(func() { _ = s.Close() })
	conn := newRPCTestClient(t, s, rpcTestClientHandler{})
	root := newWorkspaceFixture(t)

	threadID := orchestration.NewThreadID()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	var receipt orchestration.DispatchResult
	err := conn.Call(ctx, RPCMethodOrchestrationDispatchCommand, orchestration.Command{
		Type:     orchestration.CommandThreadCreate,
		ThreadID: threadID,
		Title:    "workspace search fixture",
		Cwd:      root,
	}).Await(ctx, &receipt)
	if err != nil {
		t.Fatalf("thread.create: %v", err)
	}

	result := searchUntilWarm(t, conn, wire.WorkspaceSearchFilesParams{ThreadID: threadID, Query: "promptcomp"})
	if len(result.Entries) == 0 || result.Entries[0].RelativePath != "clients/swift/PromptComposer.swift" {
		t.Fatalf("unexpected thread-backed result: %+v", result.Entries)
	}
}

func TestWorkspaceSearchFilesRejectsInvalidRequests(t *testing.T) {
	s := newServer(newLoggerFromEnv(), nil)
	t.Cleanup(func() { _ = s.Close() })
	conn := newRPCTestClient(t, s, rpcTestClientHandler{})
	root := newWorkspaceFixture(t)

	call := func(params wire.WorkspaceSearchFilesParams) error {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		var result wire.WorkspaceSearchFilesResult
		return conn.Call(ctx, RPCMethodWorkspaceSearchFiles, params).Await(ctx, &result)
	}

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
		if err := call(tc.params); err == nil {
			t.Errorf("%s: expected an error", tc.name)
		}
	}
}
