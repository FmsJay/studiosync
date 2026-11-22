# rt-fix6a: the sync-core bugs the REAPER re-check rt-r1 found (2026-11-21)

Four bugs from rt-r1 (`docs/rt/rt-p1.md` R1 results, `rt-linkmove.md` round 5 C, `rt-lab.md` LinuxBox2). Files: `lib/mirror.lua`,
`lib/sync.lua`, `lib/claimask.lua`; tests `tests/test_0_60_rt_fix6a.lua` (new), `tests/test_0_60_rt_claims.lua` (one source-text check),
`tests/test_0_60_rt_delete_race.lua` (one expectation turned round, see 2). Every fix has a check in the new test that fails without it
(checked by running the test against a copy of `lib/` with that one fix taken out).

## 1. P1-8: the claim judgement now agrees with the merge

**Cause.** P1 (29f93be) made `mirror.merge_midi` pair a moved note on both sides and merge it part by part (start, pitch, length, velocity...),
so a move and a transposition both stand. The claim judgement, `mirror.clashes` (used by `mirror.watch`'s soft path, `sync.receive`'s
`soft_ok` and `claimask.web_ask`), still compared notes as keys: a note's key is its channel, pitch and start, so James's move took key
`48@0` away and added `48@960`, and the laptop's transposition took `48@960` away. Same key: a clash, an ask, and 30 s later a put-back.

**Fix.** `mirror.note_changes(a, b)` pairs the notes one version moved or changed into the next exactly as `merge_midi` does (`move_pairs`,
same groups), and says which parts of each changed. `mirror.clashes` records, for each note of the claimer's they moved, the parts they
changed; a change of the editor's to that note is a clash only where it changes one of the same parts. A note of theirs taken away, or
another note put at its key, is still a clash. Nothing else changes: other pieces (timing, settings, points, plug-ins) are compared as before.
`merge_midi`'s note helpers moved to file level (`midi_cmps`, `note_keys`, `note_parts`) so both use the same code.

## 2. A bandmate's deletion and this computer's own auto-claim (rt-linkmove round 5 C)

**What happened on LinuxBox.** Live sync off; James deleted XT R1 take; LinuxBox moved the take's item; Live sync started. Its first look
sent the move and auto-claimed XT R1 take. Its receive then judged James's deletion (in the link's inbox all along) against today's claims:
the track was LinuxBox's own auto-claim, so the deletion was "refused here" and waited the minute every refused change waits
(`sync.refused_since`): that's the 61 s. When it landed, `mirror.apply` kept the moved item because it was "just made here"
(`mirror.just_made_here`, meant for a take just recorded), so the track turned into "XT R1 take (yours, not sent)".

**Fix, two parts.**
- `sync.gone_before_claim` (from `soft_ok` in `sync.receive`): a bandmate's deletion held back only by this computer's own **auto**-claim,
  and made before that claim (its `time` before the claim's `since`), lands at once. Its maker couldn't ask (there was no claim), and the
  claim came from an edit made without seeing the deletion (the track was still here). A deletion made after the claim waits its minute as
  before; a lasting claim is unchanged.
- `mirror.new_here`: on a track's deletion, an item "just made here" is kept on "(yours, not sent)" only when it's new work of this person's
  (every version back to its first is theirs). An edit of an item the band had goes with the track, as a deletion beats an edit made without
  seeing it (P1's rule for received edits, `mirror.gone_race`). Unsent edits (`mirror.unsent`) and items the band never had are kept as before.
  This turns round one expectation in `test_0_60_rt_delete_race.lua` ("a real edit of yours just sent ... still goes to (yours, not sent)"),
  which was written before P1's rule; James's round 5 C expected the track gone.

**The inbox wasn't the hold-up.** The need list and catch-up ordering had the deletion on time; the refusal's minute was the whole delay.

## 3. No auto-claim without an edit (LinuxBox2 and XT Rec A)

**What triggered it.** LinuxBox2's claims file (desktop's Syncthing copy, `.stversions/Cross Test/rooms/main/claims/LinuxBox2~20261121-180923.json`)
and event `LinuxBox2-20261122-010653Z-00001-0929`: 21 s after opening, LinuxBox2 sent XT Rec A's track settings with `lanenames`
`1,2,3,Verse - James - take 2,Verse - James - take 3,,,` read as `1,2,3,4,5,6,7,8` and `plays` `0,0,0,0,0,0,0,1` as `2,0,0,0,0,0,0,2`. A fresh
REAPER on Linux read the fixed lanes its own way; nobody edited. Every change that goes out auto-claimed its track (`W.send` -> `opts.sent`).

**Fix.** `mirror.user_edited` decides once per look whether an edit of the person's is behind it, and `W.send` reports a change for
auto-claiming only then (`w.edited`). An edit is: Live sync's change count moved by the person (`opts.edited_at`, which Live sync already passes;
its own writes are left out) in the last `mirror.EDIT_SECS` (30 s), and past the value the first look saw (Live sync's first tick takes the
project's count as a change); or a new undo point on top since the last look that isn't StudioSync's own syncing (`StudioSync: ...`,
`BandSync...`, the colour points). The second covers web page and phone edits (`StudioSync web page: ...`), made inside Live sync's tick and so
not in its count. A caller that doesn't pass `edited_at` (none in Live sync) gets the old behaviour.

What still goes out: the read-back itself. LinuxBox2's lane names reached the others (the band's lane names were overwritten by `1..8`). That
is a send question, not a claim one, and isn't changed here: see "Left".

## 4. A claimer the link can't reach (LinuxBox2 without Tailscale)

**Cause.** `claim_ask` goes to every computer the link reaches; `direct.send_live` returned true because the desktop and the laptop were
reachable, so the ask "went", nobody answered, and the edit was put back after 30 s.

**Decided behaviour** (`claimask.reachable`, `claimask.unreachable`):
- Before asking, `direct.reach` is read: the claimer's computer counts as reachable only when its last send or ping was answered. Without the
  link here at all (no extension in a stand-in) it can't tell, and the ask is tried as before (a failed send is "can't reach" as before).
- **Their auto-claim:** it doesn't hold. The edit goes out at once, as in Open mode, and the editor is told once a minute per thing: "<them>
  auto-claimed <it>, but the direct link can't reach them to ask (no Tailscale or nat mode on their computer): your edit went out, as an
  auto-claim doesn't hold when they can't be asked. Where you both changed the same thing, the later change stands". A deletion on it goes out
  too (`W.gone`). The web pages agree (`claimask.web_ask` doesn't say "Asked").
- **Their lasting claim** (made on purpose): put back at once, saying the link can't reach them and that the driver or an admin can release
  their claims; the web pages refuse it (`claimask.askable`). No 30 s wait for an answer that can't come.
- **Why not a Syncthing ask file:** the design (`docs/rt/rt-claims.md`) has none, and one would take Syncthing's seconds to tens of seconds
  each way (LinuxBox2's first Syncthing tune alone took over 8 s), longer than the 30 s the complaint was about. An auto-claim is a
  while-you-edit courtesy; without a way to ask, merging (which happens anyway) is the better default.
- **What the others do with it:** their receive judges the edit against the claimer's auto-claim with `soft_ok`: one that merges with the
  claimer's own change lands at once, one that clashes waits the usual minute and then lands. So the song converges, a minute later in a clash.

## Soak

`tools/soak` has no scenario mechanism (its edits come from a seed), so no case was added there. Before/after runs from a clean clone are
below.

Clean clones of `realtime` at f718439, before and with this change; `python tools/soak/soak.py --selfcheck`, then seeds 1-24 one at a time with
`--seed N --edits 40 --no-shrink`:

| | self-check | seeds passed |
| --- | --- | --- |
| before | ok | 6 of 24: 2, 11, 13, 14, 22, 23 |
| after | ok | 5 of 24: 11, 13, 14, 22, 23 |

No seed newly passes. **Seed 2 now fails** (`log`: the late joiner Dee's track order differs; three times in a row, while before passed three
times). Shrunk: `python tools/soak/soak.py --seed 2 --edits 40 --keep 2,3,24` (James deletes Bass at 29.5 s, Bee mutes an item on Bass at
29.6 s without having seen it, then resizes it). Taking part 3 out alone makes it pass again, so it's the auto-claim change, and the logs say
why: before, James's first look after sharing auto-claimed all four tracks with nobody editing (the soak's share sets no edit time), so Bee's
mute was asked about. Now the share claims nothing (as it should: sharing isn't editing), Bee's mute goes out and auto-claims Bass, and Dee,
reading every change at the end, refuses James's older deletion of Bass by today's claim (Bee's), keeps Bass and so a different order. That is
the soak's bug 3 ("a late joiner refuses older changes by today's claims", `sync.receive` judging by `sync.authority` now), reached by
another road; part 2's `gone_before_claim` only covers the claimer's own computer. Other seeds fail in the same categories as before, often
on other objects, since which tracks are claimed now differs from the start. Seeds aren't fully repeatable (the soak's bug 9), but seed 2 was.

## REAPER re-checks (written into rt-p1.md, rt-linkmove.md and rt-lab.md too)

1. **P1-8 again** (rt-p1.md): Claims mode, the desktop holding an auto-claim on XT Keys C. The desktop moves a note a beat later; within a
   second the laptop transposes that note. Pass: no ask, the laptop's log says both changes go in, all three end with the note moved **and**
   transposed. Then the laptop moves the same note again: asked as before (both changed its start).
2. **Round 5 C again** (rt-linkmove.md): LinuxBox's Live sync off and Syncthing paused; the desktop deletes a track with a take on it; LinuxBox
   moves that take; LinuxBox starts Live sync and Syncthing. Pass: the deletion applies on LinuxBox within a few seconds (not ~60 s), no
   "<track> (yours, not sent)" track on LinuxBox, the track on none of the three. Also: record a new take on LinuxBox on a track the desktop
   deletes a few seconds later: that take is kept on "<track> (yours, not sent)" as before.
3. **No claim without an edit** (rt-lab.md): open Cross Test on LinuxBox2 (or reopen it on LinuxBox) and touch nothing for two minutes. Pass:
   Who controls shows no claim of theirs, and their claims file has no tracks, even if a "change(s) went to the others" line shows. Then move
   an item there: its track is claimed.
4. **Claim asks off the link** (rt-lab.md): LinuxBox2 without Tailscale moves an item on XT Drums A (auto-claims it). On the desktop, move the
   same item: it goes out at once with the "can't reach them to ask" line, nobody is asked, and all four end alike (LinuxBox2's receive may
   take a minute if both moved it). Then Claim XT Drums A by hand on LinuxBox2 and edit it on the desktop: put back at once with the "can't
   reach them" words, no 30 s wait.

## Left / not done

- The read-back of a fresh REAPER (LinuxBox2's lane names) still goes out as that computer's change and overwrites the band's lane names. It
  needs either `mirror.track_state` to leave out REAPER's own lane naming on a track with no items in those lanes, or the first look after
  open to take such differences as the band's; both are sync-wide changes for a later round.
- `mirror.user_edited` is one answer per look: a read-back sent in the 30 s after a real edit elsewhere still claims. Per object would need
  REAPER to say what an edit touched. An edit that moves neither the change count nor REAPER's undo list (a plug-in knob turned with undo
  for parameters off, if REAPER doesn't count it) no longer auto-claims; the edit still goes out and merges. Untested in REAPER.
- `sync.gone_before_claim` handles a track claim (the deletion's track name); a deletion inside this computer's auto time-span claim still
  waits its minute.
- Nothing here was run in REAPER.

## Review-later (security)

- `gone_before_claim` trusts the deletion's `time` field, which is what its sender wrote. A sender with a clock set back could make a deletion
  of an auto-claimed track land at once instead of after a minute; it lands after the minute anyway, so no new power.
- `claimask.reachable` trusts the extension's peer status; a peer that answers pings but drops `claim_ask` still gets the 30 s wait.

## REAPER re-check results (rt-r3, 2026-11-21 evening MT / 11-22 UTC, StudioSync 0.59.49.95 from 747151f + extension 1.0.37 on the desktop, laptop, LinuxBox and LinuxBox2)

| # | Result | Evidence |
| --- | --- | --- |
| 1 P1-8 again | **first part pass, second part fail** | Claims mode ("open"), no claims anywhere first. Desktop moved XT Keys C's first note a beat later (48@0 -> 48@960, 21:02:42, which auto-claimed XT Keys C); the laptop transposed it +2 about 0.5 s later on the link clock. The move had already reached the laptop (its pitch read `50@960-1920`), so this is the "right after" case, as in rt-r1. No ask; the laptop: "James is editing that item on XT Keys C too: both changes go in ..." and "'rt-r3 note pitch' changed XT Keys C right after a bandmate's change landed: it went out as yours"; all three `50@960-1920`. **Then the laptop moved the same note again (2 min later, the desktop's auto-claim still on): not asked**, it went out ("1 change(s) went to the others"), all three `50@1920-2880`. Note put back to 48@0-960 after. |
| 2 round 5 C again | **pass** (second try) | A throwaway track "XT R3 del" with one MIDI item; the desktop's auto-claim on it released first. LinuxBox: Live sync stopped and Syncthing paused; the desktop deleted the track; LinuxBox moved its item to 4.5; Syncthing resumed and Live sync started at 04:26:45 UTC: "James: deleted a track on XT R3 del" at 04:26:46 (1 s), no "(yours, not sent)" track, the track on none of the three. **Recorded take:** LinuxBox recorded 4 s on "XT R3 rec" (its own silent output, no input) while the desktop deleted the track: the take kept on "XT R3 rec (yours, not sent)" on LinuxBox only (pass). Rig: LinuxBox's REAPER has "prompt to save/delete/rename new files on stop" on, so its "Select files to save or delete" box blocked its REAPER for 1.5 minutes (Save All pressed through xdotool). |
| 2, first try | **finding** | The same steps while the desktop still held its auto-claim on the track it had just made: the deletion landed at once, but LinuxBox's move was held as an unsent edit ("asked James to release XT R3 del"), so the track came back on LinuxBox as "XT R3 del (yours, not sent)", and the desktop got "LinuxBox wants to edit XT R3 del: Release or Keep" for a track it had deleted. The desktop also kept auto-claims on its deleted tracks "XT R3 take" and "XT R3 del" (Who controls) until released by hand. |
| 3 no claim without an edit | **pass** | LinuxBox2's REAPER restarted for 1.0.37 at 04:34 UTC, Cross Test opened, Live sync from 04:36:38; untouched until 04:39: its claims file `"tracks": []`, `my_claims` empty, and no "change(s) went to the others" line this time. Then it moved XT Drums A's item to 2.5 (04:40:00): "claimed XT Drums A for you as you edit", claims `[XT Drums A]` auto. |
| 4 claim asks off the link | **pass, with two notes** | The desktop moved the same item to 3.0 at 21:42:27 MT (after LinuxBox2's move reached it at 21:41:41, 101 s late by Syncthing): "LinuxBox2 auto-claimed XT Drums A, but the direct link can't reach them to ask (no Tailscale or nat mode on their computer): your edit went out ..." in the same second, nobody asked. Notes: the laptop applied the desktop's move only at 21:43:27 (60 s) and LinuxBox at 04:44:28 UTC (2 min), although both are on the link; LinuxBox2 at 04:54:33 (12 min, the desktop's Syncthing scanning). All four 3.0 in the end. **Hand claim:** Claim XT Drums A on LinuxBox2 (04:47:29; its claims file reached the desktop at 04:54:34), the desktop moved the item to 2.0 at 04:56:56: put back in the same second, "Not sent: LinuxBox2 has claimed XT Drums A and isn't here to release it. Your edit is put back (the driver or an admin can release their claims)": no 30 s wait, but "isn't here" rather than the "can't reach them" words. Put back: LinuxBox2 moved it to 2.0 and released. |

rt-r4 (2026-11-22 UTC, 0.59.49.96): P1-8's second part (asked), the off-link auto-claim (LinuxBox applies the desktop's edit in the same second) and deleting your own auto-claimed track (claim let go at once, no "(yours, not sent)") pass: `docs/rt/rt-converge.md`, "REAPER re-check results (rt-r4 ...)".
