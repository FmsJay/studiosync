# Connect without Tailscale, stage 2: the direct link over it (rt-nat2, 2026-11-20)

Stage 1 (extension 1.0.19, `extension/nat.cpp`) gave each bandmate the studio's tailnet doesn't reach a sealed UDP link and carried live
audio over it. Stage 2 carries everything else the direct link sends over the same link: event files (changes), messages (presence/status,
heartbeats, chat, claims, controller moves, cues, catch-up asks), the shared clock's pings, and (untested at scale) streamed takes. Native and
Lua tests only; not run in REAPER or between two real computers yet. The extension's version isn't raised.

## What it is
- **Still behind the same switch:** Settings > Studio > "Connect without Tailscale" (band.json `nat`, owner and admins, off by default). With
  it off nothing changes. Its text now says the direct link goes this way too.
- **Which peers:** the pairs stage 1 already picks (`nat.pair_needs`: both devices files carry a key and one of the two isn't on the studio's
  tailnet). For the direct link, such a bandmate is the peer `nat:<device id>` **only while their link is up** (`state` "up" in
  `StudioSync_NatStatus`). While it's connecting, down or retrying, their Tailscale entry stays in the list if they have one: today's path
  (Tailscale where it reaches, else Syncthing carries everything, as now).
- **A studio with no tailnet** can now start the direct link at all when the setting is on (send only: no Tailscale listener; what bandmates
  send arrives over the links).
- **Health:** the direct link row names each bandmate reached this way with how: "reaches james-laptop, Chilio (without Tailscale, through
  both NATs) (31 ms)" ("... relayed" once stage 3 has relays). With no Tailscale listener but someone reached this way it says "over the
  connection without Tailscale" and isn't a warning. The link speed row says "Chilio: without Tailscale, through both NATs, 88 ms". The shared
  clock row and `direct.who_of` name `nat:` peers by person. Stage 1's "Without Tailscale: <name>: direct ..." row is unchanged.
- **Falls back:** a bandmate whose link drops goes back to their Tailscale name (if any) within Lua's 2 s peer refresh; the extension's own
  answer to a frame for a `nat:` peer whose link isn't up is a fast failure ("the connection without Tailscale to it isn't up (why)"), which
  the direct link treats as any unreachable peer (its usual 10 s pause, files left to Syncthing, queued messages dropped as stale).

## How it works
**direct.cpp is unchanged above the socket.** Its frames (`SSD1`/`SSM1`/`SSP1`/`SSS1`, HMAC-signed with the studio key), one-byte answers,
per-peer Lanes with their window of 16 unanswered messages and `busy` (shared controllers' latest-wins), the send thread's kept connection,
the clock and stream windows all run as they do over Tailscale. Only where a connection comes from differs:
- `connect_peer("nat:<dev>")` calls the hook `direct_set_nat` installs (`nat_connect`, set by `nat_register`): it returns one end of a new
  **loopback TCP pair** (`loop_pair`: an ephemeral 127.0.0.1 listener that lives only for that call and accepts only the socket it just
  connected; TCP_NODELAY both ends). The other end belongs to a **stream** in that bandmate's `LinkBox`.
- A stream the other computer opens arrives as a segment with `OPEN` for an id in its half of the id space; this side makes a pair and hands
  its end to `direct_adopt`, served by a thread of its own in direct.cpp (`listen_loop` with no listening socket: independent of the
  Tailscale listener starting, stopping or missing). The same `take_conn`/`take_frame` checks apply: studio, HMAC, kinds, sizes. Adopted
  connections never go to the web UI's HTTP hook (it stays Tailscale-only): an HTTP request over the link is answered "not StudioSync's".

**The streams (`NatRel` in nat.cpp, pure, time passed in):** byte-sequenced, one per connection, inside each sealed datagram as kind 2
(kind 1 is live audio, 0 the hello). Segment: flags (OPEN, FIN, RST), u32 stream id, u64 offset, u64 cumulative ack, u32 receive window,
up to 1200 data bytes (+25 header +1 kind +28 sealing, well inside a path's ~1472).
- **Reliable, ordered:** cumulative acks; every segment with data is acked at once (a repeat too: its ack may be the one lost); a retransmit
  timer per segment (RTO 2x the smoothed RTT + 50 ms, 0.12-3 s, doubling per try to 3 s; Karn's rule); a fast resend of the first missing
  segment on three repeated acks; out-of-order segments held until the gap fills; duplicates dropped by offset.
- **A window and a size cap:** a congestion window in segments (starts 16, +1 per ack to 32, then +1/cwnd, max 128; halved on a timeout);
  the receiver's window: 256 KB ahead of what's been handed to direct.cpp; a segment past it is dropped (counted) and comes again later; a
  window update when the reader frees a quarter of it. Each stream holds at most 256 KB to send: beyond that the pump stops reading
  direct.cpp's socket, so direct.cpp's own send blocks (TCP back-pressure, its 3 s timeout as on any slow path). A segment larger than any we
  send (over 1200 data bytes), with unknown flags or a short header is refused whole. At most 16 streams per bandmate.
- **Ends:** a FIN each way after the data (graceful: an answer always reaches direct.cpp before the close); a stream is gone when both FINs
  are answered. A segment sent 10 times unanswered (~20 s) kills the stream (RST to the peer; direct.cpp sees the connection drop). A
  segment for an unknown stream gets RST; one for a stream finished in the last 120 s gets a bare ack, never a new stream.
- **A peer restarting:** its new ephemeral key makes a new link session (stage 1); the old `LinkBox` and all its streams go with it, their
  sockets close, direct.cpp's lanes and kept connection see the drop and reconnect on the next frame over the new link. No state survives
  a session (ids restart per session, keys differ).
- **The pump:** one thread per hub polls the streams' sockets (10 ms at most), runs timers, delivers, and sends. Segments arriving are handled
  on libjuice's thread straight away (acks and newly allowed data go out at once). Neither ever calls into libjuice while holding the
  streams' lock (libjuice calls back with its registry lock held, and a relayed send takes it).

**Lua (`lib/nat.lua`, `lib/direct.lua`):** `direct.ensure` starts the link for a studio with the setting on even without a tailnet;
`direct.refresh_peers` asks `nat.peers(cfg, {song, room}, "direct")` and merges with `nat.direct_merge` (only "up" links; `dev_of` gets the
device so the clock's reference pick works, `users` the person). `nat.peers(nil)` (live audio off, every tick) is ignored for `nat.HOLD` (6 s)
after the direct link last asked, so the two don't stop and start the links in turn. One hub per computer but a Live sync script per tab:
`nat.claim` (ExtState "nat setup by", refreshed every 2 s) lets the tab that set it up keep it for `nat.HOLD`; another tab's direct link
in another song sets nothing up and stops nothing meanwhile (it uses Tailscale/Syncthing for its peers), while live audio's engine (the song
in front, stage 1's rule) always takes it. Health: `direct.nat_way`, `direct.way_text`,
`direct.peer_name`.

## Files
- `extension/nat.cpp`, `extension/nat.h`: `NatRel`, segment encode/decode, the mux in `LinkBox` (`box_seg`), `pump_loop`, `nat_connect`,
  `loop_pair`; status per peer gains `streams`, `resent`, `stream_refused`; test knobs under `NAT_STANDALONE` (`nat_test_lossy`,
  `nat_test_inject`, `nat_test_sealed`).
- `extension/direct.cpp`, `extension/direct.h`: `direct_set_nat`, `direct_adopt`, the adopted connections' thread, `connect_peer`'s `nat:`
  branch, no web UI for adopted connections. Nothing else in direct.cpp changed.
- `lib/nat.lua` (`direct_merge`, `HOLD`, the Settings words), `lib/direct.lua` (ensure, refresh_peers, Health names and ways).
- Tests: `tests/nat_test.cpp` (CI runs it on macOS and Linux already), `tests/test_0_60_rt_nat2.lua`.
- Not touched: `extension/rtaudio.cpp`, `lib/liveaudio.lua`.

## Tests (JAMES-MAIN, 2026-11-20)
`tests\build_nat_test.cmd`: all ok. Stage 2's part:
- `NatRel` through a simulated path (every segment 20-50 ms late, so they reorder): 300 KB one way and 5 KB back clean (0.67 s simulated);
  10% lost each way (4.5 s); 30% lost (5.2 s); 30% doubled; 15% lost + 15% doubled + reordering; a reader that takes nothing for 2 s (the window
  shuts, 22 segments refused past it, then all of it); no answer at all (dead after its tries, between 5 and 40 s); oversized, unknown-flag
  and short segments refused; bytes past the window refused; an ack past what was sent clamped; RST ends it.
- Over two hubs' real links on localhost, with 10% of stream datagrams lost, 5% doubled and 10% held back behind the next, each way: 300
  `direct_msg` messages (a controller's moves) all arrived once, in order (1.3 s); an event file and a 1 MB one landed in the inbox whole (the
  1 MB one in 4.3 s through that loss); the clock's signed pings made an estimate; `direct_status` shows `nat:devB` ok.
- Refused over the link: a frame signed with another studio's secret (3), a message over 64 KB (5, before it's read whole), an HTTP request
  (1: never the web UI); a datagram with a flipped byte refused by the link before any stream sees it.
- The peer restarting (hub B stopped and set up again): links up again in 6.6 s, messages through again 0.5 s later.
- `python tests/run.py --no-luals`: fails 0. `build_windows.cmd` and `build_direct_test.cmd` build and pass.

## Not tested / limits
- Two real computers, real NATs, Syncthing as the rendezvous carrier, and anything inside REAPER. Streamed takes (`SSS1`) ride the same
  streams but weren't measured: the congestion window (at most 128 x 1200 B, ~150 KB in flight) caps one stream at ~1.7 MB/s at an 88 ms
  round trip, fine for WAV takes, slower than Tailscale for a big catch-up.
- Throughput under loss is modest (no SACK: a loss stalls a stream until its resend). Event files are small, so it rarely matters.
- direct.cpp keeps a status entry for every peer it ever tried: a bandmate swapped from their Tailscale name to `nat:` leaves the old entry,
  which Health shows as "can't reach" until REAPER restarts (as it already does for anyone who leaves).
- A bandmate on the tailnet for some and not others isn't a case stage 1's pair rule makes; nothing new here.

## For James to check in REAPER (desktop + laptop, after a release with this extension)
Stage 1's steps 1-3 first (the setting on, the laptop off the tailnet, "Without Tailscale: <name>: direct, through both networks' NATs").
1. With both in the same song and room and Live sync on: Health's direct link row on each reads "reaches <the other> (without Tailscale,
   through both NATs)" and isn't yellow on the laptop (no Tailscale listener there).
2. Make an edit on each: it appears on the other in well under a second (not Syncthing's 2-3 s). Chat a line each way; claim a track on one
   and see it held on the other; move a shared fader: it follows smoothly and stops where it stopped.
3. Health's shared clock row shows the other by name with an offset and round trip; Play together starts both together.
4. Restart REAPER on one: within about a minute the link row goes back to "reaches ... (without Tailscale ...)" with no action; meanwhile
   edits still arrive through Syncthing.
5. Turn the setting off: the direct link goes back to Tailscale only (the laptop isn't reached until Tailscale is back; edits via Syncthing).

## Review later (security; James deferred reviews until every feature is in)
- The streams trust the link's sealing for who sent a segment; nothing inside them is signed again (direct.cpp's HMAC on every frame still
  holds). A bandmate with the keys could open 16 streams and hold 16 x 256 KB of this computer's memory per link, or ack data it never
  got (clamped to what was sent, but it would make a frame look delivered).
- `loop_pair`'s ephemeral listener on 127.0.0.1: another local process could connect in the instant it exists; it's refused (the accepted
  end must be the socket just connected, by address and port), but a local process could make one pair fail (one frame's connection).
- `direct_adopt`'s connections skip the Tailscale address check by design (they come from the link); `take_frame` is their only bar, as on
  loopback in the tests. A forged frame is refused there; a flood of valid-looking garbage costs a connection slot (32) until it's closed.
- No per-stream rate limit on what a peer sends us beyond the windows.
