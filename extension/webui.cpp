// StudioSync's web UI server (extension/webui.h has the why). One thread accepts on 127.0.0.1; the direct link's listener hands over HTTP
// connections that reach it on the Tailscale address; each connection gets a short-lived thread of its own (at most MAX_CLIENTS: an open
// event stream holds one). One request per connection, then closed, except the event stream. Nothing here touches REAPER's API: the
// ReaScript functions at the end only copy under a lock. Only files under the pages' folder, and the files Lua offers by name
// (StudioSync_WebUIOffer: the latest mix of each song, lib/phonerec.lua), are ever read; nothing is ever run.
// GPL-3.0-or-later.
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
#define SEND_FLAGS MSG_NOSIGNAL // (a browser gone mid-answer would raise SIGPIPE, which ends REAPER)
#else
#define SEND_FLAGS 0
#endif
#endif
#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <random>
#include <set>
#include <thread>
#include "direct.h"
#include "webui.h"

// ---- the pure parts ---------------------------------------------------------------------------------------------------------------------
static std::string lower(std::string s) { for (char &c : s) if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a'); return s; }
static std::string trim(const std::string &s)
{
  size_t a = 0, b = s.size();
  while (a < b && (s[a] == ' ' || s[a] == '\t')) ++a;
  while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t')) --b;
  return s.substr(a, b - a);
}

bool webui_parse_head(const std::string &head, WebReq &out)
{
  out = WebReq();
  size_t e = head.find("\r\n");
  if (e == std::string::npos) return false;
  const std::string line = head.substr(0, e);
  const size_t s1 = line.find(' '), s2 = s1 == std::string::npos ? s1 : line.find(' ', s1 + 1);
  if (s2 == std::string::npos || line.find(' ', s2 + 1) != std::string::npos) return false;
  out.method = line.substr(0, s1);
  const std::string target = line.substr(s1 + 1, s2 - s1 - 1), ver = line.substr(s2 + 1);
  if (out.method.empty() || out.method.size() > 8 || (ver != "HTTP/1.1" && ver != "HTTP/1.0")) return false;
  for (char c : out.method) if (c < 'A' || c > 'Z') return false;
  if (target.empty() || target[0] != '/' || target.size() > 2048) return false;
  for (unsigned char c : target) if (c <= ' ' || c >= 127) return false;
  const size_t q = target.find('?');
  out.path = target.substr(0, q);
  if (q != std::string::npos) out.query = target.substr(q + 1);
  for (size_t at = e + 2; at < head.size();) {
    const size_t n = head.find("\r\n", at);
    if (n == std::string::npos) return false;
    if (n == at) break; // the blank line
    const std::string h = head.substr(at, n - at);
    const size_t colon = h.find(':');
    if (colon == std::string::npos || colon == 0) return false;
    out.headers[lower(trim(h.substr(0, colon)))] = trim(h.substr(colon + 1));
    at = n + 2;
  }
  return true;
}

bool webui_file_for(const std::string &path, std::string &rel, std::string &ctype)
{
  rel = path == "/" ? "index.html" : path.substr(path.empty() ? 0 : 1);
  if (rel.empty() || rel.size() > 200) return false;
  for (char c : rel) if (!(isalnum((unsigned char)c) || c == '.' || c == '-' || c == '_' || c == '/')) return false;
  static const char *dev[] = { "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
                               "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9" };
  for (size_t at = 0; at <= rel.size();) {
    size_t n = rel.find('/', at);
    if (n == std::string::npos) n = rel.size();
    const std::string seg = rel.substr(at, n - at);
    if (seg.empty() || seg[0] == '.') return false; // (no "..", no hidden files, no "//" or a trailing "/")
    const std::string base = lower(seg.substr(0, seg.find('.')));
    for (const char *d : dev) if (base == d) return false; // (Windows opens a device for these, whatever the folder)
    at = n + 1;
  }
  const size_t dot = rel.rfind('.');
  const std::string ext = dot == std::string::npos || rel.find('/', dot) != std::string::npos ? "" : lower(rel.substr(dot + 1));
  static const struct { const char *ext, *type; } types[] = {
    { "html", "text/html; charset=utf-8" }, { "css", "text/css; charset=utf-8" }, { "js", "text/javascript; charset=utf-8" },
    { "json", "application/json" }, { "svg", "image/svg+xml" }, { "png", "image/png" }, { "ico", "image/x-icon" },
    { "webmanifest", "application/manifest+json" }, { "txt", "text/plain; charset=utf-8" } };
  for (const auto &t : types) if (ext == t.ext) { ctype = t.type; return true; }
  return false;
}

std::string webui_token(const std::string &secret)
{
  if (secret.empty()) return "";
  static const char label[] = "StudioSync web UI v1";
  unsigned char mac[32];
  direct_hmac_sha256((const unsigned char *)secret.data(), secret.size(), (const unsigned char *)label, sizeof(label) - 1, mac);
  std::string out;
  char b[3];
  for (int i = 0; i < 16; ++i) { snprintf(b, sizeof(b), "%02x", mac[i]); out += b; }
  return out;
}

std::string webui_param(const std::string &query, const std::string &name)
{
  for (size_t at = 0; at <= query.size();) {
    size_t n = query.find('&', at);
    if (n == std::string::npos) n = query.size();
    const std::string kv = query.substr(at, n - at);
    const size_t eq = kv.find('=');
    if (eq != std::string::npos && kv.compare(0, eq, name) == 0 && eq == name.size()) return kv.substr(eq + 1);
    at = n + 1;
  }
  return "";
}

std::string webui_cookie(const std::string &header, const std::string &name)
{
  for (size_t at = 0; at < header.size();) {
    size_t n = header.find(';', at);
    if (n == std::string::npos) n = header.size();
    const std::string kv = trim(header.substr(at, n - at));
    const size_t eq = kv.find('=');
    if (eq != std::string::npos && kv.substr(0, eq) == name) return kv.substr(eq + 1);
    at = n + 1;
  }
  return "";
}

static bool same_text(const std::string &a, const std::string &b) // (constant time for equal lengths: the token's length is no secret)
{
  if (a.size() != b.size() || a.empty()) return false;
  unsigned char d = 0;
  for (size_t i = 0; i < a.size(); ++i) d |= (unsigned char)(a[i] ^ b[i]);
  return d == 0;
}
static std::string header(const WebReq &r, const char *name) { auto it = r.headers.find(name); return it == r.headers.end() ? "" : it->second; }

// (a proxy on this computer: `tailscale serve` giving the pages an https:// address, which a phone's browser wants before a page may use
// the microphone (lib/phonerec.lua). What it hands over came from the tailnet, so it needs the token as the link's port does)
static bool proxied_req(const WebReq &r)
{
  return !header(r, "x-forwarded-host").empty() || !header(r, "x-forwarded-for").empty() || !header(r, "x-forwarded-proto").empty();
}
int webui_auth(const WebReq &r, bool local, const std::string &token, int port, bool &set_cookie)
{
  set_cookie = false;
  const std::string host = header(r, "host"), origin = header(r, "origin");
  const std::string fwd_host = header(r, "x-forwarded-host");
  const bool proxied = proxied_req(r);
  if (r.method == "POST" && header(r, "x-studiosync") != "1") return 403;
  if (!origin.empty() && origin != "http://" + host && origin != "https://" + host && !(proxied && origin == "https://" + fwd_host))
    return 403; // (a page from anywhere else, asking with the visitor's cookie)
  if (local && !proxied) {
    char a[48], b[48];
    snprintf(a, sizeof(a), "127.0.0.1:%d", port);
    snprintf(b, sizeof(b), "localhost:%d", port);
    return host == a || host == b ? 0 : 403;
  }
  if (token.empty()) return 403;
  const std::string t = webui_param(r.query, "t");
  if (!t.empty()) {
    if (!same_text(t, token)) return 403;
    set_cookie = r.method == "GET";
    return 0;
  }
  return same_text(webui_cookie(header(r, "cookie"), "ss_webui"), token) ? 0 : 403;
}

// ---- browser guests: who gets in (webui.h; lib/guestweb.lua) ------------------------------------------------------------------------------
// Only these: the guest's page and the shared files it loads, and its own API under /api/guest/ (event stream, live socket, upload, action).
// Never /api/state or /api/events (every topic), /api/action, /api/upload, /api/file, /api/mix, /api/time or any other page.
bool webui_guest_path(const std::string &method, const std::string &path)
{
  if (method == "POST") return path == "/api/guest/action" || path == "/api/guest/upload";
  static const char *files[] = { "/guest.html", "/guest.js", "/guest.css", "/guestworklet.js", "/style.css", "/phonefile.js", "/api/guest/events", "/api/guest/live" };
  for (const char *f : files) if (path == f) return method == "GET";
  return false;
}
int webui_guest_auth(const WebReq &r, std::map<std::string, WebGuest> &guests, double now, const std::string &fresh, std::string &gid)
{
  gid.clear();
  const std::string host = header(r, "host"), origin = header(r, "origin"), fwd_host = header(r, "x-forwarded-host");
  if (r.method == "POST" && header(r, "x-studiosync") != "1") return 403;
  if (!origin.empty() && origin != "http://" + host && origin != "https://" + host && !(proxied_req(r) && origin == "https://" + fwd_host)) return 403;
  if (!webui_guest_path(r.method, r.path)) return 403;
  const std::string ck = webui_cookie(header(r, "cookie"), "ss_guest");
  for (auto &g : guests)
    if (!g.second.session.empty() && now < g.second.until && same_text(ck, g.second.session)) { gid = g.first; return 0; }
  const std::string code = webui_param(r.query, "g");
  if (code.empty() || r.method != "GET" || r.path != "/guest.html" || fresh.size() < 32) return 403;
  for (auto &g : guests) {
    WebGuest &w = g.second;
    if (w.code.empty() || now >= w.code_until || now >= w.until || !same_text(code, w.code)) continue;
    w.code.clear(); // (single use: the first browser gets it)
    w.session = fresh;
    gid = g.first;
    return 303;
  }
  return 403;
}

// One JSON object and nothing after it: the first '{' closes at the last byte (strings and escapes skipped). A guest's action is wrapped as
// {"topic":"guestweb","gid":...,"a":<it>}, so `{"x":1},"gid":"another guest's"` (closing early and adding keys of its own) must not pass.
static bool json_one_object(const std::string &s)
{
  if (s.empty() || s[0] != '{') return false;
  int depth = 0;
  bool str = false;
  for (size_t i = 0; i < s.size(); ++i) {
    const char c = s[i];
    if (str) { if (c == '\\') ++i; else if (c == '"') str = false; continue; }
    if (c == '"') str = true;
    else if (c == '{' || c == '[') ++depth;
    else if (c == '}' || c == ']') { if (--depth == 0) return i + 1 == s.size(); if (depth < 0) return false; }
  }
  return false;
}

// RFC 6455's handshake: base64(SHA-1(key + its GUID)). SHA-1 only here, where the protocol fixes it (no secret rests on it).
static void sha1(const std::string &m, unsigned char out[20])
{
  uint32_t h[5] = { 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 };
  std::string d = m;
  d += (char)0x80;
  while (d.size() % 64 != 56) d += '\0';
  const unsigned long long bits = (unsigned long long)m.size() * 8;
  for (int i = 7; i >= 0; --i) d += (char)((bits >> (i * 8)) & 0xff);
  auto rol = [](uint32_t x, int n) { return (x << n) | (x >> (32 - n)); };
  for (size_t at = 0; at < d.size(); at += 64) {
    uint32_t w[80];
    for (int i = 0; i < 16; ++i)
      w[i] = (uint32_t)(unsigned char)d[at + 4 * i] << 24 | (uint32_t)(unsigned char)d[at + 4 * i + 1] << 16 | (uint32_t)(unsigned char)d[at + 4 * i + 2] << 8 | (unsigned char)d[at + 4 * i + 3];
    for (int i = 16; i < 80; ++i) w[i] = rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    uint32_t a = h[0], b = h[1], c = h[2], e4 = h[3], e = h[4];
    for (int i = 0; i < 80; ++i) {
      const uint32_t f = i < 20 ? (b & c) | (~b & e4) : i < 40 ? b ^ c ^ e4 : i < 60 ? (b & c) | (b & e4) | (c & e4) : b ^ c ^ e4;
      const uint32_t k = i < 20 ? 0x5A827999 : i < 40 ? 0x6ED9EBA1 : i < 60 ? 0x8F1BBCDC : 0xCA62C1D6;
      const uint32_t t = rol(a, 5) + f + e + k + w[i];
      e = e4; e4 = c; c = rol(b, 30); b = a; a = t;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += e4; h[4] += e;
  }
  for (int i = 0; i < 20; ++i) out[i] = (unsigned char)(h[i / 4] >> (24 - 8 * (i % 4)));
}
std::string webui_ws_accept(const std::string &key)
{
  unsigned char d[20];
  sha1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11", d);
  static const char *b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string o;
  for (int i = 0; i < 20; i += 3) {
    const uint32_t v = (uint32_t)d[i] << 16 | (i + 1 < 20 ? (uint32_t)d[i + 1] << 8 : 0) | (i + 2 < 20 ? d[i + 2] : 0);
    o += b64[(v >> 18) & 63]; o += b64[(v >> 12) & 63];
    o += i + 1 < 20 ? b64[(v >> 6) & 63] : '=';
    o += i + 2 < 20 ? b64[v & 63] : '=';
  }
  return o;
}

// Live to an audience (extension/audience.cpp sets these when it's linked in; webui.h). rt-audience
bool (*webui_listen_http)(unsigned long long, const WebReq &, bool) = nullptr;
void (*webui_listen_feed)(const double *, const double *, int, double) = nullptr;
int (*webui_listen_count)() = nullptr;
void (*webui_listen_stop)() = nullptr;

// ---- state -----------------------------------------------------------------------------------------------------------------------------
namespace {
std::mutex g_mx; // guards everything below
std::condition_variable g_cv; // (a topic changed, a client went, or stopping)
std::map<std::string, std::string> g_topics;
std::map<std::string, long long> g_topic_ver; // (the g_ver each topic last changed at: the stream sends only what changed. James, rt)
long long g_ver = 0, g_served = 0, g_refused = 0;
std::deque<std::pair<std::string, bool>> g_actions; // (each with whether a page on this computer sent it: webui_poll_here)
std::string g_folder, g_token, g_bind, g_err, g_poll_out, g_status_out;
bool g_poll_here = false;
int g_port = 0, g_clients = 0;
bool g_listening = false, g_wsa = false;
double g_engine_at = -1e9;
std::set<sock_t> g_active;
std::atomic<bool> g_stop{ false };
sock_t g_lsock = BAD_SOCK;
std::thread g_lthr;
struct ExitGuard { ~ExitGuard() { if (g_lthr.joinable()) g_lthr.detach(); } } g_exit_guard; // (as direct.cpp's: REAPER exiting without unload)
const int MAX_CLIENTS = 16;
const size_t MAX_HEAD = 16 * 1024, MAX_BODY = 16 * 1024, MAX_FILE = 4 * 1024 * 1024, MAX_ACTIONS = 64, MAX_TOPIC = 1024 * 1024;
// A phone's take (lib/phonerec.lua): the recording, held until Lua saves it where the song wants it. 160 MB is 14 minutes of 48 kHz mono
// 32-bit float; two at most, the oldest let go (a page whose take is never placed can't fill memory).
const size_t MAX_UPLOAD = 160u * 1024 * 1024, MAX_UPLOADS = 2;
std::map<std::string, std::string> g_uploads; // id -> the bytes
std::deque<std::string> g_upload_order;
// Files a page may download (GET /api/file?id=): Lua names each, the server never picks a path (the phone app's mix to play along to)
const size_t MAX_OFFERS = 64;
std::map<std::string, std::string> g_offers; // id -> the path
// Browser guests (webui.h). Their uploads are kept apart from the phones' (a guest's never pushes a phone's take out): one each, two at most.
std::map<std::string, WebGuest> g_guests; // gid -> the guest
std::deque<std::string> g_guest_uploads;  // their upload ids, oldest first (each id starts with its guest's gid)
const size_t MAX_GUESTS = 8, MAX_GUEST_UPLOADS = 2, GUEST_QUEUE = 8; // (GUEST_QUEUE: one guest's actions waiting, so a flood can't fill the queue)

double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
bool topic_ok(const char *t)
{
  if (!t || !(*t >= 'a' && *t <= 'z')) return false;
  size_t n = 0;
  for (const char *p = t; *p; ++p, ++n) if (!((*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9') || *p == '_' || *p == '-') || n >= 32) return false;
  return true;
}
void json_str(std::string &o, const std::string &s)
{
  o += '"';
  for (unsigned char c : s) {
    if (c == '"' || c == '\\') { o += '\\'; o += (char)c; }
    else if (c < 0x20) { char b[8]; snprintf(b, sizeof(b), "\\u%04x", c); o += b; }
    else o += (char)c;
  }
  o += '"';
}
// (under g_mx) What every page shows: the topics as Live sync last published them, and whether Live sync is still asking (5 s).
// since >= 0: only the topics changed after that version, marked "delta" (the event stream after its first: a big song's arrange view isn't
// sent again each time someone's cursor moves; a page keeps the topics it has. James, rt)
// only: that one topic and nothing else (a browser guest's stream: rt-browserjoin).
std::string snapshot_locked(long long since = -1, const std::string &only = "")
{
  std::string o = "{\"ver\":" + std::to_string(g_ver) + ",\"engine\":" + (now_s() - g_engine_at < 5 ? "true" : "false") +
                  (since >= 0 ? ",\"delta\":true" : "") + ",\"topics\":{";
  bool first = true;
  for (const auto &kv : g_topics) {
    if (!only.empty() && kv.first != only) continue;
    if (since >= 0 && g_topic_ver[kv.first] <= since) continue;
    if (!first) o += ',';
    first = false;
    json_str(o, kv.first);
    o += ':';
    o += kv.second;
  }
  return o + "}}";
}

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
bool send_all(sock_t s, const std::string &d)
{
  for (size_t at = 0; at < d.size();) {
    const int k = (int)send(s, d.data() + at, (int)std::min<size_t>(d.size() - at, 65536), SEND_FLAGS);
    if (k <= 0) return false;
    at += (size_t)k;
  }
  return true;
}
const char *reason(int code)
{
  switch (code) {
  case 200: return "OK"; case 202: return "Accepted"; case 206: return "Partial Content"; case 416: return "Range Not Satisfiable"; case 303: return "See Other"; case 400: return "Bad Request"; case 403: return "Forbidden";
  case 404: return "Not Found"; case 405: return "Method Not Allowed"; case 413: return "Payload Too Large"; case 503: return "Service Unavailable";
  default: return "Error";
  }
}
// (no-referrer: a first visit's URL carries the token; the CSP lets the pages load nothing but their own files, so a chat message can't
// become script even if a page ever put one into HTML)
const char *SAFE_HEADERS = "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
  "Content-Security-Policy: default-src 'self'; img-src 'self' data:; frame-ancestors 'none'\r\n";
void answer(sock_t s, int code, const char *ctype, const std::string &body, const std::string &extra = "")
{
  std::string h = "HTTP/1.1 " + std::to_string(code) + " " + reason(code) + "\r\nContent-Type: " + ctype + "\r\nContent-Length: " +
                  std::to_string(body.size()) + "\r\n" + SAFE_HEADERS + extra + "Connection: close\r\n\r\n";
  send_all(s, h + body);
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
bool read_page(const std::string &folder, const std::string &rel, std::string &out)
{
  if (folder.empty()) return false;
  FILE *f = open_read(folder + "/" + rel);
  if (!f) return false;
  char b[16384];
  size_t n;
  out.clear();
  while ((n = fread(b, 1, sizeof(b), f)) > 0 && out.size() <= MAX_FILE) out.append(b, n);
  fclose(f);
  return out.size() <= MAX_FILE;
}

// The event stream: everything now, then the topics that changed whenever one does (or just "engine" when Live sync starts or stops asking);
// a comment every 15 s keeps phones' and proxies' idle timers from closing it.
// gid: a browser guest's stream, only its own topic "guest-<gid>", ended when the guest is (rt-browserjoin).
bool guest_on_locked(const std::string &gid) { auto it = g_guests.find(gid); return it != g_guests.end() && !it->second.session.empty() && now_s() < it->second.until; }
void events(sock_t s, const std::string &gid = "")
{
  if (!send_all(s, std::string("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n") + SAFE_HEADERS + "Connection: keep-alive\r\n\r\nretry: 2000\n\n")) return;
  const std::string only = gid.empty() ? "" : "guest-" + gid;
  long long sent_ver = -1, sent_tv = -1;
  bool sent_engine = false;
  double ping_at = now_s();
  for (;;) {
    std::string data;
    {
      std::unique_lock<std::mutex> l(g_mx);
      g_cv.wait_for(l, std::chrono::seconds(1), [&] { return g_stop || g_ver != sent_ver; });
      if (g_stop || (!gid.empty() && !guest_on_locked(gid))) return;
      const bool engine = now_s() - g_engine_at < 5;
      const auto tv = only.empty() ? g_ver : (g_topic_ver.count(only) ? g_topic_ver[only] : 0); // (a guest's: only when its own topic moved)
      if (only.empty() ? (g_ver != sent_ver || engine != sent_engine) : (tv != sent_tv || engine != sent_engine)) {
        data = snapshot_locked(sent_tv < 0 ? -1 : sent_ver, only); // (-1 the first time: everything)
        sent_tv = tv;
        sent_engine = engine;
      }
      sent_ver = g_ver;
    }
    if (!data.empty()) {
      for (char &c : data) if (c == '\n' || c == '\r') c = ' '; // (one event is one data line)
      if (!send_all(s, "data: " + data + "\n\n")) return;
      ping_at = now_s();
    } else if (now_s() - ping_at > 15) {
      if (!send_all(s, ": ping\n\n")) return;
      ping_at = now_s();
    }
  }
}

// A phone's take, its raw bytes (Content-Length, no more than MAX_UPLOAD): kept under a new id for StudioSync_WebUISaveUpload. -> { ok, id }
// gid: a browser guest's take: its id starts with the gid (Lua takes only those from that guest), its earlier one let go, two guests' at most.
std::string rand_hex(int words) // (under g_mx: random_device isn't shared between threads)
{
  static std::random_device rd;
  std::string o;
  char b[12];
  for (int i = 0; i < words; ++i) { snprintf(b, sizeof(b), "%08x", (unsigned)rd()); o += b; }
  return o;
}
void upload(sock_t s, const WebReq &r, std::string body, const std::string &gid = "")
{
  const std::string cl = header(r, "content-length");
  const long long n = cl.empty() || cl.size() > 12 || cl.find_first_not_of("0123456789") != std::string::npos ? -1 : atoll(cl.c_str());
  if (n <= 0 || (size_t)n > MAX_UPLOAD) return answer(s, 413, "application/json", "{\"ok\":false,\"why\":\"too big\"}");
  set_blocking(s, 30000); // (a phone on a slow connection: 30 s without a byte is a phone that's gone)
  body.reserve((size_t)n);
  std::string chunk(65536, '\0');
  while (body.size() < (size_t)n) {
    const int k = (int)recv(s, &chunk[0], (int)chunk.size(), 0);
    if (k <= 0) return;
    body.append(chunk.data(), (size_t)k);
  }
  body.resize((size_t)n);
  std::string id;
  {
    std::lock_guard<std::mutex> l(g_mx);
    id = gid + rand_hex(2);
    if (!gid.empty()) {
      if (!guest_on_locked(gid)) return answer(s, 403, "application/json", "{\"ok\":false,\"why\":\"ended\"}"); // (kicked while it came)
      for (auto it = g_guest_uploads.begin(); it != g_guest_uploads.end();)
        if (it->compare(0, gid.size(), gid) == 0) { g_uploads.erase(*it); it = g_guest_uploads.erase(it); } else ++it;
      while (g_guest_uploads.size() >= MAX_GUEST_UPLOADS) { g_uploads.erase(g_guest_uploads.front()); g_guest_uploads.pop_front(); }
      g_guest_uploads.push_back(id);
    } else {
      while (g_upload_order.size() >= MAX_UPLOADS) { g_uploads.erase(g_upload_order.front()); g_upload_order.pop_front(); }
      g_upload_order.push_back(id);
    }
    g_uploads[id] = std::move(body);
  }
  answer(s, 200, "application/json", std::string("{\"ok\":true,\"id\":\"") + id + "\"}");
}

// An offered file's type, by its name: video and pictures typed so a <video> or <img> takes them (the Project page's thumbnails); anything
// else as bytes. Never a type a browser would run (no HTML, SVG or script). (rt-video2)
const char *offer_type(const std::string &path)
{
  const size_t dot = path.rfind('.');
  const std::string ext = dot == std::string::npos ? "" : lower(path.substr(dot + 1));
  static const struct { const char *ext, *type; } types[] = { { "mp4", "video/mp4" }, { "m4v", "video/mp4" }, { "mov", "video/quicktime" },
    { "webm", "video/webm" }, { "mkv", "video/x-matroska" }, { "png", "image/png" }, { "jpg", "image/jpeg" }, { "jpeg", "image/jpeg" }, { "gif", "image/gif" } };
  for (const auto &t : types) if (ext == t.ext) return t.type;
  return "application/octet-stream";
}
// "bytes=a-b", "bytes=a-" or "bytes=-n" (one range only) against a file of n bytes -> the first and last byte; false when there's no range to
// honour (absent, several, or malformed: the whole file); `bad` when it's past the end (416).
bool byte_range(const std::string &h, long long n, long long &a, long long &z, bool &bad)
{
  bad = false;
  if (h.compare(0, 6, "bytes=") != 0 || h.find(',') != std::string::npos) return false;
  const std::string v = h.substr(6);
  const size_t dash = v.find('-');
  if (dash == std::string::npos || v.find_first_not_of("0123456789-") != std::string::npos || v.size() > 40) return false;
  const std::string l = v.substr(0, dash), r = v.substr(dash + 1);
  if (r.find('-') != std::string::npos || (l.empty() && r.empty())) return false;
  if (l.empty()) { const long long k = atoll(r.c_str()); if (k <= 0) { bad = true; return false; } a = std::max(0LL, n - k); z = n - 1; }
  else { a = atoll(l.c_str()); z = r.empty() ? n - 1 : std::min(atoll(r.c_str()), n - 1); }
  if (a >= n || z < a) { bad = true; return false; }
  return true;
}
// A file Lua offered, streamed as it's read (a mix can be 100 MB: never held in memory whole). A byte range is answered (206): a <video>
// seeks by asking for one, and Safari plays nothing from a server that can't. (rt-video2)
void send_file(sock_t s, const std::string &id, const std::string &range = "")
{
  std::string path;
  { std::lock_guard<std::mutex> l(g_mx); auto it = g_offers.find(id); if (it != g_offers.end()) path = it->second; }
  FILE *f = path.empty() ? nullptr : open_read(path);
  if (!f) return answer(s, 404, "text/plain", "not found\n");
#ifdef _WIN32
  _fseeki64(f, 0, SEEK_END); const long long n = _ftelli64(f); _fseeki64(f, 0, SEEK_SET);
#else
  fseeko(f, 0, SEEK_END); const long long n = (long long)ftello(f); fseeko(f, 0, SEEK_SET);
#endif
  if (n < 0) { fclose(f); return answer(s, 404, "text/plain", "not found\n"); }
  long long a = 0, z = n - 1;
  bool bad = false;
  const bool part = byte_range(range, n, a, z, bad);
  if (bad) { fclose(f); return answer(s, 416, "text/plain", "", "Content-Range: bytes */" + std::to_string(n) + "\r\n"); }
#ifdef _WIN32
  if (part) _fseeki64(f, a, SEEK_SET);
#else
  if (part) fseeko(f, (off_t)a, SEEK_SET);
#endif
  set_blocking(s, 30000); // (a phone on a slow connection)
  bool ok = send_all(s, std::string(part ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n") + "Content-Type: " + offer_type(path) +
                            "\r\nContent-Length: " + std::to_string(z - a + 1) + "\r\nAccept-Ranges: bytes\r\n" +
                            (part ? "Content-Range: bytes " + std::to_string(a) + "-" + std::to_string(z) + "/" + std::to_string(n) + "\r\n" : "") +
                            SAFE_HEADERS + "Connection: close\r\n\r\n");
  std::string b(65536, '\0');
  long long left = z - a + 1;
  size_t k;
  while (ok && left > 0 && (k = fread(&b[0], 1, (size_t)std::min<long long>(left, (long long)b.size()), f)) > 0) { ok = send_all(s, b.substr(0, k)); left -= (long long)k; }
  fclose(f);
}

// ---- a screen share's sound: REAPER's mix for this computer's pages (GET /api/mix; webui.h) ------------------------------------------
// One writer (the audio thread) and a few readers, each with its own place: a reader copies what's new, then checks the writer hasn't come
// round over it meanwhile (a reader that slow skips ahead). shortcut: 16-bit little-endian (every target StudioSync builds for is), stereo
// from the first output pair only; a master routed elsewhere needs a pair choice.
const unsigned long long MIX_N = 1ull << 17; // frames kept: 2.7 s at 48 kHz
const int MIX_STREAMS = 4;
short g_mix[MIX_N * 2];
std::atomic<unsigned long long> g_mix_w{ 0 };
std::atomic<double> g_mix_sr{ 0 };
std::atomic<int> g_mix_on{ 0 };
short mix16(double v) { v *= 32767.0; return (short)(v >= 32767.0 ? 32767 : v <= -32768.0 ? -32768 : v >= 0 ? v + 0.5 : v - 0.5); }
void mix_stream(sock_t s)
{
  if (g_mix_on.fetch_add(1) >= MIX_STREAMS) { g_mix_on.fetch_sub(1); return answer(s, 503, "text/plain", "busy\n"); }
  struct Off { ~Off() { g_mix_on.fetch_sub(1); } } off;
  const unsigned long long w0 = g_mix_w.load(std::memory_order_acquire);
  // (1.5 s by the clock, not by count: a loaded Mac's 10 ms sleeps run long, and a page waiting longer looks like a dead server)
  for (const double until = now_s() + 1.5; !g_stop && now_s() < until && g_mix_w.load(std::memory_order_acquire) == w0;) std::this_thread::sleep_for(std::chrono::milliseconds(10));
  const double sr = g_mix_sr.load();
  if (g_mix_w.load(std::memory_order_acquire) == w0 || sr < 8000 || sr > 768000) // (the hook goes in from REAPER's main thread within a moment)
    return answer(s, 503, "text/plain; charset=utf-8", "REAPER's audio isn't running, or this extension can't hear it.\n");
  if (!send_all(s, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nX-Rate: " + std::to_string((long long)sr) + "\r\nX-Channels: 2\r\n" + SAFE_HEADERS + "Connection: close\r\n\r\n")) return;
  unsigned long long pos = g_mix_w.load(std::memory_order_acquire);
  double fed_at = now_s();
  std::string out;
  while (!g_stop) {
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    if (g_mix_sr.load() != sr) return; // (a new rate: the page starts again with it)
    const unsigned long long w = g_mix_w.load(std::memory_order_acquire);
    if (w == pos) { if (now_s() - fed_at > 5) return; continue; } // (REAPER's audio stopped: the page says so and asks again)
    if (w < pos || w - pos > MIX_N / 2) pos = w - std::min(w, (unsigned long long)(sr * 0.05)); // (far behind: from now)
    fed_at = now_s();
    out.clear();
    for (unsigned long long at = pos; at < w;) { // (two pieces where it wraps)
      const unsigned long long i = at % MIX_N, n = std::min(w - at, MIX_N - i);
      out.append((const char *)&g_mix[i * 2], (size_t)(n * 4));
      at += n;
    }
    if (g_mix_w.load(std::memory_order_acquire) - pos > MIX_N) { pos = w; continue; } // (written over while copying: dropped)
    if (!send_all(s, out)) return;
    pos = w;
  }
}

// ---- a browser guest's live audio (GET /api/guest/live, a WebSocket; webui.h) ----------------------------------------------------------
// Down: the session mix ring (as REAPER's mix above, fed after live audio added the bandmates), each frame [SG1\0][u32 rate][f64 link-clock
// time of its first sample][16-bit stereo]. The time comes from a seqlock'd stamp the audio thread writes per block (its frame count and
// direct_now). Up: [16-bit mono] at that rate into the guest's own ring, which the audio thread drains: heard once GUP_TARGET has come,
// trimmed back to it when more than GUP_OVER piles up (the two sound cards' drift, a burst after a stall), silent on an underrun until it
// has refilled. shortcut: no resampler, the page runs its audio at REAPER's rate (the browser converts to its device); a guest's clock that
// drifts far shows as drops/underruns in the status, upgrade to a drift-correcting resampler if Health shows them often.
const unsigned long long GMIX_N = 1ull << 17;
short g_gmix[GMIX_N * 2];
std::atomic<unsigned long long> g_gmix_w{ 0 };
std::atomic<double> g_gmix_sr{ 0 };
std::atomic<unsigned> g_gstamp_seq{ 0 };
std::atomic<unsigned long long> g_gstamp_w{ 0 };
std::atomic<double> g_gstamp_t{ 0 };
const int GUEST_LIVE = 2;              // guests live at once
const unsigned long long GUP_N = 1ull << 15; // frames of a guest's sound waiting: 0.68 s at 48 kHz
const double GUP_TARGET = 0.06, GUP_OVER = 0.15; // s
const size_t WS_MAX = 65536;           // bytes in one frame from a guest (a 10 ms message is ~1 KB)
struct GuestSlot {
  std::atomic<int> taken{ 0 };         // 0 free, 2 being set up, 1 live
  char gid[17] = {};
  float ring[GUP_N];
  std::atomic<unsigned long long> w{ 0 }, r{ 0 };
  std::atomic<bool> playing{ false };
  std::atomic<float> gain{ 1.f }, peak{ 0.f };
  std::atomic<long long> under{ 0 }, drops{ 0 };
};
GuestSlot g_gslot[GUEST_LIVE];
std::atomic<int> g_guests_live{ 0 };
float g_talk[8192];                    // (the audio thread's own: the guests it heard in the last post call, for the next pre call's Talk)
int g_talk_n = 0;

bool ws_send(sock_t s, int op, const char *d, size_t n)
{
  std::string h(1, (char)(0x80 | op));
  if (n < 126) h += (char)n;
  else if (n < 65536) { h += (char)126; h += (char)(n >> 8); h += (char)(n & 255); }
  else { h += (char)127; for (int i = 7; i >= 0; --i) h += (char)((unsigned long long)n >> (8 * i) & 255); }
  return send_all(s, h + std::string(d, n));
}
double gstamp_time(unsigned long long pos, double sr) // (the link clock of session-mix frame pos)
{
  for (int i = 0; i < 100; ++i) {
    const unsigned q = g_gstamp_seq.load(std::memory_order_acquire);
    const unsigned long long w = g_gstamp_w.load(std::memory_order_relaxed);
    const double t = g_gstamp_t.load(std::memory_order_relaxed);
    std::atomic_thread_fence(std::memory_order_acquire);
    if (!(q & 1) && q == g_gstamp_seq.load(std::memory_order_relaxed)) return t + ((double)pos - (double)w) / sr;
  }
  return direct_now();
}
void guest_live(sock_t s, const WebReq &r, const std::string &gid)
{
  const std::string key = header(r, "sec-websocket-key");
  if (lower(header(r, "upgrade")) != "websocket" || lower(header(r, "connection")).find("upgrade") == std::string::npos ||
      header(r, "sec-websocket-version") != "13" || key.size() != 24)
    return answer(s, 400, "text/plain", "this is a WebSocket\n");
  for (auto &g : g_gslot) if (g.taken.load() == 1 && gid == g.gid) return answer(s, 409, "text/plain", "already live in another window\n");
  GuestSlot *slot = nullptr;
  for (auto &g : g_gslot) { int z = 0; if (g.taken.compare_exchange_strong(z, 2)) { slot = &g; break; } }
  if (!slot) return answer(s, 503, "text/plain", "two guests are live already\n");
  snprintf(slot->gid, sizeof(slot->gid), "%s", gid.c_str());
  slot->w.store(0); slot->r.store(0); slot->playing.store(false); slot->peak.store(0); slot->under.store(0); slot->drops.store(0);
  { std::lock_guard<std::mutex> l(g_mx); auto it = g_guests.find(gid); slot->gain.store(it != g_guests.end() ? it->second.gain : 1.f); }
  slot->taken.store(1, std::memory_order_release);
  g_guests_live.fetch_add(1);
  struct Free { GuestSlot *s; ~Free() { g_guests_live.fetch_sub(1); s->taken.store(0, std::memory_order_release); } } free_slot{ slot };
  if (!send_all(s, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + webui_ws_accept(key) + "\r\n\r\n")) return;
  int one = 1;
  setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&one, sizeof(one)); // (10 ms frames: no Nagle wait)
  set_blocking(s, 2000); // (a guest that takes nothing for 2 s is gone)
  std::string in, pcm;
  unsigned long long pos = g_gmix_w.load(std::memory_order_acquire);
  double check_at = 0, sec_at = now_s();
  long long sec_frames = 0;
  char b[16384];
  while (!g_stop) {
#ifdef _WIN32
    WSAPOLLFD p = { s, POLLIN, 0 };
    const int ready = WSAPoll(&p, 1, 5);
#else
    pollfd p = { s, POLLIN, 0 };
    const int ready = poll(&p, 1, 5);
#endif
    if (ready < 0) return;
    if (ready > 0) {
      const int k = (int)recv(s, b, sizeof(b), 0);
      if (k <= 0) return;
      in.append(b, (size_t)k);
    }
    while (in.size() >= 2) { // (each whole frame in: masked, unfragmented, no bigger than WS_MAX)
      const unsigned char b0 = (unsigned char)in[0], b1 = (unsigned char)in[1];
      if (!(b1 & 0x80) || !(b0 & 0x80) || (b0 & 0x70)) return; // (a client's frames are masked; no fragments, no extensions)
      size_t n = b1 & 127, hl = 2;
      if (n == 126) { if (in.size() < 4) break; n = (size_t)(unsigned char)in[2] << 8 | (unsigned char)in[3]; hl = 4; }
      else if (n == 127) return;
      if (n > WS_MAX) return;
      if (in.size() < hl + 4 + n) break;
      std::string d = in.substr(hl + 4, n);
      for (size_t i = 0; i < n; ++i) d[i] = (char)(d[i] ^ in[hl + (i & 3)]);
      in.erase(0, hl + 4 + n);
      const int op = b0 & 15;
      if (op == 8) { ws_send(s, 8, "", 0); return; }
      if (op == 9) { if (!ws_send(s, 10, d.data(), std::min<size_t>(n, 125))) return; continue; }
      if (op != 2) continue; // (text, pong: nothing to do)
      const unsigned long long frames = n / 2;
      const double sr = g_gmix_sr.load();
      sec_frames += (long long)frames;
      { // (far faster than sound, past a second's burst after a stall: not a guest's page)
        const double el = now_s() - sec_at, rmax = std::max(48000.0, sr);
        if ((double)sec_frames > 3 * rmax * el + rmax) return;
        if (el >= 2) { sec_at = now_s(); sec_frames = 0; }
      }
      const unsigned long long w = slot->w.load(std::memory_order_relaxed), rd = slot->r.load(std::memory_order_acquire);
      if (w - rd + frames > GUP_N) { slot->drops.fetch_add(1); continue; } // (the audio thread isn't taking it: REAPER's audio stopped)
      for (unsigned long long i = 0; i < frames; ++i) {
        short v;
        memcpy(&v, &d[(size_t)i * 2], 2);
        slot->ring[(w + i) % GUP_N] = (float)v / 32768.f;
      }
      slot->w.store(w + frames, std::memory_order_release);
    }
    if (in.size() > 4 * WS_MAX) return;
    const double sr = g_gmix_sr.load();
    unsigned long long w = g_gmix_w.load(std::memory_order_acquire);
    if (sr >= 8000 && sr <= 768000 && w != pos) {
      if (w < pos || w - pos > GMIX_N / 2) pos = w - std::min(w, (unsigned long long)(sr * 0.05)); // (far behind: from now)
      while (w - pos >= (unsigned long long)(sr * 0.005)) { // (5 ms at least a frame, 4096 frames at most)
        const unsigned long long n = std::min<unsigned long long>(w - pos, 4096);
        const unsigned rate = (unsigned)sr;
        const double t = gstamp_time(pos, sr);
        pcm.assign("SG1\0", 4);
        pcm.append((const char *)&rate, 4);
        pcm.append((const char *)&t, 8);
        for (unsigned long long at = pos; at < pos + n;) {
          const unsigned long long i = at % GMIX_N, m = std::min(pos + n - at, GMIX_N - i);
          pcm.append((const char *)&g_gmix[i * 2], (size_t)(m * 4));
          at += m;
        }
        if (g_gmix_w.load(std::memory_order_acquire) - pos > GMIX_N) { pos = g_gmix_w.load(); break; } // (written over while copying)
        if (!ws_send(s, 2, pcm.data(), pcm.size())) return;
        pos += n;
      }
    }
    if (now_s() - check_at > 0.1) { // (kicked or run out: closed; the host's level for them)
      check_at = now_s();
      std::lock_guard<std::mutex> l(g_mx);
      if (!guest_on_locked(gid)) { ws_send(s, 8, "\x03\xf0", 2); return; } // (1008: policy)
      slot->gain.store(g_guests[gid].gain);
    }
  }
}

thread_local bool t_kept = false; // (a listener's socket handed to audience.cpp: client() leaves it open. rt-audience)
void handle(sock_t s, std::string buf, bool local)
{
  set_blocking(s, 5000);
  char chunk[4096];
  size_t end;
  while ((end = buf.find("\r\n\r\n")) == std::string::npos && buf.size() < MAX_HEAD) {
    const int k = (int)recv(s, chunk, sizeof(chunk), 0);
    if (k <= 0) return;
    buf.append(chunk, (size_t)k);
  }
  WebReq r;
  if (end == std::string::npos || !webui_parse_head(buf.substr(0, end + 4), r)) return answer(s, 400, "text/plain", "bad request\n");
  if (webui_listen_http && r.path.compare(0, 8, "/listen/") == 0) { t_kept = webui_listen_http((unsigned long long)s, r, false); return; } // (the listening page: its own allow-list and links, never the studio's token. rt-audience)
  std::string token, folder;
  int port;
  { std::lock_guard<std::mutex> l(g_mx); token = g_token; folder = g_folder; port = g_port; }
  bool set_cookie = false;
  // (a browser guest: /api/guest/* is theirs alone, never the studio token's; a guest link (?g=) is always theirs to redeem; the guest's own
  // files open with either. rt-browserjoin)
  std::string gid;
  const bool guest_only = r.path.compare(0, 11, "/api/guest/") == 0, redeem = r.path == "/guest.html" && !webui_param(r.query, "g").empty();
  if (guest_only || redeem || webui_auth(r, local, token, port, set_cookie) != 0) {
    set_cookie = false;
    int g;
    std::string session;
    {
      std::lock_guard<std::mutex> l(g_mx);
      g = webui_guest_auth(r, g_guests, now_s(), rand_hex(4), gid);
      if (g == 303) session = g_guests[gid].session;
      ++(g == 403 ? g_refused : g_served);
    }
    if (g == 303)
      return answer(s, 303, "text/plain", "", "Location: /guest.html\r\nSet-Cookie: ss_guest=" + session + "; Path=/; HttpOnly; SameSite=Lax\r\n");
    if (g != 0)
      return answer(s, 403, "text/plain; charset=utf-8", guest_only || redeem ? "This guest link was used already, has run out, or was ended. Ask for a new one.\n"
                                                         : local ? "Open this page from REAPER (StudioSync's Chat page: Web UI).\n"
                                                                 : "This needs the studio's link: StudioSync's Chat page, Copy phone link, on the computer in the studio.\n");
    if (r.method == "POST" && r.path == "/api/guest/upload") return upload(s, r, buf.substr(end + 4), gid);
    if (r.path == "/api/guest/events") return events(s, gid);
    if (r.path == "/api/guest/live") return guest_live(s, r, gid);
  } else { std::lock_guard<std::mutex> l(g_mx); ++g_served; }
  if (set_cookie) // (the token goes into a cookie and out of the address bar. Lax, not Strict: a Strict cookie isn't sent on the redirect of a
    // link followed from elsewhere (a chat app on a phone), so the page got 403. Every action still needs X-StudioSync. Desktop, rt)
    return answer(s, 303, "text/plain", "", "Location: " + r.path + "\r\nSet-Cookie: ss_webui=" + token + "; Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax\r\n");
  if (r.method == "POST" && r.path == "/api/upload") return upload(s, r, buf.substr(end + 4));
  if (r.method == "POST") {
    if (r.path != (gid.empty() ? "/api/action" : "/api/guest/action")) return answer(s, 404, "text/plain", "not found\n");
    const std::string cl = header(r, "content-length");
    const long long n = cl.empty() ? -1 : atoll(cl.c_str());
    if (n <= 0 || (size_t)n > MAX_BODY || cl.find_first_not_of("0123456789") != std::string::npos) return answer(s, 413, "text/plain", "too big\n");
    std::string body = buf.substr(end + 4);
    while (body.size() < (size_t)n) {
      const int k = (int)recv(s, chunk, sizeof(chunk), 0);
      if (k <= 0) return;
      body.append(chunk, (size_t)k);
    }
    body.resize((size_t)n);
    if (body[0] != '{') return answer(s, 400, "text/plain", "an action is a JSON object\n"); // (Lua parses and checks the rest)
    {
      std::lock_guard<std::mutex> l(g_mx);
      if (g_actions.size() >= MAX_ACTIONS) return answer(s, 503, "application/json", "{\"ok\":false,\"why\":\"busy\"}");
      if (!gid.empty()) { // (a guest's, wrapped so it can only ever be the guest's own topic; a few at a time per guest)
        if (!json_one_object(body)) return answer(s, 400, "text/plain", "an action is one JSON object\n");
        const std::string tag = "{\"topic\":\"guestweb\",\"gid\":\"" + gid + "\",\"a\":";
        size_t mine = 0;
        for (const auto &a : g_actions) if (a.first.compare(0, tag.size(), tag) == 0) ++mine;
        if (mine >= GUEST_QUEUE) return answer(s, 503, "application/json", "{\"ok\":false,\"why\":\"busy\"}");
        body = tag + body + "}";
      }
      g_actions.emplace_back(body, local && !proxied_req(r) && gid.empty()); // (this computer's own page: not the link's port, not `tailscale serve`, not a guest)
    }
    return answer(s, 202, "application/json", "{\"ok\":true}");
  }
  if (r.method != "GET") return answer(s, 405, "text/plain", "GET or POST\n");
  if (r.path == "/api/events") return events(s);
  if (r.path == "/api/time") { // (the link's clock, StudioSync_DirectNow's: a phone's page measures its offset against it, NTP's way. lib/phonerec.lua)
    char t[64];
    snprintf(t, sizeof(t), "{\"now\":%.6f}", direct_now());
    return answer(s, 200, "application/json", t);
  }
  if (r.path == "/api/file") return send_file(s, webui_param(r.query, "id"), header(r, "range"));
  if (r.path == "/api/mix") { // (REAPER's own mix for a screen share: this computer's pages only, never the tailnet or a proxy's)
    if (!local || !header(r, "x-forwarded-host").empty() || !header(r, "x-forwarded-for").empty() || !header(r, "x-forwarded-proto").empty())
      return answer(s, 403, "text/plain", "this computer only\n");
    return mix_stream(s);
  }
  if (r.path == "/api/state") {
    std::string snap;
    { std::lock_guard<std::mutex> l(g_mx); snap = snapshot_locked(); }
    return answer(s, 200, "application/json", snap);
  }
  std::string rel, ctype, page;
  if (!webui_file_for(r.path, rel, ctype) || !read_page(folder, rel, page)) return answer(s, 404, "text/plain", "not found\n");
  answer(s, 200, ctype.c_str(), page);
}

void client(sock_t s, std::string buf, bool local)
{
  t_kept = false;
  handle(s, std::move(buf), local);
  if (!t_kept) {
#ifdef _WIN32
    shutdown(s, SD_SEND);
#else
    shutdown(s, SHUT_WR);
#endif
    close_sock(s);
  }
  std::lock_guard<std::mutex> l(g_mx);
  --g_clients;
  g_active.erase(s);
  g_cv.notify_all();
}
void spawn(sock_t s, const char *buf, size_t n, bool local)
{
  {
    std::lock_guard<std::mutex> l(g_mx);
    if (g_clients < MAX_CLIENTS && !g_stop) {
      ++g_clients;
      g_active.insert(s);
      std::thread(client, s, std::string(buf, n), local).detach();
      return;
    }
    ++g_refused;
  }
  set_blocking(s, 1000);
  answer(s, 503, "text/plain", "busy\n");
  close_sock(s);
}

// The direct link's listener found an HTTP request on its port (the Tailscale address): ours, with what it already read.
bool from_link(unsigned long long s, const char *buf, size_t n)
{
  if (n < 4 || (memcmp(buf, "GET ", 4) != 0 && memcmp(buf, "POST", 4) != 0)) return false;
  spawn((sock_t)s, buf, n, false);
  return true;
}

void accept_loop(sock_t ls)
{
  while (!g_stop) {
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
    direct_noinherit(s);
    const unsigned char *a = (const unsigned char *)&from.sin_addr;
    if (from.sin_family != AF_INET || a[0] != 127) { close_sock(s); continue; } // (bound to loopback: never otherwise, but checked)
    spawn(s, "", 0, true);
  }
}

void stop_listening()
{
  g_stop = true;
  if (g_lthr.joinable()) g_lthr.join();
  if (g_lsock != BAD_SOCK) { close_sock(g_lsock); g_lsock = BAD_SOCK; }
  g_stop = false;
  std::lock_guard<std::mutex> l(g_mx);
  g_listening = false;
}
} // namespace

void webui_mix_feed(const double *const *out, int nout, int len, double srate)
{
  if (g_mix_on.load(std::memory_order_relaxed) <= 0 || len <= 0 || nout <= 0 || !out || !out[0]) return;
  g_mix_sr.store(srate, std::memory_order_relaxed);
  const double *L = out[0], *R = nout > 1 && out[1] ? out[1] : out[0];
  unsigned long long w = g_mix_w.load(std::memory_order_relaxed);
  for (int k = 0; k < len; ++k, ++w) { short *d = &g_mix[(w % MIX_N) * 2]; d[0] = mix16(L[k]); d[1] = mix16(R[k]); }
  g_mix_w.store(w, std::memory_order_release);
}
int webui_mix_wanted() { return g_mix_on.load() + g_guests_live.load() + (webui_listen_count ? webui_listen_count() : 0); }

// ---- browser guests (webui.h) ------------------------------------------------------------------------------------------------------------
static bool hex_ok(const char *s, size_t lo, size_t hi)
{
  const size_t n = s ? strlen(s) : 0;
  if (n < lo || n > hi) return false;
  for (size_t i = 0; i < n; ++i) if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return false;
  return true;
}
int webui_guest_set(const char *gid, const char *code, int code_s, int session_s)
{
  if (!hex_ok(gid, 16, 16)) return 0;
  std::lock_guard<std::mutex> l(g_mx);
  if (!code || !*code) { g_guests.erase(gid); g_cv.notify_all(); return 1; } // (its stream ends at once, its socket within 0.1 s)
  if (!hex_ok(code, 24, 64) || code_s <= 0 || session_s <= 0) return 0;
  if (!g_guests.count(gid) && g_guests.size() >= MAX_GUESTS) return 0;
  WebGuest &g = g_guests[gid];
  g = WebGuest(); // (a new code for a gid: its old browser's session ends with it)
  g.code = code;
  g.code_until = now_s() + std::min(code_s, session_s);
  g.until = now_s() + session_s;
  g_cv.notify_all();
  return 1;
}
int webui_guest_gain(const char *gid, double gain)
{
  std::lock_guard<std::mutex> l(g_mx);
  auto it = gid ? g_guests.find(gid) : g_guests.end();
  if (it == g_guests.end() || !(gain >= 0)) return 0;
  it->second.gain = (float)std::min(gain, 4.0);
  return 1;
}
void webui_guest_audio(double *const *out, int nout, int len, double srate)
{
  if (webui_listen_feed && len > 0 && nout > 0 && out && out[0]) webui_listen_feed(out[0], nout > 1 && out[1] ? out[1] : out[0], len, srate); // (listeners: the session mix, before any guest is added. rt-audience)
  if (g_guests_live.load(std::memory_order_relaxed) <= 0 || len <= 0 || nout <= 0 || !out || !out[0]) { g_talk_n = 0; return; }
  g_gmix_sr.store(srate, std::memory_order_relaxed);
  unsigned long long w = g_gmix_w.load(std::memory_order_relaxed);
  const unsigned q = g_gstamp_seq.load(std::memory_order_relaxed);
  g_gstamp_seq.store(q + 1, std::memory_order_relaxed);
  std::atomic_thread_fence(std::memory_order_release);
  g_gstamp_w.store(w, std::memory_order_relaxed);
  g_gstamp_t.store(direct_now(), std::memory_order_relaxed);
  g_gstamp_seq.store(q + 2, std::memory_order_release);
  double *L = out[0], *R = nout > 1 && out[1] ? out[1] : nullptr;
  for (int k = 0; k < len; ++k, ++w) { short *d = &g_gmix[(w % GMIX_N) * 2]; d[0] = mix16(L[k]); d[1] = mix16(R ? R[k] : L[k]); }
  g_gmix_w.store(w, std::memory_order_release);
  const int tn = std::min(len, 8192);
  std::fill(g_talk, g_talk + tn, 0.f);
  g_talk_n = tn;
  for (auto &g : g_gslot) {
    if (g.taken.load(std::memory_order_acquire) != 1) continue;
    const unsigned long long gw = g.w.load(std::memory_order_acquire);
    unsigned long long gr = g.r.load(std::memory_order_relaxed);
    const double target = srate * GUP_TARGET;
    if (!g.playing.load(std::memory_order_relaxed)) {
      if ((double)(gw - gr) < target + len) continue; // (filling up first: a little buffer against the network's jitter)
      g.playing.store(true, std::memory_order_relaxed);
    }
    if ((double)(gw - gr) > target + srate * GUP_OVER) { gr = gw - (unsigned long long)target; g.drops.fetch_add(1, std::memory_order_relaxed); }
    if (gw - gr < (unsigned long long)len) { g.playing.store(false, std::memory_order_relaxed); g.under.fetch_add(1, std::memory_order_relaxed); continue; }
    const float gain = g.gain.load(std::memory_order_relaxed);
    float pk = 0;
    for (int k = 0; k < len; ++k) {
      const float v = g.ring[(gr + (unsigned long long)k) % GUP_N] * gain;
      pk = std::max(pk, std::fabs(v));
      L[k] += v;
      if (R) R[k] += v;
      if (k < tn) g_talk[k] += v;
    }
    g.r.store(gr + (unsigned long long)len, std::memory_order_release);
    g.peak.store(std::max(pk, g.peak.load(std::memory_order_relaxed) * 0.97f), std::memory_order_relaxed); // (a meter: falls ~30 dB in 0.2 s at 128-frame blocks)
  }
}
void webui_guest_talk(float *const *ch, int nch, int len)
{
  const int n = std::min(len, g_talk_n);
  for (int c = 0; c < std::min(nch, 2); ++c)
    if (ch && ch[c]) for (int k = 0; k < n; ++k) ch[c][k] += g_talk[k];
}

// ---- the core's functions --------------------------------------------------------------------------------------------------------------
int webui_start(const char *folder, const char *secret, int port, const char *bind_ip)
{
#ifdef _WIN32
  if (!g_wsa) { WSADATA w; g_wsa = WSAStartup(MAKEWORD(2, 2), &w) == 0; }
#endif
  if (port <= 0) port = DIRECT_PORT;
  const std::string ip = bind_ip && *bind_ip ? bind_ip : "127.0.0.1";
  {
    std::lock_guard<std::mutex> l(g_mx);
    g_folder = folder ? folder : "";
    g_token = webui_token(secret ? secret : "");
    if (g_listening && g_port == port && g_bind == ip) return 1;
  }
  stop_listening();
  direct_set_http_handler(from_link); // (the link's port: phones on Tailscale. Only once a folder and token are here)
  std::string why;
  sock_t s = socket(AF_INET, SOCK_STREAM, 0);
  bool ok = s != BAD_SOCK;
  if (ok) {
    direct_noinherit(s);
#ifndef _WIN32
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
#endif
    sockaddr_in a = {};
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    inet_pton(AF_INET, ip.c_str(), &a.sin_addr);
    ok = bind(s, (sockaddr *)&a, sizeof(a)) == 0 && listen(s, 16) == 0;
    if (!ok) { close_sock(s); why = "can't listen on " + ip + ":" + std::to_string(port) + " (another REAPER, or something else, has it)"; }
  } else why = "no socket";
  if (ok) { g_lsock = s; g_lthr = std::thread(accept_loop, s); }
  std::lock_guard<std::mutex> l(g_mx);
  g_listening = ok;
  g_port = port;
  g_bind = ip;
  g_err = why;
  return ok ? 1 : 0;
}

void webui_publish(const char *topic, const char *json)
{
  if (!topic_ok(topic) || !json || !*json || strlen(json) > MAX_TOPIC) return;
  std::lock_guard<std::mutex> l(g_mx);
  g_engine_at = now_s();
  std::string &t = g_topics[topic];
  if (t == json) return;
  t = json;
  g_topic_ver[topic] = ++g_ver;
  g_cv.notify_all();
}

const char *webui_poll()
{
  std::lock_guard<std::mutex> l(g_mx);
  const bool was = now_s() - g_engine_at < 5;
  g_engine_at = now_s();
  if (!was) g_cv.notify_all(); // (the pages say at once that Live sync is back)
  g_poll_out.clear();
  g_poll_here = false;
  if (!g_actions.empty()) { g_poll_out = g_actions.front().first; g_poll_here = g_actions.front().second; g_actions.pop_front(); }
  return g_poll_out.c_str();
}
int webui_poll_here() { std::lock_guard<std::mutex> l(g_mx); return g_poll_here ? 1 : 0; }

const char *webui_status()
{
  std::lock_guard<std::mutex> l(g_mx);
  std::string o = std::string("{\"listening\":") + (g_listening ? "true" : "false") + ",\"bind\":";
  json_str(o, g_bind);
  o += ",\"port\":" + std::to_string(g_port) + ",\"error\":";
  json_str(o, g_err);
  o += ",\"token\":";
  json_str(o, g_token);
  o += ",\"clients\":" + std::to_string(g_clients) + ",\"served\":" + std::to_string(g_served) + ",\"refused\":" + std::to_string(g_refused);
  // (browser guests: redeemed, live on the socket, their peak since the last ask, underruns and drops. rt-browserjoin)
  o += ",\"guests\":{";
  bool first = true;
  for (const auto &g : g_guests) {
    if (!first) o += ',';
    first = false;
    json_str(o, g.first);
    o += std::string(":{\"redeemed\":") + (g.second.code.empty() ? "true" : "false") + ",\"on\":" + (now_s() < g.second.until ? "true" : "false");
    for (auto &sl : g_gslot) {
      if (sl.taken.load(std::memory_order_acquire) != 1 || g.first != sl.gid) continue;
      char b[160];
      snprintf(b, sizeof(b), ",\"live\":true,\"peak\":%.4f,\"under\":%lld,\"drops\":%lld", sl.peak.load(), sl.under.load(), sl.drops.load());
      o += b;
    }
    o += '}';
  }
  o += "}}";
  g_status_out = o;
  return g_status_out.c_str();
}

int webui_save_upload(const char *id, const char *path)
{
  if (!id || !path || !*path) return 0;
  std::string data;
  {
    std::lock_guard<std::mutex> l(g_mx);
    auto it = g_uploads.find(id);
    if (it == g_uploads.end()) return 0;
    data.swap(it->second);
  }
#ifdef _WIN32
  const int n = MultiByteToWideChar(CP_UTF8, 0, path, -1, nullptr, 0);
  std::wstring w(n > 0 ? n : 1, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, path, -1, &w[0], n);
  FILE *f = _wfopen(w.c_str(), L"wb");
#else
  FILE *f = fopen(path, "wb");
#endif
  bool ok = f && fwrite(data.data(), 1, data.size(), f) == data.size();
  if (f && fclose(f) != 0) ok = false;
  std::lock_guard<std::mutex> l(g_mx);
  auto it = g_uploads.find(id);
  if (!ok) { if (it != g_uploads.end()) it->second.swap(data); return -1; } // (kept for another try: the take isn't lost to a full disk)
  if (it != g_uploads.end()) g_uploads.erase(it);
  g_upload_order.erase(std::remove(g_upload_order.begin(), g_upload_order.end(), std::string(id)), g_upload_order.end());
  g_guest_uploads.erase(std::remove(g_guest_uploads.begin(), g_guest_uploads.end(), std::string(id)), g_guest_uploads.end());
  return data.size() > 0x7fffffff ? 0x7fffffff : (int)data.size();
}

int webui_offer(const char *id, const char *path)
{
  const std::string i = id ? id : "";
  if (i.empty() || i.size() > 32 || i.find_first_not_of("0123456789abcdef") != std::string::npos) return 0;
  std::lock_guard<std::mutex> l(g_mx);
  if (!path || !*path) { g_offers.erase(i); return 1; }
  if (g_offers.size() >= MAX_OFFERS && !g_offers.count(i)) return 0;
  g_offers[i] = path;
  return 1;
}

void webui_shutdown()
{
  direct_set_http_handler(nullptr);
  stop_listening();
  if (webui_listen_stop) webui_listen_stop(); // (its listeners and public port: rt-audience)
  {
    std::unique_lock<std::mutex> l(g_mx);
    g_stop = true;
    for (sock_t s : g_active) {
#ifdef _WIN32
      shutdown(s, SD_BOTH);
#else
      shutdown(s, SHUT_RDWR);
#endif
    }
    g_cv.notify_all();
    g_cv.wait_for(l, std::chrono::seconds(3), [] { return g_clients == 0; }); // (their code is in this library: gone before it unloads)
    g_stop = false;
    g_topics.clear();
    g_topic_ver.clear();
    g_actions.clear();
    g_uploads.clear();
    g_upload_order.clear();
    g_offers.clear();
    g_guests.clear();
    g_guest_uploads.clear();
  }
#ifdef _WIN32
  if (g_wsa) { WSACleanup(); g_wsa = false; }
#endif
}

// ---- ReaScript: reaper.StudioSync_WebUI* -----------------------------------------------------------------------------------------------
#ifndef WEBUI_STANDALONE
#include "reaper_plugin.h"
void audience_register(reaper_plugin_info_t *rec); // (extension/audience.cpp)
static int api_start(const char *folder, const char *secret, int port) { return webui_start(folder, secret, port, ""); }
static void api_publish(const char *topic, const char *json) { webui_publish(topic, json); }
static const char *api_poll() { return webui_poll(); }
static const char *api_status() { return webui_status(); }
static int api_poll_here() { return webui_poll_here(); }
static int api_save_upload(const char *id, const char *path) { return webui_save_upload(id, path); }
static int api_offer(const char *id, const char *path) { return webui_offer(id, path); }
static int api_guest(const char *gid, const char *code, int code_s, int session_s) { return webui_guest_set(gid, code, code_s, session_s); }
static int api_guest_gain(const char *gid, double gain) { return webui_guest_gain(gid, gain); }
#define S_(i) (n > (i) ? (const char *)a[i] : nullptr)
static void *va_guest(void **a, int n) { return n < 4 ? nullptr : (void *)(INT_PTR)api_guest(S_(0), S_(1), (int)(INT_PTR)a[2], (int)(INT_PTR)a[3]); }
static void *va_guest_gain(void **a, int n) { return n < 2 || !a[1] ? nullptr : (void *)(INT_PTR)api_guest_gain(S_(0), *(double *)a[1]); } // (a double comes as a pointer)
static void *va_save_upload(void **a, int n) { return (void *)(INT_PTR)api_save_upload(S_(0), S_(1)); }
static void *va_offer(void **a, int n) { return (void *)(INT_PTR)api_offer(S_(0), S_(1)); }
static void *va_start_(void **a, int n) { return (void *)(INT_PTR)api_start(S_(0), S_(1), n > 2 ? (int)(INT_PTR)a[2] : 0); }
static void *va_publish(void **a, int n) { api_publish(S_(0), S_(1)); return nullptr; }
static void *va_poll(void **, int) { return (void *)api_poll(); }
static void *va_status(void **, int) { return (void *)api_status(); }
static void *va_poll_here(void **, int) { return (void *)(INT_PTR)api_poll_here(); }
#undef S_

void webui_register(reaper_plugin_info_t *rec)
{
  static const struct { const char *name; void *fn, *va; const char *def; } fns[] = {
    { "StudioSync_WebUIStart", (void *)api_start, (void *)va_start_,
      "int\0const char*,const char*,int\0folder,secret,port\0"
      "StudioSync's web UI: serve the pages in `folder` on 127.0.0.1:port (0: 47281), and to the studio's devices on the direct link's port "
      "with the token derived from `secret`. Returns 1 when listening." },
    { "StudioSync_WebUIPublish", (void *)api_publish, (void *)va_publish,
      "void\0const char*,const char*\0topic,json\0The latest state of a topic (presence, chat...) for the web UI's pages, as JSON." },
    { "StudioSync_WebUIPoll", (void *)api_poll, (void *)va_poll,
      "const char*\0\0\0The oldest action the web UI's pages sent (a JSON object), or \"\". Each is handed out once." },
    { "StudioSync_WebUIPollHere", (void *)api_poll_here, (void *)va_poll_here,
      "int\0\0\0Whether the action StudioSync_WebUIPoll handed out last came from a page on this computer (1), not a phone or another "
      "device on the studio's link or through `tailscale serve` (0). lib/ai.lua: a yes for an AI run." },
    { "StudioSync_WebUIStatus", (void *)api_status, (void *)va_status,
      "const char*\0\0\0The web UI server's state, as JSON: listening, bind, port, error, token, clients, served, refused, guests "
      "({ gid: { redeemed, on, live, peak, under, drops } })." },
    { "StudioSync_WebUISaveUpload", (void *)api_save_upload, (void *)va_save_upload,
      "int\0const char*,const char*\0id,path\0"
      "A take a page uploaded (POST /api/upload's id), written to `path` and let go. Returns its bytes; 0 no such upload; -1 couldn't write "
      "(it's kept for another try)." },
    { "StudioSync_WebUIOffer", (void *)api_offer, (void *)va_offer,
      "int\0const char*,const char*\0id,path\0"
      "Lets the pages download the file at `path` as GET /api/file?id=<id> (id: up to 32 lower-case hex characters; 64 files at most). "
      "An empty path withdraws it. Returns 1, or 0 for a bad id or too many." },
    { "StudioSync_WebUIGuest", (void *)api_guest, (void *)va_guest,
      "int\0const char*,const char*,int,int\0gid,code,code_seconds,session_seconds\0"
      "A browser guest (lib/guestweb.lua): gid (16 lower-case hex) may join once with `code` (24-64 lower-case hex, as /guest.html?g=<code>) "
      "within code_seconds; the session it opens ends session_seconds from now. code \"\": the guest is ended at once (kicked). Their page, "
      "event stream (topic guest-<gid> only), live audio socket, actions (topic guestweb) and uploads (ids starting with gid) are theirs alone; "
      "StudioSync_WebUIStatus's guests say how each goes. Returns 1, or 0 for a bad gid or code or more than 8 guests." },
    { "StudioSync_WebUIGuestGain", (void *)api_guest_gain, (void *)va_guest_gain,
      "int\0const char*,double\0gid,gain\0A browser guest's level (linear, 0-4) in what this computer hears and sends on. Returns 1 when that guest is known." },
  };
  char key[96];
  for (const auto &f : fns) {
    snprintf(key, sizeof(key), "API_%s", f.name); rec->Register(key, f.fn);
    snprintf(key, sizeof(key), "APIdef_%s", f.name); rec->Register(key, (void *)f.def);
    snprintf(key, sizeof(key), "APIvararg_%s", f.name); rec->Register(key, f.va);
  }
  audience_register(rec); // (reaper.StudioSync_Audience*: lib/audience.lua. rt-audience)
  rec->Register("atexit", (void *)webui_shutdown); // (REAPER quitting: client threads end while everything's still there)
}
#endif
