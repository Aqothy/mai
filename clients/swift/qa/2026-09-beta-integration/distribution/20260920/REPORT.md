# Release artifact validation, September 20

Application source: `b9a259a`. Evidence/script-only follow-up: `7bee70c`. The app source and project were unchanged between the archives. Both archives were created with the explicitly approved Xcode Product → Archive action, with no reported build warnings. Nothing was uploaded or distributed.

| Artifact | Architecture | Minimum OS | SHA-256 |
| --- | --- | --- | --- |
| macOS | arm64, x86_64 | 15.6 | `1707330a289533089450282d689646f432b213e14bd7b89fe63906402b676131` |
| iOS | arm64 | 18.6 | `86c81130127e5ff2fa084bc1a03d7cd5bf83f7d6876a5f5e01231c5edd9efbb7` |

Both app signatures pass deep/strict verification. Both include the required-reason API manifest and camera permission description. The binary load commands agree with the declared minimum OS versions. The macOS app is sandboxed with network-client and user-selected read-only file permissions; it does not have `get-task-allow`. The iOS archive is development-signed and has `get-task-allow=true`, which must be removed by the eventual distribution signing/export. These are local archives, not App Store-validated distribution packages. Exact paths, metadata, manifests and check output are in the platform JSON records.

## Actual Release benchmark-gate retest

The unmodified macOS archived executable was launched with `-ChatPerformanceLab -ChatBenchmarkSyntheticTurns 300 -ChatAutoBenchmark scroll`. Its supervised process retained those arguments, survived the 55-second observation, and showed the ordinary empty app shell and reconnect state. The accessibility tree contained Search, New Chat, New Terminal, the ordinary composer and no Mock Chat or performance-lab controls. The captured log contained no benchmark results, benchmark start/completion, synthetic-thread or fatal-error markers. The owned process was terminated after observation. This passes the runtime retest of the September 14 failure.

The first unsupervised launch is retained as inconclusive: its child had exited before verification, and selecting the app opened a different process without the arguments. It is not counted as passing evidence. The second supervised launch verifies both process arguments and the observed interface.

No daemon was listening during this isolated launch; connection recovery is expected. This is a startup/debug-gate check, not a real-provider or complete Release workflow test. No physical iOS device was available to run the iOS archive. The static native SDK file-API audit in the parent `PRIVACY.md` and distribution signing/validation remain open.
