# The whole UI in the web view: the plan (rt-uiplan, 2026-11-27)

Design only: no code changed. Brief: James's findings of 2026-11-27 (`docs/rt/findings-2026-11-27.md`), big items 1, 6, 7, 11, 13, 15, 16,
the small items "pop out" and "StudioSync icon on the web view", and the question "can History playback be viewed in REAPER itself?". James:

> UI needs to be cleaned up and moved entirely into the web view along with per device systems so it already knows if you have reaper and
> if you do what your reaper is doing/has open so that you only see things that actually make sense for your environment. Bring over the
> important and useful features from the panel as well as some things from the look, especially the button and strip, fullscreen, dock
> modes, minimizing when not in focus or better functionality for that if possible.

A clickable mockup of the navigation and the main pages: `docs/rt/ui-web-mockup.html` (one static file, opens in any browser; the web UI's own
colours from `lib/webui/style.css`, copied in so it needs nothing else). Its top row switches between the environments in section 3.

Read with: the panel (`StudioSync - Panel.lua`, `lib/page_*.lua`), the web UI (`lib/webui.lua`, `lib/webpages.lua`, `lib/web*.lua`,
`lib/webui/*`), the server (`extension/webui.cpp`) and the docked window (`extension/webui_dock.cpp`, `webui_dock_mac.mm`).

---

## 0. The plan in ten lines

1. One web UI, in REAPER (docked, floating, full screen, or shrunk to a strip or a button) and in any browser. The ImGui panel retires last.
2. Nine tabs, fewer than today's 9 panel pages + 9 Settings tabs + 10 web tabs: **Studio, Session, Project, Chat, History, Plug-ins, AI,
   Health, Settings**. Sub-tabs where a tab holds more than one thing (Project: Arrange / Mixer / Sheet / Beat; History: Changes / Versions /
   Playback / Mixes).
3. One word per idea (section 2.2): "Follow" (never Watch or View), "Project" (never Song), "Studio" (never Group or Band), "Room".
4. The page knows where it runs: this computer in REAPER, this computer in a browser, another device on the tailnet (phone, tablet,
   another computer), a browser guest. And it knows what REAPER has open and is doing from a new `env` topic.
5. Nothing is shown that can't work where you are: no window buttons in a browser, no "open the plug-in window" on a phone, no project
   pages with no project open (the Studio tab instead).
6. The Project tab opens in **View**; editing needs the **Edit** switch, and the page shows plainly that you're editing.
7. History and Restore are one tab; the time lapse and "hear it as it was" are its **Playback** sub-tab.
8. AI shows only **Split into stems** and **Audio to MIDI**.
9. Health shows hidden items on request and lets you hide or show **other scripts' messages**; its fix buttons work from the web.
10. Eleven build phases; Phase 1 is the shell (navigation, environment, names) so the others slot in, several at a time.

---

## 1. Inventory

Who: **O** owner, **A** admin, **M** member (everyone in the studio), **G** browser guest (guest link, no Tailscale), **P** a phone or
another device on the tailnet (it acts as the serving computer's own person). Verdict: **keep** (where it goes), **merge**, **rename**,
**drop**.

### 1.1 The panel's window (the look James wants kept)

| What | What it does | Who | Verdict |
|---|---|---|---|
| Title bar: logo, wordmark, close | Panel's own frame | M | **Keep**: the shell's top bar has the logo (it's the "StudioSync icon on the web view") |
| Window menu: Fill this screen, Left/Right/Top/Bottom half, Move to the next screen, Back to before | Places the floating panel | M | **Keep** as the window menu, in REAPER only (C++, section 4) |
| Dock menu: Dock at the bottom / left / right, Undock; right-click arms drag-to-dock | Dockers | M | **Keep**: same menu; drag-to-dock is REAPER's own docker behaviour for a native window, so the arming trick is **dropped** |
| Minimize to a strip / Shrink to the box (two icons) | Shrinks the panel over REAPER | M | **Keep** as window modes **Strip** and **Button** (section 4.2) |
| The box ("pill"): 22-56 px, green or red edge, a slash when sync is off, a red count of what waits, drag to move, lock, right-click menu (Open, Call window, Lock position, Make it a strip, Size, Sync and exit, Close) | Status at a glance while you work | M | **Keep**, renamed **Button**; same menu |
| The strip: logo, dot, "StudioSync · Sync on · Bo drives · 2 new messages · 1 join request · 3 edits not sent · 1 print problem · 2 suggestions" | Status in words | M | **Keep**, with two quick buttons added (mic, Follow) |
| When you click REAPER: shrinks to the tiny box / stays in front / goes behind (Look; Home's "Hide when not in use" is the same switch) | Gets out of the way | M | **Keep** as Settings > This computer > Window, one place only (Home's duplicate **dropped**) |
| System window frame switch | ImGui vs the system's frame | M | **Drop**: a native window always has REAPER's frame |
| Banner over REAPER's arrange view ("View only: Bo is driving…") | Tells you your edits will be put back | M | **Decision 6**: into the strip, or a native note from the extension |
| Text size 80-160 % | Accessibility | M | **Keep** (CSS zoom; Settings > This computer > Look) |
| Keyboard navigation | ImGui nav | M | **Drop**: the web has Tab/Enter natively |
| Theme: Dark, Light, Midnight, Warm, Custom (4 colours) | The panel's palettes | M | **Merge** with the web's light/dark: the same five as CSS colour sets |
| StudioSync button on REAPER's toolbar (on/off) | Toolbar button (`extension/reaper_menu.cpp`) | M | **Keep**; the button opens the web view (section 4.3) |
| "StudioSync keeps syncing with the panel closed" tip | First close | M | **Keep** as a one-time note |

### 1.2 The panel's top bar and bars

| What | Who | Verdict |
|---|---|---|
| Crumbs Studio / Project / Room (click: Groups, Projects, Rooms) | M | **Keep**: the shell's breadcrumb; each piece opens a switcher |
| Sync button: Sync off (red) / Start / Sync on, who is behind | M | **Keep**: the status pill |
| Update banner and button | M | **Merge** into Health and the notifications |
| Feedback (bug, idea, request: `lib/feedback.lua`) | M | **Keep**: Health > Send feedback, and the shell menu |
| Sync and exit (`lib/leave.lua`: saves, waits until someone else has it, "Safe to shut down") | M | **Keep**: shell menu, REAPER only; the waiting shown in the page |
| Live audio bar (mute, deafen, talk, level: `liveaudio.bar_ui`) | M | **Keep**: the shell's call controls (always visible while live audio runs) |
| Full-quality copy bar (`double.bar_ui`) | M | **Keep**: a notification |
| Edits not sent (put back), print problems, suggestions (Accept / Decline) | M | **Keep**: the notifications (bell), counted on the strip and button |
| Copied project: Open as a side room / Just look / Make this my project | M | **Keep**: a Session banner |

### 1.3 The panel's pages

**Groups and Projects (no project open: `lib/page_groups.lua`)**

| What | Who | Verdict |
|---|---|---|
| Your studios: open, rename, role, Show folder names, Close (owner) / Leave | M, O | **Keep**: Studio > Studios |
| Start a studio (name, keep a copy on a cloud drive), Paste join code, Join | M | **Keep**: Studio, shown when you have no studio or press New |
| Getting started checklist, Hide this | M | **Keep**: Studio, first runs |
| Closed or left: Delete my copy / Keep it, hide this | M | **Keep**: Studio > Studios, folded |
| Start Syncthing, Invite a collaborator | M | **Keep**: Health row, and Studio > People |
| Projects in folders: Open, Stage, Open a room, Move to folder, Delete my local copy, Share; New folder, New from template; Keep every project on this computer; Remove this folder | M | **Keep**: Studio > Projects (item 13, section 2.4) |

**Home (`page_home` and its sections)**

| What | Who | Verdict |
|---|---|---|
| Real time mode switch and its ways (My time, Their time, Time-sync, Jam; SonoBus or built-in) | M | **Keep**: Session > Play together, one "How we play" choice (item 12's Follow is its default) |
| Live ideas (what Time-sync heard: Keep selected / Dismiss) | M | **Keep**: Session, under Play together |
| Producer's seat (`page_hear.producer`) | M | **Keep**: Session, a row while producing |
| Who's here cards: name, state, live icons, Listen, claim chips, Follow / Following / Resume | M | **Keep**: Session > Who's here (one list, section 1.6) |
| Person menu: Change my name, Make admin / member / owner, Hand over driving, Give them control of (tracks, regions, time selection), Remove from the studio | O, A | **Keep**: the person's menu on Session and Studio > People (roles live in People) |
| Invite a collaborator / a guest / a SonoBus guest; Show who's away | O, A, M | **Merge** into Studio > People (invites) and Session (who's away) |
| Local mixing (your faders stay yours) | M | **Keep**: Session > How I hear |
| Take control, Always follow the driver | M | **Keep**: Session > Who can edit |
| Who can edit (mode: open, driver, admins, claims) | O, A | **Keep**: Session > Who can edit |
| Show dry and wet takes | M | **Keep**: Settings > This computer > Takes (item 10 may drop it) |
| Claims: Claim selected tracks / region / time selection, Release, Release all | M | **Keep**: Session > Claims (and the existing REAPER actions) |
| What just happened (feed) | M | **Merge** into History > Changes (the newest few on Session) |
| Join requests for you (Join / Decline: `invite.panel_ui`) | M | **Keep**: notifications and Session |

**Rooms (`lib/page_rooms.lua`)**: side rooms as squares, Create side room, Fork project, Come see! / Go / Not now, Bring into main, Send
selected to, Adopt as, Archive / Bring back, How rooms work. Who: M. **Keep**: Session > Rooms (the breadcrumb's room switcher opens it). Forks
also show in History > Changes ("Fork from here").

**Play/Jam (`lib/page_play.lua`)**

| What | Who | Verdict |
|---|---|---|
| Play and stop together (follow, bars behind) | M | **Merge** with the web Play page: Session > Play together, "Follow" |
| Start together: start from (cursor or region), count-in, click, skip the time selection; Play / Record / Stop together | M (who may: the room's rule) | **Keep** for now (item 12 may fold it into Follow); Session > Play together |
| Mode: Time-sync / Real time / Jam; Disconnect; Copy join link; Send my audio; NINJAM click | M | **Keep**: Session > Play together |
| NINJAM server: address, Save for the studio, Test it, Host it here, Stop server, Connect | O, A (save), M (connect) | **Split**: the studio's server in Settings > Studio; Connect in Session |
| Settings > Advanced "Show the Play/Jam tab" | M | **Drop**: the environment decides (Jam shows when the studio has a server) |

**Chat (`lib/page_chat.lua`)**: All, Messages, To-do, Links, Notes, Likes, Call; To: (room, project, studio); Web UI button; Copy phone link.
Who: M (P too). **Keep**: Chat tab (the web chat already has more: channels, DMs, files, unread). Notes and Likes join Chat's All. The Call tab
**moves** to the shell's call controls. Web UI and Copy phone link **move** to Settings > Devices ("Open on your phone": the link and a QR).

**Restore (`lib/page_restore.lua`)**: Saved versions (Save this version, Save permanently, Open it as it was before StudioSync), Kept
automation (Put mine back / Let it go), Every change newest first with filters (Clear filters), per change: Go to it, Undo this change, Restore
selected tracks to here, Restore whole project to here (driver), Open in side room, Fork from here. Who: M. **Keep**: History (section 2.5).

**Mixes (`page_restore.section_mixes` and `studio_listen`)**: Render current mix, Export stems, Dry stems, on the idle computers (Render
stems: each track / each folder, Render mix on the hub, Time selection only), Credits draft, Save as studio template, Save a copy outside the
studio, Compare two mixes (A/B); Listening page (Share, Copy, Open, Stop sharing). Who: M; the listening page O, A. **Keep**: History > Mixes;
the listening page **merges** with the web's listening links in Studio > People.

**Plugins (`lib/page_plugins.lua`, `lib/fxpick.lua`, `lib/pack.lua`)**: This project (each plug-in, who doesn't have it, stand-ins, Apply
stand-ins here, Drum maps: Make a map / Save, Plug-ins everyone has: Update the folder now, The plug-in pack), Find a plug-in (search, REAPER's
categories, only what everyone has). Who: M. **Keep**: Plug-ins tab, with the web's Try folded in.

**Settings (`page_setup`)**

| Settings tab | What's on it | Verdict |
|---|---|---|
| Health | Set up and health rows (Copy the line, Set …, Dismiss, Show dismissed, Set up everything I can), Can't hear each other? (Get Tailscale), the feed | **Keep**: Health tab |
| You | You're <name>, Change name, Your studios, ReaPersona (Open / Get), Tailscale token (Make a token, Forget, Set up the tags) | **Keep**: Settings > You (studios move to Studio; the token to Settings > Studio) |
| Look | Look card (see 1.1) and Colours | **Keep**: Settings > This computer > Look |
| Options | Parts play (MIDI and audio: prints mode), Live set: pause syncing while playing; Cloud copy (which drive, keep the studio's copy, a cloud folder per studio, Make it now) | **Keep**: Settings > This computer > Sync |
| Studio | Phone alerts (On, Copy, Send a test), Studio call (link, Save, Open), Listening page, Private live audio (Host it here / Turn off), Sync through Tailscale (only through Tailscale, Use <network>), Debug mode for everyone (Save a report, Open the _debug folder), Updates (run from the studio's folder), chained prints (hops), direct link, hub, lanes, take names, AI, shared preferences, colour parity, content, cloud modes | **Keep**: Settings > Studio (O, A change; M read). Listening page **moves** to Studio > People |
| Extras | The plug-in pack | **Move** to Plug-ins |
| Advanced | Keep selected tracks local, Try things in a side room, Prepare this project, Show advanced controls, Show the Play/Jam tab, Every StudioSync action in REAPER's Actions list, Set up the phone's secure link by itself, Ableton Link; Real time buffer, What you send; Measure my latency | **Split**: per-computer audio (buffer, what you send, latency, Link) to Settings > This computer > Audio; the rest to Settings > Advanced; "Show advanced controls" and "Show the Play/Jam tab" **drop** (the environment decides) |
| Console | StudioSync's log: Clear, Copy, Log files, Open the full console | **Keep**: Health > Log |
| Updates | Upkeep and activity, Update StudioSync, Update REAPER, About | **Keep**: Health > Updates |

### 1.4 Radial menu, toolbar, menus and actions

| What | Verdict |
|---|---|
| Radial menu at the mouse (`StudioSync - Radial menu.lua`): Undo, Redo, Restore…, Take control, Real time on/off, Chat, Ping here | **Stays native** (section 5). Restore… and Chat open the web view at History and Chat instead of the panel |
| Toolbar button (on / off / amber warning icons, lit while open) | **Keep**: opens or brings forward the web view; amber while something stopped syncing |
| Extensions > StudioSync, View > StudioSync, View > StudioSync: Web UI (docked) | **Merge** into one "StudioSync" item that opens the web view |
| The action scripts (Undo, Redo, Claim selected tracks, Keep selected tracks local, Live audio deafen / hold to talk / mute me / talkback, Local mixing, Take control, Try a bandmate's plug-in, Run plug-in on a bandmate, Offload track FX, Selected tracks play dry / wet / as chosen, Final mix, Draw, Measure guest delay) | **Keep**: they're how REAPER people bind keys; the web shows the same things as buttons |
| Status window (`StudioSync - Status.lua`) | **Drop** once Session matches it |
| Settings script (shared folder and name), Open session, Publish session, Prepare session | **Keep** (first run stays native, section 5); the web's flows run the same steps |
| New: "StudioSync: open Chat / History / Project / Session / Health" actions | **Add** (section 4.5) |

### 1.5 The web UI today

| Page (file) | What it does | Who | Verdict |
|---|---|---|---|
| Header: "StudioSync", where, connection pill, Record link, Dock / Undock, ◐ theme (`index.html`, `app.js`) | | M, P | **Keep** as the shell's top bar (logo added) |
| Home main view: Who's here (people with badges, Let edit / Revoke), Claims, asks (Release / Keep), chat column (`app.js`, `chat.js`) | | M, P | **Split**: Who's here, claims and asks to Session; chat to Chat |
| Home studio overview: hello, projects with who/when/what, online now, for you, new takes and bounces, last session, Notify me, Project view (`home.js`, `webhome.lua`) | | M, P | **Keep**: Studio |
| Ask to join, Ask…, Link, join requests (`invite.js`) | | M, P | **Keep**: Studio (project rows) and Session (people) |
| Browser guests: make a guest link, level, volume, End (`guesthost.js`) | | O, A | **Keep**: Studio > People > Guests |
| Listening links: make, public (owner), cap, revoke (`audiencehost.js`) | | O, A | **Keep**: Studio > People > Listeners |
| Profile: display name, colour, picture (`profile.js`) | | M | **Keep**: Settings > You (and clicking your own picture) |
| Project: arrange canvas, Play/Stop together, skip selection, time, View (follow), Fit, History strip and Restore this…, edit row, piano roll, automation lanes, video frames (`daw.js`, `pianoroll.js`, `autolanes.js`, `video.js`) | | M, P | **Keep**: Project > Arrange (Edit switch, section 2.6). "View" **renamed** Follow; Restore this… goes to History, not the panel |
| Mixer: strips, plug-ins and bypass, sends, monitor mix (`mixer.js`) | | M, P | **Keep**: Project > Mixer |
| Sheet: lyrics, chords, who plays what, teleprompter (`sheet.js`) | | M, P | **Keep**: Project > Sheet |
| Beat: count-in, bar.beat, section, Full screen (`visuals.js`, `beat.js`) | | M, P | **Keep**: Project > Beat (and pop-out) |
| Play: who's here, follow each other, start together, watch a bandmate (`play.js`) | | M, P | **Merge** into Session |
| History: time lapse, filters, summary, hear it as it was, compare with now, restore this point (`history.js`, `histhear.js`) | | M, P | **Keep**: History > Playback |
| AI: the studio's switch, tools, asks waiting for a yes, runs (`ai.js`) | | M (P yes only if allowed) | **Keep**, trimmed (section 2.7) |
| Try: try a bandmate's plug-in, its knobs, Print; your plug-ins (Allow / No), your tries (`tryfx.js`) | | M | **Merge** into Plug-ins |
| Health: rows read only, Check other scripts now (`health.js`) | | M, P | **Keep**: Health, with its buttons (section 2.8) |
| Video call and screen share, share bar, notes on the share (`call.js`) | | M | **Keep**: the shell's call controls, pop-out (section 4.4) |
| Drawing layer (`draw.js`) | | M, P | **Keep** on Arrange, Mixer and Playback |
| Phone app `record.html`: Record, Project, Sheet, Play (keys and pads), installable | | P | **Keep**; joins the shell as the phone layout in Phase 11 |
| Guest page `guest.html` | | G | **Keep** separate (it has its own token and limits); shell look only |
| Listening page `listen.html` | public | **Keep** as it is |
| `join.html` (a studiosync:// link in a browser) | M | **Keep** |

### 1.6 Duplicates between the panel and the web view

| Thing | Where it is now (all of these) | Becomes |
|---|---|---|
| Who's here | panel Home cards; web Home's Who's here; web Play's Who's here; web Home's "online now" | Session > Who's here (studio-wide "online now" stays on Studio, one line per person, item 9's folded computers) |
| Following someone | panel card "Follow"; web Project "View" select; web Play "Watch a bandmate" | **Follow**, in one place on Session, a Follow menu on the top bar |
| Play / Stop / Record together | panel Play/Jam; web Play; web Project's ▶ ■ | Session > Play together, and ▶ ■ on the top bar |
| History and restore | panel Restore; web Project's History strip; web History | History |
| Health | panel Settings > Health (with buttons); web Health (read only) | Health (with buttons) |
| Chat | panel Chat; web Home's chat column | Chat (plus a pop-out) |
| Invites and links | panel Invite a collaborator / guest / SonoBus guest; panel Mixes' listening page; web guest links; web listening links; web Ask to join / Link | Studio > People (invite, guests, listeners); Ask to join on people and projects |
| Projects list | panel Projects; web Home's projects | Studio > Projects |
| Call | panel Chat > Call; the call window (`lib/callwin.lua`); Home's Video call; web call section | Shell call controls + one call pop-out |
| Mixes | panel Mixes; web Home's bounces | History > Mixes (newest on Studio) |
| AI | panel Settings > Studio > AI card; web AI | AI tab (its studio switch in Settings > Studio) |
| Try | panel action and Plugins; web Try | Plug-ins > Try |
| Your name | panel You > Change name; web profile | Settings > You |
| The word "Home" | panel: this session; web: the studio overview | "Studio" and "Session"; "Home" retired |

---

## 2. Information architecture

### 2.1 The shell and the tabs

The shell is the same everywhere; what's in it depends on the environment (section 3).

- **Top bar**: the StudioSync logo (the icon James asked for; click: Studio), the breadcrumb **Studio ▸ Project ▸ Room** (each a switcher),
  the status pill (Sync on / off, Following Bo, Recording), ▶ ■ together, the call controls (Join, mic, deafen, while a call or live audio
  runs), the bell (join requests, asks, edits put back, print problems, suggestions, a red Health row), and on the right the window buttons
  (REAPER only: strip, button, dock menu, full screen) and the menu (theme, text size, Send feedback, Sync and exit, Open in REAPER / Open in
  the browser).
- **Tab row** under it (a side rail when the window is wider than it is tall and over 900 px; a bottom bar on a phone; a "More" menu for
  what doesn't fit in a docker).
- **Notifications** slide in under the top bar and stay in the bell until handled.
- **People rail** (optional, wide windows only): who's here, as on the panel's Home, collapsible.

| Tab | Holds | Shown when |
|---|---|---|
| **Studio** | Studios; Projects (folders, stages, search); What's new (takes, mixes, for you, last session); People (members and roles, invite, guests, listeners) | always (the only project-free page with Settings and Health) |
| **Session** | Who's here; Play together (Follow, Real time, Time-sync, Jam, Start together); How I hear (local mixing, each person's volume); Who can edit and Claims; Rooms; Live ideas | a studio project is open (on this computer, or on the computer serving this page) |
| **Project** | Arrange · Mixer · Sheet · Beat, with **View / Edit** | a studio project is open |
| **Chat** | Project, room, studio, channels, direct messages; to-dos, links, notes and likes, files | a studio is known (project chat needs a project) |
| **History** | Changes · Versions · Playback · Mixes | a studio project is open |
| **Plug-ins** | This project (missing, stand-ins, drum maps) · Try a bandmate's · Find a plug-in · Plug-in pack | a project is open; Try and Find on a REAPER computer only |
| **AI** | Split into stems, Audio to MIDI | the studio has AI on |
| **Health** | Checks, Log, Updates, Can't hear?, Send feedback | always; a red or amber dot on the tab |
| **Settings** | You · This computer · Studio · Devices · Advanced | always; "This computer" only on a REAPER computer |

Nine, down from the panel's 9 pages plus 9 Settings tabs and the web's 10 tabs. A phone gets five at the bottom (Session, Project, Record,
Chat, More), section 3.4.

### 2.2 Names (item 11)

One word per idea, the same on every page, button, tooltip, action name and log line. Old to new:

| Old (where) | New |
|---|---|
| Song (web code, page titles), "the song" | **Project** |
| Group (panel code), Band (old files) | **Studio** |
| Home (panel: this session) | **Session** |
| Home (web: the studio overview), Projects (panel) | **Studio** |
| Here (web) | Session > **Who's here** |
| Play/Jam (panel), Play (web), Play and stop together, Start together | Session > **Play together** |
| Watch a bandmate (web Play), View (web Project), Follow (panel) | **Follow** / **Following** / **Stop following** |
| Restore (panel), History (web), Song history | **History** |
| Mixes (panel), bounces (web Home) | History > **Mixes** |
| Side room | **Room** (a fork is "a copy to try things", Fork stays as the button word) |
| Driver, drive, Take control | **In control** / **Take control** (decision 1: or keep "driver") |
| Claim | **Claim** (kept: short and already in REAPER actions) |
| Dismiss (Health) | **Hide** (and **Show hidden**) |
| Box, pill | **Button** |
| Strip | **Strip** |
| Web UI, the panel | **StudioSync** (one UI) |
| Try (tab) | Plug-ins > **Try a bandmate's** |
| Hop, live hop, offload | **Run on a bandmate's computer** (button word "Run on…") |
| Wet / dry, prints | **As recorded (printed)** / **Through my plug-ins (live)** (decision with item 10) |
| Settings > Options / Advanced / Extras | Settings > **This computer** / **Advanced**; Extras moves to Plug-ins |

Rule for every agent: a new label is a verb for a button ("Open", "Follow Bo", "Restore to here"), a noun for a tab, and says what happens,
in James's plain style. Phase 1 puts this table in `lib/webui/shell.js` as the one label map pages use.

### 2.3 The main jobs, step by step

**Join a studio.** An invite link (studiosync://, or `join.html` in a browser) or a join code → Studio shows "Join <studio>?" with who invited
you → Join → Studio > Projects lists its projects. With no studio yet, Studio says "Start a studio" or "Paste a join code" (the panel's
Groups page, as the web). A browser guest never sees this: their link opens `guest.html` for one project and room.

**Open or prepare a project.** Studio > Projects → a project card → **Open** (on a REAPER computer it opens in REAPER, or switches to its
tab; from a phone it asks the serving computer to open it, as Home does now). A project open in REAPER that isn't in a studio yet shows a
banner on Studio: "This project isn't shared: **Share with <studio>**" → the Prepare checklist (lanes, WAV/FLAC, names, media) in the page →
Publish. While a big project loads, the page says "Opening Cross Test…" and greys every action (item 14) until Live sync says it's ready.

**Play or record together.** Session > Play together → one choice, "How we play": **Follow** (default: press play, stop or record in REAPER
as usual and everyone following goes with you; each records their own armed tracks), **Real time** (hear each other now), **Time-sync** (in time,
a bar or two late), **Jam** (NINJAM). Count-in and click sit beside it. ▶ ■ on the top bar work from any tab. (Item 12's redesign of Record
together lands here without moving anything.)

**Review history.** History > Changes (what changed, who, when; Undo this change; Restore to here) → Versions (saved versions) → Playback (the
time lapse, Listen to this point, Compare with now) → Mixes (renders and stems, A/B). The Project tab's "Show changes" overlay links here.

**Manage people.** Studio > People: members with roles (Make admin, Make owner, Remove), Invite a collaborator, Guests (browser guest links),
Listeners (listening links, Public listening for the owner), join requests. In a session, a person's menu on Session: Follow, Give control of
tracks / regions / time, Let edit here, Ask to join.

**Fix problems.** The Health dot (red: needs fixing, amber: worth a look) on the tab, the strip and the toolbar button → Health → each row's
own button (Set up, Fix, Check again, Copy the line) → Can't hear each other? → the Log (Copy, Log files) → Send feedback.

### 2.4 Project organisation (item 13)

Studio > Projects, built on what `page_groups.lua` and `webhome.lua` already keep (folders, stages, who/when/what):

- **Views**: Recent (default: last worked on first, with who and what), Folders (the studio's folders, as the panel's), Stage (Idea, Writing,
  Tracking, Mixing, Done: `extras.stage`).
- **Search** over names, folders, people.
- **A project card**: name, stage, folder, who worked last, when, what ("Bo added 3 takes"), who's in it now, rooms, unread count; buttons
  Open, Ask… (someone to join), Link; a menu with Stage, Move to folder, Open a room, New from this (template), Delete my local copy, Archive.
- **New**: New project (empty or from a studio template), New folder; "Share this project" when REAPER has an unshared one in front.
- **Pinned** projects (per person) and **Archived** (folded at the end): new, a small file per person (`<root>/_band/pins/<user>.json`, one
  writer, as the chat).
- **Keep every project on this computer** stays a per-computer switch here.

### 2.5 History and Restore as one tab (item 7)

| Sub-tab | From | What's on it |
|---|---|---|
| **Changes** | panel Restore's "Every change", web Project's History strip | Every change, newest first, with filters (person, kind, track, date); per change: Go to it, Undo this change, Restore selected tracks to here, Restore the whole project to here, Open in a room, Fork from here. The panel's "What just happened" is its newest few. Kept automation (Put mine back / Let it go) at the top while any waits |
| **Versions** | panel Restore's Saved versions | Save this version (name, Save permanently), the list, Open it as it was before StudioSync |
| **Playback** | web History, `histhear.js` | The time lapse (Play, speed, scrubber, sessions strip, filters, summary), and Hear it as it was: Listen to this point, Compare with now (A/B), Restore this point, plus **Play through REAPER** and **Open this point in REAPER** (section 5.2) |
| **Mixes** | panel Mixes, web Home's bounces | Render current mix, Export stems (dry stems), on the idle computers (stems per track or folder, mix on the hub, time selection only), Compare two mixes (A/B), Credits draft, Save as studio template, Save a copy outside the studio; every mix and stem with who and when |

Restores confirm **in the page** with what will change (histhear already does: `histhear.ASK_FOR`), not in a REAPER box, so a phone can do it;
the server keeps today's rules (whole project: the person in control only; tracks: each object's own rules).

### 2.6 The Project tab: looks and edits like the real project (item 15)

- **View / Edit switch** at the left of the Project bar, **View** each time the tab opens (decision 3). In View, a click selects, a drag
  scrolls, a wheel zooms, a double-click opens the piano roll read-only; nothing is sent. In Edit, the bar and the arrange get an orange
  frame and "Editing: changes go to everyone" until you switch back. Edit greys out with why ("Bo is in control", "View only in this room")
  when the room wouldn't take your edits anyway. After 5 minutes without an edit it goes back to View and says so.
- **The page sends `edit: true`** with every edit action, and `lib/dawedit.lua` drops an edit without it: a stale tab can't edit by accident.
  (A UI safety, not a security check: claims and permissions are unchanged.)
- **Looks like REAPER**: the project's own track colours, heights, folder indents, item colours and names, take lanes, fades, markers and
  regions as REAPER draws them, the ruler in the project's time format, the grid, selection as REAPER's, the play cursor and edit cursor,
  everyone's cursors in their colours. A "Follow" menu on the bar (item 5).
- **Sub-views**: Arrange (default), Mixer, Sheet, Beat. Each can pop out (section 4.4).
- **Overlays**: Show changes (the old History strip, linking to History), Drawings, Claims.

### 2.7 AI: only stems and audio to MIDI (item 6)

The AI tab shows two tools: **Split into stems** (demucs) and **Audio to MIDI** (Basic Pitch), each with where it runs, the ask, the yes and
the runs list as now. Lyrics, Mix feedback, Session recap and Take name ideas are **hidden**, not deleted (`ai.FEATURES` stays; a
`ai.SHOWN = { stems = true, midi = true }` filter in the topic). The studio's AI switch and each tool's path move to Settings > Studio and
Settings > This computer; the chat endpoint fields are hidden while no chat feature shows.

### 2.8 Health (item 16)

- Rows as now, red first. **Show hidden (n)** shows the rows you hid (the panel's "dismissed"), each with **Show again**; **Hide** on an
  amber row.
- **Other scripts' messages** (the rows `lib/compat.lua` adds: scripts known to clash, "something else changed what StudioSync wrote"):
  a switch **Show messages about other scripts**, on by default, with the count when off. Red compat rows always show.
- **The row's buttons work here**: Set up, Copy the line, Check again, Set up everything I can, Update StudioSync, Update REAPER (each sends
  `{topic:"health", act:<row id>}`; `page_health.lua` runs the same function its ImGui button runs). On a phone, buttons that need this
  computer's desktop (installers) say "On James-Main" and run there.
- **Log** (was Console), **Updates**, **Can't hear each other?**, **Send feedback** as sub-tabs.

### 2.9 Settings

- **You**: display name, colour, picture (the profile), your studios' roles (read).
- **This computer** (REAPER computers only): Look (theme, text size), Window (when REAPER has the focus, start as, toolbar button), Sync
  (parts play, live set, cloud copy), Audio (talk mic input, real time buffer, what you send, measure my latency, Ableton Link), Takes (dry and
  wet), AI tool paths.
- **Studio** (O, A change, M see): every card of today's Settings > Studio, plus the NINJAM server, the Tailscale token, AI on/off.
- **Devices**: open on your phone (link, QR, set up the secure link), this computer's name on the tailnet, item 9's "my computers" when
  it lands.
- **Advanced**: every StudioSync action in REAPER's Actions list, keep selected tracks local, debug.

---

## 3. Environment awareness

### 3.1 How the page knows its device (Phase 1, no C++)

Everything needed is already there; the page works it out at start (`lib/webui/shell.js`, `window.ssEnv`):

| Test | Means |
|---|---|
| `window.chrome.webview` or `window.webkit.messageHandlers.studiosync` exists, and `?host=docked` or `?host=floating` | **In REAPER** (the docked/floating view, `webui_dock.cpp` sets `?host=`) |
| `location.hostname` is `127.0.0.1` or `localhost` and not in REAPER | **This computer, in a browser** |
| any other host (the computer's tailnet name, a `tailscale serve` https name), with the studio's token cookie | **Another device on the tailnet**: acts as the serving computer's person (`webpages.lua`'s rule), and can't reach this REAPER's windows |
| `guest.html` with `?g=` | **Browser guest** (own page, own limits: unchanged) |
| `listen.html` | **Listener** (unchanged) |
| `matchMedia('(pointer: coarse)')` and the width; `display-mode: standalone` | **phone** (under 700 px), **tablet**, or **desktop**; installed phone app |

The server already tells local from remote for every request (`webui.cpp`'s `local`, used for `/api/mix` and `StudioSync_WebUIPollHere`),
so Lua can refuse what a remote page mustn't do; the page's own test only decides what to show.

"Do you have REAPER?" for a remote device: the page can't see the device's own REAPER (a fetch to its 127.0.0.1 from a tailnet page meets
Chrome's local-network rules). So a remote desktop page shows a one-line hint: "On a computer with StudioSync? Open it from REAPER there for
everything." (Item 9's "my computers" can later name that computer.)

### 3.2 What REAPER has open and what it's doing: the `env` topic

Today the topics exist only while a **studio project is in front**: `webui.tick` returns early without `b.song` (and only the front tab's Live
sync publishes). So with no project, or a non-studio project in front, the page has nothing and says "Live sync isn't running". New:

`env` (built by new `lib/webenv.lua`, published at most once a second, only when it changes):

```
{ v = 1, ver = StudioSync version, ext = extension version, computer = this computer's name, user = cfg.user,
  front = { name, path?, studio?, project?, room?, shared = bool, loading = bool, live = bool (Live sync running for it) },
  tabs = { { name, studio?, project?, room?, live } },          -- every open project tab (EnumProjects), names only
  transport = { playing, recording, paused, pos },               -- the front tab's play state
  studios = { { name, role } }, studio = the front tab's studio (or the last used),
  health = "red" | "yellow" | nil, notes = n waiting (bell count) }
```

Who publishes it:
- **Live sync**, in `webui.tick`, while its tab is in front (an additive line beside the presence build).
- **Autostart**, when no Live sync runs in front (no studio project, or none open): `env` plus the Studio tab's lobby data (studios, the
  current studio's projects: the panel's lobby). Autostart starts the server itself when needed (`webui.start` with the last studio's cfg;
  the extension's dock action already starts it with no secret, this computer only).
- **Actions** while no Live sync is in front: Autostart polls `StudioSync_WebUIPoll` only when the front tab has no fresh Live sync heartbeat
  (`live <proj>` ExtState), so the two never poll at once. A poll takes the action off the queue, so it can't be left for the other script:
  both share one router module (`lib/webroute.lua`) that knows every topic, and whoever polls runs it (a project topic with no project in
  front is answered "no project open"). Today `webui.parse_action` drops an unknown topic silently; the router logs it instead.
  (Decision 9: or a per-topic poll in the extension, `StudioSync_WebUIPollTopic`, which is cleaner and needs C++.)

### 3.3 Item 14: loading

`front.loading` is true from the moment a studio project starts opening until Live sync's first full look is done (Live sync sets a
`loading <proj>` ExtState at start and clears it after its first pass; Autostart reports it while Live sync isn't up yet). While it's true the
page shows "Opening <project>… (n tracks)", and Project, Mixer and every action button are disabled. This doesn't fix the crash itself (item
14 is its own task) but stops the web view from adding clicks while REAPER is busy.

### 3.4 What each environment sees

| | In REAPER (this computer) | Browser on this computer | Another device on the tailnet | Browser guest |
|---|---|---|---|---|
| Window buttons (strip, button, dock, full screen, pop out as REAPER windows) | yes | no (Open in REAPER instead; pop-outs are browser windows) | no | no |
| Tabs, no project open | Studio, Chat (studio), Health, Settings | same | Studio, Chat, Health | (guest page) |
| Tabs, studio project open | all nine | all nine | Studio, Session, Project, Chat, History, Health; Plug-ins read only; AI asks only (a yes counts only where allowed); Settings > You only | guest page: the mix, record, chat |
| Project | View / Edit | View / Edit | View / Edit (touch rules: only what's selected moves, as now) | no |
| Open a plug-in window, Run on a bandmate, Try, Find a plug-in | yes (opens in REAPER) | yes (opens in REAPER) | no (Try's knobs yes, while the computer runs it) | no |
| Screen share | REAPER's window (in the view) | the browser's picker | no | no |
| Video call | yes | yes | only on a secure page (the `tailscale serve` https link) | no |
| Record a take | REAPER does | REAPER does | the phone's Record (phone app) | the guest page |
| Settings > This computer, Log, Sync and exit | yes | yes | no | no |
| Unshared project in front | "Share with <studio>" banner | same | "James-Main has an unshared project open" (no button) | no |
| Phone layout (bottom bar: Session, Project, Record, Chat, More) | no | no | under 700 px wide | already |

---

## 4. In REAPER: the view, the button and the strip

### 4.1 What exists

`extension/webui_dock.cpp` (Windows WebView2, Linux WebKitGTK; macOS in `webui_dock_mac.mm`) opens one native window with the web view,
docked (`DockWindowAddEx` with ident `studiosync_webui`, REAPER remembers the docker) or floating (place in ExtState `web ui rect`), a
toggle action "StudioSync: Web UI (docked)" (`STUDIOSYNC_WEBUI_DOCK`, ticked while open, in View), `StudioSync_WebUIDock(mode)` for scripts,
keys passed back to REAPER (`key:<vk>:<mods>`), and one page message, `dock`, that recreates the window docked or floating. There's no
full screen, no strip or button, no focus handling, one window only, and no window icon.

### 4.2 Window modes (James: the button and strip, full screen, dock modes, minimizing)

One web view, never destroyed while StudioSync is open (a call, a share, a try or a playback in the page keeps going whatever the window
does). The window changes shape; the page draws what fits:

| Mode | The window | The page draws |
|---|---|---|
| **Docked** | in a REAPER docker; Dock at the bottom / left / right (Lua: `Dock_UpdateDockID("studiosync_webui", n)` and `tools.move_docker`, then reopen: no C++ needed) | the shell, compact nav (a "More" menu) when narrow |
| **Floating** | its own window over REAPER, place remembered; Window menu: Fill this screen, halves, Move to the next screen, Back to before | the shell |
| **Full screen** | the whole monitor it's on, no frame; Esc or the button leaves | the shell; a big Beat or Project is the obvious use |
| **Strip** | a thin bar (about 380 × 36), no frame, pinned inside REAPER's window where you drop it | logo, status dot, the status words (sync, who's in control, following, unread, joins, edits not sent, print problems), mic, Follow; click opens |
| **Button** | a square (22 / 28 / 40 / 56 px), no frame | logo, green or red edge, a slash when sync is off, the count badge; click opens; right-click: the panel box's menu |

**When REAPER has the focus** (Settings > This computer > Window; floating only):
- **Shrink to the strip** (proposed default; the panel's default was the box) or **Shrink to the button**: when you click a REAPER window
  the view covers, as the panel's `ui.should_hide` rule (another app, a dialog, a menu, or a window it doesn't cover leave it open); it comes
  back on a click, the toolbar button, an action or a notification that needs you (a join request, a red Health row).
- **Stay in front** (as a REAPER tool window).
- **Go behind REAPER**: a window with no owner, so REAPER's main window can cover it; the toolbar button or Alt+Tab brings it back. (The panel
  couldn't do this on ReaImGui 0.10; the extension can.)
- **Fade** (new, decision 2): stays where it is at 25 % opacity while REAPER has the focus, full again under the mouse. Useful for watching the
  Beat or Following while playing.

### 4.3 The toolbar button and the icon

- The toolbar button (`reaper_menu.cpp`, already added through `AddCustomMenuOrToolbarItem` with on / off / amber icons) runs the web view's
  toggle instead of the panel script when the web UI is the UI (an ExtState `ui` = `web`, decision 5 sets the default). Lit while the view is
  open in any mode; amber while something stopped syncing (unchanged).
- The **icon**: `lib/webui/icon.svg` (a copy of `docs/logo/studiosync-small.svg`) as the page's favicon and the top bar's logo; the phone app's
  icons already exist; the native window's title-bar and taskbar icon from the same artwork (Windows: an `.ico` in the extension's resources,
  `WM_SETICON`; macOS: the window has none; Linux: `gtk_window_set_icon` isn't reachable through SWELL, so none).

### 4.4 Pop-out windows (small item "pop out")

What pops out: **Chat**, **Call** (video tiles and the call controls), **Beat**, **Sheet** (teleprompter), **a plug-in you're trying**
(Try's knobs), **a screen share you're watching** (item 2), **Mixer**.

- The page opens `index.html?pop=chat` (the shell's route: one page, no tab row, a "back into the main window" button) with `window.open`.
- **In a browser** that's an ordinary popup window.
- **In REAPER** the view's new-window request is caught (WebView2 `NewWindowRequested`, WKWebView `createWebViewWithConfiguration`, WebKitGTK
  `create`) and the extension opens a second native window of the same kind, with its own ident (`studiosync_webui_pop_chat`), so each
  pop-out docks, floats or goes full screen on its own and REAPER remembers where. Up to 6; closed with the main one at exit.
- One call per computer: pages on the same computer agree through a `BroadcastChannel('studiosync')` which one holds the call (the pop-out,
  if there is one); the others show its controls and send presses to it.

### 4.5 Opening it from REAPER's actions

- **StudioSync: open** (the toolbar's action) opens the view where it was (docked, floating, full screen) or brings it forward; again
  shrinks it to the chosen strip or button (the panel's toggle did the same).
- New small action scripts **StudioSync: open Session / Project / Chat / History / Health / Settings**: each publishes a `nav` topic
  `{ page, sub, at }` and calls `StudioSync_WebUIDock(1)`; the page goes there when `at` is fresh (under 5 s). The radial menu's Chat and
  Restore… do the same instead of `band.panel_do`.
- Notifications that need you (a join request, "asked for your plug-in") can bring the view back from the strip or button: a `nav` with
  `wake = true`.

### 4.6 C++ or web

| Needs C++ (`webui_dock.cpp`, `webui_dock_mac.mm`, `webui_dock.h`) | Web or Lua only |
|---|---|
| Full screen (save the frame, size to the monitor, back) | The shell, tabs, names, environment, every page |
| Strip and button shapes: frameless, sized, kept inside REAPER's window, drag to move | What the strip and button show (the page, told its mode) |
| Focus: losing it to a REAPER window the view covers (WM_ACTIVATE + the panel's cover test; NSWindow's resign-key on macOS) | The rule's setting, the page's behaviour |
| Go behind REAPER (unowned window), Fade (layered window alpha / NSWindow alphaValue) | Which mode to use |
| Pop-out windows (new-window requests, a window table instead of one `g_hwnd`) | The `?pop=` route, the call owner |
| Messages page ↔ window: page sends `win:full`, `win:strip`, `win:button`, `win:float`, `win:dock:<side>`, `win:fullscreen`, `win:menu`; window sends `{"win": mode, "focus": bool}` to the page (`PostWebMessageAsString` / `evaluateJavaScript`) | Docking to a side (`Dock_UpdateDockID` + `tools.move_docker` in Lua) |
| The window icon | The favicon and the logo |
| The toolbar button's command (`reaper_menu.cpp`) | The `nav` topic and the open-page actions |

All C++ lives in Phase 8, one agent round; James builds and releases the extension.

---

## 5. What stays REAPER-native, and History playback in REAPER

### 5.1 What stays native, and why

| Stays | Why |
|---|---|
| **Live sync, Autostart** (the engine, Lua) | The web UI is a view of it; nothing moves out of Lua |
| **The radial menu** (ImGui at the mouse) | It pops up under the mouse in a few ms on a key, over the arrange view; a web window can't open that fast or that close to the pointer. Its Chat and Restore… go to the web view |
| **REAPER actions** (Undo, Redo, Claim, Live audio keys, Take control, play dry / wet…) | Key bindings are REAPER's way; the web shows the same things as buttons |
| **Plug-in windows, the drawing over REAPER's own arrange view** (`StudioSync - Draw.lua`) | They're REAPER's windows; the web draws on its own Project, Mixer and Playback |
| **First run** (`StudioSync - Settings.lua`: shared folder and name) | Before a studio exists the server has no token and no studio; a REAPER box is simplest |
| **The banner over the arrange view** (for now) | Until decision 6: it sits on REAPER's arrange, where a web window can't |
| **The panel**, as "Classic panel" | Until every page here matches; then removed (Phase 11) |

### 5.2 Can History playback be viewed in REAPER itself?

**Yes, three ways, two of them nearly free:**

1. **The History tab in REAPER's docked view** already is "in REAPER": the time lapse, Listen to this point and Compare with now all run
   in the web view. Docked or full screen, it looks like part of REAPER. What's wrong today is the sound: the web view plays through the
   system's default output (WebView2 and WKWebView have no access to REAPER's audio device), so with an ASIO interface the preview may come
   out of the wrong speakers.
2. **Play through REAPER** (new, small): `histhear.lua` already renders the point to a file in a background REAPER. Playing that file through
   REAPER's own output needs SWS's preview player (`CF_CreatePreview`, `CF_Preview_Play`), which `lib/extras.lua`'s mix A/B already uses. The
   Playback sub-tab gets a "Play through REAPER" switch (on by default when SWS is there); the page's scrubber drives the preview's position.
   No project change, nothing synced.
3. **Open this point in REAPER**: the point as a project of its own in a new tab, read-only, so you see it in REAPER's own arrange and mixer
   with your plug-ins and hear it through your monitoring. `histhear.rebuild` already makes exactly this copy for its render; saving it as
   `<project> (as it was <date> <time>).rpp` in this computer's temp folder and opening it in a new tab (with no Live sync, so nothing goes
   out) is a few lines. The page labels the tab "Looking at <time>: not synced" and offers Close.

What isn't possible: the animated time lapse drawn on REAPER's own arrange view (REAPER draws its arrange; scripts can't replay history on it
without changing the project). Opening the point as its own tab (3) is the REAPER-native equivalent.

---

## 6. The build plan

Rules for every phase: the agent rules (`docs/rt/agent-rules.md`); its own doc `docs/rt/rt-ui<n>.md`; Lua tests in
`tests/test_0_60_rt_ui<n>.lua`; page tests as a headless Chromium run against a stand-in server, the pattern of `tests/rt_p14_browser.mjs`
(`tests/rt_ui<n>_browser.mjs`, fake devices only). Shared files take only small additive edits: `lib/webui.lua` (one `ACTIONS` line and one
tick line per new topic), `lib/webui/index.html` (one `<script>`/`<link>` per new file), `lib/page_health.lua`. Every phase keeps the panel
working: the web UI gains, the panel loses nothing until Phase 11.

### Phase 1: the shell (first, alone)

Navigation, environment, names, so the rest slot in.
- **New** `lib/webui/shell.js`, `lib/webui/shell.css`, `lib/webui/icon.svg`, `lib/webenv.lua`.
- **Changed** `lib/webui/index.html` (the top bar markup, logo, favicon, load shell first), `lib/webui/tabs.js` (`ssTabs.add(name, label, page,
  onShow, { order, envs, need })` with subs: `ssTabs.sub(tab, name, label, el)`; the label map; deep links `#history/playback`; `?pop=`; the
  nav topic; a "More" menu when narrow; the phone bottom bar), `lib/webui/daw.js` (only: stop making the tab bar, register Project and its
  Arrange through ssTabs), `lib/webui/app.js` (the header's own bits move to shell.js), `lib/webui.lua` (publish `env` and handle `nav`:
  additive), `lib/webui/style.css` (the top bar).
- Tabs exist with today's pages under the new names (Home's overview as Studio, Here + Play as Session, Try under Plug-ins as a sub,
  Mixer / Sheet / Beat as Project subs, History as History > Playback); placeholders say "coming" for what isn't built.
- **Tests**: `tests/test_0_60_rt_ui1.lua` (`webenv` model, label map), `tests/rt_ui1_browser.mjs` (for each environment: which tabs, the
  names, deep links, phone bar, pop route; no tab without its `need`).
- Size: one round (about 900 lines, mostly JS).

### Wave A (after Phase 1; these run at the same time: no file in two of them)

**Phase 2: Studio tab and the lobby.** `lib/webhome.lua`, `lib/webui/home.js`, `lib/webui/home.css` (become the Studio tab: Studios, Projects
with views/search/stages/pins/archive, What's new), new `lib/weblobby.lua` (studios, start/join a studio, the projects of the studio with no
project open), new `lib/webroute.lua`, `StudioSync - Autostart.lua` (publish `env` and the lobby while no Live sync is in front; poll through
webroute then), `lib/webui/invite.js` (project rows' Ask… and Link on the new cards). Tests: `test_0_60_rt_ui2.lua` (lobby model, pins file,
route rule), `rt_ui2_browser.mjs`.

**Phase 3: History tab.** `lib/webui/history.js`, `history.css`, `histhear.js`, new `lib/webrestore.lua` (Changes and Versions: the list,
filters, Undo this change, Restore to here, Save this version, Open as before StudioSync, kept automation; through `recall`, `mirror`, `sync`
as `page_restore.lua` does; confirms in the page), `lib/histhear.lua` (Play through REAPER with `CF_Preview`, Open this point in REAPER),
`lib/webhistory.lua`, new `lib/webmixes.lua` (History > Mixes: render, stems, idle computers, A/B, credits, template, copy outside). Tests:
`test_0_60_rt_ui3.lua`, `rt_ui3_browser.mjs`.

**Phase 4: Health and Log.** `lib/webui/health.js`, `lib/webpages.lua` (the health half only), `lib/page_health.lua` (a `web_act(id)` that runs
a row's button: additive), `lib/compat.lua` (mark its rows as `other`), new `lib/weblog.lua` (the log for the page, Copy, Log files on this
computer only). Show hidden, Other scripts' messages, Can't hear?, Updates, Send feedback (`lib/feedback.lua`'s save). Tests: `test_0_60_rt_ui4.lua`
(which rows show with each switch, `web_act` refusing unknown ids and remote-only-unsafe ones), `rt_ui4_browser.mjs`.

**Phase 5: AI trim.** `lib/webui/ai.js`, `lib/ai.lua` (`ai.SHOWN`; the topic carries only those), panel's AI card hides the rest. Tiny: pair it
with Phase 4's agent if one round has room. Tests: extend `tests/test_0_60_rt_ai*.lua` (only stems and midi in the topic; an ask for another
id refused).

**Phase 8: the REAPER window (C++).** `extension/webui_dock.cpp`, `webui_dock.h`, `webui_dock_mac.mm`, `extension/reaper_menu.cpp` (the
button's command), a resource file for the icon. Modes (full, strip, button, full screen), focus rule, go behind, fade, pop-out windows,
page ↔ window messages, the icon. Tests: `tests/webui_dock_test.cpp` (message parsing, mode rects kept inside REAPER's window and on a
monitor, the cover test as a pure function); native build; Linux and Mac compile in CI. James builds, raises EXT_VERSION and checks in
REAPER.

### Wave B (after Wave A's Phase 2 for the router, and Phase 8 for window-aware parts)

**Phase 6: Session tab.** `lib/webui/play.js` (becomes Session: Who's here with a person menu, Play together, How I hear, Who can edit, Claims,
Live ideas), `lib/webui/app.js` (presence drawing moves to Session), new `lib/websession.lua` (who can edit, claims, take control, local mixing,
give control, roles from the person menu, live ideas: through `sync`, `claimask`, `grants`, `groups` as the panel does), new
`lib/webrooms.lua` and `lib/webui/rooms.js` (Rooms). Leaves `webpages.lua`'s play half as it is (it reads through it). Tests.

**Phase 7: Project tab and the Edit switch.** `lib/webui/daw.js`, `daw.css`, `pianoroll.js`, `autolanes.js`, `mixer.js`, `sheet.js`,
`visuals.js` (register as Project subs; pop-out ready), `lib/dawedit.lua` and `lib/dawmidi.lua` (refuse edits without `edit: true`),
`lib/dawview.lua` (what REAPER-likeness needs that the topic lacks: heights, lanes, ruler format). Tests: extend `rt_p14_browser.mjs`'s pattern
(`rt_ui7_browser.mjs`: View sends nothing; Edit sends with the flag; back to View after idle), `test_0_60_rt_ui7.lua`.

**Phase 9: Chat and pop-outs (web side).** `lib/webui/chat.js`, `chat.css`, `lib/page_chat.lua` (the read state the findings' "unread after
read" bug needs, if not fixed elsewhere first), `lib/webui/call.js` (the call controls in the top bar, the one-call-per-computer channel),
`lib/webui/call.css`. Notes and Likes in All. Tests.

**Phase 10: Plug-ins and Settings.** `lib/webui/tryfx.js`, `tryfx.css`, new `lib/webplugins.lua` (this project's plug-ins, stand-ins,
drum maps, everyone-has, pack, find: from `page_plugins`, `fxpick`, `pack` models), new `lib/websettings.lua` and `lib/webui/settings.js`
(You, This computer, Studio, Devices, Advanced: each through the module's own getters and setters; a module that has only an ImGui
`studio_ui` gets a small `model()`/`set()` beside it, additive). Too big for one round: **10a Plug-ins**, **10b Settings** (two agents, no
shared files).

### Wave C (last)

**Phase 11: the switch.** `StudioSync - Autostart.lua` opens the web view's strip at start instead of the panel's box; the toolbar button and
the menus point at the web view; `StudioSync - Radial menu.lua` sends Chat and Restore… to the web; new open-page action scripts; the panel
becomes "Classic panel" behind a setting (decision 5); `record.html` joins the shell as the phone layout; `guest.html` takes the shell's look.
Tests: the whole browser suite again, `test_0_60_rt_ui11.lua` (which UI opens for each setting).

### Order

```
Phase 1 (shell)
   └─ Wave A, in parallel:  2 Studio   3 History   4+5 Health/AI   8 Window (C++)
        └─ Wave B, in parallel:  6 Session   7 Project   9 Chat+pop-outs   10a Plug-ins   10b Settings
             └─ Wave C:  11 the switch (panel to Classic, toolbar, radial, phone app)
```

Phases 2, 3 and 4 each add one line to `lib/webui.lua` and one to `index.html`: fine as small additive edits by the agent rules, staged from
the current HEAD at commit time.

### What's left out on purpose

Item 2 (screen share's cursor and ask for control), 3 and 4 (plug-in borrowing), 5 (exact follow), 9 (fold a person's computers), 10 (dry and
wet), 12 (recording together under Follow) and 14 (crash on load) are their own tasks; this plan only leaves them a place (Session's Play
together, Project's Follow menu, Plug-ins, Devices, the loading state).

---

## 7. Decisions for James

1. **Names**: Studio / Session / Project / Chat / History / Plug-ins / AI / Health / Settings, and "In control" instead of "driver"? (Or keep
   "driver".)
2. **When REAPER has the focus**, the default: shrink to the strip (proposed), shrink to the button (the panel's default), stay in front, go
   behind REAPER, or fade?
3. **The Edit switch**: back to View each time the Project tab opens and after 5 minutes idle (proposed), or remembered per device?
4. **What a phone may do**: restore history and change studio settings from a phone, or view, chat, record and AI-ask only? (Proposed: restore
   yes, with the in-page confirm; studio settings no.)
5. **The panel's retirement**: keep it as "Classic panel" behind a setting for how long after Phase 11 (one release? until the band test)?
6. **The banner over REAPER's arrange** ("View only: Bo is in control"): fold it into the strip, a native note from the extension, or drop it?
7. **History playback sound**: Play through REAPER by default (needs SWS, which most of the band has) or the web view's own audio?
8. **Mixer** as a Project sub-view (proposed) or its own tab; **Mixes** under History (proposed) or with Studio's What's new?
9. **Who answers the page with no studio project open**: Autostart (Lua, no extension change, proposed for now) or a per-topic poll in the
   extension (cleaner, needs a release)?
10. **AI**: hide lyrics, mix feedback, recap and take names (proposed, code kept) or delete them?
