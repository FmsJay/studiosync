# rt-fixlive3: sync2i's lost mute was the live tool, not StudioSync (2026-11-28)

On 0.65.3 (90ab61e), desktop plus LinuxBox. No `lib/` change, nothing deployed, no version bump.

## Summary

- **Not a StudioSync bug.** sync2i ran in the wrong song. It never imported `SONG`, and `live.py run` then used its old default,
  "SS Test Project 112326". That song's room is in **Claims** mode (`mode.json`: `"open"`). "LV Checks" is **Open** (`"everyone"`).
- In Claims mode the desktop's move auto-claimed the track for 600 s (`sync.AUTO_IDLE`). LinuxBox's mute 17 s later asked James to release
  it. Nobody answered, so 30 s later LinuxBox put its own mute back, as designed.
- Once it ran in "LV Checks", i4 got past the mute and hit a second bug in the test: it looked for the desktop's move row with
  `rev > 1`. The move came 18 s after the item was made, inside `mirror.SESSION_SECS` (30 s). So it kept rev 1, as one edit with the making
  (by design: "one edit, however many nudges"). The test now picks the row built on an earlier version (`base_ev`).
- Third bug in the test, which made i4 flaky (it failed 2 of 3 full runs): i4 took the item's id from the first look after making it.
  `both` reads the desktop first and LinuxBox second. Sometimes the desktop had the item before Live sync's first look gave it an
  id (`P_EXT:band_oid` empty), and LinuxBox had it by the time it was read (the direct link is that quick). The id read was `''`, and no
  History row matched. Proof: one run noted "the item's id read when it was made ('') isn't its id now ('I-JAMES-...174242-325102')".
  i4 now reads the id after the mute. i2, which also kept the id from its first look, now waits for an id too.
- sync2i: **4 of 4 pass** on desktop and LinuxBox (results below).

## Evidence

The reports `sync2i-20261128-094545.json` and `-095910.json` both say `"song": "SS Test Project 112326"`. Every other set's reports say
"LV Checks". `live.py` line 429 was `song = args.song or getattr(mod, "SONG", "SS Test Project 112326")`, and sync2i imports neither
`SONG` nor anything else that carries it.

The room modes, read live through `sync.mode` / `sync.authority` on both computers:

| Song | Desktop | LinuxBox |
| --- | --- | --- |
| LV Checks | `everyone` (Open) | `everyone` |
| SS Test Project 112326 | `open` (Claims) | `open` |

LinuxBox's own log shows the same three steps in every failed try: 16:40, 16:42, 16:48 and 16:50 UTC.

```
16:50:07 [live SS Test Project 112326] James: changed an item on LV i1UndoRedoofyo U      <- the desktop's move
16:50:25 [live SS Test Project 112326] asked James to release LV i1UndoRedoofyo U: your edit waits here for their answer (up to 30 s)
16:50:55 [live SS Test Project 112326] Not sent: James didn't answer about LV i1UndoRedoofyo U in 30 s. Your edit is put back ...
```

That explains why LinuxBox read `m: 0` itself. It also explains why the 0.65.2 run failed the same way (same song), and why i2 and i3
passed: no bandmate edits an item there, and the tempo map isn't claimed.

The i4 row, from History's entries for the item of the failed i4 try (`I-JAMES-20261128170918-125637`):

| Time (UTC) | Who | rev | base_ev | What |
| --- | --- | --- | --- | --- |
| 17:09:18 | James | 1 | (none) | made |
| 17:09:36 | James | 1 | 17:09:18's | moved: same edit, inside 30 s |
| 17:09:54 | LinuxBox | 2 | 17:09:36's | muted |

## Fixes (tools/live only)

- `live.py`: a set without `SONG` runs in "LV Checks". `up` defaults to it too.
- `sets/_lv.py` `setup`: refuses to run (reads "no answer") when the song's room isn't Open. Checked live: run against "SS Test Project
  112326", i1 stops at once with "room is set to 'open' (on disk: 'open' is Claims), not Open ('everyone'): refusing to run".
- `sets/sync2i.py` i4: picks the move's row by `base_ev`, not `rev > 1`, and reads the item's id after the mute, not from the first look.
  When no row is found, it now lists the item's rows. i2 waits for the desktop's item to have its id before keeping it.
- README: the Open-room rule is in the Safety list.

## Desktop restart (lower priority)

**Probable cause, not proven** (the failed try's `rp_restart.log` was overwritten by the retry). `restart_and_test.ps1` started REAPER
with `& $Reaper -nonewinst restart_reaper.lua`, and `restart_desktop.ps1` pipes that script's output. With its output piped, PowerShell
waits for that reaper.exe to exit. Every other wait in the two scripts has a limit, and together they come to about 380 s. So a 400 s
timeout with the old REAPER still open and "[modified]" fits this case: a `-nonewinst` launcher that never handed the script over, either
stuck or turned into a second REAPER, with `restart_reaper.lua` never run in the real one. The tool met this second-REAPER case before
(11-20).

- `restart_and_test.ps1`: the launcher is started with `Start-Process` and gets 30 s. After that, a stray launcher of ours (seconds old,
  no project) is stopped and the log says so. The existing "quitting" check then fails fast.
- `live.py restart`: the desktop is tried once more when the first try doesn't say "desktop restarted", or times out.
- Checked: `live.py restart --on d,x` took 64 s, with the normal log (quitting, closed, back, installer). The stuck case wasn't reproduced.

## Live results

| Run | Song | i1 | i2 | i3 | i4 |
| --- | --- | --- | --- | --- | --- |
| before (`sync2i-20261128-095910`) | SS Test Project 112326 | fail (mute put back) | pass | pass | fail (mute put back) |
| default song fixed (`-101133`) | LV Checks | pass | pass | pass | fail ("no row": rev > 1) |
| i4 row fixed, i4 alone (`-101531`) | LV Checks | | | | pass |
| after the restart, full set (`-102626`) | LV Checks | pass | pass | pass | fail, both tries ("no row") |
| i3 + i4, with the row list (`-103258`) | LV Checks | | | pass | fail ("no row; its rows: (none of 2242)") |
| i3 + i4 (`-103755`) | LV Checks | | | pass | pass |
| full set, with an id check (`-104514`) | LV Checks | pass | pass | pass | pass: the id read when made was `''` |
| final code, full set (`-105318`) | LV Checks | pass | pass | pass | pass (all first try) |

At the failed check in `-103258`, 2242 event files were in the folder (by birth time), and History read 2242 entries. So the listing was
complete and included the item's three events. Only the id was wrong.

## Not verified

- The stuck restart itself: its log was gone, and the fix is from reading the code.
- The laptop (it was off): all runs used `--on d,x`.
- i4's Restore said "bringing back 624 changes". `mirror.revert` counts every object in the plan, not what changes, and the slice's end
  said "1 change(s) brought back". The song was empty afterwards (0 tracks, 0 items on the desktop). This wasn't looked into further.
