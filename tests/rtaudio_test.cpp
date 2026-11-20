// StudioSync's live audio core (extension/rtaudio.cpp: AOO + Opus) without REAPER: three endpoints on 127.0.0.1, each with its own UDP
// port, driven by a test clock that plays the audio thread (48 kHz, 256-sample blocks, in real time). A sends a 440 Hz sine; B hears A
// through Opus and the jitter buffer: it has to arrive within a bounded latency and at the level it was sent. C has the wrong studio
// secret: B refuses every datagram from it and hears nothing of its 1 kHz tone. Then B mutes A (the cue mix) and A goes quiet there; then
// C is given the right secret (the peers JSON again, while running) and B hears its tone. The secret and ports go in as lib/liveaudio.lua's
// JSON does (StudioSync_LiveAudioPeers). Then C mutes what it sends (Mute me: silence, the stream kept) and unmutes, heard again at once; then
// C leaves B out of what it sends (talkback to someone else) and lets it back in.
// Build and run: tests\build_rtaudio_test.cmd (macOS/Linux: the CI's line in .github/workflows/extension.yml). GPL-3.0-or-later.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>
#include "../extension/rtaudio.h"

static int fails = 0;
static void check(bool ok, const char *what) { printf("%s %s\n", ok ? "  ok  " : "  FAIL", what); if (!ok) ++fails; }
static std::string field(const std::string &json, const std::string &peer, const char *key) // (a peer's value, or a top-level one with peer "")
{
  size_t at = 0;
  if (!peer.empty()) { at = json.find("\"" + peer + "\":{"); if (at == std::string::npos) return ""; }
  const size_t k = json.find(std::string("\"") + key + "\":", at);
  if (k == std::string::npos) return "";
  const size_t v = k + strlen(key) + 3, e = json.find_first_of(",}", v);
  return json.substr(v, e - v);
}

int main()
{
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
  check(atoll(field(sa, "", "sent").c_str()) > 500, "A sent its packets");
  rt_stop(A); rt_stop(B); rt_stop(C);
  check(field(rt_status(B), "", "running") == "false", "stopped");
  check(rt_start(B, 0, 2, 64, 0, "127.0.0.1") == 1, "and starts again on the same port");
  rt_free(A); rt_free(B); rt_free(C); rt_free(bad);
  printf(fails ? "fails %d\n" : "ok, fails 0\n", fails);
  return fails ? 1 : 0;
}
