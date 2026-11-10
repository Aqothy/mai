package claudecode

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// TestMain doubles as the fake Claude Code CLI: the adapter spawns real
// processes, so tests point Config.Command at the test binary itself and the
// CLAUDE_FAKE_CLI re-entry speaks scripted stream-json on stdio. Like the real
// CLI, it writes each message it streams to the session's transcript, so
// History can be checked against what streamed.
func TestMain(m *testing.M) {
	if os.Getenv("CLAUDE_FAKE_CLI") == "1" {
		fakeCLIMain()
		return
	}
	os.Exit(m.Run())
}

// Logs the fake writes in its cwd, so tests can assert flags and control
// traffic.
const (
	fakeLaunchLog  = "fake-launches.log"
	fakeControlLog = "fake-control.log"
)

type fakeCLI struct {
	session string
	// transcript is the session's file; chain its last line.
	transcript string
	chain      string
	replay     bool
	messages   int
	// slow: a query is running, waiting for the test's next message.
	slow bool
	// approved runs once the pending permission is answered.
	approved func(allowed bool)
}

func fakeCLIMain() {
	f := &fakeCLI{replay: slices.Contains(os.Args, "--replay-user-messages")}
	for index, arg := range os.Args {
		if (arg == "--session-id" || arg == "--resume") && index+1 < len(os.Args) {
			f.session = os.Args[index+1]
		}
	}
	// The probe has no session and logs nothing.
	if f.session != "" {
		f.log(fakeLaunchLog, strings.Join(os.Args[1:], " "))
		f.openTranscript()
	}
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 0, 1<<20), 16<<20)
	initSent := false
	for scanner.Scan() {
		var message map[string]any
		if json.Unmarshal(scanner.Bytes(), &message) != nil {
			continue
		}
		switch message["type"] {
		case "control_request":
			f.control(message)
		case "control_response":
			response, _ := message["response"].(map[string]any)
			inner, _ := response["response"].(map[string]any)
			if f.approved != nil {
				approved := f.approved
				f.approved = nil
				approved(inner["behavior"] == "allow")
			}
		case "user":
			if !initSent {
				initSent = true
				f.out(map[string]any{"type": "system", "subtype": "init", "session_id": f.session, "model": "fake-model", "permissionMode": "default"})
			}
			f.user(message)
		}
	}
}

func (f *fakeCLI) log(name, line string) {
	if file, err := os.OpenFile(name, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
		fmt.Fprintln(file, line)
		_ = file.Close()
	}
}

// openTranscript finds the session's transcript where the CLI keeps it: in
// the project directory named after the real path of its cwd.
func (f *fakeCLI) openTranscript() {
	cwd, _ := os.Getwd()
	if resolved, err := filepath.EvalSymlinks(cwd); err == nil {
		cwd = resolved
	}
	dir := filepath.Join(os.Getenv("CLAUDE_CONFIG_DIR"), "projects", sanitizePath(cwd))
	_ = os.MkdirAll(dir, 0o755)
	f.transcript = filepath.Join(dir, f.session+".jsonl")
	// A resumed transcript continues from its last line.
	if data, err := os.ReadFile(f.transcript); err == nil {
		for _, line := range parseTranscript(data) {
			if line.chained() {
				f.chain = line.UUID
			}
		}
	}
}

func (f *fakeCLI) out(value any) {
	encoded, _ := json.Marshal(value)
	os.Stdout.Write(append(encoded, '\n'))
}

// write appends a line to a transcript, chained to its previous one.
func (f *fakeCLI) write(path string, chain *string, line map[string]any) string {
	id := newSessionUUID()
	if given, ok := line["uuid"].(string); ok {
		id = given
	}
	line["uuid"], line["parentUuid"], line["sessionId"] = id, nilIfEmpty(*chain), f.session
	line["timestamp"] = time.Now().UTC().Format(time.RFC3339Nano)
	*chain = id
	encoded, _ := json.Marshal(line)
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	if file, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600); err == nil {
		_, _ = file.Write(append(encoded, '\n'))
		_ = file.Close()
	}
	return id
}

func nilIfEmpty(value string) any {
	if value == "" {
		return nil
	}
	return value
}

func (f *fakeCLI) line(line map[string]any) string { return f.write(f.transcript, &f.chain, line) }

// echo acknowledges a written message the way the CLI does when it takes it
// into a query.
func (f *fakeCLI) echo(message map[string]any) {
	if f.replay {
		f.out(map[string]any{"type": "user", "isReplay": true, "uuid": message["uuid"], "session_id": f.session, "parent_tool_use_id": nil, "message": message["message"]})
	}
}

// prompt is a message the CLI starts a query with: a user line of its own.
func (f *fakeCLI) prompt(message map[string]any) {
	f.echo(message)
	f.line(map[string]any{"type": "user", "uuid": message["uuid"], "message": message["message"]})
}

// fold is a message folded into the running query: the transcript keeps
// only the queued command, with the message's uuid as its source.
func (f *fakeCLI) fold(message map[string]any) {
	f.echo(message)
	inner, _ := message["message"].(map[string]any)
	f.line(map[string]any{"type": "attachment", "attachment": map[string]any{
		"type": "queued_command", "commandMode": "prompt", "origin": map[string]any{"kind": "human"}, "prompt": inner["content"], "source_uuid": message["uuid"],
	}})
}

// block is one content block of an assistant message.
type block map[string]any

func text(value string) block { return block{"type": "text", "text": value} }
func tool(id, name string, input map[string]any) block {
	return block{"type": "tool_use", "id": id, "name": name, "input": input}
}

// say streams one API message, block by block, as the CLI does: partial
// events, then an assistant message per block, each a transcript line.
// parent tags a subagent's message; its lines go to its transcript.
func (f *fakeCLI) say(sub *fakeAgent, blocks ...block) {
	f.messages++
	id := fmt.Sprintf("msg_%d", f.messages)
	var parent any
	if sub != nil {
		parent = sub.tool
	}
	stream := func(event map[string]any) {
		f.out(map[string]any{"type": "stream_event", "session_id": f.session, "parent_tool_use_id": parent, "event": event})
	}
	stream(map[string]any{"type": "message_start", "message": map[string]any{"id": id, "role": "assistant", "content": []any{}}})
	for index, content := range blocks {
		switch content["type"] {
		case "text":
			stream(map[string]any{"type": "content_block_start", "index": index, "content_block": map[string]any{"type": "text", "text": ""}})
			words := strings.SplitAfter(content["text"].(string), " ")
			for _, word := range words {
				stream(map[string]any{"type": "content_block_delta", "index": index, "delta": map[string]any{"type": "text_delta", "text": word}})
			}
		case "tool_use":
			stream(map[string]any{"type": "content_block_start", "index": index, "content_block": map[string]any{"type": "tool_use", "id": content["id"], "name": content["name"], "input": map[string]any{}}})
			input, _ := json.Marshal(content["input"])
			half := len(input) / 2
			stream(map[string]any{"type": "content_block_delta", "index": index, "delta": map[string]any{"type": "input_json_delta", "partial_json": string(input[:half])}})
			stream(map[string]any{"type": "content_block_delta", "index": index, "delta": map[string]any{"type": "input_json_delta", "partial_json": string(input[half:])}})
		}
		message := map[string]any{"id": id, "role": "assistant", "content": []any{map[string]any(content)}}
		line := map[string]any{"type": "assistant", "message": message}
		var uuid string
		if sub != nil {
			line["isSidechain"], line["agentId"] = true, sub.id
			uuid = f.write(sub.transcript(f), &sub.chain, line)
		} else {
			uuid = f.line(line)
		}
		f.out(map[string]any{"type": "assistant", "uuid": uuid, "session_id": f.session, "parent_tool_use_id": parent, "message": message})
		stream(map[string]any{"type": "content_block_stop", "index": index})
	}
	stream(map[string]any{"type": "message_stop"})
}

// toolResult answers a tool call, with its structured result.
func (f *fakeCLI) toolResult(sub *fakeAgent, id, output string, structured map[string]any) {
	message := map[string]any{"role": "user", "content": []any{map[string]any{"type": "tool_result", "tool_use_id": id, "content": output}}}
	line := map[string]any{"type": "user", "message": message, "toolUseResult": structured}
	var parent any
	var uuid string
	if sub != nil {
		parent = sub.tool
		line["isSidechain"], line["agentId"] = true, sub.id
		uuid = f.write(sub.transcript(f), &sub.chain, line)
	} else {
		uuid = f.line(line)
	}
	f.out(map[string]any{"type": "user", "uuid": uuid, "session_id": f.session, "parent_tool_use_id": parent, "tool_use_result": structured, "message": message})
}

func (f *fakeCLI) result(extra map[string]any) {
	result := map[string]any{
		"type": "result", "subtype": "success", "is_error": false, "result": "done", "session_id": f.session, "total_cost_usd": 0.01,
		"usage":      map[string]any{"input_tokens": 5, "cache_read_input_tokens": 100, "output_tokens": 7},
		"modelUsage": map[string]any{"fake-model": map[string]any{"contextWindow": 200000, "costUSD": 0.01}},
	}
	for key, value := range extra {
		result[key] = value
	}
	f.out(result)
}

// fakeAgent is a subagent the fake runs, with a transcript of its own.
type fakeAgent struct {
	id, tool, chain string
}

func (a *fakeAgent) transcript(f *fakeCLI) string {
	return filepath.Join(strings.TrimSuffix(f.transcript, ".jsonl"), "subagents", "agent-"+a.id+".jsonl")
}

func messageText(message map[string]any) string {
	inner, _ := message["message"].(map[string]any)
	switch content := inner["content"].(type) {
	case string:
		return content
	case []any:
		text := ""
		for _, item := range content {
			if mapped, ok := item.(map[string]any); ok && mapped["type"] == "text" {
				text += mapped["text"].(string)
			}
		}
		return text
	}
	return ""
}

// user runs a written message, scripted by its text.
func (f *fakeCLI) user(message map[string]any) {
	said := messageText(message)
	if f.slow {
		f.slow = false
		if strings.Contains(said, "FOLD") {
			// Folded in at a tool boundary: the query goes on with it.
			f.fold(message)
			f.say(nil, text("Folded in"))
			f.result(nil)
			return
		}
		// The running query ends before a boundary, so the message runs as
		// one more query.
		f.result(nil)
		f.prompt(message)
		f.say(nil, text("Later reply"))
		f.result(nil)
		return
	}
	f.prompt(message)
	switch {
	case strings.Contains(said, "SLOW"):
		f.slow = true
		f.say(nil, text("Working on it"))
	case strings.Contains(said, "WAKE"):
		f.say(nil, text("Started a background task"))
		f.result(nil)
		// The task finishing wakes the CLI with no message written.
		f.line(map[string]any{"type": "user", "origin": map[string]any{"kind": "task-notification"}, "message": map[string]any{"role": "user", "content": "<task-notification>build finished</task-notification>"}})
		f.say(nil, text("Background task finished"))
		f.result(nil)
	case strings.Contains(said, "HANDBACK"):
		f.say(nil, text("Started a subagent"))
		f.result(nil)
		// A background subagent's report comes back as a peer message the
		// CLI writes itself: echoed like a written message, recorded as a
		// meta line.
		handback := map[string]any{"role": "user", "content": "Another Claude session sent a message:\n<agent-message from=\"a9\">\n  report\n</agent-message>"}
		id := newSessionUUID()
		if f.replay {
			f.out(map[string]any{"type": "user", "isReplay": true, "uuid": id, "session_id": f.session, "parent_tool_use_id": nil, "message": handback})
		}
		f.line(map[string]any{"type": "user", "uuid": id, "isMeta": true, "origin": map[string]any{"kind": "peer", "from": "a9", "handback": true}, "message": handback})
		f.say(nil, text("The subagent said: report"))
		f.result(nil)
	case strings.Contains(said, "AGENT"), strings.Contains(said, "REPORT"):
		f.say(nil, tool("toolu_agent", "Agent", map[string]any{"description": "Look around", "prompt": "Look around", "subagent_type": "general-purpose"}))
		agent := &fakeAgent{id: "a1b2c3d4e5f6a7b8c", tool: "toolu_agent"}
		f.out(map[string]any{"type": "system", "subtype": "task_started", "task_id": agent.id, "tool_use_id": agent.tool, "description": "Look around", "subagent_type": "general-purpose", "session_id": f.session})
		// The CLI streams the subagent's messages, but not its prompt.
		f.write(agent.transcript(f), &agent.chain, map[string]any{"type": "user", "isSidechain": true, "agentId": agent.id, "message": map[string]any{"role": "user", "content": "Look around"}})
		f.say(agent, tool("toolu_sub_ls", "Bash", map[string]any{"command": "ls"}))
		f.toolResult(agent, "toolu_sub_ls", "README.md", nil)
		if strings.Contains(said, "REPORT") {
			// A subagent may report through a tool instead of a message.
			f.say(agent, tool("toolu_sub_report", "SubagentHandback", map[string]any{"message": "Found a README"}))
			f.toolResult(agent, "toolu_sub_report", `{"success":true,"message":"Report delivered to your caller."}`, nil)
		} else {
			f.say(agent, text("Found a README"))
		}
		f.toolResult(nil, agent.tool, "Found a README", map[string]any{"status": "completed", "agentId": agent.id, "description": "Look around", "resolvedModel": "fake-model"})
		f.say(nil, text("The agent found a README"))
		f.result(nil)
	case strings.Contains(said, "BACKGROUND"):
		f.say(nil, tool("toolu_bg", "Bash", map[string]any{"command": "make test", "run_in_background": true}))
		f.out(map[string]any{"type": "system", "subtype": "task_started", "task_id": "task-bg", "tool_use_id": "toolu_bg", "description": "make test", "session_id": f.session})
		f.toolResult(nil, "toolu_bg", "Command running in background", map[string]any{"backgroundTaskId": "task-bg"})
		f.result(nil)
	case strings.Contains(said, "COMPACT"):
		f.say(nil, text("Before compacting"))
		f.out(map[string]any{"type": "system", "subtype": "status", "status": "compacting", "session_id": f.session})
		f.out(map[string]any{"type": "system", "subtype": "compact_boundary", "session_id": f.session})
		f.line(map[string]any{"type": "system", "subtype": "compact_boundary"})
		// The CLI keeps the last assistant message after the boundary and
		// sends it again.
		kept := map[string]any{"id": fmt.Sprintf("msg_%d", f.messages), "role": "assistant", "content": []any{map[string]any{"type": "text", "text": "Before compacting"}}}
		uuid := f.line(map[string]any{"type": "assistant", "message": kept})
		f.out(map[string]any{"type": "assistant", "uuid": uuid, "session_id": f.session, "message": kept})
		f.result(nil)
	case strings.Contains(said, "CLEAR"):
		f.session = "22222222-2222-4222-8222-222222222222"
		f.out(map[string]any{"type": "conversation_reset", "new_conversation_id": f.session, "session_id": f.session})
		f.result(nil)
	case strings.Contains(said, "SIGNED_OUT"):
		message := map[string]any{"id": "msg_err", "role": "assistant", "content": []any{map[string]any{"type": "text", "text": "Invalid API key · Please run /login"}}}
		f.line(map[string]any{"type": "assistant", "isApiErrorMessage": true, "message": message})
		f.out(map[string]any{"type": "assistant", "session_id": f.session, "error": "authentication_failed", "message": message})
		f.result(map[string]any{"is_error": true, "result": "Invalid API key · Please run /login"})
	case strings.Contains(said, "CRASH"):
		f.say(nil, text("About to fall over"))
		os.Exit(3)
	default:
		f.say(nil, text("Hello world"), tool("toolu_1", "Bash", map[string]any{"command": "echo hi", "description": "Say hi"}))
		f.out(map[string]any{"type": "control_request", "request_id": "perm-1", "request": map[string]any{
			"subtype": "can_use_tool", "tool_name": "Bash", "tool_use_id": "toolu_1", "input": map[string]any{"command": "echo hi", "description": "Say hi"},
			"permission_suggestions": []map[string]any{{"type": "addRules", "rules": []map[string]any{{"toolName": "Bash"}}, "behavior": "allow", "destination": "localSettings"}},
		}})
		f.approved = func(allowed bool) {
			if allowed {
				// A command in the foreground runs as a task too, which ends
				// before its result.
				f.out(map[string]any{"type": "system", "subtype": "task_started", "task_id": "b1", "tool_use_id": "toolu_1", "description": "Say hi", "task_type": "local_bash", "session_id": f.session})
				f.out(map[string]any{"type": "system", "subtype": "task_notification", "task_id": "b1", "tool_use_id": "toolu_1", "status": "completed", "summary": "Say hi", "session_id": f.session})
				f.toolResult(nil, "toolu_1", "hi", map[string]any{"stdout": "hi"})
			} else {
				f.toolResult(nil, "toolu_1", "The user declined this action.", nil)
			}
			f.say(nil, text("Done"))
			f.result(nil)
		}
	}
}

func (f *fakeCLI) control(message map[string]any) {
	requestID, _ := message["request_id"].(string)
	request, _ := message["request"].(map[string]any)
	if encoded, err := json.Marshal(request); err == nil && f.session != "" {
		f.log(fakeControlLog, string(encoded))
	}
	respond := func(payload any) {
		f.out(map[string]any{"type": "control_response", "response": map[string]any{"subtype": "success", "request_id": requestID, "response": payload}})
	}
	switch request["subtype"] {
	case "initialize":
		respond(map[string]any{
			"commands": []map[string]any{{"name": "compact", "description": "Compact context", "argumentHint": "[instructions]"}},
			"models": []map[string]any{
				{"value": "default", "resolvedModel": "fake-model", "displayName": "Default", "description": "Recommended", "supportsEffort": true, "supportedEffortLevels": []string{"low", "high"}},
				{"value": "fake-model", "resolvedModel": "fake-model", "displayName": "Fake", "description": "Test model"},
			},
			"account":                 map[string]any{"email": "fake@example.com", "subscriptionType": "Claude Max", "apiProvider": "firstParty"},
			"current_permission_mode": "default",
		})
	case "stop_task":
		respond(map[string]any{})
		f.out(map[string]any{"type": "system", "subtype": "task_notification", "task_id": request["task_id"], "tool_use_id": "toolu_bg", "status": "stopped", "summary": "Stopped", "session_id": f.session})
		f.line(map[string]any{"type": "attachment", "attachment": map[string]any{
			"type": "queued_command", "commandMode": "task-notification",
			"prompt": "<task-notification>\n<task-id>task-bg</task-id>\n<tool-use-id>toolu_bg</tool-use-id>\n<status>stopped</status>\n<summary>Stopped</summary>\n</task-notification>",
		}})
	case "interrupt":
		respond(map[string]any{})
		if f.slow {
			f.slow = false
			f.line(map[string]any{"type": "user", "message": map[string]any{"role": "user", "content": []any{map[string]any{"type": "text", "text": "[Request interrupted by user]"}}}})
			f.result(map[string]any{"subtype": "error_during_execution", "terminal_reason": "aborted_streaming", "result": ""})
		}
	default:
		respond(map[string]any{})
	}
}
