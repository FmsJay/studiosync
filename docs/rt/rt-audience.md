# Live to an audience: listening links (rt-audience, 2026-11-20)

Roadmap: "Live to an audience: stream the band's live mix to listeners on a web page" and "Listen from anywhere. A link from the studio to
a browser page (phone, client, a bandmate away from REAPER) that plays the live session or the latest mix." **Tested offline only** (native
test, Lua test, headless Chrome against a stand-in built from the real server); **not run in REAPER, on a phone or between computers yet.
The extension's version was not raised. Public listening was never turned on anywhere.**

## What already existed (and what each covers)
- **The listening page** (`lib/listen.lua`, Settings' "Share the listening page"): every song's bounced mixes in a browser, over
  `tailscale serve` (tailnet only), with comments through phone alerts. **Covers "the latest mix" on the tailnet**, not live.
- **The phone app's mix** (`lib/phonerec.lua`, `StudioSync_WebUIOffer`, `GET /api/file`): each song's newest mix for the Record page to play
  along to. Needs the studio's token: for bandmates' phones, not for listeners.
- **rt-share's `/api/mix`** (`docs/rt/rt-share.md`): REAPER's raw output as 16-bit PCM, **loopback only**, at most 4 streams, before live
  audio adds bandmates. For a screen share on this computer; never reaches the tailnet.
- **Browser guests** (`docs/rt/rt-browserjoin.md`): a single-use link, 16-bit PCM of the session mix over a WebSocket, **2 live at once**,
  and they're heard and record takes. Live listening for a couple of trusted people, not an audience.

Missing, now built: a listen-only page anyone with a link can open, live (low latency) or the latest mix, for many listeners from one encode,
on the tailnet or (off by default) the public internet.

## What it does
1. **The host makes a link.** Web UI, Home, under Who's here: **Listening links** (owner and admins). Pick how long (1 h to 7 days, 4 h by
   default), **Make a listening link**. The link is `https://<this computer's MagicDNS name>:8443/listen/?l=<32 hex>`: the studio's secure
   phone link (`tailscale serve`, set up by itself as for guest links), so **only the studio's tailnet** reaches it. It's shown with **Copy**
   for as long as it works (it's meant to be passed around), with how many listen on it, and **Revoke** (its listeners are cut off within
   0.25 s). 4 links at a time; one every 5 s, 12 an hour.
2. **A listener opens it** (any recent Chrome, Edge, Firefox or Safari; phones too). The page shows the **song**, a **live indicator** ("Live
   now" with a red dot while sound is coming and the band is playing), **who's playing** (tailnet links only), **Listen live** and a
   **volume**. Playback is about a quarter to half a second behind (the jitter buffer grows by 50 ms per underrun, up to 0.8 s).
3. **Nobody playing:** "Nobody's playing right now" and the song's **latest mix** (`<Song>/mixes`, the newest file) in a player, served with
   byte ranges so phones seek. Playing the mix stops live listening; when the band starts again the page says so.
4. **The host sees the cost:** listeners (and how many public), the encoder's share of a core and the kbit/s going out. **At most** N
   listeners (20 by default, 1-100) at 64/96/128/160 kbit/s (96 by default).
5. **Public listening (owner only, off by default).** Below the links, the owner sees **Turn on public listening…**; it shows the warning
   below and only a confirmed OK turns it on. Then **Make a PUBLIC link** appears: `https://<name>.ts.net:10000/listen/?l=<code>` through
   **Tailscale Funnel**. It turns itself **off after 6 hours**; **Turn public listening off** (owner) ends it at once. Off (either way)
   closes Funnel, shuts the public port and **revokes every public link**, so turning it on again later never brings old links back.

## How the audio goes
- **Source:** the session mix, the ring browser guests already get (`webui_guest_audio`: this computer's REAPER output after live audio
  added every bandmate it hears, so the hub's mix when this computer hears through a hub; before any browser guest is added). Whoever makes
  the link is the computer listeners hear: the host with the full mix (or the hub) is the one to make it.
- **One encode:** the audio thread only copies into a 1.4 s float ring (`audience_feed`), and only while someone listens. One fan-out thread
  resamples to 48 kHz (Catmull-Rom, measured within 0.2% on a 1 kHz tone from 44.1 kHz), encodes **Opus once** (20 ms frames, complexity 5,
  the chosen kbit/s) and appends the same WebSocket frame to every listener. Sockets are non-blocking and polled: no thread per listener.
- **Frames:** binary `[u32 sequence][Opus packet]`; text frames are the info JSON (on joining, on a change, and every 10 s to keep proxies'
  idle timers off). The page decodes with **WebCodecs `AudioDecoder`** and schedules AudioBuffers on its own clock.
- **Slow listeners:** each socket gets a 32 KB send buffer (Linux's would otherwise grow to megabytes and hide a stalled listener for
  minutes: CI found it); past 32 KB more waiting here (~2.7 s at 96 kbit/s) their packets are skipped; still past it after 10 s, they're closed. A
  listener sending more than 16 KB in 10 s is closed (a page sends nothing).
- **Measured (tests/audience_test.cpp, this desktop):** 100 listeners at 96 kbit/s: the encoder **0.7% of one core**, ~99 kbit/s out per
  listener (**~10 Mbit/s up for 100**). The CPU is nothing; **this computer's upload is the limit**: 20 listeners ≈ 2 Mbit/s, the default.
  The page itself is 3 small files. A cloud relay (not built) is what would take the upload off the band's computer.

## Two ways in, one allow-list
`extension/audience.cpp`, `audience_route`: **GET** `/listen/` (the page), `/listen/listen.js`, `/listen/listen.css`, `/listen/live`
(the socket), `/listen/mix` (the latest mix). Nothing else, no other method. The page, socket and mix need `?l=<code>` of a live link; the
script and style don't (they carry nothing).
- **Tailnet:** the web UI server hands any `/listen/` request to audience.cpp **before** its token check (webui.cpp, one line in `handle`);
  the studio's token is neither needed nor accepted there, and a listening code opens nothing of the web UI's (tested).
- **Public:** a listener of its own on `127.0.0.1:47320` that knows only `audience_http`: there is no code path from it to topics,
  actions, uploads, files, guests or pages of the web UI. Only links made public open on it. `tailscale funnel --bg --yes --https=10000
  http://127.0.0.1:47320` (Funnel takes 443, 8443 or 10000; 8443 is the phone link's). Public listeners are told only
  `{song, live, mix: true/false}`: no names, no mix file name.

### Exactly what public listening exposes
- **To anyone on the internet:** that `<this computer>.ts.net` exists and answers on port 10000 with Tailscale's certificate (the name
  appears in Certificate Transparency logs once certs are on, and Funnel's DNS is public). Without a valid public code every path is 403 or
  404; past 20 wrong codes a minute, everything there answers 429 for a minute; past 20 requests a second (burst 200), 429.
- **To anyone with a public link:** the session mix live (everything this computer hears: REAPER's output and every bandmate live audio
  carries, in any room of the project in front), the song's name, whether it's live, the latest bounced mix of the song in front (its bytes,
  not its name), until the link runs out, is revoked, or public listening goes off.
- **Not exposed:** the web UI, its API, chat, files, the studio token, guests, other songs, the tailnet's other machines (Funnel forwards to
  this one port only), names of who's playing.
- **The warning the owner confirms:** "Public listening puts a port of this computer on the open internet through Tailscale Funnel: anyone
  with a public link hears the session live (everything this computer hears, bandmates included) and the song's latest mix, and sees the
  song's name. It serves nothing else (no files, chat, controls or studio pages), and only public links open it. This computer's address
  (<name>.ts.net) becomes public. It turns itself off after 6 hours."
- **Needs (James's call):** HTTPS certificates on for the tailnet, and Funnel allowed for this computer in the tailnet policy
  (`nodeAttrs` "funnel"). If Tailscale refuses, the page shows Tailscale's own words and it stays off.

## Files
- New: `extension/audience.cpp`, `extension/audience.h`, `lib/audience.lua`, `lib/webui/listen.html`, `listen.js`, `listen.css`,
  `audiencehost.js`, `tests/audience_test.cpp`, `tests/build_audience_test.cmd`, `tests/test_0_60_rt_audience.lua`, this doc.
- Shared files, small additive edits:
  - `extension/webui.cpp`: four hook pointers (`webui_listen_http/feed/count/stop`, null unless audience.cpp is linked, so
    `tests/webui_test.cpp` builds as before); in `handle`, `/listen/` handed over before the token check; `client` leaves a handed-over socket
    open (`t_kept`); `webui_mix_wanted` adds the listeners (the audio hook stays in); `webui_guest_audio` feeds listeners first;
    `webui_shutdown` stops it; `webui_register` calls `audience_register`. `extension/webui.h`: the pointers' declarations.
  - `extension/build_windows.cmd`: `audience.cpp` in SRC and the obj clean-up. `.github/workflows/extension.yml`: `audience.cpp` in the
    Mac and Linux builds, its test on both, the paths.
  - `lib/webui.lua`: `ACTIONS.audience`, its dispatch, `audience.tick` at the end of the tick. `lib/webui/index.html`: `audiencehost.js`
    after guesthost.js (it uses guest.css's box styles).
- ReaScript: `StudioSync_AudienceStart(folder, cap, kbps, public_port)`, `StudioSync_AudienceLink(id, code, seconds, public)`,
  `StudioSync_AudienceInfo(full_json, public_json, mix_path)`, `StudioSync_AudienceStatus()`.
- Topic `audience` (host pages): may, owner, song, live, who, mix, links [id, url, ends, pub, by, n], listeners, public_listeners, cap,
  kbps, enc_load, out_kbps, refused, limited, public {until, by, err}, warning, last. Actions on `audience` (owner/admins; the public switch
  owner only): `make = { hours, public }`, `revoke = id`, `cap`, `kbps`, `public = { on, sure }`.
- ExtState: `audience links` (id, code, ends, pub, by, made: kept so links survive a REAPER restart), `audience public` ({until, by} while
  on), `audience cap`, `audience kbps`.

## Tests
- `tests/audience_test.cpp` (built and run here, all ok; CI builds and runs it on macOS and Linux): the route list (nothing of the web UI's:
  `/`, `/api/*`, `/guest.html`, `/record.html`, traversal, POST/HEAD); links: tailnet-only refused on the public port, run out, wrong, short,
  long; the token bucket; the resampler (1:1 exact; 44.1→48 kHz within 0.2%); WebSocket frame lengths. Live: the public port serves the page
  with the safety headers, script, style and the mix (a byte range, 416 past the end, a non-audio "mix" refused), and **404 for twelve other
  paths even with a public code and the studio token both given**; POST and HEAD refused. The tailnet way in through the real web UI server
  (as `tailscale serve` hands it over): the page with the link, the studio token not standing in for a link, a link opening no web UI page.
  A stand-in "REAPER" (440 Hz left, 660 Hz right at 0.5, 44.1 kHz, 128-frame blocks through `webui_guest_audio`): 50 packets/s, no gaps,
  decoding back to 440.0 / 660.0 Hz at 0.52 peak; public listeners told no names, tailnet ones who's playing; the hook wanted while anyone
  listens; 30 listeners at a cap of 30, the 31st gets 503; every listener on one encoder's sequence; revoke closes that link's listeners
  (1008) and leaves the others; a 1 s link closes its listener on time; a listener that never reads is skipped then closed (13.5 s); the
  public port turned off closes its listeners and stops answering; 100 listeners: encoder 0.72% of a core, 99.4 kbit/s each; 20 wrong codes
  then a 60 s lock (the right code waits too; the tailnet way in unaffected); a flood past the burst gets 429s.
- `tests/test_0_60_rt_audience.lua`: the link; host actions checked (out-of-range hours/caps/rates dropped; `public` must be a boolean and
  `sure` literally true); what listeners are told (the public JSON has exactly song, live, mix-as-boolean; under 2 KB whatever the names);
  playing/who from the transport and live audio levels; a member can't make links, an admin can; the code is 128 bits; rate limits; a
  public link refused while public is off; the host topic; links given back after a REAPER restart with their remaining time; run out;
  revoke; cap and rate. The public switch: **never turned on by itself**, an admin can't turn it on or off, the owner without `sure` can't,
  Funnel refusing leaves it off with the port shut, on opens the port then Funnel, its 6 hours run out (Funnel off, public links revoked,
  tailnet links kept, logged), the owner turns it off (Funnel closed, public links revoked). Wiring in webui.lua; the pages (only their own
  files, no inline script/style, no innerHTML/eval/other addresses/`api/`, the page sends nothing on its socket).
- **Headless Chrome, no microphone or camera used** (scratch, not committed: a stand-in exe from the real webui.cpp/audience.cpp serving the
  real `lib/webui`, the 440/660 Hz fake output; Node over CDP; `AudioBuffer.copyToChannel` wrapped to capture what the page plays): the song
  shown as text (`Bee <b>Song</b>` not run as markup); nobody named on the public link; WebCodecs present; **Listen live: the AudioContext
  running, 380 packets in 6 s, no gaps, no underruns, played 0.43 s behind; what it schedules is 440.0 Hz left / 660.0 Hz right at 0.52**;
  the live indicator; the mix hidden while live; the volume a gain after decoding. The tailnet page names James and Chilio; a tailnet link on
  the public port refused. Not live: the page says so, the latest mix shows and plays (2 s WAV through `/listen/mix`), and playing it stops
  live listening. Revoked: both pages say the link ended. The host box on Home: both links with Copy (the public one on :10000), "3 of 20
  listening (1 public) · encoder 0.7% of a core"; Revoke and Make a PUBLIC link send their actions; Turn on asks with the warning (shown as
  text) and sends `sure: true`.

## Check in REAPER (real computers)
1. Desktop, Live sync on with a song that has a render in `<Song>/mixes`: web UI Home > Listening links > Make a listening link. The log says
   the secure link is set up (as for guest links; HTTPS certificates on).
2. On a phone on the tailnet (Safari and Chrome if you can), open the link: the song's name and "Nobody's playing right now" with the latest
   mix; play it and seek.
3. Press Play in REAPER: within a second "Live now" with the red dot; tap **Listen live**: you hear REAPER's output about half a second
   behind. With live audio on and Chilio playing: "Playing: James, Chilio" and you hear Chilio too (the hub's mix if the desktop hears
   through it).
4. Home shows the listener count and the encoder load; Health's audio callback time should not move (the hook copies a block per callback).
5. Revoke: the phone says the link has ended within a second. Make another with 1 h and leave it: it ends on time.
6. Open 3-4 listeners (phone, laptop browser tabs): all play; set the cap to 2: the third is told it's full.
7. Change REAPER's sample rate (44.1/48 kHz) while listening: the stream carries on (it resamples).
8. **Public listening: only if James decides.** It needs Funnel allowed for JAMES-MAIN in the tailnet policy. Turn on (read the warning),
   Make a PUBLIC link, open it on a phone **off the tailnet** (mobile data, Tailscale off): the song and live stream, no names. Try the
   same link with `:8443` (tailnet port) from off the tailnet: nothing. Turn off: the phone's page says the link ended; `tailscale funnel
   status` shows nothing on 10000.

## Untested / limits
- Nothing ran in REAPER or on a real phone; Safari's WebCodecs Opus (Safari 26+) and Firefox's (130+) weren't tried, only Chrome 157.
- The live indicator follows this computer's transport and live audio levels (and packets arriving); a bandmate playing while this
  computer's live audio is off doesn't count.
- Browser guests aren't in what listeners hear (both taps sit before guests are added).
- No drift correction on the page: it schedules on its own clock and grows the buffer on an underrun or drops a frame when far ahead (a
  small skip now and then on long listens).
- Listeners hear this computer only: the one that makes the link. Another bandmate's links serve from theirs.
- The panel (ImGui) has no listening-link UI; only the web UI's Home.
- "Who's playing" is this computer's user while it plays plus bandmates heard above a level; it doesn't know who in a hub's mix is silent.
- The legacy listening page (`lib/listen.lua`, all songs' mixes with comments) still exists beside this; the new page shows the song in
  front only.

## Review later (security)
- **Codes are bearer secrets in URLs** (shared on purpose, so chat previews, browser history and screenshots carry them). 128-bit, from
  `band.secret` (REAPER's GUIDs, not a documented CSPRNG: as guest codes). Revoke and expiry are the controls; consider shorter defaults.
- **Codes are kept in ExtState** (reaper-extstate.ini, readable by anyone with the user's files) so links survive a restart; guest codes
  never are. Consider keeping them in memory only, at the cost of links ending with REAPER.
- **The rate limits are per way in, not per listener:** one abuser can use up the public bucket (or trip the wrong-code lock) and keep
  real listeners out for a minute (denial of service, not exposure). Funnel's `X-Forwarded-For` could key a per-client limit.
- **Public listeners can't be told apart or kicked one by one**: only their link can be revoked.
- **The session mix goes out whole** (as to guests): talkback and anything a bandmate says over live audio is heard by listeners; a
  "listener mix" would need a REAPER-side send. The page doesn't warn the band that someone listens beyond the host's count.
- **Funnel publishes the machine's name** (DNS and certificate logs) for as long as it's on, and `tailscale funnel --bg` stays configured if
  REAPER closes or crashes (pointing at a closed port: Tailscale answers 502). REAPER back within the 6 hours: public listening resumes (the
  switch is kept); after them, the first Live sync tick turns Funnel off. Nothing turns it off while REAPER stays closed.
- **The latest mix on a public link** is the song-in-front's newest file in `<Song>/mixes`, whatever it is (an unreleased render too).
- **The page files are read from `lib/webui`** on every request (as the web UI's are); anyone who can write that folder can change what
  public listeners run (the same trust as the web UI itself).
- **`/listen/` bypasses the web UI's token by design**: any future file named under `/listen/` would need adding to the allow-list
  deliberately (it can't leak by accident: unknown paths are 404).
