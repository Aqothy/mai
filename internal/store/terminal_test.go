package store

import (
	"slices"
	"testing"
	"time"
)

func TestTerminalStoreRoundTripsAndOrdersByRecency(t *testing.T) {
	s := openTestStore(t)
	base := time.Date(2026, 8, 5, 10, 0, 0, 0, time.UTC)

	for _, meta := range []TerminalMeta{
		{TerminalID: "t-old", Title: "Build", Cwd: "/a", CreatedAt: base, UpdatedAt: base},
		{TerminalID: "t-new", Cwd: "/b", CreatedAt: base, UpdatedAt: base.Add(2 * time.Hour)},
		// Same updated_at as t-old: terminal_id breaks the tie for a
		// deterministic order.
		{TerminalID: "t-also-old", Cwd: "/c", CreatedAt: base, UpdatedAt: base},
		{TerminalID: "t-gone", Cwd: "/d", CreatedAt: base, UpdatedAt: base},
		// Renaming updates the row in place.
		{TerminalID: "t-old", Title: "Deploy", Cwd: "/a", CreatedAt: base, UpdatedAt: base},
	} {
		if err := s.UpsertTerminal(meta); err != nil {
			t.Fatalf("upsert %s: %v", meta.TerminalID, err)
		}
	}
	// Deleting is idempotent.
	for range 2 {
		if err := s.DeleteTerminal("t-gone"); err != nil {
			t.Fatalf("delete: %v", err)
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
	if !slices.Equal(order, []string{"t-new", "t-also-old", "t-old"}) {
		t.Fatalf("order = %v, want t-new, t-also-old, t-old", order)
	}
	if got := terminals[2]; got != (TerminalMeta{TerminalID: "t-old", Title: "Deploy", Cwd: "/a", CreatedAt: got.CreatedAt, UpdatedAt: got.UpdatedAt}) || !got.CreatedAt.Equal(base) || !got.UpdatedAt.Equal(base) {
		t.Fatalf("renamed terminal = %+v", got)
	}
}
