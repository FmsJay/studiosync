-- rt-sync2e (docs/rt/rt-sync2e.md): grey stand-ins (mirror.placeholder: an item whose audio is still arriving) never stay for good. Lua 5.4, from
-- the repo root. Each part fails with its piece of the fix taken out.
--  1. An item lands on its stand-in while a person's copy of the stand-in is here: it lands on the stand-in at its own place, and the copy
--     becomes a copy of the landed item where the person put it, with no id (the next look gives it one and sends it as theirs). rt-sync2c's 9002.
--  2. The item's deletion lands: every stand-in carrying its id goes, the copy too.
--  3. An item recorded gone here (a deletion, or gone with its track) while a stand-in for an earlier version stands: the stand-in goes.
--  4. A deleted track's stand-in goes with the track, not onto "(yours, not sent)" with its id cleared. rt-sync2c's 15011.
--  5. StudioSync's own Undo / Redo (mirror.revert, which doesn't try again) makes no stand-in.
package.path = "lib/?.lua;tests/fixtures/?.lua;" .. package.path
local E = require("editreaper")
local band = require("band")
local files = {}
band.read_json = function(path) local v = files[path]; if type(v) == "table" then return band.json_decode(band.json_encode(v)) end end
band.write_json = function(path, v) files[path] = band.json_decode(band.json_encode(v)); return true end
band.log = function() end
band.files, band.listing = function() return {} end, function() return {} end
package.loaded.trust = { claim_ok = function() return true end }
local mirror = require("mirror")
require("prints").choose = function() end

local MEDIA = "R/Song/rooms/main/media"
local arrived = {}
local function new_song()
  local F = E.new("C:/A/Song" .. math.random(1, 1e9) .. ".rpp")
  reaper = F.reaper
  reaper.file_exists = function(p) return not p:find("%.flac$") or arrived[p] == true end
  return F
end
local function track(F, name, oid) local t = F.add_track(name); reaper.GetSetMediaTrackInfo_String(t, "P_EXT:band_oid", oid, true); return t end
local function audio(pos, file)
  return table.concat({ "<ITEM", "POSITION " .. pos, "SNAPOFFS 0", "LENGTH 2", "LOOP 0", 'NAME "take"', "SOFFS 0", "<SOURCE WAVE",
    'FILE "{media}/' .. file .. '"', ">", ">" }, "\n") .. "\n"
end
local function standins(F)
  local n = 0
  for _, it in ipairs(F.all_items()) do if (it.ext.band_arriving or "") ~= "" then n = n + 1 end end
  return n
end
local function with_id(F, oid)
  local out = {}
  for _, it in ipairs(F.all_items()) do if it.ext.band_oid == oid then out[#out + 1] = it end end
  return out
end
local function pos(it) return tonumber(E.top_value(it.text, "POSITION")) end
-- (what duplicating a stand-in leaves: its chunk, P_EXT and all, as a new item at another place)
local function copy_of(F, it, tr, at)
  local c = F.add_item(tr, (select(2, reaper.GetItemStateChunk(it, "", false))))
  reaper.SetMediaItemInfo_Value(c, "D_POSITION", at)
  return c
end
local n = 0
local function version(oid, toid, p, file, extra)
  n = n + 1
  local ev = { type = "obj", obj = "item", oid = oid, track = toid, name = "Gtr", rev = n, id = "B-20270115-080000Z-0000" .. n .. "-0001", user = "B", state = audio(p, file) }
  for k, v in pairs(extra or {}) do ev[k] = v end
  return ev
end

-- ---- 1. the item lands on its stand-in; the person's copy of it becomes theirs ---------------------------------------------------------------
do
  local F = new_song()
  local keys = track(F, "Keys", "T-A-1") -- (above Gtr: the copy comes first in the project, where mirror.find looks first)
  local gtr = track(F, "Gtr", "T-A-2")
  local ev = version("I-B-1", "T-A-2", 4, "b1.flac")
  assert(mirror.apply(F.proj, ev, MEDIA, false) == false and standins(F) == 1, "its audio isn't here: a stand-in at its place, not applied")
  local stand = with_id(F, "I-B-1")[1]
  copy_of(F, stand, keys, 20)
  assert(standins(F) == 2 and #with_id(F, "I-B-1") == 2, "the person's copy keeps the id and the mark, as REAPER copies P_EXT")
  arrived[MEDIA .. "/b1.flac"] = true
  local ok = mirror.apply(F.proj, ev, MEDIA, false)
  assert(ok, "its audio is here: applied")
  assert(standins(F) == 0, "no stand-in left (was: the copy stayed grey for good, rt-sync2c's 9002)")
  local mine = with_id(F, "I-B-1")
  assert(#mine == 1 and mine[1].track == gtr and math.abs(pos(mine[1]) - 4) < 1e-9, "the item on Gtr at its place, the only one with its id")
  local copy = keys.items[1]
  assert(copy and (copy.ext.band_oid or "") == "" and math.abs(pos(copy) - 20) < 1e-9, "the copy stays where the person put it, with no id yet")
  assert(copy.text:find('FILE "' .. MEDIA .. '/b1.flac"', 1, true), "and plays the landed item's audio")
  assert(#gtr.items == 1, "nothing doubled on Gtr (was, landing on the copy: the copy moved onto the stand-in's place)")
  -- the next look gives the copy an id of its own and it goes out as new
  local objs = mirror.scan(F.proj, "A", MEDIA, false)
  local ids = {}
  for _, o in ipairs(objs) do if o.kind == "item" then ids[#ids + 1] = o.oid end end
  assert(#ids == 2 and (keys.items[1].ext.band_oid or "") ~= "" and keys.items[1].ext.band_oid ~= "I-B-1", "a look gives the copy its own id: " .. table.concat(ids, ","))
  print("rt-sync2e 1: an item landing on its stand-in turns a person's copy of the stand-in into theirs")
end

-- ---- 2. the item's deletion lands: every stand-in carrying its id goes --------------------------------------------------------------------------
do
  local F = new_song()
  local keys, gtr = track(F, "Keys", "T-A-1"), track(F, "Gtr", "T-A-2")
  local ev = version("I-B-2", "T-A-2", 4, "b2.flac")
  mirror.apply(F.proj, ev, MEDIA, false)
  copy_of(F, with_id(F, "I-B-2")[1], keys, 20)
  assert(standins(F) == 2, "a stand-in and a copy of it")
  assert(mirror.apply(F.proj, { type = "obj", obj = "item", oid = "I-B-2", gone = true }, MEDIA, false), "the deletion applied")
  assert(standins(F) == 0 and #F.all_items() == 0, "both gone (was: the one mirror.find didn't pick stayed grey)")
  print("rt-sync2e 2: an item's deletion takes every stand-in carrying its id")
end

-- ---- 3. recorded gone here while a stand-in for an earlier version stands -----------------------------------------------------------------------
do
  local F = new_song()
  track(F, "Gtr", "T-A-2")
  mirror.apply(F.proj, version("I-B-3", "T-A-2", 4, "b3.flac"), MEDIA, false)
  assert(standins(F) == 1, "a stand-in")
  mirror.remember(F.proj, "I-B-3", 3, "", "B-20270115-090000Z-00099-0001", "")
  assert(standins(F) == 0, "the item's record says gone here: its stand-in goes (was: grey for good, 15050's late older version)")
  -- a record that holds the item doesn't touch a stand-in of another item
  mirror.apply(F.proj, version("I-B-4", "T-A-2", 8, "b4.flac"), MEDIA, false)
  mirror.remember(F.proj, "I-B-5", 1, "abc", "B-20270115-090000Z-00100-0001", "")
  assert(standins(F) == 1, "another item's record: the stand-in stays")
  print("rt-sync2e 3: an item recorded gone takes its stand-in")
end

-- ---- 4. a deleted track's stand-in goes with the track ------------------------------------------------------------------------------------------
do
  local F = new_song()
  track(F, "Keys", "T-A-1")
  track(F, "Gtr", "T-A-2")
  mirror.apply(F.proj, version("I-B-6", "T-A-2", 4, "b6.flac"), MEDIA, false)
  assert(standins(F) == 1, "a stand-in on Gtr")
  assert(mirror.apply(F.proj, { type = "obj", obj = "track", oid = "T-A-2", gone = true, user = "B" }, MEDIA, false), "Gtr's deletion applied")
  local names = {}
  for _, t in ipairs(F.tracks) do names[#names + 1] = t.name end
  assert(standins(F) == 0 and table.concat(names, ",") == "Keys", "the stand-in went with Gtr, no '(yours, not sent)' (was: kept there with its id cleared, for good): " .. table.concat(names, ","))
  print("rt-sync2e 4: a deleted track's stand-in goes with it")
end

-- ---- 5. StudioSync's own Undo / Redo makes no stand-in --------------------------------------------------------------------------------------------
do
  local F = new_song()
  track(F, "Gtr", "T-A-2")
  assert(mirror.apply(F.proj, version("I-B-7", "T-A-2", 4, "b7.flac"), MEDIA, false, true) == false and standins(F) == 0,
    "not applied, and no stand-in: an Undo doesn't try again, so it stayed grey for good (the soak's 9029)")
  print("rt-sync2e 5: StudioSync's Undo makes no stand-in")
end

print("ok rt-sync2e: stand-ins never stay grey for good")
