"""rt-sync2f's Live checks (docs/rt/rt-sync2f.md "Live checks" f1-f8): times in beats, on the desktop (d) and a bandmate (the laptop, else LinuxBox).
"x crosses" pauses LinuxBox's Syncthing and cuts its direct link inside the VM (sets/_lv.py), so its edit meets the desktop's tempo map only
after it. Every scenario sets the project timebase to beats (position, length, rate) and puts it and the tempo (one marker, 120 bpm) back."""
import subprocess, time
from live import scenario, Fail, lua_str, NAMES
from sets._lv import B, USER, SONG, setup, T, add, sleep, x_syncthing, x_cut, peer_ips, _LAB

SETTLE = 17  # presence.HOLD is 15 s: a bandmate's edit to what someone changed in the last 15 s is put back by design
ITEM_POS, ITEM_LEN, FADE = 10.0, 6.0, 0.01  # Gtr's item: QN 20, 12 QN long at 120 bpm
DRUMS = [(0, 0.5), (4, 0.7), (8, 0.9), (12, 0.6)]  # Drums' volume points (s, raw value): QN 0, 8, 16, 24 at 120 bpm


# ---- small steps ----

def tmap(ctx, w):
    return ctx.do(w, "return LV.out(LV.tempo_map(P))")


def item(ctx, w, short="Gtr", chunk=False):
    return ctx.do(w, f"return LV.out(LV.item_times(P, {lua_str(T(ctx, short))}, 0, {'true' if chunk else 'false'}))")


def env(ctx, w, short="Drums"):
    r = ctx.do(w, f"return LV.out(LV.env_points(P, {lua_str(T(ctx, short))}))")
    return r if isinstance(r, list) else []


def set_tempo(ctx, w, *edits):
    """Tempo markers in one "Edit tempo map": (idx, time, bpm, linear), idx -1 a new marker."""
    lua = "{" + ",".join("{%d,%r,%r,%s}" % (i, float(t), float(b), "true" if lin else "false") for i, t, b, lin in edits) + "}"
    ctx.do(w, f"LV.set_tempo(P, {lua}); return LV.out(true)")


def item_set(ctx, w, props=None, takeprops=None, short="Gtr"):
    tbl = lambda d: "{" + ",".join(f"{k}={float(v)!r}" for k, v in (d or {}).items()) + "}"
    ctx.do(w, f"LV.item_set(P, {lua_str(T(ctx, short))}, {tbl(props)}, {tbl(takeprops)}); return LV.out(true)")


def events(ctx, since):
    """{w: events w's own computer wrote since `since` (an os.time)}: each read where it was written, so Syncthing's lag doesn't hide one."""
    return {w: ctx.do(w, f"return LV.out(LV.events_since(SONG, {lua_str(USER[w])}, {since}))") or [] for w in ctx.on}


def mark_time():
    """A start for events(): past the second the last edit was in (event files are named to the second, by the writer's clock)."""
    sleep(2)
    return int(time.time()) - 1


def diff(a, b, tol, path=""):
    """Where two read-backs differ: numbers by more than tol, anything else not equal. -> ['path a vs b', ...]."""
    if isinstance(a, bool) or isinstance(b, bool) or not isinstance(a, (int, float, dict, list)):
        return [] if a == b else [f"{path} {a} vs {b}"]
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return [] if abs(a - b) <= tol else [f"{path} {a!r} vs {b!r}"]
    if isinstance(a, dict) and isinstance(b, dict):
        return [d for k in sorted(set(a) | set(b)) if k != "chunk" for d in diff(a.get(k), b.get(k), tol, f"{path}.{k}")]
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            return [f"{path} {len(a)} vs {len(b)} entries"]
        return [d for i, (x, y) in enumerate(zip(a, b)) for d in diff(x, y, tol, f"{path}[{i}]")]
    return [f"{path} {a} vs {b}"]


def agree(ctx, what, read, tol=1e-6, timeout=120):
    """Wait until read(w) is the same (to tol) on every computer of the run. -> {w: value}. Fails naming the computers that differ."""
    last = {}
    def same():
        nonlocal last
        try:
            last = {w: read(w) for w in ctx.on}
        except RuntimeError as e:  # (not there yet on one: "no item on ...")
            last = {w: str(e)[:200] for w in ctx.on}
            return None
        first = last[ctx.on[0]]
        return last if all(not diff(first, last[w], tol) for w in ctx.on[1:]) else None
    try:
        return ctx.wait(what, same, timeout=timeout, every=3)
    except Fail:
        d0 = ctx.on[0]
        raise Fail(f"{what}: " + "; ".join(f"{NAMES[w]} differs from {NAMES[d0]}: {', '.join(diff(last[d0], last[w], tol)[:4])}"
                                           for w in ctx.on[1:] if diff(last[d0], last[w], tol)))


def no_obj(ctx, evs, who=None):
    """The obj events (items, automation, sends, tracks) in evs: [(computer, event)]."""
    return [(NAMES[w], e.get("obj"), e.get("name")) for w, es in evs.items() if who in (None, w) for e in es if e.get("obj")]


# ---- each scenario's start and end ----

ONE_120 = [{"time": 0, "bpm": 120, "num": 4, "denom": 4, "linear": False}]


def force_120(ctx, timeout=90):
    """Every computer of the run on one marker of 120 bpm. When the desktop has it already but another computer doesn't (0.63.1 after a
    restart: the desktop's older file had 120, the room's newest timeline change, the desktop's own 100 bpm marker, had reached LinuxBox
    and not the desktop again), setting 120 on the desktop changes nothing there and sends nothing: so it goes through 121 first."""
    maps = {w: tmap(ctx, w) for w in ctx.on}
    if not any(diff(m, ONE_120, 1e-9) for m in maps.values()):
        return
    if not diff(maps["d"], ONE_120, 1e-9):
        ctx.note("tempo: the desktop on 120 already but " + ", ".join(NAMES[w] for w, m in maps.items() if diff(m, ONE_120, 1e-9))
                 + " not: through 121 first")
        ctx.do("d", "LV.tempo_reset(P, 121); return LV.out(true)")
        agree(ctx, "the tempo at 121 everywhere", lambda w: [(m["time"], m["bpm"], m["linear"]) for m in tmap(ctx, w)], 1e-6, timeout)
    ctx.do("d", "LV.tempo_reset(P, 120); return LV.out(true)")
    agree(ctx, "the tempo back to 120 everywhere", lambda w: [(m["time"], m["bpm"], m["linear"]) for m in tmap(ctx, w)], 1e-6, timeout)


def tempo_back(ctx):
    """A clean-up: the tempo back to one marker of 120 bpm on the desktop, waited for everywhere (the crossing is undone before this runs)."""
    def go():
        try:
            force_120(ctx)
        except Fail as e:
            ctx.note(f"cleanup: {e}")
    return go


def prep(ctx, drums=True):
    """The checks' song state (docs/rt/rt-sync2f.md "Live checks"): project timebase beats (position, length, rate) on every computer, the
    tempo one marker of 120 bpm, Gtr with one audio item (a generated WAV) at 10 s, 6 s long, fades 0.01 s, rate 1, and Drums with volume
    automation at 0, 4, 8, 12 s; all of it on every computer, then past presence.HOLD."""
    tb = {w: ctx.do(w, 'local was = reaper.GetSetProjectInfo(P, "PROJECT_TIMEBASE", 0, false)\n'
                       'reaper.GetSetProjectInfo(P, "PROJECT_TIMEBASE", 1, true)\nreturn LV.out(was)') for w in ctx.on}
    def tb_back():
        for w, v in tb.items():
            if v != 1:
                ctx.do(w, f'reaper.GetSetProjectInfo(P, "PROJECT_TIMEBASE", {v}, true); return LV.out(true)')
    ctx.cleanups.append(tb_back)
    ctx.cleanups.append(tempo_back(ctx))
    force_120(ctx)
    add(ctx, "d", "Gtr", "Drums")
    g = lua_str(T(ctx, "Gtr"))
    ctx.do("d", f"LV.record_take(P, {g}, {ITEM_POS}, {ITEM_LEN}, 'f') return LV.out(true)")
    item_set(ctx, "d", {"D_FADEINLEN": FADE, "D_FADEOUTLEN": FADE})
    if drums:
        pts = "{" + ",".join("{%r,%r}" % (float(t), v) for t, v in DRUMS) + "}"
        ctx.do("d", f"LV.env_add(P, {lua_str(T(ctx, 'Drums'))}, {pts}); return LV.out(true)")
    ctx.quiet(timeout=150)
    agree(ctx, "the tempo, Gtr's item and Drums' automation on every computer",
          lambda w: {"map": [(m["time"], m["bpm"]) for m in tmap(ctx, w)], "f": round(item(ctx, w)["f"], 6),
                     "env": [(round(p["t"], 6), round(p["v"], 4)) for p in env(ctx, w)]}, 1e-6, 150)
    sleep(SETTLE)


def cross(ctx):
    """x crosses: LinuxBox's Syncthing paused and its direct link to the desktop (and the laptop when it's in the run) cut, inside the VM.
    -> undo() (also registered as a clean-up). Only the desktop's address when the laptop isn't in the run: asking a powered-off laptop
    for its address would hang."""
    ctx.check(x_syncthing(True), "couldn't pause LinuxBox's Syncthing")
    def undo():
        x_cut(False)
        x_syncthing(False)
    ctx.cleanups.append(undo)
    if "l" in ctx.on:
        ips = peer_ips()
    else:
        ips = [ip for ip in subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True).stdout.split()[:1] if ip.startswith("100.")]
    ctx.check(ips, "no Tailscale address to cut")
    for ip in ips:
        subprocess.run(["bash", str(_LAB), "net", "x", "block", ip], capture_output=True, text=True, timeout=60)
    return undo


def still_120(ctx):
    """LinuxBox hasn't got the desktop's map through the cut (the crossing's premise)."""
    sleep(5)
    m = tmap(ctx, "x")
    ctx.check(len(m) == 1 and abs(m[0]["bpm"] - 120) < 1e-9, f"harness: the desktop's tempo map reached LinuxBox through the cut: {m}")


# ---- f4 and f5 first (rt-sync2f Recommendation 2) ----

@scenario("f4 auto-stretch item at a tempo change", "sync2f 4", needs=("d", "x"), wants=("l",))
def autostretch(ctx):
    """Is an auto-stretch item's rate scaled with its length at a tempo change (then nothing goes out), or is it re-sent after every one?"""
    prep(ctx, drums=False)
    item_set(ctx, "d", {"C_BEATATTACHMODE": 1, "C_AUTOSTRETCH": 1})
    agree(ctx, "Gtr's item on auto-stretch everywhere", lambda w: {k: item(ctx, w)[k] for k in ("beat", "auto")}, 0, 90)
    ctx.quiet()
    sleep(SETTLE)
    before = item(ctx, "d", chunk=True)
    fails = []
    # two tempo changes inside the item (10 s to 16 s): a new 90 bpm marker at 12 s, then that marker to 80 bpm
    for step, edit in (("90 bpm at 12 s", (-1, 12, 90, False)), ("that marker to 80 bpm", (1, 12, 80, False))):
        t0 = mark_time()
        was = item(ctx, "d", chunk=True)
        set_tempo(ctx, "d", edit)
        agree(ctx, f"the tempo map after {step}", lambda w: [(m["time"], m["bpm"]) for m in tmap(ctx, w)], 1e-6, 90)
        sleep(10)  # (a re-send of the item would go on Live sync's next looks)
        evs = events(ctx, t0)
        now = item(ctx, "d", chunk=True)
        ctx.note(f"{step}: on the desktop rate x length {was['r'] * was['l']:.9f} -> {now['r'] * now['l']:.9f} (rate {was['r']:.9f} -> "
                 f"{now['r']:.9f}, length {was['l']:.6f} -> {now['l']:.6f} s, QN {now['qp']:.6f} + {now['qe'] - now['qp']:.6f}); "
                 f"{len(now['sm'])} stretch marker(s)")
        d_ev = evs["d"]
        if [e.get("type") for e in d_ev] != ["timeline"]:
            fails.append(f"{step}: the desktop sent {[(e.get('type'), e.get('obj'), e.get('name')) for e in d_ev]}, not one timeline event")
        objs = no_obj(ctx, evs)
        if objs:
            changed = sorted(set(was["chunk"].splitlines()) ^ set(now["chunk"].splitlines()))
            ctx.note(f"{step}: REAPER rewrote the item's chunk for the tempo (a known limit); lines before/after that differ: " + " | ".join(changed[:12]))
            fails.append(f"{step}: obj events went: {objs}")
        try:
            agree(ctx, f"Gtr's item after {step} (p, l, r, stretch markers)",
                  lambda w: {k: v for k, v in item(ctx, w).items() if k in ("p", "l", "r", "sm")}, 1e-6, 60)
        except Fail as e:
            fails.append(str(e))
    ctx.note(f"rate x length from before the first change to after the second: {before['r'] * before['l']:.9f} -> "
             f"{item(ctx, 'd')['r'] * item(ctx, 'd')['l']:.9f} (equal: REAPER scales the rate with the length; StudioSync's beats form holds)")
    ctx.check(not fails, " / ".join(fails))


@scenario("f5 stretch markers across a tempo change", "sync2f 5", needs=("d", "x"), wants=("l",))
def stretch_markers(ctx):
    prep(ctx, drums=False)
    ctx.do("d", f"LV.stretch_add(P, {lua_str(T(ctx, 'Gtr'))}, {{{{1.0}}, {{3.0, 2.5}}}}); return LV.out(true)")
    sm = agree(ctx, "the two stretch markers everywhere", lambda w: item(ctx, w)["sm"], 1e-9, 120)
    ctx.check(len(sm["d"]) == 2, f"the desktop has {len(sm['d'])} stretch markers, not 2: {sm['d']}")
    ctx.note("stretch markers (pos, srcpos): " + ", ".join(f"{m['pos']:.6f}/{m['srcpos']:.6f}" for m in sm["d"]))
    sleep(SETTLE)
    t0 = mark_time()
    undo = cross(ctx)
    set_tempo(ctx, "d", (-1, 4, 100, False))
    still_120(ctx)
    item_set(ctx, "x", {"D_POSITION": ITEM_POS + 1})  # 1 s later, on 120 bpm: QN 22
    sleep(5)
    undo()
    ctx.quiet(timeout=180)
    agree(ctx, "Gtr's item and stretch markers after the crossing", lambda w: {k: v for k, v in item(ctx, w).items() if k in ("p", "l", "sm")}, 1e-6, 120)
    d = item(ctx, "d")
    ctx.note(f"after: QN {d['qp']:.6f} + {d['qe'] - d['qp']:.6f}; stretch markers " + ", ".join(f"{m['pos']:.6f}/{m['srcpos']:.6f}" for m in d["sm"]))
    ctx.check(abs(d["qp"] - 22) < 1e-5, f"Gtr's item isn't on QN 22 (LinuxBox's move, made on 120 bpm): QN {d['qp']:.6f}")
    ctx.check(len(d["sm"]) == 2, f"{len(d['sm'])} stretch markers after the crossing, not 2")
    if abs(d["sm"][1]["pos"] - sm["d"][1]["pos"]) > 1e-6:
        ctx.note(f"the stretch markers moved in item time ({sm['d'][1]['pos']:.6f} -> {d['sm'][1]['pos']:.6f}, ratio "
                 f"{d['sm'][1]['pos'] / sm['d'][1]['pos']:.6f}): they're in item time (seconds), a known limit")
    objs = no_obj(ctx, events(ctx, t0), "d")
    ctx.check(not objs, f"the desktop sent obj events after its tempo change: {objs}")


# ---- f1, f2, f3, f7 ----

@scenario("f1 a tempo change sends only the timeline", "sync2f 1", needs=("d",), wants=("l", "x"))
def only_timeline(ctx):
    prep(ctx)
    claims0 = ctx.do("d", f"return LV.out(LV.claims_text(SONG, {lua_str(USER['d'])}))")
    marks = ctx.log_marks()
    t0 = mark_time()
    set_tempo(ctx, "d", (-1, 4, 100, False))
    agree(ctx, "the 100 bpm marker everywhere", lambda w: [(m["time"], m["bpm"]) for m in tmap(ctx, w)], 1e-6, 90)
    ctx.quiet()
    sleep(10)
    evs = events(ctx, t0)
    ctx.note("events since: " + "; ".join(f"{NAMES[w]}: {[(e.get('type'), e.get('obj'), e.get('name')) for e in es]}" for w, es in evs.items()))
    ctx.check([e.get("type") for e in evs["d"]] == ["timeline"], f"the desktop sent {[(e.get('type'), e.get('obj')) for e in evs['d']]}, not one timeline event")
    objs = no_obj(ctx, evs)
    ctx.check(not objs, f"obj events went after the tempo change: {objs}")
    claims1 = ctx.do("d", f"return LV.out(LV.claims_text(SONG, {lua_str(USER['d'])}))")
    ctx.check(claims1 == claims0, f"the desktop's claims file changed: {claims0[:200]!r} -> {claims1[:200]!r}")
    bad = {NAMES[w]: ctx.log_since(w, marks, "came out different") for w in ctx.on}
    bad = {k: v for k, v in bad.items() if v}
    ctx.check(not bad, f"'came out different' in the log: {bad}")
    d = item(ctx, "d")
    ctx.check(abs(d["qp"] - 20) < 1e-5 and abs(d["qe"] - d["qp"] - 12) < 1e-5, f"REAPER didn't keep Gtr's item on its beats: QN {d['qp']} + {d['qe'] - d['qp']}")


@scenario("f2 cross-map landing: fades, snap offset, rate", "sync2f 2", needs=("d", "x"), wants=("l",))
def cross_map(ctx):
    prep(ctx, drums=False)
    undo = cross(ctx)
    set_tempo(ctx, "d", (-1, 4, 100, False))
    still_120(ctx)
    item_set(ctx, "x", {"D_LENGTH": 7.5, "D_FADEINLEN": 0.75, "D_SNAPOFFSET": 1.25}, {"D_PLAYRATE": 0.8})
    sleep(5)
    undo()
    ctx.quiet(timeout=180)
    agree(ctx, "Gtr's item after the crossing (p, l, f, s, r)", lambda w: {k: v for k, v in item(ctx, w).items() if k in ("p", "l", "f", "s", "r")}, 1e-6, 120)
    bad = []
    for w in ctx.on:
        i = item(ctx, w)
        p, l = i["qp"], i["qe"] - i["qp"]
        why = [s for s, ok in (
            (f"QN(p) {p:.7f} not 20", abs(p - 20) <= 1e-5), (f"length {l:.7f} QN not 15", abs(l - 15) <= 1e-5),
            (f"fade / length {i['f'] / i['l']:.9f} not 0.1", abs(i["f"] / i["l"] - 0.1) <= 1e-7),
            (f"snap / length {i['s'] / i['l']:.9f} not 1/6", abs(i["s"] / i["l"] - 1 / 6) <= 1e-7),
            (f"rate x length {i['r'] * i['l']:.9f} not 6", abs(i["r"] * i["l"] - 6) <= 1e-6)) if not ok]
        if why:
            bad.append(f"{NAMES[w]}{' (its edit met the map after it)' if w == 'x' else ''}: {', '.join(why)}")
    ctx.check(not bad, " / ".join(bad))


def _ramp_qn(t):
    """QN at t s under 120 -> 80 bpm linearly over 16 s, then 80 (the closed form REAPER's TimeMap2 should match)."""
    if t <= 16:
        return (120 * t - 1.25 * t * t) / 60
    return (120 * 16 - 1.25 * 256) / 60 + (t - 16) * 80 / 60


GRADUAL = ((0, 0, 120, True), (-1, 16, 80, False))  # 120 to 80 bpm over 16 s


@scenario("f3 a gradual tempo", "sync2f 3", needs=("d", "x"), wants=("l",))
def gradual(ctx):
    prep(ctx)
    undo = cross(ctx)
    set_tempo(ctx, "d", *GRADUAL)
    still_120(ctx)
    # LinuxBox on 120: Gtr's item to 9 s (QN 18: it's at 10 s already, the doc's "to 10 s" would change nothing), a point at 6 s (QN 12)
    item_set(ctx, "x", {"D_POSITION": 9.0})
    ctx.do("x", f"LV.env_add(P, {lua_str(T(ctx, 'Drums'))}, {{{{6.0, 0.25}}}}); return LV.out(true)")
    sleep(5)
    undo()
    ctx.quiet(timeout=180)
    def read(w):
        pts = [p for p in env(ctx, w) if abs(p["v"] - 0.25) < 1e-4]
        m = tmap(ctx, w)
        return {"qp": item(ctx, w)["qp"], "pt": pts[0]["qn"] if len(pts) == 1 else len(pts), "lin": bool(m and m[0]["linear"]), "n": len(m)}
    got = agree(ctx, "Gtr's item, the 0.25 point and the map after the crossing", read, 1e-5, 120)
    bad = [f"{NAMES[w]}: {v}" for w, v in got.items() if not (abs(v["qp"] - 18) <= 1e-5 and not isinstance(v["pt"], int) and abs(v["pt"] - 12) <= 1e-5 and v["lin"])]
    pt_t = [p["t"] for p in env(ctx, "d") if abs(p["v"] - 0.25) < 1e-4]
    ctx.note(f"on the desktop: Gtr at {item(ctx, 'd')['p']:.6f} s (closed form for QN 18: 10.052668), the point at "
             f"{pt_t[0] if pt_t else '?'} s (QN 12: 6.430781)")
    ctx.check(not bad, "want QN(p) 18, the point on QN 12, marker 0 linear: " + " / ".join(bad))


@scenario("f7 the same placement on Linux and Windows", "sync2f 7", needs=("d", "x"))
def placement(ctx):
    prep(ctx, drums=False)
    set_tempo(ctx, "d", *GRADUAL)
    agree(ctx, "the gradual map on both", lambda w: [(m["time"], m["bpm"], m["linear"]) for m in tmap(ctx, w)], 1e-9, 90)
    ctx.quiet()
    ts = (0.5, 7, 15.9, 16, 22.25)
    q = "{" + ",".join(f"reaper.TimeMap2_timeToQN(P, {t})" for t in ts) + "}"
    got = {w: {"qn": ctx.do(w, f"return LV.out({q})"), **{k: item(ctx, w)[k] for k in ("p", "l")}} for w in ctx.on}
    worst = max(abs(a - b) for a, b in zip(got["d"]["qn"] + [got["d"]["p"], got["d"]["l"]], got["x"]["qn"] + [got["x"]["p"], got["x"]["l"]]))
    off = [f"t {t}: {a - _ramp_qn(t):+.2e}" for t, a in zip(ts, got["d"]["qn"]) if abs(a - _ramp_qn(t)) > 1e-9]
    ctx.note(f"largest difference desktop vs LinuxBox: {worst:.3e}" + (f"; the desktop against the closed form: {', '.join(off)}" if off else ""))
    ctx.check(worst <= 1e-6, f"TimeMap2 or Gtr's place differs by {worst:.3e} (> 1e-6): desktop {got['d']}, LinuxBox {got['x']}")
    if worst > 1e-9:
        ctx.note("between 1e-9 and 1e-6: the canonical form (QN to 1e-6) still agrees")


# ---- the rest ----

@scenario("f6 no claim from a tempo change", "sync2f 6", needs=("d", "x"), wants=("l",))
def no_claim(ctx):
    """The doc's "Claims mode" is gone (sync.OLD_MODES maps it to Driver only); claims count in every mode (sync.authority), so the song
    stays Open and the bandmate claims Drums through StudioSync's own claims file."""
    b = B(ctx)
    prep(ctx)
    dn = lua_str(T(ctx, "Drums"))
    ctx.check(ctx.do(b, f"return LV.out(LV.claim(SONG, {{{dn}}}, true))"), f"{NAMES[b]} couldn't claim Drums")
    ctx.cleanups.append(lambda: ctx.do(b, f"return LV.out(LV.claim(SONG, {{{dn}}}, false))"))
    ctx.wait(f"{NAMES[b]}'s claim of Drums on the desktop", lambda: T(ctx, "Drums") in ctx.do("d", f"return LV.out(LV.claims_text(SONG, {lua_str(USER[b])}))"), timeout=120, every=3)
    b_claims = ctx.do(b, f"return LV.out(LV.claims_text(SONG, {lua_str(USER[b])}))")
    env0 = env(ctx, "d")
    marks = ctx.log_marks(["d"])
    t0 = mark_time()
    set_tempo(ctx, "d", (-1, 2, 110, False))
    agree(ctx, "the 110 bpm marker everywhere", lambda w: [(m["time"], m["bpm"]) for m in tmap(ctx, w)], 1e-6, 90)
    ctx.quiet()
    sleep(10)
    a = ctx.do(b, "return LV.out(LV.asks(P))")
    ctx.check(not a, f"{NAMES[b]} was asked: {a}")
    env1 = env(ctx, "d")
    moved = diff([round(p["qn"], 6) for p in env0], [round(p["qn"], 6) for p in env1], 1e-6)
    ctx.check(not moved, f"Drums' automation off its beats on the desktop (put back?): {moved}")
    back = ctx.log_since("d", marks, "put back")
    if back:
        ctx.note("the desktop's log: " + " | ".join(l[9:200] for l in back[:3]))
    objs = no_obj(ctx, events(ctx, t0), "d")
    ctx.check(not objs, f"the desktop sent obj events: {objs}")
    ctx.check(ctx.do(b, f"return LV.out(LV.claims_text(SONG, {lua_str(USER[b])}))") == b_claims, f"{NAMES[b]}'s claims file changed")
    mine = ctx.do("d", f"return LV.out(LV.claims_text(SONG, {lua_str(USER['d'])}))")
    named = [s for s in ("Drums", "Gtr") if T(ctx, s) in mine]
    ctx.check(not named, f"the desktop's claims file names {named}")


@scenario("f8 updating sends nothing (run first after restart)", "sync2f 8", needs=("d",), wants=("l", "x"))
def updating(ctx):
    """Meaningful once, the first look after every computer starts the level-12 build together: `live.py restart`, `live.py song`, then
    `live.py run sync2f -k f8` before anything else. Nobody edits for 120 s; no item, automation or send event may go (W.one re-anchors
    history in beats)."""
    t0 = mark_time()
    sleep(120)
    evs = events(ctx, t0)
    ctx.note("events in the 120 s: " + "; ".join(f"{NAMES[w]}: {len(es)}" for w, es in evs.items()))
    objs = no_obj(ctx, evs)
    ctx.check(not objs, f"obj events with nobody editing: {objs[:10]}")
