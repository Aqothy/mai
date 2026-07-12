package main

import (
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/Aqothy/maiD/internal/daemon"
)

func main() {
	server := daemon.NewServer()
	// Agent processes run in their own process groups, so they do not die with
	// the daemon; a signal must shut the server down cleanly (Close stops every
	// provider instance) instead of leaking running agents.
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-signals
		_ = server.Close()
	}()
	// RunWebSocket blocks until the server stops and closes the server on return.
	if err := server.RunWebSocket(os.Getenv("MAID_ADDR")); err != nil {
		log.Fatal(err)
	}
}
