// Sign-in for the Claude Code adapter. The CLI signs in only interactively
// (`claude auth login`), so Authenticate hands the host a command to run in a
// terminal; the host restarts the instance afterwards and the initialize
// handshake then reports the account.
package claudecode

import (
	"bytes"
	"context"
	"fmt"
	"maps"
	"os"
	"os/exec"
	"slices"

	"github.com/Aqothy/maiD/internal/provider"
)

const (
	authMethodSubscription = "claude-subscription"
	authMethodConsole      = "anthropic-console"
)

func claudeAuthMethods() []provider.AuthMethod {
	return []provider.AuthMethod{
		{ID: authMethodSubscription, Name: "Sign in with Claude", Description: "Use a Claude subscription", Kind: provider.AuthKindTerminal},
		{ID: authMethodConsole, Name: "Sign in with Anthropic Console", Description: "Use API usage billing", Kind: provider.AuthKindTerminal},
	}
}

func (h *Instance) Authenticate(_ context.Context, input provider.AuthenticateInput) (provider.AuthenticationResult, error) {
	if input.Secret != "" {
		return provider.AuthenticationResult{}, fmt.Errorf("Claude Code sign-in takes no secret")
	}
	args := []string{"auth", "login"}
	switch input.MethodID {
	case authMethodSubscription:
	case authMethodConsole:
		args = append(args, "--console")
	default:
		return provider.AuthenticationResult{}, fmt.Errorf("unknown Claude Code sign-in method %q", input.MethodID)
	}
	return provider.AuthenticationResult{
		Instance: h.Info(),
		Terminal: &provider.TerminalCommand{Argv: h.cliArgv(args...), Env: h.launchEnv()},
	}, nil
}

func (h *Instance) Logout(ctx context.Context) (provider.InstanceInfo, error) {
	argv := h.cliArgv("auth", "logout")
	command := exec.CommandContext(ctx, argv[0], argv[1:]...)
	command.Env = append(os.Environ(), h.launchEnv()...)
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
	h.info.Auth.Status = provider.AuthStatusUnauthenticated
	h.mu.Unlock()
}

// cliArgv is the configured CLI invocation followed by args.
func (h *Instance) cliArgv(args ...string) []string {
	return append(slices.Clone(h.config.Command), args...)
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
