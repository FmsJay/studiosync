// The Tailscale-free connection spike (extension/nat.cpp, docs/realtime-roadmap.md "Without Tailscale: design"), without REAPER:
//  - the handshake and datagram sealing: both sides agree, a flipped byte / a replay / another studio's secret / an impostor without the
//    peer's static key are refused, a degenerate public key is refused; the rendezvous message's signature, addressee and age;
//  - ICE through libjuice with libjuice's own STUN/TURN server on this computer as the rendezvous's server and a temporary folder as the
//    signalling channel: two endpoints connect, exchange sealed datagrams both ways (round trips timed), then again with only relayed
//    candidates published (what two strict NATs leave), and an impostor and a wrong secret never come up.
// Modes: `nat_test` (all of the above, on this computer), `nat_test server [port] [user] [pass]` (the STUN/TURN server alone, a hub's
// job), `nat_test peer <folder> <me> <them> <secret> [stunhost:port] [user pass]` (one end, for two computers sharing a folder: real NATs;
// NAT_NO_TAILSCALE=1 publishes no candidate on a Tailscale address, so ICE can't take the tailnet).
// Build: tests\build_nat_test.cmd (macOS/Linux: the comment there). Not part of the shipped extension. GPL-3.0-or-later.
#ifdef _WIN32
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <direct.h>
#define make_dir(p) _mkdir(p)
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/stat.h>
#include <unistd.h>
#define make_dir(p) mkdir(p, 0700)
#endif
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include "../extension/nat.h"
#include "../extension/direct.h"
#include "../extension/third_party/libjuice/include/juice/juice.h"

static int fails = 0;
#define CHECK(c, what) do { if (c) printf("ok   %s\n", what); else { printf("FAIL %s\n", what); ++fails; } } while (0)
static double now_ms() { return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static void sleep_ms(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }
static long long unix_s() { return (long long)std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count(); }
static std::string temp_dir()
{
  const char *t = getenv("TEMP");
  if (!t) t = getenv("TMPDIR");
  unsigned char r[6];
  nat_random(r, sizeof r);
  char b[64];
  snprintf(b, sizeof b, "/ss_nat_%02x%02x%02x%02x%02x%02x", r[0], r[1], r[2], r[3], r[4], r[5]);
  std::string d = std::string(t ? t : "/tmp") + b;
  make_dir(d.c_str());
  return d;
}
static void remove_dir(const std::string &d)
{
#ifdef _WIN32
  _rmdir(d.c_str());
#else
  rmdir(d.c_str());
#endif
}
static void drop_dir(const std::string &d) // (the rendezvous files a case leaves, then the folder)
{
  for (const char *f : { "/devA-devB.json", "/devB-devA.json", "/devA-devB.json.tmp", "/devB-devA.json.tmp", "/a.key", "/b.key", "/x.key" }) remove((d + f).c_str());
  remove_dir(d);
}
static void stats(const char *what, std::vector<double> v)
{
  if (v.empty()) { printf("     %s: none\n", what); return; }
  std::sort(v.begin(), v.end());
  printf("     %s: median %.3f ms, p95 %.3f ms, min %.3f, max %.3f (n=%d)\n", what, v[v.size() / 2], v[(size_t)(v.size() * 0.95)], v.front(), v.back(), (int)v.size());
}

// ---- the crypto, no network ------------------------------------------------------------------------------------------------------------
static void crypto_checks()
{
  NatKeys sa, sb, ea, eb, sx;
  nat_keypair(sa); nat_keypair(sb); nat_keypair(ea); nat_keypair(eb); nat_keypair(sx);
  const std::string K = nat_studio_key("the studio secret"), K2 = nat_studio_key("another studio");
  NatSession a, b;
  CHECK(nat_derive(a, K, true, sa, sb.pub, ea, eb.pub, "devA", "devB") && nat_derive(b, K, false, sb, sa.pub, eb, ea.pub, "devA", "devB"), "handshake: both sides derive");
  CHECK(memcmp(a.tx, b.rx, 32) == 0 && memcmp(a.rx, b.tx, 32) == 0 && memcmp(a.tx, a.rx, 32) != 0, "handshake: the same keys, one per direction");
  const std::string m1 = nat_seal(a, "hello", 5), m2 = nat_seal(a, "world", 5), m3 = nat_seal(a, "!", 1);
  std::string out;
  CHECK(m1.size() == 5 + 28 && m1.find("hello") == std::string::npos, "seal: 28 bytes added, the text isn't readable");
  CHECK(nat_open(b, m2.data(), m2.size(), out) && out == "world", "open: a datagram");
  CHECK(nat_open(b, m1.data(), m1.size(), out) && out == "hello", "open: an older one inside the window (UDP reorders)");
  CHECK(!nat_open(b, m1.data(), m1.size(), out), "open: a replay is refused");
  std::string bad = m3; bad[14] ^= 1;
  CHECK(!nat_open(b, bad.data(), bad.size(), out), "open: a flipped byte is refused");
  bad = m3; bad[5] ^= 1;
  CHECK(!nat_open(b, bad.data(), bad.size(), out), "open: a changed counter is refused (it's in the tag)");
  CHECK(nat_open(b, m3.data(), m3.size(), out) && out == "!", "open: the untouched one still opens after the refusals");
  NatSession c; // (another studio's secret, everything else right)
  nat_derive(c, K2, false, sb, sa.pub, eb, ea.pub, "devA", "devB");
  const std::string m4 = nat_seal(a, "x", 1);
  CHECK(!nat_open(c, m4.data(), m4.size(), out), "open: the right keys but another studio's secret: refused");
  NatSession imp; // (the secret, but not devB's static key: someone in the studio pretending to be devB)
  nat_derive(imp, K, false, sx, sa.pub, eb, ea.pub, "devA", "devB");
  CHECK(!nat_open(imp, m4.data(), m4.size(), out), "open: the secret without the peer's own key: refused (an impostor)");
  NatSession z;
  unsigned char zero[32] = {};
  CHECK(!nat_derive(z, K, true, sa, sb.pub, ea, zero, "devA", "devB"), "handshake: a degenerate (all-zero) public key is refused");
  // the rendezvous message
  const long long t = unix_s();
  const std::string sig = nat_signal(K, "offer", "devA", "devB", ea.pub, nullptr, t, "a=ice-ufrag:x\r\na=candidate:1 1 UDP 1 10.0.0.1 5000 typ host\r\n");
  std::string kind, sdp, why;
  unsigned char pe[32], re[32];
  CHECK(nat_signal_read(K, sig, "devB", "devA", t, kind, pe, re, sdp, why) && kind == "offer" && memcmp(pe, ea.pub, 32) == 0 && sdp.find("typ host") != std::string::npos, "rendezvous: a signed offer reads back");
  CHECK(!nat_signal_read(K2, sig, "devB", "devA", t, kind, pe, re, sdp, why), "rendezvous: another studio's secret: refused");
  CHECK(!nat_signal_read(K, sig, "devC", "devA", t, kind, pe, re, sdp, why), "rendezvous: for another computer: refused");
  CHECK(!nat_signal_read(K, sig, "devB", "devA", t + 600, kind, pe, re, sdp, why), "rendezvous: ten minutes old: refused");
  std::string tampered = sig;
  tampered[tampered.find("sdp ") + 10] ^= 1;
  CHECK(!nat_signal_read(K, tampered, "devB", "devA", t, kind, pe, re, sdp, why), "rendezvous: a changed candidate: refused");
}

// ---- ICE -------------------------------------------------------------------------------------------------------------------------------
struct Pair { NatLink *a = nullptr, *b = nullptr; };
static NatLinkConfig cfg(const std::string &dir, const char *me, const char *peer, const char *secret, const NatKeys &mine, const NatKeys &theirs, int port, bool relay)
{
  NatLinkConfig c;
  c.folder = dir; c.me = me; c.peer = peer; c.secret = secret; c.my_static = mine;
  memcpy(c.peer_static, theirs.pub, 32);
  c.stun_host = "127.0.0.1"; c.stun_port = port; c.turn_user = "studio"; c.turn_pass = "turn-test-pass"; c.only = relay ? 1 : 0;
  return c;
}
static bool wait_up(NatLink *a, NatLink *b, double ms, double &took)
{
  const double t0 = now_ms();
  int ra = 0, rb = 0;
  while (now_ms() - t0 < ms) {
    ra = nat_link_tick(a); rb = b ? nat_link_tick(b) : 1;
    if ((ra == 1 && rb == 1) || ra < 0 || rb < 0) break;
    sleep_ms(5);
  }
  took = now_ms() - t0;
  return ra == 1 && rb == 1;
}
static void exchange(NatLink *a, NatLink *b, int n)
{
  std::vector<double> rtt;
  int good_ab = 0, good_ba = 0;
  for (int i = 0; i < n; ++i) {
    char ping[64];
    snprintf(ping, sizeof ping, "ping %d", i);
    const double t0 = now_ms();
    nat_link_send(a, ping, strlen(ping));
    bool back = false;
    std::string got;
    while (now_ms() - t0 < 1000 && !back) {
      if (nat_link_recv(b, got)) { if (got == ping) { ++good_ab; got[1] = 'o'; nat_link_send(b, got.data(), got.size()); } }
      if (nat_link_recv(a, got)) { std::string want = ping; want[1] = 'o'; if (got == want) { ++good_ba; back = true; rtt.push_back(now_ms() - t0); } }
      if (!back) std::this_thread::yield();
    }
  }
  printf("     %d of %d arrived A->B, %d of %d B->A\n", good_ab, n, good_ba, n);
  stats("sealed round trip (ICE, both ends here)", rtt);
  CHECK(good_ab >= n * 98 / 100 && good_ba >= n * 98 / 100, "datagrams both ways, sealed and opened (98%+: it's UDP)");
}
// ---- the hub, as REAPER runs it: two computers' hubs, keys in files, synthetic addresses, live audio's send and receive -----------------
struct Rx { std::mutex mx; std::vector<std::string> got; std::string from; };
static void rx_fn(void *user, const unsigned char *d, int n, const void *from)
{
  Rx *r = (Rx *)user;
  const sockaddr_in &a = *(const sockaddr_in *)from;
  char b[32];
  const unsigned char *p = (const unsigned char *)&a.sin_addr;
  snprintf(b, sizeof b, "%u.%u.%u.%u:%u", p[0], p[1], p[2], p[3], ntohs(a.sin_port));
  std::lock_guard<std::mutex> g(r->mx);
  r->got.emplace_back((const char *)d, (size_t)n);
  r->from = b;
}
static std::string json_field(const std::string &j, const char *k) // (a string value, for the checks)
{
  const std::string key = std::string("\"") + k + "\":\"";
  const size_t a = j.find(key);
  if (a == std::string::npos) return "";
  const size_t e = j.find('"', a + key.size());
  return j.substr(a + key.size(), e - a - key.size());
}
static std::string setup_json(const std::string &dir, const char *me, const char *key, const char *peer, const std::string &pub, int port, const char *secret)
{
  char b[1400];
  snprintf(b, sizeof b, "{\"folder\":\"%s\",\"me\":\"%s\",\"secret\":\"%s\",\"key\":\"%s/%s\",\"port\":0,\"stun\":[\"127.0.0.1:%d\",\"127.0.0.1:%d\"],"
           "\"peers\":[{\"device\":\"%s\",\"pub\":\"%s\"}]}", dir.c_str(), me, secret, dir.c_str(), key, port, port, peer, pub.c_str());
  std::string s = b;
  for (char &c : s) if (c == '\\') c = '/';
  return s;
}
static bool hub_wait(NatHub *a, NatHub *b, const char *pa, const char *pb, double ms, double &took)
{
  const double t0 = now_ms();
  while (now_ms() - t0 < ms) {
    if (nat_hub_status(a).find("\"state\":\"up\"") != std::string::npos && nat_hub_status(b).find("\"state\":\"up\"") != std::string::npos) break;
    sleep_ms(20);
  }
  took = now_ms() - t0;
  sockaddr_in x{}, y{};
  return nat_resolve(a, pa, &x) && nat_resolve(b, pb, &y) && nat_up(a, &x) && nat_up(b, &y);
}
// ---- stage 2: reliable streams (NatRel alone, through a simulated lossy path; then the direct link over two hubs) --------------------------
static unsigned rnd(unsigned &r) { r = r * 1103515245u + 12345u; return (r >> 8) % 1000; }
struct Hop { double at; std::string seg; };
// a -> b `ab` bytes and b -> a `ba` bytes, each segment dropped / doubled per mille, every one delayed 20-50 ms (so they reorder); the reader
// on b takes nothing until `stall` s (the window shuts, then opens). -> both sides got everything in order and finished.
static bool rel_run(const char *what, int drop, int dup, size_t ab, size_t ba, double stall = 0, bool show = true)
{
  NatRel a, b;
  unsigned r = 7;
  std::string want_ab(ab, '\0'), want_ba(ba, '\0'), got_ab, got_ba;
  for (char &c : want_ab) c = (char)rnd(r);
  for (char &c : want_ba) c = (char)rnd(r);
  std::vector<Hop> to_a, to_b;
  size_t wa = 0, wb = 0;
  double t = 0;
  long long segs = 0;
  for (; t < 120 && !(a.done() && b.done()); t += 0.001) {
    wa += a.write(want_ab.data() + wa, want_ab.size() - wa); if (wa == want_ab.size()) a.close();
    wb += b.write(want_ba.data() + wb, want_ba.size() - wb); if (wb == want_ba.size()) b.close();
    for (int side = 0; side < 2; ++side) {
      NatRel &s = side ? b : a;
      std::vector<NatSeg> out;
      s.pump(t, out);
      for (const NatSeg &g : out) {
        ++segs;
        const std::string w = nat_seg_encode(g.flags, 1, g.off, s.ack_no(), s.wnd(), g.data);
        if ((int)rnd(r) < drop) continue;
        for (int k = (int)rnd(r) < dup ? 2 : 1; k-- > 0;) (side ? to_a : to_b).push_back({ t + 0.020 + rnd(r) * 0.00003, w });
      }
    }
    for (int side = 0; side < 2; ++side) {
      std::vector<Hop> &q = side ? to_a : to_b;
      NatRel &s = side ? a : b;
      for (size_t i = 0; i < q.size();) {
        if (q[i].at > t) { ++i; continue; }
        unsigned char f; uint32_t id, w; uint64_t off, ack; const char *d; size_t dn;
        if (nat_seg_decode(q[i].seg.data(), q[i].seg.size(), f, id, off, ack, w, d, dn)) s.input(f, off, ack, w, d, dn, t);
        q.erase(q.begin() + (long)i);
      }
    }
    if (t >= stall) { got_ab += b.rbuf; b.took(b.rbuf.size()); }
    got_ba += a.rbuf; a.took(a.rbuf.size());
  }
  const bool ok = got_ab == want_ab && got_ba == want_ba && a.done() && b.done() && !a.dead && !b.dead;
  if (show) printf("     %s: %.2f s simulated, %lld segments, %lld + %lld sent again, %lld + %lld refused\n", what, t, segs, a.resent, b.resent, a.dropped, b.dropped);
  return ok;
}
static void rel_checks()
{
  CHECK(rel_run("clean", 0, 0, 300000, 5000), "stream: 300 KB one way, 5 KB back, in order, both FINs answered");
  CHECK(rel_run("10% lost", 100, 0, 300000, 5000), "stream: 10% of segments lost each way: all of it still arrives, in order");
  CHECK(rel_run("30% lost", 300, 0, 100000, 1000), "stream: 30% lost: still all of it");
  CHECK(rel_run("doubled", 0, 300, 200000, 2000), "stream: 30% of segments doubled: each byte once");
  CHECK(rel_run("all three", 150, 150, 200000, 20000), "stream: lost, doubled and reordered together");
  CHECK(rel_run("reader stalls 2 s", 50, 0, 2 * NAT_RCV_WND, 100, 2.0), "stream: a reader that takes nothing for 2 s: the window shuts, then opens, nothing lost");
  { // nothing gets through: dead after its tries, not forever
    NatRel a;
    a.write("hello", 5);
    std::vector<NatSeg> out;
    double t = 0;
    for (; t < 60 && !a.dead; t += 0.01) { out.clear(); a.pump(t, out); }
    CHECK(a.dead && t > 5 && t < 40, "stream: no answer at all: given up after its tries (direct.cpp sees the connection drop)");
  }
  { // what a segment may not be
    unsigned char f; uint32_t id, w; uint64_t off, ack; const char *d; size_t dn;
    const std::string big = nat_seg_encode(0, 1, 0, 0, 0, std::string(NAT_SEG + 1, 'x')), odd = nat_seg_encode(0x40, 1, 0, 0, 0, "x"), ok = nat_seg_encode(NAT_F_OPEN, 9, 5, 6, 7, "abc");
    CHECK(!nat_seg_decode(big.data(), big.size(), f, id, off, ack, w, d, dn), "segment: one bigger than any sent (1201 bytes of data) is refused whole");
    CHECK(!nat_seg_decode(odd.data(), odd.size(), f, id, off, ack, w, d, dn) && !nat_seg_decode(ok.data(), 10, f, id, off, ack, w, d, dn), "segment: unknown flags or a short header: refused");
    CHECK(nat_seg_decode(ok.data(), ok.size(), f, id, off, ack, w, d, dn) && f == NAT_F_OPEN && id == 9 && off == 5 && ack == 6 && w == 7 && dn == 3, "segment: a good one reads back");
    NatRel b;
    const std::string beyond(100, 'x');
    b.input(0, NAT_RCV_WND, 0, NAT_RCV_WND, beyond.data(), beyond.size(), 0);
    CHECK(b.dropped == 1 && b.rbuf.empty() && b.ooo.empty(), "stream: bytes past the receive window are refused (the size cap), not held");
    NatRel c;
    c.write("abc", 3);
    std::vector<NatSeg> out;
    c.pump(0, out);
    c.input(0, 0, 1000000, NAT_RCV_WND, nullptr, 0, 0.01);
    CHECK(c.una == 3 && c.sbuf.empty(), "stream: an ack past what was sent counts only what was sent");
    c.input(NAT_F_RST, 0, 0, 0, nullptr, 0, 0.02);
    CHECK(c.dead, "stream: a reset ends it");
  }
}

// The direct link over the hubs' link (direct.cpp is one per process: here it sends to "nat:devB" through hub A, and hub B hands what
// arrives back to the same direct.cpp's server, as two computers' would).
#ifdef _WIN32
typedef SOCKET tsock;
static void sock_close(unsigned long long s) { closesocket((SOCKET)s); }
#else
typedef int tsock;
static void sock_close(unsigned long long s) { close((int)s); }
#endif
static std::string slurp_file(const std::string &p) { std::string s; FILE *f = fopen(p.c_str(), "rb"); if (!f) return s; char b[65536]; size_t n; while ((n = fread(b, 1, sizeof b, f)) > 0) s.append(b, n); fclose(f); return s; }
static int raw_answer(NatHub *a, const std::string &frame) // a frame straight onto a stream to devB -> its answer byte, -1 none
{
  std::string why;
  const unsigned long long s = nat_connect(a, "devB", why);
  if (s == ~0ULL) return -1;
#ifdef _WIN32
  DWORD tmo = 5000;
  setsockopt((SOCKET)s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&tmo, sizeof tmo);
  u_long nb = 0;
  ioctlsocket((SOCKET)s, FIONBIO, &nb);
#else
  timeval tmo = { 5, 0 };
  setsockopt((int)s, SOL_SOCKET, SO_RCVTIMEO, &tmo, sizeof tmo);
#endif
  size_t at = 0;
  while (at < frame.size()) { const int k = (int)send((tsock)s, frame.data() + at, (int)std::min<size_t>(frame.size() - at, 65536), 0); if (k <= 0) break; at += (size_t)k; }
  char c = 0;
  const int k = (int)recv((tsock)s, &c, 1, 0);
  sock_close(s);
  return k == 1 ? (unsigned char)c : -1;
}
static long long json_num(const std::string &j, const char *k) { const std::string key = std::string("\"") + k + "\":"; const size_t a = j.find(key); return a == std::string::npos ? -1 : atoll(j.c_str() + a + key.size()); }
static int msgs_after(int &seq, std::vector<std::string> &got)
{
  int n = 0;
  for (;;) {
    const std::string m = direct_msg_poll(seq);
    if (m.empty()) return n;
    seq = atoi(m.c_str());
    got.push_back(m.substr(m.rfind('\t') + 1));
    ++n;
  }
}
static void link_checks(NatHub *a, NatHub *b, const std::string &dir)
{
  direct_set_nat([](void *h, const char *dev, std::string &why) { return nat_connect((NatHub *)h, dev, why); }, a);
  const std::string inbox = dir + "/inbox";
  direct_start("studio1", "the studio secret", inbox.c_str(), -1, ""); // (send only: no Tailscale listener; what arrives comes over the link)
  nat_test_lossy(a, 100, 50, 100); nat_test_lossy(b, 100, 50, 100); // (10% lost, 5% doubled, 10% held back behind the next, each way)
  int seq = 0;
  std::vector<std::string> got;
  msgs_after(seq, got);
  got.clear();
  const double t0 = now_ms();
  for (int i = 0; i < 300; ++i) { char m[32]; snprintf(m, sizeof m, "move %d", i); direct_msg("studio1", "ctl", m, "nat:devB"); if (i % 20 == 19) sleep_ms(5); }
  while (got.size() < 300 && now_ms() - t0 < 30000) { msgs_after(seq, got); sleep_ms(5); }
  bool order = got.size() == 300;
  for (size_t i = 0; order && i < got.size(); ++i) order = got[i] == "move " + std::to_string(i);
  printf("     300 messages through 10%% loss, 5%% doubling, 10%% reordering: %d arrived in %.0f ms\n", (int)got.size(), now_ms() - t0);
  CHECK(order, "direct link over the link: 300 messages (a controller's moves) arrive once each, in order, through loss, doubling and reordering");
  // an event file, and one of 1 MB
  const std::string rel = "song/rooms/main/events/u-20261120-120000Z-abc.json", rel2 = "song/rooms/main/events/u-20261120-120001Z-big.json";
  std::string body = "{\"kind\":\"edit\"}", big(1 << 20, 'e');
  for (size_t i = 0; i < big.size(); i += 97) big[i] = (char)('a' + i % 26);
  const std::string src = dir + "/ev.json", src2 = dir + "/big.json";
  { FILE *f = fopen(src.c_str(), "wb"); fwrite(body.data(), 1, body.size(), f); fclose(f); f = fopen(src2.c_str(), "wb"); fwrite(big.data(), 1, big.size(), f); fclose(f); }
  direct_send("studio1", rel.c_str(), src.c_str(), "nat:devB");
  direct_send("studio1", rel2.c_str(), src2.c_str(), "nat:devB");
  std::string in1, in2;
  const double t1 = now_ms();
  while ((in1 != body || in2 != big) && now_ms() - t1 < 60000) { in1 = slurp_file(inbox + "/" + rel); in2 = slurp_file(inbox + "/" + rel2); sleep_ms(20); }
  printf("     the 1 MB event file in %.0f ms\n", now_ms() - t1);
  CHECK(in1 == body && in2 == big, "direct link over the link: an event file and a 1 MB one land in the inbox whole");
  // the clock
  direct_peers("studio1", "nat:devB");
  const double t2 = now_ms();
  while (json_num(direct_clock(), "samples") < 4 && now_ms() - t2 < 20000) sleep_ms(50);
  printf("     clock: %s\n", direct_clock());
  CHECK(json_num(direct_clock(), "samples") >= 4, "direct link over the link: the clock's pings answered (signed), an estimate made");
  const std::string st = direct_status();
  CHECK(st.find("\"nat:devB\":{\"ok\":true") != std::string::npos, "direct link's status: the peer nat:devB answered");
  nat_test_lossy(a, 0, 0, 0); nat_test_lossy(b, 0, 0, 0);
  // refusals: a forged frame and an oversized one, straight onto a stream
  const long long rej = json_num(direct_status(), "rejected");
  CHECK(raw_answer(a, direct_frame(direct_derive_key("another studio"), "studio1", "chat", "hi", "SSM1")) == 3, "a frame signed with another secret, over the link: refused (3)");
  std::string over = direct_frame(direct_derive_key("the studio secret"), "studio1", "chat", std::string(70000, 'x'), "SSM1");
  CHECK(raw_answer(a, over) == 5, "a message over 64 KB, over the link: refused (5) before it's read whole");
  CHECK(json_num(direct_status(), "rejected") >= rej + 2, "both counted as refused");
  CHECK(raw_answer(a, std::string("GET / HTTP/1.1\r\nHost: x\r\n\r\n")) == 1, "an HTTP request over the link never reaches the web UI: not StudioSync's (1)");
  // a forged datagram: a copy of a real one with a flipped byte, as if from the network
  std::string raw = nat_test_sealed(a, "devB");
  const long long refused0 = json_num(nat_hub_status(b), "refused");
  if (raw.size() > 20) raw[20] ^= 1;
  nat_test_inject(b, "devA", raw);
  CHECK(json_num(nat_hub_status(b), "refused") == refused0 + 1, "a datagram with a flipped byte is refused by the link, before any stream sees it");
  remove(src.c_str()); remove(src2.c_str());
  remove((inbox + "/" + rel).c_str()); remove((inbox + "/" + rel2).c_str());
  for (const char *d : { "/song/rooms/main/events", "/song/rooms/main", "/song/rooms", "/song", "" }) remove_dir(inbox + d);
}
static void link_after_restart(NatHub *a)
{
  (void)a;
  int seq = 0;
  std::vector<std::string> got;
  msgs_after(seq, got);
  got.clear();
  const double t0 = now_ms();
  while (got.empty() && now_ms() - t0 < 30000) { direct_msg("studio1", "ctl", "after", "nat:devB"); sleep_ms(250); msgs_after(seq, got); }
  printf("     messages through again %.0f ms after the link came back\n", now_ms() - t0);
  CHECK(!got.empty() && got[0] == "after", "direct link over the link: after the peer starts again, messages go through again (its lane reconnects)");
}

static void hub_checks(int port)
{
  const std::string dir = temp_dir();
  std::string why;
  const std::string pa = nat_key_public(dir + "/a.key", why), pb = nat_key_public(dir + "/b.key", why);
  CHECK(pa.size() == 64 && pb.size() == 64 && pa != pb, "keys: each computer's made in its own file, the public half as 64 hex");
  CHECK(nat_key_public(dir + "/a.key", why) == pa, "keys: read back the same from the file");
  NatKeys k;
  CHECK(!nat_key_load(dir + "/missing.key", k, false, why), "keys: none made when asked not to");
  NatHub *a = nat_hub_new(), *b = nat_hub_new();
  CHECK(nat_hub_setup(a, "not json") == -1 && nat_hub_status(a).find("isn't JSON") != std::string::npos, "hub: a bad setup is refused and says why");
  CHECK(nat_hub_setup(a, setup_json(dir, "devA", "a.key", "devB", pb, port, "the studio secret").c_str()) == 1 &&
        nat_hub_setup(b, setup_json(dir, "devB", "b.key", "devA", pa, port, "the studio secret").c_str()) == 1, "hub: both set up with one peer each");
  sockaddr_in sa{}, sb{};
  CHECK(nat_resolve(a, "nat:devB", &sa) && nat_is_synthetic(&sa) && !nat_resolve(a, "nat:devC", &sb) && !nat_resolve(a, "devB:47281", &sb),
        "hub: nat:devB has a synthetic address (198.18.0.0/15); an unknown device and a Tailscale name don't");
  CHECK(nat_self(b) == [&] { char t[32]; const unsigned char *p = (const unsigned char *)&sa.sin_addr; snprintf(t, sizeof t, "%u.%u.%u.%u:%u", p[0], p[1], p[2], p[3], ntohs(sa.sin_port)); return std::string(t); }(),
        "hub: devB's synthetic address is the same on both computers (live audio's sink ids depend on it)");
  Rx ra, rb;
  nat_set_rx(a, rx_fn, &ra);
  nat_set_rx(b, rx_fn, &rb);
  double took = 0;
  CHECK(hub_wait(a, b, "nat:devB", "nat:devA", 20000, took), "hub: both links up through the rendezvous folder");
  printf("     up in %.0f ms\n     A: %s\n", took, nat_hub_status(a).c_str());
  const std::string sta = nat_hub_status(a);
  CHECK(json_field(sta, "path") == "direct" && json_field(sta, "nat") == "easy", "status: the path is direct, and the STUN probe found an easy NAT (one mapping for both servers)");
  nat_resolve(b, "nat:devA", &sb);
  int sent = 0;
  for (int i = 0; i < 50; ++i) { char m[32]; snprintf(m, sizeof m, "SSL1 audio %d", i); sent += nat_sendto(a, &sa, m, (int)strlen(m)) > 0; nat_sendto(b, &sb, m, (int)strlen(m)); sleep_ms(2); }
  sleep_ms(300);
  {
    std::lock_guard<std::mutex> g(rb.mx);
    CHECK(sent == 50 && rb.got.size() >= 49 && rb.got[0] == "SSL1 audio 0", "live audio's datagrams A -> B through nat_sendto, opened and handed to B's receiver");
    CHECK(rb.from == nat_self(a), "B's receiver sees them from A's synthetic address");
  }
  { std::lock_guard<std::mutex> g(ra.mx); CHECK(ra.got.size() >= 49, "and B -> A"); }
  CHECK(nat_sendto(a, &sa, std::string(1500, 'x').data(), 1500) == -1, "a datagram over 1400 bytes isn't sent");
  link_checks(a, b, dir); // (stage 2: the direct link over these links)
  // B starts again (REAPER restarted): a new link, its offer answered afresh
  nat_hub_stop(b);
  CHECK(!nat_up(b, &sb), "hub: stopped, nothing up");
  nat_set_rx(b, rx_fn, &rb);
  CHECK(nat_hub_setup(b, setup_json(dir, "devB", "b.key", "devA", pa, port, "the studio secret").c_str()) == 1, "hub: B set up again");
  const bool again = hub_wait(a, b, "nat:devB", "nat:devA", 45000, took);
  CHECK(again, "hub: after B starts again both are up again (A notices, offers anew)");
  printf("     again in %.0f ms\n", took);
  if (again) link_after_restart(a);
  direct_shutdown();
  // A drops B from its list: the link goes
  nat_hub_setup(a, setup_json(dir, "devA", "a.key", "devC", pb, port, "the studio secret").c_str());
  CHECK(!nat_up(a, &sa) && !nat_resolve(a, "nat:devB", &sa), "hub: a peer taken off the list is dropped");
  nat_hub_free(a); nat_hub_free(b);
  drop_dir(dir);
}

static void ice_checks()
{
  juice_server_credentials_t cr[1];
  memset(cr, 0, sizeof cr);
  cr[0].username = "studio"; cr[0].password = "turn-test-pass";
  juice_server_config_t sc;
  memset(&sc, 0, sizeof sc);
  sc.port = 0; sc.bind_address = "127.0.0.1"; sc.credentials = cr; sc.credentials_count = 1; sc.max_allocations = 16; sc.realm = "studiosync";
  juice_server_t *srv = juice_server_create(&sc);
  const int port = srv ? juice_server_get_port(srv) : 0;
  CHECK(srv && port > 0, "rendezvous: STUN/TURN server up on 127.0.0.1 (libjuice's own)");
  if (!srv) return;
  printf("     server on 127.0.0.1:%d\n", port);
  NatKeys sa, sb, sx;
  nat_keypair(sa); nat_keypair(sb); nat_keypair(sx);
  for (int relay = 0; relay < 2; ++relay) {
    const std::string dir = temp_dir();
    NatLink *a = nat_link_new(cfg(dir, "devA", "devB", "the studio secret", sa, sb, port, relay != 0));
    NatLink *b = nat_link_new(cfg(dir, "devB", "devA", "the studio secret", sb, sa, port, relay != 0));
    double took = 0;
    const bool up = a && b && wait_up(a, b, 20000, took);
    char what[160];
    snprintf(what, sizeof what, "ICE %s: both ends up (rendezvous folder + STUN/TURN), in %.0f ms", relay ? "relayed only (TURN)" : "any path", took);
    CHECK(up, what);
    if (a) printf("     A: %s\n", nat_link_status(a).c_str());
    if (b) printf("     B: %s\n", nat_link_status(b).c_str());
    if (up) {
      if (relay) CHECK(nat_link_status(a).find("typ relay") != std::string::npos, "the chosen path goes through the relay");
      exchange(a, b, 200);
      std::string raw = nat_link_last_sealed(b), got;
      nat_link_inject(a, raw);
      CHECK(!nat_link_recv(a, got), "a captured datagram played again: refused");
    }
    nat_link_free(a); nat_link_free(b); drop_dir(dir);
  }
  { // an impostor: has the studio secret, claims to be devB, but hasn't devB's static key
    const std::string dir = temp_dir();
    NatLink *a = nat_link_new(cfg(dir, "devA", "devB", "the studio secret", sa, sb, port, false));
    NatLink *x = nat_link_new(cfg(dir, "devB", "devA", "the studio secret", sx, sa, port, false));
    double took = 0;
    wait_up(a, x, 4000, took);
    const std::string st = nat_link_status(a);
    CHECK(nat_link_tick(a) != 1 && st.find("refused 0") == std::string::npos, "an impostor with the secret but not the computer's key never comes up (its datagrams refused)");
    nat_link_free(a); nat_link_free(x); drop_dir(dir);
  }
  { // another studio's secret: its rendezvous file is refused before ICE starts
    const std::string dir = temp_dir();
    NatLink *a = nat_link_new(cfg(dir, "devA", "devB", "the studio secret", sa, sb, port, false));
    NatLink *x = nat_link_new(cfg(dir, "devB", "devA", "not the secret", sb, sa, port, false));
    double took = 0;
    wait_up(a, x, 3000, took);
    const std::string st = nat_link_status(x);
    CHECK(nat_link_tick(x) != 1 && st.find("signature") != std::string::npos, "another studio's secret: the offer is refused at the rendezvous");
    nat_link_free(a); nat_link_free(x); drop_dir(dir);
  }
  hub_checks(port);
  juice_server_destroy(srv);
}

// ---- the modes for real NATs -----------------------------------------------------------------------------------------------------------
static std::string slurp(const std::string &p) { std::string s; FILE *f = fopen(p.c_str(), "rb"); if (!f) return s; char b[4096]; size_t n; while ((n = fread(b, 1, sizeof b, f)) > 0) s.append(b, n); fclose(f); return s; }
static void spit(const std::string &p, const void *d, size_t n) { FILE *f = fopen(p.c_str(), "wb"); if (f) { fwrite(d, 1, n, f); fclose(f); } }
static int run_server(int argc, char **argv)
{
  juice_server_credentials_t cr[1];
  memset(cr, 0, sizeof cr);
  cr[0].username = argc > 3 ? argv[3] : "studio"; cr[0].password = argc > 4 ? argv[4] : "change-me";
  juice_server_config_t sc;
  memset(&sc, 0, sizeof sc);
  sc.port = (uint16_t)(argc > 2 ? atoi(argv[2]) : 3478); sc.credentials = cr; sc.credentials_count = 1; sc.max_allocations = 64; sc.realm = "studiosync";
  juice_server_t *srv = juice_server_create(&sc);
  if (!srv) { printf("couldn't start on UDP %d\n", sc.port); return 1; }
  printf("STUN/TURN on UDP %d (user %s); Ctrl+C stops\n", juice_server_get_port(srv), cr[0].username);
  for (;;) sleep_ms(1000);
}
static int run_peer(int argc, char **argv)
{
  if (argc < 6) { printf("nat_test peer <folder> <me> <them> <secret> [stunhost:port] [user pass]\n"); return 2; }
  const std::string dir = argv[2], me = argv[3], them = argv[4];
  NatKeys mine;
  const std::string kf = dir + "/" + me + ".key"; // (the spike keeps both halves here; the design keeps the private half on this computer only)
  std::string k = slurp(kf);
  if (k.size() == 64) { memcpy(mine.pub, k.data(), 32); memcpy(mine.priv, k.data() + 32, 32); }
  else { nat_keypair(mine); k.assign((const char *)mine.pub, 32); k.append((const char *)mine.priv, 32); spit(kf, k.data(), 64); }
  spit(dir + "/" + me + ".pub", mine.pub, 32);
  printf("waiting for %s.pub in %s\n", them.c_str(), dir.c_str());
  std::string theirs;
  while ((theirs = slurp(dir + "/" + them + ".pub")).size() != 32) sleep_ms(200);
  NatKeys tk{};
  memcpy(tk.pub, theirs.data(), 32);
  NatLinkConfig c = cfg(dir, me.c_str(), them.c_str(), argv[5], mine, tk, 0, false);
  c.stun_host.clear(); c.turn_user.clear();
  if (argc > 6) { std::string hp = argv[6]; const size_t col = hp.rfind(':'); c.stun_host = hp.substr(0, col); c.stun_port = col == std::string::npos ? 3478 : atoi(hp.c_str() + col + 1); }
  if (argc > 8) { c.turn_user = argv[7]; c.turn_pass = argv[8]; }
  if (getenv("NAT_NO_TAILSCALE")) c.only = 2; // (two computers that both have Tailscale: make ICE find the way without it)
  juice_set_log_level(JUICE_LOG_LEVEL_WARN);
  NatLink *l = nat_link_new(c);
  if (!l) { printf("bad arguments\n"); return 2; }
  double took = 0;
  const bool up = wait_up(l, nullptr, 30000, took);
  printf("%s after %.0f ms\n%s\n", up ? "UP" : "NOT UP", took, nat_link_status(l).c_str());
  if (up) { // the lower id pings, the other echoes, for 20 s
    std::vector<double> rtt;
    const double t0 = now_ms();
    double next = 0;
    std::string got;
    while (now_ms() - t0 < 20000) {
      nat_link_tick(l); // (keeps saying hello until the peer has opened one of ours too)
      if (me < them && now_ms() >= next) { char b[32]; snprintf(b, sizeof b, "ping %.3f", now_ms()); nat_link_send(l, b, strlen(b)); next = now_ms() + 100; }
      while (nat_link_recv(l, got)) {
        if (got.compare(0, 5, "ping ") == 0) { got[1] = 'o'; nat_link_send(l, got.data(), got.size()); }
        else if (got.compare(0, 5, "pong ") == 0) rtt.push_back(now_ms() - atof(got.c_str() + 5));
      }
      sleep_ms(1);
    }
    if (me < them) stats("sealed round trip", rtt);
    printf("%s\n", nat_link_status(l).c_str());
  }
  nat_link_free(l);
  return up ? 0 : 1;
}

int main(int argc, char **argv)
{
  setvbuf(stdout, nullptr, _IONBF, 0);
  juice_set_log_level(getenv("NAT_VERBOSE") ? JUICE_LOG_LEVEL_DEBUG : JUICE_LOG_LEVEL_NONE);
  if (argc > 1 && !strcmp(argv[1], "server")) return run_server(argc, argv);
  if (argc > 1 && !strcmp(argv[1], "peer")) return run_peer(argc, argv);
  crypto_checks();
  rel_checks();
  ice_checks();
  printf(fails ? "FAILED %d\n" : "all ok\n", fails);
  return fails ? 1 : 0;
}
