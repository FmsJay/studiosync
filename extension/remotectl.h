// Remote control of a shared window (rt-share, docs/rt/rt-share.md "Cursor and control"): the pure parts, so tests/remotectl_test.cpp
// checks them with no REAPER and no Windows. extension/remotectl.cpp has the rest (the main-thread timer, SendInput, the mouse hook).
// The sharer's own page (POST /api/input, this computer only) tells the extension what it shares and, once the sharer said Allow, passes on
// the controller's pointer, clicks, wheel and keys. Everything here is checked again: one flat JSON object, every number finite and bounded,
// coordinates 0-1 of the shared picture, a key by its physical place (KeyboardEvent.code) only from a fixed list (no Windows key), and a few
// combinations never sent (Alt+Tab, Alt+F4, Alt+Esc, Ctrl+Esc). Policy (RcPolicy): control is off unless granted, on only while the shared
// area is a window whose shape matches the picture, ends at the sharer's Stop, their hotkey (Ctrl+Alt+Esc), their own mouse, the window
// closing, the page going quiet (LEASE s) or IDLE s with no input from the controller. GPL-3.0-or-later.
#pragma once
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

struct RcRect { int x = 0, y = 0, w = 0, h = 0; };

enum RcKind { RCK_NONE, RCK_SHARE, RCK_UNSHARE, RCK_GRANT, RCK_STOP, RCK_STATUS, RCK_MOVE, RCK_DOWN, RCK_UP, RCK_WHEEL, RCK_KEY };
enum RcTarget { RCT_NONE, RCT_REAPER, RCT_FX, RCT_MONITOR }; // (REAPER's main window, a plug-in's floating window, the screen REAPER is on)

struct RcMsg {
  RcKind kind = RCK_NONE;
  double x = -1, y = -1;      // 0-1 of the shared picture
  int b = 0;                   // 0 left, 1 middle, 2 right (the browser's button)
  double dx = 0, dy = 0;      // a wheel's, in the browser's pixels
  std::string code;            // a key's KeyboardEvent.code
  bool down = false;
  RcTarget target = RCT_NONE;
  std::string track, who;      // share fx: the track's GUID; grant: who controls (shown in the bars)
  int fxi = -1, pw = 0, ph = 0, idle = 0;
};

const size_t RC_BODY_MAX = 2048;
const unsigned long RC_MAGIC = 0x53535243; // ("SSRC" in each injected event's extra info: the mouse hook tells ours from the sharer's own)

// ---- the message (pure) -------------------------------------------------------------------------------------------------------------------
namespace rc_detail {
inline void ws(const std::string &s, size_t &i) { while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) ++i; }
inline bool str(const std::string &s, size_t &i, std::string &out)
{
  out.clear();
  if (i >= s.size() || s[i] != '"') return false;
  for (++i; i < s.size(); ++i) {
    const char c = s[i];
    if (c == '"') { ++i; return true; }
    if ((unsigned char)c < 0x20) return false;
    if (c != '\\') { out += c; continue; }
    if (++i >= s.size()) return false;
    const char e = s[i];
    if (e == '"' || e == '\\' || e == '/') out += e;
    else if (e == 'n' || e == 't' || e == 'r' || e == 'b' || e == 'f') out += ' ';
    else if (e == 'u') { // (\uXXXX: as UTF-8; a lone surrogate half becomes '?')
      if (i + 4 >= s.size()) return false;
      unsigned v = 0;
      for (int k = 1; k <= 4; ++k) {
        const char h = s[i + k];
        v = v * 16 + (h >= '0' && h <= '9' ? h - '0' : h >= 'a' && h <= 'f' ? h - 'a' + 10 : h >= 'A' && h <= 'F' ? h - 'A' + 10 : 99);
        if (v > 0xFFFF) return false;
      }
      i += 4;
      if (v >= 0xD800 && v <= 0xDFFF) out += '?';
      else if (v < 0x80) out += (char)v;
      else if (v < 0x800) { out += (char)(0xC0 | (v >> 6)); out += (char)(0x80 | (v & 63)); }
      else { out += (char)(0xE0 | (v >> 12)); out += (char)(0x80 | ((v >> 6) & 63)); out += (char)(0x80 | (v & 63)); }
    } else return false;
  }
  return false;
}
inline bool hexguid(const std::string &g) // {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}, as REAPER writes a track's GUID
{
  if (g.size() != 38 || g[0] != '{' || g[37] != '}') return false;
  for (size_t k = 1; k < 37; ++k) {
    const bool dash = k == 9 || k == 14 || k == 19 || k == 24;
    const char c = g[k];
    if (dash ? c != '-' : !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return false;
  }
  return true;
}
} // namespace rc_detail

// body: what the page POSTed. -> true and m filled when it's one of the messages, every field in range. Pure.
inline bool rc_parse(const std::string &body, RcMsg &m)
{
  using namespace rc_detail;
  m = RcMsg();
  if (body.size() > RC_BODY_MAX) return false;
  size_t i = 0;
  ws(body, i);
  if (i >= body.size() || body[i++] != '{') return false;
  std::string t, target, key, sv;
  bool has_x = false, has_y = false, has_down = false, first = true;
  for (;;) {
    ws(body, i);
    if (i < body.size() && body[i] == '}' && first) { ++i; break; }
    if (!str(body, i, key)) return false;
    ws(body, i);
    if (i >= body.size() || body[i++] != ':') return false;
    ws(body, i);
    if (i >= body.size()) return false;
    const char c = body[i];
    bool is_str = false, is_bool = false, bv = false;
    double nv = NAN;
    if (c == '"') { if (!str(body, i, sv)) return false; is_str = true; }
    else if (body.compare(i, 4, "true") == 0) { i += 4; is_bool = bv = true; }
    else if (body.compare(i, 5, "false") == 0) { i += 5; is_bool = true; }
    else if (body.compare(i, 4, "null") == 0) { i += 4; }
    else if (c == '-' || (c >= '0' && c <= '9')) {
      const char *p = body.c_str() + i;
      char *e = nullptr;
      nv = strtod(p, &e);
      if (e == p) return false;
      i += (size_t)(e - p);
    } else return false; // (no objects or arrays: one flat object)
    const bool num = std::isfinite(nv);
    if (key == "t" && is_str) t = sv;
    else if (key == "x" && num) { m.x = nv; has_x = true; }
    else if (key == "y" && num) { m.y = nv; has_y = true; }
    else if (key == "b" && num) m.b = nv == std::floor(nv) && nv >= 0 && nv <= 2 ? (int)nv : -1;
    else if (key == "dx" && num) m.dx = nv;
    else if (key == "dy" && num) m.dy = nv;
    else if (key == "code" && is_str) m.code = sv;
    else if (key == "down" && is_bool) { m.down = bv; has_down = true; }
    else if (key == "target" && is_str) target = sv;
    else if (key == "track" && is_str) m.track = sv;
    else if (key == "who" && is_str) m.who = sv;
    else if (key == "fxi" && num) m.fxi = nv == std::floor(nv) && nv >= 0 && nv < 1024 ? (int)nv : -2;
    else if (key == "pw" && num) m.pw = nv == std::floor(nv) && nv >= 16 && nv <= 16384 ? (int)nv : -1;
    else if (key == "ph" && num) m.ph = nv == std::floor(nv) && nv >= 16 && nv <= 16384 ? (int)nv : -1;
    else if (key == "idle" && num) m.idle = nv == std::floor(nv) && nv >= 30 && nv <= 1800 ? (int)nv : -1;
    first = false;
    ws(body, i);
    if (i < body.size() && body[i] == ',') { ++i; continue; }
    if (i < body.size() && body[i] == '}') { ++i; break; }
    return false;
  }
  ws(body, i);
  if (i != body.size()) return false;
  const bool xy = has_x && has_y && m.x >= 0 && m.x <= 1 && m.y >= 0 && m.y <= 1;
  if (t == "status") m.kind = RCK_STATUS;
  else if (t == "stop") m.kind = RCK_STOP;
  else if (t == "unshare") m.kind = RCK_UNSHARE;
  else if (t == "share") {
    m.target = target == "reaper" ? RCT_REAPER : target == "fx" ? RCT_FX : target == "monitor" ? RCT_MONITOR : RCT_NONE;
    if (m.target == RCT_NONE || m.pw <= 0 || m.ph <= 0) return false;
    if (m.target == RCT_FX && (!hexguid(m.track) || m.fxi < 0)) return false;
    m.kind = RCK_SHARE;
  } else if (t == "grant") {
    if (m.who.empty() || m.who.size() > 64 || m.idle < 0) return false;
    for (unsigned char ch : m.who) if (ch < 0x20 || ch == 0x7F) return false;
    if (!m.idle) m.idle = 180;
    m.kind = RCK_GRANT;
  } else if (t == "move" || t == "down" || t == "up") {
    if (!xy || ((t != "move") && m.b < 0)) return false;
    m.kind = t == "move" ? RCK_MOVE : t == "down" ? RCK_DOWN : RCK_UP;
  } else if (t == "wheel") {
    if (!xy || std::fabs(m.dx) > 10000 || std::fabs(m.dy) > 10000) return false;
    m.kind = RCK_WHEEL;
  } else if (t == "key") {
    if (!has_down || m.code.empty() || m.code.size() > 24) return false;
    for (char ch : m.code) if (!((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9'))) return false;
    m.kind = RCK_KEY;
  } else return false;
  return true;
}

// ---- where (pure) -------------------------------------------------------------------------------------------------------------------------
// 0-1 of the picture -> a pixel of the shared area on screen. false when it isn't a place in it (the area empty, or x, y out of 0-1). Pure.
inline bool rc_map(const RcRect &a, double x, double y, int &sx, int &sy)
{
  if (a.w <= 0 || a.h <= 0 || !(x >= 0 && x <= 1 && y >= 0 && y <= 1)) return false;
  int px = (int)std::floor(x * a.w), py = (int)std::floor(y * a.h);
  if (px >= a.w) px = a.w - 1;
  if (py >= a.h) py = a.h - 1;
  sx = a.x + px; sy = a.y + py;
  return true;
}
inline bool rc_inside(const RcRect &a, int x, int y) { return a.w > 0 && a.h > 0 && x >= a.x && y >= a.y && x < a.x + a.w && y < a.y + a.h; }
// A screen pixel -> 0-1 of the area (the sharer's pointer for the watchers). false outside it. Pure.
inline bool rc_unmap(const RcRect &a, int sx, int sy, double &x, double &y)
{
  if (!rc_inside(a, sx, sy)) return false;
  x = (sx - a.x + 0.5) / a.w; y = (sy - a.y + 0.5) / a.h;
  return true;
}
// Is the picture (pw x ph) this area? The same shape within 3 %, at a scale the browser would capture at (a window is captured at its own
// pixels; a page may ask for less). How a share of some other window is told apart: no pointer and no control for that. Pure.
inline bool rc_same_shape(int pw, int ph, const RcRect &a)
{
  if (pw <= 0 || ph <= 0 || a.w <= 0 || a.h <= 0) return false;
  const double k = (double)pw / a.w, ar = (double)pw / ph, br = (double)a.w / a.h;
  return k >= 0.25 && k <= 4 && std::fabs(ar / br - 1) <= 0.03;
}
// A pixel -> SendInput's absolute coordinates over the whole virtual desktop (0-65535 each way). Pure.
inline void rc_abs(int x, int y, const RcRect &virt, int &ax, int &ay)
{
  const int w = virt.w > 1 ? virt.w - 1 : 1, h = virt.h > 1 ? virt.h - 1 : 1;
  ax = (int)std::lround((double)(x - virt.x) * 65535.0 / w);
  ay = (int)std::lround((double)(y - virt.y) * 65535.0 / h);
  ax = ax < 0 ? 0 : ax > 65535 ? 65535 : ax;
  ay = ay < 0 ? 0 : ay > 65535 ? 65535 : ay;
}
// A browser wheel delta (pixels; about 100 a notch, down positive) -> a Windows wheel amount (120 a notch, up positive), at most 10 notches. Pure.
inline int rc_wheel(double d, bool horizontal)
{
  long v = std::lround(d * 1.2);
  if (!horizontal) v = -v;
  return (int)(v < -1200 ? -1200 : v > 1200 ? 1200 : v);
}

// ---- keys (pure) --------------------------------------------------------------------------------------------------------------------------
// A key's physical place (KeyboardEvent.code) -> its PC scan code (set 1) and whether it's an extended (E0) one. 0: never sent (the Windows
// keys, media keys, anything not listed). By place, so the sharer's own keyboard layout reads it, as if typed there. Pure.
inline int rc_scan(const std::string &c, bool &ext)
{
  ext = false;
  static const struct { const char *code; int sc; bool ext; } T[] = {
    { "Escape", 0x01 }, { "Digit1", 0x02 }, { "Digit2", 0x03 }, { "Digit3", 0x04 }, { "Digit4", 0x05 }, { "Digit5", 0x06 }, { "Digit6", 0x07 },
    { "Digit7", 0x08 }, { "Digit8", 0x09 }, { "Digit9", 0x0A }, { "Digit0", 0x0B }, { "Minus", 0x0C }, { "Equal", 0x0D }, { "Backspace", 0x0E },
    { "Tab", 0x0F }, { "KeyQ", 0x10 }, { "KeyW", 0x11 }, { "KeyE", 0x12 }, { "KeyR", 0x13 }, { "KeyT", 0x14 }, { "KeyY", 0x15 }, { "KeyU", 0x16 },
    { "KeyI", 0x17 }, { "KeyO", 0x18 }, { "KeyP", 0x19 }, { "BracketLeft", 0x1A }, { "BracketRight", 0x1B }, { "Enter", 0x1C },
    { "ControlLeft", 0x1D }, { "KeyA", 0x1E }, { "KeyS", 0x1F }, { "KeyD", 0x20 }, { "KeyF", 0x21 }, { "KeyG", 0x22 }, { "KeyH", 0x23 },
    { "KeyJ", 0x24 }, { "KeyK", 0x25 }, { "KeyL", 0x26 }, { "Semicolon", 0x27 }, { "Quote", 0x28 }, { "Backquote", 0x29 }, { "ShiftLeft", 0x2A },
    { "Backslash", 0x2B }, { "KeyZ", 0x2C }, { "KeyX", 0x2D }, { "KeyC", 0x2E }, { "KeyV", 0x2F }, { "KeyB", 0x30 }, { "KeyN", 0x31 },
    { "KeyM", 0x32 }, { "Comma", 0x33 }, { "Period", 0x34 }, { "Slash", 0x35 }, { "ShiftRight", 0x36 }, { "NumpadMultiply", 0x37 },
    { "AltLeft", 0x38 }, { "Space", 0x39 }, { "CapsLock", 0x3A }, { "F1", 0x3B }, { "F2", 0x3C }, { "F3", 0x3D }, { "F4", 0x3E }, { "F5", 0x3F },
    { "F6", 0x40 }, { "F7", 0x41 }, { "F8", 0x42 }, { "F9", 0x43 }, { "F10", 0x44 }, { "Numpad7", 0x47 }, { "Numpad8", 0x48 }, { "Numpad9", 0x49 },
    { "NumpadSubtract", 0x4A }, { "Numpad4", 0x4B }, { "Numpad5", 0x4C }, { "Numpad6", 0x4D }, { "NumpadAdd", 0x4E }, { "Numpad1", 0x4F },
    { "Numpad2", 0x50 }, { "Numpad3", 0x51 }, { "Numpad0", 0x52 }, { "NumpadDecimal", 0x53 }, { "IntlBackslash", 0x56 }, { "F11", 0x57 },
    { "F12", 0x58 },
    { "NumpadEnter", 0x1C, true }, { "ControlRight", 0x1D, true }, { "NumpadDivide", 0x35, true }, { "AltRight", 0x38, true },
    { "Home", 0x47, true }, { "ArrowUp", 0x48, true }, { "PageUp", 0x49, true }, { "ArrowLeft", 0x4B, true }, { "ArrowRight", 0x4D, true },
    { "End", 0x4F, true }, { "ArrowDown", 0x50, true }, { "PageDown", 0x51, true }, { "Insert", 0x52, true }, { "Delete", 0x53, true },
  };
  for (const auto &e : T) if (c == e.code) { ext = e.ext; return e.sc; }
  return 0;
}
// A key press never passed on, with these modifiers held (the controller's own, as sent): switching or closing windows outside the share
// (Alt+Tab, Alt+Esc, Alt+F4) and the Start menu or Task Manager (Ctrl+Esc, Ctrl+Shift+Esc). Pure.
inline bool rc_key_refused(int sc, bool alt, bool ctrl)
{
  if (alt && (sc == 0x0F || sc == 0x01 || sc == 0x3E)) return true;
  return ctrl && sc == 0x01;
}

// ---- who may, and for how long (pure; times in seconds on any steady clock) ------------------------------------------------------------
struct RcPolicy {
  static constexpr double LEASE = 3.0;    // the sharing page says something at least this often (it asks every 50 ms), or the share is over here
  static constexpr double GRACE = 2.0;    // after Allow, the sharer's own hand on the mouse doesn't take it back yet
  static constexpr double LOCAL_PX = 12;  // how far the sharer's own mouse moves before control comes back to them
  bool sys = false;       // this system can inject input (Windows)
  bool area = false;      // a share is set up (what and how big)
  bool window = false;    // ... of a window (REAPER's or a plug-in's): control is only ever for those
  bool shape = false;     // ... and the window found matches the picture (the timer's check)
  bool on = false;
  std::string who, why;   // who controls; why control last ended (shown once)
  int idle = 180;
  double page_at = -1e9, input_at = 0, grant_at = 0, bad_at = -1;
  static constexpr double RESHAPE = 2.0;  // a window that stops matching the picture (being resized) ends control only after this long

  bool can() const { return sys && area && window && shape; }
  void heard(double now) { page_at = now; }
  void share(bool is_window, double now) { area = true; window = is_window; shape = false; page_at = now; }
  void unshare(const char *reason) { area = window = shape = false; stop(reason); }
  // -> true when control is now on for `w`. One controller at a time: a grant while someone controls replaces them.
  bool grant(const std::string &w, int idle_s, double now)
  {
    if (!can()) { why = !sys ? "remote control isn't supported on this system yet" : !area ? "nothing is shared"
                        : !window ? "control works for REAPER's window or a plug-in's window, not a whole screen"
                                  : "the shared window isn't REAPER's or the plug-in's (share that window itself)"; return false; }
    on = true; who = w; why.clear(); idle = idle_s > 0 ? idle_s : 180; grant_at = input_at = now; bad_at = -1;
    return true;
  }
  void stop(const char *reason) { if (on && reason) why = reason; on = false; who.clear(); }
  // An input from the controller: -> true when it may go in (and the idle clock starts again).
  bool may_input(double now) { if (!on || !sys || !area || !window) return false; input_at = now; return true; }
  // Each timer tick. local_px: how far the sharer's own mouse moved since Allow (after GRACE); local_click: they clicked. -> true when
  // control just ended (the caller lets go of anything held down).
  bool tick(double now, double local_px, bool local_click, bool hotkey, bool target_gone)
  {
    const bool was = on;
    if (area && now - page_at > LEASE) unshare("the sharing page stopped (closed or asleep)");
    if (shape) bad_at = -1; else if (bad_at < 0) bad_at = now;
    if (!on) return was;
    if (target_gone || (!shape && now - bad_at > RESHAPE)) stop("the shared window closed or changed");
    else if (hotkey) stop("you pressed Ctrl+Alt+Esc");
    else if (now - grant_at >= GRACE && (local_click || local_px > LOCAL_PX)) stop("you moved your mouse");
    else if (now - input_at > idle) stop("no input from them for a while");
    return !on;
  }
};

// The answer to every POST: { sys, area, can, on, who, why, cur: [x, y] or null }. Pure.
inline std::string rc_status_json(const RcPolicy &p, bool cur, double cx, double cy)
{
  auto q = [](const std::string &s) {
    std::string o = "\"";
    for (unsigned char c : s) {
      if (c == '"' || c == '\\') { o += '\\'; o += (char)c; }
      else if (c < 0x20) { char b[8]; snprintf(b, sizeof(b), "\\u%04x", c); o += b; }
      else o += (char)c;
    }
    return o + "\"";
  };
  char xy[64];
  if (cur) snprintf(xy, sizeof(xy), "[%.4f,%.4f]", cx, cy); else snprintf(xy, sizeof(xy), "null");
  return std::string("{\"sys\":") + (p.sys ? "true" : "false") + ",\"area\":" + (p.area && p.shape ? "true" : "false") + ",\"can\":" +
         (p.can() ? "true" : "false") + ",\"on\":" + (p.on ? "true" : "false") + ",\"who\":" + q(p.who) + ",\"why\":" + q(p.why) + ",\"cur\":" + xy + "}";
}
