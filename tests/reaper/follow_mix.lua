-- Run inside REAPER (ReaScript). Following someone takes on their mix (0.58.82, lib/presence.lua): their faders, pan and solos land here
-- with Control your own mix on meanwhile (so none of it goes out), and yours come back when you stop following. A scratch tab only.
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "mirror", "presence", "json" }) do package.loaded[m] = nil end
local band, mirror, presence = require("band"), require("mirror"), require("presence")
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0)
local p = reaper.EnumProjects(-1)
local ok, err = pcall(function()
  local oids = {}
  for i = 1, 3 do
    reaper.InsertTrackInProject(p, i - 1, 0)
    local tr = reaper.GetTrack(p, i - 1)
    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "T" .. i, true)
    oids[i] = string.format("T-JAMES-20261116000000-%d", i)
    reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_oid", oids[i], true)
    reaper.SetMediaTrackInfo_Value(tr, "D_VOL", 1)
  end
  local mine = presence.my_mix(p)
  check(mine[oids[1]] and mine[oids[1]].v == 1 and mine[oids[1]].s == 0, "this computer's mix, by track")
  local theirs = { [oids[1]] = { v = 0.5, p = -0.5, s = 0 }, [oids[2]] = { v = 1, p = 0, s = 2 }, [oids[3]] = { v = 0.25, p = 0, s = 0 } }
  local peers = { { user = "Sam", mix = theirs } }
  local ctx = { cfg = { user = "James", root = reaper.GetResourcePath() .. "/StudioSync/tests/fm_" .. os.time() }, song = "FM", room = "main" }
  presence.follow_mix(p, peers, "Sam", ctx)
  local t1, t2 = reaper.GetTrack(p, 0), reaper.GetTrack(p, 1)
  check(math.abs(reaper.GetMediaTrackInfo_Value(t1, "D_VOL") - 0.5) < 1e-6 and math.abs(reaper.GetMediaTrackInfo_Value(t1, "D_PAN") + 0.5) < 1e-6, "their fader and pan")
  check(reaper.GetMediaTrackInfo_Value(t2, "I_SOLO") == 2, "their solo")
  check(select(2, reaper.GetProjExtState(p, band.SECTION, "local_mix")) == "1", "Control your own mix is on meanwhile, so it doesn't go out")
  theirs[oids[3]].v = 0.75
  presence.follow_mix(p, peers, "Sam", ctx)
  check(math.abs(reaper.GetMediaTrackInfo_Value(reaper.GetTrack(p, 2), "D_VOL") - 0.75) < 1e-6, "and what they change after")
  presence.follow_mix(p, {}, "Sam", ctx)
  check(math.abs(reaper.GetMediaTrackInfo_Value(reaper.GetTrack(p, 2), "D_VOL") - 0.75) < 1e-6, "they're gone a moment: it stays as it is")
  presence.follow_mix(p, peers, "", ctx)
  check(math.abs(reaper.GetMediaTrackInfo_Value(t1, "D_VOL") - 1) < 1e-6 and reaper.GetMediaTrackInfo_Value(t2, "I_SOLO") == 0, "stopped following: your own mix back")
  check(select(2, reaper.GetProjExtState(p, band.SECTION, "local_mix")) == "" and select(2, reaper.GetProjExtState(p, band.SECTION, "follow mix saved")) == "",
    "and Control your own mix as it was")
  presence.follow_mix(p, peers, "", ctx)
  check(true, "not following, nothing saved: nothing to do")
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
reaper.SelectProjectInstance(p)
local scratch = reaper.GetResourcePath() .. "/StudioSync/tests/fm_saved"
reaper.RecursiveCreateDirectory(scratch, 0)
reaper.Main_SaveProjectEx(p, scratch .. "/follow_mix.rpp", 8) -- (saved, so closing it asks nothing)
reaper.Main_OnCommand(40860, 0)
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
out[#out + 1] = fails == 0 and "ALL PASS" or (fails .. " FAILED")
return table.concat(out, "\n")
