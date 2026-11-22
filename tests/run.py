"""Every offline check, from anywhere: python tests/run.py [--release] [--no-luals]
Runs each tests/*.lua in its own Lua 5.4 (lupa), which passes only when its last printed line starts with "ok", then tools/compile_check.py,
tools/free_names.py and tests/check_locals.py. Exits non-zero if anything fails. (Round 1 review, 0.59.45: the runner lived outside the repo.)
Round 2 review, 0.59.46: also tools/files_check.py (lib/files.txt against the code: only noted while working, a failure with --release, as the
list is made at release by tools/make_index.py), and LuaLS through tools/luals_check.py --gate when it's installed (skipped otherwise, or with
--no-luals: it takes a minute)."""
import glob, os, subprocess, sys
import lupa.lua54 as lupa  # (REAPER embeds Lua 5.4; plain lupa is 5.5 here. Round 3 review, 0.59.48)

os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
release, luals = "--release" in sys.argv, "--no-luals" not in sys.argv
fails = 0


# A guard on the whole run (2026-11-21): a test that grows without end took 22 GB of RAM and 32 GB committed on the desktop and,
# with an earlier one at 40 GB on 11-20, starved the PC into a restart. Every second a watcher reads this process's memory; past
# MEM_CAP_MB (default 4096, env STUDIOSYNC_TEST_MEM_MB) or one test past TEST_SECS (default 300, env STUDIOSYNC_TEST_SECS) it says
# which test and ends the run at once (exit 2). Lua can't be interrupted from Python, so ending the process is the only safe stop.
MEM_CAP_MB = int(os.environ.get("STUDIOSYNC_TEST_MEM_MB", "4096"))
TEST_SECS = float(os.environ.get("STUDIOSYNC_TEST_SECS", "300"))
_now = {"test": "(starting)", "at": 0.0}


def _mem_mb():
    try:
        import psutil
        return psutil.Process().memory_info().rss / 1048576
    except Exception:
        pass
    try:  # Linux
        with open("/proc/self/statm") as fh:
            return int(fh.read().split()[1]) * os.sysconf("SC_PAGE_SIZE") / 1048576
    except Exception:
        pass
    try:  # macOS: the peak, in bytes there
        import resource
        return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1048576
    except Exception:
        return 0.0


def _watch():
    while True:
        time.sleep(1)
        mb, took = _mem_mb(), (time.monotonic() - _now["at"]) if _now["at"] else 0.0
        if mb > MEM_CAP_MB or took > TEST_SECS:
            why = "%.0f MB of memory (cap %d)" % (mb, MEM_CAP_MB) if mb > MEM_CAP_MB else "%.0f s on one test (limit %.0f)" % (took, TEST_SECS)
            print(_now["test"], "FAIL: stopped the whole run at", why, flush=True)
            print("fails", fails + 1, flush=True)
            os._exit(2)


import threading, time
threading.Thread(target=_watch, daemon=True).start()
for f in sorted(glob.glob("tests/*.lua")) + sorted(glob.glob("addons/*/tests/*.lua")):  # (and the optional add-ons' own: addons/ai, 2026-11-19)
    _now["test"], _now["at"] = f, time.monotonic()
    L = lupa.LuaRuntime()
    out = []
    L.globals().print = lambda *a: out.append(" ".join(str(x) for x in a))
    try:
        L.execute(open(f, encoding="utf-8").read())
        if out and out[-1].startswith("ok"):
            print(f, "ok")
        else:
            fails += 1
            print(f, "FAIL: its last line isn't ok:", out[-1:])
    except Exception as e:
        fails += 1
        print(f, "FAIL", str(e)[:300])
steps = [("-m unittest discover -q -s addons/ai/tests", True), ("-m unittest discover -q -s tools/ears", True), ("tools/compile_check.py", True), ("tools/free_names.py", True), ("tests/check_locals.py", True), ("tools/js_check.py", True), ("tools/files_check.py", release), ("tools/soak/soak.py --quick", True)]  # convergence soak: three computers on the real sync code (docs/rt/rt-soak.md); ~60 s
if luals:
    steps.append(("tools/luals_check.py Warning --gate", True))
for step, fatal in steps:
    r = subprocess.run([sys.executable] + step.split(" "), capture_output=True, text=True)
    last = (r.stdout.strip().splitlines() or [""])[-1]
    print(step, "ok" if r.returncode == 0 else ("FAIL" if fatal else "NOTE"), last)
    if r.returncode != 0 and fatal:
        fails += 1
        print(r.stdout[-2000:], r.stderr[-1000:])
print("fails", fails)
sys.exit(1 if fails else 0)
