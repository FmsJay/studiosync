# What Live sync costs REAPER (rt-perf)

Measured on the desktop's REAPER (7.86) on 2026-11-21, 01:55-02:11. StudioSync 0.59.49.78, extension 1.0.31. Live sync was running in
Cross Test (Smiley Studios), with four computers in the room and the desktop as the song's hub. This note only measures and proposes; no
product code changed.

Three cases:
- **small**: Cross Test as it is. 4 tracks, 10 items, 2 plug-ins, 245 records, 2,487 event files in the room.
- **heavy**: rt-bigproj's generator with `big_every = 0`, so stock JSFX only and no missing-plug-in box. 150 tracks, 520 plug-ins,
  4,000 items (60 MIDI, 72,000 notes), 25,800 envelope points. Opened in its own tab, in no studio, never saved, then deleted.
- **heavy + plug-ins**: the same tab with real plug-ins added, 688 in all:
  - ReaEQ and ReaComp on 69 tracks;
  - Surge XT Effects on 19;
  - 12 synths: Vital x4, Surge XT x3, Odin2 x2, Dexed x2.
  None of them opened a dialog.

## How it was measured

- **Live sync's own timings** (small case only): ExtState "perf stats" on, then "tick stats" read every 10 s. That gives tick and pass
  median, p95 and slowest, plus the slowest tick's laps. It only gives the worst tick's laps, so a part's cost per run comes from the laps
  of worst ticks and from the timings below.
- **Each part timed in REAPER**: the same lib modules loaded fresh from the worktree into the probe's own Lua state, run against the tab in
  front (`p1_parts`, `p6_looks`). For the heavy cases this is the only way: Live sync doesn't run on a project outside a studio, as in
  rt-bigproj.
- **Main-thread stalls**: a deferred probe recorded the gap between its own runs (normally ~31 ms). It also logged every new
  "slow tick" (over 150 ms) that Live sync wrote meanwhile. That shows which stalls were Live sync's and which were not.
- **REAPER's threads**: CPU time per thread over the window, read from outside. The main thread is the first one started.
- **The edit**: track 1's volume +0.1 dB with one undo point, then set back to the exact value it had (1.0) with another.

Probes and raw logs: the agent's scratch folder `rt-perf2/` (p0-p15, `window.sh`; see the session's report).

## The table

"% of one core" = the part's milliseconds per second of wall time on REAPER's main thread. With Cross Test in front, REAPER's whole main
thread ran **17-20 % of one core** while idle. With the big project in front it ran 26-28 %, most of it REAPER drawing its own UI.

| Part | When it runs | small: ms a run | heavy: ms a run | heavy + plug-ins: ms a run | small idle, % of one core | heavy idle (est.), % of one core |
|---|---|---|---|---|---|---|
| Every tick, the base ("start" lap: link poll, controllers, web UI, hub, follow...) | ~32 a second | median 1.0-1.4 (whole tick), p95 4-7 | same (depends on the studio, not the project) | same | **~3-4** | ~3-4 |
| Quick look, nothing changed (lap "look") | on change, else every 10 s (6 a minute) | 1-2 | scan alone 65-77 | scan alone **104-109** | <0.1 | ≥0.7 / ≥1.1 |
| Quick look after one small edit | each edit | **21-35** (pass 45-54, tick 75-84) | 42-48 (one selected item moved) | **63-74** | (editing) | (editing) |
| Full look (scan + W.one on everything) | every 60 s | 10-15 | scan alone 144-161, W.one not measurable | scan alone 180-193 | <0.05 | ≥0.4 |
| Colour parity's look (`colours.look`, in each status write, held 5 s) | 2-4 a minute idle, up to every 5 s editing | 0.05 | 23-32 | 28-31 | ~0 | 0.1-0.2 (0.6 editing) |
| Heal / in line (`mirror.root`, `order_code`, `apart_note`) | each pass (30 a minute) | 0-9 (root 0.16) | root 11-13 | root 10-11 | <0.1 | **0.55-0.65** |
| Receive, nothing arriving | each pass | 3-5 | (studio-sized) | | 0.2 | 0.2 |
| Presence (claims, pings, paint) | each pass | 0-1 | (studio-sized) | | <0.05 | <0.05 |
| Status (who, info, write) | each pass; file or message every 15-30 s or on change | 1-2; **10-32 when written** | + colour look above | | 0.1-0.2 | 0.2-0.4 |
| Web feeds: presence model (`sync.authority` 0.8-1.6 ms) | every 1 s while a page looks (2 clients were connected) | ~1 | ~1 | ~1 | 0.1 | 0.1 |
| Web: Project page look (`dawview`, spread at 3 ms a tick) | each change-count move, ≤4 a second, and every 10 s, while a page shows the Song page | 0.04 (first 8) | **40-45**, with build 57-66 (first 410-470) | 43-45, with build 53-65 | ~0 | 0.4 idle; **16-25 while editing continuously** |
| Web: Mixer strips (+ JSON when the mix changed) | every 0.25 s while open | 0.015 | 2.1 (+3.5) | 2.1-3.0 | ~0 | 0.85 |
| Hub work (`hub.tick` every 2 s; restore point) | restore point ≤ every 30 min, idle | restore point 15 ms (last one) | not measured | | ~0 | ? |
| Cloud copy (lap "save, drive") | in the slowest tick of **every** 10 s window | **15-76** | same (room-sized) | same | 0.2-1.5 | 0.2-1.5 |
| Redraw after a look (`TrackList_AdjustWindows` + `UpdateArrange`) | after every look, idle or not | 7-10; **16-24 when a heavy tab is in front** | (front tab's cost) | | 0.1 | 0.2-0.3 |

The whole of Live sync on small, idle: ticks 320 per 10 s, median 1.0-1.1 ms, p95 3.8-5 ms, slowest 33-50 ms. Passes 5 per 10 s,
median 7-9 ms, slowest 15-20 ms, not counting the cloud copy. That is **about 4-6 % of one core**, roughly a quarter to a third of
REAPER's busy main thread, and almost all of it is the per-tick base, not the looks. The estimate uses the medians: rt_perf has no means.

REAPER's own reads at the heavy size:
| Read | heavy | heavy + plug-ins |
|---|---|---|
| Every track's chunk | 36-45 ms, 5.0 MB | **58-66 ms, 6.5 MB**; slowest track 5.4 ms, 641 KB |
| Every item's chunk | 44-47 ms, 4.3 MB | same |
| `mirror.root`, 4,752 records | 11-13 ms | 10-11 ms |

The `mirror.root` row settles rt-bigproj's question: `EnumProjExtState` is linear. The first 1,000 and the last 1,000 records cost the
same, 0.3-0.5 ms.

What one plug-in adds to its track's chunk, and to every read of it:
| Plug-in | Size added | Time added |
|---|---|---|
| ReaEQ, ReaComp | 0.4-0.5 KB | nothing measurable |
| Surge XT Effects | 1.8 KB | 0.04-0.09 ms |
| Dexed | 8 KB | 0.1-0.24 ms |
| Odin2 | 64 KB | **1.9-2.4 ms** |
| Surge XT | 66 KB | **2.3-2.8 ms** |
| Vital | 229 KB | **2.5-2.7 ms** |

The cost is the plug-in serialising itself, not the bytes: Surge XT costs as much as Vital at a third of the size. Twelve synths and 19
effects added ~20 ms to every every-chunk read.

## Where the time goes in the worst three

**1. The Project page's look while editing on a heavy song (only while a page shows the Song page).**
- Each change-count move costs a whole read of every track and item, 40-45 ms, and the build 15-20 ms more. That happens up to four
  times a second.
- It's spread at 3 ms a tick, so it causes no stall. The total is still 16-25 % of one core while you edit continuously.
- Nothing in it knows which tracks changed. `dawview.read` walks every track and item each time.

**2. The looks on a heavy song.**
- **The every-chunk read every 10 s** is 104-109 ms with real plug-ins. About 62 ms of it is REAPER serialising 6.5 MB of chunks; the
  synths are the slowest tracks.
- **Every quick look also reads every MIDI track and all its items, edit or no edit.** REAPER writes `POOLEDEVTS {guid}` into every MIDI
  item's chunk, pooled or not. Probe 13: 60 MIDI items, 60 with POOLEDEVTS, 60 distinct GUIDs, so none is really pooled.
  `lib/mirror.lua` takes the token as "pooled" (lines 2146, 2586, 2663, 2675, 2678). So every track holding MIDI is always read and
  worked out in full. Here that is 6 tracks, 3.1 MB with the synths, and 60 item chunks of 2.4 MB.
  - That is why "one selected item moved" read 9 tracks and 90 items, not 1 and 31.
  - It is ~25-30 ms of the 63-74 ms an edit's look takes.
- **The full look every 60 s** runs a quick scan first (the safety net), then a full scan (180-193 ms), then W.one on every object.
  That's a single stall of well over 300 ms once a minute on a heavy song, idle or not. The safety net found nothing in 297 looks today
  ("missed 0").

**3. The idle base cost, on any song, heavy or small.**
- **Every tick, ~32 a second, costs ~1 ms median before any pass.** That is about 3-4 % of one core per song tab, the largest idle cost
  measured. It's all inside the "start" lap. Which of the ~15 sub-ticks costs what can't be split today, because perf stats keeps only
  the worst tick's laps. In the "start" lap:
  - `direct.live_tick`, `controllers.tick`, `signed.drain`, `needlist.tick`;
  - `ablink`, `liveaudio`, `hops`, `claimask`;
  - `webui.tick`, `hub.tick`, `bounces`, `follow`;
  - `sharedprefs`, `calibrate`.
- The same lap holds **the rare long stalls while idle**. Live sync's recorded slow ticks:

  | Time | Tick | "start" lap |
  |---|---|---|
  | 21:48:56 | 549 ms | 548 ms |
  | 01:46:22 | 169 ms | 145 ms |
  | 02:06:38 | 238 ms | 237 ms |
  | 02:10:34 | 170 ms | 126 ms |

  None of them was a restore point (the last one took 15 ms, at 01:58:50).
- **The cloud copy never settles.**
  - ExtState "drive status" stayed `{"more":true,"moved":0}`, rewritten every 30-60 s.
  - So `drive_more` keeps `drive.pass_due` true. With the background worker on, each pass plans another round on REAPER's thread:
    `drive.bg_step` → `drive.mirror` over a room of 2,487 event files.
  - Its lap is 15-76 ms, in the slowest tick of every 10 s window measured, both today and in rt-perf's log from 22:03 yesterday. It
    moves nothing.
- **A redraw after every look**, changed or not: 7-10 ms. Live sync in a tab behind also calls `UpdateArrange`, which redraws the tab in
  front: 16-24 ms with the big project in front.

## Proposed cuts, ranked (expected saving, risk)

1. **The cloud copy's endless round.**
   - Find why `drive.bg_step` keeps answering "more" with 0 moved. It's likely a unit that never reports done: the `cm` sweep, or a room
     whose files keep failing.
   - Back off to `drive.EVERY` after a round that moved nothing.
   - Saves 15-76 ms per pass that plans: 0.2-1.5 % of one core on every song, and the recurring 40-90 ms idle ticks.
   - Risk low: the backup copy waits up to 3 minutes, which is already its schedule while editing.
2. **Real pooling, not the POOLEDEVTS token.**
   - Count a track as pooled only when a POOLEDEVTS GUID appears on two or more items in the project. One pass over the MIDI items'
     GUIDs; an item's GUID set only changes on a look that reads it.
   - Saves ~25-30 ms on each quick look here, ~40 % of an edit's look. More with more MIDI tracks or heavier synths on them.
   - Risk low-medium: a real pool's mates must still all be read. `tests/test_0_60_rt_look.lua` needs a pooled case and an unpooled-MIDI
     case.
3. **Split the per-tick base, then thin it.**
   - First, make perf stats keep per-lap sums and counts over each 10 s, not only the worst tick's. That's a few lines, zero risk, and
     it says which sub-tick owns the ~1 ms and the 126-548 ms "start" stalls.
   - Then run the sub-ticks that only poll at a lower rate when nothing arrived: web UI actions, follow, hub, bounces, needlist. 10 Hz
     instead of ~32.
   - Expected 1.5-2.5 % of one core per song tab.
   - Risk medium: controllers and link messages need their current latency, so leave `direct.live_tick` and `controllers.tick` at full
     rate.
4. **Redraw only when it helps.**
   - Skip `t.redraw` after a look that sent 0, put nothing back and wrote nothing.
   - Skip `TrackList_AdjustWindows` and `UpdateArrange` when this tab isn't in front, and redraw once when it comes to the front.
   - Saves 7-24 ms per look (~7 a minute). Removes Live sync's redraws of another tab, which took 165-374 ms when the desktop was under
     memory pressure.
   - Risk low.
5. **Fewer full looks on heavy songs.**
   - Scale `QUICK_FULL_SECS` with the look's own time, e.g. `max(60, mirror_took * 600)`, or run the safety net every 5 minutes.
   - Saves a 300+ ms stall a minute (≥0.4 % of one core) on a heavy song; nothing on a small one.
   - Risk: a quick look's miss takes longer to be caught. It's counted and logged, and was 0 here.
6. **Hold `mirror.root` between passes.**
   - Key it on the project change count plus a counter that `mirror`'s own record writes bump, with a 10 s floor for anything written
     elsewhere.
   - Saves 10-13 ms a pass on a heavy song: 0.5-0.65 % of one core.
   - Risk low-medium: records written by the panel's Restore or Undo in another script show up within the floor, unless they bump the
     counter too, which they can through ExtState.
7. **Colour parity's look only when it's used.**
   - `sync.write_status` builds it on every status write (lib/sync.lua:2234), even with the studio's Colour parity off.
   - Skip it when `colours.parity(cfg.root)` is off. Otherwise follow the change count with a 30-60 s floor.
   - Saves 23-31 ms per status write on a heavy song.
   - Risk low: a colour set by a script with no undo point shows up within the floor.
8. **The Project page: read only changed tracks.**
   - Reuse the quick look's per-track fingerprints (`mirror.track_fp`, ~1 ms for 150 tracks) to skip unchanged tracks in
     `dawview.read`. Keep the 10 s whole read as the net.
   - Saves most of the 16-25 % while editing with the page open.
   - Risk medium: a change the fingerprint can't see stays stale on the page for up to 10 s. Edits under a drag already wait.
9. **The status write's 10-32 ms.**
   - The disk part is ~2 ms (`band.write_atomic` of 2.4 KB on J: 1.4-1.8 ms; the folder check 0.2 ms; free disk 0.05 ms). JSON is
     0.1 ms. The status file isn't a signed kind.
   - So the rest is in the link send (`direct.msg`: `ensure`, `peers`, `StudioSync_DirectMsg`) or in gathering `info`. Split it with
     cut 3's per-lap sums before changing anything.

## What I could not measure

- **Live sync running on a heavy song.** That needs the project published into a studio, which a scratch project must never be. So:
  - there's no real tick or pass distribution for heavy;
  - the heavy costs above are parts timed in REAPER with Live sync's cadences applied by hand;
  - W.one's share of a full look, and an edit's event write, sign and send, are not in the heavy numbers.
- **Inside a tick**, Live sync publishes only the slowest tick's laps. How often the cloud copy plans comes from "it's in every
  window's slowest tick", not from a count. The ~1 ms per-tick base isn't split. The parts that consume queues or send weren't run in
  the probe: web UI actions, link messages, hub and controllers ticks.
- **Means.** Shares of the main thread use medians and p95s. rt_perf has no means.
- **Not covered:** playing, recording, the laptop, LinuxBox and the Mac. A real heavy session's undo history. Plug-ins that need a
  licence: Pro-Q 3, Serum and Kontakt were left out on purpose.
- **Anything after 02:11:40.** At 02:11:32 another process (`llama-server`, 6.7 GB, started outside this task) began running. After it:
  - REAPER's working set fell to 104 MB of 916 MB private;
  - its main thread ran deferred scripts only every 3-21 s;
  - Live sync managed 1-18 ticks per 10 s, with `UpdateArrange` taking 165-374 ms.

  This isn't StudioSync's doing. Those windows (the end of `idle_long.log`, all of `idle_final.log`) are left out of the table.

## REAPER's private memory (~770-920 MB)

| When | Private memory |
|---|---|
| With Cross Test alone | 817 MB |
| Big project open | 2,143 MB (+1.33 GB) |
| With the real plug-ins | 3,215 MB (+1.07 GB; the 12 synths are most of it) |
| After closing it | 916 MB (~100 MB not handed back, as heaps usually keep) |

StudioSync's Lua side is small:
- The modules, loaded fresh in a probe's state, take ~2 MB.
- The look's memo for the 150-track project takes 30-35 MB, freed when unloaded.
- On Cross Test, Live sync's state should be a few MB.

The extension's own heap (link buffers, the web UI server, live audio, which is deafened) can't be seen from outside, and nothing
reports it. So of the ~800 MB, StudioSync's Lua is likely under 20-30 MB. The rest is REAPER, the plug-ins, other scripts' ReaImGui
contexts and the undo history. To know the extension's share, it would have to report its own allocations, for example in
`StudioSync_DirectStatus`.

## State left

- Cross Test in front, unchanged: track 1 volume 1.0 exactly, as before the nudge. Change count 20, moved by 2 for the nudge pair and
  by 1 by something else around 02:01, not by me. Still dirty as it was. Never saved, never played. Live audio still deafened.
- Live sync still running (its "live" stamp under 0.15 s old). "perf stats" off again.
- The scratch tab closed without saving, by "REAPER Query" → No. Its .rpp and the AutoSaves .rpp-bak REAPER wrote for it are deleted.
  The earlier `StudioSync Big Test.rpp` and `big_silence.wav` were left as they were.

## Review-later (security)

None. Measurement only.
