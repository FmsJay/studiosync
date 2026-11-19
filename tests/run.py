"""Every offline check, from anywhere: python tests/run.py
Runs each tests/*.lua in its own Lua 5.4 (lupa), which passes only when its last printed line starts with "ok", then tools/compile_check.py,
tools/free_names.py and tests/check_locals.py. Exits non-zero if anything fails. (Round 1 review, 0.59.45: the runner lived outside the repo.)"""
import glob, os, subprocess, sys
import lupa

os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
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
for tool in ("tools/compile_check.py", "tools/free_names.py", "tests/check_locals.py"):
    r = subprocess.run([sys.executable, tool], capture_output=True, text=True)
    last = (r.stdout.strip().splitlines() or [""])[-1]
    print(tool, "ok" if r.returncode == 0 else "FAIL", last)
    if r.returncode != 0:
        fails += 1
        print(r.stdout[-2000:], r.stderr[-1000:])
print("fails", fails)
sys.exit(1 if fails else 0)
