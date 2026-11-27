// StudioSync's docked web UI on macOS: the system's WKWebView (WebKit.framework) inside the SWELL windows webui_dock.cpp makes (a SWELL
// HWND is an NSView here). Built only on Macs (the extension workflow's mac job); webui_dock.h says what each call does. Manual retain and
// release, as the job builds without ARC. A view per window: the main one, and the pop-outs a page opens (rt-ui8). GPL-3.0-or-later. (James, rt)
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <string>
#include "webui_dock.h"

struct MacView { void *h; WKWebView *v; };
static MacView g_views[8];
static dock_msg_fn g_fn;
static dock_pop_fn g_pop;
static std::string g_page;
static NSString *const HANDLER = @"studiosync"; // (the page posts with window.webkit.messageHandlers.studiosync.postMessage)

static std::string str(NSString *s) { const char *c = s ? s.UTF8String : nullptr; return c ? c : ""; }
static MacView *by_view(WKWebView *v) { for (MacView &m : g_views) if (v && m.v == v) return &m; return nullptr; }
static MacView *by_hwnd(void *h) { for (MacView &m : g_views) if (h && m.v && m.h == h) return &m; return nullptr; }
static void say(WKWebView *v, const char *msg) { MacView *m = by_view(v); if (m && g_fn) g_fn(m->h, msg); }

@interface StudioSyncDockDelegate : NSObject <WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate>
@end
static StudioSyncDockDelegate *g_delegate;
static void hook(WKWebView *v)
{
  v.navigationDelegate = g_delegate;
  v.UIDelegate = g_delegate;
  v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; // (follows the window and the docker by itself)
}

@implementation StudioSyncDockDelegate
// What a page posts: only from the pages' own origin, only text.
- (void)userContentController:(WKUserContentController *)c didReceiveScriptMessage:(WKScriptMessage *)m
{
  WKSecurityOrigin *o = m.frameInfo.securityOrigin;
  const std::string origin = str([NSString stringWithFormat:@"%@://%@:%ld", o.protocol, o.host, (long)o.port]);
  if (!g_fn || !webui_dock_same_origin(g_page, origin) || ![m.body isKindOfClass:[NSString class]]) return;
  say(m.webView, str((NSString *)m.body).c_str());
}
// Only the pages' own origin in the view; a clicked link anywhere else opens in the browser, the rest goes nowhere.
- (void)webView:(WKWebView *)w decidePolicyForNavigationAction:(WKNavigationAction *)a decisionHandler:(void (^)(WKNavigationActionPolicy))h
{
  const std::string u = str(a.request.URL.absoluteString);
  if (webui_dock_same_origin(g_page, u)) { h(WKNavigationActionPolicyAllow); return; }
  h(WKNavigationActionPolicyCancel);
  if (a.navigationType == WKNavigationTypeLinkActivated && webui_dock_external_ok(u)) dock_open_external(u.c_str());
}
- (void)webView:(WKWebView *)w didFinishNavigation:(WKNavigation *)n { say(w, "view:loaded"); }
- (void)webViewDidClose:(WKWebView *)w { say(w, "view:close"); } // (a pop-out's window.close)
// Camera and microphone for video calls (lib/webui/call.js), for the pages' own origin only (webui_dock_permission). macOS 12+; before
// that WebKit asks nothing here and the page can't capture (it offers the browser). REAPER's own Info.plist has NSCameraUsageDescription and
// NSMicrophoneUsageDescription and its signature the camera and audio-input entitlements (7.86, checked 2026-11-19), so macOS asks the
// person once, for REAPER itself. Screen capture (getDisplayMedia) also needs REAPER allowed under Screen Recording in System Settings,
// and isn't in every macOS's WKWebView: the page then offers "Open StudioSync in your browser". (James, rt)
- (void)webView:(WKWebView *)w requestMediaCapturePermissionForOrigin:(WKSecurityOrigin *)o initiatedByFrame:(WKFrameInfo *)f
           type:(WKMediaCaptureType)type decisionHandler:(void (^)(WKPermissionDecision))h API_AVAILABLE(macos(12.0))
{
  const std::string origin = str([NSString stringWithFormat:@"%@://%@:%ld", o.protocol, o.host, (long)o.port]);
  h(webui_dock_permission(g_page, origin, type == WKMediaCaptureTypeMicrophone ? 1 : 2) > 0 ? WKPermissionDecisionGrant : WKPermissionDecisionDeny);
}
// window.open: a pop-out of ours (?pop=) gets a window of its own with a view made from WebKit's configuration (so window.opener holds);
// anything else (target="_blank") goes to the browser.
- (WKWebView *)webView:(WKWebView *)w createWebViewWithConfiguration:(WKWebViewConfiguration *)c forNavigationAction:(WKNavigationAction *)a
       windowFeatures:(WKWindowFeatures *)f
{
  const std::string u = str(a.request.URL.absoluteString), name = webui_dock_pop_name(g_page, u);
  MacView *slot = nullptr;
  for (MacView &m : g_views) if (!m.v && !slot) slot = &m;
  NSView *pv = !name.empty() && slot && g_pop ? (NSView *)g_pop(name.c_str(), f.width ? f.width.intValue : 0, f.height ? f.height.intValue : 0) : nil;
  if (!pv) {
    if (webui_dock_external_ok(u)) dock_open_external(u.c_str());
    return nil;
  }
  WKWebView *v = [[WKWebView alloc] initWithFrame:pv.bounds configuration:c];
  if (!v) return nil;
  hook(v);
  [pv addSubview:v];
  slot->h = (void *)pv;
  slot->v = v; // (kept: released in dock_view_destroy)
  return v;
}
@end

bool dock_view_create(void *hwnd, const char *url, const char *, dock_msg_fn on_message, std::string &err)
{
  // (data_dir unused: WebKit keeps the pages' storage in REAPER's own app data. shortcut: shared with any other WKWebView in REAPER; a
  // WKWebsiteDataStore of its own needs macOS 14, use dataStoreForIdentifier: when that's the oldest supported)
  dock_view_destroy(nullptr);
  NSView *parent = (NSView *)hwnd;
  NSURL *u = [NSURL URLWithString:[NSString stringWithUTF8String:url ? url : ""]];
  if (!parent || !u) { err = "The docked web UI couldn't start (no window or address)."; return false; }
  g_fn = on_message;
  g_page = url;
  if (!g_delegate) g_delegate = [[StudioSyncDockDelegate alloc] init];
  WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
  [cfg.userContentController addScriptMessageHandler:g_delegate name:HANDLER]; // (pop-outs' configurations come from this one: the same handler)
  cfg.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone; // (a bandmate's video, and their call audio when it's on, plays)
  WKWebView *v = [[WKWebView alloc] initWithFrame:parent.bounds configuration:cfg];
  [cfg release];
  if (!v) { err = "WebKit couldn't make its view."; return false; }
  hook(v);
  [parent addSubview:v];
  g_views[0].h = hwnd;
  g_views[0].v = v;
  [v loadRequest:[NSURLRequest requestWithURL:u]];
  return true;
}

void dock_view_on_pop(dock_pop_fn fn) { g_pop = fn; }
void dock_view_resize(void *hwnd) { MacView *m = by_hwnd(hwnd); if (m && m->v.superview) m->v.frame = m->v.superview.bounds; }
void dock_view_show(void *hwnd, bool visible) { MacView *m = by_hwnd(hwnd); if (m) m->v.hidden = !visible; }

void dock_view_destroy(void *hwnd)
{
  for (MacView &m : g_views) {
    if (!m.v || (hwnd && m.h != hwnd)) continue;
    m.v.navigationDelegate = nil;
    m.v.UIDelegate = nil;
    [m.v stopLoading];
    [m.v removeFromSuperview];
    [m.v release];
    m.v = nil;
    m.h = nullptr;
  }
  bool any = false;
  for (MacView &m : g_views) any = any || m.v;
  if (!any) g_fn = nullptr;
}

bool dock_view_move(void *from, void *to)
{
  MacView *m = by_hwnd(from);
  NSView *t = (NSView *)to;
  if (!m || !t) return false;
  WKWebView *v = m->v;
  [v retain];
  [v removeFromSuperview];
  v.frame = t.bounds;
  [t addSubview:v];
  [v release];
  m->h = to;
  return true;
}

void dock_view_post(void *hwnd, const char *json)
{
  MacView *m = by_hwnd(hwnd);
  if (!m || !json) return;
  NSString *js = [NSString stringWithFormat:@"window.ssShell && ssShell.fromHost(%@)", [NSString stringWithUTF8String:json]];
  [m->v evaluateJavaScript:js completionHandler:nil];
}

void dock_open_external(const char *url)
{
  NSURL *u = url ? [NSURL URLWithString:[NSString stringWithUTF8String:url]] : nil;
  if (u) [[NSWorkspace sharedWorkspace] openURL:u];
}

// The window itself: a SWELL floating window is an NSWindow whose content view is the HWND. Frame: titled or borderless (SWELL's windows can
// still take the keyboard borderless: their canBecomeKeyWindow). Opacity: alphaValue. Owner: SWELL keeps owned windows in front of their
// owner through its own list and window levels; leaving that list (and the level) lets REAPER's window cover it. shortcut: full screen is
// the screen's whole frame at the normal level, so the menu bar stays over its top; a real full-screen space would take it off REAPER's.
static NSWindow *own_window(void *hwnd)
{
  NSView *v = (NSView *)hwnd;
  NSWindow *w = v ? v.window : nil;
  return w && w.contentView == v ? w : nil; // (never REAPER's docker or main window)
}
bool dock_win_can() { return true; }
void dock_win_frame(void *hwnd, bool framed)
{
  NSWindow *w = own_window(hwnd);
  const NSWindowStyleMask m = framed ? (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                                     : NSWindowStyleMaskBorderless;
  if (w && w.styleMask != m) w.styleMask = m;
}
void dock_win_alpha(void *hwnd, int percent) { NSWindow *w = own_window(hwnd); if (w) w.alphaValue = percent >= 100 ? 1.0 : percent / 100.0; }
void dock_win_owner(void *hwnd, void *main, bool owned)
{
  NSWindow *w = own_window(hwnd), *o = main ? ((NSView *)main).window : nil;
  if (!w || !o) return;
  if (owned) {
    if ([o respondsToSelector:@selector(swellAddOwnedWindow:)]) [o performSelector:@selector(swellAddOwnedWindow:) withObject:w];
    return;
  }
  if ([o respondsToSelector:@selector(swellRemoveOwnedWindow:)]) [o performSelector:@selector(swellRemoveOwnedWindow:) withObject:w];
  if ([w respondsToSelector:@selector(swellSetOwner:)]) [w performSelector:@selector(swellSetOwner:) withObject:nil];
  w.level = NSNormalWindowLevel;
}
