// StudioSync's web UI in a REAPER window that docks (docs/realtime-roadmap.md "A new interface: web UI"): the pages the web UI server
// already serves (extension/webui.cpp) at http://127.0.0.1:<port>/, in WebView2 on Windows (the static loader: no extra DLL to ship) and
// WKWebView on macOS (extension/webui_dock_mac.mm) and WebKitGTK on Linux (loaded at run time; where it isn't installed the action offers
// the browser, as with no WebView2).
// The server is the view's only channel to the engine, so nothing here talks to Lua; the view's own channel (window.chrome.webview,
// webkit.messageHandlers.studiosync) carries only what the window itself does: keys for REAPER, Dock/Undock, and the window's shapes
// (docs/rt/ui-web-plan.md 4.2-4.4, rt-ui8: the strip, the button, full screen, the focus rule, pop-out windows). GPL-3.0-or-later. (James, rt)
#pragma once
#include <string>

// ---- the pure parts (tests/webui_dock_test.cpp) ---------------------------------------------------------------------------------------
// The server's port from webui_status()'s JSON, or 0 while it isn't listening.
int webui_dock_port(const char *status_json);
// What the window opens: the pages on this computer, telling them whether they're docked (their Dock / Undock button).
std::string webui_dock_url(int port, bool docked);
// WebView2's own user-data folder (cookies, the pages' saved theme), under REAPER's resource path, never the shared default one.
std::string webui_dock_data_dir(const std::string &resource_path);
// May the view go to `uri`? Only the pages' own origin (the scheme, host and port of `page`); anything else opens in the browser.
bool webui_dock_same_origin(const std::string &page, const std::string &uri);
bool webui_dock_external_ok(const std::string &uri); // http(s) only, handed to the browser
// What a page in the view may use (video calls and screen share, lib/webui/call.js). kind: WebView2's numbers (1 microphone, 2 camera; the
// Mac's media capture asks as 1). -> 1 allow: the camera and microphone, for the pages' own origin only; -1 deny: anything another origin
// asks for; 0 the view's own default: anything else the pages' origin asks for.
int webui_dock_permission(const std::string &page, const std::string &uri, int kind);
// A message from the page: "key:<vk>:<mods>" (Windows virtual-key code; mods 1 Shift, 2 Ctrl, 4 Alt, 8 Cmd/Win). -> false if it isn't one.
bool webui_dock_key(const char *msg, int *vk, int *mods);

// The window's shapes (rt-ui8). Its modes, and what the page asks for (lib/webui/shell.js): "win:full", "win:strip", "win:button",
// "win:fullscreen", "win:menu" (the button's right-click), "win:drag" (a press on the strip or the button: it follows the mouse till let go).
enum { DOCK_WIN_NONE, DOCK_WIN_FULL, DOCK_WIN_STRIP, DOCK_WIN_BUTTON, DOCK_WIN_FULLSCREEN, DOCK_WIN_MENU, DOCK_WIN_DRAG };
int webui_dock_win(const char *msg);          // -> DOCK_WIN_*, 0 if it isn't one of those
const char *webui_dock_win_name(int mode);    // "full", "strip", "button", "fullscreen"
// What the window tells its page, whenever that changes and once the page has loaded: {"win":"strip","focus":false,"docked":false,"pop":true}
// (focus: this window has the keyboard; docked: in a REAPER docker; pop: window.open of a ?pop= page opens a window of its own here).
std::string webui_dock_win_json(int mode, bool focus, bool docked, bool pop);
// When REAPER takes the focus from the floating view (Settings > This computer > Window; ExtState BandSync "web ui focus"): shrink to the
// strip (James's default, 2026-11-27) or the button, stay as it is, go behind REAPER, or fade to 25 % till the mouse is over it.
enum { DOCK_FOCUS_STRIP, DOCK_FOCUS_BUTTON, DOCK_FOCUS_STAY, DOCK_FOCUS_BEHIND, DOCK_FOCUS_FADE };
int webui_dock_focus_rule(const char *v);     // "strip" (and anything unknown), "button", "stay", "behind", "fade"
int webui_dock_button_px(const char *v);      // the button's size (ExtState "web ui button size"): 22, 28, 40 or 56; else 28
// The strip (380 x 36) or the button (px square), in screen pixels at `scale` (the display's: 1.5 at 150 %). Others: 0 x 0.
void webui_dock_shape(int mode, int button_px, double scale, int *w, int *h);
struct dock_rect { int l, t, r, b; }; // (screen pixels, l < r and t < b; on macOS y grows upwards, which none of this minds)
// A w x h window wanted at (x, y), kept inside REAPER's window where it fits there on that monitor, else inside the monitor.
dock_rect webui_dock_place(int x, int y, int w, int h, const dock_rect &reaper, const dock_rect &monitor);
// The focus went from the view to `fg`: shrink (or fade) only for a REAPER window the view covers part of (the panel's ui.should_hide):
// not for a click on the view itself (the mouse is over it), another app, a dialog or menu, one of StudioSync's own windows, or a REAPER
// window it doesn't overlap (on another monitor). A REAPER window whose place isn't known counts.
struct dock_fg { bool any, dialog, reapers, ours, has_rect; dock_rect rect; };
bool webui_dock_covers(const dock_rect &view, int mx, int my, const dock_fg &fg);
// The pop-out a new-window request from the view is for (lib/webui/tabs.js popOut, call.js's share): the pages' own origin, the page itself
// ("/" or "/index.html") with ?pop=<route> -> the route as a name for its window and settings ("chat", "project_beat", "share"); "" for
// anything else (that goes to the browser, if anywhere).
std::string webui_dock_pop_name(const std::string &page, const std::string &uri);

// ---- the views: Windows, macOS, Linux (with SWELL) ------------------------------------------------------------------------------------
// One per window (the main one, and up to 6 pop-outs), told apart by the window they're in. on_message gets what each page posts, from its
// own origin only, on the UI thread, inside the view's event: so it must only post work on. The views say "view:loaded" once a page has
// loaded, "view:close" when a pop-out page closes itself (window.close), and "error:<why>" when one fails after creating starts.
typedef void (*dock_msg_fn)(void *hwnd, const char *msg);
// A pop-out page asked for (window.open of webui_dock_pop_name's kind): a window of its own, w x h (the page's size, 0 if it gave none) -> the
// window for its view, or null (then it goes to the browser).
typedef void *(*dock_pop_fn)(const char *name, int w, int h);
bool dock_view_create(void *hwnd, const char *url, const char *data_dir, dock_msg_fn on_message, std::string &err); // the main view
void dock_view_on_pop(dock_pop_fn fn);       // pop-outs open through this (none: the browser, as before)
void dock_view_resize(void *hwnd);           // to the window's client area
void dock_view_show(void *hwnd, bool visible); // a docker tab behind another: the view rests
void dock_view_destroy(void *hwnd);          // that window's view; null: every view
bool dock_view_move(void *from, void *to);   // the view into another window, alive (a call in it goes on); false where it can't (Linux)
void dock_view_post(void *hwnd, const char *json); // to the page: shell.js's ssShell.fromHost
void dock_open_external(const char *url);    // the system's browser
// The window itself (frame, opacity, owner): Windows and macOS. Linux keeps docked and floating only (dock_win_can false: the page then
// shows no strip, button or full-screen buttons, as it hears nothing from the window).
bool dock_win_can();
void dock_win_frame(void *hwnd, bool framed);
void dock_win_alpha(void *hwnd, int percent);
void dock_win_owner(void *hwnd, void *main, bool owned); // owned: kept in front of REAPER; not: REAPER's window can cover it

#ifndef WEBUI_DOCK_STANDALONE
struct reaper_plugin_info_t;
void webui_dock_register(reaper_plugin_info_t *rec); // the action, its menu item, reaper.StudioSync_WebUIDock
void webui_dock_shutdown();                          // the windows closed (unload, REAPER's exit)
// The toolbar button (reaper_menu.cpp's "StudioSync" action) when the web view is the UI (ExtState BandSync "ui" = "web"): opens the view
// where it was, or brings it back from the strip or button; pressed again it shrinks to the strip (or the button, when that's the rule).
bool webui_dock_is_ui();
void webui_dock_button();
int webui_dock_lit(); // 1 while the view is open, in any mode
#endif
