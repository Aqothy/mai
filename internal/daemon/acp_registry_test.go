package daemon

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/adapters/acp"
)

const testACPRegistry = `{
  "version": "1.0.0",
  "agents": [
    {
      "id": "example",
      "name": "Example Agent",
      "version": "1.2.3",
      "description": "An npm ACP agent",
      "distribution": {
        "npx": {
          "package": "@example/acp@1.2.3",
          "args": ["--acp"],
          "env": {"DISABLE_UPDATE": "1"}
        }
      }
    }
  ]
}`

func TestACPCustomAgentPersistsInPrivateJSON(t *testing.T) {
	dataDir := t.TempDir()
	newRegistry := func() *acpRegistry {
		return newACPRegistry(context.Background(), dataDir, slog.Default(), func(wire.ACPRegistryList) {})
	}
	registry := newRegistry()
	installed, err := registry.addCustom(wire.ACPCustomAgentAddParams{
		Name:    "  My Agent  ",
		Command: "  /usr/local/bin/my-agent  ",
		Args:    []string{"--acp", "--profile", "work"},
		Env:     map[string]string{"API_URL": "https://example.test"},
	})
	if err != nil {
		t.Fatalf("addCustom: %v", err)
	}
	if installed.Name != "My Agent" || installed.Source != wire.ACPAgentSourceCustom || installed.State != wire.ACPAgentInstalled {
		t.Fatalf("installed = %#v", installed)
	}

	manifestInfo, err := os.Stat(registry.installedManifestPath())
	if err != nil {
		t.Fatalf("stat manifest: %v", err)
	}
	if got := manifestInfo.Mode().Perm(); got != 0o600 {
		t.Fatalf("manifest permissions = %o, want 600", got)
	}

	reloaded := newRegistry()
	list, err := reloaded.snapshot()
	if err != nil || len(list.Agents) != 1 || list.Agents[0].ID != installed.ID {
		t.Fatalf("snapshot = %#v, %v", list, err)
	}
	spec, err := reloaded.instanceSpec(installed.ID)
	if err != nil {
		t.Fatalf("instanceSpec: %v", err)
	}
	var config acp.Config
	if err := json.Unmarshal(spec.Config, &config); err != nil {
		t.Fatalf("decode config: %v", err)
	}
	wantCommand := []string{"/usr/local/bin/my-agent", "--acp", "--profile", "work"}
	if !reflect.DeepEqual(config.Command, wantCommand) || config.Env["API_URL"] != "https://example.test" {
		t.Fatalf("custom config = %#v, want command %#v and persisted env", config, wantCommand)
	}
	if _, err := registry.addCustom(wire.ACPCustomAgentAddParams{
		Name: "My Agent", Command: "other-agent",
	}); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("duplicate add error = %v, want already-exists error", err)
	}
}

// Registry ids name directories that removing an agent deletes, and they come
// from a remote index. A dot name could also be the daemon's own trash.
func TestACPRegistrySkipsIDsThatEscapeTheAgentDirectory(t *testing.T) {
	agent := func(id string) string {
		return `{"id":` + strconv.Quote(id) + `,"name":"n","version":"1","distribution":{"npx":{"package":"p"}}}`
	}
	raw := `{"agents":[` + strings.Join([]string{agent(".."), agent("."), agent(".trash"), agent("../../.."), agent(`a\\b`), agent("safe")}, ",") + `]}`
	agents, err := parseACPRegistry([]byte(raw))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(agents) != 1 || agents[0].ID != "safe" {
		t.Fatalf("agents = %#v, want only safe", agents)
	}
}
