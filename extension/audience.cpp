// Live to an audience: extension/audience.h has the why; docs/rt/rt-audience.md how it's used. Threads: the audio thread only copies into a
// ring (audience_feed); one fan-out thread resamples, encodes and sends to every listener (non-blocking sockets, polled); the public port's
// accept thread and a few short-lived request threads (8 at most) for its page and mix. Nothing here touches REAPER's API. GPL-3.0-or-later.
#ifdef _WIN32
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
typedef SOCKET sock_t;
#define BAD_SOCK INVALID_SOCKET
#define close_sock closesocket
#define SEND_FLAGS 0
#else
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
typedef int sock_t;
#define BAD_SOCK (-1)
#define close_sock close
#ifdef MSG_NOSIGNAL
#define SEND_FLAGS MSG_NOSIGNAL
#else
#define SEND_FLAGS 0
#endif
#endif
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <set>
#include <thread>
#include <vector>
#include "opus.h"
#include "direct.h"
#include "audience.h"

// ---- the pure parts ---------------------------------------------------------------------------------------------------------------------
int audience_route(const std::string &method, const std::string &path)
{
  if (method != "GET") return AUD_NONE;
  if (path == "/listen/" || path == "/listen/index.html") return AUD_PAGE;
  if (path == "/listen/listen.js") return AUD_JS;
  if (path == "/listen/listen.css") return AUD_CSS;
  if (path == "/listen/live") return AUD_LIVE;
  if (path == "/listen/mix") return AUD_MIX;
  return AUD_NONE;
}
static bool same_text(const std::string &a, const std::string &b)
{
  if (a.size() != b.size() || a.empty()) return false;
  unsigned char d = 0;
  for (size_t i = 0; i < a.size(); ++i) d |= (unsigned char)(a[i] ^ b[i]);
  return d == 0;
}
int audience_auth(const WebReq &r, const std::map<std::string, AudLink> &links, double now, bool pub, std::string &id)
{
  id.clear();
  const int route = audience_route(r.method, r.path);
  if (route == AUD_NONE) return 404;
  if (route == AUD_JS || route == AUD_CSS) return 0;
  const std::string code = webui_param(r.query, "l");
  if (code.size() < 32 || code.size() > 64) return 403;
  for (const auto &kv : links)
    if (now < kv.second.until && (!pub || kv.second.pub) && same_text(code, kv.second.code)) { id = kv.first; return 0; }
  return 403;
}
bool audience_bucket_take(AudBucket &b, double now, double rate, double burst)
{
  b.tokens = b.tokens < 0 ? burst : std::min(burst, b.tokens + std::max(0.0, now - b.at) * rate);
  b.at = now;
  if (b.tokens < 1) return false;
  b.tokens -= 1;
  return true;
}
void audience_resample(const float *ring, unsigned long long mask, double &pos, double step, float *out, int n)
{
  for (int k = 0; k < n; ++k, pos += step) {
    const double fl = std::floor(pos);
    const float t = (float)(pos - fl);
    const unsigned long long i = (unsigned long long)fl;
    for (int c = 0; c < 2; ++c) {
      const float y0 = ring[((i - 1) & mask) * 2 + c], y1 = ring[(i & mask) * 2 + c], y2 = ring[((i + 1) & mask) * 2 + c], y3 = ring[((i + 2) & mask) * 2 + c];
      out[k * 2 + c] = y1 + 0.5f * t * (y2 - y0 + t * (2.f * y0 - 5.f * y1 + 4.f * y2 - y3 + t * (3.f * (y1 - y2) + y3 - y0)));
    }
  }
}
std::string audience_ws_frame(int op, const std::string &d)
{
  std::string h(1, (char)(0x80 | op));
  const size_t n = d.size();
  if (n < 126) h += (char)n;
  else if (n < 65536) { h += (char)126; h += (char)(n >> 8); h += (char)(n & 255); }
  else { h += (char)127; for (int i = 7; i >= 0; --i) h += (char)((unsigned long long)n >> (8 * i) & 255); }
  return h + d;
}

// ---- state -----------------------------------------------------------------------------------------------------------------------------
namespace {
const int MAX_LINKS = 8, CAP_MAX = 100, PUB_WORKERS = 8;
const double RATE = 20, BURST = 200;        // requests a second (and a burst) per way in: a page load is 4 (page, script, style, socket), a reconnect 1
const double BAD_RATE = 20.0 / 60, BAD_BURST = 20, LOCK_S = 60; // wrong codes: past 20 a minute, that way in answers nothing for a minute
const size_t OUT_MAX = 32 * 1024;           // bytes waiting for one listener (~2.7 s at 96 kbps): past it their packets are skipped...
const double SLOW_S = 10;                   // ...and after this long still past it, they're closed
const size_t IN_MAX = 16 * 1024;            // bytes a listener may send in 10 s (a browser sends nothing but a close)
const unsigned long long RN = 1ull << 16;   // ring frames: 1.36 s at 48 kHz
const int FRAME = 960;                      // 20 ms at 48 kHz: Opus's usual frame, ~50 packets a second
std::mutex g_mx;
std::map<std::string, AudLink> g_links;
std::string g_folder, g_full = "{}", g_pub = "{}", g_mix_path, g_pub_err, g_status;
long long g_info_ver = 1;
int g_cap = 20, g_kbps = 96;
struct Lis { sock_t s; std::string id; bool pub; std::string out; long long info_ver = -1; double slow_at = 0, in_at = 0, info_at = 0; size_t in_n = 0; };
std::deque<Lis> g_in;                       // handed over, waiting for the fan-out thread
std::map<std::string, int> g_link_n;        // listeners per link (the fan-out thread writes it under g_mx)
int g_pub_n = 0;
std::atomic<int> g_n{ 0 };                  // listeners, counting ones being handed over
std::atomic<bool> g_run{ false };
std::thread g_fan;
AudBucket g_bk[2], g_bad[2];
double g_lock[2] = { 0, 0 };
long long g_served = 0, g_refused = 0, g_limited = 0, g_full_n = 0;
std::atomic<long long> g_packets{ 0 }, g_skipped{ 0 }, g_slow{ 0 }, g_bytes{ 0 };
std::atomic<double> g_enc_load{ 0 }, g_out_kbps{ 0 };
float g_ring[RN * 2];
std::atomic<unsigned long long> g_rw{ 0 };
std::atomic<double> g_rsr{ 0 };
// the public port
int g_pub_port = 0;
sock_t g_pub_sock = BAD_SOCK;
std::thread g_pub_thr;
std::atomic<bool> g_pub_run{ false };
std::atomic<int> g_pub_workers{ 0 };
std::set<sock_t> g_pub_active;
bool g_wsa = false;
struct ExitGuard { ~ExitGuard() { if (g_fan.joinable()) g_fan.detach(); if (g_pub_thr.joinable()) g_pub_thr.detach(); } } g_exit_guard;

double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
void set_blocking(sock_t s, int timeout_ms)
{
#ifdef _WIN32
  u_long v = 0;
  ioctlsocket(s, FIONBIO, &v);
  DWORD t = (DWORD)timeout_ms;
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&t, sizeof(t));
  setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char *)&t, sizeof(t));
#else
  fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) & ~O_NONBLOCK);
  timeval tv = { timeout_ms / 1000, (timeout_ms % 1000) * 1000 };
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
#ifdef SO_NOSIGPIPE
  int one = 1;
  setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
#endif
}
void set_nonblocking(sock_t s)
{
#ifdef _WIN32
  u_long v = 1;
  ioctlsocket(s, FIONBIO, &v);
#else
  fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK);
#ifdef SO_NOSIGPIPE
  int one = 1;
  setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
#endif
}
bool would_block()
{
#ifdef _WIN32
  return WSAGetLastError() == WSAEWOULDBLOCK;
#else
  return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR;
#endif
}
bool send_all(sock_t s, const std::string &d)
{
  for (size_t at = 0; at < d.size();) {
    const int k = (int)send(s, d.data() + at, (int)std::min<size_t>(d.size() - at, 65536), SEND_FLAGS);
    if (k <= 0) return false;
    at += (size_t)k;
  }
  return true;
}
void close_now(sock_t s)
{
#ifdef _WIN32
  shutdown(s, SD_BOTH);
#else
  shutdown(s, SHUT_RDWR);
#endif
  close_sock(s);
}
std::string header(const WebReq &r, const char *n) { auto it = r.headers.find(n); return it == r.headers.end() ? "" : it->second; }
std::string lower(std::string s) { for (char &c : s) if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a'); return s; }
// (the web UI's own: no-store, no sniffing, no referrer (the address carries the code), and a CSP letting the page load only its own files
// and connect only back here; media from here too, for the latest mix's <audio>)
const char *HEADERS = "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
  "Content-Security-Policy: default-src 'self'; media-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'\r\n";
void answer(sock_t s, int code, const char *ctype, const std::string &body, const std::string &extra = "")
{
  const char *why = code == 200 ? "OK" : code == 206 ? "Partial Content" : code == 400 ? "Bad Request" : code == 403 ? "Forbidden" : code == 404 ? "Not Found"
                  : code == 416 ? "Range Not Satisfiable" : code == 429 ? "Too Many Requests" : code == 503 ? "Service Unavailable" : "Error";
  send_all(s, "HTTP/1.1 " + std::to_string(code) + " " + why + "\r\nContent-Type: " + ctype + "\r\nContent-Length: " + std::to_string(body.size()) +
                "\r\n" + HEADERS + extra + "Connection: close\r\n\r\n" + body);
}
#ifdef _WIN32
FILE *open_read(const std::string &p)
{
  const int n = MultiByteToWideChar(CP_UTF8, 0, p.c_str(), -1, nullptr, 0);
  std::wstring w(n > 0 ? n : 1, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, p.c_str(), -1, &w[0], n);
  const DWORD at = GetFileAttributesW(w.c_str());
  if (at == INVALID_FILE_ATTRIBUTES || (at & FILE_ATTRIBUTE_DIRECTORY)) return nullptr;
  return _wfopen(w.c_str(), L"rb");
}
#else
FILE *open_read(const std::string &p)
{
  struct stat st;
  if (stat(p.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) return nullptr;
  return fopen(p.c_str(), "rb");
}
#endif
const char *mix_type(const std::string &p) // (audio only: a mix of any other kind isn't served)
{
  const size_t dot = p.rfind('.');
  const std::string e = dot == std::string::npos ? "" : lower(p.substr(dot + 1));
  static const struct { const char *e, *t; } ts[] = { { "wav", "audio/wav" }, { "flac", "audio/flac" }, { "mp3", "audio/mpeg" }, { "ogg", "audio/ogg" },
    { "opus", "audio/ogg" }, { "m4a", "audio/mp4" }, { "aif", "audio/aiff" }, { "aiff", "audio/aiff" } };
  for (const auto &t : ts) if (e == t.e) return t.t;
  return nullptr;
}
void send_page(sock_t s, const char *file, const char *ctype)
{
  std::string folder;
  { std::lock_guard<std::mutex> l(g_mx); folder = g_folder; }
  FILE *f = folder.empty() ? nullptr : open_read(folder + "/" + file);
  if (!f) return answer(s, 404, "text/plain", "not found\n");
  std::string body;
  char b[16384];
  size_t n;
  while ((n = fread(b, 1, sizeof(b), f)) > 0 && body.size() < 512 * 1024) body.append(b, n);
  fclose(f);
  answer(s, 200, ctype, body);
}
// The song's latest mix, streamed as it's read, one byte range honoured (a phone's <audio> seeks that way, and Safari plays nothing without).
void send_mix(sock_t s, const std::string &range)
{
  std::string path;
  { std::lock_guard<std::mutex> l(g_mx); path = g_mix_path; }
  const char *type = path.empty() ? nullptr : mix_type(path);
  FILE *f = type ? open_read(path) : nullptr;
  if (!f) return answer(s, 404, "text/plain", "no mix yet\n");
#ifdef _WIN32
  _fseeki64(f, 0, SEEK_END); const long long n = _ftelli64(f);
#else
  fseeko(f, 0, SEEK_END); const long long n = (long long)ftello(f);
#endif
  long long a = 0, z = n - 1;
  bool part = false;
  if (range.compare(0, 6, "bytes=") == 0 && range.find(',') == std::string::npos && range.size() < 48) {
    const std::string v = range.substr(6);
    const size_t dash = v.find('-');
    if (dash != std::string::npos && v.find_first_not_of("0123456789-") == std::string::npos && v.find('-', dash + 1) == std::string::npos) {
      const std::string lo = v.substr(0, dash), hi = v.substr(dash + 1);
      if (lo.empty() && !hi.empty()) { a = std::max(0LL, n - atoll(hi.c_str())); part = true; }
      else if (!lo.empty()) { a = atoll(lo.c_str()); z = hi.empty() ? n - 1 : std::min(atoll(hi.c_str()), n - 1); part = true; }
      if (part && (a >= n || z < a)) { fclose(f); return answer(s, 416, "text/plain", "", "Content-Range: bytes */" + std::to_string(n) + "\r\n"); }
    }
  }
#ifdef _WIN32
  _fseeki64(f, a, SEEK_SET);
#else
  fseeko(f, (off_t)a, SEEK_SET);
#endif
  set_blocking(s, 30000);
  bool ok = send_all(s, std::string(part ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n") + "Content-Type: " + type + "\r\nContent-Length: " +
                            std::to_string(z - a + 1) + "\r\nAccept-Ranges: bytes\r\n" +
                            (part ? "Content-Range: bytes " + std::to_string(a) + "-" + std::to_string(z) + "/" + std::to_string(n) + "\r\n" : "") + HEADERS +
                            "Connection: close\r\n\r\n");
  std::string b(65536, '\0');
  long long left = z - a + 1;
  size_t k;
  while (ok && left > 0 && g_run && (k = fread(&b[0], 1, (size_t)std::min<long long>(left, (long long)b.size()), f)) > 0) { ok = send_all(s, b.substr(0, k)); left -= (long long)k; }
  fclose(f);
}

// ---- the fan-out thread --------------------------------------------------------------------------------------------------------------
void drop(std::vector<Lis> &ls, size_t i)
{
  close_now(ls[i].s);
  ls.erase(ls.begin() + (long)i);
  g_n.fetch_sub(1);
}
void fan_loop()
{
  int err = 0;
  OpusEncoder *enc = opus_encoder_create(48000, 2, OPUS_APPLICATION_AUDIO, &err);
  if (!enc) { std::lock_guard<std::mutex> l(g_mx); g_pub_err = "no Opus encoder"; return; }
  opus_encoder_ctl(enc, OPUS_SET_COMPLEXITY(5)); // (a third of the 10's time, nearly as good at these rates)
  int kbps_now = 0;
  std::vector<Lis> ls;
  std::vector<float> pcm(FRAME * 2);
  unsigned char pkt[4004];
  double rpos = 0, rsr = -1, check_at = 0, cost_at = now_s(), cost = 0, sent_at = now_s();
  unsigned seq = 0;
  long long sent_bytes = 0;
  char in[4096];
  while (g_run) {
    long long ver;
    std::string full, pub;
    int kbps;
    {
      std::lock_guard<std::mutex> l(g_mx);
      while (!g_in.empty()) { ls.push_back(std::move(g_in.front())); g_in.pop_front(); }
      ver = g_info_ver; full = g_full; pub = g_pub; kbps = g_kbps;
    }
    const double now = now_s();
    if (kbps != kbps_now) { kbps_now = kbps; opus_encoder_ctl(enc, OPUS_SET_BITRATE(kbps * 1000)); }
    // what they see: on joining, on a change, and every 10 s (keeps proxies' idle timers from closing a quiet socket)
    for (auto &x : ls)
      if (x.info_ver != ver || now - x.info_at > 10) { x.out += audience_ws_frame(1, x.pub ? pub : full); x.info_ver = ver; x.info_at = now; } // (after what's queued, whose first frame may be half sent; a newcomer has nothing queued, so it's told before its first packet)
    // encode what came, once, and give each listener the same packet
    const double sr = g_rsr.load();
    const unsigned long long w = g_rw.load(std::memory_order_acquire);
    if (ls.empty() || sr < 8000 || sr > 768000) rsr = -1;
    else {
      if (sr != rsr || (double)w - rpos > (double)(RN / 2) || rpos > (double)w) { rsr = sr; rpos = std::max(3.0, (double)w - sr * 0.05); } // (a new rate, or far behind: from now)
      const double step = sr / 48000.0;
      while (rpos + FRAME * step + 3 <= (double)w) {
        const double t0 = now_s();
        audience_resample(g_ring, RN - 1, rpos, step, pcm.data(), FRAME);
        const int n = opus_encode_float(enc, pcm.data(), FRAME, pkt + 4, 4000);
        cost += now_s() - t0;
        if (n <= 0) break;
        memcpy(pkt, &seq, 4); // (little-endian, as every target is: the page counts gaps by it)
        ++seq;
        const std::string f = audience_ws_frame(2, std::string((const char *)pkt, (size_t)n + 4));
        for (auto &x : ls) { if (x.out.size() > OUT_MAX) g_skipped.fetch_add(1); else x.out += f; }
        g_packets.fetch_add(1);
      }
    }
    if (now - cost_at >= 2) { g_enc_load.store(cost / (now - cost_at)); g_out_kbps.store(sent_bytes * 8 / 1000.0 / (now - sent_at)); cost = 0; cost_at = sent_at = now; sent_bytes = 0; }
    // links revoked or run out, and the counts
    if (now - check_at >= 0.25) {
      check_at = now;
      std::map<std::string, int> per;
      int pn = 0;
      {
        std::lock_guard<std::mutex> l(g_mx);
        for (size_t i = ls.size(); i-- > 0;) {
          auto it = g_links.find(ls[i].id);
          if (it == g_links.end() || now >= it->second.until || (ls[i].pub && (!it->second.pub || g_pub_port == 0))) {
            send(ls[i].s, "\x88\x02\x03\xf0", 4, SEND_FLAGS); // (close, 1008: the link ended)
            drop(ls, i);
          }
        }
        while ((int)ls.size() > g_cap) { send(ls.back().s, "\x88\x02\x03\xf0", 4, SEND_FLAGS); drop(ls, ls.size() - 1); } // (the cap lowered)
        for (const auto &x : ls) { ++per[x.id]; if (x.pub) ++pn; }
        g_link_n = per;
        g_pub_n = pn;
      }
    }
    if (ls.empty()) { std::this_thread::sleep_for(std::chrono::milliseconds(10)); continue; }
    // read (only to see them go: a page sends nothing but its close) and write, never waiting on one listener
    std::vector<
#ifdef _WIN32
      WSAPOLLFD
#else
      pollfd
#endif
      > ps(ls.size());
    for (size_t i = 0; i < ls.size(); ++i) { ps[i].fd = ls[i].s; ps[i].events = POLLIN; ps[i].revents = 0; }
#ifdef _WIN32
    WSAPoll(ps.data(), (ULONG)ps.size(), 5);
#else
    poll(ps.data(), (nfds_t)ps.size(), 5);
#endif
    for (size_t i = ls.size(); i-- > 0;) {
      Lis &x = ls[i];
      bool gone = false;
      if (ps[i].revents & (POLLIN | POLLHUP | POLLERR)) {
        const int k = (int)recv(x.s, in, sizeof(in), 0);
        if (k == 0 || (k < 0 && !would_block())) gone = true;
        else if (k > 0) {
          if (now - x.in_at > 10) { x.in_at = now; x.in_n = 0; }
          x.in_n += (size_t)k;
          if (x.in_n > IN_MAX) gone = true;
        }
      }
      while (!gone && !x.out.empty()) {
        const int k = (int)send(x.s, x.out.data(), (int)std::min<size_t>(x.out.size(), 65536), SEND_FLAGS);
        if (k > 0) { x.out.erase(0, (size_t)k); sent_bytes += k; g_bytes.fetch_add(k); continue; }
        if (k < 0 && would_block()) break;
        gone = true;
      }
      if (!gone && x.out.size() > OUT_MAX) { if (x.slow_at == 0) x.slow_at = now; else if (now - x.slow_at > SLOW_S) { gone = true; g_slow.fetch_add(1); } }
      else if (!gone) x.slow_at = 0;
      if (gone) drop(ls, i);
    }
  }
  for (size_t i = ls.size(); i-- > 0;) drop(ls, i);
  {
    std::lock_guard<std::mutex> l(g_mx);
    for (auto &x : g_in) { close_now(x.s); g_n.fetch_sub(1); }
    g_in.clear();
    g_link_n.clear();
    g_pub_n = 0;
  }
  opus_encoder_destroy(enc);
}

// ---- the public port: its own accept loop and request threads, nothing but audience_http behind it -------------------------------------
void pub_client(sock_t s)
{
  set_blocking(s, 5000);
  std::string buf;
  char b[4096];
  size_t end;
  while ((end = buf.find("\r\n\r\n")) == std::string::npos && buf.size() < 8192) {
    const int k = (int)recv(s, b, sizeof(b), 0);
    if (k <= 0) break;
    buf.append(b, (size_t)k);
  }
  WebReq r;
  bool kept = false;
  if (end == std::string::npos || !webui_parse_head(buf.substr(0, end + 4), r)) answer(s, 400, "text/plain", "bad request\n");
  else kept = audience_http((unsigned long long)s, r, true);
  {
    std::lock_guard<std::mutex> l(g_mx);
    g_pub_active.erase(s);
  }
  if (!kept) close_now(s);
  g_pub_workers.fetch_sub(1);
}
void pub_loop(sock_t ls)
{
  while (g_pub_run) {
#ifdef _WIN32
    WSAPOLLFD p = { ls, POLLIN, 0 };
    const int n = WSAPoll(&p, 1, 200);
#else
    pollfd p = { ls, POLLIN, 0 };
    const int n = poll(&p, 1, 200);
#endif
    if (n <= 0 || !(p.revents & POLLIN)) continue;
    sockaddr_in from = {};
    socklen_t len = sizeof(from);
    sock_t s = accept(ls, (sockaddr *)&from, &len);
    if (s == BAD_SOCK) continue;
    direct_noinherit((unsigned long long)s);
    const unsigned char *a = (const unsigned char *)&from.sin_addr;
    if (from.sin_family != AF_INET || a[0] != 127) { close_sock(s); continue; } // (bound to loopback: tailscaled's funnel connects from here)
    if (g_pub_workers.fetch_add(1) >= PUB_WORKERS) { g_pub_workers.fetch_sub(1); set_blocking(s, 1000); answer(s, 503, "text/plain", "busy\n"); close_sock(s); continue; }
    { std::lock_guard<std::mutex> l(g_mx); g_pub_active.insert(s); }
    std::thread(pub_client, s).detach();
  }
}
void pub_close()
{
  g_pub_run = false;
  if (g_pub_thr.joinable()) g_pub_thr.join();
  if (g_pub_sock != BAD_SOCK) { close_sock(g_pub_sock); g_pub_sock = BAD_SOCK; }
  { std::lock_guard<std::mutex> l(g_mx); for (sock_t s : g_pub_active) close_now(s); g_pub_active.clear(); g_pub_port = 0; } // (requests mid-way: cut)
  for (int i = 0; i < 300 && g_pub_workers.load() > 0; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(10));
}
std::string pub_open(int port)
{
  sock_t s = socket(AF_INET, SOCK_STREAM, 0);
  if (s == BAD_SOCK) return "no socket";
  direct_noinherit((unsigned long long)s);
#ifndef _WIN32
  int one = 1;
  setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
#endif
  sockaddr_in a = {};
  a.sin_family = AF_INET;
  a.sin_port = htons((unsigned short)port);
  inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
  if (bind(s, (sockaddr *)&a, sizeof(a)) != 0 || listen(s, 32) != 0) { close_sock(s); return "can't listen on 127.0.0.1:" + std::to_string(port); }
  g_pub_sock = s;
  g_pub_run = true;
  g_pub_thr = std::thread(pub_loop, s);
  std::lock_guard<std::mutex> l(g_mx);
  g_pub_port = port;
  return "";
}
} // namespace

// ---- the requests ----------------------------------------------------------------------------------------------------------------------
bool audience_http(unsigned long long sv, const WebReq &r, bool pub)
{
  const sock_t s = (sock_t)sv;
  const double now = now_s();
  const int way = pub ? 1 : 0;
  std::string id;
  int a;
  {
    std::lock_guard<std::mutex> l(g_mx);
    if (!g_run || now < g_lock[way] || !audience_bucket_take(g_bk[way], now, RATE, BURST)) {
      ++g_limited;
      a = 429;
    } else {
      a = audience_auth(r, g_links, now, pub, id);
      if (a == 403 && !audience_bucket_take(g_bad[way], now, BAD_RATE, BAD_BURST)) g_lock[way] = now + LOCK_S;
      ++(a == 0 ? g_served : g_refused);
    }
  }
  if (a == 429) { answer(s, 429, "text/plain", "slow down\n", "Retry-After: 60\r\n"); return false; }
  if (a == 404) { answer(s, 404, "text/plain", "not found\n"); return false; }
  if (a != 0) { answer(s, 403, "text/plain; charset=utf-8", "This listening link has ended, or isn't right. Ask the band for a new one.\n"); return false; }
  switch (audience_route(r.method, r.path)) {
  case AUD_PAGE: send_page(s, "listen.html", "text/html; charset=utf-8"); return false;
  case AUD_JS: send_page(s, "listen.js", "text/javascript; charset=utf-8"); return false;
  case AUD_CSS: send_page(s, "listen.css", "text/css; charset=utf-8"); return false;
  case AUD_MIX: send_mix(s, header(r, "range")); return false;
  default: break;
  }
  const std::string key = header(r, "sec-websocket-key");
  if (lower(header(r, "upgrade")) != "websocket" || lower(header(r, "connection")).find("upgrade") == std::string::npos ||
      header(r, "sec-websocket-version") != "13" || key.size() != 24) {
    answer(s, 400, "text/plain", "this is a WebSocket\n");
    return false;
  }
  int cap;
  { std::lock_guard<std::mutex> l(g_mx); cap = g_cap; }
  if (g_n.fetch_add(1) >= cap) {
    g_n.fetch_sub(1);
    { std::lock_guard<std::mutex> l(g_mx); ++g_full_n; }
    answer(s, 503, "text/plain; charset=utf-8", "The listening page is full right now. Try again in a while.\n");
    return false;
  }
  if (!send_all(s, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + webui_ws_accept(key) + "\r\n\r\n")) {
    g_n.fetch_sub(1);
    return false;
  }
  int one = 1;
  setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&one, sizeof(one)); // (20 ms packets: no Nagle wait)
  set_nonblocking(s);
  int sb = 32 * 1024; // (a small send buffer: a listener that stops taking is seen within seconds, not after megabytes sit in the system's buffer, as Linux's grows to)
  setsockopt(s, SOL_SOCKET, SO_SNDBUF, (const char *)&sb, sizeof(sb));
  std::lock_guard<std::mutex> l(g_mx);
  if (!g_run) { g_n.fetch_sub(1); return false; }
  Lis x;
  x.s = s; x.id = id; x.pub = pub; x.in_at = now;
  g_in.push_back(std::move(x));
  return true;
}

// ---- the core's functions --------------------------------------------------------------------------------------------------------------
static bool hex_ok(const char *s, size_t lo, size_t hi)
{
  const size_t n = s ? strlen(s) : 0;
  if (n < lo || n > hi) return false;
  for (size_t i = 0; i < n; ++i) if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return false;
  return true;
}
int audience_start(const char *folder, int cap, int kbps, int pub_port)
{
#ifdef _WIN32
  if (!g_wsa) { WSADATA w; g_wsa = WSAStartup(MAKEWORD(2, 2), &w) == 0; }
#endif
  {
    std::lock_guard<std::mutex> l(g_mx);
    g_folder = folder ? folder : "";
    g_cap = std::max(1, std::min(cap, CAP_MAX));
    g_kbps = std::max(32, std::min(kbps, 256));
  }
  if (!g_run.exchange(true)) g_fan = std::thread(fan_loop);
  if (pub_port < 0 || pub_port > 65535) pub_port = 0;
  int open_port;
  { std::lock_guard<std::mutex> l(g_mx); open_port = g_pub_port; }
  if (pub_port == open_port && (pub_port == 0 || g_pub_run)) return 1;
  pub_close();
  std::string why = pub_port ? pub_open(pub_port) : "";
  std::lock_guard<std::mutex> l(g_mx);
  g_pub_err = why;
  return why.empty() ? 1 : 0;
}
int audience_link(const char *id, const char *code, int seconds, int pub)
{
  if (!hex_ok(id, 16, 16)) return 0;
  std::lock_guard<std::mutex> l(g_mx);
  if (!code || !*code) { g_links.erase(id); return 1; } // (its listeners are closed by the fan-out thread within 0.25 s)
  if (!hex_ok(code, 32, 64) || seconds <= 0) return 0;
  if (!g_links.count(id) && (int)g_links.size() >= MAX_LINKS) return 0;
  AudLink &k = g_links[id];
  k.code = code;
  k.until = now_s() + std::min(seconds, 7 * 24 * 3600);
  k.pub = pub != 0;
  return 1;
}
int audience_info(const char *full, const char *pub, const char *mix)
{
  auto ok = [](const char *j) { const size_t n = j ? strlen(j) : 0; return n >= 2 && n <= 2048 && j[0] == '{' && j[n - 1] == '}'; };
  if (!ok(full) || !ok(pub)) return 0;
  std::lock_guard<std::mutex> l(g_mx);
  if (g_full != full || g_pub != pub) { g_full = full; g_pub = pub; ++g_info_ver; }
  g_mix_path = mix ? mix : "";
  return 1;
}
const char *audience_status()
{
  std::lock_guard<std::mutex> l(g_mx);
  char b[512];
  snprintf(b, sizeof(b), "{\"running\":%s,\"cap\":%d,\"kbps\":%d,\"listeners\":%d,\"public\":%d,\"public_port\":%d,\"public_listening\":%s,"
           "\"packets\":%lld,\"skipped\":%lld,\"slow_closed\":%lld,\"bytes\":%lld,\"out_kbps\":%.1f,\"enc_load\":%.5f,\"served\":%lld,\"refused\":%lld,"
           "\"limited\":%lld,\"full\":%lld,\"links\":{",
           g_run ? "true" : "false", g_cap, g_kbps, g_n.load(), g_pub_n, g_pub_port, g_pub_run ? "true" : "false", g_packets.load(), g_skipped.load(),
           g_slow.load(), g_bytes.load(), g_out_kbps.load(), g_enc_load.load(), g_served, g_refused, g_limited, g_full_n);
  g_status = b;
  bool first = true;
  for (const auto &kv : g_links) {
    auto it = g_link_n.find(kv.first);
    snprintf(b, sizeof(b), "%s\"%s\":{\"n\":%d,\"pub\":%s,\"left\":%.0f}", first ? "" : ",", kv.first.c_str(), it == g_link_n.end() ? 0 : it->second,
             kv.second.pub ? "true" : "false", std::max(0.0, kv.second.until - now_s()));
    g_status += b;
    first = false;
  }
  g_status += "},\"public_error\":\"";
  for (char c : g_pub_err) if (c != '"' && c != '\\' && (unsigned char)c >= 0x20) g_status += c;
  g_status += "\"}";
  return g_status.c_str();
}
void audience_feed(const double *L, const double *R, int len, double srate)
{
  if (g_n.load(std::memory_order_relaxed) <= 0 || len <= 0 || !L) return;
  g_rsr.store(srate, std::memory_order_relaxed);
  if (!R) R = L;
  unsigned long long w = g_rw.load(std::memory_order_relaxed);
  for (int k = 0; k < len; ++k, ++w) { float *d = &g_ring[(w & (RN - 1)) * 2]; d[0] = (float)L[k]; d[1] = (float)R[k]; }
  g_rw.store(w, std::memory_order_release);
}
int audience_count() { return g_n.load(); }
void audience_shutdown()
{
  pub_close();
  g_run = false;
  if (g_fan.joinable()) g_fan.join();
  std::lock_guard<std::mutex> l(g_mx);
  g_links.clear();
  g_mix_path.clear();
}

// (webui.cpp's hooks: set when this file is linked in, so the web UI hands over /listen/ and keeps the audio hook in while anyone listens)
static void hook_feed(const double *L, const double *R, int len, double srate) { audience_feed(L, R, len, srate); }
static struct AudHook {
  AudHook() { webui_listen_http = audience_http; webui_listen_feed = hook_feed; webui_listen_count = audience_count; webui_listen_stop = audience_shutdown; }
} g_aud_hook;

// ---- ReaScript: reaper.StudioSync_Audience* --------------------------------------------------------------------------------------------
#ifndef AUDIENCE_STANDALONE
#include "reaper_plugin.h"
#define S_(i) (n > (i) ? (const char *)a[i] : nullptr)
#define I_(i) (n > (i) ? (int)(INT_PTR)a[i] : 0)
static void *va_start_(void **a, int n) { return (void *)(INT_PTR)audience_start(S_(0), I_(1), I_(2), I_(3)); }
static void *va_link(void **a, int n) { return (void *)(INT_PTR)audience_link(S_(0), S_(1), I_(2), I_(3)); }
static void *va_info(void **a, int n) { return (void *)(INT_PTR)audience_info(S_(0), S_(1), S_(2)); }
static void *va_status(void **, int) { return (void *)audience_status(); }
#undef S_
#undef I_
void audience_register(reaper_plugin_info_t *rec)
{
  static const struct { const char *name; void *fn, *va; const char *def; } fns[] = {
    { "StudioSync_AudienceStart", (void *)audience_start, (void *)va_start_,
      "int\0const char*,int,int,int\0folder,cap,kbps,public_port\0"
      "Live to an audience (lib/audience.lua): listeners hear the session mix as Opus over a WebSocket at /listen/ (the pages in `folder`), "
      "at most `cap` (1-100) at kbps (32-256). public_port: a listener of its own on 127.0.0.1 that serves only the listening page, for "
      "`tailscale funnel` (0: none). Returns 1, 0 when the public port couldn't be opened." },
    { "StudioSync_AudienceLink", (void *)audience_link, (void *)va_link,
      "int\0const char*,const char*,int,int\0id,code,seconds,public\0"
      "A listening link: id (16 lower-case hex) opens with ?l=<code> (32-64 lower-case hex) for `seconds`; public 1: also on the public port. "
      "code \"\": revoked, its listeners closed. Returns 1, 0 for a bad id/code or more than 8 links." },
    { "StudioSync_AudienceInfo", (void *)audience_info, (void *)va_info,
      "int\0const char*,const char*,const char*\0full,public,mix\0"
      "What listeners are told (JSON objects under 2 KB, passed on as they are): full to tailnet listeners, public to the public port's; "
      "mix: the latest bounced mix's path for /listen/mix (\"\" none). Returns 1." },
    { "StudioSync_AudienceStatus", (void *)audience_status, (void *)va_status,
      "const char*\0\0\0Live to an audience as JSON: running, cap, kbps, listeners, public (listeners on the public port), public_port, "
      "public_listening, public_error, packets, skipped, slow_closed, bytes, out_kbps, enc_load (the encoder's share of a core), served, "
      "refused, limited, full, links ({ id: { n, pub, left } })." },
  };
  char key[96];
  for (const auto &f : fns) {
    snprintf(key, sizeof(key), "API_%s", f.name); rec->Register(key, f.fn);
    snprintf(key, sizeof(key), "APIdef_%s", f.name); rec->Register(key, (void *)f.def);
    snprintf(key, sizeof(key), "APIvararg_%s", f.name); rec->Register(key, f.va);
  }
}
#endif
