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
#include <cstdlib>
#include <condition_variable>
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

int webui_auth(const WebReq &r, bool local, const std::string &token, int port, bool &set_cookie)
{
  set_cookie = false;
  const std::string host = header(r, "host"), origin = header(r, "origin");
  // (a proxy on this computer: `tailscale serve` giving the pages an https:// address, which a phone's browser wants before a page may use
  // the microphone (lib/phonerec.lua). What it hands over came from the tailnet, so it needs the token as the link's port does)
  const std::string fwd_host = header(r, "x-forwarded-host");
  const bool proxied = !fwd_host.empty() || !header(r, "x-forwarded-for").empty() || !header(r, "x-forwarded-proto").empty();
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

// ---- state -----------------------------------------------------------------------------------------------------------------------------
namespace {
std::mutex g_mx; // guards everything below
std::condition_variable g_cv; // (a topic changed, a client went, or stopping)
std::map<std::string, std::string> g_topics;
std::map<std::string, long long> g_topic_ver; // (the g_ver each topic last changed at: the stream sends only what changed. James, rt)
long long g_ver = 0, g_served = 0, g_refused = 0;
std::deque<std::string> g_actions;
std::string g_folder, g_token, g_bind, g_err, g_poll_out, g_status_out;
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
std::string snapshot_locked(long long since = -1)
{
  std::string o = "{\"ver\":" + std::to_string(g_ver) + ",\"engine\":" + (now_s() - g_engine_at < 5 ? "true" : "false") +
                  (since >= 0 ? ",\"delta\":true" : "") + ",\"topics\":{";
  bool first = true;
  for (const auto &kv : g_topics) {
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
  case 200: return "OK"; case 202: return "Accepted"; case 303: return "See Other"; case 400: return "Bad Request"; case 403: return "Forbidden";
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
void events(sock_t s)
{
  if (!send_all(s, std::string("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n") + SAFE_HEADERS + "Connection: keep-alive\r\n\r\nretry: 2000\n\n")) return;
  long long sent_ver = -1;
  bool sent_engine = false;
  double ping_at = now_s();
  for (;;) {
    std::string data;
    {
      std::unique_lock<std::mutex> l(g_mx);
      g_cv.wait_for(l, std::chrono::seconds(1), [&] { return g_stop || g_ver != sent_ver; });
      if (g_stop) return;
      const bool engine = now_s() - g_engine_at < 5;
      if (g_ver != sent_ver || engine != sent_engine) {
        data = snapshot_locked(sent_ver); // (-1 the first time: everything)
        sent_ver = g_ver; sent_engine = engine;
      }
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
void upload(sock_t s, const WebReq &r, std::string body)
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
  static std::random_device rd;
  char id[24];
  snprintf(id, sizeof(id), "%08x%08x", (unsigned)rd(), (unsigned)rd());
  {
    std::lock_guard<std::mutex> l(g_mx);
    while (g_upload_order.size() >= MAX_UPLOADS) { g_uploads.erase(g_upload_order.front()); g_upload_order.pop_front(); }
    g_uploads[id] = std::move(body);
    g_upload_order.push_back(id);
  }
  answer(s, 200, "application/json", std::string("{\"ok\":true,\"id\":\"") + id + "\"}");
}

// A file Lua offered, streamed as it's read (a mix can be 100 MB: never held in memory whole).
void send_file(sock_t s, const std::string &id)
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
  set_blocking(s, 30000); // (a phone on a slow connection)
  bool ok = send_all(s, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: " + std::to_string(n) + "\r\n" + SAFE_HEADERS + "Connection: close\r\n\r\n");
  std::string b(65536, '\0');
  size_t k;
  while (ok && (k = fread(&b[0], 1, b.size(), f)) > 0) ok = send_all(s, b.substr(0, k));
  fclose(f);
}

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
  std::string token, folder;
  int port;
  { std::lock_guard<std::mutex> l(g_mx); token = g_token; folder = g_folder; port = g_port; }
  bool set_cookie = false;
  if (webui_auth(r, local, token, port, set_cookie) != 0) {
    { std::lock_guard<std::mutex> l(g_mx); ++g_refused; }
    return answer(s, 403, "text/plain; charset=utf-8", local ? "Open this page from REAPER (StudioSync's Chat page: Web UI).\n"
                                                             : "This needs the studio's link: StudioSync's Chat page, Copy phone link, on the computer in the studio.\n");
  }
  { std::lock_guard<std::mutex> l(g_mx); ++g_served; }
  if (set_cookie) // (the token goes into a cookie and out of the address bar. Lax, not Strict: a Strict cookie isn't sent on the redirect of a
    // link followed from elsewhere (a chat app on a phone), so the page got 403. Every action still needs X-StudioSync. Desktop, rt)
    return answer(s, 303, "text/plain", "", "Location: " + r.path + "\r\nSet-Cookie: ss_webui=" + token + "; Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax\r\n");
  if (r.method == "POST" && r.path == "/api/upload") return upload(s, r, buf.substr(end + 4));
  if (r.method == "POST") {
    if (r.path != "/api/action") return answer(s, 404, "text/plain", "not found\n");
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
      g_actions.push_back(body);
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
  if (r.path == "/api/file") return send_file(s, webui_param(r.query, "id"));
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
  handle(s, std::move(buf), local);
#ifdef _WIN32
  shutdown(s, SD_SEND);
#else
  shutdown(s, SHUT_WR);
#endif
  close_sock(s);
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
  if (!g_actions.empty()) { g_poll_out = g_actions.front(); g_actions.pop_front(); }
  return g_poll_out.c_str();
}

const char *webui_status()
{
  std::lock_guard<std::mutex> l(g_mx);
  std::string o = std::string("{\"listening\":") + (g_listening ? "true" : "false") + ",\"bind\":";
  json_str(o, g_bind);
  o += ",\"port\":" + std::to_string(g_port) + ",\"error\":";
  json_str(o, g_err);
  o += ",\"token\":";
  json_str(o, g_token);
  o += ",\"clients\":" + std::to_string(g_clients) + ",\"served\":" + std::to_string(g_served) + ",\"refused\":" + std::to_string(g_refused) + "}";
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
  }
#ifdef _WIN32
  if (g_wsa) { WSACleanup(); g_wsa = false; }
#endif
}

// ---- ReaScript: reaper.StudioSync_WebUI* -----------------------------------------------------------------------------------------------
#ifndef WEBUI_STANDALONE
#include "reaper_plugin.h"
static int api_start(const char *folder, const char *secret, int port) { return webui_start(folder, secret, port, ""); }
static void api_publish(const char *topic, const char *json) { webui_publish(topic, json); }
static const char *api_poll() { return webui_poll(); }
static const char *api_status() { return webui_status(); }
static int api_save_upload(const char *id, const char *path) { return webui_save_upload(id, path); }
static int api_offer(const char *id, const char *path) { return webui_offer(id, path); }
#define S_(i) (n > (i) ? (const char *)a[i] : nullptr)
static void *va_save_upload(void **a, int n) { return (void *)(INT_PTR)api_save_upload(S_(0), S_(1)); }
static void *va_offer(void **a, int n) { return (void *)(INT_PTR)api_offer(S_(0), S_(1)); }
static void *va_start_(void **a, int n) { return (void *)(INT_PTR)api_start(S_(0), S_(1), n > 2 ? (int)(INT_PTR)a[2] : 0); }
static void *va_publish(void **a, int n) { api_publish(S_(0), S_(1)); return nullptr; }
static void *va_poll(void **, int) { return (void *)api_poll(); }
static void *va_status(void **, int) { return (void *)api_status(); }
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
    { "StudioSync_WebUIStatus", (void *)api_status, (void *)va_status,
      "const char*\0\0\0The web UI server's state, as JSON: listening, bind, port, error, token, clients, served, refused." },
    { "StudioSync_WebUISaveUpload", (void *)api_save_upload, (void *)va_save_upload,
      "int\0const char*,const char*\0id,path\0"
      "A take a page uploaded (POST /api/upload's id), written to `path` and let go. Returns its bytes; 0 no such upload; -1 couldn't write "
      "(it's kept for another try)." },
    { "StudioSync_WebUIOffer", (void *)api_offer, (void *)va_offer,
      "int\0const char*,const char*\0id,path\0"
      "Lets the pages download the file at `path` as GET /api/file?id=<id> (id: up to 32 lower-case hex characters; 64 files at most). "
      "An empty path withdraws it. Returns 1, or 0 for a bad id or too many." },
  };
  char key[96];
  for (const auto &f : fns) {
    snprintf(key, sizeof(key), "API_%s", f.name); rec->Register(key, f.fn);
    snprintf(key, sizeof(key), "APIdef_%s", f.name); rec->Register(key, (void *)f.def);
    snprintf(key, sizeof(key), "APIvararg_%s", f.name); rec->Register(key, f.va);
  }
  rec->Register("atexit", (void *)webui_shutdown); // (REAPER quitting: client threads end while everything's still there)
}
#endif
