-- Storage modes for the cloud copy (lib/cloudmodes.lua). Two studio folders and a cloud copy, all in memory (never a real cloud account):
-- a generated project with 40 days of history in two rooms (fixed lanes, a deleted item, saved versions, takes, trash) published by two
-- computers; then Essentials (only what the project is now stays in the cloud copy, nothing local touched), restored onto an empty computer of
-- the same person (the project there complete, nothing removed from the cloud by it), Everything again (the cloud filled back from the
-- computers), Standard (the last 14 days), and a size limit (oldest non-essential first, essentials never). Plus the pure parts.
package.path = "lib/?.lua;" .. package.path
local fs, logs, clock, ext = {}, {}, 1000, {}
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
  files = function(dir, ext_) local out = {}; for _, f in ipairs(kids(dir, false)) do if not ext_ or f:sub(-#ext_) == ext_ then out[#out + 1] = f end end; return out end,
  subdirs = function(dir) return kids(dir, true) end,
  read_json = function(p) return type(fs[p]) == "table" and copy_of(fs[p]) or nil end,
  read = function(p) return type(fs[p]) == "string" and fs[p] or nil end,
  write_json = function(p, t) fs[p] = copy_of(t) end,
  json_encode = function(t) return t end, json_decode = function(t) return t end,
  size = function(p) local v = fs[p]; return v ~= nil and (type(v) == "string" and #v or 1) or nil end,
  copy_atomic = function(a, z) assert(fs[a] ~= nil, "copied from nowhere: " .. a); fs[z] = copy_of(fs[a]) end,
  copy_background = function(a, z) fs[z] = copy_of(fs[a]) end,
  log = function(s) logs[#logs + 1] = s end,
  home = function() return "/home" end,
  song_dir = function(cfg, song) return cfg.root .. "/" .. song end,
}
package.loaded.band = band
reaper = setmetatable({
  time_precise = function() return clock end,
  file_exists = function(p) return fs[p] ~= nil end,
  EnumerateFiles = function(dir, i) return band.files(dir)[i + 1] end,
  EnumerateSubdirectories = function(dir, i) return band.subdirs(dir)[i + 1] end,
  SetExtState = function(_, k, v) ext[k] = v end,
  GetExtState = function(_, k) return ext[k] end,
}, { __index = function() return function() end end })
local real_remove, real_rename = os.remove, os.rename
os.remove = function(p) if fs[p] == nil then return nil, "no such file" end fs[p] = nil; return true end
os.rename = function(a, z) if fs[a] == nil or fs[z] ~= nil then return nil, "can't" end fs[z], fs[a] = fs[a], nil; return true end
local function check(cond, what) if not cond then os.remove, os.rename = real_remove, real_rename; error(what, 2) end end
package.loaded.songsync = { here = function() return { "Song" } end }
package.loaded.groups = { role = function(_, user) return user == "James" and "owner" or "member" end }
local drive, cm, trim = require("drive"), require("cloudmodes"), require("trim")
local setting = { mode = "everything" }
cm.settings_for = function() return cm.clean(setting) end
cm.EVERY = 0

-- ---- pure ----
local c = cm.clean({ mode = "nonsense", days = "x", limit_mb = -5 })
check(c.mode == "everything" and c.days == cm.DAYS and c.limit_mb == nil, "clean: anything odd in band.json is Everything, the default window, no limit")
c = cm.clean({ mode = "standard", days = 9999, limit_mb = 2048.7 })
check(c.mode == "standard" and c.days == 365 and c.limit_mb == 2048, "clean: days at most a year, the limit in whole MB")
check(cm.stamp_time("20261120-013000Z-James-x.json") == "2026-11-20T01:30:00Z" and cm.stamp_time("index.json") == "", "stamp_time")
check(cm.lane_plays({ freemode = 2, lanes = 2, plays = "1,0" }, 0) and not cm.lane_plays({ freemode = 2, lanes = 2, plays = "1,0" }, 1),
  "lane_plays: the lane marked playing plays, the other doesn't")
check(cm.lane_plays({ freemode = 2, lanes = 2, plays = "0,0" }, 1) and cm.lane_plays({ freemode = 0, lanes = 1 }, 3) and cm.lane_plays(nil, 1) and
  cm.lane_plays({ freemode = 2, lanes = 3, plays = "2,2,2" }, 2), "lane_plays: none marked, not in lanes, unknown track, all playing: plays")
local cut, over = cm.limit_cut({ { "essential", "", 50 }, { "recent", "2026-11-01", 20 }, { "other", "2026-10-01", 20 }, { "recent", "2026-11-10", 20 } }, 75)
check(cut == "2026-11-01" and not over, "limit_cut: the oldest non-essential go first, until it fits: " .. tostring(cut))
cut, over = cm.limit_cut({ { "essential", "", 50 }, { "other", "2026-10-01", 20 } }, 40)
check(cut == "2026-10-01" and over, "limit_cut: essentials alone over: every other file goes, and it's said")
check(cm.limit_cut({ { "essential", "", 50 } }, nil) == nil, "limit_cut: no limit, nothing goes")

-- ---- the project ----
local NOW = os.time()
local function iso(days) return os.date("!%Y-%m-%dT%H:%M:%SZ", NOW - math.floor(days * 86400)) end
local function stamp(days) return os.date("!%Y%m%d-%H%M%SZ", NOW - math.floor(days * 86400)) end
local seq = 0
local function ev(user, days, t)
  seq = seq + 1
  t.id = string.format("%s-%s-%05d-1000", user, stamp(days), seq)
  t.user, t.time, t.type = user, iso(days), t.type or "obj"
  return t
end
local function item(user, days, oid, rev, track, files, lane, gone)
  local st
  if files then
    local lines = { "<ITEM", "POSITION 1" }
    for _, f in ipairs(files) do lines[#lines + 1] = 'FILE "{media:' .. f[1] .. '}/' .. f[2] .. '"' end
    lines[#lines + 1] = ">"
    st = table.concat(lines, "\n") .. "\n" .. (lane and ("BANDLANE " .. lane .. "\n") or "")
  end
  return ev(user, days, { obj = "item", oid = oid, rev = rev, track = track, state = st, gone = gone or nil })
end
local function track(user, days, oid, rev, plays)
  return ev(user, days, { obj = "track", oid = oid, rev = rev, state = { name = oid, freemode = plays and 2 or 0, lanes = plays and 2 or 1, plays = plays or "" } })
end
local S, CLOUD = "/S/Song/rooms", "/C/Song/rooms"
local AUDIO = string.rep("x", 1024 * 1024) -- (each recording 1 MB, so a limit in MB bites)
local function put(path, v) fs[path] = v end
local function put_ev(room, e) put(S .. "/" .. room .. "/events/" .. e.id .. ".json", e) end
local function media(room, f) put(S .. "/" .. room .. "/media/" .. f, f .. AUDIO) end
local main, side = {}, {}
local function add_main(e) main[#main + 1] = e; put_ev("main", e) end
local function add_side(e) side[#side + 1] = e; put_ev("side", e) end
-- main: T1 in two fixed lanes, lane 0 plays now (it was lane 1 forty days ago); I1 on lane 0 rewritten three times (a1, a2, a3); I2 on lane 1
-- (doesn't play); Bo's I3 on a plain track, untouched for 50 days; I4 deleted 44 days ago; the timeline twice; a note; Bo's take deleted
add_main(track("James", 40, "T1", 1, "0,1"))
add_main(track("James", 2, "T1", 2, "1,0"))
add_main(track("Bo", 50, "T2", 1, nil))
add_main(item("James", 40, "I1", 1, "T1", { { "main", "a1.wav" } }, 0))
local i1v2 = item("James", 20, "I1", 2, "T1", { { "main", "a2.wav" } }, 0); add_main(i1v2)
add_main(item("James", 2, "I1", 3, "T1", { { "main", "a3.wav" } }, 0))
add_main(item("James", 30, "I2", 1, "T1", { { "main", "b.wav" } }, 1))
add_main(item("Bo", 50, "I3", 1, "T2", { { "main", "c.wav" } }))
add_main(item("James", 45, "I4", 1, "T1", { { "main", "d.wav" } }, 0))
add_main(item("James", 44, "I4", 2, "T1", nil, nil, true))
add_main(ev("James", 41, { type = "timeline", order = iso(41) }))
add_main(ev("James", 3, { type = "timeline", order = iso(3) }))
add_main(ev("Bo", 39, { type = "note", text = "nice" }))
local TAKE_OLD, TAKE_NEW, TAKE_BO = "James-" .. stamp(35) .. "-1", "James-" .. stamp(2) .. "-2", "Bo-" .. stamp(33) .. "-3"
add_main(ev("Bo", 32, { type = "delete", take = TAKE_BO }))
-- side: S1 plays main's a1.wav (an old take of main's item, current in the side room) and its own s.wav
add_side(item("Bo", 25, "S1", 1, nil, { { "main", "a1.wav" }, { "side", "s.wav" } }))
for _, f in ipairs({ "a1.wav", "a2.wav", "a3.wav", "b.wav", "c.wav", "d.wav", "stage-I1-0badf00d-1-x.flac" }) do media("main", f) end
media("side", "s.wav")
-- saved versions: one 10 days ago (its map names I1's second version), one 30 days ago
local P10, P30 = stamp(10) .. "-James-end_of_session.json", stamp(30) .. "-James-end_of_session.json"
put(S .. "/main/recall/" .. P10, { time = iso(10), keep = true, label = "end of session", by = "James" })
put(S .. "/main/recall/known/" .. P10, { I1 = i1v2.id })
put(S .. "/main/recall/" .. P30, { time = iso(30), keep = true, label = "end of session", by = "James" })
put(S .. "/main/takes/" .. TAKE_OLD .. ".flac", "old take" .. AUDIO); put(S .. "/main/takes/" .. TAKE_OLD .. ".json", { rev = 1 })
put(S .. "/main/takes/" .. TAKE_NEW .. ".flac", "new take" .. AUDIO); put(S .. "/main/takes/" .. TAKE_NEW .. ".json", { rev = 1 })
put(S .. "/main/_trash/" .. TAKE_BO .. ".flac", "Bo's deleted take"); put(S .. "/main/_trash/" .. TAKE_BO .. ".json", { rev = 1 })
put(S .. "/main/fx/James/T1.RfxChain", "<chain>")
put(S .. "/main/midi/James-" .. stamp(5) .. "-1.mid", "notes")

local function each(prefix) local out = {}; for p, v in pairs(fs) do if p:sub(1, #prefix) == prefix then out[p:sub(#prefix + 1)] = v end end; return out end
local function count_of(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
local function same_sets(a, b) for k in pairs(a) do if b[k] == nil then return false, k end end; for k in pairs(b) do if a[k] == nil then return false, k end end; return true, nil end
-- One computer's passes until its rooms are in step (each person's own files go up; anyone's come down)
local function publish(root, user)
  for _ = 1, 20 do
    local more = false
    local rooms = {}
    for _, r in ipairs(band.subdirs(root .. "/Song/rooms")) do rooms[r] = true end
    for _, r in ipairs(band.subdirs(CLOUD)) do rooms[r] = true end
    for r in pairs(rooms) do
      clock = clock + 60; drive.listed = {}
      local _, m = drive.mirror(root .. "/Song/rooms/" .. r, CLOUD .. "/" .. r, 50, user)
      more = more or m
    end
    if not more then return end
  end
  error("never in step")
end
local function sweep(root, user) clock = clock + 60; return cm.tick({ root = root, user = user }, "/C", clock, 100) end
local function cloud_has(room, sub, f) return fs[CLOUD .. "/" .. room .. "/" .. sub .. "/" .. f] ~= nil end

-- ---- Everything: both computers publish, the cloud copy holds it all ----
for p, v in pairs(each("/S/")) do fs["/B/" .. p] = copy_of(v) end -- (Bo's computer: the same studio folder)
-- (a print's stage no change names: nobody's to send up, so an older version put it there; whose it is isn't known)
fs[CLOUD .. "/main/media/stage-I1-0badf00d-1-x.flac"] = fs[S .. "/main/media/stage-I1-0badf00d-1-x.flac"]
cm.OTHERS_WAIT = 1e9
publish("/S", "James"); publish("/B", "Bo")
-- (end-of-session projects, only ever in the cloud copy: one 20 days old using x.wav, one 2 days old using y.wav)
local SD = "/C/Song/sessions"
local RPP_OLD, RPP_NEW = SD .. "/" .. stamp(20) .. "-James-main.rpp", SD .. "/" .. stamp(2) .. "-James-main.rpp"
local function put_sessions()
  fs[RPP_OLD], fs[RPP_NEW] = '<REAPER_PROJECT\n  FILE "media/James/x.wav"\n>\n', '<REAPER_PROJECT\n  FILE "media/James/y.wav"\n>\n'
  fs[SD .. "/media/James/x.wav"], fs[SD .. "/media/James/y.wav"] = "x" .. AUDIO, "y" .. AUDIO
end
put_sessions()
local local_S = each("/S/")
local cloud_all = each("/C/Song/")
check(same_sets(each("/S/Song/rooms/"), each("/C/Song/rooms/")), "Everything: the cloud copy holds every file of the project: " .. tostring(select(2, same_sets(each("/S/Song/rooms/"), each("/C/Song/rooms/")))))
local sum = sweep("/S", "James")
check(sum and sum.removed[1] == 0 and sum.stored[1] == count_of(cloud_all), "Everything: a sweep counts what's there and removes nothing")
check(sum.would.essentials < sum.would.standard and sum.would.standard < sum.would.everything and sum.would.everything == sum.stored[2],
  "each mode would store less than the next; Everything is what's there")
check(sum.drop.essentials[1] > sum.drop.standard[1] and cm.drop_words(sum, "essentials", "Google Drive"):find("recordings: ", 1, true),
  "what a switch would remove is listed by kind: " .. tostring(cm.drop_words(sum, "essentials", "Google Drive")))
check(cm.health_row(sum, "Google Drive")[5]:find("Each mode would store: Essentials", 1, true), "Health says what each mode would store")

-- ---- Essentials: each computer removes its own files the mode leaves out; nothing local is touched ----
setting = { mode = "essentials" }
sum = sweep("/S", "James"); sweep("/B", "Bo")
check(same_sets(local_S, each("/S/")), "nothing on James's computer touched")
local function evs_in(prefix) local t = {}; for _, f in ipairs(band.files(prefix .. "/events", ".json")) do t[f:gsub("%.json$", "")] = fs[prefix .. "/events/" .. f] end; return t end
local function newest_ids(list) local drop, out = {}, {}; for _, id in ipairs(trim.plan(list, {}, "~")) do drop[id] = true end; for _, e in ipairs(list) do if not drop[e.id] then out[e.id] = true end end; return out end
local want_main, want_side = newest_ids(main), newest_ids(side)
local in_cloud = evs_in(CLOUD .. "/main")
check(same_sets(want_main, in_cloud), "Essentials: the cloud's changes are exactly each object's newest (and the timeline's, the note, the take's delete): " ..
  tostring(select(2, same_sets(want_main, in_cloud))))
check(in_cloud[main[6].id] and not in_cloud[i1v2.id] and in_cloud[main[10].id], "I1's newest stays, its older versions go; I4's delete stays")
check(cloud_has("main", "media", "a3.wav") and cloud_has("main", "media", "c.wav") and cloud_has("main", "media", "a1.wav") and cloud_has("side", "media", "s.wav"),
  "the recordings the project plays stay: a3 (the lane that plays), c (50 days old, still played), a1 (played by the side room)")
check(not cloud_has("main", "media", "a2.wav") and not cloud_has("main", "media", "b.wav") and not cloud_has("main", "media", "d.wav"),
  "and the rest go: an old version's, the lane that doesn't play, a deleted item's")
check(cloud_has("main", "media", "stage-I1-0badf00d-1-x.flac"), "a file nobody's known to own waits for the owner's computer")
cm.OTHERS_WAIT = 0 -- (an hour on, as far as the owner's computer is concerned)
sweep("/B", "Bo")
check(cloud_has("main", "media", "stage-I1-0badf00d-1-x.flac"), "not a member's computer")
sweep("/S", "James")
check(not cloud_has("main", "media", "stage-I1-0badf00d-1-x.flac"), "the owner's computer removes it once it's been unwanted a while")
cm.OTHERS_WAIT = 1e9
check(#band.files(CLOUD .. "/main/recall") == 0 and #band.files(CLOUD .. "/main/recall/known") == 0 and #band.files(CLOUD .. "/main/takes") == 0 and
  #band.files(CLOUD .. "/main/_trash") == 0, "no saved versions, takes or trash")
check(cloud_has("main", "fx/James", "T1.RfxChain") and #band.files(CLOUD .. "/main/midi") == 1, "plug-in chains and MIDI stay")
check(sum.removed[1] > 0 and logs[#logs]:find("nothing on any computer was touched", 1, true), "said: " .. tostring(logs[#logs]))
check(not cloud_has("main", "_trash", TAKE_BO .. ".flac") and fs["/B/Song/rooms/main/_trash/" .. TAKE_BO .. ".flac"], "Bo's trash went from the cloud, by his computer, not from his disk")
check(not fs[RPP_OLD] and not fs[RPP_NEW] and not fs[SD .. "/media/James/x.wav"] and not fs[SD .. "/media/James/y.wav"], "no end-of-session projects, nor their recordings")
local okx, outx, whyx = pcall(require("sessionfile").export, nil, { root = "/S", user = "James" }, { song = "Song", room = "main" }, "/C", S .. "/main")
check(okx and outx == nil and tostring(whyx):find("essentials only", 1, true), "and none written: " .. tostring(whyx))
-- not sent up again: a pass from each computer leaves the cloud as it is
local after = each("/C/")
publish("/S", "James"); publish("/B", "Bo")
check(same_sets(after, each("/C/")), "Essentials: a pass sends nothing the mode leaves out: " .. tostring(select(2, same_sets(after, each("/C/")))))
-- James works on: I1 twice before a pass (a4, a5); only the newest goes up, and the one it replaced goes at the next sweep
local v4 = item("James", 0.01, "I1", 4, "T1", { { "main", "a4.wav" } }, 0); add_main(v4); media("main", "a4.wav")
local v5 = item("James", 0.005, "I1", 5, "T1", { { "main", "a5.wav" } }, 0); add_main(v5); media("main", "a5.wav")
publish("/S", "James")
check(cloud_has("main", "events", v5.id .. ".json") and cloud_has("main", "media", "a5.wav"), "the newest change and its recording go up")
check(not cloud_has("main", "events", v4.id .. ".json") and not cloud_has("main", "media", "a4.wav"), "the one replaced before the pass never goes up")
sweep("/S", "James")
check(not cloud_has("main", "events", main[6].id .. ".json") and not cloud_has("main", "media", "a3.wav"), "and the cloud's older version goes at the next sweep")
local_S = each("/S/")

-- ---- restore from Essentials onto an empty computer (James's new one): the project complete ----
publish("/E", "James")
local removed_before = count_of(each("/C/"))
sum = sweep("/E", "James")
check(sum.removed[1] == 0 and count_of(each("/C/")) == removed_before, "the new computer removes nothing from the cloud copy")
for _, r in ipairs({ { "main", main }, { "side", side } }) do
  local got = evs_in("/E/Song/rooms/" .. r[1])
  local want = newest_ids(r[2])
  for id in pairs(want) do
    local orig
    for _, e in ipairs(r[2]) do if e.id == id then orig = e end end
    check(got[id] and got[id].state == orig.state or (type(orig.state) == "table" and got[id] and got[id].state.plays == orig.state.plays),
      r[1] .. ": the project as it stands came back exactly: " .. id)
  end
  -- (what Live sync builds the project from: each object's newest change; the restored copy's newest is the original's)
  local newest = {}
  for _, e in pairs(got) do if e.oid and (not newest[e.oid] or e.rev > newest[e.oid].rev) then newest[e.oid] = e end end
  for _, e in ipairs(r[2]) do if e.oid then check(newest[e.oid] and newest[e.oid].rev >= e.rev, r[1] .. ": " .. e.oid .. " at its newest") end end
end
for _, f in ipairs({ "a5.wav", "c.wav", "a1.wav" }) do check(fs["/E/Song/rooms/main/media/" .. f] == f .. AUDIO, "played recording restored whole: " .. f) end
check(fs["/E/Song/rooms/side/media/s.wav"] == "s.wav" .. AUDIO and fs["/E/Song/rooms/main/fx/James/T1.RfxChain"] == "<chain>" and #band.files("/E/Song/rooms/main/midi") == 1,
  "the side room's recording, plug-in chains and MIDI restored")
check(same_sets(local_S, each("/S/")), "the old computer untouched")

-- ---- Everything again: each computer's own files go back up ----
setting = { mode = "everything" }
publish("/S", "James"); publish("/B", "Bo")
local missing = {}
for p in pairs(each("/S/Song/")) do -- (but the stage nobody owns: never sent up, as before)
  if not fs["/C/Song/" .. p] and not p:find("/stage%-") then missing[#missing + 1] = p end
end
check(#missing == 0, "Everything again: the cloud copy holds every file of the project again: " .. table.concat(missing, ", "))
check(sweep("/S", "James").removed[1] == 0, "and nothing goes")

-- ---- Standard (14 days): history within the window, and what the saved version 10 days ago restores to ----
setting = { mode = "standard", days = 14 }
put_sessions()
sweep("/S", "James"); sweep("/B", "Bo")
check(fs[RPP_NEW] and fs[SD .. "/media/James/y.wav"] and not fs[RPP_OLD] and not fs[SD .. "/media/James/x.wav"],
  "end-of-session projects: the recent one and what it uses stay; the old one and its recording go")
in_cloud = evs_in(CLOUD .. "/main")
check(in_cloud[i1v2.id] and in_cloud[main[6].id] and in_cloud[v4.id] and not in_cloud[main[4].id],
  "Standard: the last 14 days' changes and the version the 10-day saved version restores to stay; older ones go")
check(cloud_has("main", "recall", P10) and cloud_has("main", "recall/known", P10) and not cloud_has("main", "recall", P30), "saved versions: the recent one stays, the old one goes")
check(cloud_has("main", "media", "a2.wav") and cloud_has("main", "media", "b.wav") and cloud_has("main", "media", "a4.wav") and not cloud_has("main", "media", "d.wav"),
  "recordings: what recent history plays (and the lane that doesn't play) stays; a deleted item's from 45 days ago goes")
check(cloud_has("main", "takes", TAKE_NEW .. ".flac") and not cloud_has("main", "takes", TAKE_OLD .. ".flac") and #band.files(CLOUD .. "/main/_trash") == 0,
  "takes: the recent one stays, the old one and the trash go")
check(same_sets(local_S, each("/S/")), "nothing local touched")

-- ---- a size limit: the oldest non-essential files go first; essentials never ----
local before = sweep("/S", "James")
local ess_mb = before.ess / 1024 / 1024
setting = { mode = "standard", days = 14, limit_mb = math.floor(ess_mb) + 2 } -- (room for the essentials and one more recording, not two)
sweep("/S", "James") -- (works out the cut)
check(cm.cut ~= nil, "over the limit: a cut is worked out")
sum = sweep("/S", "James") -- (and the next sweep goes by it)
check(cloud_has("main", "media", "a5.wav") and cloud_has("main", "media", "c.wav") and cloud_has("main", "media", "a1.wav"), "essentials stay under a limit")
check(not cloud_has("main", "media", "b.wav") and not cloud_has("main", "media", "a2.wav") and cloud_has("main", "media", "a4.wav"),
  "the oldest non-essential recordings went first (b 30 days, a2 20 days), the newest stayed (a4)")
setting = { mode = "standard", days = 14, limit_mb = 1 } -- (less than the essentials alone)
sweep("/S", "James"); sum = sweep("/S", "James")
check(sum.over and cloud_has("main", "media", "a5.wav") and cloud_has("main", "media", "c.wav"), "essentials alone over the limit: said, and still kept")
local row = cm.health_row(sum, "Google Drive")
check(row[3] == "yellow" and row[5]:find("raise the limit", 1, true), "Health says so")
check(same_sets(local_S, each("/S/")), "nothing local touched")

-- ---- Everything with no limit: no filter at all (today's behaviour) ----
setting = { mode = "everything" }
check(cm.filter("/S/Song/rooms/main", math.huge) == nil, "Everything with no limit: drive.mirror goes as before")

os.remove, os.rename = real_remove, real_rename
print("ok cloud storage modes: essentials round trip, standard window, size limit, switching up and down, nothing local touched")
