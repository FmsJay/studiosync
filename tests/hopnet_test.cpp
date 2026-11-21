// The Hop's network leg's own test (extension/hopnet.cpp, no REAPER): two endpoints on localhost with real UDP sockets between them,
// through a "wire" that adds delay, jitter and loss. The sender is a Hop plug-in's core (plugin/hop_core.h, latency 7200) fed a known
// signal; the remote is a fake hidden track: Hop X -> a plug-in that delays 100 samples (its PDC) and halves the level -> Hop Y, on an
// audio clock of its own that can run faster or slower. Every frame the sender plays must be exactly half its input from 7200 frames
// before, or silence (lost, or before the hop came up), or that fading in after a hole: never anything else, at any jitter, loss or drift.
//   Windows: tests\build_hopnet_test.cmd
//   macOS/Linux: c++ -std=c++17 -O2 -pthread -DHOPNET_STANDALONE -DDIRECT_STANDALONE tests/hopnet_test.cpp extension/hopnet.cpp \
//                extension/direct.cpp extension/direct_audio.cpp -o hopnet_test && ./hopnet_test
// GPL-3.0-or-later.
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <mmsystem.h>
#pragma comment(lib, "winmm.lib")
typedef SOCKET sock_t;
#define close_sock closesocket
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
typedef int sock_t;
#define close_sock close
#endif
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <vector>
#include "../plugin/hop_core.h"
#include "../extension/hopnet.h"

static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

// A stall of the harness itself, not of the hop: an audio thread's turn, or a packet the wire lets go, this much later than it should be.
// (15 ms: the remote absorbs a late packet within its 20 ms margin_ms less the wire's own jitter; past that a run is a stall scenario,
// whether or not one was asked for. GitHub's hosted macOS runner stalls threads 15-200 ms now and then, Linux's and Windows' ~1 ms)
static const double STALL_S = 0.015;
// SS_TIMING_STRICT=1: a check the harness never got a clean run for (it stalled in every try) fails; 0: it's reported and skipped.
// Default on, off when CI is set (the hosted runners; .github/workflows/extension.yml).
static bool strict() { const char *e = getenv("SS_TIMING_STRICT"); return e ? atoi(e) != 0 : !getenv("CI"); }
static float sig(uint64_t i) { return (float)((i * 7919u) % 100003u) / 100003.f + 0.001f; } // (never 0: silence and signal differ)
static double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }

// ---- the wire: each endpoint's socket, and what goes between them late, shuffled or not at all ----
struct Pkt { double due; std::vector<unsigned char> d; sockaddr_in to; };
struct Wire {
  std::mutex mx;
  std::vector<Pkt> q;
  std::mt19937 rng{ 12345 };
  double base_ms = 2, jitter_ms = 0, loss = 0;
  double spike_every = 0, spike_ms = 0; // a queue that stalls spike_ms every spike_every s, then lets the stalled packets go at once (a real link's jitter)
  long long dropped = 0;
  double late_at = 0, late_ms = 0; // (the wire's own lateness: when it last let a packet go STALL_S or more past its due, and the worst)
  int late_n = 0;                  // (and how many times, a new one 50 ms after the last)
  std::function<bool(const unsigned char *, int)> lose_midi; // (rt-hop2: a MIDI datagram (T_MIDI, type 5) this wire loses on purpose)
};
struct End {
  sock_t s;
  sockaddr_in me{};
  Wire *wire;
  HopNet *net = nullptr;
};
static int send_fn(void *user, const void *d, int n, const void *addr, int)
{
  End *e = (End *)user;
  Wire &w = *e->wire;
  std::lock_guard<std::mutex> g(w.mx);
  std::uniform_real_distribution<double> u(0, 1);
  if (w.lose_midi && n > 4 && ((const unsigned char *)d)[4] == 5 && w.lose_midi((const unsigned char *)d, n)) { w.dropped++; return n; }
  if (u(w.rng) < w.loss) { w.dropped++; return n; }
  Pkt p;
  const double t = now_s(), ph = w.spike_every > 0 ? std::fmod(t, w.spike_every) : 1e9;
  p.due = (ph < w.spike_ms / 1000.0 ? t - ph + w.spike_ms / 1000.0 : t) + (w.base_ms + w.jitter_ms * u(w.rng)) / 1000.0;
  p.d.assign((const unsigned char *)d, (const unsigned char *)d + n);
  p.to = *(const sockaddr_in *)addr;
  w.q.push_back(std::move(p));
  return n;
}

static std::atomic<bool> g_run{ false };
static void wire_loop(Wire *w, End *from)
{
  while (g_run.load()) {
    std::vector<Pkt> go;
    {
      std::lock_guard<std::mutex> g(w->mx);
      const double t = now_s();
      for (size_t i = 0; i < w->q.size();)
        if (w->q[i].due <= t) {
          if (t - w->q[i].due > STALL_S) { w->late_n += t - w->late_at > 0.05; w->late_at = t; w->late_ms = std::max(w->late_ms, (t - w->q[i].due) * 1000); }
          go.push_back(std::move(w->q[i])); w->q[i] = std::move(w->q.back()); w->q.pop_back();
        } else ++i;
    }
    for (Pkt &p : go) sendto(from->s, (const char *)p.d.data(), (int)p.d.size(), 0, (const sockaddr *)&p.to, sizeof(p.to));
    std::this_thread::sleep_for(std::chrono::microseconds(500));
  }
}
static void rx_loop(End *e)
{
  std::vector<unsigned char> buf(2048);
  while (g_run.load()) {
    sockaddr_in from{};
    socklen_t fl = sizeof(from);
    const int n = (int)recvfrom(e->s, (char *)buf.data(), (int)buf.size(), 0, (sockaddr *)&from, &fl);
    if (n > 0) hopnet_rx(e->net, buf.data(), n, &from, (int)sizeof(from));
  }
}
static sock_t udp(sockaddr_in &me)
{
  sock_t s = socket(AF_INET, SOCK_DGRAM, 0);
  me = sockaddr_in{};
  me.sin_family = AF_INET;
  inet_pton(AF_INET, "127.0.0.1", &me.sin_addr);
  bind(s, (const sockaddr *)&me, sizeof(me));
  socklen_t l = sizeof(me);
  getsockname(s, (sockaddr *)&me, &l);
#ifdef _WIN32
  DWORD tmo = 50;
#else
  timeval tmo = { 0, 50000 };
#endif
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&tmo, sizeof(tmo));
  int big = 1 << 20;
  setsockopt(s, SOL_SOCKET, SO_RCVBUF, (const char *)&big, sizeof(big));
  return s;
}

// ---- one run: a sender hop and a fake remote, for `secs`, then every frame the sender played is checked ----
// hiccup: when the last stall ended, seconds into the run (0: none), deliberate or not (an audio thread's turn or the wire STALL_S late:
// the macOS runner pauses its VM ~60 ms now and then); after / exact_after: the frames from a second after it on, and how many came back exact.
// dry: frames that played the sender's own input (a lost frame with "Dry when late" on, rt-hopvst); events / ev_exact: MIDI notes sent, and
// how many came back as the fake instrument's click exactly on their frame (those after the hop came up); ev_holed: notes whose frame's
// audio itself didn't come back (silence, or fading in after a hole), so no click could be heard there whatever the MIDI did.
struct Result { uint64_t exact = 0, zero = 0, faded = 0, wrong = 0, dry = 0, first_wet = 0, frames = 0, after = 0, exact_after = 0, events = 0, ev_exact = 0, ev_holed = 0; double hiccup = 0, hiccup_ms = 0; int stalls = 0; std::string sst, rst; };
static const uint32_t L = 7200, LX = 256, PDC = 100, B = 256;

// stall: at stall_at seconds, the sender's audio thread (who & 1) and/or the remote's (who & 2) stop for stall_ms and then catch up
// in a burst, as a VM pause or a disk/scheduler hiccup does. Each audio thread notes any gap over STALL_S between its turns (a stall).
// lat: the sender's latency budget (a long link's bigger one); dry: "Dry when late" on at the sender, so a lost frame plays its input;
// midi: a note every 100 ms goes with the audio, and the fake remote plug-in is an instrument that adds a click (+0.25 before its x0.5) on
// the frame each one comes out of Hop X, so a note back exactly at its frame + lat is the MIDI lined up to the sample (rt-hopvst).
static const float CLICK = 0.25f;
// rt-hop2, held MIDI: what the sender plays (script, sender frames), which of its MIDI datagrams the wire loses (lose, from the run's start
// t0), and what the remote's Hop X sounded: each note as X started and let go of it (X frames; off ~0: still sounding at the end), every
// sustain change, and any snapshot X played itself (leaked: never).
struct MEv { uint64_t f; uint8_t b0, b1, b2; };
struct Sounded { int note; uint64_t on, off; };
struct MidiPlan {
  std::vector<MEv> script;
  std::function<bool(const unsigned char *, int, double)> lose; // (datagram, its length, seconds since the run's start)
  std::atomic<double> t0{ 0 };
  std::vector<Sounded> sounded;
  std::vector<std::pair<uint64_t, int>> pedal;
  int leaked = 0;
  uint64_t x_end = 0;
};
// Whether a MIDI datagram carries this message (its events: frame u64, msg u32, len u32 after the 20-byte header; extension/hopnet.cpp).
static bool carries(const unsigned char *d, int n, uint32_t msg)
{
  uint16_t nf;
  memcpy(&nf, d + 6, 2);
  for (int k = 0; k < nf && 20 + k * 16 + 16 <= n; ++k) {
    uint32_t m;
    memcpy(&m, d + 20 + k * 16 + 8, 4);
    if ((m & 0xFFFFFF) == msg) return true;
  }
  return false;
}
static Result run(int id0, double base_ms, double jitter_ms, double loss, double drift, double secs, const char *rsecret = "studio",
                  double stall_at = 0, double stall_ms = 0, int who = 0, double spike_every = 0, double spike_ms = 0, uint64_t jump = 0,
                  uint32_t lat = L, bool dry = false, bool midi = false, MidiPlan *plan = nullptr)
{
  Result res;
  const int hs = id0, hx = id0 + 1, hy = id0 + 2;
  Wire wa, wb;
  wa.base_ms = wb.base_ms = base_ms; wa.jitter_ms = wb.jitter_ms = jitter_ms; wa.loss = wb.loss = loss;
  wa.spike_every = spike_every; wa.spike_ms = spike_ms; // (the way out only: the remote's side of a spike is what's checked)
  wb.rng.seed(999);
  if (plan) wa.lose_midi = [plan](const unsigned char *d, int n) { return plan->lose && plan->t0.load() > 0 && plan->lose(d, n, now_s() - plan->t0.load()); };
  End a{}, b{};
  a.wire = &wa; b.wire = &wb;
  const unsigned long pid = hop_reaper_pid();
  a.net = hopnet_new(send_fn, &a, pid);
  b.net = hopnet_new(send_fn, &b, pid);
  a.s = udp(a.me); b.s = udp(b.me);

  // the plug-ins' mappings, as each plug-in opens its own (the cores attach to them like HopPlugin::apply)
  hop_map ms, mx, my;
  hop_shm *S = hop_shm_open(&ms, pid, hs), *X = hop_shm_open(&mx, pid, hx), *Y = hop_shm_open(&my, pid, hy);
  CHECK(S && X && Y, "the mappings open");
  if (!S || !X || !Y) return res;
  S->srate = X->srate = Y->srate = 48000;
  HopCore cs, cx, cy;
  cs.latency = lat; cs.dry_when_late = dry ? 1.f : 0.f; cs.reset(); cs.attach(S);
  std::vector<uint64_t> evs; // (the sender's frames the notes went in at)
  cx.latency = LX; cx.dry_when_late = 0; cx.reset(); cx.attach(X);
  cy.latency = LX; cy.dry_when_late = 0; cy.reset(); cy.attach(Y);

  char json[256], peer[64];
  snprintf(json, sizeof(json), "{\"secret\":\"%s\",\"token\":%u,\"x\":%d,\"y\":%d,\"pdc\":%u,\"margin_ms\":20}", rsecret, 4000000000u + id0, hx, hy, PDC);
  CHECK(hopnet_serve(b.net, json) == 1, "serve starts");
  snprintf(json, sizeof(json), "{\"secret\":\"studio\",\"token\":%u}", 4000000000u + id0);
  snprintf(peer, sizeof(peer), "127.0.0.1:%d", ntohs(b.me.sin_port));
  CHECK(hopnet_connect(a.net, hs, peer, json) == 1, "connect starts");

  double t0s = 0, hic[2] = { 0, 0 }, hic_ms[2] = { 0, 0 }, hic_jump = 0;
  int hic_n[2] = { 0, 0 };
  auto gap = [&](int k, double &last) { const double t = now_s(); if (t - last > STALL_S) { hic[k] = t; ++hic_n[k]; hic_ms[k] = std::max(hic_ms[k], (t - last) * 1000); } last = t; };
  std::vector<float> out0, out1;
  out0.reserve((size_t)(secs * 48000) + 4096); out1.reserve(out0.capacity());
  g_run = true;
  std::thread t1(wire_loop, &wa, &a), t2(wire_loop, &wb, &b), t3(rx_loop, &a), t4(rx_loop, &b);
  // the sender's audio clock: its signal in, every output kept
  std::thread ts([&] {
    std::vector<float> i0(B), i1(B), o0(B), o1(B);
    const double t0 = t0s = now_s();
    if (plan) plan->t0 = t0;
    size_t si = 0; // (the plan's next scripted event)
    double last = t0;
    uint64_t done = 0;
    bool stalled = false;
    while (now_s() - t0 < secs) {
      gap(0, last);
      if ((who & 1) && !stalled && now_s() - t0 >= stall_at) { stalled = true; std::this_thread::sleep_for(std::chrono::microseconds((int)(stall_ms * 1000))); }
      // jump: at stall_at the sender processes `jump` frames more at once and stays that far ahead (REAPER at the start of playback)
      const bool jumped = jump && now_s() - t0 >= stall_at;
      if (jumped && !hic_jump) hic_jump = now_s();
      const uint64_t due = (uint64_t)((now_s() - t0) * 48000) + (jumped ? jump : 0);
      while (done + B <= due) {
        for (uint32_t k = 0; k < B; ++k) { i0[k] = sig(done + k); i1[k] = -sig(done + k); }
        const float *in[2] = { i0.data(), i1.data() };
        float *o[2] = { o0.data(), o1.data() };
        HopMidiEv me[16];
        uint32_t nme = 0;
        const uint64_t next = (evs.size() + 1) * 4800 + (evs.size() * 37) % B; // (a note every 100 ms, anywhere in a block)
        if (midi && next >= done && next < done + B) {
          me[0].frame = (uint32_t)(next - done); me[0].size = 3; me[0].data[0] = 0x90; me[0].data[1] = 60; me[0].data[2] = 100; me[0].data[3] = 0;
          nme = 1;
          evs.push_back(next);
        }
        for (; plan && si < plan->script.size() && plan->script[si].f < done + B && nme < 16; ++si) {
          const MEv &e = plan->script[si];
          me[nme++] = HopMidiEv{ (uint32_t)(e.f > done ? e.f - done : 0), 3, { e.b0, e.b1, e.b2, 0 } };
        }
        cs.process(in, o, B, me, nme);
        out0.insert(out0.end(), o0.begin(), o0.end());
        out1.insert(out1.end(), o1.begin(), o1.end());
        done += B;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
  });
  // the remote's audio clock (`drift` faster or slower): X -> 100-sample delay x 0.5 -> Y
  std::thread tr([&] {
    std::vector<float> z(B, 0.f), x0(B), x1(B), y0(B), y1(B), o0(B), o1(B), d0(PDC, 0.f), d1(PDC, 0.f);
    std::vector<uint64_t> xon(128, 0); // (X frame + 1 each note started at, channel 1; 0: not sounding)
    size_t dp = 0;
    const double t0 = now_s();
    double last = t0;
    uint64_t done = 0;
    bool stalled = false;
    while (now_s() - t0 < secs) {
      gap(1, last);
      if ((who & 2) && !stalled && now_s() - t0 >= stall_at) { stalled = true; std::this_thread::sleep_for(std::chrono::microseconds((int)(stall_ms * 1000))); }
      const uint64_t due = (uint64_t)((now_s() - t0) * 48000 * (1 + drift));
      while (done + B <= due) {
        const float *zin[2] = { z.data(), z.data() };
        float *xo[2] = { x0.data(), x1.data() };
        cx.process(zin, xo, B);
        for (uint32_t e = 0; e < cx.nmout; ++e) {
          const HopMidiEv &m = cx.mout[e];
          const bool note_on = (m.data[0] & 0xF0) == 0x90 && m.data[2] > 0;
          if (midi && note_on) { x0[m.frame] += CLICK; x1[m.frame] -= CLICK; } // (the instrument: a click on each note)
          if (!plan) continue;
          const uint64_t x = done + m.frame; // (the plan's instrument: what X left sounding, X frames)
          if (m.data[0] == 0xF4 || m.data[0] == 0xF5) plan->leaked++;
          else if (note_on) { if (!xon[m.data[1] & 127]) xon[m.data[1] & 127] = x + 1; }
          else if ((m.data[0] & 0xF0) == 0x80 || (m.data[0] & 0xF0) == 0x90) {
            if (xon[m.data[1] & 127]) plan->sounded.push_back({ m.data[1] & 127, xon[m.data[1] & 127] - 1, x });
            xon[m.data[1] & 127] = 0;
          } else if ((m.data[0] & 0xF0) == 0xB0 && m.data[1] == 64) plan->pedal.push_back({ x, m.data[2] });
        }
        for (uint32_t k = 0; k < B; ++k) {
          y0[k] = d0[dp] * 0.5f; y1[k] = d1[dp] * 0.5f;
          d0[dp] = x0[k]; d1[dp] = x1[k];
          dp = (dp + 1) % PDC;
        }
        const float *yin[2] = { y0.data(), y1.data() };
        float *yo[2] = { o0.data(), o1.data() };
        cy.process(yin, yo, B);
        done += B;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    if (plan) {
      for (int n = 0; n < 128; ++n) if (xon[n]) plan->sounded.push_back({ n, xon[n] - 1, ~0ull });
      plan->x_end = done;
    }
  });
  ts.join(); tr.join();
  res.sst = hopnet_status(a.net, hs);
  res.rst = hopnet_status(b.net, hx);
  g_run = false;
  t1.join(); t2.join(); t3.join(); t4.join();
  hopnet_free(a.net); hopnet_free(b.net);
  close_sock(a.s); close_sock(b.s);
  hop_shm_close(&ms); hop_shm_close(&mx); hop_shm_close(&my);
  hop_shm_unlink(&ms); hop_shm_unlink(&mx); hop_shm_unlink(&my);

  // every frame: exactly 0.5 x the input lat frames before (with the click where a note went in), or 0 (or the input itself, with dry), or
  // fading from that towards the return
  res.frames = out0.size();
  std::vector<char> click(out0.size(), 0);
  for (uint64_t e : evs) if (e + lat < out0.size()) click[(size_t)(e + lat)] = 1;
  const double hl = std::max({ hic[0], hic[1], hic_jump, wa.late_at, wb.late_at });
  res.hiccup = hl > 0 ? hl - t0s : 0;
  res.hiccup_ms = std::max({ hic_ms[0], hic_ms[1], wa.late_ms, wb.late_ms });
  res.stalls = hic_n[0] + hic_n[1] + wa.late_n + wb.late_n;
  for (uint64_t i = lat; i < out0.size(); ++i) {
    const float c0 = click[(size_t)i] ? 0.5f * CLICK : 0.f;
    const float e[2] = { 0.5f * sig(i - lat) + c0, -0.5f * sig(i - lat) - c0 }, d[2] = { sig(i - lat), -sig(i - lat) }, o[2] = { out0[i], out1[i] };
    int ex = 0, zr = 0, fd = 0, dr = 0;
    for (int c = 0; c < 2; ++c) {
      const float lo = dry ? std::min(std::fabs(e[c]), std::fabs(d[c])) : 0.f, hi = dry ? std::max(std::fabs(e[c]), std::fabs(d[c])) : std::fabs(e[c]);
      if (o[c] == e[c]) ex++;
      else if (dry && o[c] == d[c]) dr++;
      else if (!dry && o[c] == 0.f) zr++;
      else if (std::fabs(o[c]) >= lo * 0.999f && std::fabs(o[c]) <= hi * 1.001f && (o[c] > 0) == (e[c] > 0)) fd++; // (a fade: between the two)
    }
    const bool aft = res.hiccup > 0 && i >= (uint64_t)((res.hiccup + 1) * 48000);
    res.after += aft;
    if (ex == 2) { res.exact++; res.exact_after += aft; if (!res.first_wet) res.first_wet = i; }
    else if (zr == 2) res.zero++;
    else if (dr == 2) res.dry++;
    else if (ex + zr + fd + dr == 2) res.faded++;
    else res.wrong++;
  }
  for (uint64_t e : evs)
    if (res.first_wet && e + lat >= res.first_wet && e + lat < out0.size()) {
      const float o = out0[(size_t)(e + lat)];
      res.events++;
      res.ev_exact += o == 0.5f * sig(e) + 0.5f * CLICK;
      res.ev_holed += o != 0.5f * sig(e) + 0.5f * CLICK && o != 0.5f * sig(e); // (its audio back without the click: the MIDI's miss, not a hole)
    }
  return res;
}

static double num(const std::string &j, const char *key)
{
  const size_t at = j.find(std::string("\"") + key + "\":");
  return at == std::string::npos ? -1 : atof(j.c_str() + at + strlen(key) + 3);
}
static void report(const char *what, const Result &r)
{
  const uint64_t wet = r.frames > r.first_wet ? r.frames - r.first_wet : 0;
  printf("%s: %llu frames, first wet at %.0f ms, after it exact %.2f%% zero %llu dry %llu faded %llu wrong %llu, notes %llu/%llu exact (%llu in audio holes)\n  send %s\n  serve %s\n", what,
         (unsigned long long)r.frames, r.first_wet / 48.0, wet ? 100.0 * r.exact / wet : 0.0, (unsigned long long)r.zero, (unsigned long long)r.dry,
         (unsigned long long)r.faded, (unsigned long long)r.wrong, (unsigned long long)r.ev_exact, (unsigned long long)r.events, (unsigned long long)r.ev_holed, r.sst.c_str(), r.rst.c_str());
}
static double exact_pct(const Result &r) { const uint64_t wet = r.frames > r.first_wet ? r.frames - r.first_wet : 0; return wet ? 100.0 * r.exact / wet : 0; }
// After a stall: from a second after it, every frame back exact; and once the status's windows (the last one to two seconds) no longer
// hold it, the hop is back inside its budget with slack to spare. What a stall too near the run's end leaves no time for isn't checked.
// This computer's 1 ms sleep (median), measured at the start. The hop and this harness poll on 1 ms timers (REAPER's), and the hop's need
// counts them at that. Over 2 ms the timers are coarse (GitHub's hosted Mac: 8-15 ms for a 3 ms sleep, Linux and Windows ~1 ms): each of
// the round trip's four timed stages (the sender's turn, the wire out, the remote's turn, the wire back) runs up to a tick late under
// STALL_S, unseen, and the jump scenario's slack there came out 42 ms under Linux's with no stall seen. So on coarse timers, unless
// SS_TIMING_STRICT, recovery is held to no lasting loss (95% exact; staying behind is ~0%) and slack to -4 ticks. (A hosted Mac's recovery after
// a stall ran 98.4-98.9% three times in 30 runs, 2026-11-20: its tighten 0.15 s on sees the ticks' jitter and waits for the next window)
static double g_tick_ms = 1;
static bool coarse() { return g_tick_ms > 2 && !strict(); }
static void recovered(const Result &r, double secs)
{
  printf("  a %.0f ms stall ending %.2f s in; from a second after it: exact %.2f%% of %llu frames\n", r.hiccup_ms, r.hiccup,
         r.after ? 100.0 * r.exact_after / r.after : 0.0, (unsigned long long)r.after);
  if (r.after >= 24000)
    CHECK(r.exact_after * 1000 >= r.after * (coarse() ? 950 : 999),
          coarse() ? "no lasting loss from a second after the stall (coarse timers: 95 percent)" : "every frame back exact from a second after the stall");
  else { printf("  (too near the end to check the frames after it)\n"); CHECK(!strict(), "a run that leaves time to check after its last stall (SS_TIMING_STRICT)"); }
  if (r.hiccup <= secs - 2.3)
    CHECK(num(r.sst, "slack_ms") >= (coarse() ? -4 * g_tick_ms : 0) && num(r.sst, "need_ms") < num(r.sst, "budget_ms"), "back inside the budget, slack to spare");
  else printf("  (too near the end to check the budget after it)\n");
}

// Up to 3 tries of a run until `ok`: a run the harness kept its own timing in (or one whose last stall leaves time to check after it).
// The decision is on the harness's timing alone, never on the hop's result.
template <class R, class Ok> static Result tries(R one, Ok ok)
{
  Result r = one();
  for (int t = 1; t < 3 && !ok(r); ++t) {
    printf("  (the harness stalled %.0f ms, the last %.2f s in: again)\n", r.hiccup_ms, r.hiccup);
    r = one();
  }
  return r;
}

// rt-hop2, held MIDI: how long past its note-off X kept each scripted note (unique note numbers, channel 1), lined up by K = X frame -
// sender frame of a note started on time (the smallest seen); and whether the pedal was up at X bound_ms after each release.
// stuck: still sounding when the run ended; hung: that, or let go more than bound_ms late; early: let go more than early_ms before its note-off.
struct Held { int notes = 0, heard = 0, stuck = 0, hung = 0, early = 0, pedal_late = 0; double worst_ms = 0, early_ms = 0; };
static Held held_check(const MidiPlan &p, double bound_ms, double early_ms)
{
  Held h;
  uint64_t on[128], off[128];
  for (int n = 0; n < 128; ++n) on[n] = off[n] = ~0ull;
  for (const MEv &e : p.script) {
    if ((e.b0 & 0xF0) == 0x90 && e.b2) on[e.b1 & 127] = e.f;
    else if ((e.b0 & 0xF0) == 0x80) off[e.b1 & 127] = e.f;
  }
  int64_t K = INT64_MAX;
  for (const Sounded &s : p.sounded) if (on[s.note] != ~0ull) K = std::min(K, (int64_t)s.on - (int64_t)on[s.note]);
  for (int n = 0; n < 128; ++n) {
    if (on[n] == ~0ull) continue;
    h.notes++;
    const Sounded *s = nullptr;
    for (const Sounded &x : p.sounded) if (x.note == n) { s = &x; break; }
    if (!s || K == INT64_MAX) continue; // (its note-on never reached X: nothing sounded)
    h.heard++;
    const double past = ((s->off == ~0ull ? (int64_t)p.x_end : (int64_t)s->off) - ((int64_t)off[n] + K)) / 48.0;
    h.worst_ms = std::max(h.worst_ms, past);
    h.stuck += s->off == ~0ull;
    h.hung += s->off == ~0ull || past > bound_ms;
    if (-past > early_ms) { h.early++; h.early_ms = std::max(h.early_ms, -past); }
  }
  for (const MEv &e : p.script) {
    if ((e.b0 & 0xF0) != 0xB0 || e.b1 != 64 || e.b2 >= 64 || K == INT64_MAX) continue;
    int v = 0;
    for (const auto &pe : p.pedal) if ((int64_t)pe.first <= (int64_t)e.f + K + (int64_t)(bound_ms * 48)) v = pe.second;
    h.pedal_late += v >= 64;
  }
  return h;
}
static void held_report(const Held &h, const MidiPlan &p)
{
  printf("  notes %d, %d sounded at X; the worst let go %.0f ms past its note-off; %d stuck, %d past the bound, %d cut early (by up to %.0f ms); "
         "pedal still down %d; snapshots X played %d\n", h.notes, h.heard, h.worst_ms, h.stuck, h.hung, h.early, h.early_ms, h.pedal_late, p.leaked);
}

int main()
{
#ifdef _WIN32
  timeBeginPeriod(1); // (REAPER runs with 1 ms timers; Windows' default 15.6 ms would bunch the test's blocks)
#endif
  {
    std::vector<double> t;
    for (int i = 0; i < 21; ++i) { const double a = now_s(); std::this_thread::sleep_for(std::chrono::milliseconds(1)); t.push_back((now_s() - a) * 1000); }
    std::sort(t.begin(), t.end());
    g_tick_ms = t[10];
    printf("a 1 ms sleep here: %.1f ms (median of 21)%s; SS_TIMING_STRICT %s\n", g_tick_ms, g_tick_ms > 2 ? ", coarse" : "", strict() ? "on" : "off");
  }
  {
    Result r = tries([] { return run(1, 2, 0, 0, 0, 3); }, [](const Result &x) { return x.hiccup == 0; });
    report("clean", r);
    CHECK(r.first_wet > 0 && r.first_wet < 48000, "the hop comes up within a second");
    CHECK(r.wrong == 0, "nothing misaligned or wrong");
    CHECK(num(r.sst, "rtt_ms") >= 0 && num(r.sst, "remote_ms") > 0, "round trip measured");
    if (r.hiccup > 0) recovered(r, 3); // (the runner paused: a moment of fallback audio and a slip or two are fair, staying behind isn't)
    else if (coarse()) {
      // (no stall seen, but the way out's three timed stages each up to a tick late, unseen, outlast the remote's 20 ms margin on a hosted
      // Mac's 7-9 ms ticks: a run of late packets, a slip and a packet or two lost, 2026-11-20. Held to no lasting loss, as after a stall)
      printf("  (coarse timers: lost %.0f, slips %.0f passed over; held to 99 percent exact)\n", num(r.sst, "lost"), num(r.rst, "slips"));
      CHECK(exact_pct(r) > 99, "no lasting loss with the clocks together (coarse timers: 99 percent)");
      CHECK(num(r.sst, "need_ms") < num(r.sst, "budget_ms"), "inside the budget");
    } else {
      CHECK(exact_pct(r) > 99.9, "every frame back, sample-exact, once up");
      CHECK(num(r.sst, "lost") == 0 && num(r.sst, "late") == 0, "nothing lost or late");
      CHECK(num(r.sst, "need_ms") < num(r.sst, "budget_ms"), "inside the budget");
      CHECK(num(r.rst, "slips") == 0, "no slip with the clocks together");
    }
  }
  {
    Result r = tries([] { return run(11, 5, 8, 0.02, 0, 3); }, [](const Result &x) { return x.hiccup == 0; });
    report("jitter 5-13 ms, 2% loss each way", r);
    CHECK(r.wrong == 0, "nothing misaligned or wrong under jitter and loss");
    // (a harness stall on top of the jitter: 82% on a hosted Mac stalling 59-113 ms in every try, 2026-11-20)
    if (r.hiccup > 0 && !strict()) printf("  (the harness stalled %.0f ms in every try: most frames back exact passed over, SS_TIMING_STRICT off)\n", r.hiccup_ms);
    else CHECK(exact_pct(r) > 85, "most frames back exact");
    CHECK(num(r.sst, "lost") > 0, "the losses counted");
  }
  {
    Result r = run(21, 3, 2, 0, 0.01, 4);
    report("remote clock 1% fast", r);
    CHECK(r.wrong == 0, "nothing misaligned when the remote's clock runs fast");
    CHECK(num(r.rst, "slips") >= 1, "it slipped to keep up");
    CHECK(exact_pct(r) > 90, "most frames back exact");
  }
  {
    Result r = run(31, 3, 2, 0, -0.01, 6);
    report("remote clock 1% slow", r);
    CHECK(r.wrong == 0, "nothing misaligned when the remote's clock runs slow");
    CHECK(num(r.rst, "slips") >= 1, "it slipped back to its margin");
    CHECK(exact_pct(r) > 85, "most frames back exact");
  }
  // A hiccup (James, rt): the macOS runner pauses its VM for about 60 ms now and then, and a real computer can stall on a disk or the
  // scheduler. It may cost a moment of fallback audio, never the rest of the session: within a second of it every frame is back exact,
  // with slack to spare, and nothing ever comes back misaligned.
  const struct { const char *what; int id, who; double ms; } stalls[] = {
    { "the remote stalls 80 ms", 51, 2, 80 }, { "the sender stalls 80 ms", 61, 1, 80 }, { "both stall 100 ms", 4, 3, 100 } };
  for (const auto &st : stalls) {
    Result r = tries([&] { return run(st.id, 3, 2, 0, 0, 4, "studio", 1.0, st.ms, st.who); }, [](const Result &x) { return x.hiccup <= 4 - 2.3; });
    report(st.what, r);
    CHECK(r.hiccup > 0, "the stall seen");
    CHECK(r.wrong == 0, "nothing misaligned through a stall");
    recovered(r, 4);
  }
  // The desktop <-> laptop link (2026-11-19, over the internet): a 90 ms round trip, and now and then a 40 ms stall on the way out, with
  // the 150 ms budget about 12 ms to spare. A late packet at the remote is lost, and only that: it doesn't move the timing (a "slip")
  // when the packets after it are on time again, which made each spike cost the next 150 ms too (all of it later than the budget).
  // The margin is the point, so it's set on this computer: the same wire without spikes first, and each way shortened by half what its need
  // is over the budget less 3 ms (the Linux runners' own: need 146-147.6 ms of 150, 2026-11-20; a hosted Mac's round trip and its remote's
  // guard ran 5-15 ms over, which left the spikes no margin at all and made every packet late, not just theirs). A loaded runner's need
  // moves +-10 ms from run to run, so each try is shortened again by its own excess, and a run is checked only with the margin it's about
  // (its own need within the budget) and no harness stall longer than a spike: a shorter one is one more spike, which the checks' room
  // covers (Linux: ~99% exact, 4-6 holes). The hosted Mac stalls 18-41 ms several times a run, so no run of it is ever free of them.
  {
    auto clean = [](const Result &x) { return x.hiccup == 0; };
    const Result c = tries([] { return run(8, 45, 3, 0, 0, 3); }, clean);
    const double budget = num(c.sst, "budget_ms"), need0 = num(c.sst, "need_ms");
    // (coarse timers: the need doesn't count the four timed stages' ticks (recovered's -4 ticks), so the margin leaves them room too: a
    // hosted Mac's need of 148.7 ms of 150 on 7.4 ms ticks came back 12% late, its spikes no margin at all, 2026-11-20)
    const double room = coarse() ? 4 * g_tick_ms : 0;
    auto over = [&](const Result &x) { return num(x.sst, "need_ms") - (budget - 3 - room); };
    double base = 45 - std::min(15.0, std::max(0.0, over(c) / 2));
    printf("the same wire without spikes: need %.1f ms of %.0f (%.0f ms left for coarse timers), so each way %.1f ms\n", need0, budget, room, base);
    // (a hosted Mac stalling in all three tries measured a need of 298.8 ms, 2026-11-20: the harness's, not the link's)
    if (c.hiccup > 0 && !strict()) printf("  (the harness stalled %.0f ms in every try: the margin check passed over, SS_TIMING_STRICT off)\n", c.hiccup_ms);
    else CHECK(need0 > 0 && over(c) - room <= 30, "the link without spikes within 30 ms of the margin (or the runner's too slow for this check)");
    auto fair = [&](const Result &x) { return x.hiccup_ms < 40 && over(x) <= 3; };
    Result r = run(7, base, 3, 0, 0, 6, "studio", 0, 0, 0, 1.3, 40);
    for (int t = 1; t < 3 && !fair(r); ++t) {
      base = std::max(25.0, base - std::max(0.0, over(r) / 2));
      printf("  (need %.1f ms, the harness's worst stall %.0f ms: again, each way %.1f ms)\n", num(r.sst, "need_ms"), r.hiccup_ms, base);
      r = run(7, base, 3, 0, 0, 6, "studio", 0, 0, 0, 1.3, 40);
    }
    report("a 90 ms round trip, a 40 ms spike on the way out every 1.3 s", r);
    if (r.hiccup > 0) printf("  (the harness's own stalls: %d, the worst %.0f ms)\n", r.stalls, r.hiccup_ms);
    CHECK(r.wrong == 0, "nothing misaligned through the spikes");
    if (fair(r)) {
      // (coarse timers: the way out's three stages, each up to a tick late, unseen, outlast the remote's 20 ms margin after a spike, as in the
      // clean run: a slip there is the runner's)
      if (coarse()) printf("  (coarse timers: slips %.0f passed over)\n", num(r.rst, "slips"));
      else CHECK(num(r.rst, "slips") == 0, "a spike isn't drift: no slip");
      CHECK(exact_pct(r) > 94, "a spike costs only its own packets");
      // (10: two a spike, and as many for each harness stall, one more spike each: a hosted Mac had 16 with stalls up to 38 ms)
      CHECK(num(r.sst, "holes") >= 1 && num(r.sst, "holes") <= 10 + 2 * r.stalls, "about a dropout a spike (or a harness stall), counted");
    } else {
      printf("  (no try had the margin and no harness stall longer than a spike: the spike checks need one)\n");
      CHECK(!strict(), "a spike run with its margin and no harness stall longer than a spike (SS_TIMING_STRICT)");
    }
  }
  // REAPER at the start of playback processes the hop's whole latency at once (its delay compensation lining up) and stays that far
  // ahead: a moment of fallback audio, then every frame back exact again well within a second, not after the 3 s it took (REAPER, 2026-11-19).
  {
    Result r = tries([] { return run(14, 30, 2, 0, 0, 4, "studio", 1.0, 0, 0, 0, 0, L - B); }, [](const Result &x) { return x.hiccup <= 4 - 2.3; });
    report("the sender jumps its latency ahead (playback starts)", r);
    CHECK(r.wrong == 0, "nothing misaligned through the jump");
    recovered(r, 4);
  }
  // rt-hopvst: "Dry when late" on, 2% loss each way: a lost frame plays the input itself (dry), never silence, and fades back to the return.
  {
    Result r = tries([] { return run(17, 5, 3, 0.02, 0, 3, "studio", 0, 0, 0, 0, 0, 0, L, true); }, [](const Result &x) { return x.hiccup == 0; });
    report("2% loss each way, dry when late", r);
    CHECK(r.wrong == 0, "nothing misaligned or wrong with dry fills");
    CHECK(r.zero == 0, "no silent frame: every lost one plays dry (%llu silent)", (unsigned long long)r.zero);
    CHECK(r.dry > 0 && num(r.sst, "lost") > 0, "the lost frames played dry, and were counted");
    CHECK(r.sst.find("\"dry_lost\":true") != std::string::npos, "the status says lost frames play dry");
    if (!(r.hiccup > 0 && !strict())) CHECK(exact_pct(r) > 85, "most frames back exact");
  }
  // rt-hopvst: a long link (300 ms round trip) inside a bigger budget (24000 = 500 ms; the plug-in's most is now HOP_LAT_MAX, 680 ms).
  {
    Result r = tries([] { return run(24, 150, 2, 0, 0, 4, "studio", 0, 0, 0, 0, 0, 0, 24000); }, [](const Result &x) { return x.hiccup == 0; });
    report("a 300 ms round trip, a 500 ms budget", r);
    CHECK(r.wrong == 0, "nothing misaligned on a long link");
    CHECK(r.first_wet > 0 && r.first_wet < 3 * 48000, "the hop comes up on a long link");
    CHECK(num(r.sst, "budget_ms") > 490 && num(r.sst, "need_ms") > 290 && num(r.sst, "need_ms") < num(r.sst, "budget_ms"), "a long link's need inside the bigger budget");
    if (r.hiccup > 0 && !strict()) printf("  (the harness stalled: exactness passed over, SS_TIMING_STRICT off)\n");
    else CHECK(exact_pct(r) > (coarse() ? 99 : 99.9), "every frame back exact on a long link");
  }
  // rt-hopvst: MIDI with the audio (an instrument you don't have): a note every 100 ms comes out of the remote's Hop X on the very frame
  // whose audio it went in with, so the instrument's sound is back exactly at the note's frame + the latency. Lossless first, then 2% loss
  // each way (each note goes at least twice, so most still land).
  {
    Result r = tries([] { return run(27, 3, 2, 0, 0, 3, "studio", 0, 0, 0, 0, 0, 0, L, false, true); }, [](const Result &x) { return x.hiccup == 0; });
    report("MIDI notes with the audio", r);
    CHECK(r.wrong == 0, "nothing misaligned with MIDI");
    CHECK(r.events >= 10, "notes went (%llu)", (unsigned long long)r.events);
    CHECK(num(r.rst, "midi") >= (double)r.events, "the remote took every note once (%.0f of %llu)", num(r.rst, "midi"), (unsigned long long)r.events);
    if (r.hiccup > 0 && !strict()) printf("  (the harness stalled: note exactness passed over, SS_TIMING_STRICT off)\n");
    else CHECK(r.ev_exact * 100 >= r.events * (coarse() ? 90 : 99), "every note's click back on its exact frame (%llu of %llu)", (unsigned long long)r.ev_exact, (unsigned long long)r.events);
    Result q = tries([] { return run(34, 5, 3, 0.02, 0, 3, "studio", 0, 0, 0, 0, 0, 0, L, false, true); }, [](const Result &x) { return x.hiccup == 0; });
    report("MIDI notes, 2% loss each way", q);
    CHECK(q.wrong == 0, "nothing misaligned with MIDI under loss");
    // (rt-ci3: the click rides in the audio, so a note whose frame fell in an audio hole is lost with the audio, not the MIDI: ~5.5% of
    // frames here, so 24 notes miss 0-4 by chance. A deterministic wire gives fine timers the same 2 misses every run, while coarse ones
    // packetize differently each run and drew 4, under the old 85%. Every note whose audio came back must carry its click)
    if (!(q.hiccup > 0 && !strict())) {
      CHECK(q.ev_exact + q.ev_holed == q.events, "every note whose audio came back lands on its exact frame under loss (%llu exact, %llu in audio holes, of %llu)",
            (unsigned long long)q.ev_exact, (unsigned long long)q.ev_holed, (unsigned long long)q.events);
      CHECK(q.ev_exact * 100 >= q.events * 70, "most notes land under loss (%llu of %llu)", (unsigned long long)q.ev_exact, (unsigned long long)q.events);
    }
    CHECK(num(q.rst, "midi") >= (double)q.events, "the remote took every note under loss (%.0f of %llu)", num(q.rst, "midi"), (unsigned long long)q.events);
  }
  // rt-hop2: no hung notes. A note-off lost twice (its packet and the 20 ms repeat) hung its note until the try stopped: nothing after it
  // carried it again. Now held-note snapshots go with the MIDI and the remote's Hop X lets go of what they (or their silence for 200 ms)
  // say isn't held. The bound, under any loss pattern and any single burst: no note sounds at X more than HOLD_BOUND_MS past its note-off
  // (200 ms with no snapshot, plus a block each side and the wire's jitter). With 10% of MIDI datagrams lost at random no held note or
  // pedal is cut early (that would take every snapshot datagram for 200 ms lost: about eight in a row).
  {
    const double HOLD_BOUND_MS = 250, EARLY_MS = 50;
    std::unique_ptr<MidiPlan> plan;
    auto midi_run = [&](int id, double secs, std::vector<MEv> script, std::function<bool(const unsigned char *, int, double)> lose) {
      plan.reset(new MidiPlan());
      std::sort(script.begin(), script.end(), [](const MEv &a, const MEv &b) { return a.f < b.f; });
      plan->script = std::move(script);
      plan->lose = std::move(lose);
      return run(id, 3, 2, 0, 0, secs, "studio", 0, 0, 0, 0, 0, 0, L, false, false, plan.get());
    };
    auto clean = [](const Result &x) { return x.hiccup == 0; };
    const uint32_t NOTE_OFF = 0x80u | 60u << 8;
    const std::vector<MEv> one = { { 72000, 0x90, 60, 100 }, { 96000, 0x80, 60, 0 } }; // (one note, 1.5 s to 2 s, then nothing)
    {
      int lost = 0;
      Result r = tries([&] { lost = 0; return midi_run(44, 3.5, one, [&lost, NOTE_OFF](const unsigned char *d, int n, double) { return lost < 2 && carries(d, n, NOTE_OFF) && ++lost; }); }, clean);
      Held h = held_check(*plan, HOLD_BOUND_MS, EARLY_MS);
      report("a note-off lost twice", r);
      held_report(h, *plan);
      CHECK(lost == 2, "the note-off's first two datagrams lost (%d)", lost);
      CHECK(h.heard == 1, "the note sounded at X");
      CHECK(h.stuck == 0 && h.hung == 0, "a note-off lost twice doesn't hang the note (let go %.0f ms past its note-off)", h.worst_ms);
      CHECK(plan->leaked == 0, "X never plays a snapshot itself");
    }
    {
      Result r = tries([&] { return midi_run(47, 3.5, one, [NOTE_OFF](const unsigned char *d, int n, double) { return carries(d, n, NOTE_OFF); }); }, clean);
      Held h = held_check(*plan, HOLD_BOUND_MS, EARLY_MS);
      report("a note-off lost every time it's sent", r);
      held_report(h, *plan);
      CHECK(h.heard == 1 && h.stuck == 0, "a note-off that never arrives doesn't hang the note");
      if (r.hiccup > 0 && !strict()) printf("  (the harness stalled: the bound passed over, SS_TIMING_STRICT off)\n");
      else CHECK(h.hung == 0, "let go within %.0f ms of its note-off (%.0f)", HOLD_BOUND_MS, h.worst_ms);
    }
    // chords and the sustain pedal: a note every 60 ms from 1.2 s, each held 200 ms (3-4 at once), the pedal down 0.3 s three times
    std::vector<MEv> dense;
    for (int i = 0; 57600 + i * 2880 + 9600 < 220800; ++i) {
      dense.push_back({ (uint64_t)(57600 + i * 2880), 0x90, (uint8_t)(30 + i), 100 });
      dense.push_back({ (uint64_t)(57600 + i * 2880 + 9600), 0x80, (uint8_t)(30 + i), 0 });
    }
    for (uint64_t at : { 72000, 120000, 168000 }) { dense.push_back({ at, 0xB0, 64, 127 }); dense.push_back({ at + 14400, 0xB0, 64, 0 }); }
    {
      Result r = tries([&] {
        auto rng = std::make_shared<std::mt19937>(4242);
        return midi_run(54, 5, dense, [rng](const unsigned char *, int, double) { return std::uniform_real_distribution<double>(0, 1)(*rng) < 0.1; });
      }, clean);
      Held h = held_check(*plan, HOLD_BOUND_MS, EARLY_MS);
      report("chords and the pedal, 10% of MIDI datagrams lost", r);
      held_report(h, *plan);
      CHECK(h.heard * 10 >= h.notes * 9, "the notes sounded at X (%d of %d)", h.heard, h.notes);
      CHECK(h.stuck == 0 && plan->leaked == 0, "nothing stuck, no snapshot played");
      if (r.hiccup > 0 && !strict()) printf("  (the harness stalled: the bound and early cuts passed over, SS_TIMING_STRICT off)\n");
      else {
        CHECK(h.hung == 0, "every note let go within %.0f ms of its note-off (worst %.0f)", HOLD_BOUND_MS, h.worst_ms);
        CHECK(h.early == 0, "no held note cut early (%d, by up to %.0f ms)", h.early, h.early_ms);
        CHECK(h.pedal_late == 0, "the pedal up again each time within the bound (%d late)", h.pedal_late);
      }
    }
    {
      Result r = tries([&] { return midi_run(57, 5, dense, [](const unsigned char *, int, double t) { return t >= 2.0 && t < 2.6; }); }, clean);
      Held h = held_check(*plan, HOLD_BOUND_MS, EARLY_MS);
      report("chords and the pedal, every MIDI datagram lost for 0.6 s", r);
      held_report(h, *plan);
      CHECK(h.stuck == 0 && plan->leaked == 0, "a burst leaves nothing stuck, no snapshot played");
      if (r.hiccup > 0 && !strict()) printf("  (the harness stalled: the bound passed over, SS_TIMING_STRICT off)\n");
      else {
        CHECK(h.hung == 0, "through a burst every note let go within %.0f ms of its note-off (worst %.0f)", HOLD_BOUND_MS, h.worst_ms);
        CHECK(h.pedal_late == 0, "through a burst the pedal up again within the bound (%d late)", h.pedal_late);
      }
    }
  }
  {
    Result r = run(41, 2, 0, 0, 0, 1.5, "not the studio's");
    report("wrong secret at the remote", r);
    CHECK(r.exact == 0 && r.wrong == 0, "nothing comes back: only silence");
    CHECK(num(r.sst, "returned") == 0 && num(r.rst, "received") == 0, "no audio crossed");
  }
  printf(fails ? "FAILED %d\n" : "ok: all hop network checks passed\n", fails);
  return fails ? 1 : 0;
}
