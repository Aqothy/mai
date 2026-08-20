# Handoff: Chat scrolling behavior for the mai Swift client

This document describes the current pure-SwiftUI chat scrolling baseline,
why it is structured this way, the approaches that failed on device, and the
remaining anchored-send work. The ordinary bottom-follow behavior is now in a
good state in the mock. **Read the current implementation and failed-attempts
sections before changing the scroll stack.**

## Project context

- Repo: `/Users/aqothy/Code/Personal/maiD`, Swift client at `clients/swift/`.
- The work happens in `clients/swift/mai/Features/Chat/MockChatView.swift`, a
  DEBUG-only test screen for chat scrolling (reachable on device via the
  ladybug toolbar button, or via its two previews). Both the mock and
  production `ChatView.swift` now use `List`. The mock remains an independent
  behavioral reference, while production adapts the same behavior to backend
  update sequences.
- Related files: `PromptComposer.swift` (composer UI), `ChatView.swift`
  (hosts one shared composer in `safeAreaInset(edge: .bottom)` across
  draft/chat modes), `DraftPromptView.swift` (empty state).
- **Follow `clients/swift/AGENTS.md`.** Highlights: iOS 18.6+ target (all the
  iOS 18 scroll APIs are available), `@Observable` classes for shared state,
  new `View` structs instead of computed view properties, no UIKit unless
  there is no SwiftUI alternative (justify in a comment if forced), never
  1-parameter `onChange`, `Button("Title", systemImage:)` for icon buttons.
- Do NOT edit `mai.xcodeproj` or anything in `Generated/`.

## Behavioral contract (all must hold simultaneously)

1. **Open at bottom.** Opening a conversation shows the latest message,
   including when content loads async (a `ProgressView` branch is replaced by
   the timeline — see `simulateLoading()` in the mock).
2. **Short conversations start at the top** and grow downward, like ChatGPT's
   first messages. Bottom behaviors kick in once content overflows.
3. **Near-bottom pinning.** When the user is at or near the bottom (within a
   24pt buffer), new messages and streaming growth of the last message keep
   the view pinned to the bottom. The installed Codex desktop app also uses
   a 24 CSS-pixel threshold.
4. **Position preservation.** When scrolled up beyond the buffer, content
   changes must NOT move the reading position, and a scroll-to-bottom button
   appears.
5. **Scroll-to-bottom button.** Floats above the composer as an overlay
   (must not change the safe-area/inset height when appearing — that caused
   a visible snap). Animated appear/disappear. Tapping it must land at the
   bottom **even mid-deceleration** (interrupts an in-flight scroll).
6. **Keyboard "lift when at end".** Opening the keyboard while near the
   bottom lifts the conversation so it sits above the composer/keyboard and
   pinning continues to work afterward. Opening it while scrolled up leaves
   the content where it is (keyboard + composer overlay it). Composer height
   growth (multiline text) must behave the same way. This is the policy
   LegendList calls `keyboardLiftBehavior="whenAtEnd"` (see reference below).
7. **Anchored end space on send (remaining work).**
   When the user sends a message, the sent message scrolls to near the TOP of
   the viewport (offset ~16pt below the top), with blank space below it where
   the streamed reply fills in. The blank end space is synthetic (spacer or
   inset) and goes away naturally as the reply grows past it / when the turn
   completes. Reference semantics: `resolveChatListAnchoredEndSpace` in
   `~/Code/Personal/t3code/packages/shared/src/chatList.ts` and its usage in
   `~/Code/Personal/t3code/apps/mobile/src/features/threads/ThreadFeed.tsx`
   (props `anchoredEndSpace`, `anchorMessageId`).
8. **Composer placement.** The composer stays in
   `safeAreaInset(edge: .bottom)`. The keyboard replaces the home-indicator
   bottom safe area with a much larger keyboard safe area, reducing usable
   timeline height. `scrollDismissesKeyboard(.interactively)` remains on the
   timeline.
9. **Performance.** Near-bottom state flips must not re-evaluate the timeline
   body (keep the existing `@Observable ChatScrollState` isolation:
   timeline and screen bodies never _read_ `isNearBottom`; only the small
   button view does). The button must not cause inset relayouts.

## Current implementation

`MockChatView.swift` remains the independent SwiftUI reference. Both timelines
use `List`; the production-specific behavior is:

- `List` provides native row virtualization and reuse for the rich production
  timeline, avoiding the stale `LazyVStack` layout-offset failure.
- `defaultScrollAnchor(.bottom, for: .initialOffset)` opens every newly mounted
  conversation at the latest content.
- `ScrollViewReader` performs explicit bottom jumps to the final marker.
- `onScrollGeometryChange` derives a 24pt near-bottom state from the List's
  visible rectangle and handles composer/keyboard viewport shrink.
- A 24pt clear final row provides breathing room and a stable bottom target.
- `onScrollPhaseChange` immediately suspends following when user-driven
  tracking, interaction, or deceleration begins. This prevents streamed
  updates from fighting a drag. There is currently no keyboard-notification or
  idle-triggered bottom correction, so ordinary scrolling and keyboard closure
  do not force an explicit snap.
- The mock and production state machines preserve pinned intent across idle
  keyboard and safe-area layout changes.
- Every mock message mutation captures whether the timeline was pinned before
  the mutation. If so, it issues an unanimated bottom request after the
  mutation. Production cannot wrap mutations owned by `ThreadStore`, so its
  per-thread sequence is the equivalent content-change signal. Initial
  positioning belongs exclusively to `defaultScrollAnchor`; `onChange` does
  not run for the initial value. Later snapshot or stream changes directly
  issue a non-animated `ScrollViewProxy.scrollTo` while following is active.
  There is no async task, sleep, yield, or second observed request mutation in
  that hot path. `BottomScrollRequest` remains for explicit actions outside
  the timeline proxy, such as tapping the floating button.
- Production has no per-thread UI-state cache. A thread switch gives the List a
  fresh structural identity and opens the new List at the bottom, matching the
  mock and t3code.
- A daemon-restored thread snapshot carries
  `historyRestorePending: true` while its provider-owned history is rebuilt.
  Production keeps applying those ordered events to `ThreadSession` behind
  `Restoring Chat…` and does not mount the List until
  `thread.history-replay-completed`. The flag is intentionally content-
  independent: another client can subscribe after some history arrives and
  still receive a nonempty partial snapshot. Terminal error/stopped status
  exits the loader into recovery UI. The completed timeline therefore receives
  the initial bottom anchor once; do not remove this gate, infer readiness from
  emptiness/session/latest-turn, or render partial restored history.
- The scroll-to-bottom button is a root overlay positioned using the reduced
  bottom safe area, not part of the composer inset's layout. It uses
  interactive Liquid Glass on iOS/macOS 26 and regular material on older
  deployment targets.
- On iOS/macOS 26 the composer uses `safeAreaBar(edge: .bottom)` and the
  timeline uses the built-in soft bottom scroll-edge effect. Older systems
  retain the `safeAreaInset` layout without a custom edge-effect fallback.
  Composer-height changes explicitly reassert the bottom only while following
  is active, so multiline growth lifts a pinned chat but overlays the current
  reading position when the user is scrolled up. No UIKit scroll wrapper
  remains in the file.

The current unit tests cover pinned-state transitions, bottom requests, reset
behavior, layout changes, and immediate cancellation when a user scroll begins.
These tests validate the state machine, not real keyboard and scroll physics;
those still require device testing.

## History pagination (production `ChatTimeline`)

This section previously described an abandoned backing-view walker, timed
compensation window, wheel monitor, and shared UIKit/AppKit compensator. None
of those types or lifecycles are current.

The authoritative current design, failure trace, platform split, AppKit anchor
math, scoped AppKit introspection rationale, performance findings, and verification
checklist are in `CHAT-MACOS-PAGINATION-AND-PERFORMANCE.md`.

In brief: page preparation is shared, iOS preserves a stable SwiftUI row ID,
and macOS introspects the List's `NSTableView` and keeps a visible row stable by
adding each real row-layout delta to the current `NSClipView` offset. The macOS
path is event-driven and has no polling, sleep, forced offscreen realization,
or timeout.

## Virtualization and current performance

Virtualized content means the scroll view represents a long document but only
mounts and lays out the rows near the visible viewport (plus a small overscan
region). A custom virtualizer records row heights and uses top/bottom spacer
geometry to represent the unmounted rows.

Both timelines use `List` for native virtualization and row reuse. Production
characteristics are:

- There is no application-owned row-height cache or overscan policy.
- SwiftUI decides when offscreen List rows are created and reused.
- Each streamed mutation invalidates the message array and the timeline
  description; SwiftUI diffs stable message IDs and updates the changed row.
- While pinned, SwiftUI coalesces model invalidations into view updates; each
  observed sequence change directly reasserts the bottom without a second
  request-state cascade.

For the real rich timeline, first keep stable IDs and separate row views, and
coalesce provider deltas to at most the display cadence. Profile realistic
long threads containing Markdown, images, and tool results before replacing
`List`. A custom virtualizer or UIKit-backed list is only justified by
measured frame, memory, or position-preservation problems.

The installed Codex desktop app uses a custom DOM virtualizer. Its packaged
scroll controller tracks `distanceFromBottomPx`, considers `<= 24` pinned,
measures changed turn heights, and compensates the scroll offset when those
heights change. The purpose of compensation is to keep the exact text a user
is reading at the same screen coordinate when streaming output, images, tool
results, or viewport changes alter layout above or below it. When pinned, the
same system instead preserves zero distance from the bottom.

## History of attempts — DO NOT repeat these blind

Several earlier versions compiled successfully but were broken on device.
Chronology:

1. `ScrollView` + `LazyVStack` + `defaultScrollAnchor(.bottom, for:
.initialOffset)` + `.defaultScrollAnchor(.bottom, for: .sizeChanges)`:
   initial-bottom and exact-bottom pinning **worked** (verified: messages
   appended by a timer keep the list pinned when at the exact bottom, and
   position is preserved when scrolled up). Short-conversation top alignment
   works (alignment role left at default).
2. 1pt sentinel + `onScrollVisibilityChange` in the `LazyVStack`: near-bottom
   detection **worked** (button showed/hid correctly on device).
3. **Keyboard problem in older versions:** opening the keyboard at the bottom
   inconsistently lifted the content and caused the at-bottom intent to be
   lost. The current state machine no longer treats an idle end-marker
   visibility loss as a user scroll, so safe-area changes do not revoke
   pinned intent.
4. `.scrollBounceBehavior(.basedOnSize)` disables the drag gesture when
   content fits → breaks `scrollDismissesKeyboard`. Don't use it on the
   timeline.
5. `ScrollPosition.scrollTo(edge: .bottom)` (the `scrollPosition($binding)`
   API) **does** interrupt an in-flight deceleration — good for the button.
   `ScrollViewReader.scrollTo` does **not** reliably interrupt deceleration.
   Note: the `scrollPosition` binding coexisted fine with the anchors during
   the timer-feed test (an earlier theory that it poisons anchor state was
   wrong).
6. `onScrollGeometryChange` distance-from-bottom math
   (`contentSize.height + contentInsets.bottom - contentOffset.y -
containerSize.height < threshold`) misfired (reported "not at bottom"
   while at the bottom). The suspected cause is wrong assumptions about
   whether `containerSize`/`contentOffset` include safe-area insets.
   **If you use this API, first add temporary on-device logging of all
   ScrollGeometry fields (offset, contentSize, containerSize, contentInsets)
   at rest-top, rest-bottom, and keyboard-open, and derive the predicate from
   the logged numbers.** Do not trust a formula from memory — that mistake
   was already made once.
7. A "buffered sentinel" built as `frame(height: 120).padding(.top, -120)`
   collapsed to zero height and never reported visible. A nonzero layout
   element works; the current version intentionally uses a 24pt clear element
   because the final message should have that breathing room.
8. **Earlier `List` attempt failures (historical):**
   - `List` ignores `defaultScrollAnchor` entirely (initial position and
     pinning).
   - `onScrollVisibilityChange` on a sentinel row (including inside a row's
     `background`) never fires — state stays at its initial value.
   - `onAppear`/`onDisappear` on a sentinel row also did not track
     scrolling on device (stuck `true`; List apparently keeps rows alive
     across a large window or indefinitely).
   - The `onGeometryChange { $0.safeAreaInsets.bottom }` watcher attached to
     the List did not produce a keyboard re-pin on device (either the inset
     change isn't visible there or the `ScrollViewReader.scrollTo` inside the
     callback failed silently).
9. The scroll-to-bottom button must NOT participate in the
   `safeAreaInset` stack's layout: its appearance changed the inset height and
   caused a snap plus full scroll relayouts. An offset overlay on the composer
   also had unreliable hit testing outside the composer's bounds. The working
   button is a root overlay positioned above the reduced bottom safe area.
10. Interactive keyboard dismissal can leave `LazyVStack` at a stale offset,
    showing temporary blank space below its content until the next gesture
    forces another bounds correction. Similar SwiftUI reports remain open for
    [`safeAreaInset` plus interactive dismissal](https://github.com/feedback-assistant/reports/issues/437)
    and for [variable-height `LazyVStack` chat rows](https://stackoverflow.com/questions/79806750/swiftui-lazyvstack-stays-stuck-on-keyboard-dismiss-ios-17).
    Do not assume the lazy stack is the only cause: keyboard safe-area changes,
    scroll bounds, and lazy layout interact during the same transition. The
    Eager `VStack` removed the bug but performed poorly, and the attempted UIKit
    collection-view replacement did not work. The keyboard-notification
    fallback was removed with the lazy-stack implementation. See
    `docs/chat-keyboard-scroll-handoff.md` for the historical details.
11. The earlier lazy-stack cache rebound scroll state to recreated lazy
    content. A later numeric List-offset cache also produced unreliable
    restoration and repeated per-frame update diagnostics. Both caches were
    removed. Every selected conversation now mounts at the bottom.

## Remaining anchored-send design

Anchored end space is not implemented. A scroll view cannot place its final
row at the viewport top unless sufficient scrollable extent exists below that
row; a `.top` request alone is clamped to the maximum content offset. The
preferred first implementation is therefore a viewport-height latest-turn
container rather than a separately measured spacer that shrinks on every
streamed update. It preserves the same UI while letting layout consume the
reserved extent naturally:

1. Before send, capture `isNearBottom`. Only enter anchored mode if it was
   true.
2. Group the newest user message and its agent response into a latest-turn
   container and store the sent message ID.
3. Measure the usable viewport with SwiftUI `onGeometryChange`. Give the
   latest-turn container a top-aligned minimum height based on that viewport,
   accounting for the desired ~16pt top clearance and the 24pt end element.
4. Make the user row a scroll target and request `.top` for its ID after the
   insertion is laid out.
5. While anchored mode is active, suppress ordinary bottom-follow requests
   that would conflict with the anchor. Keep normal near-bottom state separate
   from this temporary mode.
6. As the reply grows, its intrinsic height consumes the turn's minimum height
   automatically. Once it exceeds that minimum, ordinary bottom-following can
   take over; no per-token spacer measurement or reduction is required.
7. Cancel anchored mode immediately on user scroll. A scroll-to-bottom action
   also cancels it and returns to normal bottom-follow semantics.
8. If a short reply completes before filling the minimum height, matching the
   original contract still requires a handoff: collapse the residual extent
   with offset compensation so visible content does not jump. Keeping the
   minimum height until the next send is simpler, but leaves persistent blank
   space and is therefore a deliberate UX change rather than an equivalent
   implementation.

This is a moderate addition rather than a rewrite. The minimum-height turn
removes most spacer lifecycle measurement, but completion, cancellation, and
keyboard-size changes still need device testing. Keep anchored send as a
separate mode in the scroll state instead of folding special cases into
`isNearBottom`.

## Rules for future changes

- Keep production on `List` unless a tested replacement preserves its
  virtualization, keyboard, and bottom-follow behavior.
- Keep role-scoped anchors; do not set the alignment role to bottom.
- Keep `ScrollViewReader` plus `BottomScrollRequest` for explicit List jumps.
- Keep automatic stream following direct on the sequence change; do not add a
  task yield or arbitrary frame sleep.
- Do not add per-thread scroll-position, List, row-view, or layout caches.
- Keep the 24pt clear end element unless on-device behavior justifies a change.
- Do not let user-driven streaming updates issue bottom requests after a
  scroll phase begins.
- Do not put conditional button layout inside the composer safe-area inset.
- Do not add UIKit merely to obtain cell reuse; profile the rich timeline
  first.

## Verification checklist (must be done interactively — static builds and

previews are NOT sufficient; every failure above compiled fine)

On an iOS simulator or device, in the mock (ladybug button):

- [ ] Long conversation opens at the latest message; short one sits at top.
- [ ] Reset → Simulate Loading: spinner → conversation appears at bottom.
- [ ] Start incoming feed; at bottom → stays pinned; scrolled up → position
      does not move and button appears.
- [ ] Button hidden at bottom, appears past the buffer, tap mid-deceleration
      lands at bottom, no layout snap when it appears/disappears.
- [ ] Keyboard at bottom → chat lifts above composer AND autoscroll still
      works afterward without manual re-scrolling. Keyboard while scrolled
      up → content doesn't move. Multi-line typing behaves the same.
- [ ] Interactive drag-down keyboard dismissal works.
- [ ] Send → sent message anchors near the top with blank space below;
      the (mock) reply fills in below it; no jumps when the space collapses.
- [ ] No scroll indicator until content overflows; the final content remains
      visible above the composer in both keyboard states.
- [ ] The Xcode build and active test plan pass.

## Reference implementation

`~/Code/Personal/t3code` (React Native + LegendList) implements the target UX;
read `apps/mobile/src/features/threads/ThreadFeed.tsx` for the policy set:
`initialScrollAtEnd`, `maintainScrollAtEnd` (+ threshold = the buffer),
`maintainVisibleContentPosition`, `keyboardLiftBehavior="whenAtEnd"`,
`anchoredEndSpace` (+ `packages/shared/src/chatList.ts`). Match those
behaviors, not its implementation details.
