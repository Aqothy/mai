package terminal

import (
	"slices"
	"strings"
	"unicode"
)

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
// display text from its first word with a letter or digit. Agents animate
// what comes before (Claude Code's ✳ ◐ ◑, Codex's braille frames and its
// "[ ! ]" blink), so an animation leaves the title, and the list, unchanged.
func normalizeTitle(raw string) string {
	fields := strings.Fields(displayText(raw, len(raw)))
	first := slices.IndexFunc(fields, func(field string) bool {
		return strings.IndexFunc(field, func(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) }) >= 0
	})
	if first < 0 {
		return ""
	}
	return capScalars(strings.Join(fields[first:], " "), maxTitleScalars)
}

// capScalars bounds a string to n Unicode scalars.
func capScalars(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n])
}
