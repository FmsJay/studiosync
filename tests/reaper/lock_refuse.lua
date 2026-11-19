-- Run inside REAPER (ReaScript). 0.59.18-19: one REAPER per song and room on a computer. With another REAPER's fresh lock for the song,
-- Live sync doesn't start here, says why ("elsewhere <tab>" for Autostart), and writes nothing for the song first; a stale lock (a REAPER
-- that quit) and this REAPER's own don't stop it. The other REAPER is stood in for by its lock file. One scratch tab, closed at the end.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
local repo = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]")
package.path = repo .. "/lib/?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "json" }) do package.loaded[m] = nil end
local band = require("band")
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local song = "LockLab" .. os.time()
local lock = band.home() .. "/locks/" .. song .. " main.json"
local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
local opts = reaper.set_action_options
local ok, err = pcall(function()
  band.bind(pa, { song = song, room = "main", role = "host", root = D .. "/lockroot" })
  reaper.RecursiveCreateDirectory(band.home() .. "/locks", 0)
  local function run_live()
    reaper.set_action_options = nil -- (Live sync's own action options would land on the test runner's)
    reaper.DeleteExtState(band.SECTION, "elsewhere " .. tostring(pa), false)
    -- ("run from" cleared meanwhile, as tests/reaper/from_folder.lua does: on a computer that runs from a studio's folder, Live sync's first act
    -- handed over to that copy, which was already running for another tab, so this copy never reached its refusal. Round 2 review, 0.59.46)
    local run = reaper.GetExtState(band.SECTION, "run from")
    reaper.DeleteExtState(band.SECTION, "run from", true)
    local got, e = pcall(dofile, repo .. "/StudioSync - Live sync.lua")
    if run ~= "" then reaper.SetExtState(band.SECTION, "run from", run, true) end
    reaper.set_action_options = opts
    return got, e
  end
  -- another REAPER syncs it now
  band.write_json(lock, { instance = "another-reaper", at = os.time() })
  local got, e = run_live()
  check(got, "Live sync runs to its refusal without an error: " .. tostring(e))
  check(reaper.GetExtState(band.SECTION, "elsewhere " .. tostring(pa)) ~= "", "it refuses, and says so for Autostart")
  check(reaper.GetExtState(band.SECTION, "live owner " .. tostring(pa)) == "", "before taking the tab (nothing set up for the song)")
  check(reaper.GetExtState(band.SECTION, "live " .. tostring(pa)) == "", "and no Live sync heartbeat for it")
  local lk = band.read_json(lock)
  check(type(lk) == "table" and lk.instance == "another-reaper", "the other REAPER's lock is left as it was")
  -- the decision for a stale lock and for this REAPER's own, without starting a real Live sync on the scratch song (the same test as Live sync's)
  local mine = reaper.GetExtState(band.SECTION, "instance id")
  check(mine ~= "", "this REAPER has its own id for the session")
  local function refuses(l) return type(l) == "table" and l.instance ~= mine and tonumber(l.at) and os.time() - tonumber(l.at) < 20 end
  check(not refuses({ instance = "another-reaper", at = os.time() - 60 }), "a stale lock (a REAPER that quit a minute ago) doesn't stop it")
  check(not refuses({ instance = mine, at = os.time() }), "nor does this REAPER's own")
end)
if not ok then say("ERROR " .. tostring(err)); fails = fails + 1 end
reaper.set_action_options = opts
os.remove(lock)
for _, k in ipairs({ "elsewhere ", "live owner ", "live " }) do reaper.DeleteExtState(band.SECTION, k .. tostring(pa), false) end
if reaper.ValidatePtr2(0, pa, "ReaProject*") then
  reaper.SelectProjectInstance(pa)
  reaper.Main_SaveProjectEx(pa, D .. "/lock_refuse.rpp", 8)
  reaper.Main_OnCommand(40860, 0)
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")
