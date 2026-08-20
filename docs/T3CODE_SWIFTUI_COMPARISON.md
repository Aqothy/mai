# t3code PR #5178 SwiftUI Client vs maiD Swift Client

## Scope and methodology

This report compares:

- **t3code:** [`pingdotgg/t3code` PR #5178](https://github.com/pingdotgg/t3code/pull/5178), exact PR head `7b8bb94d5ae71042c6336b7e74b7504081ff4c3e` (`t3code/rebuild-mobile-app-swift`). The local review checkout is `/tmp/t3code-pr5178`; the app is under `apps/swift-ios`.
- **maiD:** local `main` at `55e3893d20684c0b3262eb09c7303afb4e8957cf` **plus the current working tree**. The working tree was already substantially dirty with unrelated modified/untracked work while this review was performed, so this report describes the source actually being tested, not only committed `main`.

The review is source- and history-based. I inspected the UI implementation, state/transport code, server contracts needed by each client, tests, PR commit history, and automated review comments. For the follow-up comparison I also inspected local `stash@{0}` (`uikit chat tail-first experiment`), `stash@{1}` (`uikit chat`), and `stash@{2}` (`cache render layout`) without applying or modifying them. I did **not** run a matched Instruments benchmark on identical hardware, build mode, transcript, and server. Therefore:

- Architectural statements are high confidence.
- Relative performance conclusions are reasoned predictions, reinforced where possible by existing measurements and the observed behavior described in the request.
- Absolute speed claims should not be treated as benchmark results.

The PR is explicitly experimental/high-risk and says it was built by GPT-5.6-sol. At the reviewed head it contains 137 commits and roughly 50,000 added lines across the whole PR. `apps/swift-ios` contains about 37,000 non-test Swift lines (about 48,000 including tests), versus roughly 22,800 app Swift lines in `clients/swift/mai` (or about 29,900 including tests and current generated/untracked Swift files).

---

## Executive conclusion

The short version is:

1. **t3code feels faster on a cold, large thread because it bounds work and, separately, guarantees an opening state before mounting the transcript.** It initially requests only **10 user-anchored turns** and renders them in a directly controlled, recycled `UICollectionView`. However, the 10-turn limit does **not** explain a comparison where both tested threads contain only about seven equivalent messages. In that small case, the more likely advantage is t3code's navigation contract: it mounts the destination loader, force-awaits detail, and only then exposes chat content, while maiD can let a fast local snapshot replace its loader and start main-actor timeline/Markdown planning during the push transition. Also compare rendered rows and bytes, not only message count: seven maiD messages can expand into many semantic/tool rows.
2. **maiD has a more sophisticated warm-thread strategy but a more expensive cold-thread strategy.** It retains full thread sessions, up to five inactive subscriptions, semantic Markdown segmentation, and up to three threads of prepared TextKit layouts. Warm reopen can be excellent. On a cold large thread, however, maiD still accepts a complete history snapshot and synchronously performs some timeline projection and Markdown segmentation on the main actor before detached text layout warming can help. If maiD adopts a deterministic loader plus bounded/off-main initial presentation, this warm-thread machinery is no longer needed for *navigation responsiveness*; keep only the caches that measurements justify for warm scrolling/reopen, under a shared byte budget.
3. **The current maiD source already contains the right route-before-selection ordering, but not a hard first-frame guarantee.** Compact navigation appends `IOSChatDestinationView` and initially shows `Opening Chat…`; selection starts from the destination task rather than the row-tap closure. However, maiD also starts the local subscription before appending the route, and a fast cached/local snapshot can make `selectThread` expose the complete timeline during the push transition. SwiftUI `.task` mounting is not itself a Core Animation frame barrier. t3code is more deterministic because it deliberately ignores visible cached detail, awaits a forced fresh 10-turn request, and only then removes the loader.
4. **t3code has the better transcript container for deterministic large-history behavior:** explicit `UICollectionView`, diffable snapshots, granular item reconfiguration, explicit prefetch, direct content-offset control, and tested bottom-anchor geometry. maiD's SwiftUI `List` is simpler and still virtualized by UIKit internally, but its realization/diff/prefetch behavior is less controllable.
5. **maiD has the better Markdown feature set and generally better selection experience.** It uses `MarkdownView`/`swift-markdown`, Highlightr-backed syntax highlighting, math, richer CommonMark/GFM behavior, sanitation of active HTML/images, and always-enabled selection. t3code uses a custom dependency-free block parser plus Foundation inline Markdown, has no code syntax highlighting or math, and requires a context-menu toggle to enable selection.
6. **t3code's Markdown cache is better bounded and more operationally disciplined, but maiD does have Markdown-related caches.** maiD's `MarkdownReader` remembers one parse for the lifetime of that mounted reader; `ChatMarkdownSegmentCache` retains semantic split results per message/session; and `ChatTextLayoutStore` retains attributed text plus finished glyph geometry. What maiD lacks is one bounded, process-level cache of complete short/rich Markdown parse/render plans that survives row recycling and navigation. t3code provides that with byte-cost/count limits, request coalescing/cancellation, streaming-final promotion, unchanged-inline identity reuse, prefetch, and memory-warning clearing. maiD's deeper TextKit cache can make warm scrolling faster, but can retain much more memory and has no observed cost limit or memory-warning purge.
7. **maiD's terminal architecture is substantially stronger.** Raw bytes bypass observation and SwiftUI, are batched server-side, restore from an exact native Ghostty model snapshot, and cross an explicit run-ID/sequence barrier. t3code observes and republishes a growing cumulative `String` on every output event, then prefix-compares it before feeding only the suffix to Ghostty. Its 512 KiB cap prevents unbounded growth, but the hot path remains much less efficient and its replay model is less correct than a native snapshot.
8. **t3code's terminal surface has more bespoke mobile interaction polish.** It directly integrates Ghostty C APIs, a hidden text field, hardware key commands, accessory modifiers, pan-to-scrollback, pinch font adjustment, themes, multiple sessions, and lifecycle chrome. However, it explicitly disables Ghostty selection clipboard support and only offers “Copy output” for the entire ANSI-stripped buffer.
9. **t3code has much broader workspace functionality.** It includes a project file browser, text/Markdown/image previews, a review browser with inline word-change highlighting and review comments, and source-control actions. maiD currently has a capable tool-result diff viewer, but no equivalent general file browser or source-control surface.
10. **Code-quality leadership is split.** maiD is smaller, uses Swift 6 approachable concurrency/default main-actor isolation, has clearer server/client ownership in several hot paths, and has targeted performance tests. t3code demonstrates excellent performance iteration and defensive race handling, but centralizes too much in 5,409-line `NativeFeatureClient`, 1,698-line `ThreadDetailView`, and 1,239-line `FeatureRootModel`. The PR accumulated 191 automated inline review comments (151 Macroscope, 40 Cursor); many were later fixed or marked obsolete, so that number is review volume, not a count of current defects. No human approval was visible in the fetched PR reviews.
11. **maiD has the better in-transcript agent-activity model.** It preserves typed thoughts, tool kinds, statuses, duration, compact semantic groups, lazily hydrated detail, and file-change navigation. t3code intentionally compresses thousands of lifecycle activities into one disclosure per turn containing at most 40 short lines. That is cheap and bounded, but much less informative.
12. **t3code has the broader composer and persistence story.** It has inline command/model/skill/file completion, structured user-input forms, image-draft persistence, stable optimistic identities, and a durable cross-launch outbox. maiD has better visible queued-prompt controls (including steer/remove) and generic provider configuration, but its queue and pending attachments are memory-only.
13. **t3code shows more explicit accessibility engineering and a smaller UI dependency surface.** Its source has labels/actions/identifiers throughout transcript, tables, attachments, terminal, review, and home collection cells. maiD correctly handles several core surfaces and Dynamic Type-sensitive TextKit cache keys, but has fewer explicit annotations. The raw occurrence counts are not directly comparable because t3code has many more features.

### Overall decision table

| Area                                       | Advantage             | Main reason                                                                                      |
| ------------------------------------------ | --------------------- | ------------------------------------------------------------------------------------------------ |
| Cold large-thread opening                  | **t3code**            | Navigate-first loader + initial 10-turn pagination                                               |
| Warm recently viewed thread                | **maiD, potentially** | Retained live session + prepared TextKit layout registry                                         |
| Predictable transcript recycling           | **t3code**            | Explicit collection view/diffable/prefetch control                                               |
| Bottom anchoring and keyboard transitions  | **t3code, slight**    | Direct offset geometry and custom collection subclass; maiD is still thoughtfully implemented    |
| Markdown correctness/features              | **maiD**              | swift-markdown/MarkdownView, syntax highlighting, math, sanitation                               |
| Markdown cache bounding                    | **t3code**            | NSCache cost limits and memory-warning cleanup                                                   |
| Text selection                             | **maiD**              | Always enabled; native selectable long-prose path                                                |
| Tool/reasoning activity UX                 | **maiD, strongly**    | Typed folding/grouping, lazy full details, direct diff opening                                   |
| Composer completion breadth                | **t3code**            | Inline commands, models, skills, and server-backed file mentions                                 |
| Queued-prompt controls                     | **maiD**              | Visible queue with steer and remove; t3code emphasizes durable delivery                          |
| Draft/offline-send resilience              | **t3code**            | Attachments/model draft persistence plus stable-ID disk outbox                                   |
| Accessibility coverage                     | **t3code**            | More systematic labels, actions, identifiers, and collection-cell semantics                      |
| Streaming Markdown cadence                 | Mixed                 | t3code 150 ms latest-wins custom renderer; maiD 50 ms package renderer with leaf isolation       |
| Home list at very large scale              | **t3code**            | Explicit recycled collection + granular reconfigure                                              |
| Terminal data path/correctness             | **maiD, strongly**    | Native model snapshot + sequence barrier + raw-byte non-observed pipeline                        |
| Terminal mobile controls                   | **t3code**            | Custom iOS Ghostty interaction layer                                                             |
| Diff presentation                          | Mixed                 | t3code inline word spans/horizontal code; maiD parser robustness/off-main model/stable IDs/tests |
| File browsing/source control               | **t3code, strongly**  | Features do not currently have maiD equivalents                                                  |
| Network/multi-environment/offline delivery | **t3code** in breadth | Multi-env, HTTP fallback, durable outbox, managed cloud auth                                     |
| Simplicity/maintainability                 | **maiD**              | Smaller feature scope and less monolithic central client                                         |
| Cross-platform SwiftUI                     | **maiD**              | Shared iOS/macOS client; t3code Swift client is iOS-only                                         |

### Performance matrix for features both clients implement

This separates product breadth from hot-path performance. It is a source-based assessment, not a matched benchmark.

| Shared operation | Likely performance advantage | Qualification |
| --- | --- | --- |
| Tap a cold thread and show navigation immediately | **t3code** | Its loader/fetch gate is deterministic. With the same seven simple messages, this—not the 10-turn cap—is the likely reason it *navigates* faster. |
| Mount a genuinely large cold history | **t3code, strong** | Only 10 user turns initially, bounded IDs/models, explicit recycling. maiD currently plans complete history. |
| Reopen and rapidly scroll already prepared giant prose | **maiD** | Cached TextKit includes line breaking/glyph geometry; t3code caches a render plan, then SwiftUI still lays it out. This matches the observation that maiD can scroll more smoothly. |
| Scroll a cold/unprepared very large transcript | **t3code for predictability; FPS unproven** | Collection prefetch/offset control and pagination reduce worst-case work. `UIHostingConfiguration` plus self-sizing does not inherently draw faster than `List`. |
| Stream one growing assistant message | **Mixed** | t3code publishes detail at ~80 ms and Markdown at 150 ms; maiD isolates the live leaf and incrementally parses at ~50 ms. t3code does less often; maiD feels more immediate. |
| Maintain bottom through content/keyboard size changes | **t3code, slight** | Direct offsets are more deterministic; both implement follow intent and avoid fighting active user scrolling. |
| Prepend earlier history | **t3code** | It implements visible-item/offset restoration; maiD has no history pagination today. |
| Very large home/thread list | **t3code** | Explicit collection recycling, changed-row reconfiguration, visible-only timers, and staged settled rows. |
| Parse and plan a large unified diff | **maiD** | Detached parser/model construction and 20k-row performance tests. t3code's hydration has its own binary-search optimization. |
| Scroll long no-wrap diff/source lines | **t3code for readability, not necessarily vertical FPS** | One bidirectional lazy scroll surface; maiD's `List` recycles more explicitly but wraps lines. |
| Terminal output/reconnect | **maiD, strong** | Raw-byte path and native Ghostty state snapshot avoid cumulative observed strings and replay ambiguity. |
| Image attachments/thumbnails | **t3code, slight** | Transcript thumbnail cache and systematic downsampling; maiD serializes processing well but does less historical image presentation. |

---

## 1. Product and architecture boundaries

### t3code

The SwiftUI client is a parallel iOS 17+ app, not a replacement for t3code's shipped React Native app. It talks directly to T3 Effect RPC/WebSocket and HTTP contracts rather than going through the JavaScript client runtime.

It includes:

- multiple local and managed environments;
- pairing links, QR/manual pairing, Keychain credentials;
- T3 Connect with Clerk, DPoP, relay token exchange, and WebSocket tickets;
- a thread/workspace UI;
- project browsing and creation;
- transcript, approvals, structured input, attachments, and composer features;
- file browser, review/diff, source-control operations, and terminal;
- widgets, Live Activities, share extension, shortcuts, deep links, push, and background refresh.

The broad scope matters: some of its complexity and line count are unrelated to chat rendering.

Key central types:

- `Features/Root/FeatureRootModel.swift`: `@MainActor @Observable`, app-facing state, optimistic sends, durable outbox, per-thread detail dictionaries and render revisions.
- `App/NativeFeatureClient.swift`: transport-to-feature mapper, multi-environment coordination, polling/streaming, render mutation reduction, terminal accumulation, workspace tools.
- `Core/T3Client.swift` and `Core/WebSocketRPC.swift`: HTTP/Effect-RPC client and actor-based socket lifecycle.

### maiD

maiD is a shared iOS/macOS SwiftUI client for a local Go daemon. The server owns provider/ACP integration, authoritative thread snapshots/events, compact tool projections, item-detail hydration, terminal PTYs, and terminal model snapshots.

Key central types:

- `Features/Threads/ThreadStore.swift`: `@Observable`, thread list, selected-session projection, connection/reconnect, session cache, event routing, optimistic/queued prompt handling.
- `Features/Threads/ThreadSession.swift` and `ThreadEventReducer.swift`: in-place session/event reduction.
- `Network/RPCClient.swift`: JSON-RPC WebSocket transport with off-main encode/decode.
- `Features/Terminal/*` plus `internal/terminal/*`: separate terminal connection and native Ghostty snapshot protocol.

The comparison is not perfectly apples-to-apples. t3code is a remote/multi-environment cloud-capable client; maiD is a local-daemon client with server code under the same repository and a macOS surface.

### UIKit/SwiftUI component map

Neither app is “all UIKit” or “pure SwiftUI.” Both use SwiftUI for composition and selectively drop to UIKit/native surfaces where lifecycle or text/terminal behavior needs more control.

| Surface          | t3code Swift client                                                                          | maiD Swift client                                                                                                 |
| ---------------- | -------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Root/navigation  | SwiftUI `NavigationSplitView`, `NavigationStack`, sheets                                     | SwiftUI `NavigationStack` on compact iOS, custom slide-out menu, regular iOS/macOS containers                     |
| Home/thread list | `UICollectionView` compositional list + diffable data source + `UIHostingConfiguration` rows | SwiftUI `List`                                                                                                    |
| Chat transcript  | `UICollectionView` compositional layout + diffable data source + hosted SwiftUI rows         | SwiftUI `List` + `ScrollViewReader` and modern scroll geometry/phase APIs                                         |
| Markdown         | Custom SwiftUI block views; Foundation inline `AttributedString`                             | MarkdownView SwiftUI blocks, RichText non-scrolling text view, and custom non-scrolling `UITextView`/TextKit path |
| Composer         | SwiftUI `TextField`; UIKit/PhotosUI image pickers where needed                               | SwiftUI `TextField`, `PhotosPicker`/file importer, UIKit camera picker                                            |
| Diff             | SwiftUI bidirectional `ScrollView` + `LazyVStack`                                            | SwiftUI `List`                                                                                                    |
| Source files     | SwiftUI `ScrollView` + `LazyVStack`; UIKit image preview/downsampling helper                 | No equivalent workspace browser                                                                                   |
| Terminal         | Custom `UIView` calling Ghostty C/IOSurface APIs directly                                    | Ghostty package surface hosted by SwiftUI; separate custom transport/server model                                 |
| Selection        | SwiftUI `.textSelection` over independent Markdown blocks                                    | RichText/custom `UITextView` for longer continuous selections, SwiftUI selection elsewhere                        |

The main transcript distinction is therefore **who owns virtualization and offsets**, not UIKit versus SwiftUI row drawing: t3code gives those responsibilities to `UICollectionView`, while both clients still use SwiftUI for most visible chat cells.

### Does `UICollectionView` make t3code's lists faster than maiD's `List`?

Not automatically. SwiftUI `List` is itself platform-backed, virtualized, and recycled. t3code's `UICollectionView` cells still host SwiftUI and still pay self-sizing/text-layout cost on the main thread. The collection view buys **control**—diffable snapshots, exact changed-item reconfiguration, prefetch callbacks, direct offsets, and visible-anchor restoration—not a universal FPS improvement.

For the simple home list, that control is likely a clear scale advantage: t3code avoids broad parent timer updates and touches only changed/visible rows. For chat, the result is mixed because row cost dominates container cost. maiD's current warm `List` can plausibly scroll more smoothly than t3code because its long prose may arrive with finished TextKit glyph layout, while t3code's recycled hosted cells still self-size SwiftUI Markdown as they are demanded. t3code is more predictable on cold huge histories because it windows data and prefetches Markdown, not merely because the type is named `UICollectionView`.

A fair container comparison must feed the **same immutable row plans and same row views** to both containers, then measure hitch ratio, synchronous layout misses, cell creation/reconfiguration, and memory. Comparing current apps conflates container, pagination, Markdown renderer, row density, and caches.

---

## 2. Thread selection, navigation, and why t3code appears instant

### t3code's sequence

`WorkspaceView.openThread` performs only cheap synchronous UI state changes:

1. set `selectedThreadID`;
2. switch the compact split-view column to detail;
3. mount `ThreadDetailView` with `.id(id)`.

`ThreadDetailView` starts with `isLoading = true`, so the destination immediately shows `FeatureThreadOpeningView`. Its `.task(id: thread.id)` then:

1. calls `model.detail(for: thread.id, force: true)`;
2. restores the composer draft;
3. sets `isLoading = false`.

At the current head it intentionally shows the opening loader even when a cached detail exists. Commit `c4fb08e` changed this behavior to stabilize repeated thread opening rather than painting possibly stale/costly cached transcript content during the transition.

This is a good latency-perception design: the navigation acknowledgement is separated from data/model/layout readiness.

It is important not to over-credit pagination here. If the tested thread contains only seven equivalent messages/turns, t3code's 10-turn ceiling excludes nothing, so it cannot explain that particular navigation difference. If all seven rows also fit or are immediately realized, collection recycling is not the explanation either. In that case compare:

- tap-to-loader frame separately from loader-to-transcript frame;
- exact source bytes and expensive constructs, not only message count;
- resulting UI row count—maiD can project thoughts, tools, approvals, fold controls, and multiple semantic Markdown segments from seven wire messages;
- whether each app's Markdown/TextKit cache is warm;
- whether maiD's local subscription publishes while the push transition is beginning.

### maiD's current sequence

Current compact iOS source attempts the same principle:

- `IOSCompactAppContainer` calls `store.prepareThreadForSelection(threadID)` and then appends the route to `NavigationPath` in the same synchronous closure.
- `IOSChatDestinationView` initially describes itself as `ProgressView("Opening Chat…")`.
- A destination `.task(id: route)` performs `store.selectThread(threadID)` after the destination view mounts rather than directly in the list-row action.

The source comment says this is intended to prevent a cached full timeline from being built before the push transition's first frame. The synchronous ordering is definitely better than selecting before `path.append`, but `.task` is not a documented Core Animation commit barrier. There are two important races:

1. `prepareThreadForSelection` starts the subscription before the route is appended. It launches asynchronously, but a local daemon can return and publish a complete snapshot very quickly.
2. Once that session is cached/prepared, `selectThread` is synchronous. Its observation change can replace the loader with `ChatView`, whose body immediately performs full section/row/Markdown planning, while the navigation animation is still starting.

By contrast, t3code always sets `isLoading`, force-fetches a fresh detail, and awaits the network before exposing even a cached transcript. With the current server that fresh detail is also only 10 turns. This makes its loader behavior more deterministic, not merely cosmetically different.

Therefore, if the tested app still visibly freezes before the destination becomes apparent, likely possibilities are:

- the installed build predates `IOSChatDestinationView`'s route-before-selection change;
- the pre-subscription finishes during the navigation transaction and exposes full history too early;
- the destination task runs soon enough that cached full-timeline planning blocks the first visible transition frames;
- some parent/body dependency evaluates selected-thread state during the transition;
- Debug-only logging/layout behavior magnifies the hitch.

This should be confirmed with signposts/Instruments around route tap, `path.append`, destination first appearance, `selectThread`, snapshot completion, timeline projection, segmentation, and first rendered frame.

### What is actually asynchronous, and what can freeze maiD?

`t3code` does **not** parse and lay out the complete transcript on a background core before navigation. Its forced snapshot is asynchronous, and custom Markdown prefetch/stream renders use detached tasks. But `NativeFeatureClient`/`FeatureRootModel` mapping is main-actor state work, a settled visible Markdown cache miss calls `documentImmediately`, and SwiftUI/self-sizing text layout still occurs on the main thread. Its fast opening comes primarily from the loader gate, bounded detail, and demand-driven collection cells—not off-main TextKit geometry.

maiD's RPC JSON encode/decode is already off-main, and its current `ChatTextLayoutStore.warm` already does what `stash@{2}` (“cache render layout”) did: one `Task.detached(.userInitiated)` constructs complete TextKit stacks newest-first. It is concurrent *with the main actor* but intentionally sequential within that worker rather than laying out many rows in parallel. The current implementation is an evolved/better-bounded version of that stash (for example, the old experiment retained up to 64 idle text views; current source retains 16). A visible row that outruns warmup still builds synchronously to avoid flashing a placeholder.

The work that precedes or can outrun that warmup is the likely freeze source:

1. `ChatView.body` calls `ChatTimelineLayout.sections(timeline:)` on the main actor.
2. `ChatTimeline.body` calls `ChatTimelineLayout.rows(...)` and `renderRows(...)` synchronously.
3. `renderRows` invokes `ChatMessageTextPlanner`; a cold oversized assistant message invokes `ChatMarkdownSegmentCache`, then `Markdown.Document(parsing:)`, synchronously.
4. Mounted short/rich rows use `MarkdownReader`; its one-entry `@State` cache avoids repeated parsing only while that reader instance survives, and the initial static parse is performed from its body path.
5. If List realizes long prose before detached warming finishes, `ChatTextLayoutStore.layout` performs the full attributed-string/TextKit layout synchronously.
6. All normal SwiftUI measurement, hosted text layout, and `List` updates remain main-thread work.

This is why the old/current detached TextKit path is useful but cannot by itself guarantee responsive navigation: the main actor must first create the presentation structure and may need visible geometry before the warm worker catches up.

### How I would implement t3code-like opening in maiD

Use a revisioned **presentation gate**, not a sleep:

1. Row tap only appends a route. Do not let a completed pre-subscription expose `ChatView` during the transition.
2. Destination owns an `opening` state and starts/awaits selection or subscription.
3. Copy the minimum immutable, `Sendable` thread snapshot needed for rendering; never read the observable store from a detached task.
4. In a detached task build `ChatTimelinePresentation`: section/fold inputs, stable row IDs/models, text-renderer choices, and Markdown segment plans. Initially build only a tail window if the thread is large.
5. Check thread ID plus timeline revision when the task returns. Discard stale plans after switching threads or receiving a newer snapshot.
6. Publish the immutable plan and only then mount `List`/the collection. Start TextKit warming from that plan; visible misses may still use the synchronous final-layout fallback.
7. Expand or paginate older rows after first presentation. If prepending, preserve a visible anchor.

A detached task normally gives the navigation transaction a scheduling opportunity, but the correctness condition should be “the opening view remains until the plan is ready,” not “wait one frame.” This also makes thread switching cancellation explicit.

### The deeper remaining difference: bounded vs complete cold history

The loader alone does not explain all of t3code's advantage. PR commit `45d0dea` added thread history pagination across the server/contracts/client:

- initial load: 10 user-anchored turns;
- earlier pages: 20 user-anchored turns;
- loading is **manual**, through the synthetic “Load earlier turns” button at the top; the reviewed client does not automatically fetch when the user approaches the top;
- a “turn” is not one visible message: each user-anchored window includes the associated assistant messages/activity, and dependent subagent activity remains attached to the relevant user turn;
- a capability gate preserves compatibility with old servers;
- page merges deduplicate and sort using sequence/watermark/epoch protection;
- prepending restores the first visible message and its offset.

maiD deliberately subscribes to a complete authoritative thread snapshot. It compacts large tool payloads on the server and lazily fetches full item details, which dramatically reduces transport size, but the client still receives and models the full row history.

Consequences:

- **t3code cold open is bounded** in bytes, decode, mapped models, diffable IDs, Markdown objects, and layout work.
- **maiD cold open grows with total transcript length**, even if tool payload contents are compact.
- **maiD warm reopen can be faster/more complete**, because its session and layout caches already contain the whole thread.
- t3code pays pagination UX and race complexity and initially hides older context.

The PR's CI transfer comment reports about 95 KiB decoded snapshots in a scenario with 10 historical turns and very large retained MCP results. That is useful evidence for server projection and the 10-turn window, but it is not a transcript FPS or navigation latency benchmark.

---

## 3. Transcript container and large-scrolling behavior

### t3code: explicit `UICollectionView`

`FeatureTranscriptCollectionView` is a `UIViewRepresentable` wrapping:

- `BottomAnchoredTranscriptCollectionView: UICollectionView`;
- a compositional layout with self-sizing estimated 120-point rows;
- one transcript section;
- `UICollectionViewDiffableDataSource`;
- `UIHostingConfiguration` for each SwiftUI message row;
- `UICollectionViewDataSourcePrefetching` for settled Markdown.

This is not an all-UIKit chat renderer. UIKit owns recycling, snapshots, offsets, and prefetch; SwiftUI still renders the content inside visible cells.

Important optimizations:

- stable message IDs and a `messagesByID` lookup;
- an explicit `FeatureDetailRenderUpdate` revision chain;
- incremental deltas containing changed messages and appended IDs;
- append-only snapshot fast paths;
- `snapshot.reconfigureItems` only for changed existing rows;
- no diff animations during stream updates;
- no active SwiftUI hierarchy for offscreen messages;
- settled Markdown prefetch cancellation when cells move away or messages change.

This architecture was introduced after the original SwiftUI `ScrollView`/`LazyVStack` implementation. Commit `1f99b8b` is specifically `perf(ios): recycle native transcript rows`.

### Comparison with maiD's stashed `UICollectionView` transcripts

I inspected both local stashes rather than inferring from the current `List`:

- `stash@{1}` — `uikit chat`;
- `stash@{0}` — `uikit chat tail-first experiment`.

Both preserve maiD's existing SwiftUI row hierarchy inside `UIHostingConfiguration`, so neither removes Markdown/TextKit/SwiftUI row cost. Both also calculate `ChatTimelineLayout.rows` and `renderRows` before the collection can virtualize anything. Therefore, simply replacing `List` cannot fix the cold navigation planning hitch.

The first `stash@{1}` implementation has several concrete costs that can make it equal to or worse than `List`:

- it rebuilds a full diffable snapshot and reconfigures every retained ID on each update, even when row content is unchanged;
- `.id(itemID)` inside every hosted cell forces SwiftUI subtree identity resets;
- initial positioning calls `layoutIfNeeded`, scrolls to bottom, then calls `layoutIfNeeded` again;
- every row begins at an estimated 44-point height, which is far from giant Markdown rows and causes more self-sizing correction;
- it manually applies top-safe-area insets and later corrects geometry.

The newer `stash@{0}` is much better:

- typed plan/row/working/end IDs and per-item versions;
- only changed existing items are reconfigured unless shared rendering context changes;
- compositional list layout, automatic safe-area adjustment, and self-sizing invalidation;
- a genuine **tail-first attempt**: before the first nonzero layout it sets `contentOffset.y` to `CGFloat.greatestFiniteMagnitude` *before* `super.layoutSubviews()`, intending UIKit to request estimated tail cells instead of walking from the first row;
- direct bottom-following on later layouts.

That tail-first mechanism is something the reviewed t3code collection does **not** do. t3code applies the initial snapshot at the normal initial offset and, in the diffable completion on the next main-queue turn, calls `layoutIfNeeded` and sets a nonanimated bottom offset. Its small initial page and opening loader make any top-first intermediate work/visual state hard to notice.

#### Why the stashed collection could flash or temporarily lose content

The observed flashing during fast scrollbar scrubbing is consistent with the implementation and does not prove `UICollectionView` is generally defective:

1. Rapid thumb jumps demand distant self-sized cells whose estimated heights are still wrong; UIKit repeatedly corrects layout attributes/content size.
2. Recycling/reconfiguration replaces `UIHostingConfiguration`, so per-cell SwiftUI `@State` and child tasks can be torn down and recreated more aggressively than in the prior `List` path.
3. Markdown reader tasks, attachment/thumbnail work, or stream state can be cancelled/restarted as cells leave and re-enter the prefetch/visible region.
4. A long row that misses `ChatTextLayoutStore` still builds synchronously; short/rich Markdown can mount, parse, and then remeasure on demand.
5. `stash@{1}` amplifies all of this with full reconfiguration, forced identity, forced layout, and a poor 44-point estimate. `stash@{0}` fixes much of that but has no explicit settled-Markdown prefetch and still has the same synchronous global row planning.
6. The tail-first extreme offset and immediate corrective bottom writes can add geometry churn during the initial settling period, though they are not the primary explanation for flashes during later arbitrary scrubbing.

Why t3code hides this better: it normally exposes only 10 turns; collection prefetch warms settled Markdown; a settled visible miss synchronously returns final Markdown rather than swapping a placeholder; streamed stale documents are accepted only for the same source prefix; and render deltas reconfigure a narrow set of IDs. Those choices reduce visible content replacement, though they do not remove self-sizing cost.

The accompanying observation—t3code does not flash but scrolls less smoothly than current maiD—is also credible. maiD's warm List can attach finished TextKit glyph geometry, while t3code's cells still perform hosted SwiftUI Markdown measurement. `UICollectionView` improves lifecycle/offset determinism; it does not guarantee lower frame time. If revisiting the stash, start from `stash@{0}`, add immutable off-main/tail-window presentation and Markdown prefetch, preserve hosted state/generation by stable message ID, and benchmark before replacing `List`.

#### t3code risks/limitations

- Each cell is still a self-sizing hosted SwiftUI hierarchy; recycling does not make expensive first layout free.
- Estimated self-sizing plus large Markdown cells can still cause repeated layout correction.
- Settled cache misses can parse synchronously in `MarkdownMessageView.init`, including on the main actor.
- The coordinator is complex and stateful; synthetic rows share a string identifier namespace with server message IDs.
- One automated review found a prefetch-index bug when the “Load earlier turns” synthetic item shifts real message indices. The exact reviewed source still maps `indexPath.item` directly into `orderedIDs`, even though the diffable snapshot prepends the synthetic history item. When `canLoadEarlier` is true, Markdown prefetch/cancellation is therefore shifted by one (and the final real row may be skipped). This looks like a current localized bug, not a reason to reject the collection architecture.

### maiD: SwiftUI `List`

`ChatTimeline` uses:

- `List`;
- `ScrollViewReader`;
- a unary concrete row wrapper (`ChatTimelineRenderRowView`) to help `List` template identities without evaluating all case-specific row bodies;
- stable row IDs;
- row-level streaming reference models;
- semantic splitting of oversized settled assistant messages into independently virtualized prose/rich rows.

A SwiftUI `List` on iOS is backed by platform list/collection machinery and does recycle/virtualize rows. It is not equivalent to a plain eager `VStack`. The difference is control:

- maiD cannot directly control cell registration, prefetch windows, snapshot reconfiguration, or exact content-offset restoration;
- SwiftUI decides when to instantiate and remeasure hosted row content;
- `ScrollViewReader.scrollTo` is less deterministic than direct `contentOffset` math for changing self-sized rows.

The unary row shape and semantic segmentation show that maiD has already worked around common `List` performance traps. t3code's container is the stronger foundation **for deterministic offset, reconfiguration, prefetch, and prepend control** at extreme lengths. It is not proven to have smoother steady-state scrolling than maiD's `List`; with warm prepared TextKit, maiD may be smoother.

### Timeline projection cost

maiD currently computes, in `ChatTimeline.body`:

1. `ChatTimelineLayout.rows(...)`;
2. `renderRows(...)`;
3. per-message `ChatMessageTextPlanner.plan(...)`;
4. on cache misses, `ChatMarkdownSegmenter.segments(of:)`, which invokes `Markdown.Document(parsing:)`.

The segmentation cache is retained in `ThreadSession`, so warm paths avoid reparsing. On a cold complete thread, however, this planning can traverse many rows and parse all oversized eligible messages synchronously before `List` gets to its own lazy realization. That is a plausible source of the observed cold-thread hitch.

t3code's initial 10-turn window makes its equivalent up-front ID/model work small. Its native detail reducer also maps only changed raw messages/activities during streams instead of rebuilding the entire rendered transcript prefix.

---

## 4. Starting at the bottom, following output, keyboard changes, and pagination

### t3code

Initial positioning and bottom following are explicit:

- initial load sets `maintainsBottomAnchor = true`;
- the collection initially exists at UIKit's normal default/top offset;
- after applying the diffable snapshot, its completion schedules another main-queue callback, calls `layoutIfNeeded`, computes the raw bottom offset from content height/viewport/insets, and sets it without animation;
- it follows new content if initially loading or within 120 points of bottom;
- beginning a drag disables bottom anchoring and dismisses the keyboard;
- ending drag/deceleration re-enables anchoring only if near bottom;
- `BottomAnchoredTranscriptCollectionView.layoutSubviews` reasserts the bottom offset when self-sized content or viewport/keyboard insets change, but not while the user is interacting.

So t3code is **not** an inverted collection and does not intrinsically mount at the final bottom coordinate. It mounts normally, then jumps directly to the computed end—it does not animate through every intermediate row. The opening loader, next-turn handoff, and 10-turn page normally hide the transient top state. By contrast, maiD's `stash@{0}` tail-first experiment attempts to establish an extreme bottom offset before UIKit's first real layout requests cells.

When older history is prepended and the user is not following bottom, t3code captures the first visible message plus its exact offset from the viewport top, applies the snapshot, lays out, and restores that anchor. This should be visually stable when the collection is idle and relevant self-sized heights are settled, but it is not a perfect physical invariant in every state: applying a snapshot can disturb active deceleration, later self-sizing changes above the anchor can alter content geometry, and the implementation does not defer prepend until dragging/deceleration ends. A small snap remains possible. The manual load button makes an in-flight fling less likely than proximity-triggered pagination.

SwiftUI `List` has no public equivalent of “capture this visible cell's pixel offset, apply a prepend, then restore that offset.” Stable IDs often let it preserve a reasonable visible position, and `scrollPosition`/`defaultScrollAnchor` can express targets, but they do not expose the same reliable arbitrary pixel-offset transaction for self-sized prepends. Exact behavior usually requires a UIKit bridge/custom scroll container or a workaround that measures anchors.

`TranscriptViewportGeometryTests` cover the bottom-offset state math, including content growth, viewport shrink, and user interaction. They do not simulate diffable prepend during live deceleration or late self-sizing.

### maiD

maiD uses modern SwiftUI scroll APIs thoughtfully:

- `.onAppear` calls `proxy.scrollTo(bottomID, anchor: .bottom)`; like t3code this is a post-mount direct positioning request, not a truly inverted bottom-origin list, and SwiftUI controls how much realization occurs before it lands;
- an initial-awaiting flag prevents later geometry handling from fighting initial positioning;
- `onScrollGeometryChange` computes distance from bottom with a 24-point threshold;
- `onScrollPhaseChange` distinguishes user tracking/interacting/decelerating from idle/animation;
- viewport shrink (including keyboard inset) or content growth triggers another bottom scroll only while `ChatScrollState.shouldFollowBottom` is true;
- expanding folded content first clears follow intent, preventing an unwanted jump;
- a floating “scroll to bottom” button gives the user an explicit recovery affordance.

### Assessment

- t3code is more deterministic because it controls the concrete scroll view and offset.
- maiD has the better explicit user affordance (the bottom button).
- t3code's 120-point threshold is more forgiving; maiD's 24 points requires the reader to be very close to the end.
- For short non-overflowing chats, maiD's list naturally top-aligns content; t3code's raw bottom geometry can bottom-align once content/viewport produce a valid lower offset.
- t3code has a tested prepend-anchor flow because it paginates. maiD currently does not prepend history pages.

### Keyboard safe-area handling

Neither implementation manually tracks keyboard frames or calculates raw keyboard offsets. t3code places the composer with SwiftUI `.safeAreaInset(edge: .bottom)`. That changes the space proposed to the transcript as the keyboard/composer moves; its collection has `contentInsetAdjustmentBehavior = .never`, and the custom layout observer reacts to the resulting viewport/content geometry by reasserting bottom when appropriate. It also dismisses through UIKit drag handling plus a composer drag gesture.

Current maiD similarly uses `.safeAreaBar` on newer OS versions or `.safeAreaInset` otherwise, then reacts through SwiftUI scroll geometry. The `stash@{0}` collection explicitly uses automatic inset adjustment and comments that the final UIKit bounds/adjusted insets make keyboard notifications unnecessary. `stash@{1}` was less clean: it disabled adjustment and manually supplied a top safe-area inset. The recommended direction is the current/stash@{0} model—let SwiftUI/UIKit negotiate the safe area and keep only bottom-follow geometry, not keyboard-notification math.

---

## 5. Markdown implementation and rendering quality

### t3code: custom block parser, Foundation inline parser

There is no third-party Markdown package in the Swift app. `MarkdownDocument.swift` is a custom roughly 600-line block parser supporting:

- paragraphs;
- ATX and Setext headings;
- fenced code blocks;
- ordered/unordered lists, nested block content, and task markers;
- block quotes;
- thematic breaks;
- GFM-style tables.

Inline styling uses Foundation `AttributedString(markdown:)` with inline-only preserving-whitespace mode.

It **does handle tables**: the custom parser recognizes GFM-style header/delimiter rows, alignment, escaped pipes, and normalized row widths. Rendering uses a horizontally scrolling SwiftUI `Grid`; column-width estimates are prepared in the render plan rather than measured repeatedly in `body`. “Custom” here means t3code owns both that block parser and its SwiftUI table/list/code/quote views; Foundation is used only for inline attributed Markdown.

This is custom Markdown rendering, but it is not a full CommonMark/GFM implementation. Compared with `swift-markdown`, it has a narrower syntax/correctness envelope. Examples that deserve differential tests include reference links/definitions, indented code, raw HTML, autolinks, images, footnotes, complex lazy list continuation, and interactions between table-like lines and following block starters. An automated review did find a table/block-boundary parser issue during the PR; it was later marked obsolete after a fix.

Code blocks are monospaced plain text with copy and wrap controls. There is **no token syntax highlighting** and no math rendering.

### t3code cache and streaming renderer

`MarkdownRenderCache` is one of the PR's strongest pieces. It caches an immutable **render plan**: parsed block structure, Foundation-produced inline attributed runs, and table-width estimates. It does **not** cache final SwiftUI view instances, line wrapping, cell height, or glyph geometry; those still depend on width/Dynamic Type and are laid out by SwiftUI/UIKit.

Why this cache matters even though a parsed message normally does not change:

- a mounted view can retain its parse, but collection/List virtualization destroys offscreen row views and recreates them later;
- navigation remounts transcript rows;
- SwiftUI may reconstruct value views frequently, while a process cache lives independently of a particular cell;
- collection prefetch can parse before a row is visible only if the result has somewhere durable to live;
- identical concurrent requests can share work;
- each streaming revision changes, but unchanged inline blocks can retain identity and the final streaming result can become the settled entry rather than being parsed again;
- avoiding parser/attributed-string allocations lowers CPU and reduces the chance that a visible cell first shows fallback text and then changes height.

It is a performance cache, not a correctness requirement. Its concrete policies are:

- deterministic FNV-1a content fingerprint plus UTF-8 count;
- final source equality check prevents fingerprint collision errors;
- `NSCache` document limit: 512 entries / 12 MiB cost;
- inline-run limit: 2,048 entries / 8 MiB cost;
- memory warning clears documents, inline runs, and in-flight work;
- async cache misses render in `Task.detached`;
- identical concurrent requests share one in-flight task with waiter cancellation;
- streaming intermediates do not evict settled documents;
- the final streaming document is promoted into the settled cache;
- inline runs have reference identity, allowing unchanged streaming blocks to compare equal;
- tables estimate column widths during the render pass rather than repeatedly measuring cells in `body`;
- settled collection-view prefetch warms likely upcoming rows.

Streaming rendering is throttled to 150 ms. One render runs at a time; the newest pending revision wins. A generation prevents stale drains from clearing or delivering over replacements. A stale displayed document is accepted only when its source is a prefix of the current source, preventing recycled cells from briefly showing another message.

Important tradeoff: settled `MarkdownMessageView.init` calls `documentImmediately` on a cache miss so geometry is final on first display. That avoids a plain-text-to-Markdown layout swap, but parsing and inline attributed-string creation can occur synchronously on the main actor. t3code previously attempted to prewarm an initial tail and force hidden layout; commit `7c1c432` removed that strategy because it interfered with repeated navigation. Pagination and normal collection prefetch now do most of the protection.

### maiD: MarkdownView + swift-markdown + native long-prose path

maiD does have several caches, but at different layers:

1. MarkdownView's static `MarkdownReader` keeps one `MarkdownParseResult` in `@State` and reuses it while the same mounted reader and parse request survive. It does **not** provide a global cache across cell destruction/navigation.
2. `StreamingMarkdownReader` keeps the previous parse result and incrementally parses on a detached task; that state is also tied to the mounted reader/source lifetime.
3. `ChatMarkdownSegmentCache` stores up to 256 message-ID/source semantic split results inside `ThreadSession`, so unchanged oversized messages are not reparsed merely because the timeline replans.
4. `ChatTextLayoutStore` goes further for optimized prose: it caches attributed text, TextKit storage/manager/container, finished glyph layout, height, and sometimes an idle `UITextView`.

Thus the intuition “blocks do not reparse after they are parsed” is true **within a surviving reader or matching segment/layout cache entry**, but not universally. maiD's short/rich settled Markdown can be parsed again after its virtualized row is destroyed and remounted. Its giant prose cache is deeper than t3code's cache but narrower by renderer path and much heavier per entry.

maiD has three deliberate rendering modes:

1. **Settled short/rich document:** `MarkdownText(parseResult)`, backed by RichText/UITextView.
2. **Streaming document:** `MarkdownView(parseResult)`, native SwiftUI blocks, avoiding RichText's repeated full-document non-scrolling text-view measurement as the row grows.
3. **Settled oversized eligible content:** semantic segmentation. Rich blocks stay in MarkdownView; contiguous prose uses a custom `swift-markdown` walker and a prepared native TextKit layout.

Features include:

- `swift-markdown` parsing;
- incremental `StreamingMarkdownReader` and static `MarkdownReader`;
- Highlightr-backed Atom One Light/Dark code syntax themes;
- math rendering;
- custom horizontally scrollable tables;
- source sanitation that converts HTML/image syntax to inert code;
- a plain-text safety fallback for unsupported/unsafe parse results.

For messages above 2,048 UTF-8 bytes, settled assistant Markdown is semantically split only at rich blocks. Adjacent headings/paragraphs/lists/quotes remain one prose segment so selection is not arbitrarily chopped. Code, tables, HTML, and images become separate rich rows. Messages containing reference definitions or potential math remain on the document-wide renderer to preserve semantics.

This delivers significantly better language features and correctness than t3code, at the cost of more dependencies, more renderer paths, and more possible visual/lifecycle inconsistency between streaming, short settled, and optimized long settled states.

### maiD prepared TextKit layouts

For long prose and long user prompts, maiD can build a complete TextKit 1 stack in a detached task:

- attributed string;
- text storage;
- layout manager;
- fixed-width text container;
- ensured glyph layout and final height.

A visible `UITextView` adopts the already-laid-out container. The store also retains up to 16 idle text views for exact-layout reuse.

Limits:

- 256 prepared layouts per thread store;
- registry retains three recent thread stores for the current Dynamic Type size;
- newest transcript rows warm first, sequentially, to avoid competing layout tasks.

This can make a warm long-prose scroll extremely efficient. Risks:

- as many as 3 × 256 complete TextKit stacks, plus attributed strings and up to 16 idle text views per retained store;
- count/FIFO bounds rather than byte-cost bounds;
- no observed memory-warning clearing;
- a visible row that beats warmup builds synchronously to avoid a placeholder flash;
- segmentation/planning before warmup can still occur on the main actor;
- segment and layout entry order is FIFO rather than true LRU on hits.

### Markdown verdict

- **Feature quality and standards behavior:** maiD.
- **Bounded cache engineering and stream coalescing:** t3code.
- **Warm giant prose:** maiD may be faster due to cached glyph geometry.
- **Cold giant transcript:** t3code likely wins overall because it initially loads only 10 turns, despite synchronous visible cache misses.
- **Maintenance simplicity:** t3code avoids a dependency graph but owns a Markdown parser forever; maiD outsources standards parsing but owns a complex multi-renderer optimization layer.

For maiD, do not add another cache solely because t3code has one. First instrument static `MarkdownReader` parse calls during a rapid down/up scrub and thread reopen. If short/rich rows materially reparse after recycling, add a bounded process-level `MarkdownParseResult` cache keyed by sanitized source plus all parse-affecting math/renderer options, with in-flight coalescing and memory-warning purge. Keep it separate from width/Dynamic-Type glyph layout. The existing segment and TextKit caches should remain, but under one observable byte budget.

---

## 6. Text selection and links

### t3code

- Selection is off by default.
- A per-message context menu toggles “Select text” / “Done selecting”.
- “Copy message” copies the raw source.
- Code blocks have a dedicated copy control.
- Source and diff views enable selection.

Because a Markdown message is a hierarchy of independent SwiftUI `Text`, `Grid`, and code-block views, selection is likely block-local rather than one continuous document selection across every Markdown block.

Foundation inline links carry link attributes and are accent-colored. Unlike maiD's style, no explicit discarded `openURL` environment was observed in the chat Markdown renderer, so link interaction follows normal SwiftUI behavior where selection and surrounding gestures permit it.

### maiD

- Selection is enabled by default in Markdown content.
- Settled short/rich Markdown uses one non-scrolling RichText text view, giving strong document selection behavior.
- Long native prose is a selectable non-scrolling `UITextView` across contiguous prose blocks.
- Rich segments and streaming SwiftUI blocks are separate selection surfaces.
- User messages use literal selectable text on optimized paths.

maiD intentionally discards `openURL`, and the custom prose renderer underlines links without attaching URL actions. Links are display-only. This is safer/inert but less useful.

**Verdict:** maiD is better for immediate text selection; t3code is better if live links are desired, but its selection activation and cross-block continuity are weaker.

---

## 7. Streaming updates and observation invalidation

### t3code

The raw active detail stream is reduced incrementally in `NativeFeatureClient`:

- a dedicated selected-thread stream;
- raw mutation tracking;
- mapped-message/activity render cache;
- 80 ms detail publish throttle;
- deltas identify changed and appended messages;
- collection view reconfigures only those cells;
- Markdown independently renders at a slower 150 ms cadence.

Shell/home publication is separately throttled (about 250 ms). Passive environments use lower-frequency refresh/polling.

This is a strong end-to-end invalidation strategy: wire event → raw mutation → mapped delta → diffable cell reconfigure → changed Markdown tail.

### maiD

maiD uses different but also strong isolation:

- `sessionsByID` is `@ObservationIgnored`, so hidden subscribed threads do not invalidate visible views;
- selected-session computed properties depend on an explicit generation counter;
- event reduction mutates a dictionary subscript in place to avoid accidental copy-on-write of the timeline;
- stable `ThreadStreamingText` reference models let only the actively streaming message/reasoning leaf observe text changes;
- the composer captures a narrow projection rather than depending on the whole thread timeline;
- compact tool summaries are stable; large details hydrate only on demand.

This avoids broad SwiftUI invalidation well. The remaining active-row cost is the renderer itself: the package streaming path still parses and lays out a growing active message, and an extremely long live response remains one row until it settles.

**Verdict:** both have serious optimization work. t3code has more granular collection-cell update control; maiD has cleaner observation isolation around hidden sessions and raw streaming text.

---

## 8. Home/thread list

### t3code

`HomeThreadCollectionView` is another explicit `UICollectionView` with:

- compositional list layout;
- diffable data source;
- SwiftUI row hosting;
- cached home presentation keyed by model revisions and query/project/time inputs;
- structural snapshots only when IDs change;
- item reconfiguration for changed content/selection;
- visible-only elapsed-time refresh;
- 1 Hz timer only while a visible working row needs seconds, otherwise roughly 60 seconds;
- initial settled-thread limit of 12 and subsequent batches of 25.

Commits `cc021c0` and `e1cdab1` specifically moved timing work out of broad parents and added explicit row recycling.

### maiD

`IOSThreadListView` is a SwiftUI `List` over a merged/filter/sort projection of chat and terminal rows. Local source caches several derived provider/thread collections in `ThreadStore`, and each terminal/thread row receives a relatively narrow value. Time labels use per-row minute `TimelineView`s.

It is much simpler and likely sufficient for normal local-daemon thread counts. t3code has better control and likely scales more predictably to thousands of rows and multi-environment aggregation.

---

## 9. Ghostty terminal

### t3code terminal architecture

The app vendors `GhosttyKit.xcframework` and directly calls Ghostty C APIs in a custom roughly 1,073-line `TerminalSurfaceView.swift`.

The surface provides substantial iOS-specific behavior:

- Ghostty app/surface creation with custom IO;
- iOS UIView/IOSurface layer integration;
- hidden `UITextField` keyboard bridge;
- hardware key encoding;
- mobile accessory keys and modifier state;
- paste and clear actions;
- pan gesture mapped to mouse scroll;
- pinch gesture mapped to font-size steps;
- theme configuration staged through a temporary Ghostty config file;
- multiple terminal sessions and session switching.

Transport/render path:

1. terminal server events are converted to `FeatureTerminalSnapshot`;
2. each output event appends to `snapshot.buffer: String`;
3. buffer is capped to the newest 512 KiB at a UTF-8 and line boundary;
4. the observable `terminal` state is replaced;
5. SwiftUI updates `GhosttyTerminalSurface(buffer:)`;
6. `GhosttyTerminalView.applyRemoteBuffer` checks whether the cumulative new string has the old string as a prefix;
7. if so, it feeds only the suffix; otherwise it destroys/recreates the surface and replays the retained buffer.

This cap is important and was added after automated review flagged unbounded terminal accumulation. It prevents runaway memory. It does not eliminate per-event growing-string append, copy/prefix work, observation invalidation, or full reset when the retained tail rolls over and no longer starts with the prior buffer.

Correctness limitations:

- replaying a truncated raw byte/string history is not equivalent to restoring terminal state; modes, alternate screen, cursor, styling, partial escape sequences, and erased content can diverge;
- attach starts with hard-coded 80×24 before later measured resizing (also identified by automated review);
- `supports_selection_clipboard` is explicitly false;
- context menu offers “Copy output”, which strips ANSI from the full retained buffer, not native range selection.

### maiD terminal architecture

maiD uses `Aqothy/libghostty-spm`'s `GhosttyTerminal` product on the client and a pinned server-side `libghostty-vt` model.

Hot path:

- terminal transport has a separate `RPCClient` from chat;
- Go reads PTY output into a bounded queue and batches up to 64 KiB or 8 ms;
- raw `Data` goes directly through `TerminalOutputPipeline` to `InMemoryTerminalSession.receive`;
- raw bytes never enter `@Observable` state or SwiftUI `body`;
- the SwiftUI surface receives only a stable `TerminalViewState` integration object;
- row/list state sees only low-frequency lifecycle summaries.

Attach/reconnect correctness:

- server keeps a passive Ghostty VT model with 2 MiB bounded scrollback;
- the model exports a native `GHOSTSNP` snapshot carrying scrollback, primary/alternate screens, cursor, parser continuation, modes, margins, tab stops, and style state;
- snapshot capture is atomic with the stream sequence;
- client validates the snapshot format, restores it transactionally, then applies only buffered live items with matching run ID and sequence greater than the snapshot;
- a grid change during capture causes a new snapshot at the settled grid;
- reconnect leaves the previous screen visible and disables input until replacement state is installed;
- relaunches use a new run ID and cannot mix old output into the new shell.

The server also provides backpressure: when the bounded internal queue fills, the PTY reader stops and the kernel PTY buffer slows the child rather than dropping output.

### Terminal verdict

- **Performance, attach fidelity, reconnect correctness, and architecture:** maiD by a large margin.
- **Bespoke iOS input/accessory/pan/pinch/theme surface polish:** t3code.
- **Text selection:** t3code explicitly lacks native range selection; maiD delegates interaction to the package surface and should be verified on device for the package version in use.
- **Maintainability:** maiD has more protocol/server complexity, but the complexity enforces clear invariants. t3code's direct C integration is locally self-contained yet places raw-pointer, UIKit, GCD, renderer, keyboard, and transport-replay assumptions in one large view file.

---

## 10. Diffs and review

Neither client uses a third-party diff library in the reviewed code. In t3code, the patch parser, adjacent delete/add pairing, tokenization, bounded token LCS, full-file hydration, line UI, selection, review-comment prompt generation, and send/copy workflow are all app-owned code. SwiftUI/Foundation provide controls and attributed text, not a diff engine or review package.

### t3code

`t3code` review is a full workspace feature:

- server returns bounded diff previews (tracked patch about 120 KB; untracked file patches about 80 KB each in current server constants);
- client custom-parses Git unified diff in `NativeWorkspaceMapper`;
- adjacent deletion/addition runs are paired;
- token-level longest-common-subsequence highlighting marks changed spans, bounded to 20,000 token-cell comparisons;
- file summary shows additions/deletions and statuses;
- tapping a file fetches old/new contents (server max around 1 MiB per file operation);
- `FeatureFullDiffHydrator` expands partial hunks into full-file context and uses binary search for old/new line anchor lookup;
- diff lines are a **bidirectional** `ScrollView([.horizontal, .vertical])` with `LazyVStack`: “bidirectional” means the one code surface pans both vertically through lines and horizontally across long no-wrap lines, not that it shows two files side by side;
- fixed-width monospaced text, old and new line-number columns, backgrounds, and selectable text are custom SwiftUI row composition;
- users can tap/select a line, compose a review comment, copy the custom-generated agent prompt, or send it through the normal client message API. This review workflow is also custom.

Strengths:

- custom inline word-change spans: neighboring deletion/addition runs are tokenized and paired, then a bounded custom LCS identifies unchanged versus emphasized spans;
- horizontal scrolling preserves long code lines;
- line-level review workflow;
- full-file hydration;
- bounded server previews;
- diff hydration was optimized from an O(n²) anchor scan to binary search. More exactly, full-file context lines need an approximate old-line number from ordered patch anchors; the previous implementation scanned anchors for each emitted line, while the current lookup is binary search, changing that part from approximately `fullLines × anchors` to `fullLines × log(anchors)`.

maiD has no equivalent hydration hot path. When it receives `oldText`/`newText`, its adapter already creates a full-file presentation by finding common prefix/suffix and marking the whole changed middle (linear, but less granular than a real diff algorithm). When it receives a patch, it presents that patch rather than fetching old/new file content and filling every omitted context line. Therefore maiD does not need t3code's anchor binary search unless it adds full-file hydration.

Weaknesses:

- initial parser is less robust than maiD's parser for quoted Git paths and malformed/headerless patches;
- full hydration can create one row model for every line of a near-1 MiB file;
- no source syntax coloring inside the diff;
- line list is SwiftUI `LazyVStack`, not an explicit recycled collection;
- selection/review state is all in one 526-line view file;
- source-control actions can partially succeed while the UI retains stale pre-action status if refresh/action throws.

### maiD

maiD's `UnifiedDiffParser` is custom and more defensive:

- CRLF normalization;
- Git and plain `---`/`+++` headers;
- added/deleted/renamed/binary metadata;
- quoted Git token/path parsing;
- multiple files and hunks;
- malformed/headerless partial patches;
- no-final-newline markers;
- stable structural IDs across append-only reparses;
- unique IDs for duplicate paths/hunk starts;
- adapters for provider-neutral `FileChange`, patch payloads, and old/new full text.

Parsing and presentation-model construction run in a detached task, and `UnifiedDiffView` shows a parsing loader. Rows use SwiftUI `List` with a unary wrapper and stable IDs. There are correctness tests plus `XCTMeasure` tests for a 20,000+ row synthetic patch.

Strengths:

- more robust parser and provider-neutral adapter;
- parsing off the main actor;
- stable streamed-patch identities;
- explicit performance tests;
- binary/malformed/no-newline handling.

Weaknesses:

- current UI has one displayed line number rather than side-by-side old/new columns;
- lines wrap to available width rather than offering a code-style horizontal viewport;
- `attributedContent` exists in the model but no current syntax or word-diff highlighter populates it;
- no inline changed-token emphasis;
- no file browser/full-file hydration/line-comment workflow;
- only tool-captured changes are viewable, not an arbitrary repository review.

### Can maiD simplify its defensive parser?

Yes, but only after defining where normalization is guaranteed. “Correct patch” does not mean “one trivial patch spelling”: CRLF, quoted Git paths, renames, multiple hunks/files, binary metadata, and `\ No newline at end of file` are all valid inputs rather than malformed recovery cases.

A useful classification:

| Behavior | Remove from Swift only when… | Recommendation |
| --- | --- | --- |
| Malformed/headerless partial-patch repair | server rejects or canonicalizes malformed provider output | **Good first simplification.** Fail visibly instead of guessing if that is the desired contract. |
| CRLF normalization | server canonicalizes all patch/text line endings | Keep unless moved; it is cheap and Windows input is valid. |
| Git vs plain `---`/`+++` headers | server emits exactly one canonical format | Pick one at the server boundary, then remove the other path. |
| Quoted Git token/path parsing | server sends decoded `oldPath`/`newPath` structurally | Do not just drop it: spaces, tabs, escapes, and non-ASCII quoting are valid Git output. Move it server-side. |
| Added/deleted/renamed/binary metadata | status/paths/binary flag are trusted structured fields | Prefer structured fields; then the Swift patch parser need only hunks/lines. |
| Multiple files | server splits one patch into one structured change per file | Safe to remove after contract change. Multiple hunks within a file should remain. |
| No-final-newline markers | server provides line-ending metadata or product accepts losing it | Usually keep; it affects exact file semantics. |
| Stable/unique structural IDs | never | Keep this UI requirement, although ID assignment can be a much smaller post-parse pass. Correct patches can still contain repeated paths/hunk starts in combined streams. |
| `diff` versus `oldText`/`newText` adapters | daemon emits one canonical structured diff model | Move normalization to Go, then delete the client adapters. ACP currently naturally supplies before/after blocks, so assuming every provider already emits a patch is not the current contract. |

My preferred simplification is not a less-correct ad hoc Swift parser. Make the daemon the single boundary: accept provider-specific `diff` or `oldText`/`newText`, validate/canonicalize once, and send a structured `DiffDocument` (file status/paths, hunks, typed lines, final-newline state) to every client. Then Swift can delete most parsing and repair code, use strict decoding, and retain only presentation IDs/highlighting. If changing the server is out of scope, removing only malformed/headerless inference is reasonable; the rest handles valid diversity.

### Do no-wrap diffs require `LazyVStack`?

Not merely to stop wrapping. A `List` row could contain `Text(...).fixedSize(horizontal: true, vertical: false)` inside its own horizontal `ScrollView`, but every row would then have an independent horizontal offset, so columns would not move together.

T3code wants one synchronized code viewport, so it uses one outer `ScrollView([.horizontal, .vertical])` and a vertical `LazyVStack`; every line shares the same horizontal coordinate space. In pure SwiftUI, adopting that exact behavior generally means leaving `List` for a lazy stack. The tradeoff is that `LazyVStack` lazily creates views but does not offer the same explicit cell recycling as `List`/`UICollectionView`.

Alternatives for maiD:

1. Keep `List` and keep wrapping—the simplest and often smoothest.
2. Keep `List`, add per-row horizontal scroll—easy, but horizontally unsynchronized and awkward.
3. Use t3code's bidirectional `ScrollView` + `LazyVStack`—best pure-SwiftUI shared horizontal viewport; benchmark 20k rows/memory.
4. Use a custom `UICollectionView`/`UIScrollView` with content width based on measured maximum line width—shared horizontal offset plus recycling, at much higher implementation cost.

### Diff performance verdict

For the work both apps perform, maiD currently has the safer compute path: its parser, adapter, structural-ID assignment, and complete presentation-row array are built in one detached task behind “Parsing diff…”. It has measured 20,000+ row fixtures. T3code's `NativeWorkspaceMapper.review` (parse plus custom word spans) is called by its `@MainActor NativeFeatureClient`, and full-file hydration is called from the diff view task with no explicit detached boundary. Binary search fixes the anchor algorithm, but a near-1-MiB full-file row expansion can still be meaningful main-actor work.

For scrolling, maiD `List` likely has the better recycling behavior; t3code's `LazyVStack` has the better no-wrap shared-horizontal presentation. Neither source provides a matched device FPS result. T3code may build many more rows because it hydrates full-file context, while maiD usually displays only patch rows (except its old/new full-content adapter). That data-volume difference can dominate the container.

Overall:

- **Parser robustness, off-main planning, IDs, tests, and likely large-plan responsiveness:** maiD.
- **Review product, custom inline changed spans, code-line readability, and full-file context:** t3code.
- **Very large diff scrolling:** unresolved without a matched 20k-row/device test; expect maiD to recycle better and t3code to handle long horizontal lines better.

---

## 11. Files, source highlighting, image preview, and source control

### t3code file browser

The file browser:

- lists project entries from a server-side workspace index (bounded around 25,000 entries);
- derives directory children client-side;
- filters hidden files and local search text;
- supports server-backed project file search elsewhere in the composer/workspace;
- reads text files up to 1 MiB and marks truncated previews;
- rejects binary text reads;
- infers image, Markdown, source, or plain-text preview type;
- loads signed image assets, caps input to 64 MiB, and downscales off-main to 4,096 pixels;
- supports image zoom and sharing;
- prewarms Markdown files through the same Markdown cache.

Source highlighting is custom, not Highlightr/Tree-sitter:

- immutable line/span plans are computed once in a detached task;
- highlighting is disabled above 512 KiB or for individual lines above 32 KiB;
- token kinds: plain, comment, keyword, literal, number, property;
- limited keyword tables for Swift, JS/TS, Python, Rust, Go, shell, and a common fallback;
- simple string/comment/number/property lexing with basic block-comment continuation.

This is efficient and bounded but intentionally shallow. It will not match a real grammar for interpolation, regex literals, nested comments, contextual keywords, multiline strings, escaped delimiters, and many language-specific edge cases. Source is shown in a bidirectional `ScrollView`/`LazyVStack` with line numbers and selection. An automated review noted the trailing padding makes even short files slightly horizontally scrollable at the reviewed head.

### t3code source control

The source-control screen shows:

- branch/upstream/ahead/behind;
- PR information;
- changed/staged file rows;
- available actions: commit, push, pull, create PR, and combined actions;
- commit-message prompt and loading overlay.

This has no maiD equivalent today.

### maiD

No general project file browser, source preview, image workspace browser, or source-control action screen was found in the current Swift client. maiD can show file paths/tool summaries and captured file changes through the diff viewer.

**Verdict:** t3code has a major product-capability advantage. For future maiD implementation, t3code's bounding/off-main approach is worth copying, but a maintained syntax engine would provide higher fidelity than its handwritten lexer.

---

## 12. Composer, attachments, approvals, and agent activity

### Composer interaction and provider controls

`t3code`'s composer is the broader mobile coding-agent surface:

- collapsed and expanded modes, with a one-to-seven-line SwiftUI `TextField`;
- Return always inserts a newline; only the explicit send button submits;
- provider/model picker and context-usage meter;
- inline `/` provider-command completion, `/model` completion, `$skill` completion, and `@path` workspace completion;
- trigger detection memoized once per draft revision rather than recomputed by every dependent property;
- path search debounced by 140 ms and capped at 20 results;
- follow-up submission while a turn runs;
- image attachments from Photos, camera, or Files.

maiD's composer is simpler but has useful strengths:

- one stable composer identity across draft-to-thread transition;
- up to six lines; iOS uses the explicit send button while macOS handles Return-to-send and Shift-Return-to-edit;
- provider-exposed generic boolean/select config options rather than only app-modeled choices;
- context-token usage in the advanced options sheet;
- slash commands in the Add menu;
- working directory/provider/config preferences for new drafts;
- a visible queue above the composer, with **Steer** and **Remove** actions for each queued prompt.

maiD does not currently provide t3code's inline model/skill/file mention menu. t3code does not expose maiD's equally explicit per-prompt queue management in the composer; it primarily represents pending delivery as optimistic queued transcript rows and reconciles them through the outbox.

### Drafts, queueing, and durability

`t3code` persists the complete draft—text, selected model/options, workspace choices, attachment bytes, and thumbnails—to an atomic Application Support JSON file after a 220 ms debounce. It also writes new-thread and follow-up submissions to a separate atomic outbox **before** sending, with stable command/message/thread identities for idempotent retry after an ambiguous disconnect or app relaunch.

That is materially more resilient than maiD's current persistence:

- maiD persists per-thread text to `UserDefaults` after 300 ms;
- new-draft provider, working directory, and provider config preferences are persisted separately;
- queued prompts and pending attachment data are memory-only;
- replacing `ChatPromptModel` while switching threads discards that model's unsent attachments, although its text is independently retained.

There is also a t3code storage-efficiency caveat: image `Data` is Codable inside whole-document JSON. Up to eight 10 MiB images can be base64-expanded and the entire draft/outbox document is atomically rewritten. No aggregate draft/outbox byte budget or attachment-blob garbage collector was observed. Its normal 2,048-pixel/JPEG normalization usually makes images much smaller, but separate content-addressed blob files would scale more safely.

maiD's explicit in-memory queue is the better interactive queue UX; t3code's disk outbox is the better delivery guarantee. These solve related but not identical problems.

### Image attachment processing

Both clients enforce **eight images** and approximately **10 MiB per prepared image**, and both keep expensive image work away from normal SwiftUI body evaluation.

`t3code`:

- downsamples every selected image to at most 2,048 pixels;
- normalizes to JPEG at 0.82 quality and creates a separate 160-pixel thumbnail;
- processes selected images asynchronously and sequentially;
- has a 96-entry / 32 MiB thumbnail `NSCache` for transcript images;
- preserves a local optimistic thumbnail until the server URL hydrates;
- has a richer full-screen remote image preview.

maiD:

- creates 320-pixel thumbnails off-main;
- generally retains and base64-encodes original file bytes rather than always normalizing them; camera images are JPEG encoded;
- uses an actor gate to serialize full image encoding globally, limiting simultaneous memory spikes;
- presents pending thumbnails and processing state clearly;
- currently renders historical message attachments as names in chat rather than t3code's image grid/full-screen preview.

The t3code path spends CPU once to reduce future wire/disk/decode cost; maiD preserves source fidelity but can carry larger payloads. Both choices are defensible, though maiD would benefit from transcript thumbnail previews and t3code would benefit from bounded blob storage.

### Approvals and structured user input

`t3code` gives pending requests priority inside the composer surface:

- approval panel with approve once, always allow, decline, and cancel-turn actions;
- typed command/file access/file change labeling;
- multi-question provider input with single-select, multi-select, custom text, back/next, and answer reconciliation if questions change;
- pending requests disappear after authoritative resolution or recognized stale/unknown failures.

This is polished and keeps required action next to the main control, but it temporarily replaces ordinary composing while a request is pending.

maiD renders approvals inline in transcript history. It respects arbitrary server-provided option names/IDs and maps allow-always/reject variants, while leaving the composer independently available. Resolved approval history remains visible and folds with completed activity. No equivalent structured multi-question user-input protocol/UI was found in the current maiD client/server contract.

### Tool calls, reasoning, plans, and transcript density

This is an area where **maiD is substantially richer**.

`t3code` deliberately maps only errors and completion/lifecycle activities (`tool.completed`, `task.completed`, `turn.plan.updated`) into chat rows. Non-error activity is collapsed by turn into one generic tool `DisclosureGroup`:

- at most the latest 40 lines;
- older count summarized as “earlier updates hidden”;
- each detail normalized to a maximum 160-character preview;
- one `FeatureMessage` is updated incrementally rather than adding thousands of lifecycle rows.

That is excellent density and update-cost control, but it loses typed distinctions, structured per-tool status/output, separate reasoning, direct file-change opening, and full detail hydration. Workspace review/files remain separate thread menu tools rather than being connected to a specific transcript step.

maiD keeps a provider-neutral typed timeline:

- reasoning is a separate selectable disclosure, open while streaming and folded after settlement;
- consecutive tools are summarized semantically (read, search, edit, command, fetch, other);
- completed turns fold intermediate assistant segments, thoughts, approvals, and activity behind “Worked for …” while final answers remain visible;
- running turns remain expanded and show a live duration;
- warnings/errors and pending approvals never hide;
- expanded tools show compact summary immediately, then lazily hydrate revision-matched full detail;
- command/query/output/error metadata is selectable and bounded to a 4,000-character preview;
- file-change steps open the shared structured diff viewer.

The cost is more timeline projection/state and more row types—the same cold-history work maiD needs to move off-main or window. Product-quality verdict: **t3code is more aggressively bounded; maiD is more informative and useful for understanding the agent's work.** Preserve maiD's model while optimizing its planning rather than replacing it with t3code's generic work log.

---

## 13. Accessibility, Dynamic Type, dependencies, and deployment floor

### Accessibility and Dynamic Type

`t3code` has visibly broader explicit accessibility work:

- semantic labels/values/actions for transcript messages, tables, task-list markers, code copy/wrap controls, attachments, approvals, review comments, and terminal controls;
- collection cells hide duplicate hosted accessibility trees and expose stable row-level labels/hints;
- extensive identifiers for transcript, message cells, opening state, composer suggestions, send/stop, terminal, and sidebar controls;
- accessibility Dynamic Type sizes force richer home rows rather than compressing metadata into the slim layout;
- transcript type-size changes reconfigure all currently loaded message IDs.

maiD has appropriate labels on core thread status, approval state, diff rows, tables, composer/attachments, terminal actions, and the scroll-to-bottom control. Its prepared TextKit cache key includes Dynamic Type and the chat clears/rewarms relevant layouts when size changes. Its always-on selection and fewer nested chat controls also help basic usability.

A source grep found roughly 182 accessibility/Dynamic-Type-related occurrences in t3code and 59 in maiD, but those numbers are only directional: t3code has many more screens, and maiD's DEBUG mock chat contributes some of its count. The actionable conclusion is not the ratio; it is that t3code more consistently annotates custom UIKit-hosted cells and controls. maiD should run VoiceOver/Switch Control audits specifically on custom long-text views, folded activity, queue rows, and the exact Ghostty package surface.

### Dependency and platform tradeoffs

`t3code`'s app UI has a small external package surface:

- ClerkKit/ClerkKitUI pinned exactly to 1.2.0 for managed authentication;
- a vendored Ghostty xcframework (44 MiB in the multi-slice source checkout; this is **not** the final stripped app contribution);
- no third-party Markdown, syntax-highlighting, image-loading, or diff package.

This reduces transitive update risk and gives precise behavior, but shifts maintenance to custom Markdown, source lexer, diff mapper, image loading, and direct Ghostty C integration.

maiD directly depends on MarkdownView 3.0.0 and `libghostty-spm` 1.5.2. The resolved transitive graph also includes RichText, swift-markdown, swift-cmark, Highlightr, SwiftMath, and MSDisplayLink. That is a larger build/binary/upstream surface, but it buys standards parsing, syntax themes, math, rich text selection, and a packaged Ghostty integration instead of rebuilding all of them.

Deployment/language difference:

- t3code: iPhone/iPad, iOS 17+, Swift 5 language mode;
- maiD app target: iPhone/iPad and native macOS, iOS 18.6+/macOS 15.6+, Swift 6 with approachable concurrency/default `MainActor`.

`t3code` reaches more existing iOS devices. maiD gets newer APIs, desktop reuse, and stricter concurrency checking.

---

## 14. Networking, reconnect, caching, and offline delivery

### t3code

`WebSocketRPCClient` is an actor implementing Effect RPC framing. This does **not** mean the Effect TypeScript library runs in Swift. The server uses Effect RPC, whose socket transport has a language-neutral JSON envelope (`_tag: "Request"`, request ID, procedure tag, payload, headers; response/stream/exit/interrupt/control frames). The Swift actor manually encodes/decodes those wire shapes and reproduces the required lifecycle semantics. It depends on the protocol contract, not on an Effect Swift package.

Notable behavior:

- subscriptions automatically reissue after reconnect;
- unary mutations that crossed the socket are failed rather than blindly replayed;
- commands use stable command/message IDs so higher layers can reconcile ambiguous acceptance;
- connection wait, send, and response deadlines for unary calls;
- cancellation sends `Interrupt` only for the correct connection/request ownership;
- reconnect backoff with jitter;
- keepalive pings;
- HTTP fallback only where a request is known not to have crossed the socket;
- shell snapshot polling fallback;
- active environment socket plus passive-environment refresh behavior;
- idle clients can be released.

`FeatureRootModel` has a durable on-disk outbox for new-thread and follow-up submissions, optimistic rows, stable identities, retry backoff, dependent queued-message ordering, and reconciliation after ambiguous failures.

This is broader and more resilient than maiD's current chat delivery because it is designed for mobile/remote/offline operation. It is also much more complex. Automated reviews found many reentrancy, cancellation, token, and lifecycle issues throughout the PR; numerous follow-up commits fixed them, but the central client still has a large state/race surface.

### maiD

`RPCClient` is simpler JSON-RPC over `URLSessionWebSocketTask`:

- request JSON encoding and response decoding run off the main actor;
- agent and terminal subscriptions share one coordinated connection with one-pass terminal envelope decoding;
- pending requests fail on disconnect;
- thread subscriptions restore from authoritative snapshots;
- automatic reconnect has bounded attempts, jitter, and a 15-second connect-attempt timeout;
- selected, protected, and recent inactive subscriptions are restored;
- local queued follow-up prompts are in memory rather than a durable network outbox;
- drafts are persisted in `UserDefaults` with a 300 ms debounce.

maiD's model is appropriate for a local daemon and is easier to reason about. It lacks t3code's multi-environment, managed credential, HTTP fallback, and durable offline send requirements.

### Thread caches

`t3code`:

- retains `FeatureRootModel.details` and `NativeFeatureClient.latestDetails`/render caches by thread;
- releases the active thread transport on view disappearance;
- keeps only one selected detail stream;
- no clear count/TTL eviction was found for per-thread detail/render dictionaries;
- Markdown itself is globally cost-bounded.

`maiD`:

- retains process-lifetime session models;
- keeps visible + protected + up to five inactive subscriptions for 30 minutes;
- warm sessions contain complete thread history and segment cache;
- TextKit layout registry keeps only three recent threads;
- full item details are revision/sequence-cached and removed on unsubscribe.

### Does maiD need five inactive subscriptions?

Probably not for correctness, and not to solve the navigation hitch.

An inactive thread can still publish events—for example, another connected client can add work, or a state transition may arrive after leaving it—so “inactive” does not literally imply a silent server stream. The policy's benefits are exact background detail continuity and instant A↔B reopening without a resubscribe/snapshot. **Protected** sessions are the important category: queued prompts, an incomplete/active turn, or pending approval stay subscribed so background work and required actions cannot be lost. The independent thread-list stream can carry summary/status changes for everything else.

Crucially, unsubscribing does not require discarding the cached `ThreadSession.thread` or its `ChatMarkdownSegmentCache`; maiD can keep a stale warm presentation snapshot, resubscribe on reopen, and reconcile authoritatively. It already removes expensive hydrated item details on unsubscribe. Therefore recent settled detail subscriptions are mainly a latency/freshness optimization, not a cache prerequisite.

Recommendation:

1. Keep **visible + protected** subscriptions.
2. Set ordinary inactive capacity to **0 or 1** initially (one is useful for rapid A↔B comparisons), not five.
3. Retain a bounded decoded session/presentation cache without a live stream.
4. On reopen, show the deterministic loader or cached shell while an authoritative resubscribe plus revisioned presentation plan completes.
5. Measure reopen latency, daemon/socket event volume, and memory before increasing the recent set.

If multi-client exact live updates to several hidden settled transcripts are a product requirement, a larger inactive set is defensible. Otherwise five full-history live sessions consume complexity/memory without addressing the main-actor planning freeze.

maiD is better at having an explicit subscription/cache policy. t3code is better at bounding heavyweight Markdown documents, but its thread-detail dictionaries deserve an eviction policy.

---

## 15. Code quality, language mode, and maintainability

### t3code strengths

- Good comments around invariants, especially WebSocket ownership, transcript anchoring, and streaming Markdown.
- Excellent iterative performance history; the author measured real failure modes and reverted strategies that hurt navigation.
- Strong use of immutable render plans and explicit revisions/deltas.
- Extensive capability/race/contract tests.
- Most expensive non-UI transforms are moved to detached tasks.
- Resource bounds exist in many places: Markdown cache, terminal tail, source highlighting, file reads, image loads, review previews.

### t3code weaknesses

- Monolithic files and responsibilities:
  - `NativeFeatureClient.swift`: 5,409 lines;
  - `ThreadDetailView.swift`: 1,698 lines;
  - `FeatureRootModel.swift`: 1,239 lines;
  - `TerminalSurfaceView.swift`: 1,073 lines.
- `NativeFeatureClient` is an especially large `@MainActor` state machine coordinating environments, polling, streams, mapping, caches, approvals, attachments, files/review/source control, terminals, retries, and date/provider caches.
- Project uses Swift language version 5 mode at the reviewed head. It does not get the same Swift 6/default-actor compile-time discipline as maiD.
- It mixes modern concurrency with direct `DispatchQueue.main.async`, locks/queues, UIKit delegates, and unchecked-sendable render objects. Some use is integration-driven, but it increases the audit surface.
- Custom parsers/lexers create long-term standards and fuzzing obligations.
- The PR is too large for ordinary review. The PR itself labels the security-critical Connect paths high risk, and Macroscope explicitly requested human review because of size.

### maiD strengths

- Swift 6 mode with approachable concurrency and default `MainActor` isolation in the app target.
- Server/client responsibilities are clearer in the terminal and compact item-detail protocols.
- Hidden session dictionaries and raw terminal paths are intentionally kept outside observation.
- Generated wire models are separated from handwritten state reducers.
- Diff and Markdown paths have targeted `XCTMeasure` coverage and DEBUG diagnostics.
- The code frequently documents performance invariants and copy-on-write/observation hazards.
- Current source already addresses loader-first navigation and stable leaf streaming.

### maiD weaknesses

- `ChatView.swift` (1,737 lines) and `ThreadStore.swift` (1,546 lines) are also too large.
- The long-text optimization is highly sophisticated and therefore costly to maintain: semantic splitting, multiple Markdown renderers, custom prose rendering, detached TextKit stacks, custom UIView reuse, and a cross-navigation registry.
- Layout caches are count-bounded but not cost-bounded and have no observed memory-pressure response.
- Several planning steps still occur synchronously in `body`.
- The shared iOS/macOS design creates conditional paths and means iOS performance changes need desktop regression care.

### Recommended simplification of maiD's long-text stack

Yes, simplify—but do not start by deleting the one optimization that is demonstrably different from t3code: detached prepared TextKit geometry. Pagination bounds the **number of turns**, not the size of one 100-KB answer, so a giant-message path remains valuable.

A lower-complexity target would be:

1. **One normal package-backed family:** keep the existing `MarkdownReader` parse path for ordinary content, with `MarkdownText` for settled selection and `MarkdownView` for streaming if measurements still justify that presentation split. Treat them as one normal policy and do not add more special cases.
2. **One giant-prose escape hatch:** above a measured byte/line threshold, use semantic rich-block splitting plus the prepared selectable TextKit prose view. Keep code/tables/math in the normal renderer.
3. **Plan off-main first:** choose modes and compute semantic segments in a detached presentation planner, so renderer selection never parses from `body`.
4. **One active-thread layout cache plus at most one recent thread**, governed by bytes, width, Dynamic Type, and memory pressure. Remove the three-thread × 256 default as a navigation requirement.
5. **Warm only the initial/near-visible tail**, not up to 256 rows merely because they exist. Grow opportunistically while idle.
6. **Delete the idle `UITextView` pool unless Instruments proves attachment setup is a material remaining hitch.** Prepared attributed/glyph layout is the main win; exact view-instance reuse is the most UIKit-lifecycle-sensitive extra layer.
7. Keep `ChatMarkdownSegmentCache` (it is small and directly prevents repeated `swift-markdown` parsing), but make it true LRU/byte-aware or subsume it into the immutable presentation cache.
8. Remove ordinary inactive live subscriptions independently; they are not required to retain a session's segment plan.

This produces two conceptual paths—normal Markdown and giant selectable prose—rather than treating navigation cache retention, parse caching, glyph caching, and native view reuse as one coupled system. Validate each deletion with the existing giant-message fixture and a rapid scrollbar scrub.

### Quality verdict

maiD has the healthier foundation for concurrency correctness and hot-byte isolation. t3code has the more mature transcript collection mechanics and a stronger record of targeted end-to-end UI performance iteration. Both should split their largest state/view files before adding more features.

---

## 16. Tests and performance evidence

### t3code

The PR reports:

- 245 native simulator tests passed, 0 failed, 1 skipped;
- repeated A→B→C→A long-thread navigation manually verified on a real-data snapshot;
- simulator and physical-device install/build checks.

The source currently contains roughly 300 `@Test`/`test...` occurrences, but that simple count includes helpers/variants and should not replace the PR's actual executed count.

Useful tests cover:

- Markdown parser/cache cancellation;
- transcript viewport geometry;
- large home collection presentation;
- native stream/retry/multi-environment races;
- pairing and managed auth;
- tools/review/source highlighting;
- platform extensions/deep links.

There are few true UI performance benchmarks. Transcript tests validate state math rather than FPS, hitch time, memory, or first-frame latency. Manual validation is useful but not reproducible benchmark evidence.

### maiD

Current `maiTests` has roughly 209 `@Test`/`test...` occurrences by the same approximate grep method.

Performance-oriented tests include:

- Markdown parsing/safety and cumulative streaming prefixes;
- hosting/layout paths;
- native and third-party 4 KB paths;
- giant 10k-word TextKit layout/cache/recycled attachment;
- medium and 20,000+ row diff parsing/model construction.

Terminal has client unit tests plus extensive Go lifecycle/snapshot/multiclient tests. Native snapshot tests enforce bounded size and preserve terminal modes/cursor/continuation behavior.

Existing local documentation records a compact-thread snapshot improvement from about 3.34 MB / 930 ms to about 75 KB / 128 ms in a physical-device Debug scenario, with warm reopen medians around 35–53 ms. This proves the value of compact tool projection but is not directly comparable with t3code's different server, 10-turn page, build, data, and device.

### Missing benchmark for both

A fair comparison should record, on the same iPhone and Release/Profile build:

- tap-to-first-navigation-frame;
- tap-to-loader-frame;
- loader-to-first-transcript-frame;
- first usable composer time;
- main-thread longest hitch and cumulative blocked time;
- peak/resident memory after opening and after A→B→C→A;
- 60/120 Hz scroll hitch ratio over a fixed 1,000-message transcript;
- streaming CPU and allocations for a 100 KB response;
- cold and warm behavior after memory warning;
- selection activation/copy latency on a 100 KB prose message;
- terminal CPU/memory during `yes`, colored progress updates, alternate screen, and reconnect.

---

## 17. What t3code is doing better

1. It **bounds cold thread work** with user-turn pagination.
2. It **acknowledges navigation immediately** and explicitly waits behind a loader.
3. It uses an **explicit recycled collection view** for both transcript and home.
4. It propagates **granular render deltas** from stream reducer to cell reconfiguration.
5. It has **explicit Markdown prefetch** and in-flight coalescing.
6. Markdown caches are **byte-cost bounded and memory-warning aware**.
7. Bottom anchoring and prepend restoration use **direct geometry/offset control**.
8. It has broader workspace features: **files, review comments, source control, and rich image/source previews**.
9. Its composer has **inline model/command/skill/file completion** and structured multi-question input.
10. It persists richer drafts and has a **durable offline outbox** with stable command identities.
11. It applies more systematic **accessibility semantics** to custom cells and controls.
12. It has broad iOS platform integration and multi-environment support.
13. Its commit history demonstrates repeated profiling-driven optimization rather than assuming “native SwiftUI” is automatically fast.

---

## 18. What maiD is doing better

1. **Terminal architecture and correctness** are substantially better.
2. Raw terminal bytes and hidden thread streams are **isolated from SwiftUI observation**.
3. Markdown has **better standards coverage, syntax highlighting, math, and safety sanitation**.
4. Text selection is **enabled by default** and can span contiguous long prose in a native text view.
5. Warm long-text performance can reuse **fully prepared glyph layout**, not only parsed Markdown.
6. Thread subscriptions have an explicit **count/TTL/protected-session policy**.
7. Its typed **tool/reasoning/activity transcript** is far more informative and opens captured file changes directly.
8. Queued prompts have explicit **Steer** and **Remove** controls, and provider config options are generic rather than app-hardcoded.
9. The unified diff parser is **more defensive**, provider-neutral, parsed off-main, and benchmarked.
10. Swift 6/default-actor configuration gives **stronger compile-time concurrency checking**.
11. The architecture is smaller and avoids t3code's cloud/security/platform breadth.
12. It supports both **iOS and macOS**.
13. It has targeted performance tests and DEBUG diagnostics for layout cache misses/attachment cost.

---

## 19. Recommended next steps for maiD

### Priority 0: verify the tested build and instrument the exact freeze

Do not redesign from observation alone. Add signposts around:

- list-row tap;
- `prepareThreadForSelection` entry/exit;
- `path.append`;
- `IOSChatDestinationView` first appearance;
- `selectThread`;
- subscribe request/response and decode;
- selected-session publication;
- `ChatTimelineLayout.sections` and `.rows`;
- `renderRows` and Markdown segmentation;
- first `List` layout and first transcript frame.

The current source appends the route before selecting, but do not assume the destination task guarantees a committed placeholder frame. Confirm the exact timing in the binary being tested. If the snapshot/select path wins the race, keep the opening surface visible until an off-main, revisioned initial presentation plan is ready; a fixed arbitrary delay should not be the long-term solution.

### Priority 1: gate and bound cold presentation work

For the observed seven-message case, first fix the deterministic presentation gate and main-actor planning; a 10-turn limit cannot help when it excludes nothing. For genuinely large threads, the most important t3code lesson is not merely `UICollectionView`; it is **bounded initial history**.

Options, from least invasive to most:

1. Keep the complete server snapshot/model but initially publish only a tail presentation window to `ChatTimeline`, expanding older rows after first frame.
2. Move timeline section/row planning and Markdown segmentation into a detached, revisioned presentation-plan task, then publish an immutable plan.
3. Add user-turn pagination to the daemon/client, with sequence watermarks and prepend anchor restoration.
4. Hybrid: subscribe to a small presentation page immediately while a complete compact model hydrates in the background for local search/offline operations.

A tail presentation window may fit maiD's existing “complete authoritative model” philosophy better than immediately changing the wire contract.

### Priority 2: consider an explicit transcript collection container

If Instruments shows `List` realization/diffing remains a major cost after bounded planning, port the useful parts of t3code's design:

- `UICollectionViewDiffableDataSource`;
- typed item IDs (message, activity, working, history control);
- `UIHostingConfiguration` for existing SwiftUI rows;
- `reconfigureItems` for changed leaves;
- append/prepend fast paths;
- explicit prefetch hooks;
- direct bottom and visible-anchor restoration.

Do not rewrite Markdown rows in UIKit first. The hybrid hosted-cell approach gets most lifecycle control while preserving existing views. `stash@{0}` is the appropriate prototype, not `stash@{1}`: retain typed IDs/versioned reconfiguration and tail-first positioning, then add presentation windowing and settled-Markdown prefetch. Do not ship it until rapid scrollbar scrubbing no longer causes hosted content/state flashes and a matched test shows an advantage over `List`.

### Priority 3: put hard memory budgets on maiD's layout caches

- Add estimated cost accounting for attributed strings/TextKit stacks.
- Add a global byte budget in addition to per-thread count.
- Purge or aggressively trim on memory warning.
- Make per-thread entries true LRU if revisit behavior matters.
- Cancel stale/in-flight warmups when width, Dynamic Type, thread generation, or memory pressure changes.
- Log current cache count/cost in performance fixtures.

### Priority 4: move segmentation/planning out of `body`

`ChatMarkdownSegmentCache` avoids repeated parsing, but the first parse still happens during render planning. Specifically move these pure stages:

- `ChatTimelineLayout.sections(timeline:)`;
- `ChatTimelineLayout.rows(...)`;
- `renderRows(...)` / `ChatMessageTextPlanner.plan(...)`;
- `ChatMarkdownSegmenter.segments(of:)`, including `Markdown.Document(parsing:)` and source slicing;
- immutable warmup-request creation and tail-window selection.

TextKit attributed-string creation, glyph layout, and height calculation are **already detached during warmup**. Keep normal SwiftUI state publication, List/collection snapshot application, `UITextView` attachment, and actual view measurement on the main actor. A visible TextKit miss is currently synchronous by design; reduce those misses through gated tail warmup rather than showing a geometry-changing placeholder.

Build a `Sendable` immutable transcript presentation plan when the selected thread revision changes. If generated wire/domain values are not safely sendable, copy only needed strings/enums/IDs into a lightweight snapshot on the main actor first. Never capture `ThreadStore`, `ThreadSession`, the fold model, or mutable observation objects in the detached closure. Publish only if thread ID, timeline revision, fold revision, width policy, and Dynamic Type still match.

### Priority 5: preserve maiD's terminal design

Do not copy t3code's cumulative-string terminal path. Copy only UX ideas:

- mobile accessory controls;
- hardware key affordances;
- terminal-session menu polish;
- pinch/live font controls;
- explicit clear/copy/paste menus.

Keep raw `Data`, native snapshot restore, run/sequence barriers, the shared connection coordinator, and stable surface objects.

### Priority 6: improve diff UX without weakening its parser

- Add old and new line-number columns.
- Add optional horizontal code scrolling/no-wrap mode.
- Populate `attributedContent` with bounded word-level LCS spans similar to t3code.
- Keep parsing/planning detached and structural IDs stable.
- Consider file-group navigation rather than one very long combined list.

### Priority 7: add workspace files/source control only if product scope needs it

If added, reuse t3code's good resource policies:

- server-root path validation;
- 1 MiB text cap/truncation marker;
- off-main line plans;
- highlighting disabled above a byte threshold;
- image byte and pixel caps/downsampling;
- signed asset URLs;
- bounded review previews.

Prefer a maintained syntax grammar engine over a handwritten multi-language lexer unless binary size/dependency policy rules it out.

### Priority 8: add durable send semantics only if maiD's connection model needs them

For a local daemon, a cross-launch mobile outbox may not justify t3code's complexity yet. If remote/offline operation becomes a requirement, copy the invariants rather than the exact storage shape:

- create stable command/message identities before first send;
- persist before attempting transport;
- distinguish “never crossed socket” from ambiguous acceptance;
- reconcile only against authoritative non-optimistic messages;
- preserve dependent queue order;
- store attachment blobs separately with aggregate byte limits and orphan cleanup instead of base64-embedding every image in one JSON document.

Independently, consider retaining pending attachment drafts across thread switches. That is a smaller UX improvement than a full outbox.

### Priority 9: preserve maiD's activity model and audit accessibility

Do not trade typed tools/reasoning for t3code's generic work log solely to gain performance. Move section/row planning off-main and window old turns while retaining:

- semantic groups and fold state;
- reasoning separation;
- lazy sequence-matched detail hydration;
- direct file-change diff opening;
- pending approvals outside completed folds.

Then run VoiceOver, Switch Control, and large Dynamic Type checks on hosted long-text views, activity disclosures, queued prompts, approvals, diff rows, and terminal controls. Add stable accessibility identifiers to a small navigation/performance UI suite rather than relying only on source-level annotations.

---

## 20. Notable t3code performance/fix commits

These commit messages are useful because they document problems the final source alone hides:

- `cc021c0` — keep native home list responsive; moves time/boundary work out of broad updates.
- `d96a558` — stream incremental thread updates; introduces dedicated reducer/render deltas.
- `22f7201` — cache native Markdown rendering.
- `1f99b8b` — recycle native transcript rows with collection view.
- `e1cdab1` — recycle native home rows.
- `3a07967` — stabilize transcript rendering; attempted initial prewarm/geometry stabilization.
- `7c1c432` — unblock repeated thread navigation; removes prewarm/forced hidden layouts that hurt repeated switching.
- `7acf144` — keep threads anchored above keyboard.
- `e7df79a` / `164fa5b` — make composer state durable and preserve durable outbox state across failure/relaunch paths.
- `2bb6646` — cut hot-path networking/state/cache waste: persistence/date/provider caches, terminal cap, Markdown fingerprints/final promotion, 150 ms stream cadence, shared coders, lifecycle fixes.
- `ee028f3` — off-main table width estimates, equatable unchanged Markdown blocks, off-main thumbnails, memory-warning cleanup, binary-search diff hydration.
- `7743a43` — latest-wins streaming renderer and UTF-8 terminal cap corrections.
- `b3737cc` — generation guard for stale streaming drains.
- `09c8cbe` — reject stale Markdown from recycled cells unless it is a source prefix.
- `7d53fab` — release idle WebSocket clients.
- `45d0dea` — paginate long thread history.
- `ff13ebd` — bring Ghostty to the terminal.
- `91b7b35` — stabilize image attachment preparation and delivery.
- `c4fb08e` — stabilize thread opening/photo selection; always use the opening state during forced refresh.

The progression is instructive: t3code first added caching and prewarming, then removed eager opening work when it made repeated navigation worse, and finally relied on a bounded page, explicit recycling, cache prefetch, and a loader-first transition.

---

## 21. Source map

### t3code

- `apps/swift-ios/Features/Chat/ThreadDetailView.swift`
- `apps/swift-ios/Features/Chat/FeatureComposerView.swift`
- `apps/swift-ios/Features/Chat/FeatureComposerPowerFeatures.swift`
- `apps/swift-ios/Features/Chat/FeatureComposerRequestViews.swift`
- `apps/swift-ios/Features/Chat/ImageAttachmentViews.swift`
- `apps/swift-ios/Features/Chat/MarkdownDocument.swift`
- `apps/swift-ios/Features/Chat/MarkdownRenderCache.swift`
- `apps/swift-ios/Features/Chat/MarkdownMessageView.swift`
- `apps/swift-ios/Features/Workspace/HomeThreadCollectionView.swift`
- `apps/swift-ios/Features/Workspace/WorkspaceView.swift`
- `apps/swift-ios/Features/Root/FeatureRootModel.swift`
- `apps/swift-ios/App/NativeFeatureClient.swift`
- `apps/swift-ios/App/NativeWorkspaceMapper.swift`
- `apps/swift-ios/Core/T3Client.swift`
- `apps/swift-ios/Core/WebSocketRPC.swift`
- `apps/swift-ios/Features/Terminal/FeatureTerminalView.swift`
- `apps/swift-ios/Features/Terminal/TerminalSurfaceView.swift`
- `apps/swift-ios/Features/Review/FeatureReviewView.swift`
- `apps/swift-ios/Features/Files/FeatureFilesView.swift`
- `apps/swift-ios/Features/SourceControl/FeatureSourceControlView.swift`
- `apps/swift-ios/Features/Shared/FeatureToolModels.swift`

### maiD

- `clients/swift/mai/Platform/iOS/IOSCompactAppContainer.swift`
- `clients/swift/mai/Platform/iOS/IOSChatDestinationView.swift`
- `clients/swift/mai/Features/Chat/ChatView.swift`
- `clients/swift/mai/Features/Chat/PromptComposer.swift`
- `clients/swift/mai/Features/Chat/ComposerAttachments.swift`
- `clients/swift/mai/Features/Chat/ComposerOptionsSheet.swift`
- `clients/swift/mai/Features/Chat/ChatPromptModel.swift`
- `clients/swift/mai/Features/Chat/ChatTimelineLayout.swift`
- `clients/swift/mai/Features/Chat/ChatMarkdownMessageView.swift`
- `clients/swift/mai/Features/Chat/ChatMarkdownSegmentation.swift`
- `clients/swift/mai/Features/Chat/ChatTextLayout.swift`
- `clients/swift/mai/Features/Chat/ChatProseMarkdownRenderer.swift`
- `clients/swift/mai/Features/Chat/ChatMarkdownContentStyle.swift`
- `clients/swift/mai/Features/Threads/ThreadStore.swift`
- `clients/swift/mai/Features/Threads/ThreadSession.swift`
- `clients/swift/mai/Network/RPCClient.swift`
- `clients/swift/mai/Features/Diff/*`
- `clients/swift/mai/Features/Terminal/*`
- `internal/terminal/*`
- `internal/daemon/terminal.go`

---

## 22. Remaining validation work

The source comparison is substantially complete. Before treating the recommendations as a migration plan, the highest-value remaining work is:

1. matched Instruments capture of cold/warm A→B→C→A navigation;
2. exact memory-cost measurement of the three retained maiD TextKit stores;
3. 1,000-message scroll benchmark comparing `List` to a hosted-cell collection using the same row views;
4. differential Markdown corpus comparing t3code's custom parser with swift-markdown;
5. terminal interaction verification for range selection in the exact `libghostty-spm` package build;
6. device test of diff scrolling with 20,000 rows and very long lines.
