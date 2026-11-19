// The docked web UI (extension/webui_dock.cpp) without REAPER: the server's port from its status, the address the window opens, WebView2's
// own user-data folder, where the view may go, and the page's key messages. On Windows, when the WebView2 Runtime is installed, also the
// real thing headless: a hidden window, the view made in it with a fresh user-data folder, the pages loaded from the web UI server
// (extension/webui.cpp, standalone, on a port of its own so a running REAPER's isn't touched). Build and run: tests\build_webui_dock_test.cmd
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
static void on_msg(const char *m) { g_msg = m ? m : ""; }
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
    dock_view_resize();
    dock_view_show(false);
    dock_view_destroy();
    dock_view_destroy(); // (twice: nothing)
    CHECK(true, "the view closed");
  }
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

  // keys from the page
  int vk = 0, mods = 0;
  CHECK(webui_dock_key("key:32:0", &vk, &mods) && vk == 32 && mods == 0, "Space");
  CHECK(webui_dock_key("key:83:2", &vk, &mods) && vk == 83 && mods == 2, "Ctrl+S");
  CHECK(webui_dock_key("key:90:9", &vk, &mods) && vk == 90 && mods == 9, "Shift+Cmd+Z");
  const char *bad[] = { "key:0:0", "key:255:0", "key:32:16", "key:32:-1", "key:32:0x", "key:32", "kex:32:0", "dock", "", "key:32:0:1" };
  bool rejected = !webui_dock_key(nullptr, &vk, &mods);
  for (const char *b : bad) if (webui_dock_key(b, &vk, &mods)) { rejected = false; printf("     taken: %s\n", b); }
  CHECK(rejected, "anything else isn't a key");

#ifdef _WIN32
  headless(argv[0]);
#endif
  printf(fails ? "FAILED %d\n" : "all ok\n", fails);
  return fails ? 1 : 0;
}
