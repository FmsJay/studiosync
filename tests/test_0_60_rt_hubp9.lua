-- rt-p9 (2026-11-21, backlog package P9: items 1.20 and 4.d). lib/hub.lua and lib/livex.lua:
--   1. a computer whose Syncthing is paused isn't a second hub: it hears bandmates over the direct link whose status files haven't come
--      (hub.lagging), says `lag` in its status, and nobody elects it, itself included (every computer reads the same word in its status);
--   2. a song's home that two bandmates can't reach is passed over once another is reached by all, after REACH_SETTLE s, and hosts again
--      once reached for as long (the backlog's section 4 default, question d);
--   3. a guest counts as one each must reach, by that computer's own word (never the guest's);
--   4. a computer that just came online isn't named by the others before it takes the role itself (their HANDBACK against its LISTEN).
-- The live mix's host settling a reach move over REACH_SETTLE s, not SETTLE, is rt-hubsmall's (tests/test_0_60_rt_hubsmall.lua part 6).
package.path = "lib/?.lua;" .. package.path
local ext, files, now_p = {}, {}, 1000
reaper = setmetatable({
  time_precise = function() return now_p end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  GetPlayState = function() return 1 end, -- (playing: the restore-point job waits, so the tick is only the election)
  GetProjectStateChangeCount = function() return 1 end,
  EnumProjects = function() return "P" end,
}, { __index = function() return function() return "" end end })
local band = require("band")
band.info = function() return { id = "studio1", name = "Smiley" } end
band.log = function() end
band.read_json = function(p) return files[p] end
band.write_json = function(p, t) files[p] = t end
band.files = function() return {} end
band.listing = function() return {} end
package.loaded.groups = { trusted = function() return {} end, role = function() return "member" end }
local hub = require("hub")
local livex = require("livex")
local T = 2000000
local function iso(ago) return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - ago) end

-- A room as candidates: names (the first online longest), links "A-B" (both ways), x[name] = { holds, off, lag, since }.
local function room(names, links, x)
  local set, list = {}, {}
  for a, b2 in links:gmatch("(%w+)%-(%w+)") do set[a .. "|" .. b2], set[b2 .. "|" .. a] = true, true end
  for i, n in ipairs(names) do
    local o = (x or {})[n] or {}
    local sees = {}
    for _, m in ipairs(names) do if m ~= n and set[n .. "|" .. m] then sees[m] = true end end
    list[#list + 1] = { user = n, machine = "m-" .. n, since = o.since or (T - 100000 + i * 1000), link = true, off = o.off, lag = o.lag, ext = "1.0.28",
      songs = { Song = { holds = o.holds, sees = sees } } }
  end
  return list
end
local function elect(list, home, studio, now, mem, gs) hub.reach(list, "Song", gs); return hub.elect_song(list, "Song", home, studio, now or T, mem) end

-- ---- 1. Syncthing paused: not a second hub ----------------------------------------------------------------------------------------------
do
  -- the pure word: two or more heard over the link, none with a status file here under VOUCH s old
  local live = { Pi = { user = "Pi", time = iso(2) }, Qu = { user = "Qu", time = iso(3) } }
  assert(hub.lagging(live, {}) == true, "two bandmates heard on the link, neither's status file here: this computer's Syncthing is behind")
  assert(hub.lagging(live, { { user = "Qu" } }) == false, "one of them has a file here: it's their Syncthing, not this one's")
  assert(hub.lagging({ Pi = live.Pi }, {}) == false, "one bandmate alone can't tell whose Syncthing it is: two computers never lag")
  assert(hub.lagging({ Pi = live.Pi, Qu = { user = "Qu", time = iso(600) } }, {}) == false, "a link status gone old doesn't count as heard")
  assert(hub.lagging(nil, {}) == false, "nothing from the link: no word")
  -- the others' view: Mo holds the song's hub; Lin (Syncthing paused, its own Mo file stale) claims it too, over the link
  local list = room({ "Lin", "Mo", "Pi", "Qu" }, "Lin-Pi Lin-Qu Mo-Pi Mo-Qu Pi-Qu", { Mo = { holds = true }, Lin = { holds = true, lag = true } })
  local u, why = elect(list, nil, nil, T, {}) -- (with the tick's memory: Mo, missed by Lin, isn't moved at first sight)
  assert(u == "Mo" and why == "kept", "two say they hold it, one of them says its Syncthing is behind: the other keeps it, on every computer (" .. tostring(u) .. ")")
  list = room({ "Lin", "Mo", "Pi", "Qu" }, "Lin-Pi Lin-Qu Mo-Pi Mo-Qu Pi-Qu", { Lin = { lag = true } })
  assert(elect(list) == "Pi", "nobody holds it: never the one behind, though it's online longest")
  assert(hub.elect_studio(list, "Lin", T) ~= "Lin", "nor the studio hub, though it's the owner's pick")
  list = room({ "Lin", "Pi" }, "Lin-Pi", { Lin = { lag = true }, Pi = { lag = true } })
  assert(elect(list) == "Lin", "everyone says so: as before (the roles still go to someone)")
  -- Live sync's tick on the paused computer: the statuses' files are 10 minutes old, two bandmates heard over the link; Mo (the holder)
  -- isn't reached from here at all
  local cfg, b = { root = "R", user = "Lin" }, { song = "Song", room = "main" }
  ext["BandSync/hub since"] = tostring(os.time() - 1000)
  ext["BandSync/menu extension"] = "1.0.28"
  files["R/Song/session.json"] = {}
  band.songs = function() return { "Song" } end
  band.subdirs = function(d) return d == "R/Song/rooms" and { "main" } or {} end
  band.files = function(d) return d == "R/Song/rooms/main/status" and { "Mo.json", "Pi.json", "Qu.json" } or {} end
  local function st(user, ago, since, sees, holds) return { user = user, machine = "m" .. user, time = iso(ago), hub = { since = os.time() - since, link = true, ext = "1.0.28", sees = sees, song = holds } } end
  files["R/Song/rooms/main/status/Mo.json"] = st("Mo", 600, 9000, { "Pi", "Qu" }, true)
  files["R/Song/rooms/main/status/Pi.json"] = st("Pi", 600, 500, { "Lin", "Mo", "Qu" })
  files["R/Song/rooms/main/status/Qu.json"] = st("Qu", 600, 400, { "Lin", "Mo", "Pi" })
  local live_now = { Pi = st("Pi", 2, 500, { "Lin", "Mo", "Qu" }), Qu = st("Qu", 3, 400, { "Lin", "Mo", "Pi" }) }
  package.loaded.presence = { peers = function() return { live_now.Pi, live_now.Qu } end, live = function() return live_now end }
  package.loaded.direct = { available = function() return true end, live_available = function() return true end, firewall_ok = function() return true end,
    reach = function() return { Pi = { ok = true, at = os.time() }, Qu = { ok = true, at = os.time() } } end }
  package.loaded.removal = { guest_names = function() return {} end }
  package.loaded.trust = { own_file_ok = function() return true end, user_file = function(n) return n .. ".json" end }
  package.loaded.sync = { machine = function() return "mLin" end, loading = {}, room_dir = function(_, s, rm) return "R/" .. s .. "/rooms/" .. rm end }
  package.loaded.recall = { dir = function() return "R/Song/rooms/main/recall" end, save = function() end }
  local function tick() now_p = now_p + hub.SCAN_EVERY + 1; hub.tick("P", cfg, b); return band.ext_json(band.SECTION, "hub view studio1 Song") end
  local v = tick()
  assert(v.hub ~= "Lin" and v.lag == true, "the paused computer doesn't make itself the song's hub (it did: online longest of those it could see) (" .. tostring(v.hub) .. ")")
  assert(hub.status_part(cfg, b).lag == true and hub.status_part(cfg, b).song == nil, "its status says so, and that it holds nothing")
  assert(hub.line(v, "Lin"):find("Syncthing is behind here", 1, true), "Health says why: " .. hub.line(v, "Lin"))
  -- Syncthing runs again: the files come, the word goes, and Mo (holding) keeps it
  for _, n in ipairs({ "Mo", "Pi", "Qu" }) do files["R/Song/rooms/main/status/" .. n .. ".json"].time = iso(2) end
  v = tick()
  assert(v.lag == nil and hub.status_part(cfg, b).lag == nil and v.hub == "Mo" and v.why == "kept", "Syncthing back: no word, and the holder keeps it (" .. tostring(v.hub) .. ")")
end

-- ---- 2. a home that two bandmates can't reach (backlog 4.d) ---------------------------------------------------------------------------
do
  -- Ho is the song's home; Al and Bo can't reach it; Cy reaches everybody
  local FAR = "Ho-Cy Al-Bo Al-Cy Bo-Cy"
  local u, why, passed = elect(room({ "Ho", "Al", "Bo", "Cy" }, FAR), "Ho")
  assert(u == "Cy" and why == "ranked" and passed == 2, "two can't reach the home, everybody reaches Cy: Cy hosts (" .. tostring(u) .. ", " .. tostring(passed) .. ")")
  u, why = elect(room({ "Ho", "Al", "Bo", "Cy" }, "Ho-Cy Ho-Bo Al-Bo Al-Cy Bo-Cy"), "Ho")
  assert(u == "Ho" and why == "home", "only one can't reach it: the home hosts, as before")
  u, why = elect(room({ "Ho", "Al", "Bo", "Cy" }, "Ho-Cy Al-Cy"), "Ho")
  assert(u == "Ho" and why == "home", "two can't reach it, but nobody else is reached by all either (Bo reaches nobody): the home hosts")
  u = elect(room({ "Ho", "Al", "Bo", "Cy" }, FAR, { Ho = { holds = true } }), "Ho")
  assert(u == "Cy", "passed over, it doesn't keep it as the one holding it either")
  -- the settling time: not at once, after REACH_SETTLE; and back once reached for as long
  local mem = {}
  local far, near = room({ "Ho", "Al", "Bo", "Cy" }, FAR, { Ho = { holds = true } }), room({ "Ho", "Al", "Bo", "Cy" }, "Ho-Al Ho-Bo Ho-Cy Al-Bo Al-Cy Bo-Cy", { Cy = { holds = true } })
  assert(elect(far, "Ho", nil, T, mem) == "Ho", "with the tick's memory: the home hosts at first sight of it")
  assert(elect(far, "Ho", nil, T + hub.REACH_SETTLE - 1, mem) == "Ho", "nor a second before REACH_SETTLE")
  u, why, passed = elect(far, "Ho", nil, T + hub.REACH_SETTLE, mem)
  assert(u == "Cy" and passed == 2, "after REACH_SETTLE s of it: Cy")
  assert(elect(near, "Ho", nil, T + hub.REACH_SETTLE + 5, mem) == "Cy", "reached again: not at once (a link back for a moment moves nothing)")
  elect(far, "Ho", nil, T + hub.REACH_SETTLE + 10, mem) -- (a break in it)
  assert(elect(near, "Ho", nil, T + hub.REACH_SETTLE * 2 + 6, mem) == "Cy", "a break starts the count again")
  assert(elect(near, "Ho", nil, T + hub.REACH_SETTLE * 3 + 11, mem) == "Ho", "reached for REACH_SETTLE s: the home hosts again")
  -- a link that drops for a moment doesn't pass it over
  mem = {}
  local near_h = room({ "Ho", "Al", "Bo", "Cy" }, "Ho-Al Ho-Bo Ho-Cy Al-Bo Al-Cy Bo-Cy", { Ho = { holds = true } })
  for t = 0, 600, 2 do
    local list = (t % 60 < 20) and room({ "Ho", "Al", "Bo", "Cy" }, FAR, { Ho = { holds = true } }) or near_h
    assert(elect(list, "Ho", nil, T + t, mem) == "Ho", "the home's links to two drop 20 s a minute: it hosts throughout (" .. t .. ")")
  end
  -- Health's words
  local line = hub.line({ hub = "Cy", why = "ranked", home = "Ho", passed = 2, far = nil }, "Al")
  assert(line:find("Ho is the project's home but 2 here can't reach it directly", 1, true), "Health: " .. line)
  line = hub.line({ hub = "Cy", why = "kept", home = "Ho", passed = 2 }, "Al")
  assert(line:find("holding it, Ho is the project's home but 2 here", 1, true), "Health (kept): " .. line)
  assert(hub.line({ hub = "Cy", why = "ranked", home = "Ho" }, "Al"):find("Ho is away", 1, true), "an away home: as before")
end

-- ---- 3. a guest counts as one each must reach, by that computer's own word ------------------------------------------------------------
do
  -- Al holds; Gu is a guest Al doesn't reach and Bo does; everybody else reaches everybody
  local list = room({ "Al", "Bo", "Ca", "Gu" }, "Al-Bo Al-Ca Bo-Ca Bo-Gu Ca-Gu", { Al = { holds = true } })
  local gs = { Gu = true }
  hub.reach(list, "Song", gs)
  local byn = {}
  for _, c in ipairs(list) do byn[c.user] = c end
  assert(byn.Al.miss == 1 and byn.Bo.miss == 0 and byn.Gu.miss == nil, "Al doesn't reach the guest: one miss; Bo does: none; the guest has no numbers")
  local guestless = {}
  for _, c in ipairs(list) do if c.user ~= "Gu" then guestless[#guestless + 1] = c end end -- (guests are dropped before the election)
  local mem = {}
  assert(elect(list, nil, nil, T, mem, gs) == "Al" and hub.elect_song(guestless, "Song", nil, nil, T + hub.REACH_SETTLE, mem) == "Bo",
    "a hub the guest can't reach is moved, after the settling time, to one it can (" .. tostring(hub.elect_song(guestless, "Song", nil, nil, T + hub.REACH_SETTLE, mem)) .. ")")
  -- the guest's own word moves nothing: it says it reaches only Ca
  list = room({ "Al", "Bo", "Ca", "Gu" }, "Al-Bo Al-Ca Bo-Ca Al-Gu Bo-Gu Ca-Gu", { Al = { holds = true } })
  for _, c in ipairs(list) do if c.user == "Gu" then c.songs.Song.sees = { Ca = true } end end
  hub.reach(list, "Song", gs)
  for _, c in ipairs(list) do if c.user ~= "Gu" then assert(c.miss == 0, "the guest leaves " .. c.user .. " out: not counted") end end
  -- Health: who has no link to the hub, a guest by the hub's word
  list = room({ "Al", "Bo", "Gu" }, "Al-Bo Bo-Gu", {})
  for _, c in ipairs(list) do if c.user == "Gu" then c.songs.Song.sees = { Al = true, Bo = true } end end
  assert(table.concat(hub.far(list, "Song", "Al", gs), ",") == "Gu", "the hub doesn't reach the guest: Health names it, whatever the guest says")
end

-- ---- 4. a computer just come online isn't named before it takes the role itself -------------------------------------------------------
do
  -- Ne came online 10 s ago and ranks first (link, machine id), nobody holds: its own view (listening) passes itself over; so do the others now
  local list = room({ "Ne", "Ol" }, "Ne-Ol", { Ne = { since = T - 10 }, Ol = { since = T - 5000 } })
  for _, c in ipairs(list) do if c.user == "Ne" then c.machine = "a" end end
  local own = {}
  for i, c in ipairs(list) do own[i] = c end
  local me = { user = "Ne", machine = "a", since = T - 10, link = true, ext = "1.0.28", listening = true, songs = { Song = { sees = { Ol = true } } } }
  own[1] = me
  local theirs = elect(list, nil, nil, T)
  assert(theirs == "Ol" and elect(own, nil, nil, T) == "Ol", "the others name Ol, as Ne's own view does (they named Ne for its first 45 s) (" .. tostring(theirs) .. ")")
  -- the home back from a restart: named once it's past LISTEN, by everyone at the same moment
  list = room({ "Ho", "Ol" }, "Ho-Ol", { Ho = { since = T - 3 }, Ol = { holds = true } })
  assert(elect(list, "Ho", nil, T + hub.HANDBACK) == "Ol", "the home on for HANDBACK s but still listening: not named yet (it was, 15 s before it took it)")
  assert(elect(list, "Ho", nil, T - 3 + hub.LISTEN) == "Ho", "past LISTEN: the home hosts")
  assert(hub.elect_studio(room({ "Ne" }, "", { Ne = { since = T - 10 } }), nil, T) == nil, "alone and just come online: nobody yet, as its own view says")
end

-- ---- 5. Live sync's tick: the guest and the home end to end ---------------------------------------------------------------------------
do
  local src = assert(io.open("lib/hub.lua", "rb")):read("a")
  assert(src:find("hub.reach(list, b.song, gs)", 1, true) and src:find("hub.far(room, b.song, song, gs)", 1, true), "the tick counts the room's guests by the others' word")
  assert(src:find("passed = passed, lag = lag or nil", 1, true), "and publishes the passed-over home and the lag for Health")
end

print("ok: rt-p9 (Syncthing paused isn't a second hub, a home two can't reach, guests' reach, no naming before LISTEN)")
