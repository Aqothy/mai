# Confirmed failure: annotation metadata does not survive reload/fork

The actual daemon at `034ab57` (production source unchanged through `eada62a`) and bundled Codex `0.158.0-alpha.2` reproduce this on the disposable annotated steering chat from the September 22 workflow QA. A consistent SQLite backup is used in a fresh data directory. Only that known chat is resumed and forked; no new model turn or account-wide history listing is performed.

## Result

| Value | Original live snapshot | Reload and native fork |
| --- | --- | --- |
| Selected quote | `QUEUED_TWO` | Preserved inside plain prompt text |
| Note | `Preserve this reference while steering` | Preserved inside plain prompt text |
| Annotation card metadata | One annotation | Empty |
| Original referenced message ID | `assistant:msg_0b4bd19473f8c83a016ab2e727ef2487d199123a5be1310866` | Absent |
| Visible user prompt | Original request | Expanded provider-facing context plus original request |

`annotation-replay/annotation-replay-b/result.json.gz` contains the exact comparison, and the full replay snapshots are retained beside it. The owned daemon exited normally with code 0. The native fork is a disposable QA conversation and has not been deleted. This is a failed release requirement, not a pass because the quote text survived.

## Cause and repair requirements

`promptTextWithAnnotations` sends readable quote/note context to the provider, while the live projection keeps structured annotations separately. The local database currently persists sidebar/routes, not annotation metadata. Native replay therefore has only the provider's expanded text; the conversion and ingestion layers cannot restore cards or their original references.

A repair should persist client-owned annotation metadata separately from provider-owned conversation history, identify it by provider instance/session and an exact stable client message identity, and apply it only to the matching replay item. It must preserve the original visible prompt, quote, note and referenced message ID through restart and fork, support distinct steering messages within one turn, and keep identical-looking repeated prompts distinct. Storage failures must not silently accept an annotated send while dropping its metadata. Copying fork metadata must leave the source untouched and not attach records to unrelated native sessions. Old records that never stored this metadata cannot be reconstructed reliably; keep their readable text instead of guessing references.

The locally generated schema from the installed Codex executable exposes `clientUserMessageId` on turn start/steer and nullable `clientId` on replayed user-message items. The current adapter sends the **turn ID** for `clientUserMessageId` and does not decode `clientId`; reusing a turn ID for steering cannot identify individual prompts. This provides a concrete protocol path for a repair, but it still needs implementation and end-to-end validation. Providers/runtimes without this identity need an explicit compatibility policy, not text matching.

## Harness notes

`check-annotation-replay.mjs` is the executable probe. Its output argument must contain a fresh SQLite backup at `data/maid.db`; `QA_DAEMON` selects the tested daemon and `QA_CODEX` optionally selects the runtime. The original live comparison fixture is the retained September 22 steering snapshot.

The installed app changed its bundled executable path to `Contents/Resources/codex-cli/bin/codex`. The first attempt failed before starting a provider because the older path was absent; its failure and daemon cleanup are preserved. A second invocation correctly refused to overwrite the existing log. The successful attempt used a new output directory and the discovered executable path. These setup failures are separate from the confirmed annotation failure.
