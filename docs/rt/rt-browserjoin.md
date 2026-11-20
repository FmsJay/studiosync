# Browser guests: join from a browser with an audio interface, no REAPER (rt-browserjoin, 2026-11-20)

James: "Quick invite for people without reaper if not already being worked on, needs audio interface and asio support for all platforms".
Native tests, Lua tests, and headless Chrome with fake media devices against a stand-in server built from the real `extension/webui.cpp`
and the real pages. **Not run in REAPER, on a phone, or between two computers yet. The extension's version was not raised.**

## What it does
1. **The host makes a guest link.** Web UI, Home, under Who's here: **Browser guests** (owner and admins only; `groups.may_manage`). Type
   their name, **Make a guest link**. The link is `https://<this computer's MagicDNS name>:8443/guest.html?g=<24 hex>`: the studio's existing
   secure phone link (`tailscale serve`, set up by itself as the phone app does; tailnet-only, nothing on the open internet). It's shown
   with **Copy** until it's used or runs out; it's never saved anywhere.
   - The code works **once** (the first browser that opens it), within **30 minutes**; the session it opens lasts **4 hours** (10 minutes to
     12 hours if a page asks). The guest is scoped to the project and room in front when the link was made.
   - Rate limits: one link every 5 s, 12 an hour, 4 guests at a time (the extension takes 8, and 2 live at once).
   - Each guest shows as waiting / joined / live, with their level here, a **volume** (what this computer hears and sends of them) and
     **End** (kicks them at once: their socket, stream and cookie stop working within 0.1 s).
2. **The guest opens the link** (Chrome, Edge, Firefox or Safari; they must be on the studio's Tailscale, like any phone link). The server
   swaps the code for an HttpOnly session cookie and drops the code from the address. The page shows the project, who invited them, where
   the song is and when the session ends. They pick their **interface** (input), **channels** (input 1, input 2, 1+2 stereo, 1+2 mono), the
   **output** where the browser allows it (`AudioContext.setSinkId`, Chrome/Edge), and press **Join with this interface**.
3. **Live.** They hear the session and are heard (below). Mute me, a headphone volume, an input meter.
4. **Takes.** **Record a take**: recorded here, lossless (32-bit float WAV, the picked channels), while the host's REAPER plays; it stops
   by itself when the host stops (or on Stop), uploads, and goes in as an ordinary take on **"<name> (guest)"** (made at the end of the
   project if it isn't there) through the phone-take path (`phonerec.put_with`): the same placement, trim to the stretch played, naming,
   BWF stamp and note file. The computer's answer ("<take>: on Bo (guest) at bar 5, in time to about 8 ms") shows on the guest's page.
   **Send again** and **Save the take to this computer** if the upload fails.
5. **Loopback test** (**Measure**): 8 clicks on their output; a cable from an output to an input (or headphones held to the mic) brings
   them back; the median lateness is their round trip, kept per input/output in the browser. Until then the page uses the browser's own
   latency figures (and says "estimated").
6. **Leave the session** ends it from their side.

## How the audio goes (and why this path)
- **One WebSocket per guest, straight to the extension** (`GET /api/guest/live`, `extension/webui.cpp`), not WebRTC. WebRTC would need
  either a DTLS-SRTP stack in the extension (new dependencies) or a host browser page in the middle, which then still needs a way to hand
  PCM to REAPER and get REAPER's mix out: two hops, a page that must stay open, and the mDNS/Tailscale candidate problem rt-video hit. The
  socket uses the server and Tailscale path the pages already use, and the audio hook the screen share's sound already uses.
- **Down (to the guest):** the hook's post call, *after* live audio added the bandmates it hears and *before* any guest is added, copies
  this computer's output pair into a ring (`webui_guest_audio`). The socket sends it as frames `[SG1\0][u32 rate][f64 link clock of the
  first frame][16-bit stereo]`, 5 ms or more each. So the guest hears REAPER's mix plus every bandmate (the hub mix, when this computer
  hears through a hub), never themselves.
- **Up (from the guest):** 16-bit mono (the picked inputs mixed) at REAPER's rate, ~10 ms a message. A ring per guest; the audio thread
  starts playing it once 60 ms has come, trims back to 60 ms past +150 ms (the two sound cards' drift, a burst after a stall), and on an
  underrun goes silent until it has refilled. It's added to this computer's output (heard here, not recorded) and, through one hook in
  `rt_capture` (`rt_talk_add`), into the Talk this computer sends, so the bandmates hear the guest too.
- **Rates:** the page runs its AudioContext at REAPER's rate (from the guest topic; the browser converts to the device), so nothing is
  resampled in the extension. A rate change in REAPER restarts the page's audio.
- **Codec:** none: 16-bit PCM. Down is ~1.5 Mbit/s stereo at 48 kHz, up ~0.77 Mbit/s. Fine on home connections over Tailscale, heavy on
  mobile data. Opus through WebCodecs (`AudioEncoder`/`AudioDecoder`) on the page and the extension's own libopus is the next step if
  bandwidth bites (the frame header leaves room for a codec byte).
- **Latency (estimates, not measured on real networks):** the guest hears the session one network trip + ~80 ms (the page's jitter
  buffer) + their output latency late; the host hears the guest one trip + ~60 ms + their input latency; bandmates hear the guest through
  the host's Talk, a second trip later. TCP means a lost packet stalls the stream briefly instead of a click; the rings catch up after.
  Good for talking, cueing and playing along; not for playing tightly together live (that's what the takes' placement is for).
- **Takes in time:** the worklet (`guestworklet.js`) does both directions on one frame clock, and maps each output frame to the link-clock
  stamp it carried. The take's first input frame f0 was played along to output frame f0 - round trip, so `t0 = stamp(f0 - round trip) +
  REAPER's output latency` (the stamp is when the hook processed the block; it's heard that much later). Lua places it with the same play
  readings and median maths as a phone take (`phonerec.place`). Expected error: the loopback test's precision (~1 ms) plus the stamp's
  block jitter (a few ms); without the test, tens of ms (the page says so; the take's `err` says 30 vs 8 ms).
- **Echo:** the browser's echo cancellation is off (it would wreck music), so **headphones are required**: speakers would send the session
  (bandmates included) back to everyone, a round trip late. The page says so. No speaker mode in this slice.

## ASIO and pro audio, honestly, per system
Browsers can't open ASIO drivers. What the page gets:
- **Windows:** WASAPI **shared** mode through the browser (Chrome/Edge/Firefox), the browser's own buffer (often 10-20 ms each way on top
  of the interface's). Exclusive mode isn't reachable from a page. The interface's Windows sample rate should match the session's; a DAW
  holding the interface in ASIO/exclusive mode can leave the browser with no input. Many interfaces' ASIO and WASAPI drivers coexist.
- **macOS:** Core Audio, the interface as it is, low latency; an aggregate device for more inputs.
- **Linux:** PipeWire (or PulseAudio) as the browser's audio; JACK clients through `pipewire-jack`.
- **All:** two input channels at most reach a page (Chrome gives 2; some setups 1, said on the page); raw input is asked for
  (`echoCancellation/noiseSuppression/autoGainControl: false`, `latency: 0`), and the page warns when the browser kept echo cancellation on.
- **Later, a tiny native helper** (not built): a small signed app per OS that opens ASIO / WASAPI exclusive / Core Audio / JACK at low
  buffer sizes and speaks the same WebSocket frames as the page (or the live audio's AOO UDP directly). The extension side wouldn't change.

## Files
- New: `lib/guestweb.lua`, `lib/webui/guest.html`, `guest.js`, `guest.css`, `guestworklet.js`, `guesthost.js`, `tests/test_0_60_rt_browserjoin.lua`,
  this doc.
- `extension/webui.cpp`, `extension/webui.h` (additive): guest sessions (`webui_guest_auth`, `webui_guest_path`), `/api/guest/*` (events
  filtered to the guest's topic, actions wrapped, uploads), the WebSocket (`webui_ws_accept`, SHA-1 for the handshake only), the guest
  rings and `webui_guest_audio`/`webui_guest_talk`; ReaScript `StudioSync_WebUIGuest(gid, code, code_seconds, session_seconds)`,
  `StudioSync_WebUIGuestGain(gid, gain)`; `StudioSync_WebUIStatus` adds `guests`; `webui_mix_wanted` counts live guests (the hook stays in).
- `extension/rtaudio.cpp`, `rtaudio.h`: **exactly these small additive hooks:** `void (*rt_talk_add)(float *const *, int, int)` (declared
  in rtaudio.h, null by default), called in `rt_capture` after the Talk inputs are copied and only while sending (`if (on && rt_talk_add)`);
  `webui_guest_audio(out, nout, len, srate)` after `rt_mix` in the hook's post call; `rt_talk_add = webui_guest_talk` in `rtaudio_register`.
- `lib/phonerec.lua`: `phonerec.put_with(proj, cfg, b, t, readings)` (a take placed by given readings; the Record page's own words and nudge
  target left alone).
- Shared files, small additive edits: `lib/webui.lua` (`ACTIONS.guestweb`, its dispatch, `guestweb.tick` at the end of the tick),
  `lib/webui/index.html` (guest.css and guesthost.js after the AI page's), `tests/webui_test.cpp` (guest tests; two stand-in files).
- Topics: `guestweb` (host pages: may, guests [gid, name, song, room, ends, by, here, joined, live, peak, under, drops, gain, link], last),
  `guest-<gid>` (that guest only: name, song, room, here, host, ends, playing, rec, pos, at, rate, bar, outlat, srate, said, said_at).
  Actions on `guestweb`: host `make = { name, minutes }`, `kick = gid`, `gain = { gid, v }`; guest (wrapped by the server as
  `{ topic, gid, a }`) `take = { id, t0, len, err, cid, title }`, `leave`.

## Tests
- `tests/webui_test.cpp` (built and run here, all ok; CI runs it on Windows/macOS/Linux): RFC 6455's handshake vector; the guest path list
  (nothing of the studio's: `/`, `/api/state`, `/api/events`, `/api/file`, `/api/mix`, `/api/time`, `/api/action`, `/api/upload`); the code
  from another site, wrong, on the wrong page, run out; redeemed once (a second browser refused, the first keeps its session); the cookie
  only for the guest API; through `tailscale serve`; session run out. Live: the link on the studio's address -> 303 with an HttpOnly Lax
  cookie; the guest's page and shared files but no studio page, state or topic; the studio token doesn't open the guest API; the event
  stream carries only their topic (another guest's and the band's never), ends when kicked, and the cookie stops working; actions arrive
  wrapped; closing the object early to add another `gid` refused (strings and escapes understood); 8 queued per guest at most; uploads get
  the guest's gid as prefix, the earlier one let go, the phones' path refused; the socket: the studio token refused, 101 with the right
  accept, the hook wanted while live, a second window refused, the guest heard at 0.25 on top of REAPER's output and in the Talk, the down
  frames stamped (rate, link clock) and without the guest, the host's level 0 silences them, ping/pong, an unmasked frame or a flood (far
  past real time) closes it, kicked while live closes it, gone from the status.
- `tests/test_0_60_rt_browserjoin.lua`: the link; host and guest actions checked (a guest's `make`/`kick`/`gain` is nothing; another guest's
  upload id refused); alive (run out, forgotten by the extension); rate limits; a member can't make links; the code never saved; host and
  guest topics (the guest's carries nothing else; no position for another project); used links hidden; volume; a take through a stand-in
  REAPER: the guest track made, placed by the readings (8 s, its pre-roll inside), told to the guest, once only, paced, waits for another
  project, refused (no track made) when the room's rules say no; leave, kick, run out, forgotten after a REAPER restart; wiring in
  webui.lua; the pages (only their own files, no inline script/style, no innerHTML/eval, only `api/guest/`, raw input constraints).
- **Headless Chrome, fake devices only** (a 1 kHz WAV as the fake mic, `--use-fake-device-for-media-stream`; scratch scripts, not committed:
  a stand-in exe from the real webui.cpp/direct.cpp serving the real `lib/webui`, a fake audio thread with a 440 Hz "REAPER output", a fake
  Lua publishing the guest topic; Node driving Chrome over CDP): the link redeemed and the code gone from the address; the cookie unreadable
  by script; Join: AudioContext at 48 kHz running, the socket open, the mix flowing (map points), the input asked raw (echo cancellation,
  noise suppression, gain control all false); the fake mic's 1 kHz heard at the stand-in host at exactly 0.25 peak / 0.177 RMS for ~25 s
  with 1-2 underruns; Mute silences it, Unmute brings it back; the loopback test with no cable says "No clicks came back" (a steady tone
  isn't taken for a click); findLatency on synthetic clicks (1234 frames, 900 on top of a tone; null with nothing back); a take armed before
  the host played, stopped by itself 0.6 s after the host stopped, uploaded (14.07 s, 2.7 MB float WAV) with t0 consistent with the arm
  time; Leave posts `leave`. Host page on 127.0.0.1: the Browser guests box, a hostile name shown as text, the link with Copy, Make / End /
  volume actions sent.

## Check in REAPER (real computers)
1. Desktop: Live sync on in a project with live audio on; web UI Home > Browser guests > type "Test" > Make a guest link. HTTPS
   certificates must be on for the tailnet (the phone link's rule); the log says the secure link was set up.
2. On the laptop (on the tailnet, in a browser, **not** REAPER), open the link: the guest page shows the project and "invited by". Open the
   same link in another browser: "used already".
3. Join with the laptop's interface (UR22mkII), headphones on. On the desktop: the Browser guests row says live with a moving level; you
   hear the laptop's input; the laptop hears the desktop's REAPER mix and, if Chilio's Mac is on live audio, Chilio. Chilio hears the guest
   too (through the desktop's Talk). Desktop Mute me: the guest goes silent for Chilio as well (expected).
4. Laptop: Measure with a cable from the UR22's output to its input 2 (pick input 2 for the test, then back): a round trip in ms is shown.
5. Laptop: Record a take, desktop presses Play from bar 5, then Stop: a take appears on "Test (guest)" at bar 5; check it lines up with the
   click/backing it was played to (nudge figures in ms). Check REAPER sees the BWF position (Item > move to source preferred position).
6. Desktop: the guest's volume slider, then End: the guest page says "The host ended your session", and the link/page stop working.
7. Change REAPER's sample rate while the guest is live: the page restarts its audio.
8. Health: watch the desktop's audio callback time with a guest live (the hook does a copy and a mix per block).

## Untested / limits
- Nothing ran in REAPER: the hook placement, `GetOutputLatency` as the stamp's offset, the hook staying in while only guests use it
  (`mix_timer` via `webui_mix_wanted`), and real-network latency are unverified. The 60/80 ms buffers are guesses to tune.
- The guest must be on the studio's Tailscale (as a phone is): there's no public path. The NAT links (rt-nat) don't carry web pages.
- No drift-correcting resampler: the rings trim and refill, which is audible as a small skip every so often on long sessions (counted in
  the status as `under`/`drops`, shown on the host's row).
- Guests don't hear each other (both are added after the session mix is copied); two live at once at most.
- One take is held per guest on the computer (a new upload replaces their previous one); 160 MB per upload (~7 minutes mono float).
- Take names use the phone-take naming ("<name> - phone take" when smart names are off; the file is "<song> phone <name> ...").
- iPhone Safari: not tried; AudioWorklet and getUserMedia exist, `setSinkId` doesn't (default output only).
- The panel (ImGui) has no guest UI; only the web UI's Home.

## Review later (security)
- **The code and session secrets** come from `band.secret` (REAPER's GUIDs) and `std::random_device`: fine on Windows/macOS/Linux
  toolchains used, but neither is documented as a CSPRNG. Consider the OS CSPRNG directly.
- **The cookie is per browser, not bound to anything else:** whoever copies it (same machine, a proxy log) is the guest until the session
  ends or is kicked. Sessions are 4 h by default; consider shorter with a refresh while live.
- **The guest link is a bearer secret in a URL** (chat apps preview links: a preview fetch from a tailnet device would redeem it first).
  Tailnet-only limits who can, but consider a confirm step on the page before redeeming (GET shows a button, POST redeems).
- **Guest uploads take memory** (two guests' takes held, 160 MB each) and a guest can make the host's computer write files in the
  project's folder (only WAVs that pass the magic check, only onto their own track). Rate-limited to one take every 3 s per guest.
- **Up audio isn't authenticated per frame** beyond the session cookie on the socket; a guest can send any sound (it's their voice, by
  design), up to 3x real time before the socket closes. Their level can be set to 0 or they can be ended.
- **The session mix goes to the guest whole:** every bandmate live audio carries, in any room of this project the host is in. Guests
  hear what the host hears; a "guest mix" with chosen tracks only would need a REAPER-side send.
- **The guest topic** shows the host's name, the project and room names, and the play position; nothing else (tested).
- **`tailscale serve` is shared** with the phone link (port 8443): turning the phone link off (Settings > Advanced) doesn't stop guest
  links working if serve is already up.
- **Actions from guests are wrapped by the server** (and an early-closing object refused); Lua still re-checks everything, but a future
  module that trusts `a.gid` from a host page should remember host pages can send it too (they're trusted, they act as this computer).
