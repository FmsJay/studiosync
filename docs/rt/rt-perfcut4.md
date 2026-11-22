# Perf cuts 7-9, the base-cost items and the efficiency list (rt-perfcut4, package P8, 2026-11-21)

What was built is offline-tested only (`tests/test_0_60_rt_perfcut4.lua`, rt-bigproj's 150-track, 4,000-item project in the stand-in REAPER).
Nothing ran in REAPER. Each part fails without its change (checked by reverting one file at a time against HEAD 625d421).

## 1. Cut 7: the colour look only with Colour parity on (`lib/sync.lua` write_status)

`write_status` builds `colours.look` (every item's and take's colour, ~29,500 REAPER calls on the heavy song, 23-31 ms) on every status write. Its
only reader is Health's Colour parity row, which only exists while the studio's Colour parity is on (`colours.health_row`). So with it off the
look is no longer built and the status has no `look` key. Anything a user sees is the same (the row never showed with parity off).

Offline, a status write on the big project: parity on 29,480 REAPER calls (8 ms of Lua), off **3 calls** (0.00 ms).

Parity is on by default, so most studios still pay the look on each status write (2-4 a minute idle, up to every 5 s editing). Not cut further,
on purpose: holding the look by change count with a floor (rt-perf's wording) can't help while editing (the count moves every edit) and a
colour set by a script with no undo point would make Health's row say "colours differ" for up to the floor, on top of its 30 s grace. If
that cost matters after the REAPER run, the same per-track memory as cut 8 (re-read hinted, selected and fingerprint-changed tracks, all of
them every 20-30 s) would do it, with that one visible difference; James's call.

## 2. Cut 8: the Project page's look reads the tracks that may have changed (`lib/dawview.lua`)

`dawview.read(proj, key, now, budget_end, tc, full)` keeps, per track, the items it read last time (`tc.tracks`, keyed by the track pointer and
GUID). A look re-reads a track's items when:
- it is the first look, or `full`: one each `dawview.FLOOR` (10 s) as before, after `mirror.apply` or `mirror.touch` wrote the project (a
  bandmate's change landing, a put-back: they bump `mirror.applied`), after the page sent an edit, a MIDI-roll or an automation change
  (`dawview.action` sets `S.dirty_all`), and while an undo can be redone (`Undo_CanRedo2`, and once more after it clears);
- its cheap fingerprint moved (`items_fp`: item count, I_FREEMODE, first item's position, last item's position and length);
- it's a hinted track: `mirror.hinted(proj)` (selected items and tracks, the MIDI editor's take, the last touched track, the selected envelope,
  an FX window open in the last minute), and the tracks hinted at the look before, so an item deselected straight after its edit isn't missed;
- it is waiting on peaks REAPER hasn't built (or on a budgeted read), or holds a video item (the look offers those again each time).

Always read, every look (about 8 calls a track): name, colour, mute, solo, folder depth, envelope count, whether it's shown. The peak and note
caches are only purged on a whole read. Other callers of `dawview.read` (no `tc`) behave as before.

**Visible difference, stated plainly:** a change that no hint and no fingerprint sees stays off the page until the next whole read, up to 10 s:
another script's edit of an unselected item in the middle of a track, or another REAPER script's restore. Everything StudioSync itself does
(its own edits, bandmates' changes, the page's edits, undo) is read at once.

Offline (the big project, the change count moved each time):

| Look | REAPER calls | Lua ms (stand-in) |
|---|---|---|
| first (peaks built) | 132,069 | 685-760 |
| a whole look, peaks kept (what each look cost before, and a FLOOR look still costs) | 56,033 | 28-35 |
| nothing but the change count moved | **3,906** (7 %) | 12 |
| one selected item moved (its chunk and the header go, same bytes as a whole look) | **4,314** (7.7 %) | 12-14 |

(`os.clock` steps 1 ms here; the calls are the stable number. At 0.5-1 µs a call in REAPER the whole look is the 40-45 ms rt-perf measured.)
`tests/test_0_60_rt_dawview.lua`'s payload check now selects the item it moves, as a drag does; unselected, the look doesn't see it until the
next whole read (that case is asserted in the new test).

## 3. Cut 9: the status write's split (`lib/sync.lua`, `StudioSync - Live sync.lua`, `lib/direct.lua`)

New: laps inside library code while perf stats is on. Live sync hands its `lap` to `band.sublap` in `perf_publish` (nil when perf stats is
off, one nil test per site). `write_status` marks `status/folder, name clash`, `status/info`, `status/colour look`, `status/file`,
`status/link send`. `tests/reaper/rt_perf.lua` now lists 30 laps per tab (it listed 12).

Offline result for the question rt-perf left open ("the link send or gathering `info`?"): of a status write's 29,480 REAPER calls, **29,477 are
the colour look**; the folder check, name clash, `info`, file write and link send are 3 calls and no measurable Lua. So the 10-32 ms was the
colour look (cut 7 for parity off). The write's own disk part stays ~2 ms (rt-perf). Nothing else to cut there until the REAPER laps say so.

## 4. `start/link` split, `band.songs` held, the stream trace capped

- `direct.live_tick` and `direct.tick` mark `link/poll, ensure`, `link/prune`, `link/peers`, `link/clock`, `link/heartbeat`, `link/messages`
  (`link/prune` only when the 10 s prune runs). The REAPER run (section 7) says which of them owns the ~0.25 ms a tick; nothing in them was
  cut blind (rt-perfcut3's own advice: split before changing). What's left in `start/link` is the remainder after the last mark.
- `band.songs` (5.3 ms on the desktop, asked by the hub's 10 s scan, each cloud plan, Listen, the Home page): the answer is held
  `band.SONGS_HOLD` (5 s) per studio, as a copy, and emptied by any write or removal of a `session.json` here. Not held while a join's
  first copy is coming (`join boots` set). Visible difference: a song a bandmate published shows in this computer's lists up to 5 s later
  than it arrived (Syncthing's own delay is longer). A second call inside the hold reads no `session.json` (tested).
- The stream trace (`ExtState "stream trace" = 1`) grew without a limit: past `direct.TRACE_MAX` (20 MB), checked every 60 s, it is renamed
  `stream_trace.log.old` (the older `.old` goes) and a new one starts; every writer appends by name.
- **Live audio's peer and vouch merges (`lib/liveaudio.lua`, 2.2 ms a run, worst 42 ms): not touched** (P11's file). What `liveaudio.tick`
  does each 0.5 s: `direct.peers`, `nat.peers`, `presence.here`, `heard_merge`, `presence.peers`, `vouch_merge`, `livex.guests`. A cache
  of the merged list keyed on the inputs' signatures (direct's peer list table, presence's status times, `S.heard`) with a 2 s floor would
  skip all of it on idle ticks. P11 or P12 should do it with the file in hand.

## 5. The efficiency list (backlog 1.37), each item done or dropped

| Item (roadmap "Problems found, not fixed") | Now |
|---|---|
| Arrange redraw every pass | done (rt-perfcut2 cut 4) |
| `seen_ev` and `fired` unbounded | done (pruned each minute, Live sync) |
| `refused_at` never cleared | done (entries older than an hour go, `lib/sync.lua`) |
| streams `asked`, `sent_media`, `placed`, `streamed` | done (`streams.forget_old`, media_tick) |
| recall `ev_cache` | done (this room's names no longer listed go every 10 minutes) |
| mirror `fx_open_at` (per track pointer, never pruned) | dropped: one small entry per track whose FX window was ever opened, bounded by the project's tracks; no growth over time |
| `sync.authority` reads every claims file uncached | done (cached, as backlog 1.37 said) |
| write_status reads its own file back each write | done (`sync.CLASH_EVERY`, 45 s) |
| "Catch-up with a cloud copy asks Syncthing's need list every 30 s alone" | done (doubling wait to `streams.CLOUD_WAIT_MAX`, 300 s) |
| Unlimited stream trace log | **done here** (capped, section 4) |
| The cue watch walks every name when it lists | dropped: one hash lookup per name, ~1-2 ms at 20,000 names, only when the folder moved (an event arrived) |
| The web UI builds every second with nobody looking | dropped: 0.8-1.6 ms a second (0.1 % of a core, rt-perf); gating it on a connected browser leaves a first page load up to a second stale, and a docked web view is always connected. `lib/webui.lua` isn't this package's file either |
| `presence.lua` `last_time` keyed by user only | not done: `lib/presence.lua` is rt-fix5's. The fix: key it by `user .. "\0" .. song .. "\0" .. room`; only matters for one person in two rooms at once |
| Colour parity's look on every status write | done (cut 7); with parity on it stays, section 1 |
| The Project page rereads every track | done (cut 8) |
| `band.songs` | done (section 4) |

## 6. Tests

`tests/test_0_60_rt_perfcut4.lua` (the numbers above print from it):
- cut 7: with parity off `colours.look` isn't called and `info.look` is nil; on, it is built; the source asks the switch; 3 against 29,480 calls;
- cut 9: the status write's marks in order with `band.sublap` set, no marks and no error without it; `direct.tick` and `live_tick` marks in order
  with the extension stood in (the prune only every `PRUNE_EVERY`); Live sync hands its lap over only while perf stats is on;
- cut 8: first look publishes everything; a look with only the change count moved asks REAPER a fifth as often as a whole one; a selected
  item's move sends its own chunk only, and what the partial look publishes is what a whole look of the same state publishes; a deselect
  straight after still reads the track; an unselected middle item's move isn't seen until the whole read within FLOOR; the last item's trim
  is seen with no hint; `mirror.applied`, a page's edit and a waiting redo each make the next look whole;
- `band.songs`: a repeat reads nothing, a caller's change to the list can't reach the held one, read again after the hold, a `session.json`
  write or a join's boot copy releases it;
- the trace rotates past the cap, at most each `TRACE_CHECK`, and the older `.old` goes.
Without each change the test fails (sync.lua at the parity line, dawview.lua at the call-count check, band.lua at `forget_songs`, direct.lua at
the laps, mirror.lua at `hinted`, Live sync at `band.sublap`). `test_0_60_rt_quiet_folder` and `test_0_60_rt_status_read` stand in
`colours`: their stand-ins now also answer `parity`.

## 7. REAPER steps (desktop; `tests/reaper/rt_perf.lua`, ExtState `BandSync / perf stats`)

Switch perf stats on by running `tests/reaper/rt_perf.lua` once (it sets ExtState `BandSync / perf stats` = `1`, not saved), wait 20 s, run it
again to read each tab's "tick stats". Set `OFF = true` in the script (or `DeleteExtState("BandSync","perf stats",false)`) when done.

1. **Cut 7.** Cross Test open, Live sync running, idle. In Settings > Studio > Colour parity switch it off, run rt_perf twice 30 s apart: the
   `status/colour look` lap is gone (it was ~0 ms in the table already on the small song: this matters on the heavy one, step 5). Switch
   it on again: Health's Colour parity row comes back within a status write (15-30 s), and says the same as before.
2. **Cut 9 and start/link split.** On Cross Test idle for 5 minutes with perf stats on: read the `status/*` and `link/*` laps (total ms /
   100 = % of one core, ticks, worst). Expect `status/colour look` the largest of the status laps and `status/file` ~2 ms a write.
   The `link/*` laps say which of poll, prune, peers, clock, heartbeat or messages owns start/link's ~60-90 ms per 10 s. Send me the table:
   the next cut is chosen from it.
3. **Cut 8.** Heavy song (`tests/reaper/big_project.lua` makes it) with real plug-ins, Project page open on the Song tab in the web UI, then
   edit continuously: nudge a selected item every 2 seconds for a minute, then change a track's colour, mute and solo. Check on the page that
   each change shows within a second (selected item moved, mute, solo, colour, rename, a new item, a deleted item, the last item trimmed,
   Undo then Redo of a move). Then change an unselected middle item with another script or action (select it, change its mute, deselect it again before the look): it may
   take up to 10 s to show; that is the accepted risk, and the number to judge it by. rt_perf: the
   `dawview` share of the editing ticks should drop to a few ms where it was 40-45 ms per look (16-25 % of a core editing).
4. **band.songs.** Open Home, Listen and the hub's scan idle: no change to what they list. Publish a song from the laptop: it appears here
   within a few seconds of arriving (up to 5 s after).
5. **The heavy song with real plug-ins, Live sync on (never measured).** Needs a scratch studio, never the real one:
   a. In StudioSync create a throwaway studio on the desktop only (a folder nobody else syncs, say `J:\scratch-studio`), no other computer.
   b. Run `tests/reaper/big_project.lua` (150 tracks, 4,000 items), add the real plug-ins as rt-perf did (ReaEQ and ReaComp on 69 tracks, Surge XT
      Effects on 19, 12 synths: Vital x4, Surge XT x3, Odin2 x2, Dexed x2), publish it into the scratch studio, let Live sync start.
   c. perf stats on. Measure 10 minutes idle, then 10 minutes editing (move a selected item every 2 s, a fader now and then), with the Song page
      open for half of each. Report the table: tick median/p95/slowest, the largest laps, and REAPER's main thread CPU. Targets from rt-perf:
      idle 26-28 % of a core in front, no 300+ ms stall more often than every ~2.5 minutes, edit looks 35-45 ms.
   d. Close the tab without saving, delete the scratch studio folder and the scratch project, perf stats off.

## 8. Left

- Live audio's merges (P11/P12, section 4).
- `presence.lua` `last_time` (rt-fix5's file).
- The colour look with parity on (section 1) and the `start/link` remainder: choose after the REAPER laps.
- Cut 8's other-script case (up to 10 s) is the accepted risk of rt-perf's cut 8; shorten `dawview.FLOOR` if it shows.

## Review-later (security)

None. No check, size limit or trust rule changed. `mirror.applied` and `mirror.hinted` only count and read local project state.

## Re-check results (rt-r2, 2026-11-21 evening MT / 11-22 UTC, StudioSync 0.59.49.94 from 905f000 + extension 1.0.36 on the desktop, laptop, LinuxBox and LinuxBox2; Deafen 1 everywhere, no sound tests)

- **7.1 Cut 7: pass.** Colour parity off (`groups.set_colour_parity(root, false)` on the desktop, put back on after): status files written at
  02:14:30 and 02:15:28 UTC have no `look`; parity on: 02:15:58 has it (453 bytes). The lap name `status/colour look` still appears (0 ms) in a
  slowest tick's list with parity off. Health's row not looked at.
- **7.2 (5 minutes idle, Home page open, 10 samples 19:06:38-19:10:44 MT):** tick median 0.3-0.5 ms, p95 3.1-5.1 ms, slowest 39-72 ms (1-2 ticks
  over 50 ms per 10 s, each `drive/step` 20-53 ms plus `status/folder` up to 17 ms or `status/file` 7 ms); pass median 8-21 ms. Per 10 s:
  `start/webui` 65-99 ms, `drive/step` 92-135 (4-5 ticks), `start/liveaudio` 46-50, `cue check` 32-42, `listen, midi view` 21-33,
  `start/lock, follow file` 26-30, `start/hub` 10-17, `receive` 17-21. **status/**: `status/file` 6.6-30 ms a write (mostly 7-9: not ~2),
  `status/folder, name clash` 1.5-17, `status/colour look` 0 (not the largest on this 3-track song), `status/link send` 1. **link/**: clock 11-19,
  peers 7-9, messages 4-7, poll/ensure 3-5, heartbeat ~1, prune 1.4: 30-40 ms per 10 s together (less than the 60-90 expected for start/link).
  The biggest idle costs are `start/webui` (with a page open) and `drive/step`.
- 7.3, 7.5: not run (no throwaway studio for the heavy song). 7.4: not run.

**rt-fix7 (2026-11-21):** 7.2's `status/file` was the atomic write opening its .tmp again to measure it (Windows' scanner holds a just-written file): measured from the write handle now, and no doomed rename on Windows. Checks: `docs/rt/rt-fix7.md`.
