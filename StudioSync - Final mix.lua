-- @description StudioSync: render the current mix into the song's shared folder (mixes/), for everyone
-- Renders the whole project's master mix as this person hears it (their master is their own), with this project's own render
-- format (File > Render sets it) to <shared folder>/<Song>/mixes/<Song> <date> <you>, which reaches every bandmate like any
-- file in the folder, and to <Drive>/<Song>/mixes where this person uses Drive (named for them: each machine writes only its own there).
-- Only the band's mix: StudioSync's own tracks (the Real time return, live placeholders) and tracks kept as yours are
-- muted for the render and put back after, and the render isn't added to the project (it would go to the band as
-- a new item). Your render settings are put back as they were.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band, mirror = require("band"), require("mirror")
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
if not b then return band.msg("This project isn't a studio project: open the studio's project first (StudioSync panel).") end
local cfg = band.settings()
if not cfg then return end
if reaper.GetPlayStateEx(proj) & 4 == 4 then return band.msg("Stop recording first.") end

local out = band.song_dir(cfg, b.song) .. "/mixes"
reaper.RecursiveCreateDirectory(out, 0)
local name = band.clean(string.format("%s %s %s", b.song, os.date("%Y-%m-%d %H%M%S"), cfg.user)) -- (to the second: a second render in the same minute wrote over the first, which then didn't count as new. 0.58.93)

local extras = require("extras")
local saved = extras.save_render(proj)
local muted = {}
for i = 0, reaper.CountTracks(proj) - 1 do
  local tr = reaper.GetTrack(proj, i)
  if mirror.local_track(tr) and reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") == 0 then
    reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1); muted[#muted + 1] = tr
  end
end

reaper.GetSetProjectInfo_String(proj, "RENDER_FILE", out, true)
reaper.GetSetProjectInfo_String(proj, "RENDER_PATTERN", name, true)
reaper.GetSetProjectInfo(proj, "RENDER_SETTINGS", 0, true) -- the master mix
reaper.GetSetProjectInfo(proj, "RENDER_BOUNDSFLAG", 1, true) -- the entire project
reaper.GetSetProjectInfo(proj, "RENDER_ADDTOPROJ", 0, true)
-- (REAPER's Render window opens set up, to check and press Render: 24-bit WAV at the project's rate, and the safety limiter, which shows there.
-- It rendered straight away in whatever format File > Render had. James, 0.58.98)
extras.set_render(proj, extras.STANDARD(proj))
for k, v in pairs(band.LIMIT) do reaper.GetSetProjectInfo(proj, k, v, true) end -- (over full scale it's limited, not clipped: lib/band.lua)
local before = {} -- (what's there already: a cancelled render picked up an earlier one of the same minute. Review, 0.58.92)
for i = 0, math.huge do local f = reaper.EnumerateFiles(out, i); if not f then break end; before[f] = true end
extras.render_window()

-- (the render blocks: Live sync's loop hasn't run since the mutes, so they never reach the band)
for _, tr in ipairs(muted) do reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 0) end
for k, v in pairs(saved) do
  if type(v) == "string" then reaper.GetSetProjectInfo_String(proj, k, v, true) else reaper.GetSetProjectInfo(proj, k, v, true) end
end

local made
for i = 0, math.huge do
  local f = reaper.EnumerateFiles(out, i)
  if not f then break end
  if f:sub(1, #name) == name and not before[f] then made = f end
end
-- (it clipped in every section, and only a measurement showed it: Mac and laptop, 0.42.7. And each machine's master is its own.)
-- (from the file: RENDER_STATS opens a box asking to enable a preference where it's off, and a fixed-point file holds no peak over 0)
local src = made and reaper.PCM_Source_CreateFromFile(out .. "/" .. made)
if src then
  local adjust = reaper.CalculateNormalization(src, 2, 0, 0, 0) -- (2: peak, to 0 dB: what it would take to reach full scale)
  reaper.PCM_Source_Destroy(src)
  if adjust and adjust > 0 and adjust <= 1 / band.LIMIT.RENDER_BRICKWALL + 0.002 then -- (at the limiter's ceiling: it's been working)
    band.log("the mix went over full scale, and a safety limiter caught it so it doesn't clip. For a cleaner mix, turn the master down and render again (your master is your own: it doesn't go to the others)")
  end
end
if made then
  band.log("mix rendered for the studio: " .. out .. "/" .. made)
  pcall(require("api").event, "mix", { file = out .. "/" .. made, song = b.song })
  local droot = require("drive").root(cfg)
  if droot then
    reaper.RecursiveCreateDirectory(droot .. "/" .. b.song .. "/mixes", 0)
    local copied, why = pcall(band.copy_atomic, out .. "/" .. made, droot .. "/" .. b.song .. "/mixes/" .. made)
    band.log(copied and "and copied to Google Drive" or ("couldn't copy the mix to Google Drive, but it's in the shared folder: " .. tostring(why)))
    if copied then droot = droot .. "/" .. b.song .. "/mixes" else droot = nil end
  end
  -- (in the chat, so everyone hears there's a new mix, and where to play it on a phone: the Drive app. Research, 0.58.47)
  pcall(function()
    require("page_chat").post(cfg, b, "New mix: " .. made .. (droot and (". On your phone: the Google Drive app, " .. b.song .. " > mixes.") or
      ". It's in the shared folder's " .. b.song .. "/mixes."))
  end)
else band.msg("No mix was made in the studio's mixes folder (the Render window was cancelled, or its folder or name was changed). Your render settings are as they were.") end
reaper.defer(function() end) -- (no "ReaScript: Run" on the undo list: Ctrl+Z would be spent on it)
