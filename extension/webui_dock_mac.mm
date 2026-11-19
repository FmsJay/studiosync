// StudioSync's docked web UI on macOS: the system's WKWebView (WebKit.framework) inside the SWELL window webui_dock.cpp makes (a SWELL
// HWND is an NSView here). Built only on Macs (the extension workflow's mac job); webui_dock.h says what each call does. Manual retain and
// release, as the job builds without ARC. GPL-3.0-or-later. (James, rt)
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <string>
#include "webui_dock.h"

static WKWebView *g_view;
static dock_msg_fn g_fn;
static std::string g_page;
static NSString *const HANDLER = @"studiosync"; // (the page posts with window.webkit.messageHandlers.studiosync.postMessage)

static std::string str(NSString *s) { const char *c = s ? s.UTF8String : nullptr; return c ? c : ""; }

@interface StudioSyncDockDelegate : NSObject <WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate>
@end
@implementation StudioSyncDockDelegate
// What the page posts: only from the pages' own origin, only text.
- (void)userContentController:(WKUserContentController *)c didReceiveScriptMessage:(WKScriptMessage *)m
{
  WKSecurityOrigin *o = m.frameInfo.securityOrigin;
  const std::string origin = str([NSString stringWithFormat:@"%@://%@:%ld", o.protocol, o.host, (long)o.port]);
  if (!g_fn || !webui_dock_same_origin(g_page, origin) || ![m.body isKindOfClass:[NSString class]]) return;
  g_fn(str((NSString *)m.body).c_str());
}
// Only the pages' own origin in the view; a clicked link anywhere else opens in the browser, the rest goes nowhere.
- (void)webView:(WKWebView *)w decidePolicyForNavigationAction:(WKNavigationAction *)a decisionHandler:(void (^)(WKNavigationActionPolicy))h
{
  const std::string u = str(a.request.URL.absoluteString);
  if (webui_dock_same_origin(g_page, u)) { h(WKNavigationActionPolicyAllow); return; }
  h(WKNavigationActionPolicyCancel);
  if (a.navigationType == WKNavigationTypeLinkActivated && webui_dock_external_ok(u)) dock_open_external(u.c_str());
}
// target="_blank" and window.open: the browser, never a second view.
- (WKWebView *)webView:(WKWebView *)w createWebViewWithConfiguration:(WKWebViewConfiguration *)c forNavigationAction:(WKNavigationAction *)a
       windowFeatures:(WKWindowFeatures *)f
{
  const std::string u = str(a.request.URL.absoluteString);
  if (webui_dock_external_ok(u)) dock_open_external(u.c_str());
  return nil;
}
@end
static StudioSyncDockDelegate *g_delegate;

bool dock_view_create(void *hwnd, const char *url, const char *, dock_msg_fn on_message, std::string &err)
{
  // (data_dir unused: WebKit keeps the pages' storage in REAPER's own app data. shortcut: shared with any other WKWebView in REAPER; a
  // WKWebsiteDataStore of its own needs macOS 14, use dataStoreForIdentifier: when that's the oldest supported)
  dock_view_destroy();
  NSView *parent = (NSView *)hwnd;
  NSURL *u = [NSURL URLWithString:[NSString stringWithUTF8String:url ? url : ""]];
  if (!parent || !u) { err = "The docked web UI couldn't start (no window or address)."; return false; }
  g_fn = on_message;
  g_page = url;
  if (!g_delegate) g_delegate = [[StudioSyncDockDelegate alloc] init];
  WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
  [cfg.userContentController addScriptMessageHandler:g_delegate name:HANDLER];
  g_view = [[WKWebView alloc] initWithFrame:parent.bounds configuration:cfg];
  [cfg release];
  if (!g_view) { err = "WebKit couldn't make its view."; return false; }
  g_view.navigationDelegate = g_delegate;
  g_view.UIDelegate = g_delegate;
  g_view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; // (follows the window and the docker by itself)
  [parent addSubview:g_view];
  [g_view loadRequest:[NSURLRequest requestWithURL:u]];
  return true;
}

void dock_view_resize() { if (g_view && g_view.superview) g_view.frame = g_view.superview.bounds; }
void dock_view_show(bool visible) { if (g_view) g_view.hidden = !visible; }

void dock_view_destroy()
{
  g_fn = nullptr;
  if (!g_view) return;
  // (the content controller holds its message handler: removed, or the delegate and the view would keep each other)
  [g_view.configuration.userContentController removeScriptMessageHandlerForName:HANDLER];
  g_view.navigationDelegate = nil;
  g_view.UIDelegate = nil;
  [g_view stopLoading];
  [g_view removeFromSuperview];
  [g_view release];
  g_view = nil;
}

void dock_open_external(const char *url)
{
  NSURL *u = url ? [NSURL URLWithString:[NSString stringWithUTF8String:url]] : nil;
  if (u) [[NSWorkspace sharedWorkspace] openURL:u];
}
