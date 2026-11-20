# rt-hubfix: one-way audio and "joining" for minutes through the hub's live mix

2026-11-20, after the four-computer test with StudioSync 0.59.49.69 and extension 1.0.27. Needs an extension release (C++ changed).

## What was seen

Desktop (studio owner), laptop, LinuxBox and Chilio's Mac in Cross Test, live audio on. The laptop's REAPER started first, the desktop's Live
sync about a minute later. 2-3 minutes in:

- laptop: hub state `hub`, serving 0, rescues 4, mix_gap 298 ms; its peer james-main fill -1, underruns climbing (it heard nothing of the desktop);
- desktop: hub state `joining`, serving 0, for minutes; it heard the laptop fine.

## Why

`state` in the extension's hub status is the *listener's* state: `hub` means "hearing through a hub's mix", not "being the hub". Both
computers' logs say who the hub was: "live audio: Chilio-Mac's computer mixes it for the room" (desktop 11:19, laptop 12:19 its clock). So:

1. The Mac mixed for the laptop (laptop: `hub`). The Mac's peer list left the desktop out (its room read the desktop's status late: the same
   asymmetry rt-small counted as `not_here`). So the desktop's 'R' (asking for its mix) and its audio were dropped at the Mac.
2. The desktop never got a mix and kept asking: `joining` with no end. Audio-wise that is direct streams (it says `via` 0), so it heard everyone.
3. The laptop, hearing the Mac's mix, told *everyone* ('M' via 1) that its streams come through the hub, so the desktop stopped sending to it,
   and the laptop faded every direct stream out. The Mac's mix had no desktop in it. One-way: laptop -> desktop fine, desktop -> laptop silent.

Read-only probes of both REAPERs (`rthf_probe.lua`, `rthf_raw.lua` in the bandtest scratchpad) later showed the room had moved on (the desktop
serving 2, the laptop through it) and the Mac still missing from rooms now and then (`not_here` from its address climbing on the laptop).

## The fix (extension/rtaudio.cpp)

- **'H': whom the hub's mix has.** With each 'I' (every 0.25 s) the hub sends each listener the addresses whose Talk or Play it receives now.
  A listener through that hub tells only those peers (and the hub itself) "my streams come through the hub" ('M' is per peer now), and leaves
  out only their own streams; a peer the hub doesn't hear keeps sending to it directly and is heard directly. Per peer `via_hub` in the status
  is now "heard in the hub's mix" (Health's "hearing ..." then shows such a peer by its own latency). An older hub that never sends 'H' counts
  as "everyone in the mix", as before; an older listener ignores 'H' (unknown kinds are dropped).
- **A join no mix answers stops.** Asking for 5 s (`JOIN_S`) with no mix: back to `direct`, `join_fails` counted, asked again 10 s later
  (`JOIN_RETRY_S`). Asking never cost audio, but the status said `joining` for minutes. Health: "Chilio-Mac's mix didn't come when asked (3
  times), so you hear everyone's own streams; asked again every 10 s" (lib/liveaudio.lua `hub_text`).
- Nothing changes for the hub's election (lib/hub.lua) or `hub_plan`: whichever computer the views pick, audio stays two-way.

## Tests

- `tests/rtaudio_test.cpp` `start_order_test` (also `rtaudio_test startorder` alone): M (the Mac) lists A (the laptop) only; A starts with M as
  its hub, D (the desktop) 1.5 s later with M as its hub. Checks: A hears through M's mix, A and D hear each other at full level (never
  one-way), A's status says D is heard directly and D keeps sending to A, D is `direct` with `join_fails` >= 1 by 7.8 s; then the owner's pick
  takes the hub back (M's list catches up, D mixes, A and M take D): everyone hears everyone at full level, D serves 2, A's and D's longest
  gap in each other through all of it under 60 ms (measured 5 ms). Against 1.0.27's rtaudio.cpp the same test fails 4 checks: A hears D at
  0.000 while D hears A at 0.301, D still `joining` at 7.8 s, A's longest gap in D 5.6 s.
- `tests/test_0_60_rt_hubfix.lua`: Health's words (a peer outside the hub's mix by its own latency, green; a join no mix answers).

## To check in REAPER (after the extension release)

1. Same start order: laptop REAPER and Live sync first, the desktop's Live sync a minute later. On both, `underrun.lua`/`rthf_probe.lua`: no
   peer with fill -1 and climbing underruns while both run; the desktop never `joining` for more than ~5 s at a time.
2. If a hub's list leaves someone out again (`not_here` on the hub), that someone's peers show `via_hub=false direct=true` for it and hear it.
3. Hand the hub to the desktop (or let the views move it): the laptop and Mac go `hub` through the desktop within a few seconds, no silence.
4. `rtaudio_test startorder` on the Mac/Linux CI runners passes (the full rtaudio_test runs it too).

## Not done / limits

- The asymmetric peer lists themselves (a room that leaves a present computer out, rt-small's `not_here`) aren't fixed here: through a hub
  that does hear it, that computer is now heard; peer to peer it still isn't until the room lists it. A computer the hub doesn't list can't be
  mixed for (its 'R' is dropped: it falls back to direct after 5 s).
- Policy question for James: the live mix goes to the *song's* hub (its home, here the Mac on Wi-Fi), not the studio's preferred hub; the
  desktop "takes the hub back" only when the views pick it (the Mac away). Changing that is a hub.lua decision, left alone.
- Review-later (security): 'H' is tagged with the studio secret like every control datagram and only read from a listed peer that is this
  computer's hub; its addresses only narrow whom a listener tells to stop sending (a forged or wrong 'H' can at most make peers send directly,
  which costs bandwidth, not audio or access). Size-checked (at most RT_MAX_PEERS addresses, exact length).
