// The docked web UI (extension/webui_dock.cpp) without REAPER: the server's port from its status, the address the window opens, WebView2's
// own user-data folder, where the view may go, and the page's key messages; the window's shapes (rt-ui8): the page's "win:" asks, what the
// window tells the page, the focus rule, the strip and button sizes, places kept inside REAPER's window and on a monitor, the cover test,
// pop-out names. On Windows, when the WebView2 Runtime is installed, also the real thing headless: hidden windows, the view made in one with
// a fresh user-data folder, the pages loaded from the web UI server (extension/webui.cpp, standalone, on a port of its own so a running
// REAPER's isn't touched), the view moved alive into another window, and the window's frame, opacity and owner. Build and run: tests\build_webui_dock_test.cmd
// (macOS/Linux, the pure parts: c++ -std=c++17 -pthread -DWEBUI_DOCK_STANDALONE tests/webui_dock_test.cpp extension/webui_dock.cpp). GPL-3.0-or-later.
#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>
#include "../extension/webui.h"
#endif
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include "../extension/webui_dock.h"

static int fails = 0;
#define CHECK(c, what) do { if (c) printf("ok   %s\n", what); else { printf("FAIL %s\n", what); ++fails; } } while (0)

#ifdef _WIN32
static std::string g_msg; // (the last thing the view said: "error:..." when it couldn't start)
static void *g_from; // (the window it said it from)
static bool g_loaded;
static void on_msg(void *h, const char *m)
{
  g_msg = m ? m : "";
  g_from = h;
  if (g_msg == "view:loaded") g_loaded = true;
}
static void pump(DWORD ms, bool (*done)())
{
  const DWORD until = GetTickCount() + ms;
  while (GetTickCount() < until && !done()) {
    MSG m;
    while (PeekMessage(&m, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&m); DispatchMessage(&m); }
    Sleep(10);
  }
}
static long long served()
{
  const char *s = strstr(webui_status(), "\"served\":");
  return s ? atoll(s + 9) : -1;
}
static void headless(const char *exe)
{
  // the pages: <repo>/lib/webui, from this test's own path (tests\..\lib\webui)
  std::string root = exe;
  root = root.substr(0, root.find_last_of("\\/") + 1);
  const char *env = getenv("SS_REPO");
  const std::string pages = (env && *env ? std::string(env) : root + "..") + "\\lib\\webui";
  const int port = 47299;
  if (!webui_start(pages.c_str(), "", port, "")) { printf("FAIL the web UI server couldn't listen on %d: %s\n", port, webui_status()); ++fails; return; }
  char tmp[MAX_PATH];
  GetTempPathA(MAX_PATH, tmp);
  const std::string data = webui_dock_data_dir(std::string(tmp) + "ss_webui_dock_test");
  HWND h = CreateWindowExA(0, "STATIC", "StudioSync dock test", WS_OVERLAPPEDWINDOW, 0, 0, 400, 600, nullptr, nullptr, nullptr, nullptr);
  std::string err;
  const long long before = served();
  if (!dock_view_create(h, webui_dock_url(port, true).c_str(), data.c_str(), on_msg, err)) {
    if (err.find("isn't installed") != std::string::npos) printf("skip the headless view: %s\n", err.c_str());
    else { printf("FAIL the view didn't start: %s\n", err.c_str()); ++fails; }
  } else {
    // (WebView2 answers on this thread's message loop: pump it until the page and its two files came, or it failed, or 30 s)
    const DWORD until = GetTickCount() + 30000;
    while (GetTickCount() < until && served() - before < 3 && g_msg.compare(0, 6, "error:") != 0) {
      MSG m;
      while (PeekMessage(&m, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&m); DispatchMessage(&m); }
      Sleep(10);
    }
    CHECK(g_msg.compare(0, 6, "error:") != 0, "WebView2 started in its own user-data folder");
    CHECK(GetFileAttributesA(data.c_str()) != INVALID_FILE_ATTRIBUTES, "the user-data folder was made (and the folders above it)");
    CHECK(served() - before >= 3, "the view loaded the pages from the web UI server (index.html, style.css, app.js)");
    pump(15000, [] { return g_loaded || g_msg.compare(0, 6, "error:") == 0; });
    CHECK(g_loaded && g_from == h, "the view says the page loaded, from its window");
    HWND h2 = CreateWindowExA(0, "STATIC", "StudioSync dock test 2", WS_OVERLAPPEDWINDOW, 0, 0, 300, 200, nullptr, nullptr, nullptr, nullptr);
    CHECK(dock_view_move(h, h2) && !dock_view_move(h, h2), "the view moves alive into another window (and isn't in the first any more)");
    dock_view_post(h2, webui_dock_win_json(DOCK_WIN_STRIP, false, false, true).c_str());
    dock_view_resize(h2);
    dock_view_show(h2, false);
    dock_view_destroy(h2);
    dock_view_destroy(h2); // (twice: nothing)
    dock_view_destroy(nullptr);
    CHECK(!dock_view_move(h2, h), "the view closed");
    DestroyWindow(h2);
  }
  // the window itself: frame, opacity, owner (plain Win32 on hidden windows)
  HWND o = CreateWindowExA(0, "STATIC", "owner", WS_POPUP, 0, 0, 10, 10, nullptr, nullptr, nullptr, nullptr);
  dock_win_frame(h, false);
  CHECK(!(GetWindowLongPtr(h, GWL_STYLE) & (WS_CAPTION | WS_THICKFRAME)), "no frame for the strip, the button and full screen");
  dock_win_frame(h, true);
  CHECK((GetWindowLongPtr(h, GWL_STYLE) & (WS_CAPTION | WS_THICKFRAME)) == (WS_CAPTION | WS_THICKFRAME), "the frame back for full");
  dock_win_alpha(h, 25);
  BYTE a = 0;
  DWORD fl = 0;
  CHECK((GetWindowLongPtr(h, GWL_EXSTYLE) & WS_EX_LAYERED) && GetLayeredWindowAttributes(h, nullptr, &a, &fl) && a == 63 && (fl & LWA_ALPHA), "faded: 25 %");
  dock_win_alpha(h, 100);
  CHECK(!(GetWindowLongPtr(h, GWL_EXSTYLE) & WS_EX_LAYERED), "full again: a plain window");
  dock_win_owner(h, o, true);
  CHECK((HWND)GetWindowLongPtr(h, GWLP_HWNDPARENT) == o, "owned: kept in front of REAPER");
  dock_win_owner(h, o, false);
  CHECK((HWND)GetWindowLongPtr(h, GWLP_HWNDPARENT) == nullptr, "no owner: REAPER can cover it");
  DestroyWindow(o);
  DestroyWindow(h);
  webui_shutdown();
  // (the browser processes let go of the folder a moment after the view closes)
  const std::string dir = std::string(tmp) + "ss_webui_dock_test";
  for (int i = 0; i < 20 && GetFileAttributesA(dir.c_str()) != INVALID_FILE_ATTRIBUTES; i++) {
    std::string from = dir + '\0';
    SHFILEOPSTRUCTA op = {};
    op.wFunc = FO_DELETE;
    op.pFrom = from.c_str();
    op.fFlags = FOF_NO_UI;
    SHFileOperationA(&op);
    Sleep(250);
  }
}
#endif

int main(int argc, char **argv)
{
  (void)argc;
  (void)argv;
  // the server's port
  CHECK(webui_dock_port("{\"listening\":true,\"bind\":\"127.0.0.1\",\"port\":47281,\"error\":\"\"}") == 47281, "port while listening");
  CHECK(webui_dock_port("{\"listening\":false,\"port\":47281}") == 0, "no port while it isn't");
  CHECK(webui_dock_port("{\"listening\":true,\"port\":70000}") == 0 && webui_dock_port("{\"listening\":true}") == 0, "no port out of range or missing");
  CHECK(webui_dock_port(nullptr) == 0 && webui_dock_port("") == 0, "no port from nothing");

  // the address
  CHECK(webui_dock_url(47281, true) == "http://127.0.0.1:47281/?host=docked", "docked address");
  CHECK(webui_dock_url(5000, false) == "http://127.0.0.1:5000/?host=floating", "floating address");

  // WebView2's own user-data folder, under REAPER's resource path
#ifdef _WIN32
  CHECK(webui_dock_data_dir("C:\\REAPER\\") == "C:\\REAPER\\Data\\StudioSync\\WebView2", "user-data folder (Windows, trailing slash)");
  CHECK(webui_dock_data_dir("D:/Portable/REAPER") == "D:/Portable/REAPER\\Data\\StudioSync\\WebView2", "user-data folder (Windows, forward slashes)");
#else
  CHECK(webui_dock_data_dir("/Users/x/Library/Application Support/REAPER/") == "/Users/x/Library/Application Support/REAPER/Data/StudioSync/WebView2",
        "user-data folder (POSIX)");
#endif

  // where the view may go
  const std::string page = webui_dock_url(47281, true);
  CHECK(webui_dock_same_origin(page, "http://127.0.0.1:47281/api/state"), "same origin: a path");
  CHECK(webui_dock_same_origin(page, "http://127.0.0.1:47281"), "same origin: the bare origin (a message's source on macOS)");
  CHECK(webui_dock_same_origin(page, page), "same origin: the page itself");
  const char *away[] = { "http://127.0.0.1:472810/", "http://127.0.0.1:47281@evil.example/", "https://127.0.0.1:47281/", "http://localhost:47281/",
                         "http://127.0.0.1:4728/", "javascript:alert(1)", "about:blank", "", "http://evil.example/http://127.0.0.1:47281/" };
  bool none = true;
  for (const char *u : away) if (webui_dock_same_origin(page, u)) { none = false; printf("     let in: %s\n", u); }
  CHECK(none, "anything else isn't the pages' origin");
  CHECK(!webui_dock_same_origin("", "http://127.0.0.1:47281/") && !webui_dock_same_origin("nonsense", "nonsense"), "no page, no origin");
  CHECK(webui_dock_external_ok("https://example.com/a?b=c") && webui_dock_external_ok("http://example.com"), "http(s) links go to the browser");
  CHECK(!webui_dock_external_ok("file:///C:/Windows/notepad.exe") && !webui_dock_external_ok("javascript:alert(1)") &&
        !webui_dock_external_ok("ms-settings:") && !webui_dock_external_ok("https://a.example/ x") && !webui_dock_external_ok("https://a\n"),
        "nothing else does (no files, schemes or spaces)");

  // what the view's page may use (video calls: camera 2 and microphone 1 for the pages' own origin; anyone else refused)
  CHECK(webui_dock_permission(page, "http://127.0.0.1:47281/", 2) == 1 && webui_dock_permission(page, "http://127.0.0.1:47281", 1) == 1,
        "camera and microphone for the pages' own origin (a URL, or the bare origin as macOS gives it)");
  CHECK(webui_dock_permission(page, "http://127.0.0.1:47281/", 4) == 0 && webui_dock_permission(page, "http://127.0.0.1:47281/", 0) == 0,
        "anything else the pages ask for: the view's own default");
  bool refused = true;
  for (const char *u : away) for (int k = 0; k <= 13; k++) if (webui_dock_permission(page, u, k) != -1) { refused = false; printf("     allowed: %s %d\n", u, k); }
  CHECK(refused, "every other origin refused, whatever it asks for");

  // keys from the page
  int vk = 0, mods = 0;
  CHECK(webui_dock_key("key:32:0", &vk, &mods) && vk == 32 && mods == 0, "Space");
  CHECK(webui_dock_key("key:83:2", &vk, &mods) && vk == 83 && mods == 2, "Ctrl+S");
  CHECK(webui_dock_key("key:90:9", &vk, &mods) && vk == 90 && mods == 9, "Shift+Cmd+Z");
  const char *bad[] = { "key:0:0", "key:255:0", "key:32:16", "key:32:-1", "key:32:0x", "key:32", "kex:32:0", "dock", "", "key:32:0:1" };
  bool rejected = !webui_dock_key(nullptr, &vk, &mods);
  for (const char *b : bad) if (webui_dock_key(b, &vk, &mods)) { rejected = false; printf("     taken: %s\n", b); }
  CHECK(rejected, "anything else isn't a key");

  // the window's shapes (rt-ui8): what the page asks
  CHECK(webui_dock_win("win:full") == DOCK_WIN_FULL && webui_dock_win("win:strip") == DOCK_WIN_STRIP && webui_dock_win("win:button") == DOCK_WIN_BUTTON &&
        webui_dock_win("win:fullscreen") == DOCK_WIN_FULLSCREEN && webui_dock_win("win:menu") == DOCK_WIN_MENU && webui_dock_win("win:drag") == DOCK_WIN_DRAG,
        "the page's asks (shell.js)");
  const char *notwin[] = { "win:", "win:Full", "win:full ", "win:fullx", "xwin:full", "win:float", "win:dock:left", "dock", "key:32:0", "" };
  bool nw = webui_dock_win(nullptr) == DOCK_WIN_NONE;
  for (const char *b : notwin) if (webui_dock_win(b) != DOCK_WIN_NONE) { nw = false; printf("     taken: %s\n", b); }
  CHECK(nw, "anything else isn't one");
  CHECK(!strcmp(webui_dock_win_name(DOCK_WIN_STRIP), "strip") && !strcmp(webui_dock_win_name(DOCK_WIN_FULLSCREEN), "fullscreen") &&
        !strcmp(webui_dock_win_name(DOCK_WIN_MENU), "full") && !strcmp(webui_dock_win_name(99), "full"), "mode names (only the four shapes)");
  CHECK(webui_dock_win_json(DOCK_WIN_BUTTON, true, false, true) == "{\"win\":\"button\",\"focus\":true,\"docked\":false,\"pop\":true}" &&
        webui_dock_win_json(DOCK_WIN_FULL, false, true, false) == "{\"win\":\"full\",\"focus\":false,\"docked\":true,\"pop\":false}",
        "what the window tells the page");

  // the focus rule and the sizes
  CHECK(webui_dock_focus_rule("button") == DOCK_FOCUS_BUTTON && webui_dock_focus_rule("stay") == DOCK_FOCUS_STAY &&
        webui_dock_focus_rule("behind") == DOCK_FOCUS_BEHIND && webui_dock_focus_rule("fade") == DOCK_FOCUS_FADE, "the rules");
  CHECK(webui_dock_focus_rule("strip") == DOCK_FOCUS_STRIP && webui_dock_focus_rule("") == DOCK_FOCUS_STRIP && webui_dock_focus_rule(nullptr) == DOCK_FOCUS_STRIP &&
        webui_dock_focus_rule("Fade") == DOCK_FOCUS_STRIP, "the strip by default (James, 2026-11-27), and for anything unknown");
  CHECK(webui_dock_button_px("22") == 22 && webui_dock_button_px("56") == 56 && webui_dock_button_px("30") == 28 && webui_dock_button_px("") == 28 &&
        webui_dock_button_px(nullptr) == 28, "the button's sizes: 22, 28, 40, 56");
  int sw = 0, sh = 0;
  webui_dock_shape(DOCK_WIN_STRIP, 28, 1.0, &sw, &sh);
  CHECK(sw == 380 && sh == 36, "the strip: 380 x 36");
  webui_dock_shape(DOCK_WIN_STRIP, 28, 1.5, &sw, &sh);
  CHECK(sw == 570 && sh == 54, "at 150 %: 570 x 54");
  webui_dock_shape(DOCK_WIN_BUTTON, 40, 1.25, &sw, &sh);
  CHECK(sw == 50 && sh == 50, "the button: square, scaled");
  webui_dock_shape(DOCK_WIN_FULL, 40, 1.0, &sw, &sh);
  CHECK(sw == 0 && sh == 0, "no shape size for the others");
  webui_dock_shape(DOCK_WIN_BUTTON, 28, 0.0, &sw, &sh);
  CHECK(sw == 28, "a nonsense scale counts as 1");

  // places: kept inside REAPER's window, and on a monitor
  const dock_rect mon = { 0, 0, 1920, 1040 }, mon2 = { -1280, 0, 0, 1024 }, reaper = { 100, 50, 1500, 950 };
  dock_rect p = webui_dock_place(300, 200, 380, 36, reaper, mon);
  CHECK(p.l == 300 && p.t == 200 && p.r == 680 && p.b == 236, "where it was dropped, inside REAPER's window");
  p = webui_dock_place(1400, 940, 380, 36, reaper, mon);
  CHECK(p.l == 1120 && p.t == 914, "past REAPER's right and bottom edges: pulled back in");
  p = webui_dock_place(-50, -50, 28, 28, reaper, mon);
  CHECK(p.l == 100 && p.t == 50, "above and left of it: its top-left corner");
  p = webui_dock_place(-900, 100, 380, 36, reaper, mon2);
  CHECK(p.l == -900 && p.t == 100, "REAPER on another monitor: kept on this one, where it was dropped (a monitor left of the main one)");
  p = webui_dock_place(-100, 2000, 380, 36, reaper, mon2);
  CHECK(p.l == -380 && p.t == 988, "and on that monitor");
  const dock_rect tiny = { 10, 10, 200, 30 };
  p = webui_dock_place(50, 15, 380, 36, tiny, mon);
  CHECK(p.l == 50 && p.t == 15 && p.r - p.l == 380, "REAPER's window too small for it: the monitor");
  p = webui_dock_place(10, 10, 3000, 36, reaper, mon);
  CHECK(p.l == 0 && p.r == 3000, "wider than the monitor: its left edge");

  // the cover test (the panel's ui.should_hide)
  const dock_rect view = { 100, 100, 500, 700 };
  const dock_fg fg = { true, false, true, false, true, { 0, 0, 1920, 1040 } };
  CHECK(webui_dock_covers(view, 800, 300, fg), "a click on REAPER's main window under it: shrink");
  CHECK(!webui_dock_covers(view, 300, 300, fg), "a click on the view itself: no");
  dock_fg f2 = fg;
  f2.any = false;
  CHECK(!webui_dock_covers(view, 800, 300, f2), "nothing has the focus (another app's window, on macOS): no");
  f2 = fg;
  f2.dialog = true;
  CHECK(!webui_dock_covers(view, 800, 300, f2), "a dialog or a menu: no");
  f2 = fg;
  f2.reapers = false;
  CHECK(!webui_dock_covers(view, 800, 300, f2), "another app: no");
  f2 = fg;
  f2.ours = true;
  CHECK(!webui_dock_covers(view, 800, 300, f2), "one of StudioSync's own windows (a pop-out): no");
  f2 = fg;
  f2.rect = { 1920, 0, 3840, 1080 };
  CHECK(!webui_dock_covers(view, 2000, 300, f2), "a REAPER window on another monitor: no");
  f2.rect = { 500, 100, 900, 700 };
  CHECK(!webui_dock_covers(view, 600, 300, f2), "one just beside it (touching): no");
  f2.rect = { 499, 100, 900, 700 };
  CHECK(webui_dock_covers(view, 600, 300, f2), "one it overlaps by a pixel: shrink");
  f2 = fg;
  f2.has_rect = false;
  CHECK(webui_dock_covers(view, 800, 300, f2), "a REAPER window whose place isn't known: shrink");

  // pop-outs
  CHECK(webui_dock_pop_name(page, "http://127.0.0.1:47281/?pop=chat") == "chat", "a pop-out: chat");
  CHECK(webui_dock_pop_name(page, "http://127.0.0.1:47281/?pop=project%2Fbeat") == "project_beat" &&
        webui_dock_pop_name(page, "http://127.0.0.1:47281/index.html?pop=project/beat#x") == "project_beat", "a sub-tab (tabs.js encodes the slash)");
  CHECK(webui_dock_pop_name(page, "http://127.0.0.1:47281/?pop=share&call=c-123") == "share" &&
        webui_dock_pop_name(page, "http://127.0.0.1:47281/?t=x&pop=plugins%2ftry") == "plugins_try", "call.js's share, and pop after another field");
  const char *notpop[] = { "http://127.0.0.1:47281/", "http://127.0.0.1:47281/?pop=", "http://127.0.0.1:47281/?xpop=chat", "http://127.0.0.1:47281/x?pop=chat",
                           "http://127.0.0.1:47281/listen.html?pop=chat", "http://127.0.0.1:47281/?pop=Chat", "http://127.0.0.1:47281/?pop=..%2Fx",
                           "http://127.0.0.1:47281/?pop=a%20b", "http://127.0.0.1:47281/?pop=a_b", "http://evil.example/?pop=chat",
                           "http://127.0.0.1:472810/?pop=chat", "http://127.0.0.1:47281/?pop=abcdefghijabcdefghijabcdefghijabc", "https://example.com/" };
  bool np = true;
  for (const char *u : notpop) if (!webui_dock_pop_name(page, u).empty()) { np = false; printf("     a pop-out: %s\n", u); }
  CHECK(np, "anything else isn't (it goes to the browser, if anywhere)");

#ifdef _WIN32
  headless(argv[0]);
#endif
  printf(fails ? "FAILED %d\n" : "all ok\n", fails);
  return fails ? 1 : 0;
}
