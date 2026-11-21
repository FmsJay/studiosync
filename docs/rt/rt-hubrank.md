# rt-hubrank: a song's hub by who reaches whom

2026-11-20. Lua only: no C++ change, no extension release, no version bump. **Tests with stand-ins only: not run in REAPER or between
real computers.** Builds what rt-hubfix part 2 left ("a hub is still chosen without asking whether everyone can reach it") from the
`sees` and `ext` every computer already publishes.

Files: `lib/hub.lua`, `lib/livex.lua`, `tests/test_0_60_rt_hubrank.lua` (new), this note. `lib/liveaudio.lua` needed no change.

## The ranking

For every computer in the song's room, from the statuses (`hub.reach`):

- **miss**: how many of the others in the room don't reach it, by *their* word (their status's `sees`).
- **blind**: how many of the others it doesn't reach, by its own word.

A song's ranking (`hub.closer`) is: fewest miss, then fewest blind, then the ranking as it was (the direct link listening, online
longest, machine id, name). Every computer works out the same numbers from the same statuses.

Where it applies in a song's election (`hub.elect_song`), in order:

1. **The song's home, when it's here: it hosts, whoever reaches it.** Unchanged (James: the project's home hosts the mix unless shared
   CPU runs). The owner's pick for the studio hub is unchanged too.
2. **Whoever holds the role keeps it**, unless another eligible computer is clearly better reached (the hysteresis below).
3. **The studio hub, if it has the song open**, unless another is reached by more of the others.
4. **The ranking** above.

Eligible is as before: not handed on, not a guest, not just come online, and an extension of `hub.EXT` (1.0.28) or newer while anyone
has one. An old extension is never elected however well it's reached, and nobody waits for it: it's left out before reach is looked at,
so no settling time applies. Its computer still counts as one of the others who must reach the hub.

Details:

- `sees` is read song by song (`songs[song].sees`). A computer with two songs open writes two statuses; before, only its newest
  status's `sees` was kept, which could be the other song's room.
- A status that says nothing about reach (no `ext`: an older StudioSync, until its update arrives) is nobody's miss and has no numbers
  itself, so it ranks exactly as before. Same rule as rt-hubfix's for `ext`: an update that reaches the computers one by one moves no role.
- A guest's word isn't counted (and guests are never a hub, as before).
- The numbers are worked out before this computer's own link losses are dropped from its list, so every computer counts the same statuses.
- Two computers that both say they hold the role (a move in flight, a partition healing): the ranking as it was decides at once, the
  same everywhere, as before. Reach then moves it through the settling time. Reach numbers reach the computers at different moments,
  so between two holders they would name different ones for a while.
- The studio hub's own election is unchanged: `sees` is per room, so computers in different songs have no word about each other.

## The hysteresis

**The holder keeps the role unless another eligible computer is reached by at least one more of the others (`REACH` = 1), and has been
without a break for 30 s as this computer sees it (`REACH_SETTLE`).** Then the role goes to the best-ranked.

- Equal reach never moves it, whatever the tie-breakers say (reaching more itself, online longer). That is "marginally better".
- A hub everybody reaches can't be replaced by reach at all.
- A link that drops for a moment doesn't move it: the link watch takes a name out of `sees` after 12 s (`LINK_GONE`) and puts it back
  at once, so a 20 s drop is 8 s of worse reach. A link flapping faster than about 40 s down at a time never moves it.
- A move always goes to a computer more of the others reach, so the role settles on one everybody reaches and stays there.
- A hub that drops out altogether is still replaced within the link watch's seconds, as before; that isn't a reach move.
- The count is each computer's own (`reach_mem` in `hub.tick`), not shared. Around a move the computers can name different hubs for a
  few seconds (up to a status's trip through Syncthing for one that only reads the others as files). Audio stays two-way meanwhile
  (rt-hubfix part 1).

## The live mix's host while shared CPU runs (`lib/livex.lua`)

James's decision stands: the best-connected computer hosts the mix only while shared CPU runs; otherwise the song's hub (its home).
"Best-connected" now starts with the same two numbers: fewest miss, fewest blind, then wired, round trip, CPU, the song's hub, name
(`livex.mix_better`). A computer two bandmates can't reach can't mix for them, however fast its network.

- `livex.mix_cands` counts everyone in the room by the statuses, not only those live audio reaches here, so every computer ranks the
  same numbers. A guest's word isn't counted.
- The one mixing keeps it unless another is clearly better: reached by more of the others is now one of those reasons, beside wired
  against Wi-Fi and 20 ms less round trip. rt-sonox's 4 s settling applies.
- Health's live audio row adds "N here can't reach it directly" when the host is missed by anyone.

## Health

- The hub row says who has no direct link to the song's hub: "No direct link to this project's hub from: LinuxBox." This matters most
  when the home hosts and someone can't reach it. The view (`hub view <id> <song>`) carries it as `far`.
- A hub chosen by the ranking reads "the one the others here reach best, then online longest" (was "online longest").

## Tests

`tests/test_0_60_rt_hubrank.lua`:

1. **The numbers and the pure election.**
   - Three computers, two that can't reach each other and one that reaches both: the numbers; the middle one is chosen though another is
     online longest; the studio hub is passed over for it; with everybody reaching everybody the studio hub as before; the home hosts
     whoever reaches it, and `hub.far` names who doesn't.
   - The settling time: not at once, not a second early, after 30 s; a break starts the count again.
   - Two holders: the ranking as it was until this computer's settling time is over.
   - Marginal: a holder everybody reaches stays though two are online longer; a holder that reaches one fewer itself stays; with
     nobody holding, that tie-breaker counts.
   - Four computers (one pair can't reach each other): the one everybody reaches, the same answer in any order of statuses; everybody
     reaching everybody leaves the holder.
   - Five computers: one that two bandmates can't reach is never chosen over one everybody reaches (fresh, as the studio hub, or
     holding); a well-reached holder stays though another is online longer.
   - An old extension: not elected though it holds the role and everybody reaches it, replaced at once with no settling time; its
     computer still counts as one of the others; nobody's new enough: the best reached still gets the role.
   - An older StudioSync (no `ext`, no `sees`): no numbers, nobody's miss, keeps what it holds.
   - Someone in another song isn't counted; candidates without numbers rank as before.
   - A lying computer: claiming to reach everyone doesn't elect it; leaving the holder out of its `sees` does move the role (the known limit).
2. **A small world over 20 minutes** (each computer elects from the statuses as they reach it; the real link watch; files 8 s then 60 s late):
   - Three, partial reach: the hub goes to the one both reach, once on each computer, after the settling time, agreed to the end; the
     two that can't reach each other never trade it.
   - The same with the song's home holding it: nothing moves. The home away, then back: handed to it, as before.
   - Two alone that can't see each other: nothing moves (rt-hubfix's case).
   - One old extension (the best-reached computer's): never elected, the other two don't trade the role; holding it at the start, it's
     given up at once on all three. An older StudioSync: steady.
   - Four and five computers with partial reach: one move each to the one everybody reaches.
   - Hysteresis in a room where everybody reaches everybody: 20 minutes, no move though another ranks ahead; one link down for 20 s: no
     move; flapping every 20 s for ten minutes: no move; gone for good: one move about 42 s later; down a minute at a time: one move, never back.
   - One that drops out and returns: replaced within the link watch's seconds; returning as a REAPER just started, the new holder keeps
     it; returning still holding, settled within seconds; the well-reached one leaving a room with partial reach and returning: away
     once and back once.
3. **Live sync's tick end to end:** `sees` read from the status of this song, not the newest one; the holder kept at first sight, moved
   once the settling time is over; `far` and Health's words; the home hosts though this computer can't reach it; a guest's word not
   counted, a member's counted.
4. **The live mix's host:** the candidates' numbers; a wired, fast computer two can't reach loses to one everybody reaches; handed over
   from it; kept when equally reached; counted over the whole room; a guest's word; statuses without numbers as before; Health's words.

`tests/test_0_60_rt_hubfix_elect.lua`, `test_0_60_rt_hub.lua`, `test_0_60_rt_hubmix.lua` and `test_0_60_rt_sonox.lua` pass unchanged.

## To check on three real computers (desktop, laptop, LinuxBox)

Lua only, so after the update reaches all three. All three need extension 1.0.28 or newer. The ranking works below the song's home, so
use a project whose home is away (one the Mac shared), or have its home click Health > Hand it on first.

1. **Baseline.** All three in the project. `rthf_view.lua` (rt-hubfix's read-only probe) on each: the same `hub` in all three views;
   each status file's hub part has `sees` naming the two others; no `far`. Health's hub row is the same on all three.
2. **Partial reach.** Note who the hub is. Block the direct link (port 47281) between the hub and one other computer, leaving both
   able to reach the third (a firewall rule on one of the two, for that one address).
   - Within about 12 s the two statuses drop each other from `sees`.
   - About 30 s after that, all three views name the third computer, `why` = `ranked`. Its log says "you're the hub for '...' now"
     once; the old hub's says "'...': <name> is its hub now" once.
   - Health's hub row: "this project: <name> (the one the others here reach best, then online longest ...)".
   - The computer that lost its link to the old hub leaves it sooner (its link watch drops the old hub after 12 s, as before).
3. **It stays.** Leave it 30 minutes: no further "you're the hub" / "is its hub now" lines on any of the three.
4. **No move back.** Remove the block: `sees` fills again, the hub stays where it is.
5. **A short drop.** With everybody reaching everybody, block the same link for 20 s and remove it: no log line on the hub or the third
   computer. The blocked computer's own view may leave the hub and come back.
6. **The home hosts.** In a project whose home is one of the three and present, block that home's link to one other: the hub stays the
   home ("shared it") on the home and the third computer, and Health adds "No direct link to this project's hub from: <name>". The
   blocked computer's own view drops the home after 12 s, as before rt-hubrank.
7. **Shared CPU.** Settings > Studio > "The song's hub mixes it" from 3 people; offload one track's FX; block one link as in 2. Health's
   live audio row names the computer both others reach as mixing, on all three; for a host someone can't reach it says "1 here can't
   reach it directly". `underrun.lua`: no peer silent for more than a jitter buffer during the handover.
8. When the Mac is back (extension 1.0.23): it's never the hub while a computer with 1.0.28 or newer is in the room, however well it's
   reached, and nothing waits for it.

## Left

- **The home and the owner's pick aren't ranked by reach.** A home two bandmates can't reach still hosts; Health now says who can't
  reach it. Passing over a home that N can't reach would be one more `clearly` test in `hub.elect_song`: James's call.
- **What decides a song's home** is untouched. The ranking never reads session.json: it takes `home` as given by `hub.home`. If the
  home comes from something only the sharer writes, the home is known all the time, so the ranking decides only while the home is away,
  handed on, a guest, or on an old extension, and never because the home "went missing" for a moment. Nothing here needs changing for it.
- **The studio hub's election** doesn't use reach (no word between computers in different songs).
- **A guest's reach isn't counted**, so a hub can be one a guest can't reach.
- **A returning or new computer** can be named by the others up to 15 s before it takes the role itself (their 30 s against its 45 s of
  listening first). The home's handback has the same gap today.
- **The live mix's host** uses rt-sonox's 4 s settling for reach as well, not 30 s: one link down for 16 s can hand the mix over once
  while shared CPU runs.
- **`blind`** is the computer's own word and only breaks ties.
- `docs/rt/backlog.md` still lists this as not built (lines 44-45 and 170): not my file.
- Not run in REAPER or between real computers.

## Review later (security)

`sees`, like `ext`, `since`, `link` and "I hold it", is each member's own word in its own status. What a lying member's computer could do
with `sees`:

1. **Cost another computer one miss by leaving it out.** With `REACH` = 1 that is enough to move the role off a holder everyone else
   reaches, 30 s later, to the best of the rest.
2. **Make itself a song's hub.** Leaving everyone else out gives each of them one miss; if the others do reach the liar, it is then
   the only one with none and takes the role after 30 s. Only below the home and never as a guest. A member could already do this by
   claiming to be online longest or to hold the role. It gains the hub's jobs (restore points, the live mix from 4 people): streams it
   already receives peer to peer, and the chance to mix badly.
3. **Move the role back and forth.** Leaving out whoever holds it, then the next holder, moves the role about every 30-45 s. Audio
   stays two-way through each move (rt-hubfix), but it's a nuisance a member can cause. Possible limits: a cap on moves per hour, or
   `REACH` = 2 in rooms of four or more so one computer's word is never enough.
4. **Hide that it can't reach someone** (claim to reach everyone). That lowers only its own `blind` (a tie-breaker) and the other's
   miss by one; it can keep a hub the liar can't reach, which hurts the liar.
5. **Leave out `ext`** (pose as an older StudioSync). It then has no numbers, counts as reached by all, and reach can't displace it
   while it holds a role. That is the transition rule; once every computer has this build, a status without `ext` should count as
   missed by everyone or not be eligible.
6. **Become the live mix's host while shared CPU runs** by the same numbers, as rt-sonox listed for `net` and `lrtt`.
7. **Put its name in Health's "No direct link ... from"** on everyone's hub row.

What it can't do: lower its own miss (that is the others' word), elect a guest, override the home, the owner's pick or a handover,
elect an old extension, or affect the studio hub. A guest's `sees` is ignored (the guest marks decide who is a guest, not the guest's
status). `sees` is read from statuses that already passed presence's and the link's checks; `hub.reach` is n squared over the room's
members, with nothing stored per name beyond the candidates list.
