# rt-claims: four editing modes, auto-claims, asking for a claim, and letting someone edit in Admins only

James, 2026-11-20: "yes three modes, also when working into something unclaimed, auto claims it in claims mode, and when trying to edit
something someone else has claims, asks the person who claimed it to release, if released the change goes through to everyone and the person
who tried the edit takes the claim". Then: "keep open for disabling all claims and completely open editing. Admins only makes sense to as
well as a way to give guests or other users editing access as an admin+". The finding was docs/rt/rt-audit.md §7.

## Four modes

| On disk | Shown as | What it does |
|---|---|---|
| `open` (the default) | **Claims** | Anyone changes what nobody else has claimed. What you edit becomes yours while you work on it, and editing someone else's claim asks them for it (below). |
| `everyone` | **Open** | Claims off: anyone changes anything. Claims are kept but don't hold; nothing is claimed by itself and nothing is asked for. |
| `driver` | **Driver only** | Only the driver's changes reach everyone. |
| `admins` | **Admins only** | The owner and admins, whoever an admin let edit in this room (below), and whoever an admin gave something to. |

Only **Driver + claims** (`claims`) is removed. A room saved on it reads as `driver` (`sync.OLD_MODES`), and the log says so once per room
each session. `mode.json` isn't rewritten, because only the owner or an admin writes it; their next pick replaces it. A room saved as
`everyone` (the old "Anyone (claims ignored)") is Open as it was. On disk the names stay as they were, which is why Claims is `open` and
Open is `everyone`.

Updated to match: `live.MODE_INFO` and `live.DRIVING` (the panel's Who controls picker, its tooltips and Take control's words), the panel's
banner and "You're driving" line, `sync.authority`, dawedit's refusal words, the tempo put-back's words, README, docs/API.md and
docs/clashes.md.

## Letting someone edit in Admins only (`lib/grants.lua`)

- **What:** an owner or admin lets a guest (an invited guest running StudioSync) or a member edit in one room as an admin would, without
  making them a studio admin. It counts only in that room, only while it's Admins only, and only for editing the project:
  `sync.authority`'s admins branch adds `who.granted`. A claim still holds against them, as it does against an admin. A guest's other
  limits (trust, roles, what a guest can't do elsewhere) are untouched.
- **Where it's kept:** `rooms/<room>/grants/<admin>.json` holds `{ by, users = { [name] = { on, at } } }`, one writer per file, as
  `released/` does. A file counts only when its name is its `by`, that person may manage the studio now, and Syncthing says their own
  computer wrote it (`trust.claim_ok`, as for a given claim). The newest word on a person wins across files; in the same second, taking
  back wins.
- **Who can change it:** only the owner and admins (`grants.set` checks `groups.may_manage`). Granting an admin is refused, since they
  already edit.
- **Panel:** under Who controls, in Admins only, it says "Can edit here too: …". The owner and admins see **Revoke <name>** and a **Let
  someone edit here…** list of the people here now.
- **Web Who's here:** shows a "can edit here" badge. In Admins only the owner and admins get **Let edit / Revoke** on each person
  (action topic `grants`), and people with a grant who aren't here are listed too.
- **Health:** a row "Admins only in 'main': Kim edits here too (given by an admin, this room only)".
- **Log:** "James let Kim edit in 'main' as an admin would" and "Chilio took back Kim's editing in 'main'".
- **Browser guests** have no REAPER of their own: what they do goes through the host computer, under the host's rights. A grant is for
  people running StudioSync.
- **Timing:** a grant travels by Syncthing (seconds), not the direct link.

## Auto-claims (Claims mode only: not in Open)

- **What:** every change that goes out (`mirror.watch`'s `W.send`, reported through `opts.sent`) on a track nobody has claimed claims
  that track. When one look sent items on **3 tracks or more and nothing else** (a section cut or moved across the song), it claims the
  **stretch of time** they cover instead of each track. Region claims never happen by themselves: renaming or moving a region would have
  locked every part that starts inside it.
- **Only with a bandmate here.** When you're alone you already have full control, and claiming everything you touched would lock it all
  for whoever joins next.
- **They're ordinary claims.** They're written with `sync.set_claims` and sent over the link at once. They show in every Claims list (the
  web page adds "while editing"), and Release is still one click. In the claims file they're marked in `auto` (`"tracks:<name>"` gives
  the time of your last edit to it), or by the time entry's own `auto`.
- **How long one lasts:** until you release it, **leave the room** (Live sync stops, but not when it reloads for an update), or go
  **10 minutes without editing it** (`sync.AUTO_IDLE = 600`). Each edit to it touches it again, at most once a minute.
  `sync.authority` stops counting an idle one on every computer from its timestamp alone. Your own Live sync also drops it from the file
  within a minute (`claimask.tick`), and a crash is covered by the same timeout. Claiming one yourself makes it lasting.

## Asking for a claim (Claims mode)

- An edit to something someone else claimed reaches `W.refuse`, which asks `opts.ask` (`claimask.hold`) first:
  - **held** (`true`): nothing is sent and nothing is put back. `mirror.unsent` marks it, so the band's changes to it wait, and
    `mirror.unsettled` makes Live sync look again about once a second while it waits.
  - **a string**: it's put back with those words. An item's copy is kept on "(yours, not sent)", as for any refused edit.
  - **nil**: it isn't something this asks about, so it's refused as before (suggestions, Driver only, Admins only).
- **Which claim:** the one that decides the owner, the same way `sync.authority` does: a track claim, else the newest time claim over the
  spot, else the claim on the named region it starts in.
- **The ask** goes out as `claim_ask` over the direct link. The claimer sees "James wants to edit XT Rec A (30 s)" with **Release** and
  **Keep** at the top of the panel (`claimask.bar`) and in the web page's Who's here (`presence.asks`, sent back as action topic
  `claimask`). They also get a **phone alert** (`alerts.send`, kind "claim ask", at most one a minute).
- **Release:** the claim leaves the claimer's file and goes into the asker's, as lasting as it was (an auto-claim stays an auto-claim).
  The answer travels as `claim_answer`. On the next look the edit is allowed, so the held edit goes out to everyone as an owner's change.
- **Keep, or no answer in 30 s** (`ASK_WAIT`): it's put back with "Chilio kept XT Rec A" or "didn't answer". The same thing isn't asked
  for again for a minute (`COOLDOWN`); edits to it in that time are put back straight away.
- **Claimer not here** (no presence in 45 s): it's put back with "Chilio has claimed XT Rec A and isn't here to release it (the driver or
  an admin can release their claims)". The existing driver and admin release paths are unchanged. **Link can't reach them:** it's put
  back, saying so.
- **Limits:** 3 of your asks waiting at once, and 5 waiting on you (more are answered Keep). One ask per asker and thing. If the claimer
  no longer holds the claim, the ask is answered Release at once.
- **Web pages:** `dawedit.item_why` (the Song page's item edits, and dawmidi's note edits through it) no longer refuses an edit to the
  claim of a bandmate who is here. The edit is made, so `mirror.watch` holds it and asks. The reply carries `ask = "Chilio"`, and daw.js
  says "Asked Chilio for it…". The Mixer page, the phone's take picker and live keys still refuse as before (`dawedit.item_refusal`).

## Files

- New: `lib/claimask.lua`, `lib/grants.lua` and `tests/test_0_60_rt_claims.lua`, which also covers Open, the `everyone` read, grants,
  revoke, a member unable to grant, files that don't count, and a grant not leaking to another room.
- `lib/sync.lua`: modes and migration, `AUTO_IDLE`, the idle filter in `authority`, `auto` kept in step by `set_claims` (renames too),
  and `live_claim` checks `auto`'s type.
- `lib/live.lua`: MODE_INFO and DRIVING.
- `lib/dawedit.lua`: the ask instead of a refusal, and `reply.ask`.
- Shared files, small additive edits only:
  - `StudioSync - Live sync.lua`: two link handlers, `ask` and `sent` in `mirror.watch`'s opts, `claimask.flush` after the look,
    `claimask.tick`, and `claimask.leave` at exit.
  - `StudioSync - Panel.lua`: `claimask.bar`, `grants.panel` under Who controls in Admins only, the Driver + claims banner and "You're driving" text removed, and a manual Claim clearing
    the auto mark.
  - `lib/mirror.lua`: three lines in `W.refuse`, one in `W.send`, and the opts comment.
  - `lib/webui.lua`: the `claimask` and `grants` actions, `asks`, `granted` and `may_grant` in presence, and `auto` on each claim.
  - `lib/page_health.lua`: the grants row.
  - `lib/webui/app.js`, `index.html` and `daw.js`.
- Docs: README, docs/API.md, docs/clashes.md, and the comment in `StudioSync - Take control.lua`.
- Tests: `tests/test_authority.lua` (migration, and Claims in place of Driver + claims), `test_0_60_rt_dawedit.lua` (migration, and the
  refusal turning into an ask), and `test_0_60_rt_dawmidi.lua` (the migration message).

## Not tested / left as is

- Nothing has been run in REAPER yet. Two computers were simulated in one Lua (`tests/test_0_60_rt_claims.lua`), and `W.refuse` was
  driven on its own; a whole `mirror.watch` holding a real item for 30 s hasn't been tested.
- The web page's Release and Keep buttons weren't driven in Chromium. The test checks the wiring in app.js and the action handler.
- `lib/mirror.lua`'s `mode == "everyone"` branches (`mirror.owned`, the rename check) serve Open again. `room_mode == "claims"` (the
  bar's Claim it) is dead code now; it's rt-merge's file. `page_restore` passes `mode = "claims"` to `mirror.revert` as an
  internal "not free" flag, not a room mode.
- Deletes and moves of several claimed things at once still go through the older suggestion path (`W.others_claims` and `propose`), not
  through asks.
- A held plug-in or automation change waits like an item does, but its copy on Keep is the existing put-back's: an FX chain file, or
  Kept automation.
- The web page's countdown is worked out when the presence topic is drawn, so it only moves when presence changes.

## Review-later (security)

- `mode.json` itself is still read without a writer check (as before rt). Grants are checked like given claims; mode.json could get the
  same check.
- A grant names a person by display name, as claims do. If someone renames themselves to a granted name, they get the grant.
- `trust.claim_ok`'s log line for a refused file says "a claim said to be given by", which also covers grants files.
- `claim_ask.from` and `claim_answer.from` are what the message says. The link checks the studio, not the person behind a field. A member
  could send a fake "release" answer and take a claim, but anyone can already take any claim with a newer one of their own (`set_claims`:
  newest wins), so no new power is added. A fake `from` on an ask shows the wrong name to the claimer.
- An ask names a thing by track or region name, up to 200 characters with no control characters, or by a time span. Phone alerts carry
  that name to the studio's ntfy channel, as chat alerts already do.
- Auto-claim timestamps use each computer's own clock. A clock far ahead makes someone's auto-claims last longer, up to the skew.
