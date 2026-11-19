// The extension's end of StudioSync Hop (plugin/hop_shm.h, docs/realtime-roadmap.md 4b). For now only a loopback, so plug-in -> extension
// -> plug-in can be tested in one REAPER before any network: StudioSync_HopLoopback(hop_id, delay) hands each send frame back unchanged
// once the plug-in has written `delay` more frames, i.e. a round trip of `delay` samples in the plug-in's own clock. The network leg
// (the ring's audio to the bandmate and back) is extension/rtaudio's, through the same mapping. -DHOP_STANDALONE: tests/hop_test.cpp.
// GPL-3.0-or-later.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <mutex>
#include <thread>
#include <vector>
#include "../plugin/hop_shm.h"

namespace {
struct Hop {
  int id = 0, delay = 0;
  hop_map m = {};
  uint64_t r = 0; // the next send frame to hand back
};
std::mutex g_mx;            // g_hops: main thread and the loopback thread
std::vector<Hop *> g_hops;
std::vector<hop_map> g_names; // every mapping opened, for the POSIX names at exit
std::thread g_thr;
std::atomic<bool> g_run{ false };

Hop *find(int id)
{
  for (Hop *h : g_hops)
    if (h->id == id) return h;
  return nullptr;
}

void step(Hop *h)
{
  hop_shm *s = h->m.p;
  if (!hop_shm_ok(s)) return;
  uint64_t w = hop_load(&s->send_w);
  if (h->r > w || w - h->r > HOP_FRAMES / 2) h->r = w > HOP_FRAMES / 2 ? w - HOP_FRAMES / 2 : 0; // (fell behind: the oldest still in the ring)
  uint64_t upto = w > (uint64_t)h->delay ? w - h->delay : 0;
  if (upto <= h->r) return;
  static thread_local std::vector<float> buf((size_t)HOP_FRAMES * HOP_CH);
  uint32_t n = (uint32_t)(upto - h->r);
  hop_copy_out(s->send, h->r, n, buf.data());
  hop_copy_in(s->ret, h->r, buf.data(), n);
  hop_store(&s->ret_w, upto); // (after the frames: the plug-in reads ret_w first, then the frames below it)
  h->r = upto;
}

void loop()
{
  while (g_run.load()) {
    {
      std::lock_guard<std::mutex> lk(g_mx);
      if (g_hops.empty()) { g_run = false; return; } // (no loopback left: the thread ends, the next HopLoopback starts another)
      for (Hop *h : g_hops) step(h);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1)); // (well under the smallest latency, 256 samples = 5 ms)
  }
}
} // namespace

// delay < 0: stop that hop's loopback. Returns 1 when the loopback runs (or was stopped), 0 when the mapping couldn't be opened.
int hop_loopback(int id, int delay)
{
  std::lock_guard<std::mutex> lk(g_mx);
  Hop *h = find(id);
  if (delay < 0) {
    if (h) {
      if (hop_shm_ok(h->m.p)) h->m.p->ext_mode = HOP_EXT_NONE;
      hop_shm_close(&h->m);
      g_hops.erase(std::find(g_hops.begin(), g_hops.end(), h));
      delete h;
    }
    return 1;
  }
  if (!h) {
    h = new Hop();
    h->id = id;
    if (!hop_shm_open(&h->m, hop_reaper_pid(), id)) { delete h; return 0; }
    g_names.push_back(h->m);
    uint64_t w = hop_load(&h->m.p->send_w), rw = hop_load(&h->m.p->ret_w);
    h->r = rw <= w && w - rw <= HOP_FRAMES / 2 ? rw : w; // (from where the returns stopped, so no stale frame is ever published)
    g_hops.push_back(h);
  }
  h->delay = delay > (int)(HOP_FRAMES / 2) ? (int)(HOP_FRAMES / 2) : delay;
  h->m.p->ext_mode = HOP_EXT_LOOPBACK;
  h->m.p->ext_delay = (uint32_t)h->delay;
  if (!g_run.exchange(true)) {
    if (g_thr.joinable()) g_thr.join(); // (one that ended by itself: it holds no lock on its way out)
    g_thr = std::thread(loop);
  }
  return 1;
}

// The hop's state as JSON (for tests and Health): what the plug-in reports and how far each side is.
const char *hop_status(int id)
{
  static char out[384];
  std::lock_guard<std::mutex> lk(g_mx);
  Hop *h = find(id);
  hop_map tmp = {};
  hop_shm *s = h ? h->m.p : nullptr;
  if (!s) {
    if (!(s = hop_shm_open(&tmp, hop_reaper_pid(), id))) return "{}";
    g_names.push_back(tmp); // (asking may have made the name: it goes at exit too)
  }
  if (!hop_shm_ok(s)) snprintf(out, sizeof(out), "{\"hop\":%d,\"ready\":false}", id);
  else
    snprintf(out, sizeof(out),
             "{\"hop\":%d,\"ready\":true,\"srate\":%.0f,\"latency\":%llu,\"send_w\":%llu,\"ret_w\":%llu,\"late\":%llu,\"blocks\":%llu,\"mode\":%u,\"delay\":%u}",
             id, s->srate, (unsigned long long)hop_load(&s->latency), (unsigned long long)hop_load(&s->send_w),
             (unsigned long long)hop_load(&s->ret_w), (unsigned long long)hop_load(&s->late), (unsigned long long)hop_load(&s->blocks),
             s->ext_mode, s->ext_delay);
  if (tmp.p) hop_shm_close(&tmp);
  return out;
}

void hop_stop_all()
{
  g_run = false;
  if (g_thr.joinable()) g_thr.join(); // (also one that ended by itself: a joinable thread left at exit would end REAPER)
  std::lock_guard<std::mutex> lk(g_mx);
  for (Hop *h : g_hops) { hop_shm_close(&h->m); delete h; }
  g_hops.clear();
  for (const hop_map &m : g_names) hop_shm_unlink(&m);
  g_names.clear();
}

#ifndef HOP_STANDALONE
#include "reaper_plugin.h"
static int api_loopback(int id, int delay) { return hop_loopback(id, delay); }
static const char *api_status(int id) { return hop_status(id); }
static void *va_loopback(void **a, int n) { return n < 2 ? nullptr : (void *)(intptr_t)api_loopback((int)(intptr_t)a[0], (int)(intptr_t)a[1]); }
static void *va_status(void **a, int n) { return n < 1 ? nullptr : (void *)api_status((int)(intptr_t)a[0]); }

extern "C" void hop_register(reaper_plugin_info_t *rec) // (C linkage: reaper_menu.cpp declares it inside its extern "C" entry point)
{
  static const struct { const char *name; void *fn, *va; const char *def; } fns[] = {
    { "StudioSync_HopLoopback", (void *)api_loopback, (void *)va_loopback,
      "int\0int,int\0hop_id,delay_samples\0StudioSync Hop's test loopback: the hop's audio comes straight back after `delay_samples` (in the "
      "plug-in's clock), with no network. A negative delay stops it. Returns 1, or 0 when the hop's shared memory couldn't be opened." },
    { "StudioSync_HopStatus", (void *)api_status, (void *)va_status,
      "const char*\0int\0hop_id\0StudioSync Hop's state as JSON: srate, latency, frames sent and returned, late blocks, blocks, mode, delay." },
  };
  char key[96];
  for (const auto &f : fns) {
    snprintf(key, sizeof(key), "API_%s", f.name); rec->Register(key, f.fn);
    snprintf(key, sizeof(key), "APIdef_%s", f.name); rec->Register(key, (void *)f.def);
    snprintf(key, sizeof(key), "APIvararg_%s", f.name); rec->Register(key, f.va);
  }
  rec->Register("atexit", (void *)hop_stop_all); // (the thread out and the names gone before REAPER goes)
}
#endif
