-- The cloud copy's storage modes, the leftovers (rt-p2, backlog 1.34, 3.14, 1.35): an item's takes it doesn't play left out in Essentials, a
-- bandmate without a cloud folder no longer leaving the cloud's version of an object older, the filter's judging a few plans a pass, a lower
-- size limit asking first, Standard's last mixes, and the song's signed settings (session.json, room.json, band.json) carried by the copy.
-- Two studio folders and a cloud copy in memory, as test_0_60_rt_cloudmodes.lua (never a real cloud account).
package.path = "lib/?.lua;" .. package.path
local json = require("json")
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
  json_encode = function(t) return t end,
  json_decode = function(s) if type(s) ~= "string" then return s end; local ok, v = pcall(json.decode, s); return ok and v or nil end,
  size = function(p) local v = fs[p]; return v ~= nil and (type(v) == "string" and #v or 1) or nil end,
  copy_atomic = function(a, z) assert(fs[a] ~= nil, "copied from nowhere: " .. a); fs[z] = copy_of(fs[a]) end,
  copy_background = function(a, z) fs[z] = copy_of(fs[a]) end,
  log = function(s) logs[#logs + 1] = s end,
  home = function() return "/home" end,
  song_dir = function(cfg, song) return cfg.root .. "/" .. song end,
  clean = function(s) return (s:gsub("[^%w%-_ ]", "")) end,
}
package.loaded.band = band
reaper = setmetatable({
  time_precise = function() return clock end,
  file_exists = function(p) return fs[p] ~= nil end,
  EnumerateFiles = function(dir, i) return band.files(dir)[i + 1] end,
  EnumerateSubdirectories = function(dir, i) return band.subdirs(dir)[i + 1] end,
  SetExtState = function(_, k, v) ext[k] = v end,
  GetExtState = function(_, k) return ext[k] or "" end,
}, { __index = function() return function() end end })
local real_remove, real_rename = os.remove, os.rename
os.remove = function(p) if fs[p] == nil then return nil, "no such file" end fs[p] = nil; return true end
os.rename = function(a, z) if fs[a] == nil or fs[z] ~= nil then return nil, "can't" end fs[z], fs[a] = fs[a], nil; return true end
local function check(cond, what) if not cond then os.remove, os.rename = real_remove, real_rename; error(what, 2) end end
package.loaded.songsync = { here = function() return { "Song" } end }
local edits = 0
local setting = { mode = "everything" }
package.loaded.groups = { role = function(_, user) return user == "James" and "owner" or "member" end,
  edit = function(_, fn) local j = {}; fn(j); setting = j.cloud_storage or { mode = "everything" }; edits = edits + 1; return true end }
package.loaded.signed = { my_id = function() return "KEY-JAMES" end }
local drive, cm, trim = require("drive"), require("cloudmodes"), require("trim")
cm.settings_for = function() return cm.clean(setting) end
cm.EVERY, cm.OTHERS_WAIT = 0, 1e9

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
local S, B, CLOUD = "/S/Song/rooms", "/B/Song/rooms", "/C/Song/rooms"
local function cloud_has(sub, f) return fs[CLOUD .. "/main/" .. sub .. "/" .. f] ~= nil end
local function publish(root, user)
  for _ = 1, 20 do
    clock = clock + 60; drive.listed = {}
    local _, m = drive.mirror(root .. "/Song/rooms/main", CLOUD .. "/main", 50, user)
    if not m then return end
  end
  error("never in step")
end
local function sweep(root, user) clock = clock + 60; return cm.tick({ root = root, user = user }, "/C", clock, 100) end
local function both(p, v) fs["/S/" .. p], fs["/B/" .. p] = copy_of(v), copy_of(v) end

-- ---- 1. an item's takes it doesn't play (Essentials keeps the playing take and the prints made from it) ----
local function take(name, file, ext_lines)
  return { "TAKE", "NAME " .. name, "<SOURCE WAVE", 'FILE "{media:main}/' .. file .. '"', ">", ext_lines }
end
local lines = { "<ITEM", "POSITION 1", "NAME first", "<SOURCE WAVE", 'FILE "{media:main}/k0.wav"', ">" }
for _, t in ipairs({ take("second", "k1.wav"), take("third", "k2.wav"),
    take("print of second", "print-x.flac", "<EXT\nband_m_print 1a2b\nband_m_printof 1\n>"),
    take("print of first", "print-y.flac", "<EXT\nband_m_print 3c4d\nband_m_printof 0\n>") }) do
  for _, l in ipairs(t) do lines[#lines + 1] = l end
end
lines[#lines + 1] = ">"
local STATE = table.concat(lines, "\n") .. "\nBANDTAKE 1\n"
local media = cm.item_media(STATE, "main")
local plays = {}
for _, m in ipairs(media) do plays[m[2]] = not m[3] end
check(#media == 5 and plays["k1.wav"] and plays["print-x.flac"] and not plays["k0.wav"] and not plays["k2.wav"] and not plays["print-y.flac"],
  "item_media: the picked take (BANDTAKE 1: the second real take) and the print made from it play; the others don't")
for _, m in ipairs(cm.item_media((STATE:gsub("BANDTAKE 1\n", "")), "main")) do check(not m[3], "no BANDTAKE (one take, or an older version): all of it counts") end
for _, m in ipairs(cm.item_media('<ITEM\nFILE "{media:main}/a.wav"\n>\nBANDTAKE 0\n', "main")) do check(not m[3], "one take: it plays") end

local I5 = ev("James", 1, { obj = "item", oid = "I5", rev = 1, state = STATE })
local AUDIO = ("x"):rep(2048)
both("Song/rooms/main/events/" .. I5.id .. ".json", I5)
for _, f in ipairs({ "k0.wav", "k1.wav", "k2.wav", "print-x.flac", "print-y.flac" }) do both("Song/rooms/main/media/" .. f, f .. AUDIO) end
setting = { mode = "essentials" }
publish("/S", "James")
check(cloud_has("events", I5.id .. ".json") and cloud_has("media", "k1.wav") and cloud_has("media", "print-x.flac"),
  "Essentials: the item and what it plays go up")
check(not cloud_has("media", "k0.wav") and not cloud_has("media", "k2.wav") and not cloud_has("media", "print-y.flac"),
  "and the takes it doesn't play don't (rt-cloudmodes kept every take of a multi-take item)")
setting = { mode = "everything" }
publish("/S", "James")
check(cloud_has("media", "k0.wav") and cloud_has("media", "k2.wav"), "Everything: every take goes up")
setting = { mode = "standard", days = 14 }
sweep("/S", "James")
check(cloud_has("media", "k0.wav") and cloud_has("media", "print-y.flac"), "Standard: a day-old change's other takes are recent history: kept")
setting = { mode = "essentials" }
sweep("/S", "James")
check(not cloud_has("media", "k0.wav") and not cloud_has("media", "k2.wav") and not cloud_has("media", "print-y.flac") and cloud_has("media", "k1.wav")
  and cloud_has("media", "print-x.flac"), "Essentials' sweep: the unplayed takes go from the cloud copy, the played take and its print stay")
check(fs[S .. "/main/media/k0.wav"], "nothing local touched")

-- ---- 2. a bandmate without a cloud folder (Bo) replaced James's change: James's still goes up, and stays ----
local J1 = ev("James", 3, { obj = "item", oid = "I6", rev = 1, state = '<ITEM\nFILE "{media:main}/j1.wav"\n>\n' })
local B2 = ev("Bo", 2, { obj = "item", oid = "I6", rev = 2, state = '<ITEM\nFILE "{media:main}/bo2.wav"\n>\n' })
for _, e in ipairs({ J1, B2 }) do both("Song/rooms/main/events/" .. e.id .. ".json", e) end
both("Song/rooms/main/media/j1.wav", "j1" .. AUDIO); both("Song/rooms/main/media/bo2.wav", "bo2" .. AUDIO)
publish("/S", "James")
check(cloud_has("events", J1.id .. ".json") and cloud_has("media", "j1.wav"),
  "James's change to I6 and its recording go up though Bo's newer one is here: Bo's never reaches the cloud, so the cloud would have no I6")
check(not cloud_has("events", B2.id .. ".json"), "Bo's own change isn't James's to send")
sweep("/S", "James")
check(cloud_has("events", J1.id .. ".json") and cloud_has("media", "j1.wav"), "and the sweep keeps both: the cloud's own changes say I6 plays j1.wav")
-- Bo gets a cloud folder: his change goes up, and James's sweep takes his older one out; it isn't sent again
publish("/B", "Bo")
check(cloud_has("events", B2.id .. ".json") and cloud_has("media", "bo2.wav"), "Bo's newer change up from his computer")
sweep("/S", "James")
check(not cloud_has("events", J1.id .. ".json") and not cloud_has("media", "j1.wav"), "then James's replaced change goes from the cloud copy")
publish("/S", "James")
check(not cloud_has("events", J1.id .. ".json"), "and isn't sent up again")

-- ---- 3. the filter judges a few trim plans a pass, not the room in one go ----
setting = { mode = "standard", days = 14 }
for i = 1, 30 do -- (a room with history older than the window, in two rooms of the song)
  local e = ev("James", 20 + i, { obj = "item", oid = "OLD" .. (i % 5), rev = i, state = '<ITEM\nFILE "{media:main}/o' .. i .. '.wav"\n>\n' })
  both("Song/rooms/main/events/" .. e.id .. ".json", e)
  local s2 = ev("James", 20 + i, { obj = "item", oid = "SIDE" .. (i % 5), rev = i, state = '<ITEM\nFILE "{media:side}/s' .. i .. '.wav"\n>\n' })
  both("Song/rooms/side/events/" .. s2.id .. ".json", s2)
end
fs[S .. "/main/recall/" .. stamp(5) .. "-James-x.json"] = { time = iso(5), keep = true, label = "end of session" }
local real_plan, plans = trim.plan, 0
trim.plan = function(...) plans = plans + 1; return real_plan(...) end
package.loaded.cloudmodes = nil
cm = require("cloudmodes"); cm.settings_for = function() return cm.clean(setting) end
local whole = cm.filter(S .. "/main", math.huge, CLOUD .. "/main", "James")
local all_plans = plans
check(type(whole) == "function" and all_plans >= 3, "judged in one go with time to spare: " .. all_plans .. " trim plans")
package.loaded.cloudmodes = nil
cm = require("cloudmodes"); cm.settings_for = function() return cm.clean(setting) end
plans = 0
local got, calls = false, 0
repeat
  calls = calls + 1
  clock = clock + 1
  got = cm.filter(S .. "/main", clock - 0.5, CLOUD .. "/main", "James") -- (each pass's time already gone: one plan a call)
  check(calls == 1 and got == false or calls > 1, "the first pass stops after one plan and carries on next pass (it judged the room in one go)")
until got or calls > 20
check(type(got) == "function" and plans == all_plans and calls == all_plans, "a plan a pass, none made twice: " .. plans .. " plans in " .. calls .. " passes")
check(cm.filter(S .. "/main", clock - 0.5, CLOUD .. "/main", "James") == got, "then kept while nothing changes")
trim.plan = real_plan
for p in pairs(fs) do if p:find("/OLD") or p:find("/side/") then fs[p] = nil end end

-- ---- 4. a lower size limit asks first, with what goes ----
local MB = 1024 * 1024
local sum = { ages = { { "2026-10-01", 2, 3 * MB }, { "2026-11-01", 1, 2 * MB } }, kept = 10 * MB, ess = 4 * MB, stored = { 9, 10 * MB }, would = {} }
local w = cm.limit_words(sum, 7, "Google Drive")
check(w and w:find("About 2 files (3 MB)", 1, true) and w:find("2026-10-01 and before", 1, true) and not w:find("essentials alone", 1, true),
  "limit_words: the oldest day's files go until it fits: " .. tostring(w))
w = cm.limit_words(sum, 3, "Google Drive")
check(w and w:find("About 3 files (5 MB)", 1, true) and w:find("essentials alone are over", 1, true), "under the essentials: every other file, and it's said: " .. tostring(w))
check(cm.limit_words(sum, 20, "Google Drive") == nil and cm.limit_words(nil, 1, "x") == nil, "nothing goes, or no sweep yet: nothing to list")
-- the panel: picking a lower limit sets nothing until confirmed; a higher one at once
ext["drive_root"] = "/C"
ext["cloud storage"] = { ages = { { "2026-10-01", 40, 3000 * MB } }, kept = 4000 * MB, ess = 900 * MB, stored = { 50, 4000 * MB }, would = {}, mode = "standard", days = 14 }
setting = { mode = "standard", days = 14 }
local opened, pick, press, said = {}, nil, nil, {}
local ImGui = setmetatable({
  BeginCombo = function(_, id) return id == "##cloudlimit" and pick ~= nil end,
  Selectable = function(_, label) return label == pick end,
  OpenPopup = function(_, id) opened[id] = true end,
  BeginPopupModal = function(_, id) return opened[id] == true end,
  CloseCurrentPopup = function() opened = {} end,
  Button = function(_, label) return label == press end,
  Text = function(_, t) said[#said + 1] = t end,
}, { __index = function() return function() return false end end })
local cfg = { root = "/S", user = "James" }
pick = "1 GB limit"
cm.studio_ui({}, ImGui, cfg, true)
check(edits == 0 and opened["Lower size limit?"], "a lower limit opens its confirmation and sets nothing yet")
pick, said = nil, {}
cm.studio_ui({}, ImGui, cfg, true)
check(edits == 0 and table.concat(said, "\n"):find("About 40 files", 1, true), "the confirmation lists what goes: " .. table.concat(said, " | "))
press = "Cancel##limit"
cm.studio_ui({}, ImGui, cfg, true)
check(edits == 0 and not opened["Lower size limit?"] and setting.limit_mb == nil, "Cancel: no limit set")
pick, press = "1 GB limit", nil
cm.studio_ui({}, ImGui, cfg, true)
pick, press = nil, "Limit to 1 GB"
cm.studio_ui({}, ImGui, cfg, true)
check(edits == 1 and setting.limit_mb == 1024, "confirmed: the limit is set")
pick, press = "2 GB limit", nil
cm.studio_ui({}, ImGui, cfg, true)
check(edits == 2 and setting.limit_mb == 2048 and not opened["Lower size limit?"], "a higher limit: set at once, nothing asked")
pick = "No size limit"
cm.studio_ui({}, ImGui, cfg, true)
check(edits == 3 and setting.limit_mb == nil, "and no limit: at once")
pick = nil

-- ---- 5. Standard's last mixes: carried by the copy, the window's and the newest; each by its maker ----
check(cm.mix_user("Song 2026-11-20 101500 James.wav") == "James" and cm.mix_user("Song 2026-11-20 101500 Bo James.flac") == "Bo James"
  and cm.mix_time("Song 2026-11-20 101500 James.wav") == "2026-11-20T10:15:00" and cm.mix_user("notes.txt") == nil, "a mix's maker and time from its name")
local function mix(days, who) return "Song " .. os.date("%Y-%m-%d %H%M%S", NOW - math.floor(days * 86400)) .. " " .. who .. ".wav" end
local M30, M20, BO25 = mix(30, "James"), mix(20, "James"), mix(25, "Bo")
for _, f in ipairs({ M30, M20, BO25 }) do both("Song/mixes/" .. f, f .. AUDIO) end
setting = { mode = "essentials" }
local CD = "/C/Song/mixes/"
drive.song_files(cfg, "/C", "Song")
check(not fs[CD .. M20] and not fs[CD .. M30], "Essentials: no mixes go up")
setting = { mode = "standard", days = 14 }
drive.song_files(cfg, "/C", "Song")
check(fs[CD .. M20] and not fs[CD .. M30] and not fs[CD .. BO25], "Standard: James's newest goes up though older than the window (the song's last mix); not his older one, not Bo's")
setting = { mode = "everything" }
drive.song_files(cfg, "/C", "Song")
check(fs[CD .. M30] and not fs[CD .. BO25], "Everything: all of James's")
fs[CD .. BO25] = BO25 .. AUDIO -- (Bo's, from his own computer)
setting = { mode = "standard", days = 14 }
local s5 = sweep("/S", "James")
check(not fs[CD .. M30] and fs[CD .. M20] and fs[CD .. BO25], "Standard's sweep: James's old mix goes from the cloud; his last stays; Bo's isn't his to take")
check(s5.kinds.mixes and s5.kinds.mixes[1] >= 2, "the sweep counts mixes")
fs["/C/Song/mixes/" .. M30] = nil
check(fs["/S/Song/mixes/" .. M30], "nothing local touched")

-- ---- 6. the song's signed settings: session.json, room.json and band.json with their signatures, from the computer that signed them ----
local function sig(by, n) return json.encode({ v = 1, by = by, key = ("a"):rep(64), seq = n, sig = ("b"):rep(128) }) end
fs["/S/Song/session.json"], fs["/S/Song/session.json.sig"] = '{"host":"James"}', sig("KEY-JAMES", 1)
fs["/S/Song/rooms/main/room.json"], fs["/S/Song/rooms/main/room.json.sig"] = '{"mode":"open"}', sig("KEY-BO", 1)
fs["/S/_band/band.json"], fs["/S/_band/band.json.sig"] = '{"owner":"James"}', sig("KEY-JAMES", 1)
fs["/S/Song/rooms/side/room.json"] = '{"mode":"open"}' -- (unsigned: an older studio)
local n6 = drive.song_files(cfg, "/C", "Song")
check(fs["/C/Song/session.json"] and fs["/C/Song/session.json.sig"] == fs["/S/Song/session.json.sig"] and fs["/C/_band/band.json.sig"],
  "the files this computer signed go up, each with its signature: " .. n6)
check(not fs["/C/Song/rooms/main/room.json"] and not fs["/C/Song/rooms/side/room.json"], "not one a bandmate signed (theirs to send), nor an unsigned one")
check(drive.song_files(cfg, "/C", "Song") == 0, "and not again while the cloud's signature is the same")
fs["/S/Song/session.json"], fs["/S/Song/session.json.sig"] = '{"host":"James","x":1}', sig("KEY-JAMES", 2)
drive.song_files(cfg, "/C", "Song")
check(fs["/C/Song/session.json"] == '{"host":"James","x":1}' and fs["/C/Song/session.json.sig"] == sig("KEY-JAMES", 2), "a newer signing goes up")
check(fs["/C/Song/session.json"] and cm.where() == nil, "nothing of the sweep's touched them")

os.remove, os.rename = real_remove, real_rename
print("ok cloud modes 2: unplayed takes, a bandmate without a cloud folder, the filter a plan a pass, a lower limit asks, last mixes, signed settings carried")
