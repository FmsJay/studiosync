// StudioSync's live audio core (extension/rtaudio.cpp: AOO + Opus) without REAPER: three endpoints on 127.0.0.1, each with its own UDP
// port, driven by a test clock that plays the audio thread (48 kHz, 256-sample blocks, in real time). A sends a 440 Hz sine; B hears A
// through Opus and the jitter buffer: it has to arrive within a bounded latency and at the level it was sent. C has the wrong studio
// secret: B refuses every datagram from it and hears nothing of its 1 kHz tone. Then B mutes A (the cue mix) and A goes quiet there; then
// C is given the right secret (the peers JSON again, while running) and B hears its tone. The secret and ports go in as lib/liveaudio.lua's
// JSON does (StudioSync_LiveAudioPeers). Then C mutes what it sends (Mute me: silence, the stream kept) and unmutes, heard again at once; then
// C leaves B out of what it sends (talkback to someone else) and lets it back in. Then Wi-Fi's bursts (the adaptive buffer), then Play
// (the second stream, from a Hop's ring: heard apart from Talk), then the hub's live mix (a hub and three listeners: each listener's own levels
// through the hub, talkback through it, the extra hop's latency, the streams each listener sends, and the hub dropping: direct again), and
// the hub's load at 128 and 64-sample blocks (its own CPU time). Then the four-computer test's underruns: two clocks 200 and 100 ppm apart
// (AOO's drift correction), a buffer left far above its size (re-buffered in a quiet moment), a hub mix <-> direct switch (not jitter).
// Build and run: tests\build_rtaudio_test.cmd (macOS/Linux: the CI's line in .github/workflows/extension.yml). GPL-3.0-or-later.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>
#include "../extension/rtaudio.h"
#include "../plugin/hop_shm.h" // (Play: the test writes a Hop's send ring as the live out track's plug-in does)

static int fails = 0;
static void check(bool ok, const char *what) { printf("%s %s\n", ok ? "  ok  " : "  FAIL", what); if (!ok) ++fails; }
// SS_TIMING_STRICT=1 (default, not in CI): a check a stall of the test process itself spoiled still fails; 0: it's reported and passed over
// (the macOS CI runner stalls 15-250 ms several times a run: its callbacks then come all at once, before the packets they'd need have crossed).
static bool timing_strict() { const char *e = getenv("SS_TIMING_STRICT"); return e ? atoi(e) != 0 : !getenv("CI"); }
static void check_unless_stalled(bool ok, double stall_ms, const char *what)
{
  if (!ok && stall_ms > 15 && !timing_strict()) { printf("  (passed over: the test itself stalled %.0f ms) %s\n", stall_ms, what); return; }
  check(ok, what);
}
// This computer's 1 ms sleep (median of 21). rt_test_hold's holds end on the receive thread's 1 ms sleeps, so on coarse timers (over 2 ms:
// GitHub's hosted Mac's run 5-13 ms, Linux's and Windows' ~1 ms) each hold runs up to a tick long, a different length each time, and the
// test's own loop sees none of it. The checks that count what a hold of one exact length costs allow for that there, with SS_TIMING_STRICT
// off only (rt-ci3; tests/hopnet_test.cpp's coarse()).
static double tick_ms()
{
  static double t = -1;
  if (t < 0) {
    std::vector<double> v;
    for (int i = 0; i < 21; ++i) {
      const auto a = std::chrono::steady_clock::now();
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
      v.push_back(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - a).count());
    }
    std::sort(v.begin(), v.end());
    t = v[10];
  }
  return t;
}
static bool coarse() { return tick_ms() > 2 && !timing_strict(); }
static std::string field(const std::string &json, const std::string &peer, const char *key) // (a peer's value, or a top-level one with peer "")
{
  size_t at = 0;
  if (!peer.empty()) { at = json.find("\"" + peer + "\":{"); if (at == std::string::npos) return ""; }
  const size_t k = json.find(std::string("\"") + key + "\":", at);
  if (k == std::string::npos) return "";
  const size_t v = k + strlen(key) + 3, e = json.find_first_of(",}", v);
  return json.substr(v, e - v);
}

// The hub's load at a given block size (James, rt: the laptop's hub, ASIO at 128 samples, paused itself at 25-29% of a core where the desktop's
// 256-sample test measured 5%). A hub and three listeners, each sending a tone; the hub's load read once a second after it settles. busy: as
// many spinning threads as cores beside it (another program, or REAPER's own FX threads, taking the cores: the send thread gets preempted).
static double hub_load_at(int len, int port0, bool busy)
{
  const int SR = 48000;
  const double PI = 3.14159265358979;
  char nm[4][32];
  RtLink *L[4];
  for (int i = 0; i < 4; ++i) { snprintf(nm[i], sizeof nm[i], "127.0.0.1:%d", port0 + i); L[i] = rt_new(); }
  for (int i = 0; i < 4; ++i) {
    std::string list;
    for (int j = 0; j < 4; ++j) if (j != i) list += std::string(list.empty() ? "" : ", ") + "\"" + nm[j] + "\"";
    rt_peers(L[i], (std::string("{\"peers\":[") + list + "],\"port\":" + std::to_string(port0 + i) + ",\"secret\":\"studio\"}").c_str());
    rt_start(L[i], 0, 1, 128, 0, "127.0.0.1");
  }
  std::atomic<bool> spinning{ busy };
  std::vector<std::thread> spin;
  if (busy) for (unsigned i = 0; i < std::max(2u, std::thread::hardware_concurrency()); ++i) spin.emplace_back([&] { volatile double x = 1; while (spinning.load()) x = x * 1.0000001 + 1e-9; });
  const auto at = [&](double s) { return (int)(s * SR / len); };
  std::vector<double> in(len), out(len), out2(len);
  double sum = 0, mx = 0;
  int n = 0;
  long long k0 = 0;
  const auto t0 = std::chrono::steady_clock::now();
  for (int b = 0; b < at(6.0); ++b) {
    const auto due = t0 + std::chrono::nanoseconds((long long)(1e9 * b * len / SR));
    while (std::chrono::steady_clock::now() < due) std::this_thread::yield();
    if (b == at(0.5)) { rt_hub(L[0], "", 1); for (int i = 1; i < 4; ++i) rt_hub(L[i], nm[0], 0); }
    if (b > at(2.5) && b % at(1.0) == 0) {
      const double v = atof(field(rt_status(L[0]), "hub", "load").c_str());
      sum += v; mx = std::max(mx, v); ++n;
    }
    for (int i = 0; i < 4; ++i) {
      for (int k = 0; k < len; ++k) in[k] = 0.2 * sin(2 * PI * 300 * (i + 1) * (double)(k0 + k) / SR);
      const double *ii[1] = { in.data() };
      rt_capture(L[i], ii, 1, len, SR);
      double *oo[2] = { out.data(), out2.data() };
      rt_mix(L[i], oo, 2, len, SR);
    }
    k0 += len;
  }
  const std::string s = rt_status(L[0]);
  spinning.store(false);
  for (std::thread &t : spin) t.join();
  printf("     hub load, %d-sample blocks%s: %.1f%% of a core on average, %.1f%% at most (serving %s, skipped %s)\n", len, busy ? ", every core busy beside it" : "",
         n ? 100 * sum / n : -1.0, 100 * mx, field(s, "hub", "serving").c_str(), field(s, "hub", "skipped").c_str());
  for (int i = 0; i < 4; ++i) rt_free(L[i]);
  return mx;
}

// Desktop (Ryzen 7700X), three listeners: 3.8-4.5% of a core at 256, 128 and 64 (the block size isn't the cost: Opus's encode is, 96% of it).
// With every core busy beside it the clock read 13.4%, its own CPU time 10.5-11.5% (two threads to a core and a lower clock: real, but not
// the mix's doing). busy runs only with the "hubload" argument (rtaudio_test hubload: these alone), not on the CI's small runners.
static void hub_loads(bool busy)
{
  const double l128 = hub_load_at(128, 47421, false), l64 = hub_load_at(64, 47431, false);
  check(l128 > 0 && l128 < 0.25 && l64 > 0 && l64 < 0.25, "hub load: three listeners stay inside the 25% budget at 128 and 64-sample blocks");
  if (busy) check(hub_load_at(256, 47411, false) > 0 && hub_load_at(128, 47441, true) < 0.25, "hub load: at 256, and at 128 with every core busy beside it, inside the budget");
}

// ---- Drift (the four-computer test, 2026-11-20: every link underran ~3 times a minute in silence; the audio clocks ran -50 to a few hundred
// ppm against each computer's clock, and AOO's drift correction was off). T sends to R; each has its own audio clock (its blocks come at its
// own rate against the real clock: ppm_t, ppm_r). T plays a 5 ms burst every 0.5 s; its delay to R's output, in real time from each one's
// own clock, from 8 s to 16 s: its slope, ms a second. Without the correction the buffer takes up the clocks' difference (200 ppm: 0.2 ms a
// second, 12 ms a minute: a 30-100 ms buffer drained or filled in minutes, then an underrun or AOO's overrun); with it, flat. stalls: the
// test itself freezes 30-250 ms four times (both computers' callbacks late, then all at once), as the macOS CI runner does on its own: AOO's
// DLL took those in and swung the correction to -2.2 ms a second there; the clock is now measured from each stretch's earliest callback.
// under: R's underruns from 8 s; excused: those of them that came within 0.5 s of a stall of the test process itself over 15 ms (its
// callbacks then catch up all at once, before T's packets have crossed: the macOS CI runner's own stalls), apart from the ones it makes.
static double drift_slope(bool fix, double ppm_t, double ppm_r, int port0, long long &under, long long &excused, bool stalls = false, double *ratio = nullptr, double *lat = nullptr)
{
  const int SR = 48000, LEN = 256;
  const double PI = 3.14159265358979;
  char pt[32], pr[32];
  snprintf(pt, sizeof pt, "127.0.0.1:%d", port0); snprintf(pr, sizeof pr, "127.0.0.1:%d", port0 + 1);
  RtLink *T = rt_new(), *R = rt_new();
  rt_test_drift(T, fix ? 1 : 0); rt_test_drift(R, fix ? 1 : 0);
  rt_peers(T, (std::string("{\"peers\":[\"") + pr + "\"],\"port\":" + std::to_string(port0) + ",\"secret\":\"studio\"}").c_str());
  rt_peers(R, (std::string("{\"peers\":[\"") + pt + "\"],\"port\":" + std::to_string(port0 + 1) + ",\"secret\":\"studio\"}").c_str());
  rt_start(T, 0, 1, 128, 0, "127.0.0.1"); rt_start(R, 0, 1, 128, 0, "127.0.0.1");
  std::vector<double> in(LEN, 0.0), silent(LEN, 0.0), o1(LEN), o2(LEN);
  double *oo[2] = { o1.data(), o2.data() };
  const double per_t = (double)LEN / (SR * (1 + ppm_t * 1e-6)), per_r = (double)LEN / (SR * (1 + ppm_r * 1e-6));
  const long long EVERY = SR / 2, BURST = SR / 200;
  long long bt = 0, br = 0, u_last = -1, quiet_run = 0;
  double last_stall = -1e9;
  under = excused = 0;
  std::vector<double> sent, heard; // (real times: each burst's start at T, its onset in R's output)
  const double stall_at[4] = { 5.3, 9.1, 11.7, 14.2 }, stall_ms[4] = { 120, 30, 250, 60 };
  int next_stall = stalls ? 0 : 4;
  const auto t0 = std::chrono::steady_clock::now();
  for (;;) {
    const double dt = bt * per_t, dr = br * per_r, due = std::min(dt, dr);
    if (due > 16.0) break;
    while (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() < due) std::this_thread::yield();
    const double real = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    if (real - due > 0.015) last_stall = real;
    if (next_stall < 4 && due >= stall_at[next_stall]) std::this_thread::sleep_for(std::chrono::milliseconds((int)stall_ms[next_stall++]));
    if (dt <= dr) {
      for (int k = 0; k < LEN; ++k) {
        const long long i = bt * LEN + k, m = i % EVERY;
        in[k] = i >= SR && m < BURST ? 0.5 * sin(2 * PI * 3000 * (double)m / SR) : 0.0;
        if (i >= SR && m == 0) sent.push_back(i * per_t / LEN);
      }
      const double *ii[1] = { in.data() };
      rt_capture(T, ii, 1, LEN, SR);
      rt_mix(T, oo, 2, LEN, SR);
      ++bt;
    } else {
      const double *ii[1] = { silent.data() };
      std::fill(o1.begin(), o1.end(), 0.0);
      rt_capture(R, ii, 1, LEN, SR);
      rt_mix(R, oo, 2, LEN, SR);
      for (int k = 0; k < LEN; ++k) {
        if (std::fabs(o1[k]) > 0.15 && quiet_run > SR / 10) heard.push_back((br * LEN + k) * per_r / LEN);
        quiet_run = std::fabs(o1[k]) > 0.1 ? 0 : quiet_run + 1;
      }
      ++br;
      if (dr >= 8.0 && br % 8 == 0) { // (R's underruns, about every 40 ms: each one counted, or excused when it came right after a stall)
        const long long u = atoll(field(rt_status(R), pt, "underruns").c_str());
        if (u_last >= 0 && u > u_last) (real - last_stall < 0.5 ? excused : under) += u - u_last;
        u_last = u;
      }
    }
  }
  if (ratio) *ratio = atof(field(rt_status(R), pt, "ratio_ppm").c_str()); // (what R learned of T's rate against its own: rt-audio3)
  if (lat) lat[0] = atof(field(rt_status(R), pt, "latency_ms").c_str()); // (what R's status says the latency is; lat[1]: as heard, below)
  rt_free(T); rt_free(R);
  // each onset's delay after the burst sent last before it (a burst missed in the output is just left out); the slope: the median of the
  // slopes between onsets one after the other, so a re-buffer (a step in the delay: a stall longer than the buffer underruns here, as R's
  // callbacks catch up before T's packets have crossed) is one slope of many, not a trend
  std::vector<double> at_s, d_ms, sl;
  for (double h : heard) {
    double from = -1;
    for (double t : sent) if (t <= h) from = t;
    if (from < 8.0 || h - from > 0.4) continue;
    at_s.push_back(from); d_ms.push_back((h - from) * 1000);
    if (getenv("DRIFT_DEBUG")) printf("       %s %.1f s: delay %.2f ms\n", fix ? "on " : "off", from, d_ms.back());
  }
  for (size_t i = 1; i < at_s.size(); ++i) if (at_s[i] > at_s[i - 1]) sl.push_back((d_ms[i] - d_ms[i - 1]) / (at_s[i] - at_s[i - 1]));
  if (lat && !d_ms.empty()) { std::vector<double> d = d_ms; std::nth_element(d.begin(), d.begin() + d.size() / 2, d.end()); lat[1] = d[d.size() / 2]; }
  if (sl.size() < 6) return 1e9;
  std::nth_element(sl.begin(), sl.begin() + sl.size() / 2, sl.end());
  return sl[sl.size() / 2];
}
static void drift_tests()
{
  long long u_off = 0, u_on = 0, u_on2 = 0, x_off = 0, x_on = 0, x_on2 = 0;
  double r_on = 0, lat_on[2] = { -1, -1 };
  const double off = drift_slope(false, 100, -100, 47451, u_off, x_off), on = drift_slope(true, 100, -100, 47453, u_on, x_on, false, &r_on, lat_on);
  // (1e9: not measured, under 6 onsets heard from 8 s: the hosted Mac's own stalls on top of the four made ones lost the bursts (CI run
  // 44780868653). Tried again up to 3 times; a slope that was measured is always checked)
  double on2 = 1e9, r_on2 = 0;
  for (int i = 0; i < 3 && on2 >= 1e9; ++i) on2 = drift_slope(true, -50, 50, i ? 47555 + 2 * i : 47455, u_on2, x_on2, true, &r_on2);
  printf("     drift: T's delay to R moves %+.3f ms/s with T +100 ppm and R -100 ppm uncorrected (underruns %lld), %+.3f ms/s corrected (%lld; R learned %+.0f ppm, the real ratio +200); T -50, R +50 corrected, the test stalling 30-250 ms four times: %+.3f ms/s (%lld; R learned %+.0f ppm, the real ratio -100)\n",
         off, u_off, on, u_on, r_on, on2, u_on2, r_on2);
  check(off > 0.12 && off < 0.35, "drift: uncorrected, a sender 200 ppm fast fills the receiver's buffer ~0.2 ms a second (what the field's buffers did)");
  check(std::fabs(on) < 0.06, "drift: corrected, the buffer holds still (+100/-100)");
  check(std::fabs(r_on - 200) < 300, "drift: and the receiver learned the ratio from its buffer alone, no clock estimate (within 300 ppm of +200 by 16 s)");
  // (rt-r3: the tap's stamps said 127.6 ms where the status said 152-171: the status against what is heard, on one clock, with nothing moving)
  printf("     drift: T's burst is heard %.1f ms after it's played (8-16 s, the median); R's status says latency_ms %.1f\n", lat_on[1], lat_on[0]);
  check(lat_on[0] > 0 && std::fabs(lat_on[0] - lat_on[1]) < 12, "drift: the status's latency_ms is the delay heard, within 12 ms (a block of each end and the round trip's half)");
  // (rt-audio3: through the stalls the delay doesn't hold still any more, and shouldn't: a stall leaves the buffer off its size (a re-buffer, a
  // burst) and the read-rate control brings it back, at 0.5 % at most. What must hold is the rate: a stall isn't learnt as one. AOO's DLL
  // took them in and swung to -2200 ppm; the slope servo before this one kept still by leaving the level wherever a stall had put it)
  if (on2 >= 1e9 && !timing_strict()) printf("  (passed over: the stalling run heard too few bursts to measure in 3 tries; SS_TIMING_STRICT off) drift through stalls\n");
  else {
    check(std::fabs(r_on2 + 100) < 700, "drift: the test's stalls aren't learnt as a rate (the ratio stays within 700 ppm of -100)");
    check(on2 < 0.06 && on2 > -6.5, "drift: and after them the delay only comes back toward its size, at about 0.5 % a second at most (never away)");
  }
  if (x_on) printf("     drift: %lld underrun(s) of the corrected run came right after a stall of the test itself%s\n", x_on, timing_strict() ? "" : " (passed over: SS_TIMING_STRICT off)");
  check(u_on == 0 && (x_on == 0 || !timing_strict()), "drift: corrected, no underruns (but in a stall of this process, SS_TIMING_STRICT off)");
}

// ---- A buffer left far above its size (the four-computer test: the laptop's buffer for the Mac sat at 190 ms against 110, the Mac's for the
// desktop 195 against 120). A re-buffer that comes while packets are held up (Wi-Fi's stall) takes in the held ones when they burst in, and
// AOO plays from there for good. D sends to E; at 2 s E's receive thread is held 70 ms and E's buffer for D goes from 30 to 60 ms 43 ms
// into it (its floor and ceiling 60): E's buffer ends up ~45 ms over its size. D plays a tone until 6 s: once a stretch has shown the
// buffer above its size, what's over is shed (a "trim": a skip rt_mix crossfades, rt-p11; it was a re-buffer, a gap, so it waited for quiet),
// with no gap in what E hears, and it stays at its size once D is quiet. E's timings 4x faster here.
// Gaps: the smallest RMS over 10 ms windows of what's heard in [s0, s1) (a 0.5 tone's is 0.35; a re-buffer's silence or concealment ~0).
static double min_rms(const std::vector<double> &x, double s0, double s1, int sr = 48000)
{
  double lo = 1e9;
  const size_t w = (size_t)sr / 100;
  for (size_t i = (size_t)(s0 * sr); i + w <= (size_t)(s1 * sr) && i + w <= x.size(); i += w / 2) {
    double e = 0;
    for (size_t k = i; k < i + w; ++k) e += x[k] * x[k];
    lo = std::min(lo, sqrt(e / (double)w));
  }
  return lo;
}
static void trim_test()
{
  const int SR = 48000, LEN = 256, PD = 47457, PE = 47458;
  const double PI = 3.14159265358979;
  char pd[32], pe[32];
  snprintf(pd, sizeof pd, "127.0.0.1:%d", PD); snprintf(pe, sizeof pe, "127.0.0.1:%d", PE);
  RtLink *D = rt_new(), *E = rt_new();
  rt_peers(D, (std::string("{\"peers\":[\"") + pe + "\"],\"port\":" + std::to_string(PD) + ",\"secret\":\"studio\"}").c_str());
  rt_peers(E, (std::string("{\"peers\":[\"") + pd + "\"],\"port\":" + std::to_string(PE) + ",\"secret\":\"studio\"}").c_str());
  rt_start(D, 0, 1, 128, 0, "127.0.0.1"); rt_start(E, 0, 1, 128, 0, "127.0.0.1");
  rt_test_speed(E, 4);
  auto at = [&](double s) { return (int)(s * SR / LEN); };
  std::vector<double> id(LEN), ie(LEN, 0.0), o1(LEN), o2(LEN);
  const double *ind[1] = { id.data() }, *ine[1] = { ie.data() };
  double *oo[2] = { o1.data(), o2.data() };
  double hi = 0, lo_loud = 1e9, lo_after = 1e9, stalled = 0;
  long long trims_loud = -1, n = 0;
  std::vector<double> heard;
  const auto t0 = std::chrono::steady_clock::now();
  for (int b = 0; b < at(8.0); ++b) {
    const auto due = t0 + std::chrono::nanoseconds((long long)(1e9 * b * LEN / SR));
    while (std::chrono::steady_clock::now() < due) std::this_thread::yield();
    if (b > at(2.0)) stalled = std::max(stalled, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - due).count());
    for (int k = 0; k < LEN; ++k, ++n) id[k] = b < at(6.0) ? 0.5 * sin(2 * PI * 440 * n / SR) : 0.0;
    if (b == at(2.0)) rt_test_hold(E, 70);
    if (b == at(2.0) + 8) rt_peer_buffer(E, pd, 60, 60); // (43 ms into the stall: what was held up is taken in after the re-buffer)
    if (b >= at(2.6) && b < at(3.2) && b % 8 == 0) hi = std::max(hi, atof(field(rt_status(E), pd, "fill_ms").c_str()));
    if (b >= at(5.0) && b < at(6.0) && b % 8 == 0) { const double f = atof(field(rt_status(E), pd, "fill_ms").c_str()); if (f >= 0) lo_loud = std::min(lo_loud, f); }
    if (b == at(6.0)) trims_loud = atoll(field(rt_status(E), pd, "trims").c_str());
    if (b >= at(7.0) && b % 8 == 0) { const double f = atof(field(rt_status(E), pd, "fill_ms").c_str()); if (f >= 0) lo_after = std::min(lo_after, f); }
    std::fill(o1.begin(), o1.end(), 0.0);
    rt_capture(D, ind, 1, LEN, SR); rt_capture(E, ine, 1, LEN, SR);
    rt_mix(D, oo, 2, LEN, SR);
    std::fill(o1.begin(), o1.end(), 0.0);
    rt_mix(E, oo, 2, LEN, SR);
    heard.insert(heard.end(), o1.begin(), o1.end());
  }
  const std::string end = rt_status(E);
  const double gap = min_rms(heard, 2.4, 5.95);
  printf("     trim: E's buffer for D (size %s ms) at up to %.0f ms after the stall, %.0f ms at its lowest from 5 s while D still played (trims %lld), %.0f ms after D went quiet (trims %s); quietest 10 ms heard 2.4-5.95 s: RMS %.3f\n",
         field(end, pd, "target_ms").c_str(), hi, lo_loud < 1e9 ? lo_loud : -1.0, trims_loud, lo_after < 1e9 ? lo_after : -1.0, field(end, pd, "trims").c_str(), gap);
  check(hi > 60 + 25, "trim: a re-buffer during a stall leaves E's buffer far above its size");
  check_unless_stalled(trims_loud >= 1 && lo_loud < 60 + 15, stalled, "trim: what's above its size is shed while D plays (it was held until quiet)");
  check_unless_stalled(gap > 0.1, stalled, "trim: the shed is crossfaded: no gap in what E hears (a re-buffer was one)");
  check_unless_stalled(lo_after < 60 + 15 && lo_after > 20, stalled, "trim: D quiet, E's buffer stays at its size");
  rt_free(D); rt_free(E);
}

// ---- Play's resync (rt-ears Findings 1, rt-p11): the laptop heard the desktop's Play ~100 ms later than live audio said, then mid-tone ~130
// ms of silence, garbage and a fade-in, and no counter moved. A buffer that finished buffering above its size has little room left in AOO's
// default capacity (twice its size), so the next burst overruns it: AOO resets the stream. P sends a 0.5 tone as Play (hop 62's ring) to Q.
// At 2 s Q's receive thread is held 70 ms and its buffer set to 60 ms 43 ms in (as trim_test: ~45 ms over); at 3 s Q's audio callbacks are
// held up 43 ms (packets pile in on top: no longer fits 120 ms). Now: no overrun, no gap, the excess shed, and Play's own counters say so. Then the ears tap: Q
// records what it hears of P's Play and P its own Play as it goes out, 1 s each, and both WAVs hold the tone.
static bool read_wav_f32(const std::string &path, int &sr, std::vector<float> &lr)
{
  FILE *f = fopen(path.c_str(), "rb");
  if (!f) return false;
  unsigned char h[44];
  const bool ok = fread(h, 1, 44, f) == 44 && !memcmp(h, "RIFF", 4) && !memcmp(h + 8, "WAVEfmt ", 8) && h[20] == 3 && h[22] == 2 && h[34] == 32 && !memcmp(h + 36, "data", 4);
  if (ok) {
    sr = h[24] | h[25] << 8 | h[26] << 16 | h[27] << 24;
    const unsigned n = (unsigned)(h[40] | h[41] << 8 | h[42] << 16 | (unsigned)h[43] << 24) / 4;
    lr.resize(n);
    lr.resize(fread(lr.data(), 4, n, f));
  }
  fclose(f);
  return ok;
}
static void play_resync_test()
{
  const int SR = 48000, LEN = 256, PP = 47621, PQ = 47622, HOP = 62;
  const double PI = 3.14159265358979;
  char pp[32], pq[32];
  snprintf(pp, sizeof pp, "127.0.0.1:%d", PP); snprintf(pq, sizeof pq, "127.0.0.1:%d", PQ);
  RtLink *P = rt_new(), *Q = rt_new();
  rt_peers(P, (std::string("{\"peers\":[\"") + pq + "\"],\"port\":" + std::to_string(PP) + ",\"secret\":\"studio\"}").c_str());
  rt_peers(Q, (std::string("{\"peers\":[\"") + pp + "\"],\"port\":" + std::to_string(PQ) + ",\"secret\":\"studio\"}").c_str());
  rt_start(P, 0, 1, 128, 0, "127.0.0.1"); rt_start(Q, 0, 1, 128, 0, "127.0.0.1");
  rt_test_speed(Q, 4);
  hop_map hm;
  hop_shm *ring = hop_shm_open(&hm, hop_reaper_pid(), HOP);
  check(ring != nullptr, "play resync: the test's own Hop mapping");
  auto at = [&](double s) { return (int)(s * SR / LEN); };
  std::vector<double> silent(LEN, 0.0), o1(LEN), o2(LEN), heard;
  std::vector<float> inter((size_t)LEN * 2);
  const double *in0[1] = { silent.data() };
  double *oo[2] = { o1.data(), o2.data() };
  char tmp[512];
  const char *td = getenv("TEMP") ? getenv("TEMP") : getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp";
  snprintf(tmp, sizeof tmp, "%s/ss_rt_ears_%d", td, (int)hop_reaper_pid());
  const std::string heard_wav = std::string(tmp) + "_heard.wav", sent_wav = std::string(tmp) + "_sent.wav";
  double stalled = 0, hi = 0, lo_late = 1e9;
  int ears_q = -1, ears_p = -1, ears_bad = 0, ears_busy = -1, held = 0;
  std::string mid;
  long long n = 0;
  const auto t0 = std::chrono::steady_clock::now();
  for (int b = 0; b < at(8.5); ++b) {
    const auto due = t0 + std::chrono::nanoseconds((long long)(1e9 * b * LEN / SR));
    while (std::chrono::steady_clock::now() < due) std::this_thread::yield();
    if (b > at(2.0)) stalled = std::max(stalled, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - due).count());
    for (int k = 0; k < LEN; ++k, ++n) inter[2 * k] = inter[2 * k + 1] = (float)(0.5 * sin(2 * PI * 440 * n / SR));
    if (b == at(0.3)) rt_play(P, HOP, 1);
    if (b == at(2.0)) rt_test_hold(Q, 70);
    if (b == at(2.0) + 8) rt_peer_buffer(Q, pp, 60, 60);
    if (b >= at(2.6) && b < at(3.0) && b % 8 == 0) hi = std::max(hi, atof(field(rt_status(Q), pp, "play_buffer_ms").c_str()));
    if (b >= at(6.0) && b < at(7.0) && b % 8 == 0) { const double f = atof(field(rt_status(Q), pp, "play_buffer_ms").c_str()); if (f >= 0) lo_late = std::min(lo_late, f); }
    if (b == at(6.5)) mid = rt_status(Q);
    if (b == at(7.0)) {
      ears_bad = rt_ears(Q, pp, "play", (std::string(tmp) + ".txt").c_str(), 1.0) + rt_ears(Q, "127.0.0.1:1", "play", heard_wav.c_str(), 1.0) +
                 rt_ears(Q, pp, "play", heard_wav.c_str(), 61.0) + rt_ears(Q, pp, "loud", heard_wav.c_str(), 1.0) + rt_ears(Q, "", "talk", heard_wav.c_str(), 1.0) +
                 rt_ears(Q, pp, "play", (std::string(tmp) + "/../x.wav").c_str(), 1.0);
      ears_q = rt_ears(Q, pp, "play", heard_wav.c_str(), 1.0);
      ears_busy = rt_ears(Q, pp, "talk", sent_wav.c_str(), 1.0);
      ears_p = rt_ears(P, "", "play", sent_wav.c_str(), 1.0);
    }
    rt_capture(P, in0, 1, LEN, SR);
    if (ring) { const uint64_t w = hop_load(&ring->send_w); hop_copy_in(ring->send, w, inter.data(), LEN); hop_store(&ring->send_w, w + LEN); }
    std::fill(o1.begin(), o1.end(), 0.0);
    rt_mix(P, oo, 2, LEN, SR);
    // (3 s: Q's audio callbacks held up 43 ms, then all at once, as a busy system's or a VM's: what arrived meanwhile sits on top of a buffer
    // already ~45 ms over its size, past AOO's default room of twice its size)
    if (b >= at(3.0) && b < at(3.0) + 8) { ++held; continue; }
    for (; held >= 0; --held) {
      rt_capture(Q, in0, 1, LEN, SR);
      std::fill(o1.begin(), o1.end(), 0.0);
      rt_mix(Q, oo, 2, LEN, SR);
      heard.insert(heard.end(), o1.begin(), o1.end());
    }
    held = 0;
  }
  const std::string endq = rt_status(Q), endp = rt_status(P);
  const double gap = min_rms(heard, 2.4, 8.4);
  printf("     play resync: Q's Play buffer %.0f ms after the stall (size 60), %.0f ms at its lowest 6-7 s; overruns %s, resyncs %s, trims %s; quietest 10 ms heard 2.4-8.4 s: RMS %.3f\n",
         hi, lo_late < 1e9 ? lo_late : -1.0, field(endq, pp, "play_overruns").c_str(), field(endq, pp, "play_resyncs").c_str(), field(endq, pp, "play_trims").c_str(), gap);
  check(hi > 60 + 25, "play resync: the stall leaves Q's Play buffer far above its size (play_buffer_ms)");
  check_unless_stalled(gap > 0.1, stalled, "play resync: no gap in what Q hears (the burst overran AOO's buffer: a re-buffer mid-tone)");
  check_unless_stalled(field(endq, pp, "play_overruns") == "0" && field(endq, pp, "play_resyncs") == "0" && field(endq, pp, "overruns") == "0", stalled,
                       "play resync: no overrun of Play or Talk, no Play re-buffer (and the counters are there)");
  check_unless_stalled(atoll(field(endq, pp, "play_trims").c_str()) >= 1 && lo_late < 60 + 15, stalled, "play resync: Play's excess shed (play_trims), its buffer back at its size");
  const double plat = atof(field(mid, pp, "play_latency_ms").c_str());
  check(plat > 0 && plat < 60 + 40, "play resync: play_latency_ms, from Play's own buffer");
  check(ears_bad == 0, "ears: a path not .wav or with .., a peer not in the list, over 60 s, an unknown stream, own Talk: refused");
  check(ears_q == 1 && ears_busy == 0 && ears_p == 1, "ears: Q taps P's Play, a second tap at once is refused, P taps its own Play");
  for (int i = 0; i < 300 && (field(rt_status(Q), "", "state") == "\"writing\"" || field(rt_status(P), "", "state") == "\"writing\""); ++i) std::this_thread::sleep_for(std::chrono::milliseconds(10));
  const std::string eq = rt_status(Q), ep = rt_status(P);
  int srq = 0, srp = 0;
  std::vector<float> wq, wp;
  const bool okq = read_wav_f32(heard_wav, srq, wq), okp = read_wav_f32(sent_wav, srp, wp);
  double rq = 0, err = 0;
  for (size_t i = 0; i < wq.size(); ++i) rq += (double)wq[i] * wq[i];
  rq = wq.empty() ? 0 : sqrt(rq / wq.size());
  // (P's own Play is the ring's tone sample for sample: its amplitude and phase fitted over the whole second, then every sample compared)
  if (wp.size() >= 4) {
    const size_t nf = wp.size() / 2;
    double a = 0, c = 0;
    for (size_t i = 0; i < nf; ++i) { a += wp[2 * i] * sin(2 * PI * 440 * (double)i / SR); c += wp[2 * i] * cos(2 * PI * 440 * (double)i / SR); }
    const double amp = 2 * sqrt(a * a + c * c) / nf, ph = atan2(c, a);
    for (size_t i = 0; i < nf; ++i) err = std::max(err, std::fabs(wp[2 * i] - amp * sin(2 * PI * 440 * (double)i / SR + ph)));
    if (std::fabs(amp - 0.5) > 0.01) err = std::max(err, std::fabs(amp - 0.5));
  }
  printf("     ears: Q %s (%d Hz, %zu frames, RMS %.3f); P %s (%d Hz, %zu frames, largest error against the tone %.4f); Q's status %s\n", okq ? "read" : "unread", srq, wq.size() / 2, rq,
         okp ? "read" : "unread", srp, wp.size() / 2, err, eq.find("\"ears\"") == std::string::npos ? "(no ears)" : eq.substr(eq.find("\"ears\""), 120).c_str());
  check(okq && srq == SR && wq.size() == (size_t)SR * 2 && rq > 0.3 && rq < 0.42, "ears: Q's WAV holds 1 s of P's Play as heard (the tone's level)");
  check(okp && srp == SR && wp.size() == (size_t)SR * 2 && err < 0.01, "ears: P's WAV is its own Play as it went out, sample for sample");
  check(field(eq, "", "state") == "\"done\"" && atof(field(eq, "", "first_age_s").c_str()) > 0.9 && field(eq, "", "lost") == "0", "ears: Q's status: done, the first frame's age, nothing lost");
  remove(heard_wav.c_str()); remove(sent_wav.c_str());
  if (ring) { hop_shm_close(&hm); hop_shm_unlink(&hm); }
  rt_free(P); rt_free(Q);
}

// ---- A switch between the hub's mix and direct streams isn't network jitter (the four-computer test: the Mac's buffers grew with its rescues).
// H mixes for W and X; at 3 s H's mixing stalls 250 ms (its send thread held up): X and W fall back to direct streams and the mix underruns
// when it comes back, but the buffers stay at 30 ms ("switched", not "jitter"). Then H's mixing turned off and on and the same peers given
// again: no pause of the audio thread (each was a block not sent or heard).
static void switch_test()
{
  const int SR = 48000, LEN = 256, P0 = 47461;
  const double PI = 3.14159265358979;
  char nm[3][32];
  RtLink *L[3];
  std::string js[3];
  for (int i = 0; i < 3; ++i) { snprintf(nm[i], sizeof nm[i], "127.0.0.1:%d", P0 + i); L[i] = rt_new(); }
  for (int i = 0; i < 3; ++i) {
    std::string list;
    for (int j = 0; j < 3; ++j) if (j != i) list += std::string(list.empty() ? "" : ", ") + "\"" + nm[j] + "\"";
    js[i] = "{\"peers\":[" + list + "],\"port\":" + std::to_string(P0 + i) + ",\"secret\":\"studio\"}";
    rt_peers(L[i], js[i].c_str());
    rt_start(L[i], 0, 1, 128, 0, "127.0.0.1");
  }
  auto at = [&](double s) { return (int)(s * SR / LEN); };
  std::vector<double> in(LEN), o1(LEN), o2(LEN);
  double *oo[2] = { o1.data(), o2.data() };
  std::string before, after;
  long long p0 = -1, p1 = -1, n = 0;
  double stalled = 0; // (the test's own longest stall: on a loaded runner its callbacks come all at once, as rescue_test's)
  const auto t0 = std::chrono::steady_clock::now();
  for (int b = 0; b < at(9.5); ++b) {
    const auto due = t0 + std::chrono::nanoseconds((long long)(1e9 * b * LEN / SR));
    while (std::chrono::steady_clock::now() < due) std::this_thread::yield();
    stalled = std::max(stalled, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - due).count());
    if (b == at(0.5)) { rt_hub(L[0], "", 1); rt_hub(L[1], nm[0], 0); rt_hub(L[2], nm[0], 0); }
    if (b == at(2.9)) before = rt_status(L[2]);
    if (b == at(3.0)) rt_test_hold_mix(L[0], 250);
    if (b == at(7.5)) { after = rt_status(L[2]); p0 = atoll(field(rt_status(L[0]), "", "pauses").c_str()); rt_hub(L[0], "", 0); }
    if (b == at(8.0)) { rt_hub(L[0], "", 1); rt_peers(L[0], js[0].c_str()); }
    if (b == at(9.4)) p1 = atoll(field(rt_status(L[0]), "", "pauses").c_str());
    for (int i = 0; i < 3; ++i) {
      for (int k = 0; k < LEN; ++k) in[k] = 0.3 * sin(2 * PI * 500 * (i + 1) * (double)(n + k) / SR);
      const double *ii[1] = { in.data() };
      rt_capture(L[i], ii, 1, LEN, SR);
      rt_mix(L[i], oo, 2, LEN, SR);
    }
    n += LEN;
  }
  printf("     switch: X before the stall: hub %s; after: hub %s, fallbacks %s, rescues %s; X's buffer for H %s ms (switched %s, jitter %s), for W %s ms (switched %s, jitter %s); H's pauses %lld -> %lld\n",
         field(before, "hub", "state").c_str(), field(after, "hub", "state").c_str(), field(after, "hub", "fallbacks").c_str(), field(after, "hub", "rescues").c_str(),
         field(after, nm[0], "target_ms").c_str(), field(after, nm[0], "switched").c_str(), field(after, nm[0], "jitter").c_str(),
         field(after, nm[1], "target_ms").c_str(), field(after, nm[1], "switched").c_str(), field(after, nm[1], "jitter").c_str(), p0, p1);
  check_unless_stalled(field(before, "hub", "state") == "\"hub\"", stalled, "switch: X hears through H before the stall");
  check(atoll(field(after, "hub", "fallbacks").c_str()) + atoll(field(after, "hub", "rescues").c_str()) >= 1, "switch: H's stall sent X to direct streams");
  check_unless_stalled(atoll(field(after, nm[0], "switched").c_str()) + atoll(field(after, nm[1], "switched").c_str()) >= 1, stalled, "switch: the underruns it brought were counted as the switch's");
  check_unless_stalled(field(after, nm[0], "target_ms") == "30" && field(after, nm[1], "target_ms") == "30" && field(after, nm[0], "jitter") == "0", stalled,
        "switch: X's buffers didn't grow for it (not network jitter)");
  check(p0 >= 0 && p1 == p0, "switch: H's mixing off and on, and the same peers again: no pause of the audio thread");
  for (int i = 0; i < 3; ++i) rt_free(L[i]);
}

// ---- A listener whose link stalls ~110 ms every second or so (the Mac through the desktop's mix, 2026-11-20: 40 rescues a minute with the hub
// steady). X's buffer for H is 100 ms (floor and ceiling), so a 110 ms stall comes near its end: the first one asks everyone's streams back,
// and from then on the widest spacing lately covers them (they were left out of it: every stall was a rescue).
static void rescue_test()
{
  const int SR = 48000, LEN = 256, P0 = 47471;
  char nm[3][32];
  RtLink *L[3];
  for (int i = 0; i < 3; ++i) { snprintf(nm[i], sizeof nm[i], "127.0.0.1:%d", P0 + i); L[i] = rt_new(); }
  for (int i = 0; i < 3; ++i) {
    std::string list;
    for (int j = 0; j < 3; ++j) if (j != i) list += std::string(list.empty() ? "" : ", ") + "\"" + nm[j] + "\"";
    rt_peers(L[i], ("{\"peers\":[" + list + "],\"port\":" + std::to_string(P0 + i) + ",\"secret\":\"studio\"}").c_str());
    rt_start(L[i], 0, 1, 128, 0, "127.0.0.1");
  }
  auto at = [&](double s) { return (int)(s * SR / LEN); };
  std::vector<double> in(LEN, 0.0), o1(LEN), o2(LEN);
  const double *ii[1] = { in.data() };
  double *oo[2] = { o1.data(), o2.data() };
  std::string before, after;
  int holds = 0;
  double stalled = 0; // (the test's own longest stall: a runner's 300 ms one is a gap the hub's mix falls back on)
  const auto t0 = std::chrono::steady_clock::now();
  for (int b = 0; b < at(9.0); ++b) {
    const auto due = t0 + std::chrono::nanoseconds((long long)(1e9 * b * LEN / SR));
    while (std::chrono::steady_clock::now() < due) std::this_thread::yield();
    stalled = std::max(stalled, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - due).count());
    if (b == at(0.3)) rt_peer_buffer(L[2], nm[0], 100, 100);
    if (b == at(0.5)) { rt_hub(L[0], "", 1); rt_hub(L[1], nm[0], 0); rt_hub(L[2], nm[0], 0); }
    if (b == at(2.9)) before = rt_status(L[2]);
    if (b >= at(3.0) && b < at(8.5) && (b - at(3.0)) % at(1.1) == 0) { rt_test_hold(L[2], 110); ++holds; }
    if (b == at(8.9)) after = rt_status(L[2]);
    for (int i = 0; i < 3; ++i) { rt_capture(L[i], ii, 1, LEN, SR); rt_mix(L[i], oo, 2, LEN, SR); }
  }
  const long long r0 = atoll(field(before, "hub", "rescues").c_str()), r1 = atoll(field(after, "hub", "rescues").c_str());
  printf("     rescue: X's link stalled 110 ms %d times: rescues %lld -> %lld, fallbacks %s, widest spacing %s ms, X hears through H: %s\n", holds, r0, r1,
         field(after, "hub", "fallbacks").c_str(), field(after, "hub", "mix_gap_ms").c_str(), field(after, "hub", "state").c_str());
  // (coarse timers: a hold that ran to 120 ms or more is past the mix's 100 ms buffer + GONE_PAD: the hub rightly counts as gone and X goes
  // direct. The hosted Mac's widest was 119.2 ms; with the hold's sleep made 13 ms here, 4 of 6 runs went over. A longer stall than this test
  // means, so it's passed over as the test's own)
  const double widest = atof(field(after, "hub", "mix_gap_ms").c_str());
  check_unless_stalled(field(before, "hub", "state") == "\"hub\"" && field(after, "hub", "state") == "\"hub\"", std::max(stalled, coarse() && widest >= 120 ? widest : 0.0),
                       "rescue: X hears through H throughout");
  // (coarse timers: a hold over 5 ms (RESCUE_PAD) longer than every one before it is a new widest spacing, and one more rescue: 2 of 6 on the
  // hosted Mac in three runs, and here with only the hold's sleep made 7 or 13 ms. Held to half of them; every one was the fault)
  if (coarse()) printf("     rescue: coarse timers (a 1 ms sleep here: %.1f ms): up to %d of the %d stalls may ask\n", tick_ms(), holds / 2, holds);
  check_unless_stalled(r1 - r0 <= (coarse() ? holds / 2 : 1), stalled, "rescue: only the first stall asks everyone's streams back (it was every one)");
  for (int i = 0; i < 3; ++i) rt_free(L[i]);
}

// ---- A listener on a VM whose guest is descheduled now and then (LinuxBox, 2026-11-21: 24 fallbacks against 7 rescues, 29 send queue
// overflows; rt-hubsmall): its receive and send threads stop together, the mix waits in the socket, and when the send thread woke first it
// read the mix's age before the receive thread had taken it and fell back though nothing was lost (3.3 s on everyone's own streams). H mixes
// for W, X and Y, each with a 30 ms buffer for it (gone at 50 ms). X's two threads are held five times, the send thread 150 ms and the
// receive thread 10 ms longer (it wakes second: the case that fell back): no fallback, no rescue, 5 stalls. Then a real outage, H's mixing
// stopped 400 ms: W, not held, falls back as before (a rescue first); X, held once more inside it, falls back soon after it wakes; and Y,
// whose send thread is held 30 ms every 35 ms through it (late on every pass), falls back too (a late pass waits once per silence).
static void stall_test()
{
  const int SR = 48000, LEN = 256, P0 = 47511;
  char nm[4][32];
  RtLink *L[4];
  for (int i = 0; i < 4; ++i) { snprintf(nm[i], sizeof nm[i], "127.0.0.1:%d", P0 + i); L[i] = rt_new(); }
  for (int i = 0; i < 4; ++i) {
    std::string list;
    for (int j = 0; j < 4; ++j) if (j != i) list += std::string(list.empty() ? "" : ", ") + "\"" + nm[j] + "\"";
    rt_peers(L[i], ("{\"peers\":[" + list + "],\"port\":" + std::to_string(P0 + i) + ",\"secret\":\"studio\"}").c_str());
    rt_start(L[i], 0, 1, 128, 0, "127.0.0.1");
  }
  auto at = [&](double s) { return (int)(s * SR / LEN); };
  std::vector<double> in(LEN, 0.0), o1(LEN), o2(LEN);
  const double *ii[1] = { in.data() };
  double *oo[2] = { o1.data(), o2.data() };
  std::string before, after, out_x, end_x, after_w, end_w, after_y, out_y, end_y;
  int holds = 0, late = 0;
  double stalled = 0, next_late = 0;
  const auto t0 = std::chrono::steady_clock::now();
  for (int b = 0; b < at(9.0); ++b) {
    const auto due = t0 + std::chrono::nanoseconds((long long)(1e9 * b * LEN / SR));
    while (std::chrono::steady_clock::now() < due) std::this_thread::yield();
    const double now = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    stalled = std::max(stalled, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - due).count());
    if (b == at(0.3)) for (int i = 1; i < 4; ++i) rt_peer_buffer(L[i], nm[0], 30, 30);
    if (b == at(0.5)) { rt_hub(L[0], "", 1); for (int i = 1; i < 4; ++i) rt_hub(L[i], nm[0], 0); }
    if (b == at(2.9)) before = rt_status(L[2]);
    if (b >= at(3.0) && b < at(7.5) && (b - at(3.0)) % at(1.0) == 0) { rt_test_hold(L[2], 160); rt_test_hold_tx(L[2], 150); ++holds; }
    if (b == at(7.9)) { after = rt_status(L[2]); after_w = rt_status(L[1]); after_y = rt_status(L[3]); }
    if (b == at(8.0)) { rt_test_hold_mix(L[0], 400); rt_test_hold(L[2], 160); rt_test_hold_tx(L[2], 150); next_late = now; }
    if (b >= at(8.0) && b < at(8.4) && now >= next_late) { rt_test_hold_tx(L[3], 30); next_late = now + 0.035; ++late; }
    if (b == at(8.3)) { out_x = rt_status(L[2]); out_y = rt_status(L[3]); }
    if (b == at(8.9)) { end_x = rt_status(L[2]); end_w = rt_status(L[1]); end_y = rt_status(L[3]); }
    for (int i = 0; i < 4; ++i) { rt_capture(L[i], ii, 1, LEN, SR); rt_mix(L[i], oo, 2, LEN, SR); }
  }
  auto n = [&](const std::string &s, const char *k) { return atoll(field(s, "hub", k).c_str()); };
  printf("     stalls: X's threads held 150 ms %d times: stalls %lld -> %lld (longest %s ms), fallbacks %lld -> %lld, rescues %lld -> %lld, X hears through H: %s -> %s\n",
         holds, n(before, "stalls"), n(after, "stalls"), field(after, "hub", "stall_max_ms").c_str(), n(before, "fallbacks"), n(after, "fallbacks"),
         n(before, "rescues"), n(after, "rescues"), field(before, "hub", "state").c_str(), field(after, "hub", "state").c_str());
  printf("     stalls: H's mix stopped 400 ms: X (held 150 ms in it) %s at 0.3 s, fallbacks +%lld; Y (send thread held 30 ms %d times) %s at 0.3 s, fallbacks +%lld, stalls +%lld; W fallbacks +%lld, rescues +%lld\n",
         field(out_x, "hub", "state").c_str(), n(end_x, "fallbacks") - n(after, "fallbacks"), late, field(out_y, "hub", "state").c_str(), n(end_y, "fallbacks") - n(after_y, "fallbacks"),
         n(end_y, "stalls") - n(after_y, "stalls"), n(end_w, "fallbacks") - n(after_w, "fallbacks"), n(end_w, "rescues") - n(after_w, "rescues"));
  check(n(after, "stalls") - n(before, "stalls") >= holds && atof(field(after, "hub", "stall_max_ms").c_str()) >= 140, "stalls: each hold of X's send thread is counted, the longest about 150 ms");
  check_unless_stalled(n(after, "stalls") - n(before, "stalls") == holds, stalled, "stalls: and nothing else here was a stall");
  check_unless_stalled(field(before, "hub", "state") == "\"hub\"" && field(after, "hub", "state") == "\"hub\"" && n(after, "fallbacks") == n(before, "fallbacks") && n(after, "rescues") == n(before, "rescues"),
                       stalled, "stalls: X's own threads held 150 ms is neither a fallback nor a rescue (it fell back on each one it heard the hub in)");
  // (rt-p9: the receive thread learnt each hold as the mix's widest spacing, 150 ms, for up to 60 s: the rescue line went past `gone` and a
  // real hub drop then fell back with no rescue first. The part the send thread's late pass covers is left out now)
  printf("     stalls: X's widest spacing of the mix after the holds: %s ms (W's, not held: %s ms)\n", field(after, "hub", "mix_gap_ms").c_str(), field(after_w, "hub", "mix_gap_ms").c_str());
  check_unless_stalled(atof(field(after, "hub", "mix_gap_ms").c_str()) < 60, stalled, "stalls: X's own stalls aren't learnt as the mix's spacing (it was ~150 ms)");
  check_unless_stalled(field(out_x, "hub", "state") == "\"direct\"" && n(end_x, "fallbacks") - n(after, "fallbacks") == 1, stalled,
                       "stalls: the hub's mix stopping while X is held still sends X to everyone's own streams, within 150 ms of waking");
  check_unless_stalled(field(out_y, "hub", "state") == "\"direct\"" && n(end_y, "fallbacks") - n(after_y, "fallbacks") == 1 && n(end_y, "stalls") - n(after_y, "stalls") >= 3, stalled,
                       "stalls: a send thread late on every pass still falls back on a mix that stopped (a late pass waits once per silence)");
  check_unless_stalled(n(end_w, "fallbacks") - n(after_w, "fallbacks") == 1 && n(end_w, "rescues") - n(after_w, "rescues") == 1, stalled,
                       "stalls: W, not held, rescues and falls back on it as before");
  for (int i = 0; i < 4; ++i) rt_free(L[i]);
}

// ---- A listener's own outage (its Wi-Fi, rt-p9; rt-hubsmall's "not recommended yet", backlog 1.20): nothing arrives at X for 300 ms, from the
// hub or anyone. Falling back then was no use (no direct stream comes either) and cost RETRY_S + ENTER_S of everyone's own streams after it.
// H mixes for W, X and Y (30 ms buffers, gone at 50 ms); W and Y say their mode to X every MODE_EVERY. X stays on the mix through it. Then
// H's mix really stops (600 ms): X and W fall back within about MODE_EVERY. And a room of two (H and Z only, nobody else to hear): Z's own
// outage falls back as before (nothing tells the two apart there).
static void outage_test()
{
  const int SR = 48000, LEN = 256, P0 = 47521;
  char nm[4][32];
  RtLink *L[4];
  for (int i = 0; i < 4; ++i) { snprintf(nm[i], sizeof nm[i], "127.0.0.1:%d", P0 + i); L[i] = rt_new(); }
  for (int i = 0; i < 4; ++i) {
    std::string list;
    for (int j = 0; j < 4; ++j) if (j != i) list += std::string(list.empty() ? "" : ", ") + "\"" + nm[j] + "\"";
    rt_peers(L[i], ("{\"peers\":[" + list + "],\"port\":" + std::to_string(P0 + i) + ",\"secret\":\"studio\"}").c_str());
    rt_start(L[i], 0, 1, 128, 0, "127.0.0.1");
  }
  char zn[2][32];
  RtLink *Z[2];
  for (int i = 0; i < 2; ++i) { snprintf(zn[i], sizeof zn[i], "127.0.0.1:%d", P0 + 5 + i); Z[i] = rt_new(); }
  for (int i = 0; i < 2; ++i) {
    rt_peers(Z[i], ("{\"peers\":[\"" + std::string(zn[1 - i]) + "\"],\"port\":" + std::to_string(P0 + 5 + i) + ",\"secret\":\"studio\"}").c_str());
    rt_start(Z[i], 0, 1, 128, 0, "127.0.0.1");
  }
  auto at = [&](double s) { return (int)(s * SR / LEN); };
  std::vector<double> in(LEN, 0.0), o1(LEN), o2(LEN);
  const double *ii[1] = { in.data() };
  double *oo[2] = { o1.data(), o2.data() };
  std::string before, mid, after, before_w, out_x, out_w, end_x, end_w, zb, ze;
  double stalled = 0;
  const auto t0 = std::chrono::steady_clock::now();
  for (int b = 0; b < at(6.0); ++b) {
    const auto due = t0 + std::chrono::nanoseconds((long long)(1e9 * b * LEN / SR));
    while (std::chrono::steady_clock::now() < due) std::this_thread::yield();
    stalled = std::max(stalled, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - due).count());
    if (b == at(0.3)) { for (int i = 1; i < 4; ++i) rt_peer_buffer(L[i], nm[0], 30, 30); rt_peer_buffer(Z[1], zn[0], 30, 30); }
    if (b == at(0.5)) { rt_hub(L[0], "", 1); for (int i = 1; i < 4; ++i) rt_hub(L[i], nm[0], 0); rt_hub(Z[0], "", 1); rt_hub(Z[1], zn[0], 0); }
    if (b == at(2.9)) { before = rt_status(L[2]); zb = rt_status(Z[1]); }
    if (b == at(3.0)) { rt_test_drop(L[2], 300); rt_test_drop(Z[1], 300); }
    if (b == at(3.2)) mid = rt_status(L[2]);
    if (b == at(3.9)) { after = rt_status(L[2]); before_w = rt_status(L[1]); ze = rt_status(Z[1]); }
    if (b == at(4.0)) rt_test_hold_mix(L[0], 600);
    if (b == at(4.4)) { out_x = rt_status(L[2]); out_w = rt_status(L[1]); }
    if (b == at(5.9)) { end_x = rt_status(L[2]); end_w = rt_status(L[1]); }
    for (int i = 0; i < 4; ++i) { rt_capture(L[i], ii, 1, LEN, SR); rt_mix(L[i], oo, 2, LEN, SR); }
    for (int i = 0; i < 2; ++i) { rt_capture(Z[i], ii, 1, LEN, SR); rt_mix(Z[i], oo, 2, LEN, SR); }
  }
  auto n = [&](const std::string &s, const char *k) { return atoll(field(s, "hub", k).c_str()); };
  printf("     outage: X heard nothing 300 ms: %s -> %s (in it) -> %s, fallbacks %lld -> %lld; a room of two: fallbacks %lld -> %lld\n", field(before, "hub", "state").c_str(),
         field(mid, "hub", "state").c_str(), field(after, "hub", "state").c_str(), n(before, "fallbacks"), n(after, "fallbacks"), n(zb, "fallbacks"), n(ze, "fallbacks"));
  printf("     outage: then H's mix stopped 600 ms: X %s, W %s at 0.4 s; fallbacks X +%lld, W +%lld\n", field(out_x, "hub", "state").c_str(), field(out_w, "hub", "state").c_str(),
         n(end_x, "fallbacks") - n(after, "fallbacks"), n(end_w, "fallbacks") - n(before_w, "fallbacks"));
  check_unless_stalled(field(before, "hub", "state") == "\"hub\"" && field(mid, "hub", "state") == "\"hub\"" && field(after, "hub", "state") == "\"hub\"" &&
                       n(after, "fallbacks") == n(before, "fallbacks"), stalled, "outage: X's own outage (nothing from anyone) keeps it on the mix, no fallback (it fell back: 3.3 s of everyone's streams)");
  check_unless_stalled(n(ze, "fallbacks") - n(zb, "fallbacks") == 1, stalled, "outage: in a room of two (nobody else to hear) the same outage falls back as before");
  check_unless_stalled(field(out_x, "hub", "state") == "\"direct\"" && field(out_w, "hub", "state") == "\"direct\"" && n(end_x, "fallbacks") - n(after, "fallbacks") == 1 &&
                       n(end_w, "fallbacks") - n(before_w, "fallbacks") == 1, stalled, "outage: the hub's mix really stopping still sends X and W to everyone's own streams within 0.4 s");
  for (int i = 0; i < 4; ++i) rt_free(L[i]);
  for (int i = 0; i < 2; ++i) rt_free(Z[i]);
}

// ---- Latency against underruns over a realistic spike pattern (1.0.22 in REAPER: 6 underruns took the desktop's buffer for the laptop from
// 45 to 110 ms and it stayed, latency 97 -> 161 ms). D sends silence to E with E's receive thread held 3-12 ms every 50-150 ms (an internet
// path's ordinary jitter) and 60 ms at each spike, at E's timings 20x faster (gap_s: the spikes' spacing in those timings). Returns E's
// buffer for D averaged over the run (ms) and counts the underruns (all, and those in the run's second half). Lone spikes (40 s apart) should
// each cost their one underrun and leave the buffer near its floor; spikes 8 s apart are the network's steady jitter and get held.
static double spike_run(double gap_s, int spikes, int port0, long long &under, long long &late_under, double &stalled)
{
  const int SR = 48000, LEN = 256;
  char pd[32], pe[32];
  snprintf(pd, sizeof pd, "127.0.0.1:%d", port0); snprintf(pe, sizeof pe, "127.0.0.1:%d", port0 + 1);
  RtLink *D = rt_new(), *E = rt_new();
  rt_peers(D, (std::string("{\"peers\":[\"") + pe + "\"],\"port\":" + std::to_string(port0) + ",\"secret\":\"studio\"}").c_str());
  rt_peers(E, (std::string("{\"peers\":[\"") + pd + "\"],\"port\":" + std::to_string(port0 + 1) + ",\"secret\":\"studio\"}").c_str());
  rt_start(D, 0, 1, 128, 0, "127.0.0.1"); rt_start(E, 0, 1, 128, 0, "127.0.0.1");
  rt_test_speed(E, 20);
  auto at = [&](double s) { return (int)(s * SR / LEN); };
  const double gap = gap_s / 20, first = 1.0, end = first + spikes * gap;
  std::vector<double> in(LEN, 0.0), o1(LEN), o2(LEN);
  const double *ii[1] = { in.data() };
  double *oo[2] = { o1.data(), o2.data() };
  unsigned rng = 777;
  auto rnd = [&](double lo, double hi) { rng = rng * 1103515245u + 12345u; return lo + (hi - lo) * ((rng >> 8) & 0xffff) / 65535.0; };
  double sum = 0, next_jit = 0.5, next_spike = first;
  long long n = 0, u0 = -1, u_half = -1;
  stalled = 0;
  const auto t0 = std::chrono::steady_clock::now();
  for (int b = 0; b < at(end); ++b) {
    const auto due = t0 + std::chrono::nanoseconds((long long)(1e9 * b * LEN / SR));
    while (std::chrono::steady_clock::now() < due) std::this_thread::yield();
    stalled = std::max(stalled, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - due).count());
    const double now = (double)b * LEN / SR;
    if (now >= next_spike) { rt_test_hold(E, 60); next_spike += gap; next_jit = now + 0.1; }
    else if (now >= next_jit) { rt_test_hold(E, rnd(3, 12)); next_jit = now + rnd(0.05, 0.15); }
    if (b >= at(first) && b % 4 == 0) {
      const std::string s = rt_status(E);
      if (u0 < 0) u0 = atoll(field(s, pd, "underruns").c_str());
      if (u_half < 0 && now >= (first + end) / 2) u_half = atoll(field(s, pd, "underruns").c_str());
      sum += atof(field(s, pd, "target_ms").c_str()); ++n;
    }
    rt_capture(D, ii, 1, LEN, SR); rt_capture(E, ii, 1, LEN, SR);
    rt_mix(D, oo, 2, LEN, SR); rt_mix(E, oo, 2, LEN, SR);
  }
  const long long u_end = atoll(field(rt_status(E), pd, "underruns").c_str());
  under = u_end - u0; late_under = u_end - u_half;
  rt_free(D); rt_free(E);
  return n ? sum / n : -1;
}
static void spike_tests()
{
  long long u40 = 0, l40 = 0, u8 = 0, l8 = 0;
  double s40 = 0, s8 = 0;
  const double b40 = spike_run(40, 8, 47481, u40, l40, s40), b8 = spike_run(8, 20, 47483, u8, l8, s8);
  printf("     spikes: 60 ms spikes 40 s apart (8): E's buffer %.1f ms on average, %lld underruns (a lone spike's ~30 ms of audio each); 8 s apart"
         " (20): %.1f ms on average, %lld underruns, %lld in the second half\n", b40, u40, b8, u8, l8);
  check_unless_stalled(b40 < 40 && u40 <= 8, s40, "spikes: lone spikes cost their own underrun, not a bigger buffer for minutes (under 40 ms on average)");
  // (coarse timers: a 60 ms spike runs up to a tick longer, and each 10 ms more is one more step for the buffer to grow, an underrun each: 4 in
  // the second half on the hosted Mac in three runs, and here with only the hold's sleep made 7 or 13 ms (2 with 1 ms). Held to half of the 10)
  if (coarse()) printf("     spikes: coarse timers (a 1 ms sleep here: %.1f ms): up to 5 of the last 10 may underrun\n", tick_ms());
  check_unless_stalled(l8 <= (coarse() ? 5 : 3) && b8 > 50, s8, "spikes: spikes close together are held (the buffer grows for them and stays: 3 of the last 10 at most)");
}

// ---- The desktop's audio clock (1.0.22: clock_ppm -1321 and -1498 where it counts -102 over minutes). Probed read-only on the desktop:
// WASAPI through Voicemeeter calls REAPER back on a 10 ms timer (480 samples a tick: the 512-sample block runs 15 ticks in 16) on the system's
// clock, and about once a minute drops a whole tick (the earliest callback's offset flat for a minute, then 10 ms later): a staircase that the
// median of 2-30 s slopes read as flat (+10) or, with a step inside, -1300. The estimator over 10 minutes of such callbacks (each 0-2 ms late,
// some 50 ms), from rt_test_clock: a tick dropped every 80 s is -125 ppm; and a plain device 102 ppm slow with the same lateness. The
// correction holds at 0 for the first 2 minutes of history and ramps in to all of the estimate at 10 (the desktop read -375 at 3 minutes).
static void clock_tests()
{
  unsigned rng = 4242;
  auto rnd = [&](double lo, double hi) { rng = rng * 1103515245u + 12345u; return lo + (hi - lo) * ((rng >> 8) & 0xffff) / 65535.0; };
  auto late = [&]() { return rnd(0, 1) < 0.002 ? 0.05 : rnd(0, 0.002); };
  std::vector<double> t;
  int acc = 0;
  for (long long j = 0; j < 60000; ++j) { // (10 minutes of 10 ms ticks, one dropped every 80 s)
    if (j % 8000 != 7999) acc += 480;
    for (; acc >= 512; acc -= 512) t.push_back(j * 0.010 + late());
  }
  double h10 = 1, h2 = 1;
  const double stair = rt_test_clock(t.data(), (int)t.size(), 512, 48000, &h10);
  const double stair2 = rt_test_clock(t.data(), (int)t.size() / 5, 512, 48000, &h2); // (2 minutes in)
  // (rt-audio3: AOO is handed nominal times whatever the estimate says: a wrong estimate at either end drained or filled every buffer, and
  // each stream's own buffer says what to read at instead. It was the estimate, ramped in over 10 minutes: -125 ppm here by then)
  printf("     clock: the times AOO is handed run %.2f ppm from nominal after 2 minutes, %.2f after 10 (the estimate: %.0f, %.0f)\n", h2, h10, stair2, stair);
  check(std::fabs(h2) < 0.01 && std::fabs(h10) < 0.01, "clock: AOO is handed nominal times, whatever the device's estimate reads (nothing reads at an estimate)");
  t.clear();
  for (long long k = 0; k < 56250; ++k) t.push_back(k * 512 / (48000 * (1 - 102e-6)) + late());
  const double slow = rt_test_clock(t.data(), (int)t.size(), 512, 48000);
  printf("     clock: Voicemeeter's staircase (a 10 ms tick dropped every 80 s: -125 ppm) reads %.0f ppm after 10 minutes, %.0f after 2; a device"
         " 102 ppm slow reads %.0f\n", stair, stair2, slow);
  check(std::fabs(stair + 125) < 15 && std::fabs(stair2 + 125) < 60, "clock: a staircase of dropped buffers is measured over minutes (not as its flat parts)");
  check(std::fabs(slow + 102) < 5, "clock: a plain slow device, its callbacks late by 0-2 ms and now and then 50 ms, measured within 5 ppm");
  // (rt-fix6b: the same device with stalls: callbacks that never came for 1.2 s at 3 minutes and 0.4 s at 7 (REAPER busy, the device
  // reopened), and the computer's clock set back 0.8 s at 5. They were read as rate: about +2000 ppm, the desktop's -1824 after a restart)
  t.clear();
  double gap = 0;
  for (long long k = 0; k < 56250; ++k) {
    const double at = k * 512 / (48000 * (1 - 102e-6));
    if (at > 180 && gap == 0) gap = 1.2;
    if (at > 300 && gap == 1.2) gap = 0.4;
    if (at > 420 && gap == 0.4) gap = 0.8;
    t.push_back(at + late() + (at > 180 ? 1.2 : 0) - (at > 300 ? 0.8 : 0) + (at > 420 ? 0.4 : 0));
  }
  const double stalled = rt_test_clock(t.data(), (int)t.size(), 512, 48000);
  printf("     clock: the slow device with stalls of 1.2 and 0.4 s and its clock set back 0.8 s reads %.0f ppm\n", stalled);
  check(std::fabs(stalled + 102) < 5, "clock: stalls and a clock set aren't taken as the device's rate (rt-r1: the laptop played the desktop's Play 2 % fast)");
  // (rt-audio3: LinuxBox, a VM, whose device counted +135 ppm while 1.0.37's estimate read -1008 to -1521 with 275-375 "steps". Its callbacks
  // come ten at once (the last of each ten on time), their timing creeps later, 75 ms in 30 s, and snaps back, and the guest is held 0.1-0.7 s
  // now and then and catches up. 1.0.37 took every jump over 25 ms + 2 blocks out, either way: the snaps back went, the creep stayed, read
  // as a device 2500 ppm slow. A jump down is the device's own timing; a jump up counts only if the callbacks stay late)
  t.clear();
  {
    const double per = 512 / (48000 * (1 + 135e-6));
    double free_at = 0;
    for (long long b = 0; b < 5625; ++b) { // (10 minutes of bursts of ten)
      const double at = (10 * b + 9) * per, due = at + 0.0025 * fmod(at, 30.0);
      if (rnd(0, 1) < 0.01) free_at = due + rnd(0.1, 0.7);
      for (int k = 0; k < 10; ++k) t.push_back(std::max(due, free_at) + rnd(0, 0.003));
    }
  }
  const double vm = rt_test_clock(t.data(), (int)t.size(), 512, 48000);
  printf("     clock: a VM's device 135 ppm fast, its callbacks ten at once, creeping 75 ms late every 30 s and held 0.1-0.7 s now and then, reads %+.0f ppm\n", vm);
  check(std::fabs(vm - 135) < 150, "clock: a VM's creeping, bursting callbacks aren't read as a slow device (LinuxBox read -1008 to -1521 ppm at +135, rt-r3)");
}

// ---- rt-fix6b: a receiver whose drift correction reads the sender 1.5 % wrong (rt-r1's laptop: the desktop's Play at 446.5 Hz, an underrun
// every few seconds) still plays what arrives at its rate: the read-rate servo follows each stream's buffer. P sends 440 Hz; Q's clock
// estimate is made 1.5 % off (rt_test_clock_bias); Q's adaptive timings 4x (rt_test_speed), so the servo settles within the run.
static void rate_test()
{
  const int SR = 48000, LP = 512, LQ = 128, PP = 47631, PQ = 47632;
  const double PI = 3.14159265358979;
  char pp[32], pq[32];
  snprintf(pp, sizeof pp, "127.0.0.1:%d", PP); snprintf(pq, sizeof pq, "127.0.0.1:%d", PQ);
  RtLink *P = rt_new(), *Q = rt_new();
  rt_peers(P, (std::string("{\"peers\":[\"") + pq + "\"],\"port\":" + std::to_string(PP) + ",\"secret\":\"studio\"}").c_str());
  rt_peers(Q, (std::string("{\"peers\":[\"") + pp + "\"],\"port\":" + std::to_string(PQ) + ",\"secret\":\"studio\"}").c_str());
  rt_start(P, 0, 1, 128, 0, "127.0.0.1"); rt_start(Q, 0, 1, 128, 0, "127.0.0.1");
  rt_test_clock_bias(Q, 15000);
  rt_test_speed(Q, 4);
  rt_peer_buffer(Q, pp, 60, 60);
  std::vector<double> ip(LP), iq(LQ, 0.0), op1(LP), op2(LP), oq1(LQ), oq2(LQ), heard;
  double *oP[2] = { op1.data(), op2.data() }, *oQ[2] = { oq1.data(), oq2.data() };
  long long bp = 0, bq = 0, n = 0, u10 = -1;
  double stalled = 0;
  const auto t0 = std::chrono::steady_clock::now();
  for (;;) {
    const double dp = (double)bp * LP / SR, dq = (double)bq * LQ / SR, due = std::min(dp, dq);
    if (due > 26.0) break;
    while (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() < due) std::this_thread::yield();
    const double late_ms = (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() - due) * 1000;
    if (due > 2) stalled = std::max(stalled, late_ms);
    if (dp <= dq) {
      for (int k = 0; k < LP; ++k, ++n) ip[k] = 0.5 * sin(2 * PI * 440 * n / SR);
      const double *ii[1] = { ip.data() };
      rt_capture(P, ii, 1, LP, SR); rt_mix(P, oP, 2, LP, SR); ++bp;
    } else {
      const double *ii[1] = { iq.data() };
      std::fill(oq1.begin(), oq1.end(), 0.0);
      rt_capture(Q, ii, 1, LQ, SR); rt_mix(Q, oQ, 2, LQ, SR); ++bq;
      heard.insert(heard.end(), oq1.begin(), oq1.end());
      if (u10 < 0 && dq >= 12.0) u10 = atoll(field(rt_status(Q), pp, "underruns").c_str());
    }
  }
  const std::string sq = rt_status(Q);
  rt_free(P); rt_free(Q);
  // (the pitch over 20-25 s: zero crossings, interpolated)
  double first = -1, last = -1;
  int cnt = 0;
  for (size_t i = (size_t)20 * SR + 1; i < (size_t)25 * SR && i < heard.size(); ++i)
    if (heard[i - 1] < 0 && heard[i] >= 0) { const double x = (i - 1) + heard[i - 1] / (heard[i - 1] - heard[i]); if (first < 0) first = x; last = x; ++cnt; }
  const double hz = cnt > 1 ? (cnt - 1) * SR / (last - first) : -1;
  const long long u20 = atoll(field(sq, pp, "underruns").c_str());
  const double rate = atof(field(sq, pp, "rate_ppm").c_str());
  printf("     rate: Q's clock 1.5 %% off: heard %.2f Hz at 20-25 s, underruns %lld by 12 s and %lld by 26 s, Talk's read rate %.0f ppm\n", hz, u10, u20, rate);
  check_unless_stalled(std::fabs(hz - 440) < 440 * 0.002, stalled, "rate: Q plays what P sends at P's rate (440 Hz, not 446.6) with its own clock 1.5 % off");
  check_unless_stalled(u20 == u10, stalled, "rate: no underrun in Q's last 14 s (it ran dry every few seconds)");
  check(rate < -10000 && rate > -20000, "rate: the servo learned the 1.5 % (rate_ppm in the status)");
}

// ---- rt-audio3: devices that don't keep their rate, and a VM's timing (rt-r3, extension 1.0.37, on the real rig) ---------------------------
// A tone's pitch over [a, b) of x (zero crossings, interpolated), Hz at sr; -1: under two crossings.
static double pitch_hz(const std::vector<double> &x, size_t a, size_t b, double sr)
{
  double first = -1, last = -1;
  int cnt = 0;
  for (size_t i = a + 1; i < b && i < x.size(); ++i)
    if (x[i - 1] < 0 && x[i] >= 0) { const double at = (double)(i - 1) + x[i - 1] / (x[i - 1] - x[i]); if (first < 0) first = at; last = at; ++cnt; }
  return cnt > 1 ? (cnt - 1) * sr / (last - first) : -1;
}
// The desktop's device (WASAPI through Voicemeeter at 512): REAPER is called back on a 10 ms tick with 480 samples a tick, and ticks are
// dropped, 2 to 12 of them in 10 s, a different share every few seconds (measured: 47404-48138 Hz over 10 s stretches, 47716-47890 over
// 30-45 s). So its real rate is 0.1-1.2 % under 48 kHz and moves all the time. Heard through 1.0.37: the laptop -> the desktop 0.25 % fast
// with 250 ms of gaps and the desktop's Play re-buffers rising; the desktop -> the laptop re-buffering every 2 minutes while idle, its read
// rate swinging +-3000 ppm. Here L (a steady device, 128-sample blocks) and D (that device) each send the other a tone for 45 s; from 15 s
// on, each must hear the other whole (no re-buffer, no shed, no gap) at the pitch the two real rates give, and D's status must say what
// D's device really does. Fails on 1.0.37's rtaudio.cpp (a clock estimate held at nominal for its first minutes, then a ten-minute
// average; a servo that wants three 1 s slopes in a row).
static void device_test()
{
  const int SR = 48000, LL = 128, LD = 512, PL = 47641, PD = 47642;
  const double PI = 3.14159265358979, T_END = 45.0, T_SET = 15.0;
  const double drop[8] = { 0.004, 0.012, 0.001, 0.008, 0.003, 0.010, 0.002, 0.006 }; // (the share of D's ticks dropped, a new one every 6 s)
  char pl[32], pd[32];
  snprintf(pl, sizeof pl, "127.0.0.1:%d", PL); snprintf(pd, sizeof pd, "127.0.0.1:%d", PD);
  RtLink *L = rt_new(), *D = rt_new();
  rt_peers(L, (std::string("{\"peers\":[\"") + pd + "\"],\"port\":" + std::to_string(PL) + ",\"secret\":\"studio\"}").c_str());
  rt_peers(D, (std::string("{\"peers\":[\"") + pl + "\"],\"port\":" + std::to_string(PD) + ",\"secret\":\"studio\"}").c_str());
  rt_start(L, 0, 1, 128, 0, "127.0.0.1"); rt_start(D, 0, 1, 128, 0, "127.0.0.1");
  std::vector<double> il(LL), id(LD), ol1(LL), ol2(LL), od1(LD), od2(LD), heard_l, heard_d;
  double *oL[2] = { ol1.data(), ol2.data() }, *oD[2] = { od1.data(), od2.data() };
  long long bl = 0, tick = 0, nl = 0, nd = 0, bd = 0, bd_set = -1;
  int acc = 0;
  double debt = 0, stalled = 0, real_set = 0, real_end = 0;
  std::string sl0, sd0;
  const auto t0 = std::chrono::steady_clock::now();
  for (;;) {
    const double due_l = (double)bl * LL / SR, due_t = (double)tick * 0.010, due = std::min(due_l, due_t);
    if (due > T_END) break;
    while (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() < due) std::this_thread::yield();
    const double real = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    if (due > 2) stalled = std::max(stalled, (real - due) * 1000);
    if (bd_set < 0 && due >= T_SET) { bd_set = bd; real_set = real; sl0 = rt_status(L); sd0 = rt_status(D); }
    real_end = real;
    if (due_l <= due_t) {
      for (int k = 0; k < LL; ++k, ++nl) il[k] = 0.5 * sin(2 * PI * 440 * nl / SR);
      const double *ii[1] = { il.data() };
      std::fill(ol1.begin(), ol1.end(), 0.0);
      rt_capture(L, ii, 1, LL, SR); rt_mix(L, oL, 2, LL, SR); ++bl;
      heard_l.insert(heard_l.end(), ol1.begin(), ol1.end());
    } else { // (a tick of D's device: 480 samples unless it's dropped, and a callback for every 512 of them)
      debt += drop[(int)(due_t / 6) % 8];
      if (debt >= 1) debt -= 1; else acc += 480;
      for (; acc >= LD; acc -= LD) {
        for (int k = 0; k < LD; ++k, ++nd) id[k] = 0.5 * sin(2 * PI * 660 * nd / SR);
        const double *ii[1] = { id.data() };
        std::fill(od1.begin(), od1.end(), 0.0);
        rt_capture(D, ii, 1, LD, SR); rt_mix(D, oD, 2, LD, SR); ++bd;
        heard_d.insert(heard_d.end(), od1.begin(), od1.end());
      }
      ++tick;
    }
  }
  const std::string sl = rt_status(L), sd = rt_status(D);
  rt_free(L); rt_free(D);
  auto num = [](const std::string &s, const char *peer, const char *key) { return atof(field(s, peer, key).c_str()); };
  // (D's real rate from 15 s to the end, counted here; what each hears is at the other's rate over its own)
  const double d_hz = bd_set >= 0 && real_end > real_set ? (double)(bd - bd_set) * LD / (real_end - real_set) : 0;
  const double hz_l = pitch_hz(heard_l, (size_t)(T_SET * SR), heard_l.size(), SR), want_l = 660 * d_hz / SR; // (L hears D's 660)
  const double hz_d = pitch_hz(heard_d, (size_t)bd_set * LD, heard_d.size(), SR), want_d = 440 * SR / d_hz;  // (D hears L's 440)
  std::vector<double> hd(heard_d.begin() + (ptrdiff_t)((size_t)bd_set * LD), heard_d.end());
  const double gap_l = min_rms(heard_l, T_SET, T_END - 0.1), gap_d = min_rms(hd, 0, (double)hd.size() / SR - 0.1);
  const double ul = num(sl, pd, "underruns") - num(sl0, pd, "underruns"), ud = num(sd, pl, "underruns") - num(sd0, pl, "underruns");
  const double tl = num(sl, pd, "trims") - num(sl0, pd, "trims"), td = num(sd, pl, "trims") - num(sd0, pl, "trims");
  const double ol = num(sl, pd, "overruns") - num(sl0, pd, "overruns"), od = num(sd, pl, "overruns") - num(sd0, pl, "overruns");
  printf("     device: D's device ran %.0f Hz from 15 s (%+.0f ppm); L hears D's 660 Hz at %.2f (%.2f at the two real rates), D hears L's 440 Hz at %.2f (%.2f)\n",
         d_hz, (d_hz / SR - 1) * 1e6, hz_l, want_l, hz_d, want_d);
  printf("     device: from 15 s: L's buffer for D underran %.0f times, shed %.0f, overran %.0f (quietest 10 ms heard: RMS %.3f; size %s ms, learned %+.0f ppm); D's for L: %.0f, %.0f, %.0f (RMS %.3f; size %s ms, learned %+.0f ppm); the test's own longest stall %.0f ms\n",
         ul, tl, ol, gap_l, field(sl, pd, "target_ms").c_str(), num(sl, pd, "ratio_ppm"), ud, td, od, gap_d, field(sd, pl, "target_ms").c_str(), num(sd, pl, "ratio_ppm"), stalled);
  check(d_hz > SR * 0.99 && d_hz < SR * 0.998, "device: the test's device runs 0.2-1 % under 48 kHz, as the desktop's does");
  check_unless_stalled(ul == 0 && ud == 0 && ol == 0 && od == 0, stalled, "device: neither end's buffer runs dry or over once settled (the desktop's Play re-buffered every minute or two)");
  check_unless_stalled(tl == 0 && td == 0, stalled, "device: and nothing is shed: the read rate follows the device, the buffer isn't cut to fit");
  check_unless_stalled(gap_l > 0.25 && gap_d > 0.25, stalled, "device: no gap in what either hears (250 ms of gaps in 10 s, rt-r3)");
  check_unless_stalled(std::fabs(hz_l / want_l - 1) < 0.001 && std::fabs(hz_d / want_d - 1) < 0.001, stalled,
                       "device: each hears the other at the pitch the two real rates give, within 0.1 % over 30 s (nothing lost, nothing added)");
  // (what each learned: the other's rate over its own. L's of D: D's deficit, so negative; D's of L: the same, positive)
  check_unless_stalled(std::fabs(num(sl, pd, "ratio_ppm") - (d_hz / SR - 1) * 1e6) < 4000 && std::fabs(num(sd, pl, "ratio_ppm") - (SR / d_hz - 1) * 1e6) < 4000, stalled,
                       "device: the status says what each learned of the other's rate (ratio_ppm, within the device's own swing)");
}

// LinuxBox, a VM: its REAPER is called back for ten 512-sample blocks at once about every 107 ms, the guest is held for 60-100 ms now and
// then (its threads all stop, then catch up), and the times it hands AOO were 1000-1500 ppm wrong (1.0.37's clock estimate, see clock_tests'
// VM case; here rt_test_clock_bias makes them so), so it heard the desktop 0.3 % slow with 240-1820 ms of gaps in 10 s and its Play
// re-buffers ran 1 -> 15 in a run. S (a steady device) sends V a tone for 45 s; V's buffer for S is given the 120-200 ms such a guest
// settles at. From 15 s on V must hear S whole, at the pitch the two real rates give.
static void vm_test()
{
  const int SR = 48000, LS = 256, LV = 512, PS = 47651, PV = 47652, BURST = 10;
  const double PI = 3.14159265358979, T_END = 45.0, T_SET = 15.0, V_PPM = 135;
  char ps[32], pv[32];
  snprintf(ps, sizeof ps, "127.0.0.1:%d", PS); snprintf(pv, sizeof pv, "127.0.0.1:%d", PV);
  RtLink *S = rt_new(), *V = rt_new();
  rt_peers(S, (std::string("{\"peers\":[\"") + pv + "\"],\"port\":" + std::to_string(PS) + ",\"secret\":\"studio\"}").c_str());
  rt_peers(V, (std::string("{\"peers\":[\"") + ps + "\"],\"port\":" + std::to_string(PV) + ",\"secret\":\"studio\"}").c_str());
  rt_start(S, 0, 1, 128, 0, "127.0.0.1"); rt_start(V, 0, 1, 128, 0, "127.0.0.1");
  rt_test_clock_bias(V, -1500);
  std::vector<double> is(LS), iv(LV, 0.0), os1(LS), os2(LS), ov1(LV), ov2(LV), heard;
  double *oS[2] = { os1.data(), os2.data() }, *oV[2] = { ov1.data(), ov2.data() };
  const double per_v = (double)BURST * LV / (SR * (1 + V_PPM * 1e-6)); // (a burst of V's callbacks: this long apart, real time)
  unsigned rng = 9001;
  auto rnd = [&](double lo, double hi) { rng = rng * 1103515245u + 12345u; return lo + (hi - lo) * ((rng >> 8) & 0xffff) / 65535.0; };
  long long bs = 0, bursts = 0, ns = 0, bv = 0, bv_set = -1;
  double stalled = 0, real_set = 0, real_end = 0, held_until = 0, next_hold = 4.0, jit = 0;
  bool sized = false;
  std::string sv0;
  const auto t0 = std::chrono::steady_clock::now();
  for (;;) {
    const double due_s = (double)bs * LS / SR, due_v = std::max((double)(bursts + 1) * per_v + jit, held_until), due = std::min(due_s, due_v);
    if (due > T_END) break;
    while (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() < due) std::this_thread::yield();
    const double real = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    if (due > 2) stalled = std::max(stalled, (real - due) * 1000);
    if (!sized && due > 0.5) sized = rt_peer_buffer(V, ps, 120, 200) == 1;
    if (bv_set < 0 && due >= T_SET) { bv_set = bv; real_set = real; sv0 = rt_status(V); }
    real_end = real;
    if (due >= next_hold) { // (the guest held: its receive and send threads stop, and its callbacks with them, then all catch up)
      const double ms = rnd(60, 100);
      rt_test_hold(V, ms); rt_test_hold_tx(V, ms);
      held_until = due + ms / 1000;
      next_hold = due + rnd(2.0, 4.0);
    }
    if (due_s <= due_v) {
      for (int k = 0; k < LS; ++k, ++ns) is[k] = 0.5 * sin(2 * PI * 440 * ns / SR);
      const double *ii[1] = { is.data() };
      rt_capture(S, ii, 1, LS, SR); rt_mix(S, oS, 2, LS, SR); ++bs;
    } else { // (every burst V's device has run by now, ten blocks each, back to back)
      while ((double)(bursts + 1) * per_v + jit <= due) {
        for (int b = 0; b < BURST; ++b) {
          const double *ii[1] = { iv.data() };
          std::fill(ov1.begin(), ov1.end(), 0.0);
          rt_capture(V, ii, 1, LV, SR); rt_mix(V, oV, 2, LV, SR); ++bv;
          heard.insert(heard.end(), ov1.begin(), ov1.end());
        }
        ++bursts;
        jit = rnd(0, 0.015); // (the next one up to 15 ms late)
      }
    }
  }
  const std::string sv = rt_status(V);
  rt_free(S); rt_free(V);
  auto num = [](const std::string &s, const char *peer, const char *key) { return atof(field(s, peer, key).c_str()); };
  // (V's real rate is the one its bursts are timed at: counted over 30 s it's only good to a burst, 107 ms in 30 s)
  const double v_hz = SR * (1 + V_PPM * 1e-6);
  const double hz = pitch_hz(heard, (size_t)bv_set * LV, heard.size(), SR), want = 440 * SR / v_hz;
  std::vector<double> hv(heard.begin() + (ptrdiff_t)((size_t)bv_set * LV), heard.end());
  const double gap = min_rms(hv, 0, (double)hv.size() / SR - 0.1);
  const double u = num(sv, ps, "underruns") - num(sv0, ps, "underruns"), t = num(sv, ps, "trims") - num(sv0, ps, "trims"), o = num(sv, ps, "overruns") - num(sv0, ps, "overruns");
  printf("     vm: V's device runs %.0f Hz (%+.0f ppm), its AOO times 1500 ppm off; V hears S's 440 Hz at %.2f (%.2f at the two real rates); its buffer for S underran %.0f times, shed %.0f, overran %.0f (quietest 10 ms heard: RMS %.3f; size %s ms, learned %+.0f ppm, read at %+.0f now); the test's own longest stall %.0f ms\n",
         v_hz, (v_hz / SR - 1) * 1e6, hz, want, u, t, o, gap, field(sv, ps, "target_ms").c_str(), num(sv, ps, "ratio_ppm"), num(sv, ps, "rate_ppm"), stalled);
  check_unless_stalled(std::fabs(hz / want - 1) < 0.001, stalled, "vm: a VM hears a bandmate at the pitch the two real rates give, its own times 1500 ppm wrong (0.3 % slow, rt-r3)");
  check_unless_stalled(u == 0 && o == 0 && gap > 0.25, stalled, "vm: with no re-buffer and no gap once settled, through the guest's holds (240-1820 ms of gaps in 10 s)");
  check_unless_stalled(t <= 1, stalled, "vm: and at most one shed in 30 s: the bursts and holds aren't cut out of the buffer");
  // (what it must learn: S's rate over V's, and the 1500 ppm its own times run slow)
  check_unless_stalled(std::fabs(num(sv, ps, "ratio_ppm") - (1500 - V_PPM)) < 600, stalled, "vm: it learned the ratio from its buffer, wrong times and all (ratio_ppm within 600 ppm of +1365)");
}

// ---- A studio computer this one doesn't list (Health on the desktop: "refused 13589 (last: not one of the studio's computers here from
// <the laptop's address>)" while the laptop's room left the desktop out): X lists Y and sends; Y has the secret but lists nobody. Y drops X's
// datagrams as not_here, with X's address, and refuses nothing.
static void not_here_test()
{
  const int SR = 48000, LEN = 256, PX = 47581, PY = 47582;
  char px[32], py[32];
  snprintf(px, sizeof px, "127.0.0.1:%d", PX); snprintf(py, sizeof py, "127.0.0.1:%d", PY);
  RtLink *X = rt_new(), *Y = rt_new();
  rt_peers(X, (std::string("{\"peers\":[\"") + py + "\"],\"port\":" + std::to_string(PX) + ",\"secret\":\"studio\"}").c_str());
  rt_peers(Y, (std::string("{\"peers\":[],\"port\":") + std::to_string(PY) + ",\"secret\":\"studio\"}").c_str());
  rt_start(Y, 0, 1, 64, 0, "127.0.0.1"); rt_start(X, 0, 1, 64, 0, "127.0.0.1");
  std::vector<double> in(LEN, 0.25), o1(LEN), o2(LEN);
  const double *ii[1] = { in.data() };
  double *oo[2] = { o1.data(), o2.data() };
  const auto t0 = std::chrono::steady_clock::now();
  for (long long b = 0; b * LEN < SR * 3 / 2; ++b) { // (1.5 s of blocks in real time)
    while (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() < (double)b * LEN / SR) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    rt_capture(X, ii, 1, LEN, SR); rt_mix(X, oo, 2, LEN, SR);
    rt_capture(Y, ii, 1, LEN, SR); rt_mix(Y, oo, 2, LEN, SR);
  }
  const std::string sy = rt_status(Y);
  // (rt-roomlist: each sender off the list apart, how long ago; and once Y lists X, how long ago X's last datagram came: Live sync keeps X while
  // it sends, lib/liveaudio.lua heard_merge)
  const size_t nhp = sy.find("\"not_here_peers\":{\"" + std::string(px) + "\":{\"ago\":");
  const double nh_ago = nhp == std::string::npos ? -1 : atof(sy.c_str() + sy.find("\"ago\":", nhp) + 6);
  rt_peers(Y, (std::string("{\"peers\":[\"") + px + "\"],\"port\":" + std::to_string(PY) + ",\"secret\":\"studio\"}").c_str());
  const auto t1 = std::chrono::steady_clock::now();
  for (long long b = 0; b * LEN < SR; ++b) { // (1 s more, Y listing X now)
    while (std::chrono::duration<double>(std::chrono::steady_clock::now() - t1).count() < (double)b * LEN / SR) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    rt_capture(X, ii, 1, LEN, SR); rt_mix(X, oo, 2, LEN, SR);
    rt_capture(Y, ii, 1, LEN, SR); rt_mix(Y, oo, 2, LEN, SR);
  }
  const std::string sy2 = rt_status(Y);
  rt_free(X); rt_free(Y);
  const std::string heard = field(sy2, px, "heard_ago");
  printf("     not here: X in Y's not_here_peers %.2f s ago; once listed, X heard %s s ago\n", nh_ago, heard.c_str());
  check(nh_ago >= 0 && nh_ago < 0.5, "not here: each sender off the list is in not_here_peers, heard just now");
  check(!heard.empty() && atof(heard.c_str()) < 0.5, "not here: once listed, its heard_ago says it still sends (Live sync keeps a peer it hears)");
  printf("     not here: Y dropped %s of X's datagrams as not on its list (from %s), refused %s (last: %s)\n", field(sy, "", "not_here").c_str(),
         field(sy, "", "not_here_from").c_str(), field(sy, "", "rejected").c_str(), field(sy, "", "last_reject").c_str());
  check(atoll(field(sy, "", "not_here").c_str()) > 0 && field(sy, "", "not_here_from") == "\"" + std::string(px) + "\"",
        "not here: a studio computer Y doesn't list is counted apart, with its address");
  check(field(sy, "", "rejected") == "0", "not here: and isn't counted as a refusal (Health's alarm)");
}

// ---- The four-computer test's start order (2026-11-20, extension 1.0.27): the laptop's REAPER and Live sync start first, the desktop's a
// minute later; the Mac is everyone's hub, but its peer list leaves the desktop out (its room read the desktop's status late: not_here). The
// laptop heard the Mac's mix and told everyone so, so the desktop stopped sending to it, and the Mac's mix had no desktop: the laptop heard
// nothing of it while the desktop heard the laptop (one-way), and the desktop sat "joining" the Mac's mix for minutes. Here M (the Mac) lists
// A (the laptop) only; A starts with M as its hub, D (the desktop) 1.2 s later. A must hear D directly (M's 'H' says its mix hasn't D), D
// must stop joining within JOIN_S and say so; then the owner's pick takes the hub back (M's list catches up, D mixes, A and M take D as their
// hub) and everyone hears everyone, A never losing D for longer than a jitter buffer. Tones on their own DFT bins, as the hub test's.
static void start_order_test()
{
  const int SR = 48000, LEN = 256, P[3] = { 47591, 47592, 47593 }; // M, A, D
  const double PI = 3.14159265358979, AMP[3] = { 0.2, 0.3, 0.4 };
  const int BIN[3] = { 2, 4, 6 };
  char nm[3][32];
  RtLink *L[3];
  for (int i = 0; i < 3; ++i) { snprintf(nm[i], sizeof nm[i], "127.0.0.1:%d", P[i]); L[i] = rt_new(); }
  auto js = [&](int i, std::vector<int> others) {
    std::string list;
    for (int j : others) list += std::string(list.empty() ? "" : ", ") + "\"" + nm[j] + "\"";
    return "{\"peers\":[" + list + "],\"port\":" + std::to_string(P[i]) + ",\"secret\":\"studio\"}";
  };
  rt_peers(L[0], js(0, { 1 }).c_str()); // (the Mac's room without the desktop)
  rt_peers(L[1], js(1, { 0, 2 }).c_str());
  rt_peers(L[2], js(2, { 0, 1 }).c_str());
  rt_start(L[0], 0, 1, 128, 0, "127.0.0.1");
  rt_start(L[1], 0, 1, 128, 0, "127.0.0.1");
  auto at = [&](double s) { return (int)(s * SR / LEN); };
  auto level_of = [&](const std::vector<double> &x, int bin) {
    double re = 0, im = 0;
    for (int k = 0; k < LEN; ++k) { re += x[k] * cos(2 * PI * bin * k / LEN); im -= x[k] * sin(2 * PI * bin * k / LEN); }
    return 2 * sqrt(re * re + im * im) / LEN;
  };
  std::vector<double> in[3], out[3], out2[3], amp[3][3]; // amp[listener][source]: each block's level of that source's tone (left)
  for (int i = 0; i < 3; ++i) { in[i].assign(LEN, 0.0); out[i].assign(LEN, 0.0); out2[i].assign(LEN, 0.0); }
  std::string a_mid, d_mid, d_late, m_end, a_end, d_end;
  long long n = 0;
  double stalled = 0;
  const int total = at(13.0), d_on = at(1.5), back = at(8.0);
  const auto t0 = std::chrono::steady_clock::now();
  for (int b = 0; b < total; ++b) {
    const auto due = t0 + std::chrono::nanoseconds((long long)(1e9 * b * LEN / SR));
    while (std::chrono::steady_clock::now() < due) std::this_thread::yield();
    stalled = std::max(stalled, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - due).count());
    for (int k = 0; k < LEN; ++k, ++n) for (int i = 0; i < 3; ++i) in[i][k] = AMP[i] * sin(2 * PI * BIN[i] * (double)n / LEN);
    if (b == at(0.3)) { rt_hub(L[0], "", 1); rt_hub(L[1], nm[0], 0); }
    if (b == d_on) { rt_start(L[2], 0, 1, 128, 0, "127.0.0.1"); rt_hub(L[2], nm[0], 0); }
    if (b == at(4.0)) { a_mid = rt_status(L[1]); d_mid = rt_status(L[2]); }
    if (b == at(7.8)) d_late = rt_status(L[2]);
    if (b == back) { // (the owner's pick takes the hub back)
      rt_peers(L[0], js(0, { 1, 2 }).c_str());
      rt_hub(L[2], "", 1);
      rt_hub(L[0], nm[2], 0);
      rt_hub(L[1], nm[2], 0);
    }
    if (b == at(12.8)) { m_end = rt_status(L[0]); a_end = rt_status(L[1]); d_end = rt_status(L[2]); }
    for (int i = 0; i < 3; ++i) { std::fill(out[i].begin(), out[i].end(), 0.0); std::fill(out2[i].begin(), out2[i].end(), 0.0); }
    for (int i = 0; i < 3; ++i) { const double *ii[1] = { in[i].data() }; rt_capture(L[i], ii, 1, LEN, SR); }
    for (int i = 0; i < 3; ++i) { double *oo[2] = { out[i].data(), out2[i].data() }; rt_mix(L[i], oo, 2, LEN, SR); }
    for (int i = 0; i < 3; ++i) for (int j = 0; j < 3; ++j) amp[i][j].push_back(level_of(out[i], BIN[j]));
  }
  auto avg = [&](int li, int src, double s0, double s1) { double s = 0; int c = 0; for (int b = at(s0); b < at(s1); ++b) { s += amp[li][src][b]; ++c; } return c ? s / c : 0.0; };
  auto about = [](double v, double want) { return v > want * 0.75 && v < want * 1.25; };
  auto gap = [&](int li, int src, double s0, double s1) { int run = 0, best = 0; for (int b = at(s0); b < at(s1); ++b) { run = amp[li][src][b] < AMP[src] / 2 ? run + 1 : 0; best = std::max(best, run); } return best * 1000.0 * LEN / SR; };
  const double ad = avg(1, 2, 3.0, 4.0), da = avg(2, 1, 3.0, 4.0), am = avg(1, 0, 3.0, 4.0);
  printf("     start order: by 4 s A hears D at %.3f (want %.2f), M at %.3f (through M's mix: %s, D via_hub %s); D hears A at %.3f; D's hub %s at 4 s, %s at 7.8 s (join_fails %s)\n",
         ad, AMP[2], am, field(a_mid, "hub", "state").c_str(), field(a_mid, nm[2], "via_hub").c_str(), da, field(d_mid, "hub", "state").c_str(),
         field(d_late, "hub", "state").c_str(), field(d_late, "hub", "join_fails").c_str());
  check_unless_stalled(field(a_mid, "hub", "state") == "\"hub\"" && about(am, AMP[0]), stalled, "start order: A hears through M's mix");
  check(about(ad, AMP[2]) && about(da, AMP[1]), "start order: A and D hear each other though M's mix hasn't D (never one-way)");
  check(field(a_mid, nm[2], "via_hub") == "false" && field(d_mid, nm[1], "direct") == "true", "start order: A says D is heard directly, and D keeps sending to A");
  check_unless_stalled(field(d_late, "hub", "state") == "\"direct\"" && atoll(field(d_late, "hub", "join_fails").c_str()) >= 1, stalled,
        "start order: D stops joining a mix that never comes within seconds, and says so (join_fails)");
  const double g_ad = gap(1, 2, 2.5, 12.8), g_da = gap(2, 1, 2.5, 12.8);
  printf("     start order: after D takes the hub back: A hears M %.3f, D %.3f (%s); M hears A %.3f, D %.3f (%s); D hears A %.3f, M %.3f (serving %s); A's longest gap in D %.0f ms, D's in A %.0f ms\n",
         avg(1, 0, 11.5, 12.8), avg(1, 2, 11.5, 12.8), field(a_end, "hub", "state").c_str(), avg(0, 1, 11.5, 12.8), avg(0, 2, 11.5, 12.8), field(m_end, "hub", "state").c_str(),
         avg(2, 1, 11.5, 12.8), avg(2, 0, 11.5, 12.8), field(d_end, "hub", "serving").c_str(), g_ad, g_da);
  bool all = true;
  for (int li = 0; li < 3; ++li) for (int s = 0; s < 3; ++s) if (li != s && !about(avg(li, s, 11.5, 12.8), AMP[s])) all = false;
  // (rt-ci3: a 419 ms stall of the test inside the last 1.3 s took ~27% off every level and sent everyone back to direct: CI run 44819565221)
  check_unless_stalled(all, stalled, "start order: after the owner's pick takes the hub back, everyone hears everyone at full level");
  check_unless_stalled(field(d_end, "hub", "serving") == "2" && field(a_end, "hub", "state") == "\"hub\"" && field(m_end, "hub", "state") == "\"hub\"", stalled,
        "start order: D mixes for A and M, both hear through it");
  check_unless_stalled(g_ad < 60 && g_da < 60, stalled, "start order: A and D never lose each other for longer than a jitter buffer, through the handover too");
  for (int i = 0; i < 3; ++i) rt_free(L[i]);
}

int main(int argc, char **argv)
{
  if (argc > 1 && strcmp(argv[1], "underruns") == 0) { drift_tests(); trim_test(); play_resync_test(); switch_test(); rescue_test(); stall_test(); outage_test(); spike_tests(); clock_tests(); rate_test(); device_test(); vm_test(); printf(fails ? "fails %d\n" : "ok, fails 0\n", fails); return fails ? 1 : 0; }
  if (argc > 1 && strcmp(argv[1], "device") == 0) { device_test(); vm_test(); printf(fails ? "fails %d\n" : "ok, fails 0\n", fails); return fails ? 1 : 0; }
  if (argc > 1 && strcmp(argv[1], "clock") == 0) { clock_tests(); printf(fails ? "fails %d\n" : "ok, fails 0\n", fails); return fails ? 1 : 0; }
  if (argc > 1 && strcmp(argv[1], "drift") == 0) { drift_tests(); printf(fails ? "fails %d\n" : "ok, fails 0\n", fails); return fails ? 1 : 0; }
  if (argc > 1 && strcmp(argv[1], "rate") == 0) { clock_tests(); rate_test(); printf(fails ? "fails %d\n" : "ok, fails 0\n", fails); return fails ? 1 : 0; }
  if (argc > 1 && strcmp(argv[1], "playresync") == 0) { trim_test(); play_resync_test(); printf(fails ? "fails %d\n" : "ok, fails 0\n", fails); return fails ? 1 : 0; }
  if (argc > 1 && strcmp(argv[1], "stalls") == 0) { stall_test(); printf(fails ? "fails %d\n" : "ok, fails 0\n", fails); return fails ? 1 : 0; }
  if (argc > 1 && strcmp(argv[1], "outage") == 0) { outage_test(); printf(fails ? "fails %d\n" : "ok, fails 0\n", fails); return fails ? 1 : 0; }
  if (argc > 1 && strcmp(argv[1], "nothere") == 0) { not_here_test(); printf(fails ? "fails %d\n" : "ok, fails 0\n", fails); return fails ? 1 : 0; }
  if (argc > 1 && strcmp(argv[1], "startorder") == 0) { start_order_test(); printf(fails ? "fails %d\n" : "ok, fails 0\n", fails); return fails ? 1 : 0; }
  if (argc > 1 && strcmp(argv[1], "hubload") == 0) { hub_loads(true); printf(fails ? "fails %d\n" : "ok, fails 0\n", fails); return fails ? 1 : 0; }
  const int SR = 48000, LEN = 256, PA = 47391, PB = 47392, PC = 47393;
  const double PI = 3.14159265358979;
  RtLink *A = rt_new(), *B = rt_new(), *C = rt_new();
  char pa[32], pb[32], pc[32];
  snprintf(pa, sizeof pa, "127.0.0.1:%d", PA); snprintf(pb, sizeof pb, "127.0.0.1:%d", PB); snprintf(pc, sizeof pc, "127.0.0.1:%d", PC);
  auto cfg = [](const char *secret, int port, const std::string &peers) { // (as lib/liveaudio.lua writes it)
    return std::string("{\"peers\":[") + peers + "],\"port\":" + std::to_string(port) + ",\"secret\":\"" + secret + "\"}";
  };
  const std::string qa = std::string("\"") + pa + "\"", qb = std::string("\"") + pb + "\"", qc = std::string("\"") + pc + "\"";
  check(rt_peers(A, cfg("studio \\\"secret\\\"", PA, qb).c_str()) == 1, "A's peers JSON: B (a secret with escapes in it)");
  check(rt_peers(B, cfg("studio \\\"secret\\\"", PB, qa + ", " + qc).c_str()) == 2, "B's peers: A and C");
  check(rt_peers(C, cfg("not the studio's", PC, qb).c_str()) == 1, "C's peers: B, with the wrong secret");
  check(rt_peers(C, "[\"127.0.0.1:1\"]") == -1 && rt_peers(C, "{\"peers\":[\"x\"") == -1, "JSON that isn't the peers object is refused");
  check(rt_start(A, 0, 1, 128, 0, "127.0.0.1") == 1, "A starts on 127.0.0.1 (UDP), on the JSON's port");
  check(rt_start(B, 0, 1, 128, 0, "127.0.0.1") == 1, "B starts");
  check(rt_start(C, 0, 1, 128, 0, "127.0.0.1") == 1, "C starts");
  check(rt_start(B, 0, 1, 128, 0, "127.0.0.1") == 1, "starting again while running is a no-op");
  check(field(rt_status(B), "", "bind") == "\"" + std::string(pb) + "\"", "B is bound where its JSON said");
  RtLink *bad = rt_new();
  check(rt_start(bad, 0, 1, 128, 47394, "192.168.1.5") == 0, "a non-Tailscale address isn't bound");

  // the test clock: a block every 256/48000 s, in real time (AOO's drift filter reads the times)
  const int secs = 11, blocks = secs * SR / LEN, start_blk = 2 * SR / LEN, mute_blk = 5 * SR / LEN, fix_blk = 11 * SR / LEN / 2;
  // (Mute me and talkback, StudioSync_LiveAudioSend: C's send off at 7 s, on at 7.8 s; B left out at 8.6 s, let back in at 9.6 s. James, rt)
  auto at = [&](double s) { return (int)(s * SR / LEN); };
  const int smute = at(7.0), sun = at(7.8), tb_out = at(8.6), tb_in = at(9.6);
  std::vector<double> ia(LEN), ib(LEN, 0.0), ic(LEN), oa(LEN), ob(LEN), ob2(LEN), oc(LEN), heard;
  heard.reserve((size_t)blocks * LEN);
  const double *ina[1] = { ia.data() }, *inb[1] = { ib.data() }, *inc[1] = { ic.data() };
  double *outa[2] = { oa.data(), oa.data() }, *outb[2] = { ob.data(), ob2.data() }, *outc[2] = { oc.data(), oc.data() };
  const auto t0 = std::chrono::steady_clock::now();
  long long n = 0;
  for (int b = 0; b < blocks; ++b) {
    const auto due = t0 + std::chrono::nanoseconds((long long)(1e9 * b * LEN / SR));
    while (std::chrono::steady_clock::now() < due) std::this_thread::yield();
    for (int k = 0; k < LEN; ++k, ++n) {
      ia[k] = b >= start_blk ? 0.5 * sin(2 * PI * 440 * n / SR) : 0.0;
      ic[k] = 0.8 * sin(2 * PI * 1000 * n / SR);
    }
    if (b == mute_blk) check(rt_peer_set(B, pa, 1.0, 1) == 1, "B mutes A");
    if (b == fix_blk) check(rt_peers(C, cfg("studio \\\"secret\\\"", PC, qb).c_str()) == 1, "C gets the right secret while running");
    if (b == smute) check(rt_send(C, "", 0) == 1, "C mutes what it sends");
    if (b == sun) check(rt_send(C, "", 1) == 1, "C unmutes");
    if (b == tb_out) check(rt_send(C, pb, 0) == 1 && rt_send(C, "127.0.0.1:1", 0) == 0, "C leaves B out (a peer not in its list: 0)");
    if (b == tb_in) check(rt_send(C, pb, 1) == 1, "C lets B back in");
    std::fill(oa.begin(), oa.end(), 0.0); std::fill(ob.begin(), ob.end(), 0.0); std::fill(ob2.begin(), ob2.end(), 0.0); std::fill(oc.begin(), oc.end(), 0.0);
    rt_capture(A, ina, 1, LEN, SR); rt_capture(B, inb, 1, LEN, SR); rt_capture(C, inc, 1, LEN, SR);
    rt_mix(A, outa, 2, LEN, SR); rt_mix(B, outb, 2, LEN, SR); rt_mix(C, outc, 2, LEN, SR);
    heard.insert(heard.end(), ob.begin(), ob.end());
    if (b == start_blk - 1) {
      double pk = 0;
      for (double v : heard) pk = std::max(pk, std::fabs(v));
      check(pk < 0.01, "before A plays, B hears nothing (nothing of C's tone either)");
    }
  }
  const std::string sa = rt_status(A), sb = rt_status(B), sc = rt_status(C);
  printf("A: %s\nB: %s\nC: %s\n", sa.c_str(), sb.c_str(), sc.c_str());

  // latency: the first sample past 0.1 after A started, against when A started
  long long first = -1;
  for (size_t i = (size_t)start_blk * LEN; i < heard.size() && first < 0; ++i) if (std::fabs(heard[i]) > 0.1) first = (long long)i;
  const double lat_ms = first < 0 ? -1 : (first - (double)start_blk * LEN) * 1000.0 / SR;
  printf("     A -> B: heard %.1f ms after it was played (the jitter buffer is 30 ms of that)\n", lat_ms);
  check(first >= 0 && lat_ms < 150, "A's sine reaches B within 150 ms");
  // level: the steady part (4-5 s), against 0.5 sent
  double pk = 0, sum = 0;
  const size_t a0 = (size_t)4 * SR, a1 = (size_t)5 * SR - LEN;
  for (size_t i = a0; i < a1; ++i) { pk = std::max(pk, std::fabs(heard[i])); sum += heard[i] * heard[i]; }
  const double rms = sqrt(sum / (double)(a1 - a0));
  printf("     B hears A at peak %.3f, rms %.3f (sent: peak 0.500, rms 0.354)\n", pk, rms);
  check(pk > 0.4 && pk < 0.65 && rms > 0.28 && rms < 0.43, "at the level it was sent (Opus 128 kbit/s, within 2 dB)");
  double after = 0, fixed = 0;
  for (size_t i = (size_t)(mute_blk + 20) * LEN; i < (size_t)fix_blk * LEN; ++i) after = std::max(after, std::fabs(heard[i]));
  check(after < 0.01, "muted on B: silent there");
  // (10 s, not 7: C's fix comes at 5.5 s and the macOS CI runner heard nothing from C in the 1.5 s after it. Now 4.5 s, and how long it took)
  long long fix_first = -1;
  for (size_t i = (size_t)fix_blk * LEN; i < heard.size(); ++i) {
    fixed = std::max(fixed, std::fabs(heard[i]));
    if (fix_first < 0 && std::fabs(heard[i]) > 0.6) fix_first = (long long)i;
  }
  printf("     B hears C at peak %.3f once C has the right secret (sent: 0.800), first %.0f ms after the fix\n", fixed,
         fix_first < 0 ? -1.0 : (fix_first - (double)fix_blk * LEN) * 1000.0 / SR);
  check(fixed > 0.6, "with the right secret C is heard on B");
  auto peak = [&](int b0, int b1) { double p = 0; for (size_t i = (size_t)b0 * LEN; i < (size_t)b1 * LEN && i < heard.size(); ++i) p = std::max(p, std::fabs(heard[i])); return p; };
  auto first_loud = [&](int b0) { for (size_t i = (size_t)b0 * LEN; i < heard.size(); ++i) if (std::fabs(heard[i]) > 0.6) return (i - (double)b0 * LEN) * 1000.0 / SR; return -1.0; };
  printf("     C muted: B hears peak %.3f; unmuted: heard again after %.0f ms; B left out: peak %.3f; let back in: heard after %.0f ms\n",
         peak(smute + at(0.2), sun), first_loud(sun), peak(tb_out + at(0.3), tb_in), first_loud(tb_in));
  check(peak(smute + at(0.2), sun) < 0.01, "C muted: B hears silence from it");
  check(first_loud(sun) >= 0 && first_loud(sun) < 150, "C unmuted: heard again within 150 ms (the stream was kept)");
  check(peak(tb_out + at(0.3), tb_in) < 0.01, "C left B out: B hears nothing of it");
  check(first_loud(tb_in) >= 0 && first_loud(tb_in) < 1000, "C let B back in: heard again within a second");
  check(field(sb, pa, "streaming") == "true", "B's status: A is streaming");
  check(std::stod("0" + field(sb, pa, "rtt_ms")) >= 0 && field(sb, pa, "rtt_ms") != "-1.0", "B's status: a round trip to A");
  check(field(sb, pa, "latency_ms") != "-1.0" && field(sb, pa, "buffer_ms") != "-1.0", "B's status: A's latency and jitter buffer");
  check(field(sb, pa, "mute") == "true", "B's status: A muted");
  check(atoll(field(sb, "", "rejected").c_str()) > 0 && field(sb, "", "last_reject") == "\"wrong studio secret\"", "B refused C's datagrams: wrong studio secret");
  check(field(sb, pc, "streaming") == "true", "and B's status has C streaming now");
  check(atoll(field(sc, "", "rejected").c_str()) > 0, "and C refuses B's (the secret works both ways)");
  check(field(sb, "", "last_reject_from") == "\"" + std::string(pc) + "\"", "and B's status says which address it refused (C's)");
  check(atoll(field(sa, "", "sent").c_str()) > 500, "A sent its packets");
  rt_stop(A); rt_stop(B); rt_stop(C);
  check(field(rt_status(B), "", "running") == "false", "stopped");
  check(rt_start(B, 0, 2, 64, 0, "127.0.0.1") == 1, "and starts again on the same port");
  rt_stop(B);

  // ---- Wi-Fi's bursts (James, rt): the MacBook's stream flapped on every receiver against the fixed 30 ms buffer (underruns ~2/s). D sends a
  // sine to E, and E's receive thread reads nothing for 20-60 ms at a time, every 40-150 ms, from 1 s to 9 s: the packets wait in the socket
  // and come all at once, as over Wi-Fi. E's adaptive buffer grows on the first underruns and then holds: after settling (4.5 s) no more
  // underruns, and "streaming" stays true. Then the bursts stop, D goes quiet at 9.5 s, and the buffer shrinks back (its timings 20x faster
  // here: the first shrink after 0.75 s steady, then one every 0.5 s; a size that underran is retried after 6 s).
  {
    const int PD = 47395, PE = 47396;
    char pd[32], pe[32];
    snprintf(pd, sizeof pd, "127.0.0.1:%d", PD); snprintf(pe, sizeof pe, "127.0.0.1:%d", PE);
    RtLink *D = rt_new(), *E = rt_new();
    rt_peers(D, cfg("studio", PD, std::string("\"") + pe + "\"").c_str());
    rt_peers(E, cfg("studio", PE, std::string("\"") + pd + "\"").c_str());
    check(rt_start(D, 0, 1, 128, 0, "127.0.0.1") == 1 && rt_start(E, 0, 1, 128, 0, "127.0.0.1") == 1, "bursts: D and E start");
    rt_test_speed(E, 20);
    const int total = at(16.0), b_on = at(1.0), b_off = at(9.0), settled = at(4.5), quiet = at(9.5);
    std::vector<double> id(LEN), ie(LEN, 0.0), od(LEN), oe(LEN);
    const double *ind[1] = { id.data() }, *ine[1] = { ie.data() };
    double *outd[2] = { od.data(), od.data() }, *oute[2] = { oe.data(), oe.data() };
    unsigned rng = 12345;
    auto rnd = [&](double lo, double hi) { rng = rng * 1103515245u + 12345u; return lo + (hi - lo) * ((rng >> 8) & 0xffff) / 65535.0; };
    double next_hold = 0, grown = 0;
    long long u_settled = -1, u_off = -1, n2 = 0;
    bool flapped = false, set_ok = false;
    // (what this machine does to a 20 ms sleep: the hold is one, and the macOS CI runner is a VM with long stalls)
    double sleep_max = 0;
    for (int i = 0; i < 5; ++i) {
      const auto s0 = std::chrono::steady_clock::now();
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
      sleep_max = std::max(sleep_max, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - s0).count());
    }
    printf("     bursts: a 20 ms sleep here takes up to %.1f ms\n", sleep_max);
    double late_max = 0; // (the test clock's own lateness since the last look: a stall of this process, not the network)
    long long u_last = 0;
    // (underruns after settling in a look whose test clock ran over the 30 ms floor late: this process stalled on top of the holds, not
    // the network. The hosted Mac: 79-97 ms with both of its late underruns, Linux ~1 ms; any other underrun still fails the check)
    long long u_stalled = 0;
    double stall_at = -1e9;
    std::string t_last;
    const auto t1 = std::chrono::steady_clock::now();
    for (int b = 0; b < total; ++b) {
      const auto due = t1 + std::chrono::nanoseconds((long long)(1e9 * b * LEN / SR));
      while (std::chrono::steady_clock::now() < due) std::this_thread::yield();
      late_max = std::max(late_max, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - due).count());
      const double now = (double)b * LEN / SR;
      if (b % at(0.25) == 0) { // (a line whenever E's buffer for D changes or underruns: the timeline the checks below read)
        const std::string s = rt_status(E), t = field(s, pd, "target_ms");
        const long long u = atoll(field(s, pd, "underruns").c_str());
        if (u != u_last || t != t_last) printf("       %5.2f s: underruns %lld, target %s ms, test clock late up to %.1f ms\n", now, u, t.c_str(), late_max);
        // (or in the look right after one: its catch-up's underrun lands there, the hosted Mac's 6.38 s stall of 45 ms and 6.62 s underrun, 2026-11-20)
        if (late_max > 30) stall_at = now;
        if (b > settled && b <= b_off && u > u_last && now - stall_at <= 0.26) u_stalled += u - u_last;
        u_last = u; t_last = t; late_max = 0;
      }
      for (int k = 0; k < LEN; ++k, ++n2) id[k] = b >= at(0.5) && b < quiet ? 0.5 * sin(2 * PI * 440 * n2 / SR) : 0.0;
      if (b >= b_on && b < b_off && now >= next_hold) { const double h = rnd(20, 60); rt_test_hold(E, h); next_hold = now + h / 1000 + rnd(0.04, 0.15); }
      if (b == at(0.8)) set_ok = rt_peer_buffer(E, pd, 30, 150) == 1 && rt_peer_buffer(E, "127.0.0.1:1", 30, 150) == 0;
      if (b >= settled && b <= b_off && b % at(0.25) == 0) {
        const std::string s = rt_status(E);
        if (u_settled < 0) u_settled = atoll(field(s, pd, "underruns").c_str());
        if (field(s, pd, "streaming") != "true") flapped = true;
        grown = std::max(grown, atof(field(s, pd, "target_ms").c_str()));
        if (b + at(0.25) > b_off) u_off = atoll(field(s, pd, "underruns").c_str());
      }
      std::fill(od.begin(), od.end(), 0.0); std::fill(oe.begin(), oe.end(), 0.0);
      rt_capture(D, ind, 1, LEN, SR); rt_capture(E, ine, 1, LEN, SR);
      rt_mix(D, outd, 2, LEN, SR); rt_mix(E, oute, 2, LEN, SR);
    }
    const std::string se = rt_status(E);
    const double after_ms = atof(field(se, pd, "target_ms").c_str());
    printf("E: %s\n     bursts: buffer grew to %.0f ms; underruns %lld at 4.5 s, %lld at 9 s (%lld as this process stalled); after the bursts and quiet: %.0f ms (floor %s)\n",
           se.c_str(), grown, u_settled, u_off, u_stalled, after_ms, field(se, pd, "floor_ms").c_str());
    check(set_ok, "bursts: a peer's floor and ceiling are set (a peer not in the list: 0)");
    check(grown > 30, "bursts: E's buffer for D grew past 30 ms");
    check(u_settled >= 0 && u_off - u_settled <= u_stalled, "bursts: after settling, no more underruns (but in a stall of this process over 30 ms)");
    check(!flapped, "bursts: D stays streaming on E throughout");
    check(after_ms < grown && after_ms >= 30, "bursts over and D quiet: the buffer shrank back (not below the floor)");
    rt_free(D); rt_free(E);
  }

  // ---- Play, the second stream (James, rt: "hear what a bandmate plays when they arm"). F's Talk is a quiet 440 Hz sine (0.2) on its input;
  // its Play is a loud 1 kHz one (0.7), written into hop 63's send ring each block before the post call, as the live out track's Hop does.
  // G hears both, and sets them apart: Talk off (Play heard), then Play off (Talk heard). Then F mutes Play (silence, the stream kept), the
  // live out track stops (play_alive false), and Play ends.
  {
    const int PF = 47397, PG = 47398, HOP = 63;
    char pf[32], pg[32];
    snprintf(pf, sizeof pf, "127.0.0.1:%d", PF); snprintf(pg, sizeof pg, "127.0.0.1:%d", PG);
    RtLink *F = rt_new(), *G = rt_new();
    rt_peers(F, cfg("studio", PF, std::string("\"") + pg + "\"").c_str());
    rt_peers(G, cfg("studio", PG, std::string("\"") + pf + "\"").c_str());
    check(rt_start(F, 0, 1, 128, 0, "127.0.0.1") == 1 && rt_start(G, 0, 1, 128, 0, "127.0.0.1") == 1, "play: F and G start");
    hop_map hm;
    hop_shm *ring = hop_shm_open(&hm, hop_reaper_pid(), HOP);
    check(ring != nullptr, "play: the test's own Hop mapping (the live out track's)");
    const int total = at(10.0), p_on = at(0.5), talk_off = at(3.0), play_off = at(5.0), pmute = at(7.0), ring_stop = at(8.0), p_end = at(8.6);
    std::vector<double> iff(LEN), ig(LEN, 0.0), of(LEN), og(LEN), og2(LEN), heard_g;
    std::vector<float> inter((size_t)LEN * 2);
    const double *inf[1] = { iff.data() }, *ing[1] = { ig.data() };
    double *outf[2] = { of.data(), of.data() }, *outg[2] = { og.data(), og2.data() }; // (G's left ear is what's checked)
    std::string mid_f, mid_g, dead_f;
    long long n3 = 0;
    const auto t2 = std::chrono::steady_clock::now();
    for (int b = 0; b < total; ++b) {
      const auto due = t2 + std::chrono::nanoseconds((long long)(1e9 * b * LEN / SR));
      while (std::chrono::steady_clock::now() < due) std::this_thread::yield();
      for (int k = 0; k < LEN; ++k, ++n3) {
        iff[k] = 0.2 * sin(2 * PI * 440 * n3 / SR);
        inter[2 * k] = inter[2 * k + 1] = (float)(0.7 * sin(2 * PI * 1000 * n3 / SR));
      }
      if (b == p_on) check(rt_play(F, HOP, 1) == 1, "play: F sends hop 63 as Play");
      if (b == talk_off) check(rt_peer_set(G, pf, 0.0, 0) == 1, "play: G turns F's Talk off");
      if (b == play_off) check(rt_peer_set(G, pf, 1.0, 0) == 1 && rt_peer_play(G, pf, 0.0) == 1 && rt_peer_play(G, "127.0.0.1:1", 1) == 0, "play: G turns F's Talk back, Play off");
      if (b == pmute) { rt_peer_play(G, pf, 1.0); check(rt_play(F, HOP, 0) == 1, "play: F mutes Play"); }
      if (b == at(4.5)) { mid_f = rt_status(F); mid_g = rt_status(G); }
      if (b == ring_stop + at(0.5)) dead_f = rt_status(F);
      if (b == p_end) rt_play(F, 0, 0);
      std::fill(of.begin(), of.end(), 0.0); std::fill(og.begin(), og.end(), 0.0); std::fill(og2.begin(), og2.end(), 0.0);
      rt_capture(F, inf, 1, LEN, SR); rt_capture(G, ing, 1, LEN, SR);
      if (ring && b < ring_stop) { // (the Hop's process(): its input into the send ring, then send_w)
        const uint64_t w = hop_load(&ring->send_w);
        hop_copy_in(ring->send, w, inter.data(), LEN);
        hop_store(&ring->send_w, w + LEN);
      }
      rt_mix(F, outf, 2, LEN, SR); rt_mix(G, outg, 2, LEN, SR);
      heard_g.insert(heard_g.end(), og.begin(), og.end());
    }
    const std::string end_f = rt_status(F);
    auto pk = [&](double s0, double s1) { double p = 0; for (size_t i = (size_t)(s0 * SR); i < (size_t)(s1 * SR) && i < heard_g.size(); ++i) p = std::max(p, std::fabs(heard_g[i])); return p; };
    printf("G (mid): %s\n     play: both %.3f, Talk off %.3f, Play off %.3f, Play muted %.3f (Talk 0.2, Play 0.7)\n", mid_g.c_str(), pk(2, 3), pk(3.5, 4.9), pk(5.5, 6.9), pk(7.5, 7.9));
    check(pk(2, 3) > 0.7, "play: G hears Talk and Play together");
    check(pk(3.5, 4.9) > 0.55 && pk(3.5, 4.9) < 0.85, "play: Talk off, G hears Play at its level");
    check(pk(5.5, 6.9) > 0.12 && pk(5.5, 6.9) < 0.3, "play: Play off, G hears only Talk");
    check(pk(7.5, 7.9) > 0.12 && pk(7.5, 7.9) < 0.3, "play: F muted Play, G hears only Talk (Play's level back up)");
    check(field(mid_f, "", "play") == "63" && field(mid_f, "", "play_alive") == "true" && atof(field(mid_f, "", "play_level").c_str()) > 0.6, "play: F's status: hop 63, alive, its level");
    check(field(mid_g, pf, "play_streaming") == "true" && field(mid_g, pf, "streaming") == "true", "play: G's status: F's Talk and Play both streaming");
    check(field(dead_f, "", "play_alive") == "false" && field(dead_f, "", "play") == "63", "play: the live out track stopped: play_alive false");
    check(field(end_f, "", "play") == "0", "play: ended, F's status says no Play");
    if (ring) { hop_shm_close(&hm); hop_shm_unlink(&hm); }
    rt_free(F); rt_free(G);
  }

  // ---- The hub's live mix (James, rt: docs/realtime-roadmap.md "More big ideas" 1). H is the hub, W, X, Y listen; each plays its own tone
  // (on a 256-sample DFT bin, so each is measured apart in a block of the mix: H 375 Hz at 0.2, W 750 Hz at 0.3, X 1125 Hz at 0.4, Y 1500 Hz
  // at 0.5). X turns W down to 0.5, Y turns X down to 0.25 (their own levels, peer to peer and then through the hub). W plays 1-2 s (its
  // onset heard directly) and from 5 s (heard through the hub: the extra hop). At 2.5 s H serves and the others take it as their hub; Y leaves
  // X out of what it sends 6.6-7.4 s (talkback, through the hub); at 8.5 s H stops dead, and the others go back to each other's streams.
  {
    const int P[4] = { 47401, 47402, 47403, 47404 };
    const double AMP[4] = { 0.2, 0.3, 0.4, 0.5 };
    const int BIN[4] = { 2, 4, 6, 8 };
    char nm[4][32];
    RtLink *L[4];
    for (int i = 0; i < 4; ++i) { snprintf(nm[i], sizeof nm[i], "127.0.0.1:%d", P[i]); L[i] = rt_new(); }
    for (int i = 0; i < 4; ++i) {
      std::string list;
      for (int j = 0; j < 4; ++j) if (j != i) list += std::string(list.empty() ? "" : ", ") + "\"" + nm[j] + "\"";
      rt_peers(L[i], cfg("studio", P[i], list).c_str());
    }
    bool started = true;
    for (int i = 0; i < 4; ++i) started = rt_start(L[i], 0, 1, 128, 0, "127.0.0.1") == 1 && started;
    check(started, "hub: H, W, X and Y start, each with the other three");
    const int total = at(10.5), w_on = at(1.0), w_off = at(2.0), w_on2 = at(5.0), hub_on = at(2.5), tb_out2 = at(6.6), tb_in2 = at(7.4), drop = at(8.5);
    std::vector<double> in[4], out[4], out2[4];
    for (int i = 0; i < 4; ++i) { in[i].assign(LEN, 0.0); out[i].assign(LEN, 0.0); out2[i].assign(LEN, 0.0); }
    std::vector<double> amp[4][4]; // [listener][source]: each block's level of that source's tone in what the listener hears (left)
    auto level_of = [&](const std::vector<double> &x, int bin) {
      double re = 0, im = 0;
      for (int k = 0; k < LEN; ++k) { re += x[k] * cos(2 * PI * bin * k / LEN); im -= x[k] * sin(2 * PI * bin * k / LEN); }
      return 2 * sqrt(re * re + im * im) / LEN;
    };
    long long sent_w[3] = { 0, 0, 0 };
    std::string s_h, s_w, s_x, s_y;
    std::thread stopper;
    long long n4 = 0;
    double hub_stall = 0; // (the test's own longest stall: the timing checks below are passed over in CI past 15 ms, check_unless_stalled)
    const auto t3 = std::chrono::steady_clock::now();
    for (int b = 0; b < total; ++b) {
      const auto due = t3 + std::chrono::nanoseconds((long long)(1e9 * b * LEN / SR));
      while (std::chrono::steady_clock::now() < due) std::this_thread::yield();
      hub_stall = std::max(hub_stall, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - due).count());
      for (int k = 0; k < LEN; ++k, ++n4)
        for (int i = 0; i < 4; ++i) {
          const bool on = i != 1 || (b >= w_on && b < w_off) || b >= w_on2;
          in[i][k] = on ? AMP[i] * sin(2 * PI * BIN[i] * (double)n4 / LEN) : 0.0;
        }
      if (b == at(0.5)) check(rt_peer_set(L[2], nm[1], 0.5, 0) == 1 && rt_peer_set(L[3], nm[2], 0.25, 0) == 1, "hub: X turns W to 0.5, Y turns X to 0.25");
      if (b == hub_on) {
        check(rt_hub(L[0], "", 1) == 1, "hub: H serves");
        for (int i = 1; i < 4; ++i) rt_hub(L[i], nm[0], 0);
      }
      if (b == tb_out2) check(rt_send(L[3], nm[2], 0) == 1, "hub: Y leaves X out (talkback through the hub)");
      if (b == tb_in2) rt_send(L[3], nm[2], 1);
      if (b == at(1.0)) sent_w[0] = atoll(field(rt_status(L[1]), "", "sent").c_str());
      if (b == at(2.0)) sent_w[0] = atoll(field(rt_status(L[1]), "", "sent").c_str()) - sent_w[0];
      if (b == at(5.5)) sent_w[1] = atoll(field(rt_status(L[1]), "", "sent").c_str());
      if (b == at(6.5)) sent_w[1] = atoll(field(rt_status(L[1]), "", "sent").c_str()) - sent_w[1];
      if (b == at(6.0)) { s_h = rt_status(L[0]); s_w = rt_status(L[1]); s_x = rt_status(L[2]); s_y = rt_status(L[3]); }
      if (b == drop) stopper = std::thread([&] { rt_stop(L[0]); }); // (the hub's REAPER gone: no goodbye. Its own thread: rt_stop waits for its receive thread, up to 100 ms, and the others' clock mustn't)
      for (int i = 0; i < 4; ++i) { std::fill(out[i].begin(), out[i].end(), 0.0); std::fill(out2[i].begin(), out2[i].end(), 0.0); }
      for (int i = 0; i < 4; ++i) { const double *ii[1] = { in[i].data() }; rt_capture(L[i], ii, 1, LEN, SR); }
      for (int i = 0; i < 4; ++i) { double *oo[2] = { out[i].data(), out2[i].data() }; rt_mix(L[i], oo, 2, LEN, SR); }
      for (int i = 1; i < 4; ++i) for (int j = 0; j < 4; ++j) amp[i][j].push_back(level_of(out[i], BIN[j]));    }
    if (stopper.joinable()) stopper.join();
    const std::string end_x = rt_status(L[2]);
    printf("H (6 s): %s\nX (6 s): %s\n", s_h.c_str(), s_x.c_str());
    auto avg = [&](int li, int src, double s0, double s1) { double s = 0; int c = 0; for (int b = at(s0); b < at(s1) && b < (int)amp[li][src].size(); ++b) { s += amp[li][src][b]; ++c; } return c ? s / c : 0.0; };
    auto about = [](double v, double want) { return v > want * 0.75 && v < want * 1.25; };
    // each listener's levels: X hears W at 0.5 x 0.3, Y hears X at 0.25 x 0.4, everyone else as sent; peer to peer, then through the hub
    const double want[4][4] = { { 0, 0, 0, 0 }, { 0.2, 0, 0.4, 0.5 }, { 0.2, 0.15, 0, 0.5 }, { 0.2, 0.3, 0.1, 0 } };
    bool lv_direct = true, lv_hub = true;
    for (int li = 1; li < 4; ++li) {
      printf("     hub: %s hears", li == 1 ? "W" : li == 2 ? "X" : "Y");
      for (int s = 0; s < 4; ++s) {
        if (s == li) continue;
        const double d = avg(li, s, 1.3, 1.9), h = avg(li, s, 5.5, 6.5);
        if (!about(d, want[li][s])) lv_direct = false; // (W plays only 1-2 s and from 5 s: everyone's direct level read in 1.3-1.9 s)
        if (!about(h, want[li][s])) lv_hub = false;
        printf(" %s %.3f direct / %.3f through H (want %.2f);", s == 0 ? "H" : s == 1 ? "W" : s == 2 ? "X" : "Y", d, h, want[li][s]);
      }
      printf("\n");
    }
    printf("     hub: the test's own longest stall %.0f ms\n", hub_stall);
    // (rt-ci3: a stall inside the 0.6 s the direct levels are read in takes the same share off all nine: 63-66% each in CI run 44820984871)
    check_unless_stalled(lv_direct, hub_stall, "hub: peer to peer, each listener hears each at its own level (within 25%)");
    check_unless_stalled(field(s_x, "hub", "state") == "\"hub\"" && field(s_w, "hub", "state") == "\"hub\"" && field(s_y, "hub", "state") == "\"hub\"",
          hub_stall, "hub: W, X and Y hear through H by 6 s");
    check_unless_stalled(field(s_h, "hub", "serving") == "3" && field(s_h, "hub", "serve") == "true", hub_stall, "hub: H mixes for the three");
    check(lv_hub, "hub: through H, each listener still hears each at its own level (H's mix per listener, within 25%)");
    check_unless_stalled(field(s_w, nm[2], "direct") == "false" && field(s_w, nm[3], "direct") == "false" && field(s_w, nm[0], "direct") == "true",
          hub_stall, "hub: W sends its stream only to H (X and Y hear it through H)");
    printf("     hub: W sent %lld datagrams in a second peer to peer (to H, X, Y), %lld through H; by 6 s the mix paused enough to ask for streams back: W %s, X %s, Y %s times\n",
           sent_w[0], sent_w[1], field(s_w, "hub", "rescues").c_str(), field(s_x, "hub", "rescues").c_str(), field(s_y, "hub", "rescues").c_str());
    check_unless_stalled(sent_w[1] > 0 && sent_w[1] * 2 < sent_w[0], hub_stall, "hub: W sends less than half as much through the hub (one stream instead of three)");
    // the extra hop: W's onset heard on X directly (1 s) and through H (5 s)
    auto onset = [&](int b0) { for (int b = b0; b < b0 + at(0.5) && b < (int)amp[2][1].size(); ++b) if (amp[2][1][b] > 0.075) return (b - b0) * 1000.0 * LEN / SR; return -1.0; };
    const double on_d = onset(w_on), on_h = onset(w_on2);
    printf("     hub: W's onset on X: %.0f ms directly, %.0f ms through H (+%.0f ms: the hub's hop); X's status says %s ms through H, %s ms directly; H's load %s of a core, %s us a block at most\n",
           on_d, on_h, on_h - on_d, field(s_x, "hub", "latency_ms").c_str(), field(s_x, "hub", "direct_ms").c_str(), field(s_h, "hub", "load").c_str(), field(s_h, "hub", "max_us").c_str());
    // (rt-ci3: a 381 ms stall of the test sent W and X back to direct streams before W's second onset: 43 ms both ways, +0. CI run 44825802025)
    check_unless_stalled(on_d >= 0 && on_h > on_d && on_h < on_d + 120, hub_stall, "hub: the hop through H adds a little latency (under 120 ms)");
    check(atof(field(s_x, "hub", "latency_ms").c_str()) > atof(field(s_x, "hub", "direct_ms").c_str()) && atof(field(s_x, "hub", "direct_ms").c_str()) > 0,
          "hub: X's status measures both (through H, and directly before)");
    check_unless_stalled(atof(field(s_h, "hub", "load").c_str()) > 0 && atof(field(s_h, "hub", "load").c_str()) < 0.5, hub_stall, "hub: H's mixing measured, well under half a core");
    // talkback through the hub: Y leaves X out, so X's mix has no Y, W's still has
    const double tb_x = avg(2, 3, 6.9, 7.3), tb_w = avg(1, 3, 6.9, 7.3), back_x = avg(2, 3, 7.8, 8.3);
    printf("     hub: Y left X out: X hears Y at %.3f, W at %.3f; let back in: X at %.3f\n", tb_x, tb_w, back_x);
    check(tb_x < 0.05 && about(tb_w, 0.5) && about(back_x, 0.5), "hub: talkback through H (Y left out of X's mix only, then back)");
    // the hub drops: the longest stretch X hears no Y after 8.5 s, and everyone heard again directly
    auto gap = [&](int li, int src, double s0, double s1, double thr) { int run = 0, best = 0; for (int b = at(s0); b < at(s1); ++b) { run = amp[li][src][b] < thr ? run + 1 : 0; best = std::max(best, run); } return best * 1000.0 * LEN / SR; };
    const double g_in = gap(2, 3, 2.4, 4.5, 0.25), g_drop = gap(2, 3, 8.4, 9.6, 0.25), g_drop_w = gap(1, 3, 8.4, 9.6, 0.25);
    printf("     hub: X's longest gap in Y: %.0f ms switching to H, %.0f ms when H dropped (W's: %.0f ms); X's buffer for H %s ms, fallbacks %s\n", g_in, g_drop, g_drop_w,
           field(end_x, nm[0], "target_ms").c_str(), field(end_x, "hub", "fallbacks").c_str());
    check_unless_stalled(g_in < 30, hub_stall, "hub: no gap switching to the hub (its mix flows before it's heard)");
    // (measured here: 16-21 ms, under the 30 ms buffer: the streams were asked back while the mix's buffer played. 60: the macOS CI runner's stalls)
    check_unless_stalled(g_drop < 60 && g_drop_w < 60, hub_stall, "hub: H dropping leaves a gap of about a jitter buffer at most, then each other's streams at full level");
    check(about(avg(2, 3, 9.8, 10.4), 0.5) && about(avg(2, 1, 9.8, 10.4), 0.15) && avg(2, 0, 9.8, 10.4) < 0.05, "hub: after the drop X hears Y and W directly at its own levels (and no H)");
    check_unless_stalled(field(end_x, "hub", "state") == "\"direct\"" && field(end_x, "hub", "fallbacks") == "1", hub_stall, "hub: X's status: direct, one fallback");
    for (int i = 0; i < 4; ++i) rt_free(L[i]);
  }
  not_here_test();
  start_order_test(); // (the four-computer test's start order: a hub whose list leaves a computer out)
  drift_tests(); // (the four-computer test's underruns: drift, a buffer left high, a hub switch)
  trim_test();
  play_resync_test(); // (Play's resync after a buffer left high, its counters, the ears tap: rt-p11)
  switch_test();
  rescue_test();
  stall_test(); // (a listener on a VM: its own threads held, not the hub gone)
  outage_test(); // (a listener's own Wi-Fi outage: kept on the mix. rt-p9)
  spike_tests();
  clock_tests();
  rate_test(); // (a receiver whose clock estimate is off: the read-rate servo. rt-fix6b)
  device_test(); // (a device that doesn't keep its rate: the desktop's. rt-audio3)
  vm_test(); // (a VM: its callbacks ten at once, the guest held, its times wrong. rt-audio3)
  hub_loads(false); // (the hub's load at REAPER's small blocks, as the laptop's ASIO runs: 128 and 64 samples)
  rt_free(A); rt_free(B); rt_free(C); rt_free(bad);
  printf(fails ? "fails %d\n" : "ok, fails 0\n", fails);
  return fails ? 1 : 0;
}
