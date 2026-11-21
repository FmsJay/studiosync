-- rt-perfcut2 (docs/rt/rt-perfcut2.md): real MIDI pools, the full look's interval, a look's writes counted, mirror.root held.
-- Unit checks only; the bigproj read-count test is still to write (see the doc's "Left").
package.path = "lib/?.lua;" .. package.path
local clock, cc, pext = 1000, 1, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetProjectStateChangeCount = function() return cc end,
  SetProjExtState = function(_, s, k, v) pext[#pext + 1] = { k, v } end,
  EnumProjExtState = function(_, s, i) local e = pext[i + 1]; if e then return true, e[1], e[2] end return false end,
  SetItemStateChunk = function() return true end,
  GetSetMediaItemInfo_String = function() return true, "" end,
}, { __index = function() return function() end end })
local mirror = require("mirror")

-- 1. pools: a GUID two items hold is a pool; REAPER's POOLEDEVTS on every MIDI item alone isn't
local a = mirror.pool_ids("<TRACK\n<ITEM\nPOOLEDEVTS {a1}\n>\n<ITEM\nPOOLEDEVTS {b1}\n>\n>\n")
local b = mirror.pool_ids("<TRACK\n<ITEM\nPOOLEDEVTS {B1}\n>\n<ITEM\nPOOLEDEVTS {c1}\n>\n>\n")
local c = mirror.pool_ids("<TRACK\n<ITEM\nPOOLEDEVTS {d1}\n>\n<ITEM\nPOOLEDEVTS {d1}\n>\n>\n")
assert(mirror.pool_ids("<TRACK\n>\n") == nil and a["{A1}"] == 1 and c["{D1}"] == 2, "pool ids, counted per item")
local sh = mirror.shared_pools({ a, b, c })
assert(sh["{B1}"] and sh["{D1}"] and not sh["{A1}"] and not sh["{C1}"], "shared across tracks and within one; unique GUIDs aren't pools")
assert(mirror.in_pool(a, sh) and not mirror.in_pool(mirror.pool_ids("POOLEDEVTS {z}\n"), sh) and not mirror.in_pool(nil, sh), "in_pool")

-- 2. the full look's interval follows its cost, between QUICK_FULL_SECS and QUICK_FULL_MAX
assert(mirror.full_every(nil) == 60 and mirror.full_every(0.015) == 60, "a small song: every minute")
assert(math.abs(mirror.full_every(0.35) - 175) < 1e-9, "a heavy song's 350 ms: 0.2 % of the main thread")
assert(mirror.full_every(3) == 300, "never further apart than the ceiling")

-- 3. a look's writes are counted; reads and records aren't, and the writers are put back
local real_set = reaper.SetItemStateChunk
local wrote, x, y = mirror.counting_writes(function(p, q)
  reaper.GetSetMediaItemInfo_String(1, "GUID", "", false)
  reaper.GetSetMediaItemInfo_String(1, "P_EXT:band_oid", "I-1", true)
  reaper.SetProjExtState(0, "s", "k", "v")
  return p, q
end, 4, 5)
assert(wrote == false and x == 4 and y == 5, "reads, P_EXT notes and records: no write, results passed on")
assert(mirror.counting_writes(function() reaper.SetItemStateChunk(1, "x", false) end) == true, "a chunk set: a write")
assert(mirror.counting_writes(function() reaper.GetSetMediaItemInfo_String(1, "P_NAME", "n", true) end) == true, "a GetSet with set true: a write")
assert(reaper.SetItemStateChunk == real_set, "the writers are put back")
assert(not pcall(mirror.counting_writes, function() reaper.SetItemStateChunk(1, "x", false); error("boom") end) and reaper.SetItemStateChunk == real_set,
  "an error is raised again, the writers put back")

-- 4. mirror.root is held until the change count moves, a record is written here, or ROOT_HOLD passes
pext[1] = { "I-1", "1|h1|ev1" }
local r1 = mirror.root("P")
pext[2] = { "I-2", "1|h2|ev2" } -- (another script's record: no count, no write here)
assert(mirror.root("P") == r1, "held between passes")
clock = clock + mirror.ROOT_HOLD
local r2 = mirror.root("P")
assert(r2 ~= r1, "read again past ROOT_HOLD")
pext[3] = { "I-3", "1|h3|ev3" }; cc = cc + 1
local r3 = mirror.root("P")
assert(r3 ~= r2, "read again when the change count moves")
mirror.remember("P", "I-4", 1, "h4", "ev4", "o")
assert(mirror.root("P") ~= r3, "read again when this script writes a record")
print("ok rt-perfcut2")
