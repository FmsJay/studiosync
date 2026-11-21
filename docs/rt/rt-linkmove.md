# More small studio files over the direct link first (rt-linkmove, 2026-11-20)

James asked: "could the grants travel through the direct link? And is there anything else still relying on syncthing that could also use the
direct link?" rt-linkfirst (36f90ae) answered the first half and listed the rest. This takes the small, frequent files from that list.
Offline only: nothing here was run in REAPER.

## Summary for James

- **A claim someone gives, and a release, now go over the link.** Everyone in the room sees them about as fast as a grant (0.6 s on the
  real computers), not when Syncthing gets round to it.
- **So do four more files, each one person's own:** who a song's hub was handed to, a song's session.json, your track order, and your
  profile picture. Each is signed by the computer that wrote it, and another computer takes it over the link only when that person's own
  computer signed it.
- **A new member can't be handed an old copy.** The invitation's welcome now carries the newest number of each signed file, so a
  replayed older grant or settings file is refused on the joiner's first day too.
- **Catch-up can ask a bandmate what media is missing** instead of waiting for Syncthing's list. It is built and tested but **switched
  off**, because it could bring back a file someone deleted (see "The need list").
- **One line is still needed in a file I may not touch** (`lib/sync.lua`) before the person who is *given* a claim sees it at once on
  their own computer. Everyone else already does. See "Hooks".
- **Nothing old breaks.** A computer on an older build ignores these messages and gets the files from Syncthing as before. Files written
  by an older build (unsigned) are judged by Syncthing as before.
- **Not moved, on purpose:** mixes, stems, restore points and the update code. What each would take is below.
- **The timeline file** (`rooms/<room>/timeline/<user>.json`, commit 0ae5fbf) was not signed and not link-first. In a second round it
  now is both (see "The timeline file").

## Per item

| # | Item | State |
|---|---|---|
| 1 | Given claims | **Done** for every computer but the one of the person the claim is for: that waits for hook 1 (`sync.follow_claims`). |
| 1 | `released/*` | **Done.** Now signed; over the link only from the room's driver or someone in charge, from their own computer. |
| 2 | `hub/<person>.json` | **Done.** Signed and link-first. `lib/hub.lua` needed no change: it reads through `band.read` and `trust.own_file_ok`. |
| 2 | session.json | **Done** (signed; link-first when it is under 32 KB). This closes stage B's "signing session.json and `hub/<person>.json`". |
| 2 | Other per-person files | Track order **done** (it is the one that is felt: tracks follow the newest order). Not moved: the room summary, plays lists, plug-in and library lists (nothing waits on them; see the inventory). |
| 3 | Catch-up's need list | **Half done, off by default.** Media: a bandmate's list feeds the existing catch-up (`lib/needlist.lua`). Events: not done. |
| 4 | Profile pictures | **Done.** Signed and sent as base64; `band.size` reads the link's copy. |
| 4 | Other small own files | Not done: `<Song>/chat/resolved`, `chat/stage.json`, drum maps (see the inventory for why each can wait). |
| 5 | The welcome's sequence numbers | **Done.** |
| – | The timeline file (`timeline/<person>.json`) | **Done** in a second round: signed and link-first. |
| – | Mixes, stems, restore points, update code | Not moved (as asked). Costs and risks below. |

## What was built

| Piece | Where |
|---|---|
| New signed kinds: `rooms/<room>/released/<person>.json`, `rooms/<room>/order/<person>.json`, `<song>/hub/<person>.json`, `<song>/session.json`, `_band/profiles/<id>.jpg|png`. Given claims were signed already and now go over the link. | `lib/signed.lua` `KINDS`, `LINK` |
| Whose file each is, by what it says and its name: `signed.owner`. Over the link it is taken only when `trust.own_file_ok` says that person's own computer signed it. A release must also be the room's driver's or a manager's. | `lib/signed.lua` `owner`; `lib/trust.lua` `file_ok` |
| A given claim over the link: the same check as the file's (`may_manage` plus `trust.claim_ok`), and its name must be `given-<who it's for>-...`. It is taken once per computer. On a computer its file never reaches (folded in and deleted before Syncthing brought it) it counts for `GIVEN_KEEP` = 60 s. | `lib/signed.lua` `on_msg`, `tidy`; `lib/trust.lua` `file_ok` |
| A picture is bytes and the extension signs text, so a picture's signature is over its base64, and the message carries the base64. The receiver decodes it and runs `profile.image_info` (real PNG or JPEG, 10 KB, 256 px), and the picture must be the one its person's profile names. The picture is signed and queued when its profile is written. | `lib/signed.lua` `as_signed`, `on_write`, `on_msg` |
| The write hook now reaches `<song>/hub/` and `<song>/session.json` (only in a folder that is a studio's). `band.size` reads the link's copy. `band.copy` measures the folder's file. | `lib/band.lua` |
| Never an older copy over a newer one: a link copy numbered below the folder's own signature file is refused; one already taken is let go when a higher-numbered signature file lands in the folder (about once a second). | `lib/signed.lua` `on_msg`, `tidy` |
| A refused message no longer takes out the good link copy that was being read. The same message twice isn't checked twice. | `lib/signed.lua` `on_msg` |
| A "no" to a link copy is neither kept nor logged. trust.lua's verdict caches go by what a file says, not by who signed it, so a member's re-signed copy of someone's file, once refused, had the real file refused after it until REAPER restarted. | `lib/trust.lua` `probing` |
| The welcome carries `seqs`: `{ rel, number, first 16 of the signature }` for the files the inviter's computer has numbers for, the studio's own first, in the room the welcome's files leave (30 KB in all). The joiner takes each as a floor: only ever raising, never one dated more than a day ahead. | `lib/signed.lua` `known_seqs`, `seed_seqs`; `lib/joinboot.lua` |
| With the stream trace on, each signed file logs "written", "out" and "in" (or "not taken (why)") with the studio's shared clock. | `lib/signed.lua` `trace` |
| The need list (see below). | `lib/needlist.lua`; `lib/streams.lua` `catchup_tick` (8 lines); `StudioSync - Live sync.lua` (4 lines) |

### Shared files touched (small, additive)

- `StudioSync - Live sync.lua`: two handlers (`need_ask`, `need_list`) and `needlist.tick` in the tick. 4 lines.
- `lib/band.lua`: the hook's gate (1 line), `band.size` (overlay first), `band.copy` (the folder's size).
- `lib/trust.lua`: `file_ok`'s new kinds, and `probing` (5 one-line guards).
- `lib/streams.lua`: `catchup_tick` adds `needlist.pending` to its wants.
- `lib/joinboot.lua`: 3 lines.
- `tests/test_0_60_rt_joinlink.lua`: one block, the welcome's numbers.

Not touched: `lib/sync.lua`, `lib/mirror.lua`, `lib/undo.lua`, `lib/hub.lua`, `lib/livex.lua`, `lib/liveaudio.lua`, `lib/webdraw.lua`, `lib/webui/`,
and no C++.

## Hooks I need in files I may not touch

1. **`lib/sync.lua`, `sync.follow_claims`: a given claim on its own person's computer.** That function folds a given claim into the
   person's own claims and deletes the file. A link copy isn't a file, so the delete does nothing and it would fold it again on every
   pass. So today `signed.on_msg` refuses a given claim that is for this computer's person ("given to you: it counts when Syncthing
   brings it"). Two lines turn it on:

   - the loop's condition, so the link's copy is left alone until the folder's comes (`sync.authority` counts it meanwhile):

     ```lua
     if f:sub(1, #prefix) == prefix and not band.overlay_of(dir .. "/" .. f) then
     ```

   - and, at the top level beside `sync.live_claims = {}`, the word that says so:

     ```lua
     sync.GIVEN_WAITS = true -- (follow_claims leaves a given claim's link copy alone: lib/signed.lua takes one for this computer's person only then)
     ```

   The flag lives in sync.lua on purpose: if a rewrite drops the condition, it drops the flag with it.
2. **`lib/sync.lua`, `sync.follow_claims`: the orphan signature file** (since 36f90ae, not new). After `os.remove(dir .. "/" .. f)` add
   `os.remove(dir .. "/" .. f .. ".sig")`. Every given claim leaves a `given-*.json.sig` in `claims/` for good.
3. **The timeline file, in my own `lib/signed.lua`: done** in the second round (three lines; see "The timeline file").
4. **Nothing needed** in `lib/hub.lua` (handovers), `lib/mirror.lua` (`read_order` reads through `band.files` and `band.read_json`),
   `lib/profile.lua` or `lib/webui/`.

## The timeline file (second round)

`sync.session_timeline` (rt-edits, 0ae5fbf) writes the last tempo map and markers each computer sent to
`rooms/<room>/timeline/<person>.json`; `sync.timeline_reads` writes a "reads only" one before a computer has a map of its own.
`sync.studio_timeline` takes the newest stamp (`order`) among the files that are named for the person they say and that
`trust.own_file_ok` accepts. The map itself still travels as a `timeline` event; the file is what a computer opening the song, or checking
what it holds, reads. `lib/sync.lua` was read, not edited.

**What changed** (`lib/signed.lua`, three lines): the kind `timeline` in `KINDS` and `LINK`, and `signed.owner` says the file is its
`user`'s when it is named for that user. So every write of the file is signed, goes over the link at once (when it is under 32 KB), and is
taken there only when that person's own computer signed it.

**Checked by test:**

- A timeline file with a missing signature, another file under a good signature, someone else's signature, or a name that isn't its
  person's is not taken over the link, and the studio's timeline stays what it was.
- An older replay doesn't replace a newer stamp, three ways: the same person's older file is refused by its number; it is refused against
  a newer file Syncthing brought that no check has looked at; and another person's older-stamped file is taken as theirs but the newest
  stamp among the files is still the studio's.
- A computer on an older build: an unsigned file from Syncthing is judged by Syncthing's `modifiedBy` exactly as today (taken from the
  person's computer, left out from another's). An older build receiving the link message ignores it.
- The link copy and the later Syncthing copy end the same: the same studio timeline, the link's copy let go, nothing written into the
  folder by the receiver, and nothing sent on. The same message twice is not taken twice. The writer sends each write once.

**Does signing change who may write the file, where the studio pins computers?** The rule is the same: only the computer that person's
devices file names (or this computer, for its own person). Three things differ once the file carries a good signature from a key this
computer knows:

1. **The writer is the computer that signed it, not the last one Syncthing saw change it.** A file another computer copies or puts back
   unchanged, with its signature file, is still its author's. Before, Syncthing named the computer that put it there and it was set aside.
2. **Ids are compared whole.** A computer whose id shares the owner's first 7 characters no longer passes (Syncthing's `modifiedBy` is 7
   characters).
3. **"Syncthing doesn't hold it" no longer says yes by itself.** An unsigned file Syncthing has no record of is believed, as everywhere in
   trust.lua. A signed one is judged by its signer even then.

Unchanged: a file with no signature, a stale one (an older build rewrote the file), a key not known here yet, or a number older than one
taken all fall back to Syncthing's word. A person's second computer (not the one their devices file names) is set aside either way. A
studio from before owners (no pins) believes anyone, either way.

**What the link adds here is small.** The link's copy is read only by the Live sync that received it, and that one has already had the
map as an event. A computer that opens the song later reads the folder's file, which Syncthing brought. So the gain is the signature
(who wrote it no longer rests on Syncthing's word alone) and that the others see sooner that this computer reads these files, and stop
writing session.json's timeline for it.

**Costs to know.** Every timeline change now also signs the file and sends it (up to 32 KB) to the bandmates here, beside the `timeline`
event that already goes. While someone on an older build is in the main room, `sync.session_timeline` also rewrites session.json; that
copy is signed and sent too, and refused over the link everywhere unless the writer is the song's sharer (it comes by Syncthing as
before). Both stop mattering once rt-edits' "old readers" are gone.

## How fast, and how to measure it on three real computers

Each of these should arrive as a grant does: one Live sync tick on the writer (the outbox is emptied each tick), the link (about 30 ms),
and the receiver's next tick. Expect **about 0.6 s**, the figure measured for a grant. A file written by the ImGui panel (a given claim, a
release) waits for Live sync's next tick on that computer first.

Setup, once, on all three computers (desktop as an admin, laptop and a third as members), all in one room with the link up:

1. Turn the trace on, on each computer, with a one-line ReaScript:
   `reaper.SetExtState("BandSync", "stream trace", "1", true)`. The trace is `<REAPER resources>/StudioSync/direct/stream_trace.log`
   (the same file the stream tests read). Set it back to `""` afterwards: the log grows.
2. Wait a minute after all three are in the room, so each has learnt the others' keys (ExtState `BandSync / signed keys <studio id>`
   lists the other two).
3. Pause Syncthing on the two members, so only the link can have carried it.

Then for each file, do the action on the desktop and read three lines:

- desktop trace: `signed written <path> at T0` and `signed out <path> at T1`
- each member's trace: `signed in <path> at T2`

`T2 - T0` is the time from the write to it counting on that computer. All three are on the studio's shared clock, so they subtract directly.
A line `signed <path> not taken (why)` says why a computer refused one.

| File | Action on the desktop | The path in the trace | What to see on the others |
|---|---|---|---|
| Given claim | Who controls > a member > Give them control of > selected track | `<Song>/rooms/<room>/claims/given-<name>-<time>.json` | The third computer's "who controls" shows the track as theirs. The member themself: "not taken (given to you ...)" until hook 1 is in; after it, they can edit the track at once. |
| Release | As the driver, with a member away: Release X's claims | `.../released/<you>.json` | X's tracks follow the driver again. |
| Track order | Drag a track to a new place, then stop | `.../order/<you>.json` | The others' tracks follow at their next order pass (tab in front, stopped). |
| Hub handover | Hand the song's hub to another computer (`hub.hand_song`, wherever the build's UI offers it) | `<Song>/hub/<you>.json` | The others name the new hub as the song's home. |
| session.json | Publish the session again (StudioSync - Publish session) | `<Song>/session.json` | "in" on the others (no "out" line on the desktop means it was over 32 KB). |
| Timeline file | Add a marker or change the tempo | `.../timeline/<you>.json` | "in" on the others within a second (the marker itself arrives as the `timeline` event, as before). After Syncthing resumes, `timeline/<you>.json.sig` is beside the file on every computer, and reopening the song on a member opens on the desktop's markers and tempo with no "set aside" line in the log. |
| Profile picture | Web UI > your profile > a new picture | `_band/profiles/<you>.json`, then `.../<you>.jpg` | The picture changes on the others' pages within a second. |

Then resume Syncthing on the members: every file arrives, nothing changes on screen, and no `*.sync-conflict-*` appears.

The welcome's numbers: invite a fourth computer (or a scratch studio's joiner, as rt-joinlink's checks). Afterwards its ExtState
`BandSync / signed seqs <studio id>` holds entries for files it has never read, such as `_band/joins/<id>.json`.

## The need list (item 3)

Today `streams.catchup_tick` asks Syncthing what this computer still needs (`/rest/db/need`) and fetches those media files over the link.
So catch-up starts only after Syncthing has found the others, traded its index, and been asked (every 30 s): typically 30 to 90 s after
coming online.

**Built:** `lib/needlist.lua`. Every 30 s, and at once when who is here changes, a computer asks one bandmate in its room (each in turn)
what media that computer holds in the song's rooms. The answer is a list of `{ room, file, size }`, 300 a message, only files last written
30 s ago or more. What the asker lacks goes into catch-up's wants beside Syncthing's, and the same `media_want` fetches it with the same
checks (the link's name rule, nothing in place already, no tombstone in the room's `deleted/`, the very size the bandmate has). A list the
asker has been through isn't sent again until it changes, so the steady state is one small message per 30 s.

**Switched off.** It runs only where ExtState `BandSync / link need list` is `1`, on both computers.

**Why off:** a bandmate's folder is a weaker judge than Syncthing. If someone deletes unused media, the bandmate still holds it until
Syncthing carries the delete there. Fetching it back would undo the delete for everyone (the VM test's "four unused WAVs came back" again).
Guards in place: tombstones are respected, and a file this computer held since Live sync started and no longer holds is never wanted.
Not covered: a file deleted while this computer's Live sync wasn't running, that the bandmate still holds.

**To test on real computers** (then decide whether it goes on by default): switch it on on all three. Take one offline, record two takes
on another, bring the first back with Syncthing paused: its trace shows `media want` and `media in` within a few seconds of the link coming
up, and the takes are in the room's media folder. Then, with Syncthing running everywhere, delete an unused WAV from a room's media on one
computer and watch for a minute: it must not come back anywhere.

**Not done: events.** A computer that was away still gets the events it missed from Syncthing. Trading them (each writer's event names per
day, then the missing files as link files into the inbox) is the other half of rt-linkfirst's "2-3 sessions". It needs no file I may not
touch, only time: about 150 lines and a test of what `sync.receive` does with old events arriving in the inbox while it is being rewritten.

## Not moved: what each would take, and what it would risk

| What | What moving it takes | Risk |
|---|---|---|
| **Mixes and stems** (`<Song>/mixes`, bounce results) | A stream per file, as media goes today (`direct.stream_start`), offered when the bounce finishes, placed where Syncthing would put it, then a rescan. `lib/bounces.lua` already coordinates over the link. One session. | Bandwidth: a mix is tens of MB and a stem set hundreds, sent to everyone here at once while they may be playing. It needs a rate cap or "on demand" (send when someone opens the mix). Two writers on one file if Syncthing's copy lands mid-stream (the media path already handles that with its temp name and rescan). Low for trust: nothing reads a mix as an instruction. |
| **Restore points** (`recall/`) | Link files after each save, one writer per file. Medium size (a project's state). One session. | Low. They matter only to someone who restores, and nobody restores within the 3 s Syncthing takes. The gain is small; the cost is every save going to everyone twice. |
| **The update code** (`_tools`, signed by the owner) | A bandmate serves the files over the link; the receiver checks `lib/files.txt.sig` as it does today before anything runs. 1-2 sessions. | Medium to high. It is the path that decides what code runs. The signature check guards it, but a second way in doubles what a security review has to cover, for a file set that changes a few times a week and isn't felt when it takes a minute. Leave it on Syncthing until the review. |
| **Media and takes as the record** | The link's inbox copy would have to be written into the folder as the record. | High while Syncthing runs (two writers on one file). Only in No Syncthing mode (rt-lite stage D). |

## What's still on Syncthing only (inventory, updated)

**On the link before rt-linkfirst:** events, cues, presence, own claims and asks, chat, live MIDI, streamed takes and media, Jam, punch-ins,
Ableton Link, hops, views, controllers, bounces, the Sheet, video-call setup, NAT offers over links that are up.

**Moved by rt-linkfirst:** grants, a room's mode, band.json and roles.json, closing, removal and guest marks, guest lists and invitations,
devices files, profiles, colours, recaps.

**Moved now:** given claims, releases, track order, hub handovers, session.json, profile pictures, the timeline files; the welcome's
sequence numbers; and, switched off, catch-up's media list.

| Still on Syncthing | Could the link carry it? | Why it waited |
|---|---|---|
| A timeline file over 32 KB (a long tempo map, many markers, project settings) | Not as one message. | The link's message limit. Signed all the same. |
| Catch-up for **events** | Yes (see "The need list"). | Time. |
| Catch-up's media list by default | Built, off. | The delete-comes-back risk, until tested. |
| A given claim on its own person's computer | Yes. | Hook 1. |
| driver.json, room.json, invitation records | Signed already. driver.json has a `driver` event. | Nothing is felt: room.json changes when a room is made or renamed. |
| Room summary (`summary/<user>.json`), plays lists, plug-in lists, libraries | Yes, as own files. | Nothing waits on them: they feed the song chooser's preview and the Plug-ins page. Signing them adds a signature write to files rewritten often. |
| `<Song>/chat/resolved`, `chat/stage.json`, drum maps, plug-in translations | Yes. | Several writers per file or no person in the file to check a signature against; ticking a note off is not felt at 3 s. |
| session.json and timeline files over 32 KB | Not as one message. | The link's message limit. Rare. |
| Mixes, stems, restore points, the update code, media as the record | See the table above. | On purpose. |
| `_band` for a new joiner beyond the welcome's 30 KB; a new secret after a removal | Sealed per device (rt-lite stage D). | Secret handling. |
| NAT first contact (`_band/nat/*`) | Needs another meeting point. | rt-lite stage D. |
| Unsharing a removed computer, adding devices | No: that's Syncthing's own configuration. | — |

Also still true from rt-linkfirst: the link's copy is read only by the script that received it (Live sync, which enforces edits and serves
the web UI). The ImGui panel sees a change when Syncthing's copy lands. Studio-wide files go to the bandmates in the room Live sync is in.

## Tests

`tests/test_0_60_rt_linkmove.lua` (rt-linkfirst's rig: stand-in computers, each with its own folder, saved state, Syncthing answers and
modules; real Ed25519 through `tools/sign_release.py`). For each file:

- **By the link first:** it counts at once on another computer, by its signature, with Syncthing not asked and nothing written into the
  folder. Then Syncthing's copy arrives and nothing changes.
- **By Syncthing only** (a computer with no keys learnt, files unsigned as an older build writes them): judged exactly as before.
- **A bad signature:** unsigned, one byte changed, a member's signature in someone else's file, a member giving himself a claim, a file
  under another person's name, a PNG under a `.jpg` name, bytes that aren't a picture, a picture no profile names. All refused, and the
  copy read before stays.
- **An older replay:** refused as older than one taken; refused as older than the folder's copy when a newer file is there that no check
  has looked at; let go when a newer signature file lands. A given claim replayed after it was folded in and deleted: refused.
- **An older build:** a receiver whose link doesn't know these kinds refuses them without a word or a log line.
- **Given claims:** counted on a third computer at once; let go after a minute where no file ever comes; on the person's own computer
  refused without `sync.GIVEN_WAITS` and kept until the folder's copy with it; after a member's forged copy is refused, the admin's real
  one (the same words) is still taken.
- **Releases:** a member who isn't the driver is refused; the same member as the room's driver is taken.
- **The timeline file:** see "The timeline file".
- **The welcome's numbers:** without them a computer new to the studio takes a replayed first grant (first use); with them it refuses it,
  asks Syncthing about the same old file put into the folder, and still takes the newest copy. A lower number, one three days ahead, a
  path outside the studio and junk change nothing.

`tests/test_0_60_rt_joinlink.lua`: after a real welcome, the joiner holds the inviter's numbers for band.json and for a file the welcome
doesn't carry.

`tests/test_0_60_rt_linkmove_need.lua`: the need list off does nothing; on, the ask, the list (settled media only, not an `.exe`), the
wants, the usual `media_want` going out with Syncthing silent, the bandmate streaming it back; an unchanged list not sent again; a long list
in parts; lists from a computer not here, oversized, or naming paths refused; a file deleted here not fetched back; wants that expire.

`python tests/run.py --no-luals`: fails 0, here and in a clean clone of each commit.

## Not done or not tested

- **Not run in REAPER.** Signing uses `StudioSync_Sign`/`Verify` exactly as rt-linkfirst does. The base64 path for pictures was tested
  with the Python twin only.
- **Not pushed by me.** Commits are made locally; the coordinator pushes.
- **A person with two computers.** `trust.own_file_ok` goes by the one computer their devices file names, as it does for Syncthing's
  copy. A hub handover or track order written on their other computer is refused over the link and comes by Syncthing, where the same
  rule already sets it aside for hub and session files.
- **A song this computer only lists** (lib/songsync.lua's `.stignore`) gets `session.json` but not `session.json.sig`, so there it is
  judged by Syncthing as before.
- **The given claim's minute.** If Syncthing is slower than 60 s on a third computer *and* on the claim's own person's computer, the third
  one stops counting the claim until the file arrives. That is today's behaviour, a minute later.
- **Track order** is read at `mirror.keep_order`'s next pass (tab in front, stopped). The link only gets the file there sooner.
- **The need list** lists only the top of each room's media folder (not `plugin files/`), and at most 6,000 files.

## Review later (security; reviews come after all features)

- **The own-file rule over the link** rests on `trust.own_file_ok`: the signer must be the computer the person's devices file names. In a
  studio from before owners (no pins) that check says yes to anyone, as it does for Syncthing's copy. There, any member whose key is
  known can send another person's hub handover, track order or release over the link.
- **Releases and track order had no check at all** when Syncthing brings them, and still don't. Only the link path is stricter. A member
  can still write either file into the folder.
- **`probing` in trust.lua.** While a link copy is checked, a "no" isn't cached or logged, including a "no" about another file the check
  looks at on the way (the person's devices file). That costs a repeated Syncthing question per refused message; a member could send
  many. Messages are not rate-limited per sender anywhere on the link.
- **The same roles written by an admin.** A manager's link copy of band.json that changes roles passes `file_ok` (a manager's) and is
  then refused by `trust.roles` (not the owner's), which caches that "no" by the roles and their date. The owner's real file with the same
  roles and date would then be refused until restart. The same was true through Syncthing; the link makes it invisible in the record.
- **A given claim is taken once per computer**, by spending its number in the kept store. After that its Syncthing copy is judged by
  Syncthing's `modifiedBy`, not its signature (in another script or after a restart; the same run keeps its verdict).
- **Spent and seeded numbers share the 600-entry store.** Past 600 files the oldest number is forgotten, so first use applies to it
  again, and a given claim's spent mark can be forgotten too (then a replay would count for a minute).
- **The welcome's numbers come from the inviter.** A wrong or hostile inviter can set a floor up to a day ahead, which stops that file's
  signature being believed there for a day (it falls back to Syncthing's word). The joiner already trusts the inviter for the roles.
- **Pictures.** A signature over base64 is this module's convention, not the extension's. `profile.unbase64` and `image_info` run on bytes
  from the link before the signature is checked (size-capped at 10 KB first).
- **Unsigned own files from rt-linkfirst** (profiles, colours, recaps) are still taken over the link unsigned. A picture is now stricter
  than the profile that names it. Signing those three with the own-file rule would close it (older builds would then fall back to
  Syncthing for them).
- **The folder's signature file as a floor.** `on_msg` and the tidy read the number from the folder's `.sig` without verifying it. A
  member can write a high number there to stop link copies of that file being taken (they come by Syncthing instead). It can't make
  anything be taken.
- **The need list** tells a bandmate in the room the names and sizes of the song's media. They hold the same folder. A list can make this
  computer ask for files (never place one by itself); the existing `media` path already lets a bandmate offer a file by name. The
  delete-comes-back risk is the reason it is off.
- **session.json over the link** is taken only from its sharer's computer. Other computers still write it (the timeline, while older
  builds are in the room); those writes are refused over the link and come by Syncthing unchecked, as before.

## Round 3: events catch up over the link, and the panel reads the link's copies (rt-linkmove2, 2026-11-21)

rt-linkmove stopped mid-round (a usage limit) with the panel half written and not committed; rt-linkmove2 finished it. Offline only:
nothing here was run in REAPER.

### Summary for James

- **A computer that comes back asks a bandmate for the changes it missed**, not only the media. They land within seconds of the link
  coming up, in the link's inbox, and count exactly as a change that came over the link live does. It is behind the same switch as the
  media half (`BandSync / link need list`, off by default).
- **The "deleted while Live sync wasn't running" hole is closed** for media. A file is fetched from a bandmate's list only while the song
  still plays it (the newest change to some item names it), and only once the changes on their way over the link have landed. A file
  someone deleted that isn't played comes back from nowhere.
- **The panel shows a claim or a grant as fast as Live sync takes it** (about 0.6 s), not when Syncthing brings the file (about 3 s).
  Live sync keeps the copy where the panel can read it, on this computer only, and the panel checks it again itself.
- **Hooks 1 and 2 in `lib/sync.lua` are in** (rt-edits put them in). So the person a claim is *given* to sees it at once on their own
  computer too. No hooks are needed from me this round.
- **The trust.roles fix (4cc9eba) is complete.** Nothing more was needed.

### Per item

| # | Item | State |
|---|---|---|
| 1 | Event catch-up over the link | **Done, off by default** (`lib/needlist.lua`). What has to be true to switch it on is below. |
| 1 | The "deleted while Live sync wasn't running" hole (media) | **Closed** by fetching only what the folder's own changes say the song plays. |
| 2 | The panel reads the link's copies | **Done** (`lib/signed.lua`, `lib/band.lua`). Studio-wide files reaching other rooms: not built, what it takes is below. |
| 3 | trust.roles verdict cache (4cc9eba) | **Checked: complete.** |

### What I kept and changed of rt-linkmove's unfinished work

Kept, as designed: the shared place (`<REAPER resources>/StudioSync/direct/<studio id>/.linked/<path>` and a non-persisted ExtState
`linked files`), `signed.import` taking each line through the same `accept` a link message gets, and the "folder's file still what it was"
fingerprint. Kept: its test block.

Fixed:

- **A random test failure, and a real bug under it.** The tidy walked `linked` with `pairs` while `band.read` inside it could take another
  script's new copy into `linked` (Lua leaves that walk undefined). About one run in three, Syncthing's copy landing didn't take the link's
  copy off the shared list. The tidy now walks a list of paths made first.
- **The panel never ended a given claim's minute.** Only Live sync's `signed.drain` ran the tidy, so with Live sync stopped or busy the
  panel kept a given claim until the folder changed. `band.read` now runs `signed.import` whenever the shared list isn't empty; the import
  takes new lines only when the text changed, and runs the tidy (at most once a second) either way. It guards against running inside itself.
- Not mine and left alone: the one-line `edited_at` change in `StudioSync - Live sync.lua` is rt-edits'.

### Item 1: events over the link

**How.** The media ask (`need_ask`, every 30 s and at once when who's here changes) now also carries, when due, this computer's event ids
per room and day: for each day of the last `EV_DAYS` (58) days, a count and a sum of the ids' hashes. The bandmate compares each day with
its own (the folder and the link's inbox) and sends back its ids for each day that differs (`need_list` with `room` and `evs`, 300 a
message, 6,000 at most). This computer asks for the ids it lacks (`need_ask` with `want`), and the bandmate sends those files with
`StudioSync_DirectSend`, the way every new change goes. The extension puts them in the link's inbox, and `sync.receive` takes them as any
change that came over the link. Due when who's here changes, and again on the next round after a round that asked for something, so the
ids stop going once two computers agree.

**Safe because:**

- Nothing is written into the studio's folder. The inbox copy is read only on this computer, until Syncthing's file lands (then the inbox
  copy is pruned). So this can't undo anyone's delete, and Syncthing stays the record.
- Who may make each change is checked when it is applied, exactly as for a change from Syncthing or from the link live. Event files are
  not signed anywhere, so "trusted as Syncthing's" means the same file, the same checks.
- Never an id in the room's `trimmed/` lists (history trim's deletion record, which travels by Syncthing), and never one made more than 58
  days ago. History trim takes only changes older than `trim.DAYS` (60), so the window alone keeps trimmed changes out; the list is a
  second guard.
- Never this computer's own changes, never a name the link wouldn't carry (`direct.rel_ok`), never a room this computer doesn't have,
  never one already in the folder or the inbox. A list from a computer that isn't here on the link is refused.
- The inbox normally drops a change named more than a day old. Fetched ones are older, so the room's inbox gets a `.boot` mark (as an
  invitation's welcome does), which keeps them a day from now.
- The bandmate sends at most 6,000 files a minute to one asker, 300 a message.

**The media half's hole, closed.** A link want is let through to catch-up only while (a) no change asked for over the link is still on its
way for the song (at most 60 s), and (b) the song as this computer has it plays the file: `drive.media_in_use` over every room's events,
the inbox's too (the rule the cloud copy already uses to decide a delete). A file deleted while Live sync wasn't running is either unused
(never fetched) or still played (fetched back, as the cloud copy brings it back too, and as the project needs it to play). Syncthing's own
need list is not filtered: it's Syncthing's word, as before.

**Still not covered.** A file whose deleting change hasn't reached either computer yet, by Syncthing or the link, and that the song as this
computer has it still plays. That needs a change nobody but the deleter has, so it's a delete Syncthing would also be racing.

**What has to be true to switch both halves on by default:**

1. The three-computer checks below pass: changes and takes arrive within seconds with Syncthing paused; the delete checks never bring a
   file back; no `*.sync-conflict-*` anywhere afterwards.
2. A big song measured once: the first in-use read of 20,000 events (spread at 50 ms a catch-up look, every 5 s), and how long a list a
   week away makes. If either hurts, keep the switch per song.
3. The default comes in the build that has this round's filter. A computer on rt-linkmove's first build, switched on by hand, has the media
   half without the filter and should be switched off or updated.
4. James decides whether the review-later items below (no per-sender rate limit, the hash sums) wait for the security review.

### Item 2: the panel

**How.** When Live sync takes a signed file from the link and its check says yes, it also writes the file and its signature file to
`<REAPER resources>/StudioSync/direct/<studio id>/.linked/<path inside the studio>` and adds a line to the non-persisted ExtState
`BandSync / linked files`: the studio folder, the path, a generation, a fingerprint of the folder's file at that moment, the given-claim
deadline, and whether it's a removal. Every script's `band.read` (and listings) looks at that ExtState. A new line is taken into that
script's own overlay through the same `accept` a link message gets (signature, key, number, the folder's signature file, `trust.file_ok`),
and only while the folder's file still matches the fingerprint. A line gone takes the copy out. Live sync removes a line, and the files,
when it lets go of its copy (Syncthing's file landed, a higher-numbered signature file, a given claim's minute). The panel does the same
for a given claim's minute by itself.

Not shared: the unsigned own files (profiles, colours, recaps), which nothing in the panel checks today.

**Studio-wide files reach only the bandmates in Live sync's room** (and those in the file's own room). What reaching everyone would take:
`signed.drain` would send the studio-wide kinds (band.json, roles.json, closed.json, removal and guest marks, guest lists, devices files,
profiles, colours, pictures) to every computer the studio's devices files name that has a Tailscale name, not to `direct.peers` of one
room. That needs a studio-wide peer list in `lib/direct.lua` (its peer builder with `present` = nil, minus anyone with a removal mark, as
band.json's secret rule does now), and the receivers already take a `signed` message whatever room it was sent from. Costs: a send to every
bandmate's computer whether or not it's in a session (the extension's send to an unreachable one times out on its sending thread, behind
the others), and it still reaches only computers where Live sync runs. About half a session. Not built.

### How to check on three computers

Desktop as an admin, laptop and a third computer as members, one song, the link up. On each computer, once, in a one-line ReaScript:
`reaper.SetExtState("BandSync", "link need list", "1", true)` and `reaper.SetExtState("BandSync", "stream trace", "1", true)`. The trace is
`<REAPER resources>/StudioSync/direct/stream_trace.log`. Set both back to `""` afterwards.

**Events.**

1. Quit REAPER on the third computer and pause Syncthing there (Syncthing's own page, Pause All).
2. On the desktop, in the room: move a few items, add a marker, record a short take. Wait a minute (so the take is 30 s settled).
3. Start REAPER on the third computer and Live sync in the same room, Syncthing still paused.
4. Within about 10 s: the third computer's trace says `event catch-up: N changes in main asked of <desktop or laptop>`, the bandmate's says
   `event catch-up: N changes in main sent to ...`; the moves and the marker are in the third computer's project; then `media want` and
   `media in` for the take, and the take plays. `<REAPER resources>/StudioSync/direct/<studio id>/<Song>/rooms/main/events/` holds the
   changes and a `.boot` file.
5. Resume Syncthing on the third computer. Within a minute the inbox folder empties (each file goes when the folder's copy is there),
   nothing moves in the project, no `*.sync-conflict-*`.

**The delete hole.**

1. Make a take on the desktop, let it reach everyone, then delete its item and wait for everyone to have the delete (the file is unused now).
2. Quit REAPER on the laptop, leave its Syncthing running. Pause Syncthing on the third computer.
3. On the desktop, delete that WAV from `<Song>/rooms/main/media`. Wait until the laptop's Syncthing has deleted it there (the third still
   has it).
4. Start the laptop's REAPER and Live sync with the third computer in the room. Watch a minute: the laptop's trace has no `media want` for
   that file, and it stays gone. Resume the third's Syncthing: it goes there too and comes back nowhere.
5. The other way: a WAV the song still plays, deleted the same way, does come back on the laptop (as the cloud copy brings it back). That's
   the intended rule, and the log on the desktop says the file is still played.

**The panel.**

1. Pause Syncthing on the laptop and the third computer. Open the ImGui panel's Who controls on the third computer.
2. On the desktop, Give the laptop's person control of a track. On the third computer the panel shows it within about a second (before,
   about 3 s or until Syncthing). `BandSync / linked files` (ExtState) lists the claim's path, and the copy is in
   `<REAPER resources>/StudioSync/direct/<studio id>/.linked/...`; nothing new in the studio's folder.
3. Stop Live sync on the third computer and wait a minute: the panel stops showing the claim by itself (the given claim's minute).
4. Start Live sync again, grant someone edit rights on the desktop: the panel shows the grant at once. Resume Syncthing: the line leaves
   `linked files`, the `.linked` copy goes, the panel shows the same thing from the folder's file.

### Hooks in files I may not touch

None needed. Hooks 1 and 2 (rt-linkmove's list above) are in `lib/sync.lua` at HEAD, by rt-edits. No change to `lib/streams.lua` or
`StudioSync - Live sync.lua` either: the event messages ride on the existing `need_ask` and `need_list` handlers.

### Shared files touched this round

- `lib/band.lua`: `shared_look` (looks at `linked files` from `band.read` and the listings). About 15 lines with rt-linkmove's part.
- `lib/signed.lua`, `lib/needlist.lua`: mine.

### What's still on Syncthing only (updated)

Changed since the table above:

- **A given claim on its own person's computer**: now on the link (hooks 1 and 2 are in).
- **Catch-up for events**: built, behind the switch. **Catch-up's media list by default**: still off, but the delete hole is closed; the
  switch waits for the checks above.
- **The panel** reads the link's signed copies too. It still waits for Syncthing for the unsigned own files (profiles, colours, recaps) and
  for anything Live sync isn't running to receive.

Still Syncthing only, as before: files over 32 KB (long timelines, big session.json), driver.json, room.json and invitation records, room
summaries, plays lists, plug-in and library lists, `chat/resolved`, `chat/stage.json`, drum maps, mixes, stems, restore points, the update
code, media as the record, `_band` beyond the welcome's 30 KB and a new secret after a removal, NAT first contact, Syncthing's own
configuration. Studio-wide files to computers outside Live sync's room (see item 2).

### Review later (security), added this round

- **Event ids and hash sums.** The day sums use a 32-bit FNV hash summed per day. Two different sets can collide (or be made to); then that
  day isn't compared and its changes come by Syncthing as before. Nothing wrong is taken; something can be missed.
- **No per-sender rate limit on asks.** A bandmate can ask for up to 6,000 event files a minute and the media list every 10 s. They hold the
  same folder, so nothing is disclosed, but it costs this computer's upload.
- **The event list can make this computer ask, never take.** What comes back is any event file the bandmate sends, with the same name rule
  as live events; its content is checked as any event is when applied. A bandmate could already send any event file over the link.
- **The `.boot` mark** keeps every inbox file of that room a day from the last fetch, not only the fetched ones.
- **The in-use rule** goes by this computer's own events. A hostile event naming a media file (anyone may write events into the folder)
  makes that file "played", so a link list can fetch it, never place it anywhere but its own room's media, and only a file a bandmate
  really holds at that size.
- **The shared place for the panel.** `linked files` and `.linked/` are written by Live sync and readable and writable by anything running as
  this user on this computer. Every script checks each copy again with the same checks, so a planted copy is refused unless it is genuinely
  signed by someone who may write it, and the fingerprint keeps it from being read over a newer folder file. A planted genuine older copy
  is refused by the kept numbers. A given claim's copy, once spent by Live sync, is not spent again by the panel (the panel trusts Live
  sync's spending): a planted line for a spent given claim would count in the panel, never in Live sync, which enforces edits.
- **4cc9eba closed** the "same roles written by an admin" item in the list above.

### Tests

- `tests/test_0_60_rt_linkmove.lua`: the panel block now passes every run (it failed about one in three); added: with Live sync quiet, the
  panel ends a given claim's minute and takes it off the shared list (fails without the import's tidy).
- `tests/test_0_60_rt_linkmove_need.lua`: media from a list only while the song plays it (never played, item deleted, played again);
  Syncthing's wants untouched; events: the ask carries day sums only when due, the answer lists only differing days and never one older
  than 58 days, the asker asks for exactly what it lacks (not one it has, a trimmed one, its own, or one in the inbox), writes the inbox's
  `.boot`, never asks twice; media waits while changes are on their way; the bandmate sends the files by `StudioSync_DirectSend` with the
  event's own path; the ids stop after a round that brings nothing; bad lists, rooms, oversized lists, path-like ids, asks from a computer
  not here and ids it doesn't hold are refused.
- `python tests/run.py --no-luals`: fails 0 in a clean clone of the commit.

## Round 4: a person's own claims file over the link first (rt-linkmove3, 2026-11-21)

Found in the REAPER recheck on three computers: a member released a claim that had been given to them, from the panel. Live sync on the
other computers saw it at once (the `claim` message), but a panel-like reader on LinuxBox, which reads claims through `sync.authority` as
the ImGui panel does, still showed the claim for 3.2 s. `rooms/<room>/claims/<person>.json` wasn't one of signed's kinds, so the panel
waited for Syncthing. Offline only: nothing here was run in REAPER.

### Summary for James

- **A claim made or let go now reaches the panel as fast as a given claim does** (about a second): the person's claims file is signed as it
  is written and goes over the link, and the panel reads the link's copy.
- **Only that person's own computer counts.** Over the link a claims file is taken only when it is named for the person it says it is
  from, isn't a given claim's words, and is signed by the computer that person's devices file names (`trust.own_file_ok`, as for a hub
  handover or a track order).
- **One change is still needed in `lib/sync.lua`** (which I may not touch) for computers with js_ReaScriptAPI: its claims cache would
  otherwise go on reading an older claims file that hasn't changed in the folder. Without it, a brand-new claims file, and any claims file
  changed in the last minute, already show at once; an older one waits for Syncthing as before. See "Hook".
- **Nothing old breaks.** An older build's unsigned claims file reads as before (by its name), a stale signature file falls back to
  Syncthing's word, and an older build ignores the link message.

### What changed

| Piece | Where |
|---|---|
| New signed kind `claims`: `<song>/rooms/<room>/claims/<file>.json`, after `given` (same folder), and in `LINK`. | `lib/signed.lua` `KINDS`, `LINK` |
| Whose file it is: its `user`, when the file is named for that user (`claims/<user>.json`, as `sync.claims_path` names it) and it isn't a given claim (`given` absent). `trust.file_ok` already sends every `signed.owner` kind to `trust.own_file_ok`, so `lib/trust.lua` needed no change. | `lib/signed.lua` `owner` |
| Every accepted link copy now takes its number at once, not only through trust's `took`. `trust.own_file_ok` caches a "yes" by the file's words, so a person's file going back to words it had before left its number untaken, and the copy in between could be replayed over it. Given claims keep their "spent" mark as before. | `lib/signed.lua` `accept` |

The write hook already reaches `rooms/` (`lib/band.lua` `signed_hook`), and every writer of a claims file goes through `band.write_json` on
its own person's computer (`sync.set_claims`, `sync.follow_claims`, `band.rename`), so the panel's own Claim and Release are signed too and
leave at Live sync's next tick (the outbox is the shared ExtState). Not touched: `lib/band.lua`, `lib/trust.lua`, `lib/sync.lua`.

### Hook in a file I may not touch

**`lib/sync.lua`, `sync.claims_files`: never the cache over a link copy.** With `JS_File_Stat` (js_ReaScriptAPI) the cache keeps a claims
file's words by the folder file's size and time once settled (60 s). A link copy is read in place of an unchanged folder file, so the cache
went on returning the folder's older words, and caching the link copy's words under the folder file's key would outlive the copy. Two
lines change (the `if` and the `e =` in the stat branch):

```lua
      if key and e and e.key == key and e.settled and not band.overlay_of(path) then c = e.c
      else
        c = band.read_json(path)
        -- (a read that failed, the file busy mid-replace, isn't kept: it would hide that claim until the file changed again)
        -- (nor the direct link's copy, read in place of the folder's file until that changes: kept under the folder file's size and time,
        -- it outlived the copy. lib/signed.lua, rt-linkmove3)
        e = key and c and not band.overlay_of(path) and { key = key, c = c, settled = (band.file_age(mt) or -1) >= sync.CLAIMS_SETTLE } or nil
      end
```

`band.overlay_of` returns at once when this script holds no link copies. Live sync itself doesn't depend on this (its `sync.live_claims`
already has the newer claims); the panel and other readers do.

### Tests (`tests/test_0_60_rt_linkmove.lua`, block "A person's own claims file")

- Bee releases Keys (given to her and folded in): the file is signed as written and goes over the link; Cy's Live sync counts the release
  at once by its signature (Syncthing not asked), and the panel beside it shows it before Syncthing's copy, with nothing written into the
  folder. Then she claims Horns: in the panel at once.
- An older replay: her release replayed after her new claim is refused by the number taken; on another computer it is refused against a
  newer file in the folder no check has looked at; her file going back to earlier words still takes its number, so the copy in between
  can't be replayed (fails without the `accept` change).
- Refused: unsigned, another file under her signature, Moe's signature on her file, a file named for Moe that says it's Bee's, a given
  claim's words in her own file. Her real claims stay read in Live sync and the panel.
- Syncthing's copy later: nothing changes, both scripts let the link copy go, it leaves `linked files`, nothing is sent on.
- An older build: its unsigned rewrite (stale signature file beside it) reads as before and `trust.own_file_ok` falls back to Syncthing;
  a computer with no keys learnt reads an unsigned file by its name; a receiver whose link doesn't know `claims` ignores it silently.
- The stand-in REAPER has no working `JS_File_Stat`, so these run the cache-less branch of `sync.claims_files`. The hook above was checked
  in a scratch copy with a `JS_File_Stat` stand-in on the panel (see the report).

`python tests/run.py --no-luals`: fails 0 in a clean clone of the commit.

### How to check on three computers

Desktop as an admin, laptop and a third computer (LinuxBox) as members, one song, the link up, Live sync running on all three, keys
learnt (a minute in the room). Trace on, on each: `reaper.SetExtState("BandSync", "stream trace", "1", true)` (set back to `""` after).

1. Pause Syncthing on the desktop and LinuxBox.
2. On the desktop, give the laptop's person a track (Who controls > Give them control of). On the laptop, from the panel, Release it.
3. On LinuxBox the panel (or the panel-like reader) stops showing the claim within about a second. Its trace: `signed in
   <Song>/rooms/<room>/claims/<laptop person>.json`; the laptop's: `signed written` then `signed out` for that path.
   `BandSync / linked files` on LinuxBox lists the path, and the copy is under `<REAPER resources>/StudioSync/direct/<studio id>/.linked/`.
4. On the laptop, Claim another track from the panel: LinuxBox's panel shows it within about a second.
5. Resume Syncthing: `claims/<person>.json.sig` arrives beside the file on every computer, the line leaves `linked files`, nothing
   changes on screen, no `*.sync-conflict-*`.
6. With js_ReaScriptAPI installed and the `lib/sync.lua` hook not yet in, step 2 on a claims file last written more than a minute before
   still waits for Syncthing on LinuxBox's panel: that's the hook's case. With it in, it doesn't.

### Costs

Every claims write (a claim, a release, an auto-claim's touch, at most once a minute per claim) also signs the file, writes a `.sig`
beside it (one more small file for Syncthing) and sends the file over the link (up to 32 KB; bigger stays on Syncthing). Each person's
claims file per room takes a place in the 600-entry numbers store.

### Not done or not tested

- Not run in REAPER.
- The hook above (in another agent's file).
- **An older folder copy can still briefly replace a newer link copy**, as for every kind: if Syncthing brings an earlier write after the
  link brought a later one, the folder's file is read (it changed) until Syncthing brings the latest. Live sync is covered by
  `sync.live_claims`; the panel sees the earlier words for that moment, as it did before this change.
- `band.rename` removes the old name's claims file and leaves its `.sig` (harmless: claims are listed by `.json`).

### Review later (security), added this round

- **The Syncthing path for claims files is still unchecked**: a claims file counts by its name alone, as before. Only the link path is
  checked. A member can still write another person's claims file into the folder. Checking it there (`trust.own_file_ok` in
  `sync.authority`) is a `lib/sync.lua` change and costs a Syncthing question per file until signed.
- **Studios from before owners** (no pins): `trust.own_file_ok` says yes to anyone, so any member with a known key can send another
  person's claims file over the link, as for hub handovers and track orders. The folder path already allowed the same.
- **Claims files fill the numbers store** (600 entries) faster; past it the oldest number is forgotten and first use applies to it again.

## Round 5: catch-up when Syncthing is paused, found by the LinuxBox test (rt-catchup, 2026-11-21)

The LinuxBox test (2026-11-21) ran the "Events" check above and found three gaps, and one question about deleted tracks. Offline build and
tests only: nothing here was run in REAPER.

### Summary for James

- **Catch-up now works when Syncthing is paused or broken on the computer that comes back.** Before, that computer read everyone's status
  file as stale, so nobody was "here", the link had nobody to talk to, and nothing was asked ("nobody else is here: you have full control").
  Now Live sync says hello over the link to the studio's computers it doesn't see, every 15 s. A bandmate in the same room answers with its
  own status, and from then on each is here for the other, whatever the files say.
- **You don't get full control on stale files.** A bandmate heard on the link is here, so the band's rules hold. And for the first 8 s of
  Live sync, while the link may not have heard anyone yet, you aren't read as alone at all.
- **The changes you missed are asked for again until someone answers.** Before, the list of your changes went once. If the bandmate didn't
  know your computer yet it dropped the ask, and the changes took 85 s or never came. Now the ask goes again after 5, 10, 20, then every 30 s,
  until a bandmate answers. A bandmate whose changes all match says so in an empty answer, and the asking stops.
- **Missing takes are found in about 5 s, not 50.** Working out which media the song plays now reads the song's changes at 16 ms a tick
  just after a start (never while playing or recording), not 50 ms every 5 s.
- **A take on a track someone deleted no longer counts as played**, even when someone else moved it before the delete reached them. That was
  a bug. It's fixed for the need list and for the cloud copy alike.
- **The hub election still goes by status files only** (why below). A computer with Syncthing paused can still think it's its song's hub
  while it's paused, as before this change.

### Item 1: a bandmate heard on the link counts as here

**Why nothing happened.** Who's here (`presence.peers`) comes from the status files, plus any status that came over the link
(`presence.from_msg`, since 0.60.0-rt). The link sends only to those here (`direct.refresh_peers`). With LinuxBox's Syncthing paused, its
copies of the others' files were over 45 s old, and the others' copy of LinuxBox's file was just as old. So neither side ever sent the other
a status, and neither ever counted the other as here. The link's half of "who's here" was in place but never got its first message.

**The fix: a hello.** When Live sync writes its status (`presence.put_status`, at least every 15 s), it also sends that status, at most
every `HELLO_EVERY` (15) s, to `direct.strangers`. Those are the studio's computers the link may send to whose person isn't here by this
computer's view:

- the devices file passes the same check as the link's own peers (`trust.device_ok`: written by that computer, by Syncthing's word or the
  file's signature);
- it has a Tailscale name on the studio's network, and the song is in their list if they're a guest (`access.shows`);
- no removal mark for that person, and not your own other computer.

A bandmate's Live sync in the same song and room takes the hello like any status off the link (`from_msg`; no change on the receiving side,
so the computers that already have this build answer too). Within `PEERS_EVERY` (2) s that bandmate's link lists this computer, and its
heartbeat (every 5 s) or its next status comes back here. Expected time from Live sync starting to both computers being here for each other
is about 3 to 8 s.

**What uses "here", and what I decided for each:**

| Gate | Uses the link's view? | Why |
|---|---|---|
| Who the link sends to (`direct.refresh_peers`, the need list, catch-up, live audio, claims, grants) | **Yes** (already merged; now it actually gets a first message) | This is what the link is for. A bandmate it can hear and send to is reachable, whatever Syncthing says. |
| Full control (`sync.present` -> Live sync's "nobody else is here") | **Yes**, plus a start hold | A status heard over the link comes from a running Live sync in this room, signed with the studio's key. Being "here" stops full control. That's the safe direction: a stale file never grants it while the link hears someone. `presence.link_hold`: in Live sync's first `HOLD` (8) s, while the link is on, you aren't alone (no log either). After that, alone is decided as before. |
| Edit holds, follow, hear, producer, claim-ask (`presence.peers` / `presence.here`) | **Yes** (unchanged: they already merged live statuses) | Same statuses as from the file, only sooner. |
| Hub election (`lib/hub.lua scan`) | **No, files only** (unchanged) | Every computer must elect from the same inputs, and other songs elect from the files alone. The others read LinuxBox's file as stale, so they never count it. If LinuxBox alone counted the link, the two views still wouldn't match. The link only takes away a holder it lost (`hub.link_watch`), never adds one. **Known cost:** a computer with Syncthing paused can elect itself its song's hub. Its hub snapshots stay in its own folder until Syncthing runs again, then travel like any file. That was already so before this round, and it's listed under "Not done". |
| "Quiet" status files (`presence.link_carries`) | Yes (unchanged) | A status written to the folder every 30 s instead of 15 once the link reaches everyone here. A computer heard only over the link is "here" and reached, so this computer's own file can go quiet. Its file is useless to a computer whose Syncthing is paused anyway. |

**Trust.** The hello and the answer are link messages: the extension signs each frame with the studio's key (HMAC-SHA256) and drops any
it can't verify. The receiver takes the status's `user` as it does for every status message. Names are chosen, and any member could already
send a status message. Sending goes only to computers that pass the link's usual device check.

**Costs.** One small message per hello to each studio computer that isn't here, every 15 to 30 s. A computer that's switched off costs its
own send lane one 3 s timeout (the extension keeps a lane per peer, so nobody else waits). The first device check for a computer this one
has never checked may ask Syncthing: one ask per hello at most, stopped after 50 ms, with Syncthing's 5 s timeout throttled to once per 30 s
per file. That's the same as `refresh_peers` for those here.

**Not covered:** a bandmate reachable only over the connection without Tailscale (`nat:` peers). It gets no hello, since `nat.peers` is
also keyed on presence. And the start hold makes a computer that really is alone wait 8 s for full control when the link is on.

### Item 2: the event ids, asked until answered

**Confirmed from the code** (`lib/needlist.lua` at 8b6c501). `ev_due` was set only when who's here changed, or after a round that asked for
something. The ask went to one peer, and the bandmate's `on_ask` dropped it when `peer_of` found no peer for the asker's device, as on a
fresh start before its link listed this computer. Nothing came back, so `ev_due` stayed false and the next 30 s round went without the ids.
They went again only if who's here changed. That's the 85 s run (who's here changed by chance) and the run where they never came.
`tests/test_0_60_rt_catchup_need.lua` reproduces it: an ask dropped by a bandmate that doesn't know the asker, and with the old code the next
tick sends no ids.

**Fix.** An ask that carried the ids waits for an answer (`ev_wait`). If none has come, the ids go again after `EV_RETRY` (5) s, then 10,
20, then every `EVERY` (30) s, until a bandmate answers. Each retry goes to the next bandmate in turn. Any id list from a bandmate here
counts as the answer. A bandmate whose days all match now answers with an empty list (`need_list { dev, evs = {} }`). An older asker refuses
that message (it has no room), so nothing changes for it. When who's here changes, the wait starts over.

**Trace lines added** (with `stream trace` on): `event catch-up: ids sent to <peer> (try N)` on the asker, and `event catch-up: an ask from
<name>'s computer dropped: not here for this one yet` on the bandmate.

### Item 3: the first read of which media the song plays

`in_use` read the song's changes at 0.05 s per call, and only catch-up's look called it, every `CATCHUP_LOOK` (5) s. Each call also listed
every room's events again. With 2,700 changes that's about 50 s. Now:

- the read resumes where it stopped (`pass`: the listing is made once per read);
- `needlist.warm` reads `WARM` (16 ms, the cloud copy's `WORK_BUDGET` for its first round since REAPER started) every Live sync tick from
  `streams.tick` until the read is through. `needlist.tick` starts it once the switch is on, before the link has any peers, so the read is
  usually done before a bandmate's list arrives. It never runs while playing or recording, as with the cloud copy's planning;
- a change that lands over the link (an `ev_wanted` one) clears the cached read, so a take that only the new change plays is wanted on the
  same look, not 5 s later.

Test: 2,700 changes at 0.2 ms a read. The bandmate's file is wanted on the first catch-up look after its list arrives (5 s; before the fix,
50 s). No tick reads for longer than 16 ms plus one file. What's left of the wait is catch-up's own 5 s look.

### Item 4: a take on a deleted track

**Verdict: a bug, fixed.** `drive.media_in_use` decided "played" from each item's own newest change. When a track is deleted, its items
normally get their own deleting changes. But an edit to one of those items made elsewhere before the delete arrived (a move, a trim) is newer
than the delete. So the item's newest change didn't remove it, and its file counted as played. Yet every computer drops that edit
(`mirror.lua on_gone_track`: a change to something on a track the band has deleted), and the item exists nowhere. Now an item whose track's
newest change removed the track isn't played. A track that comes back (a newer change to it, such as a restore) makes its items count again.

This is shared code. For the need list it closes a small form of the "deleted while Live sync wasn't running" hole: such a file is no longer
fetched from a bandmate. For the cloud copy, a file played only by items on deleted tracks, once gone from a room's media, is now written down
as deleted (tombstoned) instead of brought back with "still played". That's the same rule as a take whose item was deleted. The event
summaries in `lib/drive.lua` and `lib/needlist.lua` now keep each change's `obj` and `track`.

### The REAPER re-check (LinuxBox, its own Syncthing paused; James OK'd this, never the desktop's or the laptop's)

All three computers on the build with this round, one song, all in the same room, the link up. On each computer, once, in a one-line
ReaScript: `reaper.SetExtState("BandSync", "link need list", "1", true)` and `reaper.SetExtState("BandSync", "stream trace", "1", true)`. The
trace is `<REAPER resources>/StudioSync/direct/stream_trace.log`; Live sync's log is the StudioSync log as usual. Set both ExtStates back to
`""` afterwards.

**A. Fresh start with Syncthing paused (items 1, 2, 3).**

1. Quit REAPER on LinuxBox. Pause Syncthing on LinuxBox only (its own web page, Pause All).
2. On the desktop, in the room: move two items, add a marker, record a 10 s take. Wait 60 s, so the take has settled and LinuxBox's copies of
   the status files are well past 45 s old.
3. Start REAPER on LinuxBox, open the song, and start Live sync in the same room. Note the time (t = 0).
4. Expected on LinuxBox:
   - Live sync's log never says "nobody else is here: you have full control". If it does, note when, and whether "... joined: the studio's
     rules are back" follows within seconds (that would mean the hello took over 8 s).
   - The trace has `event catch-up: ids sent to <desktop or laptop> (try 1)` by about t = 10 s. If it shows `(try 2)` or later, the desktop's
     or laptop's trace should show `event catch-up: an ask from <LinuxBox's name>'s computer dropped: not here for this one yet` for the
     earlier tries, and the tries stop once one is answered.
   - `event catch-up: N changes in main asked of ...` by about t = 15 s, and the bandmate's trace says `... sent to ...`. The two moves and the
     marker appear in LinuxBox's project.
   - `media want <Song>/main/<take>.wav` and then `media in` by about t = 25 s, and the take plays on LinuxBox.
   - ExtState `BandSync / direct peers <studio id> <Song>/main` on LinuxBox lists both other computers' `name:port`.
5. Expected on the desktop and laptop: the same ExtState lists LinuxBox's `name:port` within about 10 s of t = 0. Nobody's log says "nobody
   else is here".
6. Resume Syncthing on LinuxBox. Within a minute LinuxBox's link inbox (`<REAPER resources>/StudioSync/direct/<studio id>/<Song>/rooms/main/events/`)
   empties, nothing moves in the project, and no `*.sync-conflict-*` appears anywhere.

**B. The other order.** Do A.1 and A.2, then stop Live sync on the desktop and the laptop. Start REAPER and Live sync on LinuxBox (Syncthing
still paused) and wait 30 s. After 8 s "nobody else is here: you have full control" is right this time, because nobody else is running.
Then start Live sync on the desktop in the room. Expected, without touching LinuxBox: within about 10 s, LinuxBox's log says "<desktop's
name> joined: the studio's rules are back". Its trace shows `ids sent to ... (try N)`, then the event catch-up and the take as in A.4.

**C. A take on a deleted track (item 4).** Optional, about 10 minutes.

1. On the desktop, record a take `T` on a new track `Gtr`. Wait until it's on all three computers (its file in each `<Song>/rooms/main/media`).
2. On LinuxBox: stop Live sync (keep the project open), then pause Syncthing.
3. On the desktop: delete track `Gtr`. Wait 60 s.
4. On LinuxBox: move `T`'s item a little, then start Live sync in the room (Syncthing still paused). Expected: LinuxBox's move goes out and
   the desktop's delete comes in. `Gtr` is gone on LinuxBox and comes back nowhere.
5. On the desktop, delete `T`'s file from `<Song>/rooms/main/media` by hand. Wait until the laptop's Syncthing has deleted it there too
   (LinuxBox still has it, its Syncthing paused).
6. Stop and start Live sync on the laptop. Watch its trace for a minute: no `media want <Song>/main/T...` (before this round it was fetched
   back from LinuxBox's list, since LinuxBox's move was the item's newest change). With a cloud copy set up, the desktop's log doesn't say the
   file is still played.
7. Resume Syncthing on LinuxBox: the file goes there too and comes back nowhere.

### Re-check results (rt-r0, 2026-11-21, 0.59.49.92 + extension 1.0.34)

Need list and stream trace on for the run on all three, off again after. LinuxBox's REAPER quit by SIGTERM (no save), its Syncthing paused
and resumed through its REST API (`/rest/system/pause`, `/resume`); the desktop's edits through its eval hook; the take recorded from a new
track's own silent output (no input, no microphone). Times are LinuxBox's trace and log (UTC).

- **A: pass.** Desktop moved two items, added a marker, recorded a 9.3 s take while LinuxBox was down and paused; LinuxBox's Live sync
  started 22:26:04. Trace: `ids sent to james-main (try 1)` +2.9 s, `5 changes in main asked of james-main` +3.0 s (the desktop's trace:
  `5 changes in main sent to linuxbox`), `media want .../5d98c11c-04-XT_R0_take-261121_1524.flac` +6.0 s, `media in` +6.1 s; the moves,
  the marker and the take in LinuxBox's project. No "nobody else is here" on any computer. `direct peers ... Cross Test/main`: LinuxBox lists
  both, the desktop and laptop list LinuxBox. Syncthing resumed 22:26:49; at 22:27:55 LinuxBox's link inbox was empty (5 files before),
  Syncthing idle with nothing needed, nothing moved, no `sync-conflict` anywhere.
- **B: not run as written; what ran instead: one finding.** Stopping Live sync on the desktop and laptop (their tab's owner token)
  doesn't hold: Autostart starts it again within ~30 s ("starting Live sync again for ...": desktop 22:30:05, laptop 22:30:11), and on the
  desktop Autostart started **main's** Live sync (no live audio, link, hub or web UI lines; the web UI said "Live sync isn't running"; the
  realtime one, started at 22:31:12, said "already running"), so the desktop wasn't on the link at all until I handed it back to the
  realtime Live sync at 22:40. With that, what LinuxBox did (Live sync started 22:30:36, Syncthing paused, after a new take and two moves on
  the desktop) is as designed except for one timing:
  - 22:30:38 "16 changes from the others"; **22:30:44 "nobody else is here: you have full control"** although the laptop's realtime Live
    sync had been running for 24 s; 22:30:50 "James-Laptop joined"; then the trace catches up from the laptop (`4 changes asked of
    james-laptop`, the new take from the laptop at 22:30:57). So the hello took 14 s, longer than `presence.LINK_HOLD` (8 s): the laptop
    only says hello every `HELLO_EVERY` (15 s) and doesn't answer a stranger's hello at once. Either hold for one hello interval (15 s plus
    a margin) or answer a hello from a stranger with a hello straight back.
  - The desktop (main's Live sync) wasn't seen: "James is driving but isn't here" (22:31:01), right for what was running.
  - To run B as written, Autostart has to be kept from restarting Live sync (or REAPER quit) on the desktop and laptop, and the desktop must
    restart into the realtime Live sync, not main's.
- **C: steps 5-7 only, pass.** The desktop deleted the take's track, then the two take files (Recycle Bin) with the need list on: gone on
  the laptop and LinuxBox within 23 s, no `media want ...R0_take` in any trace after, and nothing came back.
- Also seen: LinuxBox's Live sync logs "Syncthing didn't answer (is it running, with a folder called ...)" at every start (55 times today):
  `services.tune_band_folder`'s `syncthing cli config folders ... get` fails from REAPER there, though the same command answers `1` over SSH.

### Shared files touched this round (small, additive)

- `StudioSync - Live sync.lua`: one line in `P.who` (`alone` also needs `not presence.link_hold(cfg)`).
- `lib/presence.lua`: the hello in `put_status`, and `link_hold`.
- `lib/direct.lua`: `refresh_peers`'s device check moved into `sendable` (unchanged), plus `direct.strangers`.
- `lib/streams.lua`: one line in `streams.tick` (`needlist.warm`).
- `lib/drive.lua`: `media_in_use`'s track rule, and `summary` keeps `obj` and `track`.
- `lib/needlist.lua`: mine (this doc's earlier rounds).
- `tests/test_0_60_rt_linkmove_need.lua`: one line, so Bee also takes Ann's (now always sent) answer to the event ids.

### Tests

- `tests/test_0_60_rt_catchup_link.lua`: with stale status files nobody is here and the link has no peers; `strangers` lists the trusted
  studio computers, never one removed, untrusted or this one; the status write sends them a hello, at most every `HELLO_EVERY`, nothing with
  the link off; a status back over the link makes that bandmate here and on the link's list (so not alone), and the hello then goes only to
  the rest; `link_hold` holds for `HOLD` s; `media_in_use` leaves out an item that went with its deleted track and counts it again when the
  track comes back.
- `tests/test_0_60_rt_catchup_need.lua`: an ask with the ids dropped by a bandmate that doesn't know the asker goes again after `EV_RETRY`,
  then doubling; a bandmate whose days match answers with an empty list, and the asking stops; with 2,700 changes a bandmate's file is wanted
  within 10 s of its list (it was 50 s) and no tick reads for longer than `WARM`; a change that lands is read on the same look.
- Each fails with its change taken out (checked one at a time: hello, hold, track rule, retry, empty answer, warm, re-read on landing).
- `python tests/run.py --no-luals`: fails 0 in a clean clone of the commit.

### Not done or not tested

- Not run in REAPER (the re-check above).
- Hub election with Syncthing paused: still files only (see the table). A computer whose Syncthing is paused can hold its song's hub
  alongside the real one until Syncthing runs again. Making the election link-aware would need every computer to share the same link view,
  which is a design change for `lib/hub.lua`.
- `nat:` peers get no hello.
- The need list is still off by default (`link need list`). This round removes two of the reasons it couldn't be on for this case. The
  switch still waits for the three-computer checks in round 3.

### Review later (security), added this round

- **The hello shows your status** (song, room, what you're editing, the hub part) to every studio computer that passes the device check, not
  only those in your room. They're studio members, and the status file is in the shared folder for all of them anyway, but this goes out
  even when you'd expect only your room's members to see it live.
- **A status message makes its sender "here"**, which turns off full control. That was already true of every status message. A member could
  keep you out of full control by sending your room a status in someone's name. They could already do that with a status file in the folder.
- **No rate limit on received hellos.** Each costs one `from_msg`, as any status does.

## Round 6: link-first leftovers (rt-p3, 2026-11-21)

Package P3 of `docs/rt/backlog.md`'s "Plan to finish": the leftovers of item 1.30, item 3.3 and 1.35's `streams.lua` cloud check. Offline build
and tests only: nothing here was run in REAPER. Commits: 0ca071c (the link-first items), 1028e3f (the need list measures 8 ms a list), and
a separate last commit, "Need list on by default", to hold back until the round 5 re-check passes (see item 1).

### Summary for James

- **Studio-wide files reach everyone in the studio, not only your room.** A change to the band's settings, a removal mark, a devices file, a
  profile or picture, and a song's session.json or hub handover now go over the link to every computer of the studio the link may send to,
  wherever its Live sync is (another room, another song). Before, a bandmate in another room had them only when Syncthing brought them.
- **Files over 32 KB go over the link too**, in parts, up to 256 KB: a big session.json, a long tempo map's timeline file. Each part is
  small enough for the link, and the whole is checked exactly as a small file is. An older StudioSync ignores the parts and gets the file
  from Syncthing, as before.
- **Take control shows in the panel at once:** driver.json goes over the link from the new driver's own computer.
- **An older copy that Syncthing brings late no longer replaces a newer one.** If the link brought a newer write first, the newer one stays
  read (at once; within a second if the older file's signature lands after it) until Syncthing brings it.
- **Catch-up's cloud check no longer reads Google Drive on REAPER's thread** when the cloud copy's worker is on.
- **A bug from round 5, fixed:** the link's 8-second start hold had the same name as the edit hold, so a bandmate's edit counted as "being
  edited" for 8 s instead of 3 (the track tint and the "Bo is editing that item too" warning stayed longer). It's 3 s again.
- **The need list on by default is ready as its own commit.** Safe to turn on once the round 5 re-check passes; until then, hold it.
- **Not done here:** a person with two computers (a design question, below) and a hello for computers reached without Tailscale (it needs
  `lib/nat.lua`, P13's, and can't help while Syncthing is paused anyway).

### Per item

| Item | Result |
|---|---|
| The need list on by default | **Built, its own commit, hold it.** Why it's safe and what's left: item 1 below. |
| Studio-wide files to computers outside Live sync's room | **Done** (`direct.studio_peers`, `signed.drain`). |
| Files over 32 KB | **Done** up to 256 KB (`signed.FILE_MAX`), in parts. |
| `driver.json` on the link | **Done** (kind `driver`, only from the driver's own computer). |
| `room.json`, room summaries, plays lists | **Not moved**, on purpose: item 4. |
| A person with two computers | **Not fixable in P3's files**: a design question, item 7. |
| `nat:` peers' hello | **Not built**: needs `lib/nat.lua` (P13), item 8. |
| An older folder copy over a newer link copy | **Done**: `band.read` keeps the link's copy at once (follow-up commit); the tidy covers a signature file landing late. |
| `streams.lua`'s cloud check off REAPER's thread | **Done** with the worker on (`drivebg.known_size`). |
| List-only songs' `session.json.sig` | P2's (`lib/songsync.lua`), not touched. |
| `band.rename` leaves an old `.sig` | **Done** (follow-up commit): the old claims and devices files' `.sig` go too. |
| Found: `presence.HOLD` set to 8 by round 5 | **Fixed** (renamed `LINK_HOLD`), item 9. |

### Item 1: the need list on by default

**Built** as the last commit: `needlist.on()` is true unless ExtState `BandSync / link need list` is `"0"` (`"1"` and `""` are on). Turning it
off on a computer: `reaper.SetExtState("BandSync", "link need list", "0", true)`.

**Is it safe now? In the code, yes; on real computers, not yet shown.** The reasons it was off are each answered in code:

- *A deleted file coming back* (rt-linkmove's first reason). A file from a bandmate's list is fetched only while the song as this computer
  has it still plays it (round 3), never one with a tombstone, never one this computer held and lost since Live sync started, and never a take
  on a track the band deleted (round 5). What's left is a file whose deleting change neither computer has yet, by Syncthing or the link:
  Syncthing races that delete too.
- *Changes* land in the link's inbox only, never in the folder, and are checked when applied like any change.
- *Nobody to ask when Syncthing is paused* (the LinuxBox test): the hello and the retried ids (round 5).
- *A big song*: the first in-use read is 16 ms a tick (round 5); a bandmate's answer now measures new files 8 ms a list (1028e3f).
- *Older builds*: the default only comes with this build, which has every filter. A computer on rt-linkmove's first build answers only if
  someone switched it on by hand there.

**Why hold it anyway:** none of the above has run on real computers (round 5's checks A-C and round 3's "The delete hole" are the test).
The re-check runs now, in parallel. If A, C and the delete hole pass, push the commit; if any fails, leave it out and the switch stays as it
was (`"1"` turns it on by hand, as before).

**Costs once on everywhere:** one small ask a bandmate per 30 s, its answer only when the list changed; on Live sync's start, the in-use read
(16 ms a tick, never while playing or recording) and, the first time a bandmate asks, new files measured 8 ms a list. The event day sums for
the last 58 days are hashed once per run on the answering side (tens of ms for 20,000 changes, not budgeted).

### Item 2: studio-wide files to every computer of the studio

`signed.drain` sends a studio-wide file (`_band/...`) or a song's own (`<song>/session.json`, `<song>/hub/<person>.json`) to the room's peers as
before, plus `direct.studio_peers(cfg, song)`: every studio computer whose devices file passes the link's own check (`trust.device_ok`, as
`refresh_peers`), with a Tailscale name on the studio's network, the song in a guest's list, and no removal mark. band.json (it holds the
secret) still never goes to a computer whose person has a removal mark or that the link can't name. A room's own files (grants, claims,
orders...) still go to that room's computers only. The receivers already took a `signed` message from any room or song
(`direct.STUDIO_WIDE`); a receiving Live sync in another room puts it where its panel reads it too.

`direct.strangers` (round 5's hello) now uses the same list minus those here and minus this person.

**Costs:** a studio-wide write is now sent to each of the studio's computers, here or not. One that's switched off costs its own send lane
one timeout (the extension keeps a lane per peer). Studio-wide files change rarely (settings, someone joining or leaving, a profile).

### Item 3: files over 32 KB

A signed file over `BODY_MAX` (32 KB) and up to `FILE_MAX` (256 KB) goes as `ceil(size / 30,000)` messages of kind `signed`, each
`{ part = { rel, i, n, sum }, data = <30,000 bytes as base64>, side = <the signature file, with the last part only> }` (about 40 KB, under the
link's 64 KB a message; base64 so the size doesn't depend on how JSON escapes the file). The receiver keeps parts per file and sum, at most
`PARTS_OPEN` (8) files half-arrived, each dropped `PARTS_KEEP` (30) s after its last part; when all `n` are in, the whole must match `sum`
and then goes through exactly the checks of a one-message file (signature, key, number, the folder's signature file, `trust.file_ok`). A
part has no `rel`, so an older build refuses it as "not a signed file", without a log line, and gets the file from Syncthing.

Over 256 KB stays on Syncthing only. Which files grow past 32 KB: session.json in a long song, a timeline file with many markers.

### Item 4: driver.json, and what isn't moved

driver.json's kind is now `driver` (it shared `room` with room.json) and it is in `LINK`. `signed.owner` says the file is its `driver`'s, so
over the link it's taken only when that person's own computer signed it (`trust.own_file_ok`). Take control (`StudioSync - Take control.lua`)
and a new room write it on the new driver's own computer, so they go at once. A handover (`sync.hand_over`, the old driver writing the new
one's name), a rename and a removal's seat handed back are written by someone else: refused over the link, they come by Syncthing as before
(the "driver" event already reaches Live sync live). Nothing checks driver.json when Syncthing brings it, before or now.

**Not moved, and why:** room.json is rewritten by whoever bins a room or adopts a fork (`rooms.bin`, `lib/forks.lua`), and nothing checks who
when Syncthing brings it, so the link has no writer to check it against; nothing waits on it (it changes when a room is made, binned or
adopted). Room summaries (`summary/<user>.json`) and plays lists feed the song chooser before someone joins: their readers aren't the Live sync
that would receive them, and the panel's shared copies carry only signed kinds.

### Item 5: an older folder copy after a newer link copy

`band.read` reads the folder's file as soon as it changes, so when Syncthing brought an earlier write after the link brought a later one,
the earlier one was read until Syncthing brought the latest. Now the link's copy keeps its bytes and signature, and the tidy (at most once a
second, on every `signed.drain` and every `band.read` while copies are shared) checks a copy whose folder file changed: if the folder's file
has a signature that checks out for its bytes and is numbered before the link's copy, the link's copy goes back in, over the folder's file as
it is now, and Live sync shares it again for the panel. A folder file without a matching signature (an older build rewrote it, or its
signature file hasn't landed yet) is read, as before. When Syncthing brings the newest, the link's copy is let go as before.

**Follow-up (once P2 freed `lib/band.lua`):** `band.read` itself asks before it drops the link's copy. Each overlay entry carries `keep`
(`signed` keeper: the same signature check on the folder's bytes, the studio id taken beforehand so it never reads band.json inside
band.read), so an older signed copy landing whole is never read, not even until the tidy; Live sync shares the copy again for the panel
then. Left: the moment the folder's file has landed but its signature file hasn't (the older file is read), until the tidy after the
signature file lands (at most a second).

### Item 6: catch-up's cloud check

`streams.catchup_tick`, alone on the link with a cloud copy, asked the cloud folder for each wanted file's size (`band.size` on Google Drive,
up to a third of a second each). With the cloud copy's worker on (`drivebg.on()`), it now reads the size from the worker's listing
(`drivebg.known_size`, never asks). A file not listed yet asks for one cloud pass per new Syncthing need list (that pass lists the folder and
brings what's there), not one a minute. With the worker off, as before (the passes then run on REAPER's thread anyway).

### Item 7: a person with two computers (not fixable in P3's files)

A person has one devices file, `_band/devices/<person>.json`, naming one computer (`removal.publish`). With two computers, each rewrites it
naming itself every 30 s ("one naming another computer is written over"), so the file flips between them. Everything keyed on it flips too:
which computer `trust.own_file_ok` takes the person's own files from (over the link and from Syncthing alike), which one the link sends to
(`direct.devices`), the NAT pairing, the key learnt. A hub handover or track order written on the computer the file doesn't name at that
moment is refused over the link, and set aside from Syncthing for hub and session files.

The fix is a devices model with a file per computer (or a list of computers per person) and a rule for who may add a person's second
computer (the first computer signs the second's entry, or a manager does). That touches `lib/removal.lua`, `lib/trust.lua` (`device_ok`,
`own_file_ok`, the pins), `lib/direct.lua`, `lib/nat.lua`, `lib/joinboot.lua` and `presence.from_msg` (which drops a status in your own name),
and it's a security design first. Suggested for section 4 as a new question: *"Should one person be able to use two computers in one
studio?"* Default: not built; a person uses one computer per studio (or a second name for the second computer).

### Item 8: a hello for `nat:` peers (not built)

The hello goes to `direct.strangers`, which has only Tailscale names. A bandmate reached without Tailscale is a `nat:<device>` peer only
while its NAT link is up, and `nat.peers` sets links up only for people here (`present[d.user]`), so a computer not here has no link to say
hello over. Two things would be needed: `lib/nat.lua` (P13's) setting links up for the studio's computers not here too when the direct link
asks (`by == "direct"`), kept out of the peers it returns; and `direct.strangers` adding `nat:<device>` for those whose link is up. But a NAT
link is met through rendezvous files in the shared folder, or stage 3's signalling over another link that's up. With Syncthing paused (the
case the hello is for) neither works for a first link, so this only helps a computer that already reaches someone. Left for P13, with the
router VM to test it on.

### Item 9 (found): the edit hold

Round 5 added `presence.HELLO_EVERY, presence.HOLD = 15, 8` for the link's start hold. `presence.HOLD` is also how long a changed object
counts as being edited (`presence.editing`: the status file's `editing` list, which drives the track tint in `lib/people.lua` and mirror's
"Bo is editing that item too" warning; 3 s since rt-merge). Loading presence.lua set it to 8 for everyone. Renamed `LINK_HOLD`; `HOLD` is 3
again.

### Hooks

1. **`lib/band.lua` `band.read`: done** in the follow-up commit (`band.set_overlay`'s new `keep`, one line in `band.read`, `signed` keeper).
2. **`lib/band.lua` `band.rename`: done** in the follow-up commit (`gone`: the file and its `.sig`).
3. **`lib/nat.lua` (P13):** item 8, still open.
4. **Section 4 of the backlog:** item 7's question, added in the follow-up commit (question 12).

### Files touched this round

Only P3's: `lib/presence.lua` (the rename), `lib/direct.lua` (`studio_peers`, `strangers`), `lib/signed.lua`, `lib/streams.lua` (the cloud
check), `lib/needlist.lua` (the measure budget; the default in its own commit). Tests: `tests/test_0_60_rt_linkmove.lua` (block "rt-p3"),
`tests/test_0_60_rt_linkmove_need.lua`, `tests/test_0_60_rt_catchup.lua`, `tests/test_0_60_rt_catchup_link.lua`, and one stand-in line in
`tests/test_0_60_rt_linkfirst.lua` (`studio_peers` on its stand-in link). Follow-up: `lib/band.lua` (`band.read`, `band.set_overlay`,
`band.rename`) with `tests/test_0_59_45_trust.lua` (a rename's old `.sig` files go) and the race block in `tests/test_0_60_rt_linkmove.lua`
(an older signed copy landing whole is never read; a signature file landing after its file: put back at the next tidy).

### Tests

- `tests/test_0_60_rt_linkmove.lua`, block "rt-p3": band.json goes to the room and to a computer in another room, never to one with a removal
  mark; session.json to its song's computers wherever they are; a grant to the room only. driver.json from Take control is taken at once by
  its signature, Moe's computer naming Ann is refused, Syncthing's copy changes nothing. A 70 KB session.json goes in 3 parts, each under 64 KB
  a message, the signature with the last, no `rel`; parts alone aren't taken, the last one in takes the whole by its signature with nothing in
  the folder; a changed part, a part after the rest expired, too many parts, a path outside the studio and junk are refused; over 256 KB
  nothing is sent. An older v1 brought after the link's v2 is read for a moment, then v2 again at the next tidy; an unsigned rewrite is read;
  Syncthing bringing the newest lets the link's copy go.
- `tests/test_0_60_rt_catchup.lua`: the cloud check's old path with the worker off; with it on, the cloud folder is never read, one pass per
  new need list while unlisted, not again for the same list, a pass when the listing has the file at its size.
- `tests/test_0_60_rt_catchup_link.lua`: `studio_peers` lists every trusted studio computer but this one and one taken out; the edit hold is 3.
- `tests/test_0_60_rt_linkmove_need.lua`: two new files a list at 5 ms each, then the rest; off only with `"0"` (the default commit).
- Each fails with its change taken out (checked one at a time: studio-wide reach, driver, parts, keep_newer, the cloud check, the hold, the
  measure budget, the default).
- `python tests/run.py --no-luals`: fails 0 in a clean clone of each commit.

### The REAPER checks (round 6)

All three computers on this build (with or without the need list commit, said per check), one song, desktop as an admin. On each, once:
`reaper.SetExtState("BandSync", "stream trace", "1", true)` (set back to `""` afterwards). The trace is
`<REAPER resources>/StudioSync/direct/stream_trace.log`. Syncthing is paused on LinuxBox only (James's OK; never the desktop's or laptop's).
Use the `bandtest` scratch song.

**A. Studio-wide files to another room (item 2).**

1. Desktop and laptop in room `main`; LinuxBox in a side room of the same song (make one: New room). Pause Syncthing on LinuxBox.
2. On the desktop, change your profile's display name (web UI > your profile). LinuxBox's trace: `signed in _band/profiles/<desktop person>.json`
   within about a second, and its web UI shows the new name. Before this round: nothing until Syncthing.
3. On the desktop, StudioSync - Publish session. LinuxBox's trace: `signed in <Song>/session.json`; `BandSync / linked files` on LinuxBox
   lists it.
4. On the desktop, give someone a grant in `main`: LinuxBox's trace has no `signed in .../grants/...` (a room's file stays in its room).
5. Resume Syncthing on LinuxBox: no `*.sync-conflict-*`, nothing changes on screen.

**B. A file over 32 KB (item 3).**

1. All three in `main`, Syncthing paused on LinuxBox. On the desktop, in the scratch song, add 600 markers with a one-line ReaScript,
   `for i = 0, 599 do reaper.AddProjectMarker(0, false, i * 2, 0, "m" .. i, -1) end`, then StudioSync - Publish session.
2. The desktop's `<Song>/session.json` (or `rooms/main/timeline/<you>.json`) is over 32 KB (check its size). The desktop's trace: `signed out`
   for it; LinuxBox's: `signed in` for the same path within a couple of seconds. The copy under LinuxBox's
   `<REAPER resources>/StudioSync/direct/<studio id>/.linked/` is the same size as the desktop's file.
3. Resume Syncthing; then Undo the markers so the song is as it was.

**C. Take control (item 4).** Syncthing paused on LinuxBox, all three in `main`, the ImGui panel open on LinuxBox. On the laptop, run
StudioSync - Take control. LinuxBox's panel shows the laptop's person as the driver within about a second; its trace: `signed in
<Song>/rooms/main/driver.json`. Then on the laptop, hand the seat to the desktop from the panel: LinuxBox's trace has `signed <...>/driver.json
not taken (not from someone who may)` (written for someone else), and the panel follows Syncthing or the "driver" event, as before.

**D. The edit hold (item 9).** Desktop and laptop in `main`, room mode Open. On the desktop, move an item. On the laptop, the desktop
person's tint on that track goes about 3 s after the move (before this round, about 8 s). Move the same item on the laptop 5 s after the
desktop's move: no "<desktop person> is editing that item too" line in the laptop's log (before this round there was one); 1 s after: there
is, as designed.

**E. Catch-up's cloud check (item 6).** Desktop with its cloud copy and the worker on (the default), perf stats on. Only when it happens
naturally: alone on the link with something Syncthing still needs, the trace says `cloud catch-up: ... may be in the cloud copy (not listed
yet)` once per need list, or `... is in the cloud copy`, and no catch-up lap goes over a few ms.

**F. The need list on by default (only with that commit deployed).** Run round 5's checks A and C and round 3's "The delete hole" without
setting `link need list` on any computer: the same results. Then `reaper.SetExtState("BandSync", "link need list", "0", true)` on LinuxBox:
its trace has no new `event catch-up` or `media want` lines from a need list after the next 30 s.

Not staged by hand: item 5 (Syncthing landing an older write after a newer link copy needs two writes a second apart and Syncthing
delivering them out of order). Offline test only.

### Not done or not tested

- Not run in REAPER (the checks above).
- Items 7 and 8.
- Files over 256 KB stay on Syncthing. The welcome's 30 KB (`lib/joinboot.lua`, P10) is unchanged.
- Restore points, mixes and stems, the update code: not moved, on purpose (the table in round 1).

### Review later (security), added this round

- **Parts are kept per file and sum, not per sender.** Any computer whose link frames verify can keep up to 8 half-arrived files (8 x 256 KB)
  for 30 s, and by opening new ones push out another sender's half-arrived file (that file then comes by Syncthing). No per-sender rate limit.
- **A link copy can now be up to 256 KB** (was 32 KB), from parts or from this computer's shared place (`.linked`).
- **Studio-wide files go to every trusted computer of the studio**, here or not, band.json with its secret included (never to one with a
  removal mark; Syncthing already gives the folder to all of them). A guest's computer gets them when its list has the song Live sync is in.
- **driver.json over the link** is taken only from the new driver's own computer; the Syncthing path is still unchecked (anyone can write it).
- **The "older folder copy" check** believes any folder copy whose signature checks out for its bytes, by any key (known here or not), when it
  says "older". The result is only ever that the link's copy, already checked, stays read; it lasts until the folder has a copy numbered as new.
