# rt-ui9: Chat and pop-outs, web side (Phase 9 of the whole UI in the web view)

Plan: `docs/rt/ui-web-plan.md`, section 6 "Wave B" > Phase 9, with 1.3 (Chat: "Notes and Likes join Chat's All", "the Call tab moves to the
shell's call controls"), 2.1 (the top bar's call controls) and 4.4 (pop-outs, one call per computer). Findings served
(`docs/rt/findings-2026-11-27.md`): "Pop out the parts of the UI where it makes sense (chat, plug-ins, ...)" for the chat and the call, and
the last piece of "Messages shown as unread after being read".

## What was built

- **Read once per newest message** (`lib/webui/chat.js`): rt-people's fix sent "seen" whatever the list's count said, but the page never
  remembered that it had, so it said it again on every draw of the conversation. Now it says it once per newest message, and again only if
  the call fails. rt-people's server side (`page_chat.mark_seen`, the covered scopes, the shared seen file) is unchanged.
- **Notes and Likes in All** (`chat.js`, `lib/page_chat.lua`): with All open on This room or This project, the page asks for the room's notes
  and likes every 10 s (`{ topic: "chat", notes: true }`). While asked (30 s), Live sync reads the room's changes a little each tick (the same
  `recall.warm` the panel's Chat page uses, 4 ms a tick) and publishes `chat_notes`: `{ song, room, notes = { { id, type = "note" | "like",
  user, time, text (notes only, 2000 bytes at most), track, pos } } }`, newest first, 100 at most (`page_chat.notes_model`). All mixes them
  in with the messages, to-dos and links by time: "note chilio: Louder vox · Vox (at 1:23.4)", "like chilio: liked a take on Bass". Studio,
  channels and DMs show none (they aren't the room's). All's authors now read through `ssProfiles.name` too (a person's computers as one).
- **The top bar's call controls** (`lib/webui/call.js`, `call.css`): call.js puts `#sscall` in the shell's header, right after the status
  pill (no shell.js or index.html edit). It shows:
  - while StudioSync's live audio runs here: **Mic on / Muted / Deafened** and **Deafen / Hear**, as the panel's live audio bar (a click on
    the mic while deafened hears again). The page sends `{ topic: "rtc", t: "la", k: "mute" | "deaf", on }`; `lib/webcall.lua` takes it only
    from a page on this computer and calls `liveaudio.set`; the `rtc` model carries `la = { mute, deaf, ptt }` while live audio runs.
  - a ring: "chilio is calling" with **Answer** / **No thanks** (or **Watch** for a share), in every window.
  - each call or share going on, here or in another window of this computer: "Call: chilio", with **Mic** / **Camera** (the call's own
    tracks, on or off) and **Hang up** (**Stop** for your share). "(another window)" when it's held elsewhere; the buttons work from there.
  - **Video**: opens and closes the video section (who you can call, the pictures). It now starts put away and opens by itself when a call
    rings or runs; the main window remembers open or closed (`ss-call-open`), a pop-out starts with it put away. A page without the shell's
    header (rt-share's test page) keeps the section always shown, as before.
- **One call per computer** (`call.js`): the pages of one browser on this computer (REAPER's main window and its pop-out windows share one
  WebView2 environment; a browser's tabs share theirs) talk over `BroadcastChannel('studiosync-call-<this computer's device id>')`. Each page
  says every 2 s (and when it changes) which calls it holds and whether their mic and camera are on. A press goes to:
  1. the page that holds a call, else
  2. the call's own window (`?pop=call`), else
  3. the main window (the oldest page without `?pop=`), else
  4. the page where it was pressed.

  So Call in a chat pop-out starts the call in the main window, Answer in the main window answers in the call's window, Hang up anywhere ends
  it where it is. The others show it in their top bar and grey Call for that bandmate. **Share screen stays in the page where it's pressed:**
  the browser lets only the window you clicked in capture the screen.
- **The call pops out** (`?pop=call`): **Pop out** at the top of the video section opens the section in a window of its own (the shell's
  pop-out: no tab row, "Back into the main window"; call.css shows only the video section under the top bar). New calls start there. A call
  already going stays in the page that holds it.
- **Pop out in REAPER** (rt-ui8's "Not done"): the call's Pop out and a watched share's Pop out show in the docked view once the REAPER
  window says it opens pop-outs itself (`ssEnv.winPop`), and stay hidden before that (they'd go to the browser, where the call can't follow).
- **The chat pops out** (`?pop=chat`, the shell's): checked in a browser and with a stand-in REAPER pop-out window (no `?host=`, the window's
  `{ win, docked, pop: true }`); sending, reading, the conversation list and the top bar's call controls all work there.

## Files

Mine: `lib/webui/chat.js`, `lib/webui/call.js`, `lib/webui/call.css`, `lib/page_chat.lua`, `tests/test_0_60_rt_ui9.lua`,
`tests/rt_ui9_browser.mjs`, this doc. Small additive edit in another file: `lib/webcall.lua` (the `la` local message, this computer only, and
`la` in the model: the rtc topic's own Lua, nobody's phase). Not touched: `shell.js`, `tabs.js`, `index.html`, `webui.lua`, `chat.css` (nothing
to change there).

## Checks for James

In REAPER on JAMES-MAIN (after a release with these files and Extension 1.0.41's pop-out windows):
1. Chat tab: have the laptop post in This project. Open Chat on the desktop: the unread count goes and stays gone (Home, the strip's count,
   the panel's Messages count), also after a reload.
2. Chat > All on This project: notes and likes made in the panel (Notes and Likes tabs) show among the messages, newest first, with their
   track and time; on Studio they don't.
3. The top bar: with live audio running, Mic on and Deafen sit right of the status pill. Mute and Deafen from there, then look at the panel's
   live audio bar: the same state. Stop live audio: the buttons go.
4. Video in the top bar opens the video section; press it again to put it away. Call the laptop: the section opens by itself; the top bar
   shows "Call: <laptop>" with Mic, Camera and Hang up. Mic off: the laptop stops hearing you; Camera off: the picture stops.
5. ⋯ > Pop out this page on Chat: a REAPER window with the chat alone. From it, call the laptop (Video in its top bar, then Call): the call
   starts in the main window (its section opens), and the chat window's top bar shows "Call: <laptop> (another window)". Hang up from the
   chat window: it ends.
6. Video section > Pop out: the call's own REAPER window. Call the laptop from the main window: it starts in the call's window. Let the laptop
   call you: Answer in the main window's top bar; the call runs in the call's window and the ring stops everywhere.
7. Watch the laptop's screen share docked: Pop out shows on the share's tools and opens a REAPER window (before, it was hidden there).
On the laptop's browser: 1, 2, 4 and 6 the same (pop-outs are browser popups).
On the phone: nothing new but the notes in All (no camera there).

## Tests

- `tests/test_0_60_rt_ui9.lua` (in `tests/run.py`): `page_chat.notes_model` (notes and likes only, fields made safe, capped), the ask and
  publish (nothing read or published unasked, nobody looking, after 30 s, or with no project), webcall's `la` (this computer only, mute or deaf
  only, on or off only, nothing over the link, no live audio no action, the model's `la` and when it's absent), and a link check of chat.js,
  call.js and call.css.
- `tests/rt_ui9_browser.mjs` (by hand: `node tests/rt_ui9_browser.mjs`; Chrome or Edge, fake camera and mic): the real index.html against a
  stand-in server, three pages of one Chrome at once (main, `?pop=chat`, `?pop=call`), as REAPER's windows share one browser: read said once
  per newest, All with notes and likes, the top bar's live audio buttons, Video, the chat pop-out sending, the call started from the main
  window held by the call's window, Mic from the main window muting it there, Hang up from the chat window, a ring answered from the main
  window in the call's window and stopping everywhere, the call's window closed handing calls back to the main window, and in REAPER (a stand-in
  WebView2 channel) Pop out hidden until the window says `pop`, then opening `?pop=call`; a REAPER chat pop-out. No page errors.
- `tests/rt_share_browser.mjs` and `tests/rt_ui1_browser.mjs` still pass.

## Left for later

- **Across REAPER and a browser on the same computer** the channel doesn't reach (two browsers): the server's out-echo still stops a ring in
  one when the other answers, but a second call could start from the other. Closing that needs Live sync to say which page holds the call
  (in `rtc`); not done.
- **A call doesn't move** between windows: Pop out moves new calls, not one already going (its connection lives in the page that made it).
  Closing the window that holds a call ends it, as before.
- **Join / leave live audio** from the top bar (the plan's "Join"), Hold to talk and talkback: still the panel's (Chat > Call, the call
  window). The top bar has Mute and Deafen only.
- **Go** for a note or like (the panel's All jumps REAPER there): the web shows the time; a Go needs a "move the edit cursor" action nobody
  has yet.
- The strip's words don't mention a call ("In a call with chilio"): `stripWords` is shell.js's.
- The panel's Everyone filter ("show only") isn't applied to the web's notes (it isn't to the web's messages either).

## Review later (security)

- `la` (Mute / Deafen) acts only for a page on this computer (`StudioSync_WebUIPollHere`), only on `mute` or `deaf`, only with a boolean;
  a remote page's is dropped. It only calls `liveaudio.set`, the panel's own.
- `chat_notes` carries the room's notes and likes to every page that can see the project's chat already (the same people, the same files),
  capped at 100 and 2000 bytes a note, without take ids or file paths.
- The call channel is same-origin only (BroadcastChannel); a page there could already do anything the page can. What comes in is still
  checked (ids, names and devices as short strings, kinds and roles from a fixed set, at most 8 calls a page), and a press only does what
  the page's own buttons do. The channel's name holds the device id, which the page has already.
