-- rt-answers, item 4 (James, 2026-11-21): a band Play together honours REAPER's "Transport: Play (skip time selection)". A start made with
-- the skip carries the time selection ahead of it (`skip = { s, e }`, lib/together.lua start/skip_of); every computer, the leader's own
-- Live sync included, fires it as REAPER's own action over that selection (together.play), and one that starts late lands as far in as the
-- others have got by skipping it (together.plan). A bandmate's skip is checked as anything received is. Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local calls, sel, cursor, front = {}, { 0, 0 }, 0, "P"
local xs, playstate, playpos, now_p = {}, 0, 0, 100
reaper = setmetatable({
  GetExtState = function(s, k) return xs[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) xs[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) xs[s .. "/" .. k] = nil end,
  GetPlayStateEx = function() return playstate end,
  GetPlayPosition2Ex = function() return playpos end,
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
  time_precise = function() return now_p end,
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
assert(posted[4].skip and posted[4].skip[1] == 10, "(round 2) from inside the selection too: every computer runs REAPER's action from the same place")
together.start("P", { user = "James" }, { song = "S", room = "main" }, 20, false, 0, false, 0, true)
assert(posted[5].skip == nil, "a selection behind the start isn't skipped")
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

-- (round 2) from inside the selection: REAPER's own action from there, whatever it does there (the leader's did the same)
calls, sel, cursor = {}, { 10, 20 }, 12
assert(together.play("P", { skip = { 10, 20 } }) and calls[#calls] == "action 40317", "from inside the selection: REAPER's Play (skip time selection) too")

-- (round 2) this computer's own time selection comes back once the skip is behind the playhead, or playback stops
calls, sel, cursor, playstate, together.own = {}, { 1, 2 }, 4, 1, {}
together.play("P", { skip = { 10, 20 } })
playpos = 15
assert(not together.restore_own("P") and sel[1] == 10, "still before the skip's end: the leader's selection stays")
playpos = 20.2
assert(together.restore_own("P") and sel[1] == 1 and sel[2] == 2 and together.own.P == nil, "past it: your own selection (and so a linked loop) is back")
sel = { 1, 2 }
together.play("P", { skip = { 10, 20 } })
playstate, playpos = 0, 12
assert(together.restore_own("P") and sel[1] == 1, "stopped first: back then")
sel, playstate = { 1, 2 }, 1
together.play("P", { skip = { 10, 20 } })
sel, playpos = { 30, 40 }, 25
assert(not together.restore_own("P") and sel[1] == 30 and together.own.P == nil, "a selection you made meanwhile is yours: left")
sel = { 10, 20 }
together.play("P", { skip = { 10, 20 } })
assert(together.own.P == nil, "the leader's own selection is the skip: nothing to put back")
playstate = 0

-- (round 2) REAPER's own Play (skip time selection), noted by the extension (ExtState "play skip" = time_precise then)
sel, now_p = { 10, 20 }, 100
xs["BandSync/play skip"] = "99.5"
local k = together.pressed_skip("P", 4)
assert(k and k[1] == 10 and k[2] == 20 and xs["BandSync/play skip"] == nil, "pressed just now: the start carries the selection, and the note is taken")
assert(together.pressed_skip("P", 4) == nil, "once")
xs["BandSync/play skip"] = "97"
assert(together.pressed_skip("P", 4) == nil, "an old note isn't a press now")
xs["BandSync/play skip"], front = "99.5", "Q"
assert(together.pressed_skip("P", 4) == nil, "pressed in another tab: not this one's start")
front = "P"
xs["BandSync/play skip"], calls, cursor = "99.9", {}, 4
together.play("P", { skip = { 10, 20 } })
assert(xs["BandSync/play skip"] == nil, "a follower's own run of the action (which the extension notes too) isn't a press")
-- REAPER's jump over the selection isn't a seek for the others to follow
assert(together.skip_jump({ 10, 20 }, 10.08, 20.08), "the jump over the skip")
assert(not together.skip_jump({ 10, 20 }, 6, 30) and not together.skip_jump(nil, 10.08, 20.08) and not together.skip_jump({ 10, 20 }, 3, 13), "a seek is a seek")

-- (round 2) the extension notes 40317 without eating it, before its own action's check; ReaPersona's build leaves it out
local function src0(path) local fh = assert(io.open(path, "rb")); local s = fh:read("a"); fh:close(); return (s:gsub("\r", "")) end
local cpp = src0("extension/reaper_menu.cpp")
local hook = cpp:find("if (command == PLAY_SKIP_SEL) note_play_skip();", 1, true)
local own = cpp:find("if (!command || command != g_cmd) return false;", 1, true)
assert(cpp:find("PLAY_SKIP_SEL = 40317", 1, true) and hook and own and hook < own, "on_command notes 40317 first, and goes on to REAPER (not eaten)")
assert(cpp:find('SetExtState(SECTION, "play skip", at, false)', 1, true) and cpp:find("time_precise()", 1, true) and cpp:find("#define REAPERAPI_WANT_time_precise", 1, true),
  "as \"play skip\" = REAPER's time_precise, the clock Lua reads")
assert(cpp:find("#ifndef REAPERSONA\n  if (command == PLAY_SKIP_SEL)", 1, true), "(StudioSync's build only)")

-- wiring: Live sync fires every start's play through together.play; the panel's Play together asks for the skip
local function src(path) local fh = assert(io.open(path, "rb")); local s = fh:read("a"); fh:close(); return s end
local live = src("StudioSync - Live sync.lua")
assert(live:find("together.play(proj, transport)", 1, true), "Live sync starts a start's play through together.play")
assert(src("lib/page_play.lua"):find("play_along and lag_bars or 0, skip_sel)", 1, true), "the panel's Play together carries the skip when ticked")
assert(live:find("together.pressed_skip(proj, pos)", 1, true) and live:find("together.skip_jump(side.skip,", 1, true) and live:find("together.restore_own(proj)", 1, true)
  and live:find("if together.play(proj, transport) then side.skip = transport.skip end", 1, true),
  "(round 2) Live sync: a press of REAPER's own action carries the skip, its jump isn't a seek, your own selection comes back")
-- (round 2) the web UI's Play page and Song page ask for it too
assert(src("lib/webui/play.js"):find("skip: what === 'play' && skip.checked", 1, true) and src("lib/webpages.lua"):find("webpages.bars(a.lag) or 0, a.skip == true)", 1, true),
  "the Play page's box")
assert(src("lib/webui/daw.js"):find("act({ play: 'start', skip: q('.dskip input').checked })", 1, true) and src("lib/dawview.lua"):find("false, 1, true, 0, d.skip)", 1, true),
  "the Song page's box")
local dv = require("dawview")
assert(dv.parse({ play = "start", skip = true }).skip == true and dv.parse({ play = "start" }).skip == nil and dv.parse({ play = "stop", skip = true }).skip == nil
  and dv.parse({ play = "start", skip = "yes" }).skip == nil, "the Song page's skip: only true, only with a start")
print("ok rt-answers skip")
