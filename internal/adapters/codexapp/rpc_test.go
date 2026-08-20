package codexapp

import (
	"context"
	"encoding/json"
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

func TestRPCClientOmitsNilParams(t *testing.T) {
	input, server := io.Pipe()
	writes := &capturedLineWriter{lines: make(chan []byte, 1)}
	client := newRPCClient(input, writes)
	go client.run()

	result := make(chan error, 1)
	go func() { result <- client.call(context.Background(), "account/logout", nil, nil) }()
	line := <-writes.lines
	var request map[string]json.RawMessage
	if err := json.Unmarshal(line, &request); err != nil {
		t.Fatal(err)
	}
	if _, exists := request["params"]; exists {
		t.Fatalf("parameterless request included params: %s", line)
	}
	if _, err := server.Write([]byte(`{"id":1,"result":{}}` + "\n")); err != nil {
		t.Fatal(err)
	}
	if err := <-result; err != nil {
		t.Fatalf("parameterless call: %v", err)
	}
	_ = server.Close()
}

func TestRPCClientMalformedJSONFailsPendingCalls(t *testing.T) {
	input, server := io.Pipe()
	writes := &capturedLineWriter{lines: make(chan []byte, 1)}
	client := newRPCClient(input, writes)
	go client.run()

	result := make(chan error, 1)
	go func() { result <- client.call(context.Background(), "thread/list", map[string]any{}, nil) }()
	<-writes.lines
	if _, err := server.Write([]byte("{not-json}\n")); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-result:
		if err == nil || !strings.Contains(err.Error(), "decode Codex app-server message") {
			t.Fatalf("malformed JSON error = %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("pending call was not released after malformed JSON")
	}
	client.mu.Lock()
	pending := len(client.pending)
	client.mu.Unlock()
	if pending != 0 {
		t.Fatalf("pending calls after transport failure = %d", pending)
	}
	_ = server.Close()
}

func TestRPCClientEOFFailsEveryPendingCall(t *testing.T) {
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
	_ = server.Close()
	for range 2 {
		select {
		case err := <-results:
			if err == nil {
				t.Fatal("pending call unexpectedly succeeded after EOF")
			}
		case <-time.After(2 * time.Second):
			t.Fatal("pending call was not released after EOF")
		}
	}
}
