-- Settings in the web UI (rt-ui10b: docs/rt/ui-web-plan.md Phase 10b, 2.9; James's decisions 2026-11-27). Covers: every row of
-- lib/websettings.lua round-trips through its own module (set from the page, read back by the module's getter, and the topic shows it);
-- the REAPER window's focus rule writes ExtState "web ui focus" (strip by default, every one of James's options); a phone or another device
-- changes nothing (decision 4); Studio rows only for the owner and admins, Public links only for the owner and only with the warning
-- confirmed; values checked against their row (choices, numbers clamped, the call link by its module's check); Your computers and the phone
-- link from this computer only; the want / tick rhythm; webui.lua's hooks and index.html's script. No REAPER: a stand-in. Lupa, repo root.
package.path = "lib/?.lua;" .. package.path
local clock, ext = 1000, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetAppVersion = function() return "7.27/win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  HasExtState = function(s, k) return ext[s .. "/" .. k] ~= nil end,
  GetResourcePath = function() return "C:/res" end,
  RecursiveCreateDirectory = function() return 1 end,
  APIExists = function() return false end,
  CountMediaItems = function() return 0 end,
  GetNumAudioInputs = function() return 4 end,
  GetInputChannelName = function(i) return "In " .. (i + 1) end,
  CountTracks = function() return 2 end,
  GetTrack = function(_, i) return { i = i } end,
  GetTrackName = function(tr) return true, tr.i == 0 and "Guitar" or "Keys" end,
  GetSetMediaTrackInfo_String = function() return true, "" end,
  GetMediaTrackInfo_Value = function(tr, k) if k == "I_RECINPUT" then return tr.i == 0 and 0 or 4096 end; return tr.i == 0 and 1 or 0 end,
  GetSetProjectInfo_String = function() return true, "" end,
  genGuid = function() return "{0123ABCD-4567-89AB-CDEF-0123456789AB}" end,
}, { __index = function(_, k) return function() return "" end end })
local band = require("band")
local logged = {}
band.log = function(s) logged[#logged + 1] = s end
band.copy_atomic = function() end
band.info = function() return { name = "Chilio", id = "c1" } end
local synced = 0
band.sync_actions = function(dir) synced = synced + 1; assert(type(dir) == "string" and dir ~= "", "the scripts' folder for the Actions list"); return 7, 0 end

-- the studio's settings as band.json would hold them (lib/groups.lua's trusted settings), and who's who
local G, ROLE = {}, "owner"
package.loaded.groups = {
  role = function() return ROLE end,
  may_manage = function() return ROLE ~= "member" end,
  trusted = function() return G end,
  edit = function(_, f) f(G); return true end,
  ai = function() return G.ai == true end, set_ai = function(_, v) G.ai = v or nil end,
  live_audio = function() return G.live_audio ~= false end, set_live_audio = function(_, v) if v then G.live_audio = nil else G.live_audio = false end end,
  live_hub = function() return G.live_hub end, set_live_hub = function(_, n) G.live_hub = n end,
  set_direct = function(_, v) if v then G.direct = nil else G.direct = false end end,
  set_nat = function(_, v) G.nat = v or nil end,
  tailnet = function() return G.tailnet end,
  tailscale_only = function() return G.tailscale_only == true and G.tailnet ~= nil end, set_tailscale_only = function(_, v) G.tailscale_only = v or nil end,
  takes_to_lanes = function() return G.takes_to_lanes ~= false end, set_takes_to_lanes = function(_, v) if v then G.takes_to_lanes = nil else G.takes_to_lanes = false end end,
  set_print_hops = function(_, v) G.print_hops = v end,
  colour_parity = function() return G.colour_parity ~= false end, set_colour_parity = function(_, v) if v then G.colour_parity = nil else G.colour_parity = false end end,
  set_debug = function(_, v) G.debug = v or nil end,
  set_folder_updates = function(_, v) G.updates = v and "folder" or nil end,
}
local mine_calls = {}
package.loaded.persons = {
  computers = function() return { { user = "James-Laptop", state = "asks" }, { user = "James-Main", state = "this" } } end,
  set = function(root, user, on) mine_calls[#mine_calls + 1] = { user = user, on = on }; return user .. (on and " is yours" or " isn't") end,
}
package.loaded.services = { my_tailscale_name = function() return "james-main" end }
package.loaded.debugmode = setmetatable({ write = function() return "S/_debug/James-Main" end }, { __index = require("debugmode") })
local pub_calls = {}
require("audience").set_public = function(cfg, on, sure) pub_calls[#pub_calls + 1] = { on = on, sure = sure }; return "public " .. tostring(on) end
require("webui").phone_link = function() return "http://james-main:47281/?t=ab12" end

local ws = require("websettings")
local cfg, b = { root = "S", user = "James-Main" }, { song = "Cross Test", room = "main" }
local c = { proj = "P1", cfg = cfg, b = b }
local function row(id) for _, r in ipairs(ws.model(c, clock).rows) do if r.id == id then return r end end end
local function set(id, value, here, sure) return ws.action(c, { set = { id = id, value = value, sure = sure } }, here ~= false, clock) end
local function said() return ws.model(c, clock).said end

-- ---- 1. every row round-trips through its module ----------------------------------------------------------------------------------------
G.tailnet = { name = "Chilio", suffix = "chilio.ts.net" }
local modules = {
  -- id, a value to set, how its own module reads it back
  { "focus", "fade", function() return ext["BandSync/web ui focus"] end },
  { "button_size", 56, function() return ext["BandSync/web ui button size"] end, "56" },
  { "lock", true, function() return ext["BandSync/web ui lock"] end, "1" },
  { "ui_web", true, function() return ext["BandSync/ui"] end, "web" },
  { "toolbar_button", true, function() return require("tools").toolbar_button() end },
  { "parts_play", "sound", function() return require("prints").mode() end },
  { "stream_listen", "in_time", function() return require("streams").mode() end },
  { "stream_bars", 3, function() return require("streams").bars() end },
  { "record_wav", false, function() return require("streams").record_wav() end },
  { "live_set", true, function() return ext["BandSync/live set"] end, "on" },
  { "talk_input", 2, function() return (require("liveaudio").mine()) end },
  { "talk_stereo", true, function() return select(2, require("liveaudio").mine()) end, 2 },
  { "talk_kbps", 192, function() return select(3, require("liveaudio").mine()) end },
  { "phone_auto", false, function() return require("phonerec").auto_on() end },
  { "all_actions", true, function() return band.all_actions() end },
  { "show_advanced", true, function() return ext["BandSync/show advanced"] end, "1" },
  { "show_play", true, function() return ext["BandSync/show play"] end, "1" },
  { "ai", true, function() return require("groups").ai("S") end },
  { "live_audio", false, function() return require("groups").live_audio("S") end },
  { "direct", false, function() return require("direct").enabled("S") end },
  { "nat", true, function() return require("nat").enabled("S") end },
  { "tailscale_only", true, function() return require("groups").tailscale_only("S") end, nil, true },
  { "takes_to_lanes", false, function() return require("groups").takes_to_lanes("S") end },
  { "print_hops", "any", function() return G.print_hops end },
  { "colour_parity", false, function() return require("groups").colour_parity("S") end },
  { "alerts", true, function() return require("alerts").channel("S") ~= nil end },
  { "call", "https://discord.gg/abc", function() return require("alerts").call_link("S") end },
  { "debug", true, function() return require("debugmode").on("S") end },
  { "folder_updates", true, function() return require("fromfolder").on("S") end },
}
local covered = {}
for _, m in ipairs(modules) do
  local id, v, read, want, sure = m[1], m[2], m[3], m[4], m[5]
  covered[id] = true
  local words = set(id, v, true, sure)
  assert(words and not said().bad, id .. ": set from this computer's page (" .. tostring(words) .. ")")
  local got = read()
  if want ~= nil then assert(got == want, id .. ": its module reads " .. tostring(got) .. ", not " .. tostring(want))
  else assert(got == v, id .. ": its module reads " .. tostring(got) .. " after setting " .. tostring(v)) end
  local r = row(id)
  assert(r and r.value == v, id .. ": the topic shows " .. tostring(r and r.value) .. " after setting " .. tostring(v))
end
assert(synced == 1, "every action: REAPER's Actions list synced once")
assert(row("live_hub") == nil, "the hub's threshold shows only while live audio is on")
set("live_audio", true)
assert(set("live_hub", 6) and G.live_hub == 6 and row("live_hub").value == 6, "live hub: through groups.set_live_hub, read back by liveaudio.hub_from")
set("live_hub", 4)
assert(G.live_hub == nil, "the default threshold is written as nothing, as the panel does")
covered.live_hub, covered.debug_report, covered.public_links, covered.ablink = true, true, true, true
for _, r in ipairs(ws.ROWS) do assert(covered[r.id], "a row the round trip doesn't cover: " .. r.id) end
assert(set("debug_report", true) and said().text:match("_debug"), "Save a debug report now runs debugmode.write")

-- ---- 2. the focus rule (decision 2) -----------------------------------------------------------------------------------------------------
ext["BandSync/web ui focus"] = nil
assert(row("focus").value == "strip", "no setting: the strip (decision 2's default)")
ext["BandSync/web ui focus"] = "nonsense"
assert(row("focus").value == "strip", "an unknown value reads as the strip, as the window does")
local names = {}
for _, o in ipairs(row("focus").choices) do names[#names + 1] = o[1] end
assert(table.concat(names, ",") == "strip,button,stay,behind,fade", "James's options, strip first: " .. table.concat(names, ","))
for _, v in ipairs(names) do set("focus", v); assert(ext["BandSync/web ui focus"] == v, "the window's key gets " .. v) end
assert(not set("focus", "minimize") or said().bad, "a value outside the list is refused")
assert(ext["BandSync/web ui focus"] == "fade", "and nothing written")
assert(row("button_size").value == 56 and (function() ext["BandSync/web ui button size"] = "13"; return row("button_size").value == 28 end)(), "button size: 28 unless one of 22/28/40/56")

-- ---- 3. a phone or another device changes nothing (decision 4) --------------------------------------------------------------------------
local before = { ai = G.ai, focus = ext["BandSync/web ui focus"], wav = ext["BandSync/record wav"] }
set("ai", false, false)
assert(G.ai == before.ai and said().bad and said().text:match("only from this computer"), "a phone can't change a studio setting")
set("focus", "stay", false)
assert(ext["BandSync/web ui focus"] == before.focus and said().bad, "nor this computer's window")
set("record_wav", true, false)
assert(ext["BandSync/record wav"] == before.wav, "nor its recording format")
ws.action(c, { computer = { user = "James-Laptop", on = true } }, false, clock)
assert(#mine_calls == 0 and said().bad, "nor Your computers")
ws.action(c, { phone = true }, false, clock)
assert(ws.model(c, clock).phone == nil, "nor ask for the phone link")
set("public_links", true, false, true)
assert(#pub_calls == 0, "nor turn Public links on, even saying yes")

-- ---- 4. owner and admins ------------------------------------------------------------------------------------------------------------------
ROLE = "member"
set("ai", false)
assert(G.ai == true and said().bad and said().text:match("owner or an admin"), "a member can't change a studio setting")
assert(row("ai").may == nil and row("focus").may == true, "the topic says which rows a member may change")
set("focus", "button")
assert(ext["BandSync/web ui focus"] == "button", "a member changes this computer's own settings")
ROLE = "admin"
set("ai", false)
assert(G.ai == nil, "an admin changes studio settings")
set("public_links", true, true, true)
assert(#pub_calls == 0 and said().text:match("only the studio's owner"), "an admin can't turn Public links on")
assert(row("public_links").may == nil and row("ai").may == true, "the topic: Public links are the owner's")
ROLE = "owner"
set("public_links", true)
assert(#pub_calls == 0 and said().text:match("needs a yes"), "the owner without the warning confirmed: refused")
assert(row("public_links").confirm_on == require("audience").WARNING, "the page shows audience's own warning first")
set("public_links", true, true, true)
assert(#pub_calls == 1 and pub_calls[1].on == true and pub_calls[1].sure == true, "the owner, warning confirmed: audience.set_public")
set("public_links", false)
assert(#pub_calls == 2 and pub_calls[2].on == false, "turning it off needs no yes")
set("tailscale_only", false); set("tailscale_only", true)
assert(G.tailscale_only == nil and said().bad, "Sync only through Tailscale asks first too")
set("alerts", false)
assert(require("alerts").channel("S") ~= nil and said().bad, "phone alerts off asks first (a new channel next time)")
assert(row("alerts").note:match("studiosync%-"), "the channel to subscribe to shows")
set("alerts", false, true, true)
assert(require("alerts").channel("S") == nil, "and goes with a yes")

-- ---- 5. values checked against their row -------------------------------------------------------------------------------------------------
set("stream_bars", 99)
assert(require("streams").bars() == 16, "a number past its row's top: clamped")
set("talk_kbps", "12.7")
assert(select(3, require("liveaudio").mine()) == 64, "a number below: clamped to the row's floor")
local was = require("alerts").call_link("S")
set("call", "javascript:alert(1)")
assert(require("alerts").call_link("S") == was and said().bad, "the call link: only a plain https link (alerts.call_ok)")
set("call", ("https://x.y/" .. string.rep("a", 400)))
assert(said().bad, "a text past its limit: refused")
set("call", "")
assert(require("alerts").call_link("S") == nil, "an empty call link takes it away")
set("lock", "yes")
assert(said().bad and ext["BandSync/web ui lock"] == "1", "a switch takes only true or false")
set("talk_input", 9)
assert(said().bad and (require("liveaudio").mine()) == 2, "an input REAPER doesn't have: refused")
ws.action(c, { set = { id = "rm -rf", value = true } }, true, clock)
assert(said().bad and said().text:match("doesn't know"), "an unknown setting: refused")
ws.action(c, { set = "ai" }, true, clock)
assert(said().bad, "a set that isn't a table: refused")

-- ---- 6. the talk mic (findings: set the talk mic to the right input) ---------------------------------------------------------------------
set("talk_stereo", false); set("talk_input", 0)
local t = row("talk_input")
assert(#t.choices == 4 and t.choices[1][2]:match("Guitar %(armed%)"), "each input names the tracks recording from it")
assert(t.note and t.note:match("Guitar"), "the clash with an armed track is said")
assert(t.fix and t.fix.value == 1 and t.fix.label:match("In 2"), "and the first free input offered")
set("talk_input", t.fix.value)
assert((require("liveaudio").mine()) == 1 and row("talk_input").fix == nil, "pressing it moves the talk mic; nothing to fix then")

-- ---- 7. Devices: Your computers, the phone link --------------------------------------------------------------------------------------------
local m = ws.model(c, clock)
assert(#m.computers == 2 and m.tailnet == "james-main", "Your computers (lib/persons.lua) and this computer's Tailscale name")
ws.action(c, { computer = { user = "James-Laptop", on = true } }, true, clock)
assert(#mine_calls == 1 and mine_calls[1].on == true and said().text:match("yours"), "Mine too through persons.set")
assert(m.phone == nil, "no phone link until this computer's page asks")
ws.action(c, { phone = true }, true, clock)
assert(ws.model(c, clock).phone:match("^http://james%-main"), "asked: the phone link")
assert(ws.model(c, clock + ws.PHONE_FOR + 1).phone == nil, "and gone again a minute later")

-- ---- 8. built only while a page shows Settings ---------------------------------------------------------------------------------------------
ws._reset()
local sent = {}
local function pub(topic, v) sent[#sent + 1] = { topic, v } end
ws.tick(c, pub, clock)
assert(#sent == 0, "nobody showing Settings: nothing built")
ws.action(c, { want = true }, false, clock) -- (a phone may say it looks)
ws.tick(c, pub, clock)
assert(#sent == 1 and sent[1][1] == "settings" and sent[1][2].v == 1, "a page shows it: the topic")
ws.tick(c, pub, clock + 1)
assert(#sent == 1, "at most every " .. ws.EVERY .. " s")
ws.tick(c, pub, clock + ws.WANT_FOR + 1)
assert(#sent == 1, "and not after the page stopped saying so")
local okj = pcall(band.json_encode, ws.model(c, clock))
assert(okj, "the topic encodes as JSON")

-- ---- 9. webui.lua's hooks, index.html -------------------------------------------------------------------------------------------------------
local src = io.open("lib/webui.lua", "rb"):read("a")
assert(src:find('webui.ACTIONS.settings = true', 1, true), "the settings topic is an action")
assert(src:find('require("websettings").action', 1, true) and src:find("StudioSync_WebUIPollHere() == 1, reaper.time_precise())", 1, true), "dispatched with whether it's this computer's page")
assert(src:find('require("websettings").tick', 1, true), "built in the tick")
local html = io.open("lib/webui/index.html", "rb"):read("a")
local sp, tp, pp = html:find('<script src="settings.js"', 1, true), html:find('<script src="tabs.js"', 1, true), html:find('<script src="profile.js"', 1, true)
assert(sp and sp > tp and sp > pp, "settings.js loads after tabs.js and profile.js")
local js = io.open("lib/webui/settings.js", "rb"):read("a")
assert(not js:find("innerHTML", 1, true), "settings.js puts Live sync's words in as text only")
print("ok")
