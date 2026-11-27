// Live to an audience (extension/audience.cpp, docs/rt/rt-audience.md) without REAPER: the allow-list, links, rate limits and the
// resampler; then live, through the real web UI server (the tailnet way in) and the public port: the public port refuses everything but the
// listening page, its files, the socket and the mix; a 440/660 Hz stand-in "session mix" fed through webui_guest_audio arrives as Opus that
// decodes back to those tones; many stand-in listeners get the same packets from one encode (its cost measured); the cap, revoke, run out,
// the public port closing, a listener that never reads. Build and run: tests\build_audience_test.cmd (macOS/Linux: the line in it).
// GPL-3.0-or-later.
#define _USE_MATH_DEFINES
#ifdef _WIN32
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <direct.h>
#define mkdir_(p) _mkdir(p)
typedef SOCKET tsock;
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#define closesocket close
#define mkdir_(p) mkdir(p, 0755)
typedef int tsock;
#endif
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>
#include "opus.h"
#include "../extension/audience.h"
#include "../extension/audiohook.h"

static int fails = 0;
#define CHECK(c, what) do { if (c) printf("ok   %s\n", what); else { printf("FAIL %s\n", what); ++fails; } } while (0)
static void sleep_ms(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }
static double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static void spit(const std::string &p, const std::string &s) { FILE *f = fopen(p.c_str(), "wb"); fwrite(s.data(), 1, s.size(), f); fclose(f); }

static tsock dial(int port, int rcvbuf = 0)
{
  tsock s = socket(AF_INET, SOCK_STREAM, 0);
  if (rcvbuf) setsockopt(s, SOL_SOCKET, SO_RCVBUF, (const char *)&rcvbuf, sizeof rcvbuf);
  sockaddr_in a = {}; a.sin_family = AF_INET; a.sin_port = htons((unsigned short)port); inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
  if (connect(s, (sockaddr *)&a, sizeof a) != 0) { closesocket(s); return (tsock)-1; }
#ifdef _WIN32
  DWORD t = 3000; setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&t, sizeof t);
#else
  timeval tv = { 3, 0 }; setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
#endif
  return s;
}
static std::string ask(int port, const std::string &req)
{
  const tsock s = dial(port);
  if (s == (tsock)-1) return "";
  send(s, req.data(), (int)req.size(), 0);
  std::string out;
  char b[4096];
  int k;
  while ((k = recv(s, b, sizeof b, 0)) > 0) out.append(b, (size_t)k);
  closesocket(s);
  return out;
}
static std::string get(int port, const std::string &path, const std::string &extra = "", const char *method = "GET")
{
  return ask(port, std::string(method) + " " + path + " HTTP/1.1\r\nHost: pc.tail.ts.net:10000\r\nX-Forwarded-For: 203.0.113.9\r\n" + extra + "\r\n");
}
static int code(const std::string &resp) { return resp.size() > 12 ? atoi(resp.c_str() + 9) : -1; }
static std::string body(const std::string &resp) { const size_t e = resp.find("\r\n\r\n"); return e == std::string::npos ? "" : resp.substr(e + 4); }

// A listener: the handshake, then the server's frames (unmasked). -> the socket, or -1 with the answer's status in `status`.
static tsock ws_open(int port, const std::string &path, int &status, int rcvbuf = 0)
{
  status = -1;
  const tsock s = dial(port, rcvbuf);
  if (s == (tsock)-1) return s;
  const std::string req = "GET " + path + " HTTP/1.1\r\nHost: pc.tail.ts.net\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                          "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
  send(s, req.data(), (int)req.size(), 0);
  std::string h;
  char c;
  while (h.find("\r\n\r\n") == std::string::npos && recv(s, &c, 1, 0) == 1) h += c;
  status = code(h);
  if (status != 101 || h.find("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") == std::string::npos) { closesocket(s); return (tsock)-1; }
  return s;
}
static bool read_n(tsock s, char *d, size_t n) { for (size_t at = 0; at < n;) { const int k = (int)recv(s, d + at, (int)(n - at), 0); if (k <= 0) return false; at += (size_t)k; } return true; }
// One frame -> its opcode (-1: closed or timed out).
static int ws_read(tsock s, std::string &d)
{
  unsigned char h[2];
  if (!read_n(s, (char *)h, 2)) return -1;
  size_t n = h[1] & 127;
  if (n == 126) { unsigned char e[2]; if (!read_n(s, (char *)e, 2)) return -1; n = (size_t)e[0] << 8 | e[1]; }
  else if (n == 127) { unsigned char e[8]; if (!read_n(s, (char *)e, 8)) return -1; n = 0; for (int i = 0; i < 8; ++i) n = n << 8 | e[i]; }
  d.assign(n, '\0');
  if (n && !read_n(s, &d[0], n)) return -1;
  return h[0] & 15;
}

// Reads until the server closes the socket (a close frame, or the connection gone), for `secs` at most: whatever was still queued comes first.
static bool until_closed(tsock s, double secs)
{
  std::string d;
  for (const double t0 = now_s(); now_s() - t0 < secs;) { const int op = ws_read(s, d); if (op == 8 || op < 0) return true; }
  return false;
}

// The stand-in audio thread: REAPER's output, 440 Hz left and 660 Hz right at 0.5, in 128-frame blocks at `sr`, through the web UI's hook.
static std::atomic<bool> g_play{ false };
static std::atomic<double> g_sr{ 44100 };
static void audio_thread()
{
  double ph = 0;
  const double t0 = now_s();
  long long done = 0;
  std::vector<double> L(128), R(128);
  while (g_play) {
    const double sr = g_sr.load();
    const long long want = (long long)((now_s() - t0) * sr);
    while (done + 128 <= want) {
      for (int k = 0; k < 128; ++k, ++ph) { L[k] = 0.5 * sin(2 * M_PI * 440 * ph / sr); R[k] = 0.5 * sin(2 * M_PI * 660 * ph / sr); }
      double *out[2] = { L.data(), R.data() };
      webui_guest_audio(out, 2, 128, sr);
      done += 128;
    }
    sleep_ms(2);
  }
}
// Frequency by zero crossings (rising) over interleaved stereo channel c.
static double freq(const std::vector<float> &pcm, int c, double sr)
{
  int n = 0, first = -1, last = -1;
  const size_t frames = pcm.size() / 2;
  for (size_t i = 1; i < frames; ++i)
    if (pcm[(i - 1) * 2 + c] < 0 && pcm[i * 2 + c] >= 0) { if (first < 0) first = (int)i; last = (int)i; ++n; }
  return n > 1 ? (n - 1) * sr / (last - first) : 0;
}

// REAPER's audio hook struct as the extension meets it: the channel counts left at 0, the buffers there all the same (extension/audiohook.h).
static double g_fake[4][8];
static int g_fake_have = 0, g_fake_asked = 0;
struct FakeReg {
  int input_nch, output_nch;
  double *(*GetBuffer)(bool isOutput, int idx);
};
static double *fake_get(bool, int idx) { ++g_fake_asked; return idx >= 0 && idx < g_fake_have ? g_fake[idx] : nullptr; }

static void pure_tests()
{
  {
    FakeReg reg = { 0, 0, fake_get };
    double *out[2] = { nullptr, nullptr };
    const double *in[64] = { nullptr };
    g_fake_have = 2;
    CHECK(hook_buffers(&reg, true, out, 2) == 2 && out[0] == g_fake[0] && out[1] == g_fake[1], "the hook's outputs with output_nch left at 0 (REAPER 7): both buffers all the same");
    g_fake_asked = 0;
    CHECK(hook_buffers(&reg, false, in, 64) == 2 && in[0] == g_fake[0] && in[2] == nullptr && g_fake_asked == 3, "its inputs with input_nch 0: up to the first it doesn't have, asked no further");
    g_fake_have = 1;
    out[0] = out[1] = nullptr;
    CHECK(hook_buffers(&reg, true, out, 2) == 1 && out[0] && !out[1], "a mono device: one");
    g_fake_have = 0;
    CHECK(hook_buffers(&reg, true, out, 2) == 0 && !out[0], "no outputs: none");
    g_fake_have = 4;
    reg.input_nch = 3;
    g_fake_asked = 0;
    CHECK(hook_buffers(&reg, false, in, 64) == 3 && g_fake_asked == 3, "a count REAPER did set is the most asked for");
    // rt-p11: the master's own output pair (a master routed to outputs 3/4)
    reg.input_nch = 0;
    g_fake_have = 4;
    CHECK(hook_pair(&reg, 2, out) == 2 && out[0] == g_fake[2] && out[1] == g_fake[3], "the master on outputs 3/4: that pair");
    CHECK(hook_pair(&reg, 3, out) == 1 && out[0] == g_fake[3] && !out[1], "its first channel the device's last: that one");
    CHECK(hook_pair(&reg, 6, out) == 2 && out[0] == g_fake[0] && out[1] == g_fake[1], "a pair the device doesn't have: the first pair, as before");
    CHECK(hook_pair(&reg, 0, out) == 2 && out[0] == g_fake[0], "the first pair: as hook_buffers");
  }
  CHECK(audience_route("GET", "/listen/") == AUD_PAGE && audience_route("GET", "/listen/listen.js") == AUD_JS && audience_route("GET", "/listen/listen.css") == AUD_CSS &&
        audience_route("GET", "/listen/live") == AUD_LIVE && audience_route("GET", "/listen/mix") == AUD_MIX, "the listener paths");
  const char *no[] = { "/", "/index.html", "/listen", "/listen/x", "/listen/../index.html", "/listen/listen.html", "/api/state", "/api/events", "/api/mix",
                       "/api/file", "/api/time", "/api/guest/live", "/guest.html", "/record.html", "/app.js", "/listen/live/", "/LISTEN/" };
  bool all = true;
  for (const char *p : no) if (audience_route("GET", p) != AUD_NONE) { printf("     let through: %s\n", p); all = false; }
  CHECK(all, "and nothing else: no page, topic, action, file or mix of the web UI's");
  CHECK(audience_route("POST", "/listen/live") == AUD_NONE && audience_route("HEAD", "/listen/") == AUD_NONE && audience_route("PUT", "/listen/mix") == AUD_NONE, "GET only");

  std::map<std::string, AudLink> links;
  const std::string tc(32, 'a'), pc(40, 'b');
  links["1111111111111111"] = { tc, 100, false };
  links["2222222222222222"] = { pc, 100, true };
  auto req = [](const std::string &line) { WebReq w; webui_parse_head(line + " HTTP/1.1\r\nHost: x\r\n\r\n", w); return w; };
  std::string id;
  CHECK(audience_auth(req("GET /listen/?l=" + tc), links, 50, false, id) == 0 && id == "1111111111111111", "a tailnet link on the tailnet");
  CHECK(audience_auth(req("GET /listen/live?l=" + pc), links, 50, false, id) == 0 && id == "2222222222222222", "a public link on the tailnet too");
  CHECK(audience_auth(req("GET /listen/?l=" + tc), links, 50, true, id) == 403 && id.empty(), "a tailnet link on the public port: no");
  CHECK(audience_auth(req("GET /listen/mix?l=" + pc), links, 50, true, id) == 0, "a public link on the public port");
  CHECK(audience_auth(req("GET /listen/?l=" + pc), links, 100, true, id) == 403 && audience_auth(req("GET /listen/?l=" + tc), links, 101, false, id) == 403, "run out: no");
  CHECK(audience_auth(req("GET /listen/"), links, 50, false, id) == 403 && audience_auth(req("GET /listen/?l=" + std::string(32, 'c')), links, 50, false, id) == 403 &&
        audience_auth(req("GET /listen/?l=a"), links, 50, false, id) == 403 && audience_auth(req("GET /listen/?l=" + tc + "a"), links, 50, false, id) == 403,
        "no code, a wrong one, a short one, a longer one: no");
  CHECK(audience_auth(req("GET /listen/listen.js"), links, 50, true, id) == 0 && audience_auth(req("GET /listen/listen.css"), links, 50, true, id) == 0,
        "the script and style need no code");
  CHECK(audience_auth(req("GET /api/state?l=" + pc), links, 50, true, id) == 404, "anything else: not found, code or not");

  AudBucket b;
  int took = 0;
  for (int i = 0; i < 50; ++i) took += audience_bucket_take(b, 10, 5, 30);
  CHECK(took == 30, "a bucket: the burst at once");
  CHECK(!audience_bucket_take(b, 10.1, 5, 30) && audience_bucket_take(b, 10.3, 5, 30), "then the rate");

  std::vector<float> ring(1024 * 2), out(100 * 2);
  for (int i = 0; i < 1024; ++i) { ring[i * 2] = (float)i; ring[i * 2 + 1] = (float)-i; }
  double pos = 10;
  audience_resample(ring.data(), 1023, pos, 1.0, out.data(), 100);
  bool same = pos == 110;
  for (int k = 0; k < 100; ++k) same = same && out[k * 2] == (float)(10 + k) && out[k * 2 + 1] == (float)-(10 + k);
  CHECK(same, "the resampler at 1:1 is the input");
  std::vector<float> big(65536 * 2), o48(48000 * 2);
  for (int i = 0; i < 65536; ++i) { big[i * 2] = (float)sin(2 * M_PI * 1000 * i / 44100.0); big[i * 2 + 1] = 0; }
  pos = 3;
  audience_resample(big.data(), 65535, pos, 44100.0 / 48000, o48.data(), 48000);
  double err = 0;
  for (int k = 0; k < 48000; ++k) err = std::max(err, (double)std::fabs(o48[k * 2] - (float)sin(2 * M_PI * 1000 * (k + 3 * 48000 / 44100.0) / 48000)));
  CHECK(std::fabs(freq(o48, 0, 48000) - 1000) < 1 && err < 0.002, "44.1 kHz to 48 kHz: 1 kHz stays 1 kHz, within 0.2%");
  CHECK(audience_ws_frame(2, std::string(5, 'x')).size() == 7 && audience_ws_frame(1, std::string(300, 'x')).substr(0, 4) == std::string("\x81\x7e\x01\x2c", 4) &&
        audience_ws_frame(2, std::string(70000, 'x')).size() == 70010, "WebSocket frames: 7, 16 and 64-bit lengths");
}

// ---- public guests on the public port (rt-guestnet, Phase 1) --------------------------------------------------------------------------
// The guest page's paths handed to webui.cpp's public guest handler, as Funnel delivers them (its forwarded headers). Few wrong codes here: the
// public way's wrong-code bucket is the listeners' too (the lock test at the end).
static tsock open_raw(int port, const std::string &req) { const tsock s = dial(port); if (s != (tsock)-1) send(s, req.data(), (int)req.size(), 0); return s; }
static std::string head_of(tsock s) { std::string h; char c; while (h.find("\r\n\r\n") == std::string::npos && recv(s, &c, 1, 0) == 1) h += c; return h; }
static double closed_in(tsock s, double secs) // (seconds until the server ended the connection; -1 not within secs)
{
  char b[4096];
  for (const double t0 = now_s(); now_s() - t0 < secs;) { const int k = (int)recv(s, b, sizeof b, 0); if (k <= 0) return now_s() - t0; }
  return -1;
}
static void public_guest_tests(int web, int pubp, const std::string &pages, const std::string &dir)
{
  const std::string F = "Host: pc.tail.ts.net:10000\r\nX-Forwarded-Host: pc.tail.ts.net:10000\r\nX-Forwarded-Proto: https\r\nX-Forwarded-For: 203.0.113.9\r\n";
  const std::string T = "Host: pc.tail.ts.net:8443\r\nX-Forwarded-Host: pc.tail.ts.net:8443\r\nX-Forwarded-Proto: https\r\nX-Forwarded-For: 100.64.0.9\r\n";
  auto pq = [&](const std::string &line, const std::string &extra = "") { return ask(pubp, line + " HTTP/1.1\r\n" + F + extra + "\r\n"); };
  auto tq = [&](const std::string &line, const std::string &extra = "") { return ask(web, line + " HTTP/1.1\r\n" + T + extra + "\r\n"); };
  const std::string POST = "X-StudioSync: 1\r\nOrigin: https://pc.tail.ts.net:10000\r\nContent-Length: 0\r\n";
  const std::string gid = "0123456789abcdef", gc = "c0de0123456789abcdef0123", tgid = "1111222233334444", tc = "7a11e70123456789abcdef01";
  const std::string tok = webui_token("web-test-secret-0123456789");
  CHECK(webui_guest_set(gid.c_str(), gc.c_str(), 60, 3600) == 1 && webui_guest_public(gid.c_str(), 1) == 1 && webui_guest_set(tgid.c_str(), tc.c_str(), 60, 3600) == 1,
        "public guests: one public, one tailnet");
  CHECK(webui_guest_public("ffffffffffffffff", 1) == 0, "StudioSync_WebUIGuestPublic: an unknown guest, 0");
  CHECK(std::string(webui_status()).find("\"" + gid + "\":{\"redeemed\":false,\"on\":true,\"pub\":true") != std::string::npos, "the status says which is public");
  webui_publish(("guest-" + gid).c_str(), "{\"name\":\"Bo\"}");
  // a chat app's preview, then the guest opening it: the page, and the code still good
  std::string r = pq("GET /guest.html?g=" + gc);
  CHECK(code(r) == 200 && body(r) == "GUEST" && r.find("Set-Cookie") == std::string::npos && r.find("Referrer-Policy: no-referrer") != std::string::npos,
        "a public link opened (or fetched for a preview): the page, no cookie, nothing used up");
  CHECK(code(pq("GET /guest.html?g=" + gc)) == 200 && code(pq("GET /guest.js")) == 200, "opened again: still the page; its script needs no code");
  CHECK(code(pq("GET /api/guest/events")) == 403, "no session yet: their stream refused");
  CHECK(code(pq("POST /api/guest/redeem?g=" + gc, "Content-Length: 0\r\n")) == 403, "redeeming needs X-StudioSync (a form on another site can't send it)");
  // the public code on the tailnet port: refused, and not used up there
  CHECK(code(tq("GET /guest.html?g=" + gc)) == 403 && code(tq("POST /api/guest/redeem?g=" + gc, "X-StudioSync: 1\r\nContent-Length: 0\r\n")) == 403,
        "the public code on the tailnet port: refused (GET and POST)");
  // Join: POST redeems once
  r = pq("POST /api/guest/redeem?g=" + gc, POST);
  const size_t at = r.find("ss_pguest=");
  const std::string ps = at == std::string::npos ? "" : r.substr(at + 10, 32);
  CHECK(code(r) == 200 && ps.size() == 32 && r.find("; Path=/; Secure; HttpOnly; SameSite=Lax\r\n") != std::string::npos &&
        body(r).find("\"guest-" + gid + "\":{\"name\":\"Bo\"}") != std::string::npos && body(r).find("guest-" + tgid) == std::string::npos,
        "Join redeems (POST): a Secure HttpOnly cookie, and the guest's own topic");
  CHECK(code(pq("POST /api/guest/redeem?g=" + gc, POST)) == 403, "used once: another browser's Join refused");
  const std::string ck = "Cookie: ss_pguest=" + ps + "\r\n";
  r = pq("POST /api/guest/redeem?g=" + gc, POST + ck);
  CHECK(code(r) == 200 && r.find("Set-Cookie") == std::string::npos && code(pq("GET /guest.html", ck)) == 200, "the guest themselves: Join again just says the topic; the page");
  // the tailnet guest's session, the studio's token and cookie: nothing on the public port
  r = tq("GET /guest.html?g=" + tc);
  const std::string ts = r.find("ss_guest=") == std::string::npos ? "" : r.substr(r.find("ss_guest=") + 9, 32);
  CHECK(code(r) == 303 && ts.size() == 32, "(the tailnet guest redeemed on the tailnet port)");
  CHECK(code(pq("GET /api/guest/events?t=" + tok, "Cookie: ss_guest=" + ts + "; ss_pguest=" + ts + "; ss_webui=" + tok + "\r\n")) == 403,
        "public: a tailnet guest's cookie (by either name), the studio token and ss_webui open no guest's API");
  CHECK(code(tq("GET /api/guest/events", "Cookie: ss_pguest=" + ps + "; ss_guest=" + ps + "\r\n")) == 403, "tailnet: a public guest's cookie (by either name) opens nothing");
  const char *studio[] = { "/", "/index.html", "/api/state", "/api/events", "/api/time", "/api/file?id=1", "/api/mix", "/app.js", "/record.html" };
  bool none = true;
  for (const char *p : studio) {
    const std::string a = pq(std::string("GET ") + p + (strchr(p, '?') ? "&" : "?") + "t=" + tok, "Cookie: ss_pguest=" + ps + "; ss_webui=" + tok + "\r\n");
    if (code(a) != 404 || a.find("STUDIO") != std::string::npos || a.find("band talk") != std::string::npos) { printf("     answered %s: %d\n", p, code(a)); none = false; }
  }
  CHECK(none && code(pq("POST /api/action", ck + "X-StudioSync: 1\r\nContent-Length: 2\r\n")) == 404 && code(pq("POST /api/upload", ck + "X-StudioSync: 1\r\nContent-Length: 2\r\n")) == 404,
        "public: every studio path not found, with a valid guest cookie, the token and ss_webui all given");
  // their action, wrapped; their upload, the body bytes that came with the head kept
  while (*webui_poll()) {}
  r = ask(pubp, "POST /api/guest/action HTTP/1.1\r\n" + F + ck + "X-StudioSync: 1\r\nContent-Length: 15\r\n\r\n{\"leave\":false}");
  CHECK(code(r) == 202 && std::string(webui_poll()) == "{\"topic\":\"guestweb\",\"gid\":\"" + gid + "\",\"a\":{\"leave\":false}}" && webui_poll_here() == 0,
        "public: their action reaches Lua wrapped as theirs");
  while (*webui_poll()) {}
  std::string take(100000, '\0');
  for (size_t i = 0; i < take.size(); ++i) take[i] = (char)(i * 7 + i / 300);
  r = ask(pubp, "POST /api/guest/upload HTTP/1.1\r\n" + F + ck + "X-StudioSync: 1\r\nContent-Length: " + std::to_string(take.size()) + "\r\n\r\n" + take);
  const size_t ia = body(r).find("\"id\":\"");
  const std::string up = ia == std::string::npos ? "" : body(r).substr(ia + 6, 32);
  const std::string saved = dir + "/public take.bin";
  CHECK(code(r) == 200 && up.compare(0, 16, gid) == 0 && webui_save_upload(up.c_str(), saved.c_str()) == (int)take.size(), "public: their upload, an id starting with their gid");
  FILE *f = fopen(saved.c_str(), "rb");
  std::string back(take.size() + 1, '\0');
  const size_t got = f ? fread(&back[0], 1, back.size(), f) : 0;
  if (f) fclose(f);
  CHECK(got == take.size() && back.compare(0, got, take) == 0, "every byte of it, the ones read with the head included");
  // two long-lived connections each, no third
  const tsock ev = open_raw(pubp, "GET /api/guest/events HTTP/1.1\r\n" + F + ck + "\r\n");
  const std::string evh = head_of(ev);
  const tsock ws = open_raw(pubp, "GET /api/guest/live HTTP/1.1\r\n" + F + ck + "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n");
  const std::string wsh = head_of(ws);
  CHECK(code(evh) == 200 && evh.find("text/event-stream") != std::string::npos && code(wsh) == 101 && wsh.find("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != std::string::npos,
        "public: their event stream and live socket open");
  char b[4096];
  std::string evd;
  for (int i = 0; i < 20 && evd.find("\"name\":\"Bo\"") == std::string::npos; ++i) { const int k = (int)recv(ev, b, sizeof b, 0); if (k <= 0) break; evd.append(b, (size_t)k); }
  CHECK(evd.find("\"guest-" + gid + "\"") != std::string::npos && evd.find("band talk") == std::string::npos, "the stream: their topic only");
  CHECK(code(pq("GET /api/guest/events", ck)) == 429, "a third long-lived connection for the guest: refused");
  // Public links off: their stream and socket closed at once, the guest ended, the tailnet guest kept
  const double t0 = now_s();
  std::thread off([&] { audience_start(pages.c_str(), 30, 96, 0); }); // (the call itself waits out the accept loop's poll: the closing is what's timed)
  const double ce = closed_in(ev, 2) >= 0 ? now_s() - t0 : -1;
  std::string cd;
  int op = 0;
  while ((op = ws_read(ws, cd)) >= 0 && op != 8) {}
  const double cw = now_s() - t0;
  off.join();
  printf("     public port off: stream closed after %.3f s, socket after %.3f s\n", ce, cw);
  // (0.5 s: pub_close waits 150 ms on purpose so the 1008 reaches the page first; a macOS CI runner measured 0.299 s. What matters is
  //  "at once, and told why", the next CHECK)
  CHECK(ce >= 0 && ce < 0.5 && cw < 0.5, "the public port off: their stream and socket closed within 0.5 s");
  CHECK(op == 8 && cd == "\x03\xf0", "the socket told why first (1008: the page says the session ended, not reconnecting)");
  const std::string st = webui_status();
  CHECK(st.find(gid) == std::string::npos && st.find(tgid) != std::string::npos, "the public guest ended in the extension; the tailnet guest kept");
  closesocket(ev); closesocket(ws);
  audience_start(pages.c_str(), 30, 96, pubp);
  CHECK(code(pq("GET /guest.html", ck)) == 403, "on again: the old public cookie opens nothing");
  webui_guest_set(tgid.c_str(), "", 0, 0);
}

int main()
{
#ifdef _WIN32
  WSADATA w; WSAStartup(MAKEWORD(2, 2), &w);
  const char *tmp = getenv("TEMP");
#else
  const char *tmp = "/tmp";
#endif
  pure_tests();
  const std::string dir = std::string(tmp ? tmp : ".") + "/ss_audience_test", pages = dir + "/pages";
  mkdir_(dir.c_str()); mkdir_(pages.c_str());
  spit(pages + "/listen.html", "<!doctype html><title>LISTEN PAGE</title>");
  spit(pages + "/listen.js", "/*js*/");
  spit(pages + "/listen.css", "/*css*/");
  spit(pages + "/index.html", "<!doctype html><title>STUDIO PAGE</title>");
  spit(pages + "/guest.html", "GUEST");
  spit(pages + "/guest.js", "/*guest js*/");
  std::string mix(5000, '\0');
  for (size_t i = 0; i < mix.size(); ++i) mix[i] = (char)('a' + i % 26);
  spit(dir + "/song mix.wav", mix);
  spit(dir + "/notes.txt", "secret notes");

  const int web = 47393, pubp = 47394;
  CHECK(webui_start(pages.c_str(), "web-test-secret-0123456789", web, "127.0.0.1") == 1, "the web UI listens (the tailnet way in)");
  webui_publish("chat", "{\"secret\":\"band talk\"}");
  CHECK(audience_start(pages.c_str(), 30, 96, pubp) == 1, "the audience starts, with its public port");
  const std::string tc = "0123456789abcdef0123456789abcdef", pc = "fedcba9876543210fedcba9876543210ff";
  CHECK(audience_link("aaaaaaaaaaaaaaaa", tc.c_str(), 3600, 0) == 1 && audience_link("bbbbbbbbbbbbbbbb", pc.c_str(), 3600, 1) == 1, "two links: tailnet, public");
  CHECK(audience_link("AAAA", tc.c_str(), 60, 0) == 0 && audience_link("cccccccccccccccc", "short", 60, 0) == 0 && audience_link("cccccccccccccccc", tc.c_str(), 0, 0) == 0,
        "a bad id, code or time: refused");
  CHECK(audience_info("{\"song\":\"Bee\",\"live\":true,\"who\":[\"James\",\"Chilio\"]}", "{\"song\":\"Bee\",\"live\":true}", (dir + "/song mix.wav").c_str()) == 1 &&
        audience_info("not json", "{}", "") == 0, "what listeners are told");

  // ---- the public port: the listening page and nothing else ----
  std::string r = get(pubp, "/listen/?l=" + pc);
  CHECK(code(r) == 200 && body(r).find("LISTEN PAGE") != std::string::npos && r.find("Content-Security-Policy") != std::string::npos &&
        r.find("Referrer-Policy: no-referrer") != std::string::npos, "public: the page with a public link, with the safety headers");
  CHECK(code(get(pubp, "/listen/listen.js")) == 200 && code(get(pubp, "/listen/listen.css")) == 200, "public: its script and style");
  CHECK(code(get(pubp, "/listen/?l=" + tc)) == 403, "public: a tailnet-only link refused");
  const std::string tok = webui_token("web-test-secret-0123456789");
  const char *refuse[] = { "/", "/index.html", "/api/state", "/api/events", "/api/mix", "/api/time", "/api/file?id=1", "/record.html", "/app.js",
                           "/notes.txt", "/listen/../index.html", "/listen/listen.html" }; // (the guest page's paths: public guests', below)
  bool none = true;
  for (const char *p : refuse) {
    const std::string a = get(pubp, std::string(p) + (strchr(p, '?') ? "&" : "?") + "l=" + pc + "&t=" + tok);
    if (code(a) != 404 || a.find("STUDIO") != std::string::npos || a.find("band talk") != std::string::npos) { printf("     answered %s: %d\n", p, code(a)); none = false; }
  }
  CHECK(none, "public: everything else not found, with a public code and the studio token both given");
  CHECK(code(get(pubp, "/api/action", "X-StudioSync: 1\r\nContent-Length: 2\r\n", "POST")) == 404 && code(get(pubp, "/listen/?l=" + pc, "", "HEAD")) == 404 &&
        code(get(pubp, "/api/upload", "X-StudioSync: 1\r\nContent-Length: 2\r\n", "POST")) == 404, "public: no POST but a guest's, no HEAD");
  r = get(pubp, "/listen/mix?l=" + pc, "Range: bytes=10-19\r\n");
  CHECK(code(r) == 206 && body(r) == mix.substr(10, 10) && r.find("audio/wav") != std::string::npos && r.find("Content-Range: bytes 10-19/5000") != std::string::npos,
        "public: the latest mix, a byte range of it");
  CHECK(code(get(pubp, "/listen/mix?l=" + pc)) == 200 && code(get(pubp, "/listen/mix?l=" + pc, "Range: bytes=9000-\r\n")) == 416, "the whole mix; a range past it");
  audience_info("{\"song\":\"Bee\"}", "{\"song\":\"Bee\"}", (dir + "/notes.txt").c_str());
  CHECK(code(get(pubp, "/listen/mix?l=" + pc)) == 404, "a 'mix' that isn't audio isn't served");
  audience_info("{\"song\":\"Bee\",\"live\":true,\"who\":[\"James\",\"Chilio\"]}", "{\"song\":\"Bee\",\"live\":true}", (dir + "/song mix.wav").c_str());

  public_guest_tests(web, pubp, pages, dir);

  // ---- the tailnet way in (the web UI server, as `tailscale serve` hands it over) ----
  r = ask(web, "GET /listen/?l=" + tc + " HTTP/1.1\r\nHost: pc.tail.ts.net:8443\r\nX-Forwarded-Host: pc.tail.ts.net:8443\r\nX-Forwarded-For: 100.64.0.9\r\n\r\n");
  CHECK(code(r) == 200 && body(r).find("LISTEN PAGE") != std::string::npos, "tailnet: the page with the link, no studio token needed");
  r = ask(web, "GET /listen/ HTTP/1.1\r\nHost: pc.tail.ts.net:8443\r\nX-Forwarded-For: 100.64.0.9\r\nCookie: ss_webui=" + tok + "\r\n\r\n");
  CHECK(code(r) == 403, "tailnet: the studio's token doesn't stand in for a listening link");
  r = ask(web, "GET /index.html?l=" + tc + " HTTP/1.1\r\nHost: pc.tail.ts.net:8443\r\nX-Forwarded-For: 100.64.0.9\r\n\r\n");
  CHECK(code(r) == 403, "tailnet: a listening link opens nothing of the web UI's");

  // ---- live: one encode, every listener the same packets ----
  g_play = true;
  std::thread audio(audio_thread);
  int st;
  tsock pl = ws_open(pubp, "/listen/live?l=" + pc, st);
  CHECK(pl != (tsock)-1, "public: the live socket opens");
  std::string d;
  int op = ws_read(pl, d);
  CHECK(op == 1 && d == "{\"song\":\"Bee\",\"live\":true}", "public: told the song and live, nobody's name");
  tsock tl = ws_open(web, "/listen/live?l=" + tc, st);
  op = ws_read(tl, d);
  CHECK(tl != (tsock)-1 && op == 1 && d.find("Chilio") != std::string::npos, "tailnet: told who's playing too");
  CHECK(webui_mix_wanted() >= 2, "the audio hook is wanted while anyone listens");
  OpusDecoder *dec = opus_decoder_create(48000, 2, nullptr);
  std::vector<float> pcm, f(5760 * 2);
  unsigned first = 0, last = 0;
  int packets = 0, gaps = 0;
  const double t0 = now_s();
  while (now_s() - t0 < 2.5) {
    if ((op = ws_read(pl, d)) != 2) { if (op < 0) break; continue; }
    unsigned seq;
    memcpy(&seq, d.data(), 4);
    if (packets == 0) first = seq; else if (seq != last + 1) ++gaps;
    last = seq;
    ++packets;
    const int n = opus_decode_float(dec, (const unsigned char *)d.data() + 4, (int)d.size() - 4, f.data(), 5760, 0);
    if (n > 0) pcm.insert(pcm.end(), f.begin(), f.begin() + n * 2);
  }
  printf("     %d packets in 2.5 s, seq %u..%u, %d gaps, %zu frames decoded\n", packets, first, last, gaps, pcm.size() / 2);
  CHECK(packets >= 100 && gaps == 0, "public: ~50 Opus packets a second, none missing");
  std::vector<float> tail(pcm.begin() + std::min(pcm.size(), (size_t)48000 * 2 / 2), pcm.end()); // (past the encoder's start)
  const double fl = freq(tail, 0, 48000), fr = freq(tail, 1, 48000);
  float pk = 0;
  for (size_t i = 0; i < tail.size(); i += 2) pk = std::max(pk, std::fabs(tail[i]));
  printf("     decoded: left %.1f Hz, right %.1f Hz, peak %.3f\n", fl, fr, pk);
  CHECK(std::fabs(fl - 440) < 3 && std::fabs(fr - 660) < 3 && pk > 0.4f && pk < 0.6f, "the session mix decodes back: 440 Hz left, 660 Hz right, at 0.5 (44.1 kHz in)");
  opus_decoder_destroy(dec);

  // many listeners: the tailnet way, all at once
  std::vector<tsock> many;
  for (int i = 0; i < 27; ++i) { tsock s = ws_open(web, "/listen/live?l=" + tc, st); if (s != (tsock)-1) many.push_back(s); }
  CHECK(many.size() == 27, "27 more listeners (30 with the two and one to come): all in");
  int full_st = 0;
  tsock one_more = ws_open(pubp, "/listen/live?l=" + pc, st);
  tsock over = ws_open(web, "/listen/live?l=" + tc, full_st);
  CHECK(one_more != (tsock)-1 && over == (tsock)-1 && full_st == 503, "the cap: the 31st is told it's full (503)");
  sleep_ms(2500);
  std::string stt = audience_status();
  printf("     status with 30: %s\n", stt.c_str());
  CHECK(stt.find("\"listeners\":30") != std::string::npos && stt.find("\"public\":2") != std::string::npos, "the status counts them, and the public ones");
  // the same packet reaches everyone
  bool alike = true;
  std::vector<unsigned> seqs;
  for (tsock s : many) {
    unsigned seq = 0;
    for (int i = 0; i < 200 && (op = ws_read(s, d)) >= 0; ++i) if (op == 2) { memcpy(&seq, d.data(), 4); break; }
    seqs.push_back(seq);
    if (op != 2) alike = false;
  }
  unsigned lo = *std::min_element(seqs.begin(), seqs.end()), hi = *std::max_element(seqs.begin(), seqs.end());
  CHECK(alike && hi - lo < 200, "every listener is getting the one stream (sequence numbers from one encoder)");

  // revoke the tailnet link: its listeners closed, the public ones stay
  CHECK(audience_link("aaaaaaaaaaaaaaaa", "", 0, 0) == 1, "revoke the tailnet link");
  int closed = 0;
  for (tsock s : many) closed += until_closed(s, 10);
  CHECK(closed == (int)many.size(), "its listeners are closed (1008)");
  for (tsock s : many) closesocket(s);
  closesocket(tl);
  sleep_ms(400);
  stt = audience_status();
  CHECK(stt.find("\"listeners\":2") != std::string::npos, "and gone from the count; the public two still listen");
  CHECK(code(ask(web, "GET /listen/?l=" + tc + " HTTP/1.1\r\nHost: x\r\n\r\n")) == 403, "the revoked link's page: refused");

  // a run-out link
  const std::string sc = "abcdefabcdefabcdefabcdefabcdef01";
  audience_link("dddddddddddddddd", sc.c_str(), 1, 0);
  tsock shortl = ws_open(web, "/listen/live?l=" + sc, st);
  const double ts = now_s();
  bool ended = false;
  while (now_s() - ts < 3) { op = ws_read(shortl, d); if (op == 8 || op < 0) { ended = true; break; } }
  CHECK(shortl != (tsock)-1 && ended && now_s() - ts < 2, "a link run out: its listener closed within a second or so");
  closesocket(shortl);

  // a listener that never reads: skipped, then closed (at 256 kbps with a small receive buffer, to be quick)
  audience_start(pages.c_str(), 30, 256, pubp);
  tsock slow = ws_open(pubp, "/listen/live?l=" + pc, st, 2048);
  const double tsl = now_s();
  std::string s1;
  bool slow_gone = false;
  while (now_s() - tsl < 40) { sleep_ms(500); s1 = audience_status(); if (s1.find("\"slow_closed\":1") != std::string::npos) { slow_gone = true; break; } }
  printf("     slow listener: %s after %.1f s\n", slow_gone ? "closed" : "still there", now_s() - tsl);
  CHECK(slow != (tsock)-1 && slow_gone && s1.find("\"skipped\":0,") == std::string::npos, "a listener that takes nothing: its packets skipped, then closed");
  closesocket(slow);
  audience_start(pages.c_str(), 30, 96, pubp);

  // the public port closed: its listeners go, it answers nothing
  CHECK(audience_start(pages.c_str(), 30, 96, 0) == 1, "the public port turned off");
  CHECK(until_closed(pl, 15), "its listeners closed");
  CHECK(ask(pubp, "GET /listen/listen.js HTTP/1.1\r\nHost: x\r\n\r\n").empty(), "nothing listens there now");
  closesocket(pl);
  closesocket(one_more);

  // the cost of 100 listeners (one encode; a send each)
  audience_start(pages.c_str(), 100, 96, pubp);
  audience_link("eeeeeeeeeeeeeeee", tc.c_str(), 3600, 0);
  std::vector<tsock> hundred;
  for (int i = 0; i < 100; ++i) { tsock s = ws_open(web, "/listen/live?l=" + tc, st); if (s != (tsock)-1) hundred.push_back(s); else sleep_ms(50); }
  std::atomic<bool> drain{ true };
  std::thread drainer([&] { char b[65536]; while (drain) { for (tsock s : hundred) {
#ifdef _WIN32
    u_long n = 0;
    ioctlsocket(s, FIONREAD, &n);
    if (n) recv(s, b, (int)std::min<u_long>(n, sizeof b), 0);
#else
    recv(s, b, sizeof b, MSG_DONTWAIT);
#endif
    } sleep_ms(5); } });
  sleep_ms(4500);
  stt = audience_status();
  printf("     with %zu listeners: %s\n", hundred.size(), stt.c_str());
  CHECK(hundred.size() == 100 && stt.find("\"listeners\":100") != std::string::npos, "100 listeners at the most cap");
  const char *el = strstr(stt.c_str(), "\"enc_load\":");
  const char *ok = strstr(stt.c_str(), "\"out_kbps\":");
  const double load = el ? atof(el + 11) : 1, outk = ok ? atof(ok + 11) : 0;
  printf("     encoder: %.2f%% of a core; out: %.0f kbit/s (%.1f each)\n", load * 100, outk, outk / 100);
  CHECK(load < 0.05 && outk > 100 * 60 && outk < 100 * 160, "one encode for all: under 5% of a core; ~96-110 kbit/s each out");
  drain = false;
  drainer.join();
  for (tsock s : hundred) closesocket(s);

  // a crowd joining at the same instant: every socket connected first, each held by a request thread, then all ask at once (the web UI has
  // 16 threads of its own, the public port had 8: 22 at once on the real desktop got 14 in)
  sleep_ms(600);
  for (int way = 0; way < 2; ++way) {
    std::vector<tsock> crowd;
    for (int i = 0; i < 40; ++i) crowd.push_back(dial(way ? pubp : web));
    sleep_ms(300);
    const std::string req = "GET /listen/live?l=" + (way ? pc : tc) + " HTTP/1.1\r\nHost: pc.tail.ts.net\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                            "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
    for (tsock s : crowd) if (s != (tsock)-1) send(s, req.data(), (int)req.size(), 0);
    int in = 0;
    for (tsock s : crowd) {
      std::string h;
      char c;
      while (s != (tsock)-1 && h.find("\r\n\r\n") == std::string::npos && recv(s, &c, 1, 0) == 1) h += c;
      in += code(h) == 101;
    }
    printf("     %s: %d of 40 in\n", way ? "public" : "tailnet", in);
    CHECK(in == 40, way ? "public: 40 joining at the same instant all get in" : "tailnet: 40 joining at the same instant all get in (past the web UI's 16 threads)");
    for (tsock s : crowd) if (s != (tsock)-1) closesocket(s);
    sleep_ms(600);
  }
  CHECK(code(ask(web, "GET /listen/?l=" + tc + " HTTP/1.1\r\nHost: x\r\n\r\n")) == 200, "and the page still answers after");

  // rate limits: wrong codes lock that way in for a minute, the other way unaffected; a flood of requests is refused past the burst
  audience_start(pages.c_str(), 30, 96, pubp);
  int c403 = 0, c429 = 0;
  for (int i = 0; i < 25; ++i) { const int c = code(get(pubp, "/listen/?l=" + std::string(32, '0' + (i % 10)))); c403 += c == 403; c429 += c == 429; }
  printf("     wrong codes: %d refused, %d locked out\n", c403, c429);
  CHECK(c403 >= 15 && c403 <= 21 && c403 + c429 == 25, "public: 20 wrong codes a minute, then the 21st locks it (every request after: 429; the public guests' few earlier wrong codes count too)");
  CHECK(code(get(pubp, "/listen/?l=" + pc)) == 429, "locked: even the right code waits the minute out");
  webui_guest_set("5555666677778888", "abcabcabcabcabcabcabcabc", 60, 3600);
  webui_guest_public("5555666677778888", 1);
  CHECK(code(get(pubp, "/guest.html?g=abcabcabcabcabcabcabcabc")) == 429, "public guests share the lock: a right guest code waits it out too");
  webui_guest_set("5555666677778888", "", 0, 0);
  CHECK(code(ask(web, "GET /listen/?l=" + tc + " HTTP/1.1\r\nHost: x\r\n\r\n")) == 200, "the tailnet way in isn't locked by the public one");
  int flood429 = 0;
  for (int i = 0; i < 260; ++i) flood429 += code(ask(web, "GET /listen/listen.js HTTP/1.1\r\nHost: x\r\n\r\n")) == 429;
  printf("     flood: %d of 260 refused\n", flood429);
  CHECK(flood429 > 0, "a flood past the burst: refused (429)");

  g_play = false;
  audio.join();
  audience_shutdown();
  webui_shutdown();
  printf(fails ? "\n%d FAILED\n" : "\nall ok\n", fails);
  return fails ? 1 : 0;
}
