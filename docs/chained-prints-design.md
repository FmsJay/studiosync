# Chained prints

James, 2026-11-19. Status: built in 0.59.49 (lib/prints.lua "chained prints": `prints.split`, `prints.assign`, `relay_plan`,
`relay_stage`; `sync.print_file`; the cap is band.json `print_hops`, Settings > Studio). Where the build differs from the design:

- Stage files are `stage-<oid>-<print hash>-<k>-<split hash>-<who>.flac` in the room's media folder, beside prints. The print hash covers
  the part and the whole chain, so a change anywhere renders every stage again (no reuse of stages 1..k-1 when only stage k's plug-in
  changed). Once the print is attached its item's stage files are deleted; trimming a print also takes its stages (lib/trim.lua).
- Who renders a run: whoever changed the part if here and able, else whoever here has most of the chain, then by name; nobody here: the
  same among everyone, and Health says the relay waits for them.
- Linked knobs keep a part out whenever any knob on its chain is linked to another plug-in (not only across stages). FX containers,
  plug-ins running in parallel and tracks of more than two channels are kept out too. MIDI-only receives (a sampler fed by several MIDI
  tracks) are fine; audio receives are not.
- A stage waits the 3 s every print waits (`prints.SETTLE`), not `prints.QUIET`.

## The gap

A print (an item's wet take) is rendered only by a computer on which **every** plug-in of the track loads
(`prints.refresh` -> `prints.track_plays(tr, true)`). When no single computer has the whole chain, nobody prints,
and each computer hears the chain with its own missing plug-ins skipped (REAPER passes audio through an offline
plug-in).

Example: the laptop has an EQ the desktop lacks; the desktop has an amp modeler, placed after the EQ, that the
laptop lacks. Today the laptop hears no amp, the desktop hears no EQ, and nobody hears the part as written.

## Idea

Render the chain in **stages**, each on a computer that has that stage's plug-ins, passing the audio along:

    dry --(laptop: [EQ])--> stage 1 file --(desktop: [amp, ...])--> final print

The last stage's output is the print, attached as today (`attach`), and played by Auto wherever the chain doesn't
fully load (unchanged).

## Splitting the chain

1. Walk the track's chain in order (instrument first for MIDI; a routed instrument's track counts as the head of
   the chain, as `prints.route` does now).
2. For each plug-in, the set of computers that have it: everyone's published list (`plugins.band`, the same data
   `prints.lacking` uses). Stock JSFX and Cockos effects count as everyone's.
3. Greedy runs: start with the computers that have plug-in 1, keep extending while the running intersection is non-empty;
   when it empties, close the run and start the next. That gives the fewest stages for the given order.
4. Each run is assigned to one computer of its set: prefer whoever changed the part, then whoever has the most of the
   chain, then the lowest device id (deterministic, so two computers never both take a stage).

A chain that needs N runs needs N-1 hand-overs ("hops").

## Rendering a stage

- Input: the previous stage's file (stage 1: the dry take or MIDI).
- On the stage's computer: a scratch copy of the track (as background prints already make: `bgrender`) with only
  that run's plug-ins enabled, the input placed as the item's source, rendered with the tail (as prints do).
- Output: `<room>/media/prints/stage-<oid>-<k>-<prefixhash>-<who>.flac`, moved in whole (the existing tmp-then-rename
  path), so a half-written stage never travels.
- `prefixhash` = hash(dry source hash, chain text of plug-ins 1..end-of-run k, the run's automation and modulation).
  Like print names today, the name says what it was made from: going back to an earlier state finds its files, and
  changing a plug-in in stage 3 re-renders stages 3.. only; stages 1-2 are reused.

## Hand-over

No new messaging: the next stage's computer sees the stage file arrive in the shared folder (the same listing the
print code already reads) whose `prefixhash` matches what its own chain says stage k should be, and renders stage k+1.
It never renders from a stale stage: the hash covers everything upstream.

## Limits and settings

- **Hop cap** (Settings > Advanced, per studio, owner's setting so everyone agrees): 0 = off (today's behaviour),
  1, 2 (default: covers the two-computer case above), 3, no cap. A chain needing more hops than the cap gets today's
  behaviour, and Health says why ("Bass needs 3 hand-overs to print; the studio allows 2").
- **Quiet wait**: a stage renders only after its part and chain have been left alone (as long prints wait for
  `prints.QUIET` now), so turning a knob doesn't start a relay on every move; background rendering stays preferred.
- **Who's online**: if a stage's computer isn't online, the relay stops there; the part plays as today (each computer's
  own partial chain), and Health lists the waiting stage and whose computer it needs. When that computer comes back it
  picks up from the last finished stage.
- **Latency**: each hop is one render plus a Syncthing transit (seconds). Fine for recorded parts; not for live
  playing.

## What it can't do (stays as today)

- Sidechains from other tracks, sends into the chain, feedback routing.
- Parameter modulation or links between plug-ins in different stages.
- Real time / jam modes (rendered material only).
- The master track: re-rendering the whole mix on every change is too costly. Instead (0.59.49): Health flags
  master plug-ins someone lacks, and the master's plug-in picker defaults to "Only what everyone has".

## Cost

- Disk/network: one extra FLAC per hop per part version (stage files of superseded versions trimmed with prints).
- CPU: one stage render per computer per change, instead of one full render on one computer.
- Nothing per look beyond the listing the print code already reads.

## Open questions for James

1. Default hop cap: 2?
2. Should the cap be per studio (owner decides) or per computer?
3. When a relay is waiting on an offline computer for a long time, should Health show it, or stay quiet unless the
   part is played?
