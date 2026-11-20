# Hold my changes removed (rt-nohold)

James, 2026-11-20: "I think hold my changes might be working against us, might be better to just remove it. Someone can go into a
different room to test, especially now that changes come so fast now."

Hold my changes (ProjExtState `hold`, "Hold sync") is gone. The colour try, which used Hold to keep a look private, now has its own narrow
mechanism.

What went wrong today: the laptop's Cross Test had `hold = "1"` saved in the .rpp (left by a colour try from before rt-edits' fix).
- After every REAPER restart, none of its edits went out.
- The band's timeline changes waited (`sync.timeline_waits`).
- rt-edits' 3963730 and 3036ffc patched around it. Both patches are removed here, along with the rest of Hold.

## What changed

### 1. Migration (`lib/mirror.lua`, `mirror.on_open`)

`mirror.watch` calls `mirror.on_open(proj)` before its scan, once each time a project opens (keyed by the project's master track, as the
stash already was).
- If the project has ProjExtState `hold` set to anything (`"1"`, `"try"`, `"try1"`), it is cleared, and the log says once: "Hold my changes
  was removed: this project's held changes go out now".
- Held edits are still in the project and differ from what the band last had, so that same look sends them like any other change. Nothing
  is lost.
- An old crash-safe file's `hold = true` is ignored. Its changes are restored and sent as usual.
- This is the only place in the code that reads `"hold"`. The test checks that.

### 2. Colour try without Hold (`lib/colours.lua`, `lib/band.lua`, `lib/mirror.lua`)

Trying a look still sends nothing, and Keep and Put back work as before. Nothing else is held back.

**What the try records.** After each colour button runs (`try_first` -> `fn()` -> `publish`), the try writes down what it changed:
- tracks by GUID: `{was, now}` native colours;
- items by GUID: `{was COLOR line, now COLOR line, was value}`;
- markers and regions by number (`r5`, `m2`): `{was, now}`.

It writes this to two places:
- this REAPER's ExtState: `colour try <proj>` holds a stamp, `colour try data <proj>` holds the JSON;
- the project's ProjExtState `colour try`, used only to undo the try after a restart.

**How the band's copy reads it (`band.colour_try`).** Wherever StudioSync reads what the band shares, a thing that still shows its tried
colour reads with its colour from before the try:
- `mirror.track_state` (track colour);
- mirror's item states (`mirror.item_state`, `mirror.item_states`): the item's `COLOR` line is put back with `mirror.with_colour_line`;
- `band.capture_markers` (marker and region colours).

So a colour-only change is not a change, and nothing goes out. Any other edit goes out as usual, including an edit to a tried track. That
edit carries the track's old colour.

**Keeping the look out of other paths:**
- The try's stamp is part of `look_ctx`, so a quick look can't reuse stale states.
- Live sync starts a full look as soon as the stamp changes (Keep or Put back), instead of waiting up to 10 s.
- The SWS re-colour step in `W.one` (rescheme) and Live sync's `colours.auto` leave a tried project alone.

**Keep** clears the try. The next look sends the colours.

**Put back** restores each thing that still shows its tried colour, then clears the try. Nothing is sent.
- A bandmate's change that landed on a tried thing meanwhile stays.
- So does a colour you set by hand during the try (it already went out, because it isn't the tried colour).

**Restart mid-try: the look is put back.**
- The try lives in the panel's Lua and this REAPER's ExtState, so it can't outlive REAPER.
- If the project was saved during the try, its ProjExtState `colour try` is still there. On the next opening, `mirror.on_open` calls
  `colours.put_back_stale`: the look is put back (one undo point, "Colours put back"), the log says so, and nothing is sent.
- If the project wasn't saved, it opens with its old colours anyway.
- If Live sync restarts while the panel still has a try open, the ExtState is still there, so the try stays.

### 3. Everything that used Hold as a safety for something else

| Where | What Hold did | Now |
|---|---|---|
| `lib/sync.lua` `sync.timeline_waits`, `sync.apply`, `sync.receive` | the band's timeline waited while your own held timeline differed | removed: the timeline is sent every pass (`watch_timeline` no longer skipped), so there's no held local timeline to protect |
| `lib/sync.lua` `sync.preload` | skipped catching up on open while held | removed: catch-up runs |
| `lib/sync.lua` `hold_mine`, `hold_words` | try vs. real Hold; Health wording | removed |
| Live sync `P.look` | skipped `watch_timeline`, passed `opts.hold`, wrote the `held <proj>` count | removed |
| Live sync `P.outbox_inbox` | `mirror.waiting(key, hold)` didn't count held changes; inbox import skipped | `mirror.waiting(key)`; inbox runs |
| Live sync `P.heal` | no heal while held | heal runs (a try changes no revisions, so it doesn't start a heal) |
| Live sync `colours.auto` | not while "sending is held" (a try) | not while `band.colour_try(proj)` (the nearest correct behaviour) |
| Live sync `sync.timeline_mine` | a Link app's tempo couldn't become the song's while held | `my_can` only |
| Live sync status / `lib/status.lua` | `info.hold`; handover said "Hold sync is on" or "X is holding sync" | removed; the handover says "you: trying a colour look" while a try is live |
| `lib/mirror.lua` `W.one`, `W.keep_held`, `W.credit`, deletes, prints | `opts.hold`: mark unsent, don't send, don't print, hold deletes | removed |
| `lib/mirror.lua` stash | `hold` / `hold off` in `bandsync-unsent.json` | removed; an empty stash removes the file |
| `lib/mirror.lua` `restore_unsent` | put Hold back on or off from the stash | removed (the migration covers old files) |
| `lib/controllers.lua` | no live fader moves while held | removed |
| `lib/leave.lua` (Sync and exit) | "hold?" step, Send what I'm holding / Keep holding, `send_held`, `unheld`, `kept_held` words | removed; it always starts at Save |
| `lib/page_health.lua` | yellow Hold row | a yellow row while a colour try is live (dismissed for the day) |
| `lib/api.lua` | `hold`/`held` state, `hold` event and verb | state keeps `hold = false`, `held = 0` (the API says fields never go); no `hold` event; the `hold` verb logs that Hold was removed |
| `lib/debugmode.lua` | `hold` in the report | removed |
| `lib/rooms.lua` | cleared `hold` on a new side room | removed (the migration covers it) |
| Panel | Settings > Advanced switch, "Holding N changes" pill + Send now, `panel do` "hold" | the switch is replaced by **Try things in a side room** (opens Rooms); pill gone; "hold" logs that Hold was removed |
| `StudioSync - Hold my changes.lua` | the bindable action | deleted. `band.sync_actions` drops an action whose script is gone at REAPER start |

### 4. UI text

- Settings > Advanced: **Try things in a side room**, with the tooltip "To try something without the others getting it, make a side room and
  test there: Bring into main brings back what you keep."
- The old `hold` verb or key logs: "Hold my changes was removed: to try something without the others getting it, test in a side room
  (Rooms)".
- Colours try box: "Trying a look on this computer only: its colours haven't gone to the others yet. Everything else you change still goes
  out." The "Try it on this computer first" tooltip says the same.
- README (actions list, "what you see is what the studio has", Sync and exit, the API paragraph, crash-safe) and `docs/API.md` (state,
  events and verbs) are updated.

### 5. Tests

- Removed: `tests/test_0_60_rt_edits_hold.lua`, and the Hold parts of `test_0_59_45_engine`, `0_59_45_ui`, `0_59_46_engine`, `0_59_46_ui`,
  `0_59_48_ui`, `0_59_49_ui`, `0_60_rt_controllers`, `0_60_rt_crashsafe`, `0_60_rt_delete_race`, `0_60_rt_edits` (the timeline block keeps
  "an older-format seen takes the band's renumbering and matrix"), `test_api`, `test_actions`, and `tests/reaper/limit_fixes.lua`.
- New: `tests/test_0_60_rt_nohold.lua`. It runs on two stand-in REAPERs (`tests/fixtures/editreaper.lua`), each with its own ExtState:
  - Migration of `"1"`, `"try"` and `"try1"`: cleared on opening, said exactly once, the held edit goes out in that look, and the desktop
    ends up identical.
  - Colour try, nothing sent: no event from a quick or a full look, and both computers read the same.
  - Colour try, other edits: an item moved elsewhere, a rename of a tried track (sent with its old colour) and a marker added (the region
    keeps its old colour) all go out.
  - Keep sends both track colours, the item's `COLOR` and the region.
  - Put back sends nothing, leaves nothing in the project, and leaves a bandmate's landed colour alone.
  - Live sync restarted mid-try: the try stays.
  - REAPER restarted mid-try (project saved): put back on opening, logged, nothing sent.
  - A grep over `git ls-files "*.lua"` (excluding tests and comments): `"hold"` appears only in `mirror.on_open`, the API's KINDS/VERBS lists
    and the panel's old-verb branch, and the action script is gone.
  - Mutation checks: with substitution off, stale put-back off, or migration off, the test fails.
- Fixture additions to `editreaper.lua`:
  - item `I_CUSTOMCOLOR` (written as REAPER writes it: `COLOR n R` after `MUTE`);
  - `GetItemProjectContext`;
  - `GetNumRegionsOrMarkers` returning 0. Without it, `band.apply_markers`' lane step ended in an error after the markers were applied, so
    any received timeline counted as skipped.

## REAPER checks for James (real computers)

1. **The laptop's Cross Test (it has `hold = "1"` saved):** open it with the new version.
   - The log says "Hold my changes was removed: this project's held changes go out now" once.
   - Anything changed there since goes to the desktop within a pass.
   - Band timeline changes (markers, renumbering, render matrix) land on it.
   - Restart REAPER: the line doesn't come back, and edits keep going out.
2. **Colour try:** Colours, with "Try it on this computer first" ticked (the default) > Colour all tracks (and Colour items, a region scheme).
   - On the other computer: no colour change, and no "changed a track" line in its log.
   - While trying, move an item and rename a tried track on the trying computer: both arrive on the other computer, the track keeping its
     old colour there.
   - Keep it for everyone: the colours arrive within about a second.
   - Try again, then Put it back: the colours return, and nothing appears on the other computer.
3. **Restart mid-try:** try a look, Ctrl+S, then kill REAPER (Task Manager) and start it again.
   - The project opens with the look put back, and the log says "a colour look was being tried when REAPER stopped: it's put back".
   - Nothing arrives on the other computer.
4. Settings > Advanced shows **Try things in a side room** (it opens Rooms), not Hold my changes. The sync pill has no "Holding" pill.
5. Sync and exit starts at Saving, with no Hold question.
6. A toolbar button or key that ran "StudioSync - Hold my changes": after a REAPER restart the action is gone from the Actions list. A
   leftover button does nothing.

## Untested, limits

- `mirror.with_colour_line` inserts a `COLOR` line after `MUTE` when the try cleared an item's colour (scheme to none) and Put back or the
  band needs the old one. That placement matches REAPER 7's chunks (checked on a local .RPP: `MUTE`, then `COLOR n R`, then `SEL`), but no
  live REAPER run tested it.
- On a Mac, the old COLOR line is built with REAPER's `B` suffix taken from the current line, or from `GetOS` when there is none. Untested on
  a Mac.
- Put back sets a marker's colour with `SetProjectMarkerByIndex2`, where colour 0 means "leave it". A region that had no colour before the
  try keeps the tried one. That limit already existed.
- A bandmate's change landing on a tried track or item replaces the tried colour there. Keep then sends nothing for it, and Put back leaves
  it alone.
- A peer still on an older version may publish `hold = true`. The handover check no longer mentions it.
- `lib/files.txt` (the release manifest) still lists `StudioSync - Hold my changes.lua`. `tools/make_index.py` regenerates it at release.
- `test_0_60_rt_webpages.lua` fails in the shared worktree because of another agent's uncommitted `lib/webpages.lua` and `lib/live.lua`
  (`live.builtin_audio`). It passes on the tree committed here.

## Review-later (security)

- The colour try's ExtState data (`colour try data <proj>`) and ProjExtState `colour try` are trusted as written by this computer's panel.
  A hostile script on the same computer could make mirror withhold colour changes, or put colours back on open. That is local-only and
  can't send anything a person couldn't already send. Size isn't capped: it is one entry per tried track, item or marker.
- The migration only clears a key and logs; nothing received is involved.

## Files

- Mine:
  - code: `lib/colours.lua` (try), `lib/band.lua` (`colour_try`, `untried`, `mark_key`, `capture_markers`), `lib/mirror.lua` (`on_open`,
    try reading, Hold removal), `lib/sync.lua`, `lib/leave.lua`, `lib/status.lua`, `lib/controllers.lua`, `lib/api.lua`,
    `lib/debugmode.lua`, `lib/rooms.lua`;
  - tests: `tests/test_0_60_rt_nohold.lua`, `tests/fixtures/editreaper.lua` (three additions), and the test edits listed above;
  - docs: `README.md`, `docs/API.md`, this doc.
- Shared files, changed only for Hold:
  - `StudioSync - Live sync.lua`: Hold removed, plus the try-stamp look trigger;
  - `StudioSync - Panel.lua`: the switch, pill and verb, and the header comment;
  - `lib/page_health.lua`: the row.
- Deleted: `StudioSync - Hold my changes.lua`, `tests/test_0_60_rt_edits_hold.lua`.
- `lib/liveaudio.lua` and `lib/hub.lua` were not touched (their "hold" is hold-to-talk, unrelated).
