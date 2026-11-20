# rt-small: four small fixes (2026-11-20)

## 1. Live audio's clock: hold the drift correction for the first minutes (39da63f, a61f69c)

The audio clock's estimate (`clock_step`, `extension/rtaudio.cpp`) is the slope between minima kept over 10 minutes, and it needs most of
that window to settle: the desktop read -375 ppm at 3 minutes and -78 at 13, against -102 counted. AOO's drift correction used it from the
first 6 s.

- Now the rate the correction uses holds at the nominal until the minima cover `CLK_HOLD` = 120 s, then takes a linearly growing share of
  the estimate, all of it once the 10-minute window is full (598 s of minima).
- Status: `clock_ppm` stays the estimate; `clock_used_ppm` (new) is what the correction uses.
- `rt_test_drift(l, 2)`: the correction without the hold (the 16 s drift runs use it, so they prove the same correction as before).
  `rt_test_clock(..., &used)` gives the share used.
- Tests (`tests/rtaudio_test.cpp` clock_tests): 0 used at 2 minutes, part of the estimate at 5 (-38 of -102), all of it at 10.
- CI 44780868653 (Mac) failed "the buffer holds still" with the stalling drift run at 1e9: no measurement (under 6 burst onsets heard
  past 8 s), not a drift. That run is now tried up to 3 times; if none measured and SS_TIMING_STRICT is off it's reported and passed over.
  A measured slope over 0.06 ms/s always fails, and the +100/-100 run without stalls is checked on its own.

Untested: on the real computers. Uncorrected for the first 2 minutes, a link between clocks 200 ppm apart drifts up to ~24 ms before the
correction starts; the quiet re-buffer (TRIM_OVER) and the adaptive buffer cover that, as they did before the correction was turned on.

## 2. nat_test's "a message over 64 KB, over the link: refused (5)" (f469e6b)

The receiver answers 5 from the 12-byte header and closes; the test kept sending all 70 KB, so the close's reset could beat the answer
byte. `raw_answer` now takes `upto`, and this check sends only the frame's first 256 bytes. The answer must come from the header alone,
which also really checks "before it's read whole": a receiver that waited for the whole frame would time out and fail.

## 3. "Live audio: refused 13589 (last: not one of the studio's computers here from <laptop>:47281)" (f3b7eb3)

Found by read-only probes (`StudioSync_LiveAudioStatus`, `StudioSync_DirectStatus`/`DirectClock`/`NatStatus`):
- Live audio binds the direct link's port number (47281, UDP), so `<address>:47281` is that computer's live audio socket, not the direct
  link or the NAT signalling.
- The datagrams pass the studio tag (only a studio computer can make them) and fail `slot_of`: the receiver's own peer list leaves the
  sender out. On the laptop at that moment the live audio peers were the Mac and LinuxBox, not the desktop (and its DirectClock had no
  james-main entry), while the desktop listed the laptop and sent to it: 2,000+ refusals in ~30 s on the laptop, from the desktop.
- The peer list is Live sync's room (`direct.peers` -> `presence.peers`, `trust.device_ok`, `access.shows`), so this is one computer's view
  of who's in the room disagreeing with the other's: a status file older than 45 s there, another song or room, a list being changed, or
  the names still resolving right after start (the secret is set before the peers resolve, so a start refuses for a few seconds).

Fix: such datagrams are still dropped, but counted as `not_here` with `not_here_from` (new status fields), not as `rejected`. Health
(`lib/liveaudio.lua`) says "<address> sends here but isn't in this room here yet (its status may be old here), so it isn't heard" instead
of the refusal. It also means one-way audio: the sender hears this computer, this computer doesn't hear it.

Not done: why the laptop's room left the desktop out at that moment. The probes that would show it (the room's status files and
presence as the laptop sees them) were cut short (see "Probe mishap"). If Health keeps showing the new words for a bandmate that's
plainly in the room, look at that bandmate's status file age on the receiving computer and at `trust.device_ok` for its device.

## 4. Web UI: duplicate accessibility nodes for the chat chips (not reproduced, nothing changed)

Against a stand-in server (Live sync's presence, chat and chat_index topics) in the Claude Browser pane's Chromium, desktop width, plain
and `?host=docked`: there is one `nav.cconvs` and one copy of each chip (`.cchip`); no button appears twice visible-and-hidden except the
hidden pages' own (Play together, History). What the browser tools' tree does list twice:
- display:none elements: the hidden pages (Play together's "Who's here", Health, Sheet...), the chat's hidden To-do/Links/All lists (All
  repeats the messages), the group form once "+ Group" was opened;
- aria-hidden avatars (`span.av` with `title` = the name), next to the visible name.
Those tools walk the DOM and don't drop `hidden` or `aria-hidden` nodes, so markup alone won't change what they return. Real screen
readers already skip them. Needed to go further: the real page's state when find() returned the hidden copy (which tab, the ref's role
and name, and its parent).

## Probe mishap

My first probe called `reaper.StudioSync_HopStatus()` without its argument (inside pcall, but REAPER's own argument check showed a modal
"ReaScript Error"), which blocked both REAPERs until the orchestrator cleared them. Lesson: check each extension function's registration
for its arguments before calling it in a probe, not just pcall it.

## The REAPER checks to run

1. After installing the extension with these commits: Health's live audio row after a few minutes: `clock_used_ppm` 0 in the first
   2 minutes (`StudioSync_LiveAudioStatus`), then rising toward `clock_ppm`; no growth of underruns from drift in the first 10 minutes.
2. Open a room on two computers where one hasn't seen the other's status yet (or right after starting live audio): Health should show
   "... sends here but isn't in this room here yet ..." and no "refused" for it; `rejected` stays for real refusals (wrong secret).

## Review-later (security)

- `not_here` datagrams are dropped exactly where the refusal was (after the tag check), so nothing new reaches AOO. The counter and the
  last sender's address are status only.
