# rt-roomlist: computers that disagree about who's in the room for live audio (2026-11-20)

Needs an extension release (C++ changed, `extension/rtaudio.cpp`; rides with rt-hubfix's pending one). The Lua parts work with 1.0.27 too,
minus the two-way add (it reads fields only the new extension writes).

## What was seen

- The laptop's live audio list left the desktop out while the desktop listed the laptop and sent (one-way; rt-small's `not_here`).
- Chilio's Mac, the song's hub, left the desktop out, so the desktop's audio never entered the mix (rt-hubfix).
- The laptop's `not_here` from the Mac's address kept climbing: the Mac dropped out of the laptop's list now and then.

## What the probes showed (read-only, both REAPERs, 19:14 UTC)

`rtroom_probe.lua`, `rtroom_nh.lua`, `rtroom_log.lua`, `rtroom_time.lua` in the bandtest scratchpad.

- At that moment both lists agreed (desktop: Mac, laptop, LinuxBox; laptop: Mac, desktop, LinuxBox) and neither `not_here` count moved
  (desktop 1248 from LinuxBox's address, laptop 37425 from the Mac's): the episodes come and go.
- The devices files hadn't changed since the morning, and reading the status and devices files takes under 1 ms, so neither
  `trust.device_ok`'s cache nor refresh_peers' 50 ms gate explains a lasting drop.
- The desktop can't reach the Mac at all right now: its direct link says "no answer" and Tailscale shows `rx 0` from the Mac (the laptop
  and the Mac are on one network, 10 ms apart; the desktop and LinuxBox on another, 77 ms from them). So the Mac reads the desktop only
  from its status file, never from the link's heartbeats.
- A computer always lists the others from the same list for live audio and for the link's heartbeats (`direct.peers`), and a heartbeat
  from a computer makes it present at once (`presence.from_msg`). So whoever sends audio to you also sends you heartbeats, and a one-way
  spell lasts until the next one gets through, unless the sender's heartbeats stop while its audio goes on: its Live sync held (a dialog
  pauses every script; the extension's audio thread keeps sending with the old list), or the link failing where UDP gets through.

## The causes, and what changed

1. **The quiet status file (lib/presence.lua `link_carries`).** While "the link reaches everyone here", the status file is written only
   every 30 s. "Here" was `presence.peers` (45 s), which leaves out exactly the people whose status went old here; this computer doesn't
   list them, so they get none of its link messages and read only its file, which looked older than 45 s to them whenever Syncthing took
   over 15 s (the Mac on Wi-Fi). They then dropped this computer in turn, and both stayed apart until a file landed fresh. Now "here" for
   this is anyone with a status in the last `presence.READERS` = 120 s: such a person, not reached, keeps today's pace (every 15 s).
2. **Live audio heard from a computer the room doesn't list (lib/liveaudio.lua `heard_merge`, extension `not_here_peers`, `heard_ago`).**
   Audio that comes tagged with the studio's secret means the sender's room lists this computer. Now:
   - The extension keeps each such sender apart (up to 16 addresses, oldest replaced): `not_here_peers` = { "ip:port" = { ago, n } } for
     those heard in the last minute. Each listed peer has `heard_ago` (its last tagged datagram). Datagrams are dropped exactly as before.
   - Live sync's tick maps each address heard in the last `HEARD_S` = 15 s to a studio computer: its Tailscale name from `tailscale status
     --json` (`direct.ips_in`, the same background call as link speed), then `direct.studio_peer`: a devices file whose own computer wrote
     it (`trust.device_ok` true, as the room's list asks) and, for a guest, a list that has the song. Same port only; the connection
     without Tailscale's synthetic addresses aren't looked up. Anything else stays out.
   - That computer is added to the live audio list (and the hub's view) while it keeps sending (`heard_ago` under 15 s), and dropped once
     it's been silent 15 s (its room dropped this one, or it left) or the room lists it itself. Logged once per computer per session:
     "live audio: <name>'s computer sends here before this room lists it (its status is late here), so it's heard and hears you meanwhile".
   - Through a hub this means the hub adds a listener whose 'R' it heard, so its mix has that listener.
3. **Health's "sends here but isn't in this room"** was shown for the rest of the session after any one datagram. Now only while one was
   heard in the last 5 s (with the new extension; an older one: as before).

Presence itself already took the freshest evidence: a heartbeat over the link counts though the status file is old, the file being the
fallback (proved in the test, unchanged).

## Tests

- `tests/test_0_60_rt_roomlist.lua`: a heartbeat beats a 60 s old file; someone with an old status keeps the file at 15 s until READERS
  passes (HEAD fails this: "not quiet"); `heard_merge` adds a studio computer heard now, never a stranger, keeps it through a quiet spell
  under 15 s, drops it after, hands over to the room's list; the address -> computer chain refuses a guest without the song, a devices file
  its computer didn't write, an unknown address, another port, a synthetic address, and "Syncthing hasn't said"; Health's words.
- `tests/rtaudio_test.cpp` `not_here_test` (also `rtaudio_test nothere` alone): the sender off the list is in `not_here_peers` heard
  just now; once listed, its `heard_ago` is under 0.5 s.
- `python tests/run.py --no-luals` on HEAD plus these changes: fails 0 apart from rt-nohold's test, which needs a git checkout. The full
  `rtaudio_test` on HEAD plus these changes: see the report.

## REAPER checks (after the extension release)

1. `rtroom_nh.lua` on each computer during a session: `not_here` should stop growing within a second of starting, for any studio computer.
   The log says "... sends here before this room lists it ..." when it happened.
2. Hold the Mac's (or any one computer's) Live sync with a dialog for a minute: the others keep hearing it and it them (the extension still
   sends; their lists keep it while its audio comes), and nobody's `not_here` climbs.
3. While the desktop can't reach the Mac (as at 19:14 today: Tailscale `rx 0`), the Mac's Health shows the desktop by its status file only;
   that's a Tailscale path problem (no audio can flow either way), not the room's list.

## Not done / limits

- A computer neither side lists (both statuses old at the other) still waits for a status file or heartbeat: no audio flows to add from.
- A sender in hub mode tells a peer "through the hub" and keeps sending it 'M' every 0.25 s, so it stays heard; one that talks back to
  someone else only (talkback) sends a peer nothing and drops off after 15 s, as before this change.
- The desktop <-> Mac Tailscale path (`rx 0`) is outside StudioSync.

## Review-later (security)

- Adding a peer on evidence: the datagrams pass the studio tag (only a computer with the studio secret makes them) and the address maps,
  through this computer's own Tailscale, to a devices file its computer wrote and a guest list that has the song. A studio computer with
  the secret could make itself heard in a room it isn't in for 15 s at a time, which it could already do by writing a status file there.
- `not_here_peers` is bounded (16 entries, oldest replaced), filled only after the tag check, status only.
