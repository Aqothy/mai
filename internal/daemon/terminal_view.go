package daemon

import (
	"slices"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/Aqothy/maiD/internal/terminal/vtscreen"
)

// terminalView is one client's view of a terminal: the grid that fits it,
// its appearance, and the stream that carries the terminal to it. A
// connection has one view per terminal.
type terminalView struct {
	client       *rpcClient
	attachmentID string
	columns      uint16
	rows         uint16
	appearance   vtscreen.Appearance
	// ticket opens stream; it is zero once used.
	ticket streamTicket
	stream *terminalStream
}

// terminalViews are the views attached to one terminal, the active one first:
// the terminal has its grid and answers the program's queries with its
// appearance. The rest follow in the order they were last active, so when the
// active view leaves, the one active before it takes over. Callers that change
// the views hold the entry's operations, so the change and the resize it
// implies happen together; the PTY's event path only reads them. A view that
// goes closes its stream. Lock order: the run's emit, then mu, then a
// stream's mu; nothing takes emit while holding mu.
type terminalViews struct {
	mu   sync.Mutex
	list []terminalView
}

// attach adds the client's view, replacing its earlier one in place and
// ending that one's stream, since the client opens the new view's. The view
// goes first when it is active or alone, and last otherwise. It fails
// for a closed connection: once a connection closes, its views are removed
// from every registered terminal, and one added after would hold the size for
// nobody. Checking under the lock the removal takes closes the gap, provided
// the terminal is registered before its first view attaches.
func (v *terminalViews) attach(view terminalView, active bool) bool {
	v.mu.Lock()
	defer v.mu.Unlock()
	if view.client.closed.Load() {
		return false
	}
	switch i := v.index(view.client); {
	case i >= 0:
		closeStream(v.list[i], websocket.StatusNormalClosure, "view replaced")
		v.list[i] = view
		if active {
			v.moveFirst(i)
		}
	case active:
		v.list = slices.Insert(v.list, 0, view)
	default:
		v.list = append(v.list, view)
	}
	return true
}

// activate makes the client's view the active one and reports whether the
// active view changed.
func (v *terminalViews) activate(client *rpcClient) bool {
	v.mu.Lock()
	defer v.mu.Unlock()
	i := v.index(client)
	if i <= 0 {
		return false
	}
	v.moveFirst(i)
	return true
}

func (v *terminalViews) moveFirst(i int) {
	view := v.list[i]
	copy(v.list[1:i+1], v.list[:i])
	v.list[0] = view
}

// update records the grid and appearance that now fit the client's view and
// reports whether the view is attached and whether it is the active one.
func (v *terminalViews) update(client *rpcClient, columns, rows uint16, appearance vtscreen.Appearance) (attached, active bool) {
	v.mu.Lock()
	defer v.mu.Unlock()
	i := v.index(client)
	if i < 0 {
		return false, false
	}
	v.list[i].columns, v.list[i].rows, v.list[i].appearance = columns, rows, appearance
	return true, i == 0
}

// detach removes the client's view while attachmentID is still its current
// one, so a closed view's late detach cannot drop its replacement. It reports
// whether the active view changed.
func (v *terminalViews) detach(client *rpcClient, attachmentID string) bool {
	v.mu.Lock()
	defer v.mu.Unlock()
	i := v.index(client)
	if i < 0 || v.list[i].attachmentID != attachmentID {
		return false
	}
	return v.removeAt(i, websocket.StatusNormalClosure, "view detached")
}

// remove drops the client's view, when its connection closes, and reports
// whether the active view changed.
func (v *terminalViews) remove(client *rpcClient) bool {
	v.mu.Lock()
	defer v.mu.Unlock()
	i := v.index(client)
	if i < 0 {
		return false
	}
	return v.removeAt(i, websocket.StatusGoingAway, "connection closed")
}

func (v *terminalViews) removeAt(i int, code websocket.StatusCode, reason string) bool {
	closeStream(v.list[i], code, reason)
	v.list = slices.Delete(v.list, i, i+1)
	return i == 0 && len(v.list) > 0
}

// clear removes every view, when the terminal is deleted.
func (v *terminalViews) clear() {
	v.mu.Lock()
	defer v.mu.Unlock()
	for _, view := range v.list {
		closeStream(view, websocket.StatusNormalClosure, "terminal deleted")
	}
	v.list = nil
}

// closeStreams ends every view's stream, when the daemon shuts down, and
// returns them so the caller can wait for their goodbyes.
func (v *terminalViews) closeStreams(code websocket.StatusCode, reason string) []*terminalStream {
	v.mu.Lock()
	defer v.mu.Unlock()
	var streams []*terminalStream
	for _, view := range v.list {
		if view.stream != nil {
			view.stream.close(code, reason)
			streams = append(streams, view.stream)
		}
	}
	return streams
}

func closeStream(view terminalView, code websocket.StatusCode, reason string) {
	if view.stream != nil {
		view.stream.close(code, reason)
	}
}

// holdsTicket reports whether a view's unused ticket is ticket.
func (v *terminalViews) holdsTicket(ticket [16]byte) bool {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.ticketIndex(ticket) >= 0
}

// redeem uses up ticket and returns the client whose view it opens, if it
// is still valid at now and the client is still connected.
func (v *terminalViews) redeem(ticket [16]byte, now time.Time) (*rpcClient, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	i := v.ticketIndex(ticket)
	if i < 0 {
		return nil, errStreamTicketUnknown
	}
	view := &v.list[i]
	expires := view.ticket.expires
	view.ticket = streamTicket{}
	if view.client.closed.Load() {
		return nil, errStreamTicketUnknown
	}
	if !now.Before(expires) {
		return nil, errStreamTicketExpired
	}
	return view.client, nil
}

func (v *terminalViews) ticketIndex(ticket [16]byte) int {
	if ticket == ([16]byte{}) {
		return -1
	}
	return slices.IndexFunc(v.list, func(view terminalView) bool { return view.ticket.value == ticket })
}

// setStream makes stream the client's view's stream. The caller holds the
// entry's operations since redeeming the view's ticket, so the view is
// still there.
func (v *terminalViews) setStream(client *rpcClient, stream *terminalStream) {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.list[v.index(client)].stream = stream
}

// eachStream calls fn with each view's stream. Publishers call it under the
// run's emit.
func (v *terminalViews) eachStream(fn func(*terminalStream)) {
	v.mu.Lock()
	defer v.mu.Unlock()
	for _, view := range v.list {
		if view.stream != nil {
			fn(view.stream)
		}
	}
}

func (v *terminalViews) attached(client *rpcClient) bool {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.index(client) >= 0
}

func (v *terminalViews) active() (terminalView, bool) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if len(v.list) == 0 {
		return terminalView{}, false
	}
	return v.list[0], true
}

func (v *terminalViews) index(client *rpcClient) int {
	return slices.IndexFunc(v.list, func(view terminalView) bool { return view.client == client })
}
