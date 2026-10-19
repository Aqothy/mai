package terminal

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/creack/pty"

	"github.com/Aqothy/maiD/internal/terminal/vtscreen"
)

const (
	ptyReadBufferSize       = 32 * 1024
	outputBatchSize         = 64 * 1024
	outputBatchMaximumDelay = 8 * time.Millisecond
	outputReadQueueSize     = 32
	// inputQueueSize bounds input waiting for a program that is not reading
	// stdin. Each item is one client write (a keystroke or a paste).
	inputQueueSize = 256
	// scrollbackBytes bounds the run terminal's retained scrollback.
	scrollbackBytes = 2 * 1024 * 1024
	maxPwdScalars   = 1024
)

// Session is one live PTY run. All mutating operations are serialized on mu;
// PTY writes happen on the run's own writer goroutine so a program that stops
// reading stdin cannot block callers, resize, or termination.
type Session struct {
	TerminalID string
	RunID      string

	// emit is held from assigning a sequence until the item is published, so
	// output, resizes and the exit reach clients in sequence order.
	emit sync.Mutex

	mu       sync.Mutex
	ptyFile  *os.File
	cmd      *exec.Cmd
	status   Status
	columns  uint16
	rows     uint16
	seq      uint64
	exitCode *int
	events   Events
	// vt is the run's terminal: it answers the program's queries and is
	// the attach model. It is fed under mu in sequence order, so snapshots
	// are atomic with the sequence counter. Nil only after the run's attach
	// state has been released.
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
		RunID:      newRunID(),
		cmd:        cmd,
		status:     StatusStarting,
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

	// creack/pty starts the child with Setsid, so the shell leads its own
	// session and process group; group signals reach every descendant.
	ptyFile, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: spec.Rows, Cols: spec.Columns})
	if err != nil {
		vt.Close()
		return nil, fmt.Errorf("spawn %s: %w", cmd.Path, err)
	}
	s.ptyFile = ptyFile
	s.status = StatusRunning
	go s.readLoop()
	go s.writeLoop()
	return s, nil
}

// terminalEffects records what the program asks of its terminal. They run
// inside vt.Feed under mu, so they only record; publishOutput acts after.
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
// when the run exits and the PTY closes.
func (s *Session) writeLoop() {
	for {
		select {
		case <-s.done:
			return
		case data := <-s.input:
			if _, err := s.ptyFile.Write(data); err != nil {
				return
			}
		}
	}
}

// readLoop batches the small reads commonly produced by a PTY before sending
// them over RPC. This keeps fast output from becoming thousands of tiny JSON
// and renderer operations. A batch is published when it reaches the byte cap
// or has waited eight milliseconds, whichever comes first. The bounded read
// queue prevents unbounded intermediate allocations if local processing
// cannot keep up with the PTY.
func (s *Session) readLoop() {
	reads := make(chan []byte, outputReadQueueSize)
	go s.readPTY(reads)

	pending := make([]byte, 0, outputBatchSize)
	flushTimer := time.NewTimer(outputBatchMaximumDelay)
	if !flushTimer.Stop() {
		<-flushTimer.C
	}
	defer flushTimer.Stop()
	var flushTimerChannel <-chan time.Time

	stopTimer := func() {
		if flushTimerChannel == nil {
			return
		}
		if !flushTimer.Stop() {
			select {
			case <-flushTimer.C:
			default:
			}
		}
		flushTimerChannel = nil
	}

	publish := func() {
		stopTimer()
		if len(pending) == 0 {
			return
		}
		data := pending
		pending = make([]byte, 0, outputBatchSize)
		s.publishOutput(data)
	}

drainReads:
	for {
		select {
		case data, ok := <-reads:
			if !ok {
				publish()
				break drainReads
			}
			for len(data) > 0 {
				available := outputBatchSize - len(pending)
				if available > len(data) {
					available = len(data)
				}
				pending = append(pending, data[:available]...)
				data = data[available:]
				if len(pending) == outputBatchSize {
					publish()
				} else if flushTimerChannel == nil {
					flushTimer.Reset(outputBatchMaximumDelay)
					flushTimerChannel = flushTimer.C
				}
			}
		case <-flushTimerChannel:
			flushTimerChannel = nil
			publish()
		}
	}

	waitErr := s.cmd.Wait()
	code, hasCode := exitCode(waitErr)

	s.emit.Lock()
	s.mu.Lock()
	if s.status == StatusRunning || s.status == StatusStarting {
		s.status = StatusExited
	}
	if hasCode {
		s.exitCode = &code
	}
	if s.status == StatusStopped {
		// Explicit termination discards attach state; a natural exit keeps
		// it viewable until relaunch, delete, or daemon shutdown.
		if s.vt != nil {
			s.vt.Close()
			s.vt = nil
		}
	}
	// Nothing is working or waiting once the run is over.
	s.programs.remove(ProgramWorking, ProgramBlocked)
	status := s.status
	exitPtr := s.exitCode
	s.seq++
	seq := s.seq
	s.mu.Unlock()
	// The exit is the run's last item: nothing takes a sequence after the
	// status leaves running, so it can be reported without emit. Its
	// listeners take the terminal's lifecycle fence, whose holders resize
	// through emit.
	s.emit.Unlock()

	_ = s.ptyFile.Close()
	close(s.done)
	if s.events.Exit != nil {
		s.events.Exit(s.TerminalID, s.RunID, seq, status, exitPtr)
	}
}

// readPTY is the sole PTY reader. Its bounded destination is deliberate: once
// the publisher and queue fill, this goroutine stops reading and the kernel's
// PTY buffer naturally slows the child instead of dropping output.
func (s *Session) readPTY(reads chan<- []byte) {
	defer close(reads)
	buf := make([]byte, ptyReadBufferSize)
	for {
		n, readErr := s.ptyFile.Read(buf)
		if n > 0 {
			data := make([]byte, n)
			copy(data, buf[:n])
			reads <- data
		}
		if readErr != nil {
			// EOF or EIO: the child side of the PTY is gone.
			return
		}
	}
}

func (s *Session) publishOutput(data []byte) {
	s.emit.Lock()
	defer s.emit.Unlock()
	s.mu.Lock()
	s.seq++
	seq := s.seq
	// Feeding the terminal under the same lock that assigns its sequence
	// makes Snapshot atomic: attach state always describes exactly the
	// snapshot sequence, so an attach can neither lose nor duplicate output.
	if s.vt != nil {
		s.vt.Feed(data)
	}
	replies := s.replies
	s.replies = nil
	changed := s.programChanged
	s.programChanged = false
	s.mu.Unlock()
	for _, reply := range replies {
		s.queueInput(reply)
	}
	if s.events.Output != nil {
		s.events.Output(s.TerminalID, s.RunID, seq, data)
	}
	if changed && s.events.ProgramChanged != nil {
		s.events.ProgramChanged(s.TerminalID, s.RunID)
	}
}

// Snapshot is the authoritative attach point for one run. Data is a complete
// native Ghostty model captured atomically at Sequence; clients restore it
// before applying live items with a greater sequence.
type Snapshot struct {
	RunID          string
	Sequence       uint64
	Status         Status
	Columns        uint16
	Rows           uint16
	ExitCode       *int
	SnapshotFormat string
	Data           []byte
}

// Snapshot atomically captures attach state and the last assigned sequence.
func (s *Session) Snapshot() (Snapshot, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	snapshot := Snapshot{
		RunID:    s.RunID,
		Sequence: s.seq,
		Status:   s.status,
		Columns:  s.columns,
		Rows:     s.rows,
		ExitCode: s.exitCode,
	}
	if s.vt == nil {
		return snapshot, ErrNotRunning
	}
	format, err := vtscreen.SnapshotFormat()
	if err != nil {
		return snapshot, err
	}
	data, err := s.vt.Snapshot()
	if err != nil {
		return snapshot, fmt.Errorf("terminal snapshot encode: %w", err)
	}
	snapshot.SnapshotFormat = format
	snapshot.Data = data
	return snapshot, nil
}

// Release frees the attach model's native resources once no future attach
// can need them: after relaunch, removal, or service shutdown. Idempotent.
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
	running := s.status == StatusRunning
	s.mu.Unlock()
	if !running {
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
// publishes it as a stream item at its sequence, so every client resizes at
// the same point in the output. A run that ended keeps its last grid, which
// views draw scaled. Unchanged dimensions are not re-applied.
func (s *Session) Resize(columns, rows uint16) error {
	if err := ValidateSize(columns, rows); err != nil {
		return err
	}
	s.emit.Lock()
	defer s.emit.Unlock()
	s.mu.Lock()
	if s.status != StatusRunning {
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
	s.seq++
	seq := s.seq
	s.mu.Unlock()
	if s.events.Resized != nil {
		s.events.Resized(s.TerminalID, s.RunID, seq, columns, rows)
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
		alive := s.status == StatusRunning || s.status == StatusStarting
		if alive {
			s.status = StatusStopped
		}
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

// Status returns the current lifecycle status.
func (s *Session) Status() Status {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.status
}

// Size returns the last applied grid dimensions.
func (s *Session) Size() (columns, rows uint16) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.columns, s.rows
}

// ExitCode returns the child's exit code when it has one.
func (s *Session) ExitCode() (code int, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.exitCode == nil {
		return 0, false
	}
	return *s.exitCode, true
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
	return "terminal-" + newRunID()
}

func newRunID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
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
