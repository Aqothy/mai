//go:build unix

package procgroup

import (
	"bufio"
	"io"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Output an agent writes just before it exits is still read when the reader
// gets to it after the exit.
func TestOutputWrittenBeforeExitIsRead(t *testing.T) {
	p, err := Start(exec.Command("/bin/sh", "-c", "head -c 8000 /dev/zero | tr '\\0' x; echo; echo last"))
	if err != nil {
		t.Fatal(err)
	}
	<-p.Exited()
	data, err := io.ReadAll(p.Stdout())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(string(data), "\nlast\n") || len(data) != 8006 {
		t.Fatalf("read %d bytes ending %q", len(data), data[max(len(data)-8, 0):])
	}
}

// Stop lets an agent that exits on stdin EOF finish on its own, sends one
// that doesn't SIGTERM so it can clean up, and kills one that ignores that.
func TestStopIsGracefulThenKills(t *testing.T) {
	polite, err := Start(exec.Command("/bin/sh", "-c", "cat >/dev/null; echo bye"))
	if err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(polite.Stdout())
	polite.Stop()
	if line, _ := reader.ReadString('\n'); line != "bye\n" {
		t.Fatalf("graceful exit output = %q", line)
	}
	if polite.Err() != nil {
		t.Fatalf("graceful exit error = %v", polite.Err())
	}

	busy, err := Start(exec.Command("/bin/sh", "-c", "trap 'echo cleaned up; exit 0' TERM; while :; do sleep 0.05; done"))
	if err != nil {
		t.Fatal(err)
	}
	reader = bufio.NewReader(busy.Stdout())
	busy.Stop()
	if line, _ := reader.ReadString('\n'); line != "cleaned up\n" {
		t.Fatalf("output after SIGTERM = %q", line)
	}

	stubborn, err := Start(exec.Command("/bin/sh", "-c", "trap '' HUP TERM; exec sleep 60"))
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	stubborn.Stop()
	if elapsed := time.Since(start); elapsed > 2*stopGrace+time.Second {
		t.Fatalf("Stop took %v", elapsed)
	}
}

// A wrapper that backgrounds the real agent and exits takes the agent with
// it: the group is killed as soon as the wrapper is reaped.
func TestExitKillsWhatTheWrapperLeft(t *testing.T) {
	p, err := Start(exec.Command("/bin/sh", "-c", "sleep 60 >/dev/null 2>&1 & echo $!"))
	if err != nil {
		t.Fatal(err)
	}
	line, err := bufio.NewReader(p.Stdout()).ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	child, err := strconv.Atoi(strings.TrimSpace(line))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = syscall.Kill(child, syscall.SIGKILL) }()
	<-p.Exited()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		state, err := exec.Command("ps", "-o", "stat=", "-p", strconv.Itoa(child)).Output()
		if err != nil || strings.HasPrefix(strings.TrimSpace(string(state)), "Z") {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("background child %d survived the wrapper", child)
}
