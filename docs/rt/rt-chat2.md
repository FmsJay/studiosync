# Chat: direct messages, channels, unread, file drops, voice channels (design)

rt-chat2, 2026-11-20. James asked for "Direct messages and more chat features, voice chat and text chat channels like discord for example"
and "Drag and drop files to specific users or the whole group." Offline Lua tests and headless Chromium against a stand-in server only:
**not run in REAPER or between two computers yet.**

## What's built

### Conversations (web UI's Chat)
The scope picker is now a conversation list, three rows of chips, each with its unread count (red with "@" when one mentions you):
- **Here:** This room, This project, Studio (as before).
- **Channels:** the studio's named text channels (`#mixing`). Owner and admins get **+ Channel**, and on a chosen channel **Rename** and
  **Archive / Unarchive**. Archived channels disappear from members' lists, stay readable for admins, take no new messages.
- **Direct:** one chip per studio member (their 1:1 conversation, made on the first click, message or file), then group DMs, and
  **+ Group** (tick 1 to 7 people). Studio members come from `_band/devices/*.json`.

Messages, To-do and Links work in channels and DMs as in the project's chat. **All** (new): messages, to-dos and links of the chosen
conversation together, newest first. (The panel's All also has notes, likes and drawings: not on the web page yet.)

### Seen and unread
A conversation shown on the page (page visible, Messages or All) is marked seen: `{topic:"chat", scope, seen:true}` →
`page_chat.mark_seen`, the same ExtState keys the panel's Messages tab writes (`chat seen <scope> ...`, `chat seen dm:<id>`, `chat seen ch:<id>`),
so the panel's Chat count drops too. `@Name` (any case, whole name) counts as a mention and is highlighted.

**For rt-home:** `require("page_chat").unread_summary(cfg, b)` → `{ total, mentions, by = { [scope] = { n, at, name, kind } } }`.
`b` may be nil (no project open: Studio, channels and DMs only). Archived channels are left out of `total`. Cached 5 s.
`chat.unread(cfg, b)` and `chat.count_unread(cfg, b)` keep their meaning (the panel's three scopes).

### Files
Drag a file onto a person's chip, a conversation's chip or the messages, or press **+ File** (a phone's picker). The page checks kind and
size first, uploads it to this computer (`POST api/upload`, one at a time), then sends `{file:{id,name,size}}`. Live sync
(`lib/chatfiles.lua`):
- refuses anything not on the direct link's own list (audio, MIDI, video, pictures, PDF, text, presets, zips; never exe/dll/scripts),
  any name that isn't a plain file name (or is CON/COM1...), anything over **150 MB** (under the server's 160 MB upload), an upload whose size
  isn't what the page said, and **any file whose first bytes are a program** (MZ, ELF, Mach-O, `#!`) whatever it's called;
- works out its SHA-256 (`StudioSync_FileHash`) and writes a chat message `"sent a file: <name>"` carrying
  `attach = { name, size, sha, key, via }` (`key` = `<message stamp>~<name>`);
- **a DM whose other members the link reaches now:** sends it over the link only (`direct.stream_start` to their peers, named
  `_chat/<key>`; the extension chunks it, resumes from what's there after a dropped connection, checks SHA-256 at the end) and keeps it out
  of the shared folder (staged in `<home>/chat files/<studio id>/`). If the stream fails, the extension forgets it, or it hasn't finished in
  10 minutes, the copy goes to the shared folder after all (`<dm>/files/<key>`) and the log says so;
- **anything else** (someone in the DM not reachable, a channel, Here scopes): into the shared folder (`<conversation>/files/<key>`,
  written under a `.syncthing.*.tmp` name and renamed), and over the link too to those here, for speed.

The receiver sees a file card (name, size, arriving %, or on its way) and chooses: **Save** (to `<REAPER resource>/StudioSync/Received files`,
or `BandSync/...` on old installs), **Save to project folder** (audio only: the front project's own media folder), or **Download** (Live sync
offers it to the page by id, `GET api/file`, sent as octet-stream with nosniff; the page saves it with `<a download>`). Every save first
checks the bytes are whole, match the sender's SHA-256, and aren't a program. Nothing ever opens or runs a file; a file dropped elsewhere
on the page is swallowed rather than opened by the browser.

**Not done:** putting received audio on a track as a new take. There's no shared "import a file as a take" path in StudioSync (the phone's
`phonerec.put_take_in` is specific to phone takes with their own placement), so as agreed it only saves into the project's folder, ready to
drag in. Received link copies in `<inbox>/.streams/_chat/` are deleted after 7 days.

### How it's stored
| What | Where (in the studio's shared folder unless said) |
|---|---|
| DM | `_band/dm/<id>/members.json` (`members` sorted; `<id>` = FNV-1a-64 of the names joined by newline), `msgs/`, `todo/`, `links/`, `files/` |
| Channel | `_band/channels/<12 hex>/channel.json` (`name`, `archived`, `by`, `time`), then as above |
| Link-only DM file, sender | `<REAPER resource>/StudioSync/chat files/<studio id>/<key>` + `<key>.json` (state), not shared |
| Link-only DM file, receiver | `<home>/direct/<studio id>/.streams/_chat/<key>`, not shared |

Messages are one file per message as before (nobody writes another's file). DM messages over the link go **only to the members'
computers** (`to` = their peers) and carry `members`, which the receiver checks hash to the DM and include it before taking it. A DM is
never sent to the studio's phone-alert channel or the local API event list.

## What a DM's privacy really is (plainly)
- **Inside StudioSync** a DM shows only to its members: the panel doesn't show DMs at all, the web page shows only DMs you're in, a page
  can't read, write, save or download in a DM you're not in, and a DM action never falls back into the project's chat.
- **On disk it is not private from the studio.** The DM's messages (and its files, unless they went link-only) are plain JSON in
  `_band/dm/` of the shared folder. Syncthing copies that folder to **every computer in the studio** (owner, admins, members, and guests whose
  computers share the folder). Anyone at any of those computers can open the files in a text editor. They are not encrypted.
- **Link-only files** (a DM whose members are all reachable when sent) never touch the shared folder: they travel over Tailscale
  (WireGuard-encrypted, peer to peer, HMAC-signed with the studio key) to the members' computers only. If the link fails they fall back to the
  shared folder, readable by everyone as above.
- **The phone link is the big hole.** The web UI's phone link carries the studio's web token, which is the same for the whole studio.
  Anyone in the band who has the link (or a phone that kept its cookie) can open **your** computer's web UI over Tailscale and read and send
  your DMs as you. Same for the project chat today, but it matters more for DMs.
- Names aren't authenticated: a computer's user name is what its StudioSync says it is, so a bandmate who renames themselves to you would
  be shown your DMs on their own computer (they could read the files anyway).

Real privacy needs per-person keys (see review list).

## Voice channels: design only (not built)
Built on `lib/liveaudio.lua` (AOO + Opus over the link's UDP port, jitter buffer per bandmate, mute/deafen/push-to-talk/talkback, the hub mix).
Today live audio's peer set is "the bandmates in this project and room" (`direct.peers(song, room)`); a voice channel replaces that set by
"the people who joined this voice channel", studio-wide, like Discord.
- **Model:** voice channels are channels with `"voice": true` in `channel.json` (same create/rename/archive rules), plus every DM gets a
  **Call** button that is a voice channel of its members. Joining writes `_band/voice/<channel id>/<user>.json` (heartbeat every 5 s, like
  presence, gone after 15 s) and sends a `voice` link message `{ ch, user, join|leave }` so it shows at once.
- **Engine:** one live-audio engine per computer, so you're in one voice channel at a time. While joined, `liveaudio.tick` hands
  `StudioSync_LiveAudioPeers` the joined members' peers (from `_band/devices` + Tailscale suffix, as `direct.peers_from` does, with
  `present` = the joined set) instead of the room's; leaving restores the room's. Optional "also hear my room" merges the two sets.
- **What carries:** the Talk stream only (the mic: `mic_plan`), not Play (armed tracks), unless the person ticks "send my playing" (then
  it's a jam). Mute, deafen, push-to-talk, talkback, per-person volume (kept by name) all apply unchanged. From `HUB_FROM` (4) people the
  existing hub mix takes over (`hub_plan`), the hub being the joined member with the most headroom.
- **Pages:** voice channels as chips with who's in (speaking ring from `liveaudio.status()` levels), Join / Leave, Mute / Deafen; a DM's
  Call button. Health's live audio row names the voice channel.
- **Rules:** a DM call is joinable only by its members (the same `scope_ok`); never recorded (live audio already never is); the studio's
  `live_audio` setting off disables voice channels too; UDP firewall rule as today.
- **Steps:** (1) voice flag + join files + link message, (2) peer set switch in `liveaudio.tick` with tests on the plan, (3) pages,
  (4) hub for 4+.

## Files and edits
- New: `lib/chatfiles.lua`, `lib/webui/chat.css`, `tests/test_0_60_rt_chat2.lua`, this doc.
- Mine: `lib/page_chat.lua` (DMs, channels, `scope_ok`, `mark_seen`, `unread_in`, `index`, `unread_summary`, `web_tick`; `read`'s cache key now
  includes the user; `add` takes an optional name), `lib/webui/chat.js` (rewritten around the conversation list).
- Shared, small additive edits: `lib/webui.lua` (one line in `chat_model`: a message's `attach` → `e.file`; one line in `tick`:
  `chat.web_tick(...)` before the "nobody looking" return), `tests/test_0_60_rt_webui.lua` (the page_chat stand-in gets `web_tick`).
- Topics: `chat_index`, `chat_dm_<16 hex>`, `chat_ch_<12 hex>`. Actions on `chat`: `seen`, `want` (DM/channel), `dm`, `channel`, `file`,
  `save` (+`into:"project"`), `download`.

## Tests
- `tests/test_0_60_rt_chat2.lua`: scopes, members, mentions, file names and a program's first bytes, the link's list agreeing with
  `direct.stream_ext`; over a stand-in shared folder: DM members only, link sends to members only, no alert, a non-member's or tampered DM
  refused (nothing written anywhere), live DMs taken by members only; channels (members refused, made, renamed, archived read-only); unread,
  mentions, seen, the summary without a project; the tick publishing only while looking; files link-only in a DM, the fallback on a failed
  stream, the Studio via the shared folder, refusals (renamed program, .exe, too big, wrong size, nothing left behind), saving checked
  against SHA-256 and program bytes, download offers, the page's model.
- Headless Chromium against a stand-in server: chips and badges, picking a channel (want + seen), admin buttons, dropping a .wav and an
  .exe on a person (the .exe refused before upload, the .wav uploaded and sent to the DM), download asked, All tab, phone width without
  sideways scroll.
- `python tests/run.py --no-luals`: my tests pass; at the time of writing two failures belong to other agents' uncommitted work
  (`test_0_60_rt_compat.lua`; `test_0_60_rt_webui.lua` line 103 with their webui.lua edits: it passes on HEAD plus my lines).

## Untested
REAPER at all; two computers; a real Syncthing round trip of `_band/dm` and `_band/channels`; the extension's stream of a finished non-take
file under `_chat/` (bounces do the same with finished files, so it should work); WebView2 / WebKitGTK file drops in the docked view; phones'
file pickers; 150 MB uploads (the server holds an upload in memory); `copy_background` for big saves; the panel's count after a web "seen".

## Review later (security)
1. DMs are readable by everyone with the studio folder (above). Proper fix: per-person key pairs in the extension (X25519), DM bodies and
   files encrypted to the members; or link-only DMs with a local store and acks.
2. The studio-wide phone-link token lets any bandmate use your web UI as you (DMs included). Needs per-person tokens.
3. Channel admin rights are checked only on the computer doing it; a member could hand-write `channel.json`. Sign channel files, or check
   `by` against the trusted admin list when reading.
4. DM ids are FNV-1a-64: membership tamper-evidence is not collision-resistant. Use SHA-256 when there's a Lua/extension hash for strings.
5. `StudioSync_FileHash` reads the whole file on REAPER's main thread (up to 150 MB on send and on save) and treats CRLF as LF (both sides
   alike, so it still matches); a streaming hash in a thread would be better.
6. Received files come from studio members; the SHA-256 proves they're what the sender sent, not that they're harmless (a malicious PDF or
   MP4 is still possible). Only programs are blocked.
7. `chat_index.people` and DM names come from devices files, not verified with `trust.user_file`.

## Check in REAPER (two computers, A and B, same studio, both web UIs open)
1. A: Chat > Direct > B's chip > send "hi @B". B: a "@ 1" badge on A's chip and the panel's Chat count; opening it clears both. A third
   person C sees no DM in their list; confirm `_band/dm/<id>/` exists on C's disk (expected: readable there).
2. A (owner/admin): + Channel "mixing"; B sees it; B can't rename/archive (no buttons); A archives it: gone from B's list, typing refused.
3. A and B in the same project and room with the link up: drag a WAV onto B's chip. B: card arrives, Save → `Received files`; Save to project
   folder → project's media folder; Download in the browser. On A's and B's shared folder: nothing under `_band/dm/<id>/files/` (link-only).
4. Same with B's REAPER closed: the file goes to `_band/dm/<id>/files/` and B gets it when back.
5. Drag `notepad.exe`, and a copy of it renamed `x.wav`: both refused (page or log).
6. Drop a file onto the Studio chip: it lands in `_band/chat/files/` for everyone.
7. On a phone (phone link): + File picks a photo into a DM.
