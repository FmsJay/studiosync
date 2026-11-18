-- Run inside REAPER (ReaScript). 0.59.27: the call apart from the playing. A fresh SonoBus in a scratch tab (in no group: it connects to
-- nothing) is given the split state, Music and Talk to send and a bandmate's talk on the call's pair, and what SonoBus itself saves
-- afterwards still has them; the live mix compiles with its two levels; the talk track's send lands mono on the Real time track's
-- channel 3. One scratch tab, closed at the end.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
local repo = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]")
package.path = repo .. "/lib/?.lua;" .. package.path
for _, m in ipairs({ "band", "sonobus", "hear", "live", "json" }) do package.loaded[m] = nil end
local band, sonobus, hear, live = require("band"), require("sonobus"), require("hear"), require("live")
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local front = reaper.EnumProjects(-1)
reaper.RecursiveCreateDirectory(D, 0)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
local ok, err = pcall(function()
  reaper.InsertTrackInProject(pa, 0, 0)
  local tr = reaper.GetTrack(pa, 0)
  reaper.SetMediaTrackInfo_Value(tr, "I_NCHAN", 16)
  local i = reaper.TrackFX_AddByName(tr, "VST3:SonoBus (Sonosaurus)", false, -1) -- (its VST3, as live.fx adds it: the VST2 keeps another shape)
  check(i >= 0, "SonoBus loads in a scratch tab")
  if i < 0 then return end
  local _, before = reaper.TrackFX_GetNamedConfigParm(tr, i, "vst_chunk")
  local outs = { TestMate = 4 }
  local new = sonobus.set_outputs(before, outs)
  new = sonobus.set_input_split(new)
  new = sonobus.set_talk(new, outs, hear.TALK)
  check(new ~= nil and sonobus.input_split_ok(new) and sonobus.talk_ok(new, outs, hear.TALK), "the state StudioSync made has both")
  if not new then return end
  reaper.TrackFX_SetNamedConfigParm(tr, i, "vst_chunk", new)
  reaper.TrackFX_SetOffline(tr, i, true); reaper.TrackFX_SetOffline(tr, i, false) -- (reloaded with it, as setup.sonobus does)
  local _, after = reaper.TrackFX_GetNamedConfigParm(tr, i, "vst_chunk")
  check(sonobus.input_split_ok(after), "SonoBus kept Music and Talk to send (its own saved state, read back)")
  check(sonobus.talk_ok(after, outs, hear.TALK), "and the bandmate's talk on the call's pair")
  check(sonobus.output_of(after, "TestMate") == 4, "and their playing on their own pair")
  local _, ins, outsn = reaper.TrackFX_GetIOSize(tr, i)
  check(ins >= 4 and outsn >= 16, string.format("SonoBus has the pins for it here (%d in, %d out)", ins, outsn))
  reaper.TrackFX_Delete(tr, i)
  -- the live mix, as hear.install writes it
  local mix = reaper.TrackFX_AddByName(tr, hear.install(), false, -1)
  check(mix >= 0 and reaper.TrackFX_GetNumParams(tr, mix) >= 11, "the live mix compiles with its levels (" .. reaper.TrackFX_GetNumParams(tr, mix) .. " params)")
  local _, n9 = reaper.TrackFX_GetParamName(tr, mix, 8)
  local _, n11 = reaper.TrackFX_GetParamName(tr, mix, 10)
  check(n9:find("call") ~= nil and n11:find("playing") ~= nil, "named: " .. n9 .. " / " .. n11)
  -- the talk track's send into the Real time track: mono from its input, onto channel 3
  local rt = live.rt_track(pa, true)
  local talk = live.talk_track(pa, true)
  check(rt ~= nil and talk ~= nil, "a Real time track and a talk track")
  if rt and talk then
    reaper.SetMediaTrackInfo_Value(talk, "I_RECARM", 1)
    reaper.SetProjExtState(pa, band.SECTION, "rt talk only", "1")
    live.rt_sends(pa)
    local found
    for s = 0, reaper.GetTrackNumSends(talk, 0) - 1 do
      if reaper.GetTrackSendInfo_Value(talk, 0, s, "P_DESTTRACK") == rt then
        found = { reaper.GetTrackSendInfo_Value(talk, 0, s, "I_SRCCHAN"), reaper.GetTrackSendInfo_Value(talk, 0, s, "I_DSTCHAN") }
      end
    end
    check(found and found[1] == 1024 and found[2] == 2, "talk goes mono onto channel 3: " .. (found and (found[1] .. "/" .. found[2]) or "no send"))
  end
end)
if not ok then out[#out + 1] = "ERROR " .. tostring(err); fails = fails + 1 end
if reaper.ValidatePtr2(0, pa, "ReaProject*") then
  reaper.SelectProjectInstance(pa)
  reaper.Main_SaveProjectEx(pa, D .. "/call_split.rpp", 8)
  reaper.Main_OnCommand(40860, 0)
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")
