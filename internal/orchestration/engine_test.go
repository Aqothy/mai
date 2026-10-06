package orchestration

import (
	"context"
	"encoding/json"
	"errors"
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

	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "cmd-cwd-default", ThreadID: "thread-cwd-default", Title: "Thread"})
	daemonCwd, err := os.Getwd()
	if err != nil {
		t.Fatalf("os.Getwd: %v", err)
	}
	thread, ok := engine.Thread("thread-cwd-default")
	if !ok || thread.Cwd != daemonCwd {
		t.Fatalf("thread cwd = %q, want daemon default %q", thread.Cwd, daemonCwd)
	}

	dir := t.TempDir()
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "cmd-cwd-supplied", ThreadID: "thread-cwd-supplied", Title: "Thread", Cwd: dir})
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
	mustDispatch(t, engine, Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-cwd-meta-empty", ThreadID: "thread-cwd-supplied", Title: "Renamed"})
	if thread, ok := engine.Thread("thread-cwd-supplied"); !ok || thread.Cwd != dir {
		t.Fatalf("thread cwd after empty-cwd update = %q, want unchanged %q", thread.Cwd, dir)
	}
}

func TestThreadStartCreatesRealThreadWithFirstTurnAndConfig(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	cwd := t.TempDir()
	threadID := ThreadID("thread-local-draft-start")

	result, err := engine.Dispatch(context.Background(), Command{
		Type: CommandThreadStart, CommandID: "start-local-draft", ThreadID: threadID,
		Title: "Build the chat view", ProviderInstanceID: "codex", Cwd: cwd,
		Message: &CommandMessage{MessageID: "first-message", Text: "Build the chat view"},
		ConfigSelections: []provider.ConfigOptionSelection{{
			OptionID: "model", Value: "fast", Category: provider.ConfigOptionCategoryModel,
		}},
	})
	if err != nil {
		t.Fatalf("thread.start: %v", err)
	}
	thread, ok := engine.Thread(threadID)
	if !ok || thread.ProviderInstanceID != "codex" || thread.Cwd != cwd {
		t.Fatalf("thread = %#v, want real configured thread", thread)
	}
	if thread.LatestTurn == nil || thread.LatestTurn.State != TurnStateRunning {
		t.Fatalf("latest turn = %#v, want running first turn", thread.LatestTurn)
	}
	if message := thread.Timeline.Message("first-message"); message == nil || message.Text != "Build the chat view" {
		t.Fatalf("first message = %#v", message)
	}
	if len(thread.ConfigSelections) != 1 || thread.ConfigSelections[0].Value != "fast" {
		t.Fatalf("config selections = %#v", thread.ConfigSelections)
	}

	duplicate, err := engine.Dispatch(context.Background(), Command{
		Type: CommandThreadStart, CommandID: "start-local-draft", ThreadID: threadID,
		ProviderInstanceID: "other", Cwd: cwd,
		Message: &CommandMessage{MessageID: "duplicate", Text: "duplicate"},
	})
	if err != nil || duplicate.Sequence != result.Sequence {
		t.Fatalf("duplicate result = %#v, err = %v, want idempotent receipt %#v", duplicate, err, result)
	}
	if thread, _ := engine.Thread(threadID); thread.Timeline.Message("duplicate") != nil {
		t.Fatal("duplicate thread.start appended another message")
	}
}

func TestEngineRejectsCwdMetaUpdateWhileProviderSessionBound(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-cwd-bound-session")
	firstCwd := t.TempDir()
	secondCwd := t.TempDir()

	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "cmd-create-cwd-bound-session", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex", Cwd: firstCwd})
	mustAppend(t, engine, EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", Status: SessionStatusReady, Cwd: firstCwd, UpdatedAt: time.Now()}}})

	mustDispatch(t, engine, Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-cwd-same-bound-session", ThreadID: threadID, Cwd: firstCwd})
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-cwd-change-bound-session", ThreadID: threadID, Cwd: secondCwd}); err == nil || !strings.Contains(err.Error(), "cannot change cwd") {
		t.Fatalf("cwd change with bound session err = %v, want cannot-change-cwd rejection", err)
	}
	if thread, ok := engine.Thread(threadID); !ok || thread.Cwd != firstCwd {
		t.Fatalf("thread cwd after rejected update = %q, want %q", thread.Cwd, firstCwd)
	}

	mustAppend(t, engine, EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", Status: SessionStatusStopped, Cwd: firstCwd, UpdatedAt: time.Now()}}})
	mustDispatch(t, engine, Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-cwd-change-stopped-session", ThreadID: threadID, Cwd: secondCwd})
	if thread, ok := engine.Thread(threadID); !ok || thread.Cwd != secondCwd {
		t.Fatalf("thread cwd after stopped-session update = %q, want %q", thread.Cwd, secondCwd)
	}
}

func TestAdditionalDirectoriesCanBeClearedAndRenormalizeWhenCwdChanges(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-additional-directories")
	primary := t.TempDir()
	second := t.TempDir()
	third := t.TempDir()

	if _, err := engine.Dispatch(context.Background(), Command{
		Type: CommandThreadCreate, CommandID: "create-additional-directories", ThreadID: threadID,
		Cwd: primary, AdditionalDirectories: []string{second, primary, second, third},
	}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	thread, ok := engine.Thread(threadID)
	if !ok || len(thread.AdditionalDirectories) != 2 || thread.AdditionalDirectories[0] != second || thread.AdditionalDirectories[1] != third {
		t.Fatalf("normalized additional directories = %#v", thread.AdditionalDirectories)
	}

	if _, err := engine.Dispatch(context.Background(), Command{
		Type: CommandThreadMetaUpdate, CommandID: "clear-additional-directories", ThreadID: threadID,
		AdditionalDirectories: []string{},
	}); err != nil {
		t.Fatalf("clear additional directories: %v", err)
	}
	thread, _ = engine.Thread(threadID)
	if len(thread.AdditionalDirectories) != 0 {
		t.Fatalf("additional directories after clear = %#v", thread.AdditionalDirectories)
	}

	if _, err := engine.Dispatch(context.Background(), Command{
		Type: CommandThreadMetaUpdate, CommandID: "restore-additional-directories", ThreadID: threadID,
		AdditionalDirectories: []string{second, third},
	}); err != nil {
		t.Fatalf("restore additional directories: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{
		Type: CommandThreadMetaUpdate, CommandID: "move-primary-into-additional", ThreadID: threadID, Cwd: second,
	}); err != nil {
		t.Fatalf("change cwd: %v", err)
	}
	thread, _ = engine.Thread(threadID)
	if thread.Cwd != second || len(thread.AdditionalDirectories) != 1 || thread.AdditionalDirectories[0] != third {
		t.Fatalf("thread roots after cwd change = cwd %q, additional %#v", thread.Cwd, thread.AdditionalDirectories)
	}
}

func TestEngineIdempotentThreadCreateByThreadID(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	events := observeEvents(t, engine)
	threadID := ThreadID("thread-create-idempotent")
	first := mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "cmd-create-idempotent-1", ThreadID: threadID, Title: "Original", ProviderInstanceID: "codex"})
	mustDispatch(t, engine, Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-touch-idempotent", ThreadID: threadID, Title: "Touched"})
	second := mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "cmd-create-idempotent-2", ThreadID: threadID, Title: "Duplicate", ProviderInstanceID: "other"})
	if second.Sequence != first.Sequence {
		t.Fatalf("duplicate create sequence = %d, want original create sequence %d", second.Sequence, first.Sequence)
	}
	recorded := events.matching("", 0)
	if len(recorded) != 2 {
		t.Fatalf("events = %#v, want original create plus metadata update only", recorded)
	}
	thread, ok := engine.Thread(threadID)
	if !ok || thread.Title != "Touched" || thread.ProviderInstanceID != "codex" {
		t.Fatalf("thread = %#v, want duplicate create ignored after metadata update", thread)
	}
}

// While a turn is active the thread's provider/model selection is pinned: a
// metadata change of either is rejected, and a turn.start becomes steering on
// the same turn (keeping its timing) that may not change the selection either.
func TestEngineActiveTurnPinsSelectionAndAcceptsSteering(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-active-turn")
	selection := &provider.ModelSelection{Model: "fast", Options: json.RawMessage(`{"effort":"low"}`)}
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "create-active-turn", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex", ModelSelection: selection})
	mustDispatch(t, engine, Command{Type: CommandThreadTurnStart, CommandID: "turn-active", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-1", Text: "hello"}})
	active, _ := engine.Thread(threadID)
	activeTurn := *active.LatestTurn

	for name, command := range map[string]Command{
		"meta provider":  {Type: CommandThreadMetaUpdate, ProviderInstanceID: "other"},
		"meta model":     {Type: CommandThreadMetaUpdate, ProviderInstanceID: "codex", ModelSelection: &provider.ModelSelection{Model: "slow", Options: selection.Options}},
		"steer provider": {Type: CommandThreadTurnStart, ProviderInstanceID: "other", Message: &CommandMessage{Text: "switch provider"}},
		"steer model":    {Type: CommandThreadTurnStart, ProviderInstanceID: "codex", ModelSelection: &provider.ModelSelection{Model: "slow"}, Message: &CommandMessage{Text: "switch model"}},
	} {
		command.CommandID, command.ThreadID = CommandID("reject-"+name), threadID
		if _, err := engine.Dispatch(context.Background(), command); err == nil {
			t.Fatalf("%s during active turn err = nil, want rejection", name)
		}
	}
	mustDispatch(t, engine, Command{Type: CommandThreadMetaUpdate, CommandID: "rename-active", ThreadID: threadID, Title: "Renamed", ProviderInstanceID: "codex"})
	mustDispatch(t, engine, Command{Type: CommandThreadTurnStart, CommandID: "steer-active", ThreadID: threadID, ProviderInstanceID: "codex", Message: &CommandMessage{MessageID: "msg-2", Text: "actually, do this too"}, CreatedAt: time.Now().Add(time.Minute)})

	thread, _ := engine.Thread(threadID)
	if thread.Title != "Renamed" || thread.ProviderInstanceID != "codex" || !selectionEqual(thread.ModelSelection, selection) {
		t.Fatalf("thread = %q/%q/%#v, want renamed with the original selection", thread.Title, thread.ProviderInstanceID, thread.ModelSelection)
	}
	steered := thread.LatestTurn
	if steered.ID != activeTurn.ID || steered.State != TurnStateRunning || !steered.RequestedAt.Equal(activeTurn.RequestedAt) || steered.StartedAt == nil || !steered.StartedAt.Equal(*activeTurn.StartedAt) {
		t.Fatalf("steered turn = %#v, want %#v still running with its original timing", steered, activeTurn)
	}
	if messages := thread.Timeline.Messages(); len(messages) != 2 || messages[1].ID != "msg-2" || messages[1].TurnID != activeTurn.ID {
		t.Fatalf("messages = %#v, want only the compatible steering message, on the active turn", messages)
	}
}

func TestEngineRejectsClientSuppliedTurnIDOnTurnStart(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-client-turn-id")
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "create-client-turn-id", ThreadID: threadID, ProviderInstanceID: "codex"})
	_, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-client-turn-id", ThreadID: threadID, TurnID: "client-turn", Message: &CommandMessage{Text: "hello"}})
	if err == nil || !strings.Contains(err.Error(), "turnId") {
		t.Fatalf("client-supplied turnId err = %v, want turnId rejection", err)
	}
	if thread, _ := engine.Thread(threadID); thread.LatestTurn != nil || len(thread.Timeline) != 0 {
		t.Fatalf("rejected turn.start mutated the thread: %#v", thread)
	}
}

func TestEngineConfigOptionSetRequiresThreadWithActiveSession(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	events := observeEvents(t, engine)
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadConfigOptionSet, CommandID: "cmd-missing-config", ThreadID: "missing-thread", OptionID: "mode", Value: "agent"}); err == nil {
		t.Fatal("config-option set for missing thread err = nil, want rejection")
	}
	if recorded := events.matching("", 0); len(recorded) != 0 {
		t.Fatalf("events = %#v, want no ghost thread events", recorded)
	}
	threadID := ThreadID("thread-config-option-boundary")
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "cmd-create-config-option-boundary", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"})
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadConfigOptionSet, CommandID: "cmd-config-option-no-session", ThreadID: threadID, OptionID: "model", Value: "slow"}); err == nil || !strings.Contains(err.Error(), "active provider session") {
		t.Fatalf("config-option without session err = %v, want active-session rejection", err)
	}
	mustAppend(t, engine, EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", Status: SessionStatusReady, UpdatedAt: time.Now()}}})
	mustDispatch(t, engine, Command{Type: CommandThreadConfigOptionSet, CommandID: "cmd-config-option-forward", ThreadID: threadID, OptionID: "provider-option", Value: false})
}

func TestEngineRejectsApprovalRespondForUnknownResolvedOrUnofferedOption(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	events := observeEvents(t, engine)
	threadID := ThreadID("thread-approval-option-validation")
	requestID := ApprovalID("approval-1")
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "cmd-create-approval-option-validation", ThreadID: threadID, Title: "Thread"})
	approval := &ApprovalEvent{RequestID: string(requestID), Options: []provider.ApprovalOption{{ID: "allow", Name: "Allow"}, {ID: "reject", Name: "Reject"}}}
	mustAppend(t, engine, EventInput{Type: EventThreadApprovalOpened, ThreadID: threadID, Payload: EventPayload{Approval: approval}})

	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadApprovalRespond, CommandID: "cmd-invalid-approval-decision", ThreadID: threadID, RequestID: requestID, Decision: "approve"}); err == nil {
		t.Fatal("thread.approval.respond invalid decision err = nil, want rejection")
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadApprovalRespond, CommandID: "cmd-unknown-approval-response", ThreadID: threadID, RequestID: "missing", Decision: provider.ApprovalDecisionAccept}); err == nil {
		t.Fatal("thread.approval.respond unknown request err = nil, want rejection")
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadApprovalRespond, CommandID: "cmd-bad-approval-option", ThreadID: threadID, RequestID: requestID, Decision: provider.ApprovalDecisionAccept, OptionID: "allow-typo"}); err == nil {
		t.Fatal("thread.approval.respond unoffered optionId err = nil, want rejection")
	}
	if recorded := events.matching("", 0); len(recorded) != 2 {
		t.Fatalf("events after rejected approval responses = %#v, want only create/open", recorded)
	}
	thread, ok := engine.Thread(threadID)
	if !ok || len(thread.Timeline.Approvals()) != 1 || thread.Timeline.Approvals()[0].Decision != "" || thread.Timeline.Approvals()[0].OptionID != "" {
		t.Fatalf("approval after rejected responses = %#v, want no dirty response", thread.Timeline.Approvals())
	}

	mustAppend(t, engine, EventInput{Type: EventThreadApprovalResolved, ThreadID: threadID, Payload: EventPayload{Approval: &ApprovalEvent{RequestID: string(requestID), Decision: provider.ApprovalDecisionAccept, OptionID: "allow"}}})
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadApprovalRespond, CommandID: "cmd-stale-approval-response", ThreadID: threadID, RequestID: requestID, Decision: provider.ApprovalDecisionAccept}); err == nil {
		t.Fatal("thread.approval.respond resolved request err = nil, want rejection")
	}
	if recorded := events.matching("", 0); len(recorded) != 3 {
		t.Fatalf("events after stale approval response = %#v, want create/open/resolve", recorded)
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
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "cmd-create-approval-reopen", ThreadID: threadID, Title: "Thread"})
	options := []provider.ApprovalOption{{ID: "allow", Name: "Allow"}, {ID: "reject", Name: "Reject"}}
	mustAppend(t, engine, EventInput{Type: EventThreadApprovalOpened, ThreadID: threadID, Payload: EventPayload{Approval: &ApprovalEvent{RequestID: string(requestID), TurnID: "turn-1", Options: options}}})
	mustAppend(t, engine, EventInput{Type: EventThreadApprovalResolved, ThreadID: threadID, Payload: EventPayload{Approval: &ApprovalEvent{RequestID: string(requestID), Decision: provider.ApprovalDecisionDecline, OptionID: "reject"}}})

	// The agent retried the tool call: the same request id opens again with
	// fresh options.
	reopenedOptions := []provider.ApprovalOption{{ID: "allow-2", Name: "Allow"}, {ID: "reject-2", Name: "Reject"}}
	mustAppend(t, engine, EventInput{Type: EventThreadApprovalOpened, ThreadID: threadID, Payload: EventPayload{Approval: &ApprovalEvent{RequestID: string(requestID), TurnID: "turn-1", Options: reopenedOptions}}})
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
	mustDispatch(t, engine, Command{Type: CommandThreadApprovalRespond, CommandID: "cmd-respond-approval-reopen", ThreadID: threadID, RequestID: requestID, Decision: provider.ApprovalDecisionAccept, OptionID: "allow-2"})
}

func TestTimelinePreservesFirstAppearanceAcrossUpserts(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-timeline-sequence")
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "create-timeline-sequence", ThreadID: threadID, Title: "Thread"})

	mustAppend(t, engine, EventInput{Type: EventThreadMessageSent, ThreadID: threadID, Payload: EventPayload{MessageID: "message-1", Role: MessageRoleAssistant, Text: "hel"}})
	mustAppend(t, engine, EventInput{Type: EventThreadItemUpserted, ThreadID: threadID, Payload: EventPayload{Item: &Item{ID: "item-1", Kind: provider.ItemKindCommandExecution, Status: provider.ItemStatusInProgress}}})
	mustAppend(t, engine, EventInput{Type: EventThreadMessageSent, ThreadID: threadID, Payload: EventPayload{MessageID: "message-1", Role: MessageRoleAssistant, Text: "lo"}})
	mustAppend(t, engine, EventInput{Type: EventThreadItemUpserted, ThreadID: threadID, Payload: EventPayload{Item: &Item{ID: "item-1", Status: provider.ItemStatusCompleted}}})

	thread, _ := engine.Thread(threadID)
	if len(thread.Timeline) != 2 || thread.Timeline[0].Kind != TimelineEntryMessage || thread.Timeline[1].Kind != TimelineEntryItem {
		t.Fatalf("timeline = %#v, want message, item", thread.Timeline)
	}
	if thread.Timeline[0].Message.Text != "hello" || thread.Timeline[1].Item.Status != provider.ItemStatusCompleted || thread.Timeline[1].Item.Kind != provider.ItemKindCommandExecution {
		t.Fatalf("timeline updates were not applied in place: %#v", thread.Timeline)
	}
}

func TestStoppedFactDoesNotOverwriteCompletedTurnStopReason(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	events := observeEvents(t, engine)
	threadID := ThreadID("thread-completion-before-stop")
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "cmd-create-completion-before-stop", ThreadID: threadID, ProviderInstanceID: "prov-a"})
	mustDispatch(t, engine, Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-completion-before-stop", ThreadID: threadID, Message: &CommandMessage{Text: "hello"}})
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
	recorded := events.matching(threadID, result.Sequence-1)
	if len(recorded) != 1 || recorded[0].Payload.StopReason != "" {
		t.Fatalf("stopped event = %#v, want no stale cancelled reason", recorded)
	}
}

func TestEngineAcceptsAttachmentOnlyTurnStartTaggedWithTurnID(t *testing.T) {
	engine := NewEngine()
	threadID := ThreadID("thread-attachment-only")
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "cmd-create-attachment-only", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"})
	mustDispatch(t, engine, Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-attachment-only", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-image", Attachments: []provider.Attachment{{Kind: "image", Data: "base64", MimeType: "image/png"}}}, CreatedAt: time.Now()})
	snapshot, err := engine.SubscribeThread(SubscribeThreadInput{ThreadID: threadID})
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	thread := snapshot.Snapshot.Thread
	if messages := thread.Timeline.Messages(); len(messages) != 1 || len(messages[0].Attachments) != 1 || thread.LatestTurn == nil || messages[0].TurnID != thread.LatestTurn.ID {
		t.Fatalf("thread = %#v, want attachment-only user message tagged with the latest turn id", thread)
	}
}

func TestEngineRejectsStaleTurnInterrupt(t *testing.T) {
	engine := NewEngine()
	threadID := ThreadID("thread-stale-interrupt")
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "cmd-create-stale-interrupt", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"})
	binding := &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", Status: SessionStatusReady, UpdatedAt: time.Now()}
	mustAppend(t, engine, EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: binding}})
	mustDispatch(t, engine, Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-stale-old", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-old", Text: "old"}, CreatedAt: time.Now()})
	thread, _ := engine.Thread(threadID)
	oldTurnID := thread.LatestTurn.ID
	mustDispatch(t, engine, Command{Type: CommandThreadTurnInterrupt, CommandID: "cmd-interrupt-stale-old", ThreadID: threadID, TurnID: oldTurnID, CreatedAt: time.Now()})
	mustAppend(t, engine, EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", Status: SessionStatusInterrupted, UpdatedAt: time.Now()}}})
	mustDispatch(t, engine, Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-stale-new", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-new", Text: "new"}, CreatedAt: time.Now()})
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

// Until the provider session binds, preparation blocks every command that
// would race the provider start; a rename still applies.
func TestEngineRejectsSessionChangesWhilePreparing(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-preparing")
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "create-preparing", ThreadID: threadID, ProviderInstanceID: "provider-a", ModelSelection: &provider.ModelSelection{Model: "model-a"}})
	mustDispatch(t, engine, Command{Type: CommandThreadSessionPrepare, CommandID: "prepare", ThreadID: threadID})

	for name, command := range map[string]Command{
		"provider switch": {Type: CommandThreadMetaUpdate, ProviderInstanceID: "provider-b"},
		"model switch":    {Type: CommandThreadMetaUpdate, ModelSelection: &provider.ModelSelection{Model: "model-b"}},
		"turn start":      {Type: CommandThreadTurnStart, Message: &CommandMessage{Text: "hello"}},
		"session stop":    {Type: CommandThreadSessionStop},
		"second prepare":  {Type: CommandThreadSessionPrepare},
	} {
		command.CommandID, command.ThreadID = CommandID("during-prepare-"+name), threadID
		if _, err := engine.Dispatch(context.Background(), command); err == nil || !strings.Contains(err.Error(), "prepar") {
			t.Fatalf("%s during preparation err = %v, want preparing rejection", name, err)
		}
	}
	mustDispatch(t, engine, Command{Type: CommandThreadMetaUpdate, CommandID: "rename-during-prepare", ThreadID: threadID, Title: "Renamed"})
	thread, _ := engine.Thread(threadID)
	if thread.Title != "Renamed" || thread.ProviderInstanceID != "provider-a" || thread.ModelSelection.Model != "model-a" || thread.LatestTurn != nil || len(thread.Timeline) != 0 {
		t.Fatalf("thread after preparation guards = %#v, want renamed with the original selection and no turn", thread)
	}
}

func TestEngineDeduplicatesCommandID(t *testing.T) {
	engine := NewEngine()
	threadID := ThreadID("thread-dedupe")
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "cmd-create-dedupe", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"})
	first := mustDispatch(t, engine, Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-dedupe", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-1", Text: "hello"}, CreatedAt: time.Now()})
	second := mustDispatch(t, engine, Command{Type: CommandThreadTurnStart, CommandID: "cmd-turn-dedupe", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-duplicate", Text: "hello again"}, CreatedAt: time.Now()})
	if second.Sequence != first.Sequence {
		t.Fatalf("duplicate sequence = %d, want %d", second.Sequence, first.Sequence)
	}
	snapshot, err := engine.SubscribeThread(SubscribeThreadInput{ThreadID: threadID})
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	if len(snapshot.Snapshot.Thread.Timeline.Messages()) != 1 || snapshot.Snapshot.Thread.Timeline.Messages()[0].ID != "msg-1" {
		t.Fatalf("messages = %#v, want duplicate command ignored", snapshot.Snapshot.Thread.Timeline.Messages())
	}
}

func TestEngineCloseRejectsQueuedRequests(t *testing.T) {
	engine := NewEngine()
	entered := make(chan struct{})
	release := make(chan struct{})
	engine.OnEvent(func(event Event) {
		if event.Type == EventThreadCreated && event.ThreadID() == "thread-blocking" {
			close(entered)
			<-release
		}
	})

	firstDone := make(chan error, 1)
	go func() {
		_, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, ThreadID: "thread-blocking"})
		firstDone <- err
	}()
	<-entered
	queuedDone := make(chan error, 1)
	go func() {
		_, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, ThreadID: "thread-queued"})
		queuedDone <- err
	}()
	engine.Close()
	close(release)
	if err := <-firstDone; err != nil && !strings.Contains(err.Error(), "closed") {
		t.Fatalf("in-flight dispatch error = %v, want success or shutdown error", err)
	}
	if err := <-queuedDone; err == nil || !strings.Contains(err.Error(), "closed") {
		t.Fatalf("queued dispatch error = %v, want engine closed", err)
	}
	if _, ok := engine.Thread("thread-queued"); ok {
		t.Fatal("queued request mutated projection after Close")
	}
}

func TestEngineSurvivesPanickingListener(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	engine.OnEvent(func(Event) { panic("listener boom") })
	threadID := ThreadID("thread-panic-recovery")
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "cmd-panic-create", ThreadID: threadID, Title: "Thread"})
	// The worker must still process commands after the listener panicked.
	mustDispatch(t, engine, Command{Type: CommandThreadMetaUpdate, CommandID: "cmd-panic-meta", ThreadID: threadID, Title: "Still alive"})
	if thread, ok := engine.Thread(threadID); !ok || thread.Title != "Still alive" {
		t.Fatalf("thread = %#v, want projection updated after listener panic", thread)
	}
}

// ThreadListVisible drives sidebar fan-out and ThreadMetadataMayChange drives
// metadata-table writes; per-delta streaming events must stay out of both.
func TestThreadListAndMetadataPredicates(t *testing.T) {
	for _, tc := range []struct {
		name             string
		event            Event
		visible, durable bool
	}{
		{"user message", Event{Type: EventThreadMessageSent, Payload: EventPayload{Role: MessageRoleUser}}, true, true},
		{"assistant message", Event{Type: EventThreadMessageSent, Payload: EventPayload{Role: MessageRoleAssistant}}, false, false},
		{"reasoning item", Event{Type: EventThreadItemUpserted, Payload: EventPayload{Item: &Item{Kind: provider.ItemKindReasoning}}}, false, false},
		{"thread metadata", Event{Type: EventThreadMetaUpdated}, true, true},
		{"session status", Event{Type: EventThreadSessionStatusSet, Payload: EventPayload{Session: &SessionBinding{Status: SessionStatusRunning}}}, true, false},
		{"config options with model", Event{Type: EventThreadConfigOptionsUpdated, Payload: EventPayload{ModelSelection: &provider.ModelSelection{Model: "model-1"}}}, false, true},
		{"config options without model", Event{Type: EventThreadConfigOptionsUpdated}, false, false},
	} {
		if got := ThreadListVisible(tc.event); got != tc.visible {
			t.Errorf("%s: ThreadListVisible = %v, want %v", tc.name, got, tc.visible)
		}
		if got := ThreadMetadataMayChange(tc.event); got != tc.durable {
			t.Errorf("%s: ThreadMetadataMayChange = %v, want %v", tc.name, got, tc.durable)
		}
	}
}

func TestProjectionUpdatedAtTracksUserMessageActivity(t *testing.T) {
	projection := NewProjection()
	threadID := ThreadID("thread-recency")
	base := time.Date(2025, time.January, 2, 3, 4, 5, 0, time.UTC)
	at := func(seconds int) time.Time { return base.Add(time.Duration(seconds) * time.Second) }
	apply := func(seconds int, eventType EventType, payload EventPayload) {
		payload.ThreadID = threadID
		projection.Apply(Event{Type: eventType, OccurredAt: at(seconds), Payload: payload})
	}
	assertUpdatedAt := func(want time.Time) {
		t.Helper()
		if thread, ok := projection.Thread(threadID); !ok || !thread.UpdatedAt.Equal(want) {
			t.Fatalf("UpdatedAt = %v, want %v", thread.UpdatedAt, want)
		}
	}
	apply(0, EventThreadCreated, EventPayload{})
	assertUpdatedAt(at(0))
	apply(10, EventThreadMessageSent, EventPayload{MessageID: "message-1", Role: MessageRoleUser})
	assertUpdatedAt(at(10))

	// Neither an out-of-order user message nor any other activity moves recency.
	apply(5, EventThreadMessageSent, EventPayload{MessageID: "message-older", Role: MessageRoleUser})
	apply(20, EventThreadTurnStartRequested, EventPayload{TurnID: "turn-1"})
	apply(30, EventThreadSessionStatusSet, EventPayload{Session: &SessionBinding{Status: SessionStatusRunning, ActiveTurnID: "turn-1"}})
	apply(40, EventThreadMessageSent, EventPayload{MessageID: "assistant-1", Role: MessageRoleAssistant})
	apply(50, EventThreadSessionStatusSet, EventPayload{Session: &SessionBinding{Status: SessionStatusReady}})
	apply(60, EventThreadMetaUpdated, EventPayload{Title: "Renamed"})
	apply(70, EventThreadTurnInterruptConfirmed, EventPayload{TurnID: "turn-1"})
	assertUpdatedAt(at(10))

	apply(80, EventThreadMessageSent, EventPayload{MessageID: "message-2", Role: MessageRoleUser})
	assertUpdatedAt(at(80))
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
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "cmd-locked-create", ThreadID: threadID, Title: "Thread"})

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
		if _, err := engine.SubscribeThread(SubscribeThreadInput{ThreadID: threadID}); err != nil {
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

// TestEnginePreMutationPanicIsRecoverableWithoutFatal pins the other half of
// the panic policy: a panic BEFORE anything was appended (decider/validation
// code) is converted into a command error, does NOT terminate the daemon, and
// leaves the engine fully usable.
func TestEnginePreMutationPanicIsRecoverableWithoutFatal(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	violations := recordInvariantViolations(t, engine)

	_, err := recoverEngineOperation("test pre-mutation decider", func() (DispatchResult, error) {
		return DispatchResult{}, engine.withLockNotify(func(appendEvent func(Event) Event) error {
			panic("decider boom")
		})
	})
	if err == nil || !strings.Contains(err.Error(), "decider boom") {
		t.Fatalf("pre-mutation panic err = %v, want recovered decider boom", err)
	}
	select {
	case violation := <-violations:
		t.Fatalf("violation = %v, want none: pre-mutation panics must stay recoverable", violation)
	default:
	}

	// Mutex released, worker healthy.
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "cmd-pre-panic", ThreadID: "thread-pre-panic", Title: "Alive"})
}

// TestSessionStatusEventPayloadIsTheCompleteClientState is the client
// conformance test for the thread.session-status-set contract: the event's
// session payload IS the complete new session state, and clients must REPLACE
// their cached binding with it — no field merging. It pins
// that (a) the engine-derived payload byte-equals the server projection after
// every status event, (b) metadata set between status events (slash commands,
// config options, token usage) is carried forward in the next payload, so
// replacement loses nothing, and
// (c) a provider switch emits a payload WITHOUT the old provider's metadata,
// so replacement clears it — the case where the old merge rule left clients
// permanently out of sync with fresh snapshots.
func TestSessionStatusEventPayloadIsTheCompleteClientState(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()

	threadID := ThreadID("thread-session-replace")
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "cmd-replace-create", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "prov-a"})

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
	mustDispatch(t, engine, Command{Type: CommandThreadTurnStart, CommandID: "cmd-replace-turn", ThreadID: threadID, Message: &CommandMessage{Text: "hello"}})
	thread, ok := engine.Thread(threadID)
	if !ok || thread.LatestTurn == nil {
		t.Fatal("turn.start did not create a running turn")
	}
	turnID := thread.LatestTurn.ID
	appendUpdate("bind prov-a", sessionUpdate{Kind: sessionUpdateBound, TurnID: turnID, Binding: &SessionBinding{ProviderInstanceID: "prov-a", ProviderName: "Provider A", Driver: "acp"}})
	snapshotMustEqualLastPayload("after bind")

	// 2. The agent publishes session metadata BETWEEN status events.
	for _, input := range []EventInput{
		{Type: EventThreadSlashCommandsUpdated, Payload: EventPayload{SlashCommands: []provider.SlashCommand{{Name: "compact"}}}},
		{Type: EventThreadConfigOptionsUpdated, Payload: EventPayload{ConfigOptions: []provider.ConfigOption{{ID: "effort", CurrentValue: "deep"}}}},
		{Type: EventThreadTokenUsageUpdated, Payload: EventPayload{TokenUsage: &provider.TokenUsage{UsedTokens: 4242}}},
	} {
		input.ThreadID = threadID
		mustAppend(t, engine, input)
	}

	// 3. The settle payload must carry that metadata forward: replace
	// semantics lose nothing that the server kept.
	appendUpdate("settle turn", sessionUpdate{Kind: sessionUpdateTurnSettled, TurnID: turnID, TurnState: provider.RuntimeTurnCompleted})
	settled := snapshotMustEqualLastPayload("after settle")
	for _, want := range []string{`"compact"`, `"deep"`, `4242`} {
		if !strings.Contains(string(settled), want) {
			t.Fatalf("settle payload = %s, want %s carried forward for replace semantics", settled, want)
		}
	}

	// 4. Switching providers emits a fresh binding WITHOUT provider A's
	// metadata; replacement clears it. (The old documented merge rule kept
	// the stale slash commands here — the client-divergence bug.)
	appendUpdate("bind prov-b", sessionUpdate{Kind: sessionUpdateBound, Binding: &SessionBinding{ProviderInstanceID: "prov-b", ProviderName: "Provider B", Driver: "acp"}})
	switched := snapshotMustEqualLastPayload("after provider switch")
	if strings.Contains(string(switched), `"compact"`) || strings.Contains(string(switched), "Provider A") {
		t.Fatalf("provider-switch payload = %s, want no provider-A metadata", switched)
	}
}

// TestProviderSelectionEventsCarryTheCompleteAggregate is the client
// conformance test for selection events: when an event carries
// providerInstanceId it is the COMPLETE new selection — clients replace both
// providerInstanceId and modelSelection with the event's values (absent
// modelSelection = cleared); an event with only modelSelection replaces just
// the model choice. The provider-only switch step is the case a patch rule got
// wrong: the event omits modelSelection, and replacing must clear the old
// provider's model instead of keeping it. The thread's selection stays the
// desired one even when a provider session binds to a different instance, and
// a later provider switch clears that stale session.
func TestProviderSelectionEventsCarryTheCompleteAggregate(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-selection-aggregate")

	// Client-side fold, applying exactly the documented rule.
	var clientInstance provider.InstanceID
	var clientSelection *provider.ModelSelection
	var lastEvent Event
	engine.OnEvent(func(event Event) {
		if event.ThreadID() != threadID {
			return
		}
		lastEvent = event
		switch {
		case event.Payload.ProviderInstanceID != "":
			clientInstance = event.Payload.ProviderInstanceID
			clientSelection = cloneModelSelection(event.Payload.ModelSelection)
		case event.Payload.ModelSelection != nil:
			clientSelection = cloneModelSelection(event.Payload.ModelSelection)
		}
	})

	step := func(name string, command Command, wantInstance provider.InstanceID, wantModel string) Thread {
		t.Helper()
		command.CommandID = CommandID("cmd-agg-" + name)
		command.ThreadID = threadID
		if command.Type == "" {
			command.Type = CommandThreadMetaUpdate
		}
		mustDispatch(t, engine, command)
		thread, ok := engine.Thread(threadID)
		if !ok {
			t.Fatalf("%s: thread not found", name)
		}
		if thread.ProviderInstanceID != clientInstance || !selectionEqual(thread.ModelSelection, clientSelection) {
			t.Fatalf("%s: client fold (%q, %#v) diverges from snapshot (%q, %#v)", name, clientInstance, clientSelection, thread.ProviderInstanceID, thread.ModelSelection)
		}
		gotModel := ""
		if thread.ModelSelection != nil {
			gotModel = thread.ModelSelection.Model
		}
		if thread.ProviderInstanceID != wantInstance || gotModel != wantModel {
			t.Fatalf("%s: selection = (%q, %#v), want (%q, %q)", name, thread.ProviderInstanceID, thread.ModelSelection, wantInstance, wantModel)
		}
		if entry, ok := engine.ThreadListEntry(threadID); !ok || entry.ProviderInstanceID != wantInstance {
			t.Fatalf("%s: thread list entry = %#v, want provider %q", name, entry, wantInstance)
		}
		return thread
	}

	step("create", Command{Type: CommandThreadCreate, Title: "Thread", ProviderInstanceID: "provider-a", ModelSelection: &provider.ModelSelection{Model: "a-model"}}, "provider-a", "a-model")
	thread := step("model-only", Command{ModelSelection: &provider.ModelSelection{Model: "a-model-2", Options: json.RawMessage(`{"effort":"high"}`)}}, "provider-a", "a-model-2")
	if string(thread.ModelSelection.Options) != `{"effort":"high"}` {
		t.Fatalf("model-only options = %s", thread.ModelSelection.Options)
	}
	// The critical step: provider-only switch. The event must carry the new
	// instance with NO modelSelection, and replacement must clear the model.
	step("provider-only", Command{ProviderInstanceID: "provider-b"}, "provider-b", "")

	// A session bound to another instance does not rewrite the desired selection.
	mustAppend(t, engine, EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "runtime-binding", Status: SessionStatusReady, UpdatedAt: time.Now()}}})
	thread = step("title-only", Command{Title: "Renamed"}, "provider-b", "")
	if thread.Session == nil || thread.Session.ProviderInstanceID != "runtime-binding" {
		t.Fatalf("session = %#v, want runtime binding stored on the session", thread.Session)
	}
	thread = step("provider-and-model", Command{ProviderInstanceID: "provider-c", ModelSelection: &provider.ModelSelection{Model: "opus"}}, "provider-c", "opus")
	if thread.Session != nil || !lastEvent.Payload.SessionCleared {
		t.Fatalf("session after provider switch = %#v (event %#v), want cleared", thread.Session, lastEvent.Payload)
	}
	step("turn-start", Command{Type: CommandThreadTurnStart, ProviderInstanceID: "provider-d", ModelSelection: &provider.ModelSelection{Model: "haiku"}, Message: &CommandMessage{Text: "hello"}}, "provider-d", "haiku")
}
