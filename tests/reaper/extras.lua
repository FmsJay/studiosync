-- Run inside REAPER (ReaScript). The band extras (lib/extras.lua, 0.58.47): stems really render, one per shared track; a singer's own file
-- lines up with what came over SonoBus (a known shift, found again); the credits draft counts who did what; a project's stage; what happened
-- while you were away. A scratch tab and a scratch shared folder; the tab is closed without saving at the end.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "extras" }) do package.loaded[m] = nil end
local band, sync, mirror, extras = require("band"), require("sync"), require("mirror"), require("extras")
local root = D .. "/xroot_" .. os.time()
local song, room = "ExtrasLab", "main"
local cfg = { user = "Laptop", root = root }
local b = { song = song, room = room }
reaper.RecursiveCreateDirectory(sync.room_dir(cfg, song, room) .. "/events", 0)
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local proj = reaper.EnumProjects(-1)

-- a mono 16-bit WAV of `secs` seconds: clicks and bursts at uneven places, after `pad` seconds of silence
local function wav(path, secs, pad)
  local rate, n = 44100, math.floor((secs + pad) * 44100)
  local s, seed = {}, 12345
  local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 - 0.5 end
  local bursts = { 0.31, 0.77, 1.05, 1.62, 2.20, 2.45, 3.10, 3.71 }
  for i = 0, n - 1 do
    local t, v = i / rate - pad, 0
    if t >= 0 then for _, at in ipairs(bursts) do if t >= at and t < at + 0.06 then v = rnd() * math.exp(-(t - at) * 40) end end end
    s[#s + 1] = string.pack("<i2", math.floor(v * 30000))
  end
  local data = table.concat(s)
  local f = assert(io.open(path, "wb"))
  f:write(string.pack("<c4I4c4c4I4I2I2I4I4I2I2c4I4", "RIFF", 36 + #data, "WAVE", "fmt ", 16, 1, 1, rate, rate * 2, 2, 16, "data", #data), data)
  f:close()
end

local ok, err = pcall(function()
  reaper.SelectProjectInstance(proj)
  -- ---- stems: two shared tracks with a tone each, one silent: two files, named for their tracks
  for i, name in ipairs({ "Lead", "Pad", "Quiet" }) do
    reaper.InsertTrackInProject(proj, i - 1, 0)
    local tr = reaper.GetTrack(proj, i - 1)
    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
    reaper.CreateNewMIDIItemInProj(tr, 0, 2, false)
    if name ~= "Quiet" then reaper.TrackFX_AddByName(tr, "JS: synthesis/tonegenerator", false, -1) end
  end
  local dir, n = extras.stems(proj, cfg, b)
  check(dir ~= nil, "stems rendered: " .. tostring(dir or n))
  if dir then
    local files = band.files(dir)
    local names = table.concat(files, ", ")
    check(#files == 2, "one file per sounding track, the silent one skipped: " .. names)
    check(names:find("Lead", 1, true) and names:find("Pad", 1, true), "named for their tracks")
  end
  check(reaper.GetSetProjectInfo(proj, "RENDER_SETTINGS", 0, false) ~= 3, "your render settings are put back")
  -- dry: the tone generator is an effect, not an instrument, so a dry render of these tracks is silent and nothing's left; and it's back on after
  local ddir = extras.stems(proj, cfg, b, true)
  check(ddir == nil and reaper.TrackFX_GetEnabled(reaper.GetTrack(proj, 0), 0), "dry: the effects were off for the render, and are back on after")

  -- ---- a singer's own file, 0.137 s later than what came over SonoBus: lined up to within a sample at 8 kHz
  local a, bpath = root .. "/stream.wav", root .. "/own.wav"
  reaper.RecursiveCreateDirectory(root, 0)
  wav(a, 4, 0); wav(bpath, 4, 0.137)
  local tr = reaper.GetTrack(proj, 0)
  local item = reaper.AddMediaItemToTrack(tr)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", 5)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", 4)
  local tk = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(tk, reaper.PCM_Source_CreateFromFile(a))
  local off, why = extras.swap_in_file(item, bpath)
  check(off and math.abs(off - 0.137) < 0.0015, string.format("their own file lines up: %.4f s into it (0.137 expected) %s", tonumber(off) or -1, tostring(why or "")))
  check(reaper.CountTakes(item) == 2 and reaper.GetActiveTake(item) ~= tk, "it's a new take, and the one playing")

  -- ---- credits: who started tracks and made changes, from the history
  local function watch() for _ = 1, 10 do mirror.watch(proj, cfg, song, room, { can = function() return true end, mode = "open" }); if not mirror.more then break end end end
  watch()
  local path = extras.credits(cfg, b)
  local text = band.read(path) or ""
  check(text:find("Laptop", 1, true) ~= nil and text:find("Signed", 1, true) ~= nil, "the credits draft names who did what")
  check(text:match("Laptop%s+(%d+)") ~= nil and tonumber(text:match("Laptop%s+(%d+)")) >= 3, "and counts the tracks they started: " .. tostring(text:match("Laptop[^\n]*")))

  -- ---- a project's stage, for everyone
  extras.set_stage(root, song, "Mixing", "Laptop")
  check(extras.stage(root, song) == "Mixing", "the stage is kept")

  -- ---- while you were away: a bandmate's change after you were last here
  reaper.SetExtState(band.SECTION, "last here " .. song .. "/" .. room, "2000-01-01T00:00:00Z", false)
  local other = { user = "James", root = root }
  sync.post(other, song, room, { type = "obj", obj = "item", oid = "I-JAMES-X", rev = 1, base = 0, state = "<ITEM\n>" })
  local away = extras.away({ user = "Laptop", root = root }, b)
  check(away.parts and table.concat(away.parts, " | "):find("James: 1 change", 1, true) ~= nil, "what the others did is told: " .. table.concat(away.parts or {}, " | "))
  extras.away_seen(b)
  check(reaper.GetExtState(band.SECTION, "last here " .. song .. "/" .. room) > "2000", "and once seen, the moment moves on")
end)
if not ok then fails = fails + 1; out[#out + 1] = "FAIL error: " .. tostring(err) end
reaper.DeleteExtState(band.SECTION, "last here " .. song .. "/" .. room, true)
reaper.SelectProjectInstance(proj)
reaper.Main_SaveProjectEx(proj, root .. "/extras.rpp", 8) -- (saved into the scratch folder first: closing a changed tab asks, and that held REAPER)
reaper.Main_OnCommand(40860, 0)
if reaper.ValidatePtr(front, "ReaProject*") then reaper.SelectProjectInstance(front) end
out[#out + 1] = string.format("extras: fails %d of %d", fails, #out)
return table.concat(out, "\n")
