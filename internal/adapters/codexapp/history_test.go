package codexapp

import (
	"encoding/json"
	"fmt"
	"io"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

func TestHistoryListingRejectsIncompleteResults(t *testing.T) {
	for _, tc := range []struct {
		name       string
		secondPage string
		wantError  string
	}{
		{"repeated cursor", `"result":{"data":[],"nextCursor":"page-two"}`, "repeated cursor"},
		{"unsupported operation", `"error":{"code":-32601,"message":"history operation unsupported"}`, "-32601: history operation unsupported"},
		{"malformed page", `"result":{"data":"corrupt"}`, "cannot unmarshal"},
		{"transport loss", "", "EOF"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			input, server := io.Pipe()
			writes := &capturedLineWriter{lines: make(chan []byte, 4)}
			client := newRPCClient(input, writes)
			go client.run()
			t.Cleanup(func() { _ = server.Close(); _ = input.Close() })
			type result struct {
				sessions []provider.SessionSummary
				err      error
			}
			finished := make(chan result, 1)
			ctx := testContext(t)
			go func() {
				sessions, err := (&Instance{rpc: client}).Sessions(ctx, "/history")
				finished <- result{sessions, err}
			}()
			for page := 0; page < 2; page++ {
				var line []byte
				select {
				case line = <-writes.lines:
				case <-ctx.Done():
					t.Fatal("history request did not arrive")
				}
				var request struct {
					ID     json.RawMessage `json:"id"`
					Method string          `json:"method"`
					Params struct {
						Cwd    string `json:"cwd"`
						Cursor string `json:"cursor"`
					} `json:"params"`
				}
				if err := json.Unmarshal(line, &request); err != nil {
					t.Fatal(err)
				}
				wantCursor := ""
				if page == 1 {
					wantCursor = "page-two"
				}
				if request.Method != "thread/list" || request.Params.Cwd != "/history" || request.Params.Cursor != wantCursor {
					t.Fatalf("page %d lost its history scope/cursor: %s", page, line)
				}
				response := `"result":{"data":[{"id":"first-session","cwd":"/history"}],"nextCursor":"page-two"}`
				if page == 1 {
					response = tc.secondPage
				}
				if response == "" {
					_ = server.Close()
				} else if _, err := io.WriteString(server, `{"id":`+string(request.ID)+`,`+response+"}\n"); err != nil {
					t.Fatal(err)
				}
			}
			select {
			case result := <-finished:
				if result.sessions != nil || result.err == nil || !strings.Contains(result.err.Error(), tc.wantError) {
					t.Fatalf("partial history must fail visibly: sessions=%d error=%v", len(result.sessions), result.err)
				}
			case <-time.After(time.Second):
				t.Fatal("failed history page retried or hung instead of returning its error")
			}
			if len(writes.lines) != 0 {
				t.Fatal("history failure issued another request")
			}
		})
	}
}

// Opening a chat reads in full only the turns past the one its cache has,
// none when there are none; an unknown turn reads it all and resets the
// cache.
func TestHistoryReadsBackOnlyToTheCachedTurn(t *testing.T) {
	const thread = "paged-thread"
	var turns []appTurn
	for index := 1; index <= 25; index++ {
		turns = append(turns, appTurn{ID: fmt.Sprintf("t%02d", index), Status: "completed", Items: []appItem{}})
	}
	for _, tc := range []struct {
		after     string
		wantFirst string
		wantTurns int
		wantReset bool
		served    int
	}{
		{after: "t25", wantTurns: 0, served: 0},
		{after: "t24", wantFirst: "t25", wantTurns: 1, served: 2},
		{after: "t03", wantFirst: "t04", wantTurns: 22, served: 23},
		{after: "", wantFirst: "t01", wantTurns: 25, served: 25},
		{after: "gone", wantFirst: "t01", wantTurns: 25, wantReset: true, served: 25},
	} {
		t.Run("after "+tc.after, func(t *testing.T) {
			input, server := io.Pipe()
			writes := &capturedLineWriter{lines: make(chan []byte, 8)}
			client := newRPCClient(input, writes)
			go client.run()
			t.Cleanup(func() { _ = server.Close(); _ = input.Close() })
			ctx := testContext(t)
			served := 0
			go func() {
				for line := range writes.lines {
					var request struct {
						ID     json.RawMessage `json:"id"`
						Params struct {
							ThreadID      string `json:"threadId"`
							Cursor        string `json:"cursor"`
							Limit         int    `json:"limit"`
							SortDirection string `json:"sortDirection"`
							ItemsView     string `json:"itemsView"`
						} `json:"params"`
					}
					if err := json.Unmarshal(line, &request); err != nil || request.Params.ThreadID != thread || request.Params.SortDirection != "desc" {
						_ = server.CloseWithError(fmt.Errorf("unexpected request %s", line))
						return
					}
					start := len(turns)
					if request.Params.Cursor != "" {
						_, _ = fmt.Sscan(request.Params.Cursor, &start)
					}
					end := max(start-request.Params.Limit, 0)
					page := slices.Clone(turns[end:start])
					slices.Reverse(page)
					if request.Params.ItemsView == "full" {
						served += len(page)
					} else {
						for index := range page {
							page[index].Items = nil
						}
					}
					var next any
					if end > 0 {
						next = fmt.Sprint(end)
					}
					data, _ := json.Marshal(map[string]any{"id": request.ID, "result": map[string]any{"data": page, "nextCursor": next}})
					if _, err := server.Write(append(data, '\n')); err != nil {
						return
					}
				}
			}()
			page, err := (&Instance{rpc: client}).History(ctx, thread, provider.Workspace{}, provider.Marker(tc.after))
			if err != nil {
				t.Fatal(err)
			}
			var refs []string
			for _, turn := range page.Turns {
				refs = append(refs, turn.Ref)
			}
			if len(refs) != tc.wantTurns || len(refs) > 0 && (refs[0] != tc.wantFirst || refs[len(refs)-1] != "t25") || page.Reset != tc.wantReset {
				t.Fatalf("history after %q = %v (reset %v), want %d turns from %q to t25 (reset %v)", tc.after, refs, page.Reset, tc.wantTurns, tc.wantFirst, tc.wantReset)
			}
			if served != tc.served {
				t.Fatalf("history after %q read %d turns in full, want %d", tc.after, served, tc.served)
			}
		})
	}
}
