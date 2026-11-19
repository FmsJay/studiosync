# StudioSync full review, 2026-11-18 (0.59.42-0.59.43)

Nine read-only reviews, each on Fable 5.2 at high effort, asked for by James. Seven covered the usual areas: sync engine, security and
privacy, UX and wording, performance, cross-platform, and code health with tests. Two were new: data safety and recovery, and install,
update and version mixing. One more reviewed the whole project. None of them edited files or ran anything in REAPER. Two findings were
reproduced offline by a reviewer (sync 3 and 4). I checked the main claims against the code at 0.59.43 (marked "checked" below).
Everything else was read from code and has not been run.

Offline tests pass: 82 files, 0 failures. The lints pass.

## Verdict in one paragraph

The core design holds up: write-once event files per object, revisions, a hybrid clock, and one ordering rule
(`mirror.newer`). The reviewers found no injection holes and no unsafe loading of shared data. Refusals always say what to do, and most
destructive actions confirm first. The serious problems are in three places. **Trust:** a guest can put code where every computer runs it,
and several trust checks rest on what another computer writes about itself. **Data safety at the edges:** Delete my copy, kept copies of
refused edits, and Sync and exit saying "safe" too early. **Updates:** a half-delivered version can load and is never corrected, and one
bad version stops every computer. The full review's main point: before other bands use it, freeze features, release through a stable
channel, and build a soak test where three REAPERs edit the same song with a stand-in for Syncthing that delivers files late and out of
order.

## Fix first (ranked)

| # | What | Where | Area |
|---|---|---|---|
| 1 | **A guest (or any member) can put code where every computer runs it.** Guests sync the band-wide `/_*` folders, which includes `_tools`. A studio that updates through its folder runs whatever is there without asking, on every computer, for every studio it's in, and also copies the native extension. The panel and fromfolder.lua still say the code guard asks. (checked) | `lib/songsync.lua:16,51`; `lib/band.lua:789-792`; `lib/fromfolder.lua:30-33` | security, install |
| 2 | **Delete my copy can bin the last full copy.** "Confirmed on Bob" trusts a holds file that is never re-stamped or removed, so a wiped laptop or a removed member still counts. On Windows, "too big for the Recycle Bin" can be answered yes silently, so the files are deleted permanently. | `lib/localcopy.lua:64-81,219-221,252-312` | data safety |
| 3 | **A half-arrived update loads and is never corrected.** files.txt's version is only a cache key and only lengths are compared, so a new band.lua next to old modules passes. Once band.VERSION reads new, nothing reloads. Separately, a version that errors while loading kills Autostart, Live sync and the panel on every computer, and nothing falls back. (checked) | `lib/band.lua:716-729`; reload paths in Autostart, Live sync, Panel | install |
| 4 | **A refused edit's kept copy is made only once per object per band event**, so a second refused edit in the same session is lost with no copy and no message. (checked) | `lib/mirror.lua:2788` (copy_key without the state hash) | data safety |
| 5 | **Declined, withdrawn or stale suggestions delete the only copy** of an edit to an existing item or automation. | `lib/suggest.lua:153-257`; `lib/mirror.lua:2789,2822` | data safety |
| 6 | **Sync and exit says "safe to close up" too early.** It's said while a big take is still copying into the shared folder, while edits are unsent or unsettled, and after "Stop waiting". It also sends held changes before you've answered. | `lib/leave.lua:52-93,159-165` | data safety, UX |
| 7 | **Who's here ignores clock differences in the rule that decides "alone"**, so a bandmate whose clock runs 90 s behind reads as absent. You then get full control over their claims. Five copies of the rule exist. (checked) | `lib/sync.lua:1519-1527`; `Live sync.lua:292,297`; others | code health, sync |
| 8 | **A track deleted by hand and brought back** (Restore, Undo, or Ctrl+Z) comes back bare, and then an empty chain, automation and sends go out to everyone. | `lib/mirror.lua:3387-3388,3201-3204,3667` | sync |
| 9 | **Permission checks use a track's old name after a rename.** On a claimed track renamed Keys→Piano, anyone can delete older items, while the claimant is refused on others. (checked) | `lib/mirror.lua:3259,3383,3395` | sync |
| 10 | **Auto-admit and removal trust what each computer writes about itself.** A member or guest can let a second computer in. A member can point Remove at a decoy device. Owner-only actions are accepted from any admin's computer. Trusted settings (including `updates`) rest on Syncthing's `modifiedBy`, compared on 7 characters. | `lib/removal.lua:74-79,211-279`; `lib/trust.lua:32-40`; `lib/groups.lua:286` | security |
| 11 | **Debug data:** "owner and admins only" is each member's own .stignore, so it's hidden but not locked. The bundle carries the whole computer's log, so data from other studios too. The project copy includes local and held work. Crash reports pick the wrong eight on Windows. Members aren't told when it's on. (crash report order checked: 57 reports here, kept by folder name) | `lib/debugmode.lua`; `lib/songsync.lua:66-69` | security, cross-platform, UX |
| 12 | **Items that point at a local file get sent** when the source isn't reachable: a moved studio folder or a changed drive letter, or a take on an unplugged drive. In the worst case "Make this my project" sends every audio item with dead paths. | `lib/mirror.lua:1629-1640`; `lib/band.lua:918-921` | data safety |

## By area

### Sync engine (the other 9 findings)
- **Two people are enough for an item to merge differently on different computers** (reproduced offline): `mirror.lua:2181-2185`. Fix: rebuild from the leaves through `merge_order`.
- **Heal undoes 0.59.37's three-way merge** (reproduced offline): `mirror.settled` merges only two versions, `mirror.lua:3913-3925`.
- **StudioSync's Undo can't undo deleting a track that had items**: it says "couldn't change here yet" on every press. `mirror.lua:3360-3364,965-978`.
- **Hold my changes doesn't hold the tempo map or markers**: an incoming timeline replaces yours. `Live sync.lua:353-355`; `sync.lua:1039-1047`.
- **A print refresh can carry a refused MIDI edit past a claim**, when the item is still open in the MIDI editor. `mirror.lua:3257-3260,3323`.
- **A backlog drains about 8x slower**: receive's own changes count as you editing. `Live sync.lua:242-249`.
- **A restored chain can go out twice** (the panel's read-back memory isn't shared with Live sync). **A failed media copy isn't marked unsent.** **Restores skip `hlc_seen`.**
- Checked sound: the 0.59.40 split of watch and poll (diffed against 0.59.39), receive's guards, merge rules, ordering.

### Security and privacy (beyond fix-first 1, 10, 11)
- Permission checks on received events trust the name written inside the event file (`sync.lua:1007,1213,1255`): in admins or driver mode a guest can write events as the owner.
- A long guest (2 weeks or a month) can be auto-admitted as a full member from day 8 (`removal.lua:184-197`). Any 100.64/10 address counts as the tailnet.
- Before a new computer has pins, trusted settings come from band.json as anyone wrote it (`groups.lua:31-38`).
- `pin_tailnet` takes Tailscale names from devices files without `device_ok` (`services.lua:1181`).
- The ntfy channel can reach a public GitHub issue through the activity list (`band.lua:966`).
- A bandmate's event can create dotfiles at absolute paths (`fxfiles.lua:71-76`).
- The Tailscale token is in plain text on Linux, and in a temp sweep config left behind after a crash.
- The listening page shows guests every project's mixes.
- Checked sound: shell construction (no injection through names), no `load`/`dofile` on shared data, token handling otherwise, listening server loopback, chat links.

### Data safety (beyond fix-first 2, 4, 5, 6, 12)
- A saved version is only a timestamp, so "yours before X's work done alone" can't restore your side (`page_restore.lua:254`; `mirror.lua:830-848`). Store the oid→event map in the point.
- Delete my copy also bins the local project folder with unsent work in it (`localcopy.lua:118-122,288-304`).
- The auto-save after 100 received changes counts across the whole session, and saves your unsaved experiments (`Live sync.lua:438,520-530`).
- Prepare calls `PCM_Source_Destroy` twice on every converted take, which can crash or leave it half converted (`prep.lua:333-334`).
- Restore, Undo this change and Use mine apply over unsent local edits with no copy (`mirror.lua:3673-3698`).
- An orphaned original isn't re-shared if the shared copy is later deleted (`mirror.lua:2922-2931`).
- Local projects and unsent takes live under REAPER's resource folder, so resetting it loses them.
- Producer cues can stop another tab's recording. End-of-session exports copy every media file to Drive, per member, and never remove them. Trimmed history is kept on one disk only. A leftover `.syncthing.*.tmp` can bring a deleted file back. Close this project closes the tab in front.
- To verify: that `Main_SaveProjectEx(…, 0)` leaves the modified flag alone. Nothing asserts it, and prints and debug mode rely on it.

### Install, update, versions (beyond fix-first 1, 3)
- On Windows the panel rewrites the startup block without its fallback: the path comparison is case- and slash-sensitive. A missing studio folder then means a script error at every start and no projects opened. The laptop's `__startup.lua` already has the bare form. (`Panel.lua:584-587`; `tools.lua:49-70`)
- Moving to the folder copy is one-way: it's never moved back when updates are turned off or you leave (`fromfolder.lua:53-65`).
- Changes an older version couldn't read stay marked applied after it updates (skips capped at 50, unknown types silent) (`sync.lua:903-908,1294-1335`).
- Mixed versions are labelled, never gated. FORMAT is written but never read (`band.lua:4`). Add a trusted `min_version` and a format floor on events.
- The folder move reruns every 60 s, and is half applied until restart. Nothing publishes StudioSync into `_tools`, so a hand copy without files.txt counts as complete.
- No uninstall. It leaves behind a startup block that errors, `loadlastproj` changed, 17 Ctrl+Z override lines, and old extension files.
- Installer gaps: Windows downloads can die with REAPER closed. ReaImGui's version isn't checked. A re-run starts a second helper. A moved studio folder loses its pins. The extension updater can install the old build.

### Cross-platform
- Debug crash reports on Windows: sorted by hash, not date (fix-first 11). `AppHang` reports are ignored, and `C:/ProgramData` is hard-coded.
- **Windows drive letters D: to Z: are listed every 300 s on the UI thread** (`drive.lua:86-91`). A mapped drive that can't be reached freezes REAPER.
- Putting a plug-in's sample back at its original path never works on Windows (backslashes into `copy_atomic`) (`fxfiles.lua:140`).
- Windows reserved names (Aux, Con…) are checked for rooms only, not songs, users or studios.
- macOS: `hand_over` hard-codes `REAPER.app`. Linux aarch64 gets the x86_64 extension, because GetOS says "Other". Linux call apps aren't detected. Non-Latin names clean to "" with no message. `%w` depends on the locale in some cleaners. The Linux terminal fallback can't fail. Linux sample paths miss `/run/media`. Program Files paths are hard-coded. Some tool paths are absolute.
- Seen on the way: a renamed member with a space in their name stays listed twice (`plugins.lua:46` vs `band.lua:466`).

### Performance (estimates, not measured)
- **Every look re-serialises every item** even when its track's chunk is unchanged. Reusing them could save 60-80% of a look (`mirror.lua:1537,1571-1585`).
- **The track-parts memo is keyed on the whole track chunk, items included.** Every item edit misses it, and about 100 edits fill the 128 MB cap and wipe it all, which means a cold look of 2-3 s (`mirror.lua:1539-1545`). Fix: key on the chunk up to the first `<ITEM`.
- **The events folder is listed 4 times a second** while a bandmate is present, which grows with history (`Live sync.lua:706-720`).
- Print checks walk every item on every look. `mirror.root` is built twice per poll. Sorted listings run where they aren't needed. The live MIDI tidy runs even when the feature is unused. A full redraw on every poll of every tab. Per-object ProjExtState lookups. Byte-by-byte Lua hashing of MB chains. `restless_sig` rebuilt per object. Memory per tab. `band.info` uncached. band.lua (81 KB) read whole to find VERSION every 2-5 s.
- Debug mode's 5-minute project copy was the worst new cost. **Fixed in 0.59.43**: it now collects only at session end, with bug reports, and after a crash.

### UX and wording
- **A new member's dead end:** with no project open there's no Health tab and nothing starts Syncthing, yet the messages send them to Settings > Health.
- Sync and exit acts before asking (fix-first 6).
- Messages point at buttons that no longer exist: "press Start", "Configure SonoBus", "Update below", "Leave". Settings directions are out of date: "Settings > Advanced", "Cloud copy", "Call".
- The toast covers the page tabs in the compact layout. Keyboard navigation can't reach the switches, crumbs or claim chips (`InvisibleButton` with no EnableNav), so "a claim released from the keyboard" doesn't hold.
- Handing over driving is hidden in a right-click menu. "Driving" is explained three ways, and the Take control text is wrong for the default mode. "Who can edit" has five names. Time-sync and Play along are the same thing under two names. Opening a project needs a double-click nobody is told about.
- Text size isn't carried through: the Sync and exit box, room squares, Feedback's row, and the other windows (chooser, Prepare, radial, Draw).
- Debug mode is silent to members. Let in has no confirm. "Google Drive" is hard-coded although the cloud copy can be another service. Saved versions use several names, and so do song/project. Internal names show up in messages, and "BandSync" still shows on fresh installs. The README is behind the panel. Small wording fixes.
- Works well: refusals say what to do, destructive actions confirm in plain words, tooltips are thorough, getting-started and waiting cards, narrow layouts.

### Code health and tests
- **The old take-based sync's send half is still wired in**: `mark_baseline` at every start, `holdings` always `{}` but encoded every poll, and the Status window reads "0/0 takes".
- Module-level fields act as hidden parameters between scripts. `sync.is_claimed`/`owner_of` judge by the last room asked about, and `free_names` can't see that.
- The status fingerprint misses `mix`, `produce_via` and `stamping`, so followers get a fader move only at the 15 s heartbeat.
- About 190 bare `pcall`s. `end_of_session` marks itself done before saving, so a failed save is never retried and on two paths never logged.
- Lints: `free_names` whitelists 15 table keys as globals. Nothing checks calls to missing module functions, arity, shadowing or unused locals. The offline runner lives in %TEMP%, not the repo, and only an exception counts as a fail. CI builds only the extension.
- The docked-bar rule is written twice with inline pixel numbers and has no test (changed 3 times today).
- `last_track` is still a ProjExtState write, the sibling of 0.59.37's `last_at` fix.
- Next biggest functions: Draw's loop (301 lines), `tick_body` (265), `chooser.open` (263, nesting 10), `F.top_bar` (237), `maint_rows`, `sync.receive` (its classify step has duplicate branches).
- Two hand-rolled ISO parsers without `isdst = false`. `hear.mix` keeps `carried` at module level. A hand-kept list of 38 per-tab keys to clear. 27 mutually dependent module pairs, and the engine calls a UI page. Dead code: `prep.lua:379-405`, `producer.LET`, `hear.listeners_here`, `drummap.translate`.
- **The 10 most valuable tests to add:**
  1. Who's here under clock skew. This fails today.
  2. Every status field triggers a write.
  3. `sync.receive` classification, via an extracted `sync.triage`.
  4. The top-bar plan.
  5. The song lock lifecycle.
  6. The `hear.mix` upgrade.
  7. Try again across scripts.
  8. The trusted-settings list.
  9. A look leaves the change count alone.
  10. `band.try` and the end-of-session retry.

  Tests that can't fail: `follow_mix.lua:42` is `check(true)`. `page_modules` passes hidden parts and draws only 4 pages. `test_drummap` covers dead code.

## The whole project (full review)

**Architecture.** The core design is sound. Four structural weak points will keep producing bugs however many are fixed:
1. Change detection by diffing serialised REAPER text with a denylist of local lines. Every new plug-in, REAPER line or OS quirk becomes a false edit. An allowlist schema of named fields that travel would remove the class.
2. Convergence is checked on bookkeeping (event ids), not content, so two computers that applied the same event differently agree and nothing repairs it.
3. Authority (driver, mode, claims) sits in shared multi-writer files outside the event log, which is why enforcement is "undo after the fact" with timers.
4. Several Lua states (panel, one Live sync per tab, Autostart) share about 160 ExtState keys.

**Scope.** 32.5k lines in about 3 weeks. Carrying cost out of proportion for a small band:
- two live-audio stacks (SonoBus with a reverse-engineered state writer plus a position modem, and NINJAM with binaries for 4 targets);
- the three-way merge;
- 5 edit modes × 3 claim kinds × 4 roles;
- guests with expiry and Tailscale policy rewriting;
- eight places an unsent change can live, six ways back, four update paths;
- the half-removed take sync.

Candidates to freeze: the listening page, phone alerts, credits, stages, A/B, colour schemes, drawing, the plug-in pack installer, FX finder and drum maps.

**Reliability.** Recurring failure kinds: false edits, clocks and ordering, stuck-forever states ("for good" appears 63 times), cross-script stale state, one bad input stopping everything, destructive automation, fixes that break things. The tests are pins written after each review. The REAPER suites model two computers as two tabs in one process on one folder, so delay, reordering, partial files and second platforms are untested. Every commit to main is a release (48 today), hot-swapped into running sessions: the band is the test rig. **The one investment:** a convergence soak with three REAPER instances, each with its own folder, a shim that delivers files late, out of order, half-written and duplicated, random edits, and an oracle that compares content per object. Run it nightly on the Linux VM and before any release.

**Docs vs reality.** About fifteen places where README and docs/mirror-design.md describe old behaviour:
- the root hash "repairs" content;
- ties settled by time then user;
- envelopes "later";
- "events never pruned";
- Their time "set by hand";
- Through my plug-ins / As printed;
- the mode names;
- Full screen and Window;
- "up to 7" pairs;
- who can Remove;
- the Settings tabs list;
- "code guard still asks".

docs/TEST-PLAN.md is a changelog.

**Readiness before other bands, in order:**
1. Code and authority trust: checksummed releases, and guests unable to deliver code.
2. A stable channel and a wire-version gate.
3. Content-level divergence detection with self-service repair.
4. The open crashes resolved or bounded, and the soak passing for days.
5. Supportable install and docs: a short getting-started guide, and diagnostics that reach whoever supports StudioSync.

**Highest-leverage next steps:**
1. A feature freeze for the testing phase, and one release a day through a beta channel.
2. The convergence soak, with offline tests and lints in CI and the runners in the repo.
3. A per-object content hash in the status file, plus a repair action.
4. A wire-format version in events, and holding sync with an incompatible peer.
5. Release checksum verification before adding testers, brought forward from "after testing".
6. Driver, mode and claims moved into the event log.
7. An allowlist schema, starting with items and tracks.
8. Live audio split into its own package, with one stack chosen.
9. Drop the three-way merge and the take-sync remnants, and collapse the "mine, not sent" mechanisms into one.
10. A short guide plus a reference to replace the README, and mirror-design.md rewritten from the code.

## Already changed since the reviews started
- 0.59.43: debug mode collects at each session's end, with each bug report, and at the start after a crash, instead of every 5 minutes. This removes the performance review's debug item and the 5-minute part of the UX one. The crash-report order, members not being told, and the cross-studio log contents are still open.

## 0.59.44: the fix-first list (James: "without affecting the ease of use and setup... performance, speed, network strain")

Done:
1. Guests with a project list no longer sync `_tools` (their ignore file leaves it out, before the band-wide line), and a guest's computer
   never moves to the studio's copy. The texts that said the code guard still asks now say what happens.
2. Delete my copy: a holder counts only if its list was said again in the last 3 days (each computer re-says it daily, one small file)
   and it hasn't been taken out. On Windows, a folder bigger than that drive's Recycle Bin, or a bin set to delete at once, is left and
   said, as a drive with no bin is (checked in the background helper; this desktop's J: bin is 188 GB).
3. Updates: files.txt now carries each file's hash, its version must be band.lua's own, and a script started on a part-arrived copy
   reloads once it's whole. Reloads compile every file first and run under pcall: a version that fails to start leaves the old one running,
   said once. The hashes are worked out once per version and shared between REAPER's scripts.
4. A refused edit's kept copy is per refused version (the band's event id plus the refused state's hash).
5. Declined or withdrawn suggestions keep what you did: items on "(yours, not sent)" tracks, automation in Kept automation.
6. Sync and exit: asks first when Hold my changes is on (send it, or keep holding); counts unsent and settling changes (a big take still
   copying) as not out; says "safe" only when it is; closes the tab it was for.
7. Who's here: one rule with peers' clock allowance (presence.here), used for "alone" and "the driver is here" (one file read fewer).
8. A part recorded as gone with its track isn't sent as empty when the track comes back bare; Restore re-applies such parts instead of
   taking them as "already that revision"; a refused track deletion brings its parts back with it.
9. Permission checks use an item's or part's track by its current name (W.one, W.gone).
10. Owner-only: a closed.json counts only from the owner, as groups.close already required. No auto-admit while any guest's time is
   still running (they ask in the panel). Tailscale names are taken only from devices files their own computer wrote (asked once per file;
   one not answered yet is taken as before). (James: these two are rare checks, fine to do now.)
11. Debug mode: the newest eight crash reports by EventTime (hangs too), older ones pruned, $ProgramData; the report names the project it's
   for; each computer is told once when debug mode is on; the panel says the folder is hidden from members, not locked.
12. An item whose audio file isn't on this computer is held back with a word, never sent pointing at a path only it had.

Held back, as asked (each would change setup, add calls or traffic, or block the folder updates the studios use):
- Folder code only from a manager's computer (a Syncthing check per changed file: the laptop's own folder copies could be refused).
- A manager-written list of admitted computers for auto-admit and removal; removal by every device a name ever had.
- Moving `updates`/`debug` out of the settings believed on `modifiedBy` alone (a local yes per computer).
- Tailnet `whois` on auto-admit (a Tailscale call per asking computer; the guest-time rule below covers the long-guest case).
- Debug: a manager-only Syncthing folder for `_debug`; log lines tagged by studio.
Not done yet, smaller: the accepted-but-stale part of suggestions; Delete my copy's local project folder check; moved-root path rewrite.

## 0.59.45: review round 1 (nine reviewers on 0.59.44, all NOT SOLID; reports in the session scratchpad round1/*.md)

James's decisions: Hold keeps the band's tempo/markers waiting while yours differ; every saved version stores the exact per-object state;
auto-save after 100 incoming changes only when you had no unsaved changes; renaming onto someone else's claimed name is refused; a
last-good local copy is the safety net (no Syncthing at login); "X is editing" keeps a copy; all guests are kept off the studio's
StudioSync copy (and computers move back off it); a Debug pill in the top bar.

Done (by area):
- Engine: two-person merges and heal agree everywhere (fuzz: 0 differences in 4,000 runs); trim keeps every leaf; duplicate ids prefer the
  recorded item; a re-created track brings its parts; Undo of a track delete with items; prints don't carry refused edits; Hold holds the
  timeline; held-back items counted by Sync and exit (mirror.waiting); stale unsent flags swept; clocks before restores and deletions;
  owner step on owner deletes/restores; multi-object undo; rename onto a claim refused; latency writes only on change.
- Data: kept automation survives Put mine back; revert/heal skip unsent edits and say so; saved versions store the oid->event map;
  Prepare's double source destroy removed; declined suggestions keep failures; refused copies only after success; Sync and exit counts a
  peer only if it holds the song; Delete my copy keeps a project folder with local work; band.save_copy keeps the unsaved mark.
- Security (no setup friction): closed.json only from the owner's computer; marks remembered after deletion; trusted settings fail
  closed once an owner is named; role changes only from the owner's computer; left marks need the user's own device; guests of any kind
  ignore _tools and others' holds/lists/invites/feedback; the band's own file paths are never copied back to the studio; dotfiles and
  REAPER's folder refused for plug-in files; clipboard text not logged; pin_tailnet only for Tailscale-only studios, checked by content.
- Install/update: last-good copy and a startup block that falls back; reloads restore every module and the code searcher, compile only
  what's loaded, never while recording; Autostart keeps its update check after an error; the Windows startup block keeps its fallback;
  the folder move goes back when no studio wants it and doesn't rerun every minute; no files.txt = not whole; files_complete backs off.
- Performance: tabs behind skip passes while any project records; track-parts memo keyed on the track head (whole chunk when frozen),
  two-generation memo; cue watch skips big files and relists only on a folder change; room summary measures only new media; print
  checks cached; backlog drains at full speed; reload compiles less; drive letters not swept every 5 minutes; VERSION read from 512 bytes.
- Cross-platform: case-only renames don't delete; plug-in files put back on Windows; Mac REAPER found under any bundle name; non-Latin
  and reserved names refused with a word; Syncthing GUI 0.0.0.0 handled; Linux call apps, terminals, aarch64.
- UX: Start Syncthing button for a new member with no project; Sync and exit wording, Start sync button, scaled box; driving explained
  per mode; one table of place names; toast below the tabs; Debug pill; double-click hint and Enter to open; keyboard navigation flag;
  tooltips no longer collide; Health doesn't warn about the studio's own folder choice; cloud service named as chosen.
- Code health: take-sync send half gone; authority's claims passed explicitly; status fingerprint covers every field; end_of_session
  retries a failed save; free_names counts only real globals; tests/run.py; tools/luals_check.py (LuaLS); test temp folders cleaned.
Suite regressions found and fixed before release: suggestions (new-item suggest refused), mirror_freeze (frozen chunks), trim_history,
restless_fx (print cache key), take_comps (paths record), groups (band.info cache key, empty modifiedBy for the owner's file).
Mac now runs the full suites too (two Mac-only failures predate this round: routed_print's file name, lock_refuse; for round 2).

## 0.59.46: review round 2 (nine reviewers on 0.59.45, all NOT SOLID with far fewer issues; reports in the session scratchpad round2/*.md)

James's decisions: saved versions keep their per-object map in a sidecar (recall/known/), read only on restore and trim; a version saved
while catching up is marked and restores by time; roles live in _band/roles.json, written only by the owner's computer; incoming file
paths that aren't shared media are dropped on arrival, and keep-local tracks stay out of the end-of-session cloud export; the Recycle
Bin check counts only the job; Autostart starts Syncthing at REAPER start when in a studio; moving back off the folder copy never goes
to an older version; panel errors are logged and the panel recovers (no REAPER error box), and every module is preloaded at start.

Done: Sync and exit counts people in the room and guests correctly, never syncs a backup copy, and Start Syncthing reaches a new
member with no studio; reloads announce only after they worked and wait while anything records; the old-form startup block is upgraded
so the last-good safety net is really installed; last-good saved only when whole and current; trusted settings ask Syncthing only when
band.json changes (1 ask and 1 write in 10 minutes instead of 121); the events listing and the cue watch relist on folder change or
every 2 s (exFAT/FAT); no empty undo points while a change waits; undo of a track deleted across seconds; bare returning tracks bring
their parts every look; deletion-vs-edit races heal; unsent plug-in/automation work protected from Restore and Bring into main; failed
suggestion applies kept; saved-twice copies fixed (band.save_copy); templates opened through the stripper; prints never render a
band-named file; the memo turns over only between looks; heal reads only new history; events of an unknown kind or newer format are left
unapplied and skipped ones retried after an update; Mac-only test bugs fixed (routed_print pattern, lock_refuse run-from). New checks:
tools/files_check.py (files.txt vs code) and LuaLS gating in tests/run.py.

