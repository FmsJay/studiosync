# Livestream: the band on Twitch/YouTube with everyone's cameras (rt-stream, 2026-11-21, design only)

James (2026-11-21): "consider how we could tie studio sync into a Livestream as well with everyone's cameras, live view, dynamic view
switching, easily switch between it and regular streaming setup for gaming, any other useful or cool features, would probably be a
standalone or addon."

**Design document only: no code was written, nothing was run.** Built on what exists: listening links (`docs/rt/rt-audience.md`), the
screen share and its sound (`rt-share.md`), video calls (roadmap section 5, `lib/webcall.lua`, `lib/webui/call.js`), browser guests
(`rt-browserjoin.md`), REAPER's video (`rt-video2.md`), the Beat page's synced clock (`lib/webui/beat.js`, `visuals.js`) and the AI
add-on's shape (`rt-ai.md`, `addons/ai/`). Web facts checked on 2026-11-21; sources and licences at the end.

## 1. Goals (and what this is not)
- **The band live on a stream:** everyone's camera in one picture, the band's live mix as the sound, in step with the pictures.
- **A director that switches views by itself** (who's playing loudest, the soloist, a layout per song section) with a **manual override**
  from the panel, the web UI, a phone or a foot switch.
- **One click between "band mode" and James's normal gaming setup**, without rebuilding either.
- **StudioSync drives OBS; it does not replace it.** OBS already encodes, streams to every platform, records, keeps the stream key and
  James's gaming scenes. StudioSync supplies what OBS can't know: the cameras of people in other cities, the band mix, who's playing,
  where the song is, and the controls.
- Not a goal: an encoder or RTMP client in the extension, a cloud relay, handling stream keys, streaming without OBS.

## 2. The shape in one picture
```
 bandmates' web UI pages ──(WebRTC camera, receive-only, over Tailscale)──┐
 (camera opt-in, "On air" bar)                                            v
 Live sync (Lua): `stream` topic ──────────────────────────────> STREAM PAGE  /stream/   (an OBS Browser Source on the
   layout, focus, why, song, section, levels, overlays             grid / spotlight / wide,    streaming computer: one
   <── `stream` actions from panel, web UI, phone, pedal           overlays, per-camera delay  source = the whole show)
                                                                              │
 REAPER output (the session mix: REAPER + every bandmate live audio carries)  │
   └── OBS "Application Audio Capture" of reaper.exe (or the output device) ──┤
                                                                              v
 Stream tab (web UI on the streaming computer) ──obs-websocket (ws://127.0.0.1:4455)──> OBS: profile + scene collection,
                                                                                         start/stop, sync offset, replay buffer
```
Everything new sits on the **streaming computer** (recommended: the computer that mixes, see 4). Bandmates only send a camera and get an
"On air" bar.

## 3. Cameras to the streaming computer
- **Reuse the web UI's WebRTC video.** Calls today are pairwise (mesh), signalled over the link through the `rtc` topic, host candidates
  only over Tailscale, 640x360 camera, no audio by default. The stream adds one offer kind, **`cam`** (`lib/webcall.lua` `KINDS`, one
  line): a bandmate's page offers its camera, video only, to the streaming computer, which only receives (as a screen share's watcher
  does). The stream page (not the streamer's normal page) answers `cam` offers; normal pages ignore them.
- **Quality:** 1280x720 at 30 fps ideal, 2.5 Mbit/s cap per camera (`RTCRtpSender.setParameters`), 640x360 fallback chosen on the
  bandmate's page ("Stream camera quality: 720p / 360p"). Upload per bandmate ~2.5 Mbit/s on top of live audio; the streaming computer
  downloads ~2.5 Mbit/s per camera (5 bandmates: ~12 Mbit/s down) and uploads the stream itself (6 Mbit/s at OBS 32's default).
- **The streamer's own camera** goes straight into OBS (a Video Capture Device in the band scene) or into the stream page through
  `getUserMedia`; the page way keeps all tiles laid out by one director, so it's the default.
- **The catch to test first (Phase 0):** rt-video found that a page with neither camera nor microphone permission gets only an mDNS-hidden
  default-route address, which doesn't cross Tailscale. The stream page in OBS's Browser Source (CEF) is exactly such a page. The
  bandmate's side has camera permission and offers its real 100.x address, which may be enough (the receiver answers to a known address;
  peer-reflexive candidates), or may not. Fallbacks in order:
  1. OBS started with `--enable-media-stream` and the page doing rt-video's "ask for the microphone once and let go" trick;
  2. the stream page opened in a Chrome window on the streaming computer (where the permission trick is proven) and captured by OBS
     (Window Capture, or a Chrome app window) — works today, one more window;
  3. the TURN relay inside the extension already listed as a TODO in roadmap section 5 (no outside service).
- **Video vs. audio latency (the core sync problem):** live audio arrives in roughly half a round trip + its jitter buffer + two codecs
  (tens of ms between cities; rt-share measured it about 100 ms ahead of the video). WebRTC video is ~150-300 ms glass to glass. So
  each camera is late against its own sound, by a different amount per person. Audiences notice sound leading picture far sooner than
  picture leading sound (broadcast guidance, ITU-R BT.1359: detectable around 45 ms audio early vs 125 ms audio late). Plan:
  - **Line the cameras up with each other:** every video receiver gets `RTCRtpReceiver.jitterBufferTarget` (Chromium 114+) so all
    cameras sit at the same total delay, the slowest camera's plus a margin (read from `getStats`: `jitterBufferDelay` /
    `jitterBufferEmittedCount`, plus half the round trip). No frames buffered in JavaScript.
  - **Then line the sound up with the cameras:** the band mix is delayed in OBS by (common video delay − the audio's own delay),
    set through obs-websocket `SetInputAudioSyncOffset` on the REAPER audio source and re-set when it drifts by more than 20 ms (never
    during a song; between songs or on Stop). The audio's delay per bandmate is live audio's own `latency_ms` (already in
    `StudioSync_LiveAudioStatus`, shown in Health).
  - **A nudge slider** (±300 ms) on the Stream tab for what the numbers miss (camera capture lag, a USB webcam's own buffer), and a
    **clap check** (Phase 3): everyone claps once on camera; the page finds each clap in that person's audio level and the operator taps
    the frame where hands meet; the difference becomes that camera's correction.
  - Expected result: the whole show sits ~0.3 s behind real time (nobody watching can tell), each player's picture within a frame or two
    of their sound.

## 4. The stream's sound
- **Source: the session mix**, the same thing listening links and browser guests hear: REAPER's output after live audio added every
  bandmate it hears (the hub's mix when this computer hears through a hub). **Recommendation: stream from the computer that mixes** (the
  song's hub / live mix host). There, every bandmate's audio and video are measured at the same place; streaming from a computer that
  hears through the hub adds the hub→here trip to the sound (still corrected by the offset above, just later).
- **Phase 1 needs no code for audio:** OBS's **Application Audio Capture** (Windows, OBS 28+) of `reaper.exe`, or an Audio Output
  Capture of the device REAPER plays to (on the desktop, the Voicemeeter bus). Live audio already plays bandmates into REAPER's first
  output pair, so that capture is the band mix. OBS then encodes AAC once (set 320 kbit/s in the band profile; Twitch/YouTube ingest
  take it).
- **Not the listening link's Opus stream** (it would be Opus then AAC, two lossy steps, and 0.25-0.8 s of its own buffer) and **not
  `/api/mix`** (it's REAPER's output *before* bandmates are added: the screen share's on-purpose choice). If the stream ever needs the
  sound inside the browser source (one source, page-controlled sync, OBS on another computer), the small change is a loopback-only
  `/api/mix?session=1` fed from the same tap as `webui_guest_audio` (extension, additive, one flag).
- **Off-air sound:** the session mix carries the click, talkback and anything said over live audio (the audience doc's own review note).
  For a stream that matters more. Phase 1: say it on the Stream tab ("everything this computer hears goes out: click, talk between
  songs"). Later, a **stream mix**: talkback held out of REAPER's output while On air, the click on its own output pair, and a REAPER
  "Stream" bus feeding a second output pair that OBS captures instead. Bandmates arrive in the extension, not on tracks, so a stream mix
  that differs per bandmate needs live audio to put bandmates on their own output pairs or tracks: a live audio change, flagged as a
  question, not designed here.

## 5. Live view and dynamic view switching
- **Layouts, drawn by the stream page** (CSS grid over `<video>` tiles, 1920x1080 canvas, safe margins): **Grid** (everyone, equal),
  **Spotlight** (one big, the rest in a strip), **Duo** (two side by side), **Wide** (Grid with the song title and Beat bar), **Screen**
  (a screen share full, cameras in a strip: for "making of" streams, using rt-share's "like your own timeline" crop), **Holding**
  (Starting soon / Be right back / Thanks for watching, with the song's latest mix playing, as the listening page offers it).
  Tiles change with a 250 ms crossfade; a name strip and a level ring on each tile.
- **Why in the page and not as OBS scenes:** a cut is a CSS change (instant, no OBS round trip), the page knows the cameras and levels,
  and James's OBS needs just one Browser Source per band scene collection. OBS scenes are still used for what OBS owns (holding scenes
  James designs himself, a game capture in a hybrid show), switched through obs-websocket or the page's own `window.obsstudio
  .setCurrentScene` (needs the source's Page permissions at "Advanced"; no password involved).
- **The director, in Live sync (`lib/stream.lua`), publishing `stream` = { layout, focus, why, song, section, next, levels, onair,
  cams, overlays }` at most 10 times a second, only on a change.** Highest wins:
  1. **Manual** (a pin): "Spotlight Chilio", "Grid", "Holding". Stays until **Auto** is pressed again, or for N bars if pinned "for this
     section".
  2. **Song section rule:** a layout per section, from the project's regions or the Sheet page's sections, set once per song on the
     Stream tab ("Verse: Grid, Chorus: Wide, Solo: Spotlight on the soloist, Outro: Grid"). Stored with the song (a project ExtState
     key, so it travels with the project like other song settings).
  3. **The soloist:** a region or marker named "Solo: <name>" or a Sheet section with a person on it; else, during a section marked solo,
     the loudest player against their own average (so a loud drummer doesn't win every solo).
  4. **Auto, who's playing:** the per-bandmate levels live audio already measures (and this computer's input). Spotlight goes to someone
     who leads everyone by 6 dB for 1.5 s; a cut never comes sooner than 4 s after the last; back to Grid when nobody leads for 8 s or
     two people trade (Duo).
  5. **Default:** Grid.
  Each change says why ("Spotlight Chilio: solo region"), shown on the Stream tab so a wrong cut can be understood and overridden.
- **Cuts on the bar line:** the page has the beat clock (`ssBeat`: play position on the link clock and the tempo map), so a section's
  cut is scheduled for its downbeat **plus the stream delay** (section 3), landing exactly when the viewer hears the downbeat. Auto cuts snap to
  the next beat.
- **Overriding:**
  - **Web UI, Stream tab:** big buttons per layout and per person, Auto on/off, what's on air now and why, the next section's planned
    view. Works on the phone link (control needs no camera, so the plain http phone link is fine).
  - **The panel:** a small card with the same buttons (ImGui).
  - **Foot switch / controller:** one REAPER action per button ("StudioSync stream: Spotlight next player", "Grid", "Auto", "Clip
    that"), so the FCB1010, the Oxygen Pro or a Stream Deck (keys) can cut views with hands on instruments.
  - Who may: the owner, admins, and whoever the streamer names "director" for the session; a member's page shows the controls read-only
    otherwise (as other studio settings).

## 6. Band mode vs. James's gaming setup (OBS profiles and scene collections)
- OBS keeps **profiles** (output settings: encoder, resolution, bitrate, and the stream service with its key) and **scene collections**
  (scenes and sources) separately, and obs-websocket v5 (built into OBS since 28, port 4455, password on by default) can switch both:
  `GetProfileList` / `SetCurrentProfile`, `GetSceneCollectionList` / `SetCurrentSceneCollection`.
- **The Stream tab's "Band mode" button:** remember the current profile and collection, refuse if OBS is streaming or recording
  (`GetStreamStatus`, `GetRecordStatus`: "stop the stream first"), then switch to profile **"StudioSync Band"** and collection
  **"StudioSync Band"**. **"Back to my setup"** puts the remembered pair back. James's gaming profile and scenes are never edited.
- **First-time setup** (Phase 2): StudioSync can create the collection over obs-websocket (`CreateSceneCollection`, `CreateScene`,
  `CreateInput` with a `browser_source` pointing at the stream page, 1920x1080, "Control audio via OBS", plus the REAPER audio capture)
  or ship an importable collection JSON in `addons/stream/obs/` for OBS's Scene Collection > Import. The **profile** is made by James
  in OBS (Profile > New, copy of his gaming one, then the band's output settings), because it holds the stream key.
- **Who talks to OBS:** the Stream tab page on the streaming computer, served from 127.0.0.1, with the browser's own `WebSocket` and
  `crypto.subtle` SHA-256 for obs-websocket's challenge (127.0.0.1 is a secure context). No new dependency, nothing in the extension. The
  OBS password is typed by James on that page and kept in that browser's storage on that computer only: never in band.json, a topic,
  ExtState, the link or a log. The stream page in OBS can hold a second connection while in band mode, so phone commands (start/stop,
  clip) reach OBS even with no Stream tab open; switching *into* band mode needs the Stream tab (the browser source doesn't exist in the
  gaming collection).
- **Streamlabs Desktop** has its own remote-control API, not obs-websocket; not targeted. **Virtual camera:** OBS's built-in virtual
  camera already turns the band's program into a webcam for Discord or Zoom: no code needed, just documented.

## 7. Standalone or add-on: an add-on inside StudioSync (recommendation)
- **Not a separate app.** Everything a standalone app would need already lives in StudioSync: the signed link that carries WebRTC setup,
  per-room permissions, the web server and its secure tailnet link, live audio's levels and latencies, the tempo map and Sheet sections,
  profile pictures, the phone pages. A standalone app would rebuild each.
- **Add-on in the AI sense:** off for the studio unless the owner turns on "Livestream tools" (band.json, owner and admins, like `ai`);
  nothing runs, no tab shows, no camera is asked for until then. Files: `lib/stream.lua` (director, topic, actions, consent),
  `lib/webui/stream.html|js|css` (the stream page), `lib/webui/streamtab.js` (the Stream tab and OBS client), and
  `addons/stream/` for what lives outside StudioSync (the OBS collection JSON, a README for James's OBS setup, the REAPER actions for
  pedals). Shared-file edits: one `KINDS` entry in `lib/webcall.lua`, the action and tick lines in `lib/webui.lua`, a tab in `tabs.js`,
  the `/stream/` route in `extension/webui.cpp` (loopback-only, as `/api/mix`).
- **Later, a separate OBS on another computer** (e.g. the laptop streams while the desktop mixes): the stream page by a code, as a
  listening link (`https://<host>:8443/stream/?s=<code>`, tailnet only), and the sound in the page (the `/api/mix?session=1` change in
  4, over the same code). NDI isn't needed for this; DistroAV (GPL-2.0, needs NDI's own runtime and licence) stays an option James can
  install himself, not something StudioSync ships.

## 8. Privacy and consent
- **Cameras are opt-in per person, per stream:** each bandmate's page shows "Put me on the stream" (off by default, never remembered
  across streams). The streamer can't turn anyone's camera on, only ask ("James asks you to join the stream camera").
- **Everyone in the room knows when it's live,** camera or not, because their sound is in the mix: a red **ON AIR** bar on every
  StudioSync page in the room (as the sharing bar), naming the platform as the streamer labels it ("Live on Twitch, 12:04 in"), with
  **Camera off** and **Leave the stream**. A 10 s "Going live" countdown on every page first.
- **Keep me off the stream:** camera off and the person's audio muted in the streaming computer's mix (the per-bandmate mute live audio
  already has). Said plainly: it also mutes them in the streamer's monitoring if that's the same mix.
- **Off-camera members:** a name card with their profile picture, or left out entirely: their choice ("Show my name when my camera is
  off").
- **Browser guests and screen shares:** a guest's camera (later) and a screen share go on the stream only with that person's own OK on
  their page; a share to a bandmate never becomes a share to the stream by itself.
- **Chat overlay:** viewers' names and words appear on the stream; links hidden, a word filter, the director can hide a message, and an
  optional OBS stream delay as a safety buffer (OBS's own setting).
- **Recording the stream:** the ON AIR bar says "and recording" when OBS records; REAPER's own multitrack recording is the band's
  normal practice and isn't changed.
- **The stream page is loopback-only** (later tailnet by code), never on the open internet; the cameras never leave the tailnet except
  inside OBS's encoded stream.
- **Covers and music rights:** platforms' music rules and VOD claims (YouTube Content ID, Twitch's music guidelines) are James's call
  per song; StudioSync can mark songs "don't stream" so the Stream tab warns.

## 9. What needs James (never an agent)
- **Platform accounts and stream keys:** made by James, typed by James into OBS's Settings > Stream in the band profile. StudioSync never
  asks for, stores, reads, logs or moves a stream key or a WHIP bearer token, and no agent handles them. (obs-websocket can read and set
  stream service settings; StudioSync won't call `GetStreamServiceSettings` / `SetStreamServiceSettings`.)
- **OBS:** installed (30+, ideally 32.x), Tools > WebSocket Server Settings on with a password, which James types into the Stream tab.
  The band profile (copy of his gaming profile) with the band's output settings.
- **Which computer streams,** and whether its GPU/CPU can run REAPER, the hub mix and the encoder at once (NVENC on the RTX 4080 costs
  little CPU; a test stream to a private/unlisted target first).
- **Bandmates' agreement** (Chilio and others) before anyone's camera or sound goes out.
- **Anything public:** going live, the stream's title, which platforms.

## 10. Phases and effort (agent working days, tests included)
| Phase | What | Effort |
|---|---|---|
| 0. Spike | A receive-only WebRTC page in OBS's Browser Source gets a bandmate's camera over Tailscale (desktop + laptop, Chromium fake camera on the sender for the test, then real cameras only when James runs it); measure video vs live-audio lag. Picks 3's path 1, 2 or 3. | 0.5-1 |
| 1. Band on stream, manual | `cam` offers, the stream page (Grid, Spotlight, Duo, Holding), opt-in + ON AIR bar, Stream tab and phone buttons, song title overlay, OBS audio capture documented, manual sync nudge (set in OBS by hand). Lua tests, stand-in server + headless Chromium with fake devices. | 3-4 |
| 2. OBS link | obs-websocket client in the Stream tab: Band mode / Back to my setup, start/stop stream and recording, status (live, dropped frames, kbit/s) on the tab and Health, automatic audio sync offset, first-time collection setup or import JSON. Tested against a stand-in obs-websocket server (its protocol is documented; no real OBS in CI). | 2-3 |
| 3. Auto director | Loudest player with hysteresis, section rules, soloist, cuts on the bar line, per-camera alignment with `jitterBufferTarget`, clap check, panel card, REAPER actions for pedals. | 2-3 |
| 4. Extras | Pick from 11, each 0.5-2. | as picked |
| Later | Stream mix (needs a live audio change), OBS on another computer by code, guest and phone cameras. | 2-4 |

Phase 1 alone gives a watchable band stream; Phase 2 is what makes "switch back to gaming" one click.

## 11. Other useful or cool features (pick list)
- **Now playing:** song title and "next up" lower third from the song in front and a setlist (the studio's songs in an order the band
  sets); changes on its own when the next song opens.
- **Lyrics and chords on screen:** the Sheet page's sections and lyrics, following the transport (the Beat page's clock), karaoke-style
  for the audience; the AI add-on's "Lyrics from a vocal take" can fill them.
- **VU meters and level rings** on each tile and a master meter, from levels StudioSync already has.
- **Beat-synced touches:** the Beat page's bar.beat and count-in as an overlay, tile pulses on the downbeat, cuts on the bar.
- **Chat overlay, and chat to the band:** Twitch chat read anonymously over its IRC WebSocket (read-only, no account needed), shown on
  the stream and in StudioSync's chat for the band (read-only, marked as viewers'), so players see requests on their own screens. YouTube
  chat needs a Data API key and quota (James's account): later.
- **Clip that:** a button/pedal saves OBS's replay buffer (`SaveReplayBuffer`) and drops a REAPER marker "Clip 1:03:12" at the moment,
  so the lossless multitrack of that moment can be rendered for a proper clip later.
- **Local recording of the stream:** OBS records the program (Hybrid MP4, OBS 32's default) beside REAPER's multitrack.
- **Post-show remaster:** the VOD's sound replaced with a proper mix of REAPER's lossless multitrack (rt-double's full-quality copy while
  jamming), lined up by the clap or the stream's start marker, muxed under OBS's recording: a better-sounding upload than the live one.
- **Multi-platform:** OBS streams to one service per profile; for several at once, a restreaming service or the obs-multi-rtmp plugin
  (GPL-2.0), James's choice. Twitch also takes WHIP (OBS 30+, H.264 + Opus; YouTube does not list WHIP: RTMP(S), HLS, DASH).
- **Holding scenes with music:** Starting soon / Be right back playing the song's latest mix (as the listening page does) with a
  countdown.
- **Producer stream:** the Screen layout with rt-share's REAPER timeline crop and its pointer/notes, for "how we made this" streams.
- **Phone as a second angle:** a one-time camera link on the secure tailnet port (the guest-link path, 8443), so a phone on a mic stand
  becomes a drum or hands cam, opted in on the phone.
- **Hybrid gaming + music:** a band scene with James's game capture in a corner (an OBS scene, switched like the others).
- **Listening link as the audio-only option:** viewers who want only sound get a listening link (tailnet, or public through Funnel when
  James allows it) at the same time.
- **Stream health for the band:** a small "live 12:04, 6.0 Mbit/s, 0 dropped" on every member's ON AIR bar, from OBS's stats.

## 12. Review later (security)
- The stream page is a new `/stream/` route: loopback-only like `/api/mix`; when tailnet access by code comes, it needs the listening
  links' allow-list treatment (only its own files, codes as bearer secrets, revoke, rate limits).
- A `cam` offer reaches only the streaming computer's stream page, through the same checks as `call`/`screen` (signed link, in the room
  now, SDP size); the stream page must still refuse cameras from anyone who hasn't opted in this stream (the opt-in travels in the
  `stream` topic, and the page matches it against the offer's sender).
- The OBS password lives in one browser's storage on the streaming computer: anyone with that user's browser profile has it, and
  obs-websocket listens on all interfaces by default (tell James to keep its password on, or bind it to 127.0.0.1 where OBS allows).
- An obs-websocket client can read the stream key; StudioSync must never call the stream-service requests (a test can grep for them).
- Chat overlay text is viewers' input shown on the stream and in the band's chat: text only, length-capped, no links, no markup.
- Director rights: phones on the studio link can send `stream` actions; limit to owner/admins/director as other settings.

## Sources and licences (checked 2026-11-21)
- OBS Studio: GPL-2.0-or-later. Not borrowed from; driven over its documented protocol. 32.0 release notes (plugin manager, 6000 kbit/s
  default, Hybrid MP4 default): https://obsproject.com/blog/obs-studio-32-0-release-notes
- obs-websocket v5 protocol (GPL-2.0, built into OBS since 28; SHA-256 challenge/salt auth; requests named above):
  https://github.com/obsproject/obs-websocket/blob/master/docs/generated/protocol.md . Only the protocol is used, so no licence applies to
  StudioSync's own client code.
- OBS Browser Source and `window.obsstudio` (Page permissions levels; `setCurrentScene` at Advanced): https://github.com/obsproject/obs-browser
- WHIP in OBS (since 30; Twitch among supported services; bearer token = stream key; simulcast from 32.1):
  https://obsproject.com/kb/whip-streaming-guide . YouTube's ingest protocols (RTMP, RTMPS, HLS, DASH; no WHIP):
  https://developers.google.com/youtube/v3/live/guides/ingestion-protocol-comparison
- How remote bands stream today: SonoBus or Jamulus for audio, VDO.Ninja for cameras, OBS to stream, sync by hand
  (https://docs.vdo.ninja , OBS forum threads on SonoBus + VDO.Ninja). VDO.Ninja's licence is its own "mostly open-source" LICENCE.md (its
  OBS plugin is AGPL-3.0-only): **not borrowed from**, an inspiration only; StudioSync's WebRTC path already exists.
- NDI / DistroAV (plugin GPL-2.0; needs NDI's runtime under NDI's own licence): not used or shipped.
- obs-multi-rtmp (GPL-2.0): mentioned for James to install if he wants simulcast; not bundled.
- Twitch chat over IRC WebSocket (read-only anonymous): Twitch developer docs; YouTube Live Chat via the Data API (key + quota).
- Lip-sync tolerance: ITU-R BT.1359.
- No new third-party dependency is proposed: browser WebSocket, WebRTC, `crypto.subtle`, and OBS's own features.

## Decisions for James
1. **Which computer streams**: the desktop (also the gaming PC?) as mix host + OBS, or OBS on another computer (later phase).
2. **Go-ahead for Phase 0**, which needs a real OBS on two computers over Tailscale (no real camera needed until you run it yourself).
3. **OBS setup on your side:** obs-websocket password on; a "StudioSync Band" profile you make (it holds the stream key).
4. **Audio for Phase 1:** OBS capturing REAPER's output as-is (click and talkback go out too), or wait for a stream mix (needs a live audio
   change).
5. **Default director:** Auto (loudest player + section rules) or manual-first with Auto as a button.
6. **Who may direct:** owner/admins only, or a named director per stream (e.g. a phone held by someone not playing).
7. **Bandmates' consent rules:** cameras opt-in per stream (proposed); do off-camera members show as a name card by default?
8. **Platforms:** Twitch, YouTube, both (restream service vs obs-multi-rtmp), and whether covers get streamed.
9. **Which extras first** from section 11.
