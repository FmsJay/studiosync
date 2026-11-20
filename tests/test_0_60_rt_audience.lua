-- Live to an audience (lib/audience.lua; rt-audience): the link, what a host page may send, what listeners are told (the public port's never
-- names anyone), who's playing, the links' lifecycle through a stand-in extension (owner/admin only, rate limits, run out, revoked, given
-- back after a REAPER restart), and the owner's public switch: never on by itself, owner only, only with the warning confirmed, Funnel's
-- failure leaves it off, its hours run out, off revokes every public link. Plus a check of the pages and the wiring. The server's half (the
-- allow-list, the Opus fan-out, caps, revoke, rate limits): tests/audience_test.cpp.
package.path = "lib/?.lua;" .. package.path
local clock = 1000
local ext, links_set, starts, infos, ts_calls = {}, {}, {}, {}, {}
local ext_status = { links = {} }
local play_state = 0
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  genGuid = function() return string.format("{%08X-1234-5678-9ABC-%012X}", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff)) end,
  GetPlayStateEx = function() return play_state end,
  EnumerateFiles = function() return nil end,
  StudioSync_AudienceStart = function(folder, cap, kbps, pport) starts[#starts + 1] = { folder = folder, cap = cap, kbps = kbps, pport = pport }; return 1 end,
  StudioSync_AudienceLink = function(id, code, secs, pub) links_set[#links_set + 1] = { id = id, code = code, secs = secs, pub = pub }; return 1 end,
  StudioSync_AudienceInfo = function(full, pub, mix) infos[#infos + 1] = { full = full, pub = pub, mix = mix }; return 1 end,
  StudioSync_AudienceStatus = function() return require("band").json_encode(ext_status) end,
}, { __index = function() return function() return "" end end })

local band = require("band")
local logged = {}
band.log = function(s) logged[#logged + 1] = s end
local real_time, toff = os.time, 0
os.time = function(t) if t then return real_time(t) end return real_time() + toff end
local role = "owner"
package.loaded.groups = { may_manage = function() return role ~= "member" end, role = function() return role end }
local tsname, ts_answer = "james-main.tail99.ts.net.", "0\n"
package.loaded.services = { my_tailscale_name = function() return tsname end, tailscale_exe = function() return "tailscale" end,
  ts_exec = function(args) ts_calls[#ts_calls + 1] = args; return ts_answer end }
package.loaded.phonerec = { auto_on = function() return false end }
local la_status = {}
package.loaded.liveaudio = { status = function() return la_status end, names = function() return { ["chilio-mac:47281"] = "Chilio" } end,
  name_of = function(p, names) return (names or {})[p] or p end }
local au = require("audience")

-- ---- pure ----
local C = string.rep("ab", 16)
assert(au.url("pc.tail9.ts.net.", C, 8443) == "https://pc.tail9.ts.net:8443/listen/?l=" .. C, "the link: the secure address, the trailing dot gone")
assert(au.url(nil, C) == nil and au.url("a b", C) == nil and au.url("pc", "abc") == nil and au.url("pc", string.rep("Z", 32)) == nil, "no link from a bad name or code")
local d = au.parse({ make = { hours = 99999, public = "yes" }, revoke = "../etc", cap = 5000, kbps = 8, public = { on = "true" } })
assert(d.make and d.make.hours == nil and d.make.public == nil and d.revoke == nil and d.cap == nil and d.kbps == nil and d.public == nil,
  "a host's action: out-of-range hours, caps, rates dropped; only true makes a public link; the switch takes booleans only")
d = au.parse({ revoke = "0123456789abcdef", cap = 30.7, kbps = 128, public = { on = true, sure = 1 } })
assert(d.revoke == "0123456789abcdef" and d.cap == 30 and d.kbps == 128 and d.public.on == true and d.public.sure == false, "the switch's sure must be true itself")
assert(au.parse("x") == nil and au.parse({}) == nil, "nothing usable: nothing")
assert(#au.alive({ { id = "0123456789abcdef", code = C, ends = 50 }, { id = "x", code = C, ends = 500 }, { id = "0123456789abcdef", code = C, ends = 500 } }, 100) == 1,
  "run out and malformed left out")
assert(au.may_make({}, au.MAX_LINKS, 0) == false and select(2, au.may_make({ 100 }, 0, 102)):find("every") and au.may_make({ 100 }, 0, 106), "the gap and the most links")
local full, pubj = au.info("Bee\nSong", true, { "James", "Chi\0lio" }, "Bee 2026-11-20.wav")
local F, P = band.json_decode(full), band.json_decode(pubj)
assert(F.song == "Bee Song" and F.live == true and F.who[2] == "Chi lio" and F.mix == "Bee 2026-11-20.wav", "the tailnet's info: song, live, who, the mix's name")
local pk = {}
for k in pairs(P) do pk[#pk + 1] = k end
table.sort(pk)
assert(table.concat(pk, ",") == "live,mix,song" and P.mix == true and not pubj:find("James") and not pubj:find("2026"), "the public's: song, live, a mix or not; never a name")
local big = {}
for i = 1, 40 do big[i] = string.rep("n", 100) end
full, pubj = au.info(string.rep("s", 500), false, big, string.rep("m", 500))
assert(#full < 2048 and #pubj < 2048, "under the extension's 2 KB, whatever the names")
assert(au.playing(1, {}) and au.playing(4, {}) and not au.playing(0, {}) and not au.playing(2, {}), "playing or recording here; paused isn't")
local la = { peers = { ["chilio-mac:47281"] = { streaming = true, level = 0.2 }, ["bo:1"] = { streaming = true, level = 0 }, ["cy:1"] = { streaming = false, level = 0.5 } } }
assert(au.playing(0, la), "a bandmate heard making sound is playing")
local who = au.who("James", false, la, function(p) return ({ ["chilio-mac:47281"] = "Chilio" })[p] or p end)
assert(#who == 1 and who[1] == "Chilio", "who's playing: the ones heard making sound, by name")
assert(au.who("James", true, {}, tostring)[1] == "James", "and this computer's user while it plays")
assert(au.span(900) == "15 minutes" and au.span(60) == "1 minute" and au.span(3600) == "1 hour" and au.span(7200) == "2 hours" and au.span(5400) == "1.5 hours" and
  au.span(7 * 24 * 3600) == "168 hours", "how long a link works, in words (a 15-minute link said 0 hours)")
assert(au.funnel_args(true) == "funnel --bg --yes --https=10000 http://127.0.0.1:47320" and au.funnel_args(false) == "funnel --https=10000 off", "Funnel's arguments")

-- ---- links ----
local cfg, b = { user = "James", root = "C:/studio" }, { song = "Bee", room = "main" }
local pub = {}
local function publish(topic, t) pub[topic] = t end
role = "member"
assert(au.action("P", cfg, b, { make = { hours = 4 } }):find("owner or an admin") and #links_set == 0, "a member can't make a listening link")
role = "admin"
local said = au.action("P", cfg, b, { make = { hours = 2 } })
assert(said:find("tailnet listening link for 2 hours") and #links_set == 1, "an admin makes one: " .. tostring(said))
local L1 = links_set[1]
assert(#L1.id == 16 and L1.id:match("^[0-9a-f]+$") and #L1.code == 32 and L1.code:match("^[0-9a-f]+$") and L1.secs == 7200 and L1.pub == 0,
  "the extension gets an id, a 128-bit code, two hours, not public")
assert(starts[#starts].pport == 0 and starts[#starts].cap == au.CAP and starts[#starts].kbps == au.KBPS and starts[#starts].folder:find("webui$"),
  "started with no public port, the default cap and rate, the pages' folder")
assert(au.action("P", cfg, b, { make = { hours = 2 } }):find("every 5 s") and #links_set == 1, "another within 5 s: refused")
toff = toff + 10
assert(au.action("P", cfg, b, { make = { hours = 2, public = true } }):find("Public listening on first") and #links_set == 1, "a public link while public listening is off: refused")
ext_status = { links = { [L1.id] = { n = 3, pub = false, left = 7000 } }, listeners = 3, enc_load = 0.004, out_kbps = 310 }
clock = clock + 2
au.tick("P", cfg, b, publish, clock)
local t = pub.audience
assert(t.may and not t.owner and #t.links == 1 and t.links[1].url == "https://james-main.tail99.ts.net:8443/listen/?l=" .. L1.code and t.links[1].n == 3 and
  t.listeners == 3 and t.enc_load == 0.004 and not t.public, "the host's topic: the link to copy, its listeners, the cost, public off")
assert(not t.live and #infos > 0, "not playing")
local inf = infos[#infos]
assert(band.json_decode(inf.full).song == "Bee" and band.json_decode(inf.full).live == false and inf.mix == "", "the listeners told the song, not live, no mix yet")
play_state = 1
la_status = la
clock = clock + 2
au.tick("P", cfg, b, publish, clock)
inf = infos[#infos]
local fj = band.json_decode(inf.full)
assert(fj.live and fj.who[1] == "James" and fj.who[2] == "Chilio" and not inf.pub:find("James") and not inf.pub:find("Chilio") and pub.audience.live,
  "playing: live, and who's playing for the tailnet (never the public)")
-- REAPER restarted: the extension forgot the link; it's given back with the time it has left
local n = #links_set
ext_status = { links = {} }
clock = clock + 2
au.tick("P", cfg, b, publish, clock)
assert(#links_set == n + 1 and links_set[#links_set].id == L1.id and links_set[#links_set].code == L1.code and links_set[#links_set].secs <= 7200 and links_set[#links_set].secs > 7000,
  "a link the extension forgot (REAPER restarted): given back with what's left of its time")
-- run out
toff = toff + 7300
clock = clock + 2
au.tick("P", cfg, b, publish, clock)
assert(links_set[#links_set].id == L1.id and links_set[#links_set].code == "" and #pub.audience.links == 0, "run out: revoked in the extension, gone from the list")
-- revoke
toff = toff + 10
au.action("P", cfg, b, { make = { hours = 1 } })
local L2 = links_set[#links_set]
said = au.action("P", cfg, b, { revoke = L2.id })
assert(said:find("revoked by James") and links_set[#links_set].id == L2.id and links_set[#links_set].code == "" and #(band.ext_json(band.SECTION, au.KEY) or {}) == 0, "revoked: at once")
-- a 15-minute link says so
toff = toff + 10
said = au.action("P", cfg, b, { make = { hours = 0.25 } })
assert(said:find("for 15 minutes") and links_set[#links_set].secs == 900, "a 15-minute link: " .. tostring(said))
au.action("P", cfg, b, { revoke = links_set[#links_set].id })
-- cap and rate
said = au.action("P", cfg, b, { cap = 50, kbps = 128 })
assert(said:find("50 listeners, 128") and starts[#starts].cap == 50 and starts[#starts].kbps == 128, "the cap and rate, kept and given to the extension")

-- ---- the public switch ----
for _, a in ipairs(ts_calls) do assert(not a:find("funnel %-%-bg"), "public listening is never turned on by itself") end
role = "admin"
assert(au.action("P", cfg, b, { public = { on = true, sure = true } }):find("only the studio's owner") and not au.public_on(), "an admin can't turn it on")
role = "owner"
assert(au.action("P", cfg, b, { public = { on = true } }):find("warning confirmed") and not au.public_on() and #ts_calls == 0, "the owner, without confirming the warning: no")
ts_answer = "1\nFunnel is not enabled on your tailnet."
said = au.action("P", cfg, b, { public = { on = true, sure = true } })
assert(said:find("didn't open Funnel") and said:find("not enabled") and not au.public_on() and starts[#starts].pport == 0, "Funnel refused: it stays off, the port shut again")
ts_answer = "0\n"
said = au.action("P", cfg, b, { public = { on = true, sure = true } })
assert(said:find("PUBLIC listening is on for 6 hours") and au.public_on() and ts_calls[#ts_calls] == au.funnel_args(true), "the owner confirms: Funnel opened")
local s_on = starts[#starts]
assert(s_on.pport == au.PUBLIC_PORT, "the extension's public port opened first")
toff = toff + 10
said = au.action("P", cfg, b, { make = { hours = 1, public = true } })
local LP = links_set[#links_set]
assert(said:find("PUBLIC listening link") and LP.pub == 1, "now a public link can be made")
toff = toff + 10
au.action("P", cfg, b, { make = { hours = 1 } })
local LT = links_set[#links_set]
ext_status = { links = { [LP.id] = { n = 1, pub = true }, [LT.id] = { n = 0 } }, public = 1, listeners = 1 }
clock = clock + 2
au.tick("P", cfg, b, publish, clock)
t = pub.audience
local pl
for _, k in ipairs(t.links) do if k.pub then pl = k end end
assert(t.owner and t.public and t.public["until"] and pl and pl.url == "https://james-main.tail99.ts.net:10000/listen/?l=" .. LP.code and t.warning:find("open internet"),
  "the host's topic: public on, the public link on Funnel's port, the warning")
-- its hours run out: off by itself, public links revoked, tailnet ones kept
toff = toff + au.PUBLIC_HOURS * 3600
local before = #links_set
ext_status = { links = { [LP.id] = { n = 1, pub = true }, [LT.id] = { n = 0 } } }
-- (the tailnet link would run out too in 6 h: give it a long life first)
local kept = band.ext_json(band.SECTION, au.KEY)
for _, k in ipairs(kept) do if k.id == LT.id then k.ends = os.time() + 3600 end end
band.set_ext_json(band.SECTION, au.KEY, kept, true)
local ts_before = #ts_calls
clock = clock + 2
au.tick("P", cfg, b, publish, clock)
local revoked_pub = false
for i = before + 1, #links_set do if links_set[i].id == LP.id and links_set[i].code == "" then revoked_pub = true end end
assert(not au.public_on() and #ts_calls == ts_before + 1 and ts_calls[#ts_calls] == au.funnel_args(false), "run out: Funnel turned off")
assert(revoked_pub and not pub.audience.public and starts[#starts].pport == 0, "the public link revoked, the public port shut")
assert(#pub.audience.links == 1 and not pub.audience.links[1].pub, "the tailnet link stays")
local saw_off = false
for _, s in ipairs(logged) do if s:find("ran out") then saw_off = true end end
assert(saw_off, "said in the log")
-- on again, then the owner turns it off
toff = toff + 10
au.action("P", cfg, b, { public = { on = true, sure = true } })
toff = toff + 10
au.action("P", cfg, b, { make = { hours = 1, public = true } })
local LP2 = links_set[#links_set]
role = "admin"
assert(au.action("P", cfg, b, { public = { on = false } }):find("only the studio's owner") and au.public_on(), "an admin can't turn it off either (the owner's switch)")
role = "owner"
said = au.action("P", cfg, b, { public = { on = false } })
assert(said:find("off; every public link revoked") and not au.public_on() and links_set[#links_set].id == LP2.id and links_set[#links_set].code == "" and
  ts_calls[#ts_calls] == au.funnel_args(false), "the owner turns it off: Funnel closed, public links revoked")

-- ---- wiring and pages ----
package.loaded.webui = nil
local okw, webui = pcall(require, "webui")
assert(okw and webui.ACTIONS.audience and webui.parse_action('{"topic":"audience","revoke":"0123456789abcdef"}') == "audience", "lib/webui.lua takes the topic")
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end
local wsrc = read("lib/webui.lua")
assert(wsrc:find('require%("audience"%)%.action') and wsrc:find('require%("audience"%)%.tick'), "and hands it on, and ticks it")
local html = read("lib/webui/listen.html")
for src in html:gmatch('src="([^"]+)"') do assert(src == "listen.js", "listen.html loads only its own script: " .. src) end
for href in html:gmatch('href="([^"]+)"') do assert(href == "listen.css" or href == "data:,", "and its own style (no icon to fetch): " .. href) end
assert(not html:find("<script>") and not html:find("style="), "no inline script or style (the CSP)")
local js = read("lib/webui/listen.js")
assert(not js:find("innerHTML") and not js:find("eval%(") and not js:find("https?://[%w%[]") and not js:find("api/"), "listen.js: no HTML from strings, no eval, no other addresses, no studio API")
assert(js:find("'/listen/live%?l='") and js:find("'mix%?l='") and not js:find("ws%.send"), "it uses only the live socket and the mix, and sends nothing")
local idx = read("lib/webui/index.html")
assert(idx:find("audiencehost.js") and idx:find("tabs.js") < idx:find("audiencehost.js"), "index.html: the host's box after tabs.js")
local hj = read("lib/webui/audiencehost.js")
assert(not hj:find("innerHTML") and hj:find("confirm%(") and hj:find("sure: true"), "audiencehost.js: text only; public needs the warning confirmed")
print("ok audience")
