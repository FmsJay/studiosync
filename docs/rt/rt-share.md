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

---

# Cursor and control, pop-out, "Show its window" (rt-share, 2026-11-27)

James's findings (docs/rt/findings-2026-11-27.md):
- 2: "Screen share shows where the sharer's cursor is, plus "ask for control", and the modern capabilities of Discord / TeamViewer etc.
  (pop-out view, full screen, ...)."
- 4: "More controls/view when trying someone's VST or changing a VST setting on another machine: maybe screen share + control of that VST's
  window."

**Tested offline only:** the extension builds (Windows, MSVC) and its pure parts pass their native test; Lua tests; headless Chromium with
two stand-in computers, a drawn canvas as the screen and Chromium's fake microphone. **Not run in REAPER, on Windows input for real, or
between two computers yet.** Remote control is off by default and needs the sharer's Allow every time.

## What's built

### The sharer's pointer
While you share, your page tells this computer's extension what is shared and asks it every 50 ms where your pointer is in that area. The
answer goes to every watcher over the call's data channel, only when it changed (at most 20 a second), as 0-1 of the picture. Watchers see
a white arrow with your name over the picture, at the right place whatever its size (and in a pop-out or full screen). It hides when the
pointer leaves the shared area, and after 5 s without moving.

What counts as "the shared area" (the page decides, the extension checks):
- **REAPER's window:** a window share (`displaySurface: 'window'`). The extension takes REAPER's main window's visible frame
  (`DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)`, i.e. without Windows 10/11's invisible borders: what the browser captures) and checks
  it has the picture's shape (within 3 %). A window that isn't REAPER's fails the check: no pointer, no control.
- **A plug-in's window** ("Show its window", below): the floating window of FX 1 on the hidden hop track (found by the track's GUID and
  `TrackFX_GetFloatingWindow`), with the same shape check.
- **The screen REAPER is on:** a whole-screen share; the monitor REAPER's main window is on (`MonitorFromWindow`), shape-checked. Pointer
  only, never control.
- A browser tab: nothing.

### Ask for control
- A watcher's picture has **Ask for control** under it (greyed, with a reason, when the sharer can't give it: not a REAPER or plug-in
  window, not Windows, or an older extension). It sends `ctlask` over the data channel.
- The sharer sees **"chilio asks to control the window you're sharing (inside it only; ...)" Allow / Deny** in the Video section, and the
  same on the **panel's bar** (beside the plug-in asks: the page tells Live sync, `{topic:"rtc", t:"ctlask"}`, every 4 s while it waits;
  Live sync puts it in ExtState `share asks`; the bar's answer goes back through ExtState `share answer` into the rtc topic's `answers`, which
  the page acts on).
- **Allow:** the page tells the extension `grant` for that watcher. From then on that watcher's pointer moves (at most ~30 a second, merged),
  buttons (left, middle, right), wheel and keys go over the data channel to the sharer's page, which passes on only the allowed watcher's,
  in order, to the extension. Their picture gets a red outline and "You're in control"; the keys go while their picture has the focus (and
  aren't taken from the page otherwise).
- **One controller at a time:** a second Allow replaces the first; asks while someone controls are answered "X is in control now".
- **Taking it back:** the sharer's bar turns dark red and always says **"chilio is in control (move your mouse or press Ctrl+Alt+Esc to take it
  back)" with Take back**. The panel's bar says it too, with Stop. Control also ends when:
  - the sharer moves their own mouse more than 12 px or clicks (after a 2 s grace from Allow, so the hand that clicked Allow doesn't end it
    at once);
  - the sharer presses **Ctrl+Alt+Esc**;
  - the watcher presses **Stop controlling**, hangs up, or their connection ends;
  - no input from the watcher for **3 minutes**;
  - the share stops, changes window, or the shared window closes (or stops matching the picture for 2 s);
  - the sharer's page goes quiet for 3 s (closed, crashed, asleep): the extension holds a lease the page renews with every message.
  Anything the controller held down (a button, Shift, Ctrl) is let go when control ends. Both pages say why it ended.

### Where input may go (the extension, Windows)
- Only while control is on (granted, and the share still a matching REAPER or plug-in window).
- A pointer event goes in only at a point inside the shared window's rect, and only if the window under that point **is the shared window
  or one it owns** (its dialogs, its menus' owner chain, REAPER's own menus) **and belongs to REAPER's process** (a bridged plug-in's window
  is a child of REAPER's container, so it counts). A window lying over REAPER there: nothing goes in. A button press outside is refused; a
  release always goes (nothing stuck down).
- Keys only while the shared window (or one it owns) is in front, by physical key (`KeyboardEvent.code` -> scan code, so the sharer's own
  layout reads them) from a fixed list: no Windows keys, no media keys; **Alt+Tab, Alt+Esc, Alt+F4, Ctrl+Esc (and Ctrl+Shift+Esc)** are never
  passed on.
- Injected with `SendInput` (absolute over the virtual desktop, per-monitor-DPI coordinates on both the injecting thread and the timer), each
  event tagged (`dwExtraInfo` = "SSRC") so the low-level mouse hook, installed only while control is on, tells the sharer's own mouse (or
  another program's, Synergy's or RustDesk's) from ours.
- macOS and Linux: not yet (the status says `sys: false`; the page greys Ask for control). The code is behind `#ifdef _WIN32`; the rest
  compiles there (checked by compiling the non-Windows branch with MSVC and a stand-in `reaper_plugin.h`; CI builds it for real).

### Pop out and full screen
- **Pop out** (watchers, in a browser) opens `?pop=share&call=<id>`: the share's tile and its tools move into that window (one window per
  share; the same tile, so the pointer, notes, control and its sound go with it) and back into the Video section when it closes. The
  docked view doesn't show Pop out yet (it hands new windows to the browser, where the tile can't follow).
- **Full screen** was there; it now works inside a pop-out too (`ownerDocument`).
- **Shell hook (rt-ui1, docs/rt/ui-web-plan.md 4.4):** call.js handles `?pop=share` itself at its top: it marks `<html class="ss-pop-share">`
  (call.css hides every other child of `<body>`), adds a `.pop-share` box and asks `window.opener.ssShare.adopt(call, window, box)`. When
  the shell routes `?pop=`, it only needs to leave call.js running and show nothing else for `pop=share`; if it provides its own container,
  call.js can put the tile there instead of the `.pop-share` box it makes (a one-line change). When the C++ dock supports pop-outs (its
  `NewWindowRequested`), the same route works there and Pop out can show in the docked view too.

### "Show its window" (item 4)
- The **Try tab** (lib/webui/tryfx.js) has **Show its window** on each plug-in you're trying or have borrowed. It sends an rtc **`ask`**
  (`what: "window"`, the try's token, the plug-in's name) to the owner's computers whose page is open.
- The owner's Live sync passes it to their pages **only if it hosts that plug-in for that very bandmate** (`hoptry.window_of(token, user)`:
  a try or a borrowed plug-in, `sv.user` the asker). Their page shows **"chilio asks to see your Serum window (the plug-in they're trying from
  you)" Show it / No thanks**. It's asked and answered every time; there's no "always".
- **Show it:** the page tells Live sync `fxwin` (only a page on this computer: `StudioSync_WebUIPollHere`), which opens that plug-in's floating
  window (`TrackFX_Show(track, 1, 3)` on the hidden hop track) and puts its track GUID and FX index in the rtc topic (`fxwin`). In the same
  click the browser's picker opens on its windows: the owner picks the plug-in's window. The share's offer carries `re` (the ask's id), so
  the borrower watches it at once (no Watch to press), and the extension's shared area is that plug-in's window. The borrower can then **Ask
  for control** of it, the same flow as above.
- **No thanks** answers `busy`: the borrower's page says "James said no to showing Serum's window".

## Messages
- Page -> extension, `POST api/input` (JSON, one flat object, at most 2 KB; this computer's page only: loopback, not the link's port, not
  `tailscale serve`, not a guest; `X-StudioSync: 1` as every POST):
  `{t:"share", target:"reaper"|"fx"|"monitor", track?, fxi?, pw, ph}`, `{t:"unshare"}`, `{t:"status"}`, `{t:"grant", who, idle?}`, `{t:"stop"}`,
  `{t:"move", x, y}`, `{t:"down"|"up", b, x, y}`, `{t:"wheel", x, y, dx, dy}`, `{t:"key", code, down}`.
  Answer: `{sys, area, can, on, who, why, cur:[x,y]|null}` (`{bad:true}` for anything that doesn't parse).
- ReaScript: `StudioSync_RemoteControlStatus()` (that JSON), `StudioSync_RemoteControlStop()`.
- Data channel (the share's own, peer to peer): sharer -> watchers `{t:"cur", x, y}` / `{t:"cur"}`, `{t:"ctl", can, on, by, you, no?}`;
  watcher -> sharer `{t:"ctlask"}`, `{t:"ctlend"}`, `{t:"in", e:"move"|"down"|"up"|"wheel"|"key", x, y, b, dx, dy, code, down}`.
- rtc over the signed link: `{t:"ask", to, call, what:"window", token, fx}`; an offer's optional `re`. Local (this computer's page only):
  `{t:"ctlask", call, user, on}`, `{t:"fxwin", token}`. Model: `answers: [{call, yes, seq, time}]`, `fxwin: [{token, track, fxi, fx}]`.

## Files
- New: `extension/remotectl.h` (the pure parts: parser, mapping, shape check, SendInput coordinates, wheel, scan codes, refused combos,
  `RcPolicy`, the status JSON), `extension/remotectl.cpp` (timer, hook, SendInput, the HTTP handler, the two API functions),
  `tests/remotectl_test.cpp` + `tests/build_remotectl_test.cmd` (249 checks), `tests/rt_share_browser.mjs` (57 checks).
- `extension/webui.cpp` / `webui.h` (small, additive): the `webui_input_http` hook and the `/api/input` route (403 unless local and not
  proxied, never a guest; 404 when remotectl isn't linked in, as in the standalone tests).
- `extension/reaper_menu.cpp` (one line: `remotectl_register`), `extension/build_windows.cmd` (the source and its .obj),
  `.github/workflows/extension.yml` (the source in the macOS and Linux builds, the native test on both).
- `lib/webcall.lua`: `ask`, `re`, the local `ctlask` / `fxwin`, the panel's asks and answers (`ctl_ask`, `ctl_asks`, `asks_tick` from
  `view_tick`, `bar`), the model's `answers` and `fxwin`.
- `lib/hoptry.lua` (additive): `window_of`, `show_window`, the try's `token` in the Try model, and `hoptry.bar` calls `webcall.bar` first (the
  panel already calls `hoptry.bar`, so StudioSync - Panel.lua is untouched).
- `lib/webui/call.js`, `call.css`: everything on the pages; `lib/webui/tryfx.js`: the button.
- Tests changed: `tests/test_0_60_rt_share.lua` (asks, offers' `re`, the link's host check, fxwin, the bar with a stand-in ImGui, the
  extension's door and wiring), `tests/test_0_60_rt_webcall.lua` (its "no keys taken" check now allows the one in-control handler).

## To check in REAPER (Windows, two computers, the web UI open on each, in a browser)
1. Install the extension built from this commit; restart REAPER. `reaper.StudioSync_RemoteControlStatus()` in a ReaScript console returns
   `{"sys":true,"area":false,...}`.
2. Desktop: Share screen (REAPER's window) to the laptop; laptop: Watch. Move the desktop's mouse over REAPER: the laptop sees the arrow
   with the name, in the right place; off REAPER's window it goes; resting 5 s it goes.
3. Laptop: Ask for control. Desktop: Allow (try once from the page, once from the panel's bar). The desktop's bar turns dark red with
   "... is in control". Laptop: click a track, drag a fader, scroll the arrange view, type a track name (keys need the picture focused).
4. Take back each way: move the desktop's mouse (after 2 s); Ctrl+Alt+Esc; Take back; the panel's Stop; the laptop's Stop controlling; leave it
   3 minutes; close the desktop's page (within 3 s). Each time the laptop's clicks stop working and a held key (hold Shift on the laptop, take
   back) isn't left down on the desktop.
5. Put another window (Notepad) over part of REAPER on the desktop: the laptop's clicks there do nothing (the picture still shows REAPER).
   Open a REAPER dialog (FX browser) from the laptop: it can be used (it's REAPER's, owned by its window). Alt+Tab and Alt+F4 from the laptop do
   nothing.
6. Share a non-REAPER window (Notepad): no arrow, Ask for control greyed. Share the whole screen: the arrow shows on REAPER's screen; control
   stays greyed.
7. Try tab on the laptop: try one of the desktop's plug-ins, Show its window. Desktop: Show it, pick the plug-in's window in the picker. The
   laptop watches it at once; Ask for control, Allow, turn a knob in the plug-in's own UI from the laptop.
8. Pop out on the laptop (browser): the share moves to its own window with its tools; full screen there; close it: back in the Video section.
9. With two monitors at different scaling (100 % and 150 %), REAPER on each in turn: the arrow and clicks land where they should.
10. The Mac (as a watcher): everything but giving control works; as a sharer, Ask for control is greyed with a reason.

## Not done / limits
- **macOS and Linux sharers:** no pointer and no control (Windows only). A Mac version would use `CGEventPost`, `CGEventSourceSetUserData`
  for the tag, a `CGEventTap` for the sharer's own mouse and `kCGWindowListOptionIncludingWindow` bounds; it needs Accessibility permission
  and testing on James's Mac.
- The sharer's pointer is shown to watchers but not drawn over the sharer's own REAPER (the earlier "dot on the real screen" item stays).
- A whole-screen share never gives control (its monitor can't be told apart from another of the same shape with certainty).
- A plug-in that opens its own popup outside its window's rect (a big preset browser) can't be clicked outside that rect.
- Keys by physical place: a watcher with a different layout types the sharer's layout's characters. No IME/dead-key composition.
- Wheel steps are scaled (~100 browser px = one notch); a trackpad's fine scrolling arrives as whole notches.
- The window share's "is it REAPER's" check is by shape (3 %); a different window of the very same shape would pass (the input still only
  ever lands on REAPER's own windows).
- Pop out isn't in the docked view yet (C++ dock pop-outs, ui-web-plan 4.4).
- Each page's first WebRTC connection took ~9 s in headless Chrome on the desktop (Chrome enumerating network adapters, Tailscale's and
  VMware's): not this feature's, but the browser test waits up to 40 s for it.

## Review later (security; the review is held until James says)
- **Remote input exists now.** Everything below holds by design, but none of it has had a security review:
  - `POST /api/input` trusts any page served from 127.0.0.1 with the right Host and `X-StudioSync` (the existing loopback rule for the whole
    local web UI). A malicious local page could grant control to itself, but input still only lands inside REAPER's shared window, and only
    while a share is set up and the page keeps the lease.
  - The grant is the sharer page's decision; the extension doesn't know which watcher sends what (it can't: the data channel ends at the
    page). The page passes on only the allowed session's input.
  - The data channel is peer to peer, set up through the signed link; the watcher is a bandmate in the room. A compromised bandmate page
    could send input as fast as allowed while in control (the page queues at most 200; moves merge).
  - The "belongs to the shared window / REAPER's process" check uses `WindowFromPoint`, `GetAncestor(GA_ROOT)`, the owner chain and
    `#32768` menus; a REAPER dialog owned by the main window (Preferences, Actions list, ReaScript editor, Render) is reachable by a controller
    of REAPER's window. Those can run actions and scripts: control of REAPER's window is as powerful as sitting at REAPER. Maybe limit
    REAPER-window control to the arrange/mixer area, or block certain dialogs, after review.
  - Keys go to whatever has focus inside REAPER (a script editor included). File dialogs opened from REAPER are owned by it, so a
    controller can navigate the sharer's disk through them.
  - The low-level mouse hook is global while control is on; if REAPER's main thread hangs, Windows' hook timeout applies to all mouse input
    on that computer until it's removed.
  - The take-back hotkey is polled with `GetAsyncKeyState`; a controller could send Ctrl+Alt+Esc too (refused as Ctrl+Esc), so only the
    sharer can press it.
  - Idle 3 minutes and the 2 s grace are judgment calls; a fixed overall time limit isn't there.
  - `fxwin` and `ctlask` are accepted only from a page on this computer (`StudioSync_WebUIPollHere`); a window ask from the link is accepted
    only for a plug-in this computer hosts for the asker (by their name as the signed link reports it).
- "Show its window" opens a plug-in's window on the owner's REAPER at the owner's click; the borrower sees only what the owner picks in the
  browser's picker (the owner could pick the wrong window: the bar says what's shared).
