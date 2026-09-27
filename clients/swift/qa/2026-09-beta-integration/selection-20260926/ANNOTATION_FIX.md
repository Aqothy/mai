# Annotation persistence repair and QA — September 26–27, 2026

New Codex prompts now preserve their original visible text, annotation cards and message references through native fork and daemon restart. This repairs the real failure in [ANNOTATION_REPLAY.md](ANNOTATION_REPLAY.md). It does not reconstruct metadata that older versions never saved.

## Change

The daemon stores client-owned presentation metadata separately from provider-owned history. Ordinary prompts retain only message identity and a hash; annotated prompts also retain their original visible text and cards. Each dispatch gets a random client ID, including each steering message within the same turn. Codex already decodes the native `clientId`; the adapter now forwards it to the service instead of discarding it.

Replay restores metadata only when provider instance, native session, client ID and exact provider-facing prompt hash agree. Identical-looking prompts can therefore keep different original references. Unknown/edited/legacy items retain their native text without guessed annotation metadata. Native history still determines which messages exist. Unsent records cannot create phantom messages, and a repeated native retry item cannot concatenate into another local message.

Metadata is saved before dispatch. A failed save rejects the send before contacting the provider; a failed read does not consume the adapter's replay response. Fork metadata is copied atomically without altering the source; failure rolls back the newly created native fork where supported. Provider switching is checked again before saving. Native session deletion also removes its metadata.

The SQLite change adds one table. No generated client files, Xcode project, Swift app source, deployment targets, animation or rendering behavior changed. Providers without exact client-message replay identities retain their existing text history behavior; this repair's durable-card guarantee is verified for Codex below.

## Verified results

- Full backend tests pass on the final source. Race checks pass for store, provider service, Codex adapter, orchestration and daemon; the final provider-switch guard also passes its targeted race regression. Static checks pass.
- Store regressions cover reopen/restart, exact Unicode metadata, immutable dispatch identities, provider/session isolation, atomic fork collisions and deleting a fork without touching its source.
- Service regressions cover repeated text with distinct references, two steering messages sharing a turn, ordinary user-message identities, restart/fork, unknown IDs, edited prompt text, retained retry items, and save/read/fork failures. Adapter wire checks require distinct start/steer IDs; ingestion restores an annotation-only prompt with an empty visible string.
- Real Codex `0.158.0-alpha.2`, model `gpt-5.6-luna`, low reasoning: annotation-only, two identical-looking prompts with different references, and two annotated steering messages during one running command all pass. Exact message IDs/text/cards agree after native fork and after daemon restart for both source and fork. Every quoted message ID resolves inside its owning chat. The complete scenario passes twice, including the final daemon build.
- Custom Codex `0.147.0` independently replays the same source and fork with exact cards, visible prompts and message IDs. Its existing model-cache compatibility error is retained in the log; this passing history check does not certify all old-runtime functionality.
- The actual Mac and iOS 18.6 client decoder, session and row construction paths consume five captured live/restart/fork/runtime snapshots. All five annotation cards per snapshot, empty annotation-only prompt, exact quote/note/reference values, standard annotation renderer selection and cleared activity pass. This checks data reaching the renderer, not pointer gestures or a pixel comparison.
- Generating the API schema, methods and vocabulary into a temporary directory produces byte-identical files to the committed generated versions. No client regeneration is needed.
- The inspected live database contains 14 presentation records across source/fork, with original text only on the 10 annotated records. SQLite integrity and foreign-key checks pass.

## Evidence and reproduction

`annotation-fix/manifest.json` records original evidence paths, hashes, final source-file hashes and the complete staged backend patch. Logs and snapshots are losslessly compressed. Databases, authentication files and personal conversation history are excluded. `live-final/metadata.json.gz` identifies the final daemon and current runtime; `older-runtime/metadata.json.gz` identifies the custom runtime. All owned daemon launches report successful cleanup. Disposable native QA chats/forks remain in provider history.

Run `check-annotation-fix.mjs` with a new output path and `QA_DAEMON` pointing to the built daemon. `QA_CODEX` selects a custom runtime. To check existing history without another model turn, set `QA_RESUME_FIXTURE` to a previous full run; the harness backs up its database into the new output before opening it. Child-only configuration uses read-only tools and no approval prompts; the sole live tool command sleeps for six seconds in the disposable directory without reading/writing files. Saved user configuration is unchanged.

For client validation, substitute the base64 encoding of `annotation-fix/client-annotation-fixture.deflate` into `client-annotation-replay.swift`, then run it through Xcode MCP in `ThreadSession.swift` on each destination. The compressed input avoids truncation of the larger inline JSON. `annotation-client-results.json` contains both successful outputs.

The initial regression helper needed two compile corrections and a completed-turn status in its fixture; corrected tests pass. The retained pre-fix live failure remains the product regression evidence. The final source adds a route-ownership guard after the first successful live run; `prompt-final.log.gz`, `full-final.log.gz` and the complete `live-final/` rerun validate that final change.

Remaining release requirements in `RELEASE_QA.md` still apply, including broader presented-frame checks, remaining iOS/device/accessibility checks and refreshed distribution artifacts.
