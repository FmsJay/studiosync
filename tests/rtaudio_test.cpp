// StudioSync's live audio core (extension/rtaudio.cpp: AOO + Opus) without REAPER: three endpoints on 127.0.0.1, each with its own UDP
// port, driven by a test clock that plays the audio thread (48 kHz, 256-sample blocks, in real time). A sends a 440 Hz sine; B hears A
// through Opus and the jitter buffer: it has to arrive within a bounded latency and at the level it was sent. C has the wrong studio
// secret: B refuses every datagram from it and hears nothing of its 1 kHz tone. Then B mutes A (the cue mix) and A goes quiet there; then
// C is given the right secret (the peers JSON again, while running) and B hears its tone. The secret and ports go in as lib/liveaudio.lua's
// JSON does (StudioSync_LiveAudioPeers). Then C mutes what it sends (Mute me: silence, the stream kept) and unmutes, heard again at once; then
// C leaves B out of what it sends (talkback to someone else) and lets it back in. Then Wi-Fi's bursts (the adaptive buffer), then Play
// (the second stream, from a Hop's ring: heard apart from Talk).
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
#include "../plugin/hop_shm.h" // (Play: the test writes a Hop's send ring as the live out track's plug-in does)

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
    printf("E: %s\n     bursts: buffer grew to %.0f ms; underruns %lld at 4.5 s, %lld at 9 s; after the bursts and quiet: %.0f ms (floor %s)\n", se.c_str(), grown,
           u_settled, u_off, after_ms, field(se, pd, "floor_ms").c_str());
    check(set_ok, "bursts: a peer's floor and ceiling are set (a peer not in the list: 0)");
    check(grown > 30, "bursts: E's buffer for D grew past 30 ms");
    check(u_settled >= 0 && u_off == u_settled, "bursts: after settling, no more underruns");
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
  rt_free(A); rt_free(B); rt_free(C); rt_free(bad);
  printf(fails ? "fails %d\n" : "ok, fails 0\n", fails);
  return fails ? 1 : 0;
}
