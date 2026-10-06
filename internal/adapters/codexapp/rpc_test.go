package codexapp

import (
	"context"
	"io"
	"strings"
	"testing"
	"time"
)

type capturedLineWriter struct {
	lines chan []byte
}

func (writer *capturedLineWriter) Write(data []byte) (int, error) {
	copyOfData := append([]byte(nil), data...)
	writer.lines <- copyOfData
	return len(data), nil
}

func TestRPCClientMalformedJSONFailsPendingCalls(t *testing.T) {
	input, server := io.Pipe()
	writes := &capturedLineWriter{lines: make(chan []byte, 2)}
	client := newRPCClient(input, writes)
	go client.run()

	results := make(chan error, 2)
	for range 2 {
		go func() { results <- client.call(context.Background(), "thread/list", map[string]any{}, nil) }()
	}
	<-writes.lines
	<-writes.lines
	if _, err := server.Write([]byte("{not-json}\n")); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		select {
		case err := <-results:
			if err == nil || !strings.Contains(err.Error(), "decode Codex app-server message") {
				t.Fatalf("malformed JSON error = %v", err)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("pending call was not released after malformed JSON")
		}
	}
	client.mu.Lock()
	pending := len(client.pending)
	client.mu.Unlock()
	if pending != 0 {
		t.Fatalf("pending calls after transport failure = %d", pending)
	}
	_ = server.Close()
}
