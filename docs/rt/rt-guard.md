# rt-guard: no deletion without a deletion behind it, and moving windows isn't "editing" (2026-11-27)

From James's findings (docs/rt/findings-2026-11-27.md: the track-deletion bug from docs/rt/rt-reopen.md, and "Says someone is editing when
they're only moving windows around"). Code: `lib/mirror.lua` (W.gone, mirror.watch, mirror.on_open), `lib/follow.lua` (a small change in
another agent's file: `follow.claim_of`, `follow.drag_spot`, `follow.down_on_project`, two lines in `send_editing`). Tests:
`tests/test_0_60_rt_guard.lua`, the soak's new `reopen` edit (`tools/soak/node.lua`, `tools/soak/soak.py`).

## 1. The track-deletion bug (Cross Test, 11-23)

**Cause.** `W.gone` sent a deletion for every object record (`BandSync.mirror` ProjExtState) whose object the look didn't see. Nothing asked
whether a person deleted anything, so any look at a project that held the studio's records without its objects deleted them for everyone.
Two ways that happens, both reproduced against 3ffc001:

- **A. A project read with its records and none of its tracks** (closing or loading in the tab Live sync runs in; Live sync's edit count
  moves with it, so even "was there an edit" said yes). The 11-23 evidence fits it: deletions built on the newest records, no `was_after`
  (the look's track list was reset, as a first look's is), 13 changes in 75 ms. The test sends 3 tracks and 4 items on HEAD.
- **B. A file opened whose records name objects it doesn't hold**, at REAPER's start (and in Autostart's `sync.preload`, which calls
  `mirror.watch` with no `edited_at`, so every look there counted as an edit) or opened again in the same tab (Live sync keeps running, and
  its edit state and last look were the old project's). The soak's new `reopen` edit: seeds 3 and 4 of `--quick` send deletions on HEAD.

Which of the two happened on the desktop at 10:56 is still not established (rt-reopen's B, "something on the desktop deleted them with an
undo point", would look like a real deletion and still go: see below).

**Fix (W.gone).** A deletion goes out only with something to show this person made it, here, in this session:

1. **Not a new opening.** `mirror.on_open` now says when a project is opened (this script's first look at it, or a new master track: a file
   opened again in the tab). Then `mirror.watch` forgets the old project's edit state (`mirror.edit_seen`, so the load's edit count isn't
   "you edited") and its last look (`mirror.looks`, so the first look is a full one), and the guard's marks.
2. **An edit of this person's behind the look**: `w.edited ~= false` (`mirror.user_edited`: Live sync's count moved by them in the last
   30 s, or a new undo point of someone's on top since the last look), the same test auto-claims use.
3. **A project with no tracks at all** also needs a new undo point of someone's on top since the last look (REAPER's own "Remove tracks"),
   whatever the edit count says. Without it nothing is sent and nothing is changed for `mirror.EMPTY_SECS` (10 s: it may be closing or
   loading); if it stays empty, the studio's tracks are put back. *Deviation from the brief, on purpose:* the brief said "sends nothing";
   deleting every track is a real workflow (cross test step 1, `tests/test_0_60_rt_delete_race.lua`), so a delete-all with REAPER's undo
   point fresh on top still goes.
4. Otherwise the object is **put back from the band's last version** (`W.put_back`, as a refused deletion is; a track's items and parts come
   back with it) and one line is logged (at most once a minute per project): "N track(s) or item(s) of the studio's weren't in this project,
   with no deletion of yours behind it ...". Nothing is sent.

Each absence is judged once, on the look that first misses it (`mirror.gone_why`: "user" or "not", per project and object), so a burst
spread over passes and a deletion held for a claimer's answer go as first judged, even if nobody edits in between; a mark goes when the
object is seen again, put back, settled as gone, or the project is opened again.

**What stays as it was:** a track or item deleted by hand (also the top track, which resets the look's track list: the brief's suggested
`w.first_here` would have refused that one, so the guard uses the master track instead), a deletion made while the project's tab is behind
another, REAPER's own Undo of a track deletion bringing it back for everyone (rt-converge 14 and rt-guard 4), Redo deleting it again, a
deletion held for a claimer and sent on Release (rt-guard 5), StudioSync's Undo and Restore (mirror.revert sends its own deletions).

**Known limits (review later):**
- A deletion made while Live sync wasn't running is put back when it starts (it can't be told from an older file).
- A delete-all whose undo point appears on a look that `W.keep_held` ends early: the point is used up, and the empty project is put back
  after 10 s. Rare; the person deletes again.
- Something on the computer that deletes with an undo point (a script, an agent's test: rt-reopen's B) is a real deletion to this guard.
- Put-back tracks land where `apply` puts them; the order heal sets the order after an opening (as for any put-back).

## 2. "Says someone is editing when they're only moving windows around"

**Cause** (`lib/follow.lua`, the live "<name> is editing" signal: the "[editing: name]" region, the track tint, the panel's line and the web
Project page's "Bo is editing ..."): `send_editing` counted the mouse held for 0.3 s as a drag of whatever was selected, and
`JS_Mouse_GetState` is the whole screen's button. Dragging any window's title bar or edge, a docker splitter or another program's window,
with a track selected (almost always), said "James is editing Bass". And a plug-in or MIDI editor window counted for 120 s after it
*opened*, so opening a plug-in window and moving it about said "editing plug-in X on Bass" for two minutes.

**Fix:** the held mouse counts only when it was pressed on the arrange view or a track's panel (`follow.down_on_project`: REAPER's
`GetThingFromPoint` says "arrange", "tcp...", "mcp..."; anything else, or a REAPER without it, isn't a drag), and an open editor counts only
while you change something (`follow.claim_of`: `changed_ago < IDLE`, not the time since it opened). Real edits count as before: the project's
change count moving (CHANGED, 2 s) and a drag begun on the project.

Not changed: edit holds (`presence.touch` in W.send) only come from changes that went out, and window positions were already kept out of
what's sent (FX_LOCAL, track state). Unverified: whether REAPER moves `GetProjectStateChangeCount` for a window move or dock change (if it
does, the CHANGED path would still say "editing" for 2 s: the REAPER re-check below tells).

## Tests

- `tests/test_0_60_rt_guard.lua` 1 (A) and 2 (B, REAPER restarted and same tab) fail on 3ffc001; 7 (follow) too; 3-5 pin what must keep
  working.
- Soak: `reopen` edit (weight 1): the project saved without one or two of its tracks and loaded again as a new opening; node.lua raises an
  error if that computer posts a deletion before its next edit. Adding the edit changes every seed's sequence.
- Results: see the report (suite in a clean clone, local time and TZ=UTC0; 10-minute `--long` soak before and after).

## REAPER re-checks

In docs/rt/rt-reopen.md, "rt-guard: REAPER re-checks".
