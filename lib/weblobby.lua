-- The Studio tab's lobby (docs/rt/ui-web-plan.md 2.3, 2.4, 3.2; Phase 2, rt-ui2): your studios (start one, join one, switch to another), the
-- organising of a studio's projects (pins and archive per person, stage, folders), and the web UI with no studio project in front. James's
-- decision 9 (2026-11-27): Autostart answers the page then. Findings 2026-11-27 item 13 ("better project organisation") and "switching
-- studio without a project open".
--   With a studio project in front, Live sync's webui.tick runs lib/webhome.lua, whose tick publishes the "lobby" topic too and whose
--   action hands {topic = "home", lobby = {...}} here.
--   With none (no project, a project not in a studio, or Live sync not running for the front tab), Autostart calls weblobby.tick on every
--   pass: it starts the server, takes the page's actions through lib/webroute.lua, and publishes env (no project), presence (nobody: the
--   last Live sync's stays in the server otherwise), home (the studio's projects and what's new, lib/webhome.lua), profiles, invite, nav and
--   lobby. The two never poll at once: Autostart polls only while the front tab has no fresh Live sync heartbeat. (James, rt-ui2)
local band = require("band")
local weblobby = { EVERY = 1, STUDIOS_EVERY = 10, SAID_FOR = 20, PINS_MAX = 200, NAME_MAX = 120, FOLDER_MAX = 60, ROOMS_MAX = 12 }
weblobby.LOOK_GRACE = 30 -- seconds a page counts as looking after its last request (webui.LOOK_GRACE)
weblobby.HOLD = 30       -- after REAPER held every script (a gap over 10 s), Live sync's beat is old too: wait this long before taking over

local function str(s, max)
  if type(s) ~= "string" then return nil end
  s = s:gsub("%c", ""):match("^%s*(.-)%s*$")
  if s == "" or #s > (max or weblobby.NAME_MAX) then return nil end
  return s
end

-- ---- pins and archive: <root>/_band/pins/<user>.json, one writer (this computer, for its user), as the chat's own files ------------------
-- t: the file's table (or anything). -> { pins = { song }, archived = { song } }: strings only, no repeats, PINS_MAX each. Pure.
function weblobby.pins_clean(t)
  t = type(t) == "table" and t or {}
  local out = { pins = {}, archived = {} }
  for kind in pairs(out) do
    local seen = {}
    for _, s in ipairs(type(t[kind]) == "table" and t[kind] or {}) do
      s = str(s)
      if s and not seen[s] and #out[kind] < weblobby.PINS_MAX then seen[s] = true; out[kind][#out[kind] + 1] = s end
    end
  end
  return out
end
-- kind: "pins" or "archived"; on: put it in or take it out. -> a new cleaned table (t untouched), or nil for a bad ask. Pure.
function weblobby.pins_set(t, kind, song, on)
  song = str(song)
  if not song or (kind ~= "pins" and kind ~= "archived") then return nil end
  local c = weblobby.pins_clean(t)
  local keep = {}
  for _, s in ipairs(c[kind]) do if s ~= song then keep[#keep + 1] = s end end
  if on then table.insert(keep, 1, song) end -- (newest first; the oldest drop off at PINS_MAX)
  c[kind] = keep
  return weblobby.pins_clean(c)
end
function weblobby.pins_path(root, user)
  if type(root) ~= "string" or type(user) ~= "string" or user == "" or user:find("[%c/\\]") or user:find("..", 1, true) then return nil end
  return root .. "/_band/pins/" .. user .. ".json"
end
-- -> cleaned { pins, archived } for this person in this studio.
function weblobby.pins(cfg)
  local p = cfg and weblobby.pins_path(cfg.root, cfg.user)
  return weblobby.pins_clean(p and band.read_json(p))
end
local function save_pins(cfg, t)
  local p = weblobby.pins_path(cfg.root, cfg.user)
  if not p then return false end
  reaper.RecursiveCreateDirectory(cfg.root .. "/_band/pins", 0)
  band.write_json(p, { user = cfg.user, pins = t.pins, archived = t.archived, at = os.time() }) -- (written whole to a temp file, then moved in)
  return true
end

-- ---- folders: the panel's (lib/page_groups.lua): a project's own folder.json, and _band/folders/<name>.json for one with nothing in it yet --
function weblobby.folders(root, projects)
  local set = {}
  for _, f in ipairs(band.files(root .. "/_band/folders", ".json")) do set[f:sub(1, -6)] = true end
  for _, p in ipairs(projects or {}) do if (p.folder or "") ~= "" then set[p.folder] = true end end
  local names = {}
  for n in pairs(set) do names[#names + 1] = n end
  table.sort(names, function(a, z) return a:lower() < z:lower() end)
  return names
end
function weblobby.folder_of(cfg, song)
  local f = (band.read_json(band.song_dir(cfg, song) .. "/folder.json") or {}).folder
  return type(f) == "string" and f ~= "" and f or nil
end

-- ---- your studios ---------------------------------------------------------------------------------------------------------------------
-- The studios this computer is in and hasn't left (or had closed by its owner): the panel's live groups (lib/page_groups.lua).
local LS = nil -- (held 2 s: Live sync asks on Home's builds and actions, and each look reads every studio's folder)
function weblobby.live_studios()
  local now = reaper.time_precise()
  if LS and now >= LS.at and now - LS.at < 2 then return LS.list end
  local groups, list = require("groups"), {}
  for _, g in ipairs(band.bands()) do
    local okc, closed = pcall(function() return reaper.file_exists(g.root .. "/_band/closed.json") and groups.closed_ok(g.root) end)
    local oko, old = pcall(groups.is_old, g.root)
    if not (oko and old) and not (okc and closed) then list[#list + 1] = g end
  end
  LS = { at = now, list = list }
  return list
end
-- The studio the Studio tab shows: the one this computer works in ("sync_root", what the panel's Open on a studio sets), else the first one.
-- base: a cfg (Live sync's), or nil (Autostart: this computer's user from ExtState). -> { root, user } or nil (not set up, or no studio).
function weblobby.cfg(base, list)
  local user = base and base.user or reaper.GetExtState(band.SECTION, "user")
  if (user or "") == "" then return nil end
  list = list or weblobby.live_studios()
  local cur = reaper.GetExtState(band.SECTION, "sync_root")
  for _, g in ipairs(list) do if g.root == cur then return { root = g.root, user = user } end end
  if base and base.root then return { root = base.root, user = user } end
  return list[1] and { root = list[1].root, user = user } or nil
end
-- list: live studios ({ root, name, id, waiting }); cur: the root shown; info(root) -> { role, projects, people }; said: the last action's
-- words. -> the lobby topic: { me, current, studios = { { id, name, role, current, waiting, projects, people } }, said }. Pure.
function weblobby.model(list, cur, me, info, said)
  local out = { me = me, studios = {}, said = said }
  for _, g in ipairs(list or {}) do
    local i = info and info(g.root) or {}
    local s = { id = tostring(g.id or g.name), name = tostring(g.name or "?"), role = i.role, current = g.root == cur or nil, waiting = g.waiting or nil,
      projects = tonumber(i.projects), people = {} }
    for k, u in ipairs(type(i.people) == "table" and i.people or {}) do if k <= 12 and type(u) == "string" then s.people[#s.people + 1] = u end end
    if s.current then out.current = s.id end
    out.studios[#out.studios + 1] = s
  end
  return out
end
local info_memo = {} -- root -> { at, role, projects, people }
local function studio_info(root, user, now)
  local c = info_memo[root]
  if c and now - c.at < weblobby.STUDIOS_EVERY then return c end
  local names, seen = {}, {}
  for _, f in ipairs(band.files(root .. "/plugins", ".json")) do -- (every computer publishes its plug-in list: the studio's members, as the panel counts them)
    local p = band.read_json(root .. "/plugins/" .. f)
    if type(p) == "table" and type(p.user) == "string" and not seen[p.user] then seen[p.user] = true; names[#names + 1] = p.user end
  end
  table.sort(names)
  local okr, role = pcall(require("groups").role, root, user)
  c = { at = now, role = okr and role or nil, projects = #band.songs({ root = root }), people = names }
  info_memo[root] = c
  return c
end
local L = { said = nil }
function weblobby.build(cfg, now)
  local list = weblobby.live_studios()
  return weblobby.model(list, cfg and cfg.root, cfg and cfg.user, function(root) return studio_info(root, cfg.user, now) end,
    L.said and os.time() - L.said.at < weblobby.SAID_FOR and L.said or nil)
end

-- ---- what the page sends: { topic = "home", lobby = { ... } } -------------------------------------------------------------------------------
local function known_song(cfg, song)
  for _, s in ipairs(band.songs(cfg)) do if s == song then return true end end
  return false
end
local function run_script(name)
  local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]lib[/\\][^/\\]+$") or "."
  local id = reaper.AddRemoveReaScript(true, 0, dir .. "/" .. name, true)
  if not id or id <= 0 then return false end
  reaper.Main_OnCommand(id, 0)
  return true
end
-- cfg: the studio shown (weblobby.cfg); x: the lobby table; here: a page on this computer sent it (StudioSync_WebUIPollHere). Starting,
-- joining and sharing change this computer and may open REAPER's own boxes: this computer only. -> ok, words for the log and the page.
function weblobby.act(cfg, x, here)
  if type(x) ~= "table" or not cfg then return false, nil end
  if x.use ~= nil then -- (switch studio: the one this computer works in from now on, as the panel's Open on a studio card)
    for _, g in ipairs(weblobby.live_studios()) do
      if tostring(g.id) == x.use then band.use_band(g.root); return true, "working in " .. g.name .. " now (from the web page)" end
    end
    return false, "the web page asked for a studio this computer isn't in"
  end
  if x.start ~= nil or x.join ~= nil or x.share ~= nil then
    if not here then return false, "starting, joining or sharing a studio is done on the computer itself, not from another device" end
    local services = require("services")
    if (x.start ~= nil or x.join ~= nil) and services.ensure_syncthing() == "started" then return false, "Starting Syncthing: press it again in a few seconds" end
    if x.start ~= nil then
      local root, why = services.new_band(cfg, type(x.start) == "string" and x.start:sub(1, 200) or "")
      if not root then return false, tostring(why) end
      local okd, drive = pcall(require, "drive")
      local made = okd and drive.wanted() and drive.make(band.info(root).drive)
      return true, "started " .. band.info(root).name .. (made and (": made " .. band.info(root).drive .. " in your cloud drive too, share it with the others there") or "")
    end
    if x.join ~= nil then
      local code = type(x.join) == "string" and #x.join <= 8000 and services.parse_join(x.join)
      if not code then return false, "That isn't a join code: ask them to press Invite and send it again." end
      local root, why = services.join_band(cfg, code)
      if not root then return false, tostring(why) end
      local asking = code.invite and (why == "back" or not reaper.file_exists(root .. "/_band/band.json")) -- (the panel's: lib/page_groups.lua)
      if asking then require("joins").request(root, code.invite) end
      local name = band.info(root).name
      return true, (why == "already" and ("you're already in " .. name) or asking and ("joined " .. name .. ": the invitation asks their computer to let you in. Its projects arrive after that.")
        or ("joined " .. name .. ": ask whoever invited you to let you in. Its projects arrive after that."))
        .. (code.key and " Their invitation also signs you in to their Tailscale: paste it on the panel's Studios page for that." or "")
    end
    -- share: the front tab, into the studio shown (the panel's "Share <tab> with <studio>": Publish session asks the rest in REAPER)
    if band.binding(reaper.EnumProjects(-1)) then return false, "the project in front is shared already" end
    band.use_band(cfg.root)
    return run_script("StudioSync - Publish session.lua"), "sharing the project in front with " .. band.info(cfg.root).name .. ": REAPER asks the rest"
  end
  if x.newfolder ~= nil then -- (a folder with nothing in it yet: the panel's New folder)
    local to = str(band.clean(type(x.newfolder) == "string" and x.newfolder or ""), weblobby.FOLDER_MAX)
    if not to then return false, "a folder needs a short name" end
    reaper.RecursiveCreateDirectory(cfg.root .. "/_band/folders", 0)
    band.write_json(cfg.root .. "/_band/folders/" .. to .. ".json", { name = to })
    return true, "made the folder " .. to
  end
  local song = str(x.song)
  if not song or not known_song(cfg, song) then return false, "the web page named a project this studio doesn't have" end
  if x.pin ~= nil or x.archive ~= nil then
    local kind, on = "pins", x.pin == true
    if x.pin == nil then kind, on = "archived", x.archive == true end
    local t = weblobby.pins_set(weblobby.pins(cfg), kind, song, on)
    if not (t and save_pins(cfg, t)) then return false, "couldn't keep that" end
    return true, nil
  end
  if x.stage ~= nil then
    local extras, to = require("extras"), nil
    for _, s in ipairs(extras.STAGES) do if s == x.stage then to = s end end
    if x.stage ~= "" and not to then return false, "no such stage" end
    extras.set_stage(cfg.root, song, to, cfg.user)
    return true, song .. ": " .. (to or "no stage")
  end
  if x.folder ~= nil then -- ("": out of its folder; a new name is a new folder, listed from the project's own folder.json)
    local to = x.folder == "" and "" or str(band.clean(type(x.folder) == "string" and x.folder or ""), weblobby.FOLDER_MAX)
    if not to then return false, "a folder needs a short name" end
    require("chooser").set_folder(cfg, song, to)
    return true, song .. (to == "" and ": out of its folder" or (": in " .. to))
  end
  return false, nil
end
-- From webhome.action. -> words for the log.
function weblobby.action(cfg, x)
  local here = reaper.StudioSync_WebUIPollHere ~= nil and reaper.StudioSync_WebUIPollHere() == 1
  local ok, okv, said = pcall(weblobby.act, cfg, x, here)
  if not ok then okv, said = false, "the web page's studio change couldn't be made: " .. tostring(okv) end
  info_memo, LS = {}, nil
  if said then L.said = { ok = okv == true or nil, text = said, at = os.time() } end
  return said
end

-- ---- Autostart: the page with no studio project in front ----------------------------------------------------------------------------------
-- -> the env topic for the lobby: what REAPER has open, no project (the project tabs hide), no studio (Chat needs Live sync for now).
function weblobby.env(front)
  local webenv, tabs, i = require("webenv"), {}, 0
  while i < webenv.TABS_MAX do
    local p = reaper.EnumProjects(i)
    if not p then break end
    tabs[#tabs + 1] = { name = reaper.GetProjectName(p), live = band.live_here(p), front = p == front or nil }
    i = i + 1
  end
  local ps = reaper.GetPlayStateEx(front)
  local studios = {}
  local user = reaper.GetExtState(band.SECTION, "user")
  for _, g in ipairs(weblobby.live_studios()) do
    local okr, role = pcall(require("groups").role, g.root, user)
    studios[#studios + 1] = { name = g.name, role = okr and role or nil }
  end
  return webenv.model({ ver = band.VERSION, ext = reaper.GetExtState(band.SECTION, "menu extension"), computer = user, user = user,
    health = reaper.GetExtState(band.SECTION, "sync problem") ~= "" and "red" or nil,
    front = { name = reaper.GetProjectName(front), shared = band.binding(front) ~= nil, loading = require("loadguard").busy(), tracks = reaper.CountTracks(front) },
    tabs = tabs, transport = { playing = ps & 1 == 1, recording = ps & 4 == 4, paused = ps & 2 == 2 }, studios = studios })
end
local A = { last = nil, hold = -math.huge, on = false, at = -math.huge, published = {}, served = false, seen = -math.huge }
local function publish(topic, t)
  local s = band.json_encode(t)
  if A.published[topic] ~= s then A.published[topic] = s; reaper.StudioSync_WebUIPublish(topic, s) end
end
local function looking(now)
  local s = reaper.StudioSync_WebUIStatus() or ""
  local served = s:match('"served":(%d+)')
  if served ~= A.served then A.served, A.seen = served, now end
  return (tonumber(s:match('"clients":(%d+)')) or 0) > 0 or now - A.seen < weblobby.LOOK_GRACE
end
-- Does Autostart answer the page now? live: the front tab's Live sync beat is fresh (band.live_here(front, 30): Live sync clears it when it
-- stops); held: REAPER held every script a moment ago. Pure.
function weblobby.answers(live, held) return not live and not held end
-- Autostart's every pass (after its hidden-renderer check). Cheap when the extension has no web UI or Live sync answers.
function weblobby.tick()
  local webui = require("webui")
  if not webui.available() then return end
  local now = reaper.time_precise()
  if A.last and now - A.last > 10 then A.hold = now + weblobby.HOLD end
  A.last = now
  local front = reaper.EnumProjects(-1)
  local on = weblobby.answers(band.live_here(front, 30), now < A.hold)
  if on ~= A.on then A.on, A.published, A.at = on, {}, -math.huge; require("webroute").reset() end -- (Live sync published in between: all again)
  if not on then return end
  local cfg = weblobby.cfg(nil)
  if not (cfg and webui.start(cfg)) then return end
  local busy = require("loadguard").busy()
  local b = { room = "main" } -- (no project: lib/webhome.lua builds the studio's projects with none current)
  if not busy then -- (REAPER loading or saving: nothing opened or changed now, findings item 14; the actions wait in the queue)
    local route, url = require("webroute"), webui.local_url(webui.status().port)
    for _ = 1, 20 do
      local s = reaper.StudioSync_WebUIPoll()
      if s == nil or s == "" then break end
      local said = route.run(s, { proj = front, cfg = cfg, b = b, url = url })
      if said then band.log(said) end
    end
  end
  if now - A.at < weblobby.EVERY or not looking(now) then return end
  A.at = now
  publish("env", weblobby.env(front))
  publish("presence", { people = {}, claims = {} }) -- (nobody here: the last Live sync's stays in the server otherwise, and its project with it)
  local nav = require("webenv").nav_topic()
  if nav then publish("nav", nav) end
  if busy then return end
  require("webhome").tick(front, cfg, b, publish, now) -- (profiles, home and lobby)
  require("invite").web_tick(front, cfg, b, publish, now) -- (join requests for you, Ask... and Link on the project cards)
  require("websettings").tick({ proj = front, cfg = cfg, b = b }, publish, now) -- (Settings, while a page shows it; rt-uifix1)
end
function weblobby._reset() L, A, info_memo, LS = { said = nil }, { last = nil, hold = -math.huge, on = false, at = -math.huge, published = {}, served = false, seen = -math.huge }, {}, nil end

return weblobby
