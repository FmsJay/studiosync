// StudioSync's web UI in a REAPER window that docks: see webui_dock.h. The window is REAPER's usual docker citizen: DockWindowAddEx with
// its own ident (REAPER remembers which docker and where), a toggle action ticked while it's open, the page's Dock / Undock button to move
// it in or out of the docker (a docked window and a floating one are different kinds: a new window, the same view moved into it; Linux makes
// the view again), the floating size and place kept in ExtState, and closed at unload and REAPER's exit. Floating, it also takes the strip,
// button and full-screen shapes, the focus rule and pop-out windows (rt-ui8: "the windows" below). macOS's view is in webui_dock_mac.mm, Linux's (WebKitGTK) below; the rest
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

// ---- the window's shapes (rt-ui8), pure ----------------------------------------------------------------------------------------------
static const char *const WIN_NAMES[] = { "", "full", "strip", "button", "fullscreen", "menu", "drag" };

int webui_dock_win(const char *m)
{
  if (!m || strncmp(m, "win:", 4)) return DOCK_WIN_NONE;
  for (int i = DOCK_WIN_FULL; i <= DOCK_WIN_DRAG; i++) if (!strcmp(m + 4, WIN_NAMES[i])) return i;
  return DOCK_WIN_NONE;
}

const char *webui_dock_win_name(int mode) { return mode >= DOCK_WIN_FULL && mode <= DOCK_WIN_FULLSCREEN ? WIN_NAMES[mode] : "full"; }

std::string webui_dock_win_json(int mode, bool focus, bool docked, bool pop)
{
  return std::string("{\"win\":\"") + webui_dock_win_name(mode) + "\",\"focus\":" + (focus ? "true" : "false") + ",\"docked\":" +
         (docked ? "true" : "false") + ",\"pop\":" + (pop ? "true" : "false") + "}";
}

int webui_dock_focus_rule(const char *v)
{
  static const char *const rules[] = { "strip", "button", "stay", "behind", "fade" };
  for (int i = 0; v && i < 5; i++) if (!strcmp(v, rules[i])) return i;
  return DOCK_FOCUS_STRIP;
}

int webui_dock_button_px(const char *v)
{
  const int n = v ? atoi(v) : 0;
  return n == 22 || n == 28 || n == 40 || n == 56 ? n : 28;
}

void webui_dock_shape(int mode, int button_px, double scale, int *w, int *h)
{
  if (scale < 0.5 || scale > 4) scale = 1;
  const int bw = mode == DOCK_WIN_STRIP ? 380 : mode == DOCK_WIN_BUTTON ? button_px : 0;
  const int bh = mode == DOCK_WIN_STRIP ? 36 : bw;
  *w = (int)(bw * scale + 0.5);
  *h = (int)(bh * scale + 0.5);
}

static int clampi(int v, int lo, int hi) { return hi < lo || v < lo ? lo : v > hi ? hi : v; } // (lo wins when hi < lo: the corner)

dock_rect webui_dock_place(int x, int y, int w, int h, const dock_rect &reaper, const dock_rect &monitor)
{
  dock_rect a = { reaper.l > monitor.l ? reaper.l : monitor.l, reaper.t > monitor.t ? reaper.t : monitor.t,
                  reaper.r < monitor.r ? reaper.r : monitor.r, reaper.b < monitor.b ? reaper.b : monitor.b };
  if (a.r - a.l < w || a.b - a.t < h) a = monitor; // (REAPER on another monitor, or too small for it there)
  const int l = clampi(x, a.l, a.r - w), t = clampi(y, a.t, a.b - h);
  return { l, t, l + w, t + h };
}

bool webui_dock_covers(const dock_rect &view, int mx, int my, const dock_fg &fg)
{
  if (mx >= view.l && mx < view.r && my >= view.t && my < view.b) return false; // (a click on it)
  if (!fg.any || fg.dialog || !fg.reapers || fg.ours) return false;
  if (!fg.has_rect) return true;
  return fg.rect.l < view.r && fg.rect.r > view.l && fg.rect.t < view.b && fg.rect.b > view.t;
}

std::string webui_dock_pop_name(const std::string &page, const std::string &uri)
{
  if (!webui_dock_same_origin(page, uri)) return "";
  const std::string o = origin_of(page);
  size_t q = uri.find('?', o.size());
  const std::string path = uri.substr(o.size(), q == std::string::npos ? std::string::npos : q - o.size());
  if (q == std::string::npos || (path != "/" && path != "/index.html")) return "";
  const size_t end = uri.find('#', q);
  const std::string query = uri.substr(q, end == std::string::npos ? std::string::npos : end - q); // ("?a=b&pop=chat")
  const size_t at = query.find("pop=");
  if (at == std::string::npos || (query[at - 1] != '?' && query[at - 1] != '&')) return "";
  std::string name;
  for (size_t i = at + 4; i < query.size() && query[i] != '&'; i++) {
    char c = query[i];
    if (c == '%' && i + 2 < query.size() && query[i + 1] == '2' && (query[i + 2] == 'F' || query[i + 2] == 'f')) { c = '/'; i += 2; }
    if (c == '/') c = '_';
    else if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return ""; // (a route: lower-case words)
    name += c;
  }
  return name.size() <= 32 ? name : "";
}

// ---- the views: WebView2 (Windows) ----------------------------------------------------------------------------------------------------
// One environment (browser process, user-data folder) for REAPER's run of the view; a view per window: the main one, made here, and the
// pop-outs, made when their page asks (NewWindowRequested: the new view is handed to WebView2 as the opened window, so window.opener holds and
// call.js's share can move its tile in). A view moves between windows alive (put_ParentWindow): docking, undocking, the strip and the button
// don't reload the page. (rt-ui8)
#ifdef _WIN32
using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
struct View { HWND h; ComPtr<ICoreWebView2Controller> ctl; ComPtr<ICoreWebView2> wv; };
static View g_views[8];
static ComPtr<ICoreWebView2Environment> g_env;
static HWND g_vhwnd; // (the main view's window while it starts)
static int g_gen; // (a view made again before the last one finished starting: the late callbacks see a newer number and stop)
static dock_msg_fn g_fn;
static dock_pop_fn g_pop;
static std::string g_page;

static View *view_of(HWND h) { for (View &v : g_views) if (h && v.h == h) return &v; return nullptr; }
static View *free_view() { for (View &v : g_views) if (!v.h) return &v; return nullptr; }
static View *view_by(ICoreWebView2 *w) { for (View &v : g_views) if (w && v.wv.Get() == w) return &v; return nullptr; }
static void say(ICoreWebView2 *w, const char *m) { View *v = view_by(w); if (v && g_fn) g_fn(v->h, m); }

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
static void fail(HWND h, const char *what, HRESULT hr)
{
  if (!g_fn) return;
  char b[160];
  snprintf(b, sizeof(b), "error:%s (0x%08lX)", what, (unsigned long)hr);
  g_fn(h, b);
}

// ---- camera, microphone and screen capture (video calls and screen share: lib/webui/call.js) ---------------------------------------------
// WebView2 asks the host. The camera and microphone are allowed for the pages' own origin only (webui_dock_permission: the call page asks
// only on a click, Call / Answer / Share, and only our pages are ever in the view); any other origin is refused. Screen capture isn't one
// of those kinds: WebView2 shows its own picker, and ScreenCaptureStarting (runtimes that have it) cancels it for anything but the pages'
// origin. (James, rt)
static_assert(COREWEBVIEW2_PERMISSION_KIND_MICROPHONE == 1 && COREWEBVIEW2_PERMISSION_KIND_CAMERA == 2, "webui_dock_permission's kind numbers");
static void media_permissions(ICoreWebView2 *wv)
{
  EventRegistrationToken t;
  wv->add_PermissionRequested(Callback<ICoreWebView2PermissionRequestedEventHandler>(
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
  if (FAILED(wv->QueryInterface(IID_PPV_ARGS(&w27))) || !w27) return; // (an older runtime: its picker, and only our pages are in the view)
  w27->add_ScreenCaptureStarting(Callback<ICoreWebView2ScreenCaptureStartingEventHandler>(
    [](ICoreWebView2 *, ICoreWebView2ScreenCaptureStartingEventArgs *a) -> HRESULT {
      ComPtr<ICoreWebView2FrameInfo> f;
      LPWSTR src = nullptr;
      if (SUCCEEDED(a->get_OriginalSourceFrameInfo(&f)) && f) f->get_Source(&src);
      if (!webui_dock_same_origin(g_page, take(src))) a->put_Cancel(TRUE);
      return S_OK;
    }).Get(), &t);
}

static HRESULT on_new_window(ICoreWebView2 *, ICoreWebView2NewWindowRequestedEventArgs *a);

// What every view has, the main one and the pop-outs: its settings, the page's messages, where it may go, new windows, closing, permissions.
static void hook(View &v)
{
  ICoreWebView2 *wv = v.wv.Get();
  ComPtr<ICoreWebView2Settings> s;
  if (SUCCEEDED(wv->get_Settings(&s))) {
    s->put_IsStatusBarEnabled(FALSE);
    s->put_IsZoomControlEnabled(FALSE); // (Ctrl+wheel over a docker would zoom the page by accident)
    ComPtr<ICoreWebView2Settings3> s3;
    if (SUCCEEDED(s.As(&s3))) s3->put_AreBrowserAcceleratorKeysEnabled(FALSE); // (Ctrl+F, F5, Ctrl+P... reach the page, and so REAPER)
  }
  EventRegistrationToken t;
  wv->add_WebMessageReceived(Callback<ICoreWebView2WebMessageReceivedEventHandler>(
    [](ICoreWebView2 *w, ICoreWebView2WebMessageReceivedEventArgs *a) -> HRESULT {
      LPWSTR src = nullptr, m = nullptr;
      a->get_Source(&src);
      if (!webui_dock_same_origin(g_page, take(src)) || FAILED(a->TryGetWebMessageAsString(&m))) return S_OK;
      const std::string msg = take(m);
      say(w, msg.c_str());
      return S_OK;
    }).Get(), &t);
  // Only the pages' own origin in the view; a link anywhere else opens in the browser (a click, so it's wanted), the rest goes nowhere.
  wv->add_NavigationStarting(Callback<ICoreWebView2NavigationStartingEventHandler>(
    [](ICoreWebView2 *, ICoreWebView2NavigationStartingEventArgs *a) -> HRESULT {
      LPWSTR u = nullptr;
      a->get_Uri(&u);
      const std::string uri = take(u);
      if (webui_dock_same_origin(g_page, uri)) return S_OK;
      a->put_Cancel(TRUE);
      if (webui_dock_external_ok(uri)) dock_open_external(uri.c_str());
      return S_OK;
    }).Get(), &t);
  wv->add_NavigationCompleted(Callback<ICoreWebView2NavigationCompletedEventHandler>(
    [](ICoreWebView2 *w, ICoreWebView2NavigationCompletedEventArgs *) -> HRESULT { say(w, "view:loaded"); return S_OK; }).Get(), &t);
  wv->add_WindowCloseRequested(Callback<ICoreWebView2WindowCloseRequestedEventHandler>(
    [](ICoreWebView2 *w, IUnknown *) -> HRESULT { say(w, "view:close"); return S_OK; }).Get(), &t);
  wv->add_NewWindowRequested(Callback<ICoreWebView2NewWindowRequestedEventHandler>(on_new_window).Get(), &t);
  media_permissions(wv);
}

// window.open from a page: a pop-out of ours (?pop=) gets a window and a view of its own, handed back as the opened window; anything else
// (a link with target=_blank) goes to the browser, as before.
static HRESULT on_new_window(ICoreWebView2 *, ICoreWebView2NewWindowRequestedEventArgs *a)
{
  LPWSTR u = nullptr;
  a->get_Uri(&u);
  const std::string uri = take(u);
  a->put_Handled(TRUE); // (never WebView2's own popup window)
  const std::string name = webui_dock_pop_name(g_page, uri);
  View *slot = free_view();
  int w = 0, h = 0;
  ComPtr<ICoreWebView2WindowFeatures> f;
  BOOL has = FALSE;
  if (SUCCEEDED(a->get_WindowFeatures(&f)) && f && SUCCEEDED(f->get_HasSize(&has)) && has) {
    UINT32 fw = 0, fh = 0;
    f->get_Width(&fw);
    f->get_Height(&fh);
    w = (int)fw, h = (int)fh;
  }
  HWND ph = !name.empty() && slot && g_env && g_pop ? (HWND)g_pop(name.c_str(), w, h) : nullptr;
  if (!ph) {
    if (webui_dock_external_ok(uri)) dock_open_external(uri.c_str());
    return S_OK;
  }
  slot->h = ph; // (taken now: another request before this view is made gets the next slot)
  ComPtr<ICoreWebView2Deferral> d;
  a->GetDeferral(&d);
  ComPtr<ICoreWebView2NewWindowRequestedEventArgs> args = a;
  const int gen = g_gen;
  const HRESULT hr = g_env->CreateCoreWebView2Controller(ph, Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
    [ph, d, args, gen](HRESULT r, ICoreWebView2Controller *c) -> HRESULT {
      View *v = view_of(ph);
      ComPtr<ICoreWebView2> wv;
      if (gen != g_gen || !v || FAILED(r) || !c || FAILED(c->get_CoreWebView2(&wv)) || !wv) {
        if (c) c->Close();
        if (v) v->h = nullptr;
        d->Complete();
        if (gen == g_gen) fail(ph, "WebView2 couldn't make the pop-out's view", FAILED(r) ? r : E_FAIL);
        return S_OK;
      }
      v->ctl = c;
      v->wv = wv;
      hook(*v);
      dock_view_resize(ph);
      args->put_NewWindow(wv.Get()); // (WebView2 loads the page in it: window.opener is the page that asked)
      d->Complete();
      return S_OK;
    }).Get());
  if (FAILED(hr)) { slot->h = nullptr; d->Complete(); fail(ph, "WebView2 couldn't make the pop-out's view", hr); }
  return S_OK;
}

static void start_main(ICoreWebView2Controller *c)
{
  View *v = free_view();
  ComPtr<ICoreWebView2> wv;
  if (!v || FAILED(c->get_CoreWebView2(&wv)) || !wv) { c->Close(); fail(g_vhwnd, "WebView2 gave no view", E_FAIL); return; }
  v->h = g_vhwnd;
  v->ctl = c;
  v->wv = wv;
  hook(*v);
  dock_view_resize(v->h);
  wv->Navigate(wide(g_page).c_str());
}

static void make_main(int gen)
{
  const HRESULT r2 = g_env->CreateCoreWebView2Controller(g_vhwnd, Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
    [gen](HRESULT r3, ICoreWebView2Controller *c) -> HRESULT {
      if (gen != g_gen) { if (c) c->Close(); return S_OK; }
      if (FAILED(r3) || !c) { fail(g_vhwnd, "WebView2 couldn't make its view", r3); return S_OK; }
      start_main(c);
      return S_OK;
    }).Get());
  if (FAILED(r2)) fail(g_vhwnd, "WebView2 couldn't make its view", r2);
}

bool dock_view_create(void *hwnd, const char *url, const char *data_dir, dock_msg_fn on_message, std::string &err)
{
  dock_view_destroy(nullptr);
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
      if (FAILED(r) || !env) { fail(g_vhwnd, "WebView2 couldn't start", r); return S_OK; }
      g_env = env;
      make_main(gen);
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

void dock_view_on_pop(dock_pop_fn fn) { g_pop = fn; }

void dock_view_resize(void *hwnd)
{
  View *v = view_of((HWND)hwnd);
  if (!v || !v->ctl) return;
  RECT r;
  GetClientRect(v->h, &r);
  v->ctl->put_Bounds(r);
}
void dock_view_show(void *hwnd, bool visible) { View *v = view_of((HWND)hwnd); if (v && v->ctl) v->ctl->put_IsVisible(visible ? TRUE : FALSE); }
void dock_view_destroy(void *hwnd)
{
  for (View &v : g_views) {
    if (!v.h || (hwnd && v.h != (HWND)hwnd)) continue;
    if (v.ctl) v.ctl->Close();
    v.wv.Reset();
    v.ctl.Reset();
    v.h = nullptr;
  }
  if (!hwnd || (HWND)hwnd == g_vhwnd) { ++g_gen; g_vhwnd = nullptr; } // (the main one: a start still under way stops)
  bool any = false;
  for (View &v : g_views) any = any || v.h;
  if (!any) { g_env.Reset(); g_fn = nullptr; } // (the browser process goes with the last view)
}
bool dock_view_move(void *from, void *to)
{
  View *v = view_of((HWND)from);
  if (!v || !to) return false;
  if (v->ctl && FAILED(v->ctl->put_ParentWindow((HWND)to))) return false;
  if (g_vhwnd == v->h) g_vhwnd = (HWND)to;
  v->h = (HWND)to;
  dock_view_resize(to);
  return true;
}
void dock_view_post(void *hwnd, const char *json) { View *v = view_of((HWND)hwnd); if (v && v->wv && json) v->wv->PostWebMessageAsJson(wide(json).c_str()); }
void dock_open_external(const char *url) { ShellExecuteW(nullptr, L"open", wide(url).c_str(), nullptr, nullptr, SW_SHOWNORMAL); }

// The window itself. Frame: the dialog's caption and sizing border on or off. Opacity: a layered window while faded, plain again at 100 %
// (shortcut: WebView2's drawing in a layered window is unchecked here; if it shows blank faded, Fade is still usable as "full under the
// mouse"). Owner: GWLP_HWNDPARENT, REAPER's main window or none (none: REAPER's window can cover it, and it gets a taskbar button).
bool dock_win_can() { return true; }
void dock_win_frame(void *hwnd, bool framed)
{
  HWND h = (HWND)hwnd;
  const LONG_PTR FRAME = WS_CAPTION | WS_SYSMENU | WS_THICKFRAME, s = GetWindowLongPtr(h, GWL_STYLE);
  const LONG_PTR to = framed ? (s | FRAME) : (s & ~FRAME);
  if (to == s) return;
  SetWindowLongPtr(h, GWL_STYLE, to);
  SetWindowPos(h, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
}
void dock_win_alpha(void *hwnd, int percent)
{
  HWND h = (HWND)hwnd;
  const LONG_PTR ex = GetWindowLongPtr(h, GWL_EXSTYLE);
  if (percent >= 100) { if (ex & WS_EX_LAYERED) SetWindowLongPtr(h, GWL_EXSTYLE, ex & ~WS_EX_LAYERED); return; }
  if (!(ex & WS_EX_LAYERED)) SetWindowLongPtr(h, GWL_EXSTYLE, ex | WS_EX_LAYERED);
  SetLayeredWindowAttributes(h, 0, (BYTE)(percent < 0 ? 0 : percent * 255 / 100), LWA_ALPHA);
}
void dock_win_owner(void *hwnd, void *main, bool owned)
{
  HWND h = (HWND)hwnd, want = owned ? (HWND)main : nullptr;
  if ((HWND)GetWindowLongPtr(h, GWLP_HWNDPARENT) != want) SetWindowLongPtr(h, GWLP_HWNDPARENT, (LONG_PTR)want);
}

// ---- the view: WebKitGTK (Linux) ------------------------------------------------------------------------------------------------------
// SWELL draws REAPER's windows itself on GDK, so a GTK widget can't simply be a child of one. But it has what Linux plug-in windows use:
// SWELL_ExtendedAPI("LOAD_GTK") starts GTK 3 inside REAPER (SWELL keeps its event handler and passes GTK's own windows their events), and
// SWELL_CreateXBridgeWindow makes a child that is a real X window, kept at the child's place (moved with its docker, re-parented when the
// docker floats). A GtkPlug (GTK's window for living inside another program's X window) goes in that, the WebKitWebView in the plug. Keys:
// while the bridge has SWELL's focus (a click in the view gives it), SWELL sends the window's keys on to the plug, and the page passes on what
// it doesn't use as on the other systems. WebKitGTK is looked up at run time, so the extension loads where it isn't installed; there the
// action says so and offers the browser, as with no WebView2. Checked in REAPER 7.86 on Ubuntu 24.04 (2026-11-20). (James, rt)
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
  if (s) g_fn(g_vhwnd, s);
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
  dock_view_destroy(nullptr);
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
  // (hardware-acceleration-policy 2, never: in the plug, WebKit's GPU compositing drew only its first blank 200x200 frame in REAPER on
  // Ubuntu 24.04 with xfwm4 compositing, page loaded but never shown; its own drawing works there and anywhere. 2026-11-20)
  wk.g_object_set(wk.webkit_web_view_get_settings(g_view), "enable-media-stream", 1, "enable-webrtc", 1, "hardware-acceleration-policy", 2,
    nullptr);
  wk.g_signal_connect_data(g_view, "decide-policy", (void *)wk_policy, nullptr, nullptr, 0);
  wk.g_signal_connect_data(g_view, "permission-request", (void *)wk_permission, nullptr, nullptr, 0);
  wk.g_signal_connect_data(g_view, "button-press-event", (void *)wk_click, nullptr, nullptr, 0);
  g_plug = wk.gtk_plug_new((unsigned long)(UINT_PTR)xid);
  wk.gtk_container_add(g_plug, g_view);
  wk.gtk_widget_show_all(g_plug);
  g_vhwnd = (HWND)hwnd;
  g_fn = on_message;
  g_page = url ? url : "";
  dock_view_resize(hwnd);
  wk.webkit_web_view_load_uri(g_view, g_page.c_str());
  return true;
}

// (one view, in the main window: no pop-outs here, a new window goes to the browser; and no shapes: dock_win_can is false, so the window
// never asks for a move, a frame, an opacity or an owner, and the page, told nothing, shows no strip, button or full-screen buttons. rt-ui8)
void dock_view_on_pop(dock_pop_fn) {}
bool dock_view_move(void *, void *) { return false; }
void dock_view_post(void *, const char *) {}
bool dock_win_can() { return false; }
void dock_win_frame(void *, bool) {}
void dock_win_alpha(void *, int) {}
void dock_win_owner(void *, void *, bool) {}

void dock_view_resize(void *)
{
  if (!g_bridge || !g_vhwnd) return;
  RECT r;
  GetClientRect(g_vhwnd, &r);
  SetWindowPos(g_bridge, nullptr, 0, 0, r.right, r.bottom, SWP_NOZORDER | SWP_NOACTIVATE);
  SetTimer(g_bridge, 1010, 1, nullptr); // (SWELL's bridge then sizes the plug to itself, once it's there)
}
void dock_view_show(void *, bool visible) { if (g_bridge) ShowWindow(g_bridge, visible ? SW_SHOW : SW_HIDE); }
void dock_view_destroy(void *)
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

// ---- the windows, the action and the ReaScript function ---------------------------------------------------------------------------------
// The main window and up to 6 pop-outs, each docked (a REAPER docker, by its own ident) or floating, and floating in one of four shapes
// (docs/rt/ui-web-plan.md 4.2): full (the framed window, its place kept), the strip and the button (no frame, pinned inside REAPER's window
// where they're dropped), full screen (the whole monitor, no frame; Esc or the button leaves). The page asks with "win:<shape>" and is told
// {"win", "focus", "docked", "pop"} (webui_dock_win_json). The main window's focus rule (ExtState "web ui focus") acts when a REAPER window it
// covers takes the focus. A shape change moves the same view into the window it needs (dock_view_move): nothing reloads. (rt-ui8)
#ifndef WEBUI_DOCK_STANDALONE
#include "reaper_plugin.h"
#include "webui.h"
#ifndef FLWIN
#define FLWIN 0x20 // (SWELL's Control key on macOS, beside FCONTROL for Cmd)
#endif

static const char *SECTION = "BandSync", *IDENT = "studiosync_webui", *TITLE = "StudioSync", *DESC = "StudioSync: Web UI (docked)";
enum { WM_DOCK_KEY = WM_USER + 0x541, WM_DOCK_TOGGLE, WM_DOCK_ERROR, WM_DOCK_WIN, WM_DOCK_FOCUS }; // (WM_USER: SWELL has it everywhere)
enum { TIMER_DRAG = 0x5501, TIMER_FADE };
enum { MENU_OPEN = 1, MENU_LOCK, MENU_SHAPE, MENU_CLOSE, MENU_SIZE = 10 };
static const int POPS = 6, FADED = 25;

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

struct Win {
  HWND h = nullptr;
  std::string name, ident, title; // (name "": the main window; else the pop-out's, "chat", "project_beat"; ident and title kept for REAPER)
  int mode = DOCK_WIN_FULL, pending = 0, alpha = 100, pop_w = 0, pop_h = 0;
  bool docked = false, ready = false, active = false, faded = false, moved = false;
  DWORD moved_at = 0;
  POINT grab = { 0, 0 };
};
static Win g_w[1 + POPS]; // ([0] the main window)
static Win &g_main = g_w[0];
static int g_cmd;
static std::string g_err, g_url;
static gaccel_register_t g_gaccel = { { 0, 0, 0 }, nullptr };

static Win *win_of(HWND h) { for (Win &w : g_w) if (h && w.h == h) return &w; return nullptr; }
static bool is_main(const Win &w) { return &w == &g_main; }
static const char *get(const std::string &k) { const char *v = R.GetExtState(SECTION, k.c_str()); return v ? v : ""; }
static void put(const std::string &k, const char *v) { R.SetExtState(SECTION, k.c_str(), v, true); }
// (the main window's settings are "web ui <what>", as before; a pop-out's "web ui pop <name> <what>")
static std::string key(const Win &w, const char *what) { return (w.name.empty() ? std::string("web ui ") : "web ui pop " + w.name + " ") + what; }
// (the main window docked unless undocked, as before; a pop-out floats unless docked)
static bool docked_pref(const Win &w) { const char *v = get(key(w, "docked")); return w.name.empty() ? strcmp(v, "0") != 0 : !strcmp(v, "1"); }
static int focus_rule() { return webui_dock_focus_rule(get("web ui focus")); }
static bool locked() { return !strcmp(get("web ui lock"), "1"); }

static dock_rect norm(const RECT &r)
{
  return { r.left < r.right ? (int)r.left : (int)r.right, r.top < r.bottom ? (int)r.top : (int)r.bottom,
           r.left < r.right ? (int)r.right : (int)r.left, r.top < r.bottom ? (int)r.bottom : (int)r.top };
}
static dock_rect rect_of(HWND h) { RECT r = {}; if (h) GetWindowRect(h, &r); return norm(r); }
static bool inside(const dock_rect &r, const POINT &p) { return p.x >= r.l && p.x < r.r && p.y >= r.t && p.y < r.b; }
// The monitor a rect is on (its work area: without the taskbar or menu bar; or the whole of it, for full screen).
static dock_rect monitor_of(const dock_rect &d, bool work)
{
  RECT r = { d.l, d.t, d.r, d.b };
#ifdef _WIN32
  MONITORINFO mi = {};
  mi.cbSize = sizeof(mi);
  if (GetMonitorInfo(MonitorFromRect(&r, MONITOR_DEFAULTTONEAREST), &mi)) r = work ? mi.rcWork : mi.rcMonitor;
#else
  RECT in = r;
  SWELL_GetViewPort(&r, &in, work);
#endif
  return norm(r);
}
// The display's scale where a window is (Windows: its DPI / 96, so the strip is as tall at 150 % as the page's 36 px; macOS counts in points).
static double scale_of(HWND h)
{
#ifdef _WIN32
  typedef UINT(WINAPI * dpi_fn)(HWND);
  static const dpi_fn dpi = (dpi_fn)(void *)GetProcAddress(GetModuleHandleA("user32.dll"), "GetDpiForWindow"); // (Windows 10 1607 on)
  const UINT d = dpi && h ? dpi(h) : 96;
  return d ? d / 96.0 : 1.0;
#else
  (void)h;
  return 1.0;
#endif
}

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
static INT_PTR CALLBACK dlgproc(HWND h, UINT m, WPARAM w, LPARAM l);

// The floating full window's place (screen pixels: x y w h), kept for next time.
static void save_rect(const Win &w)
{
  RECT r;
  if (!w.h || w.docked || w.mode != DOCK_WIN_FULL || !GetWindowRect(w.h, &r)) return;
  const dock_rect d = norm(r);
  char b[64];
  snprintf(b, sizeof(b), "%d %d %d %d", d.l, d.t, d.r - d.l, d.b - d.t);
  put(key(w, "rect"), b);
}

// The window's title-bar and taskbar icon (Windows: studiosync.rc's icon 101 in this DLL; macOS windows have none; Linux: not through SWELL).
static void set_icon(HWND h)
{
#ifdef _WIN32
  static HICON g_big, g_small;
  if (!g_big) {
    HMODULE mod = nullptr;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCSTR)&dlgproc, &mod);
    g_big = (HICON)LoadImageW(mod, MAKEINTRESOURCEW(101), IMAGE_ICON, GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), 0);
    g_small = (HICON)LoadImageW(mod, MAKEINTRESOURCEW(101), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0);
  }
  if (g_big) SendMessage(h, WM_SETICON, ICON_BIG, (LPARAM)g_big);
  if (g_small) SendMessage(h, WM_SETICON, ICON_SMALL, (LPARAM)g_small);
#else
  (void)h;
#endif
}

static HWND make_window(const Win &w)
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
  if (h) { SetWindowText(h, w.title.c_str()); set_icon(h); }
  return h;
}

// Where a shape goes. Full: its kept place (back on a monitor if that one's gone), else near REAPER's top-left; a pop-out at the size its page
// asked. The strip and the button: where they were dropped, else REAPER's top right under its toolbar; kept inside REAPER's window. Full
// screen: the monitor the window is on.
static dock_rect want_rect(const Win &w, int mode)
{
  const dock_rect cur = rect_of(w.h), rp = rect_of(R.GetMainHwnd());
  if (mode == DOCK_WIN_FULLSCREEN) return monitor_of(cur, false);
  if (mode == DOCK_WIN_FULL) {
    int x = 0, y = 0, ww = 0, hh = 0;
    if (sscanf(get(key(w, "rect")), "%d %d %d %d", &x, &y, &ww, &hh) != 4 || ww < 200 || hh < 150) {
      const double s = scale_of(R.GetMainHwnd());
      if (is_main(w)) x = rp.l + 80, y = rp.t + 80, ww = 420, hh = 600;
      else x = rp.l + 140, y = rp.t + 120, ww = (int)((w.pop_w > 0 ? w.pop_w : 480) * s), hh = (int)((w.pop_h > 0 ? w.pop_h : 720) * s);
    }
    const dock_rect at = { x, y, x + ww, y + hh }, mon = monitor_of(at, true);
    return webui_dock_place(x, y, ww < mon.r - mon.l ? ww : mon.r - mon.l, hh < mon.b - mon.t ? hh : mon.b - mon.t, mon, mon);
  }
  int ww = 0, hh = 0;
  webui_dock_shape(mode, webui_dock_button_px(get("web ui button size")), scale_of(R.GetMainHwnd()), &ww, &hh);
  int x = rp.r - ww - 24, y = rp.t + 64;
  sscanf(get(key(w, mode == DOCK_WIN_STRIP ? "strip" : "button")), "%d %d", &x, &y);
  const dock_rect at = { x, y, x + ww, y + hh };
  return webui_dock_place(x, y, ww, hh, rp, monitor_of(at, true));
}

static void tell(const Win &w)
{
  if (w.h && w.ready && dock_win_can()) dock_view_post(w.h, webui_dock_win_json(w.mode, w.active, w.docked, true).c_str());
}
static void set_alpha(Win &w, int pct) { if (w.alpha != pct && w.h) { dock_win_alpha(w.h, pct); w.alpha = pct; } }

// The view into a new window of the other kind (docked <-> floating), alive: a call or a share in it goes on.
static bool swap_window(Win &w, bool docked)
{
  HWND old = w.h, h = make_window(w);
  if (!h) return false;
  if (docked) R.DockWindowAddEx(h, w.title.c_str(), w.ident.c_str(), true);
  if (!dock_view_move(old, h)) {
    if (docked) R.DockWindowRemove(h);
    DestroyWindow(h);
    return false;
  }
  const bool was = w.docked;
  w.h = h; // (first: the old window's WM_DESTROY isn't this one's any more)
  w.docked = docked;
  w.alpha = 100;
  KillTimer(old, TIMER_DRAG);
  KillTimer(old, TIMER_FADE);
  if (was) R.DockWindowRemove(old);
  DestroyWindow(old);
  return true;
}

// The window to a shape: into a docker or out of it as the shape needs (full goes back where the person keeps it), the frame, the owner
// (the main window full under "go behind REAPER" has none), the place, and the page told.
static void set_mode(Win &w, int mode, bool activate)
{
  if (!w.h || !w.ready || !dock_win_can() || mode < DOCK_WIN_FULL || mode > DOCK_WIN_FULLSCREEN) return;
  const bool dock = mode == DOCK_WIN_FULL && docked_pref(w);
  save_rect(w);
  if (dock != w.docked && !swap_window(w, dock)) return;
  w.mode = mode;
  w.faded = false;
  KillTimer(w.h, TIMER_FADE);
  if (w.docked) {
    if (activate) R.DockWindowActivate(w.h);
  } else {
    dock_win_frame(w.h, mode == DOCK_WIN_FULL);
    dock_win_owner(w.h, R.GetMainHwnd(), !(is_main(w) && mode == DOCK_WIN_FULL && focus_rule() == DOCK_FOCUS_BEHIND));
    set_alpha(w, 100);
    const dock_rect r = want_rect(w, mode);
    SetWindowPos(w.h, nullptr, r.l, r.t, r.r - r.l, r.b - r.t, SWP_NOZORDER | SWP_NOACTIVATE);
    ShowWindow(w.h, activate ? SW_SHOW : SW_SHOWNA);
    if (activate) SetForegroundWindow(w.h);
  }
  dock_view_resize(w.h);
  tell(w);
}

static void close_window(Win &w)
{
  if (!w.h) return;
  if (is_main(w)) {
    for (int i = 1; i <= POPS; i++) close_window(g_w[i]); // (the pop-outs go with the main window)
    put(key(w, "mode"), w.mode == DOCK_WIN_FULLSCREEN ? "fullscreen" : ""); // (opened again where it was: full screen, docked or floating)
  }
  HWND h = w.h;
  save_rect(w);
  if (w.docked) R.DockWindowRemove(h);
  dock_view_destroy(h);
  w = Win();
  DestroyWindow(h);
}

// The strip or the button follows the mouse from a press on it (the page's "win:drag") till the button's let go, kept inside REAPER's window,
// and stays where it's dropped. (A timer, not the system's move loop: the press went to the view, maybe in another process.)
static void drag_start(Win &w)
{
  if (w.docked || (w.mode != DOCK_WIN_STRIP && w.mode != DOCK_WIN_BUTTON) || locked()) return;
  POINT p;
  GetCursorPos(&p);
  const dock_rect r = rect_of(w.h);
  w.grab.x = p.x - r.l;
  w.grab.y = p.y - r.t;
  w.moved = false;
  SetTimer(w.h, TIMER_DRAG, 15, nullptr);
}
static void drag_tick(Win &w)
{
  POINT p;
  GetCursorPos(&p);
  const dock_rect r = rect_of(w.h);
  if (!(GetAsyncKeyState(VK_LBUTTON) & 0x8000)) {
    KillTimer(w.h, TIMER_DRAG);
    if (!w.moved) return;
    char b[40];
    snprintf(b, sizeof(b), "%d %d", r.l, r.t);
    put(key(w, w.mode == DOCK_WIN_STRIP ? "strip" : "button"), b);
    w.moved_at = GetTickCount();
    return;
  }
  const dock_rect at = { (int)p.x, (int)p.y, (int)p.x + 1, (int)p.y + 1 };
  const dock_rect to = webui_dock_place(p.x - w.grab.x, p.y - w.grab.y, r.r - r.l, r.b - r.t, rect_of(R.GetMainHwnd()), monitor_of(at, true));
  if (to.l == r.l && to.t == r.t) return;
  SetWindowPos(w.h, nullptr, to.l, to.t, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  w.moved = true;
}

// Faded (the focus rule "fade"): 25 % while REAPER has the focus, full while the mouse is over it.
static void fade_tick(Win &w)
{
  if (!w.faded) { KillTimer(w.h, TIMER_FADE); set_alpha(w, 100); return; }
  POINT p;
  GetCursorPos(&p);
  set_alpha(w, inside(rect_of(w.h), p) ? 100 : FADED);
}

// What has the focus now, for webui_dock_covers.
static dock_fg foreground()
{
  dock_fg f = {};
  HWND fg = GetForegroundWindow(), main = R.GetMainHwnd();
  if (!fg) return f;
  f.any = true;
#ifdef _WIN32
  char cls[16] = "";
  GetClassNameA(fg, cls, sizeof(cls));
  f.dialog = !strcmp(cls, "#32770") || !strcmp(cls, "#32768"); // (a dialog box, a menu: Windows' own classes, as the panel's rule)
  f.reapers = fg == main || GetAncestor(fg, GA_ROOTOWNER) == main;
#else
  f.reapers = fg == main || GetParent(fg) == main || IsChild(main, fg);
#endif
  for (const Win &w : g_w) if (w.h && (fg == w.h || IsChild(w.h, fg))) f.ours = true;
  RECT r;
  f.has_rect = GetWindowRect(fg, &r) != 0;
  if (f.has_rect) f.rect = norm(r);
  return f;
}

// The focus came or went (WM_ACTIVATE, posted on: by now the other window has it). The main window, floating full or full screen, losing it
// to a REAPER window it covers: the rule.
static void on_focus(Win &w, bool active)
{
  w.active = active;
  if (active) {
    w.faded = false;
    KillTimer(w.h, TIMER_FADE);
    set_alpha(w, 100);
    if (is_main(w) && !w.docked && w.mode == DOCK_WIN_FULL && dock_win_can()) // (the rule may have changed: owned or not, before REAPER is clicked)
      dock_win_owner(w.h, R.GetMainHwnd(), focus_rule() != DOCK_FOCUS_BEHIND);
    tell(w);
    return;
  }
  tell(w);
  if (!is_main(w) || w.docked || !w.ready || !dock_win_can() || (w.mode != DOCK_WIN_FULL && w.mode != DOCK_WIN_FULLSCREEN)) return;
  const int rule = focus_rule();
  if (rule == DOCK_FOCUS_STAY || rule == DOCK_FOCUS_BEHIND) return; // (behind: it has no owner, so REAPER's window simply covers it)
  POINT p;
  GetCursorPos(&p);
  if (!webui_dock_covers(rect_of(w.h), p.x, p.y, foreground())) return;
  if (rule == DOCK_FOCUS_FADE) {
    w.faded = true;
    set_alpha(w, FADED);
    SetTimer(w.h, TIMER_FADE, 100, nullptr);
    return;
  }
  set_mode(w, rule == DOCK_FOCUS_BUTTON ? DOCK_WIN_BUTTON : DOCK_WIN_STRIP, false); // (a click on it, the toolbar button, an action or a nav with wake brings it back)
}

static void menu_item(HMENU m, int id, const char *text, bool checked, HMENU sub)
{
  MENUITEMINFO mi = {};
  mi.cbSize = sizeof(mi);
  mi.fMask = MIIM_TYPE | MIIM_ID | MIIM_STATE | (sub ? MIIM_SUBMENU : 0);
  mi.fType = MFT_STRING;
  mi.fState = checked ? MFS_CHECKED : 0;
  mi.dwTypeData = (char *)text;
  mi.wID = id;
  mi.hSubMenu = sub;
  InsertMenuItem(m, GetMenuItemCount(m), TRUE, &mi);
}

// The strip's or the button's right-click (the page's "win:menu"): as the panel's box menu.
static void shape_menu(Win &w)
{
  static const int SIZES[] = { 22, 28, 40, 56 };
  static const char *const SIZE_NAMES[] = { "Small", "Medium", "Large", "Big" };
  const bool lock = locked(), button = w.mode == DOCK_WIN_BUTTON;
  const int px = webui_dock_button_px(get("web ui button size"));
  HMENU m = CreatePopupMenu(), sizes = button ? CreatePopupMenu() : nullptr;
  menu_item(m, MENU_OPEN, "Open StudioSync", false, nullptr);
  menu_item(m, MENU_LOCK, "Lock position", lock, nullptr);
  menu_item(m, MENU_SHAPE, button ? "Make it a strip" : "Make it a button", false, nullptr);
  if (sizes) {
    for (int i = 0; i < 4; i++) menu_item(sizes, MENU_SIZE + i, SIZE_NAMES[i], SIZES[i] == px, nullptr);
    menu_item(m, 0, "Size", false, sizes);
  }
  menu_item(m, MENU_CLOSE, is_main(w) ? "Close StudioSync" : "Close this window", false, nullptr);
  POINT p;
  GetCursorPos(&p);
  const int cmd = TrackPopupMenu(m, TPM_NONOTIFY | TPM_RETURNCMD, p.x, p.y, 0, w.h, nullptr);
  DestroyMenu(m); // (its submenu with it)
  if (cmd == MENU_OPEN) set_mode(w, DOCK_WIN_FULL, true);
  else if (cmd == MENU_LOCK) put("web ui lock", lock ? "" : "1");
  else if (cmd == MENU_SHAPE) set_mode(w, button ? DOCK_WIN_STRIP : DOCK_WIN_BUTTON, false);
  else if (cmd >= MENU_SIZE && cmd < MENU_SIZE + 4) {
    put("web ui button size", std::to_string(SIZES[cmd - MENU_SIZE]).c_str());
    set_mode(w, DOCK_WIN_BUTTON, false);
  } else if (cmd == MENU_CLOSE) close_window(w);
}

// What the page asked for (0: the page has loaded, and is told what the window is).
static void on_ask(Win &w, int ask)
{
  if (ask == DOCK_WIN_NONE) {
    tell(w);
    if (w.pending) { const int p = w.pending; w.pending = 0; set_mode(w, p, true); }
  } else if (ask == DOCK_WIN_FULL) {
    if (w.moved && GetTickCount() - w.moved_at < 500) tell(w); // (the click that ends a drag: it stays the strip or the button)
    else set_mode(w, DOCK_WIN_FULL, true);
  } else if (ask == DOCK_WIN_STRIP || ask == DOCK_WIN_BUTTON) set_mode(w, ask, false);
  else if (ask == DOCK_WIN_FULLSCREEN) set_mode(w, w.mode == DOCK_WIN_FULLSCREEN ? DOCK_WIN_FULL : DOCK_WIN_FULLSCREEN, true);
  else if (ask == DOCK_WIN_MENU && (w.mode == DOCK_WIN_STRIP || w.mode == DOCK_WIN_BUTTON)) shape_menu(w);
  else if (ask == DOCK_WIN_DRAG) drag_start(w);
}

// Dock / Undock: the other kind of window, the view moved in alive; where it can't move (Linux) the main window is made again, as before.
static void toggle_dock(Win &w)
{
  const bool to = !w.docked;
  put(key(w, "docked"), to ? "1" : "0");
  if (dock_win_can() && w.ready) { set_mode(w, DOCK_WIN_FULL, true); return; }
  if (!is_main(w)) return;
  close_window(w); // (as it was: its floating place kept, out of the docker)
  if (show(1) < 0) offer_browser(g_err);
}

// What a page sent (inside the view's own event: only posted on, so nothing runs REAPER or closes the view from in there).
static void on_page(void *hwnd, const char *m)
{
  HWND h = (HWND)hwnd;
  Win *w = win_of(h);
  int vk = 0, mods = 0, ask = 0;
  if (!w || !m) return;
  if (webui_dock_key(m, &vk, &mods)) PostMessage(h, WM_DOCK_KEY, (WPARAM)vk, (LPARAM)mods);
  else if (!strcmp(m, "dock")) PostMessage(h, WM_DOCK_TOGGLE, 0, 0);
  else if ((ask = webui_dock_win(m)) != 0) PostMessage(h, WM_DOCK_WIN, (WPARAM)ask, 0);
  else if (!strcmp(m, "view:loaded")) PostMessage(h, WM_DOCK_WIN, 0, 1);
  else if (!strcmp(m, "view:close")) { if (!is_main(*w)) PostMessage(h, WM_CLOSE, 0, 0); } // (a pop-out's window.close: Back into the main window)
  else if (!strncmp(m, "error:", 6)) { if (is_main(*w)) g_err = m + 6; PostMessage(h, WM_DOCK_ERROR, 0, 0); }
}

// A pop-out page asked for (the view's new-window request): a window of its own, docked or floating as that pop-out was last, up to 6.
static void *open_pop(const char *name, int pw, int ph)
{
  Win *w = nullptr;
  for (int i = 1; i <= POPS && !w; i++) if (!g_w[i].h) w = &g_w[i];
  if (!w || !g_main.h || !name || !*name) return nullptr;
  *w = Win();
  w->name = name;
  w->ident = "studiosync_webui_pop_" + w->name; // (REAPER remembers its docker by this, apart from the main window's)
  w->title = std::string(TITLE) + ": " + w->name;
  for (char &c : w->title) if (c == '_') c = ' ';
  w->pop_w = pw;
  w->pop_h = ph;
  w->docked = docked_pref(*w);
  w->h = make_window(*w);
  if (!w->h) { *w = Win(); return nullptr; }
  if (w->docked) {
    R.DockWindowAddEx(w->h, w->title.c_str(), w->ident.c_str(), true);
    R.DockWindowActivate(w->h);
  } else {
    const dock_rect r = want_rect(*w, DOCK_WIN_FULL);
    SetWindowPos(w->h, nullptr, r.l, r.t, r.r - r.l, r.b - r.t, SWP_NOZORDER | SWP_NOACTIVATE);
    ShowWindow(w->h, SW_SHOW);
  }
  return w->h;
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
  Win *win = win_of(h);
  switch (m) {
  case WM_INITDIALOG: return 0;
  case WM_SIZE: if (win) dock_view_resize(h); break;
  case WM_SHOWWINDOW: if (win) dock_view_show(h, w != 0); break; // (a docker tab behind another, or its docker hidden)
  case WM_COMMAND: if (LOWORD(w) == IDCANCEL && win) { close_window(*win); return 1; } break; // (the docker's own Close, and Esc on the frame)
  case WM_CLOSE: if (win) close_window(*win); return 1;
  case WM_DESTROY: // (a docker REAPER closed itself, at its exit: the pop-outs go with the main window)
    if (win) {
      const bool main = is_main(*win);
      dock_view_destroy(h);
      *win = Win();
      for (int i = 1; main && i <= POPS; i++) close_window(g_w[i]);
    }
    break;
  case WM_ACTIVATE: if (win && !win->docked) PostMessage(h, WM_DOCK_FOCUS, LOWORD(w) != WA_INACTIVE, 0); break;
  case WM_TIMER:
    if (win && w == TIMER_DRAG) drag_tick(*win);
    else if (win && w == TIMER_FADE) fade_tick(*win);
    break;
  case WM_DOCK_KEY:
    if (win && win->mode == DOCK_WIN_FULLSCREEN && w == 27 && l == 0) set_mode(*win, DOCK_WIN_FULL, true); // (Esc leaves full screen)
    else forward_key((int)w, (int)l);
    return 1;
  case WM_DOCK_TOGGLE: if (win) toggle_dock(*win); return 1;
  case WM_DOCK_WIN:
    if (!win) return 1;
    if (l) win->ready = true;
    on_ask(*win, (int)w);
    return 1;
  case WM_DOCK_FOCUS: if (win) on_focus(*win, w != 0); return 1;
  case WM_DOCK_ERROR: {
    if (!win) return 1;
    if (!is_main(*win)) { close_window(*win); return 1; }
    const std::string why = g_err;
    close_window(*win);
    failed(why);
    offer_browser(why);
    return 1;
  }
  }
  return 0;
}

// Keys on the windows. Windows: WebView2 takes its keys in its own process, so only the frame's (its docker tab clicked) come here: REAPER's
// main shortcuts. macOS: the view is in REAPER's process, so its keys come here first and go to the view (else Space in the chat box would
// press Play); the page passes on what it doesn't use.
static int translate(MSG *msg, accelerator_register_t *)
{
  if (!msg || !msg->hwnd) return 0;
  for (const Win &w : g_w) {
    if (!w.h || (msg->hwnd != w.h && !IsChild(w.h, msg->hwnd))) continue;
#ifdef __APPLE__
    return -1;
#else
    return -666;
#endif
  }
  return 0;
}
static accelerator_register_t g_keys = { translate, true, nullptr };

// The main window. mode 1 open (or bring forward, back from the strip or button), 0 close, -1 toggle. -> 1 open, 0 closed, -1 can't here
// (g_err says why; the browser instead).
static int show(int mode)
{
  Win &w = g_main;
  if (mode < 0) mode = w.h && IsWindowVisible(w.h) ? 0 : 1; // (open but behind another docker tab: brought forward, as SWS's do)
  if (mode == 0) { close_window(w); return 0; }
  if (w.h) {
    if (w.mode == DOCK_WIN_STRIP || w.mode == DOCK_WIN_BUTTON) set_mode(w, DOCK_WIN_FULL, true);
    else if (w.docked) R.DockWindowActivate(w.h);
    else { ShowWindow(w.h, SW_SHOW); SetForegroundWindow(w.h); }
    return 1;
  }
  w = Win();
  w.ident = IDENT;
  w.title = TITLE;
  const bool full_screen = dock_win_can() && !strcmp(get(key(w, "mode")), "fullscreen");
  w.docked = docked_pref(w) && !full_screen;
  const int port = server_port();
  g_url = port ? webui_dock_url(port, w.docked) : std::string();
  if (!port) return failed("StudioSync's web UI isn't running yet: open the StudioSync panel once (or start Live sync), then try again.");
  w.h = make_window(w);
  if (!w.h) return failed("REAPER couldn't make the window.");
  std::string err;
  if (!dock_view_create(w.h, g_url.c_str(), webui_dock_data_dir(R.GetResourcePath()).c_str(), on_page, err)) {
    HWND h = w.h;
    w = Win();
    DestroyWindow(h);
    return failed(err);
  }
  failed("");
  if (full_screen) w.pending = DOCK_WIN_FULLSCREEN; // (once the page is there)
  if (w.docked) {
    R.DockWindowAddEx(w.h, w.title.c_str(), w.ident.c_str(), true); // (REAPER remembers the docker and the place by IDENT, in reaper.ini)
    R.DockWindowActivate(w.h);
  } else {
    const dock_rect r = want_rect(w, DOCK_WIN_FULL);
    SetWindowPos(w.h, nullptr, r.l, r.t, r.r - r.l, r.b - r.t, SWP_NOZORDER | SWP_NOACTIVATE);
    ShowWindow(w.h, SW_SHOW);
  }
  return 1;
}

static bool on_command(int command, int)
{
  if (!command || command != g_cmd) return false;
  if (show(-1) < 0) offer_browser(g_err);
  return true;
}
static int on_toggle(int command) { return command == g_cmd ? (g_main.h && IsWindowVisible(g_main.h) ? 1 : 0) : -1; }

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

bool webui_dock_is_ui() { return R.GetExtState && !strcmp(get("ui"), "web"); }
void webui_dock_button()
{
  Win &w = g_main;
  if (!w.h || w.docked || !w.ready || !dock_win_can()) { if (show(w.h ? -1 : 1) < 0) offer_browser(g_err); return; }
  if (w.mode == DOCK_WIN_STRIP || w.mode == DOCK_WIN_BUTTON) set_mode(w, DOCK_WIN_FULL, true);
  else set_mode(w, focus_rule() == DOCK_FOCUS_BUTTON ? DOCK_WIN_BUTTON : DOCK_WIN_STRIP, false);
}
int webui_dock_lit() { return g_main.h ? 1 : 0; }

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
      !R.DockWindowRemove || !R.ShowMessageBox) { R.GetExtState = nullptr; return; }
  g_cmd = rec->Register("command_id", (void *)"STUDIOSYNC_WEBUI_DOCK");
  if (!g_cmd) return;
  dock_view_on_pop(open_pop);
  g_gaccel.desc = DESC;
  g_gaccel.accel.cmd = (WORD)g_cmd;
  rec->Register("gaccel", &g_gaccel);
  rec->Register("hookcommand", (void *)on_command);
  rec->Register("hookcustommenu", (void *)on_menu);
  rec->Register("toggleaction", (void *)on_toggle);
  rec->Register("accelerator", &g_keys);
  rec->Register("atexit", (void *)webui_dock_shutdown); // (REAPER quitting: the windows and their views go while REAPER is all there)
  rec->Register("API_StudioSync_WebUIDock", (void *)api_dock);
  rec->Register("APIdef_StudioSync_WebUIDock", (void *)"int\0int\0mode\0"
    "StudioSync's web UI in a REAPER window that docks: mode 1 opens it (or brings it forward, back from the strip or the button), 0 closes "
    "it, -1 toggles. Returns 1 open, 0 closed, -1 when it can't here (no WebKitGTK on Linux, no WebView2 runtime, the web UI not started; "
    "ExtState BandSync \"web ui dock error\" says why): open the browser instead.");
  rec->Register("APIvararg_StudioSync_WebUIDock", (void *)va_dock);
}

void webui_dock_shutdown() { close_window(g_main); }
#endif
