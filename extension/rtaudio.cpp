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
// whether it hears through a hub, 'I' the hub's latency and load back), switches to the mix once it has flowed ENTER_S, and every sender then
// stops sending it their own streams. When the mix pauses (RESCUE_MIN), the listener asks for everyone's streams back ('M') while the mix's
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
typedef SOCKET sock_t;
#define BAD_SOCK INVALID_SOCKET
#define close_sock closesocket
#else
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
typedef int sock_t;
#define BAD_SOCK (-1)
#define close_sock close
#endif
#include <algorithm>
#include <atomic>
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
// The adaptive jitter buffer, per peer (adapt below). ms: a peer's own floor and ceiling come from rt_peer_buffer, these are the defaults
// (30 ms held between the Windows computers over Tailscale; 150 ms is past what a band can play along to anyway). (James, rt)
const double BUF_FLOOR = 30, BUF_CEIL = 150, BUF_GROW = 20, BUF_SHRINK = 10;
// seconds: no underrun this long before the first shrink, then this long between shrinks; a size that underran is not tried again until
// this long without one (the network may have got better)
const double BUF_STEADY = 15, BUF_STEP = 10, BUF_FORGET = 120;
const float BUF_QUIET = 0.003f;      // a shrink waits for the peer to be quiet (peak under -50 dBFS) for BUF_QUIET_S: its re-buffer is a gap
const double BUF_QUIET_S = 0.3;
const double STREAM_GRACE = 2.0;     // s: "streaming" stays true through a re-buffer, so the panel and Health don't flap with every underrun
const double PAUSE_S = 1.0;          // an underrun after the stream was down longer than this is a pause (talkback, a stalled sender), not jitter
// The hub's live mix (rt_hub). MIX_ID: each listener's mix is its own source at the hub (one per listener, told apart by address); the
// listener's sink for it: the hub's address hash with "/mix". CTL: the control datagrams (mode, the mix's levels, the hub's numbers back).
const AooId MIX_ID = 3;
const char CTL[4] = { 'S', 'S', 'X', '1' };
const int HUB_RING = 32;             // blocks the audio thread may be ahead of the hub's mixing (~170 ms at 256): past that blocks are skipped (overloaded)
const double MODE_EVERY = 0.25;      // s: a listener's mode and its mix's levels are said again this often (and at once when they change)
const double MODE_FRESH = 1.0;       // s: a listener's mode older than this counts as "hears everyone directly"; its mix stops when its asking does
const double ENTER_S = 0.3;          // s: the mix flowing this long before a listener hears it instead of everyone's own streams
const double GONE_MIN = 40, GONE_PAD = 20; // ms: no mix datagram for its buffer + GONE_PAD (at least GONE_MIN): the hub is gone, everyone's streams at once
// ms: no mix datagram for the mix's buffer less RESCUE_LEAD (at least RESCUE_MIN, two 5 ms packets): everyone's streams are asked back at once
// while the mix's buffer still plays, so they're nearly buffered by the time it runs dry; the mix back, they're let go again. A buffer grown
// for Wi-Fi's bursts waits longer, so bursts it absorbs don't turn everyone's streams on and off.
// RESCUE_PAD: and never before the mix's widest packet spacing lately + this, so a jittery link (the macOS CI runner) doesn't keep asking.
const double RESCUE_MIN = 10, RESCUE_LEAD = 20, RESCUE_PAD = 5;
const double RETRY_S = 3.0;          // s after falling back before the hub's mix is asked for again (a flickering hub doesn't flap the stream)

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
  long long jitter_seen = 0;
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
};
} // namespace

struct RtLink {
  std::mutex api_mx, pend_mx, cfg_mx, stats_mx;
  std::string key, bind_s, err, last_reject, last_reject_from, want_peers, want_secret, have_secret;
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
  std::atomic<long long> callbacks{ 0 }, max_ns{ 0 }, sent{ 0 }, received{ 0 }, rejected{ 0 };
  unsigned char txbuf[MAX_DGRAM + 64];
  std::string status_out;
  std::atomic<rt_extra_fn> extra{ nullptr }; // (Hop's network leg: rt_set_extra)
  std::atomic<void *> extra_user{ nullptr };
  std::atomic<int> extra_in{ 0 };
  std::atomic<double> hold_until{ 0 }; // (tests/rtaudio_test.cpp: rt_test_hold, Wi-Fi's bursts)
  double speed = 1;                    // (rt_test_speed: the adaptive buffer's timings this many times faster)
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
  double intra_until = 0;           // (apply_sends: frames coded without prediction until then)
  long long fallbacks = 0, rescues = 0; // (rescues: everyone's streams asked back while the mix paused)
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
  int hub_serving = 0;
};

namespace {
std::once_flag g_aoo_once;
double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
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
// This computer's Tailscale address, as direct.cpp tailscale_ip: where a UDP socket "connected" to 100.100.100.100 would send from.
std::string tailscale_ip()
{
  sock_t s = socket(AF_INET, SOCK_DGRAM, 0);
  if (s == BAD_SOCK) return "";
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
  if (!addr_ok(to, l->loopback)) return -1;
  memcpy(l->txbuf, MAGIC, 4);
  memcpy(l->txbuf + 4, data, (size_t)size);
  unsigned char t[32];
  tag_of(l->key, l->txbuf, 4 + (size_t)size, t);
  memcpy(l->txbuf + 4 + size, t, TAG);
  const int n = (int)sendto(l->s, (const char *)l->txbuf, 4 + size + TAG, 0, (const sockaddr *)&to, sizeof(to));
  if (n > 0) l->sent.fetch_add(1, std::memory_order_relaxed);
  return n;
}

Slot *slot_of(RtLink *l, const sockaddr_in &a) // (cfg_mx or the send thread)
{
  for (int i = 0; i < l->nslots; ++i) if (l->slots[i]->resolved && same_addr(l->slots[i]->addr, a)) return l->slots[i].get();
  return nullptr;
}

// Events, polled on the send thread.
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
    if (now_s() - p->down_at < PAUSE_S) p->jitter += 1;
    break;
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
  case kAooEventBufferUnderrun: if (now_s() - p->pdown_at < PAUSE_S) p->pjitter += 1; break;
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
  case kAooEventBufferUnderrun: if (now_s() - p->mdown_at < PAUSE_S) p->mjitter += 1; break;
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

void pause_audio(RtLink *l)
{
  l->live.store(false);
  for (int i = 0; i < 2000 && l->in_cb.load() > 0; ++i) std::this_thread::sleep_for(std::chrono::microseconds(100)); // (a callback mid-flight finishes)
}
void setup_source(RtLink *l, AooSource *src, int nch, bool start);
void setup_sink(RtLink *l, Slot &p)
{
  if (!p.sink || l->cfg_sr <= 0) return;
  p.sink->setup(2, l->cfg_sr, l->cfg_len, kAooFixedBlockSize);
  if (p.psink) p.psink->setup(2, l->cfg_sr, l->cfg_len, kAooFixedBlockSize);
  if (p.msink) p.msink->setup(2, l->cfg_sr, l->cfg_len, kAooFixedBlockSize);
  if (p.msrc) setup_source(l, p.msrc, 2, p.mserving);
}
std::unique_ptr<Slot> make_slot(RtLink *l, const std::string &peer)
{
  std::unique_ptr<Slot> p(new Slot());
  p->peer = peer;
  p->resolved = resolve(peer, l->loopback, p->addr, p->err);
  if (!p->resolved) return p;
  p->addr_s = addr_str(p->addr);
  p->sink_id = id_of(p->addr_s);
  p->remote_sink_id = id_of(l->bind_s);
  p->sink = AooSink_new(p->sink_id);
  if (!p->sink) { p->resolved = false; p->err = "no AOO sink"; return p; }
  p->sink->setEventHandler(sink_event, p.get(), kAooEventModePoll);
  p->sink->setLatency(BUF_FLOOR / 1000.0);
  p->sink->setPacketSize(1200);
  p->psink_id = id_of(p->addr_s + "/play");
  p->premote_id = id_of(l->bind_s + "/play");
  p->psink = AooSink_new(p->psink_id);
  if (p->psink) {
    p->psink->setEventHandler(play_sink_event, p.get(), kAooEventModePoll);
    p->psink->setLatency(BUF_FLOOR / 1000.0);
    p->psink->setPacketSize(1200);
  }
  p->msink_id = id_of(p->addr_s + "/mix"); // (the hub's live mix: heard from this peer only while it's my hub; made for every peer, it costs nothing idle)
  p->mremote_id = id_of(l->bind_s + "/mix");
  p->msink = AooSink_new(p->msink_id);
  if (p->msink) {
    p->msink->setEventHandler(mix_sink_event, p.get(), kAooEventModePoll);
    p->msink->setLatency(BUF_FLOOR / 1000.0);
    p->msink->setPacketSize(1200);
  }
  p->msrc = AooSource_new(MIX_ID); // (its stream starts only while I mix for this peer: hub_serve)
  if (p->msrc) p->msrc->setPacketSize(1200);
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
  src->setup(nch, l->cfg_sr, l->cfg_len, kAooFixedBlockSize);
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
    for (const std::string &name : split(list)) {
      bool kept = false;
      for (int i = 0; i < l->nslots && !kept; ++i) kept = l->slots[i] && l->slots[i]->resolved && l->slots[i]->peer == name;
      next.push_back(kept ? nullptr : make_slot(l, name)); // (nullptr: the running one is moved over below)
    }
  }
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
    for (int c = 0; c < l->nch; ++c) l->inptr[c] = &l->inbuf[(size_t)c * slen];
    for (int c = 0; c < 2; ++c) { l->mixptr[c] = &l->mixbuf[(size_t)c * slen]; l->pptr[c] = &l->pbuf[(size_t)c * slen]; }
    setup_source(l, l->src, l->nch, true);
    const bool want = l->pshm != nullptr; // (the first block size seen: a Play asked for before it starts now)
    setup_source(l, l->psrc, 2, want);
    l->pstream.store(want);
    for (int i = 0; i < l->nslots; ++i) setup_sink(l, *l->slots[i]);
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
    l->hring.assign(serve && l->cfg_len > 0 ? HUB_RING * l->hstride : 0, 0.f);
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
  if (sendto(l->s, (const char *)l->txbuf, 5 + n + TAG, 0, (const sockaddr *)&p.addr, sizeof(p.addr)) > 0) l->sent.fetch_add(1, std::memory_order_relaxed);
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
  if (!h) st = 0;
  else {
    const double gone = std::max(GONE_MIN, h->target_ms + GONE_PAD) / 1000.0, quiet = now - h->mix_at.load();
    const bool flowing = quiet < gone;
    if (st == 2 && !flowing) { st = 0; ++l->fallbacks; l->retry_at = now + RETRY_S; } // (the hub dropped, or stopped mixing for me: direct at once)
    else if (st != 2) st = now < l->retry_at ? 0 : flowing && now - h->mix_first.load() >= ENTER_S && h->mstreaming ? 2 : 1;
    via = st == 2 && quiet < std::max(std::max(RESCUE_MIN, h->target_ms - RESCUE_LEAD), h->mix_gap.load() * 1000 + RESCUE_PAD) / 1000.0;
    if (st == 2 && !via && l->via_said) ++l->rescues;
  }
  l->hub_state.store(st);
  if (was == 2 && st != 2) l->left_at = now;
  const bool told = via != l->via_said; // (the senders hear of it at once)
  l->via_said = via;
  if (!h && now - l->left_at > MODE_FRESH && !told) return; // (peer to peer, and said so: nothing to say)
  if (now < l->next_ctl && !told) {
    if (!h || st == 0) return;
    std::string sig; // (the levels changed: asked again at once, so a mute or Deafen is heard in one trip)
    for (int i = 0; i < l->nslots; ++i) { char b[48]; snprintf(b, sizeof b, "%.3f,%.3f,%d;", l->slots[i]->gain.load(), l->slots[i]->pgain.load(), (l->slots[i]->mute.load() ? 1 : 0) | (l->slots[i]->want_send.load() ? 0 : 2)); sig += b; }
    if (sig == l->asked_sig) return;
  }
  l->next_ctl = now + MODE_EVERY;
  const unsigned char m = via ? 1 : 0;
  for (int i = 0; i < l->nslots; ++i) send_ctl(l, *l->slots[i], 'M', &m, 1);
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
    if (l->hub_serving) { std::lock_guard<std::mutex> st(l->stats_mx); l->hub_serving = 0; l->hub_load = l->hub_ns = l->hub_audio_s = 0; } // (no stale load once it stops)
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
    }
  }
  l->hr.store(w, std::memory_order_release);
  for (int i = 0; i < ns; ++i) if (l->slots[i]->mserving) l->slots[i]->msrc->send(send_fn, l); // (the encode: most of the cost)
  const double ns_took = (double)std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - t0).count();
  std::lock_guard<std::mutex> st(l->stats_mx);
  l->hub_serving = n;
  l->hub_ns += ns_took;
  l->hub_audio_s += (double)blocks * len / std::max(1, l->cfg_sr);
  if (blocks) l->hub_max_us = std::max(l->hub_max_us, ns_took / 1000.0 / (double)blocks);
  if (now - l->hub_win >= 1.0) { // (its share of one core over the last second or so, and the hub's numbers to each listener: 'I')
    l->hub_load = l->hub_audio_s > 0 ? l->hub_ns / 1e9 / l->hub_audio_s : 0;
    l->hub_ns = l->hub_audio_s = 0;
    l->hub_win = now;
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
    for (int i = 0; i < ns; ++i) if (l->slots[i]->mserving) send_ctl(l, *l->slots[i], 'I', d.data(), (int)d.size());
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
//  - it grows (+20 ms, up to the ceiling) on an underrun: that is already a gap while AOO buffers again, so re-buffering a little longer
//    there costs nothing more than the gap that was coming anyway;
//  - it shrinks (-10 ms) after BUF_STEADY s with no underrun, then every BUF_STEP s, but never down to a size that underran in the last
//    BUF_FORGET s (the smallest size that held), and only while that peer is quiet: a re-buffer is a short gap, so it lands in silence
//    between songs or phrases, never in a held note. shortcut: a peer that never goes quiet keeps its bigger buffer; fine for a band.
// rt_mix fades sound back in after any gap, so neither change clicks. The send thread's, under stats_mx.
void adapt(RtLink *l, Slot &p, double now)
{
  if (!p.sink) return;
  const double sp = l->speed;
  if (p.loud.exchange(0.f) >= BUF_QUIET) p.quiet_since = -1;
  else if (p.quiet_since < 0) p.quiet_since = now;
  double want = p.target_ms;
  if (p.jitter + p.pjitter + p.mjitter != p.jitter_seen) { // (Talk's, Play's or its mix's: one buffer size for all, they come over the same network)
    p.jitter_seen = p.jitter + p.pjitter + p.mjitter;
    p.last_under = now;
    p.fail_ms = std::max(p.fail_ms, p.target_ms);
    want = p.target_ms + BUF_GROW;
  } else if (p.fail_ms > 0 && now - p.last_under > BUF_FORGET / sp) p.fail_ms = 0;
  else if (now - p.last_under > BUF_STEADY / sp && now - p.last_change > BUF_STEP / sp && p.quiet_since >= 0 && now - p.quiet_since > BUF_QUIET_S)
    want = std::max(p.target_ms - BUF_SHRINK, p.fail_ms + BUF_SHRINK);
  want = std::max(p.floor_ms, std::min(p.ceil_ms, want));
  if (want == p.target_ms) return;
  p.target_ms = want;
  p.last_change = now;
  p.sink->setLatency(want / 1000.0);
  if (p.psink) p.psink->setLatency(want / 1000.0);
  if (p.msink) p.msink->setLatency(want / 1000.0);
}

void tx_loop(RtLink *l)
{
  while (l->run.load()) {
    l->wake.wait_for(0.005);
    reconfigure(l);
    apply_sends(l);
    if (!l->live.load()) continue;
    // AOO's source (v2.0-pre4, source.cpp process) reblocks REAPER's blocks into Opus frames through its resampler, and when the
    // send thread falls behind (a stall of ~60 ms on the macOS CI runner) both the resampler and the queue fill. From then on
    // process() gives up on the full resampler before moving it into the queue, so nothing is ever sent again: that peer goes silent
    // for good (C never heard after its secret was fixed, A silent on B). Emptying both, as AOO's own reset does, ends that; the
    // late audio is lost either way. (James, rt)
    if (l->overflow.exchange(false)) l->src->reset();
    if (l->poverflow.exchange(false)) l->psrc->reset();
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
void rx_loop(RtLink *l)
{
  std::vector<unsigned char> buf(AOO_MAX_PACKET_SIZE + 64);
  while (l->run.load()) {
    const double hold = l->hold_until.load() - now_s();
    if (hold > 0) { std::this_thread::sleep_for(std::chrono::milliseconds(1)); continue; } // (the socket keeps what comes meanwhile; short sleeps: a VM's long ones overshoot)
    sockaddr_in from{};
    socklen_t fl = sizeof(from);
    const int n = (int)recvfrom(l->s, (char *)buf.data(), (int)buf.size(), 0, (sockaddr *)&from, &fl);
    if (n <= 0 || fl < (socklen_t)sizeof(from)) continue; // (the receive timeout: a look at run)
    l->received.fetch_add(1, std::memory_order_relaxed);
    if (!addr_ok(from, l->loopback)) { reject(l, "not a Tailscale address", from); continue; }
    if (n >= 4 && memcmp(buf.data(), "SSH1", 4) == 0) { // (a hop's audio, extension/hopnet.cpp: same port, its own tag and key)
      l->extra_in.fetch_add(1);
      if (rt_extra_fn fn = l->extra.load()) fn(l->extra_user.load(), buf.data(), n, &from, (int)sizeof(from));
      l->extra_in.fetch_sub(1);
      continue;
    }
    if (n >= 5 + TAG && memcmp(buf.data(), CTL, 4) == 0) { // (the hub's live mix: a control datagram, tagged as the rest)
      std::lock_guard<std::mutex> g(l->cfg_mx);
      if (l->key.empty()) { reject(l, "no studio secret here yet", from); continue; }
      unsigned char t[32];
      tag_of(l->key, buf.data(), (size_t)n - TAG, t);
      if (!same_tag(t, buf.data() + n - TAG)) { reject(l, "wrong studio secret", from); continue; }
      Slot *p = slot_of(l, from);
      if (!p) { reject(l, "not one of the studio's computers here", from); continue; }
      handle_ctl(l, *p, buf.data() + 4, n - 4 - TAG, now_s());
      continue;
    }
    if (n < 4 + TAG + 4 || memcmp(buf.data(), MAGIC, 4) != 0) { reject(l, "not StudioSync audio", from); continue; }
    const AooByte *msg = buf.data() + 4;
    const AooInt32 size = n - 4 - TAG;
    {
      std::lock_guard<std::mutex> g(l->cfg_mx);
      if (l->key.empty()) { reject(l, "no studio secret here yet", from); continue; }
      unsigned char t[32];
      tag_of(l->key, buf.data(), (size_t)n - TAG, t);
      if (!same_tag(t, buf.data() + n - TAG)) { reject(l, "wrong studio secret", from); continue; }
      AooMsgType type;
      AooId id;
      AooInt32 onset;
      if (aoo_parsePattern(msg, size, &type, &id, &onset) != kAooOk) { reject(l, "not an AOO message", from); continue; }
      Slot *p = slot_of(l, from);
      if (!p) { reject(l, "not one of the studio's computers here", from); continue; }
      if (type == kAooMsgTypeSink && id == p->sink_id && p->sink) p->sink->handleMessage(msg, size, &from, (AooAddrSize)sizeof(from));
      else if (type == kAooMsgTypeSink && id == p->psink_id && p->psink) p->psink->handleMessage(msg, size, &from, (AooAddrSize)sizeof(from));
      else if (type == kAooMsgTypeSource && id == SRC_ID && l->src) l->src->handleMessage(msg, size, &from, (AooAddrSize)sizeof(from));
      else if (type == kAooMsgTypeSource && id == PLAY_ID && l->psrc) l->psrc->handleMessage(msg, size, &from, (AooAddrSize)sizeof(from));
      else if (type == kAooMsgTypeSink && id == p->msink_id && p->msink) { // (my hub's mix for me: when it last came, and since when unbroken)
        const double now = now_s(), since = now - p->mix_at.load();
        if (since > 0.1) p->mix_first.store(now);
        else p->mix_gap.store(std::max(since, p->mix_gap.load() * 0.999)); // (the widest spacing lately, ~3 s to fade: how long a pause is only jitter)
        p->mix_at.store(now);
        p->msink->handleMessage(msg, size, &from, (AooAddrSize)sizeof(from));
      } else if (type == kAooMsgTypeSource && id == MIX_ID && p->msrc) p->msrc->handleMessage(msg, size, &from, (AooAddrSize)sizeof(from));
      else { reject(l, "for a stream that isn't theirs", from); continue; }
    }
    l->wake.set(); // (replies and resend requests go out now)
  }
}
} // namespace

RtLink *rt_new() { return new RtLink(); }
void rt_free(RtLink *l)
{
  if (!l) return;
  rt_stop(l);
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
  const std::string ip = bind_ip && *bind_ip ? std::string(bind_ip) : tailscale_ip();
  if (ip.empty()) { l->err = "Tailscale isn't up here (no 100.64.0.0/10 address)"; return 0; }
  sockaddr_in me{};
  me.sin_family = AF_INET;
  me.sin_port = htons((unsigned short)port);
  if (inet_pton(AF_INET, ip.c_str(), &me.sin_addr) != 1) { l->err = "bad address"; return 0; }
  l->loopback = ip.compare(0, 4, "127.") == 0;
  if (!addr_ok(me, l->loopback)) { l->err = "not a Tailscale address"; return 0; }
  sock_t s = socket(AF_INET, SOCK_DGRAM, 0);
  if (s == BAD_SOCK) { l->err = "no socket"; return 0; }
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
  l->callbacks = 0; l->max_ns = 0; l->sent = 0; l->received = 0; l->rejected = 0; l->last_reject.clear(); l->last_reject_from.clear();
  l->src = AooSource_new(SRC_ID);
  l->src->setEventHandler(source_event, l, kAooEventModePoll);
  l->src->setPacketSize(1200);
  l->psrc = AooSource_new(PLAY_ID); // (no events: Talk's source pings say the round trip and loss)
  l->psrc->setPacketSize(1200);
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
  if (!l->run.load() || l->s == BAD_SOCK || !addr_ok(to, l->loopback)) return -1;
  return (int)sendto(l->s, (const char *)d, n, 0, (const sockaddr *)&to, sizeof(to));
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
  snprintf(b, sizeof(b), ",\"secret\":%s,\"srate\":%d,\"block\":%d,\"first\":%d,\"nch\":%d,\"kbps\":%d,\"level\":%.5f,\"callbacks\":%lld,\"max_us\":%.1f,\"sent\":%lld,\"received\":%lld,\"rejected\":%lld,\"peers\":{",
           l->key.empty() ? "false" : "true", l->cfg_sr, l->cfg_len, l->first, l->nch, l->kbps, l->in_peak.exchange(0.f), l->callbacks.load(), l->max_ns.load() / 1000.0,
           l->sent.load(), l->received.load(), l->rejected.load());
  o += b;
  // (Play: the live out Hop read, whether its track ran lately (a full block in the last ~50 callbacks), and what goes out, peak since the last ask)
  const bool palive = l->pstream.load() && l->callbacks.load() - l->play_ok_cb.load() < 50;
  snprintf(b, sizeof(b), "\"play\":%d,\"play_alive\":%s,\"play_send\":%s,\"play_level\":%.5f,", l->pstream.load() ? l->phop : 0, palive ? "true" : "false",
           l->play_send.load() ? "true" : "false", l->play_peak.exchange(0.f));
  o.insert(o.size() - 9, b); // (before "peers":{)
  const double now = now_s();
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
    snprintf(b, sizeof(b), ",\"state\":\"%s\",\"serve\":%s,\"serving\":%d,\"load\":%.4f,\"max_us\":%.1f,\"skipped\":%lld,\"fallbacks\":%lld,\"rescues\":%lld,\"latency_ms\":%.1f,\"in_ms\":%.1f,\"direct_ms\":%.1f,\"hub_load\":%.4f,\"level\":%.5f}",
             hs == 2 ? "hub" : hs == 1 ? "joining" : "direct", l->serve ? "true" : "false", l->hub_serving, l->hub_load, l->hub_max_us, l->hskipped.load(), l->fallbacks, l->rescues,
             through, h ? h->hin_ms.load() : -1.f, nd ? direct / nd : -1.0, h ? h->hload.load() : -1.f, h ? h->mpeak.exchange(0.f) : 0.f);
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
             p.ppeak.exchange(0.f), p.pgain.load(), l->hub_state.load() == 2 ? "true" : "false", hears_direct(p, now) ? "true" : "false"); // (via_hub: heard in the hub's mix; direct: my streams go to it)
    o.insert(o.size() - 1, b); // (inside the peer's object)
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
void rt_capture(RtLink *l, const double *const *in, int nin, int len, double srate)
{
  if (!l || len <= 0) return;
  l->in_cb.fetch_add(1);
  if (l->run.load(std::memory_order_relaxed)) {
    const auto t0 = std::chrono::steady_clock::now();
    l->callbacks.fetch_add(1, std::memory_order_relaxed);
    l->seen_sr.store(srate, std::memory_order_relaxed);
    l->seen_len.store(len, std::memory_order_relaxed);
    if (l->live.load() && (int)srate == l->cfg_sr && len == l->cfg_len) {
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
      const AooError e = l->src->process(l->inptr, len, aoo_getCurrentNtpTime());
      if (e == kAooErrorOverflow) l->overflow.store(true); // (the send thread unsticks AOO's queue: tx_loop)
      if (e == kAooOk || e == kAooErrorOverflow) l->wake.set();
    } else l->wake.set(); // (a new sample rate or block size: the send thread sets AOO up for it)
    took(l, t0);
  }
  l->in_cb.fetch_sub(1);
}
// Play's input (the hook's post call): the live out track's StudioSync Hop wrote this block's frames into its send ring during REAPER's FX
// pass, just before this, so the newest `len` frames are this block's sound of the armed tracks. Fewer there (the track isn't running,
// REAPER stopped its audio, no Hop yet): silence goes out. Far behind (a new Hop instance, a stall): only the newest block, never a backlog
// that would sit in the stream as delay. (James, rt)
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
    const AooNtpTime t = aoo_getCurrentNtpTime();
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
    auto hear = [&](Slot &p, AooSink *sink, std::atomic<bool> &mono, std::atomic<float> &peak, bool &was_quiet, float gain, float r0, float r1, float *to) {
      if (!sink || sink->process(l->mixptr, len, t, nullptr, nullptr) != kAooOk) { if (to) std::fill(to, to + 2 * len, 0.f); return; }
      float *L = l->mixptr[0], *R = l->mixptr[1];
      if (mono.load(std::memory_order_relaxed)) std::copy(L, L + len, R); // (a mono sender: both ears)
      float pk = 0;
      for (int k = 0; k < len; ++k) pk = std::max(pk, std::max(std::fabs(L[k]), std::fabs(R[k])));
      if (pk > peak.load(std::memory_order_relaxed)) peak.store(pk, std::memory_order_relaxed);
      if (pk > p.loud.load(std::memory_order_relaxed)) p.loud.store(pk, std::memory_order_relaxed);
      const bool quiet = pk < 1e-4f; // (AOO's silence in a gap or a re-buffer: under -80 dBFS)
      if (was_quiet && !quiet) for (int k = 0; k < len; ++k) { const float g = (float)k / (float)len; L[k] *= g; R[k] *= g; } // (back after a gap: faded in over one block, no click)
      was_quiet = quiet;
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
      hear(p, p.sink, p.mono, p.peak, p.was_quiet, m ? 0.f : p.gain.load(std::memory_order_relaxed), 1 - w0, 1 - w1, to);
      hear(p, p.psink, p.pmono, p.ppeak, p.pwas_quiet, m ? 0.f : p.pgain.load(std::memory_order_relaxed), 1 - w0, 1 - w1, to ? to + 2 * len : nullptr);
    }
    if (hp) { // (my hub's mix, already at my levels: decoded while asked for, so it's ready the moment it's heard)
      std::atomic<bool> stereo{ false };
      hear(*hp, hp->msink, stereo, hp->mpeak, hp->mwas_quiet, 1.f, w0, w1, nullptr);
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
  }
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
static RtLink *g_rt = nullptr; // (made once at load, freed never while REAPER runs: the hook may still hold it for a moment after removal)
RtLink *rt_global() { return g_rt; }
static int (*g_reg_hook)(bool isAdd, audio_hook_register_t *reg) = nullptr;
static bool g_hooked = false;
static std::string g_status;
static void on_audio(bool isPost, int len, double srate, audio_hook_register_t *reg)
{
  if (!isPost) { // (before REAPER's processing: the hardware inputs as they came in)
    const double *in[64] = { nullptr };
    const int nin = std::min(reg->input_nch, 64);
    for (int c = 0; c < nin; ++c) in[c] = reg->GetBuffer(false, c);
    rt_capture(g_rt, in, nin, len, srate);
  } else { // (after: added to what REAPER is about to play out of the first output pair)
    double *out[2] = { nullptr, nullptr };
    const int nout = std::min(reg->output_nch, 2);
    for (int c = 0; c < nout; ++c) out[c] = reg->GetBuffer(true, c);
    rt_mix(g_rt, out, nout, len, srate);
  }
}
static audio_hook_register_t g_hook = { on_audio, nullptr, nullptr, 0, 0, nullptr };

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
static const char *api_status() { g_status = g_rt ? rt_status(g_rt) : "{}"; return g_status.c_str(); }
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
static void *vla_hub(void **a, int n) { return n < 2 ? nullptr : (void *)(INT_PTR)api_hub((const char *)a[0], (int)(INT_PTR)a[1]); }

void rtaudio_shutdown()
{
  api_stop();
  if (g_rt) for (const hop_map &m : g_rt->pnames) hop_shm_unlink(&m); // (the live out mappings' POSIX names, as extension/hop.cpp's)
}

void rtaudio_register(reaper_plugin_info_t *rec)
{
  g_reg_hook = (int (*)(bool, audio_hook_register_t *))rec->GetFunc("Audio_RegHardwareHook");
  if (!g_rt) g_rt = rt_new();
  static const struct { const char *name; void *fn, *va; const char *def; } fns[] = {
    { "StudioSync_LiveAudioStart", (void *)api_start, (void *)vla_start,
      "int\0int,int,int\0inputs,nch,kbps\0StudioSync's live audio: send hardware inputs inputs..inputs+nch-1 (0-based, nch 1-8) as Opus at kbps (16-512, the total) to the peers (StudioSync_LiveAudioPeers) over Tailscale UDP, and mix theirs into the first output pair. Call StudioSync_LiveAudioPeers first: it gives the studio secret and the port. Returns 1 when started (or already running: stop first to change inputs or rate)." },
    { "StudioSync_LiveAudioStop", (void *)api_stop, (void *)vla_stop, "void\0\0\0Stop StudioSync's live audio (the hook comes out, the socket closes)." },
    { "StudioSync_LiveAudioPeers", (void *)api_peers, (void *)vla_peers,
      "int\0const char*\0json\0Who to send to and hear, and the key: {\"secret\":\"<the studio secret>\",\"port\":47281,\"peers\":[\"name:port\",...]} (the direct link's list; Tailscale addresses only). Returns how many peers, or -1 when the JSON isn't that." },
    { "StudioSync_LiveAudioStatus", (void *)api_status, (void *)vla_status,
      "const char*\0\0\0StudioSync's live audio as JSON: running, bind, error, secret, srate, block, level (what you send, peak since the last ask), callbacks, max_us, sent, received, rejected, last_reject, last_reject_from (its sender's ip:port), and per peer: resolved, streaming, rtt_ms, latency_ms, buffer_ms (the jitter buffer), target_ms, floor_ms, ceiling_ms (the adaptive buffer's size and bounds), loss (0-1), dropped, underruns, level (peak since the last ask), gain, mute, play_streaming, play_level, play_gain (their Play stream); and play (the live out hop id, 0: no Play), play_alive, play_send, play_level (what this computer plays out)." },
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
    { "StudioSync_LiveAudioHub", (void *)api_hub, (void *)vla_hub,
      "int\0const char*,int\0peer,serve\0The hub's live mix: peer (in the list) mixes for this computer, which then sends its streams to it alone and hears the one stream it mixes at this computer's own levels, back to everyone's own streams at once when that mix stops; \"\": peer to peer. serve 1: this computer mixes for every listener that asks. StudioSync_LiveAudioStatus's hub (peer, state direct/joining/hub, serve, serving, load, max_us, skipped, fallbacks, latency_ms, in_ms, direct_ms, hub_load) and per peer via_hub, direct say how it goes. Returns 1." },
  };
  char key[96];
  for (const auto &f : fns) {
    snprintf(key, sizeof(key), "API_%s", f.name); rec->Register(key, f.fn);
    snprintf(key, sizeof(key), "APIdef_%s", f.name); rec->Register(key, (void *)f.def);
    snprintf(key, sizeof(key), "APIvararg_%s", f.name); rec->Register(key, f.va);
  }
  rec->Register("atexit", (void *)rtaudio_shutdown); // (the hook out before REAPER goes)
}
#endif
