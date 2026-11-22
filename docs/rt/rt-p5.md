# P5: phone, home and chat (rt-p5, 2026-11-21)

Backlog package P5 (items 1.25, 1.26, 1.27, 3.9, and from P1 item 1.5's phone half). Offline tests only; nothing was run in REAPER, on a phone
or in a browser. The checks for those are at the end, written to be run through the S23 over adb and Chrome DevTools, or by hand.

## What was built

### 1.5, phone half: a claimed track's take pick asks instead of refusing (`lib/phonedaw.lua`)
The phone's take pick refused outright when a bandmate held the track. It now goes the way `lib/dawedit.lua` does: `dawedit.item_why` (which calls
`claimask.askable`), the pick is made, and `claimask.web_ask(proj, cfg, b, who, it, owner, name, pos)` says whether mirror.watch will ask the
claimer; the answer carries `ask = <name>` only when it does. The phone's page reads `reply.ask` and says "Asked <name> for it (they claimed it)".
A pick that merges with an auto-claimer's own change goes out and says "Done".
Test: `tests/test_0_60_rt_phonedaw.lua` (a present claimer is asked; one who isn't here is still a refusal).

### 1.25 Phone MIDI (`lib/livekeys.lua`, `lib/webui/phonedaw.js`, `lib/dawmidi.lua`, `lib/webui/pianoroll.js`)
`lib/livekeys.lua` is not in P5's file list but is where the phone's live notes live; no other package holds it.
- **A channel for each page.** Each page that plays live gets its own channel on REAPER's virtual keyboard (1-16, the pads' channel 10 where
  it's free, otherwise the first free one). The track's record input is "virtual keyboard, that channel" and every note goes in on that channel
  whatever channel the page played it on, so two phones play two tracks at once and neither hears the other. A page that asks for a track
  another page holds takes it, and the other page is told ("another page took this track"). A 17th page is told no. Per page state:
  armed / monitored / input put back only while still what it set; stuck-note release (panic, 3 s quiet, idle, refusal, exit) is per page and
  per channel. The topic `phonekeys` is now `{ pages = { [sid] = { sid, seq, track, name, ch, why, also } } }`; the page reads its own entry.
  The "also" list names only armed tracks that really hear this page's channel (a track filtered to another page's channel isn't listed).
- **Program changes** go through (a controller's; the on-screen keys send none), on the page's own channel. The page may leave the second byte
  out. System messages and a program number over 127 are still dropped.
- **Step input as one undo point.** The piano roll's step notes carry `step: true`. `lib/dawmidi.lua` puts each in with no undo point of its own
  and makes one "StudioSync web page: step input (N notes)" point when the run ends: 1.5 s after the last note (`dawmidi.STEP_GAP`, flushed by
  the Project page's tick) or at once when any other edit arrives. One Ctrl+Z takes the run back. Plain adds keep their own point.
  Small edits in P14's files: `lib/dawmidi.lua` (the step path and `step_flush`), `lib/webui/pianoroll.js` (one flag on the step add).
- Left as REAPER's own routing: other armed tracks on "All MIDI inputs" still hear a page's notes (said on the page).

### 1.26 Home
- **Phone-link notifications** (`lib/webui/home.js`). Plain http over the phone link can't use the browser's Notification, so a new mention shows
  as a banner on the page with a short buzz (`navigator.vibrate`), and the tab title keeps counting. The Notify button's tooltip says why it
  is hidden there. Where notifications work (127.0.0.1) nothing changes.
- **Open from a page** (`lib/webhome.lua`, `StudioSync - Open session.lua`). Home's Open now runs the script with ExtState `open quiet`; with it
  the script's `band.msg` boxes ("still arriving", "open that room first") go to the log and to ExtState `open said` instead of onto a screen
  nobody may be at. `webhome.open` reads and clears it and the Home topic carries `opened = { song, room, said }` for a minute; the page
  shows it under the head. Switching to an open tab says so too.
- **Mix times in one clock** (`lib/webhome.lua`). A mix's or stems folder's time is the file's modified time when `JS_File_Stat` is there (read once
  per file, cached), converted from this computer's own clock; the name's time (the renderer's local clock) is only the fallback.

### 1.27 Chat uploads (`extension/webui.cpp`, `extension/webui.h`, `lib/chatfiles.lua`)
Past 4 MB an upload is written to a spool file in the temp folder as it arrives (not held in memory), and its SHA-256 is worked out by the
receiving thread as the bytes come in, in StudioSync_FileHash's definition (a CR before an LF dropped unless the bytes hold a NUL: both
variants are kept while receiving and the right one is picked at the end). New `reaper.StudioSync_WebUIUploadHash(id)`; `StudioSync_WebUISaveUpload`
moves the spool file to where Lua says (a rename on one volume, a copy across volumes, on the caller's thread as before) and still returns -1 and
keeps the upload when the path can't be written. Older uploads are let go with their file (oldest of two; a guest's; shutdown). `lib/chatfiles.lua`
uses the upload's hash and no longer reads the saved file whole on REAPER's main thread; an older extension falls back to `StudioSync_FileHash`.
Native test: `tests/webui_test.cpp` (a 5 MB CR LF text and a 9 MB binary: hash equals `sign_file_hash`'s rule; unwritable path; byte for byte; let go
once saved; pushed out by newer ones). Windows build to a scratch DLL (`DLL_OUT`) compiled; the tracked DLL is untouched. Left: the receiver's hash
at Save (`cf.save`) still reads the saved file whole on the main thread (rt-chat2 limit 5, the other half).

### 3.9 Home proposals and chat (the four the backlog names)
- **Status line** (`lib/profile.lua`, `lib/webui/home.js`). A short line of your own ("back at 8", 60 bytes) in your profile file (`status`, `status_at`);
  shown next to you in Online now for 24 hours, then gone. A box under the head sets it (Enter or leaving the box); empty clears it. Cleaned again
  when read from a bandmate's file.
- **Since you were last here** (`lib/webhome.lua`, `lib/webui/home.js`). The page keeps, in this browser, when it last had each project in front and
  sends that map with its want (at most 40 entries, each checked); each project row says "N changes by others since you were last here" (not yours,
  not automatic ones; counted over the newest 40 events of each room, so "40+" is the most).
- **Mentions for several names** (`lib/page_chat.lua`). `chat.mentions(text, names)` takes a list; `chat.names_of(cfg)` is your user name, your display
  name and everyone / all. The chat's own unread @ counts, Home and the chat page's highlight (chat.js) now agree. `webhome.mentions` is the same function.
- **A to-do for someone** (`lib/page_chat.lua`, `lib/webui.lua`, `lib/webui/chat.js`). A to-do carries `for`, set from a person picker beside the
  box (someone of the studio or you; anyone else is dropped); Home's "To-dos for you" already honoured it, and the page shows "for X".
- **A cheap newest-messages read** (`lib/page_chat.lua`, `lib/webhome.lua`). `chat.newest(cfg, b, scope, k, kt)` finds the newest from the folder
  listings (names begin with their stamp) and reads only those; messages are kept from one read to the next (they never change). Home reads 150 messages
  and 80 to-dos instead of the whole studio's chat every 15 s. Shortcut: a mention older than the newest 150 messages, and an open to-do beyond the
  newest 80, isn't shown on Home.
- **Not built, defaults from section 4:** 3.12's low-res video proxy and the Video processor's preset sharing (4.10: no). Project cover art, read
  receipts and a mention-only phone push: not in the backlog's P5 list; the studio alert channel already sends every chat message (`alerts.send`).

## Files
Mine: `lib/phonedaw.lua`, `lib/webui/phonedaw.js`, `lib/livekeys.lua` (not listed), `lib/webhome.lua`, `lib/profile.lua` (not listed), `lib/page_chat.lua`,
`lib/chatfiles.lua`, `lib/webui/home.js`, `lib/webui/home.css`, `lib/webui/chat.js`, `extension/webui.cpp` / `webui.h` (upload path only),
`StudioSync - Open session.lua` (a few lines), tests: `test_0_60_rt_phonedaw.lua`, `test_0_60_rt_vmidi.lua`, `test_0_60_rt_dawmidi.lua`,
`test_0_60_rt_home.lua`, `test_0_60_rt_chat2.lua`, `webui_test.cpp`.
Small additive edits in others' files: `lib/webui.lua` (one line in `chat_model`: a to-do's `for`), `lib/dawmidi.lua`, `lib/webui/pianoroll.js` (above).
No version file touched (EXT_VERSION, `make_index.py`, `tools.lua`): the extension needs a release for `StudioSync_WebUIUploadHash` and the spool.

## Review later (security)
- A spool file for an upload sits in the temp folder under a random name until saved or let go (two at most from the phones, two from guests); other
  local users could read it. It holds what the page sent, as the memory copy did.
- `phonekeys` pages: up to 16 pages can each arm a track they may edit; the room's track rule is checked for each every second as before.
- A page's `since` stamps and a status line are text a page chose; both are length- and format-checked and shown as text.

## Checks (not run: nothing was run in REAPER, on a phone or in a browser)

**S23 over adb and Chrome DevTools** (`adb forward tcp:9222 localabstract:chrome_devtools_remote`, Playwright `connect_over_cdp`, the studio's Tailscale name):
1. Phone app, Play view, two phones (or the S23 plus a desktop browser) on two different instrument tracks, Live into REAPER on both: both arm,
   input shows "Virtual MIDI keyboard / channel 1" and "channel 2"; each plays only its own track; the page says "virtual keyboard channel N".
   Pads on one phone: channel 10. Turn one off: only its track is put back.
2. Second phone picks the first phone's track: the first says "another page took this track" and stops; no stuck notes.
3. A USB MIDI keyboard sending a program change (Android Chrome Web MIDI): the instrument changes patch.
4. Phone Project view, pick a take on a track a bandmate has claimed (Claims mode, bandmate here): "Asked <name> for it"; the pick is held on the
   computer until they answer; refused when the claimer isn't here.
5. Home over the phone link: a bandmate writes "@<your name>" in the studio chat: a banner appears with a buzz, the tab title counts; with the
   page in the background nothing pops (expected over http). On 127.0.0.1 with Notify allowed a real notification still appears.
6. Home, tap Open on a project that isn't open on the computer: if the project is still arriving the page says so ("it may still be arriving")
   and no box appears on the computer; the computer's log has the line.
7. A mix rendered on a computer in another time zone (or set the laptop's zone differently): Home's "Mixes and stems" time matches the other
   computer's wall clock difference (needs js_ReaScriptAPI here).
8. Status line: type "back at 8", press Enter: it shows next to you in Online now on every page within ~10 s; empty it: gone.
9. Since you were last here: open project A, switch REAPER to project B, a bandmate edits A: A's row on Home says "1 change by others since you
   were last here"; opening A clears it.
10. A to-do for a bandmate (the picker beside the box): it shows "for <name>" and on their Home under "To-dos for you".
11. Chat: drop a 100+ MB file on a person: the page uploads, REAPER doesn't stall on the send (watch a playing project); the message carries the
    SHA-256; the receiver's Save matches.

**REAPER (real computers):** step input with a 1/16 grid and a controller: chord, Rest, Back; wait 2 s; Edit > Undo shows one
"StudioSync web page: step input (N notes)" and one Ctrl+Z removes them all; notes appear on the other computer after the point is made.

## Check results (rt-t1, 2026-11-22, 0.59.49.95 + extension 1.0.37; details in `rt-t1.md`)

Unattended with `tools/devices/p5_checks.py --phone`: the S23's Chrome over the phone link (adb over Wi-Fi + DevTools), a second page in
headless Chrome on the laptop, the bandmate as the laptop's own web UI; everything made was deleted after, REAPER's inputs read back.
| Check | Result |
| --- | --- |
| 1 two pages, two virtual keyboard channels | **pass**: channel 1 (S23) and 2 (laptop page); REAPER's inputs 6081/6082, armed; back to input 0, unarmed 0.4 s after off |
| 2 the second page takes the track | **pass** on the S23 ("another page took this track"); intermittent from laptop pages: 2 of 7 runs the first page wasn't told within 15 s |
| 5 mention banner over http | **pass**: banner text and title "(1) StudioSync"; the buzz can't be observed |
| 8 status line | **pass**: on the laptop's page 0.7 s later; cleared |
| 10 a to-do for a bandmate | **pass**: on James-Laptop's Home 13.3 s later |
| 11 upload past the spool | **pass**: 5 MB, the shared copy's SHA-256 equals what was sent (deleting the message leaves the file in `_band/chat/files/`: rt-t1 finding 6) |
| 3, 4, 6, 7, 9 | not run (a real USB keyboard; Claims mode; would switch REAPER's tab; another time zone; a bandmate edit with another project in front) |
