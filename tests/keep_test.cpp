// The full-quality copy's capture (extension/direct_audio.cpp direct_keep_*; lib/double.lua; docs/rt/rt-double.md) without REAPER: blocks of
// hardware inputs fed as the audio thread would, with the link clock and the play position and state, become one 32-bit float WAV per line of
// the spec (mono or stereo, the inputs it names, in its order), readable while it's written (the header rewritten each second) and with the
// real sizes once stopped. Segments { file frame, clock, playing, position } start at the first block, at play and stop, at a seek or loop while
// playing and after a dropped block, never mid-stretch; a bad spec is refused; a second rate is flagged. Build and run: tests\build_keep_test.cmd.
// macOS/Linux:
//   c++ -std=c++17 -O2 -pthread -DDIRECT_STANDALONE tests/keep_test.cpp extension/direct.cpp extension/direct_audio.cpp -o /tmp/keep_test && /tmp/keep_test
// GPL-3.0-or-later.
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>
#include "../extension/direct.h"

static int fails = 0;
static void check(bool ok, const char *what) { printf("%s %s\n", ok ? "ok  " : "FAIL", what); if (!ok) ++fails; }
static std::string status() { return direct_keep_status(); }
static long long num(const std::string &j, const char *key)
{
  const size_t at = j.find(std::string("\"") + key + "\":");
  return at == std::string::npos ? -1 : atoll(j.c_str() + at + strlen(key) + 3);
}
struct Seg { long long n0; double t0; int playing; double p0; };
static std::vector<Seg> segs(const std::string &j)
{
  std::vector<Seg> out;
  size_t at = j.find("\"segs\":[");
  if (at == std::string::npos) return out;
  at += 8;
  long long i; Seg s; int used = 0;
  while (sscanf(j.c_str() + at, "[%lld,%lld,%lf,%d,%lf]%n", &i, &s.n0, &s.t0, &s.playing, &s.p0, &used) == 5) { out.push_back(s); at += (size_t)used; if (j[at] == ',') ++at; }
  return out;
}
static std::vector<unsigned char> slurp(const std::string &p)
{
  std::vector<unsigned char> d;
  FILE *f = fopen(p.c_str(), "rb");
  if (f) { int c; while ((c = fgetc(f)) != EOF) d.push_back((unsigned char)c); fclose(f); }
  return d;
}
static unsigned u32(const std::vector<unsigned char> &d, size_t at) { return (unsigned)d[at] | ((unsigned)d[at + 1] << 8) | ((unsigned)d[at + 2] << 16) | ((unsigned)d[at + 3] << 24); }
static unsigned u16(const std::vector<unsigned char> &d, size_t at) { return (unsigned)d[at] | ((unsigned)d[at + 1] << 8); }
static float f32(const std::vector<unsigned char> &d, size_t at) { unsigned v = u32(d, at); float f; memcpy(&f, &v, 4); return f; }

// Four hardware inputs: input c carries c + 1 + frame / 1e6 (each sample tells which input and frame it was).
static long long g_frame = 0;
static void feed(int blocks, int len, double sr, double &clock, double &pos, bool playing)
{
  std::vector<std::vector<double>> ch(4, std::vector<double>((size_t)len));
  for (int b = 0; b < blocks; ++b) {
    for (int c = 0; c < 4; ++c) for (int k = 0; k < len; ++k) ch[(size_t)c][(size_t)k] = c + 1 + (double)(g_frame + k) / 1e6;
    const double *in[4] = { ch[0].data(), ch[1].data(), ch[2].data(), ch[3].data() };
    direct_keep_feed(in, 4, len, sr, clock, pos, playing);
    g_frame += len;
    clock += len / sr;
    if (playing) pos += len / sr;
  }
}

int main()
{
  const std::string dir = std::string(getenv("TEMP") ? getenv("TEMP") : "/tmp");
  const std::string a = dir + "/ss_keep_test_gtr.wav", b = dir + "/ss_keep_test_vox.wav";
  remove(a.c_str()); remove(b.c_str());
  const double none = 0;
  const double *nothing[1] = { &none };
  direct_keep_feed(nothing, 1, 1, 48000, 0, 0, false); // (before a start: ignored)
  check(direct_keep_start("") == 0 && direct_keep_start("x\tpath") == 0 && direct_keep_start("1") == 0 && direct_keep_start("-1\tp") == 0 &&
        direct_keep_start("1,2,3\tp") == 0, "a bad spec is refused");
  std::string many;
  for (int i = 0; i < 17; ++i) many += "0\t" + dir + "/x.wav\n";
  check(direct_keep_start(many.c_str()) == 0, "at most 16 files");
  const std::string spec = "2,3\t" + a + "\n0\t" + b + "\n"; // (a stereo guitar on inputs 3-4, a mono vocal on input 1)
  check(direct_keep_start(spec.c_str()) == 1, "starts");
  check(direct_keep_start(spec.c_str()) == 0, "once at a time");
  const double sr = 48000;
  const int len = 256;
  double clock = 1.8e9, pos = 10.0;
  feed(40, len, sr, clock, pos, false); // live, the transport stopped: recorded (the double-ender doesn't need the transport)
  const double c_play = clock;
  feed(100, len, sr, clock, pos, true); // play from 10 s
  pos = 2.0; // a loop back
  feed(50, len, sr, clock, pos, true);
  pos += 0.005; // (the play position's own jitter: no new segment)
  feed(10, len, sr, clock, pos, true);
  feed(5, len, sr, clock, pos, false); // stopped: still recorded, a new segment
  std::this_thread::sleep_for(std::chrono::milliseconds(1200)); // (the worker rewrites the headers each second)
  auto mid = slurp(b);
  check(mid.size() > 44 && u32(mid, 40) > 0, "readable while it's written: the header has the sizes so far");
  std::string j = status();
  auto s = segs(j);
  check(s.size() == 4, "four segments: live, play, the loop back, stopped again");
  check(s.size() == 4 && s[0].n0 == 0 && s[0].playing == 0 && std::fabs(s[0].t0 - 1.8e9) < 1e-6, "the first at frame 0 with its clock, not playing");
  check(s.size() == 4 && s[1].n0 == 40 * len && s[1].playing == 1 && std::fabs(s[1].p0 - 10.0) < 1e-9 && std::fabs(s[1].t0 - c_play) < 1e-6, "play: its frame, clock and position");
  check(s.size() == 4 && s[2].n0 == 140 * len && std::fabs(s[2].p0 - 2.0) < 1e-9, "the loop back: its frame and position");
  check(s.size() == 4 && s[3].n0 == 200 * len && s[3].playing == 0, "the stop: a new one, recording on");
  check(num(j, "frames") == 205 * len && num(j, "files") == 2, "every frame in both files");
  // a second rate: flagged, not taken
  direct_keep_feed(nothing, 1, 1, 44100, clock, pos, false);
  j = status();
  check(j.find("\"rate_changed\":true") != std::string::npos, "another rate: flagged");
  direct_keep_stop();
  j = status();
  check(j.find("\"state\":\"done\"") != std::string::npos && j.find("\"on\":false") != std::string::npos, "stopped: done");
  const unsigned frames = 205 * len;
  auto da = slurp(a), db = slurp(b);
  check(da.size() == 44 + (size_t)frames * 8 && db.size() == 44 + (size_t)frames * 4, "each file: its header and every frame");
  check(da.size() > 44 && !memcmp(&da[0], "RIFF", 4) && u16(da, 20) == 3 && u16(da, 22) == 2 && u32(da, 24) == 48000 && u16(da, 34) == 32 &&
        u32(da, 40) == frames * 8 && u32(da, 4) == 36 + frames * 8, "the guitar: float, stereo, 48 kHz, 32-bit, real sizes");
  check(db.size() > 44 && u16(db, 22) == 1 && u32(db, 40) == frames * 4, "the vocal: mono, real sizes");
  const size_t k = 1000; // a frame well inside
  check(da.size() > 44 + (k + 1) * 8 && std::fabs(f32(da, 44 + k * 8) - (3 + k / 1e6)) < 1e-5 && std::fabs(f32(da, 48 + k * 8) - (4 + k / 1e6)) < 1e-5,
        "the guitar holds inputs 3 and 4, sample for sample");
  check(db.size() > 44 + (k + 1) * 4 && std::fabs(f32(db, 44 + k * 4) - (1 + k / 1e6)) < 1e-5, "the vocal holds input 1");
  // a whole block that doesn't fit the ring is dropped and the next starts a segment
  check(direct_keep_start(("0\t" + b + "\n").c_str()) == 1, "starts again (the file anew)");
  g_frame = 0;
  feed(2, len, sr, clock, pos, false);
  std::vector<double> big(1 << 19, 0.0);
  const double *bch[1] = { big.data() };
  direct_keep_feed(bch, 1, 1 << 19, sr, clock, pos, false);
  clock += (1 << 19) / sr;
  const double c_after = clock;
  feed(2, len, sr, clock, pos, false);
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  j = status();
  s = segs(j);
  check(num(j, "dropped") == (1 << 19), "a block bigger than the room left: dropped whole");
  check(s.size() == 2 && s[1].n0 == 2 * len && std::fabs(s[1].t0 - c_after) < 1e-6, "after a drop: a new segment with the clock where writing went on");
  direct_keep_stop();
  direct_keep_stop(); // (twice: nothing)
  db = slurp(b);
  check(db.size() == 44 + 4 * (size_t)len * 4, "only what was kept");
  // stopped before any audio: no file
  remove(a.c_str());
  check(direct_keep_start(("0\t" + a + "\n").c_str()) == 1, "starts");
  direct_keep_stop();
  check(slurp(a).empty() && status().find("\"state\":\"done\"") != std::string::npos, "stopped before any audio: done, no file");
  remove(a.c_str()); remove(b.c_str());
  printf(fails ? "keep_test: %d FAILED\n" : "keep_test: all ok\n", fails);
  return fails ? 1 : 0;
}
