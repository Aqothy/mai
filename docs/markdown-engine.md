# Markdown engine: architecture, upstream parity, and extraction plan

The native Swift Markdown engine lives under `clients/swift/mai/Features/Transcript/Shared/Markdown/`.
It replaces `swift-markdown` / `cmark-gfm` in the new transcript with a zero-dependency, two-pass
flat-record UTF-8 + `SIMD16<UInt8>` parser and incremental streaming layer modeled on
`@pierre/words` (Apache 2.0).

This document holds what the code alone cannot: the upstream mapping for syncing future
optimizations, intentional spec/policy differences, future feature extension points, and the
checklist for extracting the engine into a standalone Swift package later.

## 1. Pipeline and invariants

```text
UTF-8 bytes (String.withUTF8 — zero copy)
  │
  ├─ Pass 1: MarkdownBlockParser
  │    Flat [Record] + [LineSpan] + [Alignment] + linkDefinitions + boundary.
  │    Zero AST object allocations. Uses SIMD16 scans (MarkdownByteScanner) for line ends,
  │    closing fences (tryCodeRun), plain-paragraph runs (with plainInline proof),
  │    and 128-bit first-byte block-start bitset.
  │    Single source of truth for the safe append boundary (blank line at document depth
  │    with no leaf open).
  │
  ├─ Streaming Completion (when incomplete == true): MarkdownCompletion
  │    Post-Pass-1 repair of only the last leaf (paragraph, heading, or last table cell),
  │    ported from `@pierre/words` `src/complete.wat`. Closes open emphasis/strikethrough/code
  │    spans using CommonMark flanking/rule-of-three rules, substitutes placeholder destinations
  │    for unfinished links, and drops unfinished tags/images. When repair changes the tail,
  │    Pass 1 re-runs on the repaired copy; source bytes never mutate.
  │
  ├─ Pass 2: MarkdownInlineParser (reuses Scratch buffers across blocks)
  │    Skips inline parsing entirely when Flags.plainInline is set.
  │    Otherwise produces flat 32-byte [Mark] records using SIMD16 syntax scans, O(N) backtick
  │    memoization (tickMemo), CommonMark delimiter stack with openersBottom (O(N)),
  │    shared MarkdownHTMLScanner / MarkdownLinkSyntax / MarkdownEntities (full WHATWG table),
  │    and GFM extended autolinks, emitting coalesced [MarkdownInline] runs directly.
  │
  └─ Planner: MarkdownPlanner
       Projects flat records/inlines into [MarkdownBlock] (Sendable value types) for
       layout, selection, and rendering.

Streaming: StreamingMarkdownParser (`lib/core.ts` session model)
  - Commits completed document-depth prefixes at MarkdownBlockParser's boundary once.
  - Literal extension fast paths (O(delta) per chunk, armed only when no completion repair
    or new link definitions are active):
      1. Open top-level code fence literal extension (`fenceMayClose` guard).
      2. Single-line paragraph ending in a literal word.
  - Link reference definitions: parser-verified definitions persist in `definitions` (first wins).
    Only committed chunks whose bytes contained `[` are re-parsed when visible definitions change.
  - Downstream incremental layout: `AttributedTextBuilder.paragraphSuffix` +
    `TextLayoutEngine.layoutSuffix` + `CodeLayout` avoid rebuilding full attributed strings
    and CTFrames for growing open paragraphs and fences.
```

Key invariants:
- **Streaming equivalence**: At every streaming update, `committed + open` equals a fresh
  incomplete parse of the same prefix, and `finish(_:)` equals one-shot `MarkdownPlanner.blocks(from:)`
  for any chunking.
- **Linear worst-case time**: No quadratic regexes or rescanning — `hrKill` memoization in block
  parsing, `htmlNoClose` + `tickMemo` + `openersBottom` in inline parsing, O(N) extlink paren
  balancing, and a 524,288-cell auto-table cap keep adversarial inputs O(N).
- **Concurrency**: All parser types are `nonisolated` value types (`Sendable` outputs); parsing runs
  off the main thread in `TranscriptStreamWorker` / `LayoutQueue`.

## 2. Tracking parity with `@pierre/words`

Reference repository: `github.com/pierrecomputer/pierre` (`packages/words`).
Baseline synced commit: **`b049b9e`**.

Module boundaries map 1:1 so upstream bug fixes and performance improvements can be reviewed and
ported mechanically:

| Swift file | `@pierre/words` counterpart | Responsibility |
| --- | --- | --- |
| `MarkdownByteScanner.swift` | `src/scan.wat` | `SIMD16<UInt8>` scans, block-start bitset, UTF-8 scalar & Unicode punctuation/whitespace helpers |
| `MarkdownBlockParser.swift` | `src/block.wat`, `src/blockscan.wat` | Pass 1 flat-record CommonMark + GFM block parser, HTML block types 1–7, GFM tables, link ref definitions, safe append boundary |
| `MarkdownHTMLScanner.swift` | `src/htmlscan.wat` | Shared CommonMark raw HTML tag/comment/CDATA/declaration grammar with `NoClose` memoization |
| `MarkdownLinkSyntax.swift` | `src/link.wat` | Shared link label, destination, title, and label-normalization helpers |
| `MarkdownEntities.swift`, `MarkdownEntities+Table.swift` | `src/entity.wat`, `tables/entities.txt` | Numeric/hex references and full 2,125-entry WHATWG named entity table |
| `MarkdownInlineParser.swift` | `src/inline.wat`, `src/extlink.wat` | Pass 2 flat-mark inline parser, emphasis/strikethrough stack, links/images, angle + GFM extended autolinks |
| `MarkdownCompletion.swift` | `src/complete.wat` | Post-Pass-1 streaming completion of the last leaf before `finish(_:)` |
| `StreamingMarkdownParser.swift` | `lib/core.ts` | Incremental chunk state, literal paragraph/fence extension, persistent link-ref tracking |
| `MarkdownPlanner.swift` | `lib/core.ts` + renderer projection | Orchestrates Pass 1 → completion → Pass 2 and projects into `[MarkdownBlock]` / `[MarkdownInline]` |
| `TranscriptLinkPolicy.swift` | URL policy + percent-encoding | Filters allowed schemes (`http`, `https`, `mailto`) and normalizes percent-encoding |

Completion behavior follows `@pierre/words` `complete.wat` byte-for-byte:
- A trailing delimiter run with nothing open outside it (e.g. `hello **`, `hello ***`) stays
  literal until following characters arrive; when an outer span is open (`**bold *`), the trailing
  run is trimmed so outer closers do not glue onto it.
- Partial table delimiter rows (`| A | B |\n| -`) are not speculatively completed; the table
  renders once a valid delimiter row arrives.

To check upstream changes since the last sync:

```sh
git -C <pierre-clone> fetch origin
git -C <pierre-clone> log b049b9e..origin/main --stat -- packages/words/src packages/words/lib/core.ts
```

Update the baseline commit SHA above whenever upstream changes are ported.

## 3. Intentional app-policy projections (not parser limitations)

The parser implements CommonMark 0.31.2 + GFM tables, task-list items, strikethrough, and
extended autolinks; `MarkdownPlanner` applies transcript-specific display choices today:

1. **Raw HTML (blocks & inline)**: `RecordKind.html` (all 7 CommonMark HTML block types) and
   `MarkKind.rawHTML` are parsed natively, then projected to `.code(language: "html", ...)` /
   inline `.code` for safe chat display.
2. **Images**: `MarkKind.image` is parsed natively, then projected as literal inline `.code`
   until inline image rendering is wanted.
3. **Link sanitization**: `TranscriptLinkPolicy.url(for:)` filters link schemes (`http`, `https`,
   `mailto`) before emitting `.link`.
4. **GFM task-list items**: `[ ]`, `[x]`, and `[X]` parse into `MarkdownList.Item.taskChecked`
   (GFM 5.3) and render as vector checkboxes in the leading list gutter (`TextLayoutEngine` +
   `TextRenderer`), while `MarkdownCompletion` hides partial `[` / `[x` markers during streaming.
5. **Fence language**: Only the first whitespace-delimited info-string token is kept as `language`.
6. **Pierre parity items left as upstream**: NUL bytes are not replaced with U+FFFD, `<pre/>` is
   treated as HTML block type 7, and math/footnotes/frontmatter/ANSI/HTML-formatters are not ported.

## 4. Future feature extension points

None of these require rewriting the two-pass parser:

- **Mermaid diagrams (` ```mermaid ... ``` `)**: Already parsed as `.code(language: "mermaid", code:)`
  with O(delta) open-fence streaming. Rendering is purely a layout/renderer branch on
  `language == "mermaid"`.
- **HTML rendering**: Add `.html(String)` cases to `MarkdownBlock` / `MarkdownInline` gated by a
  parser option; `MarkdownBlockParser` and `MarkdownInlineParser` already emit `RecordKind.html`
  and `MarkKind.rawHTML`.
- **LaTeX / Math (`$...$`, `$$...$$`, `\(...\)`, `\[...\]`)**: Opt-in flag mirroring `@pierre/words`:
  - Block display math (`$$...$$`): add `$` to `mayStartBlock` and reuse `tryCodeRun` with `$` as
    the fence byte.
  - Inline math (`$...$`): add `$` to `findInlineSyntax` + flanking-rule scanner (keeping currency
    like `$5 and $10` as plain text) emitting a `.math` mark.
  - Streaming: include `$` in literal-break checks when math is enabled.
- **GFM task lists, footnotes, frontmatter, GitHub alerts**: Add dedicated `RecordKind` / `MarkKind`
  or planner projections behind options without changing the core scanner or streaming state machine.

## 5. Package extraction & full-library checklist (for later)

When extracting the chat + Markdown engine into a standalone full-Markdown Swift package:

1. **Decouple app policy via `MarkdownOptions`**: Move `TranscriptLinkPolicy`, HTML/image
   AST projection mode (emit raw HTML / image nodes instead of `.code`), optional NUL → U+FFFD
   replacement, and future math/footnote/frontmatter flags into an options struct passed to
   `MarkdownPlanner` / `StreamingMarkdownParser`.
2. **Tight vs loose list flag**: Surface `isTight: Bool` on `MarkdownList` (block analysis already
   tracks blank lines between list items).
3. **Optional non-GFM extensions & emitters**: Add LaTeX math, footnotes, YAML frontmatter,
   GitHub alerts, or an HTML output emitter on top of the existing flat `Record` / `Mark` pipeline.
4. **Full CommonMark 0.31.2 + GFM spec suite**: Add the official spec JSON fixtures (also vendored
   in `@pierre/words/test/spec/`) as a `swift test` target alongside the streaming chunk-equivalence
   fuzzer (`1 / 7 / 17 / 97 / 256`-byte chunks == one-shot).
5. **Clean `swift-markdown` dependency**: Remove the `swift-markdown` package once Phase 3 deletes
   the legacy `Features/Chat/` files (the only remaining callers).
6. **Ship benchmarks**: Keep the one-shot and streaming throughput benchmarks in the package so
   future refactors cannot regress performance.
