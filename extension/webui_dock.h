// StudioSync's web UI in a REAPER window that docks (docs/realtime-roadmap.md "A new interface: web UI"): the pages the web UI server
// already serves (extension/webui.cpp) at http://127.0.0.1:<port>/, in WebView2 on Windows (the static loader: no extra DLL to ship) and
// WKWebView on macOS (extension/webui_dock_mac.mm). Linux has no view yet (TODO: WebKitGTK where it's there): the action opens the browser.
// The server is the view's only channel to the engine, so nothing here talks to Lua; the view's own channel (window.chrome.webview,
// webkit.messageHandlers.studiosync) carries only what the window itself does: keys for REAPER and Dock/Undock. GPL-3.0-or-later. (James, rt)
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

// ---- the view (one at a time), Windows and macOS --------------------------------------------------------------------------------------
// on_message gets what the page posts, from its own origin only, on the UI thread, inside the view's event: so it must only post work on.
// A view that fails after creating starts says so as "error:<why>".
typedef void (*dock_msg_fn)(const char *msg);
bool dock_view_create(void *hwnd, const char *url, const char *data_dir, dock_msg_fn on_message, std::string &err);
void dock_view_resize();          // to the window's client area
void dock_view_show(bool visible); // a docker tab behind another: the view rests
void dock_view_destroy();
void dock_open_external(const char *url); // the system's browser

#ifndef WEBUI_DOCK_STANDALONE
struct reaper_plugin_info_t;
void webui_dock_register(reaper_plugin_info_t *rec); // the action, its menu item, reaper.StudioSync_WebUIDock
void webui_dock_shutdown();                          // the window closed (unload, REAPER's exit)
#endif
