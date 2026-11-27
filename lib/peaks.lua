-- Missing peaks (waveforms) built a step a tick, in any tab: the takes that came in during a first catch-up, or on a computer whose audio device
-- isn't running (REAPER builds none by itself then: Mac, 0.57.6). It was REAPER's "Peaks: Build any missing peaks" (40047), which works on the
-- tab in front only (a tab behind kept its blank boxes) and holds REAPER in a modal box until every file is done: on a big song just opened,
-- clicked around in meanwhile, that's the load-time hazard of findings 2026-11-27 item 14. Here each audio take is asked in turn whether its
-- peaks are missing (PCM_Source_BuildPeaks 0), and one build at a time is run a step each tick (1 until it says 0, then 2 to finish). No REAPER
-- pointer is kept between ticks except the take being built, checked before each step. (rt-setup)
local peaks = { CHECK = 16 } -- takes asked a tick
local W = {} -- tostring(proj) -> { i = the next item to ask about, job = { take, src, item } }
peaks.W = W

function peaks.want(proj)
  if not reaper.PCM_Source_BuildPeaks then -- (a REAPER without it: the action, in the front tab, as before)
    if reaper.EnumProjects(-1) == proj then reaper.Main_OnCommand(40047, 0) end
    return
  end
  local k = tostring(proj)
  if W[k] then W[k].i = 0 else W[k] = { i = 0 } end -- (asked again: from the top, the build under way carries on)
end
function peaks.busy(proj) return W[tostring(proj)] ~= nil end

function peaks.tick(proj)
  local k = tostring(proj)
  local w = W[k]
  if not w then return end
  local j = w.job
  if j then
    -- (its take deleted, or its file swapped, meanwhile: that source is gone, and its build with it)
    if not (reaper.ValidatePtr2(proj, j.take, "MediaItem_Take*") and reaper.GetMediaItemTake_Source(j.take) == j.src) then w.job = nil
    elseif reaper.PCM_Source_BuildPeaks(j.src, 1) == 0 then
      reaper.PCM_Source_BuildPeaks(j.src, 2)
      w.job = nil
      if reaper.ValidatePtr2(proj, j.item, "MediaItem*") then reaper.UpdateItemInProject(j.item) end
    end
    return
  end
  local n = reaper.CountMediaItems(proj)
  for _ = 1, peaks.CHECK do
    if w.i >= n then W[k] = nil; return end
    local it = reaper.GetMediaItem(proj, w.i)
    w.i = w.i + 1
    local tk = it and reaper.GetActiveTake(it)
    local src = tk and not reaper.TakeIsMIDI(tk) and reaper.GetMediaItemTake_Source(tk)
    if src and reaper.PCM_Source_BuildPeaks(src, 0) ~= 0 then w.job = { take = tk, src = src, item = it }; return end
  end
end

-- Peak files in a studio's projects that came through Syncthing before StudioSync's ignore block left them out (lib/songsync.lua PEAKS): one of
-- them built from part of a file, or written over while REAPER had it, kept that take's waveform wrong or blank here. Each is deleted (REAPER
-- builds its own again as a waveform is needed, and peaks.want does after a catch-up). `list(dir)` -> files, folders; `remove(path)`. Pure
-- but for those two. -> how many went.
function peaks.purge(root, list, remove)
  local n = 0
  local function walk(dir, depth)
    local files, dirs = list(dir)
    for _, f in ipairs(files) do if f:lower():match("%.reapeaks$") and remove(dir .. "/" .. f) then n = n + 1 end end
    if depth < 4 then for _, d in ipairs(dirs) do walk(dir .. "/" .. d, depth + 1) end end
  end
  local _, songs = list(root)
  for _, s in ipairs(songs) do if not s:match("^[_%.]") then walk(root .. "/" .. s, 0) end end -- (a project's folder; not _band, _tools, .stfolder)
  return n
end
local function listing(dir)
  local files, dirs = {}, {}
  for i = 0, 100000 do local f = reaper.EnumerateFiles(dir, i); if not f then break end files[#files + 1] = f end
  for i = 0, 100000 do local d = reaper.EnumerateSubdirectories(dir, i); if not d then break end dirs[#dirs + 1] = d end
  return files, dirs
end
-- Once per studio on this computer (Autostart, as REAPER starts, before it opens any project): the ignore block written first, so the
-- deletions aren't waiting on it, then the old peak files go.
function peaks.purge_once(root, user)
  local band = require("band")
  local k = "peaks purged " .. tostring(root):lower()
  if root == "" or reaper.GetExtState(band.SECTION, k) == "1" then return 0 end
  pcall(require("songsync").apply, { root = root, user = user })
  local n = peaks.purge(root, listing, function(p) return os.remove(p) ~= nil end)
  reaper.SetExtState(band.SECTION, k, "1", true)
  if n > 0 then band.log(string.format("%d peak file(s) that had come from other computers deleted in %s: REAPER builds its own (StudioSync leaves them out of syncing now)", n, band.info(root).name)) end
  return n
end

return peaks
