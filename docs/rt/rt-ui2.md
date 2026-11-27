# rt-ui2: the Studio tab and the lobby (Phase 2 of the whole UI in the web view)

Plan: `docs/rt/ui-web-plan.md`, section 6 "Wave A" > Phase 2, with 2.1-2.4, 3.2-3.4 and James's decisions of 2026-11-27 (decision 9:
Autostart answers the page with no project open). Findings served (`docs/rt/findings-2026-11-27.md`): item 1 (the web view knows what
REAPER has open), item 11 (names), item 13 ("better project organisation, and better organisation/flow in general") and "Switching studio
without a project open". rt-people's Online now folding, "no Ask on people already in your project" and rt-setup's "Your studios" way back are
kept (Studio's own studios list is the web's way back).

## What was built

- **The Studio tab** (`lib/webui/home.js`, `home.css`): one page, top to bottom:
  - **No studio project open**: "No studio project is open in REAPER: open one below." (another device: "... on James-Main ..."), and when the
    tab in front isn't in a studio, "“Untitled 3” is open in REAPER and isn't shared yet. **Share with Chilio**" (this computer only; another
    device sees the line without the button).
  - **Your studios**: every studio this computer is in and hasn't left, your role, its projects and people; **Open** on another one switches to
    it (the panel's Open on a studio card: you work in it from now on and its projects show). **Start a studio** and **Paste a join code**
    (this computer only) do what the panel's do.
  - **Projects**: search (names, folders, stages, who worked last, who's in it), views **Recent** (default) / **Folders** / **Stage**
    (remembered per browser), **New folder**. Each project is a card: name, pin, stage, who's in it, who worked last, what and when, its
    folder, "n changes since you were last here"; **Open** (or Switch to it / Project view), **Ask…** and **Link** (invite.js), and **⋯**:
    Pin to the top / Unpin, Stage, Folder (with New folder…), Open room <name>, Archive / Unarchive. Pinned come first in every view;
    **Archived (n)** folds at the end (a search opens it).
  - **What's new**: For you, Online now (rt-people's folding, untouched), New takes, Mixes and stems, Last session here.
- **`lib/weblobby.lua`** (new): the lobby topic (your studios), the studio shown (`weblobby.cfg`: the one this computer works in,
  "sync_root"), the pins file, the organising actions, and Autostart's tick (below).
- **`lib/webroute.lua`** (new): the action router for when no Live sync answers. `webroute.rule(topic, live)`: `home`, `profile`, `invite`
  and `nav` run with no project; the rest of `webui.ACTIONS` need one ("the web page's 'health' needs a studio project open here"); anything
  else is unknown. Both are said in the log once per topic each time Autostart takes over (pages ask for Health or the call every few
  seconds). Live sync's own dispatch in `webui.tick` is unchanged; the router reads `webui.ACTIONS`, so a topic added there is known to both.
- **`lib/webhome.lua`**: the build carries each project's `folder`, `pinned`, `archived`, `roomnames` (rooms beyond main), and the studio's
  `folders` and `stages`; the tick builds the studio shown (another studio's projects with none current) and publishes `lobby` beside `home`;
  the action hands `{ topic = "home", lobby = { ... } }` to weblobby; Open on a project of the studio shown switches this computer to it first
  (Open session opens from "sync_root", as the panel's Projects page does).
- **`StudioSync - Autostart.lua`** (two lines and a local): `weblobby.tick()` on every pass (so a click isn't held for its 2 s look), once a
  look has found this REAPER isn't the hidden renderer.
- **`lib/webui/invite.js`** (one line): Ask… and Link go in the card's `.hpinv` place beside Open (old rows still get them in `.hptop`).
- No change to `lib/webui.lua` or `lib/webui/index.html`: the lobby's actions travel under the `home` topic (already in `webui.ACTIONS` and
  dispatched to webhome), its topic is published from webhome's tick, and the page is in home.js / home.css, which index.html loads already.
  So neither shared file is touched, and their uncommitted reorder (someone else's) is left alone.

## How the lobby works (decision 9)

With a studio project in front, Live sync answers as before; webhome's tick adds the `lobby` topic.

With none (no project, a project not in a studio, or Live sync not running for the front tab: `band.live_here(front, 30)` false; Live sync
clears its beat when it stops), Autostart's `weblobby.tick`:
1. starts the web UI server with the studio this computer works in (`webui.start`), when the extension has it and you've set a name;
2. polls the page's actions (up to 20 a pass) and runs them through `webroute`; not while REAPER loads or saves (they wait in the queue,
   findings item 14);
3. while a page looks, at most once a second and only what changed: `env` (what's in front, every tab, the transport, your studios; **no
   project and no studio**, so the project tabs and Chat hide), `presence` = nobody (the last Live sync's stays in the server otherwise, with
   its project, and the tabs would show), `nav`, then `home`, `lobby`, `profiles` (webhome's tick, with no project) and `invite`.

The two never poll at once: Live sync's front tab polls only while it runs in front (its tick returns before polling otherwise), Autostart
only while that tab has no fresh beat. After a gap over 10 s (REAPER held every script) Autostart waits 30 s before answering, so a Live sync
whose beat aged in the same hold isn't talked over (its publish cache would then think the server still had its topics). When the tab comes
to the front again Live sync publishes everything afresh (its own rule on coming to the front).

## The pins file

`<studio>/_band/pins/<user>.json`: `{ user, pins = { project }, archived = { project }, at }`, newest first, 200 each at most, written whole
(temp file and move) by this computer only, read only by it. Per computer name (a person's two computers each keep their own: see Left).

## The lobby topic and actions

```
lobby = { me, current = <studio id>, studios = { { id, name, role, current, waiting, projects, people (12 at most) } }, said = { ok, text, at } }
{ topic = "home", lobby = { use = <studio id> } }                     -- switch studio (band.use_band)
{ topic = "home", lobby = { start = <name> } } / { join = <text> } / { share = true }   -- this computer only (StudioSync_WebUIPollHere)
{ topic = "home", lobby = { song, pin = bool } } / { song, archive = bool }             -- the pins file
{ topic = "home", lobby = { song, stage = <one of the five> or "" } }  -- extras.set_stage
{ topic = "home", lobby = { song, folder = <name> or "" } }            -- chooser.set_folder (name cleaned, 60 at most)
{ topic = "home", lobby = { newfolder = <name> } }                     -- _band/folders/<name>.json, the panel's empty folder
```

Every project action checks the project is one of the studio's (`band.songs`, so a guest's own list). Join with a Tailscale key joins the
studio and says to paste the code on the panel's Studios page for the Tailscale sign-in (its question is a REAPER box; not from the web).

## Checks for James (REAPER, after a release with these files)

1. Close every studio tab (an empty untitled one left). Open the docked web UI (or `http://127.0.0.1:47281/`): Studio, Health, Settings;
   "No studio project is open in REAPER"; "“Untitled” ... isn't shared yet · Share with Chilio"; Your studios lists Chilio (working in) and
   the others; Projects shows Chilio's projects.
2. Open on a project card: it opens in REAPER; within a few seconds the project tabs come back (Live sync answers again) and the card says
   Project view.
3. Close it again; Your studios > Open on another studio: its projects show; open one of them: it opens from that studio.
4. ⋯ on a card: Pin to the top (it moves first), Stage, Folder (and New folder…), Archive (it folds into Archived at the end). Folders and
   Stage views group them; search finds "Bo" by who worked last. Restart REAPER: pins, archive, stages and folders are kept; the panel's
   Projects page shows the same folders and stages.
5. Start a studio and Paste a join code from the web (this computer): the same as the panel's (the log says what happened; a mistake shows
   under Your studios in red).
6. From the phone link with no project open on the desktop: the lobby names the computer, no Start / Join / Share; Open opens on the desktop.
7. Ask… and Link on a card with no project open: Ask sends the request (the asked person sees Join); Link shows the studiosync:// link.
8. With a project open: Studio still has every card; the panel works as before.
9. The log: one line "the web page's 'health' needs a studio project open here" when you open Health in the lobby, not one every few seconds.

## Tests

- `tests/test_0_60_rt_ui2.lua`: the pins file (cleaning, caps, set/unset, newest first, path refusals), the lobby model and the studio shown,
  every lobby action (switch, pins round trip, stage, folder, new folder, start/join/share refused from another device and done here), the
  route rule and run (FREE topics dispatched with no project, a project's topic and an unknown one said once, reset), Autostart's tick with a
  stand-in REAPER (Live sync answering: no poll; stopped: poll, env with no project and no studio, empty presence, home and lobby; once a
  second and only changes; nobody looking: nothing built; the hold after a gap; loading: actions wait), webhome handing the lobby on with the
  studio shown, the Autostart and invite.js hooks.
- `tests/rt_ui2_browser.mjs` (by hand: `node tests/rt_ui2_browser.mjs`; Chrome or Edge, fake devices only): the real page against a stand-in
  server: tabs with no project, the lobby note and Share, your studios (Open, Start, Join), cards (pinned first, Archived, Switch to it, Ask… and
  Link, Open), search, Folders and Stage views, the menu (pin, stage, folder, rooms, archive), New folder, a menu kept open over a redraw, the
  words back, another device's limits, a project opening again, no page errors.

## Left for later

- **Chat with no project**: the lobby's env has no `studio`, so Chat hides (its topics and actions need Live sync). Phase 9 can let
  Autostart build the studio chat (webroute: add `chat` to FREE once it works without `b.song`) and put `studio` back in env.
- **Health with no project**: shows Live sync's last Health (stale) and its asks are "needs a project" (Phase 4's).
- The conn pill says "live" and the strip "Sync on" while Autostart answers (the server's `engine` is "someone answers"): app.js and
  shell.js could read `env.front.live`. Small, but rt-ui1's files.
- Studio > People (members and roles, invite, guests, listeners) is still under Session > Who's here; New project (empty or from a template),
  New from this, Delete my local copy (the panel's, with its REAPER box) are panel-only.
- Pins are per computer name, not folded per person (rt-people's `persons`); fold them when item 9's "my computers" lands everywhere.
- Live sync's dispatch could use webroute too (one table of topics): a bigger edit of the shared webui.lua, left as is.

## Review later (security)

- Lobby actions from another device (the phone link, acting as this computer's person): switch studio, pin, archive, stage, folder, new folder
  and Open are allowed (the panel's members may do all of them); Start a studio, Paste a join code and Share are this computer only
  (`StudioSync_WebUIPollHere`), as they change this computer's setup and Share opens REAPER's boxes.
- The pins file is read only by the computer that writes it and isn't checked with `trust.own_file_ok`: someone in the studio could write
  `_band/pins/<you>.json` through Syncthing and reorder your list (only your view; names are cleaned and capped on reading).
- Folder names from the page go through `band.clean` (letters, digits, space, - and _) and 60 characters; join codes are capped at 8000 bytes.
- Autostart now starts the web UI server at REAPER's start when this computer is in a studio (Live sync did so whenever it ran): the same
  server, token and tailnet-only rules as before.
