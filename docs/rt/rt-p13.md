# rt-p13: package P13, Connect without Tailscale (2026-11-21)

Backlog 1.31, 1.32, 3.2 A, 4.7 and rt-linkmove round 6 item 8. The full write-up (what each fix does, the release notes for the extension,
tests, the REAPER checks, the router-VM lab checks and the steps to build RouterBox, review-later items) is **docs/rt/rt-nat3.md, "Round 2"**.

| Item | Result |
|---|---|
| SACK (1.31) | Built: selective acks in a kind-4 datagram (older extensions ignore it); 10% loss: timer rounds 15 -> 6 |
| Health's stale "can't reach" (1.31) | Built in Lua (works with extension 1.0.35) |
| A hub behind CGNAT (1.32) | Built: UPnP WAN address vs STUN's public one, or a 100.64/10 own address; Health row; `cgnat` in the devices file |
| The relay's role and the forward (1.32) | Built: a relay reached from outside (`relay_reach`) keeps the role while online |
| A relay that stops relaying (1.32) | Built: held back after a failed link through it, 30 s doubling to 10 min |
| The hub's TURN for video-call pages (3.2 A) | Built: `StudioSync_NatIce`, the rtc model's `ice`, call.js |
| Health naming Tailscale-only features (3.2 A) | Built |
| Phone pages without Tailscale (4.7) | Built: `StudioSync_DirectLan`, a per-computer switch (off until ticked), its own Windows rule, no microphone |
| `nat:` peers' hello (rt-linkmove r6 item 8) | Built: quiet links to computers not here |
| Invitations over a NAT link (3.2 A) | Not built: needs a first-contact channel and P10's files; design in rt-nat3 round 2 |

**Shared files, small edits:** `lib/removal.lua` (the devices file's NAT comparison also covers `relay_reach` and `cgnat`: one line),
`lib/webui/call.js` (RTCPeerConnection takes the model's `ice`: one line), `tools/lab/README.md` (three rows). Expectations updated in
`tests/test_0_60_rt_nat.lua` and `tests/test_0_60_rt_webcall.lua`.

**New files:** `tests/test_0_60_rt_p13.lua`, `tools/lab/routerlab.sh`, `tools/lab/stun.py`, `tools/lab/fake_igd.py` (the last two
stdlib Python; routerlab.sh and fake_igd.py not run: RouterBox isn't built).
