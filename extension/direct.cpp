// StudioSync's direct link (docs/direct-link-design.md, 0.59.50): each new event file goes straight to the studio's other computers over
// Tailscale, so it lands in well under a second; Syncthing still carries it and its copy is the record. A listener thread (bound only to
// this computer's Tailscale address) writes what arrives into an inbox outside the shared folder; a sender thread keeps one connection
// per peer. Neither thread touches REAPER's API: the ReaScript functions at the end only queue, copy and read under a lock.
// Frame: "SSD1", u16 studio, u16 path, u32 data (big-endian), the three, then HMAC-SHA256(key, all of that). Answer: one byte, 0 = kept.
// 1.0.8 (docs/realtime-roadmap.md steps 1-2): the same frame with "SSM1" (a small message: path = its kind), "SSP1" (a ping for the shared
// clock, answered with two times and a signature) and "SSS1" (a piece of a file that's still being written: a take streamed as it records).
// Socket patterns as tools/ninjam-relay/njrelay.c. GPL-3.0-or-later.
#ifdef _WIN32
#define NOMINMAX // (windows.h's min and max macros would hide std::min and std::max)
#include <winsock2.h> // (before windows.h, which reaper_plugin.h brings: windows.h alone pulls the old winsock.h in)
#include <ws2tcpip.h>
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#include <share.h>
typedef SOCKET sock_t;
#define BAD_SOCK INVALID_SOCKET
#define close_sock closesocket
#define poll_socks WSAPoll
#define SEND_FLAGS 0
#else
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
typedef int sock_t;
#define BAD_SOCK (-1)
#define close_sock close
#define poll_socks poll
#ifdef MSG_NOSIGNAL
#define SEND_FLAGS MSG_NOSIGNAL // (Linux: a peer gone mid-send raises SIGPIPE, which would end REAPER)
#else
#define SEND_FLAGS 0 // (macOS: SO_NOSIGPIPE on each socket instead)
#endif
#endif
#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <random>
#include <thread>
#include <vector>
#include "direct.h"

// ---- SHA-256 and HMAC ------------------------------------------------------------------------------------------------------------------
// SHA-256 after Brad Conte's crypto-algorithms sha256.c (public domain, github.com/B-Con/crypto-algorithms), HMAC as RFC 2104.
namespace {
struct Sha256 { unsigned char data[64]; unsigned int datalen = 0; unsigned long long bitlen = 0; unsigned int state[8]; };
const unsigned int K256[64] = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be,
  0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa,
  0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85,
  0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f,
  0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2 };
inline unsigned int rotr(unsigned int a, int b) { return (a >> b) | (a << (32 - b)); }
void sha_transform(Sha256 &c, const unsigned char *d)
{
  unsigned int m[64], a, b, cc, dd, e, f, g, h, t1, t2;
  for (int i = 0, j = 0; i < 16; ++i, j += 4) m[i] = (d[j] << 24) | (d[j + 1] << 16) | (d[j + 2] << 8) | d[j + 3];
  for (int i = 16; i < 64; ++i) {
    const unsigned int s0 = rotr(m[i - 15], 7) ^ rotr(m[i - 15], 18) ^ (m[i - 15] >> 3);
    const unsigned int s1 = rotr(m[i - 2], 17) ^ rotr(m[i - 2], 19) ^ (m[i - 2] >> 10);
    m[i] = m[i - 16] + s0 + m[i - 7] + s1;
  }
  a = c.state[0]; b = c.state[1]; cc = c.state[2]; dd = c.state[3]; e = c.state[4]; f = c.state[5]; g = c.state[6]; h = c.state[7];
  for (int i = 0; i < 64; ++i) {
    t1 = h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K256[i] + m[i];
    t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & cc) ^ (b & cc));
    h = g; g = f; f = e; e = dd + t1; dd = cc; cc = b; b = a; a = t1 + t2;
  }
  c.state[0] += a; c.state[1] += b; c.state[2] += cc; c.state[3] += dd; c.state[4] += e; c.state[5] += f; c.state[6] += g; c.state[7] += h;
}
void sha_init(Sha256 &c)
{
  static const unsigned int iv[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
  c.datalen = 0; c.bitlen = 0;
  memcpy(c.state, iv, sizeof(iv));
}
void sha_update(Sha256 &c, const unsigned char *d, size_t len)
{
  for (size_t i = 0; i < len; ++i) {
    c.data[c.datalen++] = d[i];
    if (c.datalen == 64) { sha_transform(c, c.data); c.bitlen += 512; c.datalen = 0; }
  }
}
void sha_final(Sha256 &c, unsigned char out[32])
{
  unsigned int i = c.datalen;
  c.data[i++] = 0x80;
  if (c.datalen >= 56) { while (i < 64) c.data[i++] = 0; sha_transform(c, c.data); i = 0; }
  while (i < 56) c.data[i++] = 0;
  c.bitlen += (unsigned long long)c.datalen * 8;
  for (int k = 0; k < 8; ++k) c.data[63 - k] = (unsigned char)(c.bitlen >> (8 * k));
  sha_transform(c, c.data);
  for (int k = 0; k < 8; ++k) for (int j = 0; j < 4; ++j) out[k * 4 + j] = (unsigned char)(c.state[k] >> (24 - 8 * j));
}
} // namespace

void direct_sha256(const unsigned char *msg, size_t len, unsigned char out[32])
{
  Sha256 c; sha_init(c); sha_update(c, msg, len); sha_final(c, out);
}
void direct_hmac_sha256(const unsigned char *key, size_t klen, const unsigned char *msg, size_t mlen, unsigned char out[32])
{
  unsigned char k[64] = { 0 }, pad[64], inner[32];
  if (klen > 64) direct_sha256(key, klen, k); else memcpy(k, key, klen);
  Sha256 c;
  for (int i = 0; i < 64; ++i) pad[i] = k[i] ^ 0x36;
  sha_init(c); sha_update(c, pad, 64); sha_update(c, msg, mlen); sha_final(c, inner);
  for (int i = 0; i < 64; ++i) pad[i] = k[i] ^ 0x5c;
  sha_init(c); sha_update(c, pad, 64); sha_update(c, inner, 32); sha_final(c, out);
}
std::string direct_derive_key(const std::string &secret)
{
  static const char label[] = "StudioSync direct v1";
  unsigned char out[32];
  direct_hmac_sha256((const unsigned char *)secret.data(), secret.size(), (const unsigned char *)label, sizeof(label) - 1, out);
  return std::string((const char *)out, 32);
}
static void put16(std::string &s, size_t v) { s += (char)((v >> 8) & 255); s += (char)(v & 255); }
static void put32(std::string &s, size_t v) { put16(s, (v >> 16) & 0xffff); put16(s, v & 0xffff); }
std::string direct_frame(const std::string &key, const std::string &studio, const std::string &rel, const std::string &data, const char *magic)
{
  std::string f(magic, 4);
  put16(f, studio.size()); put16(f, rel.size()); put32(f, data.size());
  f += studio; f += rel; f += data;
  unsigned char mac[32];
  direct_hmac_sha256((const unsigned char *)key.data(), key.size(), (const unsigned char *)f.data(), f.size(), mac);
  f.append((const char *)mac, 32);
  return f;
}

// ---- paths and files -------------------------------------------------------------------------------------------------------------------
// Only "<song>/rooms/<room>/events/<name>.json": song and room plain folder names, the name an event id. Nothing else ever lands here.
static bool seg_ok(const std::string &s)
{
  if (s.empty() || s.size() > 200 || s[0] == '.' || s.back() == '.' || s.back() == ' ') return false;
  for (unsigned char c : s) if (c < 0x20 || c == 0x7f || strchr("/\\:*?\"<>|", c)) return false;
  return true;
}
bool direct_path_ok(const char *rel)
{
  if (!rel) return false;
  const std::string r(rel);
  if (r.size() > 512) return false;
  std::vector<std::string> parts;
  size_t at = 0;
  for (;;) {
    const size_t sl = r.find('/', at);
    parts.push_back(r.substr(at, sl == std::string::npos ? std::string::npos : sl - at));
    if (sl == std::string::npos) break;
    at = sl + 1;
  }
  if (parts.size() != 5 || !seg_ok(parts[0]) || parts[1] != "rooms" || !seg_ok(parts[2]) || parts[3] != "events") return false;
  const std::string &n = parts[4];
  if (n.size() < 6 || n.size() > 200 || n.compare(n.size() - 5, 5, ".json") != 0) return false;
  for (size_t i = 0; i + 5 < n.size(); ++i) {
    const char c = n[i];
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_')) return false;
  }
  return true;
}

#ifdef _WIN32
static std::wstring widen(const std::string &s)
{
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  std::wstring w(n > 0 ? n : 1, L'\0');
  if (n > 0) MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], n);
  w.resize(wcslen(w.c_str()));
  return w;
}
static bool file_exists(const std::string &p) { return GetFileAttributesW(widen(p).c_str()) != INVALID_FILE_ATTRIBUTES; }
static void make_dir(const std::string &p) { CreateDirectoryW(widen(p).c_str(), nullptr); }
static FILE *open_file(const std::string &p, const char *mode) { return _wfopen(widen(p).c_str(), mode[0] == 'r' ? L"rb" : L"wb"); }
static bool move_new(const std::string &a, const std::string &b) { return MoveFileExW(widen(a).c_str(), widen(b).c_str(), 0) != 0; }
static void remove_file(const std::string &p) { DeleteFileW(widen(p).c_str()); }
#else
static bool file_exists(const std::string &p) { struct stat st; return stat(p.c_str(), &st) == 0; }
static void make_dir(const std::string &p) { mkdir(p.c_str(), 0755); }
static FILE *open_file(const std::string &p, const char *mode) { return fopen(p.c_str(), mode[0] == 'r' ? "rb" : "wb"); }
static bool move_new(const std::string &a, const std::string &b) { return rename(a.c_str(), b.c_str()) == 0; }
static void remove_file(const std::string &p) { unlink(p.c_str()); }
#endif
static void make_dirs(const std::string &dir) // every folder down to `dir` (errors ignored: the write after says)
{
  for (size_t i = 1; i <= dir.size(); ++i)
    if (i == dir.size() || dir[i] == '/' || dir[i] == '\\') { if (dir[i - 1] != ':') make_dir(dir.substr(0, i)); }
}
static std::atomic<unsigned> g_tmp_n{ 0 };
// Write-once: a file that's there already is kept as it is. Through a temporary name and a rename, so nobody reads half of one.
static bool write_atomic(const std::string &path, const char *data, size_t len)
{
  if (file_exists(path)) return true;
  const size_t sl = path.find_last_of("/\\");
  if (sl != std::string::npos) make_dirs(path.substr(0, sl));
  char suffix[48];
  snprintf(suffix, sizeof(suffix), ".part%u-%u", (unsigned)std::chrono::steady_clock::now().time_since_epoch().count(), ++g_tmp_n);
  const std::string tmp = path + suffix;
  FILE *f = open_file(tmp, "w");
  if (!f) return false;
  const bool ok = fwrite(data, 1, len, f) == len;
  if (fclose(f) != 0 || !ok) { remove_file(tmp); return false; }
  if (!move_new(tmp, path)) { remove_file(tmp); return file_exists(path); } // (another copy got there first: as good)
  return true;
}
static bool read_file(const std::string &path, std::string &out)
{
  FILE *f = open_file(path, "r");
  if (!f) return false;
  out.clear();
  char buf[65536];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
    out.append(buf, n);
    if (out.size() > DIRECT_MAX_DATA) break;
  }
  fclose(f);
  return out.size() <= DIRECT_MAX_DATA;
}

// 1.0.8: a stream's file, opened alongside whoever else has it: REAPER writing the take, REAPER reading the received copy. Windows: share
// read, write and delete, so neither blocks the other (nor REAPER deleting a take it discards). mode "rb", "r+b" or "w+b".
#ifdef _WIN32
static FILE *open_shared(const std::string &p, const char *mode)
{
  const bool w = mode[0] == 'w', rw = w || mode[1] == '+';
  HANDLE h = CreateFileW(widen(p).c_str(), GENERIC_READ | (rw ? GENERIC_WRITE : 0), FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                         nullptr, w ? CREATE_ALWAYS : OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) return nullptr;
  const int fd = _open_osfhandle((intptr_t)h, (rw ? _O_RDWR : _O_RDONLY) | _O_BINARY);
  if (fd < 0) { CloseHandle(h); return nullptr; }
  FILE *f = _fdopen(fd, rw ? "r+b" : "rb");
  if (!f) _close(fd);
  return f;
}
static int seek64(FILE *f, long long at) { return _fseeki64(f, at, SEEK_SET); }
static long long size64(FILE *f) { return _fseeki64(f, 0, SEEK_END) == 0 ? _ftelli64(f) : -1; }
#else
static FILE *open_shared(const std::string &p, const char *mode) { return fopen(p.c_str(), mode); }
static int seek64(FILE *f, long long at) { return fseeko(f, (off_t)at, SEEK_SET); }
static long long size64(FILE *f) { return fseeko(f, 0, SEEK_END) == 0 ? (long long)ftello(f) : -1; }
#endif
// (the size from an open handle: NTFS's directory entry, what stat, Explorer and Get-Item read, lags behind a file someone has open for
// writing. On Windows a handle asking only for its attributes: no share mode can refuse that, whatever REAPER's writer allows. James, rt)
#ifdef _WIN32
static std::string win_err(const char *what)
{
  const DWORD e = GetLastError();
  char b[160];
  snprintf(b, sizeof b, "%s (Windows error %lu%s)", what, (unsigned long)e, e == ERROR_SHARING_VIOLATION ? ": REAPER holds it without letting others read" : e == ERROR_FILE_NOT_FOUND || e == ERROR_PATH_NOT_FOUND ? ": not there" : "");
  return b;
}
// (REAPER recording: the laptop's copy sat at 64 KB on a direct LAN path while Git-bash's stat saw the desktop's take grow in 256 KB steps,
// and the stream's own size stayed small. So the size is asked every way there is and the largest taken: FILE_STANDARD_INFO and
// GetFileSizeEx on a handle asking only for attributes (no share mode refuses it), GetFileSizeEx on a reading handle (what read_some uses),
// and the folder entry (what Explorer, Get-Item and stat read; NTFS updates it lazily for a file someone has open). `how` says what each said,
// for the stream trace. James, rt)
static long long file_size(const std::string &p, std::string *why = nullptr, std::string *how = nullptr)
{
  const std::wstring w = widen(p);
  long long standard = -1, attr = -1, reading = -1, folder = -1;
  HANDLE a = CreateFileW(w.c_str(), FILE_READ_ATTRIBUTES | SYNCHRONIZE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  const std::string a_err = a == INVALID_HANDLE_VALUE ? win_err("can't see the file") : "";
  if (a != INVALID_HANDLE_VALUE) {
    FILE_STANDARD_INFO si;
    if (GetFileInformationByHandleEx(a, FileStandardInfo, &si, sizeof si)) standard = (long long)si.EndOfFile.QuadPart;
    LARGE_INTEGER n;
    if (GetFileSizeEx(a, &n)) attr = (long long)n.QuadPart;
    CloseHandle(a);
  }
  HANDLE r = CreateFileW(w.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  const std::string r_err = r == INVALID_HANDLE_VALUE ? win_err("can't open it to read") : "";
  if (r != INVALID_HANDLE_VALUE) {
    LARGE_INTEGER n;
    if (GetFileSizeEx(r, &n)) reading = (long long)n.QuadPart;
    CloseHandle(r);
  }
  WIN32_FIND_DATAW fd;
  HANDLE f = FindFirstFileW(w.c_str(), &fd);
  if (f != INVALID_HANDLE_VALUE) { folder = ((long long)fd.nFileSizeHigh << 32) | fd.nFileSizeLow; FindClose(f); }
  const long long best = std::max(std::max(standard, attr), std::max(reading, folder));
  if (how) {
    char b[200];
    snprintf(b, sizeof b, "standard=%lld attr=%lld read=%lld folder=%lld", standard, attr, reading, folder);
    *how = b;
    if (!a_err.empty()) *how += " [" + a_err + "]";
    if (!r_err.empty()) *how += " [" + r_err + "]";
  }
  if (best < 0 && why) *why = !a_err.empty() ? a_err : "can't read the file's size";
  return best;
}
#else
static long long file_size(const std::string &p, std::string *why = nullptr, std::string *how = nullptr)
{
  FILE *f = open_shared(p, "rb");
  if (!f) { if (why) *why = std::string("can't open the file (") + strerror(errno) + ")"; return -1; }
  const long long n = size64(f);
  fclose(f);
  if (how) *how = "seek-end=" + std::to_string(n);
  return n;
}
#endif
// A file's newest time, made or last written (lib/streams.lua: is this file the take REAPER began just now? No API names it before stop. James, rt)
double direct_file_time(const char *path)
{
  if (!path || !*path) return -1;
#ifdef _WIN32
  HANDLE h = CreateFileW(widen(path).c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) return -1;
  FILETIME made, wrote;
  const bool ok = GetFileTime(h, &made, nullptr, &wrote) != 0;
  CloseHandle(h);
  if (!ok) return -1;
  auto secs = [](const FILETIME &t) { return (double)((((unsigned long long)t.dwHighDateTime << 32) | t.dwLowDateTime) - 116444736000000000ULL) / 1e7; };
  return std::max(secs(made), secs(wrote));
#else
  struct stat st;
  if (stat(path, &st) != 0) return -1;
  return (double)std::max(st.st_mtime, st.st_ctime);
#endif
}
long long direct_file_size(const char *path, std::string *how) { return path ? file_size(path, nullptr, how) : -1; }
// Up to n bytes at `at`: -> how many were read (fewer near the end, or where a writer hasn't got to yet), -1 if it can't be opened (why).
static long long read_some(const std::string &p, long long at, size_t n, std::string &out, std::string *why = nullptr)
{
  FILE *f = open_shared(p, "rb");
  if (!f) {
#ifdef _WIN32
    if (why) *why = win_err("can't open the file to read it");
#else
    if (why) *why = std::string("can't open the file to read it (") + strerror(errno) + ")";
#endif
    out.clear();
    return -1;
  }
  out.resize(n);
  const size_t got = n == 0 || seek64(f, at) != 0 ? 0 : fread(&out[0], 1, n, f);
  fclose(f);
  out.resize(got);
  return (long long)got;
}
static bool read_at(const std::string &p, long long at, size_t n, std::string &out) { return read_some(p, at, n, out) == (long long)n; }
// SHA-256 of a file's first `len` bytes (-> false: shorter, or unreadable).
static bool sha_file(FILE *f, long long len, unsigned char out[32])
{
  if (seek64(f, 0) != 0) return false;
  Sha256 c; sha_init(c);
  std::vector<unsigned char> buf(1 << 16);
  for (long long left = len; left > 0;) {
    const size_t want = (size_t)std::min<long long>(left, (long long)buf.size());
    if (fread(buf.data(), 1, want, f) != want) return false;
    sha_update(c, buf.data(), want);
    left -= (long long)want;
  }
  sha_final(c, out);
  return true;
}

// Only "<song>/<name>.<an extension on the list>": the song a plain folder name, the name a plain file name. The list: audio and MIDI, and
// (1.0.12, "send anything") the other files a studio passes round: video references, PDF charts, pictures, notes, plug-in presets and patches
// (Neural Amp Modeler, SFZ; impulse responses are WAVs), Ableton sets, zips. Never anything that runs: no exe, dll, dylib, so, lua, py, sh,
// bat, cmd, ps1, js (they're simply not on it; lib/direct.lua STREAM_EXT says the same. James, rt)
bool direct_stream_rel_ok(const char *rel)
{
  if (!rel) return false;
  const std::string r(rel);
  const size_t sl = r.find('/');
  if (r.size() > 512 || sl == std::string::npos || !seg_ok(r.substr(0, sl))) return false;
  const std::string name = r.substr(sl + 1);
  const size_t dot = name.rfind('.');
  if (!seg_ok(name) || dot == std::string::npos) return false;
  std::string ext = name.substr(dot + 1);
  for (char &c : ext) c = (char)tolower((unsigned char)c);
  static const char *ok[] = { "wav", "w64", "flac", "aif", "aiff", "ogg", "opus", "mp3", "mid", "mp4", "mov", "webm", "pdf", "png", "jpg", "jpeg",
                              "txt", "md", "fxp", "fxb", "vstpreset", "nam", "sfz", "als", "zip" };
  for (const char *e : ok) if (ext == e) return true;
  return false;
}

// A WAV's layout from its first bytes: the chunks up to "data" (whose own size is a placeholder while it's recorded).
bool direct_wav_layout(const std::string &h, long long &data_off, int &block_align, bool &rf64, long long &ds64_off)
{
  if (h.size() < 12 || (h.compare(0, 4, "RIFF") != 0 && h.compare(0, 4, "RF64") != 0) || h.compare(8, 4, "WAVE") != 0) return false;
  rf64 = h.compare(0, 4, "RF64") == 0;
  ds64_off = -1;
  block_align = 0;
  auto le32 = [&](size_t at) { return (unsigned)(unsigned char)h[at] | ((unsigned)(unsigned char)h[at + 1] << 8) | ((unsigned)(unsigned char)h[at + 2] << 16) | ((unsigned)(unsigned char)h[at + 3] << 24); };
  for (size_t at = 12; at + 8 <= h.size();) {
    const std::string id = h.substr(at, 4);
    const unsigned sz = le32(at + 4);
    if (id == "data") { data_off = (long long)at + 8; return block_align > 0 && (!rf64 || ds64_off >= 0); }
    if (id == "fmt " && at + 22 <= h.size()) block_align = (unsigned char)h[at + 20] | ((unsigned char)h[at + 21] << 8);
    if (id == "ds64") ds64_off = (long long)at + 8;
    at += 8 + (size_t)sz + (sz & 1);
  }
  return false;
}

// ---- sockets ---------------------------------------------------------------------------------------------------------------------------
static bool tailnet_v4(unsigned a, unsigned b) { return a == 100 && b >= 64 && b <= 127; } // 100.64.0.0/10
static bool addr_ok(const sockaddr_in &sa, bool loopback_ok)
{
  const unsigned char *p = (const unsigned char *)&sa.sin_addr;
  return tailnet_v4(p[0], p[1]) || (loopback_ok && p[0] == 127);
}
static void set_nonblock(sock_t s, bool on)
{
#ifdef _WIN32
  u_long v = on ? 1 : 0;
  ioctlsocket(s, FIONBIO, &v);
#else
  const int fl = fcntl(s, F_GETFL, 0);
  fcntl(s, F_SETFL, on ? (fl | O_NONBLOCK) : (fl & ~O_NONBLOCK));
#endif
}
void direct_noinherit(unsigned long long s)
{
#ifdef _WIN32
  SetHandleInformation((HANDLE)(uintptr_t)s, HANDLE_FLAG_INHERIT, 0);
#else
  fcntl((int)s, F_SETFD, FD_CLOEXEC);
#endif
}
static void set_timeouts(sock_t s, int ms)
{
#ifdef _WIN32
  DWORD v = (DWORD)ms;
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&v, sizeof(v));
  setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char *)&v, sizeof(v));
#else
  timeval tv = { ms / 1000, (ms % 1000) * 1000 };
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
#endif
}
static void no_sigpipe(sock_t s)
{
#ifdef SO_NOSIGPIPE
  int one = 1;
  setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#else
  (void)s;
#endif
}
static void no_delay(sock_t s) { int one = 1; setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&one, sizeof(one)); }
static bool send_all(sock_t s, const char *p, size_t n)
{
  while (n > 0) {
    const int k = (int)send(s, p, (int)(n > 65536 ? 65536 : n), SEND_FLAGS);
    if (k <= 0) return false;
    p += k; n -= (size_t)k;
  }
  return true;
}
// This computer's Tailscale address: where a UDP socket "connected" to Tailscale's own 100.100.100.100 would send from. Nothing is sent.
static std::string tailscale_ip(std::string &why)
{
  sock_t s = socket(AF_INET, SOCK_DGRAM, 0);
  if (s == BAD_SOCK) { why = "no socket"; return ""; }
  direct_noinherit(s);
  sockaddr_in to = {};
  to.sin_family = AF_INET;
  to.sin_port = htons(53);
  inet_pton(AF_INET, "100.100.100.100", &to.sin_addr);
  sockaddr_in me = {};
  socklen_t len = sizeof(me);
  std::string ip;
  if (connect(s, (sockaddr *)&to, sizeof(to)) == 0 && getsockname(s, (sockaddr *)&me, &len) == 0 && addr_ok(me, false)) {
    char buf[64];
    inet_ntop(AF_INET, &me.sin_addr, buf, sizeof(buf));
    ip = buf;
  } else why = "Tailscale isn't up here (no 100.64.0.0/10 address)";
  close_sock(s);
  return ip;
}

// ---- state -----------------------------------------------------------------------------------------------------------------------------
namespace {
struct Studio { std::string key, inbox; };
struct Got { int seq; std::string studio, rel; };
struct Msg { int seq; std::string studio, kind, data; };
struct Job { std::string studio, rel, data; std::vector<std::string> peers; }; // an event file (messages go by their peer's Lane)
// (a peer's messages: their own thread and connection, frames pipelined. They were jobs on the one send thread, each waiting for every peer's
// answer in turn behind pings, files and streams: 3 peers at 0.5 + 84 + 100 ms took ~190 ms a message, a fader's 13 a second queued up to 44
// deep and a 3 s ramp showed over 9 s on the laptop. Now a message goes as soon as it's queued, up to MSG_WINDOW unanswered; `busy` while a
// peer's window is full, so shared controllers hold their latest values instead of queueing old ones. James, rt)
struct Lane {
  std::thread thr; std::deque<std::pair<std::string, std::string>> q; std::condition_variable cv; bool stop = false, busy = false; // q: studio, frame
  bool ok = false; double ms = -1; long long at = 0, sent = 0; std::string err; // (Health's: the last answer's, or the failure's)
};
struct Sample { double offset_us, rtt_us; };
struct Peer {
  sock_t s = BAD_SOCK; bool ok = false; double ms = -1; std::string err; long long at = 0, sent = 0; double retry_after = 0;
  // the clock (1.0.8): the last pings' samples, and the estimate from the lowest round trips among them
  double next_ping = 0; int pings = 0; std::deque<Sample> samples; double offset_ms = 0, rtt_ms = -1, spread_ms = 0; long long clock_at = 0; std::string clock_err;
  // link speed (1.0.12): stream frames in flight, the rate the last streams were answered at (bytes/s), the quickest frame round trip seen
  int window = 0; double rate = 0, frame_rtt_ms = -1, quick_ms = -1, quick_at = 0; long long rate_at = 0; // (quick: a small frame's round trip, and when)
};
struct OutPeer { long long off = 0; bool begun = false, done = false; int resends = 0; size_t chunk = 0; std::string err; }; // (chunk: 0 = STREAM_CHUNK)
struct OutStream {
  std::string studio, rel, path, err; std::map<std::string, OutPeer> peers; int interval_ms = 250, codec = 0; bool ended = false; // (codec 0 only, for now; err: reading it here)
  double next_at = 0, finished_at = 0; long long size = 0, sha_len = -1; unsigned char sha[32] = { 0 };
};
struct InStream {
  std::string studio, rel, path; FILE *f = nullptr; // (f: only the listener thread uses it)
  long long len = 0, total = -1, data_off = -1, ds64_off = -1; int block_align = 0, codec = 0; bool rf64 = false, finalizing = false, done = false, ok = false; long long at = 0;
  std::string held; // (the file's start while it isn't yet a WAV header worth showing: zeros on disk meanwhile. wav_append)
};
struct Conn { sock_t s; std::vector<char> buf; double last; };

std::mutex g_mx; // guards everything below but the sockets and stream files, which only their own thread touches
std::map<std::string, Studio> g_studios;
std::deque<Got> g_got;
std::deque<Msg> g_msgs;
size_t g_msg_bytes = 0;
int g_seq = 0, g_msg_seq = 0;
long long g_received = 0, g_rejected = 0, g_msgs_received = 0;
std::string g_last_reject, g_listen_err, g_bind;
int g_port = 0;
bool g_listening = false, g_kick = false;
double g_next_due = 0;
std::deque<Job> g_jobs;
std::map<std::string, std::unique_ptr<Lane>> g_lanes; // peer -> its messages (a Lane lives until direct_shutdown: its thread holds it)
std::map<std::string, Peer> g_peers;
std::map<std::string, std::string> g_clock; // peer -> the studio whose key its pings are signed with
std::map<std::string, OutStream> g_out;     // "<studio>\t<rel>" -> a file being streamed
std::map<std::string, InStream> g_in;       // "<studio>\t<rel>" -> a file arriving
std::condition_variable g_cv;
std::thread g_listen_thr, g_send_thr;
// (a thread still joinable when the DLL's statics go would end the process: if REAPER exits without unloading or atexit, they're let go)
struct ExitGuard { ~ExitGuard() {
  if (g_listen_thr.joinable()) g_listen_thr.detach(); if (g_send_thr.joinable()) g_send_thr.detach();
  for (auto &kv : g_lanes) if (kv.second->thr.joinable()) { kv.second->thr.detach(); kv.second.release(); } // (released: a detached thread may still use it)
} } g_exit_guard;
std::atomic<bool> g_stop_listen{ false }, g_stop_send{ false };
sock_t g_listen_sock = BAD_SOCK;
bool g_wsa = false;
std::string g_poll_out, g_status_out, g_msg_out, g_clock_out, g_streams_out; // (what the last call handed back: REAPER copies it before the next)
std::atomic<bool> g_tracing{ false };
std::string g_trace_path; // (lib/direct.lua sets it while ExtState "stream trace" is 1: every stream pass appends a line. James, rt)
long long g_skew_us = 0; int g_delay_max_ms = 0; double g_ping_s = 1.0; int g_listen_kbps = 0, g_stream_gap_ms = 0; // (the test's knobs; 0, 0, 1 s, 0, 0 otherwise)
int g_test_rtt_ms = 0, g_test_wmax = 0; // (the test's: answers held to this round trip, the window capped; 0, 0 otherwise)

// (STREAM_CHUNK: each stream frame waits up to 3 s for its answer, so it has to cross in well under that on a slow way too. At 256 KB a
// Tailscale relay's few hundred kbit/s timed out every frame after REAPER's first 64 KB, each failure skipping the peer 10 s: the laptop's copy
// sat at 64 KB till stop. 64 KB, halved per peer after a dropped frame, down to 16 KB. James, rt)
const size_t MSG_KEEP = 512, MSG_KEEP_BYTES = 8 * 1024 * 1024, STREAM_CHUNK = 64 * 1024, STREAM_CHUNK_MIN = 16 * 1024, STREAM_HEAD = 64 * 1024;
const long long STREAM_MAX = 16LL << 30; // (a take over 16 GB isn't one)
// (WINDOW_*: stream frames in flight per peer, 1.0.12. Stop-and-wait, one 64 KB frame and then its answer, topped out near 1 MB/s at
// Tailscale's 57 ms round trip: a 20 MB catch-up took 23 s. Now several go before the first answer is back: grown while the measured rate says
// the pipe isn't full, cut to what the link carries once it is, so a slow or relayed way keeps 2-3 in flight and each answer still comes within
// one frame's crossing of the last, well inside the 3 s it may take. Halved after a dropped frame, as the frame size is. James, rt)
const int WINDOW_MIN = 2, WINDOW_START = 4, WINDOW_MAX = 32;
// (MSG_WINDOW: a peer's messages unanswered at most: 160 a second at a 100 ms round trip, 50 over a 300 ms relay, past Live sync's ~30 ticks
// with a message each. LANE_MAX: queued for one peer (its window full), else dropped; LANES_MAX: peers)
const int MSG_WINDOW = 16; const size_t LANE_MAX = 1000, LANES_MAX = 32;
const long long RATE_MIN_BYTES = 256 * 1024; // (a pass that moved less says more about the round trip than the rate)
const int CLOCK_WINDOW = 16, CLOCK_BEST = 3;

double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
long long unix_now() { return (long long)std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count(); }
// The clock pings carry: wall time (µs since 1970) when first asked, then the monotonic clock's progress. Steps in wall time (Windows
// syncing its time) never jump it, and its resolution is the high-resolution counter's (QueryPerformanceCounter under steady_clock).
long long clock_us()
{
  static const auto mono0 = std::chrono::steady_clock::now();
  static const long long wall0 = (long long)std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
  return wall0 + (long long)std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - mono0).count();
}
void reject(const char *why)
{
  std::lock_guard<std::mutex> l(g_mx);
  ++g_rejected;
  g_last_reject = why;
}
unsigned rd16(const char *p) { return ((unsigned char)p[0] << 8) | (unsigned char)p[1]; }
unsigned rd32(const char *p) { return (rd16(p) << 16) | rd16(p + 2); }
long long rd64(const char *p) { return (long long)(((unsigned long long)rd32(p) << 32) | rd32(p + 4)); }
void put64(std::string &s, long long v) { put32(s, (size_t)(((unsigned long long)v >> 32) & 0xffffffffu)); put32(s, (size_t)((unsigned long long)v & 0xffffffffu)); }
bool same_mac(const unsigned char *a, const char *b) { unsigned char d = 0; for (int i = 0; i < 32; ++i) d |= a[i] ^ (unsigned char)b[i]; return d == 0; } // (constant time)
std::string pong_mac(const std::string &key, const std::string &t0t1t2)
{
  const std::string m = "SSQ1" + t0t1t2;
  unsigned char mac[32];
  direct_hmac_sha256((const unsigned char *)key.data(), key.size(), (const unsigned char *)m.data(), m.size(), mac);
  return std::string((const char *)mac, 32);
}
bool kind_ok(const std::string &k)
{
  if (k.empty() || k.size() > 32 || k[0] < 'a' || k[0] > 'z') return false;
  for (char c : k) if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-')) return false;
  return true;
}
void sleep_ms(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

// ---- receiving a stream ----------------------------------------------------------------------------------------------------------------
// (the stream file is unbuffered, so each of these is one write that reaches the file in the order made: a reader never sees a header ahead
// of the bytes it describes. stdio flushed at its own moments before. James, rt)
static FILE *open_stream(const std::string &p, const char *mode)
{
  FILE *f = open_shared(p, mode);
  if (f) setvbuf(f, nullptr, _IONBF, 0);
  return f;
}
static bool put_at(FILE *f, long long at, const char *d, size_t n) { return n == 0 || (seek64(f, at) == 0 && fwrite(d, 1, n, f) == n); }
// A WAV arriving while it's still being recorded has the recorder's placeholder sizes: the copy here gets the sizes of what has arrived (whole
// sample frames), with every chunk, so REAPER can open it and play it as it grows. The sender's own header comes at the end (op 3).
// The size fields for `len` bytes, in the order they're written: (offset, little-endian bytes). RIFF's first, then data's: a look in between
// sees RIFF already covering bytes that are there, and data's the last one. (data's went first, and a look between the two read RIFF behind
// data: Linux CI's "playable WAV mid-stream" failure. James, rt)
static std::vector<std::pair<long long, std::string>> wav_sizes(const InStream &s, long long len)
{
  std::vector<std::pair<long long, std::string>> out;
  if (s.data_off < 0 || len < s.data_off) return out;
  const long long data = (len - s.data_off) / s.block_align * s.block_align, riff = s.data_off + data - 8;
  auto le = [](unsigned long long v, int n) { std::string b((size_t)n, '\0'); for (int i = 0; i < n; ++i) b[(size_t)i] = (char)(v >> (8 * i)); return b; };
  if (s.rf64) { out.push_back({ s.ds64_off, le(riff, 8) }); out.push_back({ s.ds64_off + 8, le(data, 8) }); out.push_back({ s.ds64_off + 16, le(data / s.block_align, 8) }); }
  else if (riff <= 0xffffffffLL) { out.push_back({ 4, le(riff, 4) }); out.push_back({ s.data_off - 4, le(data, 4) }); }
  return out;
}
// Could these first bytes be a WAV's (RIFF or RF64)? Fewer than 4: could they still become one?
static bool riffish(const std::string &h)
{
  const size_t n = std::min<size_t>(4, h.size());
  return h.compare(0, n, "RIFF", 0, n) == 0 || h.compare(0, n, "RF64", 0, n) == 0;
}
// The layout, while it isn't known yet (data_off -1), from what's here and the chunk arriving: a WAV whose sizes are kept, or not one (-2).
static void wav_learn(InStream &s, const char *q, size_t qn)
{
  if (s.data_off != -1) return;
  std::string head;
  if (!s.held.empty() || s.len == 0) head = s.held; // (held: the whole file so far, not on disk yet)
  else {
    head.assign((size_t)std::min<long long>(s.len, (long long)STREAM_HEAD), '\0');
    if (seek64(s.f, 0) != 0 || fread(&head[0], 1, head.size(), s.f) != head.size()) return;
  }
  head.append(q, std::min(qn, (size_t)STREAM_HEAD - std::min(head.size(), (size_t)STREAM_HEAD)));
  if (head.size() < 12) { if (!riffish(head)) s.data_off = -2; return; }
  if (direct_wav_layout(head, s.data_off, s.block_align, s.rf64, s.ds64_off)) return;
  const bool riff = head.compare(0, 4, "RIFF") == 0 || head.compare(0, 4, "RF64") == 0;
  s.data_off = (!riff || head.size() >= STREAM_HEAD) ? -2 : -1; // (not a WAV, or no "data" in its first 64 KB: left as it comes)
}
// The held start, sizes for `end` bytes put in. Pure.
static std::string with_sizes(const InStream &s, std::string head, long long end)
{
  for (auto &f : wav_sizes(s, end))
    for (size_t i = 0; i < f.second.size(); ++i) if (f.first + (long long)i < (long long)head.size()) head[(size_t)(f.first + (long long)i)] = f.second[i];
  return head;
}
// A chunk appended at s.len. A look at any moment sees either no WAV yet (zeros where its header goes) or a whole header claiming at least
// one sample frame and never more than is on disk:
//  - until the header is complete AND a whole frame of audio is here, the file's start is held back (zeros on disk, s.held in memory). The
//    copy showed a header claiming no audio (data 0) between the first audio's append and its sizes, when the first chunk was the header
//    alone, and a placeholder size when the header came in two chunks: aarch64 CI caught the first with 64 KB frames (James, rt);
//  - then the audio goes first and the header after it, already holding the sizes;
//  - after that, each chunk's audio first, then the sizes on disk, RIFF's before data's (a look between sees them a chunk behind).
static bool wav_append(InStream &s, const char *q, size_t qn)
{
  const bool keep = !s.finalizing && s.codec == 0;
  if (keep) wav_learn(s, q, qn);
  const long long end = s.len + (long long)qn, pre = s.data_off > 0 ? s.data_off : end; // (pre: where the header ends, once known)
  const size_t in_pre = (size_t)std::max<long long>(0, std::min(end, pre) - s.len); // (this chunk's bytes that are header)
  const bool whole = s.data_off > 0 && end >= s.data_off + s.block_align;
  const bool held_all = (long long)s.held.size() == std::min(s.len, pre); // (held from the start: a copy reopened after a restart isn't)
  if (keep && held_all && (s.data_off == -1 || (s.data_off > 0 && !whole))) { // hold the header back
    s.held.append(q, in_pre);
    const std::string zeros(in_pre, '\0');
    if (!put_at(s.f, s.len, zeros.data(), in_pre) || !put_at(s.f, s.len + (long long)in_pre, q + in_pre, qn - in_pre)) return false;
    s.len = end;
    return true;
  }
  if (!s.held.empty()) { // the held header goes in, after the audio, with the sizes
    const std::string head = with_sizes(s, s.held + std::string(q, in_pre), end);
    if (!put_at(s.f, s.len + (long long)in_pre, q + in_pre, qn - in_pre)) return false;
    if (g_stream_gap_ms > 0) sleep_ms(g_stream_gap_ms);
    if (!put_at(s.f, 0, head.data(), head.size())) return false;
    s.held.clear();
    s.len = end;
    return true;
  }
  const size_t cut = keep && s.data_off > s.len ? (size_t)std::min<long long>(s.data_off - s.len, (long long)qn) : 0;
  std::string head(q, cut);
  for (auto &f : wav_sizes(s, end))
    for (size_t i = 0; i < f.second.size(); ++i) if (f.first + (long long)i >= s.len && f.first + (long long)i < s.len + (long long)cut) head[(size_t)(f.first + (long long)i - s.len)] = f.second[i];
  if (!put_at(s.f, s.len + (long long)cut, q + cut, qn - cut)) return false;
  if (g_stream_gap_ms > 0) sleep_ms(g_stream_gap_ms);
  if (!put_at(s.f, s.len, head.data(), cut)) return false;
  s.len = end;
  if (keep) for (auto &f : wav_sizes(s, s.len)) put_at(s.f, f.first, f.second.data(), f.second.size());
  return true;
}
// What's held back goes to disk as it is (the stream's end: op 3 brings the real header anyway).
static void flush_held(InStream &s)
{
  if (!s.held.empty() && s.f) put_at(s.f, 0, s.held.data(), s.held.size());
  s.held.clear();
}
// One stream frame: op (0 begin, its payload the codec id: 0 = the file's own bytes, 1 = Opus packets later; 1 bytes at an offset, 3 the header rewritten, 2 done), u64 offset, payload. -> the answer: 0 kept; 7 + u64
// what's here (a gap: send from there); 8 done but the copy doesn't match (begin again); 1, 5, 6 as for files.
std::string take_stream(const Studio &st, const std::string &studio, const std::string &rel, const char *d, size_t n)
{
  if (!direct_stream_rel_ok(rel.c_str())) { reject("a name that isn't a stream's"); return std::string("\4", 1); }
  if (n < 9) { reject("a malformed stream message"); return std::string("\1", 1); }
  const int op = (unsigned char)d[0];
  const long long off = rd64(d + 1);
  const char *p = d + 9;
  const size_t pn = n - 9;
  if (off < 0 || off + (long long)pn > STREAM_MAX || op > 3 || (op == 2 && pn != 32)) { reject("a stream message out of bounds"); return std::string("\5", 1); }
  const std::string key = studio + "\t" + rel;
  InStream s;
  {
    std::lock_guard<std::mutex> l(g_mx);
    auto it = g_in.find(key);
    if (it != g_in.end()) s = it->second;
    else if (g_in.size() >= 64) { // (the oldest finished one makes room; 64 arriving at once: refused)
      auto old = g_in.end();
      for (auto i = g_in.begin(); i != g_in.end(); ++i) if (!i->second.f && (old == g_in.end() || i->second.at < old->second.at)) old = i;
      if (old == g_in.end()) { ++g_rejected; g_last_reject = "too many streams at once"; return std::string("\6", 1); }
      g_in.erase(old);
    }
  }
  s.studio = studio; s.rel = rel; s.path = st.inbox + "/.streams/" + rel;
  std::string reply(1, '\0');
  auto gap = [&]() { std::string r(1, '\7'); put64(r, s.len); return r; };
  auto fresh = [&]() {
    if (s.f) fclose(s.f);
    make_dirs(s.path.substr(0, s.path.find_last_of('/')));
    s.f = open_stream(s.path, "w+b");
    s.len = 0; s.total = -1; s.data_off = -1; s.finalizing = s.done = s.ok = false; s.held.clear();
  };
  if (op == 0) { fresh(); s.codec = pn > 0 ? (unsigned char)p[0] : 0; if (!s.f) reply = std::string("\6", 1); }
  else {
    if (!s.f) { // (a restart here, or closed after done: what's on disk counts)
      s.f = open_stream(s.path, "r+b");
      if (s.f) { s.len = size64(s.f); s.data_off = -1; s.done = s.ok = false; }
      else if (op == 1 && off == 0) fresh();
    }
    if (!s.f) reply = op == 1 ? gap() : std::string("\6", 1);
    else if (op == 1) {
      if (off > s.len) reply = gap();
      else if (off + (long long)pn > s.len) { // (bytes already here are skipped: a resend after a lost answer)
        const size_t skip = (size_t)(s.len - off);
        if (!wav_append(s, p + skip, pn - skip)) reply = std::string("\6", 1);
        s.done = false;
        fflush(s.f);
      }
    } else if (op == 3) {
      flush_held(s);
      if (off + (long long)pn > s.len) reply = gap();
      else if (seek64(s.f, off) != 0 || fwrite(p, 1, pn, s.f) != pn) reply = std::string("\6", 1);
      else { s.finalizing = true; fflush(s.f); }
    } else { // done
      flush_held(s);
      unsigned char h[32];
      s.total = off;
      if (s.len < off) reply = gap();
      else if (s.len == off && sha_file(s.f, s.len, h) && same_mac(h, p)) { s.done = s.ok = true; fclose(s.f); s.f = nullptr; }
      else { s.ok = false; reply = std::string("\10", 1); reject("a stream that didn't match its hash (sent again)"); }
    }
  }
  s.at = unix_now();
  std::lock_guard<std::mutex> l(g_mx);
  g_in[key] = s;
  return reply;
}

// One whole frame -> the answer. Checked before anything is written: studio, HMAC, then what each kind allows. t1: when it arrived.
std::string take_frame(const char *f, size_t total, long long t1)
{
  const unsigned sl = rd16(f + 4), pl = rd16(f + 6), dl = rd32(f + 8);
  const std::string studio(f + 12, sl), rel(f + 12 + sl, pl);
  const char *data = f + 12 + sl + pl;
  Studio st;
  {
    std::lock_guard<std::mutex> l(g_mx);
    auto it = g_studios.find(studio);
    if (it != g_studios.end()) st = it->second;
  }
  unsigned char mac[32] = { 0 };
  if (!st.key.empty()) direct_hmac_sha256((const unsigned char *)st.key.data(), st.key.size(), (const unsigned char *)f, total - 32, mac);
  if (st.key.empty() || !same_mac(mac, f + total - 32)) {
    reject(st.key.empty() ? "a studio this computer doesn't have" : "a bad signature (another studio's, or an old secret)");
    return std::string("\3", 1);
  }
  switch (f[2]) {
  case 'M':
    if (!kind_ok(rel)) { reject("a message kind that isn't a word"); return std::string("\4", 1); }
    {
      std::lock_guard<std::mutex> l(g_mx);
      ++g_msgs_received;
      g_msgs.push_back({ ++g_msg_seq, studio, rel, std::string(data, dl) });
      g_msg_bytes += dl;
      while (g_msgs.size() > MSG_KEEP || g_msg_bytes > MSG_KEEP_BYTES) { g_msg_bytes -= g_msgs.front().data.size(); g_msgs.pop_front(); }
    }
    return std::string(1, '\0');
  case 'P': {
    // NTP's exchange: t0 the sender's (in the ping), t1 when it got here, t2 when the answer goes, both this computer's clock. Signed.
    std::mt19937 rng((unsigned)t1);
    if (g_delay_max_ms > 0) { sleep_ms((int)(rng() % (unsigned)(g_delay_max_ms + 1))); t1 = clock_us(); } // (the test: a slower way here)
    std::string t(data, 8);
    put64(t, t1 + g_skew_us);
    put64(t, clock_us() + g_skew_us);
    if (g_delay_max_ms > 0) sleep_ms((int)(rng() % (unsigned)(g_delay_max_ms + 1))); // (and back)
    return std::string(1, '\0') + t.substr(8) + pong_mac(st.key, t);
  }
  case 'S': return take_stream(st, studio, rel, data, dl);
  default:
    if (!direct_path_ok(rel.c_str())) { reject("a name that isn't an event file's"); return std::string("\4", 1); }
    if (!write_atomic(st.inbox + "/" + rel, data, dl)) { reject("couldn't write into the inbox"); return std::string("\6", 1); }
    std::lock_guard<std::mutex> l(g_mx);
    ++g_received;
    g_got.push_back({ ++g_seq, studio, rel });
    while (g_got.size() > 256) g_got.pop_front();
    return std::string(1, '\0');
  }
}

std::atomic<bool (*)(unsigned long long, const char *, size_t)> g_http{ nullptr }; // (the web UI: direct_set_http_handler. James, rt)
// Whatever has arrived on one connection: each whole frame answered. -> false to close it (c.s is BAD_SOCK when the web UI took it).
bool take_conn(Conn &c, long long t_recv)
{
  for (;;) {
    auto http = g_http.load();
    if (http && c.buf.size() >= 4 && http((unsigned long long)c.s, c.buf.data(), c.buf.size())) { c.s = BAD_SOCK; return false; }
    if (c.buf.size() < 12) return true;
    const char *f = c.buf.data();
    const char m = f[2];
    if (f[0] != 'S' || f[1] != 'S' || f[3] != '1' || !m || !strchr("DMPS", m)) { reject("not StudioSync's"); send_all(c.s, "\1", 1); return false; }
    const unsigned sl = rd16(f + 4), pl = rd16(f + 6), dl = rd32(f + 8);
    const unsigned max_pl = m == 'M' || m == 'P' ? 32 : 512;
    if (sl == 0 || sl > 128 || pl == 0 || pl > max_pl || (m == 'P' && dl != 8)) { reject("a malformed message"); send_all(c.s, "\1", 1); return false; }
    if (dl > (m == 'M' ? (unsigned)DIRECT_MAX_MSG : (unsigned)DIRECT_MAX_DATA)) { reject(m == 'M' ? "a message over 64 KB" : "a file over 4 MB"); send_all(c.s, "\5", 1); return false; }
    const size_t total = 12 + sl + pl + (size_t)dl + 32;
    if (c.buf.size() < total) return true;
    const std::string reply = take_frame(f, total, t_recv);
    const char code = reply[0];
    // (7, a gap, and 8, a stream to send again, are part of a stream's flow: the connection stays)
    if (!send_all(c.s, reply.data(), reply.size()) || (code != 0 && code != 7 && code != 8)) return false;
    c.buf.erase(c.buf.begin(), c.buf.begin() + total);
  }
}

void listen_loop(sock_t ls, bool loopback_ok)
{
  std::vector<Conn> conns;
  std::vector<char> chunk(65536);
  while (!g_stop_listen) {
    std::vector<pollfd> fds(1 + conns.size());
    fds[0].fd = ls; fds[0].events = POLLIN; fds[0].revents = 0;
    for (size_t i = 0; i < conns.size(); ++i) { fds[i + 1].fd = conns[i].s; fds[i + 1].events = POLLIN; fds[i + 1].revents = 0; }
    const int n = poll_socks(fds.data(), (unsigned)fds.size(), 200); // (200 ms: how soon a stop is seen)
    const double t = now_s();
    if (n > 0 && (fds[0].revents & POLLIN)) {
      sockaddr_in from = {};
      socklen_t len = sizeof(from);
      sock_t s = accept(ls, (sockaddr *)&from, &len);
      if (s != BAD_SOCK) {
        direct_noinherit(s);
        if (from.sin_family != AF_INET || !addr_ok(from, loopback_ok)) { reject("a connection from outside Tailscale"); close_sock(s); }
        else if (conns.size() >= 32) { reject("too many connections"); close_sock(s); }
        else { set_nonblock(s, true); no_sigpipe(s); no_delay(s); conns.push_back({ s, {}, t }); }
      }
    }
    // (only those polled: one accepted just now has no poll entry yet, and read past the list's end it was closed at once. Laptop over
    // Tailscale, 0.59.50; on one computer it happened to work)
    for (size_t i = fds.size() - 1; i-- > 0;) {
      Conn &c = conns[i];
      bool keep = t - c.last < 120; // (a quiet connection goes after 2 minutes: the sender makes a new one)
      if (n > 0 && (fds[i + 1].revents & (POLLIN | POLLHUP | POLLERR))) {
        const int k = (int)recv(c.s, chunk.data(), (int)chunk.size(), 0);
        const long long t_recv = clock_us(); // (a ping's t1: as soon as its bytes are here)
        if (k > 0) {
          if (g_listen_kbps > 0) sleep_ms(k * 8 / g_listen_kbps); // (the test: a slow way here, a Tailscale relay)
          c.last = t;
          c.buf.insert(c.buf.end(), chunk.data(), chunk.data() + k);
          set_nonblock(c.s, false); set_timeouts(c.s, 3000); // (the answer is sent blocking, briefly)
          keep = take_conn(c, t_recv);
          set_nonblock(c.s, true);
        } else keep = false;
      }
      if (!keep) { if (c.s != BAD_SOCK) close_sock(c.s); conns.erase(conns.begin() + i); }
    }
  }
  for (Conn &c : conns) close_sock(c.s);
}

// A connection to `peer` ("host:port"), only to an address on Tailscale (or this computer). -> BAD_SOCK and why.
sock_t connect_peer(const std::string &peer, std::string &why)
{
  const size_t colon = peer.rfind(':');
  if (colon == std::string::npos || colon == 0) { why = "not host:port"; return BAD_SOCK; }
  const std::string host = peer.substr(0, colon), port = peer.substr(colon + 1);
  addrinfo hints = {}, *res = nullptr;
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  if (getaddrinfo(host.c_str(), port.c_str(), &hints, &res) != 0 || !res) { why = "its name doesn't resolve (Tailscale off there or here?)"; return BAD_SOCK; }
  sockaddr_in to = {};
  bool found = false;
  for (addrinfo *a = res; a && !found; a = a->ai_next)
    if (a->ai_family == AF_INET) { memcpy(&to, a->ai_addr, sizeof(to)); found = addr_ok(to, true); }
  freeaddrinfo(res);
  if (!found) { why = "its address isn't on Tailscale"; return BAD_SOCK; }
  sock_t s = socket(AF_INET, SOCK_STREAM, 0);
  if (s == BAD_SOCK) { why = "no socket"; return BAD_SOCK; }
  direct_noinherit(s);
  set_nonblock(s, true);
  connect(s, (sockaddr *)&to, sizeof(to));
  pollfd pf = { s, POLLOUT, 0 };
  int err = 0;
  socklen_t el = sizeof(err);
  // (1.5 s: a computer that's off mustn't hold the queue up for long; Syncthing carries its changes)
  if (poll_socks(&pf, 1, 1500) != 1 || getsockopt(s, SOL_SOCKET, SO_ERROR, (char *)&err, &el) != 0 || err != 0) {
    why = "no answer (off, asleep, or its firewall)";
    close_sock(s);
    return BAD_SOCK;
  }
  set_nonblock(s, false);
  set_timeouts(s, 3000);
  no_sigpipe(s);
  no_delay(s);
  return s;
}
bool recv_all(sock_t s, char *p, size_t n)
{
  while (n > 0) {
    const int k = (int)recv(s, p, (int)n, 0);
    if (k <= 0) return false;
    p += k; n -= (size_t)k;
  }
  return true;
}

// Send one frame to one peer on its kept connection, reconnecting once. -> the answer byte, or -1 and why. `extra`: what follows the answer
// byte, ok_extra bytes after a 0 (a ping's answer), 8 after a 7 (a stream's gap).
// (the test: a peer far away on localhost. An answer is taken no sooner than the round trip after its frame went)
void hold_answer(double sent_at)
{
  const double w = g_test_rtt_ms > 0 ? sent_at + g_test_rtt_ms / 1000.0 - now_s() : 0;
  if (w > 0) sleep_ms((int)(w * 1000 + 0.5));
}
int send_frame(Peer &p, const std::string &peer, const std::string &frame, std::string &why, std::string *extra = nullptr, size_t ok_extra = 0)
{
  for (int attempt = 0; attempt < 2; ++attempt) {
    const bool fresh = p.s == BAD_SOCK;
    if (fresh && (p.s = connect_peer(peer, why)) == BAD_SOCK) return -1;
    char code = 0;
    const double t0 = now_s();
    if (send_all(p.s, frame.data(), frame.size()) && recv(p.s, &code, 1, 0) == 1) {
      const size_t want = !extra ? 0 : code == 0 ? ok_extra : code == 7 ? 8 : 0;
      if (extra) extra->assign(want, '\0');
      if (!want || recv_all(p.s, &(*extra)[0], want)) {
        hold_answer(t0);
        // (too small to spend time crossing: the path's own round trip. Not a stream's "done": its answer waits on the whole file's hash there)
        if (frame.size() <= 1024 && (frame[2] != 'S' || frame[12 + rd16(&frame[4]) + rd16(&frame[6])] == 0)) { p.quick_at = now_s(); p.quick_ms = (p.quick_at - t0) * 1000; }
        return (unsigned char)code;
      }
    }
    close_sock(p.s);
    p.s = BAD_SOCK;
    why = "the connection dropped";
    if (fresh) return -1; // (a new one failing isn't a stale one: no second try)
  }
  return -1;
}

const char *answer_text(int code, const std::string &why)
{
  static const char *answers[] = { "", "it didn't understand (an older StudioSync extension there?)", "", "it refused the signature (another studio's secret?)",
                                   "it refused the name", "too big for it", "it couldn't write the file", "a gap (sent again from where it is)",
                                   "its copy didn't match (sent again)" };
  return code < 0 ? why.c_str() : code < 9 ? answers[code] : "it answered strangely";
}
// After an answer: the peer's state. A failed connection: skipped for 10 s (Syncthing carries files meanwhile). A refusal: it closes.
void note_failure(Peer &p, int code)
{
  if (code < 0) p.retry_after = now_s() + 10;
  if (code > 0 && code != 7 && code != 8 && p.s != BAD_SOCK) { close_sock(p.s); p.s = BAD_SOCK; }
}

void do_job(const Job &job)
{
  std::string key;
  {
    std::lock_guard<std::mutex> l(g_mx);
    auto it = g_studios.find(job.studio);
    if (it == g_studios.end()) return; // (stopped meanwhile)
    key = it->second.key;
  }
  const std::string frame = direct_frame(key, job.studio, job.rel, job.data, "SSD1");
  for (const std::string &peer : job.peers) {
    Peer p;
    {
      std::lock_guard<std::mutex> l(g_mx);
      p = g_peers[peer];
    }
    if (now_s() < p.retry_after) continue; // (failed a moment ago: left to Syncthing for 10 s)
    std::string why;
    const double t0 = now_s();
    const int code = send_frame(p, peer, frame, why);
    p.at = unix_now();
    if (code == 0) { p.ok = true; p.ms = (now_s() - t0) * 1000; p.err.clear(); ++p.sent; p.retry_after = 0; }
    else { p.ok = false; p.err = answer_text(code, why); note_failure(p, code); }
    std::lock_guard<std::mutex> l(g_mx);
    g_peers[peer] = p;
  }
}

// One peer's messages (Lane): each frame written as soon as it's queued, in order on one connection of the lane's own; the answers read as they
// come, and waited for only while MSG_WINDOW are unanswered. A failed connection: what's queued for the next 10 s is dropped (it'd be stale; the
// files still go), as is what was in flight on a dropped one. Quiet for 60 s: closed before the listener's 2 minutes make it stale.
void lane_loop(const std::string peer, Lane *ln)
{
  sock_t s = BAD_SOCK;
  std::deque<double> fl; // (when each unanswered frame went)
  double retry_after = 0, last = 0;
  auto note = [&](int code, double ms, const std::string &why) {
    std::lock_guard<std::mutex> l(g_mx);
    ln->ok = code == 0; ln->at = unix_now();
    if (code == 0) { ln->ms = ms; ln->err.clear(); ++ln->sent; } else ln->err = answer_text(code, why);
  };
  auto drop = [&](int code, const std::string &why) { if (s != BAD_SOCK) close_sock(s); s = BAD_SOCK; fl.clear(); note(code, -1, why); };
  auto answer = [&]() -> bool { // the next answer: false when the connection's gone (a refusal closes it there too)
    char c = 0;
    if (recv(s, &c, 1, 0) != 1) { drop(-1, "the connection dropped"); return false; }
    const double t = fl.front();
    fl.pop_front();
    hold_answer(t);
    if (c != 0) { drop((unsigned char)c, ""); return false; }
    note(0, (now_s() - t) * 1000, "");
    return true;
  };
  for (;;) {
    std::string frame;
    {
      std::unique_lock<std::mutex> l(g_mx);
      if (ln->q.empty() && !ln->stop) ln->cv.wait_for(l, std::chrono::milliseconds(fl.empty() ? 1000 : 20));
      if (ln->stop) break;
      if (!ln->q.empty()) { frame = std::move(ln->q.front().second); ln->q.pop_front(); }
    }
    // (the answers here already; the test's far peer: not before its round trip)
    while (s != BAD_SOCK && !fl.empty() && now_s() >= fl.front() + g_test_rtt_ms / 1000.0) { pollfd pf = { s, POLLIN, 0 }; if (poll_socks(&pf, 1, 0) != 1 || !answer()) break; }
    if (frame.empty()) {
      if (s != BAD_SOCK && fl.empty() && now_s() - last > 60) { close_sock(s); s = BAD_SOCK; }
      continue;
    }
    if (now_s() < retry_after) continue;
    if (s != BAD_SOCK && (int)fl.size() >= MSG_WINDOW) {
      { std::lock_guard<std::mutex> l(g_mx); ln->busy = true; }
      while (s != BAD_SOCK && (int)fl.size() >= MSG_WINDOW && answer()) {}
      std::lock_guard<std::mutex> l(g_mx);
      ln->busy = false;
    }
    for (int attempt = 0; attempt < 2; ++attempt) {
      const bool fresh = s == BAD_SOCK;
      std::string why;
      if (fresh && (s = connect_peer(peer, why)) == BAD_SOCK) { retry_after = now_s() + 10; note(-1, -1, why); break; }
      if (send_all(s, frame.data(), frame.size())) { fl.push_back(now_s()); last = now_s(); break; }
      drop(-1, "the connection dropped"); // (a kept one gone stale: once more on a new one, as send_frame does)
      if (fresh) { retry_after = now_s() + 10; break; }
    }
  }
  if (s != BAD_SOCK) close_sock(s);
}

// The clock: each peer kept, pinged (fast at first, then every g_ping_s). NTP's estimate per ping: offset = ((t1 - t0) + (t2 - t3)) / 2,
// round trip = (t3 - t0) - (t2 - t1); the estimate is the median offset of the CLOCK_BEST lowest round trips among the last CLOCK_WINDOW
// (a ping that waited somewhere, one way more than the other, is off by half the difference: the quickest are the truest). -> next due.
double do_pings()
{
  const double now = now_s();
  double next = now + 0.5;
  std::vector<std::pair<std::string, std::string>> due;
  {
    std::lock_guard<std::mutex> l(g_mx);
    for (const auto &kv : g_clock) {
      const Peer &p = g_peers[kv.first];
      const double at = std::max(p.next_ping, p.retry_after);
      if (now >= at) due.push_back(kv); else next = std::min(next, at);
    }
  }
  for (const auto &d : due) {
    Peer p;
    std::string key;
    {
      std::lock_guard<std::mutex> l(g_mx);
      auto it = g_studios.find(d.second);
      if (it == g_studios.end()) continue;
      key = it->second.key;
      p = g_peers[d.first];
    }
    std::string t0s, extra, why;
    const long long t0 = clock_us();
    put64(t0s, t0);
    const int code = send_frame(p, d.first, direct_frame(key, d.second, "ping", t0s, "SSP1"), why, &extra, 48);
    const long long t3 = clock_us();
    ++p.pings;
    p.next_ping = now_s() + (p.pings < 8 ? std::min(0.2, g_ping_s) : g_ping_s); // (quick at first: an estimate within 2 s)
    if (code == 0 && same_mac((const unsigned char *)pong_mac(key, t0s + extra.substr(0, 16)).data(), extra.data() + 16)) {
      const long long t1 = rd64(extra.data()), t2 = rd64(extra.data() + 8);
      p.samples.push_back({ ((double)(t1 - t0) + (double)(t2 - t3)) / 2, (double)((t3 - t0) - (t2 - t1)) });
      while ((int)p.samples.size() > CLOCK_WINDOW) p.samples.pop_front();
      std::vector<Sample> best(p.samples.begin(), p.samples.end());
      std::sort(best.begin(), best.end(), [](const Sample &a, const Sample &b) { return a.rtt_us < b.rtt_us; });
      best.resize(std::min((size_t)CLOCK_BEST, best.size()));
      std::vector<double> offs;
      for (const Sample &s : best) offs.push_back(s.offset_us);
      std::sort(offs.begin(), offs.end());
      p.offset_ms = offs[offs.size() / 2] / 1000;
      p.spread_ms = (offs.back() - offs.front()) / 1000;
      p.rtt_ms = best.front().rtt_us / 1000;
      p.clock_at = p.at = unix_now();
      p.clock_err.clear();
      p.ok = true; p.err.clear(); p.ms = (double)(t3 - t0) / 1000; p.retry_after = 0; // (a ping is a round trip on the link too: Health's)
    } else {
      p.clock_err = code == 0 ? "its answer's signature was wrong" : answer_text(code, why);
      if (code == 1) p.next_ping = now_s() + 60; // (an older extension: no clock there, its files still go)
      else { p.ok = false; p.err = p.clock_err; p.at = unix_now(); }
      note_failure(p, code);
    }
    std::lock_guard<std::mutex> l(g_mx);
    g_peers[d.first] = p;
    next = std::min(next, std::max(p.next_ping, p.retry_after));
  }
  return next;
}

// One pass of a stream for each of its peers: what's been written since, in chunks (op 1); once it's ended and all sent, the file's first
// 64 KB again (op 3: the header the recorder rewrote at the end) and done (op 2) with the length and SHA-256.
// (trouble reading the file here is this computer's, never the peer's: it isn't skipped for 10 s for it, as a peer that doesn't answer is, and
// the stream's own `err` says what. A read that comes back short sends what it got. James, rt: a take's tail sat unsent while REAPER wrote it)
static void trace_line(const std::string &line)
{
  std::string path;
  {
    std::lock_guard<std::mutex> l(g_mx);
    path = g_trace_path;
  }
  if (path.empty()) return;
  FILE *f = fopen(path.c_str(), "ab"); // (not open_shared: that one opens to read only, or to write from the start)
  if (!f) return;
  fseek(f, 0, SEEK_END);
  if (ftell(f) > 5 * 1024 * 1024) { // (rolled at 5 MB, one older copy kept, as the Lua side's streams.trace does: the trace is for testing. rt)
    fclose(f);
    remove((path + ".1").c_str());
    rename(path.c_str(), (path + ".1").c_str());
    f = fopen(path.c_str(), "ab");
    if (!f) return;
  }
  const double t = std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();
  fprintf(f, "%.3f %s\n", t, line.c_str());
  fclose(f);
}
struct Flight { long long off; size_t n; double at; };
// The path's own round trip (ms), from frames too small to spend time crossing it: the clock's quickest ping while the clock's kept with that
// peer, else the last small frame's answer (a stream's begin or done, an event, a message) within a minute; -1 if neither. (A 64 KB frame's own
// round trip has its crossing in it: on a slow way that's most of it, and the window grew from it. James, rt)
double path_rtt_ms(const Peer &p)
{
  if (p.rtt_ms > 0 && unix_now() - p.clock_at <= 5) return p.rtt_ms;
  return p.quick_ms > 0 && now_s() - p.quick_at < 60 ? p.quick_ms : -1;
}
// A stream's bytes from o.off on, in chunks (op 1), up to the peer's window of frames in flight on its kept connection; the answers come back in
// order. -> the last answer: 0 or 7 (fine: a gap moves o.off to what the peer has), -1 dropped (why), else a refusal (the peer closes).
// Also measures, for Health: the rate this pass's answers came at, and its quickest frame round trip. (James, rt)
int stream_chunks(Peer &p, const std::string &peer, const std::string &key, OutStream &s, OutPeer &o, long long size, std::string &why)
{
  const size_t chunk = o.chunk ? o.chunk : STREAM_CHUNK;
  const int cap = g_test_wmax > 0 ? g_test_wmax : WINDOW_MAX, lo = std::min(WINDOW_MIN, cap);
  const double path_rtt = path_rtt_ms(p) / 1000;
  // (each pass starts at no more than WINDOW_START, whatever the last one grew to: a way that's turned slow or relayed since never gets a big
  // window's worth at once. The last one's still counts when it was cut after a drop)
  int w = std::max(lo, std::min(std::min(p.window ? p.window : WINDOW_START, WINDOW_START), cap));
  for (int attempt = 0; attempt < 2; ++attempt) {
    const bool fresh = p.s == BAD_SOCK;
    if (fresh && (p.s = connect_peer(peer, why)) == BAD_SOCK) return -1;
    std::deque<Flight> fl;
    std::string bytes, d;
    long long next = o.off, budget = 8LL << 20, acked = 0, round_bytes = 0; // (8 MB a pass to each: a long file started late doesn't hold the others up)
    int code = 0, gaps = 0, round_n = 0;
    const double t0 = now_s();
    double round_t = t0, last_ack = t0, best = -1;
    bool readable = true;
    for (;;) {
      while (readable && (int)fl.size() < w && next < size && budget > 0) {
        const size_t n = (size_t)std::min<long long>((long long)chunk, size - next);
        if (read_some(s.path, next, n, bytes, &s.err) <= 0) { if (s.err.empty()) s.err = "the file's newest bytes aren't readable yet"; readable = false; break; } // (next pass)
        d.assign(1, '\1');
        put64(d, next);
        d += bytes;
        const std::string f = direct_frame(key, s.studio, s.rel, d, "SSS1");
        if (!send_all(p.s, f.data(), f.size())) { code = -1; break; }
        fl.push_back({ next, bytes.size(), now_s() });
        next += (long long)bytes.size();
        budget -= (long long)bytes.size();
      }
      if (code < 0 || fl.empty()) break;
      char c = 0, len[8];
      if (recv(p.s, &c, 1, 0) != 1) { code = -1; break; }
      const Flight f = fl.front();
      fl.pop_front();
      hold_answer(f.at);
      code = (unsigned char)c;
      if (code == 0) {
        const double t = now_s();
        o.off = std::max(o.off, f.off + (long long)f.n);
        acked += (long long)f.n;
        round_bytes += (long long)f.n;
        last_ack = t;
        best = best < 0 ? t - f.at : std::min(best, t - f.at);
        if (++round_n >= w) { // a round trip's worth answered: is the pipe full yet?
          // (frames: what the link carried in one round trip of the path's, else of this pass's quickest frame)
          const double rtt = path_rtt > 0 ? path_rtt : best, frames = (double)round_bytes / std::max(1e-6, t - round_t) * rtt / (double)chunk;
          w = frames >= 0.75 * w ? std::min(cap, w * 2) : std::max(lo, std::min(w, (int)std::ceil(frames) + 1));
          round_n = 0; round_bytes = 0; round_t = t;
        }
      } else if (code == 7) { // a gap: the frames behind this one are past the peer's end too, so their answers are gaps as well, read and dropped
        if (!recv_all(p.s, len, 8)) { code = -1; break; }
        o.off = std::min(rd64(len), size);
        for (; !fl.empty() && code == 7; fl.pop_front()) {
          if (recv(p.s, &c, 1, 0) != 1 || (c == 7 && !recv_all(p.s, len, 8))) code = -1;
          else if (c != 0 && c != 7) code = (unsigned char)c;
        }
        if (code != 7 || ++gaps > 8) break;
        next = o.off;
      } else break;
    }
    if (acked >= RATE_MIN_BYTES && last_ack > t0) { p.rate = (double)acked / (last_ack - t0); p.rate_at = unix_now(); } // (the last: a path gone relayed shows at once)
    if (best > 0) p.frame_rtt_ms = best * 1000;
    p.window = code < 0 ? std::max(lo, w / 2) : w;
    if (code >= 0) return code;
    close_sock(p.s);
    p.s = BAD_SOCK;
    why = "the connection dropped";
    if (fresh || acked > 0) return -1; // (a kept connection that had gone stale: one more try on a new one, as send_frame does)
  }
  return -1;
}

void stream_tick(OutStream &s, const std::string &key)
{
  std::string how;
  const long long size = file_size(s.path, &s.err, &how);
  struct Trace { OutStream &s; const std::string &how; long long size; ~Trace() { // (each pass, whatever it did)
    if (!g_tracing) return;
    std::string l = s.rel + " | " + s.path + " | size " + std::to_string(size) + " (" + how + ")" + (s.ended ? " ended" : "") + (s.err.empty() ? "" : " | err " + s.err);
    for (auto &kv : s.peers) l += " | " + kv.first + " off " + std::to_string(kv.second.off) + (kv.second.begun ? "" : " not begun") + (kv.second.done ? " done" : "") +
                                (kv.second.err.empty() ? "" : " (" + kv.second.err + ")");
    trace_line(l);
  } } trace{ s, how, size };
  if (size < 0) return;
  s.size = size;
  s.err.clear();
  for (auto &kv : s.peers) {
    OutPeer &o = kv.second;
    if (o.done || o.resends > 2) continue;
    Peer p;
    {
      std::lock_guard<std::mutex> l(g_mx);
      p = g_peers[kv.first];
    }
    if (now_s() < p.retry_after) continue;
    std::string why, extra, chunk;
    int code = 0;
    auto op = [&](int what, long long off, const std::string &payload) {
      std::string d(1, (char)what);
      put64(d, off);
      d += payload;
      code = send_frame(p, kv.first, direct_frame(key, s.studio, s.rel, d, "SSS1"), why, &extra);
      if (code == 7 && extra.size() == 8) o.off = std::min(rd64(extra.data()), size);
      return code;
    };
    if (!o.begun) { if (op(0, 0, std::string(1, (char)s.codec)) == 0) { o.begun = true; o.off = 0; } }
    if (o.begun && (code == 0 || code == 7) && o.off < size && (code = stream_chunks(p, kv.first, key, s, o, size, why)) < 0)
      o.chunk = std::max(STREAM_CHUNK_MIN, (o.chunk ? o.chunk : STREAM_CHUNK) / 2); // (too slow a way for this size)
    if (o.begun && (code == 0 || code == 7) && s.ended && o.off >= size) {
      if (s.sha_len != size) {
        FILE *f = open_shared(s.path, "rb");
        s.sha_len = f && sha_file(f, size, s.sha) ? size : -1;
        if (f) fclose(f);
      }
      if (s.sha_len == size && read_at(s.path, 0, (size_t)std::min<long long>(size, (long long)STREAM_HEAD), chunk) && op(3, 0, chunk) == 0 &&
          op(2, size, std::string((const char *)s.sha, 32)) == 0) o.done = true;
      else if (code == 8) { o.begun = false; o.off = 0; ++o.resends; } // (its copy differs: the whole file again, twice at most)
    }
    o.err = code == 0 || code == 7 ? "" : answer_text(code, why);
    if (code != 0) note_failure(p, code);
    std::lock_guard<std::mutex> l(g_mx);
    g_peers[kv.first] = p;
  }
}
double do_streams()
{
  const double now = now_s();
  double next = now + 0.5;
  std::vector<std::string> due;
  {
    std::lock_guard<std::mutex> l(g_mx);
    for (const auto &kv : g_out)
      if (kv.second.finished_at == 0) { if (now >= kv.second.next_at) due.push_back(kv.first); else next = std::min(next, kv.second.next_at); }
  }
  for (const std::string &k : due) {
    OutStream s;
    std::string key;
    {
      std::lock_guard<std::mutex> l(g_mx);
      auto it = g_out.find(k);
      auto st = it == g_out.end() ? g_studios.end() : g_studios.find(it->second.studio);
      if (st == g_studios.end()) continue;
      s = it->second;
      key = st->second.key;
    }
    stream_tick(s, key);
    std::lock_guard<std::mutex> l(g_mx);
    auto it = g_out.find(k);
    if (it == g_out.end()) continue;
    OutStream &o = it->second; // (only what the pass changed: `ended` and new peers are the main thread's)
    for (auto &kv : s.peers) o.peers[kv.first] = kv.second;
    o.size = s.size; o.sha_len = s.sha_len; memcpy(o.sha, s.sha, 32); o.err = s.err;
    bool all = o.ended;
    for (auto &kv : o.peers) all = all && (kv.second.done || kv.second.resends > 2);
    if (all) o.finished_at = now_s();
    o.next_at = now_s() + o.interval_ms / 1000.0;
    next = std::min(next, o.next_at);
  }
  return next;
}

void send_loop()
{
  for (;;) {
    Job job;
    bool have = false;
    {
      std::unique_lock<std::mutex> l(g_mx);
      const double wait = g_next_due - now_s();
      if (g_jobs.empty() && !g_stop_send && !g_kick && wait > 0) g_cv.wait_for(l, std::chrono::duration<double>(std::min(wait, 0.5)));
      g_kick = false;
      if (g_stop_send) break;
      if (!g_jobs.empty()) { job = std::move(g_jobs.front()); g_jobs.pop_front(); have = true; }
    }
    if (have) do_job(job);
    const double next = std::min(do_pings(), do_streams());
    std::lock_guard<std::mutex> l(g_mx);
    g_next_due = next;
  }
  std::lock_guard<std::mutex> l(g_mx);
  for (auto &kv : g_peers) if (kv.second.s != BAD_SOCK) { close_sock(kv.second.s); kv.second.s = BAD_SOCK; }
}

void stop_listening()
{
  g_stop_listen = true;
  if (g_listen_thr.joinable()) g_listen_thr.join();
  if (g_listen_sock != BAD_SOCK) { close_sock(g_listen_sock); g_listen_sock = BAD_SOCK; }
  g_stop_listen = false;
  std::lock_guard<std::mutex> l(g_mx);
  g_listening = false;
  g_bind.clear();
}

bool start_listening(const std::string &ip, int port, std::string &why)
{
  sock_t s = socket(AF_INET, SOCK_STREAM, 0);
  if (s == BAD_SOCK) { why = "no socket"; return false; }
  direct_noinherit(s);
#ifndef _WIN32
  int one = 1;
  setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)); // (straight back after a REAPER restart; Windows binds past TIME_WAIT as it is)
#endif
  sockaddr_in a = {};
  a.sin_family = AF_INET;
  a.sin_port = htons((unsigned short)port);
  inet_pton(AF_INET, ip.c_str(), &a.sin_addr);
  if (bind(s, (sockaddr *)&a, sizeof(a)) != 0 || listen(s, 16) != 0) {
    close_sock(s);
    char buf[160];
    snprintf(buf, sizeof(buf), "can't listen on %s:%d (another REAPER, or something else, has the port)", ip.c_str(), port);
    why = buf;
    return false;
  }
  g_listen_sock = s;
  const bool loopback = ip.compare(0, 4, "127.") == 0;
  g_listen_thr = std::thread(listen_loop, s, loopback);
  return true;
}

std::vector<std::string> parse_peers(const char *peers)
{
  std::vector<std::string> out;
  for (const char *p = peers ? peers : ""; *p;) {
    while (*p == ' ' || *p == '\t' || *p == '\n') ++p;
    const char *e = p;
    while (*e && *e != ' ' && *e != '\t' && *e != '\n') ++e;
    if (e > p) out.emplace_back(p, e);
    p = e;
  }
  return out;
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
} // namespace

void direct_set_http_handler(bool (*fn)(unsigned long long, const char *, size_t)) { g_http = fn; }

#ifdef DIRECT_STANDALONE
void direct_test_bandwidth(int kbps) { g_listen_kbps = kbps; }
void direct_test_stream_gap(int ms) { g_stream_gap_ms = ms; }
void direct_test_link(int rtt_ms, int window_max) { g_test_rtt_ms = rtt_ms; g_test_wmax = window_max; }
void direct_test_knobs(long long skew_us, int delay_max_ms, int ping_ms)
{
  g_skew_us = skew_us;
  g_delay_max_ms = delay_max_ms;
  g_ping_s = ping_ms > 0 ? ping_ms / 1000.0 : 1.0;
}
#endif

// ---- the core's functions --------------------------------------------------------------------------------------------------------------
int direct_start(const char *studio, const char *secret, const char *inbox, int port, const char *bind_ip)
{
  if (!studio || !*studio || strlen(studio) > 128 || !secret || !*secret || !inbox || !*inbox) return 0;
#ifdef _WIN32
  if (!g_wsa) { WSADATA w; g_wsa = WSAStartup(MAKEWORD(2, 2), &w) == 0; }
#endif
  clock_us(); // (its zero: now)
  {
    std::lock_guard<std::mutex> l(g_mx);
    g_studios[studio] = { direct_derive_key(secret), inbox };
  }
  if (!g_send_thr.joinable()) { g_stop_send = false; g_send_thr = std::thread(send_loop); }
  if (port < 0) { std::lock_guard<std::mutex> l(g_mx); return g_listening ? 1 : 0; }
  if (port == 0) port = DIRECT_PORT;
  std::string why, ip = bind_ip && *bind_ip ? bind_ip : tailscale_ip(why);
  {
    std::lock_guard<std::mutex> l(g_mx);
    if (g_listening && g_bind == ip && g_port == port) return 1;
  }
  stop_listening(); // (Tailscale's address changed, or there's none now)
  const bool ok = !ip.empty() && start_listening(ip, port, why);
  std::lock_guard<std::mutex> l(g_mx);
  g_listening = ok;
  g_bind = ok ? ip : "";
  g_port = port;
  g_listen_err = ok ? "" : why;
  return ok ? 1 : 0;
}

void direct_stop(const char *studio)
{
  if (!studio || !*studio) { direct_shutdown(); return; }
  std::lock_guard<std::mutex> l(g_mx);
  g_studios.erase(studio);
  for (auto it = g_clock.begin(); it != g_clock.end();) it = it->second == studio ? g_clock.erase(it) : std::next(it);
  for (auto it = g_out.begin(); it != g_out.end();) it = it->second.studio == studio ? g_out.erase(it) : std::next(it);
  for (auto &kv : g_lanes) { auto &q = kv.second->q; q.erase(std::remove_if(q.begin(), q.end(), [&](const std::pair<std::string, std::string> &m) { return m.first == studio; }), q.end()); }
}

int direct_send(const char *studio, const char *rel, const char *path, const char *peers)
{
  if (!studio || !rel || !path || !peers || !direct_path_ok(rel)) return 0;
  Job job;
  job.studio = studio;
  job.rel = rel;
  job.peers = parse_peers(peers);
  if (job.peers.empty() || !read_file(path, job.data)) return 0; // (read here: a few hundred bytes, and it's still there now)
  std::lock_guard<std::mutex> l(g_mx);
  if (!g_send_thr.joinable() || !g_studios.count(studio) || g_jobs.size() >= 1000) return 0;
  g_jobs.push_back(std::move(job));
  g_cv.notify_one();
  return 1;
}

int direct_msg(const char *studio, const char *kind, const char *data, const char *peers)
{
  if (!studio || !kind || !data || !kind_ok(kind) || strlen(data) > DIRECT_MAX_MSG) return 0;
  const std::vector<std::string> list = parse_peers(peers);
  if (list.empty()) return 0;
  std::lock_guard<std::mutex> l(g_mx);
  auto st = g_studios.find(studio);
  if (!g_send_thr.joinable() || st == g_studios.end()) return 0;
  const std::string frame = direct_frame(st->second.key, studio, kind, data, "SSM1");
  int queued = 0;
  for (const std::string &peer : list) {
    auto it = g_lanes.find(peer);
    if (it == g_lanes.end()) {
      if (g_lanes.size() >= LANES_MAX) continue;
      it = g_lanes.emplace(peer, std::unique_ptr<Lane>(new Lane)).first;
      it->second->thr = std::thread(lane_loop, peer, it->second.get());
      g_peers[peer]; // (Health lists it from now on)
    }
    Lane &ln = *it->second;
    if (ln.q.size() >= LANE_MAX) continue;
    ln.q.emplace_back(studio, frame);
    ln.cv.notify_one();
    ++queued;
  }
  return queued > 0 ? 1 : 0;
}

const char *direct_poll(int after)
{
  std::lock_guard<std::mutex> l(g_mx);
  g_poll_out.clear();
  for (const Got &g : g_got)
    if (g.seq > after) { g_poll_out = std::to_string(g.seq) + "\t" + g.studio + "\t" + g.rel; break; }
  return g_poll_out.c_str();
}

const char *direct_msg_poll(int after)
{
  std::lock_guard<std::mutex> l(g_mx);
  g_msg_out.clear();
  for (const Msg &m : g_msgs)
    if (m.seq > after) { g_msg_out = std::to_string(m.seq) + "\t" + m.studio + "\t" + m.kind + "\t" + m.data; break; }
  return g_msg_out.c_str();
}

int direct_peers(const char *studio, const char *peers)
{
  if (!studio || !*studio) return 0;
  const std::vector<std::string> list = parse_peers(peers);
  std::lock_guard<std::mutex> l(g_mx);
  if (!g_studios.count(studio)) return 0;
  for (auto it = g_clock.begin(); it != g_clock.end();)
    it = it->second == studio && std::find(list.begin(), list.end(), it->first) == list.end() ? g_clock.erase(it) : std::next(it);
  for (const std::string &p : list) g_clock[p] = studio;
  g_kick = true;
  g_cv.notify_one();
  return (int)list.size();
}

double direct_now() { return clock_us() / 1e6; }

const char *direct_clock()
{
  std::lock_guard<std::mutex> l(g_mx);
  std::string &o = g_clock_out;
  char num[200];
  snprintf(num, sizeof(num), "{\"now\":%.6f,\"peers\":{", clock_us() / 1e6);
  o = num;
  bool first = true;
  for (const auto &kv : g_clock) {
    const Peer &p = g_peers[kv.first];
    if (!first) o += ',';
    first = false;
    json_str(o, kv.first);
    snprintf(num, sizeof(num), ":{\"offset_ms\":%.3f,\"rtt_ms\":%.3f,\"spread_ms\":%.3f,\"samples\":%d,\"at\":%lld,\"error\":",
             p.offset_ms, p.rtt_ms, p.spread_ms, (int)p.samples.size(), p.clock_at);
    o += num;
    json_str(o, p.clock_err);
    o += '}';
  }
  o += "}}";
  return o.c_str();
}

int direct_stream(const char *studio, const char *rel, const char *path, const char *peers, int interval_ms)
{
  if (!studio || !rel || !path || !*path || !direct_stream_rel_ok(rel)) return 0;
  const std::vector<std::string> list = parse_peers(peers);
  if (list.empty()) return 0;
  std::lock_guard<std::mutex> l(g_mx);
  if (!g_send_thr.joinable() || !g_studios.count(studio)) return 0;
  int live = 0;
  for (auto it = g_out.begin(); it != g_out.end();) { // (finished ones kept 10 minutes, for the status)
    if (it->second.finished_at > 0 && now_s() - it->second.finished_at > 600) { it = g_out.erase(it); continue; }
    live += it->second.finished_at == 0;
    ++it;
  }
  const std::string key = std::string(studio) + "\t" + rel;
  auto it = g_out.find(key);
  if (it != g_out.end() && (it->second.finished_at > 0 || it->second.path != path)) { g_out.erase(it); it = g_out.end(); }
  if (it == g_out.end()) {
    if (live >= 32) return 0;
    OutStream s;
    s.studio = studio; s.rel = rel; s.path = path;
    it = g_out.emplace(key, s).first;
  }
  it->second.interval_ms = interval_ms <= 0 ? 250 : std::max(20, std::min(interval_ms, 5000));
  for (const std::string &p : list) it->second.peers[p]; // (a peer added later starts from the beginning)
  g_kick = true;
  g_cv.notify_one();
  return 1;
}

void direct_trace(const char *path)
{
  std::lock_guard<std::mutex> l(g_mx);
  g_trace_path = path ? path : "";
  g_tracing = !g_trace_path.empty();
}
int direct_stream_end(const char *studio, const char *rel)
{
  if (!studio || !rel) return 0;
  std::lock_guard<std::mutex> l(g_mx);
  auto it = g_out.find(std::string(studio) + "\t" + rel);
  if (it == g_out.end()) return 0;
  it->second.ended = true;
  it->second.next_at = 0;
  g_kick = true;
  g_cv.notify_one();
  return 1;
}

const char *direct_streams()
{
  std::lock_guard<std::mutex> l(g_mx);
  std::string &o = g_streams_out;
  char num[200];
  o = "{\"out\":[";
  bool first = true;
  for (const auto &kv : g_out) {
    const OutStream &s = kv.second;
    o += first ? "{\"studio\":" : ",{\"studio\":";
    first = false;
    json_str(o, s.studio); o += ",\"rel\":"; json_str(o, s.rel);
    snprintf(num, sizeof(num), ",\"size\":%lld,\"ended\":%s,\"finished\":%s,\"error\":", s.size, s.ended ? "true" : "false", s.finished_at > 0 ? "true" : "false");
    o += num;
    json_str(o, s.err);
    o += ",\"peers\":{";
    bool pf = true;
    for (const auto &pk : s.peers) {
      if (!pf) o += ',';
      pf = false;
      json_str(o, pk.first);
      snprintf(num, sizeof(num), ":{\"sent\":%lld,\"done\":%s,\"resends\":%d,\"error\":", pk.second.off, pk.second.done ? "true" : "false", pk.second.resends);
      o += num;
      json_str(o, pk.second.err);
      o += '}';
    }
    o += "}}";
  }
  o += "],\"in\":[";
  first = true;
  for (const auto &kv : g_in) {
    const InStream &s = kv.second;
    o += first ? "{\"studio\":" : ",{\"studio\":";
    first = false;
    json_str(o, s.studio); o += ",\"rel\":"; json_str(o, s.rel); o += ",\"path\":"; json_str(o, s.path);
    snprintf(num, sizeof(num), ",\"bytes\":%lld,\"total\":%lld,\"done\":%s,\"ok\":%s,\"playable\":%s,\"codec\":%d,\"at\":%lld}", s.len, s.total, s.done ? "true" : "false",
             s.ok ? "true" : "false", s.data_off >= 0 || s.done ? "true" : "false", s.codec, s.at);
    o += num;
  }
  o += "]}";
  return o.c_str();
}

const char *direct_status()
{
  std::lock_guard<std::mutex> l(g_mx);
  std::string &o = g_status_out;
  char num[320];
  o = "{\"listening\":";
  o += g_listening ? "true" : "false";
  o += ",\"bind\":"; json_str(o, g_bind);
  size_t queued = g_jobs.size();
  for (const auto &kv : g_lanes) queued += kv.second->q.size();
  snprintf(num, sizeof(num), ",\"port\":%d,\"received\":%lld,\"rejected\":%lld,\"queued\":%d,\"messages\":%lld", g_port, g_received, g_rejected,
           (int)queued, g_msgs_received);
  o += num;
  o += ",\"error\":"; json_str(o, g_listen_err);
  o += ",\"last_reject\":"; json_str(o, g_last_reject);
  o += ",\"peers\":{";
  bool first = true;
  for (const auto &kv : g_peers) {
    if (!first) o += ',';
    first = false;
    json_str(o, kv.first);
    // (1.0.12, link speed: rate, bytes/s the last streams were answered at, and when; rtt_ms, the path's round trip (path_rtt_ms),
    // else the quickest stream frame's; window, frames in flight)
    // (busy: its messages' window is full, the link behind on it; ok, ms and error the newer of its lane's last answer and the send thread's)
    Peer p = kv.second;
    auto ln = g_lanes.find(kv.first);
    const bool busy = ln != g_lanes.end() && ln->second->busy;
    if (ln != g_lanes.end()) { const Lane &m = *ln->second; p.sent += m.sent; if (m.at >= p.at) { p.ok = m.ok; p.ms = m.ms; p.at = m.at; p.err = m.err; } }
    snprintf(num, sizeof(num), ":{\"ok\":%s,\"ms\":%.1f,\"at\":%lld,\"sent\":%lld,\"rate\":%.0f,\"rate_at\":%lld,\"rtt_ms\":%.1f,\"window\":%d,\"busy\":%s,\"error\":",
             p.ok ? "true" : "false", p.ms, p.at, p.sent, p.rate, p.rate_at, path_rtt_ms(p) > 0 ? path_rtt_ms(p) : p.frame_rtt_ms, p.window, busy ? "true" : "false");
    o += num;
    json_str(o, p.err);
    o += '}';
  }
  o += "}}";
  return o.c_str();
}

void direct_shutdown()
{
  stop_listening();
  {
    std::lock_guard<std::mutex> l(g_mx);
    g_stop_send = true;
    g_jobs.clear();
  }
  g_cv.notify_all();
  if (g_send_thr.joinable()) g_send_thr.join();
  std::map<std::string, std::unique_ptr<Lane>> lanes;
  {
    std::lock_guard<std::mutex> l(g_mx);
    lanes.swap(g_lanes);
    for (auto &kv : lanes) { kv.second->stop = true; kv.second->cv.notify_one(); }
  }
  for (auto &kv : lanes) kv.second->thr.join(); // (a lane blocked on an answer: its 3 s timeout at most)
  std::lock_guard<std::mutex> l(g_mx);
  g_stop_send = false;
  g_studios.clear();
  g_peers.clear();
  g_clock.clear();
  g_out.clear();
  for (auto &kv : g_in) if (kv.second.f) fclose(kv.second.f); // (the listener has stopped: nobody else has them)
  g_in.clear();
#ifdef _WIN32
  if (g_wsa) { WSACleanup(); g_wsa = false; }
#endif
}

// ---- ReaScript: reaper.StudioSync_Direct* ----------------------------------------------------------------------------------------------
#ifndef DIRECT_STANDALONE
#include "reaper_plugin.h"
static int api_start(const char *studio, const char *secret, const char *inbox, int port) { return direct_start(studio, secret, inbox, port, ""); }
static void api_stop(const char *studio) { direct_stop(studio); }
static int api_send(const char *studio, const char *rel, const char *path, const char *peers) { return direct_send(studio, rel, path, peers); }
static const char *api_poll(int after) { return direct_poll(after); }
static const char *api_status() { return direct_status(); }
// (ReaScript's calls: ints as (INT_PTR), strings as pointers. reaper_plugin.h's APIvararg_ notes)
static void *va_start_(void **a, int n) { return n < 4 ? nullptr : (void *)(INT_PTR)api_start((const char *)a[0], (const char *)a[1], (const char *)a[2], (int)(INT_PTR)a[3]); }
static void *va_stop(void **a, int n) { api_stop(n > 0 ? (const char *)a[0] : ""); return nullptr; }
static void *va_send(void **a, int n) { return n < 4 ? nullptr : (void *)(INT_PTR)api_send((const char *)a[0], (const char *)a[1], (const char *)a[2], (const char *)a[3]); }
static void *va_poll(void **a, int n) { return (void *)api_poll(n > 0 ? (int)(INT_PTR)a[0] : 0); }
static void *va_status(void **, int) { return (void *)api_status(); }
// 1.0.8
static int api_msg(const char *studio, const char *kind, const char *data, const char *peers) { return direct_msg(studio, kind, data, peers); }
static const char *api_msg_poll(int after) { return direct_msg_poll(after); }
static int api_peers(const char *studio, const char *peers) { return direct_peers(studio, peers); }
static const char *api_clock() { return direct_clock(); }
static double api_now() { return direct_now(); }
static int api_stream(const char *studio, const char *rel, const char *path, const char *peers, int ms) { return direct_stream(studio, rel, path, peers, ms); }
static int api_stream_end(const char *studio, const char *rel) { return direct_stream_end(studio, rel); }
static const char *api_streams() { return direct_streams(); }
static double api_file_time(const char *path) { return direct_file_time(path); }
static void api_trace(const char *path) { direct_trace(path); }
#define S_(i) (n > (i) ? (const char *)a[i] : nullptr)
static void *va_msg(void **a, int n) { return (void *)(INT_PTR)api_msg(S_(0), S_(1), S_(2), S_(3)); }
static void *va_msg_poll(void **a, int n) { return (void *)api_msg_poll(n > 0 ? (int)(INT_PTR)a[0] : 0); }
static void *va_peers(void **a, int n) { return (void *)(INT_PTR)api_peers(S_(0), S_(1)); }
static void *va_clock(void **, int) { return (void *)api_clock(); }
static void *va_now(void **, int) { static double v; v = api_now(); return &v; } // (a double goes back as a pointer to one)
static void *va_stream(void **a, int n) { return (void *)(INT_PTR)api_stream(S_(0), S_(1), S_(2), S_(3), n > 4 ? (int)(INT_PTR)a[4] : 0); }
static void *va_stream_end(void **a, int n) { return (void *)(INT_PTR)api_stream_end(S_(0), S_(1)); }
static void *va_streams(void **, int) { return (void *)api_streams(); }
static void *va_file_time(void **a, int n) { static double v; v = api_file_time(S_(0)); return &v; }
static void *va_trace(void **a, int n) { api_trace(S_(0)); return nullptr; }
#undef S_

void direct_register(reaper_plugin_info_t *rec)
{
  static const struct { const char *name; void *fn, *va; const char *def; } fns[] = {
    { "StudioSync_DirectStart", (void *)api_start, (void *)va_start_,
      "int\0const char*,const char*,const char*,int\0studio,secret,inbox,port\0"
      "StudioSync's direct link: add a studio (its folder id, shared secret, inbox folder) and listen on this computer's Tailscale address "
      "(port 0: 47281; below 0: send only). Returns 1 when listening." },
    { "StudioSync_DirectStop", (void *)api_stop, (void *)va_stop, "void\0const char*\0studio\0Forget a studio; \"\" stops the direct link." },
    { "StudioSync_DirectSend", (void *)api_send, (void *)va_send,
      "int\0const char*,const char*,const char*,const char*\0studio,relpath,path,peers\0"
      "Queue an event file (relpath: <song>/rooms/<room>/events/<id>.json) for peers \"host:port host:port\". Returns 1 when queued." },
    { "StudioSync_DirectPoll", (void *)api_poll, (void *)va_poll,
      "const char*\0int\0after\0The first file received after sequence number `after`: \"seq<TAB>studio<TAB>relpath\", or \"\"." },
    { "StudioSync_DirectStatus", (void *)api_status, (void *)va_status, "const char*\0\0\0The direct link's state, as JSON." },
    { "StudioSync_DirectMsg", (void *)api_msg, (void *)va_msg,
      "int\0const char*,const char*,const char*,const char*\0studio,kind,data,peers\0"
      "Queue a small message (kind: a lower-case word such as chat, cue, claim, presence, transport, midi; data: text up to 64 KB) for peers "
      "\"host:port host:port\". Returns 1 when queued." },
    { "StudioSync_DirectMsgPoll", (void *)api_msg_poll, (void *)va_msg_poll,
      "const char*\0int\0after\0The first message received after sequence number `after`: \"seq<TAB>studio<TAB>kind<TAB>data\", or \"\"." },
    { "StudioSync_DirectPeers", (void *)api_peers, (void *)va_peers,
      "int\0const char*,const char*\0studio,peers\0The computers to keep a shared clock with (pinged on the link). Returns how many." },
    { "StudioSync_DirectClock", (void *)api_clock, (void *)va_clock,
      "const char*\0\0\0The clock estimates, as JSON: now, and per peer offset_ms (its clock minus this one's), rtt_ms, spread_ms, samples." },
    { "StudioSync_DirectNow", (void *)api_now, (void *)va_now,
      "double\0\0\0This computer's link clock, seconds since 1970 (wall time when the link started, then a monotonic high-resolution clock)." },
    { "StudioSync_DirectStream", (void *)api_stream, (void *)va_stream,
      "int\0const char*,const char*,const char*,const char*,int\0studio,relpath,path,peers,interval_ms\0"
      "Stream a file that's still being written (relpath: <song>/<name>.wav etc.) to peers every interval_ms (0: 250). Returns 1 when started." },
    { "StudioSync_DirectStreamEnd", (void *)api_stream_end, (void *)va_stream_end,
      "int\0const char*,const char*\0studio,relpath\0The streamed file is complete: send the rest, then its length and SHA-256." },
    { "StudioSync_DirectStreams", (void *)api_streams, (void *)va_streams,
      "const char*\0\0\0Streams going out and coming in, as JSON (bytes so far, done, hash ok, the received copy's path)." },
    { "StudioSync_DirectTrace", (void *)api_trace, (void *)va_trace,
      "void\0const char*\0path\0Every stream pass appends a line to this file (its size, how each way of asking it read, each peer's place and answer); \"\" stops." },
    { "StudioSync_DirectFileTime", (void *)api_file_time, (void *)va_file_time,
      "double\0const char*\0path\0A file's newest time, made or last written, seconds since 1970 (current while it's being written); -1 if it can't be read." },
  };
  char key[96];
  for (const auto &f : fns) {
    snprintf(key, sizeof(key), "API_%s", f.name); rec->Register(key, f.fn);
    snprintf(key, sizeof(key), "APIdef_%s", f.name); rec->Register(key, (void *)f.def);
    snprintf(key, sizeof(key), "APIvararg_%s", f.name); rec->Register(key, f.va);
  }
  rec->Register("atexit", (void *)direct_shutdown); // (REAPER quitting: the threads stop while everything's still there)
}
#endif
