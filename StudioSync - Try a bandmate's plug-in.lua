-- @description StudioSync: try a bandmate's plug-in you don't have, live, on the selected track
-- Select a track (an instrument's MIDI, or the audio to put through an effect), run this, type part of a plug-in's name: the ones bandmates
-- here have and you don't are listed; pick one and a StudioSync Hop goes at the end of the track. Their StudioSync asks them first (it's their
-- computer and their licence); once they say yes you hear it through their REAPER, in time with the rest of the mix. Its knobs and Print are on
-- the web UI's Try tab. Run this again on the track to stop or print a try. Needs Live sync on both computers. (James, rt-hopvst)
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
if require("fromfolder").handoff(debug.getinfo(1, "S").source) then return end
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
if not b then return band.msg("This project isn't shared yet: share it, or open it from Projects in the StudioSync panel.") end
local cfg = band.for_tab(band.settings(), b)
local hops, hoptry = require("hops"), require("hoptry")
if not cfg then return end
if not hops.available() then return band.msg("This needs StudioSync's extension with live hops: Extensions > ReaPack > Synchronize packages, then restart REAPER.") end
local tr = reaper.GetSelectedTrack(proj, 0)
if not tr then return band.msg("Select a track first: the instrument's MIDI or the audio you want to put through the plug-in.") end
local oid = require("mirror").track_oid(tr)
local items, acts = {}, {}
for _, rec in pairs(hops.records(proj)) do
  if rec.try and rec.oid == oid then
    items[#items + 1] = "Print " .. rec.fx .. " (records it onto a new track)"; acts[#items] = function()
      local ok, why = hoptry.print(proj, cfg, rec.id)
      if not ok then band.msg("Not printed: " .. tostring(why) .. ".") end
    end
    items[#items + 1] = "Stop trying " .. rec.fx .. " on " .. tostring(rec.user) .. "'s computer"; acts[#items] = function() hops.stop(proj, cfg, rec.id) end
  end
end
items[#items + 1] = "Try another plug-in..."; acts[#items] = true
local pick = items[1]
if #items > 1 then pick = band.pick(items) end
for k, it in ipairs(items) do if pick == it and acts[k] ~= true then return acts[k]() end end
if pick ~= items[#items] then return end -- (closed the menu)
local ok, q = reaper.GetUserInputs("Try a bandmate's plug-in", 1, "Part of its name:,extrawidth=200", "")
if not ok then return end
local peer_of = hops.peers_by_user(cfg, b.song, b.room)
local here, plugins = {}, require("plugins")
for u in pairs(peer_of) do here[u] = true end
if not next(here) then return band.msg("No bandmate is on the link now (Live sync needs to be running on their computer too).") end
local mine = {}
for _, p in ipairs(plugins.installed()) do mine[plugins.key(p.name)] = true end
local found, n = hoptry.search(plugins.lists(cfg), here, mine, q, 25)
if #found == 0 then return band.msg("None of the bandmates here has a plug-in matching \"" .. q .. "\" that you don't have (by the lists StudioSync shares).") end
local menu = {}
for _, f in ipairs(found) do menu[#menu + 1] = f.key .. "  on " .. f.user .. "'s computer" end
if n > #found then menu[#menu + 1] = "#" .. (n - #found) .. " more: type more of the name" end
local chosen = band.pick(menu)
for k, f in ipairs(found) do
  if chosen == menu[k] then
    local id, why = hoptry.start(proj, cfg, b, tr, f.user, f.key)
    if not id then band.msg("Not tried: " .. tostring(why) .. ".") end
  end
end
