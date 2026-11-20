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
// One AOO source (id 1) sends to every peer; one AOO sink per peer, so each peer has its own level and mute (the cue mix). A peer's
// sink id is a hash of its "ip:port", so a sender knows which id its stream goes to on the other side without asking.
// Auth: every datagram is "SSL1" + the AOO message + 16 bytes of HMAC-SHA256 with a key made from the studio secret (as the direct
// link's frames, direct.cpp), so only studio computers are heard; AOO's own passwords live in its server/client part, not built here.
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
#include "direct.h"
#include "rtaudio.h"

namespace {
const AooId SRC_ID = 1;
const char MAGIC[4] = { 'S', 'S', 'L', '1' };
const int TAG = 16, MAX_DGRAM = 1400; // (Tailscale's MTU is 1280: AOO's packets are kept to 1200 below, plus our 20 bytes)
const int OPUS_FRAME = 240;           // samples at 48 kHz: 5 ms frames (2.5 ms doubles the packets for little gain over Tailscale)
const double SINK_LATENCY = 0.03;     // the jitter buffer's target, seconds (AOO's default is 50 ms; over Tailscale 30 ms held. James, rt)

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
  long long dropped = 0, underruns = 0;
};
} // namespace

struct RtLink {
  std::mutex api_mx, pend_mx, cfg_mx, stats_mx;
  std::string key, bind_s, err, last_reject, want_peers, want_secret, have_secret;
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
  case kAooEventStreamState: p->streaming = e->streamState.state == kAooStreamStateActive; break;
  case kAooEventStreamStop: case kAooEventSourceRemove: p->streaming = false; break;
  case kAooEventBlockDrop: p->dropped += e->blockDrop.count; break;
  case kAooEventBufferUnderrun: p->underruns += 1; break;
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
void setup_sink(RtLink *l, Slot &p)
{
  if (!p.sink || l->cfg_sr <= 0) return;
  p.sink->setup(2, l->cfg_sr, l->cfg_len, kAooFixedBlockSize);
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
  p->sink->setLatency(SINK_LATENCY);
  p->sink->setPacketSize(1200);
  setup_sink(l, *p);
  return p;
}
void drop_slot(RtLink *l, Slot &p)
{
  if (p.resolved && l->src) { AooEndpoint ep = { &p.addr, (AooAddrSize)sizeof(p.addr), p.remote_sink_id }; l->src->removeSink(ep); }
  if (p.sink) AooSink_free(p.sink);
  p.sink = nullptr;
}
void setup_source(RtLink *l)
{
  l->src->setup(l->nch, l->cfg_sr, l->cfg_len, kAooFixedBlockSize);
  AooFormatOpus fmt;
  AooFormatOpus_init(&fmt, l->nch, 48000, OPUS_FRAME, OPUS_APPLICATION_RESTRICTED_LOWDELAY); // (CELT only: the lowest delay, made for music)
  l->src->setFormat(fmt.header);
  opus_int32 br = l->kbps * 1000;
  l->src->codecControl(kAooCodecOpus, OPUS_SET_BITRATE_REQUEST, 0, &br, sizeof(br));
  l->src->startStream(0, nullptr);
}

// The send thread's changes: a new sample rate or block size, a new peer list (or a peer whose name didn't resolve, every 5 s).
void reconfigure(RtLink *l)
{
  const double ssr = l->seen_sr.load();
  const int slen = l->seen_len.load();
  const bool audio = ssr > 0 && slen > 0 && ((int)ssr != l->cfg_sr || slen != l->cfg_len);
  bool peers = false;
  std::string list, secret;
  {
    std::lock_guard<std::mutex> g(l->pend_mx);
    peers = l->peers_dirty;
    l->peers_dirty = false;
    list = l->want_peers;
    secret = l->want_secret;
  }
  if (secret != l->have_secret) { // (a new studio secret: the receive thread checks tags under cfg_mx, the send thread is this one)
    std::lock_guard<std::mutex> g(l->cfg_mx);
    l->have_secret = secret;
    l->key = key_of(secret);
  }
  if (!peers && now_s() > l->next_resolve) {
    for (int i = 0; i < l->nslots; ++i) peers = peers || !l->slots[i]->resolved;
    l->next_resolve = now_s() + 5;
  }
  if (!audio && !peers) return;
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
  if (audio) {
    l->cfg_sr = (int)ssr;
    l->cfg_len = slen;
    l->inbuf.assign((size_t)l->nch * slen, 0.f);
    l->mixbuf.assign((size_t)2 * slen, 0.f);
    for (int c = 0; c < l->nch; ++c) l->inptr[c] = &l->inbuf[(size_t)c * slen];
    for (int c = 0; c < 2; ++c) l->mixptr[c] = &l->mixbuf[(size_t)c * slen];
    setup_source(l);
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
      if (!p.resolved || p.added) continue;
      AooEndpoint ep = { &p.addr, (AooAddrSize)sizeof(p.addr), p.remote_sink_id };
      p.added = l->src->addSink(ep, kAooTrue) == kAooOk;
    }
  }
  l->live.store(l->cfg_sr > 0);
}

// Talkback (rt_send with a peer): a peer left out stops getting this computer's stream (AOO deactivates that sink; let back in, its jitter buffer
// refills, a few tens of ms). The send thread's, as every change to the source. (James, rt)
void apply_sends(RtLink *l)
{
  for (int i = 0; i < l->nslots; ++i) {
    Slot &p = *l->slots[i];
    const bool want = p.want_send.load();
    if (!p.added || want == p.sending) continue;
    AooEndpoint ep = { &p.addr, (AooAddrSize)sizeof(p.addr), p.remote_sink_id };
    if (l->src->activate(ep, want ? kAooTrue : kAooFalse) == kAooOk) p.sending = want;
  }
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
    l->src->send(send_fn, l);
    for (int i = 0; i < l->nslots; ++i) if (l->slots[i]->sink) l->slots[i]->sink->send(send_fn, l);
    std::lock_guard<std::mutex> g(l->stats_mx);
    l->src->pollEvents();
    for (int i = 0; i < l->nslots; ++i) if (l->slots[i]->sink) l->slots[i]->sink->pollEvents();
  }
}

void reject(RtLink *l, const char *why)
{
  l->rejected.fetch_add(1, std::memory_order_relaxed);
  std::lock_guard<std::mutex> g(l->stats_mx);
  l->last_reject = why;
}
void rx_loop(RtLink *l)
{
  std::vector<unsigned char> buf(AOO_MAX_PACKET_SIZE + 64);
  while (l->run.load()) {
    sockaddr_in from{};
    socklen_t fl = sizeof(from);
    const int n = (int)recvfrom(l->s, (char *)buf.data(), (int)buf.size(), 0, (sockaddr *)&from, &fl);
    if (n <= 0 || fl < (socklen_t)sizeof(from)) continue; // (the receive timeout: a look at run)
    l->received.fetch_add(1, std::memory_order_relaxed);
    if (!addr_ok(from, l->loopback)) { reject(l, "not a Tailscale address"); continue; }
    if (n < 4 + TAG + 4 || memcmp(buf.data(), MAGIC, 4) != 0) { reject(l, "not StudioSync audio"); continue; }
    const AooByte *msg = buf.data() + 4;
    const AooInt32 size = n - 4 - TAG;
    {
      std::lock_guard<std::mutex> g(l->cfg_mx);
      if (l->key.empty()) { reject(l, "no studio secret here yet"); continue; }
      unsigned char t[32];
      tag_of(l->key, buf.data(), (size_t)n - TAG, t);
      if (!same_tag(t, buf.data() + n - TAG)) { reject(l, "wrong studio secret"); continue; }
      AooMsgType type;
      AooId id;
      AooInt32 onset;
      if (aoo_parsePattern(msg, size, &type, &id, &onset) != kAooOk) { reject(l, "not an AOO message"); continue; }
      Slot *p = slot_of(l, from);
      if (!p) { reject(l, "not one of the studio's computers here"); continue; }
      if (type == kAooMsgTypeSink && id == p->sink_id && p->sink) p->sink->handleMessage(msg, size, &from, (AooAddrSize)sizeof(from));
      else if (type == kAooMsgTypeSource && id == SRC_ID && l->src) l->src->handleMessage(msg, size, &from, (AooAddrSize)sizeof(from));
      else { reject(l, "for a stream that isn't theirs"); continue; }
    }
    l->wake.set(); // (replies and resend requests go out now)
  }
}
} // namespace

RtLink *rt_new() { return new RtLink(); }
void rt_free(RtLink *l) { if (l) { rt_stop(l); delete l; } }

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
  l->callbacks = 0; l->max_ns = 0; l->sent = 0; l->received = 0; l->rejected = 0; l->last_reject.clear();
  l->src = AooSource_new(SRC_ID);
  l->src->setEventHandler(source_event, l, kAooEventModePoll);
  l->src->setPacketSize(1200);
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
  if (l->src) AooSource_free(l->src);
  l->src = nullptr;
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
  snprintf(b, sizeof(b), ",\"secret\":%s,\"srate\":%d,\"block\":%d,\"first\":%d,\"nch\":%d,\"kbps\":%d,\"level\":%.5f,\"callbacks\":%lld,\"max_us\":%.1f,\"sent\":%lld,\"received\":%lld,\"rejected\":%lld,\"peers\":{",
           l->key.empty() ? "false" : "true", l->cfg_sr, l->cfg_len, l->first, l->nch, l->kbps, l->in_peak.exchange(0.f), l->callbacks.load(), l->max_ns.load() / 1000.0,
           l->sent.load(), l->received.load(), l->rejected.load());
  o += b;
  for (int i = 0; i < l->nslots; ++i) {
    Slot &p = *l->slots[i];
    if (i) o += ',';
    json_str(o, p.peer);
    o += ":{\"addr\":"; json_str(o, p.addr_s);
    o += ",\"error\":"; json_str(o, p.err);
    // latency: one way, mouth to ear less the audio interfaces' own buffers = half the round trip + the jitter buffer + both ends' codec/reblocking
    const double lat = p.rtt_ms >= 0 && p.buffer_ms >= 0 ? p.rtt_ms / 2 + p.buffer_ms + p.src_lat_ms + p.sink_lat_ms : -1;
    snprintf(b, sizeof(b), ",\"resolved\":%s,\"streaming\":%s,\"rtt_ms\":%.1f,\"latency_ms\":%.1f,\"buffer_ms\":%.1f,\"loss\":%.4f,\"dropped\":%lld,\"underruns\":%lld,\"level\":%.5f,\"gain\":%.3f,\"mute\":%s}",
             p.resolved ? "true" : "false", p.streaming ? "true" : "false", p.rtt_ms, lat, p.buffer_ms, p.loss, p.dropped, p.underruns,
             p.peak.exchange(0.f), p.gain.load(), p.mute.load() ? "true" : "false"); // (level: the peak since the last ask, before the cue mix's level)
    o += b;
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
void rt_mix(RtLink *l, double *const *out, int nout, int len, double srate)
{
  if (!l || len <= 0) return;
  l->in_cb.fetch_add(1);
  if (l->live.load() && (int)srate == l->cfg_sr && len == l->cfg_len) {
    const auto t0 = std::chrono::steady_clock::now();
    const AooNtpTime t = aoo_getCurrentNtpTime();
    for (int i = 0; i < l->nslots; ++i) {
      Slot &p = *l->slots[i];
      if (!p.sink || p.sink->process(l->mixptr, len, t, nullptr, nullptr) != kAooOk) continue;
      float *L = l->mixptr[0], *R = l->mixptr[1];
      if (p.mono.load(std::memory_order_relaxed)) std::copy(L, L + len, R); // (a mono sender: both ears)
      float pk = 0;
      for (int k = 0; k < len; ++k) pk = std::max(pk, std::max(std::fabs(L[k]), std::fabs(R[k])));
      if (pk > p.peak.load(std::memory_order_relaxed)) p.peak.store(pk, std::memory_order_relaxed);
      if (p.mute.load(std::memory_order_relaxed) || !out) continue;
      const double gn = p.gain.load(std::memory_order_relaxed);
      if (nout > 0 && out[0]) for (int k = 0; k < len; ++k) out[0][k] += gn * L[k];
      if (nout > 1 && out[1]) for (int k = 0; k < len; ++k) out[1][k] += gn * R[k];
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
static void *vla_start(void **a, int n) { return n < 3 ? nullptr : (void *)(INT_PTR)api_start((int)(INT_PTR)a[0], (int)(INT_PTR)a[1], (int)(INT_PTR)a[2]); }
static void *vla_stop(void **, int) { api_stop(); return nullptr; }
static void *vla_peers(void **a, int n) { return n < 1 ? nullptr : (void *)(INT_PTR)api_peers((const char *)a[0]); }
static void *vla_status(void **, int) { return (void *)api_status(); }
static void *vla_send(void **a, int n) { return n < 2 ? nullptr : (void *)(INT_PTR)api_send((const char *)a[0], (int)(INT_PTR)a[1]); }
static void *vla_peer_set(void **a, int n) { return n < 3 || !a[1] ? nullptr : (void *)(INT_PTR)api_peer_set((const char *)a[0], *(double *)a[1], (int)(INT_PTR)a[2]); } // (a double comes as a pointer)

void rtaudio_shutdown() { api_stop(); }

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
      "const char*\0\0\0StudioSync's live audio as JSON: running, bind, error, secret, srate, block, level (what you send, peak since the last ask), callbacks, max_us, sent, received, rejected, last_reject, and per peer: resolved, streaming, rtt_ms, latency_ms, buffer_ms (the jitter buffer), loss (0-1), dropped, underruns, level (peak since the last ask), gain, mute." },
    { "StudioSync_LiveAudioPeerSet", (void *)api_peer_set, (void *)vla_peer_set,
      "int\0const char*,double,int\0peer,gain,mute\0A peer's level (linear, 0-4) and mute in what you hear (the cue mix). Returns 1 when that peer is in the list." },
    { "StudioSync_LiveAudioSend", (void *)api_send, (void *)vla_send,
      "int\0const char*,int\0peer,on\0What this computer sends. peer \"\": everything (on 0 sends silence while the stream stays up: Mute me, push-to-talk). A peer in the list: whether that peer gets it (talkback: one bandmate hears you, the others don't). Returns 1 when done (0: that peer isn't in the list)." },
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
