-- Run inside REAPER (ReaScript). A knob turned while StudioSync wasn't running (0.58.78): at the next open it read as the
-- plug-in loading, and never went out (Linux stress test). Now each chain's knobs are kept in the project as they were when
-- this machine last agreed with the band, and knobs not as left go out. A chain nobody touched still sends nothing.
-- Scratch folder and scratch tabs only.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
local function fresh() -- (a REAPER restart, as far as StudioSync's memory goes)
  for _, m in ipairs({ "band", "sync", "mirror", "prints", "plugins", "json" }) do package.loaded[m] = nil end
  require("prints").SETTLE = 1.5
  return require("band"), require("sync"), require("mirror")
end
local band, sync, mirror = fresh()
local stamp = os.time()
local root = D .. "/kroot_" .. stamp
local song, room = "KnobLab", "main"
local A = { user = "James", root = root }
local events = sync.room_dir(A, song, room) .. "/events"
reaper.RecursiveCreateDirectory(events, 0)
local yes = function() return true end
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local function pass(p) reaper.SelectProjectInstance(p); return mirror.watch(p, A, song, room, { can = yes, mode = "claims" }) end
local function hold(s) local w = reaper.time_precise(); while reaper.time_precise() - w < s do end end
local function fx_sent()
  local n = 0
  for _, f in ipairs(band.files(events, ".json")) do
    local e = band.read_json(events .. "/" .. f)
    if e and e.obj == "fx" then n = n + 1 end
  end
  return n
end
local file = D .. "/knob_" .. stamp .. ".rpp"
local front = reaper.EnumProjects(-1)
local was_bg = reaper.GetExtState(band.SECTION, "bg render test")
reaper.SetExtState(band.SECTION, "bg render test", "off", false)
local p1, p2
local ok, err = pcall(function()
  reaper.Main_OnCommand(40859, 0); p1 = reaper.EnumProjects(-1)
  for i, fx in ipairs({ "ReaComp", "ReaEQ" }) do
    reaper.InsertTrackInProject(p1, i - 1, 0)
    local tr = reaper.GetTrack(p1, i - 1)
    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", fx .. " track", true)
    reaper.TrackFX_AddByName(tr, fx, false, -1)
  end
  local t = reaper.time_precise()
  while reaper.time_precise() - t < 15 and fx_sent() < 2 do pass(p1); hold(0.4) end
  check(fx_sent() == 2, "both chains go out")
  for _ = 1, 6 do pass(p1); hold(0.3) end
  local k = select(2, reaper.GetProjExtState(p1, mirror.SEC, "fxk " .. "F" .. select(2, reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(p1, 0), "P_EXT:band_oid", "", false)):sub(2)))
  check(k ~= "", "their knobs are kept in the project")

  -- StudioSync stops; a knob is turned; the project is saved and closed, then opened again with StudioSync running
  reaper.TrackFX_SetParam(reaper.GetTrack(p1, 0), 0, 0, -20)
  reaper.Main_SaveProjectEx(p1, file, 8)
  reaper.Main_OnCommand(40860, 0); p1 = nil
  band, sync, mirror = fresh()
  reaper.Main_OnCommand(40859, 0)
  reaper.Main_openProject("noprompt:" .. file)
  p2 = reaper.EnumProjects(-1)
  local th = reaper.TrackFX_GetParam(reaper.GetTrack(p2, 0), 0, 0)
  t = reaper.time_precise()
  while reaper.time_precise() - t < 15 and fx_sent() < 3 do pass(p2); hold(0.4) end
  check(fx_sent() == 3, string.format("the knob turned meanwhile goes out (%.1f s)", reaper.time_precise() - t))
  local last
  for _, f in ipairs(band.files(events, ".json")) do
    local e = band.read_json(events .. "/" .. f)
    if e and e.obj == "fx" and (not last or f > last.f) then last = { f = f, e = e } end
  end
  check(last and last.e.state:find("ReaComp", 1, true) ~= nil, "it's the compressor's chain")
  for _ = 1, 8 do pass(p2); hold(0.3) end
  check(fx_sent() == 3, "and the chain nobody touched sends nothing")
  check(math.abs(th - reaper.TrackFX_GetParam(reaper.GetTrack(p2, 0), 0, 0)) < 0.01, "the knob stays where it was turned")
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
reaper.SetExtState(band.SECTION, "bg render test", was_bg, false)
for _, p in ipairs({ p2, p1 }) do
  if p then
    reaper.SelectProjectInstance(p)
    reaper.Main_SaveProjectEx(p, root .. "/" .. tostring(p):gsub("%W", "") .. ".rpp", 8)
    reaper.Main_OnCommand(40860, 0)
  end
end
reaper.SelectProjectInstance(front)
out[#out + 1] = fails == 0 and "ALL PASS" or (fails .. " FAILED")
return table.concat(out, "\n")
