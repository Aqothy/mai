package vtscreen

import (
	"fmt"
	"runtime"
	"strings"
	"testing"
)

func newTestScreen(t *testing.T) Screen {
	t.Helper()
	s, err := New(80, 24)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(s.Close)
	return s
}

func text(t *testing.T, s Screen) string {
	t.Helper()
	out, err := s.Text()
	if err != nil {
		t.Fatalf("Text: %v", err)
	}
	return out
}

// The screen must reflect terminal semantics, not raw byte order: carriage
// returns overwrite, clear-screen discards, and the alternate screen
// replaces the primary content while active.
func TestScreenFollowsCarriageReturnOverwrite(t *testing.T) {
	s := newTestScreen(t)
	s.Feed([]byte("progress 10%\rprogress 99%"))
	got := text(t, s)
	if !strings.Contains(got, "progress 99%") {
		t.Fatalf("screen missing final text: %q", got)
	}
	if strings.Contains(got, "10%") {
		t.Fatalf("screen kept overwritten text: %q", got)
	}
}

func TestScreenFollowsClearScreen(t *testing.T) {
	s := newTestScreen(t)
	s.Feed([]byte("old transcript line\r\n\x1b[2J\x1b[Hfresh prompt"))
	got := text(t, s)
	if strings.Contains(got, "old transcript") {
		t.Fatalf("clear-screen kept stale text: %q", got)
	}
	if !strings.Contains(got, "fresh prompt") {
		t.Fatalf("screen missing current text: %q", got)
	}
}

func TestScreenFollowsAlternateScreen(t *testing.T) {
	s := newTestScreen(t)
	s.Feed([]byte("shell scrollback\r\n"))
	s.Feed([]byte("\x1b[?1049h\x1b[2J\x1b[Halt screen app"))
	got := text(t, s)
	if !strings.Contains(got, "alt screen app") || strings.Contains(got, "shell scrollback") {
		t.Fatalf("alternate screen not reflected: %q", got)
	}
	s.Feed([]byte("\x1b[?1049l"))
	got = text(t, s)
	if !strings.Contains(got, "shell scrollback") {
		t.Fatalf("primary screen not restored: %q", got)
	}
}

func TestScreenResizeKeepsFormatting(t *testing.T) {
	s := newTestScreen(t)
	s.Feed([]byte("before resize\r\n"))
	s.Resize(120, 40)
	s.Feed([]byte("after resize"))
	got := text(t, s)
	if !strings.Contains(got, "after resize") {
		t.Fatalf("screen lost content across resize: %q", got)
	}
}

// Benchmark gate: 25 headless detector screens fed continuous output with
// formatting at the debounced cadence. Run with:
//
//	make ghostty-vt && PKG_CONFIG_PATH=build/ghostty-vt/_deps/ghostty-src/zig-out/share/pkgconfig \
//	  go test -tags ghostty_vt -bench BenchmarkHeadlessScreens -benchmem ./internal/terminal/vtscreen/
//
// Recorded results live in docs/TERMINAL_AGENT_DETECTION.md.
func BenchmarkHeadlessScreens25(b *testing.B) {
	const screens = 25
	var pool []Screen
	var before runtime.MemStats
	runtime.GC()
	runtime.ReadMemStats(&before)
	for range screens {
		s, err := New(80, 24)
		if err != nil {
			b.Fatalf("New: %v", err)
		}
		defer s.Close()
		pool = append(pool, s)
	}

	// One chunk approximates a busy agent redraw: styled lines, cursor
	// movement, and a status footer.
	var chunk strings.Builder
	for i := range 24 {
		fmt.Fprintf(&chunk, "\x1b[%d;1H\x1b[K\x1b[38;5;110mline %02d \x1b[1mstyled\x1b[0m content with some text\r\n", i+1, i)
	}
	chunk.WriteString("\x1b[24;1H• Working (12s • esc to interrupt)")
	data := []byte(chunk.String())

	b.ResetTimer()
	for i := 0; b.Loop(); i++ {
		s := pool[i%screens]
		s.Feed(data)
		// The debounce allows at most one format per ~2 feeds of
		// continuous output at this chunk cadence.
		if i%2 == 0 {
			if _, err := s.Text(); err != nil {
				b.Fatalf("Text: %v", err)
			}
		}
	}
	b.StopTimer()

	var after runtime.MemStats
	runtime.GC()
	runtime.ReadMemStats(&after)
	// Native VT memory lives outside the Go heap, so this is a floor, not a
	// ceiling; the recorded budget uses process RSS from the benchmark run.
	b.ReportMetric(float64(after.HeapAlloc-before.HeapAlloc)/float64(screens), "heapB/screen")
}
