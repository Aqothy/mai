// Package agentrules classifies coding-agent activity from terminal
// evidence: the current screen text, the OSC 0/2 title, and the OSC 9;4
// progress payload. Rules are compiled in from embedded manifests originally
// recorded by the Herdr project (see manifests/NOTICE); there is no remote
// update mechanism and no plugin system.
//
// The package is pure classification. It knows nothing about PTYs, RPC, or
// scheduling; the terminal detector owns when to evaluate and how to
// stabilize transitions.
package agentrules

import (
	"embed"
	"fmt"
	"regexp"
	"strings"

	"github.com/BurntSushi/toml"
)

//go:embed manifests/*.toml
var manifestFS embed.FS

// State is a manifest-declared activity state.
type State string

const (
	StateWorking State = "working"
	StateBlocked State = "blocked"
	StateIdle    State = "idle"
	StateUnknown State = "unknown"
)

// Input is the evidence one evaluation may inspect. Screen is empty when no
// screen source exists (detector VT absent or unavailable); screen-region
// rules are skipped rather than evaluated against an empty screen.
type Input struct {
	Screen string
	// OSCTitle is the raw observed terminal title, spinner frames intact.
	OSCTitle string
	// OSCProgress is the raw OSC 9 payload after the leading "9;", for
	// example "4;0" or "4;1;42". Empty when no progress was observed.
	OSCProgress string
}

// Detection is the outcome of evaluating one agent's rules.
type Detection struct {
	State State
	// SkipStateUpdate means the screen currently shows an agent-owned
	// viewer (transcript, model picker) rather than live prompt state; the
	// caller should keep its previous state.
	SkipStateUpdate bool
	// Rule is the matched rule id, for bounded diagnostics only.
	Rule string
}

type manifest struct {
	ID               string   `toml:"id"`
	Version          string   `toml:"version"`
	MinEngineVersion int      `toml:"min_engine_version"`
	UpdatedAt        string   `toml:"updated_at"`
	Aliases          []string `toml:"aliases"`
	Rules            []rule   `toml:"rules"`
}

type rule struct {
	ID              string `toml:"id"`
	State           string `toml:"state"`
	Priority        int    `toml:"priority"`
	Region          string `toml:"region"`
	SkipStateUpdate bool   `toml:"skip_state_update"`
	// visible_* flags exist in the manifests for Herdr's source arbitration;
	// maiD's detector does not use them but they must decode.
	VisibleIdle    bool `toml:"visible_idle"`
	VisibleBlocker bool `toml:"visible_blocker"`
	VisibleWorking bool `toml:"visible_working"`

	Contains  []string `toml:"contains"`
	Regex     []string `toml:"regex"`
	LineRegex []string `toml:"line_regex"`
	All       []gate   `toml:"all"`
	Any       []gate   `toml:"any"`
	Not       []gate   `toml:"not"`
}

type gate struct {
	Contains  []string `toml:"contains"`
	Regex     []string `toml:"regex"`
	LineRegex []string `toml:"line_regex"`
	All       []gate   `toml:"all"`
	Any       []gate   `toml:"any"`
	Not       []gate   `toml:"not"`
}

type compiledGate struct {
	contains  []string // lowercased; all must be present case-insensitively
	regex     []*regexp.Regexp
	lineRegex []*regexp.Regexp
	all       []compiledGate
	any       []compiledGate
	not       []compiledGate
}

type compiledRule struct {
	id              string
	state           State
	priority        int
	region          string
	skipStateUpdate bool
	gate            compiledGate
}

type compiledManifest struct {
	label string
	rules []compiledRule
}

// manifestEngineVersion is the small, local compatibility contract for the
// embedded Herdr rule features implemented by this package. It is not a
// remote-update protocol.
const manifestEngineVersion = 3

// manifestsByLabel maps every manifest id and alias to its compiled rules.
var manifestsByLabel = mustLoadManifests()

func mustLoadManifests() map[string]*compiledManifest {
	entries, err := manifestFS.ReadDir("manifests")
	if err != nil {
		panic(fmt.Sprintf("agentrules: read embedded manifests: %v", err))
	}
	byLabel := make(map[string]*compiledManifest)
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".toml") {
			continue
		}
		data, err := manifestFS.ReadFile("manifests/" + entry.Name())
		if err != nil {
			panic(fmt.Sprintf("agentrules: read %s: %v", entry.Name(), err))
		}
		var m manifest
		metadata, err := toml.Decode(string(data), &m)
		if err != nil {
			panic(fmt.Sprintf("agentrules: parse %s: %v", entry.Name(), err))
		}
		if undecoded := metadata.Undecoded(); len(undecoded) > 0 {
			panic(fmt.Sprintf("agentrules: parse %s: unsupported fields %v", entry.Name(), undecoded))
		}
		compiled, err := compileManifest(m)
		if err != nil {
			panic(fmt.Sprintf("agentrules: compile %s: %v", entry.Name(), err))
		}
		byLabel[m.ID] = compiled
		for _, alias := range m.Aliases {
			byLabel[alias] = compiled
		}
	}
	return byLabel
}

func compileManifest(m manifest) (*compiledManifest, error) {
	if m.MinEngineVersion <= 0 {
		return nil, fmt.Errorf("missing min_engine_version")
	}
	if m.MinEngineVersion > manifestEngineVersion {
		return nil, fmt.Errorf("requires engine %d, current engine is %d", m.MinEngineVersion, manifestEngineVersion)
	}
	compiled := &compiledManifest{label: m.ID}
	for _, r := range m.Rules {
		region := strings.TrimSpace(r.Region)
		if !supportedRegion(region) {
			return nil, fmt.Errorf("rule %s: unsupported region %q", r.ID, region)
		}
		g, err := compileGate(gate{
			Contains:  r.Contains,
			Regex:     r.Regex,
			LineRegex: r.LineRegex,
			All:       r.All,
			Any:       r.Any,
			Not:       r.Not,
		})
		if err != nil {
			return nil, fmt.Errorf("rule %s: %w", r.ID, err)
		}
		state := State(r.State)
		switch state {
		case StateWorking, StateBlocked, StateIdle, StateUnknown:
		case "":
			state = StateUnknown
		default:
			return nil, fmt.Errorf("rule %s: unsupported state %q", r.ID, r.State)
		}
		compiled.rules = append(compiled.rules, compiledRule{
			id:              r.ID,
			state:           state,
			priority:        r.Priority,
			region:          region,
			skipStateUpdate: r.SkipStateUpdate,
			gate:            g,
		})
	}
	return compiled, nil
}

var (
	rustUnicodeEscape = regexp.MustCompile(`\\u(?:([0-9A-Fa-f]{4})|\{([0-9A-Fa-f]+)\})`)
	rustAlphabetic    = regexp.MustCompile(`\\p\{Alphabetic\}`)
)

// translatePattern maps the Rust regex constructs the recorded manifests use
// onto Go RE2 syntax: \uXXXX / \u{XXXX} code points and the Alphabetic
// property class.
func translatePattern(pattern string) string {
	pattern = rustUnicodeEscape.ReplaceAllString(pattern, `\x{$1$2}`)
	pattern = rustAlphabetic.ReplaceAllString(pattern, `\p{L}`)
	return pattern
}

func compileGate(g gate) (compiledGate, error) {
	out := compiledGate{}
	for _, needle := range g.Contains {
		out.contains = append(out.contains, strings.ToLower(needle))
	}
	for _, pattern := range g.Regex {
		re, err := regexp.Compile(translatePattern(pattern))
		if err != nil {
			return compiledGate{}, fmt.Errorf("regex %q: %w", pattern, err)
		}
		out.regex = append(out.regex, re)
	}
	for _, pattern := range g.LineRegex {
		re, err := regexp.Compile(translatePattern(pattern))
		if err != nil {
			return compiledGate{}, fmt.Errorf("line_regex %q: %w", pattern, err)
		}
		out.lineRegex = append(out.lineRegex, re)
	}
	for _, nested := range g.All {
		compiled, err := compileGate(nested)
		if err != nil {
			return compiledGate{}, err
		}
		out.all = append(out.all, compiled)
	}
	for _, nested := range g.Any {
		compiled, err := compileGate(nested)
		if err != nil {
			return compiledGate{}, err
		}
		out.any = append(out.any, compiled)
	}
	for _, nested := range g.Not {
		compiled, err := compileGate(nested)
		if err != nil {
			return compiledGate{}, err
		}
		out.not = append(out.not, compiled)
	}
	return out, nil
}

// Known reports whether a manifest exists for the agent label or alias.
func Known(label string) bool {
	_, ok := manifestsByLabel[label]
	return ok
}

// Labels returns the canonical manifest ids in sorted order.
func Labels() []string {
	seen := make(map[string]struct{})
	var labels []string
	for _, m := range manifestsByLabel {
		if _, dup := seen[m.label]; dup {
			continue
		}
		seen[m.label] = struct{}{}
		labels = append(labels, m.label)
	}
	sortStrings(labels)
	return labels
}

func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}

// Detect evaluates the labeled agent's rules over the input. The highest
// priority matching rule wins. When no manifest rule matches — including for
// agents without a manifest — generic OSC conventions (spinner-frame titles,
// ConEmu progress states) provide a fallback so unrecognized agents still
// produce useful working/blocked signals.
func Detect(label string, in Input) Detection {
	if m, ok := manifestsByLabel[label]; ok {
		if d, matched := evaluate(m, in); matched {
			return d
		}
	}
	return genericOSCDetection(in)
}

func evaluate(m *compiledManifest, in Input) (Detection, bool) {
	var matched *compiledRule
	for i := range m.rules {
		r := &m.rules[i]
		text, ok := regionText(in, r.region)
		if !ok {
			continue
		}
		if !gateMatches(&r.gate, text, strings.ToLower(text)) {
			continue
		}
		if matched == nil || r.priority > matched.priority {
			matched = r
		}
	}
	if matched == nil {
		return Detection{State: StateUnknown}, false
	}
	return Detection{
		State:           matched.state,
		SkipStateUpdate: matched.skipStateUpdate,
		Rule:            matched.id,
	}, true
}

func gateMatches(g *compiledGate, text, lowerText string) bool {
	for _, needle := range g.contains {
		if !strings.Contains(lowerText, needle) {
			return false
		}
	}
	for _, re := range g.regex {
		if !re.MatchString(text) {
			return false
		}
	}
	for _, re := range g.lineRegex {
		if !anyLineMatches(text, re) {
			return false
		}
	}
	for i := range g.all {
		if !gateMatches(&g.all[i], text, lowerText) {
			return false
		}
	}
	if len(g.any) > 0 {
		ok := false
		for i := range g.any {
			if gateMatches(&g.any[i], text, lowerText) {
				ok = true
				break
			}
		}
		if !ok {
			return false
		}
	}
	for i := range g.not {
		if gateMatches(&g.not[i], text, lowerText) {
			return false
		}
	}
	return true
}

func anyLineMatches(text string, re *regexp.Regexp) bool {
	for line := range strings.Lines(text) {
		if re.MatchString(strings.TrimSuffix(line, "\n")) {
			return true
		}
	}
	return false
}

// genericOSCDetection covers the conventions shared by most terminal agents:
// a braille spinner frame in the title or a busy ConEmu-style progress
// report means working. Anything less explicit stays unknown rather than
// guessing.
func genericOSCDetection(in Input) Detection {
	if titleHasSpinnerFrame(in.OSCTitle) {
		return Detection{State: StateWorking, Rule: "generic_title_spinner"}
	}
	switch progressState(in.OSCProgress) {
	case 1, 3:
		return Detection{State: StateWorking, Rule: "generic_progress_busy"}
	}
	return Detection{State: StateUnknown}
}

// progressState parses the state field of a "4;<state>[;value]" payload,
// returning -1 when absent or malformed.
func progressState(payload string) int {
	rest, ok := strings.CutPrefix(payload, "4")
	if !ok {
		return -1
	}
	rest, ok = strings.CutPrefix(rest, ";")
	if !ok {
		if rest == "" {
			return 0 // bare "4" clears progress
		}
		return -1
	}
	stateField, _, _ := strings.Cut(rest, ";")
	switch stateField {
	case "0", "":
		return 0
	case "1":
		return 1
	case "2":
		return 2
	case "3":
		return 3
	case "4":
		return 4
	}
	return -1
}

// titleHasSpinnerFrame reports whether the title contains a standalone
// braille spinner frame (U+2800–U+28FF), the common working animation.
func titleHasSpinnerFrame(title string) bool {
	for _, field := range strings.Fields(title) {
		runes := []rune(field)
		if len(runes) == 1 && runes[0] >= 0x2800 && runes[0] <= 0x28FF {
			return true
		}
	}
	return false
}
