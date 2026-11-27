-- rt-ui1 (docs/rt/ui-web-plan.md Phase 1, the shell): the env topic's model and build (lib/webenv.lua: what this computer's REAPER has open
-- and is doing, loading included), the nav topic and its action (only a page on this computer opens a window here), webui's additive hooks,
-- and the page side read as text: the one label map (shell.js) with James's names, every tab and legacy page named in it, and index.html's
-- order and markup. The pages themselves run in tests/rt_ui1_browser.mjs. Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local clock, ext, docks, opened, playstate = 1000, {}, {}, {}, 0
local projects = { "P1", "P2" }
reaper = setmetatable({
  time_precise = function() return clock end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  EnumProjects = function(i) if i == -1 then return projects[1] end return projects[i + 1] end,
  GetProjectName = function(p) return p == "P1" and "Cross Test.rpp" or "scratch.rpp" end,
  GetPlayStateEx = function() return playstate end,
  GetPlayPositionEx = function() return 12.345 end,
  GetCursorPositionEx = function() return 3.21 end,
  CountTracks = function() return 24 end,
  GetCurrentProjectInLoadSave = function() return nil end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
band.log = function() end
band.open_url = function(u) opened[#opened + 1] = u end
band.info = function() return { name = "Chilio" } end
band.bands = function() return { { root = "C:/Chilio", name = "Chilio" }, { root = "C:/Other", name = "Other" } } end
package.loaded.groups = { role = function(root) return root == "C:/Chilio" and "owner" or "member" end, ai = function() return true end,
  sonobus_secret = function() return "" end }
package.loaded.persons = { of = function(_, u) return u == "James-Main" and "james" or u end }
local webenv = require("webenv")

-- ---- the model: only known fields, capped, flags true or left out -----------------------------------------------------------------------
do
  local tabs = {}
  for i = 1, 40 do tabs[i] = { name = "t" .. i, live = i == 1, front = i == 1 } end
  local m = webenv.model({ ver = "0.60.1", ext = "1.0.40", computer = "James-Main", user = "James-Main", person = "james", studio = "Chilio", ai = true,
    health = "purple", junk = "x", front = { name = string.rep("n", 500), project = "Cross Test", room = "main", shared = true, loading = false, live = true, tracks = 24.7, extra = 1 },
    tabs = tabs, transport = { playing = true, recording = false, pos = 12.345 }, studios = { { name = "Chilio", role = "owner" }, { role = "x" } } })
  assert(m.v == 1 and m.ver == "0.60.1" and m.ext == "1.0.40" and m.studio == "Chilio" and m.ai == true and m.junk == nil, "the known fields, nothing else")
  assert(m.health == nil, "a health level that isn't red or yellow is left out")
  assert(#m.front.name == webenv.NAME_MAX and m.front.project == "Cross Test" and m.front.loading == nil and m.front.live == true and m.front.extra == nil, "the front tab: capped, flags true or nil")
  assert(m.front.tracks == 24, "the track count whole")
  assert(#m.tabs == webenv.TABS_MAX and m.tabs[1].live == true and m.tabs[2].live == nil, "at most 32 tabs")
  assert(m.transport.playing == true and m.transport.recording == nil and m.transport.pos == 12.3, "the transport, the position to a tenth")
  assert(#m.studios == 1 and m.studios[1].role == "owner", "a studio with no name is left out")
  local e = webenv.model(nil)
  assert(e.v == 1 and e.front == nil and #e.tabs == 0 and e.transport == nil, "nothing given: an empty env, not an error")
  assert(webenv.model({ health = "red" }).health == "red" and webenv.model({ health = "yellow" }).health == "yellow", "red and yellow pass")
end

-- ---- built from REAPER: the front tab, every tab, the transport, loading, Health -----------------------------------------------------------
local cfg, b = { root = "C:/Chilio", user = "James-Main" }, { song = "Cross Test", room = "main" }
do
  ext["BandSync/menu extension"] = "1.0.40"
  ext["BandSync/live P1"] = tostring(clock)
  local m = webenv.build("P1", cfg, b, nil, "yellow")
  assert(m.front.name == "Cross Test.rpp" and m.front.project == "Cross Test" and m.front.studio == "Chilio" and m.front.shared and m.front.live, "the front tab")
  assert(m.front.loading == nil and m.front.tracks == 24, "not loading; its tracks")
  assert(#m.tabs == 2 and m.tabs[1].front and m.tabs[1].live and m.tabs[2].name == "scratch.rpp" and not m.tabs[2].live, "every open tab, Live sync's marked")
  assert(m.transport.pos == 3.2 and not m.transport.playing, "stopped: the edit cursor")
  assert(m.ext == "1.0.40" and m.user == "James-Main" and m.person == "james" and m.ai == true, "versions, who, the studio's AI")
  assert(m.health == "yellow", "Health's last level")
  assert(#m.studios == 2 and m.studios[1].role == "owner" and m.studios[2].role == "member", "your studios with your role in each")
  playstate = 5 -- (playing and recording)
  ext["BandSync/sync problem"] = "the shared folder went away"
  m = webenv.build("P1", cfg, b, { loading = true }, nil)
  assert(m.front.loading == true, "Live sync's loadguard holding the tab: loading")
  assert(m.transport.playing and m.transport.recording and m.transport.pos == 12.3, "recording: the play position")
  assert(m.health == "red", "a sync problem (the toolbar's amber) reads red, Health shown or not")
  ext["BandSync/sync problem"], playstate = nil, 0
  reaper.GetCurrentProjectInLoadSave = function() return "P2" end
  assert(webenv.build("P1", cfg, b).front.loading == true, "REAPER loading or saving any project: loading")
  reaper.GetCurrentProjectInLoadSave = function() return nil end
end

-- ---- at most once a second, only what changed ----------------------------------------------------------------------------------------------
do
  local sent = {}
  local publish = function(topic, t) sent[#sent + 1] = { topic, t } end
  webenv.tick("P1", cfg, b, publish, 2000)
  webenv.tick("P1", cfg, b, publish, 2000.5)
  webenv.tick("P1", cfg, b, publish, 2000.6, { loading = true })
  assert(#sent == 1 and sent[1][1] == "env", "once a second, loading or not")
  webenv.tick("P1", cfg, b, publish, 2001.1, { loading = true })
  assert(#sent == 2 and sent[2][2].front.loading, "a second later: again")
end

-- ---- nav: routes, the topic, the action -----------------------------------------------------------------------------------------------------
do
  assert(webenv.route("history", "playback") == "history/playback" and webenv.route("chat") == "chat" and webenv.route("chat", "") == "chat", "routes")
  assert(not webenv.route("nope") and not webenv.route("history", "../x") and not webenv.route("history", string.rep("a", 17)) and not webenv.route(nil), "only the nine, plain sub names")
  assert(webenv.nav_request("history", "playback", true) == true, "a REAPER action asks for a tab")
  local n = webenv.nav_topic()
  assert(n and n.page == "history" and n.sub == "playback" and n.wake == true and math.abs(n.at - os.time()) <= 1, "the topic says it")
  assert(type(n.id) == "string" and #n.id <= 32, "with an id the page acts on once")
  assert(webenv.nav_request("nope") == false, "an unknown page isn't asked for")
  assert(webenv.nav_model("{bad") == nil and webenv.nav_model('{"page":"x","at":1,"id":"a"}') == nil and webenv.nav_model('{"page":"chat","id":"a"}') == nil, "a bad one is nothing")
  reaper.StudioSync_WebUIDock = function(mode) docks[#docks + 1] = mode; return 1 end
  ext["BandSync/web nav"] = nil
  local said = webenv.nav_action({ to = "reaper", page = "chat" }, false, "http://127.0.0.1:47281/")
  assert(said and said:find("another device", 1, true) and #docks == 0 and ext["BandSync/web nav"] == nil, "a page on another device opens nothing here")
  assert(webenv.nav_action({ to = "reaper", page = "chat" }, true, "http://127.0.0.1:47281/") == nil and docks[1] == 1, "Open in REAPER: the docked view opens")
  assert(webenv.nav_topic().page == "chat", "and is told where to go")
  webenv.nav_action({ to = "browser", page = "history", sub = "playback" }, true, "http://127.0.0.1:47281/")
  assert(opened[1] == "http://127.0.0.1:47281/#history/playback", "Open in the browser: this computer's address, at the same page")
  assert(webenv.nav_action({ to = "browser", page = "../../x" }, true, "http://127.0.0.1:47281/") == nil and #opened == 1, "a bad page opens nothing")
end

-- ---- webui's hooks (additive) ---------------------------------------------------------------------------------------------------------------
local webui = require("webui")
assert(webui.ACTIONS.nav and webui.parse_action('{"topic":"nav","to":"reaper","page":"chat"}') == "nav", "nav is a topic the pages may send")
assert(type(webui.env_loading) == "function", "Live sync's loading hook")
local function read(p) local f = assert(io.open(p, "rb"), p); local s = f:read("a"); f:close(); return s end
local ui = read("lib/webui.lua")
assert(ui:find('require("webenv").tick(proj, cfg, b, publish, now', 1, true) and ui:find('publish("nav", nav)', 1, true), "the tick publishes env and nav")
assert(read("StudioSync - Live sync.lua"):find('require("webui").env_loading, proj, cfg, b)', 1, true), "Live sync says it's loading while its loadguard holds")

-- ---- the label map (shell.js) and the tabs (tabs.js) ----------------------------------------------------------------------------------------
local shell, tabsjs = read("lib/webui/shell.js"), read("lib/webui/tabs.js")
local function map(src, name)
  local body = assert(src:match("const " .. name .. " = (%b{})"), name)
  local m = {}
  for k, v in body:gmatch("'([^']+)':%s*'([^']*)'") do m[k] = v end
  return m
end
local LABELS, WORDS = map(shell, "LABELS"), map(shell, "WORDS")
local want = { studio = "Studio", session = "Session", project = "Project", chat = "Chat", history = "History", plugins = "Plug-ins", ai = "AI", health = "Health", settings = "Settings" }
for k, v in pairs(want) do assert(LABELS[k] == v, "the tab names James accepted: " .. k .. " = " .. tostring(LABELS[k])) end
assert(LABELS["history/playback"] == "Playback" and LABELS["session/play"] == "Play together" and LABELS["plugins/try"] == "Try a bandmate’s", "sub-tab names")
for k, v in pairs(LABELS) do assert(not v:find("Song") and not v:find("Home") and not v:lower():find("driver"), "no old word in a label: " .. k) end
assert(WORDS.driver == "In control" and WORDS.song == "Project" and WORDS.dismiss == "Hide" and WORDS["side room"] == "Room", "old words to new (2.2)")
local tabs_body = assert(tabsjs:match("const TABS = (%b[])"))
local n = 0
for name, subs in tabs_body:gmatch("%['(%a+)', %b[], (%b[])%]") do
  n = n + 1
  assert(LABELS[name], "every tab has its name: " .. name)
  for s in subs:gmatch("'(%a+)'") do assert(LABELS[name .. "/" .. s], "every sub-tab has its name: " .. name .. "/" .. s) end
end
assert(n == 9, "nine tabs: " .. n)
for old, route in assert(tabsjs:match("const LEGACY = (%b{})")):gmatch("(%a+): '([%a/]+)'") do
  assert(LABELS[route], "an older page lands on a named sub-tab: " .. old .. " -> " .. route)
  assert(tabs_body:find("'" .. route:match("/(%a+)$") .. "'", 1, true), "and one the tab lists: " .. route)
end
for _, f in ipairs({ "shell.js", "tabs.js" }) do
  local s = read("lib/webui/" .. f)
  assert(not s:find("innerHTML", 1, true) and not s:find("eval(", 1, true) and not s:find("https?://[%w]"), f .. ": no HTML from data, no eval, nothing from elsewhere")
end

-- ---- index.html ----------------------------------------------------------------------------------------------------------------------------
local html = read("lib/webui/index.html")
local function at(s) return assert(html:find(s, 1, true), s) end
assert(at('src="shell.js"') < at('src="tabs.js"') and at('src="tabs.js"') < at('src="app.js"') and at('src="app.js"') < at('src="daw.js"'), "shell, tabs, app, then the pages")
assert(at('href="shell.css"') > at('href="tryfx.css"'), "the shell's look last")
assert(html:find('<link rel="icon" href="icon.svg"', 1, true) and html:find('class="sslogo"', 1, true), "the StudioSync icon: favicon and logo")
assert(html:find('<main id="studiomain">', 1, true) and html:find('<main id="chatmain" hidden>', 1, true), "two mains: the studio overview's and the chat's")
assert(html:find('id="sstabs"', 1, true) and html:find('id="ssbar"', 1, true) and html:find('id="sspages"', 1, true), "the row, the phone's bar, the pages' place")
assert(not html:find("<script>", 1, true) and not html:find("style=", 1, true), "no inline script or style (the CSP)")
assert(read("lib/webui/icon.svg"):find("<svg", 1, true), "the icon is there")
print("ok")
