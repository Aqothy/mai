package vtscreen

import (
	"fmt"
	"runtime"
	"strings"
	"testing"
)

// Benchmark gate: 25 headless detector screens fed continuous output with
// formatting at the debounced cadence. Run with:
//
//	make ghostty-vt && PKG_CONFIG_PATH=build/ghostty-vt/_deps/ghostty-src/zig-out/share/pkgconfig \
//	  go test -bench BenchmarkHeadlessScreens -benchmem ./internal/terminal/vtscreen/
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
	// ceiling.
	b.ReportMetric(float64(after.HeapAlloc-before.HeapAlloc)/float64(screens), "heapB/screen")
}
