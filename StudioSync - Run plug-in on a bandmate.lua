-- @description StudioSync: run the focused plug-in on a bandmate's computer (a live hop)
-- Click a plug-in's window (one you don't have here, shown offline), then run this: "Run this plug-in on Bo's computer" puts a StudioSync
-- Hop right after it on your track and asks Bo's StudioSync to host it; you hear it through Bo's REAPER, in time with the rest of the mix.
-- Run it again on the same plug-in to stop. Bind it to a key or put it in REAPER's FX chain menu (Options > Customize menus/toolbars).
-- Needs Live sync running on both computers. (James, rt: docs/realtime-roadmap.md 4b)
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
if require("fromfolder").handoff(debug.getinfo(1, "S").source) then return end
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
if not b then return band.msg("This project isn't shared yet: share it, or open it from Projects in the StudioSync panel.") end
local cfg = band.for_tab(band.settings(), b)
local got, trn, _, fx = reaper.GetFocusedFX2()
if not cfg or (got or 0) & 1 == 0 or trn == 0 then return band.msg("Click the window of a plug-in on a track first, then run this again.") end
local tr = reaper.GetTrack(proj, trn - 1)
local hops = require("hops")
if not hops.available() then return band.msg("This needs StudioSync's extension with live hops: Extensions > ReaPack > Synchronize packages, then restart REAPER.") end
local rec = hops.of_fx(proj, tr, fx)
if rec then
  if band.pick({ "Stop running it on " .. tostring(rec.user) .. "'s computer" }) then hops.stop(proj, cfg, rec.id) end
  return
end
local ok, name = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_name")
if not ok or name == "" then name = select(2, reaper.TrackFX_GetFXName(tr, fx, "")) end
local short = name:gsub("^%w+:%s*", "")
local list = hops.candidates(cfg, name, b.song, b.room)
if #list == 0 then return band.msg("Nobody here now has " .. short .. " (by the plug-in lists StudioSync shares). Live sync needs to be running on their computer too.") end
local items = {}
for _, c in ipairs(list) do items[#items + 1] = "Run " .. short .. " on " .. c.user .. "'s computer" end
local pick = band.pick(items)
for k, c in ipairs(list) do
  if pick == items[k] then
    local id, why = hops.make(proj, cfg, tr, fx, c.user, c.peer, b.song, b.room)
    if not id then band.msg("The hop wasn't made: " .. tostring(why) .. ".") end
  end
end
