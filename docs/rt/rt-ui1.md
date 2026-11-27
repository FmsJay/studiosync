# rt-ui1: the shell (Phase 1 of the whole UI in the web view)

Plan: `docs/rt/ui-web-plan.md`, section 6 "Phase 1", with 2.1, 2.2, 3.1-3.4 and the page side of 4.2-4.4, under James's decisions of
2026-11-27. Findings served (`docs/rt/findings-2026-11-27.md`): item 1 ("UI needs to be cleaned up and moved entirely into the web view
along with per device systems"), item 11 (names), item 13 (organisation and flow), and the small items "Show the StudioSync icon on the
web view" and "Pop out the parts of the UI where it makes sense".

## What was built

- **`lib/webui/shell.js`** (loaded first): `window.ssEnv` (where the page runs), `window.ssLabels` (the one label map), the top bar
  (logo, breadcrumb Studio ▸ Project ▸ Room, the status pill, Dock / Undock and the hidden window buttons in REAPER, the ⋯ menu), the loading
  note, light/dark, and the window's small shapes: the **strip** and the **button** (`?win=strip|button`, or the REAPER window's own
  `{"win": mode}` message once Phase 8 sends it).
- **`lib/webui/tabs.js`** (rewritten, same `ssTabs.topics` / `ssTabs.act` / `ssTabs.add` as before): the nine tabs and their sub-tabs, each
  shown only where it can work and when what it needs is there; deep links; `?pop=`; the `nav` topic; "More" when the row doesn't fit; the
  phone's bottom bar; a side rail on wide landscape windows (over 900 px); "coming" pages for what isn't built.
- **`lib/webui/shell.css`** (loaded last), **`lib/webui/icon.svg`** (the small logo; its two bars follow light/dark inside the SVG).
- **`lib/webenv.lua`**: the `env` topic (model, build, once-a-second tick) and the `nav` topic (route check, request, model, action).
- **`lib/webui.lua`** (additive): `ACTIONS.nav`; the `nav` action; in the tick, `env` and `nav` published while a page looks;
  `webui.env_loading` for Live sync's load hold.
- **`StudioSync - Live sync.lua`** (one additive line in `loading()`): while `lib/loadguard.lua` holds the tab, `webui.env_loading` publishes
  `env` with `front.loading`, since `webui.tick` doesn't run then.
- **`lib/webui/index.html`**: favicon and logo, shell.js and tabs.js before app.js, shell.css last, the top bar markup, `.ssbody` (tab row and
  `#sspages`), two `<main>`s (`#studiomain` for the studio overview, `#chatmain` for the chat), the phone bar `#ssbar`.
- **`lib/webui/daw.js`**: no tab bar of its own any more; registers as Project > Arrange (`ssTabs.sub`).
- **`lib/webui/app.js`**: light/dark, Dock / Undock and the "where" line moved to shell.js; the driver badge reads "in control" (decision 1).
  The key pass-through to REAPER stays.
- **`lib/webui/home.js`** (two lines, not in the plan's list but needed): "Project view" opened the *second* tab button (now Session) and
  the unread button scrolled to a chat that's now its own tab; both go through `ssTabs.go`.
- Tests: `tests/test_0_60_rt_ui1.lua`, `tests/rt_ui1_browser.mjs`; `tests/test_0_60_rt_dock.lua` reads shell.js too (the Dock code moved);
  `tests/test_0_60_rt_webui.lua` counts the new env topic apart from the pages' own publishes (and checks it went);
  `tests/rt_p14_browser.mjs` loads shell.js, tabs.js and shell.css and publishes an `env` with a project (daw.js now needs the shell).

## The tabs and labels

| Tab | Shown when (`need`) | Sub-tabs (built today in **bold**; the rest say "coming" and where the thing is meanwhile) |
|---|---|---|
| Studio | always | **Studio** (home.js's overview) |
| Session | a project open | **Who's here** (`#here`), **Play together** (play.js), Rooms |
| Project | a project open | **Arrange** (daw.js), **Mixer**, **Sheet**, **Beat** |
| Chat | a studio known | **Chat** (chat.js) |
| History | a project open | Changes, Versions, **Playback** (history.js, histhear.js), Mixes |
| Plug-ins | a project open | This project, **Try a bandmate's** (tryfx.js; this computer only), Find a plug-in (this computer only), Plug-in pack |
| AI | the studio has AI on | **AI** (ai.js; Phase 5 trims it to stems and audio to MIDI) |
| Health | always (red or amber dot from `env.health`) | **Checks** (health.js), Log, Updates (both this computer only) |
| Settings | always | You (has a "Your picture, name and colour" button meanwhile), This computer, Studio, Devices, Advanced (all four this computer only) |

"A project open" = Live sync is running (`engine`) and `env.front.project` or `presence.song` is set; "a studio known" = that, or
`env.studio` while Live sync runs. Before the first state arrives every tab counts as there, so a reload doesn't flash a bare Studio.

Environments (`ssEnv.where`): `reaper` (a WebView channel and `?host=docked|floating`), `local` (127.0.0.1 / localhost in a browser),
`remote` (any other host: another device on the tailnet). `ssEnv.phone` = remote and under 700 px. Guests and listeners have their own pages,
unchanged.

| | In REAPER | Browser here | Another device | Phone |
|---|---|---|---|---|
| Dock / Undock (and strip, button, full screen once the window says it can) | yes | no | no | no |
| ⋯ menu | Open in the browser, Pop out | Open in REAPER, Pop out | Pop out only (hidden when nothing pops) | hidden |
| Plug-ins > Try / Find, Health > Log / Updates, Settings > all but You | yes | yes | no | no |
| Tab row | row, rail when wide, More when narrow | same | same | bottom bar: Session, Project, Record, Chat, More (Studio in Session's place with no project) |

Label map: `LABELS` in `lib/webui/shell.js` (route -> name, e.g. `'history/playback': 'Playback'`) and `WORDS` (old word -> new: song ->
Project, driver -> In control, dismiss -> Hide, side room -> Room, box/pill -> Button, try -> Try a bandmate's, hop -> Run on a bandmate's
computer, console -> Log, ...). Pages use `ssLabels.tab(route)` and `ssLabels.word(old)`. A sub registered with its own label still shows
the map's name when the map has one: names stay in one place.

Older pages' `ssTabs.add` names land by `LEGACY` in tabs.js: play -> session/play, mixer/sheet/beat -> project/..., history ->
history/playback, tryfx -> plugins/try, health -> health/checks, ai -> ai/ai. No page file needed changing for that.

## How later phases register

```js
// a sub-tab of one of the nine (replaces its "coming" page; the label comes from the map when it has the route)
ssTabs.sub('history', 'changes', 'Changes', el, (on) => { shown = on; if (on) want(); });
// with its own conditions: need = names from tabs.js NEEDS (project, studio, ai, reaper), envs = where it may show
ssTabs.sub('plugins', 'find', 'Find a plug-in', el, onShow, { envs: ['reaper', 'local'], need: ['project'] });
// a page of its own as a new tab (order: where in the row; the nine are 0-8)
ssTabs.add('rooms', 'Rooms', el, onShow, { order: 2.5, need: ['project'] });
ssTabs.go('history/playback');   // show a tab (and remember it as the person's choice)
ssTabs.route();                  // 'history/playback'
ssTabs.shown('history');         // true while any History sub shows
ssTabs.list();                   // every tab and sub with ok/coming, for tests
addEventListener('ss-route', (e) => e.detail);  // the route changed
```

`onShow(true)` runs every time the sub is shown and `onShow(false)` every time it's hidden (Phase 7: put the Edit switch back to View in
`onShow(true)`). A page's element gets `hidden` toggled itself, so code that watches its own `hidden` (chat.js on `#chatmain`, home.js on
`#studiomain`) keeps working. To make a sub poppable add its route to `POP` in tabs.js; to add a tab to the nine, add a row to `TABS` and its
names to `LABELS`.

Deep links: `#tab` or `#tab/sub`; the address follows the open page (`history.replaceState`, no history entries). A tab that can't show now
is remembered: if a project closes while you're on Project you see Studio, and Project comes back when the project does.

Pop-out: `index.html?pop=chat` (or `?pop=project/beat`): that page alone, no tab row, a "Back into the main window" button. The ⋯ menu's
"Pop out this page" opens it with `window.open` (no `?t=` token in it: the cookie carries it). In REAPER the view's own popup handling is
Phase 8's.

## The `env` topic

Published by Live sync's front tab while a page looks, at most once a second, only when changed; while Live sync's loadguard holds the tab,
by `webui.env_loading` with `front.loading = true`.

```
{ v = 1, ver (StudioSync), ext (extension, the "menu extension" ExtState), computer, user (cfg.user), person (lib/persons.lua's key),
  studio (band.info name), ai (the studio's AI switch), health ("red" when a sync problem lit the toolbar amber, else Health's last worst
  if a page had Health open, else nil),
  front = { name (REAPER's), studio, project, room, shared, loading, live, tracks },
  tabs = { { name, live (Live sync runs there), front } },   -- every open REAPER tab, 32 at most
  transport = { playing, recording, paused, pos },            -- pos: the play position while playing, the edit cursor otherwise, to 0.1 s
  studios = { { name, role } } }                               -- every studio on this computer, refreshed every 10 s
```

Flags are `true` or absent. `front.loading`: REAPER loading or saving (`loadguard.busy()`), or Live sync's loadguard holding the tab; the page
then says "Loading <name> (n tracks)…" and greys `#sspages` (no clicks reach a page). Sync's first catch-up (`loading <proj>` ExtState) is not
counted: that's files arriving, not REAPER busy, and greying everything for minutes of catching up seemed wrong. Say if you want it.

The `nav` topic: `{ page, sub, at, id, wake }` from the `web nav` ExtState (`webenv.nav_request(page, sub, wake)`, for Phase 11's
"StudioSync: open Chat / History / …" actions and the radial menu). Only the page in REAPER acts on it, once per id, and only within 5 s of
`at`. A page's `{ topic: "nav", to: "reaper" | "browser", page, sub }` (the ⋯ menu): from this computer only (`StudioSync_WebUIPollHere`),
`reaper` writes the nav and calls `StudioSync_WebUIDock(1)`, `browser` opens this computer's address at `#page/sub`.

## Checks for James

In REAPER (after a release with these files):
1. Open the docked web UI with a studio project in front: the logo top left, "Chilio ▸ Cross Test", the tab row (or the rail when the docker is
   wide and short); every tab opens; Project > Arrange draws as before; Session shows Who's here and Play together.
2. Undock / Dock still work; no strip / button / full-screen buttons yet (they appear with Phase 8's extension).
3. Narrow the docker: the last tabs go into "More ▾".
4. ⋯ > Open in the browser: the browser opens on the same page. In that browser, ⋯ > Open in REAPER: the docked view opens (or comes
   forward) on that page.
5. Open a big project: the view says "Loading <name> (n tracks)…" and nothing on the pages can be pressed until it has loaded.
6. Close the studio project (or stop Live sync): the project tabs go, Studio / Health / Settings stay; open it again: you're back on the tab
   you were on.
7. The panel: unchanged.
On the phone (the phone link): the bottom bar (Session, Project, Record, Chat, More); Settings shows only You; Plug-ins has no Try.
In a browser: `http://127.0.0.1:47281/#history/playback` opens History > Playback; `…/?pop=chat` shows the chat alone.

## Tests

- `tests/test_0_60_rt_ui1.lua`: the env model (fields, caps, flags), build from a stand-in REAPER (front tab, tabs, transport, loading from the
  hold and from REAPER's load/save, a sync problem as red, Health's level, studios and roles), the once-a-second tick, routes, the nav topic and
  action (another device opens nothing; Open in REAPER docks; Open in the browser opens `#history/playback`), webui's hooks, the label map
  (James's nine names, every tab, sub and legacy target named, no old word in a label), index.html's order and markup.
- `tests/rt_ui1_browser.mjs` (run by hand: `node tests/rt_ui1_browser.mjs`; needs Chrome or Edge): the real index.html and every page file
  against a stand-in server with SSE; in REAPER (a stand-in WebView2 channel), a browser here, another device wide and as a phone: which tabs and
  subs show, the names, today's pages in their new places, deep links, the remembered tab, loading, the menus and the nav action, the nav topic
  (REAPER only, fresh only), the strip and button, More, the rail, the phone bar, `?pop=chat`, no page errors.
- `tests/rt_p14_browser.mjs`: still passes with the shell.

## Left for later phases

- Top bar ▶ ■ together, call controls, the bell and notifications (`env.notes` isn't filled), text size, Send feedback, Sync and exit in the
  menu (Phases 6, 9, 10, 11).
- The people rail (optional in 2.1).
- `env` with no studio project in front, and the Studio lobby: Autostart (Phase 2). Until then, with no Live sync the page shows Studio,
  Health and Settings and the conn pill says "Live sync isn't running".
- Health's level in `env` only after a page had Health open (apart from a sync problem); Phase 4 can publish it always.
- Window modes, focus behaviour, pop-out windows inside REAPER, the window icon (Phase 8's C++). The page already sends `win:strip`,
  `win:button`, `win:fullscreen`, `win:full`, `win:menu` and takes `{"win": mode}` (WebView2 `message` event, or `ssShell.fromHost(obj)` for
  WKWebView / WebKitGTK).
- Studio > People (guests, listening links still sit under Who's here, inside `#here`), Settings pages, the Edit switch, the AI trim.

## Review later (security)

- `nav` from a page opens a window or the browser on this computer only when the extension says the page is on this computer
  (`StudioSync_WebUIPollHere`); a remote page's ask is logged and dropped. The browser URL is built from this computer's own port and a route
  checked against the nine names and `^%a+$`, so nothing from the page reaches `open_url` unchecked.
- The page's environment test only decides what to show; the server's existing checks are unchanged.
