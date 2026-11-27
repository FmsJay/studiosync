# rt-ui6: the Session tab (Phase 6 of the whole UI in the web view)

Plan: `docs/rt/ui-web-plan.md`, section 6 "Wave B" > Phase 6, with 2.1-2.3, 3.4, 4.2 and James's decisions of 2026-11-27 (decision 1: "In
control" replaces "driver"; decision 4: no studio settings from a phone; decision 6: "View only" folds into the strip). Findings served
(`docs/rt/findings-2026-11-27.md`): item 1 (the panel's Home moved into the web view), 11 (names), 12 (Follow stays the one way to play together),
13 (organisation: Session holds the session's jobs), and item 9's folding (one entry per person, the menu acting on each of their computers).

## What was built

Session now has three working sub-tabs:

- **Who's here** (`#here`, drawn by `lib/webui/play.js`; the drawing moved out of `app.js`):
  - Each person, one entry with their computers under it (rt-people). Their role (owner, admin, guest) shows beside the name, plus "in
    control", playing / recording, real time, on the call, and their armed tracks.
  - A **⋯ menu** on each person. It shows only what the panel's right-click menu would offer you, and asks in the page before anything that
    changes rights:
    - Follow <name> (the one Follow, rt-follow)
    - Hand over control… (only whoever is in control)
    - Give them control of the selected tracks / region / time selection (owner and admins). The selection is REAPER's, shown in the menu.
    - Make admin… / Make member…, Make owner… (owner only)
    - Remove from the studio… (`groups.may_remove`), Keep them (owner and admins)
    - On your own entry: Change my name, colour…
  - Let edit / Revoke in Admins only, as before (grants).
  - The asks on your claims (Release / Keep) with their countdown, as before.
  - **View only** under the heading: "View only: Bo is in control. Your changes are put back; what you record stays on this computer." (or
    "admins only here"). It is the panel's banner rule, with one fix: someone an admin let edit here (a grant) isn't told View only.
  - **Who can edit**: the room's mode (Claims / Open / Driver only / Admins only, greyed unless you're the owner or an admin), who is in control
    ("Bo is in control." / "You're in control." / "... isn't here" / "Nobody else is here: you have full control"), **Take control**, and
    **Always follow whoever is in control**.
  - **Claims**: the list (yours have **Release**), then **Claim selected tracks (n)**, **Claim selected region**, **Claim time selection** and
    **Release all claims** (asks first: press twice). Whoever is in control also gets "Release <name>'s claims" for someone with claims who
    isn't here. In Admins only, a member sees "Admins only here: an admin can give you tracks to work on." instead.
  - Bandmates' **come and see** asks, with Go and Not now.
- **Play together** (play.js, as rt-follow left it: the one Follow), then:
  - **How I hear**: Local mixing. Turning it off asks whose mix: "Use the studio's mix" or "Send my faders and pan to everyone", the panel's
    two named choices. Each person's volume stays with the call's controls.
  - **Live ideas** (only when there are some): each person's count with Dismiss, Keep selected, Dismiss all.
  - The Follow list's "The driver" reads **Whoever is in control**.
- **Rooms** (new `lib/webui/rooms.js`, `lib/webrooms.lua`; it was "coming"): this project's rooms as cards (this tab, main, where each came
  from, who's in it). It offers:
  - Go, the Studio tab's Open, so a side room opens the way Open session opens it
  - Create a room, Fork project, Come see!
  - Archive (side rooms nobody has open; asks first), and Archived rooms (n) with Bring back
  - In a side room, a "Back to <parent>" part: Send selected to <parent>, Bring into / Compare with <parent>… (the comparison track by track,
    then Bring into <parent>, only for whoever is in control of the parent), and for a fork, Adopt as <parent>…
- **The strip** (`shell.js`, a 3-line additive edit): with the session topic's `viewonly`, the strip reads "View only: Bo is in control" (or
  "View only: admins only here") in place of "Bo in control".

### Files

- New: `lib/websession.lua`, `lib/webrooms.lua`, `lib/webui/rooms.js`, `tests/test_0_60_rt_ui6.lua`, `tests/rt_ui6_browser.mjs`, this doc.
- Changed (my phase's): `lib/webui/play.js` (Session: Who's here moved in, the person menu, Who can edit, Claims, How I hear, Live ideas),
  `lib/webui/app.js` (the presence drawing taken out).
- Small additive edits in shared files:
  - `lib/webui.lua`: `ACTIONS.session`, the `session` dispatch (4 lines), one tick line.
  - `lib/webui/index.html`: `rooms.js` after `play.js`.
  - `lib/webui/shell.js`: the strip's View only.
- Tests that read the moved code now read `play.js`: `tests/test_0_60_rt_claims.lua`, `test_0_60_rt_merge_p1.lua`, `test_0_60_rt_home.lua`.
- `tests/test_0_60_rt_webui.lua` stubs websession, so its publish counts stay the pages' own.
- `tests/rt_ui1_browser.mjs` checks whichever "coming" page is left, as Session > Rooms is built now.
- `lib/webpages.lua`'s play half is unchanged. Not touched: `sync`, `claimask`, `grants`, `groups`, `follow` (called only).

## The `session` topic and actions

Built once a second while any page looks (the strip reads it on every tab), sent only when it changed:

```
session = { me, role, mode, modes = { { id, name, tip } }, may_set, driver, driving, away (who is in control but away), alone, take (what taking
  control means in this mode), viewonly ("driver" | "admins" | nil), followdriver, localmix, claims (yours: { kind, name | from, to, auto }),
  locked (Admins only, not an admin), release (whoever is in control: names with claims who aren't here), sel = { tracks, regions, time } (REAPER's
  selection), people = { [computer] = { role, key (Follow's person key), can = { admin = "admin"|"member", owner, handover, give, remove, keep } } },
  ideas = { { who, n } }, said = { text, ok, n, take } }
```

`{ topic = "session", ... }` with one of the following. "Refused" says why in `said`. Each change goes through the call the panel uses:

| Ask | Who may | What runs |
|---|---|---|
| `mode` | owner and admins | `sync.set_mode` |
| `take` (and `anyway`) | anyone (as the panel's Take control) | `status.handover_check` first; if not everyone is in sync it says so and the page offers Take control anyway. Then `recall.save`, `sync.set_driver`, `sync.post` (Take control's own steps, without its boxes) |
| `handover` | only whoever is in control, only to someone here | `sync.hand_over` |
| `followdriver` | anyone | the "follow driver" ExtState |
| `localmix` (`false` needs `keep = "theirs" \| "mine"`) | anyone | `mirror.begin_local_mix` / `end_local_mix` |
| `claim` (tracks, regions, time) | anyone, except a member in Admins only | `sync.my_claims` + `set_claims` (the panel's claim) |
| `release` (one, or `"all"`) | your own | `sync.set_claims` (printing duties kept) |
| `release_for` | whoever is in control, someone not here | `sync.release_claims` |
| `give` (`{ user, what }`) | owner and admins | `sync.give_claims` with REAPER's selection |
| `admin`, `owner` | owner (`groups.set_admin` / `hand_over` refuse anyone else), this computer's page only | groups |
| `remove`, `keep` | `groups.may_remove` / owner and admins, this computer's page only | `removal.remove` / `keep` |
| `ideas` (keep, dismiss with `who`) | anyone | `tools.keep_ideas` / `dismiss_ideas` |
| `rooms = { ... }` | below | `lib/webrooms.lua` |

Rooms, `{ topic = "session", rooms = { ... } }`. The `rooms` topic carries the list only while Rooms shows (it says `want` every 10 s); the
asks to come and see go every 3 s while any page looks.

| Ask | Who may / what runs |
|---|---|
| `go` | a room of this project; `webhome.open` |
| `create` (with `fork`) | `rooms.create` / `forks.create`, then Live sync started for the new tab |
| `comesee` | `rooms.invite` |
| `archive` / `unarchive` | side rooms only, not the room you're in, nobody in it; `rooms.bin` |
| `send` | side room; `mirror.selected`, `allowed_into` (the parent's claims), `post_into` |
| `look`, then `bring` | side room; `mirror.bring_plan`; bring only by whoever is in control of the parent, what the claims there allow |
| `adopt` | a fork; `forks.adopt` (which checks the parent is open here and you're in control of it) |

## Checks for James (REAPER, after a release with these files)

Desktop and laptop, one studio project open on both, the docked web UI on the desktop:

1. Session > Who's here: both of you once each (folded, if your computers are), roles beside names, a ⋯ on each. The panel's Home shows
   the same people.
2. On the laptop's panel set Who controls to Driver only and take control there. On the desktop, the web page under Who's here and the strip
   (shrink the view to the strip) both say "View only: <laptop> is in control". The panel's own banner says the same.
3. Desktop web: Who can edit > Take control. Either it takes control at once (the panel and the laptop show you in control), or it says
   "not everyone is in sync yet: …" with a Take control anyway button. No REAPER box comes up in either case.
4. ⋯ on the laptop's person > Hand over control… > Hand over: the laptop is in control again.
5. As the owner: select two tracks in REAPER, then ⋯ on the laptop > Selected tracks: … > Give. The laptop's panel shows them as its claims.
   Make admin… / Make member… change the laptop's role (the panel's person menu agrees). Leave Make owner… and Remove… untested unless
   you want to (Keep them undoes a Remove within its minute).
6. Claims: Claim selected tracks (with tracks selected), the claim shows with Release, and Release lets it go. Release all claims asks
   "sure?" first.
7. Play together > How I hear: tick Local mixing (the panel's switch follows). Untick it: the two choices appear. Pick "Use the studio's mix".
8. Live ideas: after a Time-sync take from the laptop, its placeholder count shows. Dismiss and Keep selected work as on the panel.
9. Session > Rooms:
   - Create a room "web test". A new tab opens and Live sync starts there.
   - In it, Back to main > Bring into main… shows the comparison, then Bring into main (as whoever is in control of main).
   - Go main switches tabs.
   - Archive "web test", then Bring back.
   - Come see! makes the laptop's Who's here show the ask, with Go.
10. From the phone link: the ⋯ menu has Follow, hand over and Give, but no Make admin / owner and no Remove (it says why). A Make admin sent
    by hand from the phone is refused in the log.
11. The panel: unchanged (its Home, Rooms and person menu still work).

## Tests

- `tests/test_0_60_rt_ui6.lua` covers:
  - View only's rule: Driver only, away, alone, Admins only, granted, given a claim
  - your claims, and who's away
  - the person menu's rights for owner, admin, member, in control, leaving, yourself
  - the topic from a stand-in REAPER and studio: REAPER's selection named as the panel names parts, roles, ideas, the switches
  - every action and each refusal: a member's mode, give, keep; hand over by someone not in control and to someone away; Take control not in
    sync (said, nothing taken) then anyway (recall point, driver set, posted); claims from the selection (no repeats, not auto-claims, none
    selected, Admins only); release one, all (prints kept), for someone here or away; roles and removal from another device, by an admin, by
    the owner, twice; Local mixing off with and without whose mix; ideas
  - Rooms' model; Go, create, fork, come see, archive (the main room, someone in it), unarchive, send, look and bring (not in control of the
    parent), adopt (only a fork)
  - the tick: session once a second; rooms with the asks only, then the list once shown
  - the hooks in webui.lua, index.html, shell.js, app.js and the page files
- `tests/rt_ui6_browser.mjs` (by hand: `node tests/rt_ui6_browser.mjs`; Chrome or Edge, fake devices only) runs the real page against a
  stand-in server and checks each part of Who's here, Play together and Rooms listed above, as this computer and as another device (no
  roles, no removing). It also checks there are no page errors.

## Left for later

- **Notifications**: the come-and-see asks show on Session (Who's here and Rooms), not in the shell's bell. Phase 9/11 owns the bell.
- **Solo** (the panel's Solo / Listen on a person's card) and **each person's volume** aren't in How I hear. Volume stays with the call's
  controls. Producer's seat and "Show who's away" weren't brought over.
- **Bring into** brings every change the panel would tick by default. The panel's per-change ticks (untick what stays) aren't on the page;
  use the panel for a partial bring-in.
- **Send selected** from the web asks one question with no count of the items. The panel names the count.
- **Claims list**: the web shows a claim on a track that isn't in this project any more (the panel hides those until their owner drops
  them).
- **Folded people**: role and remove act on each of the person's computers. Give and hand over act on the first one (the panel's cards are
  per computer anyway).
- `tabs.js` still has a dead `COMING['session/rooms']` line (rt-ui1's file; harmless).
- The strip says "View only" only while a page looks (the session topic is built then, like presence).
- `lib/files.txt` needs `lib/websession.lua` and `lib/webrooms.lua` at release (tools/make_index.py).

## Review later (security)

- **Another device**: roles (Make admin / member / owner) and Remove / Keep are refused unless `StudioSync_WebUIPollHere` says the page is
  on this computer (decision 4). Everything else a phone may do is what the panel lets the same person do: the phone link acts as this
  computer's user, as for every other topic.
- **Rights**: every rights change re-checks on the computer at the time of the action, never trusting the page's own `can`:
  - groups for the mode, give, roles, remove and keep
  - `sync.driver` for hand over and release_for
  - presence for "someone here"
  - `mirror.allowed_into` and the parent's driver for bringing work into another room
- **Take control from the web** skips the script's Yes/No box, as the panel's button runs it. A box on a phone's press would sit on
  REAPER's window. It keeps the in-sync check (with its "anyway") and the recall point.
- **Names from a page**: strings up to 64 bytes, no control characters. Room names go through `rooms.bad_name` (via `rooms.create`).
  Archive, Go and the rest only act on a room `rooms.list` has.
- **Make admin / owner and Remove**: the target isn't checked against the studio's members beyond what groups and removal do. They take
  any name (as the panel's menu, which only lists people here). The page only offers people here.
