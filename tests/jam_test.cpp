// Jam's capture (extension/direct_audio.cpp direct_jam_*; lib/jam.lua; docs/rt/rt-jam.md) without REAPER: blocks fed as the audio thread
// would, with their play positions, become a 16-bit stereo WAV whose header has the real sizes once stopped, and segments { file frame,
// position } start at play, at a seek or loop, after a dropped block, and never mid-stretch; nothing is written while stopped; a second rate is
// flagged. Build and run: tests\build_jam_test.cmd. macOS/Linux:
//   c++ -std=c++17 -O2 -pthread -DDIRECT_STANDALONE tests/jam_test.cpp extension/direct.cpp extension/direct_audio.cpp -o /tmp/jam_test && /tmp/jam_test
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
static std::string status() { return direct_jam_status(); }
static long long num(const std::string &j, const char *key)
{
  const size_t at = j.find(std::string("\"") + key + "\":");
  return at == std::string::npos ? -1 : atoll(j.c_str() + at + strlen(key) + 3);
}
// segs as [[index, frame, pos], ...]
static std::vector<std::pair<long long, double>> segs(const std::string &j)
{
  std::vector<std::pair<long long, double>> out;
  size_t at = j.find("\"segs\":[");
  if (at == std::string::npos) return out;
  at += 8;
  long long i, n; double p; int used = 0;
  while (sscanf(j.c_str() + at, "[%lld,%lld,%lf]%n", &i, &n, &p, &used) == 3) { out.push_back({ n, p }); at += (size_t)used; if (j[at] == ',') ++at; }
  return out;
}
static void feed(int blocks, int len, double sr, double &pos, bool playing, float &v)
{
  std::vector<float> L((size_t)len), R((size_t)len);
  for (int b = 0; b < blocks; ++b) {
    for (int k = 0; k < len; ++k) { L[(size_t)k] = v; R[(size_t)k] = -v; v += 1.f / 32768.f; if (v > 0.9f) v = 0; }
    const float *ch[2] = { L.data(), R.data() };
    direct_jam_feed(ch, 2, len, sr, pos, playing);
    if (playing) pos += len / sr;
  }
}

int main()
{
  const std::string path = std::string(getenv("TEMP") ? getenv("TEMP") : "/tmp") + "/ss_jam_test.wav";
  remove(path.c_str());
  float none = 0;
  const float *nothing[1] = { &none };
  direct_jam_feed(nothing, 1, 1, 48000, 0, true); // (before a start: ignored)
  check(direct_jam_start(path.c_str()) == 1, "starts");
  check(direct_jam_start(path.c_str()) == 0, "once at a time");
  const double sr = 48000;
  const int len = 256;
  double pos = 10.0;
  float v = 0;
  feed(4, len, sr, pos, false, v); // stopped: nothing written
  double was = pos;
  feed(100, len, sr, pos, true, v); // play from 10 s
  pos = 2.0; // a seek back (a loop)
  feed(50, len, sr, pos, true, v);
  feed(3, len, sr, pos, false, v); // stopped
  pos = 30.0;
  feed(10, len, sr, pos, true, v); // played again from 30
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  std::string j = status();
  auto s = segs(j);
  check(s.size() == 3, "three segments: play, the jump back, play again");
  check(s.size() == 3 && s[0].first == 0 && std::fabs(s[0].second - was) < 1e-9, "the first at frame 0, at 10 s");
  check(s.size() == 3 && s[1].first == 100 * len && std::fabs(s[1].second - 2.0) < 1e-9, "the jump: its frame and position");
  check(s.size() == 3 && s[2].first == 150 * len && std::fabs(s[2].second - 30.0) < 1e-9, "after a stop: a new one, nothing written meanwhile");
  check(num(j, "fed") == 160 * len, "every frame played fed, none while stopped");
  // a second rate: flagged, not written
  const float *ch[1] = { nothing[0] };
  direct_jam_feed(ch, 1, 1, 44100, pos, true);
  j = status();
  check(j.find("\"rate_changed\":true") != std::string::npos && num(j, "fed") == 160 * len, "another rate: flagged, nothing taken");
  // a whole block that doesn't fit the ring is dropped and the next block starts a segment
  std::vector<float> big(1 << 19, 0.f);
  const float *bch[1] = { big.data() };
  direct_jam_stop();
  check(direct_jam_start(path.c_str()) == 1, "starts again (the file anew)");
  pos = 5.0;
  feed(2, len, sr, pos, true, v);
  direct_jam_feed(bch, 1, 1 << 19, sr, pos, true);
  pos += (1 << 19) / sr;
  feed(2, len, sr, pos, true, v);
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  j = status();
  s = segs(j);
  check(num(j, "dropped") == (1 << 19), "a block bigger than the room left: dropped whole");
  check(s.size() == 2 && s[1].first == 2 * len && std::fabs(s[1].second - pos + 2 * len / sr) < 1e-9, "after a drop: a new segment where writing went on");
  direct_jam_stop();
  check(status().find("\"state\":\"done\"") != std::string::npos && status().find("\"on\":false") != std::string::npos, "stopped: done");
  // the file: a 16-bit stereo WAV, its sizes real, its samples as fed
  FILE *f = fopen(path.c_str(), "rb");
  std::vector<unsigned char> d;
  if (f) { int c; while ((c = fgetc(f)) != EOF) d.push_back((unsigned char)c); fclose(f); }
  auto u32 = [&](size_t at) { return (unsigned)d[at] | ((unsigned)d[at + 1] << 8) | ((unsigned)d[at + 2] << 16) | ((unsigned)d[at + 3] << 24); };
  auto u16 = [&](size_t at) { return (unsigned)d[at] | ((unsigned)d[at + 1] << 8); };
  const unsigned frames = 4 * len;
  check(d.size() == 44 + frames * 4, "header and every frame");
  check(d.size() >= 44 && !memcmp(&d[0], "RIFF", 4) && !memcmp(&d[8], "WAVE", 4) && u16(20) == 1 && u16(22) == 2 && u32(24) == 48000 && u16(34) == 16,
        "PCM, stereo, 48 kHz, 16-bit");
  check(d.size() >= 44 && u32(40) == frames * 4 && u32(4) == 36 + frames * 4, "the real sizes at the end");
  long long d0 = d.size() >= 48 ? (short)u16(44) : -1, r0 = d.size() >= 48 ? (short)u16(46) : 1;
  check(d0 == -r0, "left and right as fed (right = -left)");
  direct_jam_stop(); // (twice: nothing)
  remove(path.c_str());
  printf(fails ? "jam_test: %d FAILED\n" : "jam_test: all ok\n", fails);
  return fails ? 1 : 0;
}
