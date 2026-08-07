package vtscreen

import libghostty "go.mitchellh.com/libghostty"

// The detector never renders, so pixel dimensions are stable dummy values.
const (
	dummyCellWidthPx  = 8
	dummyCellHeightPx = 16
)

// New creates one passive, zero-scrollback Ghostty VT screen. No effect
// callbacks are registered: the screen cannot answer PTY queries or produce
// input, it only accumulates state for formatting.
func New(columns, rows uint16) (Screen, error) {
	term, err := libghostty.NewTerminal(
		libghostty.WithSize(columns, rows),
		// Zero scrollback: detection follows the live bottom screen, never
		// a history buffer.
		libghostty.WithMaxScrollbackBytes(0),
	)
	if err != nil {
		return nil, err
	}
	formatter, err := libghostty.NewFormatter(term,
		libghostty.WithFormatterFormat(libghostty.FormatterFormatPlain),
		libghostty.WithFormatterTrim(true),
	)
	if err != nil {
		term.Close()
		return nil, err
	}
	return &ghosttyScreen{term: term, formatter: formatter}, nil
}

type ghosttyScreen struct {
	term      *libghostty.Terminal
	formatter *libghostty.Formatter
	closed    bool
}

func (s *ghosttyScreen) Feed(data []byte) {
	if s.closed {
		return
	}
	// Terminal.Write consumes the whole slice; VT errors do not stop the
	// stream, matching how a real renderer tolerates malformed output.
	_, _ = s.term.Write(data)
}

func (s *ghosttyScreen) Resize(columns, rows uint16) {
	if s.closed {
		return
	}
	_ = s.term.Resize(columns, rows, dummyCellWidthPx, dummyCellHeightPx)
}

func (s *ghosttyScreen) Text() (string, error) {
	if s.closed {
		return "", ErrUnavailable
	}
	return s.formatter.FormatString()
}

func (s *ghosttyScreen) Close() {
	if s.closed {
		return
	}
	s.closed = true
	s.formatter.Close()
	s.term.Close()
}
