package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

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
    },
    {
      "id": "binary-only",
      "name": "Binary Only",
      "distribution": {"binary": {}}
    }
  ]
}`

func testRegistryServer(t *testing.T, body *string) (*acpRegistry, *httptest.Server) {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(*body))
	}))
	t.Cleanup(server.Close)
	return &acpRegistry{url: server.URL, client: server.Client(), dataDir: t.TempDir(), npm: "npm"}, server
}

func TestParseACPRegistryReturnsNPXAgents(t *testing.T) {
	agents, err := parseACPRegistry([]byte(testACPRegistry))
	if err != nil {
		t.Fatalf("parseACPRegistry: %v", err)
	}
	if len(agents) != 1 {
		t.Fatalf("agents = %#v, want one npx agent", agents)
	}
	agent := agents[0]
	if agent.ID != "example" || agent.InstanceID != "registry-example" || agent.Package != "@example/acp@1.2.3" {
		t.Fatalf("agent = %#v", agent)
	}
	if !reflect.DeepEqual(agent.Args, []string{"--acp"}) || agent.Env["DISABLE_UPDATE"] != "1" {
		t.Fatalf("agent distribution = %#v", agent)
	}
}

func TestACPRegistryListAlwaysFetchesFresh(t *testing.T) {
	body := testACPRegistry
	registry, _ := testRegistryServer(t, &body)

	agents, err := registry.list(context.Background())
	if err != nil || len(agents) != 1 || agents[0].Name != "Example Agent" {
		t.Fatalf("list = %#v, %v", agents, err)
	}

	body = strings.Replace(testACPRegistry, "Example Agent", "Fresh Agent", 1)
	agents, err = registry.list(context.Background())
	if err != nil || len(agents) != 1 || agents[0].Name != "Fresh Agent" {
		t.Fatalf("refreshed list = %#v, %v", agents, err)
	}
}

func TestACPRegistryInstallRecordsManifestAndBuildsBoundedNPMCommand(t *testing.T) {
	body := testACPRegistry
	registry, server := testRegistryServer(t, &body)

	installed, err := registry.install(context.Background(), "example")
	if err != nil {
		t.Fatalf("install: %v", err)
	}
	if installed.ID != "example" || installed.Version != "1.2.3" || installed.InstalledAt.IsZero() {
		t.Fatalf("installed = %#v", installed)
	}

	// A fresh registry instance must see the persisted manifest without any
	// network access.
	server.Close()
	reloaded := &acpRegistry{dataDir: registry.dataDir, npm: "npm"}
	agents, err := reloaded.installedAgents()
	if err != nil || len(agents) != 1 || agents[0].ID != "example" {
		t.Fatalf("installedAgents = %#v, %v", agents, err)
	}

	spec, err := reloaded.instanceSpec("example")
	if err != nil {
		t.Fatalf("instanceSpec: %v", err)
	}
	var config acp.Config
	if err := json.Unmarshal(spec.Config, &config); err != nil {
		t.Fatalf("decode config: %v", err)
	}
	prefix := filepath.Join(registry.dataDir, "agents", "registry", "npx", "example")
	cache := filepath.Join(registry.dataDir, "agents", "npm-cache")
	wantCommand := []string{"npm", "--prefix", prefix, "exec", "--cache=" + cache, "--yes", "--", "@example/acp@0.0.0 - 1.2.3", "--acp"}
	if !reflect.DeepEqual(config.Command, wantCommand) {
		t.Fatalf("command = %#v, want %#v", config.Command, wantCommand)
	}
	if config.Env["DISABLE_UPDATE"] != "1" {
		t.Fatalf("env = %#v", config.Env)
	}
}

func TestACPRegistryUpdateChangesVersionCeiling(t *testing.T) {
	body := testACPRegistry
	registry, _ := testRegistryServer(t, &body)
	if _, err := registry.install(context.Background(), "example"); err != nil {
		t.Fatalf("initial install: %v", err)
	}

	body = strings.ReplaceAll(testACPRegistry, "1.2.3", "1.2.4")
	if _, err := registry.list(context.Background()); err != nil {
		t.Fatalf("refresh registry: %v", err)
	}
	if _, err := registry.install(context.Background(), "example"); err != nil {
		t.Fatalf("update: %v", err)
	}

	spec, err := registry.instanceSpec("example")
	if err != nil {
		t.Fatalf("instanceSpec after update: %v", err)
	}
	var config acp.Config
	if err := json.Unmarshal(spec.Config, &config); err != nil {
		t.Fatalf("decode config: %v", err)
	}
	if !slices.Contains(config.Command, "@example/acp@0.0.0 - 1.2.4") {
		t.Fatalf("command = %#v, want updated version ceiling", config.Command)
	}
	agents, err := registry.installedAgents()
	if err != nil || len(agents) != 1 || agents[0].Version != "1.2.4" {
		t.Fatalf("installedAgents = %#v, %v", agents, err)
	}
}

func TestACPRegistryInstanceSpecRequiresInstall(t *testing.T) {
	registry := &acpRegistry{dataDir: t.TempDir(), npm: "npm"}
	if _, err := registry.instanceSpec("example"); err == nil || !strings.Contains(err.Error(), "not installed") {
		t.Fatalf("instanceSpec err = %v, want not-installed error", err)
	}
}
