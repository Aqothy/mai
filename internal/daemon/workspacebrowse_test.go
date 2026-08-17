package daemon

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/Aqothy/maiD/api/wire"
)

func TestBrowseWorkspaceDirectoriesReturnsOnlySortedDirectories(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"zeta", "Alpha", ".hidden"} {
		if err := os.Mkdir(filepath.Join(root, name), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", name, err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "notes.txt"), []byte("ignored"), 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}

	server := newServer(newLoggerFromEnv(), nil)
	t.Cleanup(func() { _ = server.Close() })
	result, err := server.browseWorkspaceDirectories(wire.WorkspaceBrowseDirectoriesParams{Path: root})
	if err != nil {
		t.Fatalf("browse directories: %v", err)
	}
	if result.Path != filepath.Clean(root) || result.ParentPath != filepath.Dir(root) {
		t.Fatalf("unexpected paths: %+v", result)
	}
	got := make([]string, len(result.Entries))
	for index, entry := range result.Entries {
		got[index] = entry.Name
		if entry.Path != filepath.Join(root, entry.Name) {
			t.Fatalf("unexpected entry path: %+v", entry)
		}
	}
	want := []string{".hidden", "Alpha", "zeta"}
	if len(got) != len(want) {
		t.Fatalf("unexpected entries: got %v, want %v", got, want)
	}
	for index := range want {
		if got[index] != want[index] {
			t.Fatalf("unexpected entries: got %v, want %v", got, want)
		}
	}
}

func TestBrowseWorkspaceDirectoriesRPCAndValidation(t *testing.T) {
	server := newServer(newLoggerFromEnv(), nil)
	t.Cleanup(func() { _ = server.Close() })
	client := newRPCTestClient(t, server, rpcTestClientHandler{})
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "project"), 0o755); err != nil {
		t.Fatalf("mkdir project: %v", err)
	}

	var result wire.WorkspaceBrowseDirectoriesResult
	if err := client.Call(
		context.Background(),
		RPCMethodWorkspaceBrowseDirectories,
		wire.WorkspaceBrowseDirectoriesParams{Path: root},
	).Await(context.Background(), &result); err != nil {
		t.Fatalf("workspace.browseDirectories: %v", err)
	}
	if len(result.Entries) != 1 || result.Entries[0].Name != "project" {
		t.Fatalf("unexpected result: %+v", result)
	}

	invalidPaths := []string{"relative/path", filepath.Join(root, "missing")}
	var homeResult wire.WorkspaceBrowseDirectoriesResult
	if err := client.Call(
		context.Background(),
		RPCMethodWorkspaceBrowseDirectories,
		wire.WorkspaceBrowseDirectoriesParams{},
	).Await(context.Background(), &homeResult); err != nil {
		t.Fatalf("browse home directory: %v", err)
	}
	homeDirectory, err := os.UserHomeDir()
	if err != nil {
		t.Fatalf("resolve home directory: %v", err)
	}
	if homeResult.Path != filepath.Clean(homeDirectory) {
		t.Fatalf("unexpected home directory: got %q, want %q", homeResult.Path, homeDirectory)
	}

	for _, path := range invalidPaths {
		var invalidResult wire.WorkspaceBrowseDirectoriesResult
		err := client.Call(
			context.Background(),
			RPCMethodWorkspaceBrowseDirectories,
			wire.WorkspaceBrowseDirectoriesParams{Path: path},
		).Await(context.Background(), &invalidResult)
		if err == nil {
			t.Errorf("path %q: expected an error", path)
		}
	}
}
