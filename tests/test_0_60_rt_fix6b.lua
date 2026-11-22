-- rt-fix6b (2026-11-21), from rt-r1's REAPER re-check: a pause then a stop on the leader passed on (rt-answers check 9); Record together
-- with REAPER's record pre-roll on the computer that records (check 10: it ran a bar behind the others); Syncthing 1.27's missing
-- fswatcher-timeouts skipped quietly and a set that timed out tried again later (rt-linkmove check E, rt-lab); "live audio didn't start"
-- said once, then on change, and kept for Health (rt-lab: every 10 s on LinuxBox2). The audio fixes are in tests/rtaudio_test.cpp
-- (clock_tests' stalls, rate_test) and tools/ears/test_ears.py (speed, a silent tap). Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local gext, toggles, cfgvars, exists, scripts, logged = {}, {}, {}, { ["/usr/bin/syncthing"] = true }, {}, {}
reaper = setmetatable({
  GetOS = function() return "Other" end,
  time_precise = function() return 100 end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  DeleteExtState = function(s, k) gext[s .. "\0" .. k] = nil end,
  file_exists = function(p) return exists[p] == true end,
  GetResourcePath = function() return "/home/studio/REAPER" end,
  GetToggleCommandStateEx = function(sec, id) return sec == 0 and (toggles[id] or 0) or -1 end,
  get_config_var_string = function(name) if cfgvars[name] then return true, cfgvars[name] end return false, "" end,
  TimeMap_GetTimeSigAtTime = function() return 4, 4 end,
  TimeMap2_timeToQN = function(_, t) return t * 130 / 60 end, -- (130 bpm, as the check's song)
  TimeMap2_QNToTime = function(_, q) return q * 60 / 130 end,
}, { __index = function() return function() end end })
local band = require("band")
band.write_atomic = function(path, text) scripts[path] = text; return true end
band.bands = function() return {} end
band.log = function(t) logged[#logged + 1] = t end
local together = require("together")
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end
local live = read("StudioSync - Live sync.lua")

-- 1. a pause then a stop: both pressed on to the followers (play state 1 -> 2 -> 0; "playing" is false in both of the last two)
assert(together.side_press(false, true, true, false, false), "a pause (playing -> paused) goes out")
assert(together.side_press(false, false, false, true, false), "the stop after a pause (paused -> stopped) goes out too (it went nowhere)")
assert(not together.side_press(false, false, false, false, false), "stopped and still stopped: nothing")
assert(not together.side_press(true, false, true, false, false), "playing on: nothing")
assert(together.side_press(true, false, true, false, true), "a seek while playing goes out")
assert(together.side_press(true, false, false, true, false), "playing again from a pause goes out (a start)")
assert(live:find("together.side_press(playing, ps & 2 == 2, side.playing, side.paused, jumped)", 1, true), "Live sync asks side_press with the pause state")
assert(live:find("side.playing, side.pos, side.t, side.paused = playing, pos, tp, ps & 2 == 2", 1, true), "and keeps the pause state each pass")
assert(live:find("pos = side.paused and side.pos or", 1, true), "a stop from a pause goes out where the song stayed, so a paused follower reaches it")

-- 2. Record together with this computer's record pre-roll: it presses Record that much sooner, so its playhead is at the start when the others' are
assert(together.preroll("P", 10) == 0, "pre-roll on record off: nothing")
toggles[41819], cfgvars.prerollmeas = 1, "1.00000000"
local pre = together.preroll("P", 10)
assert(math.abs(pre - 4 * 60 / 130) < 1e-9, "one bar of 4/4 at 130 bpm: 1.846 s (rt-r1: the desktop's Record started at -1.856 s): " .. pre)
cfgvars.prerollmeas = "2"
assert(math.abs(together.preroll("P", 10) - 2 * pre) < 1e-9, "two bars: twice that")
cfgvars.prerollmeas = nil
assert(together.preroll("P", 10) == 0, "unreadable: nothing (never a guess)")
local ev = { at = 1000, pos = 4, countin = 0, rec = true }
local fire, from = together.plan(ev, "James", nil)
assert(fire == 1000 and from == 4, "no pre-roll: at the planned moment")
ev.pre = pre
fire, from = together.plan(ev, "James", nil)
assert(math.abs(fire - (1000 - pre)) < 1e-9 and from == 4, "with it: that much sooner, from the same place (REAPER plays the pre-roll first)")
fire, from = together.plan(ev, "James", 1000 - pre + 0.25)
assert(math.abs(from - 4.25) < 1e-9, "late by 0.25 s: from 0.25 s further in, as the others are")
assert(live:find("transport.pre = transport.rec and not (transport.follow and theirs) and together.armed(proj) and together.preroll(proj,", 1, true),
  "Live sync sets the pre-roll only where it presses Record itself (not a play-along follower, not one with nothing armed)")

-- 3. Syncthing 1.27 has no fswatcher-timeouts ("No help topic", exit 3): skipped quietly, the rest (versioning: staggered) still done
local services = require("services")
assert(services.no_such_setting("3\nNo help topic for 'fswatcher-timeouts'\n", "fswatcher-timeouts"), "Syncthing 1.27's answer: no such setting")
assert(not services.no_such_setting("3\nNo help topic for 'studiosync-x'\n", "fswatcher-timeouts"), "a missing folder isn't (it names the folder)")
assert(not services.no_such_setting("-1005", "fswatcher-delays") and not services.no_such_setting(nil, "x"), "a timeout isn't")
local ask = services.TMP .. "/bandsync-ask.sh"
local answers, sets = {}, {}
reaper.ExecProcess = function()
  local body = scripts[ask] or ""
  for k, v in pairs(answers) do if body:find(" " .. k .. "\n", 1, true) then return v end end
  if body:find(" set ", 1, true) then sets[#sets + 1] = body:match("config folders %S+ (.-)\n") end
  return "0\n"
end
answers = { ["fswatcher-enabled get"] = "0\ntrue\n", ["fswatcher-delays get"] = "0\n1\n", ["fswatcher-timeouts get"] = "3\nNo help topic for 'fswatcher-timeouts'\n",
  ["versioning type get"] = "0\n\n", ["label get"] = "0\nStudioSync Smiley Studios\n" }
local set, err = services.tune_band_folder("studiosync-smiley-studios-a963")
assert(set, "tuned on Syncthing 1.27 (it said: " .. tostring(err) .. ")")
local joined = table.concat(set, ", ")
assert(joined:find("versioning none -> staggered", 1, true), "the steps after it ran (versioning was never set on LinuxBox): " .. joined)
assert(not joined:find("timeouts", 1, true), "the missing setting isn't reported as set")
-- LinuxBox2's first tune: the set timed out (-1005): "didn't answer", so Live sync tries again later, further apart each time
answers["fswatcher-delays get"], answers["fswatcher-delays set 1"] = "0\n0\n", "-1005"
set, err = services.tune_band_folder("studiosync-smiley-studios-a963")
assert(not set and err:find("didn't answer", 1, true), "a set that timed out: tried again later, not \"couldn't set\": " .. tostring(err))
answers["fswatcher-delays set 1"] = "1\nsome refusal\n"
set, err = services.tune_band_folder("studiosync-smiley-studios-a963")
assert(not set and err:find("couldn't set fswatcher-delays: some refusal", 1, true), "a real refusal still says why: " .. tostring(err))
assert(live:find("math.min(300, 30 * 2 ^ (10 - tune_left))", 1, true), "Live sync's retries back off: 30 s, then further apart (each can hold REAPER 8 s)")

-- 4. "live audio didn't start": once, then only when the reason changes; Health shows it
local la = require("liveaudio")
assert(la.fail_new("Tailscale isn't up here (no 100.64.0.0/10 address)"), "the first failure is said")
assert(not la.fail_new("Tailscale isn't up here (no 100.64.0.0/10 address)"), "the same again every 10 s: not")
assert(la.fail_new("couldn't bind"), "a different reason: said")
local src = read("lib/liveaudio.lua")
assert(src:find('if liveaudio.fail_new(why) then band.log("live audio didn\'t start: " .. why) end', 1, true), "the start's failure goes through fail_new")
assert(src:find('if err == "" and S.fail_why then err = "didn\'t start: " .. S.fail_why end', 1, true), "Health's row shows the last failed start")
assert(src:find("S.fail_why = nil -- (started", 1, true), "a start that works clears it, so the next failure is said again")

print("ok rt-fix6b pause then stop, record pre-roll, Syncthing 1.27, live audio's start failure")
