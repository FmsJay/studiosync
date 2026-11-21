# rt-hubwatch: a listener's own stall isn't the hub's silence

2026-11-21. C++ (`extension/rtaudio.cpp`, `extension/rtaudio.h`: the test hook's declaration) and `tests/rtaudio_test.cpp`. Needs an
extension release; EXT_VERSION not bumped, no binaries committed. Implements rt-hubsmall item 1, with one change to its design (below).

## What changed

- `hub_watch`: `WATCH_LATE` = 20 ms. A pass that comes more than that after the last one (the send loop wakes every 5 ms) counts as a
  stall (`stalls`, `stall_max`). While hearing the mix (state 2), the mix's age is
  `quiet = min(raw, max(0, now - watch_free - WATCH_LATE))`: from a late pass the receive thread gets WATCH_LATE to take what waited in the
  socket before the age counts again. `flowing` (fallback) and `via` (rescue) both use it. Joining keeps the raw age.
- Status hub block: `"stalls"` (late passes of the send thread, whole session; a reconfigure's pause counts too) and `"stall_max_ms"`.
- Test hook `rt_test_hold_tx(l, ms)`: the send loop sleeps in 1 ms steps until then, as `rt_test_hold` does for the receive loop.

## What I changed from the proposal, and why

1. **Once per silence.** As written, every late pass set `watch_free = now`. A send thread that is late on *every* pass (a loaded
   machine: held 30 ms every 35 ms) then never falls back on a hub that really stopped: quiet is reset each pass. The test shows it: with the
   proposal as written, Y was still "hub" 300 ms into a 400 ms outage, 0 fallbacks. Now a late pass renews `watch_free` only if a mix
   datagram came since the last renewal (`h->mix_at > watch_free`). A real outage falls back at most WATCH_LATE + gone after the first late
   pass in it. Cost: two stalls back to back with no mix datagram taken between them get one wait, not two (both threads would have to stay
   starved in between).
2. **WATCH_LATE of grace after the late pass** (`- WATCH_LATE`). In the proposal quiet restarts at 0 on the late pass itself, so if the
   receive thread wakes even ~15 ms after the send thread (a VM resumes threads at different moments; the Mac runner's 1 ms sleeps run
   5-13 ms), the first hold's rescue line (~15 ms, before mix_gap learns the stall) is crossed: a rescue. Cost: a real outage that begins in
   a stall falls back 20 ms later.

## Tests (local, Windows, scratch export)

`rtaudio_test stalls` (also in the full run and `underruns`): H mixes for W, X, Y (30 ms buffers, gone at 50 ms).
- X's send thread held 150 ms and its receive thread 160 ms (it wakes second: the failing order), five times: stalls 0 -> 5 (longest
  151 ms), fallbacks 0, rescues 0, "hub" throughout.
- H's mix stopped 400 ms: X, held once more inside it, is "direct" 300 ms in (+1 fallback); Y, send thread held 30 ms every 35 ms, "direct"
  300 ms in (+1 fallback, 11 stalls); W, not held, +1 rescue +1 fallback, as before.
- Each part fails with its fix taken out: without the shield, X fell back 2 times (no rescue first, LinuxBox's signature) and was "direct"
  before the outage; with the proposal's renew-every-pass, Y never fell back.
- Full `rtaudio_test` (fine timers, SS_TIMING_STRICT on by default locally): `ok, fails 0`, nothing passed over. The hub test's drop
  ("X's status: direct, one fallback"), rescue_test (1 rescue in 6, through H throughout), switch, start order, spikes, clock, hub load all pass.

CI to watch: the `stalls:` lines on the Mac. Timing checks go through `check_unless_stalled`; the hold ordering has 35 ms of margin before
the first rescue line (receive thread up to 10 ms + a tick later than the send thread, then WATCH_LATE + ~15 ms). "and nothing else here was
a stall" is the most likely to be passed over on a stalling runner (an unseen stall of X's send thread alone would also show there).

## A listener's status now

`"hub":{..., "mix_gap_ms":..., "level":..., "stalls":5, "stall_max_ms":151.5}`.

## Checks after the release

- LinuxBox, same four-computer sound test: note the hub block before and after. `stalls` grows; `fallbacks` should stop growing without a
  `rescues` step before each (24 vs 7 before). `overflows` will still grow (the send queue still fills during a deschedule).
- Desktop / laptop / Mac: `stalls` stays near 0 (a few from reconfigure pauses). Their fallbacks still come with a rescue first (Wi-Fi):
  that's rt-hubsmall's "not recommended yet" item.
- Hand the hub off or quit the hub's REAPER: listeners still go direct within about a buffer (the hub-drop test's case).

## Check results (rt-r0, 2026-11-21, extension 1.0.34)

Without a sound test (Deafen stayed 1 everywhere): `StudioSync_LiveAudioStatus`'s hub block has `stalls` and `stall_max_ms` on all three.
LinuxBox: `stalls` 31, `stall_max_ms` 86.7 while not serving or listening to a hub (state direct); desktop and laptop 0. `fallbacks` and
`rescues` 0 everywhere (no hub in use). The before/after comparison during a four-computer sound test and the hub hand-off: not run.

## Found, not changed

- After a stall the receive thread's widest spacing (`mix_gap`) learns the stall (150 ms) for up to 60 s (GAP_SPAN), so the rescue line
  is then above `gone` and a real hub drop on that listener falls back without the early rescue (a longer gap). The same is true today. Fixing
  it means telling the receive thread which gaps were this computer's own stall; the threads race on who sees it first. Left for a later look.

## Left

- `python tests/run.py --no-luals` in a clean clone of the commit: not run (session ended). No Lua changed.
- Not pushed; CI not watched (the coordinator pushes).

## Security

No change to what's accepted or from whom. The new hook is test-only (an atomic the extension never sets).
