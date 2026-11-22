-- rt-fix7 (2026-11-21, the hub findings of the rt-r2 re-check, docs/rt/rt-hubrank.md "R2 re-check results"), lib/hub.lua:
--   1. a computer the link lost stays a candidate while another here says its own link reaches it, so the computers cut off from the hub
--      name what the others name (rt-r2: LinuxBox and LinuxBox2, cut from the desktop, named the laptop the studio's hub, the others James);
--   2. the home passed over: the ranking's pick says "ranked" though it holds the role by now (rt-r2: "kept");
--   3. a computer holding a role gives it up for its Syncthing being behind only once that has lasted REACH_SETTLE s (rt-r2: the desktop
--      handed Cross Test to the laptop and took it back 21 s later, with its own Syncthing not answering), and the log says why.
package.path = "lib/?.lua;" .. package.path
local ext, files, now_p, logged = {}, {}, 1000, {}
reaper = setmetatable({
  time_precise = function() return now_p end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  GetPlayState = function() return 1 end, -- (playing: the restore-point job waits, so the tick is only the election)
  GetProjectStateChangeCount = function() return 1 end,
  EnumProjects = function() return "P" end,
}, { __index = function() return function() return "" end end })
local real_time, toff = os.time, 0
os.time = function(t) if t then return real_time(t) end return real_time() + toff end
local band = require("band")
band.info = function() return { id = "studio1", name = "Smiley" } end
band.log = function(s) logged[#logged + 1] = s end
band.read_json = function(p) return files[p] end
band.write_json = function(p, t) files[p] = t end
band.files = function() return {} end
band.listing = function() return {} end
package.loaded.groups = { trusted = function() return { hub = "Ja" } end, role = function() return "member" end }
local hub = require("hub")
local T = 2000000

-- A room as candidates: names (the first online longest), links "A-B" (both ways), x[name] = { holds }.
local function room(names, links, x)
  local set, list = {}, {}
  for a, b2 in links:gmatch("(%w+)%-(%w+)") do set[a .. "|" .. b2], set[b2 .. "|" .. a] = true, true end
  for i, n in ipairs(names) do
    local o = (x or {})[n] or {}
    local sees = {}
    for _, m in ipairs(names) do if m ~= n and set[n .. "|" .. m] then sees[m] = true end end
    list[#list + 1] = { user = n, machine = "m-" .. n, since = T - 100000 + i * 1000, link = true, ext = "1.0.36", sees = sees,
      studio = o.studio, songs = { Song = { holds = o.holds, sees = sees } } }
  end
  return list
end

-- ---- 1 and 2: four computers, both VMs cut from the desktop (Ja, the home and the owner's pick); the laptop (La) reaches everybody -------
do
  local CUT = "Ja-La La-Bx La-By Bx-By"
  -- the desktop's and the laptop's view: nobody lost
  local function view(gone, x, now, mem)
    local list = room({ "Ja", "La", "Bx", "By" }, CUT, x)
    hub.reach(list, "Song")
    list = hub.drop(list, gone)
    local studio = hub.elect_studio(list, "Ja", now)
    local song, why, passed = hub.elect_song(list, "Song", "Ja", studio, now, mem)
    return studio, song, why, passed
  end
  local held = { Ja = { holds = true, studio = true } }
  local s1 = view({}, held, T)
  local s2 = view({ Ja = true }, held, T)
  assert(s1 == "Ja" and s2 == "Ja", "the studio's hub: the owner's pick on the desktop's view and on a VM cut from it, as the laptop still reaches it (" .. tostring(s2) .. ")")
  local _, song = view({ Ja = true }, held, T, {})
  assert(song == "Ja", "the song's hub on the cut VM at first: the home, as everyone names it (it named the laptop at once) (" .. tostring(song) .. ")")
  -- after REACH_SETTLE s of two misses the home is passed over on every view alike; the laptop then holds it and is the ranking's pick
  local mem_d, mem_v = {}, {}
  view({}, held, T, mem_d); view({ Ja = true }, held, T, mem_v)
  local _, sd, wd, pd = view({}, held, T + hub.REACH_SETTLE, mem_d)
  local _, sv, wv, pv = view({ Ja = true }, held, T + hub.REACH_SETTLE, mem_v)
  assert(sd == "La" and sv == "La" and pd == 2 and pv == 2, "passed over the same on the desktop and on the cut VM (" .. tostring(sv) .. ", " .. tostring(pv) .. ")")
  local now_held = { Ja = { studio = true }, La = { holds = true } }
  _, sd, wd, pd = view({}, now_held, T + hub.REACH_SETTLE + 2, mem_d)
  _, sv, wv = view({ Ja = true }, now_held, T + hub.REACH_SETTLE + 2, mem_v)
  assert(sd == "La" and wd == "ranked" and wv == "ranked" and pd == 2, "the laptop holding it by now: still 'ranked', as Health words it (was 'kept') (" .. tostring(wd) .. ")")
  assert(hub.line({ hub = "La", why = wd, home = "Ja", passed = pd, studio = "Ja", studio_why = "preferred" }, "Bx"):find("the one the others here reach best", 1, true), "Health")
  -- a hub that really drops: nobody reaches it any more, so it's dropped at once, as before
  local list = room({ "Ja", "La", "Bx" }, "La-Bx", held)
  assert(#hub.drop(list, { Ja = true }) == 2, "lost by everyone's link: out")
  -- a guest's word doesn't keep one, nor does one lost here itself
  list = room({ "Ja", "La", "Gu" }, "Ja-Gu", held)
  assert(#hub.drop(list, { Ja = true }, { Gu = true }) == 1, "only a guest says it reaches the lost one: out (and the guest too)")
  list = room({ "Ja", "La", "Bx" }, "Ja-Bx", held)
  assert(#hub.drop(list, { Ja = true, Bx = true }) == 1, "the only one vouching is lost here too: both out")
end

-- ---- 3. Syncthing behind on the computer holding the role: given up only after REACH_SETTLE s --------------------------------------------
do
  local cfg, b = { root = "R", user = "Ja" }, { song = "Song", room = "main" }
  ext["BandSync/hub since"] = tostring(os.time() - 100000)
  ext["BandSync/menu extension"] = "1.0.36"
  band.songs = function() return { "Song" } end
  band.subdirs = function(d) return d == "R/Song/rooms" and { "main" } or {} end
  local listed = { "Pi.json", "Qu.json" }
  band.files = function(d) return d == "R/Song/rooms/main/status" and listed or {} end
  local function iso(ago) return os.date("!%Y-%m-%dT%H:%M:%SZ", real_time() - ago) end
  -- (rt-audio3: the others also reach Zed, whom this computer's link doesn't: behind AND blind to someone, the case a holder still steps down
  -- for. Seeing everyone the others reach, it keeps the role however long its Syncthing is behind: tests/test_0_60_rt_audio3.lua part 3)
  local function st(user, since) return { user = user, machine = "m" .. user, time = iso(2), hub = { since = real_time() - since, link = true, ext = "1.0.36", sees = { "Ja", "Pi", "Qu", "Zed" } } } end
  files["R/Song/rooms/main/status/Pi.json"], files["R/Song/rooms/main/status/Qu.json"] = st("Pi", 500), st("Qu", 400)
  local live_now = { Pi = st("Pi", 500), Qu = st("Qu", 400) }
  package.loaded.presence = { peers = function() return { live_now.Pi, live_now.Qu } end, live = function() return live_now end }
  package.loaded.direct = { available = function() return true end, live_available = function() return true end, firewall_ok = function() return true end,
    reach = function() return { Pi = { ok = true, at = os.time() }, Qu = { ok = true, at = os.time() } } end }
  package.loaded.removal = { guest_names = function() return {} end }
  package.loaded.trust = { own_file_ok = function() return true end, user_file = function(n) return n .. ".json" end }
  package.loaded.sync = { machine = function() return "mJa" end, loading = {}, room_dir = function(_, s, rm) return "R/" .. s .. "/rooms/" .. rm end }
  package.loaded.recall = { dir = function() return "R/Song/rooms/main/recall" end, save = function() end }
  local function tick() now_p = now_p + hub.SCAN_EVERY + 1; hub.tick("P", cfg, b); return band.ext_json(band.SECTION, "hub view studio1 Song") end
  local v = tick()
  assert(v.hub == "Ja", "online longest: the song's hub (" .. tostring(v.hub) .. ")")
  -- its Syncthing stops bringing the files (the link still brings the statuses): behind, but holding the role
  listed = {}
  v = tick()
  assert(v.hub == "Ja" and v.lag == nil and hub.status_part(cfg, b).lag == nil, "holding it: kept at first sight of being behind (it handed it on at once) (" .. tostring(v.hub) .. ")")
  toff = hub.REACH_SETTLE - 5
  v = tick()
  assert(v.hub == "Ja", "nor before REACH_SETTLE s")
  listed = { "Pi.json", "Qu.json" } -- (a moment's stall: the files come again)
  toff = hub.REACH_SETTLE + 2
  v = tick()
  assert(v.hub == "Ja" and v.lag == nil, "caught up within it: nothing moved")
  listed = {}
  toff = hub.REACH_SETTLE + 4
  v = tick()
  assert(v.hub == "Ja", "behind again: the count starts again")
  toff = hub.REACH_SETTLE * 2 + 5
  logged = {}
  v = tick()
  assert(v.hub ~= "Ja" and v.lag == true and hub.status_part(cfg, b).lag == true, "behind for REACH_SETTLE s: given up, and its status says so (" .. tostring(v.hub) .. ")")
  local said = table.concat(logged, "\n")
  assert(said:find("is its hub now (Syncthing is behind here)", 1, true), "the log says why: " .. said)
  toff = hub.REACH_SETTLE * 2 + 9
  v = tick()
  assert(v.lag == true and v.hub ~= "Ja", "holding nothing now: still behind, still out")
  -- holding nothing, a computer that falls behind takes nothing at once (rt-p9, unchanged): Pi and Qu hold nothing either here
end

print("ok: rt-fix7 hub (a lost computer others still reach stays named, 'ranked' when the home is passed over, Syncthing behind settles for a holder)")
