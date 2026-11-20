# rt-phonefix: the phone's Project view stuck on "Asking the computer for the project…"

## What was wrong

Found in real REAPER (JAMES-MAIN, StudioSync 0.59.49.65, extension 1.0.25, REAPER 7.86): record.html's Project view never left "Asking the
computer for the project…". The page was fine. It sent `daw` and `phonedaw` wants every 10 s and the server took them (202). The computer
published `phonedaw` and `dawcur` but never `daw` or any `dawc<k>`, so `phonedaw.js`'s `liveView()` never had a head.

The cause is in `lib/dawview.lua`. Since the look was spread over ticks (4de121b, today), `dawview.read` runs inside a coroutine. **REAPER
7.86's `GetMediaItemTake_Peaks` called inside a coroutine returns nothing and fills its buffer with junk.** This was measured in the desktop
REAPER with read-only probes: outside a coroutine it returned 382, 118, …; inside one it returned no values and the buffer summed to ~9e281.
Every other call the look makes (MIDI_*, EnumProjectMarkers3, TimeMap_GetMeasureInfo, GetSetProjectGrid, GetTrackStateChunk, take and
source names…) answers the same both ways. So `math.floor(rv)` failed at the first audio item of every look. Today's log has it once at
09:17:20, because `band.try` logs each different message only once: `ERROR in webui.tick: …dawview.lua:267: bad argument #1 to 'floor'`.
The look restarted every 10 s and failed again each time.

This was never phone-only. The desktop Project tab (index.html) reads the same `daw` topic, so it can't get a fresh arrange view either on a
song with audio. A song with only MIDI items worked. If that tab showed an arrange view today, it was from before 0.59.49.65 went in at
09:09 or from a song without audio.

## The fix (`lib/dawview.lua`)

- `outside(fn, ...)`: inside the look's coroutine (while `slice_end` is set) it yields `OUTSIDE, fn, args`. The tick's resume loop makes the
  call on the main thread (in a pcall) and resumes the look with its answers, all in the same tick. Outside the look, as in tests and
  direct calls, it just calls `fn`.
- `take_peaks` makes its `GetMediaItemTake_Peaks` call through `outside`. A missing answer now counts as "no peaks yet" (`tonumber(rv) or
  0`), so it's asked again after PEAK_RETRY, and one bad answer can't stop the whole topic again.

Checked in the real REAPER, read-only: the repo's fixed `dawview.lua` was loaded into the dev-eval hook and `dawview.tick` run against the
Cross Test tab with a capturing `publish` (nothing sent to the server). The `daw` header came out with 3 tracks and 1 chunk. The audio
item's real peaks arrived on the next look, as the peak budget intends.

## Tests

- `tests/test_0_60_rt_phonefix.lua` (new) drives the phone's flow through the real tick. record.html's three actions go in word for word
  (`phonerec`, `daw` and `phonedaw` wants), through the real `lib/webui.lua` tick, `lib/dawview.lua` and `lib/phonedaw.lua`, into a stand-in
  extension that keeps topics as the server does. It then checks the topics with `phonedaw.js`'s own rules from `liveView`, written in Lua:
  the header for the song `phonerec` names, every chunk it counts, and the `phonedaw` lanes in the same order. It also checks that the
  audio item has real peaks, the two-take item's takes, 40 s of 10 s wants, and another song coming to the front. The stand-in REAPER's
  `GetMediaItemTake_Peaks` behaves as REAPER does in a coroutine. A link check makes sure the page still sends those wants and still waits
  on `!v || !v.head`. Against the old `dawview.lua` it fails with the exact error from the real log (line 267, `floor`, nil).
- `tests/test_0_60_rt_dawview.lua`: its stand-in peaks now behave the same way in a coroutine. The first tick re-reads one item's peaks
  inside the look and checks they're REAPER's, not junk. It also fails on the old code.
- `python tests/run.py --no-luals`: the only failure is `tests/test_0_60_rt_receive_latency.lua`, another agent's untracked work in
  progress (with `lib/sync.lua` changes) that isn't mine. Everything else passes.

## The other views on record.html (real REAPER, headless Chromium, read only)

- Sheet: fine. It shows `0:00.0 A- A+ VERSE` from the `sheet` topic, which the computer publishes while the page asks.
- Play: fine. It lists the three tracks from the `phonerec` topic. "Live into REAPER" wasn't pressed, since it would play into REAPER.
- Record: fine. It's live, and `phonerec` updates about twice a second.
- Neither Sheet nor Play depends on the `daw` topic, so they don't have this problem. Project view's track panel (`mixer` want) wasn't
  opened.

## Untested

- The fix in Live sync itself, deployed: run with the real `webui.lua` → `dawview` path inside Live sync and seen on the phone page.
  Checked only with the probe above and the Lua tests.
- Other REAPER calls that might also misbehave in a coroutine. The look's whole set was probed and only `GetMediaItemTake_Peaks` fails.
  Any new call added to the look should go through `outside` if it takes a `reaper.array`.

## Review later

- Nothing new on the security side. No checks or limits changed.
