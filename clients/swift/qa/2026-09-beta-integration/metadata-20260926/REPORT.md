# Metadata upgrade and rollback — September 26

The current source is `034ab57`. The comparison source is `88d7d7e`, the parent of the cleanup commit and the pre-integration database implementation. Both actual versions of `internal/store` and `internal/provider` were exported from Git into disposable directories and compiled with the same small harness. This pass changes no production code and opens no valuable database or provider history.

## Results

- The old version creates a database with a Unicode thread, model/options, provider instance, native-session route, opaque resume cursor, import identity and terminal metadata.
- The current version adds `threads.additional_directories` while preserving every pre-existing value and import identity. Reopening is idempotent.
- New additional directories survive a current-version close/reopen in both thread metadata and the saved launch route.
- The old binary reads the upgraded database and renames the thread successfully. Its upsert preserves the unfamiliar SQL column, terminal metadata, model/options, import identity and other route values.
- **Downgrade is not lossless for the new route field:** the old binary decodes and rewrites `start_input` without `additionalDirectories`, removing that JSON field. The separate thread metadata column survives. Do not promise that the old application can use or preserve this newer launch capability.
- A consistent pre-downgrade SQLite backup restores the entire enriched metadata state exactly, including the extra launch directories. Original and backup hashes remain unchanged. SQLite integrity and foreign-key checks pass.
- The actual corrected daemon starts from a separate copy of the recovered database. Its WebSocket API returns the correct thread title, provider/model and additional directories, plus the terminal in the stopped state. No provider process or terminal is launched. The owned daemon then exits cleanly.

`results.json` contains eight completed store operations, source revisions, harness hashes, database paths/hashes and assertions. `daemon-result.json` records the actual daemon hash, restored API values and cleanup. All values and paths in these fixtures are synthetic. Conversation text is provider-owned and intentionally absent; actual Codex history compatibility is covered separately in the history reports, including their older-runtime warnings.

## Backup correction retained

The first QA attempt copied only the main SQLite file. Its read-only inspection connection was not explicitly closed (a Python connection context ends the transaction, not the connection), leaving newer writes in the WAL. The copied file consequently missed those writes and the recovery assertion failed. `attempts/initial-backup/` retains that failure and its snapshots.

The final harness closes inspection connections explicitly and uses SQLite's backup API for every copy. The complete eight-step scenario and the daemon recovery then pass. This validates the documented recovery procedure; maiD does not gain an automatic backup or downgrade mechanism from this QA pass. Do not copy only `maid.db` while connections or WAL writes may remain.

## Reproduction and limits

Run `python3 clients/swift/qa/2026-09-beta-integration/metadata-20260926/check-versions.py`, then `node clients/swift/qa/2026-09-beta-integration/metadata-20260926/check-daemon.mjs`. The first creates a fresh cache directory each time; the second refuses to reuse its daemon data directory. Keep outputs from different runs separate when retaining evidence.

These checks cover the metadata format transition introduced by the integrated beta branches and exact recovery after an older metadata writer. They do not certify arbitrary future/ancient versions, native-provider history downgrades, or unavailable physical-device behavior. Remaining release QA and final archives are still required.
