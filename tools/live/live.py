#!/usr/bin/env python3
"""StudioSync live checks: drive the real REAPERs on the desktop (d), the laptop (l, ssh) and LinuxBox (x, ssh) through their dev
eval hooks, run named scenario sets, print a pass/fail table and write a JSON report. See tools/live/README.md.

  python tools/live/live.py up                       who answers, which StudioSync each runs, the test song open there
  python tools/live/live.py eval d|l|x FILE.lua      one chunk in one REAPER (prints the hook's answer)
  python tools/live/live.py run SET [-k NAME] [--on d,l,x] [--song NAME] [--report FILE]
  python tools/live/live.py sets                     the sets and their scenarios
"""
import argparse, base64, importlib, json, os, pathlib, subprocess, sys, time, traceback, uuid

HERE = pathlib.Path(__file__).resolve().parent
LUA = HERE / "lua" / "live.lua"
DEV_D = "J:/Portable Workstation/DAW/REAPER/Scripts/MIDI Control Center/midi_control_center/dev"
DEV_L = "D:/Portable Workstation/DAW/REAPER/Scripts/MIDI Control Center/midi_control_center/dev"
DEV_X = "/home/studio/REAPER/Scripts/MIDI Control Center/midi_control_center/dev"
NAMES = {"d": "desktop", "l": "laptop", "x": "LinuxBox"}
# Where each computer runs StudioSync's actions from (Open session, Undo, Redo...): the desktop from its main checkout; the others from the
# studio folder's _tools/studiosync (None). SS_DESKTOP_SCRIPTS overrides the desktop's.
SCRIPTS = {"d": os.environ.get("SS_DESKTOP_SCRIPTS", "J:/Portable Workstation/DAW/Utility/studiosync")}
SSH = ["ssh", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR"]
STALE_LOCK = 600  # a lock older than this is a dead holder's (as every earlier runner: run.sh, lap_eval.sh, reval.sh)


class NoAnswer(Exception):
    """The computer's REAPER didn't answer in time (not running, a modal dialog, the hook stopped, ssh down)."""


class Fail(AssertionError):
    pass


def _x_ip():
    ip = os.environ.get("X_IP")
    if ip:
        return ip
    out = subprocess.run(["bash", str(HERE.parent / "lab" / "lab.sh"), "ip", "x"], capture_output=True, text=True).stdout.strip()
    if not out.startswith(("192.", "10.", "172.")):
        raise NoAnswer("LinuxBox isn't running (tools/lab/lab.sh start x)")
    os.environ["X_IP"] = out
    return out


# ---- transport: one chunk, one answer -----------------------------------------------------------------------------------------------
# Every transport: take dev/.evallock (shared with other sessions' runners), wait for a pending eval.lua, drop ours with an atomic rename,
# wait for result.txt; on timeout take our eval.lua back (so a REAPER blocked by a dialog doesn't run a stale step later) and say NO ANSWER.

PS_EVAL = r"""
param([string]$B64, [int]$T = 30, [string]$Dev)
$L = "$Dev/.evallock"; $got = $false
for ($i = 0; $i -lt 600; $i++) {
  try { [void](New-Item -ItemType Directory -Path $L -ErrorAction Stop); $got = $true; break }
  catch { if ((Test-Path $L) -and ((Get-Date) - (Get-Item $L).CreationTime).TotalSeconds -gt 600) { Remove-Item -Force $L -ErrorAction SilentlyContinue } }
  Start-Sleep -Milliseconds 500 }
if (-not $got) { "LVBUSY"; exit 0 }
try {
  for ($i = 0; ($i -lt 120) -and (Test-Path "$Dev/eval.lua"); $i++) { Start-Sleep -Milliseconds 250 }
  $id = [guid]::NewGuid().ToString('N').Substring(0, 8); $src = "$Dev/live_src_$id.lua"
  [IO.File]::WriteAllBytes($src, [Convert]::FromBase64String($B64))
  Remove-Item -ErrorAction SilentlyContinue "$Dev/result.txt"
  [IO.File]::WriteAllText("$Dev/eval.tmp", "return dofile([[$src]])"); Move-Item -Force "$Dev/eval.tmp" "$Dev/eval.lua"
  $end = (Get-Date).AddSeconds($T); $out = $null
  while ((Get-Date) -lt $end) { if (Test-Path "$Dev/result.txt") { Start-Sleep -Milliseconds 50; $out = [IO.File]::ReadAllText("$Dev/result.txt"); break }; Start-Sleep -Milliseconds 100 }
  if ($null -eq $out) { Remove-Item -ErrorAction SilentlyContinue "$Dev/eval.lua"; "LVNOANSWER" } else { $out }
  Remove-Item -ErrorAction SilentlyContinue $src
} finally { Remove-Item -Force -ErrorAction SilentlyContinue $L }
"""

SH_EVAL = r"""
B64="$1"; T="${2:-30}"; D="$3"; L="$D/.evallock"; got=
for _ in $(seq 1 1200); do mkdir "$L" 2>/dev/null && { got=1; break; }; [ -n "$(find "$L" -maxdepth 0 -mmin +10 2>/dev/null)" ] && rmdir "$L" 2>/dev/null; sleep 0.5; done
[ -n "$got" ] || { echo LVBUSY; exit 0; }
trap 'rmdir "$L" 2>/dev/null' EXIT
for _ in $(seq 1 120); do [ -f "$D/eval.lua" ] || break; sleep 0.25; done
src="$D/live_src_$$.lua"; echo "$B64" | base64 -d > "$src"
rm -f "$D/result.txt"; printf 'return dofile([[%s]])' "$src" > "$D/eval.tmp" && mv "$D/eval.tmp" "$D/eval.lua"
for _ in $(seq 1 $((T*10))); do [ -f "$D/result.txt" ] && { sleep 0.05; cat "$D/result.txt"; echo; rm -f "$src"; exit 0; }; sleep 0.1; done
rm -f "$D/eval.lua" "$src"; echo LVNOANSWER
"""


def _eval_desktop(code, timeout):
    dev = pathlib.Path(DEV_D)
    lock = dev / ".evallock"
    t0 = time.time()
    while True:
        try:
            lock.mkdir()
            break
        except FileExistsError:
            try:
                if time.time() - lock.stat().st_mtime > STALE_LOCK:
                    lock.rmdir()
            except OSError:
                pass
            if time.time() - t0 > 600:
                raise NoAnswer("desktop: dev hook lock held for 10 minutes")
            time.sleep(0.3)
    try:
        for _ in range(120):
            if not (dev / "eval.lua").exists():
                break
            time.sleep(0.25)
        src = dev / f"live_src_{uuid.uuid4().hex[:8]}.lua"
        src.write_text(code, encoding="utf-8")
        (dev / "result.txt").unlink(missing_ok=True)
        (dev / "eval.tmp").write_text(f"return dofile([[{src.as_posix()}]])", encoding="utf-8")
        os.replace(dev / "eval.tmp", dev / "eval.lua")
        end = time.time() + timeout
        while time.time() < end:
            if (dev / "result.txt").exists():
                time.sleep(0.05)
                out = (dev / "result.txt").read_text(encoding="utf-8", errors="replace")
                src.unlink(missing_ok=True)
                return out
            time.sleep(0.1)
        (dev / "eval.lua").unlink(missing_ok=True)
        src.unlink(missing_ok=True)
        return "LVNOANSWER"
    finally:
        try:
            lock.rmdir()
        except OSError:
            pass


_pushed = {}


def _push(w):
    """Copy live.lua (and the remote eval script) to a computer's dev folder when it changed."""
    body = LUA.read_bytes()
    key = hash(body)
    if _pushed.get(w) == key:
        return
    if w == "d":
        (pathlib.Path(DEV_D) / "live.lua").write_bytes(body)
    elif w == "l":
        tmp = HERE / ".live_eval.ps1"
        tmp.write_text(PS_EVAL, encoding="utf-8")
        for f, dst in ((LUA, "live.lua"), (tmp, "live_eval.ps1")):
            r = subprocess.run(["scp", "-q", "-o", "ConnectTimeout=8", "-o", "LogLevel=ERROR", str(f), f"laptop:{DEV_L}/{dst}"], capture_output=True, text=True)
            if r.returncode:
                tmp.unlink(missing_ok=True)
                raise NoAnswer(f"laptop: copy failed: {r.stderr.strip()[:200]}")
        tmp.unlink(missing_ok=True)
    elif w == "x":
        ip = _x_ip()
        r = subprocess.run(SSH + [f"studio@{ip}", f"cat > '{DEV_X}/live.lua'"], input=body, capture_output=True)
        r2 = subprocess.run(SSH + [f"studio@{ip}", f"cat > '{DEV_X}/live_eval.sh'"], input=SH_EVAL.encode(), capture_output=True)
        if r.returncode or r2.returncode:
            raise NoAnswer("LinuxBox: copy failed")
    _pushed[w] = key


def lua_path(w):
    return {"d": DEV_D, "l": DEV_L, "x": DEV_X}[w] + "/live.lua"


def raw_eval(w, code, timeout=30):
    """Run a Lua chunk in computer w's REAPER. -> the hook's text ("OK\\n..." or an error). Raises NoAnswer."""
    _push(w)
    if w == "d":
        out = _eval_desktop(code, timeout)
    elif w == "l":
        b64 = base64.b64encode(code.encode("utf-8")).decode()
        cmd = f"powershell -NoProfile -ExecutionPolicy Bypass -File \"{DEV_L}/live_eval.ps1\" -B64 {b64} -T {int(timeout)} -Dev \"{DEV_L}\""
        try:
            r = subprocess.run(SSH + ["laptop", cmd], capture_output=True, text=True, timeout=timeout + 400)
        except subprocess.TimeoutExpired:
            raise NoAnswer("laptop: ssh timed out")
        out = r.stdout
        if r.returncode and not out.strip():
            raise NoAnswer(f"laptop: ssh failed: {r.stderr.strip()[:200]}")
    elif w == "x":
        b64 = base64.b64encode(code.encode("utf-8")).decode()
        try:
            r = subprocess.run(SSH + [f"studio@{_x_ip()}", f"bash '{DEV_X}/live_eval.sh' {b64} {int(timeout)} '{DEV_X}'"],
                               capture_output=True, text=True, timeout=timeout + 700)
        except subprocess.TimeoutExpired:
            raise NoAnswer("LinuxBox: ssh timed out")
        out = r.stdout
        if r.returncode and not out.strip():
            raise NoAnswer(f"LinuxBox: ssh failed: {r.stderr.strip()[:200]}")
    else:
        raise ValueError(w)
    out = out.replace("\r", "").strip()
    if "LVNOANSWER" in out:
        raise NoAnswer(f"{NAMES[w]}: no answer in {timeout} s (REAPER not running, a dialog open, or its hook stopped)")
    if "LVBUSY" in out:
        raise NoAnswer(f"{NAMES[w]}: dev hook lock held for 10 minutes")
    return out


def lua(w, body, timeout=30, song=None):
    """Run `body` (Lua statements ending in `return LV.out(...)`) with LV loaded and SONG / P set. -> the decoded value."""
    pre = (f"LV_SCRIPTS = {lua_str(SCRIPTS[w]) if SCRIPTS.get(w) else 'nil'}\n"
           f"local LV = dofile([[{lua_path(w)}]])\n")
    if song:
        pre += f"local SONG = {lua_str(song)}\nlocal P = LV.proj(SONG)\n"
    code = pre + "local ok, r = pcall(function()\n" + body + "\nend)\nif ok then return r end\nreturn 'LVERR ' .. tostring(r)"
    out = raw_eval(w, code, timeout)
    if out.startswith("OK\n"):
        out = out[3:]
    if out.startswith("LVJSON"):
        return json.loads(out[6:])
    if out.startswith("LVERR LVNOSONG") or "LVNOSONG" in out:
        raise NoAnswer(f"{NAMES[w]}: {out.split('LVNOSONG', 1)[1].strip()}")
    if out.startswith(("LVERR", "RUNTIME ERROR", "COMPILE ERROR")):
        raise RuntimeError(f"{NAMES[w]}: {out[:600]}")
    return out


def lua_str(s):
    return "[==[" + s + "]==]"


# ---- the scenario context -------------------------------------------------------------------------------------------------------------

class Ctx:
    """What a scenario gets: the computers in this run, the test song, Lua on each, waits, checks and notes for the report."""

    def __init__(self, on, song, prefix):
        self.on, self.song, self.prefix = on, song, prefix
        self.notes, self.evidence = [], []
        self.cleanups = []

    # Lua on a computer, in the test song (P = its tab; error if it isn't open there)
    def do(self, w, body, timeout=30):
        return lua(w, "P = LV.need(SONG)\n" + body, timeout, self.song)

    # Lua on a computer without requiring the song's tab (opening or closing it); SONG set, P the tab or nil
    def raw(self, w, body, timeout=60):
        return lua(w, body, timeout, self.song)

    def shape(self, w):
        return self.do(w, f"return LV.out(LV.shape(P, {lua_str(self.prefix)}))")

    def state(self, w):
        return self.do(w, f"return LV.out(LV.state(P, {{ prefix = {lua_str(self.prefix)} }}))")

    def note(self, s):
        self.notes.append(s)
        print("   ", s, flush=True)

    def wait(self, what, fn, timeout=60, every=2.0):
        """Poll fn() until it returns a truthy value; -> that value. Raises Fail naming `what` with the last value seen."""
        end, last = time.time() + timeout, None
        while True:
            try:
                last = fn()
            except NoAnswer:
                raise
            if last:
                return last
            if time.time() > end:
                raise Fail(f"timed out after {timeout} s waiting for {what} (last: {str(last)[:300]})")
            time.sleep(every)

    def quiet(self, ws=None, timeout=90, settle=6, show=None):
        """'Everything quiet': the scenario's tracks read the same on every computer and haven't changed for `settle` s.
        -> the shape they agree on. Raises Fail with each computer's shape when they don't agree in time."""
        ws = ws or self.on
        end, stable_since, last = time.time() + timeout, None, None
        while True:
            shapes = {w: self.shape(w) for w in ws}
            same = len(set(shapes.values())) == 1
            if same and shapes == last:
                if stable_since and time.time() - stable_since >= settle:
                    return shapes[ws[0]]
                stable_since = stable_since or time.time()
            else:
                stable_since = time.time() if same else None
            last = shapes
            if time.time() > end:
                raise Fail("not quiet: the computers differ after %d s:\n%s" % (timeout, "\n".join(f"      {NAMES[w]}: {s}" for w, s in shapes.items())))
            time.sleep(2)

    def log_marks(self, ws=None):
        return {w: self.do(w, "return LV.out(LV.log_mark())") for w in (ws or self.on)}

    def log_since(self, w, marks, find=None):
        return self.do(w, f"return LV.out(LV.log_since({marks[w]}, {lua_str(find) if find else 'nil'}))")

    def at_once(self, steps, lead=8.0, after=4.0):
        """Run {w: lua body returning a value} at one moment on the studio's shared link clock. -> {w: (ran_at, result)}."""
        now = self.do(self.on[0], "return LV.out(LV.now())")
        at = round(now + lead, 3)
        for w, body in steps.items():
            self.do(w, f"return LV.out(LV.at({at}, function()\n{body}\nend))")
        time.sleep(lead + after)
        out = {}
        for w in steps:
            r = self.do(w, "return LV.out(LV.timed_result())")
            try:
                r = json.loads(r)
            except Exception:
                pass
            out[w] = r
        spread = [v.get("at") for v in out.values() if isinstance(v, dict) and v.get("at")]
        if spread:
            self.note("ran at one shared moment, %d ms apart" % round((max(spread) - min(spread)) * 1000))
        for w, v in out.items():
            if not (isinstance(v, dict) and v.get("ok")):
                raise RuntimeError(f"{NAMES[w]}'s timed step: {v}")
        self.note("just after: " + " | ".join(f"{NAMES[w]}: {self.shape(w).replace(self.prefix, '')}" for w in self.on))
        return out

    def check(self, cond, msg):
        if not cond:
            raise Fail(msg)


def scenario(name, check, needs=("d", "l"), wants=()):
    """Decorator for a scenario function f(ctx). `check`: which check list item it automates; `needs`: computers it requires; `wants`:
    computers it uses when they're in the run (a third computer to agree with; the laptop as the bandmate, else LinuxBox stands in)."""
    def wrap(f):
        f.lv = {"name": name, "check": check, "needs": tuple(needs), "wants": tuple(wants)}
        return f
    return wrap


class Skip(Exception):
    """A scenario that can't be automated or can't run here: the reason goes in the report."""


# ---- commands -------------------------------------------------------------------------------------------------------------------------

def cmd_up(args):
    rows = []
    for w in args.on.split(","):
        try:
            r = lua(w, f"""
local band, dir, v = LV.lib()
local p = LV.proj({lua_str(args.song)})
local tabs = {{}}
for i = 0, 99 do local q = reaper.EnumProjects(i); if not q then break end; tabs[#tabs+1] = select(2, reaper.GetProjExtState(q, "BandSync", "song")) end
return LV.out({{ lib = v, user = reaper.GetExtState("BandSync", "user"), deaf = reaper.GetExtState("BandSync", "live audio deaf"), mute = reaper.GetExtState("BandSync", "live audio mute"),
  song_open = p ~= nil, live = p and LV.live_running(p) or false, tabs = tabs, reaper = reaper.GetAppVersion() }})""", 20)
            rows.append((NAMES[w], "answers", json.dumps(r)))
        except (NoAnswer, RuntimeError) as e:
            rows.append((NAMES[w], "NO ANSWER", str(e)))
    for r in rows:
        print("%-9s %-10s %s" % r)


def cmd_song(args):
    """Open the test song on each computer (the desktop makes it first when the studio hasn't got it), Live audio deafened first, the room
    set to Open (claims off) by the desktop (the studio's owner). --close: close its tab everywhere without saving, and put back the studio
    each computer worked in before."""
    song = args.song
    for w in args.on.split(","):
        try:
            if args.close:
                r = lua(w, f"return LV.out({{ LV.close_song({lua_str(song)}), LV.restore_studio() }})", 40)
            else:
                # (Live sync turns live audio on as it starts: muted and deafened first, so no computer's input is sent, a VM's least of all)
                body = 'reaper.SetExtState("BandSync", "live audio deaf", "1", true)\nreaper.SetExtState("BandSync", "live audio mute", "1", true)\n'
                if w == "d":
                    body += f"""
local root = LV.studio_root()
local r = reaper.file_exists(root .. "/" .. {lua_str(song)} .. "/session.json") and LV.open_song({lua_str(song)}) or LV.publish_song({lua_str(song)})
local band = LV.lib(); local sync = require("sync")
local cfg = {{ root = root, user = reaper.GetExtState("BandSync", "user") }}
if sync.mode(cfg, {lua_str(song)}, "main") ~= "everyone" then sync.set_mode(cfg, {lua_str(song)}, "main", "everyone", cfg.user); r = r .. ", room set to Open" end
return LV.out(r)"""
                else:
                    body += f"return LV.out(LV.open_song({lua_str(song)}))"
                r = lua(w, body, 60)
            print(f"{NAMES[w]}: {r}")
        except (NoAnswer, RuntimeError) as e:
            print(f"{NAMES[w]}: {e}")


def cmd_restart(args):
    """Restart each computer's REAPER at once (threads), never saving: onto a newly deployed build (a running REAPER keeps the code it
    approved; files changed since are refused until it restarts). Then each must be opened in the song again: `live.py song`."""
    import threading
    out = {}
    def go(w):
        try:
            if w == "d":
                # (once more when it didn't say it restarted: a first try timed out once, REAPER left running "[modified]". rt-fixlive3)
                for tried in (1, 2):
                    try:
                        r = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(HERE / "restart" / "restart_desktop.ps1")],
                                           capture_output=True, text=True, timeout=400)
                        if "desktop restarted" in r.stdout:
                            break
                        why = (r.stdout.strip().splitlines() or ["(nothing said)"])[-1]
                    except subprocess.TimeoutExpired:
                        why, r = "timed out after 400 s", None
                    print(f"desktop: restart try {tried}: {why}" + ("; trying once more" if tried == 1 else ""), flush=True)
                if r is None:
                    out[w] = f"failed twice: {why}"
                    return
            elif w == "l":
                r = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(HERE / "start_laptop.ps1"), "-Restart"],
                                   capture_output=True, text=True, timeout=400)
            else:
                r = subprocess.run(SSH + [f"studio@{_x_ip()}", "pkill -TERM -x reaper; for i in $(seq 1 30); do pgrep -x reaper >/dev/null || break; sleep 1; done; "
                                   "sleep 21; ~/start-reaper.sh -new"], capture_output=True, text=True, timeout=200)
            out[w] = (r.stdout.strip().splitlines() or ["(nothing said)"])[-1]
        except Exception as e:
            out[w] = f"failed: {e}"
    ts = [threading.Thread(target=go, args=(w,)) for w in args.on.split(",")]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    for w, s in out.items():
        print(f"{NAMES[w]}: {s}")
    _pushed.clear()


def cmd_eval(args):
    print(raw_eval(args.w, pathlib.Path(args.file).read_text(encoding="utf-8"), args.timeout))


def load_set(name):
    sys.path.insert(0, str(HERE))
    mod = importlib.import_module(f"sets.{name}")
    scen = [getattr(mod, a) for a in dir(mod) if hasattr(getattr(mod, a), "lv")]
    scen.sort(key=lambda f: f.__code__.co_firstlineno)
    return mod, scen


def cmd_sets(args):
    for f in sorted((HERE / "sets").glob("*.py")):
        if f.stem.startswith("_"):
            continue
        mod, scen = load_set(f.stem)
        print(f"{f.stem}: {(mod.__doc__ or '').strip().splitlines()[0] if mod.__doc__ else ''}")
        for s in scen:
            print(f"   {s.lv['name']:<40} {s.lv['check']:<24} needs {','.join(s.lv['needs'])}" + (f" (+{','.join(s.lv['wants'])} when there)" if s.lv.get('wants') else ""))


def cmd_run(args):
    mod, scen = load_set(args.set)
    on = args.on.split(",")
    # (a set that didn't import SONG ran in "SS Test Project 112326", a room in Claims mode: sync2i's bandmate edits asked for the desktop's
    # auto-claim and were put back. rt-fixlive3)
    song = args.song or getattr(mod, "SONG", "LV Checks")
    if args.k:
        scen = [s for s in scen if any(k in s.lv["name"] for k in args.k)]
    results = []
    setup = getattr(mod, "setup", None)
    started = time.strftime("%Y-%m-%dT%H:%M:%S")
    for s in scen:
        meta = s.lv
        prefix = "LV " + "".join(ch for ch in meta["name"] if ch.isalnum())[:14] + " "
        want = list(meta["needs"]) + [w for w in meta.get("wants", ()) if w in on]
        ctx = Ctx([w for w in ("d", "l", "x") if w in want] or on, song, prefix)
        missing = [w for w in meta["needs"] if w not in on]
        row = {"name": meta["name"], "check": meta["check"], "on": ctx.on}
        print(f"== {meta['name']} ({meta['check']}) on {','.join(ctx.on)}", flush=True)
        t0 = time.time()
        if missing:
            row.update(result="skip", why=f"needs {','.join(NAMES[w] for w in missing)}")
        else:
            tries = args.retries + 1
            for attempt in range(tries):
                ctx.notes, ctx.cleanups = [], []
                try:
                    if setup:
                        setup(ctx)
                    s(ctx)
                    row.update(result="pass")
                    row.pop("why", None)  # (a retry that passed: the failed try's reason stays in "retried" only)
                except Skip as e:
                    row.update(result="couldn't automate", why=str(e))
                except Fail as e:
                    row.update(result="fail", why=str(e))
                except NoAnswer as e:
                    row.update(result="no answer", why=str(e))
                except Exception as e:
                    row.update(result="error", why=f"{type(e).__name__}: {e}", trace=traceback.format_exc()[-1500:])
                finally:
                    _cleanup(ctx)
                if row["result"] not in ("fail", "error") or attempt == tries - 1:
                    break
                print(f"   retry {attempt + 1}: {row['why'][:200]}", flush=True)
                row.setdefault("retried", []).append(row["why"])
        row["notes"] = list(ctx.notes)
        row["secs"] = round(time.time() - t0, 1)
        results.append(row)
        print(f"   -> {row['result'].upper()}{': ' + row['why'][:400] if row.get('why') else ''}", flush=True)
    rep = {"set": args.set, "song": song, "on": on, "started": started, "ended": time.strftime("%Y-%m-%dT%H:%M:%S"), "results": results}
    path = pathlib.Path(args.report) if args.report else HERE / "reports" / f"{args.set}-{time.strftime('%Y%m%d-%H%M%S')}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(rep, indent=1), encoding="utf-8")
    print()
    print("%-36s %-22s %-18s %s" % ("scenario", "check", "result", "why"))
    for r in results:
        print("%-36s %-22s %-18s %s" % (r["name"], r["check"], r["result"], (r.get("why") or "").splitlines()[0][:110] if r.get("why") else ""))
    print(f"\nreport: {path}")
    return 0 if all(r["result"] in ("pass", "couldn't automate", "skip") for r in results) else 1


def purge(ctx, w, prefix=None):
    """Delete every track named `prefix`... on w; when that is half the song or more, StudioSync asks first (the big-deletion ask): this is
    the tool's own clean-up, so the ask is answered Yes at once (the bar's Yes, LV.answer). -> how many were deleted."""
    pre = lua_str(prefix or ctx.prefix)
    return ctx.do(w, f"""
local n = LV.delete_prefix(P, {pre})
if n == 0 then return LV.out(0) end
local q = LV.answer(P, "delete", true)
return LV.out(q and -n or n)""")


def _answer_cleanup_ask(ctx, w, secs=20):
    """A deletion's ask appears on the look after the deletion: keep answering Yes for a few seconds."""
    end = time.time() + secs
    while time.time() < end:
        try:
            if ctx.do(w, "return LV.out(LV.answer(P, 'delete', true) ~= nil)"):
                return True
        except Exception:
            return False
        time.sleep(0.5)
    return False


def _cleanup(ctx):
    """Every scenario's own tracks go (prefix "LV <name> "), on each computer it ran on, then the cleanups it registered. Nothing saved."""
    for fn in reversed(ctx.cleanups):
        try:
            fn()
        except Exception as e:
            ctx.note(f"cleanup step failed: {e}")
    for w in ctx.on[:1]:  # (deleted on the first computer: the deletion syncs; then every computer is checked)
        try:
            n = purge(ctx, w)
            if n and _answer_cleanup_ask(ctx, w):
                ctx.note(f"cleanup: {abs(n)} test track(s) deleted on {NAMES[w]} (its big-deletion ask answered Yes)")
            elif n:
                ctx.note(f"cleanup: {abs(n)} test track(s) deleted on {NAMES[w]}")
        except Exception as e:
            ctx.note(f"cleanup on {NAMES[w]} failed: {e}")
    for attempt in range(2):
        end = time.time() + 90
        left = {}
        while time.time() < end:
            left = {}
            for w in ctx.on:
                try:
                    s = ctx.shape(w)
                except Exception:
                    continue
                if s:
                    left[w] = s
            if not left:
                return
            time.sleep(3)
        for w, s in left.items():  # (still there after 90 s: deleted where they are, so nothing is left behind)
            try:
                purge(ctx, w)
                _answer_cleanup_ask(ctx, w)
                ctx.note(f"cleanup: test tracks still on {NAMES[w]} after 90 s ({s[:120]}); deleted there")
            except Exception as e:
                ctx.note(f"cleanup on {NAMES[w]} failed: {e}")


# (run as a script, this module is __main__: the sets' `from live import Fail, Skip, ...` must get these very classes, or a set's Fail
# isn't caught as one and reads "error")
sys.modules.setdefault("live", sys.modules[__name__])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("up"); a.add_argument("--on", default="d,l,x"); a.add_argument("--song", default="LV Checks")
    a = sub.add_parser("eval"); a.add_argument("w"); a.add_argument("file"); a.add_argument("--timeout", type=int, default=30)
    a = sub.add_parser("sets")
    a = sub.add_parser("restart"); a.add_argument("--on", default="d,l,x")
    a = sub.add_parser("song"); a.add_argument("--on", default="d,l,x"); a.add_argument("--song", default="LV Checks")
    a.add_argument("--close", action="store_true")
    a = sub.add_parser("run"); a.add_argument("set"); a.add_argument("-k", action="append"); a.add_argument("--on", default="d,l,x")
    a.add_argument("--song"); a.add_argument("--report"); a.add_argument("--retries", type=int, default=1)
    args = ap.parse_args()
    return {"up": cmd_up, "eval": cmd_eval, "sets": cmd_sets, "run": cmd_run, "song": cmd_song, "restart": cmd_restart}[args.cmd](args) or 0


if __name__ == "__main__":
    sys.exit(main())
