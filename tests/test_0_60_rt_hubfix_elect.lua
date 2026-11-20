-- rt-hubfix, part 2 (2026-11-20): the song's hub flipped between the desktop and the Mac 24 times in a day ("you're the hub for 'Cross Test'
-- now", then "Chilio-Mac is its hub now"). The two can't reach each other directly (the laptop reaches both), so each read the other's status
-- only as a file through Syncthing; whenever it came over 45 s late the desktop took the role, and gave it back when the file came. And the
-- Mac's extension (1.0.23) was too old for the hub's jobs. lib/hub.lua now: a late status still counts while a computer here says its link
-- reaches that one (hub.sees, VOUCH), a holder keeps counting HOLD s with nobody vouching, and an extension older than hub.EXT isn't elected
-- while a newer one is here. Here: (1) A and B can't reach each other, C reaches both, over 20 minutes of late files; (2) A and B alone;
-- (3) one computer with an older extension; (4) Live sync's tick end to end (the room's statuses from presence, this computer's ext and sees).
package.path = "lib/?.lua;" .. package.path
local ext, files, now_p = {}, {}, 1000
reaper = setmetatable({
  time_precise = function() return now_p end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  GetPlayState = function() return 1 end, -- (playing: the hub's restore-point job waits, so the tick is only the election)
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
local pref
package.loaded.groups = { trusted = function() return { hub = pref } end, role = function() return "member" end }
local hub = require("hub")

assert(hub.fit("1.0.28") and hub.fit("1.0.29") and hub.fit("1.1.0") and not hub.fit("1.0.23") and not hub.fit("") and not hub.fit(nil) and not hub.fit("0"),
  "the hub's jobs need extension " .. hub.EXT .. " or newer")
assert(hub.fits(nil) and hub.fits("1.0.28") and not hub.fits("1.0.23") and not hub.fits("0"), "a status that doesn't say (an older StudioSync) counts as before; no extension at all says 0")

-- ---- a small world: each computer elects from the statuses as they reach it ---------------------------------------------------------------
-- o: users (in order) = { name, since, ext, stubborn (an older StudioSync there: it says it holds the song's hub, whatever the others say, and
-- its status has neither ext nor sees) }; link(x, u): do x and u reach each other directly (a status crosses in 2 s); delay(x, u, t): how
-- late u's status file is at x without a link; quiet(u, t): u has stopped writing; T: seconds. Every computer starts believing `first` holds
-- the song's hub. -> per computer: changes (how often its view of the hub moved), hub (its view at the end), and agree_from (the time from
-- which all the computers that elect named the same hub, to the end).
local BASE, WARM = 2000000, 150
local function sim(o)
  local hist, state, names = {}, {}, {}
  for _, u in ipairs(o.users) do names[#names + 1] = u.name; hist[u.name] = {}; state[u.name] = { holds = u.name == o.first, hub = o.first, changes = 0, said = -math.huge } end
  local agree_from
  for t = 0, o.T, 2 do
    for _, u in ipairs(o.users) do -- (each writes its status every 15 s, and at once when what it holds changes)
      local s = state[u.name]
      if not (o.quiet and o.quiet(u.name, t)) and (t - s.said >= 15 or s.wrote ~= s.holds) then
        local sees = {}
        for _, v in ipairs(names) do if v ~= u.name and o.link(u.name, v) then sees[#sees + 1] = v end end
        hist[u.name][#hist[u.name] + 1] = { at = t, st = { user = u.name, machine = "m-" .. u.name, time = string.format("%010d", t),
          hub = { since = u.since, link = true, song = s.holds or nil, ext = not u.stubborn and u.ext or nil, sees = not u.stubborn and sees or nil } } }
        s.said, s.wrote = t, s.holds
      end
    end
    local views = {}
    for _, x in ipairs(o.users) do
      local s = state[x.name]
      if t >= WARM and not x.stubborn and not (o.quiet and o.quiet(x.name, t)) then -- (WARM: everyone's statuses have gone round once)
        local sts, sees = {}, {}
        for _, u in ipairs(names) do
          if u ~= x.name then
            local d, st = o.link(x.name, u) and 2 or o.delay(x.name, u, t), nil
            for _, h in ipairs(hist[u]) do if h.at <= t - d then st = h.st end end
            if st then sts[#sts + 1] = { song = "Song", st = st, seen = -math.huge } end
            if o.link(x.name, u) then sees[u] = true end
          end
        end
        local list = hub.candidates(sts, t, function(stamp) return t - tonumber(stamp) end)
        list[#list + 1] = { user = x.name, machine = "m-" .. x.name, since = x.since, link = true, ext = x.ext, sees = sees, songs = { Song = { holds = s.holds } } }
        list = hub.vouched(list)
        local song = hub.elect_song(list, "Song", nil, (hub.elect_studio(list, o.pref, BASE + t)), BASE + t)
        if song ~= s.hub then s.changes, s.hub = s.changes + 1, song end
        s.holds = song == x.name
        views[#views + 1] = tostring(song)
      end
    end
    local same = true
    for i = 2, #views do same = same and views[i] == views[1] end
    if #views > 0 then if not same then agree_from = nil elseif not agree_from then agree_from = t - WARM end end
  end
  local out = { agree_from = agree_from }
  for _, u in ipairs(o.users) do out[u.name] = state[u.name] end
  return out
end
local function linked(pairs_) return function(x, u) return pairs_[x .. "|" .. u] == true or pairs_[u .. "|" .. x] == true end end
-- (the file's trip through Syncthing: 8 s for two minutes, then 60 s for two minutes, and so on: with a status every 15 s it reads 60-75 s old)
local function hiccups(_, _, t) return t % 240 < 120 and 8 or 60 end

-- ---- 1. Desk and Mac can't reach each other, Lap reaches both; the Mac (online longest) holds the song's hub -------------------------------
local three = { { name = "Desk", since = BASE - 500, ext = "1.0.28" }, { name = "Lap", since = BASE - 600, ext = "1.0.28" }, { name = "Mac", since = BASE - 30000, ext = "1.0.28" } }
local world = { users = three, first = "Mac", pref = "Desk", T = 1200, link = linked({ ["Desk|Lap"] = true, ["Lap|Mac"] = true }), delay = hiccups }
local keep = { VOUCH = hub.VOUCH, HOLD = hub.HOLD }
hub.VOUCH, hub.HOLD = hub.FRESH, 0 -- (as it was: a status over FRESH s old doesn't count, whoever reaches its computer)
local was = sim(world)
assert(was.Desk.changes >= 8, "as it was: the desktop takes the role and gives it back with every late file (" .. was.Desk.changes .. " moves in 20 minutes)")
hub.VOUCH, hub.HOLD = keep.VOUCH, keep.HOLD
local r = sim(world)
assert(r.Desk.changes == 0 and r.Lap.changes == 0 and r.Mac.changes == 0, "now: nobody's view of the hub moves (Desk " .. r.Desk.changes .. ", Lap " .. r.Lap.changes .. ", Mac " .. r.Mac.changes .. ")")
assert(r.Desk.hub == "Mac" and r.Lap.hub == "Mac" and r.Mac.hub == "Mac" and r.agree_from == 0, "and the three agree on one hub throughout: the Mac, vouched by the laptop while its file is late at the desktop")
-- the Mac drops for real (it stops writing, and the laptop's link loses it: nobody vouches): the role moves once, to the studio's hub
local gone = sim({ users = three, first = "Mac", pref = "Desk", T = 900, delay = hiccups, quiet = function(u, t) return u == "Mac" and t >= 300 end,
  link = function(x, u) return linked({ ["Desk|Lap"] = true })(x, u) end })
assert(gone.Desk.hub == "Desk" and gone.Lap.hub == "Desk" and gone.Desk.changes == 1 and gone.Lap.changes == 1, "a hub that's really gone is still replaced, once")

-- ---- 2. Desk and Mac alone, each the other's status only as a late file: the holder is given HOLD s ----------------------------------------
local two = { { name = "Desk", since = BASE - 500, ext = "1.0.28" }, { name = "Mac", since = BASE - 30000, ext = "1.0.28" } }
local alone = { users = two, first = "Mac", pref = nil, T = 1200, link = function() return false end, delay = hiccups }
hub.VOUCH, hub.HOLD = hub.FRESH, 0
assert(sim(alone).Desk.changes >= 8, "as it was, two computers: the same flapping")
hub.VOUCH, hub.HOLD = keep.VOUCH, keep.HOLD
r = sim(alone)
assert(r.Desk.changes == 0 and r.Mac.changes == 0 and r.Desk.hub == "Mac", "now: files up to " .. hub.HOLD .. " s late don't move the role from whoever holds it")
r = sim({ users = two, first = "Mac", T = 600, link = function() return false end, delay = hiccups, quiet = function(u, t) return u == "Mac" and t >= 100 end })
assert(r.Desk.hub == "Desk" and r.Desk.changes == 1, "the holder gone for good: taken over once, after HOLD s")

-- ---- 3. one computer's extension is too old for the hub's jobs -----------------------------------------------------------------------------
local old_mac = { { name = "Desk", since = BASE - 500, ext = "1.0.28" }, { name = "Lap", since = BASE - 600, ext = "1.0.28" }, { name = "Mac", since = BASE - 30000, ext = "1.0.23" } }
r = sim({ users = old_mac, first = "Mac", pref = "Desk", T = 1200, link = linked({ ["Desk|Lap"] = true, ["Lap|Mac"] = true }), delay = hiccups })
assert(r.Desk.hub == "Desk" and r.Lap.hub == "Desk" and r.Mac.hub == "Desk", "the Mac's extension is 1.0.23: not the hub, though it held the role and is online longest; all three say Desk")
assert(r.Desk.changes == 1 and r.Lap.changes == 1 and r.Mac.changes == 1 and r.agree_from <= 4, "one move each, at once, and none after (agreed from " .. tostring(r.agree_from) .. " s)")
-- the Mac on an older StudioSync as well (until its update arrives): its status has no ext and keeps saying it holds the hub. It's left as
-- it was, steadily: no flapping, and an update reaching the computers one by one doesn't hand the role to whoever got it first
old_mac[3] = { name = "Mac", since = BASE - 30000, stubborn = true }
r = sim({ users = old_mac, first = "Mac", pref = "Desk", T = 1200, link = linked({ ["Desk|Lap"] = true, ["Lap|Mac"] = true }), delay = hiccups })
assert(r.Desk.hub == "Mac" and r.Lap.hub == "Mac" and r.Desk.changes == 0 and r.Lap.changes == 0, "a status that doesn't say its extension: as before, and steady")
-- everyone's is old (a studio just updated, nobody restarted REAPER yet): the role still goes to someone, as before
local c = function(user, since, t) t.user, t.since, t.machine, t.songs = user, since, "m-" .. user, { Song = { holds = t.holds } }; return t end
assert(hub.elect_song({ c("A", 5, { link = true, ext = "1.0.23" }), c("B", 9, { link = true, ext = "0" }) }, "Song", nil, nil, BASE) == "A", "nobody's extension is new enough: the ranking, as before")
assert(hub.elect_studio({ c("A", 5, { link = true, ext = "1.0.23" }), c("B", 9, { link = true, ext = "1.0.29" }) }, "A", BASE) == "B", "the owner's pick with an old extension isn't the studio hub while a newer one is online")

-- ---- 4. Live sync's tick: this computer's status says its extension and whom its link reaches; the room's statuses come from presence ------
do
  local cfg, b = { root = "R", user = "Bo" }, { song = "Song", room = "main" }
  local function iso(ago) return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - ago) end
  ext["BandSync/hub since"] = tostring(os.time() - 1000) -- (online a while: past hub.LISTEN)
  ext["BandSync/menu extension"] = "1.0.28"
  files["R/Song/session.json"] = {} -- (no sharer known here: the song has no home, as while the desktop and the Mac flapped)
  band.songs = function() return { "Song" } end
  band.subdirs = function(d) return d == "R/Song/rooms" and { "main" } or {} end
  band.files = function(d) if d == "R/Song/rooms/main/status" then return { "Desk.json", "Lap.json" } end return {} end
  -- Desk holds the song's hub; its file is 100 s old here. Lap's is fresh, and says its link reaches Desk
  files["R/Song/rooms/main/status/Desk.json"] = { user = "Desk", machine = "md", time = iso(100), hub = { since = os.time() - 9000, link = true, song = true, ext = "1.0.28" } }
  files["R/Song/rooms/main/status/Lap.json"] = { user = "Lap", machine = "ml", time = iso(3), hub = { since = os.time() - 500, link = true, ext = "1.0.28", sees = { "Bo", "Desk" } } }
  local room = {}
  package.loaded.presence = { peers = function() return room end }
  package.loaded.direct = { available = function() return true end, live_available = function() return true end, firewall_ok = function() return true end,
    reach = function() return { Lap = { ok = true, at = os.time() }, Desk = { ok = false, at = os.time() } } end }
  package.loaded.removal = { guest_names = function() return {} end }
  package.loaded.trust = { own_file_ok = function() return true end, user_file = function(u) return u .. ".json" end }
  package.loaded.sync = { machine = function() return "mbo" end, loading = {}, room_dir = function(_, s, rm) return "R/" .. s .. "/rooms/" .. rm end }
  package.loaded.recall = { dir = function() return "R/Song/rooms/main/recall" end, save = function() end }
  local function tick() now_p = now_p + hub.SCAN_EVERY + 1; hub.tick("P", cfg, b); return band.ext_json(band.SECTION, "hub view studio1 Song") end
  local v = tick()
  assert(v.hub == "Desk" and v.why == "kept", "Desk's file is 100 s old here, but Lap's link reaches it: Desk keeps the song's hub (" .. tostring(v.hub) .. ")")
  local part = hub.status_part(cfg, b)
  assert(part.ext == "1.0.28" and type(part.sees) == "table" and #part.sees == 1 and part.sees[1] == "Lap", "this computer's status: its extension, and those its link reaches (Lap, not Desk)")
  -- Lap stops vouching (its link lost Desk too): Desk's 100 s are past HOLD, so the role moves
  files["R/Song/rooms/main/status/Lap.json"].hub.sees = { "Bo" }
  v = tick()
  assert(v.hub ~= "Desk" and v.hub ~= nil, "nobody reaches Desk and its status is " .. hub.HOLD .. " s past: replaced (" .. tostring(v.hub) .. ")")
  -- the room's statuses as the link brought them count before the files do: Desk's fresh word over the link, its file still old
  files["R/Song/rooms/main/status/Desk.json"].time = iso(140)
  room = { { user = "Desk", machine = "md", time = iso(1), hub = { since = os.time() - 9000, link = true, song = true, ext = "1.0.28" } } }
  v = tick()
  assert(v.hub == "Desk", "Desk's status over the link is a second old: it's here, and the better-ranked holder (" .. tostring(v.hub) .. ")")
  -- an older extension there: passed over, and Health says who and why
  room = { { user = "Desk", machine = "md", time = iso(1), hub = { since = os.time() - 9000, link = true, song = true, ext = "1.0.23" } } }
  v = tick()
  assert(v.hub ~= "Desk" and v.hub ~= nil and type(v.old) == "table" and v.old[1] == "Desk", "Desk's extension is 1.0.23: not the hub while a newer one is here")
  assert(hub.line(v, "Bo"):find("Not a hub until REAPER restarts there with StudioSync's extension " .. hub.EXT .. " or newer: Desk.", 1, true), "Health: " .. hub.line(v, "Bo"))
  -- and this computer with the old one: it gives the role up itself
  ext["BandSync/menu extension"] = "1.0.23"
  room[1].hub.ext = "1.0.28"
  v = tick()
  assert(v.hub == "Desk" and hub.status_part(cfg, b).song == nil and hub.status_part(cfg, b).ext == "1.0.23", "this computer's extension is the old one: it holds no hub role")
  -- only old ones here: the hub's own extension can't mix, and the view says so (lib/liveaudio.lua hub_plan: peer to peer, with why)
  room[1].hub.ext = "1.0.23"
  files["R/Song/rooms/main/status/Lap.json"].hub.ext = "1.0.23"
  v = tick()
  assert(v.hub ~= nil and v.hub_fit == false and v.old == nil, "nobody's extension is new enough: someone still holds the role, and the view says it can't mix")
end

print("ok: rt-hubfix (the hub's election: late statuses vouched by a third computer, a holder's grace, old extensions passed over)")
