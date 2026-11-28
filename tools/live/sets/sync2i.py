"""rt-sync2i's Live checks (docs/rt/rt-sync2i.md): Undo from ancestry (rt-sync2 5a). StudioSync's own Undo and Redo through undo.step, the
path the Ctrl+Z / Ctrl+Shift+Z scripts take for a change StudioSync made (an ask is answered as a person does: the same key again); History's
"Undo this change" and "Restore whole project to here" through page_restore's own functions, as the History web page runs them
(lib/webrestore.lua). i3 and i4 set the project timebase to beats (position, length, rate) on every computer and put it back after, and leave
the tempo on one marker of 120 bpm. Nothing is saved."""
import time
from live import scenario, Fail, lua_str, NAMES
from sets._lv import B, setup, T, add, sleep, ask_of, answer
from sets.sync2f import force_120, tmap

SETTLE = 17  # presence.HOLD is 15 s: a bandmate's edit to what someone changed in the last 15 s is put back by design


# ---- small steps ----

def ss(ctx, w, redo=False):
    """StudioSync's own Undo (or Redo) on w: undo.step, pressed again when it asks (a bandmate changed it since). -> its words."""
    flag = "true" if redo else "false"
    r = ctx.do(w, "local band = LV.lib(); local u = require('undo'); local cfg, b = band.settings(), band.binding(P)\n"
                  f"local r, why, asked = u.step(P, cfg, b, {flag})\n"
                  f"if asked then r, why = u.step(P, cfg, b, {flag}) end\n"
                  "return LV.out({ r = r or '', why = why or '', asked = asked or '' })", timeout=60)
    ctx.note(f"{NAMES[w]} {'Redo' if redo else 'Undo'}: {r.get('r') or r.get('why')}{' (asked first)' if r.get('asked') else ''}")
    return r


def new_item(ctx, w, short, pos, length=2.0):
    """A MIDI item on the track with two notes, made in one step (its first version carries them)."""
    ctx.do(w, f"local it = LV.midi_item(P, {lua_str(T(ctx, short))}, {float(pos)!r}, {float(length)!r}); local tk = reaper.GetActiveTake(it)\n"
              "reaper.MIDI_InsertNote(tk, false, false, 0, 480, 0, 60, 100, true); reaper.MIDI_InsertNote(tk, false, false, 480, 960, 0, 64, 90, true)\n"
              "reaper.MIDI_Sort(tk); reaper.UpdateArrange(); return LV.out(true)")


def item(ctx, w, short):
    """The track's first item on w: place (seconds, quarter notes), mute, how many items the track has, its notes, its id. None: none."""
    r = ctx.do(w, f"local t = LV.track(P, {lua_str(T(ctx, short))}); local it = t and reaper.GetTrackMediaItem(t, 0)\n"
                  "if not it then return LV.out(false) end\n"
                  "local _, ch = reaper.GetItemStateChunk(it, '', false); local notes = {}\n"
                  "for l in ch:gmatch('\\n%s*(E %d+ [89]0 [^\\n]+)') do notes[#notes + 1] = l end\n"
                  "local pos = reaper.GetMediaItemInfo_Value(it, 'D_POSITION')\n"
                  "return LV.out({ p = pos, q = reaper.TimeMap2_timeToQN(P, pos), m = reaper.GetMediaItemInfo_Value(it, 'B_MUTE'), n = reaper.CountTrackMediaItems(t),\n"
                  "  notes = table.concat(notes, '|'), oid = select(2, reaper.GetSetMediaItemInfo_String(it, 'P_EXT:band_oid', '', false)) })")
    return r or None


def set_item(ctx, w, short, key, v):
    ctx.do(w, f"LV.item_set(P, {lua_str(T(ctx, short))}, {{ {key} = {float(v)!r} }}); return LV.out(true)")


def kept_copies(ctx, w):
    """Tracks named '... (yours, not sent)' on w (a deleted item of yours kept from a bandmate's deletion)."""
    return ctx.do(w, "local n = 0; for i = 0, reaper.CountTracks(P) - 1 do local _, nm = reaper.GetTrackName(reaper.GetTrack(P, i))\n"
                     "if nm:find('(yours, not sent)', 1, true) then n = n + 1 end end; return LV.out(n)")


def both(ctx, what, fn, timeout=60):
    """Wait until fn(item on w) holds on every computer of the run. -> {w: item}."""
    last = {}
    def ok():
        nonlocal last
        last = {w: item(ctx, w, what[0]) for w in ctx.on}
        return all(fn(x) for x in last.values())
    try:
        ctx.wait(what[1], ok, timeout=timeout, every=2)
    except Fail:
        raise Fail(f"{what[1]}: " + "; ".join(f"{NAMES[w]} {x}" for w, x in last.items()))
    return last


def bpm(ctx, w):
    m = tmap(ctx, w)
    return m[0]["bpm"] if len(m) == 1 else None


def beats_timebase(ctx):
    """The project timebase beats (position, length, rate) on every computer, put back after; the tempo one marker of 120 after."""
    tb = {w: ctx.do(w, 'local was = reaper.GetSetProjectInfo(P, "PROJECT_TIMEBASE", 0, false)\n'
                       'reaper.GetSetProjectInfo(P, "PROJECT_TIMEBASE", 1, true)\nreturn LV.out(was)') for w in ctx.on}
    def back():
        for w, v in tb.items():
            if v != 1:
                ctx.do(w, f'reaper.GetSetProjectInfo(P, "PROJECT_TIMEBASE", {v}, true); return LV.out(true)')
    def tempo():
        try:
            force_120(ctx)
        except Fail as e:
            ctx.note(f"cleanup: {e}")
    ctx.cleanups.append(back)
    ctx.cleanups.append(tempo)
    force_120(ctx)


def history(ctx, w, body):
    """page_restore's functions on w, set up as the History web page sets them up (lib/webrestore.lua panel/opts_of), over History's
    entries sorted as the page sorts them. `body` runs with entries, R (page_restore), opts and cfg in scope."""
    return ctx.do(w, "local band = LV.lib(); local cfg, b = band.settings(), band.binding(P)\n"
                     "local sync = require('sync'); local session = band.read_json(band.session_path(cfg, b.song))\n"
                     "local entries = require('recall').entries(cfg, b.song, b.room)\n"
                     "table.sort(entries, function(a, x) return (a.time .. a.id) < (x.time .. x.id) end)\n"
                     "local R = require('page_restore')\n"
                     "R.init({ b = function() return b end, cfg = function() return cfg end, proj = function() return P end,\n"
                     "  view = function() return { session = session, driver = cfg.user } end, refresh_now = function() end })\n"
                     "R.test.entries(entries)\n"
                     "local can, who = sync.authority(cfg, b.song, b.room, session)\n"
                     "local opts = { can = can, mode = who and who.mode, driver = who and who.driver, is_claimed = who and who.is_claimed,\n"
                     "  local_mix = select(2, reaper.GetProjExtState(P, band.SECTION, 'local_mix')) == '1' }\n" + body, timeout=90)


# ---- the scenarios ----

@scenario("i1 Undo/Redo of your edit, a bandmate's change since", "rt-sync2i 1", needs=("d",), wants=("l", "x"))
def own_edit(ctx):
    bm = B(ctx)
    add(ctx, "d", "U")
    new_item(ctx, "d", "U", 4)
    both(ctx, ("U", "the item on every computer"), lambda x: x and abs(x["p"] - 4) < 1e-6)
    sleep(SETTLE)
    set_item(ctx, "d", "U", "D_POSITION", 8)
    both(ctx, ("U", "the desktop's move on every computer"), lambda x: x and abs(x["p"] - 8) < 1e-6)
    sleep(SETTLE)
    set_item(ctx, bm, "U", "B_MUTE", 1)
    both(ctx, ("U", f"{NAMES[bm]}'s mute on every computer"), lambda x: x and x["m"] == 1)
    sleep(SETTLE)
    u = ss(ctx, "d")
    ctx.check(u.get("asked"), f"the desktop's Undo didn't ask, though {NAMES[bm]} changed the item since: {u}")
    both(ctx, ("U", "the move undone and the mute kept, on every computer"), lambda x: x and abs(x["p"] - 4) < 1e-6 and x["m"] == 1)
    sleep(4)
    ss(ctx, "d", redo=True)
    both(ctx, ("U", "the Redo: moved again, still muted, on every computer"), lambda x: x and abs(x["p"] - 8) < 1e-6 and x["m"] == 1)


@scenario("i2 Undo of a deletion: back with its contents", "rt-sync2i 2", needs=("d",), wants=("l", "x"))
def deletion(ctx):
    add(ctx, "d", "D", "D2", "D3")  # (three: deleting one is under half the song's tracks, so no big-deletion ask)
    new_item(ctx, "d", "D", 2, 3)
    was = both(ctx, ("D", "the item and its notes on every computer"), lambda x: x and x["notes"].count("|") == 3)["d"]
    sleep(SETTLE)
    # the item deleted, then undone
    ctx.do("d", f"LV.delete_items_on(P, {lua_str(T(ctx, 'D'))}); return LV.out(true)")
    both(ctx, ("D", "the item gone everywhere"), lambda x: x is None)
    sleep(SETTLE)
    ss(ctx, "d")
    back = both(ctx, ("D", "the item back on every computer, its notes and place as they were"),
                lambda x: x and x["n"] == 1 and x["notes"] == was["notes"] and abs(x["p"] - was["p"]) < 1e-6 and x["oid"] == was["oid"])
    ctx.check(all(kept_copies(ctx, w) == 0 for w in ctx.on), "a '(yours, not sent)' copy appeared")
    ctx.note(f"item back as {back['d']['oid']}")
    sleep(SETTLE)
    # the track deleted with its item, then undone: the track comes back with the item (containment)
    ctx.do("d", f"LV.delete_tracks(P, {{{lua_str(T(ctx, 'D'))}}}); return LV.out(true)")
    sleep(3)
    if ask_of(ctx, "d", "delete"):
        answer(ctx, "d", "delete", True)
    ctx.wait("the track gone everywhere", lambda: all(ctx.do(w, f"return LV.out(LV.track(P, {lua_str(T(ctx, 'D'))}) ~= nil)") is False for w in ctx.on), timeout=60)
    sleep(SETTLE)
    ss(ctx, "d")
    both(ctx, ("D", "the track back on every computer with its item and notes"),
         lambda x: x and x["n"] == 1 and x["notes"] == was["notes"] and x["oid"] == was["oid"], timeout=90)
    ctx.check(all(kept_copies(ctx, w) == 0 for w in ctx.on), "a '(yours, not sent)' copy appeared")


@scenario("i3 Undo across a bandmate's tempo change", "rt-sync2i 3", needs=("d",), wants=("l", "x"))
def across_tempo(ctx):
    bm = B(ctx)
    beats_timebase(ctx)
    add(ctx, "d", "Q")
    new_item(ctx, "d", "Q", 4)  # (beat 8 at 120)
    both(ctx, ("Q", "the item on every computer"), lambda x: x and abs(x["q"] - 8) < 1e-6)
    sleep(SETTLE)
    set_item(ctx, "d", "Q", "D_POSITION", 6)  # (beat 12)
    both(ctx, ("Q", "the desktop's move on every computer"), lambda x: x and abs(x["q"] - 12) < 1e-6)
    sleep(SETTLE)
    ctx.do(bm, "LV.tempo_reset(P, 60); return LV.out(true)")
    ctx.wait("60 bpm everywhere", lambda: all(bpm(ctx, w) == 60 for w in ctx.on), timeout=60)
    both(ctx, ("Q", "the item on its beat (12 s at 60) everywhere"), lambda x: x and abs(x["p"] - 12) < 1e-6)
    sleep(SETTLE)
    ss(ctx, "d")
    both(ctx, ("Q", "the move undone onto its beat under today's map (beat 8: 8 s at 60) everywhere"),
         lambda x: x and abs(x["q"] - 8) < 1e-6 and abs(x["p"] - 8) < 1e-6)
    ctx.check(all(bpm(ctx, w) == 60 for w in ctx.on), f"the bandmate's tempo didn't stay: {[bpm(ctx, w) for w in ctx.on]}")
    sleep(4)
    ss(ctx, "d", redo=True)
    both(ctx, ("Q", "the Redo onto beat 12 everywhere"), lambda x: x and abs(x["q"] - 12) < 1e-6)


@scenario("i4 History's Undo this change, and a Restore's", "rt-sync2i 4", needs=("d",), wants=("l", "x"))
def history_undo(ctx):
    bm = B(ctx)
    beats_timebase(ctx)
    add(ctx, "d", "H")
    new_item(ctx, "d", "H", 2)
    oid = both(ctx, ("H", "the item on every computer"), lambda x: x and abs(x["p"] - 2) < 1e-6)["d"]["oid"]
    sleep(SETTLE)
    set_item(ctx, "d", "H", "D_POSITION", 5)
    both(ctx, ("H", "the desktop's move everywhere"), lambda x: x and abs(x["p"] - 5) < 1e-6)
    sleep(SETTLE)
    set_item(ctx, bm, "H", "B_MUTE", 1)
    both(ctx, ("H", f"{NAMES[bm]}'s mute everywhere"), lambda x: x and x["m"] == 1)
    sleep(SETTLE)
    # "Undo this change" on the desktop's move row: the move goes back, the bandmate's mute stays
    said = history(ctx, "d", f"local i; for k = #entries, 1, -1 do local e = entries[k]; if e.kind == 'obj' and e.oid == {lua_str(oid)} and e.user == cfg.user"
                             " and not e.restored and not e.undoes and not e.redoes and (e.rev or 0) > 1 then i = k; break end end\n"
                             "if not i then return LV.out('no row') end\nreturn LV.out(tostring(R.test.undo_change(i, opts)))")
    ctx.note(f"Undo this change: {said}")
    both(ctx, ("H", "History's Undo this change: the move back, the mute kept, everywhere"), lambda x: x and abs(x["p"] - 2) < 1e-6 and x["m"] == 1)
    sleep(SETTLE)
    # the point to restore to: now (120 bpm, the item at beat 4). Then the bandmate's tempo change and the desktop's move
    point = history(ctx, "d", "return LV.out(entries[#entries].id)")
    ctx.do(bm, "LV.tempo_reset(P, 100); return LV.out(true)")
    ctx.wait("100 bpm everywhere", lambda: all(bpm(ctx, w) == 100 for w in ctx.on), timeout=60)
    sleep(SETTLE)
    set_item(ctx, "d", "H", "D_POSITION", 7)
    both(ctx, ("H", "the desktop's move to 7 s everywhere"), lambda x: x and abs(x["p"] - 7) < 1e-6)
    sleep(SETTLE)
    act = history(ctx, "d", f"local i; for k, e in ipairs(entries) do if e.id == {lua_str(point)} then i = k end end\n"
                            "if not i then return LV.out('') end\nlocal said = R.test.restore_whole(i, nil, opts)\nreturn LV.out({ act = opts.act or '', said = tostring(said) })")
    ctx.check(isinstance(act, dict) and act.get("act"), f"the Restore didn't run: {act}")
    ctx.note(f"Restore: {act['said']}")
    ctx.wait("the Restore's 120 bpm everywhere", lambda: all(bpm(ctx, w) == 120 for w in ctx.on), timeout=60)
    both(ctx, ("H", "the Restore: the item at beat 4 (2 s at 120) everywhere"), lambda x: x and abs(x["q"] - 4) < 1e-6 and x["m"] == 1)
    sleep(SETTLE)
    # "Undo this change" on the Restore's row of the item: today's tempo map comes back with it (James, 11-21), and the item to today's place
    said = history(ctx, "d", f"local i; for k = #entries, 1, -1 do local e = entries[k]; if e.kind == 'obj' and e.act == {lua_str(act['act'])} and e.restored"
                             f" and e.oid == {lua_str(oid)} then i = k; break end end\n"
                             "if not i then return LV.out('no row') end\nreturn LV.out(tostring(R.test.undo_change(i, opts)))")
    ctx.note(f"Undo this change on the Restore's row: {said}")
    ctx.wait("today's 100 bpm back everywhere", lambda: all(bpm(ctx, w) == 100 for w in ctx.on), timeout=60)
    both(ctx, ("H", "the item at today's 7 s everywhere"), lambda x: x and abs(x["p"] - 7) < 1e-6 and x["m"] == 1)
