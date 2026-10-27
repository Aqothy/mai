package codexapp

import (
	"context"
	"encoding/json"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// TestLiveHistoryPagination reads an explicitly supplied disposable history
// fixture. It sends no model turn, deletes no history, and resumes only the
// fixture's native thread. Other histories are listed only when separately
// opted in; their contents and identifiers are never logged.
func TestLiveHistoryPagination(t *testing.T) {
	fixturePath := os.Getenv("CODEX_HISTORY_QA_FIXTURE")
	if os.Getenv("CODEX_LIVE_TEST") != "1" || fixturePath == "" {
		t.Skip("set CODEX_LIVE_TEST=1 and CODEX_HISTORY_QA_FIXTURE for disposable history QA")
	}
	var fixture struct {
		Cwd      string `json:"cwd"`
		ThreadID string `json:"threadId"`
		Users    []struct {
			Text string `json:"text"`
			Data string `json:"data"`
		} `json:"users"`
		Assistants []string `json:"assistants"`
	}
	data, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(fixture.Cwd) == "" || fixture.Cwd == "/" || fixture.ThreadID == "" || len(fixture.Users) == 0 {
		t.Fatal("fixture requires a scoped working directory, native thread and expected messages")
	}
	binary := os.Getenv("CODEX_LIVE_BINARY")
	if binary == "" {
		t.Fatal("select CODEX_LIVE_BINARY explicitly")
	}
	config, err := json.Marshal(Config{Command: []string{binary, "app-server"}})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	instance, err := OpenInstance(ctx, provider.InstanceSpec{InstanceID: "codex-history-qa", Config: config}, provider.Host{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = instance.Close() })
	sessions, err := instance.Sessions(ctx, fixture.Cwd)
	if err != nil {
		t.Fatalf("scoped listing: %v", err)
	}
	var listedIDs []string
	for _, session := range sessions {
		listedIDs = append(listedIDs, session.SessionID)
	}
	if !slices.Contains(listedIDs, fixture.ThreadID) {
		t.Fatal("fixture thread missing from scoped listing")
	}
	var pagedIDs []string
	cursor := ""
	seenCursors := make(map[string]bool)
	pages := 0
	for {
		params := map[string]any{"limit": 1, "cwd": fixture.Cwd, "sortKey": "updated_at", "sortDirection": "desc"}
		if cursor != "" {
			params["cursor"] = cursor
		}
		var response threadListResponse
		if err := instance.rpc.call(ctx, "thread/list", params, &response); err != nil {
			t.Fatalf("one-item page %d: %v", pages+1, err)
		}
		pages++
		for _, thread := range response.Data {
			pagedIDs = append(pagedIDs, thread.ID)
		}
		if response.NextCursor == nil || *response.NextCursor == "" {
			break
		}
		cursor = *response.NextCursor
		if seenCursors[cursor] {
			t.Fatal("repeated history cursor")
		}
		seenCursors[cursor] = true
	}
	if pages < 2 || !slices.Equal(pagedIDs, listedIDs) {
		t.Fatalf("one-item pagination disagrees with adapter listing: pages=%d, paged=%d, listed=%d", pages, len(pagedIDs), len(listedIDs))
	}
	t.Logf("scoped history: %d sessions, %d one-item pages, same complete order", len(sessions), pages)
	if os.Getenv("CODEX_HISTORY_LIST_ALL") == "1" {
		all, err := instance.Sessions(ctx, "")
		if err != nil {
			t.Fatalf("full listing: %v", err)
		}
		seen := make(map[string]bool)
		for _, session := range all {
			if session.SessionID == "" || seen[session.SessionID] {
				t.Fatal("full listing contains an empty or duplicated session id")
			}
			seen[session.SessionID] = true
		}
		if len(all) <= 100 {
			t.Fatal("full listing did not exercise the adapter's 100-item page boundary")
		}
		t.Logf("actual adapter pagination: %d unique sessions across its 100-item boundary; metadata not logged", len(all))
	}
	page, err := instance.History(ctx, fixture.ThreadID, provider.Workspace{Cwd: fixture.Cwd}, "")
	if err != nil {
		t.Fatalf("fixture history: %v", err)
	}
	var users []provider.Entry
	var assistants []string
	completed := 0
	for _, turn := range page.Turns {
		if turn.State == provider.TurnCompleted {
			completed++
		}
		for _, entry := range turn.Entries {
			switch entry.Kind {
			case provider.ItemKindUserMessage:
				users = append(users, entry)
			case provider.ItemKindAssistantMessage:
				assistants = append(assistants, entry.Text)
			}
		}
	}
	if len(users) != len(fixture.Users) || completed != len(fixture.Users) || !slices.Equal(assistants, fixture.Assistants) {
		t.Fatalf("history lost or changed messages/turns: users=%d, assistants=%d, completed=%d", len(users), len(assistants), completed)
	}
	for i, expected := range fixture.Users {
		if users[i].Text != expected.Text || len(users[i].Attachments) != 1 || users[i].Attachments[0].Data != expected.Data {
			t.Fatalf("history user message %d changed text or image bytes", i)
		}
	}
	t.Logf("fixture history: %d completed turns; exact user text, images and assistant replies preserved", completed)
}
