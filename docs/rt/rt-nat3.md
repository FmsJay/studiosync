# Connect without Tailscale, stage 3: the hub's relay, faster set-up, network changes (rt-nat3, 2026-11-20)

Stage 1 (live audio) and stage 2 (the direct link, extension 1.0.24) reach a bandmate the studio's tailnet doesn't over a sealed UDP link that
ICE punches through both NATs. Two strict (symmetric) NATs can't be punched through, set-up waited on Syncthing, and a computer that changed
network waited ~30 s for each path to die. Stage 3 fixes those. Native and Lua tests only; not run in REAPER or between real computers yet.
The extension's version isn't raised.

## What it is
- **Still behind the same switch** (Settings > Studio > "Connect without Tailscale", band.json `nat`, off by default). Nothing below runs
  while it's off.
- **The studio hub relays.** The computer lib/hub.lua elects as the studio hub (the same choice on every computer: the owner's preferred hub
  when it's online) runs libjuice's own STUN/TURN server on **UDP 47298**, relayed addresses on **UDP 47299-47314**. It puts its address
  (`<public ip>:47298`, the IP from its STUN probe) in its devices file as `nat.relay`; the others take it from there (only from a file the
  hub's own computer wrote: `trust.device_ok`) and use it once its STUN answers them. ICE picks the relay only when no direct path works.
  - **Credentials from the studio key:** user name = the computer's device id, password = HMAC-SHA256(nat studio key, "StudioSync relay v1\n"
    + id), 32 hex. The hub knows every studio computer with a key (the devices files) and accepts only those; a new studio secret (someone
    removed) makes new passwords and restarts the relay.
  - **Caps:** at most 16 relayed addresses per computer (one per link) and 64 in all (libjuice's quotas); 1 MB/s sent in all and 256 KB/s to
    any one address (a live-audio stream is ~32 KB/s): beyond that datagrams are dropped at the relay. The rate caps are ours: libjuice's
    server.c is built with `-Dudp_sendto=nat_relay_sendto` (that file only, no source change), so every datagram it sends passes a token bucket
    in nat.cpp first.
  - **Still sealed end to end:** everything through the relay is the same `SSN1` datagram (XChaCha20-Poly1305 under the pair's own keys). The
    hub sees sizes, timing and addresses, never plaintext; it can't forge or read anything.
  - **The router:** a relay is reachable from outside its network only if the hub's router forwards UDP 47298-47314 to it. Health on the hub
    says exactly that, every time. **StudioSync never changes a router or a firewall itself.** On Windows the hub's firewall rule (the same
    "Set up connection without Tailscale" button) covers 47282-47314 instead of 47282-47297; a computer that isn't the hub accepts either.
- **Signalling over existing links.** Every rendezvous message (offer, answer, and the new "restart") still goes in the shared folder (the
  fallback: Syncthing carries it), and now also over every link that's up: as pieces inside sealed datagrams (kind 3, at most 8 x 1200 bytes),
  sent again each second while that peer's link isn't up (for a minute). The addressee takes it; any other bandmate checks it (the studio's
  signature, addressee, age) and passes it on once over its own link to the addressee. So a computer that already reaches someone (typically
  the hub) meets a new bandmate in about a second instead of a Syncthing round trip or two. The pair's own Tailscale direct link isn't a
  carrier: a pair that goes this way has no Tailscale path between them by definition.
- **The strict-NAT check** (stage 1's probe: two STUN servers from one socket; different mapped ports = strict) now also asks the hub's relay
  for its STUN answer, and Health says what the strict NAT means: this computer needs a relay; whether the hub's answers.
- **Network changes** (Wi-Fi to tethering, a new address): every 2 s the extension looks at its address on the default route (a UDP connect,
  nothing sent); a new one, or a new public address from the STUN probe, makes every link again at once with new ICE credentials and new
  keys (libjuice has no in-place ICE restart; a new agent is the same thing). Peers this computer offers to get a new offer; peers that offer
  to it get a signed "restart" message (folder + links) and offer again at once. Links come back in about a second on localhost, without a
  REAPER restart; streams on the old links drop and direct.cpp reconnects as after any peer restart (stage 2).
- **Health:** per bandmate "Chilio: direct (through both NATs), up 12s", "Chilio: relayed by James, up 3s", or "Chilio: no path (...)" (the
  last try met through the rendezvous but found no way through: both strict and no relay that answers), as well as stage 1's "connecting" /
  "waiting" / "trying again shortly". On the hub: "this computer is the studio's relay (... UDP 47298-47314; x MB relayed, n datagrams over
  its caps dropped). Bandmates outside this network reach it only if this network's router forwards UDP 47298-47314 to this computer: set that
  up in the router (StudioSync never changes a router or firewall)." On the others, when the hub's relay doesn't answer: "its router may not
  forward UDP 47298-47314 to it yet". The direct link's row says "without Tailscale, relayed by <hub>".

## Files
- `extension/nat.cpp`, `extension/nat.h`: the relay (`relay_tick`, `nat_relay_pass`, `nat_relay_caps`, `nat_relay_sendto`), the hub's
  relay use (`turn`, `relay_ok` from `probe`), signalling (`carry_on`, `hub_carry`, `send_signal`, `box_signal`, `hub_signal_rx`, the inbox
  each link and the hub loop read beside the folder file), `restart_all` + `net_id`, `nopath`; NatLinkConfig gains `turn_host/turn_port`,
  `signal_in/out`, `on_signal`, `offer_e` (the responder answers only the offer the hub chose), `bind`. Setup JSON gains `turn`, `relay`
  (`port`, `users`, `rate`, `rate_each`, `allocs`, `allocs_each`) and `timeout` (tests); status gains `turn`, `relay_ok`, `relay {}`,
  `restarts`, `signals {}`, per peer `nopath`. Test knobs (`NAT_STANDALONE`): `nat_test_only(h, 1, bind)`, `nat_test_netchange`,
  `nat_test_carry`.
- `lib/nat.lua`: `relay_plan` (who relays, whose relay), the setup's `relay`/`turn`, `entry` with `relay`, a hub with nobody to reach still
  set up (relaying), `peer_text`/`rows_from` words, `ports(relay)` and the firewall rule's range.
- Small edits elsewhere: `lib/removal.lua` (republish the devices file when `nat.relay` changes: one comparison), `lib/direct.lua`
  (`way_text`: "relayed by <hub>").
- Builds: `extension/third_party/build_windows.cmd` (server.c again with the define; the library is now `studiosync_nat3-x64.lib` so an older
  build is rebuilt), `extension/build_windows.cmd` and `tests/build_nat_audio_test.cmd` (the new name), `extension/third_party/build_unix.sh`
  (server.c's own line), `tests/build_nat_test.cmd` and `.github/workflows/extension.yml` (server.c again; macOS adds loopback aliases
  127.0.0.2/.3 for the symmetric-NAT test).
- Tests: `tests/nat_test.cpp` (stage 3 section), `tests/test_0_60_rt_nat3.lua`; one expected string in `tests/test_0_60_rt_nat.lua`.

## Tests (JAMES-MAIN, 2026-11-20)
`tests\build_nat_test.cmd`: all ok (stage 1 and 2 checks unchanged). Stage 3:
- **Relay credentials:** a studio computer's credential gets a relayed address; a credential made from another studio's secret, and a
  well-made password for a device that isn't the studio's, are refused; the same computer's second address at once is refused (quota 1 here).
- **Two symmetric NATs:** two hubs that publish only relayed candidates, each bound to its own loopback address (127.0.0.2/.3) so nothing on
  one computer joins them but the relay (it permits only its own relayed address, 127.0.0.1): with no relay they never meet and the status
  says `nopath`; given the hub's relay they're up in ~5 s, path `relayed` on both (local relay, remote relay), 100/100 sealed datagrams through.
- **Caps:** with the relay's rate cut to 20 KB/s (no restart: the link stays up) a 1 MB flood arrives as 2 of 1000 datagrams, 998 dropped
  at the relay; the same with the per-address cap; caps back: the same link carries 100/100 again.
- **Network change:** on the computer that answers, both up again in ~1.0 s; on the one that offers, ~0.5-1.3 s; `restarts` 1.
- **Signalling over links / fallback:** three computers with separate folders, the test's copier joining A-C and B-C at once and A-B only
  after 4 s: A-B up in ~1.5 s (their folder needs 8 s+ for an offer and an answer), C forwarded 2 messages. Then nothing carried and the A-B
  copy 2 s: B's network changes and they're up again by the folder alone in ~6.9 s, no message carried.
- `tests\build_nat_audio_test.cmd`: ok. `extension\build_windows.cmd`: builds. `python tests/run.py --no-luals`: fails 0.

## Not tested / limits
- Two real computers behind real symmetric NATs (or CGNAT), a real router's port forward, hairpin NAT (two bandmates relayed by the same hub
  send relay-to-relay through the hub's own public address: most home routers loop that back, some don't), anything inside REAPER, macOS
  and Linux beyond CI.
- The relay runs on whichever computer is the studio hub; if the role moves to a computer without the port forward, its relay isn't reachable
  (Health says so on the others). Set the forwarding computer as the studio's preferred hub so the role stays there.
- A hub behind CGNAT can't be reached at all however its router is set; nothing detects that.
- The relay's rate caps count what it sends, both legs of a relay-to-relay hop (so a stream relayed between two of its own clients counts
  twice). They're process-wide (one relay per REAPER).
- An unreachable relay costs nothing (links use it only once its STUN answers, checked every 10 minutes and on a network change), but a relay
  that answers STUN and then stops relaying makes links fail until the next probe.
- Network change is detected from the default route's local address and the public address; a change that keeps both (some Wi-Fi roams)
  is left to the old path's ~30 s consent timeout and stage 1's retry.

## For James to check in REAPER (desktop = studio hub, laptop; after a release with this extension)
Stage 1 and 2's checks first. Then:
1. On the desktop, Health shows the relay row: "this computer is the studio's relay ... forwards UDP 47298-47314 ...". The laptop's devices
   file (`_band/devices/<you>.json`) shows nothing new; the desktop's has `nat.relay = "<public ip>:47298"` within ~30 s.
2. Only if James decides to: forward UDP 47298-47314 on the home router to the desktop (and, Windows, press "Set up connection without
   Tailscale" again on the desktop: the rule now covers 47282-47314). StudioSync never does either itself.
3. From the laptop away from home (tethered, off the tailnet): Health has no "relay doesn't answer" row once the forward is in; without it,
   the row says the hub's router may not forward the ports.
4. Network change: with the laptop's link up ("direct (through both NATs)"), switch the laptop from Wi-Fi to the phone's hotspot. Within a few
   seconds (one Syncthing hop when no other link is up) the row goes "connecting" and back to "direct" or "relayed by James", with no REAPER
   restart; Health's live audio comes back.
5. A strict NAT (some phone hotspots, hotel Wi-Fi): Health shows "a strict NAT, so this computer needs a relay ... James's relay answers". With
   the desktop's forward in, the laptop's row reads "relayed by James" when the other side is strict too.

## Review later (security; James deferred reviews until every feature is in)
- Relay passwords are derivable by every studio member (they hold the secret): per-computer quotas are fairness, not authentication between
  members. A member could use another's quota or relay arbitrary traffic within the caps.
- The relay is an open STUN binding responder on the hub (standard; it reveals the asker's own address to it) and listens on 17 UDP ports.
- The `-Dudp_sendto` shim depends on server.c sending only through `udp_sendto` (true for libjuice 1.7.4); check again on any libjuice update.
- Signalling over links: a forwarder verifies the signature before passing anything on, and passes each message once (hop 1 is never
  forwarded); the inbox keeps only messages from this computer's own peers, newest by time. A member could replay a still-fresh (300 s)
  "restart" to make a link start over (a nuisance, not access).
- Each link's reassembly holds at most 4 half-arrived messages of at most 9.6 KB for 5 s.
- `nat_relay_sendto` returns success for a dropped datagram (as the network might drop it); libjuice never learns it was capped.
