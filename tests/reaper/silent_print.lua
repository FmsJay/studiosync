-- Run inside REAPER (ReaScript). A print of notes that comes out silent (0.58.78): the instrument loaded, its sounds didn't
-- (a library or kit not installed here). It isn't attached, the file goes, and the log says why; it isn't rendered again.
-- A part that sounds still gets its print. ReaSynth at -inf stands in for the instrument with no sounds. Scratch tab, saved
-- into the scratch folder and closed.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "prints", "json" }) do package.loaded[m] = nil end
require("prints").SETTLE = 0
local band, prints = require("band"), require("prints")
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local p = reaper.EnumProjects(-1)
local media = D .. "/silent_media_" .. os.time()
reaper.RecursiveCreateDirectory(media, 0)
local was_bg = reaper.GetExtState("BandSync", "bg render")
reaper.SetExtState("BandSync", "bg render", "off", false)
local logged = {}
local log = band.log
band.log = function(s) logged[#logged + 1] = s; return log(s) end
local ok, err = pcall(function()
  local function part(i, name, volume)
    reaper.InsertTrackInProject(p, i, 0)
    local tr = reaper.GetTrack(p, i)
    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
    reaper.TrackFX_AddByName(tr, "ReaSynth", false, -1)
    for k = 0, volume and reaper.TrackFX_GetNumParams(tr, 0) - 1 or -1 do
      if select(2, reaper.TrackFX_GetParamName(tr, 0, k)):lower():find("volume") then reaper.TrackFX_SetParamNormalized(tr, 0, k, volume) end
    end
    local it = reaper.CreateNewMIDIItemInProj(tr, 0, 1, false)
    local tk = reaper.GetActiveTake(it)
    reaper.MIDI_InsertNote(tk, false, false, 0, 960, 0, 60, 110, true); reaper.MIDI_Sort(tk)
    reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", "I-Test-" .. i, true)
    return it
  end
  local quiet, loud = part(0, "No sounds", 0), part(1, "Synth")
  reaper.SelectProjectInstance(p)
  check(prints.refresh(p, quiet, media, "fx") == false, "the silent print isn't attached")
  local _, wet = prints.takes(quiet)
  check(wet == nil and reaper.CountTakes(quiet) == 1, "the item keeps its notes alone")
  check(#band.files(media, ".flac") == 0, "and the silent file is gone")
  check(logged[#logged] and logged[#logged]:find("came out silent", 1, true) ~= nil, "the log says why: " .. tostring(logged[#logged]))
  local n = #logged
  check(prints.refresh(p, quiet, media, "fx") == false and #logged == n and #band.files(media, ".flac") == 0, "it isn't rendered or said again")
  check(prints.refresh(p, loud, media, "fx") == true, "a part that sounds gets its print")
  local _, wet2 = prints.takes(loud)
  check(wet2 ~= nil, "attached as its wet take")
  -- a plug-in taken offline to save CPU doesn't hold its track's prints back; one that isn't installed still does
  local tr = reaper.GetMediaItem_Track(loud)
  local eq = reaper.TrackFX_AddByName(tr, "ReaEQ", false, -1)
  reaper.TrackFX_SetOffline(tr, eq, true)
  check(prints.track_plays(tr, true), "offline by choice: it still prints")
  check(not prints.track_plays(tr), "though the track doesn't play here as it is")
  local _, chunk = reaper.GetTrackStateChunk(tr, "", false)
  chunk = chunk:gsub("(<FXCHAIN\n)", "%1BYPASS 0 1 0\n<VST \"VST: Not Installed Anywhere (Nobody)\" nothere.dll 0 \"\" 1234<>\nAAAA\n>\nFXID {11111111-2222-3333-4444-555555555555}\nWAK 0 0\n", 1)
  reaper.SetTrackStateChunk(tr, chunk, false)
  check(reaper.TrackFX_GetCount(tr) == 3 and not prints.track_plays(tr, true), "a plug-in that isn't installed: no print")
end)
if not ok then fails = fails + 1; say("ERROR " .. tostring(err)) end
band.log = log
reaper.SetExtState("BandSync", "bg render", was_bg, false)
reaper.SelectProjectInstance(p)
reaper.Main_SaveProjectEx(p, media .. "/silent.rpp", 8)
reaper.Main_OnCommand(40860, 0)
reaper.SelectProjectInstance(front)
say(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
return table.concat(out, "\n")
