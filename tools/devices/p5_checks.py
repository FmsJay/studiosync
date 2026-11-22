"""rt-p5's phone checks, unattended (rt-t1; docs/rt/rt-p5.md "Checks"). GPL-3.0-or-later.

  python tools/devices/p5_checks.py OUT_DIR [--phone] [--only midi,banner,status,todo,upload]

The "phone" is a browser on the studio's Tailscale opening the desktop's phone link (http://<desktop MagicDNS>:47281/?t=<token>, as the QR
code gives a phone): by default headless Chrome on the laptop (tools/devices/devlib.RemoteChrome), with --phone the S23's Chrome when it's
idle. A second page for the two-phone MIDI check is a second headless Chrome on the laptop (its own profile, so its own page id; also
through the phone link). The bandmate who writes
the @mention and gets the to-do is the laptop's own web UI (127.0.0.1:47281 on the laptop, user James-Laptop), driven in the same laptop
Chrome. Everything made is taken back: the mention and the upload's message deleted by their writers, the to-do deleted, the status cleared,
Live into REAPER turned off (and REAPER's arm/input checked back to what it was). No notes are played: only the page's keep-alive, so no
instrument sounds. Checks 2.., numbers as rt-p5's list:
  midi    1+2: two pages Live into REAPER on two tracks get two virtual-keyboard channels (REAPER's record inputs read back); the second
          page taking the first's track tells the first "another page took this track"; off puts each track back
  banner  5: a bandmate's "@James" in the studio chat shows the banner over the phone link (plain http: no Notification)
  status  8: a status line set on the phone shows on the desktop's and the laptop's pages, then cleared
  todo    10: a to-do for James-Laptop from the phone reaches the laptop's Home "To-dos for you"
  upload  11: a 5 MB file sent to the studio chat from the phone (past the 4 MB spool): the message carries the SHA-256 the phone sent
Writes OUT_DIR/p5_result.json.
"""
import argparse
import base64
import contextlib
import hashlib
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import devlib as D  # noqa: E402

PROBE = os.path.join(D.HERE, "probe.lua")
DESK = os.environ.get("SS_DESK_NAME", "james-main.tail99132c.ts.net")
LAP_USER = os.environ.get("SS_LAP_USER", "James-Laptop")
STUDIO = os.environ.get("SS_STUDIO", r"J:\Portable Workstation\StudioSync Smiley Studios")  # (the test studio's shared folder here)
ME = os.environ.get("SS_DESK_USER", "James")


def probe(pre):
    out = D.reaper_eval(PROBE, pre)
    m = re.search(r"T1PROBE (.*)", out)
    return m.group(1).strip() if m else None


def tracks(guids):
    s = probe("T1P={mode='tracks', guids={%s}}" % ",".join("'%s'" % g for g in guids)) or ""
    out = {}
    for row in filter(None, s.split(";")):
        g, name, inp, arm, mon = row.split("|")
        inp = int(inp)
        out[g] = {"name": name, "recinput": inp, "arm": int(arm), "mon": int(mon),
                  "midi_dev": (inp >> 5) & 127 if inp & 4096 else None, "midi_ch": inp & 31 if inp & 4096 else None}
    return out


def act(page, topic, o):
    return page.evaluate("""([t, o]) => fetch('api/action', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-StudioSync': '1' },
      body: JSON.stringify(Object.assign({ topic: t }, o)) }).then((r) => r.status)""", [topic, o])


def topics(page):
    return page.evaluate("fetch('api/state').then((r) => r.json()).then((s) => s.topics)")


def phone_page(ctx, base):
    p = ctx.new_page()
    p.goto(base, wait_until="domcontentloaded", timeout=30000)  # (the link's token becomes the page's cookie, then the address drops it)
    return p


def check_midi(pA, pB, base, res):
    r = res["midi"] = {}
    for p in (pA, pB):
        p.goto(base.split("?")[0] + "record.html", wait_until="domcontentloaded")
        p.click("button[data-view=ply]")
    opts = D.wait_for(lambda: pA.evaluate("[...document.querySelectorAll('#ktrack option')].filter(o => !o.disabled && o.value).map(o => [o.value, o.textContent])")
                      or None, secs=30, what="tracks in the Play view")
    if len(opts) < 2:
        r["error"] = "fewer than two tracks this page may play: %s" % opts
        return
    (g1, n1), (g2, n2) = opts[0], opts[1]
    r["tracks"] = [n1, n2]
    before = tracks([g1, g2])
    r["before"] = before

    def live(p, g):
        p.select_option("#ktrack", g)
        if not p.is_checked("#klive"):
            p.check("#klive")
    live(pA, g1)
    live(pB, g2)
    kw = lambda p: p.evaluate("document.getElementById('kwhy').textContent")  # noqa: E731
    D.wait_for(lambda: "virtual keyboard channel" in kw(pA) and "virtual keyboard channel" in kw(pB), secs=20, what="both pages playing")
    r["page_A"], r["page_B"] = kw(pA), kw(pB)
    time.sleep(1.5)
    during = tracks([g1, g2])
    r["during"] = during
    chA = re.search(r"channel (\d+)", r["page_A"]).group(1)
    chB = re.search(r"channel (\d+)", r["page_B"]).group(1)
    r["pass_two_channels"] = chA != chB and during[g1]["midi_ch"] == int(chA) and during[g2]["midi_ch"] == int(chB) \
        and during[g1]["arm"] == 1 and during[g2]["arm"] == 1 and during[g1]["midi_dev"] == during[g2]["midi_dev"] == 62
    # the second page picks the first's track
    pB.select_option("#ktrack", g1)
    pB.dispatch_event("#ktrack", "change")
    try:
        D.wait_for(lambda: "another page took this track" in kw(pA) or not pA.is_checked("#klive"), secs=15, what="the first page told")
    except TimeoutError:
        r["take_timeout"] = True
    r["page_A_after_take"], r["page_B_after_take"] = kw(pA), kw(pB)
    r["page_B_live_after_take"] = pB.is_checked("#klive")
    r["phonekeys_after_take"] = topics(pA).get("phonekeys")
    r["page_A_live_after_take"] = pA.is_checked("#klive")
    time.sleep(1.5)
    r["after_take"] = tracks([g1, g2])
    r["pass_take_told"] = "another page took this track" in r["page_A_after_take"] and not r["page_A_live_after_take"]
    for p in (pA, pB):
        if p.is_checked("#klive"):
            p.uncheck("#klive")
    t0 = time.time()
    back = lambda a: all(a[g][k] == before[g][k] for g in (g1, g2) for k in ("recinput", "arm", "mon"))  # noqa: E731
    after = tracks([g1, g2])
    while not back(after) and time.time() - t0 < 60:  # (off should put it back at once; the idle release would within a minute)
        time.sleep(1)
        after = tracks([g1, g2])
    r["after_off"], r["put_back_s"] = after, round(time.time() - t0, 1)
    r["pass_put_back"] = back(after) and r["put_back_s"] <= 5
    r["pass"] = r["pass_two_channels"] and r["pass_take_told"] and r["pass_put_back"]


def check_banner(pA, lap, base, res):
    r = res["banner"] = {}
    pA.goto(base.split("?")[0], wait_until="domcontentloaded")
    D.wait_for(lambda: pA.evaluate("!!document.querySelector('.hbanner')"), secs=20, what="Home")
    time.sleep(3)
    title0 = pA.title()
    text = "@%s t1 mention check %s (automatic test, deleted after)" % (ME, time.strftime("%H:%M:%S"))
    r["post_status"] = act(lap, "chat", {"scope": "band", "text": text})
    D.wait_for(lambda: pA.evaluate("(() => { const b = document.querySelector('.hbanner'); return b && !b.hidden && b.textContent; })()"), secs=40,
               what="the banner")
    r["banner"] = pA.evaluate("document.querySelector('.hbanner').textContent")
    r["title_before"], r["title_after"] = title0, pA.title()
    r["secure_context"] = pA.evaluate("window.isSecureContext")
    r["pass"] = "mentioned you" in r["banner"] and "t1 mention check" in r["banner"]
    men = (topics(pA).get("home") or {}).get("mentions") or []
    mid = next((m["id"] for m in men if "t1 mention check" in (m.get("text") or "")), None)
    r["deleted"] = act(lap, "chat", {"scope": "band", "delete": {"kind": "msgs", "id": mid}}) if mid else "no id"


def check_status(pA, lap, res):
    r = res["status"] = {}
    s = "t1 status check %s" % time.strftime("%H%M%S")
    pA.fill(".hstatusin", s)
    pA.press(".hstatusin", "Enter")
    desk = None  # (the desktop's own view: its /api/state read from here, no browser)

    def seen(page):
        pr = (topics(page) if page else D.state()).get("profiles") or {}
        return json.dumps(pr).find(s) >= 0
    t0 = time.time()
    D.wait_for(lambda: seen(desk), secs=20, what="the status on the desktop")
    r["desktop_s"] = round(time.time() - t0, 1)
    try:
        D.wait_for(lambda: seen(lap), secs=40, what="the status on the laptop")
        r["laptop_s"] = round(time.time() - t0, 1)
    except TimeoutError:
        r["laptop_s"] = None
    pA.fill(".hstatusin", "")
    pA.press(".hstatusin", "Enter")
    D.wait_for(lambda: not seen(desk), secs=20, what="the status cleared")
    r["cleared"] = True
    r["pass"] = r["laptop_s"] is not None and r["laptop_s"] <= 15


def check_todo(pA, lap, res):
    r = res["todo"] = {}
    text = "t1 to-do check %s (automatic test, deleted after)" % time.strftime("%H:%M:%S")
    r["post_status"] = act(pA, "chat", {"scope": "band", "todo": text, "todofor": LAP_USER})
    act(lap, "home", {"want": True})

    def got():
        act(lap, "home", {"want": True})
        return next((d for d in (topics(lap).get("home") or {}).get("todos") or [] if text in (d.get("text") or "")), None)
    t0 = time.time()
    try:
        d = D.wait_for(got, secs=60, every=2, what="the to-do on the laptop's Home")
        r["laptop_s"], r["entry"] = round(time.time() - t0, 1), d
    except TimeoutError:
        d = None
    r["pass"] = d is not None
    mine = topics(pA).get("chat_band") or {}
    tid = (d or {}).get("id") or next((x.get("id") for x in mine.get("todo") or [] if text in (x.get("text") or "")), None)
    r["deleted"] = act(pA, "chat", {"scope": "band", "delete": {"kind": "todo", "id": tid}}) if tid else "no id"
    r["entry_for"] = next((x.get("for") for x in mine.get("todo") or [] if text in (x.get("text") or "")), None)


def check_upload(pA, res, mb=5):
    r = res["upload"] = {}
    line = b"StudioSync rt-t1 upload check, a test file (deleted after).\n"
    data = (line * (mb * 1048576 // len(line) + 1))[: mb * 1048576]
    sha = hashlib.sha256(data).hexdigest()
    name = "t1-upload-%s.txt" % time.strftime("%H%M%S")
    r.update(bytes=len(data), sha_sent=sha, name=name)
    up = pA.evaluate("""async ([b64, name]) => {
      const bin = atob(b64); const u = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
      const t0 = performance.now();
      const r = await fetch('api/upload', { method: 'POST', headers: { 'X-StudioSync': '1', 'Content-Type': 'application/octet-stream' }, body: u });
      const j = await r.json().catch(() => ({}));
      return { status: r.status, id: j.id, ok: j.ok, ms: Math.round(performance.now() - t0) };
    }""", [base64.b64encode(data).decode(), name])
    r["upload"] = up
    if not up.get("ok"):
        r["pass"] = False
        return
    r["send_status"] = act(pA, "chat", {"scope": "band", "file": {"id": up["id"], "name": name, "size": len(data)}})

    def msg():
        act(pA, "chat", {"want": "band", "scope": "band"})
        c = topics(pA).get("chat_band") or {}
        return next((m for m in c.get("msgs") or [] if (m.get("file") or {}).get("name") == name), None)
    try:
        m = D.wait_for(msg, secs=40, every=2, what="the file's message")
    except TimeoutError:
        m = None
    r["message_file"] = (m or {}).get("file")
    # (the pages' model of a file carries no hash: the shared copy, <studio>/_band/chat/files/<stamp>~<name>, is hashed here instead)
    fdir = os.path.join(STUDIO, "_band", "chat", "files")
    copy = next((os.path.join(fdir, f) for f in (os.listdir(fdir) if os.path.isdir(fdir) else []) if f.endswith("~" + name)), None)
    r["shared_copy_sha"] = hashlib.sha256(open(copy, "rb").read()).hexdigest() if copy else None
    r["pass"] = bool(m) and r["shared_copy_sha"] == sha
    if m and m.get("id"):
        r["deleted"] = act(pA, "chat", {"scope": "band", "delete": {"kind": "msgs", "id": m["id"]}})
    if copy:  # (deleting the message leaves its file in the shared folder: this test's own copy is removed)
        time.sleep(2)
        with contextlib.suppress(OSError):
            os.remove(copy)
            r["shared_copy_removed"] = True


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--only", default="midi,banner,status,todo,upload")
    ap.add_argument("--phone", action="store_true", help="the S23's Chrome as the phone, when it's idle (tools/devices/s23.py)")
    a = ap.parse_args(argv)
    from playwright.sync_api import sync_playwright
    os.makedirs(a.out, exist_ok=True)
    only = set(a.only.split(","))
    res = {"started": time.strftime("%Y-%m-%d %H:%M:%S"), "phone": "laptop headless Chrome over the phone link"}
    tok = probe("T1P={mode='token'}")
    if not tok:
        print("no token")
        return 1
    base = "http://%s:47281/?t=%s" % (DESK, tok)
    with sync_playwright() as pw, contextlib.ExitStack() as st:
        _b, lctx = st.enter_context(D.RemoteChrome(pw, 9363))
        pA = None
        if a.phone:
            import s23 as S23
            why = "offline" if not S23.connect() else S23.busy()
            if why:
                res["phone"] = "laptop headless Chrome (the S23 skipped: %s)" % why
            else:
                res["phone"] = "the S23's Chrome over the phone link"
                # (no Web MIDI on James's phone for the test: Chrome would ask him for the MIDI permission on its screen)
                pA = st.enter_context(S23.tab(pw, base, "try { delete Navigator.prototype.requestMIDIAccess; } catch (e) {}"))
        pA = pA or phone_page(lctx, base)
        lap = lctx.new_page()
        lap.goto("http://127.0.0.1:47281/", wait_until="domcontentloaded")  # (the laptop's own web UI: James-Laptop)
        # (the second "phone" for the MIDI check: another headless Chrome on the laptop with its own profile, so its own page id)
        _b2, dctx = st.enter_context(D.RemoteChrome(pw, 9364))
        for name, fn in (("midi", lambda: check_midi(pA, phone_page(dctx, base), base, res)), ("banner", lambda: check_banner(pA, lap, base, res)),
                         ("status", lambda: check_status(pA, lap, res)), ("todo", lambda: check_todo(pA, lap, res)),
                         ("upload", lambda: check_upload(pA, res))):
            if name not in only:
                continue
            try:
                fn()
            except Exception as e:  # noqa: BLE001
                res.setdefault(name, {})["error"] = "%s: %s" % (type(e).__name__, str(e)[:500])
                if name == "midi":  # (whatever happened, Live into REAPER off on every page)
                    for p in lctx.pages + dctx.pages:
                        with contextlib.suppress(Exception):
                            if p.query_selector("#klive") and p.is_checked("#klive"):
                                p.uncheck("#klive")
    res["ended"] = time.strftime("%Y-%m-%d %H:%M:%S")
    with open(os.path.join(a.out, "p5_result.json"), "w") as f:
        json.dump(res, f, indent=1, default=str)
    print(json.dumps({k: (v.get("pass"), v.get("error")) if isinstance(v, dict) else v for k, v in res.items()}, indent=1, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
