package terminal

import "strings"

const (
	maxTitleScalars      = 128
	maxStatusTextScalars = 256
)

// displayText makes program-supplied text safe to show outside the
// terminal: control and text-direction characters removed (so a title
// can't reorder the row it's shown in), whitespace collapsed, capped at n
// scalars.
func displayText(raw string, n int) string {
	var b strings.Builder
	b.Grow(len(raw))
	for _, r := range raw {
		switch {
		case r < 0x20, r == 0x7F, r >= 0x80 && r <= 0x9F:
			b.WriteRune(' ')
		case isDirectionControl(r):
		default:
			b.WriteRune(r)
		}
	}
	return capScalars(strings.Join(strings.Fields(b.String()), " "), n)
}

func isDirectionControl(r rune) bool {
	return r == 0x061C || r == 0x200E || r == 0x200F || (r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069)
}

// normalizeTitle is the window title as the terminal list shows it:
// display text without the spinner frames and status glyphs agents put in
// front, so an animating spinner leaves the title unchanged and doesn't
// churn the list.
func normalizeTitle(raw string) string {
	fields := strings.Fields(displayText(raw, len(raw)))
	kept := fields[:0]
	for _, field := range fields {
		runes := []rune(field)
		if len(runes) == 1 {
			if _, marker := spinnerGlyphs[runes[0]]; marker || isBrailleSpinnerRune(runes[0]) {
				continue
			}
		}
		kept = append(kept, field)
	}
	return capScalars(strings.Join(kept, " "), maxTitleScalars)
}

// spinnerGlyphs are single-character status markers agents prepend to titles.
var spinnerGlyphs = map[rune]struct{}{
	'✳': {},
	'✶': {},
	'✻': {},
	'✽': {},
	'✢': {},
	'·': {},
	'∗': {},
	'*': {},
	'◐': {},
	'◓': {},
	'◑': {},
	'◒': {},
}

func isBrailleSpinnerRune(r rune) bool {
	return r >= 0x2800 && r <= 0x28FF
}

// capScalars bounds a string to n Unicode scalars.
func capScalars(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n])
}
