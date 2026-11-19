# StudioSync realtime: tools, libraries and products worth using (2026-11-19)

Based on docs/realtime-roadmap.md. Licences checked on the web unless marked (mem) = from memory, check the LICENSE file before vendoring. GPL-3.0-or-later can absorb MIT/BSD/ISC/zlib/Apache-2.0/MPL-2.0/LGPL/GPL-2.0-or-later. It cannot take GPL-2.0-only, and AGPL would spread its network clause.

## Top 10 by value for effort

| # | Candidate | What it does for StudioSync | Effort |
|---|---|---|---|
| 1 | **Tailscale Peer Relays** (the desktop as the band's UDP relay) + the free plan now allowing **6 users** | Fixes the "DERP adds latency" risk with no code: Tailscale tries a peer relay before DERP. A 5-piece band fits one free tailnet. Health only has to report direct / peer-relay / DERP. | Config only |
| 2 | **VST3 SDK under MIT (3.8, Oct 2025)** + **CLAP (MIT)**, built with **DPF (ISC)** | The "StudioSync Hop" plug-in no longer faces a GPL-or-proprietary licence choice. DPF builds CLAP, VST3 and AU from one small source with no GUI, so Hop stays tiny. | Small |
| 3 | **AOO 2.x (BSD-3, C++ with a C API)**, the engine inside SonoBus | Ready-made step-4 transport: Opus/PCM sources and sinks, an adjustable jitter buffer, clock drift fixed with a DLL plus dynamic resampling, a codec plug-in API (FLAC can be added), and multi-peer groups. Use it whole or as the reference design. | Medium |
| 4 | **yyjson (MIT, mem)** | One C file. Moves JSON encode/decode into the extension; the 210 ms decode of 10 MB in Lua should fall to around 10 ms. | Very small |
| 5 | **zstd (BSD/GPL-2 dual, mem) with a trained dictionary** + **xxHash/BLAKE3 (BSD-2 / CC0-Apache, mem)** | A dictionary shrinks small JSON events several times over on the link and in snapshots. Fast hashes for change detection; SHA-256 stays for signatures. | Small |
| 6 | **SQLite amalgamation (public domain)** | Index for history, snapshots and comments. Song history playback and "what did we do Tuesday" become queries. | Small-medium |
| 7 | **Opus 1.5 Deep PLC / DRED, plus custom modes** (inside libopus, BSD) | Neural loss concealment and redundancy hide lost packets far better than classic PLC. Building with `--enable-custom-modes` allows 64/128-sample frames, the way Jamulus does it, which cuts latency. | Small (build flags, a bigger binary) |
| 8 | **webview/webview (MIT)** or **Saucer (MIT)** over WebView2/WKWebView/WebKitGTK | The docked web UI without CEF's ~150+ MB. | Medium |
| 9 | **Yjs (MIT)**; **yffi/yrs (MIT, C FFI)** in the extension or hub | CRDT for the song sheet, chat, comments and to-dos: offline edits merge, and you get presence and undo. Send its updates as link messages. | Medium |
| 10 | **Ableton Link (GPL-2.0-or-later) as a local bridge** | Link can't cross a WAN: it uses multicast discovery, and Tailscale has no multicast. Each computer can still run a local Link session driven by StudioSync's shared clock, which locks every bandmate's Ableton, iOS apps and Link hardware to the band's beat. | Small-medium |

Honourable mentions: wavesurfer.js (BSD-3) for waveforms; Excalidraw (MIT, mem) for drawing; LiveKit (Apache-2.0, mem) for video with more than ~4 people; iroh for the Tailscale-free path.

## By area

### Networking / NAT
- **libtailscale / tsnet (BSD-3).** Builds as a Go `c-archive`, so bandmates get a tailnet IP from userspace with no Tailscale app and no admin rights. The README makes no maturity statement. Risks: it puts a Go runtime of about 20-30 MB (mem) inside REAPER's process, two Go runtimes clash if another plug-in also embeds Go, macOS needs a lipo of two archives, and users still need a tailnet login or auth key. Headscale (BSD-3, mem) is the self-hosted control server. Verdict: later, and only if the app is the real barrier.
- **libdatachannel + libjuice (MPL-2.0 since 0.18; GPL-compatible).** C++17 with a C API. ICE/STUN/TURN, data channels (reliable or unreliable), and media tracks. Needs only OpenSSL or GnuTLS. Mature. Verdict: the best Tailscale-free option inside a C++ extension. You still need a small signalling/rendezvous server and TURN for strict NATs.
- **iroh 1.0 (MIT/Apache-2.0, Rust).** QUIC with hole punching and relay fallback. iroh-blobs does BLAKE3-verified, resumable content-addressed transfer, which is essentially roadmap step 3. Rust: needs a C shim (iroh-ffi targets other languages). Verdict: strong if the extension ever takes on Rust.
- **QUIC: msquic (MIT), ngtcp2 (MIT, needs a TLS library), quiche (BSD-2, mem).** Streams and datagrams on one connection, without head-of-line blocking. Over Tailscale this is encryption on top of WireGuard, and the TCP+UDP split already handles head-of-line blocking. Skip, unless you go Tailscale-free (iroh covers that case).
- **ENet (MIT, mem).** Reliable and unreliable UDP channels, no encryption, no NAT traversal. Little gain now that SSA1 is designed.

### Real-time audio
- **libopus / libFLAC.** Already chosen (BSD-3); see #7 for the Opus 1.5 extras.
- **AOO (BSD-3).** See #3. NAT traversal through its server/client is from memory: check it.
- **JackTrip (core MIT/Expat; GUI files GPL-3+).** Ideas: hub-server mixing and loss concealment for PCM.
- **Jamulus (GPL-2.0+ per Debian, GPL-2.0-only per AUR).** Ideas only, don't copy code: the server mixes one stream per client (the roadmap's hub mixing), an auto jitter buffer, and small Opus custom frames.
- **Resampling for drift.** Try REAPER's `Resampler_Create` first (no new dependency) and check that `SetRates` per block is click-free. Then **speexdsp** (BSD-3, `set_rate_frac`, cheap, built for VoIP drift). **libsamplerate** (BSD-2, mem) changes ratio smoothly but costs more CPU. **r8brain** (MIT, mem) is high quality but made for fixed ratios, a poor fit for drift.
- **Jitter buffer.** Copy AOO's design (DLL plus resampling) rather than WebRTC NetEq, which is heavy and tangled.
- **Ableton Link.** See #10. **Link Audio** (Live 12.4, 2026) streams audio between Link peers but only on the local network. Its "pick a peer as a track input" is a model for receiving a bandmate's audio on a track.

### Plug-in side
- **VST3 SDK.** MIT since 3.8; GPLv3/proprietary is no longer offered; VST2 is not included.
- **CLAP.** MIT (mem).
- **DPF.** ISC (mem): CLAP/VST3/VST2/LV2/AU from one source, small. Best fit.
- **iPlug2.** WDL/zlib-style (mem); fine but larger.
- **JUCE 8.** AGPLv3 or commercial. Avoid: AGPL inside a GPL package adds the network clause, and the framework is heavy for a GUI-less plug-in.
- **Check:** REAPER's CLAP host extension (`cockos.reaper_extension`, mem) for Hop to reach `StudioSync_*` functions.

### Web UI in REAPER
- **WebView2** is preinstalled on Windows 10/11; link it statically with WebView2LoaderStatic. You must forward accelerator keys to REAPER (`AcceleratorKeyPressed`) or shortcuts break. WKWebView is fine inside a SWELL NSView.
- **Linux risk.** SWELL-GDK windows are not GTK widgets, so embedding WebKitGTK is hard. Fallback: serve the same page and open it in the system browser.
- **CEF** (BSD-3): too big.
- **Saucer** (MIT): WebView2, WKWebView, WebKitGTK and Qt backends, with C++ bindings.
- **REAPER's built-in web interface** (custom pages in `reaper_www_root`, plus the `/_/` command API including ExtState get/set). Zero-code stopgap for phone pages ("Listen from anywhere", remote transport), and it can already talk to Lua through ExtState. Its auth is weak (optional password), so keep it on the tailnet only.
- **Helgobox / ReaLearn** (GPL-3). The open repo's UI is its own Win32/SWELL framework. It runs an HTTP/WebSocket server for "Projection", and gRPC is planned for apps like Playtime 2. The external-app-over-a-local-server pattern matches the roadmap.
- **Front end.** wavesurfer.js (BSD-3), or peaks.js (LGPL-3, fine) fed from REAPER's peak data. Draw the timeline on your own canvas/WebGL: no timeline library fits the DAW model well.
- **Drawing.** Excalidraw (MIT). **Avoid tldraw**: SDK 4 needs a licence key for production and a watermark you may not remove.

### Video / screen share
- WebRTC inside the web view, peer to peer, is fine for 2-4 people. WebView2 needs a `PermissionRequested` handler. Whether `getDisplayMedia` works in WKWebView is unverified; check it early.
- For more people, self-host **LiveKit** (Apache-2.0, a single Go binary) on the hub, or **mediasoup** (ISC, Node + C++).

### Data / history
- SQLite, zstd, lz4 (BSD-2, mem), yyjson, and simdjson (Apache-2.0/MIT, mem; overkill next to yyjson).
- **Don't** move the project model to Automerge/Yjs: StudioSync's event log is already op-based. Use a CRDT only for the text-like documents (song sheet, chat, comments).

### REAPER-specific
- **What CSurf covers** (checked against `reaper_plugin.h` on disk): track list, volume/pan/mute/solo/selection/arm, play state, repeat, track title, automation mode, plus `CSURF_EXT_*`: FX param/change/enable/open/focus/preset, send/receive volume and pan, BPM/playrate, metronome, record mode, input monitor, project marker changes.
- **What it misses:** items and takes (move/trim/split/add), MIDI note edits, envelope points, track colour, routing added, project settings. Keep `GetProjectStateChangeCount` plus targeted diffs for those.
- **reaper-rs** (MIT, mem): only if you move to Rust.
- **SWS** (MIT, mem): a reference for "preview through track".
- **ReaBlink** (ak5k): exposes Link to ReaScript, so REAPER itself can follow #10's bridge. Licence unverified.

### Other
- **whisper.cpp** (MIT, mem): session notes, and lyrics into the song sheet.
- **Demucs**: code MIT, maintained fork adefossez/demucs, original archived Jan 2025; check the weights' licence separately. Stem splitting.
- **Basic Pitch** (Apache-2.0, mem): audio to MIDI on CPU.
- A local LLM for mix notes (on the hub).
- All of these need GPU or heavy CPU: ask James every time.

## Competitor features StudioSync lacks
- **VST Connect:** the engineer controls the remote performer's cue mix and talkback; talkback mutes itself during recording; a free Performer app for people without a DAW (StudioSync's web recorder); the HQ recording uploads in the background and replaces the compressed one (this confirms "fast first, lossless after").
- **BandLab:** **forks** (branch a song to try an arrangement, merge back), published revisions, Splitter stems, one-click mastering, invite by username/email.
- **Soundtrap:** video chat inside the editor; comments while tracks are being laid down; share by link.
- **Pibox/Filepass:** timestamped comments that carry across mix versions with a resolved state; expiring or password-protected client links; a lossless review page.
- **Audiomovers / dBaton CUE:** master bus to a browser for approvals (StudioSync's "Listen from anywhere").
- **NINJAM:** already planned (step 2).
- **REAPER gap:** no REAPER-native shared-project tool was found (BeatConnect doesn't list REAPER; Satellite is 2021-era). StudioSync appears to be alone here.

## Sources
- https://github.com/tailscale/libtailscale
- https://tailscale.com/blog/peer-relays-beta
- https://tailscale.com/kb/1591/peer-relays
- https://tailscale.com/docs/account/manage-plans/free-plans-discounts.md
- https://tailscale.com/blog/pricing-v4
- https://libdatachannel.org/
- https://github.com/n0-computer/iroh
- https://docs.rs/crate/iroh/latest
- https://en.wikipedia.org/wiki/MsQuic
- https://raw.githubusercontent.com/Spacechild1/aoo/develop/LICENSE
- https://github.com/essej/aoo
- https://github.com/essej/sonobus
- https://soundingfuture.com/articles/aoo-low-latency-peer-peer-audio-streaming-and-messaging
- https://sources.debian.org/copyright/license/jacktrip/2.5.1%2Bds-1
- https://en.wikipedia.org/wiki/Jamulus
- https://browse.dgit.debian.org/ableton-link.git/tree/LICENSE.md
- https://help.ableton.com/hc/en-us/articles/25425913328924
- https://www.ableton.com/release-notes/live-12/
- https://steinbergmedia.github.io/vst3_dev_portal/pages/VST+3+Licensing/VST3+License
- https://www.soundonsound.com/news/steinberg-adopt-mit-license-vst3
- https://forum.juce.com/t/juce8-license-and-open-source-projects/60987
- https://github.com/saucer/saucer
- https://github.com/helgoboss/helgobox
- https://tldraw.dev/legal/tldraw-license
- https://tldraw.dev/sdk-features/license-key
- https://unpkg.com/wavesurfer.js@6.6.4/README.md
- https://github.com/suterma/vue-peaks
- https://docs.rs/crate/yffi/0.26.0/source/Cargo.toml
- https://github.com/facebookresearch/demucs
- https://download.steinberg.net/downloads_software/VST_Connect_Pro/VST_Connect_5_Operation_Manual.pdf
- https://help.bandlab.com/hc/en-us/articles/48041963115033-What-is-Forking
- https://help.bandlab.com/hc/en-us/articles/48010528581529-How-do-I-invite-other-users-to-collaborate
- https://soundtrap.com/content/blog/collaboration
- https://tapeop.com/reviews/gear/140/filepass-file-sharing-utility
- https://pibox.com/plugin/
- https://www.production-expert.com/production-expert-1/dbaton-cue-stream-your-daws-master-bus-to-any-browser-in-real-time-for-remote-mix-approvals
- https://www.kvraudio.com/product/beatconnect-by-beatconnect
