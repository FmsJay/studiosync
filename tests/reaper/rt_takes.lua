-- Run inside REAPER (ReaScript). Takes as a studio setting and prints of the picked take (rt, commit d58afdf):
--   7. band.json "takes_to_lanes" false: prints.takes_to_lanes(proj, mine, root) does nothing (the item keeps its two takes, the track stays
--      out of lanes); groups.set_takes_to_lanes back on (the key removed: on by default): it converts as before;
--   8. an audio item with two takes on a track whose plug-in "someone lacks" (prints.lacking stood in for) gets a real print of the picked
--      take, rendered here (background renders off for the run), with prints.FROM saying which take; picking the other take prints again
--      with another source hash and FROM; where the plug-ins don't load the print plays only for the take it was made from, and a playing
--      print counts as that take (mirror.picked_take).
-- A scratch tab and a scratch studio folder (two 2 s test tones; the prints land in its media folder); Syncthing isn't asked (lib/trust.lua
-- stood in for). The ExtState "bg render" and "print problem" are put back. Any OS.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
local MODS = { "band", "json", "groups", "trust", "prints", "mirror", "sync", "plugins", "bgrender" }
for _, m in ipairs(MODS) do package.loaded[m] = nil end
package.loaded.trust = { pins = function() return nil end, from_manager_file = function() return nil end, inviter = function() return nil end,
  roles = function() return nil, {} end, held = function() return false end, pin = function() end, managers = function() return nil end,
  roles_of = function() return {} end }
local band, groups, prints, mirror = require("band"), require("groups"), require("prints"), require("mirror")
prints.SETTLE = 0 -- (print_bursts covers the wait)
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local root = D .. "/rttakes_" .. os.time() .. "/StudioSync TakesLab"
local media = root .. "/TakesLab/rooms/main/media"
local cfg = { user = "James", root = root }
local S = band.SECTION
local was = { ["bg render"] = reaper.GetExtState(S, "bg render"), ["print problem"] = reaper.GetExtState(S, "print problem") }
reaper.SetExtState(S, "bg render", "off", false) -- (rendered here and now: the background renderer is audio_prints.lua's)
local function sine(path, hz) -- 2 s, 44.1 kHz, 16-bit mono, -12 dBFS
  local sr, n = 44100, 88200
  local t = { "RIFF", string.pack("<I4", 36 + n * 2), "WAVE", "fmt ", string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, sr, sr * 2, 2, 16), "data", string.pack("<I4", n * 2) }
  for i = 0, n - 1 do t[#t + 1] = string.pack("<i2", math.floor(0.25 * 32767 * math.sin(2 * math.pi * hz * i / sr))) end
  local f = assert(io.open(path, "wb")); f:write(table.concat(t)); f:close()
  return path
end
local function two_takes(tr, at, oid)
  local it = reaper.AddMediaItemToTrack(tr)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", at); reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 2)
  for _, f in ipairs({ "takeA.wav", "takeB.wav" }) do
    reaper.SetMediaItemTake_Source(reaper.AddTakeToMediaItem(it), reaper.PCM_Source_CreateFromFile(media .. "/" .. f))
  end
  if oid then reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", oid, true) end
  return it
end
local function ext(tk, k) return tk and select(2, reaper.GetSetMediaItemTakeInfo_String(tk, "P_EXT:" .. k, "", false)) or "" end
local user = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local p = reaper.EnumProjects(-1)
local ok, err = pcall(function()
  reaper.RecursiveCreateDirectory(media, 0)
  reaper.RecursiveCreateDirectory(root .. "/_band", 0)
  sine(media .. "/takeA.wav", 220); sine(media .. "/takeB.wav", 330)
  band.write_json(root .. "/_band/band.json", { name = "TakesLab", id = "rttakes-lab", takes_to_lanes = false })
  local all = function() return true end

  -- ---- 7. takes become lanes only while the studio's setting is on ----------------------------------------------------------------
  reaper.InsertTrackInProject(p, 0, 0)
  local t1 = reaper.GetTrack(p, 0)
  reaper.GetSetMediaTrackInfo_String(t1, "P_NAME", "Takes", true)
  local it = two_takes(t1, 1)
  reaper.SetMediaItemInfo_Value(it, "I_CURTAKE", 1)
  check(groups.takes_to_lanes(root) == false, "7. band.json says takes_to_lanes false: the studio's setting is off")
  -- (the track before and after, whatever it starts as: the pass returned 0 on the desktop, but "no lanes" failed. A new track can start in
  -- fixed lanes by REAPER's track defaults; this line says which it was. Desktop, rt)
  local function looks()
    return string.format("%d item(s), %d take(s), freemode %d, %d lane(s)", reaper.CountTrackMediaItems(t1), reaper.CountTakes(reaper.GetTrackMediaItem(t1, 0)),
      reaper.GetMediaTrackInfo_Value(t1, "I_FREEMODE"), reaper.GetMediaTrackInfo_Value(t1, "I_NUMFIXEDLANES"))
  end
  local before = looks()
  say("     the new track: " .. before)
  local n = prints.takes_to_lanes(p, all, root)
  check(n == 0 and looks() == before, "off: the pass does nothing (" .. tostring(n) .. "; " .. looks() .. ")")
  groups.set_takes_to_lanes(root, true)
  check((band.read_json(root .. "/_band/band.json") or {}).takes_to_lanes == nil and groups.takes_to_lanes(root) == true, "switched on: the key is gone from band.json (on by default)")
  n = prints.takes_to_lanes(p, all, root)
  local one_each = true
  for j = 0, reaper.CountTrackMediaItems(t1) - 1 do one_each = one_each and reaper.CountTakes(reaper.GetTrackMediaItem(t1, j)) == 1 end
  check(n > 0 and reaper.GetMediaTrackInfo_Value(t1, "I_FREEMODE") == 2 and one_each, string.format("on: it converts as before (%d, in lanes, %d items of one take)", n, reaper.CountTrackMediaItems(t1)))
  groups.set_takes_to_lanes(root, false)
  check((band.read_json(root .. "/_band/band.json") or {}).takes_to_lanes == false, "and off again is written as false")

  -- ---- 8. a print of the picked take ---------------------------------------------------------------------------------------------
  reaper.InsertTrackInProject(p, 1, 0)
  local t2 = reaper.GetTrack(p, 1)
  reaper.GetSetMediaTrackInfo_String(t2, "P_NAME", "Amp", true)
  local fx = reaper.TrackFX_AddByName(t2, "JS: Volume Adjustment", false, -1)
  if fx < 0 then fx = reaper.TrackFX_AddByName(t2, "utility/volume", false, -1) end
  if fx < 0 then error("no JS volume plug-in here to put on the track") end
  reaper.TrackFX_SetParam(t2, fx, 0, 6)
  local real_lacking, real_plays = prints.lacking, prints.track_plays
  prints.lacking = function() return true end -- (someone in the band lacks the track's plug-in)
  local item = two_takes(t2, 4, "I-JAMES-20261119000000-1")
  local tA, tB = reaper.GetTake(item, 0), reaper.GetTake(item, 1)
  local function refresh()
    local did
    for _ = 1, 3 do did = prints.refresh(p, item, media, "fxhash", nil, cfg); if did then break end end
    return did
  end
  reaper.SetMediaItemInfo_Value(item, "I_CURTAKE", 1)
  check(prints.audio_take(item) == tB, "8. two takes, the second picked: it's the one a print stands for")
  local did = refresh()
  local _, pr = prints.takes(item)
  local hB = mirror.hash(prints.audio_source(item, tB, "fxhash") .. "|t1")
  local file = pr and reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(pr), "") or ""
  check(did and pr ~= nil, "it gets a print, rendered here")
  check(ext(pr, prints.KEY) == hB and ext(pr, prints.FROM) == "1", "made from the second take: source hash of take 2 and the pick, FROM '" .. ext(pr, prints.FROM) .. "'")
  check(file:find(hB, 1, true) and reaper.file_exists(file), "its file is there and named for that source: " .. file:match("[^/\\]*$"))
  check(reaper.GetActiveTake(item) == tB, "the plug-ins load here: the picked take plays itself")
  prints.track_plays = function() return false end -- (as on the computer that lacks them)
  prints.choose(item, true)
  check(reaper.GetActiveTake(item) == pr, "where they don't load, the print plays")
  check(mirror.picked_take(item) == 1, "and counts as the take it was made from (BANDTAKE stays 1)")
  -- the other take picked
  reaper.SetMediaItemInfo_Value(item, "I_CURTAKE", 0)
  prints.choose(item, true)
  check(reaper.GetActiveTake(item) == tA, "take 1 picked: it plays itself until its own print lands (the print is take 2's)")
  prints.track_plays = real_plays
  did = refresh()
  local _, pr2 = prints.takes(item)
  local hA = mirror.hash(prints.audio_source(item, tA, "fxhash") .. "|t0")
  check(did and pr2 ~= nil and ext(pr2, prints.KEY) == hA and hA ~= hB, "picking take 1 prints again, with another source hash")
  check(ext(pr2, prints.FROM) == "0", "and FROM says take 1: '" .. ext(pr2, prints.FROM) .. "'")
  check(reaper.CountTakes(item) == 3 and #mirror.real_takes(item) == 2, "the print replaced the old one (3 takes: 2 real and the print)")
  local file2 = pr2 and reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(pr2), "") or ""
  check(file2 ~= file and reaper.file_exists(file2), "from a file of its own: " .. file2:match("[^/\\]*$"))
  prints.track_plays = function() return false end
  prints.choose(item, true)
  check(reaper.GetActiveTake(item) == pr2 and mirror.picked_take(item) == 0, "where the plug-ins don't load, take 1's print plays, counted as take 1")
  prints.track_plays = real_plays
  check(prints.refresh(p, item, media, "fxhash", nil, cfg) == false and select(2, prints.takes(item)) == pr2, "and nothing changed: no print again")
  prints.lacking = real_lacking
end)
if not ok then check(false, "ERROR " .. tostring(err)) end
reaper.SelectProjectInstance(p)
pcall(reaper.GetSetProjectInfo, p, "DIRTY", 0, true) -- (7.75+: closes without asking)
if reaper.IsProjectDirty(p) ~= 0 then
  reaper.Main_SaveProjectEx(p, root .. "/rt_takes.rpp", 8)
  say("NOTE this REAPER couldn't clear the scratch tab's changed flag: saved it into " .. root .. " to close it without a prompt")
end
reaper.Main_OnCommand(40860, 0)
if user and reaper.ValidatePtr2(0, user, "ReaProject*") then reaper.SelectProjectInstance(user) end
for k, v in pairs(was) do if v ~= "" then reaper.SetExtState(S, k, v, false) else reaper.DeleteExtState(S, k, false) end end
for _, m in ipairs(MODS) do package.loaded[m] = nil end
say(string.format("rt_takes: fails %d of %d", fails, #out))
return table.concat(out, "\n")
