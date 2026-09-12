# Verification of the beta-stack review findings

Scope: the other model's review of `aq/beta-01…07`, verified against the clean worktree
`~/Code/Personal/worktrees/maid-beta-stack` (commit `65b0a43`, `aq/beta-07-stability-followups`).
No source changes were made. Sources of truth used: pinned `go-acp@v0.0.0-20260710233715`,
`~/Code/Personal/codex/codex-rs/app-server-protocol`, `~/Code/Personal/codex/codex-rs/core`,
T3 Code, gemini-cli, and the Zed-installed `claude-code-acp@0.4.2` dist.

Validation re-run on the beta stack (all green): `gofmt -l`, `go vet ./...`, `go test ./...`,
`go test -race -count=1` on providerservice / codexapp / orchestration, `git diff --check`.
Swift tests were not run: the open Xcode workspace is on the unrelated WIP branch, and
`clients/swift/AGENTS.md` says not to run Swift tests unless told.

---

## Finding 1 — Dead DTOs in `codexapp/protocol.go`; fork `lastTurnId` unreachable

**Verdict: CORRECT, but overstated in severity. Partial fix worth doing; the proposed full fix is not.**

Verified:
- 40 of 64 struct types in `internal/adapters/codexapp/protocol.go` have zero references
  outside that file. The request-param DTOs (`threadStartParams`, `threadResumeParams`,
  `threadForkParams`, `turnStartParams`, `modelListParams`, `accountReadParams`,
  `thread{Read,Delete,Unsubscribe,List}Params`) and every `*Notification` type are dead.
  `session.go` sends `map[string]any`; `events.go` decodes with inline anonymous structs.
- `tokenUsageFromApp` (`convert.go:1134`) has no callers. Same class.
- `threadForkParams.LastTurnID` is the only place `lastTurnId` appears in Go, Swift, or the
  wire layer. `provider.ForkSessionInput` has only `ProviderSessionID`;
  `codexapp.ForkSession` sends `{"threadId": ...}` only. The official
  `ThreadForkParams` (`protocol/v2/thread.rs:509`) does define `last_turn_id` as an
  optional, nullable, stable field.

Would users hit it? No. There is no UI to pick a turn boundary. Fork of the whole thread
works. This is a criteria gap ("supports optional last-turn boundaries") and dead code,
not a runtime defect.

Is the proposed fix worth it?
- Deleting the dead DTOs and `tokenUsageFromApp`: yes, cheap and zero risk. Go vet does not
  flag unused unexported types, so they will otherwise rot silently.
- Consolidating maps/anonymous structs into typed DTOs across `session.go`/`events.go`:
  not worth it in this review. It is a broad mechanical rewrite of working, tested code
  with no behavior change, which the review brief explicitly says to avoid. The
  "two parallel definitions" risk is real but the dead copies are the drift risk, and
  deleting them removes it.
- Wiring `lastTurnId` end to end: only if a "fork from here" UI is planned. Without a UI it
  is speculative API surface. If not planned, delete the field with the rest.

Recommended root fix: delete the dead types and `tokenUsageFromApp`; add a comment on
`ForkSessionInput` that turn boundaries are intentionally unsupported until there is a UI
for them. Skip the DTO consolidation.

---

## Finding 2 — `separateReplayReasoningBlocks` can corrupt replayed reasoning

**Verdict: CORRECT as a fragility. Low impact today. Not worth changing the code; worth one doc line.**

Verified (`internal/adapters/acp/session.go:266`):
- Every replayed reasoning delta not ending in `\n` gets `\n\n` appended. Live deltas pass
  through raw (`acp/convert.go:274`), so live and replay use different join rules.
- gemini-cli replay (`acpClient.ts:636`) emits exactly one whole thought
  (`**subject**\ndescription`) per `agent_thought_chunk`, so the patch is correct for it.
- gemini-cli live streams `part.thought` as chunks (`acpClient.ts:815`), which is the
  "live emits separators" the code comment refers to.
- claude-code-acp 0.4.2 emits one `agent_thought_chunk` per completed thinking block
  (`acp-agent.js:440`) and that build shows no `session/load` support, so it never takes
  the replay path.

Would users hit it? Only with a future ACP agent that both supports `session/load` and
replays a single thought as several sub-newline deltas. No agent in scope does that.
Gemini replay would look wrong without this patch, so removing it is a regression.

Is the proposed fix worth it? A per-agent quirk table is more machinery than the problem
deserves. Unifying live and replay joins would break the Gemini live path. Leave the
code; move or copy the assumption into the package doc / `AGENTS.md` so the next agent
integration knows the replay path assumes one-thought-per-delta.

---

## Finding 3 — Codex completed items are not authoritative for message text

**Verdict: CORRECT, and more serious than reported. This is the one finding worth a code fix.**

Verified structurally (`codexapp/events.go:188-224`, `orchestration/ingestion.go:356-400`):
- On `item/completed` for `agentMessage` / `reasoning`, the snapshot is used only to emit a
  tail delta when `strings.HasPrefix(snapshot, streamed)`. Otherwise it is dropped.
- The completed event for reasoning carries `Detail: reasoningText(item)`, but
  `settleReasoning` ignores `Detail` and records the accumulator. For assistant messages the
  completed event carries no text at all and `ingestAssistantMessageStatus` only flushes.

Verified as a real live divergence, not a latent one:
- Codex core emits `AgentReasoningSectionBreak` between reasoning summary parts
  (`core/src/session/turn.rs:2633`, `:2659`), which app-server forwards as
  `item/reasoning/summaryPartAdded`. Delta text for the next part does not include a
  separator; the `summaryIndex` on each delta and the part-added notification exist so
  clients can insert one. T3 Code maps `summaryPartAdded` to a reasoning item update.
- maiD handles only `item/reasoning/textDelta` and `summaryTextDelta` (`events.go:44`) and
  concatenates them into one string. It does not handle `summaryPartAdded` or watch
  `summaryIndex`. Nothing in `codexapp/*_test.go` covers a multi-part summary.
- `reasoningText(item)` joins the completed `summary: Vec<String>` with `\n\n`. So for a
  two-part summary, `streamed = "A" + "B"` and `snapshot = "A\n\nB"`. `HasPrefix` fails,
  no tail delta is emitted, `Detail` is ignored, and the transcript keeps `"AB"` with the
  second heading glued to the first part's last sentence. Neither the live view nor the
  settled view gets the break. Replay (`thread/read`) goes through `reasoningText` and is
  correct, so a reloaded thread will look different from the one the user just watched.

Would users hit it? Yes, whenever a Codex reasoning model produces more than one summary
part in a turn, which is the normal case for non-trivial prompts. Not verified against a
live app-server in this session; recommend a quick manual check with reasoning summaries
enabled before prioritizing.

Root fix (small): handle `item/reasoning/summaryPartAdded` in `events.go` by appending
`"\n\n"` to `session.streamedText[itemID]` and emitting it as a reasoning delta (only when
the buffer is non-empty and does not already end in a newline). That makes live match the
completed snapshot and makes the existing `HasPrefix` tail logic succeed. Add a test that
streams two summary parts and asserts the settled reasoning text contains the break.

Optional hardening (the reviewer's proposal): when the snapshot is not a prefix extension,
emit a full-replacement event so the transcript converges on the snapshot. That is a new
event type through ingestion and projection. Only do it if the small fix is not enough in
practice; it is not needed to solve the observed divergence.

---

## Finding 4a — ACP options sessions leak on client abandonment

**Verdict: INCORRECT. Already handled.**

`internal/daemon/rpc.go:274` calls `closeClientOptionsSessions` on client disconnect, which
iterates every open options session and calls `CloseOptionsSession` with a 3s timeout
(`rpc.go:825-844`). The ACP adapter then calls `session/close` when the agent advertises
the capability and unbinds locally either way (`acp/session.go:97`). The only remaining case
is an agent with no `session/close` capability, where nothing the daemon does can free the
native session. No fix needed.

---

## Finding 4b — `emitCommandOutput` before `item/started` emits a zero-valued ToolCall

**Verdict: CORRECT in code, unreachable in practice. Optional one-line guard.**

`events.go:270-291` reads `session.items[itemID]`, gets a zero value for an unknown item,
appends the delta, and emits `ItemUpdated` with empty Action/Name. App-server sends
`item/started` before any `outputDelta` on a single ordered stdout stream, so the case
does not occur. A guard that drops output deltas for unknown items is cheap and harmless
but not required.

---

## Finding 4c — `tokenUsageFromApp` unreferenced

**Verdict: CORRECT.** Fold into finding 1's dead-code deletion.

---

## Spot checks of the "verified correct" section

Sampled, all confirmed:
- `ExperimentalAPI: false` in `codexapp/adapter.go:175`.
- No `Fork` anywhere in `internal/adapters/acp` non-test code.
- `internal/daemon/web` and `web.go` absent; the only `react` hits are `ProviderEventReactor`.
- Late close/delete/import results guarded by `effectiveAgentID == agentID` in
  `SessionImportModel.swift:83,96,112`.

Not independently re-verified: generation fencing, import/fork transaction atomicity,
recycled-PID fences, streaming reveal internals, attachment caps. The other review's claims
there were not contradicted by anything found here.

---

## Priority summary

| # | Finding | Correct? | User-facing? | Action |
|---|---------|----------|--------------|--------|
| 3 | Completed items not authoritative; `summaryPartAdded` ignored | Yes, worse than stated | Yes, likely common | Fix: handle `summaryPartAdded` as a `\n\n` delta, plus a test |
| 1 | Dead DTOs, `lastTurnId` unwired | Yes | No | Delete dead types and `tokenUsageFromApp`; skip DTO consolidation; do not wire `lastTurnId` without a UI |
| 2 | Replay reasoning separator assumption | Yes, fragility | No agent in scope | Document at package level; leave code |
| 4b | Output delta before item start | Yes, unreachable | No | Optional guard |
| 4a | Options-session leak | No | No | None |
| 4c | Dead `tokenUsageFromApp` | Yes | No | Delete with finding 1 |

---

## Fixes applied (worktree `~/Code/Personal/worktrees/maid-beta-stack`, uncommitted)

Own findings beyond the other review: the ignored `summaryPartAdded` boundary (extends
finding 3), and three more unused functions found by staticcheck U1000
(`Instance.sessionForLocal`, `rpcClient.wait` plus its orphaned `done` channel,
`containsSkillToken`).

- **Finding 3, root fix in two layers.**
  `codexapp/events.go`: reasoning deltas now track which part they belong to
  (`summaryIndex` / `contentIndex`, stored in `streamedItem.part`) and insert the same
  paragraph break the completed item uses when the part changes, so live text, the
  completion tail, and replay agree. `summaryPartAdded` is an explicit no-op.
  `orchestration/ingestion.go`: a completed reasoning item's `Detail` snapshot now replaces
  the streamed accumulation on settle (`settleReasoningWith`), documented on the contract.
  Tests: `TestReasoningPartsStreamWithParagraphBreaksAndMatchCompletedSnapshot`,
  `TestIngestionCompletedReasoningSnapshotIsAuthoritative`.
- **Finding 1 / 4c.** Deleted all 33 unused DTOs from `protocol.go` and the four unused
  functions above. `ForkSessionInput` now documents that the turn boundary is intentionally
  unexposed. Typed-DTO consolidation was not done (behavior-neutral rewrite, out of scope).
- **Finding 2.** Replay assumption documented as the `acp` package doc comment.
- **Finding 4b.** `emitCommandOutput` drops deltas for items that never started, with a
  test.
- **Finding 4a.** No change; already handled.

Validation after fixes: gofmt, `go generate ./api/wire` (zero diff), `go vet`, `go test ./...`,
race tests on providerservice/codexapp/orchestration, `git diff --check`, and
staticcheck U1000 over `./internal/...` all clean. Swift not affected; no Swift build run.
