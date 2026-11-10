package claudecode

import (
	"bufio"
	"context"
	"io"
	"testing"
	"time"
)

// The control round trip is exercised by every fake-CLI integration test;
// this covers stream failure, which those never reach.
func TestStreamClientFailsPendingControlOnStreamClose(t *testing.T) {
	hostReader, cliWriter := io.Pipe()
	cliReader, hostWriter := io.Pipe()
	requested := make(chan struct{})
	go func() {
		input := bufio.NewReader(cliReader)
		_, _ = input.ReadString('\n')
		close(requested)
		_, _ = io.Copy(io.Discard, input)
	}()
	client := newStreamClient(hostReader, hostWriter)
	client.start()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	errs := make(chan error, 1)
	go func() {
		errs <- client.control(ctx, map[string]any{"subtype": "never-answered"}, nil)
	}()
	// A call registers as pending before it writes, so one the CLI has read is
	// pending when the stream fails.
	select {
	case <-requested:
	case err := <-errs:
		t.Fatalf("control ended before the CLI read it: %v", err)
	}
	cliWriter.Close()
	select {
	case err := <-errs:
		if err == nil {
			t.Fatal("pending control survived stream failure")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("pending control did not fail on close")
	}
	if err := client.send(map[string]any{"type": "user"}); err == nil {
		t.Fatal("send after failure should error")
	}
}
