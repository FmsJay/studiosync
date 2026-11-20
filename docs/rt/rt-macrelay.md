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
