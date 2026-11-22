-- tools/devices/pattern.lua: the ears pattern into this computer's own output, quietly, for listening links (rt-t1, docs/rt/rt-t1.md).
-- GPL-3.0-or-later. Run through the dev eval hook with T1 = { mode = ..., ... } set first; returns one line tagged T1PAT. Only the song
-- "Cross Test"; every REAPER call pcall-wrapped by the hook's caller and given all its arguments. The project is never saved.
--   add     f32=<pattern.f32> vol=0.01   the pattern into gmem "StudioSyncEars" (as tools/ears/ears.lua load) and a track "T1 Pattern":
--                                        this computer's own (band_local "yours": never sent to bandmates), armed with no input and no
--                                        monitoring (so its FX run while stopped), ears.jsfx playing in slot 2, the MASTER SEND ON at
--                                        `vol` (0.01 = -40 dB: the pattern's -6 dBFS peak reaches the output at -46 dBFS), so listening
--                                        links and browser guests (which take this computer's output) hear it
--   fire                                 play the pattern once (slot 2); -> the link clock when fired
--   info                                 the track, the master's volume and mute, Live sync's deafen
--   remove                               the track deleted
local E = T1 or {}
T1 = nil
local S = "BandSync"
local GM = "StudioSyncEars"
local FX = "JS:StudioSync Ears/ears.jsfx"
local NAME = "T1 Pattern"
local SLOT = 2

local function cross_test()
  for i = 0, 50 do
    local q = reaper.EnumProjects(i)
    if not q then break end
    if select(2, reaper.GetProjExtState(q, S, "song")) == "Cross Test" then return q end
  end
end
local function find_track(p)
  for k = 0, reaper.CountTracks(p) - 1 do
    local tr = reaper.GetTrack(p, k)
    if select(2, reaper.GetTrackName(tr)) == NAME then return tr end
  end
end
local function now() return reaper.StudioSync_DirectNow and reaper.StudioSync_DirectNow() or reaper.time_precise() end

local modes = {}
function modes.add()
  local p = assert(cross_test(), "no Cross Test tab")
  if find_track(p) then return "already there" end
  local f = assert(io.open(E.f32, "rb"))
  local data = f:read("a")
  f:close()
  reaper.gmem_attach(GM)
  local n = #data // 4
  for i = 0, n - 1, 4096 do
    local m = math.min(4096, n - i)
    local vals = { string.unpack("<" .. string.rep("f", m), data, i * 4 + 1) }
    for j = 1, m do reaper.gmem_write(1024 + i + j - 1, vals[j]) end
  end
  reaper.gmem_write(0, n)
  reaper.Undo_BeginBlock2(p)
  local k = reaper.CountTracks(p)
  reaper.InsertTrackAtIndex(k, true)
  local tr = reaper.GetTrack(p, k)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", NAME, true)
  reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local", "yours", true)
  reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 1)
  reaper.SetMediaTrackInfo_Value(tr, "D_VOL", math.min(tonumber(E.vol) or 0.01, 0.01)) -- (never louder than -40 dB)
  reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", -1)
  reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", 0)
  local fx = reaper.TrackFX_AddByName(tr, FX, false, -1)
  if fx < 0 then
    reaper.DeleteTrack(tr)
    reaper.Undo_EndBlock2(p, "t1: pattern track", -1)
    return "ears.jsfx not found (copy tools/ears/ears.jsfx to Effects/StudioSync Ears/)"
  end
  reaper.TrackFX_SetParam(tr, fx, 0, 0)
  reaper.TrackFX_SetParam(tr, fx, 1, SLOT)
  reaper.TrackFX_SetParam(tr, fx, 2, 0)
  reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 1)
  reaper.Undo_EndBlock2(p, "t1: pattern track", -1)
  return string.format("added %s (yours, armed, no input, master send at %.4f), %d frames loaded", NAME, reaper.GetMediaTrackInfo_Value(tr, "D_VOL"), n)
end
function modes.fire()
  reaper.gmem_attach(GM)
  local base = 8 + 8 * SLOT
  local t = now()
  reaper.gmem_write(base, reaper.gmem_read(base) + 1)
  return string.format("fired at %.4f", t)
end
function modes.info()
  local p = cross_test()
  local m = p and reaper.GetMasterTrack(p)
  local tr = p and find_track(p)
  reaper.gmem_attach(GM)
  return string.format("track=%s vol=%s master_vol=%.4f master_mute=%d deaf=%s slot_taken=%d running=%d", tostring(tr ~= nil),
    tr and string.format("%.4f", reaper.GetMediaTrackInfo_Value(tr, "D_VOL")) or "-", m and reaper.GetMediaTrackInfo_Value(m, "D_VOL") or -1,
    m and math.floor(reaper.GetMediaTrackInfo_Value(m, "B_MUTE")) or -1, reaper.GetExtState(S, "live audio deaf"),
    math.floor(reaper.gmem_read(8 + 8 * SLOT + 1)), math.floor(reaper.gmem_read(8 + 8 * SLOT + 3)))
end
function modes.remove()
  local p = assert(cross_test(), "no Cross Test tab")
  local tr = find_track(p)
  if not tr then return "not there" end
  reaper.Undo_BeginBlock2(p)
  reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 0)
  reaper.DeleteTrack(tr)
  reaper.Undo_EndBlock2(p, "t1: pattern track removed", -1)
  return "removed " .. NAME
end

local fn = modes[E.mode or ""]
if not fn then return "T1PAT unknown mode " .. tostring(E.mode) end
local ok, r = pcall(fn)
return "T1PAT " .. (ok and tostring(r) or ("error: " .. tostring(r)))
