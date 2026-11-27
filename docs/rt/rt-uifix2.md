# rt-uifix2: pages draw from the state that was already there when they load

## The bug
app.js opens the event stream first; tabs.js keeps every topic in `ssTabs.topics` (and seeds it from `api/state`). A page file that only listens for `ss-state` / `ss-tabs` and never looks at `ssTabs.topics` when it loads misses a first snapshot that came before its script ran (a loaded machine: the stream beats the later deferred scripts). It stays empty until the next change. rt-uifix1 found it in history.js and call.js and worked around it in two tests.

## The fix (no new polling, no new endpoint)
Each affected file reads what tabs.js already holds, once, when it loads:
- `call.js`: the `ss-state` handler is now `onState(s)`; it also runs once at load and on `ss-tabs` from `{ engine: ssTabs.engine(), topics: ssTabs.topics }`. `take()` skips rtc messages it has seen (`last`), so a repeat does nothing. `tabs.js` gets one line: `ssTabs.engine()` (the engine flag it already keeps).
- `history.js` (Changes / Versions / Mixes block): `onState()` at load (Changes and Mixes only drew from the topics when an event came).
- `histhear.js`, `audiencehost.js`, `guesthost.js`: the same one call at load (`onState()` / `draw()`).

## What was checked (every `lib/webui/*.js` that reads topics)
- Already fine, read `ssTabs.topics` on show or at load: ai, chat (layout draws), health, home, invite (DOMContentLoaded hook), mixer, play, profile, rooms, settings, sheet, tryfx, beat, visuals, history.js's first block (onShow calls onState), shell.js (loads before tabs.js, sees every snapshot).
- Seed from `api/state` themselves: daw, draw, autolanes, pianoroll, phonedaw.
- Standalone pages with their own state: record, guest, listen, join.
- Left alone: phonedaw's `phonekeys` listener (`kTopic`) only feeds a latency average and a "why" note; a missed first snapshot costs nothing the next one doesn't repair.

## Tests
`rt_ui3_browser.mjs` and `rt_ui9_browser.mjs`: rt-uifix1's "send the new page every topic again" lines are gone (rt_ui9 keeps its `until` waits); assertions unchanged. To prove it, a scratch copy of each that serves history.js (rt_ui3) or call.js (rt_ui9) 2.5 s late failed on the old page files ("every change, one row each", and the top bar's call controls) and passes on these.
