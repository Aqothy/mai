# Chat performance — handoff

> Historical baseline. Its long-message guidance is superseded by
> `CHAT-PROSE-PIPELINE-HANDOFF.md`; the scroll-state separation and streaming
> guidance below still apply. Current macOS pagination and AppKit rendering
> findings live in `CHAT-MACOS-PAGINATION-AND-PERFORMANCE.md`.

Continuation notes for the Swift client chat (`clients/swift`). Read
`clients/swift/AGENTS.md` first. Do not edit `mai.xcodeproj` or generated model
files. Use the Xcode MCP to build and run tests, then use Computer Use for an
interactive chat/scroll check.

## Product priority

The primary goal is smooth manual scrolling while messages continue streaming.
Prefer a small, understandable baseline over caches, custom equality,
scroll-aware rendering modes, or special handling for rare giant messages.

The user explicitly accepts some hitching when a several-thousand-word message
mounts. Normal chats will eventually contain compacted history, so optimizing
the uncommon giant-essay case is not worth complicating the normal path.

Streaming text must not pause, slow down, or change visual behavior merely
because the user is touching or scrolling the list.

## Current approach

The production timeline uses ordinary SwiftUI `Text` for messages. There is no
custom streaming animation, client display buffer, 90 ms update cadence, or
450 ms display delay. Every text value published by `ThreadStore` becomes the
row's displayed value normally.

`ChatScrollState` has one narrow responsibility: automatic bottom-following.

- While the list is idle at the bottom, content growth keeps the end marker
  pinned after layout.
- As soon as the user starts tracking, interacting, or decelerating,
  `shouldFollowBottom` becomes false so `scrollTo` cannot fight the gesture.
- When the gesture ends at the bottom, following resumes.
- Scroll phase is not placed in the environment and is not read by message
  rendering.

The remaining low-complexity SwiftUI optimizations are:

- Stable, cheap row identity from message IDs, item IDs, and approval request
  IDs (`TimelineEntry.chatIdentity`).
- A single-root `VStack` for the branching timeline row, preserving `List`'s
  unary-row fast path.
- Narrow message row inputs (`text`, `role`, `attachments`) rather than a full
  generated model plus unrelated turn state.
- A separate composer view boundary so composer edits do not re-evaluate the
  timeline.
- Server-side compact `ToolCallSummary` values for normal tool rows, with full
  details fetched only when expanded.

Inline item payloads and approval arguments are not truncated by the Swift
client. The daemon already bounds normal tool summaries; generic non-tool
payloads render in full.

## The streaming-scroll fix

The performance-heavy version coupled gesture state to rendering:

1. `ChatTimeline` published `isUserScrolling` through a custom environment
   value.
2. Streaming message views read that value.
3. Starting a drag settled the pending reveal immediately, potentially adding
   a large amount of text to layout at gesture start.
4. While dragging, later chunks bypassed normal pacing, so every raw stream
   update could lay out the growing message.
5. The environment change itself invalidated streaming rows at scroll-phase
   transitions.

That entire coupling was removed. `onScrollPhaseChange` now calls only
`ChatScrollState.noteUserScrollActivity`. Message rendering has no knowledge of
scroll state. The custom `StreamingText` renderer was subsequently removed as
well to establish the simplest baseline: plain `Text`, updated directly from
the store.

This is the important separation:

```text
stream event -> ThreadStore -> message Text

scroll gesture -> ChatScrollState -> allow/deny automatic scrollTo(bottom)
```

Neither path changes the behavior or cadence of the other.

## Removed performance machinery

Do not reintroduce these without a measured regression and a focused A/B test:

- `chatTimelineIsScrolling` environment propagation.
- Scroll-triggered stream settling, pausing, or throttling.
- `StreamingText` backlog, drip cadence, glyph fade renderer, and animation
  timers.
- Manual `.equatable()` timeline rows.
- The 358-line generated-model `Equatable` conformance file.
- The global Markdown parse cache.
- The global inline JSON preview cache and its 2,000-character cap.
- DEBUG performance probes interleaved through production code.
- Long-message row splitting/chunk projection.

These mechanisms either did not affect the production plain-text path, added
maintenance risk, complicated correctness, or targeted an edge case the user
does not want prioritized.

## ACP Registry note

The ACP Registry is unrelated to chat performance. Its one cleanup-adjacent
change is local: `ACPRegistryInstalledAgentsSync` observes an
`InstalledAgentSnapshot` containing only `id`, `name`, `description`, and
`version`.

This became necessary when the broad generated-model `Equatable` extensions
were removed, because SwiftUI's `onChange(of:)` requires an equatable value.
The local snapshot is preferable to restoring hundreds of lines of handwritten
model equality and also avoids rebuilding registry rows for irrelevant agent
fields.

## Known behavior and accepted tradeoffs

### Very large messages

SwiftUI `List` virtualizes per row. A 3k/5k/10k-word message remains one row,
so mounting or updating it requires laying out the whole `Text` synchronously.
Occasional hitches at giant messages are expected and accepted for now.

Do not add splitting, caching, TextKit wrappers, or truncation merely to improve
this case. Reconsider only if real normal-sized chats show a measurable problem.

### Top-edge rubber-band jitter

When the user pulls beyond the top while the bottom message grows, SwiftUI's
underlying scroll view reconciles a changing content size while its overscroll
spring has a negative offset. A small jitter can result even though the app is
not issuing `scrollTo` calls.

There is no clean universal SwiftUI no-bounce option. Avoid freezing stream
updates or adding UIKit/AppKit introspection for this minor edge case. A future
experiment could apply `Transaction.scrollContentOffsetAdjustmentBehavior =
.disabled` only to stream-growth transactions, but it must be tested with a
real touch gesture and checked for scroll-position, keyboard, and history-
restore regressions before being kept.

## Verification checklist

After chat changes:

1. Search for `StreamingText`, `chatTimelineIsScrolling`, preview caches, and
   `.equatable()` timeline rows; none should remain in the production path.
2. Build with Xcode MCP and inspect the Issue Navigator for errors/warnings.
3. Run the active test plan with Xcode MCP.
4. In the DEBUG mock chat, start a live stream and verify:
   - text continues updating while dragging or holding the list;
   - the list does not automatically pull toward the bottom during the gesture;
   - bottom-following resumes only when the user returns to the bottom;
   - ordinary scrolling is smooth for normal-sized rows.
5. Treat simulator results as relative. A physical-device gesture remains the
   ground truth for rubber-band behavior and hitches.

Last verification on 2026-08-01 with Xcode 26.5:

- Xcode MCP build succeeded with no reported errors.
- The Issue Navigator contained no errors or warnings.
- The active test plan passed 101 of 101 tests.
- The DEBUG Mock Chat preview rendered successfully.
- The accepted 10k-word plain-`Text` benchmark measured 0.454 seconds for 64
  complete hosting-and-layout operations (1.0% relative standard deviation).

## Measurement rule for future work

Do not optimize from intuition alone. First reproduce a user-visible problem
on the production path, record an Instruments trace or a focused before/after
measurement, and change one variable at a time. Keep an optimization only when
the improvement is perceptible for realistic chat data and outweighs its code
and behavior cost.
