// A loopback-only fixture server for exercising the actual Swift RPC transport.
// Run from the repository root with the captured pipeline path as its argument.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

func main() {
	if len(os.Args) != 2 {
		log.Fatal("usage: date-wire-server <pipeline.json>")
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		log.Fatal(err)
	}
	var fixture struct {
		Initial json.RawMessage `json:"initial"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		log.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("ws://%s/rpc\n", listener.Addr())
	mux := http.NewServeMux()
	mux.HandleFunc("/rpc", func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			log.Print(err)
			return
		}
		defer conn.CloseNow()
		ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
		defer cancel()
		for {
			var request struct {
				ID     int    `json:"id"`
				Method string `json:"method"`
			}
			if err := wsjson.Read(ctx, conn, &request); err != nil {
				return
			}
			var result any
			switch request.Method {
			case "qa.thread":
				result = fixture.Initial
			case "qa.terminal":
				result = map[string]bool{"ok": true}
			default:
				log.Printf("unexpected method %q", request.Method)
				return
			}
			if err := wsjson.Write(ctx, conn, map[string]any{"jsonrpc": "2.0", "id": request.ID, "result": result}); err != nil {
				return
			}
			if request.Method == "qa.terminal" {
				for _, stamp := range []string{"2026-09-24T00:26:41.437657-04:00", "2026-09-24T04:26:42Z"} {
					terminal := map[string]any{"terminalId": "wire-date-qa", "title": "Timestamp QA", "cwd": "/tmp", "status": "running", "createdAt": stamp, "updatedAt": stamp, "agentActivityUpdatedAt": stamp}
					item := map[string]any{"kind": "upsert", "terminal": terminal}
					if err := wsjson.Write(ctx, conn, map[string]any{"jsonrpc": "2.0", "method": "terminal.subscribeList", "params": item}); err != nil {
						return
					}
				}
			}
			log.Printf("served %s id=%d", request.Method, request.ID)
		}
	})
	server := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	log.Fatal(server.Serve(listener))
}
