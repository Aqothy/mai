package codexapp

import (
	"encoding/json"
	"io"
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
				sessions, err := (&Instance{rpc: client}).ListSessions(ctx, "/history")
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
