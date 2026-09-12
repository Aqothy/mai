# Claude Code provider (`claude-code`)

Native maiD provider that runs the **Claude Code harness** (not the raw
Anthropic API) by spawning the `claude` CLI and speaking its stream-json
protocol — the exact same wire protocol the official Claude Agent SDKs
(TypeScript/Python) speak. There is no official Go Agent SDK; those SDKs are
thin wrappers that spawn this same CLI, so this adapter *is* the Agent SDK
architecture minus the wrapper. Users get built-in tools, CLAUDE.md, settings,
hooks, their configured MCP servers, skills, and claude.ai subscription auth
exactly as in the terminal.

Written against CLI `2.1.226` and `@anthropic-ai/claude-agent-sdk` `0.3.239`
typings; all protocol shapes below were verified empirically against the
installed CLI, not just docs.

## Architecture

```
internal/adapters/claudecode/
├── protocol.go   wire DTOs (stream-json messages, control protocol, transcripts)
├── client.go     streamClient: line reader, control request/response correlation
├── adapter.go    Instance, Config, capabilities, per-thread session registry
├── session.go    process spawn/teardown, StartSession/SendTurn/Interrupt/Stop,
│                 SetConfigOption, turn queueing
├── events.go     stream-json -> provider.RuntimeEvent mapping, approvals
├── convert.go    pure conversions (tool_use -> ToolCall, results, permissions)
├── catalog.go    initialize probe, config options, skill discovery, options facet
├── history.go    transcript replay, list/delete/close/fork sessions
└── proc_*.go     process-group helpers (copied fencing pattern from codexapp)
```

`protocol.go` + `client.go` deliberately import nothing from
`internal/provider` — they are extractable later as a standalone Go
agent-SDK client library with a mechanical move.

### Process model (differs from codexapp!)

Codex runs **one** app-server process for all threads. The claude CLI is one
process **per conversation**, so:

- `Instance` holds `sessionsByLocal` (threadID → `claudeSession`), each owning
  its own `sessionProcess` (cmd, stdin, `streamClient`).
- `OpenInstance` never starts a long-lived process. It runs a **probe**: spawn
  CLI, send the `initialize` control request, read the response, kill. The CLI
  answers initialize **before any API request**, so the probe is free, works
  logged-out, and returns in one round trip:
  - `account` (email, subscriptionType, apiProvider) → auth status
  - `models` — full per-model matrix (`supportedEffortLevels`,
    `supportsAdaptiveThinking`, `supportsFastMode`, …). Unlike ACP, you do NOT
    need to select a model to learn its config space.
  - `commands` (slash commands + skills, with descriptions/argument hints)
- Per-thread spawn (in `spawnProcess`):
  ```
  claude --print --input-format stream-json --output-format stream-json --verbose
    --include-partial-messages --permission-prompt-tool stdio
    --allow-dangerously-skip-permissions        # enables bypass as an OPTION only
    (--session-id <uuid> | --resume <uuid>)     # resume iff transcript exists
    [--model X] [--effort Y] [--permission-mode M] [--add-dir D]...
  ```
  The daemon generates the session UUID up front (`--session-id`) so the
  durable id is known before the CLI answers. `--resume` is used only when the
  transcript file actually exists; otherwise a resume of a never-run session
  would fail.

### Turn model

Claude has **no native turn ids**. A turn = one queued user message through its
`result` line. The daemon's TurnID is authoritative:

- `SendTurn` writes a user message to stdin. If no turn is active, it becomes
  `activeLocalTurn` and `turn.started` is emitted. If a turn is running, the
  TurnID is appended to `queuedTurns` (the CLI queues stdin messages and runs
  them sequentially, emitting one `result` each).
- `handleResult` completes `activeLocalTurn`, pops the next queued turn, emits
  its `turn.started`.
- A `result` with no active local turn (resume handshake) is **ignored** —
  emitting turn lifecycle there corrupts session state (learned from t3code).
- `InterruptTurn` sends control `{"subtype":"interrupt","cancel_queued":true}`;
  the active turn completes via its aborted `result`, queued turns are
  completed as `cancelled` locally (they never produce results).
- `terminal_reason` containing `aborted` ⇒ `RuntimeTurnInterrupted`, not failed.

### Event mapping

| CLI stream | RuntimeEvent |
|---|---|
| `stream_event` `text_delta` / `thinking_delta` | `content.delta` (`assistant_text` / `reasoning_text`); item ids `claude:text:<turn>:<n>` / `claude:reasoning:...` |
| `content_block_start` `tool_use`/`server_tool_use`/`mcp_tool_use` | `item.started` (ItemID = `toolu_...`, stable across lifecycle) |
| `input_json_delta` | accumulate partial JSON, re-parse, `item.updated` on fingerprint change (complete ToolCall snapshots only — contract requirement) |
| `assistant` snapshot (per block) | flush checkpoint: emit missing text suffix vs streamed, then `item.completed` (assistant_message / reasoning); materialize tool blocks that never streamed |
| `user` `tool_result` | merge output/error into ToolCall, `item.completed` (failed if `is_error`) |
| `TodoWrite` input | `turn.plan.updated` (no timeline item) |
| `result` | `thread.token-usage.updated` (last `usage.iterations` entry = live context; MaxTokens = max `modelUsage[].contextWindow`; Cost = `total_cost_usd`) then `turn.completed` |
| `system/init` | adopt CLI session id if it differs; permission-mode drift → `config.options.updated` |
| `system/status` (permissionMode) | `config.options.updated` (fires when ExitPlanMode approval flips the mode) |
| `system/compact_boundary` | `context_compaction` item |
| `parent_tool_use_id != null` | **dropped** — subagent narration; the Task tool item represents the delegation |

Error text filtering: `result.errors` entries prefixed `[ede_diagnostic]` are
CLI-internal telemetry and are never surfaced.

### Permissions

`--permission-prompt-tool stdio` makes the CLI pause tools and send
`control_request {subtype:"can_use_tool", tool_name, input,
permission_suggestions, tool_use_id, decision_reason, ...}`. Mapping:

- request type: Bash/BashOutput/KillShell → command_execution_approval;
  Edit/Write/NotebookEdit → file_change_approval; Read → file_read_approval;
  else dynamic_tool_call. Options: accept / acceptForSession / decline.
- Response is a `PermissionResult`: allow ⇒ `{behavior:"allow", updatedInput}`;
  deny ⇒ `{behavior:"deny", message, interrupt?}`.
- **acceptForSession**: the CLI's suggestions default to `localSettings`
  (would persist to `.claude/settings.local.json`!) — every suggestion is
  rewritten to `destination:"session"`, with a whole-tool session `addRules`
  fallback when no suggestions came (common for MCP tools).
- **AskUserQuestion** (single question): answer options become approval
  Options (`answer:<i>`); the allow response sets
  `updatedInput.answers = {<full question text>: <label>}` — the SDK looks
  answers up **by question text**. Multi-question prompts are denied with a
  message telling the model to ask in plain text.
- **ExitPlanMode**: normal approval ("Approve plan"/"Keep planning"); approving
  lets the CLI exit plan mode itself; the resulting mode change flows back via
  `system/status`.
- `control_cancel_request` (CLI no longer needs the answer, e.g. after
  interrupt) resolves the approval as cancelled. Safe commands (e.g. `echo`)
  never generate requests — that's CLI-side allowlisting, not a bug.

### Sessions on disk

Transcripts: `<configDir>/projects/<munged-cwd>/<session-id>.jsonl` where
munging replaces every non-alphanumeric char with `-` (configDir =
`Config.ConfigDir` || `$CLAUDE_CONFIG_DIR` || `~/.claude`).

- **Replay** (`history.go`): parsed directly from the transcript (no CLI
  involved). Turn boundary = each non-meta, non-sidechain user prompt line;
  deterministic event ids `claude:replay:<turn>:<item>:<suffix>`; synthetic
  monotonic timestamps; `ai-title` line → thread title metadata. During a
  replay start, setup events (slash commands/skills) ride the Replay batch,
  never the live sink (contract rule).
- **ListSessions**: directory scan; title from `ai-title` or first prompt.
- **DeleteSession**: removes the transcript (id validated against a UUID-ish
  pattern before any path is built).
- **ForkSession**: copies the transcript to a fresh UUID rewriting each line's
  `sessionId`. Chosen over native `--resume --fork-session` because the native
  path only materializes the fork after a paid turn; the copy is instant, free,
  and immediately resumable.

### Config options

- `model` (category `model`): from probe catalog; live switch via control
  `set_model` (`"default"` ⇒ `model: null` resets).
- `effort` (category `thought_level`): per-selected-model levels + "default".
  **Launch-flag only** — no control message exists; stored and applied at next
  spawn; an idle process is proactively stopped so it takes effect next turn.
- `permission_mode` (category `mode`): default/auto/acceptEdits/plan/dontAsk/
  bypassPermissions. Live switch via `set_permission_mode`. `default` is not a
  valid `--permission-mode` launch value (the flag's ask-mode is `manual`,
  semantics unverified) — so `default` is applied post-spawn via the control
  request instead of guessing.

### Landmines (inherited from t3code's production Claude adapter — keep these)

- Set `CLAUDE_CONFIG_DIR`, **never override `HOME`** — that breaks macOS
  keychain OAuth and the CLI reports "Not logged in".
- Trust the CLI as authoritative for session id (`system/init` may differ on
  fallback); never trust ids from hook-related messages.
- Process fencing: `reaped`/`killedTree` — once `Wait` reaps the leader, never
  signal that pid again (OS pid recycling). Copied verbatim from codexapp.
- Every stream callback fences on `session.proc == proc` so a replaced process
  cannot mutate its successor's state.
- On unexpected process death: fail the active turn, cancel queued turns and
  pending approvals (a `request.resolved` must be emitted on every exit path).

## Registration

`internal/daemon/server.go`: `openProviderInstance` case + manifest instance
`{InstanceID:"claude-code", Name:"Claude Code"}`. Config accepts
`{command, env, configDir}`; defaults to `["claude"]` on PATH.

## Capabilities declared

SessionList, SessionDelete, SessionClose, LoadReplay, Resume, Fork, Skills,
ConfigOptions, AdditionalDirectories, PromptContent{Image},
ModelSwitch=in-session. **Auth/Logout are false** — the CLI has no
non-interactive login (the Agent SDK requires pre-existing credentials too);
auth *status* is still reported from the probe account, and users log in via
`claude /login` in a terminal.

## Known gaps

Provider contract can't express (SDK offers them; would need contract work):
subagent narration as nested items (Task shows as a single delegate item),
hook lifecycle events, structured outputs (`--json-schema`), turn/budget
limits (`--max-turns`, `--max-budget-usd`), file rewind/checkpoints,
background tasks, MCP server management from the client (the CLI still loads
the user's own MCP config).

Claude-specific: audio attachments unsupported (codex has them); effort
changes apply from the next turn; `Write` renders as FileChangeAdd and `Edit`
as Update (the CLI doesn't say whether Write created or overwrote).

Claude-only extras other providers lack: full per-model capability matrix in
one free handshake, permission suggestions, plan-approval flow, dollar cost
reporting, AskUserQuestion option prompts.

## Testing

- `go test ./internal/adapters/claudecode/` — pure conversion tests plus an
  integration suite driving a **fake CLI**: `TestMain` re-executes the test
  binary with `CLAUDE_FAKE_CLI=1` (see `fakeCLIMain`) and the adapter points
  `Config.Command` at it. Covers probe, full turn with streaming + approval
  round trip, interrupt, replay determinism, fork, list, delete.
- `CLAUDE_LIVE_TEST=1 go test ./internal/adapters/claudecode/ -run TestLiveSmoke -v`
  — end-to-end against the real CLI on **haiku** (costs ~1¢; skips when
  logged out). Verified passing on 2026-08-22 (CLI 2.1.226).

Protocol references: `@anthropic-ai/claude-agent-sdk` typings (`npm pack`,
see `sdk.d.ts`/`agentSdkTypes.d.ts`/`sdk-tools.d.ts`),
https://code.claude.com/docs/en/agent-sdk/overview.md, and
`~/Code/Personal/t3code/apps/server/src/provider/Layers/ClaudeAdapter.ts`
(TypeScript reference implementation whose workarounds are catalogued above).
