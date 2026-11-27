// Remote control of a shared window, its pure parts (extension/remotectl.h; rt-share, docs/rt/rt-share.md "Cursor and control"): the
// message parser, where a point of the picture lands on screen and back, the "same window" shape check, SendInput's absolute coordinates, the
// wheel, keys by place and the combinations never sent, and the policy (off until granted, one controller, the sharer's mouse, hotkey, idle,
// the page going quiet, the window closing or changing). No REAPER, no Windows.
//   Windows: tests\build_remotectl_test.cmd    macOS/Linux: c++ -std=c++17 -O2 tests/remotectl_test.cpp -o remotectl_test && ./remotectl_test
// GPL-3.0-or-later.
#include <cstdio>
#include "../extension/remotectl.h"

static int fails = 0, checks = 0;
#define CHECK(c, ...) do { ++checks; if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

int main()
{
  RcMsg m;
  // ---- the parser ----
  CHECK(rc_parse("{\"t\":\"status\"}", m) && m.kind == RCK_STATUS, "status");
  CHECK(rc_parse(" { \"t\" : \"stop\" } ", m) && m.kind == RCK_STOP, "spaces");
  CHECK(rc_parse("{\"t\":\"move\",\"x\":0.25,\"y\":1}", m) && m.kind == RCK_MOVE && m.x == 0.25 && m.y == 1, "move");
  CHECK(!rc_parse("{\"t\":\"move\",\"x\":1.01,\"y\":0.5}", m), "x past 1");
  CHECK(!rc_parse("{\"t\":\"move\",\"x\":-0.0001,\"y\":0.5}", m), "x under 0");
  CHECK(!rc_parse("{\"t\":\"move\",\"x\":0.5}", m), "no y");
  CHECK(!rc_parse("{\"t\":\"move\",\"x\":\"0.5\",\"y\":0.5}", m), "x a string");
  CHECK(!rc_parse("{\"t\":\"move\",\"x\":1e999,\"y\":0.5}", m), "x infinite");
  CHECK(rc_parse("{\"t\":\"down\",\"b\":2,\"x\":0,\"y\":0}", m) && m.kind == RCK_DOWN && m.b == 2, "right button down");
  CHECK(!rc_parse("{\"t\":\"down\",\"b\":3,\"x\":0,\"y\":0}", m), "button 3");
  CHECK(!rc_parse("{\"t\":\"up\",\"b\":0.5,\"x\":0,\"y\":0}", m), "button 0.5");
  CHECK(rc_parse("{\"t\":\"wheel\",\"x\":0.5,\"y\":0.5,\"dy\":-100}", m) && m.kind == RCK_WHEEL && m.dy == -100, "wheel");
  CHECK(!rc_parse("{\"t\":\"wheel\",\"x\":0.5,\"y\":0.5,\"dy\":20000}", m), "wheel too far");
  CHECK(rc_parse("{\"t\":\"key\",\"code\":\"KeyA\",\"down\":true}", m) && m.kind == RCK_KEY && m.code == "KeyA" && m.down, "key");
  CHECK(!rc_parse("{\"t\":\"key\",\"code\":\"KeyA\"}", m), "key without down");
  CHECK(!rc_parse("{\"t\":\"key\",\"code\":\"Key A\",\"down\":true}", m), "key code with a space");
  CHECK(rc_parse("{\"t\":\"share\",\"target\":\"reaper\",\"pw\":1920,\"ph\":1040}", m) && m.kind == RCK_SHARE && m.target == RCT_REAPER && m.pw == 1920, "share reaper");
  CHECK(!rc_parse("{\"t\":\"share\",\"target\":\"desktop\",\"pw\":1920,\"ph\":1040}", m), "share an unknown target");
  CHECK(!rc_parse("{\"t\":\"share\",\"target\":\"reaper\",\"pw\":8,\"ph\":1040}", m), "share a tiny picture");
  CHECK(rc_parse("{\"t\":\"share\",\"target\":\"fx\",\"track\":\"{0A1B2C3D-0000-0000-0000-00000000ABCD}\",\"fxi\":1,\"pw\":640,\"ph\":480}", m) &&
        m.target == RCT_FX && m.fxi == 1 && m.track == "{0A1B2C3D-0000-0000-0000-00000000ABCD}", "share a plug-in window");
  CHECK(!rc_parse("{\"t\":\"share\",\"target\":\"fx\",\"track\":\"{0A1B2C3D-0000-0000-0000-00000000ABCZ}\",\"fxi\":1,\"pw\":640,\"ph\":480}", m), "a bad GUID");
  CHECK(!rc_parse("{\"t\":\"share\",\"target\":\"fx\",\"track\":\"{0A1B2C3D-0000-0000-0000-00000000ABCD}\",\"pw\":640,\"ph\":480}", m), "no FX index");
  CHECK(rc_parse("{\"t\":\"grant\",\"who\":\"chilio\"}", m) && m.kind == RCK_GRANT && m.who == "chilio" && m.idle == 180, "grant, the default idle");
  CHECK(rc_parse("{\"t\":\"grant\",\"who\":\"Ren\\u00e9\",\"idle\":60}", m) && m.who == "Ren\xc3\xa9" && m.idle == 60, "a name with \\u, idle 60");
  CHECK(!rc_parse("{\"t\":\"grant\",\"who\":\"\"}", m), "grant to nobody");
  CHECK(rc_parse("{\"t\":\"grant\",\"who\":\"a\\nb\"}", m) && m.who == "a b", "an escaped newline in a name is a space");
  CHECK(!rc_parse("{\"t\":\"grant\",\"who\":\"x\",\"idle\":5}", m), "an idle of 5 s");
  CHECK(!rc_parse("{\"t\":\"grant\",\"who\":\"0123456789012345678901234567890123456789012345678901234567890123456789\"}", m), "a 70-byte name");
  CHECK(!rc_parse("{\"t\":\"move\",\"x\":0.5,\"y\":0.5,\"n\":{\"a\":1}}", m), "a nested object");
  CHECK(!rc_parse("{\"t\":\"move\",\"x\":0.5,\"y\":0.5,\"n\":[1]}", m), "an array");
  CHECK(!rc_parse("{\"t\":\"move\",\"x\":0.5,\"y\":0.5}x", m), "trailing junk");
  CHECK(!rc_parse("{\"t\":\"move\",\"x\":0.5,\"y\":0.5", m), "unterminated");
  CHECK(!rc_parse("{\"t\":\"exec\"}", m), "an unknown kind");
  CHECK(!rc_parse("", m) && !rc_parse("[]", m) && !rc_parse("{}", m), "empty");
  CHECK(!rc_parse(std::string("{\"t\":\"status\",\"pad\":\"") + std::string(3000, 'a') + "\"}", m), "over RC_BODY_MAX");
  CHECK(!rc_parse("{\"t\":\"st\x01" "atus\"}", m), "a control character in a string");

  // ---- where ----
  const RcRect win{ 100, 50, 800, 600 };
  int sx, sy;
  CHECK(rc_map(win, 0, 0, sx, sy) && sx == 100 && sy == 50, "top left");
  CHECK(rc_map(win, 1, 1, sx, sy) && sx == 899 && sy == 649, "bottom right is inside, not one past");
  CHECK(rc_map(win, 0.5, 0.25, sx, sy) && sx == 500 && sy == 200, "middle");
  CHECK(!rc_map(win, 1.0001, 0.5, sx, sy) && !rc_map(RcRect(), 0.5, 0.5, sx, sy), "outside, or no area");
  CHECK(rc_inside(win, 100, 50) && rc_inside(win, 899, 649) && !rc_inside(win, 900, 300) && !rc_inside(win, 99, 300) && !rc_inside(win, 300, 650), "inside");
  for (double x = 0; x <= 1; x += 0.0625) for (double y = 0; y <= 1; y += 0.125) {
    CHECK(rc_map(win, x, y, sx, sy) && rc_inside(win, sx, sy), "every mapped point is inside (%g, %g)", x, y);
  }
  const RcRect neg{ -1920, -200, 1920, 1080 }; // (a screen left of and above the main one)
  CHECK(rc_map(neg, 0.5, 0.5, sx, sy) && sx == -960 && sy == 340 && rc_inside(neg, sx, sy), "negative coordinates");
  double ux, uy;
  CHECK(rc_unmap(win, 500, 200, ux, uy) && std::fabs(ux - 0.500625) < 1e-9 && std::fabs(uy - 0.250833) < 1e-5, "back to 0-1");
  CHECK(!rc_unmap(win, 99, 200, ux, uy), "the pointer outside: nothing");
  CHECK(rc_map(win, ux, uy, sx, sy) && sx == 500 && sy == 200, "and there again");
  CHECK(rc_same_shape(1920, 1040, RcRect{ 0, 0, 1920, 1040 }), "the same size");
  CHECK(rc_same_shape(960, 520, RcRect{ 0, 0, 1920, 1040 }), "half size (a page that asked for less)");
  CHECK(rc_same_shape(3840, 2080, RcRect{ 0, 0, 1920, 1040 }), "twice (a Retina capture)");
  CHECK(!rc_same_shape(1920, 1080, RcRect{ 0, 0, 1920, 1040 }), "1080 against 1040 tall is 3.7 %% off: not it");
  CHECK(rc_same_shape(1906, 1033, RcRect{ 0, 0, 1920, 1040 }), "a few pixels of border either way still is");
  CHECK(!rc_same_shape(1920, 1200, RcRect{ 0, 0, 1920, 1040 }), "another shape: some other window");
  CHECK(!rc_same_shape(400, 300, RcRect{ 0, 0, 1920, 1440 }), "too small a scale");
  CHECK(!rc_same_shape(0, 300, win) && !rc_same_shape(800, 600, RcRect()), "nothing");
  int ax, ay;
  const RcRect virt{ -1920, 0, 3840, 1080 };
  rc_abs(-1920, 0, virt, ax, ay); CHECK(ax == 0 && ay == 0, "the virtual desktop's corner");
  rc_abs(1919, 1079, virt, ax, ay); CHECK(ax == 65535 && ay == 65535, "the far corner");
  rc_abs(0, 540, virt, ax, ay); CHECK(std::abs(ax - 32776) <= 1 && std::abs(ay - 32798) <= 1, "the middle: %d %d", ax, ay);
  rc_abs(5000, -5, virt, ax, ay); CHECK(ax == 65535 && ay == 0, "clamped");
  CHECK(rc_wheel(100, false) == -120 && rc_wheel(-100, false) == 120, "a notch, down and up");
  CHECK(rc_wheel(100, true) == 120, "horizontal: right is positive");
  CHECK(rc_wheel(1e5, false) == -1200 && rc_wheel(-1e5, true) == -1200, "at most 10 notches");

  // ---- keys ----
  bool ext;
  CHECK(rc_scan("KeyA", ext) == 0x1E && !ext, "A");
  CHECK(rc_scan("Escape", ext) == 0x01 && !ext, "Esc");
  CHECK(rc_scan("ArrowLeft", ext) == 0x4B && ext, "an arrow is extended");
  CHECK(rc_scan("ControlRight", ext) == 0x1D && ext && rc_scan("ControlLeft", ext) == 0x1D && !ext, "both Ctrls");
  CHECK(rc_scan("MetaLeft", ext) == 0 && rc_scan("MetaRight", ext) == 0 && rc_scan("OSLeft", ext) == 0, "never the Windows keys");
  CHECK(rc_scan("AudioVolumeUp", ext) == 0 && rc_scan("", ext) == 0 && rc_scan("keya", ext) == 0, "nothing unlisted");
  CHECK(rc_key_refused(0x0F, true, false) && rc_key_refused(0x3E, true, false) && rc_key_refused(0x01, true, false), "Alt+Tab, Alt+F4, Alt+Esc");
  CHECK(rc_key_refused(0x01, false, true), "Ctrl+Esc (and Ctrl+Shift+Esc)");
  CHECK(!rc_key_refused(0x0F, false, false) && !rc_key_refused(0x01, false, false) && !rc_key_refused(0x1E, true, true), "Tab, Esc, Ctrl+Alt+A go");

  // ---- the policy ----
  RcPolicy p;
  CHECK(!p.can() && !p.on && !p.may_input(0), "off at first");
  CHECK(!p.grant("chilio", 180, 0) && p.why.find("supported") != std::string::npos, "no system support: no grant");
  p.sys = true;
  CHECK(!p.grant("chilio", 180, 0) && p.why == "nothing is shared", "nothing shared: no grant");
  p.share(false, 0); p.shape = true;
  CHECK(!p.grant("chilio", 180, 0) && p.why.find("not a whole screen") != std::string::npos, "a whole screen: no control");
  p.share(true, 0);
  CHECK(!p.grant("chilio", 180, 0) && p.why.find("isn't REAPER's") != std::string::npos, "a window that doesn't match: no control");
  p.shape = true;
  CHECK(p.grant("chilio", 180, 1) && p.on && p.who == "chilio" && p.why.empty(), "granted");
  CHECK(p.may_input(1.5), "an input goes");
  CHECK(!p.tick(1.6, 500, true, false, false), "the sharer's own mouse in the first GRACE s doesn't take it back");
  p.heard(3.1);
  CHECK(p.tick(3.1, 13, false, false, false) && !p.on && p.why == "you moved your mouse" && p.who.empty(), "past GRACE, 13 px does");
  CHECK(!p.may_input(3.2), "and nothing goes then");
  p.heard(3.2); p.grant("chilio", 180, 3.2);
  CHECK(!p.tick(5.3, 11, false, false, false), "11 px isn't enough");
  CHECK(p.tick(5.4, 0, true, false, false) && p.why == "you moved your mouse", "a click is");
  p.heard(5.4); p.grant("chilio", 180, 5.4);
  CHECK(p.tick(5.5, 0, false, true, false) && p.why == "you pressed Ctrl+Alt+Esc", "the hotkey, at once (no grace)");
  p.heard(5.5); p.grant("chilio", 60, 5.5);
  p.heard(30); CHECK(!p.tick(30, 0, false, false, false), "29 s idle of 60");
  p.heard(65); CHECK(p.tick(65.6, 0, false, false, false) && p.why == "no input from them for a while", "past 60 s idle");
  p.heard(66); p.grant("chilio", 180, 66);
  p.grant("Ren", 180, 66.5);
  CHECK(p.on && p.who == "Ren", "one at a time: a new grant replaces the last");
  p.heard(67); p.shape = false;
  CHECK(!p.tick(67, 0, false, false, false) && p.on, "a window being resized doesn't end it at once");
  p.heard(68); CHECK(p.may_input(68), "and input still goes meanwhile");
  p.heard(69.1); CHECK(p.tick(69.1, 0, false, false, false) && p.why == "the shared window closed or changed", "after RESHAPE s it does");
  p.shape = true; p.heard(70); p.grant("chilio", 180, 70);
  p.heard(70.5); p.shape = false; p.tick(70.5, 0, false, false, false); p.shape = true;
  p.heard(71); CHECK(!p.tick(71, 0, false, false, false) && p.on, "matching again resets the clock");
  CHECK(p.tick(71.1, 0, false, false, true) && p.why == "the shared window closed or changed", "the window gone: at once");
  p.heard(72); p.grant("chilio", 180, 72);
  CHECK(!p.tick(74.9, 0, false, false, false) && p.on, "the page said something 2.9 s ago");
  CHECK(p.tick(75.1, 0, false, false, false) && !p.on && !p.area && p.why.find("sharing page stopped") != std::string::npos, "3.1 s: the share is over here");
  p.share(true, 80); p.shape = true; p.grant("chilio", 180, 80); p.stop("you took control back");
  CHECK(!p.on && p.why == "you took control back", "Stop");
  p.grant("chilio", 180, 81); p.unshare("the share ended");
  CHECK(!p.on && !p.area && !p.can() && p.why == "the share ended", "the share ends: so does control");

  // ---- the answer ----
  RcPolicy q; q.sys = true; q.share(true, 0); q.shape = true; q.grant("Ana \"A\"", 180, 0);
  const std::string j = rc_status_json(q, true, 0.25, 0.5);
  CHECK(j == "{\"sys\":true,\"area\":true,\"can\":true,\"on\":true,\"who\":\"Ana \\\"A\\\"\",\"why\":\"\",\"cur\":[0.2500,0.5000]}", "status: %s", j.c_str());
  q.stop("you moved your mouse");
  CHECK(rc_status_json(q, false, 0, 0) == "{\"sys\":true,\"area\":true,\"can\":true,\"on\":false,\"who\":\"\",\"why\":\"you moved your mouse\",\"cur\":null}", "status off");

  printf("%s: %d checks, %d failed\n", fails ? "FAIL" : "ok", checks, fails);
  return fails ? 1 : 0;
}
