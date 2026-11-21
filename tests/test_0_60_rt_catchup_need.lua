-- rt-catchup (2026-11-21), from the LinuxBox test of the link's need list (lib/needlist.lua, docs/rt/rt-linkmove.md "Round 5"):
--   2. the event ids went only with the first ask (or when who's here changed). A bandmate that didn't count the asker as here yet dropped it,
--      and the ids were never asked again: events took 85 s in one run and never came in another. Now an ask with the ids goes again, the gap
--      doubling from EV_RETRY to EVERY, until a bandmate answers; a bandmate whose days all match answers with an empty list.
--   3. the first look at which media the song plays read 0.05 s every CATCHUP_LOOK s: 2,700 changes took about 50 s. Now needlist.warm reads
--      WARM s a tick from Live sync's every tick until it's through, and a change that lands reads it again at once.
package.path = "lib/?.lua;" .. package.path
local clock, gext = 1000, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })
local band = require("band")
band.home = function() return "H" end
band.info = function() return { id = "studio1" } end
local streams = require("streams")
local direct = require("direct")
local services = require("services")
local needlist = require("needlist")
local ANN = "AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA"
local BEE = "BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB"
local TODAY = os.date("!%Y%m%d")

-- each computer's rooms, events (dir -> { [file] = event }), media sizes; a read of an event file costs READ s of the clock
local evdirs, disk, onfile = {}, {}, {}
local READ = 0.0002
band.subdirs = function(dir)
  if dir == "RA/Song/rooms" or dir == "RB/Song/rooms" then return { "main" } end
  return dir:match("^R[AB]/Song/rooms/main$") and { "events" } or {}
end
band.files = function(dir)
  local out = {}
  for f in pairs(evdirs[dir] or {}) do out[#out + 1] = f end
  table.sort(out)
  return out
end
band.read_json = function(p)
  local d, f = p:match("^(.*)/([^/]+)$")
  if evdirs[d] then clock = clock + READ; return evdirs[d][f] end
  return nil
end
band.size = function(p) return disk[p] end
band.write_atomic = function() end
reaper.file_exists = function(p) return onfile[p] == true end
local evn = 0
local function ev(root, by, e)
  evn = evn + 1
  local id = string.format("%s-%s-100000Z-%05d-0001", by, TODAY, evn)
  local d = root .. "/Song/rooms/main/events"
  evdirs[d] = evdirs[d] or {}
  e = e or {}
  e.id, e.oid, e.time = id, e.oid or ("{O" .. evn .. "}"), e.time or string.format("2026-11-21T10:%02d:00Z", evn % 60)
  evdirs[d][id .. ".json"], onfile[d .. "/" .. id .. ".json"] = e, true
  return id
end

local me, here, here_dev, sent = BEE, {}, {}, {}
direct.live_available = function() return true end
direct.ensure = function() return true end
direct.peers = function() return here, here_dev end
direct.send_live = function(_, kind, dd, song, room, id, to) sent[#sent + 1] = { kind = kind, d = dd, to = to } end
services.my_device_id = function() return me end
local cfgA, cfgB, b = { user = "Ann", root = "RA" }, { user = "Bee", root = "RB" }, { song = "Song", room = "main" }
local function as(who, knows)
  if who == "Ann" then me, here, here_dev = ANN, knows and { "bee.ts.net:47281" } or {}, knows and { ["bee.ts.net:47281"] = BEE } or {}
  else me, here, here_dev = BEE, { "ann.ts.net:47281" }, { ["ann.ts.net:47281"] = ANN } end
end
local function last() return sent[#sent] end
local function wire(t) return band.json_decode(band.json_encode(t)) end
gext[band.SECTION .. "\0" .. needlist.EXT] = "1"

-- both computers hold the same changes (every day matches); Bee's song plays b.wav, which Bee lacks
local same = ev("RA", "Ann"); evdirs["RB/Song/rooms/main/events"] = { [same .. ".json"] = evdirs["RA/Song/rooms/main/events"][same .. ".json"] }
onfile["RB/Song/rooms/main/events/" .. same .. ".json"] = true

-- ---- 2. an ask of the event ids that isn't answered goes again ----------------------------------------------------------------------
as("Bee")
assert(needlist.tick(cfgB, b) == 1 and last().d.evs and last().d.evs.main, "Bee's computer, back: the ask carries its event ids")
local ask = wire(last().d)
as("Ann", false) -- (Ann's computer hasn't heard Bee's yet: she isn't here for it)
local n = #sent
assert(needlist.on_ask(cfgA, b, ask) == 0 and #sent == n, "dropped: an ask from a computer that isn't here (the bug: never asked again)")
as("Bee")
clock = clock + needlist.EV_RETRY - 1
assert(needlist.tick(cfgB, b) == 0, "not before EV_RETRY")
clock = clock + 1
assert(needlist.tick(cfgB, b) == 1 and last().d.evs and last().d.evs.main, "unanswered: the ids go again after EV_RETRY s, not at the next 30 s round without them")
clock = clock + needlist.EV_RETRY
assert(needlist.tick(cfgB, b) == 0, "the gap doubles")
clock = clock + needlist.EV_RETRY
assert(needlist.tick(cfgB, b) == 1 and last().d.evs, "after 2 x EV_RETRY")
ask = wire(last().d)
as("Ann", true) -- (now Ann's computer counts Bee's as here)
n = #sent
needlist.on_ask(cfgA, b, ask)
local answer
for k = n + 1, #sent do if sent[k].d.evs then answer = sent[k] end end
assert(answer and answer.kind == "need_list" and #answer.d.evs == 0 and answer.d.room == nil and answer.to[1] == "bee.ts.net:47281",
  "every day the same: Ann's computer answers with an empty list, so the asker knows")
as("Bee")
assert(needlist.on_list(cfgB, b, wire(answer.d)) == false, "(an empty answer asks for nothing)")
clock = clock + needlist.EVERY - 1
assert(needlist.tick(cfgB, b) == 0, "answered: no more asks before the round")
clock = clock + 1
assert(needlist.tick(cfgB, b) == 1 and last().d.evs == nil, "and the next round goes without the ids")

-- ---- 3. the first read of which media the song plays, within seconds -------------------------------------------------------------
for i = 1, 2700 do ev("RB", "Moe", { state = i == 2700 and 'FILE "{media:main}/b.wav"' or nil }) end -- (2,700 changes; the last plays b.wav)
local start = clock
needlist.on_list(cfgB, b, { dev = ANN, digest = "1|200", part = 1, of = 1, files = { { "main", "b.wav", 200 } } })
assert(needlist.wants["Song/main/b.wav"], "a bandmate lists b.wav, which Bee lacks")
local function here_b(w) return disk["RB/Song/rooms/" .. w.room .. "/media/" .. w.file] ~= nil end
local found, worst, ticks = nil, 0, 0
local next_look = clock
while clock - start < 60 and not found do
  if ticks % 30 == 0 then needlist.tick(cfgB, b) end -- (Live sync's sub-tick, once a second)
  local t0 = clock
  needlist.warm() -- (lib/streams.lua tick, every tick)
  worst = math.max(worst, clock - t0)
  if clock >= next_look then -- (catch-up's look, every CATCHUP_LOOK s)
    next_look = clock + streams.CATCHUP_LOOK
    local wants = needlist.pending({}, "Song", here_b)
    if #wants == 1 and wants[1].file == "b.wav" then found = clock - start end
  end
  clock, ticks = clock + 1 / 30, ticks + 1
end
assert(found and found <= 10, "2,700 changes: b.wav is wanted within 10 s of the list, not ~50 (" .. tostring(found) .. " s)")
assert(worst <= needlist.WARM + 2 * READ, "and no tick read for longer than WARM (" .. string.format("%.4f", worst) .. " s)")

-- a change that lands over the link is read at once, not when the cached look runs out
clock = clock + streams.CATCHUP_LOOK
assert(#needlist.pending({}, "Song", here_b) == 1, "(a fresh look: b.wav)")
local e_new = string.format("Moe-%s-100000Z-%05d-0001", TODAY, 99999)
needlist.ev_wanted["Song/main/" .. e_new] = { at = clock, path = "RB/Song/rooms/main/events/" .. e_new .. ".json", inbox = "H/direct/studio1/Song/rooms/main/events/" .. e_new .. ".json" }
needlist.on_list(cfgB, b, { dev = ANN, digest = "2|300", part = 1, of = 1, files = { { "main", "b.wav", 200 }, { "main", "c.wav", 100 } } })
clock = clock + 0.5
assert(#needlist.pending({}, "Song", here_b) == 0, "a change on its way: the bandmate's media waits")
evdirs["RB/Song/rooms/main/events"][e_new .. ".json"] = { id = e_new, oid = "{NEW}", time = "2026-11-21T11:00:00Z", state = 'FILE "{media:main}/c.wav"' }
onfile["RB/Song/rooms/main/events/" .. e_new .. ".json"] = true -- (it landed)
clock = clock + 0.5
local files_now = {}
for _, w in ipairs(needlist.pending({}, "Song", here_b)) do files_now[#files_now + 1] = w.file end
table.sort(files_now)
assert(table.concat(files_now, " ") == "b.wav c.wav", "it landed: the file it plays is wanted on the same look (" .. table.concat(files_now, " ") .. ")")

print("ok rt-catchup need list retry and first read")
