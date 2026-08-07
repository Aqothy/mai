package terminal

import (
	"strings"
)

// oscTracker is a small bounded streaming scanner for the two OSC sequences
// agent detection uses: OSC 0/2 (terminal title) and OSC 9;4 (progress).
// It tolerates sequences split anywhere across PTY read chunks and never
// retains more than oscPayloadCap bytes of an in-flight sequence. It is a
// byte scanner, not a terminal screen; screen-accurate evidence is the
// detector VT's job.
type oscTracker struct {
	state       oscScanState
	payload     []byte
	overflowing bool
}

type oscScanState uint8

const (
	oscScanGround  oscScanState = iota
	oscScanEsc                  // saw ESC
	oscScanBody                 // inside ESC ] ... collecting payload
	oscScanBodyEsc              // inside OSC, saw ESC (possible ST terminator)
)

// oscPayloadCap bounds one in-flight OSC payload. Raw titles are capped at
// 256 scalars anyway; anything longer is kept up to the cap and the
// remainder discarded until the terminator.
const oscPayloadCap = 512

// scan feeds one output chunk and invokes the callbacks for each complete
// sequence of interest. onProgress receives the raw payload after the
// leading "9;", for example "4;0" or "4;1;42".
func (t *oscTracker) scan(data []byte, onTitle func(title string), onProgress func(payload string)) {
	for i := 0; i < len(data); i++ {
		b := data[i]
		switch t.state {
		case oscScanGround:
			if b == 0x1b {
				t.state = oscScanEsc
			}
		case oscScanEsc:
			switch b {
			case ']':
				t.state = oscScanBody
				t.payload = t.payload[:0]
				t.overflowing = false
			case 0x1b:
				// stay: ESC ESC ] still starts an OSC
			default:
				t.state = oscScanGround
			}
		case oscScanBody:
			switch b {
			case 0x07: // BEL terminator
				t.emit(onTitle, onProgress)
				t.state = oscScanGround
			case 0x1b:
				t.state = oscScanBodyEsc
			default:
				t.collect(b)
			}
		case oscScanBodyEsc:
			if b == '\\' { // ST terminator
				t.emit(onTitle, onProgress)
				t.state = oscScanGround
				break
			}
			// A bare ESC inside an OSC cancels it; reprocess this byte as a
			// fresh escape introducer so following sequences stay in sync.
			t.state = oscScanEsc
			i--
		}
	}
}

func (t *oscTracker) collect(b byte) {
	if t.overflowing {
		return
	}
	if len(t.payload) >= oscPayloadCap {
		t.overflowing = true
		return
	}
	t.payload = append(t.payload, b)
}

// emit parses one complete OSC payload of the form "Ps;data".
func (t *oscTracker) emit(onTitle func(string), onProgress func(string)) {
	payload := string(t.payload)
	code, rest, hasBody := strings.Cut(payload, ";")
	if !hasBody {
		return
	}
	switch code {
	case "0", "2":
		onTitle(rest)
	case "9":
		// OSC 9;4;... is the ConEmu progress report; other OSC 9 payloads
		// are desktop notifications and are ignored here.
		if rest == "4" || strings.HasPrefix(rest, "4;") {
			onProgress(rest)
		}
	}
}
