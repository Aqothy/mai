# maiD — Future Work

Only actionable deferred work belongs here. Persistence is complete for the intended design:
SQLite stores thread/provider metadata, providers own conversation history, and the event
log remains process-local (`docs/PERSISTENCE_PLAN.md`).

## 1. Stable ACP through provider-neutral contracts

Finish this section before product/workspace features. ACP details stay inside the adapter;
orchestration and clients consume provider-neutral capabilities and types.

### MCP server forwarding — next

Load transport-neutral MCP server configuration from maiD  
settings and forward the  
resolved configuration to providers. maiD does not host or
proxy an MCP tool server.

- Define transport-neutral MCP configuration in  
  `internal/provider/contract.go` and carry  
  the resolved list in `provider.StartSessionInput`.
- Resolve current global/project MCP configuration before  
  every new/load/resume; do not  
  persist resolved MCP configuration or secrets in thread  
  routes.
- Populate `NewSessionRequest`, `LoadSessionRequest`, and  
  `ResumeSessionRequest` in  
  `internal/adapters/acp/session.go`.
- Gate HTTP/SSE with existing `Capabilities.MCP`; stable  
  ACP stdio requires no capability.
- Treat the list as immutable for a live ACP session.  
  Applying changes requires  
  resume/load with the full updated list because stable  
  ACP has no live MCP update method.
- Resolve secret references only at the adapter boundary  
  and redact them from events,  
  descriptors, errors, and logs.
- Future native adapters map the same intent through their
  SDK/configuration interface or  
  advertise unsupported.

### Additional session directories — later

Add provider-neutral primary + additional workspace roots only when multi-root thread UX is
prioritized.

- Carry roots in session input, route persistence, snapshots, and imported session summaries.
- Map them to ACP `additionalDirectories` on new/load/resume only when advertised.
- Validate and deduplicate paths; initially make roots immutable after session creation
  because stable ACP has no live update method.
- Future adapters map an equivalent native feature or advertise unsupported.

## 2. Provider infrastructure — not ACP features

### Environment and named instances

- Add `env` to `acp.Config`; merge it with `os.Environ()` before assigning `exec.Cmd.Env` in
  `internal/adapters/acp/adapter.go`.
- Expose persisted cold `InstanceSpec`s as named instances so the picker remains useful after
  daemon restart; storage already exists in `internal/store`.
- Never return environment secrets from provider descriptors or diagnostics.
- Add a driver-factory registry only when a second driver makes the switch in
  `internal/daemon/server.go` unwieldy.

## 3. Product/workspace roadmap

1. **Git status and aggregate diffs** — use thread `cwd`; invoke native Git with porcelain,
   null-delimited output, deadlines, and output limits. Start without persistence.
2. **Projects/workspaces** — persist project ID, title, workspace roots, and thread ownership
   in `internal/store`.
3. **Per-turn checkpoints, diffs, and revert** — capture hidden Git refs before/after turns,
   diff adjacent checkpoints, confirm restore, and clean refs up with threads.
4. **Terminal** — backend PTY create/attach/input/resize/stop with streamed output and bounded
   scrollback; xterm.js renders it in the client. No multiplexing or persisted transcript.
5. **Optional worktree isolation** — branch picker plus explicit create/remove worktree;
   retain the current working tree as the default.
6. **Minimal project file access** — directory listing, bounded text reads, and search for
   navigation/review; do not turn this into ACP filesystem callbacks or an IDE editing API.

Later if needed: commit/push, archive/delete, selective staging, worktree cleanup, and one
provider-neutral pull-request seam.

## Explicit non-goals

- Durable/full event-store or server-owned conversation-history persistence.
- Thick history mode, synced drafts, or server-managed hosted auth/tenancy.
- Generic multi-VCS abstraction before a second VCS is planned.
- Cloud relay platform, preview automation, language services, full IDE filesystem editing,
  or terminal multiplexing.
