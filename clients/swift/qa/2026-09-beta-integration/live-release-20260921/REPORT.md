# Actual Release app and Codex workflow

The unmodified macOS Release app at `267d18b` completed a real prompt through an isolated local daemon and the bundled Codex CLI 0.155.0-alpha.9.2. `metadata.json` records source, paths and executable hashes. The selected saved model was gpt-5.6-luna. Only Codex received live prompts; the replacement run verifies that Claude remained configured without initialization.

The exact multiline café / 👩🏽‍💻 prompt that crashed the previous archive now submits successfully. Five captured assistant chunks concatenate to the expected Markdown, with ordered unique event sequences. The app clears its composer and working indicator after completion. Clicking the assistant code block's actual Copy button changes its accessibility label to Copied; the system clipboard contains exactly `let answer = 42`. See `turn-result.json`, `code-copy.json`, `first-turn.ndjson` and `completed-snapshot.json`.

The following recovery checks also pass:

- Import the original persisted native Codex session; repeating import returns the same local thread without duplication.
- Replay exactly the original user and assistant messages.
- Fork into independent local and native identities with the same complete history.
- Rename the restored and forked chats, restart the Codex provider, and recover the renamed original with exact messages.
- Restart the daemon and let the Release app reconnect. The selected chat, title, messages and native session identity survive. The fork's independent identity also survives.

`check-recovery.mjs`, `recovery-result.json`, `native-identities-before-restart.json` and `daemon-restart-result.json` retain the corresponding protocol and identity evidence. The app's accessibility tree was inspected after reconnect; it showed the selected restored chat and both original messages, with no working indicator.

An earlier harness incorrectly used `thread.session.stop` as a reconnect operation. That command intentionally deletes the resume route so a later turn starts fresh. Its subsequent fork failed because the new empty session had no persisted rollout. `reset-diagnostic-result.json` records the correction. `check-replay.mjs` and `resumed-thread.json` are historical diagnostics, not replay proof. No application lifecycle fix was made for this harness mistake.

The app remained in its ordinary shell despite `-ChatPerformanceLab -ChatBenchmarkSyntheticTurns 300 -ChatAutoBenchmark scroll` in its process arguments. It neither opened synthetic chat nor emitted benchmark output. The original archived executable remained unmodified; app stdout/stderr contain no fatal-error output.

These checks do not establish 120 Hz presentation, absence of individual tile seams, approvals, queue/steering behavior or attachment rendering. They also exposed the separate reasoning selection defect fixed and retested in `../reasoning-20260921`. The daemon log retains unrelated RevenueCat MCP authorization warnings and earlier idle catalog refresh timeouts; these are not described as a clean warning-free log.
