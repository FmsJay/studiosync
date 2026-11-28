"""rt-sync2h's Live checks (docs/rt/rt-sync2h.md): nothing refused on receive (phase 6), and the room's newest timeline after a restart.
h1-h3 put the song in Claims mode (room mode "open": sync.authority binds claims there; Open, "everyone", has claims off) and back to Open
after. Claims go through StudioSync's own claims file (LV.claim: sync.claim_tracks / set_claims), asks are answered as the panel's Release
writes it. "x crosses" pauses LinuxBox's Syncthing and cuts its direct link inside the VM (sets/_lv.py), so the desktop can't learn its claim.
h4 restarts both REAPERs (live.py restart: never saving) and checks each takes the room's newest tempo map at once."""
import json, subprocess, sys, time
from live import scenario, Fail, lua_str, NAMES, HERE
from sets._lv import USER, SONG, T, add, sleep, ss_undo, log_has, x_syncthing, _LAB

SETTLE = 17  # presence.HOLD is 15 s: a bandmate's edit to what someone changed in the last 15 s is put back by design
CFG = 'local sync = require("sync"); local cfg = { root = LV.studio_root(), user = reaper.GetExtState("BandSync", "user") }\n'


# ---- small steps ----

def set_mode(ctx, mode):
    ctx.do("d", CFG + f'sync.set_mode(cfg, SONG, "main", {lua_str(mode)}, cfg.user); return LV.out(true)')
    ctx.wait(f"room mode {mode} on {', '.join(NAMES[w] for w in ctx.on)}",
             lambda: all(ctx.do(w, CFG + 'return LV.out(sync.mode(cfg, SONG, "main"))') == mode for w in ctx.on), timeout=90, every=3)


def claims_mode(ctx):
    """The song in Claims mode for this scenario; Open again after (a clean-up)."""
    set_mode(ctx, "open")
    ctx.cleanups.append(lambda: set_mode(ctx, "everyone"))


def claim(ctx, w, short, seen_by=None):
    """w claims a track lastingly through its own claims file; with seen_by, waits until that computer reads it."""
    n = lua_str(T(ctx, short))
    ctx.check(ctx.do(w, f"return LV.out(LV.claim(SONG, {{{n}}}, true))"), f"{NAMES[w]} couldn't claim {short}")
    ctx.cleanups.append(lambda: ctx.do(w, f"return LV.out(LV.claim(SONG, {{{n}}}, false))"))
    if seen_by:
        ctx.wait(f"{NAMES[w]}'s claim of {short} on {NAMES[seen_by]}",
                 lambda: T(ctx, short) in ctx.do(seen_by, f"return LV.out(LV.claims_text(SONG, {lua_str(USER[w])}))"), timeout=120, every=3)


def vol(ctx, w, short):
    return ctx.do(w, f"local t = LV.track(P, {lua_str(T(ctx, short))}); return LV.out(t and reaper.GetMediaTrackInfo_Value(t, 'D_VOL') or -1)")


def set_vol(ctx, w, short, v):
    ctx.do(w, f"LV.set_vol(P, {lua_str(T(ctx, short))}, {float(v)!r}); return LV.out(true)")


def incoming(ctx, w):
    """The claim asks waiting on w's person (claimask.model's incoming, as the panel reads it)."""
    r = ctx.do(w, 'local band = LV.lib(); return LV.out((band.json_decode(reaper.GetExtState("BandSync", "claim asks " .. tostring(P))) or {}).incoming or {})')
    return r if isinstance(r, list) else []


def release(ctx, w, ask_id):
    """Release, as the panel's button writes it (claimask.tick carries it out)."""
    ctx.do(w, f'local band = LV.lib(); reaper.SetExtState("BandSync", "claim answer " .. tostring(P), band.json_encode({{ id = {lua_str(ask_id)}, yes = true }}), false); return LV.out(true)')


def crossing(ctx):
    """x crosses: LinuxBox's Syncthing paused and its direct link to the desktop cut, inside the VM. -> undo() (also a clean-up)."""
    ctx.check(x_syncthing(True), "couldn't pause LinuxBox's Syncthing")
    done = []
    def undo():
        if done:
            return
        done.append(1)
        subprocess.run(["bash", str(_LAB), "net", "x", "undo"], capture_output=True, text=True, timeout=60)
        x_syncthing(False)
    ctx.cleanups.append(undo)
    ips = [ip for ip in subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True).stdout.split()[:1] if ip.startswith("100.")]
    ctx.check(ips, "no Tailscale address to cut")
    for ip in ips:
        subprocess.run(["bash", str(_LAB), "net", "x", "block", ip], capture_output=True, text=True, timeout=60)
    return undo


def names_on(ctx, w):
    return [p.split("|")[0].replace(ctx.prefix, "") for p in (ctx.shape(w) or "").split(" ; ") if p]


def tmap(ctx, w):
    return [(m["time"], m["bpm"]) for m in ctx.do(w, "return LV.out(LV.tempo_map(P))")]


# ---- 1. a claimed track edited by a bandmate whose StudioSync asked ----

@scenario("h1 asked: lands at once, no minute", "sync2h 1", needs=("d", "x"))
def asked(ctx):
    claims_mode(ctx)
    add(ctx, "d", "Keys")
    ctx.quiet()
    sleep(SETTLE)
    claim(ctx, "x", "Keys", seen_by="d")
    marks = ctx.log_marks()
    set_vol(ctx, "d", "Keys", 0.5)
    q = ctx.wait("the desktop's ask on LinuxBox", lambda: incoming(ctx, "x"), timeout=45, every=1)
    t0 = time.time()
    release(ctx, "x", q[0]["id"])
    ctx.wait("Keys at 0.5 on LinuxBox", lambda: abs(vol(ctx, "x", "Keys") - 0.5) < 1e-6, timeout=60, every=1)
    took = time.time() - t0
    ctx.note(f"from Release to the edit on LinuxBox: {took:.1f} s")
    ctx.check(took < 20, f"the asked edit took {took:.0f} s to land on LinuxBox (a refusal minute?)")
    sleep(5)
    ctx.check(abs(vol(ctx, "d", "Keys") - 0.5) < 1e-6, f"the desktop's edit was put back: {vol(ctx, 'd', 'Keys')}")
    told = log_has(ctx, "x", marks, "which you've claimed")
    ctx.check(not told, f"LinuxBox says it didn't ask, though it did: {told[:1]}")


# ---- 2. the rename / claim races ----

@scenario("h2 a claim crossing an edit: lands at once, the claimer told", "sync2h 2", needs=("d", "x"))
def crossing_edit(ctx):
    claims_mode(ctx)
    add(ctx, "d", "Keys")
    ctx.quiet()
    sleep(SETTLE)
    undo = crossing(ctx)
    claim(ctx, "x", "Keys")
    sleep(3)
    set_vol(ctx, "d", "Keys", 0.4)  # the desktop can't know LinuxBox's claim: its edit goes out
    sleep(6)
    marks = ctx.log_marks(["x"])
    undo()
    t0 = time.time()
    ctx.wait("Keys at 0.4 on LinuxBox", lambda: abs(vol(ctx, "x", "Keys") - 0.4) < 1e-6, timeout=120, every=2)
    took = time.time() - t0
    ctx.note(f"from reconnecting to the edit on LinuxBox: {took:.1f} s (Syncthing's catch-up and the link's included)")
    ctx.check(took < 50, f"the crossing edit took {took:.0f} s to land on LinuxBox (held a minute on receive?)")
    told = log_has(ctx, "x", marks, "which you've claimed")
    ctx.check(any("their StudioSync didn't ask" in l and T(ctx, "Keys") in l for l in told), f"LinuxBox's log doesn't say the desktop didn't ask: {told[:2]}")
    sleep(8)
    ctx.check(abs(vol(ctx, "d", "Keys") - 0.4) < 1e-6 and abs(vol(ctx, "x", "Keys") - 0.4) < 1e-6,
              f"they differ after: desktop {vol(ctx, 'd', 'Keys')}, LinuxBox {vol(ctx, 'x', 'Keys')}")


@scenario("h3 a Redo of a rename crossing a claim on the old name stands (127)", "sync2h 3", needs=("d", "x"))
def rename_redo_claim(ctx):
    claims_mode(ctx)
    add(ctx, "d", "Drums")
    ctx.quiet()
    sleep(SETTLE)
    ctx.do("d", f"LV.rename(P, {lua_str(T(ctx, 'Drums'))}, {lua_str(T(ctx, 'T1'))}); return LV.out(true)")
    ctx.wait("T1 on both", lambda: all(names_on(ctx, w) == ["T1"] for w in ctx.on), timeout=60, every=2)
    sleep(3)
    ss_undo(ctx, "d")
    ctx.wait("Drums again on both", lambda: all(names_on(ctx, w) == ["Drums"] for w in ctx.on), timeout=60, every=2)
    sleep(SETTLE)
    undo = crossing(ctx)
    claim(ctx, "x", "Drums")
    sleep(2)
    ss_undo(ctx, "d", redo=True)
    ctx.wait("the Redo on the desktop", lambda: names_on(ctx, "d") == ["T1"], timeout=30, every=1)
    sleep(5)
    marks = ctx.log_marks(["x"])
    undo()
    try:
        ctx.wait("T1 on both, for 20 s", lambda: all(names_on(ctx, w) == ["T1"] for w in ctx.on) and (sleep(20) or True)
                 and all(names_on(ctx, w) == ["T1"] for w in ctx.on), timeout=150, every=3)
    except Fail as e:
        back = log_has(ctx, "x", marks, "put back")
        raise Fail(f"{e}; LinuxBox's log: {back[:2]}")
    told = log_has(ctx, "x", marks, "which you've claimed")
    ctx.note("LinuxBox's log: " + (" | ".join(l[9:200] for l in told[:2]) or "(nothing about the claim)"))
    ctx.check(any("renamed" in l and "didn't ask" in l for l in told), f"LinuxBox's log doesn't say the rename came unasked: {told[:2]}")


# ---- 4. the room's newest timeline after a restart ----

def restart_both(ctx):
    live = str(HERE / "live.py")
    for cmd in (["restart"], ["song"]):
        r = subprocess.run([sys.executable, live] + cmd + ["--on", ",".join(ctx.on)], capture_output=True, text=True, timeout=900)
        ctx.note(f"live.py {cmd[0]}: " + " | ".join(r.stdout.strip().splitlines()[-2:]))
    ctx.wait("Live sync running on both", lambda: all(ctx.do(w, "return LV.out(LV.live_running(P))") for w in ctx.on), timeout=120, every=3)


def on_map(ctx, bpm, what, timeout):
    t0 = time.time()
    last = {}
    def ok():
        nonlocal last
        last = {w: tmap(ctx, w) for w in ctx.on}
        return all(m == [(0, bpm)] for m in last.values())
    try:
        ctx.wait(what, ok, timeout=timeout, every=2)
    except Fail:
        raise Fail(f"{what}: not within {timeout} s of Live sync running: " + "; ".join(f"{NAMES[w]} {m}" for w, m in last.items()))
    return time.time() - t0


def back_to_120(ctx):
    def go():
        try:
            for bpm in (121, 120):  # (through 121: a computer already on 120 sends nothing for it)
                ctx.do("d", f"LV.tempo_reset(P, {bpm}); return LV.out(true)")
                on_map(ctx, bpm, f"the tempo at {bpm} everywhere", 120)
        except Fail as e:
            ctx.note(f"cleanup: {e}")
    return go


@scenario("h4 after a restart, the room's newest tempo map at once", "sync2h 4", needs=("d", "x"))
def restart_timeline(ctx):
    """a. A tempo change of the desktop's, then both REAPERs restarted onto their files: each on it within 30 s of Live sync running.
    b. The room's newest timeline change made at the level before (what every deploy that raises the level leaves: rt-fixlive2's f4 prep,
    rt-sync2g's desktop after 0.63.1): a copy of the desktop's timeline at 113 bpm with lv one lower, written into the room's events by hand;
    after a restart each must be on 113. 0.65.1 holds it by the floor and picks it as the newest map, so no older one lands either."""
    ctx.cleanups.append(back_to_120(ctx))
    ctx.do("d", "LV.tempo_reset(P, 117); return LV.out(true)")
    on_map(ctx, 117, "117 on both before the restart", 90)
    restart_both(ctx)
    took = on_map(ctx, 117, "a. 117 on both after the restart", 30)
    ctx.note(f"a. both on 117 {took:.0f} s after Live sync ran")
    made = ctx.do("d", CFG + """local band = LV.lib()
local id = string.format("%s-%s-%05d-%04d", sync.id_user(cfg.user), os.date("!%Y%m%d-%H%M%SZ"), 99999, math.random(0, 9999))
local ev = { type = "timeline", id = id, user = cfg.user, time = os.date("!%Y-%m-%dT%H:%M:%SZ"), format = band.FORMAT, lv = sync.LEVEL - 1,
  tempo = { { time = 0, bpm = 113, num = 4, denom = 4, linear = false } }, markers = band.capture_markers(P), project = band.capture_project(P) }
local path = sync.room_dir(cfg, SONG, "main") .. "/events/" .. id .. ".json"
band.write_json(path, ev)
return LV.out({ id = id, path = path, lv = ev.lv })""")
    def unforge():
        ctx.do("d", f"os.remove({lua_str(made['path'])}); return LV.out(true)")
    ctx.cleanups.insert(0, unforge)
    ctx.note(f"b. wrote {made['id']} (lv {made['lv']}, 113 bpm)")
    ctx.wait("LinuxBox has the hand-made change's file", lambda: ctx.do("x", CFG + f"""
return LV.out(reaper.file_exists(sync.room_dir(cfg, SONG, "main") .. "/events/" .. {lua_str(made['id'])} .. ".json"))"""), timeout=120, every=3)
    restart_both(ctx)
    took = on_map(ctx, 113, "b. the room's newest (113, made a level lower) on both after the restart", 60)
    ctx.note(f"b. both on 113 {took:.0f} s after Live sync ran")
