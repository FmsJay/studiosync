# Two people editing one thing at once (rt-merge)

James, 2026-11-20: "For this maybe both can go through depending on the edit, like 2 people can edit a midi item at the same time, adding
different notes and such. But in cases where editing at the same time wouldn't make sense then do the 3s or warn only (see what other similar
apps do and which is better)".

**Result:** both edits go through and are merged, finer than before. Where they can't merge (the same setting, the same note, a deletion
against an edit), StudioSync **warns only and the later change wins**, everywhere the same. There's no hold any more: the 15 s "X is editing
that right now" put-back is gone.

## 1. What similar apps do

| App | Two people on one object | Sources |
|---|---|---|
| **Figma** | No locks. The server keeps the latest value per property per object: different properties of one object both survive; the same property, last write wins. A client ignores incoming values that clash with its own unacknowledged edits (no flicker). Deleting an object removes it with all its properties; the deleter keeps it in their undo. Undo is designed so undo, then redo, leaves the document as it was. | [Figma: How Figma's multiplayer technology works](https://www.figma.com/blog/how-figmas-multiplayer-technology-works/) |
| **Google Docs** | No locks. Operational transformation merges concurrent edits character by character; each client applies its own edits at once and transforms others' against them. | [Google Drive blog, 2010: What's different about the new Google Docs](https://drive.googleblog.com/2010/09/whats-different-about-new-google-docs.html) |
| **CRDT editors (Automerge, Yjs)** | No locks. Different properties merge cleanly. The same property: one value deterministically "wins" on every computer (by operation id, not wall clock), and the losing values stay readable. Concurrent list inserts are all kept. | [Automerge: Conflicts](https://automerge.org/docs/reference/documents/conflicts/) |
| **Soundtrap (Spotify)** | Live Collab: everyone sees changes in real time, no sync button. I found no public description of locks or per-note merging. | [TechCrunch, 2022](https://techcrunch.com/2022/08/09/spotifys-soundtrap-app-for-musicians-introduces-live-collaboration-and-auto-save/), [Soundtrap blog](https://blog.soundtrap.com/collaboration) |
| **Audiotool** | Several people edit one cloud project at once and see changes as they happen. Keyboard undo covers only your own changes; owners can roll back others' changes in History. No public conflict rules. | [Audiotool: Collaborate](https://www.audiotool.com/collaborate) |
| **BandLab Studio** | Shared projects with near-real-time collaboration; sources disagree on true simultaneous editing, and none describe conflict rules. | [audeobox guide](https://www.audeobox.com/learn/bandlab/bandlab-collaboration-features/) |
| **Ohm Studio** | Marketed as everyone editing one project simultaneously, with undo/versioning; no public description of how clashes resolve. | [MusicRadar review](https://www.musicradar.com/reviews/tech/ohm-force-ohm-studio-590570), [Sonic State](https://sonicstate.com/amped/2013/10/16/-real-time-collaborative-daw/) |
| **Steinberg Nuendo/Cubase networking** | Locks: "Get exclusive access" to a track before editing it. | [Steinberg help: Locking tracks](https://archive.steinberg.help/nuendo/v8/en/cubase_nuendo/topics/networking/networking_tracks_loading_c.html) |
| **Pro Tools Cloud Collaboration** | Track-by-track upload/download, not live co-editing; a session-level "Prevent Others from Overwriting Open Session". | [Production Expert](https://www.production-expert.com/home-page/2016/3/25/pro-tools-125-cloud-collaboration-covering-a-session-to-a-project-and-setting-up-collaboration-tools), [Sound on Sound](https://www.soundonsound.com/techniques/part-2-cloud-collaboration-pro-tools-125) |
| **Ableton Live** | No shared editing: Ableton says to open a synced Live Project from one system at a time. Link / Link Audio share tempo and audio, not the set. | [Ableton: Best practices for collaborating remotely](https://help.ableton.com/hc/en-us/articles/360012680119) |
| **Satellite Sessions (Mixed In Key), Audiomovers** | Each person streams their own tracks or audio into the others' DAWs; nobody edits the same object. | [Mixed In Key: Satellite](https://mixedinkey.com/satellite/collaboration-with-ableton-live/) |

**What this says:**
- Every tool built for live co-editing (Figma, Docs, CRDT editors, the browser DAWs) uses **no locks and no holds**. It merges as finely as it
  can, resolves what can't merge deterministically (last writer wins), and shows presence.
- Locks (Nuendo) and turn-taking (Pro Tools, Ableton) belong to slow, file-based sync. They're what the 15 s hold imitated when StudioSync
  took seconds per change.
- Nobody that publishes their design uses a short timed hold. A hold puts back work the person can see they did, and at 0.25 s delivery the
  clash it prevents is already resolved by the time it fires.

**Picked: merge finely, then warn only, last change wins.** Reasons:
1. It's what the live tools do, and changes now arrive in about 0.25 s (docs/rt/rt-look.md).
2. Nothing is lost. The loser is told at once, with **Use mine**, and their version stays in History and on the Restore page.
3. The live "<name> is editing" tint (lib/follow.lua) already warns within about 100 ms, before you touch it.
4. A hold blocks work and puts back an edit you can see you made, which is worse than a clear "theirs stands, Use mine".

## 2. What merges now

Two changes are merged when they were made apart: neither computer had the other's change when it made its own. This uses the same
machinery items had since 0.58 (`mirror.merge_for`, `mirror.apart`, merged versions rebuilt the same way on every computer as `m(a&b)`),
now for more kinds and finer pieces (`mirror.MERGES`).

| What | Merged by | Both changed the same piece |
|---|---|---|
| **MIDI notes** (`mirror.merge_midi`, inside `mirror.merge_item`) | note: a note-on with its note-off, keyed by channel, pitch and start. Other events by tick, status and first byte; SysEx/text by tick and data; the end of the source as one piece | the winner's note stands; the other is told |
| **Item settings** (`mirror.merge_item`, as before) | each line of the chunk: volume, mute, fades, name, colour, take lines... Position, length, offset and rate move together | the winner's |
| **Track settings** (`mirror.merge_track`, new) | each setting: name, volume, pan, mute, colour, icon, folder depth, the rest of `track_state`. Lanes (count, which play, names, mode) move together | the winner's |
| **Automation** (`mirror.merge_env`, new) | each envelope by its name, each point by its time, each other line by its word | the winner's point |
| Plug-in chains | not merged | the later chain stands, the other told (as before) |
| A deletion against an edit (items) | `mirror.gone_race`, as before: the deletion wins over an edit made without seeing it, whichever is newer | deleted everywhere |

"The winner" is the newer change by `mirror.newer` (revision, then the shared clock, then the name), so every computer agrees.

**What the loser sees.** "Bo changed the same thing as you on an item on Keys: theirs stands where you both changed it, and the rest of
your change is in", with Use mine (it brings all of yours back). Both always get "Bo changed an item on Keys as you did, at the same time:
both changes are kept" in the log. Before this, two people writing notes into one MIDI item got the loser's notes as a second take named
"Bo's version". Now that only happens for audio both re-recorded, or MIDI that can't be read as notes.

**Undo after a merge** (`mirror.undo_keeping`, `lib/undo.lua`). One Ctrl+Z takes back only your own change in that item, track or
automation. What a bandmate changed since, and you didn't, stays. It works by a three-way merge with your change as the base. rt-edits'
one-act undo is kept: the plan is still `mirror.plan_undo_moment`, and only each planned version's state is merged. Where both of you
changed the same piece, going back stands, as before (the Undo box still asks, now saying "what they changed stays, unless it's what you
changed").

## 3. The hold is gone; the warning stays

- `lib/mirror.lua` W.one: an edit to something a bandmate changed in the last `presence.HOLD` seconds isn't put back. It goes out, and the
  log says once every 30 s "Bo is editing that item too: both changes go in, and where you both change the same thing the later one
  stands".
- `presence.HOLD` 15 → **3** s (`lib/presence.lua:10`, the only line changed there). It now only says how long a changed object counts as
  being edited, in the status file's `editing` list. That list drives the track tint in `lib/people.lua` and the warning above.
- The web Project page, its MIDI and automation editing, and the phone DAW no longer refuse "X is editing that item/the automation right now"
  (`lib/dawedit.lua` item_why, `lib/dawmidi.lua` auto_apply, `lib/phonedaw.lua`). The web page shows "<name> is editing" through follow's live editing message, as before.
- **Kept:** the mouse/drag gate (`mirror.watch` waits for the drop), `sync.seen_mine`, the per-object "unsent edits" wait in
  `mirror.receive` (Figma's rule: an incoming change waits while your own to the same thing hasn't gone yet; the two then merge), claims,
  room modes and permissions.
- `lib/sync.lua` receive: a bandmate's change made apart from a newer one is no longer marked "older news" for tracks and automation either
  (`apart`, now `mirror.mergeable`). Before this, the older of two crossing automation changes was dropped on the computer that had the newer.

## 3b. Claims mode: a bandmate's auto-claim asks only for a clash (fix after the first REAPER check)

**What failed** (Cross Test, 0.59.49.70, "XT Keys C"'s first MIDI item, p48 only): in the same wall-clock second the desktop added p84 and
the laptop p86. Both computers ended with p48 and p86. The desktop's log shows what happened:
1. 13:16:56: the laptop's change landed first. Its look sent it, and rt-claims' Claims mode made XT Keys C the laptop's **auto-claim**.
2. 13:16:57: the desktop's look saw its own note, built on the laptop's version (so there was nothing to merge), and asked the laptop to
   release XT Keys C (rt-claims' ask).
3. 13:17:27: nobody answered in 30 s, so the desktop's edit was put back.

The merge code never ran, and the chunk REAPER wrote parses fine (`merge_midi` reads it). The studio folder has no desktop event for that
second, only the laptop's.

**The rule now.** James asked for both: two people adding different notes to one part both go through (rt-merge), and editing what someone
claimed asks them (rt-claims). They meet at auto-claims, which every edit makes in Claims mode. So:
- An edit held back **only by a bandmate's auto-claim** goes out when it touches no piece that bandmate changed lately in the same item,
  automation or track. Different notes, other points, other settings, or something they didn't touch all go through.
- An edit to a note, point or setting they changed is still asked for, as rt-claims does. **That includes setting it back to what it was**
  (second fix, below), and deleting a note they added.
- "Lately" is as long as an auto-claim lasts: their changes to it in the last 10 minutes (`sync.AUTO_IDLE`), every one of them, not only the
  newest. An item they made in that time is all theirs (new notes in it still go through).
- A lasting claim (one claimed by hand) still asks for every edit.
- Plug-in chains and the timeline don't merge, so they're still asked for.
- `claimask.soft(who, name, pos, user)` gives the claimer when the deciding claim is someone else's auto-claim (`claimask.which` now
  carries the claim's `auto`).
- `mirror.pieces(kind, state)` cuts a state where the merges cut it: an item's lines (place, length, offset and rate as one; each note and
  MIDI event its own), a track's settings (lanes as one), automation's envelopes, points and lines.
- `mirror.clashes(room_dir, kind, state, from, user)` walks from `from` (the version the editor's computer held) back through the versions
  each started from, collects the pieces the claimer's recent changes changed, and says whether the edit (`from` → `state`) changes any.
- Sender: `mirror.watch`'s W.one, through `opts.soft` from Live sync, sends instead of refusing (W.refuse, the ask) when nothing clashes.
- Receivers: `sync.receive`'s `refused` takes the same rule through `sync.soft` (Live sync's, its own room only), judged from the change's
  own base as its sender judged it. Without it, the change would wait a minute as "refused, maybe a claim on its way" before landing.
- The web Project page and the phone still go by rt-claims' ask for an auto-claimed track. They have no state of the edit before it's made.
- Test: `tests/test_0_60_rt_merge.lua`, "Claims mode". With Keys as James's auto-claim, the laptop's different note goes out and lands on
  the desktop at once. The laptop changing James's own new note is still refused.

**Second fix (REAPER check, 0.59.49.72): putting back what the claimer changed slipped past the ask.** The desktop, holding an auto-claim,
set an item's volume 0.9 → 0.5; the laptop set it back to 0.9 and it went straight out, silently undoing the desktop's change (0.7 asked
correctly; the same with an unmute after a mute). `mirror.clashes` used the three-way merge, whose base is the state before the claimer's
change, so a value equal to that base didn't count as a change. It now compares pieces directly, as above: what the claimer changed from the
version they started from, against what the editor changed from the version their computer held. Tests: the volume set back, another
volume, an unmute after a mute, the claimer's earlier change set back, the claimer's new note deleted, an item the claimer just made (all
refused); a setting the claimer didn't touch, and the same set-back ten minutes later (both sent).

**In practice (REAPER check 7):** in Claims mode, two people moving one item about half a second apart get the **ask**, not "theirs
stands". The first move lands and auto-claims the track before the second look, so the second move is an edit to the piece the claimer just
changed. "Theirs stands" with Use mine shows only when both went out before either arrived, or in Open, where there are no claims.

## 3c. Refusal words by mode (`mirror.refusal_words`)

The REAPER check found Driver only saying "Not sent: James is driving and XT Drums A is nobody's: claim it to edit it." Those were Driver +
claims' words (a mode rt-claims removed); in Driver only a claim doesn't count. W.refuse's words now come from one function, by mode:

| Mode | Whose claim holds there | Words after "Not sent: " |
|---|---|---|
| Driver only | anyone's or nobody's (claims don't count) | only the driver (James) edits in this room (Take control, or ask them to set Who controls to Claims) |
| Claims | someone else's | X is claimed by Bo: ask them to release it (reached only when the ask can't run; otherwise rt-claims' ask words) |
| Claims, Admins only | someone else's, sent as a suggestion | X is Bo's, so it's sent to them as a suggestion |
| Admins only | someone else's | X is claimed by Bo: ask them to release it, or an admin to give it to you |
| Admins only | nobody's | only admins, and whoever an admin lets edit here, change what nobody has claimed in this room |
| Open | (nothing is refused for whose it is) | it isn't yours to change right now (a fallback only) |

A claim by the driver now reads as a claim ("claimed by James"), not as "James is driving and it's nobody's". "claim it to edit it" is gone
everywhere: no mode left makes an unclaimed thing yours by claiming it except Admins only, where the claim has to be given.

## 4. Files

- `lib/mirror.lua`: `mirror.side3`, `merge_midi`, `merge_env`, `merge_track`, `MERGES`, `mergeable`, `merge_state`, `undo_keeping`.
  `merge_item` calls `merge_midi` for a take's `<SOURCE>`. `merge_for`, merged versions (`event_file`) and `settled` (heal) take any
  mergeable kind. Receive's wording now covers tracks and automation. W.one warns instead of putting back.
- `lib/sync.lua`: one line in `sync.receive`'s `apart`.
- `lib/undo.lua`: `undo_keeping` per planned object; the box's wording.
- `lib/presence.lua`: `HOLD` only (it reached HEAD inside rt-roomlist's 8091554, which committed the shared working file).
  `lib/dawedit.lua`, `lib/dawmidi.lua`, `lib/phonedaw.lua`: the hold refusals removed.
- Tests: `tests/test_0_60_rt_merge.lua` (new), `tests/test_mirror.lua` (the MIDI case now merges note by note; the take-copy rule is checked
  with audio), `tests/test_0_60_rt_dawedit.lua`, `test_0_60_rt_dawmidi.lua`, `test_0_60_rt_phonedaw.lua` (not refused),
  `tests/test_0_59_48_engine.lua` (a refused edit is copied only when selected: the hold's exception went).

## 5. Tests (`tests/test_0_60_rt_merge.lua`)

Two computers in the editreaper stand-in. Each edits, both send before either receives, then both receive and must read the same:
- two different notes added to one MIDI item: both stay, in time order, no extra take;
- one Ctrl+Z on each side after that: only that person's note goes;
- one note's velocity changed by both: the same velocity everywhere, the loser told, no extra take;
- envelope points: one adds a point and deletes another, the other changes a third and adds a fourth: all four outcomes kept;
- an item moved on one and turned down on the other: both. Then Ctrl+Z on each side: each takes back only their own, ending as it began;
- a track renamed on one and turned down on the other: both;
- both moved one item: one place everywhere, the other told;
- an item deleted on one while edited on the other: deleted everywhere;
- an edit to an item a bandmate is editing: sent, not put back, said;
- the merges on their own, including a 4,000-note part (about 120 ms in lupa; REAPER's Lua is faster).

The bigreaper fixture times single-computer looks and receives. A merge only runs on a crossing change, so the 4,000-note timing above is the
size check, not bigreaper.

## 6. Untested / limits

- **A note moved by both** (or moved by one and changed by the other) keeps both copies. A move is a remove plus an add, and there are no
  note ids in a chunk. Deterministic and nothing lost, but you may see a doubled note. The same holds for an envelope point moved on one side
  and changed on the other.
- **Pitch change = a moved note** (the key includes the pitch).
- MIDI with CC lanes drawn densely by both at the same tick merges by tick, status and controller: two people drawing one controller over the
  same span keep the winner's points where ticks coincide and both elsewhere. It's audible but deterministic.
- A take's MIDI that `midi_read` can't read (an unknown nested block between events) falls back to the take-copy rule.
- **Track deletion against a track edit**: newest wins, as before. `gone_race` is still items only.
- **Plug-in chains** don't merge (one chain stands, the other told with Use mine). Per-plug-in merging (by FXID) is possible later.
- **rt-claims' auto-claims**: since §3b an auto-claim asks only for a clash. A lasting claim still asks for everything.
- The first REAPER check failed (§3b); the fix is only proven offline so far. The MIDI chunk format with selection (e), mute (Em) and SysEx (<X>) events is handled from REAPER's documented format
  and this repo's notes, not from a live capture of each.

## 7. Review-later (security)

- `merge_midi`/`merge_env` read event states from bandmates' events (size-limited upstream, as all events are). They're pure string work
  with linear passes and a sort, and no `load`. A hostile event with many tiny events costs a sort per merge; merged versions are cached per
  id (`merged`), and the depth of nested merges is capped at 12 as before.
- A merged version's state was never signed by anyone. It's rebuilt from two signed events and their base, as merged items were since 0.58.

## 8. REAPER checks for the real computers (desktop + laptop, same room; Claims mode is fine, as long as nobody claimed the track by hand)

1. **Two notes at once:** both open one MIDI item in the MIDI editor. Each adds a different note within a second of the other. Both
   computers show both notes, no "<name>'s version" take, and the log says "...as you did, at the same time: both changes are kept".
2. **The same note:** both change one note's velocity at once. Both end with the same velocity; the loser's bar says "theirs stands where
   you both changed it", and **Use mine** brings theirs back everywhere.
3. **Undo after a merge:** after step 1, Ctrl+Z on the desktop. Only the desktop's note goes on both. Then Ctrl+Z on the laptop: only the
   laptop's goes.
4. **Item:** one drags an item while the other changes its volume (item properties or the fader on the item). Both stand on both.
5. **Track:** one renames a track while the other moves its fader. Both stand.
6. **Envelope:** both show the same track's volume envelope; each adds a point in a different place at the same time. Both points are on
   both computers once the 3 s settle passes.
7. **Same setting:** both drag one item to different places at once. Both end in one place. In Open, or when both went out before either
   arrived, one gets the "theirs stands" bar. In Claims mode with the moves about half a second apart, the second mover gets the ask
   instead (§3b): the first move auto-claimed the track.
7b. **Set back (Claims mode):** one changes an item's volume; within ten minutes the other sets it back to the old value. The other gets the
   ask (no silent undo). Changing a different setting of that item goes straight out.
7c. **Driver only:** a non-driver's edit is put back with "only the driver (<name>) edits in this room", never "claim it".
8. **Delete vs edit:** one deletes an item while the other trims it. It's gone on both.
9. **No hold:** edit an item right after a bandmate did. It isn't put back, there's no "Not sent" bar, and the log says "<name> is editing
   that item too". The "<name> is editing" tint still shows on the item while they work.
10. **Web/phone:** with a bandmate editing an item in REAPER, mute it from the web Project page. It's done, not refused.
