package agentrules

import (
	"path/filepath"
	"strings"
)

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
// whitespace) to a canonical agent label: the id of the manifest whose id or
// alias names the executable. The first token is the executable; for a
// script interpreter the first non-flag argument names the program.
func IdentifyCommand(argv []string) (string, bool) {
	if len(argv) == 0 {
		return "", false
	}
	name := normalizeExecutable(argv[0])
	if label, ok := manifestLabel(name); ok {
		return label, true
	}
	if _, ok := scriptInterpreters[name]; !ok {
		return "", false
	}
	for _, arg := range argv[1:] {
		if strings.HasPrefix(arg, "-") {
			continue
		}
		if label, ok := manifestLabel(normalizeExecutable(arg)); ok {
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

func manifestLabel(executable string) (string, bool) {
	if m, ok := manifestsByLabel[executable]; ok {
		return m.label, true
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
