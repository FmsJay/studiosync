// StudioSync Hop's network leg (docs/realtime-roadmap.md 4b, "live hops"): a hop's audio to the bandmate who has the plug-in and back,
// sample-exact, as raw float PCM over live audio's UDP socket (extension/rtaudio.cpp hands it every datagram that starts "SSH1").
// The core has no REAPER in it, so tests/hopnet_test.cpp runs a sender and a fake remote on localhost. GPL-3.0-or-later.
#pragma once
#include <string>

struct HopNet;
// How a datagram goes out (REAPER: rt_send_raw on live audio's socket; the test: its own socket). addr is a sockaddr_in. -> bytes or < 0.
typedef int (*hopnet_send_fn)(void *user, const void *data, int n, const void *addr, int addrlen);
// pid: whose hops (the shared memory's name, plugin/hop_shm.h): REAPER's own.
HopNet *hopnet_new(hopnet_send_fn send, void *user, unsigned long pid);
void hopnet_free(HopNet *h);
// One datagram that came in (from: a sockaddr_in). void* first, so it fits rtaudio's hook (rt_set_extra) as it is.
void hopnet_rx(void *h, const unsigned char *d, int n, const void *from, int fromlen);
// The sending end: hop hop_id's audio goes to peer ("name:port"). json: {"secret":"<studio secret>","token":<the hop's number, 1..2^32-1>}
// (the token is the hop's name on the wire, shared with the remote over the direct link). json {"stop":true}: this hop stops.
// -> 1, or 0 (bad arguments, or the hop's shared memory couldn't be opened).
int hopnet_connect(HopNet *h, int hop_id, const char *peer, const char *json);
// The remote end: {"secret":..,"token":..,"x":<the hidden track's first Hop's id>,"y":<its last Hop's id>,"pdc":<the plug-ins' latency
// between them, samples>,"margin_ms":<the jitter buffer, default 20>}; {"token":..,"stop":true} stops it. -> 1, or 0.
int hopnet_serve(HopNet *h, const char *json);
// The network side of hop hop_id (a sending hop, or a served one by its x id) as a JSON object, or "" when it has none.
std::string hopnet_status(HopNet *h, int hop_id);
