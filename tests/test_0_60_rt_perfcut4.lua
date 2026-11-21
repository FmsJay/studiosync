-- rt-perfcut4 (P8): the perf cuts left over from rt-perf, offline on rt-bigproj's project (150 tracks, 4,000 items):
--  cut 7  the colour look only with the studio's Colour parity on (sync.write_status);
--  cut 8  the Project page's look reads the tracks that may have changed (dawview.read with a track memory), every track on a whole read;
--  cut 9  the status write and start/link in named parts while perf stats is on (band.sublap);
--  and band.songs held a few seconds, the stream trace capped.
-- Each part fails without its change. The numbers print; docs/rt/rt-perfcut4.md has them.
package.path = "tools/?.lua;lib/?.lua;tests/fixtures/?.lua;" .. package.path
local function check(cond, what) if not cond then error(what, 2) end end
local function read(path) local f = assert(io.open(path, "rb"), path); local d = f:read("a"):gsub("\r\n", "\n"); f:close(); return d end
local G = require("bigproject")
local m = G.model()
local F = require("bigreaper").new(m)
reaper = F.reaper
rawset(reaper, "GetAppVersion", function() return "7.86/win64" end)
local files, logged = {}, {}
local band = require("band")
local proxy = setmetatable({}, { __index = band })
proxy.read_json = function(path) return files[path] end
proxy.write_json = function(path, v) files[path] = v; return true end
proxy.log = function(t) logged[#logged + 1] = t end
package.loaded.band = proxy
local parity = true
package.loaded.groups = setmetatable({ trusted = function() return {} end, may_manage = function() return true end, colours = function() return nil end,
  colour_parity = function() return parity end }, { __index = function() return function() end end })
local sync, colours = require("sync"), require("colours")
local cfg = { user = "James", root = "C:/fake/StudioSync" }
local b = { song = "Big", room = "main" }
local function ms(fn, n)
  n = n or 1
  F.reset_counts()
  local t0 = os.clock()
  for _ = 1, n do fn() end
  return (os.clock() - t0) / n * 1000, F.total_calls() // n
end
local function say(fmt, ...) print("perfcut4: " .. string.format(fmt, ...)) end

-- ---- cut 7: the colour look only with Colour parity on ----
do
  local looks, real = 0, colours.look
  colours.look = function(p) looks = looks + 1; return real(p) end
  local function status()
    F.clock = F.clock + 10 -- (past the look's own 5 s hold)
    local info = {}
    sync.write_status(F.proj, cfg, b.song, b.room, info, true)
    return info
  end
  parity = true
  local on = status()
  check(looks == 1 and type(on.look) == "table" and on.look.fp, "parity on: the colour look is in the status (" .. looks .. ")")
  parity = false
  looks = 0
  local off = status()
  check(looks == 0 and off.look == nil, "parity off: no colour look is built, and none goes in the status (" .. looks .. ")")
  -- Health's row only exists with parity on, and peers' `look` is only read by it
  check(colours.health_row({ root = cfg.root, user = "James" }, b, F.proj) == nil, "parity off: no Colour parity row to read a look")
  local src = read("lib/sync.lua")
  check(src:find('if require("colours").parity(cfg.root) then', 1, true), "write_status asks the studio's switch first")
  local t_on, c_on = ms(function() parity = true; status() end, 3)
  local t_off, c_off = ms(function() parity = false; status() end, 3)
  say("cut 7, a status write on the 150-track, 4,000-item project: parity on %.1f ms / %d REAPER calls, off %.2f ms / %d calls", t_on, c_on, t_off, c_off)
  check(c_off * 20 < c_on, "off costs a twentieth of the calls (" .. c_off .. " against " .. c_on .. ")")
  colours.look, parity = real, true
end

-- ---- cut 9: the status write in parts (band.sublap, only while perf stats is on) ----
do
  local seen, parts, c0, t0 = {}, {}, 0, 0
  proxy.sublap = function(name)
    seen[#seen + 1] = name
    parts[#parts + 1] = string.format("%s %d calls %.1f ms", name:gsub("^status/", ""), F.total_calls() - c0, (os.clock() - t0) * 1000)
    c0, t0 = F.total_calls(), os.clock()
  end
  F.clock = F.clock + 10 -- (past the colour look's own hold)
  F.reset_counts(); c0, t0 = 0, os.clock()
  sync.write_status(F.proj, cfg, b.song, b.room, {}, false)
  say("cut 9, a status write by parts, offline (REAPER calls and Lua ms; the real cost of a call is REAPER's): %s", table.concat(parts, "; "))
  check(table.concat(seen, "|") == "status/folder, name clash|status/info|status/colour look|status/file|status/link send", "the status write's parts in order: " .. table.concat(seen, "|"))
  proxy.sublap = nil
  sync.write_status(F.proj, cfg, b.song, b.room, {}, false) -- (perf stats off: no marks, no error)
  -- start/link in parts, run with the extension and the studio stood in
  do
    local direct = require("direct")
    local keep = {}
    for _, k in ipairs({ "available", "live_available", "ensure", "refresh_peers", "keep_clock", "peers", "messages", "dispatch", "prune", "send_live" }) do keep[k] = direct[k] end
    local yes = function() return true end
    direct.available, direct.live_available, direct.ensure = yes, yes, yes
    direct.refresh_peers, direct.keep_clock, direct.messages, direct.dispatch = function() end, function() end, function() return {} end, function() end
    direct.peers, direct.send_live, direct.prune = function() return { "bo:1" } end, function() end, function() end
    rawset(reaper, "StudioSync_DirectPoll", function() return "" end)
    local laps = {}
    proxy.sublap = function(name) laps[#laps + 1] = name end
    direct.live_tick({ root = "R", user = "James" }, "S", "main", {})
    check(table.concat(laps, "|") == "link/poll, ensure|link/prune|link/peers|link/clock|link/heartbeat|link/messages", "start/link's parts in order: " .. table.concat(laps, "|"))
    laps = {}
    direct.live_tick({ root = "R", user = "James" }, "S", "main", {})
    check(table.concat(laps, "|") == "link/poll, ensure|link/peers|link/clock|link/heartbeat|link/messages", "the prune only every PRUNE_EVERY s: " .. table.concat(laps, "|"))
    proxy.sublap = nil
    direct.live_tick({ root = "R", user = "James" }, "S", "main", {}) -- (perf stats off: no marks, no error)
    rawset(reaper, "StudioSync_DirectPoll", nil)
    for k, v in pairs(keep) do direct[k] = v end
  end
  local ls, dr = read("StudioSync - Live sync.lua"), read("lib/direct.lua")
  check(ls:find("band.sublap = perf.on and lap or nil", 1, true), "Live sync hands its lap to band.sublap only while perf stats is on")
  local n = 0
  for name in dr:gmatch('sublap%("(link/[^"]+)"%)') do n = n + 1 end
  check(n >= 6, "start/link in parts: " .. n)
  for _, name in ipairs({ "link/poll, ensure", "link/prune", "link/peers", "link/clock", "link/heartbeat", "link/messages" }) do
    check(dr:find('sublap("' .. name .. '")', 1, true), "a lap for " .. name)
  end
end

-- ---- cut 8: the Project page reads the tracks that may have changed ----
do
  local selected, asked = {}, 0
  reaper.CountSelectedMediaItems = function() return #selected end
  reaper.GetSelectedMediaItem = function(_, i) return selected[i + 1] end
  -- (peaks REAPER has built: with none, a track is read again at every look, as peaks may still arrive)
  reaper.new_array = function(n) local a = { d = {} }; a.table = function() local t = {}; for i = 1, n do t[i] = a.d[i] or 0 end; return t end; return a end
  reaper.GetMediaItemTake_Peaks = function(_, _, _, _, n, _, buf)
    for i = 1, n do buf.d[i] = math.abs(math.sin(i / 7)) * 0.8; buf.d[n + i] = -math.abs(math.cos(i / 5)) * 0.6 end
    asked = asked + 1
    return n | 0x100000
  end
  local dawview = require("dawview")
  local mirror = require("mirror")
  local published = {}
  local function publish(topic, t) published[topic] = band.json_encode(t) end
  local clock = 5000
  F.clock = clock
  local function tick() clock = clock + 0.3; F.clock = clock; dawview.action(F.proj, cfg, b, { want = true }); dawview.tick(F.proj, cfg, b, publish, nil, clock) end
  local function settle() for _ = 1, 400 do tick() end end -- (a look spread over ticks, done)
  dawview.action(F.proj, cfg, b, { want = true })
  local was_slice = dawview.SLICE
  dawview.SLICE = 10 -- (a look in one tick: the calls are what's compared)
  F.cc = F.cc + 1
  local t_first, c_first = ms(tick)
  check(published.daw and published.dawc0 and published.dawc37, "the first look read everything")
  local first = {}
  for k, v in pairs(published) do first[k] = v end
  local function whole_again() -- what a fresh, whole look of the project as it is publishes
    dawview.reset(); local keep = published; published = {}
    F.cc = F.cc + 1; tick()
    local out = published
    published = keep
    return out
  end
  -- a whole look again, with the peaks kept (what each FLOOR s costs on an idle song)
  clock = clock + dawview.FLOOR + 1
  local t_whole, c_whole = ms(tick)
  -- nothing changed but the change count: the headers and fingerprints only
  F.cc = F.cc + 1; clock = clock + 1
  local t_idle, c_idle = ms(tick)
  say("cut 8, a look of the 150-track, 4,000-item project: first %.0f ms / %d REAPER calls, a whole one with peaks kept %.1f ms / %d; the change count moved and nothing else %.1f ms / %d", t_first, c_first, t_whole, c_whole, t_idle, c_idle)
  check(c_idle * 5 < c_whole, "a look with nothing changed asks REAPER a fifth as often as a whole one: " .. c_idle .. " against " .. c_whole)
  for k, v in pairs(published) do check(first[k] == v, "same topics as the whole look: " .. k) end

  -- a selected item moved: its track is read, its chunk goes, the same bytes as a whole look
  local it = m.tracks[20].items[5]
  selected = { it }
  published = {}
  F.move(it, 0.5); clock = clock + 1
  local t_sel, c_sel = ms(tick)
  local n = 0
  for _ in pairs(published) do n = n + 1 end
  check(n >= 2 and published["dawc" .. (19 // dawview.CHUNK_TRACKS)] and not published.dawc0, "the moved item's chunk (and the header) go, no other chunk")
  say("cut 8, one selected item moved: %.1f ms / %d REAPER calls, %d topics out (a whole look's %d calls)", t_sel, c_sel, n, c_whole)
  check(c_sel * 5 < c_whole, "an edit's look is a fifth of a whole one: " .. c_sel .. " against " .. c_whole)
  local fresh = whole_again()
  for k, v in pairs(published) do if k ~= "dawcur" then check(fresh[k] == v, "what the partial look published is what a whole look of the same state does: " .. k) end end
  -- ... and deselected straight after (the look after it): still read once more, so the move can't be missed
  selected = {}
  published = {}
  F.move(it, 0.25); clock = clock + 1
  tick() -- (hints: nothing selected now, the last look's selected item's track is read again)
  check(published["dawc" .. (19 // dawview.CHUNK_TRACKS)], "an item deselected straight after its edit: its track is still read once more")

  -- an edit nothing hints at (an unselected middle item, another script's) shows at the next whole read, within FLOOR s
  local mid = m.tracks[30].items[3]
  published = {}
  F.move(mid, 0.5); clock = clock + 1
  tick(); tick()
  check(not published["dawc" .. (29 // dawview.CHUNK_TRACKS)], "an unselected middle item's move isn't seen by a partial look")
  clock = clock + dawview.FLOOR
  tick(); tick()
  check(published["dawc" .. (29 // dawview.CHUNK_TRACKS)], "and is by the whole read within FLOOR s")
  -- the cheap fingerprint sees a count, a first or last item's move, a trim of the last, without any hint
  local last = m.tracks[40].items[#m.tracks[40].items]
  published = {}
  last.len = last.len + 1; F.changed(last.track); clock = clock + 1
  tick(); tick()
  check(published["dawc" .. (39 // dawview.CHUNK_TRACKS)], "the last item trimmed: seen without a hint")
  -- StudioSync wrote the project (a bandmate's change, a put-back): everything is read
  local mid2 = m.tracks[50].items[2]
  published = {}
  F.move(mid2, 0.5); mirror.applied = (mirror.applied or 0) + 1; clock = clock + 1
  tick(); tick()
  check(published["dawc" .. (49 // dawview.CHUNK_TRACKS)], "after mirror.apply wrote the project: every track read")
  -- a page's own edit
  local mid3 = m.tracks[60].items[2]
  published = {}
  F.move(mid3, 0.5); dawview.action(F.proj, cfg, b, { edit = { op = "none" } }); clock = clock + 1
  tick(); tick()
  check(published["dawc" .. (59 // dawview.CHUNK_TRACKS)], "after an edit from the page: every track read")
  -- Undo can be redone: every look is whole (Undo moves anything)
  local mid4 = m.tracks[70].items[2]
  published = {}
  reaper.Undo_CanRedo2 = function() return "Move items" end
  F.move(mid4, 0.5); clock = clock + 1
  tick(); tick()
  check(published["dawc" .. (69 // dawview.CHUNK_TRACKS)], "while a redo is waiting: every track read")
  reaper.Undo_CanRedo2 = nil
  -- track lines (name, colour, mute, solo) are always read: a mixer click shows at once
  dawview.SLICE = was_slice
  say("cut 8's partial look keeps its memory by track pointer and GUID; peaks asked of REAPER in this test: %d", asked)
  dawview.reset()
end

-- ---- band.songs held a few seconds ----
do
  local root, reads, listed = "C:/fake/Songs", 0, { "A", "B", "C" }
  local sessions = { A = { published = "2026-11-01" }, B = { published = "2026-11-03" }, C = { published = "2026-11-02" } }
  local real_read, real_subdirs, real_exists = band.read_json, band.subdirs, reaper.file_exists
  band.read_json = function(path) reads = reads + 1; return sessions[path:match("/(%w+)/session.json$")] end
  band.subdirs = function() return listed end
  rawset(reaper, "file_exists", function() return true end)
  local c = { root = root, user = "" }
  band.forget_songs()
  local first = band.songs(c)
  check(table.concat(first, ",") == "B,C,A" and reads == 3, "newest first: " .. table.concat(first, ","))
  first[1] = "mutated"
  F.clock = F.clock + 1
  local again = band.songs(c)
  check(reads == 3 and table.concat(again, ",") == "B,C,A", "held: not read again, and a caller's sort can't change the held list (" .. reads .. ")")
  F.clock = F.clock + band.SONGS_HOLD
  band.songs(c)
  check(reads == 6, "read again after SONGS_HOLD s: " .. reads)
  sessions.D, listed = { published = "2026-11-09" }, { "A", "B", "C", "D" }
  check(#band.songs(c) == 3, "a song a bandmate published shows after the hold, not before")
  band.forget_songs()
  check(band.songs(c)[1] == "D", "forgotten: read at once")
  -- a session.json written (or removed) here shows at once
  band.forget_songs()
  band.read_json, band.subdirs, reaper.file_exists = real_read, real_subdirs, real_exists
  local src = read("lib/band.lua")
  check(src:find('path:sub(-12):lower() == "session.json" then songs_memo = {}', 1, true), "a write or removal of a session.json empties the held list")
  check(src:find('reaper.GetExtState(band.SECTION, "join boots") == ""', 1, true), "not held while a join's first copy is coming")
  local g, real_boot = 0, band.boot_songs
  band.boot_songs = function() return {} end
  local was = reaper.GetExtState
  reaper.GetExtState = function(s, k) if k == "join boots" then return "1" end return was(s, k) end
  band.read_json = function(path) g = g + 1; return sessions[path:match("/(%w+)/session.json$")] end
  band.subdirs, reaper.file_exists = function() return listed end, function() return true end
  band.songs(c); band.songs(c)
  check(g >= 8, "with a join's boot copy coming nothing is held (" .. g .. ")")
  reaper.GetExtState, band.read_json, band.subdirs, reaper.file_exists = was, real_read, real_subdirs, real_exists
  band.boot_songs = real_boot
  say("band.songs: a repeat inside %d s reads no session.json", band.SONGS_HOLD)
end

-- ---- the stream trace capped ----
do
  local direct = require("direct")
  local p = os.tmpname()
  local f = assert(io.open(p, "wb")); f:write(("x"):rep(3000)); f:close()
  local was_max, was_size = direct.TRACE_MAX, proxy.size
  direct.TRACE_MAX = 1000
  proxy.size = function(path) local h = io.open(path, "rb"); if not h then return nil end; local n = h:seek("end"); h:close(); return n end
  check(direct.trace_rotate("", 1e6) == false, "no trace: nothing")
  check(direct.trace_rotate(p, 1e6 + 1) == true, "past the cap: it becomes .old")
  local old = io.open(p .. ".old", "rb")
  check(old and not io.open(p, "rb"), "the big file moved aside and a new one starts")
  old:close()
  local f2 = assert(io.open(p, "wb")); f2:write(("y"):rep(3000)); f2:close()
  check(direct.trace_rotate(p, 1e6 + 2) == false, "checked at most each TRACE_CHECK s")
  check(direct.trace_rotate(p, 1e6 + 2 + direct.TRACE_CHECK) == true, "then again: the older .old goes")
  local o2 = io.open(p .. ".old", "rb")
  check(o2 and o2:read("a"):sub(1, 1) == "y", "the .old is the latest big one")
  o2:close()
  os.remove(p); os.remove(p .. ".old")
  direct.TRACE_MAX, proxy.size = was_max, was_size
end

-- ---- mirror's marks for the Project page ----
do
  local mirror = require("mirror")
  check(type(mirror.hinted) == "function", "mirror.hinted is shared with the Project page's look")
  local src = read("lib/mirror.lua")
  check(src:find("mirror.applied = (mirror.applied or 0) + 1", 1, true), "mirror.apply counts what StudioSync writes")
  local was = mirror.applied or 0
  mirror.touch(F.proj, F.raw.GetTrack(F.proj, 0))
  check(mirror.applied == was + 1, "mirror.touch too")
end
print("ok perf cuts 7-9: colour look with parity, the Project page's partial look, status and link laps, songs held, trace capped")
