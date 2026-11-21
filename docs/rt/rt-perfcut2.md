# Three cuts from rt-perf, in the looks (rt-perfcut2)

Cut short by a desktop restart. The code for all three cuts and for holding `mirror.root` is in, with unit checks in
`tests/test_0_60_rt_perfcut2.lua`. The bigproj-level tests and the offline measurements are not done (see "Left"). Offline only: nothing ran
in REAPER.

## What changed

**Cut 2: real MIDI pools** (`lib/mirror.lua`: `mirror.pool_ids`, `mirror.shared_pools`, `mirror.in_pool`, `mirror.scan`, `mirror.quick_scan`,
`mirror.item_states`).
- Rule: a track counts as pooled only when it holds a `POOLEDEVTS` GUID that two or more items in the project hold (on any tracks, or twice
  on one). REAPER writes the token into every MIDI item (rt-perf probe 13: 60 items, 60 GUIDs).
- Each look keeps each track's pool GUIDs with their item counts (`pools`) and the project's shared set (`L.shared`). A quick look counts
  read tracks from their new chunk and unread ones from the last look.
- A pool that forms during a look (a pooled copy on one track of an item on another): the other tracks holding it are read as pooled in the
  same look, so an edit to the pool made with it goes at once.
- What a real pool needs is kept: a pooled track is read every quick look and its items read again (`item_states` gets a per-track
  `pooled_tr`). Without that argument `item_states` behaves as before (any token counts).
- Expected saving (rt-perf's figures, not re-measured): ~25-30 ms of a 63-74 ms edit look on the heavy song. The full look also stops
  reading every MIDI item's chunk again.

**Cut 4: redraw only when it helps** (`StudioSync - Live sync.lua` P.look and P.status; `mirror.counting_writes`).
- After a look, `t.redraw` is set only when it failed, sent something, put something back, or wrote to the project.
  - "Wrote" comes from `mirror.counting_writes`. It wraps REAPER's writers for the length of the look: `Set*`, `Delete*`, `Add*`,
    `Insert*`, `Move*`, `MIDI_Set*` and the like, and `GetSet*` with its last ("set") argument true.
  - ExtState, records and `P_EXT` notes don't count, since nothing on screen changes.
  - The writers are put back afterwards, also after an error.
- `TrackList_AdjustWindows` and `UpdateArrange` run only when this song's tab is in front. Before, a tab behind redrew the tab in front. A
  redraw due while behind is owed (`redraw_owed`) and runs the next pass the tab is in front.
- Saving: 7-24 ms per idle look (rt-perf), ~6-7 looks a minute.

**Cut 5: fewer full looks on heavy songs** (`mirror.full_every`, `L.full_took`).
- Rule: the timed full looks keep to `QUICK_FULL_SHARE` (0.2 %) of the main thread. Interval = clamp(full look's time / 0.002, 60 s, 300 s).
  - A small song (10-15 ms): every 60 s, as before.
  - The heavy song's 300-350 ms: every 150-175 s.
  - 0.6 s and over: every 300 s, the ceiling, so the safety net still runs.
- A full look's time is measured in `look_commit`, safety-net quick scan included. Undo, track-order and other forced full looks are unchanged.
- Saving: on the heavy song, about 2 of every 3 stalls of 300+ ms go.

**Also: `mirror.root` held between passes.**
- It's kept until the project's change count moves, this script writes a record (`setext` bumps `mirror.rec_writes`), or `ROOT_HOLD`
  (10 s) passes.
- Saving: 10-13 ms a pass on the heavy song.

**Not done: the colour look only with colour parity on.** It's built in `lib/sync.lua` (write_status) and `lib/colours.lua`. Both are outside
my files (sync.lua is off-limits), and `colours.look(proj)` has no studio root to ask `colours.parity` with. Left for the owner of those files:
in `sync.write_status`, call `colours.look` only when `colours.parity(cfg.root)`.

## Tests

`tests/test_0_60_rt_perfcut2.lua` covers:
- pool ids, and what's shared;
- `full_every` at small, heavy and huge;
- `counting_writes`: reads, P_EXT and records aren't writes; a chunk set and a GetSet with set are; writers are put back, also after an error;
- `mirror.root` held, then read again after ROOT_HOLD, after a change-count move, and after a record written here.

`test_0_60_rt_look`, `test_0_59_48_engine`, `test_0_59_49_engine` and `test_0_60_rt_edits` pass unchanged.

## Left (next steps)

1. **A bigproj test for cut 2 that fails without it**, in `tests/test_0_60_rt_perfcut2.lua`. Build the medium model as in
   `test_0_60_rt_look.lua`, and patch `G.item_chunk` so every MIDI item carries `POOLEDEVTS <its own GUID>`. Two items on two MIDI tracks
   share one GUID with `<SOURCE MIDIPOOL`. Then check:
   - (a) a selected audio item moved: chunk reads = its track + master + the two pool tracks, and no unpooled MIDI track's chunk is read;
   - (b) a note changed in both pooled items, only one hinted: both go in one look;
   - (c) a pooled copy made and edited in one look: both go.
2. **Measure offline** with rt-bigproj's harness (150 tracks, the same POOLEDEVTS patch): an unrelated edit's quick look, HEAD against this
   commit (chunk reads, calls, ms).
3. A test for the front-tab redraw gate. It can only be a source check: Live sync isn't run by the tests.

## Risks

- `counting_writes` swaps functions on the global `reaper` table during each look. If REAPER's table refused writes, or a module had cached a
  writer in a local at load time, a write would go uncounted, and that look wouldn't redraw. The next change-count move or write still
  redraws.
- A pool formed by another computer's change landing is counted from the next look that reads that track.
- `mirror.root` can be up to 10 s stale after a record written by another script with no change-count move. Health's apart check waits
  30 s, so that fits.
- `ACT_KEEP` (70 s) was sized "past the next full look". With heavy songs' full looks further apart, a part of an act only the safety net
  finds becomes its own Undo step. The every-chunk read each 10 s is unchanged.
- A first look that sends a whole song counts as a long full look, so the next timed one may be up to 5 minutes away.

## REAPER checks (desktop, later; rt-perf's probes in the scratch folder `rt-perf2/`)

1. Heavy project with the 12 synths, published into the test studio, perf stats on.
   - Move one selected audio item. The look lap should be ~35-45 ms, not 63-74 ms.
   - ExtState "look stats": missed stays 0.
2. Make a real pooled copy (Ctrl+drag with pooling on) of a MIDI item to another track, edit notes in one. Both change on the other computers
   in one look.
3. Idle 10 minutes on the heavy song: slow ticks of 300+ ms only every ~2.5-3 min, not every minute. Small song: full looks still every 60 s
   (look stats' full count).
4. With the heavy song behind and Cross Test in front: no `UpdateArrange` from the song behind. p6/window probes show no 16-24 ms redraws
   every look. Idle looks on Cross Test show a "redraw" lap of ~0 ms.
5. Refuse an edit (Claims mode) and check that the put-back shows at once (redrawn).

## Review-later (security)

None. Nothing received is parsed differently. `counting_writes` only observes local calls.
