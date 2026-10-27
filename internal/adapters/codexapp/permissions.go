package codexapp

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/Aqothy/maiD/internal/provider"
)

const (
	permissionsOptionID = "permissions"
	// customPermissions stands for an approval policy and sandbox from the
	// user's Codex configuration that no preset matches. It can be the
	// current value but not a selection.
	customPermissions = "custom"
)

// permissionPreset is one of Codex's own permission presets (the TUI's
// /approvals menu): an approval policy paired with a sandbox. Thread
// requests take the sandbox as a mode; turn/start takes it as a policy.
type permissionPreset struct {
	id             string
	label          string
	description    string
	approvalPolicy string
	sandboxMode    string
	sandboxPolicy  string
}

var permissionPresets = []permissionPreset{
	{
		id: "read-only", label: "Read only",
		description:    "Codex can read files in the workspace. Approval is required to edit files or access the internet.",
		approvalPolicy: "on-request", sandboxMode: "read-only", sandboxPolicy: "readOnly",
	},
	{
		id: "auto", label: "Default",
		description:    "Codex can read and edit files in the workspace, and run commands. Approval is required to access the internet or edit other files.",
		approvalPolicy: "on-request", sandboxMode: "workspace-write", sandboxPolicy: "workspaceWrite",
	},
	{
		id: "full-access", label: "Full access",
		description:    "Codex can edit files outside the workspace and access the internet without asking for approval.",
		approvalPolicy: "never", sandboxMode: "danger-full-access", sandboxPolicy: "dangerFullAccess",
	},
}

func permissionPresetByID(id string) (permissionPreset, bool) {
	for _, preset := range permissionPresets {
		if preset.id == id {
			return preset, true
		}
	}
	return permissionPreset{}, false
}

// permissionsFor names the preset an approval policy and sandbox select. The
// sandbox is a SandboxMode or a SandboxPolicy type; a granular approval
// policy decodes to "" and matches no preset.
func permissionsFor(approvalPolicy json.RawMessage, sandbox string) string {
	var policy string
	_ = json.Unmarshal(approvalPolicy, &policy)
	for _, preset := range permissionPresets {
		if preset.approvalPolicy == policy && (preset.sandboxMode == sandbox || preset.sandboxPolicy == sandbox) {
			return preset.id
		}
	}
	return customPermissions
}

// selectedPermissions is the preset a thread's selections ask for, if any.
func selectedPermissions(selections []provider.ConfigOptionSelection) (permissionPreset, bool) {
	for _, selection := range selections {
		if selection.OptionID == permissionsOptionID {
			value, _ := selection.Value.(string)
			return permissionPresetByID(value)
		}
	}
	return permissionPreset{}, false
}

// setThreadParams applies the preset to a thread/start, thread/resume or
// thread/fork request. The sandbox mode keeps the user's configured extras
// (writable roots, network access) for that sandbox.
func (p permissionPreset) setThreadParams(params map[string]any) {
	params["approvalPolicy"] = p.approvalPolicy
	params["sandbox"] = p.sandboxMode
}

// setTurnParams applies the preset to a turn/start request, which changes it
// for the rest of the thread.
func (p permissionPreset) setTurnParams(params map[string]any) {
	params["approvalPolicy"] = p.approvalPolicy
	params["sandboxPolicy"] = map[string]any{"type": p.sandboxPolicy}
}

func permissionsOption(current string) provider.ConfigOption {
	choices := make([]provider.ConfigChoice, 0, len(permissionPresets)+1)
	if _, ok := permissionPresetByID(current); !ok {
		current = customPermissions
		choices = append(choices, provider.ConfigChoice{Value: customPermissions, Label: "Custom", Description: "The approval policy and sandbox from your Codex configuration"})
	}
	for _, preset := range permissionPresets {
		choices = append(choices, provider.ConfigChoice{Value: preset.id, Label: preset.label, Description: preset.description})
	}
	return provider.ConfigOption{
		ID:           permissionsOptionID,
		Type:         provider.ConfigOptionTypeSelect,
		Category:     provider.ConfigOptionCategoryMode,
		Label:        "Permissions",
		Description:  "What Codex can do without asking",
		Choices:      choices,
		CurrentValue: current,
	}
}

// permissionsRequest is item/permissions/requestApproval: the agent asks for
// more network or filesystem access than its sandbox gives it.
type permissionsRequest struct {
	ThreadID    string          `json:"threadId"`
	TurnID      string          `json:"turnId"`
	ItemID      string          `json:"itemId"`
	Reason      *string         `json:"reason"`
	Permissions json.RawMessage `json:"permissions"`
}

type requestedPermissions struct {
	Network *struct {
		Enabled *bool `json:"enabled"`
	} `json:"network"`
	FileSystem *struct {
		Read  []string `json:"read"`
		Write []string `json:"write"`
	} `json:"fileSystem"`
}

func (r requestedPermissions) summary() string {
	var parts []string
	if r.Network != nil && r.Network.Enabled != nil && *r.Network.Enabled {
		parts = append(parts, "network access")
	}
	if r.FileSystem != nil {
		if len(r.FileSystem.Write) > 0 {
			parts = append(parts, "write access to "+strings.Join(r.FileSystem.Write, ", "))
		}
		if len(r.FileSystem.Read) > 0 {
			parts = append(parts, "read access to "+strings.Join(r.FileSystem.Read, ", "))
		}
	}
	if len(parts) == 0 {
		return "Codex asks for more permissions"
	}
	return fmt.Sprintf("Codex asks for %s", strings.Join(parts, " and "))
}

// permissionsReply grants what was asked for the turn or the session, or
// grants nothing.
func permissionsReply(requested json.RawMessage, decision provider.ApprovalDecision) map[string]any {
	switch decision {
	case provider.ApprovalDecisionAccept:
		return map[string]any{"permissions": requested, "scope": "turn"}
	case provider.ApprovalDecisionAcceptForSession:
		return map[string]any{"permissions": requested, "scope": "session"}
	default:
		return map[string]any{"permissions": map[string]any{}, "scope": "turn"}
	}
}
