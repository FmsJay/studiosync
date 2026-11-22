"""Shared pieces of tools/devices (rt-t1, docs/rt/rt-t1.md): the host web UI on this computer, Chrome with fake devices, the in-page audio
tap (webtap.js) and small signal checks. GPL-3.0-or-later.

Never a real microphone or camera: guests get Chrome's fake devices with a generated WAV; listeners need no input at all.
"""
import base64
import json
import math
import os
import subprocess
import sys
import time
import urllib.request

import numpy as np
from scipy.io import wavfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
EARS = os.path.join(REPO, "tools", "ears", "ears.py")
sys.path.insert(0, os.path.dirname(EARS))  # (ears.tone_hz and friends)
HOST = os.environ.get("SS_HOST", "http://127.0.0.1:47281")  # this computer's web UI: no token on 127.0.0.1, acts as this computer (owner)
CHROME = os.environ.get("SS_CHROME", r"C:\Program Files\Google\Chrome\Application\chrome.exe")
SR = 48000
TAP_JS = open(os.path.join(HERE, "webtap.js"), encoding="utf-8").read()


# ---- the host's web UI (127.0.0.1) ---------------------------------------------------------------------------------------------------------
def state():
    with urllib.request.urlopen(HOST + "/api/state", timeout=10) as r:
        return json.loads(r.read().decode("utf-8")).get("topics", {})


def act(topic, **o):
    """An action as the host's own Home page sends it (POST /api/action with X-StudioSync)."""
    body = json.dumps(dict(topic=topic, **o)).encode("utf-8")
    req = urllib.request.Request(HOST + "/api/action", data=body, method="POST",
                                 headers={"Content-Type": "application/json", "X-StudioSync": "1"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.status


def wait_for(fn, secs=20, every=0.5, what="condition"):
    end = time.time() + secs
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(every)
    raise TimeoutError("waited %d s for %s" % (secs, what))


_last_make = [0.0]
GUEST_GAP = 5.5  # (lib/guestweb.lua: one guest link every 5 s, 12 an hour)


def make_guest(name, minutes=30, gain=None):
    """A guest link from the host (guestweb make), its volume set before anyone joins. -> (gid, link)."""
    before = {g["gid"] for g in state().get("guestweb", {}).get("guests", [])}
    g = None
    for _ in range(3):  # (a refusal for the 5 s gap: once seen right at the start of a run, cause unknown; wait and ask again)
        time.sleep(max(0.0, _last_make[0] + GUEST_GAP - time.time()))
        _last_make[0] = time.time()
        sent = time.time()
        act("guestweb", make={"name": name, "minutes": minutes})
        try:
            g = wait_for(lambda: next((g for g in state().get("guestweb", {}).get("guests", []) if g["gid"] not in before and g.get("name") == name
                                       and g.get("link")), None) or (_refused(sent) and "refused"), secs=15, what="the guest link")
        except TimeoutError:
            g = None
        if isinstance(g, dict):
            break
        time.sleep(GUEST_GAP)
    if not isinstance(g, dict):
        raise RuntimeError("no guest link: " + json.dumps(state().get("guestweb", {}).get("last")))
    if gain is not None:
        act("guestweb", gain={"gid": g["gid"], "v": gain})
        wait_for(lambda: any(x["gid"] == g["gid"] and abs((x.get("gain") or 1) - gain) < 1e-9
                             for x in state().get("guestweb", {}).get("guests", [])), what="the guest's volume")
    return g["gid"], g["link"]


def _refused(since):
    last = state().get("guestweb", {}).get("last") or {}
    return bool(last.get("bad")) and (last.get("at") or 0) >= int(since) - 1


def guest_row(gid):
    return next((g for g in state().get("guestweb", {}).get("guests", []) if g["gid"] == gid), None)


def make_listen_link(hours=1):
    """A tailnet listening link from the host (audience make). -> (id, url)."""
    before = {k["id"] for k in state().get("audience", {}).get("links", [])}
    act("audience", make={"hours": hours})
    k = wait_for(lambda: next((k for k in state().get("audience", {}).get("links", []) if k["id"] not in before and k.get("url")), None),
                 what="the listening link")
    return k["id"], k["url"]


def revoke_listen(lid):
    act("audience", revoke=lid)


def kick_guest(gid):
    act("guestweb", kick=gid)


# ---- this computer's REAPER, through its dev eval hook (the desktop's; locked as the bandtest helpers and tools/ears/rig.sh do) ----------
HOOK = os.environ.get("SS_EVAL_HOOK", r"J:\Portable Workstation\DAW\REAPER\Scripts\MIDI Control Center\midi_control_center\dev")


def reaper_eval(lua_file, pre="", secs=30):
    """Run lua_file (with `pre` prepended, e.g. "T1={mode='fire'}") in REAPER's dev eval hook and return its result text. The hook is shared:
    its lock folder (.evallock, taken over after 10 minutes) and any pending eval.lua are waited for."""
    import tempfile
    lock = os.path.join(HOOK, ".evallock")
    for _ in range(600):
        try:
            os.mkdir(lock)
            break
        except FileExistsError:
            if time.time() - os.path.getmtime(lock) > 600:
                try:
                    os.rmdir(lock)
                except OSError:
                    pass
            time.sleep(1)
    try:
        for _ in range(60):
            if not os.path.exists(os.path.join(HOOK, "eval.lua")):
                break
            time.sleep(1)
        src = os.path.join(tempfile.gettempdir(), "rt-t1_eval_%d.lua" % os.getpid())
        with open(src, "w", encoding="utf-8") as f:
            f.write(pre + "\n" + open(lua_file, encoding="utf-8").read())
        res = os.path.join(HOOK, "result.txt")
        if os.path.exists(res):
            os.remove(res)
        tmp = os.path.join(HOOK, "eval.tmp")
        with open(tmp, "w", encoding="ascii") as f:
            f.write("return dofile([[%s]])" % src.replace("\\", "/"))
        os.replace(tmp, os.path.join(HOOK, "eval.lua"))
        for _ in range(int(secs * 4)):
            if os.path.exists(res):
                time.sleep(0.1)
                return open(res, encoding="utf-8", errors="replace").read()
            time.sleep(0.25)
        return "NO RESULT"
    finally:
        try:
            os.rmdir(lock)
        except OSError:
            pass


def cpu_load():
    """This computer's CPU % and run queue (3 samples, Windows): real-time results on a busy computer aren't the product's."""
    r = subprocess.run(["powershell", "-NoProfile", "-Command", "Get-Counter '\\Processor(_Total)\\% Processor Time','\\System\\Processor Queue Length' "
                        "-SampleInterval 1 -MaxSamples 3 | % { ($_.CounterSamples | % { [int]$_.CookedValue }) -join '/' }"],
                       capture_output=True, text=True, timeout=30)
    return r.stdout.split()


# ---- Chrome ----------------------------------------------------------------------------------------------------------------------------------
def chrome_args(wav=None):
    a = ["--autoplay-policy=no-user-gesture-required", "--mute-audio", "--disable-background-timer-throttling",
         "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows"]
    if wav:  # (a fake microphone and camera only: Chrome's own generated devices, the microphone reading this file, looped)
        a += ["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream", "--use-file-for-fake-audio-capture=" + wav.replace("\\", "/")]
    return a


def launch(pw, wav=None, headless=False):
    """Chrome for one guest or listener on THIS computer, windowed (off screen, muted by --mute-audio) by default. Measured 2026-11-22: on a
    busy computer (another agent's soak, run queue 30-70) a headless Chrome's audio clock ran 2 % slow and wandered 0.3 s and the main thread
    stalled up to 0.6 s, so guests under-ran about once a second; on a quiet one both headless (the laptop) and windowed (the desktop) keep
    1.0000 with 13-22 ms wander and no stalls. guests.py logs the load (cpu_load) with its results."""
    args = chrome_args(wav) + ([] if headless else ["--window-position=-2400,-2400", "--window-size=520,420"])
    b = pw.chromium.launch(executable_path=CHROME, headless=headless, args=args)
    ctx = b.new_context(ignore_https_errors=False)
    ctx.add_init_script(TAP_JS)
    return b, ctx


LAPTOP_CHROME = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
LAPTOP_TMP = r"C:\Users\FMSJa\AppData\Local\Temp\rt-t1"


class RemoteChrome:
    """Headless Chrome on the laptop (over `ssh laptop`; nothing on its screen, nothing installed there), driven from here over CDP through
    an ssh tunnel. A guest from another computer, as a real one would be. Its fake microphone file is copied over first. Chrome lives as long
    as the ssh session that started it (Windows OpenSSH ends a session's processes with it). Use: `with RemoteChrome(pw, port, wav) as (b, ctx):`."""

    def __init__(self, pw, port, wav=None, host="laptop"):
        self.pw, self.port, self.wav, self.host = pw, port, wav, host
        self.procs = []

    def __enter__(self):
        tag = "rt-t1-%d" % self.port
        rwav = None
        subprocess.run(["ssh", self.host, "New-Item -ItemType Directory -Force '%s\\%s' | Out-Null" % (LAPTOP_TMP, tag)], capture_output=True, timeout=30)
        if self.wav:
            rwav = "%s\\%s\\%s" % (LAPTOP_TMP, tag, os.path.basename(self.wav))
            subprocess.run(["scp", "-q", self.wav, "%s:%s" % (self.host, rwav.replace("\\", "/"))], check=True, timeout=60)
        args = chrome_args(rwav) + ["--headless=new", "--remote-debugging-port=%d" % self.port, "--remote-debugging-address=127.0.0.1",
                                    "--user-data-dir=%s\\%s\\profile" % (LAPTOP_TMP, tag), "--no-first-run", "--no-default-browser-check", "about:blank"]
        cmd = "& '%s' %s; Start-Sleep -Seconds 86400" % (LAPTOP_CHROME, " ".join("'%s'" % x for x in args))
        self.procs.append(subprocess.Popen(["ssh", "-L", "%d:127.0.0.1:%d" % (self.port, self.port), self.host, cmd],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL))
        url = "http://127.0.0.1:%d" % self.port

        def up():
            try:
                with urllib.request.urlopen(url + "/json/version", timeout=3) as r:
                    return r.status == 200
            except Exception:  # noqa: BLE001
                return False
        wait_for(up, secs=40, every=1, what="the laptop's Chrome DevTools")
        self.b = self.pw.chromium.connect_over_cdp(url, timeout=30000)
        ctx = self.b.contexts[0]
        ctx.add_init_script(TAP_JS)
        if self.wav:
            ctx.grant_permissions(["microphone"])
        return self.b, ctx

    def __exit__(self, *exc):
        try:
            self.b.close()
        except Exception:  # noqa: BLE001
            pass
        subprocess.run(["ssh", self.host, "Get-CimInstance Win32_Process -Filter \"Name='chrome.exe'\" | Where-Object { $_.CommandLine -like '*rt-t1-%d*' } "
                        "| ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; Start-Sleep 1; "
                        "Remove-Item -Recurse -Force -ErrorAction SilentlyContinue '%s\\rt-t1-%d'; "
                        "if (-not (Get-ChildItem '%s' -ErrorAction SilentlyContinue)) { Remove-Item -Force -ErrorAction SilentlyContinue '%s' }"
                        % (self.port, LAPTOP_TMP, self.port, LAPTOP_TMP, LAPTOP_TMP)],
                       capture_output=True, timeout=60)
        for p in self.procs:
            p.terminate()
        return False


# ---- the tap ----------------------------------------------------------------------------------------------------------------------------------
def tap_fetch(page, info=None):
    """What webtap.js kept on that page -> float32 array (frames, 2), and the stop() info."""
    info = info or page.evaluate("window.__ssTap.stop()")
    n, step, parts = info["frames"], SR, []
    for i in range(0, n, step):
        b = base64.b64decode(page.evaluate("([i, n]) => window.__ssTap.chunk(i, n)", [i, min(step, n - i)]))
        parts.append(np.frombuffer(b, dtype="<f4"))
    x = np.concatenate(parts) if parts else np.zeros(0, dtype="<f4")
    return x.reshape(-1, 2), info


def write_wav(path, x, sr=SR):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    wavfile.write(path, sr, np.asarray(x, dtype=np.float32))


def read_mono(path):
    sr, x = wavfile.read(path)
    x = x.astype(np.float64)
    if x.dtype.kind == "i" or np.max(np.abs(x)) > 4:
        x = x / 32768.0
    if x.ndim > 1:
        x = x.mean(axis=1)
    return sr, x


# ---- signal checks ------------------------------------------------------------------------------------------------------------------------
def db(v):
    return 20 * math.log10(max(float(v), 1e-12))


def tone_db(x, sr, f, bw=8.0):
    """RMS level (dBFS) of x within +-bw Hz of f (Welch PSD)."""
    from scipy import signal
    if len(x) < sr // 4:
        return -240.0
    fr, p = signal.welch(x, sr, nperseg=min(len(x), 16384))
    w = (fr >= f - bw) & (fr <= f + bw)
    return 10 * math.log10(max(float(np.sum(p[w]) * (fr[1] - fr[0])), 1e-24))


def ears_wav(ref, got, pattern_dir=None, gain=1.0, out_scaled=None):
    """tools/ears/ears.py wav REF GOT (GOT first scaled by 1/gain, so a path heard at a known volume compares level-for-level). -> dict."""
    if gain != 1.0:
        sr, x = wavfile.read(got)
        x = x.astype(np.float64) / gain
        out_scaled = out_scaled or got[:-4] + "_scaled.wav"
        wavfile.write(out_scaled, sr, x.astype(np.float32))
        got = out_scaled
    cmd = [sys.executable, EARS, "wav", ref, got] + (["--pattern", pattern_dir] if pattern_dir else [])
    r = subprocess.run(cmd, capture_output=True, text=True)
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stdout + r.stderr)[-800:]}


def gen_tone(path, hz, secs=60, peak=0.25, sr=SR):
    """A steady tone, 16-bit PCM (what Chrome's fake microphone reads most surely), a whole number of cycles so its loop doesn't click."""
    n = int(round(secs * hz)) * sr // int(hz) if float(hz).is_integer() else int(secs * sr)
    t = np.arange(n) / sr
    wavfile.write(path, sr, np.clip(peak * np.sin(2 * np.pi * hz * t) * 32767, -32768, 32767).astype(np.int16))


def gen_pattern_loop(path, pattern_dir, gap_s=2.25, sr=SR):
    """The ears pattern followed by gap_s of silence (so each loop of Chrome's fake microphone is one clean pattern), 16-bit PCM."""
    _, p = wavfile.read(os.path.join(pattern_dir, "pattern.wav"))
    x = np.concatenate([p.astype(np.float64), np.zeros(int(gap_s * sr))])
    wavfile.write(path, sr, np.clip(x * 32767, -32768, 32767).astype(np.int16))
