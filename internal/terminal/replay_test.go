package terminal

import (
	"bytes"
	"testing"
)

func TestReplayBufferRespectsCapAndRecordsTruncation(t *testing.T) {
	b := NewReplayBuffer()
	chunk := bytes.Repeat([]byte("x"), 256*1024)
	for range 7 {
		b.Append(append([]byte(nil), chunk...))
	}
	if b.Truncated() {
		t.Fatal("buffer under the cap reported truncation")
	}
	if b.Len() != 7*256*1024 {
		t.Fatalf("len = %d, want %d", b.Len(), 7*256*1024)
	}

	b.Append(append([]byte(nil), chunk...)) // reaches exactly 2 MiB
	b.Append([]byte("tail"))
	if !b.Truncated() {
		t.Fatal("exceeding the cap did not record truncation")
	}
	if b.Len() > replayBufferLimit {
		t.Fatalf("len = %d exceeds cap %d", b.Len(), replayBufferLimit)
	}
	got := b.Bytes()
	if !bytes.HasSuffix(got, []byte("tail")) {
		t.Fatal("newest output missing after truncation")
	}
	// The oldest complete chunk was dropped, not partially trimmed.
	if b.Len() != 7*256*1024+4 {
		t.Fatalf("len = %d, want oldest complete chunk dropped", b.Len())
	}
}

func TestReplayBufferOversizedChunkKeepsTail(t *testing.T) {
	b := NewReplayBuffer()
	huge := bytes.Repeat([]byte("a"), replayBufferLimit+10)
	copy(huge[len(huge)-3:], "end")
	b.Append(huge)
	if !b.Truncated() {
		t.Fatal("oversized chunk did not record truncation")
	}
	if b.Len() != replayBufferLimit {
		t.Fatalf("len = %d, want cap %d", b.Len(), replayBufferLimit)
	}
	if !bytes.HasSuffix(b.Bytes(), []byte("end")) {
		t.Fatal("oversized chunk did not keep its tail")
	}
}

func TestReplayBufferReset(t *testing.T) {
	b := NewReplayBuffer()
	b.Append(bytes.Repeat([]byte("x"), replayBufferLimit+1))
	b.Reset()
	if b.Len() != 0 || b.Truncated() || len(b.Bytes()) != 0 {
		t.Fatal("reset did not clear payload and truncation record")
	}
}
