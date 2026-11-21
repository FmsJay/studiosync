# rt-hop2: the Hop plug-in's known faults (Hop 0.2.1)

Backlog section 1: "Hops: a note-off lost twice hangs a note until the try stops; Print's first 0.5 s is dry when the selection starts at 0;
only the first 256 knobs; switching tabs on the owner's computer drops the try." and "Two hops at once on one internet link lost more".
Offline and CI only: native tests, Lua tests with the stand-in REAPER. **Nothing was run in REAPER.** The extension (`extension/`) is
unchanged; the Hop plug-in goes to 0.2.1 (needs a plug-in build: James builds and installs).

| Item | Status |
| --- | --- |
| 1. A note-off lost twice hangs a note | Fixed in the plug-in (0.2.1): held-note and pedal snapshots, a bound under any loss, tested |
| 2. Print's first 0.5 s dry at 0 | Cause found; not fixable without REAPER behaviour I can't check offline. Print now says so when it happens |
| 3. Switching tabs on the owner's computer | Not fixed: it's REAPER not running a background tab's audio (to check); what to check and the fix below |
| 4. Only the first 256 knobs | Not raised: the knob list is one direct-link message, and 512 can pass its 64 KB cap. What raising takes, below |
| 5. Two hops lost more | Nothing clearly wrong in my files; the likely cause is the link's capacity for two raw-PCM streams. Below |

## 1. No hung notes (plug-in 0.2.1, `plugin/hop_core.h`)

Why it hung: the network leg sends each MIDI event in its own packet, again in the next packet's window, and once more 20 ms on. A note-off
that's the last event for a while (a note let go, then a pause) and loses both copies is never sent again, so the remote instrument holds it
until the try stops.

What it does now, all in the plug-in (the same binary is the sender and the remote's Hop X, so the extension needed no change):
- **The sending Hop** adds a snapshot of what its MIDI holds to its MIDI, every 50 ms and in any block where a note or a pedal changed: per
  channel, each 5-note group that has a note held or let go in the last 0.4 s (which of its notes are held), and each held controller that is
  off its rest value or changed in the last 0.4 s. Snapshot messages are ordinary 3-byte short messages with the undefined statuses 0xF4
  (notes) and 0xF5 (controllers), every data byte 7-bit, so the network leg numbers and repeats them like any MIDI. Incoming 0xF4/0xF5 from
  the host are dropped (undefined in MIDI anyway). Nothing is added while nothing is held or recently let go.
- **Hop X** (the remote's first Hop, which plays network MIDI to the instrument) keeps track of what it has left sounding and set. A snapshot
  lets go (note-off) of every note it has sounding that the snapshot says isn't held, and puts each controller to the snapshot's value. Once it
  has had one snapshot, if 200 ms pass with no newer one while anything is sounding or off rest, it lets go of all of it (note-offs, pedals up,
  bend centred). A note-on or controller set arriving more than 200 ms late is dropped: it would sound after the snapshots that could undo it.
  X never plays a snapshot message itself.
- **Covered:** notes on all 16 channels (note-off, note-on velocity 0, CC120/CC123 all off), pitch bend (put back as its MSB with LSB 0, so
  centre is exact), mod wheel CC1, sustain CC64, sostenuto CC66, soft CC67, hold 2 CC69, channel pressure; CC121 resets them. **Not covered:**
  poly aftertouch, other controllers (expression CC11, breath CC2, NRPN/RPN), program changes: a lost last value of those stays until the next
  change, as before. Notes lost on the way in (a lost note-on) stay lost: nothing starts a note late.
- **The bound** (HOLD_S = 0.2 s, RECENT_S = 0.4 s): under **any** loss pattern, including any single burst of any length, a note X sounds
  stops at most 200 ms + one host block after the later of its note-off at the sender and the moment X started it; the listed controllers come
  back as fast. Why: let f be the note-off. If X processes a snapshot dated after f within 200 ms of its previous one, that snapshot is dated
  before f + 0.4 s, so the sender still lists the note's group and it's let go; if not, the 200 ms timer has fired by f + 200 ms. (RECENT_S has
  to stay above HOLD_S plus a block for this.) The tests check 250 ms (the bound plus a block each side and the wire's jitter).
- **Arming:** X lets go on silence only after its first snapshot, so a 0.2.0 sender's MIDI plays exactly as before. A 0.2.1 sender sends a
  snapshot in the same block as its first note, in the same datagram unless more than 32 MIDI events were made in one millisecond.
- **Held notes aren't cut early** unless every datagram carrying a snapshot is lost for 200 ms: about 4 snapshots, each sent at least twice
  (and again in later datagrams' windows), so 8+ in a row. With 10% of MIDI datagrams lost at random, none was.
- **Cost:** while notes are held, roughly 40 extra MIDI datagrams a second (up to 548 bytes each), about 0.2 Mbit/s against the hop's
  3.1 Mbit/s of audio; nothing when nothing is held.

### Tests
- `tests/hop_test.cpp` section 13 (deterministic, a sending core and an X core with a "network" handing over each event once or losing it):
  a lost note-off is let go by its block's snapshot; lost with that snapshot (lost twice), by the next periodic one; everything lost from a
  frame on (a burst), let go 200 ms after the last snapshot, once; a note held 0.6 s with nothing lost isn't let go early and its note-off
  lands exactly; a lost pedal up and a lost bend back to centre come back by the next snapshot; with no snapshots (an older sender) X plays only
  what it gets; a note-on 200 ms late isn't played, a late note-off is. Section 11 now expects the snapshot after the note.
- `tests/hopnet_test.cpp` (two endpoints on localhost through the lossy wire, a MIDI plan: script, a filter on MIDI datagrams, and a remote
  instrument that records what X sounds): **a note-off lost twice** (its first two datagrams), **a note-off lost every time it's sent**,
  **chords and the pedal with 10% of MIDI datagrams lost**, **chords and the pedal with every MIDI datagram lost for 0.6 s**. Checks: nothing
  stuck, every note let go within 250 ms of its note-off, the pedal up within 250 ms, no snapshot played by X, and with random loss no note cut
  early (by over 50 ms). The fake instrument's click now sounds only on note-ons (X can now send note-offs).
- Run on this desktop (an export in my scratch folder, MSVC through the build scripts): `hop_test: ok`; `hopnet_test`: all pass (lost twice:
  let go 27 ms after its note-off; lost every time: 187 ms; 10% loss: worst 13 ms, none cut early; 0.6 s burst: worst 187 ms).
  **The same hopnet_test against HEAD's 0.2.0 core fails 4 checks:** lost twice and lost every time: stuck, 1461 ms to the end of the run;
  the burst: 565 ms (late note-ons from before the burst played after it).
- `plugin/build_windows.cmd` in the export builds the VST3 and CLAP (not committed).

## Versions: a mixed room
- 0.2.1 is set in `plugin/HopPlugin.cpp` (`getVersion`, d_version(0, 2, 1)). The mapping is unchanged (hop_shm.h version 2), so a 0.2.1 Hop
  pairs with the same extension as 0.2.0, and no Lua checks the Hop's version (it reads the Latency budget's range for the pre-0.2.0 limit).
- **Sender 0.2.1, owner 0.2.0:** works as before; the owner's old Hop X passes the 0xF4/0xF5 snapshot messages on to the instrument. They're
  undefined system-common statuses with 7-bit data, which instruments ignore (to check in REAPER, below). No hung-note protection.
- **Sender 0.2.0, owner 0.2.1:** no snapshots, so X never arms: MIDI plays exactly as before (apart from a note-on more than 200 ms late now
  being dropped). No hung-note protection.
- **Both 0.2.1:** protected. Each computer's own Hops (Offload, Run plug-in on a bandmate) are unaffected: they carry no MIDI.

## 2. Print's first half second at 0 (`lib/hoptry.lua`)
Why: at a play start REAPER processes the Hop's whole latency at once (its delay compensation lining up; 12 late blocks at each play start in
REAPER, 2026-11-19). Those frames all leave at that instant, and the returned audio for the project's first moments is needed sooner than a
round trip (plus the remote's margin and the extension's catch-up) can bring it back, so the Hop plays its input there (dry when late). Print
plays from 2 s before the selection so that happens before it; a selection under 2 s from the start gets only that much lead-in, and at 0
none. No Hop change can help (the audio for time 0 only exists once REAPER renders it, at the play start), so the fix needs a lead-in REAPER
must provide, which I can't check offline. Done: Print still prints, and logs, when the selection starts under 1 s in, that about the first
half second will be dry and to start it at 1 s or later (tested in `tests/test_0_60_rt_hoptry.lua`).
The fix, once checked in REAPER (one of):
- **Pre-roll:** if REAPER plays before 0 for its record pre-roll (Options > "Pre-roll before recording", action 41819, with the metronome
  settings' pre-roll length), Print turns it on for the print (and back after) when the selection starts under PRINT_LEAD.
- **Loop:** with repeat on, loop points [0, end + tail] and time-selection auto-punch, the second pass comes in warm (no play start at the
  wrap); keep the second pass's take and stop after it.

## 3. Switching tabs on the owner's computer
What the code does: Live sync is bound to its own project tab; the hidden track is in that tab; `hops.tick` does nothing while another tab is
in front (no knob updates to the requester, no idle drop), and nothing in Lua deletes or rebuilds the hidden track on a tab switch (a later
ask finds the track and only refreshes it: "the next ask rebuilds it" in rt-hopvst.md isn't what the code does). So the drop is almost
certainly REAPER not processing a background tab: Hop X and Y stop, the extension's serving end stops saying "alive", the requester stops
streaming and plays its fallback (dry), and Health there says "the hidden track there isn't running". Not fixed: whether REAPER keeps a
background tab running (and how to ask it to) is REAPER behaviour I can't check offline. Fixes, once checked:
- If REAPER can run background projects (a preference, or a per-project/tab option), the owner turns it on, and Health on the owner says so
  when a try is being served from a tab that isn't in front.
- Otherwise the hidden track follows the tab in front: drop it in the old tab and build it in the new one (the tried plug-in reloads; its knobs
  come back from the requester's last values). More code and a reload click each switch.

## 4. Only the first 256 knobs
What it costs: a plug-in's knobs past the 256th can't be seen or turned from the requester's Try tab (the owner's own window still has them).
Effects and small synths mostly fit; big synths and samplers commonly have several hundred to thousands of parameters, and JUCE-made VST3s add
MIDI-CC proxy parameters after their own. What raising takes: the whole list goes as one direct-link message once a second while it changes
(~50-100 bytes a knob: up to 48 characters of name and 24 of value text, plus JSON escapes), and the direct link caps a message at 64 KB, so
512 knobs can already pass the cap with long names, and a list over it doesn't arrive at all. Raising it safely needs pages (the owner sends
256 at a time with an offset, the requester merges them by index; an older requester would show only the last page) or only the knobs that
changed. Not cheap and safe as a constant change, so left at 256.

## 5. Two hops at once lost more
What two hops share: one UDP socket (live audio's; 1 MB receive buffer, so not overflowing there), one extension thread that steps every hop
under one lock every 1 ms, and the same peer. They share no redundancy budget (audio has none; MIDI repeats per event) and nothing in Lua
(margins and budgets are per hop). Each hop is raw float PCM, 3.1 Mbit/s each way (about 3.4 with Tailscale's overhead), sent unpaced: every
poll sends all the frames published since the last one back to back, and both Hops publish in the same REAPER audio block, so two hops make
bursts twice the size at the same instants and twice the rate (~6.8 Mbit/s each way). On an internet link with a few Mbit/s of upload or a
small queue that's the likely cause of the extra loss. Nothing is clearly wrong in my files; the fixes are in the extension (pace a hop's
packets across the block, send the hops to one peer as one stream, or compress losslessly). To check: Health's lost % with one hop and with
two, and the link's upload speed.

## Files
- Changed: `plugin/hop_core.h` (held MIDI), `plugin/HopPlugin.cpp` (0.2.1), `tests/hop_test.cpp`, `tests/hopnet_test.cpp`,
  `lib/hoptry.lua` (Print's note), `tests/test_0_60_rt_hoptry.lua`, this file. CI already runs both native tests (`plugin.yml`: hop_test on
  `plugin/**`; `extension.yml`: hopnet_test on `plugin/hop_core.h` and `tests/hopnet_test.cpp`), so no workflow change.

## Check in REAPER (two computers, after installing Hop 0.2.1 on both and restarting REAPER)
1. The Hop's version reads 0.2.1 in REAPER's FX browser / plug-in info.
2. Desktop tries a laptop-only instrument on a MIDI track (Try tab, Allow on the laptop). Hold a key (or a long MIDI note), and while it's
   held set the desktop's Hop offline (FX chain: right-click > Offline): on the laptop the note stops within about 0.2 s (it used to ring until
   the try stopped). Same with the sustain pedal held down: it lets go. Online again: new notes play.
3. Play a fast staccato part for a few minutes on the internet link: no note hangs (watch the laptop's instrument meter go quiet in each gap).
4. Hold a chord for 10 s with nothing lost: it isn't cut (snapshots keep it).
5. Mixed room: laptop with the old 0.2.0 Hop, desktop 0.2.1: the instrument plays normally, with no odd sounds or stuck notes from the
   undefined 0xF4/0xF5 messages it now receives. Then the other way round.
6. Print with a time selection at 0: the log says the first half second will be dry, and it is; at 2 s: no message, wet throughout. For the
   fix: does REAPER play before 0 with "Pre-roll before recording" on at position 0, and are FX processed during it?
7. Tab switch: while the desktop tries a laptop plug-in, switch the laptop to another project tab. Note what the desktop hears and its Health
   row, and whether it comes back on switching back. Then look for REAPER's option to run background projects, turn it on, and repeat.
8. Two hops at once: Health's lost % with one hop, then two, for a minute each, and the upload speed of both ends.

## Review later (security)
- The 0xF4/0xF5 snapshot messages come over the hop's MIDI, which is HMAC-tagged with the studio secret: anyone who can already send a hop
  MIDI can also make Hop X send note-offs and set the seven covered controllers (nothing more: no note-on, no other message). The work per
  received message is bounded (at most 5 note-offs, or one controller), and a let-go is bounded by the out buffer (the rest the next block).
- Everything read from the mapping is masked or clamped as before; the sample rate used for the 50/200/400 ms windows is taken from the
  mapping only between 8 kHz and 768 kHz (48 kHz otherwise).
- X now drops a note-on more than 200 ms late; it never starts anything on its own.

# Round 2 (rt-p4, backlog package P4: items 1.17 and 1.18)

Offline, native and headless only: **nothing was run in REAPER or on the test computers.** Changed: `extension/hopnet.cpp` (needs an
extension release; the coordinator bumps EXT_VERSION), `lib/hops.lua`, `lib/hoptry.lua`, `lib/webui/tryfx.js`, `tests/hopnet_test.cpp`,
`tests/test_0_60_rt_hoptry.lua`. The Hop plug-in is unchanged (stays 0.2.1, no plug-in build needed for this round).

| Item | Status |
| --- | --- |
| 4. Only the first 256 knobs | Fixed: pages of 256, up to 4,096 knobs; the Try tab pages through them and its filter looks through all |
| 2. Print's first 0.5 s dry at 0 | Built, REAPER-dependent: a print without room for its lead-in records with REAPER's pre-roll on (put back after), and checks afterwards whether playback really went back far enough; says so if not |
| 3. Switching tabs on the owner's computer | Built, REAPER-dependent: hosting goes on behind another tab (it used to stop following), and while hosting, REAPER's two "Run background projects" options are on (put back after) |
| 5. Two hops at once lost more | Fixed in the extension: two or more hops to one computer are paced across the block, both ways. Test: 47.7% lost before, 0% after |

## 4. Knobs in pages (`lib/hoptry.lua`, `lib/hops.lua`, `lib/webui/tryfx.js`)
- **The owner** (`hoptry.host_params`, once a second): reads every knob's value (up to `PARAM_MAX` = 4,096; a JUCE VST3's 2,048 MIDI-CC
  proxies after its own still fit). A page of 256 goes when one of its values changed, when it's its turn (one page a second in rotation, so
  each is sent again every `PARAMS_AGAIN` s or every `pages` s, whichever is longer), or when it was never sent; names and value texts are
  read only for a page that goes. At most `PAGES_EVERY` = 4 pages a tick (~25 KB each; the direct link caps a message at 64 KB), the rest at
  the next tick.
- **On the wire:** page 0 is the old `"params"` message (plus `off = 0`), so an **older requester** shows the first 256 exactly as before;
  pages 1+ go as a new op `"page"` with `off`, which an older StudioSync ignores (its `hops.on_msg` routed only params/set). An **older
  owner** sends only page 0: the new requester shows 256, as before.
- **The requester** (`hoptry.on_msg`): a page is taken only at a multiple of 256 under 4,096, and only its own indexes (`clean_params(list,
  off)`: at most 256, values clamped 0..1, texts clipped); pages are merged by index into one list (in any order; page 0 says how many knobs
  there are and drops pages past that). `set_param` works on any index the owner has (the owner checks `p < NumParams`).
- **The Try tab:** one page at a time (`{knobs = {id, page}}`: "Earlier knobs" / "Later knobs", "Knobs 257-512 of 600") or, with a filter
  typed, the first 256 knobs of all pages whose name has it (`{knobs = {id, q}}`, sent 300 ms after typing; the rows on screen are hidden at
  once as before). Past 4,096: "The first 4096 of its N knobs come here; the rest only in its own window there." The topic still carries one
  page of knobs, so it stays the size it was.
- **Cost:** the owner reads up to 4,096 normalized values a second on REAPER's thread (cheap calls; not measured in REAPER). A knob's value
  text that changes without its value (rare) shows up to `pages` s late on pages other than the one in turn.

## 2. Print's lead-in (`lib/hoptry.lua`)
- A selection starting under `PRINT_LEAD` (2 s) can't have the 2 s lead-in (the edit cursor goes to 0). Print now turns on REAPER's
  **Pre-roll: Toggle pre-roll on record** (action 41819, checked in this drive's REAPER action list) for the print when it's off, and turns
  it off again when the print ends. With pre-roll, REAPER plays from `prerollmeas` measures before the cursor (1 measure in this REAPER's ini).
- Whether REAPER plays **before 0** in its pre-roll is the one REAPER fact this rests on, so Print doesn't assume it: `print_tick` keeps the
  lowest play position it saw (every half second while it runs), and after the print, if playback didn't start at least `PRINT_WARM` (1 s)
  before the selection, it logs "the print's lead-in was only N s ... about the first half second of the print may be the dry track. Start
  the selection at 2 s or later, or set a longer pre-roll". The old up-front warning is gone (it was right only without pre-roll).
- If the REAPER check shows pre-roll doesn't play before 0, the fallback is the loop design in item 2 above (not built).

## 3. Switching tabs on the owner's computer (`lib/hops.lua`)
- `hops.tick` no longer returns when Live sync's tab isn't in front: the **hosting** part (knobs to the requester, the song's knobs to an
  offload's copies, the idle drop, leftover hidden tracks) runs behind another tab too; this computer's **own** hops still wait for its tab
  to be in front, as before. (REAPER's whatsnew: "support background projects for GetTrackGUID(), GetTrackInfo(), DeleteTrack()".)
- `hops.run_background`: while this computer hosts a hop, REAPER's **Project tabs: Run background projects** (40871) and **Run stopped
  background projects** (40873) are on; each one StudioSync turned on goes back off the tick after the last hosted hop ends, and when Live
  sync stops. One that was already on is left alone. Said once in the log. They're REAPER's own global options (reaper.ini), so a crash while
  hosting leaves them on (review-later list).
- Not built: the hidden track following the tab in front (rebuilt in the new tab). Only needed if the REAPER check shows the two options
  don't keep a background tab's FX running.

## 5. Two hops paced (`extension/hopnet.cpp`)
- With two or more hops streaming to the same computer (sending end: same address, active; serving end: same requester address, a packet in
  the last second), each hop's frames go out at `PACE` = 1.5 x real time from the first packet of its block, instead of everything published
  since the last 1 ms poll at once: a 512-frame block (4 datagrams) over ~5.3 ms at 48 kHz. The credit builds only while frames wait, so a
  quiet spell between blocks banks nothing but the first packet. Never more than one block behind: a play start's whole-latency burst still
  goes at once (those frames can't be back in time anyway). The returns from the remote are paced the same way. **A lone hop is unchanged.**
- **Cost:** the last datagram of a block waits up to (block - 128) / 1.5 frames (5.3 ms at 512, 13 ms at 1024); that's added to the sender's
  `need_ms` (and the remote's part in its pong), so Health and the long-link budget account for it. A MIDI event goes once its frame has.
- Status: `"paced": true/false` in both roles' net JSON. The wire format is unchanged, so either end can be an older extension.

## Tests (each fails with its change removed)
- `tests/hopnet_test.cpp`: **two hops at once** through a link of 8 Mbit/s each way with a drop-tail queue of 6 datagrams (two hops are
  6.4 Mbit/s), both Hops in the same 512-frame block: paced, both hops lost 0 frames, every frame exact once up, no datagram dropped by the
  queue. **Against HEAD's hopnet.cpp: hop 1 lost 47.7% (529 datagrams dropped by the queue), 4 checks fail.** Also: a lone hop reports
  `paced:false` both ways. All the old scenarios pass unchanged (this desktop, 1 ms timers). On coarse timers (a hosted Mac) the loss checks
  are reported and passed over, as the other timing checks are.
- `tests/test_0_60_rt_hoptry.lua`: pages (clean_params by offset, `knob_view`); 600 knobs go as params + 2 pages, each under 64 KB, merged
  in any order, odd and too-far offsets ignored; the model's page, Later, never past the last, the filter through every page, at most a page
  of matches; a knob past 256 turned and only its page sent again; 1,100 knobs: four pages, the fifth at the next tick; back to 3 knobs drops
  the old pages; behind another tab the knobs still go; hosting turns 40871/40873 on; Print at 0.4 s turns pre-roll on and back off, no
  warning when playback went before 0, the lead-in warning when it didn't, pre-roll already on is left on. Mutations checked one at a time
  (the front-tab return put back, the `"page"` routing removed, the pre-roll removed): each fails its assertion. Against HEAD's hops.lua or
  hoptry.lua the test fails too.
- Headless Chrome (no media devices) against a stand-in `ssTabs` around the real `tryfx.js`: 256 rows, "Knobs 1-256 of 600",
  Earlier/Later state and their action, page 2's rows replace page 1's, a knob on page 3 sends its own index, the filter's action after
  300 ms, one match with no paging, three knobs with no nav, the "first 4096" note. With HEAD's tryfx.js it fails.
- `python tests/run.py --no-luals` in a clean clone of HEAD (cc86dcc) plus these files: **fails 0**.
- Builds, to scratch copies only (no tracked binary touched): `extension\build_windows.cmd` with `DLL_OUT=rtp4_studiosync-x64.dll` links;
  `plugin\build_windows.cmd` builds the VST3 and CLAP.

## Check in REAPER, round 2 (after the extension release with this hopnet.cpp, on both computers; Hop 0.2.1 as before)

**Allow without a click.** A try needs the owner's yes. Instead of Allow on the laptop's screen, the laptop's own web UI takes it from the
laptop itself (a request from 127.0.0.1 needs no token, only the header the page sends). From the desktop, `ssh laptop`, then in its
PowerShell (47281 is the direct link's port; use the studio's if it was changed):

    $u = 'http://127.0.0.1:47281/api'; $h = @{ 'X-StudioSync' = '1' }
    Invoke-RestMethod -Method Post -Uri "$u/action" -Headers $h -ContentType 'application/json' -Body '{"topic":"tryfx","want":true}'
    Start-Sleep 2; (Invoke-RestMethod "$u/state").topics.tryfx.asks          # each ask: token, user, key
    Invoke-RestMethod -Method Post -Uri "$u/action" -Headers $h -ContentType 'application/json' -Body ('{"topic":"tryfx","allow":' + $TOKEN + '}')

The ask must still be pending (the requester asks every 3 s; an ask lapses 30 s after its last). If that route can't be used, James clicks
**Allow for this session** on the laptop: Settings > Health, the row "<name> asks to try your <plug-in> on this computer"; or the web UI's
Try tab > Your plug-ins > **Allow**.

1. **Knob pages.** Desktop tries a laptop-only plug-in with more than 256 parameters (a big synth; the Try tab says "Knobs 1-256 of N").
   Later knobs shows 257-512; turn knob 300 on the desktop: the laptop's plug-in moves. Type part of a name that's past 256 in the filter:
   it's listed. Turn a knob past 256 in the plug-in's own window on the laptop: the desktop's value follows within ~2 s. Live sync's
   `start/hops` sub-lap on the laptop with the try running stays under ~2 ms.
2. **Print at 0.** On the desktop, a try running, a time selection 0-4 s, Print. Log: "with REAPER's pre-roll". Note whether playback
   started before 0 (negative time on the timeline) and that pre-roll is off again after. Listen to the print's first second (or compare it
   with `ears.py wav` against a render of the dry track): wet from 0 means pre-roll plays before 0. If the log says "the print's lead-in was
   only ...", REAPER didn't play before 0: report it (the loop design is next).
3. **Tab switch.** While the desktop tries a laptop plug-in: the laptop logs "hosting a hop: REAPER now runs project tabs that aren't in
   front", and `reaper.GetToggleCommandState(40871)` and `(40873)` read 1 there. Bring another project tab to the front on the laptop
   (`reaper.SelectProjectInstance` through the dev-eval hook; no click), stopped and then playing: the desktop keeps hearing the plug-in and
   its Health row stays green; turn a knob on the desktop: the laptop's plug-in follows. Stop the try: within a second both options read
   what they did before.
4. **Two hops paced.** Two tries (or a try and an offload) from the desktop to the laptop at once over the internet link: both hops' net
   JSON (`StudioSync_HopStatus`) says `"paced":true`; Health's lost % for each over a minute, against round 1's one-hop figure. One hop
   alone: `"paced":false` and the same lost % as before. Note each REAPER's block size (pacing costs up to a block / 1.5 in `need_ms`).
5. **Note tails (ears).** As rt-ears.md "Left": on the desktop `track add=true note=60 instrument=<the try's track> capture=true`, `note
   frames=144000 off=48000`, `capread`, then `python tools/ears/ears.py tail GOT.wav --on 1 --off 3`: passes (the tail ends within release +
   200 ms + a block). Then the lost note-off: set the desktop's Hop offline while the note is held, and capture on the laptop's hidden track.

## Review later (security), round 2
- A `"page"` message is bounded like `"params"`: its offset a multiple of 256 under 4,096, at most 256 entries, only indexes in its page,
  texts clipped; at most 16 pages a try. It's taken only for a try this computer made, over the direct link (signed).
- `{knobs = {id, page, q}}` from the web page: the id must be a try in this project, the page is clamped, the filter clipped to 48 bytes.
- Hosting turns on two REAPER-wide options and puts back only what it turned on; a crash or REAPER killed mid-hosting leaves them on. They
  make every background tab run, not only Live sync's.
- Pacing changes only when datagrams go, never what goes or to whom.

## Left
- The REAPER facts items 2 and 3 rest on (pre-roll playing before 0; the two options keeping a background tab's FX running) are unchecked;
  each has a fallback design above, not built.
- A lone hop with big blocks (1,024+) still sends each block at once (unchanged on purpose: one hop measured fine).
- `tryfx.css` (not in P4's files) has no style for the new `.tfnav` row: it wraps as plain buttons.
- No `tools/ears` run offline: the native held-MIDI checks (round 1) already measure each note-off at Hop X exactly; ears' `tail` belongs to
  the REAPER check (step 5), where it measures the real instrument's sound.
