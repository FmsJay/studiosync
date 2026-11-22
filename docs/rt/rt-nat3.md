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
  - **Caps:** at most 32 relayed addresses per computer and 128 in all (libjuice's quotas; links ask for one only when they may need it); 1 MB/s sent in all and 256 KB/s to
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

## Fix: the NAT entry's publish on a gate of its own (found in the stage 2 test between real computers)
The desktop never put its NAT key in `_band/devices/James.json`: it also runs main's StudioSync for another studio, both versions'
`removal.tick` share one 30 s gate (ExtState "removal look"), main's took the slot every time, and its publish writes no `nat`. Now
`removal.publish_all` (lib/removal.lua) publishes this computer's devices entry in every studio at most every 30 s on its own gate
("devices publish rt"), called first thing in `removal.tick` whoever holds the shared slot. The file still has one writer (this computer);
a field it doesn't know, in this computer's own earlier file, is kept. An older version that rewrites the file (main does only when its
Tailscale name changes) drops `nat`; the next pass, within 30 s, puts it back. Test: `tests/test_0_60_rt_nat3_publish.lua`.

## Fixes from the macOS CI runs
- **A responder gives way to a newer offer** (ea2adac). With a slow answer (TURN gathering), the responder's link waited out its timeout on
  an offer the initiator had already replaced, so every answer landed one offer behind ("the peer answered an older offer"). A newer offer
  now ends that link at once and the hub answers the newest (`offer_t`).
- **Relayed addresses only when a link may need one** (80ca4a5). libjuice never gives a TURN allocation back when an agent is destroyed: it
  lives its full 10 minutes on the relay, so every link made again (a retry, a restart, a network change) held one more of the computer's
  quota, and a slow first try locked the test's pair out. Links now ask the hub's relay for an address only when this computer's NAT is
  strict or blocked, or the last try to that peer found no path (an easy-NAT computer still meets a strict one through the strict side's
  relayed address). Quotas: 32 per computer, 128 in all.

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

# Round 2: package P13, the rest of Connect without Tailscale (rt-p13, 2026-11-21)

Backlog items 1.31, 1.32, 3.2 A and 4.7 (default yes), plus rt-linkmove round 6 item 8 (the `nat:` peers' hello). Offline and native tests
only; not run in REAPER, between the real computers or in the VM lab. The extension's version isn't raised (the coordinator releases).

| Item | Result | Where |
|---|---|---|
| 1.31 No SACK: a loss stalls a stream | **Built**: selective acks | `extension/nat.cpp`, `nat.h` (`NatRel::sack_blocks`, `NatRel::sack`, kind-4 datagrams) |
| 1.31 Health's stale "can't reach" after a swap to `nat:` | **Built** (Lua, works with the extension already out) | `lib/direct.lua` `health_line`, `direct.STALE` |
| 1.32 A hub behind CGNAT is never detected | **Built**: UPnP's WAN address against the public one, and the computer's own 100.64/10 address; a Health row; `cgnat` in the devices file | `extension/nat.cpp` (`upnp_wan`, `nat_ip_class`), `lib/nat.lua` |
| 1.32 The role moves to a computer without the forward | **Built**: a relay reached from outside keeps the role while it's online | `extension/nat.cpp` (relay `outside`), `lib/nat.lua` (`relay_plan`, `learn`, `entry`), `lib/removal.lua` (one comparison) |
| 1.32 A relay that answers STUN and stops relaying | **Built**: held back after a link fails through it, back-off 30 s to 10 min | `extension/nat.cpp` (`relay_bad`, `relay_hold`), `lib/nat.lua` Health |
| 3.2 A The hub's TURN for video-call pages | **Built** | `extension/nat.cpp` (`StudioSync_NatIce`), `lib/nat.lua` `ice`, `lib/webcall.lua`, `lib/webui/call.js` (one line) |
| 3.2 A Health naming the Tailscale-only features | **Built** | `lib/nat.lua` `tailscale_row` |
| 4.7 Phone pages without Tailscale (LAN listener, no microphone) | **Built**, off per computer until ticked | `extension/direct.cpp` (`direct_lan`, `StudioSync_DirectLan`), `lib/nat.lua` (switch, firewall rule, Health) |
| rt-linkmove r6 item 8: `nat:` peers' hello | **Built**: quiet links to the studio's computers not here | `extension/nat.cpp` (`quiet`), `lib/nat.lua` (`peers`, `quiet_up`), `lib/direct.lua` `studio_peers` |
| 3.2 A Invitations over a NAT link | **Not built** (needs a first-contact channel and P10's files): design below | |

## What each does

**Selective acks.** A receiver holding bytes past a gap sends, beside its usual ack, a kind-4 datagram naming up to 4 held ranges. The sender
marks segments the peer holds (never resent by a timer) and resends every gap below the highest held byte at once, at most once a round trip
each. Before, only the first gap went again (after three repeated acks) and every other loss in the window waited out its timer, halving the
window each time. An older extension ignores a kind it doesn't know, so a mixed pair works as before. Simulated path (20-50 ms, reordering),
300 KB: 10% lost each way, timer rounds 15 -> 6 and segments sent 735 -> 476; 3% lost on 600 KB, timer rounds 7 -> 0. Over two hubs' real
links on localhost (10% lost, 5% doubled, 10% held back), the 1 MB event file now lands in 2.7 s (4.3 s in rt-nat2's run).

**The stale row.** The extension keeps a status entry for every peer it ever tried. Health's direct-link row now leaves out a failed peer
whose last try is over `direct.STALE` (60) s old: one in use is tried at least every ~10 s. Fixed in Lua, so it works with extension 1.0.35.

**A hub behind CGNAT.** The relay hub asks its router for its own internet address by UPnP (an SSDP search on its network, the description
and `GetExternalIPAddress` only from the IP that answered, 2 s and 64 KB at most, on a thread of its own every 10 minutes). When that isn't
the public address STUN sees (or the computer's own address is in 100.64.0.0/10: a carrier's NAT, or a Tailscale exit node), the status says
`relay.cgnat` and Health says no forward on that router can reach the relay. The devices file carries `cgnat = true` (remembered per public
address), and no such computer counts as a proven relay. No UPnP answer: nothing is said (many routers have it off).

**The role stays with a forward that works.** The relay records when it last answered a public address (someone outside its network reached
it, so the forward works); the computer remembers that public address (ExtState, across restarts) and its devices file says `relay_reach`.
Every computer picks the relay from the same files: the studio hub if it's proven or nobody else is; else the proven computer that's online
(lib/hub.lua's candidates; the lowest name when several). So handing the hub role on, or the hub going to sleep and coming back, no longer
moves the relay to a computer without the forward. A new public address knows nothing until it's reached there.

**A relay that stops relaying.** A link the hub's relay was given that fails through it (no path, its relayed path stopped, or no relayed
address at all) holds the relay back: links go without it (`relay_ok` false) for 30 s, doubling per failure in a row to 10 minutes, its STUN
asked again at once (a relay that's gone altogether shows as not answering) and when the hold ends. A link it carries clears the count. Health:
"the studio's relay (James, ip:port) answers but didn't carry the last link that needed it (its router may forward UDP 47298 but not
47299-47314, or not loop it back): links go without it for N s". Before, links kept asking it (each one more allocation of the computer's 32)
until the next 10-minute probe, and Health said nothing.

**Video-call pages.** With the studio's connection without Tailscale on, the "rtc" model carries `ice`: the studio's STUN servers and the relay
as TURN (`turn:<ip>:47298?transport=udp`, this computer's own relay user and password from `StudioSync_NatIce`; this computer's own relay on
127.0.0.1 when it is the relay). call.js hands it to `RTCPeerConnection`. With it off: no ICE servers, host candidates only, as before.

**What still needs Tailscale.** A grey Health row, when this computer is off the studio's tailnet or reaches anyone without it: changes, chat,
claims, the shared clock, live audio and video calls go the connection without Tailscale; the Hop plug-in, Listen along, listening links,
browser guests, invite links and phone pages from other devices still need Tailscale (the last on this computer's own network with the switch
below).

**Phone pages on this network.** Settings > Studio, under Connect without Tailscale: "Phone pages on this network (this computer)", a
per-computer switch, off until ticked. Then the web UI, with the studio's token as over Tailscale, also listens on this computer's private
address (10.x, 172.16-31.x, 192.168.x) at the direct link's port, from private addresses only; a frame there is refused. On Windows only once
its own firewall rule is in ("StudioSync phone pages on this network": reaper.exe, TCP 47281, `remoteip=LocalSubnet`; Health's button, one
UAC), so Windows' own box never comes up in REAPER's face. Health gives the address with the token. Plain HTTP: browsers give such pages no
microphone, so the Record page still needs Tailscale (4.7's "no microphone").

**The hello for computers not here.** The direct link's call to `nat.peers` also sets up quiet links to the studio's other computers whose
pair goes this way and whose person isn't here (trusted, not removed, the song in a guest's list): no relay for them and retries every 30 s
doubling to 10 minutes (each try is a rendezvous file in the folder). Live audio's calls keep the same setup for 6 s, so the two don't drop and
remake the links. `direct.studio_peers` adds the quiet peers whose link is up, so `presence`'s hello (and the studio-wide signed files) reach
them; once the other side's Live sync hears it, each is here for the other and the link is an ordinary one. As rt-linkmove said, a first link
still needs the folder or another link that's up: with Syncthing paused on both and no other link this can't meet.

## Invitations over a NAT link (not built)
A joiner without Tailscale has no channel to the inviter before it's in: the rendezvous is the shared folder (not shared yet) or another link
(none yet). Two ways that would work, both outside P13's files:
1. **Syncthing as the channel** (`lib/joins.lua`, `lib/services.lua`): the joiner offers the inviter a tiny folder whose id is derived from the
   invite code and whose label carries its signed ask (device id, name, `nat.pub`, an HMAC with the code). The inviter's Live sync sees the
   pending offer (Syncthing's REST), checks the HMAC, and lets that device in as Let them in does today. Syncthing's own discovery and relays
   carry it, so no Tailscale and no router change. Then the folder, the devices file and the NAT link follow as now.
2. **The hub's public address in the token**: only with the relay's forward in (section 4.2's default is no forward), and it needs a TURN
   credential in the link (sealed to the code) and a TURN client in the joiner's extension. More code, and a dependency on James's router.
Today a joiner without Tailscale gets an honest note (rt-p10) and is let in with Let them in.

## Extension changes for the release
New ReaScript: `StudioSync_NatIce()` (JSON user/pass for a browser's TURN), `StudioSync_DirectLan(port)` (phone pages on this network; 0
stops). `StudioSync_NatStatus` gains `relay_answers`, `relay_bad`, `relay_hold`, `relay.wan`, `relay.cgnat`, `relay.outside`, and per peer
`quiet`, `turn`; setup peers take `quiet`, and the setup takes `relay_hold` (tests). `StudioSync_DirectStatus` gains `lan { bind, port, error }`.
A new datagram kind (4, selective acks) on the links: an older extension ignores it. Lua checks each new function exists, so an older
extension simply goes without (no TURN for pages, no LAN pages, no SACK).

## Tests (JAMES-MAIN, 2026-11-21)
- `tests/nat_test.cpp` (built with `tests/build_nat_test.cmd`'s steps into a scratch folder): all ok. New: "SACK: ..." (6 checks, the
  timer-round comparisons fail with `sack()` taken out), "a relay that answers STUN but stops relaying ..." and "that relay relaying again ..."
  (a test knob mutes every relay's Data indications and ChannelData while its STUN answers; without the hold no `relay_bad` is ever set), "a
  quiet peer ... is never given the relay", the address classes, and "relay hub whose router's own WAN address (UPnP) is 100.70.1.2 ..." and
  its clearing (a stand-in router on 127.0.0.1 answering SSDP, the description and the SOAP call).
- `tests/direct_test.cpp`: `fails 0` (`SS_TEST_PORT=47591`). New: phone pages on this network: listening, a page goes to the web UI, a
  well-signed frame refused there, off again.
- `tests/test_0_60_rt_p13.lua` (new): the relay plan (proven, offline, CGNAT, an untrusted file), learning and publishing `relay_reach` and
  `cgnat`, the Health rows, the stale row, the quiet peers and the hello's peers, the pages' ICE servers, phone pages on this network.
  `tests/test_0_60_rt_nat3_publish.lua`: the devices file rewritten when `relay_reach` or `cgnat` changes (fails against HEAD's
  `lib/removal.lua`). Two expectations updated: `test_0_60_rt_nat.lua` (Health's new grey row), `test_0_60_rt_webcall.lua` (call.js's line).
- `python tests/run.py --no-luals`: fails 0. `extension\build_windows.cmd` with `DLL_OUT` in a scratch folder: builds (the tracked DLL untouched).

## REAPER checks on the real computers (after a release with this extension)
Stage 1-3's checks first. Desktop = studio hub, laptop off the tailnet.
1. **Stale row.** Laptop on the tailnet, Live sync running on both; take the laptop off the tailnet (its link goes `nat:`). Within about a minute
   Health's direct-link row on the desktop reads "reaches ... James-Laptop (without Tailscale ...)" with no "can't reach james-laptop".
2. **What still needs Tailscale.** On the laptop (off the tailnet): a grey row "Without Tailscale on this computer: ... these still need
   Tailscale here: the Hop plug-in, ...". On the desktop: "Reached without Tailscale: James-Laptop ...".
3. **Video call.** Laptop off the tailnet: open the web UI on both and Call the other: video both ways. In the browser's
   `chrome://webrtc-internals`, the selected pair is srflx or host (on the same LAN) or relay (only with James's forward in).
4. **Phone pages on this network.** Desktop: Settings > Studio > Phone pages on this network; Health asks for its firewall rule (one UAC) and
   then shows `http://192.168.x.y:47281/?t=...`. On the S23 on the home Wi-Fi (CDP over adb, a new tab, rt-lab "The S23"): the page opens, Home
   and Chat work; the Record page says the microphone isn't available. Untick: the address stops answering.
5. **The relay's rows** (only if James forwards UDP 47298-47314 to the desktop, section 4.2): from the laptop on the phone's hotspot, after
   one relayed link, the desktop's relay row says "Reached from outside this network N min ago"; `_band/devices/James.json` has
   `nat.relay_reach`. Hand the hub role on (Health: Hand it on): the laptop's turn stays the desktop's relay.

## Lab checks (the router VM; nothing on the real PCs' firewalls)

### The router VM (James's steps: creating VMs is outside an agent's scope)
1. Power LinuxBox2 off and take a powered-off snapshot `pre-router` (its netplan already matches any NIC: rt-lab).
2. `./lab.sh clone RouterBox` (a linked clone of LinuxBox2's snapshot: about 300 MB). In its .vmx (VM off): keep ethernet0 and set it to a
   LAN segment `lab-wan`; add ethernet1 on a LAN segment `lab-lan` (Workstation: VM Settings > Network Adapter > LAN segment). Turn XFCE off
   if you like (`systemctl set-default multi-user.target`).
3. `./lab.sh clone LinuxBox3` the same way, ethernet0 on `lab-wan`: the bandmate "on the internet", the STUN servers and (for the relay
   checks) the hub. Run `vm_identity.sh` in it as in rt-lab.
4. LinuxBox2's ethernet0 to `lab-lan` (VM off). Static addresses (no DHCP on LAN segments): LinuxBox2 `10.77.0.2/24` via `10.77.0.1`;
   LinuxBox3 `203.0.113.10/24`; RouterBox's WAN `203.0.113.1/24`. (203.0.113.0/24 is a documentation range: "public" in the lab only.)
5. Copy `tools/lab/routerlab.sh`, `stun.py`, `fake_igd.py` into RouterBox and LinuxBox3 (`scp` through the desktop). In RouterBox:
   `sudo ./routerlab.sh up ens192 203.0.113.1/24 ens224` (interface names from `ip -br link`).
6. On LinuxBox3: `python3 stun.py --port 3478 & python3 stun.py --port 3479 &`. In the test studio's band.json (owner): `nat` true,
   `nat_stun` "203.0.113.10:3478 203.0.113.10:3479". Neither VM has Tailscale: the lab is the hour-long gate's "Tailscale off".
7. Two strict NATs (L2) need a second router: clone RouterBox as RouterBox2 with its LAN on `lab-lan2` and a client there (another clone),
   `up` with WAN 203.0.113.2.

### The checks
- **L1 NAT kinds.** For each `routerlab.sh mode open|restricted|cone|symmetric` (a new mode drops the old mappings: restart Live sync on
  LinuxBox2 after each): LinuxBox2's `StudioSync_NatStatus().nat` is `easy` for open, restricted and cone, `strict` for symmetric; with
  LinuxBox3 as the bandmate, Health on both says "direct (through both NATs)" for the first three. For symmetric with LinuxBox3 as the hub
  (relay on, its address public in the lab): "relayed by <LinuxBox3's person>" only if LinuxBox3 is strict too; otherwise direct through the
  strict side's relayed address.
- **L2 Two symmetric NATs.** RouterBox and RouterBox2 both `mode symmetric`, LinuxBox3 the hub: the two clients' rows read "relayed by ...";
  without the hub's relay (hand the hub role to one of them): "no path ... trying again shortly".
- **L3 SACK.** `lab.sh net x2 shape 203.0.113.10 --delay 40 --loss 5` on LinuxBox2. Record a 3-minute take on LinuxBox2 with the streamed
  copy on; LinuxBox3's copy keeps up (the stream trace, `direct.trace_path`); compare `resent` in `StudioSync_NatStatus` with extension 1.0.35
  on the same shaping (expect fewer, and no multi-second stalls in the trace). `undo` after.
- **L4 Hub behind CGNAT.** `routerlab.sh double on`, `routerlab.sh forward on` (the forward on the home router, which can't help), and in
  RouterBox: `sudo ip netns exec home python3 fake_igd.py --wan 100.64.77.2 --lan 10.77.0.1`. Make LinuxBox2 the preferred studio hub. Within
  ~30 s its Health shows "this computer's network is behind another NAT (its router's own internet address is 100.64.77.2 ...)" and its
  devices file has `nat.cgnat = true`. LinuxBox3's relay row says the relay doesn't answer. `double off` and stop fake_igd after.
- **L5 The role stays.** `double off`, `forward on`, LinuxBox2 the hub; LinuxBox3 strict (or `nat_stun` making it so) reaches LinuxBox2's
  relay: LinuxBox2's relay row "Reached from outside this network ..." and `nat.relay_reach` in its devices file. Then make LinuxBox3 the
  preferred hub: LinuxBox3's `StudioSync_NatStatus().turn` stays LinuxBox2's relay (it's proven and online); stop LinuxBox2's Live sync: within
  ~45 s (the candidates' age) the role goes to LinuxBox3.
- **L6 A relay that answers but can't relay.** `forward stun` (47298 only): a link that needs the relay fails; Health on the far side says
  "answers but didn't carry the last link that needed it ... for 30 s", then 60, 120 s on further failures. `forward on`: the next try after
  the hold meets through it and the row goes.
- **L7 Network change.** With a link up, `routerlab.sh wanip 203.0.113.5/24`: LinuxBox2's links make themselves again within a few seconds
  (`restarts` +1), Health back to "direct" or "relayed".
- **L8 Hairpin.** LinuxBox2 the hub behind RouterBox (`forward on`), a second client behind the same RouterBox, both relayed (`only` isn't
  available in REAPER: make both strict with `mode symmetric`): with `hairpin off` their relay-to-relay path through the public address
  fails; `hairpin on`: it works.
- **L9 The hour.** No Tailscale anywhere in the lab: LinuxBox2 and LinuxBox3 in one room for an hour with live audio playing (a tone track),
  edits every few minutes, chat: Health stays green; the NAT status `fails` stays 0 after the first minute.
- **L10 The hello.** LinuxBox2 and LinuxBox3 linked; pause Syncthing on LinuxBox2 and restart its Live sync: it's "here" for LinuxBox3 within
  ~10 s (rt-fix5's timing) while a link to anyone else is up (the rendezvous goes over it); with no other link up, it waits for Syncthing (the
  limit above).

## Review later (security), added this round
- Video-call pages get this computer's relay password (`StudioSync_NatIce`) in the rtc model: any page with the web UI's token (a phone
  included) can use this computer's relay quota and bandwidth within the caps. With the connection without Tailscale on, browsers also ask
  the public STUN servers (they learn the browser's address, as the extension's own probe already lets them).
- Phone pages on this network: plain HTTP on the LAN, so the token in the address and the cookie cross the Wi-Fi in the clear; any device with
  a private address on that network may try (the token is the only bar; the Windows rule allows the local subnet). Off per computer until
  ticked.
- UPnP: the relay hub sends an SSDP search and reads the description and control URL from whatever answers on its network (only from the IP
  that answered, 64 KB and 2 s at most); a device there could claim any WAN address, making Health say CGNAT and the role move.
- `relay_reach` is a member's own claim about its own computer: a member could set it to draw the relay role (and see sizes and timing of
  relayed links, as any relay does). "Reached from outside" counts any public sender the relay answered, a scanner included.
- Selective acks are trusted like the cumulative ack (the link's sealing): a member's SACK can claim bytes it never got, so they aren't
  resent and its own stream stalls; resends it triggers are bounded to once a round trip per segment.
- Quiet links: one rendezvous file per offline studio computer whose pair goes this way, every 30 s doubling to 10 minutes, and hellos to them.
- The relay's hold: a member that makes links through the relay fail can hold it back for others on that computer (a nuisance).
