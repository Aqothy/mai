package terminal

import "testing"

// Encodings from xterm's ctlseqs and the kitty keyboard protocol.
func TestIsUserInput(t *testing.T) {
	for _, tc := range []struct {
		name string
		data string
		want bool
	}{
		{"text", "ls", true},
		{"return", "\r", true},
		{"ctrl-c", "\x03", true},
		{"escape", "\x1b", true},
		{"alt-x", "\x1bx", true},
		{"arrow", "\x1b[A", true},
		{"application arrow", "\x1bOA", true},
		{"ctrl-right", "\x1b[1;5C", true},
		{"delete", "\x1b[3~", true},
		{"shift-tab", "\x1b[Z", true},
		{"kitty key", "\x1b[97;5u", true},
		{"paste", "\x1b[200~echo hi\x1b[201~", true},
		{"incomplete csi", "\x1b[1;", true},
		{"reply then key", "\x1b[?62;22cq", true},

		{"nothing", "", false},
		{"device attributes", "\x1b[?62;22c", false},
		{"secondary device attributes", "\x1b[>1;10;0c", false},
		{"cursor position", "\x1b[12;40R", false},
		{"private mode", "\x1b[?2026;2$y", false},
		{"ansi mode", "\x1b[4;2$y", false},
		{"kitty keyboard flags", "\x1b[?1u", false},
		{"device status", "\x1b[0n", false},
		{"window size", "\x1b[8;24;80t", false},
		{"xtversion", "\x1bP>|ghostty 1.2.0\x1b\\", false},
		{"background color", "\x1b]11;rgb:0000/0000/0000\x1b\\", false},
		{"color with bel", "\x1b]10;rgb:ffff/ffff/ffff\x07", false},
		{"focus in", "\x1b[I", false},
		{"sgr mouse", "\x1b[<0;10;5M", false},
		{"x10 mouse", "\x1b[M !!", false},
		{"several replies", "\x1b[?62;22c\x1b[12;40R\x1bP>|ghostty\x1b\\", false},
	} {
		if got := IsUserInput([]byte(tc.data)); got != tc.want {
			t.Errorf("%s %q: IsUserInput = %v, want %v", tc.name, tc.data, got, tc.want)
		}
	}
}
