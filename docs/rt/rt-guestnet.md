# Guest links for people not on Tailscale: design (rt-guestnet, 2026-11-27)

James's findings, 2026-11-27, "Additions": "Guest links for people not on Tailscale." This is a design only: nothing is built, nothing on
a network or a real computer was touched. The decisions at the end are James's.

## 1. What a guest can do today, and exactly where Tailscale comes in

**Today (rt-browserjoin, `lib/guestweb.lua`, `lib/webui/guest.js`, `extension/webui.cpp`):** the owner or an admin makes a guest link on
Home > Browser guests. The guest opens it in a browser, picks their interface and channels, hears the host's session mix live (REAPER's
output plus every bandmate live audio carries), is heard live (mixed into what the host hears and into the host's Talk, so the bandmates
hear them too), records lossless takes that land on "<name> (guest)" in time, runs a loopback test, and leaves. Up to 4 guests, who hear
each other. No REAPER, no install.

**Every part of it goes over one HTTPS origin, and that origin is tailnet-only.** There is no separate signalling server and no WebRTC:

| Part | What it is today | Where it needs Tailscale |
|---|---|---|
| The page | `GET /guest.html`, `guest.js`, `guest.css`, `guestworklet.js`, `style.css`, `phonefile.js` from the extension's web UI server (`webui_guest_path`, webui.cpp:200) | The link is `https://<MagicDNS name>:8443/guest.html?g=<code>` (`guestweb.link`, `guestweb.PORT = 8443`): `tailscale serve` proxying to `127.0.0.1:47281` (`phonerec.serve_args`). Serve answers only devices on the tailnet. |
| "Signalling" (state, words, actions) | The guest's own event stream `GET /api/guest/events` (SSE, only topic `guest-<gid>`), `POST /api/guest/action` (wrapped by the server as `{topic:"guestweb",gid,a}`) | Same origin, same tailnet-only serve. |
| Media | One WebSocket per guest, `GET /api/guest/live` (`guest_live`, webui.cpp:895): down `[SG1\0][u32 rate][f64 link clock][16-bit stereo]`, up 16-bit mono, no codec: ~1.5 Mbit/s down, ~0.77 Mbit/s up at 48 kHz. Takes go up as `POST /api/guest/upload` (up to 160 MB, `MAX_UPLOAD`) | Same origin. TCP through serve. |
| The token | A single-use 96-bit code (`band.secret(24)`), good for 30 min (`CODE_LIFE`), swapped on first `GET /guest.html?g=` for an HttpOnly `ss_guest` cookie (`webui_guest_auth`), session 4 h (`SESSION`) | Nothing Tailscale-specific: the code and cookie would work on any origin. `guestweb.make` does refuse when Tailscale has no MagicDNS name for the computer. |

So nothing has to change in what the guest does: only **how a browser off the tailnet reaches that one origin**. rt-sonox already said
this ("a browser can't speak the sealed SSN1 UDP links, so it needs a WebSocket/HTTPS endpoint reachable from the internet").

**Pieces already built that this reuses:**
- **Public listening** (rt-audience, `extension/audience.cpp`, `lib/audience.lua`): a listener of its own on `127.0.0.1:47320` that knows
  only an allow-list (`audience_route`), behind `tailscale funnel --bg --yes --https=10000 http://127.0.0.1:47320`, an owner-only switch
  with a confirmed warning, off after 6 h, rate limits per way in (20 req/s, burst 200; 20 wrong codes a minute locks it for 60 s), public
  links refused on the tailnet port and tailnet links refused on the public port. Off by default; it needs Funnel allowed in the tailnet
  policy (backlog section 4 decision 1, still open).
- **Opus**: the extension already links libopus and encodes it for listeners (audience.cpp); `listen.js` already decodes with WebCodecs
  `AudioDecoder`. The guest frame header left room for a codec byte (rt-browserjoin).
- **The hub's TURN** (rt-nat3, `extension/nat.cpp`, `StudioSync_NatIce`, `webcall.ice`): libjuice's STUN/TURN on UDP 47298-47314 with
  studio-key passwords, already handed to video-call pages. Reachable from outside only with a router port forward, which StudioSync never
  makes.

**Two hard facts from Tailscale's Funnel docs (tailscale.com/kb/1223/funnel) that shape the design:**
- Funnel listens only on **443, 8443 or 10000**, and **a port can't be Serve and Funnel at once**. On JAMES-MAIN 8443 is the phone link's
  serve (tailnet-only, it must stay so: it fronts the whole web UI behind the token) and 443 is the AI hub's (phonerec.lua's comment). So
  the only free public port is **10000, which public listening already uses**. Guests must share that listener with listening links.
- Funnel traffic goes through Tailscale's Funnel relay servers as a TCP proxy; TLS ends on the host (the relays don't decrypt). It is
  "subject to non-configurable bandwidth limits", with no figures published.

## 2. The options

The guest must only click a link. The host is the server in every option (the guest hears the host's REAPER), so "host off" means no
session in all of them; what differs is what the guest sees then.

| | A. Funnel, everything over the existing WebSocket | B. Funnel page + WebRTC media (direct/STUN) | C. B + a TURN relay (coturn on a VPS, or hosted TURN) | D. Cloudflare Tunnel | E. A tiny relay on a free tier / VPS | F. Router port forward + DNS + certificate |
|---|---|---|---|---|---|---|
| **James, once** | Allow Funnel for the host computers in the tailnet policy (`nodeAttrs` "funnel"); HTTPS certs (already on for the phone link). The same step public listening needs. | As A | As A, plus a VPS (create, harden, patch coturn) or a Cloudflare account + API token for TURN credentials | Cloudflare account + a domain on Cloudflare (~$10/yr), `cloudflared` installed and logged in on each host. Quick Tunnels (no account) don't support SSE, which the guest page uses, and change name each run | Create a VPS or free-tier account, deploy and maintain the relay, a domain or its subdomain | A router change (UDP/TCP forward), dynamic DNS, a certificate; fails behind CGNAT |
| **Guest** | Click | Click | Click | Click | Click | Click |
| **Reliability across NATs** | Excellent: plain outbound HTTPS from the guest; the host's side is Tailscale's own path. Port 10000 can be blocked on strict corporate/hotel Wi-Fi | Media fails for ~10-20% of pairs (symmetric NAT/CGNAT, UDP-blocked networks) | Excellent (TURN over TCP/TLS 443 gets through almost anything) | Excellent (443) | Excellent (443) | Poor: CGNAT, ISP blocks, hairpin |
| **Live-audio latency** | One TCP trip via a Funnel relay (an extra hop, unmeasured) + the page's ~80 ms buffer; a lost packet stalls briefly. Fine for talking, cueing, playing along; takes are placed in time regardless | Best: UDP, direct, Opus FEC/PLC | Direct when possible, relay hop otherwise | Like A via Cloudflare's edge (often closer PoPs) | Like A plus the VPS hop | Direct TCP |
| **Cost** | Free (Funnel is in Tailscale's free plan) | Free | coturn: a $4-6/month VPS; Cloudflare TURN: $0.05/GB after a 1,000 GB/month allowance shared with its SFU (developers.cloudflare.com/realtime/pricing). A guest on Opus is ~45 MB/h each way | Free tunnel, domain ~$10/yr | $0-6/month | Free |
| **Privacy / security** | TLS ends on the host; Tailscale sees only encrypted bytes and the machine name (public in DNS and certificate logs while on, as already accepted for listening). A public port on the host, behind an allow-list | Media DTLS-SRTP end to end; needs a WebRTC stack inside the extension (libdatachannel brings usrsctp, libsrtp and a TLS library: big new dependencies) | As B; TURN sees only encrypted media; a VPS is one more internet machine to keep patched | **Cloudflare terminates TLS and sees the plaintext audio and pages**; their terms on streaming media apply | You own it; terminate TLS there (sees plaintext) or pass TLS through by SNI (more work) | Exposes the home IP and a port permanently |
| **What runs where** | Host: extension's public listener + tailscaled's Funnel. Nothing else | Host + browsers | Host + browsers + VPS/Cloudflare | Host: `cloudflared`; Cloudflare edge | Host + relay | Host + router |
| **Host computer off** | Guest sees Tailscale's error page (502) or nothing | Same | Same | Cloudflare's error page | The relay can show "the host is offline" | Connection refused |
| **New code** | Small (section 3) | Large (WebRTC in the extension, or a host browser page in the middle, rejected in rt-browserjoin) | B + credentials | Small, plus driving `cloudflared` | Medium: a relay service + a host-to-relay link | Small, but StudioSync never changes routers |

**Others considered:** inviting the guest onto the tailnet (Tailscale's share / guest key, `services.tailscale_guest_key`) is not "click
a link" (they install Tailscale); it stays the path for REAPER guests (rt-sonox). WebTransport/HTTP3 datagrams would give UDP to a
browser without WebRTC, but Funnel is TCP-only. Tailscale's own Funnel TCP forwarder doesn't help a browser.

## 3. Recommendation

**Option A: public guest links over the public port public listening already has (Funnel on 10000), with Opus on that socket.** It is
the only option that is click-a-link for the guest, free, keeps TLS on the host, needs no new machine or dependency, and costs James one
policy change he has to decide on anyway for public listening. TCP latency is acceptable for what browser guests are for (rt-browserjoin:
"good for talking, cueing and playing along"; takes are placed by the link clock, not by live latency). If real-network measurements show
the Funnel hop is too slow or rate-limited, C (hosted TURN + WebRTC) is the next step, and only then.

**Plan B if Funnel is refused or blocked for a guest:** Cloudflare Tunnel (D) with a named tunnel, as a host setting. Not built unless
needed: it means an account, a domain, `cloudflared`, and Cloudflare seeing the audio.

### Shape of the change (all additive; the tailnet path stays exactly as it is)
- **One public listener, two allow-lists.** audience.cpp's `pub_client` hands requests whose path is in `webui_guest_path` to a new hook
  in webui.cpp, `webui_public_guest(sock, req, rest_of_buffer)` (a function pointer, null unless webui.cpp is linked, the pattern of
  `webui_listen_http` in reverse). Everything else on the public port stays `audience_http`. The public guest handler:
  - opens only guests marked **public** (a new `StudioSync_WebUIGuestPublic(gid, on)`; `StudioSync_WebUIGuest`'s signature unchanged);
    tailnet guests' codes and cookies are refused there, as tailnet listening links are;
  - **never** calls `webui_auth`: the studio token and `ss_webui` cookie are neither needed nor accepted; no path to `/api/state`,
    `/api/events`, `/api/action`, `/api/upload`, `/api/file`, `/api/mix`, pages or topics;
  - shares the public way's rate buckets and wrong-code lock (`g_bk[1]`, `g_bad[1]`), and caps long-lived connections at 2 per guest (the
    event stream and the socket hold a request thread each; `PUB_WORKERS` is 64);
  - sets the cookie `Secure` as well as HttpOnly and SameSite.
- **Redeem on Join, not on open (public links).** Chat apps fetch links from the internet to build previews; on a public link that fetch
  would use up the code. `GET /guest.html?g=` on the public port only shows the page; the guest's existing **Join with this interface**
  press POSTs the code and gets the cookie. No extra click.
- **The switch.** A public guest link needs the public port on. Proposed: the owner's existing public switch becomes "Public links
  (listening and guests)", one warning, the same 6 h limit and off-everything; making a public guest link while it's off asks the owner
  to turn it on with the warning (decision 2). Turning it off ends public guests at once (kicked, sockets closed) and revokes public
  listening links, as today.
- **Opus on the public guest socket.** The extension encodes the guest's down mix with its libopus (one encoder per live guest, 20 ms,
  ~96-128 kbit/s stereo) and decodes their up stream; the page uses WebCodecs `AudioEncoder`/`AudioDecoder`, the codec byte in the frame
  header says which; PCM stays the fallback for browsers without WebCodecs Opus and stays the tailnet default. ~2.3 Mbit/s becomes ~0.2,
  so Funnel's unpublished limits and mobile data stop mattering. Takes stay lossless (they go up as files after the take).

### Phased build plan

**Phase 0, James once (approvals needed; no agent does these):**
1. Decide public links at all (backlog 4, decision 1 is the same question).
2. Allow Funnel for JAMES-MAIN (and the laptop if it will host) in the tailnet policy: `nodeAttrs` `funnel`. HTTPS certificates are on
   already for the phone link. **Network/Tailscale change: James's OK, done by James.**
3. Run rt-audience's REAPER check 8 (public listening from a phone on mobile data). It proves Funnel, the WebSocket and the public
   listener on his real network before any guest code is written.

**Phase 1, public guest links (1-2 agent rounds, Opus high):**
- `extension/webui.cpp`, `webui.h`: `webui_public_guest`, the `public` flag per guest, `StudioSync_WebUIGuestPublic`, POST redeem, Secure
  cookie, per-guest connection cap. `extension/audience.cpp`: the hand-off in `pub_client` (passing the body bytes already read, for
  uploads) and the shared buckets.
- `lib/guestweb.lua`: `make` takes `public`; the link on `audience.FUNNEL_PORT`; refuses while the switch is off (or asks, decision 2);
  public guests ended when the switch goes off; host topic gains `pub`. `lib/audience.lua`: the switch's words and its "off" ending public
  guests. `lib/webui/guesthost.js`: "Public link (works without Tailscale)" for whoever decision 3 allows, with the warning shown as
  text. `lib/webui/guest.js`: redeem on Join when the page has a code and no cookie.
- Tests: `tests/webui_test.cpp` / `tests/audience_test.cpp` live tests: a public guest's page, events, socket, action and upload work on
  the public port; a tailnet guest's code and cookie refused there; a public guest's code refused on the tailnet port; the studio token and
  `ss_webui` cookie open nothing on the public port; every studio path 404/403 even with a valid guest cookie; GET never redeems, POST
  does once; `Secure` set; the switch off closes their socket and stream within 0.25 s; buckets and the wrong-code lock; the third
  long-lived connection refused. `tests/test_0_60_rt_guestnet.lua`: the link, the switch rules, who may make public links, ending.
  Headless Chromium with fake devices against the stand-in public listener (the rt-browserjoin pattern): Join redeems, audio flows,
  a preview-style GET leaves the code usable.

**Phase 2, Opus on the public socket (1 round, Opus high):** `extension/webui.cpp` (encode/decode per slot, outside the audio thread, as
audience.cpp does), `lib/webui/guest.js`/`guestworklet.js` (WebCodecs, fallback), tests: a 440/660 Hz stand-in round trip through Opus
both ways within the existing tolerances; the fallback path; CPU per guest.

**Phase 3, only if measured need:** after a real guest session over Funnel, look at the socket's ping/pong round trip, `under`/`drops` on
the host row, and Funnel throttling. If it's not good enough: C with Cloudflare's hosted TURN (no VPS) and a WebRTC media path. That is a
new-dependency decision (libdatachannel, MPL-2.0, plus libsrtp/usrsctp and a TLS library) and several rounds; not proposed now.

**REAPER checks once built (James):** make a public guest link on the desktop; open it on a phone with Tailscale off on mobile data, and on
a laptop off the tailnet; paste the link into a chat app first and check the guest can still join; hear and be heard; record a take;
End; turn the switch off mid-session and see the guest page end; try the same code on `:8443` off the tailnet (nothing).

## 4. Security

- **Link lifetime:** the code works once, within 30 minutes (unchanged); a public session lasts at most until the public switch goes off
  (6 h) and at most the session length (4 h default; decision 4 proposes 2 h for public links). The code is never saved (unchanged).
- **Revocation:** End (kicks within 0.1 s, unchanged); the switch off ends every public guest and listening link; REAPER closing ends
  guests (the extension forgets them). Funnel staying configured after a crash points at a closed port (already listed by rt-audience).
- **What a public guest reaches:** only the guest page's six files, their own event stream (topic `guest-<gid>`), their socket, their
  wrapped action and their upload (onto their own track, under the host user's room rules, one take every 3 s). Never the web UI, its API,
  topics, chat, files, the studio token, other guests' topics, other songs or other tailnet machines (Funnel forwards to one loopback port).
  This is a separate code path from the tailnet server's token check, tested with a valid guest cookie and the studio token both given.
- **Rate limits:** the public way's existing 20 req/s (burst 200) and wrong-code lock; one link every 5 s, 12 an hour, 4 guests (unchanged);
  2 long-lived connections per guest; the socket's existing flood close (past ~3x real time).
- **Safe by default without new friction:** public links are off until the owner turns the switch on once per session; the guest's flow is
  unchanged (one Join press, which now also redeems).

### Review later (security review is held until James says)
- Codes from `band.secret` (REAPER GUIDs) and `std::random_device`, not a documented CSPRNG (as rt-browserjoin/rt-audience); nat.cpp
  already has `nat_random` (BCryptGenRandom), which could make them.
- Cookies aren't port-isolated: `ss_webui` from `:8443` is sent to `:10000` and `ss_guest` from `:10000` to `:8443`. Neither port honours
  the other's (by design above), but a test should keep it that way.
- The public rate limits are per way in, not per client: one abuser can lock real guests out for a minute. Funnel's forwarded headers
  could key a per-client limit (check what tailscaled actually sets on Funnel requests first).
- The session mix goes to a public guest whole, talkback included; the band sees the guest on Who's here but isn't otherwise warned.
- Uploads: a public guest can push up to 160 MB per take through the public port; consider a lower public cap.
- The guest's up audio isn't authenticated per frame beyond the cookie on the socket (unchanged).
- The machine's ts.net name is public while Funnel is on (DNS, certificate logs), as already accepted for public listening.
- One public port serves two features: any future path under the guest or listening allow-lists is public by construction.

## Decisions for James
1. **Public guest links at all?** Proposed: yes, through Tailscale Funnel on the existing public port (option A). This needs Funnel allowed
   for JAMES-MAIN (and the laptop, if it hosts) in the tailnet policy, a change you make yourself.
2. **One switch for public listening and public guests?** Proposed: yes, "Public links", one warning, off after 6 h; making a public
   guest link while it's off asks the owner to turn it on.
3. **Who may make a public guest link?** Proposed: the owner only (as the public listening switch); admins keep tailnet guest links.
4. **Public guest session length?** Proposed: 2 h by default, up to the switch's 6 h; tailnet guests keep 4 h.
5. **Opus on public guest sockets?** Proposed: yes (phase 2), PCM kept as the fallback and the tailnet default.
6. **WebRTC/TURN later?** Proposed: only if a real Funnel session measures badly; then Cloudflare's hosted TURN rather than a VPS you
   maintain.
7. **Plan B if Funnel is refused?** Proposed: none built now; Cloudflare Tunnel (account + domain, Cloudflare sees the audio) only if
   Funnel doesn't work for you.

## James's decisions (2026-11-27)
All seven accepted as proposed: public guest links through Tailscale Funnel on the existing public port; one "Public links" switch (one warning, off after 6 h); owner only; public sessions 2 h (tailnet guests 4 h); Opus on public guest sockets with PCM as fallback; WebRTC/TURN only if a real Funnel session measures badly (then Cloudflare hosted TURN); no plan B built now.
Build order: Phase 1 starts once rt-share has landed (both touch `extension/webui.cpp`). Phase 0 steps 2 and 3 are James's.

## Phase 0 result (2026-11-27, orchestrator, James OK'd testing on the S23)
- Funnel was already allowed: the tailnet policy has `nodeAttrs` funnel for autogroup:member; JAMES-MAIN carries the funnel cap for ports 443, 8443, 10000.
- Public listening on (owner switch), a public link made. From the desktop through Funnel's public address (public DNS, `--resolve`): the page 200 in ~0.4 s (TLS ~0.28 s, first byte +0.1 s); `:8443` unreachable from the public address; `/api/state` on the public port 404.
- S23 (no SIM, so Wi-Fi on its own ISP, a different internet connection from the desktop): Listen pressed on the tailnet, then the phone's Tailscale turned off for 75 s (IPNReceiver DISCONNECT/CONNECT broadcasts). The page reconnected about 4 s after Tailscale went off (one underrun, 2 gaps for the switch), so through Funnel. The ears pattern fired during the off period came through clean: corr_windows 0.99, level 0 dB, no gaps, speed 0.9996, steady (0.4 ms jump). After Tailscale came back the Funnel socket carried on: 49 s more, no new underruns or gaps. The page settled at a 0.3 s lead.
- Not measured: the pure Funnel hop latency (the page does not report round trip); scrcpy's capture of the phone came back silent (the in-page tap is the measure).
- Cleaned up: link revoked, public listening off (Funnel 10000 gone), test track removed, phone back as it was.
Verdict: Funnel carries the page, the event stream and the live WebSocket from off the tailnet; Phase 1 goes ahead.

## Phase 1 (built, 2026-11-27, rt-guestnet1)
Public guest links, as designed above, PCM on the socket (Opus is Phase 2). Tested offline only: native tests, Lua tests, headless Chromium
against a stand-in. **Not run in REAPER, on a phone, or through Funnel yet; the extension's version was not raised** (it needs a new
extension build: `StudioSync_WebUIGuestPublic` is new, and without it the owner is told the extension is older).

### What changed
- **One switch, "Public links"** (`lib/audience.lua`, `lib/webui/audiencehost.js`): the owner's public listening switch now covers public
  guest links too. One warning (it now says a public guest link lets someone join, be heard and record onto their own track, and that
  turning it off ends every public link and guest), the same 6 hours, the same `public = { on, sure }` action. Turning it off (the owner, or
  its hours running out) ends every public guest first (so a live page is told "ended" before Funnel goes), then closes Funnel, revokes
  public listening links and shuts the port.
- **Making one** (`lib/guestweb.lua`, `lib/webui/guesthost.js`): the owner (only; admins keep tailnet guest links) types a name and presses
  **Public link (works without Tailscale)**. While Public links are off it asks with the switch's warning (a plain confirm, text only), turns
  them on, then makes the link. The link is `https://<name>.ts.net:10000/guest.html?g=<code>`; the session is 2 h at most (`PUBLIC_SESSION`)
  and never past the switch's end (under a minute left: refused). The host's topic gains `pub` per guest, and `owner`, `public_on`,
  `warning`; the guest list shows "public".
- **The extension** (`extension/webui.cpp`, `webui.h`): `WebGuest.pub`; `StudioSync_WebUIGuestPublic(gid, on)` (registered with the other
  `StudioSync_WebUI*` functions in `webui_register`, so `reaper_menu.cpp` needed nothing); `webui_guest_auth(..., pub)` and
  `webui_guest_path(..., pub)` take which port asks: a guest opens only on its own kind of port, codes and cookies alike. Public guests'
  cookie is `ss_pguest` (`Secure; HttpOnly; SameSite=Lax`), so it never clobbers or stands in for a tailnet `ss_guest`. On the public port
  `GET /guest.html?g=` only shows the page (a link preview uses nothing up); **`POST /api/guest/redeem?g=`** (the page's Join) redeems and
  answers with the guest's own topic; the page's script and style need no code (like `/listen/listen.js`). `webui_public_guest(sock, req,
  rest)` serves it all, never calls `webui_auth`, and caps each guest at 2 long-lived connections (stream + socket; a third: 429).
  `webui_public_guests_end()`: every public guest ended when the public port closes. The action-queue code moved out of `handle()` into
  `post_body()` unchanged so both ports use it. `StudioSync_WebUIStatus`'s guests carry `pub`.
- **The public port** (`extension/audience.cpp`): `pub_client` hands `webui_guest_path(.., true)`'s paths to `webui_public_guest` after the
  public way's own bucket and wrong-code lock (`g_bk[1]`, `g_bad[1]`; a 403 there counts toward the lock), passing the body bytes already
  read; everything else stays `audience_http`. A direct call, not the function pointer the design sketched: `audience.cpp` is always linked
  with `webui.cpp`. `pub_close` now ends public guests first (and waits 150 ms when one was live, for its 1008), then **shuts down** the
  active request sockets instead of closing them, so each request thread closes its own and no handle is closed twice.
- **The guest page** (`lib/webui/guest.js`): a page opened with `?g=` keeps the code in memory (dropped from the address as before), opens
  no stream, says "press Join to start"; Join POSTs the redeem first, then starts from its answer and opens the stream. Ended (the socket's
  1008, or the stream refused) says "Your session has ended (the host ended it, or turned public links off)" and stops reconnecting.

### Tests (all pass here)
- `tests/webui_test.cpp` (all ok): redeem only on the public port and only by POST; a public guest's code refused on the tailnet port and not
  used up; on the public port GET shows the page twice and uses nothing; the script without a code, page and API not; a tailnet guest's
  code refused there; redeem without X-StudioSync or from another site refused; POST redeems once, then neither redeem nor the page again;
  `ss_pguest` opens the API, the tailnet's cookie name doesn't; each kind's session refused on the other port.
- `tests/audience_test.cpp` (all ok; the existing checks adjusted: the guest page's paths are no longer 404 on the public port, and the
  wrong-code lock check allows for the guest section's few earlier wrong codes): live through the public port as Funnel delivers it: the
  preview GET (page, no cookie), again, the script; no session, no stream; redeem without X-StudioSync refused; the public code on the tailnet
  port refused (GET and POST) and still good after; Join's POST: `Secure; HttpOnly; SameSite=Lax` cookie and only the guest's own topic; a
  second Join refused; the guest's own Join again: no new cookie; a tailnet guest's cookie (by either name), the studio token and `ss_webui`
  open no guest API on the public port; a public cookie opens nothing on the tailnet port; nine studio paths 404 with a valid guest cookie,
  the token and `ss_webui` all given, `/api/action` and `/api/upload` too; the action wrapped as theirs; a 100 KB upload saved byte for byte
  (the bytes read with the head included); stream and socket open, the stream carries their topic only; the third long-lived connection 429;
  the public port off: stream and socket closed in 0.155 s (the 150 ms wait for the 1008 included), the socket's close is 1008, the public
  guest gone and the tailnet guest kept; on again: the old cookie 403; and while the wrong-code lock is on, a right guest code waits too.
- `tests/test_0_60_rt_guestnet.lua`: `public` only when `true`; a member and an admin can't make one, the owner can't while Public links are
  off, a public link never turns them on by itself; an older extension refused; made: 2 h session, the extension told it's public, kept as
  public without the code, on port 10000, the host's topic (owner, public_on, the warning covering guests); a tailnet guest alongside
  (4 h, never public, :8443); 30 minutes asked: 30; Public links ending in 10 minutes: 10; under a minute: refused; the owner turns them
  off: the public guest ended (extension told), the tailnet guest kept, "1 public guest ended", Funnel closed; the hours run out: ended too,
  logged; off again: refused. The pages: the owner's button, the warning as text before turning on, redeem by POST, no stream before it.
  `tests/test_0_60_rt_audience.lua` follows the switch's new words; `tests/test_0_60_rt_browserjoin.lua`'s groups stand-in gained `role`.
- **Headless Chromium, fake devices only** (scratch, not committed, the rt-browserjoin pattern: a stand-in exe from the real `webui.cpp` and
  `audience.cpp` serving the real `lib/webui` on its public port, a fake audio thread with a 440 Hz "REAPER output", a fake Lua publishing the
  guest topic; a 1 kHz WAV as the fake mic; Node over CDP): a link-preview-style GET first (the page, no cookie, the code still unused); the
  page opened: code gone from the address, no cookie, "press Join to start", nothing used up; Join: redeemed, the socket open, the cookie
  unreadable by script, the name from the redeem's answer; the AudioContext running at 48 kHz with the mix's map points arriving; **the fake
  mic heard at the stand-in host at 0.50 peak, 0 underruns, 0 drops**; the same link from another browser refused (page and Join), the
  guest's own other tab still theirs; the public port off: the page says ended, why, and stops reconnecting; no script errors.

### REAPER and phone checks for James
1. Desktop, extension with this build, Live sync on: Studio/Session > Browser guests, type a name, **Public link (works without Tailscale)**.
   With Public links off it shows the warning; OK turns them on (Funnel 10000) and the link appears with Copy (`:10000`).
2. **Paste the link into a chat app first** (WhatsApp/Messages/Discord: let it build its preview), then open it on a phone **with Tailscale
   off, on mobile data**. The page says "press Join to start".
3. Pick the interface, **Join**: headphones on, hear the session; the band hears the phone (the host row shows it live with a level).
4. **Record a take** while REAPER plays; stop; it lands on "<name> (guest)" in time and the page says where.
5. The host's list shows the guest as "public". Try the same link in another browser: "used already".
6. **Turn Public links off** (Listening links box) mid-session: the phone's page says "Your session has ended ..." and stops; the guest is
   gone from the list; a tailnet guest, if any, stays.
7. Optional: the same code on `:8443` from off the tailnet (nothing), and a tailnet guest link (`:8443`) still works as before.

### Review later (security review held)
- Codes still from `band.secret` (REAPER GUIDs) and sessions from `std::random_device` (as before); `nat_random` could make them.
- The public port's rate limit and wrong-code lock are per way in, shared by listeners and guests: one abuser locks real guests out for a
  minute (DoS, not exposure). A per-client key from Funnel's forwarded headers would fix it.
- A public guest's upload cap is still the tailnet's 160 MB; a lower public cap may be wise.
- The page's static files (guest.js, guest.css, guestworklet.js, style.css, phonefile.js) open on the public port without a code (they carry
  nothing of the studio's, as listen.js). Any future file added to `webui_guest_path` becomes public by construction.
- `Secure` on the cookie is honoured by Chrome over `http://127.0.0.1` too (the tests rely on that); real use is https through Funnel.
- Public links off: guests are ended before Funnel is closed; the "ended" the page shows relies on the 1008 reaching it before Funnel cuts
  the connection (`tailscale funnel off` takes longer than the 0.1 s the socket needs, but that's not guaranteed).
- iOS Safari: Join now awaits the redeem POST (~0.3 s through Funnel) before it opens the AudioContext and the microphone; the existing join
  already awaits several steps before `resume()`, but Safari's user-gesture rules weren't tested here.
- The session mix (talkback included) goes whole to a public guest, as to a tailnet one; the band sees them on Who's here only.
