"""rt-sync2j's Live checks (docs/rt/rt-sync2j.md): rt-sync2 phase 8 (Health compares contents, drift here) and two loose ends.
j1 reads each computer's status file in the room: their content codes agree at quiet. j2 makes the test-only fault on the bandmate's computer
(its REAPER item moved and its record taking that for the version held, in one script step: mirror.test_drift) and waits for Live sync's look
to put the studio's version back, with nothing sent and the line said once. j3 restarts both REAPERs (live.py restart: never saving) and reads
the desktop's log since: no "skipped a change ... that StudioSync can't read". j4 restores the whole project, on the desktop, to just before
its own two changes, through History's page functions, and checks the slices' count is what the Restore ends saying. j1 and j2 need this
build on both computers (mirror.contents, mirror.test_drift): on 0.65.3 they stop at once and say so. Nothing is saved."""
import re, time
from live import scenario, Fail, Skip, lua_str, NAMES
from sets._lv import SONG, B, T, add, sleep, log_has
from sets.sync2i import new_item, item, both, history
from sets.sync2h import restart_both

SETTLE = 17  # presence.HOLD is 15 s: a bandmate's edit to what someone changed in the last 15 s is put back by design


def needs_build(ctx, w, fn):
    if not ctx.do(w, f"local band = LV.lib(); return LV.out(require('mirror').{fn} ~= nil)"):
        raise Skip(f"{NAMES[w]}'s StudioSync has no mirror.{fn} (rt-sync2j's build isn't deployed there)")


def statuses(ctx, w):
    """The room's status files as w reads them: user -> { content, bk, pending, mirror }."""
    return ctx.do(w, "local band = LV.lib(); local cfg, b = band.settings(), band.binding(P)\n"
                     "local dir = require('sync').room_dir(cfg, b.song, b.room) .. '/status'; local out = {}\n"
                     "for _, f in ipairs(band.files(dir, '.json')) do local st = band.read_json(dir .. '/' .. f)\n"
                     "  if type(st) == 'table' and st.user then out[st.user] = { content = st.content or '', bk = st.bk or '', pending = st.pending or -1, mirror = st.mirror or '', time = st.time or '' } end end\n"
                     "return LV.out(out)")


@scenario("j1 content codes agree at quiet", "rt-sync2j 5c", needs=("d", "x"))
def contents_agree(ctx):
    for w in ctx.on:
        needs_build(ctx, w, "contents")
    add(ctx, "d", "C")
    new_item(ctx, "d", "C", 2)
    both(ctx, ("C", "the item on every computer"), lambda x: x and abs(x["p"] - 2) < 1e-6)
    ctx.quiet()
    last = {}

    def agree():
        nonlocal last
        last = statuses(ctx, "d")
        mine = [last.get(u) for u in ("James", "LinuxBox")]
        return all(m and m["content"] and m["pending"] == 0 for m in mine) and mine[0]["content"] == mine[1]["content"] and mine[0]["bk"] == mine[1]["bk"]
    try:
        ctx.wait("the desktop's and LinuxBox's content codes and buckets the same, both caught up", agree, timeout=60, every=3)
    except Fail:
        raise Fail("content codes differ at quiet: " + "; ".join(f"{u} {v.get('content')} pending {v.get('pending')}" for u, v in last.items()))
    ctx.note("content code at quiet: " + last["James"]["content"])


@scenario("j2 drift here is found, put back and said once", "rt-sync2j 5c", needs=("d", "x"))
def drift_here(ctx):
    bm = B(ctx)
    for w in ctx.on:
        needs_build(ctx, w, "test_drift")
    add(ctx, "d", "D")
    new_item(ctx, "d", "D", 3)
    oid = both(ctx, ("D", "the item, with its id, on every computer"), lambda x: x and abs(x["p"] - 3) < 1e-6 and x["oid"])["d"]["oid"]
    ctx.quiet()
    sleep(SETTLE)
    marks = ctx.log_marks()
    sent_before = ctx.do("d", "local band = LV.lib(); local cfg, b = band.settings(), band.binding(P)\n"
                              "local n = 0; for _, e in ipairs(require('recall').entries(cfg, b.song, b.room)) do if e.oid == " + lua_str(oid) + " then n = n + 1 end end\n"
                              "return LV.out(n)")
    # (the fault, in one step: Live sync's look can't run between the move and the record)
    made = ctx.do(bm, f"local band = LV.lib(); local cfg, b = band.settings(), band.binding(P)\n"
                      f"local t = LV.track(P, {lua_str(T(ctx, 'D'))}); local it = t and reaper.GetTrackMediaItem(t, 0)\n"
                      "if not it then return LV.out('no item') end\n"
                      "reaper.SetMediaItemInfo_Value(it, 'D_POSITION', 6); reaper.UpdateArrange()\n"
                      f"local ok = require('mirror').test_drift(P, {lua_str(oid)}, require('sync').room_dir(cfg, b.song, b.room),\n"
                      "  select(2, reaper.GetProjExtState(P, band.SECTION, 'local_mix')) == '1')\n"
                      "return LV.out(ok and 'made' or 'not made')")
    ctx.check(made == "made", f"the fault wasn't made on {NAMES[bm]}: {made}")
    took = time.time()
    both(ctx, ("D", f"{NAMES[bm]}'s item back at 3 s (the studio's version), the desktop's never moved"), lambda x: x and abs(x["p"] - 3) < 1e-6, timeout=90)
    ctx.note(f"put back {time.time() - took:.1f} s after the fault")
    sleep(10)
    said = log_has(ctx, bm, marks, "wasn't the studio's version of it")
    ctx.note(f"{NAMES[bm]}'s log: " + (" | ".join(l[9:200] for l in said) or "(nothing)"))
    ctx.check(len(said) == 1, f"{NAMES[bm]} said it {len(said)} times, not once")
    sent_after = ctx.do("d", "local band = LV.lib(); local cfg, b = band.settings(), band.binding(P)\n"
                             "local n = 0; for _, e in ipairs(require('recall').entries(cfg, b.song, b.room)) do if e.oid == " + lua_str(oid) + " then n = n + 1 end end\n"
                             "return LV.out(n)")
    ctx.check(sent_after == sent_before, f"something was sent for the item ({sent_before} -> {sent_after} changes in History)")


@scenario("j3 the restart log is quiet", "rt-sync2j task 2.1", needs=("d", "x"))
def restart_quiet(ctx):
    marks = ctx.log_marks()
    restart_both(ctx)
    sleep(20)
    lines = log_has(ctx, "d", marks, "that StudioSync can't read")
    ctx.note(f"desktop: {len(lines)} 'can't read' line(s) since the restart" + (": " + lines[0][9:160] if lines else ""))
    ctx.check(not lines, f"the desktop's restart logged {len(lines)} 'can't read' line(s)")
    xl = log_has(ctx, "x", marks, "that StudioSync can't read")
    ctx.check(not xl, f"LinuxBox's restart logged {len(xl)} 'can't read' line(s)")


@scenario("j4 a Restore's count is what it brings back", "rt-sync2j task 2.2", needs=("d",), wants=("x",))
def restore_count(ctx):
    point = history(ctx, "d", "return LV.out(entries[#entries].id)")
    add(ctx, "d", "R")
    new_item(ctx, "d", "R", 2)
    both(ctx, ("R", "the item on every computer"), lambda x: x and abs(x["p"] - 2) < 1e-6)
    ctx.quiet()
    marks = ctx.log_marks(["d"])
    r = history(ctx, "d", f"local i; for k, e in ipairs(entries) do if e.id == {lua_str(point)} then i = k end end\n"
                          "if not i then return LV.out('') end\nlocal said = R.test.restore_whole(i, nil, opts)\nreturn LV.out({ said = tostring(said), n = #entries })")
    ctx.check(isinstance(r, dict), f"the Restore didn't run: {r}")
    ctx.note(f"Restore to before the two changes ({r['n']} rows in History): {r['said']}")
    m = re.search(r"bringing back (\d+) changes", r["said"])
    done = None
    if m:
        def ended():
            nonlocal done
            for l in log_has(ctx, "d", marks, "brought back"):
                x = re.search(r"(\d+) change\(s\) brought back", l)
                if x:
                    done = int(x.group(1))
            return done is not None
        ctx.wait("the Restore's slices done", ended, timeout=120, every=2)
        ctx.note(f"it said it was bringing back {m.group(1)}, and ended with {done} brought back")
        ctx.check(int(m.group(1)) == done, f"said {m.group(1)}, brought back {done}")
    else:
        x = re.search(r"(\d+) change\(s\) brought back", r["said"])
        ctx.check(x is not None, f"neither a count nor a result: {r['said']}")
        ctx.note(f"done at once: {x.group(1)} brought back (the plan was small enough not to need slices)")
    ctx.wait("the track gone everywhere", lambda: all(not ctx.do(w, f"return LV.out(LV.track(P, {lua_str(T(ctx, 'R'))}) ~= nil)") for w in ctx.on), timeout=90)
