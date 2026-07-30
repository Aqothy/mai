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
		"control  char",
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
