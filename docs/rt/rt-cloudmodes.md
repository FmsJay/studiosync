# Cloud storage modes (rt-cloudmodes, 2026-11-20)

James: "Storage modes/limits for cloud and others. Different options for what's stored in cloud to keep it smaller if needed, just the bare
essentials to get a full project back without any restore or anything would be the lowest option I think."

Offline tests only. Not run in REAPER yet.

## What it does

The studio's owner or an admin picks what the cloud copy keeps. Every computer follows that choice. It is stored in band.json
`cloud_storage = { mode, days, limit_mb }`, a trusted setting read through `groups.trusted`, so it only counts when the owner's or an admin's
computer wrote it.

| Mode | The cloud copy keeps |
|---|---|
| **Essentials** | The project as it stands now: each object's newest change, plus what a pending merge is rebuilt from (`trim.plan` with no saved versions). The recordings those changes play, **on lanes that play only**. Plug-in chains (`fx/`), MIDI, tombstones (`deleted/`) and trim lists. It keeps no older changes, saved versions, takes, trash or end-of-session projects, and it writes no new end-of-session projects. |
| **Standard** (default 14 days, 1-90) | Essentials, plus the last N days: the changes from those days, the saved versions from those days and the changes they restore to (`trim.plan` with those versions), the recordings any of these play (including lanes that don't play), takes from those days, and end-of-session projects from those days with the recordings they use. |
| **Everything** | Today's behaviour, and the default. A studio that never picks a mode has no setting, so `cm.filter` returns nil and `drive.mirror` runs exactly as before. |

**Size limit** (None, 1, 2, 5 ... 200 GB) works with any mode. When the cloud copy is over the limit, the oldest non-essential files go first:
non-essential files dated on or before a cut-off date go, and files with the same date go together. Essentials never go. When the essentials
alone are over the limit, Health shows a yellow row saying so.

How it works:
- **Nothing on any computer is removed.** The mode only affects what `drive.mirror` uploads (`cm.filter`) and what each sweep removes from the
  cloud copy.
- **Removals go to the cloud service's own trash.** The sweep calls `os.remove` on the synced folder, and Google Drive, Dropbox, OneDrive, Box
  and iCloud then keep the file in their trash for about 30 days. This is the same way `sessionfile.prune` already removes old session projects.
- **Switching to a smaller mode asks first.** A confirmation dialog lists what goes, by kind, with counts and sizes taken from the last sweep.
- **Each computer removes only its own files.** This follows `drive.mine`'s one-writer rule. A recording belongs to whoever made the first
  change that played it, in any room. If Google Drive removes someone else's file, it only unlinks it and doesn't free that person's quota.
- **The owner's computer also removes anyone's file** once that file has been unwanted for an hour (`cm.OTHERS_WAIT`, kept in memory), which
  covers a member who has left.
- **A file is judged from the cloud copy's own changes.** `cm.judge` uses the cloud's events, so a newer change that exists only on this
  computer can't make the cloud's older version look unneeded before the newer one has been uploaded. Recordings are judged from every change
  on either side, because keeping more is always safe.
- **A room is left alone** while its cloud events folder is empty and this computer has events for it (the copy is still arriving or not listed
  yet).

### The sweep and the readout
- Live sync's cloud pass calls `cloudmodes.tick` with a 0.1 s budget: one room or a song's session projects at a time. A full sweep of the
  studio's cloud copy, covering every song in the cloud or here and every room on either side, starts at most every 10 minutes.
- File sizes come from the studio folder's copy where there is one, otherwise from `JS_File_Stat`, otherwise by opening the file.
- The result goes to ExtState `cloud storage` and contains:
  - what the cloud copy holds (files and bytes, by kind);
  - what each mode would store, judged from both sides;
  - what switching to Essentials or Standard would remove;
  - what the last sweep removed;
  - the size limit's cut-off date and whether the essentials alone are over the limit.
- **Health:** a row under the cloud copy row, for example "Google Drive copy holds 3.2 GB (4,120 files), Standard (14 days). Each mode would
  store: Essentials 1.1 GB, Standard 2.0 GB, Everything 3.2 GB." It turns yellow when the essentials alone are over the limit.
- **Settings > Options > Cloud copy:** a new "Cloud storage" section with the mode, a days slider for Standard and the size limit. The owner and
  admins can change them; everyone else sees what's set. It shows the same readout and the confirmation dialog.

## Files
- `lib/cloudmodes.lua` (new): settings, `judge` (pure), `limit_cut` (pure), `filter` (for drive.mirror), `tick` (the sweep and removals),
  `health_row`, `drop_words`, `studio_ui`.
- `lib/drive.lua`: drive.mirror asks `cloudmodes.filter`. Uploads of files the mode leaves out are skipped, and so is take placement on the
  cloud side. Downloads are unchanged. 5 lines.
- `lib/groups.lua`: `cloud_storage` added to the trusted SETTINGS. 1 line.
- `lib/sessionfile.lua`: no end-of-session project is written in Essentials. 2 lines.
- Shared files, small additive edits only:
  - `StudioSync - Live sync.lua`: one `band.try` after `drive.tools_pass`.
  - `lib/page_health.lua`: the storage row after the cloud copy row.
  - `StudioSync - Panel.lua`: the Cloud storage section at the end of `section_drive`.
- `tests/test_0_60_rt_cloudmodes.lua`: two studio folders, an empty third computer and a cloud copy, all in memory, never a real cloud account.
  - Pure functions: settings clean-up, lanes that play, limit order, stamps.
  - A generated project with 40 days of history in two rooms: fixed lanes, a deleted item, a side room playing an old recording, saved
    versions, takes, trash and session projects. Two computers publish it in Everything.
  - Essentials: the cloud copy's changes are exactly each object's newest, plus the recordings that play. The rest goes, including Bo's files
    removed by Bo's own computer. Nothing local is touched.
  - A pass uploads nothing the mode leaves out. A change replaced before a pass never goes up.
  - Restore onto an empty computer belonging to the same person: each object comes back at its newest change with identical state, the
    recordings that play arrive whole, plug-in chains and MIDI arrive, and that computer removes nothing from the cloud copy.
  - Everything again: the cloud fills back up from the computers.
  - Standard: the 14-day window, and the saved version from 10 days ago still restores.
  - Size limit: the oldest non-essential files go first, and when the limit is below the essentials it says so and keeps them.
  - The owner's computer removes an unowned file only after the wait.

## Not done, and why
- **"The last mixes" in Standard:** the cloud copy doesn't carry mixes or stems today. The song-level `mixes/` and `stems/` folders only
  travel by Syncthing, so no mode has any mixes to keep. Standard would need the cloud copy to carry `mixes/` first, which needs a rule for who
  uploads them, since they aren't named after anyone.
- **Takes inside one item:** Essentials filters lanes, not the inactive takes of a multi-take item. Which take plays can be a print on one
  computer and the dry take on another (`mirror.picked_take`), so all of an item's takes are kept.
  `shortcut: an item's every take's file is kept; filter by BANDTAKE once prints' per-computer choice is settled.`
- **Song settings in the cloud:** session.json, room.json and band.json still aren't in the cloud copy; Syncthing carries them, as before.
  So a restore onto an empty computer still needs the song's listing to have arrived. The roadmap's "the hub's stand-in" covers this.
- **Local stores** (each computer's history, received files) aren't changed. Local history is already trimmed by `lib/trim.lua` (60 days);
  received files weren't looked at.
- **Free up space:** in Essentials or Standard, `lib/localcopy.lua` no longer counts the cloud copy as holding a song, because it doesn't hold
  every file. That is correct and safe: a local copy is only deleted when the song is complete somewhere else.
- **Members without a cloud folder:** as today, their changes reach the cloud copy only from their own computer. In Essentials, an older
  change of yours that their newer one replaced isn't uploaded either, so the cloud's version of that object can be older until they have a
  cloud folder.
- **Lowering the size limit** has no confirmation dialog. Its removals still go to the service's trash. Only a switch to a smaller mode asks.

## Untested (needs REAPER and real cloud services)
- The Panel section has never been drawn. It uses ReaImGui combos, a slider and a modal popup, written like `liveaudio.studio_ui`.
- Real trash behaviour on each service, and Google Drive's rate limits when a sweep removes thousands of files. The first switch on a big
  studio removes a lot in one sweep.
- How long a sweep takes on a big studio: the first sweep reads every event file on both sides once (the cache is per path).
- `JS_File_Stat` sizes on online-only files. Without js_ReaScriptAPI, a cloud-only file is opened to get its size, which may download it.

## For the security review (later)
- **The cloud copy's events aren't signed.** Anyone with write access to the cloud folder could plant a newer-looking change for an object
  and make the real newest look old, so the sweep would remove it from the cloud copy. The removal goes to trash and never touches a computer,
  but the cloud copy's content is trusted as `drive.mirror` already trusts it.
- **A manager's choice of Essentials removes data from the cloud copy for everyone.** It still goes only to the service's trash, and the
  setting is only taken from trusted band.json.
- **The owner's computer removes other members' unwanted files after an hour.** That hour is in-memory only, so it resets with REAPER.
- **Size readout without js_ReaScriptAPI** opens cloud-only files, which can download them.

## REAPER checks for James
Use a test studio, not Chilio's.
1. **Desktop (owner):** Settings > Options > Cloud copy shows "Cloud storage: Keeps Everything". Leave Live sync running with the transport
   stopped for about 10 minutes. Health should then show the storage row with what each mode would store.
2. **Switch to Essentials:** pick Essentials. The dialog should list files and sizes by kind (changes, saved versions, recordings, takes,
   trash, end-of-session projects). Confirm.
3. **After the next sweep (about 10 minutes):**
   - The Drive folder's `<song>/rooms/<room>/recall`, `takes` and `_trash` are empty, `events` holds fewer files, and `<song>/sessions` is
     empty.
   - drive.google.com Trash holds the removed files.
   - The studio folder's file counts are unchanged.
   - The log line "cloud storage (essentials): N files ... removed ... nothing on any computer was touched" appears.
4. **Keep working:** edit an item a few times and wait for a pass. Only the newest version's event and recording appear in Drive.
5. **Switch back to Everything:** Drive fills back up from each computer over the next passes. Then try Standard with 7 days, and a size limit
   below the current size: the oldest non-essential files go and essentials stay.
6. **Laptop (member):** its Settings shows the mode greyed out with "The owner or an admin picks". Its sweep removes only its own files.
