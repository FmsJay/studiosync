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

# Part 2: the song's hub flapping between the desktop and the Mac

2026-11-20, later the same day (extension 1.0.28 released). Lua only: no C++ change.

## What was seen

The desktop's log: "you're the hub for 'Cross Test' now" 24 times, "'Cross Test': Chilio-Mac is its hub now" within the same minute after
some, and live audio flipping between "peer to peer (the hub's mix: waiting for Chilio-Mac to have the newer StudioSync extension)" and
"Chilio-Mac's computer mixes it" / "you mix it". The Mac is on extension 1.0.23 and the desktop can't reach it over the direct link at all;
the laptop reaches both.

## Why (read-only probes: the status files on the desktop's disk, `rthf_view.lua` on both REAPERs)

- The election read status *files* only, with a 45 s window. A computer whose link reaches everyone writes its file every 30 s; one whose
  link doesn't, every 15 s. Measured on the desktop while things were calm: the laptop's file reached 44 s old, the Mac's 27 s. Any extra
  Syncthing delay (the Mac's file comes through the laptop) put one over 45 s.
- While the flapping went on the song had no home (session.json last written by another computer than its sharer, so the sharer is set aside),
  and the Mac, online longest, held the song's hub. Each time its file came late the desktop saw no holder and took the role at once (it is
  the studio's hub); when the file came, two held it, the better-ranked (online longest: the Mac) won everywhere, and the desktop gave it
  back. No hysteresis either way. At 14:25 session.json was the desktop's again, the desktop became the song's home, and it stopped.
- "waiting for Chilio-Mac to have the newer StudioSync extension" was the same late status seen by live audio: the plan asked every
  bandmate's status for `lhub`, and one whose status was missing for a moment read as "older extension", so the whole room switched to its
  own streams and back. The Mac's status says `lhub` true: nothing was actually being waited for.
- Nothing told anyone the Mac's extension is 1.0.23: a hub on 1.0.23 doesn't say whom its mix has ('H'), so with it as hub a listener is
  deaf to whoever the hub can't hear (here: the desktop), as before 1.0.28.

## The fix

lib/hub.lua:
- **A third computer vouches (`hub.sees`, `VOUCH` 150 s).** Each status's hub part lists those its direct link reaches now (by the link
  watch's memory, so one failed ping doesn't rewrite the status). A candidate whose own status is 45-150 s old still counts while a computer
  that isn't late lists it. The desktop and the Mac agree through the laptop.
- **The room's statuses come from presence, not only the files** (`hub.with_room`): what the link brought (seconds old) counts before the
  file does, so the laptop's own word isn't 44 s old when it vouches.
- **A holder's grace (`HOLD` 90 s).** Whoever holds a role keeps counting until its status is 90 s old even with nobody vouching, so two
  computers alone with late files don't trade the role. The link's own watch still drops a hub it had reached within 12 s; one only the files
  show is replaced after 90 s (was 45).
- **An extension too old for the hub's jobs isn't elected (`hub.EXT` "1.0.28", status `hub.ext`)** while a computer with a new enough one is
  here, for the studio's hub and a song's, the owner's pick and the song's home included; such a computer gives the role up itself. When
  nobody's is new enough the role still goes to someone (the restore points need no extension) and the view says `hub_fit` false. A status
  that doesn't say (an older StudioSync, until its update arrives) counts as before, so an update reaching the computers one by one doesn't
  hand the roles to whoever got it first; a computer with no extension says "0". Health's hub row names those passed over.

lib/liveaudio.lua, lib/livex.lua:
- **Nobody waits for anyone's extension.** `hub_plan` no longer asks every bandmate's status; only the hub's own extension must be new
  enough (`hub_fit` from the view), and this computer's (`liveaudio.hub_fit`: an older one keeps its own streams with everyone, which the
  extension handles per peer since 1.0.28). lib/livex.lua's mix-host pick (rt-sonox) uses the same test for `can`.
- **The room's size is held (`HUB_KEEP` 60 s, `liveaudio.hub_n`).** Big enough for the hub's mix once, it stays so until it has been smaller
  for a minute: a status late for a moment took someone off the list and switched everyone's audio.

## Tests

`tests/test_0_60_rt_hubfix_elect.lua`: a small world where each computer elects from the statuses as they reach it (a file's trip 8 s for
two minutes, then 60 s for two minutes, over 20 minutes).
- Desk and Mac can't reach each other, Lap reaches both, the Mac holds the hub: with the old rules the desktop's view moves 8+ times; now
  nobody's moves and all three agree throughout. The Mac really gone: replaced once.
- Desk and Mac alone: the same flapping before, none now; the holder gone for good: taken over once after HOLD.
- The Mac's extension 1.0.23: all three say Desk within one tick, one move each, none after. The Mac on an older StudioSync too (no `ext`):
  left as it was, steadily. Nobody's new enough: the ranking as before; the owner's pick with an old one isn't the studio hub.
- Live sync's tick end to end: a holder's file 100 s old kept while Lap's link reaches it, replaced when nobody does; the room's link
  statuses over the files; `status_part`'s `ext` and `sees`; an old extension passed over, Health's words; this computer giving the role up.

`tests/test_0_60_rt_hubmix.lua` (changed: an older bandmate doesn't block the mix, the hub's own extension too old, the room's size held);
`tests/test_0_60_rt_hub.lua` (one line: the stand-in computer says its extension).

## To check in REAPER

1. After the update is on all four (Lua only; the Mac takes it from the studio's folder), `rthf_view.lua` on the desktop and the laptop:
   the same `hub` in both views, and each status file's hub part with `ext` (the Mac's "1.0.23") and `sees`.
2. Health's hub row on any computer: "Not a hub until REAPER restarts there with StudioSync's extension 1.0.28 or newer: Chilio-Mac."
3. The desktop's log over an hour: no new "you're the hub for 'Cross Test' now" / "is its hub now" pairs, and no "waiting for ... to have
   the newer StudioSync extension" at all.
4. Live audio on the desktop and laptop: the mix's host doesn't change while nobody joins or leaves; the Mac heard by its own streams
   (`via_hub=false`) where the hub doesn't hear it.

## Not done / limits (part 2)

- Until the Mac's StudioSync has this change, its status doesn't say its extension, so the others still count it as able (as before).
- The song's home still comes and goes with who last wrote session.json (the Syncthing writer check sets the sharer aside when anyone else
  publishes the timeline). With the holder's grace that no longer flaps, but the home should come from something only the sharer writes.
  Left for James: it's the trust design.
- The desktop's own status file is rewritten every 2 s (it can't reach the Mac, so it never goes quiet, and something in its status changes
  every tick). It works, but it's Syncthing traffic worth a look.
- A hub is still chosen without asking whether everyone can reach it: with `sees` in every status that ranking is now possible (prefer the
  computer most others reach). Not built.
- Review-later (security): `ext` and `sees` are a member's own word in its own status. A false `sees` keeps a computer that left counted
  for up to 150 s; a false `ext` makes its writer eligible (as everyone was before) or not. Neither grants anything a member hadn't.
