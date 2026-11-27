# rt-ui4: Health and Log, and the AI trim (Phases 4 and 5 of the whole UI in the web view)

Plan: `docs/rt/ui-web-plan.md`, section 6 "Wave A", Phases 4 and 5, with 2.7, 2.8 and James's decisions of 2026-11-27 (the other AI tools
hidden, not deleted). Findings served (`docs/rt/findings-2026-11-27.md`): item 6 ("AI tab: keep only stem separation and audio-to-MIDI for
now") and item 16 ("Health: hide/show hidden items; hide/show other scripts' messages").

## What was built

**Health tab** (`lib/webui/health.js`, rewritten; registers its sub-tabs with `ssTabs.sub`):

- **Checks**: the panel's rows, red first, as before, now with
  - **Show hidden (n)**: the rows hidden here or dismissed in the panel (same list: the `dismissed` ExtState), each with **Show again**;
    **Hide** on every amber row. Red rows are never hidden.
  - **Show messages about other scripts**: a switch, on by default. Off, the rows `lib/compat.lua` adds go (amber and fine ones), with their
    count beside the switch; red ones always show. The switch is the computer's (`health other off` ExtState, kept), so it is the same in REAPER,
    the browser and on a phone, and with it off those amber rows no longer light Health's dot in the tab row.
  - **The row's buttons work here**: Show it, Try again, Pick one for me, Set Ctrl+Z, Switch to …, Update REAPER, Check again, Move
    StudioSync's start to the top, Set up direct link, … whatever button the panel draws on that row, plus **Set up everything I can** and
    **Copy the line** (copied by the page). Each sends `{ topic: "health", act: <row id> }` and `page_health.web_act` runs the same function
    the ImGui button runs.
  - On another device (a phone), only the buttons that change StudioSync's own state work (`page_health.WEB_REMOTE`: Try again, Pick one for
    me, Check again); every other one is greyed and reads "… (on James-Main)", and the server refuses it anyway.
  - The "Check other scripts now" button stays.
- **Log** (was the panel's Console): StudioSync's activity lines, newest first (the `log` topic from new `lib/weblog.lua`), **Copy** (the page's
  own clipboard), **Log files** (opens the folder of daily log files on this computer; from this computer's page only).
- **Updates**: the versions, the "newer StudioSync in the studio" / "REAPER behind" rows, **Update StudioSync** (runs `StudioSync - Update.lua`
  as a REAPER action, as the panel's button does) and **Update REAPER**.
- **Can't hear?**: the panel's "Can't hear each other?" card as text, without the SonoBus half while the studio's own live audio runs.
- **Send feedback**: kind, subject, what happened, "Add what it was doing"; **Save it** saves through `lib/feedback.lua`'s `save` into the
  studio's `_band/feedback` folder (with the last 25 activity lines and the system lines when ticked). GitHub isn't offered from the page.

Log and Updates are this computer only (rt-ui1's `ENVS`); Can't hear? and Send feedback are too (the advice is about this computer's setup,
and a report goes out under this computer's name). Another device sees Checks only.

**Server side**

- `lib/webpages.lua` (the health half; the Play half untouched): `health_model(rows, gone, ver, ext, o)` now keeps hidden rows (marked
  `hidden`), marks `other` rows, adds each row's button (`act`) and whether only this computer may press it (`here`), the counts (`hidden`,
  `other`), `show_other`, `builtin`, and the last action's words (`said`, `said_n`); `worst` leaves out what the page hides. `health_shows(r,
  show_hidden, show_other)` is the one rule (health.js has the same one line). On the health topic: `act`, `hide`, `show` (an id or `true`),
  `other`, `feedback`, `log`. Health is built every `HEALTH_IDLE` (10 s) while any page looks, every 2 s while one shows Health: **the env
  topic's Health level is now always there** (rt-ui1's ask), not only after a page opened Health.
- `lib/page_health.lua` (additive, at the end): `H.WEB_REMOTE`, `H.web_button(row)`, `H.web_act(id, here)`. Refuses a non-string, empty or over-200
  id, an id that isn't a row or has no button now, and from another device anything not in `WEB_REMOTE` (including `@setup`, `@update`,
  `@update reaper`). `here` comes from the extension's `StudioSync_WebUIPollHere` for the action just polled (read in `webpages.action`, so
  `lib/webui.lua` needed no change).
- `lib/compat.lua`: every row it makes carries `other = true` (one line).
- `lib/weblog.lua` (new): the `log` topic (built only while a page shows the Log, at most once a second), Log files.

**AI trim** (Phase 5)

- `lib/ai.lua`: `ai.SHOWN = { stems = true, midi = true }`. The topic carries only those; `ai.ask` refuses another id ("… isn't offered for
  now"); `ai.FEATURES` and every other tool's code stay. "A part to MIDI" is now **Audio to MIDI** (the plan's name). `ai.key_shown(k)`: the
  panel's AI card (Settings > Studio > AI) shows only the demucs and Basic Pitch paths; the chat model's address and name, and whisper's two
  fields, are hidden while no feature that needs them shows. Its "Off:" line says stems and MIDI.
- `lib/webui/ai.js`: the privacy line speaks of the two tools only (no chat model words).

**Shared files:** none. `lib/webui.lua` and `lib/webui/index.html` didn't need a line (the health topic already was an action; no new page
file). Tests of others' I adjusted for the new behaviour: `tests/test_0_60_rt_webpages.lua` (hidden rows now come along marked; Health at the
idle pace), `tests/test_0_60_rt_webui.lua` (the health topic counted apart, as env is).

## Checks for James (in REAPER, after a release with these files)

1. Web UI > Health: sub-tabs Checks, Log, Updates, Can't hear?, Send feedback. The tab's dot is red or amber even if Health was never opened.
2. Checks: press **Hide** on an amber row: it goes, "Show hidden (1)" appears; press it: the row shows with **Show again**; press that. The
   panel's Settings > Health shows the same rows dismissed / back.
3. Untick **Show messages about other scripts** (with a compat row there, e.g. after "Check other scripts now" finds something): those rows go,
   "(n hidden)" shows; the tab's dot stops being amber if they were the only amber ones. Tick it again.
4. Press a row's button (e.g. Try again, Check again, Set Ctrl+Z if it shows) and **Set up everything I can**: the Log names what ran.
5. Log: lines newest first; Copy, then paste somewhere; Log files opens the logs folder.
6. Updates: Update StudioSync starts ReaPack's update as the panel's does; Update REAPER opens the Update Utility.
7. Send feedback: write a subject, Save it: "feedback saved in the studio's feedback folder"; the file is in `<studio>/_band/feedback/`.
8. On the phone link: Health shows Checks only; Show it / Switch to … / Set Ctrl+Z read "(on James-Main)" and can't be pressed; Try again works.
9. AI tab (studio's AI on): only Split into stems and Audio to MIDI. Panel > Settings > Studio > AI: only the demucs and Basic Pitch paths.
10. The panel's Health, Console and Updates are unchanged.

## Tests

- `tests/test_0_60_rt_ui4.lua`: which rows show with each switch (every combination), the dot, a row's button and `here`, compat rows marked
  other, `web_act` running the panel's functions (rows, keys, `@setup`, `@update`, `@update reaper`) and refusing unknown ids, junk ids, rows
  without a button, and from another device every unsafe id (nothing runs, nothing registered); the health topic's act / hide / show / other /
  feedback (phone refused, kinds, size limits, control characters, the activity lines) / log (topic only while shown, Log files refused from a
  phone); health.js's actions.
- `tests/test_0_60_rt_ai.lua` section 6: the topic carries only stems and midi; asks for lyrics, feedback, recap and names refused with no
  ask made; stems still asks; the panel's fields. Sections 1-5 run with every tool shown, so the hidden tools' code stays tested.
- `tests/rt_ui4_browser.mjs` (by hand: `node tests/rt_ui4_browser.mjs`): rt-ui1's harness; Health here and on another device, both switches,
  Hide / Show again / the switch / buttons send the right action, greyed remote buttons send nothing, Log, Updates, Can't hear? both ways,
  Send feedback, the AI page with two tools, no page errors.

## Left for later

- The panel's own Health page doesn't follow the "other scripts" switch (its list and its sidebar dot): only the web page and env do.
- Plan 2.8's "on a phone, buttons that need this computer's desktop say 'On James-Main' and run there": they say it, but don't run there from a
  phone. Running installers or network switches from a phone needs a decision (and a confirm) first.
- Studio AI switch and tool paths moving to Settings > Studio / This computer (Settings is a later phase); the panel's AI card stays.
- The Log has no Clear (the panel's has); the log topic is published like every topic, so another device with the token could read it from
  `/api/state` even though the Log sub-tab doesn't show there.
- Labels "Can't hear?" and "Send feedback" aren't in shell.js's label map (not my file): they come from health.js.

## Review later (security)

- `web_act` from another device: allow-list `WEB_REMOTE` (skipped, colours, compat); everything else needs `StudioSync_WebUIPollHere() == 1`.
  An older extension without that function counts as not here, so only the allow-list works then.
- Hide/Show write the `dismissed` ExtState from any device with the token: ids capped at 200 chars, no `|`, at most 200 entries.
- Feedback: this computer's page only; kind from a fixed list, subject 200 and body 8000 characters, UTF-8, control characters dropped;
  the file name is `lib/feedback.lua`'s own (UTC time and the user name, sanitized).
- The health and log topics go to every client of the web server (as before for health); the log may name tracks, people and paths.
