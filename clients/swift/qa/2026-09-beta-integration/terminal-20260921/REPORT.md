# Terminal runtime QA

The actual daemon built from `5ea7385` passed the scripted WebSocket/PTY checks in `check-terminal.mjs`. Its executable hash is in `../reasoning-20260921/daemon-result.json`. All terminals were disposable fixtures and were deleted afterward.

The run verified create/attach, live input, a byte-for-byte ordered 5 MiB text burst, strictly increasing output sequence numbers, at most 64 KiB per notification, and successful input after the burst. Reconnecting retained the same running shell and installed a snapshot containing the previous visible output; subsequent output had sequence numbers above the snapshot. The actual PTY reported the requested 96 × 31 grid. Detached-client input was rejected. Relaunch replaced the run identity and rejected input from the previous run. Natural exit preserved code 7; relaunch after exit, terminate and delete all worked. See `result.json` for bytes, SHA-256, timing, run identities and snapshot size.

The first harness incorrectly waited for an `exit` item. The protocol actually emits a `status` item with status `exited`. The process had already ended successfully; the daemon log confirms that. `failure.json` preserves this harness failure. The corrected script then completed the entire sequence. No terminal product code changed.

The unmodified Release app (`267d18b`) created a terminal from its New Terminal button, sent a pasted Unicode command and Return, switched to the restored chat with its exact messages, then switched back to the terminal with its output intact. The actual output includes café and the joined 👩🏽‍💻 emoji. The shell editor displays the zero-width joiner explicitly in the entered command, while the command's output renders the combined emoji normally.

CUA reported a clipboard-read timeout although the paste reached the shell. Its later screenshots returned blank images. An independent native window capture (`release-terminal.png`) confirms the app was rendering normally; those CUA images are not an application rendering failure. The native terminal does not expose its contents in the captured accessibility tree, so this check does not establish VoiceOver support. `ui-result.json` records these limits.

The full backend suite also passes the existing split/oversized/cancelled OSC tests, detector tests, semantic agent upsert tests and run fencing tests. Actual provider activity inside the terminal, clipboard selection/copy, accessibility and iOS terminal rendering remain separate requirements.
