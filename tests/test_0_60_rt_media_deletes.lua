-- Deleted recordings stay deleted (lib/drive.lua media_deletes; VM test, rt: four unused WAVs deleted from a room's media came back from the
-- cloud copy, which copies whatever's missing on either side). drive.mirror between two stand-in folders (a studio folder and its cloud copy, in
-- memory), both ways: a delete here is written down (a tombstone) and the cloud's copy goes to its _trash/media; a tombstone that came from
-- another computer keeps the cloud's file from coming back here; a file that's only missing (never deleted) is still filled in, either way; a
-- file the song still plays (in this room or another) is never taken as deleted, nor one tombstoned and played again; nothing local is removed.
package.path = "lib/?.lua;" .. package.path
local fs, logs, clock = {}, {}, 1000
local function kids(dir, want_dirs)
  local out, seen = {}, {}
  for p in pairs(fs) do
    local rest = p:sub(1, #dir + 1) == dir .. "/" and p:sub(#dir + 2)
    if rest then
      local first, more = rest:match("^([^/]+)(/?)")
      if first and (more == "/") == want_dirs and not seen[first] then seen[first] = true; out[#out + 1] = first end
    end
  end
  table.sort(out)
  return out
end
local function copy_of(v) if type(v) ~= "table" then return v end local t = {}; for k, x in pairs(v) do t[k] = copy_of(x) end; return t end
local band = {
  SECTION = "StudioSync",
  files = function(dir, ext) local out = {}; for _, f in ipairs(kids(dir, false)) do if not ext or f:sub(-#ext) == ext then out[#out + 1] = f end end; return out end,
  subdirs = function(dir) return kids(dir, true) end,
  read_json = function(p) return type(fs[p]) == "table" and copy_of(fs[p]) or nil end,
  write_json = function(p, t) fs[p] = copy_of(t) end,
  size = function(p) local v = fs[p]; return v ~= nil and (type(v) == "string" and #v or 1) or nil end,
  copy_atomic = function(a, z) assert(fs[a] ~= nil, "copied from nowhere: " .. a); fs[z] = copy_of(fs[a]) end,
  copy_background = function(a, z) fs[z] = copy_of(fs[a]) end,
  log = function(s) logs[#logs + 1] = s end,
  home = function() return "/home" end,
}
package.loaded.band = band
reaper = setmetatable({
  time_precise = function() return clock end,
  file_exists = function(p) return fs[p] ~= nil end,
  EnumerateFiles = function(dir, i) return band.files(dir)[i + 1] end,
}, { __index = function() return function() end end })
local real_remove, real_rename = os.remove, os.rename
os.remove = function(p) if fs[p] == nil then return nil, "no such file" end fs[p] = nil; return true end
os.rename = function(a, z) if fs[a] == nil or fs[z] ~= nil then return nil, "can't" end fs[z], fs[a] = fs[a], nil; return true end
local drive = require("drive")

local HERE, THERE = "/S/Song/rooms/main", "/C/Song/rooms/main"
local function ev(user, n, oid, files, gone)
  local id = string.format("%s-20261120-01%02d00Z-%05d-1000", user, n, n)
  local state
  if files then
    local lines = {}
    for _, f in ipairs(files) do lines[#lines + 1] = 'FILE "{media:' .. f[1] .. '}/' .. f[2] .. '"' end
    state = "<ITEM\n" .. table.concat(lines, "\n") .. "\n>"
  end
  return { type = "obj", obj = "item", oid = oid, id = id, user = user, time = string.format("2026-11-20T01:%02d:00Z", n), state = state, gone = gone or nil }, id
end
local function put_ev(dir, e) fs[dir .. "/events/" .. e.id .. ".json"] = e end
local function pass() clock = clock + 60; drive.listed = {}; return drive.mirror(HERE, THERE, 5, "James") end
local function check(cond, what) if not cond then os.remove, os.rename = real_remove, real_rename; error(what, 2) end end
local function here(f) return fs[HERE .. "/media/" .. f] end
local function cloud(f) return fs[THERE .. "/media/" .. f] end
local function tombs(dir) local t = {}; for _, f in ipairs(band.files(dir .. "/deleted", ".json")) do t[#t + 1] = f end; return t end

-- the song: a.wav and c.wav played; b.wav played once, its item since deleted; d.wav never used; i.wav played from a side room; e.wav James's,
-- deleted on Bo's computer (its item gone); h.wav deleted once and played again
put_ev(HERE, (ev("James", 1, "I1", { { "main", "a.wav" } })))
put_ev(HERE, (ev("James", 2, "I2", { { "main", "b.wav" } })))
put_ev(HERE, (ev("James", 3, "I2", nil, true)))
put_ev(HERE, (ev("Bo", 4, "I3", { { "main", "c.wav" } })))
put_ev(HERE, (ev("James", 5, "I5", { { "main", "e.wav" } })))
put_ev(HERE, (ev("Bo", 6, "I5", nil, true)))
put_ev(HERE, (ev("James", 7, "I7", { { "main", "h.wav" } })))
fs["/S/Song/rooms/side/events/x.json"] = (ev("Bo", 8, "S1", { { "main", "i.wav" } }))
for _, f in ipairs({ "a.wav", "b.wav", "c.wav", "d.wav", "i.wav" }) do fs[HERE .. "/media/" .. f], fs[THERE .. "/media/" .. f] = "audio " .. f, "audio " .. f end

-- the first pass: nothing deleted, only what this computer saw is noted (outside the shared folder)
pass()
check(#tombs(HERE) == 0 and #tombs(THERE) == 0, "nothing deleted yet: no tombstone")
check(fs["/home/cloud-media-seen.json"] and #fs["/home/cloud-media-seen.json"][HERE:lower()] == 5, "what's in the room's media noted, in StudioSync's home")

-- ---- this way: deleted here -> written down, the cloud's copy to its _trash, never brought back ----
fs[HERE .. "/media/b.wav"], fs[HERE .. "/media/d.wav"] = nil, nil -- (unused: a delete to keep)
fs[HERE .. "/media/a.wav"], fs[HERE .. "/media/i.wav"] = nil, nil -- (played here, and from the side room: not one)
pass()
local t = tombs(HERE)
check(#t == 1 and t[1]:match("^James%-%d+%-%d+Z%-%d+%.json$"), "one tombstone, named for whoever wrote it (theirs to put in the cloud copy): " .. tostring(t[1]))
local names = fs[HERE .. "/deleted/" .. t[1]].names
check(names["b.wav"] and names["d.wav"] and not names["a.wav"] and not names["i.wav"], "the unused ones, each with when")
check(not here("b.wav") and not here("d.wav"), "not brought back from the cloud copy")
check(not cloud("b.wav") and not cloud("d.wav") and fs[THERE .. "/_trash/media/b.wav"] == "audio b.wav" and fs[THERE .. "/_trash/media/d.wav"],
  "the cloud's copies moved into its _trash/media (kept, not deleted)")
check(here("a.wav") == "audio a.wav" and here("i.wav") == "audio i.wav", "still played (here, or in another room): brought back as before")
local said = table.concat(logs, "\n")
check(said:find("a.wav was deleted from main's recordings here, but the project still plays it: not taken as deleted", 1, true) and said:find("2 recordings deleted from main's media", 1, true),
  "both said: " .. said)
pass()
check(#tombs(THERE) == 1 and fs[THERE .. "/deleted/" .. t[1]], "the tombstone goes to the cloud copy, for the computers that only meet there")
check(not here("b.wav") and not here("d.wav") and #tombs(HERE) == 1, "and nothing comes back, nor is it written down twice")

-- ---- the other way: deleted on Bo's computer -> its tombstone arrives through the cloud copy, the cloud's file isn't brought here ----
fs[THERE .. "/deleted/Bo-20261120-020000Z-1.json"] = { names = { ["e.wav"] = 1795140000, ["h.wav"] = 1795140000, ["e2.wav"] = 1795140000 }, by = "Bo" }
fs[THERE .. "/media/e.wav"] = "audio e.wav" -- (James's recording: Bo's computer leaves the cloud's copy to his)
fs[THERE .. "/media/f.wav"] = "audio f.wav" -- (only missing here: never deleted)
fs[THERE .. "/media/h.wav"] = "audio h.wav" -- (deleted once, but its item still plays it)
fs[HERE .. "/media/e2.wav"] = "audio e2.wav" -- (still here: Syncthing hasn't carried Bo's delete yet)
fs[HERE .. "/media/g.wav"] = "audio g.wav" -- (made here, not in the cloud yet)
put_ev(HERE, (ev("James", 9, "I9", { { "main", "g.wav" } })))
pass()
check(fs[HERE .. "/deleted/Bo-20261120-020000Z-1.json"], "Bo's tombstone came from the cloud copy (before the recordings)")
check(not here("e.wav") and not cloud("e.wav") and fs[THERE .. "/_trash/media/e.wav"], "e.wav not brought back; his computer moves the cloud's copy to _trash")
check(here("f.wav") == "audio f.wav", "only missing, never deleted: filled in from the cloud copy")
check(cloud("g.wav") == "audio g.wav", "and the other way: his new recording goes up")
check(here("h.wav") == "audio h.wav", "tombstoned, but the song plays it again: brought here")
check(here("e2.wav") == "audio e2.wav" and not cloud("e2.wav"), "tombstoned and still here: not sent up, and not removed here (Syncthing carries deletes)")

-- ---- an empty media folder (not there just now): nothing taken as deleted ----
local nt = #tombs(HERE)
for _, f in ipairs(band.files(HERE .. "/media")) do fs[HERE .. "/media/" .. f] = nil end
local in_cloud = #band.files(THERE .. "/media")
pass()
check(#tombs(HERE) == nt and #band.files(THERE .. "/media") == in_cloud and #band.files(THERE .. "/_trash/media") == 3, "an emptied folder writes no tombstone and moves nothing in the cloud")

-- ---- which files the song plays (pure) ----
check(drive.media_in_use({ main = { { oid = "A", time = "1", id = "x", media = { { "main", "p.wav" } } }, { oid = "A", time = "2", id = "y", gone = true } },
  side = { { oid = "B", time = "1", id = "z", media = { { "main", "q.wav" }, { "side", "r.wav" } } } } }, "main")["q.wav"],
  "media_in_use: the newest change to each item, in every room, for this room's files")
local u = drive.media_in_use({ main = { { oid = "A", time = "1", id = "x", media = { { "main", "p.wav" } } }, { oid = "A", time = "2", id = "y", gone = true } } }, "main")
check(not u["p.wav"], "an item deleted since doesn't keep its file played")

os.remove, os.rename = real_remove, real_rename
print("ok media deletes: tombstones both ways, cloud _trash, fill-in kept, played files kept")
