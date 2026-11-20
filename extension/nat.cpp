// StudioSync's connection without Tailscale (docs/realtime-roadmap.md "Without Tailscale: design"): see nat.h. Stage 1: live audio's
// datagrams for the bandmates the tailnet doesn't reach, while the studio has band.json "nat" on (lib/nat.lua decides who and when).
// GPL-3.0-or-later. libjuice (MPL-2.0) and Monocypher (CC0-1.0 / BSD-2-Clause): extension/third_party/README.md.
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <bcrypt.h>
#pragma comment(lib, "bcrypt.lib")
typedef SOCKET nat_sock_t;
#define NAT_BAD_SOCK INVALID_SOCKET
#define nat_close closesocket
#else
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
typedef int nat_sock_t;
#define NAT_BAD_SOCK (-1)
#define nat_close close
#endif
#include <cctype>
#include <cstdlib>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>
#include "nat.h"
#include "direct.h"
#ifndef JUICE_STATIC
#define JUICE_STATIC // (libjuice is built into the extension: no dllimport)
#endif
#include "third_party/libjuice/include/juice/juice.h"
extern "C" {
#include "third_party/monocypher/monocypher.h"
}

// ---- keys ------------------------------------------------------------------------------------------------------------------------------
bool nat_random(void *p, size_t n)
{
#ifdef _WIN32
  return BCryptGenRandom(nullptr, (PUCHAR)p, (ULONG)n, BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0;
#elif defined(__APPLE__)
  arc4random_buf(p, n);
  return true;
#else
  FILE *f = fopen("/dev/urandom", "rb");
  if (!f) return false;
  const bool ok = fread(p, 1, n, f) == n;
  fclose(f);
  return ok;
#endif
}
bool nat_keypair(NatKeys &k)
{
  if (!nat_random(k.priv, 32)) return false;
  crypto_x25519_public_key(k.pub, k.priv);
  return true;
}
static std::string hmac(const std::string &key, const std::string &msg)
{
  unsigned char out[32];
  direct_hmac_sha256((const unsigned char *)key.data(), key.size(), (const unsigned char *)msg.data(), msg.size(), out);
  return std::string((const char *)out, 32);
}
std::string nat_studio_key(const std::string &secret) { return secret.empty() ? "" : hmac(secret, "StudioSync nat v1"); }

// ---- the handshake: Noise KK's three DHs (ee, es, se) mixed with the studio key as a pre-shared key ------------------------------------
bool nat_derive(NatSession &s, const std::string &K, bool initiator, const NatKeys &ms, const unsigned char ts[32], const NatKeys &me,
                const unsigned char te[32], const std::string &id_i, const std::string &id_r)
{
  if (K.size() != 32) return false;
  unsigned char ee[32], es[32], se[32];
  crypto_x25519(ee, me.priv, te);
  if (initiator) { crypto_x25519(es, me.priv, ts); crypto_x25519(se, ms.priv, te); }  // es = DH(eI, sR), se = DH(sI, eR)
  else { crypto_x25519(es, ms.priv, te); crypto_x25519(se, me.priv, ts); }
  unsigned char oe = 0, os = 0, oz = 0;
  for (int i = 0; i < 32; ++i) { oe |= ee[i]; os |= es[i]; oz |= se[i]; }
  if (!oe || !os || !oz) { crypto_wipe(ee, 32); crypto_wipe(es, 32); crypto_wipe(se, 32); return false; } // (a low-order public key)
  const unsigned char *sI = initiator ? ms.pub : ts, *sR = initiator ? ts : ms.pub, *eI = initiator ? me.pub : te, *eR = initiator ? te : me.pub;
  std::string ikm = "SSN1 v1";
  ikm.append((const char *)ee, 32); ikm.append((const char *)es, 32); ikm.append((const char *)se, 32);
  ikm.append((const char *)sI, 32); ikm.append((const char *)sR, 32); ikm.append((const char *)eI, 32); ikm.append((const char *)eR, 32);
  ikm += id_i; ikm += '\0'; ikm += id_r;
  const std::string prk = hmac(K, ikm), kir = hmac(prk, "I->R"), kri = hmac(prk, "R->I");
  memcpy(s.tx, (initiator ? kir : kri).data(), 32);
  memcpy(s.rx, (initiator ? kri : kir).data(), 32);
  s.next = s.top = s.seen = 0;
  s.have = true;
  crypto_wipe(ee, 32); crypto_wipe(es, 32); crypto_wipe(se, 32); crypto_wipe(&ikm[0], ikm.size());
  return true;
}

// ---- datagrams -------------------------------------------------------------------------------------------------------------------------
static void nonce_of(const unsigned char *hdr, unsigned char nonce[24]) { memset(nonce, 0, 24); memcpy(nonce + 16, hdr + 4, 8); }
std::string nat_seal(NatSession &s, const void *p, size_t n)
{
  std::string out(12 + n + 16, '\0');
  unsigned char *o = (unsigned char *)&out[0];
  memcpy(o, "SSN1", 4);
  const uint64_t c = s.next++;
  for (int i = 0; i < 8; ++i) o[4 + i] = (unsigned char)(c >> (56 - 8 * i));
  unsigned char nonce[24];
  nonce_of(o, nonce);
  crypto_aead_lock(o + 12, o + 12 + n, s.tx, nonce, o, 12, (const unsigned char *)p, n);
  return out;
}
bool nat_open(NatSession &s, const void *p, size_t n, std::string &out)
{
  const unsigned char *d = (const unsigned char *)p;
  if (!s.have || n < 28 || memcmp(d, "SSN1", 4) != 0) return false;
  uint64_t c = 0;
  for (int i = 0; i < 8; ++i) c = (c << 8) | d[4 + i];
  if (s.seen && c <= s.top && (s.top - c >= 64 || ((s.seen >> (s.top - c)) & 1))) return false; // (a replay, or older than the window)
  unsigned char nonce[24];
  nonce_of(d, nonce);
  out.assign(n - 28, '\0');
  if (crypto_aead_unlock(out.empty() ? nullptr : (unsigned char *)&out[0], d + n - 16, s.rx, nonce, d, 12, d + 12, n - 28) != 0) { out.clear(); return false; }
  if (!s.seen || c > s.top) { const uint64_t sh = s.seen ? c - s.top : 0; s.seen = (sh >= 64 ? 0 : s.seen << sh) | 1; s.top = c; }
  else s.seen |= 1ULL << (s.top - c);
  return true;
}

// ---- the rendezvous message ------------------------------------------------------------------------------------------------------------
static std::string hex(const unsigned char *p, size_t n)
{
  static const char *h = "0123456789abcdef";
  std::string s;
  for (size_t i = 0; i < n; ++i) { s += h[p[i] >> 4]; s += h[p[i] & 15]; }
  return s;
}
static bool unhex(const std::string &s, std::string &out)
{
  if (s.size() % 2) return false;
  out.clear();
  for (size_t i = 0; i < s.size(); i += 2) {
    int v = 0;
    for (int k = 0; k < 2; ++k) {
      const char c = s[i + k];
      v = v * 16 + (c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1000);
    }
    if (v < 0) return false;
    out += (char)v;
  }
  return true;
}
static bool id_ok(const std::string &id)
{
  if (id.empty() || id.size() > 64) return false;
  for (char c : id) if (!(isalnum((unsigned char)c) || c == '-' || c == '_')) return false;
  return true;
}
// A JSON file of plain string fields (hex, ids, a number as text): the signature covers them in this fixed order, so the file's layout and
// any other field don't matter.
static std::string signal_body(const std::string &kind, const std::string &from, const std::string &to, const std::string &t,
                               const std::string &e, const std::string &re, const std::string &sdp)
{
  return "SSN1 " + kind + "\nfrom " + from + "\nto " + to + "\nt " + t + "\ne " + e + "\nre " + re + "\nsdp " + sdp + "\n";
}
static std::string jfield(const std::string &j, const char *key) // (a flat object's string value; "" when it isn't one)
{
  const std::string k = std::string("\"") + key + "\"";
  size_t at = 0;
  while ((at = j.find(k, at)) != std::string::npos) {
    size_t i = at + k.size();
    while (i < j.size() && (j[i] == ' ' || j[i] == '\t' || j[i] == '\r' || j[i] == '\n')) ++i;
    if (i < j.size() && j[i] == ':') {
      ++i;
      while (i < j.size() && (j[i] == ' ' || j[i] == '\t' || j[i] == '\r' || j[i] == '\n')) ++i;
      if (i >= j.size() || j[i] != '"') return "";
      const size_t e = j.find('"', i + 1);
      if (e == std::string::npos) return "";
      const std::string v = j.substr(i + 1, e - i - 1);
      return v.find('\\') == std::string::npos ? v : ""; // (nothing of ours needs an escape)
    }
    at += k.size();
  }
  return "";
}
std::string nat_signal(const std::string &K, const char *kind, const std::string &from, const std::string &to, const unsigned char eph[32],
                       const unsigned char *re, long long t, const std::string &sdp)
{
  const std::string ts = std::to_string(t), e = hex(eph, 32), r = re ? hex(re, 32) : "-", d = hex((const unsigned char *)sdp.data(), sdp.size());
  const std::string m = hmac(K, signal_body(kind, from, to, ts, e, r, d));
  return std::string("{\"v\":\"SSN1\",\"kind\":\"") + kind + "\",\"from\":\"" + from + "\",\"to\":\"" + to + "\",\"t\":\"" + ts + "\",\"e\":\"" + e +
         "\",\"re\":\"" + r + "\",\"sdp\":\"" + d + "\",\"mac\":\"" + hex((const unsigned char *)m.data(), 32) + "\"}\n";
}
bool nat_signal_read(const std::string &K, const std::string &text, const std::string &me, const std::string &peer, long long now,
                     std::string &kind, unsigned char eph[32], unsigned char re[32], std::string &sdp, std::string &why)
{
  if (K.size() != 32 || jfield(text, "v") != "SSN1") { why = "not a rendezvous message"; return false; }
  kind = jfield(text, "kind");
  const std::string from = jfield(text, "from"), to = jfield(text, "to"), t = jfield(text, "t"), e = jfield(text, "e"), r = jfield(text, "re"),
                    s = jfield(text, "sdp");
  std::string got;
  if (!unhex(jfield(text, "mac"), got) || got.size() != 32) { why = "no signature"; return false; }
  const std::string want = hmac(K, signal_body(kind, from, to, t, e, r, s));
  unsigned char d = 0;
  for (int i = 0; i < 32; ++i) d |= (unsigned char)(got[i] ^ want[i]);
  if (d) { why = "the signature doesn't match the studio secret"; return false; }
  std::string eb, rb;
  if (from != peer || to != me || !id_ok(from) || !id_ok(to)) { why = "not from that computer to this one"; return false; }
  if (t.empty() || llabs(now - atoll(t.c_str())) > NAT_SIGNAL_AGE) { why = "too old (or the clocks are minutes apart)"; return false; }
  if (!unhex(e, eb) || eb.size() != 32 || !unhex(s, sdp)) { why = "a damaged message"; return false; }
  memcpy(eph, eb.data(), 32);
  memset(re, 0, 32);
  if (r != "-") { if (!unhex(r, rb) || rb.size() != 32) { why = "a damaged message"; return false; } memcpy(re, rb.data(), 32); }
  return true;
}

// ---- one ICE link ----------------------------------------------------------------------------------------------------------------------
struct NatLink {
  NatLinkConfig c;
  std::string K, why, sdp_path_out, sdp_path_in, last_sealed;
  bool initiator = false, sent = false, got = false, failed = false;
  NatKeys eph{};
  unsigned char offer_e[32] = {}; // (the responder: the offer's ephemeral key, sent back in the answer)
  unsigned char peer_e[32] = {};  // (the peer's ephemeral key this session was made with: a new one in its file means it started again)
  juice_agent_t *agent = nullptr;
  juice_turn_server_t turn{};
  std::atomic<int> state{ 0 };
  std::atomic<bool> gathered{ false }, ready{ false }, up{ false }, heard{ false }; // (up: a datagram from the peer opened; heard: the peer says it has one of ours)
  std::mutex mx; // (the session's counters and the queue: juice's thread receives, the caller's sends)
  NatSession sess;
  std::deque<std::string> inq;
  long long rx_ok = 0, rx_bad = 0, tx = 0;
  double t0 = 0, next_hello = 0, next_look = 0;
};
static double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static long long unix_s() { return (long long)std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count(); }
// Files by UTF-8 path (a studio folder or a user name with accents: Windows' fopen reads the path in the local code page).
#ifdef _WIN32
static std::wstring wide(const std::string &s)
{
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  std::wstring w(n > 1 ? (size_t)n - 1 : 0, L'\0');
  if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], n);
  return w;
}
static FILE *ufopen(const std::string &p, bool write) { return _wfopen(wide(p).c_str(), write ? L"wb" : L"rb"); }
static bool umove(const std::string &a, const std::string &b) { return MoveFileExW(wide(a).c_str(), wide(b).c_str(), MOVEFILE_REPLACE_EXISTING) != 0; }
static void umkdir(const std::string &p) { CreateDirectoryW(wide(p).c_str(), nullptr); }
#else
static FILE *ufopen(const std::string &p, bool write) { return fopen(p.c_str(), write ? "wb" : "rb"); }
static bool umove(const std::string &a, const std::string &b) { return rename(a.c_str(), b.c_str()) == 0; }
static void umkdir(const std::string &p) { mkdir(p.c_str(), 0700); }
#endif
static std::string slurp(const std::string &p)
{
  std::string s;
  FILE *f = ufopen(p, false);
  if (!f) return s;
  char b[4096];
  size_t n;
  while ((n = fread(b, 1, sizeof b, f)) > 0 && s.size() < (1 << 20)) s.append(b, n);
  fclose(f);
  return s;
}
static bool spit_atomic(const std::string &p, const std::string &s)
{
  const std::string tmp = p + ".tmp";
  FILE *f = ufopen(tmp, true);
  if (!f) return false;
  const bool ok = fwrite(s.data(), 1, s.size(), f) == s.size();
  fclose(f);
  return ok && umove(tmp, p); // (only this side writes this name)
}

static void on_state(juice_agent_t *, juice_state_t st, void *u) { ((NatLink *)u)->state.store((int)st); }
static void on_gathered(juice_agent_t *, void *u) { ((NatLink *)u)->gathered.store(true); }
static void on_recv(juice_agent_t *, const char *d, size_t n, void *u)
{
  NatLink *l = (NatLink *)u;
  if (!l->ready.load(std::memory_order_acquire)) return;
  std::string m;
  {
    std::lock_guard<std::mutex> g(l->mx);
    if (!nat_open(l->sess, d, n, m) || m.empty()) { ++l->rx_bad; return; }
    ++l->rx_ok;
    l->up.store(true); // (key confirmation: only the peer could have sealed this)
    if (m[0] != 1) { if (m.size() > 1 && m[1] == 1) l->heard.store(true); return; } // (a hello: { 0, 1 once it has opened one of ours })
    l->heard.store(true);
    if (!l->c.on_data) { l->inq.push_back(m.substr(1)); return; }
  }
  l->c.on_data(l->c.user, m.data() + 1, m.size() - 1); // (outside the lock: the receiver may send from here)
}

NatLink *nat_link_new(const NatLinkConfig &c)
{
  if (!id_ok(c.me) || !id_ok(c.peer) || c.me == c.peer || c.secret.empty()) return nullptr;
  NatLink *l = new NatLink();
  l->c = c;
  l->K = nat_studio_key(c.secret);
  l->initiator = c.me < c.peer;
  l->sdp_path_out = c.folder + "/" + c.me + "-" + c.peer + ".json";
  l->sdp_path_in = c.folder + "/" + c.peer + "-" + c.me + ".json";
  l->t0 = now_s();
  if (!nat_keypair(l->eph)) { delete l; return nullptr; }
  juice_config_t jc;
  memset(&jc, 0, sizeof jc);
  jc.concurrency_mode = JUICE_CONCURRENCY_MODE_POLL; // (every link on libjuice's one thread)
  jc.local_port_range_begin = (uint16_t)c.port_lo; jc.local_port_range_end = (uint16_t)(c.port_hi ? c.port_hi : c.port_lo); // (0: any port)
  if (!l->c.stun_host.empty()) { jc.stun_server_host = l->c.stun_host.c_str(); jc.stun_server_port = (uint16_t)l->c.stun_port; }
  if (!l->c.turn_user.empty() && !l->c.stun_host.empty()) {
    l->turn.host = l->c.stun_host.c_str(); l->turn.port = (uint16_t)l->c.stun_port;
    l->turn.username = l->c.turn_user.c_str(); l->turn.password = l->c.turn_pass.c_str();
    jc.turn_servers = &l->turn; jc.turn_servers_count = 1;
  }
  jc.cb_state_changed = on_state; jc.cb_gathering_done = on_gathered; jc.cb_recv = on_recv; jc.user_ptr = l;
  l->agent = juice_create(&jc);
  if (!l->agent) { delete l; return nullptr; }
  if (l->initiator) juice_gather_candidates(l->agent); // (the responder gathers once it has the offer)
  return l;
}
void nat_link_free(NatLink *l)
{
  if (!l) return;
  if (l->agent) juice_destroy(l->agent);
  crypto_wipe(l->eph.priv, 32);
  crypto_wipe(l->sess.tx, 32); crypto_wipe(l->sess.rx, 32);
  delete l;
}
// The test's filters on what's published: 1 relayed candidates only, 2 none on a Tailscale address (100.64.0.0/10, fd7a:115c:a1e0::/48).
static bool on_tailscale(const std::string &line)
{
  if (line.find(" fd7a:115c:a1e0:") != std::string::npos) return true;
  const size_t at = line.find(" 100.");
  if (at == std::string::npos) return false;
  const int b = atoi(line.c_str() + at + 5);
  return b >= 64 && b <= 127;
}
static std::string filtered(const std::string &sdp, int only)
{
  std::string out;
  for (size_t i = 0; i < sdp.size();) {
    size_t e = sdp.find('\n', i);
    if (e == std::string::npos) e = sdp.size() - 1;
    const std::string line = sdp.substr(i, e - i + 1);
    const bool cand = line.compare(0, 12, "a=candidate:") == 0;
    if (!cand || (only == 1 ? line.find(" typ relay") != std::string::npos : only == 2 ? !on_tailscale(line) : true)) out += line;
    i = e + 1;
  }
  return out;
}
int nat_link_tick(NatLink *l)
{
  if (l->failed) return -1;
  if (!l->got && now_s() >= l->next_look) { // (the peer's file, 4 times a second until it's read)
    l->next_look = now_s() + 0.25;
    const std::string text = slurp(l->sdp_path_in);
    std::string kind, sdp, why;
    unsigned char pe[32], re[32];
    if (!text.empty()) {
      if (!nat_signal_read(l->K, text, l->c.me, l->c.peer, unix_s(), kind, pe, re, sdp, why)) l->why = "the peer's rendezvous file: " + why;
      else if (kind != (l->initiator ? "answer" : "offer")) l->why = "the peer's file is an " + kind;
      else if (l->initiator && memcmp(re, l->eph.pub, 32) != 0) l->why = "the peer answered an older offer";
      else {
        std::lock_guard<std::mutex> g(l->mx);
        const std::string &a = l->initiator ? l->c.me : l->c.peer, &b = l->initiator ? l->c.peer : l->c.me;
        if (!nat_derive(l->sess, l->K, l->initiator, l->c.my_static, l->c.peer_static, l->eph, pe, a, b)) { l->failed = true; l->why = "a bad key"; return -1; }
        l->ready.store(true, std::memory_order_release); // (before the peer's candidates: no datagram can arrive before the keys)
        memcpy(l->offer_e, pe, 32); // (the answer carries the offer's key back)
        memcpy(l->peer_e, pe, 32);
        l->got = true;
        juice_set_remote_description(l->agent, sdp.c_str());
        if (!l->initiator) juice_gather_candidates(l->agent);
      }
    }
  } else if (l->got && now_s() >= l->next_look) { // (made: a new ephemeral key in the peer's file means it started again, and this session is over)
    l->next_look = now_s() + 1;
    std::string kind, sdp, why;
    unsigned char pe[32], re[32];
    const std::string text = slurp(l->sdp_path_in);
    if (!text.empty() && nat_signal_read(l->K, text, l->c.me, l->c.peer, unix_s(), kind, pe, re, sdp, why) && memcmp(pe, l->peer_e, 32) != 0 &&
        (!l->initiator || memcmp(re, l->eph.pub, 32) == 0 || kind == "offer")) {
      l->failed = true; l->why = "the other computer started again"; return -1;
    }
  }
  if (l->gathered.load() && !l->sent && (l->initiator || l->got)) {
    char sdp[JUICE_MAX_SDP_STRING_LEN];
    if (juice_get_local_description(l->agent, sdp, sizeof sdp) == 0) {
      const std::string desc = filtered(sdp, l->c.only);
      const std::string msg = nat_signal(l->K, l->initiator ? "offer" : "answer", l->c.me, l->c.peer, l->eph.pub, l->initiator ? nullptr : l->offer_e, unix_s(), desc);
      if (spit_atomic(l->sdp_path_out, msg)) l->sent = true; else l->why = "can't write to the rendezvous folder";
    }
  }
  const int st = l->state.load();
  if (st == JUICE_STATE_FAILED || (st == JUICE_STATE_DISCONNECTED && l->up.load())) {
    l->failed = true;
    l->why = l->up.load() ? "the path stopped answering" : "ICE found no path (both behind strict NATs and no relay?)";
    return -1;
  }
  if ((st == JUICE_STATE_CONNECTED || st == JUICE_STATE_COMPLETED) && l->ready.load() && !(l->up.load() && l->heard.load()) && now_s() >= l->next_hello) {
    const char hello[] = { 0, (char)(l->up.load() ? 1 : 0) }; // (until both ends have opened one: neither can be sure before)
    std::string d;
    { std::lock_guard<std::mutex> g(l->mx); d = nat_seal(l->sess, hello, sizeof hello); }
    juice_send(l->agent, d.data(), d.size());
    l->next_hello = now_s() + 0.2;
  }
  const double limit = l->c.timeout_s > 0 ? l->c.timeout_s : 30;
  if (!l->up.load() && now_s() - l->t0 > limit) { l->failed = true; if (l->why.empty()) l->why = "no connection in " + std::to_string((int)limit) + " s"; return -1; }
  return l->up.load() ? 1 : 0;
}
bool nat_link_send(NatLink *l, const void *p, size_t n)
{
  if (!l->up.load() || n > 1400) return false;
  std::string m(1, '\1');
  m.append((const char *)p, n);
  std::string d;
  { std::lock_guard<std::mutex> g(l->mx); d = nat_seal(l->sess, m.data(), m.size()); ++l->tx; l->last_sealed = d; }
  return juice_send(l->agent, d.data(), d.size()) == 0;
}
bool nat_link_recv(NatLink *l, std::string &out)
{
  std::lock_guard<std::mutex> g(l->mx);
  if (l->inq.empty()) return false;
  out = std::move(l->inq.front());
  l->inq.pop_front();
  return true;
}
void nat_link_inject(NatLink *l, const std::string &raw) { on_recv(l->agent, raw.data(), raw.size(), l); }
std::string nat_link_last_sealed(NatLink *l) { std::lock_guard<std::mutex> g(l->mx); return l->last_sealed; }
// The chosen pair's kinds ("host", "srflx", "prflx", "relay"; "" before one is chosen).
static std::string typ_of(const char *cand) { const char *t = strstr(cand, " typ "); if (!t) return ""; std::string s(t + 5); return s.substr(0, s.find(' ')); }
void nat_link_path(NatLink *l, std::string &local, std::string &remote)
{
  char loc[JUICE_MAX_CANDIDATE_SDP_STRING_LEN] = "", rem[JUICE_MAX_CANDIDATE_SDP_STRING_LEN] = "";
  juice_get_selected_candidates(l->agent, loc, sizeof loc, rem, sizeof rem);
  local = typ_of(loc); remote = typ_of(rem);
}
std::string nat_link_status(NatLink *l)
{
  char loc[JUICE_MAX_CANDIDATE_SDP_STRING_LEN] = "", rem[JUICE_MAX_CANDIDATE_SDP_STRING_LEN] = "";
  juice_get_selected_candidates(l->agent, loc, sizeof loc, rem, sizeof rem);
  std::lock_guard<std::mutex> g(l->mx);
  char b[160];
  snprintf(b, sizeof b, "state %s, up %d, sent %lld, opened %lld, refused %lld", juice_state_to_string((juice_state_t)l->state.load()), (int)l->up.load(), l->tx, l->rx_ok, l->rx_bad);
  return std::string(b) + "\n  local  " + loc + "\n  remote " + rem + (l->why.empty() ? "" : "\n  why    " + l->why);
}

// ---- a small JSON reader (the setup from lib/nat.lua) ---------------------------------------------------------------------------------
namespace {
struct JV {
  int t = 0; // 0 null, 1 bool, 2 number, 3 string, 4 array, 5 object
  bool b = false; double n = 0; std::string s;
  std::vector<JV> a; std::vector<std::pair<std::string, JV>> o;
  const JV *get(const char *k) const { for (const auto &kv : o) if (kv.first == k) return &kv.second; return nullptr; }
  std::string str(const char *k) const { const JV *v = get(k); return v && v->t == 3 ? v->s : ""; }
};
void jws(const char *&p) { while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') ++p; }
void utf8(std::string &o, unsigned c)
{
  if (c < 0x80) o += (char)c;
  else if (c < 0x800) { o += (char)(0xC0 | (c >> 6)); o += (char)(0x80 | (c & 63)); }
  else if (c < 0x10000) { o += (char)(0xE0 | (c >> 12)); o += (char)(0x80 | ((c >> 6) & 63)); o += (char)(0x80 | (c & 63)); }
  else { o += (char)(0xF0 | (c >> 18)); o += (char)(0x80 | ((c >> 12) & 63)); o += (char)(0x80 | ((c >> 6) & 63)); o += (char)(0x80 | (c & 63)); }
}
bool hex4(const char *p, unsigned &c)
{
  c = 0;
  for (int i = 0; i < 4; ++i) {
    const char h = p[i];
    if (!isxdigit((unsigned char)h)) return false;
    c = c * 16 + (unsigned)(isdigit((unsigned char)h) ? h - '0' : (tolower((unsigned char)h) - 'a' + 10));
  }
  return true;
}
bool jstr(const char *&p, std::string &o)
{
  if (*p != '"') return false;
  for (++p; *p && *p != '"'; ++p) {
    if (*p != '\\') { o += *p; continue; }
    ++p;
    switch (*p) {
    case 'n': o += '\n'; break;
    case 't': o += '\t'; break;
    case 'r': o += '\r'; break;
    case 'b': o += '\b'; break;
    case 'f': o += '\f'; break;
    case 'u': {
      unsigned c = 0, d = 0;
      if (!hex4(p + 1, c)) return false;
      p += 4;
      if (c >= 0xD800 && c < 0xDC00 && p[1] == '\\' && p[2] == 'u' && hex4(p + 3, d) && d >= 0xDC00 && d < 0xE000) { // (a surrogate pair)
        c = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00);
        p += 6;
      }
      utf8(o, c);
      break;
    }
    case 0: return false;
    default: o += *p; // (a quote, a backslash, a slash)
    }
  }
  if (*p != '"') return false;
  ++p;
  return true;
}
bool jval(const char *&p, JV &v, int depth)
{
  if (depth > 16) return false;
  jws(p);
  if (*p == '"') { v.t = 3; return jstr(p, v.s); }
  if (*p == '{' || *p == '[') {
    const bool obj = *p == '{';
    const char close = obj ? '}' : ']';
    v.t = obj ? 5 : 4;
    ++p;
    jws(p);
    if (*p == close) { ++p; return true; }
    for (;;) {
      std::string k;
      if (obj) {
        jws(p);
        if (!jstr(p, k)) return false;
        jws(p);
        if (*p != ':') return false;
        ++p;
      }
      JV x;
      if (!jval(p, x, depth + 1)) return false;
      if (obj) v.o.emplace_back(k, std::move(x)); else v.a.push_back(std::move(x));
      jws(p);
      if (*p == ',') { ++p; continue; }
      if (*p == close) { ++p; return true; }
      return false;
    }
  }
  if (!strncmp(p, "true", 4)) { v.t = 1; v.b = true; p += 4; return true; }
  if (!strncmp(p, "false", 5)) { v.t = 1; p += 5; return true; }
  if (!strncmp(p, "null", 4)) { p += 4; return true; }
  char *e = nullptr;
  v.n = strtod(p, &e);
  if (e == p) return false;
  v.t = 2;
  p = e;
  return true;
}
bool jparse(const char *text, JV &v) { const char *p = text ? text : ""; if (!jval(p, v, 0)) return false; jws(p); return *p == 0; }
void jquote(std::string &o, const std::string &s)
{
  o += '"';
  for (unsigned char c : s) {
    if (c == '"' || c == '\\') { o += '\\'; o += (char)c; }
    else if (c < 0x20) { char b[8]; snprintf(b, sizeof b, "\\u%04x", c); o += b; }
    else o += (char)c;
  }
  o += '"';
}
} // namespace

// ---- this computer's static key ---------------------------------------------------------------------------------------------------------
// The file: "StudioSync nat key v1", a newline, the private half as 64 hex, beside the update key (lib/nat.lua: ~/.studiosync/nat-key).
bool nat_key_load(const std::string &path, NatKeys &k, bool create, std::string &why)
{
  if (path.empty()) { why = "no key file"; return false; }
  const std::string text = slurp(path);
  if (!text.empty()) {
    std::string raw;
    const size_t nl = text.find('\n');
    if (nl == std::string::npos || text.compare(0, nl, "StudioSync nat key v1") != 0 || !unhex(text.substr(nl + 1, 64), raw) || raw.size() != 32) {
      why = "the key file isn't one (" + path + ")";
      return false;
    }
    memcpy(k.priv, raw.data(), 32);
    crypto_wipe(&raw[0], 32);
    crypto_x25519_public_key(k.pub, k.priv);
    return true;
  }
  if (!create) { why = "no key yet"; return false; }
  if (!nat_keypair(k)) { why = "no random numbers"; return false; }
  const size_t slash = path.find_last_of("/\\");
  if (slash != std::string::npos) umkdir(path.substr(0, slash));
  std::string body = "StudioSync nat key v1\n" + hex(k.priv, 32) + "\n";
  const std::string tmp = path + ".tmp";
#ifndef _WIN32
  const mode_t old = umask(077); // (this user only, as ssh keeps its keys)
#endif
  FILE *f = ufopen(tmp, true);
#ifndef _WIN32
  umask(old);
#endif
  const bool ok = f && fwrite(body.data(), 1, body.size(), f) == body.size();
  if (f) fclose(f);
  crypto_wipe(&body[0], body.size());
  if (!ok || !umove(tmp, path)) { why = "can't write " + path; return false; }
  return true;
}
std::string nat_key_public(const std::string &path, std::string &why)
{
  NatKeys k;
  if (!nat_key_load(path, k, true, why)) return "";
  crypto_wipe(k.priv, 32);
  return hex(k.pub, 32);
}

// ---- synthetic addresses ----------------------------------------------------------------------------------------------------------------
static void synthetic_of(const std::string &dev, sockaddr_in &a)
{
  unsigned h = 2166136261u;
  for (unsigned char c : dev) { h ^= c; h *= 16777619u; }
  const unsigned v = h % 131072; // (198.18.0.0/15: benchmarking addresses, never routed anywhere)
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  unsigned char *b = (unsigned char *)&a.sin_addr;
  b[0] = 198;
  b[1] = (unsigned char)(18 + (v >> 16));
  b[2] = (unsigned char)((v >> 8) & 255);
  b[3] = (unsigned char)(v & 255);
  a.sin_port = htons(NAT_AUDIO_PORT);
}
bool nat_is_synthetic(const void *p)
{
  const sockaddr_in &a = *(const sockaddr_in *)p;
  const unsigned char *b = (const unsigned char *)&a.sin_addr;
  return a.sin_family == AF_INET && b[0] == 198 && (b[1] == 18 || b[1] == 19);
}
static bool same_sa(const sockaddr_in &a, const sockaddr_in &b) { return a.sin_addr.s_addr == b.sin_addr.s_addr && a.sin_port == b.sin_port; }

// ---- the hub ----------------------------------------------------------------------------------------------------------------------------
namespace {
struct LinkBox { // (owns one NatLink; libjuice's callbacks point at it, so it's freed only after juice_destroy)
  NatHub *h = nullptr;
  sockaddr_in addr{};
  NatLink *l = nullptr;
  ~LinkBox() { nat_link_free(l); }
};
struct HubPeer {
  std::string dev, pub_hex, why, answered_e;
  unsigned char pub[32] = {};
  sockaddr_in addr{};
  std::shared_ptr<LinkBox> box;
  double next_try = 0, up_at = -1, next_offer_look = 0;
  int fails = 0;
  bool was_up = false;
};
} // namespace
struct NatHub {
  std::mutex mx; // (the configuration and the peers; never held across file or network work)
  std::string folder, me, secret, K, keypath, err;
  NatKeys keys{};
  bool have_key = false;
  std::vector<std::pair<std::string, int>> stun;
  int port = NAT_PORT;
  std::map<std::string, std::shared_ptr<HubPeer>> peers;
  std::thread thr;
  std::atomic<bool> run{ false };
  std::atomic<nat_rx_fn> rx{ nullptr };
  std::atomic<void *> rx_user{ nullptr };
  std::atomic<int> rx_in{ 0 };
  std::string kind = "unknown", pub_addr; // (the STUN probe: easy, strict, blocked, unknown)
  double next_probe = 0;
};

static void box_rx(void *u, const char *d, size_t n)
{
  LinkBox *b = (LinkBox *)u;
  NatHub *h = b->h;
  h->rx_in.fetch_add(1);
  if (nat_rx_fn fn = h->rx.load()) fn(h->rx_user.load(), (const unsigned char *)d, (int)n, &b->addr);
  h->rx_in.fetch_sub(1);
}

// One STUN binding request (RFC 5389) from `s` to host:port -> the mapped address as "ip:port", or "".
static std::string stun_mapped(nat_sock_t s, const std::string &host, int port)
{
  addrinfo hints{}, *res = nullptr;
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_DGRAM;
  if (getaddrinfo(host.c_str(), std::to_string(port).c_str(), &hints, &res) != 0 || !res) return "";
  sockaddr_in to = *(const sockaddr_in *)res->ai_addr;
  freeaddrinfo(res);
  unsigned char req[20] = { 0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42 };
  nat_random(req + 8, 12);
  for (int attempt = 0; attempt < 3; ++attempt) {
    sendto(s, (const char *)req, 20, 0, (const sockaddr *)&to, sizeof to);
    const double until = now_s() + 0.7;
    while (now_s() < until) {
      unsigned char buf[512];
      sockaddr_in from{};
      socklen_t fl = sizeof from;
      const int n = (int)recvfrom(s, (char *)buf, sizeof buf, 0, (sockaddr *)&from, &fl);
      if (n < 20 || buf[0] != 0x01 || buf[1] != 0x01 || memcmp(buf + 8, req + 8, 12) != 0) continue;
      const int len = (buf[2] << 8) | buf[3];
      for (int i = 20; i + 4 <= 20 + len && i + 4 <= n;) {
        const int type = (buf[i] << 8) | buf[i + 1], alen = (buf[i + 2] << 8) | buf[i + 3];
        const unsigned char *v = buf + i + 4;
        if ((type == 0x0020 || type == 0x0001) && alen >= 8 && i + 4 + 8 <= n && v[1] == 0x01) {
          unsigned p = (unsigned)((v[2] << 8) | v[3]);
          unsigned char ip[4] = { v[4], v[5], v[6], v[7] };
          if (type == 0x0020) { p ^= 0x2112; ip[0] ^= 0x21; ip[1] ^= 0x12; ip[2] ^= 0xA4; ip[3] ^= 0x42; }
          char o[40];
          snprintf(o, sizeof o, "%u.%u.%u.%u:%u", ip[0], ip[1], ip[2], ip[3], p);
          return o;
        }
        i += 4 + ((alen + 3) & ~3);
      }
    }
  }
  return "";
}
// Two STUN servers from one socket: the same mapped port from both is a NAT a hole punch gets through ("easy"); different ports mean it
// maps per destination ("strict": this computer needs a relay to reach another strict one).
static void probe(NatHub *h)
{
  std::vector<std::pair<std::string, int>> list;
  { std::lock_guard<std::mutex> g(h->mx); list = h->stun; }
  std::string kind = "unknown", pub;
  if (!list.empty()) {
    nat_sock_t s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s != NAT_BAD_SOCK) {
#ifdef _WIN32
      DWORD tmo = 200;
#else
      timeval tmo = { 0, 200000 };
#endif
      setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&tmo, sizeof tmo);
      const std::string a = stun_mapped(s, list[0].first, list[0].second), b = list.size() > 1 ? stun_mapped(s, list[1].first, list[1].second) : "";
      nat_close(s);
      pub = !a.empty() ? a : b;
      if (a.empty() && b.empty()) kind = "blocked";
      else if (!a.empty() && !b.empty()) kind = a == b ? "easy" : "strict";
    }
  }
  std::lock_guard<std::mutex> g(h->mx);
  h->kind = kind;
  h->pub_addr = pub;
}

static std::shared_ptr<LinkBox> make_box(NatHub *h, HubPeer &p) // (h->mx held)
{
  std::shared_ptr<LinkBox> b = std::make_shared<LinkBox>();
  b->h = h;
  b->addr = p.addr;
  NatLinkConfig c;
  c.folder = h->folder; c.me = h->me; c.peer = p.dev; c.secret = h->secret; c.my_static = h->keys;
  memcpy(c.peer_static, p.pub, 32);
  if (!h->stun.empty()) { c.stun_host = h->stun[0].first; c.stun_port = h->stun[0].second; }
  if (h->port > 0) { c.port_lo = h->port; c.port_hi = h->port + NAT_PORTS - 1; }
  c.timeout_s = 60; // (the other side's file comes through Syncthing: a few seconds each way, more when it's busy)
  c.on_data = box_rx;
  c.user = b.get();
  b->l = nat_link_new(c);
  if (!b->l) return nullptr;
  return b;
}
static void hub_loop(NatHub *h)
{
  while (h->run.load()) {
    const double now = now_s();
    if (now >= h->next_probe) { h->next_probe = now + 600; probe(h); }
    std::vector<std::pair<std::shared_ptr<HubPeer>, std::shared_ptr<LinkBox>>> items;
    std::string folder, me, K;
    {
      std::lock_guard<std::mutex> g(h->mx);
      folder = h->folder; me = h->me; K = h->K;
      for (auto &kv : h->peers) items.emplace_back(kv.second, kv.second->box);
    }
    for (auto &it : items) {
      HubPeer &p = *it.first;
      const bool initiator = me < p.dev;
      if (it.second) {
        const int r = nat_link_tick(it.second->l);
        std::string why;
        if (r < 0) {
          why = nat_link_status(it.second->l);
          const size_t w = why.find("why    ");
          why = w == std::string::npos ? "no connection" : why.substr(w + 7);
        }
        std::lock_guard<std::mutex> g(h->mx);
        if (p.box != it.second) continue; // (dropped or replaced by a setup meanwhile)
        if (r == 1 && !p.was_up) { p.was_up = true; p.up_at = now; p.fails = 0; p.why.clear(); }
        if (r < 0) {
          p.why = why;
          ++p.fails;
          p.was_up = false;
          p.up_at = -1;
          p.next_try = now + std::min(120.0, 5.0 * (1 << std::min(p.fails - 1, 5)));
          p.box.reset();
        }
        continue;
      }
      if (initiator) {
        std::lock_guard<std::mutex> g(h->mx);
        if (now < p.next_try || h->peers.find(p.dev) == h->peers.end()) continue;
        std::shared_ptr<LinkBox> b = make_box(h, p);
        if (b) p.box = b; else { p.why = "libjuice wouldn't start (the ports taken?)"; p.next_try = now + 30; }
        continue;
      }
      if (now < p.next_offer_look) continue; // (the responder: a new offer starts a link)
      p.next_offer_look = now + 1;
      const std::string text = slurp(folder + "/" + p.dev + "-" + me + ".json");
      std::string kind, sdp, why;
      unsigned char pe[32], re[32];
      const bool ok = !text.empty() && nat_signal_read(K, text, me, p.dev, unix_s(), kind, pe, re, sdp, why) && kind == "offer";
      std::lock_guard<std::mutex> g(h->mx);
      if (h->peers.find(p.dev) == h->peers.end()) continue;
      if (!ok) { if (!text.empty() && !why.empty()) p.why = "their rendezvous file: " + why; continue; }
      const std::string e = hex(pe, 32);
      if (e == p.answered_e) continue; // (answered already; a new try of theirs brings a new key)
      if (std::shared_ptr<LinkBox> b = make_box(h, p)) { p.box = b; p.answered_e = e; p.why.clear(); }
    }
    items.clear(); // (a link dropped by a setup is freed here, outside the lock)
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
}

NatHub *nat_hub_new() { return new NatHub(); }
void nat_hub_stop(NatHub *h)
{
  h->run.store(false);
  if (h->thr.joinable()) h->thr.join();
  std::map<std::string, std::shared_ptr<HubPeer>> gone;
  { std::lock_guard<std::mutex> g(h->mx); gone.swap(h->peers); h->me.clear(); }
  for (auto &kv : gone) kv.second->box.reset(); // (each link's agent destroyed: no callback after)
}
void nat_hub_free(NatHub *h)
{
  if (!h) return;
  nat_hub_stop(h);
  nat_set_rx(h, nullptr, nullptr);
  crypto_wipe(h->keys.priv, 32);
  delete h;
}
int nat_hub_setup(NatHub *h, const char *json)
{
  JV v;
  if (!jparse(json, v) || v.t != 5) { std::lock_guard<std::mutex> g(h->mx); h->err = "the setup isn't JSON"; return -1; }
  const std::string folder = v.str("folder"), me = v.str("me"), secret = v.str("secret"), keypath = v.str("key");
  const JV *port = v.get("port"), *stun = v.get("stun"), *peers = v.get("peers");
  const int want_port = port && port->t == 2 ? (int)port->n : NAT_PORT;
  std::string why;
  NatKeys k;
  if (folder.empty() || !id_ok(me) || secret.empty() || !nat_key_load(keypath, k, true, why)) {
    std::lock_guard<std::mutex> g(h->mx);
    h->err = !why.empty() ? why : folder.empty() ? "no folder" : !id_ok(me) ? "no device id" : "no studio secret";
    return -1;
  }
  umkdir(folder);
  std::vector<std::pair<std::string, int>> sl;
  if (stun && stun->t == 4)
    for (const JV &x : stun->a) {
      if (x.t != 3) continue;
      const size_t c = x.s.rfind(':');
      const std::string host = c == std::string::npos ? x.s : x.s.substr(0, c);
      const int p = c == std::string::npos ? 3478 : atoi(x.s.c_str() + c + 1);
      if (!host.empty() && p > 0 && p < 65536) sl.emplace_back(host, p);
    }
  std::map<std::string, std::string> want; // device -> pub hex
  if (peers && peers->t == 4)
    for (const JV &x : peers->a) {
      std::string raw;
      const std::string d = x.str("device"), pub = x.str("pub");
      if (id_ok(d) && d != me && unhex(pub, raw) && raw.size() == 32) want[d] = pub;
    }
  std::vector<std::shared_ptr<HubPeer>> gone; // (their links freed outside the lock: an agent waits for libjuice's thread)
  {
    std::lock_guard<std::mutex> g(h->mx);
    const bool same = h->folder == folder && h->me == me && h->secret == secret && h->have_key && !memcmp(h->keys.pub, k.pub, 32) &&
                      h->stun == sl && h->port == want_port;
    if (h->stun != sl) h->next_probe = 0;
    for (auto it = h->peers.begin(); it != h->peers.end();) {
      auto w = want.find(it->first);
      if (!same || w == want.end() || w->second != it->second->pub_hex) { gone.push_back(it->second); it = h->peers.erase(it); }
      else ++it;
    }
    h->folder = folder; h->me = me; h->secret = secret; h->K = nat_studio_key(secret); h->keypath = keypath;
    h->keys = k;
    h->have_key = true;
    h->stun = sl;
    h->port = want_port;
    h->err.clear();
    for (const auto &kv : want) {
      if (h->peers.count(kv.first)) continue;
      std::shared_ptr<HubPeer> p = std::make_shared<HubPeer>();
      p->dev = kv.first;
      p->pub_hex = kv.second;
      std::string raw;
      unhex(kv.second, raw);
      memcpy(p->pub, raw.data(), 32);
      synthetic_of(kv.first, p->addr);
      h->peers[kv.first] = p;
    }
    for (auto &p : gone) p->box.reset(); // (the loop may hold its own reference for one pass; it's freed after that)
  }
  crypto_wipe(k.priv, 32);
  gone.clear();
  if (!h->run.load()) {
    if (h->thr.joinable()) h->thr.join();
    h->run.store(true);
    h->thr = std::thread(hub_loop, h);
  }
  std::lock_guard<std::mutex> g(h->mx);
  return (int)h->peers.size();
}
static std::string self_of(const std::string &me);
std::string nat_hub_status(NatHub *h)
{
  std::vector<std::shared_ptr<HubPeer>> list;
  std::string o = "{";
  {
    std::lock_guard<std::mutex> g(h->mx);
    o += "\"on\":";
    o += h->run.load() && !h->me.empty() ? "true" : "false";
    o += ",\"me\":"; jquote(o, h->me);
    o += ",\"error\":"; jquote(o, h->err);
    o += ",\"nat\":"; jquote(o, h->kind);
    o += ",\"public\":"; jquote(o, h->pub_addr);
    o += ",\"self\":"; jquote(o, h->me.empty() ? "" : self_of(h->me));
    for (auto &kv : h->peers) list.push_back(kv.second);
  }
  o += ",\"peers\":{";
  bool first = true;
  const double now = now_s();
  for (auto &pp : list) {
    std::shared_ptr<LinkBox> box;
    std::string me;
    { std::lock_guard<std::mutex> g(h->mx); box = pp->box; me = h->me; }
    std::string loc, rem, link;
    long long sent = 0, opened = 0, refused = 0;
    if (box) {
      nat_link_path(box->l, loc, rem);
      link = nat_link_status(box->l);
      const size_t at = link.find("sent ");
      if (at != std::string::npos) sscanf(link.c_str() + at, "sent %lld, opened %lld, refused %lld", &sent, &opened, &refused);
    }
    std::lock_guard<std::mutex> g(h->mx);
    const HubPeer &p = *pp;
    const char *state = p.was_up ? "up" : p.box ? "connecting" : (me < p.dev ? "waiting" : "waiting for them");
    if (!first) o += ',';
    first = false;
    jquote(o, p.dev);
    o += ":{\"state\":"; jquote(o, state);
    o += ",\"path\":"; jquote(o, !p.was_up ? "" : (loc == "relay" || rem == "relay") ? "relayed" : "direct");
    o += ",\"local\":"; jquote(o, loc);
    o += ",\"remote\":"; jquote(o, rem);
    o += ",\"why\":"; jquote(o, p.why);
    char b[200];
    snprintf(b, sizeof b, ",\"fails\":%d,\"up_s\":%.0f,\"sent\":%lld,\"opened\":%lld,\"refused\":%lld}", p.fails, p.was_up ? now - p.up_at : 0.0, sent, opened, refused);
    o += b;
  }
  o += "}}";
  return o;
}

// ---- live audio's side ------------------------------------------------------------------------------------------------------------------
bool nat_resolve(NatHub *h, const char *peer, void *out)
{
  if (!h || !peer || strncmp(peer, "nat:", 4) != 0) return false;
  std::lock_guard<std::mutex> g(h->mx);
  auto it = h->peers.find(peer + 4);
  if (it == h->peers.end()) return false;
  memcpy(out, &it->second->addr, sizeof(sockaddr_in));
  return true;
}
static std::shared_ptr<LinkBox> box_at(NatHub *h, const sockaddr_in &a)
{
  std::lock_guard<std::mutex> g(h->mx);
  for (auto &kv : h->peers) if (same_sa(kv.second->addr, a)) return kv.second->was_up ? kv.second->box : nullptr;
  return nullptr;
}
bool nat_up(NatHub *h, const void *sa) { return h && nat_is_synthetic(sa) && box_at(h, *(const sockaddr_in *)sa) != nullptr; }
int nat_sendto(NatHub *h, const void *sa, const void *d, int n)
{
  if (!h || n <= 0 || !nat_is_synthetic(sa)) return -1;
  std::shared_ptr<LinkBox> b = box_at(h, *(const sockaddr_in *)sa);
  return b && nat_link_send(b->l, d, (size_t)n) ? n : -1;
}
void nat_set_rx(NatHub *h, nat_rx_fn fn, void *user)
{
  if (!h) return;
  h->rx.store(nullptr);
  while (h->rx_in.load() > 0) std::this_thread::yield();
  h->rx_user.store(user);
  h->rx.store(fn);
}
static std::string self_of(const std::string &me)
{
  sockaddr_in a;
  synthetic_of(me, a);
  char b[32];
  const unsigned char *p = (const unsigned char *)&a.sin_addr;
  snprintf(b, sizeof b, "%u.%u.%u.%u:%d", p[0], p[1], p[2], p[3], NAT_AUDIO_PORT);
  return b;
}
std::string nat_self(NatHub *h)
{
  std::lock_guard<std::mutex> g(h->mx);
  return h->me.empty() ? "" : self_of(h->me);
}
bool nat_active(NatHub *h)
{
  if (!h) return false;
  std::lock_guard<std::mutex> g(h->mx);
  return h->run.load() && !h->me.empty() && !h->peers.empty();
}
NatHub *nat_global() { static NatHub *g = nat_hub_new(); return g; } // (made once, freed never while REAPER runs: live audio may hold it)

#ifndef NAT_STANDALONE
// ---- the ReaScript functions ------------------------------------------------------------------------------------------------------------
#include "reaper_plugin.h"
#include "rtaudio.h"
// Live audio's way to the bandmates reached here (extension/rtaudio.h RtNat): function pointers, so rtaudio.cpp's own test needs no nat.cpp.
static bool w_resolve(void *h, const char *p, void *o) { return nat_resolve((NatHub *)h, p, o); }
static bool w_up(void *h, const void *a) { return nat_up((NatHub *)h, a); }
static int w_send(void *h, const void *a, const void *d, int n) { return nat_sendto((NatHub *)h, a, d, n); }
static std::string w_self(void *h) { return nat_self((NatHub *)h); }
static bool w_active(void *h) { return nat_active((NatHub *)h); }
static void to_live_audio(void *u, const unsigned char *d, int n, const void *from) { rt_nat_rx((RtLink *)u, d, n, from); }
static std::string g_key_out, g_status_out;
static const char *api_key(const char *path) { std::string why; g_key_out = nat_key_public(path ? path : "", why); return g_key_out.c_str(); }
static int api_setup(const char *json) { return nat_hub_setup(nat_global(), json); }
static const char *api_status() { g_status_out = nat_hub_status(nat_global()); return g_status_out.c_str(); }
static void api_stop() { nat_hub_stop(nat_global()); }
static void *vla_key(void **a, int n) { return n < 1 ? nullptr : (void *)api_key((const char *)a[0]); }
static void *vla_setup(void **a, int n) { return n < 1 ? nullptr : (void *)(INT_PTR)api_setup((const char *)a[0]); }
static void *vla_status(void **, int) { return (void *)api_status(); }
static void *vla_stop(void **, int) { api_stop(); return nullptr; }
static void nat_shutdown() { nat_hub_stop(nat_global()); }
extern "C" void nat_register(reaper_plugin_info_t *rec)
{
  juice_set_log_level(JUICE_LOG_LEVEL_NONE); // (nothing to print to inside REAPER; the status says why)
  static const struct { const char *name; void *fn, *va; const char *def; } fns[] = {
    { "StudioSync_NatKey", (void *)api_key, (void *)vla_key,
      "const char*\0const char*\0path\0This computer's static key for the connection without Tailscale: the private half kept in the file at path (made when missing, this user only; never in a synced folder). Returns the public half as 64 hex (for this computer's devices file), or an empty string." },
    { "StudioSync_NatSetup", (void *)api_setup, (void *)vla_setup,
      "int\0const char*\0json\0The connection without Tailscale: {\"folder\":\"<studio>/_band/nat\",\"me\":\"<device id>\",\"secret\":\"<studio secret>\",\"key\":\"<key file>\",\"port\":47282,\"stun\":[\"host:port\",...],\"peers\":[{\"device\":\"<id>\",\"pub\":\"<64 hex>\"},...]}. Keeps a link up to each peer (signed rendezvous files in the folder, ICE, sealed datagrams); live audio reaches them as \"nat:<device id>\". Returns how many peers, or -1 (StudioSync_NatStatus's error)." },
    { "StudioSync_NatStatus", (void *)api_status, (void *)vla_status,
      "const char*\0\0\0The connection without Tailscale as JSON: on, me, error, nat (easy, strict: needs a relay, blocked: no STUN answer, unknown), public (ip:port), self (this computer's synthetic address), peers = { [device] = { state (up, connecting, waiting, waiting for them), path (direct, relayed), local, remote (host, srflx, prflx, relay), why, fails, up_s, sent, opened, refused } }." },
    { "StudioSync_NatStop", (void *)api_stop, (void *)vla_stop, "void\0\0\0Every link without Tailscale down." },
  };
  char key[96];
  for (const auto &f : fns) {
    snprintf(key, sizeof(key), "API_%s", f.name); rec->Register(key, f.fn);
    snprintf(key, sizeof(key), "APIdef_%s", f.name); rec->Register(key, (void *)f.def);
    snprintf(key, sizeof(key), "APIvararg_%s", f.name); rec->Register(key, f.va);
  }
  rec->Register("atexit", (void *)nat_shutdown);
  static RtNat ops = { nat_global(), w_resolve, w_up, w_send, w_self, w_active };
  if (RtLink *rt = rt_global()) { rt_set_nat(rt, &ops); nat_set_rx(nat_global(), to_live_audio, rt); } // (rtaudio_register ran first: reaper_menu.cpp)
}
#endif
