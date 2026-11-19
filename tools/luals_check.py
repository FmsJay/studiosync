"""LuaLS (the Lua language server) over a snapshot of StudioSync's Lua: catches calls with the wrong number of arguments, operator
precedence slips and more that tools/free_names.py can't. Most of what it says at Warning level is noise for this code base
(need-check-nil, undefined-field on tables built at run time): read redundant-parameter, missing-parameter, ambiguity-1, undefined-global.
Needs lua-language-server on PATH (winget install LuaLS.lua-language-server) or in $LUALS. Round 1 review, 0.59.45.
usage: python tools/luals_check.py [Warning|Hint] [--gate]
--gate (tests/run.py): exit 1 when any of those kinds shows, and 0 with "skipped" when LuaLS isn't installed. Round 2 review, 0.59.46."""
import collections, json, os, pathlib, shutil, subprocess, sys, tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
EXE = os.environ.get("LUALS") or shutil.which("lua-language-server") or str(next(
    pathlib.Path(os.environ.get("LOCALAPPDATA", ".")).glob("Microsoft/WinGet/Packages/LuaLS.*/bin/lua-language-server.exe"), ""))
GATE = "--gate" in sys.argv
args = [a for a in sys.argv[1:] if a != "--gate"]
if not EXE or not pathlib.Path(EXE).exists():
    if GATE:
        print("skipped: lua-language-server isn't installed")
        sys.exit(0)
    sys.exit("lua-language-server not found: winget install LuaLS.lua-language-server, or set LUALS")
level = args[0] if args else "Warning"
work = pathlib.Path(tempfile.mkdtemp(prefix="luals-"))
src = work / "src"
(src / "lib").mkdir(parents=True)
for f in REPO.glob("StudioSync - *.lua"):
    shutil.copy(f, src / f.name)
for f in (REPO / "lib").glob("*.lua"):
    shutil.copy(f, src / "lib" / f.name)
cfg = work / "luarc.json"
cfg.write_text(json.dumps({"runtime.version": "Lua 5.4", "runtime.path": ["lib/?.lua", "?.lua"],
    "diagnostics.globals": ["reaper", "gfx", "BANDSYNC_AUTOSTART_STARTED", "BANDSYNC_LIVE_PROJ", "BANDSYNC_ENDED_AT", "STUDIOSYNC_PANEL_RELOAD"],
    "workspace.library": [], "workspace.checkThirdParty": False, "diagnostics.disable": ["lowercase-global"]}))
logs = work / "logs"
subprocess.run([EXE, f"--check={src}", f"--configpath={cfg}", f"--checklevel={level}", "--check_format=json", f"--logpath={logs}"],
               capture_output=True, timeout=600)
res = json.loads((logs / "check.json").read_text(encoding="utf-8")) if (logs / "check.json").exists() else {}
codes, rows = collections.Counter(), []
for uri, items in res.items():
    name = uri.split("/src/")[-1].replace("%20", " ")
    for d in items:
        codes[d["code"]] += 1
        rows.append((d["code"], name, d["range"]["start"]["line"] + 1, d["message"].splitlines()[0][:140]))
print("total", sum(codes.values()))
for c, n in codes.most_common():
    print(f"{n:5} {c}")
WORTH = ("redundant-parameter", "missing-parameter", "ambiguity-1", "undefined-global", "count-down-loop", "duplicate-index")
for c, n, l, m in sorted(rows):
    if c in WORTH:
        print(f"  {c}  {n}:{l}  {m}")
out = pathlib.Path(tempfile.gettempdir()) / f"studiosync_luals_{level}.txt"
out.write_text("\n".join(f"{c}\t{n}:{l}\t{m}" for c, n, l, m in sorted(rows)), encoding="utf-8")
print("all of it:", out)
shutil.rmtree(work, ignore_errors=True)
worth = sum(1 for c, *_ in rows if c in WORTH)
if GATE:
    print(f"{worth} worth reading" if worth else "none worth reading")
    sys.exit(1 if worth else 0)
