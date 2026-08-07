package agentrules

import (
	"strconv"
	"strings"
)

func supportedRegion(spec string) bool {
	switch spec {
	case "osc_title", "osc_progress", "whole_recent", "after_last_prompt_marker", "prompt_box_body", "after_last_horizontal_rule":
		return true
	}
	for _, name := range []string{"bottom_non_empty_lines", "bottom_lines", "top_non_empty_lines"} {
		if _, ok := regionCount(spec, name); ok {
			return true
		}
	}
	return false
}

// regionText resolves a manifest region spec against the input. The second
// result is false when the region's source is unavailable, which lets the
// engine skip screen rules entirely while no screen text exists instead of
// matching them against an empty screen. Region semantics follow the Herdr
// engine the manifests were written for.
func regionText(in Input, spec string) (string, bool) {
	switch spec {
	case "osc_title":
		return in.OSCTitle, in.OSCTitle != ""
	case "osc_progress":
		return in.OSCProgress, in.OSCProgress != ""
	}
	if in.Screen == "" {
		return "", false
	}
	content := in.Screen
	switch spec {
	case "whole_recent":
		return content, true
	case "after_last_prompt_marker":
		return afterLastPromptMarker(content), true
	case "prompt_box_body":
		return promptBoxBody(content), true
	case "after_last_horizontal_rule":
		return afterLastHorizontalRule(content), true
	}
	if n, ok := regionCount(spec, "bottom_non_empty_lines"); ok {
		return bottomNonEmptyLines(content, n), true
	}
	if n, ok := regionCount(spec, "bottom_lines"); ok {
		return bottomLines(content, n), true
	}
	if n, ok := regionCount(spec, "top_non_empty_lines"); ok {
		return topNonEmptyLines(content, n), true
	}
	// Unknown regions match nothing; a newer manifest region name must not
	// break older engines.
	return "", false
}

func regionCount(spec, name string) (int, bool) {
	rest, ok := strings.CutPrefix(spec, name)
	if !ok {
		return 0, false
	}
	rest, ok = strings.CutPrefix(rest, "(")
	if !ok {
		return 0, false
	}
	rest, ok = strings.CutSuffix(rest, ")")
	if !ok {
		return 0, false
	}
	n, err := strconv.Atoi(rest)
	if err != nil || n <= 0 {
		return 0, false
	}
	return n, true
}

// splitLines mirrors Rust's str::lines: split on '\n' without a trailing
// empty element for a final newline.
func splitLines(content string) []string {
	lines := strings.Split(content, "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	return lines
}

func lineStartOffset(content string, lines []string, index int) int {
	if index > len(lines) {
		index = len(lines)
	}
	offset := 0
	for _, line := range lines[:index] {
		offset += len(line) + 1
	}
	if offset > len(content) {
		offset = len(content)
	}
	return offset
}

func sliceFromLineIndex(content string, lines []string, index int) string {
	return content[lineStartOffset(content, lines, index):]
}

func bottomLines(content string, count int) string {
	lines := splitLines(content)
	start := len(lines) - count
	if start < 0 {
		start = 0
	}
	return sliceFromLineIndex(content, lines, start)
}

func bottomNonEmptyLines(content string, count int) string {
	lines := splitLines(content)
	seen := 0
	for i := len(lines) - 1; i >= 0; i-- {
		if strings.TrimSpace(lines[i]) == "" {
			continue
		}
		seen++
		if seen == count {
			return sliceFromLineIndex(content, lines, i)
		}
	}
	// Fewer non-empty lines than requested: everything from the first
	// non-empty line on.
	for i, line := range lines {
		if strings.TrimSpace(line) != "" {
			return sliceFromLineIndex(content, lines, i)
		}
	}
	return ""
}

func topNonEmptyLines(content string, count int) string {
	lines := splitLines(content)
	seen := 0
	for i, line := range lines {
		if strings.TrimSpace(line) == "" {
			continue
		}
		seen++
		if seen == count {
			return content[:lineStartOffset(content, lines, i+1)]
		}
	}
	if seen > 0 {
		return content
	}
	return ""
}

// afterLastPromptMarker returns everything below the Codex-style "›" prompt
// line, or the whole content when no prompt line exists.
func afterLastPromptMarker(content string) string {
	lines := splitLines(content)
	for i := len(lines) - 1; i >= 0; i-- {
		if codexPromptLine(lines[i]) {
			return sliceFromLineIndex(content, lines, i+1)
		}
	}
	return content
}

func codexPromptLine(line string) bool {
	return line == "›" || strings.HasPrefix(line, "› ")
}

// promptBoxBody returns the text inside the bottom bordered prompt box: the
// lines between the second horizontal rule from the bottom and the next rule
// below it. Empty when no box is on screen.
func promptBoxBody(content string) string {
	lines := splitLines(content)
	top, ok := promptBoxTopBorderIndex(lines)
	if !ok {
		return ""
	}
	start := lineStartOffset(content, lines, top+1)
	end := len(content)
	for i := top + 1; i < len(lines); i++ {
		if isHorizontalRule(lines[i]) {
			end = lineStartOffset(content, lines, i)
			break
		}
	}
	if start > end {
		start = end
	}
	return content[start:end]
}

func promptBoxTopBorderIndex(lines []string) (int, bool) {
	borders := 0
	for i := len(lines) - 1; i >= 0; i-- {
		if isHorizontalRule(lines[i]) {
			borders++
			if borders == 2 {
				return i, true
			}
		}
	}
	return 0, false
}

func afterLastHorizontalRule(content string) string {
	lines := splitLines(content)
	for i := len(lines) - 1; i >= 0; i-- {
		if isHorizontalRule(lines[i]) {
			return sliceFromLineIndex(content, lines, i+1)
		}
	}
	return content
}

// isHorizontalRule matches box-drawing rule lines: a run of '─' either alone
// on the line or at least three long with trailing decoration.
func isHorizontalRule(line string) bool {
	trimmed := strings.TrimSpace(line)
	if trimmed == "" {
		return false
	}
	runes := []rune(trimmed)
	ruleRunes := 0
	for _, r := range runes {
		if r != '─' {
			break
		}
		ruleRunes++
	}
	if ruleRunes == 0 {
		return false
	}
	suffix := strings.TrimSpace(string(runes[ruleRunes:]))
	return suffix == "" || ruleRunes >= 3
}
