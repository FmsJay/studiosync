-- Run inside REAPER (ReaScript). An item with an empty take lane (saved as "TAKE NULL": GetTake gives nil for it), as James's Nostalgia had
-- 81 of (0.58.81: sharing it stopped at "band.lua:789: bad argument #1 to 'GetSetMediaItemTakeInfo_String'"). What sharing and Live sync do
-- with every take runs through it without an error. A scratch tab and folder only.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "prep", "recall", "prints", "json" }) do package.loaded[m] = nil end
require("prints").SETTLE = 0
local band, sync, mirror, prep, recall = require("band"), require("sync"), require("mirror"), require("prep"), require("recall")
local root = D .. "/etroot_" .. os.time()
local song, room = "EmptyLab", "main"
local A = { user = "James", root = root }
reaper.RecursiveCreateDirectory(sync.room_dir(A, song, room) .. "/events", 0)
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local function try(what, f, ...)
  local ok, err = pcall(f, ...)
  check(ok, what .. (ok and "" or (": " .. tostring(err))))
end
local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0)
local p = reaper.EnumProjects(-1)
local ok, err = pcall(function()
  reaper.InsertTrackInProject(p, 0, 0)
  local tr = reaper.GetTrack(p, 0)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Keys", true)
  local it = reaper.CreateNewMIDIItemInProj(tr, 0, 2, false)
  local _, chunk = reaper.GetItemStateChunk(it, "", false)
  chunk = chunk:gsub(">%s*$", "TAKE NULL\n>\n")
  reaper.SetItemStateChunk(it, chunk, false)
  check(reaper.CountTakes(it) == 2 and reaper.GetTake(it, 1) == nil, "an item with an empty take lane (" .. reaper.CountTakes(it) .. " takes)")
  try("band.take_ext / take_id on it", function() assert(band.take_ext(nil, "band_take") == "" and band.take_id(nil) == nil) end)
  try("set_take_ext on it does nothing", band.set_take_ext, nil, "band_take", "x")
  try("marking what's there as baseline", sync.mark_baseline, p)
  try("the take index", band.take_index, p)
  try("a note on the item", sync.mark_item, it, 0.5, "James: hi", nil)
  try("the Prepare checklist", prep.scan, p, A, nil)
  try("a restore point", recall.save, p, A, song, room, "empty takes", true)
  try("Live sync's look", function()
    band.bind(p, { role = "host", song = song, room = room, version = 1, root = root })
    for _ = 1, 3 do mirror.watch(p, A, song, room, { can = function() return true end, mode = "open" }) end
  end)
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
reaper.SelectProjectInstance(p)
reaper.Main_SaveProjectEx(p, root .. "/empty_takes.rpp", 8)
reaper.Main_OnCommand(40860, 0)
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
out[#out + 1] = fails == 0 and "ALL PASS" or (fails .. " FAILED")
return table.concat(out, "\n")
