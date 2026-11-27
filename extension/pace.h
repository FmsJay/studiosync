// The read-rate control of StudioSync's live audio, written once (rt-audio4, docs/rt/rt-audio4.md section 5; rt-audio3's recommendation 4):
// what a stream is read at, from its own buffer. extension/rtaudio.cpp holds one per bandmate and stream (Talk, Play, the hub's mix) and
// calls it from adapt; moved here from there unchanged (the simulated suite gives the same numbers to the digit before and after). The web
// pages' guest rings use a lighter law today (extension/webui.cpp gpace, lib/webui/*.js ssPace): see the design doc. GPL-3.0-or-later.
#pragma once
#include <algorithm>
#include <cmath>

namespace pace {
// The read-rate control (rt-audio3; it was rt-fix6b's slope servo on top of AOO's ratio of two clock estimates). What a stream must be
// read at is (the sender's real sample rate) / (this device's real one), and the only thing that measures both is the stream's own buffer:
// what arrives against what is played. So each stream is read at 1 + R + P, and AOO is told nothing else (clock_step hands out nominal times):
//  - R, the bandmate's learned ratio less 1 (one device there against one here; each of its streams learns its own since round 3:
//    the comment at RATE_SETTLE_S). It integrates the level error, so it settles where the level holds;
//  - P, proportional to the level error: the level's median over RATE_WIN s (a median: the tail of a burst, a VM's ten blocks at once and
//    one late read don't move it) less the level the stream settled at when it started, wherever that was. It holds the level while R
//    learns, and brings it back after a small step.
// It doesn't steer the level to the buffer's size (rt-r5: it did, to within 5 ms under and 12 over; a stream that had finished buffering
// above that, or that a burst had left high, was then read up to 0.5 % fast until it was down: 0.23 % sharp through a 9 s pattern on a
// calm link, and on a jittery one, where the buffer needs what the bursts leave, it drained every refill into the next hold and R, seeing
// a level that never came back, learned the wrong sign: +12156 ppm for a device 4000 ppm slow). What sits unused above the size is the
// shed's to take (TRIM_OVER), what is missing below it is an underrun's to grow.
// And a level that moves more than RATE_JUMP between two windows isn't a rate (a device 6 % off): it's the network's delay moving, a
// stall, a burst. The held level moves with it, R learns nothing from it, and the loop is slow for RATE_CALM_S after (P within RATE_P, R
// at the slow gain): on a link like that the buffer's size is what copes (adapt), not the pitch.
// The level is a time, not a count: what the buffer held at the last read plus how old its newest packet was then (rt_mix's `age`). The
// count alone moves in the sender's blocks: with 256-sample blocks at both ends and 200 ppm between them it sat still for 26 s while the
// delay heard grew 5 ms, then jumped a block; the control saw nothing, then a step (drift_tests: the delay moved as if uncorrected). With
// the packet's age the level moves as the delay does, and stays put while the link holds packets and lets them go together (the buffer
// drains as the age grows). A newest packet older than RATE_AGE at a read is left out (nothing is coming just now; it restarted the
// windows and the held level, so on a link that holds packets that long the control never got to act).
// Two speeds, faded between. Slow (RATE_KP: critically damped, 20 s) while the level stays within RATE_FAST_MS of where it's held (one
// tick of a 10 ms device doesn't pass it; it was 6 ms, and the desktop's stream ran the fast loop in every look, rt-r5): a steady
// device's ratio moves by ppm, and a quiet loop adds no wobble of its own. Fast (RATE_KP_F: 4 s) after a window further off than that and
// for a bandmate's first seconds, RATE_FAST_S in all, the last RATE_FADE_S of them fading back to slow (a step between the two gains was
// a step in the rate). The desktop's device loses 2 to 12 of its 10 ms ticks in 10 s, and a 1.2 % step then costs ~20 ms of buffer before
// it is followed (the slow loop would take ~100). What each part may do is bounded: P by RATE_P and RATE_P_F (so a buffer left far over
// its size by a stall is still shed, TRIM_OVER, not played off-pitch for seconds), the error R learns from by RATE_I_MS a window, the sum
// by RATE_CAP. And R learns only while P isn't getting its way: a level left off by a stall or a burst comes back at P's own pace, and R,
// integrating all the way, read up to 0.9 % fast and then overshot; a real rate error holds the level off against P, or moves it further.
// So a window counts for R only when the level, against RATE_BACK windows ago, came back less than half of what P alone would have done.
// Tried before and dropped (rt-fix6b): the slope alone (no level term) left a residual under its 0.1 % floor that walked the buffer into
// an underrun or a shed every couple of minutes (the laptop's idle resyncs), and three 1 s slopes in a row couldn't follow a device whose
// rate moves every few seconds. It reaches AOO as the time rt_mix gives that sink: AOO's sink takes its own rate from those times
// (kAooPreciseTimestamp), so a sink timed 1 % fast reads 1 % faster.
const double RATE_WIN = 0.5, RATE_CAP = 0.02;
const int RATE_W = 96, RATE_NEED = 8;                 // a window's samples kept (a reservoir), and the fewest that make a window
const double RATE_KP = 0.1, RATE_KP_F = 0.5;          // per s, slow and fast; the integral's gain is kp * kp / 4 (critically damped)
const double RATE_P = 0.002, RATE_P_F = 0.005;        // the most P may add or take: 0.2 % slow, 0.5 % fast (9 cents)
const double RATE_FAST_MS = 10, RATE_FAST_S = 10, RATE_FADE_S = 5, RATE_I_MS = 20;
// The fast loop needs the level this share of the buffer's size off where it's held, where that is more than RATE_FAST_MS (round 3, from
// rt-r6). The desktop's device drops a 10 ms tick about once in 200, at random: nothing to follow in that but its average, and one tick
// or two took the level past RATE_FAST_MS, so the laptop, its buffer for the desktop at 110-170 ms, ran the fast loop in 8 looks of 10
// and read it anywhere from -0.47 to -1.31 %, P at its limit in 3 of 10: a tone 0.5 % off for seconds. A buffer that size has room for
// those ticks; a small one hasn't, and there the fast loop still runs (device_test: 30 ms).
const double RATE_FAST_PART = 0.5;
const double RATE_JUMP = 30, RATE_CALM_S = 10;        // ms between two windows that no rate explains; s the loop stays slow after one
const double RATE_AGE = 0.25;                         // s: the newest packet older than this at a read: nothing is coming, that read is left out
const int RATE_BACK = 4;                              // windows back the level is compared with (2 s: P's 10 ms then, against a window's 2 ms of noise)
// Each of a bandmate's streams learns its own R (round 3, from rt-r6; it was one R for the three, and the cap 3 %). The laptop, muted, sent
// its silence all evening. Its Talk's buffer here was re-buffered several times a minute (the quiet shrink a step every BUF_STEP, a grow
// at each hold), and R, kept across each and learning again from wherever the buffer landed, walked to the cap: +15525 ppm three minutes
// in, +29673 at the hour, +1000 a minute on LinuxBox. Its Play then started at that R: read 2.8 % fast, 15 re-buffers in 2.5 minutes. So:
//  - for RATE_SETTLE_S after a stream re-buffers (its start, an underrun, an overrun, a new size, a shed) the held level follows the
//    stream, P is 0 there and nothing is learned: where a buffer lands and what arrives late on top of it isn't a rate. But a level
//    that falls RATE_DIP in a window is acted on at once: nothing but reading too fast drains a buffer that has just filled, and the
//    next thing is a gap;
//  - R goes past RATE_SANE only on a stream that has run RATE_TRUST_S without re-buffering and without a jump (real devices are within
//    0.1 % of each other, the desktop's bad one 0.2 to 1.1 %); one that hasn't may come back toward 0 from wherever it is, no further out;
//  - an underrun says which way a large R is wrong: one read faster than RATE_SANE that ran dry goes back to RATE_SANE at once, and one
//    that ran dry in the fast loop with P already at its slow limit goes RATE_WIDE slower at once (the rate test: this computer's times
//    1.5 % off, where it ran dry every few seconds and so never ran RATE_TRUST_S). Not after a jump (the jitter test: the link's holds
//    ran it dry, and R went 0.4 % past the device). Only the slow side opens so: too slow fills the buffer, which is shed in a
//    crossfade; too fast empties it, a gap, and that is the way rt-r6's ran;
//  - no stream takes another's R: a muted Talk's is never its Play's, whatever it learned. A Play that starts learns in the fast loop.
const double RATE_SETTLE_S = 1.2, RATE_DIP = 5, RATE_SANE = 0.006, RATE_TRUST_S = 15, RATE_WIDE = 0.005;

// One stream's read-rate control: its state and the steps extension/rtaudio.cpp's adapt takes for it, in this order on each look (the send
// thread's, about every 5 ms): events (AOO's underruns and re-buffers since the last look), look (its buffer as measured; the reservoir's
// generator is the bandmate's, shared by its streams in order), then, after any shed (settle), rate (the fade's hand-over and what it is read
// at now). rint: R; wsince: since when it has run without re-buffering or jumping (-1: not playing); the rest as the comment above says.
struct Pace {
  double rint = 0, wsince = -1, settle_until = 0, wbuf[RATE_W] = {}, wt0 = 0, werr = 0, whist[RATE_BACK] = {}, whp[RATE_BACK] = {};
  double wset = -1, fast_until = 0, kp_was = RATE_KP, rough_until = 0;
  int wn = 0, wh = 0;
  bool learning = true, dry_p = false;
  long long rebuf_seen = 0, under_seen = 0;
  // The control's last minute (rt-audio4, rt-audio3's recommendation 19): each window (the level, where it's held, the error in ms, R and
  // P in ppm) and each event, newest last, for rtaudio.cpp's rt_trace (StudioSync_LiveAudioTrace). Finding D took five lab models from
  // status reads a minute apart; one dump during the walk says which term moved R. Written here only, read under the caller's lock.
  struct Note { double t; float level, held, err, r, p; unsigned char ev; };
  enum { NOTE_WINDOW = 1, NOTE_JUMP = 2, NOTE_REBUF = 4, NOTE_UNDER = 8, NOTE_FAST = 16, NOTE_ROUGH = 32, NOTE_SETTLING = 64 };
  static const int NOTES = 160; // (a minute of windows, two a second, and the events among them)
  Note notes[NOTES] = {};
  unsigned nn = 0;
  void note(double now, double level, double e, unsigned char ev)
  {
    Note &x = notes[nn++ % NOTES];
    x.t = now; x.level = (float)level; x.held = (float)wset; x.err = (float)(e * 1000); x.r = (float)(rint * 1e6); x.p = (float)(part(now) * 1e6); x.ev = ev;
  }
  // the gains now: g 1 in the fast loop, 0 in the slow one, fading between; P's share, inside its bound
  void gains(double now, double &kp, double &pmax) const
  {
    const double g = now < rough_until ? 0.0 : std::max(0.0, std::min(1.0, (fast_until - now) / RATE_FADE_S));
    kp = RATE_KP + g * (RATE_KP_F - RATE_KP);
    pmax = RATE_P + g * (RATE_P_F - RATE_P);
  }
  double part(double now) const { double kp, pmax; gains(now, kp, pmax); return std::max(-pmax, std::min(pmax, kp * werr)); }
  bool trusted(double now) const { return wsince >= 0 && now - wsince >= RATE_TRUST_S; }
  void learn(double now, double d) // (R moves by d, inside what it may: the comment at RATE_SETTLE_S)
  {
    const double lo = trusted(now) ? -RATE_CAP : std::max(-RATE_CAP, std::min(-RATE_SANE, rint)), hi = trusted(now) ? RATE_CAP : std::min(RATE_CAP, std::max(RATE_SANE, rint));
    rint = std::max(lo, std::min(hi, rint + d));
  }
  void settle(double now) { wn = 0; wh = 0; werr = 0; wset = -1; settle_until = now + RATE_SETTLE_S; } // (its windows and held level start again, R kept)
  void resettle(double now) { settle(now); if (wsince >= 0) wsince = now; } // (a re-buffer: and its trust starts again)
  // AOO's counts for this stream: under, its underruns; rebuf, its underruns and overruns (each a re-buffer). An underrun also says
  // something of a large R (was P at its slow limit, in the fast loop, when it last played? Not after a jump).
  void events(double now, long long under, long long rebuf)
  {
    double kp, pmax;
    gains(now, kp, pmax);
    if (wsince >= 0) dry_p = now >= rough_until && now < fast_until && kp * werr <= -pmax;
    if (under != under_seen) {
      under_seen = under;
      if (rint > RATE_SANE) rint = RATE_SANE;
      else if (dry_p) rint = std::max(-RATE_CAP, rint - RATE_WIDE);
      note(now, -1, werr, NOTE_UNDER);
    }
    if (rebuf != rebuf_seen) { rebuf_seen = rebuf; resettle(now); note(now, -1, 0, NOTE_REBUF); }
  }
  // A look: f, its buffer as measured (ms; < 0: not playing now); age, how old its newest packet was at the last read (s); target, the
  // buffer's size (ms); rng, the reservoir's generator.
  void look(double now, double f, double age, double target, unsigned &rng)
  {
    if (f < 0) { settle(now); wsince = -1; return; }
    if (wsince < 0) { wsince = now; settle_until = now + RATE_SETTLE_S; } // (it starts, or is back from a re-buffer: its own R, and it settles)
    if (age > RATE_AGE) return; // (the link is holding its packets: no level at this read, and nothing forgotten)
    const double lv = f + std::max(0.0, age) * 1000; // (the level, a time)
    const int n = wn++;
    if (n == 0) wt0 = now;
    if (n < RATE_W) wbuf[n] = lv;
    else { // (a reservoir: every sample of the window as likely kept)
      rng = rng * 1103515245u + 12345u;
      const unsigned j = (rng >> 8) % (unsigned)(n + 1);
      if (j < (unsigned)RATE_W) wbuf[j] = lv;
    }
    if (now - wt0 < RATE_WIN || wn < RATE_NEED) return;
    const int m = std::min(wn, RATE_W);
    std::nth_element(wbuf, wbuf + m / 2, wbuf + m);
    // (the level it's held at: where the stream settled after it last re-buffered. While it settles the held level follows it, but for a
    // fall of RATE_DIP, and a window it follows starts the count again)
    const double med = wbuf[m / 2];
    const bool first = wset < 0 || (now < settle_until && med >= wset - RATE_DIP);
    if (first) { wset = med; wh = 0; werr = 0; }
    double e = (med - wset) / 1000.0;
    const double dt = std::min(now - wt0, 2 * RATE_WIN); // (a window stretched by a stall counts as two at most)
    const bool jumped = !first && std::fabs(e - werr) * 1000 > RATE_JUMP;
    if (jumped) { // (not a rate: the held level goes with it, and the loop is slow for a while)
      wset += (e - werr) * 1000;
      e = werr;
      wh = 0;
      rough_until = now + RATE_CALM_S;
      kp_was = RATE_KP; // (no hand-over as the gain drops: what P held then was the jump's)
      wsince = now;     // (and its R stays within RATE_SANE until it has run RATE_TRUST_S without another)
    }
    const double moved = std::fabs(part(now)) * dt; // (how far P, as it was through this window, moved the level toward where it's held)
    if (learning || (std::fabs(e) * 1000 > std::max(RATE_FAST_MS, RATE_FAST_PART * target) && now >= rough_until)) { learning = false; fast_until = now + RATE_FAST_S; }
    // (R learns only while P isn't getting its way: the level against RATE_BACK windows ago came back less than half of what P alone did
    // since. Not from a stream's first two windows: one window back P has had half a window to act)
    double did = moved;
    for (int i = 1; i < wh; ++i) did += whp[i];
    if (wh >= 2 && std::fabs(e) > std::fabs(whist[0]) - 0.5 * did) {
      double kp, pmax;
      gains(now, kp, pmax);
      learn(now, kp * kp / 4 * std::max(-RATE_I_MS / 1000, std::min(RATE_I_MS / 1000, e)) * dt);
    }
    if (wh == RATE_BACK) { std::copy(whist + 1, whist + RATE_BACK, whist); std::copy(whp + 1, whp + RATE_BACK, whp); --wh; }
    whist[wh] = e;
    whp[wh++] = moved;
    werr = e;
    wn = 0;
    note(now, med, e, (unsigned char)(NOTE_WINDOW | (jumped ? NOTE_JUMP : 0) | (fast(now) ? NOTE_FAST : 0) | (rough(now) ? NOTE_ROUGH : 0) | (now < settle_until ? NOTE_SETTLING : 0)));
  }
  // What it's read at now (1 + R + P). playing: it was measured this look. The fast loop fading to the slow one: what P gives up as its gain
  // falls goes into R, so the rate doesn't move and the level stays where it settled.
  double rate(double now, bool playing)
  {
    double kp, pmax;
    gains(now, kp, pmax);
    if (playing && kp < kp_was && std::fabs(kp_was * werr) < pmax) learn(now, (kp_was - kp) * werr);
    kp_was = kp;
    return 1 + std::max(-RATE_CAP, std::min(RATE_CAP, rint + part(now)));
  }
  bool fast(double now) const { return now < fast_until && now >= rough_until; }
  bool rough(double now) const { return now < rough_until; }
};

// The light law (rt-audio3's gpace and ssPace): the browser guests' rings, extension/webui.cpp here and lib/webui/guestworklet.js,
// sharemix.js and listen.js in the pages (their JS copy, the same text in all three). Once a LITE_WIN, P = LITE_KP x (the window's mean
// level - the size), within LITE_P, brings the level back; R, the other clock against this one as learned (within LITE_R), integrates the
// error only while P isn't getting its way (the level, against LITE_BACK windows ago, came back less than half of what P alone did since);
// the level is a time (what waits plus how long ago the newest piece came: age, at most LITE_AGE), and a window whose level jumped more than
// LITE_JUMP isn't a rate. tests/fixtures/pace_lite.json pins this and the JS copy to the same numbers (tests/rtaudio_test.cpp pace_lite_test,
// tests/pace_lite_check.py). The full law above needs AOO's events, which the guests' rings don't have yet: docs/rt/rt-audio4.md section 5.
const double LITE_WIN = 0.5, LITE_KP = 0.2, LITE_P = 0.001, LITE_R = 0.01, LITE_I = 0.05, LITE_JUMP = 0.03, LITE_AGE = 1;
const int LITE_BACK = 4;
struct Lite { // (the audio thread's)
  double sum = 0, t = 0, r = 0, p = 0, rate = 1, he[LITE_BACK] = {}, hp[LITE_BACK] = {};
  int n = 0;
  void again() { sum = t = p = 0; n = 0; rate = 1 + r; } // (a start or a cut: the level anew, R kept)
  double step(double fill, double target, double dt, double age)
  {
    fill += std::max(0.0, std::min(LITE_AGE, age)); // (the level as a time: what waits plus how long ago the newest piece came)
    sum += fill * dt; t += dt;
    if (t < LITE_WIN) return rate;
    const double e = sum / t - target, T = t, was = std::fabs(p) * T;
    sum = t = 0;
    if (n > 0 && std::fabs(e - he[n - 1]) > LITE_JUMP) n = 0; // (a jump between two windows isn't a rate: R learns nothing from it)
    double did = was;
    for (int i = 1; i < n; ++i) did += hp[i];
    if (n >= 2 && std::fabs(e) > std::fabs(he[0]) - 0.5 * did) r = std::max(-LITE_R, std::min(LITE_R, r + LITE_KP * LITE_KP / 4 * std::max(-LITE_I, std::min(LITE_I, e)) * T));
    if (n == LITE_BACK) { std::copy(he + 1, he + LITE_BACK, he); std::copy(hp + 1, hp + LITE_BACK, hp); --n; }
    he[n] = e; hp[n++] = was;
    p = std::max(-LITE_P, std::min(LITE_P, LITE_KP * e));
    return rate = 1 + r + p;
  }
};
} // namespace pace
