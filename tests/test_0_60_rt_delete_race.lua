-- 0.60.0-rt (cross test, step 1): A deletes every track (and its items) in one undo block that also changes the tempo; B and C, which got the
-- tempo map first, send their re-timed parts as edits built on the version A deleted. Every computer must end the same in every arrival order:
-- the tracks and items gone, nothing kept as "(yours, not sent)", and each holding A's deletion. Fails with mirror.gone_race, the on_gone_track
-- record, the re-time check in apply or sync.receive's race check reverted. Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local exts, gext, clock = {}, {}, 1000
local function sec_of(p, sec) exts[p] = exts[p] or {}; exts[p][sec] = exts[p][sec] or {}; return exts[p][sec] end
-- a tiny REAPER: per project a list of tracks, each with its items; P_EXT on both
local projs = {}
local function P(p) projs[p] = projs[p] or { tracks = {} }; return projs[p] end
local function ext_of(o, k, v, set) o.ext = o.ext or {}; if set then o.ext[k] = v end; return true, o.ext[k] or "" end
local function all_items(p) local t = {}; for _, tr in ipairs(P(p).tracks) do for _, it in ipairs(tr.items) do t[#t + 1] = it end end; return t end
local function drop(list, x) for i, y in ipairs(list) do if y == x then table.remove(list, i); return end end end
local guid = 0
local function new_track(p, name) guid = guid + 1; local tr = { name = name, items = {}, proj = p, guid = "{" .. guid .. "}" }; table.insert(P(p).tracks, tr); return tr end
reaper = setmetatable({
  GetProjExtState = function(p, sec, k) local v = sec_of(p, sec)[k] or ""; return v ~= "" and 1 or 0, v end,
  SetProjExtState = function(p, sec, k, v) sec_of(p, sec)[k] = v end,
  EnumProjExtState = function() return false end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  DeleteExtState = function(s, k) gext[s .. "\0" .. k] = nil end,
  time_precise = function() return clock end,
  EnumProjects = function() return nil end,
  GetPlayStateEx = function() return 0 end,
  ValidatePtr2 = function() return true end,
  GetSetMediaItemInfo_String = ext_of,
  GetSetMediaTrackInfo_String = function(tr, k, v, set) if k == "P_NAME" then if set then tr.name = v end; return true, tr.name end; return ext_of(tr, k, v, set) end,
  GetTrackName = function(tr) return true, tr.name end,
  GetTrackGUID = function(tr) return tr.guid end,
  GetMediaTrackInfo_Value = function() return 0 end,
  GetMediaItemInfo_Value = function() return 0 end,
  CountTracks = function(p) return #P(p).tracks end,
  GetTrack = function(p, i) return P(p).tracks[i + 1] end,
  InsertTrackInProject = function(p) new_track(p, "") end,
  DeleteTrack = function(tr) drop(P(tr.proj).tracks, tr) end,
  CountTrackMediaItems = function(tr) return #tr.items end,
  GetTrackMediaItem = function(tr, i) return tr.items[i + 1] end,
  CountMediaItems = function(p) return #all_items(p) end,
  GetMediaItem = function(p, i) return all_items(p)[i + 1] end,
  GetMediaItem_Track = function(it) return it.track end,
  MoveMediaItemToTrack = function(it, tr) drop(it.track.items, it); it.track = tr; table.insert(tr.items, it) end,
  DeleteTrackMediaItem = function(tr, it) drop(tr.items, it) end,
  file_exists = function() return true end,
}, { __index = function() return function() end end })

local files = {}
local band = require("band")
local proxy = setmetatable({}, { __index = band })
proxy.read_json = function(path) local v = files[path]; if type(v) == "table" then local c = {}; for k, x in pairs(v) do c[k] = x end; return c end end
proxy.listing = function() return {} end
proxy.write_json = function(path, v) files[path] = v end
proxy.log = function() end
proxy.capture_tempo, proxy.capture_markers = function() return {} end, function() return {} end
package.loaded.band = proxy
local mirror = require("mirror")
local sync = require("sync")
require("direct").path = function(_, d, f) return d .. "/" .. f end
local cfg = { user = "Xa", root = "root" }
local R = sync.room_dir(cfg, "S", "main")
local MEDIA = R .. "/media"
local real_apply = mirror.apply
-- (an item edit lands as the model's item on its track; deletions go through the real apply, which is what's tested)
mirror.apply = function(proj, ev, media_dir, local_mix)
  if ev.gone or ev.obj ~= "item" then return real_apply(proj, ev, media_dir, local_mix) end
  local tr = mirror.find(proj, "track", ev.track)
  if not tr then return false end
  local it = mirror.find(proj, "item", ev.oid)
  if not it then it = { track = tr }; table.insert(tr.items, it); it.ext = { ["P_EXT:band_oid"] = ev.oid } end
  it.state = ev.state
  return true, "h:" .. ev.id
end
mirror.track_state, mirror.set_track_state, mirror.track_hash = function() return {} end, function() end, function() return "t" end -- (lanes_back)
require("prints").choose = function() end
sync.put_back = function() end

-- the events (the cross test's, in small): Al deleted the track and its item; Bo and Mac re-timed the item from the version Al deleted
local T, I = "T-AL-1-1", "I-AL-1-2"
local H0 = os.time() * 1000 - 5000 -- (Mac's re-time is "just made here": under two minutes old by its clock)
local function ev(t) t.type, t.time = "obj", "2026-11-19T17:25:58Z"; files[R .. "/events/" .. t.id .. ".json"] = t; return t end
local OLD = "<ITEM\nPOSITION 2\nLENGTH 3.69\nNAME \"d\"\n>\n"
local RETIMED = "<ITEM\nPOSITION 2.1666\nLENGTH 4\nNAME \"d\"\n>\n"
local V0 = ev({ id = "Al-20261119-171302Z-00001-0001", obj = "track", oid = T, rev = 1, base = 0, state = { name = "Drums", after = "" }, user = "Al", hlc = H0 - 9000 })
local V1 = ev({ id = "Bo-20261119-171542Z-00009-0001", obj = "item", oid = I, track = T, rev = 4, base = 3, state = OLD, user = "Bo", hlc = H0 - 8000, name = "Drums" })
local GT = ev({ id = "Al-20261119-172558Z-00003-0001", obj = "track", oid = T, rev = 2, base = 1, base_ev = V0.id, gone = true, user = "Al", hlc = H0 + 100, name = "Drums" })
local GI = ev({ id = "Al-20261119-172558Z-00005-0001", obj = "item", oid = I, track = T, rev = 5, base = 4, base_ev = V1.id, gone = true, user = "Al", hlc = H0 + 110, name = "Drums" })
local EC = ev({ id = "Mac-20261119-172558Z-00001-0001", obj = "item", oid = I, track = T, rev = 5, base = 4, base_ev = V1.id, state = RETIMED, user = "Mac", hlc = H0 + 120, name = "Drums" })
local EB = ev({ id = "Bo-20261119-172558Z-00001-0001", obj = "item", oid = I, track = T, rev = 5, base = 4, base_ev = V1.id, state = RETIMED, user = "Bo", hlc = H0 + 700, name = "Drums" })

-- the race rule itself
assert(mirror.gone_race(R, GI, EB) == true and mirror.gone_race(R, EB, GI) == false, "the deletion beats a later edit that didn't see it")
assert(mirror.gone_race(R, EB, EC) == nil and mirror.gone_race(R, GT, EB) == nil, "two edits, or a track and an item: no such race")
local RESTORE = { id = "Al-20261119-172700Z-00009-0001", obj = "item", oid = I, track = T, rev = 6, base = 5, base_ev = GI.id, state = OLD, user = "Al", hlc = H0 + 2000 }
assert(mirror.gone_race(R, RESTORE, GI) == true, "an edit built on the deletion (a restore) beats it")
assert(mirror.settled(R, EB, { V1, GI, EC, EB }).id == GI.id, "heal settles on the deletion, not the newest edit")
assert(mirror.settled(R, RESTORE, { V1, GI, EC, EB, RESTORE }).id == RESTORE.id, "and on a restore after it")

local function permutations(list)
  local out = {}
  local function go(a, n)
    if n <= 1 then local c = {}; for i, x in ipairs(a) do c[i] = x end; out[#out + 1] = c; return end
    for i = 1, n do a[i], a[n] = a[n], a[i]; go(a, n - 1); a[i], a[n] = a[n], a[i] end
  end
  go(list, #list)
  return out
end
local runs = 0
local function remember(p, e, h) mirror.remember(p, e.oid, e.rev, h, e.id, mirror.order_of(e)) end
-- what a computer ends with: its tracks (local ones included), its items, and the record of the item
local function shape(p)
  local names, n = {}, 0
  for _, tr in ipairs(P(p).tracks) do names[#names + 1] = tr.name; n = n + #tr.items end
  local _, kh, kev = mirror.known(p, I)
  return table.concat(names, ",") .. " | items " .. n .. " | " .. tostring(kev) .. (kh == "" and " gone" or " here")
end
local function start(user, holds_track, item_ev)
  runs = runs + 1
  local p = "P" .. runs
  gext[band.SECTION .. "\0user"] = user
  if holds_track then
    local tr = new_track(p, "Drums"); tr.ext = { ["P_EXT:band_oid"] = T }; remember(p, V0, "t")
    if item_ev then table.insert(tr.items, { track = tr, state = item_ev.state, ext = { ["P_EXT:band_oid"] = I } }); remember(p, item_ev, "h:" .. item_ev.id) end
  else remember(p, GT, ""); remember(p, GI, "") end
  return p
end
local WANT = " | items 0 | " .. GI.id .. " gone"
local function check(who, user, holds, item_ev, arriving)
  for _, order in ipairs(permutations(arriving)) do
    local p = start(user, holds, item_ev)
    local ids = {}
    for _, e in ipairs(order) do ids[#ids + 1] = e.id:match("^(%a+)") .. (e.gone and "-del" or "-edit"); assert(mirror.receive(p, e, MEDIA, false, user) ~= false, who .. ": nothing waits") end
    local s = shape(p)
    assert(s == WANT, who .. " after " .. table.concat(ids, " ") .. ": " .. s)
  end
end
check("a third computer", "Xa", true, V1, { GT, GI, EC, EB })
check("Mac, which re-timed it", "Mac", true, EC, { GT, GI, EB })
check("Bo, which re-timed it", "Bo", true, EB, { GT, GI, EC })
check("Al, which deleted it", "Al", false, nil, { EC, EB })

-- a real edit of yours just sent (not a re-time) still goes to "(yours, not sent)" when the track's deletion didn't see it
do
  local MINE = ev({ id = "Mac-20261119-172558Z-00002-0001", obj = "item", oid = I, track = T, rev = 5, base = 4, base_ev = V1.id, state = OLD:gsub("NAME \"d\"", "NAME \"take 2\""), user = "Mac", hlc = H0 + 130 })
  local p = start("Mac", true, MINE)
  mirror.receive(p, GT, MEDIA, false, "Mac")
  assert(shape(p):find("^Drums %(yours, not sent%) | items 1"), "a just-sent take is kept: " .. shape(p))
end

-- all of it arriving in one pass: the deletion isn't counted as older news than the newer edits
do
  local p = start("Xa", true, V1)
  local list = {}
  for _, e in ipairs({ GT, GI, EC, EB }) do list[#list + 1] = e.id .. ".json" end
  proxy.listing = function(d) if d == R .. "/events" then return list end; return {} end
  sync.receive(p, cfg, "S", "main", function() return true end)
  proxy.listing = function() return {} end
  assert(shape(p) == WANT, "one pass: " .. shape(p))
end
print("ok")
