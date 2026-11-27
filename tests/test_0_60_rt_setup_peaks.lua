-- rt-setup (findings 2026-11-27, issue "Waveforms not showing on some tracks"). Three causes found in the code, each checked here:
-- 1. The web view's Project page (lib/dawview.lua take_peaks) kept what REAPER answered for a take whose peaks weren't built yet (all silence)
--    as that take's waveform for good: the cache answered for it at every look after, P8's partial read or a whole one. Now silence is asked
--    again (5 s, then twice as long each time, up to 60 s), and a take given a new source (a file that grew) is read again.
-- 2. REAPER's peak files (.reapeaks, in the media folder's peaks folder) went through Syncthing: every computer's build of a take met in the
--    shared folder. lib/songsync.lua leaves them out (first line of each block), and lib/peaks.lua purge deletes the ones that came in.
-- 3. Missing peaks were built by REAPER's modal "Build any missing peaks", in the front tab only: lib/peaks.lua builds them a step a tick in
--    any tab, one at a time, never keeping a pointer it hasn't checked.
package.path = "lib/?.lua;" .. package.path
local now_t = 0
local zeros = true -- (REAPER hasn't built this take's peaks yet: it answers silence)
local src = { len = 10, file = "C:/s/Song/rooms/main/media/abc-take.flac" }
local take, item, track, P = { src = src }, {}, {}, { "proj" }
local asked = 0
reaper = setmetatable({
  time_precise = function() return now_t end,
  CountTracks = function() return 1 end, GetTrack = function() return track end, GetMediaTrackInfo_Value = function(_, k) return k == "B_SHOWINTCP" and 1 or 0 end,
  GetSetMediaTrackInfo_String = function() return true, "Bass" end, CountTrackEnvelopes = function() return 0 end,
  CountTrackMediaItems = function() return 1 end, GetTrackMediaItem = function() return item end,
  GetMediaItemInfo_Value = function(_, k) return k == "D_LENGTH" and 10 or 0 end, GetActiveTake = function() return take end,
  GetTakeName = function() return "take" end, GetMediaItemTakeInfo_Value = function(_, k) return k == "D_PLAYRATE" and 1 or 0 end,
  TakeIsMIDI = function() return false end, GetMediaItemTake_Source = function(t) return t.src end,
  GetMediaSourceFileName = function(s) return s.file end, GetMediaSourceLength = function(s) return s.len, false end,
  new_array = function(n) local t = {}; for i = 1, n do t[i] = 0 end; return { t = t, table = function() return t end } end,
  GetMediaItemTake_Peaks = function(_, _, _, _, want, _, buf)
    asked = asked + 1
    for i = 1, want do buf.t[i] = zeros and 0 or 0.5; buf.t[want + i] = zeros and 0 or -0.5 end
    return want
  end,
  EnumProjectMarkers3 = function() return 0 end, TimeMap_GetMeasureInfo = function() return 1e9 end, GetProjectLength = function() return 10 end,
  GetSetProjectGrid = function() return 0, 0.25 end, GetToggleCommandStateEx = function() return 0 end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return 0 end end end })
package.loaded.mirror = { track_oid = function() return "T1" end, local_track = function() return false end }
local band = require("band")
band.track_ext, band.track_colour, band.is_local_mark, band.capture_tempo = function() return "" end, function() return 0 end, function() return false end, function() return {} end
local dawview = require("dawview")
local function peaks_now(t)
  now_t = t
  local raw = dawview.read(P, "Song/main", t, math.huge, nil, true)
  return raw.tracks[1].items[1].peaks
end
-- 1. silence while REAPER builds: no waveform yet, asked again later, and the real one shows once it's there
assert(dawview.flat("0000") and not dawview.flat("00A0") and not dawview.flat(nil), "silence is all zeros")
assert(peaks_now(0) == nil and asked == 1, "silence isn't kept as the waveform")
assert(peaks_now(3) == nil and asked == 1, "not asked again within 5 s")
zeros = false
local p = peaks_now(6)
assert(asked == 2 and p and not dawview.flat(p), "asked again: the real waveform shows (it stayed a flat line before)")
assert(peaks_now(100) == p and asked == 2, "a real waveform is kept")
-- a take's file that grew under the same name: the take gets a new source (lib/streams.lua), read again
take.src = { len = 12, file = src.file }
assert(peaks_now(101) and asked == 3, "a new source: read again")
-- silence that stays silence (a silent take): asked less and less often, 60 s apart at most
zeros, take.src = true, { len = 20, file = src.file }
local times = {}
for t = 200, 600 do local a = asked; peaks_now(t); if asked > a then times[#times + 1] = t end end
assert(times[1] == 200 and times[2] - times[1] == 5 and times[3] - times[2] == 10 and times[4] - times[3] == 20 and times[5] - times[4] == 40 and times[6] - times[5] == 60
  and times[7] - times[6] == 60, "silence asked again after 5, 10, 20, 40, then every 60 s: " .. table.concat(times, " "))

-- 2. peak files stay each computer's: first in each block, so no ! line lets them in
local songsync = require("songsync")
for _, blk in ipairs({ songsync.block({ Song = true }), songsync.block_except({}), songsync.block_guest({ Song = true }) }) do
  assert(blk[2] == "(?d)*.reapeaks", "peak files ignored, before anything is let in")
end
local merged = songsync.merge("", { Song = true })
assert(merged:find("(?d)*.reapeaks", 1, true) < merged:find("!/Song", 1, true), "and in the written ignore file, before the song")
-- the ones that already came in: deleted in the projects' folders, nothing else touched
local peaks = require("peaks")
local FS = { ["R/Song/rooms/main/media/a.flac"] = 1, ["R/Song/rooms/main/media/peaks/a.flac.reapeaks"] = 1,
  ["R/Song/rooms/main/media/peaks/a.flac.sync-conflict-20261127-120000-ABCDEFG.reapeaks"] = 1, ["R/Song/rooms/side/media/b.wav.reapeaks"] = 1,
  ["R/Song/stems/x.wav.REAPEAKS"] = 1, ["R/_band/notes.reapeaks"] = 1, ["R/_tools/t.reapeaks"] = 1, ["R/Song/session.json"] = 1 }
local function list(dir)
  local files, dirs, seen = {}, {}, {}
  for path in pairs(FS) do
    local rest = path:sub(1, #dir + 1) == dir .. "/" and path:sub(#dir + 2)
    if rest then
      local first, more = rest:match("^([^/]+)(/?)")
      if more == "" then files[#files + 1] = first elseif not seen[first] then seen[first] = true; dirs[#dirs + 1] = first end
    end
  end
  return files, dirs
end
local n = peaks.purge("R", list, function(path) FS[path] = nil; return true end)
assert(n == 4, "four peak files in the project's folders went: " .. n)
assert(FS["R/Song/rooms/main/media/a.flac"] and FS["R/Song/session.json"] and FS["R/_band/notes.reapeaks"] and FS["R/_tools/t.reapeaks"], "media, project files and _ folders stay")

-- 3. missing peaks built a step a tick, one at a time, in any tab; a take deleted mid-build is let go
local calls, items = {}, {}
local function mk(name, missing, midi)
  local s = { name = name, missing = missing, left = 2 }
  local tk = { src = s, midi = midi }
  local it = { take = tk }
  tk.item = it
  items[#items + 1] = it
  return it
end
mk("a", true); mk("b", false); mk("m", true, true); mk("c", true)
local valid = {}
reaper = setmetatable({
  PCM_Source_BuildPeaks = function(s, mode)
    calls[#calls + 1] = s.name .. mode
    if mode == 0 then return s.missing and 1 or 0 end
    if mode == 1 then s.left = s.left - 1; return s.left > 0 and 50 or 0 end
    s.missing = false; return 0
  end,
  CountMediaItems = function() return #items end, GetMediaItem = function(_, i) return items[i + 1] end, GetActiveTake = function(it) return it.take end,
  TakeIsMIDI = function(tk) return tk.midi == true end, GetMediaItemTake_Source = function(tk) return tk.src end,
  ValidatePtr2 = function(_, ptr) return valid[ptr] ~= false end, UpdateItemInProject = function(it) calls[#calls + 1] = "update " .. it.take.src.name end,
  EnumProjects = function() return P end,
}, { __index = function() return function() end end })
peaks.want(P)
for _ = 1, 20 do peaks.tick(P) end
assert(table.concat(calls, ",") == "a0,a1,a1,a2,update a,b0,c0,c1,c1,c2,update c", "each missing one built in steps, MIDI skipped: " .. table.concat(calls, ","))
assert(not peaks.busy(P), "done: nothing more to do")
calls, items = {}, {}
local gone = mk("d", true); mk("e", true)
peaks.want(P)
peaks.tick(P); peaks.tick(P) -- (d begun, a step)
valid[gone.take] = false -- (its item deleted by a bandmate's change)
for _ = 1, 10 do peaks.tick(P) end
local text = table.concat(calls, ",")
assert(text:find("^d0,d1,e0") and not text:find("d2", 1, true), "a deleted take's source is never touched again: " .. text)
print("ok")
