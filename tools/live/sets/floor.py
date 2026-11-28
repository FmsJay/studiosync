"""rt-floor's Live checks (docs/rt/rt-floor.md "Live checks", 6 scenarios): the studio's version floor. Needs every computer on the
floor build (0.62.0 or later: sync.LEVEL exists); refuses to run otherwise. A test floor file is never left behind: each scenario that
writes one deletes it in a clean-up, and every setup deletes a stray one first (a stray floor file stops everyone sending)."""
import json, time, urllib.request
from live import scenario, Skip, Fail, NoAnswer, lua_str, NAMES
from sets._lv import B, USER, SONG, T, names, add, order, quiet_order, sleep
from sets import _lv

TEST_FLOOR = "99-livecheck.json"  # (a test floor far above any real level: it puts every computer below it)
CUR = {"level": 11}  # (the computers' own sync.LEVEL, read in setup)


def _floor_file_lua(op):
    return f"""
local root = LV.studio_root(); local dir = root .. "/_band/floor"; local f = dir .. "/{TEST_FLOOR}"
{op}
return LV.out(reaper.file_exists(f))"""


def drop_test_floor(ctx):
    """Delete the test floor file (on the desktop: Syncthing carries the deletion), and wait until no computer has it."""
    ctx.raw("d", _floor_file_lua("os.remove(f)"))
    end = time.time() + 60
    while time.time() < end:
        if not any(ctx.raw(w, _floor_file_lua("")) for w in ctx.on):
            return
        time.sleep(2)
    for w in ctx.on:  # (still there after a minute: deleted where it is)
        ctx.raw(w, _floor_file_lua("os.remove(f)"))


def setup(ctx):
    for w in ctx.on:
        lv = ctx.raw(w, "LV.lib(); return LV.out(require('sync').LEVEL or 0)")
        if not lv or lv < 11:
            raise NoAnswer(f"{NAMES[w]}: not on the floor build (sync.LEVEL {lv}): run this set once 0.62.0 is deployed and every REAPER restarted")
        CUR["level"] = lv
    drop_test_floor(ctx)
    _lv.setup(ctx)


def floor_of(ctx, w):
    return ctx.do(w, """local band = LV.lib(); local sync = require("sync")
local cfg = { root = LV.studio_root(), user = reaper.GetExtState("BandSync", "user") }
local f = sync.floor_read(cfg, true); return LV.out({ level = f.level, since = f.since, below = f.below })""")


def events_since(ctx, w, t0):
    """Every event in the room since t0 (any user): [{ id, user, name, auto, lv, obj }]."""
    return ctx.do(w, f"""
local dir = LV.studio_root() .. "/" .. SONG .. "/rooms/main/events"
local mark = os.date("!%Y%m%d-%H%M%SZ", {int(t0)})
reaper.EnumerateFiles(dir, -1)
local out, i = {{}}, 0
while true do local f = reaper.EnumerateFiles(dir, i); if not f then break end; i = i + 1
  local stamp = f:match("%-(%d%d%d%d%d%d%d%d%-%d%d%d%d%d%dZ)%-")
  if stamp and stamp >= mark then
    local h = io.open(dir .. "/" .. f); local s = h and h:read("a") or ""; if h then h:close() end
    out[#out+1] = {{ id = f, user = f:match("^(.-)%-%d%d%d%d%d%d%d%d%-"), name = s:match('"name"%s*:%s*"([^"]*)"'),
      auto = s:find('"auto"%s*:%s*true') ~= nil, lv = tonumber(s:match('"lv"%s*:%s*(%d+)')), obj = s:match('"obj"%s*:%s*"([^"]*)"') }}
  end
end
return LV.out(out)""")


@scenario("f1 the floor is recorded", "rt-floor 1", needs=("d", "x"), wants=("l",))
def recorded(ctx):
    fs = {w: floor_of(ctx, w) for w in ctx.on}
    files = ctx.do("d", """local dir = LV.studio_root() .. "/_band/floor"; local o = {}; reaper.EnumerateFiles(dir, -1)
local i = 0; while true do local f = reaper.EnumerateFiles(dir, i); if not f then break end; i = i + 1
  local h = io.open(dir .. "/" .. f); o[#o+1] = f .. " " .. (h and h:read("a"):gsub("%s+", " ") or ""); if h then h:close() end end
return LV.out(o)""")
    ctx.note("floor files: " + "; ".join(files))
    for w, f in fs.items():
        ctx.note(f"{NAMES[w]}: level {f['level']}, below {f['below']}, since {f['since']}")
    ctx.check(any(x.startswith(f"{CUR['level']}-") for x in files), f"no {CUR['level']}-<user>.json in _band/floor")
    ctx.check(all(f["level"] == CUR["level"] and f["below"] is False for f in fs.values()), f"not level {CUR['level']} / not at the floor everywhere")
    ctx.check(len({f["since"] for f in fs.values()}) == 1, "the computers read different 'since' times")


@scenario("f2 updating sends nothing", "rt-floor 2", needs=("d", "x"), wants=("l",))
def updating_quiet(ctx):
    t0 = time.time()
    sleep(120)
    ev = events_since(ctx, "d", t0)
    ctx.note(f"{len(ev)} event(s) in 120 s with nobody editing: " + "; ".join(f"{e['user']} {e['obj']} {e['name']} auto={e['auto']}" for e in ev[:10]))
    bad = [e for e in ev if e.get("obj") == "track" and not e.get("auto")]
    ctx.check(not bad, f"track versions without auto: {[(e['user'], e['name']) for e in bad]}")


@scenario("f3 below the floor: nothing out, nothing lost", "rt-floor 3", needs=("d", "x"), wants=("l",))
def below(ctx):
    add(ctx, "d", "Gtr", "Keys")
    ctx.quiet()
    sleep(17)
    ctx.cleanups.append(lambda: drop_test_floor(ctx))
    marks = ctx.log_marks()
    ctx.raw("d", _floor_file_lua(f'reaper.RecursiveCreateDirectory(dir, 0); local h = assert(io.open(f, "w")); h:write(\'{{ "level": 99, "since": "{time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}" }}\'); h:close()'))
    for w in ctx.on:
        ctx.wait(f"{NAMES[w]} below the floor", lambda w=w: floor_of(ctx, w)["below"], timeout=60)
    sleep(12)
    for w in ctx.on:
        said = [l for l in ctx.log_since(w, marks) if "older than the studio" in l]
        ctx.check(said, f"{NAMES[w]}'s log doesn't say it is older than the studio's")
    # (Health's rows are rebuilt on their own beat, not at once: wait for the row as f6 does, up to 60 s)
    ctx.wait("the desktop's web page's 'update floor' Health row",
             lambda: "update floor" in json.dumps(json.load(urllib.request.urlopen("http://127.0.0.1:47281/api/state", timeout=10))), timeout=60)
    t1 = time.time()
    ctx.do("d", f"LV.rename(P, {lua_str(T(ctx, 'Gtr'))}, {lua_str(T(ctx, 'Gtr floor'))}) return LV.out(true)")
    ctx.do(B(ctx), f"LV.rename(P, {lua_str(T(ctx, 'Keys'))}, {lua_str(T(ctx, 'Keys floor'))}) return LV.out(true)")
    sleep(15)
    ev = [e for e in events_since(ctx, "d", t1) if (e.get("name") or "").startswith(ctx.prefix)]
    ctx.check(not ev, f"events written while below the floor: {[(e['user'], e['name']) for e in ev]}")
    m2 = ctx.log_marks(["d"])
    ctx.do("d", "LV.run_script('StudioSync - Undo.lua') return LV.out(true)", timeout=40)
    sleep(3)
    nd = [l for l in ctx.log_since("d", m2) if "Not done" in l]
    ctx.check(nd, "StudioSync's Undo below the floor didn't say 'Not done: ...'")
    drop_test_floor(ctx)
    ctx.wait("both renames everywhere", lambda: all(set(order(ctx, w)) == {"Gtr floor", "Keys floor"} for w in ctx.on), timeout=90)
    ev = [e for e in events_since(ctx, "d", t1) if (e.get("name") or "").startswith(ctx.prefix)]
    ctx.note("after the floor went: " + "; ".join(f"{e['user']} {e['name']} lv={e['lv']}" for e in ev))
    ctx.check(all(e.get("lv") == CUR["level"] for e in ev) and {e["user"] for e in ev} >= {"James", USER[B(ctx)]}, f"not one lv-{CUR['level']} event each from both")


@scenario("f4 a change made below the floor is held", "rt-floor 4", needs=("d", "x"), wants=("l",))
def held(ctx):
    add(ctx, "d", "Bass")
    ctx.quiet()
    t0 = time.time()
    made = ctx.do("d", f"""
local dir = LV.studio_root() .. "/" .. SONG .. "/rooms/main/events"
local band = LV.lib()
local best
reaper.EnumerateFiles(dir, -1)
local i = 0; while true do local f = reaper.EnumerateFiles(dir, i); if not f then break end; i = i + 1
  local h = io.open(dir .. "/" .. f); local s = h and h:read("a") or ""; if h then h:close() end
  if s:find('"name"%s*:%s*"' .. ({lua_str(T(ctx, 'Bass'))}):gsub("%p", "%%%0") .. '"') and (not best or f > best) then best = f end end
if not best then error("no event for the Bass track", 0) end
local ev = band.read_json(dir .. "/" .. best)
local id = "LiveCheck-" .. os.date("!%Y%m%d-%H%M%S") .. "Z-00001-0001"
ev.user, ev.id, ev.base, ev.base_ev, ev.rev = "LiveCheck", id, ev.rev, ev.id, (tonumber(ev.rev) or 0) + 1
ev.state.name, ev.lv, ev.time = {lua_str(T(ctx, 'Bass HELD'))}, 10, os.date("!%Y-%m-%dT%H:%M:%SZ")
band.write_json(dir .. "/" .. id .. ".json", ev)
return LV.out(id)""")
    path = f"{SONG}/rooms/main/events/{made}.json"
    ctx.cleanups.append(lambda: ctx.raw("d", f"os.remove(LV.studio_root() .. '/' .. {lua_str(path)}) return LV.out(true)"))
    marks = ctx.log_marks()
    sleep(30)
    for w in ctx.on:
        o = order(ctx, w)
        applied = ctx.do(w, f"return LV.out(select(2, reaper.GetProjExtState(P, 'BandSync.applied', {lua_str(made)})))")
        said = [l for l in ctx.log_since(w, marks) if "LiveCheck's StudioSync is older" in l]
        ctx.note(f"{NAMES[w]}: {o}, applied '{applied}', log {len(said)} line(s)")
        ctx.check("Bass HELD" not in o and applied in ("", None), f"{NAMES[w]} took the held change")
        ctx.check(said, f"{NAMES[w]}'s log doesn't say LiveCheck's StudioSync is older")


@scenario("f5 two folder moves at once, no write-back", "rt-floor 5", needs=("d", "x"), wants=("l",))
def folder_loop(ctx):
    add(ctx, "d", "Keys", "Bass", "Other")
    ctx.quiet()
    sleep(17)
    t0 = time.time()
    ctx.at_once({
        "d": f"LV.into_folder(P, {names(ctx, 'Keys')}, {lua_str(T(ctx, 'Bass'))}) return true",
        B(ctx): f"LV.into_folder(P, {names(ctx, 'Bass')}, {lua_str(T(ctx, 'Keys'))}) return true",
    })
    sleep(60)
    got = quiet_order(ctx)
    ctx.note(f"all: {got}")
    ctx.check(got in (["Bass", "Keys<Bass", "Other"], ["Keys", "Bass<Keys", "Other"]), f"not one inside the other: {got}")
    auto = [e for e in events_since(ctx, "d", t0) if e.get("auto") and (e.get("name") or "").startswith(ctx.prefix)]
    ctx.note("auto versions in that minute: " + "; ".join(f"{e['user']} {e['name']}" for e in auto))
    ctx.check(not [e for e in auto if e["user"] != "James"], f"an auto version from a computer that isn't the tracks' maker: {auto}")


@scenario("f6 web Health shows the floor", "rt-floor 6", needs=("d",), wants=("l", "x"))
def web_health(ctx):
    ctx.cleanups.append(lambda: drop_test_floor(ctx))
    ctx.raw("d", _floor_file_lua(f'reaper.RecursiveCreateDirectory(dir, 0); local h = assert(io.open(f, "w")); h:write(\'{{ "level": 99, "since": "{time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}" }}\'); h:close()'))
    def row():
        s = json.load(urllib.request.urlopen("http://127.0.0.1:47281/api/state", timeout=10))
        txt = json.dumps(s)
        return ("update floor" in txt and "Update StudioSync" in txt) and txt
    ctx.wait("the web page's 'update floor' row with its button", row, timeout=60)
