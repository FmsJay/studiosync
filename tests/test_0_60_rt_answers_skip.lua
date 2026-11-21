-- rt-answers, item 4 (James, 2026-11-21): a band Play together honours REAPER's "Transport: Play (skip time selection)". A start made with
-- the skip carries the time selection ahead of it (`skip = { s, e }`, lib/together.lua start/skip_of); every computer, the leader's own
-- Live sync included, fires it as REAPER's own action over that selection (together.play), and one that starts late lands as far in as the
-- others have got by skipping it (together.plan). A bandmate's skip is checked as anything received is. Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local calls, sel, cursor, front = {}, { 0, 0 }, 0, "P"
reaper = setmetatable({
  GetSet_LoopTimeRange2 = function(_, set, loop, s, e)
    if loop then return 0, 0 end
    if set then sel = { s, e }; calls[#calls + 1] = "sel " .. s .. "-" .. e end
    return sel[1], sel[2]
  end,
  GetCursorPositionEx = function() return cursor end,
  EnumProjects = function() return front end,
  Main_OnCommandEx = function(id) calls[#calls + 1] = "action " .. id end,
  OnPlayButtonEx = function() calls[#calls + 1] = "play" end,
  TimeMap_GetTimeSigAtTime = function() return 4, 4 end,
  TimeMap2_timeToQN = function(_, t) return t * 2 end,
  TimeMap2_QNToTime = function(_, q) return q / 2 end,
  time_precise = function() return 100 end,
}, { __index = function() return function() return 0 end end })
local band = require("band")
local logged, posted, ext = {}, {}, nil
band.log = function(t) logged[#logged + 1] = t end
band.set_ext_json = function(_, _, v) ext = v end
package.loaded.sync = { post = function(_, _, _, ev) posted[#posted + 1] = ev end }
package.loaded.direct = { shared_now = function() return nil end }
local together = require("together")

-- the start: the time selection ahead of the start position, only when asked and only for playing
sel = { 10, 20 }
together.start("P", { user = "James" }, { song = "S", room = "main" }, 4, false, 0, false, 0, true)
assert(posted[1].skip and posted[1].skip[1] == 10 and posted[1].skip[2] == 20 and ext.skip, "Play together with the skip carries the time selection")
together.start("P", { user = "James" }, { song = "S", room = "main" }, 4, false, 0, false, 0, false)
assert(posted[2].skip == nil, "without it, nothing")
together.start("P", { user = "James" }, { song = "S", room = "main" }, 4, true, 0, false, 0, true)
assert(posted[3].skip == nil, "a recording doesn't skip")
together.start("P", { user = "James" }, { song = "S", room = "main" }, 12, false, 0, false, 0, true)
assert(posted[4].skip == nil, "a selection that isn't ahead of the start isn't skipped")
sel = { 0, 0 }
assert(together.skip_of("P", 4) == false, "no time selection: nothing to skip")

-- a bandmate's skip, as received: only two numbers, in order
assert(together.skip_range({ skip = { 10, 20 } }) == 10, "a skip")
for _, bad in ipairs({ { "10", "x" }, { 20, 10 }, { -1, 5 }, { 1, 1e9 }, "10-20" }) do
  assert(together.skip_range({ skip = bad }) == nil, "a skip that doesn't make sense is ignored")
end

-- a late start lands as far in as the others have got by skipping
local ev = { at = 1000, pos = 4, countin = 0, skip = { 10, 20 } }
local fire, from = together.plan(ev, "Bee", nil)
assert(fire == 1000 and from == 4, "on time: from the start")
fire, from = together.plan(ev, "Bee", 1003)
assert(from == 7, "late, still before the selection: as far as time has gone")
fire, from = together.plan(ev, "Bee", 1008)
assert(from == 22, "late past the selection's start: past the selection, where the others are (" .. from .. ")")
fire, from = together.plan({ at = 1000, pos = 4, countin = 0 }, "Bee", 1008)
assert(from == 12, "(without a skip, as before)")

-- fired here: REAPER's own Play (skip time selection) over the leader's selection
calls, sel, cursor = {}, { 0, 0 }, 4
assert(together.play("P", { skip = { 10, 20 } }) and calls[1] == "sel 10-20" and calls[2] == "action 40317" and #calls == 2,
  "a start with a skip plays as REAPER's Play (skip time selection) over the same selection (" .. table.concat(calls, ", ") .. ")")
calls = {}
assert(not together.play("P", {}) and calls[1] == "play" and #calls == 1, "without one, Play as before")
calls, cursor = {}, 22
assert(not together.play("P", { skip = { 10, 20 } }) and calls[1] == "play", "from past the selection (a late start): Play")
calls, cursor = {}, 4
assert(not together.play("P", { skip = { 10, 20 }, rec = true }) and calls[1] == "play", "(a recording never skips)")
calls, front = {}, "Q"
assert(not together.play("P", { skip = { 10, 20 } }) and calls[1] == "play" and logged[#logged]:find("isn't in front", 1, true),
  "a tab that isn't in front plays through it, and says so (REAPER's actions go to the tab in front)")
front = "P"

-- wiring: Live sync fires every start's play through together.play; the panel's Play together asks for the skip
local function src(path) local fh = assert(io.open(path, "rb")); local s = fh:read("a"); fh:close(); return s end
local live = src("StudioSync - Live sync.lua")
assert(live:find("together.play(proj, transport)", 1, true), "Live sync starts a start's play through together.play")
assert(src("lib/page_play.lua"):find("play_along and lag_bars or 0, skip_sel)", 1, true), "the panel's Play together carries the skip when ticked")
print("ok rt-answers skip")
