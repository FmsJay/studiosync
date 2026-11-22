-- tools/devices/probe.lua: read-only looks into this computer's REAPER for tools/devices (rt-t1). GPL-3.0-or-later.
-- Run through the dev eval hook with T1P = { mode = ..., ... } first; one line tagged T1PROBE (JSON-ish, flat). Changes nothing.
--   token                         the web UI's phone-link token (StudioSync_WebUIStatus): stays on this computer, never printed by callers
--   tracks guids={...}            Cross Test's tracks with those GUIDs: name, record input, arm, monitoring
local E = T1P or {}
T1P = nil
local function cross_test()
  for i = 0, 50 do
    local q = reaper.EnumProjects(i)
    if not q then break end
    if select(2, reaper.GetProjExtState(q, "BandSync", "song")) == "Cross Test" then return q end
  end
end
local out = {}
if E.mode == "token" then
  local ok, s = pcall(reaper.StudioSync_WebUIStatus)
  out[#out + 1] = (ok and type(s) == "string" and s:match('"token":"(%x+)"')) or ""
elseif E.mode == "tracks" then
  local p = cross_test()
  local want = {}
  for _, g in ipairs(E.guids or {}) do want[g] = true end
  for k = 0, p and reaper.CountTracks(p) - 1 or -1 do
    local tr = reaper.GetTrack(p, k)
    local g = reaper.GetTrackGUID(tr)
    if want[g] then
      out[#out + 1] = string.format("%s|%s|%d|%d|%d", g, select(2, reaper.GetTrackName(tr)), math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_RECINPUT")),
        math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_RECARM")), math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_RECMON")))
    end
  end
end
return "T1PROBE " .. table.concat(out, ";")
