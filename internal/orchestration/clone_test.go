package orchestration

import (
	"testing"

	"github.com/Aqothy/maiD/internal/provider"
)

func TestCloneAttachmentsDetachesMetadata(t *testing.T) {
	original := []provider.Attachment{{
		Kind: "resource",
		Annotations: &provider.ContentAnnotations{
			Audience: []string{"assistant"},
			Metadata: map[string]any{"nested": map[string]any{"value": "original"}},
		},
		Metadata: map[string]any{
			"items": []any{map[string]any{"value": "original"}},
			"raw":   []byte("original"),
		},
		ResourceMetadata: map[string]any{"value": "original"},
	}}

	cloned := cloneAttachments(original)
	cloned[0].Annotations.Audience[0] = "user"
	cloned[0].Annotations.Metadata["nested"].(map[string]any)["value"] = "changed"
	cloned[0].Metadata["items"].([]any)[0].(map[string]any)["value"] = "changed"
	cloned[0].Metadata["raw"].([]byte)[0] = 'X'
	cloned[0].ResourceMetadata["value"] = "changed"

	if got := original[0].Annotations.Audience[0]; got != "assistant" {
		t.Fatalf("original annotation audience = %q, want assistant", got)
	}
	if got := original[0].Annotations.Metadata["nested"].(map[string]any)["value"]; got != "original" {
		t.Fatalf("original annotation metadata = %v, want original", got)
	}
	if got := original[0].Metadata["items"].([]any)[0].(map[string]any)["value"]; got != "original" {
		t.Fatalf("original attachment metadata = %v, want original", got)
	}
	if got := string(original[0].Metadata["raw"].([]byte)); got != "original" {
		t.Fatalf("original raw metadata = %q, want original", got)
	}
	if got := original[0].ResourceMetadata["value"]; got != "original" {
		t.Fatalf("original resource metadata = %v, want original", got)
	}
}
