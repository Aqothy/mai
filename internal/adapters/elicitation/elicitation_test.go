package elicitation

import (
	"encoding/json"
	"reflect"
	"testing"
)

// Every MCP enum form becomes options with the right labels, and answers are
// checked against them.
func TestChoiceSchemas(t *testing.T) {
	request, form, err := Parse("Pick", "form", "", json.RawMessage(`{"type":"object","properties":{
		"legacy": {"type":"string","enum":["a","b"],"enumNames":["Alpha","Beta"]},
		"titled": {"type":"string","oneOf":[{"const":"x","title":"Ex","description":"first"}]},
		"tags":   {"type":"array","items":{"anyOf":[{"const":"p","title":"Pee"},{"const":"q","title":"Queue"}]},"maxItems":1}
	}}`))
	if err != nil {
		t.Fatal(err)
	}
	labels := map[string][]string{}
	for _, question := range request.Questions {
		for _, option := range question.Options {
			labels[question.ID] = append(labels[question.ID], option.Value+"="+option.Label)
		}
	}
	want := map[string][]string{"legacy": {"a=Alpha", "b=Beta"}, "titled": {"x=Ex"}, "tags": {"p=Pee", "q=Queue"}}
	if !reflect.DeepEqual(labels, want) {
		t.Fatalf("options = %v, want %v", labels, want)
	}
	if _, err := form.Content(map[string][]string{"legacy": {"Alpha"}}); err == nil {
		t.Fatal("a label was accepted as a value")
	}
	if _, err := form.Content(map[string][]string{"tags": {"p", "q"}}); err == nil {
		t.Fatal("more selections than maxItems were accepted")
	}
	content, err := form.Content(map[string][]string{"legacy": {"b"}, "tags": {"q"}})
	if err != nil || !reflect.DeepEqual(content, map[string]any{"legacy": "b", "tags": []string{"q"}}) {
		t.Fatalf("content = %#v, %v", content, err)
	}
}

func TestURLModeOnlyAcceptsWebLinks(t *testing.T) {
	if _, _, err := Parse("Open", "url", "javascript:alert(1)", nil); err == nil {
		t.Fatal("a non-web URL was accepted")
	}
	request, form, err := Parse("Open", "url", "https://example.com/auth", nil)
	if err != nil || form != nil || request.URL != "https://example.com/auth" || request.Questions != nil {
		t.Fatalf("request = %#v, form = %v, err = %v", request, form, err)
	}
}
