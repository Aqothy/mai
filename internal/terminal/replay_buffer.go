package terminal

// replayBufferLimit bounds the replay payload retained per terminal run. The
// value is a starting point, not a compatibility promise; change it only after
// measurement.
const replayBufferLimit = 2 * 1024 * 1024

// ReplayBuffer retains recent output for cold attach. It stores output only,
// never input, preserves byte order, and lives solely in daemon memory for the
// current run. Access is serialized by the owning session.
type ReplayBuffer struct {
	chunks    [][]byte
	size      int
	limit     int
	truncated bool
}

// NewReplayBuffer creates a buffer with the standard byte cap.
func NewReplayBuffer() *ReplayBuffer {
	return &ReplayBuffer{limit: replayBufferLimit}
}

// Append retains one output chunk, discarding the oldest complete chunks once
// the cap is exceeded and recording that truncation happened. The buffer owns
// the slice afterward.
func (b *ReplayBuffer) Append(data []byte) {
	if len(data) == 0 {
		return
	}
	// A chunk larger than the whole cap replaces the entire buffer; keep its
	// tail so replay still ends at the live stream position.
	if len(data) >= b.limit {
		b.chunks = [][]byte{data[len(data)-b.limit:]}
		b.size = b.limit
		b.truncated = true
		return
	}
	b.chunks = append(b.chunks, data)
	b.size += len(data)
	for b.size > b.limit {
		b.size -= len(b.chunks[0])
		b.chunks[0] = nil
		b.chunks = b.chunks[1:]
		b.truncated = true
	}
}

// Bytes returns the retained output as one contiguous copy.
func (b *ReplayBuffer) Bytes() []byte {
	out := make([]byte, 0, b.size)
	for _, chunk := range b.chunks {
		out = append(out, chunk...)
	}
	return out
}

// Len reports the retained payload size.
func (b *ReplayBuffer) Len() int { return b.size }

// Truncated reports whether any output was discarded for this run.
func (b *ReplayBuffer) Truncated() bool { return b.truncated }

// Reset discards all retained output and the truncation record.
func (b *ReplayBuffer) Reset() {
	b.chunks = nil
	b.size = 0
	b.truncated = false
}
