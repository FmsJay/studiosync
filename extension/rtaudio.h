// StudioSync's built-in real-time audio (docs/realtime-roadmap.md step 4; replaces SonoBus): each computer sends its chosen hardware inputs
// as Opus through an AOO source (extension/third_party/aoo, BSD) to the studio's other computers over Tailscale UDP, and mixes every
// peer's stream, through an AOO sink with its jitter buffer, into REAPER's first output pair (the audio hook's post call: heard here,
// not recorded). Every datagram carries a tag made with the studio secret, so only studio computers are heard. Nothing runs until
// started. The core has no REAPER in it, so tests/rtaudio_test.cpp runs two or three of these on localhost (and a hub with three listeners).
// GPL-3.0-or-later.
#pragma once
#include <string>

#define RT_MAX_PEERS 16
#define RT_MAX_CH 8

struct RtLink;
RtLink *rt_new();
void rt_free(RtLink *l);
// first_input/nch: the hardware inputs to send (nch 1..8); kbps: Opus's total rate (16..512); port: the UDP port (0: the peers JSON's,
// else the direct link's number, 47281); bind_ip: "" finds this computer's Tailscale address (the test passes 127.0.0.1).
// -> 1 started, else 0 (rt_status says why). Nothing is sent or heard until rt_peers has given the studio secret.
int rt_start(RtLink *l, int first_input, int nch, int kbps, int port, const char *bind_ip);
void rt_stop(RtLink *l);
// Who to send to and hear, and the key: {"secret":"<the studio secret>","port":47281,"peers":["name:port",...]} (the direct link's peer
// list; Tailscale addresses only). Before or after rt_start. -> how many peers, or -1 when the JSON isn't that.
int rt_peers(RtLink *l, const char *json);
// A peer's level in the cue mix (gain: linear, 0..4) and mute. -> 1 when that peer is in the list.
int rt_peer_set(RtLink *l, const char *peer, double gain, int mute);
// A peer's adaptive jitter buffer bounds, ms: it starts at the floor, grows on underruns up to the ceiling, shrinks back after a steady spell
// (rtaudio.cpp adapt). 0 or less: the default (30, 150). -> 1 when that peer is in the list. (James, rt)
int rt_peer_buffer(RtLink *l, const char *peer, double floor_ms, double ceil_ms);
// tests/rtaudio_test.cpp only: the receive thread reads nothing for ms (what arrives waits in the socket and comes at once after: Wi-Fi's
// bursts), and the adaptive buffer's timings x times faster.
void rt_test_hold(RtLink *l, double ms);
void rt_test_speed(RtLink *l, double x);
// tests only: the hub's mixing stalls for ms (its ring fills, as when its send thread is held up); and, before rt_start, AOO's drift
// correction off (resample 0), or on without its first minutes' hold (2: the clock's estimate used in full from 6 s).
void rt_test_hold_mix(RtLink *l, double ms);
// tests only: the send thread doesn't run for ms (with rt_test_hold: a VM's guest descheduled; hub_watch's stalls)
void rt_test_hold_tx(RtLink *l, double ms);
// tests only: nothing arrives for ms (a Wi-Fi outage here: hub_watch's own_outage)
void rt_test_drop(RtLink *l, double ms);
void rt_test_drift(RtLink *l, int resample);
// tests only: this computer's audio clock estimate made wrong by ppm on purpose (rt-r1's laptop read its sinks' rate 1.5-2 % off: the
// read-rate servo must still match what arrives). rt-fix6b
void rt_test_clock_bias(RtLink *l, double ppm);
// tests only: the audio clock's estimate (ppm, as clock_ppm) after callbacks at these times (s) with this block size and rate; used: what
// the drift correction uses of it then (clock_used_ppm).
double rt_test_clock(const double *t, int n, int len, double srate, double *used = nullptr);
// What this computer sends. peer "" (or null): everything, on 0 = silence while the stream stays up (Mute me, push-to-talk; kept across
// restarts). A peer in the list: whether it gets this computer's stream (talkback). -> 1 done, 0 when that peer isn't in the list. (James, rt)
int rt_send(RtLink *l, const char *peer, int on);
// Play (docs/realtime-roadmap.md step 4, "Hear what a bandmate plays when they arm"): a second stream beside Talk, read from a StudioSync
// Hop's send ring (hop id 1-64, on the hidden "live out" track the armed tracks send to post-FX). hop_id 0: no Play stream. send 0: silence
// while the stream stays up (Mute me, Deafen). The mapping is opened on the send thread; rt_status's "play" says when it is. -> 1. (James, rt)
int rt_play(RtLink *l, int hop_id, int send);
// A peer's Play level in what you hear (linear, 0..4), apart from their Talk level (rt_peer_set; its mute is the whole bandmate's). -> 1 when in the list.
int rt_peer_play(RtLink *l, const char *peer, double gain);
// The hub's live mix (docs/realtime-roadmap.md "More big ideas" 1): peer, a bandmate in the list, is the computer that mixes for this one: this
// computer sends Talk and Play to it alone and hears the one stream it mixes (from this computer's own Talk/Play levels per bandmate, sent to
// it), switching back to everyone's own streams within about a jitter buffer when that mix stops coming. "" (or null): peer to peer. serve 1:
// this computer mixes for every listener that asks (its own Talk and Play in it), on the send thread. -> 1. (James, rt)
int rt_hub(RtLink *l, const char *peer, int serve);
std::string rt_status(RtLink *l); // JSON: the link, and per peer latency, jitter buffer, loss, level (see rtaudio.cpp)
// The ears tap (tools/ears; docs/rt/rt-p11.md): what this computer hears of peer's stream ("talk", "play", "hub": decoded, before any level),
// or with peer "" and "play" its own Play as it goes out, written to path (a .wav: 32-bit float stereo) for seconds (0..60) by a worker; the
// audio thread only copies into a ring. One at a time, while running. -> 1 started. rt_status's "ears" says how it goes.
int rt_ears(RtLink *l, const char *peer, const char *stream, const char *path, double seconds);
// The audio thread (REAPER's hook, or the test's clock): capture before REAPER's processing, mix after. No lock, allocation or REAPER call.
void rt_capture(RtLink *l, const double *const *in, int nin, int len, double srate);
// A browser guest heard here, added to the Talk sent (extension/webui.cpp webui_guest_talk; null: nothing). Called in rt_capture on the audio
// thread with this block's Talk channels, after the inputs were copied in and only while sending (Mute me silences the guest too). rt-browserjoin
extern void (*rt_talk_add)(float *const *ch, int nch, int len);
void rt_mix(RtLink *l, double *const *out, int nout, int len, double srate);
// Jam (extension/direct_audio.cpp, lib/jam.lua): each Play block as it goes out (after Mute me), on the audio thread, with the device's rate.
// null: nothing. rt-jam
extern void (*rt_play_tap)(float *const *ch, int nch, int len, int srate);

#ifndef RTAUDIO_STANDALONE
struct reaper_plugin_info_t;
void rtaudio_register(reaper_plugin_info_t *rec); // the ReaScript functions StudioSync_LiveAudio* and the audio hook (extension/rtaudio.cpp)
void rtaudio_shutdown();                          // the hook out and the threads stopped (REAPER unloading the extension)
#endif

// ---- Hop's network leg (extension/hopnet.cpp) shares this UDP socket (James, rt) ----
// A datagram from a Tailscale address that starts "SSH1" goes to fn (on the receive thread, outside every lock here), never to AOO; hopnet
// checks its own tag. fn nullptr: none (and this waits for a call in flight to end). rt_send_raw: one datagram out of the socket, to a
// Tailscale address (addr: a sockaddr_in); -1 while live audio is stopped. rt_global: REAPER's link (the one StudioSync_LiveAudio* runs).
typedef void (*rt_extra_fn)(void *user, const unsigned char *d, int n, const void *from, int fromlen);
void rt_set_extra(RtLink *l, rt_extra_fn fn, void *user);
int rt_send_raw(RtLink *l, const void *d, int n, const void *addr, int addrlen);
RtLink *rt_global();

// ---- the connection without Tailscale (extension/nat.cpp, docs/realtime-roadmap.md "Without Tailscale: design") ----
// A peer "nat:<device id>" in the peers JSON is reached through nat.cpp: its synthetic address (198.18.0.0/15, the same on every computer)
// stands for it wherever AOO and the hub's mix name it; datagrams to it go through `send`, and nat.cpp hands what it opens to rt_nat_rx.
// With no Tailscale address here and nat active, rt_start binds loopback and hears only those peers. (Function pointers, so the tests that
// build rtaudio.cpp alone need nothing from nat.cpp.)
struct RtNat {
  void *h;
  bool (*resolve)(void *h, const char *peer, void *sockaddr_in_out);
  bool (*up)(void *h, const void *sockaddr_in_p);
  int (*send)(void *h, const void *sockaddr_in_p, const void *d, int n);
  std::string (*self)(void *h); // this computer's synthetic "ip:port", as the others name it
  bool (*active)(void *h);
};
void rt_set_nat(RtLink *l, const RtNat *nat); // null: none
void rt_nat_rx(RtLink *l, const unsigned char *d, int n, const void *from_sockaddr_in);
