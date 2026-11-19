// StudioSync's signed updates (docs/realtime-roadmap.md "Signed updates"): Ed25519 signatures over a copy's lib/files.txt, checked here so
// a studio's folder copy runs only when the studio owner signed it. The core has no REAPER in it, so tests/sign_test.cpp builds it alone
// (-DSIGN_STANDALONE). GPL-3.0-or-later.
#pragma once
#include <cstddef>
#include <string>

// Ed25519 (RFC 8032): a 32-byte seed is the private key.
void sign_public(const unsigned char seed[32], unsigned char pk[32]);
void sign_detached(const unsigned char seed[32], const unsigned char *msg, size_t len, unsigned char sig[64]);
bool sign_verify(const unsigned char sig[64], const unsigned char *msg, size_t len, const unsigned char pk[32]);
void sign_sha512(const unsigned char *msg, size_t len, unsigned char out[64]);

// A file's SHA-256 as signed: text (no NUL byte) with CRLF read as LF, anything else as it is. -> 64 hex, or "" when it can't be read.
std::string sign_file_hash(const std::string &path);
// Is `dir`'s lib/files.txt signed by `key_hex`, and does every file it lists by SHA-256 match? -> "ok <version>\n<files.txt as signed>",
// or why not.
std::string sign_verify_files(const std::string &dir, const std::string &key_hex);
// The private key at `path`, made if there's none (a new random seed, written only for this user). -> the public key in hex, or "".
std::string sign_key_create(const std::string &path);
// `msg` signed with the key at `path`. -> 128 hex, or "" when there's no key there.
std::string sign_with_key(const std::string &path, const std::string &msg);
// What lib/files.txt.sig signs: this prefix, then lib/files.txt with CRLF read as LF.
#define SIGN_FILES_PREFIX "StudioSync files.txt v1\n"

#ifndef SIGN_STANDALONE
struct reaper_plugin_info_t;
extern "C" void sign_register(reaper_plugin_info_t *rec); // (C linkage: reaper_menu.cpp declares it inside its extern "C" entry point)
// the ReaScript functions StudioSync_Verify*, StudioSync_KeyCreate, StudioSync_Sign, StudioSync_FileHash
#endif
