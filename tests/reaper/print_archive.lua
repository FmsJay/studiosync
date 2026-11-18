-- Run inside REAPER (ReaScript). History trim takes old prints with it (0.58.92): a print only the archived changes named goes to the
-- archive (flac and opus); one a kept change still names stays, in this room or a side room. Scratch folders only.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "trim", "json" }) do package.loaded[m] = nil end
local band, sync, trim = require("band"), require("sync"), require("trim")
local base = D .. "/troot_parch_" .. os.time() .. "/StudioSync"
local song, room = "PrintLab", "main"
local A = { user = "James", root = base }
local events, media = sync.room_dir(A, song, room) .. "/events", sync.room_dir(A, song, room) .. "/media"
local side = sync.room_dir(A, song, "side") .. "/events"
for _, d in ipairs({ events, media, side }) do reaper.RecursiveCreateDirectory(d, 0) end
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local function p(name) return "print-" .. name .. "-James" end
local function ev(dir, id, oid, rev, day, prints)
  local state = "<ITEM\nPOSITION 0\n"
  for _, n in ipairs(prints) do state = state .. 'TAKE\n<SOURCE FLAC\nFILE "{media:main}/' .. p(n) .. '.flac"\n>\n' end
  band.write_json(dir .. "/" .. id .. ".json", { id = id, type = "obj", obj = "item", oid = oid, rev = rev, user = "James", track = "T-1",
    time = string.format("2026-01-%02dT00:00:00Z", day), state = state .. ">" })
end
local ok, err = pcall(function()
  for _, n in ipairs({ "A1", "A2", "C1", "D1", "D2", "E1", "E2" }) do
    band.write_atomic(media .. "/" .. p(n) .. ".flac", "flac " .. n)
    band.write_atomic(media .. "/" .. p(n) .. ".opus", "opus " .. n)
  end
  ev(events, "James-20260101-000000Z-1-a", "I-A", 1, 1, { "A1" })
  ev(events, "James-20260102-000000Z-2-a", "I-A", 2, 2, { "A2" })
  ev(events, "James-20260101-000000Z-3-b", "I-B", 1, 1, { "A1" }) -- (I-B's newest still plays A1)
  ev(events, "James-20260101-000000Z-4-c", "I-C", 1, 1, { "C1" })
  ev(events, "James-20260102-000000Z-5-c", "I-C", 2, 2, {})
  ev(side, "James-20260103-000000Z-6-s", "I-S", 1, 3, { "C1" }) -- (a side room's item plays the main room's C1)
  ev(events, "James-20260101-000000Z-7-d", "I-D", 1, 1, { "D1" })
  ev(events, "James-20260102-000000Z-8-d", "I-D", 2, 2, { "D2" })
  ev(events, "James-20260101-000000Z-9-e", "I-E", 1, 1, { "E1" })
  ev(events, "James-20260102-000000Z-10-e", "I-E", 2, 2, { "E2" })
  -- (the side room's copy was made while I-E played E1: no change of its own names it, its note does. lib/rooms.lua note_prints, 0.59.10)
  band.write_json(sync.room_dir(A, song, "side") .. "/plays-Laptop.json", { p("E1") })
  local n = trim.run(A, song, room, -1)
  say("trimmed " .. n)
  check(n == 4, "the four superseded changes went (a1, c1, d1, e1)")
  local archive = base:match("^(.*)/[^/]+$") .. "/StudioSync history archive/" .. song .. "/" .. room .. "/media"
  check(reaper.file_exists(archive .. "/" .. p("D1") .. ".flac") and reaper.file_exists(archive .. "/" .. p("D1") .. ".opus"), "D1, named only by d1, is in the archive (flac and opus)")
  check(not reaper.file_exists(media .. "/" .. p("D1") .. ".flac"), "and gone from the media folder")
  check(reaper.file_exists(media .. "/" .. p("A1") .. ".flac"), "A1 stays: I-B's newest change still plays it")
  check(reaper.file_exists(media .. "/" .. p("C1") .. ".flac"), "C1 stays: the side room still plays it")
  check(reaper.file_exists(media .. "/" .. p("E1") .. ".flac"), "E1 stays: the side room's copy plays it, by its note")
  check(reaper.file_exists(media .. "/" .. p("A2") .. ".flac") and reaper.file_exists(media .. "/" .. p("D2") .. ".flac"), "the newest prints stay")
  local list
  for _, f in ipairs(band.files(sync.room_dir(A, song, room) .. "/trimmed", ".json")) do if f:find("%-media%.json$") then list = band.read_json(sync.room_dir(A, song, room) .. "/trimmed/" .. f) end end
  check(type(list) == "table" and type(list.media) == "table" and #list.media == 2, "listed for the Drive copy (" .. tostring(list and list.media and #list.media) .. ")")
end)
if not ok then say("ERROR " .. tostring(err)); fails = fails + 1 end
local function rm(dir) -- (the scratch tree and its archive, gone afterwards: 0.58.93)
  for i = 0, math.huge do local s = reaper.EnumerateSubdirectories(dir, i); if not s then break end; rm(dir .. "/" .. s) end
  reaper.EnumerateFiles(dir, -1)
  local fs = {}
  for i = 0, math.huge do local f = reaper.EnumerateFiles(dir, i); if not f then break end; fs[#fs + 1] = f end
  for _, f in ipairs(fs) do os.remove(dir .. "/" .. f) end
  os.remove(dir)
end
local top = base:match("^(.*)/[^/]+$")
rm(base); rm(top .. "/StudioSync history archive/" .. song); rm(top .. "/StudioSync history archive"); os.remove(top)
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")
