# Ask to join, invite links and the studiosync:// handler (rt-invite, 2026-11-20)

James: "Ask someone to join a project while they're inside or outside reaper, one click to open and join, or invite link that opens their
reaper to - Opens their reaper to the project and studio sync". Lua tests, a stand-in server in the app's Chromium pane, and the two launchers
run by hand in a temp folder only. **Not run in REAPER or between two computers yet. No handler was installed on any computer.**

## What it does
### 1. Ask to join (someone already in the studio)
- **Web UI Home:** each bandmate in *Online now* has **Ask to join** (asks them into the project and room you're in); each project row has
  **Ask…** (pick anyone in the studio, then Ask to join) and **Link** (the project's studiosync:// link and its web fallback, copied when the
  browser allows it).
- The ask is a **direct message** from you to them (rt-chat2's DMs) with the text "asks you to join <project> (room <room>)" and a field
  `join = { song, room }`. So it goes over the direct link to their computer at once and through the shared folder behind it (Syncthing),
  exactly as a DM does, and anything that shows DMs shows it.
- **On their side:** a bar at the top of Home ("bob asks you to join Sunset Drive [Join] [Decline]"); **Join / Decline** on the message in
  the chat (rt-chat2's chat.js: one line); the panel's Home lists it with Join / Decline and the minimized box says "1 join request"; and a
  line on the studio's phone alerts ("alice asks bob to join", title the project) when the studio has alerts on.
- **Join** opens that project and room here the Home page's way (`webhome.open`: its tab if it's open, otherwise Open session in a new tab,
  which starts Live sync), and answers "is joining <project>" in the DM. **Decline** answers "can't join right now". Each request is
  answered once on that computer (ExtState `invite answered`), and can be answered for 30 minutes (`ASK_LIFE`); only the newest per person
  is listed. The asker can't answer their own; a request in a DM you're not in never shows.
- **Rate limits** (on the asker's computer, Live sync and the panel together through ExtState): one ask a minute to the same person
  (`ASK_GAP`), at most 10 asks an hour (`ASK_MAX`). Phone alerts are also held to one a minute per kind by alerts.lua.

### 2. Links (outside REAPER)
- **A member's link:** `studiosync://join?s=<studio id>&p=<project>&r=<room>` (room left out for main). Names only: nothing secret. It opens
  the project if this computer is in that studio (switching the panel's current studio to it, as the Projects page does), otherwise says
  "That link is for a studio this computer isn't in".
- **Someone new's link** (Settings > Studio > Invitations: **Copy invite link (member)** / **(guest)**, owner and admins, where an invitation
  can be made): `studiosync://join?s=<studio>&n=<name>&h=<inviter's Tailscale name>&c=<24 hex>`. The code is random (96 bits), works for a
  day at most (never past its invitation's 2 days), and once: the first computer that uses it gets it (the same computer may ask again if
  the answer was lost). Behind it sits an ordinary signed invitation (`joins.make`) made when the link was; the link itself holds no
  invitation, signature, key or Tailscale key.
  - Clicking it asks first, in REAPER: "Join the studio '<name>'? This link asks <host> to let this computer in. Only say Yes to a link from
    someone you know".
  - On Yes, this computer sends `redeem {code, device, name, reply}` on the existing join channel to the inviter's computer (Tailscale), and
    listens on `joinlink-<FNV hash of the code>` keyed with the code. The inviter's computer checks the code (known, not run out, unused or
    used by this same computer), that its invitation's record is still there (revoked links die with it), that it's still owner/admin, and
    that the reply name is on the studio's Tailscale network; then sends the signed invitation back on that channel. Refusals go to the
    log through `joins.say_refused` (paced; the code is never written). After 30 refusals in 10 minutes it ignores code asks for the rest
    of the window.
  - The joiner then does exactly what Paste join code does with an invitation (`services.join_band`, `joins.request`): from there it's the
    existing invitation path, with its record, signature, single use and refused-asks log. It asks every 10 s for 2 minutes, then gives up
    with "ask them for the invitation message and paste it with Paste join code".
- **Web fallback:** the same query on `http://127.0.0.1:<port>/join.html?...`: the web UI's own page on this computer, which shows what the
  link is (as text) and sends it to Live sync only when **Open in REAPER** is pressed; Live sync checks it exactly as a clicked link. It works
  without the handler when Live sync is running on this computer. (Localhost is a secure context; there's no https for it. A remote phone
  needs the studio's web token as for every page.)

### 3. The handler (Settings > Studio > Direct link > Invitations > "Open StudioSync links on this computer")
Installed only when ticked, taken away when unticked (`lib/urlhandler.lua`). The launcher never runs a link: it writes it as plain text to
`<home>/link/pending.txt` and starts or wakes REAPER; StudioSync's tick (from `joins.tick`, so Autostart and the panel) reads and deletes the
file within a second and checks it with `invite.parse_link`. When StudioSync's scripts folder is gone (uninstalled through ReaPack: there is
no StudioSync uninstaller), the launcher takes the handler away itself on its next click.
- **Windows:** per user, `HKCU\Software\Classes\studiosync` (URL Protocol, DefaultIcon reaper.exe, shell\open\command =
  `"%SystemRoot%\System32\wscript.exe" //B //Nologo "<home>\link\studiosync-link.js" "%1"`), written with `reg.exe add` (no admin, nothing
  machine-wide). The JScript launcher takes argument 0, keeps it only if it starts `studiosync:`, is printable ASCII without spaces and at
  most 2048 bytes, writes it, then runs `"<reaper.exe>" -nonewinst`. No cmd.exe anywhere, so `&`, `|`, quotes in a link are just text.
  Untick: the key is deleted only while its command names our launcher (someone else's `studiosync:` handler is left alone).
- **macOS:** `~/Applications/StudioSync Link.app`, an AppleScript applet built with `osacompile`, with `CFBundleURLTypes` (scheme
  studiosync), `CFBundleIdentifier com.studiosync.link` and `LSUIElement`, registered with `lsregister -f`. Its `on open location` writes
  the link through `quoted form of` and runs `open <REAPER.app>`. Untick: `lsregister -u` and that one app removed.
- **Linux:** `~/.local/share/applications/studiosync-link.desktop` (or `$XDG_DATA_HOME`), `MimeType=x-scheme-handler/studiosync;`,
  `Exec=/bin/sh "<home>/link/studiosync-link.sh" %u` (quoted per the Desktop Entry spec), made the default with `xdg-mime default`, then
  `update-desktop-database`. The launcher `printf '%s' "$1"`s the link (single-quoted paths, no eval) and starts `reaper -nonewinst`. Untick:
  the .desktop file goes only while it names our launcher.

## Files
- New: `lib/invite.lua`, `lib/urlhandler.lua`, `lib/webui/invite.js`, `lib/webui/invite.css`, `lib/webui/join.html`, `lib/webui/join.js`,
  `tests/test_0_60_rt_invite.lua`, this doc.
- Small additive edits in others' files:
  - `lib/webui.lua` (shared): `ACTIONS.invite`, its dispatch, `e.join` in `chat_model`, `invite.web_tick` at the end of the tick.
  - `lib/webui/index.html` (shared): invite.css and invite.js, before chat.js.
  - `lib/page_chat.lua` (rt-chat2): `chat.post(cfg, b, text, sc, extra)` (extra fields on a message; `text`, `user`, `time` can't be
    overridden), and a live (link) message keeps a checked `join`.
  - `lib/webui/chat.js` (rt-chat2): one line, Join / Decline on a message with `join`.
  - `lib/joins.lua`: `invite.tick` at the start of `joins.tick`; `redeem` and `token` messages handed to invite; `invite.studio_ui` under
    Invitations.
  - `StudioSync - Panel.lua`: one line on the Home page (join requests), one in the minimized box's words.
  - `tests/test_0_60_rt_webui.lua`: an invite stand-in so its publish count stays its own.
- Topic `invite`: `{ me, studio, port, people, asks = [{ scope, id, user, song, room, time }], last = { ok, text, at }, song, room }`.
  Actions on `invite`: `ask = { to, song, room }`, `answer = { scope, id, go }`, `link = "studiosync://..."`.

## Tests
`tests/test_0_60_rt_invite.lua`:
- **Parser:** member and code links; `studiosync:join?`, `studiosync://join/?`, any case, trimmed, the web fallback form; UTF-8, brackets and a
  browser's encoding read back. Refused: empty, no query, other schemes (https, javascript:), other hosts than `join`, Syncthing's
  `default` folder, missing project, duplicate or unknown keys (`token=`), bad `%` escapes, `%00` / `%0A` / CRLF, raw spaces and raw bytes
  past ASCII, `..`, `../etc`, `/`, `\`, `CON:`, a project mixed with a code, a short or non-hex code, hosts without a dot or with `..`,
  700-byte links and 250-byte names; a name keeps only plain characters (`<script>$(x)` stripped).
- **Asks over a stand-in link:** not to strangers or yourself, only known projects and rooms; the DM file in the shared folder, the link
  message to the bandmate's computer only, the alert with names only; rate limits (a minute, ASK_MAX an hour); the receiver takes the link
  copy; pending lists it (newest per person, not from DMs you're not in, not an hour-old one); Join opens it once, Decline opens nothing,
  the asker can't answer, a made-up id or the wrong scope is refused, a run-out request can't be answered; the answer is posted in the DM.
- **Links:** a member's opens the project; a second within 2 s waits; another studio's is said and opens nothing; a code for a studio you're in;
  a bad link refused in the log; someone new's: No sends nothing, Yes sends `redeem` with the code (never in an address), listening keyed with
  the code, sent again after 10 s, given up after 2 minutes with a line in the log.
- **Codes:** the link holds the code, not the invitation; kept a day at most; from outside the studio's Tailscale network refused (logged
  without the code); unknown code refused with nothing sent; the right computer gets the invitation on the code's channel; again for the
  same computer; another computer refused (single use); revoked invitation, no longer admin, run out: refused; paused after 30 refusals.
- **Joiner:** an answer nobody waits for, an oversized one, one for another studio: ignored; the right one joins as Paste join code does, once.
- **Launcher file:** an oversized file read as nothing and deleted; a clicked link read, deleted, opened.
- **Handler, per OS, on a stand-in file layer:** Windows (HKCU only, the link as one quoted argument, the launcher never builds a command from
  it, self-removal when StudioSync is gone, untick deletes only our key), macOS (quoted form of, install script quoted with an apostrophe in
  the path, URL type and lsregister, only our app removed), Linux (`$` escaped in Exec, printf, no eval, a .desktop file that isn't ours
  stays); control characters / unknown OS / no home refused; a failing step stops it and says why.
- **Pages:** invite.js before chat.js; no innerHTML / eval / remote addresses; join.html sends only on a press.
- **By hand (temp folder, fake reaper, nothing registered):** the generated Windows launcher under cscript wrote a good link and refused one
  with a space; `&calc` stayed text. The Linux launcher wrote a good link, started the fake reaper with `-nonewinst`, wrote
  `$(touch /tmp/pwn)` and backticks as text without running them, ignored an http:// link.
- **Chromium (stand-in server):** Home's bar with Join / Decline, Ask to join on a bandmate, Ask… picker, Link box, chat Join / Decline and
  "You asked them", a hostile `<img onerror>` text shown as text, join.html layout and its action; every action as expected in the log.

## Check in REAPER (real computers)
1. Two members in one studio, both with the web UI open: on Home, Ask to join on the other person. On theirs: the bar on Home, the DM with
   Join / Decline in the chat, the panel's Home row and "1 join request" on the minimized box, a phone alert if the studio has alerts.
2. Join: the project and room open in a new tab with Live sync running (or switch to the tab if open). Decline: nothing opens; the asker's
   DM shows "can't join right now". Ask twice within a minute: the second is refused with a reason.
3. Settings > Studio > Direct link > Invitations: tick "Open StudioSync links on this computer" on Windows, the Mac and Linux. Then a project's
   Link (Home > project > Link) pasted into a browser's address bar on the other member's computer: REAPER comes forward (or starts) and the
   project opens. With REAPER closed: it starts, and Autostart opens the project. Untick: the link does nothing any more (and on Windows
   `HKCU\Software\Classes\studiosync` is gone).
4. Without the handler, the "Without the link handler" address (127.0.0.1 join.html) in a browser on a computer with Live sync running:
   Open in REAPER opens it.
5. Copy invite link (member) on the owner's computer; on a computer already on the studio's Tailscale network but not in the studio (the
   LinuxBox): click it, say Yes: the log says asking, then joined, then the usual "let in by the invitation"; the owner's log names the
   computer. Click the same link from a third computer: refused ("used already") in the owner's log, nothing happens there.
6. Revoke the invitation behind an unused link in Settings: the link is refused.
7. Windows without the firewall rule on the joiner: the invitation's answer can't reach it (as with the welcome); check the log says so.

## Untested / limits
- Nothing ran in REAPER. `reaper.exe -nonewinst` with no file is assumed to start REAPER or bring the running one forward; if it opens a
  second instance on some setups, the launcher needs a REAPER action to run instead.
- A code link only works for someone already on the studio's Tailscale network (it must reach the inviter); anyone else still needs the
  invitation message (it carries the Tailscale guest key, which never goes in a link).
- On Windows the joiner hears the invitation's answer only with the direct link's firewall rule (the same limit as the welcome).
- macOS: the applet and lsregister steps are only checked as text; `osacompile` must exist (it ships with macOS). Gatekeeper may ask about the
  unsigned applet the first time a link opens. Linux: `xdg-mime`'s default stays in mimeapps.list after untick (pointing at a missing file).
- WSH (wscript) must not be disabled by policy on Windows.
- Join requests reach the panel and Home from DM files (Syncthing's few seconds); the web chat shows the link's copy at once.
- One pending link at a time (a second click before the first is read replaces it).

## Review later (security)
- **The phone alert** for a join request goes to the studio-wide ntfy channel: everyone subscribed learns "alice asks bob to join <project>"
  (names and the project's name). Make it per-person or drop it if that's too much.
- **Codes are stored in plain ExtState** (reaper-extstate.ini, this computer only) next to the invitation token, as the existing
  "joins pending" tokens are. A copy of that file within the day lets someone on the tailnet use an unused link.
- **The redeem channel is the public join channel** (its HMAC key is public): an attacker on the studio's tailnet can try codes; 96 bits plus
  the 30-refusals pause make guessing hopeless, but the pause is also a cheap way to block real link use for 10 minutes (DoS).
- **The answer goes to whatever Tailscale name the asker claims** on the studio's network (as the welcome does); the channel is keyed with
  the code, so only the code holder can read it, but a tailnet member who saw the link first wins the single use.
- **Member links open projects without asking** (a site or app can open `studiosync://join?s=<your studio>&p=<project>`): it can only open
  a project you already have, through webhome.open's checks, but it can switch your current studio and start Live sync in a new tab.
- **Join requests aren't authenticated beyond the DM** (rt-chat2's note: names aren't authenticated, DM files are readable/writable by the
  whole studio): a studio member could write a request "from" someone else. Join only opens a project you already have.
- **The launcher's pending file** is in StudioSync's home folder: any program running as you can write a link there (it gets the same checks
  and the same Yes box as a click).
- **Windows: the handler runs wscript.exe**, which some security tools flag; consider a tiny signed helper exe later.
- **`chat.post`'s `extra`** lets any caller add fields to a message; only `join` and `join_answer` are used now.
