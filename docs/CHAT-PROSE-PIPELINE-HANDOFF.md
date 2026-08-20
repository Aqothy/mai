# Chat prose pipeline — handoff

Continuation notes for the current Swift client chat implementation
(`clients/swift`). Where this document conflicts with
`CHAT-PERFORMANCE-HANDOFF.md`, this one wins: the earlier "accept hitching on
giant messages" stance is obsolete.

> macOS now has its own premeasured AppKit prose path. For its current
> `NSTextView` ownership model, cache behavior, pagination interaction, and
> performance backlog, see `CHAT-MACOS-PAGINATION-AND-PERFORMANCE.md`.

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

Settled assistant messages and user prompts over 2 048 UTF-8 bytes flow
through four stages:

1. **Planning and segmentation** — `ChatMessageTextPlanner` and
   `ChatMarkdownSegmenter` in `ChatMarkdownSegmentation.swift`. The centralized
   planner is shared by the production and mock timelines. Assistant Markdown
   splits at top-level block boundaries into
   typed segments: contiguous prose accumulates into one **unbounded**
   `.prose` segment; any block whose subtree contains a code fence, table,
   HTML, or image becomes its own `.rich` segment. Concatenating segment
   sources reproduces the message byte-for-byte. Returns nil (→ fallback)
   for sources with math markers or link reference definitions.
   Memoized per message in `ChatMarkdownSegmentCache`. Long user prompts skip
   Markdown entirely and select the literal `.plainText` path.
2. **Rendering** — `ChatProseMarkdownRenderer` (iOS). Walks
   swift-markdown and emits one NSAttributedString per prose segment.
   Styling mirrors MarkdownView defaults (heading ramp largeTitle…headline,
   8 pt block spacing, 2 pt line spacing, mono inline code with subtle
   background, underlined display-only links, serif indented quotes).
3. **Off-main layout** — `ChatTextLayout` builds a full TextKit 1 stack
   (storage → layout manager → container) and runs `ensureLayout` on
   whatever thread creates it. `ChatTextLayoutStore` (main-actor, per timeline,
   bounded to 256 entries and keyed by message segment ID + exact text width)
   warms layouts on a detached task whenever the
   timeline width is known or content changes; a row that realizes before
   its warm finishes builds synchronously once instead of flashing blank.
   Dynamic Type changes flush the store (fonts are resolved at build time).
   `widthTracksTextView` is deliberately **false** — width tracking would
   let the adopting text view resize the container against its default
   insets and re-run the whole layout on main.
4. **Display** — `ChatSelectableText` (iOS `UIViewRepresentable`).
   `sizeThatFits` returns the pre-computed height; the host view creates a
   `UITextView(frame:textContainer:)` that adopts the laid-out container, so
   realization is view creation + drawing only. Selection is native
   UITextView selection across the whole prose run. One container backs one
   text view; a conflicting attach falls back to a private duplicate stack.

Wiring (`ChatView.swift` → `ChatTimeline`): settled oversized assistant
messages become `.prose` and `.richMarkdown` rows; long user prompts become
one `.plainText` row. Rich rows reuse `ChatMarkdownMessageView`, including its
HTML/image sanitizer. Warming triggers via `onGeometryChange` and timeline,
streaming-turn, fold, and Dynamic Type changes. The warm width is derived from
the same centralized row and bubble insets as display, so user bubbles do not
miss the cache. `MockChatView` uses the same planner and layout store for the
sandbox fixtures ("Giant Essays" is the manual stress bed).

## What deliberately did not change

- **Streaming assistant messages** stay on MarkdownView's incremental reader
  until settlement. **Small assistant messages** (≤ 2 048 bytes) use the
  existing renderer. **All user messages are literal text**: short prompts use
  SwiftUI `Text(verbatim:)`; long prompts use the pre-laid-out native path.
- macOS uses `ChatMacTextLayout` and `ChatMacSelectableText` for optimized
  prose while retaining the existing whole-document renderer for unsupported
  segmentation cases. Math and reference-definition sources remain whole to
  preserve document-wide semantics.
- Scroll pinning / `ChatScrollState` — untouched.
- Inline tool payload previews in `ChatItemRow` are now capped at 4 000
  chars (`ChatTimelineText.preview`); detail view still shows more.

## Knobs

- `ChatMarkdownSegmenter.optimizationThreshold` (2 048) — measured pipeline
  entry gate.
- `ChatTextLayoutStore.maximumEntryCount` (256) — per-timeline safety bound.

## Verification

- `maiTests`: `ChatMarkdownTests` covers planning, segmentation, literal user
  text, selection, and render-path activation. `ChatMarkdownPerformanceTests`
  contains 4 KB existing-renderer, native cold-layout, user-layout, and cached
  row-attachment benchmarks.
- On-device checklist: fast scroll through giant-essay history; drag-select
  across paragraphs/headings/lists; the stream-settle re-render (style swap
  MarkdownView → prose renderer — watch for visual pop); dark mode; Dynamic
  Type change mid-session; code-heavy thread (fences as separate rows
  between selectable prose); rotation (layout rebuilds at new width).

## Known gaps / polish backlog

- Block quotes: indent + serif + secondary color, no vertical bar.
- Thematic breaks render as a plain rule string.
- Single-`$` inline math heuristics are conservative; money-heavy essays may
  stay on the existing single-row renderer (correct output, potentially less
  smooth initial layout).
- Stream-settle style match is close but not pixel-identical.
- Selection cannot cross a code fence/table (t3code behaves the same); a
  "Select Text" sheet showing the whole message in one view would cover the
  rare full-message selection need.
- Streaming a giant reply still lays out one growing MarkdownView row;
  chunking the stable prefix during streaming is the next perf win if wanted.
- macOS could adopt the pipeline with an NSTextView host later.
