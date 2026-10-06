package daemon

import (
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/Aqothy/maiD/api/wire"
)

func TestBrowseWorkspaceDirectoriesRPCAndValidation(t *testing.T) {
	server := newServer(newLoggerFromEnv(), nil)
	t.Cleanup(func() { _ = server.Close() })
	client := newRecordingClient(t, server)
	root := t.TempDir()
	for _, name := range []string{"zeta", "Alpha", ".hidden"} {
		if err := os.Mkdir(filepath.Join(root, name), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", name, err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "notes.txt"), []byte("ignored"), 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}

	// Directories only, case-insensitively sorted, with absolute entry paths.
	var result wire.WorkspaceBrowseDirectoriesResult
	client.call(t, wire.MethodWorkspaceBrowseDirectories, wire.WorkspaceBrowseDirectoriesParams{Path: root}, &result)
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
	if want := []string{".hidden", "Alpha", "zeta"}; !slices.Equal(got, want) {
		t.Fatalf("unexpected entries: got %v, want %v", got, want)
	}

	var homeResult wire.WorkspaceBrowseDirectoriesResult
	client.call(t, wire.MethodWorkspaceBrowseDirectories, wire.WorkspaceBrowseDirectoriesParams{}, &homeResult)
	homeDirectory, err := os.UserHomeDir()
	if err != nil {
		t.Fatalf("resolve home directory: %v", err)
	}
	if homeResult.Path != filepath.Clean(homeDirectory) {
		t.Fatalf("unexpected home directory: got %q, want %q", homeResult.Path, homeDirectory)
	}

	for _, path := range []string{"relative/path", filepath.Join(root, "missing")} {
		var invalidResult wire.WorkspaceBrowseDirectoriesResult
		if err := client.callErr(wire.MethodWorkspaceBrowseDirectories, wire.WorkspaceBrowseDirectoriesParams{Path: path}, &invalidResult); err == nil {
			t.Errorf("path %q: expected an error", path)
		}
	}
}
