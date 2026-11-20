// StudioSync's audio spike (docs/realtime-roadmap.md step 4, 1.0.8): nothing happens until StudioSync_DirectAudioStart. Then REAPER's
// audio hook (Audio_RegHardwareHook, reaper_plugin.h audio_hook_register_t) copies the chosen hardware inputs, before REAPER's processing,
// into a lock-free single-producer/single-consumer ring: on the audio thread no allocation, no lock, no REAPER API, no file, a fixed
// amount of work per buffer. Peaks go out through atomics; a worker thread drains the ring into a 32-bit float WAV (the test writer).
// The plan for Opus/FLAC/PCM over UDP with a jitter buffer: docs/realtime-roadmap.md "Step 4 spike: findings and plan". GPL-3.0-or-later.
#ifdef _WIN32
#define NOMINMAX
#endif
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include "direct.h"
#ifdef _WIN32
#include <windows.h>
#endif

namespace {
const int MAX_CH = 8;
const size_t RING_FRAMES = 1 << 19; // (about 11 s at 48 kHz: a power of two, so a position is taken modulo with a mask)
float *g_ring = nullptr;            // RING_FRAMES * g_nch floats, allocated before the hook goes in and freed after it's out
int g_first = 0, g_nch = 0;
std::atomic<bool> g_on{ false }, g_consuming{ false };
std::atomic<int> g_in_cb{ 0 };
std::atomic<size_t> g_w{ 0 }, g_r{ 0 }; // frames written (audio thread) and read (the worker): only ever grow
std::atomic<float> g_peak[MAX_CH];
std::atomic<long long> g_callbacks{ 0 }, g_frames{ 0 }, g_overruns{ 0 }, g_max_ns{ 0 };
std::atomic<double> g_srate{ 0 };
std::atomic<int> g_inputs{ 0 };
// the dump (main thread starts it, its worker runs it)
std::thread g_dump_thr;
std::atomic<int> g_dump_state{ 0 }; // 0 none, 1 writing, 2 done, 3 failed
std::atomic<long long> g_dump_frames{ 0 };
std::atomic<bool> g_dump_stop{ false };
std::string g_dump_path, g_status_out;
std::mutex g_api_mx; // (main-thread API calls only: never the audio thread)

void le16(FILE *f, unsigned v) { fputc(v & 255, f); fputc((v >> 8) & 255, f); }
void le32(FILE *f, unsigned v) { le16(f, v & 0xffff); le16(f, v >> 16); }
void wav_header(FILE *f, int nch, int srate, unsigned frames, int bits = 32) // 32-bit float (format 3), or 16-bit PCM (Jam's), as every DAW reads
{
  const unsigned bytes = (unsigned)bits / 8, data = frames * (unsigned)nch * bytes;
  fseek(f, 0, SEEK_SET);
  fwrite("RIFF", 1, 4, f); le32(f, 36 + data); fwrite("WAVEfmt ", 1, 8, f); le32(f, 16);
  le16(f, bits == 32 ? 3 : 1); le16(f, (unsigned)nch); le32(f, (unsigned)srate); le32(f, (unsigned)srate * nch * bytes); le16(f, (unsigned)nch * bytes); le16(f, (unsigned)bits);
  fwrite("data", 1, 4, f); le32(f, data);
}
FILE *open_w(const std::string &p)
{
#ifdef _WIN32
  const int n = MultiByteToWideChar(CP_UTF8, 0, p.c_str(), -1, nullptr, 0);
  std::wstring w(n > 0 ? n : 1, L'\0');
  if (n > 0) MultiByteToWideChar(CP_UTF8, 0, p.c_str(), -1, &w[0], n);
  return _wfopen(w.c_str(), L"wb");
#else
  return fopen(p.c_str(), "wb");
#endif
}

void dump_loop(std::string path, double seconds)
{
  for (int i = 0; i < 200 && g_srate.load() <= 0 && !g_dump_stop; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(10));
  const double sr = g_srate.load();
  FILE *f = sr > 0 ? open_w(path) : nullptr;
  if (!f) { g_dump_state = 3; return; }
  const int nch = g_nch, srate = (int)sr;
  const long long want = (long long)(seconds * srate);
  wav_header(f, nch, srate, 0);
  g_r.store(g_w.load(std::memory_order_acquire), std::memory_order_release); // (from now: nothing stale)
  g_consuming.store(true, std::memory_order_release);
  long long got = 0;
  const auto give_up = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds + 5);
  bool ok = true;
  while (got < want && !g_dump_stop && std::chrono::steady_clock::now() < give_up) {
    const size_t r = g_r.load(std::memory_order_relaxed), w = g_w.load(std::memory_order_acquire);
    const size_t n = std::min<size_t>(w - r, (size_t)(want - got));
    if (n == 0) { std::this_thread::sleep_for(std::chrono::milliseconds(5)); continue; }
    const size_t at = r & (RING_FRAMES - 1), run = std::min(n, RING_FRAMES - at); // (up to the ring's end; the next pass goes on from its start)
    ok = fwrite(g_ring + at * nch, sizeof(float) * nch, run, f) == run && ok;
    g_r.store(r + run, std::memory_order_release);
    got += (long long)run;
    g_dump_frames = got;
  }
  g_consuming.store(false, std::memory_order_release);
  wav_header(f, nch, srate, (unsigned)got);
  ok = fclose(f) == 0 && ok;
  g_dump_state = ok && got == want ? 2 : 3;
}
} // namespace

// The audio thread (REAPER's, or the test's): a fixed amount of work for `len` frames. Nothing here waits, allocates or calls out.
void direct_audio_process(const double *const *in, int nin, int len, double srate)
{
  if (!g_on.load(std::memory_order_acquire) || len <= 0) return;
  const auto t0 = std::chrono::steady_clock::now();
  g_callbacks.fetch_add(1, std::memory_order_relaxed);
  g_srate.store(srate, std::memory_order_relaxed);
  g_inputs.store(nin, std::memory_order_relaxed);
  const int nch = g_nch;
  const double *src[MAX_CH];
  for (int c = 0; c < nch; ++c) {
    const int i = g_first + c;
    src[c] = i < nin ? in[i] : nullptr;
    float pk = 0;
    if (src[c]) for (int k = 0; k < len; ++k) pk = std::max(pk, (float)std::fabs(src[c][k]));
    if (pk > g_peak[c].load(std::memory_order_relaxed)) g_peak[c].store(pk, std::memory_order_relaxed); // (a reset racing this: one buffer's peak lost)
  }
  if (g_consuming.load(std::memory_order_acquire)) { // (nobody reading: nothing written, nothing counted as lost)
    const size_t w = g_w.load(std::memory_order_relaxed), r = g_r.load(std::memory_order_acquire);
    size_t n = (size_t)len;
    const size_t space = RING_FRAMES - (w - r);
    if (n > space) { g_overruns.fetch_add((long long)(n - space), std::memory_order_relaxed); n = space; }
    for (size_t k = 0; k < n; ++k) {
      float *dst = g_ring + ((w + k) & (RING_FRAMES - 1)) * nch;
      for (int c = 0; c < nch; ++c) dst[c] = src[c] ? (float)src[c][k] : 0.f;
    }
    g_w.store(w + n, std::memory_order_release);
    g_frames.fetch_add((long long)n, std::memory_order_relaxed);
  }
  const long long ns = (long long)std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - t0).count();
  if (ns > g_max_ns.load(std::memory_order_relaxed)) g_max_ns.store(ns, std::memory_order_relaxed);
}

// ---- Jam (docs/rt/rt-jam.md, lib/jam.lua; James 2026-11-20: classic NINJAM play-along built in) ------------------------------------------
// While the transport plays, live audio's Play feed (the armed tracks post-FX, after Mute me: rtaudio.cpp play_feed hands it over through
// rt_play_tap) goes into a ring on the audio thread, and a worker writes it to a growing 16-bit stereo WAV that the direct link streams as it
// grows (its receiver keeps the copy playable). Each block's play position comes with it: a block that doesn't start where the last one ended
// (play, a seek, a loop, a dropped block) starts a segment { file frame, position }, so the others can place every interval on its bar. The
// audio thread allocates nothing, locks nothing and writes no file. Nothing runs until StudioSync_JamStart.
namespace {
const size_t JAM_RING = 1 << 18; // frames, stereo (about 5 s at 48 kHz; the worker drains it every 10 ms)
const int JAM_SEGS = 32;
const double JAM_JUMP = 0.002; // s
struct JamSeg { long long n0; double p0; };
float *g_jring = nullptr;
std::atomic<bool> g_jon{ false }, g_jstop{ false }, g_jrate_changed{ false };
std::atomic<int> g_jin_cb{ 0 }, g_jstate{ 0 }; // (state: 0 none, 1 writing, 2 done, 3 failed)
std::atomic<size_t> g_jw{ 0 }, g_jr{ 0 };
std::atomic<long long> g_jdropped{ 0 }, g_jfile_frames{ 0 }, g_jsegs{ 0 };
std::atomic<double> g_jsr{ 0 };
JamSeg g_jseg[JAM_SEGS];
bool g_jlast_ok = false; // (the audio thread's, while g_jon)
double g_jlast_end = 0;
std::thread g_jthr;
std::string g_jstatus;
std::mutex g_jmx; // (main-thread API calls only)

void jam_loop(std::string path)
{
  while (g_jsr.load() <= 0 && !g_jstop) std::this_thread::sleep_for(std::chrono::milliseconds(10)); // (its rate comes with the first block)
  FILE *f = g_jstop ? nullptr : open_w(path);
  if (!f) { g_jstate = 3; return; }
  const int sr = (int)g_jsr.load();
  wav_header(f, 2, sr, 0, 16);
  fflush(f);
  static short buf[4096 * 2];
  long long frames = 0;
  bool ok = true;
  for (;;) {
    const bool last = g_jstop.load(); // (read before draining: whatever came before the stop is written)
    const size_t r = g_jr.load(std::memory_order_relaxed), w = g_jw.load(std::memory_order_acquire);
    if (w == r) { if (last) break; std::this_thread::sleep_for(std::chrono::milliseconds(10)); continue; }
    const size_t n = std::min<size_t>(w - r, 4096);
    for (size_t k = 0; k < n; ++k) {
      const float *s = g_jring + ((r + k) & (JAM_RING - 1)) * 2;
      for (int c = 0; c < 2; ++c) buf[k * 2 + c] = (short)std::lround(std::max(-1.f, std::min(1.f, s[c])) * 32767.f);
    }
    g_jr.store(r + n, std::memory_order_release);
    ok = fwrite(buf, 4, n, f) == n && ok;
    fflush(f); // (the link reads the file by its size: every 10 ms of it is there to send)
    frames += (long long)n;
    g_jfile_frames = frames;
  }
  wav_header(f, 2, sr, (unsigned)frames, 16); // (the real sizes at the end: the link sends the header last)
  ok = fclose(f) == 0 && ok;
  g_jstate = ok ? 2 : 3;
}
} // namespace

void direct_jam_feed(const float *const *ch, int nch, int len, double srate, double pos, bool playing)
{
  g_jin_cb.fetch_add(1, std::memory_order_acq_rel);
  if (g_jon.load(std::memory_order_acquire) && ch && nch > 0 && ch[0] && len > 0 && srate > 0) {
    const double sr0 = g_jsr.load(std::memory_order_relaxed);
    if (sr0 == 0) g_jsr.store(srate, std::memory_order_relaxed);
    if (sr0 != 0 && sr0 != srate) g_jrate_changed.store(true, std::memory_order_relaxed); // (the file's rate is fixed: Lua starts a new run)
    else if (!playing) g_jlast_ok = false; // (nothing written while stopped)
    else {
      const size_t w = g_jw.load(std::memory_order_relaxed), r = g_jr.load(std::memory_order_acquire);
      if (JAM_RING - (w - r) < (size_t)len) { g_jdropped.fetch_add(len, std::memory_order_relaxed); g_jlast_ok = false; } // (a whole block, so the next starts a segment)
      else {
        if (!g_jlast_ok || std::fabs(pos - g_jlast_end) > JAM_JUMP) {
          const long long c = g_jsegs.load(std::memory_order_relaxed);
          g_jseg[c % JAM_SEGS] = { (long long)w, pos };
          g_jsegs.store(c + 1, std::memory_order_release);
        }
        g_jlast_ok = true;
        g_jlast_end = pos + len / srate;
        const float *L = ch[0], *R = nch > 1 && ch[1] ? ch[1] : ch[0];
        for (int k = 0; k < len; ++k) {
          float *d = g_jring + ((w + (size_t)k) & (JAM_RING - 1)) * 2;
          d[0] = L[k]; d[1] = R[k];
        }
        g_jw.store(w + (size_t)len, std::memory_order_release);
      }
    }
  }
  g_jin_cb.fetch_sub(1, std::memory_order_acq_rel);
}

static void jam_hook(bool add);
int direct_jam_start(const char *path)
{
  std::lock_guard<std::mutex> l(g_jmx);
  if (g_jon || !path || !*path) return 0;
  if (g_jthr.joinable()) g_jthr.join();
  g_jring = new (std::nothrow) float[JAM_RING * 2];
  if (!g_jring) return 0;
  g_jw = 0; g_jr = 0; g_jdropped = 0; g_jfile_frames = 0; g_jsegs = 0; g_jsr = 0; g_jrate_changed = false; g_jstop = false;
  g_jlast_ok = false;
  g_jstate = 1;
  g_jthr = std::thread(jam_loop, std::string(path));
  g_jon.store(true, std::memory_order_release);
  jam_hook(true);
  return 1;
}

void direct_jam_stop()
{
  std::lock_guard<std::mutex> l(g_jmx);
  if (!g_jon && !g_jthr.joinable()) return;
  g_jon.store(false, std::memory_order_release);
  jam_hook(false);
  for (int i = 0; i < 200 && g_jin_cb.load() > 0; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(1)); // (a block mid-flight finishes)
  g_jstop = true;
  if (g_jthr.joinable()) g_jthr.join();
  delete[] g_jring;
  g_jring = nullptr;
}

const char *direct_jam_status()
{
  std::lock_guard<std::mutex> l(g_jmx);
  static const char *states[] = { "none", "writing", "done", "failed" };
  char b[256];
  snprintf(b, sizeof(b), "{\"on\":%s,\"state\":\"%s\",\"srate\":%.0f,\"frames\":%lld,\"fed\":%lld,\"dropped\":%lld,\"rate_changed\":%s,\"segs\":[",
           g_jon ? "true" : "false", states[g_jstate.load() & 3], g_jsr.load(), g_jfile_frames.load(), (long long)g_jw.load(), g_jdropped.load(),
           g_jrate_changed ? "true" : "false");
  g_jstatus = b;
  // (the newest JAM_SEGS - 1, each [index, file frame, position]; one the audio thread may be writing over is left out by reading the count again)
  const long long c = g_jsegs.load(std::memory_order_acquire);
  JamSeg got[JAM_SEGS];
  const long long from = std::max(0LL, c - (JAM_SEGS - 1));
  for (long long i = from; i < c; ++i) got[i % JAM_SEGS] = g_jseg[i % JAM_SEGS];
  const long long safe = std::max(from, g_jsegs.load(std::memory_order_acquire) - (JAM_SEGS - 1));
  for (long long i = safe; i < c; ++i) {
    snprintf(b, sizeof(b), "%s[%lld,%lld,%.9f]", i > safe ? "," : "", i, got[i % JAM_SEGS].n0, got[i % JAM_SEGS].p0);
    g_jstatus += b;
  }
  g_jstatus += "]}";
  return g_jstatus.c_str();
}

#ifdef DIRECT_STANDALONE
static void jam_hook(bool) {}
#endif

#ifndef DIRECT_STANDALONE
#include "reaper_plugin.h"
#ifdef min // (SWELL, macOS/Linux: min/max as macros broke std::min and the C++ headers after it. CI, 2026-11-19)
#undef min
#endif
#ifdef max
#undef max
#endif
static_assert(sizeof(ReaSample) == sizeof(double), "the hook reads ReaSample as double (REASAMPLE_SIZE 8)");
static int (*g_reg_hook)(bool isAdd, audio_hook_register_t *reg) = nullptr;
static void on_audio(bool isPost, int len, double srate, audio_hook_register_t *reg)
{
  if (isPost) return; // (before REAPER's processing: the hardware inputs as they came in)
  g_in_cb.fetch_add(1, std::memory_order_acq_rel);
  const double *chans[64] = { nullptr };
  const int nin = std::min(reg->input_nch, 64);
  for (int c = 0; c < g_nch; ++c) if (g_first + c < nin) chans[g_first + c] = reg->GetBuffer(false, g_first + c);
  direct_audio_process(chans, nin, len, srate);
  g_in_cb.fetch_sub(1, std::memory_order_acq_rel);
}
static audio_hook_register_t g_hook = { on_audio, nullptr, nullptr, 0, 0, nullptr };
static bool g_hooked = false;
// Jam's play position: read in this hook's call before REAPER processes the block (GetPlayPosition2Ex: the block about to be processed), and
// taken by rt_play_tap after it (rtaudio.cpp's post call, the same block's Play feed). Every hook's pre call comes before the processing.
#include "rtaudio.h"
static double (*g_play_pos2)(ReaProject *) = nullptr;
static int (*g_play_state)(ReaProject *) = nullptr;
static std::atomic<double> g_jpos{ 0 };
static std::atomic<bool> g_jplaying{ false };
static void on_jam_audio(bool isPost, int, double, audio_hook_register_t *)
{
  if (isPost || !g_play_pos2 || !g_play_state) return;
  g_jpos.store(g_play_pos2(nullptr), std::memory_order_relaxed);
  g_jplaying.store((g_play_state(nullptr) & 1) != 0, std::memory_order_relaxed);
}
static audio_hook_register_t g_jhook = { on_jam_audio, nullptr, nullptr, 0, 0, nullptr };
static bool g_jhooked = false;
static void jam_hook(bool add)
{
  if (add && !g_jhooked && g_reg_hook) g_jhooked = g_reg_hook(true, &g_jhook) > 0;
  else if (!add && g_jhooked) { g_reg_hook(false, &g_jhook); g_jhooked = false; }
}
static void jam_tap(float *const *ch, int nch, int len, int srate)
{
  direct_jam_feed(ch, nch, len, srate, g_jpos.load(std::memory_order_relaxed), g_jplaying.load(std::memory_order_relaxed));
}
#endif

int direct_audio_start(int first_input, int nch)
{
  std::lock_guard<std::mutex> l(g_api_mx);
  if (g_on || first_input < 0 || nch < 1 || nch > MAX_CH) return 0;
  g_ring = new (std::nothrow) float[RING_FRAMES * (size_t)nch];
  if (!g_ring) return 0;
  g_first = first_input; g_nch = nch;
  g_w = 0; g_r = 0; g_callbacks = 0; g_frames = 0; g_overruns = 0; g_max_ns = 0; g_srate = 0;
  for (auto &p : g_peak) p = 0;
  g_on.store(true, std::memory_order_release);
#ifndef DIRECT_STANDALONE
  g_hooked = g_reg_hook && g_reg_hook(true, &g_hook) > 0;
  if (!g_hooked) { g_on = false; delete[] g_ring; g_ring = nullptr; return 0; }
#endif
  return 1;
}

void direct_audio_stop()
{
  std::lock_guard<std::mutex> l(g_api_mx);
  g_dump_stop = true;
  if (g_dump_thr.joinable()) g_dump_thr.join();
  g_dump_stop = false;
  if (!g_on) return;
#ifndef DIRECT_STANDALONE
  if (g_hooked) g_reg_hook(false, &g_hook);
  g_hooked = false;
#endif
  g_on.store(false, std::memory_order_release);
  for (int i = 0; i < 200 && g_in_cb.load() > 0; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(1)); // (a callback mid-flight finishes)
  delete[] g_ring;
  g_ring = nullptr;
}

int direct_audio_dump(const char *path, double seconds)
{
  std::lock_guard<std::mutex> l(g_api_mx);
  if (!g_on || !path || !*path || seconds <= 0 || seconds > 60 || g_dump_state == 1) return 0;
  if (g_dump_thr.joinable()) g_dump_thr.join();
  g_dump_path = path;
  g_dump_frames = 0;
  g_dump_state = 1;
  g_dump_thr = std::thread(dump_loop, g_dump_path, seconds);
  return 1;
}

const char *direct_audio_status()
{
  std::lock_guard<std::mutex> l(g_api_mx);
  char b[160];
  snprintf(b, sizeof(b), "{\"running\":%s,\"srate\":%.0f,\"inputs\":%d,\"first\":%d,\"nch\":%d,\"callbacks\":%lld,\"frames\":%lld,\"overruns\":%lld,\"max_us\":%.1f,\"peaks\":[",
           g_on ? "true" : "false", g_srate.load(), g_inputs.load(), g_first, g_nch, g_callbacks.load(), g_frames.load(), g_overruns.load(), g_max_ns.load() / 1000.0);
  g_status_out = b;
  for (int c = 0; c < g_nch; ++c) { snprintf(b, sizeof(b), c ? ",%.5f" : "%.5f", g_peak[c].exchange(0)); g_status_out += b; } // (peaks since the last ask)
  static const char *states[] = { "none", "writing", "done", "failed" };
  snprintf(b, sizeof(b), "],\"dump\":{\"state\":\"%s\",\"frames\":%lld}}", states[g_dump_state.load() & 3], g_dump_frames.load());
  g_status_out += b;
  return g_status_out.c_str();
}

#ifndef DIRECT_STANDALONE
static int api_a_start(int first, int nch) { return direct_audio_start(first, nch); }
static void api_a_stop() { direct_audio_stop(); }
static const char *api_a_status() { return direct_audio_status(); }
static int api_a_dump(const char *path, double secs) { return direct_audio_dump(path, secs); }
static void *va_a_start(void **a, int n) { return n < 2 ? nullptr : (void *)(INT_PTR)api_a_start((int)(INT_PTR)a[0], (int)(INT_PTR)a[1]); }
static void *va_a_stop(void **, int) { api_a_stop(); return nullptr; }
static void *va_a_status(void **, int) { return (void *)api_a_status(); }
static void *va_a_dump(void **a, int n) { return n < 2 || !a[1] ? nullptr : (void *)(INT_PTR)api_a_dump((const char *)a[0], *(double *)a[1]); } // (a double comes as a pointer)
static int api_j_start(const char *path) { return direct_jam_start(path); }
static void api_j_stop() { direct_jam_stop(); }
static const char *api_j_status() { return direct_jam_status(); }
static void *va_j_start(void **a, int n) { return n < 1 ? nullptr : (void *)(INT_PTR)api_j_start((const char *)a[0]); }
static void *va_j_stop(void **, int) { api_j_stop(); return nullptr; }
static void *va_j_status(void **, int) { return (void *)api_j_status(); }
static void stop_all() { direct_audio_stop(); direct_jam_stop(); }

void direct_audio_register(reaper_plugin_info_t *rec)
{
  g_reg_hook = (int (*)(bool, audio_hook_register_t *))rec->GetFunc("Audio_RegHardwareHook");
  *(void **)&g_play_pos2 = rec->GetFunc("GetPlayPosition2Ex");
  *(void **)&g_play_state = rec->GetFunc("GetPlayStateEx");
  rt_play_tap = jam_tap; // (it does nothing until StudioSync_JamStart)
  static const struct { const char *name; void *fn, *va; const char *def; } fns[] = {
    { "StudioSync_JamStart", (void *)api_j_start, (void *)va_j_start,
      "int\0const char*\0path\0Jam (lib/jam.lua): while the transport plays, write live audio's Play feed to a growing 16-bit stereo WAV at path, for the direct link to stream. Returns 1 when started." },
    { "StudioSync_JamStop", (void *)api_j_stop, (void *)va_j_stop, "void\0\0\0Stop Jam's capture: the rest is written and the WAV's header gets its real sizes." },
    { "StudioSync_JamStatus", (void *)api_j_status, (void *)va_j_status,
      "const char*\0\0\0Jam's capture as JSON: on, state (none, writing, done, failed), srate, frames (in the file), fed, dropped, rate_changed, segs ([index, file frame, play position] for each stretch played without a jump)." },
    { "StudioSync_DirectAudioStart", (void *)api_a_start, (void *)va_a_start,
      "int\0int,int\0first_input,nch\0StudioSync's audio spike: capture hardware inputs first_input.. (nch 1-8) from the audio thread into a ring. Returns 1 when started." },
    { "StudioSync_DirectAudioStop", (void *)api_a_stop, (void *)va_a_stop, "void\0\0\0Stop the audio spike's capture (the hook comes out)." },
    { "StudioSync_DirectAudioStatus", (void *)api_a_status, (void *)va_a_status,
      "const char*\0\0\0The audio spike's state as JSON: srate, callbacks, frames, overruns, the callback's longest time, peaks since the last ask, the dump." },
    { "StudioSync_DirectAudioDump", (void *)api_a_dump, (void *)va_a_dump,
      "int\0const char*,double\0path,seconds\0Write the next `seconds` (up to 60) of the captured inputs to a 32-bit float WAV, from a worker thread." },
  };
  char key[96];
  for (const auto &f : fns) {
    snprintf(key, sizeof(key), "API_%s", f.name); rec->Register(key, f.fn);
    snprintf(key, sizeof(key), "APIdef_%s", f.name); rec->Register(key, (void *)f.def);
    snprintf(key, sizeof(key), "APIvararg_%s", f.name); rec->Register(key, f.va);
  }
  rec->Register("atexit", (void *)stop_all); // (the hooks out before REAPER goes)
}
#endif
