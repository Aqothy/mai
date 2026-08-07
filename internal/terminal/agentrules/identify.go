package agentrules

import (
	"path/filepath"
	"strings"
)

// executableLabels maps foreground command basenames to canonical agent
// labels. The set mirrors the agents the embedded manifests cover, plus
// their common install aliases.
var executableLabels = map[string]string{
	"pi":              "pi",
	"claude":          "claude",
	"claude-code":     "claude",
	"codex":           "codex",
	"gemini":          "gemini",
	"cursor-agent":    "cursor",
	"cursor":          "cursor",
	"devin":           "devin",
	"agy":             "agy",
	"antigravity":     "agy",
	"antigravity-cli": "agy",
	"cline":           "cline",
	"opencode":        "opencode",
	"copilot":         "copilot",
	"github-copilot":  "copilot",
	"ghcs":            "copilot",
	"kimi":            "kimi",
	"kiro":            "kiro",
	"kiro-cli":        "kiro",
	"droid":           "droid",
	"amp":             "amp",
	"amp-local":       "amp",
	"grok":            "grok",
	"grok-build":      "grok",
	"hermes":          "hermes",
	"hermes-agent":    "hermes",
	"kilo":            "kilo",
	"kilo-code":       "kilo",
	"qodercli":        "qodercli",
	"qoder":           "qodercli",
	"maki":            "maki",
}

// scriptInterpreters are runtimes whose script argument names the real
// program, covering npm-style installs such as `node /usr/local/bin/claude`
// and Python entry points. Version-suffixed Python binaries are normalized
// before lookup.
var scriptInterpreters = map[string]struct{}{
	"node":   {},
	"bun":    {},
	"deno":   {},
	"python": {},
	"sh":     {},
	"bash":   {},
	"zsh":    {},
	"fish":   {},
}

// IdentifyCommand maps one process's command tokens (argv split on
// whitespace) to a canonical agent label. The first token is the executable;
// for a script interpreter the first non-flag argument names the program.
func IdentifyCommand(argv []string) (string, bool) {
	if len(argv) == 0 {
		return "", false
	}
	name := normalizeExecutable(argv[0])
	if label, ok := executableLabels[name]; ok {
		return label, true
	}
	if _, ok := scriptInterpreters[name]; !ok {
		return "", false
	}
	for _, arg := range argv[1:] {
		if strings.HasPrefix(arg, "-") {
			continue
		}
		if label, ok := executableLabels[normalizeExecutable(arg)]; ok {
			return label, true
		}
		return "", false
	}
	return "", false
}

// IdentifyGroup names the agent for one foreground process group, preferring
// the group leader, then any recognized member: agents spawn MCP servers and
// helpers inside their own process group.
func IdentifyGroup(leaderPID int, processes []GroupProcess) (string, bool) {
	for _, p := range processes {
		if p.PID == leaderPID {
			if label, ok := IdentifyCommand(p.Argv); ok {
				return label, true
			}
		}
	}
	for _, p := range processes {
		if p.PID == leaderPID {
			continue
		}
		if label, ok := IdentifyCommand(p.Argv); ok {
			return label, true
		}
	}
	return "", false
}

// GroupProcess is one process in a foreground process group.
type GroupProcess struct {
	PID  int
	Argv []string
}

// normalizeExecutable lowercases a path's basename and folds version-suffixed
// Python interpreters ("python3.12") onto "python".
func normalizeExecutable(token string) string {
	name := strings.ToLower(filepath.Base(token))
	if rest, ok := strings.CutPrefix(name, "python"); ok {
		trimmed := strings.TrimLeft(rest, "0123456789.")
		if trimmed == "" {
			return "python"
		}
	}
	return name
}
