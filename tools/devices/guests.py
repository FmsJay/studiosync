"""Browser guests and a listening link, unattended (rt-t1; docs/rt/rt-p11.md check 7, docs/rt/rt-browserjoin.md). GPL-3.0-or-later.

  python tools/devices/guests.py OUT_DIR [--soak-min 15] [--extra 2] [--gain 0.01] [--cap-s 25]

On the computer whose web UI makes the links (127.0.0.1:47281, Live sync on with a song in front), with Python Playwright and Chrome:
  1. Guest links for "T1 Guest A" and "T1 Guest B" (guestweb make), each guest's volume set to --gain BEFORE they join (so what they send
     is heard on this computer's output at that level: 0.01 = -40 dB), and a tailnet listening link (audience make).
  2. Headless Chrome per guest with Chrome's FAKE microphone only (--use-fake-device-for-media-stream, --use-file-for-fake-audio-capture):
     A reads the ears pattern (tools/ears) looped with 2.25 s of silence, B a steady 1500 Hz tone; both --mute-audio (nothing plays out
     loud here). A third Chrome opens the listening link and presses Listen live.
  3. webtap.js captures what each page plays (in the page, before the device) for --cap-s seconds: A should hear B's tone and not its own
     pattern, B A's pattern and not its own tone, the listener both. Compared with tools/ears/ears.py wav (scaled by 1/gain).
  4. --extra N more guests join for a moment (4 live at most, rt-p11 5): each live on the host's row.
  5. The soak: A and B stay live --soak-min minutes; every 10 s the host's row (under, drops) and each page's worklet/listener stats are
     logged (soak.jsonl). Pass: no new under/drops after the first 30 s (rt-p11 check 7), and the listener's under stays put (check 8).
  6. Always: the guests leave, are ended (kick), the listening link revoked, the browsers closed.
Results: OUT_DIR/result.json and the WAVs. Exit 1 when a check fails.
"""
import argparse
import contextlib
import json
import os
import subprocess
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import devlib as D  # noqa: E402

TONE_B = 1500.0


def join_guest(ctx, link, log):
    p = ctx.new_page()
    p.on("console", lambda m: log.append(("console", m.type, m.text[:300])) if m.type in ("error", "warning") else None)
    p.goto(link, wait_until="domcontentloaded", timeout=30000)
    D.wait_for(lambda: p.evaluate("document.getElementById('who').textContent") not in ("", "Guest"), secs=20, what="the guest topic")
    p.click("#join")
    D.wait_for(lambda: p.evaluate("document.getElementById('conn').textContent") == "live", secs=20, what="the guest socket live")
    return p


def open_listener(ctx, url, log):
    p = ctx.new_page()
    p.on("console", lambda m: log.append(("console", m.type, m.text[:300])) if m.type in ("error", "warning") else None)
    p.goto(url, wait_until="domcontentloaded", timeout=30000)
    D.wait_for(lambda: p.evaluate("!document.getElementById('go').disabled"), secs=20, what="Listen live enabled")
    p.click("#go")
    D.wait_for(lambda: p.evaluate("window.ssListen && window.ssListen.stats().on"), secs=10, what="listening on")
    return p


def capture(pages, secs, out_dir, tag):
    for p in pages.values():
        p.evaluate("window.__ssTap.start()")
    time.sleep(secs)
    infos = {k: p.evaluate("window.__ssTap.stop()") for k, p in pages.items()}
    files = {}
    for k, p in pages.items():
        x, info = D.tap_fetch(p, infos[k])
        f = os.path.join(out_dir, "%s_%s.wav" % (tag, k))
        D.write_wav(f, x)
        files[k] = {"wav": f, "frames": info["frames"], "rate": info["rate"], "missed_blocks": info["missed"],
                    "peak_db": round(D.db(np.max(np.abs(x))) if len(x) else -240, 1)}
    return files


def analyse(files, pattern_dir, gain):
    ref = os.path.join(pattern_dir, "pattern.wav")
    out = {}
    from scipy import signal
    import ears  # (tools/ears, on the path via devlib's REPO)
    for k, f in files.items():
        sr, x = D.read_mono(f["wav"])
        r = dict(f)
        r["tone_b_db"] = round(D.tone_db(x, sr, TONE_B, bw=30), 1)  # B's tone at 0.25 x gain: RMS about -55 dBFS at gain 0.01
        r["tone_b_hz"] = [round(v, 2) for v in (ears.tone_hz(x[i:i + 4 * sr], sr, TONE_B * 0.97, TONE_B * 1.03) for i in range(0, len(x) - 4 * sr, 4 * sr))
                          if v and r["tone_b_db"] > -80]
        wav = f["wav"]
        if r["tone_b_db"] > -80:  # (B's tone notched out before comparing with the pattern: the listener hears both)
            bb, aa = signal.iirnotch(TONE_B, 30, sr)
            wav = f["wav"][:-4] + "_notched.wav"
            D.write_wav(wav, signal.filtfilt(bb, aa, x).astype(np.float32), sr)
        r["pattern"] = D.ears_wav(ref, wav, pattern_dir, gain=gain)
        out[k] = r
    exp_tone = D.db(0.25 * gain / np.sqrt(2))
    a, b, l = out.get("A"), out.get("B"), out.get("L")
    # heard: the pattern's level and spectrum where it should be (ears' corr alone fails when a drift control plays it 0.5 % fast: the
    # alignment smears over the pattern's 9.75 s), not silent: its level within 3 dB, spectra within ears' 3 dB
    hears = lambda r: bool(r) and r["pattern"].get("level_db") is not None and abs(r["pattern"]["level_db"]) <= 3 \
        and all(v <= 3 for v in (r["pattern"].get("spectral_db") or {"x": 99}).values())  # noqa: E731
    checks = {
        "A_hears_B": bool(a and a["tone_b_db"] > exp_tone - 6),
        "A_not_itself": bool(a and not hears(a)),
        "B_hears_A": bool(hears(b)),
        "B_not_itself": bool(b and b["tone_b_db"] < exp_tone - 30),
        "listener_hears_A": bool(hears(l)),
        "listener_hears_B": bool(l and l["tone_b_db"] > exp_tone - 6),
    }
    return out, checks, round(exp_tone, 1)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--soak-min", type=float, default=15.0)
    ap.add_argument("--extra", type=int, default=2)
    ap.add_argument("--gain", type=float, default=0.01)
    ap.add_argument("--cap-s", type=float, default=25.0)
    ap.add_argument("--laptop", action="store_true", help="guests A and B in headless Chrome on the laptop (ssh), not here")
    a = ap.parse_args(argv)
    from playwright.sync_api import sync_playwright
    os.makedirs(a.out, exist_ok=True)
    pattern_dir = os.path.join(a.out, "pattern")
    subprocess.run([sys.executable, D.EARS, "pattern", pattern_dir], check=True, capture_output=True)
    wav_a, wav_b = os.path.join(a.out, "fake_mic_A.wav"), os.path.join(a.out, "fake_mic_B.wav")
    D.gen_pattern_loop(wav_a, pattern_dir)
    D.gen_tone(wav_b, TONE_B, secs=60, peak=0.25)
    res = {"gain": a.gain, "started": time.strftime("%Y-%m-%d %H:%M:%S"), "log": []}
    log = res["log"]
    gids, lid, browsers = [], None, []
    res["cpu_load_start"] = D.cpu_load()
    try:
        with sync_playwright() as pw, contextlib.ExitStack() as stack:
            try:
                gA, linkA = D.make_guest("T1 Guest A", minutes=60, gain=a.gain)
                gids.append(gA)
                gB, linkB = D.make_guest("T1 Guest B", minutes=60, gain=a.gain)
                gids.append(gB)
                lid, lurl = D.make_listen_link(1)
                if a.laptop:  # (the guests on the laptop, headless, as guests from another computer; the listener here)
                    cA = stack.enter_context(D.RemoteChrome(pw, 9361, wav_a))[1]
                    cB = stack.enter_context(D.RemoteChrome(pw, 9362, wav_b))[1]
                else:
                    bA, cA = D.launch(pw, wav_a)
                    bB, cB = D.launch(pw, wav_b)
                    browsers += [bA, bB]
                if a.laptop:
                    cL = stack.enter_context(D.RemoteChrome(pw, 9365))[1]
                else:
                    bL, cL = D.launch(pw, None)
                    browsers.append(bL)
                pA = join_guest(cA, linkA, log)
                pB = join_guest(cB, linkB, log)
                pL = open_listener(cL, lurl, log)
                time.sleep(6)
                pages = {"A": pA, "B": pB, "L": pL}
                files = capture(pages, a.cap_s, a.out, "c1")
                res["capture"], res["checks"], res["expected_tone_b_db"] = analyse(files, pattern_dir, a.gain)
                res["rows_after_join"] = [D.guest_row(g) for g in gids]
                # a third and fourth guest join for a moment (silent fake microphones: a 0-level tone file)
                if a.extra:
                    wav_s = os.path.join(a.out, "fake_mic_silent.wav")
                    D.gen_tone(wav_s, 1000.0, secs=5, peak=0.0)
                    xs = []
                    for i in range(a.extra):
                        g, link = D.make_guest("T1 Guest %s" % "CDEF"[i], minutes=10, gain=a.gain)
                        gids.append(g)
                        if a.laptop:
                            b, c = None, stack.enter_context(D.RemoteChrome(pw, 9366 + i, wav_s))[1]
                        else:
                            b, c = D.launch(pw, wav_s)
                            browsers.append(b)
                        xs.append((g, join_guest(c, link, log), b))
                    time.sleep(4)
                    rows = [D.guest_row(g) for g in gids]
                    res["extra"] = {"live": sum(1 for r in rows if r and r.get("live")), "rows": rows}
                    res["checks"]["four_live"] = res["extra"]["live"] == 2 + a.extra
                    for g, p, b in xs:
                        try:
                            p.click("#leave")
                        except Exception as e:  # noqa: BLE001
                            log.append(("leave", g, str(e)[:200]))
                        D.kick_guest(g)
                        if b:
                            b.close()
                            browsers.remove(b)
                # the soak
                soak = []
                t0 = time.time()
                with open(os.path.join(a.out, "soak.jsonl"), "w") as f:
                    while time.time() - t0 < a.soak_min * 60:
                        row = {"t": round(time.time() - t0, 1)}
                        for k, g in (("A", gA), ("B", gB)):
                            r = D.guest_row(g) or {}
                            row[k] = {"live": r.get("live"), "under": r.get("under"), "drops": r.get("drops"), "peak": r.get("peak")}
                        for k, p in (("A", pA), ("B", pB)):
                            row[k]["page"] = p.evaluate("window.__ssTap.stats().worklet")
                            row[k]["conn"] = p.evaluate("document.getElementById('conn').textContent")
                        row["L"] = pL.evaluate("window.ssListen.stats()")
                        aud = D.state().get("audience", {})
                        row["listeners"] = aud.get("listeners")
                        f.write(json.dumps(row) + "\n")
                        f.flush()
                        soak.append(row)
                        time.sleep(10)
                files2 = capture(pages, min(a.cap_s, 15), a.out, "c2")
                res["capture_end"], res["checks_end"], _ = analyse(files2, pattern_dir, a.gain)
                res["soak"] = summarise_soak(soak)
                res["checks"].update(res["soak"]["pass"])
                for p in (pA, pB):
                    try:
                        p.click("#leave")
                    except Exception as e:  # noqa: BLE001
                        log.append(("leave", str(e)[:200]))
            finally:
                for g in gids:
                    try:
                        D.kick_guest(g)
                    except Exception as e:  # noqa: BLE001
                        log.append(("kick", g, str(e)[:200]))
                if lid:
                    try:
                        D.revoke_listen(lid)
                    except Exception as e:  # noqa: BLE001
                        log.append(("revoke", str(e)[:200]))
                for b in browsers:
                    try:
                        b.close()
                    except Exception:  # noqa: BLE001
                        pass
                res["cpu_load_end"] = D.cpu_load()
    except Exception as e:  # noqa: BLE001
        res["error"] = "%s: %s" % (type(e).__name__, str(e)[:600])
    res["ended"] = time.strftime("%Y-%m-%d %H:%M:%S")
    with open(os.path.join(a.out, "result.json"), "w") as f:
        json.dump(res, f, indent=1, default=str)
    ok = "error" not in res and all(res.get("checks", {}).values())
    print(json.dumps({"ok": ok, "checks": res.get("checks"), "error": res.get("error"), "soak": res.get("soak", {}).get("summary")}, indent=1, default=str))
    return 0 if ok else 1


def summarise_soak(soak):
    """New under/drops on the host's rows and in each page after the first 30 s; the listener's under and gaps."""
    after = [r for r in soak if r["t"] >= 30]
    out, ok = {}, {}
    if not after:
        return {"summary": "no soak", "pass": {}}
    first, last = after[0], soak[-1]
    for k in ("A", "B"):
        d = {m: (last[k].get(m) or 0) - (first[k].get(m) or 0) for m in ("under", "drops")}
        pg0, pg1 = first[k].get("page") or {}, last[k].get("page") or {}
        d["page_under"] = (pg1.get("under") or 0) - (pg0.get("under") or 0)
        d["page_drops"] = (pg1.get("drops") or 0) - (pg0.get("drops") or 0)
        d["live_all"] = all(r[k].get("live") for r in after)
        out[k] = d
        ok["soak_%s_host_no_new_drops" % k] = d["under"] == 0 and d["drops"] == 0
        ok["soak_%s_page_no_new_drops" % k] = d["page_under"] == 0 and d["page_drops"] == 0
        ok["soak_%s_live" % k] = d["live_all"]
    out["L"] = {"under": last["L"].get("under", 0) - first["L"].get("under", 0), "gaps": last["L"].get("gaps", 0) - first["L"].get("gaps", 0),
                "ahead_s": [round(min(r["L"].get("ahead", 0) for r in after), 3), round(max(r["L"].get("ahead", 0) for r in after), 3)]}
    ok["soak_listener_no_new_under"] = out["L"]["under"] == 0
    return {"summary": out, "minutes": round(soak[-1]["t"] / 60, 1), "pass": ok}


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
