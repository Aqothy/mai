package terminal

import (
	"strings"
	"testing"
)

func scanAll(t *testing.T, chunks ...[]byte) (titles []string, progress []string) {
	t.Helper()
	var tracker oscTracker
	for _, chunk := range chunks {
		tracker.scan(chunk,
			func(title string) { titles = append(titles, title) },
			func(payload string) { progress = append(progress, payload) },
		)
	}
	return titles, progress
}

func TestOSCTrackerTitleTerminators(t *testing.T) {
	titles, _ := scanAll(t, []byte("\x1b]0;hello\x07plain\x1b]2;world\x1b\\"))
	if len(titles) != 2 || titles[0] != "hello" || titles[1] != "world" {
		t.Fatalf("titles = %v", titles)
	}
}

func TestOSCTrackerProgress(t *testing.T) {
	_, progress := scanAll(t, []byte("\x1b]9;4;1;42\x07\x1b]9;4;0\x1b\\\x1b]9;something else\x07"))
	if len(progress) != 2 || progress[0] != "4;1;42" || progress[1] != "4;0" {
		t.Fatalf("progress = %v", progress)
	}
}

func TestOSCTrackerFragmentedAcrossChunks(t *testing.T) {
	titles, progress := scanAll(t,
		[]byte("output \x1b"),
		[]byte("]0;split ti"),
		[]byte("tle\x07more\x1b]9;4"),
		[]byte(";3;\x1b"),
		[]byte("\\tail"),
	)
	if len(titles) != 1 || titles[0] != "split title" {
		t.Fatalf("titles = %v", titles)
	}
	if len(progress) != 1 || progress[0] != "4;3;" {
		t.Fatalf("progress = %v", progress)
	}
}

func TestOSCTrackerBoundsPayload(t *testing.T) {
	huge := "\x1b]0;" + strings.Repeat("x", 10_000) + "\x07"
	titles, _ := scanAll(t, []byte(huge))
	if len(titles) != 1 {
		t.Fatalf("titles = %d", len(titles))
	}
	if len(titles[0]) > oscPayloadCap {
		t.Fatalf("payload not bounded: %d bytes", len(titles[0]))
	}
	// The tracker recovers cleanly after an overlong sequence.
	titles, _ = scanAll(t, []byte(huge+"\x1b]0;next\x07"))
	if len(titles) != 2 || titles[1] != "next" {
		t.Fatalf("recovery titles = %v", titles)
	}
}

func TestOSCTrackerCancelledSequence(t *testing.T) {
	// A bare ESC inside an OSC aborts it; the following CSI must not emit
	// anything and the stream stays in sync for the next real title.
	titles, _ := scanAll(t, []byte("\x1b]0;dropped\x1b[31mred\x1b]2;kept\x07"))
	if len(titles) != 1 || titles[0] != "kept" {
		t.Fatalf("titles = %v", titles)
	}
}

func TestOSCTrackerIgnoresOtherSequences(t *testing.T) {
	titles, progress := scanAll(t, []byte("\x1b[1;32mgreen\x1b[0m\x1b]8;;https://x\x07link\x1b]133;A\x07"))
	if len(titles) != 0 || len(progress) != 0 {
		t.Fatalf("unexpected events: %v %v", titles, progress)
	}
}
