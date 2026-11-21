# The relay's two failing checks on the macOS runner (rt-macrelay, 2026-11-20)

NAT stage 3 (`docs/rt/rt-nat3.md`) passed on Windows and Linux, but on GitHub's macOS runner two checks in `tests/nat_test.cpp` failed:
"symmetric NATs with the hub's relay: they meet" (every time) and "fourth address refused (quota 3)" (once).

## Cause 1: macOS answers a loopback alias from the alias (test harness, not the product)
The test runs two simulated symmetric NATs on one computer by binding each one's libjuice sockets to its own loopback address
(127.0.0.2 and 127.0.0.3, aliases on macOS). The hub's relay listened on any address. libjuice's log on the runner showed:
- the TURN Allocate answers reached the clients, but **from 127.0.0.2:<relay port>** (and .3), not from 127.0.0.1, where the clients sent
  them. libjuice matches TURN answers by transaction, so allocations and permissions still worked;
- every relayed datagram (a Data indication from the relay) then came from 127.0.0.2:<relay port> too, and libjuice's agent drops those:
  `No STUN entry matching remote address, ignoring`. ICE's checks through the relay never got back, so the pair never met.

On macOS (BSD) a UDP socket bound to any address picks the reply's source from the route to the destination, and a loopback alias's
route is a host route whose address is the alias itself (`route -n get 127.0.0.2`: `flags: <UP,HOST,DONE,LOCAL>`). Linux and
Windows answer from 127.0.0.1. The test's own STUN server was already bound to 127.0.0.1, which is why its answers were fine.

**Fix:** the relay binds the test's address. `nat_test_only(h, only, bind)` (test-only, `NAT_STANDALONE`) already put a hub's links on
`bind`; `relay_tick` now gives the relay's libjuice server the same `bind_address` when it is set, and the test puts the relay hub on
127.0.0.1. The shipped relay is unchanged (no `bind`: it listens on any address). The check still proves the relay end to end on macOS:
the same relay code, credentials, caps and libjuice server, only its socket's address is fixed.

## Cause 2: the quota check
It failed in one run of six (44771924285). There the three gathers after the first took 15.2 s instead of milliseconds: one of the
second or third allocations waited out the helper's 15 s and never got its address (its result wasn't checked), so the "fourth" was
really the third, and the relay rightly granted it. The quota itself works: libjuice's log on the runner shows three allocations and
then `486 Allocation Quota Reached`, and it passed in every later Mac run, including 9 runs on a throwaway branch (3 at once, 3 rounds,
run 44777157274). The stall didn't recur, so its cause isn't known (a loaded runner losing every retransmission, or something in the
shared libjuice poll thread). **Fix:** the second and third allocations are now a check of their own ("its second and third address at
once too"), so if the stall comes back it fails under its real name instead of passing as a granted fourth.

## Then: the rate caps' checks (reached on the Mac for the first time)
With the pair meeting, the caps' checks after it ran on the Mac and "the rate to any one address" failed: the flood's 1000 datagrams
were paced with `sleep_ms(1)`, which runs ~9 ms on a hosted Mac, so the "1 MB in ~1 s" took ~9 s, and a 20 KB/s cap rightly let
~160 through against the check's fixed "under 150". **Fix:** the flood sends 10 datagrams every 10 ms (~1 s everywhere), times itself,
and the check allows what 20 KB/s lets through in the time it really took (plus the bucket's burst and 25%), and under half of the 1000.
JAMES-MAIN: 0 and 24 of 1000 in ~1.1 s.

## Seen in passing, not fixed
- "a message over 64 KB, over the link: refused (5) before it's read whole" (stage 2) failed once in those 9 Mac runs and once on
  JAMES-MAIN: the receiver answers 5 and closes while the test is still sending the 70 KB, so the reset can arrive before the answer
  byte is read. A test race, not this task's.

## Files
- `extension/nat.cpp`: `relay_tick` passes the hub's test `bind` to the relay (`sc.bind_address`). `extension/nat.h`: the comment.
- `tests/nat_test.cpp`: the relay hub on 127.0.0.1; the second and third allocations are checked themselves ("its second and third
  address at once too"), so a failed earlier allocation can't pass as a granted fourth.
- `.github/workflows/extension.yml`: no lasting change (libjuice's debug log on the Mac, diagnostics only, added and removed).

## Review later
- The shipped relay listens on any address. On a hub with more than one address on its route out (a secondary address, an alias, some
  VPNs), replies to a bandmate could leave from another address than the one the router forwards to, and the bandmate's libjuice would
  drop the relayed data exactly as on the Mac runner. Binding the relay to the address the router forwards to would avoid it; that needs
  knowing that address (a setting, or the default route's address) and isn't done.

# Second round: the hang, the relayed path again, direct_test's slow way, CI timeouts (2026-11-20, evening)

## 1. nat_test hung 50 minutes (run 44818861223, attempt 2): three deadlocks in nat.cpp, all real, all fixed
The test's own waits were all bounded already. What had no bound was a lock: libjuice (in its "poll" mode) runs every link on one thread,
and that thread holds libjuice's own lock while it calls back into nat.cpp. On the way it takes the link's lock (to open a datagram), the
signals' lock (a rendezvous message carried over a link) and the hub's lock (live audio's receiver asks `nat_up` for every datagram).
Any other thread that calls into libjuice while holding one of those waits for libjuice's lock, libjuice's thread waits for theirs, and
both stop for good. The next `StudioSync_NatStatus` (REAPER's main thread; in the test, the next `nat_hub_status`) then stops too, on
libjuice's lock. Three places did that:

| Where | Held | Called | Meets |
|---|---|---|---|
| `nat_link_tick`, when the peer's answer is read | the link's lock | `juice_set_remote_description`, `juice_gather_candidates` | a hello from the peer. The peer that answered checks our address before we've read its answer, libjuice answers those checks (RFC 8445 7.3), so the peer comes up first and says hello every 0.2 s. One that lands between "keys ready" and the call stops both threads. |
| `nat_hub_setup`, dropping a peer | the hub's and the signals' locks | `juice_destroy` (the dropped link was freed under them when the loop held no reference) | a carried rendezvous message, or live audio, on another link |
| the hub's loop making a link (`make_box`) | the hub's lock | `juice_create` + `juice_gather_candidates` | live audio arriving on another link |

The first is the CI hang: it needs no audio and no setup, only a link being made, and the run stopped exactly where three hubs start
making links to each other, with the main thread never returning from its next status call. It is rare there because the window is
microseconds wide. **Shown, not guessed:** with that window held open 300 ms in a scratch copy of the old code, nat_test stops at its
first hub link every time; the same wait with the fix passes. The third is the one most likely in the field (three or more computers
without Tailscale, audio flowing, a link to make or retry): against the old code the new test stops in the first of 40 rounds.

**Fixes (`extension/nat.cpp`):** the link's lock is let go before libjuice is told the peer's addresses; a setup moves the dropped links
out under the locks and frees them after; `make_box` only fills in the link's settings under the hub's lock and the caller makes the
link (`nat_link_new`) after letting go, then looks again whether the peer is still wanted (`still_peer`). No behaviour change otherwise.

**Tests (`tests/nat_test.cpp`, `lock_checks`):** "a hello that arrives before the peer's addresses are set" (the window held open with
the new test knob `nat_test_gap`), and "a setup adds and drops a peer 40 times while live audio arrives on another link" (a receiver that
asks `nat_up`, as rtaudio.cpp's does, under a flood). A stop fails the check and ends the run. Both fail against the old code.

**Every wait bounded:** nat_test now has a watchdog. After `NAT_TEST_TIMEOUT` seconds (600; a run takes 1-3 minutes) it prints the last
check made and every thread's stack (`sample` on macOS, `gdb` on Linux when it's there) and ends as failed. Tried on the runner with a
made-up hang (`NAT_TEST_HANG=1`): the stacks name the functions.

## 2. "the chosen path goes through the relay" (run 44832121855, attempt 1): the test let ICE find a direct path
Stage 1's relayed round ran both ends on 127.0.0.1. Only relayed candidates are published, but A also checks B's relayed address from
its own socket, and the relay lets that through: TURN permits by IP, and A's relayed address has the same IP as A's socket. B learns A's
real address from that check (a peer-reflexive candidate), checks it directly, and ICE moves to that direct pair moments after the link
comes up. The log shows it: the status printed just before the check still said `remote ... typ relay`, the check a line later found
`typ prflx`. Not a relay fault and not macOS: only timing decides whether the check looks before or after the move.
**Fix:** the relayed round puts each end on its own loopback address (127.0.0.2 / .3, as stage 3's pair), so the relay refuses the check
from A's own socket and the only pair that works is relayed address to relayed address. The check now asks that each end's own half of
the chosen pair is its relayed address. Without the aliases (a Mac that hasn't added them) the round still has to come up, and the path
check prints SKIP, as stage 3's does.

## 3. direct_test "a slow relayed way: the window is cut to the link" (44832121855 attempt 3, 44783155606)
Traced on the runner (a throwaway branch with the window's rounds printed, run 44841997505; 1 of 4 runs failed, the trace below is that
one): the window is cut as designed, 4 -> 2 in the first round, and stays 2 for five rounds. The last round of the pass then doubles it:

    w 4 -> 2, frames 0.52, 262144 bytes in 1.710 s, path round trip 0.221 s
    w 2 -> 2, frames 0.64 ... 0.59   (five rounds, 0.59-0.76 s each)
    w 2 -> 4, frames 1.52, 131072 bytes in 0.291 s

Both numbers in that last line are the test's own slow way on coarse timers, not the link code: the way sleeps after each read, so a
round of two frames takes 0.3 or 0.6 s by where the reads fall (fine timers show the same short round, 0.26 s), and the 120 ms round
trip is a sleep too, which measured 187-221 ms on the Mac (120 on JAMES-MAIN). A short round at 221 ms is 1.52 frames in flight, just
over the 1.5 that grows a window of 2; at 120 ms it is 0.91. The pass ends there, so the status shows 4.
**Fix (`tests/direct_test.cpp`):** on coarse timers (a 3 ms sleep over 6 ms, SS_TIMING_STRICT off) the slow relayed way gets up to 3
tries, as the windowed 8 MB check beside it already does; a window that is never cut fails every try. Fine timers and SS_TIMING_STRICT
get one try, as before. The line also prints the measured round trip now.
Also: `SS_TEST_PORT` picks another port than 47391 (another agent's stand-in server held it on JAMES-MAIN, so the test couldn't run
there), and the test's output is unbuffered, so a run that stops says where.

## 4. Timeouts in `.github/workflows/extension.yml`
`timeout-minutes` on the jobs (mac 45, linux 40, linux-ninjam 20; a job runs 10-15 minutes) and on every test step (10; nat_test 15,
its own watchdog ends it at 10 with the stacks). Additions only.

## Review later (nat.cpp, from reading its locks)
- A link's last reference can be let go on libjuice's own thread: `hub_signal_rx` holds one while it passes a message on, and `nat_up`
  (asked by live audio's receiver on that thread) holds one for an instant. If the hub drops that link at that moment, `juice_destroy`
  runs inside a libjuice callback. Not seen; it needs a link dropped within microseconds of a datagram for it.
- `loop_pair` (a stream's loopback socket pair) accepts with no time limit, on libjuice's thread, under the streams' lock.
- `nat_set_rx(h, nullptr)` waits without limit for a receiver call in flight.
