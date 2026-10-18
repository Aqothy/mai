package terminal

// IsUserInput reports whether bytes a client's terminal wrote hold anything
// the user typed or pasted, as opposed to only what a terminal sends on its
// own: replies to the program's queries (device attributes, cursor position,
// mode, color and size reports, XTVERSION and other DCS replies), mouse
// reports and focus events (encodings from xterm's ctlseqs). An unknown or
// incomplete sequence counts as input, so a key is never mistaken for a
// reply, except where xterm's encodings collide: CSI 1;5R is both a cursor
// position report and Ctrl+F3.
func IsUserInput(data []byte) bool {
	for i := 0; i < len(data); {
		next, report := terminalReport(data, i)
		if !report {
			return true
		}
		i = next
	}
	return false
}

// terminalReport reports whether the sequence at data[i] is one a terminal
// sends on its own, and where it ends.
func terminalReport(data []byte, i int) (next int, report bool) {
	if data[i] != 0x1b || i+1 >= len(data) {
		return 0, false
	}
	switch data[i+1] {
	case '[':
		return csiReport(data, i+2)
	case ']':
		// OSC replies (colors, clipboard) end with BEL or ST.
		for j := i + 2; j < len(data); j++ {
			if data[j] == 0x07 {
				return j + 1, true
			}
			if data[j] == 0x1b && j+1 < len(data) && data[j+1] == '\\' {
				return j + 2, true
			}
		}
		return 0, false
	case 'P', '_', '^', 'X':
		// DCS (XTVERSION, DECRQSS, XTGETTCAP), APC (kitty graphics), PM and
		// SOS replies end with ST.
		for j := i + 2; j+1 < len(data); j++ {
			if data[j] == 0x1b && data[j+1] == '\\' {
				return j + 2, true
			}
		}
		return 0, false
	default:
		return 0, false
	}
}

// csiReport classifies the CSI sequence whose parameters start at data[i].
func csiReport(data []byte, i int) (next int, report bool) {
	start := i
	for i < len(data) && data[i] >= 0x30 && data[i] <= 0x3f {
		i++
	}
	params := data[start:i]
	intermediates := i
	for i < len(data) && data[i] >= 0x20 && data[i] <= 0x2f {
		i++
	}
	if i >= len(data) || data[i] < 0x40 || data[i] > 0x7e {
		return 0, false
	}
	final, hasIntermediate, next := data[i], i > intermediates, i+1
	if len(params) > 0 {
		switch params[0] {
		case '?', '>', '=':
			// DA1, DA2, DA3, private mode, kitty keyboard flags and DSR replies.
			return next, true
		case '<':
			// SGR mouse.
			return next, final == 'M' || final == 'm'
		}
	}
	switch {
	case final == 'M' && len(params) == 0 && !hasIntermediate:
		// X10 mouse: button, column and row follow as bytes.
		if next+3 > len(data) {
			return 0, false
		}
		return next + 3, true
	case final == 'R':
		// Cursor position report: row;column.
		return next, countParams(params) == 2
	case (final == 'I' || final == 'O') && len(params) == 0:
		// Focus in and out.
		return next, true
	case final == 'n', final == 't':
		// Device status and window size reports.
		return next, true
	case final == 'y' && hasIntermediate && data[next-2] == '$':
		// ANSI mode report.
		return next, true
	default:
		return next, false
	}
}

func countParams(params []byte) int {
	if len(params) == 0 {
		return 0
	}
	count := 1
	for _, b := range params {
		if b == ';' {
			count++
		}
	}
	return count
}
