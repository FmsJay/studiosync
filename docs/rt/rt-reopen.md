# rt-reopen: Cross Test's three tracks deleted at 10:56 on 2026-11-23

Stopped early (usage limit). **No code changed, no tests written or run.** This file holds the evidence read so far, what it
rules out, where the deletions are sent from, the fix I'd make, and how to get Cross Test back. The cause is **not established**:
the suspected one (an older .rpp reopened, its missing tracks read as deletions by the first look) does not fit the evidence as
it stands.

## What the evidence shows

Read only, on the desktop, nothing run on the test computers.

1. **The 13 changes** are `rooms/main/events/James-20261123-175607Z-00120` to `-00132` in
   `J:\Portable Workstation\StudioSync Smiley Studios\Cross Test\`: one act (`James-20261123175607-833078`), 3 tracks `gone`
   (XT Keys C `T-CHILIO_MAC-20261119215830-18823`, XT Drums A `T-JAMES-20261119215726-10590`, XT Rec A
   `T-JAMES-20261120003033-10538`) and their 10 items `gone`, all by `James`, written within 75 ms.
2. **Each deletion is built on the newest version**, not an old one. The tracks' `base` / `base_ev` are 9055, 16066 and 15060 on
   `James-20261123-034414Z-00097/98/99`: the desktop's own changes of 20:44 MT the night before. So the project in REAPER's
   memory at 10:56 held last night's records for all 13 objects, and none of the objects.
3. **The .rpp on disk is not that project.** `Cross Test.rpp` was last saved 2026-11-19 15:11:30 (44,960 bytes). It contains
   XT Drums A and XT Keys C with their ids (`band_oid`) and their records at **rev 1** (for example
   `T-CHILIO_MAC-20261119215830-18823 1|4b07cf56|Chilio-Mac-20261119-215830Z-00001-7564`), and not XT Rec A. A first look at that
   file would see two of the three tracks present, and would have no rev-9055 record to build a deletion on.
4. **The track deletions carry no `was_after`.** `W.gone` writes it from the look's remembered track order (`w.order_was`); last
   night's deletions (20:44) have it. Not followed further.
5. **The log has no Live sync start at 10:56.** `logs/studiosync-2026-11-23.log` has `live sync for 'Cross Test' (host, room main,
   driver James)` at 13:07:14, 13:17:28 and 13:19:26, and no such line (nor an `[autostart]` one) at 10:56. The lines there are
   `10:56:07 live audio on`, `10:56:07 13 change(s) went to the others`, `10:56:12 REAPER's audio device wasn't running ... opened
   it again`. The line before is 03:07:11, from a Live sync that was already running.
6. `reopen.json` is only the list of tabs to open again (`{"tabs":[{"band":true,"front":true,"path":".../Cross Test.rpp"}],
   "loadlastproj":18}`, written 13:17:26). It says nothing about 10:56.
7. REAPER's autosaves in `...\REAPER\StudioSync\Cross Test\AutoSaves\`: `Cross Test-2026-11-22_2047.rpp-bak` has 4 tracks and
   10 items, with XT Keys C, XT Drums A and XT Rec A. `Cross Test-2026-11-23_1322.rpp-bak` has 0 tracks, 0 items and the records
   only. There is no autosave between them.

## What that rules out, and what is left

**Ruled out as described:** "REAPER started, opened the 11-19 .rpp, and the first look read tracks the file lacks as deletions."
Objects the file lacks have no record in the file, and `W.gone` only looks at records; the two tracks the file has would be seen.
Records are given back from `<project>.bandsync-ids.json` only for a track that is present without its id (`settle_ids`).
So rt-converge's change to the reopen marks (07c44bf, `if not w.first_here then ... mirror.reopened[k] = nil`) is not shown to be
involved. I did not read that commit's diff.

**Left, not told apart:**

- **A. A look read the project while it had no tracks but still had its records**: REAPER closing or loading a project in the same
  tab under a Live sync that kept running (item 5; the 11:17 line says "REAPER was closing the project"). `W.gone` then sent every
  record as a deletion. If the 11-19 file loaded after that, its two tracks at rev 1 would be deleted again by the desktop's own
  rev-9056 events, which matches the empty project.
- **B. The tracks really were removed from the open project at 10:56:07** by something other than a person at the screen (a
  script or an agent's test on the desktop).

Next evidence to read: when REAPER's process started that morning, what ran on the desktop at 10:55-10:57 (rt-r7's re-check
notes), the 03:07-10:56 stream trace, and `git show 07c44bf`.

## Where the deletions are sent

`lib/mirror.lua`, `W.gone` (about lines 6131-6260 at a01a648). It lists every record in the project's `mirror.SEC` state with a
rev and a non-empty hash whose object the scan didn't see, and for each one this person may change it posts
`{ type = "obj", gone = true, base = g.rev, base_ev = g.evid, ... }` through `sync.post`. Nothing there asks whether a person
deleted anything: "the record is here and the object isn't" is the whole test.

## The fix I'd make (not written, not tested)

In `W.gone`, before the branch that posts a deletion, require evidence of a deletion made by this person in this session, as
auto-claims already do:

- not the project's first look (`w.first_here`), and
- `w.edited ~= false` (`mirror.user_edited`: this person's edit count moved, or a new undo point of theirs is on top), the same
  pair line 5968 already uses for a track's read-back.

Without it the object is not deleted for the band: it is put back from the band's last version (`put_back(o, g.rev, g.evid, ...)`,
as a refused deletion is), said once ("this project was opened without its last save ..."), and nothing is sent. Two things to
check when writing it: REAPER's own Undo and Redo of a track delete (bug C) put a user undo point on top, so `w.edited` should
stay true for them; and a look that finds **no tracks at all** while records exist should send nothing whatever `w.edited` says
(candidate A).

Tests it needs, failing on HEAD: records present, objects absent, first look: 0 sent, objects back from events; the same on a
later look with no edit of this person's; a real delete (undo point "Remove tracks") still goes out; bug C's test still passes.

## Was the laptop right to apply them at 13:19?

From the events, yes: they are ordinary deletions by James, each one rev above the newest version, so any computer that receives
them applies them. That is not a second instance. The laptop's own log was not read.

## Getting Cross Test back

**The 11:17 end-of-session version is very likely the wrong one**: it was saved 20 minutes after the deletions, and the
13:22 autosave of the same project has no tracks. I did not open that version to confirm.

Versions from before 10:56 that should have the tracks:

- Restore > Saved versions: the end-of-session version of **2026-11-22 21:05** (Drive copy `20261123-040526Z-James-main.rpp`).
  Not opened to confirm.
- REAPER's autosave `J:\Portable Workstation\DAW\REAPER\StudioSync\Cross Test\AutoSaves\Cross Test-2026-11-22_2047.rpp-bak`:
  confirmed to hold the three tracks and 10 items. Keep a copy of it before anything else.

Restore on one computer with the others connected, and check all three afterwards. I did not check how Restore sends a version
that brings back objects deleted at a higher rev.

## Recommendations

1. Don't release until `W.gone` has the guard above with its tests: today any look that sees an empty project deletes the song
   for everyone.
2. Find out what happened on the desktop at 10:56 (A or B) before trusting the fix to cover it.
3. Save the test projects once after a session, or copy the 20:47 autosave now: the only .rpp of Cross Test on disk is four
   days old.

## REAPER re-check (once the fix exists)

Close REAPER on the desktop without saving Cross Test, start it, let the 11-19 `Cross Test.rpp` open, start Live sync: the log
shows no "change(s) went to the others" for deletions, the events folder gets no `gone` event from this computer, and tracks the
file lacks come back from the events. Then delete a track by hand: it goes to the others. Then Ctrl+Z: it comes back for
everyone.
