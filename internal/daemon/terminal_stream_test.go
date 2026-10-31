package daemon

// Terminal stream tests read the binary stream the way the app does: each
// view opens GET /terminal with its attach ticket, then rebuilds its terminal
// from the snapshot and the records after it. Screens are compared with the
// daemon's own terminal through the same Ghostty decoder a client uses.

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	libghostty "go.mitchellh.com/libghostty"

	"github.com/Aqothy/maiD/api/wire"
)

// testView is a view attached over RPC whose stream is open and has
// delivered its first snapshot.
type testView struct {
	Terminal       wire.TerminalSummary
	RunID          string
	SnapshotFormat string
	Snapshot       []byte
	// Columns and Rows are the snapshot's grid, decoded as a client does.
	Columns, Rows uint16
	stream        *testStream
}

// testRecord is one record as a client applies it; a snapshot's data parts
// are joined into its data.
type testRecord struct {
	kind     wire.TerminalStreamRecordKind
	snapshot wire.TerminalStreamSnapshot
	// data is output, or a snapshot's data.
	data    []byte
	resized wire.TerminalStreamResized
	exited  wire.TerminalStreamExited
}

// testStream reads one terminal stream into its client. Its fields are
// guarded by the client's mu.
type testStream struct {
	client  *recordingClient
	ws      *websocket.Conn
	records []testRecord
	// pending is a snapshot whose data is still arriving.
	pending *testRecord
	// err is the first protocol violation the reader saw.
	err         error
	closed      bool
	closeStatus websocket.StatusCode
}

func (c *recordingClient) streamURL() string {
	return strings.TrimSuffix(c.url, "/rpc") + wire.TerminalStreamPath
}

// dialStream opens a terminal stream WebSocket without sending a ticket.
func dialStream(t testing.TB, url string, subprotocols ...string) *websocket.Conn {
	t.Helper()
	ws, _, err := websocket.Dial(context.Background(), url, &websocket.DialOptions{Subprotocols: subprotocols})
	if err != nil {
		t.Fatalf("terminal stream dial: %v", err)
	}
	ws.SetReadLimit(-1)
	t.Cleanup(func() { _ = ws.CloseNow() })
	return ws
}

func sendTicket(t testing.TB, ws *websocket.Conn, ticket string) {
	t.Helper()
	raw, err := base64.RawURLEncoding.DecodeString(ticket)
	if err != nil {
		t.Fatalf("ticket %q: %v", ticket, err)
	}
	if err := ws.Write(context.Background(), websocket.MessageBinary, raw); err != nil {
		t.Fatalf("send ticket: %v", err)
	}
}

// openStream opens the stream a ticket names, without reading it yet.
func (c *recordingClient) openStream(t testing.TB, ticket string) *websocket.Conn {
	t.Helper()
	ws := dialStream(t, c.streamURL(), wire.TerminalStreamSubprotocol)
	sendTicket(t, ws, ticket)
	return ws
}

// follow reads ws from here on.
func (c *recordingClient) follow(ws *websocket.Conn) *testStream {
	stream := &testStream{client: c, ws: ws}
	go stream.read()
	return stream
}

// view opens and follows the stream of an attach result, and waits for the
// snapshot it starts with.
func (c *recordingClient) view(t testing.TB, result wire.TerminalAttachResult) testView {
	t.Helper()
	stream := c.follow(c.openStream(t, result.StreamTicket))
	index, first := stream.waitRecord(t, "the stream's snapshot", 0, isSnapshot)
	if index != 0 {
		t.Fatalf("stream began with %d records before its snapshot", index)
	}
	term := decodeSnapshot(t, first.data)
	columns, err := term.Cols()
	if err != nil {
		t.Fatalf("snapshot columns: %v", err)
	}
	rows, err := term.Rows()
	if err != nil {
		t.Fatalf("snapshot rows: %v", err)
	}
	return testView{
		Terminal:       result.Terminal,
		RunID:          first.snapshot.RunID,
		SnapshotFormat: first.snapshot.SnapshotFormat,
		Snapshot:       first.data,
		Columns:        columns,
		Rows:           rows,
		stream:         stream,
	}
}

func (s *testStream) read() {
	c := s.client
	for {
		_, message, err := s.ws.Read(context.Background())
		c.mu.Lock()
		if err != nil {
			s.closed = true
			s.closeStatus = websocket.CloseStatus(err)
			c.signalLocked()
			c.mu.Unlock()
			return
		}
		if err := s.apply(message); err != nil && s.err == nil {
			s.err = err
		}
		c.signalLocked()
		c.mu.Unlock()
	}
}

// apply decodes one message as the app does. The caller holds the client's
// mu.
func (s *testStream) apply(message []byte) error {
	if len(message) == 0 {
		return errors.New("empty record")
	}
	kind, payload := wire.TerminalStreamRecordKind(message[0]), message[1:]
	if s.pending != nil && kind != wire.TerminalRecordSnapshotData && kind != wire.TerminalRecordSnapshot {
		return fmt.Errorf("record %#x inside a snapshot", kind)
	}
	if (kind == wire.TerminalRecordOutput || kind == wire.TerminalRecordSnapshotData) && len(payload) > streamMessageBytes {
		return fmt.Errorf("record %#x payload %d bytes, over 64 KiB", kind, len(payload))
	}
	record := testRecord{kind: kind}
	var err error
	switch kind {
	case wire.TerminalRecordSnapshot:
		err = json.Unmarshal(payload, &record.snapshot)
		record.data = make([]byte, 0, record.snapshot.Size)
		s.pending = &record
	case wire.TerminalRecordSnapshotData:
		if s.pending == nil {
			return errors.New("snapshot data outside a snapshot")
		}
		s.pending.data = append(s.pending.data, payload...)
		if len(s.pending.data) > s.pending.snapshot.Size {
			return errors.New("snapshot data past its size")
		}
	case wire.TerminalRecordOutput:
		record.data = payload
		s.records = append(s.records, record)
		s.client.terminalOutput.Write(payload)
	case wire.TerminalRecordResized:
		err = json.Unmarshal(payload, &record.resized)
		s.records = append(s.records, record)
	case wire.TerminalRecordExited:
		err = json.Unmarshal(payload, &record.exited)
		s.records = append(s.records, record)
	default:
		return fmt.Errorf("unknown record kind %#x", kind)
	}
	if s.pending != nil && len(s.pending.data) == s.pending.snapshot.Size {
		s.records = append(s.records, *s.pending)
		s.pending = nil
	}
	return err
}

// waitRecord waits for the first record at or after from that matches,
// and returns it with its index. match sees each record once, in order.
func (s *testStream) waitRecord(t testing.TB, desc string, from int, match func(testRecord) bool) (int, testRecord) {
	t.Helper()
	found, next := -1, from
	s.client.waitFor(t, desc, func() bool {
		for ; next < len(s.records); next++ {
			if match(s.records[next]) {
				found = next
				return true
			}
		}
		return s.err != nil || s.closed
	})
	s.client.mu.Lock()
	defer s.client.mu.Unlock()
	if s.err != nil {
		t.Fatalf("waiting for %s: %v", desc, s.err)
	}
	if found < 0 {
		t.Fatalf("stream closed (%v) waiting for %s", s.closeStatus, desc)
	}
	return found, s.records[found]
}

// waitOutput waits until the stream's output since record from contains
// marker, and returns the index of the record that completed it.
func (s *testStream) waitOutput(t testing.TB, from int, marker string) int {
	t.Helper()
	// Only the end of the output so far can begin the marker.
	var carry []byte
	index, _ := s.waitRecord(t, "output "+marker, from, func(record testRecord) bool {
		if record.kind != wire.TerminalRecordOutput {
			return false
		}
		window := append(carry, record.data...)
		carry = slices.Clone(window[max(0, len(window)-len(marker)+1):])
		return bytes.Contains(window, []byte(marker))
	})
	return index
}

func (s *testStream) waitClosed(t testing.TB) websocket.StatusCode {
	t.Helper()
	s.client.waitFor(t, "the stream to close", func() bool { return s.closed })
	s.client.mu.Lock()
	defer s.client.mu.Unlock()
	if s.err != nil {
		t.Fatalf("stream: %v", s.err)
	}
	return s.closeStatus
}

func (s *testStream) snapshot() []testRecord {
	s.client.mu.Lock()
	defer s.client.mu.Unlock()
	return slices.Clone(s.records)
}

func isSnapshot(record testRecord) bool { return record.kind == wire.TerminalRecordSnapshot }

// screen rebuilds the terminal from the stream's latest snapshot and the
// records after it, as the app does, and returns its text with scrollback.
func (s *testStream) screen(t testing.TB) string {
	t.Helper()
	records := s.snapshot()
	last := len(records) - 1
	for last >= 0 && !isSnapshot(records[last]) {
		last--
	}
	if last < 0 {
		t.Fatal("stream has no snapshot")
	}
	term := decodeSnapshot(t, records[last].data)
	for _, record := range records[last+1:] {
		switch record.kind {
		case wire.TerminalRecordOutput:
			_, _ = term.Write(record.data)
		case wire.TerminalRecordResized:
			if err := term.Resize(record.resized.Columns, record.resized.Rows, 8, 16); err != nil {
				t.Fatalf("resize: %v", err)
			}
		}
	}
	return terminalText(t, term)
}

// sessionScreen is the daemon's own terminal for terminalID, as text.
func sessionScreen(t testing.TB, s *Server, terminalID string) string {
	t.Helper()
	session, err := s.terminals.service.Get(terminalID)
	if err != nil {
		t.Fatalf("session: %v", err)
	}
	snapshot, err := session.Snapshot()
	if err != nil {
		t.Fatalf("session snapshot: %v", err)
	}
	return terminalText(t, decodeSnapshot(t, snapshot.Data))
}

func decodeSnapshot(t testing.TB, data []byte) *libghostty.Terminal {
	t.Helper()
	decoder, err := libghostty.NewSnapshotDecoderBytes(data)
	if err != nil {
		t.Fatalf("snapshot decoder: %v", err)
	}
	defer decoder.Close()
	if err := decoder.SetMaxContinuationBytes(64 * 1024); err != nil {
		t.Fatalf("snapshot decoder limit: %v", err)
	}
	term, err := decoder.Decode()
	if err != nil {
		t.Fatalf("decode snapshot: %v", err)
	}
	t.Cleanup(term.Close)
	return term
}

func terminalText(t testing.TB, term *libghostty.Terminal) string {
	t.Helper()
	formatter, err := libghostty.NewFormatter(term,
		libghostty.WithFormatterFormat(libghostty.FormatterFormatPlain),
		libghostty.WithFormatterTrim(true),
	)
	if err != nil {
		t.Fatalf("formatter: %v", err)
	}
	defer formatter.Close()
	text, err := formatter.FormatString()
	if err != nil {
		t.Fatalf("format: %v", err)
	}
	return text
}

// A view that attaches while the program prints gets everything: its
// snapshot holds what came before, and the records after it hold the rest,
// none twice.
func TestTerminalStreamContinuesItsSnapshotWithoutGapOrDuplicate(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	first := dialRecordingClient(t, url)
	created := createTestTerminal(t, first)
	terminalID := created.Terminal.TerminalID
	first.writeTerminal(t, terminalID, created.RunID, "printf 'HISTORY-%d\\n' $((80+8)); "+
		"perl -e '$|=1; for (1..4000) { print \"LINE-$_\\n\"; select(undef, undef, undef, 0.0005) }'; "+
		"printf 'DONE-%d\\n' $((1+1)); exec sleep 600\n")
	created.stream.waitOutput(t, 1, "LINE-400")

	second := dialRecordingClient(t, url).mustAttachTerminal(t, terminalID, 80, 24)
	if !containsBytes(second.Snapshot, "HISTORY-88") {
		t.Fatal("snapshot lacks the output from before the attach")
	}
	second.stream.waitOutput(t, 1, "DONE-2")
	if got, want := second.stream.screen(t), sessionScreen(t, s, terminalID); got != want {
		t.Fatalf("view's terminal differs from the daemon's:\n got %q\nwant %q", tail(got), tail(want))
	}
}

// A view that stops reading falls behind alone: the program, the control
// connection and other views carry on, and once it reads again it jumps to
// the current screen from a fresh snapshot.
func TestTerminalSlowStreamResyncsWithoutHoldingAnyoneBack(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	defer s.Close()
	url := newWSTestServer(t, s)
	slow := dialRecordingClient(t, url)
	var result wire.TerminalAttachResult
	slow.call(t, wire.MethodTerminalCreate, wire.TerminalCreateParams{
		Cwd: t.TempDir(), Columns: 80, Rows: 24, Appearance: testAppearance,
	}, &result)
	terminalID := result.Terminal.TerminalID
	stalled := slow.openStream(t, result.StreamTicket)
	healthy := dialRecordingClient(t, url)
	view := healthy.mustAttachTerminal(t, terminalID, 80, 24)

	const flood = 64 << 20
	healthy.writeTerminal(t, terminalID, view.RunID, fmt.Sprintf(
		"head -c %d /dev/zero; seq -f 'ROW-%%g' 1 60; printf 'FLOOD-%%d\\n' $((6*7)); exec sleep 600\n", flood))
	view.stream.waitOutput(t, 1, "FLOOD-42")
	var summary wire.TerminalListStreamItem
	slow.call(t, wire.MethodTerminalSubscribeList, nil, &summary)

	stream := slow.follow(stalled)
	stream.waitOutput(t, 0, "FLOOD-42")
	records := stream.snapshot()
	if !isSnapshot(records[0]) {
		t.Fatalf("stream began with record %#x", records[0].kind)
	}
	resync := slices.IndexFunc(records[1:], isSnapshot)
	if resync < 0 {
		t.Fatalf("the stalled view never resynced; it got %d records", len(records))
	}
	if records[resync+1].snapshot.RunID != view.RunID {
		t.Fatalf("resync snapshot run = %s, want %s", records[resync+1].snapshot.RunID, view.RunID)
	}
	if got, want := stream.screen(t), sessionScreen(t, s, terminalID); got != want {
		t.Fatalf("resynced terminal differs from the daemon's:\n got %q\nwant %q", tail(got), tail(want))
	}
}

// A stream opens only with a fresh ticket from a live view, over the
// subprotocol, and the ticket comes first. Every refusal closes before
// anything streams.
func TestTerminalStreamHandshakeRefusals(t *testing.T) {
	useQuietTestShell(t)
	s := newTestServer(t)
	url := newWSTestServer(t, s)

	attach := func(t *testing.T, c *recordingClient) wire.TerminalAttachResult {
		t.Helper()
		var result wire.TerminalAttachResult
		c.call(t, wire.MethodTerminalCreate, wire.TerminalCreateParams{
			Cwd: t.TempDir(), Columns: 80, Rows: 24, Appearance: testAppearance,
		}, &result)
		return result
	}
	for _, tc := range []struct {
		name string
		want websocket.StatusCode
		open func(t *testing.T) *websocket.Conn
	}{
		{"reused ticket", websocket.StatusPolicyViolation, func(t *testing.T) *websocket.Conn {
			c := dialRecordingClient(t, url)
			result := attach(t, c)
			c.view(t, result)
			return c.openStream(t, result.StreamTicket)
		}},
		{"expired ticket", websocket.StatusPolicyViolation, func(t *testing.T) *websocket.Conn {
			c := dialRecordingClient(t, url)
			result := attach(t, c)
			entry := s.terminals.entry(result.Terminal.TerminalID)
			entry.views.mu.Lock()
			entry.views.list[0].ticket.expires = time.Now()
			entry.views.mu.Unlock()
			return c.openStream(t, result.StreamTicket)
		}},
		{"closed connection's ticket", websocket.StatusPolicyViolation, func(t *testing.T) *websocket.Conn {
			c := dialRecordingClient(t, url)
			result := attach(t, c)
			_ = c.conn.Close()
			waitUntil(t, "the daemon to drop the connection's view", func() bool {
				return !s.terminals.entry(result.Terminal.TerminalID).views.holdsTicket(ticketBytes(t, result.StreamTicket))
			})
			return c.openStream(t, result.StreamTicket)
		}},
		{"missing subprotocol", websocket.StatusProtocolError, func(t *testing.T) *websocket.Conn {
			c := dialRecordingClient(t, url)
			result := attach(t, c)
			ws := dialStream(t, c.streamURL())
			sendTicket(t, ws, result.StreamTicket)
			return ws
		}},
		{"no ticket", websocket.StatusPolicyViolation, func(t *testing.T) *websocket.Conn {
			return dialStream(t, dialRecordingClient(t, url).streamURL(), wire.TerminalStreamSubprotocol)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			_, message, err := tc.open(t).Read(context.Background())
			if err == nil {
				t.Fatalf("stream sent a %d-byte record", len(message))
			}
			if got := websocket.CloseStatus(err); got != tc.want {
				t.Fatalf("closed with %v (%v), want %v", got, err, tc.want)
			}
		})
	}
}

func ticketBytes(t testing.TB, ticket string) [16]byte {
	t.Helper()
	raw, err := base64.RawURLEncoding.DecodeString(ticket)
	if err != nil || len(raw) != 16 {
		t.Fatalf("ticket %q: %v", ticket, err)
	}
	return [16]byte(raw)
}

// tail keeps a failure message to the end of a long screen.
func tail(text string) string {
	const keep = 2000
	if len(text) > keep {
		return "…" + text[len(text)-keep:]
	}
	return text
}
