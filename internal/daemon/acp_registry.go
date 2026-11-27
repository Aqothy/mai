package daemon

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"maps"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/adapters/acp"
	"github.com/Aqothy/maiD/internal/provider"
)

const defaultACPRegistryURL = "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json"

// acpRegistryAgent is one entry of the registry index, resolved for the
// daemon's platform. A nil distribution has no build for it.
type acpRegistryAgent struct {
	ID, Name, Version                               string
	Description, Icon, Repository, Website, License string
	Distribution                                    acpDistribution
	Args                                            []string
	Env                                             map[string]string
	Blocker                                         wire.ACPAgentBlocker
}

func (a acpRegistryAgent) instanceID() provider.InstanceID {
	return provider.InstanceID("registry-" + a.ID)
}

// acpInstalledAgent is one registry or custom definition in the daemon-owned
// manifest, which alone decides what is installed.
type acpInstalledAgent struct {
	ID          string              `json:"id"`
	InstanceID  provider.InstanceID `json:"instanceId"`
	Name        string              `json:"name"`
	Source      wire.ACPAgentSource `json:"source"`
	Version     string              `json:"version,omitempty"`
	Description string              `json:"description,omitempty"`
	Icon        string              `json:"icon,omitempty"`
	Repository  string              `json:"repository,omitempty"`
	Website     string              `json:"website,omitempty"`
	LicenseURL  string              `json:"licenseUrl,omitempty"`
	// Dir is a registry agent's install directory. Command is relative to it,
	// and runs on node when Node is set; a custom agent's is as the user wrote it.
	Dir     string            `json:"dir,omitempty"`
	Node    bool              `json:"node,omitempty"`
	Command string            `json:"command,omitempty"`
	Args    []string          `json:"args,omitempty"`
	Env     map[string]string `json:"env,omitempty"`
}

type acpRegistryIndex struct {
	Agents []struct {
		ID           string `json:"id"`
		Name         string `json:"name"`
		Version      string `json:"version"`
		Description  string `json:"description"`
		Icon         string `json:"icon"`
		Repository   string `json:"repository"`
		Website      string `json:"website"`
		LicenseURL   string `json:"license_url"`
		Distribution struct {
			Binary map[string]acpIndexTarget `json:"binary"`
			NPX    *acpIndexPackage          `json:"npx"`
			UVX    *acpIndexPackage          `json:"uvx"`
		} `json:"distribution"`
	} `json:"agents"`
}

type acpIndexTarget struct {
	Archive string            `json:"archive"`
	Cmd     string            `json:"cmd"`
	Args    []string          `json:"args"`
	Env     map[string]string `json:"env"`
	SHA256  string            `json:"sha256"`
}

type acpIndexPackage struct {
	Package string            `json:"package"`
	Args    []string          `json:"args"`
	Env     map[string]string `json:"env"`
}

type acpRegistry struct {
	url     string
	client  *http.Client
	dataDir string
	logger  *slog.Logger
	// ctx ends with the daemon, and every install and lookup with it.
	ctx context.Context
	// publish tells clients the list changed. It runs under mu, which keeps
	// lists in order, and must not block.
	publish func(wire.ACPRegistryList)

	// mu guards everything below and the manifest on disk. It is never held
	// across a process, a network call or a recursive delete.
	mu              sync.Mutex
	catalog         []acpRegistryAgent // the last successful fetch
	installed       []acpInstalledAgent
	installedLoaded bool
	jobs            map[string]*acpInstallJob
	failures        map[string]string
	// released holds update release dates by agent and version. A zero time is
	// a lookup that is running or found no date.
	released map[string]time.Time
}

func newACPRegistry(ctx context.Context, dataDir string, logger *slog.Logger, publish func(wire.ACPRegistryList)) *acpRegistry {
	return &acpRegistry{
		url:      defaultACPRegistryURL,
		client:   &http.Client{Timeout: 15 * time.Second},
		dataDir:  dataDir,
		logger:   logger,
		ctx:      ctx,
		publish:  publish,
		jobs:     make(map[string]*acpInstallJob),
		failures: make(map[string]string),
		released: make(map[string]time.Time),
	}
}

// refresh fetches the registry index. The snapshot lets a later install use
// the version the user just saw without a second fetch.
func (r *acpRegistry) refresh(ctx context.Context) (wire.ACPRegistryList, error) {
	agents, err := r.fetch(ctx)
	if err != nil {
		return wire.ACPRegistryList{}, fmt.Errorf("load ACP registry: %w", err)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.catalog = agents
	if err := r.loadInstalledLocked(); err != nil {
		return wire.ACPRegistryList{}, err
	}
	list := r.listLocked()
	r.publish(list)
	r.lookUpReleaseDatesLocked()
	return list, nil
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
		id := strings.TrimSpace(entry.ID)
		// The id comes from a remote index and names the agent's directory,
		// which removing the agent deletes. Dot names are the daemon's own.
		if id == "" || strings.HasPrefix(id, ".") || strings.ContainsAny(id, "/\\\x00") || entry.Version == "" {
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
		agent := acpRegistryAgent{
			ID: id, Name: name, Version: entry.Version, Description: entry.Description, Icon: entry.Icon,
			Repository: entry.Repository, Website: entry.Website, License: entry.LicenseURL,
			Blocker: wire.ACPAgentNeedsPlatform,
		}
		// A build for this platform needs no runtime, so it comes first, as in
		// Zed. Python packages are the last resort: Zed has no such kind.
		distribution := entry.Distribution
		if target, ok := distribution.Binary[acpPlatform()]; ok {
			agent.Distribution = acpBinaryArchive{url: target.Archive, command: target.Cmd, sha256: target.SHA256}
			agent.Args, agent.Env = target.Args, target.Env
		} else if npm := parseNPMPackage(distribution.NPX, entry.Version); npm != nil {
			agent.Distribution = npm
			agent.Args, agent.Env = distribution.NPX.Args, distribution.NPX.Env
		} else if uv := parseUVPackage(distribution.UVX, entry.Version); uv != nil {
			agent.Distribution = uv
			agent.Args, agent.Env = distribution.UVX.Args, distribution.UVX.Env
		}
		if agent.Distribution != nil {
			agent.Blocker = agent.Distribution.blocker()
		}
		agents = append(agents, agent)
	}
	if len(agents) == 0 {
		return nil, fmt.Errorf("registry contains no agents")
	}
	return agents, nil
}

// snapshot is the list as it stands, without touching the network.
func (r *acpRegistry) snapshot() (wire.ACPRegistryList, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.loadInstalledLocked(); err != nil {
		return wire.ACPRegistryList{}, err
	}
	return r.listLocked(), nil
}

// listLocked derives every row from what the daemon knows: the registry's
// entry, the manifest's and the running job or last failure. Installed agents
// stay listed when the registry drops them.
func (r *acpRegistry) listLocked() wire.ACPRegistryList {
	agents := make([]wire.ACPRegistryAgent, 0, len(r.catalog)+len(r.installed))
	for i := range r.installed {
		agent := &r.installed[i]
		row := wire.ACPRegistryAgent{
			ID: agent.ID, InstanceID: agent.InstanceID, Name: agent.Name, State: wire.ACPAgentInstalled,
			Description: agent.Description, Icon: agent.Icon, Repository: agent.Repository, Website: agent.Website, LicenseURL: agent.LicenseURL,
		}
		if agent.custom() {
			row.Source, row.Command, row.Args = wire.ACPAgentSourceCustom, agent.Command, agent.Args
			row.EnvNames = slices.Sorted(maps.Keys(agent.Env))
		} else {
			row.Source, row.InstalledVersion = wire.ACPAgentSourceRegistry, agent.Version
		}
		if listed, ok := findRegistryAgent(r.catalog, agent.ID); ok && !agent.custom() {
			row.Name, row.Description, row.Icon, row.Repository, row.Website, row.LicenseURL = listed.Name, listed.Description, listed.Icon, listed.Repository, listed.Website, listed.License
			if listed.Version != agent.Version {
				row.AvailableVersion, row.Blocker = listed.Version, listed.Blocker
				if at := r.released[releaseKey(listed.ID, listed.Version)]; !at.IsZero() {
					row.AvailableReleasedAt = &at
				}
			}
		}
		agents = append(agents, r.withJobStateLocked(row))
	}
	for _, listed := range r.catalog {
		if slices.ContainsFunc(r.installed, func(agent acpInstalledAgent) bool { return agent.ID == listed.ID }) {
			continue
		}
		agents = append(agents, r.withJobStateLocked(wire.ACPRegistryAgent{
			ID: listed.ID, InstanceID: listed.instanceID(), Name: listed.Name, Source: wire.ACPAgentSourceRegistry, State: wire.ACPAgentNotInstalled,
			Description: listed.Description, Icon: listed.Icon, Repository: listed.Repository, Website: listed.Website, LicenseURL: listed.License,
			AvailableVersion: listed.Version, Blocker: listed.Blocker,
		}))
	}
	slices.SortFunc(agents, func(a, b wire.ACPRegistryAgent) int {
		if order := strings.Compare(strings.ToLower(a.Name), strings.ToLower(b.Name)); order != 0 {
			return order
		}
		return strings.Compare(a.ID, b.ID)
	})
	return wire.ACPRegistryList{Agents: agents}
}

func (r *acpRegistry) withJobStateLocked(row wire.ACPRegistryAgent) wire.ACPRegistryAgent {
	if job, running := r.jobs[row.ID]; running {
		row.State = wire.ACPAgentInstalling
		if job.updating {
			row.State = wire.ACPAgentUpdating
		}
		return row
	}
	if failure, failed := r.failures[row.ID]; failed {
		row.State, row.Error = wire.ACPAgentFailed, failure
	}
	return row
}

func (r *acpRegistry) publishLocked() {
	r.publish(r.listLocked())
}

// registryAgent resolves an id against the last fetched snapshot, fetching
// once if the snapshot has nothing for it.
func (r *acpRegistry) registryAgent(ctx context.Context, id string) (acpRegistryAgent, error) {
	r.mu.Lock()
	agent, ok := findRegistryAgent(r.catalog, id)
	r.mu.Unlock()
	if ok {
		return agent, nil
	}
	if _, err := r.refresh(ctx); err != nil {
		return acpRegistryAgent{}, err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if agent, ok := findRegistryAgent(r.catalog, id); ok {
		return agent, nil
	}
	return acpRegistryAgent{}, fmt.Errorf("ACP registry agent %q not found", id)
}

func findRegistryAgent(agents []acpRegistryAgent, id string) (acpRegistryAgent, bool) {
	for _, agent := range agents {
		if agent.ID == id {
			return agent, true
		}
	}
	return acpRegistryAgent{}, false
}

// addCustom records a user-supplied ACP command in the same manifest as
// registry installations. Its id and instance id never change, so its chats
// survive a rename.
func (r *acpRegistry) addCustom(params wire.ACPCustomAgentAddParams) (wire.ACPRegistryAgent, error) {
	record, err := parseCustomAgent(params)
	if err != nil {
		return wire.ACPRegistryAgent{}, err
	}
	record.ID = rand.Text()
	record.InstanceID = provider.InstanceID("custom-" + record.ID)

	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.loadInstalledLocked(); err != nil {
		return wire.ACPRegistryAgent{}, err
	}
	return r.saveCustomLocked(record)
}

// updateCustom replaces a custom agent's definition. Clients never see the
// environment's values, so KeepEnv names the variables that stay as they are.
func (r *acpRegistry) updateCustom(params wire.ACPCustomAgentUpdateParams) (wire.ACPRegistryAgent, error) {
	record, err := parseCustomAgent(params.ACPCustomAgentAddParams)
	if err != nil {
		return wire.ACPRegistryAgent{}, err
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.loadInstalledLocked(); err != nil {
		return wire.ACPRegistryAgent{}, err
	}
	index := slices.IndexFunc(r.installed, func(agent acpInstalledAgent) bool { return agent.ID == params.RegistryID })
	if index < 0 {
		return wire.ACPRegistryAgent{}, fmt.Errorf("ACP agent %q is not installed", params.RegistryID)
	}
	current := r.installed[index]
	if !current.custom() {
		return wire.ACPRegistryAgent{}, fmt.Errorf("%s comes from the agent registry and can't be edited", current.Name)
	}
	for _, name := range params.KeepEnv {
		value, ok := current.Env[name]
		if !ok {
			return wire.ACPRegistryAgent{}, fmt.Errorf("custom ACP agent has no environment variable %q to keep", name)
		}
		if _, replaced := record.Env[name]; replaced {
			return wire.ACPRegistryAgent{}, fmt.Errorf("custom ACP agent both keeps and sets environment variable %q", name)
		}
		record.Env[name] = value
	}
	record.ID, record.InstanceID = current.ID, current.InstanceID
	return r.saveCustomLocked(record)
}

// parseCustomAgent validates a user-supplied definition. Identity is left to
// the caller.
func parseCustomAgent(params wire.ACPCustomAgentAddParams) (acpInstalledAgent, error) {
	name := strings.TrimSpace(params.Name)
	if name == "" {
		return acpInstalledAgent{}, fmt.Errorf("custom ACP agent requires a name")
	}
	if strings.ContainsRune(name, '\x00') {
		return acpInstalledAgent{}, fmt.Errorf("custom ACP agent name contains a null byte")
	}
	command := strings.TrimSpace(params.Command)
	if command == "" {
		return acpInstalledAgent{}, fmt.Errorf("custom ACP agent requires a command")
	}
	if strings.ContainsRune(command, '\x00') {
		return acpInstalledAgent{}, fmt.Errorf("custom ACP agent command contains a null byte")
	}
	args := append([]string(nil), params.Args...)
	for _, arg := range args {
		if strings.ContainsRune(arg, '\x00') {
			return acpInstalledAgent{}, fmt.Errorf("custom ACP agent argument contains a null byte")
		}
	}
	env := make(map[string]string, len(params.Env))
	for rawKey, value := range params.Env {
		key := strings.TrimSpace(rawKey)
		if key == "" || strings.ContainsAny(key, "=\x00") {
			return acpInstalledAgent{}, fmt.Errorf("custom ACP agent has an invalid environment variable name")
		}
		if strings.ContainsRune(value, '\x00') {
			return acpInstalledAgent{}, fmt.Errorf("custom ACP agent environment variable %q contains a null byte", key)
		}
		if _, duplicate := env[key]; duplicate {
			return acpInstalledAgent{}, fmt.Errorf("custom ACP agent has duplicate environment variable %q", key)
		}
		env[key] = value
	}
	return acpInstalledAgent{Name: name, Source: wire.ACPAgentSourceCustom, Command: command, Args: args, Env: env}, nil
}

// saveCustomLocked writes a custom definition whose name no other custom agent
// uses. A registry agent may share it: the picker tells them apart.
func (r *acpRegistry) saveCustomLocked(record acpInstalledAgent) (wire.ACPRegistryAgent, error) {
	for _, installed := range r.installed {
		if installed.custom() && installed.Name == record.Name && installed.ID != record.ID {
			return wire.ACPRegistryAgent{}, fmt.Errorf("an ACP agent named %q already exists", record.Name)
		}
	}
	if err := r.saveInstalledLocked(upsertInstalledAgent(slices.Clone(r.installed), record)); err != nil {
		return wire.ACPRegistryAgent{}, err
	}
	list := r.listLocked()
	r.publish(list)
	return list.Agents[slices.IndexFunc(list.Agents, func(row wire.ACPRegistryAgent) bool { return row.ID == record.ID })], nil
}

// remove ends any job on the agent and takes it out of the manifest, which is
// what decides it is gone. A job that started meanwhile is ended too, so the
// removal holds when it returns. The caller deletes the files once the agent's
// process has stopped.
func (r *acpRegistry) remove(id string) error {
	for {
		r.mu.Lock()
		job, running := r.jobs[id]
		if !running {
			defer r.mu.Unlock()
			if err := r.loadInstalledLocked(); err != nil {
				return err
			}
			installed := slices.DeleteFunc(slices.Clone(r.installed), func(agent acpInstalledAgent) bool { return agent.ID == id })
			if err := r.saveInstalledLocked(installed); err != nil {
				return err
			}
			delete(r.failures, id)
			r.publishLocked()
			return nil
		}
		job.cancel()
		r.mu.Unlock()
		<-job.done
	}
}

// pruneFiles deletes everything in the agents' directory that neither the
// manifest nor a job needs, including what an interrupted install or delete
// left. It runs before any agent starts: while one runs, its old version may
// be in use, so only pruneAgent is safe.
func (r *acpRegistry) pruneFiles() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.loadInstalledLocked(); err != nil {
		return err
	}
	entries, err := os.ReadDir(r.agentsDir())
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("list agent files: %w", err)
	}
	var failed error
	for _, entry := range entries {
		if entry.Name() != acpTrashDir {
			failed = errors.Join(failed, r.pruneAgentLocked(entry.Name()))
		}
	}
	// What a daemon that died left in the trash. Deleting what this just moved
	// there a second time is harmless.
	leftovers, err := os.ReadDir(r.trashDir())
	if err != nil && !os.IsNotExist(err) {
		return errors.Join(failed, fmt.Errorf("list deleted agent files: %w", err))
	}
	go func() {
		for _, leftover := range leftovers {
			r.deleteFile(filepath.Join(r.trashDir(), leftover.Name()))
		}
	}()
	return failed
}

// pruneAgent deletes the agent's install directories that neither the manifest
// nor a job needs. Its caller knows no process runs from an old one.
func (r *acpRegistry) pruneAgent(id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.loadInstalledLocked(); err != nil {
		return err
	}
	return r.pruneAgentLocked(id)
}

func (r *acpRegistry) pruneAgentLocked(id string) error {
	entries, err := os.ReadDir(r.agentDir(id))
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("list agent files: %w", err)
	}
	var keep []string
	if i := slices.IndexFunc(r.installed, func(agent acpInstalledAgent) bool { return agent.ID == id }); i >= 0 {
		keep = append(keep, filepath.Join(r.agentDir(id), r.installed[i].Dir))
	}
	if job, running := r.jobs[id]; running {
		keep = append(keep, job.dir)
	}
	var failed error
	for _, entry := range entries {
		if dir := filepath.Join(r.agentDir(id), entry.Name()); !slices.Contains(keep, dir) {
			failed = errors.Join(failed, r.discardLocked(dir))
		}
	}
	// Fails while a version remains, which is the point.
	_ = os.Remove(r.agentDir(id))
	return failed
}

// discardLocked moves path to the trash and deletes it in the background: a
// big agent takes seconds to delete, which must hold up neither mu nor shutdown.
// A delete shutdown cuts short finishes at the next startup.
func (r *acpRegistry) discardLocked(path string) error {
	if err := os.MkdirAll(r.trashDir(), 0o755); err != nil {
		return fmt.Errorf("delete agent files: %w", err)
	}
	trashed := filepath.Join(r.trashDir(), rand.Text())
	if err := os.Rename(path, trashed); err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("delete agent files: %w", err)
	}
	go r.deleteFile(trashed)
	return nil
}

func (r *acpRegistry) deleteFile(path string) {
	if err := os.RemoveAll(path); err != nil {
		r.logger.Warn("delete agent files", "error", err)
	}
}

func (r *acpRegistry) installedAgent(id string) (acpInstalledAgent, bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.loadInstalledLocked(); err != nil {
		return acpInstalledAgent{}, false, err
	}
	for _, agent := range r.installed {
		if agent.ID == id {
			return agent, true, nil
		}
	}
	return acpInstalledAgent{}, false, nil
}

func (r *acpRegistry) instanceSpec(id string) (provider.InstanceSpec, error) {
	agent, ok, err := r.installedAgent(id)
	if err != nil {
		return provider.InstanceSpec{}, err
	}
	if !ok {
		return provider.InstanceSpec{}, fmt.Errorf("ACP agent %q is not installed; install it from the agent registry first", id)
	}
	return r.instanceSpecForAgent(agent), nil
}

func (r *acpRegistry) instanceSpecs() ([]provider.InstanceSpec, error) {
	r.mu.Lock()
	if err := r.loadInstalledLocked(); err != nil {
		r.mu.Unlock()
		return nil, err
	}
	agents := slices.Clone(r.installed)
	r.mu.Unlock()

	specs := make([]provider.InstanceSpec, 0, len(agents))
	for _, agent := range agents {
		specs = append(specs, r.instanceSpecForAgent(agent))
	}
	return specs, nil
}

// instanceSpecForAgent is how an agent launches. The registry's environment
// reaches only this: never npm or uv, where it could redirect the install.
func (r *acpRegistry) instanceSpecForAgent(agent acpInstalledAgent) provider.InstanceSpec {
	config := acp.Config{Command: []string{agent.Command}, Env: agent.Env}
	if !agent.custom() {
		config.Dir = filepath.Join(r.agentDir(agent.ID), agent.Dir)
		entry := filepath.Join(config.Dir, agent.Command)
		config.Command = []string{entry}
		if agent.Node {
			config.Command = []string{"node", entry}
		}
	}
	config.Command = append(config.Command, agent.Args...)
	encoded, err := json.Marshal(config)
	if err != nil {
		panic(err) // Strings can't fail to encode.
	}
	return provider.InstanceSpec{InstanceID: agent.InstanceID, Name: agent.Name, Driver: acp.DriverKind, Config: encoded}
}

func (a acpInstalledAgent) custom() bool {
	return a.Source == wire.ACPAgentSourceCustom
}

func (r *acpRegistry) loadInstalledLocked() error {
	if r.installedLoaded {
		return nil
	}
	raw, err := os.ReadFile(r.installedManifestPath())
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

// saveInstalledLocked replaces the manifest atomically: it is the commit point
// of every install, update and removal.
func (r *acpRegistry) saveInstalledLocked(agents []acpInstalledAgent) error {
	path := r.installedManifestPath()
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create agents directory: %w", err)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return fmt.Errorf("secure agents directory: %w", err)
	}
	raw, err := json.MarshalIndent(agents, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(raw, '\n'), 0o600); err != nil {
		return fmt.Errorf("write installed agents: %w", err)
	}
	if err := os.Chmod(tmp, 0o600); err != nil {
		return fmt.Errorf("secure installed agents: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		return fmt.Errorf("write installed agents: %w", err)
	}
	r.installed = agents
	return nil
}

func upsertInstalledAgent(agents []acpInstalledAgent, record acpInstalledAgent) []acpInstalledAgent {
	if i := slices.IndexFunc(agents, func(agent acpInstalledAgent) bool { return agent.ID == record.ID }); i >= 0 {
		agents[i] = record
		return agents
	}
	return append(agents, record)
}

// acpTrashDir holds directories on their way out. Registry ids can't start
// with a dot, so it can't be an agent's.
const acpTrashDir = ".trash"

func (r *acpRegistry) installedManifestPath() string {
	return filepath.Join(r.dataDir, "agents", "installed.json")
}

func (r *acpRegistry) agentsDir() string {
	return filepath.Join(r.dataDir, "agents", "registry")
}

func (r *acpRegistry) trashDir() string {
	return filepath.Join(r.agentsDir(), acpTrashDir)
}

func (r *acpRegistry) agentDir(id string) string {
	return filepath.Join(r.agentsDir(), id)
}
