// StudioSync's signed updates (docs/realtime-roadmap.md "Signed updates", extension 1.0.9): a studio's folder copy of StudioSync runs only when
// its lib/files.txt carries the studio owner's Ed25519 signature and every file it lists matches its SHA-256. lib/band.lua's code check asks
// here (StudioSync_VerifyFiles); the owner's key is made and used here too (StudioSync_KeyCreate, StudioSync_Sign).
// Ed25519 and SHA-512 below are TweetNaCl's (tweetnacl.c 20140427, Bernstein, van Gastel, Janssen, Lange, Schwabe, Smetsers: public domain,
// tweetnacl.cr.yp.to), unchanged in substance; added: RFC 8032's check that S < L (TweetNaCl accepts S + L too), and a seed-only key.
// SHA-256 is direct.cpp's (Brad Conte's, public domain). GPL-3.0-or-later for the rest.
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#include <bcrypt.h>
#pragma comment(lib, "bcrypt.lib")
#else
#include <fcntl.h>
#include <unistd.h>
#endif
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>
#include "direct.h"
#include "sign.h"

namespace {
typedef unsigned char u8;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int64_t i64;
typedef i64 gf[16];
#define FOR(i, n) for (i = 0; i < n; ++i)

const gf gf0 = { 0 }, gf1 = { 1 },
  D = { 0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070, 0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203 },
  D2 = { 0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0, 0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406 },
  X = { 0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c, 0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169 },
  Y = { 0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666 },
  I = { 0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43, 0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83 };

u64 dl64(const u8 *x) { u64 i, u = 0; FOR(i, 8) u = (u << 8) | x[i]; return u; }
void ts64(u8 *x, u64 u) { for (int i = 7; i >= 0; --i) { x[i] = (u8)u; u >>= 8; } }
int vn(const u8 *x, const u8 *y, int n) { u32 d = 0; for (int i = 0; i < n; ++i) d |= x[i] ^ y[i]; return (1 & ((d - 1) >> 8)) - 1; }
int verify_32(const u8 *x, const u8 *y) { return vn(x, y, 32); }

void set25519(gf r, const gf a) { int i; FOR(i, 16) r[i] = a[i]; }
void car25519(gf o)
{
  for (int i = 0; i < 16; ++i) {
    o[i] += (1LL << 16);
    const i64 c = o[i] >> 16;
    o[(i + 1) * (i < 15)] += c - 1 + 37 * (c - 1) * (i == 15);
    o[i] -= c << 16;
  }
}
void sel25519(gf p, gf q, int b)
{
  const i64 c = ~(i64)(b - 1);
  for (int i = 0; i < 16; ++i) { const i64 t = c & (p[i] ^ q[i]); p[i] ^= t; q[i] ^= t; }
}
void pack25519(u8 *o, const gf n)
{
  int i, j, b;
  gf m, t;
  FOR(i, 16) t[i] = n[i];
  car25519(t); car25519(t); car25519(t);
  FOR(j, 2) {
    m[0] = t[0] - 0xffed;
    for (i = 1; i < 15; i++) { m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1); m[i - 1] &= 0xffff; }
    m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
    b = (int)((m[15] >> 16) & 1);
    m[14] &= 0xffff;
    sel25519(t, m, 1 - b);
  }
  FOR(i, 16) { o[2 * i] = (u8)(t[i] & 0xff); o[2 * i + 1] = (u8)(t[i] >> 8); }
}
int neq25519(const gf a, const gf b) { u8 c[32], d[32]; pack25519(c, a); pack25519(d, b); return verify_32(c, d); }
u8 par25519(const gf a) { u8 d[32]; pack25519(d, a); return d[0] & 1; }
void unpack25519(gf o, const u8 *n) { int i; FOR(i, 16) o[i] = n[2 * i] + ((i64)n[2 * i + 1] << 8); o[15] &= 0x7fff; }
void A(gf o, const gf a, const gf b) { int i; FOR(i, 16) o[i] = a[i] + b[i]; }
void Z(gf o, const gf a, const gf b) { int i; FOR(i, 16) o[i] = a[i] - b[i]; }
void M(gf o, const gf a, const gf b)
{
  i64 i, j, t[31];
  FOR(i, 31) t[i] = 0;
  FOR(i, 16) FOR(j, 16) t[i + j] += a[i] * b[j];
  FOR(i, 15) t[i] += 38 * t[i + 16];
  FOR(i, 16) o[i] = t[i];
  car25519(o); car25519(o);
}
void S(gf o, const gf a) { M(o, a, a); }
void inv25519(gf o, const gf in)
{
  gf c;
  int a;
  FOR(a, 16) c[a] = in[a];
  for (a = 253; a >= 0; a--) { S(c, c); if (a != 2 && a != 4) M(c, c, in); }
  FOR(a, 16) o[a] = c[a];
}
void pow2523(gf o, const gf in)
{
  gf c;
  int a;
  FOR(a, 16) c[a] = in[a];
  for (a = 250; a >= 0; a--) { S(c, c); if (a != 1) M(c, c, in); }
  FOR(a, 16) o[a] = c[a];
}

// ---- SHA-512 ----
u64 R(u64 x, int c) { return (x >> c) | (x << (64 - c)); }
u64 Ch(u64 x, u64 y, u64 z) { return (x & y) ^ (~x & z); }
u64 Maj(u64 x, u64 y, u64 z) { return (x & y) ^ (x & z) ^ (y & z); }
u64 Sigma0(u64 x) { return R(x, 28) ^ R(x, 34) ^ R(x, 39); }
u64 Sigma1(u64 x) { return R(x, 14) ^ R(x, 18) ^ R(x, 41); }
u64 sigma0(u64 x) { return R(x, 1) ^ R(x, 8) ^ (x >> 7); }
u64 sigma1(u64 x) { return R(x, 19) ^ R(x, 61) ^ (x >> 6); }
const u64 K[80] = {
  0x428a2f98d728ae22ULL, 0x7137449123ef65cdULL, 0xb5c0fbcfec4d3b2fULL, 0xe9b5dba58189dbbcULL, 0x3956c25bf348b538ULL, 0x59f111f1b605d019ULL,
  0x923f82a4af194f9bULL, 0xab1c5ed5da6d8118ULL, 0xd807aa98a3030242ULL, 0x12835b0145706fbeULL, 0x243185be4ee4b28cULL, 0x550c7dc3d5ffb4e2ULL,
  0x72be5d74f27b896fULL, 0x80deb1fe3b1696b1ULL, 0x9bdc06a725c71235ULL, 0xc19bf174cf692694ULL, 0xe49b69c19ef14ad2ULL, 0xefbe4786384f25e3ULL,
  0x0fc19dc68b8cd5b5ULL, 0x240ca1cc77ac9c65ULL, 0x2de92c6f592b0275ULL, 0x4a7484aa6ea6e483ULL, 0x5cb0a9dcbd41fbd4ULL, 0x76f988da831153b5ULL,
  0x983e5152ee66dfabULL, 0xa831c66d2db43210ULL, 0xb00327c898fb213fULL, 0xbf597fc7beef0ee4ULL, 0xc6e00bf33da88fc2ULL, 0xd5a79147930aa725ULL,
  0x06ca6351e003826fULL, 0x142929670a0e6e70ULL, 0x27b70a8546d22ffcULL, 0x2e1b21385c26c926ULL, 0x4d2c6dfc5ac42aedULL, 0x53380d139d95b3dfULL,
  0x650a73548baf63deULL, 0x766a0abb3c77b2a8ULL, 0x81c2c92e47edaee6ULL, 0x92722c851482353bULL, 0xa2bfe8a14cf10364ULL, 0xa81a664bbc423001ULL,
  0xc24b8b70d0f89791ULL, 0xc76c51a30654be30ULL, 0xd192e819d6ef5218ULL, 0xd69906245565a910ULL, 0xf40e35855771202aULL, 0x106aa07032bbd1b8ULL,
  0x19a4c116b8d2d0c8ULL, 0x1e376c085141ab53ULL, 0x2748774cdf8eeb99ULL, 0x34b0bcb5e19b48a8ULL, 0x391c0cb3c5c95a63ULL, 0x4ed8aa4ae3418acbULL,
  0x5b9cca4f7763e373ULL, 0x682e6ff3d6b2b8a3ULL, 0x748f82ee5defb2fcULL, 0x78a5636f43172f60ULL, 0x84c87814a1f0ab72ULL, 0x8cc702081a6439ecULL,
  0x90befffa23631e28ULL, 0xa4506cebde82bde9ULL, 0xbef9a3f7b2c67915ULL, 0xc67178f2e372532bULL, 0xca273eceea26619cULL, 0xd186b8c721c0c207ULL,
  0xeada7dd6cde0eb1eULL, 0xf57d4f7fee6ed178ULL, 0x06f067aa72176fbaULL, 0x0a637dc5a2c898a6ULL, 0x113f9804bef90daeULL, 0x1b710b35131c471bULL,
  0x28db77f523047d84ULL, 0x32caab7b40c72493ULL, 0x3c9ebe0a15c9bebcULL, 0x431d67c49c100d4cULL, 0x4cc5d4becb3e42b6ULL, 0x597f299cfc657e2aULL,
  0x5fcb6fab3ad6faecULL, 0x6c44198c4a475817ULL };
u64 hashblocks(u8 *x, const u8 *m, u64 n)
{
  u64 z[8], b[8], a[8], w[16], t;
  int i, j;
  FOR(i, 8) z[i] = a[i] = dl64(x + 8 * i);
  while (n >= 128) {
    FOR(i, 16) w[i] = dl64(m + 8 * i);
    FOR(i, 80) {
      FOR(j, 8) b[j] = a[j];
      t = a[7] + Sigma1(a[4]) + Ch(a[4], a[5], a[6]) + K[i] + w[i % 16];
      b[7] = t + Sigma0(a[0]) + Maj(a[0], a[1], a[2]);
      b[3] += t;
      FOR(j, 8) a[(j + 1) % 8] = b[j];
      if (i % 16 == 15) FOR(j, 16) w[j] += w[(j + 9) % 16] + sigma0(w[(j + 1) % 16]) + sigma1(w[(j + 14) % 16]);
    }
    FOR(i, 8) { a[i] += z[i]; z[i] = a[i]; }
    m += 128;
    n -= 128;
  }
  FOR(i, 8) ts64(x + 8 * i, z[i]);
  return n;
}
const u8 iv[64] = { 0x6a, 0x09, 0xe6, 0x67, 0xf3, 0xbc, 0xc9, 0x08, 0xbb, 0x67, 0xae, 0x85, 0x84, 0xca, 0xa7, 0x3b, 0x3c, 0x6e, 0xf3, 0x72, 0xfe, 0x94,
  0xf8, 0x2b, 0xa5, 0x4f, 0xf5, 0x3a, 0x5f, 0x1d, 0x36, 0xf1, 0x51, 0x0e, 0x52, 0x7f, 0xad, 0xe6, 0x82, 0xd1, 0x9b, 0x05, 0x68, 0x8c, 0x2b, 0x3e,
  0x6c, 0x1f, 0x1f, 0x83, 0xd9, 0xab, 0xfb, 0x41, 0xbd, 0x6b, 0x5b, 0xe0, 0xcd, 0x19, 0x13, 0x7e, 0x21, 0x79 };
void hash(u8 *out, const u8 *m, u64 n)
{
  u8 h[64], x[256];
  u64 i, b = n;
  FOR(i, 64) h[i] = iv[i];
  hashblocks(h, m, n);
  m += n;
  n &= 127;
  m -= n;
  FOR(i, 256) x[i] = 0;
  FOR(i, n) x[i] = m[i];
  x[n] = 128;
  n = 256 - 128 * (n < 112);
  x[n - 9] = (u8)(b >> 61);
  ts64(x + n - 8, b << 3);
  hashblocks(h, x, n);
  FOR(i, 64) out[i] = h[i];
}

// ---- the curve ----
void add(gf p[4], gf q[4])
{
  gf a, b, c, d, t, e, f, g, h;
  Z(a, p[1], p[0]); Z(t, q[1], q[0]); M(a, a, t);
  A(b, p[0], p[1]); A(t, q[0], q[1]); M(b, b, t);
  M(c, p[3], q[3]); M(c, c, D2);
  M(d, p[2], q[2]); A(d, d, d);
  Z(e, b, a); Z(f, d, c); A(g, d, c); A(h, b, a);
  M(p[0], e, f); M(p[1], h, g); M(p[2], g, f); M(p[3], e, h);
}
void cswap(gf p[4], gf q[4], u8 b) { for (int i = 0; i < 4; ++i) sel25519(p[i], q[i], b); }
void pack(u8 *r, gf p[4])
{
  gf tx, ty, zi;
  inv25519(zi, p[2]);
  M(tx, p[0], zi);
  M(ty, p[1], zi);
  pack25519(r, ty);
  r[31] ^= par25519(tx) << 7;
}
void scalarmult(gf p[4], gf q[4], const u8 *s)
{
  set25519(p[0], gf0); set25519(p[1], gf1); set25519(p[2], gf1); set25519(p[3], gf0);
  for (int i = 255; i >= 0; --i) {
    const u8 b = (s[i / 8] >> (i & 7)) & 1;
    cswap(p, q, b);
    add(q, p);
    add(p, p);
    cswap(p, q, b);
  }
}
void scalarbase(gf p[4], const u8 *s)
{
  gf q[4];
  set25519(q[0], X); set25519(q[1], Y); set25519(q[2], gf1); M(q[3], X, Y);
  scalarmult(p, q, s);
}
const u64 L[32] = { 0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10 };
void modL(u8 *r, i64 x[64])
{
  i64 carry, i, j;
  for (i = 63; i >= 32; --i) {
    carry = 0;
    for (j = i - 32; j < i - 12; ++j) {
      x[j] += carry - 16 * x[i] * (i64)L[j - (i - 32)];
      carry = (x[j] + 128) >> 8;
      x[j] -= carry * 256;
    }
    x[j] += carry;
    x[i] = 0;
  }
  carry = 0;
  FOR(j, 32) { x[j] += carry - (x[31] >> 4) * (i64)L[j]; carry = x[j] >> 8; x[j] &= 255; }
  FOR(j, 32) x[j] -= carry * (i64)L[j];
  FOR(i, 32) { x[i + 1] += x[i] >> 8; r[i] = (u8)(x[i] & 255); }
}
void reduce(u8 *r)
{
  i64 x[64], i;
  FOR(i, 64) x[i] = (i64)(u64)r[i];
  FOR(i, 64) r[i] = 0;
  modL(r, x);
}
int unpackneg(gf r[4], const u8 p[32])
{
  gf t, chk, num, den, den2, den4, den6;
  set25519(r[2], gf1);
  unpack25519(r[1], p);
  S(num, r[1]);
  M(den, num, D);
  Z(num, num, r[2]);
  A(den, r[2], den);
  S(den2, den); S(den4, den2); M(den6, den4, den2);
  M(t, den6, num); M(t, t, den);
  pow2523(t, t);
  M(t, t, num); M(t, t, den); M(t, t, den); M(r[0], t, den);
  S(chk, r[0]); M(chk, chk, den);
  if (neq25519(chk, num)) M(r[0], r[0], I);
  S(chk, r[0]); M(chk, chk, den);
  if (neq25519(chk, num)) return -1;
  if (par25519(r[0]) == (p[31] >> 7)) Z(r[0], gf0, r[0]);
  M(r[3], r[0], r[1]);
  return 0;
}
void expand(const u8 seed[32], u8 d[64])
{
  hash(d, seed, 32);
  d[0] &= 248; d[31] &= 127; d[31] |= 64;
}
// RFC 8032 5.1.7: S must be below L (TweetNaCl leaves this out: S + L passed as a second signature)
bool below_L(const u8 *s)
{
  for (int i = 31; i >= 0; --i) { if (s[i] < L[i]) return true; if (s[i] > L[i]) return false; }
  return false;
}
#undef FOR

// ---- files and hex ----
const char HEX[] = "0123456789abcdef";
std::string hex(const u8 *p, size_t n) { std::string s; for (size_t i = 0; i < n; ++i) { s += HEX[p[i] >> 4]; s += HEX[p[i] & 15]; } return s; }
bool unhex(const std::string &s, u8 *out, size_t n)
{
  if (s.size() != n * 2) return false;
  for (size_t i = 0; i < n * 2; ++i) {
    const char c = s[i];
    const int v = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
    if (v < 0) return false;
    if (i & 1) out[i / 2] |= (u8)v; else out[i / 2] = (u8)(v << 4);
  }
  return true;
}
std::string trim(const std::string &s)
{
  size_t a = 0, b = s.size();
  while (a < b && strchr(" \t\r\n", s[a])) ++a;
  while (b > a && strchr(" \t\r\n", s[b - 1])) --b;
  return s.substr(a, b - a);
}
#ifdef _WIN32
std::wstring widen(const std::string &s)
{
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  std::wstring w(n > 0 ? n : 1, L'\0');
  if (n > 0) MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], n);
  return w;
}
FILE *open_read(const std::string &p) { return _wfopen(widen(p).c_str(), L"rb"); }
#else
FILE *open_read(const std::string &p) { return fopen(p.c_str(), "rb"); }
#endif
bool read_file(const std::string &p, std::string &out)
{
  FILE *f = open_read(p);
  if (!f) return false;
  out.clear();
  char buf[65536];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), f)) > 0) out.append(buf, n);
  const bool ok = !ferror(f);
  fclose(f);
  return ok;
}
// Text (no NUL byte) with CRLF read as LF: a Windows checkout and a Mac copy hash the same, and Lua reads CRLF as one line end anyway. A lone
// CR is kept (Lua ends a comment at one, so dropping it would let a changed file keep its hash).
std::string as_signed(const std::string &s)
{
  if (memchr(s.data(), 0, s.size())) return s;
  std::string o;
  o.reserve(s.size());
  for (size_t i = 0; i < s.size(); ++i) if (!(s[i] == '\r' && i + 1 < s.size() && s[i + 1] == '\n')) o += s[i];
  return o;
}
// A path lib/files.txt may name: relative, "/" between parts, no "." or ".." part, no drive or backslash.
bool rel_ok(const std::string &p)
{
  if (p.empty() || p.size() > 400 || p[0] == '/' || p.find('\\') != std::string::npos || p.find(':') != std::string::npos) return false;
  size_t at = 0;
  for (;;) {
    const size_t sl = p.find('/', at);
    const std::string part = p.substr(at, sl == std::string::npos ? std::string::npos : sl - at);
    if (part.empty() || part == "." || part == "..") return false;
    for (unsigned char c : part) if (c < 0x20) return false;
    if (sl == std::string::npos) return true;
    at = sl + 1;
  }
}
bool random_bytes(u8 *out, size_t n)
{
#ifdef _WIN32
  return BCryptGenRandom(nullptr, out, (ULONG)n, BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0;
#else
  const int fd = open("/dev/urandom", O_RDONLY);
  if (fd < 0) return false;
  size_t got = 0;
  while (got < n) { const ssize_t r = read(fd, out + got, n - got); if (r <= 0) break; got += (size_t)r; }
  close(fd);
  return got == n;
#endif
}
bool read_seed(const std::string &path, u8 seed[32])
{
  std::string s;
  return read_file(path, s) && unhex(trim(s).substr(0, 64), seed, 32);
}
} // namespace

void sign_sha512(const unsigned char *msg, size_t len, unsigned char out[64]) { hash(out, msg, len); }
void sign_public(const unsigned char seed[32], unsigned char pk[32])
{
  u8 d[64];
  gf p[4];
  expand(seed, d);
  scalarbase(p, d);
  pack(pk, p);
}
void sign_detached(const unsigned char seed[32], const unsigned char *msg, size_t len, unsigned char sig[64])
{
  u8 d[64], h[64], r[64], pk[32];
  i64 x[64];
  gf p[4];
  expand(seed, d);
  sign_public(seed, pk);
  std::vector<u8> sm(64 + len);
  if (len) memcpy(&sm[64], msg, len);
  memcpy(&sm[32], d + 32, 32);
  hash(r, &sm[32], len + 32);
  reduce(r);
  scalarbase(p, r);
  pack(&sm[0], p);
  memcpy(&sm[32], pk, 32);
  hash(h, &sm[0], len + 64);
  reduce(h);
  for (int i = 0; i < 64; ++i) x[i] = 0;
  for (int i = 0; i < 32; ++i) x[i] = (i64)(u64)r[i];
  for (int i = 0; i < 32; ++i) for (int j = 0; j < 32; ++j) x[i + j] += h[i] * (i64)(u64)d[j];
  modL(&sm[32], x);
  memcpy(sig, &sm[0], 64);
}
bool sign_verify(const unsigned char sig[64], const unsigned char *msg, size_t len, const unsigned char pk[32])
{
  if (!below_L(sig + 32)) return false;
  gf p[4], q[4];
  if (unpackneg(q, pk)) return false;
  std::vector<u8> buf(64 + len);
  memcpy(&buf[0], sig, 32);
  memcpy(&buf[32], pk, 32);
  if (len) memcpy(&buf[64], msg, len);
  u8 h[64], t[32];
  hash(h, &buf[0], buf.size());
  reduce(h);
  scalarmult(p, q, h);
  scalarbase(q, sig + 32);
  add(p, q);
  pack(t, p);
  return verify_32(sig, t) == 0;
}

std::string sign_file_hash(const std::string &path)
{
  std::string s;
  if (!read_file(path, s)) return "";
  s = as_signed(s);
  u8 out[32];
  direct_sha256((const u8 *)s.data(), s.size(), out);
  return hex(out, 32);
}

std::string sign_verify_files(const std::string &dir_in, const std::string &key_hex)
{
  std::string dir = dir_in;
  while (!dir.empty() && (dir.back() == '/' || dir.back() == '\\')) dir.pop_back();
  u8 pk[32], sig[64];
  if (!unhex(trim(key_hex), pk, 32)) return "the studio's update key isn't a key (64 hex digits)";
  std::string list, sig_text;
  if (!read_file(dir + "/lib/files.txt", list)) return "it has no lib/files.txt";
  if (!read_file(dir + "/lib/files.txt.sig", sig_text)) return "it isn't signed (no lib/files.txt.sig)";
  if (!unhex(trim(sig_text), sig, 64)) return "lib/files.txt.sig isn't a signature";
  list = as_signed(list);
  const std::string msg = std::string(SIGN_FILES_PREFIX) + list;
  if (!sign_verify(sig, (const u8 *)msg.data(), msg.size(), pk)) return "lib/files.txt isn't signed by the studio's update key (changed since it was signed, or signed by another key)";
  std::string version;
  int rows = 0;
  size_t at = 0;
  while (at < list.size()) {
    size_t nl = list.find('\n', at);
    if (nl == std::string::npos) nl = list.size();
    const std::string line = list.substr(at, nl - at);
    at = nl + 1;
    if (version.empty() && line.compare(0, 8, "version ") == 0) { version = trim(line.substr(8)); continue; }
    if (line.compare(0, 7, "sha256 ") != 0) continue;
    if (line.size() < 7 + 64 + 2 || line[7 + 64] != ' ') return "lib/files.txt has a SHA-256 line it can't read";
    const std::string want = line.substr(7, 64), rel = line.substr(7 + 64 + 1);
    u8 tmp[32];
    if (!unhex(want, tmp, 32) || !rel_ok(rel)) return "lib/files.txt has a SHA-256 line it can't read";
    const std::string got = sign_file_hash(dir + "/" + rel);
    if (got.empty()) return rel + " isn't there";
    if (got != hex(tmp, 32)) return rel + " doesn't match its signed SHA-256";
    ++rows;
  }
  if (version.empty() || version.find_first_of(" \t") != std::string::npos) return "lib/files.txt has no version line";
  if (!rows) return "lib/files.txt lists no SHA-256 hashes";
  return "ok " + version + "\n" + list;
}

std::string sign_key_create(const std::string &path)
{
  u8 seed[32], pk[32];
  std::string have;
  if (read_file(path, have)) { // (there already: read, never overwritten. Unreadable as a key: "", so a damaged key file isn't replaced)
    if (!unhex(trim(have).substr(0, 64), seed, 32)) return "";
    sign_public(seed, pk);
    return hex(pk, 32);
  }
  if (!random_bytes(seed, 32)) return "";
  const std::string text = hex(seed, 32) + "\n";
#ifdef _WIN32
  FILE *f = _wfopen(widen(path).c_str(), L"wbx"); // (a user's profile folder is theirs alone already)
  if (!f) return "";
  const bool ok = fwrite(text.data(), 1, text.size(), f) == text.size();
  if (fclose(f) != 0 || !ok) { _wremove(widen(path).c_str()); return ""; }
#else
  const int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0600); // (only this user can read it)
  if (fd < 0) return "";
  const bool ok = write(fd, text.data(), text.size()) == (ssize_t)text.size();
  if (close(fd) != 0 || !ok) { unlink(path.c_str()); return ""; }
#endif
  memset(seed, 0, sizeof(seed));
  return sign_key_create(path); // (read back: what's on disk is what's used)
}

std::string sign_with_key(const std::string &path, const std::string &msg)
{
  u8 seed[32], sig[64];
  if (!read_seed(path, seed)) return "";
  sign_detached(seed, (const u8 *)msg.data(), msg.size(), sig);
  memset(seed, 0, sizeof(seed));
  return hex(sig, 64);
}

// ---- ReaScript: reaper.StudioSync_Verify* etc. (REAPER's main thread only: the answers live in static strings until the next call) ----
#ifndef SIGN_STANDALONE
#include "reaper_plugin.h"
#ifdef min // (SWELL, macOS/Linux: min/max as macros broke std::min and the C++ headers after it. CI, 2026-11-19)
#undef min
#endif
#ifdef max
#undef max
#endif
static const char *str(const char *s) { return s ? s : ""; }
static int api_verify(const char *sig, const char *msg, const char *key)
{
  u8 s[64], k[32];
  const std::string m = str(msg);
  return unhex(trim(str(sig)), s, 64) && unhex(trim(str(key)), k, 32) && sign_verify(s, (const u8 *)m.data(), m.size(), k) ? 1 : 0;
}
static const char *api_verify_files(const char *dir, const char *key) { static std::string r; r = sign_verify_files(str(dir), str(key)); return r.c_str(); }
static const char *api_key_create(const char *path) { static std::string r; r = sign_key_create(str(path)); return r.c_str(); }
static const char *api_sign(const char *path, const char *msg) { static std::string r; r = sign_with_key(str(path), str(msg)); return r.c_str(); }
static const char *api_file_hash(const char *path) { static std::string r; r = sign_file_hash(str(path)); return r.c_str(); }
#define S_(i) (n > (i) ? (const char *)a[i] : nullptr)
static void *va_verify(void **a, int n) { return (void *)(INT_PTR)api_verify(S_(0), S_(1), S_(2)); }
static void *va_verify_files(void **a, int n) { return (void *)api_verify_files(S_(0), S_(1)); }
static void *va_key_create(void **a, int n) { return (void *)api_key_create(S_(0)); }
static void *va_sign(void **a, int n) { return (void *)api_sign(S_(0), S_(1)); }
static void *va_file_hash(void **a, int n) { return (void *)api_file_hash(S_(0)); }
#undef S_

void sign_register(reaper_plugin_info_t *rec)
{
  static const struct { const char *name; void *fn, *va; const char *def; } fns[] = {
    { "StudioSync_Verify", (void *)api_verify, (void *)va_verify,
      "int\0const char*,const char*,const char*\0signature,message,key\0"
      "Is `signature` (128 hex digits) an Ed25519 signature of `message` by `key` (64 hex digits)? Returns 1 or 0." },
    { "StudioSync_VerifyFiles", (void *)api_verify_files, (void *)va_verify_files,
      "const char*\0const char*,const char*\0dir,key\0"
      "Is the StudioSync copy in `dir` signed by `key`: lib/files.txt.sig over lib/files.txt, and every file it lists by SHA-256 matching? "
      "Returns \"ok <version>\" and a new line and lib/files.txt as signed, or why not." },
    { "StudioSync_KeyCreate", (void *)api_key_create, (void *)va_key_create,
      "const char*\0const char*\0path\0"
      "The update key at `path` (its folder must exist): made if there's none, never overwritten. Returns its public key (64 hex digits), or \"\"." },
    { "StudioSync_Sign", (void *)api_sign, (void *)va_sign,
      "const char*\0const char*,const char*\0keypath,message\0`message` signed with the update key at `keypath`: 128 hex digits, or \"\"." },
    { "StudioSync_FileHash", (void *)api_file_hash, (void *)va_file_hash,
      "const char*\0const char*\0path\0A file's SHA-256 as lib/files.txt lists it (text with CRLF read as LF): 64 hex digits, or \"\"." },
  };
  char key[96];
  for (const auto &f : fns) {
    snprintf(key, sizeof(key), "API_%s", f.name); rec->Register(key, f.fn);
    snprintf(key, sizeof(key), "APIdef_%s", f.name); rec->Register(key, (void *)f.def);
    snprintf(key, sizeof(key), "APIvararg_%s", f.name); rec->Register(key, f.va);
  }
}
#endif
