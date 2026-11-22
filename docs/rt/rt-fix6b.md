# rt-fix6b: audio, transport and rig fixes from rt-r1's re-check (2026-11-21)

Fixes for what rt-r1 found (`docs/rt/rt-p11.md` "REAPER check results", `rt-answers.md` checks 9-10, `rt-linkmove.md` check E, `rt-lab.md`).
Offline builds and tests only, plus read-only reads on the test computers (the laptop's `reaper.ini`, its clocks, and the live audio
status on the laptop and desktop through their eval hooks). No sound test ran: the orchestrator's re-check had the computers. The C++ needs
the extension release after 1.0.36.

## 1. The laptop played the desktop's Play 1.5-2 % fast (`extension/rtaudio.cpp`)

**Cause.** AOO's drift correction reads each stream at (the sender's rate / this computer's rate). Each side's rate comes from
`clock_step`: the earliest callback in each 2 s span, against the nominal block count, with the slope over up to 10 minutes. A callback that
never comes (REAPER busy loading or restarting, the device reopened at the same rate, an ASIO driver skipping buffers under load) or the
computer's clock being set shows up as a **step** in those minima, and the slope took it as rate for up to 10 minutes, clamped at 2 %.
- The tone ladder came in at 446.5 Hz (r3, x1.0148) and 448.8 Hz (r4, x1.0199) two minutes later. 2.0 % is `clock_step`'s clamp, and the
  rise between the runs fits its ramp-in (the share used grows from 2 to 10 minutes of history). A whole 2 % with the clamp means a step of
  about 1.2 s in a one-minute window, or 12 s in a ten-minute one.
- Seen live after today's deploy: the desktop's status read `clock_ppm` **-1823.7**, `clock_used_ppm` -1455.4, 8.4 minutes after the
  restart (callbacks 47356 x 512). That's about 0.9 s of callbacks lost to the restart, taken as rate. Every bandmate would play the desktop
  0.15 % slow until it left the window. The laptop read -61.6 just after its restart and settled at -59.4 over 7 minutes (polled every
  90 s), so its estimate is fine while nothing stalls. rt-r1's "-59 ppm" was read at some other time than r3/r4.
- Ruled out. The laptop's REAPER runs ASIO "Yamaha Steinberg USB ASIO" (not Voicemeeter) at 48000 / 128 (`reaper.ini`: mode=3,
  asio_srate=48000, asio_srate_use=0, so REAPER uses the driver's rate). In r3/r4/r6 the laptop's callbacks came at 375.0 a second on the
  link clock (= 48000 / 128, 47999.9 measured). Its wall clock against QPC was within 1 ppm over 30 s (W32Time isn't running). REAPER's
  block size against its rate is consistent (`seen_sr` 48000, `block` 128). A local 512 -> 128 run reproduces nothing (440.00 Hz both
  ways), so the block sizes aren't it either. LinuxBox heard the same stream at 440.0, so the desktop's own stamps were right at that time.
  The fast reading was on the laptop's sinks.

**Fix, two parts:**
- `clock_step`: a jump between one span's minimum and the next of more than `CLK_STEP` (25 ms) + 2 blocks is taken out of the minima after
  it (`off`) and counted (`clock_steps` in the status). Voicemeeter's staircase (one 10 ms buffer at a time) stays in, as designed.
- **Read-rate servo** (receiver side, "robust either way"): each stream's read rate follows the **slope** of its measured fill (the fill
  averaged over each 1 s window against the window before). Only three slopes in a row with the same sign, each past 0.1 %, count, and
  then the smallest of them less 0.1 % (60 % of that). A burst after a stall, a shed or a re-buffer moves one or two windows, never three,
  and shed and re-buffer also restart the windows. A bursty network whose buffer sits low on average has no slope. Slopes under 0.1 % are
  the fill's own noise (it is measured in Opus frames) and are left to AOO's correction. The total stays within 3 %.
  It reaches AOO through the time `rt_mix` gives each sink (`toff`): AOO's sink takes its own rate from those times
  (kAooPreciseTimestamp), so a sink timed 1 % fast reads 1 % faster. So the receiver plays at the real arrival rate against the sender's
  clock, whatever either estimate says. Status per peer: `rate_ppm`, `play_rate_ppm`, `mix_rate_ppm`.
  Versions that didn't work, against the full native test:
  - Steering from the fill's *level* (PI) drained the buffers P11 sheds and learned a Wi-Fi burst's low average as a rate. The trim,
    play-resync and drift checks failed.
  - Every slope taken (no 0.1 % floor) random-walked the drift test's buffer by 0.1-0.5 ms a second.
  - A small level nudge (0.1 %) drained it by 1 ms a second after its stalls.

## 2. The desktop's ears tap of the laptop's Play was silent (`tools/ears`)

**Cause: the tap's timing, not `rt_ears`.** The desktop's tap (`r6_d.wav.json`) ran 1795308811.3-841.3 on the laptop's link clock. The
laptop's Play went out at 851.4-861.2 (`r6_l.wav.json` and its WAV). So the tap ended 10.1 s before the sound. It had been started by hand
39 s before the fire, ahead of the polls and the laptop's own tap. The desktop's poll does have the laptop's `play_level` at 0.5, but only
in its last 0.4 s (853.2-853.5). `rt_ears`' slot choice (by peer name, then `same_addr` in `hear`) is right, and P11's native test covers it.
- `rig.sh live` takes `TAP="l x"` (receivers): after the polls, each receiver's tap of the sender's Play (its hub mix with HUB), then the
  sender's own, then the fire right away, and fetches the WAVs with their `.json`.
- `ears.py wav`: a silent GOT is an error ("GOT is silent"), and with `--stamps` it gets `tap_window`, which says where the tap ran against
  the sound. Run on r6 it says: "GOT's tap ended 10.1 s before the sound went out".
- `ears.py wav` also has a **speed** check: the pattern's tone found in each recording on its own, so `speed` = got/ref, passing within
  0.2 %. On rt-r1's files: r3 1.01498, r4 1.01987 (both fail), r5 (LinuxBox) 1.00016 (pass).

## 3. Pause then stop on the leader (`lib/together.lua`, Live sync)
`together.side_press(playing, paused, was_playing, was_paused, jumped)`: a press is passed on when play/stop changes, on a seek while
playing, **or when a pause turns into a stop** (play state 2 -> 0 was "not playing" both times). Live sync keeps `side.paused`. A stop from
a pause goes out at the position where the song stayed, so a paused follower reaches it by position (two readings) instead of by the 2 s
time backstop. rt-fix5's put-back then runs on that stop.

## 4. Record together a bar out with record pre-roll (`lib/together.lua`, Live sync)
`together.preroll(proj, pos)`: with "Pre-roll: Toggle pre-roll on record" (41819) on, `prerollmeas` bars (`get_config_var_string`) before
`pos` by the tempo map, else 0. A computer that presses Record itself sets `transport.pre` once per cue. That excludes a play-along
follower, a side-by-side follower, and a computer with nothing armed. `together.plan` then fires that much sooner, from the same place, so
its playhead is at the start when everyone else's is. A late start is as far in as the others are. The Beat page's count-down
(`together_from`) still ends where the playhead reaches the start.

## 5. Syncthing 1.27 has no fswatcher-timeouts (`lib/services.lua`, Live sync)
`services.no_such_setting(r, key)`: an answer with exit code > 0 that names the key ("No help topic for 'fswatcher-timeouts'", exit 3) means
this Syncthing has no such setting. `tune_band_folder` skips it quietly and goes on (versioning, auto-accept, label). A missing folder names
the folder, so it is still "didn't answer". A set that timed out (REAPER's -1005, or Windows' 259) is now "didn't answer setting <key>"
(tried again), not "couldn't set". Live sync's retries back off: 30 s, then 60, 120, 240, then every 300 s (10 tries).

## 6. "live audio didn't start" every 10 s (`lib/liveaudio.lua`)
`liveaudio.fail_new(why)`: the reason is said once, then only when it changes, and is cleared by a start that works. Health's live audio
row shows "didn't start: <why>" when the extension's own error is empty.

## Tests (each fails without its change)
- `tests/rtaudio_test.cpp` (`rtaudio_test rate`; also in `underruns` and the full run):
  - `clock_tests`: a 102 ppm slow device with stalls of 1.2 and 0.4 s and its clock set back 0.8 s reads -101 ppm. Without the step
    removal it reads -1448: fail.
  - `rate_test`: P (512) sends 440 Hz to Q (128) with Q's clock estimate made 1.5 % wrong (`rt_test_clock_bias`). With the servo: 440.40 Hz
    at 20-25 s, 2 underruns while it learns and none in the last 14 s, Talk's `rate_ppm` -14096 (the exact correction is -14778). Without
    it: 4 underruns by 12 s and 6 by 26 s, `rate_ppm` 0, pitch off: 3 fails.

## Checks run (offline)
- `tests\build_rtaudio_test.cmd` (the full run, which includes P11's trim, play-resync, the drift and burst tests, and the hub): `ok,
  fails 0`. The drift test with stalls reads -0.017 ms/s (it reads -1.0 with the level nudge, so that was taken out).
- `tests\build_nat_audio_test.cmd`: `ok, fails 0`.
- `extension\build_windows.cmd` with `DLL_OUT` in my scratch folder: builds. The tracked DLL wasn't touched.
- `python -m unittest discover -s tools/ears`: 10 tests OK.
- `python tests/run.py --no-luals` in a clean clone of the commit, local time and `TZ=UTC0`: `fails 0` both.
- `tests/test_0_60_rt_fix6b.lua`: side_press and Live sync's use of it; preroll (1 bar at 130 bpm = 1.846 s; off, unreadable: 0) and plan
  with `pre`; Syncthing 1.27's answer skipped with versioning still set, -1005 as "didn't answer", a real refusal still "couldn't set"; the
  retry back-off; fail_new and Health's row. Against HEAD's lib: fails at the first assert (no side_press).
- `tools/ears/test_ears.py`: `test_wav_speed_and_silent_tap` (1.5 % fast fails `speed`, 1:1 passes; a silent GOT errors; `tap_window`
  says "ended").

## REAPER checks (desktop, laptop, LinuxBox; the extension build after 1.0.36)
1. **Clock steps.** Restart REAPER on the desktop, wait 3 minutes, then read `StudioSync_LiveAudioStatus()`. Expected: `clock_steps` >= 1
   if the restart stalled callbacks, and `clock_ppm` within a few hundred ppm of 0 (it read -1824 today). The same on the laptop after a
   project load.
2. **The ears re-run, desktop -> laptop** (rt-p11 check 1), with the taps in the run:
   `TAP="l" OUT=<scratch> tools/ears/rig.sh live r7 d`, after the usual setup (`load`, `track add=true`, `live role=send` on the desktop,
   `live role=recv volume=0` on the laptop). Then `python tools/ears/ears.py wav <OUT>/r7_d.wav <OUT>/r7_l.wav --pattern <OUT>/pattern
   --stamps`. **Pass:** `speed` within 0.2 % (it was 1.015/1.020), `no_gaps`, `steady`. The laptop's `play_underruns`/`play_resyncs` are
   unchanged through the run, and `play_rate_ppm` is small (under ~1000) unless its estimate was off.
3. **Laptop -> desktop** (r6 again): `TAP="d" ... rig.sh live r8 l`, then `ears.py wav r8_l.wav r8_d.wav --pattern ... --stamps`: not
   silent, `speed`, `no_gaps`.
4. **Idle 8 minutes** with the desktop's Play stream up and silent: the laptop's `play_resyncs` doesn't climb (it went 12 -> 51).
5. **Pause then stop** (rt-answers check 9's setup): pause on the desktop. The followers pause. Then Stop on the desktop. The followers stop
   within a second, and their own selections come back.
6. **Record pre-roll** (check 10's setup, desktop with `preroll` 2, `prerollmeas` 1): Record together. In a defer sampler, desktop t - pos
   equals the followers' t - pos within ~50 ms (it was 1.85 s apart). The desktop's take starts at the start position.
7. **LinuxBox Syncthing:** start Live sync on LinuxBox. No "didn't answer" line. `syncthing cli config folders <id> versioning type get`
   says `staggered`.
8. **LinuxBox2 without Tailscale:** one "live audio didn't start: Tailscale isn't up here ..." in its log, not one every 10 s. Health's
   live audio row says it.

## Untested / limits
- Nothing ran in REAPER. The servo was checked on localhost with a forced 1.5 % error and the existing burst, stall and shed tests, not a
  real internet link. Its windows are 1 s. A drift that drains a buffer within ~3 s (2 % on a 30-60 ms buffer) underruns once or twice
  before three slopes agree; after that it holds. A residual under 0.1 % (1 ms a second) is left to AOO's correction and the shed and
  adaptive size, as before.
- The servo's rate also stretches AOO's own timers for that sink (pings, resend, inactivity) by the same <= 3 %.
- The pre-roll comes from REAPER's current setting when the cue arrives. A pre-roll changed in the seconds before the start isn't seen.
  `prerollmeas` is read through `get_config_var_string`; a REAPER too old for it (before 6.x) leaves pre 0, as before.
- The step threshold (25 ms + 2 blocks) keeps a two-buffer Voicemeeter drop in one span as rate. A stall shorter than that is still rate
  until it leaves the window, but such a stall is at most ~40 ppm over 10 minutes.

## Review later (security)
- No new inputs from the link. `rt_test_clock_bias` is a test hook in the C API (not a ReaScript function).
- The status JSON gains `clock_steps`, `rate_ppm`, `play_rate_ppm`, `mix_rate_ppm` (numbers only).
