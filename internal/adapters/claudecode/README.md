# Claude Code provider (`claude-code`)

Native maiD provider that runs the **Claude Code harness** (not the raw
Anthropic API) by spawning the `claude` CLI and speaking its stream-json
protocol — the same wire protocol the official Claude Agent SDKs
(TypeScript/Python) speak. There is no official Go Agent SDK; those SDKs are
thin wrappers that spawn this same CLI, so this adapter *is* the Agent SDK
architecture minus the wrapper. Users get built-in tools, CLAUDE.md, settings,
hooks, their configured MCP servers, skills, and claude.ai subscription auth
exactly as in the terminal.

Checked against CLI `2.1.294`, `@anthropic-ai/claude-agent-sdk` `0.3.295`
typings and the Python SDK `0.2.165` session helpers (`sessions.py`,
`session_mutations.py`); protocol shapes were verified against the installed
CLI.

## Architecture

```
internal/adapters/claudecode/
├── protocol.go   wire DTOs (stream-json messages, control protocol, transcripts)
├── client.go     streamClient: line reader, control request/response correlation
├── adapter.go    Instance, Config, capabilities, per-thread session registry
├── session.go    process spawn/teardown, StartSession/SendTurn/Interrupt/Stop,
│                 SetConfigOption, steering
├── events.go     stream-json -> provider.RuntimeEvent mapping, approvals
├── convert.go    pure conversions (tool_use -> ToolCall, results, permissions)
├── plan.go       the plan kept by the Task tools
├── catalog.go    initialize probe, config options, skill discovery, options facet
├── transcript.go transcript paths and the current conversation of a transcript
├── replay.go     transcript -> replayed events
├── history.go    session list/delete/close/fork/rename, list titles
└── auth.go       sign-in, CLI environment
```

`protocol.go` + `client.go` import nothing from `internal/provider`; they are
extractable as a standalone Go agent-SDK client library.

### Process model

Codex runs **one** app-server for all threads. The claude CLI is one process
**per conversation**, so `Instance` holds `sessionsByLocal` (threadID →
`claudeSession`), each owning a `sessionProcess` (a `procgroup.Process` and its
`streamClient`).

- `OpenInstance` runs a **probe**: spawn the CLI, send `initialize`, kill. The
  CLI answers before any API request, so it is free, works logged-out, and
  returns the account (auth status), the model catalog with per-model effort
  levels, the commands, and `current_permission_mode` (the user's configured
  default mode).
- Per-thread spawn (`spawnProcess`):
  ```
  claude --print --input-format stream-json --output-format stream-json --verbose
    --include-partial-messages --replay-user-messages --permission-prompt-tool stdio
    --allow-dangerously-skip-permissions        # enables bypass as an OPTION only
    --thinking-display summarized               # newer models omit thinking text otherwise
    (--session-id <uuid> | --resume <uuid>)     # resume iff the transcript exists
    [--model X] [--effort Y] [--permission-mode M] [--add-dir D]...
  ```
  `--permission-mode` is passed only for a mode the user chose; otherwise the
  CLI starts in the user's configured default, which `initialize` reports and
  maiD shows.
- Processes start through `procgroup.Start`: own process group, and a stdout
  pipe that stays readable after exit, so the CLI's last result or error is
  still delivered (`Drain`). Stopping closes stdin and gives the CLI 5 s to
  exit on its own (it flushes the transcript then, as the SDKs wait for)
  before killing the group.
- The CLI's environment drops the variables an enclosing Claude Code session
  sets (`CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`, …), so a daemon started from
  inside Claude Code does not spawn child sessions.

### Turn model

Claude has **no native turn ids**, so one daemon turn id at a time stands for
the CLI's work, from the message that starts it to the `result` that ends it.
The CLI runs with `--replay-user-messages`, so it echoes each written message
(`isReplay`, same `uuid`) when it takes it into a query.

- `SendTurn` writes the user message with a fresh `uuid` and emits
  `turn.started`.
- A steer (`SendTurnInput.Steer`) writes the message with `"priority":"next"`.
  The CLI folds it into the running query at the next tool boundary and echoes
  it; one it could not fold runs as one more query with its own `result`. So a
  `result` that arrives while a written message is unechoed keeps the turn
  open. A steer of a turn that already ended fails with `ErrTurnNotRunning`.
- Output while no turn is active (a background task or agent finishing wakes
  the CLI) starts a CLI-started turn, completed by its own `result`.
- A `result` with no active turn (resume handshake) is ignored.
- `InterruptTurn` sends `{"subtype":"interrupt","cancel_queued":true}`, which
  also drops unfolded steers, so the aborted `result` ends the turn.
- When the process exits with a turn active, the turn completes as
  interrupted (deliberate stop) or failed (crash).

### Event mapping

| CLI stream | RuntimeEvent |
|---|---|
| `stream_event` `text_delta` / `thinking_delta` | `content.delta` (`assistant_text` / `reasoning_text`) |
| `content_block_start` tool use | `item.started` (ItemID = `toolu_...`) |
| `input_json_delta` | re-parsed partial input, `item.updated` with the complete snapshot |
| `assistant` (per block) | flush checkpoint: missing text suffix, `item.completed`; tools that never streamed. A message already shown (resent after `/compact`) and the CLI's API-error message are skipped |
| `user` `tool_result` | `item.completed`; Edit/Write take the CLI's `structuredPatch` (line-numbered hunks) and Write's create/update from `tool_use_result` |
| `tool_use_result` with `backgroundTaskId` (Bash) or `status: async_launched`/`remote_launched` (Agent, Workflow) | the tool stays running (`item.updated`) until `system/task_notification` completes it in its turn; in replay the `<task-notification>` message does |
| `TodoWrite` input; `TaskCreate`/`TaskUpdate`/`TaskList` results | `turn.plan.updated` (no timeline item) |
| `result` | `thread.token-usage.updated` (live context from the last `usage.iterations` entry, window of the session's model, cost); a local command's zero usage keeps the meter; then `turn.completed` |
| `system/init` | adopt the CLI's session id; permission mode and model (e.g. after `/model`) → `config.options.updated` |
| `system/status` | permission mode; `compacting` → compaction item in progress |
| `system/compact_boundary` | compaction item completed |
| `system/api_retry` | `runtime.warning` |
| `system/informational` (warnings, prompts a hook blocked) | `runtime.warning` |
| `conversation_reset` (`/clear`) | follow the new session id; "Cleared context" item |
| `parent_tool_use_id != null` | dropped — subagent narration; the Agent tool item represents it |

`result.errors` entries prefixed `[ede_diagnostic]` are CLI telemetry and are
never surfaced.

### Permissions

`--permission-prompt-tool stdio` makes the CLI send `control_request
{subtype:"can_use_tool", ...}`:

- Request type: Bash → command; Edit/Write/NotebookEdit → file change; Read →
  file read; else dynamic tool.
- Options: allow once, decline, and — like the CLI — "Allow for session" only
  when the CLI sent permission suggestions and did not set
  `suppress_always_allow_rule`. Suggestions are rewritten to
  `destination:"session"` so nothing persists to settings files.
- **AskUserQuestion** → provider-neutral user-input request; answers go back in
  `updatedInput.answers` keyed by question text.
- **MCP elicitation** → `internal/adapters/elicitation`.
- **ExitPlanMode** → user-input request whose message is the plan: "Approve
  plan" or "Keep planning", with an optional typed answer sent to the model as
  the deny message. Either answer resolves the request as accepted, so the chat
  keeps it.
- `control_cancel_request` resolves the request as cancelled.

### Sessions on disk

Transcripts: `<configDir>/projects/<sanitized real cwd>/<session-id>.jsonl`
(configDir = `Config.ConfigDir` || `$CLAUDE_CONFIG_DIR` || `~/.claude`).
Sanitizing replaces non-alphanumerics with `-`; names over 200 characters get
a hash only the CLI computes, so they are found by prefix. Lookups by session
id search every project directory.

- **Replay** (`replay.go`): built like the SDK's `get_session_messages` — the
  `parentUuid` chain from the newest main-chain leaf, so branches the user
  rewound away from are left out — but continuing across compactions and
  keeping parallel tool calls (sibling lines). Steers (stored only as
  `queued_command` attachments) join their turn; the interrupt marker ends its
  turn as interrupted; API-error messages fail their turn; slash commands show
  as typed; compaction summaries and CLI bookkeeping are hidden; a background
  task waking the CLI starts a turn with no prompt. Event ids are
  deterministic.
- **Titles**: a name the user chose (`custom-title`, from `/rename` or maiD)
  else the first prompt. Generated `ai-title`s are ignored, as maiD titles
  threads by their prompt.
- **DeleteSession**: removes the transcript and its subagent folder.
- **ForkSession**: the SDK's `_build_fork_lines` — new session and message
  uuids with the chain kept, sidechain/progress lines dropped, `forkedFrom`
  recorded, titled "<source> (fork)".
- **RenameSession**: appends a `custom-title` line (the SDK's `renameSession`)
  and tells a live CLI through `rename_session`.

### Config options

- `model`: catalog from `initialize`; switched live with `set_model`.
- `effort`: per-model levels + "default"; switched live with
  `apply_flag_settings {effortLevel}` (`null` returns to the model default).
- `permission_mode`: default/auto/acceptEdits/plan/dontAsk/bypassPermissions;
  switched live with `set_permission_mode`.

### Landmines (keep these)

- Set `CLAUDE_CONFIG_DIR`, **never override `HOME`** — that breaks macOS
  keychain OAuth and the CLI reports "Not logged in".
- The CLI is authoritative for the session id (`system/init`,
  `conversation_reset`); the next StartSession persists it.
- Every stream callback fences on `session.proc == proc` so a replaced process
  cannot mutate its successor's state.
- On process exit: settle the active turn and cancel pending approvals.

## Registration

`internal/daemon/server.go`: `openProviderInstance` case + manifest instance
`{InstanceID:"claude-code", Name:"Claude Code"}`. Config accepts
`{command, env, configDir}`; defaults to `["claude"]` on PATH.

Sign-in (`auth.go`): the CLI only signs in interactively, so Authenticate
returns `claude auth login [--console]` for the daemon to run in a terminal;
the daemon restarts the instance afterwards. Logout runs `claude auth logout`.
An assistant message with `error: "authentication_failed"` marks the instance
signed out.

## Known gaps

Need contract or client work: stopping a background task (`stop_task`),
subagent narration as nested items, hook lifecycle events, file rewind,
forking from a chosen message, and the cost/compacting/retry details the client does not show yet.
Audio and embedded-resource attachments are not part of the SDK prompt
surface; `resource_link` attachments are skipped since the CLI reads `@path`
in the prompt text.

## Testing

- `go test ./internal/adapters/claudecode/` — conversion and replay tests plus
  an integration suite driving a **fake CLI**: `TestMain` re-executes the test
  binary with `CLAUDE_FAKE_CLI=1` (see `fakeCLIMain`).
- `CLAUDE_LIVE_TEST=1 go test ./internal/adapters/claudecode/ -run TestLiveSmoke -v`
  — end-to-end against the real CLI on **haiku** (skips when logged out).
