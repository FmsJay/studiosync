-- rt-ui2 (docs/rt/ui-web-plan.md Phase 2, the Studio tab and the lobby): the lobby's model (your studios), the studio shown, the pins file
-- (pins and archive per person, one writer), the organising actions (switch studio, stage, folder, new folder; start, join and share only on
-- this computer), the route rule (lib/webroute.lua: what runs with no project, what needs one, what's unknown, said once), and Autostart
-- answering the page with no Live sync in front (lib/weblobby.lua's tick: polls only then, publishes env with no project and an empty
-- presence, waits after REAPER held every script). Home's builds carry folders, pins and stages; its action hands the lobby on. The page
-- itself runs in tests/rt_ui2_browser.mjs. Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local clock, ext, polls, published, logs, scripts = 1000, {}, {}, {}, {}, {}
local front, here, status = "P1", 1, '{"listening":true,"port":47281,"clients":1,"served":3}'
reaper = setmetatable({
  time_precise = function() return clock end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  EnumProjects = function(i) if i == -1 or i == 0 then return front end end,
  GetProjectName = function() return "Untitled 3.rpp" end,
  GetPlayStateEx = function() return 0 end,
  CountTracks = function() return 2 end,
  GetProjExtState = function() return 0, "" end,
  GetCurrentProjectInLoadSave = function() return nil end,
  RecursiveCreateDirectory = function() return 1 end,
  file_exists = function() return false end,
  AddRemoveReaScript = function(_, _, path) scripts[#scripts + 1] = path; return 7 end,
  Main_OnCommand = function() end,
  StudioSync_WebUIStart = function() return 1 end,
  StudioSync_WebUIPublish = function(t, s) published[#published + 1] = { t, s } end,
  StudioSync_WebUIPoll = function() return table.remove(polls, 1) or "" end,
  StudioSync_WebUIPollHere = function() return here end,
  StudioSync_WebUIStatus = function() return status end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
band.log = function(t) logs[#logs + 1] = t end
local files = {} -- (the shared folder, in memory)
band.read_json = function(p) return files[p] end
band.write_json = function(p, t) files[p] = t end
band.files = function() return {} end
band.info = function(root) return { name = root == "C:/Chilio" and "Chilio" or "Other", id = root == "C:/Chilio" and "chilio-1" or "other-2" } end
local studios = { { root = "C:/Chilio", name = "Chilio", id = "chilio-1" }, { root = "C:/Other", name = "Other", id = "other-2", waiting = true } }
band.bands = function() return studios end
band.songs = function(cfg) return cfg.root == "C:/Chilio" and { "Cross Test", "Night Drive" } or { "Elsewhere" } end
local used = {}
band.use_band = function(root) used[#used + 1] = root; ext["BandSync/sync_root"] = root end
package.loaded.groups = { role = function(root) return root == "C:/Chilio" and "owner" or "member" end, is_old = function() return false end,
  closed_ok = function() return false end, sonobus_secret = function() return "" end, ai = function() return false end }
local stages = {}
package.loaded.extras = { STAGES = { "Idea", "Writing", "Tracking", "Mixing", "Done" }, set_stage = function(root, song, st) stages[root .. "/" .. song] = st or "(none)" end,
  stage = function() return nil end }
local foldered = {}
package.loaded.chooser = { set_folder = function(cfg, song, f) foldered[song] = f; return f end }
local started = {}
package.loaded.services = { ensure_syncthing = function() return true end,
  new_band = function(cfg, name) started[#started + 1] = name; return "C:/" .. name end,
  parse_join = function(t) return t:find("studiosync%-join") and { id = "X", band = "b", name = "Band" } or nil end,
  join_band = function() return "C:/Band", nil end }
package.loaded.drive = { wanted = function() return false end }
local weblobby, webroute = require("weblobby"), require("webroute")
ext["BandSync/user"], ext["BandSync/sync_root"] = "James-Main", "C:/Chilio"

-- ---- the pins file: pins and archive, per person, cleaned ---------------------------------------------------------------------------------
do
  local c = weblobby.pins_clean({ pins = { "A", "A", 3, "", "B", string.rep("x", 121), "  C  " }, archived = "nope", junk = 1 })
  assert(#c.pins == 3 and c.pins[1] == "A" and c.pins[2] == "B" and c.pins[3] == "C" and #c.archived == 0 and c.junk == nil, "strings only, trimmed, no repeats, nothing else")
  local big = { pins = {} }
  for i = 1, 300 do big.pins[i] = "p" .. i end
  assert(#weblobby.pins_clean(big).pins == weblobby.PINS_MAX, "at most PINS_MAX")
  local t = weblobby.pins_set({ pins = { "A" } }, "pins", "B", true)
  assert(t.pins[1] == "B" and t.pins[2] == "A", "the newest pin first")
  t = weblobby.pins_set(t, "pins", "A", false)
  assert(#t.pins == 1 and t.pins[1] == "B", "unpinned")
  assert(weblobby.pins_set(t, "pins", "B", true).pins[2] == nil, "pinned twice is once")
  assert(weblobby.pins_set(t, "stars", "B", true) == nil and weblobby.pins_set(t, "pins", 5, true) == nil, "a bad ask is nothing")
  assert(weblobby.pins_path("C:/Chilio", "James-Main") == "C:/Chilio/_band/pins/James-Main.json", "one small file per person")
  assert(not weblobby.pins_path("C:/Chilio", "../x") and not weblobby.pins_path("C:/Chilio", "a/b") and not weblobby.pins_path("C:/Chilio", ""), "never outside its folder")
end

-- ---- your studios: the lobby's model and the studio shown ---------------------------------------------------------------------------------
do
  local people = {}
  for i = 1, 20 do people[i] = "u" .. i end
  local m = weblobby.model(studios, "C:/Chilio", "James-Main", function(root) return root == "C:/Chilio" and { role = "owner", projects = 2, people = people } or {} end,
    { ok = true, text = "hi", at = 1 })
  assert(m.current == "chilio-1" and m.studios[1].current and m.studios[1].role == "owner" and m.studios[1].projects == 2, "the one shown, your role, its projects")
  assert(#m.studios[1].people == 12, "its people, 12 at most")
  assert(m.studios[2].current == nil and m.studios[2].waiting == true and m.said.text == "hi", "another, waiting to be let in; the last words")
  assert(#weblobby.model(nil, nil, "x").studios == 0, "no studios: an empty list")
  assert(weblobby.cfg(nil).root == "C:/Chilio" and weblobby.cfg(nil).user == "James-Main", "the studio this computer works in")
  ext["BandSync/sync_root"] = "C:/Gone"
  assert(weblobby.cfg({ root = "C:/Other", user = "James-Main" }).root == "C:/Other", "left or closed: the project's studio")
  assert(weblobby.cfg(nil).root == "C:/Chilio", "or the first one, with no project")
  ext["BandSync/user"] = ""
  assert(weblobby.cfg(nil) == nil, "not set up: nothing")
  ext["BandSync/user"], ext["BandSync/sync_root"] = "James-Main", "C:/Chilio"
  assert(weblobby.answers(false, false) and not weblobby.answers(true, false) and not weblobby.answers(false, true), "Autostart answers only with no fresh Live sync, not after a hold")
end

-- ---- what the page sends -------------------------------------------------------------------------------------------------------------------
local cfg = { root = "C:/Chilio", user = "James-Main" }
do
  assert(weblobby.action(cfg, { use = "other-2" }):find("working in Other", 1, true) and used[#used] == "C:/Other", "switch studio: the one this computer works in")
  assert(weblobby.action(cfg, { use = "nope" }):find("isn't in", 1, true), "a studio this computer isn't in: nothing")
  ext["BandSync/sync_root"] = "C:/Chilio"
  weblobby.action(cfg, { song = "Cross Test", pin = true })
  weblobby.action(cfg, { song = "Night Drive", archive = true })
  local f = files["C:/Chilio/_band/pins/James-Main.json"]
  assert(f and f.user == "James-Main" and f.pins[1] == "Cross Test" and f.archived[1] == "Night Drive" and tonumber(f.at), "the pins file: who, pins, archived, when")
  local p = weblobby.pins(cfg)
  assert(p.pins[1] == "Cross Test" and p.archived[1] == "Night Drive", "read back")
  weblobby.action(cfg, { song = "Cross Test", pin = false })
  assert(#weblobby.pins(cfg).pins == 0 and weblobby.pins(cfg).archived[1] == "Night Drive", "unpinned, still archived")
  assert(weblobby.action(cfg, { song = "Not Ours", pin = true }):find("doesn't have", 1, true), "only this studio's projects")
  weblobby.action(cfg, { song = "Cross Test", stage = "Mixing" })
  assert(stages["C:/Chilio/Cross Test"] == "Mixing", "a stage")
  assert(weblobby.action(cfg, { song = "Cross Test", stage = "Famous" }):find("no such stage", 1, true), "only the five stages")
  weblobby.action(cfg, { song = "Cross Test", stage = "" })
  assert(stages["C:/Chilio/Cross Test"] == "(none)", "or none")
  weblobby.action(cfg, { song = "Night Drive", folder = "Songs/../2026" })
  assert(foldered["Night Drive"] == "Songs2026", "into a folder, its name cleaned")
  weblobby.action(cfg, { song = "Night Drive", folder = "" })
  assert(foldered["Night Drive"] == "", "out of its folder")
  weblobby.action(cfg, { newfolder = "Sketches" })
  assert(files["C:/Chilio/_band/folders/Sketches.json"].name == "Sketches", "a new, empty folder: the panel's own file")
  here = 0
  for _, x in ipairs({ { start = "New Band" }, { join = "studiosync-join:X:b:Band" }, { share = true } }) do
    assert(weblobby.action(cfg, x):find("on the computer itself", 1, true), "start, join and share: not from another device")
  end
  assert(#started == 0, "nothing started")
  here = 1
  assert(weblobby.action(cfg, { start = "New Band" }):find("started", 1, true) and started[1] == "New Band", "Start a studio, on this computer")
  assert(weblobby.action(cfg, { join = "hello" }):find("isn't a join code", 1, true), "not a join code")
  assert(weblobby.action(cfg, { join = "studiosync-join:X:b:Band" }):find("joined", 1, true), "Paste a join code")
  local said = weblobby.action(cfg, { share = true })
  assert(said:find("sharing", 1, true) and scripts[#scripts]:find("Publish session", 1, true) and used[#used] == "C:/Chilio", "Share: Publish session, into the studio shown")
  local m = weblobby.build(cfg, clock)
  assert(m.said and m.said.text == said, "the page is told")
end

-- ---- the route rule ------------------------------------------------------------------------------------------------------------------------
do
  assert(webroute.rule("home", false) == "run" and webroute.rule("profile", false) == "run" and webroute.rule("invite", false) == "run" and webroute.rule("nav", false) == "run", "the Studio tab's topics run with no project")
  assert(webroute.rule("daw", false) == "project" and webroute.rule("chat", false) == "project" and webroute.rule("health", false) == "project", "a project's topics need one")
  assert(webroute.rule("daw", true) == "run", "with Live sync running they run")
  assert(webroute.rule("nope", false) == "unknown" and webroute.rule(nil, false) == "unknown" and webroute.rule(5, true) == "unknown", "anything else is unknown")
  local got = {}
  package.loaded.webhome = { action = function(_, c, b, a) got[#got + 1] = { "home", c.root, b.song, a.topic }; return "home did it" end, tick = function() end }
  package.loaded.invite = { action = function(_, _, _, a) got[#got + 1] = { "invite", a.ask and a.ask.to }; return nil end, web_tick = function() end }
  local c = { proj = "P1", cfg = cfg, b = { room = "main" }, url = "http://127.0.0.1:47281/" }
  assert(webroute.run('{"topic":"home","want":true}', c) == "home did it" and got[1][2] == "C:/Chilio" and got[1][3] == nil, "home: webhome's action, no project")
  webroute.run('{"topic":"invite","ask":{"to":"Bo"}}', c)
  assert(got[2][1] == "invite" and got[2][2] == "Bo", "invite: Ask..., Link and join requests work with no project")
  assert(webroute.run('{"topic":"health","want":true}', c):find("needs a studio project", 1, true), "a project's topic: said")
  assert(webroute.run('{"topic":"health","want":true}', c) == nil, "once")
  assert(webroute.run('{"topic":"zap"}', c):find("doesn't know", 1, true) and webroute.run('{"topic":"zap"}', c) == nil, "an unknown topic: said, once")
  assert(webroute.run('{"topic":"z<a>p!"}', c):find("z?a?p?", 1, true), "its name made plain in the log")
  assert(webroute.run("{bad", c):find("no topic", 1, true), "not JSON: unknown")
  webroute.reset()
  assert(webroute.run('{"topic":"health"}', c), "said again after Autostart takes over again")
  ext["BandSync/web nav"] = nil
  here = 0
  assert(webroute.run('{"topic":"nav","to":"reaper","page":"chat"}', c):find("another device", 1, true), "nav: a page on another device opens nothing")
  here = 1
end

-- ---- Autostart answering the page ------------------------------------------------------------------------------------------------------------
do
  local ticked = 0
  package.loaded.webhome.tick = function(_, c, b, publish) ticked = ticked + 1; publish("home", { studio = band.info(c.root).name, song = b.song }); publish("lobby", { me = c.user }) end
  weblobby._reset()
  webroute.reset()
  local function topics() local t = {}; for _, x in ipairs(published) do t[x[1]] = x[2] end; return t end
  -- a Live sync runs for the tab in front: Autostart leaves the page to it
  ext["BandSync/live P1"] = tostring(clock - 3)
  polls = { '{"topic":"home","want":true}' }
  weblobby.tick()
  assert(#polls == 1 and #published == 0, "Live sync answers: no poll, nothing published")
  -- it stops (and clears its beat): Autostart answers
  ext["BandSync/live P1"] = nil
  clock = clock + 0.1
  weblobby.tick()
  assert(#polls == 0, "the page's action taken")
  local t = topics()
  assert(t.env and t.presence and t.home and t.lobby, "env, presence, home and lobby published")
  local env = band.json_decode(t.env)
  assert(env.front and env.front.project == nil and not env.front.shared and env.front.name == "Untitled 3.rpp" and env.studio == nil, "env: what's in front, no project, not shared, no studio (Chat needs Live sync)")
  assert(#env.studios == 2 and env.studios[1].role == "owner", "your studios in env")
  assert(t.presence == '{"claims":[],"people":[]}', "presence: nobody (the last Live sync's project goes from the page)")
  local n = #published
  clock = clock + 0.2
  weblobby.tick()
  assert(#published == n, "once a second")
  clock = clock + 1
  weblobby.tick()
  assert(#published == n, "and only what changed")
  -- nobody looking: nothing built
  status = '{"listening":true,"port":47281,"clients":0,"served":3}'
  clock = clock + 40
  local was = ticked
  weblobby.tick()
  assert(ticked == was, "no page looking: no Home built")
  status = '{"listening":true,"port":47281,"clients":1,"served":4}'
  -- REAPER held every script (a gap over 10 s): Live sync's beat is old too, so Autostart waits
  clock = clock + 20
  polls = { '{"topic":"home","want":true}' }
  weblobby.tick()
  assert(#polls == 1, "after a hold: no poll for a while")
  for _ = 1, 7 do clock = clock + 5; weblobby.tick() end -- (Autostart's passes go on: each a few seconds apart, more than HOLD in all)
  assert(#polls == 0, "then it answers again")
  -- REAPER loading: actions wait in the queue, env says loading
  reaper.GetCurrentProjectInLoadSave = function() return "P1" end
  polls = { '{"topic":"home","want":true}' }
  clock = clock + 1.5
  published = {}
  weblobby.tick()
  assert(#polls == 1 and band.json_decode(topics().env).front.loading == true, "REAPER loading: the action waits, the page greys")
  reaper.GetCurrentProjectInLoadSave = function() return nil end
  polls = {}
end

-- ---- Home: the studio shown, its folders, pins and stages; the lobby action handed on ------------------------------------------------------------
do
  package.loaded.webhome = nil
  local webhome = require("webhome")
  local handed
  local real = weblobby.action
  weblobby.action = function(c, x) handed = { c.root, x }; return "done" end
  ext["BandSync/sync_root"] = "C:/Other"
  assert(webhome.action("P1", cfg, { song = "Cross Test", room = "main" }, { topic = "home", lobby = { use = "chilio-1" } }) == "done", "Home's action hands the lobby on")
  assert(handed[1] == "C:/Other" and handed[2].use == "chilio-1", "with the studio shown (the one this computer works in)")
  weblobby.action = real
  ext["BandSync/sync_root"] = "C:/Chilio"
end
local function read(p) local f = assert(io.open(p, "rb"), p); local s = f:read("a"); f:close(); return s end
do
  local src = read("lib/webhome.lua")
  assert(src:find("folders = weblobby.folders(cfg.root, projects), stages = extras.STAGES", 1, true), "Home's build: the studio's folders and the stages")
  assert(src:find("folder = weblobby.folder_of(cfg, song), pinned = pinned[song], archived = archived[song]", 1, true), "each project's folder, pin and archive")
  assert(src:find('publish("lobby"', 1, true), "Home's tick publishes the lobby too (Live sync's)")
  local auto = read("StudioSync - Autostart.lua")
  local a, gate, r, ok = auto:find('band.try("weblobby.tick"', 1, true), auto:find("if reaper.time_precise() - at < 2 then return end", 1, true),
    auto:find("bandsync-render", 1, true), auto:find("lobby_ok = true", 1, true)
  assert(a and gate and a < gate, "Autostart answers the page on every pass, before its 2 s look")
  assert(r and ok and ok > r, "and only once it knows it isn't the hidden renderer")
  local inv = read("lib/webui/invite.js")
  assert(inv:find("li.querySelector('.hpinv')", 1, true), "invite.js puts Ask... and Link in the card's place for them")
  local home = read("lib/webui/home.js")
  assert(home:find("'hpinv'", 1, true) and home:find("lobby: x", 1, true), "home.js: the place, and the lobby actions under the home topic")
  for _, f in ipairs({ "lib/webui/home.js" }) do
    assert(not read(f):find("innerHTML", 1, true) and not read(f):find("eval(", 1, true), f .. ": no HTML from data, no eval")
  end
end
print("ok")
