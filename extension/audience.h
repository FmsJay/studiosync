// Live to an audience (docs/rt/rt-audience.md): the band's live mix for listeners on a web page, with no REAPER and no login beyond a link.
// The session mix (this computer's REAPER output with every bandmate live audio hears, the hub's mix when it hears through one: the ring
// browser guests already get) is resampled to 48 kHz and Opus-encoded ONCE on a thread of its own, and each packet goes to every listener
// over a WebSocket: one encode however many listen, a send per listener. The page decodes it with WebCodecs.
// Two ways in, the same tiny allow-list (audience_route): the page, its script and style, the live socket, and the song's latest mix:
//  * tailnet: the web UI server hands over any /listen/ request (webui_listen_http), so the studio's secure phone link
//    (`tailscale serve`, https://<this computer>:8443/listen/?l=<code>) carries it;
//  * public (off unless the owner turns it on, lib/audience.lua): a listener of its own on 127.0.0.1:<port> that `tailscale funnel` points
//    at. It knows nothing else: no topic, action, file, token or page of the web UI is reachable through it, and only links made public open.
// Links: a code (32-64 lower-case hex) with an end time, revocable at once (its listeners are closed within 0.25 s); a cap on listeners;
// rate limits on requests and on wrong codes. GPL-3.0-or-later. Opus (BSD-3-Clause): extension/third_party/README.md.
#pragma once
#include <map>
#include <string>
#include "webui.h"

// ---- the pure parts (tests/audience_test.cpp) -------------------------------------------------------------------------------------------
enum { AUD_NONE = 0, AUD_PAGE, AUD_JS, AUD_CSS, AUD_LIVE, AUD_MIX };
// Which listener path this is; AUD_NONE for everything else (and for any method but GET).
int audience_route(const std::string &method, const std::string &path);
struct AudLink {
  std::string code;
  double until = 0;
  bool pub = false;
};
// May this request in? 0 yes (id: the link's), 403 a wrong, run-out or (on the public port) non-public link, 404 not a listener path.
// The script and style need no code (they carry nothing of the studio's); the page, the socket and the mix do.
int audience_auth(const WebReq &r, const std::map<std::string, AudLink> &links, double now, bool pub, std::string &id);
struct AudBucket {
  double tokens = -1, at = 0; // (tokens < 0: full on first use)
};
// A token bucket: rate a second, up to burst. -> true when one was taken.
bool audience_bucket_take(AudBucket &b, double now, double rate, double burst);
// n frames of interleaved stereo at 48 kHz from a ring of interleaved stereo (mask+1 frames, a power of two) read from frame `pos` in
// steps of `step` (the ring's rate / 48000), Catmull-Rom; pos moves on. The caller keeps pos+n*step+3 within what's written.
void audience_resample(const float *ring, unsigned long long mask, double &pos, double step, float *out, int n);
// A server-to-client WebSocket frame (unmasked, whole).
std::string audience_ws_frame(int op, const std::string &payload);

// ---- running ------------------------------------------------------------------------------------------------------------------------
// folder: the pages (lib/webui, for listen.html/.js/.css); cap: listeners at most (1-100); kbps: Opus's rate (32-256); pub_port: the public
// listener on 127.0.0.1 (0: none, and its listeners are closed). Starts the encoder thread. -> 1, 0 when the public port couldn't be opened
// (the rest still runs).
int audience_start(const char *folder, int cap, int kbps, int pub_port);
// id: 16 lower-case hex; code: 32-64 lower-case hex; seconds: how long it opens (1 .. 7 days); pub: may open on the public port.
// code "": the link is revoked and its listeners closed. -> 1, 0 for a bad id/code or more than 8 links.
int audience_link(const char *id, const char *code, int seconds, int pub);
// What listeners see: full (tailnet listeners: song, live, who's playing...) and pub (the public ones: song and live only), each a JSON
// object under 2 KB that the server passes on as it is; mix: the song's latest bounced mix ("" none), served as /listen/mix.
int audience_info(const char *full, const char *pub, const char *mix);
const char *audience_status(); // JSON: running, cap, kbps, listeners, public, public_port, public_error, links {id: n}, packets, ...
void audience_feed(const double *L, const double *R, int len, double srate); // the audio thread: the session mix, nothing unless one listens
bool audience_http(unsigned long long sock, const WebReq &r, bool pub);   // a listener request; true: the socket is kept (don't close it)
int audience_count();
void audience_shutdown();
#ifndef AUDIENCE_STANDALONE
struct reaper_plugin_info_t;
void audience_register(reaper_plugin_info_t *rec); // reaper.StudioSync_Audience*
#endif
