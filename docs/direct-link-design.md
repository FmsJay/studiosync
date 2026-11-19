# Direct link (0.59.50)

Every change is a small write-once event file (`<song>/rooms/<room>/events/<id>.json`) that Syncthing carries: measured at about
2.6-3.3 s per change. The direct link sends each new event file straight to the other computers in the studio over Tailscale as well,
so it arrives in well under a second. Syncthing stays exactly as it is: it still carries every event file, audio and media, and its
copy is the record. The direct copy only gets there first.

REAPER's Lua has no sockets, so the networking lives in the native extension (`extension/direct.cpp`, in the same
`reaper_studiosync` DLL/dylib/so as the menus; not in ReaPersona's build).

## Pieces

| Where | What |
|---|---|
| `extension/direct.cpp`, `direct.h` | A listener thread (TCP, bound only to this computer's Tailscale IPv4 address) and a sender thread (a queue, one kept-open connection per peer). SHA-256 / HMAC-SHA256. The ReaScript functions below. No REAPER API call from either thread. |
| `lib/direct.lua` | Starts the link for a studio, offers each new event to the studio's other computers, lists what arrived, tidies the inbox, the Windows firewall rule, status for Health. Silent fallback to Syncthing-only. |
| `tests/direct_test.cpp`, `tests/build_direct_test.cmd` | Native test: listener + sender on localhost, without REAPER. |
| `tests/test_0_59_50_direct.lua` | The Lua module's pure parts. |

## ReaScript functions (extension 1.0.7)

| Function | |
|---|---|
| `int StudioSync_DirectStart(studio, secret, inbox, port)` | Adds or updates a studio (its folder id, its shared secret, the inbox folder for it) and listens, when it isn't already, on this computer's Tailscale address at `port` (0: 47281). -> 1 listening, 0 not (status says why). A studio is known for sending even when listening fails. `port` < 0: send only, don't listen (no firewall rule yet). |
| `void StudioSync_DirectStop(studio)` | Forgets a studio; `""` stops everything. |
| `int StudioSync_DirectSend(studio, relpath, path, peers)` | Queues the file at `path` (its name in the studio `relpath`) for each of `peers` ("host:port host:port ..."). -> 1 queued, 0 refused (not started, bad path, too big, queue full). |
| `const char* StudioSync_DirectPoll(int after)` | The first file received after sequence number `after`: `"<seq>\t<studio>\t<relpath>"`, or `""`. Not consuming: every Live sync tab keeps its own `after`. The last 256 are kept. |
| `const char* StudioSync_DirectStatus()` | JSON: `{ listening, bind, port, error, received, rejected, last_reject, peers = { ["host:port"] = { ok, ms, error, at, sent } } }`. |

Lua checks `reaper.StudioSync_DirectSend` exists: an older extension simply has none, and everything stays Syncthing-only.

## Protocol

One TCP connection per sender and peer, kept open (closed by the receiver after 120 s idle; the sender reconnects once on a failed
write). Each message:

```
"SSD1"  u16 studio_len  u16 path_len  u32 data_len   (big-endian)
studio bytes  path bytes  data bytes
HMAC-SHA256(key, everything above)                   (32 bytes)
```

`key = HMAC-SHA256(studio secret, "StudioSync direct v1")`. The receiver answers one byte: 0 kept, 1 bad frame, 3 not accepted
(unknown studio or bad HMAC: one answer for both), 4 bad path, 5 too big, 6 couldn't write. Anything but 0 closes the connection.
The sender times that answer: it's the per-peer latency Health shows.

Refused, before anything is written:
- a connection from outside 100.64.0.0/10 (loopback only when the listener itself is bound to loopback: the native test);
- a frame over 4 MB of data, a studio id over 128 bytes, a path over 512 (checked from the header, before reading the body);
- a bad HMAC (compared in constant time) or an unknown studio;
- a path that isn't exactly `<song>/rooms/<room>/events/<name>.json`: song and room plain names (no `/ \ : * ? " < > |`, no control
  characters, not starting with `.`, not ending with `.` or space, at most 200 bytes), `name` only letters, digits, `-` and `_`.

The sender also refuses to connect anywhere outside 100.64.0.0/10 (or loopback), whatever a name resolves to.

Replays: an event file is write-once and named by its id, so a replayed message writes the same file again. Harmless.

## The inbox, outside the shared folder

A received file is written as `<band.home()>/direct/<studio id>/<relpath>` through a temporary name and a rename, never into the
shared folder: Syncthing never sees a local copy of a file it's about to bring (a local duplicate would be a change of this
computer's, with its own modifiedBy, racing the real one).

`direct.listing(cfg, dir)` is the shared folder's listing plus the names only in the inbox; `direct.path(cfg, dir, f)` the shared
file when it's there, else the inbox copy. `direct.tick` tidies: an inbox file whose Syncthing copy has arrived goes, and so does
any older than a day (a song this computer doesn't download, a change trimmed away).

Who may write an event is unchanged: events in the shared folder are writable by anyone in the studio and say who made them;
the HMAC with the studio's secret is the same bar (being in the studio). Roles, claims given, devices and everything else trust
checks by Syncthing's modifiedBy never come through here: only `events/*.json`.

## Who it's sent to

The studio's computers from `_band/devices/*.json` whose person is in the room now (`presence.peers`: nobody here, nothing sent):
each one's Tailscale name on the studio's network (`ts[<suffix>]`, the suffix from `groups.tailnet`), not this computer, only files
their own computer wrote (`trust.device_ok`, as `services.pin_tailnet`), and not a guest whose project list leaves the song out
(`access.read`: a narrowing only). Names, never 100.x addresses. Port 47281, or
ExtState `direct port` (every computer in the studio has to use the same one). A peer that fails is skipped for 10 s by the sender,
so one computer that's off doesn't hold the queue up: Syncthing carries those.

## Secret

The studio's SonoBus secret (`groups.sonobus_secret`, band.json `sonobus`): made by the owner's computer, made again when someone is
taken out (lib/removal.lua). Until the new one reaches a computer its direct copies are refused, and Syncthing carries everything
meanwhile.

## Setting

band.json `direct` (owner and admins, through `groups.trusted`: add `"direct"` to `SETTINGS` in lib/groups.lua): on unless it's
`false`. `direct.enabled(root)`.

## Firewall

- **Windows**: an inbound rule for reaper.exe, TCP 47281, remote addresses 100.64.0.0/10 only, named "StudioSync direct link".
  `direct.firewall_ok()` checks for it (`netsh advfirewall firewall show rule`, in the background); until it's there, StudioSync
  doesn't listen at all (listening without it brings up Windows' own firewall box in REAPER's face) and only sends. `direct.setup_firewall()`
  adds it through `netsh`, elevated by Windows' own UAC prompt (PowerShell `Start-Process -Verb RunAs`): the button for it is Health's
  direct-link row. A "block" rule for reaper.exe (someone pressed Cancel on Windows' box once) beats an allow rule: Health says to
  remove it in Windows Defender Firewall > Allowed apps.
- **macOS**: with the application firewall on, macOS asks once "accept incoming connections?" for REAPER the first time it
  listens; Allow. With it off (the default), nothing.
- **Linux**: usually nothing (no firewall by default). ufw/firewalld on: allow 47281/tcp from 100.64.0.0/10.

## Fallbacks (all silent, Syncthing carries everything)

Extension missing or older than 1.0.7; Tailscale off or no address in 100.64.0.0/10; the studio has no Tailscale network or no secret;
the setting off; no firewall rule (send-only); a peer unreachable or refusing. Nothing waits on the direct copy anywhere.

## Hooks (where StudioSync calls it)

- `sync.post`: `direct.offer(cfg, path)` after the event file is written.
- `sync.receive` and `sync.pending_events`: `direct.listing(cfg, dir)` instead of `band.listing(dir, ".json")`, reading an inbox-only
  name from the path it hands back.
- `sync.forget_trimmed`: names in the inbox count as here (or a change applied from the inbox loses its mark and is applied again).
- Live sync: `direct.tick(cfg)` each tick (a pass of receive and the cue watch at once when something arrived); the cue watch's
  listing through `direct.merge`.
- `mirror.plain_event`'s read by name: `direct.path(nil, dir, f)`.
- Health: `direct.health_line(cfg)`, and the Set up direct link button (`direct.setup_firewall()`) on Windows while
  `direct.firewall_ok()` is false.

## Measured (2026-11-19, JAMES-MAIN and the laptop, the laptop off the home network: Tailscale direct over the internet)

| | |
|---|---|
| Syncthing, a 307-byte file, desktop -> laptop | 2.2-2.7 s, median 2.3 s (half of 8 round trips, 4.5-5.4 s); Live sync's 2 s poll comes on top |
| Tailscale round trip (`tailscale ping`, TCP connect to the laptop's ssh) | 57 ms, 60 ms |
| Direct link through an ssh tunnel over Tailscale, send -> kept and answered | median 59 ms (57-67), first send on a new connection 122 ms |
| Direct link on one computer (tests/direct_test.cpp) | 1.6 ms send -> in the inbox and polled; a 1 MB file 17-20 ms |

So a change is on the other computer's disk about 30 ms after it's written (one way), against about 2.3 s, and is applied at the
next tick instead of the next 2 s poll.

## 1.0.8: the live layer (docs/realtime-roadmap.md steps 1, 2 and the step-4 spike)

Same link, same connection per peer, same HMAC key, same address rules. Three more frame kinds, the header unchanged (the second
field is the frame's "name"); an older extension answers 1 ("it didn't understand") and nothing else changes for it.

| Magic | Name field | Data | Answer |
|---|---|---|---|
| `SSD1` | event path (as before) | the file, up to 4 MB | 1 byte |
| `SSM1` | the kind: `[a-z][a-z0-9_-]{0,31}` (presence, heartbeat, claim, chat, cue, transport, midi, json...) | text, up to 64 KB | 1 byte |
| `SSP1` | `ping` | t0, u64 µs | 0, t1, t2 (u64 µs each), HMAC(key, "SSQ1" t0 t1 t2) |
| `SSS1` | stream path `<song>/<name>.<wav w64 flac aif aiff ogg opus mp3 mid>` | op u8, offset u64, payload | 1 byte; 7 + u64 "what's here" on a gap |

Answer codes added: 7 a gap (the receiver's length follows: the sender goes on from there), 8 a finished stream whose hash didn't match
(the sender begins again; twice at most). Neither closes the connection.

### ReaScript functions

| Function | |
|---|---|
| `int StudioSync_DirectMsg(studio, kind, data, peers)` | Queue a small message. 1 queued. Refused before queueing: a kind that isn't a word, data over 64 KB. |
| `const char* StudioSync_DirectMsgPoll(int after)` | `"<seq>\t<studio>\t<kind>\t<data>"` (data may hold tabs: split on the first three), or `""`. Per-script cursor as DirectPoll; the last 512 (and at most 8 MB) kept. |
| `int StudioSync_DirectPeers(studio, peers)` | The computers to keep a clock with: pinged every 0.2 s for the first 8, then every second, on the kept connection. -> how many. `""`: none. |
| `const char* StudioSync_DirectClock()` | `{ now, peers = { ["host:port"] = { offset_ms, rtt_ms, spread_ms, samples, at, error } } }`; offset = that computer's clock minus this one's. |
| `double StudioSync_DirectNow()` | This computer's link clock, seconds since 1970: wall time when the extension first used it, then the monotonic high-resolution clock (no jumps when Windows syncs its time). |
| `int StudioSync_DirectStream(studio, relpath, path, peers, interval_ms)` | Stream a file that's still being written, every interval_ms (0: 250; 20-5000). 1 started. Calling again adds peers. |
| `int StudioSync_DirectStreamEnd(studio, relpath)` | It's complete (REAPER stopped and closed it): the rest, the first 64 KB again, then done with length + SHA-256. |
| `const char* StudioSync_DirectStreams()` | `{ out = [ { studio, rel, size, ended, finished, peers = { [peer] = { sent, done, resends, error } } } ], in = [ { studio, rel, path, bytes, total, done, ok, playable, codec, at } ] }` |
| `int StudioSync_DirectAudioStart(first_input, nch)`, `void StudioSync_DirectAudioStop()`, `const char* StudioSync_DirectAudioStatus()`, `int StudioSync_DirectAudioDump(path, seconds)` | The audio spike (extension/direct_audio.cpp): idle until started. |

`lib/direct.lua`: `direct.live_available()`, `direct.msg(cfg, kind, data, song, room)`, `direct.messages(cfg)`,
`direct.keep_clock(cfg, song, room)`, `direct.clock_reference(me, dev_of, est)`, `direct.shared_now()`, `direct.stream_rel(song, path)`,
`direct.stream_start(cfg, path, song, room, interval_ms)`, `direct.stream_end(cfg, rel)`, `direct.streams(cfg)`, `direct.stream_path(cfg, rel)`;
`direct.peers` / `peers_from` now also hand back peer -> device id.

### The shared clock

NTP's exchange in-band: t0 (sender), t1 (when the ping's bytes reached the listener), t2 (when the answer goes), t3 (back at the sender).
Per ping, offset = ((t1 - t0) + (t2 - t3)) / 2 and round trip = (t3 - t0) - (t2 - t1). The estimate is the median offset of the 3 lowest
round trips among the last 16 pings: a ping held up one way more than the other is off by half the difference, so the quickest are the
truest, and 16 s of window follows the drift between two computers' clocks (tens of ppm: well under a ms per window).

**Reference rule:** the studio's clock is the computer with the lowest Syncthing device id among this computer and the others in the
room that the link reaches with an estimate (4 samples or more, no error). Every computer picks the same one from the same view, and no
computer's clock is ever set. `direct.shared_now()` = `StudioSync_DirectNow()` + the reference's offset (this computer's own clock when
it is the reference or nobody has an estimate yet), with an error bound of half the reference's best round trip. Play/Record together:
the starter picks `start_at = shared_now + lead`; each computer starts when `reaper.time_precise() >= t_here + (start_at - shared_now_at_t_here)`.

### Streams (a take as it's recorded)

The sender reads the file through a handle shared for read, write and delete (Windows: REAPER can keep writing, and delete a take it
discards), and gets its size from that handle (NTFS's directory entry lags behind a file someone is writing). Each pass, for each peer:
op 0 begin (payload: the codec id, 0 = the file's own bytes; 1 reserved for Opus packets, "fast first, lossless after"), then op 1 chunks
of up to 256 KB from where that peer is, 8 MB a pass at most. After DirectStreamEnd, once everything's sent: op 3 (the first 64 KB again:
the header the recorder rewrote at stop) and op 2 done (length + SHA-256). The receiver writes `<inbox>/.streams/<song>/<name>` (`.streams`
can't be a song's name), skips bytes it already has, answers a gap with its length, and checks the hash at done.

**WAV while recording:** a recorder writes the header first with placeholder sizes (0 or 0xFFFFFFFF) and the real ones at stop. The
receiver keeps its copy playable: after every chunk it sets the `data` size to the whole sample frames it has and then the RIFF size
(RF64: the ds64 chunk's sizes and sample count), so a reader never sees sizes past what's on disk; a look between an append and the
update sees the sizes one chunk behind (a good WAV, a little shorter). The sender's real header (op 3) replaces them at the end and the
hash proves the copy. Not a WAV (or no `data` chunk in the first 64 KB): kept as it comes.

## Measured, 1.0.8 (2026-11-19, tests/direct_test.cpp)

| | |
|---|---|
| Messages on one computer | send -> polled median 0.02-0.03 ms, p95 0.06 ms (200) |
| Clock on one computer, listener skewed +37.5 ms, each way delayed 0-15 ms at random | estimate 36.4-39.0 ms over 8 runs (error 0.15-1.5 ms) after 1.5 s |
| Clock on one computer, no added delay, skew -120 ms | -119.990 to -119.994 ms (error < 0.01 ms), round trip 0.05 ms |
| Clock desktop <-> laptop (ssh tunnel over Tailscale, laptop off the home network, 60 s) | the laptop's clock 322.5 ms ahead (median; all estimates within 322.3-323.8 ms), best round trip median 56.6 ms; an ssh time read agreed (laptop 204-234 ms ahead at the reply, plus the one-way and ssh teardown) |
| Stream on one computer, writer at 4x real time, 50 ms interval | appended -> in the received copy median 44 ms, p95 72-77 ms; every mid-stream look (~400) a playable WAV; final copy byte-identical (one byte changed after sending: caught by the hash, sent again once) |
| Stream throughput on one computer, 64 MB already written | 46-58 MB/s including both SHA-256 passes |
| Stream desktop -> laptop, 48 kHz 24-bit stereo written in real time, 100 ms interval, 20 s | appended -> acknowledged by the laptop median 155 ms, p95 233 ms (one way about 30 ms less); stop -> done and hash-checked 378 ms; 0 resends |
| Audio spike (stand-in audio thread, 256-frame buffers) | 1 s dump exact (48000 frames), no overruns, both sines continuous; callback max 10-255 µs (the high one with the test's own threads busy) |

## Not done (yet)

IPv6 Tailscale addresses (fd7a:115c:a1e0::/48); a peer's port other than this computer's. The Lua hooks for messages, the clock and
streams in the engine and UI (listed in docs/realtime-roadmap.md "Findings, 1.0.8"). A big stream's hash is computed on the listener
thread (about 0.3 s per 100 MB, holding up that computer's other incoming frames meanwhile).
