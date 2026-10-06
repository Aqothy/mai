package orchestration

import (
	"reflect"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

func TestReplayRestoresEmptyPromptAndAnnotationProvenance(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	newThreadWithSession(t, engine, "thread")
	ingestion := NewProviderRuntimeIngestion(engine)
	empty := ""
	annotations := []provider.PromptAnnotation{{ID: "annotation", MessageID: "original-user", Role: "user", Quote: "café 👩🏽‍💻", Note: "保持"}}
	ingestion.Ingest(provider.RuntimeEvent{Type: provider.RuntimeEventItemCompleted, ThreadID: "thread", TurnID: "native-turn", ItemID: "native-item", CreatedAt: time.Now(),
		Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindUserMessage, Detail: "expanded provider-facing prompt", Presentation: &provider.PromptPresentation{MessageID: "original-annotated", Text: &empty, Annotations: annotations}}})
	thread, ok := engine.Thread("thread")
	if !ok {
		t.Fatal("thread missing")
	}
	message := thread.Timeline.Message("original-annotated")
	if message == nil || message.Text != "" || !reflect.DeepEqual(message.Annotations, annotations) {
		t.Fatalf("replayed presentation: %#v", message)
	}
}
