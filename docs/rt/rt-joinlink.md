# The first copy of the studio over the link, for a computer an invitation lets in (rt-joinlink, 2026-11-20)

Roadmap "More big ideas" 6: "Joining without Syncthing's device approval step. The link can carry the invite and the first copy of the song,
so a new member is in within seconds." The invite half was built on 2026-11-19 (`lib/joins.lua`); this is the first-copy half.

## Summary for James

- **What happens now.** When the owner's or an admin's computer lets someone in with an invitation, it sends the new computer, over the
  direct link and only to it:
  - the studio's essentials (band.json, roles, removal marks, names, devices, guest lists), as the signed files they are;
  - the studio's secret, inside that welcome, which is sealed to the joiner's own key from its ask;
  - the current song as it stands: the newest change of each object, plus the media the arrangement plays, streamed.
- **Result.** The joiner's studio stops "waiting" and the song is on its Projects page. Opened, it plays straight away. Syncthing pairs in the
  background as before, and each file it brings becomes the record from then on.
- **Measured (stand-in link, offline):** a song of 770 changes went as 187, plus 12 media files (686 KB in all). It was playable two tick
  rounds after the let-in. With Autostart's 2-second tick that is about **4 s plus the link's transfer time** (well under a second for this
  size on a direct Tailscale path). Compacting the 770 changes took 0.011 s. Not measured in REAPER yet.
- **Every existing join rule is kept:** the owner/admin approval, the one-time codes, the refused-asks log, removal marks. Two rules are new:
  - an ask "again" must come with the key the first ask used, and goes back only to the first ask's Tailscale name;
  - a computer taken out since the invitation gets nothing, not even the welcome. A first copy still being sent to it stops.
- **Needs the next extension build.** It adds `StudioSync_Seal`/`StudioSync_Unseal`; EXT_VERSION isn't bumped. Without them on either side
  everything works as yesterday: today's welcome, and Syncthing brings the files.

## What was built

| Piece | Where |
|---|---|
| Sealing to one computer's static key: `"SSS1"` + hex(ephemeral X25519 key, nonce, tag, ciphertext). The key is HMAC-SHA256(shared, label, both keys); the cipher is XChaCha20-Poly1305 (Monocypher, already in the extension). It opens with the private half of `~/.studiosync/nat-key` (the key the connection without Tailscale already uses; its public half goes in the ask). | `extension/nat.cpp` `nat_seal_to`, `nat_unseal`; ReaScript `StudioSync_Seal(pub, text)`, `StudioSync_Unseal(path, sealed)` |
| The maker's side: the welcome is built and sealed. The song's main room is compacted and its media listed. Events go as link files on the invitation's channel, 500 a tick (the link holds 1,000). Media go as streams, 6 at a time and smallest first. It stops for a computer taken out. Once per invitation: an ask "again" gets only the welcome, worked out once. | `lib/joinboot.lua` `send`, `maker_tick`, `compact`, `media_of`, `files_for`, `song_for` |
| The joiner's side: the sealed welcome is opened and checked (studio, invitation, this device, this ask's nonce). Its files go into a store beside the link inbox, `<home>/direct/<studio>/.boot`. Streamed media is put in place in the room's media folder (as link media always is) and Syncthing is told. "Ready to play" is said once. The store retires on its own. | `lib/joinboot.lua` `take`, `joiner_tick`, `state`, `read`, `songs` |
| `band.read` falls back to the boot copy where the folder has no file yet (`band.boot_copy`). `band.bands()` no longer marks the studio waiting. `band.songs()` lists the boot song. | `lib/band.lua` |
| A boot copy counts as one Syncthing knows nothing of (like the link's overlay): believed only by its signature, never by Syncthing's silence. The welcome carries the keys the maker knows its bandmates' computers by; the joiner takes each only where none is noted (never replacing one). | `lib/signed.lua` `current`, `known_keys`, `seed_keys` |
| The ask carries `key` (only where the joiner can unseal) and a fresh `nonce`. The key and reply are bound at first use. An ask "again" with another key is refused as a replay; one from a computer taken out since is refused. The joiner listens on the invitation's channel into the studio's link inbox, so the song's changes land where Live sync reads link events. A sealed welcome goes through `joinboot.take`. | `lib/joins.lua` |
| The link inbox's day-long prune counts a join's first copy from when it came, not from when the changes were made. | `lib/direct.lua` `prune` (2 lines) |

### What "the newest change per object" keeps (`joinboot.compact`)

- **Objects:** the newest revision by `mirror.newer`, when every other change of that object is one it builds on (its `base_ev` chain,
  through merges). Otherwise, when two people edited it apart or a deletion raced an edit, every change of it, so the joiner's receive
  merges them as everyone's did.
- **The tempo map:** only the newest.
- **Cues** (start/stop): dropped.
- **Every other kind** (notes, likes, driver handovers, which permissions read back in time): kept.
- **Media:** the media of non-deleted items (`FILE "{media:<room>}/<file>"`).
- **Not sent:** event files over 4 MB (the link's file limit). Syncthing brings those.

### Shared files touched (small, additive)

- `lib/band.lua`: `band.read`'s fallback, `boot_copy`, `boot_songs`, and one line each in `bands` and `songs`.
- `lib/direct.lua`: `prune` (2 lines).
- `lib/signed.lua`: `current` (1 line), `known_keys`, `seed_keys`.
- `lib/joins.lua`: the ask's key, nonce and bindings, and the joinboot calls.
- `extension/nat.cpp`, `nat.h`: the seal functions and their registration.
- `tests/nat_test.cpp`: the seal checks.
- `tests/test_0_60_rt_joins.lua`: one expectation, since an ask "again" now goes back to the bound Tailscale name.

## How to use it

Nothing new to do. Invite a collaborator gives the signed invitation as before; they paste it. When the link can hear the ask, they're let
in, and within seconds their log says:

> the studio's first copy came over the link: N files, 'Song' on its way (...)

then:

> 'Song' is ready to play N s after the welcome: open it from Projects

The maker's log says "sent X the studio and 'Song' over the link (...)", then "the first copy of 'Song' went: ... in N s".

## Tests

`tests/test_0_60_rt_joinlink.lua` sets up two stand-in computers with their own folders, homes, saved state and modules: Ann (the owner, who
invites) and Jo (the joiner). A third, Eve, holds the token. A stand-in link hands messages, files and streams over only on a channel both
started with the same key, and only to a computer listening. Jo runs the real `lib/trust.lua`, and Syncthing never answers there.

- **The bootstrap.** Ann invites, Jo pastes and asks, and Ann's computer lets Jo in (the invitation's checks). The key and reply are bound,
  and the welcome goes sealed on the invitation's channel, followed by the changes and the media. Afterwards Jo's computer:
  - reads Ann's band.json, roles.json, devices files, removal mark, names, session.json and the room's mode.json, signatures included;
  - has none of them in its folder;
  - shows the studio as not waiting, with the song on its Projects list and band.info and the secret read from the boot copy.
- **The song's state.** Every object's newest change is everyone's. All three changes of the item two people edited apart are there, plus
  one tempo map (the newest), no cues, and the note and the driver change. 187 of 770 changes went. All 12 media files are placed byte for
  byte, and a deleted item's media isn't sent. The inbox prune keeps the old changes.
- **Jo's trust.**
  - The welcome's keys are taken, and an existing key is never replaced.
  - band.json, signed by Ann's computer, is believed at the first look.
  - Bo's devices file, signed by Bo's computer, is believed. A devices file naming Ann's computer but signed by Bo's is set aside.
  - roles.json from Bo's computer making himself owner is set aside, as Syncthing's copy would be.
  - Syncthing is never asked about a boot copy.
- **The secret.** It never goes over the link in the clear. Jo's key opens the welcome; Eve's doesn't, and Eve can't take it with the token.
- **Refused:**
  - a replayed welcome, both after it was taken and against a later ask with another nonce;
  - another computer with the used token (nothing sent);
  - Jo's device named with Eve's key to Eve's address (nothing sent).

  Jo asking again with its own key gets exactly the welcome again, to Jo. Once Jo is taken out:
  - asking again gets nothing;
  - a first copy still being sent stops;
  - without the extension's sealing, or without a key in the ask, there's no first copy.
- **Syncthing arriving later is a no-op.** With Ann's whole folder copied into Jo's:
  - every read is the same, as are the Projects list and the "not waiting" state;
  - the boot copies and inbox copies go, and the media is untouched;
  - the song stays playable;
  - the store retires once GRACE has passed, and the folder's copy reads on.
- **The time to playable** is printed, as in the summary.

`tests/nat_test.cpp` (CI on Mac and Linux, and `tests\build_nat_test.cmd` here) checks the sealing:

- the text is unreadable, and each sealing is fresh;
- the joiner's key opens it; another computer's key doesn't;
- one changed byte is refused;
- a missing key file is refused, and none is made to open with;
- a bad or degenerate key gives nothing;
- an empty text round-trips.

All passed here. The extension also builds with the registrations (to a scratch file, so the tracked DLL wasn't rewritten).

`python tests/run.py --no-luals`: fails 0 (the `files_check` NOTE is the usual one: the list is made at release).

## REAPER checks for the real computers

These need the new extension build on both computers (with `StudioSync_Seal`). Use a **scratch studio only, never Chilio's**. The desktop is
the owner and LinuxBox is the joiner (a new computer to the studio).

1. On the desktop, make a scratch studio (e.g. "Joinlink test") with a song that has a few tracks and items playing 2-3 recorded takes.
   Keep it open in front. Invite a collaborator and copy the `studiosync-invite:` token.
2. On LinuxBox, Paste join code with the token. Within about 2-6 s:
   - LinuxBox's log says "the studio's first copy came over the link ..." and then "'<song>' is ready to play N s after the welcome". Note N:
     that's the real time to playable.
   - The desktop's log says "sent ... over the link (N changes, M media files)", then "the first copy ... went".
3. On LinuxBox, before Syncthing has synced the folder (watch its folder state; if you pause its folder to prove the link carried it, that's
   your call), check that:
   - the Studios page shows the studio as let in, not waiting;
   - Projects lists the song;
   - opening it brings the tracks and items, and the takes play;
   - `<studio folder>/_band/band.json` isn't there yet, while `~/.config/REAPER/StudioSync/direct/<studio id>/.boot/_band/band.json` is;
   - the room's media folder has the takes.
4. Let Syncthing finish. Check that:
   - band.json and the rest arrive;
   - no `*.sync-conflict-*` files appear anywhere, especially in `rooms/main/media`;
   - nothing on screen changes;
   - about 10 minutes after band.json arrives, `.boot` is empty and ExtState `BandSync / join boots` no longer names the studio.
5. Live sync on LinuxBox: a change on the desktop reaches LinuxBox within a second. The link started with the studio's secret from the
   sealed welcome.
6. Refusals. Paste the same token on a third computer: the desktop logs "an invitation ask ... refused: it has been used already" and sends
   nothing. Take LinuxBox out of the scratch studio, then restart its StudioSync so it asks again if it was still pending: the desktop logs
   "refused: taken out since the invitation was made".
7. An older extension on either side: today's welcome and Syncthing, with no error in the log.

## Not done, or not tested

- **Not run in REAPER**, and the extension change needs a release. The seal's native code is tested (`nat_test`); the Lua uses stand-ins.
- **Only the current song's main room** goes. That's the song in front on the maker's computer if it's this studio's and the joiner may see
  it, else the newest the joiner may see. Other songs and side rooms come with Syncthing.
- **The joiner opens the song itself** from Projects (it isn't opened automatically). The ImGui Studios card says "let in" as before; the
  "ready to play" line is in the log.
- **Big studios.** The welcome holds up to 30 KB of files, most needed first. band.json and the song's session.json must fit, or there's no
  first copy. Devices files, guest lists and the rest that don't fit come with Syncthing.
- **A Windows joiner without the firewall rule** hears neither the welcome nor the first copy (as before: let in all the same, and Syncthing
  carries it).
- **Unsigned boot copies** (session.json, names.json, files from older StudioSync versions) are never believed by trust checks until
  Syncthing brings them ("not yet"). They are still read where nothing checks them, e.g. opening the song reads session.json.
- **The maker's events are read and decoded once per invitation** (about 210 ms per 10 MB of events, in Autostart).

## Review later (security; reviews come after all features)

- **The joiner's trust root is the token plus its inviter.** The welcome is keyed with the token's signature and sealed to the key the first
  ask carried, so whoever uses the token first gets in and gets the secret. That's as before: Syncthing would hand them band.json after the
  let-in anyway.
- **Keys from the welcome.** The joiner takes the inviter's map of bandmates' keys (first use per computer, never replacing one). A wrong
  binding on the inviter's computer is passed on.
- **The song's changes and media are not sealed.** They travel on the invitation's channel (HMAC with the token's signature), encrypted by
  Tailscale's WireGuard. Only the welcome, which holds the secret, is sealed.
- **No rate limit on refused welcomes.** "a welcome to X was refused" isn't rate-limited: a token holder could fill the joiner's log while its
  ask is pending.
- **Boot copies after a deletion.** A file deleted in the studio after the welcome that never arrives in the folder is still read from the
  boot copy until the store retires (GRACE, 10 minutes after Syncthing brings band.json, or 2 days at most). An example is a removal mark
  taken back. The trust checks still apply to it.
- **The seal construction is unreviewed.** It is ephemeral-static X25519, an HMAC-SHA256 key derivation and XChaCha20-Poly1305 with a random
  nonce.
- **Media into the folder.** Media is placed into the shared folder before Syncthing indexes the remote copy, as the link's media always is.
  Syncthing should take identical blocks without a conflict copy; REAPER check 4 confirms it.
