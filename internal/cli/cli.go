package cli

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/Aqothy/maiD/internal/daemon"
	"github.com/Aqothy/maiD/internal/ipc"
)

func RunAuto(args []string) error {
	if len(args) == 0 {
		return errors.New("missing argv")
	}
	if len(args) == 1 || strings.HasPrefix(args[1], "-") {
		return RunDaemon(args[1:])
	}
	return RunClient(args[1:])
}

func RunDaemon(args []string) error {
	fs := flag.NewFlagSet("maiD", flag.ExitOnError)
	socketPath := fs.String("socket", ipc.DefaultSocketPath, "unix socket path")
	if err := fs.Parse(args); err != nil {
		return err
	}
	server := daemon.NewServer()
	return server.Run(*socketPath)
}

func RunClient(args []string) error {
	if len(args) == 0 {
		usage()
		return nil
	}

	switch args[0] {
	case "agent":
		return agentCommand(args[1:])
	default:
		usage()
		return fmt.Errorf("unknown command: %s", args[0])
	}
}

func agentCommand(args []string) error {
	if len(args) == 0 {
		return errors.New("missing agent subcommand")
	}
	if args[0] != "init" {
		return fmt.Errorf("unknown agent subcommand: %s", args[0])
	}
	return agentInit(args[1:])
}

func agentInit(args []string) error {
	fs := flag.NewFlagSet("agent init", flag.ExitOnError)
	socketPath := fs.String("socket", ipc.DefaultSocketPath, "unix socket path")
	name := fs.String("name", "", "agent connection name, e.g. codex")
	kind := fs.String("kind", "acp", "agent kind; only acp is implemented right now")
	cmdFlag := fs.String("cmd", "", "ACP adapter command, e.g. 'codex-acp' or 'npx @zed-industries/codex-acp'")
	if err := fs.Parse(args); err != nil {
		return err
	}

	command := strings.Fields(*cmdFlag)
	if len(command) == 0 {
		command = fs.Args()
	}
	if len(command) == 0 {
		return errors.New("agent init requires --cmd or an adapter command after --")
	}

	return sendRequest(*socketPath, ipc.ActionAgentInit, ipc.AgentInitParams{Name: *name, Kind: *kind, Command: command})
}

func sendRequest(socketPath string, action string, params any) error {
	req, err := ipc.NewRequest(action, params)
	if err != nil {
		return err
	}

	resp, err := ipc.Send(socketPath, req)
	if err != nil {
		return err
	}
	if !resp.OK {
		return errors.New(resp.Message)
	}

	fmt.Println(resp.Message)
	return nil
}

func usage() {
	_, _ = fmt.Fprintln(os.Stderr, `usage
	maiD [--socket /tmp/maiD.sock]
	maiD agent init [--socket /tmp/maiD.sock] [--name codex] [--kind acp] -- <acp-adapter-command> [args...]
	maiD agent init [--socket /tmp/maiD.sock] [--name codex] -- codex-acp
	maiD agent init [--socket /tmp/maiD.sock] [--name codex] --cmd "npx @zed-industries/codex-acp"`)
}
