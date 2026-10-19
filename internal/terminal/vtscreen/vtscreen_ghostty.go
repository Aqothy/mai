// Package vtscreen wraps the daemon's libghostty-vt terminal for one run:
// the one terminal that parses the program's output, answers its queries,
// reports its title, working directory and program status, and exports the
// native snapshot clients attach from. Clients render the same output but
// never answer the program, so every query gets exactly one reply.
//
// The package links a static libghostty-vt through cgo; `make ghostty-vt`
// builds the pinned library and `make build`/`make test` point pkg-config
// at it.
//
// The caller serializes all access, and effects run inside Feed under the
// caller's lock, so they must not block.
package vtscreen

import (
	"errors"
	"fmt"
	"sync"

	libghostty "go.mitchellh.com/libghostty"
)

const (
	// Pixel sizes for size reports (CSI 14/16 t). The daemon doesn't know
	// the views' fonts, and nothing it runs depends on pixels: kitty
	// graphics are out of scope.
	cellWidthPx  = 8
	cellHeightPx = 16
	// attachContinuationMaxBytes keeps an escape sequence or UTF-8
	// codepoint split across the snapshot/live boundary in the snapshot.
	// Without it, the client would get only the suffix as live output and
	// parse a different terminal state.
	attachContinuationMaxBytes = 64 * 1024
)

// ErrUnavailable reports use of a closed screen.
var ErrUnavailable = errors.New("terminal screen is closed")

// RGB is one color.
type RGB struct{ R, G, B uint8 }

// Appearance is the theme of the view whose answers the program gets: OSC
// 10/11/4 color queries and light/dark reports (CSI ? 996 n).
type Appearance struct {
	Foreground RGB
	Background RGB
	// Palette overrides the first len(Palette) entries of Ghostty's
	// 256-color palette.
	Palette []RGB
	Dark    bool
}

// ProgramState is what a program reported doing (OSC 7501).
type ProgramState int

const (
	ProgramIdle ProgramState = iota
	ProgramWorking
	ProgramDone
	ProgramBlocked
	ProgramError
	// ProgramClear removes the record and its children instead of
	// describing the program.
	ProgramClear
)

// ProgramKind is what a blocked program needs.
type ProgramKind int

const (
	ProgramNeedsNothing ProgramKind = iota
	ProgramNeedsPermission
	ProgramNeedsAnswer
	ProgramNeedsAuth
)

// ProgramStatus is one OSC 7501 report. Title and Message come from the
// program: untrusted display text without control characters.
type ProgramStatus struct {
	ID      string
	App     string
	Title   string
	Message string
	State   ProgramState
	Kind    ProgramKind
	// Progress is 0-100, or -1 when the program gave none.
	Progress int
}

// Effects receive what the program asks of the terminal. Each runs inside
// Feed.
type Effects struct {
	// Reply receives the terminal's answers for the PTY.
	Reply func(data []byte)
	// TitleChanged reports OSC 0/2.
	TitleChanged func(title string)
	// PwdChanged reports OSC 7.
	PwdChanged func(pwd string)
	// ProgramStatus reports OSC 7501.
	ProgramStatus func(status ProgramStatus)
	// PromptStarted reports a new shell prompt (OSC 133;A).
	PromptStarted func()
}

// Screen is one run's terminal. Callers serialize all calls.
type Screen struct {
	term    *libghostty.Terminal
	columns uint16
	rows    uint16
	dark    bool
	closed  bool
}

// New creates a run's terminal with Ghostty.app's defaults (grapheme
// clustering, a blinking cursor) and bounded scrollback.
func New(columns, rows uint16, maxScrollbackBytes uint, effects Effects) (*Screen, error) {
	s := &Screen{columns: columns, rows: rows, dark: true}
	term, err := libghostty.NewTerminal(
		libghostty.WithSize(columns, rows),
		libghostty.WithMaxScrollbackBytes(maxScrollbackBytes),
		libghostty.WithContinuationMaxBytes(attachContinuationMaxBytes),
		libghostty.WithModeDefault(libghostty.ModeGraphemeCluster, true),
		libghostty.WithWritePty(func(_ *libghostty.Terminal, data []byte) {
			if effects.Reply != nil {
				effects.Reply(append([]byte(nil), data...))
			}
		}),
		libghostty.WithTitleChanged(func(t *libghostty.Terminal) {
			if title, err := t.Title(); err == nil && effects.TitleChanged != nil {
				effects.TitleChanged(title)
			}
		}),
		libghostty.WithPwdChanged(func(t *libghostty.Terminal) {
			if pwd, err := t.Pwd(); err == nil && effects.PwdChanged != nil {
				effects.PwdChanged(pwd)
			}
		}),
		libghostty.WithProgramStatus(func(_ *libghostty.Terminal, status libghostty.ProgramStatus) {
			if effects.ProgramStatus != nil {
				effects.ProgramStatus(programStatus(status))
			}
		}),
		libghostty.WithSemanticPrompt(func(_ *libghostty.Terminal, event libghostty.TerminalSemanticPrompt) {
			if event.Kind == libghostty.SemanticPromptStart && effects.PromptStarted != nil {
				effects.PromptStarted()
			}
		}),
		libghostty.WithSizeReport(func(*libghostty.Terminal) (libghostty.SizeReportSize, bool) {
			return libghostty.SizeReportSize{
				Rows: s.rows, Columns: s.columns, CellWidth: cellWidthPx, CellHeight: cellHeightPx,
			}, true
		}),
		libghostty.WithColorScheme(func(*libghostty.Terminal) (libghostty.ColorScheme, bool) {
			if s.dark {
				return libghostty.ColorSchemeDark, true
			}
			return libghostty.ColorSchemeLight, true
		}),
		libghostty.WithDeviceAttributes(func(*libghostty.Terminal) (libghostty.DeviceAttributes, bool) {
			return deviceAttributes, true
		}),
		libghostty.WithXtversion(func(*libghostty.Terminal) string { return "maiD" }),
	)
	if err != nil {
		return nil, err
	}
	// Cursor blink is a reset default of its own, not a mode default.
	blink := true
	if err := term.SetDefaultCursorBlink(&blink); err != nil {
		term.Close()
		return nil, err
	}
	s.term = term
	return s, nil
}

// deviceAttributes are Ghostty's (termio/stream_handler.zig
// deviceAttributes): a VT220 with color text and clipboard access, since
// clients take OSC 52 writes.
var deviceAttributes = func() libghostty.DeviceAttributes {
	var attributes libghostty.DeviceAttributes
	attributes.Primary.ConformanceLevel = 62
	attributes.Primary.Features[0] = 22
	attributes.Primary.Features[1] = 52
	attributes.Primary.NumFeatures = 2
	attributes.Secondary.DeviceType = 1
	attributes.Secondary.FirmwareVersion = 10
	return attributes
}()

func programStatus(status libghostty.ProgramStatus) ProgramStatus {
	state := map[libghostty.ProgramStatusState]ProgramState{
		libghostty.ProgramStatusStateIdle:    ProgramIdle,
		libghostty.ProgramStatusStateWorking: ProgramWorking,
		libghostty.ProgramStatusStateDone:    ProgramDone,
		libghostty.ProgramStatusStateBlocked: ProgramBlocked,
		libghostty.ProgramStatusStateError:   ProgramError,
		libghostty.ProgramStatusStateClear:   ProgramClear,
	}[status.State]
	// Kinds a later libghostty adds read as no kind (the binding's advice).
	kind := map[libghostty.ProgramStatusKind]ProgramKind{
		libghostty.ProgramStatusKindPermission: ProgramNeedsPermission,
		libghostty.ProgramStatusKindQuestion:   ProgramNeedsAnswer,
		libghostty.ProgramStatusKindAuth:       ProgramNeedsAuth,
	}[status.Kind]
	return ProgramStatus{
		ID:       status.ID,
		App:      status.App,
		Title:    status.Title,
		Message:  status.Message,
		State:    state,
		Kind:     kind,
		Progress: int(status.Progress),
	}
}

// SnapshotFormat names the GHOSTSNP contract of the linked libghostty-vt.
// GHOSTSNP v1 isn't stable across Ghostty commits (ghostty snapshot.h), so a
// client may decode a snapshot only if its library reports the same commit.
// The commit comes from the build's -Dlib-version-string
// (tools/ghostty-vt/CMakeLists.txt).
var SnapshotFormat = sync.OnceValues(func() (string, error) {
	info, err := libghostty.GetBuildInfo()
	if err != nil {
		return "", fmt.Errorf("libghostty-vt build info: %w", err)
	}
	if info.VersionBuild == "" {
		return "", errors.New("libghostty-vt was built without its commit in -Dlib-version-string")
	}
	return "ghostty-gsn-v1-" + info.VersionBuild, nil
})

// Feed parses program output. Malformed input never stops the stream, as a
// real terminal tolerates it.
func (s *Screen) Feed(data []byte) {
	if s.closed {
		return
	}
	_, _ = s.term.Write(data)
}

// Resize reflows the terminal to a new grid.
func (s *Screen) Resize(columns, rows uint16) error {
	if s.closed {
		return ErrUnavailable
	}
	if err := s.term.Resize(columns, rows, cellWidthPx, cellHeightPx); err != nil {
		return err
	}
	s.columns, s.rows = columns, rows
	return nil
}

// SetAppearance makes the terminal answer with a view's theme. A program's
// own color changes (OSC 4/10/11) still win until it resets them.
func (s *Screen) SetAppearance(appearance Appearance) error {
	if s.closed {
		return ErrUnavailable
	}
	foreground := libghostty.ColorRGB(appearance.Foreground)
	background := libghostty.ColorRGB(appearance.Background)
	palette := libghostty.DefaultPalette()
	for index, color := range appearance.Palette {
		palette[index] = libghostty.ColorRGB(color)
	}
	if err := s.term.SetColorForeground(&foreground); err != nil {
		return err
	}
	if err := s.term.SetColorBackground(&background); err != nil {
		return err
	}
	if err := s.term.SetColorPalette(&palette); err != nil {
		return err
	}
	s.dark = appearance.Dark
	return nil
}

// Snapshot exports the terminal's complete native model.
func (s *Screen) Snapshot() ([]byte, error) {
	if s.closed {
		return nil, ErrUnavailable
	}
	return s.term.Snapshot()
}

// Close releases the terminal's native resources.
func (s *Screen) Close() {
	if s.closed {
		return
	}
	s.closed = true
	s.term.Close()
}
