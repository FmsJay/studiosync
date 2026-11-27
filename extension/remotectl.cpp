// Remote control of a shared window, and the sharer's pointer for watchers (rt-share, docs/rt/rt-share.md "Cursor and control"). The pure
// parts (the message, where a point lands, keys, who may and for how long) are in remotectl.h with their own test.
//  - The sharer's page (lib/webui/call.js) posts to POST /api/input on this computer only (extension/webui.cpp hands it here: never the
//    link's port, a proxy or a guest): what it shares ("share": REAPER's window, a plug-in's window or REAPER's screen, and the picture's
//    size), "status" every 50 ms while sharing (the answer carries the pointer's place in the shared area; the page going quiet ends it),
//    "grant" once the sharer said Allow to one watcher, "stop", and that watcher's pointer, buttons, wheel and keys.
//  - REAPER's main thread (a timer) finds the shared window and its place on screen each tick, checks it matches the picture, reads the pointer
//    and Ctrl+Alt+Esc, and while control is on keeps a low-level mouse hook in that tells the sharer's own mouse from ours (each injected event
//    carries RC_MAGIC), so moving it takes control back.
//  - An input goes in (SendInput, the HTTP thread) only while control is on, only at a point inside the shared window's rect where the window
//    under it is that window (or one it owns: its menus and dialogs) and REAPER's own; a key only while that window is in front. Anything held
//    down is let go when control ends.
// Windows only for now: elsewhere "sys" is false (no pointer, no control) and the page says so. GPL-3.0-or-later.
#include "remotectl.h"
#include <chrono>
#include <mutex>
#include <set>
#include <string>
#ifdef _WIN32
#include <windows.h>
#include <dwmapi.h>
#pragma comment(lib, "dwmapi.lib")
#endif
#include "webui.h"

namespace {
std::mutex g_mx; // everything below: the HTTP threads and REAPER's main thread
RcPolicy g_pol;
RcTarget g_target = RCT_NONE;
std::string g_track;
int g_fxi = -1, g_pw = 0, g_ph = 0;
RcRect g_rect;          // the shared area on screen (physical pixels), the timer's latest
bool g_cur = false;     // the pointer is in it, at g_cx, g_cy (0-1)
double g_cx = 0, g_cy = 0;
double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }

#ifdef _WIN32
HWND g_win = nullptr;       // the shared window (REAPER's main or the plug-in's), the timer's latest
std::set<int> g_buttons;    // held down by the controller (0-2)
std::set<int> g_keys;       // held down by the controller (scan code | 0x100 for an extended one)
// (main thread only: the timer and the hook)
HHOOK g_hook = nullptr;
double g_grace_until = 0, g_local_px = 0, g_seen_grant = -1, g_fx_look = 0;
bool g_local_click = false, g_have_last = false;
POINT g_last = {};
HWND g_fx_win = nullptr;

HWND (*p_GetMainHwnd)() = nullptr;
int (*p_CountTracks)(void *) = nullptr;
void *(*p_GetTrack)(void *, int) = nullptr;
GUID *(*p_GetTrackGUID)(void *) = nullptr;
void (*p_guidToString)(const GUID *, char *) = nullptr;
HWND (*p_TrackFX_GetFloatingWindow)(void *, int) = nullptr;

// Physical pixels for this thread meanwhile (REAPER may run DPI-unaware or per-monitor aware; SendInput, the rects and the hook's points
// must agree). Windows 10 1607+; older: as the process is.
struct Dpi {
  DPI_AWARENESS_CONTEXT old = nullptr;
  Dpi()
  {
    static auto set = (DPI_AWARENESS_CONTEXT(WINAPI *)(DPI_AWARENESS_CONTEXT))GetProcAddress(GetModuleHandleW(L"user32.dll"), "SetThreadDpiAwarenessContext");
    if (set) old = set(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    setp = set;
  }
  ~Dpi() { if (setp && old) setp(old); }
  DPI_AWARENESS_CONTEXT(WINAPI *setp)(DPI_AWARENESS_CONTEXT) = nullptr;
};

bool ours(HWND w)
{
  DWORD pid = 0;
  GetWindowThreadProcessId(GetAncestor(w, GA_ROOT), &pid); // (a bridged plug-in's window is a child of REAPER's container: its root is REAPER's)
  return pid == GetCurrentProcessId();
}
// w is the shared window, inside it, or a window it owns (its dialogs, its menus' owner chain); menus (#32768) of REAPER's own count too
bool belongs(HWND w, HWND target)
{
  if (!w || !target || !ours(w)) return false;
  char cls[16] = {};
  HWND r = GetAncestor(w, GA_ROOT);
  if (GetClassNameA(r, cls, sizeof(cls)) && !strcmp(cls, "#32768")) return true;
  const HWND troot = GetAncestor(target, GA_ROOT);
  for (int k = 0; r && k < 8; ++k, r = GetWindow(r, GW_OWNER)) if (r == troot) return true;
  return false;
}

void send_mouse(int sx, int sy, DWORD extra_flags, DWORD data)
{
  RcRect virt{ GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN), GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN) };
  int ax, ay;
  rc_abs(sx, sy, virt, ax, ay);
  INPUT in[2] = {};
  in[0].type = INPUT_MOUSE;
  in[0].mi.dx = ax; in[0].mi.dy = ay;
  in[0].mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
  in[0].mi.dwExtraInfo = RC_MAGIC;
  int n = 1;
  if (extra_flags) {
    in[1].type = INPUT_MOUSE;
    in[1].mi.dwFlags = extra_flags;
    in[1].mi.mouseData = data;
    in[1].mi.dwExtraInfo = RC_MAGIC;
    n = 2;
  }
  SendInput(n, in, sizeof(INPUT));
}
void send_key(int k, bool down)
{
  INPUT in = {};
  in.type = INPUT_KEYBOARD;
  in.ki.wScan = (WORD)(k & 0xFF);
  in.ki.dwFlags = KEYEVENTF_SCANCODE | ((k & 0x100) ? KEYEVENTF_EXTENDEDKEY : 0) | (down ? 0 : KEYEVENTF_KEYUP);
  in.ki.dwExtraInfo = RC_MAGIC;
  SendInput(1, &in, sizeof(INPUT));
}
const DWORD UPS[3] = { MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_RIGHTUP }, DOWNS[3] = { MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_RIGHTDOWN };
// Let go of whatever the controller holds down (control ended). Takes the held sets out under the lock; sends after (SendInput waits for the
// mouse hook on REAPER's main thread, which may be waiting for g_mx: never send while holding it).
void release_held()
{
  std::set<int> b, k;
  { std::lock_guard<std::mutex> l(g_mx); b.swap(g_buttons); k.swap(g_keys); }
  for (int x : b) { INPUT in = {}; in.type = INPUT_MOUSE; in.mi.dwFlags = UPS[x]; in.mi.dwExtraInfo = RC_MAGIC; SendInput(1, &in, sizeof(INPUT)); }
  for (int x : k) send_key(x, false);
}

LRESULT CALLBACK mouse_ll(int code, WPARAM wp, LPARAM lp)
{
  if (code == HC_ACTION) {
    const MSLLHOOKSTRUCT *m = (const MSLLHOOKSTRUCT *)lp;
    if (m->dwExtraInfo != RC_MAGIC && now_s() >= g_grace_until) { // (the sharer's own mouse, or another program's: not the controller's)
      if (wp == WM_MOUSEMOVE) {
        if (g_have_last) g_local_px += std::hypot((double)(m->pt.x - g_last.x), (double)(m->pt.y - g_last.y));
        g_last = m->pt; g_have_last = true;
      } else if (wp == WM_LBUTTONDOWN || wp == WM_RBUTTONDOWN || wp == WM_MBUTTONDOWN || wp == WM_XBUTTONDOWN) g_local_click = true;
    }
  }
  return CallNextHookEx(nullptr, code, wp, lp);
}

HWND find_fx_window(const std::string &guid, int fxi, double now)
{
  if (g_fx_win && IsWindow(g_fx_win)) return g_fx_win;
  g_fx_win = nullptr;
  if (now < g_fx_look || !p_CountTracks || !p_GetTrack || !p_GetTrackGUID || !p_guidToString || !p_TrackFX_GetFloatingWindow) return nullptr;
  g_fx_look = now + 0.5; // (not found: looked for again twice a second, not every tick)
  const int n = p_CountTracks(nullptr);
  for (int i = 0; i < n; ++i) {
    void *tr = p_GetTrack(nullptr, i);
    GUID *g = tr ? p_GetTrackGUID(tr) : nullptr;
    char buf[64] = {};
    if (!g) continue;
    p_guidToString(g, buf);
    if (_stricmp(buf, guid.c_str()) == 0) return g_fx_win = p_TrackFX_GetFloatingWindow(tr, fxi);
  }
  return nullptr;
}
#endif

// REAPER's main thread, every tick (~30 a second).
void on_timer()
{
  const double now = now_s();
  RcTarget t;
  std::string track;
  int fxi, pw, ph;
  bool area, on;
  double grant_at;
  {
    std::lock_guard<std::mutex> l(g_mx);
    t = g_target; track = g_track; fxi = g_fxi; pw = g_pw; ph = g_ph; area = g_pol.area; on = g_pol.on; grant_at = g_pol.grant_at;
  }
  RcRect r;
  bool ok = false, cur = false, hotkey = false;
  double cx = 0, cy = 0;
#ifdef _WIN32
  HWND win = nullptr;
  if (area) {
    Dpi dpi;
    const HWND main = p_GetMainHwnd ? p_GetMainHwnd() : nullptr;
    if (t == RCT_MONITOR && main) {
      MONITORINFO mi = { sizeof(mi) };
      if (GetMonitorInfoW(MonitorFromWindow(main, MONITOR_DEFAULTTONEAREST), &mi)) {
        r = { mi.rcMonitor.left, mi.rcMonitor.top, mi.rcMonitor.right - mi.rcMonitor.left, mi.rcMonitor.bottom - mi.rcMonitor.top };
        ok = true;
      }
    } else {
      win = t == RCT_REAPER ? main : t == RCT_FX ? find_fx_window(track, fxi, now) : nullptr;
      RECT rc;
      // (the window's visible frame: what the browser captures, without Windows 10/11's invisible resize borders)
      if (win && IsWindowVisible(win) && !IsIconic(win) &&
          (SUCCEEDED(DwmGetWindowAttribute(win, DWMWA_EXTENDED_FRAME_BOUNDS, &rc, sizeof(rc))) || GetWindowRect(win, &rc))) {
        r = { rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top };
        ok = r.w > 0 && r.h > 0;
      }
    }
    POINT pt;
    if (ok && GetCursorPos(&pt)) cur = rc_unmap(r, pt.x, pt.y, cx, cy);
    hotkey = (GetAsyncKeyState(VK_CONTROL) & 0x8000) && (GetAsyncKeyState(VK_MENU) & 0x8000) && (GetAsyncKeyState(VK_ESCAPE) & 0x8000);
  } else g_fx_win = nullptr;
  if (on && !g_hook) {
    HMODULE me = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCWSTR)&mouse_ll, &me);
    g_hook = SetWindowsHookExW(WH_MOUSE_LL, mouse_ll, me, 0);
  } else if (!on && g_hook) { UnhookWindowsHookEx(g_hook); g_hook = nullptr; }
  if (grant_at != g_seen_grant) { // (a new Allow: the sharer's mouse counts again only after the grace)
    g_seen_grant = grant_at;
    g_grace_until = grant_at + RcPolicy::GRACE;
    g_local_px = 0; g_local_click = false; g_have_last = false;
  }
#endif
  bool ended;
  {
    std::lock_guard<std::mutex> l(g_mx);
    if (t != g_target || track != g_track || fxi != g_fxi) return; // (the page changed the share meanwhile: next tick)
    g_rect = ok ? r : RcRect();
    g_pol.shape = ok && rc_same_shape(pw, ph, r);
    g_cur = cur && g_pol.shape; g_cx = cx; g_cy = cy;
#ifdef _WIN32
    g_win = win;
    ended = g_pol.tick(now, g_local_px, g_local_click, hotkey, area && t != RCT_MONITOR && !win);
#else
    ended = g_pol.tick(now, 0, false, false, false);
#endif
  }
#ifdef _WIN32
  if (ended) release_held();
#else
  (void)ended;
#endif
}

#ifdef _WIN32
void input(const RcMsg &m)
{
  Dpi dpi;
  HWND win;
  int sx = 0, sy = 0;
  {
    std::lock_guard<std::mutex> l(g_mx);
    const bool is_up = (m.kind == RCK_UP && g_buttons.count(m.b)) || (m.kind == RCK_KEY && !m.down);
    if (!is_up && !g_pol.may_input(now_s())) return; // (an up for what the controller holds always goes: nothing is left stuck down)
    if (m.kind != RCK_KEY && !rc_map(g_rect, m.x, m.y, sx, sy)) return;
    win = g_win;
  }
  if (m.kind == RCK_KEY) {
    bool ext = false;
    const int sc = rc_scan(m.code, ext);
    const int k = sc | (ext ? 0x100 : 0);
    if (!sc) return;
    {
      std::lock_guard<std::mutex> l(g_mx);
      if (!m.down) { if (!g_keys.erase(k)) return; }
      else {
        const bool alt = g_keys.count(0x38) || g_keys.count(0x138), ctrl = g_keys.count(0x1D) || g_keys.count(0x11D);
        if (rc_key_refused(sc, alt, ctrl) || !belongs(GetForegroundWindow(), win)) return;
        g_keys.insert(k);
      }
    }
    send_key(k, m.down);
    return;
  }
  POINT p = { sx, sy };
  const bool here = belongs(WindowFromPoint(p), win); // (only the shared window, or what it owns, at that point: never a window over it)
  if (m.kind == RCK_MOVE) { if (here) send_mouse(sx, sy, 0, 0); return; }
  if (m.kind == RCK_WHEEL) {
    if (!here) return;
    if (m.dy) send_mouse(sx, sy, MOUSEEVENTF_WHEEL, (DWORD)rc_wheel(m.dy, false));
    if (m.dx) send_mouse(sx, sy, MOUSEEVENTF_HWHEEL, (DWORD)rc_wheel(m.dx, true));
    return;
  }
  {
    std::lock_guard<std::mutex> l(g_mx);
    if (m.kind == RCK_DOWN) { if (!here || g_buttons.count(m.b)) return; g_buttons.insert(m.b); }
    else if (!g_buttons.erase(m.b)) return;
  }
  if (m.kind == RCK_UP && !here) { INPUT in = {}; in.type = INPUT_MOUSE; in.mi.dwFlags = UPS[m.b]; in.mi.dwExtraInfo = RC_MAGIC; SendInput(1, &in, sizeof(INPUT)); return; } // (let go where it is)
  send_mouse(sx, sy, m.kind == RCK_DOWN ? DOWNS[m.b] : UPS[m.b], 0);
}
#endif

std::string bad() { return "{\"bad\":true}"; }

// POST /api/input's body -> the answer (webui.cpp sends it as JSON).
std::string http(const std::string &body)
{
  RcMsg m;
  if (!rc_parse(body, m)) return bad();
  const double now = now_s();
  bool release = false;
  {
    std::lock_guard<std::mutex> l(g_mx);
    g_pol.heard(now);
    switch (m.kind) {
    case RCK_SHARE:
      if (m.target != g_target || m.track != g_track || m.fxi != g_fxi || !g_pol.area) { // (another window: what was allowed for the last one ends)
        if (g_pol.on) release = true;
        g_pol.unshare("the share changed");
        g_target = m.target; g_track = m.track; g_fxi = m.fxi;
        g_pol.share(m.target != RCT_MONITOR, now);
        g_rect = RcRect(); g_cur = false;
      }
      g_pw = m.pw; g_ph = m.ph;
      break;
    case RCK_UNSHARE: release = g_pol.on; g_pol.unshare("the share ended"); g_target = RCT_NONE; g_track.clear(); g_fxi = -1; g_cur = false; break;
    case RCK_GRANT: if (g_pol.on) release = true; g_pol.grant(m.who, m.idle, now); break;
    case RCK_STOP: release = g_pol.on; g_pol.stop("you took control back"); break;
    default: break;
    }
  }
#ifdef _WIN32
  if (release) release_held();
  if (m.kind >= RCK_MOVE) input(m);
#else
  (void)release;
#endif
  std::lock_guard<std::mutex> l(g_mx);
  return rc_status_json(g_pol, g_cur, g_cx, g_cy);
}
} // namespace

#include "reaper_plugin.h"
static const char *api_status()
{
  static std::string s; // (REAPER's main thread only)
  std::lock_guard<std::mutex> l(g_mx);
  s = rc_status_json(g_pol, g_cur, g_cx, g_cy);
  return s.c_str();
}
static void api_stop()
{
  { std::lock_guard<std::mutex> l(g_mx); g_pol.stop("you took control back"); }
#ifdef _WIN32
  release_held();
#endif
}
static void *va_status(void **, int) { return (void *)api_status(); }
static void *va_stop(void **, int) { api_stop(); return nullptr; }
static void remotectl_exit()
{
  { std::lock_guard<std::mutex> l(g_mx); g_pol.unshare("REAPER is closing"); }
#ifdef _WIN32
  release_held();
  if (g_hook) { UnhookWindowsHookEx(g_hook); g_hook = nullptr; }
#endif
  webui_input_http = nullptr;
}

extern "C" void remotectl_register(reaper_plugin_info_t *rec) // (C linkage: reaper_menu.cpp declares it inside its extern "C" entry point)
{
  {
    std::lock_guard<std::mutex> l(g_mx);
#ifdef _WIN32
    g_pol.sys = true;
    *(void **)&p_GetMainHwnd = rec->GetFunc("GetMainHwnd");
    *(void **)&p_CountTracks = rec->GetFunc("CountTracks");
    *(void **)&p_GetTrack = rec->GetFunc("GetTrack");
    *(void **)&p_GetTrackGUID = rec->GetFunc("GetTrackGUID");
    *(void **)&p_guidToString = rec->GetFunc("guidToString");
    *(void **)&p_TrackFX_GetFloatingWindow = rec->GetFunc("TrackFX_GetFloatingWindow");
#endif
  }
  static const struct { const char *name; void *fn, *va; const char *def; } fns[] = {
    { "StudioSync_RemoteControlStatus", (void *)api_status, (void *)va_status,
      "const char*\0\0\0Remote control of a shared window (the web UI's screen share), as JSON: sys (this system can), area (a REAPER or "
      "plug-in window is shared and matches the picture), can, on, who (in control), why (why control last ended), cur (the pointer's place "
      "in the shared area, 0-1, or null)." },
    { "StudioSync_RemoteControlStop", (void *)api_stop, (void *)va_stop,
      "void\0\0\0Takes back control of a shared window at once (the web UI's screen share), letting go of anything the controller held down." },
  };
  char key[96];
  for (const auto &f : fns) {
    snprintf(key, sizeof(key), "API_%s", f.name); rec->Register(key, f.fn);
    snprintf(key, sizeof(key), "APIdef_%s", f.name); rec->Register(key, (void *)f.def);
    snprintf(key, sizeof(key), "APIvararg_%s", f.name); rec->Register(key, f.va);
  }
  rec->Register("timer", (void *)on_timer);
  rec->Register("atexit", (void *)remotectl_exit);
  webui_input_http = http;
}
