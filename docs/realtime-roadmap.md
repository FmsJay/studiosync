# StudioSync real-time roadmap: the direct link as the main path

James, 2026-11-19. Goal: StudioSync should feel like one DAW shared by everyone, live. The direct link
(docs/direct-link-design.md: the extension's own signed TCP link over Tailscale) delivers a change in about 30 ms
where Syncthing takes about 2.3 s (measured desktop -> laptop, laptop off the home network). This roadmap makes that
link the main path for everything it can carry, and asks, step by step, whether Syncthing, NINJAM and SonoBus are still
needed.

## Where things stand

| Job | Today | Speed today |
|---|---|---|
| Edits (event files) | Syncthing | ~2.3 s + up to 2 s polling |
| Start/stop together, cues | event files via Syncthing; clocks by internet time (NTP) | seconds; clocks tens of ms apart |
| Presence, claims, chat | files via Syncthing | seconds |
| Live MIDI view | a new file every second via Syncthing | arrives in batches, seconds late |
| Takes and other media | Syncthing | minutes for a long take |
| Real-time audio, Talk | SonoBus (separate plug-in) | network latency + its buffer |
| Play along in time | NINJAM (ReaNINJAM + relay) | one interval behind, by design |
| Video, screen share | an outside call service | n/a |

## What the extension can do (checked)

- Network: its own TCP link (built, 0.59.50), and UDP when needed; Tailscale gives the addresses and encryption.
- Audio: REAPER's `Audio_RegHardwareHook` (reaper_plugin.h `audio_hook_register_t`, confirmed in the SDK on disk)
  calls the extension on the audio thread twice per buffer, before and after REAPER's processing, with the hardware
  input and output buffers. It can read inputs (or the output mix) and add audio to the outputs.
- No video or window API for video inside REAPER: video goes through the browser (step 5).

## The steps

### 0. Changes over the link (0.59.50, built, wiring next)
Every event file goes straight to whoever is in the room, Syncthing's copy following as the record.

### 1. The live layer (target: a bandmate's edit visible in under 300 ms)
- A small-message channel on the same link: presence and heartbeats, claims ("Bo is editing Bass"), chat, likes,
  follow-mix and producer cues, start/stop: no files, no disk churn.
- A shared clock: each pair of computers pings over the link and keeps a running estimate of its clock offset and
  round trip (NTP's method, in-band; a few ms of error on Tailscale). Play together / Record together start every
  computer on the same bar within a few ms. Like Ableton Link (tempo + beat phase), but across the internet.
- Looks as soon as something changes instead of every ~2 s. Here the back-burner "change notifications" pay off:
  REAPER's control-surface callbacks tell the extension what changed (tracks, FX, volume, selection); items still need
  a quick look, but only when the project's change counter moved.
- Optional: bandmates' play cursors and selected items shown on your timeline.

### 2. Interval streaming: NINJAM built in (hear and see a take as it's recorded)
While someone records, REAPER writes the take's file as it goes. The recorder's computer reads the growing file and
sends each new interval (one bar, or N beats; tempo-aware, from the shared clock) over the link. Everyone else:
- sees the take grow on its track at its true song position, waveform and all, interval by interval;
- hears it in either of two ways, per listener:
  - **In time (NINJAM style):** your playback runs exactly one interval behind the recorder's, so what they play lands
    on your grid in time; you play along to it and your part streams back the same way.
  - **As it comes:** placed and played as soon as it arrives (watching a take, producing).
- at stop, the take is already complete on every computer: no Syncthing transfer for takes at all. The file's hash is
  checked against the recorder's; Syncthing's copy (while kept) is only the backstop.
- Live MIDI view becomes the same thing for notes: each note as it's played (~50 ms), not a file a second.
- Replaces NINJAM for StudioSync users: no server, no relay, no separate plug-in, and the recorded parts are real takes.

### 3. Media over the link, then offline
- Any media file (prints, plug-in files, imported audio): chunked, resumable, hash-checked, sent to whoever is here.
- Offline: when two computers meet, they compare what each has (event ids and media hashes) and pull what's missing,
  as Syncthing does today. An always-on computer (the desktop) can hold and pass things on for computers that are
  never online at the same time.
- Decision gate (James): only when this works on all three systems does Syncthing become optional (kept as a setting
  and a fallback; never removed while a studio relies on it).

### 4. Real-time audio built in (replace SonoBus)
- The audio hook captures the chosen inputs (your mic and instrument, or a monitor mix), encodes with Opus (libopus,
  BSD licence), and sends over UDP on Tailscale; each listener has a jitter buffer and mixes everyone in after REAPER's
  processing, with per-person volume, mute, Talk and deafen (the call window's controls).
- Latency target: network one-way + 10-20 ms of buffering. Desktop -> laptop measured ~28 ms one way: calls and
  watching are easy; playing tightly together needs short distances, else step 2's "in time" mode.
- Decision gate: a spike first (glitch-free audio desktop <-> laptop for an hour, CPU in budget), then real sessions;
  SonoBus stays available until it holds up.

- Audio formats (James): any channel count, and a choice per studio/person: Opus (default over the internet,
  ~128-256 kbit/s, hides lost packets), FLAC (lossless, ~1.2-1.5 Mbit/s stereo 48 kHz/24-bit, small frames of
  256-1024 samples so it adds only ~5-20 ms) or plain PCM (lossless, ~2.3 Mbit/s, lowest CPU). Lossless can't hide a
  lost packet, so it's for good connections (Health shows loss per bandmate; StudioSync can suggest Opus when loss
  rises). Different sample rates on the two ends are resampled, and the slow drift between two audio interfaces'
  clocks is absorbed in the jitter buffer (adaptive resampling), or long calls would click every few minutes.

- **Hear what a bandmate plays when they arm (James, 2026-11-19; built, see below).** Today live audio sends one fixed
  input range per computer (the call mic). An armed track's sound isn't sent: not a guitar on another input, not an amp
  sim's or a synth's output, not a MIDI instrument. Proposal, two sources per computer:
  - **Talk:** the call mic, as now.
  - **Play:** every armed track's sound after its FX, as you hear it when you monitor it (amp sims, synths, MIDI
    instruments included). Armed tracks send post-FX to a hidden "live out" track read by the extension, the tap 4b
    already uses ("feeding and reading a hidden track"). Never the master, so the others' audio isn't in it (no loop).
  - **Which is sent (automatic, per computer):** nothing armed -> Talk. A track armed -> Play, sharing ideas before
    and while recording. Plus Talk, unless the call mic is an armed track's input: then it goes once, as Play (the voice
    with its FX), never twice (the echo/doubling guard). A per-computer override: Auto, Talk only, Play only, Both.
  - Listeners get a Talk and a Play volume per bandmate (the personal monitor mix, Decisions 11). Play is heard one
    network trip late: fine for ideas and for watching a take; playing tightly together stays step 2's "in time" mode.
  - **Built (rt branch, 2026-11-19; native and Lua tests only, not run in REAPER yet).** Two AOO streams per computer: Talk (source 1,
    as before) and Play (source 2), each listener with a sink per stream per bandmate (Play's ids: the address hash with "/play"), so the
    Talk and Play volumes are truly apart; Play's buffer size follows Talk's adaptive one. The tap: Lua makes a hidden local track
    (band_local "liveout", "StudioSync live out": no master send, no anticipative FX, chain PDC "ignore") holding a StudioSync Hop (a free
    hop id, 64 down), the armed tracks (the song's and "yours", never StudioSync's helpers) send to it post-FX (`I_SENDMODE` 3); the
    extension opens that Hop's mapping on its send thread and, in the hook's post call, sends the newest block of its send ring (the Hop
    wrote it in this block's FX pass), silence when nothing came, never a backlog. ReaScript: `StudioSync_LiveAudioPlay(hop_id, send)`
    (0: no Play stream; send 0: silence, the stream kept) and `StudioSync_LiveAudioPeerPlay(peer, gain)`; Status adds play, play_alive,
    play_send, play_level and per peer play_streaming, play_level, play_gain. Lua guards both (`liveaudio.can_play`): without them, Talk
    alone as before. Choice per computer in Chat > Call (Send: Auto, Talk only, Play only, Both; ExtState "live audio source"). Mute me and
    Deafen silence both; push-to-talk and talkback are Talk's (talkback still quiet while recording, Play goes on); held talk opens Talk even
    in Play only, or opens Play when the call mic already goes as Play. The echo warning looks only at what Talk sends. Each computer's
    status carries `lsrc` (talk/play/both/none): Chat > Call shows each bandmate's Talk/Play and has a Talk and a Play slider per bandmate
    (kept by name in the cue mix, `play`); Health says what this computer sends and who's playing. The live out track goes when Live sync
    ends or the studio turns live audio off. An older bandmate's extension refuses Play's datagrams while Play is on ("for a stream that
    isn't theirs"), until EXT_WANT moves past 1.0.15. Tests: tests/rtaudio_test.cpp (Talk 0.2 and Play 0.7 heard apart, Play muted, the
    live out track stopping: play_alive), tests/test_0_60_rt_liveaudio.lua (the plans, the live out track and its sends on a stand-in).
  - To check in REAPER (desktop + laptop): the checklist in the session's report; above all that the live out track keeps processing
    while stopped with an armed, monitored track, and that Play needs input monitoring on (an unmonitored armed track sends its playback).
- **Record several at once (James, 2026-11-19): guitar and voice, several MIDI instruments.** REAPER records any number
  of armed tracks; StudioSync's parts are per track: smart take names (one number per take, top track first), streamed
  takes and their placeholders (each armed audio track its own stream), the live MIDI view (each recording MIDI track).
  To check in REAPER: two audio tracks at once (names, placeholders and the real takes on the others) and two MIDI
  tracks at once (both live views). With Play above, several armed tracks mix into the one Play stream.
  - **Audited and fixed (2026-11-19, tests/test_0_60_rt_multitrack.lua; offline, not run in REAPER yet).** Two audio tracks at once
    were seen right in REAPER. Fixed for several at once: which file is whose (an armed track that isn't the band's, its own or one with
    no oid yet, now claims its file instead of "Gtr" taking a local "Gtr 2"'s; one name on two tracks: the file starting with each
    track's number; the extension and digits-only names left out of the name match; ties keep track order); a track recording its
    output (a synth on a MIDI input, record: output stereo/mono/multichannel) streams as audio and gets no live MIDI view, nor does
    record: none; a multichannel take says its channel count; live MIDI keeps one part per track (a second "Synth" is "Synth (4)", a
    note held on both ends on both) and a track disarmed mid-take ends its held notes there; smart take names leave a track armed
    mid-take's old takes alone; the low-disk line counts the armed audio tracks. Limits: one name on two tracks with no number in the
    files: the top track gets the first file (by name), which may not be REAPER's order; several MIDI parts show as overlapping items
    on the recorder's one "(live)" track.

### 4b. Remote plug-ins in real time ("live hops")
Hear a plug-in you don't have, live, through the bandmate's REAPER that does have it, instead of waiting for a print.
- A small StudioSync audio plug-in (VST3/CLAP, part of the extension package) sits in your chain where the missing
  plug-ins are. It sends that point's audio to the computer that has them; there, StudioSync feeds it through a hidden
  track holding just those plug-ins (the same chain, synced as now) and sends the result back.
- Playback: the plug-in reports the round trip as its latency (e.g. 100-200 ms), and REAPER's own plug-in delay
  compensation runs everything else that much ahead, so playback stays in sync and sounds whole, live, with no render.
  Knob turns on the remote plug-in are heard after that round trip.
- Several hops (the chained-prints case: laptop's EQ, then desktop's amp): one plug-in per stage, each going to the
  computer that has that stage; the latencies add up and REAPER compensates the total.
- Live monitoring while you play through a plug-in you lack: possible, but you hear yourself one round trip late
  (~60-100 ms on the desktop <-> laptop path): fine for checking a sound, not for playing tight. Prints stay the record
  and the fallback when the computer with the plug-in is offline.
- Needs step 4's audio transport (formats, jitter buffer, drift) and the plug-in binary on every system.
- **Staying in sync (James, 2026-11-19):** every hop reports one FIXED latency = network round trip + the remote
  processing + a jitter margin (e.g. the worst recent round trip plus a buffer); REAPER's PDC delays everything else by
  the same amount, so playback is always aligned (play starts that much earlier internally, nothing is heard late).
  Chains of hops add up and REAPER compensates the total. The reported latency only changes while stopped (a latency
  change during playback makes REAPER recompute PDC, which can glitch); if the network falls behind the margin the hop
  plays the print (or the dry signal) for that block instead of drifting. Live monitoring through a remote plug-in can't
  be compensated: prints and local plug-ins stay the answer there.
- **First Hop plug-in built (rt-hop branch, 2026-11-19; offline tests and a CLAP smoke host only, not run in REAPER yet):**
  - `plugin/`: `StudioSync Hop`, VST3 + CLAP on DPF (pinned commit, ISC: `plugin/third_party/README.md`), no UI. Parameters: Hop id
    (1-64), Latency budget (256-8192 samples, default 7200 = 150 ms at 48 kHz), Dry when late (1 dry, 0 silence), Bypass (the host's bypass;
    dry at the same latency), Late blocks (output). Latency and hop id changes wait until the transport is stopped.
  - Timing (`plugin/hop_core.h`): frame i outputs the return for frame i - L; a return not back in time plays the input from i - L
    (or silence) and counts the block as late, so the timing never moves. Checked to the sample in `tests/hop_test.cpp`.
  - Channel (`plugin/hop_shm.h`, one C header for both sides): a named shared mapping per hop, `StudioSyncHop-<REAPER pid>-<hop id>`
    (CreateFileMapping on Windows, shm_open elsewhere), not a StudioSync_* function: a bridged or sandboxed plug-in (reaper_host64)
    can't call into the extension, and finds REAPER's pid as its parent's. Two stereo rings indexed by an absolute frame number:
    `send` (plug-in writes, publishes `send_w`), `ret` (extension writes, publishes `ret_w`); ret frame i is the processed send frame i.
  - Extension (`extension/hop.cpp`): `StudioSync_HopLoopback(hop_id, delay_samples)` (each frame back after `delay_samples` more were
    sent; negative stops) and `StudioSync_HopStatus(hop_id)` (JSON: latency, frames sent and returned, late blocks).
  - **For rtaudio (the network leg):** open the hop's mapping with `hop_shm_open(&m, hop_reaper_pid(), id)`; read send frames
    `[r, send_w)` with `hop_copy_out`, send them tagged with their frame number; the bandmate's side runs them through the synced chain
    and returns the same numbers; write them with `hop_copy_in(ret, frame, ...)` and move `ret_w` forward with `hop_store` only over a
    contiguous run (conceal or zero a lost packet first). Set `ext_mode = HOP_EXT_NETWORK`. The bandmate's side (`Hop (source)` ->
    plug-ins -> `Hop (sink)` on a hidden track) is the next step; `reserved[]` in the header is room for its round trip and losses.
  - Limits for now: stereo only; one plug-in instance per hop id (two would both write `send`); a POSIX mapping's name is removed when
    REAPER quits.
  - Build: Windows with MSVC 14.29 (VS 2019 Build Tools, vcvars64) and CMake's NMake generator, `pluginuild_windows.cmd`, static CRT
    (the plug-ins need only KERNEL32); macOS universal and Linux x86_64/aarch64 in `.github/workflows/plugin.yml`, which also runs
    `tests/hop_test.cpp`. Output in `plugin/build/bin` (not committed). The budget must also cover the host's block size: a block longer
    than the latency can never come back in time.
  - To check in REAPER: the Hop loads as VST3 and CLAP, in-process and bridged ("Run as: separate process"); its latency shows in the
    FX window's PDC and other tracks line up; the loopback is exact and stays in time; a too-long loopback plays dry without moving.
- **Hop network leg built (rt-hopnet branch, 2026-11-19; native and Lua tests only, not run in REAPER yet):**
  - Transport (`extension/hopnet.cpp`): raw 32-bit float PCM, stereo, 128 frames a datagram (1060 bytes), on live audio's UDP socket
    (rtaudio hands it every datagram starting "SSH1": `rt_set_extra`, `rt_send_raw`), HMAC-SHA256 from the studio secret under its own
    label. Not AOO + Opus: AOO's sink resamples into the receiver's clock and hands out blocks, not numbered frames, and Opus is lossy with
    a decoder delay, so nothing could come back sample-exact. Float, not 24-bit: a bus can run over 0 dBFS in REAPER. 3.1 Mbit/s each way.
  - Frame numbers are the clock: each packet carries its first frame's number in the hop's send ring; the remote returns under the same
    numbers; the sender publishes `ret_w` over unbroken runs, zeroing (and fading back in after) a frame that isn't back when the plug-in's
    next block needs it, counted as lost. Pings every 200 ms give the round trip and the remote's state.
  - The remote is the same Hop plug-in at both ends of a hidden local track (band_local "hop"): Hop X (its ret ring is fed), a copy of
    the song's plug-in, Hop Y (its send ring is the result). Chain PDC set to "ignore" (`chain_pdc_mode` 2), so REAPER adds nothing there;
    no master send; no anticipative FX. Requester frame f goes into X at f + A (A set so it lands `margin_ms`, 20, ahead of X); a table
    keeps which f sits in each X frame; Y frame y holds X frame y + delta - pdc - Lx (delta = Xw - Yw, the smallest seen reading Y then X,
    as X runs first in each block). Clock drift between the computers moves A (a "slip": a click, counted, never a timing change).
  - Budget at 48 kHz, block 256, L = 7200 (150 ms): network round trip (desktop <-> laptop measured 59-75 ms) + the remote (20 ms margin
    + two blocks and polls 13 ms + X's 256 = 5 ms + the plug-in's PDC) + our side (a block + 1 ms = 6 ms, a packet's wait each way 5 ms)
    = about 125 ms + the plug-in's PDC. `StudioSync_HopStatus(id).net.need_ms` is that, measured; Health says to raise the budget when it's
    over (the Hop's maximum is 8192 = 170 ms).
  - ReaScript: `StudioSync_HopConnect(hop_id, peer, json)`, `StudioSync_HopServe(json)`, and HopStatus's `net` (rtt, remote, need, slack,
    sent, returned, lost, late, slips). Lua: `lib/hops.lua` (who has it: prints.has; a Hop as this computer's own FX "for=hop"; asked over
    the link; the remote's knobs follow the song's; start/stop with Live sync; a Health row per hop each side) and the action
    `StudioSync - Run plug-in on a bandmate.lua` on the focused FX window. Live audio carries the hops: when the studio has it off, it's
    started with nobody to send to.
  - Checked (`tests/hopnet_test.cpp`, two endpoints on localhost through a lossy wire, a fake remote: X -> 100-sample delay x 0.5 -> Y):
    every frame exact or zero (or fading in), never misaligned: clean 100% exact; jitter 5-13 ms with 2% loss each way 94% exact; remote
    clock 1% fast or slow 99-100% with 1-2 slips; a wrong secret gets nothing back. A stall (the remote's audio thread 80 ms, the
    sender's 80 ms, both 100 ms) costs about the stall's length of audio, then 99.9% exact again within a second: the block size is
    measured per block (a catch-up burst isn't one huge block), and a slip's anchor tightens back 0.15 s later (5bc9172).
  - Limits: stereo; both computers at one sample rate (refused otherwise); not on the master; one hop per plug-in instance; a slip clicks.
  - To check in REAPER (desktop asks, laptop hosts): Live sync on both, live audio's UDP rule on both; run the action on an offline plug-in;
    the laptop's hidden track appears (Show all tracks), keeps processing while the laptop is stopped and playing ("Run FX when stopped");
    Health's hop row on both; a tone through a known-latency plug-in comes back aligned with a dry copy on another track (no comb when
    summed); a knob turned on the desktop is heard after the round trip; lost/late stay near 0 for ten minutes; stop removes both ends.
  - **Run in REAPER (2026-11-19, desktop asks, laptop hosts, extension 1.0.17 + hopnet fixes, 0.59.49.52):** the laptop is remote over the
    internet: 80-125 ms round trip (Tailscale direct). Fixed on the way: the remote slipped on every late packet, so each 40 ms spike cost the
    next 150 ms too (8-13% lost; late packets are now dropped, only lateness that lasts 80 ms slips); REAPER starts playback by processing the
    Hop's whole latency at once (8192 frames) and every return after it came back late for 3 s (the remote now tightens 50 ms after packets land
    past its margin); Live sync's reload in place forgot the hidden tracks a computer hosts (state kept, orphans removed); hops use the plug-in's
    most budget (8192 = 170 ms; 150 ms left 12 ms to spare on this link), the remote margin is 30 ms, the Hop's track runs without anticipative
    FX, and Hop Y plays its input so the hidden track's meter shows the hop. Measured: stopped 0.34% lost, 0 slips; playing 50 s 0.7% lost
    (27 dropouts, single lost packets), 12 late blocks at each play start (the latency pre-roll), none after; a null test (a 97 Hz saw through
    an offloaded Volume 0 dB against an inverted dry copy) sums to 0.0000 against 0.26-0.50, stopped and playing; stop removes both ends
    (laptop's track gone within 6 s). Both actions' paths (Offload, Run plug-in on a bandmate) behave the same.
  - Still: a lost frame plays as silence, not dry (the Hop's "Dry when late" only covers a return that never came: marking lost frames in the
    ring needs a plug-in build); the play start's pre-roll costs about half a second of the hop's audio; 170 ms is the plug-in's most, so a
    link with a round trip over ~120 ms needs a bigger maximum (plug-in build); two hops at once on this link lost more (one went back at 2.7%).

### 5. Video and screen share
- The extension serves a small page on this computer and opens it in the browser; the browser's own WebRTC does
  camera and screen share, peer to peer over Tailscale; the link carries the setup between computers. No outside
  service. Can share the REAPER window.

#### First version built (rt-video, 2026-11-19: offline tests only, not run in REAPER, no camera opened)
- **Where:** the web UI (browser on this computer, or the docked view). `lib/webui/call.js` + `call.css` (a "Video" section and the
  sharing bar; `index.html` gains two links and two empty elements, `app.js` one line that hands its snapshot on as an `ss-state`
  event); `lib/webcall.lua` (the relay; `lib/webui.lua` takes the `rtc` action, installs Live sync's `handlers.rtc`, publishes the
  `rtc` topic).
- **Signalling, no server:** page -> `POST /api/action {topic:"rtc", t, to, call, kind, sdp}` -> Live sync's tick -> `webcall.page`
  checks it and `direct.send_live(cfg, "rtc", ...)` to the one peer whose Syncthing device id is `to` (by `direct.peers`' dev_of;
  calls are per computer, so James's desktop and laptop are separate) -> their Live sync's `handlers.rtc` -> `webcall.link` checks it
  again (a known kind; call id `[%w-]{8,64}`; SDP starts `v=0` and is at most 12,000 bytes, under the server's 16 KB POST; for this
  computer; from a computer in the room now, by the same peer list) -> their pages read the `rtc` topic `{ boot, me, open, msgs }`.
  The server keeps only a topic's latest state, so `msgs` is a numbered queue (the newest 16, 30 s each; pages keep their place by
  number, starting again when `boot` changes). Kinds: `here` (to everyone: the page is open and can do video), `offer` (`kind` call
  or screen), `answer`, `bye`, `busy` (declined). The relay adds `error` (that computer isn't reachable, or the link didn't take it)
  and an `out` copy of what this computer sent (no SDP), so a ring shown in two windows here stops when one answers.
- **ICE:** no trickle. Each side waits for gathering to finish (3 s at most) and sends one offer / one answer with its candidates
  inside, so a call is two link messages. `iceServers: []`: host candidates only, which over Tailscale are the 100.x interface.
- **Presence:** a page that can do video posts `here` every 10 s while Live sync runs; this computer passes it on at most every
  5 s; a bandmate's page counts as open for 25 s after its last word. The list shows each open one (name and computer) with
  **Call** and **Share screen**. Only bandmates in the same song and room (the link's messages are per song/room).
- **Media:** a call sends the camera (640x360 ideal); call audio off by default (a tick box: live audio already carries the music),
  and the caller always offers to receive audio so a callee with it on is heard. Screen share: `getDisplayMedia` with no audio,
  15 fps ideal; the browser's own picker offers REAPER's window or the whole screen; the sharer offers, the viewer only receives.
  Tiles per bandmate, a big view for a screen being watched, and the sharer's own preview.
- **Screen share safety:** view-only (no input path exists). The pointer: the viewer clicks the picture, the place (0 to 1 each way)
  goes over the call's own data channel, and the sharer sees a named dot on their preview (only there: see below). While sharing,
  a red bar under the header always says "You're sharing your screen with ... . Stop"; the browser's own "Stop sharing" ends it too.
- **NAT / Tailscale (the catch):** Chrome, Edge, WebView2 and Safari give a page that may use neither camera nor microphone only
  the default route's address, hidden behind an mDNS name; mDNS is multicast and doesn't cross Tailscale, and the default route
  isn't Tailscale's. So two such pages can't connect unless they share a network. A video call is fine (the camera allows it). For
  a screen share, both pages ask once for the microphone and let go of it at once (the page says why; nothing is recorded or sent);
  after that the browser offers every interface's real address, Tailscale's too. If the microphone is refused, it still connects on
  one network. If host candidates fail anyway (Tailscale down, a firewall on UDP between the two), the call says "Couldn't connect
  ... over Tailscale" after 20 s: there's no relay. TODO if that bites: a TURN relay inside the extension on the link's port (no
  outside service), or carry media over the link itself.
- **Phones:** not in this version. The phone link is `http://<name>:47281`, not a secure page, so browsers keep camera, microphone
  and screen capture off; the section says so.
- **Docked view, Windows (WebView2):** `PermissionRequested` allows camera and microphone for the pages' own origin only
  (`webui_dock_permission`: 1 allow, -1 deny for any other origin, 0 the view's default for other kinds) and denies other origins;
  `ScreenCaptureStarting` (runtimes with ICoreWebView2_27) cancels screen capture for anything but the pages' origin; WebView2 shows
  its own screen picker. Allowed states are saved in the view's own profile, so the microphone ask above happens once, silently.
- **Docked view, macOS (WKWebView):** `WKUIDelegate`'s `requestMediaCapturePermissionForOrigin` (macOS 12+) grants camera and
  microphone for the pages' origin only. REAPER 7.86's own Info.plist has `NSCameraUsageDescription` and
  `NSMicrophoneUsageDescription`, and its signature the `device.camera` and `device.audio-input` entitlements (checked on the Mac,
  2026-11-19), so macOS asks once, for REAPER. Screen capture also needs REAPER allowed under Screen Recording, and WKWebView's
  `getDisplayMedia` isn't in every macOS: where capture fails or isn't there, the section offers **Open StudioSync in your browser**
  (a new window, which the view hands to the browser). Remote video and call audio play without a click
  (`mediaTypesRequiringUserActionForPlayback = none`).
- **Tests:** `tests/test_0_60_rt_webcall.lua` (what a page and a bandmate's computer may send, routing to the right peer only,
  `here` rate, errors back to the page, the queue's limits and ageing, a link check of call.js / call.css / index.html / app.js);
  `tests/test_0_60_rt_webui.lua` (the `rtc` action reaches lib/webcall.lua, the topic is published); `tests/webui_dock_test.cpp`
  (the permission rule). The headless WebView2 test still loads the pages (call.js opens nothing on load).
- **Not yet:** the dot on the sharer's real screen (the extension could draw it over REAPER's window: a small topmost layered
  window); calls of three or more are separate pairs (a mesh: each Call is one bandmate); call audio can't change mid-call; one
  studio at a time, as the rest of the web UI.
- **To check in REAPER (two computers on Tailscale, both with Live sync on in the same song/room, the web UI open on each):**
  1. Each sees the other in Video within ~10 s; closing one page drops it within ~25 s.
  2. Call from the desktop's browser page: the laptop rings in every web UI window it has open; Answer in one, the other stops.
     Both see both tiles; no call audio unless ticked on both; hang up from either side ends both.
  3. Share screen from the docked view on Windows (WebView2's picker: REAPER's window), watch from the other in a browser: the
     microphone ask happens once, it connects across Tailscale (not just on the LAN: try the laptop off the home network), the red
     bar shows with Stop, the viewer's clicks show as named dots on the sharer's preview, Stop (and the browser's own Stop sharing)
     end it on both sides.
  4. The Mac: camera in the docked view (macOS asks for REAPER once), screen share from the docked view (Screen Recording for
     REAPER) or, if it isn't there, the "Open StudioSync in your browser" link works.
  5. The phone link shows the "isn't a secure page" line and nothing breaks.
  6. Decline -> "didn't take it"; nobody answers for 40 s -> "didn't answer"; a ring cancelled -> "Missed".

#### Remote control: design note for later (James: "take control only with an explicit yes for that session")
- Never on by default and never remembered: each session starts view-only. The viewer asks ("Ask to control"); the sharer gets a
  clear prompt naming who, and only an explicit **Allow for this session** turns it on. It ends when either side clicks Stop
  control, when the share stops, when the call drops, or after a short idle; the next share asks again.
- While on, the sharing bar says "chilio is controlling your REAPER. Stop" in a different colour, and the sharer's own mouse or
  keyboard input takes over at once.
- Input goes over the call's data channel to the page, then to the extension (the docked view's channel), which posts it only to
  REAPER's own windows (never system-wide input injection, never other apps); scoped to the shared window's area; rate-limited;
  no system keys (Alt+F4, Cmd+Q) and no file dialogs driven remotely.
- Lua keeps a log line per grant and stop. A guest (limited access) can never be granted control.

## Now that the extension is mandatory: what else changes (2026-11-19)

### Project files: snapshots plus changes
Sending whole .rpp files back and forth still conflicts (two people's saves overwrite each other), which is why
StudioSync sends changes object by object. What the link adds is the other half that databases use: **snapshots**.
- The hub (or whoever's most current) keeps a compact snapshot of each song: the project as of event N, plus its media
  list. A new member, a new computer, or one coming back after weeks gets the snapshot over the link and only the
  changes after it: joining or catching up takes seconds instead of replaying thousands of events.
- Snapshots also let history be compacted safely (today's trim, with a guaranteed restore point), and give song history
  playback (web UI) its keyframes.
- Saving the project stays local and normal; the snapshot is StudioSync's, not REAPER's save.

### Native speed for the hot paths
The heaviest Lua work moves into the extension (C++ is typically 10-50x faster at this): JSON encode/decode (a big
room's 10 MB of events decodes in ~210 ms in Lua today), the FNV/SHA hashing, chunk normalizing and diffing, the
event-folder listing. Lua keeps the logic; the extension does the number-crunching. Big songs' looks get much cheaper.

### Being told what changed
REAPER's control-surface callbacks (track list, FX, parameters, volume/pan, selection) reach the extension as they
happen, so a look reads only what changed, as soon as it changes (the back-burner idea, now cheap to do).

### Signed updates
With the extension everywhere, StudioSync updates can be signed with the studio owner's key and checked natively
before anything loads. That replaces "anyone who can write the shared folder can change the code" and the "Use it?" box
with a cryptographic check, and closes most of the security items held "until the full release"
(docs/REVIEW-2026-11-18.md "Planned"), without making setup harder. Updates can also travel over the link.

**Design (built first, James: early; extension 1.0.9):**
- **Signatures:** Ed25519, checked natively in the extension (extension/sign.cpp: TweetNaCl's Ed25519 and SHA-512, public domain,
  tweetnacl.cr.yp.to; plus the RFC 8032 check that S < L). ReaScript: `StudioSync_Verify(sig, message, key)`,
  `StudioSync_VerifyFiles(dir, key)` (a copy's lib/files.txt and lib/files.txt.sig, then every file it lists by SHA-256),
  `StudioSync_KeyCreate(path)`, `StudioSync_Sign(keypath, message)`, `StudioSync_FileHash(path)`.
- **What's signed:** lib/files.txt, which already has the version and every code file's length and FNV hash, gains a SHA-256 row
  per file (`sha256 <hex> <path>`: older band.lua and tools/files_check.py skip lines they don't know) for the code and the helpers
  that ship with it (lib/mac, lib/ninjam, lib/listen, lib/toolbar_icons, the extension binaries). FNV isn't cryptographic, so the
  signature leans on the SHA-256 rows. Text files are hashed with CRLF read as LF (a Windows checkout and a Mac copy agree; Lua reads
  them the same), files with a NUL byte as they are. lib/files.txt.sig = hex Ed25519 signature over `"StudioSync files.txt v1\n"` +
  lib/files.txt (CRLF as LF).
- **Signing:** tools/make_index.py writes lib/files.txt with the SHA-256 rows and signs it when the owner's key is on the computer;
  tools/sign_release.py [dir] signs any copy (a studio's folder copy). Both in pure Python (RFC 8032's reference code). In REAPER,
  fromfolder.sign_copy does the same with the extension. The private key (32-byte seed, hex) lives at `$STUDIOSYNC_UPDATE_KEY`, else
  `~/.studiosync/update-key`: outside every synced folder, never committed; one key per owner, for every studio they own.
- **The studio's key:** band.json `update_key` (64 hex), owner-written, read through groups.trusted like the other studio settings
  (needs "update_key" in groups.lua's SETTINGS), and pinned on this computer at first look (ExtState "update key <root>", kept in
  settings.json across a crash). A different key in band.json later doesn't replace the pin: logged once.
- **Load check:** run from a studio's folder (<root>/_tools/studiosync) in a studio with an update key, band.code_guard checks the
  signature first: valid, its files all matching their SHA-256, and the code on disk exactly what lib/files.txt lists -> recorded, no
  box, without "update ok". Anything else (no .sig, a changed file, another key, no extension 1.0.9) -> refused, a line in the log, no
  box: the script doesn't start from there, the startup block falls back to the last good copy, and a reload keeps the old code. The
  same answer decides update_ok (Autostart switches to a signed version without asking and never asks about an unsigned one),
  save_last_good (only a signed copy becomes the last good copy) and fromfolder.extension_tick (only a signed copy's extension is put
  into UserPlugins). A studio without a key behaves as before; a ReaPack copy isn't checked. The check reads only files on disk, so it
  holds however they arrived (Syncthing now, the link later).
- **Key setup:** `fromfolder.create_update_key(root)` (the owner, once: Settings > Studio): makes the key (or reads it), signs the
  studio's folder copy first when it's code this computer has said yes to (so nobody is refused the moment the key appears), writes
  `update_key` to band.json and pins it. `fromfolder.sign_copy(dir)` signs a new version the owner put in the folder.
- **Closes** (docs/REVIEW-2026-11-18.md "Planned, after the testing phase"): the release checksum check (with the owner's key instead
  of GitHub, so it works offline; helpers covered); the Syncthing writer check for folder code (superseded: who wrote a file stops
  mattering); `updates` believed on Syncthing's modifiedBy alone, for code (a member setting `updates` can't get code run in a keyed
  studio); and from "Not doing": FNV and helpers outside the check, and save_last_good copying an unchecked copy.
- **Still open:** band.lua, json.lua and the entry script are read from the folder before the check runs, so someone who rewrites
  band.lua itself skips it at a fresh start (a running copy never reloads into it: update_ok checks with the code already running).
  The fix is to run a verified local copy: the running code copies a signed version out of the folder and runs that (or the
  __startup.lua block calls StudioSync_VerifyFiles before it loads anything). Also open: an older signed version put back in the folder
  is accepted (downgrade); key rotation (each computer keeps its pin); an admin can set the first key (groups.trusted takes managers).

**Built (2026-11-19, not run in REAPER yet):** extension/sign.cpp + sign.h (registered from reaper_menu.cpp; build_windows.cmd and
.github/workflows/extension.yml build it); lib/band.lua (studio_update_key, pin_update_key, update_key, signed_ok, signed_update_ok,
approved_code; code_guard, update_ok, save_last_good, kept_keys); lib/fromfolder.lua (update_key_path, sign_copy, create_update_key;
extension_tick); StudioSync - Autostart.lua (no box for a keyed studio's unsigned version); tools/sign_release.py; tools/make_index.py.
Tests: tests/sign_test.cpp via tests/build_sign_test.cmd (RFC 8032 TEST 1-3 and SHA(abc), tampered message/R/S, S + L, other key, a
signed copy checked file by file, CRLF/LF, a lone CR and a binary's CR refused, paths out of the copy refused), tests/sign_cross.py (a
copy signed in Python passes the extension's check, tampered or unsigned it doesn't), tests/test_0_60_rt_signed.lua (the Lua flow, with
sign_release.py standing in for the extension). Before publishing a key: every computer in the studio on extension 1.0.9 (one without it
refuses the keyed folder copy and runs its last good copy), and EXT_VERSION 1.0.9 in reaper_menu.cpp, tools/make_index.py and
lib/tools.lua EXT_WANT.

### Things that can go, or shrink, in the new style
- **Takes to lanes becomes a studio setting (James, 2026-11-19).** The automatic "takes become lanes" pass
  (prints.takes_to_lanes) stays, as a studio setting the owner controls, on by default (as today), so everyone's songs
  stay alike across different REAPER setups. Items with several takes print their active take (today they get no print).
  "Set up this project" and its lane setup stay as they are.

### Shared settings: everything that isn't visual (James, 2026-11-19)
- **Project settings, per song** (travel with the timeline, the driver changes them), added to what's shared already
  (title, notes, group names, ruler lanes, timebase, pan law/mode, item mixing, pitch mode): project sample rate,
  recording format (WAV/FLAC, bit depth), metronome and count-in, grid and snap, project start / measure offset,
  playrate and preserve pitch, frame rate, render format. Not shared: record path, media folder, render output path
  (each computer's own folders), and anything only visual (zoom, scroll, view).
- **A studio preference set** for the global REAPER preferences that shape recording and editing (they live in each
  computer's reaper.ini, not the song): auto-crossfade and default fades, record mode and takes-vs-lanes on record,
  MIDI record/quantize options, item trim/overlap behaviour. Chosen by the owner, applied while working in that
  studio's songs, your own values put back after, the way a persona swaps settings; built on ReaPersona's apply/restore
  rather than a second mechanism. Each preference marked live or restart-needed.
- **Never shared:** audio device, buffer, latency settings, paths, theme, layout, zoom, colours.
- **Other StudioSync-imposed restrictions** are reviewed at the end of the branch and dropped where the link makes them
  unnecessary: edit holds and "X is editing that", held-back items, waits for audio still arriving, the 2 s quiet gate.
- Presence, heartbeat, status, cue and live-MIDI files: become link messages (the shared folder gets much quieter).
  - **Built (rt, 2026-11-19; offline tests and a stand-in only, not run in REAPER yet):** while the link reaches everyone in the room
    (`presence.link_carries`: each one here by presence answered the link's last send or ping; nobody else here counts too), a status change
    goes over the link alone (`sync.write_status(..., link_only)`), the whole status again every 15 s and at once when someone new is reached,
    and the status file is written every 30 s (`presence.FILE_QUIET`, `presence.put_status` / `status_due`, from Live sync's pass and its
    heartbeat while a pass waits). 30 s, not a minute: every file reader's window is 45 s (presence, `hub.FRESH`, `rooms.people`, older
    StudioSyncs), and other songs' hub elections get no messages, so a minute read as gone for 15 s of each one. A change to the hub part still
    writes at once. Anyone here the link doesn't reach (no Tailscale name, not trusted yet, a ping unanswered), or no link: today's pace, every
    change and every 15 s, from the first pass it's so (a dropped link writes the file at once). Readers take the link first: presence (as
    before), and now the scripts that take no messages (panel, Status, Take control, Offload track FX) through Live sync's copy in ExtState
    "presence live <studio> <song>/<room>" (`presence.live`): Health, shared CPU's `cpu`, the panel's rooms (`rooms.people`) and Status's
    catch-up (`status.gather`; a heartbeat's time vouches for nothing there: `said`). The web UI's presence topic and hub's link watch were
    already the link's. Live MIDI's 1 s files (already link-first) now count everyone here, not only the link's list (`direct.reaches_all`).
    **Stand-in (tests/test_0_60_rt_quiet_folder.lua, 10 min: idle, editing, playing, recording):** status file writes 27.4 a minute before,
    2.0 after (idle 6 -> 2, editing 60 -> 2, playing 6 -> 2, recording 4 -> 2); presence messages unchanged (27.4 a minute); longest between
    files 31 s. Not changed: cue files (one per Play/Stop together, the record of the start; already sent over the link too), claims, and
    Syncthing's pacing (1 s watcher delay, 2 s timeout: what the link doesn't reach still needs it fast).
- The waits for audio "still arriving" and the held-back/retry machinery: shrink as media streams over the link.
- Polling every ~2 s: replaced by change callbacks plus link arrivals.
- NINJAM integration and the relay tool: replaced by interval streaming (at James's gate).
- SonoBus state editing (lib/sonobus.lua's state parser): replaced by built-in audio (at James's gate).
- Hidden background REAPER instances for prints (bgrender): far fewer prints needed once remote plug-ins play live; the
  hub renders what's left.
- ~~The Google Drive cloud copy at session end: the hub keeps copies; Drive becomes optional.~~ Reversed (James, 2026-11-19): the cloud
  copy stays and grows, as the always-on member for studios without a hub. See "The cloud copy as the hub" below.
- Debug-mode collections written to the shared folder: sent straight to the owner over the link.
- The ReaImGui panel: replaced by the web UI, page by page.

### New features the extension makes possible
- **Who has which library:** fingerprints of sample libraries and kits (not just plug-in names), so prints happen
  exactly when someone lacks the sounds (replaces the sample-player name list).
  - *Built (lib/libraries.lua):* each computer publishes `libraries/<user>.json`, hashed ids of the sounds the songs
    use that it has (never a path or a drive listing). A sampler's MIDI part prints only when someone lacks one, for
    the samplers whose state says what they play: ReaSamplOmatic5000 (FILE0...), and any listed sampler whose state names
    audio files, SoundFonts, an .sfz (its samples followed) or a Decent Sampler .dspreset. Opaque, so still printed by the
    name list as before: Kontakt/Komplete Kontrol, EZdrummer/EZkeys/EZbass, Superior Drummer, Addictive Drums/Keys, BFD,
    Spitfire, SampleTank, HALion, Battery, JSFX file sliders (an index, not a name), and any state naming no file or a
    vendor format. Nothing is guessed. Health lists who lacks which sound or file for the song in front.
- **Presets and small content:** your own presets, IRs, amp captures and drum maps sent to bandmates who need them for a
  song (never plug-in binaries or paid libraries).
  - *Built (lib/content.lua, on top of lib/fxfiles.lua's carrying):* rules for what leaves a computer (a list of kinds,
    64 MB cap, never programs/plug-ins/scripts, nothing in a sample vendor's, sample store's or Program Files folder),
    the studio switch (Settings > Studio, owner and admins, on by default) and a Health line. VST3 presets REAPER shows
    (TrackFX_GetPreset's .vstpreset path, from your own preset folder) go too and land in the bandmate's own VST3 preset
    folder (AU presets Mac to Mac), where REAPER's list finds them. Limits: a plug-in's state is never rewritten, so an
    IR or capture reaches a bandmate's plug-in only where the same path can exist there; REAPER's own presets/*.ini
    aren't sent (the chain carries the sound); drum maps already travel (shared drummaps/, note names in the track).
- **Distributed bounces:** stems and mixdowns split across the computers that are idle.
- **Record from a phone:** a singer with only a phone opens the studio's web page and records a take straight into the
  song, in time from the shared clock (browser recording), arriving fast-first-lossless-after.
  - **Built (rt, 2026-11-19; not run in REAPER or on a phone yet):** the web UI's Record page (`lib/webui/record.html`, `record.js`,
    `record.css`, `recworklet.js`; a Record link in the header) and `lib/phonerec.lua` (wired into `lib/webui.lua`: action and tick).
    Pick a track this computer's user may record on (sync.authority, as the panel), Record: the phone captures through an AudioWorklet
    (32-bit float mono WAV, lossless; MediaRecorder's compressed file where there's none, and it says so) while this computer plays the
    song (Play together with a bar's count-in, this computer alone where the room's rules say so, or a start already coming is joined);
    at Stop the take goes up (POST `/api/upload`, `StudioSync_WebUISaveUpload` writes it beside the project's recordings) and in, as a
    real item, named "<section> - <singer> - take N" (recap's naming), and out to the band through mirror like any new item.
    Timing: the page's clock against the link clock (GET `/api/time`, quickest of 8 round trips), its first sample's moment from the audio
    context's timestamps less the reported input latency; here, the play position read beside the link clock every tick while the page is
    open, the median over the stretch. Expect 10-30 ms at home (the page says its estimate); a nudge (+/-5, 20 ms) moves it after.
    Secure page for the microphone: `tailscale serve --bg --https=8443 http://127.0.0.1:47281` (a button on the page runs it; 8443 so
    port 443's hub stays), and the server asks proxied loopback requests (X-Forwarded-*) for the token and takes their https Origin.
    Not yet: the fast copy first (one lossless upload, at Stop), the phone hearing the song itself (the singer listens to this computer),
    a band Record together started from the phone (it starts Play together: Record would stop on REAPER's warning where nothing's armed).
    Tests: `tests/test_0_60_rt_phonerec.lua`, `tests/webui_test.cpp` (proxy, clock, upload).
- **Crash-safe sessions:** the extension keeps the last unsent changes safe even if REAPER crashes mid-session.
  **Built in Lua (2026-11-19; offline tests only, tests/test_0_60_rt_crashsafe.lua, not run in REAPER yet):** what's changed and not
  yet gone out (plug-ins settling or waiting for the stop, Hold my changes, a copy still going) is kept beside the project in
  `<project>.bandsync-unsent.json`, written only when it changes (2 s apart at most), put back by the first look after a crash and sent
  once; Live sync's clean stop removes it. A reopened older save catches up instead of pushing: your own newer tempo map, markers and
  settings land again (they were marked done unapplied), settings that only read differently wait for the first catch-up, session.json
  carries the settings, and a claim doesn't follow the old file's track name back. Not covered: a held tempo or marker change (Hold my
  changes) still goes with an unsaved project.

### New scopes to explore
- **Without Tailscale:** an optional built-in connection (NAT traversal with a small rendezvous) for bandmates who
  won't install Tailscale. Designed and spiked (rt-nat, 2026-11-19): "Without Tailscale: design" below.
- **Beyond REAPER users:** through the web UI and browser recording, people without REAPER can listen, comment and
  record parts into a song.
- **Live to an audience:** stream the band's live mix to listeners on a web page.
- **Lessons and producing for clients:** a teacher or producer sharing their REAPER, drawing and talking over it.
- **StudioSync on the phone: a small DAW that's part of the band's project (James, 2026-11-19; proposed).** Not a REAPER replacement: a
  companion that records into the real project, so everything it makes lands in REAPER as ordinary takes. Built on the phone Record page.
  - **Stage 1 (browser, installable app):** works offline once opened (records to the phone, sends when a studio computer is back); keeps
    the latest mix of each project to play along to; takes saved as WAV with its position stamped in (REAPER reads it) plus which project,
    bar and track; an interface's input 1, 2 or both (Android Chrome picks the device, iPhone uses the system's input); MIDI from a USB
    keyboard on Android Chrome; nudge, retake, name, and a simple take list per project.
  - **Stage 2 (browser):** the project's tracks as a simple arrange view (the Project page's drawing, made for touch), several takes per
    track to choose between, volume/mute per track, a few built-in effects for monitoring, comments and the song sheet (lyrics, chords).
  - **Stage 3 (a native app, later):** what browsers can't do reliably: more than two inputs as separate tracks, low-latency monitoring
    through the phone, background recording, and iPhone MIDI. Same file format and the same way into the project.

## Without Tailscale: design (rt-nat, 2026-11-19; a spike in its own test, not in the shipped extension)
Today every computer-to-computer path assumes Tailscale: the link listens and connects only on 100.64.0.0/10 (direct.cpp `tailscale_ip`,
`addr_ok`, `connect_peer`), live audio and hops take UDP 47281 only from there (rtaudio.cpp `addr_ok`/`resolve`, hopnet.cpp through it),
lib/direct.lua finds peers by each devices file's Tailscale name on the studio's network (`groups.tailnet`), and the firewall rule admits
100.64.0.0/10 only. Tailscale gives three things: addresses that reach through NATs, who's allowed (the tailnet), and encryption
(WireGuard). The option below replaces all three for a bandmate without Tailscale, and changes nothing for the computers that have it.

**Library: libjuice (ICE) + Monocypher (crypto), with our own small handshake.**
| Option | Verdict |
|---|---|
| **libjuice 1.7.4** (MPL-2.0, C, no dependencies) | **Chosen.** ICE (RFC 8445) with STUN and TURN, a STUN/TURN *server* in the same library (the hub can run the studio's own), a mux mode that puts every peer on one UDP port, builds with MSVC/clang/gcc as plain C. 0.5 MB of source. |
| **Monocypher 4.0.3** (CC0-1.0 or BSD-2-Clause) | **Chosen** for X25519 and XChaCha20-Poly1305: one audited C file. SHA-256/HMAC stay ours (direct.cpp). |
| libdatachannel (MPL-2.0) | Adds DTLS + SCTP, so OpenSSL/mbedTLS + usrsctp come with it, and DTLS's certificate fingerprints still have to be bound to the studio by us. The link already has its own frames, answers and windows. Only worth it if a browser has to join peers directly (WebRTC data channels from the web UI). |
| iroh (MIT/Apache-2.0, Rust) | The best all-in-one (QUIC streams and datagrams, hole punching, relays, Ed25519 node ids), but a Rust toolchain in three CI builds and the Windows build on JAMES-MAIN, a tokio runtime inside REAPER's process (libtailscale's Go-runtime worry again), a C shim to write, and n0's public relays unless we host iroh-relay. The fallback if stage 2's reliable stream turns out too much. |
| quinn + our own | iroh without the parts we'd need. No. |
| libtailscale / tsnet | Still a tailnet login: not "without Tailscale". |

Licences (extension/third_party/README.md has the details): MPL-2.0 is file-level copyleft and names the GPL as a "Secondary License"
(section 3.3), so its files can be part of GPL-3.0-or-later StudioSync; no libjuice file carries the "Incompatible With Secondary Licenses"
notice (checked). libjuice's files stay MPL, unmodified, with their source and licence shipped. Monocypher is CC0/BSD-2.

**How peers find each other (the rendezvous).**
- **Signalling over the shared folder.** Each computer writes one small signed file per peer, `_band/nat/<from>-<to>.json` in the design
  (the spike: `<folder>/<from>-<to>.ssn`): kind (offer from the lower device id, answer from the other), ICE credentials and candidates,
  a fresh ephemeral key, the time; an answer carries the offer's ephemeral key back. Syncthing carries it (Syncthing doesn't need
  Tailscale: it has its own discovery and relays) and its modifiedBy says which computer wrote it. Cost: one Syncthing hop (~2-3 s) per
  connection set-up, never per message. Where some link already exists (the hub, a computer on both), the files can go as an `SSM1`
  message `nat` too, for sub-second set-up; the cloud copy could carry them for a studio whose Syncthing is slow (the signature holds there).
- **STUN (learning one's public address):** the studio hub runs libjuice's STUN/TURN server inside the extension when the owner opens a
  port on its router (as James's desktop already has UDP 40041 forwarded for the Tailscale Peer Relay); else a public list
  (stun.cloudflare.com:3478, stun.l.google.com:19302): free, and the operator sees each computer's public IP address and nothing else (no
  names, no content). A studio setting replaces the list.
- **TURN (a relay, for pairs no hole punch can join: symmetric NAT or blocked UDP at both ends):** the hub's own TURN, credentials made
  from the studio key with an expiry (libjuice's `juice_server_add_credentials` takes a lifetime). Everything through it is already sealed
  end to end: the relay sees sizes and timing only. No hosted relay by default: a hosted TURN charges per GB (one live-audio stream is
  ~60-115 MB an hour), so it's a studio setting (any standard TURN server). No path at all: Health says so, Syncthing carries everything.
- **Who runs it:** nobody new. No StudioSync server, no cost, nothing of the band's content reaches a third party.

**Authentication: never weaker than today.** Today a computer needs the studio secret (every frame's HMAC) *and* to be signed into the
studio's tailnet (its WireGuard key). The replacement needs the studio secret *and* that computer's own static X25519 key: the private half
never leaves the computer (a file in `band.home()`, readable by the user only), the public half goes in its `_band/devices/<user>.json` as
`nat = { pub }`, taken only from a file its own computer wrote (`trust.device_ok`, the same check the Tailscale names pass today). The
handshake is Noise KK's three Diffie-Hellmans (ee, es, se) mixed with the studio key as a pre-shared key: a stranger with the secret but not
the computer's key gets nowhere (tested: an impostor's datagrams are all refused), and fresh ephemeral keys give forward secrecy (a secret
or static key stolen later doesn't open what was recorded before). Someone taken out loses both: the secret is made again (lib/removal.lua)
and their devices file goes. The signalling file is HMAC'd with its own label (`StudioSync nat v1`), addressed to this computer, at most
120 s old; the link counts as up only once a datagram from the peer has opened (key confirmation), and each side says hello until both have.

**Encryption (what replaces WireGuard).** Every datagram: `"SSN1"`, a 64-bit counter, the payload sealed with XChaCha20-Poly1305 (a key per
direction, the counter as the nonce, the 12-byte header authenticated), 16-byte tag: 28 bytes added. A 64-packet replay window (as
WireGuard's) takes reordering and refuses replays. New ephemeral keys on every connection. Paths without Tailscale have ~1472 bytes of UDP
payload, so today's 1200-byte packets plus 28 fit, through TURN's 4-byte ChannelData too. Over Tailscale nothing changes (no second layer).
Before shipping: an outside review of the handshake against Noise KK + psk, or Noise-C (MIT) instead of our 40 lines.

**Running the link, live audio and hops over it (an address abstraction).**
- **One more UDP port:** libjuice's mux mode on UDP 47282 for every Tailscale-free peer (not 47281: rtaudio binds that on the Tailscale
  address, and a wildcard bind beside it behaves differently on each system).
- **A peer is a "way":** lib/direct.lua's peer strings stay `name:port` for Tailscale; a devices entry with no Tailscale name on the studio's
  network but a `nat.pub` becomes `nat:<device id>` (only while band.json `nat` is on). The native side keeps one NatLink per such peer.
- **Live audio and hops (UDP already):** each NatLink gets a synthetic `sockaddr_in` (an address from 192.0.2.0/24, TEST-NET, that never
  routes, with the link's index as the port). AOO keys its sinks and sources on addresses, so it doesn't notice; rtaudio's `send_fn`
  sends to a synthetic address through `nat_link_send` instead of `sendto`, and what a NatLink opens enters `rx_loop`'s path with that
  address as `from`. `addr_ok` becomes "a Tailscale address, or a synthetic one whose link is up" (the link's identity is the check). The
  SSL1/SSH1 tags stay as they are (a second, harmless check). hopnet.cpp rides on rtaudio's socket, so it follows for free.
- **The direct link (TCP: event files, messages, clock pings, streams with windows):** needs an ordered, reliable stream over datagrams:
  KCP (MIT, one C file) on the NatLink, and a loopback shim so direct.cpp's frames, answers and windows run unchanged: the sender
  connects to `127.0.0.1:<the shim's port for that peer>`, the receiving side's shim connects to the link's listener on 127.0.0.1 (a listener
  there only while `nat` is on; the HMAC stays the bar, as it is on loopback in the tests).
- **The web UI on phones** (`tailscale serve`, the Tailscale listener) stays Tailscale-only; so does a studio set to sync only through
  Tailscale (`tailscale_only`: the owner chose the tailnet).

**What breaks or changes.**
- **Firewall:** today TCP+UDP 47281 from 100.64.0.0/10 only. The new path needs UDP 47282 from any address (hole punching makes most
  traffic replies to our own sends, which Windows lets through, but a peer's first checks can arrive before ours and be dropped: the rule
  makes it reliable). Safety rests on the sealing: anything that doesn't open is dropped before it's parsed. A second rule in the same
  UAC prompt; macOS asks as today. A hub that runs STUN/TURN also needs its router's port forward.
- **Health:** a row per Tailscale-free peer: "direct (through both NATs)", "relayed by <hub>", or "no path", from
  `juice_get_selected_candidates` (host / srflx / prflx / relay); "public address found / not" (STUN); and a strict-NAT warning (two STUN
  servers giving different mapped ports: this computer needs a relay). The existing rejection reasons gain "not an opened link".
- **Privacy:** the signalling files hold each computer's LAN and public IP addresses, readable by the studio's members (today they see
  Tailscale names and 100.x addresses); the STUN operator sees the public address.

**Staged plan.**
0. **Spike (done, below).**
1. **Live audio first** behind band.json `nat` (off by default, owner and admins): libjuice + Monocypher in the extension's build
   (third_party build scripts), static keys in devices files, signalling over the shared folder, public STUN, synthetic addresses in
   rtaudio, the UDP 47282 rule, Health's row. Gate: an hour of live audio desktop <-> laptop with Tailscale off on one side.
2. **The direct link over it:** KCP + the loopback shim; events, messages, clock and streams unchanged above it.
3. **The hub as STUN/TURN** (the server inside the extension, credentials from the studio key), signalling over existing links for
   sub-second set-up, the strict-NAT check.
4. **Before it's on by default:** the handshake reviewed (or Noise-C), the signal parser and `nat_open` fuzzed (libjuice ships a fuzzer
   for its own STUN parser), ICE restarts when a computer changes network (Wi-Fi to tethering).

### The spike (extension/nat.cpp, nat.h, tests/nat_test.cpp, tests/build_nat_test.cmd)
- `nat.cpp` is the transport above: keys, the handshake (`nat_derive`), sealing (`nat_seal`/`nat_open`), the signed rendezvous message,
  and `NatLink` (one libjuice agent, the folder, hellos). It won't compile without `-DSTUDIOSYNC_NAT`; the shipped build doesn't list it.
  CI builds and runs `nat_test` as a test step of its own on macOS and Linux, after the shipped builds.
- `nat_test` (no arguments) on JAMES-MAIN, all passing: the crypto (both sides agree; a flipped byte, a changed counter, a replay, another
  studio's secret and an impostor without the computer's key are refused; an all-zero public key is refused; the signed message's
  signature, addressee and age), then libjuice's own STUN/TURN server on 127.0.0.1 as the rendezvous server and a temporary folder as the
  signalling channel: both ends up in ~0.5 s (any path) and ~0.15 s (only relayed candidates published, so the path goes through TURN),
  200/200 sealed datagrams each way, a captured datagram played again refused, an impostor never up, another studio's offer refused.
- **Two computers on different networks, real NATs (desktop at home, the laptop elsewhere: different public addresses):**
  `nat_test peer` on each, no Tailscale candidates published (`NAT_NO_TAILSCALE=1`), Google's public STUN, the folder copied both ways by
  scp every ~0.5 s (a stand-in for Syncthing). Up after 6.6-10.8 s (the copying and the two sides' start times), the chosen pair
  server-reflexive <-> server-reflexive (a hole punched through both NATs), 197 of 199 sealed pings answered, round trip median 87.6 ms
  (p95 97.7). The same run with Tailscale's candidates allowed chose the tailnet: median 88.6 ms; `tailscale ping`: 88 ms direct. So the
  punched path costs nothing over Tailscale direct.
- **Not tested:** symmetric NAT or carrier-grade NAT on either side (both NATs here punched cleanly), TURN across the internet (only on
  localhost), networks that block UDP, IPv6-only, long sessions, a computer changing network mid-session, Syncthing as the actual carrier
  of the signalling files, macOS and Linux other than CI's localhost run, and anything inside REAPER.
- **To ship (stage 1):** add libjuice and Monocypher to `extension/third_party/build_windows.cmd` / `build_unix.sh` (static, symbols
  hidden as AOO's), the keypair and devices-file field, the signalling files in lib/direct.lua, the synthetic addresses in rtaudio.cpp, the
  firewall rule and Health's row: roughly a week of work and a review, then the hour-long gate above.

## Fast first, lossless after (James)
Everything audio can arrive twice: a fast, light version over the link now, and the lossless file after, by the
durable path (Syncthing, or the link in the background). The lossless copy replaces the fast one in place, on the same
item and take, with no edit and no event, once its hash checks:
- a take streamed while recording: intervals go as Opus (light, hides loss); the FLAC/WAV take replaces it at stop;
- live audio and remote plug-in returns heard as Opus, prints and stems kept lossless;
- media arriving on a slow connection: a quick preview first, the real file behind it.
This is also the strongest reason to keep Syncthing (or something like it) after the link carries the live traffic:
it's the patient, lossless, store-and-forward half.

## Decisions (James, 2026-11-19)
- All the ideas below are in the plan.
- **The native extension is mandatory.** StudioSync installs it everywhere (installer, ReaPack, the studio folder's
  copy) and Health treats a missing or old extension as a problem to fix, not a mode. Lua-only fallbacks for the link
  are not built; Syncthing stays as the durable, lossless path underneath.
- **The hub must never be a single point of failure** (see 1).

## More big ideas (in the plan)
1. **A studio hub, with failover.** The best-placed online computer acts as the studio's hub: it relays for computers
   that are never online together, keeps a complete copy, renders prints and chained stages for everyone, and mixes
   everyone's live audio into one stream per listener (a band of five sends 4 streams each to one place instead of 20
   between them).
   - Elected, not fixed: every computer ranks the online ones the same way (a preferred hub the owner picks, e.g. the
     desktop, first; then by uptime, connection and CPU; ties by device id), so when the desktop goes offline the next
     one takes over within seconds, and hands back when it returns.
   - Nothing depends on it: peer to peer stays the baseline. With no hub (or mid-handover) everyone still talks
     directly and Syncthing still carries everything; the hub only makes things lighter and faster.
   - What it holds is never the only copy: it's a relay and a cache, so losing it loses nothing.
   - **Per song as well as per studio (James, 2026-11-19).** Each song can have its own hub: by default the computer of
     whoever shared the song with the studio (its "home", James), transferable from there to another member; the studio hub (and then the
     ranking, then the cloud copy) is the fallback when the song's hub is offline. Jobs split the same way: a song's
     snapshots, prints and live mix go to its hub, studio-wide jobs (update files, relaying) to the studio hub.
   - **The hub is someone's working REAPER (James).** Most of the time a person is recording and mixing in the hub's
     REAPER, so hub duties must never get in their way: they run off the audio thread and outside REAPER's main loop
     where they can (the extension), heavy ones (prints, bounces) only while that REAPER is idle or in a hidden background
     instance, with a CPU budget, and paused while it records. Health shows "you're this song's hub" and what it's doing;
     the person can hand the role on.
   - **First slice built (rt-hub, 2026-11-19; offline tests only, not run in REAPER yet):** `lib/hub.lua`, tests/test_0_60_rt_hub.lua.
     - **Election, pure:** inputs are what every computer already sees: the status files of every song (all songs' statuses are in
       every computer's listing; fresh = stamped or changed here within 45 s), each now carrying `hub = { since, link, off, studio, song }`
       (online since, direct link listening, handed on, roles held now); band.json `hub` (the owner's/admins' preferred studio hub, a trusted
       setting); `<song>/hub.json` (handovers) with session.json's `host` (who shared it).
       Studio hub: the preferred one when online (back to it once it's been on 30 s, at once if nobody holds it), else whoever holds it now,
       else the ranking (link listening, then online longest, then machine id, then name). Song hub: its home (the sharer, or whoever it was
       handed to: each handover counts only from the sharer, the home at the time, or the owner/an admin), same 30 s hand-back, else whoever
       holds it, else the studio hub if it has the song open, else the ranking among those in the song, else nobody (the cloud copy stands
       in: it already carries restore points both ways). Holding beats ranking, so a better-ranked newcomer or a flickering preferred
       computer never flaps the role; two holders at once settle on the better-ranked one everywhere. Handed on (Health) = no hub role here.
     - **Visible:** Health row "Hub: X (why); this song: Y (why)", "You're this song's hub: it keeps the song's restore points (last N min
       ago)", Hand it on / Be a hub again. Settings > Studio > Hub: preferred studio hub (owner/admins, `groups.set_hub`) and the open
       song's hub (its sharer, its hub now, the owner or an admin hand it on for good in hub.json).
     - **First job: the song's restore points** ("hub snapshot", `recall.save`, not kept for good; trim treats them as minor so they don't
       hold history back). Chosen over relaying: Syncthing already stores and forwards through whichever computer is online, and the
       cloud copy covers nobody online; restore points had no owner (everyone saved end-of-session ones, nobody mid-session). At most one
       per room every 30 min, only when there are changes, the half hour counted from the room's newest hub snapshot whoever made it (so a
       new hub after failover doesn't double up), and only while that REAPER is stopped (any tab), untouched for a minute and not catching
       up, and never closer than 500x the last one's duration (0.2% CPU budget). Statuses are read a few songs per tick (4 ms) every 10 s,
       one scan shared by every Live sync tab. The capture itself is still on the main loop: that's why it waits for idle.
     - **Not yet:** failover in seconds (a hub that vanishes is noticed when its status goes stale, up to ~45 s; the link's heartbeats could
       cut that), the handover file's `by` checked against Syncthing's modifiedBy (now against the roles only: it moves where restore points
       are kept, never data), snapshots taken in the extension or a background instance, the hub's other jobs (prints, relaying, live mix).
   - **Second slice built (rt-hub 2, 2026-11-19; offline tests only, not run in REAPER yet):** `lib/hub.lua`, `direct.reach`,
     `trust.own_file_ok`; tests/test_0_60_rt_hub.lua, tests/test_0_60_rt_hub_trust.lua.
     - **Failover in seconds:** the direct link pings each computer here every second; `direct.reach` gives each person's last answer, and
       `hub.link_watch` counts out one the link has reached before that hasn't answered for 12 s (one failed ping plus the extension's 10 s
       wait before it retries, so a single dropped ping never moves the role). Counted out, it's not a candidate though its status file is
       still fresh, so the next computer takes over at the next tick (~15 s, was up to ~45 s + a 10 s scan). One the link never reached, or
       a computer in another song (the link only covers this room), is left to the status files as before. Found again, its hand-back counts
       from then (`back`), not from when its REAPER started, so a computer flickering on the link doesn't flap the role.
     - **Handovers can't be forged:** each person's handovers are their own file, `<song>/hub/<person>.json` (replacing the one hub.json,
       which said who handed it on in its own words), and count only when Syncthing's modifiedBy says that person's own computer wrote it:
       the one their devices file names, itself checked as written by that computer (`trust.device_ok`). session.json's `host` (the chain's
       start) is checked the same way. No new step for anyone: every computer already writes its own devices file. Not checked yet waits;
       set aside is said once in the log, in Health and under Settings > Studio > Hub. A handover made with the first slice's hub.json is
       no longer read: hand it on again.
     - **Guests aren't hubs:** `removal.guest_names` (the guest marks someone in charge wrote) are dropped from the candidates on every
       computer alike, and aren't offered as the preferred hub or a song's hub in Settings.
     - **Visible:** Health's hub row adds "replaced within seconds (direct link)" or "within a minute", who the link lost, "You're a guest
       here", and a set-aside handover; Settings > Studio > Hub says the same rules.
     - **Still not yet:** the studio hub in another song than yours is still noticed by its status file (the link's peers are per room);
       snapshots in the extension or a background instance; prints, relaying, live mix at the hub.
2. **Shared CPU.** The remote plug-in mechanism (4b) also works for plug-ins you DO have: freeze or offload a heavy
   track to whichever computer is idle.
   - **First version built (2026-11-19; offline tests only, not run in REAPER yet):** `lib/hops.lua` (offload, offload_pick, hold_chain,
     keep_offload), the action `StudioSync - Offload track FX.lua` and a button under the panel's "Selected tracks play" row (Offload its
     effects / Bring its effects back from Bo), tests/test_0_60_rt_sharedcpu.lua.
     - **Picks:** every computer's status now carries `cpu` (0-100 in tens: typeperf on Windows, load average over cores on macOS/Linux, read in
       the background every 20 s; an audio dropout in the last minute reads 100). Of the bandmates on the direct link: not a guest, not
       recording, has every plug-in of the chain (the shared plug-in lists), at most 75% busy, the least busy (then by name). A StudioSync
       without `cpu` can't host a chain and is passed over. Refused: the master, an instrument in the chain (a hop carries audio, not MIDI),
       this computer's own FX on the track (translations, drum maps, a live hop), a track already hopping.
     - **Moves:** one Hop at the end of the track's chain (dry when late, never silence) and the song's FX held off here: each one's BYPASS
       line as the band has it goes into the track's `band_fx_held` first, and mirror sends that line in its place (`track_head_parts`), so
       the band's chain never changes: it's this computer's choice. The host gets the whole chain (`chain` in the serve request) on its
       hidden track, Hop X, copies, Hop Y; their knobs and bypass follow the song's, their latencies summed for the extension. A print waits
       while its track's FX are held (it would miss them). Health: "Guitar's effects run on Bo's computer: round trip, needs, lost, late blocks".
     - **Comes back** (the chain on again exactly as it was, said in the log and a Health line for 5 min): the host starts recording (its
       status), stops hosting or goes for 10 s (20 s grace at the start), more than 8 late blocks in 10 s, the band changes the chain's
       plug-ins (the same plug-ins landing again only puts the Hop and the hold back), Live sync stopping, or the same button.
     - **Limits:** only the front tab's offloads are watched (as hops are); stereo; a chain with a restless plug-in may resend its unchanged
       chain once when held; a crash leaves the chain held until Live sync runs again (then it reconnects or comes back).
     - **To check in REAPER (desktop offloads to laptop):** Live sync on both; laptop idle; select a heavy track on the desktop and Offload
       its effects: Health on the desktop names the laptop, its FX bypassed only here (the laptop's copy unchanged, nothing sent), the
       laptop's hidden track (Show all tracks) has the chain; playback in time with a dry copy; the desktop's CPU meter drops; start recording
       on the laptop: back at once, the chain exactly as before; pull the laptop's network: back within ~10 s; Bring its effects back by hand.
     - **Run in REAPER (2026-11-19, 0.59.49.52):** XT Rec A (Tone Generator) offloaded desktop -> laptop, stopped and playing; it comes back
       on late blocks counted once the hop has run 3 s (and 3 s after a play start, stop or seek: the latency pre-roll), or more than 5% of its
       audio not back in time in 10 s (that link: 0.3-0.7% steadily, a 150-200 ms stall now and then). Bring back: the chain exactly as it was.
3. **Follow a bandmate.** See exactly what they see: their view, cursor, selection and open editor, live.
   - **Built (rt-follow, 2026-11-19; offline tests only, not run in REAPER yet):** `lib/follow.lua`, tests/test_0_60_rt_follow.lua.
     - **What goes:** while someone follows you (their status says `follow`, as before), Live sync's tick sends a `view` link message at most
       5 times a second, and at least once a second while it applies: the arrange view, edit cursor, play cursor while playing, the selected
       tracks' and items' oids (16 each), and words for the follower ("Bass selected; 'Riff' on Bass; editing the MIDI of 'Riff' on Bass").
       Nobody following: nothing is built or sent.
     - **What the follower does:** the tab in front takes their view (start/end), their edit cursor (their play cursor while they play and
       you don't), and their selection (tracks scrolled into view, action 40913); your own selection comes back when you stop following.
       Which editor they have open shows as words under the Following button's card ("Bo: ... editing the MIDI of 'Riff' on Bass"), not
       opened here. A scroll or zoom of yours (the view more than 1% off where following left it) pauses it: **Resume** beside Following,
       and on the web Play page. Play/stop and mix following stay as they were (`follow` ExtState).
     - **Web Play page:** "Follow a bandmate" (Nobody or anyone here), Resume while paused, and the same words (`play` topic: mate, paused,
       seen; actions `mate`, `resume`, only for someone this room has).
     - **Fallback:** a bandmate the link doesn't reach (older extension, no Tailscale) is followed from their status file as before
       (presence.follow, a few seconds behind); it steps aside while link views are fresh (3 s) or following is paused.
     - **Not yet:** the vertical scroll itself (REAPER has no API for it without js_ReaScriptAPI's window calls: their selected tracks are
       scrolled into view instead); a scroll of yours while playing (REAPER's own scrolling moves the view then, so only a stopped one
       pauses); opening their editor here.
4. **Listen from anywhere.** A link from the studio to a browser page (phone, client, a bandmate away from REAPER) that
   plays the live session or the latest mix, peer to peer over Tailscale.
5. **Shared controllers.** One person's control surface or MIDI controller moving faders and knobs in everyone's
   session (through the live layer and claims).
   - **Built (rt-controllers, 2026-11-19; offline tests only, not run in REAPER yet):** `lib/controllers.lua`, tests/test_0_60_rt_controllers.lua.
     - **What goes:** the tab in front reads every mirrored track's volume, pan and mute each Live sync tick, and the plug-in knob REAPER says
       was last touched (`GetTouchedOrFocusedFX`, and any touched in the last 3 s), so the mouse, a control surface, a MIDI-learned controller
       and OSC all count. A change since the last reading is yours: at the tick's end what StudioSync itself wrote (a receive pass, a put-back)
       is read again (`controllers.settle`, beside Live sync's took_in), so the band's changes never go back out. A `ctl` link message carries
       each moving control's latest value at most 20 times a second, and "let go" 0.5 s after it last moved. Plug-ins go by their place in
       the band's chain (this computer's translations, drum maps and live hops don't count), only track FX outside containers.
     - **Only what you may change:** sync.authority's rule and the maker's, as mirror.watch judges a change; nothing with Hold my changes on,
       nor faders and pan under Local mixing (mute still goes, as it does in the mirror). Each receiver judges the sender again and refuses
       (counted in Health, said once) what isn't theirs; not shown either on a track writing automation here (Touch, Latch, Write: nothing
       streamed lands in an envelope; the sender's own automation arrives as the mirror's change, and their moves are labelled "writing
       automation"), over an unsent change of yours, or your own faders and pan under Local mixing.
     - **A preview the mirror confirms:** while a move is shown and until the band's change for that track (or its plug-ins) lands (its
       revision moves past the last move shown), mirror.watch leaves the object alone (`mirror.previewing`): neither sent as yours nor put
       back. Nothing from the band within 20 s (a control surface's change may wait for the 10 s look): the value before it comes back.
     - **Holds:** whoever started moving a control first holds it until they let go (1.5 s without a move if the let-go is lost); a move of
       yours on it meanwhile goes back to theirs, said once ("Bo has Bass pan"). Two starting together: the earlier start on the shared clock,
       then the name, the same everywhere. Health: "Shared controllers: Bo moving Bass volume; N moves sent, N shown".
     - **Settings > Studio > Direct link:** Shared controllers (owner and admins, band.json `shared_controllers`, on unless false). Off: nothing
       is read or sent, and moves that arrive aren't shown.
     - **Not streamed:** solo (each person's own), the master (its fader is each listener's level), width, sends, take FX, plug-ins in a
       container, a knob an envelope plays (while playing) or a modulator moves. Cost with nothing moving: six reads a track a tick (the look and
       the settle) in the tab in front, one last-touched read, nothing sent; nothing at all with nobody here or in a tab behind.
     - **To check in REAPER (desktop + laptop):** Live sync on both, the same song; drag a fader on the desktop: the laptop's moves along
       within ~50-100 ms, and the normal sync's change lands after the drop (Health: moves sent / shown). On the laptop, map a MIDI CC to a
       track's volume and an FX knob (MIDI learn) and drive it from the UR22mkII's looped MIDI out (a CC sweep from a ReaControlMIDI or a
       script): the desktop follows both. Both grab one fader: the first holds it, the other's springs back with "X has ..." in the log.
       Claim a track on the laptop: the desktop's moves on it don't go (and nothing changes on the laptop). Touch automation on the laptop's
       track while the desktop moves it: the laptop's envelope stays untouched. Check D_VOL doesn't move with a playing volume envelope (if it
       does, playback would stream: then read only while stopped or with no envelope). Settings > Studio: turn it off, moves stop at once.
6. **Joining without Syncthing's device approval step.** The link can carry the invite and the first copy of the song,
   so a new member is in within seconds.
   - **Design (rt, 2026-11-19).** Today: the joiner pastes a join code (services.join_band: the studio's folder added, paired with the
     inviter as introducer), the inviter's panel shows "Let them in", and only that press adds the device and shares the folder; the others
     meet the joiner later from its own devices file (removal.known). The press is the gate, because a join code is just a device id anyone can
     send. To drop the press, the code has to carry the owner's or an admin's consent, unforgeably:
     - **The token** (`studiosync-invite:<studio>:<id>:<role>:<ends>:<host>:<device>:<sig>:<name>`): what it grants (studio folder id, member or
       guest, an end 2 days on, an id of 128 random bits) and where to ask (the maker's Tailscale name and Syncthing device id), signed with
       Ed25519 (extension 1.0.9's StudioSync_Sign) by the making computer's own invitation key, `~/.studiosync/invite-key` beside the update key
       and as private (its own key: admins invite too, and the update key only signs code). The signature is over every field
       (`"StudioSync invite v1\n"` + the fields, one a line), so a holder can't turn a member's into a guest's, move its end or point it elsewhere.
     - **The record** `_band/joins/<id>.json`: { id, studio, role, made, ends, by, dev, key = the maker's public key }, never the signature (the
       bearer part). Believed only from an owner's or admin's computer as Syncthing says (trust.from_manager_file), as guest invitations are.
       Used: rewritten naming the computer let in ({ device, name, at }). Revoked: deleted (Settings > Studio > Direct link > Invitations).
     - **Who checks:** only the computer that made it (its key in the record): one place holds "used", so one use is one use, with no race
       between computers. It also has to be someone who lets people in at the moment of use (made as an admin and demoted since: refused).
     - **The ask:** the joiner's StudioSync joins as today (the folder, the pairing with the maker as introducer), then sends `join`
       { token, device, name, reply = its Tailscale name } over the link to `<host>:47281` on a channel of its own (`studiosync-join`, under a
       public key: the joiner has none of the studio's secrets yet, and the signed token is what lets it in), every 10 s until it's in. The
       maker listens on that channel only while it has open invitations. It checks: a record there, from a manager, made under its own key; the
       fields matching it; the signature; not run out (and an end at most 7 days after `made`); not used by another computer; nobody taken out
       since it was made (a removal mark naming the device). Then it lets the computer in exactly as Let them in does (tools.let_in: the device
       added and the folder shared, the roles written out again from here so the joiner's first look believes them, a guest's mark and project
       list, a restore point "before X joined"), marks it used (ExtState and record), and logs it. The same computer asking again gets only the
       welcome; any other is refused, and Syncthing's config is never touched for a refused ask.
     - **The others in the studio:** the joiner meets them through the maker as introducer (as today); when it asks their Syncthing, they add
       it without a click if a used record from a manager names it (removal.admitted beside removal.known, in removal.tick's settle_peers,
       within a week of use and never past a removal mark). That reaches them before the joiner's own devices file does.
     - **The welcome (the link's half of "the first copy"):** keyed with the token's signature (only the joiner and the maker know it), to the
       joiner's Tailscale name on the studio's network: the studio's name, who's in charge and the projects it will see (a guest's list
       respected), never the studio's secrets (they arrive in Syncthing's band.json, which the trust checks cover). The joiner's Studios page
       says "Let in by the invitation" at once instead of "Waiting to be let in".
     - **Safe by default, no new steps:** invitations run out (2 days), let one computer in, are revocable; a device without a valid one is never
       added by this; a studio's other rules stay (removal marks, guests' time and project lists, trust's held first look). Nothing is asked of
       anyone: Invite a collaborator puts the token where the join code was, Paste join code takes it, and where the link can't hear an ask
       (no extension, Tailscale off or another network, the direct setting off, no firewall rule on Windows) the message has today's join code
       and Let them in, unchanged. The installer lines stay as they are (they pair, and Let them in follows).
   - **Built (rt, 2026-11-19; offline tests only, not run in REAPER or on real Syncthing yet):** `lib/joins.lua` (token, check, make, the
     ask and welcome, tick, admitted, revoke, Settings rows); `lib/services.lua` (invite_text's `token`, parse_join takes one); `lib/tools.lua`
     (show_invite makes one, let_in shared and says whether it worked, join_requests runs joins.tick); `lib/page_groups.lua` (Paste join code
     sends the ask; the waiting card says asking / let in); `lib/removal.lua` (admitted, out_since; settle_peers); `lib/direct.lua` (the
     Invitations rows in Settings > Studio > Direct link); `StudioSync - Autostart.lua` (joins.tick every 2 s). No extension change.
     Tests: `tests/test_0_60_rt_joins.lua` (the token and every field under the signature; the check: another key, run out, too long, used, the
     same computer again; the whole ask against a stand-in Syncthing command line: device added and folder shared only for a valid one, nothing
     on a replay, a revoked, run-out or forged one, a record a member wrote, someone no longer in charge or taken out since, and a failed share
     left unused; the welcome's key and contents; the joiner's ask, resend, welcome and run-out; admitted).
   - **Not yet:** opening a song before Syncthing has its files. A copy written into the shared folder from the link would carry this computer's
     modifiedBy (band.json's and session.json's are trust-checked), so the first copy stays Syncthing's; the songs' files come smallest first as
     soon as the device is shared. The fix is the snapshot work ("Project files: snapshots plus changes"): a song's snapshot over the link into
     the inbox, opened from there. Also: a Windows joiner without the firewall rule doesn't hear the welcome (it's let in all the same, and the
     Studios page follows band.json's arrival); the installer lines don't carry the token yet (a new computer still needs Let them in); the
     public ask channel lets anyone on the tailnet put asks in the extension's shared 512-message list while invitations are open (they're
     refused, but crowd it).
7. **Everyone records their own part in full quality during a jam.** While playing live together (heard as Opus or
   intervals), each computer records its own input locally, and the lossless takes replace the live ones afterwards,
   lined up by the shared clock (the "double-ender" way podcasts are made). The jam becomes a real multitrack session.
8. **Latency calibration per person.** A one-time loopback measurement of each computer's audio interface, so parts
   recorded against a bandmate's stream land exactly on the grid.
9. **"Bo is editing this" before you touch it.** Live claims shown on the track/item as soon as someone starts
   editing, so clashes mostly don't happen.
   - **Built (rt-follow, 2026-11-19; offline tests only, not run in REAPER yet):** `lib/follow.lua`, tests/test_0_60_rt_follow.lua.
     - **What counts as editing** (looked at every 0.1 s, only with someone here): the item in the MIDI editor, the track or take whose
       plug-in window has focus (an editor left open counts for 2 minutes after it opened or you last changed something), else what's
       selected (items first, then tracks) while a change is in progress: the project changed in the last 2 s (your changes only: Live
       sync's own are taken in at the end of each tick) or the mouse held 0.3 s (a drag, before the drop changes anything).
     - **What goes:** an `editing` link message at once when that changes ({ user, o = oids, w = words }), again each second while it lasts,
       and an empty one when you move on; the others drop it after 3 s without word.
     - **What shows:** a `[editing: Bo]` region over each item, in Bo's colour (this computer's only: band.is_local_mark, so it never
       reaches the band's markers or an event file); the track tinted like an edit hold (people.paint's `editing` map, only with Colour
       parity off, repainted at once rather than at the next pass); "Bo is editing 'Riff' on Bass" on Bo's card in the panel's Who's here;
       the same line under the web Project page's view (dawcur's people `ed`, within a second).
     - **The claims model, not a new one:** it rides the edit holds' oid -> user map that people.paint already shows, and the link's
       message path that claims and presence use; it never enters sync.authority or presence.holder, so it blocks nobody. Claims and edit
       holds do what they did.
     - **Not yet:** a track-only edit (plug-in window, selected tracks) has no timeline mark with Colour parity on (the panel and web line
       say it); an envelope or automation item being edited counts as its track only through selection.
10. **Timeline comments.** Notes pinned to a bar or region, live, like comments in a shared document.
11. **Personal monitor mixes.** Each person sets their own mix of everyone's live audio (more click, less guitar)
    without touching the song's mix.
12. **Song history playback.** Scrub through how the song evolved, change by change, and restore any point.
13. More ideas get added here as the steps land.

Latency calibration (8) is mostly automatic: REAPER already compensates recording for the driver's reported latency on
each computer, and StudioSync compensates the network part continuously from the shared clock. The loopback test is an
optional precision step for drivers that misreport by a few ms.
- **Built (rt-calibrate, 2026-11-19; offline tests only, not run in REAPER yet):** `lib/calibrate.lua`, tests/test_0_60_rt_calibrate.lua.
  - **Measure my latency** (Settings > Advanced > Recording latency; Health's line opens it): with an output looped to an input (a cable,
    or a mic held to a speaker) a scratch project tab (no sync runs on it) plays three 512-sample noise bursts through the master's outputs
    and records them on the chosen input, unmonitored, with the metronome, pre-roll and auto-punch off for the run; then the tab, its
    tracks and every file it made go, and those are put back. Each burst is found by normalised cross-correlation (gain, polarity, clipping
    and noise don't move it; three must agree within 4 samples and clear a 0.2 score, or it says why). How late they land, REAPER's own
    compensation included, is the driver's misreport; shown in samples and ms beside the driver's reported in/out latency and the round trip.
  - **The fix is REAPER's own:** Correct it sets Preferences > Audio > Recording, Input manual offset (`adjrecmanlatin`, via SWS) to the
    offset then plus the lateness (verified on a ToneX, reaper skill F-0039); Put back restores what it was before the first correction.
    Nothing changes without the button; StudioSync's placement isn't needed as REAPER has the setting.
  - **Per computer** (ExtState): when, the result, the driver's numbers, the device/rate/buffer; Health says when it was last measured, the
    correction in use, and "measure again" once the device, rate or buffer differ.
  - **Not yet:** a take's streamed placeholder (lib/streams.lua) is the raw file, uncompensated (the real take replaces it); the output
    manual offset isn't read; whether REAPER takes an SWS-set offset without reopening the audio device is to be checked.
- **Built (rt-calibrate per interface, 2026-11-19; offline tests only, not run in REAPER yet):** found in REAPER on the laptop that the ToneX
  needed +203 samples and the UR22mkII -8 (4.4 ms early with 203, on time with -8: REAPER takes an SWS-set offset live), that REAPER keeps
  one offset for every interface, and that it doesn't save an SWS-set offset to reaper.ini on quit. So (replacing Correct it / Put back):
  - A measurement's offset (REAPER's then + the lateness) is kept per interface, per computer (ExtState `latency offsets`), keyed by
    `IDENT_IN` + sample rate (the offset is in samples and converters change with the rate; the buffer moves too often and most misreports
    are fixed, so it's noted, not keyed: Health says "worth measuring again" at another buffer), and set in REAPER right away.
  - `cal.tick` (Autostart's 2 s loop and every Live sync tick, once a second at most) sets REAPER's input offset to the kept one at each
    start and when the device changes, one log line when it does; never for an interface never measured; a value typed in Preferences
    after measuring is adopted as that interface's (never fought). Re-applied at each start, so REAPER not saving it doesn't matter.
  - Health: "Recording latency: UR22mkII -8 samples (measured Nov 19), applied"; yellow with the number to type when kept but not in
    REAPER (no SWS). Settings > Advanced lists the measured interfaces with Forget (the one in use goes back to REAPER's value before
    the first measurement); Measure is for the one in use. Tests: keying, choosing, adoption, never-measured, two scripts at once, no SWS.

## A new interface: web UI in a REAPER docker and in the browser (James)
Like Helgobox's move away from REAPER's own widgets, now that the extension is mandatory:
- The extension opens a dockable REAPER window holding an embedded web view (WebView2 on Windows 11, WKWebView on
  macOS, WebKitGTK on Linux), and the whole StudioSync interface is HTML/JS inside it.
- The extension also serves the same pages over Tailscale: the web interface on a phone or another computer is the
  same UI.
- The web view has WebRTC, so step 5's video calls and screen share can live inside REAPER's docker.
- The engine stays Lua; the UI talks to it through the extension (a local message channel). The ReaImGui panel stays
  until the web UI reaches parity, moved page by page behind a setting.
- Risks: a large rewrite; WebKitGTK availability on Linux (and in Flatpak REAPER); keeping keyboard focus and
  REAPER's shortcuts working with a web view docked.

### First slice built (rt-webui, 2026-11-19: in a browser, no downloads; not run in REAPER yet)
- **Server:** `extension/webui.cpp/.h`, in the same DLL/dylib/so. Two ways in, one set of pages:
  - **This computer:** its own listener on `127.0.0.1:47281` (the link's port number; loopback needs no firewall rule). No token, but
    the Host header must be `127.0.0.1:<port>` or `localhost:<port>` (a site pointing its own name at 127.0.0.1 gets nothing).
  - **The studio's devices (a phone on Tailscale):** the direct link's listener (Tailscale address, port 47281) hands any connection
    whose first bytes are `GET ` or `POST` to the web UI (`direct_set_http_handler`; link frames start `SS`), so the one firewall rule
    James OK'd covers it. Only while the link listens (rule there, Tailscale up). These need the studio's web token: the first 16 bytes
    of HMAC-SHA256(studio secret, "StudioSync web UI v1") in hex, given once as `?t=`, then an HttpOnly SameSite=Strict cookie (the
    answer redirects to the same page without it). A re-keyed studio (someone taken out) gets a new token; no secret, no outside access.
  - Every POST needs `X-StudioSync: 1` and a matching Origin when one is sent (a form on another site can't). Files only from
    `lib/webui/` (letters, digits, `.-_/`, no dot-led segment, no Windows device names, known types only); nothing is ever run.
    Answers carry a CSP allowing only the pages' own files, no-referrer and nosniff; pages put bandmates' text in as text, never HTML.
  - API: `GET /api/state` (snapshot), `GET /api/events` (Server-Sent Events: the snapshot now and on every change; a comment every
    15 s), `POST /api/action` (a JSON object, queued for Lua, 64 at most). Snapshot: `{ ver, engine, topics = { presence, chat } }`;
    `engine` is false once Live sync hasn't asked for 5 s (the pages say "Live sync isn't running").
  - A thread per connection, 16 at most (an open event stream holds one); stopped and waited for at unload and REAPER's exit.
- **ReaScript (Lua bridge):** `StudioSync_WebUIStart(folder, secret, port)`, `StudioSync_WebUIPublish(topic, json)`,
  `StudioSync_WebUIPoll()` (the oldest action, consumed), `StudioSync_WebUIStatus()` (`listening, bind, port, error, token, clients,
  served, refused`).
- **Lua:** `lib/webui.lua`; Live sync's only change is `band.try("webui.tick", ...)` after `direct.live_tick`. The tab in front publishes
  `presence` (you first, then who's here from `presence.peers`: playing, recording, armed tracks, real time / time-sync, on the call;
  driver and mode, and claims from `sync.authority`: tracks, regions, time spans) every second and the project's chat (`page_chat.read`,
  the "This project" scope, the newest 100) every 2 s, each only when it changed. A chat send from a page goes through
  `page_chat.post` (file, link message, phone alert, API event: the same store as the panel's). Bandmates' link chat messages are given
  to the Chat page's store through Live sync's own handlers (a second reader of the link's messages would steal presence and cues).
- **Pages:** `lib/webui/index.html`, `style.css`, `app.js`: Here (people, claims) and Chat, mobile-first, light/dark from the system
  with a toggle, no framework or CDN. Shipped by make_index.py and signed with the rest (`lib/webui` in sign_release.py and
  fromfolder's SHIPPED).
- **Panel:** Chat page, **Web UI** (opens `http://127.0.0.1:47281/` in the browser) and **Copy phone link**
  (`http://<this computer's Tailscale name>:47281/?t=<token>`; says why not when the link isn't listening).
- **Tests:** `tests/webui_test.cpp` (`tests/build_webui_test.cmd`, and in CI beside direct_test): parsing, the path rule, the token,
  who gets in, then live on loopback and through the link's port (token, cookie, POST header, actions, state, the event stream, the
  link's own refusal unharmed). `tests/test_0_60_rt_webui.lua`: lib/webui.lua's pure parts and its tick against a stand-in extension.
- **Limits for now:** one studio at a time (the tab in front's); chat is the project scope only; the phone acts as this computer's
  user (whoever has the token is in the studio); the driver comes from driver.json only (not the session's host fallback).

### Docked view built (rt-dock, 2026-11-19: links and runs headless; not run in REAPER yet)
- **Window:** `extension/webui_dock.cpp/.h` (+ `webui_dock_mac.mm`). A REAPER window "StudioSync" with a web view on
  `http://127.0.0.1:<port>/?host=docked|floating`; the server stays the only channel to the engine. Docked with `DockWindowAddEx`
  (ident `studiosync_webui`: REAPER remembers the docker and the place); the page's **Dock / Undock** button makes the window again the
  other way; the floating size and place in ExtState `web ui rect`, docked or not in `web ui docked`. Action **"StudioSync: Web UI
  (docked)"** (toggle, ticked while showing; a docker tab behind another is brought forward), in View after StudioSync, and
  `reaper.StudioSync_WebUIDock(mode)` (1 open, 0 close, -1 toggle -> 1/0/-1; why in ExtState `web ui dock error`). Closed at `atexit`
  and unload, before the server. Started by the action itself when nothing has yet (the folder lib/webui.lua notes in `web ui folder`,
  no secret: this computer only, until Live sync sets the token).
- **Windows:** WebView2 SDK 1.0.4314.35 from nuget.org (BSD-style, `extension/third_party/README.md`), the static loader (no extra DLL),
  user-data folder `<resource path>/Data/StudioSync/WebView2`. No runtime: says so and offers the browser. Browser shortcuts, the
  status bar and zoom off.
- **macOS:** WKWebView in the SWELL window (WebKit's own data store; a separate one needs macOS 14). **Linux:** WebKitGTK 4.1 (or 4.0),
  loaded at run time, embedded the way REAPER hosts Linux plug-in windows: `SWELL_ExtendedAPI("LOAD_GTK")` starts GTK in REAPER
  (SWELL passes GTK's windows their events), `SWELL_CreateXBridgeWindow` gives a real X window at the docker's place (moved and
  re-parented with it), a GtkPlug in that holds the view. A click in the view gives the bridge SWELL's focus, and SWELL sends the window's
  keys to it; elsewhere REAPER keeps its keys. Not installed (or Flatpak): says so and offers the browser, as with no WebView2. No WebRTC in
  Ubuntu's WebKitGTK (2.52), so video calls there offer the browser (call.js already does).
- **Keys:** the view has REAPER's keys while focused, so `app.js` posts each one it doesn't use (`key:<vk>:<mods>`; outside a field all
  but Tab and Enter on a button; in a field only non-editing Ctrl/Cmd/Alt combinations and F-keys; Esc leaves the field) and the
  extension runs it through the main section (`kbd_translateAccelerator`). macOS: the accelerator hook gives the view its keys first.
- **Safety:** only the pages' origin in the view; clicked http(s) links and new windows go to the browser; messages only from the
  pages' origin, and only keys and Dock / Undock.
- **Panel:** the Chat page's **Web UI** opens the docked view (Shift-click, an older extension, or no view here: the browser, with the
  reason logged). **Pages:** the Dock / Undock button (only inside the view) and a compact layout under 320 px.
- **Tests:** `tests/webui_dock_test.cpp` (`tests/build_webui_dock_test.cmd`; pure parts in the Mac and Linux CI jobs): port, address,
  user-data folder, origin rule, key messages; on Windows the view made in a hidden window with a fresh folder and loading the pages
  from the server. `tests/test_0_60_rt_dock.lua`: the panel button's choices and a link check of lib/webui.

### Song page built: shared DAW view stage 1 and song history (rt-dawview, 2026-11-19; offline tests and a stand-in server only, not run in REAPER yet)
- **Model:** `lib/dawview.lua`, from the tab in front, only while a page has the Song page open (the page says so every 10 s, an action
  `{topic:"daw", want}`; 30 s grace). Topics: `daw` (tracks: name, colour, folder depth, mute/solo; markers and regions; bar times and time
  signatures; tempo; grid; whether you may play), `dawc<k>` (items of 4 tracks each: position, length, colour, name, waveform as one character
  per column, 0-63 of full scale, 10 a second up to 600, from GetMediaItemTake_Peaks at twice that and halved by maximum; MIDI as notes in ms),
  `dawcur` (play cursor with its rate, your edit cursor and view, bandmates' cursors and views), `dawhist` (History only). The project is read
  again only when REAPER's change count moves (and every 10 s); only a chunk whose fingerprint moved is encoded and sent; peaks read within
  6 ms a tick and kept per take; fixed lanes show only the lanes that play; this computer's own tracks, stem prints and hidden tracks left out.
- **Server:** the event stream sends only the topics that changed after its first snapshot (`"delta":true`; `/api/state` is still everything),
  so a cursor moving doesn't resend the song. Needs the next extension build; with 1.0.13 every event is still the whole snapshot (works, heavier).
- **Payload** (test, 40 tracks / 400 items of 20 s, every fifth track MIDI): 173 KB for the whole song (header 2.8 KB, chunks 10.6-18.7 KB,
  cursors 0.2 KB); moving one item resends 18.7 KB (its chunk).
- **Cursors and follow:** while someone's Song page is open, bandmates put their view and edit cursor in their status (`dawview` flag, as when
  followed). Follow: nobody, the play cursor (pages), this REAPER, or a bandmate.
- **History:** changes from recall.lua's own cache (recall.warm a little each tick, only while History shows; built every 10 s) as dots on
  their track at their position, coloured by who; notes at their spot; saved versions on a strip of the song's life. Picking a version shows
  what changed since the one before; **Restore this** hands it to the panel (`band.panel_do "restore <file>"`): the Restore page opens with that
  version's row open and its usual buttons, which ask as ever. Nothing is restored from the page.
- **Play/Stop together:** `together.go` (moved out of page_play, the panel uses it too); from the edit cursor with a bar's count-in. Refused in a
  driver's room for anyone but the driver (admins' room: driver and admins).
- **Pages:** `lib/webui/daw.js`, `daw.css` (the Song tab is made by daw.js; index.html links the two, app.js dispatches `ss-state`). Canvas,
  drawn into an offscreen layer when the song or view changes, cursors on top each frame while playing. Drag to pan, pinch or Ctrl/trackpad-pinch
  wheel to zoom, Shift+wheel sideways, double-tap to fit. Narrow docker and phone layouts.
- **Tests:** `tests/test_0_60_rt_dawview.lua`; `tests/webui_test.cpp` checks the delta events.
- **Check in REAPER:** open http://127.0.0.1:47281/ and the docked view, Song tab, on a real song: tracks, colours, folders, waveforms, MIDI,
  markers/regions and bar numbers match REAPER; the play cursor runs with REAPER's; editing an item updates it within a second; Follow This
  REAPER tracks the arrange view; a bandmate's cursor shows once they run this build; History dots and versions; Restore this opens the panel's
  Restore page on that version; Play/Stop together start everyone; the tick cost with the page open and closed (tests/reaper/rt_perf.lua).

### Project page edits built: shared DAW view stage 2 (rt-dawedit, 2026-11-19; offline tests and a stand-in server only, not run in REAPER yet)
- **Edits:** select an item (click, or tap on a phone), drag it to move it (to another track too), drag an edge to trim it; Split at the edit
  cursor (the play cursor while playing, as REAPER's S), Mute/Unmute, a colour or No colour; + Marker at the cursor, + Region over the selected
  item (else a bar from the cursor), drag a marker or a whole region to move it, Rename. Drags snap to the project's grid while REAPER's snapping
  is on (the header's `snap`); Live sync snaps again with REAPER's own SnapToGrid, so REAPER has the last word. Phones: a drag moves only what's
  already selected (anything else pans), a long press opens a small menu (Split, Mute, Colour, No colour, Region over it; Rename on a marker;
  Marker/Region here on an empty spot); right-click opens it with a mouse.
- **Path:** `{topic:"daw", edit:{id, op, ...}}` -> `dawview.action` -> `lib/dawedit.lua`, which finds the item as the page drew it (the track's
  place and the item's among the shown ones: `dawview.shown`/`items_of`, the reader's own filter) and only while it's still where the page saw it,
  checks it, then applies it through the API in one undo point ("StudioSync web page: move item" and so on). The normal sync sends it from there:
  no second sync path. Markers are named by REAPER's number (the header's markers now carry `i`). The answer goes back as the `dawedit` topic
  (`{id, ok | why}`); the page draws the item where it's going until its chunk comes back, and snaps back with the reason on a refusal.
- **Permissions reused:** items, mirror.watch's own `allowed`: `sync.authority`'s rule for the track's name and the spot (track claims, time
  claims, region claims from the session's regions, the driver, Driver only / admins / Anyone) or `sync.maker_may` (the track's or item's maker
  while nobody claimed it), checked where the item is and where it goes (onto or off a claimed track), and not while a bandmate holds it
  (`presence.holder`, "is editing that item right now"). Markers and regions: `sync.watch_timeline`'s (the timeline is the driver's; admins in an
  admins' room; anyone in Anyone), and a region someone else claimed can't be moved or renamed, nor a region renamed onto a claimed name. This
  computer's own marks (pings, claims, punches) can't be touched or made.
- **Not yet:** deleting items or markers, resizing a region's edges, fades, keyboard shortcuts, multi-select, Shift to drag without snapping.
- **Tests:** `tests/test_0_60_rt_dawedit.lua` (the real `sync.authority` over a stand-in shared folder, each edit on a stand-in REAPER).
- **Check in REAPER:** on a real song with a bandmate: move, trim (both edges, a looped and an unlooped take), split, mute, colour an item and see
  it land on their side within a second or two; one Ctrl+Z undoes each web edit; drag with snapping on and off; move onto a track a bandmate
  claimed (refused, snaps back, says who); in Driver only as a guest (refused); a region they claimed (refused); add, move, rename a marker and a
  region as the driver; a phone: tap, long press, drag the selected item; a fixed-lanes track (only the playing lane's items show and move).

### Web UI: what remains (TODO)
- **Docking:** built (above); check it in REAPER on Windows, a Mac and Linux (WebKitGTK built 2026-11-19: proved in a SWELL host on
  REAPER 7.86's own libSwell on Ubuntu 24.04, docked, floated, typed into, Undock and key forwarding from the real pages; not yet in REAPER).
- **Pages, then parity:** scopes and to-dos/links in chat, Health, Play together: built (below); the ReaImGui panel stays until each page matches.
- **Health, Play together and chat parity built** (rt-webpages, 2026-11-19; offline tests and a stand-in server only, not run in REAPER yet):
  - **Health** (`lib/webpages.lua`, `lib/webui/health.js`): `lib/page_health.lua`'s own rows (its `maint_rows`, set up with what the panel hands
    it), red first, the yellow ones dismissed in the panel left out and counted; web links open in the browser; the rows' buttons stay on the panel.
    Topic `health`, built every 2 s and only while a page shows it (`{topic:"health", want}` every 10 s, 30 s grace).
  - **Play together** (`webpages.lua`, `play.js`): who's here (the `presence` topic), Follow each other with its bars behind (the panel's project
    setting `side`; left alone while Real time mode is on, `live.realtime_on`), Start together from the edit cursor or a region with count-in, click
    and bars later for listeners, Play / Record / Stop together, the count-down and the last start. Starts go through `together.start` (the panel's
    Start together and the Song page's Play use it too, as they do `together.regions` and `together.bar_of`); who may press them is
    `dawview.transport_refusal` (the Song page's rule, `dawview.may_transport` on `sync.authority`'s mode: a driver's room, the driver; an admins'
    room, the driver and admins). Topic `play`, every 0.5 s while shown. NINJAM / SonoBus connecting stays on the panel's Play/Jam page.
  - **Chat** (`lib/webui/chat.js`; app.js no longer draws the chat): This room / This project / Studio, Messages, To-do and Links. Topics `chat`
    (This project, always), `chat_room` and `chat_band` (only while a page shows that scope). Each entry carries its file's name as an id; actions
    `{topic:"chat", scope, text | todo | title+url | done+on | delete}` go to `page_chat.web_action`, which finds the entry in that scope's own
    listing (nothing else is touched) and uses the panel's own `chat.post/add_todo/add_link/set_done/remove` (anyone ticks a to-do, only its
    writer deletes; the page asks first). Non-web links are shown, never opened. Not yet: the All tab, notes/likes/drawings, the Everyone filter,
    and marking messages seen (the panel's unread count).
  - **Tabs:** `lib/webui/tabs.js` adds pages to daw.js's tab bar (`ssTabs.add`), keeps the latest of every topic and sends actions; `pages.css`.
  - **Tests:** `tests/test_0_60_rt_webpages.lua`; `tests/test_0_60_rt_webui.lua` (chat models and scopes).
- **Shared DAW view, view-only first** (stage 1 above): tracks, items, markers and cursors from the synced model, follow, play/stop.
- **Video and screen share** (step 5): first version built (step 5 above: calls, screen share, pointer); check it in REAPER on two computers. The Studio browser after it.

### What the web UI makes possible (James: "keep them coming")
- **Sharing each other's REAPER.** Screen share of the REAPER window inside the docker, with a live pointer ("look
  here") from whoever's watching. Taking control of someone's REAPER only with their explicit yes for that session,
  view-only by default, ended by either side at once.
- **Song history, visualized.** A timeline of the song's life: every change as a dot on a per-track lane, coloured by
  who made it; saved versions as milestones; scrub and hear the song as it was at any point (rendered on demand, or
  from prints); A/B any two points; restore any point (the existing restore, by time or by saved map). Sessions,
  takes and comments shown on the same timeline, so "what did we do on Tuesday" is one glance.
- **Chat that knows the song.**
  - Messages can point at a bar, region, track or take ("listen at bar 33"), and clicking jumps REAPER there.
  - Voice notes and audio clips, recorded in the chat and dropped into the song if wanted (fast first, lossless
    after).
  - Reactions on takes and comments; threads per song and per track; images and links.
  - Drag a file into chat: it lands in the studio's media (Syncthing behind it).
- **Drawing.** The existing Draw tool, moved into the web view: draw over the timeline, the mixer or a screen share,
  live for everyone, kept as an annotation layer on the song (shown in history, removable).
- **Song sheet.** Lyrics, chords and the arrangement (sections, who plays what), shared and editable live, with a
  teleprompter mode that follows the play cursor while recording.
  - **Built (rt, 2026-11-19; Lua tests and a stand-in server in a browser only, not run in REAPER yet):** the web UI's **Sheet** tab
    (lib/webui/sheet.js, lib/songsheet.lua). A section per region of the project, in order (two Choruses are `r:Chorus:1`, `r:Chorus:2`),
    plus sections added by hand (a name and the bar they start at, for a project with no regions); each has lyrics with ChordPro chords
    inline (`[Am]Here comes the [F]sun`, drawn chord-over-word) and a "who plays what" line. Stored as files in the project's shared
    folder, `<project>/sheet/<user>.json`, one per person and written only by them (so Syncthing never sees two writers, as the chat), each
    section stamped with the studio's shared clock; an edit also goes over the direct link and shows on the others' pages at once, until
    their copy of the file arrives. **Merge:** per section, the latest stamp wins (last-writer-wins on the section, never the whole
    sheet): a section is a few lines one person usually has in hand, so two people rarely type in the same one at once, and when they
    do, nothing is lost: the losing version stays in its writer's file and shows under the section ("Bee's version, 21:03, replaced by
    a later edit") with Use this version, and a newer edit arriving while you type is offered (Use theirs), never put over your words.
    Each section shows who edited it last and when. A region renamed or removed keeps its words as a section of its own until someone
    deletes it. Saved 1.5 s after typing stops or on leaving the box; a save Live sync didn't take is kept and tried again.
    **Teleprompter:** the sheet big (22-40 px), the section the play position is in lit and the rest dimmed, scrolled on through it
    while playing (your own scroll holds it 4 s), bar.beat, the section and the count-in on top, Full screen, the screen kept awake
    where the browser allows (a secure page: the https link).
- **Song to-dos.** A small task list per song ("retrack bridge vocal"), tied to tracks and bars, ticked off by anyone.
- **Synced visuals.** Big count-in, bar/beat and section display for everyone, from the shared clock, so nobody
  misses an entry when recording together.
  - **Built (rt, 2026-11-19; Lua tests and a stand-in server in a browser only, not run in REAPER yet):** the web UI's **Beat** tab
    (lib/webui/visuals.js, beat.js, lib/songsheet.lua): "Starting together" counting down the seconds to a start, then the count-in's
    beats (4 3 2 1, red when it's a recording), then bar.beat as big as the screen allows with a dot a beat, the section you're in (the
    sheet's, else the regions) and the next one ("Next: Chorus in 2 bars"); Full screen. Live sync publishes the play position as a line on
    its link clock (StudioSync_DirectNow), fitted to the median of the stretch's last 15 readings and sent again only when it moves 3 ms
    off, plus every beat's time from REAPER's own tempo map (ramps and time signatures as REAPER plays them), sent when the project
    changes; the page measures its clock against the computer's (GET /api/time, the quickest of 8 round trips, again every 10 s) and works
    out bar and beat each frame. So a page shows its computer's REAPER within half a round trip to it (under a millisecond on the same
    computer, a few on Tailscale) plus a frame, and every computer started together on the shared clock, so every page shows the same beat.
    The count-in's end, length and moment come from Live sync's start (a new "together_from" ExtState beside "together_at"). Both pages are
    cheap: the topics are built only while a page shows one (it says so every 10 s), and nothing is drawn while a page is hidden.
- **Shared DAW view (James).** An arrange view drawn in the web UI from the synced project model (tracks, items with
  waveforms from REAPER's peak data, MIDI notes, automation, markers), the same for everyone whatever their theme or
  layout: everyone's cursor and selection live, "follow" a bandmate's scroll/zoom, live claims, comments and drawings
  on top. Edits made in it are applied to your REAPER through the API and go out through the normal sync, so there's
  no second sync system and claims/permissions hold. Works in a browser without REAPER too (view, comment, simple
  edits applied by the hub's REAPER). Stages: (1) view only + cursors + follow + play/stop; (2) item edits (move, trim,
  split, mute, colour, markers, regions); (3) piano roll and automation lanes; (4) mixer (plug-in windows stay in
  REAPER). Shares its timeline drawing with song history.
- **Session notes from the call.** With everyone's OK, the call transcribed locally into dated notes on the song
  (local speech-to-text; running a local GPU model needs James's OK each time, per his rules).

## Everything else that improves
- Claims and edit clashes: instant claims mean far fewer "both changed it" merges.
- Suggestions, notes, likes, follow-mix, producer cues: instant.
- Health: live round-trip and loss per bandmate, from the link itself.
- Bug reports and debug collections: straight to the owner's computer.
- Prints and chained prints: stage files hop computer to computer in milliseconds instead of seconds.
- Fewer files in the shared folder (no presence/heartbeat/live-MIDI files), so Syncthing has less to do meanwhile.

## Order and gates
0 (wiring, 0.59.50) -> signed updates (James: early) -> 1 (live layer) -> 2 (interval streaming) -> 3 (media, then offline) -> 4 (audio spike, then
built-in audio, all formats) -> 4b (remote plug-ins in real time) -> 5 (video). The web UI runs alongside from
step 1 on (its first pages: the live layer's presence, claims and chat). Each step ships behind a studio setting and falls back to today's path when a computer
lacks the new extension or can't be reached. Retiring NINJAM, SonoBus or Syncthing is James's call at each gate.

## Risks to check early
- Reading a take's file while REAPER is still writing it (file sharing on each system; REAPER's write buffering).
- Tailscale relays (DERP) when computers can't connect directly: higher latency; Health should say which path is used.
- Bandwidth: 48 kHz stereo 24-bit is ~2.3 Mbit/s raw; intervals go as FLAC (about half) and live audio as Opus
  (~128-256 kbit/s per person).
- Audio-thread safety in the hook (no locks, no allocation, no REAPER API calls there).
- Firewall rule on each computer (one UAC prompt on Windows), macOS's firewall prompt, Mac/Linux builds via CI.

## Findings, 1.0.8 (2026-11-19: steps 1, 2 and the step-4 spike started, extension side)
Built in the extension (extension/direct.cpp, direct_audio.cpp; protocol, API and measurements in docs/direct-link-design.md
"1.0.8"), with lib/direct.lua's side; not wired into the engine or UI yet, not loaded into REAPER yet.

- **Messages (step 1):** typed, signed, up to 64 KB, on the same link: on one computer 0.02 ms send -> polled. Over Tailscale it's
  the link's one way (~30 ms desktop -> laptop off the home network).
- **Shared clock (step 1):** NTP's method in-band; on one computer with 0-15 ms random delay each way, within a few ms of the true
  skew after 1.5 s (0.15-1.5 ms over 8 runs). **Desktop <-> laptop: the laptop's clock is 322.5 ms ahead of the desktop's** (stable within 1.5 ms over a minute,
  round trip 57 ms). That is what "clocks by internet time" was hiding: a third of a second, enough to wreck Play/Record together. The
  reference is the lowest Syncthing device id among the computers here (direct-link-design.md "The shared clock").
- **Interval streaming (step 2):** a growing file streamed as it's written, hash-checked at the end; the received WAV is playable at
  every point (sizes kept to what has arrived). Desktop -> laptop, a 48 kHz 24-bit stereo take written in real time with 100 ms
  intervals: on the laptop about 125 ms after it was written (median), complete and checked 0.4 s after stop. The interval is the knob:
  ~interval/2 + one way. Streams carry a codec id (0 = the file's bytes; Opus packets later) for "fast first, lossless after".
- **Audio spike (step 4):** the hook's capture side: inputs copied on the audio thread into a lock-free ring (no lock, allocation,
  REAPER call or file there), peaks, and a worker that writes N seconds to a float WAV. Idle until StudioSync_DirectAudioStart. Not yet
  run inside REAPER.

### Step 4 plan: real-time audio (from the spike)
- **Threads:** audio thread (hook, pre): capture into the ring (built). Encoder thread: pulls a frame, encodes, sends (UDP).
  Network thread: receives, checks, puts packets in each sender's jitter buffer. Audio thread (hook, post): pulls decoded audio from
  each sender's ring, resamples, applies per-person gain/mute, adds into the output buffers. Only lock-free rings and atomics between
  them. Decoding on the network thread (or a decoder thread), never on the audio thread.
- **Packet (UDP, one datagram each, under Tailscale's 1280 MTU: payload <= ~1200 bytes):** `"SSA1"`, version/flags u8, **codec u8**
  (0 PCM s16, 1 PCM s24, 2 PCM f32, 3 Opus, 4 FLAC), **channels u8**, fragment index/count (u4/u4), **sample rate u32**, **frame size
  u16** (samples per channel), stream id u16, sequence u32, timestamp u64 (the sender's sample clock), sender link-clock µs u64 (for
  latency and drift), payload, 16-byte truncated HMAC-SHA256 with a session key (studio key + a nonce agreed over the TCP link).
  Any channel count: Opus multistream (mapping family 1 to 8 channels, 255 beyond), FLAC up to 8 per stream (more: several streams),
  PCM any (fragmented when a frame doesn't fit).
- **Formats, per studio and per person (Health suggests Opus when loss rises):**
  - Opus (default): libopus 1.5 (BSD-3-Clause), 2.5-20 ms frames, in-band FEC and packet-loss concealment (`opus_decode(NULL)`).
  - FLAC: libFLAC (Xiph, BSD-3-Clause; the `flac` tool is GPL, the library isn't), 256-1024-sample blocks. Encoder:
    `FLAC__stream_encoder_set_blocksize(frame)`, `_set_channels/_set_bits_per_sample/_set_sample_rate`, `_init_stream` with a write
    callback; the first callback output (fLaC + STREAMINFO) goes once over the TCP link at session setup (and again on reconnect), and
    every later callback is one self-contained FLAC frame = one packet (`FLAC__stream_encoder_process_interleaved` per frame). Decoder:
    `FLAC__stream_decoder_init_stream` with a read callback that hands it STREAMINFO first, then one packet per
    `FLAC__stream_decoder_process_single`; its write callback fills the sender's ring. A lost FLAC/PCM packet: short crossfade to
    silence and back, counted for Health (lossless can't conceal).
  - PCM: no codec, lowest CPU; 24-bit stereo 48 kHz is 4 ms (192 frames) per datagram.
- **Jitter buffer, rates, drift:** per sender, ordered by timestamp, target depth = max(2 frames, p95 of measured jitter), adapted
  slowly. Sample-rate conversion to this device's rate and drift correction in one resampler whose ratio is
  `(src_rate / dst_rate) * (1 + correction)`, correction from a slow PI controller on the buffer's fill (keeps it at target; tens of
  ppm). Candidates: REAPER's own `Resampler_Create` (REAPER_Resample_Interface, `SetRates` each block: no new dependency; check it
  changes ratio without clicks) or the speexdsp resampler (BSD-3-Clause, `speex_resampler_set_rate_frac`, made for this).
- **Mixing in:** the post-processing hook adds each person's audio into the hardware output buffers: heard by this computer only,
  not recorded or rendered (right for a call). To record a bandmate's live audio, the receiver also offers it on a track (step 4b's
  plug-in as a source), not by writing into hardware input buffers (only real channels exist there).
- **Building the libraries** (pinned tags, fetched in CI and on JAMES-MAIN, statically linked into reaper_studiosync; not vendored yet):
  Windows `cmake -A x64 -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded -DBUILD_SHARED_LIBS=OFF` + `cmake --build . --config Release`
  (matches the extension's /MT); macOS the same with `-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DCMAKE_OSX_DEPLOYMENT_TARGET=10.13`;
  Linux the same with `-DCMAKE_POSITION_INDEPENDENT_CODE=ON` (x86_64 and aarch64 runners). libFLAC with
  `-DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DBUILD_DOCS=OFF -DWITH_OGG=OFF -DINSTALL_MANPAGES=OFF`; libopus with
  `-DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF`. Licence notices (BSD-3-Clause) shipped beside the extension.
- **Firewall:** the Windows rule gets a UDP twin on the same port (same netsh words with `protocol=UDP`).
- **Gate:** an hour desktop <-> laptop with no glitch, the hook's callback time and the encoder's CPU in budget (Health shows both).

### Step 4b findings: feeding and reading a hidden track
- The audio hook can't target a track: it sees only the hardware buffers (input_nch/output_nch real channels). Writing into an input
  buffer in the pre call and giving the hidden track that input, then reading a spare hardware output in the post call and zeroing it,
  would work only on interfaces with spare channels and fights the user's routing: not the design.
- Feeding a track from the extension: `PlayTrackPreview2Ex(proj, preview_register_t*, flags, measure_align)` with `preview_track` set
  and `m_out_chan = -1` plays a PCM_source of ours (its GetSamples fed from the jitter buffer, on the audio thread) into that track, as
  SWS's "preview through track" does. Reading a track's live output has no extension API: `CreateTrackAudioAccessor` reads the track's
  items pre-FX, not its live output; gmem isn't in the C API.
- **Cleanest design: the StudioSync plug-in is both ends on both computers.** Requester: `StudioSync Hop` in the chain where the missing
  plug-ins are: sends its input, outputs what comes back, reports the round trip as latency (VST3 `getLatencySamples` +
  `restartComponent(kLatencyChanged)`; CLAP `latency` extension) so PDC holds playback in sync. Host computer: StudioSync makes a
  hidden track (`B_SHOWINTCP`/`B_SHOWINMIXER` 0, `B_MAINSEND` 0, `I_PERFFLAGS` |= 2 "no anticipative FX" so it runs in real time) with
  `Hop (source)` -> the synced plug-ins -> `Hop (sink)`. Each instance is processed in REAPER's own FX loop, block-synced, no hardware
  channels. The plug-in instances get REAPER's API from the host callback, look up a StudioSync_* function once (main thread) that hands
  them a lock-free ring to the extension, which does the network, codecs and jitter buffers for both. Several hops add up and PDC
  compensates the total.
- To check in REAPER: that a hidden track with no items and no input keeps processing its FX while stopped and playing ("Run FX when
  stopped" preference); that PDC follows a latency change mid-session; that a plug-in instance can reach the extension's functions.

### Step 4 built, first version (rt-audio branch, 2026-11-19; native and Lua tests only, not run in REAPER yet)
- **Engine:** AOO v2.0-pre4 (git.iem.at) + Opus v1.6.1 (xiph), vendored in extension/third_party (README.md: sources, licences) and
  compiled into the extension statically (Windows +708 KB, 1.15 MB; deps 6 s, DLL 7 s on JAMES-MAIN). extension/rtaudio.cpp: one AOO
  source sends the chosen inputs (Opus, 5 ms CELT frames; AOO's process() only copies into its lock-free queue on the audio thread, the
  send thread encodes) to one AOO sink per peer (30 ms jitter buffer target, drift-correcting resampler), mixed in the hook's post call
  into the first hardware output pair at each peer's gain unless muted (heard here, never recorded: the 4b plug-in is the way onto a track).
  AOO decodes in the sink's process(), on the audio thread, as SonoBus does (tens of µs per 5 ms frame), not on the network thread as
  planned above. UDP on the link's port (47281), only 100.64.0.0/10; every datagram "SSL1" + AOO message + 16-byte HMAC-SHA256 with a key
  from the studio secret (its own label, so it can't pass for a link frame). No session nonce yet (replay inside the tailnet only).
- **ReaScript:** StudioSync_LiveAudioStart(inputs, nch, kbps), Stop, Peers(json `{secret, port, peers}`), Status (JSON: per peer
  rtt/latency/buffer ms, loss, dropped, underruns, level, gain, mute), PeerSet(peer, gain, mute).
- **Lua (lib/liveaudio.lua):** studio setting band.json `live_audio` (off by default), this computer's inputs/stereo/kbps, Live sync's tick
  starts it for direct.peers (the song in front drives it), Health row per bandmate, Chat > Call level/volume/mute per bandmate, the UDP
  twin of the direct link's firewall rule (direct.setup_firewall, same UAC).
- **Measured on one computer (tests/rtaudio_test.cpp):** sine heard 43 ms after it was played (30 ms of buffer), level within 0.1 dB at 128
  kbit/s, wrong secret refused both ways, a secret given while running is taken up.
- **Not yet:** FLAC/PCM choice, more than two channels heard (a sender's 3-8 go out, the receiver plays the first two), hub mixing,
  output pair choice, Talk/deafen tie-in with the existing call controls, SonoBus retirement.

### Fast first, lossless after: what the receiving Lua does
- The stream says its codec (begin op). Opus-first: the receiver's file is an Ogg Opus file (REAPER reads .opus), placed on the take.
- When the lossless file arrives (Syncthing's copy in the shared folder, or the link in the background) and its SHA-256 equals the one
  the recorder announced (the stream's done, or the take's event): `local src = reaper.PCM_Source_CreateFromFile(path)`,
  `local old = reaper.GetMediaItemTake_Source(take)`, `reaper.SetMediaItemTake_Source(take, src)`, then `reaper.PCM_Source_Destroy(old)`
  (only when no other take uses it), peaks built in the background (`reaper.PCM_Source_BuildPeaks(src, 0)`, then 1 each defer cycle
  until it returns 0, then 2), `reaper.UpdateItemInProject(item)`, `reaper.UpdateArrange()`. Outside any undo block (no undo point; the
  next one made by someone else carries the new path, which is what's wanted). Item position, length and start offset stay: Opus's
  pre-skip must be honoured so both line up to the sample (check in REAPER). Then the inbox copy goes.
- The same swap with the raw stream (codec 0): the received WAV and Syncthing's copy are the same bytes, so the swap only changes the
  path from the inbox to the shared folder.

### Lua hooks still to wire (after the engine files are free)
- Live sync tick: `direct.messages(cfg)` and a handler per kind: presence/heartbeat (presence.lua: seen at once), claim (the claims
  code), chat (page_chat.lua), cue/transport (together.lua / producer.lua), midi (livemidi.lua / midiview.lua: notes as played), json.
- Senders beside today's file writes: presence heartbeat, claims, chat send, cues, Play/Record together (`start_at` from
  `direct.shared_now()`), live MIDI notes: `direct.msg(cfg, kind, t, song, room)`; the file path stays as the record/fallback.
- `direct.keep_clock(cfg, song, room)` each tick (rate-limited inside); together.lua uses `direct.shared_now()` when it isn't nil.
- Recording: at record start, find the files REAPER is writing (no API names them before stop: new files in the project's record
  path made after the start), `direct.msg(cfg, "take", { track guid, position, rel, srate, nch }, ...)`, then
  `direct.stream_start(cfg, path, song, room, interval)`; at stop `direct.stream_end(cfg, rel)`.
- Receiving: from `direct.streams(cfg).inn` and the "take" message, an item on the recorder's track at its position, its source the
  growing file (re-made each interval with the item's length extended), swapped to the shared folder's copy when it arrives; the
  `.streams` copy deleted then (nothing prunes `.streams` yet).
- Health: the clock (offset to the reference, its round trip) and streams; groups.lua setting for the live layer if it gets its own.

### To test in REAPER
- Reading a take's file while REAPER records it: that REAPER's write share mode lets another handle read it (Windows), how often REAPER
  flushes (the stream only sees what's on disk), what header it writes first (placeholders), and that the header at stop is the only
  rewrite (the hash fallback resends the whole file otherwise). Also WAV vs RF64 vs W64 vs FLAC recording formats.
- That StudioSync_DirectStreamEnd after stop sees the finished file (REAPER closed it); a discarded take (deleted mid-stream).
- An item whose source is a growing WAV: does REAPER pick up the new length (re-create the source, or offline/online)?
- The audio hook: StudioSync_DirectAudioStart on a real interface, peaks, a dump, the callback time with REAPER under load; stop and
  start again; REAPER's audio device restart while running.
- StudioSync_DirectNow / Clock from Lua (the double return), messages from Lua, all 1.0.8 functions present.

## Decisions and additions (James, 2026-11-19, after the tools research: docs/tools-research.md)
- **Tailscale Peer Relay:** the desktop relays for the tailnet (one tailnet holds every studio's computers, so one setup covers
  Smiley Studios and Chilio). Desktop relay on UDP 40041 (`tailscale set --relay-server-port=40041`); the tailnet policy grant
  and a router port forward of UDP 40041 to james-main make it reachable from outside. It doesn't admit people without
  Tailscale: that's the Tailscale-free connection option (libdatachannel/libjuice or iroh) still on the list.
- **Built-in audio on AOO** (BSD, SonoBus's engine: jitter buffer, drift correction, Opus/PCM, groups), wrapped in StudioSync's
  own layer: the link's signed peer list and key, a FLAC codec through AOO's codec plug-in API, REAPER's audio hook for capture
  and mixing, hub mixing. Writing our own engine wouldn't pay back; any AOO part can be forked or replaced later.
- **Remote plug-ins endpoint ("Hop"):** VST3 SDK (MIT) + CLAP (MIT) via DPF (ISC). Not JUCE (AGPL/commercial).
- **Extension libraries:** yyjson (JSON), zstd with a trained dictionary (events on the link and snapshots), SQLite (history,
  snapshots, comments index), Opus 1.5 with Deep PLC/DRED and small frames.
- **Web UI:** webview (MIT) or Saucer (MIT), not CEF; WebView2 accelerator keys forwarded to REAPER; Linux embeds WebKitGTK
  through SWELL's X bridge (as plug-in windows), the browser where it isn't installed. Yjs (MIT) for the song sheet, chat, comments and to-dos; Excalidraw (MIT) for
  drawing (not tldraw: licence key/watermark); wavesurfer.js or own canvas for waveforms.
- **Features added (James):** cue mix + talkback control (engineer sets a performer's monitor mix; talkback mutes while
  recording); song forks (branch an arrangement, keep or merge back); versioned, timestamped comments with a resolved state
  across mix versions; client listen links (expiring/password) to the live mix or the latest bounce; Ableton Link bridge (a
  local Link session per computer driven by the shared clock); plus master-bus stream to a browser for approvals, published
  revisions (a song's official mix), one-click reference bounces with timestamped notes.
- **AI extras (James: on the roadmap, ask before every use):** stem separation, transcription (session notes, lyrics),
  audio-to-MIDI, mastering/mix feedback, chords/key/tempo/structure; local and cloud options compared in docs/ai-research.md.

## Step 2 wired (2026-11-19, lib/streams.lua; not run in REAPER yet)
- **Recorder:** Live sync's tab in front lists the record path (`GetProjectPathEx`) every 0.1 s from Record until 3 s after the playhead
  reaches the take's start (a count-in or pre-roll comes first). An audio file made or written since Record (`StudioSync_DirectFileTime`,
  extension 1.0.10: through a handle, current while REAPER writes; 3 s tolerance) is a take's, so arming and pressing Record at once works
  (an older extension: only files that appear after the first look). They're matched to the armed audio
  tracks (`I_RECARM`, an audio `I_RECINPUT`, `I_RECMODE` 0/1/3/5/6, mirrored and with an oid) by the track's name in the file name (longest
  first), then its number at the start of the name, then in order when as many files as tracks are left; anything else isn't streamed.
  Each match: `direct.stream_start` (100 ms interval) under the link name `<song>/<room>~<user>~<file>`, then a "take" message `{ id, user,
  track, name, file, pos, at, srate, nch, fmt }` (`pos`: the edit cursor when the playhead is before it, as in a count-in, or under 5 s past
  it, else the playhead; `at`: the shared clock when the playhead is at `pos`). 0.5 s after stop: `direct.stream_end` and a "take_end"
  message. Limits: another audio file written into the record folder in those seconds can be taken for a take's (only when it fits a
  track); auto-punch starts aren't read (the placeholder sits at
  the cursor); a second record path, files renamed at stop and a bandmate who joins mid-take aren't followed. All of those still arrive the
  normal way.
- **Live MIDI:** each change goes as a link message (`<since>-L<n>`) within 50 ms, `at` every 0.25 s; the 1-second files are written only
  while the link doesn't reach everyone here (`direct.reaches_all`), plus the last one at stop. A note that ended stays ended when an older
  file arrives after the link's word.
- **Receiver:** on "take", an entry; once 4 KB have arrived, an item on the recorder's own track (its plug-ins play it) at `pos`, marked
  `band_arriving` (mirror.scan skips it, as it skips its own stand-ins: never sent) and `band_stream`. Growing: a fresh
  `PCM_Source_CreateFromFile` swapped in with `band.set_take_source` (the old one destroyed) and `D_LENGTH` set from the source's length,
  4 times a second, less often as the take gets long (length / 120 s: REAPER reads the file and builds peaks again each time); a source
  that reads 0 s (a growing FLAC whose header says "length unknown") gets its length from the shared clock instead. At done: the final
  source once, then `PCM_Source_BuildPeaks` 0, 1 per tick until 0, then 2. Not touched on a track armed here while this computer records.
- **Listening (Settings > Options, "Parts play"; per computer):** As it comes (plays at once), In time (NINJAM style: a recording start of
  someone you follow, side by side or "follow", gets lag = N bars at its position, so your playback runs one interval behind theirs on the
  shared clock from the same song position; their next stop gets the same lag and stops at their position), Show only (muted). In time
  limits: only with transport following; one interval in seconds at the take's start (a tempo change later keeps the positions aligned,
  only the gap in time changes); seeks and loops mid-take are followed only as side by side follows them; a producer's chosen lag wins.
- **Fast first, lossless after:** the real take is its own item (the mirror event and the shared copy, unchanged). While mirror's grey
  stand-in waits for its audio, the placeholder stays (and isn't given up on). Once an item over its stretch plays a file named
  `<hash>-<file>` that exists: "repoint" when the stream finished, checked out and is the same size (the placeholder just goes: the real
  item already plays the same bytes from the shared folder), "swap" otherwise (it goes too, with a line in the log). The streamed copy and its
  .reapeaks go then. Given up on 15 minutes after done with no take (or 5 minutes without bytes). Each prune (30 s, and as a song opens):
  this room's `.streams/<song>` files that no entry holds and that aren't still arriving. shortcut: a song nobody opens here keeps its
  streamed copies until it's opened.
- **Health:** a "Takes streaming" row (out/in counts and MB, and any stream that didn't get through whole) under the direct link's rows.

## AI as an optional add-on (James, 2026-11-19)
The AI features ship as a separate, optional "StudioSync AI" add-on (its own folder/package, installed only by those who want
it), never inside the core. It runs as a helper program StudioSync calls (Lua renders a region/stem to WAV, the helper
writes WAV/MIDI/JSON, Lua imports the result as items, MIDI, markers or regions), so GPL-3 covers only StudioSync's code
and model weights download only after an explicit OK. Every run that uses a local GPU model asks first (James's rule);
every cloud run asks separately because audio leaves the band's computers. Order (docs/ai-research.md): mix feedback from
the stats StudioSync already computes (no audio leaves; local LLM on the hub or Claude), stem separation (RoFormer +
htdemucs_ft; LALAL.AI fallback), sections/tempo map (allin1), session transcription with speakers, audio-to-MIDI (Basic
Pitch + ADTOF), take search (CLAP) and scored auto-comping, reference mastering (Matchering), chords/key.
Started 2026-11-19 in addons/ai/ (README there): rule-based mix feedback is real and needs no Python; the helper (ssai.py, own venv) refuses any job without a matching consent.json token, and the model jobs are interfaces with dry-run examples until the owner OKs real runs.

## More ideas from the streaming work (James, 2026-11-19: on the roadmap)
- **Producer "listen while they record":** a producer hears a take on their own monitors as it's being recorded, from the
  interval stream (no call needed), with their own level.
- **Punch-in assist:** bandmates see exactly where the recorder punched in and out, live on their timeline (punch range
  and pre-roll sent as link messages), so "go again from the bridge" is unambiguous.
- **Late-joiner catch-up:** someone who joins mid-take gets the take so far (the stream from its start), not only from the
  moment they arrived.

## Studio browser (James, 2026-11-19)
A "Studio browser" panel in the web UI for browsing the web, playing videos and showing ideas together. A logged-in page
(a Drive folder, a private video) renders differently per person, so it works in four modes:
- **Follow me:** one person browses; everyone's panel loads the same URLs and follows scroll (public pages: gear,
  references, tutorials). Sent as link messages.
- **Watch together:** YouTube/Vimeo (their embed APIs) or a video file plays in sync for everyone: play, pause and seek go
  over the link, timed by the shared clock, so everyone sees the same frame ("check out 1:32").
- **Share a tab:** anything logged in or private is shared as a live screen share of that browser view (the same WebRTC path
  as video calls), so everyone sees exactly your page.
- **Studio pinboard:** links, videos and files pinned to the studio or a song; Drive links open in each person's own
  session; files dropped on it sync like other studio files (Syncthing behind the link); a pin can sit at a bar of the song
  ("reference for the chorus" at the chorus).
Video audio plays through each person's system audio by default, with an option to route it into the call.

- **First real run (desktop -> laptop, 24-bit FLAC, fixed in 1.0.10):** REAPER writes a FLAC take in 256 KB blocks (its first 64 KB first);
  the stream sent each block as one 256 KB frame, and each frame waits up to 3 s for its answer: over a slow way (a Tailscale relay's few
  hundred kbit/s) every such frame timed out ("the connection dropped") and skipped the peer 10 s, so the copy sat at the first 64 KB until
  stop. Frames are 64 KB now, halved per peer after a dropped one (down to 16 KB); a read problem on the recorder is its own, never a 10 s
  skip of the peer, and says why in `StudioSync_DirectStreams` (`error`, with the Windows error) and Health. Stop-and-wait at 64 KB gives
  about 1 MB/s at a 57 ms round trip, several times a FLAC take's rate. With REAPER's 256 KB write blocks a 24-bit FLAC take reaches the
  link in ~1-2 s steps: fine for "in time", and the floor for "as it comes".

## Step 2 checked in REAPER (1.0.11, 0.59.49.9, 2026-11-19: desktop records, laptop and Mac receive)
- **As it comes:** a 61 s FLAC take streamed to the laptop and the Mac while it recorded: the copy grew in REAPER's own write steps and the
  placeholder grew with the take (6.7 s -> 57.9 s); at stop the real take replaced it on both within ~6 s. Arm and Record in the same
  instant streams the same way.
- **The "stuck at 64 KB" take:** not a stale size. The stream trace (ExtState "stream trace" = 1, `<home>/direct/stream_trace.log`) read
  the size four ways on all 535 passes and they always agreed; both peers' offsets kept up with it. The cause was the branch shipping the
  1.0.6 Mac build beside a 1.0.11 want: the Mac's extension was swapped down at its next start (no direct link there). Now a shipped build
  is only put in when it holds the wanted version (lib/fromfolder.lua), and the branch ships CI's current Mac and Linux builds.
- **In time:** wired into the cue path (it was offered in Settings but not used). Following the desktop's take at 1 bar, the laptop played
  1.85-1.87 s behind on the shared clock (one bar at the song's tempo) and stopped where the desktop stopped.
- **The limit found:** the take reaches the link only as fast as REAPER writes it. A tone recorded to FLAC came in ~200 KB steps every
  ~4.6 s (very compressible audio; a real take compresses less and steps faster; 24-bit 48 kHz stereo WAV is ~0.9 s per 256 KB). So "In
  time" at 1 bar keeps the transport one bar behind, but the newest few seconds of a FLAC take haven't arrived yet. Until step 4: Health
  could say "use 4+ bars, or record WAV, for in-time listening"; with step 4 the audio hook sends what's recorded straight from the input
  (Opus or raw, ~10-20 ms frames), and the file stream becomes the lossless follow-up ("fast first, lossless after").

## Step 3, online half, checked in REAPER (0.59.49.11, 2026-11-19)
- A fresh 4 s WAV put on a new track on the desktop: the laptop had the item playing its real file about 1 s later, the Mac within a few
  seconds (each link look ~3-4 s apart, so the Mac's moment is an upper bound). Before, media waited on Syncthing (4-7 s, more for big files).
- Syncthing takes the file we placed first as the same file (identical blocks): no conflict copies, every folder idle with nothing needed, and
  the receiver's copy simply becomes the global version (modifiedBy that computer).
- Found and fixed: Syncthing's own download, a moment behind, found the file there and left its full-size temp (`~syncthing~<name>.tmp` on
  Windows, `.syncthing.<name>.tmp` elsewhere) for a day: double disk use for big media. Now the receiver asks Syncthing to rescan that file
  the moment it's placed (the Mac then made no temp at all), and a whole-size temp untouched for a minute beside a placed file is removed.
- Still open: takes go twice (the step-2 stream, then the shared copy as media): announce "media X = stream Y" to skip the second send.
  Offline catch-up (step 3's second half) is next.
- Takes no longer go twice (0.59.49.12): mirror.share_media remembers what each shared copy was copied from, the recorder what it streamed,
  and the media message then names the take ("media out as the streamed take"); the laptop and the Mac placed the shared copy from their
  own stream copy within ~0.2 s of the stream's end, no Syncthing temps left.

## Proposed next (2026-11-19, from the streaming and media work: James to pick)
- **Recording-format hint:** Health and the In time option say when the record format makes in-time listening late (FLAC arrives in
  multi-second steps) and offer WAV for the session, or more bars; the step-4 audio hook removes the limit later.
- **Syncthing in Health:** the folder's state, errors and "still needs N files" for each computer, from the same REST calls the link uses now,
  so "why hasn't the Mac got it?" has an answer on screen.
- **Send anything:** drag any file (video reference, PDF chart, plug-in preset, Ableton set) onto a bandmate in the panel: it goes over the
  link at once (the link's file list widened per type, still name-checked), Syncthing behind it; ties into the studio pinboard.
- **Link speed per bandmate:** a measured throughput and path (direct, or relayed and how slow) shown before recording together, so "As it
  comes" vs "In time" vs WAV can be chosen knowing what the link carries.
- **Disk space guard:** before recording and before placing media, the shared drive's free space checked on every computer; a bandmate
  running low is told (and the recorder warned) before a take fails to land.
- **One copy per file across songs:** the same audio used in two songs (a loop, a sample, a reference) stored once by hash in the studio, not
  once per song: less for Syncthing and the link to carry.

## Catch-up over the link, checked in REAPER (0.59.49.13, 2026-11-19)
- The laptop's Syncthing capped at 10 KiB/s, a 20 MB noise WAV dropped into the desktop's media folder (no change sent, so only catch-up
  could carry it): 5 s later the laptop asked the desktop for it ("media_want", to the desktop alone), the desktop streamed it to the laptop
  alone, and it was in place 23 s after the ask (~0.9 MB/s, the 64 KB stop-and-wait over Tailscale). Syncthing at that cap: ~35 minutes.
- Syncthing makes its temp download full-size at once (preallocated), so "whole size" isn't a finished download: the temp tidy relies on a
  minute with no writes, and on Windows a temp Syncthing still holds can't be removed anyway.
- Next for speed: more than one 64 KB frame in flight per peer (a window), since a big catch-up or print is link-rate bound today.

## The cloud copy as the hub (James, 2026-11-19: "imperative, especially for studios without a hub")
The Drive copy (lib/drive.lua: each room mirrored to a shared cloud folder, any sync client) becomes a full member, not a session-end post box:
- **Always current:** new media, takes, prints and events go to the cloud copy as they land (after the link has carried them), not only at
  session end, so a computer opening the song later finds everything there even when nobody else is on.
- **Catch-up's last source:** when no peer on the link has a file Syncthing still needs (nobody online, or the one who made it is away),
  catch-up takes it from the cloud copy once the sync client has it whole (some clients keep files online-only: those are asked to download,
  or skipped), then places it as the link would; Syncthing stays the judge of what's missing.
- **The hub's stand-in:** with no hub online, the cloud copy holds what the hub would (snapshots, restore points, the studio's settings and
  update files), so failover is "hub, else the cloud", never "nothing".
- **Health:** the cloud copy's state per computer (signed in, the shortcut there, last upload, files waiting), as Syncthing's gets its row.
- Risks: the cloud services' rate limits (Drive's userRateLimitExceeded, seen 2026-10-28), online-only files, a service's own conflict copies;
  a studio without a cloud folder keeps today's behaviour.

### Built and checked in REAPER (0.59.49.14, 2026-11-19)
- **Sooner passes:** a cloud pass half a minute after changes go out (drive.pass_due; never closer than 30 s apart, else every 3 minutes).
  A 5 MB recording added on the desktop was in its Drive folder 39 s later (before: up to 3 minutes).
- **Cloud catch-up:** with the studio's direct link off and the Mac's Syncthing capped (10 KiB/s, LAN limited too), the Mac's catch-up
  found the file Syncthing still needed in its own Drive copy ("nobody on the link: a cloud pass now") and its pass brought it: the file was
  in the Mac's studio folder 63 s after the desktop added it (Google's sync to the Mac took ~12 s of that). Syncthing alone: ~8.5 minutes.
  No conflict copies, Syncthing idle, its temp download tidied, as for the link's.
- **Health:** "Google Drive copy: up to date, last pass N minutes ago" (green), still copying (grey), last pass failed / no pass lately
  (yellow). A computer without a cloud copy shows no row.
- Next: the hub's other jobs in the cloud copy where no hub is online (snapshots and the studio's update files), and members without a cloud
  folder told what they'd gain from one (the laptop here has none).

## Song forks, versioned notes and client links (rt-forks branch, 2026-11-19; offline tests only, not run in REAPER yet)
- **Forks are side rooms (lib/forks.lua).** A room already is a branch: its own tab and history from where it was made, the song's recordings
  shared through the room folders (nothing copied), Bring into / Send selected for the way back. A fork is a side room whose room.json also
  says where it came from (`fork = { from, version, label }`). Rooms page: **Fork song** (as it is now) beside Create side room; Restore: a saved
  version or a change, **Fork from here** ("Open in side room" with a name: the room made from now, then put back to then). Its square says
  "fork of main, from 'chorus v2'".
- **Compare, bring back what you pick:** in a fork, **Compare with main...** opens the Bring-into view with a track-by-track count (changed here,
  in main since the fork, in both) and a tick box per change; a ticked item on a track main hasn't got brings that track, a ticked new track brings
  its plug-ins, automation and sends. Untouched, everything is ticked: Bring into as before.
- **Adopt as main:** from the fork, with main open here and driven by you. Main as it is now is kept first as a fork of its own ("main before
  <fork>"), then main is made exactly as the fork is (mirror.plan_known with the fork's own map over both rooms' histories, and the fork's tempo
  map and markers), for everyone, as new changes, so Restore in main can go back. Main stays the room called main: renaming room folders under
  Syncthing and open tabs on every computer was the risk not taken.
- **Versioned notes (lib/review.lua):** notes stay the "note" events they were (ticked off in <Song>/chat/resolved). A new note also carries the
  room's newest saved version (`ver`) and the region it sits in; the Notes tab shows "made on version N" and "that spot changed since" (its item
  changed later, or on its track an item there or starting up to 30 s before, or the track's plug-ins, or the tempo map). Older notes go by time.
  Only changes History has read already are looked through (recall.read_so_far), so nothing is read for it.
- **Client links, built: a folder in the cloud copy.** Mixes page, **Make a client link...**: pick a mix from <Song>/mixes; StudioSync copies it to
  `<cloud copy>/_Client review/<Song> - <mix>/` with comments.txt (how to comment, in the file) and studio-notes.txt (the band's notes, where
  each sits and its version). The maker shares that one folder from Drive (anyone with the link, Editor; an expiry or password where the plan
  offers one) and sends the link. The client plays the mix in the browser and adds lines ("1:32 the vocal is quiet", "bar 17 ...", or a line
  for the whole mix) to comments.txt: in Drive by downloading, editing and uploading it back (Keep both is fine: every .txt there is read), in
  OneDrive or Dropbox in the browser. The maker's StudioSync (only theirs: one writer) reads them into Notes each minute while the Mixes page is
  open, or on Look for comments, as notes from "<name> (client)" on the version the link was made from, and rewrites studio-notes.txt.
  For an older version: open it in a side room, Render current mix there, then make the link for that mix.
- **Client links, the other way: a page from the web UI.** When the web UI serves pages, a link page can play the mix in the browser with the notes
  as markers on its waveform and a comment box that posts straight in (no file to download and upload). review.data(cfg, song, link) is the hook:
  the mix's path, the client's comments as read, the studio's notes. It needs a way in from outside the tailnet (Tailscale Funnel, or a relay),
  with the page served alone (never the studio folder) and the link's own expiring token: that's the work left there.
- **Left out:** a fork's notes don't show its original's older notes; a client's bar is counted on the tab in front's tempo map, and the mix is
  taken to start at the song's start (as Render current mix renders it).
- **REAPER test:** Fork song from main (square says "fork of main"); Restore > a saved version > Fork from here (the fork is the song as it was);
  in the fork move an item, add a track with an item, then Compare with main: counts per track, untick the new item, Bring into: only the rest
  arrives; tick only the item: its track comes too. Adopt as main (main open, you drive): "main before <fork>" appears and holds the old main,
  main now matches the fork on another computer too, Restore in main can go back. Notes: add one on an item, save a version, edit that item:
  the note says "made on version N; that spot changed since". Client link: Render current mix, Make a client link, edit comments.txt in the cloud
  folder, wait a minute on the Mixes page: the comment shows in Notes as from the client, and studio-notes.txt lists it.

## Colour parity (James, 2026-11-19: "everyone should share the same colours for tracks and everything")
Track and item colours already travel as edits, and Colour the project recolours for everyone. What still differs between computers:
- local overlays: who's-working colours painted over tracks on some computers and not others;
- the theme: one track colour looks different under different themes (tinting, brightness), and theme colours are "never shared";
- personal colour preferences (MIDI note colouring, take/region colours, auto-colour for new tracks);
- each person's own colour, which should be the same on every computer.
Plan: a studio "Colour parity" setting (on by default) that keeps the project's colours identical everywhere (overlays become a badge,
not a recolour), shares the colour-affecting display settings with the studio preferences, fixes each person's colour studio-wide, and
checks parity in Health.

## Parallel round 1, merged and checked (0.59.49.19, extension 1.0.12, 2026-11-19)
Seven agents, each in its own worktree and branch (rt-cloud2, rt-linkspeed, rt-webui, rt-health, rt-streamideas, rt-forks, rt-ablink), merged
into realtime; offline suite `fails 0`; rt_settings/rt_prefs/rt_takes green on desktop, laptop and Mac; cross test PASS (every change
0.2-0.6 s; the test now starts its tempo steps from the song's start and drops its own "(yours, not sent)" leftovers).
- **Link speed (1.0.12):** frames in flight per peer. The 20 MB catch-up that took 23 s: 2.85 s ask to placed (~7.4 MB/s); the desktop
  measured 9.7 MB/s to the laptop, window 26, 55 ms round trip. Health shows each bandmate's speed and path.
- **Web UI, first slice:** http://127.0.0.1:47281/ shows the song, who's here and the project chat ("live"); a message sent from the page
  went into the normal chat store and reached the laptop and the Mac. Phone link over Tailscale with the studio's web token: not tried yet.
- **Health:** Syncthing per studio (state, needs, each bandmate's completion, errors) and disk space here and on bandmates: read right on all 3.
- **Cloud copy part 2:** end-of-session projects kept to the newest 10 per person and room; the studio's signed update files through the cloud
  copy (members bring a strictly newer signed version, dated as the cloud's so an owner's newer version wins a Syncthing conflict); a
  Health hint where there's no cloud copy. Not exercised in REAPER yet.
- **Streaming ideas, forks and notes, Ableton Link:** merged, offline-tested; their REAPER checks (punch marks, late joiner, producer level,
  format hint; fork/compare/adopt, versioned notes, client links; Link with a phone app) are next.
### Colour parity, built (rt-colours branch, 2026-11-19; offline tests only, not run in REAPER yet)
Audit: does each colour reach every computer identically?

| What | Before | Now |
|---|---|---|
| Track colour | Travels (track state `color`, Windows byte order, SWS auto-colour off while a studio song is in front). A who's-working or what's-new colour could be painted over it here (held in `P_EXT:band_colour`) | Colour parity on: never painted over; any left from before goes back |
| Item colour | Travels in the item chunk (`COLOR`, either byte order, normalised for hashing) | Same |
| Take colour | Travels in the item chunk (`TAKECOLOR`) | Same |
| Marker and region colour | Travel with the timeline, but a reset to the default colour never arrived (SetProjectMarker4's colour 0 means "leave it") | Fixed: a default colour is set through SetRegionOrMarkerInfo_Value |
| Ruler lane colour | Travelled native: a Mac's red lane showed blue on Windows | Fixed: travels in Windows' order like markers |
| Master track colour | Not sent (mirror sends the master's plug-ins and envelopes only) | Fixed: travels with the song's settings (`master_colour`) |
| Folder/child shading | Not project state: the theme (tint parameters such as Reapertips' `tint_folder_label`) and `tinttcp` | Shared as preferences and theme colour settings (below) |
| Envelope and automation-item colours | No such project state: envelope colours are the theme's (`col_env*`), automation items have no colour | Nothing to carry |
| Pooled MIDI colour (`POOLCOLOR`) | Kept local, as pool numbers are each computer's own | Same (tinttcp &1024, now shared, colours pooled items the same way) |
| MIDI note colouring (velocity/channel/pitch/track) | Per take in `CFGEDIT`, which stays local (it also holds the editor's zoom and view); the default for new editors is `[midiedit] colorwhat` in reaper.ini, not a config variable | Not shared: needs `CFGEDIT` split into view and colour parts in mirror. Notes coloured "by track" use the track colour, which does travel |
| Each person's colour | Picked colours studio-wide, but defaults by name order over members plus whoever this computer also knew of (a guest in a room, someone who drew), so one extra name moved everyone after it on that computer only | Defaults over members first, extras after; a person with no pick has today's default kept in their own `_band/colours/<user>.json` (`auto`), changeable by them |

Built:
- **Colour parity** (band.json `colour_parity`, on unless false; owner and admins; Settings > Studio > Colour parity, lib/colours.lua `parity_ui`).
  On: lib/people.lua `paint` never recolours a track (who's working shows in Who's here, "Working in ...", and in claim regions); Settings >
  Colours says the studio's choice wins. Off: today's behaviour.
- **Colour display settings** in lib/sharedprefs.lua's list as group "colour", in force only while Colour parity is on: `tinttcp` (track
  label background, tint track panels, tint item peaks and backgrounds by track/item/take colour, auto-colour new takes and pooled MIDI),
  `selitem_tintalpha`, `unselitem_tintalpha`, `specpeak_huel`, `specpeak_hueh`. Names from REAPER's config table in reaper.exe and Mespotine's
  reference. Turning parity on shares this computer's values where none are chosen.
- **The theme's colour settings**: ThemeLayout_GetParameter/SetParameter exist in REAPER's API (reaper_python.py). Shared only to computers on
  the same theme, only tint and coloured-name parameters (not panel background colours), set with persist off so reaper-themeconfig.ini is
  never written; applied and put back by sharedprefs' existing tick as `theme:<cfg>` keys. Theme choice, layout and zoom stay personal.
- **Health: Colour parity row**: each computer puts what it shows in its status file (`look`: a fingerprint of the project's colours, its
  theme, colour preferences and theme colour settings, any overlay); the row names what differs ("Mac tints track panels and items
  differently", "Mac uses another theme"), project colours only after 30 s apart.
- Tests: tests/test_0_60_rt_colours.lua.
- **Colour parity checked (0.59.49.20):** Health's row green on desktop, laptop and Mac ("every computer here shows the project's own colours,
  alike"); the master track's colour set on the desktop showed the same RGB on the laptop and the Mac (the Mac's colour byte order handled),
  and a reset to no colour reached both; rt_prefs (41 checks, the colour group included) green on all 3.
- **Round 1 features checked in REAPER (0.59.49.20):**
  - Punch-in assist: with time-selection auto-punch and one bar of pre-roll on the desktop, the laptop and the Mac showed "[punch] James punches
    in-out" (3.69-7.38 s) and a pre-roll marker one bar before; both went at stop; none reached the band's markers or an event file.
  - FLAC hint: In time at 1 bar on a FLAC project gives the yellow row (2-5 s steps, use 3 bars or WAV); 3 bars clears it.
  - Forks: "XT Fork" made on the desktop, listed as "fork of main" on the laptop, its room.json carrying the origin and version; its tab
    closed without saving. Compare/adopt not run (adopt rewrites main: a test room of its own first).
  - Client links: the link's folder made in the Google Drive copy with the mix and comments.txt; a client line came back once as a note event
    (and never twice). studio-notes.txt lists notes from the panel's history cache, so it fills in from the Mixes page, not a bare script.
  - Not yet: late joiner and producer level (need a mid-take join), cloud update files (the test studio has no update key: deploys
    unsigned), Ableton Link (needs a Link app on the LAN).

## Efficiency pass (rt-perf branch, 2026-11-19; offline tests only, not run in REAPER yet)

James: keep making StudioSync "better or more efficient". Every feature that landed today adds work to Live sync's tick (a REAPER defer, about
30 a second per tab) or to the panel's frame. What each does, how often, and whether it's gated on being needed:

| Work | Where | How often | Cost | Gated? |
|---|---|---|---|---|
| Heartbeat "live <tab>", owner check, binding | Live sync tick_body | every tick | 8 GetProjExtState, 1 SetExtState | always (it is the heartbeat) |
| lap() timing marks | Live sync tick | ~12 a tick | was a string.format each; now two numbers | **fixed**: words only for a slow or timed tick |
| sws colours, open FX chains, peaks | Live sync tick | 1 s | every track's FX open state | 1 s |
| update check, lock, Save As follow | Live sync tick | 5 s | 512-byte read | 5 s |
| plug-in lists signature | Live sync tick_body | 120 s | listing + sizes | 120 s |
| shared prefs | lib/sharedprefs.lua tick | 1 s, tab in front | ExtState JSON, a pref read per key | 1 s |
| direct.live_tick: file poll, inbox prune, peers, clock, heartbeat, messages | lib/direct.lua | every tick | DirectPoll loop; DirectClock JSON decoded every tick; prune 10 s; peers 2 s; heartbeat 5 s | extension present; **clock decode memoised** |
| shared_now | lib/direct.lua | each cue, each streamed take, Link's 10 a second | DirectClock decode + an ExtState write each call | **fixed**: decode shared, write on change |
| Ableton Link | lib/ablink.lua tick | 0.1 s | Blink calls, status ExtState JSON 1 s | Link on, tab in front |
| Web UI | lib/webui.lua tick | every tick in front; presence 1 s; chat 2 s | sync.authority (claims files read) + JSON encode each second | extension present, tab in front; **not** on a browser being connected (see problems) |
| Cue watch | Live sync quick_transport | 0.25 s with peers, 2 s alone | JS_File_Stat; a listing when the folder moved; a seen_ev lookup per name | yes |
| hear, rt_sends, join check, follow_claims, producer | Live sync tick_body | 1 s | small | 1 s |
| live MIDI send / receive | lib/livemidi.lua | tick in front while recording / 0.5 s | MIDI input history | recording / not recording |
| streams: send, receive, catch-up, media | lib/streams.lua tick | every tick, inner 0.1 s / 5 s | DirectStreams JSON decoded by receive and media in one tick | recording / book non-empty / peers or cloud; **streams decode memoised** |
| The pass (poll) | Live sync | 0.5-2 s, never while recording | below | edits, recording, Live set, undo wait |
| P.who | poll | each pass | session.json read, sync.authority (claims files read), presence, api.publish (JSON) | no |
| P.look: timeline + mirror.watch | poll | on change, 10 s floor, a fifth of REAPER's time at most | every track and item | yes (change count, look's own time) |
| outbox ExtState | poll | each pass | JSON encode + write | written each pass (left: one a pass, reader reads content) |
| P.heal + P.status: mirror.root | poll | **twice** a pass | every object's revision, sorted and hashed | **fixed**: once a pass |
| P.status: armed, fingerprint, write_status | poll | each pass; write on change or 15 s | write reads its own file back (name clash), colours.look 5 s | write on change |
| drive pass | poll | 3 min / 30 s after a send / on demand | 0.1 s copy budget | yes |
| TrackList_AdjustWindows + UpdateArrange | poll | each pass | a full redraw | no (see problems) |
| Health rows | panel, Health tab | **every frame** | session.json read, switch marker read, every track's 26 group settings x2, direct status decode, ... | **fixed**: once a second; heavy part already 10 s |
| Health level (sidebar dot) | panel | 2 s | the same build | 2 s |
| rthealth Syncthing rows | Health | 10 s, curls in the background 20-300 s | REST JSON | yes |

Changed (one commit each; behaviour the same):
1. **Timings for before/after** (`ExtState "perf stats"`): Live sync publishes "tick stats <tab>" every 10 s while it's on: median, p95 and
   slowest tick and pass, and the slowest tick's laps. Off, one comparison a tick. `tests/reaper/rt_perf.lua` switches it on and reads it.
2. **lap()** keeps name and seconds, formatted only when a tick is slow (>0.15 s) or timed: saves ~12 string.formats a tick (~360 a second a tab).
3. **direct**: the extension's JSON answers (DirectClock, DirectStatus, DirectStreams) decoded once while the raw text is unchanged, and
   shared_now writes "direct reference" only when it changes. A 3-peer status decodes in ~50 us offline (tests/test_0_60_rt_perf.lua prints
   it); keep_clock decoded the clock every tick and each shared_now again (Link alone: 10 decodes and 10 ExtState writes a second).
4. **mirror.root once a pass**: P.heal's answer goes to P.status unless it healed. On a 3,000-object song that's 3,000 EnumProjExtState calls,
   a sort and a hash saved per pass.
5. **Health rows once a second** while the Health tab is open (was every frame, ~30 a second): a button (H.maint_at), another tab, song or
   studio builds them again at once.

Measure in REAPER: run `tests/reaper/rt_perf.lua` once (switches the timings on), leave REAPER as you want it measured for 20 s or more, run
it again. It prints each Live sync tab's tick and pass median/p95/slowest and the slowest tick's laps, and times mirror.root,
presence.track_groups and direct.status on the tab in front. For before and after, run it on commit "Live sync: tick and pass timings"
(ded837f, timings only) and on the branch tip, same project, same state (alone/with others, idle/playing, Health open or not).

Problems found, not fixed (risky or a behaviour change; for James to pick):
- **Web UI builds every second with nobody looking**: lib/webui.lua starts the server and builds presence (sync.authority reads every claims
  file) and chat each 1-2 s in the tab in front whenever the extension has the web UI, browser or not. StudioSync_WebUIStatus has `clients`;
  gating on it would leave a first page load up to a second stale. The docked web view (another branch) would be a permanent client anyway.
- **sync.authority reads every claims file uncached**, each pass (P.who) and each second (web UI): a listing plus one read per member.
  A cache by listing and file size/time would do; it decides who may change what, so not touched here.
- **UpdateArrange + TrackList_AdjustWindows every pass** whether or not anything changed: a full arrange redraw every 0.5-2 s per tab.
  Calling them only after a look/receive/heal/paint changed something needs every writer known.
- **Unbounded growth** (all per REAPER session, small entries): Live sync `seen_ev` (every event file name, seeded with the whole folder:
  20,000 in a big song, never drops trimmed ones) and `fired`; sync `refused_at` (lib/sync.lua, never cleared); streams `asked`,
  `sent_media`, `placed`, `streamed` (one per media file or take, never pruned); recall `ev_cache` (the Restore page, every event path read;
  states lazy); mirror `fx_open_at` (per track pointer). None is a leak at today's sizes; a session of days would show them.
- **The cue watch walks every name** in the events folder each time it lists (a hash lookup per name, 20,000 in a big song) to find the new ones.
- **Catch-up with a cloud copy and nobody on the link** asks Syncthing's need list (a background curl) every 30 s for as long as you're alone,
  as `cloud_asked_at` moves only when a wanted file is found in the cloud.
- **The stream trace** (`stream trace` = 1, testing) appends to <home>/direct/stream_trace.log with no size limit.
- **presence.lua `last_time`** is keyed by user only, not song/room: one person in two rooms at once (two tabs) would share one "last changed" time.
- **write_status reads its own file back** on every write (the two-computers-one-name check): only needed every 45 s.
- **Signed updates on, and through the cloud copy (0.59.49.21-23):** Smiley Studios has an update key (made on the owner's desktop with
  fromfolder.create_update_key; the key file stays in the owner's home folder, ~/.studiosync/update-key); every computer logged "signed with
  the studio's update key: used" and refuses unsigned code. With the Mac cut off from the desktop and laptop in Syncthing, a new signed build
  reached the cloud copy in ~25 s, and the Mac logged "StudioSync 0.59.49.23 came from the Google Drive copy into the studio's folder" 159 s
  after the deploy, then ran it. No conflict copies once Syncthing was resumed; the Mac's folder idle with nothing needed.
- **Timings (rt_perf.lua, 0.59.49.24, the small Cross Test song, idle):** Live sync tick median 0.7 ms desktop / 1.5 ms laptop / 3.4 ms Mac
  (p95 1.9 / 14.4 / 6.3 ms); pass median 11 / 13 / 2.6 ms. A big session is the next thing to measure.
- **LinuxBox joined Smiley Studios** (James, 2026-11-19): extension 1.0.12 installed in the VM's portable REAPER, joined with the owner's
  join code (services.join_band), let in from the desktop; the signed 0.59.49.24 code arrived first. No Tailscale on the VM yet, so no direct
  link there (Syncthing over the LAN): installing Tailscale adds a device to James's tailnet, his call.

## Round 2 merged and checked (extension 1.0.13, 0.59.49.25, 2026-11-19)
- **Hop plug-in in REAPER (desktop, CLAP):** REAPER's PDC reads 7200 samples (the reported latency). The extension's loopback at 512
  samples: returns trail sends by exactly 512 and the late counter stops; at 9000 (over the 7200 budget) the counter climbs and timing holds
  (dry at the same latency); stop works. The VST3 isn't listed until REAPER rescans its VST paths (the CLAP folder is new, so it was scanned).
- **CLAP folders:** desktop and laptop add `<drive>\Portable Workstation\DAW\Plugins\CLAP` to clap_path_win64 (set while REAPER was closed by a
  small helper REAPER starts before quitting); Mac ~/Library/Audio/Plug-Ins/CLAP, LinuxBox ~/.clap. The Hop is on all four (VST3 + CLAP).
- **Docked web UI (desktop):** StudioSync_WebUIDock(1) opens it (action toggled on, no error); WebView2 runs with its own data folder under
  REAPER's Data\StudioSync\WebView2 and the page loaded (1 client, 5 requests). Closed again with StudioSync_WebUIDock(0).
- **LinuxBox:** Tailscale installed (official apt repo) and signed in as linuxbox.tail99132c.ts.net; extension 1.0.13; Cross Test open with
  its direct link listening and all three peers reached.
- **Live audio:** in 1.0.13 on Windows and Linux; the Mac build waits for a fix (macOS CI: a peer given the right secret while running is
  never heard; Windows/Linux hear it 103 ms after). Not tried between computers yet: it needs the UDP rule beside the direct link's TCP one.
- **Live audio between computers (1.0.13, James OK'd the UDP rule 2026-11-19):** the direct link rule's UDP twin added on the desktop and
  laptop (same name, reaper.exe, 47281, 100.64.0.0/10). With the studio's Live audio on, desktop and laptop streamed to each other: round trip
  59-75 ms, latency 69-78 ms (35 ms buffer), loss 0, a few underruns at the start only, audio block work 0.1-0.23 ms. LinuxBox (PulseAudio in
  a VM) streamed at first (43 ms to the desktop over the LAN) then kept resetting with hundreds of underruns: a VM audio clock, not a real
  computer's. The Mac (1.0.12) has no live audio yet. Levels were 0 (nothing on input 1), so nothing was heard. Switched off again after.
  Next: an audible check with a mic or instrument on each end, then the hour-long run that's the roadmap's gate.
- **Live audio's macOS bug fixed (43e9839):** not the secret code: AOO's source jammed for good after a long stall (the macOS CI runner's
  ~60 ms VM pauses filled the resampler and queue, then process() returned overflow before moving anything). rt_capture flags the
  overflow and the send thread calls AOO's own reset; audio resumes on the next block (a click possible after a long stall, where before
  the peer went silent forever). CI green on every platform; 8 runs in a row on the Mac runner. The Mac runs 1.0.13 with live audio now.
- **Live audio on by default (James, 2026-11-19):** band.json "live_audio" is on unless false, as the direct link. Deployed with the
  mute/deafen/push-to-talk controls (rt-liveux), so no computer starts sending a live mic without a clear way to mute it.
- **Adaptive jitter buffer (2026-11-19):** the MacBook's stream flapped on every receiver (underruns ~2/s, buffer 35-100 ms) while its
  sender was steady: Wi-Fi's bursty delivery against the fixed 30 ms buffer. Now each peer's buffer starts at 30 ms, grows +20 ms on an
  underrun up to 150 (AooSink::setLatency at runtime, inside the gap the underrun already made), and shrinks -10 ms after 15 s with no
  underrun, every 10 s, only while that peer is quiet (a re-buffer is a short gap) and not below a size that underran in the last 2 minutes.
  Sound fades in over one block after any gap; "streaming" stays true for 2 s through a re-buffer; an underrun after a pause over 1 s
  (talkback, a stalled sender) doesn't grow it. Status per peer: target_ms, floor_ms, ceiling_ms; StudioSync_LiveAudioPeerBuffer sets a
  peer's bounds (Chat > Call > Jitter buffer, kept by name). Health: "Chilio 120 ms (buffer 85 ms (Wi-Fi?) ...)" with the wired-network
  hint. tests/rtaudio_test.cpp holds the receiver's socket 20-60 ms every 40-150 ms for 8 s: no underruns after settling, streaming never
  false, back to 30 ms once quiet. Refusals now name the sender (status last_reject_from, Health "from ip:port").

## Session recaps and smart take names (rt-recap branch, 2026-11-19; offline tests only, not run in REAPER yet)
- **Recap (lib/recap.lua):** at each end of session (20 quiet minutes, Leave, Live sync stopping; right after the end-of-session version),
  a few bullets from the room's events, no new tracking and no model: who (event authors, this computer, who's here), how long (first to last
  change), takes (new items whose take has a smart name or REAPER's own: by whom, track, section), tracks added/removed, tempo/marker changes,
  insert/remove time, handovers, changes per person, notes, likes, saved versions. The window: the trailing run of changes with no gap over
  20 minutes, after this computer's last recap.
- **Who writes:** each computer its own view, in files only it writes (the studio's rule, as claims and status): `<room>/recaps/<user>.json`
  (its last 20) and, with a cloud copy, `<cloud>/<song>/recaps/<YYYY-MM-DD HHMM> <user>.md`. A single writer (the driver) leaves gaps when it
  leaves first, and one shared file makes Syncthing or cloud conflict copies. Restore page: **Last session** (folded) shows the room's newest
  recap, "as <user> saw it": whoever left last saw the most. Each computer logs its own one-line summary.
- **Smart take names:** when a recording stops, each new take on an armed track that still has REAPER's name (empty, the recorded file's,
  "untitled MIDI item") becomes "<region, else marker> - <player> - take <n>", n per section and player across the song; renamed before the
  next look, so it goes out with the take's first send. Studio setting, on unless false: band.json `smart_take_names`, Settings > Studio.
- Tests: tests/test_0_60_rt_recap.lua.
- **REAPER test:** record over a region: the take reads "Verse - <you> - take 1" here and on a bandmate; again: take 2; type a name, record
  elsewhere: the typed one stays; Settings > Studio off: REAPER's names. Leave: the log's "last session (...)" line, Restore > Last session,
  `<room>/recaps/<you>.json`, and the .md in the cloud folder's `<song>/recaps`.

## Live audio, my mic (rt-liveux branch, 2026-11-19; offline and native tests only, not run in REAPER yet)
Live audio is on in every studio now, so it has to be pleasant and safe (lib/liveaudio.lua "My mic").
- **Mute me / Deafen:** kept per computer; in the panel's top bar (the mic says Mic live / Muted / Muted (you're talking) / Push to talk /
  Talking / Deafened / Talkback: Bo), Chat > Call, and as actions (StudioSync - Live audio mute me, deafen; toolbar buttons light while on).
  Deafen also stops sending, as call apps do.
- **Push-to-talk and hold to talk:** StudioSync - Live audio hold to talk (js_ReaScriptAPI sees the key let go; 0.25 s tail; a latch from a
  toolbar button or pad) and Chat > Call's Hold to talk. A held key is a beat in ExtState that runs out in 0.6 s, so a crashed script never
  leaves the mic open. Held talk opens a muted mic while held.
- **Talkback:** Talk beside a bandmate in Chat > Call, or StudioSync - Live audio talkback (to the last one chosen): only they hear you.
  Quiet while this computer records (James's pick above). Without the extension's per-peer send, talkback sends nothing, never to everyone.
- **Defaults:** hearing others on; sending on, with a first-run note ("Live audio is on", until Got it) and an echo warning (a loopback input
  such as Stereo Mix, or REAPER monitoring the input sent while it's live) that offers Mute me or "It's headphones".
- **Cue mix:** a master volume (Everyone) over each bandmate's level; levels kept by bandmate name (the link's peers now say whose computer
  each is), so a renamed or new computer keeps its person's level. A mix kept by address before still counts.
- **Health:** "hearing Bo 68 ms (buffer 30 ms, loss 0.0%), muted; Chilio not connected: needs extension 1.0.13": each computer's status file
  carries `la` (on, muted, deaf, ptt, or why it can't run: ext, tailscale, firewall).
- **Extension:** StudioSync_LiveAudioSend(peer, on) (rtaudio.cpp rt_send): peer "" sends silence while the stream stays up (the meter still
  reads the input); a peer is left out of the source (AOO deactivates that sink). Native test: unmuted heard again after 46 ms, a peer let
  back in after 43 ms. Without it, Mute me restarts live audio on an input that isn't there; push-to-talk and talkback wait for it.
