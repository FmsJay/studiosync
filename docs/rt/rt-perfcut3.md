# Live sync's idle base, per sub-tick, and the cloud copy's slow "up to date" (rt-perfcut3, 2026-11-21)

rt-perf's cut 3, now that the tick's laps can be measured (rt-perfcut1, rt-drive2).

## 1. The measurement (desktop, read only)

StudioSync 0.59.49.81 in REAPER on the desktop, realtime Live sync in Cross Test (one tab), idle, nobody editing. Perf stats on at
07:05:39, "tick stats" read every ~10 s for 44 windows (07:05:55-07:13:06, 7.3 minutes), then perf stats off again (07:13:29,
`DeleteExtState("BandSync", "perf stats", false)`). Probes in my scratch folder `rt-perfcut3/` (`read_`, `on_`, `off_`, `time_`, `hub_`,
`sum_rt-perfcut3.*`); read only otherwise.

Ticks: 320 per 10 s, median 0.70-0.80 ms, slowest 62.9 ms. Per lap, averaged over the 44 windows (ms per 10 s / 100 = % of one core):

| Lap | ms / 10 s | % of a core | ms a run | worst ms |
|---|---|---|---|---|
| start/link | 191.6 | **1.92** | 0.599 | 15.3 |
| start/liveaudio | 35.1 | 0.35 | 0.110 (2.2 a run at its 2 Hz) | 41.8 |
| start/lock, follow file | 25.3 | 0.25 | 0.079 | 29.3 |
| start/follow | 18.7 | 0.19 | 0.058 | 13.1 |
| listen, midi view | 18.7 | 0.19 | 0.058 | 15.9 |
| status | 17.4 | 0.17 | 3.49 | 30.0 |
| cue check | 17.3 | 0.17 | 0.054 | 36.1 |
| receive | 15.6 | 0.16 | 3.13 | 12.5 |
| start/hub | 9.8 | 0.10 | 0.031 | 9.9 |
| start/webui | 8.8 | 0.09 | 0.028 | 4.1 |
| start/controllers | 8.3 | 0.08 | 0.026 | 0.8 |
| who | 8.0 | 0.08 | 1.60 | 22.5 |
| look | 7.1 | 0.07 | 7.08 | 43.7 |
| save, drive | 7.0 | 0.07 | 1.40 | 48.6 |
| start/hops | 4.5 | 0.04 | 0.014 | 0.4 |
| start/claimask | 3.1 | 0.03 | 0.010 | 4.6 |
| start/needlist | 2.2 | 0.02 | 0.007 | 5.7 |
| start/shared prefs | 2.1 | 0.02 | 0.007 | 1.0 |
| start/clip, together | 2.0 | 0.02 | 0.006 | 0.6 |
| start/plug-ins, takes | 1.9 | 0.02 | 0.006 | 0.4 |
| start/signed | 1.5 | 0.01 | 0.005 | 4.2 |
| start/bounces | 1.2 | 0.01 | 0.004 | 0.2 |
| start/calibrate | 0.9 | 0.01 | 0.003 | 0.6 |
| start/ablink | 0.8 | 0.01 | 0.003 | 0.2 |
| (the rest: transport, colours, joins, timeline, in line, claims, start, redraw) | 9.4 | 0.09 | | |

The start lap's sub-ticks: **318 ms per 10 s, 3.2 % of a core**; every lap 418 ms, 4.2 %. Last round's 170-200 ms of `start/link` is the same
here (192). No 31-47 ms `start/hub` tick in this window (worst 9.9 ms).

**Why `start/link` cost ~2 % idle** (timed in REAPER's eval host against the deployed modules, `time_rt-perfcut3.lua`):
- `services.my_device_id()`: **0.305 ms a call**. Each call looks for syncthing.exe (up to ten `file_exists`), reads Syncthing's answer file
  and decodes its JSON. `direct.keep_clock` asks it every tick: ~1 % of a core alone.
- The clock JSON: `StudioSync_DirectClock()` starts with `"now":<this instant>`, so the "decode once while it reads the same" cache never
  hit: decoded every tick, 0.048 ms (471 bytes, one peer).
- The rest (~0.25 ms a tick on average) is periodic: the peers' refresh every 2 s, `DirectStart` and the inbox prune every 10 s.

**`start/hub`'s 31-47 ms ticks**: hub.tick runs every 2 s by itself; its once-a-minute look lists the room's events (5.9 ms the first time,
cached after) and the recall folder (0.6 ms), its 10 s scan calls `band.songs` (5.3 ms on the desktop) and reads the status files (2.9 ms).
A 31-47 ms tick is the song hub's restore point (`recall.save`, every ≥30 minutes while idle; the 06:59:04 one is the snapshot of item 3).
That's real work, not waste: left as it is.

## 2. The cuts

**The polling sub-ticks at their own pace** (`StudioSync - Live sync.lua`: `SUB_EVERY`, `sub_due`, one `tnow` read in `tick_body`).

| Sub-tick | Rate | Why |
|---|---|---|
| link (`direct.live_tick`) | every tick | the link's receive: changes, cues, presence, chat |
| controllers | every tick | faders and knobs you move go out live |
| liveaudio | every tick (paced 2 Hz itself) | live audio's controls |
| ablink | every tick (paced 10 Hz itself) | tempo and start/stop with Link apps |
| hops | every tick | live hops (another agent's; audio-related) |
| webui | every tick | a page's live keys, the phone's Record page, transport from a page |
| hub | every tick (paced 0.5 Hz itself) | already slow; its cost is its runs |
| clip, together | every tick | Play together and the clip check while playing |
| lock, follow file | every tick | the tab's binding and owner checks (safety); the lock and file are paced 5 s |
| follow | 10 Hz | following a bandmate's view (they send 5 a second), your edits looked at 10 a second anyway (`follow.LOOK`) |
| claimask | 10 Hz | the panel's Release / Keep answer, asks running out (30 s): 100 ms is unseen |
| signed | 10 Hz | signed studio files written here go to those here: 100 ms on top of Syncthing's seconds |
| bounces | 4 Hz | the panel's bounce ask; its own work is paced 2 Hz |
| takes | 2 Hz | Show all takes in lanes when the setting changes; the plug-in lists' look is every 2 minutes |
| needlist | 1 Hz | catch-up's media ask, every `needlist.EVERY` or when who's here changes |
| shared prefs | 1 Hz | paced 1 s itself; a tab coming to the front gets its studio's prefs within a second |
| calibrate | 1 Hz | paced 1 s itself (`cal.EVERY`) |

**The link's base** (`lib/direct.lua`, `lib/services.lua`):
- `clock_json` drops the leading `"now"` before the decode cache (nothing in direct.lua reads it). Decoded when an estimate changes (about once
  a second a peer), not every tick.
- `services.my_device_id` keeps an ID it found for `services.MY_ID_KEEP` (10 s). A nil answer isn't kept. This also helps every other caller.

**Expected saving** (from the table and the timings): link ~0.35 ms a tick → ~110 ms per 10 s (~1.1 % of a core); the paced sub-ticks
~32 → ~8 ms per 10 s (~0.25 %). Together **~1.3-1.4 % of one core per song tab**, the start lap from ~3.2 % to ~1.8-1.9 %. Not measured
after the change (no deploy here).

## 3. The cloud copy's 3.7 minutes for 2 files (06:59:04 → 07:03:19)

Read from the desktop's log, the worker's job folder and the cloud folder:
- The two files (`recall/` and `recall/known/20261121-135904Z-James-hub_snapshot.json`) were **in the cloud at 07:00:23** (their mtime on
  `G:`): 79 s after the snapshot. "Bringing ..." at 06:59:35 is SOON (30 s) after the snapshot went out.
- "Up to date (2 files)" came at **07:03:19**, right after the worker listed Nostalgia's ten room folders (07:03:09), and the next case the
  same way: the 07:04:37 end-of-session file was in the cloud at 07:07:17, "up to date" at 07:07:25, right after the update files' listing
  (07:07:19).
- **Cause:** `drive.bg_step` said "up to date" only once *every* copy unit of the round was done and no job at all was out: this room, but
  also the other songs (`upkeep`) and the update files (`tools`), and the storage sweep's jobs kept `sent` true. Each of those needs a few
  listing round trips through the worker, one plan per Live sync pass, so the status said "still copying" for minutes after this room's
  copies were back. The other rounds took 2-30 s because nothing else in them was due.
- **Fix (`lib/drive.lua`, small):** "copied" now means the open song's rooms are done and none of them planned a write in this plan (a plan is
  only made with no job out, so every copy they planned has come back). The other songs, the update files and the sweep go on in the round as
  before; their moved files are told the next time ("up to date (N)"), and the round still ends only when all its units are done.
- **Test 3i** (`tests/test_0_60_rt_drivebg.lua`): a settled copy, a hub snapshot written, another song that wants 40 plans and a sweep that
  sends a job every plan. Now: "up to date (2)" in the same plan the files are in the cloud, the other song still reading; the round ends
  after it without resting. The old drive.lua: 41 plans later (checked).

## Tests

- `tests/test_0_60_rt_perfcut3.lua`: the schedule loaded from Live sync's text (each paced sub-tick 0.1-1 s, the link, controllers, live
  audio, Link, hops, web UI, hub and Play together not paced; 10 s of 31 ms ticks: follow ~10 a second, bounces ~4, needlist 1, the link 320;
  each paced name gated once in tick_body; the unpaced ones called unconditionally); the clock decoded once in 101 reads whose `now` moves,
  again when an estimate changes; the device ID read once in 300 calls, again after `MY_ID_KEEP`, a non-ID never kept. Each part fails without
  its change (checked against HEAD's files).
- `tests/test_0_60_rt_drivebg.lua` 3i (above).

## REAPER checks for James (desktop, after deploy)

1. Cross Test open, Live sync running, idle: `tests/reaper/rt_perf.lua` twice 30 s apart, then over ~5 minutes. Expect
   - `start/link` about 60-90 ms per 10 s (was 170-200), its worst still ~15 ms;
   - `start/follow` ~5-6 ms per 10 s with ~100 ticks (was ~19 ms, 320 ticks); `start/claimask` and `start/signed` ~100 ticks; `start/needlist`,
     `start/shared prefs`, `start/calibrate` ~10 ticks; `start/bounces` ~40;
   - the start lap's sum ~180-200 ms per 10 s (was ~320). Then `OFF = true` in rt_perf.lua (or `DeleteExtState("BandSync", "perf stats", false)`).
2. Follow a bandmate (panel: Follow) while they scroll and select: the view and selection still follow smoothly; their editing region shows
   within a moment.
3. A claim ask from the laptop: Release / Keep on the desktop's panel still answers at once.
4. Health: the shared clock line and the direct link rows unchanged (same reference, offsets moving).
5. Make one edit in Cross Test while another song is in the studio: "Google Drive copy up to date (N files this pass)" within about a minute
   of "bringing ...", not 3+ minutes; `G:/My Drive/StudioSync - Smiley Studios/Cross Test/rooms/main/events` has it.

## Left

- The rest of `start/link` (~0.25 ms a tick): the peers' refresh every 2 s (presence, trust, access, nat), `DirectStart` every 10 s, the inbox
  prune every 10 s. Split it with sub-laps inside `direct.live_tick` before changing anything.
- `start/liveaudio`: 2.2 ms a run at its 2 Hz, worst 42 ms (its status JSON decode is 0.3 ms; the rest is the peer and vouch merges). Not
  touched: live audio's controls.
- `band.songs` costs 5.3 ms on the desktop (hub's scan every 10 s, `songsync.here` in each cloud plan, listen, webhome...): a short cache would
  save a little everywhere.
- `start/lock, follow file`'s 29 ms worst is the lock file's write every 5 s on J: (a disk hiccup).

## Review-later (security)

None: no check, size limit or trust rule changed. The device ID memo keeps only a valid ID, 10 s.
