-- rt-hubrank (2026-11-20): a song's hub by who reaches whom. rt-hubfix part 2 published each computer's `sees` (those its direct link reaches
-- in the room) and left the ranking: "a hub is still chosen without asking whether everyone can reach it". lib/hub.lua now: hub.reach counts,
-- for each computer in the room, how many of the others don't reach it (miss, by their word) and how many it doesn't reach (blind, by its
-- own); below the song's home the ranking is fewest miss, fewest blind, then as before (hub.closer); whoever holds the role keeps it unless
-- another has been reached by REACH more of the others for REACH_SETTLE s. lib/livex.lua's best-connected computer (the live mix's host while
-- shared CPU runs) starts with the same two numbers.
-- Here: (1) the numbers and the pure election with three, four and five computers, an old extension, an older StudioSync, a lying computer;
-- (2) a small world over 20 minutes, each computer electing from the statuses as they reach it: partial reach, two that can't see each
-- other, an old extension, one that drops out and returns, a link that drops for a moment, flaps, or goes for good; (3) Live sync's tick
-- end to end; (4) the live mix's host.
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
package.loaded.groups = { trusted = function() return {} end, role = function() return "member" end }
local hub = require("hub")
local livex = require("livex")
local BASE = 2000000

-- ---- 1. the numbers, and the election from them ---------------------------------------------------------------------------------------
-- A room: names (the first online longest), links "A-B B-C" (both ways), x[name] = { holds, ext, old (an older StudioSync: its status says
-- neither ext nor sees), off, sees (its own word, in place of its links) }. -> candidates as hub.candidates makes them.
local function room(names, links, x)
  local set, list = {}, {}
  for a, b2 in links:gmatch("(%w+)%-(%w+)") do set[a .. "|" .. b2], set[b2 .. "|" .. a] = true, true end
  for i, n in ipairs(names) do
    local o = (x or {})[n] or {}
    local sees = {}
    for _, m in ipairs(o.sees or names) do if m ~= n and (o.sees or set[n .. "|" .. m]) then sees[m] = true end end
    local c = { user = n, machine = "m-" .. n, since = BASE - 100000 + i * 1000, link = true, off = o.off, songs = { Song = { holds = o.holds, sees = sees } } }
    if not o.old then c.ext = o.ext or "1.0.28" else c.songs.Song.sees = {} end
    list[#list + 1] = c
  end
  return list
end
local function by(list) local out = {}; for _, c in ipairs(list) do out[c.user] = c end; return out end
local function elect(list, home, studio, now, mem) hub.reach(list, "Song"); return hub.elect_song(list, "Song", home, studio, now or BASE, mem) end

-- three: Desk and Mac can't reach each other, Lap reaches both
local CHAIN = "Desk-Lap Lap-Mac"
local r3 = by(hub.reach(room({ "Mac", "Lap", "Desk" }, CHAIN), "Song"))
assert(r3.Mac.miss == 1 and r3.Mac.blind == 1 and r3.Desk.miss == 1 and r3.Desk.blind == 1 and r3.Lap.miss == 0 and r3.Lap.blind == 0,
  "three: Lap is reached by both others; the Mac and the desktop by one each")
local u, why = elect(room({ "Mac", "Lap", "Desk" }, CHAIN))
assert(u == "Lap" and why == "ranked", "nobody holds it: the one both others reach, though the Mac is online longest (" .. tostring(u) .. ")")
u, why = elect(room({ "Mac", "Lap", "Desk" }, CHAIN), nil, "Desk")
assert(u == "Lap" and why == "ranked", "the studio hub has the song open, but one bandmate can't reach it and everybody reaches Lap: Lap")
u, why = elect(room({ "Mac", "Lap", "Desk" }, "Desk-Lap Lap-Mac Desk-Mac"), nil, "Desk")
assert(u == "Desk" and why == "studio", "everybody reaches everybody: the studio hub, as before")
u, why = elect(room({ "Mac", "Lap", "Desk" }, CHAIN), "Mac", "Desk")
assert(u == "Mac" and why == "home", "the song's home is here: it hosts, whoever reaches it (James's decision; the ranking is for below the home)")
assert(table.concat(hub.far(room({ "Mac", "Lap", "Desk" }, CHAIN), "Song", "Mac"), ",") == "Desk", "and Health can say who has no direct link to it")
-- the holder, and the settling time
local held = room({ "Mac", "Lap", "Desk" }, CHAIN, { Mac = { holds = true } })
assert(elect(held) == "Lap", "the Mac holds it, Lap is reached by one more: without a memory, Lap at once")
local mem = {}
u, why = elect(held, nil, nil, BASE, mem)
assert(u == "Mac" and why == "kept", "with the tick's memory: not at once")
assert(elect(held, nil, nil, BASE + hub.REACH_SETTLE - 1, mem) == "Mac", "nor a second before REACH_SETTLE")
assert(elect(held, nil, nil, BASE + hub.REACH_SETTLE, mem) == "Lap", "after REACH_SETTLE s of it: Lap")
mem = {}
elect(held, nil, nil, BASE, mem)
elect(room({ "Mac", "Lap", "Desk" }, "Desk-Lap Lap-Mac Desk-Mac", { Mac = { holds = true } }), nil, nil, BASE + 20, mem) -- (the link came back for a moment)
assert(elect(held, nil, nil, BASE + hub.REACH_SETTLE + 5, mem) == "Mac", "a break in it starts the count again")
assert(elect(held, nil, nil, BASE + 20 + hub.REACH_SETTLE + 5, mem) == "Mac" and elect(held, nil, nil, BASE + hub.REACH_SETTLE * 2 + 5, mem) == "Lap", "counted from when it was so again")
-- two say they hold it (a move in flight: Lap has taken it, the Mac hasn't given it up yet): between holders the ranking before decides, the
-- same on every computer at once; reach moves it only through each computer's own settling time
local two = room({ "Mac", "Lap", "Desk" }, CHAIN, { Mac = { holds = true }, Lap = { holds = true } })
mem = {}
assert(elect(two, nil, nil, BASE, mem) == "Mac" and elect(two, nil, nil, BASE + hub.REACH_SETTLE, mem) == "Lap", "two holders: the one online longer until this computer's settling time is over, then the better reached")
-- marginally better never moves it: everybody reaches everybody, the holder is the youngest and reaches fewer itself
local full3 = room({ "Mac", "Lap", "Desk" }, "Desk-Lap Lap-Mac Desk-Mac", { Desk = { holds = true } })
u, why = elect(full3)
assert(u == "Desk" and why == "kept", "everybody reaches the holder: kept, though two are online longer")
local blind = room({ "Mac", "Lap", "Desk" }, "", { Mac = { sees = { "Lap", "Desk" } }, Lap = { sees = { "Mac", "Desk" } }, Desk = { sees = { "Mac" }, holds = true } })
local rb = by(hub.reach(blind, "Song"))
assert(rb.Desk.miss == 0 and rb.Desk.blind == 1 and rb.Lap.miss == 1 and rb.Mac.miss == 0 and rb.Mac.blind == 0, "blind: by its own word; miss: by the others'")
assert(elect(blind) == "Desk", "the holder reaches one fewer itself but everybody reaches it: a tie-breaker never moves the role")
blind[3].songs.Song.holds = nil
assert(elect(blind) == "Mac", "nobody holding: then the tie-breaker counts (the Mac reaches everyone, the desktop doesn't)")

-- four: everybody reaches everybody but A and D; A (online longest) holds
local four = room({ "A", "B", "C", "D" }, "A-B A-C B-C B-D C-D", { A = { holds = true } })
assert(elect(four) == "B", "four: B and C are reached by all three others; of those the one online longer")
local rev = { four[4], four[2], four[1], four[3] }
assert(elect(rev) == "B" and elect({ four[3], four[4], four[2], four[1] }) == "B", "the same answer whatever order the statuses come in")
assert(elect(room({ "A", "B", "C", "D" }, "A-B A-C A-D B-C B-D C-D", { D = { holds = true } })) == "D", "four, everybody reaches everybody: the holder stays")

-- five: X (online longest, the studio hub) isn't reached by P or Q; everybody reaches Y
local FIVE = "X-Y X-R Y-P Y-Q Y-R P-Q P-R Q-R"
local r5 = by(hub.reach(room({ "X", "Y", "P", "Q", "R" }, FIVE), "Song"))
assert(r5.X.miss == 2 and r5.Y.miss == 0 and r5.P.miss == 1 and r5.Q.miss == 1 and r5.R.miss == 0, "five: the numbers")
assert(elect(room({ "X", "Y", "P", "Q", "R" }, FIVE)) == "Y", "a computer two bandmates can't reach is never chosen over one everybody reaches")
assert(elect(room({ "X", "Y", "P", "Q", "R" }, FIVE), nil, "X") == "Y", "not as the studio hub either")
assert(elect(room({ "X", "Y", "P", "Q", "R" }, FIVE, { X = { holds = true } })) == "Y", "nor kept, once it has been so for REACH_SETTLE s")
assert(elect(room({ "X", "Y", "P", "Q", "R" }, FIVE, { R = { holds = true } })) == "R", "R holds it and everybody reaches R as well: R stays, though Y is online longer")
assert(table.concat(hub.far(room({ "X", "Y", "P", "Q", "R" }, FIVE), "Song", "X"), ",") == "P,Q", "who has no direct link to X")

-- an old extension: never elected, however well reached, and nobody waits for it; its word still counts
local old5 = room({ "X", "Y", "P", "Q", "R" }, FIVE, { Y = { ext = "1.0.23", holds = true } })
mem = {}
u = elect(old5, nil, nil, BASE, mem)
assert(u == "R", "Y's extension is 1.0.23: not the hub though it holds the role and everybody reaches it; R at once, no settling time (" .. tostring(u) .. ")")
assert(by(old5).X.miss == 2 and by(old5).R.miss == 0, "an old extension's computer is still one of the others who must reach the hub")
local allold = room({ "Mac", "Lap", "Desk" }, CHAIN, { Mac = { ext = "1.0.23" }, Lap = { ext = "0" }, Desk = { ext = "1.0.23" } })
assert(elect(allold) == "Lap", "nobody's extension is new enough: the role still goes to someone, the best reached")
-- an older StudioSync (its status says neither ext nor sees): ranked as before, and its silence is nobody's miss
local older = room({ "Mac", "Lap", "Desk" }, CHAIN, { Mac = { old = true, holds = true } })
hub.reach(older, "Song")
assert(by(older).Mac.miss == nil and by(older).Desk.miss == 0 and by(older).Lap.miss == 0, "an older StudioSync says nothing about reach: no numbers for it, no miss from it")
assert(elect(older) == "Mac", "so it keeps the role it holds, as before (an update that reaches the computers one by one moves nothing)")
-- those not in the song, and candidates nobody ran hub.reach on
local elsewhere = room({ "A", "B" }, "A-B")
elsewhere[2].songs = { Other = { sees = {} } }
hub.reach(elsewhere, "Song")
assert(elsewhere[1].miss == 0 and elsewhere[2].miss == nil, "someone in another song isn't one of the others here")
assert(hub.closer({ user = "a", since = 5, link = true }, { user = "b", since = 9, link = true }) == true and hub.closer({ user = "a", since = 5, miss = 1 }, { user = "b", since = 9 }) == false,
  "without numbers the ranking is the one before; with them, reach first")

-- a lying computer (`sees` is each computer's own word): what it can and can't do
local lie = room({ "A", "B", "C", "L" }, "A-B A-C B-C", { A = { holds = true }, L = { sees = { "A", "B", "C" } } })
hub.reach(lie, "Song")
assert(by(lie).L.miss == 3 and by(lie).L.blind == 0, "claiming to reach everyone doesn't make anyone reach it: its miss is the others' word")
assert(elect(lie) == "A", "so it can't elect itself, and the holder stays")
lie = room({ "A", "B", "C", "L" }, "A-B A-C B-C A-L B-L C-L", { A = { holds = true }, L = { sees = { "B", "C" } } })
assert(elect(lie) == "B", "known limit: leaving the holder out of its sees costs the holder one miss, and after REACH_SETTLE s the role moves to the next (never to the liar by that)")

-- ---- 2. a small world: each computer elects from the statuses as they reach it -----------------------------------------------------------
-- o: users (in order) = { name, since, ext, old (an older StudioSync: it keeps saying what it held; no ext, no sees) }; link(x, u, t): do x
-- and u reach each other directly at t (a status crosses in 2 s); delay(x, u, t): how late u's status file is at x without a link;
-- quiet(u, t): u has dropped out (no status, no link, no election); restart(u): it comes back as a REAPER just started (holding nothing,
-- online since then) rather than one that kept running; first: who holds the song's hub at the start; home, pref; T: seconds.
-- Each computer's link watch is the real one (hub.link_watch: a name leaves its sees after LINK_GONE s, and is back at once), and the
-- election is Live sync's tick step by step: candidates, vouched, reach, drop, the studio's, the song's with its memory.
-- -> per computer: changes (how often its view of the hub moved), hub (its view at the end), last (when it last moved), ever (it held the
-- role at some time); claims (how often a computer took the role); agree_from (from when all electing computers named the same hub, to the end).
local WARM = 150
local function sim(o)
  local hist, state, names = {}, {}, {}
  for _, usr in ipairs(o.users) do
    names[#names + 1] = usr.name; hist[usr.name] = {}
    state[usr.name] = { holds = usr.name == o.first, hub = o.first, changes = 0, said = -math.huge, link = {}, mem = {}, got = {}, since = usr.since, ever = usr.name == o.first }
  end
  local function up(n, t) return not (o.quiet and o.quiet(n, t)) end
  local function linked(x, n, t) return up(x, t) and up(n, t) and o.link(x, n, t) end
  local agree_from, claims = nil, 0
  for t = 0, o.T, 2 do
    for _, usr in ipairs(o.users) do -- (each one's link, and its status: every 15 s, and at once when what it holds or reaches changes)
      local s = state[usr.name]
      if not up(usr.name, t) then s.down = true
      else
        if s.down and o.restart and o.restart(usr.name) then s.holds, s.since, s.link, s.mem = false, BASE + t, {}, {} end
        s.down = nil
        local reach = {}
        for _, v in ipairs(names) do if v ~= usr.name then reach[v] = { ok = linked(usr.name, v, t), at = BASE + t } end end
        s.gone, s.back = hub.link_watch(s.link, reach, BASE + t)
        s.sees, s.set = {}, {}
        for _, v in ipairs(names) do local m = s.link[v]; if m and m.reached and not m.gone then s.sees[#s.sees + 1] = v; s.set[v] = true end end
        local key = table.concat(s.sees, ",")
        if t - s.said >= 15 or s.wrote ~= s.holds or s.wrote_sees ~= key then
          hist[usr.name][#hist[usr.name] + 1] = { at = t, st = { user = usr.name, machine = "m-" .. usr.name, time = string.format("%010d", t),
            hub = { since = s.since, link = true, song = s.holds or nil, ext = not usr.old and usr.ext or nil, sees = not usr.old and s.sees or nil } } }
          s.said, s.wrote, s.wrote_sees = t, s.holds, key
        end
      end
    end
    local views = {}
    for _, x in ipairs(o.users) do
      local s = state[x.name]
      if t >= WARM and not x.old and up(x.name, t) then -- (WARM: everyone's statuses have gone round once)
        local sts = {}
        for _, v in ipairs(names) do
          if v ~= x.name then
            local d, got = linked(x.name, v, t) and 2 or o.delay(x.name, v, t), s.got[v]
            for _, h in ipairs(hist[v]) do if h.at <= t - d and (not got or h.at > got.at) then got = h end end
            s.got[v] = got -- (a status that has arrived stays arrived when the next ones take longer)
            if got then sts[#sts + 1] = { song = "Song", st = got.st, seen = -math.huge } end
          end
        end
        local list = hub.candidates(sts, t, function(stamp) return t - tonumber(stamp) end)
        list[#list + 1] = { user = x.name, machine = "m-" .. x.name, since = s.since, link = true, ext = x.ext, sees = s.set,
          songs = { Song = { holds = s.holds, sees = s.set } }, listening = BASE + t - s.since < hub.LISTEN or nil }
        list = hub.vouched(list)
        hub.reach(list, "Song")
        list = hub.drop(list, s.gone, nil, s.back)
        local song = hub.elect_song(list, "Song", o.home, (hub.elect_studio(list, o.pref, BASE + t)), BASE + t, s.mem)
        if song ~= s.hub then s.changes, s.hub, s.last = s.changes + 1, song, t end
        if song == x.name and not s.holds then claims = claims + 1 end
        s.holds = song == x.name
        s.ever = s.ever or s.holds
        views[#views + 1] = tostring(song)
      end
    end
    local same = true
    for i = 2, #views do same = same and views[i] == views[1] end
    if #views > 0 then if not same then agree_from = nil elseif not agree_from then agree_from = t end end
  end
  local out = { agree_from = agree_from, claims = claims }
  for _, usr in ipairs(o.users) do out[usr.name] = state[usr.name] end
  return out
end
local function links(spec)
  local set = {}
  for a, b2 in spec:gmatch("(%w+)%-(%w+)") do set[a .. "|" .. b2], set[b2 .. "|" .. a] = true, true end
  return function(x, n) return set[x .. "|" .. n] == true end
end
-- (the file's trip through Syncthing: 8 s for two minutes, then 60 s for two minutes, and so on: with a status every 15 s it reads 60-75 s old)
local function hiccups(_, _, t) return t % 240 < 120 and 8 or 60 end
local function people(spec) -- "Mac:30000 Lap:600 Desk:500" (seconds online at the start), "Mac:30000:1.0.23" (its extension), "Mac:30000:old"
  local out = {}
  for name, ago, e in spec:gmatch("(%w+):(%d+):?([%w%.]*)") do out[#out + 1] = { name = name, since = BASE - tonumber(ago), ext = e ~= "old" and (e ~= "" and e or "1.0.28") or nil, old = e == "old" or nil } end
  return out
end
local SETTLED = WARM + hub.REACH_SETTLE + 6 -- (a holder clearly worse reached from the start: everyone has moved by then)

-- three: Desk and Mac can't reach each other, Lap reaches both, the Mac (online longest) holds the hub; the desktop is the studio's
local three = people("Desk:500 Lap:600 Mac:30000")
local r = sim({ users = three, first = "Mac", pref = "Desk", T = 1200, link = links(CHAIN), delay = hiccups })
assert(r.Desk.hub == "Lap" and r.Lap.hub == "Lap" and r.Mac.hub == "Lap", "three: the hub goes to Lap, the one both others reach (" .. tostring(r.Desk.hub) .. ")")
assert(r.Desk.changes == 1 and r.Lap.changes == 1 and r.Mac.changes == 1 and r.claims == 1, "once on each computer, and one computer took it once (Desk " .. r.Desk.changes .. ", Lap " ..
  r.Lap.changes .. ", Mac " .. r.Mac.changes .. ", taken " .. r.claims .. " times)")
assert(r.Lap.last >= WARM + hub.REACH_SETTLE and r.Desk.last <= SETTLED and r.Mac.last <= SETTLED and r.agree_from <= SETTLED,
  "after the settling time and not before; all three agree from " .. tostring(r.agree_from) .. " s to the end of 20 minutes of late files")
assert(not r.Desk.ever, "the two that can't reach each other never trade it: the desktop never held it")
-- the same room, the song's home is the Mac: it hosts (James), and nothing moves
r = sim({ users = three, first = "Mac", home = "Mac", pref = "Desk", T = 1200, link = links(CHAIN), delay = hiccups })
assert(r.Desk.hub == "Mac" and r.Lap.hub == "Mac" and r.Desk.changes == 0 and r.Lap.changes == 0 and r.Mac.changes == 0 and r.claims == 0, "the song's home keeps hosting, whoever reaches it")
-- the home away: the ranking decides, and the home takes it back when it returns (as before)
r = sim({ users = three, first = "Lap", home = "Mac", pref = "Desk", T = 900, link = links(CHAIN), delay = hiccups, quiet = function(n, t) return n == "Mac" and t < 400 end, restart = function() return true end })
-- (the desktop reads the Mac only as a late file: between Lap handing the role back and the Mac's status arriving it may name itself, as before)
assert(r.Desk.hub == "Mac" and r.Lap.hub == "Mac" and r.Mac.hub == "Mac" and r.Lap.changes == 1 and r.Desk.changes <= 2, "the home away: Lap holds it; back: handed to the home once (Desk " ..
  tostring(r.Desk.hub) .. " " .. r.Desk.changes .. ", Lap " .. tostring(r.Lap.hub) .. " " .. r.Lap.changes .. ", Mac " .. tostring(r.Mac.hub) .. ")")

-- two that can't see each other, alone, each the other's status only as a late file: neither is better reached, nothing moves (rt-hubfix)
r = sim({ users = people("Desk:500 Mac:30000"), first = "Mac", T = 1200, link = function() return false end, delay = hiccups })
assert(r.Desk.changes == 0 and r.Mac.changes == 0 and r.Desk.hub == "Mac" and r.claims == 0, "two alone that can't reach each other: the holder keeps it through 20 minutes of late files")

-- one old extension: Lap, the one both reach, is on 1.0.23. It isn't elected, nobody waits for it, and the other two don't trade the role
r = sim({ users = people("Desk:500 Lap:600:1.0.23 Mac:30000"), first = "Mac", pref = "Desk", T = 1200, link = links(CHAIN), delay = hiccups })
assert(r.Desk.hub == "Mac" and r.Lap.hub == "Mac" and r.Mac.hub == "Mac" and r.Desk.changes == 0 and r.Lap.changes == 0 and r.Mac.changes == 0 and r.claims == 0 and not r.Lap.ever,
  "the best-reached computer's extension is too old: the Mac keeps it (the desktop is reached no better), steadily, and Lap never has it")
r = sim({ users = people("Desk:500 Lap:600:1.0.23 Mac:30000"), first = "Lap", pref = "Desk", T = 1200, link = links(CHAIN), delay = hiccups })
assert(r.Desk.hub == r.Lap.hub and r.Lap.hub == r.Mac.hub and r.Desk.hub ~= "Lap" and r.Desk.changes == 1 and r.Mac.changes == 1 and r.claims == 1 and r.agree_from <= WARM + 4,
  "the old one holds it at the start: given up at once (agreed from " .. tostring(r.agree_from) .. " s), no settling time, once")
-- the Mac on an older StudioSync (no ext, no sees; it keeps saying it holds the hub): left as it was, steadily (rt-hubfix)
r = sim({ users = people("Desk:500 Lap:600 Mac:30000:old"), first = "Mac", pref = "Desk", T = 1200, link = links(CHAIN), delay = hiccups })
assert(r.Desk.hub == "Mac" and r.Lap.hub == "Mac" and r.Desk.changes == 0 and r.Lap.changes == 0 and r.claims == 0, "a status that says nothing about reach: as before, and steady")

-- four: everybody reaches everybody but A and D; A holds
local four_p = people("A:30000 B:20000 C:10000 D:5000")
r = sim({ users = four_p, first = "A", T = 1200, link = links("A-B A-C B-C B-D C-D"), delay = hiccups })
assert(r.A.hub == "B" and r.B.hub == "B" and r.C.hub == "B" and r.D.hub == "B" and r.claims == 1, "four, D can't reach the holder: the hub goes to B, whom everybody reaches")
assert(r.A.changes == 1 and r.B.changes == 1 and r.C.changes == 1 and r.D.changes == 1 and r.agree_from <= SETTLED, "once each, agreed from " .. tostring(r.agree_from) .. " s")
-- five: E, on a poor network, reaches only C; A holds
r = sim({ users = people("A:30000 B:20000 C:10000 D:5000 E:4000"), first = "A", T = 1200, link = links("A-B A-C A-D B-C B-D C-D C-E"), delay = hiccups })
assert(r.A.hub == "C" and r.B.hub == "C" and r.C.hub == "C" and r.D.hub == "C" and r.E.hub == "C" and r.claims == 1, "five: the hub goes to C, the only one E reaches too")
assert(r.A.changes == 1 and r.B.changes == 1 and r.C.changes == 1 and r.D.changes == 1 and r.E.changes == 1 and r.agree_from <= SETTLED, "once each, agreed from " .. tostring(r.agree_from) .. " s")

-- hysteresis, four computers that all reach each other; A holds though B is online longer (marginally better: never moves it)
local hyst = people("B:30000 A:20000 C:10000 D:5000")
local MESH = links("A-B A-C A-D B-C B-D C-D")
local function mesh_but(down) return function(x, n, t) return MESH(x, n) and not ((x .. n == "AD" or x .. n == "DA") and down(t)) end end
r = sim({ users = hyst, first = "A", T = 1200, link = MESH, delay = hiccups })
assert(r.A.changes + r.B.changes + r.C.changes + r.D.changes == 0 and r.claims == 0 and r.B.hub == "A", "everybody reaches the holder: 20 minutes, no move, though B ranks ahead of it")
-- the A-D link drops for 20 s: D's sees loses A after LINK_GONE s and has it back at once: under REACH_SETTLE, the role stays
r = sim({ users = hyst, first = "A", T = 900, link = mesh_but(function(t) return t >= 300 and t < 320 end), delay = hiccups })
assert(r.A.changes == 0 and r.B.changes == 0 and r.C.changes == 0 and r.claims == 0, "one link down for 20 s: the role doesn't move, and nobody else takes it")
assert(r.D.hub == "A" and r.D.changes <= 2, "(D itself can't reach the hub meanwhile: its own view may leave A and come back, as before)")
-- the same link flapping, 20 s down and 20 s up, for ten minutes
r = sim({ users = hyst, first = "A", T = 1200, link = mesh_but(function(t) return t >= 300 and t < 900 and (t - 300) % 40 < 20 end), delay = hiccups })
assert(r.A.changes == 0 and r.B.changes == 0 and r.C.changes == 0 and r.claims == 0 and r.A.hub == "A", "a link flapping every 20 s for ten minutes: the role never moves")
-- the link gone for good: one move, after the link watch's LINK_GONE and the settling time
r = sim({ users = hyst, first = "A", T = 1200, link = mesh_but(function(t) return t >= 300 end), delay = hiccups })
assert(r.A.hub == "B" and r.B.hub == "B" and r.C.hub == "B" and r.D.hub == "B" and r.A.changes == 1 and r.B.changes == 1 and r.C.changes == 1 and r.claims == 1,
  "the link gone for good: the role moves once, to B")
assert(r.B.last >= 300 + hub.LINK_GONE + hub.REACH_SETTLE - 2 and r.B.last <= 300 + hub.LINK_GONE + hub.REACH_SETTLE + 8, "about LINK_GONE + REACH_SETTLE s after the link went (" .. tostring(r.B.last - 300) .. " s)")
-- a slow flap (a minute down, a minute up): one move to the computer everybody reaches, and it stays there
r = sim({ users = hyst, first = "A", T = 1500, link = mesh_but(function(t) return t >= 300 and (t - 300) % 120 < 60 end), delay = hiccups })
assert(r.B.hub == "B" and r.A.changes == 1 and r.B.changes == 1 and r.C.changes == 1 and r.claims == 1, "a link down a minute at a time: moved once, to one everybody reaches, and never back")

-- one that drops out and returns. A (online longest, holding) is cut off from 300 to 500 s
local back = people("A:30000 B:20000 C:10000 D:5000")
local function a_out(n, t) return n == "A" and t >= 300 and t < 500 end
r = sim({ users = back, first = "A", T = 1200, link = MESH, delay = hiccups, quiet = a_out, restart = function() return true end })
assert(r.B.hub == "B" and r.C.hub == "B" and r.D.hub == "B" and r.A.hub == "B" and r.B.changes == 1 and r.C.changes == 1 and r.D.changes == 1 and r.claims == 1,
  "the hub drops out: replaced once; it returns as a REAPER just started: the one holding it now keeps it")
assert(r.B.last <= 300 + hub.LINK_GONE + 4, "replaced within the link watch's seconds, not after a settling time (" .. tostring(r.B.last - 300) .. " s)")
-- its REAPER kept running (it still says it holds the role): two holders, the same one wins on every computer, and that's the end of it
r = sim({ users = back, first = "A", T = 1200, link = MESH, delay = hiccups, quiet = a_out })
assert(r.A.hub == r.B.hub and r.B.hub == r.C.hub and r.C.hub == r.D.hub and r.B.changes <= 2 and r.C.changes <= 2 and r.D.changes <= 2 and r.claims <= 2 and r.B.last <= 510,
  "it returns still holding: settled within seconds of its return, at most one move away and one back (A " .. tostring(r.A.hub) .. " " .. r.A.changes .. ", B " .. tostring(r.B.hub) .. " " ..
  r.B.changes .. " last " .. tostring(r.B.last) .. ", C " .. tostring(r.C.hub) .. " " .. r.C.changes .. ", D " .. tostring(r.D.hub) .. " " .. r.D.changes .. ", taken " .. r.claims .. " times)")
-- a computer everybody reaches drops out of a room with partial reach, and returns: the role doesn't follow it back and forth
r = sim({ users = people("Desk:500 Lap:600 Mac:30000"), first = "Lap", pref = "Desk", T = 1500, link = links(CHAIN), delay = hiccups,
  quiet = function(n, t) return n == "Lap" and t >= 300 and t < 600 end, restart = function() return true end })
assert(r.Lap.hub == "Lap" and r.Desk.hub == "Lap" and r.Mac.hub == "Lap" and r.Desk.changes <= 2 and r.Mac.changes <= 2 and r.claims <= 2,
  "the one both others reach leaves and returns: away once, and back to it once it's settled (Desk " .. r.Desk.changes .. ", Mac " .. r.Mac.changes .. ", taken " .. r.claims .. " times)")

-- ---- 3. Live sync's tick end to end -------------------------------------------------------------------------------------------------------
do
  local cfg, b = { root = "R", user = "Bo" }, { song = "Song", room = "main" }
  local function iso(ago) return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - ago) end
  ext["BandSync/hub since"] = tostring(os.time() - 1000) -- (online a while: past hub.LISTEN)
  ext["BandSync/menu extension"] = "1.0.28"
  files["R/Song/session.json"] = {} -- (no sharer known here: the song has no home)
  band.songs = function() return { "Other", "Song" } end
  band.subdirs = function(d) return (d == "R/Song/rooms" or d == "R/Other/rooms") and { "main" } or {} end
  local in_song = { "Desk.json", "Lap.json" }
  band.files = function(d)
    if d == "R/Song/rooms/main/status" then return in_song end
    if d == "R/Other/rooms/main/status" then return { "Lap.json" } end
    return {}
  end
  -- Desk holds the song's hub; Bo's link doesn't reach it, Lap's does. Lap has another song open too, and its newest status is that one's
  files["R/Song/rooms/main/status/Desk.json"] = { user = "Desk", machine = "md", time = iso(3), hub = { since = os.time() - 9000, link = true, song = true, ext = "1.0.28", sees = { "Lap" } } }
  files["R/Song/rooms/main/status/Lap.json"] = { user = "Lap", machine = "ml", time = iso(5), hub = { since = os.time() - 500, link = true, ext = "1.0.28", sees = { "Bo", "Desk" } } }
  files["R/Other/rooms/main/status/Lap.json"] = { user = "Lap", machine = "ml", time = iso(1), hub = { since = os.time() - 500, link = true, ext = "1.0.28", sees = { "Zed" } } }
  files["R/Song/rooms/main/status/Gus.json"] = { user = "Gus", machine = "mg", time = iso(2), hub = { since = os.time() - 700, link = true, ext = "1.0.28", sees = { "Desk" } } }
  local guest = {}
  package.loaded.presence = { peers = function() return {} end }
  package.loaded.direct = { available = function() return true end, live_available = function() return true end, firewall_ok = function() return true end,
    reach = function() return { Lap = { ok = true, at = os.time() }, Desk = { ok = false, at = os.time() } } end }
  package.loaded.removal = { guest_names = function() return guest end }
  package.loaded.trust = { own_file_ok = function() return true end, user_file = function(n) return n .. ".json" end }
  package.loaded.sync = { machine = function() return "mbo" end, loading = {}, room_dir = function(_, s, rm) return "R/" .. s .. "/rooms/" .. rm end }
  package.loaded.recall = { dir = function() return "R/Song/rooms/main/recall" end, save = function() end }
  local function tick() now_p = now_p + hub.SCAN_EVERY + 1; hub.tick("P", cfg, b); return band.ext_json(band.SECTION, "hub view studio1 Song") end
  local v = tick()
  assert(v.hub == "Desk" and v.why == "kept", "Lap is reached by one more than Desk, the holder: not moved at the first sight of it (" .. tostring(v.hub) .. ")")
  assert(type(v.far) == "table" and #v.far == 1 and v.far[1] == "Bo", "who has no direct link to the hub: Bo. Lap's word is its status in this song (it reaches Desk), not its newest, another song's")
  assert(hub.line(v, "Bo"):find("No direct link to this project's hub from: Bo.", 1, true), "Health says so: " .. hub.line(v, "Bo"))
  local part = hub.status_part(cfg, b)
  assert(type(part.sees) == "table" and #part.sees == 1 and part.sees[1] == "Lap" and part.song == nil, "this computer's status: it reaches Lap, and holds nothing")
  local settle = hub.REACH_SETTLE
  hub.REACH_SETTLE = 0 -- (the settling time over)
  v = tick()
  assert(v.hub == "Lap" and v.why == "ranked" and v.far == nil, "then the hub is Lap, whom both others reach (" .. tostring(v.hub) .. ", " .. tostring(v.why) .. ")")
  assert(hub.line(v, "Bo"):find("this project: Lap (the one the others here reach best, then online longest)", 1, true), "Health: " .. hub.line(v, "Bo"))
  -- the song's home is Desk: it hosts, whoever reaches it, and Health says who doesn't
  files["R/Song/session.json"] = { host = "Desk", published = iso(10) }
  v = tick()
  assert(v.hub == "Desk" and v.why == "home" and type(v.far) == "table" and v.far[1] == "Bo", "the song's home hosts though Bo can't reach it (" .. tostring(v.hub) .. ", " .. tostring(v.why) .. ")")
  -- a guest's word isn't counted: Gus says it reaches Desk only, which would cost Lap its lead
  files["R/Song/session.json"] = {}
  in_song = { "Desk.json", "Gus.json", "Lap.json" }
  guest = { Gus = true }
  v = tick()
  assert(v.hub == "Lap", "a guest in the room says it reaches only Desk: Lap all the same (" .. tostring(v.hub) .. ")")
  guest = {}
  v = tick()
  assert(v.hub == "Desk" and v.why == "kept", "the same word from a member counts: Desk and Lap are each missed by one, so the holder stays (" .. tostring(v.hub) .. ")")
  hub.REACH_SETTLE = settle
end

-- ---- 4. the live mix's host while shared CPU runs (lib/livex.lua): best-connected starts with who reaches whom --------------------------
do
  local function st(user, net, rtt, sees, x) x = x or {}; x.user, x.net, x.lrtt, x.cpu, x.lhub, x.hub = user, net, rtt, 10, true, x.hub or { ext = "1.0.28", sees = sees }; return x end
  -- desk is wired and fast, but lap and mac can't reach it; everybody reaches linux and this computer
  local sts = { st("desk", "wired", 10, { "linux", "me" }), st("lap", "wifi", 40, { "linux", "mac", "me" }), st("mac", "wifi", 40, { "lap", "linux", "me" }),
    st("linux", "wifi", 40, { "desk", "lap", "mac", "me" }) }
  local me = { user = "me", net = "wifi", rtt = 50, cpu = 10, can = true, hub = { ext = "1.0.28", sees = { "desk", "lap", "linux", "mac" } } }
  local on_link = { ["d:1"] = "desk", ["l:1"] = "lap", ["m:1"] = "mac", ["x:1"] = "linux" }
  local list = livex.mix_cands(sts, on_link, me, nil, {})
  local c = by(list)
  assert(c.desk.miss == 2 and c.linux.miss == 0 and c.me.miss == 0 and c.lap.miss == 1 and c.mac.miss == 1 and c.lap.blind == 1, "the mix's candidates carry the same numbers")
  local p, why = livex.mix_pick(list)
  assert(p.user == "linux" and why == "best", "two can't reach the wired, fast desktop: the best-connected is one everybody reaches (" .. p.user .. ")")
  c.desk.lmix = true
  p = livex.mix_pick(list)
  assert(p.user == "linux", "the desktop mixes now: handed over, being reached by more is clearly better")
  assert(livex.mix_words(c.desk, "kept", "me"):find("2 here can't reach it directly", 1, true), "Health's words: " .. livex.mix_words(c.desk, "kept", "me"))
  c.desk.lmix, c.me.lmix = nil, true
  p, why = livex.mix_pick(list)
  assert(p.user == "me" and why == "kept", "this computer mixes and everybody reaches it: kept, a few ms of round trip isn't clearly better")
  -- the numbers count everyone in the room by the statuses, not only those live audio reaches here; a guest's word isn't counted
  list = livex.mix_cands(sts, { ["d:1"] = "desk" }, me, nil, {})
  assert(#list == 2 and by(list).desk.miss == 2, "only the desktop is on the link here: it's still missed by the two this computer can't hear")
  sts[#sts + 1] = st("gus", "wifi", 40, { "desk" })
  assert(by(livex.mix_cands(sts, on_link, me, nil, { gus = true })).linux.miss == 0 and by(livex.mix_cands(sts, on_link, me, nil, {})).linux.miss == 1, "a guest's word: not counted; a member's: counted")
  -- statuses that say nothing about reach (an older StudioSync): as before
  list = livex.mix_cands({ { user = "desk", net = "wired", lrtt = 20, cpu = 30, lhub = true, hub = {} } }, { ["d:1"] = "desk" }, { user = "me", net = "wifi", rtt = 30, cpu = 10, can = true }, nil, {})
  assert(by(list).desk.miss == nil and by(list).me.miss == nil and livex.mix_pick(list).user == "desk", "no numbers: wired first, as before")
  local f = assert(io.open("lib/livex.lua", "rb")); local src = f:read("a"); f:close()
  assert(src:find('hub = require("hub").status_part(cfg, b)', 1, true), "mix_host hands this computer's own ext and sees to the pick")
end

print("ok: rt-hubrank (a song's hub by who reaches whom: the numbers, the ranking, the holder's settling time, old extensions, the live mix's host)")
