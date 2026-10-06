package store

import (
	"path/filepath"
	"reflect"
	"testing"

	"github.com/Aqothy/maiD/internal/provider"
)

func TestPromptMetadataRestartForkAndIsolation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "maid.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	text := "Explain café 👩🏽‍💻"
	record := PromptRecord{ClientMessageID: "client-one", InputHash: "hash", Presentation: provider.PromptPresentation{
		MessageID: "local-one", Text: &text, Annotations: []provider.PromptAnnotation{{ID: "annotation", MessageID: "assistant:source", Quote: "保持", Note: "why?", Role: "assistant"}},
	}}
	if err := s.SavePrompt("codex", "source", record); err != nil {
		t.Fatal(err)
	}
	if err := s.SavePrompt("codex", "source", record); err == nil {
		t.Fatal("duplicate dispatch identity must not overwrite provenance")
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.ForkPrompts("codex", "source", "fork"); err != nil {
		t.Fatal(err)
	}
	for _, session := range []string{"source", "fork"} {
		got, err := s.LoadPrompts("codex", session)
		if err != nil || !reflect.DeepEqual(got[record.ClientMessageID], record) {
			t.Fatalf("%s: %#v, %v", session, got, err)
		}
	}
	for _, scope := range [][2]string{{"other-provider", "source"}, {"codex", "unrelated"}} {
		got, err := s.LoadPrompts(provider.InstanceID(scope[0]), scope[1])
		if err != nil || len(got) != 0 {
			t.Fatalf("metadata leaked into %v: %#v, %v", scope, got, err)
		}
	}
	second := record
	second.ClientMessageID = "client-two"
	if err := s.SavePrompt("codex", "source", second); err != nil {
		t.Fatal(err)
	}
	if err := s.ForkPrompts("codex", "source", "fork"); err == nil {
		t.Fatal("fork collision must be atomic")
	}
	got, err := s.LoadPrompts("codex", "fork")
	if err != nil || len(got) != 1 {
		t.Fatalf("partially copied colliding fork: %#v, %v", got, err)
	}
	if err := s.DeletePrompts("codex", "fork"); err != nil {
		t.Fatal(err)
	}
	got, err = s.LoadPrompts("codex", "source")
	if err != nil || len(got) != 2 {
		t.Fatalf("deleting fork changed source: %#v, %v", got, err)
	}
}
