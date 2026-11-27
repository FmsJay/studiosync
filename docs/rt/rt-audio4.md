# rt-audio4: the live-audio redesign rt-audio3 recommended (2026-11-27)

From rt-audio3's "Recommendations" 1-21, its rt-r5/r6/r7 results and the Mac CI `vm` note, rt-ears, rt-hubrank, rt-hubsmall and
rt-hubwatch, and the code (`extension/rtaudio.cpp`, `webui.cpp`'s guest ring, `lib/liveaudio.lua`, `lib/hub.lua`, `lib/livex.lua`,
`tests/rtaudio_test.cpp`, the vendored AOO). **Offline builds and tests only: nothing ran in REAPER, on the test computers or in the
VMs.** Source only: `EXT_VERSION` and `tools.EXT_WANT` are not bumped, no binary committed, nothing pushed.

The design comes first (what, why, the protocol and version changes, the controller, the test plan, the phases). What was built,
the commits, the re-check with numbers and the ranked recommendations follow at the end.

## 1. What is wrong today, in one paragraph each

- **The hub mixes.** A listener through the hub hears one stream that the hub decoded, mixed on its send thread and encoded again, on
  the hub's own device clock. Whatever the hub's computer does is every listener's sound: a 1.1 s host stall (r13), a live-audio
  restart, a device that drops ticks (the desktop's Voicemeeter WASAPI). A listener can't tell a 150 ms hiccup from a dead hub, so about
  400 lines of `rtaudio.cpp` (`GONE_*`, `RESCUE_*`, `RETRY_S`, `ENTER_S`, `own_outage`, `gap_learn`, `WATCH_LATE`) guess at it, and each
  wrong guess is 3.3 s on direct streams for everyone.
- **The hub is elected by each computer alone.** `lib/hub.lua` elects from status gossip that reaches each computer at a different
  moment; it has been patched five times (hubfix, hubrank, p9, fix7, audio3: `VOUCH`, `HOLD`, `lag`, `blind`, `NO_LA`), and two computers
  can still name different hubs for seconds.
- **The receive side bends AOO.** The read rate reaches AOO by shifting the timestamps handed to each sink (`toff` grows without bound;
  AOO's pings and timeouts run on that bent clock); the fill is re-derived from AOO's private capacity formula (`fill_of`); a shed is
  `reportXRun` plus a crossfade; a resize re-buffers. A lone hold of the link is always a gap.
- **The controller exists five times** (`rtaudio.cpp` adapt, `webui.cpp` GPace, three `ssPace` copies), already different.
- **The native test runs in real time**: ~9 minutes, real sockets and threads, 20 `check_unless_stalled` sites, and it flakes under
  load (the Mac CI's `vm` race).
- **The send thread looks names up itself** (`make_slot` -> `getaddrinfo`, retried every 5 s), and the status is built under two locks
  the receive thread also takes for every datagram.

## 2. Architecture after the change

```
           sender X                         relay R (lease holder)                    listener L
  Talk/Play AOO sources                                                      one sink per sender and stream
  (one encode per block)                                                     (Talk, Play), as peer to peer
        |   direct, as today, to every peer that hears X directly            ^      ^
        +------------------------------------------------------------------>+      |
        |                                                                           |
        +--> R's own sink for X (R hears X like any peer) --+ forward, bytes        |
                                                             +-- untouched ------->+  "SSF1" + X's address
                                                                (one HMAC, n sends)     + AOO message + tag
```

- **Every listener mixes locally, always.** Each listener keeps one AOO sink per sender and stream (Talk, Play), exactly as peer to
  peer. A sender's packets reach it directly, or forwarded by the relay, or both at once: the receive side merges the two copies into
  one stream (section 3.3), so switching paths is never a re-buffer and a duplicate costs nothing.
- **The relay forwards, it doesn't mix.** No decode, mix or encode for others; no second device clock in anyone's path. Forwarding is a
  memcpy, one HMAC per received packet (the envelope is the same for every listener) and one `sendto` per listener. A relay hiccup is
  jitter in each sender's buffer at the listener, which the buffers already absorb; a longer one asks the senders for direct streams
  (the merge makes that overlap free) instead of a 3.3 s fallback.
- **Upstream stays one stream per person** where it matters: in a large room each sender sends one copy to the relay (as to the mixing
  hub today) and the listeners tell it, with the existing `'M'`, not to send to them directly.
- **The relay also fills missing direct paths in any room** (the case rt-hubrank, p9 and fix7 kept patching): a listener that gets
  nothing directly from a sender the relay hears asks the relay for that one sender, whatever the room's size.
- **The relay role is a lease** (section 3.4): one computer holds it and renews it over the live-audio socket every 0.5 s; nobody else
  claims while it is valid; conflicts resolve by term, then address, the same on every computer. Lua only says whether the room uses a
  relay and in which order computers are preferred (the song's hub first, as today).
- The mixing hub stays in the extension **only for rooms with a 1.0.40 computer in them** (the version gate, section 4), and goes in
  the release after every computer has the relay.

### Bandwidth (4-6 members, Opus at 128 kbit/s, 5 ms frames)

On the wire a 5 ms Opus packet of 80 bytes carries AOO's binary header (~16), our tag (20), UDP/IP (28) and Tailscale's WireGuard (~60):
about 230 bytes, 200 times a second, **~365 kbit/s per stream** (10 ms frames: ~250).

| 6 members, every Talk and Play sounding (12 streams) | each member up | each member down | the hub/relay up |
|---|---|---|---|
| peer to peer | 10 x 365 = 3.65 Mbit/s | 3.65 | (none) |
| mixing hub (today, from 4 people) | 0.73 | 0.37 | 5 x 365 = 1.8 |
| forwarding relay, everything | 0.73 | 3.65 | 50 x 365 = 18 |
| forwarding relay as built: only what each listener wants, 4 streams actually sounding | 0.73 | ~1.1 | ~16 x 365 = 5.8 |

A pure forwarder concentrates the fan-out on one uplink; that is the price of taking the hub's clock and codec out of everyone's path.
It stays sane because:
1. **Only what each listener wants is forwarded**: a bandmate a listener has muted or at volume 0 isn't (its `'F'` lists Talk and
   Play apart, from the cue mix); a sender's Talk isn't forwarded to anyone its talkback leaves out.
2. **Relay-everything is for large rooms only** (today's threshold: from 4 people, two of them sending, held as `hub_n` holds it now);
   below it the room is peer to peer and the relay carries only the pairs that have no direct path.
3. **The lease order prefers the song's hub, then wired computers** (`net` in the status), so the fan-out lands on the best uplink.
4. Measured, not guessed: the relay's status says `fwd_kbps` and Health shows it.
5. Recommended next (not built): 10 ms frames in relay-everything rooms (-33 % on the wire, +5 ms), and a sender-side pause of a muted
   Talk after a few seconds (a muted computer sends zeros at the full packet rate today).

## 3. Protocol and code changes

### 3.1 Datagrams (all tagged with the studio key as today; anything malformed is dropped)
- `"SSF1"` + sender address (4 bytes IPv4 + 2 port, as `'H'` carries them) + the AOO message + tag: a forwarded packet (relay ->
  listener), or a listener's sink-to-source message for a relayed sender (listener -> relay; the relay answers a start request from its
  cache and drops the rest: no resend through the relay).
- Control kinds in `"SSX1"`: **`'L'` lease** (holder -> everyone, every 0.5 s): term (u32), ttl ms (u16), flags (1: handing over),
  [the next holder's address]. **`'F'` forward request** (listener -> holder, every 0.25 s and on change): n, n x (address + want bits:
  1 Talk, 2 Play), m, m x address (who must not get *my* Talk: talkback). `'H'` (whom the holder hears) is reused. An older extension
  ignores `'L'`, `'F'` and `"SSF1"` (unknown kinds are dropped today).

### 3.2 The relay (the lease holder)
- A tagged AOO datagram from X for its own sink or Play sink for X is handled as today, and then, if it is a data, `/start` or `/stop`
  message (never pings), copied once into an `"SSF1"` envelope, tagged once and sent to every listener whose fresh `'F'` wants that
  stream of X, X excluded, X's talkback respected. The last `/start` per sender and stream is kept and sent to a listener when it first
  wants that stream, and again when its sink asks.
- Its own Talk and Play go directly to everyone (listeners never tell the holder `'M'` = 1).

### 3.3 The listener: one stream whichever way it comes (the merge)
AOO gives each (source, sink) pair its own stream id, but the sequence numbers are the source's (one encode per block): the copy X sends
the relay and the copy X sends L carry the same `seq` for the same frame. So per sender and stream the receive side keeps the stream
id the sink knows (`acc`) and the other ids seen for the same stream (aliases): a `/start` whose `seq_start` is within 2 s of what is
playing and whose format id matches is an alias (dropped, nothing restarts); a data message with an alias id gets `acc` written into it
(4 bytes, big-endian, right after AOO's binary header); a `/stop` is passed only when no other copy delivered in the last 0.2 s. AOO's
jitter buffer drops the second copy of a frame. A genuinely new stream (a restart: `seq_start` far off, or a new format) replaces `acc`.

Per sender X (not the holder, not me), with the relay on and a valid lease held by someone else:
- **relayed(X)** = the holder hears X (its `'H'`) and (the room relays everything, or nothing came from X directly for 1.5 s).
- `'F'` asks for the relayed set (Talk and Play apart, from the cue mix).
- **`'M'` to X** = 1 only in a relay-everything room, once X's forwarded copy has flowed 0.3 s and while it keeps coming (no copy for
  `max(40 ms, buffer - 20 ms)`: `'M'` = 0 at once, X sends directly again, and the two copies overlap harmlessly until the relay is
  steady again). In a missing-path room `'M'` stays 0, so a path that comes back is noticed and used.
- No fallback state, no `ENTER/RETRY/JOIN` waits, no own-outage guess: a relay that stops is a sender buffer running on what it has
  while the direct copies come back.

### 3.4 The lease
- **Holder:** sends `'L'` (term, ttl 2 s) to every peer every 0.5 s. Valid at a computer until its last `'L'` + ttl.
- **Claim:** with no valid lease, the computer ranked `r` among those it hears in its order claims `r x 0.3 s` after the lease ran out
  (`term + 1`). Order comes from Lua (the song's hub, or the shared-CPU pick, first).
- **Conflict:** a higher term wins; equal terms, the lower address wins. Order-independent, so computers that disagree on the order
  still end with one holder among those that hear each other; a holder that hears a winning lease yields at once.
- **Handover:** only the holder moves the role: when a computer ranked before it has been heard for 5 s, it sends `'L'` with the
  handing-over flag and that computer claims at once with `term + 1`. A preferred computer coming back gets the role 5 s later, once.
- **Partition:** two holders can exist only where they can't hear each other; a listener that hears both follows the higher term; when
  they hear each other again the lower yields. Nothing reads status files or Syncthing: `lag`, `blind`, `HOLD`, `VOUCH` don't apply.

### 3.5 Lua (additive, apart from rt-setup's talk-mic code)
- `liveaudio.can_relay()`; the status's `lrelay = true` (two additive lines in `StudioSync - Live sync.lua`, beside `lhub`).
- `liveaudio.relay_plan(o)` (pure): the relay is on only when every computer in the room says `lrelay`; `all` from the same room size and
  senders rule `hub_plan` uses today; the order: the song's hub (or livex's shared-CPU pick), then wired computers, then by name.
- `liveaudio.hub_tick` calls `StudioSync_LiveAudioRelay(json)` when the gate is open (and `StudioSync_LiveAudioHub("", 0)`), else
  exactly what it calls today. Health: the holder, the term, `fwd_kbps`.
- `lib/hub.lua` is untouched: its song hub still keeps the restore points; the lease decides only who relays live audio.

## 4. Versions and compatibility (an explicit gate)

- The relay is used only when **every** computer in the room's live audio has it (`lrelay` in its status). One 1.0.40 computer in the
  room: the room runs **exactly what it runs today** (the elected song hub mixes from 4 people; peer to peer below), because the new
  extension keeps `StudioSync_LiveAudioHub` and its mix unchanged.
- What a 1.0.40 computer sees: nothing new. It never gets an `'L'`, `'F'` or `"SSF1"` it would act on (it drops unknown kinds), and
  nobody turns the relay on while it is in the room. If it joins a room that relays, the next Lua tick (1 s) closes the gate: everyone's
  extension gets `on = 0` and the old path resumes (listeners hear direct streams meanwhile, as in a fallback).
- What a new computer sees in an old room: today's behaviour. In an all-new room: the relay.
- The release after every computer has the relay deletes the mix (`hub_serve`, the `'R'`/`'I'` handling, `hub_watch`'s mix states,
  `msink`/`msrc`, `hring`): about 600 lines.

## 5. One controller, and the receive side

- **`extension/pace.h`**: the read-rate control of `adapt` (R + P, the slow and fast loops, the jump rule, the settle, the sanity
  bound, the underrun rules) as one self-contained struct per stream, with its inputs explicit: a look (level as a time, the newest
  packet's age, the buffer's size), a re-buffer, an underrun, a stop. `rtaudio.cpp` holds three per bandmate and is otherwise unchanged:
  with the simulated clock the suite's numbers must be identical before and after the move.
- **The web side**: `webui.cpp`'s guest ring and the three `ssPace` copies use a lighter law today (no fast loop, no settle). One law
  means giving them the full one; the JS copy is then **tested to match**: a native program runs fixed traces through `pace.h` and
  writes the rates, a Node test runs the same traces through the JS and must agree to 1e-9 (as `test_0_60_rt_p11.lua` already keeps the
  three JS copies equal by text). Kept as a text copy until ES module imports in AudioWorklet are checked on the Mac's Safari.
- **The receive side, small first:** a ~40-line patch to the vendored AOO sink: `kAooCtlSetResampleRatio` (read at a ratio, not at a bent
  clock: `toff` goes) and the fill in samples (frames buffered plus the resampler's: `fill_of`'s capacity formula goes). It does not
  bridge a hold.
- **The receive side, right (not built here):** our own jitter buffer in front of libopus, NetEq style: target delay from the histogram of
  waits between datagrams (rec 13: known from the first minute, kept through a quiet one), Opus PLC for the first 60-100 ms of a hold,
  then WSOLA time-stretch over pitch periods while it lasts and a faster play-in after it (rec 12: a lone hold is a soft patch, not a
  gap; the pitch never moves), resampling only for the clock ratio, resizes as a moved setpoint (rec 6). AOO would stay for the sender, or
  go (its packet format is the only thing the ends share).
- **Rust for that component?** It would suit it: self-contained (packets in, blocks out, a C ABI of four functions), pure DSP and data
  structures with no REAPER or OS calls, and it parses bytes from the network at a trust boundary, where Rust's bounds checks and
  `cargo fuzz` earn their keep. Against it: a second toolchain on Windows, both Macs and two Linux targets in CI, cross builds for
  universal and aarch64, and debugging across the boundary. My view: worth it for the jitter buffer alone if James accepts the
  toolchain; the rest of the extension stays C++.

## 6. Tests: a simulated clock and network (rec 2)

- `rt_sim(1)` (tests only, before any `rt_start`): no threads, no sockets. `now_s()` is the simulated clock; datagrams go into an
  in-memory network keyed by port with scripted delay, jitter, loss and blocked paths (`rt_sim_net`); `rt_sim_run(t)` advances the clock,
  delivers what is due (a held receive thread gets its backlog at once when the hold ends, as from a socket) and runs each link's send
  pass every 5 ms and whenever it was woken, as the threads would. `rt_sim_freeze(t)` jumps the clock with nothing running: a process stall.
- The test's clock (`tclock`) is the simulated one unless `SS_RT_REAL=1` (the old real-time run, kept to check the model against).
- Deterministic: the same numbers every run (AOO's round-trip pings still read the wall clock: status only, nothing decides on them).
  Fast: the suite in about a minute instead of nine; no `check_unless_stalled` excuse can fire in the model.
- New tests: the relay (forwarding, the merge, a stalled relay costs no fallback, a missing path filled, talkback and the cue mix
  respected, the relay's bandwidth), the lease (one holder, takeover after expiry, handover to the preferred, partition and heal,
  conflicting orders), the version gate in Lua, the controller's move (identical numbers), the resolver thread, the control ring.

## 7. Phases (each a commit with tests that fail without it)

| # | What | Files |
|---|---|---|
| 1 | The simulated clock and network; the suite moved onto it | `extension/rtaudio.cpp`, `rtaudio.h`, `tests/rtaudio_test.cpp` |
| 2 | The relay and the lease (C++), the version gate and order (Lua) | `extension/rtaudio.cpp`, `rtaudio.h`, `tests/rtaudio_test.cpp`, `lib/liveaudio.lua`, `StudioSync - Live sync.lua` (2 lines), `tests/test_0_60_rt_audio4.lua` |
| 3 | `pace.h`; the web side matched | `extension/pace.h`, `rtaudio.cpp`, `webui.cpp`, `lib/webui/*.js`, tests |
| 4 | Names resolved off the send thread; the status outside the receive path's lock; the control's last minute in a ring | `extension/rtaudio.cpp`, `rtaudio.h`, tests |
| 5 | The AOO patch (ratio, fill in samples); then our own jitter buffer | `extension/third_party/aoo/...`, `rtaudio.cpp` |
