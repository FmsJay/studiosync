// StudioSync's built-in real-time audio (docs/realtime-roadmap.md step 4, "Step 4 plan"; James chose AOO over our own engine). The
// pieces, and which thread each runs on:
//  - REAPER's audio thread (the hook, extension/rtaudio.cpp bottom; or the test's clock): rt_capture hands the chosen inputs to the AOO
//    source, which only copies them into its own lock-free queue (AooSource::process); rt_mix asks each peer's AOO sink for its next
//    block (jitter buffer, drift-correcting resampler, Opus decode: AOO does the decode here, as SonoBus does; a 5 ms Opus frame costs
//    tens of microseconds) and adds it, at that peer's level unless muted, into the first hardware output pair. No lock, allocation,
//    file or REAPER call here; a reconfiguration pauses it for one block (in_cb/live below, as the spike's g_in_cb).
//  - the send thread: woken by the audio thread whenever there's audio, it lets AOO encode and send (AooSource/AooSink::send), polls
//    their events into the per-peer numbers, and owns every change (sample rate or block size seen, the peer list).
//  - the receive thread: each datagram is checked (from a peer's address, tagged with the studio secret) and handed to the source or
//    to that peer's sink.
// One AOO source (id 1, Talk) sends to every peer; one AOO sink per peer, so each peer has its own level and mute (the cue mix). Play
// (id 2, rt_play: the armed tracks, read from the live out Hop) has its own source and its own sink per peer, so its level is apart. A peer's
// sink id is a hash of its "ip:port", so a sender knows which id its stream goes to on the other side without asking.
// Auth: every datagram is "SSL1" + the AOO message + 16 bytes of HMAC-SHA256 with a key made from the studio secret (as the direct
// link's frames, direct.cpp), so only studio computers are heard; AOO's own passwords live in its server/client part, not built here.
// The hub's live mix (rt_hub; docs/realtime-roadmap.md "More big ideas" 1): one computer (the song's hub, lib/liveaudio.lua hub_plan picks it)
// mixes for the others, so each sends its streams to one place and hears one stream. At the hub, rt_mix copies every peer's block as it
// decodes it anyway (before its own levels) into a ring (hring), and the send thread builds each listener's mix from that listener's own
// Talk/Play levels, adds the hub's own Talk and Play, and encodes it through that listener's own AOO source (MIX_ID): no more than a copy on
// the audio thread. A listener asks for its mix every MODE_EVERY s ("SSX1" control datagrams, tagged as the rest: 'R' its levels, 'M' to everyone
// whether it hears through a hub, 'I' the hub's latency and load back, 'H' whom the hub's mix has), switches to the mix once it has flowed
// ENTER_S, and every sender in that mix then stops sending it their own streams (one the hub doesn't hear keeps sending: hub_watch). When the mix pauses (RESCUE_MIN), the listener asks for everyone's streams back ('M') while the mix's
// buffer still plays, and when it stops for its buffer's length, hears them instead: tests/rtaudio_test.cpp measures a 16-21 ms gap, under
// the 30 ms jitter buffer (with INTRA_S, the streams turned back on are at full level from their first packet).
// GPL-3.0-or-later. AOO (BSD-3-Clause) and Opus (BSD-3-Clause): extension/third_party/README.md.

// AOO's compile-time settings: they must match extension/third_party/build_windows.cmd and build_unix.sh (AOO's headers read them too).
#ifndef _WIN32
#define AOO_HAVE_PTHREAD_RWLOCK 1
#endif
#define AOO_NET 0
#define AOO_USE_OPUS 1
#define AOO_USE_IPV6 0
#define AOO_SAMPLE_SIZE 32
#define AOO_MAX_PACKET_SIZE 4096
#define AOO_HAVE_ATOMIC_DOUBLE 1
#define AOO_HAVE_ATOMIC_INT64 1
#ifdef _WIN32
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <intrin.h>
typedef SOCKET sock_t;
#define BAD_SOCK INVALID_SOCKET
#define close_sock closesocket
#else
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
typedef int sock_t;
#define BAD_SOCK (-1)
#define close_sock close
#endif
#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>
#include "aoo.h"
#include "aoo_sink.hpp"
#include "aoo_source.hpp"
#include "codec/aoo_opus.h"
#include "common/sync.hpp"
#include "../plugin/hop_shm.h"
#include "direct.h"
#include "rtaudio.h"

namespace {
const AooId SRC_ID = 1;
// Play, the second stream (James, rt: "hear what a bandmate plays when they arm"): its own AOO source, and its own sink per peer, so each
// listener sets Talk and Play apart (the personal monitor mix). Its sink ids are the Talk ones' address hashes with "/play" added.
const AooId PLAY_ID = 2;
const int PLAY_BACKLOG = 8; // blocks: more than this unread in the live out ring (a new Hop, a stall) and only the newest block is taken
const char MAGIC[4] = { 'S', 'S', 'L', '1' };
const int TAG = 16, MAX_DGRAM = 1400; // (Tailscale's MTU is 1280: AOO's packets are kept to 1200 below, plus our 20 bytes)
const int OPUS_FRAME = 240;           // samples at 48 kHz: 5 ms frames (2.5 ms doubles the packets for little gain over Tailscale)
// A stream's measured jitter buffer fill (AOO's fill ratio), ms: its lowest in this stretch and the last one (adapt). -1: not measured yet.
struct Low {
  double cur = -1, prev = -1, at = 0;
  void reset(double now) { cur = prev = -1; at = now; }
  void add(double v, double now, double span)
  {
    if (now - at > span) { prev = cur; cur = -1; at = now; }
    if (v >= 0 && (cur < 0 || v < cur)) cur = v;
  }
  double low() const { return prev < 0 ? -1 : cur < 0 ? prev : std::min(prev, cur); } // (-1 until a whole stretch was measured)
};
// This computer's audio clock (rt_capture: the audio thread's), for AOO's drift correction. AOO's DLL read each callback's time as it came,
// so a callback held up (the macOS CI runner's 15-250 ms stalls) pulled its estimate: the test's corrected drift swung to -2.2 ms a second.
// Here lateness can't count: a callback is never early, so the earliest of each CLK_SPAN s (its time against k blocks at the nominal rate)
// is the device's own timing. The rate is the slope between the oldest and newest of those minima kept (CLK_N of them: 10 minutes; up
// to 3 averaged at each end), not a median of short slopes: WASAPI through Voicemeeter (the desktop) calls back on the system's clock and
// drops a whole 10 ms buffer every minute or so, a staircase that is flat between steps (the median read ~+10 ppm, or -1300 with a step
// inside its 30 s) and -102 ppm over minutes (counted: 20.5 ms in 172 s). AOO gets evenly spaced times at that rate (kAooPreciseTimestamp:
// no DLL), from base. Until 3 minima, the nominal rate. The estimate takes ~10 minutes to settle (the desktop: -375 ppm at 3 minutes, -78
// at 13, -102 counted), so the rate used holds at the nominal until CLK_HOLD s of minima, then ramps in linearly up to the full window.
const double CLK_SPAN = 2, CLK_HOLD = 120;
const int CLK_N = 300;
struct Clock {
  AooNtpTime base = 0;
  int len = 0, hn = 0;
  double sr = 0, nom = 0, per = 0, fed = 0, bmin = 1e300, bstart = 0, hx[CLK_N] = {}, hy[CLK_N] = {};
  long long k = 0;
  bool hold = true; // (false: the whole estimate from the first 3 minima, rt_test_drift 2: the drift test's 16 s)
  std::atomic<double> ppm{ 0 }, used{ 0 }; // (for the status: the estimate, and the share of it the correction uses)
};
AooNtpTime clock_step(Clock &c, int len, double sr, AooNtpTime now) // (now: this callback's time; rt_test_clock gives its own)
{
  if (len != c.len || sr != c.sr || c.base == 0) {
    c.len = len; c.sr = sr; c.nom = c.per = len / sr; c.base = now; c.fed = 0; c.k = 0; c.bmin = 1e300; c.bstart = 0; c.hn = 0; c.ppm.store(0); c.used.store(0);
    return now;
  }
  const double x = (double)++c.k * c.nom;
  c.bmin = std::min(c.bmin, aoo_ntpTimeDuration(c.base, now) - x);
  if (x - c.bstart >= CLK_SPAN) {
    if (c.hn == CLK_N) { std::copy(c.hx + 1, c.hx + CLK_N, c.hx); std::copy(c.hy + 1, c.hy + CLK_N, c.hy); --c.hn; }
    c.hx[c.hn] = x; c.hy[c.hn] = c.bmin; ++c.hn;
    c.bstart = x; c.bmin = 1e300;
    if (c.hn >= 3) {
      const int m = std::min(3, c.hn / 3);
      double x0 = 0, y0 = 0, x1 = 0, y1 = 0;
      for (int i = 0; i < m; ++i) { x0 += c.hx[i]; y0 += c.hy[i]; x1 += c.hx[c.hn - 1 - i]; y1 += c.hy[c.hn - 1 - i]; }
      const double v = std::max(-0.02, std::min(0.02, (y1 - y0) / (x1 - x0))); // (real seconds per nominal second, less 1; a VM's 0.5% is inside)
      const double w = !c.hold ? 1 : std::max(0.0, std::min(1.0, (c.hx[c.hn - 1] - c.hx[0] - CLK_HOLD) / (CLK_SPAN * (CLK_N - 1) - CLK_HOLD)));
      c.per = c.nom * (1 + v * w);
      c.ppm.store((1 / (1 + v) - 1) * 1e6);
      c.used.store((1 / (1 + v * w) - 1) * 1e6);
    }
  }
  c.fed += c.per;
  return c.base + (AooNtpTime)(c.fed * 4294967296.0);
}
// The adaptive jitter buffer, per peer (adapt below). ms: a peer's own floor and ceiling come from rt_peer_buffer, these are the defaults
// (30 ms held between the Windows computers over Tailscale; 150 ms is past what a band can play along to anyway). (James, rt)
const double BUF_FLOOR = 30, BUF_CEIL = 150, BUF_GROW = 10, BUF_SHRINK = 10; // (GROW was 20: 6 underruns took the desktop's buffer for the laptop 45 -> 110)
// seconds: no underrun this long before the first shrink, then this long between shrinks (BUF_RETRY: when a size that underran is tried again)
const double BUF_STEADY = 15, BUF_STEP = 10;
const float BUF_QUIET = 0.003f;      // a shrink waits for the peer to be quiet (peak under -50 dBFS) for BUF_QUIET_S: its re-buffer is a gap
const double BUF_QUIET_S = 0.3;
const double STREAM_GRACE = 2.0;     // s: "streaming" stays true through a re-buffer, so the panel and Health don't flap with every underrun
const double PAUSE_S = 1.0;          // an underrun after the stream was down longer than this is a pause (talkback, a stalled sender), not jitter
// The four-computer test (2026-11-20): every link underran ~3 times a minute even in silence, and buffers ratcheted up to the ceiling or sat
// far above their size. Measured: the audio clocks ran -50 to -110 ppm (laptop, Mac) and a few hundred (desktop) against each computer's own
// clock, and AOO's drift correction was off (AOO_DYNAMIC_RESAMPLING is 0 by default), so a slower sender drained every receiver's buffer and
// a faster one filled it, a few ms a minute; and every bit of audio a sender dropped (its send queue full: 25 ms at REAPER's 512-sample
// blocks left ~14 ms for the send thread to wake; a reconfigure's paused block) was lost from the buffers for good. So:
//  - dynamic resampling on every source and sink: each audio clock measured against the computer's (clock_step) and the sink resamples
//    the sender's rate to its own (drift between the computers' clocks themselves, the rest, is what the quiet re-buffer below catches);
//  - SRC_BUFFER: the source's queue (only a hand-off from the audio thread to the send thread: no latency when the thread keeps up);
//  - a paused block is told to AOO as an xrun, so the stream keeps its time (an empty block goes out in its place).
const double SRC_BUFFER = 0.1;
// ms: a stream whose measured buffer never came below its size + TRIM_OVER for a whole stretch (BUF_STEP / 2 twice: AOO can finish buffering
// above its size when packets stall and then burst in) sheds what's above its size (a skip rt_mix crossfades over one block: no re-buffer,
// no gap, so it needn't wait for the peer to be quiet). BUF_MARGIN: a shrink needs this much of the buffer unused at its lowest lately,
// after the shrink (so it never eats into what jitter used).
const double TRIM_OVER = 25, BUF_MARGIN = 5;
// ms: AOO's jitter buffer holds twice its latency by default, and a packet that doesn't fit resets the stream (an overrun: a re-buffer, its
// latency of silence or concealment and the decoder rejoining over ~100 ms). The 2026-11-21 sound test (docs/rt/rt-ears.md, Findings 1;
// docs/rt/rt-p11.md): the laptop's buffer for the desktop's Play had finished a quiet re-buffer ~100 ms above its 145 ms size (packets that
// came late on an internet link, then together), played ~100 ms later than live audio said for seconds, and the next burst overran it
// mid-tone; no counter moved (overruns weren't counted, and AOO's buffer latency is the size when buffering ended, not what's held since).
// So the buffer gets CAP_HEAD more room than its size, and what sits above its size is shed (TRIM_OVER) instead of left to overrun.
const double CAP_HEAD = 300;
const double SHED_STEP = 40; // ms: the most shed in one block (each step decodes that much at once on the audio thread: ~8 Opus frames)
// s: the goal is the least latency, so the odd 20 ms of audio lost to a lone spike beats 60 ms more delay for minutes (1.0.22 held grown
// sizes up to 8 minutes: latency through the hub 234 -> 286 ms). An underrun with none other in the last BUF_LONE s (and not right after
// going back below a size that underran) is a lone spike: the buffer grows a step but comes back down after BUF_STEADY as if it hadn't.
// Underruns closer together are the network's steady jitter: the size that underran is held BUF_RETRY s, doubling up to BUF_RETRY_MAX each
// time going back below it underran again, back to BUF_RETRY after BUF_CALM without an underrun.
const double BUF_LONE = 30, BUF_RETRY = 45, BUF_RETRY_MAX = 180, BUF_CALM = 600;
const double SWITCH_S = 1.5;         // s: an underrun this soon after the hub's mix and direct streams switched is the switch's, not the network's
const double OPUS_MS = 1000.0 * 240 / 48000; // (one Opus frame, ms: the jitter buffer counts in these)
// The hub's live mix (rt_hub). MIX_ID: each listener's mix is its own source at the hub (one per listener, told apart by address); the
// listener's sink for it: the hub's address hash with "/mix". CTL: the control datagrams (mode, the mix's levels, the hub's numbers back).
const AooId MIX_ID = 3;
const char CTL[4] = { 'S', 'S', 'X', '1' };
static_assert(RT_MAX_PEERS <= 32, "a bit per peer: mix_said");
const int HUB_RING = 32;            // blocks the audio thread may be ahead of the hub's mixing (~170 ms at 256): past that blocks are skipped (overloaded)
const double MODE_EVERY = 0.25;      // s: a listener's mode and its mix's levels are said again this often (and at once when they change)
const double MODE_FRESH = 1.0;       // s: a listener's mode older than this counts as "hears everyone directly"; its mix stops when its asking does
const double ENTER_S = 0.3;          // s: the mix flowing this long before a listener hears it instead of everyone's own streams
const double GONE_MIN = 40, GONE_PAD = 20; // ms: no mix datagram for its buffer + GONE_PAD (at least GONE_MIN): the hub is gone, everyone's streams at once
// ms: no mix datagram for the mix's buffer less RESCUE_LEAD (at least RESCUE_MIN, two 5 ms packets): everyone's streams are asked back at once
// while the mix's buffer still plays, so they're nearly buffered by the time it runs dry; the mix back, they're let go again. A buffer grown
// for Wi-Fi's bursts waits longer, so bursts it absorbs don't turn everyone's streams on and off.
// RESCUE_PAD: and never before the mix's widest packet spacing lately + this, so a jittery link (the macOS CI runner) doesn't keep asking.
const double RESCUE_MIN = 10, RESCUE_LEAD = 20, RESCUE_PAD = 5;
const double GAP_SPAN = 30;          // s: the mix's widest packet spacing is kept over this stretch and the last (5 s: spikes ~20 s apart each a rescue)
const double RETRY_S = 3.0;          // s after falling back before the hub's mix is asked for again (a flickering hub doesn't flap the stream)
// s: a listener asking for a mix that doesn't come in JOIN_S (the hub doesn't list it, or isn't mixing: the computers' views of who's hub
// differ for a while) stops asking for JOIN_RETRY_S. Asking costs nothing (everyone's streams are heard meanwhile); it's said in the status
// (join_fails) instead of "joining" for minutes (James, rt: the desktop joined the Mac's mix for 4 minutes, 2026-11-20).
const double JOIN_S = 5.0, JOIN_RETRY_S = 10.0;
// s: a pass of hub_watch this late (the send loop wakes every 5 ms) means this thread didn't run meanwhile, and the receive thread likely
// neither (a VM's guest descheduled: LinuxBox fell back 24 times against 7 rescues, rt-hubsmall). The mix that waited in the socket meanwhile
// isn't silence: such a pass gives the receive thread this long again before the mix's age counts.
const double WATCH_LATE = 0.02;

struct Slot {
  std::string peer, addr_s, err;
  sockaddr_in addr{};
  bool resolved = false, added = false; // (added: the source sends to it; once)
  AooId sink_id = 0, remote_sink_id = 0; // my sink for them; their sink for me
  AooSink *sink = nullptr;
  std::atomic<float> gain{ 1.f }, peak{ 0.f };
  std::atomic<bool> mute{ false }, mono{ false };
  std::atomic<bool> want_send{ true }; // (talkback: does this peer get what this computer sends? rt_send sets it, the send thread acts on it)
  bool sending = true;                 // (what the send thread last told AOO for this peer)
  // from AOO's events (the send thread writes, rt_status reads; stats_mx)
  bool streaming = false;
  double rtt_ms = -1, buffer_ms = -1, src_lat_ms = 0, sink_lat_ms = 0, loss = 0;
  long long dropped = 0, underruns = 0, jitter = 0; // (jitter: the underruns that came from late packets, not from a pause)
  double down_at = -1e9;                            // (when the stream last stopped being active)
  // the adaptive jitter buffer (the send thread's, stats_mx; rt_peer_buffer sets the floor and ceiling)
  double floor_ms = BUF_FLOOR, ceil_ms = BUF_CEIL, target_ms = BUF_FLOOR, fail_ms = 0, last_under = 0, last_change = 0, quiet_since = -1;
  double retry_s = BUF_RETRY, last_retry = -1e9, hold_until = -1e9; // (how long a size that underran is held, and until when; when the
                                                                    // buffer last went back below one)
  long long lone = 0;                                                // (underruns taken as lone spikes: not held)
  long long jitter_seen = 0;
  long long switched = 0, trims = 0; // (underruns that came from a hub mix <-> direct switch; buffers far above their size shed: adapt)
  long long overruns = 0, punderruns = 0, poverruns = 0, ptrims = 0, moverruns = 0; // (AOO's resets of Talk, Play, the mix; Play's own counts)
  double plat_ms = 0, pfill_ms = -1; // (Play: AOO's source + sink latency for it; its buffer as measured, the last look)
  std::atomic<int> shed[3]{ { 0 }, { 0 }, { 0 } }; // (samples rt_mix skips, crossfaded, on Talk's, Play's and the mix's next block: adapt)
  double switch_at = -1e9, mswitch_at = -1e9; // (when this computer last switched between the hub's mix and direct streams; when it last
                                              // joined or left the mix itself (not a rescue: the mix's own gaps are its network's): hub_watch)
  double fill_ms = -1;               // (the measured buffer of what is heard from this peer: Talk, else Play, else its hub mix; the last look)
  Low lt, lp, lm;                    // (Talk's, Play's and the mix's measured buffer lately)
  std::atomic<float> loud{ 0.f }; // (the audio thread's peak since the send thread last looked: is this peer quiet now?)
  bool was_quiet = true;          // (the audio thread's: its last block was silence, so sound coming back fades in)
  // Play from this peer: a sink of its own (its buffer size follows Talk's adaptive one), its own level; added: our Play source sends to theirs
  AooId psink_id = 0, premote_id = 0;
  AooSink *psink = nullptr;
  bool padded = false, pwas_quiet = true;
  std::atomic<float> pgain{ 1.f }, ppeak{ 0.f };
  std::atomic<bool> pmono{ false };
  bool pstreaming = false; // (stats_mx, as streaming)
  double pdown_at = -1e9;
  long long pjitter = 0;
  bool psending = true;    // (what the send thread last told the Play source for this peer)
  // The hub's live mix. As a listener, when this peer is my hub: its mix for me comes to msink (its buffer follows Talk's adaptive one)
  AooId msink_id = 0, mremote_id = 0; // (my sink for its mix; this peer's sink for my mix when I'm the hub)
  AooSink *msink = nullptr;
  bool mwas_quiet = true, mstreaming = false; // (mstreaming: stats_mx)
  double mdown_at = -1e9, mbuf_ms = -1, mlat_ms = 0;
  long long mjitter = 0;
  std::atomic<float> mpeak{ 0.f }, hin_ms{ -1.f }, hload{ -1.f }; // (hin_ms, hload: the hub's 'I': its input latency and load)
  std::atomic<double> mix_at{ -1e9 }, mix_first{ -1e9 }, mix_gap{ 0 }; // (the receive thread's: the last mix datagram, the first after a gap, the widest spacing)
  double gap_cur = 0, gap_prev = 0, gap_at = 0;                     // (the receive thread's: the widest spacing in this stretch and the last)
  double last_direct_ms = -1;                                      // (stats_mx: its own stream's latency when last heard directly)
  // As the hub: this listener's mix (msrc sends to its msink) and what it last asked for (mix_mx): when, its levels, whom its Talk mustn't reach
  AooSource *msrc = nullptr;
  bool madded = false, mserving = false;
  double asked_at = -1e9;
  struct Level { sockaddr_in a; float talk, play; };
  std::vector<Level> levels;
  std::vector<sockaddr_in> deny;
  // Every computer: how this peer hears (its 'M'): through a hub, so my streams don't go to it directly
  std::atomic<double> mode_at{ -1e9 };
  std::atomic<bool> via_hub{ false };
  // As my hub: whom its mix has (its 'H': the peers it hears now; mix_mx). heard_ever false: an older hub that doesn't say, so everyone.
  std::vector<sockaddr_in> heard;
  bool heard_ever = false;
  // As a listener: this peer is in my hub's mix (the send thread sets it, the audio thread reads it), so it's told not to send to me directly
  // and its own streams are left out here; dw: the audio thread's weight for its own streams last block (the crossfade)
  std::atomic<bool> in_mix{ true };
  float dw = 1.f;
  std::atomic<double> rx_at{ -1e9 }; // (the receive thread's: its last datagram with the studio's tag, so it lists this computer. rt-roomlist)
};
// The ears tap (rt_ears; docs/rt/rt-ears.md "Left", docs/rt/rt-p11.md): one stream as this computer hears it, or its own Play as it goes out,
// copied by the audio thread into a lock-free ring (stereo, interleaved) that a worker writes as a 32-bit float WAV. The audio thread only
// copies (no lock, allocation or file); a full ring loses frames and says so (lost).
const uint64_t EARS_RING = 1u << 17; // frames: ~2.7 s at 48 kHz, drained every 5 ms
const double EARS_MAX_S = 60;
struct Ears {
  std::atomic<int> kind{ 0 };   // 0 off, 1 this computer's Play, 2 a peer's Talk, 3 its Play, 4 its hub mix for me (addr: that peer)
  sockaddr_in addr{};           // (written before kind)
  std::vector<float> ring;      // (EARS_RING x 2, made before kind is set; the audio thread writes only while kind is set)
  std::atomic<uint64_t> w{ 0 }, r{ 0 };
  std::atomic<long long> lost{ 0 }, frames{ 0 };
  std::atomic<double> first_at{ -1 }; // (now_s() as its first frame's block was heard or sent)
  std::atomic<int> state{ 0 };  // 0 none, 1 writing, 2 done, 3 failed
  std::atomic<bool> stop{ false };
  std::thread thr;
  std::string path, what;
};
} // namespace

struct RtLink {
  std::mutex api_mx, pend_mx, cfg_mx, stats_mx;
  std::string key, bind_s, err, last_reject, last_reject_from, want_peers, want_secret, have_secret, not_here_from;
  bool peers_dirty = false;
  int want_port = 0;          // (from the peers JSON: the port rt_start binds when it's given 0)
  std::atomic<float> in_peak{ 0.f }; // what this computer sends, peak since the last status (the panel's "you're heard" meter)
  std::atomic<bool> send_on{ true };  // (Mute me and push-to-talk: false sends silence, the stream stays up so unmuting is instant. Kept across restarts)
  int first = 0, nch = 2, kbps = 128, port = 0;
  sockaddr_in me{};
  bool loopback = false;
  sock_t s = BAD_SOCK;
  std::thread rx, tx;
  std::atomic<bool> run{ false }, live{ false };
  std::atomic<bool> overflow{ false }; // (the audio thread saw AOO's send queue full: the send thread resets the source, tx_loop)
  std::atomic<int> in_cb{ 0 };
  aoo::sync::event wake;
  AooSource *src = nullptr;
  std::unique_ptr<Slot> slots[RT_MAX_PEERS];
  int nslots = 0;
  double next_resolve = 0;
  // the audio block AOO is set up for (written while paused), and what the audio thread last saw
  int cfg_sr = 0, cfg_len = 0;
  std::atomic<double> seen_sr{ 0 };
  std::atomic<int> seen_len{ 0 };
  std::vector<float> inbuf, mixbuf;
  float *inptr[RT_MAX_CH] = {}, *mixptr[2] = {};
  std::atomic<long long> callbacks{ 0 }, max_ns{ 0 }, sent{ 0 }, received{ 0 }, rejected{ 0 }, not_here{ 0 };
  struct NotHere { sockaddr_in a; double at; long long n; };
  std::vector<NotHere> nh; // (stats_mx: each studio computer sending here off the list, at most NH_MAX, the oldest replaced. rt-roomlist)
  unsigned char txbuf[MAX_DGRAM + 64];
  std::string status_out;
  std::atomic<rt_extra_fn> extra{ nullptr }; // (Hop's network leg: rt_set_extra)
  std::atomic<void *> extra_user{ nullptr };
  std::atomic<int> extra_in{ 0 };
  std::atomic<const RtNat *> nat{ nullptr }; // (the connection without Tailscale, extension/nat.cpp: rt_set_nat)
  bool nat_only = false;                     // (started with no Tailscale address: the socket on loopback, every peer through nat.cpp)
  std::atomic<double> hold_until{ 0 }; // (tests/rtaudio_test.cpp: rt_test_hold, Wi-Fi's bursts)
  std::atomic<double> hold_mix{ 0 };   // (rt_test_hold_mix: the hub's mixing stalls, as a busy hub's send thread)
  std::atomic<double> hold_tx{ 0 };    // (rt_test_hold_tx: the send thread doesn't run, as a VM's descheduled guest)
  double speed = 1;                    // (rt_test_speed: the adaptive buffer's timings this many times faster)
  bool resample = true;                // (rt_test_drift: AOO's drift correction)
  // blocks the audio thread skipped while a reconfigure paused it (capture, mix), told to AOO as xruns on the next live block; how often it paused
  std::atomic<int> skip_in{ 0 }, skip_out{ 0 };
  std::atomic<long long> skipped{ 0 };
  long long pauses = 0, overflows = 0;
  Clock clk;                          // (the audio thread's: clock_step)
  AooNtpTime tfed = 0;                // (this block's time from it, for rt_mix; clk_cb: the callback it was for)
  long long clk_cb = -1;
  // Play (rt_play): the live out Hop's send ring is read on the audio thread into its own AOO source. want_phop/play_send: rt_play's
  // (pend_mx for want_phop); phop/pmap/pshm: the send thread's, changed while paused; pstream: the stream runs (the send thread sets it)
  AooSource *psrc = nullptr;
  int want_phop = 0, phop = 0;
  hop_map pmap = {};
  hop_shm *pshm = nullptr;
  std::vector<hop_map> pnames;           // (every mapping opened: the POSIX names go when REAPER quits, as extension/hop.cpp's)
  std::atomic<bool> play_send{ true }, pstream{ false }, poverflow{ false };
  uint64_t play_r = 0;                   // (the audio thread's: the next live out frame to send)
  std::vector<float> pbuf, pinter;
  float *pptr[2] = {};
  std::vector<float> xbuf;               // (the audio thread's: the block before a shed's skip, crossfaded into the one after: rt_mix)
  float *xptr[2] = {};
  Ears ears;                             // (rt_ears)
  std::atomic<float> play_peak{ 0.f };
  std::atomic<long long> play_ok_cb{ -1000000 }; // (the callback count when a full block last came from the ring: is the live out track running?)
  // The hub's live mix (rt_hub). want_hub, want_serve: rt_hub's (pend_mx). The send thread's: serve, hub_name; hub_peer and hub_state the
  // audio thread reads (whose mix it decodes; 2: heard instead of everyone's own streams). mixw: the audio thread's last weight, for the crossfade.
  std::mutex mix_mx;
  std::string want_hub, hub_name;
  int want_serve = 0;
  bool serve = false;
  std::atomic<Slot *> hub_peer{ nullptr };
  std::atomic<int> hub_state{ 0 };   // 0 everyone's own streams, 1 asking for the mix, 2 hearing the mix
  float mixw = 0;
  double retry_at = 0, next_ctl = 0, next_info = 0, left_at = -1e9;
  bool via_said = false;            // (the last 'M' said: my streams come through the hub)
  unsigned mix_said = 0;            // (and to which peers: those in the hub's mix, a bit per slot)
  double join_at = 0;               // (when this computer last started asking for a mix: JOIN_S)
  long long join_fails = 0;         // (asks that no mix answered in JOIN_S)
  double intra_until = 0;           // (apply_sends: frames coded without prediction until then)
  long long fallbacks = 0, rescues = 0; // (rescues: everyone's streams asked back while the mix paused)
  double watch_at = -1e9, watch_free = -1e9; // (hub_watch's last pass; the last pass WATCH_LATE late that the mix's age waits out)
  long long stalls = 0; double stall_max = 0; // (status: passes WATCH_LATE late, and the longest gap, s)
  std::string asked_sig;            // (the levels last asked for: asked again at once when they change)
  // serving: the audio thread's copy of every peer's block (and this computer's own Talk and Play), per callback, read by the send thread
  std::vector<float> hring, hmix;
  std::vector<AooNtpTime> htime;
  size_t hstride = 0;
  float *hmixptr[2] = {};
  std::atomic<uint64_t> hw{ 0 }, hr{ 0 };
  std::atomic<bool> hserve{ false };
  std::atomic<long long> hskipped{ 0 };
  double hub_ns = 0, hub_audio_s = 0, hub_load = 0, hub_max_us = 0, hub_win = 0; // (stats_mx: the mixing's share of one core, over ~1 s)
  double hub_cpu = 0, hub_tick0 = 0; // (stats_mx: the send thread's own CPU time in hub_serve this window, in thread_ticks; ticks_now at its start)
  int hub_serving = 0;
};

namespace {
std::once_flag g_aoo_once;
double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
// The calling thread's own CPU time, for the hub's load: the clock also counts the time it was preempted (REAPER's FX and audio threads at
// 128-sample blocks, another program), which isn't the mix's cost (James, rt: the laptop's hub paused itself at 25-29%; its own cost is ~5%).
// Windows counts it in the TSC's ticks (QueryThreadCycleTime: a constant rate on x64), whose rate ticks_now measures against the clock.
#if defined(_WIN32) && (defined(_M_X64) || defined(_M_IX86))
double thread_ticks() { ULONG64 c = 0; return QueryThreadCycleTime(GetCurrentThread(), &c) ? (double)c : -1; }
double ticks_now() { return (double)__rdtsc(); }
#elif !defined(_WIN32)
double thread_ticks() { timespec t; return clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t) == 0 ? t.tv_sec * 1e9 + t.tv_nsec : -1; }
double ticks_now() { return now_s() * 1e9; }
#else
double thread_ticks() { return -1; } // (no thread CPU time here: the clock's)
double ticks_now() { return now_s() * 1e9; }
#endif
// The send and receive threads carry the live audio and the hub's mix. Windows 11 runs a background app's threads as EcoQoS (on a hybrid
// laptop: an efficiency core at a low clock) when REAPER isn't in front or the screen is off; these opt out, as REAPER's audio thread does
// through MMCSS. Windows 10 1709 and later (looked up, so older ones just skip it); elsewhere nothing.
void full_speed()
{
#ifdef _WIN32
  THREAD_POWER_THROTTLING_STATE s = { THREAD_POWER_THROTTLING_CURRENT_VERSION, THREAD_POWER_THROTTLING_EXECUTION_SPEED, 0 };
  typedef BOOL(WINAPI * SetInfo)(HANDLE, THREAD_INFORMATION_CLASS, LPVOID, DWORD);
  if (SetInfo f = (SetInfo)(void *)GetProcAddress(GetModuleHandleA("kernel32.dll"), "SetThreadInformation")) f(GetCurrentThread(), ThreadPowerThrottling, &s, sizeof(s));
#endif
}
unsigned fnv(const std::string &s) { unsigned h = 2166136261u; for (unsigned char c : s) { h ^= c; h *= 16777619u; } return h; }
AooId id_of(const std::string &addr) { const AooId v = (AooId)(fnv(addr) & 0x7fffffff); return v ? v : 1; }
std::string addr_str(const sockaddr_in &a)
{
  char b[64];
  inet_ntop(AF_INET, &a.sin_addr, b, sizeof(b));
  return std::string(b) + ":" + std::to_string(ntohs(a.sin_port));
}
bool same_addr(const sockaddr_in &a, const sockaddr_in &b) { return a.sin_addr.s_addr == b.sin_addr.s_addr && a.sin_port == b.sin_port; }
// Tailscale's 100.64.0.0/10 only (and 127/8 when bound to loopback: the test). Nothing else is ever sent to or taken from.
bool addr_ok(const sockaddr_in &a, bool loopback)
{
  const unsigned char *p = (const unsigned char *)&a.sin_addr;
  return (p[0] == 100 && p[1] >= 64 && p[1] <= 127) || (loopback && p[0] == 127);
}
// The connection without Tailscale (extension/nat.cpp): a bandmate it reaches has a synthetic address (198.18.0.0/15, the same on every
// computer), which stands for it here exactly as a Tailscale address does; datagrams to it go through nat.cpp (sealed there, after our tag),
// and what nat.cpp opens comes in through rt_nat_rx as if from that address. Nothing else changes: AOO, the hub's mix and the tags don't know.
bool synthetic(const sockaddr_in &a) { const unsigned char *p = (const unsigned char *)&a.sin_addr; return p[0] == 198 && (p[1] == 18 || p[1] == 19); }
bool peer_ok(RtLink *l, const sockaddr_in &a)
{
  if (!synthetic(a)) return addr_ok(a, l->loopback);
  const RtNat *n = l->nat.load();
  return n && n->up(n->h, &a);
}
int send_to(RtLink *l, const void *d, int len, const sockaddr_in &to)
{
  if (synthetic(to)) { const RtNat *n = l->nat.load(); return n ? n->send(n->h, &to, d, len) : -1; }
  return (int)sendto(l->s, (const char *)d, len, 0, (const sockaddr *)&to, sizeof(to));
}
// This computer's Tailscale address, as direct.cpp tailscale_ip: where a UDP socket "connected" to 100.100.100.100 would send from.
std::string tailscale_ip()
{
  sock_t s = socket(AF_INET, SOCK_DGRAM, 0);
  if (s == BAD_SOCK) return "";
  direct_noinherit(s);
  sockaddr_in to{}, me{};
  to.sin_family = AF_INET;
  to.sin_port = htons(53);
  inet_pton(AF_INET, "100.100.100.100", &to.sin_addr);
  socklen_t len = sizeof(me);
  std::string ip;
  if (connect(s, (sockaddr *)&to, sizeof(to)) == 0 && getsockname(s, (sockaddr *)&me, &len) == 0 && addr_ok(me, false)) {
    char b[64];
    inet_ntop(AF_INET, &me.sin_addr, b, sizeof(b));
    ip = b;
  }
  close_sock(s);
  return ip;
}
std::vector<std::string> split(const std::string &list)
{
  std::vector<std::string> out;
  size_t i = 0;
  while (i < list.size()) {
    while (i < list.size() && (list[i] == ' ' || list[i] == '\t' || list[i] == '\n' || list[i] == ',')) ++i;
    size_t e = i;
    while (e < list.size() && list[e] != ' ' && list[e] != '\t' && list[e] != '\n' && list[e] != ',') ++e;
    if (e > i && out.size() < RT_MAX_PEERS) out.push_back(list.substr(i, e - i));
    i = e;
  }
  return out;
}
// The peers JSON from lib/liveaudio.lua: {"secret":"...","port":47281,"peers":["host:port",...]}. Only those keys are read; anything
// else, or anything malformed, leaves the call doing nothing (false).
bool json_str_at(const std::string &j, size_t &i, std::string &out)
{
  out.clear();
  if (i >= j.size() || j[i] != '"') return false;
  for (++i; i < j.size(); ++i) {
    const char c = j[i];
    if (c == '"') { ++i; return true; }
    if (c != '\\') { out += c; continue; }
    if (++i >= j.size()) return false;
    switch (j[i]) {
    case 'n': out += '\n'; break;
    case 't': out += '\t'; break;
    case 'r': out += '\r'; break;
    case 'b': out += '\b'; break;
    case 'f': out += '\f'; break;
    case 'u': {
      if (i + 4 >= j.size()) return false;
      const unsigned v = (unsigned)strtoul(j.substr(i + 1, 4).c_str(), nullptr, 16);
      i += 4;
      if (v < 0x80) out += (char)v;
      else if (v < 0x800) { out += (char)(0xC0 | (v >> 6)); out += (char)(0x80 | (v & 63)); }
      else { out += (char)(0xE0 | (v >> 12)); out += (char)(0x80 | ((v >> 6) & 63)); out += (char)(0x80 | (v & 63)); }
      break;
    }
    default: out += j[i]; // (\" \\ \/)
    }
  }
  return false;
}
void json_ws(const std::string &j, size_t &i) { while (i < j.size() && (j[i] == ' ' || j[i] == '\t' || j[i] == '\n' || j[i] == '\r')) ++i; }
bool parse_peers_json(const std::string &j, std::string &secret, int &port, std::vector<std::string> &peers)
{
  size_t i = 0;
  json_ws(j, i);
  if (i >= j.size() || j[i++] != '{') return false;
  for (;;) {
    json_ws(j, i);
    if (i < j.size() && j[i] == '}') return true;
    std::string key, s;
    if (!json_str_at(j, i, key)) return false;
    json_ws(j, i);
    if (i >= j.size() || j[i++] != ':') return false;
    json_ws(j, i);
    if (i >= j.size()) return false;
    if (j[i] == '"') {
      if (!json_str_at(j, i, s)) return false;
      if (key == "secret") secret = s;
    } else if (j[i] == '[') {
      ++i;
      for (;;) {
        json_ws(j, i);
        if (i < j.size() && j[i] == ']') { ++i; break; }
        if (!json_str_at(j, i, s)) return false;
        if (key == "peers" && peers.size() < RT_MAX_PEERS && !s.empty()) peers.push_back(s);
        json_ws(j, i);
        if (i < j.size() && j[i] == ',') ++i;
      }
    } else { // a number, true, false or null
      const size_t e = j.find_first_of(",}", i);
      if (e == std::string::npos) return false;
      if (key == "port") port = atoi(j.substr(i, e - i).c_str());
      i = e;
    }
    json_ws(j, i);
    if (i < j.size() && j[i] == ',') { ++i; continue; }
    if (i < j.size() && j[i] == '}') return true;
    return false;
  }
}
// The key: a label of its own, so a live audio tag can never pass for a direct link frame's or the other way round.
std::string key_of(const std::string &secret)
{
  if (secret.empty()) return "";
  static const char label[] = "StudioSync live audio v1";
  unsigned char k[32];
  direct_hmac_sha256((const unsigned char *)secret.data(), secret.size(), (const unsigned char *)label, sizeof(label) - 1, k);
  return std::string((const char *)k, 32);
}
bool resolve(const std::string &peer, bool loopback, sockaddr_in &out, std::string &why)
{
  const size_t c = peer.rfind(':');
  if (c == std::string::npos || c == 0) { why = "not name:port"; return false; }
  addrinfo hints{}, *res = nullptr;
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_DGRAM;
  if (getaddrinfo(peer.substr(0, c).c_str(), peer.substr(c + 1).c_str(), &hints, &res) != 0 || !res) { why = "its name doesn't resolve (Tailscale off there or here?)"; return false; }
  out = *(const sockaddr_in *)res->ai_addr;
  freeaddrinfo(res);
  if (!addr_ok(out, loopback)) { why = "not a Tailscale address"; return false; }
  return true;
}
void tag_of(const std::string &key, const unsigned char *p, size_t n, unsigned char out[32]) { direct_hmac_sha256((const unsigned char *)key.data(), key.size(), p, n, out); }
bool same_tag(const unsigned char *a, const unsigned char *b) { unsigned char d = 0; for (int i = 0; i < TAG; ++i) d |= a[i] ^ b[i]; return d == 0; } // (constant time)
double ntp_ms(AooNtpTime a, AooNtpTime b) { return aoo_ntpTimeDuration(a, b) * 1000.0; }
void json_str(std::string &o, const std::string &s)
{
  o += '"';
  for (unsigned char c : s) {
    if (c == '"' || c == '\\') { o += '\\'; o += (char)c; }
    else if (c < 0x20) { char b[8]; snprintf(b, sizeof(b), "\\u%04x", c); o += b; }
    else o += (char)c;
  }
  o += '"';
}

// AOO's outgoing packets (the send thread only): tagged and sent to a peer's address.
AooInt32 AOO_CALL send_fn(void *user, const AooByte *data, AooInt32 size, const void *address, AooAddrSize addrlen, AooFlag)
{
  RtLink *l = (RtLink *)user;
  if (l->key.empty() || size <= 0 || size + 4 + TAG > MAX_DGRAM || addrlen < (AooAddrSize)sizeof(sockaddr_in)) return -1; // (no secret yet: nothing goes out)
  const sockaddr_in &to = *(const sockaddr_in *)address;
  if (!peer_ok(l, to)) return -1;
  memcpy(l->txbuf, MAGIC, 4);
  memcpy(l->txbuf + 4, data, (size_t)size);
  unsigned char t[32];
  tag_of(l->key, l->txbuf, 4 + (size_t)size, t);
  memcpy(l->txbuf + 4 + size, t, TAG);
  const int n = send_to(l, l->txbuf, 4 + size + TAG, to);
  if (n > 0) l->sent.fetch_add(1, std::memory_order_relaxed);
  return n;
}

Slot *slot_of(RtLink *l, const sockaddr_in &a) // (cfg_mx or the send thread)
{
  for (int i = 0; i < l->nslots; ++i) if (l->slots[i]->resolved && same_addr(l->slots[i]->addr, a)) return l->slots[i].get();
  return nullptr;
}

// Events, polled on the send thread.
// An underrun: the network's jitter (it grows the buffer) only when the stream was down a moment, not after a pause, and not right after this
// computer switched between the hub's mix and direct streams (the streams it stopped and started again: the switch's gap, not the network's).
void under(Slot *p, double down_at, double switch_at, long long &jitter)
{
  const double now = now_s();
  if (now - switch_at < SWITCH_S) p->switched += 1;
  else if (now - down_at < PAUSE_S) jitter += 1;
}
void AOO_CALL sink_event(void *user, const AooEvent *e, AooThreadLevel)
{
  Slot *p = (Slot *)user;
  switch (e->type) {
  case kAooEventSourcePing: {
    const auto &q = e->sourcePing;
    p->rtt_ms = ntp_ms(q.t1, q.t4) - ntp_ms(q.t2, q.t3);
    break;
  }
  case kAooEventStreamLatency:
    p->src_lat_ms = e->streamLatency.sourceLatency * 1000;
    p->sink_lat_ms = e->streamLatency.sinkLatency * 1000;
    p->buffer_ms = e->streamLatency.bufferLatency * 1000;
    break;
  case kAooEventFormatChange: p->mono.store(e->formatChange.format->numChannels == 1); break;
  case kAooEventStreamState: {
    const bool on = e->streamState.state == kAooStreamStateActive;
    if (p->streaming && !on) p->down_at = now_s();
    p->streaming = on;
    break;
  }
  case kAooEventStreamStop: case kAooEventSourceRemove: p->streaming = false; p->down_at = -1e9; break;
  case kAooEventBlockDrop: p->dropped += e->blockDrop.count; break;
  case kAooEventBufferUnderrun: // (AOO says so once packets come again after it ran dry; a long gap was a pause, which a bigger buffer doesn't help)
    p->underruns += 1;
    under(p, p->down_at, p->switch_at, p->jitter);
    break;
  case kAooEventBufferOverrun: p->overruns += 1; break; // (a burst that didn't fit: AOO re-buffered. CAP_HEAD)
  default: break;
  }
}
void AOO_CALL play_sink_event(void *user, const AooEvent *e, AooThreadLevel) // (a peer's Play: only what the panel and the buffer need)
{
  Slot *p = (Slot *)user;
  switch (e->type) {
  case kAooEventFormatChange: p->pmono.store(e->formatChange.format->numChannels == 1); break;
  case kAooEventStreamState: {
    const bool on = e->streamState.state == kAooStreamStateActive;
    if (p->pstreaming && !on) p->pdown_at = now_s();
    p->pstreaming = on;
    break;
  }
  case kAooEventStreamStop: case kAooEventSourceRemove: p->pstreaming = false; p->pdown_at = -1e9; break;
  case kAooEventBlockDrop: p->dropped += e->blockDrop.count; break;
  case kAooEventBufferUnderrun: p->punderruns += 1; under(p, p->pdown_at, p->switch_at, p->pjitter); break;
  case kAooEventBufferOverrun: p->poverruns += 1; break;
  case kAooEventStreamLatency: p->plat_ms = (e->streamLatency.sourceLatency + e->streamLatency.sinkLatency) * 1000; break;
  default: break;
  }
}
void AOO_CALL mix_sink_event(void *user, const AooEvent *e, AooThreadLevel) // (my hub's mix for me: its latency, state and underruns)
{
  Slot *p = (Slot *)user;
  switch (e->type) {
  case kAooEventStreamLatency:
    p->mbuf_ms = e->streamLatency.bufferLatency * 1000;
    p->mlat_ms = (e->streamLatency.sourceLatency + e->streamLatency.sinkLatency) * 1000;
    break;
  case kAooEventStreamState: {
    const bool on = e->streamState.state == kAooStreamStateActive;
    if (p->mstreaming && !on) p->mdown_at = now_s();
    p->mstreaming = on;
    break;
  }
  case kAooEventStreamStop: case kAooEventSourceRemove: p->mstreaming = false; p->mdown_at = -1e9; break;
  case kAooEventBlockDrop: p->dropped += e->blockDrop.count; break;
  case kAooEventBufferUnderrun: under(p, p->mdown_at, p->mswitch_at, p->mjitter); break;
  case kAooEventBufferOverrun: p->moverruns += 1; break;
  default: break;
  }
}
void AOO_CALL source_event(void *user, const AooEvent *e, AooThreadLevel)
{
  RtLink *l = (RtLink *)user;
  if (e->type != kAooEventSinkPing || e->sinkPing.endpoint.addrlen < (AooAddrSize)sizeof(sockaddr_in)) return;
  Slot *p = slot_of(l, *(const sockaddr_in *)e->sinkPing.endpoint.address);
  if (!p) return;
  const auto &q = e->sinkPing;
  p->loss = q.packetLoss;
  if (p->rtt_ms < 0) p->rtt_ms = ntp_ms(q.t1, q.t4) - ntp_ms(q.t2, q.t3);
}

// AOO's drift correction (dynamic resampling: the top of the file) on every sink and source, and the source's hand-off queue. The rate it
// corrects with comes from the times rt_capture hands AOO (clock_step; kAooPreciseTimestamp in setup). rt_test_drift: off.
void tune(RtLink *l, AooSink *s) { if (s) s->setDynamicResampling(l->resample ? kAooTrue : kAooFalse); }
void tune(RtLink *l, AooSource *s)
{
  if (!s) return;
  s->setBufferSize(SRC_BUFFER);
  s->setDynamicResampling(l->resample ? kAooTrue : kAooFalse);
}

// A sink's buffer: its latency (what AOO buffers before playing, the adaptive size) and room for CAP_HEAD more (AOO's capacity; it overruns
// past that). Both re-buffer its stream (kAooCtlSetLatency/SetBufferSize: reset_sources), so only where the size changes.
void size_sink(AooSink *s, double ms)
{
  if (!s) return;
  s->setLatency(ms / 1000.0);
  s->setBufferSize((ms + CAP_HEAD) / 1000.0);
}

void pause_audio(RtLink *l)
{
  ++l->pauses;
  l->live.store(false);
  for (int i = 0; i < 2000 && l->in_cb.load() > 0; ++i) std::this_thread::sleep_for(std::chrono::microseconds(100)); // (a callback mid-flight finishes)
}
void setup_source(RtLink *l, AooSource *src, int nch, bool start);
void setup_sink(RtLink *l, Slot &p)
{
  if (!p.sink || l->cfg_sr <= 0) return;
  p.sink->setup(2, l->cfg_sr, l->cfg_len, kAooFixedBlockSize | kAooPreciseTimestamp);
  if (p.psink) p.psink->setup(2, l->cfg_sr, l->cfg_len, kAooFixedBlockSize | kAooPreciseTimestamp);
  if (p.msink) p.msink->setup(2, l->cfg_sr, l->cfg_len, kAooFixedBlockSize | kAooPreciseTimestamp);
  if (p.msrc) setup_source(l, p.msrc, 2, p.mserving);
}
std::unique_ptr<Slot> make_slot(RtLink *l, const std::string &peer)
{
  std::unique_ptr<Slot> p(new Slot());
  p->peer = peer;
  const RtNat *nat = l->nat.load();
  const bool via_nat = peer.compare(0, 4, "nat:") == 0;
  if (via_nat) { p->resolved = nat && nat->resolve(nat->h, peer.c_str(), &p->addr); if (!p->resolved) p->err = "not set up for the connection without Tailscale yet"; }
  else p->resolved = resolve(peer, l->loopback, p->addr, p->err);
  if (!p->resolved) return p;
  const std::string me_s = via_nat ? nat->self(nat->h) : l->bind_s; // (what that peer calls this computer: its sinks for me are named from it)
  p->addr_s = addr_str(p->addr);
  p->sink_id = id_of(p->addr_s);
  p->remote_sink_id = id_of(me_s);
  p->sink = AooSink_new(p->sink_id);
  if (!p->sink) { p->resolved = false; p->err = "no AOO sink"; return p; }
  p->sink->setEventHandler(sink_event, p.get(), kAooEventModePoll);
  size_sink(p->sink, BUF_FLOOR);
  p->sink->setPacketSize(1200);
  tune(l, p->sink);
  p->psink_id = id_of(p->addr_s + "/play");
  p->premote_id = id_of(me_s + "/play");
  p->psink = AooSink_new(p->psink_id);
  if (p->psink) {
    p->psink->setEventHandler(play_sink_event, p.get(), kAooEventModePoll);
    size_sink(p->psink, BUF_FLOOR);
    p->psink->setPacketSize(1200);
    tune(l, p->psink);
  }
  p->msink_id = id_of(p->addr_s + "/mix"); // (the hub's live mix: heard from this peer only while it's my hub; made for every peer, it costs nothing idle)
  p->mremote_id = id_of(me_s + "/mix");
  p->msink = AooSink_new(p->msink_id);
  if (p->msink) {
    p->msink->setEventHandler(mix_sink_event, p.get(), kAooEventModePoll);
    size_sink(p->msink, BUF_FLOOR);
    p->msink->setPacketSize(1200);
    tune(l, p->msink);
  }
  p->msrc = AooSource_new(MIX_ID); // (its stream starts only while I mix for this peer: hub_serve)
  if (p->msrc) p->msrc->setPacketSize(1200);
  tune(l, p->msrc);
  setup_sink(l, *p);
  return p;
}
void drop_slot(RtLink *l, Slot &p)
{
  if (p.resolved && l->src) { AooEndpoint ep = { &p.addr, (AooAddrSize)sizeof(p.addr), p.remote_sink_id }; l->src->removeSink(ep); }
  if (p.resolved && l->psrc) { AooEndpoint ep = { &p.addr, (AooAddrSize)sizeof(p.addr), p.premote_id }; l->psrc->removeSink(ep); }
  if (p.sink) AooSink_free(p.sink);
  if (p.psink) AooSink_free(p.psink);
  if (p.msink) AooSink_free(p.msink);
  if (p.msrc) AooSource_free(p.msrc);
  p.sink = p.psink = p.msink = nullptr;
  p.msrc = nullptr;
}
void setup_source(RtLink *l, AooSource *src, int nch, bool start)
{
  src->setup(nch, l->cfg_sr, l->cfg_len, kAooFixedBlockSize | kAooPreciseTimestamp); // (the times: clock_step)
  AooFormatOpus fmt;
  AooFormatOpus_init(&fmt, nch, 48000, OPUS_FRAME, OPUS_APPLICATION_RESTRICTED_LOWDELAY); // (CELT only: the lowest delay, made for music)
  src->setFormat(fmt.header);
  opus_int32 br = l->kbps * 1000;
  src->codecControl(kAooCodecOpus, OPUS_SET_BITRATE_REQUEST, 0, &br, sizeof(br));
  if (start) src->startStream(0, nullptr);
}

// The send thread's changes: a new sample rate or block size, a new peer list (or a peer whose name didn't resolve, every 5 s).
void reconfigure(RtLink *l)
{
  const double ssr = l->seen_sr.load();
  const int slen = l->seen_len.load();
  const bool audio = ssr > 0 && slen > 0 && ((int)ssr != l->cfg_sr || slen != l->cfg_len);
  bool peers = false;
  std::string list, secret;
  int phop = 0;
  bool serve = false;
  {
    std::lock_guard<std::mutex> g(l->pend_mx);
    peers = l->peers_dirty;
    l->peers_dirty = false;
    list = l->want_peers;
    secret = l->want_secret;
    phop = l->want_phop;
    serve = l->want_serve != 0;
  }
  const bool play = phop != l->phop; // (another live out Hop, or none: its mapping opened here, never on the audio thread)
  const bool serving = serve != l->serve; // (mixing for others on or off: the ring the audio thread writes is sized here, while it's paused)
  if (secret != l->have_secret) { // (a new studio secret: the receive thread checks tags under cfg_mx, the send thread is this one)
    std::lock_guard<std::mutex> g(l->cfg_mx);
    l->have_secret = secret;
    l->key = key_of(secret);
  }
  if (!peers && now_s() > l->next_resolve) {
    for (int i = 0; i < l->nslots; ++i) peers = peers || !l->slots[i]->resolved;
    l->next_resolve = now_s() + 5;
  }
  if (!audio && !peers && !play && !serving) return;
  // new peers are resolved before the pause (a name lookup can take a while; audio keeps going meanwhile)
  std::vector<std::unique_ptr<Slot>> next;
  if (peers) {
    const std::vector<std::string> names = split(list);
    bool same = (int)names.size() == l->nslots; // (the same list, in order, and a name that didn't resolve still doesn't: nothing to change)
    for (size_t k = 0; k < names.size(); ++k) {
      bool kept = false;
      for (int i = 0; i < l->nslots && !kept; ++i) kept = l->slots[i] && l->slots[i]->resolved && l->slots[i]->peer == names[k];
      next.push_back(kept ? nullptr : make_slot(l, names[k])); // (nullptr: the running one is moved over below)
      same = same && l->slots[k]->peer == names[k] && (kept ? l->slots[k]->resolved : !next.back()->resolved && !l->slots[k]->resolved);
    }
    if (same) { next.clear(); peers = false; } // (unresolved slots own no AOO objects: nothing to free)
  }
  // Mixing for others on or off needs no pause once its ring is the right size: the audio thread only writes it while hserve is set, and it
  // stays allocated when the mixing stops. (Every pause is a block of audio not sent nor heard here: the hub's budget turned it off and on.)
  if (serving && !audio && !peers && !play) {
    const size_t want = (size_t)HUB_RING * (size_t)(l->nslots + 1) * 4 * (size_t)std::max(l->cfg_len, 1);
    if (!serve || (l->cfg_len > 0 && l->hring.size() == want)) {
      l->serve = serve;
      if (!serve) l->hserve.store(false);
      return;
    }
  }
  if (!audio && !peers && !play && !serving) return;
  pause_audio(l);
  std::lock_guard<std::mutex> g(l->cfg_mx);
  if (play) {
    if (l->pshm) { hop_shm_close(&l->pmap); l->pshm = nullptr; }
    l->phop = phop;
    if (phop > 0 && hop_shm_open(&l->pmap, hop_reaper_pid(), phop)) {
      l->pshm = l->pmap.p;
      l->pnames.push_back(l->pmap);
      l->play_r = hop_load(&l->pshm->send_w); // (from now on: nothing older than this is sent)
    }
    const bool want = l->pshm != nullptr && l->cfg_sr > 0;
    if (want != l->pstream.load()) { if (want) l->psrc->startStream(0, nullptr); else l->psrc->stopStream(0); l->pstream.store(want); }
  }
  if (audio) {
    l->cfg_sr = (int)ssr;
    l->cfg_len = slen;
    l->inbuf.assign((size_t)l->nch * slen, 0.f);
    l->mixbuf.assign((size_t)2 * slen, 0.f);
    l->pbuf.assign((size_t)2 * slen, 0.f);
    l->pinter.assign((size_t)2 * slen, 0.f);
    l->xbuf.assign((size_t)2 * slen, 0.f);
    l->xptr[0] = &l->xbuf[0];
    l->xptr[1] = &l->xbuf[(size_t)slen];
    for (int c = 0; c < l->nch; ++c) l->inptr[c] = &l->inbuf[(size_t)c * slen];
    for (int c = 0; c < 2; ++c) { l->mixptr[c] = &l->mixbuf[(size_t)c * slen]; l->pptr[c] = &l->pbuf[(size_t)c * slen]; }
    setup_source(l, l->src, l->nch, true);
    const bool want = l->pshm != nullptr; // (the first block size seen: a Play asked for before it starts now)
    setup_source(l, l->psrc, 2, want);
    l->pstream.store(want);
    for (int i = 0; i < l->nslots; ++i) setup_sink(l, *l->slots[i]);
    l->skip_in.store(0); l->skip_out.store(0); // (set up anew: nothing to make up for)
  }
  if (peers) {
    const std::vector<std::string> names = split(list);
    for (size_t k = 0; k < next.size(); ++k) {
      if (next[k]) { setup_sink(l, *next[k]); continue; }
      for (int i = 0; i < l->nslots; ++i)
        if (l->slots[i] && l->slots[i]->resolved && l->slots[i]->peer == names[k]) { next[k] = std::move(l->slots[i]); break; }
    }
    for (int i = 0; i < l->nslots; ++i) if (l->slots[i]) drop_slot(l, *l->slots[i]);
    l->nslots = (int)next.size();
    for (int i = 0; i < RT_MAX_PEERS; ++i) l->slots[i] = i < l->nslots ? std::move(next[(size_t)i]) : nullptr;
    for (int i = 0; i < l->nslots; ++i) {
      Slot &p = *l->slots[i];
      if (!p.resolved) continue;
      AooEndpoint ep = { &p.addr, (AooAddrSize)sizeof(p.addr), p.remote_sink_id }, pep = { &p.addr, (AooAddrSize)sizeof(p.addr), p.premote_id };
      if (!p.added) p.added = l->src->addSink(ep, kAooTrue) == kAooOk;
      if (!p.padded) p.padded = l->psrc->addSink(pep, kAooTrue) == kAooOk; // (nothing goes to it while Play has no stream: AooSource::send)
      AooEndpoint mep = { &p.addr, (AooAddrSize)sizeof(p.addr), p.mremote_id };
      if (!p.madded && p.msrc) p.madded = p.msrc->addSink(mep, kAooTrue) == kAooOk;
    }
    Slot *h = l->hub_peer.load(); // (my hub left the list: back to everyone's own streams; hub_watch finds it again by name)
    bool kept = false;
    for (int i = 0; i < l->nslots; ++i) kept = kept || l->slots[i].get() == h;
    if (!kept) { l->hub_peer.store(nullptr); l->hub_state.store(0); }
  }
  if (serving || audio || peers) { // (the ring: one block per callback of every peer's Talk and Play, L and R, then this computer's own)
    l->serve = serve;
    l->hstride = (size_t)(l->nslots + 1) * 4 * (size_t)std::max(l->cfg_len, 1);
    l->hring.assign((serve || !l->hring.empty()) && l->cfg_len > 0 ? HUB_RING * l->hstride : 0, 0.f); // (kept once used: see the no-pause case above)
    l->htime.assign(HUB_RING, 0);
    l->hmix.assign((size_t)2 * std::max(l->cfg_len, 1), 0.f);
    l->hmixptr[0] = &l->hmix[0];
    l->hmixptr[1] = &l->hmix[(size_t)std::max(l->cfg_len, 1)];
    l->hw.store(0); l->hr.store(0);
    bool any = false; // (the listeners' mixes go on through a new peer list: a bandmate joining doesn't send everyone back to direct streams)
    for (int i = 0; i < l->nslots; ++i) any = any || l->slots[i]->mserving;
    l->hserve.store(serve && any && !l->hring.empty());
  }
  l->live.store(l->cfg_sr > 0);
}

// Talkback (rt_send with a peer): a peer left out stops getting this computer's stream (AOO deactivates that sink; let back in, its jitter buffer
// refills, a few tens of ms). The send thread's, as every change to the source. (James, rt)
// The hub's live mix: a peer that hears through a hub (its 'M', fresh) gets neither stream from here directly (the hub has them, this one's
// too when it's the hub); stale or saying otherwise, it gets them again at once.
bool hears_direct(const Slot &p, double now) { return !(p.via_hub.load() && now - p.mode_at.load() < MODE_FRESH); }
// A stream turned back on for a peer starts a new decoder there, and Opus (CELT) codes each frame's band energies against the last one's, so a
// decoder joining mid-stream rose to full level over ~100 ms (measured: 3% of the level 5 ms in, 64% at 45 ms). For INTRA_S after, every frame
// is coded on its own (OPUS_SET_PREDICTION_DISABLED; the others' decoders take those too, a few more bits for a moment). The send thread's.
const double INTRA_S = 0.1;
void intra(RtLink *l, AooSource *src, bool on)
{
  opus_int32 v = on ? 1 : 0;
  src->codecControl(kAooCodecOpus, OPUS_SET_PREDICTION_DISABLED_REQUEST, 0, &v, sizeof(v)); // (an AOO built before its one patch: refused, no harm)
}
void apply_sends(RtLink *l)
{
  const double now = now_s();
  for (int i = 0; i < l->nslots; ++i) {
    Slot &p = *l->slots[i];
    const bool direct = hears_direct(p, now), want = p.want_send.load() && direct;
    if (p.added && want != p.sending) {
      AooEndpoint ep = { &p.addr, (AooAddrSize)sizeof(p.addr), p.remote_sink_id };
      if (l->src->activate(ep, want ? kAooTrue : kAooFalse) == kAooOk) p.sending = want;
      if (want) { intra(l, l->src, true); l->intra_until = now + INTRA_S; }
    }
    if (p.padded && direct != p.psending) { // (talkback is Talk's: Play follows only the hub)
      AooEndpoint ep = { &p.addr, (AooAddrSize)sizeof(p.addr), p.premote_id };
      if (l->psrc->activate(ep, direct ? kAooTrue : kAooFalse) == kAooOk) p.psending = direct;
      if (direct) { intra(l, l->psrc, true); l->intra_until = now + INTRA_S; }
    }
  }
  if (l->intra_until > 0 && now > l->intra_until) { intra(l, l->src, false); intra(l, l->psrc, false); l->intra_until = 0; }
}

// ---- the hub's live mix (rt_hub; the send thread's) -------------------------------------------------------------------------------------
// A control datagram: "SSX1" + kind + payload + the tag, to one peer (the send thread only: txbuf is its).
void send_ctl(RtLink *l, const Slot &p, char kind, const unsigned char *d, int n)
{
  if (l->key.empty() || !p.resolved || n < 0 || 5 + n + TAG > MAX_DGRAM) return;
  memcpy(l->txbuf, CTL, 4);
  l->txbuf[4] = (unsigned char)kind;
  if (n) memcpy(l->txbuf + 5, d, (size_t)n);
  unsigned char t[32];
  tag_of(l->key, l->txbuf, 5 + (size_t)n, t);
  memcpy(l->txbuf + 5 + n, t, TAG);
  if (send_to(l, l->txbuf, 5 + n + TAG, p.addr) > 0) l->sent.fetch_add(1, std::memory_order_relaxed);
}
void put_addr(std::vector<unsigned char> &o, const sockaddr_in &a) // (4 bytes of address, 2 of port, both as they are on the wire)
{
  const unsigned char *b = (const unsigned char *)&a.sin_addr.s_addr, *q = (const unsigned char *)&a.sin_port;
  o.insert(o.end(), b, b + 4);
  o.insert(o.end(), q, q + 2);
}
void put_f32(std::vector<unsigned char> &o, float v) { unsigned char b[4]; memcpy(b, &v, 4); o.insert(o.end(), b, b + 4); }

// A listener: asks its hub for its mix ('R': every bandmate's Talk and Play level here, mute as 0, and whom its Talk mustn't reach: talkback),
// switches to it once it has flowed ENTER_S, and back to everyone's own streams the moment it stops coming (no mix datagram for its buffer
// + GONE_PAD), telling everyone ('M') either way. A computer that serves never hears through another (every hub hears everyone directly).
void hub_watch(RtLink *l, double now)
{
  std::string name;
  { std::lock_guard<std::mutex> g(l->pend_mx); name = l->want_hub; }
  Slot *h = nullptr;
  if (!l->serve) for (int i = 0; i < l->nslots && !name.empty(); ++i) if (l->slots[i]->resolved && l->slots[i]->peer == name) h = l->slots[i].get();
  const int was = l->hub_state.load();
  int st = was;
  bool via = false; // (what everyone is told: true, my streams come through the hub; false, send them to me)
  if (h != l->hub_peer.load()) { l->hub_peer.store(h); st = 0; l->retry_at = 0; }
  // A pass WATCH_LATE late: this thread didn't run, so the mix's age waits for the receive thread's turn from here. Once per silence: a late
  // pass with no mix datagram since the last such pass doesn't wait again, so a send thread that's late on every pass (a loaded machine)
  // still falls back on a mix that really stopped, WATCH_LATE + gone after the first.
  const double lag = now - l->watch_at;
  l->watch_at = now;
  if (lag > WATCH_LATE && lag < 10.0) {
    ++l->stalls;
    l->stall_max = std::max(l->stall_max, lag);
    if (!h || h->mix_at.load() > l->watch_free) l->watch_free = now;
  }
  if (!h) st = 0;
  else {
    const double raw = now - h->mix_at.load();
    // (hearing it: the age counts from a late pass's WATCH_LATE on, for rescues as for falling back. Joining keeps the raw age: a mix that
    // never came can't look like it's flowing)
    const double gone = std::max(GONE_MIN, h->target_ms + GONE_PAD) / 1000.0, quiet = st == 2 ? std::min(raw, std::max(0.0, now - l->watch_free - WATCH_LATE)) : raw;
    const bool flowing = quiet < gone;
    if (st == 2 && !flowing) { st = 0; ++l->fallbacks; l->retry_at = now + RETRY_S; } // (the hub dropped, or stopped mixing for me: direct at once)
    else if (st != 2) {
      int ns = now < l->retry_at ? 0 : flowing && now - h->mix_first.load() >= ENTER_S && h->mstreaming ? 2 : 1;
      if (ns == 1 && st != 1) l->join_at = now;
      if (ns == 1 && now - l->join_at > JOIN_S) { ns = 0; ++l->join_fails; l->retry_at = now + JOIN_RETRY_S; } // (no mix answered: asked again later)
      st = ns;
    }
    via = st == 2 && quiet < std::max(std::max(RESCUE_MIN, h->target_ms - RESCUE_LEAD), h->mix_gap.load() * 1000 + RESCUE_PAD) / 1000.0;
    if (st == 2 && !via && l->via_said) ++l->rescues;
  }
  // Who's in the hub's mix (its 'H'): only they're told my streams come through it, and only their own streams are left out here. One the hub
  // doesn't hear (its peer list leaves them out: the four-computer test, the Mac's list without the desktop) keeps sending to me directly, so
  // through a hub nobody goes unheard (the laptop heard nothing of the desktop: the desktop stopped sending to it, the Mac's mix hadn't it).
  unsigned mixm = 0;
  if (h) {
    std::lock_guard<std::mutex> g(l->mix_mx);
    for (int i = 0; i < l->nslots; ++i) {
      Slot &p = *l->slots[i];
      bool in = &p == h || !h->heard_ever; // (the hub itself; an older hub that doesn't say: everyone, as before)
      for (size_t k = 0; !in && k < h->heard.size(); ++k) in = same_addr(h->heard[k], p.addr);
      p.in_mix.store(in);
      if (in) mixm |= 1u << i;
    }
  }
  l->hub_state.store(st);
  if (was == 2 && st != 2) l->left_at = now;
  const bool told = via != l->via_said || (via && mixm != l->mix_said); // (the senders hear of it at once)
  l->via_said = via;
  l->mix_said = mixm;
  for (int i = 0; i < l->nslots && (told || st != was); ++i) { // (the underruns this brings aren't jitter: under())
    l->slots[i]->switch_at = now;
    if (st != was) l->slots[i]->mswitch_at = now;
  }
  if (!h && now - l->left_at > MODE_FRESH && !told) return; // (peer to peer, and said so: nothing to say)
  if (now < l->next_ctl && !told) {
    if (!h || st == 0) return;
    std::string sig; // (the levels changed: asked again at once, so a mute or Deafen is heard in one trip)
    for (int i = 0; i < l->nslots; ++i) { char b[48]; snprintf(b, sizeof b, "%.3f,%.3f,%d;", l->slots[i]->gain.load(), l->slots[i]->pgain.load(), (l->slots[i]->mute.load() ? 1 : 0) | (l->slots[i]->want_send.load() ? 0 : 2)); sig += b; }
    if (sig == l->asked_sig) return;
  }
  l->next_ctl = now + MODE_EVERY;
  for (int i = 0; i < l->nslots; ++i) { const unsigned char m = via && (mixm >> i & 1u) ? 1 : 0; send_ctl(l, *l->slots[i], 'M', &m, 1); }
  if (!h || st == 0) return;
  std::vector<unsigned char> r;
  std::string sig;
  r.push_back((unsigned char)l->nslots);
  for (int i = 0; i < l->nslots; ++i) {
    const Slot &p = *l->slots[i];
    const bool m = p.mute.load();
    put_addr(r, p.addr);
    put_f32(r, m ? 0.f : p.gain.load());
    put_f32(r, m ? 0.f : p.pgain.load());
    char b[48]; snprintf(b, sizeof b, "%.3f,%.3f,%d;", p.gain.load(), p.pgain.load(), (m ? 1 : 0) | (p.want_send.load() ? 0 : 2)); sig += b;
  }
  const size_t nd = r.size();
  r.push_back(0);
  for (int i = 0; i < l->nslots; ++i) if (!l->slots[i]->want_send.load()) { put_addr(r, l->slots[i]->addr); ++r[nd]; }
  l->asked_sig = sig;
  send_ctl(l, *h, 'R', r.data(), (int)r.size());
}

// The hub: a listener that asked within MODE_FRESH gets its mix: from the ring (every peer's block as decoded here), at that listener's
// levels, never its own sound, its talkback kept (a sender's Talk left out of the mixes of those it leaves out), and this computer's own
// Talk and Play; encoded through its own source. Its cost is measured (rt_status "hub": load, a share of one core).
void hub_serve(RtLink *l, double now)
{
  const auto t0 = std::chrono::steady_clock::now();
  const double c0 = thread_ticks();
  const int ns = l->nslots, len = l->cfg_len;
  int n = 0;
  {
    std::lock_guard<std::mutex> g(l->mix_mx);
    for (int i = 0; i < ns; ++i) {
      Slot &p = *l->slots[i];
      const bool want = l->serve && !l->hring.empty() && p.msrc && p.madded && now - p.asked_at < MODE_FRESH;
      if (want != p.mserving) { if (want) p.msrc->startStream(0, nullptr); else p.msrc->stopStream(0); p.mserving = want; }
      n += want ? 1 : 0;
    }
  }
  if (n > 0 && !l->hserve.load()) { l->hr.store(l->hw.load()); l->hserve.store(true); } // (from now on: nothing older)
  if (n == 0) {
    l->hserve.store(false);
    if (l->hub_serving) { std::lock_guard<std::mutex> st(l->stats_mx); l->hub_serving = 0; l->hub_load = l->hub_ns = l->hub_audio_s = l->hub_cpu = l->hub_tick0 = 0; } // (no stale load once it stops)
    return;
  }
  // each listener's levels, by where each sound is in the ring (k: a peer's slot; ns: this computer's own)
  std::vector<float> gt((size_t)ns * (ns + 1), 0.f), gp((size_t)ns * (ns + 1), 0.f);
  {
    std::lock_guard<std::mutex> g(l->mix_mx);
    for (int li = 0; li < ns; ++li) {
      Slot &L = *l->slots[li];
      if (!L.mserving) continue;
      for (int k = 0; k <= ns; ++k) {
        if (k == li) continue; // (never your own sound back)
        const sockaddr_in &a = k < ns ? l->slots[k]->addr : l->me;
        float t = 1, pl = 1; // (a bandmate the listener didn't list yet: full level, as peer to peer starts)
        for (const Slot::Level &v : L.levels) if (same_addr(v.a, a)) { t = v.talk; pl = v.play; break; }
        bool denied = k == ns ? !L.want_send.load() : false; // (talkback: this computer's own Talk, or a sender's, left out of this listener's mix)
        if (k < ns) for (const sockaddr_in &d : l->slots[k]->deny) denied = denied || same_addr(d, L.addr);
        gt[(size_t)li * (ns + 1) + k] = denied ? 0.f : t;
        gp[(size_t)li * (ns + 1) + k] = pl;
      }
    }
  }
  if (now < l->hold_mix.load()) return; // (rt_test_hold_mix: the mixing stalls, the ring fills, as when the send thread is held up)
  const uint64_t w = l->hw.load(std::memory_order_acquire);
  uint64_t r = l->hr.load();
  const uint64_t blocks = w - r;
  for (; r < w; ++r) {
    const float *rec = &l->hring[(size_t)(r % HUB_RING) * l->hstride];
    const AooNtpTime t = l->htime[(size_t)(r % HUB_RING)];
    for (int li = 0; li < ns; ++li) {
      Slot &L = *l->slots[li];
      if (!L.mserving) continue;
      float *mL = l->hmixptr[0], *mR = l->hmixptr[1];
      std::fill(mL, mL + len, 0.f);
      std::fill(mR, mR + len, 0.f);
      for (int k = 0; k <= ns; ++k) {
        const float a = gt[(size_t)li * (ns + 1) + k], b = gp[(size_t)li * (ns + 1) + k];
        const float *s = rec + (size_t)k * 4 * len;
        if (a > 0) for (int j = 0; j < len; ++j) { mL[j] += a * s[j]; mR[j] += a * s[len + j]; }
        if (b > 0) for (int j = 0; j < len; ++j) { mL[j] += b * s[2 * len + j]; mR[j] += b * s[3 * len + j]; }
      }
      if (L.msrc->process(l->hmixptr, len, t) == kAooErrorOverflow) L.msrc->reset(); // (behind: as Talk's source, tx_loop)
      // (the encode, most of the cost, after every block: a backlog of blocks (the send thread held up) went into the source's queue all at
      // once and overflowed it, and the reset lost that audio: a gap in every listener's mix, and their streams asked back)
      L.msrc->send(send_fn, l);
    }
  }
  l->hr.store(w, std::memory_order_release);
  const double ns_took = (double)std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - t0).count();
  const double c1 = thread_ticks();
  std::lock_guard<std::mutex> st(l->stats_mx);
  l->hub_serving = n;
  l->hub_ns += ns_took;
  l->hub_cpu += c0 >= 0 && c1 >= c0 ? c1 - c0 : -1e300; // (no thread time: the window falls back to the clock)
  l->hub_audio_s += (double)blocks * len / std::max(1, l->cfg_sr);
  if (blocks) l->hub_max_us = std::max(l->hub_max_us, ns_took / 1000.0 / (double)blocks);
  if (now - l->hub_win >= 1.0) { // (its share of one core over the last second or so, and the hub's numbers to each listener: 'I')
    const double tk = ticks_now(), per_ns = l->hub_tick0 > 0 ? (tk - l->hub_tick0) / ((now - l->hub_win) * 1e9) : 0; // (thread ticks per ns)
    const double wall = l->hub_audio_s > 0 ? l->hub_ns / 1e9 / l->hub_audio_s : 0;
    // its own CPU time; never more than the clock's (a tick rate gone wrong), and the clock's for the first window or without thread time
    l->hub_load = per_ns > 0 && l->hub_cpu >= 0 && l->hub_audio_s > 0 ? std::min(wall, l->hub_cpu / per_ns / 1e9 / l->hub_audio_s) : wall;
    l->hub_ns = l->hub_audio_s = l->hub_cpu = 0;
    l->hub_win = now;
    l->hub_tick0 = tk;
  }
  if (now >= l->next_info) {
    l->next_info = now + MODE_EVERY;
    double in = 0;
    int m = 0;
    for (int i = 0; i < ns; ++i) {
      const Slot &p = *l->slots[i];
      if (p.streaming && p.rtt_ms >= 0 && p.buffer_ms >= 0) { in += p.rtt_ms / 2 + p.buffer_ms + p.src_lat_ms + p.sink_lat_ms; ++m; }
    }
    std::vector<unsigned char> d;
    put_f32(d, m ? (float)(in / m) : -1.f);
    put_f32(d, (float)l->hub_load);
    std::vector<unsigned char> hd(1, 0); // ('H': whom the mix has, the peers whose Talk or Play comes in here now, so each listener tells only them)
    for (int i = 0; i < ns; ++i) if (l->slots[i]->streaming || l->slots[i]->pstreaming) { put_addr(hd, l->slots[i]->addr); ++hd[0]; }
    for (int i = 0; i < ns; ++i) if (l->slots[i]->mserving) { send_ctl(l, *l->slots[i], 'I', d.data(), (int)d.size()); send_ctl(l, *l->slots[i], 'H', hd.data(), (int)hd.size()); }
  }
}

// A control datagram from a peer (the receive thread, cfg_mx held, its tag checked): 'M' how it hears, 'R' its mix (to me as its hub),
// 'I' its numbers as my hub. Anything malformed is dropped.
void handle_ctl(RtLink *l, Slot &p, const unsigned char *d, int n, double now)
{
  if (n < 1) return;
  const char kind = (char)d[0];
  ++d; --n;
  if (kind == 'M' && n == 1) { p.via_hub.store(d[0] == 1); p.mode_at.store(now); l->wake.set(); return; }
  if (kind == 'I' && n == 8) { float a, b; memcpy(&a, d, 4); memcpy(&b, d + 4, 4); if (std::isfinite(a) && std::isfinite(b)) { p.hin_ms.store(a); p.hload.store(b); } return; }
  if (kind == 'H') { // (whom its mix has, as my hub: a count, then each address and port)
    if (n < 1 || d[0] > RT_MAX_PEERS || n != 1 + d[0] * 6) return;
    std::vector<sockaddr_in> hv;
    for (int i = 0; i < d[0]; ++i) {
      sockaddr_in a{};
      a.sin_family = AF_INET;
      memcpy(&a.sin_addr.s_addr, d + 1 + i * 6, 4);
      memcpy(&a.sin_port, d + 1 + i * 6 + 4, 2);
      hv.push_back(a);
    }
    std::lock_guard<std::mutex> g(l->mix_mx);
    p.heard.swap(hv);
    p.heard_ever = true;
    l->wake.set();
    return;
  }
  if (kind != 'R' || n < 2 || d[0] > RT_MAX_PEERS) return;
  const int nl = d[0];
  if (n < 1 + nl * 14 + 1) return;
  const int nd = d[1 + nl * 14];
  if (nd > RT_MAX_PEERS || n != 1 + nl * 14 + 1 + nd * 6) return;
  std::vector<Slot::Level> lv;
  for (int i = 0; i < nl; ++i) {
    const unsigned char *e = d + 1 + i * 14;
    Slot::Level v{};
    v.a.sin_family = AF_INET;
    memcpy(&v.a.sin_addr.s_addr, e, 4);
    memcpy(&v.a.sin_port, e + 4, 2);
    memcpy(&v.talk, e + 6, 4);
    memcpy(&v.play, e + 10, 4);
    v.talk = std::isfinite(v.talk) ? std::max(0.f, std::min(4.f, v.talk)) : 1.f;
    v.play = std::isfinite(v.play) ? std::max(0.f, std::min(4.f, v.play)) : 1.f;
    lv.push_back(v);
  }
  std::vector<sockaddr_in> dn;
  for (int i = 0; i < nd; ++i) {
    sockaddr_in a{};
    a.sin_family = AF_INET;
    memcpy(&a.sin_addr.s_addr, d + 1 + nl * 14 + 1 + i * 6, 4);
    memcpy(&a.sin_port, d + 1 + nl * 14 + 1 + i * 6 + 4, 2);
    dn.push_back(a);
  }
  std::lock_guard<std::mutex> g(l->mix_mx);
  p.levels.swap(lv);
  p.deny.swap(dn);
  p.asked_at = now;
}

// The adaptive jitter buffer (James, rt). Wi-Fi delivers in bursts (the MacBook: nothing for 20-60 ms, then all of it at once), and a fixed
// 30 ms buffer underran there twice a second, the stream flapping on every receiver. AOO's own latency setting does the work
// (AooSink::setLatency, kAooCtlSetLatency: the sink re-buffers its stream at the new size), so:
//  - it grows (+10 ms, up to the ceiling) on an underrun: that is already a gap while AOO buffers again, so re-buffering a little longer
//    there costs nothing more than the gap that was coming anyway;
//  - it shrinks (-10 ms) after BUF_STEADY s with no underrun, then every BUF_STEP s, only into room its streams never used lately (their
//    measured fill at its lowest, BUF_MARGIN kept: fill_of), not back below a size held after close underruns (BUF_LONE), and only while
//    that peer is quiet: a re-buffer is a short gap, so it lands in silence between songs or phrases, never in a held note. (It was: never
//    below the largest size that underran until 120 s passed with none, so at ~3 underruns a minute every buffer ratcheted to the ceiling.)
//    shortcut: a peer that never goes quiet keeps its bigger buffer; fine for a band.
//  - a stream that finished buffering far above its size (packets stalled, then burst in: the laptop's buffer for the Mac sat at 190 ms
//    against 110; the laptop's for the desktop's Play ~100 ms over, rt-ears) holds that latency for good, and the next burst overran it; what
//    sits above its size is shed (TRIM_OVER, "trims"): rt_mix skips it, crossfading the block before the skip into the one after, so it
//    needn't wait for quiet (it was a re-buffer, a gap, while quiet only; and each re-buffer could finish high again).
// rt_mix fades sound back in after any gap, so none of this clicks. The send thread's, under stats_mx.
// A stream's buffer, measured: AOO's fill ratio (frames held plus what's in its resampler, over its capacity) x that capacity, which AOO makes
// the larger of its latency and the buffer size size_sink gives (CAP_HEAD more), in Opus frames, from each as a float (aoo/src/sink.cpp,
// source_desc::update). -1: no such stream now.
double fill_of(RtLink *l, AooSink *s, const sockaddr_in &a, AooId id, double target_ms)
{
  double r = -1;
  AooEndpoint ep = { &a, (AooAddrSize)sizeof(a), id };
  if (!s || l->cfg_sr <= 0 || s->getBufferFillRatio(ep, r) != kAooOk || r < 0) return -1;
  const double lat = (float)(target_ms / 1000.0), per = 1000.0 / OPUS_MS, least = std::ceil((double)l->cfg_len / OPUS_FRAME * 48000.0 / l->cfg_sr);
  const double cap = (float)((target_ms + CAP_HEAD) / 1000.0);
  return r * std::max(std::max(std::ceil(lat * per), least), std::ceil(cap * per)) * OPUS_MS;
}
void adapt(RtLink *l, Slot &p, double now)
{
  if (!p.sink) return;
  const double sp = l->speed;
  if (p.loud.exchange(0.f) >= BUF_QUIET) p.quiet_since = -1;
  else if (p.quiet_since < 0) p.quiet_since = now;
  const bool quiet = p.quiet_since >= 0 && now - p.quiet_since > BUF_QUIET_S;
  struct Stream { AooSink *s; AooId id; bool on; Low *lw; } st[3] = { { p.sink, SRC_ID, p.streaming, &p.lt }, { p.psink, PLAY_ID, p.pstreaming, &p.lp },
                                                                     { p.msink, MIX_ID, p.mstreaming, &p.lm } };
  for (Stream &x : st) { // (each stream's buffer while it plays, and its lowest lately)
    const double f = x.on ? fill_of(l, x.s, p.addr, x.id, p.target_ms) : -1;
    if (f < 0) x.lw->reset(now);
    else x.lw->add(f, now, BUF_STEP / 2 / sp);
    if (x.id == SRC_ID || p.fill_ms < 0) p.fill_ms = f; // (a listener through a hub hears the mix: Talk's is -1)
    if (x.id == PLAY_ID) p.pfill_ms = f;
  }
  for (int k = 0; k < 3; ++k) { // (far above its size for a whole stretch: shed down to its size, rt_mix's crossfaded skip)
    Stream &x = st[k];
    if (!x.on) { p.shed[k].store(0); continue; } // (a skip asked for a stream that stopped would cut into its next start)
    const double lo = x.lw->low();
    if (lo < 0 || lo < p.target_ms + TRIM_OVER) continue;
    p.shed[k].store((int)(std::min(lo - p.target_ms, 1000.0) * l->cfg_sr / 1000.0));
    ++p.trims;
    if (x.id == PLAY_ID) ++p.ptrims;
    x.lw->reset(now);
  }
  double want = p.target_ms;
  if (p.jitter + p.pjitter + p.mjitter != p.jitter_seen) { // (Talk's, Play's or its mix's: one buffer size for all, they come over the same network)
    p.jitter_seen = p.jitter + p.pjitter + p.mjitter;
    const bool back = now - p.last_retry < p.retry_s / sp; // (it went back below a held size too soon)
    if (now - p.last_under > BUF_LONE / sp && !back) ++p.lone; // (a lone spike: grown a step, not held)
    else {
      if (back) p.retry_s = std::min(p.retry_s * 2, BUF_RETRY_MAX);
      p.fail_ms = now < p.hold_until ? std::max(p.fail_ms, p.target_ms) : p.target_ms;
      p.hold_until = now + p.retry_s / sp;
    }
    p.last_under = now;
    want = p.target_ms + BUF_GROW;
  } else if (now - p.last_under > BUF_STEADY / sp && now - p.last_change > BUF_STEP / sp && quiet) {
    bool known = true;
    double room = 1e9;
    for (const Stream &x : st) if (x.on) { const double lo = x.lw->low(); if (lo < 0) known = false; else room = std::min(room, lo); }
    if (known && room >= BUF_SHRINK + BUF_MARGIN)
      want = std::max(p.target_ms - BUF_SHRINK, now < p.hold_until ? p.fail_ms + BUF_SHRINK : p.floor_ms);
    if (p.fail_ms > 0 && want < p.fail_ms + BUF_SHRINK && want < p.target_ms) p.last_retry = now; // (below a held size: watched)
    if (now - p.last_under > BUF_CALM / sp) p.retry_s = BUF_RETRY;
  }
  want = std::max(p.floor_ms, std::min(p.ceil_ms, want));
  if (want == p.target_ms) return;
  p.target_ms = want;
  p.last_change = now;
  size_sink(p.sink, want);
  size_sink(p.psink, want);
  size_sink(p.msink, want);
  for (Stream &x : st) x.lw->reset(now); // (re-buffered: measured again from here)
}

void tx_loop(RtLink *l)
{
  full_speed();
  while (l->run.load()) {
    l->wake.wait_for(0.005);
    while (now_s() < l->hold_tx.load()) std::this_thread::sleep_for(std::chrono::milliseconds(1)); // (rt_test_hold_tx: 1 ms sleeps, as rx_loop's hold)
    reconfigure(l);
    apply_sends(l);
    if (!l->live.load()) continue;
    // AOO's source (v2.0-pre4, source.cpp process) reblocks REAPER's blocks into Opus frames through its resampler, and when the
    // send thread falls behind (a stall of ~60 ms on the macOS CI runner) both the resampler and the queue fill. From then on
    // process() gives up on the full resampler before moving it into the queue, so nothing is ever sent again: that peer goes silent
    // for good (C never heard after its secret was fixed, A silent on B). Emptying both, as AOO's own reset does, ends that; the
    // late audio is lost either way. (James, rt)
    if (l->overflow.exchange(false)) { l->src->reset(); std::lock_guard<std::mutex> g(l->stats_mx); ++l->overflows; }
    if (l->poverflow.exchange(false)) { l->psrc->reset(); std::lock_guard<std::mutex> g(l->stats_mx); ++l->overflows; }
    const double tnow = now_s();
    hub_watch(l, tnow); // (the hub's live mix: as a listener, then as the hub)
    hub_serve(l, tnow);
    l->src->send(send_fn, l);
    l->psrc->send(send_fn, l);
    for (int i = 0; i < l->nslots; ++i) {
      if (l->slots[i]->sink) l->slots[i]->sink->send(send_fn, l);
      if (l->slots[i]->psink) l->slots[i]->psink->send(send_fn, l);
      if (l->slots[i]->msink) l->slots[i]->msink->send(send_fn, l);
    }
    std::lock_guard<std::mutex> g(l->stats_mx);
    l->src->pollEvents();
    for (int i = 0; i < l->nslots; ++i) {
      if (l->slots[i]->sink) l->slots[i]->sink->pollEvents();
      if (l->slots[i]->psink) l->slots[i]->psink->pollEvents();
      if (l->slots[i]->msink) l->slots[i]->msink->pollEvents();
    }
    const double now = now_s();
    for (int i = 0; i < l->nslots; ++i) {
      Slot &p = *l->slots[i];
      adapt(l, p, now);
      const double lat = p.rtt_ms >= 0 && p.buffer_ms >= 0 ? p.rtt_ms / 2 + p.buffer_ms + p.src_lat_ms + p.sink_lat_ms : -1;
      if (p.streaming && lat >= 0 && l->hub_state.load() != 2) p.last_direct_ms = lat; // (what the hub's hop adds is measured against this)
    }
  }
}

void reject(RtLink *l, const char *why, const sockaddr_in &from) // (and from where: the status names the sender, so a refusal can be traced)
{
  l->rejected.fetch_add(1, std::memory_order_relaxed);
  std::lock_guard<std::mutex> g(l->stats_mx);
  l->last_reject = why;
  l->last_reject_from = addr_str(from);
}
// Signed with the studio's secret but from an address not on this computer's peer list: a studio computer that lists this one while this one
// doesn't list it (Live sync's room here leaves it out for now: its status file old here, another song or room, a list being changed, or its
// names still resolving at the start). Dropped all the same, but not a refusal: Health read it as "refused 13589 (not one of the studio's
// computers here)" from the laptop's own address. Counted apart (not_here), with the last sender.
// Each one is kept apart too (not_here_peers in the status): Live sync adds a studio computer that sends here to its list (lib/liveaudio.lua
// heard_merge), so a room that's late to list it doesn't make the audio one-way. rt-roomlist
const size_t NH_MAX = 16;
void not_here(RtLink *l, const sockaddr_in &from)
{
  l->not_here.fetch_add(1, std::memory_order_relaxed);
  const double now = now_s();
  std::lock_guard<std::mutex> g(l->stats_mx);
  l->not_here_from = addr_str(from);
  RtLink::NotHere *e = nullptr;
  for (auto &x : l->nh) if (same_addr(x.a, from)) e = &x;
  if (!e && l->nh.size() < NH_MAX) { l->nh.push_back({ from, now, 0 }); e = &l->nh.back(); }
  if (!e) { e = &l->nh[0]; for (auto &x : l->nh) if (x.at < e->at) e = &x; *e = { from, now, 0 }; }
  e->at = now;
  ++e->n;
}
// One datagram from a peer: from the socket (rx_loop) or opened by the connection without Tailscale (rt_nat_rx, libjuice's thread). The
// AOO calls happen under cfg_mx either way, so the two never run them at once.
void rx_one(RtLink *l, const unsigned char *d, int n, const sockaddr_in &from)
{
  l->received.fetch_add(1, std::memory_order_relaxed);
  if (!peer_ok(l, from)) { reject(l, synthetic(from) ? "not reached without Tailscale now" : "not a Tailscale address", from); return; }
  if (n >= 4 && memcmp(d, "SSH1", 4) == 0) { // (a hop's audio, extension/hopnet.cpp: same port, its own tag and key)
    l->extra_in.fetch_add(1);
    if (rt_extra_fn fn = l->extra.load()) fn(l->extra_user.load(), d, n, &from, (int)sizeof(from));
    l->extra_in.fetch_sub(1);
    return;
  }
  if (n >= 5 + TAG && memcmp(d, CTL, 4) == 0) { // (the hub's live mix: a control datagram, tagged as the rest)
    std::lock_guard<std::mutex> g(l->cfg_mx);
    if (l->key.empty()) { reject(l, "no studio secret here yet", from); return; }
    unsigned char t[32];
    tag_of(l->key, d, (size_t)n - TAG, t);
    if (!same_tag(t, d + n - TAG)) { reject(l, "wrong studio secret", from); return; }
    Slot *p = slot_of(l, from);
    if (!p) { not_here(l, from); return; }
    p->rx_at.store(now_s(), std::memory_order_relaxed);
    handle_ctl(l, *p, d + 4, n - 4 - TAG, now_s());
    return;
  }
  if (n < 4 + TAG + 4 || memcmp(d, MAGIC, 4) != 0) { reject(l, "not StudioSync audio", from); return; }
  const AooByte *msg = d + 4;
  const AooInt32 size = n - 4 - TAG;
  {
    std::lock_guard<std::mutex> g(l->cfg_mx);
    if (l->key.empty()) { reject(l, "no studio secret here yet", from); return; }
    unsigned char t[32];
    tag_of(l->key, d, (size_t)n - TAG, t);
    if (!same_tag(t, d + n - TAG)) { reject(l, "wrong studio secret", from); return; }
    AooMsgType type;
    AooId id;
    AooInt32 onset;
    if (aoo_parsePattern(msg, size, &type, &id, &onset) != kAooOk) { reject(l, "not an AOO message", from); return; }
    Slot *p = slot_of(l, from);
    if (!p) { not_here(l, from); return; }
    p->rx_at.store(now_s(), std::memory_order_relaxed);
    if (type == kAooMsgTypeSink && id == p->sink_id && p->sink) p->sink->handleMessage(msg, size, &from, (AooAddrSize)sizeof(from));
    else if (type == kAooMsgTypeSink && id == p->psink_id && p->psink) p->psink->handleMessage(msg, size, &from, (AooAddrSize)sizeof(from));
    else if (type == kAooMsgTypeSource && id == SRC_ID && l->src) l->src->handleMessage(msg, size, &from, (AooAddrSize)sizeof(from));
    else if (type == kAooMsgTypeSource && id == PLAY_ID && l->psrc) l->psrc->handleMessage(msg, size, &from, (AooAddrSize)sizeof(from));
    else if (type == kAooMsgTypeSink && id == p->msink_id && p->msink) { // (my hub's mix for me: when it last came, and since when unbroken)
      const double now = now_s(), since = now - p->mix_at.load();
      if (since > 0.1) p->mix_first.store(now);
      // (the widest spacing in the last 5-10 s: how long a pause is only jitter. It left out gaps over 0.1 s and faded in ~1 s, so a link that
      // stalls ~0.1 s every second or two (the Mac's, through the desktop's mix: Wi-Fi) asked everyone's streams back each time: 40 rescues a
      // minute with the hub steady)
      if (since < 1.0) {
        if (now - p->gap_at > GAP_SPAN) { p->gap_prev = p->gap_cur; p->gap_cur = 0; p->gap_at = now; }
        p->gap_cur = std::max(p->gap_cur, since);
        p->mix_gap.store(std::max(p->gap_cur, p->gap_prev));
      }
      p->mix_at.store(now);
      p->msink->handleMessage(msg, size, &from, (AooAddrSize)sizeof(from));
    } else if (type == kAooMsgTypeSource && id == MIX_ID && p->msrc) p->msrc->handleMessage(msg, size, &from, (AooAddrSize)sizeof(from));
    else { reject(l, "for a stream that isn't theirs", from); return; }
  }
  l->wake.set(); // (replies and resend requests go out now)
}
void rx_loop(RtLink *l)
{
  full_speed();
  std::vector<unsigned char> buf(AOO_MAX_PACKET_SIZE + 64);
  while (l->run.load()) {
    const double hold = l->hold_until.load() - now_s();
    if (hold > 0) { std::this_thread::sleep_for(std::chrono::milliseconds(1)); continue; } // (the socket keeps what comes meanwhile; short sleeps: a VM's long ones overshoot)
    sockaddr_in from{};
    socklen_t fl = sizeof(from);
    const int n = (int)recvfrom(l->s, (char *)buf.data(), (int)buf.size(), 0, (sockaddr *)&from, &fl);
    if (n <= 0 || fl < (socklen_t)sizeof(from)) continue; // (the receive timeout: a look at run)
    rx_one(l, buf.data(), n, from);
  }
}
} // namespace

RtLink *rt_new() { return new RtLink(); }
void rt_set_nat(RtLink *l, const RtNat *nat) { if (l) l->nat.store(nat); }
void rt_nat_rx(RtLink *l, const unsigned char *d, int n, const void *from)
{
  if (!l || !l->run.load() || n <= 0) return;
  const sockaddr_in &a = *(const sockaddr_in *)from;
  if (!synthetic(a)) return; // (only what nat.cpp opened, named by its synthetic address)
  rx_one(l, d, n, a);
}
void rt_free(RtLink *l)
{
  if (!l) return;
  rt_stop(l);
  if (l->ears.thr.joinable()) l->ears.thr.join(); // (a tap that finished on its own)
  for (const hop_map &m : l->pnames) hop_shm_unlink(&m); // (the live out mappings' POSIX names; the plug-in's open one stays valid)
  delete l;
}

int rt_start(RtLink *l, int first_input, int nch, int kbps, int port, const char *bind_ip)
{
  std::lock_guard<std::mutex> g(l->api_mx);
  if (l->run.load()) return 1;
  l->err.clear();
  if (port == 0) { std::lock_guard<std::mutex> p(l->pend_mx); port = l->want_port > 0 ? l->want_port : DIRECT_PORT; }
  if (first_input < 0 || nch < 1 || nch > RT_MAX_CH || port <= 0 || port > 65535) { l->err = "bad arguments"; return 0; }
  std::call_once(g_aoo_once, [] { aoo_initialize(nullptr); });
#ifdef _WIN32
  static bool wsa = false;
  if (!wsa) { WSADATA w; wsa = WSAStartup(MAKEWORD(2, 2), &w) == 0; }
#endif
  std::string ip = bind_ip && *bind_ip ? std::string(bind_ip) : tailscale_ip();
  const RtNat *nat = l->nat.load();
  l->nat_only = ip.empty() && nat && nat->active(nat->h); // (no Tailscale here, but bandmates reached without it: they're all that's heard)
  if (l->nat_only) ip = "127.0.0.1";
  if (ip.empty()) { l->err = "Tailscale isn't up here (no 100.64.0.0/10 address)"; return 0; }
  sockaddr_in me{};
  me.sin_family = AF_INET;
  me.sin_port = htons((unsigned short)port);
  if (inet_pton(AF_INET, ip.c_str(), &me.sin_addr) != 1) { l->err = "bad address"; return 0; }
  l->loopback = ip.compare(0, 4, "127.") == 0 && !l->nat_only; // (nat_only: nothing local is taken as a peer)
  if (!l->nat_only && !addr_ok(me, l->loopback)) { l->err = "not a Tailscale address"; return 0; }
  sock_t s = socket(AF_INET, SOCK_DGRAM, 0);
  if (s == BAD_SOCK) { l->err = "no socket"; return 0; }
  direct_noinherit(s);
  if (bind(s, (const sockaddr *)&me, sizeof(me)) != 0) { close_sock(s); l->err = "UDP " + std::to_string(port) + " is taken on " + ip; return 0; }
#ifdef _WIN32
  DWORD tmo = 100;
#else
  timeval tmo = { 0, 100000 };
#endif
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&tmo, sizeof(tmo));
  int big = 1 << 20;
  setsockopt(s, SOL_SOCKET, SO_RCVBUF, (const char *)&big, sizeof(big));
  l->key.clear(); l->have_secret.clear(); // (the send thread takes the secret from the peers JSON)
  l->s = s;
  l->me = me;
  l->bind_s = addr_str(me);
  l->first = first_input; l->nch = nch; l->kbps = std::max(16, std::min(512, kbps)); l->port = port;
  l->cfg_sr = 0; l->cfg_len = 0; l->seen_sr = 0; l->seen_len = 0;
  l->callbacks = 0; l->max_ns = 0; l->sent = 0; l->received = 0; l->rejected = 0; l->last_reject.clear(); l->last_reject_from.clear(); l->not_here = 0; l->not_here_from.clear(); l->nh.clear();
  l->src = AooSource_new(SRC_ID);
  l->src->setEventHandler(source_event, l, kAooEventModePoll);
  l->src->setPacketSize(1200);
  l->psrc = AooSource_new(PLAY_ID); // (no events: Talk's source pings say the round trip and loss)
  l->psrc->setPacketSize(1200);
  tune(l, l->src);
  tune(l, l->psrc);
  l->pauses = l->overflows = 0; l->skipped = 0; l->skip_in = 0; l->skip_out = 0;
  l->phop = 0; l->pstream = false;  // (rt_play's choice is kept: the send thread opens its mapping again)
  { std::lock_guard<std::mutex> p(l->pend_mx); l->peers_dirty = true; } // (the list given before start, if any)
  l->run.store(true);
  l->rx = std::thread(rx_loop, l);
  l->tx = std::thread(tx_loop, l);
  return 1;
}

void rt_stop(RtLink *l)
{
  std::lock_guard<std::mutex> g(l->api_mx);
  if (!l->run.load()) return;
  l->ears.kind.store(0); l->ears.stop.store(true); // (the ears tap ends with what it has)
  if (l->ears.thr.joinable()) l->ears.thr.join();
  pause_audio(l);
  l->run.store(false);
  l->wake.set();
  if (l->tx.joinable()) l->tx.join();
  if (l->rx.joinable()) l->rx.join();
  std::lock_guard<std::mutex> c(l->cfg_mx);
  for (int i = 0; i < l->nslots; ++i) { drop_slot(l, *l->slots[i]); l->slots[i].reset(); }
  l->nslots = 0;
  l->hub_peer.store(nullptr); l->hub_state.store(0); l->mixw = 0; // (rt_hub's choice is kept: the ring is made again when it starts)
  l->hserve.store(false); l->serve = false; l->hub_serving = 0; l->hring.clear();
  if (l->src) AooSource_free(l->src);
  if (l->psrc) AooSource_free(l->psrc);
  l->src = l->psrc = nullptr;
  if (l->pshm) hop_shm_close(&l->pmap);
  l->pshm = nullptr; l->phop = 0; l->pstream = false;
  close_sock(l->s);
  l->s = BAD_SOCK;
}

int rt_peers(RtLink *l, const char *json)
{
  std::string secret, list;
  int port = 0;
  std::vector<std::string> peers;
  if (!json || !parse_peers_json(json, secret, port, peers)) return -1;
  for (const std::string &p : peers) list += p + " ";
  std::lock_guard<std::mutex> g(l->pend_mx);
  l->want_peers = list;
  l->want_secret = secret;
  if (port > 0 && port <= 65535) l->want_port = port;
  l->peers_dirty = true;
  l->wake.set();
  return (int)peers.size();
}

int rt_send(RtLink *l, const char *peer, int on)
{
  if (!peer || !*peer) { l->send_on.store(on != 0); return 1; }
  std::lock_guard<std::mutex> g(l->cfg_mx);
  for (int i = 0; i < l->nslots; ++i)
    if (l->slots[i]->peer == peer) { l->slots[i]->want_send.store(on != 0); l->wake.set(); return 1; }
  return 0;
}

int rt_peer_set(RtLink *l, const char *peer, double gain, int mute)
{
  std::lock_guard<std::mutex> g(l->cfg_mx);
  for (int i = 0; i < l->nslots; ++i) {
    Slot &p = *l->slots[i];
    if (peer && p.peer == peer) { p.gain.store((float)std::max(0.0, std::min(4.0, gain))); p.mute.store(mute != 0); return 1; }
  }
  return 0;
}

int rt_play(RtLink *l, int hop_id, int send)
{
  l->play_send.store(send != 0);
  std::lock_guard<std::mutex> g(l->pend_mx);
  l->want_phop = hop_id >= 1 && hop_id <= 64 ? hop_id : 0;
  l->wake.set();
  return 1;
}

int rt_peer_play(RtLink *l, const char *peer, double gain)
{
  std::lock_guard<std::mutex> g(l->cfg_mx);
  for (int i = 0; i < l->nslots; ++i)
    if (peer && l->slots[i]->peer == peer) { l->slots[i]->pgain.store((float)std::max(0.0, std::min(4.0, gain))); return 1; }
  return 0;
}

int rt_peer_buffer(RtLink *l, const char *peer, double floor_ms, double ceil_ms)
{
  const double f = floor_ms > 0 ? std::max(10.0, std::min(300.0, floor_ms)) : BUF_FLOOR;
  const double c = ceil_ms > 0 ? std::max(f, std::min(500.0, ceil_ms)) : std::max(f, BUF_CEIL);
  std::lock_guard<std::mutex> g(l->cfg_mx);
  std::lock_guard<std::mutex> st(l->stats_mx); // (the send thread's adapt reads them under this; it moves the buffer inside the new bounds)
  for (int i = 0; i < l->nslots; ++i)
    if (peer && l->slots[i]->peer == peer) { l->slots[i]->floor_ms = f; l->slots[i]->ceil_ms = c; return 1; }
  return 0;
}
// The ears tap's worker: drains the ring into a 32-bit float stereo WAV until it has `want` frames (or is stopped, or 15 s past due).
namespace {
void ears_wav(FILE *f, int sr, uint64_t frames) // (RIFF, format 3: what every DAW and scipy read)
{
  auto le = [&](unsigned v, int n) { for (int i = 0; i < n; ++i) fputc((int)(v >> (8 * i)) & 255, f); };
  const unsigned data = (unsigned)(frames * 8);
  fseek(f, 0, SEEK_SET);
  fwrite("RIFF", 1, 4, f); le(36 + data, 4); fwrite("WAVEfmt ", 1, 8, f); le(16, 4);
  le(3, 2); le(2, 2); le((unsigned)sr, 4); le((unsigned)sr * 8, 4); le(8, 2); le(32, 2);
  fwrite("data", 1, 4, f); le(data, 4);
}
FILE *ears_open(const std::string &p)
{
#ifdef _WIN32
  const int n = MultiByteToWideChar(CP_UTF8, 0, p.c_str(), -1, nullptr, 0);
  if (n <= 0) return nullptr;
  std::wstring w((size_t)n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, p.c_str(), -1, &w[0], n);
  return _wfopen(w.c_str(), L"wb");
#else
  return fopen(p.c_str(), "wb");
#endif
}
void ears_loop(RtLink *l, std::string path, uint64_t want, int sr)
{
  Ears &e = l->ears;
  FILE *f = ears_open(path);
  if (!f) { e.kind.store(0); e.state.store(3); return; }
  ears_wav(f, sr, 0);
  uint64_t got = 0;
  bool ok = true;
  const double give_up = now_s() + (double)want / sr + 15;
  while (got < want && !e.stop.load() && now_s() < give_up) {
    const uint64_t r = e.r.load(std::memory_order_relaxed), w = e.w.load(std::memory_order_acquire), n = std::min(w - r, want - got);
    if (!n) { std::this_thread::sleep_for(std::chrono::milliseconds(5)); continue; }
    const uint64_t at = r & (EARS_RING - 1), run = std::min(n, EARS_RING - at); // (up to the ring's end; the next pass goes on from its start)
    ok = fwrite(&e.ring[(size_t)(2 * at)], sizeof(float) * 2, (size_t)run, f) == run && ok;
    e.r.store(r + run, std::memory_order_release);
    got += run;
    e.frames.store((long long)got);
  }
  e.kind.store(0, std::memory_order_release);
  ears_wav(f, sr, got);
  ok = fclose(f) == 0 && ok;
  e.state.store(ok && got == want ? 2 : 3);
}
} // namespace
int rt_ears(RtLink *l, const char *peer, const char *stream, const char *path, double seconds)
{
  if (!l || !peer || !stream || !path || !(seconds > 0) || seconds > EARS_MAX_S) return 0;
  const std::string pth = path, st = stream, who = peer;
  // (a local call only, never from the link; a .wav file, no ".." step: it can't be pointed at anything but a new recording)
  if (pth.size() < 5 || pth.find("..") != std::string::npos) return 0;
  std::string ext = pth.substr(pth.size() - 4);
  for (char &c : ext) c = (char)tolower((unsigned char)c);
  if (ext != ".wav") return 0;
  const int kind = who.empty() ? (st == "play" ? 1 : 0) : st == "talk" ? 2 : st == "play" ? 3 : st == "hub" ? 4 : 0;
  if (!kind) return 0;
  std::lock_guard<std::mutex> g(l->api_mx);
  Ears &e = l->ears;
  if (e.state.load() == 1) return 0; // (one at a time)
  if (e.thr.joinable()) e.thr.join();
  if (!l->run.load() || l->cfg_sr <= 0) return 0;
  sockaddr_in a{};
  if (kind > 1) {
    std::lock_guard<std::mutex> c(l->cfg_mx);
    bool found = false;
    for (int i = 0; i < l->nslots && !found; ++i) if (l->slots[i]->resolved && l->slots[i]->peer == who) { a = l->slots[i]->addr; found = true; }
    if (!found) return 0;
  }
  if (e.ring.empty()) e.ring.assign((size_t)(2 * EARS_RING), 0.f); // (kept once made: the audio thread may still be finishing a copy into it)
  e.addr = a;
  e.r.store(e.w.load());
  e.lost.store(0); e.frames.store(0); e.first_at.store(-1); e.stop.store(false); e.state.store(1);
  e.path = pth;
  e.what = (who.empty() ? std::string("own") : who) + " " + st;
  const int sr = l->cfg_sr;
  e.kind.store(kind, std::memory_order_release);
  e.thr = std::thread(ears_loop, l, pth, (uint64_t)(seconds * sr), sr);
  return 1;
}
int rt_hub(RtLink *l, const char *peer, int serve)
{
  std::lock_guard<std::mutex> g(l->pend_mx);
  l->want_hub = peer ? peer : "";
  l->want_serve = serve ? 1 : 0;
  l->wake.set();
  return 1;
}
void rt_test_hold(RtLink *l, double ms) { l->hold_until.store(now_s() + ms / 1000.0); }
void rt_test_speed(RtLink *l, double x) { std::lock_guard<std::mutex> st(l->stats_mx); l->speed = x > 0 ? x : 1; }
void rt_test_hold_mix(RtLink *l, double ms) { l->hold_mix.store(now_s() + ms / 1000.0); }
void rt_test_hold_tx(RtLink *l, double ms) { l->hold_tx.store(now_s() + ms / 1000.0); l->wake.set(); }
void rt_test_drift(RtLink *l, int resample) { l->resample = resample != 0; l->clk.hold = resample != 2; } // (before rt_start)
double rt_test_clock(const double *t, int n, int len, double srate, double *used)
{
  std::unique_ptr<Clock> c(new Clock());
  for (int i = 0; i < n; ++i) clock_step(*c, len, srate, aoo_ntpTimeFromSeconds(1e6 + t[i]));
  if (used) *used = c->used.load();
  return c->ppm.load();
}

void rt_set_extra(RtLink *l, rt_extra_fn fn, void *user)
{
  if (!l) return;
  l->extra.store(nullptr);
  for (int i = 0; i < 2000 && l->extra_in.load() > 0; ++i) std::this_thread::sleep_for(std::chrono::microseconds(100)); // (one in flight ends)
  l->extra_user.store(user);
  l->extra.store(fn);
}
int rt_send_raw(RtLink *l, const void *d, int n, const void *addr, int addrlen)
{
  if (!l || !d || n <= 0 || n > MAX_DGRAM || !addr || addrlen < (int)sizeof(sockaddr_in)) return -1;
  const sockaddr_in &to = *(const sockaddr_in *)addr;
  std::lock_guard<std::mutex> g(l->cfg_mx); // (rt_stop closes the socket under this lock)
  if (!l->run.load() || l->s == BAD_SOCK || !peer_ok(l, to)) return -1;
  return send_to(l, d, n, to);
}

std::string rt_status(RtLink *l)
{
  std::lock_guard<std::mutex> g(l->cfg_mx);
  std::lock_guard<std::mutex> st(l->stats_mx);
  char b[512];
  std::string o = "{\"running\":";
  o += l->run.load() ? "true" : "false";
  o += ",\"bind\":"; json_str(o, l->run.load() ? l->bind_s : "");
  o += ",\"error\":"; json_str(o, l->err);
  o += ",\"last_reject\":"; json_str(o, l->last_reject);
  o += ",\"last_reject_from\":"; json_str(o, l->last_reject_from);
  o += ",\"not_here\":" + std::to_string(l->not_here.load()) + ",\"not_here_from\":"; json_str(o, l->not_here_from); // (not_here above)
  snprintf(b, sizeof(b), ",\"secret\":%s,\"srate\":%d,\"block\":%d,\"first\":%d,\"nch\":%d,\"kbps\":%d,\"level\":%.5f,\"callbacks\":%lld,\"max_us\":%.1f,\"sent\":%lld,\"received\":%lld,\"rejected\":%lld,\"peers\":{",
           l->key.empty() ? "false" : "true", l->cfg_sr, l->cfg_len, l->first, l->nch, l->kbps, l->in_peak.exchange(0.f), l->callbacks.load(), l->max_ns.load() / 1000.0,
           l->sent.load(), l->received.load(), l->rejected.load());
  o += b;
  // (Play: the live out Hop read, whether its track ran lately (a full block in the last ~50 callbacks), and what goes out, peak since the last ask)
  const bool palive = l->pstream.load() && l->callbacks.load() - l->play_ok_cb.load() < 50;
  snprintf(b, sizeof(b), "\"play\":%d,\"play_alive\":%s,\"play_send\":%s,\"play_level\":%.5f,", l->pstream.load() ? l->phop : 0, palive ? "true" : "false",
           l->play_send.load() ? "true" : "false", l->play_peak.exchange(0.f));
  o.insert(o.size() - 9, b); // (before "peers":{)
  // (pauses: reconfigures that held the audio thread; paused_blocks: the blocks it skipped meanwhile, made up as xruns; overflows: AOO's send queue full)
  // (clock_ppm: this computer's audio clock against its own clock, as clock_step measures it for the drift correction; 0 for its first 6 s.
  // clock_used_ppm: what the correction uses of it: 0 for the first ~2 minutes, all of it from ~10)
  snprintf(b, sizeof(b), "\"pauses\":%lld,\"paused_blocks\":%lld,\"overflows\":%lld,\"clock_ppm\":%.1f,\"clock_used_ppm\":%.1f,", l->pauses, l->skipped.load(),
           l->overflows, l->clk.ppm.load(), l->clk.used.load());
  o.insert(o.size() - 9, b);
  const double now = now_s();
  { // (the ears tap: what, state, frames written, lost (the worker behind), and its first frame's age on the steady clock: Lua's
    // StudioSync_DirectNow() less first_age_s is when it was heard on the link clock)
    static const char *const es[] = { "none", "writing", "done", "failed" };
    const double fa = l->ears.first_at.load();
    std::string ej = "\"ears\":{\"what\":";
    json_str(ej, l->ears.what);
    snprintf(b, sizeof(b), ",\"state\":\"%s\",\"frames\":%lld,\"lost\":%lld,\"first_age_s\":%.6f},", es[l->ears.state.load() & 3], l->ears.frames.load(), l->ears.lost.load(),
             fa < 0 ? -1.0 : now - fa);
    o.insert(o.size() - 9, ej + b);
  }
  { // (not_here_peers: each studio computer sending here off the list in the last minute, seconds ago and datagrams. rt-roomlist)
    std::string nj = "\"not_here_peers\":{";
    bool any = false;
    for (const auto &x : l->nh) {
      if (now - x.at > 60) continue;
      if (any) nj += ',';
      any = true;
      json_str(nj, addr_str(x.a));
      snprintf(b, sizeof(b), ":{\"ago\":%.2f,\"n\":%lld}", now - x.at, x.n);
      nj += b;
    }
    o.insert(o.size() - 9, nj + "},"); // (before "peers":{, as Play's)
  }
  { // (the hub's live mix: as a listener, the hub's peer, state, latency through it against the streams' own, fallbacks; as the hub, its load)
    Slot *h = l->hub_peer.load();
    const int hs = l->hub_state.load();
    double direct = 0, through = -1;
    int nd = 0;
    for (int i = 0; i < l->nslots; ++i) if (l->slots[i].get() != h && l->slots[i]->last_direct_ms >= 0) { direct += l->slots[i]->last_direct_ms; ++nd; }
    if (h && h->rtt_ms >= 0 && h->mbuf_ms >= 0 && h->hin_ms.load() >= 0) through = h->hin_ms.load() + h->rtt_ms / 2 + h->mbuf_ms + h->mlat_ms;
    std::string hp;
    { std::lock_guard<std::mutex> p(l->pend_mx); hp = l->want_hub; }
    std::string hj = "\"hub\":{\"peer\":";
    json_str(hj, hp);
    snprintf(b, sizeof(b), ",\"state\":\"%s\",\"serve\":%s,\"serving\":%d,\"load\":%.4f,\"max_us\":%.1f,\"skipped\":%lld,\"fallbacks\":%lld,\"rescues\":%lld,\"join_fails\":%lld,\"latency_ms\":%.1f,\"in_ms\":%.1f,\"direct_ms\":%.1f,\"hub_load\":%.4f,\"mix_gap_ms\":%.1f,\"level\":%.5f,\"stalls\":%lld,\"stall_max_ms\":%.1f}",
             hs == 2 ? "hub" : hs == 1 ? "joining" : "direct", l->serve ? "true" : "false", l->hub_serving, l->hub_load, l->hub_max_us, l->hskipped.load(), l->fallbacks, l->rescues, l->join_fails,
             through, h ? h->hin_ms.load() : -1.f, nd ? direct / nd : -1.0, h ? h->hload.load() : -1.f, h ? h->mix_gap.load() * 1000 : -1.0, h ? h->mpeak.exchange(0.f) : 0.f,
             l->stalls, l->stall_max * 1000);
    hj += b;
    o.insert(o.size() - 9, hj + ","); // (before "peers":{, as Play's)
    l->hub_max_us = 0;
  }
  for (int i = 0; i < l->nslots; ++i) {
    Slot &p = *l->slots[i];
    if (i) o += ',';
    json_str(o, p.peer);
    o += ":{\"addr\":"; json_str(o, p.addr_s);
    o += ",\"error\":"; json_str(o, p.err);
    // latency: one way, mouth to ear less the audio interfaces' own buffers = half the round trip + the jitter buffer + both ends' codec/reblocking
    const double lat = p.rtt_ms >= 0 && p.buffer_ms >= 0 ? p.rtt_ms / 2 + p.buffer_ms + p.src_lat_ms + p.sink_lat_ms : -1;
    const bool streaming = p.streaming || now - p.down_at < STREAM_GRACE; // (through a re-buffer: AOO is buffering again, not gone)
    snprintf(b, sizeof(b), ",\"resolved\":%s,\"streaming\":%s,\"rtt_ms\":%.1f,\"latency_ms\":%.1f,\"buffer_ms\":%.1f,\"target_ms\":%.0f,\"floor_ms\":%.0f,\"ceiling_ms\":%.0f,\"loss\":%.4f,\"dropped\":%lld,\"underruns\":%lld,\"level\":%.5f,\"gain\":%.3f,\"mute\":%s}",
             p.resolved ? "true" : "false", streaming ? "true" : "false", p.rtt_ms, lat, p.buffer_ms, p.target_ms, p.floor_ms, p.ceil_ms, p.loss, p.dropped,
             p.underruns, p.peak.exchange(0.f), p.gain.load(), p.mute.load() ? "true" : "false"); // (level: the peak since the last ask, before the cue mix's level)
    o += b;
    snprintf(b, sizeof(b), ",\"play_streaming\":%s,\"play_level\":%.5f,\"play_gain\":%.3f,\"via_hub\":%s,\"direct\":%s", p.pstreaming || now - p.pdown_at < STREAM_GRACE ? "true" : "false",
             p.ppeak.exchange(0.f), p.pgain.load(), l->hub_state.load() == 2 && p.in_mix.load() ? "true" : "false", hears_direct(p, now) ? "true" : "false"); // (via_hub: heard in the hub's mix; direct: my streams go to it)
    o.insert(o.size() - 1, b); // (inside the peer's object)
    // (fill_ms: Talk's buffer as measured now; jitter: the underruns that grew it; switched: those a hub mix <-> direct switch brought; trims)
    snprintf(b, sizeof(b), ",\"fill_ms\":%.1f,\"jitter\":%lld,\"switched\":%lld,\"trims\":%lld,\"lone\":%lld", p.fill_ms, p.jitter + p.pjitter + p.mjitter, p.switched, p.trims, p.lone);
    o.insert(o.size() - 1, b);
    snprintf(b, sizeof(b), ",\"heard_ago\":%.2f", std::min(1e6, now - p.rx_at.load(std::memory_order_relaxed))); // (its last tagged datagram: it lists this computer. rt-roomlist)
    o.insert(o.size() - 1, b);
    // (overruns: AOO's resets of Talk's buffer for a burst that didn't fit (CAP_HEAD). Play's own: its underruns, overruns, resyncs (both: each a
    // re-buffer, a gap), trims (sheds), its buffer as measured and its latency from that (half the round trip + that buffer + AOO's codec and
    // reblocking for it: what's held now, where latency_ms is Talk's size when its buffering ended), and its mix's overruns)
    const double plat = p.rtt_ms >= 0 && p.pfill_ms >= 0 ? p.rtt_ms / 2 + p.pfill_ms + p.plat_ms : -1;
    snprintf(b, sizeof(b), ",\"overruns\":%lld,\"play_underruns\":%lld,\"play_overruns\":%lld,\"play_resyncs\":%lld,\"play_trims\":%lld,\"play_buffer_ms\":%.1f,\"play_latency_ms\":%.1f,\"mix_overruns\":%lld",
             p.overruns, p.punderruns, p.poverruns, p.punderruns + p.poverruns, p.ptrims, p.pfill_ms, plat, p.moverruns);
    o.insert(o.size() - 1, b);
  }
  o += "}}";
  return o;
}

// ---- the audio thread ------------------------------------------------------------------------------------------------------------------
static void took(RtLink *l, std::chrono::steady_clock::time_point t0)
{
  const long long ns = (long long)std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - t0).count();
  if (ns > l->max_ns.load(std::memory_order_relaxed)) l->max_ns.store(ns, std::memory_order_relaxed);
}
void (*rt_talk_add)(float *const *, int, int) = nullptr; // (rtaudio.h: a browser guest into the Talk sent. rt-browserjoin)
void (*rt_play_tap)(float *const *, int, int, int) = nullptr; // (rtaudio.h: Jam's copy of each Play block. rt-jam)
void rt_capture(RtLink *l, const double *const *in, int nin, int len, double srate)
{
  if (!l || len <= 0) return;
  l->in_cb.fetch_add(1);
  if (l->run.load(std::memory_order_relaxed)) {
    const auto t0 = std::chrono::steady_clock::now();
    l->callbacks.fetch_add(1, std::memory_order_relaxed);
    l->seen_sr.store(srate, std::memory_order_relaxed);
    l->seen_len.store(len, std::memory_order_relaxed);
    l->tfed = clock_step(l->clk, len, srate, aoo_getCurrentNtpTime()); // (every block, paused or not: the device's clock runs on)
    l->clk_cb = l->callbacks.load(std::memory_order_relaxed);
    if (l->live.load() && (int)srate == l->cfg_sr && len == l->cfg_len) {
      if (const int k = l->skip_in.exchange(0)) l->src->reportXRun(k); // (blocks a reconfigure paused: the stream keeps its time)
      float pk = 0;
      const bool on = l->send_on.load(std::memory_order_relaxed); // (muted: silence goes out, but the meter still reads the input, so the panel can say "you're talking while muted")
      for (int c = 0; c < l->nch; ++c) {
        const int i = l->first + c;
        const double *src = i < nin && in ? in[i] : nullptr;
        float *dst = l->inptr[c];
        if (src) for (int k = 0; k < len; ++k) { const float v = (float)src[k]; pk = std::max(pk, std::fabs(v)); dst[k] = on ? v : 0.f; }
        else std::fill(dst, dst + len, 0.f);
      }
      if (pk > l->in_peak.load(std::memory_order_relaxed)) l->in_peak.store(pk, std::memory_order_relaxed);
      if (on && rt_talk_add) rt_talk_add(l->inptr, l->nch, len); // (a browser guest goes on to the bandmates in this Talk. rt-browserjoin)
      const AooError e = l->src->process(l->inptr, len, l->tfed);
      if (e == kAooErrorOverflow) l->overflow.store(true); // (the send thread unsticks AOO's queue: tx_loop)
      if (e == kAooOk || e == kAooErrorOverflow) l->wake.set();
    } else {
      if (!l->live.load()) { l->skip_in.fetch_add(len); l->skipped.fetch_add(1, std::memory_order_relaxed); } // (paused: made up for once it's back)
      l->wake.set(); // (a new sample rate or block size: the send thread sets AOO up for it)
    }
    took(l, t0);
  }
  l->in_cb.fetch_sub(1);
}
// Play's input (the hook's post call): the live out track's StudioSync Hop wrote this block's frames into its send ring during REAPER's FX
// pass, just before this, so the newest `len` frames are this block's sound of the armed tracks. Fewer there (the track isn't running,
// REAPER stopped its audio, no Hop yet): silence goes out. Far behind (a new Hop instance, a stall): only the newest block, never a backlog
// that would sit in the stream as delay. (James, rt)
// The ears tap's copy (rt_ears): this block into its ring, or counted lost when the worker is behind. The audio thread's: copies only.
static void ears_put(RtLink *l, const float *L, const float *R, int len)
{
  Ears &e = l->ears;
  const uint64_t w = e.w.load(std::memory_order_relaxed), r = e.r.load(std::memory_order_acquire);
  if (e.ring.size() < 2 * EARS_RING || w - r + (uint64_t)len > EARS_RING) { e.lost.fetch_add(len, std::memory_order_relaxed); return; }
  if (e.first_at.load(std::memory_order_relaxed) < 0) e.first_at.store(now_s(), std::memory_order_relaxed);
  float *d = e.ring.data();
  for (int k = 0; k < len; ++k) { const uint64_t at = (w + (uint64_t)k) & (EARS_RING - 1); d[2 * at] = L[k]; d[2 * at + 1] = R[k]; }
  e.w.store(w + (uint64_t)len, std::memory_order_release);
}
static void play_feed(RtLink *l, int len, AooNtpTime t)
{
  hop_shm *s = l->pshm;
  float *L = l->pptr[0], *R = l->pptr[1];
  const uint64_t w = hop_shm_ok(s) ? hop_load(&s->send_w) : 0;
  if (l->play_r > w || w - l->play_r > (uint64_t)len * PLAY_BACKLOG) l->play_r = w >= (uint64_t)len ? w - len : 0;
  float pk = 0;
  if (hop_shm_ok(s) && w - l->play_r >= (uint64_t)len) {
    hop_copy_out(s->send, l->play_r, (uint32_t)len, l->pinter.data());
    l->play_r += (uint64_t)len;
    for (int k = 0; k < len; ++k) { L[k] = l->pinter[2 * k]; R[k] = l->pinter[2 * k + 1]; pk = std::max(pk, std::max(std::fabs(L[k]), std::fabs(R[k]))); }
    l->play_ok_cb.store(l->callbacks.load(std::memory_order_relaxed), std::memory_order_relaxed);
  } else {
    std::fill(L, L + len, 0.f);
    std::fill(R, R + len, 0.f);
  }
  if (pk > l->play_peak.load(std::memory_order_relaxed)) l->play_peak.store(pk, std::memory_order_relaxed);
  if (!l->play_send.load(std::memory_order_relaxed)) { std::fill(L, L + len, 0.f); std::fill(R, R + len, 0.f); } // (muted: silence, the stream kept)
  if (l->ears.kind.load(std::memory_order_acquire) == 1) ears_put(l, L, R, len); // (the ears tap: this computer's Play as it goes out)
  if (rt_play_tap) rt_play_tap(l->pptr, 2, len, l->cfg_sr); // (Jam takes the same block, after Mute me: extension/direct_audio.cpp. rt-jam)
  const AooError e = l->psrc->process(l->pptr, len, t);
  if (e == kAooErrorOverflow) l->poverflow.store(true);
  if (e == kAooOk || e == kAooErrorOverflow) l->wake.set();
}
void rt_mix(RtLink *l, double *const *out, int nout, int len, double srate)
{
  if (!l || len <= 0) return;
  l->in_cb.fetch_add(1);
  if (l->live.load() && (int)srate == l->cfg_sr && len == l->cfg_len) {
    const auto t0 = std::chrono::steady_clock::now();
    const AooNtpTime t = l->clk_cb == l->callbacks.load(std::memory_order_relaxed) ? l->tfed : aoo_getCurrentNtpTime(); // (rt_capture's, this block)
    if (const int k = l->skip_out.exchange(0)) { // (blocks a reconfigure paused: Play keeps its time, the sinks drop what piled up meanwhile)
      if (l->pstream.load() && l->pshm) l->psrc->reportXRun(k);
      for (int i = 0; i < l->nslots; ++i)
        for (AooSink *s : { l->slots[i]->sink, l->slots[i]->psink, l->slots[i]->msink }) if (s) s->reportXRun(k);
    }
    if (l->pstream.load() && l->pshm) play_feed(l, len, t);
    // The hub's live mix. Serving: this block's record in the ring (every peer's Talk and Play as decoded, then this computer's own), a copy
    // for the send thread to mix; the ring full (the send thread behind): skipped, and counted. Listening through a hub: its mix instead of
    // everyone's own streams, crossfaded over one block when that changes (w0 -> w1).
    float *rec = nullptr;
    uint64_t hw = 0;
    if (l->hserve.load(std::memory_order_acquire) && !l->hring.empty()) {
      hw = l->hw.load(std::memory_order_relaxed);
      if (hw - l->hr.load(std::memory_order_acquire) < (uint64_t)HUB_RING) rec = &l->hring[(size_t)(hw % HUB_RING) * l->hstride];
      else l->hskipped.fetch_add(1, std::memory_order_relaxed);
    }
    Slot *hp = l->hub_peer.load(std::memory_order_acquire);
    const float w0 = l->mixw, w1 = hp && l->hub_state.load(std::memory_order_relaxed) == 2 ? 1.f : 0.f;
    l->mixw = w1;
    // one stream of a peer, heard: Talk at its level, Play at its own (the personal monitor mix; gain 0: the peer muted, both); r0 -> r1: its
    // weight over this block; to: the ring's copy (L, then R), before any level
    // shed: adapt's skip for this stream (its buffer far above its size), at most SHED_STEP a block: this block, kept, crossfaded into the
    // stream that far on (AOO skips it in the next process: reportXRun, a lock-free count; that process takes a block too). ek: the ears tap's
    // kind for this stream.
    const int shed_step = std::max(len, (int)(l->cfg_sr * SHED_STEP / 1000));
    auto hear = [&](Slot &p, AooSink *sink, std::atomic<bool> &mono, std::atomic<float> &peak, bool &was_quiet, float gain, float r0, float r1, float *to,
                    std::atomic<int> &shed, int ek) {
      if (!sink || sink->process(l->mixptr, len, t, nullptr, nullptr) != kAooOk) { if (to) std::fill(to, to + 2 * len, 0.f); return; }
      float *L = l->mixptr[0], *R = l->mixptr[1];
      const int sk = std::min(shed.load(std::memory_order_relaxed), shed_step);
      if (sk >= len && !l->xbuf.empty()) {
        shed.fetch_sub(sk, std::memory_order_relaxed);
        std::copy(L, L + len, l->xptr[0]); std::copy(R, R + len, l->xptr[1]);
        if (sk > len) sink->reportXRun(sk - len);
        if (sink->process(l->mixptr, len, t, nullptr, nullptr) == kAooOk)
          for (int k = 0; k < len; ++k) { const float g = ((float)k + 0.5f) / (float)len; L[k] = l->xptr[0][k] * (1 - g) + L[k] * g; R[k] = l->xptr[1][k] * (1 - g) + R[k] * g; }
        else { std::copy(l->xptr[0], l->xptr[0] + len, L); std::copy(l->xptr[1], l->xptr[1] + len, R); }
      }
      if (mono.load(std::memory_order_relaxed)) std::copy(L, L + len, R); // (a mono sender: both ears)
      float pk = 0;
      for (int k = 0; k < len; ++k) pk = std::max(pk, std::max(std::fabs(L[k]), std::fabs(R[k])));
      if (pk > peak.load(std::memory_order_relaxed)) peak.store(pk, std::memory_order_relaxed);
      if (pk > p.loud.load(std::memory_order_relaxed)) p.loud.store(pk, std::memory_order_relaxed);
      const bool quiet = pk < 1e-4f; // (AOO's silence in a gap or a re-buffer: under -80 dBFS)
      if (was_quiet && !quiet) for (int k = 0; k < len; ++k) { const float g = (float)k / (float)len; L[k] *= g; R[k] *= g; } // (back after a gap: faded in over one block, no click)
      was_quiet = quiet;
      if (ek && l->ears.kind.load(std::memory_order_acquire) == ek && same_addr(l->ears.addr, p.addr)) ears_put(l, L, R, len); // (as heard, before any level)
      if (to) { std::copy(L, L + len, to); std::copy(R, R + len, to + len); }
      if (gain <= 0 || (r0 <= 0 && r1 <= 0) || !out) return;
      const double gn = gain, dr = (double)(r1 - r0) / len;
      if (nout > 0 && out[0]) for (int k = 0; k < len; ++k) out[0][k] += gn * (r0 + dr * k) * L[k];
      if (nout > 1 && out[1]) for (int k = 0; k < len; ++k) out[1][k] += gn * (r0 + dr * k) * R[k];
    };
    for (int i = 0; i < l->nslots; ++i) {
      Slot &p = *l->slots[i];
      const bool m = p.mute.load(std::memory_order_relaxed);
      float *to = rec ? rec + (size_t)i * 4 * len : nullptr;
      const float d0 = p.dw, d1 = p.in_mix.load(std::memory_order_relaxed) ? 1 - w1 : 1.f; // (one the hub's mix hasn't: its own streams, always)
      p.dw = d1;
      hear(p, p.sink, p.mono, p.peak, p.was_quiet, m ? 0.f : p.gain.load(std::memory_order_relaxed), d0, d1, to, p.shed[0], 2);
      hear(p, p.psink, p.pmono, p.ppeak, p.pwas_quiet, m ? 0.f : p.pgain.load(std::memory_order_relaxed), d0, d1, to ? to + 2 * len : nullptr, p.shed[1], 3);
    }
    if (hp) { // (my hub's mix, already at my levels: decoded while asked for, so it's ready the moment it's heard)
      std::atomic<bool> stereo{ false };
      hear(*hp, hp->msink, stereo, hp->mpeak, hp->mwas_quiet, 1.f, w0, w1, nullptr, hp->shed[2], 4);
    }
    if (rec) { // (this computer's own Talk, the first two inputs sent (mono: both ears), and its Play, as they went out)
      float *own = rec + (size_t)l->nslots * 4 * len;
      std::copy(l->inptr[0], l->inptr[0] + len, own);
      std::copy(l->inptr[l->nch > 1 ? 1 : 0], l->inptr[l->nch > 1 ? 1 : 0] + len, own + len);
      if (l->pstream.load() && l->pshm) { std::copy(l->pptr[0], l->pptr[0] + len, own + 2 * len); std::copy(l->pptr[1], l->pptr[1] + len, own + 3 * len); }
      else std::fill(own + 2 * len, own + 4 * len, 0.f);
      l->htime[(size_t)(hw % HUB_RING)] = t;
      l->hw.store(hw + 1, std::memory_order_release);
    }
    took(l, t0);
  } else if (l->run.load(std::memory_order_relaxed) && !l->live.load()) l->skip_out.fetch_add(len); // (paused: made up for once it's back)
  l->in_cb.fetch_sub(1);
}

// ---- REAPER ----------------------------------------------------------------------------------------------------------------------------
#ifndef RTAUDIO_STANDALONE
#include "reaper_plugin.h"
#ifdef min // (SWELL on macOS/Linux defines min/max as macros)
#undef min
#endif
#ifdef max
#undef max
#endif
#include "webui.h" // (webui_mix_feed: a screen share's sound, REAPER's own mix. rt-share; after the #undefs: it brings in <map>)
#include "audiohook.h" // (hook_buffers: the channels a hook call has; REAPER leaves input_nch/output_nch at 0. rt-audience)
static RtLink *g_rt = nullptr; // (made once at load, freed never while REAPER runs: the hook may still hold it for a moment after removal)
RtLink *rt_global() { return g_rt; }
static int (*g_reg_hook)(bool isAdd, audio_hook_register_t *reg) = nullptr;
static bool g_hooked = false;
static std::string g_status;
// What the hook was handed, for StudioSync_LiveAudioStatus's "hook": calls before and after REAPER's processing, the channel counts REAPER
// put in the struct (0 on REAPER 7.86: extension/audiohook.h) and the buffers GetBuffer gave. (rt-audience, after the desktop's check)
static std::atomic<long long> g_hook_pre{ 0 }, g_hook_post{ 0 };
static std::atomic<int> g_hook_in_set{ 0 }, g_hook_out_set{ 0 }, g_hook_ins{ 0 }, g_hook_outs{ 0 };
static void on_audio(bool isPost, int len, double srate, audio_hook_register_t *reg)
{
  if (!isPost) { // (before REAPER's processing: the hardware inputs as they came in)
    const double *in[64] = { nullptr };
    g_hook_in_set.store(reg->input_nch, std::memory_order_relaxed);
    const int nin = hook_buffers(reg, false, in, 64); // (not reg->input_nch: REAPER leaves it 0, and nothing was ever captured)
    g_hook_ins.store(nin, std::memory_order_relaxed);
    g_hook_pre.fetch_add(1, std::memory_order_relaxed);
    rt_capture(g_rt, in, nin, len, srate);
  } else { // (after: added to what REAPER is about to play out of the first output pair)
    double *out[2] = { nullptr, nullptr };
    g_hook_out_set.store(reg->output_nch, std::memory_order_relaxed);
    const int nout = hook_buffers(reg, true, out, 2); // (not reg->output_nch: 0, so nobody was mixed in and no feed below ever ran)
    g_hook_outs.store(nout, std::memory_order_relaxed);
    g_hook_post.fetch_add(1, std::memory_order_relaxed);
    webui_mix_feed(out, nout, len, srate); // (a screen share's REAPER mix: taken before rt_mix adds the bandmates, so nobody hears themselves back)
    rt_mix(g_rt, out, nout, len, srate);
    webui_guest_audio(out, nout, len, srate); // (browser guests: the session mix for them, bandmates in, then each guest added. rt-browserjoin)
  }
}
static audio_hook_register_t g_hook = { on_audio, nullptr, nullptr, 0, 0, nullptr };
// (REAPER's main thread, ~30 times a second) A page streaming REAPER's mix for a screen share needs the hook whether live audio runs or not:
// in while one streams, out again once none does and live audio isn't running (api_stop takes it out; this puts it back within a tick).
static bool g_mix_down = false; // (REAPER going: the hook stays out)
static void mix_timer()
{
  if (!g_reg_hook || !g_rt || g_mix_down) return;
  const bool want = webui_mix_wanted() > 0;
  if (want && !g_hooked) g_hooked = g_reg_hook(true, &g_hook) > 0;
  else if (!want && g_hooked && !g_rt->run.load()) { g_reg_hook(false, &g_hook); g_hooked = false; }
}

static int api_start(int inputs, int nch, int kbps)
{
  if (!g_rt || !g_reg_hook) return 0;
  if (!rt_start(g_rt, inputs, nch, kbps, 0, "")) return 0; // (port 0: the peers JSON's, else the link's 47281)
  if (!g_hooked) g_hooked = g_reg_hook(true, &g_hook) > 0;
  if (!g_hooked) { rt_stop(g_rt); return 0; }
  return 1;
}
static void api_stop()
{
  if (g_hooked && g_reg_hook) g_reg_hook(false, &g_hook);
  g_hooked = false;
  if (g_rt) rt_stop(g_rt);
}
static int api_peers(const char *json) { return g_rt ? rt_peers(g_rt, json) : -1; }
static const char *api_status()
{
  g_status = g_rt ? rt_status(g_rt) : "{}";
  char b[200]; // (what the audio hook is handed, added as the last field: rt-audience)
  snprintf(b, sizeof(b), "%s\"hook\":{\"pre\":%lld,\"post\":%lld,\"in_nch\":%d,\"out_nch\":%d,\"ins\":%d,\"outs\":%d}}", g_status.size() > 2 ? "," : "", g_hook_pre.load(), g_hook_post.load(), g_hook_in_set.load(), g_hook_out_set.load(),
           g_hook_ins.load(), g_hook_outs.load());
  if (!g_status.empty() && g_status.back() == '}') { g_status.pop_back(); g_status += b; }
  return g_status.c_str();
}
static int api_peer_set(const char *peer, double gain, int mute) { return g_rt ? rt_peer_set(g_rt, peer, gain, mute) : 0; }
static int api_send(const char *peer, int on) { return g_rt ? rt_send(g_rt, peer, on) : 0; }
static int api_peer_buffer(const char *peer, double floor_ms, double ceil_ms) { return g_rt ? rt_peer_buffer(g_rt, peer, floor_ms, ceil_ms) : 0; }
static void *vla_peer_buffer(void **a, int n) { return n < 3 || !a[1] || !a[2] ? nullptr : (void *)(INT_PTR)api_peer_buffer((const char *)a[0], *(double *)a[1], *(double *)a[2]); }
static void *vla_start(void **a, int n) { return n < 3 ? nullptr : (void *)(INT_PTR)api_start((int)(INT_PTR)a[0], (int)(INT_PTR)a[1], (int)(INT_PTR)a[2]); }
static void *vla_stop(void **, int) { api_stop(); return nullptr; }
static void *vla_peers(void **a, int n) { return n < 1 ? nullptr : (void *)(INT_PTR)api_peers((const char *)a[0]); }
static void *vla_status(void **, int) { return (void *)api_status(); }
static void *vla_send(void **a, int n) { return n < 2 ? nullptr : (void *)(INT_PTR)api_send((const char *)a[0], (int)(INT_PTR)a[1]); }
static void *vla_peer_set(void **a, int n) { return n < 3 || !a[1] ? nullptr : (void *)(INT_PTR)api_peer_set((const char *)a[0], *(double *)a[1], (int)(INT_PTR)a[2]); } // (a double comes as a pointer)
static int api_play(int hop_id, int send) { return g_rt ? rt_play(g_rt, hop_id, send) : 0; }
static int api_peer_play(const char *peer, double gain) { return g_rt ? rt_peer_play(g_rt, peer, gain) : 0; }
static void *vla_play(void **a, int n) { return n < 2 ? nullptr : (void *)(INT_PTR)api_play((int)(INT_PTR)a[0], (int)(INT_PTR)a[1]); }
static void *vla_peer_play(void **a, int n) { return n < 2 || !a[1] ? nullptr : (void *)(INT_PTR)api_peer_play((const char *)a[0], *(double *)a[1]); }
static int api_hub(const char *peer, int serve) { return g_rt ? rt_hub(g_rt, peer, serve) : 0; }
static int api_ears(const char *peer, const char *stream, const char *path, double secs) { return g_rt ? rt_ears(g_rt, peer, stream, path, secs) : 0; }
static void *vla_ears(void **a, int n) { return n < 4 || !a[3] ? nullptr : (void *)(INT_PTR)api_ears((const char *)a[0], (const char *)a[1], (const char *)a[2], *(double *)a[3]); } // (a double comes as a pointer)
static void *vla_hub(void **a, int n) { return n < 2 ? nullptr : (void *)(INT_PTR)api_hub((const char *)a[0], (int)(INT_PTR)a[1]); }

void rtaudio_shutdown()
{
  g_mix_down = true; // (mix_timer: a page still streaming REAPER's mix doesn't put the hook back)
  api_stop();
  if (g_rt) for (const hop_map &m : g_rt->pnames) hop_shm_unlink(&m); // (the live out mappings' POSIX names, as extension/hop.cpp's)
}

void rtaudio_register(reaper_plugin_info_t *rec)
{
  g_reg_hook = (int (*)(bool, audio_hook_register_t *))rec->GetFunc("Audio_RegHardwareHook");
  if (!g_rt) g_rt = rt_new();
  rt_talk_add = webui_guest_talk; // (rt-browserjoin)
  static const struct { const char *name; void *fn, *va; const char *def; } fns[] = {
    { "StudioSync_LiveAudioStart", (void *)api_start, (void *)vla_start,
      "int\0int,int,int\0inputs,nch,kbps\0StudioSync's live audio: send hardware inputs inputs..inputs+nch-1 (0-based, nch 1-8) as Opus at kbps (16-512, the total) to the peers (StudioSync_LiveAudioPeers) over Tailscale UDP, and mix theirs into the first output pair. Call StudioSync_LiveAudioPeers first: it gives the studio secret and the port. Returns 1 when started (or already running: stop first to change inputs or rate)." },
    { "StudioSync_LiveAudioStop", (void *)api_stop, (void *)vla_stop, "void\0\0\0Stop StudioSync's live audio (the hook comes out, the socket closes)." },
    { "StudioSync_LiveAudioPeers", (void *)api_peers, (void *)vla_peers,
      "int\0const char*\0json\0Who to send to and hear, and the key: {\"secret\":\"<the studio secret>\",\"port\":47281,\"peers\":[\"name:port\",...]} (the direct link's list; Tailscale addresses only). Returns how many peers, or -1 when the JSON isn't that." },
    { "StudioSync_LiveAudioStatus", (void *)api_status, (void *)vla_status,
      "const char*\0\0\0StudioSync's live audio as JSON: running, bind, error, secret, srate, block, level (what you send, peak since the last ask), callbacks, max_us, pauses, paused_blocks, overflows (reconfigures that held the audio, blocks skipped meanwhile, AOO's send queue full), sent, received, rejected, last_reject, last_reject_from (its sender's ip:port), not_here, not_here_from (datagrams with the studio's secret from a computer not on the peer list here: dropped, not refused), and per peer: resolved, streaming, rtt_ms, latency_ms, buffer_ms (the jitter buffer), target_ms, floor_ms, ceiling_ms (the adaptive buffer's size and bounds), fill_ms (the buffer as measured), jitter (underruns that grew it), switched (underruns a hub mix/direct switch brought), trims (buffers far above their size shed, crossfaded), loss (0-1), dropped, underruns, overruns (bursts that didn't fit: a re-buffer), level (peak since the last ask), gain, mute, play_streaming, play_level, play_gain, play_underruns, play_overruns, play_resyncs, play_trims, play_buffer_ms (Play's buffer as measured), play_latency_ms (from that: Play's own) (their Play stream), mix_overruns; ears (StudioSync_LiveAudioEars: what, state, frames, lost, first_age_s); and play (the live out hop id, 0: no Play), play_alive, play_send, play_level (what this computer plays out); and hook: pre, post (the audio hook's calls before and after REAPER's processing), in_nch, out_nch (the channel counts REAPER put in the hook's struct: 0 on REAPER 7), ins, outs (the hardware buffers it handed over: what is captured and mixed into)." },
    { "StudioSync_LiveAudioPeerSet", (void *)api_peer_set, (void *)vla_peer_set,
      "int\0const char*,double,int\0peer,gain,mute\0A peer's level (linear, 0-4) and mute in what you hear (the cue mix). Returns 1 when that peer is in the list." },
    { "StudioSync_LiveAudioPeerBuffer", (void *)api_peer_buffer, (void *)vla_peer_buffer,
      "int\0const char*,double,double\0peer,floor_ms,ceiling_ms\0A peer's jitter buffer bounds: it starts at the floor, grows on underruns (Wi-Fi's bursts) up to the ceiling, and shrinks back after a steady spell. 0 for either: the default (30, 150 ms). Returns 1 when that peer is in the list." },
    { "StudioSync_LiveAudioSend", (void *)api_send, (void *)vla_send,
      "int\0const char*,int\0peer,on\0What this computer sends. peer \"\": everything (on 0 sends silence while the stream stays up: Mute me, push-to-talk). A peer in the list: whether that peer gets it (talkback: one bandmate hears you, the others don't). Returns 1 when done (0: that peer isn't in the list)." },
    { "StudioSync_LiveAudioPlay", (void *)api_play, (void *)vla_play,
      "int\0int,int\0hop_id,send\0Play, live audio's second stream: what the StudioSync Hop with this id (1-64, on the hidden live out track the armed tracks send to post-FX) is fed, sent beside Talk so each listener sets the two apart. hop_id 0: no Play stream. send 0: silence while the stream stays up (Mute me, Deafen). StudioSync_LiveAudioStatus's play, play_alive, play_level say how it goes. Returns 1." },
    { "StudioSync_LiveAudioPeerPlay", (void *)api_peer_play, (void *)vla_peer_play,
      "int\0const char*,double\0peer,gain\0A peer's Play level (linear, 0-4) in what you hear, apart from their Talk level (StudioSync_LiveAudioPeerSet, whose mute is the whole bandmate's). Returns 1 when that peer is in the list." },
    { "StudioSync_LiveAudioEars", (void *)api_ears, (void *)vla_ears,
      "int\0const char*,const char*,const char*,double\0peer,stream,path,seconds\0The ears tap (tools/ears, docs/rt/rt-p11.md): writes what this computer actually hears of a bandmate's stream to path, a 32-bit float stereo WAV (path must end .wav; seconds 0-60): peer (in the list) and stream \"talk\", \"play\" or \"hub\" (its live mix for this computer), as decoded and before any level; or peer \"\" and stream \"play\" for this computer's own Play as it goes out (after Mute me). One at a time, while live audio runs. StudioSync_LiveAudioStatus's ears says what, state (writing/done/failed), frames, lost and first_age_s (StudioSync_DirectNow() less it: when its first frame was heard, on the link clock). Returns 1 when started." },
    { "StudioSync_LiveAudioHub", (void *)api_hub, (void *)vla_hub,
      "int\0const char*,int\0peer,serve\0The hub's live mix: peer (in the list) mixes for this computer, which then sends its streams to it alone and hears the one stream it mixes at this computer's own levels, back to everyone's own streams at once when that mix stops; \"\": peer to peer. serve 1: this computer mixes for every listener that asks. StudioSync_LiveAudioStatus's hub (peer, state direct/joining/hub, serve, serving, load, max_us, skipped, fallbacks, join_fails (asks no mix answered in 5 s: asked again 10 s later), latency_ms, in_ms, direct_ms, hub_load) and per peer via_hub (heard in the hub's mix; one the hub doesn't hear is heard directly), direct say how it goes. Returns 1." },
  };
  char key[96];
  for (const auto &f : fns) {
    snprintf(key, sizeof(key), "API_%s", f.name); rec->Register(key, f.fn);
    snprintf(key, sizeof(key), "APIdef_%s", f.name); rec->Register(key, (void *)f.def);
    snprintf(key, sizeof(key), "APIvararg_%s", f.name); rec->Register(key, f.va);
  }
  rec->Register("atexit", (void *)rtaudio_shutdown); // (the hook out before REAPER goes)
  rec->Register("timer", (void *)mix_timer); // (a screen share's REAPER mix: the hook while a page streams it, extension/webui.cpp. rt-share)
}
#endif
