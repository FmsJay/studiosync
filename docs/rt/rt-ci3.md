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

## rtaudio_test on the Mac (added later the same day)

Five `tests/rtaudio_test.cpp` checks failed on the hosted Mac only. None is a regression from 4b8e211 (hub 'H' membership) or 8091554:
the same checks pass on the same commits whenever the runner doesn't stall, and two of them failed before 4b8e211 existed.

Three were a stall of the test process, in checks that had no stall guard while the ones beside them did:

| Check | Run | What the log shows |
|---|---|---|
| hub: the hop through H adds a little latency | 44825802025 | The test stalled 381 ms. W and X had asked their streams back, and W sent to all three again (626 datagrams a second, 220 through a hub). X heard W directly: 43 ms both ways, +0. Six checks beside it were passed over for the stall. |
| start order: after the owner's pick, everyone at full level | 44819565221 attempt 2 | The test stalled 419 ms inside the last 1.3 s that the levels are read in. Every level was 72-75% of its own, and everyone was back on direct streams. |
| hub: peer to peer, each at its own level | 44820984871 | All nine levels were 63-66% of their own in the 0.6 s window, before any hub was on: one gap for everyone. The log didn't print the stall. It does now. |

All three now go through `check_unless_stalled` with the test's own longest stall, like the checks beside them. Locally and with
SS_TIMING_STRICT on they are checked as before.

Two were coarse timers stretching the test's own injected holds. `rt_test_hold` ends on the receive thread's 1 ms sleeps, which run
5-13 ms on the hosted Mac, so a "110 ms" or "60 ms" hold is up to a tick longer, by a different amount each time. The test's loop can't
see that (it spins, and reported no stall):

| Check | Runs | Why |
|---|---|---|
| rescue: only the first stall asks everyone's streams back | 44787346094 attempt 2, 44795192770 attempt 3, 44819565221 attempt 1 (2 rescues each, the limit was 1) | A hold more than 5 ms (RESCUE_PAD) longer than every one before it is a new widest spacing, so it asks once more. That is the design learning the link, not the old fault (every stall asked: 6 of 6). |
| spikes: spikes close together are held | 44787346094 attempt 1, 44819565221 attempt 1, 44818861223 attempt 2 (4 underruns in the second half, the limit was 3) | Each 10 ms a spike runs longer is one more step for the buffer to grow, and an underrun for it. |

Reproduced on the desktop by making only that hold's sleep coarse (a scratch copy of `rtaudio.cpp`): with 1 ms, 5 of 5 runs gave 1
rescue and 2 late underruns. With 7 and 13 ms, 3 of 10 gave 2 rescues and 3 of 10 gave 4 late underruns. So on coarse timers (a 1 ms
sleep over 2 ms, measured as hopnet_test does) with SS_TIMING_STRICT off, rescue allows half the stalls (3 of 6) and spikes half of the
last ten (5). Fine timers and local runs keep 1 and 3.

One more, not seen in CI yet but close: "rescue: X hears through H throughout". A hold that runs to 120 ms is past the mix's 100 ms
buffer + GONE_PAD, so the hub rightly counts as gone and X goes direct. The Mac's widest hold so far was 119.2 ms. With the hold's sleep
made 13 ms here, 4 of 6 runs went over and failed it. On coarse timers a widest spacing of 120 ms or more is now passed over as the
test's own stall. After that change, 6 of 6 runs passed at 13 ms (6 of 6 at 7 ms had passed before it: none of those reached 120 ms).

Verified locally: the whole of rtaudio_test passes with fine timers and SS_TIMING_STRICT on (`fails 0`), built into my scratch folder
so it didn't collide with anyone's build in `%TEMP%\ss_rtaudio_test`.

## Not changed / left

- `nat_test` hung on the Mac in run 44818861223 attempt 2: no output after "network change on A ... up again 1240 ms after the change"
  for 50 minutes, until I cancelled the run. The workflow has no `timeout-minutes`, so a hang holds the job for hours. rt-nat3's to look at.
- The note-off weakness rt-hopvst noted is real but not what failed here. While MIDI keeps flowing, every MIDI packet carries the last 32
  events again. Only the *last* event before a silence relies on two copies (at once and 20 ms on), so a burst loss over both hangs that
  note until the try stops. If that turns up in use, a third copy (say 60 ms on), or a note-off sweep when the try stops, would cover it.
- No security impact: only the test changed.
