-- Public guest links (lib/guestweb.lua with lib/audience.lua's switch; rt-guestnet Phase 1, docs/rt/rt-guestnet.md): the link on Funnel's
-- port, who may make one (the owner only), the switch rules (one "Public links" switch: a public guest link needs it on; sessions 2 h at
-- most and never past the switch), the host's topic, and the ending: Public links off (the owner, or its hours run out) ends every public
-- guest and leaves tailnet guests alone. Plus a check of the pages: the owner's button and its warning as text, the guest page redeeming on
-- Join. The server's half (the public port's allow-list, POST redeem, cookies, caps): tests/webui_test.cpp and tests/audience_test.cpp.
package.path = "lib/?.lua;" .. package.path
local clock, link = 1000, 1.7e9
local ext, guests_set, public_set, ts_calls = {}, {}, {}, {}
local TMP = (os.getenv("TEMP") or "/tmp"):gsub("\\", "/")
local ext_status = { guests = {} }
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  StudioSync_WebUIPollHere = function() return 1 end, -- (a page on this computer; a phone is tried apart)
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  genGuid = function() return string.format("{%08X-1234-5678-9ABC-%012X}", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff)) end,
  CountTracks = function() return 0 end,
  GetCursorPositionEx = function() return 8 end,
  GetPlayStateEx = function() return 0 end,
  GetPlayPositionEx = function() return 8 end,
  Master_GetPlayRate = function() return 1 end,
  GetOutputLatency = function() return 0.01 end,
  GetAudioDeviceInfo = function(k) if k == "SRATE" then return true, "48000" end; return false, "" end,
  format_timestr_pos = function() return "5.1.00" end,
  EnumerateFiles = function() return nil end,
  StudioSync_DirectNow = function() return link end,
  StudioSync_WebUIGuest = function(gid, code, cs, ss) guests_set[#guests_set + 1] = { gid = gid, code = code, cs = cs, ss = ss }; return 1 end,
  StudioSync_WebUIGuestPublic = function(gid, on) public_set[#public_set + 1] = { gid = gid, on = on }; return 1 end,
  StudioSync_WebUISaveUpload = function() return 0 end,
  StudioSync_AudienceStart = function() return 1 end,
  StudioSync_AudienceLink = function() return 1 end,
  StudioSync_AudienceInfo = function() return 1 end,
  StudioSync_AudienceStatus = function() return "{}" end,
}, { __index = function(_, k) if k ~= "StudioSync_WebUIGuestPublic" then return function() return "" end end end }) -- (that one absent: an older extension)

local band = require("band")
local logged = {}
band.log = function(s) logged[#logged + 1] = s end
local real_time, toff = os.time, 0
os.time = function(t) if t then return real_time(t) end return real_time() + toff end
local role = "owner"
package.loaded.groups = { may_manage = function() return role ~= "member" end, role = function() return role end,
  smart_take_names = function() return false end, smart_lane_names = function() return false end }
package.loaded.services = { my_tailscale_name = function() return "james-main.tail99.ts.net." end, tailscale_exe = function() return "tailscale" end,
  ts_exec = function(args) ts_calls[#ts_calls + 1] = args; return "0\n" end }
package.loaded.webui = { status = function() return ext_status end, folder = function() return TMP end }
package.loaded.liveaudio = { status = function() return {} end, names = function() return {} end, name_of = function(p) return p end }
package.loaded.presence = { peers = function() return {} end }
package.loaded.recap = { names_on = function() return false end }
local gw = require("guestweb")
local au = require("audience")
require("phonerec").auto_on = function() return false end

-- ---- what a host page may send ----
assert(gw.parse_host({ make = { name = "Bo", public = true } }).make.public == true, "a public guest link asked for")
assert(gw.parse_host({ make = { name = "Bo", public = "yes" } }).make.public == nil and gw.parse_host({ make = { name = "Bo", public = 1 } }).make.public == nil,
  "only true itself asks for a public one")

-- ---- who may, and the switch ----
local cfg, b = { user = "James", root = TMP }, { song = "Song", room = "main" }
local pub = {}
local function publish(topic, t) pub[topic] = t end
role = "member"
assert(gw.action("P", cfg, b, { make = { name = "Bo", public = true } }):find("owner or an admin") and #guests_set == 0, "a member: no")
role = "admin"
assert(gw.action("P", cfg, b, { make = { name = "Bo", public = true } }):find("only the studio's owner") and #guests_set == 0, "an admin: no public guest link (tailnet ones only)")
role = "owner"
assert(gw.action("P", cfg, b, { make = { name = "Bo", public = true } }):find("needs Public links on first") and #guests_set == 0, "the owner, Public links off: no")
for _, a in ipairs(ts_calls) do assert(not a:find("funnel %-%-bg"), "a public guest link never turns Public links on by itself") end
local real_public = reaper.StudioSync_WebUIGuestPublic
assert(au.set_public(cfg, true, true):find("PUBLIC links are on for 6 hours") and au.public_on(), "the owner turns Public links on (warning confirmed)")
rawset(reaper, "StudioSync_WebUIGuestPublic", nil)
assert(gw.action("P", cfg, b, { make = { name = "Bo", public = true } }):find("extension is older") and #guests_set == 0, "an older extension: no public guest link")
reaper.StudioSync_WebUIGuestPublic = real_public

-- ---- a public guest link ----
local said = gw.action("P", cfg, b, { make = { name = "Bo", public = true } })
assert(said and said:find("PUBLIC") and said:find("without Tailscale") and #guests_set == 1, "made: " .. tostring(said))
local g1 = guests_set[1]
assert(g1.ss == gw.PUBLIC_SESSION and g1.cs == gw.CODE_LIFE and #g1.code == 24, "the session: 2 hours (not the tailnet's 4), the code's 30 minutes")
assert(#public_set == 1 and public_set[1].gid == g1.gid and public_set[1].on == 1, "the extension told it's public")
local kept = reaper.GetExtState(band.SECTION, gw.KEY)
assert(kept:find(g1.gid) and kept:find('"pub":true') and not kept:find(g1.code), "kept as public (never the code)")
clock = clock + 1
ext_status = { guests = { [g1.gid] = { redeemed = false, on = true, pub = true } } }
gw.tick("P", cfg, b, publish, clock)
local host = pub.guestweb
assert(host.owner and host.public_on and host.warning:find("public guest link") and host.warning:find("ends every public link and guest"),
  "the host's topic: the owner, Public links on, the one warning (covering guests)")
assert(host.guests[1].pub and host.guests[1].link == "https://james-main.tail99.ts.net:10000/guest.html?g=" .. g1.code, "the public guest: on Funnel's port 10000")
-- a tailnet guest alongside
toff = toff + 10
said = gw.action("P", cfg, b, { make = { name = "Cy" } })
local g2 = guests_set[2]
assert(said and #guests_set == 2 and g2.ss == gw.SESSION and #public_set == 1, "a tailnet guest: 4 hours, never marked public")
ext_status.guests[g2.gid] = { redeemed = false, on = true } -- (the extension knows both)
clock = clock + 1
gw.tick("P", cfg, b, publish, clock)
local cy
for _, g in ipairs(pub.guestweb.guests) do if g.gid == g2.gid then cy = g end end
assert(cy and not cy.pub and cy.link:find(":8443/guest.html"), "the tailnet one on the secure link's port")
-- shorter sessions, and never past the switch
toff = toff + 10
said = gw.action("P", cfg, b, { make = { name = "Di", minutes = 30, public = true } })
assert(guests_set[#guests_set].ss == 1800, "a public link asking 30 minutes: 30")
toff = toff + 10
gw.kick(guests_set[#guests_set].gid)
local p = band.ext_json(band.SECTION, au.PUB_KEY)
p["until"] = os.time() + 600
band.set_ext_json(band.SECTION, au.PUB_KEY, p, true)
gw.action("P", cfg, b, { make = { name = "Ed", public = true } })
assert(math.abs(guests_set[#guests_set].ss - 600) <= 1, "Public links off in 10 minutes: the session 10 minutes, never past them")
gw.kick(guests_set[#guests_set].gid)
p["until"] = os.time() + 30
band.set_ext_json(band.SECTION, au.PUB_KEY, p, true)
toff = toff + 10
local n0 = #guests_set
assert(gw.action("P", cfg, b, { make = { name = "Fi", public = true } }):find("within a minute") and #guests_set == n0, "under a minute left: refused")
p["until"] = os.time() + 3600
band.set_ext_json(band.SECTION, au.PUB_KEY, p, true)

-- ---- ending: Public links off ends public guests, not tailnet ones ----
n0 = #guests_set
said = au.action("P", cfg, b, { public = { on = false } })
local ended = {}
for i = n0 + 1, #guests_set do if guests_set[i].code == "" then ended[guests_set[i].gid] = true end end
assert(ended[g1.gid] and not ended[g2.gid], "the owner turns Public links off: the public guest ended at once (extension told), the tailnet one kept")
assert(said:find("1 public guest ended") and ts_calls[#ts_calls] == au.funnel_args(false), "said so; Funnel closed: " .. said)
kept = reaper.GetExtState(band.SECTION, gw.KEY)
assert(not kept:find(g1.gid) and kept:find(g2.gid), "the list: the public guest gone, the tailnet one there")
-- its hours run out
au.set_public(cfg, true, true)
toff = toff + 10
gw.action("P", cfg, b, { make = { name = "Gu", public = true } })
local g3 = guests_set[#guests_set]
p = band.ext_json(band.SECTION, au.PUB_KEY)
p["until"] = os.time() - 1
band.set_ext_json(band.SECTION, au.PUB_KEY, p, true)
n0 = #guests_set
clock = clock + 5
au.tick("P", cfg, b, publish, clock)
local gone = false
for i = n0 + 1, #guests_set do if guests_set[i].gid == g3.gid and guests_set[i].code == "" then gone = true end end
assert(gone and not reaper.GetExtState(band.SECTION, gw.KEY):find(g3.gid), "Public links' hours run out: the public guest ended too")
local found = false
for _, l in ipairs(logged) do if l:find("hours ran out") and l:find("public guest ended") then found = true end end
assert(found, "and logged")
-- a public guest link once more needs the switch again
toff = toff + 10
assert(gw.action("P", cfg, b, { make = { name = "Ho", public = true } }):find("needs Public links on first"), "off again: no public guest link")

-- ---- the pages ----
local function read(f) local h = assert(io.open(f, "rb")); local s = h:read("a"); h:close(); return s end
local hj = read("lib/webui/guesthost.js")
assert(hj:find("Public link (works without Tailscale)", 1, true) and hj:find("makeP.hidden = !t.owner", 1, true) and hj:find("public: true", 1, true),
  "guesthost.js: the owner's Public link button")
assert(hj:find("confirm((t.warning", 1, true) and hj:find("sure: true", 1, true) and not hj:find("innerHTML"), "with the switch's warning (text only) before it turns Public links on")
local gj = read("lib/webui/guest.js")
assert(gj:find("api/guest/redeem", 1, true) and gj:find("method: 'POST'", 1, true) and gj:find("if (S.code) conn(", 1, true),
  "guest.js: a public link's code is used on Join (POST), and its stream waits for that")
assert(not gj:find("innerHTML") and not gj:find("eval%("), "guest.js: still text only")

print("ok rt-guestnet: public guest links, the switch, owner only, ending")
