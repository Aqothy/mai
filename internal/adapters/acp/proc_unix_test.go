//go:build unix

package acp

import (
	"io"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// TestAgentExitKillsRemainingProcessGroup guards wrappers that background the
// real agent and exit first. wait must terminate descendants immediately,
// before the old process-group id can be recycled.
func TestAgentExitKillsRemainingProcessGroup(t *testing.T) {
	h := newInstance(nil)
	cmd := exec.Command("/bin/sh", "-c", "sleep 60 >/dev/null 2>&1 & echo $!")
	configureProcessGroup(cmd)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("stdin pipe: %v", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("start: %v", err)
	}
	h.cmd, h.stdin, h.stdout = cmd, stdin, stdout

	out, err := io.ReadAll(stdout)
	if err != nil {
		t.Fatalf("read child pid: %v", err)
	}
	sleepPID, err := strconv.Atoi(strings.TrimSpace(string(out)))
	if err != nil {
		t.Fatalf("parse child pid %q: %v", out, err)
	}
	defer func() { _ = syscall.Kill(sleepPID, syscall.SIGKILL) }()

	h.wait() // the shell already exited; wait must clean up the lingering child
	_ = h.Close()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		state, err := exec.Command("ps", "-o", "stat=", "-p", strconv.Itoa(sleepPID)).Output()
		if err != nil || strings.HasPrefix(strings.TrimSpace(string(state)), "Z") {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("process group occupant %d survived direct wrapper exit", sleepPID)
}
