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
static void drop_dir(const std::string &d) // (the rendezvous files a case leaves, then the folder)
{
  for (const char *f : { "/devA-devB.json", "/devB-devA.json", "/devA-devB.json.tmp", "/devB-devA.json.tmp", "/a.key", "/b.key", "/x.key" }) remove((d + f).c_str());
#ifdef _WIN32
  _rmdir(d.c_str());
#else
  rmdir(d.c_str());
#endif
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
  // B starts again (REAPER restarted): a new link, its offer answered afresh
  nat_hub_stop(b);
  CHECK(!nat_up(b, &sb), "hub: stopped, nothing up");
  nat_set_rx(b, rx_fn, &rb);
  CHECK(nat_hub_setup(b, setup_json(dir, "devB", "b.key", "devA", pa, port, "the studio secret").c_str()) == 1, "hub: B set up again");
  const bool again = hub_wait(a, b, "nat:devB", "nat:devA", 45000, took);
  CHECK(again, "hub: after B starts again both are up again (A notices, offers anew)");
  printf("     again in %.0f ms\n", took);
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
  ice_checks();
  printf(fails ? "FAILED %d\n" : "all ok\n", fails);
  return fails ? 1 : 0;
}
