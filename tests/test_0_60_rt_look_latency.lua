-- How long from an edit to its event file, on a small project (3 tracks, 10 items, like Cross Test), through Live sync's pass cadence: a
-- pass every 2 s, a look 0.1 s after an edit settles (sync.look_now), and a pass the moment a settling chain or automation is due
-- (mirror.settle_due). An envelope point set from a script inside an undo block took 4.2 s on the desktop and LinuxBox (orchestrator, rt):
-- the look noted it, plug-ins and automation then had to hold still 3 s, and the look that sent it waited for the next 2 s pass. Now a change
-- that comes with an undo point goes at the first look, and one without (a knob from a control surface) goes SETTLE_SECS after it stops.
-- The old rules are run too, so the before figure is printed beside the after. rt-look
package.path = "tools/?.lua;lib/?.lua;tests/fixtures/?.lua;" .. package.path
local G = require("bigproject")
local m = G.model({ tracks = 3, folders = 0, returns = 1, sends = 1, fx = 3, big_every = 0, items = 10, midi = 1, notes = 40, ccs = 10, env_points = 8, regions = 1, markers = 1 })
local F = require("bigreaper").new(m)
reaper = F.reaper
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
rawset(reaper, "file_exists", function() return true end)
rawset(reaper, "TrackFX_GetParamNormalized", function(t, i, p)
  local fx, k = t.fx and t.fx[i + 1], 0
  for x in ((fx and fx.params) or ""):gmatch("%S+") do if k == p then return (tonumber(x) or 50) / 100 end; k = k + 1 end
  return 0.5
end)
package.loaded.band = proxy
local mirror = require("mirror")
local sync = require("sync")
local cfg = { user = "James", root = "C:/fake/StudioSync" }
local b = { song = "Cross", room = "main" }
local opts = { can = function() return true end, mode = "open", quick = true }

-- Live sync's tick, as far as when it looks goes (StudioSync - Live sync.lua: tick and P.look). `old`: the rules before (3 s settling, no pass
-- when it's due, no going at once after an undo point).
local every, TICK = 2, 1 / 30
local S = { last = -math.huge, polled_at = -math.huge, pass_took = 0, changed_at = -math.huge, change_count = -1, mirror_cc = -1, mirror_at = -math.huge, due = false }
local function tick(old)
  local now = F.clock
  if F.cc ~= S.change_count then S.change_count, S.changed_at = F.cc, now end
  if now - S.last > every or sync.look_now(S.changed_at, S.polled_at, S.pass_took, now, false) then
    S.last, S.polled_at = now, now
    local waiting = now - S.mirror_at > 1 and mirror.unsettled
    if F.cc ~= S.mirror_cc or S.due or waiting or now - S.mirror_at > 10 then
      if old then mirror.look_cc = {} end -- (no change count kept: nothing goes at once)
      mirror.watch(F.proj, cfg, b.song, b.room, opts)
      S.mirror_cc, S.mirror_at, S.due = F.cc, now, false
    end
    if mirror.more then S.due = true end
    if not old and mirror.settle_due then S.due = true; S.last = math.min(S.last, mirror.settle_due - every) end
  end
  F.clock = F.clock + TICK
end
local function events()
  local n = 0
  for p in pairs(files) do if p:find("/events/", 1, true) then n = n + 1 end end
  return n
end
-- Seconds from `edit()` to its event file.
local function time_to_event(edit, old)
  for _ = 1, 30 * 12 do tick(old) end -- (quiet first: the last pass and its settling done)
  local n0, t0 = events(), F.clock
  edit()
  while events() == n0 and F.clock - t0 < 30 do tick(old) end
  return F.clock - t0
end

for _ = 1, 30 * 80 do tick() end -- (the first look, and past the plug-ins' loading minute)
local t = m.tracks[1]
local function env_edit() t.volenv[3][2] = t.volenv[3][2] + 0.05; t.raw, t.chunk = nil, nil; F.cc = F.cc + 1 end -- (SetEnvelopePoint in an undo block)
local function knob_edit() t.fx[1].params = t.fx[1].params:gsub("^%S+", tostring(math.random(1, 999) / 100)); t.raw, t.chunk = nil, nil end -- (no undo point)
local function item_edit() local it = m.tracks[2].items[1] or t.items[1]; F.move(it, 0.01) end

local mirror_settle = mirror.SETTLE_SECS
mirror.SETTLE_SECS = 3
local before = time_to_event(env_edit, true)
mirror.SETTLE_SECS = mirror_settle
local after = time_to_event(env_edit)
local knob = time_to_event(knob_edit)
local item = time_to_event(item_edit)
print(string.format("rt-look latency: envelope point (undo block) before %.2f s, after %.2f s; knob with no undo point %.2f s (after the look that sees it); item moved %.2f s",
  before, after, knob, item))
assert(before > 3.5, "the old rules: about 4 s, as measured in REAPER (" .. before .. ")")
assert(after <= 0.3, "an envelope point set in an undo block: its event within 0.3 s (" .. after .. ")")
assert(item <= 0.3, "an item moved: its event within 0.3 s (" .. item .. ")")
-- (a knob with no undo point moves no change count, so Live sync sees it at its 10 s look; from that look it goes SETTLE_SECS later)
assert(knob <= 10 + mirror.SETTLE_SECS + 0.5, "a knob with no undo point: by the 10 s look plus settling (" .. knob .. ")")
print("ok rt look latency")
