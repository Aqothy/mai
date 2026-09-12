package claudecode

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"testing"
	"time"
)

func TestStreamClientControlRoundTrip(t *testing.T) {
	hostReader, cliWriter := io.Pipe()
	cliReader, hostWriter := io.Pipe()
	client := newStreamClient(hostReader, hostWriter)
	messages := make(chan sdkMessage, 8)
	client.onMessage = func(message sdkMessage) { messages <- message }

	go func() {
		scanner := bufio.NewScanner(cliReader)
		for scanner.Scan() {
			var request sdkMessage
			if json.Unmarshal(scanner.Bytes(), &request) != nil || request.Type != "control_request" {
				continue
			}
			var body controlRequestBody
			if json.Unmarshal(request.Request, &body) == nil && body.Subtype == "never-answered" {
				continue
			}
			response, _ := json.Marshal(map[string]any{
				"type": "control_response",
				"response": map[string]any{
					"subtype": "success", "request_id": request.RequestID,
					"response": map[string]any{"echo": true},
				},
			})
			cliWriter.Write(append(response, '\n'))
			passthrough, _ := json.Marshal(map[string]any{"type": "result", "subtype": "success"})
			cliWriter.Write(append(passthrough, '\n'))
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var result struct {
		Echo bool `json:"echo"`
	}
	if err := client.control(ctx, map[string]any{"subtype": "initialize"}, &result); err != nil {
		t.Fatalf("control: %v", err)
	}
	if !result.Echo {
		t.Fatalf("result = %#v", result)
	}
	select {
	case message := <-messages:
		if message.Type != "result" {
			t.Fatalf("message = %#v", message)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("non-control message was not delivered")
	}

	// Pipe closure fails pending calls instead of hanging them.
	pendingCtx, pendingCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer pendingCancel()
	errs := make(chan error, 1)
	go func() {
		errs <- client.control(pendingCtx, map[string]any{"subtype": "never-answered"}, nil)
	}()
	time.Sleep(50 * time.Millisecond)
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
