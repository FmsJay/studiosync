# rt-t1: phone and browser-guest tests without James (2026-11-22)

Backlog T1: the S23 and browser-guest checks that used to need James, automated. Tools in `tools/devices/`; nothing in `lib/` or `extension/`
changed. Run on the desktop (StudioSync 0.59.49.95, extension 1.0.37; desktop, laptop and LinuxBox at Deafen 1 before and after every sound
test). Results are in the sections below and, short, in the result sections added to `rt-p11.md`, `rt-audience.md` and `rt-p5.md`.

## What was built (`tools/devices/`, GPL-3.0-or-later)
| File | What |
|---|---|
| `webtap.js` | Injected before a page's scripts: every node the page connects to its AudioContext's destination is also fed to a ScriptProcessor that keeps what reaches the speakers while armed (`window.__ssTap.start/stop/chunk/stats`); counts blocks the main thread missed; reads the guest worklet's own `stats` every 2 s. Changes nothing the page plays. |
| `devlib.py` | The host's web UI on 127.0.0.1 (`/api/state`, `/api/action` as the Home page sends them): guest links (paced for the 5 s / 12 an hour limits, each guest's volume set before they join), listening links, kick, revoke; REAPER's dev eval hook with its lock; Chrome with fake devices (windowed off screen, muted); `RemoteChrome`: headless Chrome on the laptop over `ssh laptop` + a CDP tunnel (a guest from another computer; nothing on its screen, nothing installed); the tap's fetch; `ears.py wav` scaled by 1/gain; tone level and frequency; CPU load. |
| `guests.py` | rt-p11 check 7 and rt-browserjoin: two guests with fake microphones (A: the ears pattern looped with 2.25 s of silence; B: 1500 Hz), a listening-link listener, captures in each page, extra guests to four live, a soak logging the host's rows and each page's counters every 10 s, a second capture at the end; always kicks, revokes and closes. `--laptop` puts the guests on the laptop. |
| `listen.py` | The listening-link check: `pattern.lua` plays the ears pattern through the desktop's master at -40 dB; listeners on the PC (`--pc`) and/or the S23 (`--phone`, `--launch-chrome`); in-page taps plus scrcpy on the phone; compared with the pattern. |
| `s23.py` | The S23 driver: its own adb server (port 5047), state and `busy()` (a call, or a touch in the last 10 minutes), Chrome's DevTools forwarded to 127.0.0.1:9341 and driven with Playwright `connect_over_cdp` (new tabs only, closed after), scrcpy playback capture (`--no-video --no-control --no-window --audio-source=playback --audio-codec=raw --time-limit`), the phone's clock over ssh. |
| `p5_checks.py` | rt-p5's phone checks over the phone link (`http://<desktop>:47281/?t=<token>`): two-page MIDI channels and take-over with REAPER's inputs read back, the @mention banner, the status line, a to-do for a bandmate, a 5 MB upload's SHA-256; everything made is deleted by its writer after. |
| `pattern.lua`, `probe.lua` | REAPER's side through the eval hook: the "T1 Pattern" track (this computer's own, armed with no input, master send at <= 0.01, ears.jsfx slot 2) and read-only probes (the web token, tracks' record input/arm/monitor). Never saves. |

How to run (desktop, Git Bash, Python with numpy/scipy and Playwright 1.65.2; Chrome; scrcpy 5.0.1):
```
python tools/devices/guests.py <out> --laptop --soak-min 15 --extra 2
python tools/devices/listen.py <out> --pc --phone --launch-chrome
python tools/devices/p5_checks.py <out>
python tools/devices/s23.py state
```

## Results (2026-11-22, 03:50-04:30 MST unless said)

Conditions: the desktop was shared with another agent's soak (CPU 86-92 % at the guest run's start, 58-66 % at its end). Earlier, at a run
queue of 30-70 (23:40-00:15), every page's audio clock and main thread were starved and the numbers were meaningless (see "Rig lessons").
Deafen was 1 on the desktop, laptop and LinuxBox before and after. Files: my scratchpad `rt-t1/` (g2 = guests, l1 = listening link, p5s23 /
p5a / p5b / p5m1-5 = rt-p5 checks).

### Browser guests (rt-p11 check 7, rt-browserjoin): `guests.py --laptop --soak-min 15 --extra 2`
Guests A (ears pattern) and B (1500 Hz) ran in headless Chrome on the laptop: guests from another computer, reaching the desktop's guest link
over the tailnet through `tailscale serve`, volume 0.01 each. The listener was a windowed Chrome on the desktop. This ran before the crash
precautions; `--laptop` now puts the listener on the laptop too.

| Check | Result | Numbers |
|---|---|---|
| A hears B, not itself | **pass** | B's tone in A at -55.1 dBFS (expected -55.1); A's own pattern absent (spectra 34-39 dB off) |
| B hears A, not itself | **pass** at join, **fail** at 15 min | join: level -0.02 dB, gaps 160 ms (longest 40), spectra 0.29/0.34 dB, B's own tone -87 dB. 15 min: gaps 640 ms (longest 110), chirp 16 dB off |
| A listening link hears both | **pass** | tone -55.1 dBFS; pattern -0.09 dB, gaps 200 ms (longest 30), spectra 0.68/0.62 dB; at 15 min gaps 120 ms (longest 20) |
| Four live at once | **pass** | 4 rows live (C and D with silent fake microphones) |
| 15 min, host's rows (no new under/drops after 30 s) | **fail** (small) | A under +5 drops +1, B under +5 drops +1 in 14.9 min |
| 15 min, each guest page's worklet | **fail** | A under +226 drops +90, B under +237 drops +95 (about 15 underruns and 6 drops a minute each) |
| rt-p11 check 8 (the listener over 15 min) | **fail** | `under` +8, `gaps` 0, `ahead` 0.14-1.03 s (expected to stay near the 0.25 s lead) |
| Pitch | **finding** | Just after joining, B's 1500 Hz reached A at 1506-1513 Hz (+0.4-0.85 %, ~15 cents), and 15 min later still at 1503.7-1507 Hz. The listener heard it at 1502-1507 Hz, then 1499.96 Hz. In B, A's pattern played at speed 1.0071 (1.0044 at 15 min) |

### Listening link: `listen.py --pc --phone --launch-chrome` (04:12)
The desktop played the ears pattern through its master at -40 dB (track "T1 Pattern", its own, removed after). The listener was a windowed
Chrome on the desktop.
- **The PC listener passes**: level -0.09 dB, gaps 180 ms (longest 70), speed 1.0018, `under` 0, `ahead` 0.19 s. The delay held steady:
  14904-14928 ms, largest step 18.9 ms over 5 windows.
- **The S23 was skipped**: James had touched it 30 s before.
- Since the 00:15 crash the coordinator has held anything that uses the desktop's audio output, so the phone half is **pending** (scrcpy
  capturing the S23 playing the link).

### rt-p5 phone checks: `p5_checks.py --phone` on the S23 (04:23-04:25)
The phone had been idle 12 minutes; TikTok was brought back to the front afterwards.

| rt-p5 check | Result | Numbers |
|---|---|---|
| 1 two pages Live into REAPER | **pass** | S23 "Playing XT Keys C in REAPER (virtual keyboard channel 1)", laptop page "XT Drums A ... channel 2"; REAPER's inputs read back 6081/6082 (virtual keyboard device 62, ch 1/2), both armed |
| 2 the second page takes the track | **pass** on the S23; **intermittent** over 7 runs | S23 "Not played in REAPER: another page took this track", Live unticked; both tracks back to input 0 and unarmed 0.4 s after off. From laptop pages, 2 of 7 runs failed: the first page wasn't told within 15 s, and in one of them the tracks were put back only by the idle release |
| 5 @mention banner over the phone link | **pass** | "James-Laptop mentioned you · Studio: @James ..." (page not a secure context), title "StudioSync" -> "(1) StudioSync"; the buzz can't be observed |
| 8 status line | **pass** | on the desktop at once, on the laptop's page 0.7 s later (10.2 s in a laptop-page run); cleared |
| 10 to-do for James-Laptop | **pass** | on the laptop's Home "To-dos for you" 13.3 s later (4.5 s in another run); deleted |
| 11 upload past the 4 MB spool | **pass** | 5 MB: 200 in 1.6 s; the shared copy's SHA-256 equals the bytes sent (the pages' file model carries no hash, so the copy itself was hashed) |
| 3, 4, 6, 7, 9 | not run | 3 USB keyboard: needs a real keyboard (James). 4 claimed take pick: needs the room in Claims mode (not changed). 6 Open from Home: would switch REAPER's tab in front. 7 mix time zones: needs another time zone. 9 since last here: needs a bandmate edit while another project is in front |

## Bugs and findings (evidence in the scratchpad folders named)
1. **Guests' down path under-runs about 15 times a minute over the internet.** In g2 `soak.jsonl`, each guest worklet's `under` went 5 -> 231
   and 3 -> 240 over 15 min, with `drops` +90/+95, while the host's up rings moved only +5/+1. `guestworklet.js` holds a TARGET of 80 ms of
   the session mix, and the laptop is 78 ms round trip away through `tailscale serve` (TCP). The listening page grows its lead on an underrun;
   the guest page doesn't. Suggest an adaptive target: grow on underrun, shrink slowly.
2. **A guest's sound plays sharp after joining**: up to +0.85 % (~15 cents) at another guest, and still +0.2-0.5 % 15 min later (g2 c1/c2,
   `tone_b_hz`). Two drift controllers sit in a row: the host's up ring and the hearing guest's worklet, each allowed up to 0.5 %. Both read
   fast while their buffers sit over target. rt-p11 expected 9 cents at most, and only when far off.
3. **Listening page drift (rt-p11 check 8) fails over 15 min**: `under` +8, `ahead` up to 1.03 s. The desktop was CPU-loaded: rerun on a quiet one.
4. **Two-page take-over is intermittent** (p5b, p5m1): the first page sometimes isn't told within 15 s.
5. **`phonekeys` keeps closed pages' entries** (p5m3-5): four sids listed, two of them earlier runs' closed pages, with `why`. Cosmetic.
6. **A deleted chat message leaves its file in the shared folder.** `_band/chat/files/<stamp>~t1-upload-041539.txt` (5 MB) stayed after its
   message was deleted, so it syncs to every computer. The test now removes its own copy.

## Rig lessons
- **Load:** at a run queue of 30-70 (another agent's 6+3 parallel soaks), a headless Chrome's AudioContext ran 2.1 % slow with 0.34 s of
  wander, a windowed one 0.2 % slow, and an empty page's timers stalled up to 0.6 s. Guests then under-ran and dropped about once a second
  (g0, g1). On a quiet machine both kinds keep 1.0000 (13-23 ms wander, no stalls). `guests.py` logs `cpu_load`.
- **adb:** the desktop's usual adb server (5037) runs elevated. It was wedged on 11-21 from about 23:22: `devices`, `shell` and `reconnect`
  all hung, and an unelevated shell can't stop it. `s23.py` uses its own server on 5047. After the reboot, 5037 answered again (no devices
  on it).
- **The S23 on its charger** stays awake and unlocked with the last app in front for hours (stay awake while plugged in, TikTok holding the
  screen on). So `busy()` goes by the last touch (`dumpsys power` `lastUserActivityTime`): 10 minutes.
- **Chrome on the phone** had no DevTools socket until its activity started. `s23.tab()` opens the link with a VIEW intent, attaches,
  reloads with the tap and brings the previous app back. Web MIDI is taken out of the page on the phone, so Chrome never asks James for a
  permission.
- **Ports:** 9222 is often busy on the desktop, so the phone's DevTools go to 9341.

## Left
- The listening link on the S23 with scrcpy capture: held until the crash is understood (it needs the desktop's audio output).
- The guest soak and check 8 again on a quiet desktop, with the listener headless on the laptop.
- Safari and iPhone, and a real USB keyboard (rt-p5 check 3): James's band-test list.

## Review later (security)
- `RemoteChrome` opens the laptop Chrome's DevTools on the laptop's 127.0.0.1, plus an ssh tunnel to the desktop's 127.0.0.1, for the run.
  The phone's DevTools forward sits on the desktop's 127.0.0.1:9341 for the run and is removed after.
- The phone link with its token goes into the S23 Chrome's history (as a QR code would).
- `webtap.js` and the Web MIDI removal are test-only init scripts, never shipped.
