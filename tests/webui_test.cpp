// The web UI server (extension/webui.cpp) without REAPER: request parsing, the path rule, the token and who gets in; then live, the
// loopback listener and the direct link's port handing HTTP over (token, cookie, X-StudioSync on POST), state, the event stream and actions.
// Build and run: tests\build_webui_test.cmd (macOS/Linux: the line in it). GPL-3.0-or-later.
#ifdef _WIN32
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <direct.h>
#define mkdir_(p) _mkdir(p)
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#define closesocket close
#define mkdir_(p) mkdir(p, 0755)
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
#include "../extension/direct.h"
#include "../extension/webui.h"

static int fails = 0;
#define CHECK(c, what) do { if (c) printf("ok   %s\n", what); else { printf("FAIL %s\n", what); ++fails; } } while (0)

static int dial(int port)
{
  int s = (int)socket(AF_INET, SOCK_STREAM, 0);
  sockaddr_in a = {}; a.sin_family = AF_INET; a.sin_port = htons((unsigned short)port); inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
  if (connect(s, (sockaddr *)&a, sizeof a) != 0) { closesocket(s); return -1; }
#ifdef _WIN32
  DWORD t = 3000; setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&t, sizeof t);
#else
  timeval tv = { 3, 0 }; setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
#endif
  return s;
}
// One request -> the whole answer (the server closes after it). "" when it couldn't connect.
static std::string ask(int port, const std::string &req)
{
  const int s = dial(port);
  if (s < 0) return "";
  send(s, req.data(), (int)req.size(), 0);
  std::string out;
  char b[4096];
  int k;
  while ((k = recv(s, b, sizeof b, 0)) > 0) out.append(b, (size_t)k);
  closesocket(s);
  return out;
}
static std::string get(int port, const std::string &path, const std::string &host, const std::string &extra = "")
{
  return ask(port, "GET " + path + " HTTP/1.1\r\nHost: " + host + "\r\n" + extra + "\r\n");
}
static int code(const std::string &resp) { return resp.size() > 12 ? atoi(resp.c_str() + 9) : -1; }
static std::string body(const std::string &resp) { const size_t e = resp.find("\r\n\r\n"); return e == std::string::npos ? "" : resp.substr(e + 4); }
static void spit(const std::string &p, const std::string &s) { FILE *f = fopen(p.c_str(), "wb"); fwrite(s.data(), 1, s.size(), f); fclose(f); }
static void sleep_ms(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

static void pure_tests()
{
  WebReq r;
  CHECK(webui_parse_head("GET /app.js?x=1&t=abc HTTP/1.1\r\nHost: 127.0.0.1:47281\r\nCookie:  a=b; ss_webui=zz \r\n\r\n", r) && r.method == "GET" &&
        r.path == "/app.js" && r.query == "x=1&t=abc" && r.headers["host"] == "127.0.0.1:47281" && r.headers["cookie"] == "a=b; ss_webui=zz",
        "a request line and headers (names lower-cased, values trimmed)");
  CHECK(!webui_parse_head("GET / HTTP/2\r\n\r\n", r) && !webui_parse_head("GET  / HTTP/1.1\r\n\r\n", r) && !webui_parse_head("GET x HTTP/1.1\r\n\r\n", r) &&
        !webui_parse_head("get / HTTP/1.1\r\n\r\n", r) && !webui_parse_head("GET / HTTP/1.1\r\nno colon\r\n\r\n", r) &&
        !webui_parse_head("GET /a\x01 HTTP/1.1\r\n\r\n", r) && !webui_parse_head("GET / HTTP/1.1", r), "malformed requests refused");
  std::string rel, ct;
  CHECK(webui_file_for("/", rel, ct) && rel == "index.html" && ct.find("text/html") == 0, "/ is index.html");
  CHECK(webui_file_for("/app.js", rel, ct) && rel == "app.js" && ct.find("javascript") != std::string::npos &&
        webui_file_for("/img/icon.svg", rel, ct) && rel == "img/icon.svg", "files and subfolders, typed");
  const char *bad[] = { "/../secret.txt", "/a/../b.js", "/.git/config", "/a//b.js", "/img/", "/x.exe", "/noext", "/a%2e%2e/b.js", "/a\\b.js",
                        "/con.html", "/CON", "/aux.js", "/lpt1.txt", "/a/nul.css", "/C:/x.js", "" };
  bool all = true;
  for (const char *p : bad) if (webui_file_for(p, rel, ct)) { printf("     let through: %s\n", p); all = false; }
  CHECK(all, "outside the folder, hidden files, device names, unknown types: refused");
  const std::string tok = webui_token("s3cret");
  CHECK(tok.size() == 32 && tok.find_first_not_of("0123456789abcdef") == std::string::npos && tok == webui_token("s3cret") &&
        tok != webui_token("s3cret2") && webui_token("").empty(), "the token: 32 hex, from the secret alone, none without one");
  CHECK(webui_param("a=1&t=xyz&tt=2", "t") == "xyz" && webui_param("tt=2", "t") == "" && webui_param("", "t") == "", "query parameters");
  CHECK(webui_cookie("a=b; ss_webui=zz", "ss_webui") == "zz" && webui_cookie("xss_webui=zz", "ss_webui") == "", "cookies");

  auto req = [](const char *head) { WebReq w; webui_parse_head(head, w); return w; };
  bool sc = false;
  const int P = 47281;
  CHECK(webui_auth(req("GET / HTTP/1.1\r\nHost: 127.0.0.1:47281\r\n\r\n"), true, tok, P, sc) == 0 && !sc &&
        webui_auth(req("GET / HTTP/1.1\r\nHost: localhost:47281\r\n\r\n"), true, "", P, sc) == 0, "this computer: in without a token");
  CHECK(webui_auth(req("GET / HTTP/1.1\r\nHost: evil.example:47281\r\n\r\n"), true, tok, P, sc) == 403 &&
        webui_auth(req("GET / HTTP/1.1\r\nHost: 127.0.0.1:9\r\n\r\n"), true, tok, P, sc) == 403 &&
        webui_auth(req("GET / HTTP/1.1\r\n\r\n"), true, tok, P, sc) == 403, "this computer, but another name for it (DNS rebinding): no");
  CHECK(webui_auth(req("POST /api/action HTTP/1.1\r\nHost: 127.0.0.1:47281\r\n\r\n"), true, tok, P, sc) == 403 &&
        webui_auth(req("POST /api/action HTTP/1.1\r\nHost: 127.0.0.1:47281\r\nX-StudioSync: 1\r\n\r\n"), true, tok, P, sc) == 0,
        "a POST needs X-StudioSync (a form elsewhere can't send it)");
  CHECK(webui_auth(req("POST /api/action HTTP/1.1\r\nHost: 127.0.0.1:47281\r\nX-StudioSync: 1\r\nOrigin: http://evil.example\r\n\r\n"), true, tok, P, sc) == 403 &&
        webui_auth(req("POST /api/action HTTP/1.1\r\nHost: 127.0.0.1:47281\r\nX-StudioSync: 1\r\nOrigin: http://127.0.0.1:47281\r\n\r\n"), true, tok, P, sc) == 0,
        "another site's Origin: no; our own: yes");
  CHECK(webui_auth(req("GET / HTTP/1.1\r\nHost: pc.ts.net:47281\r\n\r\n"), false, tok, P, sc) == 403, "from the tailnet without a token: no");
  CHECK(webui_auth(req(("GET /?t=" + tok + " HTTP/1.1\r\nHost: pc.ts.net:47281\r\n\r\n").c_str()), false, tok, P, sc) == 0 && sc,
        "the token as ?t=: in, and a cookie set");
  CHECK(webui_auth(req("GET /?t=00000000000000000000000000000000 HTTP/1.1\r\nHost: pc.ts.net:47281\r\n\r\n"), false, tok, P, sc) == 403 &&
        webui_auth(req("GET /?t=0 HTTP/1.1\r\nHost: pc.ts.net:47281\r\n\r\n"), false, tok, P, sc) == 403, "a wrong token: no");
  CHECK(webui_auth(req(("GET /api/state HTTP/1.1\r\nHost: pc.ts.net:47281\r\nCookie: ss_webui=" + tok + "\r\n\r\n").c_str()), false, tok, P, sc) == 0 && !sc,
        "the cookie: in");
  CHECK(webui_auth(req(("GET / HTTP/1.1\r\nHost: pc.ts.net:47281\r\nCookie: ss_webui=" + tok + "\r\n\r\n").c_str()), false, "", P, sc) == 403,
        "a studio with no secret: nobody from outside");
  // `tailscale serve` on this computer (the https address a phone's microphone needs): loopback, but from the tailnet, so the token's rules
  const char *fw = "Host: pc.ts.net:8443\r\nX-Forwarded-Host: pc.ts.net:8443\r\nX-Forwarded-Proto: https\r\nX-Forwarded-For: 100.64.0.9\r\n";
  CHECK(webui_auth(req((std::string("GET / HTTP/1.1\r\n") + fw + "\r\n").c_str()), true, tok, P, sc) == 403 &&
        webui_auth(req("GET / HTTP/1.1\r\nHost: 127.0.0.1:47281\r\nX-Forwarded-For: 100.64.0.9\r\n\r\n"), true, tok, P, sc) == 403,
        "through the proxy without a token: no (even naming 127.0.0.1)");
  CHECK(webui_auth(req(("GET /record.html?t=" + tok + " HTTP/1.1\r\n" + fw + "\r\n").c_str()), true, tok, P, sc) == 0 && sc,
        "through the proxy with the token: in");
  CHECK(webui_auth(req(("POST /api/upload HTTP/1.1\r\n" + std::string(fw) + "X-StudioSync: 1\r\nOrigin: https://pc.ts.net:8443\r\nCookie: ss_webui=" + tok + "\r\n\r\n").c_str()), true, tok, P, sc) == 0 &&
        webui_auth(req(("POST /api/upload HTTP/1.1\r\nHost: 127.0.0.1:47281\r\nX-Forwarded-Host: pc.ts.net:8443\r\nX-StudioSync: 1\r\nOrigin: https://pc.ts.net:8443\r\nCookie: ss_webui=" + tok + "\r\n\r\n").c_str()), true, tok, P, sc) == 0,
        "its https:// Origin: yes (Host kept, or rewritten with X-Forwarded-Host)");
  CHECK(webui_auth(req(("POST /api/upload HTTP/1.1\r\n" + std::string(fw) + "X-StudioSync: 1\r\nOrigin: https://evil.example\r\nCookie: ss_webui=" + tok + "\r\n\r\n").c_str()), true, tok, P, sc) == 403,
        "another site's https:// Origin: no");
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

  const std::string dir = std::string(tmp ? tmp : ".") + "/ss_webui_test", pages = dir + "/pages", inbox = dir + "/inbox";
  mkdir_(dir.c_str()); mkdir_(pages.c_str()); mkdir_(inbox.c_str());
  spit(pages + "/index.html", "<!doctype html><title>t</title>");
  spit(pages + "/app.js", "console.log(1)");
  spit(dir + "/secret.txt", "not for the web");
  const char *studio = "studiosync-webtest", *secret = "web-test-secret-0123456789";
  const int link = 47391, web = 47392;
  const std::string tok = webui_token(secret), lh = "127.0.0.1:" + std::to_string(web), th = "pc.tail.ts.net:" + std::to_string(link);
  CHECK(direct_start(studio, secret, inbox.c_str(), link, "127.0.0.1") == 1, "the direct link listens (127.0.0.1, as its own test)");
  CHECK(webui_start(pages.c_str(), secret, web, "127.0.0.1") == 1, "the web UI listens on loopback");
  CHECK(webui_start(pages.c_str(), secret, web, "127.0.0.1") == 1, "starting again changes nothing");

  std::string r = get(web, "/", lh);
  CHECK(code(r) == 200 && body(r) == "<!doctype html><title>t</title>" && r.find("Content-Security-Policy") != std::string::npos &&
        r.find("Referrer-Policy: no-referrer") != std::string::npos, "this computer: the page, with the safety headers");
  CHECK(code(get(web, "/app.js", lh)) == 200, "and its script");
  CHECK(code(get(web, "/", "evil.example")) == 403, "another name for this computer: refused");
  r = get(web, "/../secret.txt", lh);
  CHECK(code(r) == 404 && r.find("not for the web") == std::string::npos, "nothing outside the pages' folder");
  CHECK(code(get(web, "/missing.html", lh)) == 404, "a page that isn't there: 404");
  CHECK(code(ask(web, "garbage\r\n\r\n")) == 400, "not HTTP: 400");

  // through the direct link's port, as a phone on Tailscale would come
  CHECK(code(get(link, "/", th)) == 403, "the link's port, no token: refused");
  r = get(link, "/?t=" + tok, th);
  CHECK(code(r) == 303 && r.find("Location: /\r\n") != std::string::npos && r.find("Set-Cookie: ss_webui=" + tok + ";") != std::string::npos &&
        r.find("HttpOnly") != std::string::npos && r.find("SameSite=Lax") != std::string::npos, "the token: a cookie, and the address without it");
  const std::string ck = "Cookie: ss_webui=" + tok + "\r\n";
  r = get(link, "/", th, ck);
  CHECK(code(r) == 200 && body(r).find("<title>t</title>") != std::string::npos, "the cookie: the page, on the link's port");
  const std::string act = "{\"topic\":\"chat\",\"text\":\"hi from the phone\"}";
  const std::string post = "POST /api/action HTTP/1.1\r\nHost: " + th + "\r\n" + ck + "Content-Type: application/json\r\nContent-Length: " +
                           std::to_string(act.size()) + "\r\n";
  CHECK(code(ask(link, post + "\r\n" + act)) == 403, "a POST without X-StudioSync: refused");
  CHECK(std::string(webui_poll()).empty(), "and nothing queued");
  CHECK(code(ask(link, post + "X-StudioSync: 1\r\n\r\n" + act)) == 202, "with it: accepted");
  CHECK(std::string(webui_poll()) == act && webui_poll_here() == 0, "the engine gets the action, marked not from this computer (lib/ai.lua)");
  CHECK(std::string(webui_poll()).empty() && webui_poll_here() == 0, "once");
  {
    const std::string lp = "POST /api/action HTTP/1.1\r\nHost: " + lh + "\r\nX-StudioSync: 1\r\nContent-Length: " + std::to_string(act.size()) + "\r\n";
    CHECK(code(ask(web, lp + "\r\n" + act)) == 202 && std::string(webui_poll()) == act && webui_poll_here() == 1, "this computer's own page: marked here");
    CHECK(code(ask(web, lp + "X-Forwarded-For: 100.64.0.9\r\n" + ck + "\r\n" + act)) == 202 && std::string(webui_poll()) == act && webui_poll_here() == 0,
          "through a proxy here (tailscale serve): not here");
  }
  CHECK(code(ask(web, "POST /api/action HTTP/1.1\r\nHost: " + lh + "\r\nX-StudioSync: 1\r\nContent-Length: 3\r\n\r\nabc")) == 400, "an action that isn't an object: 400");
  CHECK(code(ask(web, "POST /api/action HTTP/1.1\r\nHost: " + lh + "\r\nX-StudioSync: 1\r\nContent-Length: 99999\r\n\r\n{")) == 413, "too big: 413");
  // the link itself is unharmed: something that is neither HTTP nor a frame still gets the link's "not StudioSync's"
  {
    const int s = dial(link);
    send(s, "XXXXXXXXXXXXXXXX", 16, 0);
    char c = 9;
    const int k = recv(s, &c, 1, 0);
    closesocket(s);
    CHECK(k == 1 && c == 1, "the link's own refusal for anything else");
  }

  // state and the event stream
  webui_publish("presence", "{\"people\":[{\"user\":\"James\"}]}");
  webui_publish("Bad Topic", "{}");
  r = get(web, "/api/state", lh);
  CHECK(code(r) == 200 && body(r).find("\"presence\":{\"people\":[{\"user\":\"James\"}]}") != std::string::npos &&
        body(r).find("Bad Topic") == std::string::npos && body(r).find("\"engine\":true") != std::string::npos, "the state, by topic (a bad name ignored)");
  {
    const int s = dial(web);
    const std::string q = "GET /api/events HTTP/1.1\r\nHost: " + lh + "\r\n\r\n";
    send(s, q.data(), (int)q.size(), 0);
    std::string got;
    char b[4096];
    auto until = [&](const char *what) {
      for (int i = 0; i < 30 && got.find(what) == std::string::npos; ++i) { const int k = recv(s, b, sizeof b, 0); if (k <= 0) break; got.append(b, (size_t)k); }
      return got.find(what) != std::string::npos;
    };
    CHECK(until("\"user\":\"James\"") && got.find("text/event-stream") != std::string::npos, "the stream starts with everything");
    const auto t0 = std::chrono::steady_clock::now();
    webui_publish("chat", "{\"msgs\":[{\"text\":\"new\"}]}");
    CHECK(until("\"text\":\"new\""), "and sends a change as it's published");
    printf("     publish -> on the stream: %.2f ms\n", std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
    // after the first, only what changed: a big topic isn't sent again with every small one (James, rt)
    {
      const size_t at = got.rfind("\"text\":\"new\"");
      const size_t start = got.rfind("data: ", at), end = got.find("\n\n", at);
      const std::string ev = got.substr(start, end - start);
      CHECK(ev.find("\"delta\":true") != std::string::npos && ev.find("\"presence\"") == std::string::npos, "a change sends only its topic, marked delta");
    }
    webui_publish("presence", "{\"people\":[{\"user\":\"Chilio\"}]}");
    CHECK(until("Chilio"), "another topic's change comes too");
    {
      const size_t at = got.rfind("Chilio");
      const size_t start = got.rfind("data: ", at), end = got.find("\n\n", at);
      CHECK(got.substr(start, end - start).find("\"chat\"") == std::string::npos, "without the unchanged chat");
    }
    r = get(web, "/api/state", lh);
    CHECK(body(r).find("\"chat\"") != std::string::npos && body(r).find("Chilio") != std::string::npos && body(r).find("delta") == std::string::npos,
          "the state is still everything");
    closesocket(s);
  }
  r = get(link, "/api/status", th, ck);
  CHECK(code(r) == 404, "an unknown API path: 404");

  // a phone's take (lib/phonerec.lua): the link's clock, then the recording up and saved where Lua says
  r = get(link, "/api/time", th, ck);
  CHECK(code(r) == 200 && fabs(atof(body(r).c_str() + 7) - direct_now()) < 1.0, "/api/time: the link's clock");
  std::string take(300000, '\0');
  for (size_t i = 0; i < take.size(); ++i) take[i] = (char)(i * 7);
  const std::string up = "POST /api/upload HTTP/1.1\r\nHost: " + th + "\r\n" + ck + "X-StudioSync: 1\r\nContent-Length: ";
  CHECK(code(ask(link, up.substr(0, up.find("X-StudioSync")) + "Content-Length: 3\r\n\r\nabc")) == 403, "an upload without X-StudioSync: refused");
  CHECK(code(ask(link, up + "999999999\r\n\r\nx")) == 413, "an upload over the limit: 413");
  r = ask(link, up + std::to_string(take.size()) + "\r\n\r\n" + take);
  const size_t idat = body(r).find("\"id\":\"");
  const std::string id = idat == std::string::npos ? "" : body(r).substr(idat + 6, 16);
  CHECK(code(r) == 200 && id.size() == 16, "an upload: kept, with an id");
  const std::string saved = dir + "/take.wav";
  CHECK(webui_save_upload("nope", saved.c_str()) == 0, "an unknown id: nothing");
  CHECK(webui_save_upload(id.c_str(), (dir + "/no/such/folder/t.wav").c_str()) == -1, "a path that can't be written: -1");
  CHECK(webui_save_upload(id.c_str(), saved.c_str()) == (int)take.size(), "and kept for another try: saved");
  {
    FILE *f = fopen(saved.c_str(), "rb");
    std::string back;
    char b[65536];
    size_t k;
    while (f && (k = fread(b, 1, sizeof b, f)) > 0) back.append(b, k);
    if (f) fclose(f);
    CHECK(back == take, "byte for byte");
  }
  CHECK(webui_save_upload(id.c_str(), saved.c_str()) == 0, "and let go once saved");
  for (int i = 0; i < 3; ++i) ask(link, up + "5\r\n\r\nhello");
  CHECK(std::string(webui_status()).find("listening") != std::string::npos, "three more: the oldest let go, the server fine");
  // a file Lua offers (the phone app's mix to play along to): only by its id, streamed whole
  std::string mix(200000, '\0');
  for (size_t i = 0; i < mix.size(); ++i) mix[i] = (char)(i * 13);
  spit(dir + "/mix.wav", mix);
  CHECK(webui_offer("ab12", (dir + "/mix.wav").c_str()) == 1 && webui_offer("AB12", "x") == 0 && webui_offer("../x", "x") == 0 && webui_offer("", "x") == 0,
        "an offer: hex ids only");
  r = get(link, "/api/file?id=ab12", th, ck);
  CHECK(code(r) == 200 && body(r) == mix && r.find("Content-Length: 200000") != std::string::npos, "an offered file, byte for byte");
  CHECK(r.find("Accept-Ranges: bytes") != std::string::npos && r.find("Content-Type: application/octet-stream") != std::string::npos, "says it takes ranges; a WAV as bytes");
  // (rt-video2: the Project page's <video> asks for byte ranges as it seeks)
  r = get(link, "/api/file?id=ab12", th, ck + "Range: bytes=1000-1999\r\n");
  CHECK(code(r) == 206 && body(r) == mix.substr(1000, 1000) && r.find("Content-Range: bytes 1000-1999/200000") != std::string::npos &&
        r.find("Content-Length: 1000") != std::string::npos, "a range: 206, just those bytes");
  r = get(link, "/api/file?id=ab12", th, ck + "Range: bytes=199990-\r\n");
  CHECK(code(r) == 206 && body(r) == mix.substr(199990), "from a byte to the end");
  r = get(link, "/api/file?id=ab12", th, ck + "Range: bytes=-100\r\n");
  CHECK(code(r) == 206 && body(r) == mix.substr(199900), "the last bytes");
  r = get(link, "/api/file?id=ab12", th, ck + "Range: bytes=199000-500000\r\n");
  CHECK(code(r) == 206 && body(r) == mix.substr(199000) && r.find("Content-Range: bytes 199000-199999/200000") != std::string::npos, "past the end: cut to it");
  r = get(link, "/api/file?id=ab12", th, ck + "Range: bytes=200000-\r\n");
  CHECK(code(r) == 416 && r.find("Content-Range: bytes */200000") != std::string::npos && body(r).empty(), "starting past the end: 416");
  CHECK(code(get(link, "/api/file?id=ab12", th, ck + "Range: bytes=0-1,5-9\r\n")) == 200 && code(get(link, "/api/file?id=ab12", th, ck + "Range: items=1-2\r\n")) == 200 &&
        code(get(link, "/api/file?id=ab12", th, ck + "Range: bytes=x-\r\n")) == 200, "several ranges or a malformed one: the whole file");
  CHECK(code(get(link, "/api/file?id=ab12", th, "Range: bytes=0-9\r\n")) == 403, "a range still needs the token");
  spit(dir + "/clip.MP4", mix.substr(0, 5000));
  CHECK(webui_offer("cd56", (dir + "/clip.MP4").c_str()) == 1 && get(link, "/api/file?id=cd56", th, ck).find("Content-Type: video/mp4") != std::string::npos,
        "a video typed as one, so a <video> plays it");
  webui_offer("cd56", "");
  CHECK(code(get(link, "/api/file?id=ab12", th)) == 403, "and only with the studio's token");
  CHECK(code(get(link, "/api/file?id=cd34", th, ck)) == 404 && code(get(link, "/api/file?id=", th, ck)) == 404, "an id not offered: 404");
  CHECK(webui_offer("ab12", "") == 1 && code(get(link, "/api/file?id=ab12", th, ck)) == 404, "withdrawn: 404");
  // a screen share's sound (rt-share): REAPER's mix as raw 16-bit stereo, this computer's pages only
  CHECK(code(get(link, "/api/mix", th, ck)) == 403, "REAPER's mix: never on the link's port, token or not");
  CHECK(code(get(web, "/api/mix", lh, "X-Forwarded-For: 100.64.0.9\r\n" + ck)) == 403, "nor through a proxy here");
  CHECK(code(get(web, "/api/mix", lh)) == 503 && webui_mix_wanted() == 0, "no audio coming (REAPER's stopped): 503, and nobody streaming after");
  {
    std::atomic<bool> feeding{ true };
    std::thread feeder([&] { // (the audio hook's part: 10 ms blocks at 48 kHz, a 1 kHz tone at -6 dB, the right channel its negative)
      std::vector<double> L(480), R(480);
      long long n = 0;
      while (feeding) {
        for (int k = 0; k < 480; ++k, ++n) { L[k] = 0.5 * sin(2 * 3.141592653589793 * 1000.0 * (double)n / 48000.0); R[k] = -L[k]; }
        const double *out[2] = { L.data(), R.data() };
        webui_mix_feed(out, 2, 480, 48000.0);
        sleep_ms(10);
      }
    });
    const int s = dial(web);
    const std::string q = "GET /api/mix HTTP/1.1\r\nHost: " + lh + "\r\n\r\n";
    send(s, q.data(), (int)q.size(), 0);
    std::string got;
    char b[8192];
    for (int i = 0; i < 200 && (got.find("\r\n\r\n") == std::string::npos || got.size() - got.find("\r\n\r\n") < 4 + 48000 * 4 / 5); ++i) {
      const int k = recv(s, b, sizeof b, 0);
      if (k <= 0) break;
      got.append(b, (size_t)k);
    }
    const size_t he = got.find("\r\n\r\n");
    CHECK(code(got) == 200 && got.find("X-Rate: 48000\r\n") != std::string::npos && got.find("X-Channels: 2\r\n") != std::string::npos &&
          got.find("Content-Length") == std::string::npos, "this computer's page: a stream, its rate in X-Rate");
    CHECK(webui_mix_wanted() == 1, "the hook is wanted while it streams");
    const std::string pcm = he == std::string::npos ? "" : got.substr(he + 4);
    bool same = pcm.size() >= 48000 * 4 / 5;
    short peak = 0, l1 = 0, l2 = 0;
    const double c2 = 2 * cos(2 * 3.141592653589793 * 1000.0 / 48000.0);
    for (size_t i = 0; same && i + 4 <= pcm.size(); i += 4) {
      short l, r2;
      memcpy(&l, &pcm[i], 2); memcpy(&r2, &pcm[i + 2], 2);
      same = abs(l + r2) <= 1 && (i < 8 || fabs(l - (c2 * l1 - l2)) <= 3); // (left then right, the right the left's negative; each sample the tone's next)
      peak = std::max(peak, l);
      l2 = l1; l1 = l;
    }
    CHECK(same && peak > 16000 && peak < 16500, "200 ms of it: the tone at -6 dB, left then right, nothing lost or torn");
    closesocket(s);
    for (int i = 0; i < 200 && webui_mix_wanted() != 0; ++i) sleep_ms(10);
    CHECK(webui_mix_wanted() == 0, "the page gone: nobody streaming, the hook can come out");
    feeding = false;
    feeder.join();
  }
  const std::string st = webui_status();
  CHECK(st.find("\"listening\":true") != std::string::npos && st.find("\"token\":\"" + tok + "\"") != std::string::npos, "status says listening, with the token");

  webui_shutdown();
  direct_shutdown();
  sleep_ms(50);
  CHECK(get(web, "/", lh).empty(), "stopped: nothing listening");
  printf("%s (%d failed)\n", fails ? "FAILED" : "all ok", fails);
  return fails ? 1 : 0;
}
