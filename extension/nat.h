// StudioSync's Tailscale-free connection, the spike (docs/realtime-roadmap.md "Without Tailscale: design"). Not in the shipped extension:
// only tests/nat_test.cpp builds it (with -DSTUDIOSYNC_NAT, libjuice and Monocypher from extension/third_party).
//  - ICE (libjuice, MPL-2.0) finds a UDP path between two computers behind NATs: host, server-reflexive (STUN) or relayed (TURN).
//  - The rendezvous is a folder: each side writes one signed file for the other (the studio's shared folder in the design, so Syncthing
//    carries it and vouches for who wrote it); STUN/TURN is libjuice's own server, which a studio's hub can run.
//  - Every datagram is sealed with XChaCha20-Poly1305 (Monocypher, CC0/BSD-2) under keys from a handshake that needs all three of: the
//    studio secret, each computer's own static X25519 key (its public half in its devices file), and fresh ephemeral keys (forward secrecy).
// GPL-3.0-or-later.
#pragma once
#include <cstddef>
#include <cstdint>
#include <string>

struct NatKeys { unsigned char pub[32], priv[32]; };
bool nat_random(void *p, size_t n); // the system's CSPRNG
bool nat_keypair(NatKeys &k);
std::string nat_studio_key(const std::string &secret); // HMAC-SHA256(secret, "StudioSync nat v1"): a label of its own

// A session's keys (one per direction) and the receive replay window.
struct NatSession { unsigned char tx[32] = {}, rx[32] = {}; uint64_t next = 0, top = 0, seen = 0; bool have = false; };
// Both sides call it with the same initiator (the lower device id) and ids. -> false on a degenerate key (an all-zero shared secret).
bool nat_derive(NatSession &s, const std::string &studio_key, bool initiator, const NatKeys &my_static, const unsigned char their_static[32],
                const NatKeys &my_eph, const unsigned char their_eph[32], const std::string &id_i, const std::string &id_r);
std::string nat_seal(NatSession &s, const void *p, size_t n);            // "SSN1" | counter u64 | ciphertext | 16-byte tag
bool nat_open(NatSession &s, const void *p, size_t n, std::string &out); // false: forged, damaged, another key, or a replay

// The rendezvous message: kind "offer" (the initiator's) or "answer" (carries the offer's ephemeral key back as `re`).
std::string nat_signal(const std::string &studio_key, const char *kind, const std::string &from, const std::string &to,
                       const unsigned char eph[32], const unsigned char *re, long long t, const std::string &sdp);
bool nat_signal_read(const std::string &studio_key, const std::string &text, const std::string &me, const std::string &peer, long long now,
                     std::string &kind, unsigned char eph[32], unsigned char re[32], std::string &sdp, std::string &why);

// One ICE link to one peer, through a rendezvous folder.
struct NatLinkConfig {
  std::string folder, me, peer, secret;       // ids: plain names (letters, digits, - _), the device ids in the design
  NatKeys my_static;                          // this computer's
  unsigned char peer_static[32];              // the peer's public key (its devices file, in the design)
  std::string stun_host; int stun_port = 0;   // "" : host candidates only
  std::string turn_user, turn_pass;           // set: also TURN on the same server
  int only = 0;                               // the test: 1 publish relayed candidates only (two strict NATs), 2 none on Tailscale
};
struct NatLink;
NatLink *nat_link_new(const NatLinkConfig &c);
void nat_link_free(NatLink *l);
// Call often (not from a juice callback): writes this side's file when gathered, reads the peer's. -> 1 up (a datagram from the peer
// has opened), 0 not yet, -1 failed (the why in nat_link_status).
int nat_link_tick(NatLink *l);
bool nat_link_send(NatLink *l, const void *p, size_t n);
bool nat_link_recv(NatLink *l, std::string &out);           // the next opened datagram
void nat_link_inject(NatLink *l, const std::string &raw);   // the test: as if `raw` arrived from the network
std::string nat_link_last_sealed(NatLink *l);               // the test: the last datagram as it went out
std::string nat_link_status(NatLink *l);                    // state, the selected pair, counts, why
