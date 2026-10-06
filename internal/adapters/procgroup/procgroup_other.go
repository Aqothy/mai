//go:build !unix

package procgroup

import "os/exec"

func Configure(*exec.Cmd) {}

func Kill(cmd *exec.Cmd) {
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
}
