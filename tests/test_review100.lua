-- 0.59.8 (lupa or Lua 5.4, from the repo root): Real time mode from its own flag; talk only while NINJAM has your playing.
package.path = "lib/?.lua;" .. package.path
local px, master_fx = {}, nil
local MASTER = {}
reaper = setmetatable({
  GetOS = function() return "Win64" end, time_precise = function() return 0 end,
  GetExtState = function() return "" end,
  GetProjExtState = function(_, _, k) return 1, px[k] or "" end,
  GetMasterTrack = function() return MASTER end,
}, { __index = function() return function() end end })
for _, m in ipairs({ "band", "live" }) do package.loaded[m] = nil end
local live = require("live")
live.fx = function(_, _, fx) if fx then return nil end; return master_fx, master_fx and 0 end
assert(not live.rt_flag(0), "nothing set: off")
px.side = "0"
assert(not live.rt_flag(0), "no flag: off, whatever the bars (Follow at 0 bars isn't Real time)")
px.rt = "0"
assert(not live.rt_flag(0), "its own flag wins: bars at 0 don't switch it on")
px.rt, px.side = "1", ""
assert(live.rt_flag(0), "Follow unticked doesn't switch it off")
px.rt = "0"
assert(not live.talk_only(0), "no call, no NINJAM: not talk only")
master_fx = MASTER
assert(live.ninjam_master(0) and live.talk_only(0), "NINJAM on the master has your playing: SonoBus carries only Talk")
px.rt = "1"
assert(not live.talk_only(0), "Real time mode: the full send")
master_fx = {}
px.rt = "0"
assert(not live.ninjam_master(0), "a ReaNINJAM elsewhere (the producer's) isn't Time-sync")
px["rt talk only"] = "1"
assert(live.talk_only(0), "the call on its own")
-- the restless plug-ins outlast a REAPER that didn't close cleanly (settings.json)
local kept = {}
for _, k in ipairs(require("band").kept_keys()) do kept[k] = true end
assert(kept["restless plugins"], "kept with the studios list")
print("ok")
