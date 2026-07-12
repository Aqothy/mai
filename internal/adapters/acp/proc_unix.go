//go:build unix

package acp

import (
	"os/exec"
	"syscall"
)

// configureProcessGroup puts the agent in its own process group so
// killProcessTree can reach every process it spawns. Agent commands are often
// wrappers (npx/npm exec) whose real agent is a child process; killing only the
// direct child would orphan the agent on restart/shutdown.
func configureProcessGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

func killProcessTree(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	_ = cmd.Process.Kill()
}
