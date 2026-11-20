// StudioSync's connection without Tailscale (docs/realtime-roadmap.md "Without Tailscale: design"). Stage 1: live audio's datagrams for the
// bandmates the tailnet doesn't reach, while the studio has band.json "nat" on (lib/nat.lua decides who; extension/rtaudio.cpp sends to them
// through the synthetic addresses below, so AOO's code doesn't change).
//  - ICE (libjuice, MPL-2.0) finds a UDP path between two computers behind NATs: host, server-reflexive (STUN) or relayed (TURN).
//  - The rendezvous is a folder: each side writes one signed file for the other (<studio>/_band/nat/<from>-<to>.json, so Syncthing carries
//    it and vouches for who wrote it); STUN from a public list or the studio's own server.
//  - Every datagram is sealed with XChaCha20-Poly1305 (Monocypher, CC0/BSD-2) under keys from a handshake that needs all three of: the
//    studio secret, each computer's own static X25519 key (its public half in its devices file), and fresh ephemeral keys (forward secrecy).
// Stage 3 (docs/rt/rt-nat3.md): the studio hub runs libjuice's STUN/TURN server as the studio's relay for pairs no hole punch joins (credentials
// from the studio key, rate and allocation caps; still sealed end to end), rendezvous messages also ride the links that are up (sub-second,
// the folder the fallback), links are made again at once when this computer's network changes (an ICE restart with new keys).
// shortcut: the handshake (nat_derive) is our own Noise-KK-style construction, not yet reviewed from outside; James deferred security reviews
// until every feature is in (2026-11-19). Review it (or swap in Noise-C) before the setting is on by default.
// GPL-3.0-or-later.
#pragma once
#include <cstddef>
#include <cstdint>
#include <deque>
#include <map>
#include <string>
#include <vector>

#define NAT_SIGNAL_AGE 300 // s: a rendezvous file older than this is ignored (Syncthing can take a while; a replay gains nothing without the keys)
#define NAT_PORT 47282     // the first of NAT_PORTS UDP ports libjuice binds (one per bandmate); the firewall rule covers the range
#define NAT_PORTS 16
#define NAT_AUDIO_PORT 47281 // the port in every synthetic address (198.18.0.0/15 + a hash of the device id): what live audio's AOO names
// Stage 3 (docs/rt/rt-nat3.md): the studio hub's own STUN/TURN (libjuice's server) on UDP NAT_RELAY_PORT, relayed addresses on the
// NAT_RELAY_PORTS after it (its router forwards all of them; StudioSync never touches a router or firewall itself).
#define NAT_RELAY_PORT 47298
#define NAT_RELAY_PORTS 16
#define NAT_RELAY_RATE (1024 * 1024)      // bytes a second the relay sends in all (a live-audio stream is ~32 KB/s): beyond it, dropped
#define NAT_RELAY_RATE_EACH (256 * 1024)  // bytes a second to any one address
#define NAT_RELAY_ALLOCS 64               // relayed addresses at once in all
#define NAT_RELAY_ALLOCS_EACH NAT_PORTS   // per computer (one per link)

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
  std::string turn_user, turn_pass;           // set: also TURN (on turn_host, else the STUN server)
  std::string turn_host; int turn_port = 0;   // (stage 3: the studio hub's relay)
  int only = 0;                               // the test: 1 publish relayed candidates only (two strict NATs), 2 none on Tailscale
  std::string offer_e;                        // (stage 3, the responder) answer only the offer with this ephemeral key (hex; "": any)
  long long offer_t = 0;                      //   and its time: a newer offer before the answer ends this link (the hub answers that one)
  std::string bind;                           // the address libjuice binds ("": all; the test gives each simulated NAT its own)
  int port_lo = 0, port_hi = 0;               // libjuice's local port range (0: any)
  double timeout_s = 30;                      // no path by then: failed
  void (*on_data)(void *user, const char *d, size_t n) = nullptr; // each opened datagram (juice's thread); null: queued for nat_link_recv
  void *user = nullptr;
  void (*on_stream)(void *user, const char *d, size_t n) = nullptr; // (stage 2) each opened stream segment (juice's thread); null: dropped
  // (stage 3) the rendezvous over other links: the peer's message as another way brought it ("" none), this side's message handed on too,
  // and each opened signal fragment (juice's thread)
  std::string (*signal_in)(void *user) = nullptr;
  void (*signal_out)(void *user, const std::string &msg) = nullptr;
  void (*on_signal)(void *user, const char *d, size_t n) = nullptr;
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
void nat_link_path(NatLink *l, std::string &local, std::string &remote); // the chosen pair's kinds: host, srflx, prflx, relay ("": none yet)

// ---- the studio's links (one hub per computer in REAPER: nat_global; tests make their own) ------------------------------------------------
struct NatHub;
NatHub *nat_hub_new();
void nat_hub_free(NatHub *h);
// {"folder":"<studio>/_band/nat","me":"<device id>","secret":"<studio secret>","key":"<private key file>","port":47282,
//  "stun":["host:port",...],"peers":[{"device":"<id>","pub":"<64 hex>"},...]}: links to those peers kept up (the lower device id offers,
// retried with a growing pause), the others dropped. -> how many peers, or -1 (bad JSON, no key: nat_hub_status's error says why).
// Stage 3 adds "turn":"host:port" (the studio hub's relay: used once its STUN answers) and, on the hub, "relay":{"port":47298,
// "users":["<device id>",...],"rate":bytes/s,"rate_each":bytes/s,"allocs":n,"allocs_each":n} (libjuice's STUN/TURN server; each
// user's password from the studio secret: nat_relay_pass).
int nat_hub_setup(NatHub *h, const char *json);
void nat_hub_stop(NatHub *h);           // every link down, nothing configured
// JSON: on, me, error, nat ("easy", "strict", "blocked", "unknown"), public, turn, relay_ok, restarts, signals { in, carried, forwarded, bad },
// relay { on, running, port, external, error, bytes, over_cap }, peers = { [device] = { state, path, local, remote, why, nopath, fails, up_s, sent, opened, refused, ... } }
std::string nat_hub_status(NatHub *h);
// The relay's password for a computer (its device id is the user name): only those with the studio secret can make it.
std::string nat_relay_pass(const std::string &studio_key, const std::string &user);
// The relay's caps (process-wide: one relay per REAPER). libjuice's server sends every datagram through nat_relay_sendto (built with
// -Dudp_sendto=nat_relay_sendto for server.c only: third_party/build_*), which drops what's over them.
void nat_relay_caps(long long rate, long long rate_each);
// This computer's static key: the private half in `path` (made when missing, readable by this user only, never in a synced folder), -> the
// public half as 64 hex, or "" and why.
std::string nat_key_public(const std::string &path, std::string &why);
bool nat_key_load(const std::string &path, NatKeys &k, bool create, std::string &why);

// ---- live audio's side (extension/rtaudio.cpp): a bandmate reached this way has a synthetic IPv4 address, the same on every computer ------
bool nat_is_synthetic(const void *sockaddr_in_p);                       // 198.18.0.0/15
bool nat_resolve(NatHub *h, const char *peer, void *sockaddr_in_out);   // "nat:<device id>" (configured) -> its address
bool nat_up(NatHub *h, const void *sockaddr_in_p);                      // that bandmate's link is up
int nat_sendto(NatHub *h, const void *sockaddr_in_p, const void *d, int n); // -> n sent, -1 not (no link up, too big)
typedef void (*nat_rx_fn)(void *user, const unsigned char *d, int n, const void *from_sockaddr_in);
void nat_set_rx(NatHub *h, nat_rx_fn fn, void *user); // every opened datagram (libjuice's thread); null waits for a call in flight to end
std::string nat_self(NatHub *h);  // "198.18.x.y:47281": this computer as the others name it ("" before nat_hub_setup)
bool nat_active(NatHub *h);       // set up, with at least one peer
NatHub *nat_global();             // REAPER's (the one StudioSync_Nat* drives and live audio uses)

// ---- stage 2: the direct link over a link (docs/rt/rt-nat2.md) -------------------------------------------------------------------------
// direct.cpp's connections (frames, answers, windows, Lanes: all unchanged) ride a link as streams: each one a loopback TCP socket pair, one
// end direct.cpp's, the other this side's pump, which carries its bytes over sealed datagrams reliably and in order (NatRel below). A stream
// opened by the other computer is handed to direct.cpp's server (direct_adopt), never to the web UI.
// -> a socket for direct.cpp to send frames on to that bandmate (its answers come back on it), or ~0 and why (no link up: Syncthing then).
unsigned long long nat_connect(NatHub *h, const char *dev, std::string &why);
#define NAT_SEG 1200          // data bytes in one segment (+ 25 header + 1 kind + 28 sealing: well inside a path's ~1472)
#define NAT_SEG_HDR 25        // flags u8, stream u32, offset u64, ack u64, window u32 (big-endian)
#define NAT_SBUF (256 * 1024) // bytes a stream holds to send (direct.cpp's socket waits beyond it: TCP's own back-pressure)
#define NAT_RCV_WND (256 * 1024) // bytes a stream takes ahead of what's delivered; a segment past it is dropped (sent again later)
#define NAT_STREAMS 16        // streams per bandmate at once
#define NAT_TRIES 10          // a segment sent this many times unanswered: the stream is dead (~20 s with the back-off)
enum { NAT_F_OPEN = 1, NAT_F_FIN = 2, NAT_F_RST = 4 };
// One stream's reliable, ordered bytes over datagrams: cumulative acks, a retransmit timer per segment (doubling to 3 s), a fast resend on
// three repeated acks, a congestion window (halved on a loss), the receiver's window, a FIN each way. Pure: time is passed in, segments out.
struct NatSeg { unsigned char flags; uint64_t off; std::string data; };
struct NatRel {
  std::string sbuf;               // bytes from `una` on: sent and unanswered, then not sent yet
  uint64_t una = 0, nxt = 0;      // the first unanswered byte, the next new one
  struct Fl { uint64_t off; uint32_t n; double at; int tries; bool fin; };
  std::deque<Fl> fl;              // in flight, oldest first
  bool closing = false, fin_sent = false, fin_acked = false, need_ack = false, dead = false, heard = false;
  uint64_t fin_off = 0, peer_wnd = NAT_RCV_WND, adv = NAT_RCV_WND;
  double cwnd = 16, srtt = -1, rto = 0.3;
  int dup = 0;
  long long resent = 0, dropped = 0; // (segments sent again; segments refused here: past the window, past the FIN)
  uint64_t rcv = 0;               // the next byte expected
  std::map<uint64_t, std::string> ooo; // arrived ahead of `rcv`
  std::string rbuf;               // in order, not yet taken by the reader
  bool rfin = false, rclosed = false;
  uint64_t rfin_off = 0;
  size_t room() const { return sbuf.size() >= NAT_SBUF ? 0 : NAT_SBUF - sbuf.size(); }
  size_t write(const char *p, size_t n); // -> bytes taken (room() at most); none after close()
  void close();                          // nothing more to send: a FIN after what's queued
  void took(size_t n);                   // the reader took n bytes from rbuf's front
  void input(unsigned char flags, uint64_t off, uint64_t ack, uint32_t wnd, const char *d, size_t n, double now);
  void pump(double now, std::vector<NatSeg> &out); // what to send now: new data, what timed out, an ack
  uint64_t ack_no() const { return rcv + (rclosed ? 1 : 0); }
  uint32_t wnd() const { return rbuf.size() >= NAT_RCV_WND ? 0 : (uint32_t)(NAT_RCV_WND - rbuf.size()); }
  bool done() const { return closing && fin_acked && rclosed && rbuf.empty(); }
};
std::string nat_seg_encode(unsigned char flags, uint32_t id, uint64_t off, uint64_t ack, uint32_t wnd, const std::string &data);
bool nat_seg_decode(const char *p, size_t n, unsigned char &flags, uint32_t &id, uint64_t &off, uint64_t &ack, uint32_t &wnd, const char *&data, size_t &dn);
#ifdef NAT_STANDALONE
// The test: what a link sends of the streams' segments is dropped, doubled or held back behind the next one, at these rates (per mille).
void nat_test_lossy(NatHub *h, int drop, int dup, int reorder);
bool nat_test_inject(NatHub *h, const char *dev, const std::string &raw); // as if `raw` arrived on that link from the network
std::string nat_test_sealed(NatHub *h, const char *dev); // the last datagram that link sent, as it went out
// (stage 3) new links publish relayed candidates only (1) and bind `bind` (127.0.0.x: each its own, so on one computer nothing but the
// relay joins them): two symmetric NATs
void nat_test_only(NatHub *h, int only, const char *bind = nullptr);
void nat_test_netchange(NatHub *h);           // as if this computer's network changed (Wi-Fi to tethering)
void nat_test_carry(NatHub *h, bool on);      // rendezvous messages over other links (on by default)
#endif
#ifndef NAT_STANDALONE
struct reaper_plugin_info_t;
extern "C" void nat_register(reaper_plugin_info_t *rec); // StudioSync_NatKey, NatSetup, NatStatus, NatStop (C linkage: reaper_menu.cpp declares it inside its extern "C" entry point)
#endif
