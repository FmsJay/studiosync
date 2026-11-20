# MIDI on the phone and in the browser: on-screen keys, drum pads, Web MIDI (rt-vmidi, 2026-11-20)

James asked for "midi compatability on mobile/browser - virtual midi input as well with virtual keyboard or drum pad". Built and tried in
headless Chromium (fake media devices, a fake Web MIDI input) against a stand-in server that runs the real `lib/livekeys.lua`, plus Lua tests.
Not yet on a real phone, with a real controller, or in REAPER.

## What it does

**The instrument** (`lib/webui/vkeys.js`, `vkeys.css`). One component, used in two places:
- **Keys**: white keys fill the width from the octave's C (about 8 on a phone held upright, 30+ on a desktop), `‹ ›` shift the octave.
  Several fingers play a chord; a finger sliding along the keys plays each key it reaches (the last one stops).
- **Pads**: 4x4, General MIDI drums from the bottom left (Kick, Snare, Hat, Open hat / Side stick, Clap, Pedal hat, Crash / toms, Ride /
  Floor tom, Bell, Splash, Cowbell), on channel 10. **Edit pads**, then tap a pad to give it any note; **GM pads** puts them back. Saved per
  browser.
- **Velocity**: where you touch (lower on a key or pad is louder, 25-127), or a pen's / screen's real pressure where the browser reports
  one (most phones report a fixed value, so position is the fallback), or fixed (a number).
- **Sustain**: tap to latch (tap again to release), or hold it to sustain only while held. Space holds it on a computer.
- **The computer's keys** (desktop): A W S E D F T G Y H U J K O L P ; play from the octave's C, Z/X shift the octave; on the pads, 1-4,
  Q-R, A-F, Z-V. Ignored while typing in a box. In the docked web UI the keys are taken before they'd be forwarded to REAPER.
- **Hear it here**: a small Web Audio sound on the device (a soft triangle for keys, simple synthetic drums on channel 10), so it's playable
  offline. Turned off by itself when Live into REAPER goes on (REAPER's sound instead); the box turns it back on.
- **Touch**: pointer events with capture, `touch-action: none`, no text selection or long-press menu, `preventDefault` on the touch: no
  300 ms delay, no scrolling, no zooming while playing.
- **MIDI controllers** (`VKeys.midiIn`): every Web MIDI input (Chrome, Edge, Android Chrome; not Safari / iPhone), joined as they're
  plugged in; channel messages only. Their notes light the on-screen keys.

**Where the notes go**
1. **A MIDI take on the phone** (Play view: Record a MIDI take). record.js's existing MIDI take: the Play view's on-screen notes reach it
   through `ssKeysBus`, a plugged-in controller through its own Web MIDI listener (as before). Along to the computer or to the mix on the
   phone (the Record view's settings: count-in, Start from), placed like an audio take (a position stamp from the phone's mix, or the link
   clock), kept in IndexedDB and sent when the computer answers with the project in front, put in as an ordinary MIDI item (phonerec.lua,
   unchanged). New: a MIDI take along to the phone with **no mix on the phone** records too, starting at "Start from" (0:00 if empty),
   timed by the phone's audio clock. "MIDI" on the Record view is now offered on every browser (the on-screen keys work everywhere).
2. **Live into REAPER** (Play view: pick a track, tick Live into REAPER). Each note goes at once as a link action
   `{ topic: "phonedaw", keys: { track, sid, on, ev: [[status, d1, d2, seq]], panic } }` (a chord's notes in one message) to
   `lib/livekeys.lua` through `lib/phonedaw.lua`'s action. There they go into REAPER's virtual MIDI keyboard queue (`StuffMIDIMessage(0, ...)`),
   and while a page plays a track that track is armed, monitored and its input set to the virtual keyboard (all channels): REAPER's own way
   of playing a track live (an unarmed track is rendered ahead, so it would sound up to the render-ahead time late). Arm, input and
   monitoring are local (mirror doesn't send them) and are put back as they were when the page stops, picks another track, goes quiet for 30 s,
   loses the room's say-so, the track is deleted, or Live sync stops, each only while it's still what livekeys set (a change made here
   meanwhile stays). Since the track is armed, REAPER recording at the time records the phone's notes into it, and live audio streams the
   track's sound to bandmates as any armed track's.
   - **Who may**: the track's rule as the Mixer page asks it (`dawedit.item_refusal`: the room's rule for the track's name, its maker's while
     unclaimed, Driver only); never this computer's own tracks (Real time, live views). Asked again every second while playing: a claim made
     meanwhile stops it (notes off, put back) and the page says why.
   - **Latency shown**: the topic `phonekeys` says the last sequence number applied; the page times the round trip (median of the last 9) and
     shows "N ms to the computer and back (you hear it about half that after a touch, plus REAPER's audio buffer)". Also which other armed
     tracks hear the virtual keyboard too (input: all MIDI or the virtual keyboard).
   - **Stuck notes**: livekeys remembers every held note and sustain per channel. All notes off (each held note's off, sustain up, CC 123 on
     each channel used) on: the page's panic (sent when the page hides, with `keepalive`), the page's off (Live unticked, pagehide), 3 s of
     quiet with notes held (the page says "still here" every second while live and visible), a refusal, a track change, a new page id
     (reload), the track deleted, and Live sync's exit (atexit). On the page: hidden or the link dropping releases everything it holds.
   - **Order**: notes are sent as played, so two can overtake each other; each carries the page's sequence number and one older than the last
     applied for the same note / controller / bend is dropped (an off that overtook its on keeps the note off).
3. **The piano roll, as step input** (Project page, piano roll: Step input). The keys (or pads) open under the notes, with Back and Rest.
   Each note played (on-screen, the computer's keys or a controller) goes in at the dashed step cursor, a grid step long, at the velocity
   played; notes held together go in at one place, and the cursor moves on a step when all are let go. It starts at the edit cursor (inside
   the item) or the item's start. Each note is the piano roll's ordinary add (`dawmidi.lua`: the same checks, one undo point each), drawn
   faint until it's back. vkeys.js/css load the first time Step input opens; the step keys keep their own settings (`ss-vkp-*`).

**The phone app**: a fourth view, **Play** (record.html), beside Record, Project and Sheet. The service worker keeps vkeys.js/css
(`ss-phone-3`).

## Files
- New: `lib/livekeys.lua`, `lib/webui/vkeys.js`, `lib/webui/vkeys.css`, `tests/test_0_60_rt_vmidi.lua`, this file.
- Mine for this task: `lib/phonedaw.lua` (routes `keys`), `lib/webui/phonedaw.js` / `phonedaw.css` (the Play view), `lib/webui/record.html`,
  `lib/webui/record.js` (ssKeysBus, MIDI without Web MIDI or a mix), `lib/webui/phone-sw.js`, `lib/webui/pianoroll.js` (step input).
- Shared, one line each: `lib/webui.lua` (`require("livekeys").tick(...)` in webui.tick before the "nobody looking" return, so a page that went
  away is still let go), `StudioSync - Live sync.lua` (atexit: `livekeys.on_exit`).

## Tests
- `tests/test_0_60_rt_vmidi.lua`: parsing and limits, the order guard, held notes and their release, the track armed and put back (only
  what's still ours; an armed track stays armed), the room's rule over the real `sync.authority` (claims, a claim made while playing, Driver
  only, this computer's own track), quiet / idle / exit / deleted track / reload, the topic, and a link check of the pages' hooks.
- Chromium (headless, fake devices, a fake Web MIDI input injected before the page), against a stand-in server running the real
  livekeys.lua over a fake REAPER: Play view on a 412 px phone: two fingers then a slide played C4+F4, then D4, live into the fake REAPER in
  order with position velocities, the track armed on the virtual keyboard and put back on Live off; the round trip shown; pads (GM labels),
  a controller's note lit and played live; sustain latch; page hidden: sustain up, panic, CC 123; a MIDI take recorded from pads and the
  controller along to the phone with no mix (a Standard MIDI File with the three hits, placed at 0:10). Project page piano roll on desktop:
  Step input from a controller (a chord at the cursor, one step), the computer's keys, Rest, Back, mouse on the step keys with position
  velocity, the adds sent with the project grid.

## Not done / limits
- One track at a time per computer (the virtual keyboard is one bus): a second page or track takes over and the first stops. Per-page
  channels would let two phones play two tracks.
- Other armed tracks whose input is "All MIDI inputs" or the virtual keyboard also hear the phone (said on the page).
- Latency is the network plus Live sync's tick (it applies actions once per defer cycle, ~30 ms) plus REAPER's buffer; no timestamps are used
  to schedule notes in REAPER (they land as they arrive). Touch-to-sound on the phone itself (Hear it here) is the browser's output latency.
- Live notes aren't recorded on the phone unless Record a MIDI take is running; REAPER records them only if it's recording.
- Pad velocity uses the same "lower is louder" rule as keys; no aftertouch, pitch bend or mod wheel on screen (a controller's go through).
- Step input: no undo grouping (one undo point per note), no tied / dotted lengths, notes past the item's end are refused, not extended.
- Edit pads uses the browser's prompt box.
- Program changes and system messages from controllers are not sent live (dropped by livekeys).

## Check in REAPER (on the real computers)
1. Phone app, Play view, a track with an instrument: tick Live into REAPER: the track arms, monitoring on, input "Virtual MIDI keyboard /
   All channels"; play: the instrument sounds; the round trip shows. Untick: arm, input and monitoring back as they were.
2. Hold a key, lock the phone (or switch apps): the note stops within ~3 s at most (at once if the page got its panic out). Hold a note and
   pull the network (Wi-Fi off): stops within 3 s. Stop Live sync mid-note: stops, track put back.
3. A track claimed by a bandmate: refused with their name; claim it while someone plays it: it stops within a second.
4. Sustain latch and hold on a piano, and pads on a drum instrument (GM map) on channel 10; Edit pads to a non-GM note.
5. A USB MIDI keyboard on Android Chrome: lights the keys, plays live, records into a phone MIDI take; check the take's place.
6. A MIDI take along to the phone with no mix: lands at "Start from".
7. Piano roll Step input with a 1/16 grid and a controller: chords, Rest, Back; each note one Ctrl+Z.
8. Desktop browser and the docked web UI: computer keys play (and aren't forwarded to REAPER while the keys show); Space sustains.
9. The tick cost while a phone plays fast (many notes a second) and the 64-action queue (`busy` answers mean notes were dropped).

## Review later (security)
- A page with the studio's token can arm a track it may edit and change its record input and monitoring on that computer (put back after),
  and sound its instrument there: the room's track rule is checked, but monitoring through speakers could be loud. Consider a per-room
  switch for live play.
- Notes from a page are limited to 64 per action and channel-voice messages only (no program change, SysEx or system messages); the action
  queue (64) bounds the rate. No per-page rate limit beyond that.
- `sid` is page-chosen; a second page can take over the track and release the first page's notes (by design; it can't play a track the
  room forbids).
