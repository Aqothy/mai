# Reading guide and evidence index

Start with the [feature map](../../../../FEATURE_MAP.md) for behavior/source ownership, then [HANDOFF.md](HANDOFF.md) for current state. The lists below distinguish architecture material from dated test evidence. Read reports first; open large captures/raw traces only for the relevant failure.

## Knowledge and operational documents

| Document | What you learn |
| --- | --- |
| [CHAT_OPTIMIZATION_OVERVIEW](../../CHAT_OPTIMIZATION_OVERVIEW.md) | Entry point to the native transcript optimization work. |
| [CHAT_NATIVE_PERFORMANCE](../../CHAT_NATIVE_PERFORMANCE.md) | Native rendering/layout architecture and optimization rationale. |
| [CHAT_PERFORMANCE_BALANCE](../../CHAT_PERFORMANCE_BALANCE.md) | Measured tradeoffs, accepted/rejected experiments and limitations. |
| [CHAT_CONTAINER_EXPERIMENTS](../../CHAT_CONTAINER_EXPERIMENTS.md) | Earlier container comparisons; historical context, not current pass criteria. |
| [CHAT_PERFORMANCE_REPORT](../../CHAT_PERFORMANCE_REPORT.md) | Earlier performance results; verify revision/configuration before comparison. |
| [CHAT_PERFORMANCE_FOLLOWUP](../../CHAT_PERFORMANCE_FOLLOWUP.md) | Earlier follow-up questions; reconcile against newer evidence rather than blindly redoing them. |
| [CHAT_BENCHMARK_GUIDE](../../CHAT_BENCHMARK_GUIDE.md) | Existing launch arguments, workload plans and scripts. Historical `/tmp` app paths are snapshots. |
| [CHAT_QA_CHECKLIST](../../CHAT_QA_CHECKLIST.md) | Detailed renderer/streaming/iOS QA state; unchecked means unverified. |
| [RELEASE_QA](../../RELEASE_QA.md) | Whole integration/provider/terminal/distribution QA and execution chronology. |
| [RUNTIME_EVIDENCE](../../qa/2026-09-beta-integration/RUNTIME_EVIDENCE.md) | Correction for iOS snippet hosts that did not match the selected Xcode runtime. |
| [root beta review](../../../../beta-review-verification.md) | Older beta verification context; reconcile with the integrated release evidence. |

Several architecture documents entered this branch with the existing performance snapshot `1ea0d32`; they were not all authored from scratch in this goal. The release checklists, dated QA reports/fixes and benchmark-guide updates accumulated during this integration task. The handoff, personal checklist, runbook and initial feature map were written at wrap-up.

## Most useful dated evidence, newest findings first

All paths below are under `clients/swift/qa/2026-09-beta-integration/`. Reports identify exact scope, binaries/runtimes, failures and exclusions. “Pass” in an older report does not cover later source changes automatically.

| Report | Why read it |
| --- | --- |
| [Offscreen disclosure](../../qa/2026-09-beta-integration/offscreen-disclosure-20260930/REPORT.md) | Last bounded check; native geometry/paging/resize result, incomplete List comparison. |
| [Anchor correction](../../qa/2026-09-beta-integration/anchor-correction-20260930/REPORT.md) | Root cause/fix for double List position correction, before-failure, 47 regressions and real controls. |
| [Disclosure](../../qa/2026-09-beta-integration/disclosure-20260930/REPORT.md) | Native eight-action pass and historical List diagnosis, superseded in part by the anchor fix. |
| [Scroll intent](../../qa/2026-09-beta-integration/scroll-intent-20260929/REPORT.md) | Competing nested geometry observer caused jump-button flicker; native/List stream-away/resume evidence. |
| [Switch/resize](../../qa/2026-09-beta-integration/switch-resize-20260929/REPORT.md) | Exact hidden streaming, unchanged other chat and four widths/chat round trips. |
| [Timestamp/runtime replay](../../qa/2026-09-beta-integration/runtime-replay-20260927/REPORT.md) | Known iOS 18.6 generated-decoder blocker and prepared repair. Read before declaring tests green. |
| [Keyboard](../../qa/2026-09-beta-integration/keyboard-20260927/REPORT.md) | Enter/Shift+Enter, native editing/Undo, failed sends and actual older-runtime metadata. |
| [Completion](../../qa/2026-09-beta-integration/composer-20260927/REPORT.md) | Stale results, menu dismissal/acceptance, scope and Unicode. |
| [Long annotation editor](../../qa/2026-09-beta-integration/annotation-20260927/REPORT.md) | Real keyboard versus safe-area confusion; older-runtime software-keyboard check remains incomplete. |
| [Activity recordings](../../qa/2026-09-beta-integration/activity-20260927/REPORT.md) | Thinking/tool/reply frame review and limits of ~79 Hz captures. |
| [Selection and reuse](../../qa/2026-09-beta-integration/selection-20260926/REPORT.md) | Actual clipboard/menu actions, row reuse, links, themes and annotation ownership. |
| [Annotation repair](../../qa/2026-09-beta-integration/selection-20260926/ANNOTATION_FIX.md) | Original metadata-loss bug, exact repair and provider replay/fork evidence. |
| [Metadata compatibility](../../qa/2026-09-beta-integration/metadata-20260926/REPORT.md) | Upgrade/downgrade/backup tests and older-writer field loss. |
| [Reasoning reload](../../qa/2026-09-beta-integration/reasoning-reload-20260924/REPORT.md) | Adjacent thoughts/IDs across live and history conversion. |
| [Registry](../../qa/2026-09-beta-integration/registry-20260923/REPORT.md) | Active-work preservation, deferred update and custom executable recovery. |
| [History compatibility](../../qa/2026-09-beta-integration/history-20260923/REPORT.md) | 737-session pagination, two Codex runtimes and failed-page behavior. |
| [Activity model](../../qa/2026-09-beta-integration/activity-20260923/REPORT.md) | Live leaf observation, authoritative completion and exact activity source. |
| [Attachments](../../qa/2026-09-beta-integration/attachments-20260922/REPORT.md) | Live Codex image messages, invalid fallback, boundaries and remaining media integrations. |
| [Workflows](../../qa/2026-09-beta-integration/workflows-20260922/REPORT.md) | Approvals, queue/steering, crash recovery and retry through real daemon/store. |
| [Rendering/completion jump](../../qa/2026-09-beta-integration/rendering-20260922/REPORT.md) | 35-point List completion regression, image analysis and limitations. |
| [Controlled benchmarks](../../qa/2026-09-beta-integration/benchmarks/20260922-final/REPORT.md) | Validated window, normal/full opening, scrubbing, pagination/resize and five-session memory. |
| [Plain-streaming baseline](../../qa/2026-09-beta-integration/benchmarks/217e488-plain-streaming/REPORT.md) | Animation-free comparison across three launches and remaining stalls. |
| [Reasoning setting](../../qa/2026-09-beta-integration/reasoning-20260921/REPORT.md) | Why UI correctness was insufficient: low effort omitted from driver session requests. |
| [Live Release Codex](../../qa/2026-09-beta-integration/live-release-20260921/REPORT.md) | Prompt/replay/restart/copy/fork core workflow on the recorded artifact. |
| [Terminal](../../qa/2026-09-beta-integration/terminal-20260921/REPORT.md) | PTY output/order/resize/reconnect/lifecycle and Release interaction. |
| [Older OS teardown](../../qa/2026-09-beta-integration/ios18-20260920/REPORT.md) | Synchronous isolated-deinit crashes and older-runtime regressions. |
| [iOS interaction](../../qa/2026-09-beta-integration/ios-interactive/RESULTS.md) | Rotation/keyboard/annotation captures, repairs and remaining mobile cases. |
| [Plain iOS follow-up](../../qa/2026-09-beta-integration/ios-interactive/20260920-plain/RESULTS.md) | Later simulator interaction scope; not physical-device FPS evidence. |
| [Release archives](../../qa/2026-09-beta-integration/distribution/20260921/REPORT.md) | Historical archive/signing checks; artifacts are stale for current source. |
| [Privacy audit](../../qa/2026-09-beta-integration/distribution/PRIVACY.md) | Declared uses and unresolved native file-API call-site/reason audit. |

Additional earlier attempt reports (`rendering-20260919`, `live-release-20260920`, `distribution/20260920`, `composer-20260921`) retain failed/setup/historical evidence. They are not recommended starting points unless investigating that history.

## How to extend the map without losing context

1. Start from a feature's expected behavior and user decision, not a directory dump.
2. Identify UI owner → command/event boundary → provider/persistence responsibility → verification.
3. Link the smallest relevant source/test/report; state platform and capability differences.
4. Record known limits and unresolved product issues separately from harness failures.
5. Update alongside code, with a lightweight automated drift/link check. The next agent is responsible for implementing this maintenance workflow; this handoff did not create a recurring automation.
