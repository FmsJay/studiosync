// StudioSync's built-in real-time audio (docs/realtime-roadmap.md step 4; replaces SonoBus): each computer sends its chosen hardware inputs
// as Opus through an AOO source (extension/third_party/aoo, BSD) to the studio's other computers over Tailscale UDP, and mixes every
// peer's stream, through an AOO sink with its jitter buffer, into REAPER's first output pair (the audio hook's post call: heard here,
// not recorded). Every datagram carries a tag made with the studio secret, so only studio computers are heard. Nothing runs until
// started. The core has no REAPER in it, so tests/rtaudio_test.cpp runs two or three of these on localhost. GPL-3.0-or-later.
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
// What this computer sends. peer "" (or null): everything, on 0 = silence while the stream stays up (Mute me, push-to-talk; kept across
// restarts). A peer in the list: whether it gets this computer's stream (talkback). -> 1 done, 0 when that peer isn't in the list. (James, rt)
int rt_send(RtLink *l, const char *peer, int on);
std::string rt_status(RtLink *l); // JSON: the link, and per peer latency, jitter buffer, loss, level (see rtaudio.cpp)
// The audio thread (REAPER's hook, or the test's clock): capture before REAPER's processing, mix after. No lock, allocation or REAPER call.
void rt_capture(RtLink *l, const double *const *in, int nin, int len, double srate);
void rt_mix(RtLink *l, double *const *out, int nout, int len, double srate);

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
