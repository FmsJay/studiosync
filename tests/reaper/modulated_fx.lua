-- Run inside REAPER (ReaScript). A plug-in with an LFO on one of its knobs (0.58.78): what it saves holds that knob as it was
-- at that instant, so the two machines never matched (a lasting "differs", Linux stress test). Now: its chain goes out once,
-- both end on the same fingerprint, nothing more goes out while the LFO runs, and its other knobs still count.
-- Two scratch tabs, a scratch shared folder; both saved there and closed at the end.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "prints", "plugins", "json" }) do package.loaded[m] = nil end
require("prints").SETTLE = 1.5
local band, sync, mirror = require("band"), require("sync"), require("mirror")
local root = D .. "/mroot_" .. os.time()
local song, room = "ModLab", "main"
local A, B = { user = "Laptop", root = root }, { user = "James", root = root }
local events = sync.room_dir(A, song, room) .. "/events"
reaper.RecursiveCreateDirectory(events, 0)
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local function sent(who, obj)
  local n = 0
  for _, f in ipairs(band.files(events, ".json")) do
    if f:sub(1, #who + 1) == who .. "-" then
      local e = band.read_json(events .. "/" .. f)
      if not obj or (e and e.obj == obj) then n = n + 1 end
    end
  end
  return n
end
local yes = function() return true end
local front = reaper.EnumProjects(-1)
local was_bg = reaper.GetExtState(band.SECTION, "bg render")
reaper.SetExtState(band.SECTION, "bg render", "off", false)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pb = reaper.EnumProjects(-1)
sync.driver_name = "Laptop"
local function watch(p, cfg)
  reaper.SelectProjectInstance(p)
  return (mirror.watch(p, cfg, song, room, { can = yes, mode = "claims", here = { Laptop = true, James = true } }))
end
local function recv(p, cfg) reaper.SelectProjectInstance(p); for _ = 1, 3 do sync.receive(p, cfg, song, room, yes) end end
local function hold(s) local w = reaper.time_precise(); while reaper.time_precise() - w < s do end end
local ok, err = pcall(function()
  reaper.SelectProjectInstance(pa)
  reaper.InsertTrackInProject(pa, 0, 0)
  local tr = reaper.GetTrack(pa, 0)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Wobble", true)
  reaper.TrackFX_AddByName(tr, "ReaComp", false, -1)
  reaper.TrackFX_AddByName(tr, "ReaEQ", false, -1)
  reaper.TrackFX_SetNamedConfigParm(tr, 0, "param.1.mod.active", "1")
  reaper.TrackFX_SetNamedConfigParm(tr, 0, "param.1.lfo.active", "1")
  reaper.TrackFX_SetNamedConfigParm(tr, 0, "param.1.lfo.speed", "8")
  local _, c1 = reaper.GetTrackStateChunk(tr, "", false); hold(0.3)
  local _, c2 = reaper.GetTrackStateChunk(tr, "", false)
  check(c1 ~= c2, "its saved data moves by itself")
  local t = reaper.time_precise()
  while reaper.time_precise() - t < 15 and sent("Laptop", "fx") == 0 do watch(pa, A); hold(0.4) end
  check(sent("Laptop", "fx") == 1, string.format("its chain goes out (%.1f s)", reaper.time_precise() - t))
  for _ = 1, 10 do watch(pa, A); hold(0.3) end
  check(sent("Laptop", "fx") == 1, "once, while the LFO keeps moving it")

  recv(pb, B)
  local tb = reaper.GetTrack(pb, 0)
  check(tb and reaper.TrackFX_GetCount(tb) == 2, "the bandmate has the chain")
  local _, lfo = reaper.TrackFX_GetNamedConfigParm(tb, 0, "param.1.lfo.active")
  check(lfo == "1", "with its LFO")
  for _ = 1, 10 do watch(pb, B); hold(0.3); recv(pb, B) end
  check(sent("James") == 0, "and sends nothing back")
  watch(pa, A)
  check(mirror.root(pa) == mirror.root(pb), "both on the same fingerprint")

  -- a knob the LFO doesn't move still counts
  reaper.SelectProjectInstance(pa)
  reaper.TrackFX_SetParam(tr, 0, 0, -12)
  t = reaper.time_precise()
  while reaper.time_precise() - t < 10 and sent("Laptop", "fx") == 1 do watch(pa, A); hold(0.3) end
  check(sent("Laptop", "fx") == 2, "turning another knob goes out")
  for _ = 1, 8 do watch(pa, A); hold(0.3) end
  check(sent("Laptop", "fx") == 2, "once")
  recv(pb, B)
  check(math.abs(reaper.TrackFX_GetParam(tb, 0, 0) - reaper.TrackFX_GetParam(tr, 0, 0)) < 0.01, "and lands on the bandmate")
  for _ = 1, 8 do watch(pb, B); hold(0.3); recv(pb, B) end
  check(sent("James") == 0, "without coming back")

  -- and the LFO switched off is a change too
  reaper.SelectProjectInstance(pa)
  reaper.TrackFX_SetNamedConfigParm(tr, 0, "param.1.mod.active", "0")
  t = reaper.time_precise()
  while reaper.time_precise() - t < 10 and sent("Laptop", "fx") == 2 do watch(pa, A); hold(0.3) end
  check(sent("Laptop", "fx") == 3, "switching its modulation off goes out")
  recv(pb, B)
  local _, on = reaper.TrackFX_GetNamedConfigParm(tb, 0, "param.1.mod.active")
  check(on == "0", "and lands")
end)
if not ok then fails = fails + 1; say("ERROR " .. tostring(err)) end
reaper.SetExtState(band.SECTION, "bg render", was_bg, false)
for _, p in ipairs({ pb, pa }) do
  reaper.SelectProjectInstance(p)
  reaper.Main_SaveProjectEx(p, root .. "/" .. tostring(p):gsub("%W", "") .. ".rpp", 8)
  reaper.Main_OnCommand(40860, 0)
end
reaper.SelectProjectInstance(front)
say(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
return table.concat(out, "\n")
