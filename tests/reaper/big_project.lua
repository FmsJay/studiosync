-- Run inside REAPER (ReaScript). The big test project and its measurements (bigger projects, James, rt; docs/rt/rt-bigproj.md):
--   1st run, with no big test project in front: writes tools/bigproject.lua's project (150 tracks in folders with sends, 520 plug-ins, 4,000
--      items over 7 minutes, 60 MIDI items with 72,000 notes, automation, 50 regions) to <REAPER resource folder>/StudioSync/tests/bigproject,
--      with the one silent WAV its audio items play, and opens it in a new tab. REAPER lists the 130 "StudioSync Big State Test" plug-ins as
--      missing (stand-ins that keep a 16 KB saved state each, as a big synth's would): close that list, it keeps their data. Set BIG_FX = false
--      below for stock plug-ins only.
--   Run again with that tab in front: times what REAPER itself does for StudioSync at this size (every track's and item's chunk, the reads
--      the Project page and the Mixer make, mirror.root, colour parity) and prints it. Reads only: nothing in the project changes.
-- Live sync on it (publish it into a test studio first) is measured with tests/reaper/rt_perf.lua, as that script says.
local BIG_FX = true
local root = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]")
package.path = root .. "/tools/?.lua;" .. root .. "/lib/?.lua;" .. package.path
local G = require("bigproject")
local dir = reaper.GetResourcePath() .. "/StudioSync/tests/bigproject"
local path = dir .. "/StudioSync Big Test.rpp"
local proj, fn = reaper.EnumProjects(-1)
local out = {}
local function say(s) out[#out + 1] = s end
local function finish(s) reaper.ShowConsoleMsg(s .. "\n"); return s end

if not (fn or ""):find("StudioSync Big Test", 1, true) then
  reaper.RecursiveCreateDirectory(dir, 0)
  local m = G.model(BIG_FX and {} or { big_every = 0 })
  local t0 = reaper.time_precise()
  local text = G.rpp(m)
  local f = assert(io.open(path, "wb")); f:write(text); f:close()
  local w = assert(io.open(dir .. "/" .. m.opts.wav, "wb")); w:write(G.wav(m.opts.wav_secs)); w:close()
  local s = G.stats(m)
  reaper.Main_OnCommand(40859, 0) -- File: New project tab
  reaper.Main_openProject(path)
  return finish(string.format("Wrote %s (%.1f MB: %d tracks, %d plug-ins, %d items, %d MIDI, %d notes) in %.1f s and opened it in a new tab.\n" ..
    "Run this again with that tab in front to measure.", path, #text / 1048576, s.tracks, s.fx, s.items, s.midi, s.notes, reaper.time_precise() - t0))
end

local function time(n, fn)
  local t0 = reaper.time_precise()
  for _ = 1, n do fn() end
  return (reaper.time_precise() - t0) / n * 1000
end
say(string.format("%s: %d tracks, %d items", fn, reaper.CountTracks(proj), reaper.CountMediaItems(proj)))
-- what a look asks REAPER for: every track's chunk (its plug-ins' saved states included) and, for a changed track, its items' chunks
local bytes, worst, worst_name = 0, 0, ""
local t_tracks = time(1, function()
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local t0 = reaper.time_precise()
    local _, c = reaper.GetTrackStateChunk(tr, "", false)
    local dt = reaper.time_precise() - t0
    bytes = bytes + #c
    if dt > worst then worst, worst_name = dt, select(2, reaper.GetTrackName(tr)) end
  end
end)
say(string.format("  every track's chunk (a look asks for all of them): %.0f ms, %.1f MB; slowest track %s %.1f ms", t_tracks, bytes / 1048576, worst_name, worst * 1000))
local ibytes = 0
local t_items = time(1, function()
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local _, c = reaper.GetItemStateChunk(reaper.GetMediaItem(proj, i), "", false)
    ibytes = ibytes + #c
  end
end)
say(string.format("  every item's chunk (the first look, or a look after many tracks changed): %.0f ms, %.1f MB", t_items, ibytes / 1048576))
local t_cc = time(1000, function() reaper.GetProjectStateChangeCount(proj) end)
say(string.format("  GetProjectStateChangeCount (each tick): %.4f ms", t_cc))
local t_vals = time(5, function()
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    reaper.GetMediaTrackInfo_Value(tr, "D_VOL"); reaper.GetMediaTrackInfo_Value(tr, "D_PAN"); reaper.GetMediaTrackInfo_Value(tr, "B_MUTE")
  end
end)
say(string.format("  every track's fader, pan and mute (controllers, twice a tick with a bandmate here): %.2f ms", t_vals))
local mods = {}
for _, name in ipairs({ "mirror", "dawview", "webmixer", "colours" }) do local ok, mod = pcall(require, name); mods[name] = ok and mod or nil end
if mods.mirror then
  say(string.format("  mirror.root (each pass; EnumProjExtState over every object Live sync has recorded): %.1f ms", time(5, function() mods.mirror.root(proj) end)))
end
if mods.dawview then
  local n = 0
  local function look() local raw = mods.dawview.read(proj, "t/main", reaper.time_precise(), reaper.time_precise() + 10); n = #raw.tracks end
  local first = time(1, look)
  say(string.format("  the Project page's look, whole (now spread over ticks at %.0f ms a tick): first %.0f ms (peaks read), then %.0f ms, %d tracks",
    mods.dawview.SLICE * 1000, first, time(3, look), n))
end
if mods.webmixer then
  say(string.format("  the Mixer page's strips (every 0.25 s while it's open): %.1f ms", time(5, function() mods.webmixer.read(proj, nil) end)))
end
if mods.colours then
  mods.colours.LOOK_EVERY = 0
  say(string.format("  colour parity's look (every 5 s, in a pass): %.1f ms", time(3, function() mods.colours.look(proj) end)))
end
collectgarbage()
say(string.format("  this script's Lua memory: %.0f MB", collectgarbage("count") / 1024))
return finish(table.concat(out, "\n"))
