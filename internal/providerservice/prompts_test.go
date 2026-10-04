package providerservice

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/store"
)

type identityProvider struct{ *fakeProviderInstance }

func (*identityProvider) ReplaysClientMessageIDs() bool { return true }

func newPromptService(t *testing.T, st store.PromptStore, routes store.RouteStore) (*Service, *identityProvider) {
	t.Helper()
	instance := &identityProvider{&fakeProviderInstance{info: provider.InstanceInfo{InstanceID: "codex", Driver: "fake", Capabilities: provider.Capabilities{Fork: true}},
		startSession: func(input provider.StartSessionInput) (provider.Session, error) {
			id := input.ProviderSessionID
			if id == "" {
				id = "native-source"
			}
			return provider.Session{ThreadID: input.ThreadID, ProviderSessionID: id}, nil
		},
		forkSession: func(context.Context, provider.ForkSessionInput) (provider.ForkSessionResult, error) {
			return provider.ForkSessionResult{Summary: provider.SessionSummary{SessionID: "native-fork"}}, nil
		},
	}}
	s := New(func(context.Context, provider.InstanceSpec, provider.RuntimeEventListener) (ProviderInstance, error) {
		return instance, nil
	}, WithRouteStore(routes), WithPromptStore(st))
	t.Cleanup(func() { s.Close() })
	if _, err := s.StartInstance(context.Background(), provider.InstanceSpec{InstanceID: "codex", Driver: "fake"}, false); err != nil {
		t.Fatal(err)
	}
	return s, instance
}

func TestPromptPresentationRestartForkAndDistinctSteering(t *testing.T) {
	st := openRouteStore(t)
	s, instance := newPromptService(t, st, st)
	if _, err := s.StartSession(context.Background(), "source", provider.StartSessionInput{ProviderInstanceID: "codex"}); err != nil {
		t.Fatal(err)
	}
	text := "same visible prompt"
	first := provider.PromptPresentation{MessageID: "message-one", Text: &text, Annotations: []provider.PromptAnnotation{{ID: "one", MessageID: "quote-one", Quote: "same quote", Note: "same note"}}}
	second := first
	second.MessageID = "message-two"
	second.Annotations = []provider.PromptAnnotation{{ID: "two", MessageID: "quote-two", Quote: "same quote", Note: "same note"}}
	plain := provider.PromptPresentation{MessageID: "quoted-user-message"}
	for _, presentation := range []provider.PromptPresentation{first, second, plain} {
		if err := s.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "source", TurnID: "same-turn", Input: "same provider input", Presentation: &presentation}); err != nil {
			t.Fatal(err)
		}
	}
	instance.mu.Lock()
	sent := append([]provider.SendTurnInput(nil), instance.sendTurns...)
	instance.mu.Unlock()
	if len(sent) != 3 || sent[0].ClientMessageID == "" || sent[0].ClientMessageID == sent[1].ClientMessageID {
		t.Fatalf("steering identities: %#v", sent)
	}
	records, err := st.LoadPrompts("codex", "native-source")
	if err != nil || len(records) != 3 {
		t.Fatalf("not durable before restart: %#v, %v", records, err)
	}
	if records[sent[2].ClientMessageID].Presentation.Text != nil {
		t.Fatal("ordinary conversation text was persisted")
	}
	if _, err := s.ForkSession(context.Background(), "source"); err != nil {
		t.Fatal(err)
	}
	s.Close()
	s, instance = newPromptService(t, st, st)
	for _, input := range sent {
		instance.startReplay = append(instance.startReplay, provider.RuntimeEvent{ItemID: input.ClientMessageID, Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindUserMessage, ClientMessageID: input.ClientMessageID, Detail: "same provider input"}})
	}
	for _, scope := range []struct{ thread, native string }{{"source", "native-source"}, {"fork", "native-fork"}, {"other", "native-other"}} {
		result, err := s.StartSession(context.Background(), scope.thread, provider.StartSessionInput{ProviderInstanceID: "codex", ProviderSessionID: scope.native, ReplayHistory: true})
		if err != nil {
			t.Fatal(err)
		}
		for index, want := range []provider.PromptPresentation{first, second, plain} {
			got := result.Replay[index].Payload.Presentation
			if scope.thread == "other" {
				if got != nil {
					t.Fatal("unrelated session received annotations")
				}
				continue
			}
			if got == nil || !reflect.DeepEqual(*got, want) {
				t.Fatalf("%s row %d: %#v, want %#v", scope.thread, index, got, want)
			}
		}
	}
}

type failingPromptStore struct {
	store.PromptStore
	saveErr, loadErr, forkErr error
}

func (s failingPromptStore) SavePrompt(i provider.InstanceID, id string, r store.PromptRecord) error {
	if s.saveErr != nil {
		return s.saveErr
	}
	return s.PromptStore.SavePrompt(i, id, r)
}
func (s failingPromptStore) LoadPrompts(i provider.InstanceID, id string) (map[string]store.PromptRecord, error) {
	if s.loadErr != nil {
		return nil, s.loadErr
	}
	return s.PromptStore.LoadPrompts(i, id)
}
func (s failingPromptStore) ForkPrompts(i provider.InstanceID, a, b string) error {
	if s.forkErr != nil {
		return s.forkErr
	}
	return s.PromptStore.ForkPrompts(i, a, b)
}

func TestPromptStorageFailuresDoNotDispatchConsumeReplayOrLeaveNativeFork(t *testing.T) {
	for _, phase := range []string{"save", "load", "fork"} {
		t.Run(phase, func(t *testing.T) {
			st := openRouteStore(t)
			failure := errors.New("injected storage failure")
			broken := failingPromptStore{PromptStore: st}
			if phase == "save" {
				broken.saveErr = failure
			}
			if phase == "load" {
				broken.loadErr = failure
			}
			if phase == "fork" {
				broken.forkErr = failure
			}
			s, instance := newPromptService(t, broken, st)
			if _, err := s.StartSession(context.Background(), "source", provider.StartSessionInput{ProviderInstanceID: "codex"}); err != nil {
				t.Fatal(err)
			}
			switch phase {
			case "save":
				err := s.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "source", Presentation: &provider.PromptPresentation{MessageID: "message"}})
				if !errors.Is(err, failure) || len(instance.sendTurns) != 0 {
					t.Fatalf("send after failed persistence: %v, %#v", err, instance.sendTurns)
				}
			case "load":
				_, err := s.StartSession(context.Background(), "source", provider.StartSessionInput{ProviderInstanceID: "codex", ReplayHistory: true})
				if !errors.Is(err, failure) || len(instance.startInputs) != 1 {
					t.Fatalf("replay consumed after failed read: %v, %#v", err, instance.startInputs)
				}
			case "fork":
				var deleted string
				instance.deleteSess = func(_ context.Context, id string) error { deleted = id; return nil }
				_, err := s.ForkSession(context.Background(), "source")
				if !errors.Is(err, failure) || deleted != "native-fork" {
					t.Fatalf("fork failure cleanup: %v, deleted %q", err, deleted)
				}
			}
		})
	}
}

func TestPromptReplayNeverMatchesTextOrMergesRetryItems(t *testing.T) {
	text := "visible"
	records := map[string]store.PromptRecord{"known": {InputHash: promptInputHash("expanded"), Presentation: provider.PromptPresentation{MessageID: "local", Text: &text}}}
	var events []provider.RuntimeEvent
	for _, row := range []struct{ id, text string }{{"unknown", "expanded"}, {"known", "edited"}, {"known", "expanded"}, {"known", "expanded"}} {
		events = append(events, provider.RuntimeEvent{Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindUserMessage, ClientMessageID: row.id, Detail: row.text}})
	}
	restorePromptPresentations(events, records)
	if events[0].Payload.Presentation != nil || events[1].Payload.Presentation != nil {
		t.Fatal("unmatched identity/content enriched")
	}
	if events[2].Payload.Presentation.MessageID != "local" || events[3].Payload.Presentation.MessageID != "" {
		t.Fatal("retry items would concatenate under one message ID")
	}
}

func TestPromptPresentationRejectsProviderSwitchBeforePersistence(t *testing.T) {
	st := openRouteStore(t)
	s, instance := newPromptService(t, st, st)
	if _, err := s.StartSession(context.Background(), "source", provider.StartSessionInput{ProviderInstanceID: "codex"}); err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	s.threadRoutes["source"] = threadRoute{InstanceID: "other", ProviderSessionID: "other-session"}
	s.mu.Unlock()
	_, err := s.preparePromptPresentation(instance, provider.SendTurnInput{ThreadID: "source", Presentation: &provider.PromptPresentation{MessageID: "message"}})
	if err == nil {
		t.Fatal("saved presentation for an instance that no longer owns the thread")
	}
	for _, scope := range []struct {
		instance provider.InstanceID
		session  string
	}{{"codex", "native-source"}, {"other", "other-session"}} {
		got, err := st.LoadPrompts(scope.instance, scope.session)
		if err != nil || len(got) != 0 {
			t.Fatalf("unexpected metadata: %#v, %v", got, err)
		}
	}
}
