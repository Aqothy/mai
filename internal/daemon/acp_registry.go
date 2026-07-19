package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/provider"
)

const (
	defaultACPRegistryURL   = "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json"
	acpRegistryRefreshAfter = time.Hour
)

var (
	npmPackagePattern = regexp.MustCompile(`^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*@[0-9]+(?:\.[0-9]+){2}(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$`)
	envKeyPattern     = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
)

type acpRegistryAgent struct {
	wire.ACPRegistryAgent
	Env map[string]string `json:"-"`
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
	mu          sync.Mutex
	url         string
	client      *http.Client
	dataDir     string
	lastRefresh time.Time
	refreshErr  error
	agents      []acpRegistryAgent
}

func newACPRegistry() *acpRegistry {
	dataDir, _ := maidDataDir()
	return &acpRegistry{
		url:     defaultACPRegistryURL,
		client:  &http.Client{Timeout: 15 * time.Second},
		dataDir: dataDir,
	}
}

func (r *acpRegistry) list(ctx context.Context) ([]acpRegistryAgent, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.lastRefresh.IsZero() && time.Since(r.lastRefresh) < acpRegistryRefreshAfter {
		if len(r.agents) > 0 {
			return r.agents, nil
		}
		if r.refreshErr != nil {
			return nil, fmt.Errorf("load ACP registry: %w", r.refreshErr)
		}
	}

	// Fetch first so this response and later starts use the same registry
	// snapshot. The disk cache is only the offline fallback.
	r.lastRefresh = time.Now()
	agents, raw, err := r.fetch(ctx)
	if err == nil {
		r.agents = agents
		r.refreshErr = nil
		r.storeCache(raw)
		return agents, nil
	}
	r.refreshErr = err
	if len(r.agents) > 0 {
		return r.agents, nil
	}
	if agents, ok := r.loadCache(); ok {
		r.agents = agents
		return agents, nil
	}
	return nil, fmt.Errorf("load ACP registry: %w", err)
}

func (r *acpRegistry) loadCache() ([]acpRegistryAgent, bool) {
	path := r.cachePath()
	if path == "" {
		return nil, false
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, false
	}
	agents, err := parseACPRegistry(raw)
	return agents, err == nil
}

func (r *acpRegistry) storeCache(raw []byte) {
	path := r.cachePath()
	if path == "" {
		return
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o644); err == nil {
		_ = os.Rename(tmp, path)
	}
}

func (r *acpRegistry) fetch(ctx context.Context) ([]acpRegistryAgent, []byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, r.url, nil)
	if err != nil {
		return nil, nil, err
	}
	resp, err := r.client.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, nil, fmt.Errorf("registry returned %s", resp.Status)
	}
	const maxRegistryBytes = 2 << 20
	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxRegistryBytes+1))
	if err != nil {
		return nil, nil, err
	}
	if len(raw) > maxRegistryBytes {
		return nil, nil, fmt.Errorf("registry response exceeds %d bytes", maxRegistryBytes)
	}
	agents, err := parseACPRegistry(raw)
	return agents, raw, err
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
		if npx == nil || id == "" || !npmPackagePattern.MatchString(npx.Package) || !strings.HasSuffix(npx.Package, "@"+entry.Version) {
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
			Env: validRegistryEnv(npx.Env),
		})
	}
	sort.Slice(agents, func(i, j int) bool { return strings.ToLower(agents[i].Name) < strings.ToLower(agents[j].Name) })
	if len(agents) == 0 {
		return nil, fmt.Errorf("registry contains no supported npx agents")
	}
	return agents, nil
}

func (r *acpRegistry) instanceSpec(ctx context.Context, id string) (provider.InstanceSpec, error) {
	agents, err := r.list(ctx)
	if err != nil {
		return provider.InstanceSpec{}, err
	}
	for _, agent := range agents {
		if agent.ID != id && string(agent.InstanceID) != id {
			continue
		}
		if r.dataDir == "" {
			return provider.InstanceSpec{}, fmt.Errorf("resolve maiD data directory")
		}
		prefix := filepath.Join(r.dataDir, "agents", "registry", "npx", safePathComponent(agent.ID))
		cache := filepath.Join(r.dataDir, "agents", "npm-cache")
		if err := os.MkdirAll(prefix, 0o755); err != nil {
			return provider.InstanceSpec{}, fmt.Errorf("create agent directory: %w", err)
		}
		if err := os.MkdirAll(cache, 0o755); err != nil {
			return provider.InstanceSpec{}, fmt.Errorf("create npm cache: %w", err)
		}
		command := []string{"npm", "--prefix", prefix, "exec", "--cache=" + cache, "--yes", "--", agent.Package}
		command = append(command, agent.Args...)
		config, err := json.Marshal(map[string]any{"command": command, "env": agent.Env})
		if err != nil {
			return provider.InstanceSpec{}, err
		}
		return provider.InstanceSpec{InstanceID: agent.InstanceID, Name: agent.Name, Driver: "acp", Config: config}, nil
	}
	return provider.InstanceSpec{}, fmt.Errorf("ACP registry agent %q not found or does not support npx", id)
}

func (r *acpRegistry) cachePath() string {
	if r.dataDir == "" {
		return ""
	}
	return filepath.Join(r.dataDir, "agents", "registry.json")
}

func safePathComponent(value string) string {
	var b strings.Builder
	for _, ch := range value {
		if ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '-' || ch == '_' || ch == '.' {
			b.WriteRune(ch)
		} else {
			b.WriteByte('_')
		}
	}
	if b.Len() == 0 {
		return "agent"
	}
	return b.String()
}

func validRegistryEnv(values map[string]string) map[string]string {
	result := make(map[string]string, len(values))
	for key, value := range values {
		if envKeyPattern.MatchString(key) && !strings.ContainsRune(value, 0) {
			result[key] = value
		}
	}
	if len(result) == 0 {
		return nil
	}
	return result
}
