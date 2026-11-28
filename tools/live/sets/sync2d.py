"""rt-sync2d's REAPER checks for James (docs/rt/rt-sync2d.md, 10 checks): folders as parent + rank, on the desktop (d), laptop (l) and LinuxBox (x)."""
import time
from live import scenario, Skip, Fail, NoAnswer, lua_str, NAMES
from sets._lv import B, USER, SONG, setup, T, names, add, order, quiet_order, ask_of, answer, ss_undo, log_has, sleep, x_syncthing, x_cut

SETTLE = 17  # past presence.HOLD (15 s)
SWS_INDENT, SWS_UNINDENT = "_SWS_INDENT", "_SWS_UNINDENT"


def _action(ctx, w, shorts, named):
    return ctx.do(w, f"""
local id = reaper.NamedCommandLookup({lua_str(named)})
if id == 0 then error("no action " .. {lua_str(named)} .. " here (SWS missing?)", 0) end
LV.action_on(P, {names(ctx, *shorts)}, id)
return LV.out(true)""")


def _valid(ctx, w):
    """REAPER's folders on w read as a valid tree: depths never below 0, and the song ends at depth 0."""
    s = ctx.state(w)
    d, ok = 0, True
    for t in s["tracks"]:
        d += t["depth"]
        if d < 0:
            ok = False
    return ok and d <= 0


@scenario("d1 switch-over to parents (logs)", "sync2d 1", needs=("d", "x"), wants=("l",))
def parent_switch(ctx):
    for w in ctx.on:
        lines = ctx.do(w, """
local band = LV.lib(); local dir = band.log_dir(); local out = {}
reaper.EnumerateFiles(dir, -1)
local i = 0
while true do local f = reaper.EnumerateFiles(dir, i); if not f then break end; i = i + 1
  local h = io.open(dir .. "/" .. f); if h then for l in h:lines() do if l:find("given their folder as a parent", 1, true) then out[#out+1] = f:match("%d+%-%d+%-%d+") .. " " .. l:sub(1, 70) end end h:close() end end
return LV.out(out)""")
        ctx.note(f"{NAMES[w]}: {len(lines)} line(s) " + "; ".join(lines[:4]))
    # live part: the switch-over is long done on every computer, so new tracks made now must not say it again
    marks = ctx.log_marks()
    add(ctx, "d", "New1", "New2")
    add(ctx, B(ctx), "New3")
    ctx.quiet()
    sleep(45)
    again = {w: [l for l in ctx.log_since(w, marks) if "given their folder as a parent" in l] for w in ctx.on}
    for w, ls in again.items():
        ctx.note(f"{NAMES[w]} after 3 new tracks: " + ("; ".join(ls) or "nothing"))
    said = [NAMES[w] for w, ls in again.items() if ls]
    ctx.check(not said, f"the switch-over line came again for new tracks on {', '.join(said)} (expected once, at the update)")


@scenario("d2 into and out of a folder", "sync2d 2", needs=("d", "x"), wants=("l",))
def into_out(ctx):
    add(ctx, "d", "Bass", "Gtr", "Keys")
    ctx.quiet()
    ctx.do("d", f"LV.into_folder(P, {names(ctx, 'Gtr')}, {lua_str(T(ctx, 'Bass'))}) return LV.out(true)")
    got = quiet_order(ctx)
    ctx.check(got == ["Bass", "Gtr<Bass", "Keys"], f"Gtr into Bass: {got}")
    sleep(SETTLE)
    ctx.do("d", f"LV.out_of_folder(P, {names(ctx, 'Gtr')}, {lua_str(T(ctx, 'Keys'))}) return LV.out(true)")
    got = quiet_order(ctx)
    ctx.check(got == ["Bass", "Gtr", "Keys"], f"Gtr out again: {got}")
    sleep(SETTLE)
    # REAPER has no indent action of its own; SWS's "Indent selected track(s)" / "Unindent" are what a person binds
    _action(ctx, "d", ["Keys"], SWS_INDENT)
    got = quiet_order(ctx)
    ctx.note(f"after SWS Indent on Keys: {got}")
    ctx.check(any(o.startswith("Keys<") for o in got), f"indent: {got}")
    sleep(SETTLE)
    _action(ctx, "d", ["Keys"], SWS_UNINDENT)
    got = quiet_order(ctx)
    ctx.check(not any("<" in o for o in got), f"unindent: {got}")


@scenario("d3 a folder change landing in pieces", "sync2d 3", needs=("d", "x"), wants=("l",))
def in_pieces(ctx):
    add(ctx, "d", "Bus", "A", "B", "Other")
    ctx.quiet()
    sleep(SETTLE)
    marks = ctx.log_marks(["x"])
    t0 = int(time.time())
    # LinuxBox stands in for "the laptop's Syncthing paused": its Syncthing paused and its direct link cut, inside the VM
    ctx.check(x_syncthing(True), "couldn't pause LinuxBox's Syncthing")
    x_cut(True)
    ctx.cleanups.append(lambda: (x_cut(False), x_syncthing(False)))
    try:
        ctx.do("d", f"LV.into_folder(P, {names(ctx, 'A', 'B')}, {lua_str(T(ctx, 'Bus'))}) return LV.out(true)")
        ctx.check(order(ctx, "d") == ["Bus", "A<Bus", "B<Bus", "Other"], f"the desktop's drag: {order(ctx, 'd')}")
        sleep(20)
        ctx.check(order(ctx, "x") == ["Bus", "A", "B", "Other"], f"LinuxBox changed while cut off: {order(ctx, 'x')}")
    finally:
        x_cut(False)
        x_syncthing(False)
    seen, end = [], time.time() + 90
    while time.time() < end:
        o = order(ctx, "x")
        if not seen or seen[-1] != o:
            seen.append(o)
        if o == ["Bus", "A<Bus", "B<Bus", "Other"]:
            break
        time.sleep(0.3)
    ctx.note("LinuxBox's orders on the way: " + " -> ".join(",".join(s) for s in seen))
    bad = [s for s in seen if "Other<Bus" in s or not all(x in ("Bus", "A", "B", "Other", "A<Bus", "B<Bus") for x in s)]
    ctx.check(seen[-1] == ["Bus", "A<Bus", "B<Bus", "Other"], f"LinuxBox didn't end with both inside Bus: {seen[-1]}")
    ctx.check(not bad, f"a track jumped into another folder on the way: {bad}")
    ev = ctx.do("x", f"return LV.out(LV.events_since(SONG, 'LinuxBox', {t0}))")
    ctx.check(not ev, f"LinuxBox sent changes of its own: {[e.get('name') for e in ev]}")
    ctx.quiet()


@scenario("d4 two folder moves at once", "sync2d 4", needs=("d", "x"), wants=("l",))
def loop(ctx):
    add(ctx, "d", "Keys", "Bass", "Other")
    ctx.quiet()
    sleep(SETTLE)
    ctx.at_once({
        "d": f"LV.into_folder(P, {names(ctx, 'Keys')}, {lua_str(T(ctx, 'Bass'))}) return true",
        B(ctx): f"LV.into_folder(P, {names(ctx, 'Bass')}, {lua_str(T(ctx, 'Keys'))}) return true",
    })
    got = quiet_order(ctx, timeout=120)
    ctx.note(f"all three: {got}")
    ctx.check(got in (["Bass", "Keys<Bass", "Other"], ["Keys", "Bass<Keys", "Other"]), f"not one inside the other: {got}")
    for w in ctx.on:
        ctx.check(_valid(ctx, w), f"{NAMES[w]}'s folder depths aren't a valid tree")
    sleep(60)
    later = quiet_order(ctx)
    ctx.check(later == got, f"changed within a minute: {got} -> {later}")


@scenario("d5 folder moved while a child leaves", "sync2d 5", needs=("d", "x"), wants=("l",))
def move_vs_child(ctx):
    add(ctx, "d", "Top", "Bus", "Kid1", "Kid2", "End")
    ctx.do("d", f"LV.into_folder(P, {names(ctx, 'Kid1', 'Kid2')}, {lua_str(T(ctx, 'Bus'))}) return LV.out(true)")
    ctx.check(quiet_order(ctx) == ["Top", "Bus", "Kid1<Bus", "Kid2<Bus", "End"], "the folder")
    sleep(SETTLE)
    ctx.at_once({
        "d": f"LV.move_tracks(P, {names(ctx, 'Bus', 'Kid1', 'Kid2')}, {lua_str(T(ctx, 'Top'))}) return true",
        B(ctx): f"LV.out_of_folder(P, {names(ctx, 'Kid2')}, nil) return true",
    })
    got = quiet_order(ctx, timeout=120)
    ctx.note(f"all three end with: {got}")
    for w in ctx.on:
        ctx.check(_valid(ctx, w), f"{NAMES[w]}'s folder depths aren't a valid tree")


@scenario("d6 a take on a folder track", "sync2d 6", needs=("d", "x"), wants=("l",))
def take_on_folder(ctx):
    add(ctx, "d", "Bus", "Kid", "New")
    ctx.do("d", f"LV.into_folder(P, {names(ctx, 'Kid')}, {lua_str(T(ctx, 'Bus'))}) return LV.out(true)")
    ctx.quiet()
    sleep(SETTLE)
    ctx.at_once({
        "d": f"LV.record_take(P, {lua_str(T(ctx, 'Bus'))}, 1, 3, 'fold') return true",
        B(ctx): f"LV.into_folder(P, {names(ctx, 'New')}, {lua_str(T(ctx, 'Bus'))}) return true",
    })
    got = quiet_order(ctx, timeout=150)
    ctx.check(got == ["Bus", "Kid<Bus", "New<Bus"], f"the folder after both: {got}")
    sh = ctx.shape("x")
    ctx.check("1.00+3.00" in sh and "~" not in sh, f"the take on the folder track: {sh}")


@scenario("d7 Undo into a folder; rename inside", "sync2d 7", needs=("d", "x"), wants=("l",))
def undo_folder(ctx):
    add(ctx, "d", "Bus", "Kid", "Gtr")
    ctx.do("d", f"LV.into_folder(P, {names(ctx, 'Kid')}, {lua_str(T(ctx, 'Bus'))}) return LV.out(true)")
    ctx.quiet()
    sleep(SETTLE)
    ctx.do("d", f"LV.into_folder(P, {names(ctx, 'Gtr')}, {lua_str(T(ctx, 'Bus'))}) return LV.out(true)")
    ctx.check(quiet_order(ctx) == ["Bus", "Kid<Bus", "Gtr<Bus"], "the drag in")
    sleep(5)
    ss_undo(ctx, "d")
    got = quiet_order(ctx)
    ctx.check(got == ["Bus", "Kid<Bus", "Gtr"], f"StudioSync's Undo: {got}")
    sleep(5)
    ss_undo(ctx, "d", redo=True)
    got = quiet_order(ctx)
    ctx.check(got == ["Bus", "Kid<Bus", "Gtr<Bus"], f"StudioSync's Redo: {got}")
    sleep(SETTLE)
    ctx.do("d", f"LV.rename(P, {lua_str(T(ctx, 'Kid'))}, {lua_str(T(ctx, 'Kid2'))}) return LV.out(true)")
    ctx.check(quiet_order(ctx) == ["Bus", "Kid2<Bus", "Gtr<Bus"], "the rename")
    sleep(5)
    ss_undo(ctx, "d")
    got = quiet_order(ctx)
    ctx.check(got == ["Bus", "Kid<Bus", "Gtr<Bus"], f"Undo of the rename: {got}")


@scenario("d8 an old-version computer", "sync2d 8", needs=())
def old_version(ctx):
    raise Skip("not applicable: James's decision of 11-27 (no old-version compatibility; StudioSync only on his computers)")


# check 9 (the big-deletion floor) runs in the sync2c set: "c4 ..." scenarios


@scenario("d10 REAPER's depths after a folder drag", "sync2d 10", needs=("d",))
def reaper_depths(ctx):
    add(ctx, "d", "Above", "Bus", "K1", "K2", "After")
    ctx.do("d", f"LV.into_folder(P, {names(ctx, 'K1', 'K2')}, {lua_str(T(ctx, 'Bus'))}) return LV.out(true)")
    sleep(5)
    # what a drag of the folder track alone does: ReorderSelectedTracks with only the folder selected, up past "Above"
    r = ctx.do("d", f"""
local function depths() local o = {{}} for k = 0, reaper.CountTracks(P) - 1 do local t = reaper.GetTrack(P, k); local n = select(2, reaper.GetTrackName(t))
  if n:sub(1, {len(ctx.prefix)}) == {lua_str(ctx.prefix)} then o[#o+1] = n:sub({len(ctx.prefix) + 1}) .. "=" .. math.floor(reaper.GetMediaTrackInfo_Value(t, "I_FOLDERDEPTH")) end end return table.concat(o, " ") end
local before = depths()
LV.move_tracks(P, {names(ctx, 'Bus')}, {lua_str(T(ctx, 'Above'))})
return LV.out({{ before = before, after = depths() }})""")
    ctx.note(f"before: {r['before']}; after dragging Bus alone up past Above: {r['after']}")
    sleep(8)
    ctx.note(f"a moment later (StudioSync's pass): {order(ctx, 'd')}")
