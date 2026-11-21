# rt-hubsmall: the hub's live mix and room lists after the first four-computer sound test

2026-11-21. Lua only in this commit (`lib/livex.lua`, `lib/liveaudio.lua`, `tests/test_0_60_rt_hubsmall.lua`). No extension release is
needed for these. Item 1's cause is in `extension/rtaudio.cpp`; the C++ change is written out below for the next extension release, and not
made here. **Tests use stand-ins only. Nothing was run in REAPER or between real computers apart from read-only probes.**

## 1. Why the hub's mix falls back and gets rescued

### What the probes showed

The probes were read-only (`hs2_probe.lua` and `hs2_log.lua` in the bandtest scratchpad). They ran on the desktop and LinuxBox at 08:57 UTC,
everyone deafened, the desktop mixing. I also read the status files on the desktop's disk and their Syncthing versions.

- **The desktop (the hub).** It mixes for 3, at load 1.7%. `skipped` is 0, so the ring never fell behind. `pauses` is 6 over about 4 hours
  (1.4 M callbacks), so its peer list hardly changed.
  - Its view of the three listeners' own streams:

    | Listener | Round trip | Buffer | Underruns |
    |---|---|---|---|
    | LinuxBox | 0.5 ms | 90 ms | 158, all jitter |
    | Laptop | 82 ms | 90 ms | 173, all jitter |
    | Mac | 132 ms | 100 ms | 15 |

- **LinuxBox.**
  - Hub block: `fallbacks 24, rescues 7, join_fails 3`, `mix_gap 25 ms`.
  - Its buffer for the desktop is 100 ms (the mix's sink follows it). That is 223 underruns, 147 of them jitter, at a 1.7 ms round trip.
  - **`overflows 29`**: AOO's send queue (100 ms, `SRC_BUFFER`) filled 29 times, so LinuxBox's send thread went 100 ms or more without
    running. `pauses` is 7.
- **The mix's host changed during the evening.** LinuxBox's log, and the status files' `lmix` / `song` history in `.stversions`, show this:
  - From 08:27 to 08:45 UTC the laptop was the song's hub and mixed. The desktop wasn't in anyone's `sees` then.
  - At 08:36 the laptop dropped out for a moment ("peer to peer"), when the Mac restarted (its `since` is 08:36:42).
  - At 08:45 the desktop arrived. It is the home, so it took over.
  - The extension's counters run for the whole session. So LinuxBox's 24 include the 18 minutes it listened to the laptop's mix over the
    laptop's Wi-Fi. The laptop's own counters (2 → 4 in a minute) are all from the desktop's mix, because before 08:45 the laptop was the hub.
- **Lua didn't flip anything during the test.** `hub_tick` logs every change of who mixes. LinuxBox's last such line is 08:45 ("James's
  computer mixes it"), and the desktop's is 01:46 MT ("you mix it"). Neither changed afterwards.
  - Each peer-list change is a `pause` in the extension, and there were 6-7 of those in 4 hours.
  - A Lua flip of the hub doesn't count as a fallback anyway: `hub_watch` sets state 0 without `++fallbacks` when `want_hub` changes.

### Reading the counters against the rules

- `gone = max(GONE_MIN 40, target_ms + GONE_PAD 20)` ms, and `rescue = max(RESCUE_MIN 10, target_ms - RESCUE_LEAD 20, mix_gap + 5)` ms.
  `hub_watch` runs on every pass of the send thread, which is at most 5 ms apart.
- When the mix stops, `quiet` passes the rescue line first (via goes false and `++rescues`), then the gone line (`++fallbacks`). The gap
  between the two lines is at least 40 ms here (LinuxBox: `target` 100, so 80 → 120 ms). **So a fallback without a rescue before it needs two
  passes of `hub_watch` more than 40 ms apart.**
- **LinuxBox: 24 fallbacks against 7 rescues.** At least 17 times its send thread didn't run for 40 ms or more at the moment it looked at the
  mix. The 29 overflows say the same, and so does its bursty stream at a sub-millisecond round trip. It's a VM, and the guest's threads are
  descheduled now and then.
  - When the guest is descheduled, the receive thread stops too. The mix's datagrams wait in the socket.
  - The send thread wakes and runs `hub_watch` before the receive thread has taken them. It sees `mix_at` 100+ ms old and falls back, though
    no datagram was lost.
  - That fallback costs 3.3 s on everyone's own streams (`RETRY_S` + `ENTER_S`). It also tells every sender 'M' = 0, then 1 again. That is
    the `switched` underruns: 81, 309 and 83 on LinuxBox.
  - The same happens after a reconfigure (`pause_audio` holds the send loop: `if (!live) continue`).
- **Laptop 2 → 4 and Mac 1 / 2: one rescue before each fallback.** These are real gaps longer than the mix's buffer + 20 ms, from their Wi-Fi.
  Falling back there is the rule working. The 3 of 30 reads at "direct" are those 3.3 s spells, and join_fails' 10 s waits.
- **'R' / 'M' / 'H' are not the cause.** The hub serves a listener while its 'R' (every `MODE_EVERY` 0.25 s) is under `MODE_FRESH` 1 s old.
  Losing that takes four 'R's in a row, a 0.75 s outage, which empties the mix's buffer anyway. 'M' and 'H' only decide who sends to whom
  directly. None of them moves the counters above.

### The C++ change (for the next extension release)

`extension/rtaudio.cpp`, `hub_watch`: **don't count time the send thread itself didn't run as the mix's silence.**

```cpp
// with the other constants
const double WATCH_LATE = 0.02; // s: a pass of hub_watch this late (the send loop wakes every 5 ms) means this thread didn't run meanwhile

// RtLink
double watch_at = 0, watch_free = -1e9; // (hub_watch's last pass; the last pass that came WATCH_LATE late)
long long stalls = 0; double stall_max = 0; // (status: such passes, and the longest, s)

// hub_watch, first lines
const double lag = now - l->watch_at;
l->watch_at = now;
if (lag > WATCH_LATE && lag < 10.0) { l->watch_free = now; ++l->stalls; l->stall_max = std::max(l->stall_max, lag); }

// in the `else` (h set): in place of `quiet = now - h->mix_at.load()`
const double raw = now - h->mix_at.load();
const double quiet = st == 2 ? std::min(raw, now - l->watch_free) : raw; // (hearing it: a late pass gives the receive thread its turn first)
```

Leave the rest as it is. `flowing` and `via` both use this `quiet`, so a late pass is neither a fallback nor a rescue. If the mix really
stopped, `quiet` grows from that pass and falls back `target + 20` ms later. Joining keeps the raw age, so a mix that never came can't look
like it's flowing.

Also add `,"stalls":%lld,"stall_max_ms":%.1f` to the status's hub block, so the next four-computer test can show it.

**Native test** for `tests/rtaudio_test.cpp`, the same shape as `rescue_test`:

- Add a hook `rt_test_hold_tx(l, ms)`: the send loop sleeps that long once, as `rt_test_hold` does for the receive loop.
- Three links, X listening through H, X's buffer for H at 30 ms (floor and ceiling).
- Five times, one second apart, hold X's receive and send threads together for 150 ms (`rt_test_hold` + `rt_test_hold_tx`). That is a VM
  descheduling the guest.
- Without the change: most holds are a fallback (150 > 50 ms gone), with no rescue before it. With it: `fallbacks` and `rescues` don't move,
  `stalls` is 5, and X stays "hub" throughout.
- The existing `rescue_test` (receive-thread holds only) and the hub-drop test (H really gone: one fallback) must pass unchanged.

**Not recommended yet:** keeping a Wi-Fi listener on the mix through its own outage (nothing arrived from anyone either, so the direct
streams wouldn't come). In hub mode the only other traffic is 'M' / 'I' / 'H' every 0.25 s, so it would sometimes delay a real hub drop by
up to a quarter of a second. Decide after a test with `stalls`, once the VM's share is out of the counters.

## 2. A status file rewritten every 2 s

- **Cause.** The status's `lrtt` (rt-sonox) is the mean of the extension's per-stream round trips, in tens of ms. With three bandmates whose
  round trips wander by tens of ms each second, that mean crossed a tens boundary on most passes.
  - Across the Syncthing versions (30 s apart), `lrtt` differs in 33-46 of about 130 consecutive pairs per computer. It's the most changed
    field after `free_mb`, and with `cpu`.
  - While the link reaches everyone, a change goes over the link alone (presence's quiet file). While it doesn't (the desktop and the Mac),
    every change rewrites the file, and that was every pass.
- **Fix (`livex.lrtt`).** The status says the round trip in tens, held until it has moved `RTT_STEP` (20 ms, the pick's own band) from what
  it says, and at most every `LRTT_FLOOR` = 10 s.
  - The mix host's pick ranks this computer by the same held value, so its own number is the one the others read.
  - Two minutes of jitter in the test: 41 moves before, at most 2 now. A real change (40 → 230 ms) is said within 10 s.
- **Not done (not my file):** a floor between file writes in `presence.status_due`. Today, without quiet, it writes on every fingerprint
  change. For example, at most one write per 5 s unless the hub part changed (elections read the files). `cpu` changes in tens every 20 s at
  most, and `free_mb` comes from lib/sync.lua.

## 3. A computer neither side lists

- **What the link already carries.** Every status here comes with whom its computer's direct link reaches now (`hub.sees`). That is the word
  lib/hub.lua already uses to vouch for a late computer.
- **Fix (`liveaudio.vouch_merge`, in Live sync's tick).** Take a computer whose status here is late but under `hub.VOUCH` (150 s), while a
  computer whose status is fresh here says its link reaches it.
  - It goes on the live audio list here, so this computer sends to it.
  - Its audio arrives there tagged, and rt-roomlist's `heard_merge` adds this computer in turn. Both hear each other until a status lands.
  - It comes off once nobody vouches.
- **Who can be added.** Only a studio computer trusted here (`liveaudio.peer_of_user`: its own devices file, written by its own computer,
  through `direct.studio_peer`, and for a guest, a list that has the song). A guest's word isn't counted. One whose status is fresh here is
  left to the room's own list.
- **Logged** once per computer: "live audio: X's status is late here, but Y's computer reaches it, so you send to it meanwhile".
- **What's still missing:** a room where nobody fresh reaches the late computer. Two computers alone, each late at the other, still wait for a
  status file or heartbeat. Nothing carries a word between them. Closing that needs a link-level hello to everyone in the studio's devices
  files, not only those present, which is a direct-link change.

## 4. A talkback-only sender

- **Cause.** Someone heard here before this room lists them (rt-roomlist) was dropped `HEARD_S` (15 s) after their last datagram. Talkback
  to someone else sends this computer nothing, so they dropped off while still in the room.
- **Fix (`heard_merge`'s `near`).** A computer once heard stays listed while its status here is under `hub.VOUCH` (late, not gone),
  silent or not. With no status here at all it's 15 s, as before.
  - Keeping it costs a stream to that computer meanwhile. If its room had dropped this one, that stream makes its `heard_merge` add this one
    back.

## 5. The mix host's `net` probe

- **Found on the desktop.** Ethernet and Wi-Fi both have a default route, both at RouteMetric 0. Windows routes over Ethernet because of the
  interface metric (25 against 30). The old probe sorted by RouteMetric alone, so it could name either. It happened to say 802.3 here.
- **Now (built-in tools only):**
  - **Windows:** `Find-NetRoute -RemoteIPAddress 1.1.1.1` (Windows' own choice, route plus interface metric, and nothing is sent), then that
    adapter's `PhysicalMediaType`. Through a VPN or exit node ("Unspecified"), the `-Physical` adapter with the lowest RouteMetric +
    InterfaceMetric. Checked on the desktop: "802.3".
  - **macOS:** `route -n get default` (the primary service's interface), then its hardware port. Through a utun, the first interface in
    `scutil --nwi`'s order that is a hardware port.
  - **Linux:** `ip -o route get 1.1.1.1` (the kernel's choice, metrics and policy rules included). Through tailscale / wg / tun, the
    lowest-metric default route that isn't one. Wireless if `/sys/class/net/<dev>/wireless` or `phy80211` exists.
  - **Fallback:** not known (nil). It ranks as not wired, and Health says "network not known".
- **Limits:**
  - A Hyper-V or bridge adapter in front of the real NIC reads as not known on Windows, and as wired on Linux.
  - iPhone USB tethering still reads as wired on macOS.
  - The route to a public address stands in for the route to the peers (for a peer on the same LAN, Tailscale's direct path normally uses
    the same interface).
- **Tests:** the commands' shape everywhere. On Mac and Linux CI, the shell part also runs against stand-in `ip`, `route`, `networksetup`
  and `scutil`: both up, Wi-Fi in use, exit node, and VPN.

## 6. Settling for reach: 4 s and 30 s

- **They should match for reach.** A computer missed by one more bandmate comes from `sees`, and a link that drops for a moment takes a name
  out of it for `LINK_GONE` s. That is the same for the song's hub and the mix's host. With 4 s, a 16 s drop handed the mix over and back.
- **Fix:** `livex.mix_pick` says why "reach" when the move is only about being reached by more, and `mix_decide` then waits
  `hub.REACH_SETTLE` (30 s). Wired against Wi-Fi, 20 ms less round trip, or busy keep `SETTLE` (4 s). Those come from values that change
  seldom (`net` every 5 min, `lrtt` now held), so 4 s only covers statuses arriving at different moments.
- rt-hubrank's rule and tests are unchanged. What decides a song's home, and ranking the home by reach, are untouched.

## Tests

`tests/test_0_60_rt_hubsmall.lua`. Each part fails with its fix taken out (checked one by one):

- 2: `lrtt` moved 41 times in two minutes before, now at most 2.
- 3: `vouch_merge` cases, `peer_of_user`, and the tick end to end: the list handed to the extension gains the Mac while Desk vouches and
  loses it after.
- 4: `heard_merge` keeps a silent near sender, and the tick end to end over a minute.
- 5: the commands, plus the shell part on POSIX.
- 6: no move at `SETTLE`, a move at `REACH_SETTLE`, a break restarts the count, wired still at `SETTLE`.

`test_0_60_rt_sonox`, `_hubrank`, `_roomlist`, `_hubmix`, `_hubfix`, `_hubfix_elect` and `_hub` pass unchanged.

## Checks on the four computers (after this Lua reaches them; item 1's after the extension release)

1. **Item 1, after the release:** the same sound test.
   - The hub block on LinuxBox now has `stalls`. Its `fallbacks` stop growing while `stalls` grows.
   - On the laptop and the Mac, each fallback still has a rescue before it (their Wi-Fi). If those stay frequent, that's the "not
     recommended yet" change above.
   - Note the counters before and after, since they run for the whole session.
2. **Item 2:** on the desktop while it can't reach someone, the status file's mtime (`stat` on
   `Cross Test/rooms/main/status/James.json`) changes about every 15 s, not every 2 s. The `lrtt` in it moves seldom.
3. **Item 3:** make the desktop and the laptop each go late at the other, while LinuxBox reaches both:
   - Block only the direct link's TCP between those two (port 47281, one firewall rule for the other's address, as in rt-hubrank's check 2),
     so no heartbeat gets through. Leave UDP open.
   - Pause Syncthing on the laptop.
   - After about 45 s, the desktop's log says "James-Laptop's status is late here, but LinuxBox's computer reaches it" (and the laptop's
     the same about James).
   - Both hear each other within a second or two (`la_peers.lua` on the desktop lists the laptop).
   - Undo both afterwards.
4. **Item 4:** in a room of three, with the laptop's status late on the desktop, the laptop holds Talk to LinuxBox for a minute. The desktop's
   live audio list keeps the laptop (`la_peers.lua`), and the laptop's next word to everyone is heard at once.
5. **Item 5:** the desktop's status says `"net": "wired"`. Unplug Ethernet with Wi-Fi up: within 5 minutes it says `"wifi"`.
6. **Item 6:** with shared CPU on, block one link for 20 s. The mix's host doesn't move. For 60 s: it moves once, about 42 s in.

## Check results (rt-r0, 2026-11-21, 0.59.49.92 + extension 1.0.34)

- 1: see rt-hubwatch's results (the counter is there; LinuxBox 31 stalls, others 0; no sound test run).
- **2: pass.** The desktop's `Cross Test/rooms/main/status/James.json` was rewritten at 15:41:28, 15:41:58, 15:42:28, 15:42:59 MT (every
  ~30 s, not 2 s) with the Mac away; `lrtt` 40 in it.
- 3, 4, 6: not run: they need the direct link blocked between two computers, a firewall change not allowed on the desktop or laptop (the
  LinuxBox `iptables` way needs James's OK for that kind of change).
- **5: half.** The desktop's status says `"net": "wired"`, the laptop's `"wifi"`, LinuxBox's `"wired"`. The unplug half not run.

## Review later (security)

- **Vouching (3)** goes by another member's `sees`. A member could name a computer whose status is late to make the others send it live
  audio for up to 150 s. The receiver is a studio computer trusted here (its own devices file, a guest only with the song), so nothing reaches
  anyone outside the studio. A guest's word isn't counted.
- **Keeping a near sender (4)** uses the status age only. A member that stops writing its status is dropped after 150 s at most.
- The network probe runs built-in system commands only, with fixed text (no names or paths from statuses).
- `lrtt` is still self-reported, as rt-sonox listed.
