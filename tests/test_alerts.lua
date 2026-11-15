-- Phone alerts: what's sent, and which channel names and servers are taken from the studio's band.json (lupa or Lua 5.4, from the repo root)
reaper = setmetatable({}, { __index = function() return function() end end })
package.path = "lib/?.lua;" .. package.path
local band = require("band")
local alerts = require("alerts")
local j = {}
band.read_json = function() return j end
local body = band.json_decode(alerts.body("studiosync-abc", "StudioSync: Sunset Drive", 'Bee: "take 3" is up & ready'))
assert(body.topic == "studiosync-abc" and body.title == "StudioSync: Sunset Drive" and body.message == 'Bee: "take 3" is up & ready', "sent as it is, in JSON")
j = { alerts = "studiosync-k3m9" }
assert(alerts.channel("root") == "studiosync-k3m9", "the studio's channel")
j = { alerts = "a b; rm -rf /" }
assert(alerts.channel("root") == nil, "a channel name with anything odd in it is never used")
j = {}
assert(alerts.channel("root") == nil, "none: alerts are off")
assert(alerts.server("root") == "https://ntfy.sh", "ntfy.sh unless the studio names another")
j = { alerts_server = "https://ntfy.example.org/" }
assert(alerts.server("root") == "https://ntfy.example.org", "its own server")
j = { alerts_server = "http://evil & calc" }
assert(alerts.server("root") == "https://ntfy.sh", "only a plain https address")
assert(alerts.send({ user = "Bee" }, "chat", "t", "m") == false, "no studio folder: nothing sent")

-- the studio's call link: only a plain https address is ever opened
assert(alerts.call_ok("https://discord.gg/Ab3dE"), "a Discord invite")
assert(alerts.call_ok("https://zoom.us/j/123456789?pwd=abcDEF"), "a Zoom room")
assert(not alerts.call_ok("http://discord.gg/x"), "not plain http")
assert(not alerts.call_ok('https://x.com/" & calc'), "no quotes or &")
assert(not alerts.call_ok("https://x.com/%COMSPEC%"), "no %")
assert(not alerts.call_ok("file:///C:/Windows/System32/calc.exe"), "nothing but https")
j = { call = "https://meet.google.com/abc-defg-hij" }
assert(alerts.call_link("root") == "https://meet.google.com/abc-defg-hij", "the studio's link")
j = { call = "javascript:alert(1)" }
assert(alerts.call_link("root") == nil, "a bad one is ignored")

-- (0.58.63) cut to a length without splitting a character
assert(alerts.cut("abcdef", 4) == "abcd" and alerts.cut("abc", 10) == "abc", "plain text: as long as asked")
local s = "ab" .. "\u{e9}" .. "cd" -- a, b, é (2 bytes), c, d
assert(alerts.cut(s, 3) == "ab", "half an é is dropped, not sent: " .. alerts.cut(s, 3))
assert(alerts.cut(s, 4) == "ab\u{e9}", "a whole é stays")
local e = string.rep("x", 299) .. "\u{1F3B8}" -- a guitar emoji, 4 bytes, across the 300 mark
assert(#alerts.cut(e, 300) == 299, "an emoji across the cut goes whole")
assert(band.json_decode(alerts.body("c", "t", alerts.cut(e, 300))), "and what's sent is still JSON")
print("ok")
