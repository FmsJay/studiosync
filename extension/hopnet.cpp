// StudioSync Hop's network leg (docs/realtime-roadmap.md 4b, "live hops"; plugin/hop_shm.h is the interface it fills in).
// James's rule (rt): "always has to do playback so everything is synced up, means playing everything later enough". The Hop plug-in
// reports a fixed latency L; REAPER plays the rest of the mix L later; this file has to bring every frame back before then.
//
// Transport: raw 32-bit float PCM, stereo, 128 frames a datagram (1060 bytes, under Tailscale's 1280 MTU), on live audio's UDP socket
// (extension/rtaudio.cpp passes us every datagram that starts "SSH1"), each tagged with HMAC-SHA256 from the studio secret under a label
// of its own. Not AOO + Opus: AOO's sink resamples to the receiver's clock and hands out blocks, not numbered frames, and Opus is lossy
// with a decoder delay, so a return could never line up to the sample with what was sent. Float, not 24-bit: a bus inside REAPER can run
// over 0 dBFS, and integers would clip it. 3.1 Mbit/s each way per hop at 48 kHz. (James, rt)
//
// Frame numbers are the clock. The sender tags each packet with the absolute frame number of its first frame (the hop's send ring index);
// the remote returns the processed audio under the same numbers; the sender writes it into the ret ring at those numbers. A frame that
// isn't back in time is filled in (the next ones fade in) and counted, so ret_w never skips a hole: with the dry input from the send ring
// when the plug-in says so (its "Dry when late", dry_lost in the mapping), else silence (rt-hopvst: a lost frame was always silence).
//
// MIDI (rt-hopvst, an instrument you don't have): the plug-in's MIDI events (send_midi, numbered by send_mw) go in their own packets once
// their frame has been published, each sent twice at least (in the next packet's window too, or again 20 ms on); the remote takes each
// number once, puts it at X frame f + A in X's ret_midi, and X plays it with that frame's audio. A note-off lost twice can hang a note.
//
// The remote: a hidden track in the bandmate's REAPER holds Hop X (hop id x), the plug-ins, then Hop Y (hop id y): the same plug-in
// binary at both ends, no new one (step 4b findings). X plays what we write into its ret ring (its input is silence), Y's send ring is
// the processed audio. Three numbers line them up:
//   - A: requester frame f is written into X's ret ring at x = f + A. A is set on the first packet so it lands margin_ms ahead of where X
//     plays; when the two computers' audio clocks drift apart (tens of ppm) it's moved (a "slip": one click, never a timing change).
//   - fmap: for every X frame, which requester frame was written there. So a slip never mislabels a return: it can only lose frames.
//   - delta: Xw - Yw when both have run the same blocks (X runs first in each block, so read Y then X: the smallest value seen is it).
//   Y frame y carries X frame y + delta - pdc - Lx (Lx: X's own reported latency; pdc: the plug-ins' between X and Y; the hidden track
//   has its chain's PDC set to "ignore", so REAPER adds nothing of its own there), which carries requester frame fmap[that].
// GPL-3.0-or-later.
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#endif
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include "../plugin/hop_shm.h"
#include "direct.h"
#include "hopnet.h"

namespace {
const char MAGIC[4] = { 'S', 'S', 'H', '1' };
enum { T_AUDIO = 1, T_RET = 2, T_PING = 3, T_PONG = 4, T_MIDI = 5 };
const int HDR = 20, TAG = 16, PKT = 128;                    // header: magic, type, version, frames u16, token u32, frame u64
const int MAXD = HDR + PKT * HOP_CH * 4 + 32 + TAG;
const uint64_t HALF = HOP_FRAMES / 2;
const int FADE = 64;                                          // frames faded in after a concealed hole
const int MPKT = 32, MEV = 16;                                // MIDI: events a packet, bytes an event (frame u64, msg u32, len u32)
const uint64_t MM = HOP_MIDI - 1;
const double LATE_HOLD = 0.08, LATE_GAP = 0.04;              // s: packets late at the remote for LATE_HOLD, never LATE_GAP apart, are drift
enum { F_ALIVE = 1, F_DELTA = 2, F_SRATE = 4 };              // the remote's state, in each pong
// rt-hop2 item 5 (two hops at once lost more): both Hops publish in the same REAPER block, and each poll sent everything published since the
// last one back to back, so two hops to one computer made bursts twice as big at the same instants, which a link with a small queue drops.
// With two or more hops to one computer (either way), each hop's frames go out paced at PACE times real time from the first packet of its
// block: a 512-frame block over 5.3 ms at 48 kHz, not at once. Never more than a block behind (a play start's whole-latency burst still
// goes at once: those frames can't be back in time anyway). A lone hop is unchanged. Costs its last packet up to (block - 128) / PACE frames.
const double PACE = 1.5;

double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
uint64_t now_us() { return (uint64_t)(now_s() * 1e6); }
void put32(unsigned char *p, uint32_t v) { memcpy(p, &v, 4); } // (little-endian on every computer StudioSync runs on)
void put64(unsigned char *p, uint64_t v) { memcpy(p, &v, 8); }
uint32_t get32(const unsigned char *p) { uint32_t v; memcpy(&v, p, 4); return v; }
uint64_t get64(const unsigned char *p) { uint64_t v; memcpy(&v, p, 8); return v; }

std::string key_of(const std::string &secret)
{
  if (secret.empty()) return "";
  static const char label[] = "StudioSync hop v1"; // (its own label: a hop tag can't pass for live audio's or the direct link's)
  unsigned char k[32];
  direct_hmac_sha256((const unsigned char *)secret.data(), secret.size(), (const unsigned char *)label, sizeof(label) - 1, k);
  return std::string((const char *)k, 32);
}
bool tag_ok(const std::string &key, const unsigned char *d, int n)
{
  unsigned char t[32], diff = 0;
  direct_hmac_sha256((const unsigned char *)key.data(), key.size(), d, (size_t)n - TAG, t);
  for (int i = 0; i < TAG; ++i) diff |= t[i] ^ d[n - TAG + i]; // (constant time)
  return diff == 0;
}

// A flat JSON object's value by key: a string's text, or a number/true/false as written. Only what Lua's hops.lua sends.
bool jget(const std::string &j, const char *key, std::string &out)
{
  const std::string k = std::string("\"") + key + "\"";
  for (size_t at = j.find(k); at != std::string::npos; at = j.find(k, at + 1)) {
    size_t b = at;
    while (b > 0 && (j[b - 1] == ' ' || j[b - 1] == '\t' || j[b - 1] == '\n' || j[b - 1] == '\r')) --b;
    if (b == 0 || (j[b - 1] != '{' && j[b - 1] != ',')) continue; // (inside a value, not a key)
    size_t i = at + k.size();
    while (i < j.size() && (j[i] == ' ' || j[i] == ':' || j[i] == '\t')) ++i;
    out.clear();
    if (i < j.size() && j[i] == '"') {
      for (++i; i < j.size() && j[i] != '"'; ++i) {
        if (j[i] == '\\' && i + 1 < j.size()) ++i;
        out += j[i];
      }
      return i < j.size();
    }
    while (i < j.size() && j[i] != ',' && j[i] != '}' && j[i] != ' ') out += j[i++];
    return !out.empty();
  }
  return false;
}
double jnum(const std::string &j, const char *key, double def) { std::string v; return jget(j, key, v) ? strtod(v.c_str(), nullptr) : def; }

bool resolve(const std::string &peer, sockaddr_in &out)
{
  const size_t c = peer.rfind(':');
  if (c == std::string::npos || c == 0) return false;
  addrinfo hints{}, *res = nullptr;
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_DGRAM;
  if (getaddrinfo(peer.substr(0, c).c_str(), peer.substr(c + 1).c_str(), &hints, &res) != 0 || !res) return false;
  out = *(const sockaddr_in *)res->ai_addr;
  freeaddrinfo(res);
  return true;
}
bool same_addr(const sockaddr_in &a, const sockaddr_in &b) { return a.sin_addr.s_addr == b.sin_addr.s_addr && a.sin_port == b.sin_port; }

// The smallest of what's seen over the last one to two seconds (two windows), and the biggest (blocks).
struct Win {
  int64_t cur = INT64_MAX, prev = INT64_MAX;
  int n = 0, pn = 0;
  void add(int64_t v) { cur = std::min(cur, v); ++n; }
  void roll() { prev = cur; pn = n; cur = INT64_MAX; n = 0; }
  int64_t min() const { return std::min(cur, prev); }
};

struct Fm { uint64_t x1, f; }; // X frame + 1 (0: nothing written there this lap), and the requester frame it holds

struct Sess {
  bool serve = false;
  uint32_t token = 0;
  std::string key;
  double win_at = 0;
  unsigned char pkt[MAXD + 16];
  bool pace = false, waiting = false; // (pace: another hop goes to the same computer; waiting: frames left for the next poll)
  double pace_at = 0, credit = 0;
  // ---- sending end
  int hop = 0;
  hop_map m = {};
  std::string peer;
  sockaddr_in addr{};
  bool resolved = false, active = false;
  double next_resolve = 0, next_ping = 0, last_pong = -1e9;
  uint64_t r = 0, rw = 0, last_w = 0, last_b = 0;
  int fade = 0;
  std::vector<uint64_t> rcv; // rcv[f & mask] == f: frame f came back
  Win blk, slack;             // block size seen (as -frames, so min() is the biggest); slack of each return, frames
  double rtt_ms = -1;
  uint32_t r_flags = 0, r_frames = 0, r_srate = 0, r_slips = 0;
  uint64_t r_received = 0, r_dropped = 0;
  uint64_t sent = 0, returned = 0, lost = 0, late = 0, holes = 0; // holes: runs of lost frames, each a dropout heard (Health shows them)
  uint64_t mr = 0, mbase = 0, msent = 0;  // MIDI: send_midi read so far, the first this session sent, events sent
  bool mset = false, mresend = false;
  double mresend_at = 0;
  int64_t slack_last = 0;
  // ---- serving end
  int xid = 0, yid = 0;
  hop_map mx = {}, my = {};
  uint32_t pdc = 0;
  double margin_ms = 20;
  bool have_peer = false, anchored = false, yr_set = false, srate_ok = true;
  sockaddr_in from{};
  double last_rx = -1e9, x_alive = -1e9, y_alive = -1e9, started = 0;
  uint64_t xb = 0, yb = 0, last_xw = 0, last_xb = 0, zeroed_to = 0, yr = 0;
  int64_t A = 0, tight_min = INT64_MAX;
  double tight_at = 0; // after a slip: when to look at how far ahead the packets since then landed (tight_min), and tighten back
  double late_since = 0, late_last = 0; // the first and last late packet of a run of them (0: none): only lateness that lasts is drift
  Win delta, xblk, sslack;
  std::vector<Fm> fmap;
  uint64_t s_received = 0, s_returned = 0, s_dropped = 0, s_slips = 0;
  uint64_t mseen[256] = {}, mtop = 0, s_midi = 0; // MIDI numbers taken (+1, by number & 255), the highest, events put in X's ret_midi
};
} // namespace

struct HopNet {
  hopnet_send_fn send = nullptr;
  void *user = nullptr;
  unsigned long pid = 0;
  std::mutex mx;
  std::vector<std::unique_ptr<Sess>> ss;
  std::vector<hop_map> names; // every mapping opened: POSIX names are taken away at the end only (the plug-in keeps its mapping open)
  std::thread thr;
  std::atomic<bool> run{ false };
};

namespace {
Sess *find_send(HopNet *h, int hop) { for (auto &s : h->ss) if (!s->serve && s->hop == hop) return s.get(); return nullptr; }
Sess *find_token(HopNet *h, uint32_t t, bool serve) { for (auto &s : h->ss) if (s->serve == serve && s->token == t) return s.get(); return nullptr; }

// A datagram: header + payload, tagged and sent.
void out(HopNet *h, Sess &s, int type, uint32_t frames, uint64_t frame, const void *payload, int plen, const sockaddr_in &to)
{
  if (s.key.empty()) return;
  unsigned char *p = s.pkt;
  memcpy(p, MAGIC, 4);
  p[4] = (unsigned char)type; p[5] = 1;
  const uint16_t nf = (uint16_t)frames;
  memcpy(p + 6, &nf, 2);
  put32(p + 8, s.token);
  put64(p + 12, frame);
  if (plen > 0) memcpy(p + HDR, payload, (size_t)plen);
  unsigned char t[32];
  direct_hmac_sha256((const unsigned char *)s.key.data(), s.key.size(), p, (size_t)HDR + plen, t);
  memcpy(p + HDR + plen, t, TAG);
  h->send(h->user, p, HDR + plen + TAG, &to, (int)sizeof(to));
}

int64_t frames_of(double ms, double srate) { return (int64_t)(ms * (srate > 0 ? srate : 48000) / 1000.0); }

// The host's block size, from how far send_w moved over how many blocks it took (James, rt). Not the biggest jump between two polls:
// after a stall (the macOS runner pauses its VM for ~60 ms; a disk or the scheduler can do it on a real computer) the plug-in catches
// up in a burst of blocks, and taken as one huge block that burst ate the budget for the next two windows: the sender zeroed returns
// that were still in time, and the remote anchored a stall's length further ahead. blocks is read on both sides of send_w: when it
// didn't change, send_w is at most the block in progress ahead of it, so a reading is off by one block at most.
void block_seen(Win &win, uint64_t &last_w, uint64_t &last_b, hop_shm *p)
{
  const uint64_t b = hop_load(&p->blocks), w = hop_load(&p->send_w);
  if (hop_load(&p->blocks) != b || b == last_b) return;
  if (last_b && b > last_b && w > last_w) win.add(-(int64_t)std::min<uint64_t>((w - last_w + (b - last_b) - 1) / (b - last_b), 8192));
  last_w = w; last_b = b;
}

// ---- the sending end (the computer whose track has the Hop) ---------------------------------------------------------------------------
int64_t biggest(const Win &w) { const int64_t m = w.min(); return m == INT64_MAX ? 0 : -m; } // (blocks are kept negated: min() is the biggest)
uint64_t guard_of(Sess &s) { return (uint64_t)std::max<int64_t>(biggest(s.blk), 128) + 48; } // (a block, and our 1 ms)

// How many of the `have` frames waiting may go now (see PACE): all of them unpaced; paced, whole packets as the credit allows (it builds
// only while frames wait, so a quiet spell between blocks banks nothing but the first packet), and anything more than `block` behind.
uint64_t paced(Sess &s, double now, double srate, uint64_t have, uint64_t block)
{
  const double dt = std::max(0.0, std::min(0.1, now - s.pace_at));
  s.pace_at = now;
  if (!s.pace) { s.waiting = false; return have; }
  s.credit = s.waiting ? s.credit + dt * (srate > 0 ? srate : 48000) * PACE : PKT;
  uint64_t go = have > block ? have - block : 0;
  while (go < have) {
    const uint64_t n = std::min<uint64_t>(PKT, have - go);
    if (s.credit < (double)n) break;
    s.credit -= (double)n;
    go += n;
  }
  s.waiting = go < have;
  return go;
}
// What pacing adds to a hop's round trip at most, in frames: its last packet's wait.
uint64_t pace_cost(const Sess &s, int64_t block) { return s.pace && block > PKT ? (uint64_t)((block - PKT) / PACE) : 0; }

void midi_send(HopNet *h, Sess &s, hop_shm *p, uint64_t w, double now);

void send_step(HopNet *h, Sess &s, double now)
{
  hop_shm *p = s.m.p;
  if (!hop_shm_ok(p) || !s.resolved) return;
  block_seen(s.blk, s.last_w, s.last_b, p);
  const uint64_t w = hop_load(&p->send_w);
  if (now >= s.next_ping) { // (the round trip, and the remote's state back in the pong)
    s.next_ping = now + 0.2;
    unsigned char pl[8];
    put32(pl, (uint32_t)p->srate); put32(pl + 4, (uint32_t)hop_load(&p->latency));
    out(h, s, T_PING, 0, now_us(), pl, 8, s.addr);
  }
  const bool serving = now - s.last_pong < 2 && (s.r_flags & (F_ALIVE | F_DELTA | F_SRATE)) == (F_ALIVE | F_DELTA | F_SRATE);
  if (!serving) { s.active = false; return; } // (nothing streams into a remote that isn't ready; the plug-in plays its late fallback)
  if (!s.active) { // From here on: frames from w on go out. Anything before w never will, so it's zeroed and published at once.
    uint64_t rw = hop_load(&p->ret_w);
    if (rw > w || w - rw > HALF) rw = w - std::min<uint64_t>(w, HALF);
    const float dk = hop_load(&p->dry_lost) ? 1.f : 0.f;
    for (uint64_t i = rw; i < w; ++i) { size_t q = (size_t)(i & HOP_MASK) * HOP_CH; p->ret[q] = p->send[q] * dk; p->ret[q + 1] = p->send[q + 1] * dk; }
    s.r = s.rw = w;
    hop_store(&p->ret_w, w);
    s.active = true;
  }
  if (s.r > w || w - s.r > HALF) s.r = w; // (the plug-in started again, or we fell far behind: from now)
  float buf[PKT * HOP_CH];
  const uint64_t upto = s.r + paced(s, now, p->srate, w - s.r, (uint64_t)std::max<int64_t>(biggest(s.blk), PKT));
  while (s.r < upto) {
    const uint32_t n = (uint32_t)std::min<uint64_t>(PKT, upto - s.r);
    hop_copy_out(p->send, s.r, n, buf);
    out(h, s, T_AUDIO, n, s.r, buf, (int)(n * HOP_CH * sizeof(float)), s.addr);
    s.r += n;
    s.sent += n;
  }
  midi_send(h, s, p, s.r, now); // (a MIDI event goes once its frame has: paced, a frame waiting here hasn't gone yet)
  // Publish what came back, in order; a frame the plug-in will need in its next block that isn't back is filled in (lost): the dry input
  // when the plug-in says so, else silence; the frames after it fade from that back to the return.
  const uint64_t L = hop_load(&p->latency), g = guard_of(s);
  const uint64_t dl = w + g > L ? w + g - L : 0;
  const float dk = hop_load(&p->dry_lost) ? 1.f : 0.f;
  uint64_t rw = s.rw;
  while (rw < s.r && (s.rcv[rw & HOP_MASK] == rw || rw < dl)) {
    float *f = p->ret + (size_t)(rw & HOP_MASK) * HOP_CH;
    const float *d = p->send + (size_t)(rw & HOP_MASK) * HOP_CH;
    if (s.rcv[rw & HOP_MASK] == rw) {
      if (s.fade > 0) {
        const float k = (float)(FADE - s.fade + 1) / (FADE + 1);
        f[0] = f[0] * k + d[0] * dk * (1 - k); f[1] = f[1] * k + d[1] * dk * (1 - k);
        --s.fade;
      }
    } else { f[0] = d[0] * dk; f[1] = d[1] * dk; ++s.lost; s.holes += s.fade != FADE; s.fade = FADE; }
    ++rw;
  }
  if (rw != s.rw) { s.rw = rw; hop_store(&p->ret_w, rw); }
}

// The plug-in's MIDI events [lo, hi) of send_midi, MPKT a packet, under their own numbers (the header's frame).
void midi_out(HopNet *h, Sess &s, hop_shm *p, uint64_t lo, uint64_t hi)
{
  unsigned char pl[MPKT * MEV];
  while (lo < hi) {
    const uint32_t n = (uint32_t)std::min<uint64_t>(MPKT, hi - lo);
    for (uint32_t k = 0; k < n; ++k) {
      const hop_midi m = p->send_midi[(lo + k) & MM];
      put64(pl + k * MEV, m.frame); put32(pl + k * MEV + 8, m.msg); put32(pl + k * MEV + 12, m.len);
    }
    out(h, s, T_MIDI, n, lo, pl, (int)(n * MEV), s.addr);
    s.msent += n;
    lo += n;
  }
}
// Events whose frames have gone out: new ones with up to MPKT - 1 before them (sent already: a lost packet's events come again in the
// next one), and the last window once more 20 ms on (a lone note-off in a lost packet).
void midi_send(HopNet *h, Sess &s, hop_shm *p, uint64_t w, double now)
{
  const uint64_t mw = hop_load(&p->send_mw);
  if (!s.mset || s.mr > mw || mw - s.mr > HOP_MIDI) { s.mr = s.mbase = mw; s.mset = true; } // (from now: the plug-in started again, or we fell a ring behind)
  const uint64_t base = std::max(s.mbase, mw > HOP_MIDI ? mw - HOP_MIDI : 0);
  uint64_t hi = s.mr;
  while (hi < mw && p->send_midi[hi & MM].frame < w) ++hi;
  if (hi > s.mr) {
    const uint64_t back = std::min<uint64_t>(s.mr - base, hi - s.mr < (uint64_t)MPKT ? MPKT - (hi - s.mr) : 0);
    midi_out(h, s, p, s.mr - back, hi);
    s.mr = hi;
    s.mresend = true; s.mresend_at = now + 0.02;
  } else if (s.mresend && now >= s.mresend_at) {
    s.mresend = false;
    midi_out(h, s, p, hi - std::min<uint64_t>(hi - base, MPKT), hi);
  }
}

void send_rx(HopNet *h, Sess &s, int type, uint32_t nf, uint64_t frame, const unsigned char *pl, int plen)
{
  (void)h;
  hop_shm *p = s.m.p;
  if (!hop_shm_ok(p)) return;
  if (type == T_PONG && plen >= 32) {
    const uint64_t t = frame, now = now_us();
    if (now >= t) s.rtt_ms = (double)(now - t) / 1000.0;
    s.r_srate = get32(pl); s.r_flags = get32(pl + 4); s.r_frames = get32(pl + 8); s.r_slips = get32(pl + 12);
    s.r_received = get64(pl + 16); s.r_dropped = get64(pl + 24);
    s.last_pong = now_s();
    return;
  }
  if (type != T_RET || !s.active || nf == 0 || nf > PKT || plen < (int)(nf * HOP_CH * sizeof(float))) return;
  if (frame + nf > s.r || frame >= s.rw + HALF) return; // (never sent, or nonsense)
  const uint64_t L = hop_load(&p->latency), w = hop_load(&p->send_w);
  const int64_t slack = (int64_t)(frame + L) - (int64_t)(w + guard_of(s)); // (frames to spare before the plug-in needs it)
  s.slack.add(slack);
  s.slack_last = slack;
  for (uint32_t k = 0; k < nf; ++k) {
    const uint64_t f = frame + k;
    if (f < s.rw) { ++s.late; continue; } // (already zeroed and published: too late)
    float v[2];
    memcpy(v, pl + (size_t)k * HOP_CH * sizeof(float), sizeof(v));
    float *d = p->ret + (size_t)(f & HOP_MASK) * HOP_CH;
    d[0] = v[0]; d[1] = v[1];
    s.rcv[f & HOP_MASK] = f;
    ++s.returned;
  }
}

// ---- the serving end (the bandmate with the plug-in) ----------------------------------------------------------------------------------
uint64_t s_guard(Sess &s) { return (uint64_t)std::max<int64_t>(biggest(s.xblk), 128) + 64; }
bool s_delta_ok(Sess &s) { return s.delta.pn >= 50 || s.delta.n >= 50; }
int64_t s_delta(Sess &s) { return s.delta.pn >= 50 ? s.delta.min() : s.delta.cur; }
bool s_alive(Sess &s, double now) { return now - s.x_alive < 0.5 && now - s.y_alive < 0.5; }
uint32_t s_flags(Sess &s, double now) { return (s_alive(s, now) ? F_ALIVE : 0) | (s_delta_ok(s) ? F_DELTA : 0) | (s.srate_ok ? F_SRATE : 0); }

// Packets landing further ahead of X than margin_ms plus a tolerance (half the margin, at least 10 ms, so jitter isn't taken for drift)
// are brought back to margin_ms: A moves back, the frames that skips are lost (counted at the sender), none is ever mislabelled (fmap).
void tighten(Sess &s, int64_t low)
{
  const double xs = s.mx.p && hop_shm_ok(s.mx.p) && s.mx.p->srate > 0 ? s.mx.p->srate : 48000;
  const int64_t S = frames_of(s.margin_ms, xs), tol = std::max<int64_t>(S / 2, frames_of(10, xs));
  if (!s.anchored || low == INT64_MAX || low <= S + tol) return;
  s.A -= low - S;
  ++s.s_slips;
  s.sslack = Win();
}

void serve_step(HopNet *h, Sess &s, double now)
{
  hop_shm *X = s.mx.p, *Y = s.my.p;
  if (!hop_shm_ok(X) || !hop_shm_ok(Y)) return;
  const uint64_t yw = hop_load(&Y->send_w), xw = hop_load(&X->send_w); // (Y first: see delta at the top)
  const uint64_t xb = hop_load(&X->blocks), yb = hop_load(&Y->blocks);
  if (xb != s.xb) { s.xb = xb; s.x_alive = now; }
  if (yb != s.yb) { s.yb = yb; s.y_alive = now; }
  if (!s_alive(s, now)) { s.delta = Win(); s.yr_set = false; return; } // (the hidden track isn't running: nothing lines up until it does)
  s.delta.add((int64_t)(xw - yw));
  block_seen(s.xblk, s.last_xw, s.last_xb, X);
  if (s.tight_at && now >= s.tight_at) { tighten(s, s.tight_min); s.tight_at = 0; }
  // X's ret ring: half a ring ahead of where X plays is zeroed (last lap's audio gone) and published; we write anywhere in it.
  const uint64_t hi = xw + HALF;
  if (s.zeroed_to < xw) s.zeroed_to = xw;
  for (uint64_t i = s.zeroed_to; i < hi; ++i) { size_t q = (size_t)(i & HOP_MASK) * HOP_CH; X->ret[q] = X->ret[q + 1] = 0.f; }
  s.zeroed_to = hi;
  hop_store(&X->ret_w, hi);
  // Y's new frames go back under the requester's frame numbers, in runs of consecutive ones.
  if (!s_delta_ok(s) || !s.have_peer) { s.yr = yw; s.yr_set = true; return; }
  if (!s.yr_set || s.yr > yw || yw - s.yr > HALF) { s.yr = yw; s.yr_set = true; }
  const int64_t shift = s_delta(s) - (int64_t)s.pdc - (int64_t)hop_load(&X->latency);
  float buf[PKT * HOP_CH];
  const uint64_t yend = s.yr + paced(s, now, X->srate, yw - s.yr, (uint64_t)std::max<int64_t>(biggest(s.xblk), PKT));
  uint64_t y0 = 0, f0 = 0;
  uint32_t n = 0;
  auto flush = [&]() {
    if (!n) return;
    hop_copy_out(Y->send, y0, n, buf);
    out(h, s, T_RET, n, f0, buf, (int)(n * HOP_CH * sizeof(float)), s.from);
    s.s_returned += n;
    n = 0;
  };
  for (uint64_t y = s.yr; y < yend; ++y) {
    const int64_t x = (int64_t)y + shift;
    const Fm e = x >= 0 ? s.fmap[(size_t)((uint64_t)x & HOP_MASK)] : Fm{ 0, 0 };
    if (x < 0 || e.x1 != (uint64_t)x + 1) { flush(); continue; }
    if (n && (e.f != f0 + n || n == PKT)) flush();
    if (!n) { y0 = y; f0 = e.f; }
    ++n;
  }
  flush();
  s.yr = yend;
}

// MIDI events numbered seq0.. into X's ret_midi at X frame f + A, each number once (the sender repeats them); none before the audio has
// anchored A (nothing to line them up with yet). One X has already played past plays at once there (X plays a late one at its block's start).
void serve_midi(Sess &s, uint32_t nf, uint64_t seq0, const unsigned char *pl, int plen)
{
  hop_shm *X = s.mx.p;
  if (!s.anchored || nf == 0 || nf > (uint32_t)MPKT || plen < (int)(nf * MEV)) return;
  uint64_t mw = hop_load(&X->ret_mw);
  for (uint32_t k = 0; k < nf; ++k) {
    const uint64_t seq = seq0 + k;
    if (s.mseen[seq & 255] == seq + 1 || seq + 256 <= s.mtop) continue; // (had it, or too old to tell)
    s.mseen[seq & 255] = seq + 1;
    s.mtop = std::max(s.mtop, seq);
    const int64_t x = (int64_t)get64(pl + k * MEV) + s.A;
    const uint32_t len = get32(pl + k * MEV + 12);
    if (x < 0 || len < 1 || len > 3) continue;
    hop_midi &m = X->ret_midi[mw & MM];
    m.frame = (uint64_t)x; m.msg = get32(pl + k * MEV + 8) & 0xFFFFFFu; m.len = len;
    ++mw;
    ++s.s_midi;
  }
  hop_store(&X->ret_mw, mw);
}

void serve_rx(HopNet *h, Sess &s, int type, uint32_t nf, uint64_t frame, const unsigned char *pl, int plen, const sockaddr_in &from)
{
  const double now = now_s();
  hop_shm *X = s.mx.p;
  if (!hop_shm_ok(X)) return;
  if (s.have_peer && !same_addr(from, s.from) && now - s.last_rx < 5) return; // (the hop's requester, pinned at its first packet)
  s.from = from;
  s.have_peer = true;
  s.last_rx = now;
  if (type == T_PING && plen >= 8) {
    const uint32_t sr = get32(pl);
    s.srate_ok = sr == 0 || X->srate <= 0 || (uint32_t)(X->srate + 0.5) == sr; // (no resampling: both computers must run one rate)
    const double xs = X->srate > 0 ? X->srate : 48000;
    unsigned char o[32];
    // what this end adds: the jitter buffer, a block each for X and Y, X's own latency, the plug-ins', and our polling
    const uint64_t remote = (uint64_t)frames_of(s.margin_ms, xs) + 2 * s_guard(s) + hop_load(&X->latency) + s.pdc + pace_cost(s, biggest(s.xblk));
    put32(o, (uint32_t)xs); put32(o + 4, s_flags(s, now)); put32(o + 8, (uint32_t)remote); put32(o + 12, (uint32_t)s.s_slips);
    put64(o + 16, s.s_received); put64(o + 24, s.s_dropped);
    out(h, s, T_PONG, 0, frame, o, 32, s.from);
    return;
  }
  if (type == T_MIDI) { serve_midi(s, nf, frame, pl, plen); return; }
  if (type != T_AUDIO || nf == 0 || nf > PKT || plen < (int)(nf * HOP_CH * sizeof(float))) return;
  if ((s_flags(s, now) & (F_ALIVE | F_DELTA | F_SRATE)) != (F_ALIVE | F_DELTA | F_SRATE)) { s.s_dropped += nf; return; }
  const uint64_t xw = hop_load(&X->send_w), Lx = hop_load(&X->latency), g = s_guard(s);
  const int64_t S = frames_of(s.margin_ms, X->srate), x_min = (int64_t)(xw + g) - (int64_t)Lx; // (earliest X frame X hasn't started reading)
  int64_t x = (int64_t)frame + s.A;
  // A packet X has already played past is late: dropped (the sender counts its frames lost). Only when late ones keep coming (LATE_HOLD,
  // never LATE_GAP apart; some in time between them is the jitter at the edge) is it this computer's clock running faster, and A moves. A spike on the way here (a queue that stalls, then lets
  // its packets go at once: the desktop <-> laptop link over the internet, 2026-11-19, 40 ms now and then) made a slip each time, and
  // everything after it then came that much later for the 0.15 s until it tightened back: past the budget, so a 40 ms spike cost 150 ms.
  const bool late = s.anchored && x < (int64_t)xw - (int64_t)Lx + 64, jump = !s.anchored || x + nf > (int64_t)s.zeroed_to;
  if (late && !jump) {
    if (!s.late_since || now - s.late_last > LATE_GAP) s.late_since = now;
    s.late_last = now;
    if (now - s.late_since < LATE_HOLD) { s.s_dropped += nf; return; }
  }
  // First packet, a late one that lasted, or a jump (the sender started again): put it margin_ms ahead of where X reads. One inside the
  // guard but not yet read is written as it is (it may well be in time).
  if (late || jump) {
    s.late_since = 0;
    // A packet late after a stall (ours, or the sender's catching up in a burst) moves A by the stall, not by drift: the packets after
    // it land that much further ahead for good. So a slip is looked at again 0.15 s on (the burst over, from 0.05 s): if every packet since
    // landed well ahead of the margin, A tightens back, and a hiccup costs a moment of fallback audio, not the rest of the session.
    // (A clock that runs fast keeps landing at the margin after its slip, so it isn't tightened.) (James, rt)
    if (s.anchored) { ++s.s_slips; s.tight_at = now + 0.15; s.tight_min = INT64_MAX; }
    s.sslack = Win(); // (what landed under the old A says nothing about the new one)
    s.A = x_min + S - (int64_t)frame;
    s.anchored = true;
    x = (int64_t)frame + s.A;
    if (x + nf > (int64_t)s.zeroed_to) { s.s_dropped += nf; return; } // (X's ring isn't cleared that far yet: the step does it next)
  }
  s.sslack.add(x - x_min);
  // A packet landing well past the margin: the sender may have jumped ahead. REAPER does at the start of playback, processing the hop's
  // whole latency at once to line up its delay compensation (8192 frames in REAPER, 2026-11-19), and every packet after it then landed that
  // much ahead and came back that much late: 3 s of silence until the once-a-second tighten (two windows) saw it. So look 50 ms on: if
  // every packet since then landed past it too, tighten then (ordinary jitter leaves some at the margin, and nothing moves).
  const double xs = X->srate > 0 ? X->srate : 48000;
  if (!s.tight_at && x - x_min > S + std::max<int64_t>(S / 2, frames_of(10, xs))) { s.tight_at = now + 0.05; s.tight_min = INT64_MAX; }
  if (s.tight_at && now >= s.tight_at - 0.1) s.tight_min = std::min<int64_t>(s.tight_min, x - x_min);
  for (uint32_t k = 0; k < nf; ++k) {
    const uint64_t xi = (uint64_t)x + k;
    memcpy(X->ret + (size_t)(xi & HOP_MASK) * HOP_CH, pl + (size_t)k * HOP_CH * sizeof(float), HOP_CH * sizeof(float));
    s.fmap[(size_t)(xi & HOP_MASK)] = Fm{ xi + 1, frame + k };
  }
  s.s_received += nf;
  // X publishes send_w before it reads its ret ring, so any frame X's newest block may have read before we wrote it is behind
  // send_w - Lx now: those played as silence there, so they aren't returned as if they'd played (the sender counts them lost).
  const uint64_t xw2 = hop_load(&X->send_w);
  for (uint32_t k = 0; k < nf; ++k)
    if ((uint64_t)x + k + Lx < xw2) { s.fmap[(size_t)(((uint64_t)x + k) & HOP_MASK)] = Fm{ 0, 0 }; ++s.s_dropped; }
}

// Once a second: the windows roll, and a remote whose clock runs slower than the sender's (packets ever earlier) is brought back to
// margin_ms (the frames it skips are lost, counted at the sender). One faster runs late and is moved by serve_rx.
void roll(Sess &s, double now)
{
  if (now - s.win_at < 1) return;
  s.win_at = now;
  if (s.serve) {
    // (two windows, so a burst of early packets on a jittery link doesn't count as drift)
    if (s.sslack.n > 0 && s.sslack.pn > 0) tighten(s, s.sslack.min());
    s.sslack.roll();
    if (s.delta.n >= 50) s.delta.roll(); // (a hidden track that stopped keeps its last good window until it runs again)
    s.xblk.roll();
  } else {
    s.blk.roll();
    s.slack.roll();
  }
}

void loop(HopNet *h)
{
  while (h->run.load()) {
    // names resolve outside the lock (a lookup can take a while)
    std::vector<std::pair<int, std::string>> want;
    {
      std::lock_guard<std::mutex> g(h->mx);
      if (h->ss.empty()) { h->run = false; return; } // (no hop left: the thread ends, the next connect or serve starts another)
      const double now = now_s();
      for (auto &s : h->ss)
        if (!s->serve && !s->resolved && now >= s->next_resolve) { s->next_resolve = now + 5; want.push_back({ s->hop, s->peer }); }
    }
    for (auto &w : want) {
      sockaddr_in a{};
      if (!resolve(w.second, a)) continue;
      std::lock_guard<std::mutex> g(h->mx);
      Sess *s = find_send(h, w.first);
      if (s && s->peer == w.second) { s->addr = a; s->resolved = true; }
    }
    {
      std::lock_guard<std::mutex> g(h->mx);
      const double now = now_s();
      for (auto &s : h->ss) { // (paced while another hop streams to or from the same computer: see PACE)
        int n = 0;
        for (auto &o : h->ss)
          n += o->serve == s->serve && (s->serve ? o->have_peer && now - o->last_rx < 1 && same_addr(o->from, s->from)
                                                 : o->resolved && o->active && same_addr(o->addr, s->addr));
        s->pace = n > 1;
      }
      for (auto &s : h->ss) {
        if (s->serve) serve_step(h, *s, now); else send_step(h, *s, now);
        roll(*s, now);
      }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1)); // (a packet is 2.7 ms at 48 kHz: well inside)
  }
}

void start_thread(HopNet *h) // (h->mx held)
{
  if (h->run.exchange(true)) return;
  if (h->thr.joinable()) h->thr.join(); // (one that ended by itself holds no lock on its way out)
  h->thr = std::thread(loop, h);
}

void close_send(Sess &s)
{
  if (hop_shm_ok(s.m.p)) s.m.p->ext_mode = HOP_EXT_NONE;
  hop_shm_close(&s.m);
}
void close_serve(Sess &s)
{
  for (hop_map *m : { &s.mx, &s.my }) {
    if (hop_shm_ok(m->p)) m->p->ext_mode = HOP_EXT_NONE;
    hop_shm_close(m);
  }
}
void drop(HopNet *h, Sess *s)
{
  if (s->serve) close_serve(*s); else close_send(*s);
  h->ss.erase(std::find_if(h->ss.begin(), h->ss.end(), [&](const std::unique_ptr<Sess> &p) { return p.get() == s; }));
}
void json_str(std::string &o, const std::string &v)
{
  o += '"';
  for (unsigned char c : v) {
    if (c == '"' || c == '\\') { o += '\\'; o += (char)c; }
    else if (c >= 0x20) o += (char)c;
  }
  o += '"';
}
} // namespace

HopNet *hopnet_new(hopnet_send_fn send, void *user, unsigned long pid)
{
#ifdef _WIN32
  WSADATA w;
  WSAStartup(MAKEWORD(2, 2), &w); // (getaddrinfo needs it even before live audio has started; counted, so harmless twice)
#endif
  HopNet *h = new HopNet();
  h->send = send; h->user = user; h->pid = pid;
  return h;
}

void hopnet_free(HopNet *h)
{
  if (!h) return;
  h->run = false;
  if (h->thr.joinable()) h->thr.join();
  {
    std::lock_guard<std::mutex> g(h->mx);
    while (!h->ss.empty()) drop(h, h->ss.back().get());
    for (const hop_map &m : h->names) hop_shm_unlink(&m);
  }
  delete h; // (nothing else may hold h now: atexit, or the test's end)
}

int hopnet_connect(HopNet *h, int hop_id, const char *peer, const char *json)
{
  if (!h || hop_id < 1 || hop_id > 64 || !json) return 0;
  const std::string j = json;
  std::string stop, secret;
  std::lock_guard<std::mutex> g(h->mx);
  Sess *s = find_send(h, hop_id);
  if (jget(j, "stop", stop) && stop == "true") { if (s) drop(h, s); return 1; }
  const uint32_t token = (uint32_t)jnum(j, "token", 0);
  jget(j, "secret", secret);
  if (!peer || !*peer || !token || secret.empty()) return 0;
  if (s && (s->peer != peer || s->token != token || s->key != key_of(secret))) { drop(h, s); s = nullptr; } // (another hop now: afresh)
  if (!s) {
    std::unique_ptr<Sess> n(new Sess());
    n->hop = hop_id; n->peer = peer; n->token = token; n->key = key_of(secret);
    if (!hop_shm_open(&n->m, h->pid, hop_id)) return 0;
    h->names.push_back(n->m);
    n->rcv.assign(HOP_FRAMES, ~0ull);
    n->win_at = now_s();
    s = n.get();
    h->ss.push_back(std::move(n));
  }
  if (hop_shm_ok(s->m.p)) s->m.p->ext_mode = HOP_EXT_NETWORK;
  start_thread(h);
  return 1;
}

int hopnet_serve(HopNet *h, const char *json)
{
  if (!h || !json) return 0;
  const std::string j = json;
  std::string stop, secret;
  const uint32_t token = (uint32_t)jnum(j, "token", 0);
  if (!token) return 0;
  std::lock_guard<std::mutex> g(h->mx);
  Sess *s = find_token(h, token, true);
  if (jget(j, "stop", stop) && stop == "true") { if (s) drop(h, s); return 1; }
  const int x = (int)jnum(j, "x", 0), y = (int)jnum(j, "y", 0);
  jget(j, "secret", secret);
  if (x < 1 || x > 64 || y < 1 || y > 64 || x == y || secret.empty()) return 0;
  if (s && (s->xid != x || s->yid != y)) { drop(h, s); s = nullptr; }
  if (!s) {
    std::unique_ptr<Sess> n(new Sess());
    n->serve = true; n->token = token; n->xid = x; n->yid = y;
    if (!hop_shm_open(&n->mx, h->pid, x)) return 0;
    if (!hop_shm_open(&n->my, h->pid, y)) { hop_shm_close(&n->mx); return 0; }
    h->names.push_back(n->mx); h->names.push_back(n->my);
    n->fmap.assign(HOP_FRAMES, Fm{ 0, 0 });
    n->win_at = n->started = now_s();
    s = n.get();
    h->ss.push_back(std::move(n));
  }
  s->key = key_of(secret);
  s->pdc = (uint32_t)std::max(0.0, std::min(1e6, jnum(j, "pdc", 0)));
  s->margin_ms = std::max(2.0, std::min(500.0, jnum(j, "margin_ms", 20)));
  for (hop_map *m : { &s->mx, &s->my }) if (hop_shm_ok(m->p)) m->p->ext_mode = HOP_EXT_NETWORK;
  start_thread(h);
  return 1;
}

void hopnet_rx(void *hv, const unsigned char *d, int n, const void *fromv, int fromlen)
{
  HopNet *h = (HopNet *)hv;
  if (!h || n < HDR + TAG || n > MAXD || memcmp(d, MAGIC, 4) != 0 || d[5] != 1 || fromlen < (int)sizeof(sockaddr_in)) return;
  const sockaddr_in &from = *(const sockaddr_in *)fromv;
  const int type = d[4];
  uint16_t nf;
  memcpy(&nf, d + 6, 2);
  const uint32_t token = get32(d + 8);
  const uint64_t frame = get64(d + 12);
  std::lock_guard<std::mutex> g(h->mx);
  Sess *s = find_token(h, token, type == T_AUDIO || type == T_PING || type == T_MIDI);
  if (!s || s->key.empty() || !tag_ok(s->key, d, n)) return; // (not a hop of ours, or not tagged with this studio's secret)
  if (s->serve) serve_rx(h, *s, type, nf, frame, d + HDR, n - HDR - TAG, from);
  else if (s->resolved && same_addr(from, s->addr)) send_rx(h, *s, type, nf, frame, d + HDR, n - HDR - TAG);
}

std::string hopnet_status(HopNet *h, int hop_id)
{
  if (!h) return "";
  std::lock_guard<std::mutex> g(h->mx);
  const double now = now_s();
  char b[768];
  for (auto &sp : h->ss) {
    Sess &s = *sp;
    if (!s.serve && s.hop == hop_id) {
      hop_shm *p = s.m.p;
      const double sr = hop_shm_ok(p) && p->srate > 0 ? p->srate : 48000;
      const double budget = hop_shm_ok(p) ? hop_load(&p->latency) * 1000.0 / sr : 0;
      const double remote = s.r_frames * 1000.0 / (s.r_srate ? s.r_srate : sr);
      const int64_t sl = s.slack.min();
      // what the round trip needs: the network both ways, the remote's part, our block and 1 ms polls, a packet's wait each way
      const double need = s.rtt_ms >= 0 ? s.rtt_ms + remote + (guard_of(s) + 2 * PKT + pace_cost(s, biggest(s.blk))) * 1000.0 / sr : -1;
      std::string o = "{\"role\":\"send\",\"peer\":";
      json_str(o, s.peer);
      snprintf(b, sizeof(b),
               ",\"token\":%u,\"resolved\":%s,\"serving\":%s,\"active\":%s,\"rtt_ms\":%.1f,\"remote_ms\":%.1f,\"budget_ms\":%.1f,\"need_ms\":%.1f,"
               "\"slack_ms\":%.1f,\"sent\":%llu,\"returned\":%llu,\"lost\":%llu,\"late\":%llu,\"remote_alive\":%s,\"remote_lined_up\":%s,"
               "\"same_rate\":%s,\"remote_slips\":%u,\"remote_received\":%llu,\"remote_dropped\":%llu,\"holes\":%llu,\"midi_sent\":%llu,\"dry_lost\":%s,\"paced\":%s}",
               s.token, s.resolved ? "true" : "false", now - s.last_pong < 2 ? "true" : "false", s.active ? "true" : "false", s.rtt_ms, remote,
               budget, need, sl == INT64_MAX ? -1.0 : sl * 1000.0 / sr, (unsigned long long)s.sent, (unsigned long long)s.returned,
               (unsigned long long)s.lost, (unsigned long long)s.late, (s.r_flags & F_ALIVE) ? "true" : "false",
               (s.r_flags & F_DELTA) ? "true" : "false", (s.r_flags & F_SRATE) || !s.r_flags ? "true" : "false", s.r_slips,
               (unsigned long long)s.r_received, (unsigned long long)s.r_dropped, (unsigned long long)s.holes, (unsigned long long)s.msent,
               hop_shm_ok(p) && hop_load(&p->dry_lost) ? "true" : "false", s.pace ? "true" : "false");
      return o + b;
    }
    if (s.serve && s.xid == hop_id) {
      hop_shm *X = s.mx.p;
      const double sr = hop_shm_ok(X) && X->srate > 0 ? X->srate : 48000;
      const double remote = ((double)frames_of(s.margin_ms, sr) + 2.0 * s_guard(s) + (hop_shm_ok(X) ? hop_load(&X->latency) : 0) + s.pdc) * 1000.0 / sr;
      snprintf(b, sizeof(b),
               "{\"role\":\"serve\",\"token\":%u,\"x\":%d,\"y\":%d,\"alive\":%s,\"lined_up\":%s,\"same_rate\":%s,\"heard\":%s,\"idle_s\":%.1f,"
               "\"remote_ms\":%.1f,\"pdc\":%u,\"margin_ms\":%.1f,\"received\":%llu,\"returned\":%llu,\"dropped\":%llu,\"slips\":%llu,\"midi\":%llu,\"paced\":%s}",
               s.token, s.xid, s.yid, s_alive(s, now) ? "true" : "false", s_delta_ok(s) ? "true" : "false", s.srate_ok ? "true" : "false",
               s.have_peer ? "true" : "false", s.have_peer ? now - s.last_rx : now - s.started, remote, s.pdc, s.margin_ms,
               (unsigned long long)s.s_received, (unsigned long long)s.s_returned, (unsigned long long)s.s_dropped, (unsigned long long)s.s_slips,
               (unsigned long long)s.s_midi, s.pace ? "true" : "false");
      return b;
    }
  }
  return "";
}

// ---- REAPER ----------------------------------------------------------------------------------------------------------------------------
#ifndef HOPNET_STANDALONE
#include "reaper_plugin.h"
#ifdef min // (SWELL on macOS/Linux defines min/max as macros)
#undef min
#endif
#ifdef max
#undef max
#endif
#include "rtaudio.h"
int hop_loopback(int id, int delay);               // extension/hop.cpp
extern std::string (*hop_net_status)(int hop_id); // extension/hop.cpp: StudioSync_HopStatus adds ours as "net"
static HopNet *g_net = nullptr;                    // (made at load; freed at exit)
static int send_rt(void *, const void *d, int n, const void *a, int al) { return rt_send_raw(rt_global(), d, n, a, al); }
static std::string net_status(int id) { return hopnet_status(g_net, id); }
static int api_connect(int id, const char *peer, const char *json)
{
  if (!g_net) return 0;
  if (json && !strstr(json, "\"stop\"")) hop_loopback(id, -1); // (one writer for the ret ring: the test loopback steps aside)
  return hopnet_connect(g_net, id, peer, json);
}
static int api_serve(const char *json) { return g_net ? hopnet_serve(g_net, json) : 0; }
static void *va_connect(void **a, int n) { return n < 3 ? nullptr : (void *)(intptr_t)api_connect((int)(intptr_t)a[0], (const char *)a[1], (const char *)a[2]); }
static void *va_serve(void **a, int n) { return n < 1 ? nullptr : (void *)(intptr_t)api_serve((const char *)a[0]); }
static void hopnet_shutdown()
{
  rt_set_extra(rt_global(), nullptr, nullptr); // (live audio's receive thread hands nothing more to us)
  hopnet_free(g_net);
  g_net = nullptr;
}

extern "C" void hopnet_register(reaper_plugin_info_t *rec) // (C linkage: declared inside hop_register, an extern "C" function; after rtaudio_register made the link)
{
  if (!g_net) g_net = hopnet_new(send_rt, nullptr, hop_reaper_pid());
  rt_set_extra(rt_global(), hopnet_rx, g_net);
  hop_net_status = net_status;
  static const struct { const char *name; void *fn, *va; const char *def; } fns[] = {
    { "StudioSync_HopConnect", (void *)api_connect, (void *)va_connect,
      "int\0int,const char*,const char*\0hop_id,peer,json\0StudioSync Hop's network leg, the sending end: hop_id's audio goes to peer "
      "(\"name:port\", a bandmate on Tailscale) as raw float PCM on live audio's UDP socket (live audio must be running) and comes back "
      "into the hop under the same frame numbers. json: {\"secret\":\"<studio secret>\",\"token\":<the hop's number>}; {\"stop\":true} "
      "stops it. Returns 1, or 0." },
    { "StudioSync_HopServe", (void *)api_serve, (void *)va_serve,
      "int\0const char*\0json\0StudioSync Hop's network leg, the remote end: {\"secret\":..,\"token\":..,\"x\":<hidden track's first Hop "
      "id>,\"y\":<its last Hop id>,\"pdc\":<plug-in latency between them, samples>,\"margin_ms\":20} feeds the sender's audio into Hop x "
      "and returns Hop y's input under the sender's frame numbers. {\"token\":..,\"stop\":true} stops it. Returns 1, or 0." },
  };
  char key[96];
  for (const auto &f : fns) {
    snprintf(key, sizeof(key), "API_%s", f.name); rec->Register(key, f.fn);
    snprintf(key, sizeof(key), "APIdef_%s", f.name); rec->Register(key, (void *)f.def);
    snprintf(key, sizeof(key), "APIvararg_%s", f.name); rec->Register(key, f.va);
  }
  rec->Register("atexit", (void *)hopnet_shutdown);
}
#endif
