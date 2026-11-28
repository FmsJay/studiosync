"""rt-sync2e's REAPER checks for James (docs/rt/rt-sync2e.md, 5 checks): grey stand-ins and byte order. "Audio arriving late" is made on
LinuxBox (x): its Syncthing paused through its REST API (approved for tests; never the real PCs'), so a take's change reaches it over the
direct link while the audio waits."""
import time
from live import scenario, Skip, Fail, NoAnswer, lua_str, NAMES
from sets._lv import _x as _lv_x, B, USER, SONG, setup, T, names, add, order, quiet_order, ss_undo, log_has, sleep, x_syncthing

SETTLE = 17
TAKE_POS, TAKE_SECS = 2.0, 16.0  # an 8-bar take at 120 bpm


def items(ctx, w, short):
    s = ctx.state(w)
    for t in s["tracks"]:
        if t["name"] == T(ctx, short):
            return t["items"]
    return None


MEDIA_X = "/home/studio/StudioSync Smiley Studios/" + SONG + "/rooms/main/media"


def x_media_blocked(on):
    """LinuxBox's copy of the song's media folder made read-only (or writable again): nothing can put a file there, not Syncthing, not the
    direct link's media stream. Inside the VM only."""
    mode = "a-w" if on else "u+w"
    r = _lv_x(f"mkdir -p '{MEDIA_X}' && chmod {mode} '{MEDIA_X}' && stat -c %A '{MEDIA_X}'")
    return r.stdout.strip()


def grey_on_x(ctx, short):
    """The desktop records an 8-bar take on `short` while its audio can't reach LinuxBox yet -> LinuxBox's grey stand-in (item dict).
    On this branch a take's audio travels over the direct link too (lib/streams.lua offer_media: any media file written in the last 10
    minutes), so pausing Syncthing alone, the check's own recipe, doesn't make it late: tried first, the audio came with the change. So:
    LinuxBox's Syncthing paused and its copy of the song's media folder read-only, until resume_x()."""
    ctx.check(x_syncthing(True), "couldn't pause LinuxBox's Syncthing")
    perm = x_media_blocked(True)
    def undo():
        x_media_blocked(False)
        x_syncthing(False)
    ctx.cleanups.append(undo)
    ctx.x_resume = undo
    ctx.note(f"LinuxBox: Syncthing paused, media folder {perm}")
    ctx.do("d", f"LV.record_take(P, {lua_str(T(ctx, short))}, {TAKE_POS}, {TAKE_SECS}, 'late') return LV.out(true)")
    end = time.time() + 120
    while time.time() < end:
        its = items(ctx, "x", short) or []
        grey = [i for i in its if i["arriving"]]
        if grey:
            ctx.note("LinuxBox shows the grey stand-in")
            return grey[0]
        if any(not i["arriving"] for i in its):
            raise Fail("harness: the take's audio reached LinuxBox with its change (no stand-in to test)")
        time.sleep(1)
    raise Fail("no grey stand-in appeared on LinuxBox within 2 minutes")


def resume_x(ctx):
    ctx.x_resume()
    return True


def no_grey(ctx):
    for w in ctx.on:
        s = ctx.shape(w)
        if "~" in s:
            return False
    return True


@scenario("e1 a copy of a grey box becomes yours", "sync2e 1", needs=("d", "x"), wants=("l",))
def copy_grey(ctx):
    add(ctx, "d", "Gtr")
    ctx.quiet()
    grey_on_x(ctx, "Gtr")
    # LinuxBox Ctrl+drags the grey box to bar 20 (38 s at 120 bpm): a copy keeps every mark the item carries, as REAPER's copy does
    ctx.do("x", f"""local t = LV.track(P, {lua_str(T(ctx, 'Gtr'))}); local it = reaper.GetTrackMediaItem(t, 0)
LV.copy_item(P, it, 38) return LV.out(true)""")
    sleep(3)
    ctx.check(resume_x(ctx), "couldn't resume LinuxBox")
    def landed():
        o = {w: ctx.shape(w) for w in ctx.on}
        ok = all("~" not in s and "2.00+16.00" in s and "38.00+16.00" in s for s in o.values())
        return o if ok else None
    try:
        ctx.wait("the take at its place and LinuxBox's copy at bar 20, on all three, nothing grey", landed, timeout=180, every=3)
    except Fail:
        raise Fail("after resuming: " + " | ".join(f"{NAMES[w]}: {ctx.shape(w)}" for w in ctx.on))


@scenario("e2 deleted before it arrived", "sync2e 2", needs=("d", "x"), wants=("l",))
def deleted_before(ctx):
    add(ctx, "d", "Gtr")
    ctx.quiet()
    grey_on_x(ctx, "Gtr")
    ctx.do("d", f"LV.delete_items_on(P, {lua_str(T(ctx, 'Gtr'))}) return LV.out(true)")
    sleep(5)
    ctx.check(resume_x(ctx), "couldn't resume LinuxBox")
    sh = ctx.quiet(timeout=150)
    ctx.check(sh == T(ctx, "Gtr"), f"after resuming: {sh} (want the track with no items anywhere)")


@scenario("e3 its track deleted before it arrived", "sync2e 3", needs=("d", "x"), wants=("l",))
def track_deleted_before(ctx):
    add(ctx, "d", "Gtr", "Keep")
    ctx.quiet()
    grey_on_x(ctx, "Gtr")
    ctx.do("d", f"LV.delete_tracks(P, {names(ctx, 'Gtr')}) return LV.out(true)")
    sleep(5)
    ctx.check(resume_x(ctx), "couldn't resume LinuxBox")
    sh = ctx.quiet(timeout=150)
    ctx.check(sh == T(ctx, "Keep"), f"after resuming: {sh}")
    allx = ctx.do("x", "local o = {} for k = 0, reaper.CountTracks(P) - 1 do o[#o+1] = select(2, reaper.GetTrackName(reaper.GetTrack(P, k))) end return LV.out(o)")
    yours = [n for n in allx if "(yours, not sent)" in n]
    ctx.check(not yours, f"LinuxBox has a '(yours, not sent)' track: {yours}")


@scenario("e4 StudioSync's Undo with the audio missing", "sync2e 4", needs=("d", "x"), wants=("l",))
def undo_missing_audio(ctx):
    """LinuxBox deletes Gtr at the moment the desktop records a take on it (the desktop hasn't seen the deletion), with the take's audio
    unable to reach LinuxBox; LinuxBox's StudioSync Undo of its deletion brings Gtr back with what was made on it meanwhile (41980c2): that
    take, whose audio isn't here. Deleting a grey box itself is no deletion (it never was the take here), so this is the path that brings a
    take back by StudioSync's Undo with its audio missing."""
    add(ctx, "d", "Gtr", "Keep")
    ctx.quiet()
    sleep(SETTLE)
    ctx.check(x_syncthing(True), "couldn't pause LinuxBox's Syncthing")
    perm = x_media_blocked(True)
    def undo():
        x_media_blocked(False)
        x_syncthing(False)
    ctx.cleanups.append(undo)
    ctx.x_resume = undo
    ctx.note(f"LinuxBox: Syncthing paused, media folder {perm}")
    ctx.at_once({
        "x": f"LV.delete_tracks(P, {names(ctx, 'Gtr')}) return true",
        "d": f"LV.record_take(P, {lua_str(T(ctx, 'Gtr'))}, {TAKE_POS}, {TAKE_SECS}, 'undo') return true",
    }, after=10)
    marks = ctx.log_marks(["x"])
    ss_undo(ctx, "x")
    sleep(10)
    said = log_has(ctx, "x", marks, "couldn't change here yet")
    ctx.note("LinuxBox after its Undo: " + ctx.shape("x").replace(ctx.prefix, "") + " | log: " + (said[0][9:200] if said else "no \"couldn't change here yet\""))
    ctx.check(resume_x(ctx), "couldn't resume LinuxBox")
    def landed():
        x = ctx.shape("x")
        return ("Gtr|" in x and "2.00+16.00" in x) and x
    try:
        ctx.wait("the take landed on LinuxBox's Gtr", landed, timeout=240, every=3)
    except Fail:
        pass
    sleep(10)
    shapes = {w: ctx.shape(w) for w in ctx.on}
    ctx.note("after resuming: " + " | ".join(f"{NAMES[w]}: {v.replace(ctx.prefix, '')}" for w, v in shapes.items()))
    dup = [NAMES[w] for w, v in shapes.items() if "(yours, not sent)" in v]
    if dup:
        ctx.note(f"a '(yours, not sent)' copy of the take stayed on {', '.join(dup)} beside the brought-back track (bug 5)")
    ctx.check(all("~" not in v for v in shapes.values()), f"a grey box is left: {shapes}")
    ctx.check("Gtr|" in shapes["x"], f"the take never landed on LinuxBox: {shapes['x']}")


@scenario("e5 which order Lua uses", "sync2e 5", needs=("d", "x"), wants=("l",))
def byte_order(ctx):
    got = {}
    for w in ctx.on:
        got[w] = ctx.do(w, 'return LV.out({ aB = tostring("a" < "B"), dash = tostring("a-b" < "ab"), locale = os.setlocale(nil, "collate") })')
        ctx.note(f"{NAMES[w]}: \"a\" < \"B\" is {got[w]['aB']}, \"a-b\" < \"ab\" is {got[w]['dash']}, collate locale {got[w]['locale']}")
    bad = [NAMES[w] for w, v in got.items() if v["aB"] != "false" or v["dash"] != "true"]
    ctx.check(not bad, f"Lua's < isn't byte order on: {bad} (StudioSync then compares byte by byte there, slower on big songs)")
