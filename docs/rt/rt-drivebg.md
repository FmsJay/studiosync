# The cloud copy off REAPER's thread (rt-drivebg, 2026-11-20)

The cloud copy's pass (`lib/drive.lua`, from Live sync's `P.save_drive`) listed the cloud drive's folders, read its files and copied to and
from it on REAPER's main thread: 223-273 ms a pass on the desktop and 963 ms on the laptop (rt-look, sections 6-7), every 2 s while a copy
caught up. rt-look's `sync.drive_quiet` only moved those stalls to pauses.

Now a background worker does every read, listing and write in the cloud folder. REAPER plans from the worker's listings and reads its
results. Measured on the desktop's REAPER (below): about 8-18 ms a tick, with no cloud call on REAPER's thread at all.

## How it works

**`lib/drivebg.lua` (new)** holds the worker, the job files and a file layer, `drivebg.C`, that `drive.mirror`, `drive.upkeep`,
`drive.tools_pass` and `cloudmodes.tick` now use for every file call:
- `drivebg.direct` does what the old code did, on REAPER's thread. It is the default, so a direct call to `drive.mirror` (the tests, and
  the fallback below) behaves exactly as before.
- `drivebg.planned` answers cloud reads from the worker's last listings (kept 30 s, as `drive.listed` was) and copies (`cache/`). It turns
  every write into a step of the next job, local writes too, so each runs in its planned order.
- A planner that reads a folder or file the worker hasn't read yet is stopped with `drivebg.NEED` at its first write, and at its end. What
  it asked for goes in the next job. Nothing is ever written on a half-read picture. `drive.mirror` asks for a room's ten folders, its
  people's plug-in chain folders and its take manifests in one go (`want_room`), so a room needs two or three jobs, not one per folder.

**The job files**, in `<temp>/bandsync-drive-<hash of the cloud folder>/`, as bgrender's jobs are:

| File | Written by | What's in it |
|---|---|---|
| `plan-<instance>-<n>.txt` | REAPER, whole (temp name, then rename) | `studiosync-drive 1`, then one step a line, `op TAB a TAB b TAB c` |
| `result-<instance>-<n>.txt` | the worker, whole | `step TAB ok [TAB size TAB mtime]` or `step TAB no TAB why`, then `end` |
| `lists/<hash>.txt` | the worker | `ok` or `none`, then `kind TAB size TAB mtime TAB name` a line |
| `cache/<hash>`, `stage/<hash>/...` | the worker | copies of cloud files REAPER reads (manifests, cloud-only changes, saved versions, session projects; the signed update files) |
| `owner`, `beat` | REAPER; the worker | the worker allowed to write (a token); its heartbeat: token, time, plan, step |

The steps are:
- `L dir out`: list.
- `C from to flags`: copy to `.syncthing.<name>.<n>.tmp` beside the target, check the size before and after, then rename into place. With
  flags `j`, only a file that reads as a whole JSON document (`{...}` or `[...]`).
- `M from to`: rename; or, when `to` already has it at the same size, drop `from`.
- `R path guard`: remove, only while `guard` exists.

After its writes, each job lists every cloud folder it wrote in, so the next plan sees what happened.

**The worker** is a PowerShell script on Windows and `/bin/sh` on macOS and Linux. Both are embedded in drivebg.lua, written to the job
folder, and started hidden through `services.run_hidden`, never waited for.
- It stays up and takes plans as they come, and stops after 60 s idle.
- It beats before each step, and each second while a copy makes progress (PowerShell copies 1 MB at a time; sh copies over 4 MB run in the
  background with a beat loop).
- It stops before its next step once `owner` names another token.
- At start it clears `cache`, `stage` and `lists` entries older than 7 days and results older than a day.

**Live sync** (`P.save_drive`, a small additive change):
- With `drive.bg_on()`, a due pass (same `pass_due` and `drive_quiet` gate as before) starts `drive.bg_step`.
- The pass then carries on every tick, edits or not, until it's done. Each tick: look at the job in flight (a file check, plus the
  heartbeat once a second); when none is out, plan up to 8 ms of units and submit a job.
- The units are each of the open song's rooms, then the other songs (`drive.upkeep`), the update files and the storage sweep.
- A sweep in progress keeps the pass going, a room or two a tick.
- Moved counts, `drive.landed` (media brought down: Syncthing rescans it) and the status come from the worker's results.
- The old synchronous block stays as the `elseif`.

**Failures:**
- **Stuck:** no heartbeat on a step for `OP_WAIT` (30 s). This covers a dead mount and a killed worker.
- **Stopped part-way:** another token took over.
- **Never started:** respawned twice, then given up on.

Each failure revokes `owner`, so a stuck worker stops before its next step, and drops every listing, so what happened is read again. Three
failures in a row put passes back on REAPER's thread (the old way) for 10 minutes, and that's logged. ExtState `"drive bg"` = `"off"` does
the same for good.

## The safety rules, kept

- **What's uploaded:** the same code decides, so `drive.mine`'s one-writer rule, media owners, tombstones, trimmed changes and
  `cloudmodes.filter` all apply unchanged. The stand-in test checks the planned pass ends byte for byte as the old pass, pass after pass.
- **Half files:** a cloud JSON file is brought down only if it reads as whole (`j` flag, a structural check: first and last non-space
  characters), and every copy is size-checked before and after and renamed into place.
  - *Weaker than before:* the old pass fully parsed a cloud JSON before copying it.
- **Removals:**
  - In the cloud folder, removals go to the service's own trash, as before (it's a file delete in the synced folder).
  - `cloudmodes`' planned removals refuse any path outside the cloud folder.
  - A leftover take is removed only while the right place has it (the `guard`), on either side.
  - Conflict copies are removed only while the original is there.
- **Never a delete by mistake:** a recording whose download is still queued, or failed, is not added to what this computer "saw" in its
  media (`cloud-media-seen.json`), so it can never be taken as deleted (tested with a download that fails).
- **One writer:** one worker per cloud folder on this computer. Every Live sync tab shares it, and plan names carry each tab's instance.
- **Signed update files:** the cloud's copy is checked in a local staged folder the worker copied it into, and what's brought into the
  studio folder is copied from that checked copy, not read again from the cloud. The usual update flow checks it all again before anything
  runs. Its post-copy check of the target moves to the next look.

## Tests

`tests/test_0_60_rt_drivebg.lua` (in `python tests/run.py`):
1. The protocol's pure parts: PowerShell and GNU/BSD `stat` listings, results, the plan text, a guard on removals, names with a tab refused.
2. One room through a stand-in worker (in memory, the same protocol). It ends exactly as `drive.mirror` on REAPER's thread does after one
   pass and after settling. **No cloud call on REAPER's thread** (counted). The storage sweep's reads are planned too. A download that
   fails is never taken as a delete.
3. A stand-in slow drive (each cloud call 25 ms): the old pass held the thread 2.7 s in one go (107 cloud calls). Planned, the worst tick
   was 1.0 ms and none touched the cloud.
4. The real worker scripts, started as Live sync starts them, on real temp folders:
   - the protocol: listed, read, copied both ways, the half-written file refused, moved, a removal refused without its guard;
   - a slow drive (0.25 s a step, a 2.7 s job): REAPER's look at it peaked at 0.4-1.8 ms;
   - stuck on a step, killed mid-job, and never started all handled;
   - three failures in a row turn the worker off for a while.

   PowerShell runs here. `/bin/sh` runs on macOS and Linux in the new CI workflow `.github/workflows/drivebg.yml`, and here through Git's
   sh with `DRIVEBG_SH=1` (protocol only: forks are slow on Windows).

Cloudmodes', media deletes' and cloud2's existing tests pass unchanged, all through `drivebg.direct`. `python tests/run.py --no-luals` ends
`fails 0`.

## Measured in REAPER (desktop, read-only)

Old reads on REAPER's thread, `G:/My Drive/StudioSync - Smiley Studios`, Cross Test/main:
- a folder listing: 0.2-13 ms each (events, 578 files: 6-13 ms);
- `_tools/studiosync/lib/files.txt` read: 11-20 ms;
- a pass touches 20-30 of these.

The new pass in this REAPER, through the repo's modules loaded in their own environment:
- every write step was dropped, so it only listed;
- the PowerShell worker listed the real Drive folders;
- ticks were 8-18 ms, with outliers of 36-42 ms;
- the outliers were the first read of the room's local changes (one big event JSON parsed in one go, or a GC step), not the cloud;
- that local read is the same one the old pass did, within its 0.1 s budget, once a session.

**Laptop not measured:** its ExtState has `drive_root=off` today, so its REAPER makes no cloud pass at all.

## REAPER checks for James (once deployed)

1. Desktop, Cross Test open, the copy catching up (add a 20 MB WAV to the room's media):
   - `tests/reaper/rt_perf.lua`: the "save, drive" lap stays under ~20 ms (was "drive 223-273");
   - `%TEMP%/bandsync-drive-*/` gets `plan-*`/`result-*` files and a `powershell` process while it runs;
   - the WAV reaches `G:/My Drive/StudioSync - Smiley Studios/Cross Test/rooms/main/media`;
   - Health shows "still copying" and then "up to date".
2. A bandmate's recording only in the cloud copy comes down. Syncthing rescans it, and no conflict copy appears.
3. Delete an unused recording here: the tombstone is written, and the cloud's copy moves to `_trash/media` (by the worker).
4. Kill the `powershell` worker mid-copy: within ~30 s the log says it stopped answering, and the next pass carries on. Three in a row: "passes
   run in REAPER again for 10 minutes".
5. Laptop with its cloud copy on (`drive_root` not `off`): the same lap check. That's where the 963 ms was.
6. Mac (sh worker): one pass completes; `$TMPDIR/bandsync-drive-*/worker.sh` runs and the media lands.

## Not done / untested

- **Not run in real REAPER end to end with writes** (read-only rule): the deploy checks above.
- **`sessionfile.catch_up`** (not my file) still copies end-of-session recordings to the cloud on REAPER's thread when it has pending
  ones. It's called at a pass's end with a 0.1 s budget, and its list is usually empty.
- **`streams.lua`'s cloud catch-up check** (`band.size` of a cloud file, only when nobody's on the link) is still on REAPER's thread.
  `drivebg.known_size(path)` answers from the worker's listing if that's wanted.
- **`drive.root`** looks at the cloud folder once every 5 minutes (one listing).
- **Spawn files:** each worker start leaves an empty `bandsync-drive-worker-<token>.txt` in the temp folder until REAPER quits
  (`services.tidy_temp`). There's about one start per pass, since the worker idles out after 60 s.
- **Two Live sync tabs:**
  - Two tabs starting a worker in the same instant: the later one wins, and the other's job fails once and is replanned.
  - A tab that quits mid-job leaves its result file for the worker's one-day tidy.
- **macOS:** the BSD `stat -f` branch runs only in CI. It has never been run against a real Google Drive File Provider folder.

## Review-later (security)

- Plans, the worker scripts and the cache sit in the per-user temp folder, as the other `run_hidden` scripts do. Another process of the
  same user could change a plan or a script (the same trust as every existing temp script).
- The worker trusts any path in a plan. A path sanity check in the worker (inside the studio folder, the cloud folder or its own job
  folder) would limit what a tampered plan could do.
- The `j` check is structural, not a JSON parse. A cloud file that is braces around garbage would come down, and is read (and refused) by
  `band.read_json` here as before.
- The worker's `slow` file (seconds a step sleeps) is a test hook. It is read only at start, from the job folder.
