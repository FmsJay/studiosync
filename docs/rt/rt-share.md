# Screen share: REAPER's sound and "like your own timeline" (rt-share, 2026-11-20)

James asked: "screensharing should be able to capture reaper audio as well as system audio - for example if you wanted to share a song
you're working on but not putting in studiosync" and "screenshare when sharing reaper has ability to match your reaper window so you can
view in full screen like it's your own reaper timeline - can point at things, make notes for them etc as they go that they can turn on or
off". Built on step 5's first version (docs/realtime-roadmap.md, "Video and screen share"). **Tested offline only** (native test, Lua tests,
headless Chromium with fake devices and a stand-in screen); **not run in REAPER or between two computers yet.**

## What's built

### The share's sound
A picker in the Video section, **Share's sound: REAPER mix / System audio / No sound** (kept on this computer, REAPER mix by default), with
a level meter for what's being sent. It can change mid-share (REAPER mix and No sound at once; System audio has to be picked before the share
starts, because the browser only hands its audio over in its own picker). The sharing bar says what goes: "You're sharing your screen with
chilio, with REAPER mix."

- **REAPER mix:** REAPER's own output, the first output pair, taken in the extension's audio hook **before** live audio adds the bandmates
  you hear, so nobody hears themselves back through your share. The extension streams it to this computer's page only (`GET /api/mix`:
  raw 16-bit stereo at REAPER's rate, `X-Rate` header); the page plays it through an AudioWorklet (`lib/webui/sharemix.js`, a 60-250 ms
  jitter buffer) into a MediaStream track. Works whether live audio runs or not.
- **System audio:** `getDisplayMedia({ audio, systemAudio: 'include' })` with echo cancelling, noise suppression and levelling off
  (`restrictOwnAudio` where Chrome has it). Chrome on Windows gives it for a whole screen or a tab, not a single window: the page says so if
  none came. While live audio runs, the page warns that system audio carries the bandmates you hear (they'd hear themselves); REAPER mix
  doesn't.
- **On the watcher's side:** the sound plays from the share's picture, with its own volume slider and meter under the picture. If live audio
  runs on the watcher's computer, the sharer's live **Play** stream is muted there while the share's sound plays (Play is the armed
  tracks, which are in the sharer's mix already: no double sound, no flam). The sharer's **Talk** (their mic) stays, so they can talk over
  it. It comes back when the share's sound is set to No sound, the share ends, the page closes, or after 25 s without the page renewing it.
- **Quality:** a screen share's Opus is set to stereo up to 256 kbit/s on both sides (`musicSdp` in call.js); WebRTC's default is mono at
  voice rates.

**Why the WebRTC track and not live audio's path:** the share already has a peer connection, and audio on it stays in step with the picture
(WebRTC syncs them); live audio is ~100 ms ahead of the video, which would read as out of sync when pointing at a playing song. One path
carries REAPER mix and System audio alike, so the watcher has one volume, one meter and one switch, and the picker swaps tracks with
`replaceTrack` without a new offer. It needs no change to the AOO engine (a third stream per peer, its sinks, the hub's mix, NAT), works when
live audio is off or its UDP rule isn't set up, and reaches only the people watching. The cost is a small HTTP stream on loopback and a
worklet; live audio's jitter buffer is lower-latency, which doesn't matter for watching.

### Like your own timeline
- **Where the arrange view is:** while this computer shares, its page says `{topic:"rtc", t:"view"}` every 2 s; Live sync then publishes the
  `rtview` topic every 0.1 s (only when it changed): the arrange view's time range (`GetSet_ArrangeView2`), its rect on screen (the
  trackview, child id 1000, via JS_ReaScriptAPI, else SWS), REAPER's main window rect, the screen it's on (`my_getViewport`; not on macOS),
  and every shown track's place and height (`I_TCPY`, `I_TCPH`, up to 256, id = 8 characters of its GUID, name).
- **Where that is in the picture:** the sharer's page works out the arrange view's place in the shared picture (`cropOf`): for a window
  share, from REAPER's window rect (allowing Windows' invisible borders, ~7 px left/right/bottom, and a Mac's 2x pixels); for a screen
  share, from the screen's rect when its shape matches the picture. If the sizes don't agree (a window that isn't REAPER's, or REAPER moved
  between screens), there's no crop and notes fall back to the picture. It sends `{t:"view"}` over the call's data channel at most every
  100 ms when it changes.
- **Full screen:** a watcher's **Full screen: like your own REAPER** fills the screen with REAPER's arrange view only (cropped, scaled with
  its shape kept, letterboxed). Without a crop it's plain full screen.
- **Pointer and notes:** tools under the picture: **Point** (a named dot for 2.5 s), **Arrow**, **Circle** (drag), **Text** (click, type).
  Each is kept as time + track + place down the track, so it stays on the same bar of the same track when the sharer scrolls or zooms
  (outside the arrange view, or with no crop: as a place on the picture). The sharer can draw on their own preview too. Notes go to the
  sharer, who keeps them (100 at most, 40 per watcher), names the author from the connection (never from the note), and sends the list to
  every watcher; points are passed on to the other watchers. **Notes** (a tick, kept per computer) hides or shows them; **Clear mine**
  (watcher) / **Clear all** (sharer).
- **Save as comments:** a watcher's notes go to the project's chat as timeline comments, the phone app's form:
  `[0:15.0 Vox] (arrow) (on James's screen share)` or `[1:02.5 Bass] too loud here (on ...)`. The phone app's Project view and the chat
  read the place from the front.

## Files
- `extension/webui.cpp` / `webui.h` (additive): `GET /api/mix` (loopback only, never the link's port or a `tailscale serve` proxy; at most 4
  at once; 503 when REAPER's audio isn't running), `webui_mix_feed` (the audio thread's part: nothing unless a page streams), `webui_mix_wanted`.
- `extension/rtaudio.cpp` (**additive only**, exactly): `#include "webui.h"` (in the REAPER part, after SWELL's min/max `#undef`s); in `on_audio`'s post branch, `webui_mix_feed(out, nout, len,
  srate);` on the line before `rt_mix(...)`; a new `mix_timer` (REAPER's main thread) registered with `rec->Register("timer", ...)` at the end
  of `rtaudio_register`, which puts the audio hook in while a page streams REAPER's mix and takes it out again once none does and live audio
  isn't running; a `g_mix_down` flag set first thing in `rtaudio_shutdown` so the timer never puts the hook back while REAPER unloads.
  Nothing in the AOO engine, `api_start` / `api_stop` or `rt_mix` changed.
- `lib/liveaudio.lua` (**additive only**, exactly): `liveaudio.ducks = liveaudio.ducks or {}` (bandmate name -> until, `time_precise`), and
  in `liveaudio.apply` one line after `local pg = liveaudio.play_gain(...)`: `if (liveaudio.ducks[name] or -math.huge) > reaper.time_precise()
  then pg = 0 end`.
- `lib/webcall.lua`: `local_msg` ("view" and "duck" stay on this computer; a duck needs the bandmate's page to be open), `view_model`,
  `view_tick`, `viewing`.
- `lib/webui.lua` (shared, one line): `webcall.view_tick(proj, publish, now)` after the rtc publish.
- `lib/webui/call.js`, `call.css` (owned): the picker, sound sources, `musicSdp`, the drawing layer, notes, full screen, duck.
  `lib/webui/sharemix.js` (new): the worklet.
- Tests: `tests/webui_test.cpp` (the stream: refused on the link's port and through a proxy, 503 with no audio, a 1 kHz tone at -6 dB with
  the right channel inverted read back sample by sample, no gaps, left then right, the hook wanted only while streaming);
  `tests/test_0_60_rt_share.lua` (view and duck, live audio's Play muted and back when a duck runs out, the view model with JS, SWS, neither,
  macOS's flipped y, hidden tracks, publish timing, a link check of every piece); `tests/test_0_60_rt_webcall.lua` (its link check updated);
  `tests/test_0_60_rt_webui.lua` (its webcall stand-in gets `view_tick`).
- Chromium (headless, fake devices; the screen is a drawn canvas, never this computer's): two stand-in web UIs relaying rtc between them,
  the sharer's `/api/mix` a 440 Hz left / 660 Hz right tone. Checked: REAPER mix arrives as stereo Opus with left 440 and right 660; duck on
  and off; the crop equals the arrange view with the window's borders allowed for; an arrow drawn on 0:15-0:20 of Vox reaches the sharer
  named by the sharer, comes back as "you", and stays on 0:15-0:20 when the sharer scrolls 2 s; Notes off and on; Save as comments writes
  `[0:15.0 Vox] (arrow) (on James's screen share)`; a point at 0:25 on Bass shows on the sharer's preview; Full screen crops to exactly the
  arrange view's width; No sound hides the watcher's controls; a second share with System audio carries the stand-in's 1 kHz.

## Not done / limits
- The pointer and notes show on the sharer's **preview** in the page, not over REAPER itself (the roadmap's "dot on the sharer's real
  screen", a topmost layered window from the extension, is still to do).
- REAPER mix is the first output pair; a master routed to other outputs isn't heard. 16-bit (plenty for listening).
- REAPER's audio clock and the browser's drift apart; the worklet skips or refills rather than resampling, so a tiny glitch every few minutes
  is possible (`shortcut:` noted in sharemix.js).
- The view and the picture travel separately: while the sharer scrolls fast, notes can lag the picture by a frame or two.
- The arrange view's place needs JS_ReaScriptAPI or SWS on the sharer's computer (otherwise notes go on the picture only). The SWS path
  (`BR_Win32_FindWindowEx` with class `REAPERTrackListWindow`) is untested against real REAPER.
- Windows' invisible border sizes and the Mac's points-vs-pixels are allowed for by a size match; other DPI setups may fail the match (then no
  crop, not a wrong one, unless a different window happens to be REAPER's size).
- Duck goes by bandmate name, so a bandmate with two computers in the room has Play muted on both while one shares.
- System audio can't be switched on mid-share (the browser asks for it only in its picker).

## Review-later security notes
- `/api/mix` gives REAPER's output to any page served from 127.0.0.1 with the right Host (the server's existing loopback rule): the same
  trust as the rest of the local web UI, but it's audio, not just state. It's refused on the link's port and through proxies.
- The data channel is peer to peer between bandmates who set the call up through the signed link; everything received is checked (sizes,
  kinds, numbers finite and bounded, text 200 characters, 64 KB per message, 100 notes, 40 per watcher), names and notes go in as text, and
  the sharer attributes notes itself. A watcher in the call can still draw rude things on the sharer's preview; the sharer can Clear all or
  Stop.
- "Save as comments" posts to this computer's own chat action, as the phone app does; nothing new on the link.
- A duck can only be asked by a page on this computer (the server's action rules) and only mutes a bandmate's Play here, for 25 s at most
  unless renewed.

## To check in REAPER (two computers, Live sync on in the same song and room, the web UI open on each)
1. Desktop: Share's sound = REAPER mix, Share screen (REAPER's window) to the laptop; laptop: Watch. Play the song on the desktop: the laptop
   hears it in stereo (pan something hard left), with its volume slider and meter; the desktop's bar says "with REAPER mix".
2. With live audio on: talk on the laptop while the desktop shares. The laptop's voice must **not** come back to the laptop in the share's
   sound. Arm a track on the desktop and play it: the laptop hears it once (from the share), not twice; set No sound on the desktop: the
   laptop hears it again through live audio's Play within a second.
3. Stop live audio on the desktop (studio setting off) and share again with REAPER mix: still heard (the hook goes in by itself).
4. Share's sound = System audio, share the whole screen (tick Share system audio): a YouTube tab on the desktop is heard on the laptop.
5. Laptop: **Full screen: like your own REAPER**: only the desktop's arrange view fills the screen. Desktop scrolls and zooms: the picture
   follows.
6. Laptop: Arrow across a chorus on the vocal track; the desktop sees it on its preview, named. Desktop scrolls and zooms: the arrow stays on
   the same bars and track on both. Notes off hides them; Save as comments puts `[m:ss.s Vox] (arrow) ...` in the project's chat.
7. Share a different window (not REAPER): no crop (Full screen is plain), notes stay where drawn on the picture.
8. The Mac: share REAPER's window from the browser (or docked view): the crop lines up (2x pixels).
9. Health/log: nothing new should appear; closing the watching page brings Play back within 25 s at most.
