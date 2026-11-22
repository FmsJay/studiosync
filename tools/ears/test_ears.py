"""Offline checks for tools/ears/ears.py: a simulated link (delay, a lossy-codec stand-in, dropouts) and simulated status polls must give the
numbers that were put in. Run: python -m unittest discover -s tools/ears (tests/run.py does). Skipped without numpy/scipy."""
import os
import sys
import unittest

try:
    import numpy as np
    from scipy import signal
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import ears
except ImportError:  # (numpy/scipy missing: nothing to check here)
    ears = None

SR = 48000


def link(x, delay_s, gain=1.0, lowpass=None, noise_db=None, drops=(), seed=1):
    """What a receiver would get: delayed, scaled, optionally low-passed (a lossy codec's top end), noise added, and stretches zeroed."""
    y = np.concatenate([np.zeros(int(delay_s * SR)), x * gain])
    if lowpass:
        y = signal.sosfilt(signal.butter(8, lowpass, fs=SR, output="sos"), y)
    if noise_db is not None:
        y = y + 10 ** (noise_db / 20) * np.random.default_rng(seed).standard_normal(len(y))
    for a, b in drops:
        y[int((delay_s + a) * SR):int((delay_s + b) * SR)] = 0
    return y


def polls(x, wall0, block, rate_s=0.002, steal_every=0.033, gap_every=None, seed=2, drops=()):
    """Status polls as ears.lua writes them: blocks of `block` frames run at wall times wall0 + k*block/SR (x's sample k*block starts block k);
    each poll reports the peak of the blocks run since the previous poll and the callback count; every steal_every s a foreign read
    (Live sync's) takes the peaks and the next poll is marked first. drops: (a, b) seconds of x heard as silence."""
    rng = np.random.default_rng(seed)
    nb = len(x) // block
    bt = wall0 + np.arange(nb) * block / SR
    bp = np.array([np.max(np.abs(x[k * block:(k + 1) * block])) for k in range(nb)])
    for a, b in drops:
        bp[(np.arange(nb) * block / SR >= a) & (np.arange(nb) * block / SR < b)] = 0
    rows, t, k, cb, first, next_steal = [], wall0 - 0.5, 0, 0, True, wall0 - 0.5 + steal_every
    while t < bt[-1] + 0.5:
        t += rate_s * (0.8 + 0.4 * rng.random())
        if t >= next_steal:  # a foreign read: blocks so far consumed, unseen
            while k < nb and bt[k] <= next_steal:
                k += 1; cb += 1
            next_steal += steal_every
            first = True
            t += 0.010  # (the defer cycle's pause)
        pk = 0.0
        while k < nb and bt[k] <= t:
            pk = max(pk, bp[k]); k += 1; cb += 1
        rows.append({"t": t, "cb": cb, "first": first, "own": pk, "hub": pk, "peers": {"A:1": [pk, 0.0]}})
        first = False
    return rows


@unittest.skipIf(ears is None, "numpy/scipy not installed")
class EarsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.x, cls.meta = ears.make_pattern()
        cls.x = cls.x.astype(float)

    def test_pattern(self):
        self.assertLessEqual(np.max(np.abs(self.x)), ears.PEAK + 0.01)
        self.assertEqual(len(self.meta["events"]), 13)
        a, b = self.meta["sections"]["band"]
        band = self.x[int(a * SR):int(b * SR)]
        # a band, not a tone: energy spread over the spectrum (bass and the top both there)
        c, bands = ears.third_octave_db(band, SR)
        self.assertGreater(bands[c < 120].max(), bands.max() - 25)
        self.assertGreater(bands[c > 6000].max(), bands.max() - 40)

    def test_wav_lossless_path(self):
        ref = np.concatenate([np.zeros(SR), self.x])
        got = link(ref, 0.0)
        q = np.round(got * 32767) / 32767  # (16-bit like Jam's WAV)
        r = ears.compare_wav(np.round(ref * 32767) / 32767, q, SR, dict(self.meta, pattern_at=1.0), exact=True)
        self.assertTrue(all(r["pass"].values()), r)
        self.assertEqual(r["lag_samples"], 0)

    def test_wav_codec_path(self):
        ref = np.concatenate([np.zeros(SR), self.x])
        got = link(ref, 0.0734, gain=10 ** (-0.5 / 20), lowpass=18000, noise_db=-70)
        r = ears.compare_wav(ref, got, SR, dict(self.meta, pattern_at=1.0))
        self.assertAlmostEqual(r["lag_ms"], 73.4, delta=0.1)
        self.assertAlmostEqual(r["level_db"], -0.5, delta=0.3)
        self.assertTrue(all(r["pass"].values()), r)

    def test_wav_dropout_and_dull(self):
        ref = np.concatenate([np.zeros(SR), self.x])
        got = link(ref, 0.05, drops=[(1.0 + 6.0, 1.0 + 6.06)])
        r = ears.compare_wav(ref, got, SR, dict(self.meta, pattern_at=1.0))
        self.assertFalse(r["pass"]["no_gaps"], r)
        self.assertGreaterEqual(r["longest_gap_ms"], 40)
        dull = link(ref, 0.05, lowpass=2500)
        r = ears.compare_wav(ref, dull, SR, dict(self.meta, pattern_at=1.0))
        self.assertFalse(r["pass"]["spectrum"], r)

    def test_wav_live_tap_steady_and_stamped(self):
        # rt-p11: the ears tap's two WAVs of live audio. The field's fault: ~300 ms for 4 s, then a resync to ~200 ms (100 ms never heard).
        ref = np.concatenate([np.zeros(SR), self.x, np.zeros(SR // 2)])
        ok = link(ref, 0.2, lowpass=18000, noise_db=-70)
        r = ears.compare_wav(ref, ok, SR, dict(self.meta, pattern_at=1.0))
        self.assertTrue(r["pass"]["steady"], r)
        cut = int((1.0 + 4.0) * SR)
        late = np.concatenate([np.zeros(int(0.3 * SR)), ref[:cut], ref[cut + int(0.1 * SR):]])
        r = ears.compare_wav(ref, late, SR, dict(self.meta, pattern_at=1.0))
        self.assertFalse(r["pass"]["steady"], r)
        self.assertGreaterEqual(r["steady"]["max_ms"] - r["steady"]["min_ms"], 90)
        # the stamps: the sender's first frame at 100.0 on its link clock, the receiver's at 99.5 on its own, which it reckons 1.2 s behind
        # the sender's (offset_ms +1200 for it); the WAVs' lag 0.2 s: 99.5 + 1.2 + 0.2 - 100.0 = 0.9 s
        import json
        import tempfile
        d = tempfile.mkdtemp()
        rp, gp = os.path.join(d, "ref.wav"), os.path.join(d, "got.wav")
        with open(rp + ".json", "w") as f:
            json.dump({"t_first": 100.0, "me": "desk"}, f)
        with open(gp + ".json", "w") as f:
            json.dump({"t_first": 99.5, "me": "lap", "clock": {"peers": {"desk.ts.net:47281": {"offset_ms": 1200.0}}}}, f)
        self.assertAlmostEqual(ears.stamp_latency(rp, gp, int(0.2 * SR), SR), 900.0, delta=0.01)
        self.assertIsNone(ears.stamp_latency(rp, os.path.join(d, "none.wav"), 0, SR))

    def test_wav_speed_and_silent_tap(self):
        # rt-fix6b: rt-r1's laptop heard the desktop's Play 1.5 % fast (the tone ladder's 440 Hz at 446.5): "speed" fails on that, passes 1:1
        ref = np.concatenate([np.zeros(SR), self.x, np.zeros(SR // 2)])
        r = ears.compare_wav(ref, link(ref, 0.1, lowpass=18000, noise_db=-70), SR, dict(self.meta, pattern_at=1.0))
        self.assertAlmostEqual(r["speed"], 1.0, delta=0.0005)
        self.assertTrue(r["pass"]["speed"], r)
        fast = signal.resample(ref, int(len(ref) / 1.015))  # (played 1.5 % fast: the same sound in fewer samples)
        r = ears.compare_wav(ref, np.concatenate([np.zeros(int(0.1 * SR)), fast]), SR, dict(self.meta, pattern_at=1.0))
        self.assertAlmostEqual(r["speed"], 1.015, delta=0.001)
        self.assertFalse(r["pass"]["speed"], r)
        # rt-r1's r6: the desktop's tap ended 10 s before the laptop's Play went out: "silent", with where each ran
        import json
        import tempfile
        r = ears.compare_wav(ref, np.zeros(len(ref)) + 1e-34, SR, dict(self.meta, pattern_at=1.0))
        self.assertFalse(r["pass"]["heard"], r)
        self.assertIn("silent", r["error"])
        d = tempfile.mkdtemp()
        rp, gp = os.path.join(d, "ref.wav"), os.path.join(d, "got.wav")
        with open(rp + ".json", "w") as f:
            json.dump({"t_first": 140.0, "me": "lap"}, f)
        with open(gp + ".json", "w") as f:
            json.dump({"t_first": 101.0, "me": "desk", "clock": {"peers": {"lap.ts.net:47281": {"offset_ms": 1000.0}}}}, f)
        w = ears.tap_window(rp, gp, ref, np.zeros(30 * SR), SR)
        self.assertIn("ended", w["why"])
        self.assertAlmostEqual(w["tap_s"][1], 132.0, delta=0.01)

    def test_device_rate(self):
        # rt-audio3: a device's real rate from looks at its callback count. The desktop's: 0.25 % under 48 kHz at 512, looked at every
        # 20-50 ms, the count up to 20 ms behind (its callbacks come 2-27 ms apart)
        rng = np.random.default_rng(5)
        t = np.cumsum(rng.uniform(0.02, 0.05, 900)) + 1000.0
        cb = np.floor((t - 1000.0 - rng.uniform(0, 0.02, len(t))) * 47880.0 / 512)
        self.assertAlmostEqual(ears.device_rate(list(zip(t, cb)), 512) / 47880.0, 1.0, delta=0.0003)
        # a VM: ten blocks at once
        cbv = np.floor((t - 1000.0) * 48006.5 / 512 / 10) * 10
        self.assertAlmostEqual(ears.device_rate(list(zip(t, cbv)), 512) / 48006.5, 1.0, delta=0.0005)
        self.assertIsNone(ears.device_rate([(0.0, 0), (1.0, 90)], 512))  # (under 2 s of looks: no rate)
        self.assertIsNone(ears.device_rate(list(zip(t, cb)), None))      # (an older stamp, without the block size)
        rows = [r for r in polls(np.zeros(SR * 6), 1000.0, 512) if 1000.2 <= r["t"] <= 1005.8]  # (a poll's rows while the audio runs)
        self.assertAlmostEqual(ears.poll_rate({"block": 512}, rows) / SR, 1.0, delta=0.001)

    def test_wav_judged_by_real_rates(self):
        # rt-r3's r9 (the laptop -> the desktop): the receiver's device runs 0.25 % under 48 kHz and it plays the sender in real time, as
        # it should: the same sound in 0.25 % fewer of its samples. Judged against 1 that read "0.25 % fast, 250 ms of gaps, not aligned"
        ref = np.concatenate([np.zeros(SR), self.x, np.zeros(SR // 2)])
        meta = dict(self.meta, pattern_at=1.0)
        got = np.concatenate([np.zeros(int(0.1 * SR)), signal.resample(ref, int(round(len(ref) * 47880 / 48000)))])
        r = ears.compare_wav(ref, got, SR, meta)
        self.assertFalse(r["pass"]["speed"], r)
        self.assertGreater(r["gap_ms"], 0, r)  # (the artefact: frames 25 ms apart by the pattern's end)
        r = ears.compare_wav(ref, got, SR, meta, rates=(48000.0, 47880.0))
        self.assertAlmostEqual(r["speed"], 1.0025, delta=0.0005)
        self.assertAlmostEqual(r["speed_error"], 1.0, delta=0.0005)
        for k in ("speed", "aligned", "no_gaps", "level", "spectrum", "steady"):
            self.assertTrue(r["pass"][k], (k, r))
        # rt-r3's r7 (the desktop -> the laptop): the SENDER's device is 0.3 % slow and the receiver plays its samples one for one, its
        # buffer draining to a re-buffer every minute. Judged against 1 that read "speed 0.99993: pass"
        r = ears.compare_wav(ref, np.concatenate([np.zeros(int(0.1 * SR)), ref]), SR, meta, rates=(47860.0, 48000.0))
        self.assertAlmostEqual(r["speed_expected"], 0.99708, delta=0.0001)
        self.assertFalse(r["pass"]["speed"], r)
        # a hub's mix arrives at the listener's own volume (0.01): its level is judged against that
        r = ears.compare_wav(ref, link(ref, 0.1, lowpass=18000, noise_db=-110) * 0.01, SR, meta, gain=0.01)
        self.assertTrue(r["pass"]["level"] and r["pass"]["aligned"], r)
        self.assertFalse(ears.compare_wav(ref, link(ref, 0.1, lowpass=18000, noise_db=-110) * 0.01, SR, meta)["pass"]["level"])
        # the stamps' latency counts lag on the sender's real sample clock
        import json
        import tempfile
        d = tempfile.mkdtemp()
        rp, gp = os.path.join(d, "ref.wav"), os.path.join(d, "got.wav")
        with open(rp + ".json", "w") as f:
            json.dump({"t_first": 100.0, "me": "desk", "block": 512, "cbs": [[100.0 + i * 0.03, int(i * 0.03 * 47860 / 512)] for i in range(400)]}, f)
        with open(gp + ".json", "w") as f:
            json.dump({"t_first": 99.5, "me": "lap", "clock": {"peers": {"desk.ts.net:47281": {"offset_ms": 1200.0}}}}, f)
        self.assertAlmostEqual(ears.stamp_rate(rp) / 47860.0, 1.0, delta=0.0005)
        self.assertIsNone(ears.stamp_rate(gp))
        lag = 10 * SR  # (the receiver's tap started 10 s of samples before the sender's first sample was heard)
        self.assertAlmostEqual(ears.stamp_latency(rp, gp, lag, SR, 47860.0) - ears.stamp_latency(rp, gp, lag, SR), 10000.0 * (48000 / 47860.0 - 1), delta=0.01)

    def _env(self, latency, block_s=512, block_r=128, gain=1.0, drops=(), offset_ms=0.0):
        sig = np.concatenate([np.zeros(SR), self.x, np.zeros(SR)])
        s_rows = polls(sig, 1000.0, block_s, seed=3)
        # the receiver's clock runs offset_ms behind the sender's: its wall times are smaller by that much
        r_rows = polls(sig * gain, 1000.0 + latency - offset_ms / 1000, block_r, seed=4, drops=[(1 + a, 1 + b) for a, b in drops])
        return ears.compare_env(self.x, self.meta, s_rows, r_rows, "A:1", gain=gain, offset_ms=offset_ms)

    def test_env_latency_level(self):
        r = self._env(0.104, offset_ms=-1358.5)
        self.assertAlmostEqual(r["latency_ms"], 104, delta=6)
        self.assertTrue(all(r["pass"].values()), r)

    def test_env_hub_gain(self):
        r = self._env(0.15, block_r=512, gain=0.01)
        self.assertAlmostEqual(r["latency_ms"], 150, delta=8)
        self.assertTrue(all(r["pass"].values()), r)
        r = ears.compare_env(self.x, self.meta, polls(np.concatenate([np.zeros(SR), self.x]), 0.0, 512),
                             polls(np.concatenate([np.zeros(SR), self.x]) * 0.1, 0.15, 512), "A:1", gain=0.01)
        self.assertFalse(r["pass"]["level"], r)  # 20 dB louder than asked for

    def test_env_dropout(self):
        r = self._env(0.1, drops=[(6.0, 6.2)])
        self.assertFalse(r["pass"]["no_gaps"], r)
        self.assertGreaterEqual(r["gap_ms"], 100)

    def test_note_tail(self):
        n = 2 * SR
        x = np.zeros(n)
        on, off, delay, release = 0.2, 0.8, 0.09, 0.03
        a, b = int((on + delay) * SR), int((off + delay) * SR)
        t = np.arange(n) / SR
        x[a:b] = 0.3 * np.sin(2 * np.pi * 220 * t[a:b])
        rel = int(release * SR)
        x[b:b + rel] = 0.3 * np.sin(2 * np.pi * 220 * t[b:b + rel]) * np.linspace(1, 0, rel)
        r = ears.note_tail(x, SR, on, off, release_ms=30)
        self.assertTrue(all(r["pass"].values()), r)
        self.assertAlmostEqual(r["delay_ms"], 90, delta=1)
        hung = x.copy()
        hung[b:b + int(0.6 * SR)] = 0.3 * np.sin(2 * np.pi * 220 * t[b:b + int(0.6 * SR)])  # a lost note-off: rings 600 ms on
        r = ears.note_tail(hung, SR, on, off, release_ms=30)
        self.assertFalse(r["pass"]["stops_in_bound"], r)


if __name__ == "__main__":
    unittest.main()
