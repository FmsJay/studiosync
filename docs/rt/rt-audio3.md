# rt-audio3: live audio on real, imperfect devices (2026-11-22)

From rt-r3's re-check on the real rig (extension 1.0.37; `rt-fix6b.md`, `rt-p11.md`, `rt-hubrank.md` results, and the evidence in the
scratchpad `rt-r3/ears/`), plus two additions from the coordinator: the growing Jam WAV's header (rt-fix8) and the browser guests' audio
(rt-t1). **Offline builds and tests only. Nothing ran in REAPER, on the test computers or in the VMs**; I read the desktop's own
StudioSync log file and rt-r3's saved polls. The C++ needs the extension release after 1.0.37 (EXT_VERSION not bumped, no binaries
committed). Re-check steps with numbers to hit are below.

## What the evidence said (root causes)

| # | Seen (rt-r3) | Root cause |
|---|---|---|
| 1 | The desktop's device 0.2-0.6 % short and changing; laptop -> desktop 0.25 % fast with 250 ms of gaps | **Reading at clock estimates.** Each end stamped its stream with an estimate of its device's rate (a ten-minute window, ramped in over ten minutes) and AOO read at the ratio. The desktop's device moves much faster than that: from rt-r3's own polls it ran 48024, 47404, 47619, 47970 Hz in four 10 s stretches of one run. In r9 it ran 47999 Hz for that minute while the estimate still said -3600 to -4500 ppm, so the desktop read the laptop 0.25 % too fast against a device at nominal and drained its buffer. |
| 2 | The laptop re-buffers the desktop's idle Play every 2 min, `play_rate_ppm` +-3000 | The same from the other side, plus rt-fix6b's servo: slope only, a 0.1 % dead band, three 1 s slopes in a row. A residual under the dead band walked the buffer into an underrun or a shed every couple of minutes. In r7 the desktop ran -2047 ppm and the laptop played its samples one for one (the old speed check passed that: see tools/ears). |
| 3 | LinuxBox's estimate -1008 to -1521 ppm at +135, with 275-375 "steps" | **fix6b's step removal took out every jump over 25 ms + 2 blocks, either way, at once.** A VM's callback timing creeps later and snaps back (PulseAudio's timer): the snaps back were taken out, the creep stayed, read as a slow device. `clock_tests` reproduces it: -2113 ppm at +135. |
| 4 | Fallbacks about once a minute through the hub, the hub's `stall_max_ms` 1613.8, one tap silent, one with 4 s gaps | Four things, from r13's polls lined up on one clock: (a) the desktop's live audio **restarted** mid-run (cause 6: its callback count starts again at 42.8 s) and Live sync then asked for its own plan; (b) a **host stall** on the desktop (REAPER's main thread frozen 1.1 s three times at 33-38 s while both peers' streams underran there: not StudioSync's); (c) a 175 ms gap on the laptop's path alone (Wi-Fi); (d) `stall_max_ms` counted the stop-to-start gap of a restart as a stall. The "silent" tap had ended before the pattern (the laptop's polls show the mix at 0.005, the right level, through the pattern); the "4 s gaps" are the 3.3 s a fallback spends on direct streams, which the `hub` tap doesn't hear. |
| 5 | The hub flapped on all four at 21:44:57-21:46:23; LinuxBox2 said "you're the hub" | The desktop's log has **17** such hand-offs between 20:05 and 23:08. `hub.lagging`: its Syncthing sat scanning (no status files for 150 s) while its direct link reached everyone the others reach. It took itself out and back in with each file. LinuxBox2 (no Tailscale, no link, files only) saw nobody once the desktop's files stopped, so it elected itself; its status said live audio "on" though its engine never started. |
| 6 | The desktop's live audio restarts itself, "Windows needs its firewall rule first" | **30 times between 19:27 and 22:44**, each back within a second. `direct.firewall_ok` reads netsh's text from a file its background run is still writing (lib/services.lua writes in place): a look at a half-written answer finds the rule's name but not yet its program, port or UDP twin. The same look restarted the direct link without listening, and the others' link watch took that for the hub dropping (21:11:33 -> the flap at 21:11:38). |
| 7 | Stamped latency 127.6 ms against `play_latency_ms` 152-171 | Not a constant error in the status: on one clock with nothing moving, the status says 37.9 ms where 37.9 to 42.9 is heard in three runs (`drift_tests`: within a block of each end). In r7 the laptop's buffer was draining 2 ms a second (cause 2), so the two numbers were read at different heights of a sawtooth; and `ears.py` counted the taps' lag at 48000 a second on a device running 47902. |

## What was built

### 1. The receive path reads from its own buffer, not from clock estimates (`extension/rtaudio.cpp`)
*(Round 2, at the end of this file, changed what the control holds the level at, added a rule for a level that jumps, and raised the default ceiling.)*
- **AOO is handed nominal times.** `clock_step` gives AOO one block after the other at the nominal rate; nothing reads at an estimate any more. The estimate stays for the status only (`clock_ppm`; `clock_used_ppm` is gone).
- **The read-rate control** (the comment at `RATE_*`): each stream is read at `1 + R + P`.
  - `R` is the bandmate's learned ratio (their device's real rate over this one's, less 1): one per bandmate, shared by its Talk, Play and mix. It integrates the level error, but only while P isn't getting its way (against 2 s ago, the level came back less than half of what P alone did since), so a level left off by a stall or a burst teaches it nothing.
  - `P` is proportional to the level error: the level's median over 0.5 s, less the level the stream settled at when it started (its buffer within 5 ms under and 12 ms over its size). Bounded: 0.2 % in the slow loop, 0.5 % (9 cents) in the fast one.
  - **The level is a time, not a count:** what the buffer held at the last read plus how old its newest packet was then (`arr_at` from the receive thread, `age` from `rt_mix`). The buffered count alone moves in the sender's blocks: with 256-sample blocks at both ends and 200 ppm between them it sat still for 26 s while the delay heard grew 5 ms, then jumped a whole block, so the control saw nothing and then a step. With the packet's age the level moves as the delay does (0.2 ms a second in that case). A newest packet older than 0.25 s at a read means nothing is coming: no level, the windows start again. An underrun starts them again too, also at the ceiling where the size stays.
  - Two speeds, faded between: slow (20 s) while the level stays within 6 ms; fast (4 s) for 10 s after a window further off, and for a bandmate's first seconds. As the fast loop fades, what P gives up goes into R, so the rate doesn't step.
  - It reaches AOO as before: the time `rt_mix` hands each sink (AOO takes its rate from those times, `kAooPreciseTimestamp`). AOO's own DLL plays no part.
  - Sheds, the adaptive size and the re-buffer rules are unchanged.
- **The estimate, made honest** (status only): a jump up between span minima is watched for three spans and taken out only if the callbacks stay late (lost for good); one that comes back was lateness. A jump down is left in (the earlier was the truth); only one over 0.25 s is taken out (a clock set). The rate is the slope between the earliest of the first 15 minima and the earliest of the last 15. Its time is the steady clock now, not wall time.
- **`stall_max_ms`** no longer counts a restart's stop-to-start gap.
- Status, per bandmate: `ratio_ppm` (R), `rate_fast` (the fast loop runs), beside `rate_ppm`, `play_rate_ppm`, `mix_rate_ppm` (what each stream is read at now).

Tried on the way and dropped: the buffered count as the level (above: `drift_tests`' clean run then moved +0.20 to +0.24 ms a second, as if uncorrected, and learned +16 to +44 ppm of +200); R integrating all the way (it read up to 0.9 % fast after a stall and overshot); "is the level heading back" against one window ago (a window's 2 ms of noise decided it); steering the level to the size itself (a pitch step at every start, and a few hundred ppm learned from nothing); a step between the two gains (a step in the rate).

### 2. The restarts and the hub's flap (`lib/direct.lua`, `lib/hub.lua`, `lib/liveaudio.lua`, `lib/livex.lua`)
- `direct.firewall_held`: a "no" after a "yes" counts once the rule hasn't been seen for `FW_HOLD` (150 s). Never seen is still "no" at once. **`lib/direct.lua` isn't one of this package's files: a 13-line additive edit**, because the one look also restarted the direct link.
- `hub.blind`: a computer holding a hub role gives it up for Syncthing being behind only if a bandmate's link reaches someone its own doesn't (rt-p9's second-hub case), then after `REACH_SETTLE` as rt-fix7. Seeing the whole room it keeps the role, and says no `lag`. Holding nothing, it still takes none while behind.
- `hub.NO_LA` (`ext`, `tailscale`, `firewall`, `down`): a computer whose status says its live audio can't run isn't elected a song's or the studio's hub while one that can is there; saying it holds the role doesn't keep it; alone it still keeps the restore points. Live audio before Syncthing-behind: one behind can still mix.
- `liveaudio.my_la` says `"down"` when the engine didn't start. `liveaudio.hub_plan` asks nobody whose word is in `NO_LA` for a mix (Health says why) and doesn't serve with its own engine not running. `livex`'s shared-CPU pick the same.

### 3. `tools/ears`: judged by each device's real rate; taps that wait for the sound
- `ears.py`: `device_rate` (callbacks against the link clock, robust to bursts and a restart), from the taps' stamps (`--stamps`), the polls (`--polls REF.jsonl GOT.jsonl`) or given (`--rates`). `compare_wav` puts GOT on REF's sample clock first, then checks; `speed` is judged against `speed_expected` = REF's rate / GOT's (`speed_error`). `--gain 0.01` for a hub's mix. The stamped latency counts lag at the sender's real rate.
- `ears.lua tap wait=N`: armed, the tap starts at its stream's first sound. The stamp carries the device's callbacks through the tap (`cbs`), `block`, `srate`; the poll's header `block`, `srate`.
- `rig.sh live`: taps armed first (`ARM` 300 s), then the polls (`SLACK` 60 s), then the fire.
- rt-r3's files judged again: r7 expected 0.99801, got 0.99993 (the laptop wasn't following; the old check passed it); r9 the desktop at 47999 Hz, got 1.0025 (a real fault, cause 1); r12 LinuxBox ran -7015 ppm (a starved VM), expected 1.0024, got 0.99703.

### 4. Jam's growing WAV (`extension/direct_audio.cpp`; rt-fix8's proposal in `rt-p12.md`)
`wav_sizes_now`: the growing `.opus.wav` and the sender's own 16-bit Jam WAV say the sizes so far every 250 ms (also through a pause). They said RIFF 36 / data 0 until the run's end.

### 5. Browser guests and listeners (`lib/webui/guestworklet.js`, `sharemix.js`, `listen.js`, `extension/webui.cpp`; rt-t1)
- One control in all four places (`ssPace` in the scripts, the same text; `gpace` in the extension): `1 + R + P`, P within 0.3 %, R learning only while P isn't getting its way. It was `1 + (fill - size) x 0.05` within 0.5 %, level only, at both ends of a guest's path.
- A buffer starts at its size: what piled up behind a pause is skipped in the silence (and for its first second).
- The guest page's buffer grows 20 ms on each underrun (80 -> 400 ms at most) and comes back 10 ms after a calm minute; the wait doubles when a step back is followed by an underrun. The listening page's lead steps back the same way; a packet past lead + 0.25 s is dropped (was 0.4).
- **`extension/webui.cpp` is a shared file: the edit is the guest ring's read (4 hunks, 46 lines).**

## Tests

Native (`tests/rtaudio_test.cpp`; the PC was at 100 % CPU from other agents' soak loops, so I ran them at High priority: at normal priority the test process itself stalls for tens of ms):

| Test | With the change | 1.0.37's `rtaudio.cpp` (HEAD) |
|---|---|---|
| `device` (new): L (steady, 128) and D (the desktop's device: 10 ms ticks, 0.1-1.2 % of them dropped, a new share every 6 s) send each other a tone for 45 s; from 15 s | D ran 47770 Hz. No underrun, shed or overrun either way; quietest 10 ms RMS 0.349/0.350; pitches 656.64 (656.83 expected) and 442.26 (442.12); learned -4459 and +4863 ppm; sizes 40 and 30 ms | 2 underruns each way, 1 shed, gaps (RMS 0.000), pitches 655.41 and 441.75, buffers grown to 70 and 50 ms: **5 fails** |
| `vm` (new): V's callbacks ten at once every 107 ms, the guest held 60-100 ms every 2-4 s, its AOO times 1500 ppm wrong; 45 s, from 15 s | 440.05 Hz heard (439.94 expected); no underrun, shed or overrun; learned +1236 to +1720 ppm in three runs (+1365 is exact) | 439.43 Hz (0.12 % slow); nothing learned: **2 fails** |
| `clock`: a VM's device +135 ppm, bursting, creeping 75 ms and snapping back, held 0.1-0.7 s | reads +136 ppm | reads **-2113 ppm**: fail |
| `clock`: AOO is handed nominal times | 0.00 ppm from nominal | -117.71 ppm at 10 minutes (the estimate): fail |
| `clock`: the staircase, the slow device, stalls and a clock set | -122, -102, -101 ppm | pass (kept) |
| `rate` (kept): times 1.5 % wrong | 439.72 Hz at 20-25 s, no underrun in the last 14 s, Talk read at -15237 ppm | pass |
| `drift` (changed): clean run, 256-sample blocks at both ends, 200 ppm apart | the delay moves +0.006, -0.029 and -0.008 ms a second in three runs (+0.200 uncorrected); learned +179 to +216 ppm of +200 by 16 s; the status's `latency_ms` 37.9 against 37.9-42.9 heard | no `ratio_ppm`. With the buffered count as the level (this change before its last step): +0.20 to +0.24 ms a second, as if uncorrected: **fail** |
| `drift` through the test's stalls | the ratio stays within 700 ppm of the real one; the delay only comes back toward its size, about 0.5 % a second | (it "held still" by leaving the level where a stall had put it) |

- `tests/jam_test.cpp`: mid-run the sender's WAV and the receiver's `.opus.wav` say what is on disk. HEAD's `direct_audio.cpp`: 3 fails (data 0 of 40960 bytes, then 0 of 81920; the `.opus.wav` 0 of 305952).
- `tests/webui_test.cpp`: a guest's ring with 200 ms waiting starts from the ramp's sample 6480 of 9600 at 1.0000 samples a sample (it played from 0 at 1.005).
- `tests/rt_p11_drift_test.js` (Node): a guest far away (39 ms each way, held ~0.18 s every ~4 s, +300 ppm, 15 minutes): 1 underrun from 4 minutes on, +322 ppm on average, size 220 ms; HEAD's worklet: 65 underruns, +3813 ppm. The listening page on a link that holds: ahead at most 80 ms past its lead, +509 ppm; HEAD's: 420 ms, +3328 ppm. **4 fails on HEAD's three scripts.**
- `tests/test_0_60_rt_audio3.lua`: the firewall look, `my_la`, `hub_plan`, the election with `nola`, `hub.blind` and the tick. It fails with each fix taken out (`direct.lua`, `liveaudio.lua`, `hub.lua` or `livex.lua` from HEAD; the blind rule or the `NO_LA` pool put back).
- `tools/ears/test_ears.py`: 12 tests OK (two new).
- Changed expectations in existing tests, each for a reason above: `drift_tests` (the stalls run, the hold checks gone), `clock_tests` (the hold and ramp-in checks gone with the hold), `test_0_60_rt_fix7_hub.lua` part 3 (its holder is now blind too), `webui_test.cpp`'s drift check, `test_0_60_rt_p11.lua` (`ssPace` in place of `DRIFT_K`).

## Re-check on the real rig (needs the extension build after 1.0.37 on the desktop, laptop and LinuxBox, and this Lua)
*(rt-r5 ran these on 1.0.38: its results are below. Round 2 has its own re-check at the end of this file; its steps replace 1-3, 8 and 10 here.)*

Setup as `rt-ears.md` (`rig.sh setup`; `load`, `track add=true`, `live role=send` on the sender; `live role=recv volume=0` on receivers, `0.01` through a hub; Deafen back to 1 and `track add=false` after). Read each status through the dev-eval hooks.

1. **The desktop -> the laptop (r7 again).** `TAP="l" OUT=<scratch> tools/ears/rig.sh live a1 d`, then `python tools/ears/ears.py wav $OUT/a1_d.wav $OUT/a1_l.wav --pattern $OUT/pattern --stamps`.
   - **Hit:** `rates_hz` has both; `speed_error` 1 +- 0.002 (expect within 0.0005; `speed` itself will read 0.994-0.999, the desktop's rate over the laptop's); `gap_ms` 0; `steady` true; `aligned` true; `latency_ms` within 20 ms of the laptop's `play_latency_ms` for the desktop read during the run.
   - On the laptop, the desktop's entry before and after: `play_underruns`, `play_overruns`, `play_resyncs` unchanged; `ratio_ppm` between -500 and -8000 (the desktop's device); `play_rate_ppm` within 5000 of it.
2. **The laptop -> the desktop (r9 again).** `TAP="d" ... rig.sh live a2 l`, the same `wav` line with `a2_l.wav a2_d.wav`. **Hit:** `speed_error` 1 +- 0.002, `gap_ms` 0, `steady`; on the desktop the laptop's `play_underruns` and `play_resyncs` unchanged (they rose 7 -> 9 and 11 -> 13), `ratio_ppm` +500 to +8000.
3. **Idle 10 minutes**, the desktop's Play up and silent, the laptop's status read every minute. **Hit:** `play_resyncs` and `play_underruns` for the desktop +0 (it was 4 -> 9 in 9.5 min); `play_trims` +1 at most (0 -> 6); Talk's `underruns` +1 at most (13 -> 19); `play_rate_ppm` within 5000 of `ratio_ppm` (it swung +-3000 around nothing).
4. **The desktop -> LinuxBox (r12 again).** `TAP="x" ... rig.sh live a3 d`. **Hit:** `speed_error` 1 +- 0.002; `gap_ms` 0 (it was 240, and 1820 with LinuxBox2 running); LinuxBox's `play_resyncs` +1 at most (1 -> 15; 210 -> 214). LinuxBox's `clock_ppm` within 300 of its counted rate (callbacks against `time_precise` over 30 s; it read -1008 to -1521 at +135) and `clock_steps` in single figures per hour.
5. **The desktop's restarts.** After two hours of Live sync on the desktop: `grep -c "live audio stopped: Windows needs its firewall rule first"` on the day's log gains **0** (it gained 30 in 3 h 17 min); the status's `callbacks` never starts again from 0.
6. **The hub holds.** Four computers in Cross Test for an hour: the desktop's log has no "is its hub now" or "you're the hub" line (17 in three hours), also while Health shows its Syncthing behind; `hub view` names James on all four. In the VM lab (as rt-p9 A): hand the hub to LinuxBox, pause LinuxBox's Syncthing: it **keeps** the role now (it was: gives it up after ~180 s), no `lag` in its view. Then cut LinuxBox from the desktop only (`lab.sh net x1 block <desktop's Tailscale IP> 47281`, UDP as rt-r2's lab notes): about 12 s + 30 s later LinuxBox's view has `lag` true and another computer holds the hub.
7. **LinuxBox2 without Tailscale.** Its status file's `"la"` is `"down"`; the others' Health says "live audio didn't start there" for it; `hub view` on the desktop, laptop and LinuxBox never names LinuxBox2 while one of them is in the room; its own log never says "live audio: you mix it for the others here".
8. **Through the hub (r13 again).** The desktop serves: `TAP="l x" ... rig.sh live a4 d d`, then `python tools/ears/ears.py wav $OUT/a4_d.wav $OUT/a4_l.wav --pattern $OUT/pattern --stamps --gain 0.01` (and `a4_x.wav`). **Hit:** in each listener's poll `hs` is "hub" in every row (r13: three changes on the laptop in 84 s); `fallbacks` +0 on both in 3 minutes with no network fault (they rose by 5 and 3); `level` true with `--gain 0.01`; `gap_ms` 0; the hub's `stall_max_ms` under 100 (1613.8). A host stall on the desktop (r13's 33-38 s) still costs a fallback: see "Left".
9. **Jam's growing WAV:** `rt-p12.md`'s check (`GetMediaSourceLength` on the growing copy against `StudioSync_JamDecode`'s `frames / 48000`: within a refresh).
10. **Browser guests** (`python tools/devices/guests.py <out> --laptop --soak-min 15 --extra 2`). **Hit:** each guest page's worklet `under` grows by 8 at most after its first 4 minutes (it grew 226 and 237 in 15), its `target` settles above 0.08; `tone_b_hz` within 0.1 % of 1500 from a minute after joining (1503.7-1513); the listener's `ahead` at most 0.3 s past its `lead` (0.14-1.03 s at lead 0.25). On a desktop that isn't at 86-92 % CPU.

## Results of the last runs
- `tests/rtaudio_test.cpp`, the whole suite on the committed code (54c6f4d), at High priority: **145 checks ok, fails 0**. The same test file on 1.0.37's `rtaudio.cpp`: `device` 7 fails, `clock` 2 fails.
- `tests/jam_test.cpp`: all ok (HEAD's `direct_audio.cpp` before 6b507bb: 3 fails). `tests/webui_test.cpp`: all ok (the `webui.cpp` before 02ebd1b: 2 fails). `tests/rt_p11_drift_test.js`: ok, fails 0 (the three scripts before 02ebd1b: 4 fails). `tools/ears/test_ears.py`: 12 OK.
- The 43 Lua tests that read live audio's, the hub's or the ears' code pass on the committed tree. `python tests/run.py --no-luals` in a clean clone, also with `TZ=UTC0`: in the report (it runs on the last commit, which is this file's).
- `extension\build_windows.cmd` with `DLL_OUT` in the scratch folder: exit 0, a 3.48 MB DLL; the tracked DLL untouched.
- Commits (local, not pushed): 6b507bb (Jam's growing WAV), 68c938e (the restarts and the flap), f9aa415 (tools/ears), 02ebd1b (browser guests and listeners), 54c6f4d (the receive path), and this file's.

## Left, untested, limits
- **Nothing ran in REAPER or over a real network.** The device and VM tests are models of what rt-r3 measured, on localhost.
- **A host that stalls** (the desktop in r13: 1.1 s, three times) still costs every listener a fallback through the hub, and each fallback is 3.3 s on direct streams. Recommendation 1.
- **The send thread still looks names up itself** (`make_slot` -> `getaddrinfo`): a peer whose name doesn't resolve blocks all sending for the lookup, every 5 s. Not seen in rt-r3 (every peer resolved). Recommendation 5.
- The fast loop reads up to 0.5 % (9 cents) off for seconds after a level step; a device like the desktop's keeps it in the fast loop most of the time. The desktop's own playback through Voicemeeter drops those ticks whatever StudioSync does.
- A holder whose Syncthing is paused for good now keeps its hub role while it sees the whole room: its restore points wait for Syncthing. Before, it gave the role up after ~180 s.
- LinuxBox2-like computers (no link, files only) can still say "you're the hub" in their own log when the files stop and they see nobody: restore points only, nobody follows it, and it mixes for no one.
- The level takes any datagram for a stream's sink as its newest packet (a ping too: about one read a second, which the median passes over).
- `clock_ppm` is for the eye. A VM whose timing creeps for longer than 30 s at a time reads off by that creep over the window.
- The guest page's first-second skip can cut a normal 60 ms jitter burst right after a start (one skip).
- An old (1.0.37) receiver hearing a new sender reads at nominal over its own estimate until its servo catches up: mixed versions are worse than either. Release to all at once.

## Review later (security)
- No new input from the link. `ratio_ppm`, `rate_fast` are numbers in a local status. The firewall hold keeps live audio and the link listening for up to 150 s after a rule is really removed (Windows itself then blocks the traffic).
- `la = "down"` is a computer's own word, like `lag`: with it a member can only take itself out of the election. Leaving it out gives the behaviour before.
- A lagging holder that claims to see everyone (its own `sees`) keeps a role it would have given up: `sees` is already each member's own word (rt-hubrank's list).
- The ears tap's stamp now carries callback counts (local file, local call).

## Recommendations (ranked: what would make this stack simpler, faster or sturdier; evidence from the code read, rough plans)

1. **Make the hub forward, not mix (an SFU), and elect it by a lease.** *Evidence:* the hub's mix is clocked by the hub's own device and encoded on a normal-priority thread, so one computer's stall (r13), restart or device (Voicemeeter's dropped ticks) is everyone's gap; a listener can't tell a 150 ms hiccup from a dead hub, so it leaves for 3.3 s (`GONE_*`, `RETRY_S`, `ENTER_S`, rescue, `own_outage`, `gap_learn`: about 400 lines of rtaudio.cpp guessing at that). The election has been patched five times (hubfix, hubrank, p9, fix7, this) because every computer elects alone from gossip that arrives at different moments. *Plan:* the hub relays each sender's Opus packets untouched to each listener (it already authenticates and addresses them; AOO's relay flag exists), each listener keeps its per-sender buffers and its own cue mix, as peer to peer. No decode, mix or encode at the hub (its 4-5 % of a core and ~10-20 ms of extra latency go), no second clock in the path, and a hub hiccup is jitter the buffers already absorb. Upstream stays one stream per person. For the role: the holder renews a lease over the direct link every few seconds; others take over only when the lease has run out, in a fixed order (home, owner's pick, reach). One holder by construction; `lag`, `blind`, `HOLD`, `VOUCH` reduce to the lease. About two weeks with tests; it removes more code than it adds.
2. **A simulated clock and network for the native tests.** *Evidence:* `rtaudio_test` runs in real time (9 minutes), fails for the machine's load alone (I had to run it at High priority), and 20 `check_unless_stalled` sites exist to excuse the runner. Each controller experiment here cost 70 s. *Plan:* inject `now_s`, the sleep and the socket (a loopback with scripted delay, loss and holds) behind three function pointers; drive capture and mix from the test. The whole suite then runs in seconds, deterministically, and rt-r3's saved polls (callback traces of the real devices) become fixtures. Three or four days; every later audio change gets cheaper.
3. **Own the receive side instead of bending AOO's.** *Evidence:* the fill AOO reports is a count that moves in the sender's blocks, so the level had to be rebuilt outside AOO from packet arrival times (above); the read rate reaches AOO by shifting the timestamps handed to each sink (`toff` grows without bound and AOO's pings and timeouts run on that bent clock); `fill_of` re-derives AOO's private capacity formula to turn a ratio into ms; a shed is `reportXRun` plus a crossfade; a resize is `setLatency`, which re-buffers (a gap, so shrinks wait for quiet). AOO's sink is 3000 lines of which we use the jitter buffer, the decoder call and a 4-point cubic. *Plan, small:* a 30-line patch to the vendored AOO: `kAooCtlSetResampleRatio` and a real fill in samples. *Plan, right:* our own jitter buffer in front of libopus (already vendored), NetEq style: target delay from the arrival histogram rather than from underruns, time-stretching (accelerate / preemptive expand over pitch periods) for level errors so the pitch never moves, resampling only for the clock ratio, Opus PLC and FEC for loss. Resizes become a moved setpoint with no gap. Two to three weeks; AOO would remain for the sender, or go entirely (its packet format is the only thing the two ends share).
4. **One controller, written once.** *Evidence:* the same law now lives in `rtaudio.cpp` (adapt), `webui.cpp` (`GPace`) and three copies of `ssPace` kept alike by a test. *Plan:* `extension/pace.h` for both C++ users; one `pace.js` imported by both worklets and the page (ES module imports work in AudioWorklet in current Chrome, Firefox and Safari; keep the text-equality test until that's checked on the Mac's Safari). Half a day.
5. **Take name lookups, and everything else that can block, off the send thread; make the status lock-free.** *Evidence:* `reconfigure` -> `make_slot` -> `getaddrinfo` runs on the thread that sends Talk, Play and every listener's mix (a failing lookup on Windows takes over a second, retried every 5 s). `rt_status` builds its JSON with repeated `std::string::insert` while holding `cfg_mx` and `stats_mx`; the receive thread takes `cfg_mx` for the HMAC and AOO's handler on every datagram, and the ears poller asked 500 times a second (the hub's 211 "stalls" in r13 are partly that). *Plan:* a resolver thread that hands finished slots over; counters as atomics and a seqlock'd snapshot that the status formats outside any lock; the HMAC before the lock; an event ring (underrun, shed, fallback, with times) so tools read events instead of polling. Three days.
6. **Change a buffer's size by moving its level, not by re-buffering.** *Evidence:* `adapt` grows on an underrun and shrinks only when the peer is quiet, because `setLatency` re-buffers (a gap). With the level control in place a size change is a new setpoint that P plays in or out at 0.2-0.5 % with no gap. *Plan:* keep AOO's latency at the ceiling's worth of room, hold the level at the adaptive size through `wset`; grow before an underrun from the buffer's low-water mark instead of after. Two days, and it removes the quiet-wait and most of the retry logic.
7. **Write background command output atomically** (`lib/services.lua` `background`: `> file.part` then rename). *Evidence:* cause 6; every caller that parses a command's text has the same exposure (Syncthing's answers, `tasklist`, `tailscale status`). An hour, plus a test.
8. **Measure latency instead of adding it up.** *Evidence:* cause 7: three numbers for one path (95-118 ms from envelopes, 127.6 stamped, 152-171 in the status). *Plan:* stamp each stream's frames with the sender's link-clock capture time (AOO's stream-time message already carries a time; `StudioSync_DirectClock` gives the offset) and report the measured mouth-to-ear delay per stream. Play together and Their time could then use it directly. Two days.
9. **Tell the user when the device is the problem.** *Evidence:* the desktop's WASAPI-through-Voicemeeter device loses 2-12 of its 10 ms ticks in 10 s; no receiver can make that sound right locally. *Plan:* Health reads `clock_ppm` and the spread of the callback count ("this audio device runs 0.4 % slow and unevenly: use its ASIO driver or Voicemeeter's ASIO insert"). Half a day.
10. **Opus settings worth a measured try:** 10 ms frames for Play (half the packets; 5 ms matters for Talk), in-band FEC on lossy links, DTX on a silent Talk (an idle stream was re-buffering for nothing). A day with the ears pattern.

## REAPER re-check results (rt-r5, 2026-11-22 11:50-13:50 MT, StudioSync 0.59.49.97 from bfb7be9 + extension 1.0.38, Deafen 1)

Desktop (d, WASAPI through Voicemeeter, 512), laptop (l, ASIO 128, on Wi-Fi over the internet), LinuxBox (x, PulseAudio 512 in a VM on
the desktop); LinuxBox2 (x2) resumed 12:43-13:48 for step 7 and the hour of four, then suspended. The Mac was offline. Sound tests as the handoff says:
the ears pattern on a generated test track on the sender only (`track add=true`, Play only), receivers muted (send nothing) at volume 0
(0.01 through the hub), no microphone, no VM audio input; Deafen back to 1 on all three after every run and the test track removed.
Probes and files: `<scratchpad>/rt-r5/` (`rig_rt-r5.sh` = tools/ears/rig.sh with the laptop through its hook lock, `stat.sh`, `ears/`,
`st/`, `idle_log.txt`, `idleb_log.txt`, `guests/`).

**The laptop's link was poor for most of the window.** Desktop -> laptop ping (Tailscale, direct): 84-748 ms, average 190, during the
guests run (12:25); 83-311, average 147, after it (12:42); 77-176, average 83, at 13:35; 73-83, average 80, at 13:38. The laptop's own
status said `rtt_ms` 106-206 to the desktop through the 9-minute idle (12:00-12:09), and its buffer for the desktop sat at the 150 ms
ceiling with `jitter` (underruns that grew it) 59 -> 222. Runs a1, idle, a2 and the guests ran on that link; b1 and the second idle on the
calm one. Read the laptop rows with that in mind.

| # | Check | Result | Numbers |
| --- | --- | --- | --- |
| 1 | d -> l (a1, poor link) | **fail** | `speed_error` **1.00734** (speed 1.00339 against 0.99607 expected: desktop 47809 Hz, laptop 47997 Hz), `gap_ms` 900 (longest 230), `steady` false, corr 0.13; on the laptop the desktop's Play: underruns 8 -> 18, overruns 5 -> 9, resyncs 13 -> 27, trims 0 -> 2 in the run; **`ratio_ppm` +8727 before and +2369 after, `play_rate_ppm` +13727 / +7369**: the wrong sign (the desktop's device is the slow one: about -3900 ppm expected) and P pinned at its +0.5 % bound. Envelopes (`ears.py env`): latency 248 ms, IQR 9, level 0.0 dB, gaps 0. Live sync also turned the desktop into the room's mixer at 11:57:08 and back at 11:58:51 during the run ("you mix it for the others here"), and the laptop's `fallbacks` went 0 -> 2. |
| 1 | d -> l again (b1, calm link, 13:36) | **pass but for 2 underruns** | `speed_error` **0.9994**, `gap_ms` **0**, `steady` true, level +0.01 dB, `latency_ms` 141.8 against `play_latency_ms` 143.0-155.0; the laptop's entry for the desktop: underruns 106 -> 108, resyncs 159 -> 161, overruns 53 -> 53, trims 25 -> 26 (target +0), `ratio_ppm` -1415 -> -2050 (in -500..-8000), `play_rate_ppm` -946 / -2374 (within 5000 of it). `aligned` false (corr 0.46, lag -20.5 ms) in all runs here: see Left. |
| 2 | l -> d (a2, poor link) | **near miss** | `speed_error` **1.00232** (bound 1 +- 0.002; laptop 47997 Hz, desktop 47909 Hz), `gap_ms` 180 (longest 20), `steady` true; on the desktop the laptop's Play: underruns 0 -> 0, resyncs 0 -> 0 (**pass**: they rose 7 -> 9 and 11 -> 13 in r9), `ratio_ppm` +1597 / +793 (in +500..+8000). Tap latency 227 ms against `play_latency_ms` 212 at the start (the size went 150 -> 60 ms during the run, 107 at the end). |
| 3 | Idle 9 min, desktop Play up and silent (12:00-12:09, poor link) | **fail** | Laptop, desktop's Play: **resyncs 39 -> 143 (+104)**, underruns 26 -> 93 (+67), overruns 13 -> 50, trims 3 -> 16 (+13); Talk underruns 67 -> 133 (+66); `ratio_ppm` swung -1612 .. +12156 and `play_rate_ppm` -6612 .. +17156 minute to minute; `play_buffer_ms` 130-392 against a 150 ms size. LinuxBox (same minutes): resyncs 3 -> 7, underruns 3 -> 7, trims 0, `ratio_ppm` -367 .. -4640. |
| 3 | Idle 6 min again, calm link (13:39-13:45, ping 74-90 ms) | **fail, small** | Laptop, desktop's Play: resyncs 162 -> 166 (+4), underruns 109 -> 113 (+4), overruns 53 -> 53, trims 27 -> 29 (+2; target +1 at most); Talk underruns 431 -> 435; `ratio_ppm` -1212 .. -3492 (the right sign now), `play_rate_ppm` within 5000 of it in every read (-7637 against -2637 at the edge); `rate_fast` true in every read. |
| 4 | d -> x (a3) | **pass but for 40 ms of gaps** | `speed_error` **1.0016** (desktop 47910, LinuxBox 48004 Hz), `gap_ms` 40 (longest 10; was 240), `steady` true, level 0.0 dB; LinuxBox's desktop entry: resyncs 12 -> 13 (+1, **pass**), underruns 12 -> 13; `clock_ppm` 63.0-66.0 against its counted rate +85 ppm (tap stamps) / +248 ppm (callbacks against `time_precise`, 47 s): **within 300, pass**; `clock_steps` 1 since 11:49 (**pass**). |
| 5 | The desktop's restarts | **pass** (2 h) | "live audio stopped: Windows needs its firewall rule first" in the desktop's log: 3 (all 04:01-04:04) at 11:53 and still 3 at 13:51: **+0 in 11:50-13:51**, and no "live audio stopped" line of any kind. The desktop's `callbacks` 25284 at 11:54, 178558 at 12:22, 680653 at 13:51 (2 h 1 min of 512-sample blocks: it never started again). |
| 6 | The hub holds | **pass** (log part) | No "is its hub now" or "you're the hub" line on the desktop after its Live sync start at 11:50:36 (the last two at 11:46:54 and 11:50:36 are the reload and the start), none on the laptop or LinuxBox today; four computers in Cross Test (LinuxBox2 from 12:44) and none either. `hub view` on d, l, x and x2: hub James, studio James (why home / preferred). Not run: the VM lab part (Syncthing paused on a LinuxBox holder; the block). |
| 7 | LinuxBox2 without Tailscale | **pass** | Resumed 12:43 (suspended again 13:48), extension 1.0.38 installed (sha256 891b0274..., the 1.0.37 .so to `~/.local/share/Trash/files/reaper_studiosync-x86_64.so.1037-1795376657`), Deafen 1 before its REAPER restarted on 1.0.38 with 0.59.49.97; its status file `"la": "down"`; Health on d, l and x: "LinuxBox2 not connected: live audio didn't start there (their Health says why)"; `hub view` names James on all four; its own log: "live audio didn't start: Tailscale isn't up here" and "James's computer mixes it for the room", never "you mix it for the others here". (It caught up "57 changes from the others" on resuming, as in rt-r4.) |
| 8 | Through the hub (a4, desktop serves) | **pass but for gaps** | Listeners' `fallbacks` +0 in the 3 minutes (laptop 2 -> 2, LinuxBox 1 -> 1); the hub's `stall_max_ms` **0.0** (1613.8 in r13), `stalls` 0; level 0.00 / -0.01 dB with `--gain 0.01`; `speed_error` 0.99887 (l) and 0.99829 (x); `hs` "hub" in every laptop row after joining (13.3 s); on LinuxBox one "direct" row at 108.9 s, which its poll notes as Live sync asking again (`hub asked again`, fallbacks unchanged), not a fallback. **`gap_ms` 120 (l, longest 10) and 10 (x)**: target 0. After the run, with no test, Health said "back to everyone's own streams 3 times" on both listeners (laptop 2 -> 3, LinuxBox 1 -> 3 by 12:47). |
| 9 | Jam's growing WAV | not run | |
| 10 | Browser guests (`guests.py --laptop --soak-min 15 --extra 2`, poor link) | **fail** | The six hearing checks and `four_live` pass. Pages' worklet `under` 15 -> 27 (A) and 14 -> 28 (B) from the 4th minute to the end (target: +8 at most; it was +226/+237 in 15 min), `drops` +8 / +13; `target` settled at 0.39-0.40 s (above 0.08: pass); `tone_b_hz` 1492.8-1506.3 (target within 0.1 % of 1500: **fail**, +-0.5 %); the listener's `ahead` at most **0.21 s** past its lead (target 0.3: pass), its lead stepped 0.25 -> 0.65 s, `under` 1 -> 8. Host rows `under` 96 -> 533 and 96 -> 531 in 15 minutes. CPU 33-48 % on the desktop. |

**Findings.**
- **A. On a jittery link the read-rate control learns a ratio of the wrong sign and holds P at its bound** (a1 and the idle, the laptop
  hearing the desktop). With the desktop's device at 47809 Hz the laptop should read it about 0.4 % slow; it read it 0.73 % fast in a1
  (`play_rate_ppm` +7369, R +2369, P +5000 = `RATE_P_F`), and through the idle R wandered -1612 .. +12156 ppm. The buffer sat at its
  150 ms ceiling, so bursts that didn't fit were re-buffers (`play_overruns` +37) and each left the level high (fill 210-392 ms against
  150): a high level is "read faster", which drains it into an underrun (`play_underruns` +67), and R, learning whenever the level "isn't
  coming back", follows the sawtooth. On a calm link (b1) the same pair read at -2374 ppm, R -2050, `speed_error` 0.9994, no gaps, though the calm idle still re-buffered about once in 90 s (+4 resyncs in 6 minutes) with the fast loop on in every read. So the
  control is right for a steady link and goes wrong when the network's jitter exceeds the buffer's ceiling: R should probably not learn
  in a window that contains a re-buffer or an overrun, nor while the size sits at the ceiling. Evidence: `st/st_idle*_l.json`,
  `idle_log.txt`, `ears/a1_*`.
- **B. Live sync switched the desktop to "you mix it for the others" during a1** (11:57:08-11:58:51) with only one sender in the room, so
  a "peer to peer" run partly went through the hub (laptop `fallbacks` +2). rt-audio3's step 1 assumes peer to peer.
- **C. A bandmate's track change can arrive 27 s late with its live preview put back first.** In fix9 check 3 LinuxBox set XT Drums A to
  0.9 at 13:07:21 (its log: "1 change(s) went to the others"); the desktop and the laptop showed the fader at once (live preview), said
  "a bandmate's live move wasn't followed by their change: put back as it was" at 13:07:40 and got the change at 13:07:48 (Syncthing, not
  the link): the fader jumped 0.9 -> 1.0 -> 0.9 on both. Seen once.
- Small: `aligned` is false in every tap comparison here (corr 0.33-0.46 with lags of -43 to +21 ms), while speed, level, spectrum and
  steadiness pass: the comparer's alignment threshold or the taps' start may need a look (a1's corr 0.13 is the real fault). The laptop
  lists the offline Mac as a peer (`chilis-macbook-pro`, "no answer"), and LinuxBox's log said "Chilio-Mac's computer sends here before
  this room lists it" at 20:17:30 UTC with the Mac offline.

**Left.** Jam's growing WAV (step 9); step 6's VM lab part; the guests and a2 again on a calm link; a1's two underruns on the calm link;
the desktop's own Voicemeeter device (`clock_ppm` -1500 to -4200 through the window).

## Round 2 (rt-audio3, 2026-11-22, from rt-r5's re-check above)

**Offline builds and tests only, as before: nothing ran in REAPER, on the test computers or in the VMs.** I read rt-r5's saved polls,
status dumps and WAVs (`<scratchpad>/rt-r5/`) and the desktop's own StudioSync log. The C++ needs the extension release after 1.0.38
(EXT_VERSION not bumped, no binaries committed).

### What rt-r5's evidence says (causes)

| rt-r5 | Seen | Cause |
|---|---|---|
| A (a1, idle on the poor link) | The laptop read the desktop 0.73 % fast, `ratio_ppm` +2369 to +12156 for a device 0.4 % slow, P at its bound, 104 re-buffers in 9 minutes | Three things in the control, and the ceiling. (1) **It steered every stream to within 12 ms of its size.** On that link the buffer sat at its 150 ms ceiling and each re-buffer finished wherever the burst behind the hold left it: `fill_ms` 209 to 392 against 150 in `st/st_idle*_l.json`. That read as "too full", P read it off at +0.5 %, which drained it into the next hold. (2) **R learns while "P isn't getting its way"**, and a level that every burst refills never comes back: R integrated a level error that wasn't a rate, up to +12156 ppm. (3) A newest packet older than 0.25 s restarted the windows and the held level, so on a link that holds packets that long nothing was ever remembered. (4) An overrun (a burst that didn't fit: `play_overruns` 13 -> 50) didn't restart them at all. And the size could not go past 150 ms, 10 ms an underrun, on a link that held packets up to 750 ms. |
| A, the calm idle | +4 underruns and resyncs in 6 minutes, `rate_fast` in every read | Two different things. The underruns are **the laptop's own link holding longer than its buffer**: in b1 (13:36) Talk and Play underran in the same poll row (`jitter` 541 -> 543 at 52.8 s) while LinuxBox, hearing the same sender through those seconds, had none. One such hold about every 90 s, each "a lone spike" by the buffer's own rule (grown a step, not held), so each is a gap again: see Left. `rate_fast` always: its threshold was 6 ms and one tick of the desktop's device is 10 ms. |
| a2 | the laptop -> the desktop "speed 1.00232, 180 ms of gaps", no underrun | **The comparer.** The desktop's device ran 47777 Hz through the 9.7 s of sound and 47909 Hz over the 30 s tap (from the tap's own stamps); judged by the tap's average the receiver, in step, read 0.23 % sharp, and resampled by the wrong ratio its frames slipped 25 ms against the reference: "gaps". Judged over the sound's own span: `speed_error` **0.99954**, `gap_ms` **0**, steady. |
| B | Live sync made the desktop the room's mixer for 103 s during a1 | **The Mac came onto the link.** The laptop's status right after a1 lists `chilis-macbook-pro` resolved, `rtt_ms` 31.1, `heard_ago` 13.31 (`st/st_post_a1_l.json`; it isn't there in `st_pre_a1_l.json`). Four computers for 43 s is `HUB_FROM`, and a room that was big enough stays so for `HUB_KEEP` 60 s: 43 + 60 = 103. Nothing held the switch back for a computer passing by, and nothing asks whether there is anything to mix. |
| guests | pages' `under` +12 and +14 after minute 4, host rows 96 -> 533, a tone +-0.5 % | The host's ring for a guest was a fixed 60 ms: dry at every hold (437 times in 15 minutes). The page's buffer stopped at 0.4 s and grew 20 ms an underrun. Both ends' pace went by the buffer's mean, which falls and rises with every hold, so P ran at its 0.3 % either way, at both ends of a guest's path, and R wandered. |
| a4 | through the hub "120 ms of gaps" on the laptop, fallbacks +0 | **The comparer.** No one 10 ms frame was lost: the delay wandered 10 ms through the pattern (steady: 17.7 to 28.0 ms) and a click that landed in the next 10 ms frame read as a gap, 12 times. With a gap needing the 10 ms either side to be empty too: 0 on the laptop, 10 ms on LinuxBox. |
| small | `aligned` false everywhere, corr 0.33-0.46 | **The comparer**: one lag for 30 s of a live path, whose delay moves by more than a waveform's period. 0.1 s at a time, each at its own lag, the same recordings match at 0.92 to 0.98 (median). |

rt-r5's own WAVs judged again with the comparer as it is now (`python tools/ears/ears.py wav REF GOT --pattern ... --stamps`):

| Run | Before | Now |
|---|---|---|
| a1 d -> l (poor link) | speed_error 1.00734, gaps 900, corr 0.13: fail | speed_error 1.00757, gaps 80, not steady: **fail** (the real fault, A) |
| b1 d -> l (calm) | 0.9994, gaps 0, aligned false | **ok**: 0.99982, gaps 0, corr_windows 0.974, steady (jump 2.6 ms) |
| a2 l -> d | 1.00232, gaps 180, aligned false: fail | **ok**: 0.99954, gaps 0, corr_windows 0.976 |
| a3 d -> x | 1.0016, gaps 40, aligned false | **ok**: 1.00164, gaps 0, corr_windows 0.946 |
| a4 hub -> l | 0.99887, gaps 120, aligned false | **ok**: 0.99957, gaps 0, corr_windows 0.921 |
| a4 hub -> x | 0.99829, gaps 10 | 0.99915, gaps 10 (one real 10 ms): no_gaps fails |

### What changed

**1. The read-rate control (`extension/rtaudio.cpp`, the comment at `RATE_*`).**
- **It holds a stream where it settled, wherever that is against its size.** No steering to within 5 ms under and 12 over (`RATE_SET_*` is gone). What sits unused above the size is the shed's to take (`TRIM_OVER`, one crossfaded skip), what is missing below it is an underrun's to grow.
- **A level that moves more than 30 ms between two windows isn't a rate** (`RATE_JUMP`: a device 6 % off): the network's delay moving, a stall, a burst. The held level moves with it, R learns nothing from it nor from the two windows after, and the loop is slow for 10 s (`RATE_CALM_S`: P within 0.2 %, R at the slow gain). Status: `rate_rough`.
- **A newest packet older than 0.25 s at a read is left out**, nothing restarted: with the packet's age in the level, the level holds still while a link holds packets and lets them go together.
- **A re-buffer of any kind restarts the windows** (underruns and overruns of Talk, Play and the mix, also the ones not counted as jitter); R is kept.
- **The fast loop starts 10 ms off** (it was 6): one tick of a 10 ms device doesn't start it.

**2. The buffer's size goes to what the link holds (`extension/rtaudio.cpp` adapt; `lib/liveaudio.lua`).**
- The receive thread keeps the longest wait between two datagrams of a stream (under 1 s: more is a pause); adapt remembers the longest of the last 30 s. Status: `hold_ms`.
- **From the second underrun in a row that wasn't lone, the size goes to that hold at once** (+5 ms, in 10 ms steps), not 10 ms an underrun. A lone underrun is still one step, not held.
- **The default ceiling is 400 ms** (`BUF_CEIL`, `liveaudio.CEILING`; it was 150). Past 150 ms nobody plays along, so what counts there is hearing each other whole. A bandmate's own ceiling in Live audio's settings still caps it. *This is a default the user sees: two constants to put back if 150 was meant as a hard promise.*

**3. The hub's mix (`lib/liveaudio.lua`).**
- `liveaudio.senders`: how many computers in the room send (all but those whose own status word says muted, deafened, or that live audio can't run). **Under two, peer to peer, however big the room**: through the hub a lone sender's stream is decoded, mixed with nothing and encoded again for each listener.
- `liveaudio.hub_n`: a room counts as big enough **once it has been so for `HUB_SETTLE` 60 s** (and then for `HUB_KEEP` 60 s after, as before). The same hold for how many send: someone unmuting for a word doesn't move the room.

**4. `tools/ears` (`ears.py`).**
- `stamp_rate(path, span)`: each device's rate **while its WAV's sound was recorded** (`sound_span`), not over the whole tap; `wav --stamps` uses it.
- `aligned`: the median match of 0.1 s stretches, each at its own lag (`corr_windows` >= 0.8); `corr` is still reported.
- When no one lag fits the waveform (`corr` < 0.8) the recording's lag comes from its loudness (`align_env`): a 3 ms wander had put the waveform's strongest peak 108 ms off.
- A gap needs the 10 ms either side to be empty too.

**5. Browser guests (`lib/webui/guestworklet.js`, `sharemix.js`, `listen.js`, `extension/webui.cpp`: the last is a shared file, the guest ring only).**
- `ssPace` / `gpace`: the level is a time where the caller gives the newest piece's age (the guest page and the host's ring do): what waits plus how long ago the newest piece came. A window whose level jumped more than 30 ms: R learns nothing from it or the next. P within 0.1 % (it was 0.3 %).
- The guest page's buffer may grow to 0.8 s (it was 0.4). **The host's ring for a guest grows too** (60 ms to 0.8 s, back 10 ms after a calm minute; it was a fixed 60 ms). Both grow when the sound comes again after running dry: to the hold that did it and a step, and not at all after a wait of a second or more (a pause, not the link). Status per guest: `size`.

### Tests (each fails without its change)

Native, `tests/rtaudio_test.cpp`, at High priority. **The whole suite on the final code: 153 checks ok, fails 0.**

| Test | With the change | 1.0.38's `rtaudio.cpp` |
|---|---|---|
| `jitter` (new): D (the desktop's device, 0.4 % of its 10 ms ticks dropped: 47821 Hz) sends J a tone for 75 s; J's packets are held 51 times in the 50 s counted (40-150 ms mostly, 150-350 ms a quarter of the time, 350-750 ms now and then: 7.3 s in all), each hold let go at once | read D at -4639 to -3347 ppm, never fast; learned -4143 to -4071 (the device: -3735); the tone heard whole 657.31 Hz (657.54 at the two real rates); the fast loop in 1 of 51 looks; size 400 ms; 1 underrun, 1 overrun, 0 shed; 1.1 % silence | read at up to **+4269**; learned -3409 to -731 and rising; **661.50 Hz (0.6 % sharp)**; the fast loop in 51 of 51 looks; size 150 ms; 8 underruns, 3 overruns, 3 shed; 4.1 % silence: **5 fails** |
| `landed` (new): R's 60 ms buffer runs dry behind an 85 ms hold and is filled again ~85 ms over its size | 440.015 Hz, read at up to 178 ppm off | **442.17 Hz (0.49 % sharp), read at 5021 ppm**: **2 fails** |
| `device`, `vm`, `drift`, `rate`, `clock` (kept) | as round 1: device learned -4291 and +5011 ppm with no underrun, shed or gap; vm +1408 of +1365; drift -0.008 ms/s and +202 ppm of +200; through the test's stalls the ratio -30 ppm of -100 and the delay stays where a stall left it (-0.017 ms/s; 1.0.38 read it off at -5) | pass |

- `tests/test_0_60_rt_audio3.lua` part 4: who sends, the plan with one sender, a room of four for 43 s, the hold for senders, the default ceiling. With `lib/liveaudio.lua` from before: fails (`senders` isn't there). `tests/test_0_60_rt_hubmix.lua`, `tests/test_0_60_rt_liveaudio.lua`: their expectations of the room's size and the default ceiling follow.
- `tools/ears/test_ears.py`: 14 tests OK (two new: a live path whose delay wanders +-3 ms is aligned, has no gap and is steady, another sound isn't aligned, a real 80 ms dropout is still a gap; a device's rate over the sound's span).
- `tests/rt_p11_drift_test.js` (Node): a guest over a link that holds ~0.2 s every ~1.5 s and ~0.6 s every ~50 s, REAPER +300 ppm, 15 minutes: 2 underruns from minute 4 on, read at -771 to +1555 ppm, its buffer 677 ms. The three scripts from before: 11 underruns, -3643 to +3094 ppm, 400 ms: **3 fails**.
- `tests/webui_test.cpp`: a guest's ring that ran dry behind a 0.3 s hold goes to that hold (its size 0.06 s, then 0.52 s after the hold and the test's own waits; ten 0.25 s bursts after it: dry 0 more times). The `webui.cpp` from before: **2 fails**.
- `extension\build_windows.cmd` with `DLL_OUT` in the scratch folder: exit 0 (a 4.0 MB DLL), the tracked DLL untouched. `python tests/run.py --no-luals` in a clean clone, also with `TZ=UTC0`: in the report (it runs on this file's commit).
- Commits (local, not pushed): 281fd71 (the receive path and the buffer's size), 841272f (the hub's mix, the default ceiling in Lua), 583261e (tools/ears), 2e0fd5d (browser guests), and this file's.

### Re-check on the real rig (needs the extension build after 1.0.38 on all computers, and this Lua)

Setup as rt-r5's. Read each status through the dev-eval hooks; the new fields per bandmate are `rate_rough` and `hold_ms`.

1. **The poor link, the desktop -> the laptop** (ping over 140 ms on average or peaks over 300; a1 again). **Hit:** on the laptop, the desktop's `ratio_ppm` between -500 and -8000 in every read, never positive (it was +2369 to +12156); `play_rate_ppm` within 2500 of it (it sat 5000 over); `rate_fast` false and `rate_rough` true in most reads; `target_ms` past 150 within the first minute, near `hold_ms` + 5, 400 at most; `speed_error` 1 +- 0.003; `play_resyncs` +3 at most in the run (13 -> 27).
2. **Idle 9 minutes on the poor link.** **Hit:** `play_resyncs` +15 at most (it was +104), most of them in the first two minutes; `ratio_ppm` between -500 and -8000 in every read; `play_trims` +2 at most (+13); `play_buffer_ms` near `target_ms`, not 60-240 ms over it.
3. **Idle 6 minutes on a calm link** (ping 74-90 ms). **Hit:** `rate_fast` false in at least 4 of 7 reads (true in every one); `play_rate_ppm` within 1500 of `ratio_ppm` in every read (-7637 against -2637); a Play underrun that doesn't come with a Talk one in the same read: 0. Underruns that hit both at once are the link's own holds (Left): count them, don't fail them.
4. **The laptop -> the desktop, and through the hub** (a2, a4 again), with this `ears.py`. **Hit:** `ok` true: `speed_error` 1 +- 0.002, `gap_ms` 0, `aligned` true with `corr_windows` over 0.9, `steady`.
5. **The hub's mix.** Three computers muted and one sending in a room of four: the log never says "you mix it for the others here" or "'s computer mixes it for the room". A fourth computer on the link for under a minute: no switch. Four computers, two of them unmuted, for over a minute: the switch within 70 s of the second unmuting.
6. **Guests on the poor link** (`guests.py --laptop --soak-min 15 --extra 2`). **Hit:** each page's worklet `under` +8 at most after its 4th minute (+12, +14), `target` up to 0.8; the host rows' `under` +10 at most after the 4th minute (96 -> 533 in 15) with `size` over 0.06 in the status; `tone_b_hz` 1497.7 to 1502.3 (within 0.15 %; it was 1492.8-1506.3).

### Left, untested, limits
- **Nothing ran in REAPER or over a real network.** The jittery link is a model: a receive thread held and let go. A link whose delay ramps up and down (a queue filling) moves the level under 30 ms a window and is followed at the slow loop's pace.
- **A link's lone holds still cost a gap each.** The laptop's link held longer than its buffer about every 90 s on the calm afternoon; by the buffer's own rule (an underrun with none other in 30 s is a lone spike: a step, not held) each one is a gap again. Holding a size that covers a hold seen every minute or two would cost that link 100-250 ms for good. James's call: see Recommendation 12.
- On a link that is rough all the time R learns at the slow gain only: a device 0.4 % off takes a minute or two to be learned there, P (0.2 %) and the buffer covering meanwhile. R is kept across re-buffers.
- `RATE_JUMP` is 30 ms a window: a device that lost more than three 10 ms ticks in half a second would be taken for a jump.
- A stream left above its size by a burst stays there until the shed takes what a whole stretch (10 s) never used: more latency for that long, where 1.0.38 read it off sharp.
- LinuxBox read the desktop 0.16 % fast in a3 (inside the bound). Not looked at beyond `vm_test`.
- The listening page's pace doesn't use the piece's age (it looks once a packet, as packets arrive): unchanged, and it passed in rt-r5.
- The guest's and the host ring's hold is counted in real time between pieces: a guest's page that stops sending for a second or more (a suspended tab) is a pause, and grows nothing.
- An old (1.0.38) extension with this Lua is handed the 400 ms ceiling and still grows 10 ms an underrun.

### Review later (security)
- Who "sends" is each computer's own status word (`muted`, `deaf`), as `la` already was: a computer that says muted while sending keeps a room peer to peer, nothing more.
- `hold_ms`, `rate_rough`, a guest's `size`: numbers in a local status. A guest's ring is 1.36 s at most (262 kB a guest, four guests), its size 0.8 s at most; the socket's rate limit is unchanged.
- The default ceiling lets a bandmate's packets hold up to 400 + 300 ms of audio in this computer's buffer (it was 150 + 300); a user's own ceiling still caps it at 500.

### Recommendations, added in round 2 (the ten above stand; these come from what rt-r5 took to explain)
11. **Tap and poll in real time, so nothing has to estimate a device's rate.** *Evidence:* two of rt-r5's six failures were the comparer's (a2, a4), from a device whose rate differs between a 30 s tap and its 9 s of sound; `stamp_rate(span)` narrows the window but a 10 ms device still isn't known better than 0.1 % over 10 s. *Plan:* the ears tap stamps every block it writes with the link clock (one double a block beside the WAV); `ears.py` compares on that clock: speed, latency and gaps without any rate. A day.
12. **Bridge a lone hold instead of re-buffering through it.** *Evidence:* the calm link's one hold every ~90 s (above); AOO's answer to a dry buffer is silence, a re-buffer and the decoder rejoining over ~100 ms. *Plan:* with the receive side owned (Recommendation 3): Opus PLC for the first 60-100 ms, then time-stretch what is there (WSOLA) while the hold lasts, and play the burst in faster after it; the size stays small and a lone hold is a soft patch, not a gap. With Recommendation 3.
13. **Size the buffer from the holds seen, before the first gap.** *Evidence:* the size now goes to the longest hold of the last 30 s at the second close underrun: still two gaps to learn a link, and 30 s of memory. *Plan:* a histogram of waits between datagrams per bandmate over ten minutes; the size is its 99.x percentile plus a margin, moved by the level (Recommendation 6), so a link's character is known from its first minute and remembered through a quiet one. Two days after Recommendation 6.
14. **Put the level's trace in the poll.** *Evidence:* a status read a minute can't say why a buffer ran dry, and the ears poll carries Talk's fields only: A's cause had to be put together from eleven one-minute snapshots and a model. *Plan:* `play_buffer_ms`, `hold_ms`, `ratio_ppm`, `play_rate_ppm` and `rate_rough` in each poll row (five numbers); the event ring of Recommendation 5 later. An hour.
15. **Say why a computer counts as here.** *Evidence:* the Mac, asleep, was in the room for 43 s and the only trace is one status dump; the laptop still listed it "no answer" hours later. *Plan:* the log says "<name>'s computer is on the link (heard n s ago)" when the room's count changes, and Health lists who counts and why (status file, heard on the link, vouched). Half a day.
16. **Recommendation 4 is now urgent**: the pace exists in five places (rtaudio.cpp, webui.cpp, three scripts) and they have started to differ (the piece's age in two of them, the jump rule in all, the fast loop in one). One `pace.h`, one `pace.js`.
