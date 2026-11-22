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

## Check results (rt-r0, 2026-11-21, 0.59.49.92 + extension 1.0.34)

- **1: pass** (with Cross Test's home, the desktop, present). All three views: `hub` = `home` = James, `why` = `home`; each status file's hub
  part `sees` names the two others; `far` false everywhere. Health's row not read.
- 2, 4, 5, 6, 7: not run: each needs the direct link blocked between two computers (no firewall changes on the desktop or laptop; LinuxBox's
  `iptables` needs James's OK). 3: not run (my hand-off test for rt-answers check 3 wrote hub lines on purpose).
- Also seen (rt-answers check 3): handing Cross Test's hub to LinuxBox and back moved `hub` on all three within 25 s, one "you're the hub"
  line on LinuxBox and one "is its hub now" on the desktop each way.

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

## Round 2: package P9 (rt-p9, 2026-11-21)

Backlog P9 (items 1.20 and 4.d). Lua (`lib/hub.lua`, `lib/livex.lua`) and C++ (`extension/rtaudio.cpp`: `hub_watch` and the receive
thread's gap learning; `extension/rtaudio.h`: one test hook). The C++ needs the next extension release; nothing bumped, no binaries.
**Offline and native tests only: nothing run in REAPER or between computers.**

| Item | Built | Test (fails without it: checked) |
|---|---|---|
| A computer with Syncthing paused isn't a second hub | `hub.lagging`, `lag` in the status | `test_0_60_rt_hubp9.lua` 1 |
| A home that two bandmates can't reach (4.d) | passed over after 30 s, hosts again after 30 s | `test_0_60_rt_hubp9.lua` 2 |
| A guest's reach counted | a guest is one each must reach, by that computer's own word | `test_0_60_rt_hubp9.lua` 3, `_hubrank` 4 |
| A returning computer named 15 s early | the others apply its LISTEN from its `since` | `test_0_60_rt_hubp9.lua` 4, `_hub` (handbacks) |
| The mix host settled 30 s like the song's hub | already built (rt-hubsmall item 6); nothing changed | `test_0_60_rt_hubsmall.lua` 6 |
| The stall-learning `mix_gap` | the part of a gap the send thread's stall covers isn't learnt | `rtaudio_test stalls` (new check) |
| A Wi-Fi listener kept through its own outage | `own_outage` in `hub_watch` | `rtaudio_test outage` (new) |
| The studio hub's election by reach | not built (no word between computers in different songs, as before) | |

### 1. Syncthing paused: not a second hub

The design constraint stands (rt-linkmove round 5): every computer elects from the same inputs. The open room's statuses already reach
the election over the link (`hub.with_room` merges `presence.peers`, which has the link's statuses). What a computer with Syncthing paused
lacks is everyone in the room it doesn't reach directly, and every other song (so the studio hub): there it elects on stale files. So it
now **says so in its own status** and takes itself out:

- `hub.lagging(live, list)`: the link brought fresh statuses from `LAG_HEARD` (2) or more bandmates in this room, and none of them has a
  status file here under `VOUCH` (150 s) old. One bandmate alone can't tell whose Syncthing is paused (theirs or this one's), so two
  computers never lag; with three, the paused one sees every file stale, the others see only its file stale.
- Its status's hub part says `"lag": true`. Every computer that has its status (by file or link) reads it the same way: it isn't eligible
  for the song's hub or the studio hub (like `off`). Its own election leaves itself out the same way, so it never claims a role and gives
  up one it holds (its restore points couldn't travel anyway). If everyone in the room says `lag`, it's as before (the roles still go
  to someone). The home is passed over too while it lags.
- Health: "Syncthing is behind here (...), so this computer takes no hub role until it catches up." The view carries `lag`.
- When Syncthing runs again, the next scan (10 s) clears it; whoever holds the role meanwhile keeps it.
- Limits: a computer paused for under 150 s isn't noticed (the vouching rules cover that span as before); one that hears only one
  bandmate over the link can't tell and elects as before. Its own view of who the hub is can still be wrong while paused (it may name a
  computer that isn't the holder, since it can't see the holder); it just doesn't claim. Relaying the elected name was not built.

### 2. A home that two bandmates can't reach (backlog 4.d, the section-4 default)

`hub.elect_song`: the home is passed over when `HOME_MISS` (2) or more of the others in the room don't reach it (`miss`, their word) and
another computer that would take the role is reached by all (`miss` 0). With the tick's memory, only after that has held for
`REACH_SETTLE` (30 s) without a break, and it hosts again once it hasn't held for as long (a link that drops for a moment, or flaps 20 s a
minute, moves nothing). Passed over, it isn't kept as the holder either; the ranking below the home decides (usually the one everybody
reaches). The owner's pick for the studio hub isn't touched. Health: "this project: Cy (the one the others here reach best, then online
longest, James is the project's home but 2 here can't reach it directly)". The view carries `passed` (that number).

### 3. A guest's reach

`hub.reach(cands, song, guests)`: a guest in the room counts as one of the others each computer must reach, judged by that computer's own
`sees` (does it name the guest?), never by the guest's: a guest's word still moves nothing, but a hub a guest can't reach now has a miss
for it. Guests get no numbers and are never elected (as before). `hub.far` names a guest the hub's own word says it doesn't reach.
`livex.mix_cands` does the same for the live mix's host.

### 4. Not named before it takes the role

A computer takes no role for its first `LISTEN` (45 s) online, but the others handed a role back to it after `HANDBACK` (30 s), so they
named it up to 15 s before it took it. `taking(c, now)` now also applies `LISTEN` from the candidate's own `since` (in its status), so
every computer names it when it takes it. `HANDBACK` still applies to a computer the link lost and found again (`back`). Before LISTEN
is over, nobody is named for a role nobody holds, as the computer's own view already did.

### 5. The live mix's host

Already built by rt-hubsmall item 6 (`livex.mix_decide` waits `hub.REACH_SETTLE` for a move only about reach; `_hubsmall` part 6).
Backlog 1.20's "settles reach in 4 s" is out of date.

### 6. The stall-learning `mix_gap` (C++)

rt-hubwatch's "Found, not changed": after a VM stall the receive thread learnt the stall (150 ms) as the mix's widest spacing for up to
60 s, so the rescue line went past `gone` and a real hub drop then fell back without the early rescue. Now `hub_watch` records its last
late pass's gap (`stall_from`, `stall_to`) and each pass's time (`watch_pass`); the receive thread (`gap_learn`) leaves out the part of a
gap that window covers. A gap over `WATCH_LATE` waits for the send thread's next pass after it (the threads wake in either order) and is
decided then, on the next gap, or after 1 s. Gaps the send thread didn't share (Wi-Fi's bursts: the receive thread alone) are learnt as
before (`rescue_test` unchanged). Test: X's threads held 150 ms five times; X's `mix_gap_ms` after: 10-14 ms (without the change: 161 ms).

### 7. A Wi-Fi listener kept through its own outage (C++)

rt-hubsmall had this as "not recommended yet" (a real hub drop could wait up to a quarter second). Built with that bound: `own_outage`
keeps a listener on the mix while **nothing** has come from anyone else since the mix's last datagram, when someone else was heard in the
`OWN_BEFORE` (0.5 s, two of the listeners' 'M' rounds) before it; for at most `OWN_MAX` (2 s). Someone else heard after the mix stopped
means the network is up here: `OWN_GRACE` (20 ms) from the first pass that sees it, for the mix to show too, then the fallback. In a room
of two (nobody else to hear) it falls back as before. Cost: a real hub drop falls back when the first other datagram arrives plus 20 ms;
the other listeners' 'M' come every 0.25 s and at once when they fall back themselves, so at most about 0.27 s. A rescue ('M' = 0) is
still sent during the outage. Tests (`rtaudio_test outage`): X hears nothing for 300 ms: stays "hub", no fallback (without it: "direct",
+1 fallback, 3.3 s on everyone's streams); a room of two: +1 fallback as before; then the hub's mix stops 600 ms: X and W both "direct"
by 0.4 s, +1 fallback each. The `stalls` test's late-every-pass listener still falls back (the grace counts from the first sight of
someone else, not the newest datagram: a rescue has everyone streaming to it).

### Tests

- `tests/test_0_60_rt_hubp9.lua` (new): parts 1-5 above. Each part fails against the code before this round (run part by part against
  `git archive HEAD lib`; the paused computer's tick on its own: "Lin" made itself the hub).
- `tests/test_0_60_rt_hub.lua`: the tie tests' computers are online 100 s (10 s was still in LISTEN); the preferred and home handbacks wait
  LISTEN from their `since`, with a check that they aren't named at HANDBACK.
- `tests/test_0_60_rt_hubrank.lua` part 4: a guest now costs a miss to the computers that don't reach it; its own word still doesn't count.
- `tests/rtaudio_test.cpp`: the `stalls` check on `mix_gap_ms`, and `outage_test` (also in `underruns` and the full run). Both fail with
  the change taken out (checked on Windows with each fix replaced by the old code).

### REAPER checks (R2, the VM lab)

Blocks and pauses happen **only inside the VMs** (`tools/lab/netlab.sh` through `lab.sh net`, Syncthing's REST on the VM), never on the
desktop's or laptop's firewall. Computers: LinuxBox (x1), LinuxBox2 (x2, once it's joined to Smiley Studios / Cross Test: rt-lab's pending
steps), the desktop; the laptop for B. All on this Lua; F needs the next extension release on all of them. Deafen on everywhere except F.
The view on any computer, read-only through the dev-eval hook: `reaper.GetExtState("BandSync", "hub view <studio id> Cross Test")` (JSON:
`hub`, `why`, `home`, `far`, `passed`, `lag`). Block the address the link uses (the Tailscale address, as rt-lab says).

**A. Syncthing paused isn't a second hub.**
1. All three in the room; LinuxBox2 holds the song's hub (a project whose home is away, or the desktop and LinuxBox click Health > Hand
   it on, then Be a hub again once LinuxBox2 has it). Each view: `hub` = LinuxBox2's name.
2. Pause LinuxBox2's Syncthing (its REST `/rest/system/pause`, as rt-r0 did on LinuxBox). Wait 3 minutes.
3. Expected: from about 150 s after the pause, LinuxBox2's view has `lag` true, Health says "Syncthing is behind here", its log says
   "'Cross Test': <name> is its hub now" once, and its status over the link has `"lag":true` in the hub part (the desktop's
   `presence live` ExtState for the room). The desktop's and LinuxBox's views name the same new hub within seconds of each other; no
   "you're the hub" on LinuxBox2 afterwards.
4. Partial reach on top: `lab.sh net x2 block <desktop's Tailscale IP> 47281`. For 10 minutes no "you're the hub" on LinuxBox2, and the
   desktop and LinuxBox keep naming one hub. `lab.sh net x2 undo`.
5. Resume Syncthing on LinuxBox2. Within about 20 s `lag` is gone from its view; the hub stays where it is (no hub log lines).

**B. A home two bandmates can't reach (four computers: the laptop too).** Cross Test's home is the desktop, all four present.
1. `lab.sh net x1 block <desktop's Tailscale IP> 47281` and the same on x2.
2. Expected: about 12 s later each of the two drops the desktop from `sees`; 30 s after that, all four views name the computer everybody
   reaches (the laptop, or whichever has `miss` 0), `why` = `ranked`, `passed` = 2; Health on all four: "James is the project's home but
   2 here can't reach it directly". One "you're the hub" on the new hub, one "is its hub now" on the desktop.
3. 10 minutes: no further hub lines.
4. Undo both blocks: about 30 s later the desktop hosts again (`why` = `home`), once.
5. Short: block the same two for 20 s and undo: no hub lines anywhere.
6. Three computers only (no laptop), the same two blocks: the desktop stays the hub (nobody else is reached by all), and Health names
   the two in "No direct link to this project's hub from".

**C. A guest's reach (if LinuxBox2 can be a guest of the room).** A project whose home is away, the desktop holding its hub, LinuxBox a
member. `lab.sh net x2 block <desktop's Tailscale IP> 47281` (on the guest). About 42 s later the hub moves to LinuxBox on the desktop's
and LinuxBox's views (the desktop no longer reaches the guest); before the move Health's hub row names LinuxBox2 in "No direct link ...
from". Undo.

**D. Not named before it takes the role.** Hand Cross Test's hub to LinuxBox (Settings > Studio). Quit LinuxBox's REAPER (SIGTERM),
wait for the desktop to name another hub, start it again and open the song with Live sync. Expected: the desktop's view names LinuxBox
within a couple of seconds of LinuxBox's own "you're the hub" line (about 45 s after its start), never about 15 s before it. Hand the hub
back afterwards.

**E. The live mix's host:** rt-hubsmall check 6 (unchanged).

**F. After the extension release (sound on, Deafen off on the three, nobody's microphone: a track's own test tone).**
1. The desktop mixes for the other two. Read LinuxBox's `StudioSync_LiveAudioStatus` hub block over a few minutes: `stalls` grows (a VM)
   while `mix_gap_ms` stays near its usual spacing (tens of ms), not jumping to 100-150 ms after a stall. Then quit the desktop's REAPER:
   LinuxBox's `rescues` +1 then `fallbacks` +1 (before: a fallback with no rescue whenever a stall had been learnt).
2. LinuxBox2 a listener (the desktop the hub, LinuxBox another listener). On LinuxBox2, in one ssh call, block the desktop's and
   LinuxBox's addresses entirely for 1 s, then undo (`lab.sh net x2 block <desktop IP>; lab.sh net x2 block <LinuxBox IP>; sleep 1;
   lab.sh net x2 undo`, or the same three netlab lines inside one ssh). Expected: LinuxBox2's `fallbacks` unchanged and `state` "hub"
   right after (before: +1 fallback, "direct" for about 3 s).
3. The same with only the desktop's address blocked for 1 s: +1 fallback within about 0.3 s (the hub gone, the others still heard).

### Left

- The studio hub's election doesn't use reach (unchanged).
- A paused computer's own view of the hub can be wrong (no claim, but it may ask for a mix where there's none until the join gives up);
  a paused computer that hears only one bandmate over the link isn't detected; under 150 s isn't detected.
- The home is passed over only when someone else is reached by all; a room where nobody is keeps the home.
- `own_outage` needs a third computer in the room; a room of two falls back on its own outage as before.
- Nothing run in REAPER or the lab; `docs/rt/backlog.md` still lists these as open (not my file).

### Review later (security), this round

- **`lag` is the computer's own word**, like `off`: with it a member can only take itself out. Leaving it out while paused gives the
  behaviour before this round.
- **A guest's reach** is judged by the members' own `sees`, so a guest can't move the role by what it says. A member could leave a guest
  out of its `sees` (a miss for itself only) or name it falsely (one fewer miss for itself: rt-hubrank's item 4 again).
- **Passing over the home** goes by the others' `sees` (rt-hubrank's item 1): two members who both leave the home out of their `sees` can
  move the song's hub off the home after 30 s, when someone else is reached by all. Before, nobody could move it off the home. A possible
  limit later: count a miss on the home only when the home's own `sees` agrees (it doesn't reach them either).
- `own_outage` reads when tagged datagrams last came (`rx_at`); a peer that keeps sending while the hub is gone shortens the wait, and
  nothing lengthens it past `OWN_MAX`.

### R2 re-check results (rt-r2, 2026-11-21 evening MT / 11-22 UTC, StudioSync 0.59.49.94 from 905f000 + extension 1.0.36 on the desktop, laptop, LinuxBox and LinuxBox2; Deafen 1 everywhere, no sound tests)

Blocks only inside the VMs (`tools/lab/lab.sh net`, plus raw iptables/ip6tables rules in a chain of my own, all removed: `undo` and the chain
deleted; checked empty). Connect without Tailscale was on for these (LinuxBox2 reaches the others only that way). Views read from
`hub view <studio> Cross Test` on all four.

**Lab lessons (for whoever runs these next):**
- `block 192.168.86.1` on a VM cuts the desktop's own ssh to it (the desktop's VMnet8 address is the ssh source). I got back into LinuxBox through
  LinuxBox2 (`ssh -J studio@192.168.86.130 studio@192.168.86.129`) and made the blocks UDP-only. Block UDP only (`-p udp`), or keep a jump host.
- To cut the desktop from a VM completely, block UDP for **every** desktop address: 192.168.86.1 (VMnet8), 192.168.6.1 (VMnet1), 192.168.0.5 (LAN),
  the public address, **and its Tailscale address 100.106.240.32 even on LinuxBox2 (no Tailscale)**: the desktop's link socket answers the VM from
  its Tailscale address through VMware's NAT (tcpdump on LinuxBox2: "In IP 100.106.240.32.47283"), plus IPv6 UDP (link-local). Until all were cut,
  the NAT link came straight back ("up 45 s").

- **A: pass (substituted).** LinuxBox2 can't hold Cross Test's hub here (the desktop is its home), so LinuxBox's Syncthing was paused instead (REST,
  03:21:45 UTC). LinuxBox's view `lag: true` by 03:24:51 (between 150 and 186 s); the desktop's `presence live` has LinuxBox's hub part
  `{"ext":"1.0.36","lag":true,"link":true,"sees":["James","James-Laptop","LinuxBox2"]}`; no hub lines anywhere; all views kept James. Resumed
  03:25:26: `lag` gone at 03:25:36. A4 (partial reach on top) not run; LinuxBox's Health wording not read.
- **B (four computers):**
  - **Fail: a 21 s hand-off with one miss.** While only LinuxBox couldn't reach the desktop (from 03:03:45), the desktop logged at 03:05:13
    "'Cross Test': James-Laptop is its hub now" and at 03:05:34 "you're the hub ..." (the laptop the same in reverse). `HOME_MISS` is 2 and
    `REACH_SETTLE` 30 s, so one miss shouldn't move it.
  - LinuxBox, cut off from the desktop, viewed `hub = James-Laptop, why = studio, studio = James-Laptop` from 03:07 while the other three said James.
  - Both VMs cut (03:12:59): 03:13:49 laptop "you're the hub for 'Cross Test' now", 03:13:52 desktop "'Cross Test': James-Laptop is its hub now"
    (50 s: 12 + 30 + the poll). All four views hub = James-Laptop, but `why = "kept"` (not "ranked"); `passed = 2` on the desktop and laptop, nil on
    the VMs; the **studio** hub split: James on the desktop and laptop, James-Laptop on LinuxBox and LinuxBox2 (they don't reach the owner's pick).
    Desktop Health: "this project: James-Laptop (holding it, James is the project's home but 2 here can't reach it directly)" (pass); LinuxBox2's:
    "this project: James-Laptop (holding it until James is back). The direct link lost James ...".
  - B3: no further hub lines for the 4 minutes I held it (03:13:52-03:17:44; not 10). B4 pass: undone 03:17:44, desktop "you're the hub" 03:18:20,
    laptop "James is its hub now", why = home everywhere, once. B5 pass: both VMs cut 03:19:48-03:20:11: no hub lines. B6 not run (laptop needed out).
- **C: not run.** Needs a project whose home is away (Cross Test's home is the desktop, and a guest's miss can't pass over the home). Note:
  LinuxBox2 and LinuxBox both start Live sync with "live sync for 'Cross Test' (guest, room main, driver James)", and LinuxBox then took the hub
  role in D, so that word isn't the guest role there (or a guest got a role).
- **D: pass.** `hub.hand_song` Cross Test -> LinuxBox (03:25:49), "you're the hub" on LinuxBox 03:25:51. LinuxBox's REAPER SIGTERM 03:26:09; the
  desktop named James (why = studio) by 03:26:23. Restarted, Live sync 03:26:47, "you're the hub" 03:27:32 (45 s), the desktop's view named LinuxBox
  by 03:27:35 (polled every ~2 s), never before. Handed back to James (hub/James.json keeps both transfers; views home = James).
- **E:** not run (live audio mix host; no sound this round).
- **F, non-audio:** hub block of `StudioSync_LiveAudioStatus` (deafened, the desktop mixing): LinuxBox `stalls` 113 (max 239 ms) two minutes after
  its restart, `mix_gap_ms` 197.3 then 25.2; LinuxBox2 `stalls` 3170 (max 758 ms), `fallbacks` 12, `rescues` 13, `join_fails` 21,
  `mix_gap_ms` 65.9 then 29.2. One 197 ms reading is above the "tens of ms" expectation (shortly after a start). The desktop-quit rescue and the 1 s
  outage tests not run (they need the mix running with sound as written).
