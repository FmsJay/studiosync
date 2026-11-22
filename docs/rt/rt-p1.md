# rt-p1: sync-core leftovers (backlog package P1, 2026-11-21)

Package P1 of `docs/rt/backlog.md` "Plan to finish": items 1.1, 1.3 (all four parts), 1.4, 1.5, 1.6, 1.8, 1.9, 1.10 and 3.13. Each fix is in
shared code. Each has a test that fails when the fix is switched off: every switch-off below was run and its test failed. Offline only: nothing
here has run in REAPER yet. The checks at the end are for the re-checker (R1).

## What changed, item by item

**1.3 / 3.13: plug-in chains merge plug-in by plug-in** (`mirror.merge_fx`, `fx_units`, `mirror.pieces("fx")`). Two people changing one track's
chain at once now merge, the same way items and tracks already do. Before this, one chain stood and the other person got "theirs stands" with
Use mine.
- **The pieces.** Each plug-in runs from its BYPASS line to the line before the next plug-in's. That includes its saved data, preset name and
  lanes. The lines before the first plug-in are a piece of their own.
- **How a plug-in is known.** By the name REAPER gives the plug-in itself (`<VST "VST: ReaEQ (Cockos)"`, `<JS utility/volume`), plus which of
  that name it is in the chain. A plug-in you renamed keeps its key. FX ids can't be used: each computer makes its own, and they never travel
  (`FX_LOCAL`). The backlog's "by FXID" isn't possible from what the band shares.
- **How a change is judged.** Each piece is compared the way `fx_hash` reads a chain: the plug-in's file named the same on every platform,
  and a VST's program line left out. A program line REAPER reads differently on another computer isn't a change and isn't a clash.
- **What merges.** A plug-in changed by one person takes their version. The same plug-in changed by both takes the winner's, and that counts
  as a clash. A plug-in removed by one and changed by the other takes the winner's word on it, also a clash. A plug-in each person added stays,
  and so do two of the same kind added by both: nothing was there to clash over.
- **The order.** If only one person moved plug-ins, their order stands, with the other's additions placed after the plug-in each followed.
  If both moved them, the winner's order stands (piece `\0order`, a clash).
- **When a merge happens.** Only between versions that both say they merge chains: `mg >= 1`, which `sync.post` puts on every change from
  this version (`mirror.MG`, `mirror.MERGE_MG`). A chain from an older StudioSync merges with nothing, so newest wins, as it did before.
- **Files.** A merged version also carries the files the loser's plug-ins load (`event_file`). Before, only the winner's list went along, so a
  computer that took the winner first never fetched the loser's sample.
- **Receiving.** The receive message now says "the plug-ins on X". A merged chain picks its track's prints like any landed chain
  (`fx_landed`, shared by both paths).
- **Claims mode.** A bandmate's auto-claim now asks only when an edit clashes with their change, as it already did for items, automation and
  track settings. `mirror.clashes` reads the plug-in pieces. rt-merge §3b's "plug-in chains ... are still asked for" no longer holds.
- **Undo.** `mirror.undo_keeping` now covers chains too. Your Ctrl+Z on a plug-in keeps a bandmate's change to another plug-in.

**1.3: track deletion against a track edit** (`mirror.gone_race`, its `RACES`). This used to be decided by "newest wins", so a rename made a
moment after someone deleted the track brought the track back for everyone. Now a track works the way an item already did:
- A deletion wins over an edit that didn't build on it. Receive and heal (`mirror.settled`) judge it this way, in either order.
- An edit that builds on the deletion (an Undo of it) still wins.

**1.3: one controller drawn densely by both** (`merge_midi`, `force_w`). Two people drawing one CC lane over the same stretch used to end up
with both curves interleaved into a zigzag.
- Now, in each lane, the winner's changed points form runs: points no more than a quarter note apart. Across each run the winner's curve stands
  whole: the loser's points inside it go, and base points the loser removed there come back. That counts as a clash.
- The loser's drawing outside those runs stays, and so do other controllers.
- A lane is a CC number, poly pressure per note, channel pressure, or pitch bend.

**1.3: a pitch change counted as a move** (`merge_midi`, `move_pairs`). A note one person moved (in time or pitch) that the other also changed
is now one note built from what each changed.
- Each of start, pitch, length, velocity, mute and the note-off is merged on its own. Where both changed the same one, the winner's stands
  (a clash). One person transposing and the other moving in time, or changing velocity, both stand.
- Both people's moves are paired now (`move_pairs` for each side), not only the loser's.
- A note the winner removed stays removed (`moved_twice`, unchanged).
- Changed tests in `test_0_60_rt_edits.lua`:
  - "a pitch change against a move" was "one note, the winner's"; it's now transposed and moved, with no clash.
  - "changed by one, moved by the other" now gives the moved note with the winner's velocity.
  - "moved and resized by one, moved by the other" now gives the winner's place with the loser's length, a clash.
  - New: both transposed it, so the winner's pitch stands, a clash.

**1.1: `mirror.settled`'s old pair** (`mirror.mergeable`, `mirror.MERGE_SINCE`). This can still happen: rt-undo saw it in real event files
(three identical follow-ups merged into a new id). So the case isn't removed. The root cause is fixed instead: a track or automation version
made before track merging began (rt-merge, c130487, 2026-11-20 19:42 UTC, read from the version's id) merges with nothing.
- Heal now settles such pairs on the newer version, as every receive did then. It no longer makes a merge that changes the track everywhere,
  a day late.
- Versions from after that time merge as before.
- Test: `test_0_60_rt_edits.lua`, "Edits order" step 4, and the gate in `test_0_60_rt_merge_p1.lua`.
- Note: events in the roughly 35 minutes between that commit and the first 0.59.49.70 install merge on updated computers. Those computers
  merged them at the time too, so this is no change.

**1.4: the web page's claim-ask countdown** (`lib/webui/app.js`, a small edit to a shared file). Each ask's seconds left is now a span that a
one-second timer rewrites in place. Before, the count moved only when the presence topic changed. The Release and Keep buttons aren't redrawn,
so a click isn't lost. The test checks this wiring (`test_0_60_rt_merge_p1.lua`). It wasn't run in Chromium.

**1.5: the web Project page, a clash or a different piece** (`claimask.web_ask`, plus two small edits in `lib/dawedit.lua`). An edit made from
the page to a bandmate's auto-claimed track used to reply "Asked <name> for it…" every time. `mirror.watch` then sent it anyway when nothing
clashed.
- `dawedit.action` now asks `claimask.web_ask` after the edit is made. That function judges the edit the way `W.one` does (`mirror.clashes`
  against the item's last version and the claimer).
- A different piece gets no ask in the reply, and the edit goes out.
- The claimer's own note, a set-back, or a lasting claim are still asked.
- Test: `test_0_60_rt_merge.lua`, Claims mode.
- **Not done: the phone.** `lib/phonedaw.lua` (P5's file) still refuses edits to a bandmate's auto-claimed track outright, through
  `dawedit.item_refusal`. The change it needs: where it refuses, call `claimask.askable`; then, once the take pick is made, call
  `claimask.web_ask(proj, cfg, b, who, it, owner, name, pos)` and refuse or say "asked" only when that returns a name.

**1.6: the colour try**
- **A bandmate's change on a tried thing** (`mirror.apply` for items, `mirror.set_track_state` for tracks). When the band's version still
  holds the colour from before the try, the tried colour stays on. It used to be replaced, so the try stopped showing there and Keep never
  sent it. Fixing this inside `set_track_state` also covers an item landing on a tried track: `lanes_back` rewrote the track's settings and
  wiped the tried colour there too.
- **Put back on a region that had no colour** (`colours.lua`, `put_back_from`). This now clears the colour with REAPER 7.62's
  `SetRegionOrMarkerInfo_Value(…, "I_CUSTOMCOLOR", 0)`, the way `band.apply_markers` already does. `SetProjectMarkerByIndex2`'s colour 0
  means "leave it", which is why the region kept the tried colour. On an older REAPER it stays as before.
- The fixture gained `GetRegionOrMarker`, `GetRegionOrMarkerInfo_Value` and `SetRegionOrMarkerInfo_Value`. Lanes still read as none.
- Test: `test_0_60_rt_merge.lua`, "the colour try".

**1.8: a given claim released before Syncthing's copy** (James's default (b)). The panel chip's release now passes `let_go`, the claim's key,
to `sync.set_claims`. That marks the claim as let go even when your own file doesn't hold it yet (only the link's copy has arrived).
- `sync.authority` and the later fold then pass over the given claim, through the existing `dropped`.
- `StudioSync - Panel.lua`: one line in `ui.claim_chips`' release. `lib/sync.lua`: `let_go` in `set_claims`.
- Test: `test_0_60_rt_edits.lua`, "Edits given", which also checks the panel's line.

**1.9: a note deleted and another drawn, read as a move** (default: keep). Nothing to build. With the new per-attribute merge (1.3 above), this
case no longer loses your drawn note. Your note stands where you drew it, and only what the bandmate changed on the deleted note (its velocity,
say) goes onto it. Before, your note was left out as a clash.

**1.10: act grouping on heavy songs, and a hand move after a tempo change**
- **Act grouping** (`mirror.act_keep`). An act now keeps what later looks find until 10 s past the next timed full look, however far apart
  heavy songs make those looks (up to `QUICK_FULL_MAX`, 300 s). It used to stop at a fixed 70 s, so on a heavy song a part only the full look
  found became a second Undo step. Test: "Edits acts".
- **A hand move after a tempo change** (`mirror.map_moved`, `mirror.tempo_changed(proj, from)`). When this computer's own tempo change is the
  cause, `sync.watch_timeline` passes the map from before it (the first map of a burst is kept).
- An item that differs only in timing is the map's move only if it sits where the old map's beat falls on the new map (`mirror.retime`). A
  version made after the change counts as already on the new map.
- A hand move now claims its track (`W.send`). In `W.refuse`, it's no longer silently taken as "nobody's edit" and recorded unsent.
- Test: "Edits tempo claim". The map's own moves still claim nothing.

## Decisions taken by default (section 4)

- b. A given claim released before Syncthing's copy: option (b), built as above.
- b. A note deleted and another drawn, read as a move: kept. The new attribute merge makes the outcome kinder; see 1.9.
- 1.1: not removed, because it can happen. Gated by date instead; see above.

## Files

- Mine:
  - `lib/mirror.lua`
  - `lib/sync.lua`: `mg` in `post`, `let_go` in `set_claims`, the old map passed to `tempo_changed`
  - `lib/claimask.lua`: `web_ask`
  - `lib/colours.lua`: Put back only
  - `StudioSync - Panel.lua`: one line, the chip's release
  - `tests/fixtures/editreaper.lua`
  - `tests/test_0_60_rt_edits.lua`
  - `tests/test_0_60_rt_merge.lua`
  - new `tests/test_0_60_rt_merge_p1.lua`
- Small edits to files outside my list:
  - `lib/dawedit.lua`: two lines, `asking_at` and the `web_ask` call. P14 holds this file later; nobody held it now.
  - `lib/webui/app.js`: the countdown (shared file, additive).
  - `tests/test_0_60_rt_undo.lua`: one line, `mirror.MERGE_SINCE = {}`. Its fake clock is 2026-11-20 16:00 local, which is before the cutoff
    on a UTC runner (CI). `test_0_60_rt_merge.lua` has the same line for its 15:00.
- `lib/undo.lua` wasn't changed: `undo_keeping` covers chains through `mirror.MERGES`.

## Deploying

The chain merge and the track deletion rule have to be the same on every computer. Update every computer in a room together, as for rt-merge.
- An older computer in the room keeps the newest chain where updated ones merge. The `mg` gate only keeps updated computers from merging an
  older one's chain.
- The track deletion rule has no such gate. An older computer still lets a newer rename beat a deletion until it's updated.

## Untested, limits

- Nothing has run in REAPER. FX merging is tested on the pure merge and on `event_file`'s merged version. The stand-in REAPER has no plug-ins,
  so a whole receive of a merged chain hasn't run.
- A plug-in is known by name and position among its namesakes. If one person adds a second ReaEQ before the first while the other changes the
  first, the merge reads the change against the wrong instance. That's a clash, the winner's stands and the loser is told; nothing is silently
  wrong.
- A container (REAPER 7) is one piece: plug-ins inside it don't merge separately.
- Restless and modulated plug-ins' data isn't hidden when judging a piece. Their reads differ more often, which shows up as a clash (the
  winner's version), never as a lost change.
- CC runs use a quarter note as their gap. A winner who drew two distant points far apart makes two runs, not one.
- `map_moved` checks position and length only, with the limits `mirror.retime` already has (rate, fades and snap offset aren't converted;
  gradual tempo changes aren't converted). A bandmate's tempo map that lands isn't affected: `mirror.map_landing` handles that.
- The web countdown uses the browser's clock against StudioSync's `till`, which is `os.time` of the host. A phone with a wrong clock reads it
  off, as before.

## Review-later (security)

- `merge_fx` reads plug-in blocks from bandmates' events. Event size limits apply upstream. It's pure string work: a linear walk and a
  name-keyed table, no `load`. A chain with thousands of tiny plug-ins costs one walk per merge, and merged versions are cached.
- `mg` is what an event says about its sender's version. A bandmate could set it to make their chain merge with an older computer's. That
  causes a merge, never data loss, and anyone can already overwrite a chain.
- `let_go` is written only by your own panel into your own claims file, and is read back as `dropped`, which is already type-checked.
- `claimask.web_ask` reads the item's own known event and room events, as `mirror.clashes` already does for `W.one`.

## REAPER checks for the re-checker (R1)

Same setup as rt-edits: Cross Test on the desktop and the laptop, and LinuxBox as a third computer, all on this build. Claims mode unless a check
says otherwise, with nothing claimed by hand. Write pass, fail or not run next to each.

- [ ] **P1-1 Plug-ins, two at once (3.13).** XT Keys C has ReaEQ then ReaComp. Within a second of each other, the desktop changes a ReaEQ band
  and the laptop changes ReaComp's ratio. All three end with both changes. Neither computer gets a "theirs stands" bar. The log says "...changed
  the plug-ins on XT Keys C as you did, at the same time: both changes are kept".
- [ ] **P1-2 The same plug-in.** Both change ReaEQ's same band at once. All three end alike. The loser's bar says "theirs stands where you both
  changed it", and Use mine brings theirs back.
- [ ] **P1-3 Added by both.** Each adds a different plug-in to XT Keys C at once (the desktop a JS volume at the end, the laptop ReaDelay after
  ReaEQ). All three show four plug-ins, each where its adder put it. No plug-in reloads twice in 5 s (`FX_SET_GAP`).
- [ ] **P1-4 Order.** The desktop drags ReaComp above ReaEQ while the laptop changes ReaEQ. Both stand: ReaComp first, with the laptop's EQ.
- [ ] **P1-5 Claims and plug-ins.** In Claims mode the desktop changes ReaEQ, which auto-claims XT Keys C. The laptop then changes ReaComp, and
  it goes out with no ask. The laptop then changes ReaEQ's same band: the desktop gets the ask.
- [ ] **P1-6 Track deleted against a rename (1.3).** The desktop deletes XT Gtr. Within two seconds, before it lands, the laptop renames XT Gtr.
  It's gone on all three and stays gone (no track comes back within a minute). Ctrl+Z on the desktop brings it back everywhere.
- [ ] **P1-7 Dense CC (1.3).** Both open one MIDI item and draw CC1 (mod wheel) over the same bar with the pencil, within a second. All three
  end with one curve over that bar: the later drawer's. A point the earlier drawer made two bars away stays.
- [ ] **P1-8 Transpose and move (1.3).** The desktop moves a note a beat later while the laptop transposes the same note up a tone (a
  script, or the MIDI editor's arrow keys, within a second). One note on all three: a beat later and a tone up. No "theirs stands".
- [ ] **P1-9 Heal leaves old pairs (1.1).** On a song with history from before 2026-11-20 19:42 UTC (Cross Test), run "Look over the room"
  (heal) on each computer. No "caught up on N" line names a track whose versions are all from before that time, and no track moves.
- [ ] **P1-10 Web countdown (1.4).** The laptop claims XT Rec A by hand. On the desktop's web Project page, mute an item on XT Rec A. On the
  laptop's web page (Who's here), "James wants to edit XT Rec A (30 s)" counts down each second to 0 without anything else changing.
  Release still works mid-count.
- [ ] **P1-11 Web page and auto-claims (1.5).** The desktop mutes XT Keys C's first item, which auto-claims the track. On the laptop's web
  Project page, mute a different item on XT Keys C. The page says it's done (no "Asked James…") and the mute reaches the desktop. Then, from
  the page, unmute the first item (the desktop's own change, set back): the page says "Asked James…" and the desktop gets the ask.
- [ ] **P1-12 Colour try with a bandmate (1.6).** On the desktop, Colours > Try it on this computer first > colour all tracks and items. While
  trying, the laptop turns an item on XT Bass down and pans XT Bass. On the desktop that item and track keep their tried colours, with the
  laptop's volume and pan. Keep sends the colours. Try again, then Put back: everything returns to its colour from before.
- [ ] **P1-13 Region with no colour (1.6).** Make a region with no colour. Try a region colour scheme, then Put it back. The region has no
  colour again (default grey), not the tried one. Nothing arrives on the other computers. Needs REAPER 7.62+.
- [ ] **P1-14 Given claim released early (1.8).** Stop Syncthing on the laptop (only for this check; start it again after). On the desktop,
  give the laptop's person XT Keys C. As soon as the laptop logs "James gave you XT Keys C" (link copy), release it from the laptop's chip x.
  Within a second, LinuxBox and the desktop no longer show it as the laptop's. Start Syncthing again: after a minute it still isn't the
  laptop's anywhere.
- [ ] **P1-15 Heavy song act (1.10).** On a heavy song (a full look over 300 ms: Health's perf line), run the round 5 step 36 script (mute one
  item on each of two tracks, nothing selected). Both events carry the same `act` even when found minutes apart. One StudioSync Undo unmutes
  both.
- [ ] **P1-16 Hand move after a tempo change (1.10).** Claims mode, nothing claimed. On the desktop add a 90 bpm tempo marker. Within 15 s,
  drag an XT Drums A item by hand. XT Drums A is claimed by the desktop (Who controls); the tracks REAPER only moved for the map aren't. Then
  repeat with XT Drums A claimed by the laptop by hand: the hand move is asked for (or put back), not silently kept on the desktop alone.

### R1 results (rt-r1, 2026-11-21, 0.59.49.93 + extension 1.0.35)

Only P1-8 was run (time); P1-1..7 and P1-9..16 not run. P1-14 as written stops the laptop's Syncthing, which James hasn't OK'd (only the test
VMs' may be paused): it would need LinuxBox or LinuxBox2 in the laptop's place.

- **P1-8: fail** (room mode "open", as it was; the desktop held an auto-claim on XT Keys C from an earlier move). Deferred scripts on the
  link clock: the desktop moved XT Keys C's note 48@0-960 a beat later at 100.019 (desktop link clock), the laptop transposed it up a tone
  0.41 s later (099.241 on its own clock = 100.43 on the desktop's). The move had already reached the laptop (it transposed 48@960 into
  50@960). The laptop logged "James is editing that item on XT Keys C too: both changes go in, and where you both change the same thing the
  later one stands", then "asked James to release XT Keys C: your edit waits here for their answer (up to 30 s)" and "Not sent: James didn't
  answer about XT Keys C in 30 s. Your edit is put back"; the desktop showed "James-Laptop wants to edit XT Keys C: Release or Keep". All
  three ended 48@960-1920: the transposition lost. So the desktop's soft auto-claim (claimask.soft) took a change to another field of the
  same note as a clash, though the merge said both go in. A truly simultaneous pair (neither seeing the other, inside the link's ~40 ms)
  wasn't produced. Note put back to 48@0-960 on all three.

### Re-check after rt-fix6a (docs/rt/rt-fix6a.md, part 1)

- [ ] **P1-8 again.** Claims mode, the desktop holding an auto-claim on XT Keys C. The desktop moves a note a beat later; within a second the
  laptop transposes that note. Pass: no ask, "both changes go in" on the laptop, all three end with the note moved and transposed. Then the
  laptop moves the same note again: asked, as before (both changed its start).

### R2 results (rt-r2, 2026-11-21 evening MT / 11-22 UTC, StudioSync 0.59.49.94 from 905f000 + extension 1.0.36 on the desktop, laptop, LinuxBox and LinuxBox2; Deafen 1 everywhere, no sound tests)

Timed edits on the shared clock (`direct.shared_now`, each computer's eval hook deferring to the same moment; pairs ran within 7-40 ms of each other
unless said). Claims mode ("open"). ReaEQ + ReaComp added to XT Keys C for P1-1..5 and removed after; Cross Test identical on all four afterwards.

- **P1-1: pass once, fail once.** With no claims (third try, both at ...263.0): all four ended with the desktop's EQ band and the laptop's ReaComp
  ratio, both logs "... changed the plug-ins on XT Keys C as you did, at the same time: both changes are kept". But the laptop's change reached the
  desktop **61 s** later (19:24:23 -> 19:25:24 MT; the desktop's reached the laptop at once). First try (the desktop's auto-claim from adding the
  plug-ins still on): all four ended with the EQ change only, the laptop's ratio gone on the laptop too, and **the laptop logged nothing about its
  own change** (no ask, no Not sent, no theirs stands): a silent loss.
- **P1-2: pass.** Both set ReaEQ's band 2 gain (0.4 desktop, 0.8 laptop): all four 0.4; laptop "James changed the same thing as you on the plug-ins
  on XT Keys C: theirs stands where you both changed it, and the rest of your change is in". The desktop's line said "... both changes are kept"
  (wrong on the winner's side). Laptop -> desktop again 61 s. Use mine not tried.
- **P1-3: pass.** Desktop JS Volume at the end, laptop ReaDelay after ReaEQ: all four EQ, ReaDelay, Comp, Volume. FX_SET_GAP not observed.
- **P1-4: fail.** Desktop moved ReaComp to the top while the laptop changed ReaEQ: the order stands everywhere but the laptop's EQ value is gone on
  all four, the laptop included, and its log has only "James: changed the plug-ins on XT Keys C": the same silent loss as P1-1's first try. Looks
  like an incoming chain applied over a local edit the laptop's pass hadn't seen yet.
- **P1-5: fail.** A ReaComp change on the laptop while the desktop's soft auto-claim on XT Keys C came from ReaEQ (and from adding both): "asked
  James to release XT Keys C" -> "Not sent ... put back" (+ the RfxChain saved), twice; once preceded by "James is editing the plug-ins on XT Keys C
  too: both changes go in ..." (rt-r1's P1-8 pattern: the soft claim asks although the merge would keep both).
- **P1-6: pass, but Ctrl+Z fails with errors.** Desktop deleted XT Gtr at ...145.04, the laptop renamed it 120 ms later: laptop "James also changed
  something on XT Gtr at the same moment as you: theirs is in."; gone on all four and stayed gone. (At 1 s the delete had already landed: the link is
  faster than the check's two seconds.) **Ctrl+Z** (40029, undoing "rt-r2 delete XT Gtr") brought it back nowhere, not even on the desktop: Live sync
  logged "this project was opened without its last save: what changed since is back as the studio has it" (`mirror.reopened` took the undo for a
  reopen), then "mirror sync skipped F-JAMES-20261122023748-22814: .../lib/mirror.lua:296: bad argument #1 to 'TrackFX_GetCount' (MediaTrack
  expected)" and ".../lib/mirror.lua:5935: bad argument #1 to 'f' (MediaTrack expected)". The laptop also kept an auto-claim on the gone
  "XT Gtr renamed" until released by hand.
- **P1-7: inconclusive.** Each inserted 16 CC1 points over the same beats (no deletes, unlike REAPER's pencil), 0.4 s apart: all four have both
  curves interleaved (33 events), the far point kept; laptop "James is editing that item on XT Keys C too ..." and "'rt-r2 CC1 drawn' changed XT
  Keys C right after a bandmate's change landed: it went out as yours". A real pencil stroke (removing the bar's events) is needed to judge.
- **P1-14 (LinuxBox in the laptop's place, only its Syncthing paused): fail.** The desktop gave LinuxBox XT Keys C (`given-LinuxBox-20261122-024750.json`);
  its link copy reached LinuxBox at once (`direct/<studio>/.linked/.../claims/given-...json`) but LinuxBox's Live sync didn't take it while Syncthing
  was paused: no "James gave you" for 2 minutes, so the early release can't happen. I released anyway (nothing to drop); on resume, 02:49:48 "James gave
  you XT Keys C: yours to change now" and LinuxBox held it. Released again by hand.
- **P1-16: pass.** 90 bpm tempo marker, then a scripted move of XT Drums A 8 s later: "claimed XT Drums A for you as you edit", XT Rec A (moved by the
  map only) not claimed. With XT Drums A claimed by hand on the laptop, tempo 100 and a move: asked, then "Not sent ... put back". Marker removed and
  the item set back after.
- P1-9 (no "Look over the room" action found by that name), P1-10, P1-11, P1-12, P1-13 (panel/web flows), P1-15 (no heavy song): not run.
