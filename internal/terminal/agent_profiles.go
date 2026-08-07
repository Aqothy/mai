package terminal

import (
	"strings"

	"github.com/Aqothy/maiD/internal/terminal/agentrules"
)

// agentEvidence is everything Increment 8 classification may inspect. Screen
// text joins in Increment 9 through the detector VT and stays empty until
// then.
type agentEvidence struct {
	kind AgentKind
	// rawTitle is the last observed OSC 0/2 title capped at 256 scalars,
	// spinner frames intact; classification depends on them.
	rawTitle string
	// progress is the raw OSC 9;4 payload in "4;<state>[;value]" form.
	progress string
	// screen is the current formatted detector screen, empty when no
	// detector VT exists.
	screen string
}

// classifyActivity maps evidence to semantic activity through the embedded
// rule tables. A skip-state rule (agent-owned transcript viewer on screen)
// keeps the previous activity. Ambiguity yields unknown, never a confident
// claim.
func classifyActivity(e agentEvidence, prev AgentActivityState) AgentActivityState {
	if e.kind == AgentNone {
		return AgentActivityNone
	}
	d := agentrules.Detect(string(e.kind), agentrules.Input{
		Screen:      e.screen,
		OSCTitle:    e.rawTitle,
		OSCProgress: e.progress,
	})
	if d.SkipStateUpdate && prev != AgentActivityNone {
		return prev
	}
	switch d.State {
	case agentrules.StateWorking:
		return AgentActivityWorking
	case agentrules.StateBlocked:
		return AgentActivityBlocked
	case agentrules.StateIdle:
		return AgentActivityIdle
	default:
		return AgentActivityUnknown
	}
}

// identifyAgentGroup names the agent kind for one foreground process group.
// An unrecognized non-shell group is AgentUnknown so the generic OSC rules
// still apply to agents without their own manifest.
func identifyAgentGroup(leaderPGID int, processes []processInfo) AgentKind {
	group := make([]agentrules.GroupProcess, 0, len(processes))
	for _, p := range processes {
		group = append(group, agentrules.GroupProcess{PID: p.pid, Argv: p.argv})
	}
	if label, ok := agentrules.IdentifyGroup(leaderPGID, group); ok {
		return AgentKind(label)
	}
	return AgentUnknown
}

// spinnerGlyphs are single-character status markers agents prepend to titles.
// They are stripped from the normalized title so animation frames and idle
// markers do not churn the thread list or read as part of the task text.
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

const (
	rawTitleScalarCap        = 256
	normalizedTitleScalarCap = 128
)

// capScalars bounds a string to n Unicode scalars.
func capScalars(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n])
}

func isBrailleSpinnerRune(r rune) bool {
	return r >= 0x2800 && r <= 0x28FF
}

// normalizeTitle produces the client-visible observed title: control
// characters removed, whitespace collapsed to single spaces, spinner frames
// and marker glyphs dropped, capped at 128 scalars. A spinner changing frames
// yields an unchanged normalized title, so no repeated publishes occur.
func normalizeTitle(raw string) string {
	var b strings.Builder
	b.Grow(len(raw))
	for _, r := range raw {
		if r < 0x20 || r == 0x7F || (r >= 0x80 && r <= 0x9F) {
			b.WriteRune(' ')
			continue
		}
		b.WriteRune(r)
	}
	fields := strings.Fields(b.String())
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
	return capScalars(strings.Join(kept, " "), normalizedTitleScalarCap)
}
