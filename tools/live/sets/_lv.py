"""Shared pieces for the scenario sets: the test song, its setup, and small steps every set uses."""
import json, time
from live import lua_str, Fail, Skip, NoAnswer, NAMES

SONG = "LV Checks"  # a song of this tool's own in Smiley Studios (made by `live.py song`), room mode Open (claims off)


def setup(ctx):
    """Before each scenario: the song open with Live sync running on every computer of the run, its tab in front on each (StudioSync's
    Undo and the actions work on the tab in front), and nothing left over from an earlier scenario (this scenario's prefix)."""
    for w in ctx.on:
        if not ctx.raw(w, "return LV.out(P ~= nil)"):
            # (closed by an earlier scenario that stopped half-way: opened again, as the panel's Projects page does)
            ctx.note(f"{NAMES[w]}: the song wasn't open: " + str(ctx.raw(w, "LV.use_studio(); LV.close_empty(); return LV.out(LV.open_song(SONG))")))
            time.sleep(15)
        r = ctx.do(w, """
local was = reaper.EnumProjects(-1)
if was ~= P then reaper.SelectProjectInstance(P) end
local left = LV.delete_prefix(P, %s)
if left > 0 then LV.answer(P, "delete", true) end
return LV.out({ live = LV.live_running(P), left = left,
  quiet_audio = reaper.GetExtState("BandSync", "live audio mute") == "1" and reaper.GetExtState("BandSync", "live audio deaf") == "1" })""" % lua_str(ctx.prefix))
        if r["left"]:
            from live import _answer_cleanup_ask
            _answer_cleanup_ask(ctx, w)
        if not r["quiet_audio"]:
            raise NoAnswer(f"{NAMES[w]}: live audio isn't muted and deafened: refusing to run (live.py song sets both)")
        if not r["live"]:
            raise NoAnswer(f"{NAMES[w]}: Live sync isn't running in {ctx.song}")


USER = {"d": "James", "l": "James-Laptop", "x": "LinuxBox"}


def B(ctx):
    """The bandmate who edits against the desktop: the laptop when it's in the run, else LinuxBox."""
    return "l" if "l" in ctx.on else "x"


def T(ctx, short):
    """A scenario's own track name: its prefix + a short name."""
    return ctx.prefix + short


def names(ctx, *shorts):
    return "{" + ",".join(lua_str(T(ctx, s)) for s in shorts) + "}"


def add(ctx, w, *shorts, at=None):
    ctx.do(w, f"LV.add_tracks(P, {names(ctx, *shorts)}{', ' + str(at) if at is not None else ''}); return LV.out(true)")


def order(ctx, w):
    """The scenario's tracks in order on w: [short name, ...] (parent shown as 'child<parent')."""
    s = ctx.shape(w)
    out = []
    for part in s.split(" ; ") if s else []:
        part = part.split("|")[0]
        out.append(part.replace(ctx.prefix, ""))
    return out


def quiet_order(ctx, ws=None, timeout=90):
    ctx.quiet(ws, timeout)
    return order(ctx, (ws or ctx.on)[0])


def asks(ctx, w):
    r = ctx.do(w, "return LV.out(LV.asks(P))")
    return r if isinstance(r, list) else []


def ask_of(ctx, w, kind):
    for a in asks(ctx, w):
        if a.get("kind") == kind:
            return a
    return None


def answer(ctx, w, kind, yes):
    return ctx.do(w, f"return LV.out(LV.answer(P, {lua_str(kind)}, {'true' if yes else 'false'}))")


def ss_undo(ctx, w, redo=False):
    """StudioSync's own Undo / Redo (the Ctrl+Z / Ctrl+Shift+Z scripts) on w's tab in front (setup puts the song in front)."""
    name = "StudioSync - Redo.lua" if redo else "StudioSync - Undo.lua"
    return ctx.do(w, f"LV.run_script({lua_str(name)}); return LV.out(true)", timeout=40)


def log_has(ctx, w, marks, text):
    return [l for l in ctx.log_since(w, marks) if text in l]


def sleep(s):
    time.sleep(s)


# ---- LinuxBox's network and Syncthing (inside the VM only: never the real PCs') ----
import subprocess, pathlib
_LAB = pathlib.Path(__file__).resolve().parents[2] / "lab" / "lab.sh"


def _x(cmd, inp=None):
    from live import _x_ip, SSH
    return subprocess.run(SSH + [f"studio@{_x_ip()}", cmd], input=inp, capture_output=True, text=True, timeout=60)


def x_syncthing(paused):
    """Pause or resume every device in LinuxBox's Syncthing (its REST API; approved for tests). -> True when it took."""
    what = "pause" if paused else "resume"
    r = _x('K=$(grep -ho "<apikey>[^<]*" ~/.local/state/syncthing/config.xml ~/.config/syncthing/config.xml 2>/dev/null | head -1 | cut -c9-); '
           f'curl -s -o /dev/null -w "%{{http_code}}" -X POST -H "X-API-Key: $K" localhost:8384/rest/system/{what}')
    return r.stdout.strip() == "200"


def peer_ips():
    """The desktop's and the laptop's Tailscale IPv4 addresses, asked at run time (they change)."""
    d = subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True).stdout.split()
    l = subprocess.run(["ssh", "-o", "LogLevel=ERROR", "laptop", "tailscale ip -4"], capture_output=True, text=True).stdout.split()
    return [ip for ip in (d[:1] + l[:1]) if ip.startswith("100.")]


def x_cut(on):
    """LinuxBox's direct link to the desktop and the laptop cut (every packet to and from their Tailscale addresses, inside the VM:
    tools/lab/netlab.sh), or every rule taken back (undo)."""
    if on:
        for ip in peer_ips():
            subprocess.run(["bash", str(_LAB), "net", "x", "block", ip], capture_output=True, text=True, timeout=60)
    else:
        subprocess.run(["bash", str(_LAB), "net", "x", "undo"], capture_output=True, text=True, timeout=60)
