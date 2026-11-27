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
  ValidatePtr2 = function(p, x, kind)
    if kind ~= "MediaTrack*" then return true end
    if x == P(p).master then return true end
    for _, tr in ipairs(P(p).tracks) do if tr == x then return true end end
    return false
  end,
  GetMasterTrack = function(p) P(p).master = P(p).master or { name = "MASTER", items = {}, proj = p, guid = "{m" .. tostring(p) .. "}" }; return P(p).master end,
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
local logged = {}
proxy.log = function(t) logged[#logged + 1] = t end
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

-- the race rule itself (the judge's step 3 since rt-sync2b: lib/judge.lua; was mirror.gone_race)
local judge, rd = require("judge"), mirror.reader(R)
local function settle(list) return judge.settled(list, rd, { mergeable = mirror.mergeable }) end
assert(settle({ GI, EB }).v == GI and settle({ EB, GI }).v == GI, "the deletion beats a later edit that didn't see it, in either order")
assert(not settle({ EB, EC }).gone and settle({ GT }).v == GT, "two edits merge (no deletion between them); a track's deletion is its own object")
local RESTORE = { id = "Al-20261119-172700Z-00009-0001", obj = "item", oid = I, track = T, rev = 6, base = 5, base_ev = GI.id, state = OLD, user = "Al", hlc = H0 + 2000 }
assert(settle({ RESTORE, GI }).v == RESTORE, "an edit built on the deletion (a restore) beats it")
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

-- the live run's orders by name (all in the permutations above too): on the Mac, the track's deletion, then Bo's re-time on the deleted track,
-- then the item's deletion; on the laptop, its re-time merged with the Mac's ("both changes are kept"), then the track and item deletions
local function run(user, item_ev, order)
  local p = start(user, true, item_ev)
  for _, e in ipairs(order) do mirror.receive(p, e, MEDIA, false, user) end
  return p
end
assert(shape(run("Mac", EC, { GT, EB, GI })) == WANT, "Mac: track deleted, Bo's edit, item deleted")
do
  local p = start("Bo", true, EB)
  mirror.receive(p, EC, MEDIA, false, "Bo")
  local _, _, kev = mirror.known(p, I)
  assert(kev == mirror.merge_id(EB.id, EC.id) and mirror.just_made_here(p, I) and mirror.only_retimed(p, I, R), "Bo holds the merge, its own, and a re-time only")
  for _, e in ipairs({ GT, GI }) do mirror.receive(p, e, MEDIA, false, "Bo") end
  assert(shape(p) == WANT, "Bo: merged re-times, then the deletions: " .. shape(p))
end

-- rt-sync2b: a track's deletion names the items that went with it (`items`, rt-sync2 section 1). An item of yours the deleter never saw (not
-- named there, every version yours) is kept on "(yours, not sent)" however old it is; one it names goes, however new. Without the list (an
-- older StudioSync's deletion), the old guess: yours and from the last two minutes. Fails with apply's track deletion as it was (the guess
-- for every deletion: the old item lost, the named one kept).
do
  local function make(id, oid, label, hlc) return ev({ id = id, obj = "item", oid = oid, track = T, rev = 1, base = 0, state = OLD:gsub('NAME "d"', 'NAME "' .. label .. '"'), user = "Xa", hlc = hlc }) end
  local OLD_MINE = make("Xa-20261119-170000Z-00001-0001", "I-XA-1", "mine, ten minutes old", H0 - 600000)
  local NEW_MINE = make("Xa-20261119-172557Z-00002-0001", "I-XA-2", "mine, just made", H0 - 1000)
  local function on_track(items_field)
    local GN = { id = "Al-20261119-172600Z-0000" .. (items_field and "7" or "8") .. "-0001", type = "obj", obj = "track", oid = T, rev = 2, base = 1, base_ev = V0.id,
      gone = true, user = "Al", hlc = H0 + 300, name = "Drums", items = items_field }
    files[R .. "/events/" .. GN.id .. ".json"] = GN
    local p = start("Xa", true, nil)
    local tr = P(p).tracks[1]
    for _, e in ipairs({ OLD_MINE, NEW_MINE }) do
      table.insert(tr.items, { track = tr, state = e.state, ext = { ["P_EXT:band_oid"] = e.oid } })
      remember(p, e, "h:" .. e.id)
    end
    assert(mirror.receive(p, GN, MEDIA, false, "Xa") ~= false, "the deletion lands")
    local kept = {}
    for _, t in ipairs(P(p).tracks) do
      for _, it in ipairs(t.items) do kept[#kept + 1] = (it.state:match('NAME "([^"]+)"')) .. " on " .. t.name end
    end
    table.sort(kept)
    return table.concat(kept, "; ")
  end
  local got = on_track({ "I-XA-2" })
  assert(got == "mine, ten minutes old on Drums (yours, not sent)", "named: the deleter saw I-XA-2 and it goes; I-XA-1 it never saw stays yours: " .. got)
  got = on_track({})
  assert(got == "mine, just made on Drums (yours, not sent); mine, ten minutes old on Drums (yours, not sent)", "it held nothing the deleter knew: both stay yours: " .. got)
  got = on_track(nil)
  assert(got == "mine, just made on Drums (yours, not sent)", "no list (an older StudioSync): the two-minute guess, as before: " .. got)
  -- bandmate data: a malformed list is no list
  assert(mirror.named_items({ items = { "I-1", "../x" } }) == nil and mirror.named_items({ items = { 5 } }) == nil, "a list with a path or a number: ignored")
  local big = {}
  for i = 1, mirror.ITEMS_MAX + 1 do big[i] = "I-" .. i end
  assert(mirror.named_items({ items = big }) == nil and mirror.named_items({ items = { "i-a" } })["I-A"], "past ITEMS_MAX: ignored; ids upper-cased")
end

-- the tempo map that came with the delete-all stays: deleting the first track isn't a file opened again, so the timeline's "opened behind the song"
-- look (which takes session.json's tempo, still the old one while Syncthing brings the new) doesn't run again. Live run 20261119-174839Z: B and
-- C both had 130 back after A's 120, and step 1 was never seen. A file opened again in the same tab (a new master track) still gets the look.
do
  local p = start("Bo", true, V1)
  local w = { proj = p, objs = {}, sync = sync }
  sync.timeline_looked[p] = true
  mirror.W.order(w)
  table.remove(P(p).tracks, 1) -- (the band's delete-all landed)
  mirror.W.order(w)
  assert(sync.timeline_looked[p] == true, "a deleted first track: no second 'behind the song' look")
  P(p).master = nil -- (the file opened again: a new master track)
  mirror.W.order(w)
  assert(sync.timeline_looked[p] == nil, "a file opened again: looked at again")
end

-- a real edit of yours just sent (not a re-time) of the band's item, which the track's deletion didn't see: it goes with the track, as a deletion
-- beats an edit made without seeing it (rt-fix6a, rt-linkmove round 5 C; it went to "(yours, not sent)" before). New work of yours is kept:
-- tests/test_0_60_rt_fix6a.lua
do
  local MINE = ev({ id = "Mac-20261119-172558Z-00002-0001", obj = "item", oid = I, track = T, rev = 5, base = 4, base_ev = V1.id, state = OLD:gsub("NAME \"d\"", "NAME \"take 2\""), user = "Mac", hlc = H0 + 130 })
  local p = start("Mac", true, MINE)
  mirror.receive(p, GT, MEDIA, false, "Mac")
  assert(not shape(p):find("yours, not sent", 1, true), "a just-sent edit of the band's item goes with the track: " .. shape(p))
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

-- the log: an edit dropped on a deleted track isn't "<who>: changed an item on X" (the Mac's log said Bo's re-times landed; they never did)
do
  local p = start("Xa", true, V1)
  local list = { GT.id .. ".json", EB.id .. ".json" }
  proxy.listing = function(d) if d == R .. "/events" then return list end; return {} end
  logged = {}
  sync.receive(p, cfg, "S", "main", function() return true end)
  proxy.listing = function() return {} end
  local text = table.concat(logged, "\n")
  assert(text:find("Al: deleted a track on Drums", 1, true) and not text:find("Bo: changed", 1, true), "only what landed is logged:\n" .. text)
end

-- the timeline's "opened behind the song" look against session.json, which Syncthing brings seconds after the direct link brought the map
do
  local tempo
  local real = { capture_tempo = proxy.capture_tempo, session_path = proxy.session_path }
  proxy.capture_tempo = function() return tempo end
  proxy.apply_tempo = function(_, t) tempo = t end
  proxy.apply_markers, proxy.apply_project, proxy.capture_project = function() end, function() end, function() return {} end
  proxy.session_path = function() return "SESSION" end
  local real_resnap, real_follow = sync.resnap, sync.audio_follow_tempo
  sync.resnap, sync.audio_follow_tempo = function() end, function() end
  local T130, T120 = { { time = 0, bpm = 130, num = 4, denom = 4, linear = false } }, { { time = 0, bpm = 120, num = 4, denom = 4, linear = false } }
  local A1, A2 = "2026-11-19T17:30:00ZJames-A1", "2026-11-19T17:49:17ZJames-A2"
  local function bpm() return tempo[1].bpm end
  local function opened(p, t, newest, session) -- (a project as it was saved, and the session.json this computer has)
    tempo = t
    reaper.SetProjExtState(p, sync.NEWEST, "timeline", newest)
    reaper.SetProjExtState(p, band.SECTION, "timeline", sync.timeline_sig(p))
    files.SESSION = session
    sync.timeline_looked[p] = nil
    if sync.timeline_live then sync.timeline_live[p] = nil end
  end
  -- open with everything current, then A's 120 lands over the link while session.json still says 130 (stamped, or written before rt)
  for _, stamp in ipairs({ A1, false }) do
    opened("PT", T130, A1, { tempo = T130, markers = {}, timeline_order = stamp or nil })
    sync.watch_timeline("PT", cfg, "S", "main", function() return false end)
    assert(sync.apply("PT", { type = "timeline", tempo = T120, markers = {}, project = {} }, R) and bpm() == 120, "the map landed")
    reaper.SetProjExtState("PT", sync.NEWEST, "timeline", A2) -- (sync.receive's stamp)
    sync.timeline_looked.PT = nil -- (as any later first look: the delete-all, before W.order's master-track check)
    sync.watch_timeline("PT", cfg, "S", "main", function() return false end)
    assert(bpm() == 120, "the newer map stays, session.json " .. (stamp and "stamped" or "unstamped") .. " and behind")
  end
  -- a real reopen of a save from before the last map, session.json already newer: put back as the studio has it
  opened("PR", T130, A1, { tempo = T120, markers = {}, timeline_order = A2 })
  sync.watch_timeline("PR", cfg, "S", "main", function() return false end)
  assert(bpm() == 120 and select(2, reaper.GetProjExtState("PR", sync.NEWEST, "timeline")) == A2, "reopened behind the song: the studio's map")
  -- a real reopen of a save that has the newest map, session.json still lagging: left as it is
  opened("PL", T120, A2, { tempo = T130, markers = {}, timeline_order = A1 })
  sync.watch_timeline("PL", cfg, "S", "main", function() return false end)
  assert(bpm() == 120, "reopened with a newer map than session.json: kept")
  -- a reopen whose project settings differ from the ones last seen (another REAPER's defaults): still put back, not sent as an edit
  local posted = 0
  local real_post = sync.post
  sync.post = function() posted = posted + 1 end
  opened("PS", T130, A1, { tempo = T120, markers = {}, timeline_order = A2 })
  proxy.capture_project = function() return { grid = 0.25 } end
  sync.watch_timeline("PS", cfg, "S", "main", function() return true end)
  assert(bpm() == 120 and posted == 0, "reopened behind, its settings changed: the studio's map, nothing sent (posted " .. posted .. ")")
  sync.post, proxy.capture_project = real_post, function() return {} end
  proxy.capture_tempo, proxy.session_path = real.capture_tempo, real.session_path
  sync.resnap, sync.audio_follow_tempo = real_resnap, real_follow
end
print("ok")
