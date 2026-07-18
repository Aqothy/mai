package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

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

func TestACPRegistryPrefersWebRefreshOverDiskCache(t *testing.T) {
	dataDir := t.TempDir()
	cachePath := filepath.Join(dataDir, "agents", "registry.json")
	if err := os.MkdirAll(filepath.Dir(cachePath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cachePath, []byte(testACPRegistry), 0o644); err != nil {
		t.Fatal(err)
	}

	freshRegistry := strings.Replace(testACPRegistry, "Example Agent", "Fresh Agent", 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(freshRegistry))
	}))
	defer server.Close()
	registry := &acpRegistry{url: server.URL, client: server.Client(), dataDir: dataDir}

	agents, err := registry.list(context.Background())
	if err != nil || len(agents) != 1 || agents[0].Name != "Fresh Agent" {
		t.Fatalf("refreshed list = %#v, %v", agents, err)
	}
}

func TestACPRegistryCachesIndexAndBuildsPersistentNPMCommand(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(testACPRegistry))
	}))
	dataDir := t.TempDir()
	registry := &acpRegistry{url: server.URL, client: server.Client(), dataDir: dataDir}

	agents, err := registry.list(context.Background())
	if err != nil || len(agents) != 1 {
		t.Fatalf("list = %#v, %v", agents, err)
	}
	server.Close()
	registry.lastRefresh = time.Time{}
	registry.agents = nil
	if agents, err = registry.list(context.Background()); err != nil || len(agents) != 1 {
		t.Fatalf("cached list = %#v, %v", agents, err)
	}

	spec, err := registry.instanceSpec(context.Background(), "example")
	if err != nil {
		t.Fatalf("instanceSpec: %v", err)
	}
	var config acp.Config
	if err := json.Unmarshal(spec.Config, &config); err != nil {
		t.Fatalf("decode config: %v", err)
	}
	wantPrefix := filepath.Join(dataDir, "agents", "registry", "npx", "example")
	wantCache := filepath.Join(dataDir, "agents", "npm-cache")
	wantCommand := []string{"npm", "--prefix", wantPrefix, "exec", "--cache=" + wantCache, "--yes", "--", "@example/acp@1.2.3", "--acp"}
	if !reflect.DeepEqual(config.Command, wantCommand) {
		t.Fatalf("command = %#v, want %#v", config.Command, wantCommand)
	}
	if config.Env["DISABLE_UPDATE"] != "1" {
		t.Fatalf("env = %#v", config.Env)
	}
}
