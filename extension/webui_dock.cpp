// StudioSync's web UI in a REAPER window that docks: see webui_dock.h. The window is REAPER's usual docker citizen: DockWindowAddEx with
// its own ident (REAPER remembers which docker and where), a toggle action ticked while it's open, the page's Dock / Undock button to move
// it in or out of the docker (the window is made again: a docked window and a floating one are different kinds), the floating size and
// place kept in ExtState, and closed at unload and REAPER's exit. macOS's view is in webui_dock_mac.mm, Linux's (WebKitGTK) below; the rest
// of this file is shared.
//
// Keys (the roadmap's stated risk). WebView2 draws in its own process, so keys typed into it never reach REAPER's message loop and REAPER's
// shortcuts would stop while the view has focus. The page passes them on: app.js sends each keydown it doesn't use over the view's own
// channel as "key:<vk>:<mods>" (outside a text field every key but Tab, and Enter on a button; in a field only Ctrl/Cmd/Alt combinations
// that aren't editing, and F-keys; Esc leaves the field), and this file hands it to REAPER's main section with kbd_translateAccelerator,
// which runs whatever the key is bound to there. WebView2's browser shortcuts (Ctrl+F, F5, Ctrl+P, zoom) are off, so those reach the page
// and go on to REAPER too. A keydown on the window itself (its frame focused) goes to REAPER's main shortcuts through the accelerator hook.
// On macOS the view is in REAPER's own process, so the hook gives the view its keys first (else Space in the chat box would press Play) and
// the page passes on the rest in the same way. Linux: SWELL hands the view the window's keys while it has focus, the page the rest, as on
// Windows. GPL-3.0-or-later. (James, rt)
#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <wrl.h>
#include "third_party/webview2/include/WebView2.h" // (Microsoft.Web.WebView2 1.0.4314.35: third_party/README.md)
#elif !defined(__APPLE__)
#include <spawn.h>
#include <sys/wait.h>
#include <thread>
extern char **environ;
#endif
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include "webui_dock.h"

// ---- the pure parts ------------------------------------------------------------------------------------------------------------------
int webui_dock_port(const char *s)
{
  if (!s || !strstr(s, "\"listening\":true")) return 0;
  const char *p = strstr(s, "\"port\":");
  const int port = p ? atoi(p + 7) : 0;
  return port > 0 && port < 65536 ? port : 0;
}

std::string webui_dock_url(int port, bool docked)
{
  return "http://127.0.0.1:" + std::to_string(port) + "/?host=" + (docked ? "docked" : "floating");
}

std::string webui_dock_data_dir(const std::string &res)
{
#ifdef _WIN32
  const char sep = '\\';
#else
  const char sep = '/';
#endif
  std::string d = res;
  while (!d.empty() && (d.back() == '/' || d.back() == '\\')) d.pop_back();
  return d + sep + "Data" + sep + "StudioSync" + sep + "WebView2";
}

// The scheme, host and port: everything before the first '/' after "://".
static std::string origin_of(const std::string &u)
{
  const size_t s = u.find("://");
  if (s == std::string::npos || s == 0) return "";
  const size_t e = u.find('/', s + 3);
  return u.substr(0, e);
}

bool webui_dock_same_origin(const std::string &page, const std::string &uri)
{
  const std::string o = origin_of(page);
  if (o.empty() || uri.compare(0, o.size(), o) != 0) return false;
  return uri.size() == o.size() || uri[o.size()] == '/'; // (so not http://127.0.0.1:47281@elsewhere/ nor port 472810)
}

bool webui_dock_external_ok(const std::string &uri)
{
  if (uri.compare(0, 7, "http://") != 0 && uri.compare(0, 8, "https://") != 0) return false;
  for (unsigned char c : uri) if (c <= ' ' || c == 127) return false;
  return true;
}

int webui_dock_permission(const std::string &page, const std::string &uri, int kind)
{
  if (!webui_dock_same_origin(page, uri)) return -1;
  return kind == 1 || kind == 2 ? 1 : 0;
}

bool webui_dock_key(const char *m, int *vk, int *mods)
{
  int k = 0, f = 0, n = 0;
  if (!m || sscanf(m, "key:%d:%d%n", &k, &f, &n) != 2 || m[n] || k < 1 || k > 254 || f < 0 || f > 15) return false;
  *vk = k;
  *mods = f;
  return true;
}

// ---- the view: WebView2 (Windows) -----------------------------------------------------------------------------------------------------
#ifdef _WIN32
using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
static ComPtr<ICoreWebView2Controller> g_ctl;
static ComPtr<ICoreWebView2> g_wv;
static HWND g_vhwnd;
static int g_gen; // (a view made again before the last one finished starting: the late callbacks see a newer number and stop)
static dock_msg_fn g_fn;
static std::string g_page;

static std::wstring wide(const std::string &s)
{
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  std::wstring w(n > 1 ? n - 1 : 0, L'\0');
  if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], n);
  return w;
}
static std::string take(LPWSTR p) // (a string WebView2 gave: UTF-8, and freed)
{
  std::string s;
  if (p) {
    const int n = WideCharToMultiByte(CP_UTF8, 0, p, -1, nullptr, 0, nullptr, nullptr);
    if (n > 1) { s.resize(n - 1); WideCharToMultiByte(CP_UTF8, 0, p, -1, &s[0], n, nullptr, nullptr); }
    CoTaskMemFree(p);
  }
  return s;
}
static void fail(int gen, const char *what, HRESULT hr)
{
  if (gen != g_gen || !g_fn) return;
  char b[160];
  snprintf(b, sizeof(b), "error:%s (0x%08lX)", what, (unsigned long)hr);
  g_fn(b);
}

// ---- camera, microphone and screen capture (video calls and screen share: lib/webui/call.js) ---------------------------------------------
// WebView2 asks the host. The camera and microphone are allowed for the pages' own origin only (webui_dock_permission: the call page asks
// only on a click, Call / Answer / Share, and only our pages are ever in the view); any other origin is refused. Screen capture isn't one
// of those kinds: WebView2 shows its own picker, and ScreenCaptureStarting (runtimes that have it) cancels it for anything but the pages'
// origin. (James, rt)
static_assert(COREWEBVIEW2_PERMISSION_KIND_MICROPHONE == 1 && COREWEBVIEW2_PERMISSION_KIND_CAMERA == 2, "webui_dock_permission's kind numbers");
static void media_permissions()
{
  EventRegistrationToken t;
  g_wv->add_PermissionRequested(Callback<ICoreWebView2PermissionRequestedEventHandler>(
    [](ICoreWebView2 *, ICoreWebView2PermissionRequestedEventArgs *a) -> HRESULT {
      LPWSTR u = nullptr;
      COREWEBVIEW2_PERMISSION_KIND k = COREWEBVIEW2_PERMISSION_KIND_UNKNOWN_PERMISSION;
      a->get_Uri(&u);
      a->get_PermissionKind(&k);
      const int r = webui_dock_permission(g_page, take(u), (int)k);
      if (r) a->put_State(r > 0 ? COREWEBVIEW2_PERMISSION_STATE_ALLOW : COREWEBVIEW2_PERMISSION_STATE_DENY);
      return S_OK;
    }).Get(), &t);
  ComPtr<ICoreWebView2_27> w27;
  if (FAILED(g_wv.As(&w27)) || !w27) return; // (an older runtime: its picker, and only our pages are in the view)
  w27->add_ScreenCaptureStarting(Callback<ICoreWebView2ScreenCaptureStartingEventHandler>(
    [](ICoreWebView2 *, ICoreWebView2ScreenCaptureStartingEventArgs *a) -> HRESULT {
      ComPtr<ICoreWebView2FrameInfo> f;
      LPWSTR src = nullptr;
      if (SUCCEEDED(a->get_OriginalSourceFrameInfo(&f)) && f) f->get_Source(&src);
      if (!webui_dock_same_origin(g_page, take(src))) a->put_Cancel(TRUE);
      return S_OK;
    }).Get(), &t);
}

static void setup(ICoreWebView2Controller *c, int gen)
{
  g_ctl = c;
  if (FAILED(c->get_CoreWebView2(&g_wv)) || !g_wv) { fail(gen, "WebView2 gave no view", E_FAIL); return; }
  ComPtr<ICoreWebView2Settings> s;
  if (SUCCEEDED(g_wv->get_Settings(&s))) {
    s->put_IsStatusBarEnabled(FALSE);
    s->put_IsZoomControlEnabled(FALSE); // (Ctrl+wheel over a docker would zoom the page by accident)
    ComPtr<ICoreWebView2Settings3> s3;
    if (SUCCEEDED(s.As(&s3))) s3->put_AreBrowserAcceleratorKeysEnabled(FALSE); // (Ctrl+F, F5, Ctrl+P... reach the page, and so REAPER)
  }
  EventRegistrationToken t;
  g_wv->add_WebMessageReceived(Callback<ICoreWebView2WebMessageReceivedEventHandler>(
    [](ICoreWebView2 *, ICoreWebView2WebMessageReceivedEventArgs *a) -> HRESULT {
      LPWSTR src = nullptr, m = nullptr;
      a->get_Source(&src);
      if (!webui_dock_same_origin(g_page, take(src)) || FAILED(a->TryGetWebMessageAsString(&m))) return S_OK;
      const std::string msg = take(m);
      if (g_fn) g_fn(msg.c_str());
      return S_OK;
    }).Get(), &t);
  // Only the pages' own origin in the view; a link anywhere else opens in the browser (a click, so it's wanted), the rest goes nowhere.
  g_wv->add_NavigationStarting(Callback<ICoreWebView2NavigationStartingEventHandler>(
    [](ICoreWebView2 *, ICoreWebView2NavigationStartingEventArgs *a) -> HRESULT {
      LPWSTR u = nullptr;
      a->get_Uri(&u);
      const std::string uri = take(u);
      if (webui_dock_same_origin(g_page, uri)) return S_OK;
      a->put_Cancel(TRUE);
      if (webui_dock_external_ok(uri)) dock_open_external(uri.c_str());
      return S_OK;
    }).Get(), &t);
  g_wv->add_NewWindowRequested(Callback<ICoreWebView2NewWindowRequestedEventHandler>(
    [](ICoreWebView2 *, ICoreWebView2NewWindowRequestedEventArgs *a) -> HRESULT {
      LPWSTR u = nullptr;
      a->get_Uri(&u);
      const std::string uri = take(u);
      a->put_Handled(TRUE);
      if (webui_dock_external_ok(uri)) dock_open_external(uri.c_str());
      return S_OK;
    }).Get(), &t);
  media_permissions();
  dock_view_resize();
  g_wv->Navigate(wide(g_page).c_str());
}

bool dock_view_create(void *hwnd, const char *url, const char *data_dir, dock_msg_fn on_message, std::string &err)
{
  dock_view_destroy();
  static bool com = false;
  if (!com) {
    if (CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED) == RPC_E_CHANGED_MODE) { err = "REAPER's main thread can't host WebView2 (COM)"; return false; }
    com = true; // shortcut: never CoUninitialize'd, as REAPER's main thread keeps COM for its own drag and drop till it quits
  }
  LPWSTR ver = nullptr;
  if (FAILED(GetAvailableCoreWebView2BrowserVersionString(nullptr, &ver)) || !ver) {
    err = "The Microsoft Edge WebView2 Runtime isn't installed here (Windows 11 has it; for Windows 10 it's at "
          "developer.microsoft.com/microsoft-edge/webview2).";
    return false;
  }
  CoTaskMemFree(ver);
  const std::wstring dir = wide(data_dir ? data_dir : "");
  SHCreateDirectoryExW(nullptr, dir.c_str(), nullptr); // (the folders above it too)
  g_vhwnd = (HWND)hwnd;
  g_fn = on_message;
  g_page = url ? url : "";
  const int gen = ++g_gen;
  const HRESULT hr = CreateCoreWebView2EnvironmentWithOptions(nullptr, dir.c_str(), nullptr,
    Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>([gen](HRESULT r, ICoreWebView2Environment *env) -> HRESULT {
      if (gen != g_gen) return S_OK;
      if (FAILED(r) || !env) { fail(gen, "WebView2 couldn't start", r); return S_OK; }
      const HRESULT r2 = env->CreateCoreWebView2Controller(g_vhwnd, Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
        [gen](HRESULT r3, ICoreWebView2Controller *c) -> HRESULT {
          if (gen != g_gen) { if (c) c->Close(); return S_OK; }
          if (FAILED(r3) || !c) { fail(gen, "WebView2 couldn't make its view", r3); return S_OK; }
          setup(c, gen);
          return S_OK;
        }).Get());
      if (FAILED(r2)) fail(gen, "WebView2 couldn't make its view", r2);
      return S_OK;
    }).Get());
  if (FAILED(hr)) {
    char b[120];
    snprintf(b, sizeof(b), "WebView2 couldn't start (0x%08lX)", (unsigned long)hr);
    err = b;
    return false;
  }
  return true;
}

void dock_view_resize()
{
  if (!g_ctl || !g_vhwnd) return;
  RECT r;
  GetClientRect(g_vhwnd, &r);
  g_ctl->put_Bounds(r);
}
void dock_view_show(bool visible) { if (g_ctl) g_ctl->put_IsVisible(visible ? TRUE : FALSE); }
void dock_view_destroy()
{
  ++g_gen;
  if (g_ctl) g_ctl->Close();
  g_wv.Reset();
  g_ctl.Reset();
  g_vhwnd = nullptr;
  g_fn = nullptr;
}
void dock_open_external(const char *url) { ShellExecuteW(nullptr, L"open", wide(url).c_str(), nullptr, nullptr, SW_SHOWNORMAL); }

// ---- the view: WebKitGTK (Linux) ------------------------------------------------------------------------------------------------------
// SWELL draws REAPER's windows itself on GDK, so a GTK widget can't simply be a child of one. But it has what Linux plug-in windows use:
// SWELL_ExtendedAPI("LOAD_GTK") starts GTK 3 inside REAPER (SWELL keeps its event handler and passes GTK's own windows their events), and
// SWELL_CreateXBridgeWindow makes a child that is a real X window, kept at the child's place (moved with its docker, re-parented when the
// docker floats). A GtkPlug (GTK's window for living inside another program's X window) goes in that, the WebKitWebView in the plug. Keys:
// while the bridge has SWELL's focus (a click in the view gives it), SWELL sends the window's keys on to the plug, and the page passes on what
// it doesn't use as on the other systems. WebKitGTK is looked up at run time, so the extension loads where it isn't installed; there the
// action says so and offers the browser, as with no WebView2. Checked on Ubuntu 24.04 with REAPER 7.86's libSwell (2026-11-19). (James, rt)
#elif !defined(__APPLE__)
#ifdef SWELL_PROVIDED_BY_APP
#include <dlfcn.h>
#include "reaper_plugin.h" // (SWELL)

// GTK's, GLib's and WebKitGTK's C functions used here (no headers: the build machine needn't have them). WebKitGTK 4.1 or 4.0 (GTK 3).
#define WK_FUNCS(X) \
  X(void *, gtk_plug_new, (unsigned long)) \
  X(void, gtk_container_add, (void *, void *)) \
  X(void, gtk_widget_show_all, (void *)) \
  X(void, gtk_widget_destroy, (void *)) \
  X(unsigned long, g_signal_connect_data, (void *, const char *, void *, void *, void *, int)) \
  X(void, g_object_set, (void *, const char *, ...)) \
  X(void *, g_object_new, (unsigned long, const char *, ...)) \
  X(void, g_object_unref, (void *)) \
  X(void, g_free, (void *)) \
  X(int, g_type_check_instance_is_a, (void *, unsigned long)) \
  X(unsigned long, webkit_web_view_get_type, ()) \
  X(void *, webkit_web_view_get_settings, (void *)) \
  X(void, webkit_web_view_load_uri, (void *, const char *)) \
  X(const char *, webkit_web_view_get_uri, (void *)) \
  X(void *, webkit_web_context_new_with_website_data_manager, (void *)) \
  X(void *, webkit_website_data_manager_new, (const char *, ...)) \
  X(void *, webkit_user_content_manager_new, ()) \
  X(int, webkit_user_content_manager_register_script_message_handler, (void *, const char *)) \
  X(void *, webkit_javascript_result_get_js_value, (void *)) \
  X(int, jsc_value_is_string, (void *)) \
  X(char *, jsc_value_to_string, (void *)) \
  X(void *, webkit_navigation_policy_decision_get_navigation_action, (void *)) \
  X(void *, webkit_navigation_action_get_request, (void *)) \
  X(int, webkit_navigation_action_get_navigation_type, (void *)) \
  X(const char *, webkit_uri_request_get_uri, (void *)) \
  X(void, webkit_policy_decision_ignore, (void *)) \
  X(unsigned long, webkit_user_media_permission_request_get_type, ()) \
  X(int, webkit_user_media_permission_is_for_audio_device, (void *)) \
  X(int, webkit_user_media_permission_is_for_video_device, (void *)) \
  X(void, webkit_permission_request_allow, (void *)) \
  X(void, webkit_permission_request_deny, (void *))
#define WK_FIELD(r, n, a) r (*n) a;
static struct { WK_FUNCS(WK_FIELD) } wk;
static void *g_plug, *g_view, *g_ctx;
static HWND g_vhwnd, g_bridge;
static dock_msg_fn g_fn;
static std::string g_page;

// GTK started and WebKitGTK found, once. -> "" or why not.
static const char *wk_load()
{
  static std::string why = "-";
  if (why != "-") return why.c_str();
  if (!SWELL_ExtendedAPI("LOAD_GTK", nullptr)) return (why = "REAPER couldn't start GTK here, which the docked view needs.").c_str();
  // (4.1 uses libsoup 3 and 4.0 libsoup 2, and a process with both aborts: if another plug-in brought one in, the WebKitGTK that matches it)
  void *lib = nullptr;
  if (!dlopen("libsoup-2.4.so.1", RTLD_NOW | RTLD_NOLOAD)) lib = dlopen("libwebkit2gtk-4.1.so.0", RTLD_NOW | RTLD_LOCAL);
  if (!lib && !dlopen("libsoup-3.0.so.0", RTLD_NOW | RTLD_NOLOAD)) lib = dlopen("libwebkit2gtk-4.0.so.37", RTLD_NOW | RTLD_LOCAL);
  if (!lib) return (why = "WebKitGTK isn't installed here (libwebkit2gtk-4.1-0 on Ubuntu and Debian, webkit2gtk4.1 on Fedora).").c_str();
#define WK_LOAD(r, n, a) if (!(*(void **)&wk.n = dlsym(lib, #n))) return (why = "This WebKitGTK is too old (it has no " #n ").").c_str();
  WK_FUNCS(WK_LOAD)
  return (why = "").c_str();
}

static std::string view_uri() { const char *u = g_view ? wk.webkit_web_view_get_uri(g_view) : nullptr; return u ? u : ""; }

// What the page posts (window.webkit.messageHandlers.studiosync, as on macOS): text, while the view shows the pages' own origin.
static void wk_message(void *, void *res, void *)
{
  void *v = wk.webkit_javascript_result_get_js_value(res);
  if (!g_fn || !v || !wk.jsc_value_is_string(v) || !webui_dock_same_origin(g_page, view_uri())) return;
  char *s = wk.jsc_value_to_string(v);
  if (s) g_fn(s);
  wk.g_free(s);
}
// Only the pages' own origin in the view; a clicked link (or a new window) anywhere else opens in the browser, the rest goes nowhere.
static int wk_policy(void *, void *d, int type, void *)
{
  if (type != 0 && type != 1) return 0; // (a response: WebKit's own way)
  void *a = wk.webkit_navigation_policy_decision_get_navigation_action(d);
  const char *u = a ? wk.webkit_uri_request_get_uri(wk.webkit_navigation_action_get_request(a)) : nullptr;
  const std::string uri = u ? u : "";
  if (type == 0 && webui_dock_same_origin(g_page, uri)) return 0;
  const bool open = webui_dock_external_ok(uri) && (type == 1 || wk.webkit_navigation_action_get_navigation_type(a) == 0 /* a link clicked */);
  wk.webkit_policy_decision_ignore(d);
  if (open) dock_open_external(uri.c_str());
  return 1;
}
// The camera and microphone (video calls, lib/webui/call.js): for the pages' own origin only (webui_dock_permission). Screen capture keeps
// WebKit's own answer (no), so the page offers the browser for that.
static int wk_permission(void *, void *req, void *)
{
  if (!wk.g_type_check_instance_is_a(req, wk.webkit_user_media_permission_request_get_type())) return 0;
  const int kind = wk.webkit_user_media_permission_is_for_audio_device(req) ? 1 : wk.webkit_user_media_permission_is_for_video_device(req) ? 2 : 0;
  const int r = webui_dock_permission(g_page, view_uri(), kind);
  if (r > 0) wk.webkit_permission_request_allow(req);
  else if (r < 0) wk.webkit_permission_request_deny(req);
  return r != 0;
}
static int wk_click(void *, void *, void *) { if (g_bridge) SetFocus(g_bridge); return 0; } // (SWELL then sends the window's keys to the view)

bool dock_view_create(void *hwnd, const char *url, const char *data_dir, dock_msg_fn on_message, std::string &err)
{
  dock_view_destroy();
  const char *why = wk_load();
  if (*why) { err = why; return false; }
  RECT r;
  GetClientRect((HWND)hwnd, &r);
  void *xid = nullptr;
  g_bridge = SWELL_CreateXBridgeWindow((HWND)hwnd, &xid, &r);
  if (!g_bridge || !xid) {
    if (g_bridge) DestroyWindow(g_bridge);
    g_bridge = nullptr;
    err = "REAPER couldn't make an X11 window for the view here.";
    return false;
  }
  if (!g_ctx) { // (one for REAPER's run, its cookies and storage in REAPER's resource folder, never another program's)
    const std::string d = data_dir ? data_dir : "";
    g_ctx = wk.webkit_web_context_new_with_website_data_manager(wk.webkit_website_data_manager_new("base-data-directory", d.c_str(),
      "base-cache-directory", (d + "/Cache").c_str(), nullptr));
  }
  void *ucm = wk.webkit_user_content_manager_new();
  wk.webkit_user_content_manager_register_script_message_handler(ucm, "studiosync");
  wk.g_signal_connect_data(ucm, "script-message-received::studiosync", (void *)wk_message, nullptr, nullptr, 0);
  g_view = wk.g_object_new(wk.webkit_web_view_get_type(), "web-context", g_ctx, "user-content-manager", ucm, nullptr);
  wk.g_object_unref(ucm); // (the view keeps it)
  wk.g_object_set(wk.webkit_web_view_get_settings(g_view), "enable-media-stream", 1, "enable-webrtc", 1, nullptr);
  wk.g_signal_connect_data(g_view, "decide-policy", (void *)wk_policy, nullptr, nullptr, 0);
  wk.g_signal_connect_data(g_view, "permission-request", (void *)wk_permission, nullptr, nullptr, 0);
  wk.g_signal_connect_data(g_view, "button-press-event", (void *)wk_click, nullptr, nullptr, 0);
  g_plug = wk.gtk_plug_new((unsigned long)(UINT_PTR)xid);
  wk.gtk_container_add(g_plug, g_view);
  wk.gtk_widget_show_all(g_plug);
  g_vhwnd = (HWND)hwnd;
  g_fn = on_message;
  g_page = url ? url : "";
  dock_view_resize();
  wk.webkit_web_view_load_uri(g_view, g_page.c_str());
  return true;
}

void dock_view_resize()
{
  if (!g_bridge || !g_vhwnd) return;
  RECT r;
  GetClientRect(g_vhwnd, &r);
  SetWindowPos(g_bridge, nullptr, 0, 0, r.right, r.bottom, SWP_NOZORDER | SWP_NOACTIVATE);
  SetTimer(g_bridge, 1010, 1, nullptr); // (SWELL's bridge then sizes the plug to itself, once it's there)
}
void dock_view_show(bool visible) { if (g_bridge) ShowWindow(g_bridge, visible ? SW_SHOW : SW_HIDE); }
void dock_view_destroy()
{
  g_fn = nullptr;
  if (g_plug) wk.gtk_widget_destroy(g_plug); // (the view with it; before the bridge, whose X window it's in)
  if (g_bridge) DestroyWindow(g_bridge);
  g_plug = g_view = nullptr;
  g_bridge = g_vhwnd = nullptr;
}
#endif // (SWELL_PROVIDED_BY_APP; without it, tests/webui_dock_test.cpp's pure parts)

void dock_open_external(const char *url)
{
  pid_t pid;
  char *argv[] = { (char *)"xdg-open", (char *)url, nullptr };
  // (no shell: the URL is one argument; waited for on a thread of its own, so it leaves no zombie and REAPER doesn't wait)
  if (posix_spawnp(&pid, "xdg-open", nullptr, nullptr, argv, environ) == 0) std::thread([pid] { waitpid(pid, nullptr, 0); }).detach();
}
#endif

// ---- the window, the action and the ReaScript function ----------------------------------------------------------------------------------
#ifndef WEBUI_DOCK_STANDALONE
#include "reaper_plugin.h"
#include "webui.h"
#ifndef FLWIN
#define FLWIN 0x20 // (SWELL's Control key on macOS, beside FCONTROL for Cmd)
#endif

static const char *SECTION = "BandSync", *IDENT = "studiosync_webui", *TITLE = "StudioSync", *DESC = "StudioSync: Web UI (docked)";
enum { WM_DOCK_KEY = WM_USER + 0x541, WM_DOCK_TOGGLE, WM_DOCK_ERROR }; // (WM_USER: SWELL has it everywhere)

static struct {
  HWND (*GetMainHwnd)();
  const char *(*GetResourcePath)();
  const char *(*GetExtState)(const char *, const char *);
  void (*SetExtState)(const char *, const char *, const char *, bool);
  void (*DockWindowAddEx)(HWND, const char *, const char *, bool);
  void (*DockWindowActivate)(HWND);
  void (*DockWindowRemove)(HWND);
  int (*kbd_translateAccelerator)(HWND, MSG *, KbdSectionInfo *);
  KbdSectionInfo *(*SectionFromUniqueID)(int);
  int (*ShowMessageBox)(const char *, const char *, int);
} R;

static int g_cmd;
static HWND g_hwnd;
static bool g_docked;
static std::string g_err, g_url;
static gaccel_register_t g_gaccel = { { 0, 0, 0 }, nullptr };

static bool docked_pref() { const char *v = R.GetExtState(SECTION, "web ui docked"); return !(v && !strcmp(v, "0")); } // (docked unless undocked)

// Why the last open failed, for lib/webui.lua's log (the panel button opens the browser then, without a box). "" once it opens.
static int failed(const std::string &why)
{
  g_err = why;
  R.SetExtState(SECTION, "web ui dock error", why.c_str(), false);
  return -1;
}

// The server's port; started here when Live sync and the panel haven't yet (the menu at REAPER's start), with the folder lib/webui.lua
// noted and no secret: this computer only, until Live sync starts it with the studio's (within 10 s; the same port only changes the token).
static int server_port()
{
  int port = webui_dock_port(webui_status());
  const char *folder = R.GetExtState(SECTION, "web ui folder");
  if (!port && folder && *folder) {
    const int want = atoi(R.GetExtState(SECTION, "direct port")); // (lib/direct.lua's direct.port())
    webui_start(folder, "", want >= 1024 && want <= 65535 ? want : 0, "");
    port = webui_dock_port(webui_status());
  }
  return port;
}

static void offer_browser(const std::string &why)
{
  const std::string url = g_url.empty() ? std::string() : g_url.substr(0, g_url.find('?'));
  if (url.empty()) { R.ShowMessageBox(why.c_str(), TITLE, 0); return; }
  const std::string q = why + "\n\nOpen it in your browser instead?\n" + url;
  if (R.ShowMessageBox(q.c_str(), TITLE, 4 /* yes, no */) == 6 /* yes */) dock_open_external(url.c_str());
}

static int show(int mode);

static void save_rect()
{
  RECT r;
  if (!g_hwnd || g_docked || !GetWindowRect(g_hwnd, &r)) return;
  char b[64];
  snprintf(b, sizeof(b), "%d %d %d %d", (int)r.left, (int)r.top, (int)(r.right - r.left), (int)(r.bottom - r.top));
  R.SetExtState(SECTION, "web ui rect", b, true);
}

static void close_window()
{
  if (!g_hwnd) return;
  HWND h = g_hwnd;
  save_rect();
  if (g_docked) R.DockWindowRemove(h);
  dock_view_destroy();
  g_hwnd = nullptr;
  DestroyWindow(h);
}

// What the page sent (inside the view's own event: only posted on, so nothing runs REAPER or closes the view from in there).
static void on_page(const char *m)
{
  int vk = 0, mods = 0;
  if (!g_hwnd || !m) return;
  if (webui_dock_key(m, &vk, &mods)) PostMessage(g_hwnd, WM_DOCK_KEY, (WPARAM)vk, (LPARAM)mods);
  else if (!strcmp(m, "dock")) PostMessage(g_hwnd, WM_DOCK_TOGGLE, 0, 0);
  else if (!strncmp(m, "error:", 6)) { g_err = m + 6; PostMessage(g_hwnd, WM_DOCK_ERROR, 0, 0); }
}

// A key from the page, as REAPER's main window would have had it, run through the main section's shortcuts. On Windows REAPER reads Ctrl,
// Shift and Alt from the keyboard (still held as the message arrives); SWELL's key messages carry them in lParam instead.
static void forward_key(int vk, int mods)
{
  if (!R.kbd_translateAccelerator || !R.SectionFromUniqueID) return;
  MSG msg = {};
  msg.hwnd = R.GetMainHwnd();
  msg.message = WM_KEYDOWN;
  msg.wParam = (WPARAM)vk;
#ifdef _WIN32
  if (mods & 4) msg.message = WM_SYSKEYDOWN; // (Alt: as Windows sends it)
#else
  msg.lParam = FVIRTKEY | ((mods & 1) ? FSHIFT : 0) | ((mods & 8) ? FCONTROL : 0) | ((mods & 4) ? FALT : 0) | ((mods & 2) ? FLWIN : 0);
#endif
  R.kbd_translateAccelerator(msg.hwnd, &msg, R.SectionFromUniqueID(0));
}

static INT_PTR CALLBACK dlgproc(HWND h, UINT m, WPARAM w, LPARAM l)
{
  switch (m) {
  case WM_INITDIALOG: return 0;
  case WM_SIZE: if (h == g_hwnd) dock_view_resize(); break;
  case WM_SHOWWINDOW: if (h == g_hwnd) dock_view_show(w != 0); break; // (a docker tab behind another, or its docker hidden)
  case WM_COMMAND: if (LOWORD(w) == IDCANCEL) { close_window(); return 1; } break; // (the docker's own Close, and Esc on the frame)
  case WM_CLOSE: close_window(); return 1;
  case WM_DESTROY: if (h == g_hwnd) { dock_view_destroy(); g_hwnd = nullptr; } break; // (a docker REAPER closed itself, at its exit)
  case WM_DOCK_KEY: forward_key((int)w, (int)l); return 1;
  case WM_DOCK_TOGGLE: {
    const bool to = !g_docked;
    close_window(); // (as it was: its floating place kept, out of the docker)
    R.SetExtState(SECTION, "web ui docked", to ? "1" : "0", true);
    if (show(1) < 0) offer_browser(g_err);
    return 1;
  }
  case WM_DOCK_ERROR: {
    const std::string why = g_err;
    close_window();
    failed(why);
    offer_browser(why);
    return 1;
  }
  }
  return 0;
}

static HWND make_window()
{
  HWND main = R.GetMainHwnd();
#ifdef _WIN32
  // (an empty dialog from a template in memory, as SWS's docking windows are dialogs; WS_POPUP: DockWindowAddEx makes it a child)
  struct alignas(4) { DLGTEMPLATE t; WORD menu, cls, title; } tpl = {};
  tpl.t.style = WS_POPUP | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_CLIPCHILDREN;
  tpl.t.cx = 280;
  tpl.t.cy = 380;
  HMODULE mod = nullptr;
  GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCSTR)&dlgproc, &mod);
  HWND h = CreateDialogIndirectParam(mod, &tpl.t, main, dlgproc, 0);
#else
  // (SWELL: no template; 0x400001 asks for a resizable top-level window. Called directly, as this module has no dialog resources)
  HWND h = SWELL_CreateDialog(nullptr, MAKEINTRESOURCE(0x400001), main, dlgproc, 0);
#endif
  if (h) SetWindowText(h, TITLE);
  return h;
}

static void place_floating()
{
  int x = 0, y = 0, w = 0, hh = 0;
  const char *v = R.GetExtState(SECTION, "web ui rect");
  if (!v || sscanf(v, "%d %d %d %d", &x, &y, &w, &hh) != 4 || w < 200 || hh < 150) { // (first time: near REAPER's top-left)
    RECT r = {};
    GetWindowRect(R.GetMainHwnd(), &r);
    x = r.left + 80, y = r.top + 80, w = 420, hh = 600;
  } // shortcut: a place on a screen that's since gone isn't brought back on screen; Dock then Undock moves it if that bites
  SetWindowPos(g_hwnd, nullptr, x, y, w, hh, SWP_NOZORDER | SWP_NOACTIVATE);
  ShowWindow(g_hwnd, SW_SHOW);
}

// Keys on the window. Windows: WebView2 takes its keys in its own process, so only the frame's (its docker tab clicked) come here: REAPER's
// main shortcuts. macOS: the view is in REAPER's process, so its keys come here first and go to the view (else Space in the chat box would
// press Play); the page passes on what it doesn't use.
static int translate(MSG *msg, accelerator_register_t *)
{
  if (!g_hwnd || !msg || !msg->hwnd || (msg->hwnd != g_hwnd && !IsChild(g_hwnd, msg->hwnd))) return 0;
#ifdef __APPLE__
  return -1;
#else
  return -666;
#endif
}
static accelerator_register_t g_keys = { translate, true, nullptr };

// mode 1 open (or bring forward), 0 close, -1 toggle. -> 1 open, 0 closed, -1 can't here (g_err says why; the browser instead).
static int show(int mode)
{
  if (mode < 0) mode = g_hwnd && IsWindowVisible(g_hwnd) ? 0 : 1; // (open but behind another docker tab: brought forward, as SWS's do)
  if (mode == 0) { close_window(); return 0; }
  if (g_hwnd) {
    if (g_docked) R.DockWindowActivate(g_hwnd);
    else { ShowWindow(g_hwnd, SW_SHOW); SetForegroundWindow(g_hwnd); }
    return 1;
  }
  g_docked = docked_pref();
  const int port = server_port();
  g_url = port ? webui_dock_url(port, g_docked) : std::string();
  if (!port) return failed("StudioSync's web UI isn't running yet: open the StudioSync panel once (or start Live sync), then try again.");
  g_hwnd = make_window();
  if (!g_hwnd) return failed("REAPER couldn't make the window.");
  std::string err;
  if (!dock_view_create(g_hwnd, g_url.c_str(), webui_dock_data_dir(R.GetResourcePath()).c_str(), on_page, err)) {
    HWND h = g_hwnd;
    g_hwnd = nullptr;
    DestroyWindow(h);
    return failed(err);
  }
  failed("");
  if (g_docked) {
    R.DockWindowAddEx(g_hwnd, TITLE, IDENT, true); // (REAPER remembers the docker and the place by IDENT, in reaper.ini)
    R.DockWindowActivate(g_hwnd);
  } else place_floating();
  return 1;
}

static bool on_command(int command, int)
{
  if (!command || command != g_cmd) return false;
  if (show(-1) < 0) offer_browser(g_err);
  return true;
}
static int on_toggle(int command) { return command == g_cmd ? (g_hwnd && IsWindowVisible(g_hwnd) ? 1 : 0) : -1; }

// View > the item, just after StudioSync's own (reaper_menu.cpp adds it first), so they sit together. Only in the default menu, as there.
static void on_menu(const char *id, HMENU menu, int flag)
{
  if (flag != 0 || !g_cmd || !id || !menu || strcmp(id, "Main view")) return;
  const int n = GetMenuItemCount(menu);
  int at = n;
  for (int i = 0; i < n; i++) {
    char text[64] = "";
    MENUITEMINFO mi = {};
    mi.cbSize = sizeof(mi);
    mi.fMask = MIIM_TYPE;
    mi.dwTypeData = text;
    mi.cch = sizeof(text);
    if (GetMenuItemInfo(menu, i, TRUE, &mi) && !strcmp(text, "StudioSync")) { at = i + 1; break; }
  }
  MENUITEMINFO mi = {};
  mi.cbSize = sizeof(mi);
  mi.fMask = MIIM_TYPE | MIIM_ID;
  mi.fType = MFT_STRING;
  mi.dwTypeData = (char *)DESC;
  mi.wID = g_cmd;
  InsertMenuItem(menu, at, TRUE, &mi);
}

static int api_dock(int mode) { return show(mode); }
static void *va_dock(void **a, int n) { return (void *)(INT_PTR)api_dock(n > 0 ? (int)(INT_PTR)a[0] : 1); }

void webui_dock_register(reaper_plugin_info_t *rec)
{
  *(void **)&R.GetMainHwnd = rec->GetFunc("GetMainHwnd");
  *(void **)&R.GetResourcePath = rec->GetFunc("GetResourcePath");
  *(void **)&R.GetExtState = rec->GetFunc("GetExtState");
  *(void **)&R.SetExtState = rec->GetFunc("SetExtState");
  *(void **)&R.DockWindowAddEx = rec->GetFunc("DockWindowAddEx");
  *(void **)&R.DockWindowActivate = rec->GetFunc("DockWindowActivate");
  *(void **)&R.DockWindowRemove = rec->GetFunc("DockWindowRemove");
  *(void **)&R.kbd_translateAccelerator = rec->GetFunc("kbd_translateAccelerator");
  *(void **)&R.SectionFromUniqueID = rec->GetFunc("SectionFromUniqueID");
  *(void **)&R.ShowMessageBox = rec->GetFunc("ShowMessageBox");
  if (!R.GetMainHwnd || !R.GetResourcePath || !R.GetExtState || !R.SetExtState || !R.DockWindowAddEx || !R.DockWindowActivate ||
      !R.DockWindowRemove || !R.ShowMessageBox) return;
  g_cmd = rec->Register("command_id", (void *)"STUDIOSYNC_WEBUI_DOCK");
  if (!g_cmd) return;
  g_gaccel.desc = DESC;
  g_gaccel.accel.cmd = (WORD)g_cmd;
  rec->Register("gaccel", &g_gaccel);
  rec->Register("hookcommand", (void *)on_command);
  rec->Register("hookcustommenu", (void *)on_menu);
  rec->Register("toggleaction", (void *)on_toggle);
  rec->Register("accelerator", &g_keys);
  rec->Register("atexit", (void *)webui_dock_shutdown); // (REAPER quitting: the window and its view go while REAPER is all there)
  rec->Register("API_StudioSync_WebUIDock", (void *)api_dock);
  rec->Register("APIdef_StudioSync_WebUIDock", (void *)"int\0int\0mode\0"
    "StudioSync's web UI in a REAPER window that docks: mode 1 opens it (or brings it forward), 0 closes it, -1 toggles. Returns 1 open, "
    "0 closed, -1 when it can't here (no WebKitGTK on Linux, no WebView2 runtime, the web UI not started; ExtState BandSync "
    "\"web ui dock error\" says why): open the browser instead.");
  rec->Register("APIvararg_StudioSync_WebUIDock", (void *)va_dock);
}

void webui_dock_shutdown() { close_window(); }
#endif
