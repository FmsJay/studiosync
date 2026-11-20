# REAPER's Undo, then another edit: receivers wrong for minutes (rt-undo, "F5")

Found in the real REAPERs on 2026-11-20 (StudioSync 0.59.49.73; the desktop, the laptop and LinuxBox in "Cross Test"). On the desktop:
items inside a region cut (`Edit: Cut items`), REAPER's own Undo (40029), a ripple cut, Undo again. Afterwards:

- the laptop and LinuxBox showed the tracks as Keys, Rec A, Drums A; the desktop had Keys, Drums A, Rec A;
- 16:11:18: LinuxBox applied a ripple-all cut, and 5 s later logged "caught up on 11 changes that hadn't arrived here": the cut items
  were back, for about 2.5 minutes;
- 16:11:25: the desktop logged "caught up on 1 change" and took the others' track order, as a REAPER undo point "Change track order";
- 16:13:57: the desktop undid; the laptop logged all 11 changes and kept 2 items for 3 min 21 s;
- Health said "Changes from the others come out the same here" throughout.

## What the desktop sent was right

A native undo brings back an old state. It must go out as a new change, and it did. From the room's event files:

| Desktop time | Act | Each item's change |
|---|---|---|
| 16:10:04 | cut | deleted, rev 2004 |
| 16:10:23 | undo | back, rev 3005, built on the deletion (`base_ev`) |
| 16:10:42 | ripple cut (per track) | deleted, rev 4006 |
| 16:10:59 | undo | back, rev 5007 |
| 16:11:18 | ripple cut (all tracks) | deleted, rev 6008 |
| 16:13:57 | undo | back, rev 7009 |

Every step has a higher revision and a later clock than the one before, so every receiver takes it (`mirror.newer`). The first case of
the test checks this.

## Cause 1: `mirror.heal` read the shared folder only, and went backwards

`mirror.heal` brings a project in line with "the room's newest version of every object it doesn't hold". It took the room's changes from
`<room>/events` alone (`mirror.room_newest`), and applied the newest it found whenever its id wasn't the id held here. It never asked
whether what's held is newer.

Since 5f185fa (rt-look) every object change also travels as a message over the direct link, into the link's inbox, and is applied seconds
before Syncthing brings its file. `sync.receive` reads the inbox. Heal didn't. So for those seconds the folder's "newest" is the version
*before* the one just applied, and a heal in that window puts it back and records it as held. The newer events are already marked
applied, so nothing lands them again until the next heal, and Live sync heals at most every 5 minutes.

Two things start a heal in that window:

1. **An item landing over a deletion held here** (`mirror.heal_due`, 0.59.46): the receive pass ends with a heal. A native undo of a cut is
   exactly that, on every receiver, every time. The laptop at 16:13:57: receive applied the 11 changes ("11 changes from the others"), the
   heal at the end of the same pass found the deletions as the folder's newest, and deleted the items again. Its own Live sync heal put
   them back 3 min 21 s later (5 minutes after its previous one).
2. **Live sync's own heal** (`P.heal`: a caught-up bandmate's project has differed for 60 s). LinuxBox had differed from the desktop since
   16:10:23 (the first undo, rolled back as in 1), so its heal ran at 16:11:23. The ripple cut of 16:11:18 was there only in the inbox;
   the folder's newest was the undo of 16:10:59. Heal put those 11 versions back over the cut.

### Fix (`lib/mirror.lua`, `lib/direct.lua`)

- **Heal reads what receive reads.** `mirror.room_newest` now lists the link's inbox too (`direct.inbox_names`, new: the inbox of any studio
  this script started the link for, as `direct.path` already does for one file). A light event's state is read from wherever its file is
  when asked (`direct.path`), since an inbox copy goes once Syncthing's is here.
- **Heal never goes back to an older version.** An object is left alone when the version held here is newer (revision, then clock) than
  the settled one *and* wasn't among the changes heal could read (a merged version counts as read when all its parts were). That covers a
  change whose inbox copy is gone and whose file isn't here (a song not downloaded, a half-synced file). A version that was read and still
  isn't the settled one is a race the settled one won (a deletion over an edit that didn't see it), and that still lands.

Both are needed: the first makes heal judge races with everything this computer has received (case 3b below fails without it: a
deletion that came over the link, against a newer edit in the folder); the second holds when the newer change can't be read at all.

## Cause 2: a heal moved a track back under the track it once sat under

A track's version carries `after`, the track it sat under when that version was made. A track that only sits elsewhere since (another
track moved or added above it) isn't sent again, by design. So XT Rec A's newest change still said "under Keys" while it sat under
Drums A.

Its history also holds the same change several times: at 00:43 UTC on 2026-11-20 the laptop, LinuxBox and the Mac each sent the identical
follow-up to a recording (same revision, same base, same hash), and the Mac did the same twice earlier. That was before track changes were merged (rt-merge), so every computer kept one and
counted the others done. Heal's `mirror.settled` now sees those as changes made apart and gives the track a merged version with another
id: `m(James-…024821&m(LinuxBox-…&m(Chilio-Mac-…)))`. Run against the real event files, its content is identical to the plain newest
change. Each computer's heal, whenever it first ran, "caught up" on it, and `mirror.apply` moved the track under `after`:

- the laptop and LinuxBox at the first undo (16:10:23, the heal that ends that receive pass);
- the desktop at 16:11:25 (Live sync's heal, 60 s after the others began to differ), as a native undo point on top of "Cut items". The
  desktop's next Ctrl+Z undid the move, which then went out as the desktop's own track move (16:13:51).

### Fix (`lib/mirror.lua`)

Heal applies a track's version without moving the track when its `after` is the same as in the version held here (`mirror.STAY`, a table
key no event file can carry; `mirror.apply` honours it). A version whose `after` differs from the held one's still moves the track.
`sync.receive` is unchanged: a move a bandmate makes travels as before.

## Health

"Changes from the others come out the same here" was computed from one counter, ExtState `mirror drift <proj>`: `mirror.receive` adds 1
when a change, the moment it's applied, hashes differently here than its sender's hash. Live sync clears it when any caught-up bandmate
has the same project code. It missed F5 because:

- every change hashed the same when applied, and again when heal applied the older one (heal isn't checked at all);
- the desktop received nothing, so it had nothing to count;
- it never compares what two computers hold. Who's here did ("project differs from yours", by `mirror.root`), on another page.

Now:

- Live sync notes, each pass, who has every change yet holds another project code, or another track order (`mirror.apart_note`, ExtState
  `apart <proj>`). It needs nothing pending on either side.
- Each status now carries `order`, a code for the mirrored tracks' order (`mirror.order_code`). The project code doesn't hold track order,
  so two computers could agree on it with their tracks in another order.
- The Health row is red once the same difference has stood for 30 s (`mirror.APART_SECS`; the codes differ for a few seconds after any
  edit). It names who, and says what happens next: heal after a minute, at most every 5; or, for track order, reopen the project on the
  computer that's wrong.
- It's still only as good as the codes: two computers holding the same versions whose content came out different are caught by the drift
  counter alone, as before.

## Test: `tests/test_0_60_rt_undo.lua`

Three computers on the stand-in REAPER of rt-edits, with both deliveries: a link message into each computer's inbox (the real
`sync.take_event`) and, later, the file. A native undo restores the old chunks with the same GUIDs and ids.

| Case | On 0.59.49.73's code |
|---|---|
| A native undo goes out as a new change, newer than the edit it takes back | passes (the sender was right) |
| An undo that lands over the link stays, its files not in the folder yet (the laptop, 16:13:57) | fails: "Bee has 1 items, James has 5" |
| Live sync's heal doesn't put an older version back over a newer one from the link (LinuxBox, 16:11:23); nor when that change is readable nowhere | fails: the heal applied 4 |
| 3b. A heal knows a deletion that came over the link, against a newer edit in the folder | fails: the item comes back |
| A heal leaves a track where it is when its place isn't what changed; a real move still travels; a missed move is still caught up on | fails: "Keys, Rec A, Drums" |
| Health's row knows when a caught-up bandmate's project, or track order, isn't this one | new |

Taking out any one of the three parts of the fix (inbox, never back, stay) fails one case each.

## Files

- New: `tests/test_0_60_rt_undo.lua`, this doc.
- `lib/mirror.lua` (shared): `room_newest` and its light events, `heal`, one condition in `apply`'s track move, and the new `order_code`,
  `apart_note`, `apart_for`.
- Small additive edits in shared files:
  - `lib/direct.lua`: `direct.inbox_names`;
  - `StudioSync - Live sync.lua`: `P.heal` notes who's apart (3 lines), the status carries `order` (1 line), `apart` in the list of a closed
    tab's ExtStates;
  - `lib/page_health.lua`: the "same" row.

## REAPER check (after deploying to all three)

Cross Test, the desktop, the laptop and LinuxBox on this build, ripple editing off unless said.

1. On the desktop select the items inside the Verse region and run `Edit: Cut items` (40699). Wait until the others show the cut.
2. On the desktop run REAPER's Undo (40029, with your own cut on top of the list). Within about 2 s the laptop and LinuxBox have every
   item back, **and still have them 10 s later**. Track order stays Keys, Drums A, Rec A on all three.
3. Straight away (within 20 s), set ripple to all tracks and cut again. The others show the cut. Wait 90 s without editing: the items
   must not come back on any computer, and no log says "caught up on N changes that hadn't arrived here".
4. Undo on the desktop. The others get the items back and keep them. Wait 90 s again.
5. Throughout: no "Change track order" undo point appears on the desktop, and its Undo list has only your own edits on top.
6. Health (Settings > Health) stays green through 1-5 on all three. If any step does leave a computer wrong, look at Health on it 30 s
   after the last edit: the row "Changes from the others come out the same here" must be red and name the other computer.
7. Logs: no "came out different", no "caught up on" on any of the three.

## Untested / limits

- Everything ran against the stand-in. The inbox in REAPER is `<home>/direct/<studio id>/…`, listed through `direct.started`, which a script
  fills when it starts the link (`direct.ensure`: Live sync does, and any script that has posted a change). A heal run from a script that
  hasn't reads the folder only, as before; "never back" still holds there.
- A track move that never landed on a computer, and whose `after` is the same as in the track's version there, isn't put right by heal any
  more (it can't be told from a version that isn't a move). Opening the project does it (`mirror.keep_order`). `keep_order` only runs when
  a project opens; nothing puts track order right during a session.
- StudioSync's own Undo and Restore (`mirror.revert`) still move a track under its old version's `after`. Not part of F5; same stale
  `after`.
- `mirror.settled` still merges changes from before track merging that were only ever the same change sent by two computers. With this fix
  that's one quiet "caught up on N" per computer and track, with nothing moving. A merge with a real, different old loser would change
  the track everywhere, a day late.
- Heal's own changes still make undo points on top of your list when they do change something (not when they don't, as here).
- Health goes red only after 30 s of the same difference: during rapid edits (one every 19 s in the F5 run) it stays green until they stop.
- The web UI's Health and the phone weren't touched.

## Review-later (security)

- `order` in a status is a bandmate's string, only compared for equality and hashed into an ExtState key. The names in `apart <proj>` are
  status `user` strings shown in Health's text (as Who's here shows them).
- `direct.inbox_names` lists only inside the link's own inbox folder for the room; names go through `mirror.light_event`, which reads by
  `direct.path` (folder first). Event size and signature checks are the extension's, unchanged.
- `mirror.STAY` is a table key, so a received event can't set it.
