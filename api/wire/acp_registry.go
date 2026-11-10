package wire

import (
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// ACP agents, from the public registry or added by the user. The daemon owns
// each agent's state and every device shows its one list. Agents only change
// version when asked: the daemon has no background check.
const (
	// MethodACPRegistrySubscribeList returns the whole list without touching
	// the network and subscribes the connection to MethodACPRegistryList, which
	// carries the whole list again after every change. Until a refresh it holds
	// only installed agents and installs in progress.
	MethodACPRegistrySubscribeList = "acp.registry.subscribeList"
	MethodACPRegistryList          = "acp.registry.list"
	// MethodACPRegistryRefresh fetches the registry and returns the whole list.
	// Release dates of available updates follow in MethodACPRegistryList.
	MethodACPRegistryRefresh = "acp.registry.refresh"
	// MethodACPRegistryInstall installs an agent, or updates an installed one,
	// at the version the registry lists. It returns once the job has started or
	// when one is already running; the job outlives the call and reports through
	// MethodACPRegistryList. The new version replaces a running agent once no
	// turn runs on it, and a failed update leaves the old version in place.
	MethodACPRegistryInstall = "acp.registry.install"
	// MethodACPRegistryAddCustom adds a user-supplied agent command.
	MethodACPRegistryAddCustom = "acp.registry.addCustom"
	// MethodACPRegistryUpdateCustom replaces a custom agent's definition.
	MethodACPRegistryUpdateCustom = "acp.registry.updateCustom"
	// MethodACPRegistryRemove removes an agent, ending any install of it, and
	// deletes every version maiD installed for it in the background. It is
	// refused while a turn runs on the agent; removing an agent that isn't
	// installed succeeds and clears a failed install. Chats on the agent stay,
	// and can't continue unless a registry agent is installed again.
	MethodACPRegistryRemove = "acp.registry.remove"
	// MethodACPRegistryStart starts an installed agent's process for a working
	// folder, or for no folder (signing in, listing sessions) when it has none.
	// An agent runs one process per folder, started on demand. It never installs.
	MethodACPRegistryStart = "acp.registry.start"
)

type ACPAgentSource string

const (
	ACPAgentSourceRegistry ACPAgentSource = "registry"
	ACPAgentSourceCustom   ACPAgentSource = "custom"
)

type ACPAgentState string

const (
	ACPAgentNotInstalled ACPAgentState = "notInstalled"
	ACPAgentInstalling   ACPAgentState = "installing"
	ACPAgentInstalled    ACPAgentState = "installed"
	ACPAgentUpdating     ACPAgentState = "updating"
	ACPAgentFailed       ACPAgentState = "failed"
)

type ACPAgentBlocker string

const (
	// ACPAgentNeedsPlatform: the agent has no build for the daemon's platform.
	ACPAgentNeedsPlatform ACPAgentBlocker = "platform"
	ACPAgentNeedsNode     ACPAgentBlocker = "node"
	ACPAgentNeedsUV       ACPAgentBlocker = "uv"
)

// ACPRegistryAgent is one row of the agent list. Launch details stay on the
// daemon, except a custom agent's, which clients edit; a custom agent's
// environment values never leave it.
type ACPRegistryAgent struct {
	ID          string              `json:"id"`
	InstanceID  provider.InstanceID `json:"instanceId"`
	Name        string              `json:"name"`
	Source      ACPAgentSource      `json:"source"`
	State       ACPAgentState       `json:"state"`
	Description string              `json:"description,omitempty"`
	Icon        string              `json:"icon,omitempty"`
	Repository  string              `json:"repository,omitempty"`
	Website     string              `json:"website,omitempty"`
	LicenseURL  string              `json:"licenseUrl,omitempty"`
	// InstalledVersion is the version on disk; absent when not installed and
	// for custom agents.
	InstalledVersion string `json:"installedVersion,omitempty"`
	// AvailableVersion is what MethodACPRegistryInstall would install; absent
	// when that is already installed or the registry no longer lists the agent.
	AvailableVersion string `json:"availableVersion,omitempty"`
	// AvailableReleasedAt is when an update was released, once known; vendor
	// downloads have no date.
	AvailableReleasedAt *time.Time `json:"availableReleasedAt,omitempty"`
	// Blocker says why AvailableVersion can't be installed here.
	Blocker ACPAgentBlocker `json:"blocker,omitempty"`
	// Error is why the last install or update failed, while State is failed.
	Error    string   `json:"error,omitempty"`
	Command  string   `json:"command,omitempty"`
	Args     []string `json:"args,omitempty"`
	EnvNames []string `json:"envNames,omitempty"`
}

// ACPRegistryList is every agent, sorted by name.
type ACPRegistryList struct {
	Agents []ACPRegistryAgent `json:"agents"`
}

type ACPRegistryStartParams struct {
	RegistryID string `json:"registryId"`
	Cwd        string `json:"cwd,omitempty"`
}

type ACPRegistryInstallParams struct {
	RegistryID string `json:"registryId"`
}

// ACPCustomAgentAddParams contains only user-facing launch configuration. The
// daemon gives the agent its stable identity and owns persistence.
type ACPCustomAgentAddParams struct {
	Name    string            `json:"name"`
	Command string            `json:"command"`
	Args    []string          `json:"args,omitempty"`
	Env     map[string]string `json:"env,omitempty"`
}

// ACPCustomAgentUpdateParams replaces a custom agent's definition, which a
// running agent takes up once it has no turn running. Env sets variables and
// KeepEnv names existing ones to leave as they are, since clients never see
// their values; any other existing variable is removed.
type ACPCustomAgentUpdateParams struct {
	RegistryID string `json:"registryId"`
	ACPCustomAgentAddParams
	KeepEnv []string `json:"keepEnv,omitempty"`
}

type ACPRegistryRemoveParams struct {
	RegistryID string `json:"registryId"`
}
