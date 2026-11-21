# Backlog for the realtime branch (rt-backlog 2026-11-20; brought up to date by rt-triage, 2026-11-21, at 8b4c064)

Gathered from every note in `docs/rt/`, from `docs/realtime-roadmap.md` and from the commit log. The first version (4ed39be, then dd2ebe2) was
written on 2026-11-20. rt-triage re-read the 80 commits since (`git log --since=2026-11-20`) and the notes they touched
(`handoff-2026-11-21.md`, rt-edits rounds 5-7, rt-answers, rt-drive2, rt-perf and rt-perfcut1-3, rt-hubsmall, rt-hubrank, rt-hubwatch,
rt-hop2, rt-history2, rt-draw2, rt-linkmove rounds 3-5, rt-stream). Nothing here was run or re-tested by rt-triage: each line is what its
source says, with the source in brackets. "Checked" means a note says it was run in REAPER on real computers; "built" means offline tests only.
The tracker artifact (https://claude.ai/artifact/RmbRPbT1TtwVAL3yZMgtFD) was not consulted: where it holds a later REAPER result than the notes, the
notes win here until someone copies the result over.

Layout: **Plan to finish** (new, below) -> **Closed since** -> 1 Bugs and limits (open only) -> 2 Built, not yet checked -> 3 Features designed
or half built -> 4 James's questions (with a default for each, so nobody waits) -> 5 Security: review later (held; kept as written, new items
appended) -> 6 Rig and CI notes -> Stale or contradictory. Open items carry a number (`1.7`, `2.12`...) that the plan's packages refer to.

## Plan to finish (2026-11-21)

### What still truly needs James

Only two things are his alone, and everything below is arranged so that nothing else waits on him:

1. **The security review** (section 5), held until every feature is in. It comes last.
2. **A real-life band test**: people in different places playing real instruments, for feel and for an hour, with the studio as they'd use it. The
   agents' harnesses (below) prove timing, levels, dropouts, convergence and recovery; they can't judge whether it is pleasant to play on.

Five physical or account things the automation can't reach. Each is small and goes into the band test's session as a short list, not a project:
an iPhone and Safari (listening links, video thumbnails); a real USB MIDI keyboard into a phone's Web MIDI; the real home router and ISP
(CGNAT, a port forward, section 4 item 2); a real audio interface in a browser guest (the UR22); the tailnet policy for Funnel (public listening,
section 4 item 1, off by default). The Mac is out of testing again (since 11-21 10:39); its items wait until it is back. **Local models:** the
AI add-on's runs each need James's yes (standing rule), a click, not testing.

Not needing James, though they look like questions: section 4 gives every open question a default that is built or kept reversible, so a package
can go ahead and James can overturn it later.

### How the "needs James" tests get automated

These are section 2's former "needs James present" items. The harnesses built first (wave 0 below) are what turn them into scripted runs.

- **`tools/ears/` (record and compare; being built now, see its docstring): live audio, Jam, the full-quality copy, solo / their time / produce,
  Hop tails.** A known pattern (`ears.py pattern`: tone ladder, impulses, a band excerpt over a -60 dB bed) goes in at one computer through an
  armed tone track or REAPER's player (no real microphone; the desktop's Voicemeeter bus and the Mac's real mic stay deafened). Each other
  computer's output is read back by `ears.py env` (the extension's status polls: counters and levels) and, where sound is needed, by a
  capture tap (a REAPER track recording the master, `ears.py wav REF GOT`: delay, level, gaps, spectrum). `ears.py tail` checks that a note's
  tail ends within the bound after its note-off: that is the Hop 0.2.1 by-ear check, without ears, even under injected loss (below). Jam's
  "lands within 10 ms of its place" and the full-quality copy's claps-line-up (note the offset in ms) become numbers with pass/fail. The
  hour-long gate is the same run left alone for 60 minutes, reading the counters every minute.
- **LinuxBox and more VMs (`vmrun -T ws start "J:\VMs\LinuxBox\LinuxBox.vmx" nogui`):** a third and fourth computer for every
  "two or three computers" test, with its own REAPER, its own Syncthing, and a clock that can be pushed (+5000 ppm already). On a VM, packet
  loss, latency and a blocked link are `tc netem` and `iptables`: so rt-hubrank's partial reach (block 47281 between two), rt-hubsmall's
  "go late at each other", Hop's lost-twice, the two-hops loss and the Wi-Fi-like gaps are scripted, not firewall edits on the real computers.
  Needs James's one-line OK, as the 11-21 Syncthing-paused test had, for each kind of network change on the VM (never on the desktop or laptop).
- **A router VM for "Connect without Tailscale":** a small Linux VM on a VMware custom network that NATs the LinuxBox (and a second VM) onto
  the desktop's subnet: full-cone, address-restricted, symmetric (random ports) and double NAT (CGNAT) are `iptables` modes, hairpin is a rule,
  a "network change" is `ip link` down and up, and the hour-long gate runs with Tailscale stopped in the VM. That covers rt-nat2/rt-nat3's
  stages 1-3 and "guest without Tailscale" without a router port forward; only the real router and ISP are left (above).
- **The S23 over adb (listening links on a phone, phone keys, phone Project view, history on a phone, chat on a phone):** Chrome on the S23 is
  driven from the desktop by `adb forward tcp:9222 localabstract:chrome_devtools_remote` and Playwright's `connect_over_cdp` (real touch, real
  Chromium engine, the studio's Tailscale name); `adb shell input` taps pads; `adb shell svc wifi disable` (Shizuku/rish) kills the link for the
  stuck-note and revoke tests; what the phone plays is recorded on the desktop with scrcpy's `--no-video --audio-source=playback --record` (the
  Phone audio tool does the same through the hub) and compared by `ears.py wav`. Firefox 130+ needs an install on the phone (a download: ask).
  Safari is not testable this way (an iPhone or the Mac's Safari: James's list above).
- **Chromium with fake devices (rules: never a real mic or camera) for browser guests, screen share, drawing, history and the web pages:**
  `--use-fake-device-for-media-stream`, `--use-file-for-fake-audio-capture` (the pattern as the "guest's voice"), `--auto-select-desktop-capture-source`,
  against the existing stand-in server pattern and against real Live sync on the desktop. The loopback measure, a take recorded by a guest, the
  share's crop, the "no echo of your own voice" check (the guest's own pattern must not come back in the mix: `ears.py wav` correlation), the
  Web MIDI page logic (a virtual loopback MIDI port, stand-in `MIDIAccess`) all run unattended.
- **Convergence soak (`tools/soak/`, new, recommended by docs/REVIEW-FULL-2026-11-18.md "the one investment"):** three REAPER instances on three
  separate folders (desktop, LinuxBox, a second VM) with a shim that delivers files late, out of order, half-written and twice, random edits
  from a seeded list, and an oracle that compares each object. Run nightly and before a release. It is the nearest thing to a band test that an
  agent can run, and it replaces most of the "edit matrix, 29 steps" by hand.
- **REAPER itself on the real computers:** the dev-eval hook (probes in the `bandtest` scratch folder; handoff "Where the tools are"), as used
  for every recheck so far. Each recheck run below writes its results into the doc whose checklist it ran, step by step (pass, fail, not
  run), so the next triage can close items from the docs alone.

### Work packages

One package = one agent round. **Files** are what the package may touch; packages that run at once share none (a small additive edit in a
shared file is named). **Kind:** offline = stand-in tests only; REAPER = a recheck on the real computers through the dev-eval hook; hardware =
needs the lab. **Model/effort:** Opus high for sync-core and design, Sonnet medium for scoped scripted work (as asked). C++ packages produce a
Windows build under a scratch name (`DLL_OUT`) and leave the release (version bump, Mac and Linux builds from CI, install) to the coordinator;
only one extension release per wave, so the C++ packages are written to be merged and released together.

**Wave 0: harnesses and rechecks of what is already built. Start now, alongside everything.** No `lib/` files.

| ID | Package | Items | Files | Kind | Model/effort |
| --- | --- | --- | --- | --- | --- |
| T1 | Ears: finish the record-and-compare harness, run it for live audio, Jam, the full-quality copy, solo / their time / produce and Hop tails | 2.18-2.22 (their harness, scripts, thresholds) | `tools/ears/*`, new `docs/rt/rt-ears.md` | offline first, then REAPER + the VM | Opus high (the thresholds are judgement) |
| T2 | Lab: LinuxBox start script, a second client VM, `tc`/`iptables` network recipes, the router VM, the S23's adb and CDP driver, scrcpy capture, Chromium fake-device launcher, a `run_check` wrapper that writes pass/fail lines into a doc | enables 2.7, 2.8, 2.22-2.31 | new `tools/lab/*`, new `docs/rt/rt-lab.md` | hardware | Sonnet medium |
| T3 | Convergence soak: three REAPERs, a late/out-of-order/half-written/duplicating shim, seeded random edits, an oracle | 2.1-2.4, 1.3, 1.8-1.10 (finds what the matrix misses) | new `tools/soak/*`, new `docs/rt/rt-soak.md` | REAPER + VM | Opus high (oracle design) |
| R0 | Recheck what is built and never checked, with the dev-eval hook: rt-answers checks 1-8 (install extension 1.0.34 first), rt-history2 1-6, rt-linkmove round 5 A-C (LinuxBox, Syncthing paused) and rounds 3-4, rt-hubrank 1-7, rt-hubsmall 1-6, rt-hubwatch (`stalls`), rt-edits 35-40, rt-merge 1-10, rt-claims, rt-nohold, rt-perfcut1-3, rt-draw2 1-10 (desktop browser) | 2.1-2.11, 2.13, 2.15 | docs only: writes its results into each note's own check list | REAPER | Sonnet medium |

**Wave 1: four at a time, files disjoint.**

| ID | Package | Items | Files | Kind | Model/effort |
| --- | --- | --- | --- | --- | --- |
| P1 | Sync core leftovers: plug-in chains merged per plug-in (FXID), dense CC ties, track deletion against an edit, a clash vs. a different piece for the web Project page and phone, the colour try's Put back, the claims countdown, a given claim released before Syncthing's copy (option b), act grouping on heavy songs, a hand-moved item just after a tempo change, pitch change = move, retire `mirror.settled`'s old-pair case if it can't happen | 1.1, 1.3-1.6, 1.8-1.10, 3.13 | `lib/mirror.lua`, `lib/sync.lua`, `lib/claimask.lua`, `lib/colours.lua` (try only), `lib/undo.lua`, `StudioSync - Panel.lua` (the claim chip's release only), `tests/test_0_60_rt_edits.lua`, `tests/test_0_60_rt_merge*.lua`, `tests/fixtures/editreaper.lua` | offline, then REAPER (edit matrix on three computers) | Opus high |
| P2 | Cloud copy: the leftovers from rt-drive2, and the modes (Standard's last mixes, Essentials' multi-take items, a member without a cloud folder, the size limit asking, the copy carrying `session.json`/`room.json`/`band.json`, inactive takes), `sessionfile.catch_up` off REAPER's thread | 1.34, 1.35 (all but `streams.lua`, P3's), 3.14, 1.30's list-only songs' `session.json.sig` | `lib/drive.lua`, `lib/drivebg.lua`, `lib/trim.lua`, `lib/cloudmodes.lua`, `lib/sessionfile.lua`, `lib/songsync.lua`, `lib/band.lua` (a small cache, additive), `tests/test_0_60_rt_drivebg.lua`, `tests/test_0_60_rt_cloudmodes*.lua` | offline, then REAPER + Google Drive (desktop's G:) | Opus high (it removes data from a cloud copy) |
| P3 | Link-first leftovers: the need list on by default once checked, studio-wide files to peers outside Live sync's room, files over 32 KB in chunks, `driver.json` / `room.json` / room summaries / plays lists on the link, a person with two computers, list-only songs' `session.json.sig`, `nat:` peers' hello, the older-folder-copy-over-newer-link-copy race | 1.30 (all but the list-only songs' `.sig`, which is P2's), 3.3, 1.35's `streams.lua` cloud check | `lib/direct.lua`, `lib/needlist.lua`, `lib/signed.lua`, `lib/signedwrites.lua`, `lib/streams.lua`, `lib/presence.lua`, `tests/test_0_60_rt_linkmove*.lua`, `tests/test_0_60_rt_catchup*.lua` | offline, then REAPER (3 computers, Syncthing paused on one) | Opus high |
| P4 | Hop plug-in: knobs in pages beyond 256, Print's lead-in (pre-roll or loop; needs one REAPER experiment first), a try surviving a tab switch, two hops paced across the block | 1.17, 1.18 | `lib/hops.lua`, `lib/hoptry.lua`, `lib/webui/tryfx.js`, `extension/hop.cpp`, `extension/hopnet.cpp`, `extension/hopnet.h`, `plugin/*`, `tests/hop_test.cpp`, `tests/hopnet_test.cpp`, `tests/test_0_60_rt_hop*.lua` | offline + native + REAPER (two computers, a long link on the lab) | Opus high |

**Wave 1b: start as slots free; also disjoint from wave 1 and from each other.**

| ID | Package | Items | Files | Kind | Model/effort |
| --- | --- | --- | --- | --- | --- |
| P5 | Phone, home and chat: per-page MIDI channels (two phones, two tracks), program changes, step input as one undo point, phone-link notifications, "Open" from a page, mix times in one clock, chat uploads streamed and hashed off the main thread, home proposals the band wants (a status line, "since you were last here", mentions for several names, a cheap newest-messages read) | 1.25-1.27, 3.9, 3.12 | `lib/phonedaw.lua`, `lib/phonerec.lua`, `lib/livemidi.lua`, `lib/webhome.lua`, `lib/chatfiles.lua`, `lib/page_chat.lua`, `lib/webui/phonedaw.js`, `lib/webui/vkeys.js`, `lib/webui/home.js`, `lib/webui/chat.js`, `extension/webui.cpp` (upload path only) | offline, then phone (S23 over adb) | Sonnet medium |
| P6 | History, drawing, video leftovers: a drawing's removal hiding a file 10 minutes, the time lapse's comp areas, automation items on the master in the preview, automation placed under another tempo map, a restored item under another map (rate, fades), more than 16 video files' thumbnails | 1.12, 1.23, 1.28, 3.13b | `lib/webdraw.lua`, `lib/webui/draw.js`, `lib/webhistory.lua`, `lib/webui/history.js`, `lib/histhear.lua`, `lib/prep.lua`, `lib/video.lua`, `lib/webui/video.js` | offline + headless Chromium | Sonnet medium |
| P7 | Small: the audit's wording (4.3: "Play and stop together", "Watch <name>"), `startup.keep_open_mode` vs Autostart, `PreventUIRefresh` left on, ReaPersona's four suggested changes in its own repo | 1.36, 3.10, 4.3 | `lib/compat.lua`, `lib/startup.lua`, `lib/page_play.lua`, `lib/webpages.lua`, `lib/webui/play.js` (not `daw.js`: P14's), the ReaPersona repo | offline | Sonnet medium |
| P11 | Audio on the browser side: drift-correcting resampling in listening links, browser guests and the share's mix, the live indicator, guests heard by listeners, guests hearing each other (cap and take rules), the share's output pair / duck / system audio, controls beyond Home | 1.19, 1.21, 1.22, 1.24, 3.6 | `extension/audience.cpp`, `extension/audience.h`, `extension/rtaudio.cpp`, `extension/direct_audio.cpp`, `lib/audience.lua`, `lib/guest.lua`, `lib/guestweb.lua`, `lib/listen.lua`, `lib/webui/listen.js`, `lib/webui/guest.js`, `lib/webui/guestworklet.js`, `lib/webui/sharemix.js`, `lib/webui/audiencehost.js`, `lib/webui/guesthost.js`, `tests/audience_test.cpp` | offline + native, then lab (ears, Chromium fake devices, the S23) | Opus high |

**Wave 2: each after the wave-1 package whose files it shares.**

| ID | Package | Items | Files | Kind | Model/effort | After |
| --- | --- | --- | --- | --- | --- | --- |
| P8 | Perf cuts left in shared files: colour look only with colour parity on, the Project page reading only changed tracks, the status write's split, `start/link` and `band.songs` and live audio's merges, the efficiency list re-checked and each item done or dropped, and a heavy-song-with-real-plug-ins run with Live sync on | 1.2, 1.37, 2.15 | `lib/sync.lua` (`write_status` only), `lib/colours.lua` (`look` only), `lib/dawview.lua`, `StudioSync - Live sync.lua` (sub-laps only), `lib/direct.lua` (`live_tick`), `lib/liveaudio.lua`, `lib/band.lua` (`songs`), `tests/test_0_60_rt_perfcut*.lua` | offline, then REAPER (perf probes on the desktop) | Sonnet medium | P1, P3 |
| P9 | Hub: link-aware election (a computer with Syncthing paused isn't a second hub), a home that two bandmates can't reach (default below), guests' reach counted, a returning computer not named 15 s early, the mix host settled 30 s like the song's hub, the stall-learning `mix_gap`, a Wi-Fi listener kept through its own outage | 1.20, 4.d | `lib/hub.lua`, `lib/livex.lua` (host election only), `lib/rthealth.lua`, `lib/page_health.lua` (additive), `lib/presence.lua` (read only), `extension/rtaudio.cpp` (`hub_watch`; coordinate with P11's file: P11 first or one agent edits both), `tests/test_0_60_rt_hub*.lua` | offline + native, then REAPER + the lab (partial reach by `iptables`) | Opus high | P3, P11 |
| P10 | Joining: the first copy for every room and for files over 30 KB, a firewall note for a Windows joiner, the secret sealed again after a removal, invite links for someone not yet on the tailnet (or an honest message), one pending link at a time, Linux's `xdg-mime` default after untick | 1.29, 1.33, 3.2 (seal) | `lib/joinboot.lua`, `lib/joins.lua`, `lib/invite.lua`, `lib/urlhandler.lua`, `lib/band.lua` (join parts), `lib/webui/invite.js`, `lib/webui/join.js` | offline, then REAPER (scratch studio; LinuxBox as joiner) | Opus high | P2, P8 |
| P12 | Jam and the full-quality copy: a player heard from arrival, Opus or FLAC, drift stamps every second, play rates other than 1, MIDI and instrument tracks, takes recorded in "their time" moved, Produce's first second | 1.14-1.16, 3.15 | `lib/jam.lua`, `lib/double.lua`, `lib/producer.lua`, `lib/livex.lua` (jam/their-time parts), `lib/liveaudio.lua` (jam parts), `extension/direct_audio.cpp` and `extension/audience.cpp` (Opus and FLAC; P11's files, so P12 waits for P11), `tests/test_0_60_rt_jam*.lua`, `tests/test_0_60_rt_double*.lua` | offline + native, then lab (ears) | Opus high | P8, P9, P11 |
| P13 | Connect without Tailscale: SACK, a hub behind CGNAT, the relay's role not moving to a computer without the forward, a relay that stops relaying, Health's stale "can't reach" row, the hub's TURN for video-call pages, Health naming Tailscale-only features, phone pages without Tailscale (LAN listener, no microphone), invitations over a NAT link | 1.31, 1.32, 3.2 (A), 4.7 | `extension/direct.cpp`, `extension/nat.cpp`, `extension/nat.h`, `lib/nat.lua`, `lib/direct.lua` (peers/Health rows), `lib/webcall.lua`, `tests/nat_test.cpp`, `tests/direct_test.cpp` | offline + native, then lab (router VM, hour-long gate) | Opus high | P3, P8, T2 |
| P14 | Web Project page: what it can't yet do (deleting items, fades, sends, automation items, CC lanes); the Follow wording in `daw.js`; region playlists decided | 3.17, 1.11 | `lib/dawedit.lua`, `lib/dawview.lua`, `lib/dawmidi.lua`, `lib/webui/daw.js`, `lib/webui/pianoroll.js`, `lib/webui/daw.css`, `tests/test_0_60_rt_dawview.lua` | offline + headless Chromium; REAPER for each edit | Sonnet medium, one round a feature (4-5 rounds) | P1, P8 |

**Wave 3: after the decisions and the lab, each its own project.** Voice channels (3.1; 4 steps; Opus high; `lib/liveaudio.lua`, `lib/page_chat.lua`,
`lib/webui/chat.js`, `lib/webui/call.js`; after P5, P12). The AI add-on's remaining work and its model runs (3.5; one James yes per run; `lib/ai.lua`,
`addons/ai/*`; Sonnet medium). Fewer dependencies C, D, E (3.2): Syncthing removal (stage D, 8-10 sessions) is a gate decision (4.6); default: not started.
Remote control of a shared screen (3.7): design only; default: not built (a bandmate controlling another's computer is a security design first).
The pointer and notes over the sharer's real REAPER window (3.8): default: leave the preview.

**Recheck runs (Sonnet medium, REAPER + lab), each after its packages are deployed, each writing results into the notes' own checklists:**
R1 after P1 (edits, claims, merge; plus T3's soak). R2 after P3, P9, P10 (link, hub, join). R3 after P5, P6, P7 (phone, history, drawing, skip).
R4 after P2, P8 (cloud copy, perf). R5 after T1, P4, P11, P12 (sound, by `tools/ears`). R6 after T2, P5, P11 (the S23). R7 after T2, P13
(the router VM). R-final: everything above in one soak, then James's band test, then the security review.

**Order in one line:** wave 0 (T1, T2, T3, R0) now -> P1, P2, P3, P4 (and, as slots free, P5, P6, P7, P11) -> P8, P9, P10 -> P12, P13, P14 ->
wave 3 -> R-final -> James's band test -> the security review. Do not run more than about four agents at once: they share one worktree and every
package ends in `tests/run.py --no-luals`, which the runner now caps at 4 GB.

## Closed since the first version (and what each was checked with)

"Checked" = a note says it ran in REAPER on real computers. "Built" = offline tests only, no REAPER run recorded.

### Round 7 (deployed as 0.59.49.77-78; kept from the first version)
- A marker added in the first seconds after opening is lost: fixed, 46c2aae (kept on top of the newer timeline; checked in REAPER on LinuxBox).
- An older StudioSync renames a claimed track for everyone: fixed, 46c2aae (receivers judge it; checked in REAPER).
- Track order only repaired when a project opens, and Undo's stale `after`: fixed, 46c2aae (mid-session heal when idle and stopped; checked
  in REAPER, except "never while playing or within 10 s of an edit").
- A note or point moved by both ends up doubled: fixed, 46c2aae (checked in REAPER in Open mode).
- Section 3's "signing session.json and hub/<person>.json" and the welcome's sequence numbers: done, 173565b.
- "Still on Syncthing and could move to the link": given claims, releases, track order, hub handovers, session.json, profile pictures and the
  timeline files are link-first and signed (173565b, 0ecf1ff; link timing measured in REAPER, 0.03-0.15 s).
- Hub ranking by who reaches whom: built, 3ce9edb (baseline checked in REAPER; partial reach needs a link blocked: item 2.7).
- Drawing (Line, Box, Highlighter, undo, share notes kept, Mixer drawings on the time lapse): built, b9f5d06 (tools and undo checked from a
  desktop browser against three real computers; phone, share notes and the panel's look not checked: item 2.13).
- A claim given to someone whose name starts with the giver's and a hyphen was folded into the giver's own claims: 5cff73a.

### Sync core (rt-edits rounds 5-7; offline fixtures plus REAPER rechecks)
- Section 1, a timeline edit made right after updating, before Live sync's first look in the new version: fixed (round 5 W, 06eae9e); can't be
  checked in REAPER until an update bumps `TIMELINE_FORMAT`.
- StudioSync's Undo didn't step back a marker-only act: fixed (X, 06eae9e); REAPER check 35 ran in the 0.59.49.79 recheck (round 6 is built from
  its findings; per-step results aren't in the docs, item 2.4).
- Undo grouping across looks (a plug-in chain settling late, a script's edit to unselected items on two tracks): fixed for up to 70 s (`ACT_KEEP`,
  Y, 06eae9e). Left: heavy songs (item 1.10).
- Heal's changes made undo points on top of your list: now one "StudioSync: ..." point per heal, put-back and Keep (Z in 06eae9e; AG, AH in ea272dd;
  AK in 03361c8). Checked in REAPER: the 0.59.49.80 recheck passed 41-44 and 47 (AF-AJ), round 10 passed the Keep put-back (handoff, 07:05).
  Left: REAPER's own Edit > Undo still undoes such a point (item 1.7).
- Claims, deleting or moving several claimed things at once now asks (AA, 06eae9e; checked: Keep passes in round 10); `room_mode == "claims"`
  dead code removed (same commit).
- A note moved and resized at once by two people: one note (AB, 06eae9e; check 39 in the 79 recheck; residual 1.9).
- A given claim released from the panel stays released (AC, 06eae9e; check 40; residual 1.8).
- A whole-song Restore across a tempo change is whole and one act (AD, ea272dd; checks 41-43 passed); the order heal beside an older build (AE,
  check 44 passed); one Keep logs once (AF) and a delete in the cooldown is told why (AI); the claims cache over a link copy (AJ, check 47 passed).
- A tempo change auto-claimed every track it moved items on (AL, 03361c8); the Keep's own put-back left no undo point (AK, 03361c8): both
  checked in round 10 (handoff 07:05).
- "Play (skip time selection)" is carried in Play together: built, 2b719c3 (the start carries the selection, the panel's box) and ea8bb37
  (the extension notes REAPER's own 40317, Live sync's cue carries it, followers put their own selection back; the web UI's Play and Song
  pages have the box); extension 1.0.34 (8b6c501, bc57d15). Built only: not installed or run in REAPER (checks 1-8 in rt-answers; item 2.10).
  Still not carried: region playlists (item 1.11).

### James's answers of 2026-11-21 (all built in 2b719c3 / ea8bb37, built only, REAPER checks in rt-answers)
- "Undo this change" on a whole-song Restore's row puts today's tempo map back first (the Restore's timeline change carries its act). Round 6 question 1.
- The Restore page puts a restored take on its beat (`map_of`, as History's). Round 6 question 3.
- A song's home is the member who added it (their own signed hub file's `added`, kept through handovers; an old song keeps the rule before until
  its sharer's computer notes it). Section 4 question 4 of the first version.
- Play together honours "skip time selection" on every computer. Section 4 question 1 of the first version.
- Livestreaming moved to its own project outside StudioSync (`docs/rt/rt-stream.md` stays as StudioSync's side only; see section 3).
- Also answered by James's own words (quoted in rt-drive2 round 10; 188794d, fcec148, 4095b34): background cloud work may take 16 ms a pass, and a big pull
  from the cloud 32 ms until caught up. The handoff's 11:45 question about the 3-minute full round backing off was met by 50516c1 (a room with nothing
  changed isn't passed over in full again) and round 10's 4 ms "quiet" mode; nothing records a further answer.

### Hub, live audio and room lists
- A computer neither side lists for live audio, and a talkback-only sender dropping off a peer's list after 15 s: fixed (7c83b33; items 3 and 4
  of rt-hubsmall; REAPER checks 3 and 4 not recorded: item 2.7).
- The desktop's status file rewritten every 2 s: fixed (7c83b33, item 2); the mix host's `net` probe misreading Ethernet plus Wi-Fi: fixed (same, item 5).
- The song's home moving with whoever last wrote session.json: fixed by "the home is the adder" (2b719c3, built only).
- The hub watch taking the VM's own stalls for the hub's silence: fixed (1efe35c; extension 1.0.32, a31fd2b). Deployed on all four; the
  `stalls` re-check on LinuxBox is item 2.7.

### History
- History's preview and Restore taking the tempo map, markers, track order and the master's automation of their moment, and the time lapse
  following the preview and showing markers, tempo and track moves: built, 415c181 (rt-history2). `.opus` served as `audio/ogg`: 415c181 plus
  extension 1.0.32 (a31fd2b). Built only: rt-history2 checks 1-6 not run (item 2.11). Still open: comp areas and the limits in item 1.12.

### Link-first
- Link-first studio files and the panel waiting about 3 s for Syncthing: the panel now reads the signed link copies (62010ce, 40eb42f; a person's own
  claims file over the link, checked in round 10: a claim shows in every panel in under a second).
- A computer that comes back catches up over the link (events, 62010ce) and, found by the 2026-11-21 LinuxBox test, with Syncthing paused on it
  (8b4c064: hello every 15 s to computers it doesn't see, ids asked again, media read 16 ms a tick, a take on a deleted track not counted). Built
  only; the need list (`link need list`) stays off by default (item 1.30); the re-check is in rt-linkmove round 5.

### Hop
- A note-off lost twice hung a note: fixed in Hop 0.2.1 (e6086cb; held-note and pedal snapshots, a 200 ms bound), with native tests; 0.2.1 is
  deployed on the desktop, laptop and LinuxBox. The by-ear check is item 2.22 (automated by `ears.py tail`).

### Performance (rt-perf, rt-perfcut1-3, rt-drive2)
- The cloud copy's endless round, the 331 ms and 970 ms drive steps, the first sweep taking 16 minutes, the update files checked again and again,
  "bringing ... up to date" with nothing to send, "up to date" 3.7 minutes late: fixed over rt-drive2's ten rounds (b9542db ... 4095b34) and
  checked on the desktop in rounds 8-10 (handoff 11:45: no plan over 50 ms, the first sweep in 9 minutes, edits and undos up within seconds).
  Extension 1.0.33 (5f4745d) checks update signatures on a thread.
- rt-perf's cuts 1 (the endless round), 2 (real MIDI pools), 3 (the base per sub-tick), 4 (redraw only when it helps), 5 (fewer full looks on heavy
  songs), 6 (`mirror.root` held): done (b9542db, e46325b, 1b47313, c53923d; idle cost 4.2 % -> 2.9 % of a core, checked). Left: cuts 7-9 (item 1.2).
- The test runner stops a run at 4 GB or 300 s on one test (6ae0bf8).

### Obsolete
- "A computer still running main's Live sync has the old colour hold": a rig condition, not a code fault (item 6.13).
- "`lib/files.txt` lists `StudioSync - Hold my changes.lua`": the script is gone from the repo; `lib/files.txt` is rewritten by `tools/make_index.py` at each release, so
  the stale row goes at the next one. Nothing to do by hand.
- "Web UI chat chips' duplicate accessibility nodes": not reproduced, nothing changed (rt-small 4).
- The first version's section 4 question 12 (which of the efficiency pass's problems to take on): superseded by rt-perf's ranked cuts, now package P8.

## 1. Bugs and limits known but not fixed (open only; most harmful first inside each group)

**Edits and the timeline** (P1 unless noted)
- 1.1 `mirror.settled` can still merge an old pair of versions from before track merging; with a real, different old loser the track would
  change everywhere, a day late. Probably gone now that every computer is on 0.59.49.7x: prove it can't happen and remove the case. (rt-undo)
- 1.2 Heavy sessions (P8): every track's chunk is still read at least every 10 s, the Mixer reads its strips every 0.25 s, the Project page costs
  about 12 % of REAPER's time while editing; the colour look runs on every status write (`sync.write_status`, 23-31 ms on a heavy song, rt-perf
  cut 7); the status write itself is 10-32 ms with the link send unsplit (cut 9); the Project page rereads every track (cut 8); `start/link`
  (~0.25 ms a tick), `band.songs` (5.3 ms), live audio's peer and vouch merges (2.2 ms a run, worst 42 ms) (rt-perfcut3 Left). Live sync on a heavy
  song with real plug-ins has never been measured. (rt-perf, rt-perfcut2, rt-perfcut3)
- 1.3 Track deletion against a track edit: newest wins. Plug-in chains don't merge: one stands. Dense CC drawn by two keeps the winner's points
  where ticks coincide. A pitch change counts as a move. (rt-merge §6)
- 1.4 Claims: the web countdown only moves when presence changes. (rt-claims)
- 1.5 The web Project page and the phone still ask for any edit to an auto-claimed track; they can't tell a clash from a different piece.
  (rt-merge §3b)
- 1.6 Colour try: Put back leaves the tried colour on a region that had none; a bandmate's change on a tried item replaces the tried colour. (rt-nohold)
- 1.7 REAPER's own Edit > Undo (not the bound Ctrl+Z) still undoes a StudioSync heal or put-back point, and the next look then sends that as yours.
  Default: leave it (James's question, 4.a). (rt-edits round 5 Z, round 6 AG)
- 1.8 A given claim released from the panel in the seconds before Syncthing's copy arrives (the link's copy only) isn't released: the member's own
  file has nothing to remove. Default: option (b), a one-line change in the panel so its release also marks a given-only claim as let go. (rt-edits round 5 AC)
- 1.9 A note you delete and another you draw of the same channel and velocity, while a bandmate changes the deleted note, is read as a move, and
  your drawn note is left out as a clash. Default: keep it so. (rt-edits round 5 AB)
- 1.10 `ACT_KEEP` (70 s) was sized for the 60 s full look; with heavy songs' full looks up to 5 minutes apart, a part of an act only the safety net finds
  is its own Undo step. An item you move by hand in the 15 seconds after a tempo change reads as the map's move and doesn't claim its track
  (the next edit to it does). (rt-perfcut2 Risks, rt-edits AL)
- 1.11 REAPER 7 region playlists ("skip hidden regions") aren't carried in Play together. Rare; default: leave. (rt-edits)
- 1.12 Restore and History limits (P6): automation placed from History that was made under another tempo map isn't moved onto it; an item restored
  from a version under another map keeps its rate, fades and snap offset as stored (position, and length in beats mode, are moved) and a map with
  a gradual tempo change isn't converted; moves from before rt-edits carry no `moved` and aren't taken back; automation items (BANDAI) on the
  master aren't rebuilt in the preview. (rt-history2, rt-edits AD)
- 1.13 Undo of a track move made before 0.59.49.77 no longer moves the track back; two tempo changes crossing keep the unsent one and replace the bandmate's;
  a rename over 10 minutes old made while the claimer was away stands. Defaults as built (4.c). (rt-edits round 7)

**Live audio, jam and plug-ins**
- 1.14 Full-quality copy (P12): no drift correction (about 7 ms over 5 minutes at 20 ppm); play rates other than 1 split into many items; MIDI and
  instrument tracks aren't copied; a no-transport jam's place depends on the anchoring computer's project end. (rt-double)
- 1.15 Jam (P12): someone arriving mid-run hears a player only from their next play; stereo 16-bit WAV only (about 1.5 Mbit/s per listener); sent
  to everyone, Jam on or not. (rt-jam)
- 1.16 Their time (P12): takes recorded in it land late by the delay and nothing moves them. Produce: the first second of a take can be heard twice. (rt-sonox)
- 1.17 Hops (P4): Print's first 0.5 s is dry when the selection starts at 0 (cause found; Print now says so; fix needs REAPER's pre-roll or a
  loop); only the first 256 knobs (paging needed, a 64 KB message cap); switching tabs on the owner's computer drops the try (REAPER doesn't
  process a background tab; check, then follow the tab). (rt-hop2 2-4)
- 1.18 Two hops at once on one internet link lost more: both publish in the same block as unpaced bursts of raw PCM (~6.8 Mbit/s each way); fix is
  in the extension (pace, one stream, or lossless compression). (rt-hop2 5)
- 1.19 No drift-correcting resampler in listening links, browser guests or the share's REAPER mix: a small skip now and then. (P11; rt-audience,
  rt-browserjoin, rt-share)
- 1.20 Hub (P9): a home that two bandmates can't reach still hosts (Health says who can't reach it; default below); a guest's reach isn't counted;
  a returning or new computer can be named by the others up to 15 s before it takes the role itself; the live mix's host settles reach in 4 s, not 30;
  after a stall the receive thread's `mix_gap` learns it for 60 s, so a real hub drop in that window falls back without the early rescue; a Wi-Fi
  listener isn't kept on the mix through its own outage; the election goes by status files only, so a computer with Syncthing paused can hold its
  song's hub beside the real one; the studio hub's election doesn't use reach. (rt-hubrank Left, rt-hubwatch, rt-hubsmall, rt-linkmove round 5)

**Web, phone, guests**
- 1.21 Listening links (P11): the live indicator ignores a bandmate playing while this computer's live audio is off; browser guests aren't in what
  listeners hear; only the web UI's Home has the controls. (rt-audience)
- 1.22 Browser guests (P11): must be on the studio's Tailscale (P13 for a guest without it); guests don't hear each other; two at most; one take held per guest. (rt-browserjoin)
- 1.23 Drawing (P6): a removal over the link hides a file for 10 minutes, and it shows again if Syncthing's deletion never comes. (rt-draw) Also from
  rt-draw2: Undo's piles live in Live sync's memory (after a restart Undo falls back to the newest drawing on the view and there's nothing to Redo);
  Clear mine and Clear all can't be undone; a share note is kept only for the room's own song with the timeline place known and its ends on studio
  tracks, in the author's colour at size M, and appears twice while the sharer's panel draws over the arrange view; both sides need this build.
- 1.24 Screen share (P11): a master routed off the first output pair isn't heard; duck mutes both of a bandmate's computers; system audio can't be
  turned on mid-share. (rt-share)
- 1.25 Phone MIDI (P5): one track at a time per computer; other armed tracks on "All MIDI inputs" also hear it; program changes are dropped; step
  input makes one undo point per note. (rt-vmidi)
- 1.26 Home (P5): notifications don't work over the phone link; Open from a page may show its usual boxes on the computer; mix times use the
  renderer's local clock. (rt-home)
- 1.27 Chat (P5): an upload is held in memory (up to 150 MB) and hashed on REAPER's main thread. (rt-chat2)
- 1.28 Video (P6): more than 16 distinct video files on screen get no thumbnails. (rt-video2)

**Joining, link, cloud**
- 1.29 First copy over the link (P10): only the current song's main room; band.json and session.json must fit in 30 KB or there's no first copy; a
  Windows joiner without the firewall rule hears neither the welcome nor the copy. (rt-joinlink)
- 1.30 Link-first (P3): studio-wide files reach only the peers in Live sync's room; still Syncthing only: files over 32 KB, `driver.json`, `room.json` and
  invitation records, room summaries, plays lists, plug-in and library lists, `chat/resolved`, `chat/stage.json`, drum maps, mixes, stems, restore points,
  the update code, `_band` beyond 30 KB; the need list (`link need list`) is off by default and covers only the top of each room's media folder (at most
  6,000 files); a person with two computers has hub handovers and track orders written on the other refused over the link; a song this computer only
  lists gets `session.json` without its `.sig`; an older folder copy can briefly replace a newer link copy; `nat:` peers get no hello; `band.rename` leaves
  an old `.sig`. (rt-linkmove rounds 1-5)
- 1.31 NAT links (P13): Health keeps a "can't reach" row for a bandmate swapped from Tailscale to `nat:` until REAPER restarts; no SACK, so a loss stalls a stream. (rt-nat2)
- 1.32 Relay (P13): a hub behind CGNAT is never detected; the role can move to a computer without the port forward; a relay that answers STUN and then
  stops relaying breaks links until the next 10-minute probe. (rt-nat3)
- 1.33 Invite links (P10): only for someone already on the studio's Tailscale; one pending link at a time; Linux keeps the `xdg-mime` default after untick. (rt-invite)
- 1.34 Cloud modes (P2): Standard has no "last mixes" (the cloud copy carries none); Essentials keeps every take of a multi-take item; a member without a
  cloud folder can leave the cloud's version older; lowering the size limit doesn't ask. (rt-cloudmodes)
- 1.35 Cloud worker (P2): `sessionfile.catch_up` (copies on REAPER's thread when recordings are pending) and `streams.lua`'s cloud check still run on
  REAPER's thread; each worker start leaves an empty file in temp until REAPER quits; `trim.plan` is 80-200 ms for a room with saved versions (one step per
  plan, a few per sweep); `cm.filter` judges a room in one go in Essentials and Standard (100-300 ms); a room's first planned pass is 30-55 ms; why a
  big room's first sweep took an hour on the desktop isn't fully explained. (rt-drivebg, rt-drive2 Left)
- 1.36 Other scripts (P7): `startup.keep_open_mode` can be overwritten by Autostart's own copy at the next tab change; `PreventUIRefresh` left on by a
  script can't be detected. (rt-compat)
- 1.37 Efficiency pass list for the cut list (P8): arrange redraw every pass (done, rt-perfcut2 cut 4), unlimited stream trace log, presence `last_time`
  by user only, and more; `seen_ev` is pruned and claims files are cached; the rest not re-checked. (roadmap, older)

## 2. Built but never checked in REAPER or on real hardware

Each line: what to check, where the step list is, and how it can now be run (R0-R7, T1-T3 in the plan). "Partly" = some steps have a record.
Closed since the first version: the edit matrix (29 steps and the 8-step Undo check: re-run on three computers over rounds 5-10) and the quick-looks timings
(measured by rt-perf).

**R1: edits, claims, merge (two or three computers, no sound)**
- 2.1 Merge checks 1 to 10; the set-back fix (c7eed9d) has no recorded re-check. (rt-merge §8)
- 2.2 Claims: a whole `mirror.watch` holding an item 30 s; the web Release and Keep buttons. (rt-claims)
- 2.3 Hold removed, colour try, restart mid-try; a Mac for the `B` colour suffix. (rt-nohold)
- 2.4 rt-edits round 5 steps 35-40: ran in the 0.59.49.79 recheck, but per-step results aren't in the docs and should be written up. W (timeline edit right after updating) can't be checked until `TIMELINE_FORMAT` changes.

**R2: link, hub, joining (two or three computers, no sound)**
- 2.5 Signed studio files, 8 steps (grant and mode at once with Syncthing paused). (rt-linkfirst)
- 2.6 rt-linkmove: round 3's three checks (events over the link with `link need list` on, the panel reading the link's copies), round 5's A-C on
  LinuxBox with its Syncthing paused (James OK'd that machine only, never the desktop's or laptop's), then switch the need list on by default if they pass. Claims
  over the link: checked (round 10).
- 2.7 Hub: rt-hubrank 1-8 (partial reach by blocking port 47281: `iptables` on LinuxBox), rt-hubsmall 1-6 (items 1, 3, 4, 6 especially), rt-hubwatch's
  `stalls` on LinuxBox, rt-hubfix (start order, hand the hub over, no flapping for an hour), rt-roomlist, rt-small, and the home = adder (rt-answers 3).
- 2.8 First copy over the link, 7 steps: a scratch studio only, never Chilio's; LinuxBox as the joiner. (rt-joinlink)
- 2.9 Ask to join, invite links, the `studiosync://` handler (no handler was installed anywhere; registering one is a system setting: James's OK or LinuxBox's
  `xdg-mime` only); `reaper.exe -nonewinst` behaviour. (rt-invite)

**R3: restore, history, skip, chat, drawing, video**
- 2.10 rt-answers checks 1-4 and round 2's 5-8 (extension 1.0.34 must be installed first; check 7 settles what REAPER's 40317 does from inside the
  selection, and the late start's rule), Restore tempo (rt-edits 41-43 passed).
- 2.11 History playback after the fixes (891dd04, 442a2aa, 415c181): rt-history2 checks 1-6; the note records no second run; a phone's playback
  (Safari: James's list). (rt-history, rt-history2)
- 2.12 Chat: DMs, channels, file drops, 150 MB uploads, a real Syncthing round trip. The roadmap records one DM reaching the laptop in 12 s. (rt-chat2)
- 2.13 Drawing on the web pages and the phone: rt-draw2's ten checks (the phone via the S23 over adb; share notes; the panel's look). (rt-draw, rt-draw2)
- 2.14 Video: Video processor, big files, video settings, thumbnails, `fx_type` and SWS config names; an iPhone (James's list). (rt-video2)

**R4: performance and the cloud**
- 2.15 The perf cuts' own checks (rt-perfcut1 1-3, rt-perfcut2 1-5, rt-perfcut3 1-5), big project measurements steps 3 to 8 (rt-bigproj), and the
  heavy song with real plug-ins and Live sync running. Round 11's idle-cost cut and the cloud copy's checks (rt-drive2) are checked.
- 2.16 Cloud storage modes: the panel section has never been drawn; real trash and rate limits (rt-cloudmodes). Cloud worker: the worker killed mid-copy
  (the desktop's G: drive; the laptop has no cloud folder); the one doubt from 11-21 07:05 (2 small files took 3.7 minutes to say "up to date",
  rt-perfcut3 §3's fix). (rt-drivebg)
- 2.17 Other scripts: undo names, persona switch timing, window sets, `netstat`/`lsof` output per system. (rt-compat)

**R5: sound (the ears harness, T1; no real microphone, desktop and Mac inputs stay deafened)**
- 2.18 Live audio: since extension 1.0.30 it sends inputs and plays bandmates; counters confirmed on three computers (the 2026-11-21 01:50 tone test:
  hub `level` 0.0625 x 0.01); sound compared by capture, then the hour-long gate. (rt-audience, roadmap)
- 2.19 Jam, 14 steps: one interval late on the bar, click at source swaps, tempo change, loop. (rt-jam)
- 2.20 Full-quality copy, 11 steps: claps line up, the offset in ms. (rt-double)
- 2.21 Solo, Their time, Produce over live audio, mix host with shared CPU (four computers: LinuxBox, a second VM). (rt-sonox)
- 2.22 Hop: try a plug-in you don't have, the budget, dry on loss, MIDI over a hop, Print's PDC; Hop 0.2.1's hung notes by ear (`ears.py tail` under
  injected loss) and its mixed-room 0xF4/0xF5 check; rt-hop2's checks 1-8. (rt-hopvst, rt-hop2)
- 2.23 Browser guest: join with an interface (Chromium fake device; a real UR22 is James's list), loopback measure, record a take. (rt-browserjoin)
- 2.24 Screen share with REAPER's sound, no echo of your own voice, full-screen crop, notes; the Mac for 2x pixels. (rt-share)
- 2.25 AI tools: no model was run or called; each run needs James's yes (which model, which PC, how long, why). (rt-ai)

**R6: the phone (the S23 over adb)**
- 2.26 Listening links on a phone (Chrome via CDP; Safari 26+ and Firefox 130+ untried: James's list for Safari, a download for Firefox), revoke, cap,
  sample-rate change. (rt-audience)
- 2.27 Phone keys, pads, Web MIDI, stuck-note safety (a USB MIDI keyboard into the phone: James's list; the page logic on the desktop with a virtual port). (rt-vmidi)
- 2.28 The phone's Project view with the fix deployed inside Live sync. (rt-phonefix)

**R7: the network (the router VM, T2)**
- 2.29 Connect without Tailscale, stages 1 to 3: real NATs (cone, address-restricted, symmetric), CGNAT, hairpin, a network change, the hour-long gate with
  Tailscale off on one side. The real home router's forward is James's call (4.2). (rt-nat2, rt-nat3, roadmap)
- 2.30 Guest without Tailscale. (rt-sonox)
- 2.31 Public listening: only if James decides (Funnel in the tailnet policy, a phone off the tailnet; 4.1). (rt-audience)

**The Mac (out of testing since 11-21 10:39; extension 1.0.31, Hop 0.2.0, SSH to it timed out)**
- 2.32 Jam and full-quality copy on SWELL builds; history's background render; the cloud worker's `stat -f` branch on a real Google Drive folder; the
  handler's applet and Gatekeeper; the docked view; rt-hubrank 8 (never the hub while a 1.0.28+ computer is in the room). (rt-jam, rt-double, rt-history,
  rt-drivebg, rt-invite, rt-hubrank, roadmap)

## 3. Features designed or half built (open)

- 3.1 Voice channels: design only, 4 steps (voice flag and join files, peer set switch, pages, hub for 4+). (rt-chat2; `lib/liveaudio.lua`) Wave 3.
- 3.2 Fewer dependencies (rt-lite's stages):
  - A, No Tailscale: built, off by default (`nat` in band.json). Left: its REAPER checks (R7), invitations over a NAT link, the hub's TURN for video-call
    pages, Health naming the Tailscale-only features, phone pages without Tailscale. (P13)
  - B, signed writes: done (rt-linkfirst, 36f90ae; the welcome's sequence numbers and session.json / hub signing in 173565b).
  - C, key-made device ids: not done. D, No Syncthing with a cloud: not done (8 to 10 sessions; a gate decision, 4.6). E, Minimal: not done (4.7).
  - The secret sealed in the join welcome: done (rt-joinlink, 2563d80). Sealing it again after a removal: not done (P10).
- 3.3 Still on Syncthing and could move to the link: catch-up's need list (built, off), restore points, mixes and stems, the update code, `released/*`
  and other own files, `_band` beyond 30 KB, NAT first contact; see item 1.30's list. Done: given claims, releases, track order, hub handovers,
  `session.json`, profile pictures, timelines, a person's own claims, events catch-up. (rt-linkmove inventory; P3)
- 3.4 Public listening: built, switched off behind the owner's switch (4.1). (rt-audience)
- 3.5 AI add-on: built against stand-ins, off per studio, no key support. (rt-ai) Wave 3, one James yes per model run.
- 3.6 No panel (ImGui) UI for listening links or browser guests. Default: none, the web UI only (follows 4.4's retirement default). (rt-audience, rt-browserjoin)
- 3.7 Remote control of a shared screen: design note only. Default: not built. (roadmap, step 5)
- 3.8 The pointer and notes over the sharer's real REAPER window: not done, preview only. Default: leave. (rt-share, roadmap)
- 3.9 Home proposals, not built: project cover art, a status line, phone push for mentions, "since you were last here", read receipts. Wished-for chat
  functions: a to-do assignee, mentions for several names, a cheap "newest messages" read. (rt-home; P5)
- 3.10 ReaPersona's four suggested changes: written down only, its repo not edited. (rt-compat §2; P7)
- 3.11 Audit recommendations not done: stretch the timed pass to about 10 s while playing and the link carries; a passive "everything's out" tick for Sync
  and exit; stop growing the panel's duplicate pages. (rt-audit §10, §12, §14; P8 for the first two, P7's wording for the third)
- 3.12 Low-res video proxy while the full file arrives; sharing the Video processor's preset file: not built on purpose (4.10). (rt-video2)
- 3.13 Per-plug-in merging by FXID (P1). Per-page MIDI channels so two phones play two tracks (P5). (rt-merge, rt-vmidi) And, from History: the time lapse
  doesn't show comp areas (P6). (rt-timelapse)
- 3.14 Cloud: the cloud copy doesn't carry `session.json`, `room.json` or `band.json`; filter an item's inactive takes. (rt-cloudmodes; P2)
- 3.15 Jam over Opus or FLAC; drift stamps every second for the full-quality copy. (rt-jam, rt-double; P12)
- 3.16 Snapshots plus changes, native hot paths, the Studio browser, a studio preference set: planned, not built. (roadmap, older)
- 3.17 Web UI pages' "not yet" lists (deleting items, fades, sends, automation items, CC lanes). (roadmap, older; P14)
- 3.18 "One copy per file across songs". (roadmap, older: "Proposed next")
- 3.19 SonoBus, ReaNINJAM, "Private live audio" and "Invite a SonoBus guest" stay until James's gates (4.6). (rt-audit "Left", rt-sonox)
- 3.20 The StudioSync side of livestreaming (new; the stream project is outside StudioSync): what it would need from StudioSync is a stream mix from
  live audio (a live audio change), the session clock and a signed `cam`/`stream` topic. Nothing to build until that project asks. (rt-stream §3, §4, §10)

## 4. Open questions that are James's to answer (a default for each, so no package waits)

Answered 2026-11-21 (moved to "Closed since"): "Play (skip time selection)" in Play together (built); what decides a song's home (the adder); a Restore
row's Undo and the tempo map; the Restore page and a take's beat; background cloud work's budget. Answered earlier: the live mix's host, edit holds, the number
of modes, SonoBus's extras, classic Jam (rt-audit 6, 7, 9, 10; built by rt-merge, rt-claims, rt-sonox, rt-jam).

1. (was 2) Public listening: turn it on at all? It needs Funnel allowed for JAMES-MAIN in the tailnet policy. Default: off. (rt-audience)
2. (was 3) Forward UDP 47298-47314 on the home router to the hub for the relay, and make that computer the preferred hub? Default: no forward; the router VM
   covers the logic. (rt-nat3)
3. (was 5) The three "Follow"s: rename the transport one "Play and stop together" and the view one "Watch <name>", or keep the words? Default: rename (the
   audit's own proposal), package P7. (rt-audit §8)
4. (was 6) In what order should the ImGui panel's pages retire? Default: Home, Chat, Play together first, as the web UI covers them. (rt-audit §14)
5. (was 7) "Open collaborators' MIDI edits as they happen": remove it (the audit's guess) or keep it? Default: keep, off. (rt-audit §15; `lib/midiview.lua`)
6. (was 8) The gates: when do SonoBus, ReaNINJAM, Syncthing, ReaImGui and SWS/JS retire? Default: none now. (roadmap, rt-lite, rt-audit §9)
7. (was 9) Is Minimal mode wanted (only if bands ask), and phone pages without Tailscale (LAN listener, no microphone)? Default: the second, no for the first. (rt-lite)
8. (was 10) Which AI models to run, if any: every run asks first. (rt-ai)
9. (was 11) Should a startup script that writes the grid keep making the grid per computer? Default: yes, reversible in `compat.run_check`. (rt-compat §6)
10. (was 13) Is a low-res video proxy wanted later? Default: no. (rt-video2)
11. (was 14) The BandSync rename shims: keep until a "drop pre-0.5 projects" release, if ever? Default: keep. (rt-audit §15)
12. (new, rt-p3) One person, two computers? A person has one devices file naming one computer, so a second computer rewrites it every 30 s
    and own files, the link's sends, NAT pairing and the key learnt flip between the two. Supporting it needs a devices model per computer and a rule
    for who may add someone's second computer (a security design; removal, trust, direct, nat, joinboot, presence). Default: not built; one computer per
    person per studio (a second name for a second computer). (rt-linkmove round 6, item 7)

Open since round 5-7 (kept with their defaults in section 1 and the packages):
- a. Edit > Undo undoing a heal or put-back point, and whether every put-back is its own StudioSync undo point or only a Keep's (items 1.7; round 6 question 2). Default: as built.
- b. A given claim released before Syncthing's copy (1.8, default option b); a note deleted and another drawn read as a move (1.9, default keep).
- c. Crossing tempo changes: the unsent one is kept and the bandmate's replaced; a rename over 10 minutes old made while the claimer was away stands;
  undo of a track move made before 0.59.49.77 no longer moves the track back. Default: as built.
- d. A home that two bandmates can't reach: should it be passed over as the song's hub? Default: pass it over once N >= 2 can't reach it and another computer
  is reached by all (P9). (rt-hubrank Left; round 7)
- e. Whether the cloud copy's BIG_BUDGET stays at 32 ms (set by 4095b34 after James's answer). Default: yes.

## 5. Security: review later

Collected as written, not judged. James deferred reviews until every feature is in. The original list is unchanged; new items from the notes written
since are appended at the end of this section.

**Link and signing**
- First use: a computer takes the first validly signed copy, however old. (rt-linkfirst, rt-lite)
- Keys are learnt from Syncthing's `modifiedBy`; a forged Syncthing client could bind its key to a computer once. (rt-linkfirst)
- A writer with a slow clock sends an older sequence number and its link copy is refused. The seqs store forgets past 600 files. (rt-linkfirst)
- Own files (profiles, colours, recaps) over the link are unsigned. (rt-linkfirst)
- band.json carries the secret over the link; a removed member whose mark hasn't arrived could still get it. (rt-linkfirst)
- The outbox is a non-persisted ExtState. (rt-linkfirst)
- A stolen device key signs until that computer is taken out. A clock a day ahead pushes sequence numbers. Two ids per computer. (rt-lite)
- The secret in band.json must be sealed before a cloud carries `_band`. (rt-lite)
- Signed updates: band.lua, json.lua and the entry script are read before the check; a downgrade is accepted; no key rotation; an
  admin can set the first key. (roadmap, "Signed updates: still open")
- A merged version's state is signed by nobody; a hostile event with many tiny events costs a sort per merge. (rt-merge)
- `undoes`, `redoes` and `base_ev` are the sender's word: a changed client could mark an edit as an undo to pass an auto-claim. (rt-edits)
- A marker's render row isn't length-capped. A start cue's `loop` sets your loop. (rt-edits)
- Hop `set` and `params` trust the `user` field inside a signed message; network MIDI goes straight to the instrument. (rt-hopvst)
- A peer's early anchor can move where this computer's no-transport parts land. (rt-double)
- A peer can make a receiver write up to an hour of WAV per jam run; streams have no per-peer budget. (rt-jam)
- Draw messages carry the author's name in the data: another name, or a removal "by" an admin, can be claimed. (rt-draw)
- A forged 'H' can make peers send directly (bandwidth). `ext` and `sees` are a member's own word. (rt-hubfix)
- A studio computer with the secret can make itself heard in a room it isn't in, 15 s at a time. (rt-roomlist)
- Status fields `net`, `lrtt`, `scpu`, `lmix` are self-reported: a member can claim to be the best mix host. (rt-sonox)
- Removing SonoBus must not remove band.json's `sonobus` secret. (rt-audit)

**Web UI and tokens**
- The studio-wide web token lets any member use your web UI as you. Needs per-person tokens. (rt-chat2) Through it a phone can: read
  and send DMs (rt-chat2), make AI asks (rt-ai), open projects (rt-home), start history renders (rt-history), make the computer
  scan every script and run `netstat` (rt-compat), arm a track and sound its instrument, possibly loudly (rt-vmidi), draw and
  remove (rt-draw).
- DMs are plain files readable by everyone with the studio folder. (rt-chat2)
- Channel admin rights are checked only on the acting computer. DM ids are FNV-1a-64. (rt-chat2)
- `StudioSync_FileHash` reads whole files on the main thread. Received files: only programs are blocked. (rt-chat2)
- `chat_index.people` and DM names aren't verified with `trust.user_file`. (rt-chat2)
- Profiles aren't checked against who wrote the file; pictures are validated, not decoded. (rt-home)
- Scanned scripts' names and paths show on the web page. (rt-compat)
- `/api/mix` gives REAPER's output to any page served from 127.0.0.1 with the right Host. A watcher can draw on the sharer's preview. (rt-share)
- A file renamed `.mp4` holding HTML is served as video with `nosniff`; byte-range parsing; media decoders parse bandmates' files. (rt-video2)
- `prep.lua` is loaded by the hidden REAPER from the per-user temp folder. (rt-history)
- History reads a huge event file whole, with no size cap of its own. (rt-timelapse)
- A future module that trusts `a.gid` from a host page. (rt-browserjoin)
- No per-page rate limit on phone notes beyond the 64-action queue; `sid` is page-chosen. (rt-vmidi)

**Listening links, public listening and browser guests**
- Codes are bearer secrets in URLs, made from `band.secret` (REAPER's GUIDs, not a documented CSPRNG). (rt-audience, rt-browserjoin)
- Listening codes are kept in ExtState on disk. (rt-audience)
- Rate limits are per way in, not per listener: one abuser can lock real listeners out for a minute. (rt-audience)
- Public listeners can't be told apart or removed one by one. (rt-audience)
- The session mix goes out whole to listeners and guests, talkback included; the band isn't warned. (rt-audience, rt-browserjoin)
- Funnel publishes the machine's name and stays configured if REAPER closes or crashes. (rt-audience)
- A public link's latest mix may be an unreleased render. (rt-audience)
- The page files are read from `lib/webui` on each request. `/listen/` bypasses the token by design. (rt-audience)
- The guest cookie is bound to nothing else; sessions last 4 h. (rt-browserjoin)
- A chat app's link preview could redeem a guest link first; consider a confirm step. (rt-browserjoin)
- Guest uploads hold memory (160 MB each) and write WAVs into the project's folder. (rt-browserjoin)
- Guest audio isn't authenticated per frame beyond the session cookie. (rt-browserjoin)
- `tailscale serve` is shared with the phone link: turning the phone link off doesn't stop guest links. (rt-browserjoin)

**Join and invite**
- A join request's phone alert goes to the studio-wide ntfy channel. (rt-invite)
- Invite codes sit in plain ExtState. (rt-invite)
- The redeem channel's key is public; the 30-refusals pause is a cheap way to block real links for 10 minutes. (rt-invite)
- The answer goes to whatever Tailscale name the asker claims; whoever sees a link first wins its single use. (rt-invite)
- Member links open projects without asking, and can switch studio and start Live sync. (rt-invite)
- Join requests aren't authenticated beyond the DM. The launcher's pending file is writable by any program. (rt-invite)
- The Windows handler runs wscript.exe. `chat.post`'s `extra` lets a caller add fields. (rt-invite)
- The joiner's trust root is the token plus its inviter: the first user of a token gets the secret. (rt-joinlink)
- Bandmates' keys come from the inviter's map; a wrong binding is passed on. (rt-joinlink)
- The song's changes and media in the first copy are not sealed (HMAC plus Tailscale). (rt-joinlink)
- Refused welcomes aren't rate-limited. Boot copies outlive a deletion for up to 2 days. (rt-joinlink)
- The seal construction is unreviewed. Media is placed before Syncthing indexes it. (rt-joinlink)

**Relay and NAT**
- The SSN1 handshake is unreviewed; the signal parser and `nat_open` aren't fuzzed. Both before `nat` is on by default. (roadmap, rt-lite)
- Streams trust the link's sealing: a bandmate could hold 16 x 256 KB per link or ack data it never got. (rt-nat2)
- `loop_pair`'s listener on 127.0.0.1 can be made to fail by a local process. (rt-nat2)
- `direct_adopt` skips the Tailscale address check by design; a flood costs a connection slot (32). No per-stream rate limit. (rt-nat2)
- Relay passwords are derivable by every member: quotas are fairness, not authentication. (rt-nat3)
- The relay is an open STUN responder on 17 UDP ports. (rt-nat3)
- The `-Dudp_sendto` shim depends on libjuice 1.7.4's server.c: check on any update. (rt-nat3)
- A member can replay a fresh "restart" (300 s) to make a link start over. (rt-nat3)
- `nat_relay_sendto` returns success for a capped datagram. (rt-nat3)
- The relay listens on any address: on a hub with several addresses, replies can leave from the wrong one and be dropped. (rt-macrelay)
- `juice_destroy` can run inside a libjuice callback; `loop_pair` accepts with no time limit under a lock; `nat_set_rx(h, nullptr)`
  waits without limit. (rt-macrelay)
- A guest without Tailscale inherits the NAT and guest-invitation lists above. (rt-sonox)

**AI add-on** (all rt-ai)
- A tool gets the take's whole source file; any program at the set path runs with the user's rights and its output is synced.
- Text to a non-local address over plain http is unencrypted.
- Credentials in the address sit in `run.ps1` and on curl's command line. No key support.
- Stems and MIDI tracks added by a yes skip per-room claims and driver rules.
- Answers go through `chat.post`: alerts carry the model's text, and an @ could ping someone.
- Job folders are never pruned. `ai_mix.lua` is loaded with `dofile` when present.

**Files and paths**
- Cloud worker: plans and scripts sit in the per-user temp folder; the worker trusts any path in a plan; the `j` check is
  structural; the `slow` file is a test hook. (rt-drivebg)
- The cloud copy's events aren't signed: a planted newer-looking change makes the sweep remove the real newest from the cloud. (rt-cloudmodes)
- A manager's Essentials removes data from the cloud copy for everyone; the owner's computer removes others' files after an
  in-memory hour; the size readout can download cloud-only files. (rt-cloudmodes)
- The startup re-assert writes `__startup.lua` without asking. (rt-compat)
- The colour try's ExtState is trusted and uncapped; a local script could withhold or put back colours. (rt-nohold)
- A bounce helper's sampler state may name any file on the helper. (roadmap, older: bounces)

**Claims and permissions**
- `mode.json` is read without a writer check. (rt-claims)
- A grant names a person by display name: renaming yourself to it gets the grant. (rt-claims)
- `claim_ask.from` and `claim_answer.from` are unauthenticated: a fake release, or a wrong name shown. (rt-claims)
- Ask names go to the studio's ntfy channel. Auto-claim times use each computer's own clock. (rt-claims)
- A rename is judged only by its sender; judging on receive is left for the security pass. (rt-claims)

**Added by rt-triage (2026-11-21) from the notes written since the list above**

- *Home and Play skip (rt-answers):* `added` is a member's own word in their own signed hub file; it counts only for the person session.json names, so it
  gives nothing a member couldn't already take by writing session.json from their own computer, which any member's computer still can. The old-song note is
  written only by the computer whose person session.json names. `skip` is two numbers range-checked (`together.skip_range`) that set this computer's time
  selection and run a fixed action id. `BandSync / play skip` is local ExtState from this computer's own extension; a script could write it, which only
  adds a skip to this person's own start.
- *Sync core (rt-edits rounds 5-7):* `dropped` (in a person's own claims file) can only make that person's given claims count less, and is type-checked and
  never a path; `undo passed`, `apart order` and the published unsent list are local, non-persisted state; a held deletion keeps `unsent` only while
  `claimask.hold` says the ask waits; `opts.map_of` maps come from History's own timeline events and `mirror.retime` reads numbers only.
- *Hub and room lists (rt-hubsmall, rt-hubrank):* vouching goes by another member's `sees`: a member could name a late computer to make the others send it live
  audio for up to 150 s (a studio computer, never outside the studio). `sees` lying can cost another computer one miss, make itself a song's hub (below the
  home, never as a guest) or move the role about every 30-45 s (a cap on moves an hour is a possible limit). A near sender is kept by status age only
  (150 s at most). `lrtt`, `net` and the others stay self-reported.
- *Link-first, rounds 3-5 (rt-linkmove):* the event day sums use a 32-bit FNV hash (a collision hides a day: its changes come by Syncthing, nothing wrong is taken);
  no per-sender limit on asks (up to 6,000 event files a minute, the media list every 10 s) or on received hellos; what an ask brings back is checked as any
  event is; the `.boot` mark keeps an inbox a day; the in-use rule goes by this computer's own events (a hostile event can make a media file "played", so a
  list can fetch it, never place it elsewhere); `linked files` and `.linked/` are readable and writable by anything running as this user (every reader
  checks each copy again; the panel trusts Live sync's spending of a given claim); the claims file's Syncthing path is unchecked and in studios from before
  owners `trust.own_file_ok` says yes to anyone; claims files fill the 600-entry numbers store faster; the hello shows your status to every studio computer
  that passes the device check, not only your room; a status message makes its sender "here", which turns off full control.
- *Hop 0.2.1 (rt-hop2):* the 0xF4/0xF5 snapshot messages ride the hop's HMAC-tagged MIDI, so anyone who can already send hop MIDI can make Hop X send up to 5
  note-offs or set seven controllers (no note-on); the mapping's sample rate is only trusted between 8 and 768 kHz; X drops a note-on over 200 ms late.
- *History (rt-history2):* `prep.lua` also carries tempo maps, markers (names through `%q`) and the master's envelope text as literals, same trust as before;
  `webhistory.detail` reads `after` from event text with a plain match.
- *Drawing (rt-draw2):* the share's view tells watchers the room key and each studio track's oid (a watcher in another room learns this room's name and oids); a
  hostile sharer's page could make a watcher's kept note land on another track or time of the same room, as that watcher's drawing; `from = "share"` is only a
  label any page can set; Undo and Redo can be asked by any page with the web token, for this user's drawings, and undoing an erase re-saves up to 50 drawings
  and sends as many link messages; a put-back drawing's `time` text isn't length-limited; the piles hold 50 steps a room and view.
- *Livestream (outside StudioSync now, rt-stream §12):* when its `/stream/` route, `cam` offers, OBS password and obs-websocket stream key handling are built,
  they get their own review in that project; StudioSync's side is only the listening links' allow-list treatment if a tailnet route is added.
- *Test and lab tools (new):* `tools/ears`, `tools/lab`, `tools/soak` write captures and run VMs and network rules; none of them may touch the real computers'
  firewall, Tailscale or Syncthing settings, a real microphone or camera, or Chilio's studio. The VM network recipes run only inside the VMs.

## 6. Test rig and CI notes (brought up to date: 12 unchanged, 4 updated, none dropped)

- 6.1 Offline tests passed channel counts in directly, so none saw that REAPER gives the audio hook 0 channels. Green offline did not mean it worked in
  REAPER. (rt-audience) This is why the recheck runs and the ears harness exist.
- 6.2 The stand-in REAPER says every file exists and has no plug-ins through the API: the media copy path isn't exercised. (rt-edits)
- 6.3 *(updated)* The big test project's plug-ins are missing-plug-in stand-ins, cheaper than real synths serialising. rt-perf has since measured the same
  project with 12 real synths (3.2 GB private against 2.1 GB), but never with Live sync running on it (it needs a project published into a studio; item 1.2). (rt-bigproj, rt-perf)
- 6.4 Offline timings were taken on the desktop while other agents were busy. (rt-bigproj, rt-look)
- 6.5 GitHub's Mac runner: `sleep_ms(1)` runs about 9 ms and the process stalls 15 to 250 ms. Timing checks are passed over there unless
  SS_TIMING_STRICT. hopnet_test still fails some attempts (94.48% against 95%). (rt-ci, rt-ci3, rt-macrelay)
- 6.6 macOS answers a loopback alias from the alias: relay tests need 127.0.0.2 and .3, and print SKIP without them. (rt-macrelay)
- 6.7 One Mac quota-check stall and one Linux "a spike isn't drift" failure have no known cause. (rt-macrelay, rt-ci)
- 6.8 *(updated)* nat_test has a 600 s watchdog; CI jobs and steps have timeouts. `SS_TEST_PORT` moves direct_test off 47391. `tests/run.py` now also stops
  the whole run at 4 GB, or 300 s on one test, and names the test (6ae0bf8): a fault can't take the PC.
- 6.9 LinuxBox is a VM: its audio clock reads about +5000 ppm and stalls, and its REAPER writes item text differently. It doesn't start with the desktop
  (`vmrun -T ws start "J:\VMs\LinuxBox\LinuxBox.vmx" nogui`). It has an old 0.58.75 StudioSync in `~/REAPER/Scripts/StudioSync/StudioSync`: start the
  realtime Live sync only from `~/StudioSync Smiley Studios/_tools/studiosync` (`/tmp/vm_open.lua` does that; /tmp is wiped by a reboot, the source is in the
  `bandtest` scratch folder). (roadmap, rt-edits fix K, handoff 07:05)
- 6.10 The desktop's WASAPI through Voicemeeter runs on a 10 ms timer and drops a tick about once a minute (about -102 ppm). (roadmap)
- 6.11 The laptop's clock ran 908 ms off the desktop's: subtract the DirectClock offset in cross-computer timings. (rt-look §7)
- 6.12 *(updated)* The Mac is out of testing again (James, 11-21 10:39): its REAPER still runs extension 1.0.31 and Hop 0.2.0, and SSH to it has timed out
  since 03:36 on 11-21. It needs REAPER restarted by hand or SSH back before any Mac item can run. Earlier the desktop at times couldn't reach it over
  Tailscale (`rx 0`). (handoff, rt-roomlist, rt-hubfix)
- 6.13 *(updated)* The desktop may still start main's Live sync first (old colour hold, no signing): after a desktop restart, start REAPER and Syncthing from
  Explorer, let main's Live sync open Cross Test, then hand over with `rt_handover.lua`, wait 6 s, `rt_live.lua`. The laptop has no cloud folder. Live audio
  is Deafened on all four on purpose (the desktop's input is a Voicemeeter bus used by work calls, the Mac's input 1 a real microphone); undeafen only for a
  planned test (the 11-21 tone-track recipe in the handoff). Syncthing kept leaving the laptop's `drive*.lua` / `cloudmodes.lua` / `sessionfile.lua` at the
  old version after a deploy (cause unknown): `rt_deploy.sh` now re-copies anything still different after 3 minutes. (rt-edits, rt-lite, handoff)
- 6.14 An extension function called with the wrong argument count shows a modal error even inside pcall and blocks REAPER. Probes in a shared eval host must
  call `band.preload` and not unload modules, or they split StudioSync's modules. (rt-small, handoff)
- 6.15 Other agents' uncommitted files in the shared worktree can fail `test_0_60_rt_webpages.lua`. (rt-nohold) Right now `lib/webui.lua`, `lib/webui/index.html`
  and `tools/ears/` are uncommitted work of other agents.
- 6.16 Use a scratch or test studio for cloud modes and join tests, never Chilio's (Chilio's studio stays on main and is never touched). The test studio is
  "Smiley Studios", the song "Cross Test". (rt-cloudmodes, rt-joinlink, handoff)

## Stale or contradictory in the notes

First version's list (kept):
- "Needs a new extension" or "version not raised" (rt-jam, rt-double, rt-browserjoin, rt-joinlink, rt-nat2, rt-nat3, rt-hubfix, rt-roomlist): all released
  since, 1.0.24 to 1.0.34 (`tools.EXT_WANT` is now 1.0.34; the first version said 1.0.31).
- rt-timelapse, rt-home, rt-chat2 and rt-bigproj say "not run in REAPER"; the roadmap's round 3 records REAPER checks for each.
- rt-look, rt-claims and rt-merge say "nothing ran in REAPER" in one section and report REAPER findings in another. The findings are newer.
- rt-timelapse and the roadmap say song playback is "designed only"; rt-history built it (8d753db).
- The roadmap's "Open: a marker-colour echo, and session.json written by several computers": fixed by rt-edits L and M (0ae5fbf).
- rt-edits §2 and checklist 17 (Hold after a colour try) describe Hold; rt-nohold removed it (6db9e1b).
- rt-ci3's nat_test hang and missing timeouts: fixed (b700cfc). rt-macrelay's 64 KB refusal race: fixed (f469e6b).
- rt-look's "the cloud copy still holds REAPER": fixed by rt-drivebg (8cd4273). The roadmap's hop "Still" list (silence on a lost frame, 170 ms budget): fixed by rt-hopvst (67c5b4c).
- The roadmap's round 1 and 2 headings still say "not run in REAPER yet" above sections that later record checks.

Found by rt-triage on 2026-11-21:
- `handoff-2026-11-21.md` is layered: its top still says "Committed and pushed, not deployed yet (HEAD after 06eae9e)", its two updates (07:05, 11:45) say rounds
  8 to 11 are deployed. Its "rounds" are the coordinator's test cycles, not the notes' rounds (rt-edits' rounds stop at 7, the handoff's "round 10 passed
  everything" is the third test cycle of that build).
- The handoff's "Still open for James" lists round 6's three questions and the 11:45 budget questions. 2b719c3 answers two of the three (a Restore row's Undo
  and the tempo map; the Restore page and a take's beat); round 6 question 2 (every put-back one undo point, or only a Keep's) is still open. The budget
  questions were answered in rt-drive2 round 10 (James's quoted words).
- `rt-answers.md` still says "No extension change, no version bump" and "Questions for James 1: build that?" at its top; its own Round 2 built the extension
  change (1.0.34) and answered that question. Read the Round 2 section as current.
- `rt-answers.md`'s home rule ("hub ranking still takes the home as given") against rt-hubrank's Left list ("what decides a song's home is untouched"): the second
  predates the first; the adder rule is now the home.
- `rt-drive2.md` round 10 and the commits disagree with each other inside the document: fcec148 says the big-job budget stays at 16 ms "until James confirms 32"
  and runs 32 ms "only while REAPER is stopped and untouched for 10 s"; 4095b34 (James's answer) makes it 32 ms until caught up, whatever you do (never
  during playback or recording). The code has `BIG_BUDGET = 0.032` and `pull` mode; the first description is superseded.
- `rt-perfcut1.md` says per-lap perf stats are "half done, NOT committed"; c53923d and c8805ea finished them. `rt-perfcut2.md` leaves cut 7 (the colour look only
  with colour parity on) "for the owner of those files": it is still undone, `lib/sync.lua` line 2302 calls it on every status write.
- `rt-hubrank.md` says the backlog "still lists this as not built": it is built (3ce9edb) and now closed here.
- `rt-linkmove.md` round 5's "Not run in REAPER (the re-check above)": the LinuxBox test it came from was run on 11-21, but the re-check of the fixes
  (8b4c064) has no recorded result.
- The first version's section 2 "needs James present" described sound tests as his alone. Wave 0's harnesses (`tools/ears`, the lab) make them scripted runs;
  only the five physical items in "What still truly needs James" are left, and the band test.
- The brief for this triage said only the security review and a real-life band test should remain James's. Strictly, five small physical or account things
  also do (an iPhone, a real USB MIDI keyboard, the home router, a real audio interface, the tailnet's Funnel policy), plus the per-run yes for local models
  and the Mac being switched back on. They are listed in the plan so the band test can absorb them.
