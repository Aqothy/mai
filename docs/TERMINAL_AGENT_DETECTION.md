# Terminal Agent Detection

Status: implemented (Increments 8 and 9 of
[TERMINAL_THREADS_IMPLEMENTATION_PLAN.md](./TERMINAL_THREADS_IMPLEMENTATION_PLAN.md))
Last updated: 2026-08-06

This is the Increment 8 decision record, the Increment 9 benchmark record,
and the operating notes for the daemon's coding-agent detection.

## 1. Architecture summary

Detection is daemon-owned and process-first, exactly as specified in
[TERMINAL_THREADS_SPEC.md](./TERMINAL_THREADS_SPEC.md) §11.7:

1. `internal/terminal.Detector` probes the PTY's foreground process group
   with `TIOCGPGRP` on each output batch, then runs one `/bin/ps` scan on its
   detector worker only when the group changes. Output delivery never waits
   for process inspection. It rechecks once per second while an agent is known
   so silent exits are observed. Idle shells are never probed or scanned.
2. A bounded streaming OSC tracker extracts OSC 0/2 titles and OSC 9;4
   progress from the output stream.
3. A passive, zero-scrollback `libghostty-vt` screen (build tag `ghostty_vt`)
   is fed the same bytes and formatted as plain text on a debounced schedule:
   200 ms after output settles, forced at most every 500 ms during continuous
   output, and never for clean idle terminals.
4. `internal/terminal/agentrules` classifies evidence with compiled-in rule
   tables ported from the Herdr project's recorded manifests
   (`agentrules/manifests/`, Apache-2.0, see `NOTICE`). Rules are embedded at
   build time; there are no remote updates.

Published reports carry only agent kind, semantic activity, and the
normalized title (control characters, spinner frames, and marker glyphs
removed, capped at 128 scalars). Screen text, raw titles, and process
details never cross RPC, never enter SQLite, and never appear in logs.

## 2. Supported agents

Identity is recognized for every agent the embedded manifests cover:

agy (Antigravity), amp, claude, cline, codex, copilot, cursor, devin, droid,
gemini, grok, hermes, kilo, kimi, kiro, maki, opencode, pi, qodercli —
including `node`/`bun`/`deno`/`python` wrapper launches (npm-style installs)
and shell-wrapped invocations.

An unrecognized non-shell foreground job is tracked as kind `unknown` and
still gets generic evidence (braille-spinner titles, ConEmu progress), so a
brand-new agent shows Working/Needs input without any code change. Unknown
jobs surface only when the generic evidence produced a real signal, so `ls`
and `vim` never churn the thread list.

To update or add an agent: copy the manifest from
`herdr/src/detect/manifests/` into `internal/terminal/agentrules/manifests/`
and run `go test ./internal/terminal/...`. Executable aliases live in
`agentrules/identify.go`.

## 3. Increment 8 decision record: what OSC/process evidence covers

Recognized without screen content (title/progress/process only):

| Agent | working | blocked (“Needs input”) | idle | done |
| --- | --- | --- | --- | --- |
| codex | title spinner frame | title `Action Required` | plain non-empty title | process transition |
| claude | title braille prefix | — (see below) | `✳` title, progress `4;0` | process transition |
| amp/grok/hermes | title rules from manifests | grok/hermes title rules | title rules | process transition |
| any other agent | generic spinner/progress | — | — | process transition |

`done` derives from the process signal (agent leaves the foreground, or
working evidence settles to idle, while no client is attached) and is
acknowledged by the next attach — it needs no screen content.

States that required Increment 9's screen source:

- **claude blocked**: permission prompts keep the `✳` idle title and leave
  progress stuck at `4;3`; only the on-screen form (“do you want to
  proceed?”, `❯ 1. Yes`, Esc-to-cancel footers) distinguishes blocked from
  idle.
- **codex static-title working**: background terminals show `• Working (…
  esc to interrupt)` on screen while the title stays static.
- **all screen-only manifests**: gemini, cline, copilot, cursor, devin,
  droid, kimi, kiro, kilo, maki, opencode, pi, qodercli, agy express
  blocked/working exclusively through screen rules.
- **viewer suppression**: transcript viewers and model pickers
  (`skip_state_update` rules) must not be mistaken for prompt state.

## 4. Increment 9 benchmark record

Environment: Apple M2 Pro, `go test -tags ghostty_vt -bench
BenchmarkHeadlessScreens -benchmem ./internal/terminal/vtscreen/`.

- 25 headless 80×24 screens, each iteration feeding a full styled 24-line
  redraw (~1.7 KiB) and formatting every second feed:
  **12.2 µs/op, 1 KiB and 2 Go allocs/op, ~594 heap bytes/screen**.
- Process max RSS with all 25 native VT instances: **~95 MB** for the whole
  test process (native VT memory is outside the Go heap).
- Extrapolation: 25 terminals in continuous full-redraw output with the
  formatter capped at 2 scans/second cost well under 1% of one core.

Budget (set now with measured evidence; Increment 0's spike numbers were
never committed): 25 detector screens must stay under 50 µs per
feed+format cycle and under 8 MB incremental RSS per screen. Current
measurements are an order of magnitude inside both.

## 5. Build recipe

The detector VT links a static `libghostty-vt` built from the Ghostty commit
pinned in `tools/ghostty-vt/CMakeLists.txt`, which must stay compatible with
the `go.mitchellh.com/libghostty` pseudo-version pinned in `go.mod`.

```sh
brew install cmake       # build-time only, once per machine
mise use -g zig          # zig on PATH via mise (build-time only)
make ghostty-vt          # builds static libghostty-vt into build/ghostty-vt
make run                 # daemon (statically linked against it)
make test                # full test suite
```

There is one build mode: the daemon always links `libghostty-vt`. Direct
`go build`/`go test` invocations — including gopls — need
`PKG_CONFIG_PATH=$PWD/build/ghostty-vt/_deps/ghostty-src/zig-out/share/pkgconfig`
in their environment; the Makefile targets set it automatically. The
resulting binary requires no installed Ghostty, Zig, or pkg-config at
runtime.

## 6. Increment 9.5: native model attach

Each run owns a second passive Ghostty VT with 2 MiB bounded scrollback, fed
under the session lock in sequence order. Attach resizes the PTY and model to
the client's measured grid and calls Ghostty's authenticated binary snapshot
encoder. The wire carries the GHOSTSNP bytes, grid, sequence watermark, and
an exact compatibility identifier.

The daemon and Swift binary both pin Ghostty commit `7a9c369cf`. The package
fork [`Aqothy/libghostty-spm`](https://github.com/Aqothy/libghostty-spm), tag
`1.4.1`, adds a narrow host-managed API that decodes a complete snapshot off
the renderer lock, reapplies surface-owned configuration, validates that its
grid still matches, swaps the model under the lock, restores parser
continuation, wakes the renderer, and only then returns success. A rejected
snapshot leaves the existing model untouched.

The client validates `snapshotFormat`, buffers live items above the snapshot
sequence, awaits installation, then reveals the surface and drains those items
in order. This completion is the visibility barrier, eliminating the old
scrollback flash. A concurrent layout change causes a fresh attach only when
the measured grid actually changed; malformed snapshots do not retry forever.

`FormatterFormatVT` was deliberately removed. It formats terminal content for
copy/export but cannot faithfully transfer every cursor, pending-wrap, margin,
mode, tabstop, alternate-screen, and parser state combination. Ghostty's own
renderer reads one persistent model rather than reparsing such a redraw. The
native path now follows that model instead of adding prompt- or grid-specific
corrections.

The snapshot compatibility string includes the exact Ghostty revision because
GHOSTSNP v1 is still an unstable upstream format. Upgrade daemon and package
together, regenerate the binary artifact, and change the compatibility value
as one reviewed operation. Tracking moving upstream independently on either
side is unsupported.

Why a second VT instead of reusing the detection screen: detection needs
cheap active-screen-only text with zero scrollback, while attach needs bounded
scrollback. Classifying a scrollback-retaining model would resurface old
prompts as false blockers and make periodic formatting more expensive. With
an attached client the stream is parsed three times (client renderer,
detection screen, attach model); the attach model is never text-formatted and
is encoded only on attach.
