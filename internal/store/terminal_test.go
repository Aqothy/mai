package store

import (
	"testing"
	"time"
)

func TestTerminalStoreRoundTrip(t *testing.T) {
	s := openTestStore(t)

	created := time.Date(2026, 8, 5, 10, 0, 0, 0, time.UTC)
	meta := TerminalMeta{
		TerminalID: "terminal-1",
		Title:      "Build",
		Cwd:        "/projects/maid",
		CreatedAt:  created,
		UpdatedAt:  created,
	}
	if err := s.UpsertTerminal(meta); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	terminals, err := s.ListTerminals()
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(terminals) != 1 {
		t.Fatalf("terminals = %d, want 1", len(terminals))
	}
	got := terminals[0]
	if got.TerminalID != meta.TerminalID || got.Title != meta.Title || got.Cwd != meta.Cwd {
		t.Fatalf("round trip mismatch: %+v", got)
	}
	if !got.CreatedAt.Equal(created) || !got.UpdatedAt.Equal(created) {
		t.Fatalf("timestamps mismatch: %+v", got)
	}

	// Rename updates in place.
	meta.Title = "Deploy"
	meta.UpdatedAt = created.Add(time.Hour)
	if err := s.UpsertTerminal(meta); err != nil {
		t.Fatalf("rename upsert: %v", err)
	}
	terminals, _ = s.ListTerminals()
	if len(terminals) != 1 || terminals[0].Title != "Deploy" {
		t.Fatalf("rename not persisted: %+v", terminals)
	}

	if err := s.DeleteTerminal("terminal-1"); err != nil {
		t.Fatalf("delete: %v", err)
	}
	terminals, _ = s.ListTerminals()
	if len(terminals) != 0 {
		t.Fatalf("delete left %d rows", len(terminals))
	}
	// Deleting an unknown terminal is a no-op, not an error.
	if err := s.DeleteTerminal("terminal-1"); err != nil {
		t.Fatalf("repeat delete: %v", err)
	}
}

func TestListTerminalsOrdersByUpdatedAtDescending(t *testing.T) {
	s := openTestStore(t)
	base := time.Date(2026, 8, 5, 10, 0, 0, 0, time.UTC)

	for _, meta := range []TerminalMeta{
		{TerminalID: "t-old", Cwd: "/a", CreatedAt: base, UpdatedAt: base},
		{TerminalID: "t-new", Cwd: "/b", CreatedAt: base, UpdatedAt: base.Add(2 * time.Hour)},
		// Same updated_at as t-old: terminal_id breaks the tie for a
		// deterministic order.
		{TerminalID: "t-also-old", Cwd: "/c", CreatedAt: base, UpdatedAt: base},
	} {
		if err := s.UpsertTerminal(meta); err != nil {
			t.Fatalf("upsert %s: %v", meta.TerminalID, err)
		}
	}

	terminals, err := s.ListTerminals()
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	var order []string
	for _, meta := range terminals {
		order = append(order, meta.TerminalID)
	}
	want := []string{"t-new", "t-also-old", "t-old"}
	for i := range want {
		if order[i] != want[i] {
			t.Fatalf("order = %v, want %v", order, want)
		}
	}
}
