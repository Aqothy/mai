package vtscreen

import (
	"bytes"
	"fmt"
	"strings"
	"testing"
	"time"

	libghostty "go.mitchellh.com/libghostty"
)

const testScrollback = 256 * 1024

func newSnapshotScreen(t *testing.T, columns, rows uint16) SnapshotScreen {
	t.Helper()
	s, err := NewSnapshot(columns, rows, testScrollback)
	if err != nil {
		t.Fatalf("NewSnapshot: %v", err)
	}
	t.Cleanup(s.Close)
	return s
}

// roundTrip exports the source's native model and decodes it exactly as a
// compatible Ghostty client would before installing it into a surface.
func roundTrip(t *testing.T, source SnapshotScreen) SnapshotScreen {
	t.Helper()
	snapshot, err := source.Snapshot()
	if err != nil {
		t.Fatalf("Snapshot: %v", err)
	}
	if !bytes.HasPrefix(snapshot, []byte("GHOSTSNP")) {
		t.Fatalf("snapshot has invalid envelope prefix: %q", snapshot[:min(len(snapshot), 8)])
	}
	decoder, err := libghostty.NewSnapshotDecoderBytes(snapshot)
	if err != nil {
		t.Fatalf("NewSnapshotDecoderBytes: %v", err)
	}
	defer decoder.Close()
	if err := decoder.SetMaxContinuationBytes(attachContinuationMaxBytes); err != nil {
		t.Fatalf("SetMaxContinuationBytes: %v", err)
	}
	term, err := decoder.Decode()
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	formatter, err := libghostty.NewFormatter(term,
		libghostty.WithFormatterFormat(libghostty.FormatterFormatPlain),
		libghostty.WithFormatterTrim(true),
	)
	if err != nil {
		term.Close()
		t.Fatalf("NewFormatter: %v", err)
	}
	fresh := &ghosttyScreen{term: term, formatter: formatter}
	t.Cleanup(fresh.Close)
	return fresh
}

func mustText(t *testing.T, s Screen) string {
	t.Helper()
	out, err := s.Text()
	if err != nil {
		t.Fatalf("Text: %v", err)
	}
	return out
}

func mustCursor(t *testing.T, s SnapshotScreen) (uint16, uint16) {
	t.Helper()
	ghostty, ok := s.(*ghosttyScreen)
	if !ok {
		t.Fatalf("unexpected snapshot screen type %T", s)
	}
	x, err := ghostty.term.CursorX()
	if err != nil {
		t.Fatalf("CursorX: %v", err)
	}
	y, err := ghostty.term.CursorY()
	if err != nil {
		t.Fatalf("CursorY: %v", err)
	}
	return x, y
}

func TestNativeSnapshotReproducesScreenAtSameGrid(t *testing.T) {
	source := newSnapshotScreen(t, 80, 24)
	source.Feed([]byte("plain line\r\n\x1b[1;32mstyled line\x1b[0m\r\nprompt with cursor here: "))

	fresh := roundTrip(t, source)
	if got, want := mustText(t, fresh), mustText(t, source); got != want {
		t.Fatalf("round-trip text mismatch:\n got %q\nwant %q", got, want)
	}
}

func TestNativeSnapshotReproducesScreenAfterResize(t *testing.T) {
	source := newSnapshotScreen(t, 80, 24)
	for i := range 30 {
		source.Feed(fmt.Appendf(nil, "history line %02d\r\n", i))
	}
	source.Feed([]byte("shell$ "))

	if err := source.Resize(120, 40); err != nil {
		t.Fatalf("Resize: %v", err)
	}
	fresh := roundTrip(t, source)
	got, want := mustText(t, fresh), mustText(t, source)
	if got != want {
		t.Fatalf("resized round-trip mismatch:\n got %q\nwant %q", got, want)
	}
	if !strings.HasSuffix(strings.TrimRight(got, "\n"), "shell$") {
		t.Fatalf("prompt not at expected position: %q", got)
	}
}

func TestNativeSnapshotReproducesZshStartupPromptAndCursor(t *testing.T) {
	source := newSnapshotScreen(t, 39, 35)
	source.Feed([]byte("%                                     \r \r\r\x1b[32m➜\x1b[39m \x1b[36m~\x1b[39m \x1b[?2004h"))

	fresh := roundTrip(t, source)
	if got, want := mustText(t, fresh), mustText(t, source); got != want {
		t.Fatalf("zsh startup round-trip mismatch:\n got %q\nwant %q", got, want)
	} else if strings.Contains(got, "%") {
		t.Fatalf("erased zsh partial-line marker was restored: %q", got)
	}
	gotX, gotY := mustCursor(t, fresh)
	wantX, wantY := mustCursor(t, source)
	if gotX != wantX || gotY != wantY {
		t.Fatalf("cursor mismatch: got (%d,%d), want (%d,%d)", gotX, gotY, wantX, wantY)
	}
}

func TestNativeSnapshotPreservesSplitVTSequence(t *testing.T) {
	source := newSnapshotScreen(t, 80, 24)
	source.Feed([]byte("content that the pending sequence will clear"))
	source.Feed([]byte("\x1b[2"))

	receiver := roundTrip(t, source)
	suffix := []byte("J")
	source.Feed(suffix)
	receiver.Feed(suffix)
	if got, want := mustText(t, receiver), mustText(t, source); got != want {
		t.Fatalf("split-sequence state diverged:\n got %q\nwant %q", got, want)
	}
}

func TestNativeSnapshotReproducesAlternateScreenApp(t *testing.T) {
	source := newSnapshotScreen(t, 80, 24)
	source.Feed([]byte("shell history\r\n"))
	source.Feed([]byte("\x1b[?1049h\x1b[2J\x1b[H\x1b[3;5HEDITOR BODY\x1b[24;1H-- INSERT --"))

	fresh := roundTrip(t, source)
	got := mustText(t, fresh)
	if !strings.Contains(got, "EDITOR BODY") || !strings.Contains(got, "-- INSERT --") {
		t.Fatalf("alternate screen content missing: %q", got)
	}
	if strings.Contains(got, "shell history") {
		t.Fatalf("primary screen leaked into alternate-screen attach: %q", got)
	}
}

func TestNativeSnapshotCarriesTerminalModes(t *testing.T) {
	source := newSnapshotScreen(t, 80, 24)
	source.Feed([]byte("\x1b[?2004h\x1b[?2048hshell$ "))

	fresh := roundTrip(t, source)
	ghostty := fresh.(*ghosttyScreen)
	for name, mode := range map[string]libghostty.Mode{
		"bracketed paste": libghostty.ModeBracketedPaste,
		"in-band resize":  libghostty.ModeInBandResize,
	} {
		enabled, err := ghostty.term.ModeGet(mode)
		if err != nil {
			t.Fatalf("ModeGet(%s): %v", name, err)
		}
		if !enabled {
			t.Fatalf("snapshot did not preserve %s mode", name)
		}
	}
}

func TestNativeSnapshotRejectsCorruption(t *testing.T) {
	source := newSnapshotScreen(t, 80, 24)
	source.Feed([]byte("authenticated state\r\nshell$ "))
	snapshot, err := source.Snapshot()
	if err != nil {
		t.Fatalf("Snapshot: %v", err)
	}
	snapshot[len(snapshot)-1] ^= 0xff

	decoder, err := libghostty.NewSnapshotDecoderBytes(snapshot)
	if err != nil {
		t.Fatalf("NewSnapshotDecoderBytes: %v", err)
	}
	defer decoder.Close()
	if _, err := decoder.Decode(); err == nil {
		t.Fatal("corrupted snapshot unexpectedly decoded")
	}
}

func TestNativeSnapshotStaysWithinBudget(t *testing.T) {
	source := newSnapshotScreen(t, 80, 24)
	for i := range 2000 {
		source.Feed(fmt.Appendf(nil, "\x1b[38;5;%dmline %04d with styled content and text\x1b[0m\r\n", i%256, i))
	}

	start := time.Now()
	snapshot, err := source.Snapshot()
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("Snapshot: %v", err)
	}
	t.Logf("native snapshot: %d bytes in %s", len(snapshot), elapsed)
	if len(snapshot) > 3*1024*1024 {
		t.Fatalf("snapshot size %d exceeds budget", len(snapshot))
	}
	if elapsed > 200*time.Millisecond {
		t.Fatalf("snapshot took %s, over budget", elapsed)
	}
}
