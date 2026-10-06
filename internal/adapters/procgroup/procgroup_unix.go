//go:build unix

// Package procgroup runs provider agent processes in their own process group.
// Agent commands are often wrappers (npx/npm exec) whose real agent is a child
// process; killing only the direct child would orphan the agent on
// restart/shutdown.
package procgroup

import (
	"os/exec"
	"syscall"
)

// Configure puts cmd in its own process group so Kill can reach every process
// it spawns. Call before cmd.Start.
func Configure(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

// Kill terminates cmd's process group and the process itself.
func Kill(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	_ = cmd.Process.Kill()
}
