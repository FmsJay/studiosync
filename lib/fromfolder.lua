-- Updates through the studio's folder (James, 0.59.24: "make sure the chilio and smiley studios groups are set to update via the folder
-- since we'll be doing a lot of work and debugging through everyone... inviting someone to a studio with this setup should be part of
-- the invite... so no extra setup on collaborators' ends").
-- A studio's owner or an admin turns it on (band.json "updates": "folder", Settings > Studio). Then each computer in the studio runs
-- StudioSync from <studio>/_tools/studiosync: Autostart moves it there by itself, once all of that copy has arrived (band.files_complete)
-- and it's this version or newer. A new person installs as usual (ReaPack) and moves once they're let in and the folder has come, so the
-- invitation needs nothing more. An action of the copy it ran from before (a toolbar button, a menu, a key) hands over to the folder's
-- (fromfolder.handoff, at the top of each script), so old code never runs beside new. A copy run from a git checkout (a developer's) stays
-- where it is. The code guard still asks once on each computer for code that changed in the folder (band.code_guard).
local band = require("band")
local ff = {}

local function norm(p) return band.norm(p or ""):lower() end
local function version_of(dir) return (band.read(dir .. "/lib/band.lua") or ""):match('VERSION = "([^"]+)"') end
-- a is b or newer ("0.59.24" >= "0.59.9"). Pure.
function ff.at_least(a, b)
  local x, y = {}, {}
  for n in tostring(a):gmatch("%d+") do x[#x + 1] = tonumber(n) end
  for n in tostring(b):gmatch("%d+") do y[#y + 1] = tonumber(n) end
  for i = 1, math.max(#x, #y) do
    local p, q = x[i] or 0, y[i] or 0
    if p ~= q then return p > q end
  end
  return true
end
function ff.target(root) return band.norm(root) .. "/_tools/studiosync" end
function ff.on(root) return root and require("groups").trusted(root).updates == "folder" end
-- Is `dir` the copy in a studio that updates through its folder (its owner chose it)? Then a new version put there is taken without asking:
-- a studio sharing a folder trusts its members (James, 0.59.19), and Chilio's computer asked at every release. 0.59.32.
function ff.trusted_copy(dir)
  local root = band.norm(dir or ""):match("^(.*)/_tools/studiosync$")
  return root ~= nil and ff.on(root) == true
end
local function dev_copy(dir) return reaper.file_exists(band.norm(dir) .. "/.git/HEAD") or reaper.file_exists(band.norm(dir) .. "/.git") end

-- The studio this computer should run StudioSync from (the one in front first), or nil.
function ff.wanted(cfg)
  local list = {}
  if cfg and cfg.root then list[1] = cfg.root end
  for _, g in ipairs(band.bands()) do list[#list + 1] = g.root end
  for _, r in ipairs(list) do if ff.on(r) and reaper.file_exists(r .. "/_band/band.json") then return r end end
end

-- From Autostart: moves this computer to the studio's copy when it should. `dir`: where this copy runs from. -> the copy it moved to, or nil.
local looked = -math.huge
function ff.tick(dir, cfg)
  if reaper.time_precise() - looked < 60 then return end
  looked = reaper.time_precise()
  if dev_copy(dir) then return end
  local front = reaper.GetExtState(band.SECTION, "sync_root") -- (not band.settings: on a first run it asks for a name)
  cfg = cfg or (front ~= "" and { root = front } or nil)
  local root = ff.wanted(cfg)
  if not root then -- (no studio says so now: a copy this computer moved to that's gone is forgotten, and it runs where it is)
    local run = reaper.GetExtState(band.SECTION, "run from")
    if run ~= "" and not reaper.file_exists(run .. "/StudioSync - Autostart.lua") then reaper.DeleteExtState(band.SECTION, "run from", true) end
    return
  end
  local t = ff.target(root)
  if norm(dir) == norm(t) then
    if norm(reaper.GetExtState(band.SECTION, "run from")) ~= norm(t) then reaper.SetExtState(band.SECTION, "run from", t, true) end
    return
  end
  if not reaper.file_exists(t .. "/StudioSync - Autostart.lua") or not band.files_complete(t) then return end
  local v = version_of(t)
  if not v or not ff.at_least(v, band.VERSION) then return end
  local ok, why = require("tools").set_autostart(true, t, band.norm(dir)) -- (this copy, should that folder go)
  if not ok then band.log("couldn't move StudioSync to the studio's folder: " .. tostring(why)); return end
  pcall(band.sync_actions, t)
  reaper.SetExtState(band.SECTION, "update ok", v, true) -- (the studio's own choice: its copy, this version, said yes to here)
  reaper.SetExtState(band.SECTION, "run from", t, true)
  band.log("StudioSync runs from " .. tostring(band.info(root).name) .. "'s folder from REAPER's next start: updates put there reach this computer without asking")
  return t
end

-- The menu extension (extension/reaper_menu.cpp) from the copy StudioSync runs from, when it's newer than the one REAPER loaded: ReaPack
-- updates it only for a ReaPack install, so a computer running StudioSync from a studio's folder or a checkout kept an old one, and Health
-- said "older" for good (James's desktop and laptop: 1.0.5 against 1.0.6, 0.59.27). The loaded file is renamed, not overwritten (Windows
-- holds it; a Mac's loaded dylib mustn't change under it), and the new one goes in beside it: REAPER loads it at its next start.
-- -> true when it put one in.
local ext_done = false
function ff.extension_tick(dir)
  if ext_done then return end
  local have, want = reaper.GetExtState(band.SECTION, "menu extension"), require("tools").EXT_WANT
  if have == "" or band.compare_versions(have, want) >= 0 then return end
  local name = band.WIN and "reaper_studiosync-x64.dll" or band.MAC and "reaper_studiosync.dylib"
    or (reaper.GetOS():find("arm") or reaper.GetOS():find("aarch64")) and "reaper_studiosync-aarch64.so" or "reaper_studiosync-x86_64.so"
  local from, to = band.norm(dir) .. "/extension/" .. name, band.norm(reaper.GetResourcePath()) .. "/UserPlugins/" .. name
  local new = band.read(from)
  if not new or #new < 10000 then return end
  if band.read(to) == new then ext_done = true; return end -- (already in, waiting for REAPER's restart)
  ext_done = true
  local old = to .. ".old-" .. have
  os.remove(old)
  if reaper.file_exists(to) and not os.rename(to, old) then band.log("couldn't put the new menu extension in (" .. to .. " is held): restart REAPER and it tries again"); return end
  local ok, err = pcall(band.write_atomic, to, new)
  if not ok then os.rename(old, to); band.log("couldn't put the new menu extension in: " .. tostring(err)); return end
  band.log("StudioSync's menu extension " .. want .. " is in place of " .. have .. ": REAPER loads it when it next starts")
  return true
end

-- At the top of each StudioSync script: run from a copy this computer has moved away from (an old toolbar button or key), it starts the
-- same script in the copy it runs from now, and stops. `source`: debug.getinfo(1, "S").source. -> true when it handed over.
function ff.handoff(source)
  local run = reaper.GetExtState(band.SECTION, "run from")
  if run == "" then return false end
  local path = tostring(source or ""):gsub("^@", ""):gsub("\\", "/")
  local dir, file = path:match("^(.*)/(StudioSync %- [^/]+%.lua)$")
  if not dir or norm(dir) == norm(run) or dev_copy(dir) then return false end
  local there = band.norm(run) .. "/" .. file
  if not reaper.file_exists(there) then return false end
  local id = reaper.AddRemoveReaScript(true, 0, there, true)
  if id == 0 then return false end
  reaper.Main_OnCommand(id, 0)
  return true
end

return ff
