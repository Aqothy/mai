package orchestration

import (
	"testing"
)

// The item-payload contract has exactly two client-visible rules (CLIENT_API
// §5): a textDelta appends to the payload's "text"; otherwise a non-empty
// payload replaces the previous one and an absent payload keeps it. These
// tests pin applyItemPayload as that contract's reference implementation.

func TestApplyItemPayloadReplacesWithIncoming(t *testing.T) {
	existing := []byte(`{"itemType":"tool_call","data":{"status":"pending","title":"Old"}}`)
	incoming := []byte(`{"itemType":"tool_call","data":{"status":"completed"}}`)
	got := applyItemPayload(existing, incoming, "")
	if string(got) != string(incoming) {
		t.Fatalf("applyItemPayload = %s, want incoming payload to replace entirely", got)
	}
}

func TestApplyItemPayloadKeepsExistingWhenIncomingAbsent(t *testing.T) {
	existing := []byte(`{"itemType":"tool_call","data":{"status":"pending"}}`)
	got := applyItemPayload(existing, nil, "")
	if string(got) != string(existing) {
		t.Fatalf("applyItemPayload = %s, want existing payload kept for a status-only update", got)
	}
}

func TestApplyItemPayloadAppendsTextDelta(t *testing.T) {
	got := applyItemPayload(nil, nil, "Thinking")
	if string(got) != `{"text":"Thinking"}` {
		t.Fatalf("first delta payload = %s, want {\"text\":\"Thinking\"}", got)
	}
	got = applyItemPayload(got, nil, " harder")
	if string(got) != `{"text":"Thinking harder"}` {
		t.Fatalf("appended delta payload = %s, want accumulated text", got)
	}
}

func TestAppendPayloadTextKeepsExistingWhenBaseUnparseable(t *testing.T) {
	existing := []byte(`{"text":"accumulated so far"`) // truncated JSON
	got := appendPayloadText(existing, " more")
	if string(got) != string(existing) {
		t.Fatalf("appendPayloadText on unparseable base = %s, want existing payload kept (never reset accumulated text to one chunk)", got)
	}
}
