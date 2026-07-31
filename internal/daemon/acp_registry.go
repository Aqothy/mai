package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/provider"
)

const defaultACPRegistryURL = "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json"

type acpRegistryAgent struct {
	wire.ACPRegistryAgent
	Env map[string]string `json:"-"`
}

// acpInstalledAgent is one logical registry installation. Package acquisition
// remains npm-owned and happens lazily when the agent starts. Env stays
// server-side.
type acpInstalledAgent struct {
	wire.ACPRegistryInstalledAgent
	Env map[string]string `json:"env,omitempty"`
}

type acpRegistryIndex struct {
	Version string `json:"version"`
	Agents  []struct {
		ID           string `json:"id"`
		Name         string `json:"name"`
		Version      string `json:"version"`
		Description  string `json:"description"`
		Icon         string `json:"icon"`
		Distribution struct {
			NPX *struct {
				Package string            `json:"package"`
				Args    []string          `json:"args"`
				Env     map[string]string `json:"env"`
			} `json:"npx"`
		} `json:"distribution"`
	} `json:"agents"`
}

type acpRegistry struct {
	url     string
	client  *http.Client
	dataDir string
	npm     string

	mu     sync.Mutex
	agents []acpRegistryAgent // snapshot of the last successful fetch

	// installMu guards the installed-agent manifest.
	installMu       sync.Mutex
	installed       []acpInstalledAgent
	installedLoaded bool
}

func newACPRegistry() *acpRegistry {
	dataDir, _ := maidDataDir()
	return &acpRegistry{
		url:     defaultACPRegistryURL,
		client:  &http.Client{Timeout: 15 * time.Second},
		dataDir: dataDir,
		npm:     "npm",
	}
}

// list fetches the registry index on demand. The in-memory snapshot lets a
// subsequent install use the version the user just saw without a second fetch.
func (r *acpRegistry) list(ctx context.Context) ([]acpRegistryAgent, error) {
	agents, err := r.fetch(ctx)
	if err != nil {
		return nil, fmt.Errorf("load ACP registry: %w", err)
	}
	r.mu.Lock()
	r.agents = agents
	r.mu.Unlock()
	return agents, nil
}

func (r *acpRegistry) fetch(ctx context.Context) ([]acpRegistryAgent, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, r.url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := r.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("registry returned %s", resp.Status)
	}
	const maxRegistryBytes = 2 << 20
	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxRegistryBytes+1))
	if err != nil {
		return nil, err
	}
	if len(raw) > maxRegistryBytes {
		return nil, fmt.Errorf("registry response exceeds %d bytes", maxRegistryBytes)
	}
	return parseACPRegistry(raw)
}

func parseACPRegistry(raw []byte) ([]acpRegistryAgent, error) {
	var index acpRegistryIndex
	if err := json.Unmarshal(raw, &index); err != nil {
		return nil, fmt.Errorf("decode registry: %w", err)
	}
	agents := make([]acpRegistryAgent, 0, len(index.Agents))
	seen := make(map[string]struct{})
	for _, entry := range index.Agents {
		npx := entry.Distribution.NPX
		id := strings.TrimSpace(entry.ID)
		if npx == nil || id == "" {
			continue
		}
		if _, exists := seen[id]; exists {
			continue
		}
		seen[id] = struct{}{}
		name := strings.TrimSpace(entry.Name)
		if name == "" {
			name = id
		}
		agents = append(agents, acpRegistryAgent{
			ACPRegistryAgent: wire.ACPRegistryAgent{
				ID: id, InstanceID: provider.InstanceID("registry-" + id), Name: name,
				Version: entry.Version, Description: entry.Description, Icon: entry.Icon,
				Package: npx.Package, Args: append([]string(nil), npx.Args...),
			},
			Env: npx.Env,
		})
	}
	sort.Slice(agents, func(i, j int) bool { return strings.ToLower(agents[i].Name) < strings.ToLower(agents[j].Name) })
	if len(agents) == 0 {
		return nil, fmt.Errorf("registry contains no supported npx agents")
	}
	return agents, nil
}

// registryAgent resolves an id against the last fetched snapshot, fetching
// once if the snapshot has nothing for it.
func (r *acpRegistry) registryAgent(ctx context.Context, id string) (acpRegistryAgent, error) {
	r.mu.Lock()
	agent, ok := findRegistryAgent(r.agents, id)
	r.mu.Unlock()
	if ok {
		return agent, nil
	}
	agents, err := r.list(ctx)
	if err != nil {
		return acpRegistryAgent{}, err
	}
	if agent, ok := findRegistryAgent(agents, id); ok {
		return agent, nil
	}
	return acpRegistryAgent{}, fmt.Errorf("ACP registry agent %q not found or does not support npx", id)
}

func findRegistryAgent(agents []acpRegistryAgent, id string) (acpRegistryAgent, bool) {
	for _, agent := range agents {
		if agent.ID == id || string(agent.InstanceID) == id {
			return agent, true
		}
	}
	return acpRegistryAgent{}, false
}

// install records the registry metadata selected by the user. npm owns package
// acquisition and caching when the agent is started.
func (r *acpRegistry) install(ctx context.Context, id string) (wire.ACPRegistryInstalledAgent, error) {
	agent, err := r.registryAgent(ctx, id)
	if err != nil {
		return wire.ACPRegistryInstalledAgent{}, err
	}
	if r.dataDir == "" {
		return wire.ACPRegistryInstalledAgent{}, fmt.Errorf("resolve maiD data directory")
	}

	record := acpInstalledAgent{
		ACPRegistryInstalledAgent: wire.ACPRegistryInstalledAgent{
			ID: agent.ID, InstanceID: agent.InstanceID, Name: agent.Name,
			Version: agent.Version, Description: agent.Description, Icon: agent.Icon,
			Package: agent.Package, Args: append([]string(nil), agent.Args...),
			InstalledAt: time.Now().UTC(),
		},
		Env: agent.Env,
	}

	r.installMu.Lock()
	defer r.installMu.Unlock()
	if err := r.loadInstalledLocked(); err != nil {
		return wire.ACPRegistryInstalledAgent{}, err
	}
	installed := upsertInstalledAgent(append([]acpInstalledAgent(nil), r.installed...), record)
	if err := r.saveInstalledLocked(installed); err != nil {
		return wire.ACPRegistryInstalledAgent{}, err
	}
	r.installed = installed
	return record.ACPRegistryInstalledAgent, nil
}

// installedAgents lists the manifest without touching the network.
func (r *acpRegistry) installedAgents() ([]wire.ACPRegistryInstalledAgent, error) {
	r.installMu.Lock()
	defer r.installMu.Unlock()
	if err := r.loadInstalledLocked(); err != nil {
		return nil, err
	}
	agents := make([]wire.ACPRegistryInstalledAgent, 0, len(r.installed))
	for _, agent := range r.installed {
		agents = append(agents, agent.ACPRegistryInstalledAgent)
	}
	return agents, nil
}

func (r *acpRegistry) installedAgent(id string) (acpInstalledAgent, bool, error) {
	r.installMu.Lock()
	defer r.installMu.Unlock()
	if err := r.loadInstalledLocked(); err != nil {
		return acpInstalledAgent{}, false, err
	}
	for _, agent := range r.installed {
		if agent.ID == id || string(agent.InstanceID) == id {
			return agent, true, nil
		}
	}
	return acpInstalledAgent{}, false, nil
}

// instanceSpec lets npm select the newest available package version up to the
// version advertised by the registry when the user installed or updated it.
func (r *acpRegistry) instanceSpec(id string) (provider.InstanceSpec, error) {
	agent, ok, err := r.installedAgent(id)
	if err != nil {
		return provider.InstanceSpec{}, err
	}
	if !ok {
		return provider.InstanceSpec{}, fmt.Errorf("ACP agent %q is not installed; install it from the agent registry first", id)
	}
	if r.dataDir == "" {
		return provider.InstanceSpec{}, fmt.Errorf("resolve maiD data directory")
	}
	prefix := r.agentPrefixDir(agent.ID)
	cache := r.npmCacheDir()
	if err := os.MkdirAll(prefix, 0o755); err != nil {
		return provider.InstanceSpec{}, fmt.Errorf("create agent directory: %w", err)
	}
	if err := os.MkdirAll(cache, 0o755); err != nil {
		return provider.InstanceSpec{}, fmt.Errorf("create npm cache: %w", err)
	}
	command := []string{r.npm, "--prefix", prefix, "exec", "--cache=" + cache, "--yes", "--", boundedNPMPackageSpec(agent.Package, agent.Version)}
	command = append(command, agent.Args...)
	config, err := json.Marshal(map[string]any{"command": command, "env": agent.Env})
	if err != nil {
		return provider.InstanceSpec{}, err
	}
	return provider.InstanceSpec{InstanceID: agent.InstanceID, Name: agent.Name, Driver: "acp", Config: config}, nil
}

func (r *acpRegistry) loadInstalledLocked() error {
	if r.installedLoaded {
		return nil
	}
	path := r.installedManifestPath()
	if path == "" {
		return fmt.Errorf("resolve maiD data directory")
	}
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		r.installedLoaded = true
		return nil
	}
	if err != nil {
		return fmt.Errorf("read installed agents: %w", err)
	}
	var agents []acpInstalledAgent
	if err := json.Unmarshal(raw, &agents); err != nil {
		return fmt.Errorf("decode installed agents: %w", err)
	}
	r.installed = agents
	r.installedLoaded = true
	return nil
}

func (r *acpRegistry) saveInstalledLocked(agents []acpInstalledAgent) error {
	path := r.installedManifestPath()
	if path == "" {
		return fmt.Errorf("resolve maiD data directory")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create agents directory: %w", err)
	}
	raw, err := json.MarshalIndent(agents, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(raw, '\n'), 0o644); err != nil {
		return fmt.Errorf("write installed agents: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		return fmt.Errorf("write installed agents: %w", err)
	}
	return nil
}

func upsertInstalledAgent(agents []acpInstalledAgent, record acpInstalledAgent) []acpInstalledAgent {
	for i, agent := range agents {
		if agent.ID == record.ID {
			agents[i] = record
			return agents
		}
	}
	agents = append(agents, record)
	sort.Slice(agents, func(i, j int) bool { return strings.ToLower(agents[i].Name) < strings.ToLower(agents[j].Name) })
	return agents
}

func (r *acpRegistry) installedManifestPath() string {
	if r.dataDir == "" {
		return ""
	}
	return filepath.Join(r.dataDir, "agents", "installed.json")
}

func (r *acpRegistry) agentPrefixDir(id string) string {
	return filepath.Join(r.dataDir, "agents", "registry", "npx", id)
}

func (r *acpRegistry) npmCacheDir() string {
	return filepath.Join(r.dataDir, "agents", "npm-cache")
}

func boundedNPMPackageSpec(spec, version string) string {
	name := spec
	if at, slash := strings.LastIndex(spec, "@"), strings.LastIndex(spec, "/"); at > slash {
		name = spec[:at]
	}
	return name + "@0.0.0 - " + version
}
