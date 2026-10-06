package orchestration

import (
	"encoding/json"
	"testing"

	"github.com/Aqothy/maiD/internal/provider"
)

// slowAppendPayloadText is the reference semantics: decode, append, encode.
func slowAppendPayloadText(existing json.RawMessage, delta string) json.RawMessage {
	var base reasoningPayload
	if len(existing) > 0 {
		if err := json.Unmarshal(existing, &base); err != nil {
			return cloneRawMessage(existing)
		}
	}
	base.Text += delta
	return marshalEventPayload(base)
}

// TestAppendPayloadTextMatchesDecodeEncodeSemantics drives the in-place fast
// path against the decode/append/encode reference across payload contents that
// stress JSON escaping, then checks both routes decode to the same payload.
func TestAppendPayloadTextMatchesDecodeEncodeSemantics(t *testing.T) {
	t.Parallel()

	texts := []string{
		"",
		"plain",
		`quote " and backslash \ inside`,
		"newline\nand\ttab",
		"unicode…✓ and emoji 🚀",
		`already \" escaped-looking`,
		"<html> & entities",
		"control \x01 char",
		`trailing backslash \`,
		`ends with quote "`,
	}
	deltas := append([]string{}, texts...)

	for _, text := range texts {
		for _, delta := range deltas {
			existing := marshalEventPayload(reasoningPayload{Text: text})
			// The projection owns its buffer, so each route needs its own copy
			// exactly as applyItemPayload guarantees in production.
			fast := appendPayloadText(cloneRawMessage(existing), delta)
			slow := slowAppendPayloadText(cloneRawMessage(existing), delta)

			var fastPayload, slowPayload reasoningPayload
			if err := json.Unmarshal(fast, &fastPayload); err != nil {
				t.Fatalf("fast result unparseable for text %q delta %q: %v (%s)", text, delta, err, fast)
			}
			if err := json.Unmarshal(slow, &slowPayload); err != nil {
				t.Fatalf("slow result unparseable for text %q delta %q: %v (%s)", text, delta, err, slow)
			}
			if fastPayload.Text != slowPayload.Text || fastPayload.Text != text+delta {
				t.Fatalf("append text %q + delta %q = %q, want %q", text, delta, fastPayload.Text, text+delta)
			}
		}
	}
}

// TestAppendPayloadTextPreservesAttachmentsViaSlowPath pins the fallback: a
// payload carrying attachments does not match the text-only shape and must
// keep decode/append/encode semantics.
func TestAppendPayloadTextPreservesAttachmentsViaSlowPath(t *testing.T) {
	t.Parallel()

	existing := marshalEventPayload(reasoningPayload{
		Text:        "thought",
		Attachments: []provider.Attachment{{Kind: "image", Name: "shot.png"}},
	})
	merged := appendPayloadText(existing, " more")

	var payload reasoningPayload
	if err := json.Unmarshal(merged, &payload); err != nil {
		t.Fatalf("merged unparseable: %v (%s)", err, merged)
	}
	if payload.Text != "thought more" {
		t.Fatalf("text = %q, want %q", payload.Text, "thought more")
	}
	if len(payload.Attachments) != 1 || payload.Attachments[0].Name != "shot.png" {
		t.Fatalf("attachments = %#v, want the original attachment preserved", payload.Attachments)
	}
}

// TestAppendPayloadTextUnknownShapesFallBack pins that shapes the splice path
// cannot handle keep the exact decode/append/encode fallback semantics,
// including the intended "unparseable base is kept untouched" rule.
func TestAppendPayloadTextUnknownShapesFallBack(t *testing.T) {
	t.Parallel()

	for _, existing := range []string{
		`{"text":"accumulated so far"`, // truncated: never reset accumulated text to one chunk
		`{"note":"x"}`,
		`not json`,
		`[]`,
		`{}`,
		``,
	} {
		merged := appendPayloadText(json.RawMessage(existing), "delta")
		reference := slowAppendPayloadText(json.RawMessage(existing), "delta")
		if string(merged) != string(reference) {
			t.Fatalf("appendPayloadText(%q) = %s, want fallback result %s", existing, merged, reference)
		}
	}
}

// The item-payload contract has exactly two client-visible rules: a textDelta
// appends to the payload's "text"; otherwise a non-empty payload replaces the
// previous one and an absent payload keeps it.
func TestApplyItemPayloadRules(t *testing.T) {
	t.Parallel()

	toolPending := `{"itemType":"tool_call","data":{"status":"pending"}}`
	toolCompleted := `{"itemType":"tool_call","data":{"status":"completed"}}`
	for _, tc := range []struct {
		name     string
		existing string
		incoming string
		delta    string
		want     string
	}{
		{name: "incoming replaces", existing: toolPending, incoming: toolCompleted, want: toolCompleted},
		{name: "absent incoming keeps existing", existing: toolPending, want: toolPending},
		{name: "first delta", delta: "Thinking", want: `{"text":"Thinking"}`},
		{name: "delta appends", existing: `{"text":"Thinking"}`, delta: " harder", want: `{"text":"Thinking harder"}`},
	} {
		var existing, incoming json.RawMessage
		if tc.existing != "" {
			existing = json.RawMessage(tc.existing)
		}
		if tc.incoming != "" {
			incoming = json.RawMessage(tc.incoming)
		}
		if got := applyItemPayload(existing, incoming, tc.delta); string(got) != tc.want {
			t.Fatalf("%s: applyItemPayload = %s, want %s", tc.name, got, tc.want)
		}
	}
}
