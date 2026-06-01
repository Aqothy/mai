package cli

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
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
	case "session":
		return sessionCommand(args[1:])
	default:
		usage()
		return fmt.Errorf("unknown command: %s", args[0])
	}
}

func agentCommand(args []string) error {
	if len(args) == 0 {
		return errors.New("missing agent subcommand")
	}
	switch args[0] {
	case "init":
		return agentInit(args[1:])
	case "auth", "authenticate":
		return agentAuthenticate(args[1:])
	case "logout":
		return agentLogout(args[1:])
	default:
		return fmt.Errorf("unknown agent subcommand: %s", args[0])
	}
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

func agentAuthenticate(args []string) error {
	fs := flag.NewFlagSet("agent auth", flag.ExitOnError)
	socketPath := fs.String("socket", ipc.DefaultSocketPath, "unix socket path")
	name := fs.String("name", "", "agent connection name")
	methodID := fs.String("method", "", "ACP auth method id advertised by the agent")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *name == "" && fs.NArg() > 0 {
		*name = fs.Arg(0)
	}
	if *methodID == "" {
		return errors.New("agent auth requires --method")
	}
	return sendRequest(*socketPath, ipc.ActionAgentAuthenticate, ipc.AgentAuthenticateParams{Name: *name, MethodID: *methodID})
}

func agentLogout(args []string) error {
	fs := flag.NewFlagSet("agent logout", flag.ExitOnError)
	socketPath := fs.String("socket", ipc.DefaultSocketPath, "unix socket path")
	name := fs.String("name", "", "agent connection name")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *name == "" && fs.NArg() > 0 {
		*name = fs.Arg(0)
	}
	return sendRequest(*socketPath, ipc.ActionAgentLogout, ipc.AgentLogoutParams{Name: *name})
}

func sessionCommand(args []string) error {
	if len(args) == 0 {
		return errors.New("missing session subcommand")
	}
	switch args[0] {
	case "new":
		return sessionNew(args[1:])
	case "load":
		return sessionLoad(args[1:])
	case "resume":
		return sessionResume(args[1:])
	case "close":
		return sessionClose(args[1:])
	case "list":
		return sessionList(args[1:])
	default:
		return fmt.Errorf("unknown session subcommand: %s", args[0])
	}
}

func sessionNew(args []string) error {
	fs := flag.NewFlagSet("session new", flag.ExitOnError)
	socketPath := fs.String("socket", ipc.DefaultSocketPath, "unix socket path")
	name := fs.String("name", "", "agent connection name")
	cwd := fs.String("cwd", defaultCwd(), "session working directory")
	mcpJSON := fs.String("mcp-json", "", "JSON array of MCP server configs")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *name == "" && fs.NArg() > 0 {
		*name = fs.Arg(0)
	}
	options, err := sessionOptionsFromMCPJSON(*mcpJSON)
	if err != nil {
		return err
	}
	return sendRequest(*socketPath, ipc.ActionSessionNew, ipc.SessionNewParams{Name: *name, Cwd: absPath(*cwd), Options: options})
}

func sessionLoad(args []string) error {
	fs := flag.NewFlagSet("session load", flag.ExitOnError)
	socketPath := fs.String("socket", ipc.DefaultSocketPath, "unix socket path")
	name := fs.String("name", "", "agent connection name")
	sessionID := fs.String("id", "", "session id")
	cwd := fs.String("cwd", defaultCwd(), "session working directory")
	mcpJSON := fs.String("mcp-json", "", "JSON array of MCP server configs")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *name == "" && fs.NArg() > 0 {
		*name = fs.Arg(0)
	}
	if *sessionID == "" {
		return errors.New("session load requires --id")
	}
	options, err := sessionOptionsFromMCPJSON(*mcpJSON)
	if err != nil {
		return err
	}
	return sendRequest(*socketPath, ipc.ActionSessionLoad, ipc.SessionLoadParams{Name: *name, SessionID: *sessionID, Cwd: absPath(*cwd), Options: options})
}

func sessionResume(args []string) error {
	fs := flag.NewFlagSet("session resume", flag.ExitOnError)
	socketPath := fs.String("socket", ipc.DefaultSocketPath, "unix socket path")
	name := fs.String("name", "", "agent connection name")
	sessionID := fs.String("id", "", "session id")
	cwd := fs.String("cwd", defaultCwd(), "session working directory")
	mcpJSON := fs.String("mcp-json", "", "JSON array of MCP server configs")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *name == "" && fs.NArg() > 0 {
		*name = fs.Arg(0)
	}
	if *sessionID == "" {
		return errors.New("session resume requires --id")
	}
	options, err := sessionOptionsFromMCPJSON(*mcpJSON)
	if err != nil {
		return err
	}
	return sendRequest(*socketPath, ipc.ActionSessionResume, ipc.SessionResumeParams{Name: *name, SessionID: *sessionID, Cwd: absPath(*cwd), Options: options})
}

func sessionClose(args []string) error {
	fs := flag.NewFlagSet("session close", flag.ExitOnError)
	socketPath := fs.String("socket", ipc.DefaultSocketPath, "unix socket path")
	name := fs.String("name", "", "agent connection name")
	sessionID := fs.String("id", "", "session id")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *name == "" && fs.NArg() > 0 {
		*name = fs.Arg(0)
	}
	if *sessionID == "" {
		return errors.New("session close requires --id")
	}
	return sendRequest(*socketPath, ipc.ActionSessionClose, ipc.SessionCloseParams{Name: *name, SessionID: *sessionID})
}

func sessionList(args []string) error {
	fs := flag.NewFlagSet("session list", flag.ExitOnError)
	socketPath := fs.String("socket", ipc.DefaultSocketPath, "unix socket path")
	name := fs.String("name", "", "agent connection name")
	cwd := fs.String("cwd", "", "optional working directory filter")
	cursor := fs.String("cursor", "", "optional pagination cursor")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *name == "" && fs.NArg() > 0 {
		*name = fs.Arg(0)
	}
	if *cwd != "" {
		*cwd = absPath(*cwd)
	}
	return sendRequest(*socketPath, ipc.ActionSessionList, ipc.SessionListParams{Name: *name, Cwd: *cwd, Cursor: *cursor})
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

func sessionOptionsFromMCPJSON(raw string) (json.RawMessage, error) {
	if raw == "" {
		return nil, nil
	}
	var servers []json.RawMessage
	if err := json.Unmarshal([]byte(raw), &servers); err != nil {
		return nil, fmt.Errorf("decode --mcp-json: %w", err)
	}
	options, err := json.Marshal(map[string]any{"mcpServers": servers})
	if err != nil {
		return nil, fmt.Errorf("encode session options: %w", err)
	}
	return options, nil
}

func defaultCwd() string {
	wd, err := os.Getwd()
	if err != nil {
		return ""
	}
	return absPath(wd)
}

func absPath(path string) string {
	if path == "" || filepath.IsAbs(path) {
		return path
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return path
	}
	return abs
}

func usage() {
	_, _ = fmt.Fprintln(os.Stderr, `usage
	maiD [--socket /tmp/maiD.sock]
	maiD agent init [--socket /tmp/maiD.sock] [--name codex] [--kind acp] -- <acp-adapter-command> [args...]
	maiD agent init [--socket /tmp/maiD.sock] [--name codex] -- codex-acp
	maiD agent init [--socket /tmp/maiD.sock] [--name codex] --cmd "npx @zed-industries/codex-acp"
	maiD agent auth [--socket /tmp/maiD.sock] --name codex --method agent-login
	maiD agent logout [--socket /tmp/maiD.sock] --name codex
	maiD session new [--socket /tmp/maiD.sock] --name codex [--cwd /path]
	maiD session list [--socket /tmp/maiD.sock] --name codex [--cwd /path] [--cursor token]
	maiD session load [--socket /tmp/maiD.sock] --name codex --id session-id [--cwd /path]
	maiD session resume [--socket /tmp/maiD.sock] --name codex --id session-id [--cwd /path]
	maiD session close [--socket /tmp/maiD.sock] --name codex --id session-id`)
}
