-- Plug-ins in the web UI (Phase 10a of docs/rt/ui-web-plan.md; rt-ui10a): the panel's Plugins page and Settings > Extras as the Plug-ins tab's
-- subs (This project, Find a plug-in, Plug-in pack; Try a bandmate's stays lib/hoptry.lua's). The "plugins" topic is built from the panel's own
-- models (lib/page_plugins.lua: this project's plug-ins, who lacks each, the studio's stand-ins, drum maps; lib/plugins.lua: the folder of what
-- everyone has; lib/fxpick.lua: REAPER's categories; lib/pack.lua: the plug-in pack), only while a page says it shows one (every 10 s), and
-- published only when it changed. What the page sends runs the panel's own functions. Everything that changes the project, writes a file or
-- opens a REAPER window or an installer is refused unless the page is on this computer (StudioSync_WebUIPollHere): a phone or another device
-- sees the lists read only, as the panel would show them. GPL-3.0-or-later. (James, rt)
local band = require("band")
local webplugins = {}
webplugins.TOPIC = "plugins"
webplugins.WANT_FOR = 30  -- seconds a page counts as showing a Plug-ins sub after it last said so
webplugins.EVERY = 3      -- seconds between builds while one shows (the panel read this project's plug-ins every 3 s too)
webplugins.FIND_MAX = 200 -- rows Find a plug-in sends (the count says how many matched)
webplugins.PICK_MAX = 60  -- names the stand-in picker sends
webplugins.TEXT_MAX = 80  -- a search's length
webplugins.NAME_MAX = 64  -- a drum map's name

local S = { want = -math.huge, at = -math.huge, find = { q = "", cat = "All", only = true }, pick = nil, said = nil, folder = nil, fx = nil }

local function short(name) return (tostring(name or ""):gsub("^%w+:%s*", "")) end
local function clip(s, n) return type(s) == "string" and s:gsub("%c", " "):sub(1, n) or "" end

-- ---- the models (pure) --------------------------------------------------------------------------------------------------------------------
-- used: page_plugins.used's list; lists: { {user, set} } (each list's plug-in keys); tmap: page_plugins.translations. -> the rows This project
-- shows: each plug-in, its tracks, who lacks it (JSFX: everyone has them), the studio's stand-in and who set it.
function webplugins.project_model(used, lists, tmap)
  local out = {}
  for _, u in ipairs(used or {}) do
    local miss = {}
    for _, l in ipairs(lists or {}) do if not l.set[u.key] then miss[#miss + 1] = l.user end end
    local t = (tmap or {})[u.key]
    out[#out + 1] = { key = u.key, name = short(u.name), tracks = u.tracks, missing = miss,
      js = (u.key:find("%.jsfx?$") or tostring(u.name):match("^JS:")) and true or nil,
      standin = t and { to = short(t.to), by = type(t.by) == "string" and t.by or nil } or nil }
  end
  return out
end
-- items: fxpick.list's; f: { q, cat, only }. -> the rows Find shows (the first `max`) and how many matched. Pure.
function webplugins.find_rows(items, f, max)
  local fxpick = require("fxpick")
  local rows, n = {}, 0
  for _, it in ipairs(items or {}) do
    if fxpick.matches(it, f.q, f.cat, f.only) then
      n = n + 1
      if #rows < (max or webplugins.FIND_MAX) then rows[#rows + 1] = { key = it.key, label = it.label, cats = table.concat(it.cats, ", "), everyone = it.everyone or nil } end
    end
  end
  return rows, n
end
-- st: pack.status's; items: pack.ITEMS; linux: this is Linux. -> what Plug-in pack shows. Pure.
function webplugins.pack_model(st, items, linux)
  local lack, list = {}, {}
  for _, it in ipairs(items) do
    if st.others[it[1]] then lack[#lack + 1] = { name = it[1], who = st.others[it[1]] } end
    list[#list + 1] = { name = it[1], what = it[2], extras = it[4] or nil, here = st.here[it[1]] or nil,
      none = linux and it.linux == false or nil, alt = linux and type(it.linux) == "string" and it.linux or nil }
  end
  return { pack = st.pack, extras = st.extras, others = lack, items = list }
end
-- A drum map from a page: { name, notes = { sound = note } }. -> the clean name and notes (every kit sound, 0-127, General MIDI's where the page
-- sent none), or nil and why. Pure but for drummap's tables.
function webplugins.map_from(m)
  local dm = require("drummap")
  if type(m) ~= "table" or type(m.name) ~= "string" then return nil, "Give it the plug-in's name." end
  local name = band.clean(m.name:sub(1, webplugins.NAME_MAX))
  if name == "" or name:lower() == "gm" then return nil, "Give it the plug-in's name." end
  if band.reserved(name) then return nil, band.reserved(name) end
  local notes = {}
  for _, k in ipairs(dm.KIT) do
    local v = math.tointeger(tonumber(type(m.notes) == "table" and m.notes[k[1]] or nil))
    notes[k[1]] = v and math.max(0, math.min(127, v)) or dm.GM[k[1]]
  end
  return name, notes
end
-- The Try tab's asks a phone or another device may send: the knobs, the search, what it shows, and answering asks for your own plug-ins (the
-- toast on every page, rt-borrow). Anything else (trying one, Add to track, Print, Stop: they change this computer's project) is this computer's
-- page only. -> words for the log when refused, else nil. Pure.
local TRY_AWAY = { topic = true, want = true, q = true, set = true, knobs = true, allow = true, refuse = true, end_use = true }
function webplugins.try_refused(a, here)
  if here or type(a) ~= "table" then return nil end
  for k in pairs(a) do
    if not TRY_AWAY[k] then return "the web page's Try (" .. tostring(k) .. ") was refused: only from this computer's own page (it changes this computer's project)" end
  end
end

-- ---- built from the panel's models ------------------------------------------------------------------------------------------------------
local function map_names(cfg) -- (page_plugins' list: General MIDI first, then the studio's own maps)
  local names = { "gm" }
  for _, f in ipairs(band.files(cfg.root .. "/drummaps", ".json")) do if f ~= "gm.json" then names[#names + 1] = f:sub(1, -6) end end
  return names
end
local function sel_tracks(proj)
  local out = {}
  for i = 0, reaper.CountSelectedTracks(proj) - 1 do out[#out + 1] = reaper.GetSelectedTrack(proj, i) end
  return out
end
local function drums_model(proj, cfg)
  local dm = require("drummap")
  local kit = {}
  for _, k in ipairs(dm.KIT) do kit[#kit + 1] = { id = k[1], label = k[2], gm = dm.GM[k[1]] } end
  local d = { maps = map_names(cfg), kit = kit }
  local tr = sel_tracks(proj)
  d.n = #tr
  if tr[1] then
    d.track = select(2, reaper.GetTrackName(tr[1]))
    d.from, d.to = band.track_ext(tr[1], "band_drum_from"), band.track_ext(tr[1], "band_drum_to")
    if d.from ~= "" and d.to ~= "" then
      local t = d.from ~= d.to and dm.table(dm.load(cfg.root, d.from), dm.load(cfg.root, d.to))
      if t then d.moved = 0; for _ in pairs(t) do d.moved = d.moved + 1 end else d.same = true end
    end
  end
  return d
end
-- fxpick's list, every 30 s (REAPER's plug-in list is long, and only changes when REAPER restarts)
local function fx_items(cfg)
  if S.fx and reaper.time_precise() - S.fx.at < 30 and S.fx.root == cfg.root then return S.fx end
  local plugins, fxpick = require("plugins"), require("fxpick")
  local ok, set = pcall(plugins.band, cfg)
  local items = fxpick.list(plugins.installed(), band.read(reaper.GetResourcePath() .. "/reaper-fxtags.ini") or "", ok and set or {})
  local seen, cats = {}, {}
  for _, it in ipairs(items) do for _, c in ipairs(it.cats) do if not seen[c] then seen[c] = true; cats[#cats + 1] = c end end end
  table.sort(cats, function(a, z) if a == "Instruments" then return true elseif z == "Instruments" then return false end return a < z end)
  table.insert(cats, 1, "All")
  S.fx = { at = reaper.time_precise(), root = cfg.root, items = items, cats = cats }
  return S.fx
end
local function find_model(proj, cfg)
  local fx = fx_items(cfg)
  local target = reaper.GetSelectedTrack2(proj, 0, true)
  local master = target ~= nil and target == reaper.GetMasterTrack(proj)
  S.find.only, S.find.on_master = require("fxpick").only_for(master, S.find.on_master, S.find.only), master
  local rows, n = webplugins.find_rows(fx.items, S.find, webplugins.FIND_MAX)
  return { q = S.find.q, cat = S.find.cat, only = S.find.only, master = master or nil,
    target = master and "Master" or target and select(2, reaper.GetTrackName(target)) or nil, cats = fx.cats, rows = rows, shown = n }
end
local function pick_model()
  if not S.pick then return nil end
  local names, n, q = {}, 0, S.pick:lower()
  for _, p in ipairs(require("plugins").installed()) do
    if q == "" or p.name:lower():find(q, 1, true) then
      n = n + 1
      if #names < webplugins.PICK_MAX then names[#names + 1] = p.name end
    end
  end
  return { q = S.pick, names = names, total = n }
end

-- -> the topic.
function webplugins.model(proj, cfg)
  local pp, plugins, pack = require("page_plugins"), require("plugins"), require("pack")
  local lists = {}
  for _, l in ipairs(plugins.lists(cfg)) do
    local set = {}
    for _, k in ipairs(l.names) do set[k] = true end
    lists[#lists + 1] = { user = l.user, set = set }
  end
  local people = {}
  for _, l in ipairs(lists) do people[#people + 1] = l.user end
  return { project = webplugins.project_model(pp.used(proj), lists, pp.translations(cfg)), people = people, drums = drums_model(proj, cfg),
    folder = plugins.FOLDER, folder_info = S.folder, find = find_model(proj, cfg), pick = pick_model(),
    pack = webplugins.pack_model(pack.status(cfg), pack.ITEMS, band.LINUX), os = band.WIN and "win" or band.MAC and "mac" or "linux",
    said = S.said }
end

function webplugins.tick(proj, cfg, b, publish, now)
  if S.want <= now or now - S.at < webplugins.EVERY then return end
  S.at = now
  local ok, m = pcall(webplugins.model, proj, cfg)
  publish(webplugins.TOPIC, ok and m or { error = tostring(m) })
end

-- ---- what the page sends ----------------------------------------------------------------------------------------------------------------
local function tfile(cfg, key) return cfg.root .. "/plugins/translations/" .. require("mirror").hash(key) .. ".json" end -- (page_plugins' own path)
local function used_one(proj, key)
  for _, u in ipairs(require("page_plugins").used(proj)) do if u.key == key then return u end end
end
local function installed_name(name)
  for _, p in ipairs(require("plugins").installed()) do if p.name == name then return p.name end end
end
local function say(text) S.said = { text = text, at = os.time() }; return text end -- (the page shows it for a while)

-- a: {want}, {find = {q, cat, only}}, {pick = q}, and from this computer's page only: {apply}, {standin = {key, to}}, {unstandin = key},
-- {drum = {from, to}}, {map = {name, notes}}, {folder}, {get = "pack" | "extras"}, {add = key}. here: the page is on this computer.
-- -> words for the log, or nil.
function webplugins.action(proj, cfg, b, a, here)
  S.want, S.at = reaper.time_precise() + webplugins.WANT_FOR, -math.huge -- (what it asked for shows on the next tick)
  if type(a.find) == "table" then
    S.find.q = clip(a.find.q, webplugins.TEXT_MAX)
    if type(a.find.cat) == "string" then S.find.cat = clip(a.find.cat, webplugins.TEXT_MAX) end
    if type(a.find.only) == "boolean" then S.find.only = a.find.only end
  end
  if a.pick ~= nil then S.pick = clip(a.pick, webplugins.TEXT_MAX) end
  local what = a.apply and "Apply stand-ins here" or a.standin and "a stand-in" or a.unstandin and "removing a stand-in" or a.drum and "a drum map choice"
    or a.map and "Make a map" or a.folder and "Update the folder now" or a.get and "Get the plug-ins" or a.add and "Add" or nil
  if not what then return nil end
  if not here then return say("the web page's " .. what .. " was refused: only from this computer's own page (it changes this computer's project or files)") end
  local pp = require("page_plugins")
  if a.apply then
    return say(pp.apply_here(proj, cfg) .. " stand-in(s) added on this machine (only here: they never go to the others)")
  end
  if type(a.standin) == "table" then
    local u = type(a.standin.key) == "string" and used_one(proj, a.standin.key)
    local to = type(a.standin.to) == "string" and installed_name(a.standin.to)
    if not (u and to) then return say("not set: that plug-in isn't in this project, or the stand-in isn't installed here") end
    reaper.RecursiveCreateDirectory(cfg.root .. "/plugins/translations", 0)
    band.write_json(tfile(cfg, u.key), { key = u.key, from = u.name, to = to, by = cfg.user, time = os.date("!%Y-%m-%dT%H:%M:%SZ") })
    S.pick = nil
    return say("stand-in for " .. short(u.name) .. ": " .. short(to))
  end
  if type(a.unstandin) == "string" then
    local t = pp.translations(cfg)[a.unstandin]
    if not t then return say("no stand-in to remove for that plug-in") end
    local gone, why = os.remove(tfile(cfg, t.key))
    return say(gone and ("removed the stand-in for " .. short(t.from)) or ("couldn't remove the stand-in: " .. tostring(why)))
  end
  if type(a.drum) == "table" then
    local ok_name = {}
    for _, n in ipairs(map_names(cfg)) do ok_name[n] = true end
    local tr = sel_tracks(proj)
    if #tr == 0 then return say("Select a drum track first.") end
    local set = {}
    for k, ext in pairs({ from = "band_drum_from", to = "band_drum_to" }) do
      local v = a.drum[k]
      if v ~= nil then
        if type(v) ~= "string" or not (v == "" or ok_name[v]) then return say("no drum map called that") end
        set[ext] = v
      end
    end
    for _, t in ipairs(tr) do
      for ext, v in pairs(set) do band.set_track_ext(t, ext, v) end
      pp.apply_drum_track(t, cfg.root)
    end
    return say(string.format("drum maps set on %d track%s (here only)", #tr, #tr == 1 and "" or "s"))
  end
  if a.map then
    local name, notes = webplugins.map_from(a.map)
    if not name then return say(notes) end
    reaper.RecursiveCreateDirectory(cfg.root .. "/drummaps", 0)
    band.write_json(cfg.root .. "/drummaps/" .. name .. ".json", { name = name, notes = notes, by = cfg.user })
    return say("drum map saved: " .. name)
  end
  if a.folder then
    local plugins = require("plugins")
    local ok, n, why, members = pcall(function() plugins.publish(cfg); return plugins.update_folder(cfg) end)
    S.folder = not ok and ("Error: " .. tostring(n)) or n and string.format("%d plug-ins everyone has (lists from %s). Reopen the FX browser to see them.",
      n, table.concat(members or {}, ", ")) or why
    return say(S.folder)
  end
  if a.get == "pack" or a.get == "extras" then
    local ok, why = require("pack").get(a.get == "extras")
    return say(ok and ("The installer opened in its own window" .. (band.WIN and " (Windows asks for permission once)" or band.MAC and " (it may ask for your Mac password)" or "") ..
      ". When it's done, restart REAPER.") or why)
  end
  if type(a.add) == "string" then
    local it
    for _, x in ipairs(fx_items(cfg).items) do if x.key == a.add then it = x end end
    local tr = reaper.GetSelectedTrack2(proj, 0, true)
    if not it then return say("not added: that plug-in isn't on this computer") end
    if not tr then return say("Select a track first: Add puts the plug-in on it.") end
    local idx = reaper.TrackFX_AddByName(tr, it.name, false, -1)
    if idx < 0 then return say("not added: REAPER couldn't load " .. it.label) end
    reaper.TrackFX_Show(tr, idx, 3)
    return say(it.label .. " added to " .. select(2, reaper.GetTrackName(tr)))
  end
  return nil
end

function webplugins._reset() S = { want = -math.huge, at = -math.huge, find = { q = "", cat = "All", only = true } } end
return webplugins
