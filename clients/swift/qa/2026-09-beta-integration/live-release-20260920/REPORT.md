# Live Release workflow, started September 20

The disposable daemon runs only on 127.0.0.1:8765, with its database and working directory isolated under the QA cache. The Codex app-server adapter started the installed bundled CLI 0.155.0-alpha.9.2 and reported authenticated status and model/config capabilities. The first app launch selected the saved Claude draft preference and initialized Claude metadata automatically; no Claude prompt was submitted. This was discovered in the following provider-status audit. The owned daemon was stopped, the QA launch preference was changed to Codex with a saved backup, and the replacement run verifies that Claude stays configured and unopened. No live Claude turn test ran.

An empty named thread was created by RPC and appeared in the unmodified Release app. Opening it worked. The first multiline Unicode paste crashed the composer before any prompt submission. The captured Release stderr is retained here; the Debug stack, fix and regression evidence are in the neighboring `composer-20260921` directory. `first-turn.ndjson` contains only the initial empty snapshot, so this attempt is not a passing live turn.

The initial archive hash and source are recorded in `metadata.json`. New-source validation will be recorded separately when resumed. A successful adapter startup does not establish completion, replay or UI streaming correctness.
