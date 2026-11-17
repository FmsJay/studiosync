-- feedback.compose / issue_url and callapps.in_list / holds_device are pure (lupa or any Lua 5.4, from the repo root). 0.58.79.
package.loaded.band = package.loaded.band or { VERSION = "test" }
package.path = "lib/?.lua;" .. package.path
local feedback = require("feedback")
local t, b = feedback.compose("bug", "", "It froze when I pressed Play\nThen it came back")
assert(t == "[Bug] It froze when I pressed Play" and b:find("came back", 1, true), "a blank subject takes the body's first line")
t, b = feedback.compose("feature", "  Dark mode  ", "")
assert(t == "[Feature] Dark mode" and b ~= "", "a blank body says so")
assert(feedback.compose("feedback", " ", "\n") == nil, "one or the other is needed")
assert(feedback.encode("a b&c=d/x~") == "a%20b%26c%3Dd%2Fx~", "query encoding")
local u = feedback.issue_url("[Bug] x", ("long line\n"):rep(2000), "bug")
assert(#u <= feedback.URL_MAX and u:find("cut%20short", 1, true), "a long body is cut to fit the address, saying so")
assert(u:sub(1, #feedback.REPO + 11) == feedback.REPO .. "/issues/new" and u:find("&labels=bug&", 1, true), "GitHub's new-issue page, labelled")

local callapps = require("callapps")
local win = '\n"System Idle Process","0","Services","0","8 K"\n"Discord.exe","1234","Console","1","90,000 K"\n"reaper.exe","99","Console","1","1 K"\n'
local a = callapps.in_list(win, true)
assert(#a == 1 and a[1] == "Discord", "Discord in a Windows process list")
local mac = "\nlaunchd\nzoom.us\nDiscord\nREAPER\nDiscord Helper\n"
a = callapps.in_list(mac, false)
assert(#a == 2 and a[1] == "Discord" and a[2] == "Zoom", "a Mac's, by whole name (not Discord Helper twice)")
assert(#callapps.in_list("\nreaper\n", false) == 0, "none")
assert(callapps.holds_device("ASIO", true) and not callapps.holds_device("WASAPI", true) and not callapps.holds_device("CoreAudio", false), "ASIO on Windows holds the interface")
-- (0.58.82) REAPER hearing itself through Voicemeeter: James's PC as it was (Potato; VAIO3 to A1 and B2, recording from B2)
local OUT, IN = "WASAPI Voicemeeter VAIO3 Input (VB-Audio Voicemeeter VAIO)", "WASAPI Voicemeeter Out B2 (VB-Audio Voicemeeter VAIO)"
local report = "type=3\ns5=0,1,0\ns6=1,1,1\ns7=0,1,0\n"
assert(callapps.vm_strip(OUT, 3) == 7 and callapps.vm_bus(IN) == 2, "VAIO3 is strip 7 on a Potato; Out B2 is B2")
assert(callapps.vm_strip("Voicemeeter Input (VB-Audio Voicemeeter VAIO)", 2) == 3 and callapps.vm_strip("Voicemeeter AUX Input (VB-Audio)", 3) == 6, "VAIO and AUX")
local w = callapps.vm_loop(OUT, IN, report)
assert(w and w:find("VAIO3 strip", 1, true) and w:find("(B2)", 1, true), "the loop, said: " .. tostring(w))
assert(callapps.vm_loop(OUT, IN, "type=3\ns7=1,0,0\n") == nil, "VAIO3 to B1 only: no loop")
assert(callapps.vm_loop(OUT, "Focusrite USB (2- Focusrite)", report) == nil and callapps.vm_loop("Speakers (Realtek)", IN, report) == nil, "not both Voicemeeter: nothing")
assert(callapps.vm_loop(OUT, IN, "off") == nil and callapps.vm_loop(OUT, IN, nil) == nil, "Voicemeeter not running, no report yet: nothing")
print("ok")
