package claudecode

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// probe runs the SDK initialize handshake against a short-lived CLI process.
// The CLI answers initialize before any API request, so the probe is free,
// works logged-out, and returns the account, model catalog (including
// per-model effort levels), and command list in one round trip.
func (h *Instance) probe(ctx context.Context) error {
	if _, hasDeadline := ctx.Deadline(); !hasDeadline {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, probeTimeout)
		defer cancel()
	}
	cwd, err := os.UserHomeDir()
	if err != nil {
		cwd = os.TempDir()
	}
	command := h.buildCommand(cwd, []string{
		// Keep the probe hermetic and fast: no MCP servers, no hooks firing
		// on a handshake that runs on every daemon start.
		"--strict-mcp-config",
		"--settings", `{"disableAllHooks":true}`,
	})
	stdin, err := command.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return err
	}
	if err := command.Start(); err != nil {
		_ = stdin.Close()
		_ = stdout.Close()
		return err
	}
	client := newStreamClient(stdout, stdin)
	done := make(chan struct{})
	go func() {
		_ = command.Wait()
		client.fail(io.EOF)
		close(done)
	}()
	defer func() {
		_ = stdin.Close()
		killProcessTree(command)
		<-done
	}()
	var response initializeResponse
	if err := client.control(ctx, map[string]any{"subtype": "initialize"}, &response); err != nil {
		return err
	}
	h.mu.Lock()
	h.models = response.Models
	h.commands = response.Commands
	h.updateAccountLocked(response.Account)
	h.mu.Unlock()
	return nil
}

// updateAccountLocked derives auth state from the initialize handshake. The
// CLI has no non-interactive login flow (the Agent SDK requires pre-existing
// credentials too), so no auth methods are advertised.
func (h *Instance) updateAccountLocked(account *sdkAccount) {
	if account != nil && (account.Email != "" || account.SubscriptionType != "") {
		h.info.Auth.Status = provider.AuthStatusAuthenticated
		return
	}
	if account == nil {
		h.info.Auth.Status = provider.AuthStatusUnauthenticated
	}
}

func (h *Instance) configOptionsLocked(selectedModel, selectedEffort, selectedMode string) []provider.ConfigOption {
	options := make([]provider.ConfigOption, 0, 3)
	if len(h.models) > 0 {
		choices := make([]provider.ConfigChoice, 0, len(h.models))
		valid := make(map[string]struct{}, len(h.models))
		for _, model := range h.models {
			value := strings.TrimSpace(model.Value)
			if value == "" {
				continue
			}
			valid[value] = struct{}{}
			choices = append(choices, provider.ConfigChoice{
				Value:       value,
				Label:       trimmedOrDefault(model.DisplayName, value),
				Description: strings.TrimSpace(model.Description),
			})
		}
		current := strings.TrimSpace(selectedModel)
		if _, ok := valid[current]; !ok {
			current = ""
		}
		if current == "" {
			if _, ok := valid["default"]; ok {
				current = "default"
			} else if len(choices) > 0 {
				current = choices[0].Value
			}
		}
		options = append(options, provider.ConfigOption{
			ID:           "model",
			Type:         provider.ConfigOptionTypeSelect,
			Category:     provider.ConfigOptionCategoryModel,
			Label:        "Model",
			Description:  "Model used for this thread",
			Choices:      choices,
			CurrentValue: current,
		})
		if model := h.modelBySelectionLocked(current); model != nil && len(model.SupportedEffortLevels) > 0 {
			effortChoices := make([]provider.ConfigChoice, 0, len(model.SupportedEffortLevels)+1)
			effortChoices = append(effortChoices, provider.ConfigChoice{Value: "default", Label: "Default", Description: "Model-selected effort"})
			validEffort := map[string]struct{}{"default": {}}
			for _, level := range model.SupportedEffortLevels {
				level = strings.TrimSpace(level)
				if level == "" {
					continue
				}
				validEffort[level] = struct{}{}
				effortChoices = append(effortChoices, provider.ConfigChoice{Value: level, Label: humanizeIdentifier(level)})
			}
			effort := strings.TrimSpace(selectedEffort)
			if _, ok := validEffort[effort]; !ok {
				effort = "default"
			}
			options = append(options, provider.ConfigOption{
				ID:           "effort",
				Type:         provider.ConfigOptionTypeSelect,
				Category:     provider.ConfigOptionCategoryThoughtLevel,
				Label:        "Effort",
				Description:  "Reasoning effort used for this thread; applies from the next turn",
				Choices:      effortChoices,
				CurrentValue: effort,
			})
		}
	}
	modeChoices := []provider.ConfigChoice{
		{Value: "default", Label: "Ask for approval", Description: "Prompt before running tools that need permission"},
		{Value: "auto", Label: "Auto", Description: "A classifier approves routine actions and asks otherwise"},
		{Value: "acceptEdits", Label: "Accept edits", Description: "Auto-approve file edits; ask for everything else"},
		{Value: "plan", Label: "Plan", Description: "Read-only planning; no tool execution"},
		{Value: "dontAsk", Label: "Don't ask", Description: "Deny anything not pre-approved instead of prompting"},
		{Value: "bypassPermissions", Label: "Bypass permissions", Description: "Run every tool without asking"},
	}
	mode := strings.TrimSpace(selectedMode)
	if !validPermissionMode(mode) {
		mode = "default"
	}
	options = append(options, provider.ConfigOption{
		ID:           "permission_mode",
		Type:         provider.ConfigOptionTypeSelect,
		Category:     provider.ConfigOptionCategoryMode,
		Label:        "Permissions",
		Description:  "How tool executions are approved",
		Choices:      modeChoices,
		CurrentValue: mode,
	})
	return options
}

func (h *Instance) modelBySelectionLocked(value string) *sdkModel {
	for index := range h.models {
		if h.models[index].Value == value {
			return &h.models[index]
		}
	}
	return nil
}

func modelValueValid(models []sdkModel, value string) bool {
	value = strings.TrimSpace(value)
	if value == "" {
		return false
	}
	if value == "default" {
		return true
	}
	for _, model := range models {
		if model.Value == value || model.ResolvedModel == value {
			return true
		}
	}
	return false
}

func currentConfigString(options []provider.ConfigOption, optionID string) (string, bool) {
	for _, option := range options {
		if option.ID != optionID {
			continue
		}
		value, ok := option.CurrentValue.(string)
		return value, ok
	}
	return "", false
}

// scanSkills discovers skills on disk. The initialize handshake surfaces
// skills only as slash commands without filesystem paths, so the scan mirrors
// the CLI's own lookup locations.
func (h *Instance) scanSkills(cwd string) []provider.Skill {
	type root struct {
		dir   string
		scope string
	}
	roots := []root{}
	if configDir := h.configDir(); configDir != "" {
		roots = append(roots, root{filepath.Join(configDir, "skills"), "user"})
	}
	if cwd != "" {
		roots = append(roots, root{filepath.Join(cwd, ".claude", "skills"), "project"})
		roots = append(roots, root{filepath.Join(cwd, ".agents", "skills"), "project"})
	}
	seen := make(map[string]struct{})
	skills := make([]provider.Skill, 0)
	for _, location := range roots {
		entries, err := os.ReadDir(location.dir)
		if err != nil {
			continue
		}
		for _, entry := range entries {
			if !entry.IsDir() {
				continue
			}
			manifest := filepath.Join(location.dir, entry.Name(), "SKILL.md")
			if _, err := os.Stat(manifest); err != nil {
				continue
			}
			name, description := skillFrontmatter(manifest)
			if name == "" {
				name = entry.Name()
			}
			if _, exists := seen[name]; exists {
				continue
			}
			seen[name] = struct{}{}
			skills = append(skills, provider.Skill{
				Name:             name,
				Description:      description,
				ShortDescription: boundedRunes(description, 120),
				Path:             manifest,
				Scope:            location.scope,
				Enabled:          true,
			})
		}
	}
	sort.Slice(skills, func(i, j int) bool { return skills[i].Name < skills[j].Name })
	return skills
}

// skillFrontmatter extracts name and description from a SKILL.md YAML header
// without a YAML dependency; values are single-line in practice.
func skillFrontmatter(path string) (string, string) {
	file, err := os.Open(path)
	if err != nil {
		return "", ""
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	inHeader := false
	name, description := "", ""
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "---" {
			if inHeader {
				break
			}
			inHeader = true
			continue
		}
		if !inHeader {
			break
		}
		if value, ok := strings.CutPrefix(line, "name:"); ok {
			name = strings.Trim(strings.TrimSpace(value), `"'`)
		}
		if value, ok := strings.CutPrefix(line, "description:"); ok {
			description = strings.Trim(strings.TrimSpace(value), `"'`)
		}
	}
	return name, description
}

func (h *Instance) OpenOptionsSession(ctx context.Context, cwd string, callbacks provider.OptionsSessionCallbacks) (provider.OptionsSession, error) {
	h.mu.Lock()
	modelsMissing := len(h.models) == 0
	h.mu.Unlock()
	if modelsMissing {
		// Recoverable, mirroring codexapp: a transient probe failure must not
		// take the mode/permission controls down with it.
		if err := h.probe(ctx); err != nil {
			h.logger.Debug("refresh Claude Code catalog", "error", err)
		}
	}
	skills := h.scanSkills(cwd)
	h.mu.Lock()
	defer h.mu.Unlock()
	options := h.configOptionsLocked("", "", "")
	selectedModel, _ := currentConfigString(options, "model")
	handle := fmt.Sprintf("claude-options-%d", time.Now().UnixNano())
	h.options[handle] = &optionsState{selectedModel: selectedModel, selectedMode: "default", options: options, callbacks: callbacks}
	return provider.OptionsSession{
		Handle:        handle,
		ConfigOptions: append([]provider.ConfigOption(nil), options...),
		Skills:        skills,
	}, nil
}

func (h *Instance) SetOptionsSessionValue(_ context.Context, handle, optionID string, value any) ([]provider.ConfigOption, error) {
	h.mu.Lock()
	state := h.options[handle]
	if state == nil {
		h.mu.Unlock()
		return nil, fmt.Errorf("Claude Code options session %q is not open", handle)
	}
	text, ok := value.(string)
	if !ok {
		h.mu.Unlock()
		return nil, fmt.Errorf("Claude Code option %q requires a string value", optionID)
	}
	selectedModel := state.selectedModel
	selectedEffort := state.selectedEffort
	selectedMode := state.selectedMode
	switch optionID {
	case "model":
		selectedModel = text
	case "effort":
		selectedEffort = text
	case "permission_mode":
		selectedMode = text
	default:
		h.mu.Unlock()
		return nil, fmt.Errorf("Claude Code option %q is not supported", optionID)
	}
	options := h.configOptionsLocked(selectedModel, selectedEffort, selectedMode)
	current, present := currentConfigString(options, optionID)
	if !present || current != text {
		h.mu.Unlock()
		return nil, fmt.Errorf("Claude Code option %q does not accept value %q", optionID, text)
	}
	state.selectedModel, _ = currentConfigString(options, "model")
	state.selectedEffort, _ = currentConfigString(options, "effort")
	state.selectedMode, _ = currentConfigString(options, "permission_mode")
	state.options = options
	snapshot := append([]provider.ConfigOption(nil), state.options...)
	callback := state.callbacks.Updated
	h.mu.Unlock()
	if callback != nil {
		callback(snapshot)
	}
	return snapshot, nil
}

func (h *Instance) CloseOptionsSession(_ context.Context, handle string) error {
	h.mu.Lock()
	delete(h.options, handle)
	h.mu.Unlock()
	return nil
}
