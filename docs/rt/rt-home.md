# Studio Home page and profiles (rt-home, 2026-11-20)

James: "Home page for the studio expanded, see what projects were worked on last and by who with time stamps and notifications for messages
etc." and "Profile pictures and other customisation." Lua tests and a stand-in server in headless Chromium only; not run in REAPER yet.

## What it is
The web UI's **Home** tab now opens on a studio dashboard in the left column (Who's here moved under it as "In this project"; the chat stays on
the right; one column on a phone and in a narrow docker):
- **Head:** your picture (click: Your profile), "Good evening, <display name>", the studio and the project you're in, **Notify me**.
- **On air:** a red bar when anyone in the studio is recording (green when playing), with who and where.
- **For you:** unread messages (every conversation's count, by conversation, when rt-chat2's `chat.unread_summary` is there; else the panel's
  count for this project), mentions of you in the last 14 days (`@user`, `@display name`, `@everyone`, `@all`; new ones marked until seen
  on this browser), and open to-dos that name you (`@you` in the text, or a `for` field equal to you if the chat ever adds one).
- **Online now:** everyone with StudioSync open, studio-wide, with the project and room (recording/playing rings; "away" when another tab is in
  front); you, where your tabs are.
- **Projects:** every project (newest activity first) with its stage, who's in it now (faces), and who changed it last, what (History's own
  words, `recall.describe`) and when ("5 min ago", the full time on hover); never changed: who published it and when. **Open** opens it in
  REAPER on this computer; **Switch to it** when it's open in another tab; **Project view** on the one you're in.
- **New takes** (studio-wide), **Mixes and stems** (from `<song>/mixes` names and `<song>/stems/<date time user>` folders), **Last session
  here** (this room's newest recap).
- **Small touches:** a count on the Home tab and in the page title ("(3) StudioSync"); browser notifications for a new message or mention while
  the page is in the background (opt-in; browsers allow it only on the computer's own `http://127.0.0.1` address, not over the phone link);
  times refresh every 30 s; avatars with each person's colour ring everywhere.

**Your profile** (click your picture on Home): picture (PNG or JPEG; cropped square and re-encoded to a 96 px JPEG in the browser), display
name (40 bytes), colour (people.lua's own: one per person in every studio, as Setup > Options sets it; Default goes back to the palette's).

## How it works
- `lib/webhome.lua`: topic `home`, built every 10 s only while a page shows Home (`{topic:"home", want}` every 10 s, 30 s grace), published only
  when it changed. Sources, all existing: `band.songs`; each room's events folder (names only: the newest 40 by the stamp in the name, read at
  fixed places from the end; this room every build, other rooms at most once a minute; only those 40 files read, through `recall.event`'s
  cache); each room's status files plus the link's live statuses (`presence.with_live`/`presence.live`, the `rooms.people` rule: under 45 s);
  `rooms.tab` for your tabs; `extras.stage`; mixes/stems names; `recap.last`/`recap.lines`; the studio's chat through `page_chat.read(cfg, b,
  "band")` every 15 s (mentions, to-dos, newest messages for notifications) and `page_chat.unread_summary` / `page_chat.unread`.
  A take is an added item (first revision, not restored, not automatic) whose name is a smart take name or REAPER's own (recap.lua's rule).
- Open: `{topic:"home", open:{song, room}}` -> only a song `band.songs` lists (a guest's own list) and a room it has; its tab to the front if
  open here, else ExtState `open project` = `song|room` and the **Open session** action, exactly as the panel's Projects page does it.
- `lib/profile.lua`: topic `profiles` (`{ me, people = { user = { name, colour, pic } }, reply }`), read every 10 s while any page looks (so
  presence, chat and Home can use it), at once after your own change. Files, one writer each: `_band/profiles/<id>.json` (`{ user, name,
  pic = "jpg"|"png", time }`) and `_band/profiles/<id>.jpg|.png`.
  - **Picture checks** (on save and again on every computer that reads a bandmate's file): at most 10,000 bytes (size checked before reading),
    PNG signature + IHDR + IEND, or JPEG SOI + a frame header (size read from it) + EOI; at most 256 px a side. The type comes from the bytes,
    never the name; it reaches pages only as `data:image/png|jpeg;base64,...` in an `<img>` (the CSP already allows `img-src 'self' data:`).
    SVG, GIF, HTML, executables, cut-off files: refused. The base64 is checked against its alphabet and length before decoding.
  - A profile file counts only when its `user` is the one its file name says. Names are cleaned (`webui.clean_text`) and cut on a character.
- `lib/webui/profile.js`: `window.ssProfiles` (`avatar(user, px)`, `name`, `colour`, `edit()`) and the Your profile dialog; puts an avatar in
  front of any element with `data-av-user` (now and when profiles change).
- `lib/webui/home.js`, `home.css`: the page.
- Shared files, small additive edits: `lib/webui.lua` (ACTIONS `home`, `profile`; their dispatch; `webhome.tick`), `lib/webui/index.html`
  (links home.css, profile.js, home.js after tabs.js), `lib/webui/app.js` (`li.dataset.avUser = x.user` on Who's here rows),
  `tests/test_0_60_rt_webui.lua` (a webhome stand-in so its publish count stays its own).

## Hook for the chat (rt-chat2's files, not edited)
Avatars in chat: set `data-av-user="<user>"` on a message row (optionally `data-av-size="20"`), and profile.js puts the picture in front of
it; or call `window.ssProfiles.avatar(user, 20)` and place it; `ssProfiles.name(user)` gives the display name. Nothing else is needed.
Wished-for chat functions (none edited): a to-do assignee (`for = user`) set by `add_todo` (Home already honours `d["for"]`); `chat.mentions`
taking several names (display name, @everyone) so Home and the chat agree on what a mention is; a cheap studio-wide "newest messages" read so
Home needn't read the whole studio's chat every 15 s.

## Tests
- `tests/test_0_60_rt_home.lua`: picture checks (PNG/JPEG good; SVG, GIF, HTML, MZ, cut-off, oversized, zero-size, no frame header, bad segment
  length refused), base64 both ways and strict, names, colours; saving your own profile (and a refusal keeping the old picture; PNG replacing
  JPEG; a write that fails reported, not raised); reading bandmates' (an SVG named .png, an oversized file, a file speaking for someone else's
  name: no picture / ignored); Home's pure parts (stamps, newest-k, mix and stems names, mentions, chat model, takes) and a build over a
  stand-in studio (order, last change, automatic changes skipped, online with rooms and away, takes, bounces, mentions by display name, unread
  with and without the chat's index); opening (unknown project or room refused, switch to an open tab, else Open session); the tick (Home only
  while shown, profiles always, a profile change answered at once); the page files (links, order, no HTML from data, no eval, nothing remote).
- Chromium against a stand-in server (desktop 1280, phone 390, docker 300, light and dark): layout, avatars in Who's here, the profile dialog
  (a picture re-encoded to a 1.8 KB JPEG and sent; an SVG refused in the page; name and colour sent and shown), Open sends the action.

## Check in REAPER (real computers)
1. Open the web UI (panel's Web UI, docked and in a browser): Home shows the studio's projects with the right "last changed by / what / when"
   against each project's History; the one you're in says "you're here".
2. With a bandmate in another project: they show in Online now and on that project's row; recording shows the red On air bar.
3. Open on another project: it opens in a new tab as the panel's Projects page does (Live sync starts there); on a project already open in a
   tab: Switch to it brings that tab forward.
4. Your profile: pick a phone photo (JPEG) and a PNG: the picture shows on Home and in Who's here on both computers within ~10 s plus
   Syncthing's time; a display name and a colour too (the colour also changes drawings, as Setup > Options does).
5. Write "@<your name> hi" from a bandmate: it shows under Mentions, the Home tab gets a count; with Notify me allowed and the browser in the
   background (on 127.0.0.1), a notification appears.
6. Put "@<your name>" in a to-do: it shows under To-dos for you.
7. Render a mix and stems: they show under Mixes and stems with who and when.
8. Tick cost with Home open on a big studio (many projects, a room with thousands of events): `tests/reaper/rt_perf.lua`.

## Untested / limits
- Not run in REAPER; the Open path from a page runs Open session from Live sync's defer (as the panel's action runner does) and may show its
  usual boxes on that computer, also when a phone with the studio's token asks.
- Notifications don't work over the phone link (plain http on a Tailscale name is not a secure context).
- Mentions are found in the studio's three scopes (Studio, projects, rooms); DMs and channels count only through `unread_summary`.
- A room's events are re-scanned when the number of names changes (shortcut in the code: a trim plus a new change in one look waits for the next).
- Takes recorded before mirror sync (old take manifests) aren't listed.
- "Mixes and stems" times are the renderer's local clock read on this computer's time zone.

## Review later (security)
- Profiles, like `_band/colours`, are not checked against who changed the file (Syncthing's modifiedBy, as `trust.lua` does for roles): a
  bandmate could write a profile under another member's name (file name and `user` must agree, but both are theirs to choose). Cosmetic, but a
  misleading picture/name is possible. Consider `trust.own_file_ok`.
- A picture is validated structurally, not decoded: a well-formed PNG/JPEG with hostile compressed data reaches the browser's image decoder (as
  any image on the web does). Re-encoding on the receiving side would need a decoder in Lua or the extension.
- Open from a phone link: anyone with the studio's web token can open projects on that computer (the phone acts as this computer's user, as
  for every other action).
- Reading the whole studio's chat every 15 s while Home shows costs time on big studios. What it shows follows `page_chat.read "band"`, which
  lists projects through `band.songs` (a guest's own list) plus the Studio folder (`_band/chat`, everyone's), as the panel's Studio scope does.

## Proposals (not built)
- Project cover art (a picture per project, same checks) and a per-project accent colour.
- A short status line per person ("back at 8", "mixing tonight") shown in Online now.
- Phone push for mentions through the existing alerts channel (lib/alerts.lua), opt-in per person.
- "Since you were last here" on each project row (the panel's away counts, per project), and a click-through from a mention to that chat.
- Read receipts / "seen by" on messages and to-dos (rt-chat2's area).
