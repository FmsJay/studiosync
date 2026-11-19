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

### 5. Video and screen share
- The extension serves a small page on this computer and opens it in the browser; the browser's own WebRTC does
  camera and screen share, peer to peer over Tailscale; the link carries the setup between computers. No outside
  service. Can share the REAPER window.

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
- **Presets and small content:** your own presets, IRs, amp captures and drum maps sent to bandmates who need them for a
  song (never plug-in binaries or paid libraries).
- **Distributed bounces:** stems and mixdowns split across the computers that are idle.
- **Record from a phone:** a singer with only a phone opens the studio's web page and records a take straight into the
  song, in time from the shared clock (browser recording), arriving fast-first-lossless-after.
- **Crash-safe sessions:** the extension keeps the last unsent changes safe even if REAPER crashes mid-session.

### New scopes to explore
- **Without Tailscale:** an optional built-in connection (NAT traversal with a small rendezvous) for bandmates who
  won't install Tailscale.
- **Beyond REAPER users:** through the web UI and browser recording, people without REAPER can listen, comment and
  record parts into a song.
- **Live to an audience:** stream the band's live mix to listeners on a web page.
- **Lessons and producing for clients:** a teacher or producer sharing their REAPER, drawing and talking over it.

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
2. **Shared CPU.** The remote plug-in mechanism (4b) also works for plug-ins you DO have: freeze or offload a heavy
   track to whichever computer is idle.
3. **Follow a bandmate.** See exactly what they see: their view, cursor, selection and open editor, live.
4. **Listen from anywhere.** A link from the studio to a browser page (phone, client, a bandmate away from REAPER) that
   plays the live session or the latest mix, peer to peer over Tailscale.
5. **Shared controllers.** One person's control surface or MIDI controller moving faders and knobs in everyone's
   session (through the live layer and claims).
6. **Joining without Syncthing's device approval step.** The link can carry the invite and the first copy of the song,
   so a new member is in within seconds.
7. **Everyone records their own part in full quality during a jam.** While playing live together (heard as Opus or
   intervals), each computer records its own input locally, and the lossless takes replace the live ones afterwards,
   lined up by the shared clock (the "double-ender" way podcasts are made). The jam becomes a real multitrack session.
8. **Latency calibration per person.** A one-time loopback measurement of each computer's audio interface, so parts
   recorded against a bandmate's stream land exactly on the grid.
9. **"Bo is editing this" before you touch it.** Live claims shown on the track/item as soon as someone starts
   editing, so clashes mostly don't happen.
10. **Timeline comments.** Notes pinned to a bar or region, live, like comments in a shared document.
11. **Personal monitor mixes.** Each person sets their own mix of everyone's live audio (more click, less guitar)
    without touching the song's mix.
12. **Song history playback.** Scrub through how the song evolved, change by change, and restore any point.
13. More ideas get added here as the steps land.

Latency calibration (8) is mostly automatic: REAPER already compensates recording for the driver's reported latency on
each computer, and StudioSync compensates the network part continuously from the shared clock. The loopback test is an
optional precision step for drivers that misreport by a few ms.

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

### Web UI: what remains (TODO)
- **Docking:** a dockable REAPER window hosting WebView2 (Windows), WKWebView (macOS), WebKitGTK (Linux) that opens
  `http://127.0.0.1:<port>/`: the server is already its message channel, so no second bridge. Needs the WebView2 SDK download: James's
  OK first. Then keyboard focus and REAPER's shortcuts with the view docked.
- **Pages, then parity:** scopes and to-dos/links in chat, Health, Play together; the ReaImGui panel stays until each page matches.
- **Shared DAW view, view-only first** (stage 1 above): tracks, items, markers and cursors from the synced model, follow, play/stop.
- **Video and screen share** (step 5) over WebRTC inside the view; the Studio browser after it.

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
- **Song to-dos.** A small task list per song ("retrack bridge vocal"), tied to tracks and bars, ticked off by anyone.
- **Synced visuals.** Big count-in, bar/beat and section display for everyone, from the shared clock, so nobody
  misses an entry when recording together.
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
- **Web UI:** webview (MIT) or Saucer (MIT), not CEF; WebView2 accelerator keys forwarded to REAPER; Linux may fall back to the
  system browser (SWELL windows aren't GTK). Yjs (MIT) for the song sheet, chat, comments and to-dos; Excalidraw (MIT) for
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
