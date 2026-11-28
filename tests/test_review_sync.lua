-- 0.59.14 (lupa or Lua 5.4, from the repo root): sync engine review. History trimmed under a restore, timing merged as one,
-- Local mixing's faders kept home.
package.path = "lib/?.lua;" .. package.path
local mirror = require("mirror")

-- an object whose first version was trimmed away: restoring to a row before its oldest kept version leaves it, never deletes it
local T = {
  { kind = "obj", obj = "track", oid = "T-A-1-1", rev = 1, base = 0, id = "t1", state = {} }, -- (a kept snapshot row)
  { kind = "obj", obj = "item", oid = "I-A-1-2", rev = 2, base = 1, base_ev = "gone1", id = "i2", state = "x" }, -- (its rev 1 trimmed)
  { kind = "obj", obj = "item", oid = "I-A-1-2", rev = 3, base = 2, base_ev = "i2", id = "i3", state = "y" },
  { kind = "obj", obj = "item", oid = "I-B-1-3", rev = 1001, base = 0, id = "b1", state = "new" }, -- (an owner's new item: rev past 1)
}
local plan = mirror.plan_restore(T, 1)
assert(plan["I-A-1-2"] == nil, "made before the trim: left out of the plan, not deleted")
assert(plan["I-B-1-3"] == false, "an owner's new item made after: it goes, rev 1001 or not")
assert(plan["T-A-1-1"] ~= nil, "what was there then stays planned")
assert(mirror.plan_restore(T, 2)["I-A-1-2"].id == "i2", "a kept version at the row: back to it")
local undo = require("undo")
local byT = {}
for _, e in ipairs(T) do byT[e.id] = e end
local function undo_row(i) return (undo.plan(T, { i }, function(id) return byT[id] end, function() end)) end
assert(next(undo_row(2)) == nil, "undoing the oldest kept change, whose base was trimmed: nothing planned")
assert(undo_row(3)["I-A-1-2"].id == "i2", "undo with the version before still here: back to it")
assert(undo_row(4)["I-B-1-3"] == false, "undo a creation: it goes")
assert(mirror.began({ rev = 1 }) and not mirror.began({ rev = 4 }) and mirror.began({ rev = 1001, base = 0 }), "began: old events by rev, newer by base")
assert(type((undo.plan({ { kind = "edit", id = "x", time = "t" } }, { 1 }, function() end, function() end))) == "table", "an empty plan, never nil")

-- a left trim on one side, a move on the other: the winner's whole timing, not a mix of both
do
  local base = "<ITEM\nPOSITION 4\nLENGTH 2\nFADEIN 1 0 0 1 0 0 0\nMUTE 0 0\nNAME \"a\"\nSOFFS 0\nVOLPAN 1 0 1 -1\n<SOURCE WAVE\nFILE \"a.wav\"\n>\n>\n"
  local trimmed = base:gsub("POSITION 4", "POSITION 5"):gsub("LENGTH 2", "LENGTH 1"):gsub("SOFFS 0", "SOFFS 1")
  local moved = base:gsub("POSITION 4", "POSITION 8"):gsub("VOLPAN 1 0 1 %-1", "VOLPAN 2 0 1 -1")
  local m = mirror.merge_item(base, moved, trimmed, "Bee")
  assert(m:find("POSITION 8\nLENGTH 2\n", 1, true) and m:find("SOFFS 0\n", 1, true) and not m:find("SOFFS 1", 1, true), "the mover won: their timing whole")
  assert(m:find("VOLPAN 2 0 1 -1", 1, true), "what isn't timing still merges")
  local m2 = mirror.merge_item(base, trimmed, moved, "James")
  assert(m2:find("POSITION 5\nLENGTH 1\n", 1, true) and m2:find("SOFFS 1\n", 1, true) and m2:find("VOLPAN 2 0 1 -1", 1, true), "the trimmer won: their trim whole, the other's volume in")
  local louder = base:gsub("VOLPAN 1 0 1 %-1", "VOLPAN 3 0 1 -1")
  local m3, both = mirror.merge_item(base, trimmed, louder, "Bee")
  assert(m3:find("SOFFS 1\n", 1, true) and m3:find("VOLPAN 3 0 1 -1", 1, true) and #both == 0, "only one changed the timing: no clash")
end

-- Local mixing: what goes out has the band's faders and pan, not yours
do
  local mine = { name = "Keys", vol = "0.5", pan = "0.3", width = "0.2", panmode = "6", mute = 1 }
  local band = { name = "Keys", vol = "1.0", pan = "0.0", width = "1", panmode = "3", mute = 0 }
  local out = mirror.band_faders(mine, band)
  assert(out.vol == "1.0" and out.pan == "0.0" and out.width == "1" and out.panmode == "3", "the band's faders")
  assert(out.mute == 1 and out.name == "Keys" and mine.vol == "0.5", "the rest is yours, and the state itself untouched")
  assert(mirror.band_faders(mine, nil) == mine, "a track the band hasn't had: its own")
end
-- the files take plug-ins load are looked for in their blocks only, never the item's own media
do
  local st = "<ITEM\nPOSITION 0\nNAME \"a\"\n<TAKEFX\nSHOW 0\n<VST \"VSTi: ReaSamplOmatic5000\" x 0\nQUJD\n>\nFLOATPOS 0 0 0 0\n>\n<SOURCE WAVE\nFILE \"C:/a/b.wav\"\n>\n>\n"
  local fx = mirror.take_fx(st)
  assert(fx:find("^<TAKEFX\n") and fx:find("ReaSamplOmatic5000", 1, true) and fx:find("FLOATPOS", 1, true) and not fx:find("FILE", 1, true), "the take FX block whole, nothing else")
  assert(mirror.take_fx("<ITEM\nPOSITION 0\n>\n") == "", "no take FX: nothing")
end
print("ok")
