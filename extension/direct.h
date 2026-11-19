// StudioSync's direct link (docs/direct-link-design.md): event files straight to the studio's other computers over Tailscale, ahead of
// Syncthing's copy; and (1.0.8, docs/realtime-roadmap.md steps 1, 2 and the step-4 spike) small messages, a shared clock, a growing file
// streamed as it's written, and an audio-input capture spike. The core has no REAPER in it, so tests/direct_test.cpp builds it alone
// (-DDIRECT_STANDALONE). GPL-3.0-or-later.
#pragma once
#include <cstddef>
#include <string>

#define DIRECT_PORT 47281
#define DIRECT_MAX_DATA (4 * 1024 * 1024) // (event files are a few hundred bytes to a few hundred KB: anything bigger is refused)
#define DIRECT_MAX_MSG (64 * 1024)        // a small message (chat, a cue, presence, live MIDI notes): no more than this

// bind_ip: "" finds this computer's Tailscale address; the test passes "127.0.0.1". port 0: DIRECT_PORT; < 0: send only.
int direct_start(const char *studio, const char *secret, const char *inbox, int port, const char *bind_ip);
void direct_stop(const char *studio); // "" stops everything
int direct_send(const char *studio, const char *rel, const char *path, const char *peers);
const char *direct_poll(int after); // (callers on one thread: REAPER's main thread, or the test's)
const char *direct_status();
void direct_shutdown();
bool direct_path_ok(const char *rel);

// ---- 1.0.8: the live layer --------------------------------------------------------------------------------------------------------------
// Small messages: kind a short lower-case word ([a-z][a-z0-9_-]{0,31}: presence, heartbeat, claim, chat, cue, transport, midi, json...),
// data any text up to DIRECT_MAX_MSG. -> 1 queued.
int direct_msg(const char *studio, const char *kind, const char *data, const char *peers);
const char *direct_msg_poll(int after); // "<seq>\t<studio>\t<kind>\t<data>" (the first after `after`), or ""
// The computers to keep a clock with (pinged every second or two on the kept connection). -> how many.
int direct_peers(const char *studio, const char *peers);
const char *direct_clock(); // JSON: { now, peers = { ["host:port"] = { offset_ms, rtt_ms, spread_ms, samples, at } } }
double direct_now();        // this computer's clock, seconds since 1970: wall time at start, then a monotonic high-resolution clock
double direct_file_time(const char *path); // a file's newest of made / last written, seconds since 1970 (through a handle: current while it's being written); -1 if it can't be read
// A growing file (a take being recorded) streamed to `peers` every interval_ms; direct_stream_end: it's complete, send the rest and
// "done" with its length and SHA-256. Received into <inbox>/.streams/<rel>, rel = "<song>/<name>.<wav|w64|flac|aif|aiff|ogg|opus|mp3|mid>".
int direct_stream(const char *studio, const char *rel, const char *path, const char *peers, int interval_ms);
int direct_stream_end(const char *studio, const char *rel);
const char *direct_streams(); // JSON: { out = [ { studio, rel, size, ended, peers = { [peer] = { sent, done, error } } } ], in = [ ... ] }
bool direct_stream_rel_ok(const char *rel);

// ---- the audio spike (extension/direct_audio.cpp: does nothing until started) ----------------------------------------------------------
int direct_audio_start(int first_input, int nch); // capture hardware inputs first..first+nch-1 (nch 1..8) into a lock-free ring
void direct_audio_stop();
const char *direct_audio_status(); // JSON: { running, srate, inputs, first, nch, callbacks, frames, overruns, max_us, peaks = [...], dump }
int direct_audio_dump(const char *path, double seconds); // a worker thread writes the next `seconds` to a 32-bit float WAV
// The audio thread's work, without REAPER: `in` has `nin` hardware input channels of `len` samples (entries may be null).
void direct_audio_process(const double *const *in, int nin, int len, double srate);

// For the test: the pieces a frame is made of, and the WAV layout the receiver keeps playable.
void direct_sha256(const unsigned char *msg, size_t len, unsigned char out[32]);
void direct_hmac_sha256(const unsigned char *key, size_t klen, const unsigned char *msg, size_t mlen, unsigned char out[32]);
std::string direct_derive_key(const std::string &secret);
std::string direct_frame(const std::string &key, const std::string &studio, const std::string &rel, const std::string &data, const char *magic = "SSD1");
// head: a WAV's first bytes. -> true once its "data" chunk header is in them: data_off (where the samples start), block_align, rf64 (an
// RF64 file: sizes in its ds64 chunk at ds64_off), else plain RIFF.
bool direct_wav_layout(const std::string &head, long long &data_off, int &block_align, bool &rf64, long long &ds64_off);
#ifdef DIRECT_STANDALONE
void direct_test_knobs(long long skew_us, int delay_max_ms, int ping_ms); // the listener's clock skewed, its answers delayed 0..max ms
void direct_test_bandwidth(int kbps); // the listener reads at most this fast (0: as fast as it comes)
#endif

#ifndef DIRECT_STANDALONE
struct reaper_plugin_info_t;
void direct_register(reaper_plugin_info_t *rec);       // the ReaScript functions StudioSync_Direct*
void direct_audio_register(reaper_plugin_info_t *rec); // the audio spike's StudioSync_DirectAudio* (extension/direct_audio.cpp)
#endif
