package orchestration

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

func TestThreadCwdDefaultsToDaemonCwdAndRejectsBadPaths(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()

	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-cwd-default", ThreadID: "thread-cwd-default", Title: "Thread"}); err != nil {
		t.Fatalf("thread.create without cwd: %v", err)
	}
	daemonCwd, err := os.Getwd()
	if err != nil {
		t.Fatalf("os.Getwd: %v", err)
	}
	thread, ok := engine.Thread("thread-cwd-default")
	if !ok || thread.Cwd != daemonCwd {
		t.Fatalf("thread cwd = %q, want daemon default %q", thread.Cwd, daemonCwd)
	}

	dir := t.TempDir()
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-cwd-supplied", ThreadID: "thread-cwd-supplied", Title: "Thread", Cwd: dir}); err != nil {
		t.Fatalf("thread.create with valid cwd: %v", err)
	}
	if thread, ok := engine.Thread("thread-cwd-supplied"); !ok || thread.Cwd != dir {
		t.Fatalf("thread cwd = %q, want client-supplied %q", thread.Cwd, dir)
	}

	file := filepath.Join(dir, "not-a-dir")
	if err := os.WriteFile(file, []byte("x"), 0o600); err != nil {
		t.Fatalf("write file: %v", err)
	}
	for name, bad := range map[string]struct {
		cwd  string
		want string
	}{
		"relative":    {cwd: "relative/path", want: "absolute"},
		"nonexistent": {cwd: filepath.Join(dir, "missing"), want: "not usable"},
		"file":        {cwd: file, want: "not a directory"},
	} {
		_, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: CommandID("cmd-cwd-bad-" + name), ThreadID: ThreadID("thread-cwd-bad-" + name), Title: "Thread", Cwd: bad.cwd})
		if err == nil || !strings.Contains(err.Error(), bad.want) {
			t.Fatalf("thread.create with %s cwd err = %v, want %q", name, err, bad.want)
		}
		if _, exists := engine.Thread(ThreadID("thread-cwd-bad-" + name)); exists {
			t.Fatalf("thread with %s cwd was created despite validation error", name)
		}
	}

	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-cwd-meta-bad", ThreadID: "thread-cwd-supplied", Cwd: filepath.Join(dir, "missing")}); err == nil || !strings.Contains(err.Error(), "not usable") {
		t.Fatalf("thread.update with bad cwd err = %v, want validation error", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-cwd-meta-empty", ThreadID: "thread-cwd-supplied", Title: "Renamed"}); err != nil {
		t.Fatalf("thread.update without cwd: %v", err)
	}
	if thread, ok := engine.Thread("thread-cwd-supplied"); !ok || thread.Cwd != dir {
		t.Fatalf("thread cwd after empty-cwd update = %q, want unchanged %q", thread.Cwd, dir)
	}
}

func TestEngineRejectsCwdMetaUpdateWhileProviderSessionBound(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-cwd-bound-session")
	firstCwd := t.TempDir()
	secondCwd := t.TempDir()

	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-cwd-bound-session", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex", Cwd: firstCwd}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", Status: SessionStatusReady, Cwd: firstCwd, UpdatedAt: time.Now()}}}); err != nil {
		t.Fatalf("thread.session.status.set: %v", err)
	}

	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-cwd-same-bound-session", ThreadID: threadID, Cwd: firstCwd}); err != nil {
		t.Fatalf("same-cwd thread.meta.update with bound session: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-cwd-change-bound-session", ThreadID: threadID, Cwd: secondCwd}); err == nil || !strings.Contains(err.Error(), "cannot change cwd") {
		t.Fatalf("cwd change with bound session err = %v, want cannot-change-cwd rejection", err)
	}
	if thread, ok := engine.Thread(threadID); !ok || thread.Cwd != firstCwd {
		t.Fatalf("thread cwd after rejected update = %q, want %q", thread.Cwd, firstCwd)
	}

	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", Status: SessionStatusStopped, Cwd: firstCwd, UpdatedAt: time.Now()}}}); err != nil {
		t.Fatalf("thread.session.status.set stopped: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-cwd-change-stopped-session", ThreadID: threadID, Cwd: secondCwd}); err != nil {
		t.Fatalf("cwd change after session stop: %v", err)
	}
	if thread, ok := engine.Thread(threadID); !ok || thread.Cwd != secondCwd {
		t.Fatalf("thread cwd after stopped-session update = %q, want %q", thread.Cwd, secondCwd)
	}
}

func TestEngineIdempotentThreadCreateByThreadID(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-create-idempotent")
	first, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-idempotent-1", ThreadID: threadID, Title: "Original", ProviderInstanceID: "codex"})
	if err != nil {
		t.Fatalf("first thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-touch-idempotent", ThreadID: threadID, Title: "Touched"}); err != nil {
		t.Fatalf("thread.meta.update: %v", err)
	}
	second, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-idempotent-2", ThreadID: threadID, Title: "Duplicate", ProviderInstanceID: "other"})
	if err != nil {
		t.Fatalf("duplicate thread.create: %v", err)
	}
	if second.Sequence != first.Sequence {
		t.Fatalf("duplicate create sequence = %d, want original create sequence %d", second.Sequence, first.Sequence)
	}
	replay := engine.ReplayEvents(ReplayEventsInput{})
	if len(replay) != 2 {
		t.Fatalf("replay events = %#v, want original create plus metadata update only", replay)
	}
	thread, ok := engine.Thread(threadID)
	if !ok || thread.Title != "Touched" || thread.ProviderInstanceID != "codex" {
		t.Fatalf("thread = %#v, want duplicate create ignored after metadata update", thread)
	}
}

func TestEngineTracksProviderIdentityAcrossCommands(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-model-selection-provider")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-model-selection-provider", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "acp-main", ModelSelection: &provider.ModelSelection{Model: "sonnet"}}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	thread, ok := engine.Thread(threadID)
	if !ok || thread.ProviderInstanceID != "acp-main" {
		t.Fatalf("thread = %#v, want providerInstanceId from modelSelection", thread)
	}
	if shell, ok := engine.ThreadListEntry(threadID); !ok || shell.ProviderInstanceID != "acp-main" {
		t.Fatalf("shell = %#v, want providerInstanceId from modelSelection", shell)
	}
	if snapshot := engine.ThreadListSnapshot(); snapshot.Snapshot == nil || len(snapshot.Snapshot.Threads) != 1 || snapshot.Snapshot.Threads[0].ProviderInstanceID != "acp-main" {
		t.Fatalf("shell snapshot = %#v, want providerInstanceId from modelSelection", snapshot)
	}

	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-meta-model-selection-provider", ThreadID: threadID, ProviderInstanceID: "acp-next", ModelSelection: &provider.ModelSelection{Model: "opus"}}); err != nil {
		t.Fatalf("thread.meta.update: %v", err)
	}
	thread, _ = engine.Thread(threadID)
	if thread.ProviderInstanceID != "acp-next" || thread.ModelSelection == nil || thread.ModelSelection.Model != "opus" {
		t.Fatalf("thread after meta = %#v, want providerInstanceId acp-next with model opus", thread)
	}

	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-model-selection-provider", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-model-selection", Text: "hello"}, ProviderInstanceID: "acp-turn", ModelSelection: &provider.ModelSelection{Model: "haiku"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	thread, _ = engine.Thread(threadID)
	if thread.ProviderInstanceID != "acp-turn" || thread.ModelSelection == nil || thread.ModelSelection.Model != "haiku" {
		t.Fatalf("thread after turn start = %#v, want providerInstanceId acp-turn with model haiku", thread)
	}
}

func TestEngineKeepsThreadProviderSelectionAuthoritativeOverSessionBinding(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-provider-selection-authoritative")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-provider-only", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "draft-instance"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	thread, ok := engine.Thread(threadID)
	if !ok || thread.ProviderInstanceID != "draft-instance" || thread.ModelSelection != nil {
		t.Fatalf("thread after create = %#v, want bare provider identity with no model selection", thread)
	}

	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-meta-provider-only", ThreadID: threadID, ProviderInstanceID: "switched-instance"}); err != nil {
		t.Fatalf("thread.meta.update: %v", err)
	}
	thread, _ = engine.Thread(threadID)
	if thread.ProviderInstanceID != "switched-instance" || thread.ModelSelection != nil {
		t.Fatalf("thread after provider switch = %#v, want bare provider identity", thread)
	}

	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-meta-model-only", ThreadID: threadID, ModelSelection: &provider.ModelSelection{Model: "opus", Options: json.RawMessage(`{"temperature":1}`)}}); err != nil {
		t.Fatalf("thread.meta.update model only: %v", err)
	}
	thread, _ = engine.Thread(threadID)
	if thread.ProviderInstanceID != "switched-instance" || thread.ModelSelection == nil || thread.ModelSelection.Model != "opus" || string(thread.ModelSelection.Options) != `{"temperature":1}` {
		t.Fatalf("thread after model-only update = %#v, want provider instance preserved", thread)
	}

	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-meta-provider-only-clears-model", ThreadID: threadID, ProviderInstanceID: "fresh-instance"}); err != nil {
		t.Fatalf("thread.meta.update provider-only switch: %v", err)
	}
	thread, _ = engine.Thread(threadID)
	if thread.ProviderInstanceID != "fresh-instance" || thread.ModelSelection != nil {
		t.Fatalf("thread after provider-only switch = %#v, want stale model/options cleared", thread)
	}

	binding := &SessionBinding{ThreadID: threadID, ProviderInstanceID: "runtime-binding", Status: SessionStatusReady, UpdatedAt: time.Now()}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: binding}}); err != nil {
		t.Fatalf("thread.session.status.set: %v", err)
	}
	thread, _ = engine.Thread(threadID)
	if thread.ProviderInstanceID != "fresh-instance" || thread.ModelSelection != nil {
		t.Fatalf("thread after session binding = %#v, want desired provider selection unchanged", thread)
	}
	if thread.Session == nil || thread.Session.ProviderInstanceID != "runtime-binding" {
		t.Fatalf("session after binding = %#v, want provider runtime binding stored on session", thread.Session)
	}

	var providerSwitchEvent Event
	engine.OnEvent(func(event Event) {
		if event.CommandID == "cmd-meta-provider-switch-clears-session" {
			providerSwitchEvent = event
		}
	})
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-meta-provider-switch-clears-session", ThreadID: threadID, ProviderInstanceID: "final-instance"}); err != nil {
		t.Fatalf("thread.meta.update provider switch with stale session: %v", err)
	}
	thread, _ = engine.Thread(threadID)
	if thread.Session != nil {
		t.Fatalf("thread session after provider switch = %#v, want cleared", thread.Session)
	}
	if !providerSwitchEvent.Payload.SessionCleared {
		t.Fatalf("provider switch event payload = %#v, want sessionCleared", providerSwitchEvent.Payload)
	}
}

func TestEngineRejectsProviderModelMetaUpdateDuringActiveTurn(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-active-meta-provider")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-active-meta-provider", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "provider-a", ModelSelection: &provider.ModelSelection{Model: "model-a", Options: json.RawMessage(`{"effort":"high"}`)}}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-active-meta-provider", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-active-meta-provider", Text: "hello"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}

	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-active-meta-switch-provider", ThreadID: threadID, ProviderInstanceID: "provider-b"}); err == nil {
		t.Fatal("thread.meta.update provider switch during active turn err = nil, want rejection")
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-active-meta-switch-model", ThreadID: threadID, ProviderInstanceID: "provider-a", ModelSelection: &provider.ModelSelection{Model: "model-b", Options: json.RawMessage(`{"effort":"high"}`)}}); err == nil {
		t.Fatal("thread.meta.update model switch during active turn err = nil, want rejection")
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-active-meta-title", ThreadID: threadID, Title: "Renamed", ProviderInstanceID: "provider-a"}); err != nil {
		t.Fatalf("thread.meta.update compatible metadata: %v", err)
	}

	thread, ok := engine.Thread(threadID)
	if !ok || thread.Title != "Renamed" || thread.ProviderInstanceID != "provider-a" || thread.ModelSelection == nil || thread.ModelSelection.Model != "model-a" || string(thread.ModelSelection.Options) != `{"effort":"high"}` {
		t.Fatalf("thread after active metadata updates = %#v, want title changed without provider/model rebinding", thread)
	}
}

func TestEngineRejectsNonCreateCommandForMissingThread(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	_, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadConfigOptionSet, CommandID: "cmd-missing-config", ThreadID: "missing-thread", OptionID: "mode", Value: "agent"})
	if err == nil {
		t.Fatal("config-option set for missing thread err = nil, want rejection")
	}
	if replay := engine.ReplayEvents(ReplayEventsInput{}); len(replay) != 0 {
		t.Fatalf("replay events = %#v, want no ghost thread events", replay)
	}
}

func TestEngineRejectsClientSuppliedTurnIDOnTurnStart(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-client-turn-id-boundary")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-client-turn-id-boundary", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-client-turn-id-old", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-client-turn-id-old", Text: "old"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("old thread.turn.start: %v", err)
	}
	thread, ok := engine.Thread(threadID)
	if !ok || thread.LatestTurn == nil {
		t.Fatalf("thread after old turn = %#v, want latest turn", thread)
	}
	oldTurnID := thread.LatestTurn.ID
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnInterrupt, CommandID: "cmd-interrupt-client-turn-id-old", ThreadID: threadID, TurnID: oldTurnID, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("old thread.turn.interrupt: %v", err)
	}

	_, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-client-turn-id-reuse", ThreadID: threadID, TurnID: oldTurnID, Message: &CommandMessage{MessageID: "msg-client-turn-id-reuse", Text: "reuse old turn"}, CreatedAt: time.Now()})
	if err == nil || !strings.Contains(err.Error(), "turnId") {
		t.Fatalf("client-supplied turnId err = %v, want turnId rejection", err)
	}
	thread, ok = engine.Thread(threadID)
	if !ok || len(thread.Timeline.Messages()) != 1 || thread.LatestTurn == nil || thread.LatestTurn.ID != oldTurnID || thread.LatestTurn.State != TurnStateRunning {
		t.Fatalf("thread after interrupt intent = %#v, want old turn to remain running until provider confirmation", thread)
	}
}

func TestEngineRequiresActiveSessionForConfigOptionSet(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-config-option-boundary")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-config-option-boundary", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadConfigOptionSet, CommandID: "cmd-config-option-no-session", ThreadID: threadID, OptionID: "model", Value: "slow"}); err == nil || !strings.Contains(err.Error(), "active provider session") {
		t.Fatalf("config-option without session err = %v, want active-session rejection", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", Status: SessionStatusReady, UpdatedAt: time.Now()}}}); err != nil {
		t.Fatalf("thread.session.status.set: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadConfigOptionSet, CommandID: "cmd-config-option-forward", ThreadID: threadID, OptionID: "provider-option", Value: false}); err != nil {
		t.Fatalf("config option should be forwarded to the provider: %v", err)
	}
}

func TestEngineRejectsInvalidApprovalDecision(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-invalid-approval-decision")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-approval-validation", ThreadID: threadID, Title: "Thread"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadApprovalRespond, CommandID: "cmd-invalid-approval-decision", ThreadID: threadID, RequestID: "approval-1", Decision: "approve"}); err == nil {
		t.Fatal("thread.approval.respond invalid decision err = nil, want rejection")
	}
	if replay := engine.ReplayEvents(ReplayEventsInput{}); len(replay) != 1 {
		t.Fatalf("events after invalid approval decision = %#v, want only create", replay)
	}
}

func TestApprovalResponseProjectionPreservesExplicitOptionID(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-approval-response-option")
	requestID := ApprovalID("approval-1")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-approval-response-option", ThreadID: threadID, Title: "Thread"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	approval := &ApprovalEvent{RequestID: string(requestID), Options: []provider.ApprovalOption{{ID: "allow", Name: "Allow"}, {ID: "reject", Name: "Reject"}}}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadApprovalOpened, ThreadID: threadID, Payload: EventPayload{Approval: approval}}); err != nil {
		t.Fatalf("thread.approval.open: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadApprovalRespond, CommandID: "cmd-respond-approval-response-option", ThreadID: threadID, RequestID: requestID, Decision: provider.ApprovalDecisionAccept, OptionID: "reject"}); err != nil {
		t.Fatalf("thread.approval.respond: %v", err)
	}

	thread, ok := engine.Thread(threadID)
	if !ok || len(thread.Timeline.Approvals()) != 1 || thread.Timeline.Approvals()[0].Decision != provider.ApprovalDecisionAccept || thread.Timeline.Approvals()[0].OptionID != "reject" {
		t.Fatalf("approval after response = %#v, want decision and explicit optionId preserved", thread.Timeline.Approvals())
	}
}

func TestEngineRejectsApprovalRespondForUnknownResolvedOrUnofferedOption(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-approval-option-validation")
	requestID := ApprovalID("approval-1")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-approval-option-validation", ThreadID: threadID, Title: "Thread"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	approval := &ApprovalEvent{RequestID: string(requestID), Options: []provider.ApprovalOption{{ID: "allow", Name: "Allow"}, {ID: "reject", Name: "Reject"}}}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadApprovalOpened, ThreadID: threadID, Payload: EventPayload{Approval: approval}}); err != nil {
		t.Fatalf("thread.approval.open: %v", err)
	}

	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadApprovalRespond, CommandID: "cmd-unknown-approval-response", ThreadID: threadID, RequestID: "missing", Decision: provider.ApprovalDecisionAccept}); err == nil {
		t.Fatal("thread.approval.respond unknown request err = nil, want rejection")
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadApprovalRespond, CommandID: "cmd-bad-approval-option", ThreadID: threadID, RequestID: requestID, Decision: provider.ApprovalDecisionAccept, OptionID: "allow-typo"}); err == nil {
		t.Fatal("thread.approval.respond unoffered optionId err = nil, want rejection")
	}
	if replay := engine.ReplayEvents(ReplayEventsInput{}); len(replay) != 2 {
		t.Fatalf("events after rejected approval responses = %#v, want only create/open", replay)
	}
	thread, ok := engine.Thread(threadID)
	if !ok || len(thread.Timeline.Approvals()) != 1 || thread.Timeline.Approvals()[0].Decision != "" || thread.Timeline.Approvals()[0].OptionID != "" {
		t.Fatalf("approval after rejected responses = %#v, want no dirty response", thread.Timeline.Approvals())
	}

	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadApprovalResolved, ThreadID: threadID, Payload: EventPayload{Approval: &ApprovalEvent{RequestID: string(requestID), Decision: provider.ApprovalDecisionAccept, OptionID: "allow"}}}); err != nil {
		t.Fatalf("thread.approval.resolve: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadApprovalRespond, CommandID: "cmd-stale-approval-response", ThreadID: threadID, RequestID: requestID, Decision: provider.ApprovalDecisionAccept}); err == nil {
		t.Fatal("thread.approval.respond resolved request err = nil, want rejection")
	}
	if replay := engine.ReplayEvents(ReplayEventsInput{}); len(replay) != 3 {
		t.Fatalf("events after stale approval response = %#v, want create/open/resolve", replay)
	}
}

// A resolved approval whose request id is opened AGAIN (the ACP adapter re-arms
// permission requests when an agent retries a declined tool call with the same
// tool-call id, so the request id repeats) must return to pending — otherwise
// the decider rejects the client's answer to the second request while the
// adapter is still waiting for it.
func TestApprovalReopenAfterResolutionIsAnswerable(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-approval-reopen")
	requestID := ApprovalID("approval-1")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-approval-reopen", ThreadID: threadID, Title: "Thread"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	options := []provider.ApprovalOption{{ID: "allow", Name: "Allow"}, {ID: "reject", Name: "Reject"}}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadApprovalOpened, ThreadID: threadID, Payload: EventPayload{Approval: &ApprovalEvent{RequestID: string(requestID), TurnID: "turn-1", Options: options}}}); err != nil {
		t.Fatalf("thread.approval.open: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadApprovalResolved, ThreadID: threadID, Payload: EventPayload{Approval: &ApprovalEvent{RequestID: string(requestID), Decision: provider.ApprovalDecisionDecline, OptionID: "reject"}}}); err != nil {
		t.Fatalf("thread.approval.resolve: %v", err)
	}

	// The agent retried the tool call: the same request id opens again with
	// fresh options.
	reopenedOptions := []provider.ApprovalOption{{ID: "allow-2", Name: "Allow"}, {ID: "reject-2", Name: "Reject"}}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadApprovalOpened, ThreadID: threadID, Payload: EventPayload{Approval: &ApprovalEvent{RequestID: string(requestID), TurnID: "turn-1", Options: reopenedOptions}}}); err != nil {
		t.Fatalf("thread.approval.reopen: %v", err)
	}
	thread, ok := engine.Thread(threadID)
	if !ok || len(thread.Timeline.Approvals()) != 1 {
		t.Fatalf("approvals after reopen = %#v, want the single reopened request", thread.Timeline.Approvals())
	}
	reopened := thread.Timeline.Approvals()[0]
	if reopened.Status != ApprovalStatusPending || reopened.Decision != "" || reopened.OptionID != "" {
		t.Fatalf("reopened approval = %#v, want pending with cleared response", reopened)
	}
	if len(reopened.Options) != 2 || reopened.Options[0].ID != "allow-2" {
		t.Fatalf("reopened approval options = %#v, want the fresh request's options", reopened.Options)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadApprovalRespond, CommandID: "cmd-respond-approval-reopen", ThreadID: threadID, RequestID: requestID, Decision: provider.ApprovalDecisionAccept, OptionID: "allow-2"}); err != nil {
		t.Fatalf("thread.approval.respond to reopened request: %v", err)
	}
}

func TestTimelinePreservesFirstAppearanceAcrossUpserts(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-timeline-sequence")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-timeline-sequence", ThreadID: threadID, Title: "Thread"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}

	_, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadMessageSent, ThreadID: threadID, Payload: EventPayload{MessageID: "message-1", Role: MessageRoleAssistant, Text: "hel"}})
	if err != nil {
		t.Fatalf("append message: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadMessageSent, ThreadID: threadID, Payload: EventPayload{MessageID: "message-1", Role: MessageRoleAssistant, Text: "lo"}}); err != nil {
		t.Fatalf("update message: %v", err)
	}
	_, err = engine.AppendEvent(context.Background(), EventInput{Type: EventThreadItemUpserted, ThreadID: threadID, Payload: EventPayload{Item: &Item{ID: "item-1", Kind: provider.ItemKindCommandExecution, Status: provider.ItemStatusInProgress}}})
	if err != nil {
		t.Fatalf("append item: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadItemUpserted, ThreadID: threadID, Payload: EventPayload{Item: &Item{ID: "item-1", Status: provider.ItemStatusCompleted}}}); err != nil {
		t.Fatalf("update item: %v", err)
	}
	_, err = engine.AppendEvent(context.Background(), EventInput{Type: EventThreadApprovalOpened, ThreadID: threadID, Payload: EventPayload{Approval: &ApprovalEvent{RequestID: "approval-1"}}})
	if err != nil {
		t.Fatalf("open approval: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadApprovalResolved, ThreadID: threadID, Payload: EventPayload{Approval: &ApprovalEvent{RequestID: "approval-1", Decision: provider.ApprovalDecisionDecline}}}); err != nil {
		t.Fatalf("resolve approval: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadApprovalOpened, ThreadID: threadID, Payload: EventPayload{Approval: &ApprovalEvent{RequestID: "approval-1"}}}); err != nil {
		t.Fatalf("reopen approval: %v", err)
	}

	thread, ok := engine.Thread(threadID)
	if !ok {
		t.Fatal("thread missing")
	}
	if len(thread.Timeline) != 3 || thread.Timeline[0].Kind != TimelineEntryMessage || thread.Timeline[1].Kind != TimelineEntryItem || thread.Timeline[2].Kind != TimelineEntryApproval {
		t.Fatalf("timeline = %#v, want message, item, approval", thread.Timeline)
	}
	if thread.Timeline[0].Message.Text != "hello" || thread.Timeline[1].Item.Status != provider.ItemStatusCompleted || thread.Timeline[2].Approval.Status != ApprovalStatusPending {
		t.Fatalf("timeline updates were not applied in place: %#v", thread.Timeline)
	}

	snapshot, err := engine.ThreadSnapshot(threadID)
	if err != nil {
		t.Fatalf("thread snapshot: %v", err)
	}
	if len(snapshot.Snapshot.Thread.Timeline) != 3 {
		t.Fatalf("snapshot lost timeline: %#v", snapshot.Snapshot)
	}
}

// The provider's stop reason (end_turn, max_tokens, refusal, ...) is part of
// the client contract (latestTurn.stopReason, CLIENT_API §11): a settle update
// carrying one must surface it on the settle event and the completed turn —
// otherwise a max_tokens/refusal turn is indistinguishable from a clean
// completion.
func TestTurnSettleSurfacesProviderStopReason(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-stop-reason")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-stop-reason", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "prov-a"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-stop-reason", ThreadID: threadID, Message: &CommandMessage{Text: "hello"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	thread, ok := engine.Thread(threadID)
	if !ok || thread.LatestTurn == nil {
		t.Fatalf("thread after turn start = %#v, want a latest turn", thread)
	}
	turnID := thread.LatestTurn.ID
	if _, err := engine.updateSession(context.Background(), sessionUpdate{threadID: threadID, Kind: sessionUpdateBound, TurnID: turnID, Binding: &SessionBinding{ProviderInstanceID: "prov-a"}}); err != nil {
		t.Fatalf("bound update: %v", err)
	}
	result, err := engine.updateSession(context.Background(), sessionUpdate{threadID: threadID, Kind: sessionUpdateTurnSettled, TurnID: turnID, TurnState: provider.RuntimeTurnCompleted, StopReason: "max_tokens"})
	if err != nil || result.Sequence == 0 {
		t.Fatalf("settle update result = %v, %v; want accepted", result, err)
	}

	thread, _ = engine.Thread(threadID)
	if thread.LatestTurn == nil || thread.LatestTurn.State != TurnStateCompleted {
		t.Fatalf("latest turn after settle = %#v, want completed", thread.LatestTurn)
	}
	if thread.LatestTurn.StopReason != "max_tokens" {
		t.Fatalf("latest turn stopReason = %q, want %q", thread.LatestTurn.StopReason, "max_tokens")
	}
	events := engine.ReplayEvents(ReplayEventsInput{FromSequenceExclusive: result.Sequence - 1, ThreadID: threadID})
	if len(events) != 1 || events[0].Payload.StopReason != "max_tokens" {
		t.Fatalf("settle event = %#v, want payload stopReason %q", events, "max_tokens")
	}
}

func TestStoppedFactDoesNotOverwriteCompletedTurnStopReason(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-completion-before-stop")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-completion-before-stop", ThreadID: threadID, ProviderInstanceID: "prov-a"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-completion-before-stop", ThreadID: threadID, Message: &CommandMessage{Text: "hello"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	thread, _ := engine.Thread(threadID)
	turnID := thread.LatestTurn.ID
	if _, err := engine.updateSession(context.Background(), sessionUpdate{threadID: threadID, Kind: sessionUpdateBound, TurnID: turnID, Binding: &SessionBinding{ProviderInstanceID: "prov-a"}}); err != nil {
		t.Fatalf("bound update: %v", err)
	}
	if _, err := engine.updateSession(context.Background(), sessionUpdate{threadID: threadID, Kind: sessionUpdateTurnSettled, TurnID: turnID, TurnState: provider.RuntimeTurnCompleted, StopReason: "end_turn"}); err != nil {
		t.Fatalf("completion update: %v", err)
	}
	result, err := engine.updateSession(context.Background(), sessionUpdate{threadID: threadID, Kind: sessionUpdateStopped, StopReason: "cancelled"})
	if err != nil || result.Sequence == 0 {
		t.Fatalf("stopped update = (%#v, %v), want accepted", result, err)
	}

	thread, _ = engine.Thread(threadID)
	if thread.LatestTurn == nil || thread.LatestTurn.StopReason != "end_turn" {
		t.Fatalf("latest turn = %#v, want completed turn reason preserved", thread.LatestTurn)
	}
	events := engine.ReplayEvents(ReplayEventsInput{ThreadID: threadID, FromSequenceExclusive: result.Sequence - 1})
	if len(events) != 1 || events[0].Payload.StopReason != "" {
		t.Fatalf("stopped event = %#v, want no stale cancelled reason", events)
	}
}

// Status changes ride session updates: the engine derives the full binding from
// the LIVE thread inside its locked write region, so a status-only change can
// never clobber newer session metadata (config options, slash commands, token
// usage) — there is no producer-side snapshot to go stale.
func TestSessionStatusUpdatePreservesNewerSessionMetadata(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-session-status-preserves-metadata")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-status-preserve", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	binding := &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", Status: SessionStatusReady, ConfigOptions: []provider.ConfigOption{{ID: "model", CurrentValue: "old"}}, SlashCommands: []provider.SlashCommand{{Name: "old"}}, TokenUsage: &provider.TokenUsage{UsedTokens: 1}, UpdatedAt: time.Now()}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: binding}}); err != nil {
		t.Fatalf("thread.session.status.set: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadConfigOptionsUpdated, ThreadID: threadID, Payload: EventPayload{ConfigOptions: []provider.ConfigOption{{ID: "model", CurrentValue: "new"}}}}); err != nil {
		t.Fatalf("thread.config-options.update: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSlashCommandsUpdated, ThreadID: threadID, Payload: EventPayload{SlashCommands: []provider.SlashCommand{{Name: "new"}}}}); err != nil {
		t.Fatalf("thread.slash-commands.update: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadTokenUsageUpdated, ThreadID: threadID, Payload: EventPayload{TokenUsage: &provider.TokenUsage{UsedTokens: 2}}}); err != nil {
		t.Fatalf("thread.token-usage.update: %v", err)
	}
	result, err := engine.updateSession(context.Background(), sessionUpdate{threadID: threadID, Kind: sessionUpdateTurnStarted, TurnID: "turn-1"})
	if err != nil || result.Sequence == 0 {
		t.Fatalf("turn-started update = (%#v, %v), want accepted append", result, err)
	}
	thread, ok := engine.Thread(threadID)
	if !ok || thread.Session == nil {
		t.Fatalf("thread/session missing: %#v", thread)
	}
	if thread.Session.Status != SessionStatusRunning || thread.Session.ActiveTurnID != "turn-1" {
		t.Fatalf("session status = %#v, want running turn-1", thread.Session)
	}
	if len(thread.Session.ConfigOptions) != 1 || thread.Session.ConfigOptions[0].CurrentValue != "new" {
		t.Fatalf("config options = %#v, want newer value preserved", thread.Session.ConfigOptions)
	}
	if len(thread.Session.SlashCommands) != 1 || thread.Session.SlashCommands[0].Name != "new" {
		t.Fatalf("slash commands = %#v, want newer value preserved", thread.Session.SlashCommands)
	}
	if thread.Session.TokenUsage == nil || thread.Session.TokenUsage.UsedTokens != 2 {
		t.Fatalf("token usage = %#v, want newer value preserved", thread.Session.TokenUsage)
	}
}

func TestConfigOptionsUpdateSyncsThreadModelSelection(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-config-options-sync-model-selection")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-config-model-sync", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	var configEvent Event
	engine.OnEvent(func(event Event) {
		if event.Type == EventThreadConfigOptionsUpdated {
			configEvent = event
		}
	})
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadConfigOptionsUpdated, ThreadID: threadID, Payload: EventPayload{ConfigOptions: []provider.ConfigOption{{ID: "model", Category: provider.ConfigOptionCategoryModel, CurrentValue: "slow"}}}}); err != nil {
		t.Fatalf("thread.config-options.update: %v", err)
	}
	thread, ok := engine.Thread(threadID)
	if !ok || thread.ModelSelection == nil {
		t.Fatalf("thread model selection missing: %#v", thread)
	}
	if thread.ModelSelection == nil || thread.ModelSelection.Model != "slow" {
		t.Fatalf("model selection = %#v, want codex/slow", thread.ModelSelection)
	}
	if configEvent.Payload.ModelSelection == nil || configEvent.Payload.ModelSelection.Model != "slow" {
		t.Fatalf("config-options event payload = %#v, want modelSelection codex/slow", configEvent.Payload)
	}
}

func TestEngineAcceptsAttachmentOnlyTurnStart(t *testing.T) {
	engine := NewEngine()
	threadID := ThreadID("thread-attachment-only")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-attachment-only", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-attachment-only", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-image", Attachments: []provider.Attachment{{Kind: "image", Data: "base64", MimeType: "image/png"}}}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("attachment-only thread.turn.start: %v", err)
	}
	snapshot, err := engine.ThreadSnapshot(threadID)
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	if len(snapshot.Snapshot.Thread.Timeline.Messages()) != 1 || len(snapshot.Snapshot.Thread.Timeline.Messages()[0].Attachments) != 1 {
		t.Fatalf("messages = %#v, want attachment-only user message", snapshot.Snapshot.Thread.Timeline.Messages())
	}
}

func TestEngineRejectsRawAttachments(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-raw-attachment")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-raw-attachment", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-raw-attachment", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-raw", Text: "hello", Attachments: []provider.Attachment{{Raw: json.RawMessage(`{"type":"image","data":"base64"}`)}}}}); err == nil {
		t.Fatal("thread.turn.start raw attachment err = nil, want rejection")
	}
	thread, ok := engine.Thread(threadID)
	if !ok || len(thread.Timeline.Messages()) != 0 {
		t.Fatalf("thread messages = %#v, want no recorded raw attachment message", thread.Timeline.Messages())
	}
}

func TestEngineUserPromptMessageCarriesTurnID(t *testing.T) {
	engine := NewEngine()
	threadID := ThreadID("thread-user-message-turn-id")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-user-message-turn-id", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-user-message-turn-id", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-user", Text: "hello"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	snapshot, err := engine.ThreadSnapshot(threadID)
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	thread := snapshot.Snapshot.Thread
	if thread.LatestTurn == nil || len(thread.Timeline.Messages()) != 1 || thread.Timeline.Messages()[0].TurnID != thread.LatestTurn.ID {
		t.Fatalf("thread = %#v, want user message tagged with latest turn id", thread)
	}
}

func TestEngineRejectsStaleTurnInterrupt(t *testing.T) {
	engine := NewEngine()
	threadID := ThreadID("thread-stale-interrupt")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-stale-interrupt", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	binding := &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", Status: SessionStatusReady, UpdatedAt: time.Now()}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: binding}}); err != nil {
		t.Fatalf("thread.session.status.set: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-stale-old", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-old", Text: "old"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("old thread.turn.start: %v", err)
	}
	thread, _ := engine.Thread(threadID)
	oldTurnID := thread.LatestTurn.ID
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnInterrupt, CommandID: "cmd-interrupt-stale-old", ThreadID: threadID, TurnID: oldTurnID, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("old thread.turn.interrupt: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", Status: SessionStatusInterrupted, UpdatedAt: time.Now()}}}); err != nil {
		t.Fatalf("confirm old turn interrupted: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-stale-new", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-new", Text: "new"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("new thread.turn.start: %v", err)
	}
	thread, _ = engine.Thread(threadID)
	newTurnID := thread.LatestTurn.ID
	if newTurnID == oldTurnID {
		t.Fatalf("new turn reused old turn id %q", oldTurnID)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnInterrupt, CommandID: "cmd-interrupt-stale-old-again", ThreadID: threadID, TurnID: oldTurnID, CreatedAt: time.Now()}); err == nil {
		t.Fatal("stale thread.turn.interrupt err = nil, want rejection")
	}
	thread, _ = engine.Thread(threadID)
	if thread.LatestTurn == nil || thread.LatestTurn.ID != newTurnID || thread.LatestTurn.State != TurnStateRunning || thread.Session == nil || thread.Session.ActiveTurnID != newTurnID {
		t.Fatalf("thread = %#v, want current turn still running after stale interrupt", thread)
	}
}

func TestEngineAcceptsTurnStartAsSteeringWhileTurnIsRunning(t *testing.T) {
	engine := NewEngine()
	threadID := ThreadID("thread-steer")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-steer", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-1", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-1", Text: "hello"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("first thread.turn.start: %v", err)
	}
	snapshot, err := engine.ThreadSnapshot(threadID)
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	activeTurnID := snapshot.Snapshot.Thread.LatestTurn.ID
	if activeTurnID == "" {
		t.Fatal("active turn id missing")
	}
	requestedAt := snapshot.Snapshot.Thread.LatestTurn.RequestedAt
	startedAt := snapshot.Snapshot.Thread.LatestTurn.StartedAt
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-2", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-2", Text: "actually, do this too"}, CreatedAt: time.Now().Add(time.Minute)}); err != nil {
		t.Fatalf("steering thread.turn.start: %v", err)
	}
	snapshot, err = engine.ThreadSnapshot(threadID)
	if err != nil {
		t.Fatalf("snapshot after steer: %v", err)
	}
	if snapshot.Snapshot.Thread.LatestTurn.ID != activeTurnID {
		t.Fatalf("latest turn id = %q, want steering to reuse %q", snapshot.Snapshot.Thread.LatestTurn.ID, activeTurnID)
	}
	steered := snapshot.Snapshot.Thread.LatestTurn
	if !steered.RequestedAt.Equal(requestedAt) || steered.StartedAt == nil || !steered.StartedAt.Equal(*startedAt) {
		t.Fatalf("steered turn timing = %v/%v, want original %v/%v preserved", steered.RequestedAt, steered.StartedAt, requestedAt, startedAt)
	}
	if steered.State != TurnStateRunning {
		t.Fatalf("steered turn state = %q, want running", steered.State)
	}
	if len(snapshot.Snapshot.Thread.Timeline.Messages()) != 2 || snapshot.Snapshot.Thread.Timeline.Messages()[1].Text != "actually, do this too" {
		t.Fatalf("messages = %#v, want second user steering message", snapshot.Snapshot.Thread.Timeline.Messages())
	}
}

func TestEngineRejectsProviderOrModelChangeWhileSteeringActiveTurn(t *testing.T) {
	engine := NewEngine()
	threadID := ThreadID("thread-steer-routing-stable")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-steer-routing", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex", ModelSelection: &provider.ModelSelection{Model: "fast", Options: json.RawMessage(`{"effort":"low"}`)}}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-routing-1", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-routing-1", Text: "hello"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("first thread.turn.start: %v", err)
	}
	thread, ok := engine.Thread(threadID)
	if !ok || thread.LatestTurn == nil {
		t.Fatalf("thread latest turn missing: %#v", thread)
	}
	activeTurnID := thread.LatestTurn.ID

	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-steer-other-provider", ThreadID: threadID, ProviderInstanceID: "other", Message: &CommandMessage{MessageID: "msg-other-provider", Text: "switch provider"}, CreatedAt: time.Now()}); err == nil {
		t.Fatal("steering with a different provider err = nil, want rejection")
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-steer-other-model", ThreadID: threadID, ProviderInstanceID: "codex", ModelSelection: &provider.ModelSelection{Model: "slow"}, Message: &CommandMessage{MessageID: "msg-other-model", Text: "switch model"}, CreatedAt: time.Now()}); err == nil {
		t.Fatal("steering with a different model err = nil, want rejection")
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-steer-same-provider", ThreadID: threadID, ProviderInstanceID: "codex", Message: &CommandMessage{MessageID: "msg-same-provider", Text: "same provider"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("compatible steering thread.turn.start: %v", err)
	}

	thread, _ = engine.Thread(threadID)
	if thread.LatestTurn == nil || thread.LatestTurn.ID != activeTurnID {
		t.Fatalf("latest turn = %#v, want steering to keep active turn %q", thread.LatestTurn, activeTurnID)
	}
	if thread.ProviderInstanceID != "codex" || thread.ModelSelection == nil || thread.ModelSelection.Model != "fast" || string(thread.ModelSelection.Options) != `{"effort":"low"}` {
		t.Fatalf("thread provider/model = %q/%#v, want original codex fast selection", thread.ProviderInstanceID, thread.ModelSelection)
	}
	if len(thread.Timeline.Messages()) != 2 || thread.Timeline.Messages()[1].ID != "msg-same-provider" {
		t.Fatalf("messages = %#v, want only compatible steering message appended", thread.Timeline.Messages())
	}
}

func TestEngineSessionStopWaitsForProviderConfirmation(t *testing.T) {
	engine := NewEngine()
	threadID := ThreadID("thread-stop-running")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-stop-running", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", Status: SessionStatusReady, UpdatedAt: time.Now()}}}); err != nil {
		t.Fatalf("thread.session.status.set: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-before-stop", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-before-stop", Text: "hello"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	thread, _ := engine.Thread(threadID)
	oldTurnID := thread.LatestTurn.ID
	if oldTurnID == "" || thread.Session == nil || thread.Session.ActiveTurnID != oldTurnID {
		t.Fatalf("thread before stop = %#v, want active running turn", thread)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadSessionStop, CommandID: "cmd-stop-running", ThreadID: threadID, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("thread.session.stop: %v", err)
	}
	thread, _ = engine.Thread(threadID)
	if thread.LatestTurn == nil || thread.LatestTurn.ID != oldTurnID || thread.LatestTurn.State != TurnStateRunning || thread.LatestTurn.CompletedAt != nil {
		t.Fatalf("latest turn after stop intent = %#v, want it running until provider confirmation", thread.LatestTurn)
	}
	if thread.Session == nil || thread.Session.Status != SessionStatusRunning || thread.Session.ActiveTurnID != oldTurnID {
		t.Fatalf("session after stop intent = %#v, want running session unchanged", thread.Session)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", Status: SessionStatusStopped, UpdatedAt: time.Now()}}}); err != nil {
		t.Fatalf("confirm session stopped: %v", err)
	}
	thread, _ = engine.Thread(threadID)
	if thread.LatestTurn == nil || thread.LatestTurn.ID != oldTurnID || thread.LatestTurn.State == TurnStateRunning || thread.LatestTurn.CompletedAt == nil {
		t.Fatalf("latest turn after confirmed stop = %#v, want completed non-running turn", thread.LatestTurn)
	}
	if thread.Session == nil || thread.Session.Status != SessionStatusStopped || thread.Session.ActiveTurnID != "" {
		t.Fatalf("session after confirmed stop = %#v, want stopped with no active turn", thread.Session)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-after-stop", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-after-stop", Text: "next"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("next thread.turn.start: %v", err)
	}
	thread, _ = engine.Thread(threadID)
	if thread.LatestTurn == nil || thread.LatestTurn.ID == oldTurnID || thread.LatestTurn.State != TurnStateRunning {
		t.Fatalf("latest turn after restart = %#v, want fresh running turn", thread.LatestTurn)
	}
}

func TestEngineDeduplicatesCommandID(t *testing.T) {
	engine := NewEngine()
	threadID := ThreadID("thread-dedupe")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-dedupe", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	first, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-dedupe", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-1", Text: "hello"}, CreatedAt: time.Now()})
	if err != nil {
		t.Fatalf("first dispatch: %v", err)
	}
	second, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-dedupe", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-duplicate", Text: "hello again"}, CreatedAt: time.Now()})
	if err != nil {
		t.Fatalf("duplicate dispatch: %v", err)
	}
	if second.Sequence != first.Sequence {
		t.Fatalf("duplicate sequence = %d, want %d", second.Sequence, first.Sequence)
	}
	snapshot, err := engine.ThreadSnapshot(threadID)
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	if len(snapshot.Snapshot.Thread.Timeline.Messages()) != 1 || snapshot.Snapshot.Thread.Timeline.Messages()[0].ID != "msg-1" {
		t.Fatalf("messages = %#v, want duplicate command ignored", snapshot.Snapshot.Thread.Timeline.Messages())
	}
}

func TestEmptyConfigAndSlashCommandUpdatesClearSessionLists(t *testing.T) {
	engine := NewEngine()
	threadID := ThreadID("thread-clear-session-lists")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-clear-session-lists", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadConfigOptionsUpdated, ThreadID: threadID, Payload: EventPayload{ConfigOptions: []provider.ConfigOption{{ID: "model", CurrentValue: "fast"}}}}); err != nil {
		t.Fatalf("thread.config-options.update: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSlashCommandsUpdated, ThreadID: threadID, Payload: EventPayload{SlashCommands: []provider.SlashCommand{{Name: "compact"}}}}); err != nil {
		t.Fatalf("thread.slash-commands.update: %v", err)
	}

	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadConfigOptionsUpdated, ThreadID: threadID, Payload: EventPayload{ConfigOptions: []provider.ConfigOption{}}}); err != nil {
		t.Fatalf("thread.config-options.update clear: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSlashCommandsUpdated, ThreadID: threadID, Payload: EventPayload{SlashCommands: []provider.SlashCommand{}}}); err != nil {
		t.Fatalf("thread.slash-commands.update clear: %v", err)
	}

	thread, ok := engine.Thread(threadID)
	if !ok || thread.Session == nil {
		t.Fatalf("thread/session missing: %#v", thread)
	}
	if len(thread.Session.ConfigOptions) != 0 || len(thread.Session.SlashCommands) != 0 {
		t.Fatalf("session lists = config:%#v slash:%#v, want both cleared", thread.Session.ConfigOptions, thread.Session.SlashCommands)
	}
}

func TestProviderCommandFailureCompletesTurnWithoutSession(t *testing.T) {
	engine := NewEngine()
	threadID := ThreadID("thread-fail")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create-fail", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-fail", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-fail", Text: "hello"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	snapshot, err := engine.ThreadSnapshot(threadID)
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	turnID := snapshot.Snapshot.Thread.LatestTurn.ID
	reactor := &ProviderEventReactor{engine: engine}
	reactor.failThread(threadID, turnID, "provider missing")
	snapshot, err = engine.ThreadSnapshot(threadID)
	if err != nil {
		t.Fatalf("snapshot after failure: %v", err)
	}
	if snapshot.Snapshot.Thread.LatestTurn.State != TurnStateError || snapshot.Snapshot.Thread.LatestTurn.Error != "provider missing" || snapshot.Snapshot.Thread.LatestTurn.CompletedAt == nil {
		t.Fatalf("latest turn = %#v, want completed error", snapshot.Snapshot.Thread.LatestTurn)
	}
}

func TestEngineProjectsProviderRuntimeIntoThreadSnapshot(t *testing.T) {
	engine := NewEngine()
	ingestion := NewProviderRuntimeIngestion(engine)

	threadID := ThreadID("thread-1")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-create", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-user", Text: "hello"}, CreatedAt: time.Now()}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}

	snapshotItem, err := engine.ThreadSnapshot(threadID)
	if err != nil {
		t.Fatalf("snapshot before runtime: %v", err)
	}
	turnID := snapshotItem.Snapshot.Thread.LatestTurn.ID
	if turnID == "" {
		t.Fatal("turn id missing")
	}
	if _, err := engine.updateSession(context.Background(), sessionUpdate{threadID: threadID, Kind: sessionUpdateBound, TurnID: turnID, Binding: &SessionBinding{ProviderInstanceID: "codex"}}); err != nil {
		t.Fatalf("bind provider session: %v", err)
	}

	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-runtime", Type: provider.RuntimeEventContentDelta, Provider: provider.DriverKind("test"), ProviderInstanceID: "codex", ThreadID: string(threadID), TurnID: string(turnID), ItemID: "msg-assistant", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{StreamKind: provider.RuntimeContentAssistantText, Delta: "hi"}})
	ingestion.Ingest(provider.RuntimeEvent{EventID: "evt-complete", Type: provider.RuntimeEventTurnCompleted, Provider: provider.DriverKind("test"), ProviderInstanceID: "codex", ThreadID: string(threadID), TurnID: string(turnID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnCompleted, StopReason: "end_turn"}})

	snapshotItem, err = engine.ThreadSnapshot(threadID)
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	messages := snapshotItem.Snapshot.Thread.Timeline.Messages()
	if len(messages) != 2 || messages[0].Text != "hello" || messages[1].Text != "hi" {
		t.Fatalf("messages = %#v, want user and completed assistant messages", messages)
	}
	if turn := snapshotItem.Snapshot.Thread.LatestTurn; turn == nil || turn.StopReason != "end_turn" {
		t.Fatalf("latest turn = %#v, want ACP stop reason projected through runtime ingestion", turn)
	}

	replay := engine.ReplayEvents(ReplayEventsInput{})
	if len(replay) < 4 {
		t.Fatalf("replay = %#v, want event history", replay)
	}
	for i := 1; i < len(replay); i++ {
		if replay[i].Sequence <= replay[i-1].Sequence {
			t.Fatalf("replay sequences not monotonic: %#v", replay)
		}
	}
}

func TestEngineReplayFiltersByThreadAndLimit(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadA := ThreadID("thread-replay-a")
	threadB := ThreadID("thread-replay-b")
	for _, command := range []Command{
		{Type: CommandThreadCreate, CommandID: "cmd-replay-create-a", ThreadID: threadA, Title: "A"},
		{Type: CommandThreadCreate, CommandID: "cmd-replay-create-b", ThreadID: threadB, Title: "B"},
		{Type: CommandThreadMetaUpdate, CommandID: "cmd-replay-meta-a1", ThreadID: threadA, Title: "A1"},
		{Type: CommandThreadMetaUpdate, CommandID: "cmd-replay-meta-b1", ThreadID: threadB, Title: "B1"},
		{Type: CommandThreadMetaUpdate, CommandID: "cmd-replay-meta-a2", ThreadID: threadA, Title: "A2"},
	} {
		if _, err := engine.Dispatch(context.Background(), command); err != nil {
			t.Fatalf("dispatch %s: %v", command.CommandID, err)
		}
	}

	all := engine.ReplayEvents(ReplayEventsInput{})
	if len(all) != 5 {
		t.Fatalf("replay all = %d events, want 5", len(all))
	}
	onlyA := engine.ReplayEvents(ReplayEventsInput{ThreadID: threadA})
	if len(onlyA) != 3 {
		t.Fatalf("replay thread A = %d events, want 3", len(onlyA))
	}
	for _, event := range onlyA {
		if event.ThreadID() != threadA {
			t.Fatalf("replay thread A returned event for %q", event.ThreadID())
		}
	}
	page := engine.ReplayEvents(ReplayEventsInput{ThreadID: threadA, Limit: 2})
	if len(page) != 2 {
		t.Fatalf("replay page = %d events, want limit 2", len(page))
	}
	next := engine.ReplayEvents(ReplayEventsInput{ThreadID: threadA, FromSequenceExclusive: page[len(page)-1].Sequence, Limit: 2})
	if len(next) != 1 || next[0].Sequence <= page[len(page)-1].Sequence {
		t.Fatalf("replay next page = %#v, want 1 remaining event after sequence %d", next, page[len(page)-1].Sequence)
	}
}

func TestEventStoreReplayLimitCapsPreallocation(t *testing.T) {
	store := NewEventStore()
	for i := 0; i < 100; i++ {
		threadID := ThreadID("thread-other")
		if i%10 == 0 {
			threadID = "thread-target"
		}
		store.Append(Event{Type: EventThreadMetaUpdated, Payload: EventPayload{ThreadID: threadID}})
	}

	page := store.Replay(ReplayEventsInput{ThreadID: "thread-target", Limit: 3})
	if len(page) != 3 {
		t.Fatalf("limited replay returned %d events, want 3", len(page))
	}
	if cap(page) > 3 {
		t.Fatalf("limited replay capacity = %d, want capped at page size 3", cap(page))
	}
}

func TestEngineTracksReceiptsOnlyForClientCommands(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-receipt-scope")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-receipt-create", ThreadID: threadID, Title: "Thread"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}

	// Client command: same CommandID must dedupe to the original sequence.
	first, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-receipt-meta", ThreadID: threadID, Title: "Once"})
	if err != nil {
		t.Fatalf("thread.meta.update: %v", err)
	}
	retry, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-receipt-meta", ThreadID: threadID, Title: "Twice"})
	if err != nil {
		t.Fatalf("thread.meta.update retry: %v", err)
	}
	if retry.Sequence != first.Sequence {
		t.Fatalf("client retry sequence = %d, want deduped %d", retry.Sequence, first.Sequence)
	}

	// Provider/server appends leave no receipt: repeated identical appends add a
	// fresh event each time (they arrive once per provider event, one per
	// streamed delta; tracking them would grow the receipts map without bound).
	item := &Item{ID: "item-receipt", Kind: provider.ItemKindToolCall, Title: "call"}
	firstItem, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadItemUpserted, ThreadID: threadID, Payload: EventPayload{Item: item}})
	if err != nil {
		t.Fatalf("item append: %v", err)
	}
	secondItem, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadItemUpserted, ThreadID: threadID, Payload: EventPayload{Item: item}})
	if err != nil {
		t.Fatalf("item append repeat: %v", err)
	}
	if secondItem.Sequence <= firstItem.Sequence {
		t.Fatalf("append repeat sequence = %d, want new event after %d", secondItem.Sequence, firstItem.Sequence)
	}
	if len(engine.receipts) != 2 {
		t.Fatalf("receipts = %d entries, want 2 (create + meta; none for appends)", len(engine.receipts))
	}
}

func TestEngineSurvivesPanickingListenerAndDecider(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	engine.OnEvent(func(Event) { panic("listener boom") })
	threadID := ThreadID("thread-panic-recovery")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-panic-create", ThreadID: threadID, Title: "Thread"}); err != nil {
		t.Fatalf("thread.create with panicking listener: %v", err)
	}
	// The worker must still process commands after the listener panicked.
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-panic-meta", ThreadID: threadID, Title: "Still alive"}); err != nil {
		t.Fatalf("dispatch after listener panic: %v", err)
	}
	if thread, ok := engine.Thread(threadID); !ok || thread.Title != "Still alive" {
		t.Fatalf("thread = %#v, want projection updated after listener panic", thread)
	}
}

func TestEngineSessionViewMatchesThreadWithoutTimeline(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-session-view")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-view-create", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "acp-main", ModelSelection: &provider.ModelSelection{Model: "sonnet"}}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "acp-main", Status: SessionStatusRunning, ActiveTurnID: "turn-view"}}}); err != nil {
		t.Fatalf("thread.session.status.set: %v", err)
	}

	view, ok := engine.SessionView(threadID)
	if !ok || view.ProviderInstanceID != "acp-main" {
		t.Fatalf("view = %#v, want resolved provider instance acp-main", view)
	}
	if view.Session == nil || view.Session.Status != SessionStatusRunning || view.Session.ActiveTurnID != "turn-view" {
		t.Fatalf("view session = %#v, want running session with active turn", view.Session)
	}
	if view.LatestTurn == nil || view.LatestTurn.ID != "turn-view" || view.LatestTurn.State != TurnStateRunning {
		t.Fatalf("view latest turn = %#v, want running turn-view", view.LatestTurn)
	}
	if _, ok := engine.SessionView(ThreadID("missing-thread")); ok {
		t.Fatal("SessionView(missing) = ok, want not found")
	}
	// Mutating the view must not leak into the projection (clone semantics).
	view.Session.Status = SessionStatusError
	if thread, _ := engine.Thread(threadID); thread.Session == nil || thread.Session.Status != SessionStatusRunning {
		t.Fatalf("projection session mutated through view: %#v", thread.Session)
	}
}

func TestThreadListVisibleGatesHotStreamingEvents(t *testing.T) {
	cases := []struct {
		name    string
		event   Event
		visible bool
	}{
		{"assistant delta", Event{Type: EventThreadMessageSent, Payload: EventPayload{Role: MessageRoleAssistant}}, false},
		{"user message", Event{Type: EventThreadMessageSent, Payload: EventPayload{Role: MessageRoleUser}}, true},
		{"reasoning item", Event{Type: EventThreadItemUpserted, Payload: EventPayload{Item: &Item{Kind: provider.ItemKindReasoning}}}, false},
		{"tool call item", Event{Type: EventThreadItemUpserted, Payload: EventPayload{Item: &Item{Kind: provider.ItemKindToolCall}}}, false},
		{"plan update", Event{Type: EventThreadPlanUpdated}, false},
		{"session status", Event{Type: EventThreadSessionStatusSet}, true},
		{"thread created", Event{Type: EventThreadCreated}, true},
	}
	for _, tc := range cases {
		if got := ThreadListVisible(tc.event); got != tc.visible {
			t.Errorf("ThreadListVisible(%s) = %v, want %v", tc.name, got, tc.visible)
		}
	}
}

// recordInvariantViolations installs a recording handler. The worker replies
// to the in-flight caller BEFORE notifying, so tests must receive from the
// channel (not read shared state) to synchronize with the handler.
func recordInvariantViolations(t *testing.T, engine *Engine) <-chan *InvariantViolationError {
	t.Helper()
	ch := make(chan *InvariantViolationError, 4)
	engine.OnInvariantViolation(func(err *InvariantViolationError) { ch <- err })
	return ch
}

func mustReceiveViolation(t *testing.T, ch <-chan *InvariantViolationError) *InvariantViolationError {
	t.Helper()
	select {
	case violation := <-ch:
		return violation
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for the invariant-violation handler")
		return nil
	}
}

// TestEnginePanicAfterMutationEscalatesToFatal proves the post-mutation panic
// policy: a panic raised inside the locked append/apply region (injected via
// testApplyHook) must (a) close the engine and report a typed
// InvariantViolationError — store and read model may now disagree, and the
// daemon's handler turns that into a full shutdown surfaced from
// RunWebSocket, (b) release e.mu so nothing wedges on the way down, and (c)
// still notify listeners of every event that made it into the store before
// the panic (no client sequence gap).
func TestEnginePanicAfterMutationEscalatesToFatal(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	t.Cleanup(func() { testApplyHook = nil })
	violations := recordInvariantViolations(t, engine)

	threadID := ThreadID("thread-locked-panic")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-locked-create", ThreadID: threadID, Title: "Thread"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}

	var notified []EventType
	engine.OnEvent(func(event Event) { notified = append(notified, event.Type) })

	// Panic on the SECOND event of turn.start (the turn request); the first
	// (the user message) is already in the store and must still be notified.
	testApplyHook = func(event Event) {
		if event.Type == EventThreadTurnStartRequested {
			panic("apply boom")
		}
	}
	_, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-locked-turn", ThreadID: threadID, Message: &CommandMessage{Text: "hello"}})
	var violation *InvariantViolationError
	if !errors.As(err, &violation) {
		t.Fatalf("turn.start with panicking apply err = %v, want typed InvariantViolationError", err)
	}
	if reported := mustReceiveViolation(t, violations); !strings.Contains(reported.Error(), "apply boom") {
		t.Fatalf("reported violation = %v, want the apply panic", reported)
	}
	// The engine closed itself before notifying: no further work is accepted.
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-after-fatal", ThreadID: threadID, Title: "nope"}); err == nil || !strings.Contains(err.Error(), "closed") {
		t.Fatalf("dispatch after invariant violation err = %v, want engine-closed error", err)
	}

	// Snapshot readers must not block on a held mutex.
	snapshotDone := make(chan struct{})
	go func() {
		defer close(snapshotDone)
		if _, err := engine.ThreadSnapshot(threadID); err != nil {
			t.Errorf("ThreadSnapshot after panic: %v", err)
		}
		engine.ThreadListSnapshot()
	}()
	select {
	case <-snapshotDone:
	case <-time.After(2 * time.Second):
		t.Fatal("snapshot reader blocked after panic in locked region: e.mu still held")
	}

	sawMessage := false
	for _, eventType := range notified {
		if eventType == EventThreadMessageSent {
			sawMessage = true
		}
	}
	if !sawMessage {
		t.Fatalf("notified events = %v, want the pre-panic EventThreadMessageSent published", notified)
	}

}

// TestEngineAppendEventPanicAfterMutationEscalatesToFatal covers the
// AppendEvent (provider/server event) worker path: a panic inside the locked
// apply region reports the typed violation and closes the engine.
func TestEngineAppendEventPanicAfterMutationEscalatesToFatal(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	t.Cleanup(func() { testApplyHook = nil })
	violations := recordInvariantViolations(t, engine)

	threadID := ThreadID("thread-append-panic")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-append-create", ThreadID: threadID, Title: "Thread"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}

	testApplyHook = func(event Event) {
		if event.Type == EventThreadItemUpserted {
			panic("append boom")
		}
	}
	item := &Item{ID: "item-panic", Kind: provider.ItemKindToolCall}
	var violation *InvariantViolationError
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadItemUpserted, ThreadID: threadID, Payload: EventPayload{Item: item}}); !errors.As(err, &violation) {
		t.Fatalf("AppendEvent with panicking apply err = %v, want typed InvariantViolationError", err)
	}
	mustReceiveViolation(t, violations)
}

// TestEnginePreMutationPanicIsRecoverableWithoutFatal pins the other half of
// the panic policy: a panic BEFORE anything was appended (decider/validation
// code) is converted into a command error, does NOT terminate the daemon, and
// leaves the engine fully usable.
func TestEnginePreMutationPanicIsRecoverableWithoutFatal(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	violations := recordInvariantViolations(t, engine)

	err := func() (err error) {
		defer func() {
			if rec := recover(); rec != nil {
				err = fmt.Errorf("recovered: %v", rec)
			}
		}()
		return engine.withLockNotify(func(appendEvent func(Event) Event) error {
			panic("decider boom")
		})
	}()
	if err == nil || !strings.Contains(err.Error(), "decider boom") {
		t.Fatalf("pre-mutation panic err = %v, want recovered decider boom", err)
	}
	select {
	case violation := <-violations:
		t.Fatalf("violation = %v, want none: pre-mutation panics must stay recoverable", violation)
	default:
	}

	// Mutex released, worker healthy.
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-pre-panic", ThreadID: "thread-pre-panic", Title: "Alive"}); err != nil {
		t.Fatalf("dispatch after pre-mutation panic: %v", err)
	}
}

// TestSessionStatusEventPayloadIsTheCompleteClientState is the client
// conformance test for the thread.session-status-set contract: the event's
// session payload IS the complete new session state, and clients must REPLACE
// their cached binding with it (CLIENT_API §7) — no field merging. It pins
// that (a) the engine-derived payload byte-equals the server projection after
// every status event, (b) metadata set between status events (slash commands)
// is carried forward in the next payload, so replacement loses nothing, and
// (c) a provider switch emits a payload WITHOUT the old provider's metadata,
// so replacement clears it — the case where the old merge rule left clients
// permanently out of sync with fresh snapshots.
func TestSessionStatusEventPayloadIsTheCompleteClientState(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()

	threadID := ThreadID("thread-session-replace")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-replace-create", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "prov-a"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}

	var statusPayloads [][]byte
	engine.OnEvent(func(event Event) {
		if event.Type == EventThreadSessionStatusSet {
			payload, err := json.Marshal(event.Payload.Session)
			if err != nil {
				t.Errorf("marshal status payload: %v", err)
				return
			}
			statusPayloads = append(statusPayloads, payload)
		}
	})

	snapshotMustEqualLastPayload := func(step string) []byte {
		t.Helper()
		if len(statusPayloads) == 0 {
			t.Fatalf("%s: no session-status-set event captured", step)
		}
		payload := statusPayloads[len(statusPayloads)-1]
		thread, ok := engine.Thread(threadID)
		if !ok {
			t.Fatalf("%s: thread not found", step)
		}
		snapshot, err := json.Marshal(thread.Session)
		if err != nil {
			t.Fatalf("%s: marshal snapshot session: %v", step, err)
		}
		if string(snapshot) != string(payload) {
			t.Fatalf("%s: replacing the client session with the event payload diverges from the snapshot\npayload:  %s\nsnapshot: %s", step, payload, snapshot)
		}
		return payload
	}

	appendUpdate := func(step string, update sessionUpdate) {
		t.Helper()
		update.threadID = threadID
		if _, err := engine.updateSession(context.Background(), update); err != nil {
			t.Fatalf("%s: %v", step, err)
		}
	}

	// 1. A turn starts (creating the running LatestTurn the bound update needs)
	// and the session binds on provider A.
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "cmd-replace-turn", ThreadID: threadID, Message: &CommandMessage{Text: "hello"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	thread, ok := engine.Thread(threadID)
	if !ok || thread.LatestTurn == nil {
		t.Fatal("turn.start did not create a running turn")
	}
	turnID := thread.LatestTurn.ID
	appendUpdate("bind prov-a", sessionUpdate{Kind: sessionUpdateBound, TurnID: turnID, Binding: &SessionBinding{ProviderInstanceID: "prov-a", ProviderName: "Provider A", Provider: "acp"}})
	snapshotMustEqualLastPayload("after bind")

	// 2. The agent publishes slash commands BETWEEN status events.
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSlashCommandsUpdated, ThreadID: threadID, Payload: EventPayload{SlashCommands: []provider.SlashCommand{{Name: "compact"}}}}); err != nil {
		t.Fatalf("slash-commands update: %v", err)
	}

	// 3. The settle payload must carry those slash commands forward: replace
	// semantics lose nothing that the server kept.
	appendUpdate("settle turn", sessionUpdate{Kind: sessionUpdateTurnSettled, TurnID: turnID, TurnState: provider.RuntimeTurnCompleted})
	settled := snapshotMustEqualLastPayload("after settle")
	if !strings.Contains(string(settled), `"compact"`) {
		t.Fatalf("settle payload = %s, want slash commands carried forward for replace semantics", settled)
	}

	// 4. Switching providers emits a fresh binding WITHOUT provider A's
	// metadata; replacement clears it. (The old documented merge rule kept
	// the stale slash commands here — the client-divergence bug.)
	appendUpdate("bind prov-b", sessionUpdate{Kind: sessionUpdateBound, Binding: &SessionBinding{ProviderInstanceID: "prov-b", ProviderName: "Provider B", Provider: "acp"}})
	switched := snapshotMustEqualLastPayload("after provider switch")
	if strings.Contains(string(switched), `"compact"`) || strings.Contains(string(switched), "Provider A") {
		t.Fatalf("provider-switch payload = %s, want no provider-A metadata", switched)
	}
}

// TestProviderSelectionEventsCarryTheCompleteAggregate is the client
// conformance test for selection events (CLIENT_API §7): when an event
// carries providerInstanceId it is the COMPLETE new selection — clients
// replace both providerInstanceId and modelSelection with the event's values
// (absent modelSelection = cleared); an event with only modelSelection
// replaces just the model choice. The provider-only switch step is the case
// a patch rule got wrong: the event omits modelSelection, and replacing must
// clear the old provider's model instead of keeping it.
func TestProviderSelectionEventsCarryTheCompleteAggregate(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-selection-aggregate")

	// Client-side fold, applying exactly the documented rule.
	var clientInstance provider.InstanceID
	var clientSelection *provider.ModelSelection
	engine.OnEvent(func(event Event) {
		if event.Payload.ThreadID != threadID && event.ThreadID() != threadID {
			return
		}
		switch {
		case event.Payload.ProviderInstanceID != "":
			clientInstance = event.Payload.ProviderInstanceID
			clientSelection = cloneModelSelection(event.Payload.ModelSelection)
		case event.Payload.ModelSelection != nil:
			clientSelection = cloneModelSelection(event.Payload.ModelSelection)
		}
	})

	mustMatchSnapshot := func(step string) {
		t.Helper()
		thread, ok := engine.Thread(threadID)
		if !ok {
			t.Fatalf("%s: thread not found", step)
		}
		if thread.ProviderInstanceID != clientInstance || !selectionEqual(thread.ModelSelection, clientSelection) {
			t.Fatalf("%s: client fold (%q, %#v) diverges from snapshot (%q, %#v)", step, clientInstance, clientSelection, thread.ProviderInstanceID, thread.ModelSelection)
		}
	}

	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "cmd-agg-create", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "provider-a", ModelSelection: &provider.ModelSelection{Model: "a-model", Options: json.RawMessage(`{"effort":"high"}`)}}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	mustMatchSnapshot("after create")

	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-agg-model", ThreadID: threadID, ModelSelection: &provider.ModelSelection{Model: "a-model-2"}}); err != nil {
		t.Fatalf("model-only meta update: %v", err)
	}
	mustMatchSnapshot("after model-only update")

	// The critical step: provider-only switch. The event must carry the new
	// instance with NO modelSelection, and replacement must clear the model.
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-agg-switch", ThreadID: threadID, ProviderInstanceID: "provider-b"}); err != nil {
		t.Fatalf("provider-only switch: %v", err)
	}
	mustMatchSnapshot("after provider-only switch")
	if clientInstance != "provider-b" || clientSelection != nil {
		t.Fatalf("client fold after switch = (%q, %#v), want provider-b with the old model cleared", clientInstance, clientSelection)
	}
}

func TestEngineStoppedAcknowledgesWorkerExit(t *testing.T) {
	e := NewEngine()

	select {
	case <-e.Stopped():
		t.Fatal("Stopped must not be closed while the engine runs")
	default:
	}

	e.Close()
	select {
	case <-e.Stopped():
	case <-time.After(2 * time.Second):
		t.Fatal("engine worker did not acknowledge stop after Close")
	}
}
