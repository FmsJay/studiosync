# Signed studio files, sent over the direct link first (rt-linkfirst, 2026-11-20)

James asked: "could the grants travel through the direct link? And is there anything else still relying on syncthing that could also use the
direct link?"

## Summary for James

- **Yes: grants now go over the link.** When an admin lets someone edit (or takes it back), the grant reaches the computers in the room at
  once. Each one checks it and it counts straight away. In the two-computer stand-in that took well under a second, even with the slow test
  signer. Syncthing's copy still arrives a few seconds later and stays the record.
- **What moved to the link:**
  - grants
  - a room's mode (Claims / Open / Driver only / Admins only)
  - band.json (the studio's settings and roles) and roles.json
  - closing the studio
  - removal and guest marks, and taking one back
  - guest project lists and guest invitations
  - devices files (NAT entries and Tailscale names)
  - profiles (name, picture flag), colours and session recaps

  Status, presence, chat, events, claims, the sheet and the rest already went both ways.
- **Why it's safe: stage B of rt-lite is done (signed writes).**
  - Every computer now signs the studio's manager-only files with its own key. The extension's signing is used as it is, so the C++ is unchanged
    and there's no new extension release.
  - Before this, a link message was only signed with the studio's shared secret, which every member has. So a message alone couldn't prove who
    sent it.
  - Now each file carries its writer's own signature. The receiver checks that signature, the writer's key, and that the file isn't an old copy
    put back. Only then does it run the same trust check it runs on Syncthing's copy.
  - This also closes trust.lua's old gap ("a forged Syncthing client could still lie about modifiedBy"), and ids are compared in full, not by
    their first 7 characters.
- **Nothing old breaks.** Files from older StudioSync versions (no signature, or one left stale by a rewrite) are still judged by Syncthing,
  exactly as today. A key counts only once that computer's devices file has been believed the usual way.
- **What's left on Syncthing, and why:**
  - catch-up's list of what's missing
  - media and takes as the record
  - restore points, mixes and stems
  - getting `_band` to a new joiner
  - the update code itself
  - a handful of small files

  These are big, need a secret handled differently, or would put two writers on one file while Syncthing runs. The table below has effort and
  risk for each one.

## What was built

### 1. Signed writes beside Syncthing's check

| Piece | Where |
|---|---|
| This computer's key: `~/.studiosync/device-key`, made by `StudioSync_KeyCreate(path)`; signs with `StudioSync_Sign(keypath, msg)`, checks with `StudioSync_Verify(sig, msg, key) == 1` (signatures from `extension/sign.cpp`) | `lib/signed.lua` `key`, `my_id` |
| Every `band.write_json` of a signed kind writes `<file>.sig` beside it (`lib/signedwrites.lua`'s sidecar: studio, path, sequence number, bytes). `band.remove` of a removal mark leaves a signed tombstone. One hook in `band.write_json` and `band.remove` reaches every writer. | `lib/band.lua` `signed_hook`; `lib/signed.lua` `on_write`, `on_remove` |
| Signed kinds: `_band/band.json`, `roles.json`, `closed.json`, `removed/*`, `guest-access/*`, `guest-invites/*`, `joins/*`, `devices/*`; `<song>/rooms/<room>/mode.json`, `driver.json`, `room.json`, `grants/*`, `claims/given-*` | `lib/signed.lua` `KINDS` |
| Each devices file carries its computer's public key (`key`) | `lib/removal.lua` `publish` |
| Whose key is which computer: noted only when `trust.device_ok` believes a devices file the usual way (Syncthing says the computer it names wrote it). It's never learnt from a signature. Kept per studio in ExtState `signed keys <studio id>`. | `lib/trust.lua` `device_ok`; `lib/signed.lua` `note_key`, `computer_of` |
| Trust takes a file when its signature is good and the key is a known computer's, compared by the **whole** id (the bound Syncthing id). In every other case it falls back to Syncthing's `modifiedBy`, as before. A copy that came by the link has no Syncthing answer, so for it the signature is the only word. | `lib/trust.lua` `changed_by`, `is`, `deleted_by_manager` |
| Rollback: the highest sequence number accepted per file, in ExtState `signed seqs <studio id>`, at most 600 files. An older number is never a signature's word. Only a signer some check accepted moves the mark (`took`). | `lib/signed.lua` `fresh_ok`, `taken`; `lib/trust.lua` `took` |
| Whole ids: `trust.is(id, by)` compares whole when `by` is a whole id (from a signature) and by 7 characters only for Syncthing's short `modifiedBy`. `self_rename` compares two whole ids from files. | `lib/trust.lua` |

Every existing trust rule is kept: who may write roles, the owner-only roles change, held invited computers, the 120-second "not yet",
studios from before owners, and the caches. Only where `by` comes from is new.

### 2. Link-first delivery

- **Sending.**
  - A signed (or OWN) file written here goes into a non-persisted ExtState outbox, so the panel, the web UI and Live sync all feed it.
  - Live sync's tick empties it (`signed.drain`) to the peers in its room, plus those in the file's own room, as a `signed` message
    `{ rel, body, side }`.
  - `direct.STUDIO_WIDE` lets that kind through from any room.
  - band.json holds the studio's secret, so it never goes to a peer with a removal mark or a peer the link can't name.
- **Receiving** (`signed.on_msg`). The checks, in order:
  1. The kind is one that comes over the link, and the path is a plain studio path.
  2. Size limits: 32 KB body, 2 KB sidecar.
  3. The signature is valid for this studio and path.
  4. The key is a known computer's.
  5. The number is newer than any taken.

  Then the copy goes into `band.overlay` and the reader's own trust check runs (`trust.file_ok`):

  | Kind | Check |
  |---|---|
  | band, roles, guest lists, mode | `from_manager_file` |
  | closed.json | `from_owner_file` |
  | removal marks | `mark_ok` or `deleted_by_manager` |
  | devices files | `device_ok` |
  | grants | `claim_ok` plus `may_manage` |

  A "no" takes the copy out again. A room's mode.json, which nothing checks when Syncthing brings it, must be a manager's when it comes over
  the link.
- **Reading it at once.**
  - `band.read` and `band.files`/`band.listing` read the link's copy in place of the folder's for as long as the folder's file is still what it
    was when the copy came.
  - As soon as the folder's file changes, the overlay goes and the folder is read again with its own checks. That change can be Syncthing's
    copy, the record, or anyone's newer write.
  - Nothing is written into the shared folder, because writing there would make this computer Syncthing's last writer.
  - Caches emptied when a copy goes in or out: `band.info`, `groups.trusted`, `direct`'s devices list, `profile` and `people` colours.
- **OWN files** (profiles, colours, recaps) are one person's each, and nothing checks them today. They go the same way unsigned, with the
  same shape check their readers make: the file's name is its person's.

Grants, mode changes, band settings and roles, closing, removal marks, guest lists and devices files now reach the bandmates here in about
one tick plus the link's ~30 ms. Grants are read by `sync.authority` on every edit, so they take effect at once.

### Shared files touched (small, additive)

- `StudioSync - Live sync.lua`: the `signed` handler and `signed.drain` in the tick (4 lines).
- `lib/band.lua`:
  - `read_raw`, plus the overlay in `read`, `files` and `listing`
  - the write and remove hooks
  - `set_overlay` and `overlay_of`
- `lib/direct.lua`: `STUDIO_WIDE` in `dispatch`, and `forget_devices`.
- `lib/groups.lua`: `forget_trusted`. `lib/people.lua`: `forget`.
- `lib/profile.lua`: the picture cache key includes the picture's size, because a profile can now arrive before its picture.
- `lib/removal.lua`: `key` in the devices file.
- `lib/trust.lua`: as above.

New: `lib/signed.lua`, `tests/test_0_60_rt_linkfirst.lua`.

## What's still on Syncthing (inventory, updated)

**Already on the link before today:**
- events: the file, plus an `event` message for object changes
- cues, presence and heartbeats, own claims and claim asks, chat, live MIDI
- streamed takes, and media files with `media_want` for catch-up
- Jam, punch-ins, Ableton Link, hops, follow and editing views, controllers, bounces, the Sheet, video-call setup
- NAT offers over links that are already up

Notes on the timeline are `note` events, so they went already.

**Moved today:** see the summary.

**Signed today but not sent over the link:**
- invitation records
- given claims
- driver.json: a `driver` event already goes
- room.json

| Still on Syncthing | Could the link carry it? | Effort | Risk |
|---|---|---|---|
| **Catch-up's need list** (`/rest/db/need`) | Yes. Each writer's list of event ids per room (events are written once by their maker, and media is named by events), traded over the link. Syncthing stays the backstop. | 2-3 sessions | Medium: deciding "complete" is subtle. Low while Syncthing remains the backstop. |
| **Media and takes as the record** | The link already brings them fast into the inbox. Making the link's copy the record means writing into the folder, which puts two writers on one file while Syncthing runs. That only makes sense in No Syncthing mode (rt-lite stage D). | 2 sessions (in D) | High while Syncthing runs |
| **Restore points** (`recall/`) | Yes. Link files (`DirectSend`) after each save, one writer per file and no trust check. They're medium-sized, and only for those here. | 1 session | Low |
| **Mixes and stems** (`<Song>/mixes`, bounce results) | Yes, as streams. `bounces` already coordinates over the link. | 1 session | Low, but heavy on bandwidth |
| **`_band` bootstrap** for a new joiner | The studio's secret has to be sealed to the joiner's key in the join welcome, and sealed again after a removal (rt-lite stage D). | 2-3 sessions | High: secret handling |
| **The update code** (`_tools`, signed by the owner) | Yes. A bandmate could serve it over the link, since its signature check (`lib/files.txt.sig`) already exists. | 1-2 sessions | Medium: it's the code-run path, though signatures guard it |
| session.json and `hub/<person>.json` (one person's own files, `own_file_ok`) | Yes, signed. The own-file rule works with a known key. | 1 session | Low |
| Given claims | Yes. `sync.claims_files` caches by file stat, so it needs to see the overlay. | 0.5 session | Low |
| Profile pictures (binary, up to 10 KB) | Yes, base64 in the message, with `band.size` made overlay-aware | 0.5 session | Low |
| `released/*` (claims a driver released), `<Song>/chat/resolved`, plug-in lists, libraries, drum maps, room summary and status | Yes, as OWN files (nothing checks them) | 0.5-1 session for all | Low |
| NAT first contact (`_band/nat/*` before any link is up) | Needs another meeting point: the hub's address or the cloud folder (rt-lite stage D) | 1 session | Medium |
| Unsharing a removed computer, adding devices | That's Syncthing's own configuration | — | — |

## Tests

`tests/test_0_60_rt_linkfirst.lua` uses two stand-in computers (Ann the admin, Bee the member), each with its own folder, saved state,
Syncthing answers and modules, plus a third with no keys learnt. Ed25519 is `tools/sign_release.py`'s, the extension's twin.

- **Keys:** learnt only from a devices file Syncthing vouches for. This computer's own key is itself.
- **Accepted:** a manager's signed guest list is taken without asking Syncthing.
- **Refused:**
  - a member's signed file
  - a forged signer (another id over one's own key): no signature, so Syncthing's word
  - an unknown key: Syncthing's word (the migration)
  - an older copy put back: not the signature's word, Syncthing asked
  - a made-up computer sharing Ann's first 7 characters: refused (whole ids), while `trust.from_manager` still matches Syncthing's short id
- **Migration:** an unsigned file is judged by Syncthing; so is a stale signature (the file rewritten after signing). Both ways are tested.
- **Writing:** writes are signed and queued; removing a removal mark leaves a numbered tombstone; event files aren't signed.
- **Link:**
  - Ann's grant goes out at once through a stand-in link and is taken on Bee's computer through the real `direct.dispatch`, sent from another
    room. It counts in `grants.list` (what `sync.authority` reads) in under a second, and nothing is written into Bee's folder.
  - Syncthing's copy then takes over and the grant stands.
  - Taking it back works the same way. A replay of the first grant is refused as older.
  - band.json goes only to Bee: not to Moe, who has a removal mark, nor to an unnamed peer.
- **Link refusals:**
  - unsigned
  - one byte changed
  - a member granting
  - an unknown key
  - a non-studio file
  - a path with `..`
  - Moe's mode change (Ann's goes in at once)
  - Moe's tombstone for another's mark (Olive's for Moe's mark goes in and reads as deleted by a manager)
  - a profile naming someone other than its file (a good one goes in)
- **Syncthing path alone:** on a computer with no keys, Syncthing's word still counts.

`python tests/run.py --no-luals`: fails 0. `test_0_60_rt_drivebg` once failed its timing check ("the slow job took 2.0 s") in a full run while
other agents worked, and passed on its own. The `files_check` NOTE is the usual one: the list is made at release.

## REAPER checks for the real computers

No extension change, so the installed 1.0.28 does. Desktop as an admin and the laptop as a member, both in the same room, with the direct
link up:

1. **Keys published.** After about 30 s, `_band/devices/<you>.json` on each computer has a `key` field, and `<you>.json.sig` sits beside it.
   `%USERPROFILE%\.studiosync\device-key` exists.
2. **Keys learnt.** On the laptop, ExtState `BandSync / signed keys <studio id>` lists the desktop's Syncthing id. It may take a minute,
   after the desktop shows up in the room.
3. **Grant at once.** Set the room to Admins only. On the desktop, Who controls > "Let someone edit here…" > the laptop's person. Pause
   Syncthing on the laptop first, to prove the link carried it. Within a second, the laptop's person can edit in the room and the edit isn't
   put back (Live sync checks it). The panel's list waits for Syncthing. Revoke works the same way.
4. **Mode at once.** With Syncthing paused on the laptop, switch the room from Admins only to Open on the desktop. Within a second the laptop's
   edits stop being put back (its Live sync goes by the new mode). The panel's Who controls follows when Syncthing's copy lands.
5. **The record.** Resume Syncthing. `rooms/<room>/grants/<you>.json` and `.sig` arrive. Nothing changes on screen, and no error in the log.
6. **Older StudioSync.** If a computer on main's version (no signing) writes band.json, the others still take its settings (Syncthing's word).
7. **Removal.** Take a scratch member out. Their mark reaches the others at once, and their computer never receives the new band.json over
   the link: check the laptop's log/trace for a `signed` message to them.
8. **Log.** No "direct link, signed:" errors in the StudioSync log.

## Not done or not tested

- Not run in REAPER. The native `StudioSync_Sign`/`Verify` are used exactly as `lib/joins.lua` uses them, and their signatures were read from
  `extension/sign.cpp`.
- The overlay lives only in the script that receives it: Live sync, which enforces edits and serves the web UI. The ImGui panel, a separate
  script, sees the change when Syncthing's copy lands (about 3 s).
- Studio-wide files go only to the peers in the room Live sync is in (plus the file's own room). Bandmates in other songs get them through
  Syncthing.
- The inviter's welcome doesn't hand over the newest sequence numbers yet (rt-lite stage B listed it), so first use is still trust on first use.
- Key-made device ids for computers without Syncthing (rt-lite stage C) are not done. Keys are bound to Syncthing ids.

## Review later (security; reviews come after all features)

- **First use.** A computer that never saw a file takes the first validly signed copy, however old. The welcome could hand over the newest
  numbers.
- **Learning keys** rests on the same thing devices files always did: Syncthing's `modifiedBy` (or "Syncthing doesn't hold it", believed as
  everywhere). A forged Syncthing client could bind its own key to someone's computer once. After that, the bound key isn't replaced by a
  signature, but a later Syncthing-believed devices file with another key replaces it. That's how a reinstalled computer gets a new key.
- **Clock skew.** Sequence numbers are milliseconds and always past the last one seen. A writer whose clock is behind, and who hasn't seen
  the latest copy, sends a number older than one taken. Its link copy is then refused ("older"), and Syncthing carries it a few seconds later.
- **The seqs store is capped** at 600 files. Past that, the oldest file's number is forgotten, so first use applies to it again.
- **OWN files** (profiles, colours, recaps) over the link are only as trusted as they are through Syncthing today: anyone in the studio could
  write them. Signing them with the own-file rule would close that.
- **band.json carries the secret over the link** to bandmates here. The link is encrypted (Tailscale or SSN1), and recipients with a removal
  mark or no name are skipped. A removed member whose mark hasn't reached this computer yet could still get it, the same window
  `removal.rotate` already names for Syncthing.
- **The outbox** is a non-persisted ExtState. A write made while no Live sync runs goes when one starts, with the file as it is then.
