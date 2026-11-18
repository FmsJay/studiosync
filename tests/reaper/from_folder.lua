-- Run inside REAPER (ReaScript). 0.59.24: updates through the studio's folder (lib/fromfolder.lua). A script run from a copy this computer
-- moved away from starts the same script in the copy it runs from now ("run from"), and stops; the copy it runs from, and a git checkout,
-- run themselves. Scratch folders only; "run from" put back as it was.
local D = reaper.GetResourcePath() .. "/StudioSync/tests/fromfolder_" .. os.time()
local repo = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]")
package.path = repo .. "/lib/?.lua;" .. package.path
for _, m in ipairs({ "band", "fromfolder", "json" }) do package.loaded[m] = nil end
local band, ff = require("band"), require("fromfolder")
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local was = reaper.GetExtState(band.SECTION, "run from")
local ok, err = pcall(function()
  check(ff.at_least("0.59.24", "0.59.9") and ff.at_least("0.59.24", "0.59.24") and not ff.at_least("0.59.9", "0.59.24") and ff.at_least("1.0", "0.99.99"),
    "versions compare as numbers")
  local new, old, dev = D .. "/studio/_tools/studiosync", D .. "/old copy", D .. "/dev copy"
  for _, d in ipairs({ new, old, dev .. "/.git" }) do reaper.RecursiveCreateDirectory(d, 0) end
  band.write_atomic(dev .. "/.git/HEAD", "ref: refs/heads/main\n")
  band.write_atomic(new .. "/StudioSync - Probe.lua", 'reaper.SetExtState("BandSync", "probe ran", "new", false)\n')
  reaper.DeleteExtState(band.SECTION, "probe ran", false)
  reaper.SetExtState(band.SECTION, "run from", new, true)
  check(ff.handoff("@" .. old .. "/StudioSync - Probe.lua") == true, "an old copy's script hands over")
  check(reaper.GetExtState(band.SECTION, "probe ran") == "new", "and the copy it runs from now ran the same script")
  check(ff.handoff("@" .. new .. "/StudioSync - Probe.lua") == false, "the copy it runs from runs itself")
  check(ff.handoff("@" .. dev .. "/StudioSync - Probe.lua") == false, "so does a git checkout (a developer's)")
  check(ff.handoff("@" .. old .. "/StudioSync - Missing.lua") == false, "a script the folder's copy hasn't got runs where it is")
  check(ff.handoff("@" .. old .. "/StudioSync tabs/StudioSync - Live sync (2).lua") == false, "a tab's own Live sync copy runs where it is")
  reaper.DeleteExtState(band.SECTION, "run from", true)
  check(ff.handoff("@" .. old .. "/StudioSync - Probe.lua") == false, "nothing to hand over to: runs where it is")
  -- the script's action, registered for the probe, taken out again
  reaper.AddRemoveReaScript(false, 0, new .. "/StudioSync - Probe.lua", true)
end)
if not ok then out[#out + 1] = "ERROR " .. tostring(err); fails = fails + 1 end
if was == "" then reaper.DeleteExtState(band.SECTION, "run from", true) else reaper.SetExtState(band.SECTION, "run from", was, true) end
reaper.DeleteExtState(band.SECTION, "probe ran", false)
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")
