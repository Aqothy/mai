package terminal

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"

	"github.com/Aqothy/maiD/internal/terminal/vtscreen"
)

const (
	// outputBatchSize caps one burst of output published at once.
	outputBatchSize = 64 * 1024
	// inputQueueSize bounds input waiting for a program that is not reading
	// stdin. Each item is one client write (a keystroke or a paste).
	inputQueueSize = 256
	// scrollbackBytes bounds the run terminal's retained scrollback, which
	// every attach snapshot carries (about 1 MB at this limit).
	scrollbackBytes = 10_000_000
	maxPwdScalars   = 1024
)

// Session is one live PTY run. All mutating operations are serialized on mu;
// PTY writes happen on the run's own writer goroutine so a program that stops
// reading stdin cannot block callers, resize, or termination.
type Session struct {
	TerminalID string

	// emit orders the run's events: output, resizes and the exit are applied
	// and published while holding it, and Observe snapshots under it, so an
	// observer gets every event after its snapshot and none before.
	emit sync.Mutex

	mu      sync.Mutex
	ptyFile *os.File
	cmd     *exec.Cmd
	// ended is set once the program is over, or when Terminate ends it.
	ended   bool
	columns uint16
	rows    uint16
	events  Events
	// vt is the run's terminal: it answers the program's queries and is
	// the attach model. It is fed under emit and mu, so a snapshot taken
	// under emit describes exactly the events published before it. Nil only
	// after the run's attach state has been released.
	vt *vtscreen.Screen
	// Set by vt's effects during a feed, under mu.
	title          string
	pwd            string
	programs       programRecords
	programChanged bool
	// replies are vt's answers to the program, queued during a feed and
	// written after it: effects run under mu and must never block on the
	// PTY.
	replies [][]byte

	input chan []byte

	// done closes after the child has been reaped and the PTY closed.
	done          chan struct{}
	terminateOnce sync.Once
}

// SpawnSpec describes one terminal launch: the user's login shell, or
// Command when set.
type SpawnSpec struct {
	// Cwd is resolved to the user's home directory when empty. It must name
	// an existing directory.
	Cwd     string
	Columns uint16
	Rows    uint16
	// Command is the argv to run instead of the login shell.
	Command []string
	// Env adds KEY=VALUE entries, overriding same-named variables.
	Env []string
}

func startSession(terminalID string, spec SpawnSpec, events Events) (*Session, error) {
	cwd, err := ResolveCwd(spec.Cwd)
	if err != nil {
		return nil, err
	}
	if err := ValidateSize(spec.Columns, spec.Rows); err != nil {
		return nil, err
	}

	var cmd *exec.Cmd
	if len(spec.Command) > 0 {
		cmd = exec.Command(spec.Command[0], spec.Command[1:]...)
	} else {
		shell := resolveShell()
		cmd = exec.Command(shell)
		// The dash-prefixed argv[0] asks the shell to behave as a login shell.
		cmd.Args = []string{"-" + filepath.Base(shell)}
	}
	cmd.Dir = cwd
	// exec keeps the last value of a duplicated key, so spec.Env overrides.
	cmd.Env = append(sessionEnv(), spec.Env...)

	s := &Session{
		TerminalID: terminalID,
		cmd:        cmd,
		columns:    spec.Columns,
		rows:       spec.Rows,
		events:     events,
		programs:   programRecords{},
		input:      make(chan []byte, inputQueueSize),
		done:       make(chan struct{}),
	}

	// The run's terminal is the source of attach state and query answers; a
	// session cannot run without it. Failure here means a misbuilt daemon,
	// not a user error.
	vt, err := vtscreen.New(spec.Columns, spec.Rows, scrollbackBytes, s.terminalEffects())
	if err != nil {
		return nil, fmt.Errorf("terminal model: %w", err)
	}
	s.vt = vt

	ptyFile, err := startPTY(cmd, spec.Columns, spec.Rows)
	if err != nil {
		vt.Close()
		return nil, fmt.Errorf("spawn %s: %w", cmd.Path, err)
	}
	s.ptyFile = ptyFile
	go s.readLoop()
	go s.writeLoop()
	return s, nil
}

// terminalEffects records what the program asks of its terminal. They run
// inside vt.Feed under mu, so they only record; feed and readBurst act after.
func (s *Session) terminalEffects() vtscreen.Effects {
	return vtscreen.Effects{
		Reply: func(data []byte) { s.replies = append(s.replies, data) },
		TitleChanged: func(title string) {
			if title := normalizeTitle(title); title != s.title {
				s.title = title
				s.programChanged = true
			}
		},
		PwdChanged: func(pwd string) {
			if pwd := displayText(pwd, maxPwdScalars); pwd != s.pwd {
				s.pwd = pwd
				s.programChanged = true
			}
		},
		ProgramStatus: func(status vtscreen.ProgramStatus) {
			s.programs.apply(status, time.Now().UTC())
			s.programChanged = true
		},
		// A new prompt means the program that was working or waiting is
		// gone (the protocol's rule).
		PromptStarted: func() {
			if len(s.programs) > 0 {
				s.programs.remove(ProgramWorking, ProgramBlocked)
				s.programChanged = true
			}
		},
	}
}

// writeLoop is the sole PTY writer. A write blocked on a full PTY buffer ends
// when the run exits.
func (s *Session) writeLoop() {
	raw, err := s.ptyFile.SyscallConn()
	if err != nil {
		return
	}
	for {
		select {
		case <-s.done:
			return
		case data := <-s.input:
			if err := writePTY(raw, data); err != nil {
				return
			}
		}
	}
}

// readLoop publishes the program's output a burst at a time.
func (s *Session) readLoop() {
	buf := make([]byte, outputBatchSize)
	raw, err := s.ptyFile.SyscallConn()
	for err == nil {
		err = s.readBurst(raw, buf)
	}

	waitErr := s.cmd.Wait()
	code, hasCode := exitCode(waitErr)

	s.emit.Lock()
	s.mu.Lock()
	exited := !s.ended
	s.ended = true
	if !exited && s.vt != nil {
		// Explicit termination discards attach state.
		s.vt.Close()
		s.vt = nil
	}
	// Nothing is working or waiting once the run is over.
	s.programs.remove(ProgramWorking, ProgramBlocked)
	s.mu.Unlock()
	// The exit is the run's last event: output has drained and resizes
	// refuse a run that isn't running.
	if exited && s.events.Exit != nil {
		var exitPtr *int
		if hasCode {
			exitPtr = &code
		}
		s.events.Exit(s, exitPtr)
	}
	s.emit.Unlock()

	_ = s.ptyFile.Close()
	close(s.done)
}

// readBurst waits for output, then feeds the run's terminal each read as it
// arrives and reads on without waiting, until the program is idle (see
// idleReads) or buf is full, and publishes the burst as one batch. A flood
// becomes few large batches, so streams send few large messages; a lone echo
// is published as soon as the reads behind it come up empty. emit is held
// from the first feed to the publish, so a snapshot never holds output that
// observers are still to be sent; it is never held while waiting. Once the
// kernel's PTY buffer is full the program waits, so output never piles up
// here.
func (s *Session) readBurst(raw syscall.RawConn, buf []byte) error {
	n, err := readPTY(raw, buf, true)
	if n == 0 {
		return err
	}
	s.emit.Lock()
	defer s.emit.Unlock()
	s.feed(buf[:n])
	for err == nil && n < len(buf) {
		var m int
		if m, err = readPTY(raw, buf[n:], false); m == 0 {
			break
		}
		s.feed(buf[n : n+m])
		n += m
	}
	s.mu.Lock()
	changed := s.programChanged
	s.programChanged = false
	s.mu.Unlock()
	if s.events.Output != nil {
		s.events.Output(s, bytes.Clone(buf[:n]))
	}
	if changed && s.events.ProgramChanged != nil {
		s.events.ProgramChanged(s.TerminalID)
	}
	return err
}

// feed applies output to the run's terminal and sends the program the
// terminal's answers to its queries.
func (s *Session) feed(data []byte) {
	s.mu.Lock()
	if s.vt != nil {
		s.vt.Feed(data)
	}
	replies := s.replies
	s.replies = nil
	s.mu.Unlock()
	for _, reply := range replies {
		s.queueInput(reply)
	}
}

// Snapshot is the authoritative attach point for one run. Data is a complete
// native Ghostty model; taken by Observe, it is followed by exactly the
// events after it.
type Snapshot struct {
	Columns        uint16
	Rows           uint16
	SnapshotFormat string
	Data           []byte
}

// Snapshot captures the run's attach state.
func (s *Session) Snapshot() (Snapshot, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	snapshot := Snapshot{Columns: s.columns, Rows: s.rows}
	if s.vt == nil {
		return snapshot, ErrNotRunning
	}
	data, err := s.vt.Snapshot()
	if err != nil {
		return snapshot, fmt.Errorf("terminal snapshot encode: %w", err)
	}
	snapshot.SnapshotFormat = vtscreen.SnapshotFormat
	snapshot.Data = data
	return snapshot, nil
}

// Observe calls register with a snapshot while holding the run's event
// order, so whatever register subscribes receives every event after the
// snapshot and none it already holds. register runs under emit: it must not
// call back into the session's event path.
func (s *Session) Observe(register func(Snapshot)) error {
	s.emit.Lock()
	defer s.emit.Unlock()
	snapshot, err := s.Snapshot()
	if err != nil {
		return err
	}
	register(snapshot)
	return nil
}

// Release frees the attach model's native resources once no future attach
// can need them: after removal or service shutdown. Idempotent.
func (s *Session) Release() {
	s.mu.Lock()
	if s.vt != nil {
		s.vt.Close()
		s.vt = nil
	}
	s.mu.Unlock()
}

// Write queues input for the PTY without blocking. Input beyond the queue is
// dropped with ErrInputQueueFull rather than stalling the caller.
func (s *Session) Write(data []byte) error {
	s.mu.Lock()
	ended := s.ended
	s.mu.Unlock()
	if ended {
		return ErrNotRunning
	}
	if !s.queueInput(data) {
		return ErrInputQueueFull
	}
	return nil
}

// queueInput hands bytes to the PTY writer without blocking. Query answers
// share the queue with input; a program that isn't reading stdin couldn't
// read either.
func (s *Session) queueInput(data []byte) bool {
	select {
	case s.input <- data:
		return true
	default:
		return false
	}
}

// SetAppearance makes the run's terminal answer color and light/dark
// queries with a view's theme.
func (s *Session) SetAppearance(appearance vtscreen.Appearance) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.vt == nil {
		return ErrNotRunning
	}
	return s.vt.SetAppearance(appearance)
}

// Program returns what the program says about itself.
func (s *Session) Program() ProgramInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	return ProgramInfo{Title: s.title, Pwd: s.pwd, Status: s.programs.pressing()}
}

// Seen records that someone looked at the terminal: finished and failed
// statuses have been seen and go away (the protocol's rule). Reports
// whether the program info changed.
func (s *Session) Seen() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	before := len(s.programs)
	s.programs.remove(ProgramDone, ProgramError)
	return len(s.programs) != before
}

// Resize applies a changed grid size to a running PTY and its terminal, and
// publishes it in order with the output, so every client resizes at the same
// point in the output. A run that ended keeps its last grid, which
// views draw scaled. Unchanged dimensions are not re-applied.
func (s *Session) Resize(columns, rows uint16) error {
	if err := ValidateSize(columns, rows); err != nil {
		return err
	}
	s.emit.Lock()
	defer s.emit.Unlock()
	s.mu.Lock()
	if s.ended {
		s.mu.Unlock()
		return ErrNotRunning
	}
	if s.columns == columns && s.rows == rows {
		s.mu.Unlock()
		return nil
	}
	if err := pty.Setsize(s.ptyFile, &pty.Winsize{Rows: rows, Cols: columns}); err != nil {
		s.mu.Unlock()
		return fmt.Errorf("terminal resize: %w", err)
	}
	if err := s.vt.Resize(columns, rows); err != nil {
		s.mu.Unlock()
		return fmt.Errorf("terminal model resize: %w", err)
	}
	s.columns = columns
	s.rows = rows
	s.mu.Unlock()
	if s.events.Resized != nil {
		s.events.Resized(s, columns, rows)
	}
	return nil
}

// Terminate ends the run's whole process group: SIGHUP and SIGTERM, a bounded
// grace interval, then SIGKILL. SIGHUP is the terminal-close signal —
// interactive shells ignore SIGTERM by design but exit promptly on hangup, so
// the grace is an upper bound, not the common cost. It is idempotent and safe
// to call concurrently with natural exit; it returns once the child has been
// reaped.
func (s *Session) Terminate(grace time.Duration) {
	s.terminateOnce.Do(func() {
		s.mu.Lock()
		alive := !s.ended
		s.ended = true
		pid := 0
		if s.cmd.Process != nil {
			pid = s.cmd.Process.Pid
		}
		var groups []int
		if alive && pid > 0 {
			groups = append(groups, pid)
			// Keep the PTY descriptor lookup under the lifecycle lock so it
			// cannot race the read loop closing the descriptor after exit.
			if fg, ok := foregroundProcessGroup(s.ptyFile); ok && fg != pid {
				groups = append(groups, fg)
			}
		}
		s.mu.Unlock()
		if len(groups) == 0 {
			return
		}
		for _, pgid := range groups {
			signalProcessGroup(pgid, hangupSignal)
			signalProcessGroup(pgid, terminateSignal)
		}
		select {
		case <-s.done:
			return
		case <-time.After(grace):
		}
		for _, pgid := range groups {
			signalProcessGroup(pgid, killSignal)
		}
	})
	<-s.done
}

// Size returns the last applied grid dimensions.
func (s *Session) Size() (columns, rows uint16) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.columns, s.rows
}

// Done closes after the run has fully ended and its resources are released.
func (s *Session) Done() <-chan struct{} { return s.done }

// ResolveCwd normalizes and validates a working directory. An empty value
// resolves to the user's home directory. Invalid paths return ErrInvalidCwd
// rather than silently falling back.
func ResolveCwd(cwd string) (string, error) {
	if strings.TrimSpace(cwd) == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("%w: no home directory: %v", ErrInvalidCwd, err)
		}
		cwd = home
	}
	cwd = filepath.Clean(cwd)
	if !filepath.IsAbs(cwd) {
		return "", fmt.Errorf("%w: %q is not absolute", ErrInvalidCwd, cwd)
	}
	info, err := os.Stat(cwd)
	if err != nil {
		return "", fmt.Errorf("%w: %q", ErrInvalidCwd, cwd)
	}
	if !info.IsDir() {
		return "", fmt.Errorf("%w: %q is not a directory", ErrInvalidCwd, cwd)
	}
	return cwd, nil
}

// resolveShell prefers a valid absolute executable in SHELL, then /bin/zsh.
func resolveShell() string {
	if shell := os.Getenv("SHELL"); filepath.IsAbs(shell) {
		if info, err := os.Stat(shell); err == nil && info.Mode().IsRegular() && info.Mode()&0o111 != 0 {
			return shell
		}
	}
	return "/bin/zsh"
}

// sessionEnv inherits the daemon environment with the terminal identity
// overrides. TERM stays on the widely installed xterm-256color entry until
// the daemon also distributes Ghostty terminfo; advertising a missing entry
// would make remote programs less capable, not more.
func sessionEnv() []string {
	overrides := map[string]string{
		"TERM":         "xterm-256color",
		"COLORTERM":    "truecolor",
		"TERM_PROGRAM": "maiD",
	}
	env := make([]string, 0, len(os.Environ())+len(overrides))
	for _, kv := range os.Environ() {
		key, _, ok := strings.Cut(kv, "=")
		if !ok {
			continue
		}
		if _, overridden := overrides[key]; overridden {
			continue
		}
		if key == "TERM_PROGRAM_VERSION" {
			continue
		}
		env = append(env, kv)
	}
	for key, value := range overrides {
		env = append(env, key+"="+value)
	}
	return env
}

// NewID returns a unique terminal thread id.
func NewID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return "terminal-" + hex.EncodeToString(b[:])
}

func exitCode(waitErr error) (code int, ok bool) {
	if waitErr == nil {
		return 0, true
	}
	var exitErr *exec.ExitError
	if errors.As(waitErr, &exitErr) {
		if c := exitErr.ExitCode(); c >= 0 {
			return c, true
		}
	}
	return 0, false
}
