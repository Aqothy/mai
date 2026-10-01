# Personal QA and dogfood checklist

Use the final release candidate identified by the next agent, not an older Debug snapshot. Record revision/build, platform/OS, display refresh setting, provider/runtime, thread and reproduction steps with any failure. Use disposable projects/chats for delete, crash, migration and permission experiments. These are **checks to perform**, not claims they passed.

Let automation cover exact source, IDs, requests, data recovery and performance measurements. Your time is most useful on actual input, visual coherence, readability, accessibility and normal work. A checked setting label does not prove the daemon/provider received it: require the agent's boundary report in the final section.

## 1. Essential desktop chat

- [ ] Open empty, one-message, ordinary and very long chats. Content is centered in the available detail pane, aligned with the composer and not hidden behind the sidebar. No prolonged blank settled viewport.
- [ ] Toggle the sidebar; drag its divider; resize narrow/wide; enter/leave fullscreen. Text reflows, controls stay reachable, and the paragraph you are reading stays in place.
- [ ] Scroll slowly and quickly; reverse direction; fling; drag the scrollbar to distant history. Look for blank patches, duplicates, overlaps, wrong reused content and long stalls.
- [ ] Reach at least three older-history boundaries. The same visible paragraph stays anchored, older messages appear once, and loading finishes.
- [ ] Jump to the bottom from far away. The last reply and composer spacing are correct. Short chats do not acquire strange empty space.
Focus desktop QA on the shipping native renderer. A Debug macOS List comparison is optional only to answer a specific unresolved behavior question; it is not a general QA requirement or release gate. iOS List remains in scope below.

## 2. Streaming, thinking and tools

- [ ] Run a real Codex answer with prose, numbered sections, a list, fenced code and a table. Text arrives plainly, without fade/reveal effects; partial Markdown remains readable.
- [ ] Watch thinking text, timer, working row and composer through wrapping and block-type changes. No vertical jump, pulsing/repeated recentering or stale final working indicator.
- [ ] Record a short problematic stream if needed and scrub it slowly. Look for left/right or top/bottom sections showing different content/positions. Keep the original recording and note capture rate; a smooth recording is not proof of every display frame.
- [ ] Scroll away while the reply grows. It should not drag you back. Return to the end/jump down and confirm following resumes; the jump control should not flicker.
- [ ] Open/close activity, thinking, command groups and nested outputs while streaming at the top, middle and bottom of the viewport. The reading position stays intentional; subsequent content is reachable.
- [ ] Open a long thought or tool output, scroll far away, load older history, return, then resize. Check for clipped output, stale space and surprising disclosure resets against the intended behavior. A List comparison is optional if it would resolve a concrete ambiguity.
- [ ] Switch chats and resize during a response, then return. The other chat must not display this stream; the original response continues and finishes correctly.
- [ ] Stop a response, trigger a controlled failure, and retry. Stop/error/completed states are clear; no stuck spinner, lost prompt or duplicate send.

## 3. Composer, completions and settings

- [ ] Enter sends once; Shift+Enter inserts a newline. Undo and selection replacement work with emoji, combining characters and Japanese/Chinese text.
- [ ] Try your normal input method. Confirming composition must not accidentally send; intentional submission must still work.
- [ ] Type @file, /command and $skill where supported. Check filtering, up/down, Enter, Escape and pointer choice; insertion occurs at the cursor with surrounding text intact.
- [ ] Dismiss or select a completion, then quickly edit/switch chat/provider/project. Old results must not reopen or insert into the new context.
- [ ] Drafts survive chat switches/relaunch, including multiline text and intended attachments/annotations. A failed send retains the draft; a successful send clears only what was submitted.
- [ ] Select a different model/reasoning setting; use a new and an existing chat, then restart/resume. UI reflects the authoritative effective setting or explains incompatibility. Require the wire-level verification below as well.
- [ ] Switch provider/account, custom runtime and working directory. Confirm the next message uses the intended context and other chats retain theirs.

## 4. Annotations and rich content

- [ ] Select prose, open Comment, edit/add/cancel/remove a note. Quote and note stay attached to the correct message after scrolling/reuse and chat switches.
- [ ] Send annotation-only and annotation-plus-text prompts. Queue/steer while another chat is selected, then reload/fork the original. Cards, notes and references remain correct.
- [ ] Edit a very long quote with a multiline note. The note and Add/Cancel stay visible/reachable with the keyboard; dismissing must not unexpectedly submit.
- [ ] Inspect headings, nested lists, quotes, rules, bold/italic, inline code, links, Unicode/emoji, long lines, tables and labelled/unlabelled code.
- [ ] Select/copy across wrapped prose; copy code and tables. Paste into a plain-text editor and verify actual text, Unicode and line breaks.
- [ ] Scroll code/table horizontally without dragging the whole chat unexpectedly. Scroll away to reuse rows and return; selection, copied feedback, syntax colors and horizontal position must not leak into unrelated rows.
- [ ] Open a supported link using a disposable safe URL. Confirm the destination matches the displayed content.

## 5. Attachments, approvals and history

- [ ] Send image-only and text+image prompts; remove/re-add attachments and hit the documented count/size boundaries. Preview and outgoing content agree.
- [ ] Inspect user, assistant and tool media; invalid/missing/unsupported files show readable fallbacks, including larger text sizes.
- [ ] Fetch a real remote tool detail/file change; verify loading/error/success and stable scroll position. Inline images currently have no open-preview/copy-image action; do not count an unimplemented feature as a regression.
- [ ] Try available photo/file/camera pickers, cancel, and permission denial/recovery on the relevant platform. Use ordinary OS permission controls; do not weaken security settings for QA.
- [ ] Exercise approval accept/decline, queued prompts and interrupt. The right request/chat is affected; no action happens silently.
- [ ] Search/list/import/resume/rename/fork a disposable Codex chat. Reload and restart provider/daemon; title, messages, reasoning parts, annotations and session identity remain correct.
- [ ] Disconnect/reconnect briefly and for a longer outage. Clear recovery/Retry state; no duplicate history or silently lost accepted prompt.

## 6. Terminal and navigation

- [ ] Create/attach a terminal; type Unicode; generate long output; select/copy; resize and switch to/from chat. Output stays ordered and input goes to the intended terminal.
- [ ] Run a supported live provider in a disposable terminal. Agent activity/state changes make sense; completion/exit does not strand the UI.
- [ ] Disconnect/reconnect, exit/relaunch and delete a disposable terminal. Old process output must not appear as a new run.
- [ ] Exercise project folder selection/search, sidebar filters, thread search, import/fork navigation and multiple app windows if supported.
- [ ] Check offline/error states and recovery buttons for the surrounding app, not just the transcript.

## 7. iPhone/iPad and accessibility

- [ ] On actual iOS 18.6 (if available) and the current supported OS, repeat ordinary chat opening, paging, streaming, scroll-away/resume and thinking/tool disclosures. Record the actual runtime.
- [ ] Type a multiline draft, rotate portrait/landscape with the software keyboard visible, switch chats and return. Prompt, Send, navigation and jump control must not overlap or disappear unexpectedly.
- [ ] Repeat landscape-with-keyboard using a pending annotation; edit a long quote/note and exercise Add/Cancel. Older iOS keyboard clearance remains an open gate.
- [ ] Repeat completion selection, attachment removal/pickers, settings and terminal checks on mobile.
- [ ] Light/dark and larger/accessibility text: no clipped controls, unreadable fallback labels or illegible syntax colors. Check your actual preferred text size.
- [ ] Keyboard-only desktop navigation and VoiceOver: sensible reading order, labels/actions, focus and copy controls; no stale reused content announced.
- [ ] Test real 60 Hz and 120 Hz hardware separately where available, under ordinary power/thermal conditions. iPhone 14 is a 60 Hz check. Simulator is functional evidence only.

## 8. Dogfood and release artifact

- [ ] Use the release candidate for one representative work session: multiple projects/chats, a long response with tools, annotations, a terminal, switching/resizing and one restart.
- [ ] Note whether scroll feel is consistently responsive, whether typing ever stalls, and whether memory keeps growing across repeated returns to the same content/widths. Let the agent measure suspected regressions.
- [ ] Launch the actual signed Release artifact with normal settings. No synthetic thread, benchmark controls, QA window or automatic termination should appear.
- [ ] Verify existing data still opens and error recovery remains usable. Do not test downgrade against your only copy of valuable history.

## Agent evidence you should demand before approval

- [ ] A boundary report showing selected model/reasoning and other settings in the client command, daemon handling, driver request, authoritative session and restart/reload—not just screenshots or a local setting assertion.
- [ ] Exact prompt/attachment/annotation payloads, streamed/final source and identity checks; no cross-chat routing, replay duplication or hidden partial-page success.
- [ ] Passing current iOS 18.6 generated-model replay, wire decoder, lifecycle and notification tests, with `.xcresult` runtime metadata.
- [ ] Current relevant Swift and Go checks, race/error-injection results and narrow explanations for any platform/provider exclusions. No unknown skips or waived failures.
- [ ] Current archive/signature/entitlement/privacy/minimum-OS review, Release debug-hook audit and a precise candidate revision/build.
- [ ] Performance comparison for actual workloads with build/hardware/window metadata, p99/worst hitches and memory as well as averages; no simulator-to-device or callback-to-presented-FPS substitution.
- [ ] The release checklist identifies remaining required human/external gates; the release agent has not labelled the branch ready before they are satisfied or deliberately scoped out by you. The second handoff separately delivers the updated feature map and maintenance automation.
