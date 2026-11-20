// StudioSync's Tailscale-free connection, the spike: see nat.h and docs/realtime-roadmap.md "Without Tailscale: design".
// Built only by tests/nat_test.cpp for now (build flag STUDIOSYNC_NAT): the shipped extension doesn't compile or link this file.
// GPL-3.0-or-later. libjuice (MPL-2.0) and Monocypher (CC0-1.0 / BSD-2-Clause): extension/third_party/README.md.
#ifndef STUDIOSYNC_NAT
#error "nat.cpp is the Tailscale-free spike: build it only with -DSTUDIOSYNC_NAT (tests/build_nat_test.cmd)"
#endif
#ifdef _WIN32
#define NOMINMAX
#include <winsock2.h>
#include <windows.h>
#include <bcrypt.h>
#endif
#include <cctype>
#include <cstdlib>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include "nat.h"
#include "direct.h"
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
std::string nat_signal(const std::string &K, const char *kind, const std::string &from, const std::string &to, const unsigned char eph[32],
                       const unsigned char *re, long long t, const std::string &sdp)
{
  std::string b = std::string("SSN1 ") + kind + "\nfrom " + from + "\nto " + to + "\nt " + std::to_string(t) + "\ne " + hex(eph, 32) +
                  "\nre " + (re ? hex(re, 32) : "-") + "\nsdp " + hex((const unsigned char *)sdp.data(), sdp.size()) + "\n";
  const std::string m = hmac(K, b);
  return b + "mac " + hex((const unsigned char *)m.data(), 32) + "\n";
}
bool nat_signal_read(const std::string &K, const std::string &text, const std::string &me, const std::string &peer, long long now,
                     std::string &kind, unsigned char eph[32], unsigned char re[32], std::string &sdp, std::string &why)
{
  const size_t at = text.rfind("\nmac ");
  if (K.size() != 32 || text.compare(0, 5, "SSN1 ") != 0 || at == std::string::npos) { why = "not a rendezvous message"; return false; }
  const std::string body = text.substr(0, at + 1), want = hmac(K, body);
  std::string got;
  const size_t me_end = text.find('\n', at + 5);
  if (!unhex(text.substr(at + 5, me_end == std::string::npos ? std::string::npos : me_end - at - 5), got) || got.size() != 32) { why = "no signature"; return false; }
  unsigned char d = 0;
  for (int i = 0; i < 32; ++i) d |= (unsigned char)(got[i] ^ want[i]);
  if (d) { why = "the signature doesn't match the studio secret"; return false; }
  std::string from, to, t, e, r, s;
  for (size_t i = 0; i < body.size();) {
    const size_t e2 = body.find('\n', i), sp = body.find(' ', i);
    const std::string k = body.substr(i, sp - i), v = body.substr(sp + 1, e2 - sp - 1);
    if (k == "SSN1") kind = v; else if (k == "from") from = v; else if (k == "to") to = v; else if (k == "t") t = v;
    else if (k == "e") e = v; else if (k == "re") r = v; else if (k == "sdp") s = v;
    i = e2 + 1;
  }
  std::string eb, rb;
  if (from != peer || to != me || !id_ok(from) || !id_ok(to)) { why = "not from that computer to this one"; return false; }
  if (t.empty() || llabs(now - atoll(t.c_str())) > 120) { why = "too old (or the clocks are minutes apart)"; return false; }
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
  juice_agent_t *agent = nullptr;
  juice_turn_server_t turn{};
  std::atomic<int> state{ 0 };
  std::atomic<bool> gathered{ false }, ready{ false }, up{ false }, heard{ false }; // (up: a datagram from the peer opened; heard: the peer says it has one of ours)
  std::mutex mx; // (the session's counters and the queue: juice's thread receives, the caller's sends)
  NatSession sess;
  std::deque<std::string> inq;
  long long rx_ok = 0, rx_bad = 0, tx = 0;
  double t0 = 0, next_hello = 0;
};
static double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static long long unix_s() { return (long long)std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count(); }
static std::string slurp(const std::string &p)
{
  std::string s;
  FILE *f = fopen(p.c_str(), "rb");
  if (!f) return s;
  char b[4096];
  size_t n;
  while ((n = fread(b, 1, sizeof b, f)) > 0) s.append(b, n);
  fclose(f);
  return s;
}
static bool spit_atomic(const std::string &p, const std::string &s)
{
  const std::string tmp = p + ".tmp";
  FILE *f = fopen(tmp.c_str(), "wb");
  if (!f) return false;
  const bool ok = fwrite(s.data(), 1, s.size(), f) == s.size();
  fclose(f);
  remove(p.c_str()); // (only this side writes this name)
  return ok && rename(tmp.c_str(), p.c_str()) == 0;
}

static void on_state(juice_agent_t *, juice_state_t st, void *u) { ((NatLink *)u)->state.store((int)st); }
static void on_gathered(juice_agent_t *, void *u) { ((NatLink *)u)->gathered.store(true); }
static void on_recv(juice_agent_t *, const char *d, size_t n, void *u)
{
  NatLink *l = (NatLink *)u;
  if (!l->ready.load(std::memory_order_acquire)) return;
  std::lock_guard<std::mutex> g(l->mx);
  std::string m;
  if (!nat_open(l->sess, d, n, m) || m.empty()) { ++l->rx_bad; return; }
  ++l->rx_ok;
  l->up.store(true);                        // (key confirmation: only the peer could have sealed this)
  if (m[0] == 1) { l->heard.store(true); l->inq.push_back(m.substr(1)); }
  else if (m.size() > 1 && m[1] == 1) l->heard.store(true); // (a hello: { 0, 1 once it has opened one of ours })
}

NatLink *nat_link_new(const NatLinkConfig &c)
{
  if (!id_ok(c.me) || !id_ok(c.peer) || c.me == c.peer || c.secret.empty()) return nullptr;
  NatLink *l = new NatLink();
  l->c = c;
  l->K = nat_studio_key(c.secret);
  l->initiator = c.me < c.peer;
  l->sdp_path_out = c.folder + "/" + c.me + "-" + c.peer + ".ssn";
  l->sdp_path_in = c.folder + "/" + c.peer + "-" + c.me + ".ssn";
  l->t0 = now_s();
  remove(l->sdp_path_out.c_str()); // (a file from an earlier try would answer the wrong offer)
  if (!nat_keypair(l->eph)) { delete l; return nullptr; }
  juice_config_t jc;
  memset(&jc, 0, sizeof jc);
  jc.concurrency_mode = JUICE_CONCURRENCY_MODE_THREAD;
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
  if (!l->got) {
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
        l->got = true;
        juice_set_remote_description(l->agent, sdp.c_str());
        if (!l->initiator) juice_gather_candidates(l->agent);
      }
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
  if (st == JUICE_STATE_FAILED) { l->failed = true; l->why = "ICE found no path (both behind strict NATs and no relay?)"; return -1; }
  if ((st == JUICE_STATE_CONNECTED || st == JUICE_STATE_COMPLETED) && l->ready.load() && !(l->up.load() && l->heard.load()) && now_s() >= l->next_hello) {
    const char hello[] = { 0, (char)(l->up.load() ? 1 : 0) }; // (until both ends have opened one: neither can be sure before)
    std::string d;
    { std::lock_guard<std::mutex> g(l->mx); d = nat_seal(l->sess, hello, sizeof hello); }
    juice_send(l->agent, d.data(), d.size());
    l->next_hello = now_s() + 0.2;
  }
  if (!l->up.load() && now_s() - l->t0 > 30) { l->failed = true; if (l->why.empty()) l->why = "no connection in 30 s"; return -1; }
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
std::string nat_link_status(NatLink *l)
{
  char loc[JUICE_MAX_CANDIDATE_SDP_STRING_LEN] = "", rem[JUICE_MAX_CANDIDATE_SDP_STRING_LEN] = "";
  juice_get_selected_candidates(l->agent, loc, sizeof loc, rem, sizeof rem);
  std::lock_guard<std::mutex> g(l->mx);
  char b[160];
  snprintf(b, sizeof b, "state %s, up %d, sent %lld, opened %lld, refused %lld", juice_state_to_string((juice_state_t)l->state.load()), (int)l->up.load(), l->tx, l->rx_ok, l->rx_bad);
  return std::string(b) + "\n  local  " + loc + "\n  remote " + rem + (l->why.empty() ? "" : "\n  why    " + l->why);
}
