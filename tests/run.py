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
for f in sorted(glob.glob("tests/*.lua")):
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
steps = [("tools/compile_check.py", True), ("tools/free_names.py", True), ("tests/check_locals.py", True), ("tools/files_check.py", release)]
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
