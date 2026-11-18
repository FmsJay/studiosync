-- StudioSync cross-computer test (0.58.96). Run inside REAPER on each computer of a studio at about the same time: the desktop (A, it
-- shares the test project), the laptop (B) and the Mac (C). Each does its steps on the real project through the real Live sync, waits
-- for the others' changes to arrive, and writes what it saw to <studio>/_crosstest/<run>/, which Syncthing carries like everything else.
-- A writes summary.md there at the end. Roles by StudioSync name (CROSS_ROLES below), or set CROSS_ROLE before dofile.
--
-- Start: Actions > Show action list > New action > Load ReaScript > this file, then run it (the desktop first: it makes the run).
-- One that isn't started within 3 minutes is left out (its steps skipped) and the rest goes on.
local here = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
local lib = here:gsub("[/\\]tests[/\\]cross$", "") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
local band = require("band")

local STUDIO, SONG = CROSS_STUDIO or "Smiley Studios", CROSS_SONG or "Cross Test"
local ROLES = CROSS_ROLES or { ["James"] = "A", ["James-Laptop"] = "B", ["Chilio-Mac"] = "C" }
local WAIT, JOIN = 120, CROSS_JOIN or 180 -- seconds a change has to arrive in; seconds to wait for the others to start (CROSS_JOIN: longer)
local cfg = band.settings()
if not cfg then return "StudioSync isn't set up here" end
local role = CROSS_ROLE or ROLES[cfg.user]
if not role then return "no role for '" .. tostring(cfg.user) .. "': set CROSS_ROLE (A, B or C)" end
local root
for _, g in ipairs(band.bands()) do if g.name == STUDIO then root = g.root end end
if not root then return "this computer isn't in '" .. STUDIO .. "'" end
local base = root .. "/_crosstest"
local function utc() return os.date("!%Y-%m-%dT%H:%M:%SZ") end
local function now() return reaper.time_precise() end
local log = {}
local function say(s) log[#log + 1] = os.date("!%H:%M:%S ") .. s; reaper.ShowConsoleMsg("[cross " .. role .. "] " .. s .. "\n") end

-- the project tab: bound to the test song in this studio. A makes and shares it when it isn't there; B and C open it from the studio.
local function find_proj()
  for i = 0, math.huge do
    local p = reaper.EnumProjects(i)
    if not p then return nil end
    local b = band.binding(p)
    if b and b.song == SONG and band.same_studio(b.root, root) then return p end
  end
end
local function run_script(name)
  local id = reaper.AddRemoveReaScript(true, 0, (lib:gsub("/lib/$", "")) .. "/" .. name, true)
  if id > 0 then reaper.Main_OnCommand(id, 0) end
end
local function share_or_open()
  band.use_band(root)
  if role == "A" then
    if band.read_json(band.session_path({ root = root, user = cfg.user }, SONG)) then
      reaper.SetExtState(band.SECTION, "open project", SONG .. "|main", false); run_script("StudioSync - Open session.lua")
    else
      reaper.Main_OnCommand(40859, 0) -- a new tab
      local p = reaper.EnumProjects(-1)
      reaper.SetExtState(band.SECTION, "prepared " .. tostring(p), "1", false) -- (an empty tab has nothing to prepare)
      reaper.SetExtState(band.SECTION, "publish as", SONG, false)
      run_script("StudioSync - Publish session.lua")
      reaper.DeleteExtState(band.SECTION, "publish as", false)
    end
  else
    reaper.SetExtState(band.SECTION, "open project", SONG .. "|main", false); run_script("StudioSync - Open session.lua")
  end
end

-- what everyone should agree on: tracks by name (this computer's own "(yours, not sent)" ones aside), their items, and the tempo
local function shape(p)
  local t = { tempo = math.floor(reaper.TimeMap2_GetDividedBpmAtTime(p, 0) * 100 + 0.5) / 100, tracks = {} }
  for i = 0, reaper.CountTracks(p) - 1 do
    local tr = reaper.GetTrack(p, i)
    local name = select(2, reaper.GetTrackName(tr))
    if not name:find("(yours, not sent)", 1, true) then
      local items = {}
      for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, j)
        items[#items + 1] = string.format("%.2f+%.2f", reaper.GetMediaItemInfo_Value(it, "D_POSITION"), reaper.GetMediaItemInfo_Value(it, "D_LENGTH"))
      end
      table.sort(items)
      t.tracks[#t.tracks + 1] = name .. " [" .. table.concat(items, " ") .. "]"
    end
  end
  table.sort(t.tracks)
  return t
end
local function track(p, name)
  for i = 0, reaper.CountTracks(p) - 1 do
    local tr = reaper.GetTrack(p, i)
    if select(2, reaper.GetTrackName(tr)) == name then return tr end
  end
end
local function add_part(p, name, at)
  reaper.Undo_BeginBlock2(p)
  reaper.InsertTrackAtIndex(reaper.CountTracks(p), true)
  local tr = reaper.GetTrack(p, reaper.CountTracks(p) - 1)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  local it = reaper.CreateNewMIDIItemInProj(tr, at, at + 4, false)
  local tk = it and reaper.GetActiveTake(it)
  if tk then reaper.MIDI_InsertNote(tk, false, false, 0, 960, 0, 48, 100, false) end
  reaper.Undo_EndBlock2(p, "Cross test: " .. name, -1)
  reaper.UpdateArrange()
end
local function first_item(p, name)
  local tr = track(p, name)
  return tr and reaper.GetTrackMediaItem(tr, 0)
end

-- The steps: who acts, what they do, and what everyone else waits to see. (A step whose actor isn't here is skipped by all.)
local STEPS = {
  { "A adds a track and a part", "A", function(p) add_part(p, "XT Drums A", 0) end,
    function(p) local it = first_item(p, "XT Drums A"); return it and math.abs(reaper.GetMediaItemInfo_Value(it, "D_POSITION")) < 0.01 end },
  { "B adds a track and a part", "B", function(p) add_part(p, "XT Bass B", 4) end, function(p) return first_item(p, "XT Bass B") ~= nil end },
  { "C adds a track and a part", "C", function(p) add_part(p, "XT Keys C", 8) end, function(p) return first_item(p, "XT Keys C") ~= nil end },
  { "C changes the tempo to 100", "C", function(p) reaper.SetCurrentBPM(p, 100, true) end,
    function(p) return math.abs(reaper.TimeMap2_GetDividedBpmAtTime(p, 0) - 100) < 0.01 end },
  { "A changes it to 120 right after (the newest map wins everywhere)", "A", function(p) reaper.SetCurrentBPM(p, 120, true) end,
    function(p) return math.abs(reaper.TimeMap2_GetDividedBpmAtTime(p, 0) - 120) < 0.01 end },
  { "B moves A's part to bar 2", "B", function(p)
      local it = first_item(p, "XT Drums A")
      if it then reaper.Undo_BeginBlock2(p); reaper.SetMediaItemInfo_Value(it, "D_POSITION", 2); reaper.Undo_EndBlock2(p, "Cross test: move", -1); reaper.UpdateArrange() end
    end, function(p) local it = first_item(p, "XT Drums A"); return it and math.abs(reaper.GetMediaItemInfo_Value(it, "D_POSITION") - 2) < 0.01 end },
  { "A deletes B's track", "A", function(p)
      local tr = track(p, "XT Bass B")
      if tr then reaper.Undo_BeginBlock2(p); reaper.DeleteTrack(tr); reaper.Undo_EndBlock2(p, "Cross test: delete", -1) end
    end, function(p) return track(p, "XT Bass B") == nil end },
}

local run, here_roles, results, step, phase, t0, p, started, opened, wrote = nil, {}, {}, 0, "start", now(), nil, now(), false, false
local function file(name) return base .. "/" .. run .. "/" .. name .. ".json" end
local function have(name) return band.read_json(file(name)) end
local function put(name, t) reaper.RecursiveCreateDirectory(base .. "/" .. run, 0); band.write_json(file(name), t) end
local function newest_run()
  local best
  for i = 0, math.huge do
    local d = reaper.EnumerateSubdirectories(base, i)
    if not d then break end
    if d:match("^%d+%-%d+Z$") and (not best or d > best) then best = d end
  end
  return best
end

local function summary()
  local lines = { "# Cross test " .. run, "", "Computers: " .. table.concat(here_roles, ", "), "" }
  local fails = 0
  for i, s in ipairs(STEPS) do
    local row = { ("%d. %s:"):format(i, s[1]) }
    for _, r in ipairs({ "A", "B", "C" }) do
      local seen = have(r .. "-step" .. i)
      if seen then
        row[#row + 1] = r .. " " .. (seen.skipped and "skipped" or seen.acted and "did it" or seen.ok and ("saw it in " .. seen.secs .. " s") or ("NOT SEEN in " .. WAIT .. " s"))
        if not seen.ok and not seen.skipped and not seen.acted then fails = fails + 1 end
      end
    end
    lines[#lines + 1] = table.concat(row, " ")
  end
  local shapes, same = {}, true
  for _, r in ipairs(here_roles) do
    local f = have(r .. "-final")
    shapes[r] = f and band.json_encode(f.shape) or "(none)"
    if shapes[r] ~= shapes[here_roles[1]] then same = false end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = same and "Final project: the same on every computer." or "Final project DIFFERS:"
  for _, r in ipairs(here_roles) do lines[#lines + 1] = "- " .. r .. ": " .. shapes[r] end
  for _, r in ipairs(here_roles) do
    local h = have(r .. "-hello")
    if h then lines[#lines + 1] = ("- %s is %s, StudioSync %s, REAPER %s, %s"):format(r, h.user, h.version, h.reaper, h.os) end
  end
  if not same then fails = fails + 1 end
  lines[#lines + 1] = ""
  lines[#lines + 1] = fails == 0 and "RESULT: PASS" or ("RESULT: " .. fails .. " FAILED")
  local f = io.open(base .. "/" .. run .. "/summary.md", "wb")
  if f then f:write(table.concat(lines, "\n") .. "\n"); f:close() end
  say(fails == 0 and "PASS: summary.md written" or (fails .. " failed: summary.md written"))
end

local function tick()
  local t = now()
  if phase == "start" then
    if role == "A" then run = os.date("!%Y%m%d-%H%M%SZ") else run = newest_run() end
    if run then
      -- (B and C take the newest run, made in the last half hour: an old one is someone else's)
      local y, mo, d, h, mi, s = run:match("^(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)Z$")
      local age = os.time(os.date("!*t")) - os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
      if role ~= "A" and age > 1800 then run = nil end
    end
    if run then
      p = find_proj()
      if not p and role == "A" then share_or_open(); p = find_proj() end
      put(role .. "-hello", { user = cfg.user, version = band.VERSION, reaper = reaper.GetAppVersion(), os = reaper.GetOS(), at = utc() })
      say("run " .. run .. ", as " .. role .. (p and "" or ": waiting for the project to open"))
      phase, t0 = "join", t
    elseif t - started > JOIN then say("no run from A in " .. JOIN .. " s: start it on the desktop first"); return
    end
  elseif phase == "join" then
    p = p and reaper.ValidatePtr2(0, p, "ReaProject*") and p or find_proj()
    -- (B and C open it once it has reached them: before, Open session says it can't read the project, in a box)
    if not p and not opened and band.read_json(band.session_path({ root = root, user = cfg.user }, SONG)) then opened = true; share_or_open(); p = find_proj() end
    here_roles = {}
    for _, r in ipairs({ "A", "B", "C" }) do if have(r .. "-hello") then here_roles[#here_roles + 1] = r end end
    -- (A decides who's in and writes it; the others start once they have that, so everyone skips the same steps)
    local roster = role ~= "A" and have("A-roster")
    if p and ((role == "A" and (#here_roles == 3 or t - t0 > JOIN)) or roster) then
      if roster then here_roles = roster.roles end
      reaper.SelectProjectInstance(p)
      say("starting with " .. table.concat(here_roles, ", "))
      put(role .. "-roster", { roles = here_roles })
      phase, step = "step", 1
      t0 = t
    end
  elseif phase == "step" then
    local s = STEPS[step]
    if not s then phase = "final"; t0 = t; return reaper.defer(tick) end
    local present = false
    -- (who's in: A's roster decides, so everyone skips the same steps)
    local roster = have("A-roster")
    for _, r in ipairs(roster and roster.roles or here_roles) do present = present or r == s[2] end
    local mine = have(role .. "-step" .. step)
    if not mine then
      if not present then put(role .. "-step" .. step, { skipped = true }); say(s[1] .. ": skipped (" .. s[2] .. " isn't here)")
      elseif s[2] == role then
        s[3](p); put(role .. "-step" .. step, { acted = true, ok = true, at = utc() }); say(s[1] .. ": done")
      elseif have(s[2] .. "-step" .. step) then -- (counted from when the actor says it acted)
        results[step] = results[step] or t
        if s[4](p) then put(role .. "-step" .. step, { ok = true, secs = math.floor(t - results[step] + 0.5) }); say(s[1] .. ": arrived")
        elseif t - results[step] > WAIT then put(role .. "-step" .. step, { ok = false }); say(s[1] .. ": NOT arrived in " .. WAIT .. " s") end
      end
    else -- everyone's in for this step (or the wait ran out): the next one
      local all = true
      for _, r in ipairs(roster and roster.roles or here_roles) do all = all and have(r .. "-step" .. step) ~= nil end
      if all or t - t0 > WAIT + 30 then step, t0 = step + 1, t; results[step] = nil end
    end
  elseif phase == "final" then
    if t - t0 > 15 then -- (a moment for the last changes to settle everywhere)
      if not wrote then wrote = true; put(role .. "-final", { shape = shape(p), at = utc() }) end
      local all = true
      local roster = have("A-roster")
      for _, r in ipairs(roster and roster.roles or here_roles) do all = all and have(r .. "-final") ~= nil end
      if role ~= "A" then say("finished: the desktop writes summary.md"); return end
      if all or t - t0 > 90 then here_roles = roster and roster.roles or here_roles; summary(); return end
    end
  end
  reaper.defer(tick)
end
say("cross test as " .. role .. " (" .. cfg.user .. ") in " .. STUDIO)
tick()
return "started as " .. role
