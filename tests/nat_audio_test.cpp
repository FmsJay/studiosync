// Live audio over the connection without Tailscale (extension/rtaudio.cpp through extension/nat.cpp), without REAPER: two computers' NAT
// hubs (keys in files, a rendezvous folder, libjuice's own STUN server on 127.0.0.1) and two live audio links whose only peer is
// "nat:<device id>". A plays a 440 Hz sine; B has to hear it through Opus, the jitter buffer and the sealed ICE path, at the level it was
// sent, and B's status names the peer "nat:devA". B is started with no address given: on a computer without Tailscale (CI) that's the
// loopback-only mode where every peer comes through nat.cpp; with Tailscale up it binds the Tailscale address and still hears A this way.
// Build and run: tests\build_nat_audio_test.cmd (macOS/Linux: the CI's line in .github/workflows/extension.yml). GPL-3.0-or-later.
#ifdef _WIN32
#define NOMINMAX
#include <winsock2.h>
#include <windows.h>
#include <direct.h>
#define make_dir(p) _mkdir(p)
#define drop_dir_(p) _rmdir(p)
#else
#include <sys/stat.h>
#include <unistd.h>
#define make_dir(p) mkdir(p, 0700)
#define drop_dir_(p) rmdir(p)
#endif
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>
#include "../extension/nat.h"
#include "../extension/rtaudio.h"
#include "../extension/third_party/libjuice/include/juice/juice.h"

static int fails = 0;
static void check(bool ok, const char *what) { printf("%s %s\n", ok ? "  ok  " : "  FAIL", what); if (!ok) ++fails; }
static const int SR = 48000, LEN = 256;
static const double PI = 3.14159265358979323846;

static bool w_resolve(void *h, const char *p, void *o) { return nat_resolve((NatHub *)h, p, o); }
static bool w_up(void *h, const void *a) { return nat_up((NatHub *)h, a); }
static int w_send(void *h, const void *a, const void *d, int n) { return nat_sendto((NatHub *)h, a, d, n); }
static std::string w_self(void *h) { return nat_self((NatHub *)h); }
static bool w_active(void *h) { return nat_active((NatHub *)h); }
static void to_rt(void *u, const unsigned char *d, int n, const void *from) { rt_nat_rx((RtLink *)u, d, n, from); }

int main()
{
  setvbuf(stdout, nullptr, _IONBF, 0);
  juice_set_log_level(getenv("NAT_VERBOSE") ? JUICE_LOG_LEVEL_DEBUG : JUICE_LOG_LEVEL_NONE);
  juice_server_config_t sc;
  memset(&sc, 0, sizeof sc);
  sc.port = 0; sc.bind_address = "127.0.0.1"; sc.max_allocations = 8; sc.realm = "studiosync";
  juice_server_t *srv = juice_server_create(&sc);
  const int sport = srv ? juice_server_get_port(srv) : 0;
  check(srv && sport > 0, "a STUN server on 127.0.0.1 (libjuice's own)");
  const char *t = getenv("TEMP");
  if (!t) t = getenv("TMPDIR");
  unsigned char r[4];
  nat_random(r, 4);
  char dn[64];
  snprintf(dn, sizeof dn, "/ss_nat_audio_%02x%02x%02x%02x", r[0], r[1], r[2], r[3]);
  std::string dir = std::string(t ? t : "/tmp") + dn;
  for (char &c : dir) if (c == '\\') c = '/';
  make_dir(dir.c_str());
  std::string why;
  const std::string pa = nat_key_public(dir + "/a.key", why), pb = nat_key_public(dir + "/b.key", why);
  auto setup = [&](const char *me, const char *key, const char *peer, const std::string &pub) {
    return std::string("{\"folder\":\"") + dir + "\",\"me\":\"" + me + "\",\"secret\":\"the studio secret\",\"key\":\"" + dir + "/" + key +
           "\",\"port\":0,\"stun\":[\"127.0.0.1:" + std::to_string(sport) + "\"],\"peers\":[{\"device\":\"" + peer + "\",\"pub\":\"" + pub + "\"}]}";
  };
  NatHub *ha = nat_hub_new(), *hb = nat_hub_new();
  check(nat_hub_setup(ha, setup("devA", "a.key", "devB", pb).c_str()) == 1 && nat_hub_setup(hb, setup("devB", "b.key", "devA", pa).c_str()) == 1,
        "both computers' NAT hubs set up");
  RtLink *A = rt_new(), *B = rt_new();
  RtNat oa = { ha, w_resolve, w_up, w_send, w_self, w_active }, ob = { hb, w_resolve, w_up, w_send, w_self, w_active };
  rt_set_nat(A, &oa); rt_set_nat(B, &ob);
  nat_set_rx(ha, to_rt, A); nat_set_rx(hb, to_rt, B);
  const int PA = 47431, PB = 47432;
  auto peers = [](int port, const char *peer) { return std::string("{\"peers\":[\"") + peer + "\"],\"port\":" + std::to_string(port) + ",\"secret\":\"the studio secret\"}"; };
  check(rt_peers(A, peers(PA, "nat:devB").c_str()) == 1 && rt_peers(B, peers(PB, "nat:devA").c_str()) == 1, "live audio's peers: nat:devB and nat:devA");
  const auto w0 = std::chrono::steady_clock::now();
  while (std::chrono::steady_clock::now() - w0 < std::chrono::seconds(20) &&
         !(nat_hub_status(ha).find("\"state\":\"up\"") != std::string::npos && nat_hub_status(hb).find("\"state\":\"up\"") != std::string::npos))
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  check(nat_hub_status(hb).find("\"state\":\"up\"") != std::string::npos, "the link between them is up (rendezvous folder, ICE, sealed)");
  check(rt_start(A, 0, 1, 128, 0, "127.0.0.1") == 1, "A's live audio starts (on 127.0.0.1)");
  check(rt_start(B, 0, 1, 128, 0, "") == 1, "B's live audio starts with no address given");
  const std::string bind = rt_status(B);
  const bool nat_only = bind.find("\"bind\":\"127.0.0.1:") != std::string::npos;
  printf("     B is %s\n", nat_only ? "on loopback: no Tailscale here, every peer through the connection without Tailscale" : "on this computer's Tailscale address");

  const int secs = 7, blocks = secs * SR / LEN, start_blk = 2 * SR / LEN;
  std::vector<double> ia(LEN), ib(LEN, 0.0), oa_(LEN), ob_(LEN), ob2(LEN), heard;
  heard.reserve((size_t)blocks * LEN);
  const double *ina[1] = { ia.data() }, *inb[1] = { ib.data() };
  double *outa[2] = { oa_.data(), oa_.data() }, *outb[2] = { ob_.data(), ob2.data() };
  const auto t0 = std::chrono::steady_clock::now();
  long long n = 0;
  for (int b = 0; b < blocks; ++b) {
    const auto due = t0 + std::chrono::nanoseconds((long long)(1e9 * b * LEN / SR));
    while (std::chrono::steady_clock::now() < due) std::this_thread::yield();
    for (int k = 0; k < LEN; ++k, ++n) ia[k] = b >= start_blk ? 0.5 * sin(2 * PI * 440 * n / SR) : 0.0;
    std::fill(oa_.begin(), oa_.end(), 0.0); std::fill(ob_.begin(), ob_.end(), 0.0); std::fill(ob2.begin(), ob2.end(), 0.0);
    rt_capture(A, ina, 1, LEN, SR); rt_capture(B, inb, 1, LEN, SR);
    rt_mix(A, outa, 2, LEN, SR); rt_mix(B, outb, 2, LEN, SR);
    heard.insert(heard.end(), ob_.begin(), ob_.end());
  }
  const std::string sa = rt_status(A), sb = rt_status(B);
  printf("A: %s\nB: %s\nA's hub: %s\n", sa.c_str(), sb.c_str(), nat_hub_status(ha).c_str());
  long long first = -1;
  for (size_t i = (size_t)start_blk * LEN; i < heard.size() && first < 0; ++i) if (std::fabs(heard[i]) > 0.1) first = (long long)i;
  const double lat_ms = first < 0 ? -1 : (first - (double)start_blk * LEN) * 1000.0 / SR;
  printf("     A -> B: heard %.1f ms after it was played\n", lat_ms);
  check(first >= 0 && lat_ms < 200, "A's sine reaches B through the connection without Tailscale, within 200 ms");
  double pk = 0, sum = 0;
  const size_t a0 = (size_t)5 * SR, a1 = (size_t)6 * SR;
  for (size_t i = a0; i < a1 && i < heard.size(); ++i) { pk = std::max(pk, std::fabs(heard[i])); sum += heard[i] * heard[i]; }
  const double rms = sqrt(sum / (double)(a1 - a0));
  printf("     B hears A at peak %.3f, rms %.3f (sent: peak 0.500, rms 0.354)\n", pk, rms);
  check(pk > 0.4 && pk < 0.65 && rms > 0.28 && rms < 0.43, "at the level it was sent");
  check(sb.find("\"nat:devA\":{") != std::string::npos && sb.find("\"streaming\":true") != std::string::npos, "B's status: peer nat:devA, streaming");
  check(sb.find("\"rejected\":0") != std::string::npos, "B refused nothing");
  rt_stop(A); rt_stop(B);
  nat_set_rx(ha, nullptr, nullptr); nat_set_rx(hb, nullptr, nullptr);
  rt_free(A); rt_free(B);
  nat_hub_free(ha); nat_hub_free(hb);
  juice_server_destroy(srv);
  for (const char *f : { "/devA-devB.json", "/devB-devA.json", "/a.key", "/b.key" }) remove((dir + f).c_str());
  drop_dir_(dir.c_str());
  printf(fails ? "FAILED %d\n" : "ok, fails 0\n", fails);
  return fails ? 1 : 0;
}
