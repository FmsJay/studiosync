# rt-ui10b: Settings in the web view (Phase 10b of the whole UI in the web view)

Plan: `docs/rt/ui-web-plan.md`, section 6 "Wave B" > Phase 10 (the Settings half), with 2.9, under James's decisions of 2026-11-27:
- decision 2: when REAPER takes the focus, shrink to the strip by default, with the other behaviours as options in Settings
- decision 4: a phone may not change studio settings

Findings served (`docs/rt/findings-2026-11-27.md`): item 1 (UI into the web view), item 11 (one word per idea), and the small item "set the
talk mic to the correct input".

## What was built

- **`lib/websettings.lua`** (new): the `settings` topic and action.
  - Each setting is a row: id, section, heading, kind (switch, choice, number, link, button), label, help, and its own module's getter and
    setter. The page draws every row the same way.
  - Built only while a page shows Settings (the page says so every 10 s), every 2 s at most, and published only when it changed.
- **`lib/webui/settings.js`** (new): the five sub-tabs through `ssTabs.sub('settings', ...)`, replacing rt-ui1's "coming" pages.
- **`lib/webui.lua`** (additive, 8 lines): `ACTIONS.settings`; the dispatch, with whether the page is on this computer
  (`StudioSync_WebUIPollHere`); the tick line.
- **`lib/webui/index.html`** (additive, 2 lines): `settings.js` after `tryfx.js` (after `tabs.js` and `profile.js`).
- Tests: `tests/test_0_60_rt_ui10b.lua`, `tests/rt_ui10b_browser.mjs`.

No module needed a new `model()` / `set()`: every row reads and writes through getters and setters that already exist. Rows by section:

| Section | Rows (module) |
|---|---|
| **You** (every device) | You're <name> on <computer>; "Your picture, name and colour" (profile.js's editor, the existing `profile` action); your studios and roles (the `env` topic); **Look on this device**: theme (As the system / Light / Dark, the `ss-theme` key shell.js already uses) and text size 80-160 % (`ss-text`, page zoom). Look is per browser, so it sits under You and a phone gets it too. |
| **This computer > Window** | When REAPER takes the focus: Shrink to the strip (default) / Shrink to the button / Stay as it is / Go behind REAPER / Fade (ExtState `web ui focus`, read by `extension/webui_dock.cpp`); the button's size 22/28/40/56 (`web ui button size`); Lock the strip and button (`web ui lock`); REAPER's StudioSync button opens this view, not the panel (`ui` = `web`); StudioSync button on REAPER's toolbar (`tools.toolbar_button` / `set_toolbar_button`, with its "why it won't show" note) |
| **This computer > Sync** | Parts play Auto / Dry / Wet (`prints.mode`, ExtState `midi_plays`, then `prints.choose` on every item as the panel does); bandmates' takes while they record (`streams.mode`); bars behind, shown only for In time (`streams.bars`); Record 24-bit WAV, off = FLAC (`streams.record_wav` / `use_wav`); Live set (`live set`) |
| **This computer > Audio** | Join Ableton Link (`ablink.on`, shown when ReaBlink is there or it's on) |
| **Studio** (owner and admins change; everyone sees) | Public links (owner only, `audience.public_on` / `set_public`, its own warning confirmed first); AI tools (`groups.ai`); Live audio and the project's hub threshold (`groups.live_audio`, `liveaudio.hub_from` / `groups.set_live_hub`); the direct link (`direct.enabled` / `groups.set_direct`); connect without Tailscale too (`nat.enabled` / `groups.set_nat`); Sync only through Tailscale, asked first (`groups.tailscale_only`, only when the studio has a network); Takes become lanes; plug-in hand-overs for prints (`prints.HOPS` / `hops_cap` / `groups.set_print_hops`); everyone sees the project's own colours (`groups.colour_parity`); Phone alerts, turning off asked first, with the channel to subscribe to (`alerts.channel` / `set`); the studio's call link (`alerts.call_link` / `set_call`, checked by `alerts.call_ok`); Debug mode for everyone (`debugmode.on` / `groups.set_debug`); everyone runs StudioSync from the studio's folder (`fromfolder.on` / `groups.set_folder_updates`) |
| **Devices** | Talk mic: REAPER's inputs, each naming the tracks that record from it, the clash with an armed track said, and "Talk on <input> instead" for the first free one (`liveaudio.mine` / `set_mine`, `liveaudio.talk_advice`); stereo pair; what you send in kbit/s. The phone's secure link by itself (`phonerec.auto_on`). Open on your phone: this computer's Tailscale name, "Show the phone link" (`webui.phone_link`) with Copy. Your computers: Mine too / Not mine (`persons.computers` / `persons.set`) |
| **Advanced** | Every StudioSync action in REAPER's Actions list (`band.all_actions`, then `band.sync_actions`); Show advanced controls and Show the Play/Jam tab (the panel's ExtStates); Save a debug report now (`debugmode.write`); a line pointing at REAPER's "Keep selected tracks local" action |

Smart take names and lane names are left out on purpose: they're among the AI tools decision 10 hides.

## Who may change what

- **Nothing from another device or a phone.** Every change (`set`, `computer`, `phone`) is refused unless the extension says the page is on this
  computer (`StudioSync_WebUIPollHere`). The refusal is logged and shown on the page.
  - This covers decision 4 for Studio rows, and This computer, Devices and Advanced are this computer's own anyway.
  - The tabs already show those four sub-tabs only in REAPER and in this computer's browser (rt-ui1's `ENVS`), so a phone sees You only.
  - A phone may still say it's looking (`want`) and change its own look and its profile (the existing `profile` action).
- **Studio rows:** only the owner and admins change them (`groups.role` other than member, as the panel's `studio_admin()`; a studio from before
  owners counts as open). Members see them greyed with a tooltip.
- **Public links:** the owner only. `audience.set_public` checks it again.
- **Every value is checked against its row before anything is written:**
  - a switch takes only true or false
  - a choice must be one of its row's choices (for the talk mic, REAPER's inputs now)
  - numbers are clamped to the row's range and made whole
  - the call link goes through `alerts.call_ok` and at most 300 bytes
  - an unknown id is refused
- **Rows that ask first** (Public links on, Sync only through Tailscale on, Phone alerts off) are refused without `sure`. The page sends `sure` only
  after a `confirm()` showing the module's own words (`audience.WARNING` for Public links).

## The topic and action

```
settings = { v = 1, user, studio, role, may, owner, tailnet, said = { text, bad, at },
  rows = { { id, sec, grp, kind, label, help, value, choices = { {value, label} }, lo, hi, may, note, fix = { label, value },
             confirm_on, confirm_off, error } },
  computers = { { user, state = this|yours|waiting|asks|other } },
  phone, phone_why }        -- the phone link: only for a minute after this computer's page asked
page -> { topic = "settings", want = true } | { set = { id, value, sure } } | { computer = { user, on } } | { phone = true }
```

Each row's getter is pcall'd, so one module's trouble shows "couldn't be read here" on that row and leaves the rest.

## Checks for James

In REAPER (after a release with these files), with a studio project open, Settings in the docked web view:
1. Settings shows You, This computer, Studio, Devices and Advanced. None says "Coming here soon".
2. This computer > Window, "When REAPER takes the focus": pick each option and float the window:
   - Shrink to the strip (the default) and Shrink to the button: it shrinks when you click the arrange view.
   - Stay as it is: nothing happens.
   - Go behind REAPER: REAPER's window covers it.
   - Fade: it fades.

   `reaper.GetExtState("BandSync", "web ui focus")` shows the choice. Change the button's size and Lock, then right-click the button: its menu agrees.
3. "REAPER's StudioSync button opens this view": on, the toolbar button opens the web view. Off, the panel.
4. Sync: Record 24-bit WAV off. File > Project settings > Media shows FLAC for this project; on again, WAV. Parts play Wet: a MIDI part with a
   print plays the print.
5. Studio, as the owner:
   - Public links asks with the warning, then the log says PUBLIC links are on. Turn it off.
   - AI tools off: the AI tab goes within a few seconds.
   - Paste a Discord link in the call link and Save.

   As a member (another computer): the Studio rows are greyed. Pressing one by hand in the browser's console is refused, and the log says so.
6. Devices:
   - The talk mic lists the inputs with track names. Arm a track on the talk mic's input: the yellow note and "Talk on In N instead" show; press it.
   - Show the phone link: the link and Copy.
   - Your computers: Mine too for James-Laptop on James-Main (and the other way round on the laptop) folds them, as in rt-people.
7. Advanced: Every StudioSync action on: REAPER's Actions list shows all of them (the log counts them). Save a debug report now: the log says where.
8. On the phone (the phone link): Settings shows only You. Theme and text size change on the phone only. The profile button works.
9. The panel's Settings: unchanged, and each change made in one shows in the other within a few seconds.

## Tests

- `tests/test_0_60_rt_ui10b.lua` (in `python tests/run.py`):
  - every row round-trips: set from this computer's page, read back by its own module's getter, shown in the topic. The test fails if a row is
    added without being covered.
  - the focus rule: strip by default and for anything unknown, James's five options in order, each written to `web ui focus`, one outside the list refused.
  - a phone or another device: no studio setting, window, format, Your computers, phone link or Public links, even with `sure`.
  - roles:
    - a member changes this computer's settings but no studio's
    - an admin changes studio settings but not Public links
    - the owner turns Public links on only with `sure`
    - Sync only through Tailscale and Phone alerts off ask first
  - values: clamped numbers, a bad call link, a too-long text, a non-boolean switch, an input REAPER doesn't have, an unknown id.
  - the talk mic: track names per input, the clash, the fix and its move.
  - Devices: Your computers through `persons.set`, the phone link only after asking and gone after a minute.
  - the want / tick rhythm, JSON encoding, webui.lua's hooks, and index.html's order.
- `tests/rt_ui10b_browser.mjs` (by hand: `node tests/rt_ui10b_browser.mjs`; needs Chrome or Edge): the real page against a stand-in server.
  - five sub-tabs on this computer, none "coming"; the want; asking Live sync before the topic
  - Window then Sync; the focus rule's choices, strip first, and Fade sends; a switch, a number, a link's Save and a button send
  - an admin's Public links greyed
  - a confirm: No sends nothing and puts the switch back; Yes sends `sure`
  - the talk mic's note and fix; the phone link
  - Your computers (Mine too, none on this computer)
  - You: profile, studios, theme and text size kept in this browser
  - another device: You only; no page errors

## Left for later

- **Settings with no studio project open.** Settings shows on every page, but only Live sync answers the topic. With no project, This computer and
  the others say "Asking Live sync…". The hook belongs to rt-ui2's files, which aren't mine:
  - `webroute.FREE.settings = true`, and in `webroute.run`: `if topic == "settings" then return require("websettings").action({ proj = c.proj, cfg = c.cfg, b = c.b }, a, <PollHere>, reaper.time_precise()) end`
  - in `weblobby`'s tick: `require("websettings").tick({ proj = proj, cfg = cfg, b = b }, publish, now)`

  websettings needs only `cfg` (root and user). Rows that read the project (parts play's re-choose, the talk mic's track names) already handle no project.
- **Not brought over yet** (the panel keeps them):
  - the Look card's panel theme and frame, and keyboard navigation (the panel's own)
  - SonoBus's real time buffer and send quality (legacy while the studio's own live audio runs; changing them restarts SonoBus, `setup.sonobus`)
  - Measure my latency, AI tool paths
  - Studio's private live audio, the hub person, shared preferences, studio colours and theme colours, content, NINJAM server, the Tailscale
    token and tags, and "Use <network> for this studio"
  - QR code for the phone link (needs an encoder; none in the repo)
  - Prepare this project, Try things in a room, and printing options
- `call.js`, `audiencehost.js` and `home.js` still have their own controls for some of these (Public links, Your computers). Settings is a second
  door to the same functions.
- `lib/files.txt` needs `lib/websettings.lua` at release (`tools/make_index.py`).
- In this worktree (not in a clean clone with only these files), `node tests/rt_ui1_browser.mjs` fails its two `?pop=chat` checks. That comes from
  another agent's uncommitted files. A clone of HEAD plus these files passes rt_ui1.

## Review later (security)

- **Two existing doors with no this-computer check (not changed here, as they're other agents' files):**
  - `audience.action`'s `public = { on, sure }`: a phone page acting as the owner's computer could turn Public links on or off through the
    `audience` topic, against decision 4's spirit. One line in `audience.action`: refuse `d.public` unless `StudioSync_WebUIPollHere() == 1`.
  - `webhome.action`'s `computer`: a phone could mark computers as yours. The fold still needs both computers to say so.
- The phone link carries the studio's web token. It goes into the `settings` topic only for a minute after this computer's page asks. Topics reach
  every page with an event stream, and those are this computer's pages or pages that already hold the token (guests and listeners use their own
  allow-listed routes).
- Phone alerts' channel is shown in the topic, as the panel shows it to everyone in the studio.
- `confirm()` in the docked WebView2 view is the browser's own dialog. If a view ever blocks dialogs, the question can't be answered, so nothing that
  asks first is sent (safe), but the switch can't be changed from there.
