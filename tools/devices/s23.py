"""The S23 driver (rt-t1, docs/rt/rt-t1.md; plan in docs/rt/rt-lab.md "The S23 over adb"). GPL-3.0-or-later.

James's phone, reached over wireless adb on the tailnet. What this does, and nothing more:
  * adb through its OWN adb server (port S23_ADB_PORT, 5047): the desktop's usual server (5037) runs elevated and was found wedged
    (2026-11-21: `adb devices` hung, `adb shell` hung, and an unelevated shell can't restart it); a second server reaches the same phone.
  * Chrome's DevTools socket forwarded to 127.0.0.1:S23_CDP_PORT (9341: 9222 is often taken on the desktop), Playwright
    `connect_over_cdp`, pages opened in NEW tabs and closed afterwards; James's own tabs are never touched or read.
  * The phone's playback captured with scrcpy (`--no-video --no-control --no-window --audio-source=playback --audio-codec=raw
    --record=x.wav --time-limit=N`): digital, nothing installed (scrcpy's server is pushed to /data/local/tmp and removes itself), and
    without --audio-dup the sound is captured instead of played, so the phone stays silent.
  * NEVER the microphone or camera (no page here asks; a page that would is not opened), no settings changed, no apps installed, no taps.
  * busy(): in a call, or the screen on and unlocked (James is using it): the caller waits or skips.

  python tools/devices/s23.py state          what the phone is doing (call, screen, lock, foreground app, Chrome, its DevTools socket)
  python tools/devices/s23.py tabs           how many Chrome tabs (no URLs: those are James's)
"""
import contextlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

SERIAL = os.environ.get("S23_SERIAL", "jamess-s23-ultra:5555")
ADB_PORT = os.environ.get("S23_ADB_PORT", "5047")
CDP_PORT = int(os.environ.get("S23_CDP_PORT", "9341"))
SCRCPY = os.environ.get("SCRCPY") or shutil.which("scrcpy") or "scrcpy"


def _env():
    e = dict(os.environ)
    e["ANDROID_ADB_SERVER_PORT"] = ADB_PORT
    return e


def adb(*args, timeout=30, check=False):
    r = subprocess.run(["adb", "-s", SERIAL] + list(args), capture_output=True, text=True, timeout=timeout, env=_env())
    if check and r.returncode != 0:
        raise RuntimeError("adb %s: %s" % (" ".join(args), (r.stderr or r.stdout).strip()[:300]))
    return r.stdout


def connect():
    """Our adb server up and the phone on it (a wireless adb connect to the same serial; changes nothing on the phone)."""
    subprocess.run(["adb", "connect", SERIAL], capture_output=True, text=True, timeout=30, env=_env())
    out = subprocess.run(["adb", "devices"], capture_output=True, text=True, timeout=30, env=_env()).stdout
    return any(l.startswith(SERIAL) and l.split()[-1] == "device" for l in out.splitlines())


def shell(cmd, timeout=30):
    return adb("shell", cmd, timeout=timeout)


def state():
    out = shell("dumpsys telephony.registry | grep -m1 mCallState; dumpsys power | grep -m1 mWakefulness=; "
                "dumpsys window | grep -m1 isKeyguardShowing; dumpsys activity activities | grep -m1 topResumedActivity; "
                "echo CHROME=$(pidof com.android.chrome); echo DEVTOOLS=$(grep -c @chrome_devtools_remote /proc/net/unix); "
                "dumpsys power | grep -m1 'lastUserActivityTime='", timeout=40)
    g = lambda pat: (re.search(pat, out) or [None, None])[1]  # noqa: E731
    top = g(r"topResumedActivity=ActivityRecord\{\S+ \S+ (\S+)")
    ago = g(r"lastUserActivityTime=\d+ \((\d+) ms ago\)")
    return {"call_state": int(g(r"mCallState=(\d)") or -1), "awake": g(r"mWakefulness=(\w+)") == "Awake",
            "locked": g(r"isKeyguardShowing=(\w+)") == "true", "top": top, "chrome_pid": g(r"CHROME=(\d+)"),
            "devtools": int(g(r"DEVTOOLS=(\d+)") or 0) > 0, "idle_min": round(int(ago) / 60000, 1) if ago else None}


IDLE_MIN = 10  # minutes since the last touch before the phone counts as not in use (it stays awake and unlocked on its charger)


def busy(st=None):
    """-> why the phone shouldn't be used now, or None. On its charger the S23 stays awake and unlocked with the last app in front for
    hours (stay-awake while plugged in), so the screen says nothing: the last touch (dumpsys power lastUserActivityTime) does."""
    st = st or state()
    if st["call_state"] != 0:
        return "in a call (or ringing)"
    if st["idle_min"] is None or st["idle_min"] < IDLE_MIN:
        return "James touched it %s min ago" % st["idle_min"]
    return None


def stamp():
    """The phone's own clock (s since 1970) over ssh, for lining a capture up with the PC's (good to tens of ms)."""
    r = subprocess.run(["ssh", "-o", "ConnectTimeout=8", "s23", "date +%s.%N"], capture_output=True, text=True, timeout=20)
    try:
        return float(r.stdout.strip())
    except ValueError:
        return None


def forward():
    adb("forward", "tcp:%d" % CDP_PORT, "localabstract:chrome_devtools_remote", check=True)
    return "http://127.0.0.1:%d" % CDP_PORT


def unforward():
    adb("forward", "--remove", "tcp:%d" % CDP_PORT)


@contextlib.contextmanager
def chrome(pw, init_script=None):
    """The phone's Chrome over CDP: yields (browser, new_page) where new_page() opens a NEW tab (closed when the block ends). The forward
    is removed afterwards. Chrome must already be running (its DevTools socket exists only then)."""
    url = forward()
    opened = []
    b = None
    try:
        b = pw.chromium.connect_over_cdp(url, timeout=30000)
        ctx = b.contexts[0]
        if init_script:
            ctx.add_init_script(init_script)

        def new_page():
            p = ctx.new_page()
            opened.append(p)
            return p
        yield b, new_page
    finally:
        for p in opened:
            with contextlib.suppress(Exception):
                p.close()
        if b:
            with contextlib.suppress(Exception):
                b.close()  # (for a connect_over_cdp browser: disconnects, leaves Chrome running)
        unforward()


def launcher_of(pkg):
    out = shell("cmd package resolve-activity --brief -c android.intent.category.LAUNCHER " + pkg).strip().splitlines()
    return out[-1] if out and "/" in out[-1] else None


@contextlib.contextmanager
def tab(pw, url, init_script=None):
    """One tab on the phone's Chrome at `url`, yielded as a Playwright page and closed afterwards. When Chrome has no DevTools socket (it
    isn't in front), the link is opened with a VIEW intent (Chrome comes to the front), attached, and reloaded so init_script is in; then the
    app that was in front is brought back as its launcher icon would (where James left it)."""
    before = state()
    launched = False
    if not before["devtools"]:
        shell("am start -a android.intent.action.VIEW -d '%s' com.android.chrome" % url)
        launched = True
        t0 = time.time()
        while not state()["devtools"]:
            if time.time() - t0 > 30:
                raise TimeoutError("the phone's Chrome opened no DevTools socket")
            time.sleep(1)
    try:
        with chrome(pw, init_script) as (b, new_page):
            if launched:
                host = url.split("/")[2]
                ctx = b.contexts[0]
                t0 = time.time()
                pg = None
                while pg is None and time.time() - t0 < 20:
                    pg = next((p for p in ctx.pages if host in p.url), None)
                    time.sleep(0.5)
                if pg is None:
                    raise TimeoutError("the intent's tab wasn't found")
                try:
                    pg.reload(wait_until="domcontentloaded")
                    yield pg
                finally:
                    with contextlib.suppress(Exception):
                        pg.close()
            else:
                pg = new_page()
                pg.goto(url, wait_until="domcontentloaded", timeout=30000)
                yield pg
    finally:
        if launched and before.get("top") and "chrome" not in before["top"]:
            comp = launcher_of(before["top"].split("/")[0])
            if comp:
                shell("am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -f 0x10200000 -n " + comp)


def capture(out_wav, secs):
    """Start scrcpy capturing the phone's playback (raw PCM 48 kHz stereo) for `secs` seconds into out_wav. -> the Popen (wait() on it)."""
    os.makedirs(os.path.dirname(os.path.abspath(out_wav)), exist_ok=True)
    cmd = [SCRCPY, "-s", SERIAL, "--no-video", "--no-control", "--no-window", "--audio-source=playback", "--audio-codec=raw",
           "--record=" + out_wav, "--time-limit=%d" % int(secs), "--verbosity=info"]
    return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=_env())


def tabs():
    forward()
    try:
        import urllib.request
        with urllib.request.urlopen("http://127.0.0.1:%d/json/list" % CDP_PORT, timeout=10) as r:
            return sum(1 for t in json.loads(r.read().decode()) if t.get("type") == "page")
    finally:
        unforward()


if __name__ == "__main__":
    if not connect():
        print(json.dumps({"online": False}))
        sys.exit(1)
    what = sys.argv[1] if len(sys.argv) > 1 else "state"
    if what == "state":
        st = state()
        st["busy"] = busy(st)
        print(json.dumps(st))
    elif what == "tabs":
        print(tabs())
