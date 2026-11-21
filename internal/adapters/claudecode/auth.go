// Account helpers for the Claude Code adapter. The CLI only signs in
// interactively (`claude auth login`), so maiD leaves sign-in to the user's
// own terminal and handles logout and environment hygiene here.
package claudecode

import (
	"bytes"
	"context"
	"fmt"
	"maps"
	"os"
	"os/exec"
	"slices"
	"strings"

	"github.com/Aqothy/maiD/internal/provider"
)

func (h *Instance) Logout(ctx context.Context) (provider.InstanceInfo, error) {
	argv := h.cliArgv("auth", "logout")
	command := exec.CommandContext(ctx, argv[0], argv[1:]...)
	command.Env = h.commandEnv()
	if output, err := command.CombinedOutput(); err != nil {
		return provider.InstanceInfo{}, fmt.Errorf("claude auth logout: %w: %s", err, bytes.TrimSpace(output))
	}
	h.markSignedOut()
	return h.Info(), nil
}

// markSignedOut records that the account is no longer usable, so clients
// offer sign-in.
func (h *Instance) markSignedOut() {
	h.mu.Lock()
	changed := h.info.Auth.Status != provider.AuthStatusUnauthenticated
	h.info.Auth.Status = provider.AuthStatusUnauthenticated
	h.mu.Unlock()
	if changed {
		h.emit("", provider.InstanceChanged{Info: h.Info()})
	}
}

// cliArgv is the configured CLI invocation followed by args.
func (h *Instance) cliArgv(args ...string) []string {
	return append(slices.Clone(h.config.Command), args...)
}

// sessionVariables are what Claude Code sets for the processes it runs. A
// daemon started from inside a Claude Code session inherits them, and the
// CLIs it starts would take themselves for parts of that session.
var sessionVariables = []string{
	"CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION",
	"CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
	"CLAUDE_CODE_EXECPATH", "CLAUDE_PID", "CLAUDE_EFFORT",
}

// commandEnv is the environment of every CLI invocation: the daemon's, less
// an enclosing Claude Code session's variables, plus the configured ones.
func (h *Instance) commandEnv() []string {
	env := slices.DeleteFunc(os.Environ(), func(variable string) bool {
		name, _, _ := strings.Cut(variable, "=")
		return slices.Contains(sessionVariables, name)
	})
	return append(env, h.launchEnv()...)
}

// launchEnv is what every CLI invocation adds to the inherited environment.
func (h *Instance) launchEnv() []string {
	var env []string
	if h.config.ConfigDir != "" {
		env = append(env, "CLAUDE_CONFIG_DIR="+h.config.ConfigDir)
	}
	for _, key := range slices.Sorted(maps.Keys(h.config.Env)) {
		env = append(env, key+"="+h.config.Env[key])
	}
	return env
}
