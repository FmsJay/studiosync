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
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <vector>
#include "../plugin/hop_core.h"
#include "../extension/hopnet.h"

static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static float sig(uint64_t i) { return (float)((i * 7919u) % 100003u) / 100003.f + 0.001f; } // (never 0: silence and signal differ)
static double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }

// ---- the wire: each endpoint's socket, and what goes between them late, shuffled or not at all ----
struct Pkt { double due; std::vector<unsigned char> d; sockaddr_in to; };
struct Wire {
  std::mutex mx;
  std::vector<Pkt> q;
  std::mt19937 rng{ 12345 };
  double base_ms = 2, jitter_ms = 0, loss = 0;
  long long dropped = 0;
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
  if (u(w.rng) < w.loss) { w.dropped++; return n; }
  Pkt p;
  p.due = now_s() + (w.base_ms + w.jitter_ms * u(w.rng)) / 1000.0;
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
        if (w->q[i].due <= t) { go.push_back(std::move(w->q[i])); w->q[i] = std::move(w->q.back()); w->q.pop_back(); } else ++i;
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
struct Result { uint64_t exact = 0, zero = 0, faded = 0, wrong = 0, first_wet = 0, frames = 0; std::string sst, rst; };
static const uint32_t L = 7200, LX = 256, PDC = 100, B = 256;

static Result run(int id0, double base_ms, double jitter_ms, double loss, double drift, double secs, const char *rsecret = "studio")
{
  Result res;
  const int hs = id0, hx = id0 + 1, hy = id0 + 2;
  Wire wa, wb;
  wa.base_ms = wb.base_ms = base_ms; wa.jitter_ms = wb.jitter_ms = jitter_ms; wa.loss = wb.loss = loss;
  wb.rng.seed(999);
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
  cs.latency = L; cs.dry_when_late = 0; cs.reset(); cs.attach(S);
  cx.latency = LX; cx.dry_when_late = 0; cx.reset(); cx.attach(X);
  cy.latency = LX; cy.dry_when_late = 0; cy.reset(); cy.attach(Y);

  char json[256], peer[64];
  snprintf(json, sizeof(json), "{\"secret\":\"%s\",\"token\":%u,\"x\":%d,\"y\":%d,\"pdc\":%u,\"margin_ms\":20}", rsecret, 4000000000u + id0, hx, hy, PDC);
  CHECK(hopnet_serve(b.net, json) == 1, "serve starts");
  snprintf(json, sizeof(json), "{\"secret\":\"studio\",\"token\":%u}", 4000000000u + id0);
  snprintf(peer, sizeof(peer), "127.0.0.1:%d", ntohs(b.me.sin_port));
  CHECK(hopnet_connect(a.net, hs, peer, json) == 1, "connect starts");

  std::vector<float> out0, out1;
  out0.reserve((size_t)(secs * 48000) + 4096); out1.reserve(out0.capacity());
  g_run = true;
  std::thread t1(wire_loop, &wa, &a), t2(wire_loop, &wb, &b), t3(rx_loop, &a), t4(rx_loop, &b);
  // the sender's audio clock: its signal in, every output kept
  std::thread ts([&] {
    std::vector<float> i0(B), i1(B), o0(B), o1(B);
    const double t0 = now_s();
    uint64_t done = 0;
    while (now_s() - t0 < secs) {
      const uint64_t due = (uint64_t)((now_s() - t0) * 48000);
      while (done + B <= due) {
        for (uint32_t k = 0; k < B; ++k) { i0[k] = sig(done + k); i1[k] = -sig(done + k); }
        const float *in[2] = { i0.data(), i1.data() };
        float *o[2] = { o0.data(), o1.data() };
        cs.process(in, o, B);
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
    size_t dp = 0;
    const double t0 = now_s();
    uint64_t done = 0;
    while (now_s() - t0 < secs) {
      const uint64_t due = (uint64_t)((now_s() - t0) * 48000 * (1 + drift));
      while (done + B <= due) {
        const float *zin[2] = { z.data(), z.data() };
        float *xo[2] = { x0.data(), x1.data() };
        cx.process(zin, xo, B);
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

  // every frame: exactly 0.5 x the input L frames before, or 0, or fading in towards it
  res.frames = out0.size();
  for (uint64_t i = L; i < out0.size(); ++i) {
    const float e[2] = { 0.5f * sig(i - L), -0.5f * sig(i - L) }, o[2] = { out0[i], out1[i] };
    int ex = 0, zr = 0, fd = 0;
    for (int c = 0; c < 2; ++c) {
      if (o[c] == e[c]) ex++;
      else if (o[c] == 0.f) zr++;
      else if (std::fabs(o[c]) < std::fabs(e[c]) && (o[c] > 0) == (e[c] > 0)) fd++;
    }
    if (ex == 2) { res.exact++; if (!res.first_wet) res.first_wet = i; }
    else if (zr == 2) res.zero++;
    else if (ex + zr + fd == 2) res.faded++;
    else res.wrong++;
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
  printf("%s: %llu frames, first wet at %.0f ms, after it exact %.2f%% zero %llu faded %llu wrong %llu\n  send %s\n  serve %s\n", what,
         (unsigned long long)r.frames, r.first_wet / 48.0, wet ? 100.0 * r.exact / wet : 0.0, (unsigned long long)r.zero,
         (unsigned long long)r.faded, (unsigned long long)r.wrong, r.sst.c_str(), r.rst.c_str());
}
static double exact_pct(const Result &r) { const uint64_t wet = r.frames > r.first_wet ? r.frames - r.first_wet : 0; return wet ? 100.0 * r.exact / wet : 0; }

int main()
{
#ifdef _WIN32
  timeBeginPeriod(1); // (REAPER runs with 1 ms timers; Windows' default 15.6 ms would bunch the test's blocks)
#endif
  {
    Result r = run(1, 2, 0, 0, 0, 3);
    report("clean", r);
    CHECK(r.first_wet > 0 && r.first_wet < 48000, "the hop comes up within a second");
    CHECK(r.wrong == 0, "nothing misaligned or wrong");
    CHECK(exact_pct(r) > 99.9, "every frame back, sample-exact, once up");
    CHECK(num(r.sst, "lost") == 0 && num(r.sst, "late") == 0, "nothing lost or late");
    CHECK(num(r.sst, "rtt_ms") >= 0 && num(r.sst, "remote_ms") > 0 && num(r.sst, "need_ms") < num(r.sst, "budget_ms"), "round trip measured, inside the budget");
    CHECK(num(r.rst, "slips") == 0, "no slip with the clocks together");
  }
  {
    Result r = run(11, 5, 8, 0.02, 0, 3);
    report("jitter 5-13 ms, 2% loss each way", r);
    CHECK(r.wrong == 0, "nothing misaligned or wrong under jitter and loss");
    CHECK(exact_pct(r) > 85, "most frames back exact");
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
  {
    Result r = run(41, 2, 0, 0, 0, 1.5, "not the studio's");
    report("wrong secret at the remote", r);
    CHECK(r.exact == 0 && r.wrong == 0, "nothing comes back: only silence");
    CHECK(num(r.sst, "returned") == 0 && num(r.rst, "received") == 0, "no audio crossed");
  }
  printf(fails ? "FAILED %d\n" : "ok: all hop network checks passed\n", fails);
  return fails ? 1 : 0;
}
