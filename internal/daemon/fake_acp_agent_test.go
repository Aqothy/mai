package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// fakeACPAgentCommand returns the command line that runs this test binary as
// the daemon tests' fake ACP agent. Flags configure the agent process itself:
//
//	-list-only       advertise session/list without load/resume/close
//	-linger          ignore stdin EOF, like real agents that only die with their process group
//	-pidfile <path>  write the agent's pid at startup
//
// Per-turn behavior is scripted by the prompt text; see fakeACPAgent.prompt.
func fakeACPAgentCommand(flags ...string) []string {
	return append([]string{"env", "MAID_DAEMON_ACP_HELPER=1", os.Args[0], "-test.run=TestHelperProcess", "--"}, flags...)
}

// startFakeACPAgent starts the fake ACP agent as provider instance id.
func startFakeACPAgent(t *testing.T, s *Server, id provider.InstanceID, flags ...string) {
	t.Helper()
	if _, err := s.StartProvider(context.Background(), acpInstanceSpec(id, string(id), fakeACPAgentCommand(flags...)), false); err != nil {
		t.Fatalf("provider start: %v", err)
	}
}

func acpInstanceSpec(id provider.InstanceID, name string, command []string) provider.InstanceSpec {
	config, err := json.Marshal(map[string]any{"command": command})
	if err != nil {
		panic(err)
	}
	return provider.InstanceSpec{InstanceID: id, Name: name, Driver: "acp", Config: config}
}

func TestHelperProcess(t *testing.T) {
	if os.Getenv("MAID_DAEMON_ACP_HELPER") != "1" {
		return
	}
	args := []string{}
	for i, arg := range os.Args {
		if arg == "--" {
			args = os.Args[i+1:]
			break
		}
	}
	flags := flag.NewFlagSet("fake-acp-agent", flag.ExitOnError)
	listOnly := flags.Bool("list-only", false, "")
	linger := flags.Bool("linger", false, "")
	pidPath := flags.String("pidfile", "", "")
	_ = flags.Parse(args)
	if *pidPath != "" {
		if err := os.WriteFile(*pidPath, []byte(strconv.Itoa(os.Getpid())), 0o644); err != nil {
			fakeAgentFail("write pidfile: %v", err)
		}
	}

	agent := &fakeACPAgent{
		listOnly:    *listOnly,
		out:         json.NewEncoder(os.Stdout),
		cwds:        map[string]string{},
		parked:      map[string]string{},
		permissions: map[string]fakePermission{},
		mode:        "ask",
		model:       "test-model-1",
	}
	reader := bufio.NewReader(os.Stdin)
	for {
		line, err := reader.ReadBytes('\n')
		if err != nil {
			break
		}
		var msg fakeACPMessage
		if err := json.Unmarshal(line, &msg); err != nil {
			fakeAgentFail("decode %s: %v", line, err)
		}
		agent.mu.Lock()
		agent.handle(msg, line)
		agent.mu.Unlock()
	}
	if *linger {
		// A sleep loop, not select{}, so the Go runtime's deadlock detector
		// does not terminate the helper.
		for {
			time.Sleep(time.Hour)
		}
	}
}

// fakeACPAgent serves one ACP connection over stdio. It is event-driven:
// parked prompts and pending permission requests are keyed state, so other
// sessions keep being served while one waits on an approval or a cancel.
type fakeACPAgent struct {
	listOnly bool

	mu          sync.Mutex // serializes stdout and the state below with gate goroutines
	out         *json.Encoder
	order       []string                  // session ids in creation/load order
	cwds        map[string]string         // session id -> cwd
	parked      map[string]string         // session id -> blocked session/prompt request id
	permissions map[string]fakePermission // permission request id -> prompt to settle

	sessionCount, permissionCount int
	mode, model                   string
}

type fakePermission struct {
	promptID  string
	sessionID string
}

type fakeACPMessage struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params struct {
		Cwd       string `json:"cwd"`
		SessionID string `json:"sessionId"`
		MethodID  string `json:"methodId"`
		ConfigID  string `json:"configId"`
		Value     string `json:"value"`
		Prompt    []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"prompt"`
	} `json:"params"`
	Result struct {
		Outcome struct {
			Outcome  string `json:"outcome"`
			OptionID string `json:"optionId"`
		} `json:"outcome"`
	} `json:"result"`
}

func fakeAgentFail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "fake ACP agent: "+format+"\n", args...)
	os.Exit(1)
}

func (a *fakeACPAgent) write(msg map[string]any) {
	msg["jsonrpc"] = "2.0"
	if err := a.out.Encode(msg); err != nil {
		fakeAgentFail("write: %v", err)
	}
}

func (a *fakeACPAgent) result(id json.RawMessage, result any) {
	a.write(map[string]any{"id": id, "result": result})
}

func (a *fakeACPAgent) update(sessionID string, update map[string]any) {
	a.write(map[string]any{"method": "session/update", "params": map[string]any{"sessionId": sessionID, "update": update}})
}

func (a *fakeACPAgent) chunk(sessionID string, text string) {
	a.update(sessionID, map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": text}})
}

func (a *fakeACPAgent) trackSession(sessionID string, cwd string) {
	if _, ok := a.cwds[sessionID]; !ok {
		a.order = append(a.order, sessionID)
	}
	a.cwds[sessionID] = cwd
}

// configOptions is a mode selector and a model selector: the two categories
// maiD projects onto SessionBinding.ConfigOptions.
func (a *fakeACPAgent) configOptions() []any {
	return []any{
		map[string]any{"type": "select", "id": "mode", "name": "Mode", "category": "mode", "currentValue": a.mode, "options": []any{
			map[string]any{"name": "Ask", "value": "ask"},
			map[string]any{"name": "Plan", "value": "plan"},
		}},
		map[string]any{"type": "select", "id": "model", "name": "Model", "category": "model", "currentValue": a.model, "options": []any{
			map[string]any{"name": "Test Model 1", "value": "test-model-1"},
			map[string]any{"name": "Test Model 2", "value": "test-model-2"},
		}},
	}
}

func (a *fakeACPAgent) handle(msg fakeACPMessage, line []byte) {
	sessionID := msg.Params.SessionID
	var result any = map[string]any{}
	switch msg.Method {
	case "":
		a.settlePermission(strings.Trim(string(msg.ID), `"`), msg.Result.Outcome.Outcome, msg.Result.Outcome.OptionID)
		return
	case "$/cancel_request":
		// Protocol-level cancellation notification; a cancel for an
		// already-completed request is a no-op.
		return
	case "session/cancel":
		a.releaseParked(sessionID, "", "cancelled")
		return
	case "initialize":
		sessionCapabilities := map[string]any{"list": map[string]any{}}
		if !a.listOnly {
			sessionCapabilities["resume"] = map[string]any{}
			sessionCapabilities["close"] = map[string]any{}
		}
		result = map[string]any{
			"protocolVersion":   1,
			"agentCapabilities": map[string]any{"auth": map[string]any{"logout": map[string]any{}}, "loadSession": !a.listOnly, "sessionCapabilities": sessionCapabilities},
			"agentInfo":         map[string]any{"name": "fake-acp-agent"},
			"authMethods":       []any{map[string]any{"id": "agent-login", "name": "Agent login"}},
		}
	case "authenticate":
		if msg.Params.MethodID != "agent-login" {
			fakeAgentFail("unexpected authenticate request: %s", line)
		}
	case "logout", "session/close":
	case "session/new":
		a.sessionCount++
		sessionID = fmt.Sprintf("sess-%d", a.sessionCount)
		a.trackSession(sessionID, msg.Params.Cwd)
		result = map[string]any{"sessionId": sessionID, "configOptions": a.configOptions()}
	case "session/list":
		sessions := []any{}
		for _, id := range a.order {
			sessions = append(sessions, map[string]any{"sessionId": id, "cwd": a.cwds[id], "title": "Test session"})
		}
		result = map[string]any{"sessions": sessions}
	case "session/load":
		a.trackSession(sessionID, msg.Params.Cwd)
		a.chunk(sessionID, "replayed")
	case "session/resume":
		a.trackSession(sessionID, msg.Params.Cwd)
	case "session/set_config_option":
		switch msg.Params.ConfigID {
		case "mode":
			a.mode = msg.Params.Value
		case "model":
			a.model = msg.Params.Value
		default:
			fakeAgentFail("unexpected set_config_option request: %s", line)
		}
		result = map[string]any{"configOptions": a.configOptions()}
	case "session/prompt":
		text := ""
		for _, block := range msg.Params.Prompt {
			if block.Type == "text" {
				text = block.Text
				break
			}
		}
		a.prompt(msg.ID, sessionID, text)
		return
	default:
		fakeAgentFail("unexpected request: %s", line)
	}
	a.result(msg.ID, result)
}

// prompt runs the turn script named by the prompt text. This is the place to
// add a new per-turn behavior:
//
//	"stream <n> [width] [delayMs]"  n agent_message_chunk updates (width-padded, optionally paced)
//	"tools <n>"                     n distinct completed tool_call updates
//	"metadata"                      slash commands, an agent-set title and usage, then "hi"
//	"permission"                    request permission, then echo "perm:<optionId>"
//	"block [gateDir]"               park until session/cancel; with gateDir, write
//	                                gateDir/ready and finish with "hi" once gateDir/release exists
//	anything else                   a single "hi" chunk
func (a *fakeACPAgent) prompt(id json.RawMessage, sessionID string, text string) {
	fields := strings.Fields(text)
	verb := ""
	if len(fields) > 0 {
		verb = fields[0]
	}
	endTurn := map[string]any{"stopReason": "end_turn"}
	switch verb {
	case "stream":
		count, width, delayMs := fakeIntArg(fields, 1), fakeIntArg(fields, 2), fakeIntArg(fields, 3)
		for i := 0; i < count; i++ {
			chunk := fmt.Sprintf("w%d ", i)
			if pad := width - len(chunk); pad > 0 {
				chunk += strings.Repeat("x", pad)
			}
			a.chunk(sessionID, chunk)
			time.Sleep(time.Duration(delayMs) * time.Millisecond)
		}
		a.result(id, endTurn)
	case "tools":
		for i := 0; i < fakeIntArg(fields, 1); i++ {
			a.update(sessionID, map[string]any{"sessionUpdate": "tool_call", "toolCallId": fmt.Sprintf("tool-%d", i), "title": fmt.Sprintf("tool %d", i), "status": "completed"})
		}
		a.result(id, endTurn)
	case "metadata":
		a.update(sessionID, map[string]any{"sessionUpdate": "available_commands_update", "availableCommands": []any{map[string]any{"name": "compact", "description": "Compact the conversation"}}})
		a.update(sessionID, map[string]any{"sessionUpdate": "session_info_update", "title": "Agent set title"})
		a.update(sessionID, map[string]any{"sessionUpdate": "usage_update", "used": 1200, "size": 200000, "cost": map[string]any{"amount": 0.42, "currency": "USD"}})
		a.chunk(sessionID, "hi")
		a.result(id, endTurn)
	case "permission":
		a.permissionCount++
		permID := fmt.Sprintf("perm-%d", a.permissionCount)
		a.permissions[permID] = fakePermission{promptID: string(id), sessionID: sessionID}
		a.write(map[string]any{"id": permID, "method": "session/request_permission", "params": map[string]any{
			"sessionId": sessionID,
			"toolCall":  map[string]any{"toolCallId": "tool-" + permID, "title": "Edit file"},
			"options": []any{
				map[string]any{"kind": "allow_once", "name": "Allow", "optionId": "allow"},
				map[string]any{"kind": "reject_once", "name": "Reject", "optionId": "reject"},
			},
		}})
	case "block":
		a.parked[sessionID] = string(id)
		if gate := strings.TrimSpace(strings.TrimPrefix(text, "block")); gate != "" {
			if err := os.WriteFile(gate+"/ready", nil, 0o644); err != nil {
				fakeAgentFail("write ready marker: %v", err)
			}
			go func() {
				for {
					if _, err := os.Stat(gate + "/release"); err == nil {
						break
					}
					time.Sleep(10 * time.Millisecond)
				}
				a.mu.Lock()
				defer a.mu.Unlock()
				a.releaseParked(sessionID, string(id), "end_turn")
			}()
		}
	default:
		a.chunk(sessionID, "hi")
		a.result(id, endTurn)
	}
}

// releaseParked settles the session's parked prompt (only promptID, when set).
func (a *fakeACPAgent) releaseParked(sessionID string, promptID string, stopReason string) {
	parked, ok := a.parked[sessionID]
	if !ok || (promptID != "" && parked != promptID) {
		return
	}
	delete(a.parked, sessionID)
	if stopReason == "end_turn" {
		a.chunk(sessionID, "hi")
	}
	a.result(json.RawMessage(parked), map[string]any{"stopReason": stopReason})
}

// settlePermission finishes the prompt behind an answered permission request.
func (a *fakeACPAgent) settlePermission(permID string, outcome string, optionID string) {
	pending, ok := a.permissions[permID]
	if !ok {
		return
	}
	delete(a.permissions, permID)
	if outcome == "cancelled" {
		a.result(json.RawMessage(pending.promptID), map[string]any{"stopReason": "cancelled"})
		return
	}
	a.chunk(pending.sessionID, "perm:"+optionID)
	a.result(json.RawMessage(pending.promptID), map[string]any{"stopReason": "end_turn"})
}

// fakeIntArg parses fields[i] as an int, defaulting to 0 when absent.
func fakeIntArg(fields []string, i int) int {
	if i >= len(fields) {
		return 0
	}
	n, err := strconv.Atoi(fields[i])
	if err != nil {
		fakeAgentFail("script argument %q: %v", fields[i], err)
	}
	return n
}
