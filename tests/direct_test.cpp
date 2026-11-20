// The direct link's core (extension/direct.cpp) without REAPER, 0.59.50: SHA-256 / HMAC against published vectors, the path rule,
// then a listener on 127.0.0.1 and the sender: a file arrives intact; a bad signature, an unknown studio, a bad path and an oversized
// file are refused and nothing is written; round-trip times. Build and run: tests\build_direct_test.cmd.
// `direct_test connect <host> <port> [n]`: only TCP connect times (one round trip each) to a port already open there, e.g. ssh's 22
// over Tailscale: how far the direct link's one hop is, with no listener (or firewall rule) needed on the other computer.
// GPL-3.0-or-later.
#ifdef _WIN32
#define NOMINMAX // (windows.h's min and max macros would hide std::min and std::max)
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#define closesocket close
#endif
#include <algorithm>
#include <atomic>
#include <cmath>
#include <mutex>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>
#include "../extension/direct.h"

static int fails = 0;
#define CHECK(c, what) do { if (c) printf("ok   %s\n", what); else { printf("FAIL %s\n", what); ++fails; } } while (0)
#define CHECK_QUIET(c) do { if (!(c)) { printf("FAIL %s (line %d)\n", #c, __LINE__); ++fails; } } while (0)
// A file's length through a handle that lets everyone else go on writing (fopen's default on Windows does too)
static long long file_len(const std::string &p) { FILE *f = fopen(p.c_str(), "rb"); if (!f) return -1; fseek(f, 0, SEEK_END); const long long n = ftell(f); fclose(f); return n; }
static double now_ms() { return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static std::string hex(const unsigned char *p, size_t n) { std::string s; char b[3]; for (size_t i = 0; i < n; ++i) { snprintf(b, 3, "%02x", p[i]); s += b; } return s; }
static std::string slurp(const std::string &p) { std::string s; FILE *f = fopen(p.c_str(), "rb"); if (!f) return "\x01missing"; char b[4096]; size_t n; while ((n = fread(b, 1, sizeof b, f)) > 0) s.append(b, n); fclose(f); return s; }
static bool exists(const std::string &p) { FILE *f = fopen(p.c_str(), "rb"); if (f) fclose(f); return f != nullptr; }
static void spit(const std::string &p, const std::string &s) { FILE *f = fopen(p.c_str(), "wb"); fwrite(s.data(), 1, s.size(), f); fclose(f); }
static void stats(const char *what, std::vector<double> v)
{
  std::sort(v.begin(), v.end());
  printf("     %s: median %.3f ms, p95 %.3f ms, min %.3f, max %.3f (n=%d)\n", what, v[v.size() / 2], v[(size_t)(v.size() * 0.95)], v.front(), v.back(), (int)v.size());
}
// A raw frame sent by hand -> the answer byte (-1: closed without one).
static int raw(int port, const std::string &frame)
{
  int s = (int)socket(AF_INET, SOCK_STREAM, 0);
  sockaddr_in a = {}; a.sin_family = AF_INET; a.sin_port = htons((unsigned short)port); inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
  if (connect(s, (sockaddr *)&a, sizeof a) != 0) { closesocket(s); return -2; }
  send(s, frame.data(), (int)frame.size(), 0);
  char c = 0;
  const int k = recv(s, &c, 1, 0);
  closesocket(s);
  return k == 1 ? (unsigned char)c : -1;
}
// Every socket this process holds on `port` (bound to it, or connected to it) -> how many; `inheritable`: how many of them a child process
// would inherit (one REAPER started outlived it and kept its ports bound).
static int sockets_on(int port, int &inheritable)
{
  int n = 0;
  inheritable = 0;
#ifdef _WIN32
  for (SOCKET s = 4; s < 65536; s += 4) { // (socket handles are multiples of 4; a non-socket fails getsockname)
#else
  for (int s = 0; s < 4096; ++s) {
#endif
    sockaddr_in a = {}, b = {};
    socklen_t la = sizeof a, lb = sizeof b;
    const bool on = (getsockname(s, (sockaddr *)&a, &la) == 0 && a.sin_family == AF_INET && ntohs(a.sin_port) == port) ||
                    (getpeername(s, (sockaddr *)&b, &lb) == 0 && b.sin_family == AF_INET && ntohs(b.sin_port) == port);
    if (!on) continue;
    ++n;
#ifdef _WIN32
    DWORD f = 0;
    if (!GetHandleInformation((HANDLE)s, &f) || (f & HANDLE_FLAG_INHERIT)) ++inheritable;
#else
    if (!(fcntl(s, F_GETFD) & FD_CLOEXEC)) ++inheritable;
#endif
  }
  return n;
}
static std::string wait_poll(int after, double ms)
{
  const double t0 = now_ms();
  while (now_ms() - t0 < ms) { const char *p = direct_poll(after); if (*p) return p; std::this_thread::yield(); }
  return "";
}

static int connect_times(const char *host, const char *port, int n)
{
  addrinfo hints = {}, *res = nullptr;
  hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM;
  if (getaddrinfo(host, port, &hints, &res) != 0 || !res) { printf("can't resolve %s\n", host); return 1; }
  char ip[64]; inet_ntop(AF_INET, &((sockaddr_in *)res->ai_addr)->sin_addr, ip, sizeof ip);
  std::vector<double> v;
  for (int i = 0; i < n; ++i) {
    int s = (int)socket(AF_INET, SOCK_STREAM, 0);
    const double t = now_ms();
    const bool ok = connect(s, res->ai_addr, (int)res->ai_addrlen) == 0;
    const double dt = now_ms() - t;
    closesocket(s);
    if (ok) v.push_back(dt);
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  freeaddrinfo(res);
  if (v.empty()) { printf("no connection to %s (%s):%s\n", host, ip, port); return 1; }
  printf("TCP connect to %s (%s):%s, one round trip each:\n", host, ip, port);
  stats("connect", v);
  return 0;
}

// Two computers: `listen <port> <seconds>` on one (127.0.0.1 only: reached through `ssh -L`, so no firewall rule is needed for a test),
// `send <host:port> <n>` on the other: each file's send -> kept-and-answered time, as the sender measures it.
static std::string scratch(const char *name)
{
  const char *t = getenv("TEMP");
  std::string d = std::string(t ? t : "/tmp") + "/" + name;
#ifdef _WIN32
  CreateDirectoryA(d.c_str(), nullptr);
#else
  mkdir(d.c_str(), 0755);
#endif
  return d;
}
static const char *PAIR_STUDIO = "studiosync-pairtest", *PAIR_SECRET = "pair-test-secret-0123456789";
static int listen_for(int port, int secs)
{
  const std::string inbox = scratch("ss_direct_listen");
  if (direct_start(PAIR_STUDIO, PAIR_SECRET, inbox.c_str(), port, "127.0.0.1") != 1) { printf("can't listen: %s\n", direct_status()); return 1; }
  printf("listening on 127.0.0.1:%d for %d s\n", port, secs);
  fflush(stdout);
  int seq = 0;
  const double end = now_ms() + secs * 1000.0;
  while (now_ms() < end) {
    const char *p = direct_poll(seq);
    if (*p) { seq = atoi(p); continue; }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  printf("received %d; %s\n", seq, direct_status());
  printf("streams: %s\n", direct_streams());
  direct_shutdown();
#ifdef _WIN32
  std::string w = inbox; std::replace(w.begin(), w.end(), '/', '\\');
  system((std::string("rmdir /s /q \"") + w + "\"").c_str());
#else
  system((std::string("rm -rf '") + inbox + "'").c_str());
#endif
  return 0;
}
static int send_to(const char *peer, int n)
{
  const std::string dir = scratch("ss_direct_send"), src = dir + "/event.json";
  spit(src, std::string("{\"type\":\"obj\",\"user\":\"James\",\"pad\":\"") + std::string(300, 'x') + "\"}");
  direct_start(PAIR_STUDIO, PAIR_SECRET, dir.c_str(), -1, "");
  std::vector<double> v;
  long long sent = 0;
  for (int i = 0; i < n; ++i) {
    char rel[128]; snprintf(rel, sizeof rel, "Song/rooms/main/events/James-20261119-120000Z-%05d-%04d.json", i, (int)(now_ms()) % 10000);
    direct_send(PAIR_STUDIO, rel, src.c_str(), peer);
    const double t0 = now_ms();
    for (;;) { // (until the sender notes this one: its "sent" goes up, or it fails)
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
      const std::string st = direct_status();
      const size_t at = st.find("\"sent\":");
      const long long s = at == std::string::npos ? 0 : atoll(st.c_str() + at + 7);
      if (s > sent) { sent = s; const size_t m = st.find("\"ms\":"); v.push_back(atof(st.c_str() + m + 5)); break; }
      if (st.find("\"error\":\"\"}}}") == std::string::npos || now_ms() - t0 > 5000) { printf("failed: %s\n", st.c_str()); return 1; } // (the peer's error, last)
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
  }
  if (!v.empty()) {
    printf("first send (a new connection): %.1f ms\n", v.front());
    stats("send -> kept and answered, on the kept connection", std::vector<double>(v.begin() + (v.size() > 1 ? 1 : 0), v.end()));
  }
  direct_shutdown();
  remove(src.c_str());
#ifdef _WIN32
  RemoveDirectoryA(dir.c_str());
#else
  rmdir(dir.c_str());
#endif
  return v.empty() ? 1 : 0;
}

// ---- 1.0.8: messages, the clock, streams, the audio spike -------------------------------------------------------------------------------
static double pct(std::vector<double> v, double q) { std::sort(v.begin(), v.end()); return v.empty() ? -1 : v[(size_t)((v.size() - 1) * q)]; }
static double json_num(const std::string &s, const std::string &key, size_t from = 0)
{
  const size_t at = s.find("\"" + key + "\":", from);
  return at == std::string::npos ? -1e9 : atof(s.c_str() + at + key.size() + 3);
}
static void le(std::string &s, unsigned v, int n) { for (int i = 0; i < n; ++i) s += (char)((v >> (8 * i)) & 255); }
static unsigned rdle(const std::string &s, size_t at) { return (unsigned char)s[at] | ((unsigned char)s[at + 1] << 8) | ((unsigned char)s[at + 2] << 16) | ((unsigned)(unsigned char)s[at + 3] << 24); }
// A 24-bit stereo 48 kHz WAV's header, as a recorder writes it first: sizes 0 until it stops (then `data` bytes).
static std::string wav_head(unsigned data)
{
  std::string h = "RIFF";
  le(h, data ? 36 + data : 0, 4); h += "WAVEfmt "; le(h, 16, 4); le(h, 1, 2); le(h, 2, 2); le(h, 48000, 4); le(h, 48000 * 6, 4); le(h, 6, 2); le(h, 24, 2);
  h += "data"; le(h, data, 4);
  return h;
}
// Is this (a received copy, mid-stream) a WAV a player can open: whole frames, and sizes that never claim more than is there (a look
// between an append and the header's update sees the sizes a chunk behind: still a good WAV, a little shorter)?
static bool wav_playable(const std::string &f)
{
  long long off; int ba; bool rf; long long ds;
  if (!direct_wav_layout(f, off, ba, rf, ds) || rf || off != 44 || ba != 6) return false;
  const unsigned riff = rdle(f, 4), data = rdle(f, 40);
  if (data % 6 != 0 || data == 0 || 44 + (long long)data > (long long)f.size() || riff < 36 + data || riff + 8 > f.size()) { printf("     not playable: size %d riff %u data %u\n", (int)f.size(), riff, data); return false; }
  return true;
}

// A take written the way REAPER writes one (James, rt: on the desktop the laptop's copy sat at the first 64 KB until stop): 24-bit FLAC
// bytes in 256 KB blocks, the file held open for writing the whole time, other handles allowed only to read (WDL_FileWrite's
// FILE_SHARE_READ). `async`: Windows only, its unbuffered overlapped writes (FILE_FLAG_NO_BUFFERING | FILE_FLAG_OVERLAPPED, sector-aligned
// blocks, the tail cut with SetEndOfFile at the end). Each block must be in the received copy within one pass of the 100 ms interval (500 ms
// allowed: localhost); at stop the header block is rewritten (FLAC's STREAMINFO), and the copy must end byte for byte the same.
static void reaper_like_take(const std::string &studio, const char *peer, const std::string &inbox, const std::string &dir, bool async)
{
  const std::string name = async ? "REAPER async take.flac" : "REAPER take.flac", take = dir + "/" + name, rel = "Song A/" + name, got = inbox + "/.streams/" + rel;
  const size_t BLOCK = 256 * 1024;
  const int blocks = 8;
  std::string all;
  unsigned x = 7;
  for (int b = 0; b < blocks; ++b) for (size_t i = 0; i < BLOCK; ++i) { x = x * 1103515245u + 12345u; all += (char)(x >> 16); }
  memcpy(&all[0], "fLaC\0\0\0\x22", 8); // (STREAMINFO with "length unknown" until the end)
  const size_t tail = 70000; // (the last block's real length: the rest is padding a sector writer cuts off)
  std::string fin = all.substr(0, (blocks - 1) * BLOCK + tail);
  fin[20] = '\x11'; // (the header rewritten at stop)
#ifdef _WIN32
  HANDLE h = CreateFileA(take.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS,
                         FILE_ATTRIBUTE_NORMAL | (async ? FILE_FLAG_NO_BUFFERING | FILE_FLAG_OVERLAPPED : 0), nullptr);
  char *buf = (char *)VirtualAlloc(nullptr, BLOCK, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE); // (sector-aligned, as unbuffered writes need)
  auto put = [&](long long at, const std::string &d) {
    memcpy(buf, d.data(), d.size());
    OVERLAPPED o = {}; o.Offset = (DWORD)at; o.OffsetHigh = (DWORD)(at >> 32);
    o.hEvent = async ? CreateEventA(nullptr, TRUE, FALSE, nullptr) : nullptr;
    DWORD n = 0;
    BOOL ok = WriteFile(h, buf, (DWORD)d.size(), async ? nullptr : &n, &o);
    if (!ok && GetLastError() == ERROR_IO_PENDING) ok = GetOverlappedResult(h, &o, &n, TRUE);
    if (o.hEvent) CloseHandle(o.hEvent);
    return ok && n == d.size();
  };
  CHECK(h != INVALID_HANDLE_VALUE, async ? "REAPER-like writer (unbuffered, overlapped, share read only) opened" : "REAPER-like writer (share read only) opened");
#else
  FILE *wf = fopen(take.c_str(), "wb");
  auto put = [&](long long at, const std::string &d) { return fseeko(wf, (off_t)at, SEEK_SET) == 0 && fwrite(d.data(), 1, d.size(), wf) == d.size() && fflush(wf) == 0; };
  CHECK(wf != nullptr, "REAPER-like writer opened");
#endif
  {
    const double wall = std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count(), ft = direct_file_time(take.c_str());
    CHECK(fabs(ft - wall) < 5, "the open take's file time is now (lib/streams.lua: is this the take REAPER just began?)");
    CHECK(direct_file_time((dir + "/no such.flac").c_str()) < 0, "no file: -1");
  }
  const std::string trace = dir + "/stream_trace.log";
  if (!async) direct_trace(trace.c_str());
  bool started = false, each = true, sized = true;
  std::vector<double> lag;
  for (int b = 0; b < blocks; ++b) {
    CHECK_QUIET(put((long long)b * BLOCK, all.substr((size_t)b * BLOCK, BLOCK)));
    { // (the size a stream reads, right after the write, nothing flushed or closed)
      std::string how;
      const long long sz = direct_file_size(take.c_str(), &how);
      if (sz != (long long)(b + 1) * BLOCK) { sized = false; printf("     block %d: the stream reads its size as %lld (%s)\n", b + 1, sz, how.c_str()); }
      else if (b == 3) printf("     block 4 written, the open take's size read every way: %s\n", how.c_str());
    }
    if (!started) { started = direct_stream(studio.c_str(), rel.c_str(), take.c_str(), peer, 100) == 1; CHECK(started, "the open take is streamed"); }
    const double t0 = now_ms();
    const size_t want = (size_t)(b + 1) * BLOCK;
    long long have = 0;
    while (now_ms() - t0 < 500 && (have = file_len(got)) < (long long)want) std::this_thread::sleep_for(std::chrono::milliseconds(2));
    if (have < (long long)want) { each = false; printf("     block %d: the copy has %lld of %d bytes after 500 ms: %s\n", b + 1, have, (int)want, direct_streams()); }
    else lag.push_back(now_ms() - t0);
    std::this_thread::sleep_for(std::chrono::milliseconds(150));
  }
  if (!async) {
    direct_trace("");
    const std::string t = slurp(trace);
    int lines = 0;
    for (size_t at = 0; (at = t.find("Song A/REAPER take.flac | ", at)) != std::string::npos; ++at) ++lines;
    printf("     stream trace: %d passes logged, e.g. %s\n", lines, t.substr(0, t.find('\n')).c_str());
    CHECK(lines >= 10 && t.find(" off ") != std::string::npos && (t.find("standard=") != std::string::npos || t.find("seek-end=") != std::string::npos), // (Windows reads the size four ways, Mac/Linux one)
          "the stream trace logs every pass while the take is open (size, how each way read it, each peer's place)");
  }
  CHECK(sized, async ?"the open take's size, read the stream's way, is what's been written after every block (unbuffered writer)" : "the open take's size, read the stream's way, is what's been written after every block (no flush, handle kept open)");
  CHECK(each, async ?"every 256 KB block of the open take reached the copy within a pass (unbuffered writer)" : "every 256 KB block of the open take reached the copy within a pass");
  if (!lag.empty()) stats(async ? "256 KB block written -> in the copy (unbuffered writer, 100 ms interval)" : "256 KB block written -> in the copy (100 ms interval)", lag);
  // stop: the header block again, the tail cut to the real length, closed
  CHECK_QUIET(put(0, fin.substr(0, BLOCK)));
#ifdef _WIN32
  LARGE_INTEGER end; end.QuadPart = (LONGLONG)fin.size();
  CHECK_QUIET(SetFilePointerEx(h, end, nullptr, FILE_BEGIN) && SetEndOfFile(h));
  CloseHandle(h);
  VirtualFree(buf, 0, MEM_RELEASE);
#else
  fclose(wf);
  CHECK_QUIET(truncate(take.c_str(), (off_t)fin.size()) == 0);
#endif
  CHECK(direct_stream_end(studio.c_str(), rel.c_str()) == 1, "the take's stream ended");
  std::string ss;
  for (double t0 = now_ms(); now_ms() - t0 < 10000; std::this_thread::sleep_for(std::chrono::milliseconds(5))) {
    ss = direct_streams();
    const size_t at = ss.find("\"rel\":\"" + rel + "\"");
    if (at != std::string::npos && ss.find("\"finished\":true", at) < ss.find('}', ss.find("\"peers\"", at))) break;
  }
  CHECK(slurp(got) == fin, "the received take matches byte for byte (header rewritten, tail cut)");
}

// The same over a slow way (400 kbit/s, as a Tailscale relay can be): REAPER's first 64 KB, then a 256 KB block while the file stays open.
// Each stream frame waits for its answer up to 3 s, so a frame must cross in well under that (James, rt: the laptop's copy sat at the first
// 64 KB while 256 KB frames timed out, each failure skipping the peer 10 s; at stop the path had gone direct).
static void slow_link_take(const std::string &studio, const char *peer, const std::string &inbox, const std::string &dir)
{
  const std::string name = "slow take.flac", take = dir + "/" + name, rel = "Song A/" + name, got = inbox + "/.streams/" + rel;
  std::string head(65536, 'h'), block(256 * 1024, 'b');
  memcpy(&head[0], "fLaC", 4);
  FILE *wf = fopen(take.c_str(), "wb");
  fwrite(head.data(), 1, head.size(), wf); fflush(wf);
  direct_test_bandwidth(400);
  CHECK(direct_stream(studio.c_str(), rel.c_str(), take.c_str(), peer, 100) == 1, "a take streamed over a slow way (400 kbit/s)");
  for (double t0 = now_ms(); now_ms() - t0 < 5000 && file_len(got) < 65536;) std::this_thread::sleep_for(std::chrono::milliseconds(10));
  fwrite(block.data(), 1, block.size(), wf); fflush(wf);
  const double t0 = now_ms();
  const std::string want_sent = "\"rel\":\"" + rel + "\",\"size\":327680";
  std::string ss;
  auto acked = [&]() { ss = direct_streams(); const size_t at = ss.find(want_sent); return at != std::string::npos && ss.find("\"sent\":327680", at) < ss.find("}}", at); };
  while (now_ms() - t0 < 9000 && !acked()) std::this_thread::sleep_for(std::chrono::milliseconds(20));
  const long long have = file_len(got);
  printf("     slow way: 256 KB block -> %lld bytes in the copy, answered, after %.0f ms\n", have, now_ms() - t0);
  CHECK(have == 65536 + (long long)block.size() && acked(), "the 256 KB block crosses the slow way while the take is still open, every frame answered in time (no dropped connection, no 10 s wait)");
  direct_test_bandwidth(0);
  fclose(wf);
  direct_stream_end(studio.c_str(), rel.c_str());
  for (double t1 = now_ms(); now_ms() - t1 < 5000 && slurp(got) != head + block;) std::this_thread::sleep_for(std::chrono::milliseconds(10));
  CHECK(slurp(got) == head + block, "and ends whole");
}

// The received WAV's one hard moment: its first audio. Many short takes, the header arriving alone in the first frame (even rounds) or split
// over two (odd rounds), then small appends; each audio write and its header write held 3 ms apart (direct_test_stream_gap) while a reader
// looks in a tight loop. Every look at a copy that starts "R" and is longer than its header must be a playable WAV (aarch64 CI caught
// "riff 36 data 0" once in ~450 looks; this catches it every run without the hold-back in wav_append).
static void wav_hammer(const std::string &studio, const char *peer, const std::string &inbox, const std::string &dir)
{
  direct_test_stream_gap(3);
  int looks = 0, bad = 0;
  for (int r = 0; r < 12; ++r) {
    char nm[64]; snprintf(nm, sizeof nm, "hammer %02d.wav", r);
    const std::string take = dir + "/" + nm, rel = std::string("Song A/") + nm, got = inbox + "/.streams/" + rel, head = wav_head(0);
    const size_t first = r % 2 ? 20 : head.size();
    FILE *wf = fopen(take.c_str(), "wb");
    fwrite(head.data(), 1, first, wf); fflush(wf);
    direct_stream(studio.c_str(), rel.c_str(), take.c_str(), peer, 20);
    auto wait_for = [&](long long n) { for (double t0 = now_ms(); now_ms() - t0 < 3000 && file_len(got) < n;) std::this_thread::sleep_for(std::chrono::milliseconds(1)); };
    wait_for((long long)first);
    if (first < head.size()) { fwrite(head.data() + first, 1, head.size() - first, wf); fflush(wf); wait_for((long long)head.size()); }
    std::atomic<bool> stop{ false };
    std::thread reader([&] {
      while (!stop) {
        const std::string g = slurp(got);
        if (g.size() > 44 && g[0] == 'R') { ++looks; if (!wav_playable(g)) ++bad; }
      }
    });
    std::string blk(600, '\0');
    for (int k = 0; k < 20; ++k) {
      for (size_t i = 0; i < blk.size(); ++i) blk[i] = (char)(i * 7 + k);
      fwrite(blk.data(), 1, blk.size(), wf); fflush(wf);
      std::this_thread::sleep_for(std::chrono::milliseconds(4));
    }
    wait_for((long long)(head.size() + 20 * blk.size()));
    stop = true;
    reader.join();
    fclose(wf);
    direct_stream_end(studio.c_str(), rel.c_str());
  }
  direct_test_stream_gap(0);
  printf("     hammered: %d looks at copies mid-stream, %d not playable\n", looks, bad);
  CHECK(looks > 50 && bad == 0, "a WAV's first audio never shows a header claiming nothing or too much (header alone or split, writes held 3 ms apart, a reader in a tight loop)");
}

// 1.0.12: several stream frames in flight. A finished file streamed and ended at once (a catch-up or a media file) -> seconds until it's
// done and hash-checked there, and it arrived whole.
static double stream_file(const std::string &studio, const char *peer, const std::string &inbox, const std::string &src, const std::string &rel, long long size)
{
  const double t0 = now_ms();
  direct_stream(studio.c_str(), rel.c_str(), src.c_str(), peer, 20);
  direct_stream_end(studio.c_str(), rel.c_str());
  const std::string done = "\"rel\":\"" + rel + "\",\"size\":" + std::to_string(size) + ",\"ended\":true,\"finished\":true";
  while (now_ms() - t0 < 60000 && std::string(direct_streams()).find(done) == std::string::npos) std::this_thread::sleep_for(std::chrono::milliseconds(2));
  const double secs = (now_ms() - t0) / 1000;
  CHECK_QUIET(slurp(inbox + "/.streams/" + rel) == slurp(src));
  return secs;
}
// The same 8 MB over a 57 ms round trip (Tailscale's, desktop <-> laptop off the home network): one frame at a time, as before 1.0.12, then
// with the window. Then a slow relayed way (2 Mbit/s, 120 ms): the window stays small, nothing drops, and the rate Health shows is the link's.
static void link_speed(const std::string &studio, const char *peer, const std::string &inbox, const std::string &dir)
{
  const std::string src = dir + "/catchup.wav";
  const long long size = 8LL << 20;
  {
    std::string chunk(1 << 20, 'c');
    FILE *f = fopen(src.c_str(), "wb");
    for (int i = 0; i < 8; ++i) { chunk[7] = (char)i; fwrite(chunk.data(), 1, chunk.size(), f); }
    fclose(f);
  }
  direct_test_link(57, 1);
  const double before = stream_file(studio, peer, inbox, src, "Song A/catchup one at a time.wav", size);
  direct_test_link(57, 0);
  const double after = stream_file(studio, peer, inbox, src, "Song A/catchup windowed.wav", size);
  std::string st = direct_status();
  const size_t at = st.find(std::string("\"") + peer + "\"");
  const double rate = json_num(st, "rate", at), rtt = json_num(st, "rtt_ms", at), win = json_num(st, "window", at);
  printf("     8 MB at a 57 ms round trip: one frame at a time %.1f s (%.2f MB/s), windowed %.1f s (%.2f MB/s), %.1fx; status rate %.2f MB/s, rtt %.0f ms, window %.0f\n",
         before, 8.39 / before, after, 8.39 / after, before / after, rate / 1e6, rtt, win);
  CHECK(before / after >= 4 && rate > 2e6 && rtt >= 50 && win >= 8, "several frames in flight: 8 MB at a 57 ms round trip at least 4x faster than one at a time; the status says the rate, round trip and window");

  // in between: a 20 Mbit/s way at the same round trip. The window settles near what the link holds in a round trip (2.5 MB/s x 57 ms: 2-3 frames)
  direct_test_bandwidth(20000);
  const double mid = stream_file(studio, peer, inbox, src, "Song A/catchup 20 Mbit.wav", size);
  st = direct_status();
  const double mrate = json_num(st, "rate", st.find(std::string("\"") + peer + "\"")), mwin = json_num(st, "window", st.find(std::string("\"") + peer + "\""));
  printf("     8 MB over 20 Mbit/s and 57 ms: %.1f s (%.2f MB/s), window %.0f, status rate %.2f MB/s\n", mid, 8.39 / mid, mwin, mrate / 1e6);
  // (0.7 MB/s floor, not 1.8: a shared macOS CI runner measured a 130 ms round trip for the 57 ms knob and got 0.89 MB/s, its fast case too
  // half of a desktop's. The window range is the real check: it settles at what the way holds, not 32. Real ways: measured in REAPER)
  CHECK(mrate > 0.7e6 && mwin >= 2 && mwin <= 8, "a 20 Mbit/s way: near its rate, with a window near what it holds in a round trip");

  const std::string relayed = dir + "/relayed.wav";
  spit(relayed, std::string(1 << 20, 'r'));
  direct_test_bandwidth(2000);
  direct_test_link(120, 0);
  const double slow = stream_file(studio, peer, inbox, relayed, "Song A/relayed.wav", 1 << 20);
  direct_test_bandwidth(0);
  direct_test_link(0, 0);
  st = direct_status();
  const double srate = json_num(st, "rate", st.find(std::string("\"") + peer + "\"")), swin = json_num(st, "window", st.find(std::string("\"") + peer + "\""));
  const std::string ss = direct_streams();
  const size_t sat = ss.find("\"rel\":\"Song A/relayed.wav\"");
  printf("     1 MB over 2 Mbit/s and 120 ms: %.1f s, window %.0f (each pass starts at 4 at most), status rate %.0f KB/s\n", slow, swin, srate / 1e3);
  CHECK(sat != std::string::npos && ss.find("\"resends\":0,\"error\":\"\"", sat) < ss.find("}}", sat) && swin <= 3 && srate > 120e3 && srate < 400e3,
        "a slow relayed way: the window is cut to the link (3 at most), every frame answered in time, the rate is the link's");
}

static void live_layer_tests(const std::string &studio, const std::string &secret, const std::string &key, int port, const char *peer, const std::string &inbox, const std::string &dir)
{
  (void)secret;
  // Messages: queued, kept, polled in order; a kind that isn't a word and an oversized one are refused before they're queued
  int mseq = 0;
  CHECK(direct_msg(studio.c_str(), "chat", "{\"user\":\"James\",\"text\":\"hi\ttab\"}", peer) == 1, "a message is queued");
  std::string m;
  for (double t0 = now_ms(); m.empty() && now_ms() - t0 < 3000;) { m = direct_msg_poll(mseq); std::this_thread::yield(); }
  CHECK(m.find("\tstudiosync-test\tchat\t{\"user\":\"James\",\"text\":\"hi\ttab\"}") != std::string::npos, "it arrives: seq, studio, kind, data (tabs kept)");
  if (!m.empty()) mseq = atoi(m.c_str());
  int inh = 0;
  const int held = sockets_on(port, inh);
  CHECK(held >= 3 && inh == 0, "the listener, the connection it accepted and the sender's kept one aren't inherited by a child process");
  if (held < 3 || inh) printf("     %d sockets on the port, %d inheritable\n", held, inh);
  CHECK(direct_msg(studio.c_str(), "Chat!", "x", peer) == 0 && direct_msg(studio.c_str(), "chat", std::string(DIRECT_MAX_MSG + 1, 'x').c_str(), peer) == 0,
        "a kind that isn't a word, or over 64 KB, isn't queued");
  CHECK(raw(port, direct_frame(key, studio, "chat", std::string(DIRECT_MAX_MSG + 1, 'x'), "SSM1")) == 5, "an oversized message is refused from its header (5)");
  CHECK(raw(port, direct_frame(direct_derive_key("nope"), studio, "chat", "x", "SSM1")) == 3, "a message with a bad signature is refused (3)");
  std::vector<double> mlat;
  for (int i = 0; i < 200; ++i) {
    const double t0 = now_ms();
    direct_msg(studio.c_str(), "midi", "{\"n\":60,\"v\":100}", peer);
    std::string g;
    while (g.empty() && now_ms() - t0 < 3000) { g = direct_msg_poll(mseq); if (g.empty()) std::this_thread::yield(); }
    if (g.empty()) break;
    mlat.push_back(now_ms() - t0);
    mseq = atoi(g.c_str());
  }
  CHECK(mlat.size() == 200, "200 messages all arrived");
  stats("message send -> polled (localhost)", mlat);
  for (int i = 0; i < 600; ++i) direct_msg(studio.c_str(), "presence", "{}", peer);
  for (double t0 = now_ms(); now_ms() - t0 < 3000 && json_num(direct_status(), "queued") > 0;) std::this_thread::sleep_for(std::chrono::milliseconds(5));
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  int kept = 0;
  for (int s = 0; *direct_msg_poll(s); ++kept) s = atoi(direct_msg_poll(s));
  CHECK(kept == 512, "the received queue is bounded (the last 512 kept)");

  // The clock: the listener's clock 37.5 ms ahead and each way delayed 0-15 ms at random; the estimate within a few ms
  direct_test_knobs(37500, 15, 20);
  CHECK(direct_peers(studio.c_str(), peer) == 1, "a peer to keep a clock with");
  const double tc = now_ms();
  std::this_thread::sleep_for(std::chrono::milliseconds(1500));
  std::string ck = direct_clock();
  printf("     clock, skew 37.5 ms, 0-15 ms random delay each way: %s (%.0f ms)\n", ck.c_str(), now_ms() - tc);
  const double off = json_num(ck, "offset_ms");
  // (within what the estimate itself says it spreads over, plus 2 ms, never asked for under 3 ms: a shared CI Mac's jitter put it 10 ms off
  // with a 16.6 ms spread. The no-delay check below stays strict. James, rt)
  const double spread = json_num(ck, "spread_ms");
  CHECK(spread >= 0 && fabs(off - 37.5) <= std::max(3.0, spread + 2.0) && json_num(ck, "samples") >= 10,
        "the clock offset is within its own spread (+2 ms, at least 3 ms) of the skew, through jitter, from 10 samples or more");
  direct_test_knobs(-120000, 0, 20);
  std::this_thread::sleep_for(std::chrono::milliseconds(800)); // (16 new samples: the window's turned over)
  ck = direct_clock();
  printf("     clock, skew -120 ms, no added delay: %s\n", ck.c_str());
  CHECK(fabs(json_num(ck, "offset_ms") + 120.0) < 0.5, "a step in the skew is followed, within 0.5 ms on localhost");
  const double t_now = direct_now(), wall = std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();
  CHECK(fabs(t_now - wall) < 1.0, "direct_now is wall time");
  direct_test_knobs(0, 0, 0);
  CHECK(direct_peers(studio.c_str(), "") == 0 && std::string(direct_clock()).find(peer) == std::string::npos, "no peers: no clock");

  // Streams: the path rule
  CHECK(direct_stream_rel_ok("Song A/James take 03.wav") && direct_stream_rel_ok("S/x.FLAC") && !direct_stream_rel_ok("S/x.json") && !direct_stream_rel_ok("../x.wav") &&
        !direct_stream_rel_ok("S/sub/x.wav") && !direct_stream_rel_ok("S/.x.wav") && !direct_stream_rel_ok("x.wav") && !direct_stream_rel_ok("S/x.wav."),
        "the stream path rule");
  { // 1.0.12, send anything: the vetted studio files go, nothing that runs ever does
    bool sends = true, runs = false;
    for (const char *e : { "mp4", "MOV", "webm", "pdf", "png", "jpg", "jpeg", "txt", "md", "mid", "fxp", "fxb", "vstpreset", "nam", "sfz", "als", "zip" })
      if (!direct_stream_rel_ok((std::string("Song A/ref chart.") + e).c_str())) { printf("     refused but shouldn't be: .%s\n", e); sends = false; }
    for (const char *e : { "exe", "dll", "dylib", "so", "lua", "py", "sh", "bat", "cmd", "ps1", "js", "EXE", "rpp", "json" })
      if (direct_stream_rel_ok((std::string("Song A/tool.") + e).c_str())) { printf("     passed but shouldn't: .%s\n", e); runs = true; }
    CHECK(sends && !runs && !direct_stream_rel_ok("Song A/x.exe:y.txt") && !direct_stream_rel_ok("Song A/../x.zip"),
          "send anything: video, pdf, pictures, notes, presets, als and zip go; executables and scripts never");
  }

  // A take recorded while it's streamed: a writer thread appends 24-bit stereo at 4x real time with the recorder's placeholder header;
  // mid-way the received copy must be a playable WAV every time it's looked at; at the end, byte for byte the same
  const std::string take = dir + "/take.wav", srel = "Song A/James take 01.wav", got_path = inbox + "/.streams/" + srel;
  spit(take, wav_head(0));
  std::vector<std::pair<long long, double>> appended; // (end offset, when)
  std::mutex amx;
  const int blocks = 400, frames_per = 480; // (4 s of audio, 10 ms blocks)
  std::thread writer([&] {
    FILE *f = fopen(take.c_str(), "ab");
    std::string blk(frames_per * 6, '\0');
    unsigned x = 1;
    long long end = 44;
    for (int b = 0; b < blocks; ++b) {
      for (char &c : blk) { x = x * 1103515245u + 12345u; c = (char)(x >> 16); }
      fwrite(blk.data(), 1, blk.size(), f);
      fflush(f);
      end += (long long)blk.size();
      { std::lock_guard<std::mutex> l(amx); appended.push_back({ end, now_ms() }); }
      std::this_thread::sleep_for(std::chrono::microseconds(2500));
    }
    fclose(f);
  });
  CHECK(direct_stream(studio.c_str(), srel.c_str(), take.c_str(), peer, 50) == 1, "a growing file is streamed");
  int looks = 0, playable = 0;
  std::vector<double> lag;
  size_t matched = 0;
  const double ts0 = now_ms();
  while (now_ms() - ts0 < 15000) {
    const std::string g = slurp(got_path);
    if (g.size() > 44 && g[0] == 'R') {
      ++looks;
      playable += wav_playable(g);
      std::lock_guard<std::mutex> l(amx);
      while (matched < appended.size() && appended[matched].first <= (long long)g.size()) { lag.push_back(now_ms() - appended[matched].second); ++matched; }
      if (matched == (size_t)blocks) break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  writer.join();
  CHECK(looks > 20 && playable == looks, "the received copy is a playable WAV (sizes right, whole frames) every time it's looked at mid-stream");
  printf("     looked %d times mid-stream, playable %d\n", looks, playable);
  stats("appended -> in the received copy (50 ms interval)", lag);
  // stop: the recorder writes the real header; one byte already sent changes too (as if rewritten), so the hash catches it and it's sent again
  const long long total = 44 + (long long)blocks * frames_per * 6;
  {
    FILE *f = fopen(take.c_str(), "r+b");
    const std::string h = wav_head((unsigned)(total - 44));
    fwrite(h.data(), 1, h.size(), f);
    fseek(f, 100000, SEEK_SET); fputc('Z', f);
    fclose(f);
  }
  CHECK(direct_stream_end(studio.c_str(), srel.c_str()) == 1, "the stream's ended");
  std::string ss;
  for (double t0 = now_ms(); now_ms() - t0 < 10000; std::this_thread::sleep_for(std::chrono::milliseconds(5))) {
    ss = direct_streams();
    if (ss.find("\"finished\":true") != std::string::npos) break;
  }
  printf("     %s\n", ss.c_str());
  CHECK(ss.find("\"done\":true,\"resends\":1") != std::string::npos && ss.find("\"ok\":true") != std::string::npos, "done, hash checked (a changed byte: sent again once)");
  const std::string sent_bytes = slurp(take), got_bytes = slurp(got_path);
  CHECK(sent_bytes.size() == (size_t)total && got_bytes == sent_bytes, "the received take matches byte for byte");
  CHECK(raw(port, direct_frame(key, studio, "Song A/../x.wav", std::string(9, '\0'), "SSS1")) == 4, "a stream path out of the inbox is refused (4)");

  // Throughput: a 64 MB file already complete, streamed and ended at once
  const std::string big = dir + "/big.wav", brel = "Song A/big.wav";
  {
    std::string chunk(1 << 20, 'q');
    FILE *f = fopen(big.c_str(), "wb");
    for (int i = 0; i < 64; ++i) { chunk[0] = (char)i; fwrite(chunk.data(), 1, chunk.size(), f); }
    fclose(f);
  }
  const double tb = now_ms();
  direct_stream(studio.c_str(), brel.c_str(), big.c_str(), peer, 20);
  direct_stream_end(studio.c_str(), brel.c_str());
  for (; now_ms() - tb < 30000; std::this_thread::sleep_for(std::chrono::milliseconds(2))) {
    if (std::string(direct_streams()).find("\"rel\":\"Song A/big.wav\",\"size\":67108864,\"ended\":true,\"finished\":true") != std::string::npos) break;
  }
  const double tbe = now_ms() - tb;
  printf("     64 MB streamed, hashed both ends and checked: %.0f ms (%.0f MB/s)\n", tbe, 64000.0 / tbe);
  CHECK(slurp(inbox + "/.streams/" + brel) == slurp(big), "the 64 MB file arrived intact");
  reaper_like_take(studio, peer, inbox, dir, false);
#ifdef _WIN32
  reaper_like_take(studio, peer, inbox, dir, true);
#endif
  slow_link_take(studio, peer, inbox, dir);
  wav_hammer(studio, peer, inbox, dir);
  link_speed(studio, peer, inbox, dir);
}

static void audio_tests(const std::string &dir)
{
  CHECK(std::string(direct_audio_status()).find("\"running\":false") != std::string::npos, "the audio spike does nothing until started");
  direct_audio_process(nullptr, 0, 256, 48000); // (not started: ignored)
  CHECK(direct_audio_start(1, 2) == 1, "the audio spike starts (inputs 2-3 of 4)");
  std::atomic<bool> stop{ false };
  std::thread feeder([&] { // (a stand-in audio thread: 4 inputs, 256-frame buffers at about 4x real time; inputs 1 and 2 two sines)
    std::vector<double> ch[4];
    for (auto &c : ch) c.resize(256);
    long long n = 0;
    while (!stop) {
      for (int k = 0; k < 256; ++k, ++n) { ch[1][k] = 0.5 * sin(n * 2 * 3.14159265358979 * 441 / 48000); ch[2][k] = 0.25 * sin(n * 2 * 3.14159265358979 * 1000 / 48000); }
      const double *in[4] = { ch[0].data(), ch[1].data(), ch[2].data(), ch[3].data() };
      direct_audio_process(in, 4, 256, 48000);
      std::this_thread::sleep_for(std::chrono::microseconds(1300));
    }
  });
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  const std::string wav = dir + "/dump.wav";
  CHECK(direct_audio_dump(wav.c_str(), 1.0) == 1, "a dump of 1 s is started (a worker thread)");
  std::string st;
  for (double t0 = now_ms(); now_ms() - t0 < 5000; std::this_thread::sleep_for(std::chrono::milliseconds(10))) {
    st = direct_audio_status();
    if (st.find("\"state\":\"done\"") != std::string::npos || st.find("\"state\":\"failed\"") != std::string::npos) break;
  }
  stop = true;
  feeder.join();
  printf("     %s\n", st.c_str());
  const std::string w = slurp(wav);
  bool smooth = w.size() == 44 + 48000 * 8;
  float a = 0, b = 0, pa = 0, pb = 0;
  for (size_t i = 0; smooth && i < 48000; ++i) {
    memcpy(&a, &w[44 + i * 8], 4); memcpy(&b, &w[48 + i * 8], 4);
    if (i && (fabs(a - pa) > 0.035 || fabs(b - pb) > 0.04)) smooth = false; // (a dropped or doubled buffer would jump)
    pa = a; pb = b;
  }
  CHECK(st.find("\"state\":\"done\"") != std::string::npos && json_num(st, "overruns") == 0, "the dump finished with no overruns");
  CHECK(w.size() > 44 && rdle(w, 20) == (3 | (2 << 16)) && rdle(w, 24) == 48000 && rdle(w, 40) == 48000 * 8, "it's a 2-channel 48 kHz float WAV of 1 s");
  CHECK(smooth, "both channels are continuous sines (the ring dropped and doubled nothing)");
  const double p1 = atof(st.c_str() + st.find(',', st.find("\"peaks\":[")) + 1);
  CHECK(fabs(atof(st.c_str() + st.find("\"peaks\":[") + 9) - 0.5) < 0.01 && fabs(p1 - 0.25) < 0.01, "peaks per channel");
  direct_audio_stop();
  CHECK(std::string(direct_audio_status()).find("\"running\":false") != std::string::npos, "and stops");
}

// Two computers, 1.0.8: `listen` on one as before (it answers pings and takes streams too); on the other `clock <host:port> <seconds>`
// (the offset and round trip estimate each second) or `stream <host:port> <seconds>` (a 48 kHz 24-bit stereo WAV written in real time,
// streamed every 100 ms: append -> acknowledged by the other computer, and stop -> done and hash-checked).
static void rm_dir(const std::string &d)
{
#ifdef _WIN32
  std::string w = d; std::replace(w.begin(), w.end(), '/', '\\');
  system((std::string("rmdir /s /q \"") + w + "\"").c_str());
#else
  system((std::string("rm -rf '") + d + "'").c_str());
#endif
}
static int clock_to(const char *peer, int secs)
{
  const std::string dir = scratch("ss_direct_clock");
  direct_start(PAIR_STUDIO, PAIR_SECRET, dir.c_str(), -1, "");
  direct_peers(PAIR_STUDIO, peer);
  std::vector<double> offs, rtts;
  for (int s = 1; s <= secs; ++s) {
    std::this_thread::sleep_for(std::chrono::seconds(1));
    const std::string ck = direct_clock();
    const double off = json_num(ck, "offset_ms"), rtt = json_num(ck, "rtt_ms"), spread = json_num(ck, "spread_ms"), n = json_num(ck, "samples");
    printf("%3d s: offset %.3f ms, best round trip %.3f ms, spread %.3f ms, %d samples%s\n", s, off, rtt, spread, (int)n, ck.find("\"error\":\"\"") == std::string::npos ? "  (error)" : "");
    fflush(stdout);
    if (n >= 8) { offs.push_back(off); rtts.push_back(rtt); }
  }
  if (!offs.empty())
    printf("estimate over %d s: offset median %.3f ms (min %.3f, max %.3f: it moved %.3f ms), best round trip median %.3f ms\n", (int)offs.size(), pct(offs, 0.5),
           pct(offs, 0), pct(offs, 1), pct(offs, 1) - pct(offs, 0), pct(rtts, 0.5));
  printf("%s\n", direct_status());
  direct_shutdown();
  rm_dir(dir);
  return offs.empty() ? 1 : 0;
}
static int stream_to(const char *peer, int secs)
{
  const std::string dir = scratch("ss_direct_stream"), take = dir + "/take.wav", rel = "Pair/pair take.wav";
  direct_start(PAIR_STUDIO, PAIR_SECRET, dir.c_str(), -1, "");
  spit(take, wav_head(0));
  direct_stream(PAIR_STUDIO, rel.c_str(), take.c_str(), peer, 100);
  FILE *f = fopen(take.c_str(), "ab");
  std::string blk(480 * 6, '\0');
  unsigned x = 7;
  std::vector<std::pair<long long, double>> appended;
  std::vector<double> lag;
  size_t matched = 0;
  long long end = 44;
  const double t0 = now_ms();
  for (int b = 0; b < secs * 100; ++b) {
    while (now_ms() < t0 + b * 10.0) { // (real time: 10 ms a block), meanwhile what the other computer has acknowledged
      const std::string s = direct_streams();
      const size_t at = s.find("\"sent\":");
      const long long sent = at == std::string::npos ? 0 : atoll(s.c_str() + at + 7);
      while (matched < appended.size() && appended[matched].first <= sent) { lag.push_back(now_ms() - appended[matched].second); ++matched; }
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    for (char &c : blk) { x = x * 1103515245u + 12345u; c = (char)(x >> 16); }
    fwrite(blk.data(), 1, blk.size(), f);
    fflush(f);
    end += (long long)blk.size();
    appended.push_back({ end, now_ms() });
  }
  fclose(f);
  {
    FILE *g = fopen(take.c_str(), "r+b");
    const std::string h = wav_head((unsigned)(end - 44));
    fwrite(h.data(), 1, h.size(), g);
    fclose(g);
  }
  const double te = now_ms();
  direct_stream_end(PAIR_STUDIO, rel.c_str());
  std::string s;
  while (now_ms() - te < 30000 && (s = direct_streams()).find("\"finished\":true") == std::string::npos) std::this_thread::sleep_for(std::chrono::milliseconds(2));
  printf("%.1f MB streamed in real time (%d s, 48 kHz 24-bit stereo, every 100 ms)\n", end / 1e6, secs);
  if (!lag.empty()) stats("appended -> acknowledged by the other computer", lag);
  printf("stop -> the rest, the header, done and hash-checked there: %.0f ms\n%s\n", now_ms() - te, s.c_str());
  const bool ok = s.find("\"done\":true") != std::string::npos;
  direct_shutdown();
  rm_dir(dir);
  return ok ? 0 : 1;
}

int main(int argc, char **argv)
{
#ifdef _WIN32
  WSADATA w; WSAStartup(MAKEWORD(2, 2), &w);
#endif
  if (argc >= 4 && !strcmp(argv[1], "connect")) return connect_times(argv[2], argv[3], argc > 4 ? atoi(argv[4]) : 20);
  if (argc >= 4 && !strcmp(argv[1], "listen")) return listen_for(atoi(argv[2]), atoi(argv[3]));
  if (argc >= 4 && !strcmp(argv[1], "send")) return send_to(argv[2], atoi(argv[3]));
  if (argc >= 4 && !strcmp(argv[1], "clock")) return clock_to(argv[2], atoi(argv[3]));
  if (argc >= 4 && !strcmp(argv[1], "stream")) return stream_to(argv[2], atoi(argv[3]));

  // SHA-256 (FIPS 180-2 "abc"; and two blocks) and HMAC-SHA256 (RFC 4231 test cases 2 and 6: a key longer than a block)
  unsigned char h[32];
  direct_sha256((const unsigned char *)"abc", 3, h);
  CHECK(hex(h, 32) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 abc");
  const char *two = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
  direct_sha256((const unsigned char *)two, strlen(two), h);
  CHECK(hex(h, 32) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "SHA-256 two blocks");
  const char *msg = "what do ya want for nothing?";
  direct_hmac_sha256((const unsigned char *)"Jefe", 4, (const unsigned char *)msg, strlen(msg), h);
  CHECK(hex(h, 32) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "HMAC-SHA256 RFC 4231 case 2");
  std::string k131(131, '\xaa');
  const char *m6 = "Test Using Larger Than Block-Size Key - Hash Key First";
  direct_hmac_sha256((const unsigned char *)k131.data(), k131.size(), (const unsigned char *)m6, strlen(m6), h);
  CHECK(hex(h, 32) == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54", "HMAC-SHA256 RFC 4231 case 6 (long key)");

  // The path rule
  CHECK(direct_path_ok("Nostalgia/rooms/main/events/James-20261117-020433Z-00036-1979.json"), "an event's path passes");
  CHECK(direct_path_ok("Cross Test/rooms/side 2/events/Chilio_Mac-20261117-020433Z-00001-0001.json"), "spaces in song and room pass");
  const char *bad[] = { "../rooms/main/events/a.json", "S/rooms/../events/a.json", "S/rooms/main/events/../a.json", "/S/rooms/main/events/a.json",
                        "C:/S/rooms/main/events/a.json", "S\\x/rooms/main/events/a.json", "S/rooms/main/claims/a.json", "S/rooms/main/events/a.txt",
                        "S/rooms/main/events/a b.json", "S/rooms/main/events/.json", ".hidden/rooms/main/events/a.json", "S/rooms/main/events/sub/a.json",
                        "_band/band.json", "S/rooms/main/events/a.json.", "S./rooms/main/events/a.json", "S/rooms/ma:in/events/a.json", "" };
  bool all_bad = true;
  for (const char *b : bad) if (direct_path_ok(b)) { printf("     passed but shouldn't: %s\n", b); all_bad = false; }
  CHECK(all_bad, "every bad path is refused");

  // Listener and sender on localhost
  char tmpl[256];
#ifdef _WIN32
  const char *tmp = getenv("TEMP");
  snprintf(tmpl, sizeof tmpl, "%s/ss_direct_test_%u", tmp ? tmp : ".", (unsigned)GetCurrentProcessId());
  CreateDirectoryA(tmpl, nullptr);
#else
  snprintf(tmpl, sizeof tmpl, "/tmp/ss_direct_test_%u", (unsigned)getpid());
  mkdir(tmpl, 0755);
#endif
  const std::string dir = tmpl, inbox = dir + "/inbox", studio = "studiosync-test", secret = "0123456789abcdef01234567";
  const int port = 47391;
  CHECK(direct_start(studio.c_str(), secret.c_str(), inbox.c_str(), port, "127.0.0.1") == 1, "listening on 127.0.0.1");
  printf("     status: %s\n", direct_status());
  char peer[64]; snprintf(peer, sizeof peer, "127.0.0.1:%d", port);

  std::string body = "{\"format\":3,\"id\":\"James-20261119-120000Z-00001-0001\",\"type\":\"obj\",\"user\":\"James\",\"pad\":\"";
  body += std::string(300, 'x') + "\"}";
  const std::string src = dir + "/event.json", rel = "Song A/rooms/main/events/James-20261119-120000Z-00001-0001.json";
  spit(src, body);
  int seq = 0;
  CHECK(direct_send(studio.c_str(), rel.c_str(), src.c_str(), peer) == 1, "a send is queued");
  std::string got = wait_poll(seq, 3000);
  CHECK(!got.empty() && got.find(rel) != std::string::npos, "poll hands back what arrived");
  if (!got.empty()) seq = atoi(got.c_str());
  CHECK(slurp(inbox + "/" + rel) == body, "the file arrived intact in the inbox");
  CHECK(direct_send(studio.c_str(), "../x.json", src.c_str(), peer) == 0, "a bad path isn't even queued");

  // Timings: send -> it's in the inbox and polled (one way, file written), and the sender's own ack round trip
  std::vector<double> one_way, acks;
  for (int i = 0; i < 200; ++i) {
    char r[160]; snprintf(r, sizeof r, "Song A/rooms/main/events/James-20261119-120000Z-%05d-0002.json", i);
    const double t0 = now_ms();
    direct_send(studio.c_str(), r, src.c_str(), peer);
    const std::string g = wait_poll(seq, 3000);
    if (g.empty()) { printf("     lost %d\n", i); continue; }
    one_way.push_back(now_ms() - t0);
    seq = atoi(g.c_str());
    std::this_thread::sleep_for(std::chrono::milliseconds(2)); // (the ack is noted just after the receiver's write)
    const char *st = direct_status(), *ms = strstr(st, "\"ms\":");
    if (ms) acks.push_back(atof(ms + 5));
  }
  CHECK(one_way.size() == 200, "200 sends all arrived");
  stats("send -> in the inbox and polled (localhost)", one_way);
  stats("sender's send -> answer round trip (localhost)", acks);
  // and a 1 MB file
  std::string big(1024 * 1024, 'b');
  spit(src, big);
  const double tb = now_ms();
  direct_send(studio.c_str(), "Song A/rooms/main/events/James-20261119-120000Z-99999-0003.json", src.c_str(), peer);
  std::string gb = wait_poll(seq, 5000);
  printf("     a 1 MB file: %.2f ms\n", now_ms() - tb);
  CHECK(!gb.empty() && slurp(inbox + "/Song A/rooms/main/events/James-20261119-120000Z-99999-0003.json") == big, "a 1 MB file arrives intact");
  if (!gb.empty()) seq = atoi(gb.c_str());

  // Refusals: nothing written, the right answer byte
  const std::string key = direct_derive_key(secret), other = direct_derive_key("someone else's secret");
  const std::string r1 = "Song A/rooms/main/events/Eve-20261119-120000Z-00001-0001.json";
  CHECK(raw(port, direct_frame(other, studio, r1, "{}")) == 3 && !exists(inbox + "/" + r1), "a bad signature is refused (3), nothing written");
  CHECK(raw(port, direct_frame(key, "studiosync-other", r1, "{}")) == 3, "an unknown studio is refused (3)");
  std::string tampered = direct_frame(key, studio, r1, "{\"a\":1}");
  tampered[12 + studio.size() + r1.size() + 6] = '2';
  CHECK(raw(port, tampered) == 3 && !exists(inbox + "/" + r1), "a file changed on the way is refused (3)");
  CHECK(raw(port, direct_frame(key, studio, "Song A/rooms/main/events/../../../escape.json", "{}")) == 4 && !exists(dir + "/escape.json") && !exists(inbox + "/escape.json"),
        "a path out of the inbox, correctly signed, is refused (4), nothing written");
  CHECK(raw(port, direct_frame(key, studio, "_band/band.json", "{}")) == 4 && !exists(inbox + "/_band/band.json"), "a non-event path is refused (4)");
  std::string huge = "SSD1";
  auto p16 = [&](size_t v) { huge += (char)(v >> 8); huge += (char)(v & 255); };
  p16(studio.size()); p16(r1.size()); p16((5u * 1024 * 1024) >> 16); p16((5u * 1024 * 1024) & 0xffff);
  huge += studio + r1;
  CHECK(raw(port, huge) == 5, "a 5 MB file is refused from its header (5), before it's read");
  CHECK(raw(port, std::string("HTTP/1.1 GET /\r\n\r\n")) == 1, "something that isn't StudioSync's is refused (1)");
  CHECK(raw(port, direct_frame(key, studio, r1, "{\"ok\":1}")) == 0 && exists(inbox + "/" + r1), "and a good frame by hand is kept (0)");
  printf("     status: %s\n", direct_status());

  // A peer that isn't there: refused quickly, and skipped for a while after
  const double tp = now_ms();
  direct_send(studio.c_str(), rel.c_str(), src.c_str(), "127.0.0.1:47392");
  std::this_thread::sleep_for(std::chrono::milliseconds(1700));
  const std::string st = direct_status();
  CHECK(st.find("\"127.0.0.1:47392\":{\"ok\":false") != std::string::npos, "a peer that isn't listening shows as not ok");
  printf("     (%.0f ms later) %s\n", now_ms() - tp, st.c_str());
  CHECK(direct_send(studio.c_str(), rel.c_str(), src.c_str(), "8.8.8.8:47281") == 1, "queued to an address off Tailscale...");
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  CHECK(std::string(direct_status()).find("\"8.8.8.8:47281\":{\"ok\":false,\"ms\":-1.0,\"at\":") != std::string::npos &&
        std::string(direct_status()).find("isn't on Tailscale") != std::string::npos, "...but never connected to");

  live_layer_tests(studio, secret, key, port, peer, inbox, dir);
  audio_tests(dir);

  direct_shutdown();
  CHECK(std::string(direct_status()).find("\"listening\":false") != std::string::npos, "shut down");
#ifdef _WIN32
  std::string wdir = dir;
  std::replace(wdir.begin(), wdir.end(), '/', '\\');
  system((std::string("rmdir /s /q \"") + wdir + "\"").c_str());
#else
  system((std::string("rm -rf '") + dir + "'").c_str());
#endif
  printf(fails ? "fails %d\n" : "ok, fails 0\n", fails);
  return fails ? 1 : 0;
}
