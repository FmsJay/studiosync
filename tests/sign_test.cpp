// Signed updates' native test (extension/sign.cpp, no REAPER): RFC 8032's Ed25519 test vectors, tampered messages, signatures and keys
// refused, and a signed copy checked file by file. "sign_test verify <dir> <key>" checks a copy signed elsewhere (tools/sign_release.py) and
// exits 0 only when it's ok. Build: tests/build_sign_test.cmd (Windows), or
//   c++ -std=c++17 -O2 -DSIGN_STANDALONE -DDIRECT_STANDALONE tests/sign_test.cpp extension/sign.cpp extension/direct.cpp extension/direct_audio.cpp -pthread
// GPL-3.0-or-later.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>
#ifdef _WIN32
#include <direct.h>
#define make_dir(p) _mkdir(p)
#define remove_dir(p) _rmdir(p)
#else
#include <sys/stat.h>
#define make_dir(p) mkdir(p, 0700)
#include <unistd.h>
#define remove_dir(p) rmdir(p)
#endif
#include "../extension/sign.h"

static int fails = 0;
static void check(bool ok, const char *what) { printf("%s %s\n", ok ? "ok  " : "FAIL", what); if (!ok) ++fails; }
static std::vector<unsigned char> unhex(const std::string &s)
{
  std::vector<unsigned char> o;
  for (size_t i = 0; i + 1 < s.size(); i += 2) o.push_back((unsigned char)strtol(s.substr(i, 2).c_str(), nullptr, 16));
  return o;
}
static std::string hex(const unsigned char *p, size_t n)
{
  static const char H[] = "0123456789abcdef";
  std::string s;
  for (size_t i = 0; i < n; ++i) { s += H[p[i] >> 4]; s += H[p[i] & 15]; }
  return s;
}
static void put(const std::string &path, const std::string &data)
{
  FILE *f = fopen(path.c_str(), "wb");
  if (f) { fwrite(data.data(), 1, data.size(), f); fclose(f); }
}

// RFC 8032 section 7.1: TEST 1, 2, 3 and SHA(abc)
struct Vec { const char *sk, *pk, *msg, *sig; };
static const Vec V[] = {
  { "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
    "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b" },
  { "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb", "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
    "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00" },
  { "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7", "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025", "af82",
    "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a" },
  { "833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42", "ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf",
    "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
    "dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b58909351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704" },
};

int main(int argc, char **argv)
{
  if (argc == 4 && !strcmp(argv[1], "verify")) {
    const std::string r = sign_verify_files(argv[2], argv[3]);
    printf("%s\n", r.substr(0, r.find('\n')).c_str());
    return r.compare(0, 3, "ok ") == 0 ? 0 : 1;
  }
  unsigned char h[64];
  sign_sha512((const unsigned char *)"abc", 3, h);
  check(hex(h, 64) == V[3].msg, "SHA-512(abc)");

  for (const Vec &v : V) {
    const auto sk = unhex(v.sk), pk = unhex(v.pk), msg = unhex(v.msg), sig = unhex(v.sig);
    unsigned char p[32], s[64];
    sign_public(sk.data(), p);
    check(hex(p, 32) == v.pk, "public key from the RFC 8032 secret");
    sign_detached(sk.data(), msg.data(), msg.size(), s);
    check(hex(s, 64) == v.sig, "signature as RFC 8032 has it");
    check(sign_verify(sig.data(), msg.data(), msg.size(), pk.data()), "RFC 8032 signature verifies");
    std::vector<unsigned char> m2 = msg;
    m2.push_back(0);
    check(!sign_verify(sig.data(), m2.data(), m2.size(), pk.data()), "a longer message is refused");
    if (!msg.empty()) { m2 = msg; m2[0] ^= 1; check(!sign_verify(sig.data(), m2.data(), m2.size(), pk.data()), "a changed message is refused"); }
    std::vector<unsigned char> s2 = sig;
    s2[5] ^= 0x10;
    check(!sign_verify(s2.data(), msg.data(), msg.size(), pk.data()), "a changed R is refused");
    s2 = sig; s2[40] ^= 0x01;
    check(!sign_verify(s2.data(), msg.data(), msg.size(), pk.data()), "a changed S is refused");
    // S + L: the same point, a second encoding of the signature (RFC 8032 refuses S >= L)
    static const unsigned char L[32] = { 0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10 };
    s2 = sig;
    int carry = 0;
    for (int i = 0; i < 32; ++i) { const int t = s2[32 + i] + L[i] + carry; s2[32 + i] = (unsigned char)t; carry = t >> 8; }
    check(!sign_verify(s2.data(), msg.data(), msg.size(), pk.data()), "S + L is refused");
    std::vector<unsigned char> k2 = pk;
    k2[0] ^= 1;
    check(!sign_verify(sig.data(), msg.data(), msg.size(), k2.data()), "another key is refused");
  }

  // a copy, signed and checked file by file
  const char *tmp = getenv("TEMP") ? getenv("TEMP") : getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp";
  const std::string dir = std::string(tmp) + "/ss_sign_test_" + std::to_string((long long)time(nullptr) % 100000);
  make_dir(dir.c_str());
  make_dir((dir + "/lib").c_str());
  const std::string key = dir + "/update-key";
  remove(key.c_str());
  const std::string pub = sign_key_create(key);
  check(pub.size() == 64, "a key is made");
  check(sign_key_create(key) == pub, "made once: read back the same");
  const std::string band = "local band = { VERSION = \"9.9.9\" }\r\nreturn band\r\n", bin = std::string("\x7f" "ELF\0\r\n\x01", 8);
  put(dir + "/lib/band.lua", band);
  put(dir + "/lib/tool.bin", bin);
  const std::string list = "version 9.9.9\nlib/band.lua\t40\t0\nsha256 " + sign_file_hash(dir + "/lib/band.lua") + " lib/band.lua\nsha256 " +
    sign_file_hash(dir + "/lib/tool.bin") + " lib/tool.bin\n";
  put(dir + "/lib/files.txt", list);
  put(dir + "/lib/files.txt.sig", sign_with_key(key, SIGN_FILES_PREFIX + list) + "\n");
  std::string r = sign_verify_files(dir, pub);
  check(r == "ok 9.9.9\n" + list, "a signed copy checks, and the list comes back");
  put(dir + "/lib/band.lua", "local band = { VERSION = \"9.9.9\" }\nreturn band\n");
  check(sign_verify_files(dir, pub).compare(0, 3, "ok ") == 0, "the same text with LF line ends still checks");
  put(dir + "/lib/band.lua", "local band = { VERSION = \"9.9.9\" }\r\rreturn band\r\n");
  check(sign_verify_files(dir, pub).find("lib/band.lua doesn't match") == 0, "a lone CR added is refused (it ends a Lua comment)");
  put(dir + "/lib/band.lua", band);
  put(dir + "/lib/tool.bin", std::string("\x7f" "ELF\0\n\x01", 7));
  check(sign_verify_files(dir, pub).find("lib/tool.bin doesn't match") == 0, "a binary is hashed as it is: a CR taken out is refused");
  put(dir + "/lib/tool.bin", bin);
  put(dir + "/lib/files.txt", list + "sha256 " + sign_file_hash(dir + "/lib/band.lua") + " lib/extra.lua\n");
  check(sign_verify_files(dir, pub).find("isn't signed by") != std::string::npos, "a changed lib/files.txt is refused");
  put(dir + "/lib/files.txt", list);
  check(sign_verify_files(dir, std::string(64, 'a')).find("isn't signed by") != std::string::npos, "another key is refused");
  check(sign_verify_files(dir, "xyz").find("isn't a key") != std::string::npos, "a key that isn't one is refused");
  remove((dir + "/lib/files.txt.sig").c_str());
  check(sign_verify_files(dir, pub).find("no lib/files.txt.sig") != std::string::npos, "no .sig is refused");
  const std::string bad = "version 9.9.9\nsha256 " + sign_file_hash(dir + "/lib/band.lua") + " ../outside.lua\n";
  put(dir + "/lib/files.txt", bad);
  put(dir + "/lib/files.txt.sig", sign_with_key(key, SIGN_FILES_PREFIX + bad));
  check(sign_verify_files(dir, pub).find("can't read") != std::string::npos, "a path out of the copy is refused, signed or not");
  for (const char *f : { "/lib/band.lua", "/lib/tool.bin", "/lib/files.txt", "/lib/files.txt.sig", "/update-key" }) remove((dir + f).c_str());
  remove_dir((dir + "/lib").c_str());
  remove_dir(dir.c_str());
  printf("%s (%d failed)\n", fails ? "FAILED" : "all ok", fails);
  return fails ? 1 : 0;
}
