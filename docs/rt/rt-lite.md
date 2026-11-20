# StudioSync with fewer dependencies (rt-lite, 2026-11-20)

James: "potentially version or options for less dependencies (no tailscale, no syncthing, no cloud etc.)"

This is a design plus one spike. The spike is a Lua module and a test, and nothing in the shipped flow calls it. No shipped behaviour
changed.

## Summary and recommendation

- **One StudioSync with modes, not a second "lite" version.** Each dependency can already be left out, or nearly, behind a studio setting.
  The same code runs everywhere and falls back to whatever is there, as the roadmap's gates already do.
- **No Tailscale is nearly here.** The NAT stages 1-3 (`nat.cpp`, behind "Connect without Tailscale") already carry live audio and the
  direct link without Tailscale, with the hub as a relay. What's left is testing in REAPER plus three small gaps: the phone pages, invitations
  and video calls. Syncthing doesn't need Tailscale, so it still carries the record and the first signalling.
- **No Syncthing is the big one, and trust is its hardest part.** Today every "who's in charge" check asks Syncthing which computer last
  wrote a file. The spike shows that check can come from signatures instead. Each computer signs what it writes with its own Ed25519 key,
  using the extension's existing `StudioSync_Sign`/`Verify`. Its device id is made from that key, so a devices file proves itself, and any
  carrier will do: the link, the hub or the cloud. The test passes.
- **Signed writes are worth doing even in Standard mode.** They close trust.lua's own shortcut ("a forged Syncthing client could still lie
  about modifiedBy"). Doing them first makes the No Syncthing work safe to do later, whatever James decides about Syncthing.
- **Recommended order:**
  1. Test the No Tailscale stages (already built).
  2. Wire signed writes in beside Syncthing's check.
  3. No Syncthing, with a cloud folder as the post box.
  4. Minimal: only if bands ask for it. It needs one computer that's always reachable.

  Retiring Syncthing stays James's call at its gate.

## 1. What StudioSync depends on today

### Tailscale

Tailscale provides addresses, encryption, the trust model and the phone link's HTTPS.

- **Addresses and reach.** The direct link listens and connects only on 100.64.0.0/10 (`extension/direct.cpp` `tailscale_ip`, `addr_ok`,
  `connect_peer`). Live audio and hops take UDP 47281 only from there (`extension/rtaudio.cpp` `addr_ok`/`resolve`; `hopnet.cpp` rides on
  it). Peers are found by each devices file's Tailscale name on the studio's network (`lib/direct.lua` `peers_from`, `groups.tailnet` in
  `lib/groups.lua:182`). Source: roadmap "Without Tailscale: design".
- **Encryption.** WireGuard. The link adds only an HMAC with the studio secret (`direct.cpp` frames). `lib/direct.lua:138` starts the link
  only with a tailnet, or with `nat` on.
- **Trust.** Being signed in to the studio's tailnet is half of who may connect. The firewall rule admits 100.64.0.0/10 only
  (`direct.firewall_ok`).
- **Phone and browser pages.** The web UI listens on 127.0.0.1 and reaches the studio's devices only through the link's Tailscale listener
  (`extension/webui.cpp:1`, `:827`). A phone browser allows the microphone only on HTTPS, which comes from `tailscale serve` with a tailnet
  certificate (`lib/phonerec.lua:19-26`, `HTTPS_PORT` 8443). The listening page is served by `tailscale serve` too (`lib/listen.lua:3`).
- **Invitations.** A signed invitation reaches its maker over the Tailscale link. `joins.can_make` (`lib/joins.lua`) needs this computer on
  the studio's tailnet. Guest invitations carry a Tailscale guest key (`services.tailscale_guest_key`, `lib/services.lua:1070`). The
  `tailscale_only` setting (`lib/groups.lua:195`) makes Syncthing sync only over the tailnet.
- **Video calls.** WebRTC uses host candidates only, with no STUN or TURN (`lib/webcall.lua:5`). That works because Tailscale addresses are
  host candidates.

### Syncthing

Syncthing provides the record, catch-up, media, the shared folder as signalling, and trust.

- **The record.** Every file in the studio folder goes everywhere through Syncthing, and its copy is the record. The direct link's copy only
  gets there first, into an inbox outside the folder (`lib/direct.lua:1-6`, `direct.inbox`). The link carries only event files
  (`direct.rel_ok`, `lib/direct.lua:30`), plus messages and streams.
- **Catch-up.** "Syncthing stays the judge of what's missing". `streams.catchup_tick` reads Syncthing's need list (`services.need`,
  `/rest/db/need`, `lib/streams.lua:931-1060`). The link and the cloud only fetch faster what that list names, asking first whoever
  Syncthing says changed the file (`streams.catchup_peer`).
- **Media.** Takes and other media are lossless and store-and-forward ("Fast first, lossless after": "the strongest reason to keep
  Syncthing").
- **The studio's own files.** `_band/` holds band.json with the studio secret (`groups.sonobus_secret`, `lib/groups.lua:114`), roles,
  devices, removals, joins, guests, names, colours and NAT signalling. Syncthing alone carries `_band/`: the cloud copy mirrors only songs
  (`lib/drive.lua:4`; grep finds no `_band` there). Joining works by Syncthing too: `services.join_band`, `share_folder`, `add_device`.
  Taking someone out unshares them (`lib/removal.lua:460`). The join welcome deliberately carries "never the studio's secrets (those come
  with Syncthing's band.json)" (`lib/joins.lua:144`).
- **Signalling.** The NAT rendezvous files are `_band/nat/<from>-<to>.json`. Stage 3 also sends them over links that are already up, but
  the first contact still goes through the folder (`docs/rt/rt-nat3.md` "Signalling over existing links").
- **Trust.** `lib/trust.lua` believes a roles, roles.json, removal, closed, given-claim, devices, session.json or hub.json file by asking
  Syncthing which computer last changed it (`services.modified_by`: `/rest/db/file`, `modifiedBy`, `lib/services.lua:436-452`). It then
  checks that computer against the pinned manager computers (`trust.from_manager`, `from_user`, `wrote_itself`, `device_ok`, `mark_ok`,
  `claim_ok`, `own_file_ok`, `deleted_by_manager`, `from_owner_file`).
  - A file Syncthing doesn't hold (`""`) is believed: "a studio synced another way is believed, as before 0.58.69" (`trust.lua:206`). So a
    studio without Syncthing has no role checks at all today.
  - trust.lua names its own limit: "a forged Syncthing client could still lie about modifiedBy. Signed files would close both"
    (`trust.lua:9-11`).
- **Identity.** A computer's id is its Syncthing device ID (`services.my_device_id`, used in 17 lib files). Devices files, pins, NAT peers
  (`nat:<device id>`), hubs and claims all name computers by it. `services.is_device_id` checks Syncthing's shape.

### The cloud copy

The cloud copy is a Google Drive, Dropbox, OneDrive or iCloud folder (`lib/drive.lua`, `lib/cloudmodes.lua`, `lib/sessionfile.lua`).

- **What it holds.** Each room (events, recall, midi, fx, takes, trash) and the end-of-session projects.
- **What it does.**
  - It's the post box for work done alone.
  - It's catch-up's last source when nobody is on the link (`streams.catchup_tick`, roadmap "The cloud copy as the hub").
  - It's the hub's stand-in (roadmap "The cloud copy as the hub").
- **What it doesn't do.** It carries no `_band/` and so no trust, and it doesn't replace Syncthing's need list. It's optional today (the
  laptop has none).

### SonoBus and NINJAM

- **SonoBus** is replaced by built-in live audio on AOO (`extension/rtaudio.cpp`, `lib/liveaudio.lua`, band.json `live_audio`, off by
  default). `lib/sonobus.lua` still edits SonoBus's state for the Play/Jam page.
- **NINJAM** is replaced by interval streaming over the link (`lib/streams.lua`, checked in REAPER: roadmap "Step 2 checked"). ReaNINJAM
  and the relay ship in `lib/ninjam/`.
- Retiring either is James's gate (roadmap "Things that can go": lines 421-422).

### ReaImGui, js_ReaScriptAPI, SWS

The README says: "the control panel needs ReaImGui; SWS and js_ReaScriptAPI help, and Health says what's off without them".

- **ReaImGui** runs the panel: Panel, Draw, Prepare session, Radial menu and `lib/chooser.lua` (`ImGui_GetBuiltinPath`). `lib/compat.lua:407`
  wants 0.10 or newer. The docked web UI (`extension/webui_dock*`, rt-dock) is the native replacement.
- **js_ReaScriptAPI.** 134 uses in 18 files, mostly finding windows and sending them messages (`JS_Window_*`, `JS_WindowMessage_*`),
  `JS_File_Stat` (17), `JS_Mouse_GetState`, `JS_VKeys_GetState`, and `JS_Dialog_BrowseForFolder`.
- **SWS.** `SNM_Get/Set*ConfigVar*` (about 50 uses), `CF_ShellExecute`, `CF_*Preview` (A/B), `BR_*` and `NF_Get*StartupAction`.

## 2. What replaces each one now, and the gaps

| Today's job | What already replaces it | Gap |
|---|---|---|
| **Tailscale: addresses and reach** | NAT stage 1: ICE via libjuice, public STUN or the hub's STUN (`extension/nat.cpp`, `lib/nat.lua`) | Not run in REAPER yet. A double symmetric NAT needs the hub's relay plus a router port forward (stage 3). CGNAT on the hub isn't detected. |
| **Tailscale: encryption** | `SSN1` sealing: X25519 Noise-KK-style handshake + XChaCha20-Poly1305, with the studio secret as a PSK | The handshake is unreviewed (deferred to after all features). |
| **Tailscale: who may connect** | The studio secret plus each computer's static X25519 key, published in its devices file and taken only via `trust.device_ok` | `device_ok` asks Syncthing (see trust below). |
| **Tailscale: the direct link** | Stage 2: `NatRel` streams under direct.cpp, unchanged | Streamed takes over it weren't measured. No SACK. |
| **Tailscale: live audio, hops** | Stage 1: synthetic 198.18/15 addresses | The hub mix's levels for a bandmate who reaches different computers different ways (rt-nat stage 1 limits). |
| **Tailscale: relays** | Stage 3: the hub's TURN, with passwords from the studio key | Needs the hub's router to forward UDP 47298-47314, which StudioSync never does itself. |
| **Tailscale: phone pages + HTTPS** | Nothing | The web UI reaches devices only through the Tailscale listener. No HTTPS means no microphone on a phone (Record page). Options: a LAN listener behind the token (pages work, recording doesn't), or a certificate for a name the studio owns (needs a domain and DNS: a cloud dependency). |
| **Tailscale: invitations** | joins.lua's signed token is carrier-neutral | `joins.can_make` needs the tailnet to hear the ask. The ask could go over a NAT link to the hub. The first contact for a brand-new computer needs a rendezvous: the inviter's or hub's public address in the token, or the shared folder. |
| **Tailscale: video calls** | Nothing | Browsers need STUN and TURN off the tailnet. The hub's libjuice TURN is standard TURN, so pages could be handed its address and short-lived credentials. |
| **Syncthing: the record** | The link delivers events in ~30 ms, but into an inbox the folder never sees. The cloud copy holds rooms. | **Inbox to folder:** without Syncthing the link's copy has to become the record (written into the folder after its HMAC and placement checks). **`_band/` and song files:** the link sends only event files (`direct.rel_ok`) and media streams. band.json, devices, roles, removals, session.json, hub.json, mixes and stems need a way. |
| **Syncthing: catch-up** | Streams and the cloud fetch, but the list comes from Syncthing | A "what's missing" exchange of its own. Events are written once by their maker and media is named by events, so a per-writer list (or the hub's snapshot, roadmap "Project files: snapshots plus changes") is enough. There's no need for Syncthing's version vectors. |
| **Syncthing: deletions and moves** | Tombstones for media already exist (`<room>/deleted`). The cloud copy works out takes vs trash from events. | `_band` files that are deleted to mean something (a removal mark taken back, a guest mark ending) need signed tombstones. The spike has them. |
| **Syncthing: offline post box** | The cloud copy (rooms only today) | Without a cloud and without an always-on hub, two computers only exchange while both are on. Today Syncthing has that same limit. |
| **Syncthing: NAT signalling (first contact)** | Stage 3 carries offers over links that are up, via any bandmate | With no shared folder, the very first link needs another way: the hub's reachable address (stage 3's relay port) or the cloud folder as the signalling folder. The signature makes any carrier safe. |
| **Syncthing: the studio secret's distribution** | Nothing (band.json via Syncthing) | Sealed to the joiner in the join welcome (the joiner's key is in its ask). A new secret after a removal, sealed to each remaining device's key (their devices files' NAT public keys). The secret must never sit in a cloud folder in the clear: band.json's `sonobus` field would need sealing before the cloud carries `_band`. |
| **Syncthing: trust (modifiedBy)** | **The spike: signed writes** (below) | Wiring it in: writers sign, trust.lua consults the signature (and Syncthing too while it's there), whole-id compares, and key-made device ids for computers without Syncthing. |
| **Syncthing: identity** | The spike: `sw.device_id(pub)` makes a Syncthing-shaped id from a computer's Ed25519 key | `services.my_device_id()` would fall back to it when there's no Syncthing (17 files call it). A computer that has both needs one id per studio, not a mix. |
| **Cloud copy** | Optional already | Nothing to replace. No cloud means no post box when nobody else is on. |
| **SonoBus** | Live audio (`rtaudio.cpp`) | James's gate (an hour's test). Works over NAT (stage 1). |
| **NINJAM** | Interval streaming (`streams.lua`) | James's gate. Over NAT it rides stage 2's streams (unmeasured). |
| **ReaImGui** | The docked web UI (rt-dock, rt-webui pages) | The panel still is ReaImGui. Moving every panel page to the web is the web UI's own roadmap ("Web UI: what remains"). |
| **js_ReaScriptAPI, SWS** | Nothing yet. "Native speed for the hot paths" puts things in the extension anyway. | The extension can do what's used: `get_config_var` for SNM config vars, a file stat, shell open, window find/messages (Win32/Cocoa, as webui_dock already does). About 1-2 sessions per OS for the common ones. Low value: ReaPack installs both in one step. |

### Trust without Syncthing, in detail (the spike's subject)

Today each manager-only file is believed when Syncthing says a pinned manager's computer wrote it. Without Syncthing nobody can say who wrote
a file, and every carrier (the link's inbox, the hub, a cloud folder) is writable by any member. Signed writes fix this:

- **Each computer has an Ed25519 device key.** The extension already makes and uses such keys (`StudioSync_KeyCreate/Sign/Verify`,
  `extension/sign.cpp`) for signed updates and invitations (`lib/joins.lua` invite-key). Its device id is made from the key:
  `sw.device_id(pub)` is base32 of the key plus "SSK", in Syncthing's 8x7 shape, so `services.is_device_id` and every stored id take it. It
  works like Syncthing's own ids, which are a hash of each device's certificate.
- **A sidecar `<file>.sig` beside each signed file:** `{ v, by, key, seq, deleted?, sig }`.
  - The signature covers `"StudioSync signed file v1\n" studio \n path \n seq \n file|deleted \n bytes`. A file can't be moved to another path
    or studio.
  - `by` must be `device_id(key)`, so nobody can claim another computer's id over their own key.
  - A sidecar keeps every file format as it is. Older versions ignore it, and `band.files(dir, ".json")` doesn't list `.json.sig`.
- **A devices file proves itself.** It's good when signed by the key its own `device` is made from, under its own person's name. This
  replaces `trust.wrote_itself` and `trust.device_ok` without asking anyone.
- **Manager files** are checked by `sw.from_manager(pins, by)` with the same pins as today, compared in full. Syncthing's `modifiedBy` is
  only 7 characters, so trust.lua compares 7-character prefixes. That's fine for Syncthing, but a key-made id's first 7 characters could be
  matched by a made-up key, so key ids must be compared whole. The test shows a lookalike passing `trust.from_manager` and failing
  `sw.from_manager`.
- **Rollback.** Syncthing names whoever puts an old file back. A signature doesn't, so each computer keeps the highest sequence number it has
  taken per file (`sw.fresh`) and refuses an older one. A different file under a number already taken is refused too. So is a number more than
  a day ahead, which would otherwise freeze everyone else's writes. Only a signer the caller accepts moves the mark.
- **Deletions** are a signed tombstone: the sidecar alone with `deleted`. This replaces `trust.deleted_by_manager`'s reading of Syncthing's
  deletion record.
- **Out of step.** A file and its sidecar arrive separately, so a mismatch or a missing half is "not yet" (`nil`), never "yes". That's
  trust.lua's existing contract for "Syncthing didn't say", where callers keep what they had.

## 3. Modes

Each mode is a set of studio settings on the same code, not a separate build. What each one loses:

| Mode | Uses | Loses (vs Standard) | State |
|---|---|---|---|
| **Standard** | Extension + Tailscale + Syncthing (+ cloud copy, optional) | Nothing | Today |
| **No Tailscale** (`nat` on) | Extension + Syncthing (its own discovery and relays: Syncthing Foundation's public servers) + public STUN or the hub's | <ul><li>Phone pages and the Record page's mic from phones, plus the listening page (no HTTPS)</li><li>Invitations over the link (the plain join code and Let them in still work)</li><li>Video calls off the LAN until pages get the hub's TURN</li><li>`tailscale_only` studios can't use it</li><li>Pairs behind two strict NATs need the hub's port forward</li><li>Set-up of a link waits a Syncthing hop when no other link is up</li></ul> | Built (stages 1-3), not run in REAPER |
| **No cloud** | Standard without a cloud folder | <ul><li>The post box when the others are off: Syncthing moves files only while two computers are on</li><li>The cloud catch-up</li><li>The hub's stand-in</li></ul> | Today (the laptop runs this way) |
| **No Syncthing** | Extension + direct link (Tailscale or NAT) + hub + cloud copy as the record and post box | <ul><li>Syncthing's patient lossless transfer of everything (replaced by the link's streams plus the cloud)</li><li>Its conflict handling (StudioSync's files are mostly one-writer, so few apply)</li><li>Joining becomes token-only</li><li>A computer coming back after weeks with nobody on catches up from the cloud only</li></ul> | Needs signed writes, inbox promotion, `_band` over the link and cloud, a missing-files exchange, secret sealing |
| **Minimal** | Extension only: peers via NAT and the hub's relay, the hub holds the record | <ul><li>Everything No Syncthing loses, plus the post box: work reaches others only while the hub or they are on</li><li>The hub must be reachable from the internet (router port forward, no CGNAT) for first contact and relaying</li><li>Without that, only pairs that are on together and punch through meet</li><li>No phone pages, no video off the LAN</li><li>Public STUN unless the hub's (configurable)</li></ul> | No Syncthing's work, plus the hub as an always-on store |

Every mode still has two outside services, which a studio can swap or turn off:

- Public STUN (Cloudflare or Google). The studio's `nat_stun` setting, or the hub's STUN, replaces it.
- ntfy.sh for phone alerts, opt-in (`lib/alerts.lua`; `alerts_server` swaps it).

Updates come from GitHub/ReaPack, or the studio folder signed by the owner.

## 4. Staged plan

Effort is in agent sessions, one session being about one of the rt-* stages. Each stage ships behind a studio setting and falls back.

| Stage | What | Effort | James's part |
|---|---|---|---|
| **A. No Tailscale, finish** | Run rt-nat stages 1-3's REAPER checks. Fix what they find. Then three small pieces: invitations whose ask goes over a NAT link to the hub; the hub's TURN handed to video-call pages; Health saying plainly which Tailscale-only features are off. Phone pages without Tailscale (LAN listener, no mic) only if wanted. | 1-2 sessions, plus 2-3 hours testing | Firewall rule (UAC), router forward for the relay (optional) |
| **B. Signed writes, beside Syncthing** | Wire the spike in. Each computer gets a device key (`~/.studiosync/device-key`). Writers sign: `removal.publish`, groups save (band.json, roles.json), removals, closed.json, given claims, session.json, hub.json. trust.lua takes a valid signature first and Syncthing's `modifiedBy` second, comparing ids in full. Pins carry key ids next to Syncthing ids. Sequence marks go in ExtState. The inviter's welcome hands over the newest sequence numbers (this closes first-use rollback). | 2 sessions | Nothing new. It also closes the "forged Syncthing client" shortcut in Standard. |
| **C. Key-made ids** | `services.my_device_id()` falls back to the key id with no Syncthing; NAT and direct peers by it. | 1 session (wide: 17 files call it) | None |
| **D. No Syncthing, with a cloud** | <ul><li>The link's inbox becomes the record when Syncthing is off</li><li>`_band` and song files over the link, signed</li><li>The cloud copy carries `_band` (signed, with band.json's secret sealed)</li><li>A missing-files exchange per writer (or hub snapshots) instead of `/rest/db/need`</li><li>Signed tombstones</li><li>The studio secret sealed in the join welcome and re-sealed to each device after a removal</li><li>NAT first contact via the hub's address or the cloud folder</li></ul> | 8-10 sessions | Long tests: offline catch-up, a removal, a rejoin |
| **E. Minimal** | D without a cloud: the hub keeps everything it receives (it already gets every event as a peer) and serves catch-up. A reachability check for the hub (CGNAT). | 2-3 sessions after D | An always-on computer with a port forward |
| **Retire SonoBus, NINJAM, ReaImGui, SWS/JS** | Each at its own gate, independent of the above | — | James's call |

## 5. The spike: signed writes

**Files:** `lib/signedwrites.lua` (new, unused by the shipped flow) and `tests/test_0_60_rt_lite.lua`.

**API (pure, with verify and sign passed in):**

| Function | What it does |
|---|---|
| `sw.device_id(pub)` / `sw.key_of(id)` | Key to Syncthing-shaped id, and back (nil for a real Syncthing id) |
| `sw.message(...)`, `sw.next_seq(prev, now)`, `sw.make(sign, pub, studio, rel, seq, bytes, deleted)` | Build and sign a sidecar |
| `sw.signer(verify, studio, rel, bytes, side)` | The signer's id, seq, sig and deleted flag; `nil` + why (not yet); or `false` + why (malformed) |
| `sw.fresh(state, rel, seq, sig, now)` | The rollback and equivocation mark |
| `sw.from_manager(pins, id, mine)` | trust.from_manager with whole ids |
| `sw.manager_ok(...)`, `sw.device_file_ok(...)` | The whole check for a manager's file and for a devices file |

**What the test checks:** Ed25519 is tools/sign_release.py's, which tests/sign_cross.py checks against the extension's.

- Ids from keys:
  - Syncthing-shaped.
  - The key comes back out of the id.
  - A real Syncthing id carries no key.
- Devices files:
  - Taken when signed by their own computer.
  - Refused when a member names the owner's computer.
  - Refused when filed under another person's name.
- band.json:
  - The owner's taken on a third computer, then an admin's later one.
  - A member's (making themselves owner) refused, and it doesn't move the mark.
  - A computer's own write counts only on that computer.
- Rollback and numbers: the owner's older band.json put back is refused, as is a different file under a number already taken, or a number
  three days ahead.
- Not yet (`nil`):
  - The file moved to roles.json or another studio.
  - One changed byte.
  - A sidecar ahead of its file.
  - An unsigned file.
- Refused outright:
  - A sidecar claiming another computer's id over its own key.
  - An oversized sidecar, before it's parsed.
  - Paths with `..`.
- Tombstones: a member's tombstone for their own removal mark is refused; the owner's is taken; the old mark put back after it is refused.
- Prefixes: the 7-character lookalike passes `trust.from_manager` and fails `sw.from_manager`.

**Results:** `python tests/run.py --no-luals` gives fails 0. The `files_check` NOTE is the usual one: the list is made at release.

**Not done or not tested:**

- Nothing is wired in: no writer signs and trust.lua doesn't read sidecars.
- Not run with the native `StudioSync_Sign`/`Verify` inside REAPER. They take C strings, so a file with a NUL byte can't be signed this way.
  `_band` files are JSON, so that's fine.
- Cost on big files: one Ed25519 verify per check, to be cached by content as trust.lua caches verdicts.

## Review later (security; James deferred reviews until every feature is in)

- **First use.** A computer that has never seen a file takes the first validly signed copy, however old (marked `shortcut:` in the module).
  Stage B's welcome would hand over the newest sequence numbers.
- **A stolen device key** signs as that computer until it's taken out. Removal already drops the devices file and pins. Signed writes add
  nothing new here, but nothing less either.
- **Clocks.** A manager whose clock runs up to a day ahead pushes sequence numbers ahead. The others still go after it (`next_seq` is
  previous + 1), but a day's cap is a judgement call.
- **Signing isn't hiding.** Before the cloud carries `_band`, the secret in band.json (`sonobus`) has to be sealed to members' keys. Today
  it's plaintext in the Syncthing folder, which only members' computers hold.
- **Two ids per computer.** A computer with both a Syncthing id and a key id is two names for one machine in pins. Stage B pins both under
  the person, and stage C has to pick one per studio.
- **Key-made ids and Syncthing.** Syncthing never sees key-made ids. Their check characters almost never pass Syncthing's own Luhn check, and the "SSK" tag inside sets them apart.
