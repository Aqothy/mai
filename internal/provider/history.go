package provider

// HistoryBuilder folds a session's events, as an adapter would emit them
// live, into the turns History returns. Adapters that replay by mapping native
// records through their live mapping use it, so replay equals live by
// construction.
type HistoryBuilder struct {
	turns []HistoryTurn
	// at locates an entry by turn and ref.
	at map[string]map[string]int
	// turnAt locates a turn by ref.
	turnAt map[string]int
}

// Add folds one event. Events other than turn and entry events are ignored.
func (b *HistoryBuilder) Add(event Event) {
	switch body := event.Body.(type) {
	case TurnStarted:
		b.turn(body.Turn, event)
	case TurnSettled:
		turn := b.turn(body.Turn, event)
		turn.State, turn.StopReason, turn.Error = body.State, body.StopReason, body.Error
	case EntryUpserted:
		turn := b.turn(body.Entry.Turn, event)
		entries := b.at[turn.Ref]
		if index, ok := entries[body.Entry.Ref]; ok {
			turn.Entries[index] = body.Entry
			return
		}
		entries[body.Entry.Ref] = len(turn.Entries)
		turn.Entries = append(turn.Entries, body.Entry)
	case TextAppended:
		turn := b.turn(body.Turn, event)
		if index, ok := b.at[turn.Ref][body.Entry]; ok {
			turn.Entries[index].Text += body.Text
		}
	}
}

func (b *HistoryBuilder) turn(ref string, event Event) *HistoryTurn {
	if b.turnAt == nil {
		b.turnAt = make(map[string]int)
		b.at = make(map[string]map[string]int)
	}
	if index, ok := b.turnAt[ref]; ok {
		return &b.turns[index]
	}
	b.turnAt[ref] = len(b.turns)
	b.at[ref] = make(map[string]int)
	b.turns = append(b.turns, HistoryTurn{Ref: ref, StartedAt: event.At, State: TurnRunning})
	return &b.turns[len(b.turns)-1]
}

// Turns are the turns folded so far, oldest first.
func (b *HistoryBuilder) Turns() []HistoryTurn { return b.turns }

// After is the page of turns after the turn whose ref is marker: all of them
// with Reset when the marker is set but unknown. Next is the last settled
// turn's ref, so a turn still running is read again in full.
func After(turns []HistoryTurn, marker Marker) HistoryPage {
	page := HistoryPage{Turns: turns, Next: marker}
	if marker != "" {
		page.Reset, page.Next = true, ""
		for index, turn := range turns {
			if turn.Ref == string(marker) {
				page.Turns, page.Reset, page.Next = turns[index+1:], false, marker
				break
			}
		}
	}
	for _, turn := range page.Turns {
		if !turn.State.Settled() {
			break
		}
		page.Next = Marker(turn.Ref)
	}
	return page
}
