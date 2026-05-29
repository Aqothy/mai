package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
)

type Request struct {
	Action string `json:"action"`
}

type Response struct {
	OK      bool   `json:"ok"`
	Message string `json:"message"`
}

// runs with socket
func main() {
	// if running with no args, just run the unix socket
	if len(os.Args) == 1 {
		runDaemon()
	}

	switch os.Args[1] {
	case "ping":
		sendCommand(os.Args[2:], "ping")
	default:
		usage()
		os.Exit(1)
	}
}

func usage() {
	fmt.Println(`usage
		maiD
		maiD ping
		use --socket flag to specify a specific socket file path
		ex. --socket /tmp/my.sock`)
}

func runDaemon() {
	var ln net.Listener
	var err error
	socketPath := flag.String("socket", "/tmp/maiD.sock", "unix socket path")
	flag.Parse()
	fmt.Println(*socketPath)

	// Remove a stale socket from a previous run, but don't replace a live daemon's socket.
	if _, err := os.Stat(*socketPath); err == nil {
		conn, err := net.Dial("unix", *socketPath)
		if err == nil {
			conn.Close()
			log.Fatal("daemon already running")
		}

		_ = os.Remove(*socketPath)
	}

	ln, err = net.Listen("unix", *socketPath)
	if err != nil {
		log.Fatal(err)
	}

	defer ln.Close()
	defer os.Remove(*socketPath)

	log.Println("Daemon listening")

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Println("accept:", err)
			continue
		}

		go handleConn(conn)

	}
}

func handleConn(conn net.Conn) {
	defer conn.Close()

	var req Request

	if err := json.NewDecoder(conn).Decode(&req); err != nil {
		json.NewEncoder(conn).Encode(Response{
			OK:      false,
			Message: err.Error(),
		})
		return
	}

	switch req.Action {
	case "ping":
		json.NewEncoder(conn).Encode(Response{
			OK:      true,
			Message: "ok",
		})
	default:
		json.NewEncoder(conn).Encode(Response{
			OK:      false,
			Message: "unknown action: " + req.Action,
		})
	}
}

func sendCommand(args []string, action string) {
	fs := flag.NewFlagSet(action, flag.ExitOnError)
	socketPath := fs.String("socket", "/tmp/maiD.sock", "unix socket path")
	fs.Parse(args)

	conn, err := net.Dial("unix", *socketPath)

	if err != nil {
		log.Fatal(err)
	}

	defer conn.Close()

	req := Request{Action: action}

	if err := json.NewEncoder(conn).Encode(req); err != nil {
		log.Fatal(err)
	}

	reader := bufio.NewReader(conn)
	var resp Response
	if err := json.NewDecoder(reader).Decode(&resp); err != nil {
		log.Fatal(err)
	}

	if !resp.OK {
		log.Fatal(resp.Message)
	}

	fmt.Println(resp.Message)
}
