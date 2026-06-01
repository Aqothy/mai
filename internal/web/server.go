package web

import (
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/Aqothy/maiD/internal/daemon"
	"github.com/Aqothy/maiD/internal/ipc"
)

//go:embed static/*
var staticFiles embed.FS

type Options struct {
	Addr        string
	SocketPath  string
	StartDaemon bool
}

func Run(opts Options) error {
	if opts.Addr == "" {
		opts.Addr = "127.0.0.1:8765"
	}
	if opts.SocketPath == "" {
		opts.SocketPath = ipc.DefaultSocketPath
	}

	var embeddedDaemon *daemon.Server
	if opts.StartDaemon && !daemonAvailable(opts.SocketPath) {
		embeddedDaemon = daemon.NewServer()
		errCh := make(chan error, 1)
		go func() { errCh <- embeddedDaemon.Run(opts.SocketPath) }()

		select {
		case err := <-errCh:
			return fmt.Errorf("start daemon: %w", err)
		case <-time.After(100 * time.Millisecond):
		}
	}
	if embeddedDaemon != nil {
		defer embeddedDaemon.Close()
	}

	static, err := fs.Sub(staticFiles, "static")
	if err != nil {
		return err
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/context", contextHandler(opts.SocketPath))
	mux.HandleFunc("POST /api", apiHandler(opts.SocketPath))
	mux.Handle("/", http.FileServer(http.FS(static)))

	log.Printf("maiD web UI listening at http://%s", opts.Addr)
	return http.ListenAndServe(opts.Addr, mux)
}

func daemonAvailable(socketPath string) bool {
	conn, err := net.DialTimeout("unix", socketPath, 100*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

func contextHandler(socketPath string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		cwd, _ := os.Getwd()
		writeJSON(w, http.StatusOK, map[string]string{
			"socketPath": socketPath,
			"cwd":        cwd,
		})
	}
}

func apiHandler(socketPath string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req ipc.Request
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, ipc.Response{OK: false, Message: "decode request: " + err.Error()})
			return
		}
		if req.Action == "" {
			writeJSON(w, http.StatusBadRequest, ipc.Response{OK: false, Message: "action is required"})
			return
		}

		resp, err := ipc.Send(socketPath, req)
		if err != nil {
			writeJSON(w, http.StatusBadGateway, ipc.Response{OK: false, Message: err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, resp)
	}
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
