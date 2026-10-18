package acp

import (
	"context"
	"encoding/json"
	"reflect"
	"testing"

	"github.com/Aqothy/maiD/internal/provider"
)

// A form elicitation becomes ordered, typed questions; a bad answer is
// rejected so the question stays answerable, and accepted answers reach the
// agent typed as the form asked.
func TestFormElicitationRoundTrip(t *testing.T) {
	replies := make(chan wireMsg, 1)
	agent := &fakeWireAgent{responses: make(chan wireMsg, 1)}
	agent.onPrompt = func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
		a.write(map[string]any{"jsonrpc": "2.0", "id": "e1", "method": "elicitation/create", "params": json.RawMessage(`{
			"sessionId": "sess", "mode": "form", "message": "How should I refactor?",
			"requestedSchema": {"type": "object", "required": ["strategy", "count"], "properties": {
				"strategy": {"type": "string", "enum": ["conservative", "balanced"]},
				"count": {"type": "integer", "title": "Files", "minimum": 1},
				"confirm": {"type": "boolean", "default": true},
				"tags": {"type": "array", "items": {"type": "string", "enum": ["a", "b"]}}
			}}
		}`)})
		replies <- <-a.responses
		a.respond(id, map[string]any{"stopReason": "end_turn"})
	}
	h := newWireTestHandle(t, agent)
	opened := make(chan provider.RuntimeEvent, 1)
	resolved := make(chan provider.RuntimeEvent, 1)
	h.runtimeEventListener = func(event provider.RuntimeEvent) {
		switch event.Type {
		case provider.RuntimeEventRequestOpened:
			opened <- event
		case provider.RuntimeEventRequestResolved:
			resolved <- event
		}
	}
	bindStreamingSession(h)
	if err := h.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", TurnID: "turn-1", Input: "go"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}

	request := waitFor(t, opened, "elicitation was not surfaced")
	input := request.Payload.Request
	if input == nil || input.Message != "How should I refactor?" {
		t.Fatalf("request = %#v, want a request with the message", request.Payload)
	}
	var kinds []string
	for _, question := range input.Questions {
		kinds = append(kinds, question.ID+":"+string(question.Kind))
	}
	if want := []string{"strategy:choice", "count:integer", "confirm:choice", "tags:choice"}; !reflect.DeepEqual(kinds, want) {
		t.Fatalf("questions = %v, want %v in schema order", kinds, want)
	}

	answer := func(count string) error {
		return h.RespondToRequest(context.Background(), provider.RespondToRequestInput{
			ThreadID: "thread-1", RequestID: request.RequestID, Action: input.Actions[0],
			Answers: map[string][]string{"strategy": {"balanced"}, "count": {count}, "confirm": {"false"}, "tags": {"a", "b"}},
		})
	}
	if err := answer("0"); err == nil {
		t.Fatal("an answer below the minimum was accepted")
	}
	if err := answer("3"); err != nil {
		t.Fatalf("RespondToRequest: %v", err)
	}

	reply := waitFor(t, replies, "agent got no elicitation response")
	var got map[string]any
	if err := json.Unmarshal(reply.Result, &got); err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"action": "accept", "content": map[string]any{"strategy": "balanced", "count": float64(3), "confirm": false, "tags": []any{"a", "b"}}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("elicitation response = %v, want %v", got, want)
	}
	if event := waitFor(t, resolved, "elicitation was not resolved"); event.Payload.Decision != provider.ApprovalDecisionAccept || event.Payload.Answers["count"][0] != "3" {
		t.Fatalf("resolved = %#v, want accepted with the submitted answers", event.Payload)
	}
}

// A question asked outside a turn (e.g. by an MCP server during session setup)
// is shown and answerable like one asked mid-turn, as with other providers.
func TestElicitationOutsideTurnIsAnswerable(t *testing.T) {
	agent := &fakeWireAgent{responses: make(chan wireMsg, 1)}
	h := newWireTestHandle(t, agent)
	opened := make(chan provider.RuntimeEvent, 1)
	h.runtimeEventListener = func(event provider.RuntimeEvent) {
		if event.Type == provider.RuntimeEventRequestOpened {
			opened <- event
		}
	}
	bindStreamingSession(h)
	agent.write(map[string]any{"jsonrpc": "2.0", "id": "e1", "method": "elicitation/create", "params": map[string]any{
		"sessionId": "sess", "mode": "url", "message": "Connect GitHub", "url": "https://example.com/connect",
	}})

	request := waitFor(t, opened, "question outside a turn was not shown")
	decline, _ := request.Payload.Request.Action("decline")
	if err := h.RespondToRequest(context.Background(), provider.RespondToRequestInput{ThreadID: "thread-1", RequestID: request.RequestID, Action: decline}); err != nil {
		t.Fatalf("RespondToRequest: %v", err)
	}
	if reply := waitFor(t, agent.responses, "agent got no reply"); string(reply.Result) != `{"action":"decline"}` {
		t.Fatalf("reply = %s, want decline", reply.Result)
	}
}
