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
