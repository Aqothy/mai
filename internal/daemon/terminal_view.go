package daemon

import (
	"slices"
	"sync"

	"github.com/Aqothy/maiD/internal/terminal/vtscreen"
)

// terminalView is one client's view of a terminal: the grid that fits it and
// its appearance. A connection has one view per terminal.
type terminalView struct {
	client       *rpcClient
	attachmentID string
	columns      uint16
	rows         uint16
	appearance   vtscreen.Appearance
}

// terminalViews are the views attached to one terminal, the active one first:
// the terminal has its grid and answers the program's queries with its
// appearance. The rest follow in the order they were last active, so when the
// active view leaves, the one active before it takes over. Callers that change
// the views hold the entry's operations, so the change and the resize it
// implies happen together; the PTY's event path only reads them.
type terminalViews struct {
	mu   sync.Mutex
	list []terminalView
}

// attach adds the client's view, replacing its earlier one in place. The
// view goes first when it is active or alone, and last otherwise. It fails
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
	return v.removeAt(i)
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
	return v.removeAt(i)
}

func (v *terminalViews) removeAt(i int) bool {
	v.list = slices.Delete(v.list, i, i+1)
	return i == 0 && len(v.list) > 0
}

// clear removes every view, when the terminal is deleted.
func (v *terminalViews) clear() {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.list = nil
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

func (v *terminalViews) clients() []*rpcClient {
	v.mu.Lock()
	defer v.mu.Unlock()
	clients := make([]*rpcClient, len(v.list))
	for i, view := range v.list {
		clients[i] = view.client
	}
	return clients
}

func (v *terminalViews) index(client *rpcClient) int {
	return slices.IndexFunc(v.list, func(view terminalView) bool { return view.client == client })
}
