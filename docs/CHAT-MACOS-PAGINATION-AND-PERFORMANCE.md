# macOS chat pagination and scrolling performance

Current implementation and investigation record for the Swift client. This
document is authoritative for macOS history pagination and supplements
`chat-scroll-handoff.md` and `CHAT-PROSE-PIPELINE-HANDOFF.md`.

Last verified: 2026-08-14, macOS Debug build launched through Xcode.

## Outcome

macOS history pagination now preserves the reading position during trackpad
dragging and momentum scrolling. The final design is deterministic and
event-driven:

- no polling or retry loop;
- no sleeps, yields, or hard-coded settling duration;
- no forced creation of offscreen List rows;
- no requirement for scrolling to become idle;
- no macOS use of SwiftUI `ScrollPosition` for prepend preservation.

On macOS, code blocks and Markdown tables use a horizontal-only AppKit scroll
container. It keeps horizontal gestures locally and passes vertical-dominant
wheel gestures directly to the enclosing chat List.

The implementation uses a visible native table row as a spatial anchor and
adjusts the backing `NSClipView` offset by exactly the amount that AppKit moves
that anchor while automatic row heights resolve.

Relevant code:

- `clients/swift/mai/Features/Chat/ChatView.swift`
- `clients/swift/mai/Features/Chat/ChatMacScrollPositionPreserver.swift`
- `clients/swift/mai/Features/Chat/ChatMacTableViewIntrospector.swift`
- `clients/swift/mai/Features/Chat/ChatMacHorizontalScrollView.swift`
- `clients/swift/mai/Features/Chat/ChatMacTextLayout.swift`
- `clients/swift/mai/Features/Chat/ChatTextLayout.swift`
- `clients/swift/mai/Features/Chat/ChatScrollState.swift`

## Root cause of the original jump

SwiftUI `List` on macOS is backed by `NSTableView`. When earlier variable-
height rows are inserted, the table initially gives offscreen rows estimated
heights. SwiftUI-hosted row content then resolves the real heights over later
layout passes.

The failed implementation repaired the offset once and discarded its anchor.
It therefore repaired only the estimated insertion, not the later real-height
changes.

One diagnostic capture made the race explicit:

1. Twenty rows were prepended to a 12-row table.
2. The table initially grew from 25,288 to 25,768 points: exactly 480 points,
   or a 24-point estimate per inserted row.
3. A one-shot restore used an anchor at 481 points and set the offset to 344.
4. During the next roughly 70 ms, the anchor moved through 513, 19,759, 6,285,
   and 31,397 points as real heights replaced estimates.
5. The discarded anchor could not compensate those later movements. The
   viewport appeared to jump to the new page's top, and the false near-top
   position could trigger another page immediately.

Calling `NSTableView.view(atColumn:row:makeIfNecessary:)` for every inserted row
and `layoutSubtreeIfNeeded()` did not make SwiftUI-hosted intrinsic heights
synchronous. That attempt also took about 235 ms on the main thread and made
scrolling feel laggy. Do not restore it.

## Pagination flow

The shared pagination path is intentionally bounded and prepared before data
changes:

1. Production initially mounts the newest five user turns.
2. Scroll geometry detects entry into the history-loading zone. macOS uses a
   240-point prefetch distance; iOS uses the top edge.
3. A structured task selects up to ten earlier user turns.
4. Markdown segmentation, Markdown render plans, and native TextKit
   measurements are prepared before insertion. The expensive measurement work
   runs off the main actor.
5. The page is revalidated after preparation: the task must not be cancelled,
   the viewport must still qualify, initial-bottom positioning must be over,
   and the previously oldest section must still be current.
6. The model changes in a transaction with animations disabled.

Position preservation is platform-specific after that point.

### iOS

iOS records the stable ID of the former first rendered row. Once geometry
confirms that content height grew, `ScrollViewProxy.scrollTo` pins that ID to
the top. `onScrollPhaseChange` supplies user-intent and top-edge retry behavior.
No UIKit introspection is used or needed.

### macOS

Before the state mutation, `ChatMacScrollPositionPreserver` captures:

- a substantive visible `NSTableView` row;
- that row's content-space `minY`;
- the `NSClipView` visible origin;
- the row index after the known number of leading rows is inserted.

The mutation disables SwiftUI's automatic content-offset adjustment so there
is only one offset owner. When the expected table rows arrive, the preserver
finds the shifted anchor and applies:

```text
initialOffset = oldVisibleY + newAnchorY - oldAnchorY
```

This keeps the same point in the old row at the same screen coordinate.

Automatic row heights continue changing later. For every table-frame change,
the preserver applies:

```text
layoutDelta = currentAnchorY - previousAnchorY
newOffset = currentOffset + layoutDelta
```

`currentOffset` already contains any intervening trackpad movement, so this
adds only the layout correction and does not replace user input. The trace
showed that AppKit remained in live scrolling until its normal end
notification.

As the user moves through the page, bounds changes rebase preservation to the
currently visible substantive row. This matters because the original row
eventually scrolls offscreen. A later height change below the viewport may
move the original anchor without moving what the user is reading; rebasing
prevents that irrelevant movement from changing the offset.

### Native notification mechanics

The preserver explicitly enables `postsFrameChangedNotifications` on the
`NSTableView` and observes `NSView.frameDidChangeNotification` for that exact
table. The table is the scroll view's document view, so inserting rows or
resolving automatic row heights changes its frame height. AppKit posts the
notification after the frame rectangle changes; it carries no row details and
is used only as a signal to recompute the preserved row's rectangle.

A table-frame change does not automatically imply an offset correction. If
the preserved row's `minY` did not move, the preserver does nothing. This is
what prevents height changes below the viewport from moving the reader.

Separately, the preserver enables bounds notifications on the `NSClipView`.
Changing the clip view's bounds origin is scrolling, so
`NSView.boundsDidChangeNotification` rebases the anchor to the row the user is
currently viewing. Frame notifications track document layout; clip-bounds
notifications track viewport movement.

## Why an anchor is required in addition to a content-height delta

A total content-height delta does not identify where the change occurred.

- A row growing above the viewport must move the offset by the same amount.
- A row growing below the viewport must not move the offset.
- A visible row changing internally may need different treatment depending on
  the point being preserved.

The successful trace included a table-height reduction from 72,573 to 68,308
points with no anchor movement. The preserver correctly made no offset change.
A total-height algorithm would have incorrectly moved the viewport by -4,265
points.

The visible row is therefore not just an implementation convenience. It is
the reference that separates layout changes affecting the reading position
from changes elsewhere in the document.

## Why the one-point history marker is not used as the anchor

The transparent history marker is a one-point sentinel used to give the top
of the List a stable structural row while more history exists. It contains no
user-visible content and can disappear when the final page replaces it with
the optional plan row.

Anchoring it would preserve the pagination boundary rather than the text the
user is reading. It also has an unusually small and structurally conditional
height. The preserver therefore chooses the first visible row taller than
`ChatTimelineMetrics.historyMarkerHeight`, with the first visible row as a
fallback. The marker view and preserver share that constant, so changing the
marker height cannot silently desynchronize the anchor rule.

## Bottom following is separate from pagination

iOS intentionally has two related values with different jobs:

- `isViewportNearBottom` is the latest raw geometry observation. The iOS
  prepend path uses it to decide whether preserving a visible row is necessary.
- `ChatScrollState.shouldFollowBottom` is behavioral intent, while
  `ChatScrollState.isNearBottom` is stabilized UI state for the jump button.
  They use scroll activity and hysteresis so a transient loss of the end zone
  while content grows does not flash the button or incorrectly cancel
  following.

Collapsing these into one Boolean would mix instantaneous layout with user
intent. The old local name `isTimelineNearBottom` was therefore changed to
`isViewportNearBottom` to make the distinction explicit. The raw local value
is declared and updated only on iOS; macOS bottom following does not depend on
it.

macOS bottom following works through `ChatScrollState`:

1. Geometry derives `newGeometry.isNearBottom` using the 24-point end zone.
2. `scrollState.noteEndVisibility` updates shared pinned intent.
3. Moving upward calls `noteScrollAwayFromEnd`, which disables following.
4. When content grows or the viewport shrinks and `shouldFollowBottom` is true,
   `ScrollViewProxy` scrolls to the bottom marker.
5. The explicit jump button increments `bottomScrollRequest`; the modifier
   observes it and scrolls directly to the bottom on macOS.

Pagination preservation and bottom following must remain separate. The first
stabilizes content inserted above the reader; the second follows content at
the end only when the user has retained that intent.

## Why scoped AppKit introspection is used

The current solution retains SwiftUI `List` and uses the project-owned
`ChatMacTableViewIntrospector` only on macOS to obtain its backing
`NSTableView`. SwiftUI Introspect is no longer imported by the chat source.

The helper borrows only the useful design principle from SwiftUI Introspect:
place an invisible, non-interactive marker inside the target view hierarchy
and resolve the native receiver relative to that marker. The local version is
small because it supports exactly one target. It walks outward from the chat
List's background marker and accepts only an `NSTableView` whose visible clip
view contains the marker's center. That containment check prevents the thread
sidebar's table from being selected. The result is weakly cached and the
callback is idempotent.

Public SwiftUI geometry provides aggregate scroll information but does not
provide the native row rectangles, delayed automatic-height notifications, or
direct `NSClipView` offset correction required here. A pure SwiftUI ID position
was tested and still lost position while macOS List revised estimated heights.

For the current List architecture, access to the native table is necessary.
The ways to remove it are to replace the macOS timeline with an owned AppKit
table or for a future SwiftUI implementation to preserve variable-height
prepends correctly. Do not add introspection to iOS while its existing
ID-anchor implementation is working.

Unlike a general introspection package, this helper has no per-OS-version
opt-in list. Its intentionally narrow contract must be rechecked when changing
the List implementation or raising the macOS deployment target.

The SwiftUI Introspect import, product reference, and package dependency have
all been removed; the scoped helper has no third-party runtime dependency.

## Nested horizontal scrolling

On macOS, a nested `NSScrollView` receives wheel events under the pointer even
when it has only horizontal content. Unlike UIKit's nested-scroll arbitration,
AppKit does not automatically hand an unused vertical axis to the enclosing
scroll view.

Code blocks and Markdown tables therefore use `ChatMacHorizontalScrollView`, a
local horizontal-only `NSScrollView`. Horizontal-dominant gestures use the
normal AppKit scrolling implementation. Vertical-dominant gestures are passed
to the nearest enclosing scroll view, which is the chat List. Keeping this
behavior in the nested control avoids a window-wide event monitor and prevents
scroll events elsewhere in the window, including the sidebar, from being
captured.

## Correctness evidence

The successful manual run covered small and very large pages while trackpad
momentum remained active:

- every observed anchor movement received an equal offset change;
- initial restores took about 0.18-0.24 ms instead of the former 235 ms forced
  realization;
- 20-, 50-, and 75-row native prepends were preserved;
- subsequent pages occurred after actual traversal of the inserted content,
  rather than from an immediate false near-top transition;
- every gesture ended with no pending restoration;
- there were no restore waits, cancelled loads, rejected preparations, or
  overlapping-load warnings.

This verifies the reproduced behavior, but the AppKit adapter currently has no
automated test. A future cleanup should extract the offset formula and leading-
row accounting into pure functions with unit tests. Native notification order
and momentum still require interactive macOS verification.

## Maintainability and deliberate coupling

The core is event-driven and has no timing hack. Some coupling remains because
SwiftUI does not expose the necessary native concepts:

- The preserver tracks `NSTableView` row indices rather than SwiftUI IDs.
- `ChatView` calculates the leading native-row change from rendered page rows,
  history-marker removal, and optional plan-row insertion. If another leading
  List row is added, this calculation must be updated.
- The substantive-row test is intentionally tied to the shared history-marker
  height.
- The preserver remains armed after a prepend and rebases during later
  scrolling because offscreen rows can resolve on later gestures. This means
  it performs one `rows(in:)` lookup on relevant clip-bounds changes after
  pagination. Do not time it out: the trace showed useful corrections on later
  gestures. If profiling finds this lookup material, end preservation only
  from a structural condition that proves every prepended row has resolved.

The preserved anchor is replaced on each new prepend and cleared when a new
backing table is attached. It is not a cache of scroll positions and is not
used to restore navigation state.

## Production cleanup

The temporary pagination logger, numeric formatting, live-scroll state, and
live-scroll notification observers were removed after verification. The only
remaining native observers are functional: table-frame changes trigger layout
compensation and clip-bounds changes rebase the visible anchor.

## Rendering optimizations shared with iOS

Both platforms currently share:

- five-turn initial mounting and ten-turn history selection;
- stable List row identities and native List virtualization;
- Markdown segmentation and per-thread segment caching;
- process-wide settled Markdown render-plan caching;
- off-main TextKit measurement warmup;
- a shared maximum of 256 eager text-layout requests per batch;
- long-message prose/rich-block segmentation;
- preparation of the next page before it enters the List.

The value 256 limits one eager batch, not the total number of retained layout
entries. Each thread's layout store is reset when its inactive session is
evicted.

## Why macOS can still feel less smooth

Correct pagination removes the position jump, but it does not eliminate the
underlying layout work.

Observed contributors:

1. **A turn-count page can become many native rows.** One captured page had 12
   logical timeline rows but 76 rendered rows, producing a 75-row net prepend.
   Segmentation improves virtualization of giant responses, but turn count is
   not a bound on native insertion work.
2. **`NSTableView` resolves automatic heights lazily.** The preserver hides
   their position error, but AppKit and SwiftUI still perform the measurement,
   hosting, and frame-update work.
3. **Visible AppKit text needs its own display graph.** Background measurement
   caches the attributed string and exact height. When a prose row becomes
   visible, its `NSTextView` still installs the attributed string and calls
   `ensureLayout` on the display layout manager on the main actor.
4. **macOS windows have many possible widths.** Layout stores use an exact
   `(row ID, CGFloat width)` key. Resizing can create several cached layouts for
   the same text, and the per-thread store currently has no entry-count or byte
   eviction policy.
5. **The debugger has overhead.** Pagination logging is gone, but compare
   Release-to-Release before attributing remaining roughness to production.

## NSTextView reuse

iOS has an application-owned `UITextView` pool. It moves an entire detached
text view—including its privately owned TextKit display graph—between host
views. A view enters the pool only after it has been removed from its old host;
an exact `(row ID, width, layout object)` match can keep its installed content,
and a non-exact match is cleared before new content is installed.

macOS deliberately relies on `NSTableView`/SwiftUI cell and representable-host
recycling instead of adding a second pool. Each `ChatMacSelectableTextHostView`
owns one `NSTextView` and one display TextKit graph for its lifetime. AppKit is
already reusing that host as List rows are realized and retired.

Native text-view reuse can reduce allocation and configuration. Exact-content
reuse can also avoid reinstalling an attributed string. It does not remove the
need to lay out a display TextKit graph when content or width changes, and it
can increase retained memory.

Correct AppKit reuse is possible, but these invariants are mandatory:

- each visible `NSTextView` owns a distinct text storage, layout manager, and
  text container;
- a TextKit graph must never be attached to two visible views;
- a view cannot enter the idle pool until dismantling proves it is no longer
  visible;
- reused views must reset delegate, selection, container width, decorations,
  and attributed content consistently;
- the pool must be bounded and cleared with the owning thread/session.

The previous explicit macOS pool added a second reuse lifecycle on top of the
table's lifecycle. Stale AppKit TextKit layout state could then survive a row
ownership change, and non-contiguous layout left the final laid-out glyph far
above the measured row height, producing large empty tails. Keeping each
display graph with its host and disabling non-contiguous layout fixed that
symptom. A correct macOS pool is possible, but it is not currently justified:
first use Instruments to show that `NSTextView` construction is material, then
test a bounded pool against empty tails, selection preservation, fast
traversal, and memory.

## Low-risk performance plan

No speculative performance change was made during the pagination fix. Use this
order for follow-up work:

1. Compare macOS and iOS Release builds with equivalent content. Debugger
   overhead is not representative of production.
2. Record a macOS Instruments Time Profiler and Core Animation trace while
   scrolling a known long thread. Measure `ChatMacSelectableTextHostView`
   presentation, TextKit layout, rich Markdown mounting, and SwiftUI update
   work separately.
3. If prepend size dominates, add a rendered-row or estimated-layout-cost
   budget to history pages. Preserve whole-turn semantics where possible; a
   single giant turn may still exceed the budget.
4. If window-resize churn or memory dominates, add a measured per-thread
   layout-cache policy. Do not round widths unless display and measurement use
   the exact same effective width, or row heights can diverge.
5. If native view construction dominates, prototype a small bounded
   exact-content `NSTextView` pool with the ownership rules above.
6. If clip-bounds rebasing itself appears in profiles, scope it using a proven
   structural completion condition, not a timeout.

Avoid removing `ensureLayout`, forcing offscreen views, lowering page sizes
arbitrarily, or adding a cache/reuse layer without a focused before/after
measurement.

## Constants and policy knobs

These named constants are intentional policy values, not settling hacks:

- `nearBottomDistance = 24`: bottom-follow end zone;
- macOS `historyLoadDistance = 240`: start preparing before the top boundary;
- `initialTurnCount = 5`: cold-open history size;
- `earlierTurnCount = 10`: history page selection size;
- `ChatTextLayoutWarmup.maximumRequestCount = 256`: eager work per batch.

They should be tuned from traces and realistic threads.

## Telegram comparison

No Telegram source was copied into this implementation. The final fix was
derived from the app's AppKit trace. It converges on the same general class of
solution used by mature custom chat lists: identify a stable visible item and
compensate the viewport by the item's layout delta. Telegram owns more of its
table and transaction stack; this client keeps SwiftUI List and isolates the
small native workaround behind project-owned AppKit adapters. The table finder
also follows the marker/receiver scoping pattern seen in SwiftUI Introspect,
but is purpose-built rather than a copy of its general machinery.

## Manual verification checklist

Test on macOS with a trackpad and representative long chats:

1. Slowly cross the history threshold and continue dragging.
2. Flick upward and let momentum cross the threshold.
3. Keep continuously scrolling through multiple pages.
4. Stop close to the threshold, then begin another gesture.
5. Traverse a page containing a giant segmented assistant response.
6. Scroll back down after all history is loaded.
7. Switch threads and confirm the new chat opens at the bottom.
8. Expand content above and below the viewport.
9. Resize the window and observe both position and frame pacing.
10. Verify the explicit jump-to-bottom button during momentum.
11. Start a vertical trackpad gesture over a horizontally overflowing code
    block and Markdown table; the chat must move and momentum must continue.
12. Start a horizontal gesture over the same content; the nested content must
    still pan horizontally without moving the chat vertically.

Build verification is necessary but cannot validate native scroll physics.
