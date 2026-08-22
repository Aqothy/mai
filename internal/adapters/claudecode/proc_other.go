//go:build !unix

package claudecode

import "os/exec"

func configureProcessGroup(_ *exec.Cmd) {}

func killProcessTree(cmd *exec.Cmd) {
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
}
