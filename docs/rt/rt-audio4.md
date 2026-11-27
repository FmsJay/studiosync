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
id the sink knows (`acc`, from a `/start` or from the data it plays) and the other ids of the same stream (aliases): an id whose *data*
carries on from `acc`'s sequence (within 800 blocks, 4 s) is an alias, and its data gets `acc` written into it (4 bytes, big-endian, right
after AOO's binary header). A `/start` for another id while `acc` plays is held and decided on that id's first data: carrying on, an
alias (the `/start` dropped, nothing restarts); not, a new stream (a restart: the held `/start` goes in first, then its data). An alias's
`/stop` is dropped; `acc`'s passes only when no alias delivered in the last 0.2 s. AOO's jitter buffer drops the second copy of a frame.
(First built on the `/start`'s `seq_start`; a kept `/start` from minutes ago carries a stale one, so the data decides.)

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
  A holder never hands the role back to the computer it got it from within 60 s, so two computers whose orders disagree can't ping-pong.
- **Partition:** two holders can exist only where they can't hear each other; a listener that hears both follows the higher term; when
  they hear each other again the lower yields. Nothing reads status files or Syncthing: `lag`, `blind`, `HOLD`, `VOUCH` don't apply.

### 3.5 Lua (additive, apart from rt-setup's talk-mic code)
- As built, a module of its own, `lib/liverelay.lua` (rt-setup was editing `lib/liveaudio.lua`): `can()`, `mine()` (the status's
  `lrelay = true`, two additive lines in `StudioSync - Live sync.lua` beside `lhub`), `gate` (pure: "yes" when every computer on the
  live-audio list says `lrelay`, "no" when one's status doesn't, "wait" when one has no status here yet), `held` (on after `SETTLE` 10 s of
  yes, off at once on a no, a wait keeps what it was), `order`, `json`, `tick` (tells the extension on a change only, and logs it), `text`
  (Health).
- `all` is `hub_plan`'s own answer: the room is big enough and two or more send (it would have mixed). The order: the song's hub (or
  livex's shared-CPU pick), then wired computers, then by name.
- `liveaudio.hub_tick` (3 additive lines) calls `liverelay.tick`; when it returns true, hub_tick asks the extension for no mix
  (`StudioSync_LiveAudioHub("", 0)`), else exactly what it called before. `liveaudio.health_text` (1 line): the relay's holder, what it
  forwards and how many bandmates come through it.
- `lib/hub.lua` is untouched: its song hub still keeps the restore points; the lease decides only who relays live audio.

## 4. Versions and compatibility (an explicit gate)

- The relay is used only when **every** computer in the room's live audio has it (`lrelay` in its status), for 10 s. One 1.0.40
  computer in the room: the room runs **exactly what it runs today** (the elected song hub mixes from 4 people; peer to peer below),
  because the new extension keeps `StudioSync_LiveAudioHub` and its mix unchanged.
- What a 1.0.40 computer sees: nothing new. It gets `'L'` leases (it drops unknown control kinds silently, as today), never an `'F'` or
  an `"SSF1"` (nobody asks it, and the relay forwards only to those that ask), and nobody turns the relay on once its status is read.
  If it joins a room that relays, the next Lua tick after its status is read (1 s) closes the gate: everyone's extension gets `on = 0`
  and the old path resumes (listeners hear direct streams meanwhile, as in a fallback). Until its status is read it is sent everything
  directly (it never says `'M'` 1), and it hears everyone directly (relay_test 9).
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

## 8. What was built (phases 1-4; phase 5 is design only)

| Phase | Commit | What | Tests (each fails without it) |
|---|---|---|---|
| 1 | 75d9039 | `rt_sim`: the simulated clock and network (no threads, no sockets; delay, jitter, loss, blocked paths, held threads, a frozen process); the native suite on it unless `SS_RT_REAL=1` | the whole suite in **8-12 s** instead of ~9 minutes, the same numbers every run (only AOO's wall-clock round trip in a status differs); `sim_test`: the same sound twice to the sample, a path's delay heard, a blocked path silent |
| 2 | f83a6de | the relay (forwarding, the merge, `'F'`, `'M'`), the lease (`'L'`), `StudioSync_LiveAudioRelay`; `lib/liverelay.lua` (gate, order, tick, Health); hooks in `liveaudio.lua` and Live sync's status | `relay_test`, 18 checks (below); `test_0_60_rt_audio4.lua` (fails with HEAD's `liveaudio.lua`) |
| 3 | 62a5661 | `extension/pace.h`: the read-rate control as one struct per stream (moved, not changed); the guests' light law there too (`pace::Lite`, `webui.cpp`'s copy gone); `tests/fixtures/pace_lite.json` | the simulated suite's 235 result lines **identical** before and after the move; `pace_lite_test` (C++) and `tests/pace_lite_check.py` (the worklet's own `ssPace` in Node, in `tests/run.py`): the golden trace's 200 rates to the bit; `webui_test`: all ok |
| 4 | 1081316 | names looked up by a resolver thread (in the model: finished when due); the tag checked before `cfg_mx`; `rt_status` under `stats_mx` alone; the control's last minute (160 windows and events per stream) and `StudioSync_LiveAudioTrace(peer)` | `lookup_test` (a 2 s lookup: B hears A whole meanwhile, the status says "looking up its name", C once the name has come); `trace_test` (windows and the underrun in the dump). Also fixed: the hub test stopped H from a second real thread, which raced the model (a crash about one run in four) |
| finish | this file's commit | the gate held (on after 10 s of everyone relaying, off at once on an older computer, a late status changes nothing); `'M'` 1 only when every stream asked for flows through the relay | `test_0_60_rt_audio4.lua` parts 1 and 3 (the hold); `relay_test` unchanged |

**`relay_test`, on the simulated network (4 computers, 60 ms buffers):**

| Case | Result |
|---|---|
| Lease | one holder, the first in the order (term 1); the others follow it |
| Forwarding | A hears B through the relay at the level B sent (0.354 rms, quietest 10 ms 0.349); B sends **218 datagrams/s** (one copy; peer to peer it was three); H forwards 1203 packets/s (838 kbit/s) to the three that ask |
| The relay stalls 150 ms, three times | A's longest gap in B **25 ms** (concealed), **no re-buffer**, everything through the relay again once it's steady. With the merge taken out: 85 ms. Through the hub's mix the same stall was a fallback (everyone's streams anew, each a re-buffer, 3.3 s on direct streams) |
| The holder goes | the next in the order holds (term 2) within the lease's 2 s; A's longest gap 20 ms, no re-buffer; C now gets B through A |
| The holder comes back | handed back to it once (handovers 1), 5 s after it's heard |
| Talkback B -> C only | A hears nothing of B, H doesn't play it (it only forwards), C hears it through the relay |
| A mutes B | the relay stops forwarding B to A: 1203 -> 1002 packets/s |
| B can't reach A (room below the threshold) | A asks the relay for B alone and hears it (0.353 rms); the path back: B's own stream again, **no gap** (70 ms with the merge taken out) |
| A partition (two that each put themselves first) | two holders while apart, one at once when they hear each other (the lower address; yields 1) |
| A computer with the relay off (as a 1.0.40) | sent everything directly, hears B at 0.353 rms, takes no forwarded copy |

Whole native suite at the end: **191 checks, fails 0**, about 12 s, 15 runs out of 15 with no crash; `SS_RT_REAL=1 rtaudio_test stalls`,
`outage`, `nothere`, `startorder`: all ok in real time. `extension\build_windows.cmd` with `DLL_OUT` in scratch: built (4,075,520
bytes), the tracked DLL untouched. `python tests/run.py --no-luals` in a clean clone: in the report.

## 9. Left, untested, limits

- **Nothing ran in REAPER or over a real network.** The relay, the lease and the merge are proven on the model only.
- **The model's links are near-instant (0.1 ms).** What a relay stall costs is what the sender sent the relay before a listener noticed
  (the rescue line: 40 ms, or the buffer less 20 ms) **plus one round trip** listener -> sender -> listener for the direct copy to come.
  On the laptop's 80-200 ms link a 150 ms relay stall would cost about as much as the stall itself, still with no re-buffer and no
  fallback state; its buffer for such a link is 110-400 ms, which covers most of it.
- **The relay's uplink** (section 2's table) is estimated, not measured; `fwd_kbps` in its status is the measurement to take.
- **The mix stays** for rooms with a 1.0.40 computer; its deletion (about 600 lines) is for the release after everyone has the relay.
- A sender whose Talk the relay won't forward (no talkback list from it: an older computer) keeps sending it directly; tested for Talk
  alone (`relay_test` 9), not with a Play stream beside it.
- The gate reads statuses: an older computer whose status hasn't come yet counts as "wait" (the relay stays as it was) for as long as
  that lasts; it hears everyone directly meanwhile.
- Lua's order puts the song's hub first, then wired computers. Two computers that disagree on the order still end with one holder (term,
  then address), maybe the less preferred one until it hands over.
- The listener learns whom the relay hears from the mix's `'H'`, reused; a relay that doesn't hear a sender carries nothing for it.
- **Not built: phase 5.** The small AOO patch (read at a ratio instead of bent timestamps, the fill in samples) is a cleanup and doesn't
  bridge a hold; our own jitter buffer with PLC and WSOLA is the real fix (recommendation 1). The web pages still run the light law
  (their copy is now pinned to the C++ one, not to the full law).
- `lib/files.txt` doesn't list `lib/liverelay.lua` yet (the release regenerates it; `tools/files_check.py` fails only with `--release`).
- The pages' check needs Node (as `tools/js_check.py`); without it, it says so and passes.

## 10. REAPER re-check (needs the extension after 1.0.40 on every computer, and this Lua)

Setup as rt-r7 (its `tools/ears` rig); Deafen back to 1 and no other live-audio keys after every run. Read `StudioSync_LiveAudioStatus`'s
`relay` block and each peer's `relayed`, `fwd_ago`.

1. **The gate, mixed.** With a 1.0.40 computer in the room (the Mac, or one REAPER not restarted): every computer's `relay.on` false,
   `claims` 0; the log has no relay line, or one "the room's relay is off"; the mix behaves as in rt-r6 step 5 (59-60 s to switch).
2. **The gate, all new** (desktop, laptop, LinuxBox; `live_hub` 3 for the test as rt-r6 did; two sending): within 70 s of the second
   sender (`HUB_SETTLE` 60 + `SETTLE` 10) every log says "through the room's relay"; `relay.holder` names the same computer everywhere
   ("me" on it), `term` the same, `claims` 1 on it and 0 elsewhere; on the holder `asking` 2; on listeners `relayed` = the other
   senders, their `fwd_ago` under 0.1. Ten minutes on: `claims`, `yields`, `handovers` unchanged everywhere.
3. **Through the relay, by ear** (the desktop sends; the holder another computer: hand the song's hub to LinuxBox first, as rt-r2 D):
   `TAP="l" rig.sh live a6 d`, then `ears.py wav a6_d.wav a6_l.wav --pattern --stamps --gain 0.01` (the laptop's own volume: no mix any
   more). **Hit:** `speed_error` 1 +- 0.002, `gap_ms` 0, `aligned` (corr_windows over 0.9), `steady`; on the laptop the desktop's
   `play_underruns` and `play_resyncs` +0 in the run, `fwd_refused` 0; the desktop's `sent` about one stream's worth a second (200-250
   datagrams per stream, not one per listener).
4. **The relay stalls or goes.** During step 3's playing, on LinuxBox (the holder) `kill -STOP <its REAPER>; sleep 0.15; kill -CONT`.
   **Hit:** on the laptop's tap `gap_ms` at most 60 + the laptop-desktop round trip per stall, `play_resyncs` +0, no "peer to peer"
   line. Then quit LinuxBox's REAPER: within 3 s the next in the order holds (`term` +1 on both survivors), the laptop's `gap_ms` at most
   one rescue line + round trip, `play_resyncs` +0. (Through the mix: a fallback and 3.3 s on direct streams.)
5. **The holder back:** LinuxBox's Live sync again: about 6-8 s after its start it holds again (`handovers` +1 on the interim holder),
   once; nothing moves in the 10 minutes after.
6. **A missing path, small room** (`live_hub` back to 4, three computers: `all` 0): inside LinuxBox block UDP from the desktop's
   Tailscale address (`lab.sh net x1 block <desktop IP>`, UDP only, as rt-r2's notes). **Hit:** within 2 s LinuxBox's desktop entry
   `relayed` true, its tap of the desktop's pattern `gap_ms` at most 100 around the switch and 0 after; undo: `relayed` false within 2 s,
   `gap_ms` 0 at the switch back.
7. **Bandwidth:** the holder's `fwd_kbps` with two senders (Talk only) and two listeners: about 4 x 365 = 1460 kbit/s (5 ms frames);
   muting one sender in one listener's cue mix takes about 365 off within 2 s. Note the numbers for section 2.
8. **The trace:** during step 3, `StudioSync_LiveAudioTrace("<the desktop's peer>")` on the laptop: `talk` and `play` hold 100-120
   windows a minute (event 1) and the run's underruns and re-buffers (8, 4) at their times. Keep one dump from the poor link (rec 19).
9. **No regression:** rt-audio3 round 3's steps 1-3 (a1 `speed_error` 0.997-1.003, `play_rate_ppm` within 2500 of `play_ratio_ppm` in 9
   of 10 reads, idle trims +8 at most): the controller moved, it didn't change.
10. **Lookups:** a Live sync start with a MagicDNS peer name (if the list uses names): its entry says "looking up its name" for a
    moment, and the status's hub `stalls` doesn't grow at the start.

## 11. Review later (security)

- **A relay can attribute audio to another member.** Forwarded packets carry the sender's address in an envelope tagged with the studio
  key; a member holding the lease could inject or alter what a listener takes for another member's stream. Before, Tailscale
  authenticated each sender's address. Fix later: a per-member signature on the inner AOO message, checked by listeners.
- **A member can take the lease** by claiming a high term (up to 2^32 - 1) and keep it. Possible limits: a term must be one more than the
  highest seen, listeners follow only holders in their own order, a cap on claims.
- `'F'` lets a member ask the relay for any stream it could already hear directly: one copy per stream per listener, at most 16 x 2
  streams; nothing amplifies further. Its talkback list is its own word (as `'R'`'s deny list was).
- Bounds: every `"SSF1"`, `'F'`, `'L'` is length-checked; the merge's OSC reader stops at the message's end; a kept `/start` is one
  datagram per sender and stream (1400 bytes at most).
- A listener takes forwarded copies only from the holder it follows, and only for a listed sender's Talk or Play sink; everything else
  is counted in `fwd_refused`.
- `StudioSync_LiveAudioTrace` and the `rt_test_*` hooks are local calls; the resolver looks up only names from the local peers JSON.

## 12. Recommendations (ranked)

1. **Our own jitter buffer, with Opus PLC and WSOLA time-stretch** (rt-audio3 recs 3, 6, 12, 13), in front of libopus: a lone hold
   becomes a soft patch instead of a gap, the size moves by setpoint instead of re-buffering, the target comes from the histogram of
   waits. AOO stays for the sender (or goes: its packet format is all the two ends share). Rust would suit it (section 5). Two to three
   weeks; the simulated network makes it testable from day one (holds, jitter and loss are scripted).
2. **Delete the mix** in the release after every computer has the relay (the gate's second half): `hub_serve`, the `'R'`/`'I'`
   handling, `hub_watch`'s mix states, `msink`/`msrc`/`hring`, `own_outage`, `gap_learn`: about 600 lines; Lua's `hub_plan` and
   `hub_budget` reduce to the relay's `all`.
3. **Sender-side bandwidth in relay rooms:** a Talk muted 5 s pauses its stream (AOO stop/start; a muted computer sends zeros at the
   full rate today), 10 ms frames when everything goes through the relay (-33 % on the wire, +5 ms), and a sender with a weak uplink
   sending only to the relay whatever the room's size (sender-driven relaying).
4. **Sign forwarded packets per member** (section 11's first item) before the relay is used outside James's own computers.
5. **Use the lease for the song's hub too** (restore points): `lib/hub.lua`'s election becomes the order, and `lag`, `blind`, `HOLD`,
   `VOUCH`, `REACH_SETTLE` go. The lease is general; only its holder's jobs differ.
6. **The web pages on the full law** (`pace::Pace`), with the guests' events (dry, cut) as its inputs; extend the golden trace to it.
7. **Measure latency per stream** (rec 8): with the relay each sender's path differs; stamp frames with the link clock.
8. **The rest of rec 5:** counters as atomics and a seqlock'd snapshot, so the status doesn't take `stats_mx` (the send thread holds it
   for `pollEvents` and `adapt` every pass).
9. **The small AOO patch** (`kAooCtlSetResampleRatio`, the fill in samples) only if recommendation 1 waits: it removes `toff`'s
   unbounded growth and `fill_of`'s copy of AOO's capacity formula, nothing audible.
10. **Health names the device as the problem** (rec 9), and **`tools/ears` on a real-time stamp** (recs 11, 21).
