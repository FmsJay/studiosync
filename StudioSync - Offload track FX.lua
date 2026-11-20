-- @description StudioSync: offload the selected track's FX to an idle bandmate's computer (Shared CPU), or bring them back
-- Select a track, then run this: its effects run on whichever bandmate's computer has the most headroom now (never one recording, or a
-- guest's), through a StudioSync Hop at the end of its chain, in time with the rest of the mix; its own chain is held off here, only here.
-- Run it again on the same track to bring them back. They also come back by themselves when that computer starts recording, goes away or
-- falls behind, and when Live sync stops. Not the master. Needs Live sync on both computers. (James, rt: docs/realtime-roadmap.md "Shared CPU")
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
if require("fromfolder").handoff(debug.getinfo(1, "S").source) then return end
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
if not b then return band.msg("This project isn't shared yet: share it, or open it from Projects in the StudioSync panel.") end
local cfg = band.for_tab(band.settings(), b)
local tr = reaper.GetSelectedTrack(proj, 0)
if not cfg or not tr then return band.msg("Select a track first (click its name), then run this again.") end
local said = require("hops").offload_toggle(proj, cfg, b, tr)
if said then band.msg(said) end
