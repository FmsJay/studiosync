-- sync.claims_files (lib/sync.lua): the claims files sync.authority reads each pass and each second, cached by size and modified time.
-- Authority decides who may change what, so every change must show on the next call: a claim added, removed and changed (even the same size
-- in the same second), and a read that failed isn't kept. (James, rt)
package.path = "lib/?.lua;" .. package.path
local clock = 1000
local files = {} -- name -> { text, mt }: the claims folder
local function enum(dir, i)
  if i < 0 or not dir:match("claims$") then return nil end
  local names = {}
  for k in pairs(files) do names[#names + 1] = k end
  table.sort(names)
  return names[i + 1]
end
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  EnumerateFiles = enum,
  JS_File_Stat = function(path)
    local e = files[path:match("[^/]+$")]
    if not e or not path:match("claims/") then return -1 end
    return 0, #e.text, "", e.mt
  end,
}, { __index = function() return function() end end })
local band = require("band")
local reads, busy = 0, {}
band.read_json = function(path)
  reads = reads + 1
  local name = path:match("[^/]+$")
  local e = files[name]
  if not e or busy[name] then return nil end
  return band.json_decode(e.text)
end
local sync = require("sync")
local function at(ago) return os.date("%Y-%m-%d %H:%M:%S", os.time() - ago) end
local function claims(user, tracks) return band.json_encode({ user = user, time = "2026-11-19T10:00:00Z", tracks = tracks }) end
local function get()
  clock = clock + 1 -- (past band.listing's own fraction of a second)
  local out = {}
  for _, fc in ipairs(sync.claims_files("root/S/rooms/main/claims")) do out[fc[1]] = fc[2] or false end
  return out
end

files["Bo.json"] = { text = claims("Bo", { "Bass" }), mt = at(600) }
local r = get()
assert(r["Bo.json"].tracks[1] == "Bass" and reads == 1, "read once")
r = get()
assert(r["Bo.json"].tracks[1] == "Bass" and reads == 1, "unchanged and settled: not read again")

-- added
files["James.json"] = { text = claims("James", { "Vox" }), mt = at(0) }
r = get()
assert(r["James.json"].tracks[1] == "Vox" and r["Bo.json"] and reads == 2, "a new file: read; the old one still from cache")
-- (a file written seconds ago is read every time: a same-size write in that second would carry the same time)
files["James.json"].text = claims("James", { "Gtr" })
r = get()
assert(r["James.json"].tracks[1] == "Gtr", "same size, same second: still seen")

-- changed: a new time, or a new size
files["Bo.json"] = { text = claims("Bo", { "Keys" }), mt = at(500) }
r = get()
assert(r["Bo.json"].tracks[1] == "Keys", "same size, another time: read again")
files["Bo.json"] = { text = claims("Bo", { "Keys", "Pad" }), mt = at(500) }
r = get()
assert(#r["Bo.json"].tracks == 2, "another size, the same time: read again")

-- removed
files["Bo.json"] = nil
r = get()
assert(r["Bo.json"] == nil and r["James.json"], "a removed file: gone at once")
files["Bo.json"] = { text = claims("Bo", { "Bass" }), mt = at(600) }
r = get()
assert(r["Bo.json"].tracks[1] == "Bass", "and back: read again, not the old entry")

-- a read that failed (the file busy) isn't kept
files["Sam.json"] = { text = claims("Sam", { "Drums" }), mt = at(600) }
busy["Sam.json"] = true
r = get()
assert(r["Sam.json"] == false, "busy: nothing this time")
busy["Sam.json"] = nil
r = get()
assert(r["Sam.json"].tracks[1] == "Drums", "and read on the next call, not remembered as nothing")

-- a release over the direct link (rt-linkmove3): its copy is read in place of the settled, unchanged folder file, at once, and isn't kept
-- under that file's size and time; once Syncthing's copy lands, the cache works as before
do
  local linked = {} -- name -> text: the link's copy, read in place of the folder's file
  local real_read, real_overlay = band.read_json, band.overlay_of
  band.read_json = function(path) local l = linked[path:match("[^/]+$")]; if l then reads = reads + 1; return band.json_decode(l) end; return real_read(path) end
  band.overlay_of = function(path) return linked[path:match("[^/]+$")] and {} or nil end
  files["Bee.json"] = { text = claims("Bee", { "Keys", "Horns" }), mt = at(600) }
  get()
  r = get()
  assert(r["Bee.json"].tracks[2] == "Horns", "(settled and cached)")
  linked["Bee.json"] = claims("Bee", { "Keys" })
  r = get()
  assert(#r["Bee.json"].tracks == 1, "a release that arrives as a link copy over a settled claims file shows at once")
  r = get()
  assert(#r["Bee.json"].tracks == 1, "and still while it's the copy: never the folder file's cached words")
  linked["Bee.json"] = nil
  files["Bee.json"] = { text = claims("Bee", { "Keys" }), mt = at(590) } -- (Syncthing's copy: the link's is let go)
  get()
  files["Bee.json"].text = claims("Bee", { "Keyz" }) -- (unchanged size and time: a settled entry is the cache's, not read again)
  r = get()
  assert(r["Bee.json"].tracks[1] == "Keys", "Syncthing's copy landed: cached as before")
  band.read_json, band.overlay_of = real_read, real_overlay
  files["Bee.json"] = nil
  get()
end

-- without js_ReaScriptAPI: read every time, as before
reaper.JS_File_Stat = nil
local n = reads
get()
assert(reads == n + 3, "no stat: every file read (" .. (reads - n) .. ")")
print("ok")
