# Quick looks (rt-look)

Live sync's "look" finds what changed after each edit. On heavy projects it was the biggest remaining cost:
- every look asked REAPER for every track's chunk (7.3 MB at 150 tracks and 520 plug-ins);
- it then ran ~150-300 ms of Lua and ~144,000 REAPER calls;
- in REAPER on the desktop, the chunks alone take 44 ms, so most of the cost was StudioSync's Lua.

Now an edit costs roughly what it touched. This round also fixed the orchestrator's finding: an envelope point took 4.2 s from the edit to its
event file.

## What changed

### 1. Quick looks build on the last look (`lib/mirror.lua`)

`mirror.watch(..., { quick = true })` runs `mirror.quick_scan` instead of `mirror.scan`. Only Live sync's looks pass `quick`
(`StudioSync - Live sync.lua`, P.look). Everything else (preload, the panel, Restore, Undo, the tests in `tests/reaper/`) still looks in full,
exactly as before.

**Which tracks it reads.** Each look keeps, per track (by GUID), its chunk, the parts worked out from it and its items' states. A quick look:
- reads every track's settings through the API (the track object is always fresh), plus a cheap fingerprint (`track_fp`): plug-in
  translations, item count, first and last item's position and length, plug-in count and which are on, envelope point counts, and receives
  with their levels;
- asks for the chunk only of tracks that may have changed:
  - its fingerprint moved;
  - a selected item or track is on it, it's the last touched track, the MIDI editor's take is on it, or the selected envelope is on it;
  - an FX window was open on it in the last minute;
  - it holds an object W.one still has something to do with (unsent, settling, refused, a print flag, a chain still loading or restless);
  - something was recorded for it since the last look (`remember`), or another module called `mirror.touch`;
  - it's pooled MIDI, or has fixed lanes (an item's lane is read through the API, so chunk equality can't vouch for it).
- keeps a track whose chunk is byte for byte the last look's, parts and items, with no item calls at all.

**The fallback.** If none of those tracks changed anything the band would see, the look reads every chunk, because the edit is one the hints
can't see (a script's, a knob with no window open). It also reads every chunk each `QUICK_ALL_SECS` (10 s), when ripple editing on all tracks
is on, and when the tempo map changed.

**When it looks in full.** A full look (`mirror.scan` plus every object through W.one, as before) runs:
- every `QUICK_FULL_SECS` (60 s);
- on the first look of a project;
- after an undo or redo (from `Undo_CanUndo2`/`Undo_CanRedo2`: REAPER puts back records as well as objects);
- when tracks are added, removed or reordered, or the restless list, SWS colouring, Local mixing, the media folder or the master track change;
- whenever crash-safe restore or a kept-back bus rescans.

**The safety net's log.** At each timed full look, the quick scan also runs first at the same moment. Anything the full look reads
differently is logged once a minute at most (`mirror: the full look found N change(s) the quick looks hadn't (...)`) and counted in
`mirror.look_stats.missed`.

**W.one.** It runs only on objects that may need it (`look_dirty`):
- objects that changed;
- objects it didn't leave clean last time (W.one marks its no-op outcomes in `w.clean`);
- objects whose record changed or was recorded since;
- objects with a flag (unsent, print, reopened, held back), moved tracks, and tracks on a colour-scheme change;
- chains that are restless, modulated, still loading or not yet knob-agreed.

Invariant: an object W.one looks at is always on a track read this look. W.one never works on a state carried over.

**Prints, gone and pending.**
- `W.prints` looks only at items that changed or whose track changed. It looks at all of them when:
  - who's here changed;
  - any chain or routing changed;
  - an item's "nothing to print" minute is up (`quiet_min`);
  - an item has none (`prints_missing`).
- `prints.takes_to_lanes` and `prints.watch_ara` take a set of tracks: an additive optional parameter in `lib/prints.lua`. ARA tracks are
  remembered between looks.
- `sync.pending_events` (a listing of every change of the room) is asked at most once a look, and only when a track looked at has items with
  takes.
- `W.gone` considers only items gone from a changed track, what was left gone last time, and what was recorded since.

### 2. Plug-in chains and automation go at once after an undo point (the 4.2 s)

Cause:
1. The look 0.1 s after the edit noted the changed envelope (`fx_seen`).
2. Plug-ins and automation then had to hold still for 3 s.
3. The look that sent it came only with the next 2 s pass. "Waiting" looks are at least 1 s apart.

That adds up to 0.1 + 2 + 2 s ≈ 4.2 s, as measured: 4.17 s on the desktop and 4.18 s on LinuxBox.

Now:
- A change that came with an undo point since the last look (`mirror.look_cc`) goes at the first look: a drop, a script's undo block, a typed
  value. Drags are never looked at mid-drag. A knob from a control surface makes no undo point, so it still settles. Not on a project's first
  look, while plug-ins load.
- Settling is `mirror.SETTLE_SECS` = 0.3 s of no change (was 3 s).
- `mirror.settle_due` is the moment the soonest one is due. Live sync makes a pass then (3 lines after `poll()` in the tick).

### 3. Smaller speed-ups, same results

- `mirror.track_line` runs its gsub only when a field holds a "|".
- `mirror.same_but_labels` returns at once when neither side has a dry/wet label.
- `W.one`'s once-per-record anchor check normalizes the event's item once, not twice.
- `mirror.normalize_item` keeps unindented `E ...` MIDI event lines as they are, without four patterns each. This halves a big MIDI item. The
  test compares it with the previous body on every item and on edge cases.

### 4. A fix in `lib/dawview.lua` (Project page look, from rt-bigproj)

After a pause, `dawview.read` checked that the tracks were still there only on the iteration that paused. Resumed at track 40 with 50 tracks
left, it read track 50 as nil and threw. `tests/test_0_60_rt_bigproj.lua` failed intermittently on it. Now it checks every track after a
pause.

### 5. A bandmate's change applied on arrival (round 2)

Deployed and measured in REAPER on Cross Test (0.59.49.65): edit to the sender's event file took 0.11-0.14 s, against 4.2 s before. End to
end, desktop to laptop, still took 1.2-1.6 s. Two causes found; both are fixed, and both are pinned by `tests/test_0_60_rt_receive_latency.lua`.

**On the sending side (most likely the 1.2-1.6 s; read from the code, not yet measured).**
- Event files go over the link through `StudioSync_DirectSend`. That's one sending thread for every file: `do_job` sends to each peer in turn
  and waits for each answer.
- The same thread also does the shared clock's pings and the streams.
- So a bandmate later in the list waits for every earlier one. A slow or relayed computer costs its round trip; one that's asleep or off costs
  a connect timeout of up to 1.5 s, and after a failure that peer is skipped for only 10 s.
- Messages go a different way: each bandmate has a lane with a thread of its own, sent the moment they're queued. That's what the "tens of
  ms" was measured on.

The fix:
- `sync.post` also sends each object change as an `event` message, up to `direct.MSG_MAX` (64 KB). A big plug-in chain or MIDI item goes as
  the file only.
- On the receiver, Live sync's `event` handler calls `sync.take_event`. That writes the event into the link's inbox, as the extension writes a
  file that arrives, and starts a pass at once.
- `sync.take_event` takes only an object change for this song and room, named as its file is (no path, no leading dot), and not one already in
  the folder or the inbox.
- The extension has already checked that the message came from the studio, and its size.
- The file still goes as the record; arriving after, it's already applied.

**On the receiving side (a stall of up to 2 s, found and fixed; not the steady second on Cross Test).**
- Before receiving, `P.receive` waits for `sync.seen_mine`: a look must have seen your last edit. It went by the project's change count, and
  StudioSync's own writes between passes move that count. They're taken in, so they don't count as you editing.
- The look that would catch up waits `mirror_took * 5`, and `sync.receive_now` fired only once, as a quiet window after your own edit ended.
- So an arrival could wait for the next 2 s pass. In the model at a 0.3 s look: the slowest 2.03 s, 1.01 s on average.

The fix:
- `sync.seen_mine` also takes "the last look began after your last edit" (Live sync's `changed_at`).
- `sync.receive_now` tries a held change again every `sync.RETRY` (0.1 s, and a big song's fifth), except while a redo wait holds the band's
  changes on purpose.
- Model: all applied in the tick that saw them. A real two-computer receive of one envelope point that came as a message: about 1 ms of Lua.

**Unchanged protections.**
- The quiet window after your own edit: 0.4 s on the link, then it lands promptly.
- The mouse gate: nothing lands mid-drag; it goes just after the drop.
- Unsent edits per object (`mirror.receive`).
- `seen_mine` for an edit made after the last look.
- The 30 s redo wait.

**A new measure for REAPER.** `rt_perf.lua` prints "a bandmate's change: arrival -> applied" (median, p95, slowest). That's from the tick that
saw the file or message to the end of its receive, so the receiver's part can be read on its own.

## Numbers (offline, this desktop, shared with other agents; fake REAPER, so REAPER calls are the real-cost hint)

Big project: 150 tracks, 520 plug-ins, 4,000 items, 60 MIDI.

| Look | Before (every look) | Quick look |
|---|---|---|
| nothing changed | 118-156 ms, 143,000-151,000 calls, 7.3 MB of chunks | 16-20 ms, 12,250 calls (every chunk read: the hints found nothing) |
| one item moved, not selected | 103-255 ms | 16-20 ms, 12,980 calls |
| one item moved, selected (as a drag leaves it) | same | 16-20 ms, 12,830 calls, **0.03 MB** of chunks |
| one MIDI note changed (a 41 KB item normalized and sent) | 131-167 ms | 22-29 ms |

The full look, now once a minute, costs ~7,600 more calls than before: it records the fingerprints.

Envelope point set from a script (undo block), small project, through Live sync's pass cadence
(`tests/test_0_60_rt_look_latency.lua`):
- the old rules: 4.23 s (REAPER: 4.17 / 4.18 s);
- now: 0.17 s;
- an item moved: 0.17 s;
- a knob with no undo point: by Live sync's 10 s look plus 0.3 s, as it moves no change count.

## Tests

`tests/test_0_60_rt_look.lua` covers a medium bigproject model. Each case is caught and goes out:
- an unselected item moved, read through the every-chunk fallback;
- a selected item moved: only its track's chunk is read;
- a MIDI note;
- an item's volume and mute;
- a plug-in knob with no undo point and no window: it settles, `settle_due` is set, and it goes;
- an envelope point with an undo point: the first look sends it;
- a send added;
- fixed lanes;
- a write StudioSync recorded itself: neither sent back nor put back;
- track order: a full look;
- an undo: a full look;
- two edits at once with only one hinted: the other goes within `QUICK_ALL_SECS`, and is logged when the full look gets there first;
- `mirror.touch`;
- 40 random single edits.

After each case, the look's view of every object equals a full scan.

`tests/test_0_60_rt_look_latency.lua` pins the edit-to-event time.

`tests/test_0_60_rt_bigproj.lua` now enforces quick-look budgets: nothing changed, one item moved (selected or not) and one MIDI note each
≤ 30 ms (a median of 5), and one selected item asks for < 0.5 MB of chunks. Idle tick budgets are unchanged.
- Other agents' builds slowed every figure 1.5-2x during this work, so the 30 ms scales with how slow the run's warm full look is (against
  120 ms, capped at 3x).
- Whatever the load, an edit's quick look must cost at most a fifth of the full look's.

## Hook point for other modules (rt-video2 and later)

When StudioSync writes to a track or item without a mirror record (stand-ins, generated takes, anything set through the API outside
`mirror.apply`/`remember`), call `require("mirror").touch(proj, track)`. The next quick look then reads that track's chunk. Writes that go
through `remember` need nothing. `lib/video.lua` doesn't write to the project today, so it needs no call. `prints.takes_to_lanes` calls it
now.

## Untested / to check in REAPER

- Nothing ran in REAPER. In particular, the hints rely on REAPER selecting what you edit; a ReaScript's edits fall back to reading every
  chunk.
- Whether REAPER's chunk holds everything the API shows that matters: `TAKE SEL` for the active take, and receives' levels in `AUXRECV`.
  Lane tracks are already always worked out.
- `GetLastTouchedTrack` and `GetSelectedEnvelope` answer for the project in front only. A tab behind falls back to every chunk.
- What the 10 s every-chunk read costs on a heavy real session: real plug-ins serialising. Before, that was the cost of every look.

REAPER checks for James:
0. Round 2: on Cross Test with everyone in, perf stats on, on the laptop:
   - edit on the desktop, and time edit to applied on the laptop (shared clock, as before). Expect under 0.3 s, against 1.2-1.6 s.
   - run `rt_perf.lua` on the laptop: "arrival -> applied" should be tens of ms.
   - if it isn't fast with a Mac asleep or away: put that Mac first in the peer list and try again. Before, the file waited for it; now the
     message doesn't.
1. On Cross Test, set an envelope point from a script (undo block) and time edit → event file. Expect < 0.3 s, against 4.2 s before. Also
   drag a point with the mouse, then turn a knob from a control surface: it should go about 0.3 s after it stops.
2. On the big project (`tests/reaper/big_project.lua`), with timings on, move one selected item, then edit one MIDI note in the piano roll,
   then run `rt_perf.lua`. The slowest pass's "look" lap should be tens of ms, not hundreds. ExtState `StudioSync` / `look stats` shows
   quick, full, every-chunk and missed counts; missed should stay 0.
3. Edit from a ReaScript with nothing selected (it falls back to every chunk), then Ctrl+Z (a full look). Check that both go out and come
   back on the other computers.
4. Leave it idle 2 minutes. Look in the log for "the full look found": there should be none.

## Review-later (security)

- None new. Nothing received is parsed differently; the quick look only decides what to read from this computer's own project.
- `mirror.touch` is local (no message can call it).
- The faster settle sends a plug-in chain sooner after an undo point. Size limits on events are unchanged.
