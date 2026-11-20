// StudioSync Hop's native test (no REAPER, no host): the shared-memory ring (plugin/hop_shm.h), the timing (plugin/hop_core.h: a late
// return plays the dry input at the same latency; an on-time one lines up to the sample), and the extension's loopback thread
// (extension/hop.cpp with -DHOP_STANDALONE) against the plug-in's core in real time.
//   Windows: tests\build_hop_test.cmd    macOS/Linux: c++ -std=c++17 -O2 -pthread -DHOP_STANDALONE tests/hop_test.cpp extension/hop.cpp -o hop_test && ./hop_test
// GPL-3.0-or-later.
#include <chrono>
#include <cstdio>
#include <thread>
#include <vector>
#include "../plugin/hop_core.h"

int hop_loopback(int id, int delay);
const char *hop_status(int id);
void hop_stop_all();

static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static float sig(uint64_t i) { return (float)((i * 7919u) % 100003u) / 100003.f + 0.001f; } // (never 0, so silence and signal differ)

// A host's view: feed blocks of the test signal, keep every output frame.
struct Run {
  HopCore core;
  std::vector<float> out0, out1;
  uint64_t fed = 0;
  void block(uint32_t n)
  {
    std::vector<float> a(n), b(n), o0(n), o1(n);
    for (uint32_t k = 0; k < n; k++) { a[k] = sig(fed + k); b[k] = -sig(fed + k); }
    const float *in[2] = { a.data(), b.data() };
    float *out[2] = { o0.data(), o1.data() };
    core.process(in, out, n);
    out0.insert(out0.end(), o0.begin(), o0.end());
    out1.insert(out1.end(), o1.begin(), o1.end());
    fed += n;
  }
};

// The extension's part, done in step with the test: send frames come back x0.5 (so wet and dry differ) once `delay` more were sent.
static uint64_t g_r = 0;
static void sim_return(hop_shm *s, uint32_t delay)
{
  uint64_t w = hop_load(&s->send_w), upto = w > delay ? w - delay : 0;
  for (; g_r < upto; g_r++) {
    size_t p = (size_t)(g_r & HOP_MASK) * HOP_CH;
    s->ret[p] = s->send[p] * 0.5f; s->ret[p + 1] = s->send[p + 1] * 0.5f;
  }
  if (upto > hop_load(&s->ret_w)) hop_store(&s->ret_w, upto);
}

static hop_shm *fresh(hop_map *m, int id)
{
  hop_shm *s = hop_shm_open(m, hop_reaper_pid(), id);
  if (s) { hop_store(&s->send_w, 0); hop_store(&s->ret_w, 0); }
  g_r = 0;
  return s;
}

// Every output frame against the rule: before L silence; then wet (0.5x) if frame i - L was back when its block began, else dry * level.
static void expect(const Run &r, uint32_t L, uint32_t block, uint32_t delay, float level, bool has_ret, const char *what)
{
  int bad = 0;
  for (uint64_t i = 0; i < r.out0.size(); i++) {
    float want;
    if (i < L) want = 0.f;
    else {
      uint64_t idx = i - L, t0 = i - i % block; // (the block's first frame)
      bool back = has_ret && t0 >= delay && idx < t0 - delay;
      want = back ? 0.5f * sig(idx) : level * sig(idx);
    }
    if (r.out0[i] != want || r.out1[i] != -want) {
      if (bad++ < 3) printf("  %s: frame %llu got %g want %g\n", what, (unsigned long long)i, r.out0[i], want);
    }
  }
  CHECK(bad == 0, "%s: %d frames off", what, bad);
}

int main()
{
  // 1. The ring: two opens of one hop share memory; the header is made once; copies wrap at the end.
  {
    hop_map a, b;
    hop_shm *sa = hop_shm_open(&a, hop_reaper_pid(), 901), *sb = hop_shm_open(&b, hop_reaper_pid(), 901);
    CHECK(sa && sb && hop_shm_ok(sa) && hop_shm_ok(sb), "open twice");
    if (sa && sb) {
      hop_store(&sa->send_w, 777);
      CHECK(hop_load(&sb->send_w) == 777, "the second view sees the first's write");
      std::vector<float> src(10 * HOP_CH), dst(10 * HOP_CH);
      for (size_t k = 0; k < src.size(); k++) src[k] = (float)k + 1;
      uint64_t at = 3ull * HOP_FRAMES - 4; // (4 frames before the end, 6 after the wrap)
      hop_copy_in(sa->send, at, src.data(), 10);
      hop_copy_out(sb->send, at, 10, dst.data());
      CHECK(src == dst, "copy across the wrap");
      CHECK(sb->send[0] == 9.f && sb->send[(size_t)(HOP_FRAMES - 4) * HOP_CH] == 1.f, "the wrap lands at the ring's start");
    }
    hop_map c;
    hop_shm *sc = hop_shm_open(&c, hop_reaper_pid(), 902);
    CHECK(sc && sa && sc != sa && hop_load(&sc->send_w) == 0, "another hop id is another mapping");
    hop_shm_unlink(&a); hop_shm_unlink(&c);
    hop_shm_close(&a); hop_shm_close(&b); hop_shm_close(&c);
  }

  const uint32_t B = 256, L = 1024;
  // 2. Exact alignment: a return exactly in time (delay = L - B) is wet on every frame, at exactly L.
  {
    hop_map m; Run r; r.core.latency = L; r.core.shm = fresh(&m, 910); r.core.reset();
    for (int k = 0; k < 64; k++) { r.block(B); sim_return(m.p, L - B); }
    expect(r, L, B, L - B, 1.f, true, "in time");
    CHECK(r.core.late_blocks == 0 && hop_load(&m.p->late) == 0, "in time: no late blocks (%llu)", (unsigned long long)r.core.late_blocks);
    CHECK(hop_load(&m.p->latency) == L, "the latency is in the mapping");
    hop_shm_unlink(&m); hop_shm_close(&m);
  }
  // 3. One frame too slow: the block's last frame plays dry, still at exactly L; each such block counts as late.
  {
    hop_map m; Run r; r.core.latency = L; r.core.shm = fresh(&m, 911); r.core.reset();
    for (int k = 0; k < 64; k++) { r.block(B); sim_return(m.p, L - B + 1); }
    expect(r, L, B, L - B + 1, 1.f, true, "one frame late");
    CHECK(r.core.late_blocks == 64 - L / B, "late blocks %llu, want %u", (unsigned long long)r.core.late_blocks, 64 - L / B);
    hop_shm_unlink(&m); hop_shm_close(&m);
  }
  // 4. Nothing comes back, silence chosen: silence after L, every block late.
  {
    hop_map m; Run r; r.core.latency = L; r.core.dry_when_late = 0.f; r.core.shm = fresh(&m, 912); r.core.reset();
    for (int k = 0; k < 16; k++) r.block(B);
    expect(r, L, B, 0, 0.f, false, "silence when late");
    CHECK(r.core.late_blocks == 16 - L / B, "late blocks %llu", (unsigned long long)r.core.late_blocks);
    hop_shm_unlink(&m); hop_shm_close(&m);
  }
  // 5. No mapping at all: dry at L.
  {
    Run r; r.core.latency = L; r.core.reset();
    for (int k = 0; k < 16; k++) r.block(B);
    expect(r, L, B, 0, 1.f, false, "no mapping");
  }
  // 6. Bypass: dry at L even with returns there, nothing late.
  {
    hop_map m; Run r; r.core.latency = L; r.core.bypass = true; r.core.shm = fresh(&m, 913); r.core.reset();
    for (int k = 0; k < 16; k++) { r.block(B); sim_return(m.p, 0); }
    expect(r, L, B, 0, 1.f, false, "bypass");
    CHECK(r.core.late_blocks == 0, "bypass: nothing late");
    hop_shm_unlink(&m); hop_shm_close(&m);
  }
  // 7. A host block bigger than the core's chunk (4096), the largest latency: still wet and aligned. (A block longer than the latency
  //    can never be in time: the return only starts after the block, so the budget has to cover the host block too.)
  {
    const uint32_t BIG = 6000, LMAX = HOP_LAT_MAX; // (the long links' budget, rt-hopvst: 32768)
    hop_map m; Run r; r.core.latency = LMAX; r.core.shm = fresh(&m, 914); r.core.reset();
    for (int k = 0; k < 10; k++) { r.block(BIG); sim_return(m.p, 0); }
    expect(r, LMAX, BIG, 0, 1.f, true, "big blocks");
    CHECK(r.core.late_blocks == 0, "big blocks: nothing late");
    hop_shm_unlink(&m); hop_shm_close(&m);
  }
  // 8. A mapping that already ran (frame numbers far ahead): our frames go after its own; nothing before attach is taken as ours.
  {
    hop_map m; Run r; r.core.latency = L; r.core.shm = fresh(&m, 915);
    hop_store(&m.p->send_w, 123457); hop_store(&m.p->ret_w, 123457); g_r = 123457;
    r.core.reset();
    for (int k = 0; k < 32; k++) { r.block(B); sim_return(m.p, L - B); }
    expect(r, L, B, L - B, 1.f, true, "offset mapping");
    CHECK(hop_load(&m.p->send_w) == 123457 + 32 * B, "send_w carries on from the mapping's own");
    hop_shm_unlink(&m); hop_shm_close(&m);
  }
  // 9. The extension's real loopback thread, paced like a host: in time no late block and the audio exactly at L; a round trip longer
  //    than L: late blocks, and still exactly at L (dry).
  {
    const int ID = 950; const uint32_t LL = 9600, BB = 480;
    hop_map m; Run r; r.core.latency = LL; r.core.shm = fresh(&m, ID); r.core.reset();
    CHECK(hop_loopback(ID, 480) == 1, "loopback starts");
    for (int k = 0; k < 120; k++) { r.block(BB); std::this_thread::sleep_for(std::chrono::milliseconds(10)); }
    uint64_t late_on_time = r.core.late_blocks;
    CHECK(hop_loopback(ID, 30000) == 1, "loopback delay changes");
    for (int k = 0; k < 60; k++) { r.block(BB); std::this_thread::sleep_for(std::chrono::milliseconds(2)); }
    printf("loopback: %s\n", hop_status(ID));
    int bad = 0;
    for (uint64_t i = LL; i < r.out0.size(); i++)
      if (r.out0[i] != sig(i - LL) || r.out1[i] != -sig(i - LL)) bad++;
    CHECK(bad == 0, "loopback: %d frames not exactly at L", bad);
    CHECK(late_on_time == 0, "loopback in time: %llu late blocks", (unsigned long long)late_on_time);
    CHECK(r.core.late_blocks > late_on_time, "loopback too slow: late blocks counted");
    CHECK(hop_loopback(ID, -1) == 1, "loopback stops");
    hop_stop_all();
    hop_shm_unlink(&m); hop_shm_close(&m);
  }
  // 10. "Dry when late" goes into the mapping (the network leg fills a lost frame with the input when it's on, rt-hopvst).
  {
    hop_map m; Run r; r.core.latency = L; r.core.shm = fresh(&m, 916); r.core.reset();
    r.block(B);
    CHECK(hop_load(&m.p->dry_lost) == 1, "dry when late on: dry_lost 1");
    r.core.dry_when_late = 0.f; r.block(B);
    CHECK(hop_load(&m.p->dry_lost) == 0, "dry when late off: dry_lost 0");
    hop_shm_unlink(&m); hop_shm_close(&m);
  }
  // 11. MIDI in: each event goes into send_midi at its absolute send frame (the mapping's own numbers), counted by send_mw; bad sizes and
  //     offsets past the block are left out.
  {
    hop_map m; Run r; r.core.latency = L; r.core.shm = fresh(&m, 917);
    hop_store(&m.p->send_w, 5000); hop_store(&m.p->send_mw, 7); g_r = 5000;
    r.core.reset();
    r.block(B);
    HopMidiEv ev[4] = { { 3, 3, { 0x90, 60, 100, 0 } }, { 3, 4, { 0xF0, 1, 2, 3 } }, { 200, 2, { 0xC0, 5, 0, 0 } }, { 999, 3, { 0x80, 60, 0, 0 } } };
    std::vector<float> a(B), o0(B), o1(B);
    const float *in[2] = { a.data(), a.data() };
    float *out[2] = { o0.data(), o1.data() };
    r.core.process(in, out, B, ev, 4);
    CHECK(hop_load(&m.p->send_mw) == 9, "two events in (send_mw %llu)", (unsigned long long)hop_load(&m.p->send_mw));
    const hop_midi e0 = m.p->send_midi[7], e1 = m.p->send_midi[8];
    CHECK(e0.frame == 5000 + B + 3 && e0.msg == (0x90u | 60u << 8 | 100u << 16) && e0.len == 3, "the note at its frame (%llu)", (unsigned long long)e0.frame);
    CHECK(e1.frame == 5000 + B + 200 && e1.msg == 0xC0u + (5u << 8) && e1.len == 2, "the program change at its frame");
    CHECK(hop_load(&m.p->send_w) == 5000 + 2 * B, "send_w after the events");
    hop_shm_unlink(&m); hop_shm_close(&m);
  }
  // 12. MIDI out: an event at mapping frame f comes out at local frame f - off + L, in its block at the right offset; one already due comes
  //     out at the block's start; one from before this instance attached never does.
  {
    hop_map m; Run r; r.core.latency = L; r.core.shm = fresh(&m, 918);
    hop_store(&m.p->send_w, 1000); g_r = 1000;
    r.core.reset(); // (off = 1000: local frame 0 is mapping frame 1000)
    hop_midi *rm = m.p->ret_midi;
    rm[0] = { 900, 0x90u | 1u << 8 | 1u << 16, 3 };   // (before our time: never)
    rm[1] = { 1000 + 10, 0x90u | 2u << 8 | 9u << 16, 3 }; // (plays at local 10 + L)
    rm[2] = { 1000 + 600, 0x80u | 2u << 8, 3 };          // (plays at local 600 + L)
    hop_store(&m.p->ret_mw, 3);
    std::vector<std::pair<uint64_t, uint32_t>> got;
    for (int k = 0; k < 12; k++) {
      uint64_t t0 = r.fed;
      r.block(B);
      for (uint32_t e = 0; e < r.core.nmout; e++) got.push_back({ t0 + r.core.mout[e].frame, (uint32_t)r.core.mout[e].data[1] });
      if (k == 9) { rm[3] = { 1000 + 5, 0xB0u | 7u << 8 | 3u << 16, 3 }; hop_store(&m.p->ret_mw, 4); } // (late: due long ago)
    }
    CHECK(got.size() == 3, "three events out (%zu)", got.size());
    if (got.size() == 3) {
      CHECK(got[0].first == 10 + L && got[0].second == 2, "the first at local 10 + L (%llu)", (unsigned long long)got[0].first);
      CHECK(got[1].first == 600 + L, "the second at local 600 + L (%llu)", (unsigned long long)got[1].first);
      CHECK(got[2].first == 10ull * B && got[2].second == 7, "the late one at its block's start (%llu)", (unsigned long long)got[2].first);
    }
    hop_shm_unlink(&m); hop_shm_close(&m);
  }
  printf(fails ? "hop_test: %d failed\n" : "hop_test: ok\n", fails);
  return fails ? 1 : 0;
}
