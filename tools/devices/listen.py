"""The listening-link check, unattended (rt-t1; docs/rt/rt-audience.md, docs/rt/rt-p11.md check 8). GPL-3.0-or-later.

  python tools/devices/listen.py OUT_DIR [--pc] [--phone] [--launch-chrome] [--secs 26] [--fires 2]

On the desktop (its web UI on 127.0.0.1:47281 makes the link; its REAPER plays the pattern):
  1. tools/devices/pattern.lua adds "T1 Pattern" to Cross Test: the ears pattern (tools/ears) through the MASTER at -40 dB (this computer's
     own track, never sent to bandmates; ears.jsfx copied into REAPER's Effects/StudioSync Ears/ for the run when it isn't there).
  2. A tailnet listening link (audience make), revoked at the end.
  3. Listeners: --pc a windowed Chrome here (muted, off screen), --phone the S23's Chrome over adb/CDP in a new tab (tools/devices/s23.py).
     Each presses Listen live; webtap.js records what the page plays; on the phone scrcpy also records the phone's playback (digital, the
     phone stays silent). --launch-chrome: when the phone's Chrome has no DevTools socket (it isn't open), open the link with a VIEW intent,
     attach, reload it with the tap, and afterwards bring back the app that was in front.
  4. The pattern is fired --fires times, 12 s apart; each capture is compared with the pattern (tools/ears/ears.py wav, scaled by 1/0.01).
  5. Always: the link revoked, the tabs closed, the track removed, ears.jsfx removed again if this copied it.
Writes OUT_DIR/listen_result.json. The S23 is used only when it's idle (s23.busy()), unless --phone-anyway.
"""
import argparse
import contextlib
import json
import os
import shutil
import subprocess
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import devlib as D  # noqa: E402

PAT_LUA = os.path.join(D.HERE, "pattern.lua")
FX_DIR = os.environ.get("SS_EARS_FX", r"J:\Portable Workstation\DAW\REAPER\Effects\StudioSync Ears")
VOL = 0.01


def pat(mode, **kw):
    pre = "T1={mode='%s'%s}" % (mode, "".join(", %s=%s" % (k, ("[[%s]]" % v.replace("\\", "/")) if isinstance(v, str) else v) for k, v in kw.items()))
    out = D.reaper_eval(PAT_LUA, pre)
    line = next((l for l in out.splitlines() if "T1PAT" in l), out.strip()[:300])
    return line


def open_listener(page, url):
    page.goto(url, wait_until="domcontentloaded", timeout=30000)
    D.wait_for(lambda: page.evaluate("!document.getElementById('go').disabled"), secs=20, what="Listen live enabled")
    page.click("#go")
    D.wait_for(lambda: page.evaluate("window.ssListen && window.ssListen.stats().on"), secs=10, what="listening on")


def compare(wav, pattern_dir, gain):
    sr, x = D.read_mono(wav)
    r = {"peak_db": round(D.db(np.max(np.abs(x))) if len(x) else -240, 1), "secs": round(len(x) / sr, 2)}
    if sr != D.SR:
        r["error"] = "rate %d" % sr
        return r
    # each fire separately: cut the capture into the stretches around each loud burst, compare each with the pattern
    r["ears"] = D.ears_wav(os.path.join(pattern_dir, "pattern.wav"), wav, pattern_dir, gain=gain)
    return r


import s23 as S23  # noqa: E402


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--pc", action="store_true")
    ap.add_argument("--phone", action="store_true")
    ap.add_argument("--phone-anyway", action="store_true")
    ap.add_argument("--launch-chrome", action="store_true")
    ap.add_argument("--secs", type=float, default=26.0)
    ap.add_argument("--fires", type=int, default=2)
    a = ap.parse_args(argv)
    from playwright.sync_api import sync_playwright
    os.makedirs(a.out, exist_ok=True)
    pattern_dir = os.path.join(a.out, "pattern")
    subprocess.run([sys.executable, D.EARS, "pattern", pattern_dir], check=True, capture_output=True)
    res = {"started": time.strftime("%Y-%m-%d %H:%M:%S"), "log": []}
    copied_fx = False
    lid = None
    phone_prev = None
    launched = False
    try:
        if a.phone:
            if not S23.connect():
                res["phone"] = "offline"
                a.phone = False
            else:
                st = S23.state()
                res["phone_state_before"] = st
                why = S23.busy(st)
                if why and not a.phone_anyway:
                    res["phone"] = "skipped: " + why
                    a.phone = False
                phone_prev = st
        if not (a.pc or a.phone):
            raise RuntimeError("no listener (" + str(res.get("phone")) + ")")
        if not os.path.exists(os.path.join(FX_DIR, "ears.jsfx")):
            os.makedirs(FX_DIR, exist_ok=True)
            shutil.copy(os.path.join(D.REPO, "tools", "ears", "ears.jsfx"), FX_DIR)
            copied_fx = True
        res["track"] = pat("add", f32=os.path.join(pattern_dir, "pattern.f32"), vol=VOL)
        res["info"] = pat("info")
        mv = 1.0
        try:
            mv = float(res["info"].split("master_vol=")[1].split()[0])
        except (IndexError, ValueError):
            pass
        gain = VOL * mv
        res["gain"] = gain
        lid, url = D.make_listen_link(1)
        with sync_playwright() as pw, contextlib.ExitStack() as stack:
            pages = {}
            if a.pc:
                b, c = D.launch(pw, None)
                stack.callback(b.close)
                pages["pc"] = c.new_page()
                open_listener(pages["pc"], url)
            proc = None
            if a.phone:
                st = S23.state()
                if not st["devtools"] and a.launch_chrome:
                    S23.shell("am start -a android.intent.action.VIEW -d '%s' com.android.chrome" % url)
                    launched = True
                    D.wait_for(lambda: S23.state()["devtools"], secs=30, what="the phone's Chrome DevTools socket")
                _b, new_page = stack.enter_context(S23.chrome(pw, D.TAP_JS))
                if launched:  # (the intent's tab: found by its link, reloaded so the tap is in; closed at the end like ours)
                    ctx = _b.contexts[0]
                    pg = D.wait_for(lambda: next((p for p in ctx.pages if p.url.startswith(url.split("?")[0]) and "l=" in p.url), None), secs=20,
                                    what="the listening tab")
                    stack.callback(lambda: pg.close())
                    pg.reload(wait_until="domcontentloaded")
                    D.wait_for(lambda: pg.evaluate("!document.getElementById('go').disabled"), secs=20, what="Listen live enabled")
                    pg.click("#go")
                    D.wait_for(lambda: pg.evaluate("window.ssListen && window.ssListen.stats().on"), secs=10, what="listening on")
                    pages["phone"] = pg
                else:
                    pages["phone"] = new_page()
                    open_listener(pages["phone"], url)
            time.sleep(4)
            for p in pages.values():
                p.evaluate("window.__ssTap.start()")
            if a.phone:
                res["phone_stamp_before"] = S23.stamp()
                proc = S23.capture(os.path.join(a.out, "phone_scrcpy.wav"), a.secs)
            time.sleep(2.5)
            fires = []
            for i in range(a.fires):
                fires.append(pat("fire"))
                time.sleep(12)
            time.sleep(max(0, a.secs - 2.5 - 12 * a.fires))
            stats = {k: p.evaluate("window.ssListen.stats()") for k, p in pages.items()}
            infos = {k: p.evaluate("window.__ssTap.stop()") for k, p in pages.items()}
            res["fires"], res["page_stats"] = fires, stats
            if proc:
                out, _ = proc.communicate(timeout=a.secs + 30)
                res["scrcpy"] = out[-1500:]
                res["phone_stamp_after"] = S23.stamp()
            res["captures"] = {}
            for k, p in pages.items():
                x, info = D.tap_fetch(p, infos[k])
                f = os.path.join(a.out, "listen_%s_tap.wav" % k)
                D.write_wav(f, x)
                res["captures"][k + "_tap"] = dict(compare(f, pattern_dir, gain), missed_blocks=info["missed"], frames=info["frames"])
            if proc and os.path.exists(os.path.join(a.out, "phone_scrcpy.wav")):
                res["captures"]["phone_scrcpy"] = compare(os.path.join(a.out, "phone_scrcpy.wav"), pattern_dir, gain)
            res["audience_status"] = D.state().get("audience", {})
    except Exception as e:  # noqa: BLE001
        res["error"] = "%s: %s" % (type(e).__name__, str(e)[:600])
    finally:
        if lid:
            with contextlib.suppress(Exception):
                D.revoke_listen(lid)
        with contextlib.suppress(Exception):
            res["removed"] = pat("remove")
        if copied_fx:
            with contextlib.suppress(Exception):
                os.remove(os.path.join(FX_DIR, "ears.jsfx"))
                os.rmdir(FX_DIR)
        if launched and phone_prev and phone_prev.get("top") and "chrome" not in phone_prev["top"]:
            with contextlib.suppress(Exception):  # (the app that was in front, as its launcher icon would: back where James left it)
                comp = S23.launcher_of(phone_prev["top"].split("/")[0])
                if comp:
                    S23.shell("am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -f 0x10200000 -n " + comp)
                    res["phone_restored"] = comp
        if a.phone:
            with contextlib.suppress(Exception):
                res["phone_state_after"] = S23.state()
    res["ended"] = time.strftime("%Y-%m-%d %H:%M:%S")
    with open(os.path.join(a.out, "listen_result.json"), "w") as f:
        json.dump(res, f, indent=1, default=str)
    summary = {k: {"peak_db": v.get("peak_db"), **{x: v.get("ears", {}).get(x) for x in ("corr", "level_db", "gap_ms", "longest_gap_ms", "speed", "steady")}}
               for k, v in res.get("captures", {}).items()}
    print(json.dumps({"error": res.get("error"), "phone": res.get("phone"), "captures": summary, "page_stats": res.get("page_stats")}, indent=1, default=str))
    return 0 if "error" not in res else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
