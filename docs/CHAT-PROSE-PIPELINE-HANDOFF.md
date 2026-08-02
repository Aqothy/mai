# Chat prose pipeline — handoff

Continuation notes for the Swift client chat (`clients/swift`). This work is
**implemented, tested, and stashed** — restore it with:

```
git stash list          # find "chat markdown prose pipeline"
git stash pop           # restores all clients/swift WIP (yours + this)
```

The stash contains the entire uncommitted `clients/swift` state, because the
pipeline is entangled with other in-progress chat work (mock sandbox, app
containers, diagnostics tests). Note: HEAD (`462d21a`) does **not** compile on
its own — its ChatView calls `ThreadStore.retryFailedTurn`, which only exists
in uncommitted work. Pop the stash before building. Where this document conflicts with
`CHAT-PERFORMANCE-HANDOFF.md`, this one wins: the "accept hitching on giant
messages" stance is obsolete — giant messages are now the smooth case.

## Goal

Two requirements that a single knob could not satisfy together:

1. Scrolling back through settled history must not hitch, even past
   several-thousand-word messages.
2. Drag selection must span all contiguous prose (paragraphs, headings,
   lists) — no seams every N bytes.

## Why this design

- SwiftUI `List` realizes each row synchronously on the main thread inside
  the scroll frame. MarkdownView renders a whole message as one UITextView,
  so a giant message means a giant single-frame text layout: the hitch.
- Splitting into fixed-size chunks (the earlier approach) bounds the layout
  cost but caps selection at the chunk size: the seam annoyance.
- React Native (t3code mobile) escapes the trade-off because Fabric measures
  text with NSTextStorage/NSLayoutManager on a background thread; the UI
  thread only mounts pre-measured views. The same TextKit APIs are public —
  this pipeline uses them from Swift.

## Architecture

Settled assistant messages over 4 096 UTF-8 bytes flow through four stages:

1. **Segmentation** — `ChatMarkdownChunker.segments(of:)` in
   `ChatMarkdownChunking.swift`. Splits at top-level block boundaries into
   typed segments: contiguous prose accumulates into one **unbounded**
   `.prose` segment; any block whose subtree contains a code fence, table,
   HTML, or image becomes its own `.rich` segment. Concatenating segment
   sources reproduces the message byte-for-byte. Returns nil (→ fallback)
   for sources with math markers or link reference definitions.
   Memoized per message in `ChatMarkdownChunkCache`.
2. **Rendering** — `ChatProseMarkdownRenderer` (cross-platform). Walks
   swift-markdown and emits one NSAttributedString per prose segment.
   Styling mirrors MarkdownView defaults (heading ramp largeTitle…headline,
   8 pt block spacing, 2 pt line spacing, mono inline code with subtle
   background, underlined display-only links, serif indented quotes).
3. **Off-main layout** — `ChatProseTextLayout` builds a full TextKit 1 stack
   (storage → layout manager → container) and runs `ensureLayout` on
   whatever thread creates it. `ChatProseLayoutStore` (main-actor, LRU 96,
   keyed source+width) warms layouts on a detached task whenever the
   timeline width is known or content changes; a row that realizes before
   its warm finishes builds synchronously once instead of flashing blank.
   Dynamic Type changes flush the store (fonts are resolved at build time).
   `widthTracksTextView` is deliberately **false** — width tracking would
   let the adopting text view resize the container against its default
   insets and re-run the whole layout on main.
4. **Display** — `ChatProseMessageText` (iOS `UIViewRepresentable`).
   `sizeThatFits` returns the pre-computed height; the host view creates a
   `UITextView(frame:textContainer:)` that adopts the laid-out container, so
   realization is view creation + drawing only. Selection is native
   UITextView selection across the whole prose run. One container backs one
   text view; a conflicting attach falls back to a private duplicate stack.

Wiring (`ChatView.swift` → `ChatTimeline`): `timelineRows()` maps each
settled oversized assistant message to segment rows — `.messageProse` rows
use the pipeline, `.rich` rows reuse the existing MarkdownView chunk row
(`ChatMessageRow`), which also brings the sanitizer's HTML/image fallbacks.
Warming triggers via `onGeometryChange` (width = list − 32 pt insets) and
`onChange` of timeline count / streaming turn. `MockChatView` mirrors all of
it for the sandbox fixtures ("Giant Essays" is the A/B bed).

## What deliberately did not change

- **Streaming** messages: MarkdownView streaming reader, single row, until
  the turn settles (then segment rows take over; warm kicks at settle).
- **User messages** (bubble stays one piece), **small messages** (≤ 4 096
  bytes, MarkdownView single row), **macOS** (chunked MarkdownView rows;
  `.messageProse` never produced), **math / reference-definition** sources
  (size-chunked MarkdownView rows via `chunks(of:)`).
- Scroll pinning / `ChatScrollState` — untouched.
- Inline tool payload previews in `ChatItemRow` are now capped at 4 000
  chars (`ChatTimelineText.preview`); detail view still shows more.

## Knobs

- `ChatMarkdownChunker.chunkingThreshold` (4 096) — pipeline entry gate.
- `chunks(of:)` fallback: `barrierCutLength` 1 024, `maximumChunkLength`
  8 192 — only affects math/ref-def messages and macOS.
- `ChatProseLayoutStore.maximumEntryCount` (96).

## Verification

- `maiTests`: `ChatMarkdownSegmentTests`, `ChatProseMarkdownRendererTests`,
  `ChatMarkdownChunkingTests` (+ full suite green on macOS destination).
- On-device checklist: fast scroll through giant-essay history; drag-select
  across paragraphs/headings/lists; the stream-settle re-render (style swap
  MarkdownView → prose renderer — watch for visual pop); dark mode; Dynamic
  Type change mid-session; code-heavy thread (fences as separate rows
  between selectable prose); rotation (layout rebuilds at new width).

## Known gaps / polish backlog

- Block quotes: indent + serif + secondary color, no vertical bar.
- Thematic breaks render as a plain rule string.
- Single-`$` inline math heuristics are conservative; money-heavy essays may
  fall back to the chunked path (seams return but nothing breaks).
- Stream-settle style match is close but not pixel-identical.
- Selection cannot cross a code fence/table (t3code behaves the same); a
  "Select Text" sheet showing the whole message in one view would cover the
  rare full-message selection need.
- Streaming a giant reply still lays out one growing MarkdownView row;
  chunking the stable prefix during streaming is the next perf win if wanted.
- macOS could adopt the pipeline with an NSTextView host later.

## Simplification candidates

- The size-based `chunks(of:)` path (barrier/maximum cut logic + its tests)
  now serves only math/ref-def sources and macOS. Accepting single
  MarkdownView rows there would delete ~100 lines; giant math essays would
  hitch again, macOS keeps them either way until it gets the pipeline.
- `ChatProseLayoutStore`'s LRU could be clear-all like the chunk cache.
- `containsPotentialMath`'s single-`$` scan could shrink to
  `source.contains("$")` (more fallbacks, less code).
- Mock sandbox duplicates the segmentation wiring; could share a helper with
  ChatTimeline if the duplication grates.
