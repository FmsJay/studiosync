# When two people change the same thing

This is how StudioSync decides today, how other collaborative tools decide, and the choices left open. Nothing here
is settled for good: it's written down so the band can decide later with the facts in one place (James, 2026-10-31).

## What StudioSync does now

Most edits never clash. Each track, item, plug-in chain, envelope and send is its own object, so two people changing
different things both land. A clash is two changes to **the same object** that neither saw before making theirs:
both were apart (offline, or Syncthing hadn't caught up), or both changed it within the same second or two.

1. **Rules come first.** In *Only the driver* and *Driver + claims*, a change you may not make is put back on your
   machine at once, with the reason, so most would-be clashes never reach the band. In *Anyone*, everything
   unclaimed is open, the tempo map and markers too.
2. **The owner wins** (James, 2026-11-04). A change by whoever has claimed it, or by the driver on what's unclaimed, takes a version number far past anything made meanwhile (`mirror.next_rev`), so it stands however often someone else changed it, and every computer agrees without being told who owned what.
3. **Items are merged, not picked** (0.58.43). Two changes to one item made apart are put together: each line of the item (its
   place, length, fades, volume, each take's settings and notes) comes from whichever side changed it, so one person moving a clip while
   another turns it down keeps both. Every computer works out the same merge from the two changes and the version they both started from
   (each change says which one: `base_ev`), so nobody has to send it (`mirror.merge_item`, `mirror.event_file` in `lib/mirror.lua`).
   "Started from" is the nearest version both build on, found by walking back through both (0.58.47; before, the older of the two bases,
   which lost what one side changed in between). When a change in between hasn't arrived yet, nothing is merged: the change waits for it,
   two minutes at most (`mirror.descends` answers "can't tell"), so two quick edits arriving out of order are never taken for a clash.
   Nor when the version they started from is over a month older than the newer change (`mirror.too_old_to_merge`, 0.58.53): someone back
   after more than a month. History trim may have taken that version away on some computers and not others, so merging only where it's
   still there would leave the projects different. Decided from the changes' ids alone, the same everywhere: rule 4 settles it whole.
4. **Where both changed the same thing, more edits wins,** counted in edits, not nudges: changes to one thing within 30 seconds of your
   last one are one edit (`mirror.SESSION_SECS`), except the owner's, which always jump past what others made meanwhile (rule 2). A tie goes to the hybrid logical clock (milliseconds, never behind any change the computer
   has seen, so a clock that's off can't win it), then to the name that sorts last (`mirror.newer`, `mirror.order_of`).
5. **Both rewrote the same notes or audio:** the winner's take plays, and the loser's comes along as another take named "X's version",
   which StudioSync's takes-into-lanes then puts on a lane of its own. Nothing anyone recorded is lost.
6. **Nothing is lost, and yours is a click away.** The losing version stays in History. Its owner is told what happened, with a
   **Use mine** button that puts all of theirs back for everyone, unless the other person owns it. When both worked alone, a saved version
   of the loser's whole project is kept first.

Known weak spots:
- Tracks, plug-in chains, automation and sends are still settled whole (rule 4), not merged. So is an item when its starting version is
  over a month old, even for two people the same day (rule 3).
- Three or more people changing one item at once can merge in a different order on different computers (Health shows it as "came out
  different"); two at once always agree. Heal then brings everyone to the same merge, compared by exact id (0.58.47).
- A bandmate on StudioSync older than 0.58.43 settles two nudges made in the same second the other way round; everyone on 0.58.43+ agrees.
- The loser still hears about it after the fact. There is no "both versions, pick one" step.

## How other tools decide

| Tool | How a clash is avoided or settled |
|---|---|
| **Pro Tools cloud collaboration** (Avid) | Per-track **ownership**: one person owns a track at a time and asks the owner to hand it over. You can still edit a track you don't own, but the owner's version is the one that goes to the project; yours shows as a conflict (yellow upload/download arrows) until you take theirs or get ownership. Changes are shared per track, when you choose. |
| **Figma** (design, not audio: the best documented live model) | A central server orders every change. Two changes clash only if they set the same property of the same object; then the **last one the server received wins**. No locks. |
| **Ohm Studio** (live collaborative DAW, now discontinued) | Everyone edits live in one shared project; each change is logged with who made it. Tracks can be kept **private** until you're ready to reveal them. |
| **BandLab, Soundtrap** | Live co-editing in the browser. Neither publishes how two edits to the same clip are settled; general write-ups describe edit locking or last-writer-wins as the usual answers. |
| **Splice Studio** (retired), Dropbox-style sharing | Whole-project versions: whoever saves later makes a new version, and the older ones stay in the history to go back to. |
| **git and code tools** | Merge what doesn't overlap; where it does, stop and ask a person to choose. |

## The choices, if the band wants to change it

- **Keep "more edits wins"** (now): automatic, the same on every machine, no waiting on anyone.
- **Last change wins** (Figma): simple to explain, but "last" depends on clocks when there is no central server, and
  a quick tweak can replace an hour's work.
- **Owner wins** (Pro Tools): the driver or the claimant's version always wins on what they own; StudioSync's claims
  are halfway there already.
- **Ask** (git): show both versions and let the person whose change lost pick. Safest, but it interrupts playing.

Sources: [Sound On Sound, Cloud Collaboration in Pro Tools 12.5](https://www.soundonsound.com/techniques/part-2-cloud-collaboration-pro-tools-125),
[AudioTechnology, Pro Tools Cloud review](https://www.audiotechnology.com/reviews/pro-tools-cloud-nine-or-nein),
[Evan Wallace, Multiplayer editing in Figma](https://madebyevan.com/figma/multiplayer-editing-in-figma/),
[Figma, Making multiplayer more reliable](https://www.figma.com/blog/making-multiplayer-more-reliable/),
[MusicRadar, Ohm Studio review](https://www.musicradar.com/reviews/tech/ohm-force-ohm-studio-590570),
[Synthtopia, Ohm Studio](https://www.synthtopia.com/content/2011/03/24/ohm-studio-demo-2-people-making-music-together-in-real-time/),
[Soundbridge, real-time collaborative DAWs](https://www.soundbridge.io/real-time-collaborative-daw-your-2026-production-guide).
