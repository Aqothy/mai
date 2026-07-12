package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/coder/websocket"
)

// TestCaptureClientAPIExamples regenerates the wire transcript behind
// docs/CLIENT_API.md. It drives a live daemon over a real WebSocket with raw
// JSON-RPC frames (no client library) and records every frame verbatim, so the
// documented examples cannot drift from what the server actually sends.
// Skipped unless an output path is supplied:
//
//	MAID_CAPTURE_EXAMPLES=/tmp/client-api-transcript.md go test -run TestCaptureClientAPIExamples ./internal/daemon
func TestCaptureClientAPIExamples(t *testing.T) {
	outPath := os.Getenv("MAID_CAPTURE_EXAMPLES")
	if outPath == "" {
		t.Skip("set MAID_CAPTURE_EXAMPLES=<output path> to regenerate the docs/CLIENT_API.md transcript")
	}

	demoCwd := "/tmp/maid-demo"
	if err := os.MkdirAll(demoCwd, 0o755); err != nil {
		t.Fatalf("create demo cwd: %v", err)
	}

	s := NewServer()
	defer s.Close()
	server := httptest.NewServer(s.WebSocketHandler())
	defer server.Close()
	url := "ws" + strings.TrimPrefix(server.URL, "http")
	ws, _, err := websocket.Dial(context.Background(), url, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer ws.Close(websocket.StatusNormalClosure, "")
	c := &captureClient{t: t, ws: ws}

	threadID := "1b2f8a54-6c1e-4d2a-9f3b-7c5d0e8a4f21"
	approvalThreadID := "9d4c2e71-3a5f-4b86-8e19-2f6a7c0d5b43"

	c.section("provider.start")
	c.mustCall("provider.start", map[string]any{
		"instanceId": "claude-code", "name": "Claude Code", "driver": "acp",
		"config": map[string]any{"command": helperCommand("rich-sessions")},
	})

	c.section("provider.list")
	c.mustCall("provider.list", nil)

	c.section("orchestration.subscribeThreadList")
	c.mustCall("orchestration.subscribeThreadList", nil)

	c.section("thread.create")
	created, _ := c.mustCall("orchestration.dispatchCommand", map[string]any{
		"type":               "thread.create",
		"commandId":          "5f0c9a3e-8f1d-4f6a-b2e7-9c8d7a6b5e40",
		"threadId":           threadID,
		"title":              "Fix the flaky login test",
		"providerInstanceId": "claude-code",
		"runtimeMode":        "approval-required",
		"cwd":                demoCwd,
	})

	c.section("thread.create retried with the same commandId (idempotent receipt)")
	retried, _ := c.mustCall("orchestration.dispatchCommand", map[string]any{
		"type":               "thread.create",
		"commandId":          "5f0c9a3e-8f1d-4f6a-b2e7-9c8d7a6b5e40",
		"threadId":           threadID,
		"title":              "Fix the flaky login test",
		"providerInstanceId": "claude-code",
		"runtimeMode":        "approval-required",
		"cwd":                demoCwd,
	})
	if string(created) != string(retried) {
		t.Fatalf("retried thread.create receipt = %s, want %s", retried, created)
	}

	c.section("orchestration.subscribeThread")
	c.mustCall("orchestration.subscribeThread", map[string]any{"threadId": threadID})

	c.section("thread.turn.start and the live event stream")
	c.mustCall("orchestration.dispatchCommand", map[string]any{
		"type":      "thread.turn.start",
		"commandId": "e1d4b7a2-0c3f-45e8-9a6b-8f2c1d0e7a54",
		"threadId":  threadID,
		"message":   map[string]any{"messageId": "7a1c4e90-5b2d-4c8f-a3e6-1d9b0f7c2a85", "text": "Why is TestLogin flaky?"},
	})
	c.drainUntilEvent(func(event orchestration.Event) bool {
		return event.ThreadID() == orchestration.ThreadID(threadID) &&
			event.Type == orchestration.EventThreadSessionStatusSet &&
			event.Payload.Session != nil && event.Payload.Session.Status == orchestration.SessionStatusReady
	})

	c.section("thread.config-option.set")
	c.mustCall("orchestration.dispatchCommand", map[string]any{
		"type":      "thread.config-option.set",
		"commandId": "3c8e1f6a-9d4b-42a7-b5e0-6f2a8c1d9e73",
		"threadId":  threadID,
		"optionId":  "model",
		"value":     "test-model-2",
	})
	c.drainUntilEvent(func(event orchestration.Event) bool {
		if event.ThreadID() != orchestration.ThreadID(threadID) || event.Type != orchestration.EventThreadConfigOptionsUpdated {
			return false
		}
		for _, option := range event.Payload.ConfigOptions {
			if option.ID == "model" && option.CurrentValue == "test-model-2" {
				return true
			}
		}
		return false
	})

	c.section("approval flow (second provider instance that asks permission)")
	c.mustCall("provider.start", map[string]any{
		"instanceId": "codex", "name": "Codex", "driver": "acp",
		"config": map[string]any{"command": helperCommand("permission-allow-sessions")},
	})
	c.mustCall("orchestration.dispatchCommand", map[string]any{
		"type":               "thread.create",
		"commandId":          "b4a7d2c9-1e6f-483b-9c5a-0d8e3f6a2b17",
		"threadId":           approvalThreadID,
		"title":              "Refactor session store",
		"providerInstanceId": "codex",
		"runtimeMode":        "approval-required",
		"cwd":                demoCwd,
	})
	c.mustCall("orchestration.subscribeThread", map[string]any{"threadId": approvalThreadID})
	c.mustCall("orchestration.dispatchCommand", map[string]any{
		"type":      "thread.turn.start",
		"commandId": "0f3b6d8a-4c1e-47f2-8b9d-5a7e2c0f4d61",
		"threadId":  approvalThreadID,
		"message":   map[string]any{"messageId": "8c5f2a71-6d3b-4e90-a1c8-3f7d0b6e9a24", "text": "Apply the refactor"},
	})
	opened := c.drainUntilEvent(func(event orchestration.Event) bool {
		return event.ThreadID() == orchestration.ThreadID(approvalThreadID) &&
			event.Type == orchestration.EventThreadApprovalOpened
	})
	c.mustCall("orchestration.dispatchCommand", map[string]any{
		"type":      "thread.approval.respond",
		"commandId": "6e9a3c50-2f8d-4b17-9e4c-1a5b7d0c8f36",
		"threadId":  approvalThreadID,
		"requestId": opened.Payload.Approval.RequestID,
		"decision":  "accept",
	})
	c.drainUntilEvent(func(event orchestration.Event) bool {
		return event.ThreadID() == orchestration.ThreadID(approvalThreadID) &&
			event.Type == orchestration.EventThreadApprovalResolved
	})
	c.drainUntilEvent(func(event orchestration.Event) bool {
		return event.ThreadID() == orchestration.ThreadID(approvalThreadID) &&
			event.Type == orchestration.EventThreadSessionStatusSet &&
			event.Payload.Session != nil && event.Payload.Session.Status == orchestration.SessionStatusReady
	})

	c.section("orchestration.replayEvents (per-thread, paged)")
	c.mustCall("orchestration.replayEvents", map[string]any{"threadId": threadID, "fromSequenceExclusive": 0, "limit": 3})

	c.section("orchestration.unsubscribeThread")
	c.mustCall("orchestration.unsubscribeThread", map[string]any{"threadId": approvalThreadID})

	c.section("provider.listSessions")
	c.mustCall("provider.listSessions", map[string]any{"instanceId": "claude-code"})

	c.section("provider.deleteSession (capability-gated error)")
	c.callExpectError("provider.deleteSession", map[string]any{"instanceId": "claude-code", "sessionId": "sess_new"})

	c.section("error: command on a missing thread")
	c.callExpectError("orchestration.dispatchCommand", map[string]any{
		"type": "thread.turn.interrupt", "commandId": "d7c0f4a8-3b6e-49d1-8f2a-5e9c1b7d0a42", "threadId": "00000000-0000-0000-0000-000000000000",
	})

	c.section("error: server-internal command rejected")
	c.callExpectError("orchestration.dispatchCommand", map[string]any{
		"type": "thread.item.upsert", "commandId": "a2e5c8f1-7d0b-4936-b8e4-9c3f6a1d5b70", "threadId": threadID,
		"item": map[string]any{"id": "item-1", "kind": "tool_call", "status": "in_progress"},
	})

	if err := os.WriteFile(outPath, []byte(c.out.String()), 0o644); err != nil {
		t.Fatalf("write transcript: %v", err)
	}
	t.Logf("wrote client API transcript to %s", outPath)
}

type captureClient struct {
	t      *testing.T
	ws     *websocket.Conn
	out    strings.Builder
	nextID int
}

func (c *captureClient) section(title string) {
	fmt.Fprintf(&c.out, "\n## %s\n\n", title)
}

func (c *captureClient) log(direction string, frame []byte) {
	var value any
	if err := json.Unmarshal(frame, &value); err != nil {
		c.t.Fatalf("invalid frame %s: %v", frame, err)
	}
	pretty, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		c.t.Fatalf("pretty-print frame: %v", err)
	}
	fmt.Fprintf(&c.out, "%s\n%s\n\n", direction, pretty)
}

func (c *captureClient) read() []byte {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, data, err := c.ws.Read(ctx)
	if err != nil {
		c.t.Logf("transcript so far:\n%s", c.out.String())
		c.t.Fatalf("read frame: %v", err)
	}
	c.log("<--", data)
	return data
}

func (c *captureClient) call(method string, params any) (json.RawMessage, json.RawMessage) {
	c.nextID++
	request := map[string]any{"jsonrpc": "2.0", "id": c.nextID, "method": method}
	if params != nil {
		request["params"] = params
	}
	frame, err := json.Marshal(request)
	if err != nil {
		c.t.Fatalf("marshal %s request: %v", method, err)
	}
	c.log("-->", frame)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := c.ws.Write(ctx, websocket.MessageText, frame); err != nil {
		c.t.Fatalf("write %s request: %v", method, err)
	}
	for {
		data := c.read()
		var msg struct {
			ID     json.RawMessage `json:"id"`
			Result json.RawMessage `json:"result"`
			Error  json.RawMessage `json:"error"`
		}
		if err := json.Unmarshal(data, &msg); err != nil {
			c.t.Fatalf("decode frame %s: %v", data, err)
		}
		if string(msg.ID) == strconv.Itoa(c.nextID) {
			return msg.Result, msg.Error
		}
	}
}

func (c *captureClient) mustCall(method string, params any) (json.RawMessage, json.RawMessage) {
	result, errRaw := c.call(method, params)
	if len(errRaw) > 0 {
		c.t.Fatalf("%s returned error: %s", method, errRaw)
	}
	return result, errRaw
}

func (c *captureClient) callExpectError(method string, params any) json.RawMessage {
	_, errRaw := c.call(method, params)
	if len(errRaw) == 0 {
		c.t.Fatalf("%s succeeded, want error", method)
	}
	return errRaw
}

func (c *captureClient) drainUntilEvent(match func(orchestration.Event) bool) orchestration.Event {
	for {
		data := c.read()
		var msg struct {
			Method string                         `json:"method"`
			Params orchestration.ThreadStreamItem `json:"params"`
		}
		if err := json.Unmarshal(data, &msg); err != nil {
			continue
		}
		if msg.Method != RPCMethodOrchestrationSubscribeThread || msg.Params.Event == nil {
			continue
		}
		if match(*msg.Params.Event) {
			return *msg.Params.Event
		}
	}
}
