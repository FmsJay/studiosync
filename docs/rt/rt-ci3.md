# rt-ci3: the Mac job's "most notes land under loss" failures (2026-11-20)

## What it was

The Mac job failed `tests/hopnet_test.cpp:505`, "most notes land under loss (20 of 24)", in runs 44806841281, 44803663250 (attempt 1)
and 44787346094. Reruns passed and Linux always passed. This is rt-hopvst's MIDI-through-hops check from 67c5b4c.

**It isn't a MIDI weakness, and it isn't really the coarse timers either. It's the check:**

- The fake instrument's click goes back inside the audio. If the note's frame lands in an audio hole (2% packet loss each way loses about
  5.5% of frames, as silence or the fade after it), the click is lost with the audio, whatever the MIDI did.
- In every failing and passing log the remote took every MIDI number (`"midi":25` for 24 counted notes), and `wrong` was 0. A late MIDI
  event would play at X's block start and show up as a wrong frame.
- I classified every missed note locally, at fine timers (10 runs) and with Mac-like 6 ms ticks emulated in the harness and the hop's loop
  (10 runs). All 32 misses were frames whose audio didn't come back (zero or fading). None came back with its audio but without the click.
- Why only the Mac: the wire's loss RNG is seeded, so with fine timers the packets split the same way each run. Linux and Windows lose the
  same 2 of 26 notes every time (every Linux job surveyed since 67c5b4c showed 24/26). Coarse ticks split packets differently each run, so the Mac
  draws fresh: 24 notes at about 5.5-7% each miss 4 or more about 5-10% of the time, and the old line allowed at most 3.

## What changed (test only)

`tests/hopnet_test.cpp`:
- `Result.ev_holed`: notes whose frame's audio didn't come back (neither the click value nor the plain audio value). The report prints it.
- The loss run now checks, strictly everywhere: **every note whose audio came back lands on its exact frame** (`ev_exact + ev_holed ==
  events`). This is stricter about the MIDI than the old 85%, since one MIDI miss now fails it. It also checks that the remote took every
  note under loss (each note goes in several packets: its own, the 20 ms repeat, and every later MIDI packet's window). "Most notes land"
  stays as a check that the run actually happened, at 70% (24 notes at a 7% miss rate fall under it far less than once in 1000 runs).
- Unchanged: the hiccup skip (a harness stall with SS_TIMING_STRICT off), the lossless MIDI run, and everything else.

Verified: `tests\build_hopnet_test.cmd` passes (24/26, 2 in audio holes). 12 runs of the loss scenario with 6 ms ticks all passed
(20-24 of 24 exact, every miss in an audio hole). The old line would have failed 2 of the 12. CI runs: see the report.

## Not changed / left

- The note-off weakness rt-hopvst noted is real but not what failed here. While MIDI keeps flowing, every MIDI packet carries the last 32
  events again. Only the *last* event before a silence relies on two copies (at once and 20 ms on), so a burst loss over both hangs that
  note until the try stops. If that turns up in use, a third copy (say 60 ms on), or a note-off sweep when the try stops, would cover it.
- No security impact: only the test changed.
