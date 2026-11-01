// Package unifieddiff writes the unified-diff hunks adapters put in
// provider.FileChange.Diff, so clients only ever parse one diff format.
// Hunks carry no file headers: the change's path and kind name the file.
package unifieddiff

import (
	"fmt"
	"strings"
)

// WholeFile is the hunk that adds content as a new file, or deletes it when
// added is false.
func WholeFile(content string, added bool) string {
	if content == "" {
		return ""
	}
	lines := strings.Split(strings.TrimSuffix(content, "\n"), "\n")
	sign, header := "+", fmt.Sprintf("@@ -0,0 +1,%d @@", len(lines))
	if !added {
		sign, header = "-", fmt.Sprintf("@@ -1,%d +0,0 @@", len(lines))
	}
	var builder strings.Builder
	builder.WriteString(header)
	for _, line := range lines {
		builder.WriteString("\n" + sign + line)
	}
	if !strings.HasSuffix(content, "\n") {
		builder.WriteString("\n\\ No newline at end of file")
	}
	return builder.String() + "\n"
}

// Hunk is one hunk whose lines already carry their ' ', '+' or '-' prefix.
func Hunk(oldStart, oldLines, newStart, newLines int, lines []string) string {
	return fmt.Sprintf("@@ -%d,%d +%d,%d @@\n", oldStart, oldLines, newStart, newLines) + strings.Join(lines, "\n") + "\n"
}
