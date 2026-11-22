"""StudioSync "ears": listen at both ends and compare (docs/rt/rt-ears.md). GPL-3.0-or-later.

A known signal goes in at one computer, each other computer captures what it receives, and this compares them.

  python tools/ears/ears.py pattern OUT_DIR             the test pattern: pattern.wav (48 kHz mono float), pattern.f32 (raw, for the
                                                        REAPER player), pattern.json (sections and timing events)
  python tools/ears/ears.py env PATTERN_DIR SEND RECV --peer NAME [--hub] [--gain G] [--offset-ms MS]
                                                        live audio from extension status polls (tools/ears/ears.lua "poll" files)
  python tools/ears/ears.py wav REF.wav GOT.wav [--pattern PATTERN_DIR] [--exact] [--stamps]
                                                        two recordings of the same signal (Jam's copies, a capture tap). Live audio's
                                                        ears tap (ears.lua "tap") leaves REF.wav.json / GOT.wav.json beside each: with
                                                        --stamps, the latency on the link clock and whether it held steady (rt-p11)
  python tools/ears/ears.py tail GOT.wav --on S --off S [--release-ms MS] [--bound-ms MS]
                                                        the Hop: a note's tail must end within the bound after its note-off

Each prints one JSON object with the numbers and a "pass" verdict per check, and exits 1 when a check fails. Needs numpy and scipy.
"""
import json
import math
import os
import sys

import numpy as np
from scipy import signal
from scipy.io import wavfile

SR = 48000
PEAK = 0.5        # the pattern's peak (-6 dBFS): receivers at live audio volume 0.01 hear it at -46 dBFS, under the -40 dB limit
BED_DB = -60.0    # a quiet noise bed throughout, so live audio's "back after a gap" fade-in (a stream under -80 dBFS) never touches an event

# ---- thresholds (why: docs/rt/rt-ears.md "Pass thresholds") ----
MAX_DELAY = 1.5         # s: the longest delay looked for (live audio's buffers top out at 150 ms + the link; Wi-Fi spikes)
LEVEL_DB = 2.0          # level against what was sent (after the expected gain): Opus and block peaks move a peak by about 1 dB
GAP_DB = 20.0           # a loud stretch heard 20 dB under what was sent is a dropout, not a codec's error
LAT_IQR_MS = 20.0       # the events' latency spread (interquartile): REAPER's blocks come in bursts (desktop WASAPI: 2-27 ms apart), so one
                        # event's reading moves by a block or two either way; past this the delay itself moved during the pattern
LAT_JUMP_MS = 40.0      # from one event to the next (250-500 ms apart): more is the jitter buffer resyncing (sound dropped or repeated)
ENV_CORR = 0.7          # the band excerpt's dB envelope (50 ms bins of block peaks) against what was sent: LinuxBox's 64 ms bursts smear it
STEP_DB = 1.5           # each 6 dB step of the tone ladder measured within this
SPEC_DB = 3.0           # mean third-octave band difference, 50 Hz-16 kHz, where the band is within 40 dB of the loudest (lossy codec)
SPEC_DB_EXACT = 0.1     # the same for a lossless path (Jam: 16-bit PCM)
JAM_PLACE_MS = 10.0     # Jam: a part lands within 10 ms of where it belongs (rt-jam's REAPER step 3)


def db(x, floor=-120.0):
    x = np.asarray(x, dtype=float)
    return np.maximum(20 * np.log10(np.maximum(np.abs(x), 1e-12)), floor)


# ---------------------------------------------------------------------------------------------------------------------------------------
# The test pattern: clicks for timing, a tone ladder for level, a chirp, and two bars of a small band (kick, snare, hats, bass, keys, and a
# voice-like formant synth) for something like a real project. All synthesised here (deterministic, no samples, no licence questions).
# ---------------------------------------------------------------------------------------------------------------------------------------
def _env(n, a, d):
    """Attack-decay envelope: a samples up, exponential decay with time constant d samples."""
    t = np.arange(n, dtype=float)
    e = np.exp(-np.maximum(t - a, 0) / max(d, 1))
    if a > 0:
        e[:a] = t[:a] / a
    return e


def _resonator(x, f, bw):
    r = math.exp(-math.pi * bw / SR)
    th = 2 * math.pi * f / SR
    return signal.lfilter([1 - r], [1, -2 * r * math.cos(th), r * r], x)


def _band(rng, n, bpm=120.0):
    beat = int(round(60.0 / bpm * SR))
    out = np.zeros(n)
    add = lambda at, x: out.__setitem__(slice(at, at + len(x)), out[at:at + len(x)] + x[:max(0, n - at)])
    kicks = []
    for b in range(0, n // beat):
        at = b * beat
        if b % 2 == 0:  # kick: a pitch-dropping sine
            m = int(0.25 * SR)
            t = np.arange(m) / SR
            f = 50 + 90 * np.exp(-t / 0.03)
            add(at, 0.9 * np.sin(2 * np.pi * np.cumsum(f) / SR) * _env(m, 48, 0.08 * SR))
            kicks.append(at)
        else:  # snare: tone plus band-passed noise
            m = int(0.2 * SR)
            t = np.arange(m) / SR
            nz = signal.lfilter(*signal.butter(2, [1000, 6000], btype="band", fs=SR), rng.standard_normal(m))
            add(at, (0.35 * np.sin(2 * np.pi * 190 * t) + 0.5 * nz) * _env(m, 24, 0.05 * SR))
        for h in (0, beat // 2):  # closed hats on the eighths
            m = int(0.05 * SR)
            nz = signal.lfilter(*signal.butter(2, 7000, btype="high", fs=SR), rng.standard_normal(m))
            add(at + h, 0.25 * nz * _env(m, 12, 0.012 * SR))
    # bass: a saw through a one-pole low pass, one note a beat
    notes = [36, 36, 43, 41, 33, 33, 40, 38]
    for b, nn in enumerate(notes * (n // (beat * len(notes)) + 1)):
        at = b * beat
        if at >= n:
            break
        m = int(beat * 0.9)
        f = 440 * 2 ** ((nn - 69) / 12)
        ph = (np.arange(m) * f / SR) % 1.0
        saw = signal.lfilter([0.08], [1, -0.92], 2 * ph - 1)
        add(at, 0.9 * saw * _env(m, 96, 0.4 * SR))
    # keys: Cmaj7 then Am7 a bar each, additive with a soft decay
    bar = 4 * beat
    for c, chord in enumerate([[60, 64, 67, 71], [57, 60, 64, 67]] * (n // (2 * bar) + 1)):
        at = c * bar
        if at >= n:
            break
        m = min(bar, n - at)
        t = np.arange(m) / SR
        x = sum(sum(np.sin(2 * np.pi * k * 440 * 2 ** ((nn - 69) / 12) * t) / k ** 2 for k in (1, 2, 3)) for nn in chord)
        add(at, 0.07 * x * _env(m, 240, 1.2 * SR))
    # voice: a glottal-ish pulse train with vibrato through three formants, the vowel moving from "a" to "i"
    t = np.arange(n) / SR
    f0 = 220 * 2 ** ((np.where(t < n / SR / 2, 0, 3)) / 12) * (1 + 0.012 * np.sin(2 * np.pi * 5.5 * t))
    ph = np.cumsum(f0) / SR % 1.0
    src = np.where(ph < 0.4, np.sin(np.pi * ph / 0.4) ** 2, 0.0)
    src = np.diff(src, prepend=0.0) * 20
    mix = np.clip(t / (n / SR), 0, 1)
    v = np.zeros(n)
    for (fa, fi, bw, g) in ((730, 270, 90, 1.0), (1090, 2290, 110, 0.6), (2440, 3010, 160, 0.3)):
        v += g * ((1 - mix) * _resonator(src, fa, bw) + mix * _resonator(src, fi, bw))
    v *= 0.5 * _env(n, int(0.05 * SR), 10 * SR) * np.minimum(1, (n - np.arange(n)) / (0.05 * SR))
    out += 0.6 * v / max(1e-9, np.max(np.abs(v)))
    return out, kicks


def make_pattern():
    """-> (mono float32 samples at SR, meta dict). Sections and events are in seconds from the pattern's first sample."""
    rng = np.random.default_rng(20261121)
    total = 9.75
    n = int(total * SR)
    x = np.zeros(n)
    events, sections = [], {}

    def at(s):
        return int(round(s * SR))
    # clicks: eight 1 ms raised-cosine pulses, 250 ms apart
    pulse = np.hanning(int(0.001 * SR) + 2)[1:-1]
    for k in range(8):
        s = 0.5 + 0.25 * k
        x[at(s):at(s) + len(pulse)] += PEAK * pulse
        events.append(s)
    sections["clicks"] = [0.5, 2.5]
    # tone ladder: 440 Hz at -6, -12, -18, -24 dBFS, 0.4 s each with 0.1 s between
    for k, lv in enumerate([-6, -12, -18, -24]):
        s = 2.5 + 0.5 * k
        m = at(0.4)
        tt = np.arange(m) / SR
        fade = np.minimum(1, np.minimum(np.arange(m), m - np.arange(m)) / (0.005 * SR))
        x[at(s):at(s) + m] += 10 ** (lv / 20) * np.sin(2 * np.pi * 440 * tt) * fade
        events.append(s)
    sections["tones"] = [2.5, 4.5]
    sections["tone_steps"] = [[2.5 + 0.5 * k + 0.05, 2.5 + 0.5 * k + 0.35, lv] for k, lv in enumerate([-6, -12, -18, -24])]
    # chirp: 100 Hz to 12 kHz in 0.5 s at -9 dBFS
    m = at(0.5)
    tt = np.arange(m) / SR
    fade = np.minimum(1, np.minimum(np.arange(m), m - np.arange(m)) / (0.003 * SR))
    x[at(4.5):at(4.5) + m] += 10 ** (-9 / 20) * signal.chirp(tt, 100, 0.5, 12000, method="logarithmic") * fade
    events.append(4.5)
    sections["chirp"] = [4.5, 5.0]
    # the band: two bars at 120 bpm
    b0 = 5.25
    band, kicks = _band(rng, at(4.0))
    band *= 0.9 * PEAK / max(1e-9, np.max(np.abs(band)))
    x[at(b0):at(b0) + len(band)] += band
    kick_times = [round(b0 + k / SR, 6) for k in kicks]
    sections["band"] = [b0, b0 + 4.0]
    x = np.clip(x, -PEAK, PEAK)
    x += 10 ** (BED_DB / 20) * rng.standard_normal(n) * 0.5
    # events: the isolated onsets used for timing (clicks, tone steps, the chirp); kicks: the band's, for reference only (other parts sound
    # under them, so an onset there is ambiguous from block peaks)
    meta = {"sr": SR, "seconds": total, "peak": PEAK, "bed_db": BED_DB, "sections": sections, "events": sorted(events), "kicks": kick_times}
    return x.astype(np.float32), meta


def write_pattern(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    x, meta = make_pattern()
    wavfile.write(os.path.join(out_dir, "pattern.wav"), SR, x)
    x.astype("<f4").tofile(os.path.join(out_dir, "pattern.f32"))
    with open(os.path.join(out_dir, "pattern.json"), "w") as f:
        json.dump(meta, f, indent=1)
    return meta


def load_pattern(d):
    sr, x = wavfile.read(os.path.join(d, "pattern.wav"))
    with open(os.path.join(d, "pattern.json")) as f:
        return x.astype(float), json.load(f)


# ---------------------------------------------------------------------------------------------------------------------------------------
# Status polls (ears.lua "poll"): one line per read of StudioSync_LiveAudioStatus, its peaks being "since the last ask".
# ---------------------------------------------------------------------------------------------------------------------------------------
def read_poll(path):
    """-> (header dict, rows: list of dicts). The file: a JSON header line, then one JSON object per poll."""
    with open(path, encoding="utf-8") as f:
        lines = [l for l in f.read().splitlines() if l.strip()]
    head = json.loads(lines[0])
    rows = []
    for l in lines[1:]:
        r = json.loads(l)
        if "t" in r:
            rows.append(r)
        elif "note" in r:
            head.setdefault("notes", []).append(r)  # (ears.lua's notes: the hub asked again)
        else:
            head["end"] = r  # (the last line: the clock again, and an error if the poll stopped early)
    return head, rows


def block_clock(rows):
    """-> f(cb): the link-clock time of audio block number cb, fitted over the whole poll (blocks per second and the median offset). REAPER
    runs blocks in bursts (LinuxBox's PulseAudio ~6 back to back, the desktop's WASAPI 2-27 ms apart), so the time a poll saw a block is
    jittery, but the block count is the audio's own clock: a block's sound is cb/rate after the start whenever it was computed."""
    cb = np.array([r["cb"] for r in rows if r.get("cb") is not None], dtype=float)
    t = np.array([r["t"] for r in rows if r.get("cb") is not None])
    new = np.r_[True, np.diff(cb) > 0]  # (the reads that saw a new block: the time it ran, give or take a read)
    slope = np.polyfit(cb[new], t[new], 1)[0]
    off = float(np.median(t[new] - cb[new] * slope))
    return lambda c: off + np.asarray(c, dtype=float) * slope


def series(rows, key, peer=None):
    """-> arrays t (end of the poll's interval), t0 (its start), v (peak in it), ok (a block ran in it), first (Live sync may have read some
    of its peaks), nb (how many blocks it covers), on the block clock (block_clock).
    key: "own" (this computer's Play going out), "hub" (the hub's mix heard), "play"/"talk" (peer's stream heard)."""
    clock = block_clock(rows)
    t, t0, v, ok, first, nb = [], [], [], [], [], []
    prev_t, prev_cb = None, None
    for r in rows:
        if key == "own":
            val = r.get("own")
        elif key == "hub":
            val = r.get("hub")
        else:
            val = (r.get("peers") or {}).get(peer, [None, None])[0 if key == "play" else 1]
        cb = r.get("cb")
        if prev_t is not None and val is not None and cb is not None and prev_cb is not None:
            # (block number c is read just after it starts, with its first sample: so the blocks prev_cb+1..cb hold the sound from block
            # prev_cb+1's start to block cb+1's)
            t.append(float(clock(cb + 1))); t0.append(float(clock(prev_cb + 1))); v.append(float(val))
            # (a read that came after a pause of the poller's, "first", may have had its peaks taken by Live sync's own read meanwhile: on the
            # desktop that was ~4% of them (2026-11-21), so they're kept; a stolen one reads low, and medians and 50 ms bins ride over it)
            ok.append(cb > prev_cb)
            first.append(bool(r.get("first")))
            nb.append(cb - prev_cb)
        prev_t, prev_cb = r["t"], cb
    return np.array(t), np.array(t0), np.array(v), np.array(ok, dtype=bool), np.array(first, dtype=bool), np.array(nb)


def grid_max(t, v, ok, start, step, n, t0=None):
    """Max of the known peaks per bin of `step` s from `start`; NaN where no known poll covers the bin. With t0, a poll covers every bin
    its interval [t0, t) touches (a burst of blocks read at once), else only the bin it ends in."""
    g = np.full(n, np.nan)
    k1 = np.floor((t - start) / step - 1e-9).astype(int)
    k0 = k1 if t0 is None else np.floor((t0 - start) / step).astype(int)
    for i in np.nonzero(ok)[0]:
        for k in range(max(0, k0[i]), min(n - 1, k1[i]) + 1):
            g[k] = v[i] if np.isnan(g[k]) else max(g[k], v[i])
    return g


def pattern_grid(x, offset_s, step, n):
    """The pattern's peak per bin, the pattern's first sample at offset_s into the grid."""
    g = np.zeros(n)
    for k in range(n):
        a, b = int((k * step - offset_s) * SR), int(((k + 1) * step - offset_s) * SR)
        a, b = max(a, 0), min(b, len(x))
        if b > a:
            g[k] = np.max(np.abs(x[a:b]))
    return g


def find_start(t, v, ok, x, t0=None, within=None):
    """Where the pattern starts in a polled series (its own clock): cross-correlation of dB envelopes, first on a 100 ms grid over the whole
    poll (LinuxBox reads ~10 blocks every ~100 ms, which smears finer bins), then on a 25 ms grid within 300 ms of that. -> (time, corr)."""
    def best_in(step, lo, hi):
        n = int((t.max() + 1.0 - lo) / step) + 1
        gm = grid_max(t, v, ok, lo, step, n, t0)
        known = ~np.isnan(gm)
        m = db(np.where(known, gm, 0), -80)
        pg = db(pattern_grid(x, 0.0, step, int(len(x) / SR / step) + 1), -80)
        best, best_k = -np.inf, 0
        for k in range(0, max(1, min(n - len(pg), int((hi - lo) / step) + 1))):
            w = known[k:k + len(pg)]
            if len(w) < len(pg) or w.sum() < len(pg) // 4:
                continue
            a = m[k:k + len(pg)][w]
            if a.std() < 1e-6:
                continue
            c = np.corrcoef(a, pg[w])[0, 1]
            if c > best:
                best, best_k = c, k
        return lo + best_k * step, best
    if within:  # (a receiver: the sender's start plus a plausible delay)
        return best_in(0.025, within[0], within[1])
    coarse, _ = best_in(0.1, t.min() - 1.0, t.max())
    # (the 100 ms grid's pick refined, or a 25 ms search over the whole poll, whichever matches better: a steady reader is best on the
    # fine grid alone, the clicks' and kicks' repeats can mislead the coarse one)
    return max(best_in(0.025, coarse - 0.3, coarse + 0.3), best_in(0.025, t.min() - 1.0, t.max()), key=lambda r: r[1])


def event_times(t, v, ok, centers, events, x, rel=0.3, window=(-0.04, 0.08), t0=None, known=None):
    """Each event's arrival: the first known poll in `window` around its expected time (centers[i]) whose peak passes `rel` of that event's
    own peak (the pattern's, scaled by how loud this series is against the pattern) where the read before it (of `known`) didn't: a rising
    edge, so a louder sound still going isn't taken for it. At the middle of that poll's blocks (t0..t). -> list of (event, time or None)."""
    known = ok if known is None else known
    scale = (np.percentile(v[ok], 99.5) / PEAK) if ok.any() else 0
    a0 = t if t0 is None else t0
    out = []
    for c, e in zip(centers, events):
        a = int(e * SR)
        want = float(np.max(np.abs(x[a:a + int(0.03 * SR)]))) * scale
        hit = None
        for i in np.nonzero(ok & (t >= c + window[0]) & (a0 <= c + window[1]) & (v >= rel * want))[0]:
            prev = np.nonzero(known[:i])[0]
            if want > 0 and (not len(prev) or v[prev[-1]] < rel * want):
                hit = float((a0[i] + t[i]) / 2)
                break
        out.append((e, hit))
    return out


def window_lag(st, st0, sv, sok, rt, rt0, rv, rok, a, b, guess, span=0.25, step=0.025):
    """The receiver's delay over [a, b] (sender's clock): the lag within guess +- span whose 25 ms dB envelope best matches the sender's.
    -> (lag s, correlation)."""
    n = int((b - a) / step)
    sg = grid_max(st, sv, sok, a, step, n, st0)
    best, best_l = -1.0, guess
    for L in np.arange(guess - span, guess + span, step / 2):
        rg = grid_max(rt - L, rv, rok, a, step, n, rt0 - L)
        w = ~np.isnan(sg) & ~np.isnan(rg)
        if w.sum() < n // 3:
            continue
        c = np.corrcoef(db(sg[w], -80), db(rg[w], -80))[0, 1]
        if c > best:
            best, best_l = c, L
    return float(best_l), float(best)


def compare_env(x, meta, send_rows, recv_rows, peer, hub=False, gain=1.0, offset_ms=0.0):
    """Live audio from polls. send: the sender's own Play; recv: the receiver's view of `peer`'s Play (or the hub's mix with hub=True).
    offset_ms: the sender's clock minus the receiver's (the receiver's StudioSync_DirectClock offset_ms for the sender). gain: what the
    receiver should hear against what was sent (the hub's mix is at the listener's levels: its live audio volume)."""
    st, st0, sv, sok, sfi, snb = series(send_rows, "own")
    rt, rt0, rv, rok, rfi, rnb = series(recv_rows, "hub" if hub else "play", peer)
    if not sok.any() or not rok.any():
        return {"error": "no known polls", "send_known": int(sok.sum()), "recv_known": int(rok.sum()), "pass": {}}
    rt, rt0 = rt + offset_ms / 1000.0, rt0 + offset_ms / 1000.0  # (the receiver's times onto the sender's clock)
    s_start, s_c = find_start(st, sv, sok, x, t0=st0)
    r_start, r_c = find_start(rt, rv, rok, x, t0=rt0, within=(s_start - 0.05, s_start + MAX_DELAY))
    ev = meta["events"]
    # (for timing, a read after a pause of the poller's only when it spans at most 15 ms of blocks: Live sync's read in the pause may have
    # taken an onset's peak, so a long one could time a sound already going. Not left out altogether: the pattern's 250 ms spacing can be a
    # whole number of REAPER's defer periods, and then every click lands in the pause, as on the laptop.)
    se = event_times(st, sv, sok & (~sfi | (st - st0 <= 0.015)), [s_start + e for e in ev], ev, x, t0=st0, known=sok & ~sfi)
    rok_t = rok & (~rfi | (rt - rt0 <= 0.015))
    # each event searched around the sender's + the latency so far (half the clicks' spacing either way), so a jump in the delay is followed
    track, lats = r_start - s_start, []
    for e, s_t in se:
        r = None if s_t is None else event_times(rt, rv, rok_t, [s_t + track], [e], x, window=(-0.12, 0.12), t0=rt0, known=rok & ~rfi)[0][1]
        lats.append(None if r is None else r - s_t)
        if r is not None:
            track = r - s_t
    # (a reading no neighbour confirms is an outlier, a false onset after a hole most likely: a real change of delay shows on two events
    # in a row. Kept in latency_each_ms, left out of the numbers.)
    res_out = []
    tol = (LAT_JUMP_MS + 1000 * (float(np.median((st - st0)[sok])) + float(np.median((rt - rt0)[rok])))) / 1000
    idx = [k for k, L in enumerate(lats) if L is not None]
    for n_, k in enumerate(idx):
        near = [lats[idx[m]] for m in (n_ - 1, n_ + 1) if 0 <= m < len(idx)]
        if near and all(abs(lats[k] - L) > tol for L in near):
            res_out.append(ev[k])
    got = [(s_t, L) for (e, s_t), L in zip(se, lats) if L is not None and e not in res_out]
    # the band excerpt has no isolated onsets: its delay from its 25 ms envelope, searched near the last event's
    a, b = meta["sections"]["band"]
    bl, bc = window_lag(st, st0, sv, sok, rt, rt0, rv, rok, s_start + a, s_start + b, track)
    res_band = {"band_latency_ms": round(bl * 1000, 1), "band_lag_corr": round(bc, 3)}
    if bc >= 0.5:
        got.append((s_start + (a + b) / 2, bl))
    res = {"send_start_corr": round(s_c, 3), "recv_start_corr": round(r_c, 3), "events": len(ev), "events_matched": len(got),
           "latency_each_ms": [None if L is None else round(L * 1000, 1) for L in lats], "outlier_events_s": res_out, **res_band}
    if got:
        lat = np.array([L for _, L in got]) * 1000
        res.update(latency_ms=round(float(np.median(lat)), 1), latency_iqr_ms=round(float(np.percentile(lat, 75) - np.percentile(lat, 25)), 1),
                   latency_range_ms=[round(float(lat.min()), 1), round(float(lat.max()), 1)],
                   latency_jump_ms=round(float(np.max(np.abs(np.diff(lat)))) if len(lat) > 1 else 0.0, 1))
        et, el = np.array([s for s, _ in got]), np.array([L for _, L in got])
    else:
        res["latency_ms"] = round((r_start - s_start) * 1000, 1)
        et, el = np.array([s_start]), np.array([r_start - s_start])
    # the receiver's reads onto the sender's timeline, by the latency at that moment (each event's, held after the last)
    lag = np.interp(rt - np.median(el), et, el)
    lag0 = np.interp(rt0 - np.median(el), et, el)
    ut, ut0 = rt - lag, rt0 - lag0
    # level and gaps on a 50 ms grid: the sender's measured peaks against the receiver's
    step = 0.05
    n = int((meta["seconds"] + 1.0) / step)
    g0 = s_start - 0.5
    sg = grid_max(st, sv, sok, g0, step, n, st0)
    rg = grid_max(ut, rv, rok, g0, step, n, ut0)
    both = ~np.isnan(sg) & ~np.isnan(rg)
    loud = both & (db(np.nan_to_num(sg)) > db(PEAK) - 20)
    diff = db(np.nan_to_num(rg)) - db(np.nan_to_num(sg)) - db(gain)
    res["level_db"] = round(float(np.median(diff[loud])), 2) if loud.any() else None
    # (only inside sustained sound, loud in the bins either side too: a click's block can land a bin later at the other end)
    sustained = loud & np.roll(loud, 1) & np.roll(loud, -1)
    gaps = sustained & (diff < -GAP_DB)
    # (a run of gap bins shorter than what one read of the receiver spans isn't seen reliably: LinuxBox reads ~100 ms of blocks at once)
    need = max(1, int(math.ceil(float(np.median((rt - rt0)[rok])) / step - 1e-9)))
    k = 0
    while k < n:
        if gaps[k]:
            e = k
            while e < n and gaps[e]:
                e += 1
            if e - k < need:
                gaps[k:e] = False
            k = e
        else:
            k += 1
    res["loud_bins"], res["gap_bins"] = int(loud.sum()), int(gaps.sum())
    res["gap_ms"] = int(gaps.sum() * step * 1000)
    res["gaps_at_s"] = [round(k * step - 0.5, 2) for k in np.nonzero(gaps)[0]]
    res["unknown_bins"] = int((~np.isnan(sg) & np.isnan(rg)).sum())
    # tone ladder: each step's level against the first, from the receiver alone
    steps = []
    for a, b, lv in meta["sections"]["tone_steps"]:
        w = rok & (ut0 >= s_start + a) & (ut <= s_start + b)
        steps.append(float(db(np.max(rv[w]))) if w.any() else None)
    if all(s is not None for s in steps):
        res["tone_steps_db"] = [round(s - steps[0], 2) for s in steps]
        res["tone_steps_err_db"] = round(max(abs((s - steps[0]) - (lv - meta["sections"]["tone_steps"][0][2]))
                                             for s, (_, _, lv) in zip(steps, meta["sections"]["tone_steps"])), 2)
    # the band excerpt's envelope against what was sent
    a, b = meta["sections"]["band"]
    k0, k1 = int((s_start + a - g0) / step), int((s_start + b - g0) / step)
    w = both[k0:k1]
    if w.sum() > 10:
        res["band_env_corr"] = round(float(np.corrcoef(db(sg[k0:k1][w], -80), db(rg[k0:k1][w], -80))[0, 1]), 3)
    # (one event's reading is good to a read's span of blocks at each end: LinuxBox reads ~6 blocks at once, 64 ms, so its allowance is wider)
    res["resolution_ms"] = round(1000 * (float(np.median((st - st0)[sok])) + float(np.median((rt - rt0)[rok]))), 1)
    res["pass"] = {
        "aligned": min(s_c, r_c) >= 0.5,
        "latency_steady": (res.get("latency_iqr_ms", 999) <= LAT_IQR_MS + res["resolution_ms"] and len(got) >= len(ev) // 2 and
                           res.get("latency_jump_ms", 999) <= LAT_JUMP_MS + res["resolution_ms"]),
        "level": res["level_db"] is not None and abs(res["level_db"]) <= LEVEL_DB,
        "no_gaps": res["gap_bins"] == 0,
        "tone_steps": res.get("tone_steps_err_db", 99) <= STEP_DB,
        "band_envelope": res.get("band_env_corr", 0) >= ENV_CORR,
    }
    return res


# ---------------------------------------------------------------------------------------------------------------------------------------
# Two recordings (wav): alignment, latency, gaps, level, spectra.
# ---------------------------------------------------------------------------------------------------------------------------------------
def read_wav(path):
    sr, x = wavfile.read(path)
    if x.dtype == np.int16:
        x = x / 32768.0
    elif x.dtype == np.int32:
        x = x / 2147483648.0
    x = np.asarray(x, dtype=float)
    if x.ndim > 1:
        x = x.mean(axis=1)
    return sr, x


def align(ref, got, max_lag=None):
    """Lag of got against ref in samples (got[n + lag] ~ ref[n]) by FFT cross-correlation; -> (lag, normalised peak)."""
    c = signal.fftconvolve(got, ref[::-1], mode="full")
    lags = np.arange(-len(ref) + 1, len(got))
    if max_lag is not None:
        keep = np.abs(lags) <= max_lag
        c, lags = c[keep], lags[keep]
    i = int(np.argmax(np.abs(c)))
    norm = math.sqrt(float(np.sum(ref ** 2)) * float(np.sum(got ** 2))) or 1.0
    return int(lags[i]), float(abs(c[i]) / norm)


def align_env(ref, got, sr):
    """The same lag by loudness (|x| over 5 ms, a point a millisecond), to a millisecond or two. For a live path: its delay wanders by
    more than a waveform's period, so no one lag lines the waveforms up and the strongest of the weak peaks can be anywhere (a +-3 ms
    wander put it 108 ms off, and every check after it read wrong)."""
    k = max(1, sr // 1000)

    def env(x):
        n = len(x) // k
        e = np.convolve(np.abs(x[:n * k]).reshape(n, k).mean(axis=1), np.ones(5) / 5, mode="same")
        return e - e.mean()
    a, b = env(ref), env(got)
    if not len(a) or not len(b):
        return 0
    c = signal.fftconvolve(b, a[::-1], mode="full")
    return (int(np.argmax(c)) - (len(a) - 1)) * k


def third_octave_db(x, sr):
    f, p = signal.welch(x, sr, nperseg=4096)
    centres = 1000 * 2 ** (np.arange(-14, 13) / 3)  # 62.5 Hz .. 16 kHz
    out = []
    for c in centres:
        lo, hi = c / 2 ** (1 / 6), c * 2 ** (1 / 6)
        w = (f >= lo) & (f < hi)
        out.append(10 * np.log10(max(np.sum(p[w]), 1e-20)))
    return centres, np.array(out)


def spectral_diff(a, b, sr):
    """Mean |dB| difference of third-octave bands (50 Hz-16 kHz) where a's band is within 40 dB of its loudest."""
    _, A = third_octave_db(a, sr)
    _, B = third_octave_db(b, sr)
    w = A > A.max() - 40
    return float(np.mean(np.abs(A[w] - B[w])))


SPEED_TOL = 0.002  # got's pitch against ref's: the laptop played the desktop's Play 1.5-2 % fast (rt-r1, rt-fix6b); a live path is 1:1


def tone_hz(x, sr, lo=200.0, hi=2000.0):
    """The strongest frequency between lo and hi over x (a fine FFT, interpolated), or None when x is silent. For the speed check."""
    if len(x) < sr // 10 or np.max(np.abs(x)) < 1e-4:
        return None
    n = 1 << int(math.ceil(math.log2(len(x) * 4)))
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x)), n=n))
    f = np.fft.rfftfreq(n, 1.0 / sr)
    i = int(np.argmax(np.where((f >= lo) & (f <= hi), spec, 0)))
    if 0 < i < len(spec) - 1:  # (parabolic interpolation of the peak in dB)
        a, b, c = (20 * np.log10(spec[i + k] + 1e-30) for k in (-1, 0, 1))
        d = 0.5 * (a - c) / (a - 2 * b + c) if (a - 2 * b + c) != 0 else 0.0
        return float((i + d) * sr / n)
    return float(f[i])


def tone_scan(x, sr, f0, win_s=0.25):
    """The median strongest frequency of x's 0.25 s windows whose peak lies within 10 % of f0 (the pattern's tone ladder), or None."""
    w, out = int(win_s * sr), []
    for a in range(0, len(x) - w, w):
        seg = x[a:a + w]
        if np.max(np.abs(seg)) < 0.01:
            continue
        f = tone_hz(seg, sr, f0 * 0.9, f0 * 1.1)
        full = tone_hz(seg, sr)
        if f and full and abs(full - f) < 1.0:  # (the window's strongest tone overall is that one: a tone step, not the band or a click)
            out.append(f)
    return float(np.median(out)) if len(out) >= 2 else None


def device_rate(pairs, block):
    """A device's REAL sample rate, Hz, from (link-clock time, audio callbacks so far) pairs and its block size: the slope of callbacks
    against time, as the median of the slopes between looks at least half the span apart (callbacks come in bursts, a VM's ten at once,
    and looks are jittery, so no single pair of looks is trusted). None with under 2 s of looks. rt-audio3: the desktop's device (WASAPI
    through Voicemeeter) runs 0.2-1 % under 48 kHz and moves from minute to minute; what a WAV's samples mean in time is this, not 48000."""
    p = [(float(t), float(c)) for t, c in (pairs or []) if t is not None and c is not None]
    runs, a = [], 0  # (the count starts again when live audio restarts: the longest stretch without that)
    for i in range(1, len(p) + 1):
        if i == len(p) or p[i][1] < p[i - 1][1]:
            runs.append(p[a:i]); a = i
    p = max(runs, key=len) if runs else []
    if not block or len(p) < 8 or p[-1][0] - p[0][0] < 2.0:
        return None
    step = max(1, len(p) // 200)
    p = p[::step]
    span = p[-1][0] - p[0][0]
    sl = [(c2 - c1) / (t2 - t1) for i, (t1, c1) in enumerate(p) for (t2, c2) in p[i + 1:] if t2 - t1 >= span / 2]
    return float(np.median(sl)) * float(block) if sl else None


def poll_rate(head, rows):
    """The same from a status poll (ears.lua "poll": each row's t and cb; the header's block since rt-audio3)."""
    return device_rate([(r.get("t"), r.get("cb")) for r in rows], (head or {}).get("block"))


def sound_span(x, floor=1e-3):
    """(first, last) sample of x with sound in it, or None."""
    loud = np.flatnonzero(np.abs(x) >= floor)
    return (int(loud[0]), int(loud[-1])) if len(loud) else None


def stamp_rate(path, span=None, sr=48000):
    """The same from an ears tap's stamp (<wav>.json: cbs and block, ears.lua "tap" since rt-audio3). None for an older stamp.
    span: (first, last) sample of the WAV the rate is wanted for (sound_span): the looks taken while those samples were recorded, when
    they make a rate (8 looks over 2 s), else the whole tap's. rt-r5: the desktop's device moves within a tap (47909 Hz over a 30 s tap,
    47777 Hz through its 9 s of sound), and judged by the tap's average a receiver in step read "0.23 % sharp, 180 ms of gaps"."""
    try:
        with open(path + ".json") as f:
            s = json.load(f)
    except (OSError, ValueError):
        return None
    cbs, t0 = s.get("cbs"), s.get("t_first")
    if span and cbs and t0 is not None:
        part = device_rate([c for c in cbs if t0 + span[0] / sr <= c[0] <= t0 + span[1] / sr], s.get("block"))
        if part:
            return part
    return device_rate(cbs, s.get("block"))


def to_rate(x, want):
    """x stretched in time by `want` (the same sound in want times the samples), band-limited."""
    from fractions import Fraction
    fr = Fraction(float(want)).limit_denominator(4000)
    return signal.resample_poly(x, fr.numerator, fr.denominator) if fr.numerator != fr.denominator else x


def compare_wav(ref, got, sr, meta=None, exact=False, rates=None, gain=1.0):
    """ref, got: the same signal recorded at two ends. meta: the pattern's (with pattern_at: where it starts in ref, s) for per-section
    spectra. exact: a lossless path (bit-exact, 16-bit). gain: the level got is expected at against ref (a hub's mix at the listener's
    volume: 0.01).
    rates: (ref's device's real rate, got's), Hz (device_rate), or None for both at sr. A WAV holds a device's samples, and a second of
    them lasts 1 / its real rate: a receiver that plays what arrives in real time, as it should, holds the sound in (got's rate / ref's)
    times the samples. So got is first put on ref's sample clock (stretched by ref's rate / got's), every check is made on that, and
    `speed` is judged against the two real rates. Before rt-audio3 it was judged against 1: on the desktop (0.2-1 % under 48 kHz) a
    receiver that followed its device read "0.25 % fast, 250 ms of gaps" (the gaps: 10 ms frames compared 25 ms apart by the pattern's
    end) and one that played sample for sample, its buffer draining to a re-buffer every minute, read "speed 0.99993: pass"."""
    if np.max(np.abs(got)) < 1e-4 * min(1.0, gain) <= np.max(np.abs(ref)):  # (rt-r1's r6: a tap that ended before the sound came read as "silent")
        return {"error": "GOT is silent (peak %.1e): its tap ran while nothing came (see tap_window with --stamps), or the stream was muted"
                % float(np.max(np.abs(got))), "pass": {"heard": False}}
    want = float(rates[0]) / float(rates[1]) if rates and rates[0] and rates[1] else 1.0  # (got's tone over ref's when all is well)
    raw = got
    if abs(want - 1) > 2e-5 and not exact:
        got = to_rate(got, want)
    if gain != 1.0:
        got = got / gain
        raw = raw / gain
    lag, peak = align(ref, got)
    if not exact and peak < 0.8:  # (no one lag fits the waveform: a live path. Its lag by loudness)
        lag = align_env(ref, got, sr)
    r_off = max(0, -lag)  # (r[i] is ref[i + r_off], g[i] the got sample heard with it)
    g = got[max(0, lag):]
    r = ref[r_off:]
    m = min(len(r), len(g))
    r, g = r[:m], g[:m]
    res = {"lag_samples": lag, "lag_ms": round(lag / sr * 1000, 2), "corr": round(peak, 4), "overlap_s": round(len(g) / sr, 3)}
    # (whether GOT is REF's sound at all: 0.1 s at a time, each at its own lag. One lag for the whole recording asks a live path's delay
    # to hold within a fraction of a waveform's period for its whole length, which no jitter buffer does: rt-r5 read corr 0.33-0.46 and
    # "aligned: false" on every run, the good ones too, where 85 % of the 0.1 s stretches match at 0.8 or better)
    cw = [x[2] for x in steady_lags(ref, got, sr, lag, win_s=0.1)] if not exact else []
    if len(cw) >= 10:
        res["corr_windows"] = round(float(np.median(cw)), 4)
    hop = int(0.01 * sr)
    nf = len(r) // hop
    fr = np.array([np.sqrt(np.mean(r[i * hop:(i + 1) * hop] ** 2)) for i in range(nf)])
    fg = np.array([np.sqrt(np.mean(g[i * hop:(i + 1) * hop] ** 2)) for i in range(nf)])
    loud = db(fr) > db(fr.max()) - 30
    d = db(fg) - db(fr)
    res["level_db"] = round(float(np.median(d[loud])), 2) if loud.any() else None
    # (a gap: a loud stretch of REF with nothing in GOT there nor in the 10 ms either side. A live path's delay wanders by a few ms, and
    # a click that fell in the next frame over read as "10 ms of gap" a time: 40-120 ms of them in rt-r5's runs with no underrun)
    near = np.maximum(fg, np.maximum(np.concatenate([fg[:1], fg[:-1]]), np.concatenate([fg[1:], fg[-1:]]))) if nf else fg
    gaps = loud & (db(near) - db(fr) < -GAP_DB)
    res["gap_ms"] = int(gaps.sum() * 10)
    # longest run of gap frames
    run = best = 0
    for v in gaps:
        run = run + 1 if v else 0
        best = max(best, run)
    res["longest_gap_ms"] = best * 10
    res["max_abs_diff"] = float(np.max(np.abs(g - r))) if len(g) else None
    spec = {}
    if meta:
        p0 = meta.get("pattern_at", 0.0)
        for name in ("chirp", "band"):
            a, b = meta["sections"][name]
            ia, ib = int((p0 + a) * sr) - r_off, int((p0 + b) * sr) - r_off
            if ia >= 0 and ib <= len(r):
                spec[name] = round(spectral_diff(r[ia:ib], g[ia:ib], sr), 2)
    else:
        spec["all"] = round(spectral_diff(r, g, sr), 2)
    res["spectral_db"] = spec
    if meta:  # (the tone ladder's tone, wherever it is in each: a receiver playing fast has no single lag to align by)
        f0 = meta.get("tone_hz", 440.0)
        fr, fg = tone_scan(ref, sr, f0), tone_scan(raw, sr, f0)
    else:
        fr, fg = tone_hz(ref, sr), tone_hz(raw, sr)
    res["speed"] = round(fg / fr, 5) if fr and fg else None  # (got's samples against ref's, as recorded)
    res["speed_expected"] = round(want, 5)                   # (what the two devices' real rates make of a receiver in step)
    res["speed_error"] = round(fg / fr / want, 5) if fr and fg else None
    if rates:
        res["rates_hz"] = [round(float(rates[0]), 1) if rates[0] else None, round(float(rates[1]), 1) if rates[1] else None]
    lim = SPEC_DB_EXACT if exact else SPEC_DB
    res["pass"] = {
        "aligned": peak >= 0.999 if exact else res.get("corr_windows", peak) >= 0.8,
        "level": res["level_db"] is not None and abs(res["level_db"]) <= (0.01 if exact else LEVEL_DB),
        "no_gaps": res["gap_ms"] == 0,
        "spectrum": all(v <= lim for v in spec.values()),
        "speed": res["speed_error"] is None or abs(res["speed_error"] - 1) <= SPEED_TOL,
    }
    if exact:
        res["pass"]["bit_exact"] = res["max_abs_diff"] is not None and res["max_abs_diff"] <= 1.0 / 32768
    if not exact:  # (a live path: its delay must hold still through the recording, LAT_IQR_MS / LAT_JUMP_MS as env's)
        sl = steady_lags(ref, got, sr, lag)
        ms = [x[1] / sr * 1000 for x in sl if x[2] >= 0.8]  # (a window matched less well than that: a repeat in the music, left out)
        if len(ms) >= 3:
            res["steady"] = {"windows": len(ms), "min_ms": round(min(ms), 1), "max_ms": round(max(ms), 1),
                             "jump_ms": round(max(abs(b - a) for a, b in zip(ms, ms[1:])), 1)}
            res["pass"]["steady"] = max(ms) - min(ms) <= LAT_JUMP_MS
    return res


def steady_lags(ref, got, sr, base_lag, win_s=0.5, search_ms=200.0, min_rms_db=-50.0):
    """The lag of got against ref window by window (each win_s of ref with sound in it, searched within +-search_ms of base_lag): a delay
    that moves (sound dropped or repeated, a re-buffer, a skip) shows as a step. -> [(t_s in ref, lag_samples, corr)]."""
    out = []
    w, s = int(win_s * sr), int(search_ms / 1000 * sr)
    for a in range(0, len(ref) - w, w):
        r = ref[a:a + w]
        if db(np.sqrt(np.mean(r ** 2))) < min_rms_db:
            continue
        g0 = a + base_lag - s
        if g0 < 0 or g0 + w + 2 * s > len(got):
            continue
        seg = got[g0:g0 + w + 2 * s]
        c = signal.fftconvolve(seg, r[::-1], mode="valid")  # (only lags with r wholly inside seg: 0 .. 2s)
        i = int(np.argmax(np.abs(c)))
        e = math.sqrt(float(np.sum(r ** 2)) * float(np.sum(seg[i:i + w] ** 2))) or 1.0
        out.append((a / sr, g0 + i - a, float(abs(c[i]) / e)))
    return out


def stamp_latency(ref_path, got_path, lag, sr, ref_rate=None):
    """The ears tap's stamps (REF.wav.json, GOT.wav.json from ears.lua "tap": t_first on each one's link clock, its me and its
    StudioSync_DirectClock): latency = when got heard a sample less when ref sent it, on the sender's clock. None without both.
    ref_rate: the sender's device's real rate (compare_wav's rates[0]), with lag counted on its sample clock: lag samples last
    lag / that, not lag / sr (rt-r3: 127.6 ms stamped against 152-171 in the status, with the taps seconds apart on a device 0.3 % off)."""
    try:
        rs = json.load(open(ref_path + ".json"))
        gs = json.load(open(got_path + ".json"))
    except (OSError, ValueError):
        return None
    peers = (gs.get("clock") or {}).get("peers") or {}
    sender = rs.get("me") or ""
    off = next((v.get("offset_ms") for k, v in peers.items() if sender and k.startswith(sender)), 0.0) or 0.0
    # (offset_ms: the receiver's estimate of the sender's clock minus its own; got's stamp moved onto the sender's clock)
    return (gs["t_first"] + off / 1000.0 + lag / (ref_rate or sr) - rs["t_first"]) * 1000.0


def tap_window(ref_path, got_path, ref, got, sr):
    """A silent GOT: where its tap ran against when REF's sound went out, both on the sender's link clock (s), and what that says. rt-fix6b"""
    try:
        rs = json.load(open(ref_path + ".json"))
        gs = json.load(open(got_path + ".json"))
    except (OSError, ValueError):
        return None
    peers = (gs.get("clock") or {}).get("peers") or {}
    sender = rs.get("me") or ""
    off = next((v.get("offset_ms") for k, v in peers.items() if sender and k.startswith(sender)), 0.0) or 0.0
    loud = np.flatnonzero(np.abs(ref) >= 1e-3)
    if not len(loud) or rs.get("t_first") is None or gs.get("t_first") is None:
        return None
    s0, s1 = rs["t_first"] + loud[0] / sr, rs["t_first"] + loud[-1] / sr
    g0 = gs["t_first"] + off / 1000.0
    g1 = g0 + len(got) / sr
    why = ("GOT's tap ended %.1f s before the sound went out: start it later (rig.sh live TAP=...)" % (s0 - g1) if g1 < s0
           else "GOT's tap started %.1f s after the sound ended" % (g0 - s1) if g0 > s1 + MAX_DELAY
           else "GOT's tap overlapped the sound: the stream itself came silent here")
    return {"sound_s": [round(s0, 3), round(s1, 3)], "tap_s": [round(g0, 3), round(g1, 3)], "why": why}


# ---------------------------------------------------------------------------------------------------------------------------------------
# The Hop's held note: where its tail ends after the note-off.
# ---------------------------------------------------------------------------------------------------------------------------------------
def note_tail(x, sr, on_s, off_s, release_ms=0.0, bound_ms=200.0, block=512, floor_db=-60.0):
    """x: the instrument's sound as heard at the end being checked; on_s/off_s: the note-on/off as sent (same clock as x).
    The onset (first sample over floor) gives the path's delay; the tail's end is the last sample over floor; it must come no later than
    off + delay + release + bound + one block."""
    e = np.abs(x)
    thr = max(10 ** (floor_db / 20), np.max(e) * 10 ** (-50 / 20)) if np.max(e) > 0 else 1
    over = np.nonzero(e > thr)[0]
    res = {"threshold_db": round(float(db(thr)), 1)}
    if not len(over):
        res["pass"] = {"heard": False}
        return res
    onset = over[0] / sr
    end = over[-1] / sr
    delay = onset - on_s
    tail = (end - off_s - delay) * 1000
    allowed = release_ms + bound_ms + block / sr * 1000
    res.update(onset_s=round(onset, 4), delay_ms=round(delay * 1000, 1), end_s=round(end, 4), tail_ms=round(tail, 1),
               allowed_ms=round(allowed, 1), held_ms=round((end - onset) * 1000, 1))
    res["pass"] = {"heard": True, "stops_in_bound": tail <= allowed, "not_cut_early": tail >= -block / sr * 1000 - 5}
    return res


def _verdict(res):
    ok = all(res.get("pass", {}).values()) and "error" not in res
    res["ok"] = ok
    print(json.dumps(res, indent=1, default=lambda o: o.item() if hasattr(o, "item") else str(o)))
    return 0 if ok else 1


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pattern"); p.add_argument("out")
    e = sub.add_parser("env"); e.add_argument("pattern"); e.add_argument("send"); e.add_argument("recv")
    e.add_argument("--peer", default=""); e.add_argument("--hub", action="store_true"); e.add_argument("--gain", type=float, default=1.0)
    e.add_argument("--offset-ms", type=float, default=None, help="the sender's clock minus the receiver's (default: the receiver poll's clock)")
    w = sub.add_parser("wav"); w.add_argument("ref"); w.add_argument("got"); w.add_argument("--pattern"); w.add_argument("--exact", action="store_true")
    w.add_argument("--stamps", action="store_true", help="the ears tap's REF.wav.json/GOT.wav.json: latency on the link clock, and each device's real rate")
    w.add_argument("--polls", nargs=2, metavar=("REF.jsonl", "GOT.jsonl"), help="each end's status poll, for the devices' real rates (stamps from before rt-audio3 have none)")
    w.add_argument("--rates", nargs=2, type=float, metavar=("REF_HZ", "GOT_HZ"), help="the devices' real rates, measured some other way")
    w.add_argument("--gain", type=float, default=1.0, help="the level GOT is expected at against REF (a hub's mix at the listener's volume: 0.01)")
    t = sub.add_parser("tail"); t.add_argument("got"); t.add_argument("--on", type=float, required=True); t.add_argument("--off", type=float, required=True)
    t.add_argument("--release-ms", type=float, default=0.0); t.add_argument("--bound-ms", type=float, default=200.0); t.add_argument("--block", type=int, default=512)
    a = ap.parse_args(argv)
    if a.cmd == "pattern":
        meta = write_pattern(a.out)
        print(json.dumps({"ok": True, "seconds": meta["seconds"], "events": len(meta["events"])}))
        return 0
    if a.cmd == "env":
        x, meta = load_pattern(a.pattern)
        sh, srows = read_poll(a.send)
        rh, rrows = read_poll(a.recv)
        off = a.offset_ms
        if off is None:  # the receiver's DirectClock estimate for the sender: offset_ms = its clock minus this one's
            peers = (rh.get("clock") or {}).get("peers") or {}
            sender = sh.get("me") or ""
            off = next((v.get("offset_ms") for k, v in peers.items() if sender and k.startswith(sender)), 0.0)
        peer = next((k for r in rrows for k in (r.get("peers") or {}) if a.peer and k.startswith(a.peer)), a.peer)
        res = compare_env(x, meta, srows, rrows, peer, hub=a.hub, gain=a.gain, offset_ms=off)
        res["offset_ms"] = off
        return _verdict(res)
    if a.cmd == "wav":
        sr, ref = read_wav(a.ref)
        sr2, got = read_wav(a.got)
        if sr != sr2:
            got = signal.resample_poly(got, sr, sr2)
        meta = None
        if a.pattern:
            px, meta = load_pattern(a.pattern)
            lag, _ = align(px, ref)
            meta["pattern_at"] = lag / sr
        # (each device's real rate: given, else from the polls, else from the taps' own stamps; without both, speed is judged against 1 and says so)
        rates = None
        if a.rates:
            rates = tuple(a.rates)
        elif a.polls:
            rates = tuple(poll_rate(*read_poll(p)) for p in a.polls)
        elif a.stamps:  # (each device's rate while its WAV's sound was recorded, not the whole tap's)
            rates = (stamp_rate(a.ref, sound_span(ref), sr), stamp_rate(a.got, sound_span(got), sr))
        known = bool(rates and rates[0] and rates[1])
        res = compare_wav(ref, got, sr, meta, exact=a.exact, rates=rates if known else None, gain=a.gain)
        if not known and not a.exact:
            res["rates_note"] = "the devices' real rates aren't known (no cbs in the stamps, no --polls or --rates): speed is judged against 1, which is wrong for a device off its nominal rate"
        if a.stamps and "error" in res:
            res["tap_window"] = tap_window(a.ref, a.got, ref, got, sr)
        elif a.stamps:
            res["latency_ms"] = stamp_latency(a.ref, a.got, res["lag_samples"], sr, rates[0] if known else None)
            res["pass"]["stamped"] = res["latency_ms"] is not None
        return _verdict(res)
    if a.cmd == "tail":
        sr, x = read_wav(a.got)
        return _verdict(note_tail(x, sr, a.on, a.off, a.release_ms, a.bound_ms, a.block))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
