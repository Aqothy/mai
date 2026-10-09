package procgroup

import (
	"errors"
	"io"
	"os"
	"os/exec"
	"sync"
	"time"
)

// Process is a started agent process that talks over stdin/stdout, in its
// own process group. Its stdout is a pipe the adapter owns, so it stays
// readable after the process exits: exec.Cmd.StdoutPipe is closed by Wait,
// which loses whatever the agent wrote last (often its final result or
// error) if the reader has not consumed it yet.
type Process struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout *os.File

	exited chan struct{}
	err    error

	mu     sync.Mutex
	reaped bool
}

// Start starts cmd in its own process group with stdin and stdout pipes.
// cmd.Stdout must be unset.
func Start(cmd *exec.Cmd) (*Process, error) {
	if cmd.Stdout != nil {
		return nil, errors.New("procgroup: Stdout already set")
	}
	Configure(cmd)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, writer, err := os.Pipe()
	if err != nil {
		_ = stdin.Close()
		return nil, err
	}
	cmd.Stdout = writer
	err = cmd.Start()
	// The child has its own copy of the write end. Closing ours makes the
	// reader see EOF once every process holding it has exited.
	_ = writer.Close()
	if err != nil {
		_ = stdin.Close()
		_ = stdout.Close()
		return nil, err
	}
	p := &Process{cmd: cmd, stdin: stdin, stdout: stdout, exited: make(chan struct{})}
	go p.wait()
	return p, nil
}

func (p *Process) wait() {
	p.err = p.cmd.Wait()
	p.mu.Lock()
	p.reaped = true
	p.mu.Unlock()
	// Wrappers (npx, shell scripts) may background the real agent and exit
	// first. Kill what the leader left in its group right away, while those
	// members still keep the group id from being reused.
	Kill(p.cmd)
	close(p.exited)
}

func (p *Process) Stdin() io.WriteCloser { return p.stdin }
func (p *Process) Stdout() io.Reader     { return p.stdout }
func (p *Process) Pid() int              { return p.cmd.Process.Pid }

// Exited is closed once the process has exited and its group was killed.
func (p *Process) Exited() <-chan struct{} { return p.exited }

// Err is the process's exit error; it is valid once Exited is closed.
func (p *Process) Err() error {
	<-p.exited
	return p.err
}

// Kill kills the process group. It never signals a reaped process, whose pid
// the OS may have given to another process.
func (p *Process) Kill() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.reaped {
		Kill(p.cmd)
	}
}

// Stop closes stdin, which agents take as the signal to finish up and exit,
// gives the process grace to do so (Claude Code flushes its transcript then),
// and kills the group if it is still running. It returns once the process
// has exited.
func (p *Process) Stop(grace time.Duration) {
	_ = p.stdin.Close()
	select {
	case <-p.exited:
		return
	case <-time.After(grace):
	}
	p.Kill()
	<-p.exited
}

// Drain waits, after the process exited, for the reader of its stdout to
// finish (readerDone), so the last messages are delivered, then releases the
// pipe. A grandchild that survived and still holds the pipe would keep it
// open, so after timeout stdout is closed to end the read.
func (p *Process) Drain(readerDone <-chan struct{}, timeout time.Duration) {
	<-p.exited
	select {
	case <-readerDone:
	case <-time.After(timeout):
		_ = p.stdout.Close()
		<-readerDone
	}
	_ = p.stdout.Close()
}

// Close releases the stdout pipe of a process that never got a reader.
func (p *Process) Close() error {
	return p.stdout.Close()
}
