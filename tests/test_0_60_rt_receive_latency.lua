-- A bandmate's change over the direct link: from the tick that sees its file to applied (rt-look). Desktop -> laptop took 1.2-1.6 s with the
-- sender's file out in 0.11-0.14 s: the receiver held it about a second. Its pass ran at once, but P.receive waits for sync.seen_mine, which
-- wanted the project's change count to be the last look's, and StudioSync's own writes between passes (taken in, not you editing) had moved
-- it; the look that would have caught up was inside its "fifth of REAPER's time" gap, and sync.receive_now only fired as a quiet window after
-- your own edit ended. So it waited for the next 2 s pass. Now a look that began after your last edit counts as having seen it, and a held
-- change is tried again every sync.RETRY s.
-- Part 1 runs Live sync's tick as far as when it receives (StudioSync - Live sync.lua: tick, P.look, P.receive) with the real gate functions,
-- old rules and new side by side. Part 2 is two computers in one Lua (tools/bigproject.lua, tests/fixtures/bigreaper.lua): one sends an
-- envelope point, the other's sync.receive applies it, timed.
package.path = "tools/?.lua;lib/?.lua;tests/fixtures/?.lua;" .. package.path

-- ---- part 1: the cadence ----
package.loaded.band = { files = function() return {} end, read_json = function() end, song_dir = function(_, s) return "root/" .. s end }
local sync = require("sync")
package.loaded.band, package.loaded.sync = nil, nil
local TICK, EVERY = 1 / 30, 2
local old = {
  seen_mine = function(cc, looked_cc, now, looked_at) return cc == looked_cc or now - looked_at > 30 end,
  receive_now = function(held, changed_at, quiet, polled_at, pass_took, now, mouse)
    return held and not mouse and polled_at < changed_at + quiet and now >= changed_at + quiet and now - polled_at > pass_took * 5
  end,
}
local new = { seen_mine = sync.seen_mine, receive_now = sync.receive_now }
-- The receiver: changes arrive at `arrivals`; StudioSync writes something between passes every `bg` s (a live fader shown, a lane painted,
-- peaks); you edit at `edits`, the mouse is held over [down, up). -> seconds from each arrival's tick to its receive.
local function receiver(rules, arrivals, until_t, o)
  o = o or {}
  local took = o.took or 0.03 -- (a look's and a pass's time: Cross Test's)
  local cc, change_count, changed_at, held_since = 0, -1, -math.huge, nil
  local last, polled_at, pass_took = 0, -math.huge, 0
  local mirror_cc, mirror_at, mirror_due, mirror_took = -1, -math.huge, false, 0
  local held, held_at, direct_in_at = false, nil, -math.huge
  local a, e, t, bg_at = 1, 1, 0, 0
  local got, waits = {}, {}
  while t < until_t do
    while o.edits and o.edits[e] and o.edits[e] <= t do cc = cc + 1; e = e + 1 end
    if cc ~= change_count then change_count, changed_at = cc, t end -- note_change
    local mouse = o.down and t >= o.down and t < o.up or false
    if arrivals[a] and arrivals[a] <= t then -- (direct.live_tick saw the file)
      if not held then held_at = t end
      held, last, direct_in_at = true, -math.huge, t
      a = a + 1
    end
    if o.bg and t - bg_at >= o.bg then bg_at = t; cc = cc + 1 end -- (StudioSync's own write in the tick, outside a pass)
    local quiet = sync.quiet_for(t, direct_in_at)
    if t - last > EVERY or sync.look_now(changed_at, polled_at, pass_took, t, mouse) or rules.receive_now(held, changed_at, quiet, polled_at, pass_took, t, mouse, false) then
      last, polled_at = t, t
      -- P.look
      local room = mirror_due or t - mirror_at > mirror_took * 5
      if room and (cc ~= mirror_cc or mirror_due or t - mirror_at > 10) and not mouse then
        cc = cc + (o.look_writes or 0)
        mirror_took, mirror_cc, mirror_at, mirror_due = took, cc, t, false
      end
      -- P.receive
      local busy
      busy, held_since = sync.editing_now(t, changed_at, held_since, quiet, mouse)
      if mirror_at > -math.huge and rules.seen_mine(cc, mirror_cc, t, mirror_at, changed_at) and not busy then
        if held then got[#got + 1] = t - held_at; cc = cc + 1; mirror_due = true end
        held = false
      end
      pass_took = took
    end
    change_count = cc -- took_in
    t = t + TICK
  end
  return got
end
local function stats(list)
  table.sort(list)
  local s = 0
  for _, x in ipairs(list) do s = s + x end
  return list[(#list + 1) // 2] or 0, list[#list] or 0, #list > 0 and s / #list or 0
end
-- arrivals a few seconds apart, at odd moments against the 2 s passes, while StudioSync writes something a few times a second
local arr = {}
for i = 1, 40 do arr[i] = 3 + i * 3.37 end
-- (a medium song: a look takes 0.3 s, so the next waits 1.5 s, its fifth of REAPER's time)
local b_med, b_max, b_avg = stats(receiver(old, arr, 150, { bg = 0.3, took = 0.3 }))
local a_med, a_max, a_avg = stats(receiver(new, arr, 150, { bg = 0.3, took = 0.3 }))
print(string.format("rt-look receive: idle receiver, StudioSync writing between passes: before median %.2f s, slowest %.2f s, average %.2f s; after median %.2f s, slowest %.2f s",
  b_med, b_max, b_avg, a_med, a_max))
assert(b_max > 1, "the old rules held some over a second (" .. b_max .. ")")
assert(a_max <= 0.1, "now: applied within 0.1 s of its tick (" .. a_max .. ")")
-- and with nothing else writing, as before
local q = receiver(new, arr, 150, {})
assert(select(2, stats(q)) <= TICK + 1e-9, "nothing else writing: the same tick")
-- the protections stay
-- (you edited 0.2 s before it arrived: it waits for the quiet window after your edit, 0.4 s, then goes at once)
local ed = receiver(new, { 5.0 }, 8, { edits = { 4.8 }, bg = 0.3 })
assert(#ed == 1 and ed[1] >= 4.8 + sync.QUIET_DIRECT - 5.0 - 1e-9 and ed[1] <= 4.8 + sync.QUIET_DIRECT - 5.0 + 0.15,
  "while you edit: after the 0.4 s window, then promptly (" .. tostring(ed[1]) .. ")")
-- (the mouse held from 4.9 to 6.0: nothing lands mid-drag; it goes just after the button's let go)
local md = receiver(new, { 5.0 }, 8, { down = 4.9, up = 6.0, bg = 0.3 })
assert(#md == 1 and md[1] >= 1.0 - 1e-9 and md[1] <= 1.0 + 0.15, "never mid-drag; just after the drop (" .. tostring(md[1]) .. ")")
-- (your edit after the last look: seen_mine still waits for a look to see it, which follows within the pass that's due)
assert(not sync.seen_mine(9, 8, 10, 9.5, 9.7), "your edit after the last look began: not seen yet")

-- ---- part 1b: the sender's look after an edit, with the cloud copy in some passes ----
-- (measured on Cross Test with the clocks lined up: the message at +0.21-0.24 s mostly, +0.65 s once. A pass that copies to Google Drive took
-- ~200 ms, and sync.look_now waits five times the last pass's time: the next edit's look waited up to 1 s. The copy's time is left out now.)
local function sender(edits, until_t, drive_in_pass, count_drive)
  local cc, change_count, changed_at = 0, -1, -math.huge
  local last, polled_at, pass_took, n = 0, -math.huge, 0, 0
  local e, t, out = 1, 0, {}
  while t < until_t do
    while edits[e] and edits[e] <= t do cc = cc + 1; e = e + 1 end
    if cc ~= change_count then change_count, changed_at = cc, t end
    if t - last > EVERY or sync.look_now(changed_at, polled_at, pass_took, t, false) then
      last, polled_at, n = t, t, n + 1
      if changed_at > (out.looked or -math.huge) and changed_at <= t then out[#out + 1] = t - changed_at; out.looked = t end
      local regular = not sync.look_now(changed_at, polled_at - 1, 0, t, false) -- (no edit waiting: the 2 s pass, which may copy to the cloud)
      local drive = regular and n % 2 == 0 and drive_in_pass or 0
      pass_took = 0.03 + (count_drive and drive or 0)
      cc = cc + 1
    end
    change_count = cc
    t = t + TICK
  end
  return out
end
local edits = {}
for i = 1, 30 do edits[i] = 1 + i * 2.13 end
local _, s_before = stats(sender(edits, 70, 0.2, true))
local _, s_after = stats(sender(edits, 70, 0.2, false))
print(string.format("rt-look send: edit -> its look with a 0.2 s cloud copy in some passes: slowest before %.2f s, after %.2f s", s_before, s_after))
assert(s_before > 0.5, "the copy's time held the look (" .. s_before .. ")")
assert(s_after <= sync.SETTLE + 0.1, "now the look goes ~0.1 s after the edit (" .. s_after .. ")")

-- ---- part 2: two computers, one Lua ----
local G = require("bigproject")
local opts_m = { tracks = 3, folders = 0, returns = 1, sends = 1, fx = 3, big_every = 0, items = 10, midi = 1, notes = 40, ccs = 10, env_points = 8, regions = 1, markers = 1 }
local FA = require("bigreaper").new(G.model(opts_m)) -- (the desktop)
local FB = require("bigreaper").new(G.model(opts_m)) -- (the laptop: the same project, as opened from the studio)
local files = {}
local band = require("band")
local proxy = setmetatable({}, { __index = band })
proxy.read_json = function(path) return files[path] end
proxy.write_json = function(path, v) files[path] = v; return true end
proxy.listing = function(dir)
  local out = {}
  for p in pairs(files) do local d, f = p:match("^(.*)/([^/]*)$"); if d == dir then out[#out + 1] = f end end
  return out
end
proxy.log = function() end
proxy.size = function() return 960044 end
proxy.copy_atomic = function() end
package.loaded.band = proxy
for _, F in ipairs({ FA, FB }) do rawset(F.reaper, "file_exists", function() return true end) end
local mirror = require("mirror")
sync = require("sync")
local A = { user = "James", root = "C:/fake/StudioSync" }
local B = { user = "Bee", root = "C:/fake/StudioSync" }
local song, room = "Cross", "main"
local yes = function() return true end
local function as(F) reaper = F.reaper end
-- the desktop's first look sends the project; the laptop takes it in
as(FA)
repeat FA.clock = FA.clock + 1 until mirror.watch(FA.proj, A, song, room, { can = yes, mode = "open", quick = true }) == 0 and not mirror.more
as(FB)
for _ = 1, 20 do FB.clock = FB.clock + 1; if sync.receive(FB.proj, B, song, room, yes) == 0 and not sync.backlog and not sync.read_cut then break end end
FB.clock = FB.clock + 70
mirror.watch(FB.proj, B, song, room, { can = yes, mode = "open", quick = true })
as(FA)
FA.clock = FA.clock + 70
mirror.watch(FA.proj, A, song, room, { can = yes, mode = "open", quick = true })
-- an envelope point set on the desktop in an undo block: out at its first look, as a file and as a message on each bandmate's lane
local direct = require("direct")
local sent_msgs = {}
direct.send_live = function(_, kind, d, s, r, id) sent_msgs[#sent_msgs + 1] = { kind = kind, d = d, song = s, room = r, id = id }; return true end
local t = FA.m.tracks[1]
t.volenv[3][2] = 0.6543; t.raw, t.chunk = nil, nil; FA.cc = FA.cc + 1
FA.clock = FA.clock + 0.1
assert(mirror.watch(FA.proj, A, song, room, { can = yes, mode = "open", quick = true }) == 1, "the desktop sent the point at its first look")
local msg
for _, m in ipairs(sent_msgs) do if m.kind == "event" then msg = m end end
assert(msg and msg.d.type == "obj" and msg.song == song and msg.room == room and msg.id == msg.d.id, "and as an \"event\" message, ahead of its file")
-- the laptop gets the message before Syncthing (or the link's file) brings the file: the file isn't in its folder yet
local dir = sync.room_dir(B, song, room) .. "/events"
files[dir .. "/" .. msg.id .. ".json"] = nil
-- (the link's inbox, as the extension keeps it)
direct.available, direct.live_available = function() return true end, function() return true end
direct.inbox = function() return "C:/fake/home/direct/STUDIO" end
proxy.files = function(d, ext)
  local out = {}
  for p in pairs(files) do local dd, f = p:match("^(.*)/([^/]*)$"); if dd == d and (not ext or f:sub(-#ext) == ext) then out[#out + 1] = f end end
  return out
end
as(FB)
rawset(FB.reaper, "file_exists", function(p) return files[p] ~= nil end)
-- (what the Live sync handler does with it: sync.take_event, then a pass at once)
local bad = { type = "obj", id = "../../evil" }
assert(not sync.take_event(B, song, room, bad), "a name with a path in it is refused")
assert(not sync.take_event(B, song, room, { type = "start", id = "x" }), "only object changes come this way")
assert(sync.take_event(B, song, room, msg.d), "the laptop takes the message into its link inbox")
assert(not sync.take_event(B, song, room, msg.d), "once")
FB.clock = FB.clock + 0.03
local t0 = os.clock()
local n = sync.receive(FB.proj, B, song, room, yes)
local ms = (os.clock() - t0) * 1000
assert(n == 1, "the laptop applied it in one receive, from the message (" .. tostring(n) .. ")")
assert(FB.track_chunk(FB.m.tracks[1]):find("0.6543", 1, true), "and the point is on the laptop's track")
print(string.format("rt-look receive: the laptop's sync.receive of one envelope point that came as a message: %.1f ms of Lua (a small song)", ms))
assert(ms < 50, "applying it is a few ms, not the wait")
-- the file arriving after (the link's copy, then Syncthing's) changes nothing
files[dir .. "/" .. msg.id .. ".json"] = msg.d
assert(sync.receive(FB.proj, B, song, room, yes) == 0, "its file coming after is already applied")
print("ok rt receive latency")
