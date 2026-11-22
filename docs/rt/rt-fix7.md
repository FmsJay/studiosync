# rt-fix7: the non-sync-core findings of the rt-r2 re-check (2026-11-21)

The bugs rt-r2 found outside the sync core (`docs/rt/rt-p14.md`, `rt-invite.md`, `rt-joinlink.md`, `rt-hubrank.md`, `rt-nat3.md`,
`rt-perfcut4.md`, each "rt-r2" section). Lua and web page only: no C++, no version bumped, nothing run on the test computers or VMs.
Not touched: `lib/mirror.lua`, `lib/sync.lua`, `lib/claimask.lua`, `lib/undo.lua`, `tools/soak/*` (rt-converge's).

| # | Finding | Fix | Test (fails without the fix: checked) |
|---|---|---|---|
| A | Sends panel: the last-moved slider never followed REAPER (focus counted as a hand) | `lib/webui/daw.js`: a hand is the pointer held (pointerdown until pointerup/cancel) or a move (pointer or keys) under `HAND_MS` (1.5 s) ago; focus no longer counts. Mute box the same | `tests/rt_p14_browser.mjs` (sends: focused slider follows; held keeps; let go a moment keeps; then REAPER's -3 dB) |
| P14 5 | A vertical drag of a CC point also moved its time (480 to 0 ticks) | `lib/webui/pianoroll.js`: the time follows only once the drag has gone sideways past 8 px (14 on touch); a value-only drag sends `keep: true`, and `lib/dawmidi.lua` then leaves the point's ticks (`MIDI_SetCC` ppq nil), so the page's ms rounding can't move it a tick either | `tests/rt_p14_browser.mjs` (CC: vertical keeps 4.03 s and says keep; sideways moves), `tests/test_0_60_rt_dawmidi.lua` (keep: ticks kept) |
| B | Linux link launcher: `reaper -nonewinst` started a second REAPER | `lib/urlhandler.lua` `linux_launcher`: the link file is written first; then REAPER starts only when none of this user's runs (`pgrep -u $(id -u) -x <reaper's name>`, `pidof` where there's no pgrep). Windows (`-nonewinst` works) and the Mac (`open`) unchanged | `tests/test_0_60_rt_fix7_links.lua` 1; the launcher also run under sh here with stand-in `pgrep`/`reaper`: running, only the file; not running, REAPER started once |
| B | Without Autostart nothing read the clicked link's file unless the panel was open | `invite.live_tick`: Live sync calls it every tick (one line in `StudioSync - Live sync.lua`); it runs `invite.tick` (once a second) while Autostart's beat is over 20 s old or missing | `tests/test_0_60_rt_fix7_links.lua` 2 |
| F | NAT3: LinuxBox2 kept "can't reach james-laptop, james-main, linuxbox (its name doesn't resolve)" while reaching them without Tailscale | `lib/direct.lua` `health_line`: a failed peer whose person (devices files, else the name) is reached by any other peer entry isn't "can't reach" | `tests/test_0_60_rt_fix7_direct.lua` (rt-r2's exact row before the fix) |
| Hub B | A 21 s hand-off with one miss | see below: a holder's "Syncthing behind" now settles 30 s; the log says why a hub moved | `tests/test_0_60_rt_fix7_hub.lua` 3 |
| Hub B | Both VMs cut: `why = "kept"`, not "ranked" | `hub.elect_song`: with the home passed over, the holder that is also the ranking's pick says "ranked" | `tests/test_0_60_rt_fix7_hub.lua` 2 |
| Hub B | The studio hub split on the cut-off VMs | `hub.drop`: one the link lost here stays a candidate while another here (not lost, not a guest) says its own link reaches it; the VMs then name James as the others do, and pass the home over by reach like them | `tests/test_0_60_rt_fix7_hub.lua` 1 |
| Joinlink B | A removed computer's folder stayed current, so Paste join code said "already" | see below | `tests/test_0_60_rt_fix7_join.lua` |
| perfcut4 7.2 | `status/file` 7-9 ms a write (expected ~2) | `lib/band.lua` `finish`: the size check reads the written handle's position (`f:seek("end")`, which flushes) instead of opening the .tmp again; Windows skips the rename over an existing file it always refuses | `tests/test_0_60_rt_fix7_write.lua` (one open, two renames, a short write still refused) |
| VM audio | LinuxBox2's input may be the desktop's real input | Warning in `docs/rt/rt-lab.md` and `tools/lab/README.md`, with a null-sink recipe | (docs) |

Also found and fixed on the way: `invite.on_token` wrote `local root, why = cfg and services.join_band(cfg, code)`, which keeps only the
first value, so `why` was always nil (its "didn't join: ..." line lost the reason).

## The hub hand-off (rt-hubrank round 2 B)

The desktop's log (`J:\Portable Workstation\DAW\REAPER\StudioSync\logs\studiosync-2026-11-21.log`, read only) has "Syncthing didn't answer
within 6 s" at 20:03:32 MT and "LinuxBox's status is late here" at 20:05:15, between "James-Laptop is its hub now" (20:05:13) and "you're
the hub" (20:05:34). The miss rule (`home_far`) can't hand back in 21 s: once passed over, the home hosts again only after `REACH_SETTLE`
(30 s) without two misses. A 21 s round trip fits the other way out of the election: `hub.lagging` (the desktop's own status files late
while the link brought fresh ones) took the desktop out at once, and the next scan put it back. Whether the second miss also came (a
NAT flap of LinuxBox2's) can't be told from what was captured.

So, to the round-2 design's "a flap moves nothing":
- **Lag settles for a holder.** A computer holding a role (the studio's or this song's) leaves it for its Syncthing being behind only once
  that has held `REACH_SETTLE` s without a break; its status says `lag` from then. Holding nothing, it still takes nothing at once (rt-p9).
- **The log says why.** "'Cross Test': James-Laptop is its hub now (Syncthing is behind here)" or "(2 here can't reach James directly)", so
  the next re-check can tell the cause from the log alone.
- `home_far` itself is unchanged: two misses for 30 s pass the home over, 30 s without bring it back (already tested in `_hubp9` part 2).

## A computer taken out (rt-joinlink round 2 B)

What it sees now: when the owner's or an admin's removal mark for this computer is due (the same minute after which everyone unshares
it), or its guest time is over, `removal.tick` marks the folder old here once (`removal.mark_old`, ExtState `out old <studio id>` = the
mark's time), as leaving does. Then:
- Paste join code with a new invitation: not "already"; `services.join_band` joins into the old copy's folder and returns `"back"`, and
  the page asks the inviter's computer (`joins.request`) though the copy has its `band.json`. An invite link's answer the same
  (`invite.on_token`), and a code link for that studio isn't "You're already in" (`invite` `member_root` skips old folders). The welcome
  never overwrites a file the copy has (`joinboot`: "another version there: Syncthing's word").
- The Groups page lists it under "Closed or left" (Delete my copy / Keep it, hide this). Hidden once, the same mark doesn't make it old again.
- Let in again (the mark deleted by the owner's computer, as Let them in does): it isn't old any more.
- A "left" mark adds nothing (groups.leave marks it old itself).

Held security list: nothing here changes a check. The inviter's side still refuses a device "taken out since the invitation was made"
(`removal.out_since`), and a removal mark still counts only from the owner's or an admin's computer.

## The status write (perfcut4 7.2)

`status/file` is `band.write_json` alone (the status file isn't a signed kind, so `signed.on_write` returns after its pattern match).
Measured here with the same steps in Lua (200 writes of 450 bytes): the second open of the .tmp to measure it took 1.9-12 ms in a temp
folder and 37 ms on J:, where everything else together is about 3 ms: Windows' on-access scan holds a file just written until it has read
it. The handle's own position after `seek("end")` is the same check (the write is flushed, a refused write fails it) without the open.
The `link/*` laps (30-40 ms per 10 s) were below rt-perfcut4's 60-90 expectation: nothing to cut there.

## REAPER and browser checks for the real computers (after a release with this Lua; no extension needed)

1. **Sends (desktop web UI, Cross Test):** open Sends on XT Keys C, drag send 1's level to -32 dB and let go; wait 2 s; Ctrl+Z in REAPER:
   the slider goes to 0 dB within a second of the next look (it used to stay). Set -3 dB by script: it shows. While holding the slider
   down, REAPER's changes don't move it.
2. **CC drag:** open a MIDI item with CC1 points, drag one straight up: only its value changes (ticks as before: check with
   `MIDI_GetCC`); drag one sideways: it moves, snapped.
3. **Linux link (LinuxBox, handler ticked):** with REAPER running, `xdg-open` a member link: no second `reaper` process (`pgrep -a reaper`
   shows one), and the link is read (the log's "opening ..., from the web page (a link)") with Live sync running and Autostart off. With
   REAPER closed: one REAPER starts.
4. **NAT3 row (LinuxBox2, Connect without Tailscale on):** Health's direct-link row lists no "can't reach" for computers it reaches without
   Tailscale; an offline Mac is still named.
5. **Hub B (VM lab):** repeat rt-hubrank R2 B. With only LinuxBox cut: no hub lines; if one comes, its "(...)" says why. Both VMs cut:
   after 12 + 30 s the hub is James-Laptop on all four with `why = "ranked"`, and the **studio** hub James on all four. LinuxBox cut alone
   views James (it named the laptop).
6. **Joinlink B (needs the coordinator's OK: removal unshares on the real PCs' Syncthing):** take LinuxBox2 out; after the minute its
   Groups page lists Smiley Studios under "Closed or left"; Paste join code with a new invitation asks the desktop (welcome in its log),
   and after Let them in the folder is current again.
7. **perfcut4 7.2:** rt_perf on the desktop, idle 5 minutes: `status/file` about 1-3 ms a write (was 7-9).

## Not done / limits

- The 21 s hand-off's exact cause is inferred from the log (no hub view was captured then); the log line now names it next time.
- `hub.drop`'s vouching uses the voucher's newest `sees`: a hub that really drops is still dropped once every computer's link has lost it,
  but a computer that relies on another's word follows that computer's next status (seconds over the link). `_hubrank`'s failover sim
  (replaced within LINK_GONE + 4 s) still passes.
- The Linux launcher no longer raises the running REAPER's window (nothing on Linux did: `-nonewinst` started a second one). If neither
  Live sync, Autostart nor the panel runs there, the link waits until one does, as before.
- `startup.hand_over` (tabs handed to the running REAPER at start on Mac and Linux) also uses `-nonewinst` on Linux; not changed or checked.
- A computer taken out, then let in again by Let them in without pasting a code: its folder is current again only once the deleted mark
  reaches it through Syncthing.

## Review later (security)

- `hub.drop` keeps a computer this one's link lost on another member's word (its status's `sees`). A member could keep a dead or cut-off
  hub named by claiming to reach it; before, it could already keep a late status alive the same way (`hub.vouched`). Guests' word doesn't count.
- `removal.mark_old` acts on accepted marks only (owner's or admin's computer, `trust.mark_ok`), and only changes this computer's own view.
