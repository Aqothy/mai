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
	// attachScrollbackBytes bounds the attach model's retained scrollback.
	attachScrollbackBytes = 2 * 1024 * 1024
)

// Session is one live PTY run. All mutating operations are serialized on mu;
// PTY writes use a dedicated mutex so a blocked write cannot deadlock resize
// or termination.
type Session struct {
	TerminalID string
	RunID      string

	mu       sync.Mutex
	ptyFile  *os.File
	cmd      *exec.Cmd
	status   Status
	columns  uint16
	rows     uint16
	seq      uint64
	exitCode *int
	events   Events
	// attachVT is the passive terminal model exported for attach. It retains
	// bounded scrollback and is fed under mu in sequence order so native
	// snapshots are atomic with the sequence counter. Nil only after the run's
	// attach state has been released.
	attachVT vtscreen.SnapshotScreen

	writeMu sync.Mutex

	// detector derives shared agent state from the same output stream the
	// clients render. It lives outside mu; its own lock serializes it.
	detector *Detector

	// done closes after the child has been reaped and the PTY closed.
	done          chan struct{}
	terminateOnce sync.Once
}

// SpawnSpec describes one shell launch.
type SpawnSpec struct {
	// Cwd is resolved to the user's home directory when empty. It must name
	// an existing directory.
	Cwd     string
	Columns uint16
	Rows    uint16
}

func startSession(terminalID string, spec SpawnSpec, events Events) (*Session, error) {
	cwd, err := ResolveCwd(spec.Cwd)
	if err != nil {
		return nil, err
	}
	if err := ValidateSize(spec.Columns, spec.Rows); err != nil {
		return nil, err
	}

	shell := resolveShell()
	cmd := exec.Command(shell)
	// The dash-prefixed argv[0] asks the shell to behave as a login shell.
	cmd.Args = []string{"-" + filepath.Base(shell)}
	cmd.Dir = cwd
	cmd.Env = sessionEnv()

	s := &Session{
		TerminalID: terminalID,
		RunID:      newRunID(),
		cmd:        cmd,
		status:     StatusStarting,
		columns:    spec.Columns,
		rows:       spec.Rows,
		events:     events,
		done:       make(chan struct{}),
	}

	// The attach model is the source of attach state; a session cannot run
	// without it. Failure here means a misbuilt daemon, not a user error.
	attachVT, err := vtscreen.NewSnapshot(spec.Columns, spec.Rows, attachScrollbackBytes)
	if err != nil {
		return nil, fmt.Errorf("terminal attach model: %w", err)
	}
	s.attachVT = attachVT

	// creack/pty starts the child with Setsid, so the shell leads its own
	// session and process group; group signals reach every descendant.
	ptyFile, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: spec.Rows, Cols: spec.Columns})
	if err != nil {
		attachVT.Close()
		return nil, fmt.Errorf("spawn %s: %w", shell, err)
	}
	s.ptyFile = ptyFile
	s.status = StatusRunning
	// A failed detection screen degrades to process and OSC evidence; the
	// terminal itself is unaffected.
	screen, screenErr := vtscreen.New(spec.Columns, spec.Rows)
	if screenErr != nil {
		screen = nil
	}
	s.detector = newDetector(detectorConfig{
		shellPGID: cmd.Process.Pid,
		foregroundPGID: func() (int, bool) {
			return foregroundProcessGroup(ptyFile)
		},
		inspectGroup: inspectProcessGroup,
		screen:       screen,
		publish: func(report AgentReport) {
			if events.Agent != nil {
				events.Agent(s.TerminalID, s.RunID, report)
			}
		},
	})
	go s.readLoop()
	return s, nil
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
		if s.attachVT != nil {
			s.attachVT.Close()
			s.attachVT = nil
		}
	}
	status := s.status
	exitPtr := s.exitCode
	s.seq++
	seq := s.seq
	s.mu.Unlock()

	// The detector stops before the PTY closes so its foreground probes
	// never race a closing descriptor. Its last report stays readable for
	// list summaries until relaunch or delete replaces the session.
	s.detector.Stop()
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
	s.mu.Lock()
	s.seq++
	seq := s.seq
	// Feeding the attach model under the same lock that assigns its
	// sequence makes Snapshot atomic: attach state always describes exactly
	// the snapshot sequence, so an attach can neither lose nor duplicate
	// output.
	if s.attachVT != nil {
		s.attachVT.Feed(data)
	}
	s.mu.Unlock()
	// The detector sees the original bytes once, in output order, before
	// client fanout; both sides parse the same stream independently.
	s.detector.ObserveOutput(data)
	if s.events.Output != nil {
		s.events.Output(s.TerminalID, s.RunID, seq, data)
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
	if s.attachVT == nil {
		return snapshot, ErrNotRunning
	}
	data, err := s.attachVT.Snapshot()
	if err != nil {
		return snapshot, fmt.Errorf("terminal snapshot encode: %w", err)
	}
	snapshot.SnapshotFormat = GhosttySnapshotFormat
	snapshot.Data = data
	return snapshot, nil
}

// Release frees the attach model's native resources once no future attach
// can need them: after relaunch, removal, or service shutdown. Idempotent.
func (s *Session) Release() {
	s.mu.Lock()
	if s.attachVT != nil {
		s.attachVT.Close()
		s.attachVT = nil
	}
	s.mu.Unlock()
}

// Write sends input bytes to the shell.
func (s *Session) Write(data []byte) error {
	s.mu.Lock()
	if s.status != StatusRunning {
		s.mu.Unlock()
		return ErrNotRunning
	}
	f := s.ptyFile
	s.mu.Unlock()

	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	if _, err := f.Write(data); err != nil {
		return fmt.Errorf("terminal write: %w", err)
	}
	return nil
}

// Resize applies a changed grid size to a running PTY and its passive models.
// After a natural exit, the retained attach model can still reflow to an
// attaching client's grid even though there is no longer a PTY to resize.
// Unchanged dimensions are deduplicated and not re-applied.
func (s *Session) Resize(columns, rows uint16) error {
	if err := ValidateSize(columns, rows); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.status != StatusRunning && (s.status != StatusExited || s.attachVT == nil) {
		return ErrNotRunning
	}
	if s.columns == columns && s.rows == rows {
		return nil
	}
	if s.status == StatusRunning {
		if err := pty.Setsize(s.ptyFile, &pty.Winsize{Rows: rows, Cols: columns}); err != nil {
			return fmt.Errorf("terminal resize: %w", err)
		}
	}
	if s.attachVT != nil {
		if err := s.attachVT.Resize(columns, rows); err != nil {
			return fmt.Errorf("terminal model resize: %w", err)
		}
	}
	s.columns = columns
	s.rows = rows
	// The detector is relevant only while the run is live.
	if s.status == StatusRunning {
		s.detector.ResizeScreen(columns, rows)
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

// AgentReport returns the run's last published agent state.
func (s *Session) AgentReport() AgentReport { return s.detector.Report() }

// SetAttached tells the run's detector whether any client is attached.
// Attaching acknowledges a pending done state.
func (s *Session) SetAttached(attached bool) { s.detector.SetAttached(attached) }

// PID exposes the shell leader's pid for tests.
func (s *Session) PID() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cmd.Process == nil {
		return 0
	}
	return s.cmd.Process.Pid
}

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
	if _, err := rand.Read(b[:]); err != nil {
		// crypto/rand does not fail on supported platforms; keep IDs unique
		// enough for one process if it ever does.
		return fmt.Sprintf("run-%d", time.Now().UnixNano())
	}
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
