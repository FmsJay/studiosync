"""rt-askweb's checks (docs/rt/rt-askweb.md): the big-deletion and Undo asks on the desktop's real web page (Session > Who's here), driven
with headless Chrome (Playwright, fake media devices: no camera or microphone is ever opened). The panel's bar is stood in for by the very
ExtState answer it writes (LV.answer)."""
import time, contextlib
from live import scenario, Skip, Fail, NoAnswer, lua_str, NAMES
from sets._lv import B, USER, SONG, setup, T, names, add, order, quiet_order, ask_of, answer, ss_undo, sleep, peer_ips

SETTLE = 17
LOCAL = "http://127.0.0.1:47281/"
CHROME_ARGS = ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", "--mute-audio", "--autoplay-policy=user-gesture-required"]


@contextlib.contextmanager
def page(url):
    from playwright.sync_api import sync_playwright
    with sync_playwright() as pw:
        b = pw.chromium.launch(headless=True, args=CHROME_ARGS, channel="chrome")  # (the installed Chrome: nothing downloaded)
        try:
            ctx = b.new_context(permissions=[])
            pg = ctx.new_page()
            pg.goto(url + "#session/here", wait_until="domcontentloaded", timeout=30000)
            pg.wait_for_function("() => window.ssTabs && ssTabs.route && ssTabs.route() === 'session/here'", timeout=30000)
            yield pg
        finally:
            b.close()


def remote_url(ctx):
    """The desktop's page as a device on the tailnet sees it: its Tailscale address with the phone-link token (read here, never printed)."""
    tok = ctx.do("d", "local ok, s = pcall(reaper.StudioSync_WebUIStatus); return LV.out(ok and type(s) == 'string' and s:match('\"token\":\"(%x+)\"') or '')")
    if not tok:
        raise Skip("the web UI's phone-link token isn't readable here")
    return f"http://{peer_ips()[0]}:47281/?t={tok}"


def li(pg, kind):
    return pg.query_selector(f"#asks li.localask[data-kind={kind}]")


def li_text(pg, kind):
    e = li(pg, kind)
    return e.text_content().replace("2019", "'") if e else None


def buttons(pg, kind):
    return [b.text_content() for b in pg.query_selector_all(f"#asks li.localask[data-kind={kind}] button")]


def wait_page(ctx, pg, what, fn, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        pg.wait_for_timeout(200)
    raise Fail(f"the page: timed out waiting for {what}")


def _three(ctx):
    add(ctx, "d", "A", "B", "C")
    ctx.quiet()
    sleep(SETTLE)


@scenario("w1 delete ask on the page: Yes, No, nothing", "askweb 1", needs=("d",), wants=("l", "x"))
def delete_on_page(ctx):
    _three(ctx)
    with page(LOCAL) as pg:
        # Yes
        ctx.do("d", f"LV.delete_tracks(P, {names(ctx, 'A', 'B')}) return LV.out(true)")
        t = wait_page(ctx, pg, "the delete ask", lambda: li_text(pg, "delete"))
        ctx.check(t.startswith("Delete 2 of the song's 3 tracks for everyone? ("), f"the words: {t}")
        ctx.check(buttons(pg, "delete") == ["Yes", "No"], f"buttons: {buttons(pg, 'delete')}")
        till1 = int(pg.eval_on_selector("#asks li.localask .asktill", "e => e.textContent").replace(" s", ""))
        pg.wait_for_timeout(2200)
        till2 = int(pg.eval_on_selector("#asks li.localask .asktill", "e => e.textContent").replace(" s", ""))
        ctx.check(till2 < till1, f"the countdown didn't count: {till1} -> {till2}")
        pg.click("#asks li.localask[data-kind=delete] button:has-text('Yes')")
        ctx.wait("A and B gone on the laptop", lambda: order(ctx, B(ctx)) == ["C"], timeout=40)
        wait_page(ctx, pg, "the line to leave", lambda: li(pg, "delete") is None, 10)
        sleep(SETTLE)
        # No
        add(ctx, "d", "A", "B")
        ctx.quiet()
        sleep(SETTLE)
        ctx.do("d", f"LV.delete_tracks(P, {names(ctx, 'A', 'B')}) return LV.out(true)")
        wait_page(ctx, pg, "the delete ask", lambda: li_text(pg, "delete"))
        pg.click("#asks li.localask[data-kind=delete] button:has-text('No')")
        ctx.wait("A and B back on the desktop", lambda: sorted(order(ctx, "d")) == ["A", "B", "C"], timeout=40)
        ctx.check(sorted(order(ctx, B(ctx))) == ["A", "B", "C"], "the laptop lost them")
        sleep(SETTLE)
        # nothing
        ctx.do("d", f"LV.delete_tracks(P, {names(ctx, 'A', 'B')}) return LV.out(true)")
        wait_page(ctx, pg, "the delete ask", lambda: li_text(pg, "delete"))
        t0 = time.time()
        ctx.wait("A and B back after the ask runs out", lambda: sorted(order(ctx, "d")) == ["A", "B", "C"], timeout=60, every=1)
        ctx.note(f"no answer: back after {time.time() - t0:.0f} s")
        wait_page(ctx, pg, "the line to leave", lambda: li(pg, "delete") is None, 10)


@scenario("w2 bar and page answer each other", "askweb 2", needs=("d",), wants=("l", "x"))
def bar_and_page(ctx):
    _three(ctx)
    with page(LOCAL) as pg:
        ctx.do("d", f"LV.delete_tracks(P, {names(ctx, 'A', 'B')}) return LV.out(true)")
        wait_page(ctx, pg, "the delete ask", lambda: li_text(pg, "delete"))
        answer(ctx, "d", "delete", False)  # the panel's bar: No
        t0 = time.time()
        wait_page(ctx, pg, "the line to leave after the bar's No", lambda: li(pg, "delete") is None, 10)
        took = time.time() - t0
        ctx.note(f"the page's line left {took:.1f} s after the bar's answer")
        ctx.check(took <= 3.0, f"the page took {took:.1f} s (want within a second or two)")
        ctx.wait("tracks back", lambda: sorted(order(ctx, "d")) == ["A", "B", "C"], timeout=40)
        sleep(SETTLE)
        ctx.do("d", f"LV.delete_tracks(P, {names(ctx, 'A', 'B')}) return LV.out(true)")
        wait_page(ctx, pg, "the delete ask", lambda: li_text(pg, "delete"))
        pg.click("#asks li.localask[data-kind=delete] button:has-text('No')")
        t0 = time.time()
        ctx.wait("the panel's bar to clear", lambda: ask_of(ctx, "d", "delete") is None, timeout=10, every=0.3)
        ctx.note(f"the bar's ask cleared {time.time() - t0:.1f} s after the page's No")
        ctx.wait("tracks back", lambda: sorted(order(ctx, "d")) == ["A", "B", "C"], timeout=40)


def _undo_ask(ctx):
    """The desktop renames A; the laptop then changes A's volume; the desktop presses StudioSync's Undo: an Undo ask (a bandmate changed it since)."""
    add(ctx, "d", "A")
    ctx.quiet()
    sleep(SETTLE)
    ctx.do("d", f"LV.rename(P, {lua_str(T(ctx, 'A'))}, {lua_str(T(ctx, 'A2'))}) return LV.out(true)")
    ctx.quiet()
    sleep(SETTLE)
    ctx.do(B(ctx), f"LV.set_vol(P, {lua_str(T(ctx, 'A2'))}, 0.5) return LV.out(true)")
    ctx.wait("the laptop's volume on the desktop", lambda: "0.5" in str([t["vol"] for t in ctx.state("d")["tracks"]]), timeout=40)
    sleep(4)
    ss_undo(ctx, "d")


@scenario("w3 Undo ask on the page", "askweb 3", needs=("d",), wants=("l", "x"))
def undo_on_page(ctx):
    with page(LOCAL) as pg:
        _undo_ask(ctx)
        t = wait_page(ctx, pg, "the Undo ask", lambda: li_text(pg, "undo"), 15)
        ctx.note(f"the page: {t[:120]}")
        ctx.check(buttons(pg, "undo") == ["Yes", "No"], f"buttons: {buttons(pg, 'undo')}")
        pg.click("#asks li.localask[data-kind=undo] button:has-text('Yes')")
        ctx.wait("the rename undone everywhere", lambda: order(ctx, B(ctx)) == ["A"] and order(ctx, "d") == ["A"], timeout=40)
        wait_page(ctx, pg, "the line to leave", lambda: li(pg, "undo") is None, 10)
        ctx.do("d", f"LV.delete_prefix(P, {lua_str(ctx.prefix)}) return LV.out(true)")
        ctx.quiet()
        sleep(SETTLE)
        # No leaves everything as it was
        _undo_ask(ctx)
        wait_page(ctx, pg, "the Undo ask", lambda: li_text(pg, "undo"), 15)
        pg.click("#asks li.localask[data-kind=undo] button:has-text('No')")
        wait_page(ctx, pg, "the line to leave", lambda: li(pg, "undo") is None, 10)
        sleep(8)
        ctx.check(order(ctx, "d") == ["A2"] and order(ctx, B(ctx)) == ["A2"], f"No changed something: {order(ctx, 'd')} / {order(ctx, 'l')}")


@scenario("w4 a page on another device", "askweb 4 and 5", needs=("d",), wants=("l", "x"))
def remote_page(ctx):
    _three(ctx)
    url = remote_url(ctx)
    with page(url) as pg:
        where = pg.evaluate("() => window.ssEnv && ssEnv.where")
        ctx.check(where == "remote", f"the tailnet page reads as '{where}', not remote")
        ctx.do("d", f"LV.delete_tracks(P, {names(ctx, 'A', 'B')}) return LV.out(true)")
        t = wait_page(ctx, pg, "the delete ask", lambda: li_text(pg, "delete"))
        ctx.check("on the computer itself" in t, f"the words: {t}")
        ctx.check(buttons(pg, "delete") == [], f"buttons on a remote page: {buttons(pg, 'delete')}")
        answer(ctx, "d", "delete", False)
        ctx.wait("tracks back", lambda: sorted(order(ctx, "d")) == ["A", "B", "C"], timeout=40)
    ctx.note("the remote page was headless Chrome on the desktop at its Tailscale address with the phone-link token: what the phone and "
             "the laptop's browser get (the web UI tells devices apart by the request's address, not by the browser)")
