-- The studio's hub and each song's (lib/hub.lua; docs/realtime-roadmap.md "More big ideas" 1): the election every computer works out alike
-- (offline, ties, flapping, hand-back, a member never online with another), a song's home and its handovers, the statuses read into candidates,
-- when the song hub keeps a restore point (never while playing or recording, only idle, within its budget), and Health's line. (James, rt)
package.path = "lib/?.lua;" .. package.path
local ext, files, now_p, play, cc = {}, {}, 1000, 0, 1
reaper = setmetatable({
  time_precise = function() return now_p end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  GetPlayState = function() return play end,
  GetProjectStateChangeCount = function() return cc end,
  EnumProjects = function() return "P" end,
}, { __index = function() return function() return "" end end })
local band = require("band")
band.info = function() return { id = "studio1", name = "Smiley" } end
band.log = function() end
band.read_json = function(p) return files[p] end
band.write_json = function(p, t) files[p] = t end
band.files = function() return {} end
band.listing = function() return { "a.json", "b.json" } end
local groups_role = { Owner = "owner", Adm = "admin" }
package.loaded.groups = { trusted = function() return { hub = ext.pref } end, role = function(_, u) return groups_role[u] or "member" end }
local hub = require("hub")

local T = 1000000 -- os.time-like "now" for the pure checks
local function c(user, since, t) t = t or {}; t.user, t.since, t.machine = user, since, t.machine or ("m-" .. user); t.songs = t.songs or {}; return t end

-- ---- studio hub: preferred, kept, ranked ----
do
  local desk, lap, mac, linux = c("Desk", T - 500, { link = true }), c("Lap", T - 900, { link = true }), c("Mac", T - 2000), c("Linux", T - 100, { link = true })
  local all = { desk, lap, mac, linux }
  assert(hub.elect_studio(all, "Desk", T) == "Desk", "the owner's preferred computer, online")
  local u, why = hub.elect_studio(all, nil, T)
  assert(u == "Lap" and why == "ranked", "no preference: the link listening first, then online longest (Lap over Desk and Linux; Mac has no link)")
  -- the same answer whatever order the computers are listed in (every computer sees them in its own order)
  assert(hub.elect_studio({ linux, mac, lap, desk }, nil, T) == "Lap" and hub.elect_studio({ mac, desk, linux, lap }, nil, T) == "Lap", "order doesn't matter")
  -- ties: the same since, the same link: machine id, then name
  local a, b2 = c("Al", T - 10, { link = true, machine = "bbbb" }), c("Bo", T - 10, { link = true, machine = "aaaa" })
  assert(hub.elect_studio({ a, b2 }, nil, T) == "Bo" and hub.elect_studio({ b2, a }, nil, T) == "Bo", "a tie goes to the lower machine id, either way round")
  local x, y = c("Xa", T - 10, { link = true, machine = "same" }), c("Ya", T - 10, { link = true, machine = "same" })
  assert(hub.elect_studio({ y, x }, nil, T) == "Xa", "and then the name")
  -- preferred offline: the ranking; nobody at all
  assert(hub.elect_studio({ lap, mac }, "Desk", T) == "Lap", "preferred offline: the ranking")
  assert(hub.elect_studio({}, "Desk", T) == nil and select(2, hub.elect_studio({}, "Desk", T)) == "nobody", "nobody online")
  -- handed on: never chosen, even when preferred
  local deskoff = c("Desk", T - 500, { link = true, off = true })
  assert(hub.elect_studio({ deskoff, mac }, "Desk", T) == "Mac", "a computer that handed the role on isn't chosen, even the preferred one")
  assert(hub.elect_studio({ deskoff }, "Desk", T) == nil, "the only one online handed it on: nobody (the cloud copy stands in)")
end

-- ---- no flapping: whoever holds it keeps it; the preferred one gets it back once it's been on a while ----
do
  local lap = c("Lap", T - 900, { link = true, studio = true })
  local linux = c("Linux", T - 5000, { link = true }) -- (ranks higher, but Lap holds it)
  local u, why = hub.elect_studio({ lap, linux }, nil, T)
  assert(u == "Lap" and why == "kept", "a better-ranked newcomer doesn't take it from whoever holds it")
  -- the desktop (preferred) comes back: not at once while someone holds it ...
  local desk = c("Desk", T - 5, { link = true })
  assert(hub.elect_studio({ lap, linux, desk }, "Desk", T) == "Lap", "preferred back 5 s: Lap keeps it a moment (a computer dropping in and out doesn't flap the role)")
  -- ... then handed back once it's been on HANDBACK s
  assert(hub.elect_studio({ lap, linux, desk }, "Desk", T + hub.HANDBACK) == "Desk", "preferred on long enough: handed back")
  -- and while nobody holds it, at once
  local lap2 = c("Lap", T - 900, { link = true })
  assert(hub.elect_studio({ lap2, desk }, "Desk", T) == "Desk", "nobody holds it: the preferred one at once")
  -- two holding it at once (a handover's moment, views apart): the better-ranked holder, and the other lets go next time
  local l3, m3 = c("Lap", T - 900, { link = true, studio = true }), c("Mac", T - 950, { link = true, studio = true })
  assert(hub.elect_studio({ l3, m3 }, nil, T) == "Mac" and hub.elect_studio({ m3, l3 }, nil, T) == "Mac", "two holders: the same one wins on every computer")
  -- the holder goes offline (its status goes stale: it's simply not a candidate any more): the ranking, within one status read
  assert(hub.elect_studio({ linux, desk }, nil, T) == "Linux", "holder offline: the next one")
  -- simulate a run: Lap holds; Desk (preferred) flickers on and off every 10 s: Lap keeps it throughout
  local holder = "Lap"
  for i = 0, 6 do
    local list = { c("Lap", T - 900, { link = true, studio = holder == "Lap" }) }
    if i % 2 == 0 then list[#list + 1] = c("Desk", T + i * 10 - 3, { link = true, studio = holder == "Desk" }) end
    holder = hub.elect_studio(list, "Desk", T + i * 10)
    assert(holder == "Lap", "a flickering preferred computer never takes it (step " .. i .. ")")
  end
end

-- ---- failover in seconds: the direct link's view (second slice) ----
do
  local mem = {}
  local live = function(at) return { ok = true, at = at } end
  local gone = hub.link_watch(mem, { Lap = live(T), Desk = live(T) }, T)
  assert(not next(gone), "both answering: nobody gone")
  -- the hub (Lap) stops answering: not at once (one dropped ping, then the extension waits 10 s before trying again) ...
  gone = hub.link_watch(mem, { Lap = { ok = false, at = T + 1 }, Desk = live(T + 2) }, T + 2)
  assert(not gone.Lap, "one failed ping: not gone yet")
  gone = hub.link_watch(mem, { Lap = { ok = false, at = T + 1 }, Desk = live(T + 10) }, T + 10)
  assert(not gone.Lap, "8 s: not yet")
  -- ... a blip: it answers at the retry, and was never gone
  gone = hub.link_watch(mem, { Lap = live(T + 11), Desk = live(T + 11) }, T + 12)
  assert(not gone.Lap and not mem.Lap.back, "it answered again within LINK_GONE: never counted out, no hand-back wait")
  -- ... really gone: within LINK_GONE s of the first failure, well before its status file goes stale (45 s)
  hub.link_watch(mem, { Lap = { ok = false, at = T + 20 }, Desk = live(T + 20) }, T + 20)
  gone = hub.link_watch(mem, { Lap = { ok = false, at = T + 30 }, Desk = live(T + 32) }, T + 20 + hub.LINK_GONE)
  assert(gone.Lap and not gone.Desk, "no answer for LINK_GONE s: gone")
  -- the election without it: the next computer at once, though Lap's (fresh) status still says it holds the role
  local lap, desk = c("Lap", T - 900, { link = true, studio = true }), c("Desk", T - 500, { link = true })
  local u = hub.elect_studio(hub.drop({ lap, desk }, gone), nil, T + 32)
  assert(u == "Desk", "the holder the link lost: the next one takes over")
  -- an answer that stopped coming (ok, but old) counts as failing too
  local m2 = {}
  hub.link_watch(m2, { Bo = live(T) }, T)
  hub.link_watch(m2, { Bo = live(T) }, T + hub.LINK_GONE)
  assert(hub.link_watch(m2, { Bo = live(T) }, T + 2 * hub.LINK_GONE).Bo, "nothing answered for 2 x LINK_GONE: gone")
  -- one the link never reached (no extension there, no firewall rule): left to its status file
  local m3 = {}
  assert(not next((hub.link_watch(m3, { Mac = { ok = false, at = T } }, T))) and not next((hub.link_watch(m3, { Mac = { ok = false, at = T } }, T + 100))), "never reached: never counted out by the link")
  -- back: the preferred computer the link lost and found again waits HANDBACK s from then (not from its since), so it doesn't flap the role
  local _, back = hub.link_watch(mem, { Lap = live(T + 40), Desk = live(T + 40) }, T + 40)
  assert(back.Lap == T + 40, "found again: back from now")
  local lap_back, desk_h = c("Lap", T - 900, { link = true }), c("Desk", T - 500, { link = true, studio = true })
  assert(hub.elect_studio(hub.drop({ lap_back, desk_h }, {}, nil, back), "Lap", T + 40) == "Desk", "the preferred one back on the link: the holder keeps it a moment")
  _, back = hub.link_watch(mem, { Lap = live(T + 40 + hub.HANDBACK), Desk = live(T + 40 + hub.HANDBACK) }, T + 40 + hub.HANDBACK)
  assert(hub.elect_studio(hub.drop({ lap_back, desk_h }, {}, nil, back), "Lap", T + 40 + hub.HANDBACK) == "Lap", "and takes it back HANDBACK s later")
  -- a computer that left the link's list (its status stale, or this computer moved to another song) isn't counted out by it
  gone = hub.link_watch(mem, { Desk = live(T + 80) }, T + 80)
  assert(not gone.Lap and mem.Lap.out, "out of the link's list: the status files decide")
  -- guests are never a hub, preferred or not
  local g = c("Gus", T - 9000, { link = true })
  assert(hub.elect_studio(hub.drop({ g, desk }, {}, { Gus = true }), "Gus", T) == "Desk", "a guest isn't a candidate, even preferred")
  assert(hub.elect_song(hub.drop({ c("Gus", T - 9000, { songs = { S = {} } }) }, {}, { Gus = true }), "S", "Gus", nil, T) == nil, "a guest's song: nobody (the cloud copy stands in)")
end

-- ---- a song's home: whoever shared it, and its handovers ----
do
  local may = function(u) return u == "Owner" or u == "Adm" end
  assert(hub.home_of("Bo", nil, may) == "Bo", "no handovers: whoever shared it")
  local h, moved = hub.home_of("Bo", { { to = "Desk", by = "Bo", at = 10 } }, may)
  assert(h == "Desk" and moved, "the sharer hands it on")
  assert(hub.home_of("Bo", { { to = "Mac", by = "Chilio", at = 10 } }, may) == "Bo", "a member who's neither sharer, hub nor in charge is passed over")
  assert(hub.home_of("Bo", { { to = "Desk", by = "Bo", at = 10 }, { to = "Mac", by = "Desk", at = 20 } }, may) == "Mac", "the hub now hands it on")
  assert(hub.home_of("Bo", { { to = "Mac", by = "Desk", at = 20 }, { to = "Desk", by = "Bo", at = 10 } }, may) == "Mac", "in time order, whatever order the file has")
  assert(hub.home_of("Bo", { { to = "Lap", by = "Owner", at = 5 } }, may) == "Lap" and hub.home_of("Bo", { { to = "Lap", by = "Adm", at = 5 } }, may) == "Lap", "the owner or an admin")
  assert(hub.home_of("Bo", { { to = "Lap", by = "Bo", at = 5 }, { to = "Bo", by = "Lap", at = 6 } }, may) == "Bo" and not select(2, hub.home_of("Bo", { { to = "Lap", by = "Bo", at = 5 }, { to = "Bo", by = "Lap", at = 6 } }, may)), "handed back to the sharer")
  assert(hub.home_of("Bo", { { to = "", by = "Bo" }, "junk", { by = "Bo" } }, may) == "Bo", "broken rows are passed over")
  -- the same second: settled by who and to whom, the same everywhere
  local a = hub.home_of("Bo", { { to = "X", by = "Bo", at = 7 }, { to = "Y", by = "Bo", at = 7 } }, may)
  local b2 = hub.home_of("Bo", { { to = "Y", by = "Bo", at = 7 }, { to = "X", by = "Bo", at = 7 } }, may)
  assert(a == b2, "two handovers in one second: one answer whatever the order")
end

-- ---- song hub: home, kept, studio hub, ranking, cloud ----
do
  local function in_song(user, since, t) t = t or {}; t.songs = { Song = { holds = t.holds } }; return c(user, since, t) end
  local bo, desk, mac = in_song("Bo", T - 100), in_song("Desk", T - 900, { link = true }), in_song("Mac", T - 3000)
  local u, why = hub.elect_song({ bo, desk, mac }, "Song", "Bo", "Desk", T)
  assert(u == "Bo" and why == "home", "its home (whoever shared it) when they're in the song")
  u, why = hub.elect_song({ desk, mac }, "Song", "Bo", "Desk", T)
  assert(u == "Desk" and why == "studio", "home offline: the studio hub, when it has the song open")
  local elsewhere = c("Desk", T - 900, { link = true, songs = { Other = {} } })
  u, why = hub.elect_song({ elsewhere, mac }, "Song", "Bo", "Desk", T)
  assert(u == "Mac" and why == "ranked", "the studio hub is in another song: the ranking among those in this one")
  u, why = hub.elect_song({ elsewhere }, "Song", "Bo", "Desk", T)
  assert(u == nil and why == "nobody", "nobody in the song: the cloud copy stands in")
  -- kept: the studio hub arriving doesn't take it from whoever holds it
  local mac_h = in_song("Mac", T - 3000, { holds = true })
  u, why = hub.elect_song({ desk, mac_h }, "Song", "Bo", "Desk", T)
  assert(u == "Mac" and why == "kept", "whoever holds it keeps it over the studio hub")
  -- home comes back: after HANDBACK s
  local bo_new = in_song("Bo", T - 3)
  assert(hub.elect_song({ desk, mac_h, bo_new }, "Song", "Bo", "Desk", T) == "Mac", "home just back: the holder keeps it a moment")
  assert(hub.elect_song({ desk, mac_h, bo_new }, "Song", "Bo", "Desk", T + hub.HANDBACK) == "Bo", "home back long enough: handed back")
  -- home handed on (Health's Hand it on): the studio hub stands in
  local bo_off = in_song("Bo", T - 100, { off = true })
  assert(hub.elect_song({ bo_off, desk }, "Song", "Bo", "Desk", T) == "Desk", "home handed the role on: the studio hub")
  -- a member who's never online with anyone else: alone, they're the song's hub (the ranking); later the home takes it back
  local chilio = in_song("Chilio", T - 50)
  assert(hub.elect_song({ chilio }, "Song", "Bo", nil, T) == "Chilio", "alone in the song: the one there is its hub")
  local chilio_h = in_song("Chilio", T - 50, { holds = true })
  assert(hub.elect_song({ chilio_h, in_song("Bo", T + 10) }, "Song", "Bo", nil, T + 10 + hub.HANDBACK) == "Bo", "the home comes on later and takes it back")
  -- everyone works out the same: each computer's list in its own order
  local list1, list2 = { bo_new, desk, mac_h }, { mac_h, bo_new, desk }
  for _, at in ipairs({ T, T + 10, T + hub.HANDBACK, T + 100 }) do
    assert(hub.elect_song(list1, "Song", "Bo", "Desk", at) == hub.elect_song(list2, "Song", "Bo", "Desk", at), "the same song hub on every computer at " .. at)
  end
end

-- ---- statuses -> candidates ----
do
  local now = 5000
  local age = function(t) return now - tonumber(t) end
  local sts = {
    { song = "A", st = { user = "Bo", time = "4990", machine = "mb", hub = { since = 100, link = true, song = true } }, seen = 4990 },
    { song = "B", st = { user = "Bo", time = "4995", machine = "mb", hub = { since = 100, link = true, studio = true } }, seen = 4995 },
    { song = "A", st = { user = "Old", time = "1000" }, seen = -math.huge }, -- (stale: offline)
    { song = "A", st = { user = "Skew", time = "0100" }, seen = 4980 }, -- (its clock is far off, but its file just changed here: online)
    { song = "A", st = { user = "Plain", time = "4999" }, seen = 4999 }, -- (older StudioSync: no hub part)
    { song = "A", st = "junk" },
  }
  local list = hub.candidates(sts, now, age)
  local by = {}
  for _, x in ipairs(list) do by[x.user] = x end
  assert(by.Bo and by.Bo.songs.A.holds and by.Bo.songs.B and not by.Bo.songs.B.holds, "in both songs; holds A's hub")
  assert(by.Bo.studio == true and by.Bo.link == true and by.Bo.since == 100, "the newest status gives since, link and the studio role")
  assert(not by.Old, "a stale status is offline")
  assert(by.Skew, "a status whose clock is off but whose file keeps changing is online")
  assert(by.Plain and by.Plain.link == false and by.Plain.since == nil, "an older StudioSync's status: a candidate, ranked last")
  assert(hub.elect_studio(list, nil, now) == "Bo", "and the election runs on them")
end

-- ---- the song hub's restore points: due, paused, idle, budget ----
do
  assert(hub.snap_due(T, nil, nil), "none yet: due")
  assert(not hub.snap_due(T, T - 60, true), "one a minute ago: not yet")
  assert(hub.snap_due(T, T - hub.SNAP_EVERY, true), "half an hour on, with changes: due")
  assert(select(2, hub.snap_due(T, T - hub.SNAP_EVERY, false)) == "unchanged", "nothing new: not again")
  assert(hub.snap_due(T, T - hub.SNAP_EVERY, nil), "not known here (after a handover): due by time alone")
  assert(select(2, hub.snap_due(T, T - hub.SNAP_EVERY, true, T - 100, 1)) == "budget", "a slow one (1 s) waits 1/BUDGET s before the next")
  -- (a real os.time, as snap_due compares it with os.time(): one named ten minutes ago, in UTC, is ten minutes old. "-358 min ago", desktop, rt)
  local ago = os.time() - hub.snap_time(os.date("!%Y%m%d-%H%M%SZ", os.time() - 600) .. "-Bo-hub_snapshot.json")
  assert(math.abs(ago - 600) <= 2, "a hub snapshot's time from its name, as an os.time: " .. tostring(ago))
  assert(hub.snap_time("20261119-101500Z-Bo-end_of_session.json") == nil, "other saved versions aren't hub snapshots")
end

-- ---- trim: a hub snapshot is a minor point ----
do
  local trim = require("trim")
  assert(not trim.major({ label = "hub snapshot" }) and trim.major({ label = "hub snapshot", keep = true }) and trim.major({ label = "end of session", keep = true }),
    "rolling hub snapshots don't hold history back from trimming; kept points still do")
end

-- ---- the tick: the role worked out from the shared folder, the job paused while playing, waiting until idle ----
do
  local cfg, b = { root = "R", user = "Bo" }, { song = "Song", room = "main" }
  reaper.SetExtState(band.SECTION, "hub since", tostring(os.time() - 1000)) -- (online a while: past hub.LISTEN)
  files["R/Song/session.json"] = { host = "Bo" }
  band.songs = function() return { "Song" } end
  band.subdirs = function(d) return d == "R/Song/rooms" and { "main" } or {} end
  band.files = function(d) if d == "R/Song/rooms/main/status" then return { "Desk.json" } end return {} end
  files["R/Song/rooms/main/status/Desk.json"] = { user = "Desk", machine = "md", time = os.date("!%Y-%m-%dT%H:%M:%SZ"), hub = { since = os.time() - 5000, link = true } }
  package.loaded.direct = { available = function() return false end }
  package.loaded.removal = { guest_names = function() return {} end }
  package.loaded.sync ={ machine = function() return "mbo" end, loading = {}, room_dir = function(_, s, r) return "R/" .. s .. "/rooms/" .. r end }
  local saved = 0
  package.loaded.recall = { dir = function() return "R/Song/rooms/main/recall" end, save = function() saved = saved + 1 end }
  play = 1
  hub.tick("P", cfg, b)
  local v = band.ext_json(band.SECTION, "hub view studio1 Song")
  assert(v and v.hub == "Bo" and v.why == "home", "Bo shared the song and is here: Bo's computer is its hub")
  assert(v.studio == "Desk", "the studio hub: Desk, online longest")
  assert(v.job.state == "paused" and saved == 0, "REAPER playing: the job waits")
  assert(hub.status_part(cfg, b).song == true and not hub.status_part(cfg, b).studio, "Bo's status says it holds the song's hub, not the studio's")
  play, now_p = 0, now_p + 3
  hub.tick("P", cfg, b)
  assert(band.ext_json(band.SECTION, "hub view studio1 Song").job.state == "waiting" and saved == 0, "stopped, but touched just now: waits for a quiet minute")
  now_p = now_p + hub.IDLE + 1
  hub.tick("P", cfg, b)
  assert(saved == 1, "stopped and untouched for a minute: a restore point")
  now_p = now_p + 3
  hub.tick("P", cfg, b)
  assert(saved == 1, "not again straight away")
  local row = hub.health_row(cfg, b)
  assert(row and row[4]:find("this project: you %(shared it%)") and row[4]:find("You're this project's hub", 1, true) and row.action[1] == "Hand it on", "Health: the role and its Hand it on")
  -- hand it on: the next tick, the studio hub stands in
  row.action[2]()
  assert(hub.off("R") and hub.status_part(cfg, b).off == true, "handed on, and the status says so")
  now_p = now_p + 3
  hub.tick("P", cfg, b)
  v = band.ext_json(band.SECTION, "hub view studio1 Song")
  assert(v.hub == "Desk" and v.why == "studio" and v.job.state == "off", "the studio hub (Desk, in this song too) stands in; Bo's job stops")
  assert(hub.health_row(cfg, b).action[1] == "Be a hub again" and hub.line(v, "Bo"):find("Desk (the studio hub, Bo is away)", 1, true), "Health says so, and offers it back")
  assert(hub.line(v, "Bo"):find("within a minute", 1, true), "no link: Health says a dropped hub is noticed within a minute")
  -- the link reaches Desk: Health says failover takes seconds
  package.loaded.direct = { available = function() return true end, live_available = function() return true end, firewall_ok = function() return true end,
    reach =function() return { Desk = { ok = true, at = os.time() } } end }
  now_p = now_p + 3
  hub.tick("P", cfg, b)
  v = band.ext_json(band.SECTION, "hub view studio1 Song")
  assert(v.fast and v.hub == "Desk" and hub.line(v, "Bo"):find("within seconds (direct link)", 1, true), "the link watches Desk: within seconds")
  -- a guest's computer: never a hub, and Health says why (removal.guest_names, re-read every GUESTS_EVERY s)
  package.loaded.removal = { guest_names = function() return { Desk = true } end }
  now_p = now_p + hub.GUESTS_EVERY + 1
  hub.tick("P", cfg, b)
  v = band.ext_json(band.SECTION, "hub view studio1 Song")
  assert(v.hub == nil and v.studio == nil, "Desk is a guest: not a hub (and Bo handed it on): nobody")
  package.loaded.removal = { guest_names = function() return { Bo = true } end }
  now_p = now_p + hub.GUESTS_EVERY + 1
  hub.tick("P", cfg, b)
  v = band.ext_json(band.SECTION, "hub view studio1 Song")
  assert(v.guest and hub.line(v, "Bo"):find("You're a guest here", 1, true), "this computer a guest's: Health says guests are never a hub")
  package.loaded.removal = { guest_names = function() return {} end }
  package.loaded.direct = { available = function() return false end }
  now_p = now_p + hub.GUESTS_EVERY + 1
  -- Desk goes offline too (its status goes stale): nobody here, so the cloud copy stands in
  band.age = function() return 1e9 end -- (its file, unchanged since first read here, now old by its stamp)
  now_p = now_p + hub.SCAN_EVERY + 1
  hub.tick("P", cfg, b)
  v = band.ext_json(band.SECTION, "hub view studio1 Song")
  assert(v.hub == nil and v.studio == nil and hub.line(v, "Bo"):find("cloud copy", 1, true), "nobody online who'll take it: the cloud copy stands in")
  hub.health_row(cfg, b).action[2]()
  assert(not hub.off("R"), "a hub again")
  -- a handover written to the hander's own file (<song>/hub/<person>.json) moves the song's home, for every computer reading it
  band.files = function(d)
    local out = {}
    for p in pairs(files) do local f = p:match("^" .. d:gsub("%p", "%%%0") .. "/([^/]+%.json)$"); if f then out[#out + 1] = f end end
    table.sort(out)
    return out
  end
  assert(not hub.hand_song({ root = "R", user = "Chilio" }, "Song", "Desk"), "a member can't hand someone else's song on")
  assert(hub.hand_song(cfg, "Song", "Desk") and hub.home(cfg, "Song") == "Desk", "the sharer hands it to Desk")
  assert(hub.hand_song({ root = "R", user = "Desk" }, "Song", "Mac") and hub.home(cfg, "Song") == "Mac", "the hub now hands it on")
  assert(hub.hand_song({ root = "R", user = "Owner" }, "Song", "Bo") and hub.home(cfg, "Song") == "Bo", "the owner hands it back")
  assert(files["R/Song/hub/Owner.json"].user == "Owner" and #files["R/Song/hub/Desk.json"].transfers == 1, "each person's handovers in their own file")
  -- forged: a file written by another computer than its person's (trust.own_file_ok says no) is set aside, and Health says so
  local trust = require("trust")
  local real = trust.own_file_ok
  trust.own_file_ok = function(_, rel) if rel == "Song/hub/Owner.json" then return false end return true end
  local h, _, refused = hub.home(cfg, "Song")
  assert(h == "Mac" and refused[1] == "Owner", "the owner's handover, written by someone else's computer, doesn't count: " .. tostring(h))
  assert(hub.line({ studio = "Desk", studio_why = "ranked", hub = "Mac", why = "home", refused = refused }, "Bo"):find("in Owner's name came from another computer", 1, true), "Health says so")
  trust.own_file_ok = function(_, rel) if rel == "Song/session.json" then return false end return true end
  files["R/Song/hub/Bo.json"], files["R/Song/hub/Desk.json"], files["R/Song/hub/Owner.json"] = nil, nil, nil
  assert(hub.home(cfg, "Song") == nil, "a session.json naming a sharer whose computer didn't write it: no home (the studio hub stands in)")
  trust.own_file_ok = function() return nil end
  assert(hub.home(cfg, "Song") == nil and #select(3, hub.home(cfg, "Song")) == 0, "not checked yet: waits, and nothing is called forged")
  trust.own_file_ok = real
end

-- ---- back from a restart: it hears the room before it takes a role (James, rt: the desktop, back, was the song's hub at once while the
-- laptop held it, both hub for minutes). Lap holds the song's hub; Desk's REAPER has just started and Lap's status isn't in its view yet
-- (its stamp reads old here: it counts once its file is seen changing, the next scan). ----
do
  local cfg, b = { root = "R2", user = "Desk" }, { song = "Song", room = "main" }
  files["R2/Song/session.json"] = { host = "Chilio" } -- (shared by someone not online: no home here)
  local trust = require("trust")
  local real = trust.own_file_ok
  trust.own_file_ok = function() return true end
  local lap_here, stamp = true, 0
  band.songs = function() return { "Song" } end
  band.subdirs = function(d) return d == "R2/Song/rooms" and { "main" } or {} end
  band.files = function(d) if d == "R2/Song/rooms/main/status" and lap_here then return { "Lap.json" } end return {} end
  band.age = function() return 1e9 end
  local function lap_writes()
    stamp = stamp + 1
    files["R2/Song/rooms/main/status/Lap.json"] = { user = "Lap", machine = "ml", time = "t" .. stamp, hub = { since = os.time() - 3000, link = true, song = true, studio = true } }
  end
  package.loaded.direct = { available = function() return false end }
  local function tick() now_p = now_p + hub.SCAN_EVERY + 1; hub.tick("P", cfg, b); return band.ext_json(band.SECTION, "hub view studio1 Song") end
  reaper.SetExtState(band.SECTION, "hub since", tostring(os.time())) -- (this REAPER just started)
  lap_writes()
  local v = tick()
  assert(v.hub == nil and v.studio == nil, "just started, Lap not in view yet: Desk takes no role (it used to be the hub at once, ranked)")
  lap_writes()
  v = tick()
  assert(v.hub == "Lap" and v.why == "kept" and v.studio == "Lap", "Lap's file seen changing: Lap holds both, and keeps them")
  reaper.SetExtState(band.SECTION, "hub since", tostring(os.time() - hub.LISTEN - 1))
  lap_writes()
  v = tick()
  assert(v.hub == "Lap" and v.studio == "Lap", "listened long enough: Desk still doesn't take what Lap holds")
  lap_here = false
  v = tick()
  assert(v.hub == "Desk" and v.why == "studio" and v.studio == "Desk", "Lap gone, Desk past listening: Desk takes them")
  -- alone and just started: nobody for LISTEN s, then this computer
  local cfg3 = { root = "R3", user = "Solo" }
  reaper.SetExtState(band.SECTION, "hub since", tostring(os.time()))
  now_p = now_p + hub.SCAN_EVERY + 1
  hub.tick("P", cfg3, b)
  assert(band.ext_json(band.SECTION, "hub view studio1 Song").hub == nil, "alone, just started: nobody yet (the cloud copy stands in a moment)")
  reaper.SetExtState(band.SECTION, "hub since", tostring(os.time() - hub.LISTEN))
  now_p = now_p + hub.SCAN_EVERY + 1
  hub.tick("P", cfg3, b)
  assert(band.ext_json(band.SECTION, "hub view studio1 Song").hub == "Solo", "alone after LISTEN s: this computer")
  -- the pure election: one listening keeps what it holds, takes nothing else
  local desk = c("Desk", T - 5, { link = true, listening = true, songs = { Song = {} } })
  local lap = c("Lap", T - 900, { link = true, songs = { Song = {} } })
  assert(hub.elect_studio({ desk, lap }, "Desk", T) == "Lap" and hub.elect_song({ desk, lap }, "Song", "Desk", nil, T) == "Lap",
    "listening: not the preferred hub nor the song's home yet")
  assert(hub.elect_studio({ desk }, nil, T) == nil and hub.elect_song({ desk }, "Song", "Desk", nil, T) == nil, "listening alone: nobody yet")
  desk.studio, desk.songs.Song.holds = true, true
  assert(hub.elect_studio({ desk, lap }, nil, T) == "Desk" and hub.elect_song({ desk, lap }, "Song", nil, nil, T) == "Desk", "listening but holding: keeps it")
  trust.own_file_ok = real
end

print("ok hub")
