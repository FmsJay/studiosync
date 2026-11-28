"""rt-sync2c's REAPER checks for James (docs/rt/rt-sync2c.md, 12 checks), run on the desktop (d), laptop (l) and LinuxBox (x, the Mac's stand-in)."""
import json, time
from live import scenario, Skip, Fail, NoAnswer, lua_str, NAMES
from sets._lv import B, USER, SONG, setup, T, names, add, order, quiet_order, asks, ask_of, answer, ss_undo, log_has, sleep

SETTLE = 17  # presence.HOLD is 15 s: a bandmate's edit to what someone changed in the last 15 s is put back by design; wait past it


# ---- check 1: rt-reopen's re-checks (docs/rt/rt-reopen.md "rt-guard: REAPER re-checks" 1-5) ----

def _older_file(ctx, w, drop_short):
    """An older .rpp of the song on computer w: a copy of its own project file beside it, without the track `drop_short` (as a file saved
    before that track arrived). The song's own file is never written. -> (copy path, own path)."""
    return ctx.do(w, """
local _, own = reaper.EnumProjects(-1)
for i = 0, 99 do local q, fn = reaper.EnumProjects(i); if q == P then own = fn end end
if own == "" then error("the song's tab has no file", 0) end
local h = assert(io.open(own, "rb")); local s = h:read("a"); h:close()
-- (the track's block, from its "<TRACK" line to the line closing it, taken out by name)
local lines, out, skip, depth = {}, {}, false, 0
for l in (s .. "\\n"):gmatch("([^\\n]*)\\n") do lines[#lines + 1] = l end
local i = 1
while i <= #lines do
  local l = lines[i]
  if l:match("^%s*<TRACK") then
    local blk, d, j = { l }, 1, i + 1
    while j <= #lines and d > 0 do
      local m = lines[j]; blk[#blk + 1] = m
      if m:match("^%s*<") then d = d + 1 elseif m:match("^%s*>%s*$") then d = d - 1 end
      j = j + 1
    end
    local txt = table.concat(blk, "\\n")
    if not txt:find('NAME "' .. @NAME@ .. '"', 1, true) and not txt:find("NAME " .. @NAME@ .. "\\n", 1, true) then for _, b in ipairs(blk) do out[#out + 1] = b end end
    i = j
  else out[#out + 1] = l; i = i + 1 end
end
local copy = own:gsub("%.[Rr][Pp][Pp]$", "") .. ".lv-older.rpp"
local h2 = assert(io.open(copy, "wb")); h2:write(table.concat(out, "\\n")); h2:close()
return LV.out({ copy, own, #s, #table.concat(out, "\\n") })""".replace("@NAME@", lua_str(T(ctx, drop_short))))


def _x_home(ctx, own, copy):
    """A clean-up: LinuxBox's song tab back on its own file with Live sync running, the older copy deleted."""
    def go():
        ctx.raw("x", f"""
local p = LV.proj(SONG)
if p then
  local fn; for i = 0, 99 do local q, f = reaper.EnumProjects(i); if q == p then fn = f end end
  if fn ~= {lua_str(own)} then LV.load_into(p, {lua_str(own)}) end
  p = LV.proj(SONG)
  if p and not LV.live_running(p) then reaper.SelectProjectInstance(p); LV.run_script("StudioSync - Open session.lua") end
end
os.remove({lua_str(copy)})
return LV.out(true)""")
    return go


@scenario("c1.2 older file, same tab", "sync2c 1 (rt-reopen 2)", needs=("d", "x"), wants=("l",))
def older_same_tab(ctx):
    add(ctx, "d", "Keep", "Late")
    ctx.quiet()
    copy, own, n0, n1 = _older_file(ctx, "x", "Late")
    ctx.note(f"LinuxBox's own file {n0} bytes; the older copy without the track {n1} bytes" + (" (its file never had the track: it is the older file)" if n1 >= n0 else ""))
    t0 = int(time.time())
    marks = ctx.log_marks(["x"])
    ctx.cleanups.append(_x_home(ctx, own, copy))
    # File > Open of the older file into the tab Live sync runs in (no "Save?" box: noprompt)
    ctx.do("x", f"LV.load_into(P, {lua_str(copy)}); return LV.out(true)")
    t1 = time.time()
    ctx.wait("the tracks the older file lacks back on LinuxBox", lambda: order(ctx, "x") == ["Keep", "Late"], timeout=300, every=2)
    ctx.note(f"back on LinuxBox {time.time() - t1:.0f} s after the older file loaded")
    sh = ctx.quiet(timeout=60)
    gone = [e for e in ctx.do("x", f"return LV.out(LV.events_since(SONG, 'LinuxBox', {t0}))") if e.get("gone")]
    ctx.check(not gone, f"LinuxBox sent deletion(s) from the opening: {gone}")
    went = log_has(ctx, "x", marks, "change(s) went")
    ctx.note(f"LinuxBox's log after the opening: {len(went)} 'change(s) went' line(s); events: no gone")
    # back to its own file (older too: it catches up the same way)
    ctx.do("x", f"LV.load_into(P, {lua_str(own)}); return LV.out(true)")
    t1 = time.time()
    ctx.wait("the tracks back on LinuxBox after its own (also older) file loaded again", lambda: order(ctx, "x") == ["Keep", "Late"], timeout=300, every=2)
    ctx.note(f"second reload: back on LinuxBox {time.time() - t1:.0f} s after")
    ctx.quiet(timeout=60)


@scenario("c1.1 older file after a restart", "sync2c 1 (rt-reopen 1)", needs=("d", "x"), wants=("l",))
def older_restart(ctx):
    add(ctx, "d", "Keep", "Late")
    ctx.quiet()
    copy, own, n0, n1 = _older_file(ctx, "x", "Late")
    import subprocess, os
    from live import _x_ip, SSH
    t0 = int(time.time())
    # REAPER closed without saving (SIGTERM), started again with the older file, then Open session (Live sync) in its tab
    ctx.cleanups.append(_x_home(ctx, own, copy))
    ip = _x_ip()
    r = subprocess.run(SSH + [f"studio@{ip}", f"pkill -TERM -x reaper; for i in $(seq 1 30); do pgrep -x reaper >/dev/null || break; sleep 1; done; ~/start-reaper.sh '{copy}'"],
                       capture_output=True, text=True)
    ctx.note("LinuxBox: " + r.stdout.strip().splitlines()[-1] if r.stdout.strip() else "LinuxBox restarted")
    def back():
        try:
            return ctx.do("x", "return LV.out(true)", timeout=10)
        except NoAnswer:
            return None
    ctx.wait("LinuxBox's REAPER and hook back", back, timeout=120, every=5)
    sleep(25)  # (Live sync's lock of the REAPER that was closed counts for 20 s: "syncing in another REAPER on this computer" before that)
    ctx.do("x", "reaper.SelectProjectInstance(P); LV.run_script('StudioSync - Open session.lua'); return LV.out(true)", timeout=60)
    t1 = time.time()
    ctx.wait("the track the older file lacks back on LinuxBox", lambda: order(ctx, "x") == ["Keep", "Late"], timeout=300, every=2)
    ctx.note(f"back on LinuxBox {time.time() - t1:.0f} s after Open session")
    sh = ctx.quiet(timeout=60)
    gone = [e for e in ctx.do("x", f"return LV.out(LV.events_since(SONG, 'LinuxBox', {t0}))") if e.get("gone")]
    ctx.check(not gone, f"LinuxBox sent deletion(s) after the restart: {gone}")
    # the tab back on its own file, the older copy deleted
    ctx.do("x", f"LV.load_into(P, {lua_str(own)}); os.remove({lua_str(copy)}); return LV.out(true)")
    ctx.wait("LinuxBox back on its own file, caught up", lambda: order(ctx, "x") == ["Keep", "Late"], timeout=300, every=3)


@scenario("c1.3 closing or loading the tab", "sync2c 1 (rt-reopen 3)", needs=("d", "x"), wants=("l",))
def close_or_load(ctx):
    add(ctx, "d", "A", "B")
    ctx.quiet()
    t0 = int(time.time())
    ctx.do("x", "return LV.out(LV.close_song(SONG))")
    sleep(20)
    for w in [w for w in ctx.on if w != "x"]:
        ctx.check(order(ctx, w) == ["A", "B"], f"{NAMES[w]} changed after LinuxBox closed the tab: {order(ctx, w)}")
    ctx.check(ctx.raw("x", "LV.use_studio(); return LV.out(LV.open_song(SONG))") in ("opened", "open already"), "LinuxBox couldn't open the song again")
    sleep(15)
    ctx.quiet(timeout=120)
    # a different project into the tab Live sync runs in
    ctx.do("x", "LV.load_into(P, LV.empty_rpp()); return LV.out(true)")
    sleep(20)
    for w in [w for w in ctx.on if w != "x"]:
        ctx.check(order(ctx, w) == ["A", "B"], f"{NAMES[w]} changed after LinuxBox loaded another project into the tab: {order(ctx, w)}")
    gone = [e for e in ctx.do("d", f"return LV.out(LV.events_since(SONG, 'LinuxBox', {t0}))") if e.get("gone")]
    ctx.check(not gone, f"deletions sent by LinuxBox: {gone}")
    # (the empty project now sits in that tab: closed, and the song opened again)
    ctx.raw("x", "LV.close_empty(); return LV.out(LV.open_song(SONG))")
    sleep(15)
    ctx.quiet(timeout=120)


@scenario("c1.4 real deletions still go", "sync2c 1 (rt-reopen 4)", needs=("d", "x"), wants=("l",))
def real_deletions(ctx):
    add(ctx, "d", "A", "B", "C", "D", "E")
    ctx.quiet()
    ctx.do("d", f"LV.delete_tracks(P, {names(ctx, 'C')}); return LV.out(true)")
    ctx.check(order(ctx, "d") == ["A", "B", "D", "E"], "the deletion didn't happen on the desktop")
    ctx.quiet()
    ctx.do("d", "reaper.Undo_DoUndo2(P); return LV.out(true)")  # Ctrl+Z
    sh = ctx.quiet()
    ctx.check(T(ctx, "C") in sh, f"Ctrl+Z didn't bring C back everywhere: {sh}")
    ctx.do("d", "reaper.Undo_DoRedo2(P); return LV.out(true)")  # Ctrl+Shift+Z
    sh = ctx.quiet()
    ctx.check(T(ctx, "C") not in sh, f"Ctrl+Shift+Z didn't delete C again everywhere: {sh}")
    sleep(SETTLE)
    # the top track: E moved to the top of the song, then deleted
    ctx.do("d", f"LV.move_tracks(P, {names(ctx, 'E')}, (select(2, reaper.GetTrackName(reaper.GetTrack(P, 0))))); return LV.out(true)")
    ctx.check(ctx.do("d", "return LV.out(select(2, reaper.GetTrackName(reaper.GetTrack(P, 0))))") == T(ctx, "E"), "E isn't the top track")
    ctx.quiet()
    sleep(SETTLE)
    ctx.do("d", f"LV.delete_tracks(P, {names(ctx, 'E')}); return LV.out(true)")
    sh = ctx.quiet()
    ctx.check(T(ctx, "E") not in sh, f"the top track's deletion didn't go: {sh}")
    sleep(SETTLE)
    # every track selected and deleted: asks first since rt-sync2c ("answer Yes")
    allnames = ctx.do("d", "local o = {} for k = 0, reaper.CountTracks(P) - 1 do o[#o+1] = select(2, reaper.GetTrackName(reaper.GetTrack(P, k))) end return LV.out(o)")
    ctx.check(all(n.startswith(ctx.prefix) for n in allnames), f"the song holds tracks that aren't this scenario's: {allnames}")
    ctx.do("d", "local o = {} for k = 0, reaper.CountTracks(P) - 1 do o[#o+1] = select(2, reaper.GetTrackName(reaper.GetTrack(P, k))) end LV.delete_tracks(P, o) return LV.out(true)")
    a = ctx.wait("the delete-all ask on the desktop", lambda: ask_of(ctx, "d", "delete"), timeout=20, every=1)
    ctx.note(f"asked: {a['text']}")
    for w in ctx.on[1:]:
        ctx.check(len(order(ctx, w)) == 3, f"{NAMES[w]} lost tracks before the answer: {order(ctx, w)}")
    answer(ctx, "d", "delete", True)
    sh = ctx.quiet()
    ctx.check(sh == "", f"Yes to delete-all didn't delete them everywhere: {sh}")


@scenario("c1.5 deletion with the tab behind", "sync2c 1 (rt-reopen 5)", needs=("d", "x"), wants=("l",))
def tab_behind(ctx):
    add(ctx, "d", "A")
    ctx.do("d", f"LV.midi_item(P, {lua_str(T(ctx, 'A'))}, 2, 2); LV.midi_item(P, {lua_str(T(ctx, 'A'))}, 6, 2); return LV.out(true)")
    ctx.quiet()
    sleep(SETTLE)
    # delete an item, and switch to another project tab at once (the desktop's other song tab, or a new empty tab)
    ctx.do("d", f"""
local t = LV.track(P, {lua_str(T(ctx, 'A'))})
LV.block(P, "Delete items", function() reaper.DeleteTrackMediaItem(t, reaper.GetTrackMediaItem(t, 0)) end)
local other
for i = 0, 99 do local q = reaper.EnumProjects(i); if not q then break end; if q ~= P then other = q end end
if other then reaper.SelectProjectInstance(other) else reaper.Main_OnCommand(40859, 0) end
return LV.out(true)""")
    try:
        sh = ctx.quiet(timeout=60)
        ctx.check(sh.count("+") == 1, f"the deletion didn't reach the others with the tab behind: {sh}")
    finally:
        ctx.do("d", "reaper.SelectProjectInstance(P); return LV.out(true)")


def _delete_all_asks(ctx, first_one):
    add(ctx, "d", "A", "B", "C")
    ctx.quiet()
    sleep(SETTLE)
    if first_one:
        ctx.do("d", f"LV.delete_tracks(P, {names(ctx, 'C')}); return LV.out(true)")
        ctx.quiet()
        sleep(SETTLE)
    marks = ctx.log_marks(["d"])
    left = ["A", "B"] if first_one else ["A", "B", "C"]
    ctx.do("d", f"LV.delete_tracks(P, {names(ctx, *left)}); return LV.out(true)")  # Ctrl+A, delete: every track of the song
    try:
        a = ctx.wait("the delete-all ask on the desktop", lambda: ask_of(ctx, "d", "delete"), timeout=25, every=1)
    except Fail:
        said = ctx.log_since("d", marks)
        raise Fail("no ask; the desktop's log: " + " / ".join(l[9:170] for l in said if "LV Checks" in l)[:900])
    answer(ctx, "d", "delete", False)
    ctx.quiet()


@scenario("c1.4b delete-all right after a deletion", "sync2c 1 (rt-reopen 4), bug repro", needs=("d", "x"), wants=("l",))
def delete_all_after_delete(ctx):
    """A person deletes one track, then selects every track and deletes: REAPER's undo top reads "Remove tracks" both times."""
    _delete_all_asks(ctx, True)


@scenario("c1.4c delete-all as the first deletion", "sync2c 1 (rt-reopen 4), control", needs=("d", "x"), wants=("l",))
def delete_all_fresh(ctx):
    _delete_all_asks(ctx, False)


# ---- check 2: check 12 as built (a chain's knobs on reopen) ----

@scenario("c2 reopen keeps chains; knob + track 1", "sync2c 2", needs=("d", "x"), wants=("l",))
def reopen_chain(ctx):
    have = ctx.do(B(ctx), """
local f = io.open(reaper.GetResourcePath() .. "/reaper-vstplugins64.ini"); local s = f and f:read("a") or ""; if f then f:close() end
return LV.out({ tonex = s:find("TONEX", 1, true) ~= nil, sd = s:find("Superior Drummer", 1, true) ~= nil })""")
    plug = "TONEX" if have.get("tonex") else ("Superior Drummer 3" if have.get("sd") else None)
    ctx.note(f"plug-in used on {NAMES[B(ctx)]}: " + (plug or "ReaEQ (neither TONEX nor Superior Drummer is in its plug-in list)"))
    add(ctx, B(ctx), "Top", "Chain")
    fx = plug or "ReaEQ"
    ctx.do(B(ctx), f"""
local t = LV.track(P, {lua_str(T(ctx, 'Chain'))})
LV.block(P, "Add FX", function() reaper.TrackFX_AddByName(t, {lua_str(fx)}, false, -1) end)
return LV.out(reaper.TrackFX_GetCount(t))""", timeout=60)
    sleep(10)
    ctx.quiet(timeout=120)
    sleep(SETTLE)
    # 1. close the project and open it again in the same tab, Live sync running: nothing goes out for that chain
    t0 = int(time.time())
    marks = ctx.log_marks([B(ctx)])
    ctx.do(B(ctx), """local own; for i = 0, 99 do local q, fn = reaper.EnumProjects(i); if q == P then own = fn end end
LV.load_into(P, own) return LV.out(true)""", timeout=60)
    t1 = time.time()
    ctx.wait(f"the song's tracks back on {NAMES[B(ctx)]} after the reopen", lambda: order(ctx, B(ctx)) == ["Top", "Chain"], timeout=300, every=2)
    ctx.note(f"tracks back {time.time() - t1:.0f} s after the reopen")
    sleep(10)
    ev = [e for e in ctx.do(B(ctx), f"return LV.out(LV.events_since(SONG, {lua_str(USER[B(ctx)])}, {t0}))") if (e.get("name") or "").endswith("Chain")]
    ctx.check(not ev, f"the reopen sent changes for the chain's track: {ev}")
    ctx.quiet(timeout=120)
    sleep(SETTLE)
    # 2. a knob from a control surface (no undo point) and track 1 deleted within the same second: the knob reaches the others
    ctx.do(B(ctx), f"""
local c = LV.track(P, {lua_str(T(ctx, 'Chain'))}); local top = reaper.GetTrack(P, 0)
reaper.TrackFX_SetParamNormalized(c, 0, 0, 0.123)
LV.block(P, "Remove tracks", function() reaper.DeleteTrack(top) end)
return LV.out(true)""")
    def knob(w):
        return ctx.do(w, f"local c = LV.track(P, {lua_str(T(ctx, 'Chain'))}); return LV.out(c and math.floor(reaper.TrackFX_GetParamNormalized(c, 0, 0) * 1000 + 0.5) or -1)")
    for w in [w for w in ctx.on if w != B(ctx)]:
        ctx.wait(f"the knob on {NAMES[w]}", lambda w=w: knob(w) == 123, timeout=60)
    ctx.note("knob + deletion of track 1 in one second: the knob reached " + ", ".join(NAMES[w] for w in ctx.on if w != B(ctx)))
    raise Skip("parts 1-2 pass (above); part 3 ('turn a knob, save, and open the file again') needs saving the project, which these checks never do")


# ---- check 3: the master track on reopen (read only) ----

@scenario("c3 master track differs after reopen", "sync2c 3", needs=("d", "x"), wants=("l",))
def master_pointer(ctx):
    same = []
    for w in ctx.on:
        r = _master_once(ctx, w)
        ctx.note(f"{NAMES[w]}: master before {r['before']}, after {r['after']} (project pointer kept: {r['same_proj']})")
        if r["before"] == r["after"]:
            same.append(NAMES[w])
        ctx.wait(f"{NAMES[w]}'s Live sync after the reopen", lambda: ctx.do(w, "return LV.out(LV.live_running(P))"), timeout=60)
    ctx.check(not same, f"REAPER handed back the same master track pointer after File > Open in the same tab on: {', '.join(same)}")


def _master_once(ctx, w):
    return ctx.do(w, """
local own; for i = 0, 99 do local q, fn = reaper.EnumProjects(i); if q == P then own = fn end end
local before = tostring(reaper.GetMasterTrack(P))
local np = LV.load_into(P, own)
local after = tostring(reaper.GetMasterTrack(np))
return LV.out({ before = before, after = after, same_proj = tostring(np) == tostring(P) })""", timeout=60)


# ---- check 4 (and rt-sync2d 9's floor): the big-deletion ask ----

def _four(ctx):
    add(ctx, "d", "A", "B", "C", "D")
    for s in ("A", "B", "C", "D"):
        ctx.do("d", f"LV.midi_item(P, {lua_str(T(ctx, s))}, 1, 2); return LV.out(true)")
    ctx.quiet()
    sleep(SETTLE)


@scenario("c4 big deletion: Yes", "sync2c 4 / sync2d 9", needs=("d", "x"), wants=("l",))
def big_yes(ctx):
    _four(ctx)
    ctx.do("d", f"LV.delete_tracks(P, {names(ctx, 'A', 'B')}); return LV.out(true)")
    a = ctx.wait("the ask", lambda: ask_of(ctx, "d", "delete"), timeout=20, every=1)
    ctx.check(a["text"].startswith("Delete 2 of the song's 4 tracks for everyone?"), f"the ask's words: {a['text']}")
    sleep(4)
    for w in ctx.on[1:]:
        ctx.check(len(order(ctx, w)) == 4, f"{NAMES[w]} lost tracks while the ask waited: {order(ctx, w)}")
    answer(ctx, "d", "delete", True)
    sh = ctx.quiet()
    ctx.check(order(ctx, B(ctx)) == ["C", "D"], f"Yes didn't delete them everywhere: {sh}")


@scenario("c4 big deletion: No", "sync2c 4 / sync2d 9", needs=("d", "x"), wants=("l",))
def big_no(ctx):
    _four(ctx)
    marks = ctx.log_marks(["d"])
    ctx.do("d", f"LV.delete_tracks(P, {names(ctx, 'A', 'B')}); return LV.out(true)")
    ctx.wait("the ask", lambda: ask_of(ctx, "d", "delete"), timeout=20, every=1)
    answer(ctx, "d", "delete", False)
    sh = ctx.quiet()
    ctx.check(order(ctx, "d") == ["A", "B", "C", "D"], f"No didn't bring them back on the desktop: {sh}")
    ctx.check(sh.count("+") == 4, f"their items didn't come back with them: {sh}")
    went = log_has(ctx, "d", marks, "deleting 2 tracks")
    ctx.check(not went, "the desktop's log says it deleted them for everyone")


@scenario("c4 big deletion: no answer", "sync2c 4 / sync2d 9", needs=("d", "x"), wants=("l",))
def big_silent(ctx):
    _four(ctx)
    ctx.do("d", f"LV.delete_tracks(P, {names(ctx, 'A', 'B')}); return LV.out(true)")
    ctx.wait("the ask", lambda: ask_of(ctx, "d", "delete"), timeout=20, every=1)
    t0 = time.time()
    ctx.wait("the tracks back on the desktop", lambda: order(ctx, "d") == ["A", "B", "C", "D"], timeout=60, every=1)
    took = time.time() - t0
    ctx.note(f"back after {took:.0f} s with no answer")
    ctx.check(took >= 25, f"back after {took:.0f} s: before the 30 s ask ran out")
    ctx.quiet()


@scenario("c4 delete 1 of 4, and all", "sync2c 4 / sync2d 9", needs=("d", "x"), wants=("l",))
def big_one_and_all(ctx):
    _four(ctx)
    ctx.do("d", f"LV.delete_tracks(P, {names(ctx, 'A')}); return LV.out(true)")
    sleep(3)
    ctx.check(ask_of(ctx, "d", "delete") is None, "deleting 1 of 4 asked")
    ctx.quiet()
    ctx.check(order(ctx, "x") == ["B", "C", "D"], "1 of 4 didn't go to the others")
    sleep(SETTLE)
    ctx.do("d", f"LV.delete_tracks(P, {names(ctx, 'B', 'C', 'D')}); return LV.out(true)")  # Ctrl+A, delete (every track of the song)
    a = ctx.wait("the ask for all", lambda: ask_of(ctx, "d", "delete"), timeout=20, every=1)
    ctx.note(f"asked: {a['text']}")
    answer(ctx, "d", "delete", False)
    ctx.quiet()
    ctx.check(order(ctx, "d") == ["B", "C", "D"], "No didn't bring them back")


@scenario("c4 2-track song: delete 1", "sync2d 9", needs=("d", "x"), wants=("l",))
def big_two(ctx):
    add(ctx, "d", "A", "B")
    ctx.quiet()
    sleep(SETTLE)
    ctx.do("d", f"LV.delete_tracks(P, {names(ctx, 'A')}); return LV.out(true)")
    sleep(3)
    ctx.check(ask_of(ctx, "d", "delete") is None, "deleting 1 of 2 asked")
    ctx.quiet()
    ctx.check(order(ctx, B(ctx)) == ["B"], "it didn't go")


# ---- checks 5-12 (phase 4) ----

@scenario("c5 switch-over to ranks (logs)", "sync2c 5", needs=("d", "x"), wants=("l",))
def rank_switch(ctx):
    found = {}
    for w in ctx.on:
        found[w] = ctx.do(w, """
local band = LV.lib(); local dir = band.log_dir(); local out = {}
reaper.EnumerateFiles(dir, -1)
local i = 0
while true do local f = reaper.EnumerateFiles(dir, i); if not f then break end; i = i + 1
  local h = io.open(dir .. "/" .. f); if h then for l in h:lines() do if l:find("given their place as a rank", 1, true) then out[#out+1] = f:match("%d+%-%d+%-%d+") .. " " .. l:sub(1, 70) end end h:close() end end
return LV.out(out)""")
        ctx.note(f"{NAMES[w]}: {len(found[w])} line(s) " + "; ".join(found[w][:4]))
    # live part: the switch-over is long done on every computer, so new tracks made now must not say it again
    marks = ctx.log_marks()
    add(ctx, "d", "New1", "New2")
    add(ctx, B(ctx), "New3")
    ctx.quiet()
    sleep(45)
    again = {w: [l for l in ctx.log_since(w, marks) if "given their place as a rank" in l] for w in ctx.on}
    for w, ls in again.items():
        ctx.note(f"{NAMES[w]} after 3 new tracks: " + ("; ".join(ls) or "nothing"))
    said = [NAMES[w] for w, ls in again.items() if ls]
    ctx.check(not said, f"the switch-over line came again for new tracks on {', '.join(said)} (expected once, at the update)")


@scenario("c6 two moves at once", "sync2c 6", needs=("d", "x"), wants=("l",))
def two_moves(ctx):
    add(ctx, "d", "Drums", "Bass", "Gtr", "Keys")
    ctx.quiet()
    sleep(SETTLE)
    ctx.at_once({
        "d": f"LV.move_tracks(P, {names(ctx, 'Keys')}, {lua_str(T(ctx, 'Drums'))}) return true",
        B(ctx): f"LV.move_tracks(P, {names(ctx, 'Drums')}, nil) return true",
    })
    got = quiet_order(ctx)
    ctx.check(got == ["Keys", "Bass", "Gtr", "Drums"], f"order after both moves: {got} (want Keys, Bass, Gtr, Drums)")


@scenario("c7 late joiner after moves", "sync2c 7", needs=("d", "x"), wants=("l",))
def late_joiner(ctx):
    add(ctx, "d", "A", "B", "C", "D")
    ctx.quiet()
    ctx.do("x", "return LV.out(LV.close_song(SONG))")
    sleep(5)
    ctx.do("d", f"LV.move_tracks(P, {names(ctx, 'D')}, {lua_str(T(ctx, 'A'))}) return LV.out(true)")
    sleep(SETTLE)
    mover = "l" if "l" in ctx.on else "d"
    ctx.do(mover, f"LV.move_tracks(P, {names(ctx, 'A')}, nil) return LV.out(true)")
    want = quiet_order(ctx, [w for w in ctx.on if w != "x"])
    ctx.check(want == ["D", "B", "C", "A"], f"desktop/laptop order: {want}")
    ctx.raw("x", "LV.use_studio(); return LV.out(LV.open_song(SONG))")
    first = ctx.wait("LinuxBox's song open", lambda: (lambda o: o if o else None)(order(ctx, "x")), timeout=60)
    sleep(10)
    first = order(ctx, "x")
    ctx.note(f"LinuxBox as it opened: {first}")
    sleep(60)
    later = order(ctx, "x")
    ctx.check(first == want and later == want, f"LinuxBox: {first} at first, {later} after a minute, want {want}")


@scenario("c8 folders as before", "sync2c 8", needs=("d", "x"), wants=("l",))
def folders(ctx):
    add(ctx, "d", "Bus", "Kid", "Other", "Last")
    ctx.quiet()
    ctx.do("d", f"LV.into_folder(P, {names(ctx, 'Kid')}, {lua_str(T(ctx, 'Bus'))}) return LV.out(true)")
    sh = ctx.quiet()
    ctx.check("Kid<" + T(ctx, "Bus") in sh, f"indent into a folder: {sh}")
    sleep(SETTLE)
    ctx.do("d", f"LV.out_of_folder(P, {names(ctx, 'Kid')}, {lua_str(T(ctx, 'Other'))}) return LV.out(true)")
    sh = ctx.quiet()
    ctx.check("<" not in sh, f"outdent: {sh}")
    sleep(SETTLE)
    ctx.do("d", f"LV.into_folder(P, {names(ctx, 'Kid')}, {lua_str(T(ctx, 'Bus'))}) return LV.out(true)")
    ctx.quiet()
    sleep(SETTLE)
    # drag the whole folder (Bus with Kid) below Last
    ctx.do("d", f"LV.move_tracks(P, {names(ctx, 'Bus', 'Kid')}, nil) return LV.out(true)")
    got = quiet_order(ctx)
    ctx.check(got == ["Other", "Last", "Bus", "Kid<" + T(ctx, "Bus").replace(ctx.prefix, "")], f"after dragging the folder down: {got}")
    sleep(SETTLE)
    # a folder moved on one computer while a child is dragged out of it on another, within a second
    ctx.at_once({
        "d": f"LV.move_tracks(P, {names(ctx, 'Bus', 'Kid')}, {lua_str(T(ctx, 'Other'))}) return true",
        B(ctx): f"LV.out_of_folder(P, {names(ctx, 'Kid')}, nil) return true",
    })
    got = quiet_order(ctx)
    ctx.note(f"each computer ends with: {got}")


@scenario("c9 an old-version computer", "sync2c 9", needs=())
def old_version(ctx):
    raise Skip("not applicable: James's decision of 11-27 (StudioSync runs only on his own computers, no old-version compatibility, "
               "rt-sync2e): no computer is kept on an older release")


@scenario("c10 Undo of a move", "sync2c 10", needs=("d", "x"), wants=("l",))
def undo_move(ctx):
    add(ctx, "d", "A", "B", "C")
    ctx.quiet()
    sleep(SETTLE)
    ctx.do("d", f"LV.move_tracks(P, {names(ctx, 'C')}, {lua_str(T(ctx, 'A'))}) return LV.out(true)")
    ctx.check(quiet_order(ctx) == ["C", "A", "B"], "the move")
    sleep(5)
    ss_undo(ctx, "d")
    got = quiet_order(ctx)
    ctx.check(got == ["A", "B", "C"], f"after StudioSync's Undo: {got}")
    sleep(5)
    ss_undo(ctx, "d", redo=True)
    got = quiet_order(ctx)
    ctx.check(got == ["C", "A", "B"], f"after StudioSync's Redo: {got}")


@scenario("c11 order waits while playing", "sync2c 11", needs=("d", "x"), wants=("l",))
def order_while_playing(ctx):
    add(ctx, "d", "A", "B", "C")
    ctx.quiet()
    sleep(SETTLE)
    # the desktop plays where the song has nothing (5000 s), metronome off for the moment: no sound
    st = ctx.do("d", """
local was = { cur = reaper.GetCursorPositionEx(P), met = reaper.GetToggleCommandStateEx(0, 40364) }
if was.met == 1 then reaper.Main_OnCommand(40364, 0) end
reaper.SetEditCurPos2(P, 5000, false, false)
reaper.OnPlayButtonEx(P)
return LV.out(was)""")
    def stop():
        ctx.do("d", f"reaper.OnStopButtonEx(P); reaper.SetEditCurPos2(P, {st['cur']}, false, false); if {st['met']} == 1 and reaper.GetToggleCommandStateEx(0, 40364) == 0 then reaper.Main_OnCommand(40364, 0) end return LV.out(true)")
    ctx.cleanups.append(stop)
    ctx.do(B(ctx), f"LV.move_tracks(P, {names(ctx, 'C')}, {lua_str(T(ctx, 'A'))}) return LV.out(true)")
    ctx.wait("the move on LinuxBox", lambda: order(ctx, "x") == ["C", "A", "B"], timeout=40)
    sleep(6)
    playing = ctx.do("d", "return LV.out(reaper.GetPlayStateEx(P))")
    while_play = order(ctx, "d")
    ctx.note(f"desktop while playing (play state {playing}): {while_play}")
    stop()
    ctx.cleanups.remove(stop)
    after = ctx.wait("the desktop in order after the stop", lambda: order(ctx, "d") == ["C", "A", "B"] and order(ctx, "d"), timeout=40)
    ctx.check(while_play == ["A", "B", "C"], f"the desktop's tracks moved while it played: {while_play}")
    ctx.note("the mouse-button half isn't automatable: StudioSync reads the real mouse button (JS_Mouse_GetState); a script can't hold it")


@scenario("c12 a track brought back by Undo", "sync2c 12", needs=("d", "x"), wants=("l",))
def undo_brings_take(ctx):
    add(ctx, "d", "Gtr", "Other")
    ctx.quiet()
    sleep(SETTLE)
    # the desktop deletes Gtr while the laptop (not yet seeing it) records a short take on it
    ctx.at_once({
        "d": f"LV.delete_tracks(P, {names(ctx, 'Gtr')}) return true",
        B(ctx): f"LV.record_take(P, {lua_str(T(ctx, 'Gtr'))}, 2, 3, 'lap') return true",
    }, after=8)
    sleep(10)
    ss_undo(ctx, "d")
    def back_with_take():
        o = {w: ctx.shape(w) for w in ctx.on}
        ok = all(("Gtr|" in s and "2.00+3.00" in s.split("Gtr|")[1].split(" ;")[0] and "~" not in s) for s in o.values())
        return o if ok else None
    try:
        ctx.wait("Gtr back everywhere with the laptop's take, not grey", back_with_take, timeout=150, every=3)
    except Fail:
        o = {NAMES[w]: ctx.shape(w) for w in ctx.on}
        raise Fail(f"after StudioSync's Undo: {o}")
    sleep(20)
    left = {NAMES[w]: ctx.shape(w) for w in ctx.on}
    ctx.note("20 s later: " + " | ".join(f"{k}: {v.replace(ctx.prefix, '')}" for k, v in left.items()))
    extra = [k for k, v in left.items() if "(yours, not sent)" in v]
    ctx.check(not extra, f"a '(yours, not sent)' copy of the take is left beside the brought-back track on: {', '.join(extra)}")
