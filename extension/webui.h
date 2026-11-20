// StudioSync's web UI server (docs/realtime-roadmap.md "A new interface: web UI"): the pages in lib/webui/, a small JSON API and a
// Server-Sent Events stream, served by the extension. On this computer it listens on 127.0.0.1 (no token: loopback needs no firewall rule
// and nothing outside can reach it). From the studio's other devices (a phone on Tailscale) it answers on the direct link's own port: the
// link's listener hands over any connection that starts with an HTTP request (direct_set_http_handler), so the one firewall rule James OK'd
// covers it; those need the studio's web token (derived from its secret, as the link's HMAC key is), given once as ?t= and then a cookie.
// The engine stays Lua: Live sync publishes state by topic (presence, chat) and polls the actions the pages send (lib/webui.lua).
// A later docked WebView2/WKWebView window only has to open http://127.0.0.1:<port>/ : the server is its message channel too.
// The core has no REAPER in it, so tests/webui_test.cpp builds it alone (-DWEBUI_STANDALONE). GPL-3.0-or-later.
#pragma once
#include <cstddef>
#include <map>
#include <string>

// folder: the pages (lib/webui); secret: the studio's ("" -> no token, so nothing but this computer gets in); port 0: 47281 (the link's);
// bind_ip "" -> 127.0.0.1. Starts listening if it isn't, or again on a new port. -> 1 listening.
int webui_start(const char *folder, const char *secret, int port, const char *bind_ip);
void webui_publish(const char *topic, const char *json); // the latest state of a topic ([a-z][a-z0-9_-]{0,31}), JSON text
const char *webui_poll();   // the oldest action a page sent (its JSON body), or "" (consuming: one engine takes each)
int webui_poll_here();      // 1 when the action webui_poll handed out last came from a page on this computer (loopback, not proxied)
const char *webui_status(); // JSON: { listening, bind, port, error, token, clients, served, refused }
// A phone's take that a page sent as POST /api/upload (its answer's id), written to path and let go. -> bytes; 0 no such upload; -1 couldn't
// write it (kept for another try). lib/phonerec.lua
int webui_save_upload(const char *id, const char *path);
// A file the pages may download as GET /api/file?id=<id> (lower-case hex, 1-32): the server reads only paths Lua named. "" path withdraws
// it. -> 1; 0 a bad id or MAX_OFFERS already. lib/phonerec.lua (the latest mix of each song, for the phone app to play along to)
int webui_offer(const char *id, const char *path);
void webui_shutdown();

// ---- the pure parts (tests/webui_test.cpp) ----------------------------------------------------------------------------------------------
struct WebReq {
  std::string method, path, query, body;
  std::map<std::string, std::string> headers; // names lower-cased
};
// head: everything up to and including the blank line. -> false when it isn't a request this server takes (malformed, not HTTP/1.x).
bool webui_parse_head(const std::string &head, WebReq &out);
// A URL path -> the file under the pages' folder (relative, '/' separated) and its content type. "/" is index.html. Refused: anything but
// letters, digits, '.', '-', '_' and '/'; an empty or dot-led segment (so no "..", no hidden files); Windows device names; an unknown type.
bool webui_file_for(const std::string &path, std::string &rel, std::string &ctype);
std::string webui_token(const std::string &secret); // 32 hex characters: HMAC-SHA256(secret, "StudioSync web UI v1"), first half
std::string webui_param(const std::string &query, const std::string &name);  // a query parameter's raw value ("" when absent)
std::string webui_cookie(const std::string &header, const std::string &name); // a cookie's value from a Cookie header ("" when absent)
// May this request in? local: it came in on the loopback listener. 0 yes; 403 no. set_cookie: it carried the token as ?t= (the answer
// sets the cookie and sends the browser to the same page without it). Local ones must name this computer as Host (a web page elsewhere
// that points its own name at 127.0.0.1 gets no further); every POST must carry X-StudioSync (a form on another site can't add it). A
// local one a proxy handed over (X-Forwarded-*: `tailscale serve`, the pages' https address) needs the token, and may come from https://.
int webui_auth(const WebReq &r, bool local, const std::string &token, int port, bool &set_cookie);

#ifndef WEBUI_STANDALONE
struct reaper_plugin_info_t;
void webui_register(reaper_plugin_info_t *rec); // reaper.StudioSync_WebUI*
#endif
