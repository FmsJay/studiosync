-- Prints rendered in the background (James, 2026-11-01: render wet takes so people can keep editing meanwhile).
-- REAPER renders only in the project in front, holding its window until done. A second REAPER, started hidden on a
-- saved copy with -renderproject, renders while this one carries on: the copy is saved set up exactly as the
-- render in front would be (band.render saves it instead of rendering when a job is open), then that's put back.
-- Measured on the PC (REAPER 7.84): a short MIDI print through a VST3 instrument took ~4 s, no window in front.
-- The copy keeps every track (routing still points at the right ones) with the plug-ins of the tracks the print
-- doesn't go through switched offline, so only what it needs loads.
-- Costs: the second REAPER writes reaper.ini when it quits (as it read it when it started) and puts the copy in the
-- recent-projects list; this REAPER writes its own over both when it quits. Where background renders don't work
-- (GIVE_UP failures, none done: it was two, James 0.58.86), prints render in front again, and the panel says so (Health, and
-- Settings beside the setting) with a button to try the background again (ExtState "bg render retry"). Live sync publishes how it's
-- going in ExtState "bg render state": { failed, done, why, gave_up }.
local band = require("band")
local bg = {}

local WIN = reaper.GetOS():find("^Win") ~= nil
local TMP = ((WIN and (os.getenv("TEMP") or os.getenv("TMP")) or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/"):gsub("/+$", "")) .. "/bandsync-render"
bg.WAIT = 180 -- seconds a job may go without progress (starting, loading its plug-ins, or between passes) before it counts as stuck
bg.MAX = 3 -- renders at once (fewer on a computer with fewer cores: bg.max)
-- How long a print may take in all, by how long it is and how fast this computer has rendered (James, 0.59.11: "renders doing a really long
-- stretch of audio... base it on the actual length... could depend on the power of the system"). A whole song through heavy plug-ins on a
-- slower computer went past a flat 3 minutes every time and never printed. `rate`: seconds of rendering per second of audio, the slowest
-- of this computer's recent prints (1, real time, until it has some). Four passes' worth, twice as slow as seen, at least half real time. Pure.
function bg.time_limit(secs, rate)
  return bg.WAIT + (tonumber(secs) or 0) * 4 * math.max((tonumber(rate) or 1) * 2, 0.5)
end
-- The rate to go by from the recent ones kept (ExtState "bg render rates", newest last): the slowest. Pure.
function bg.rate_of(list)
  local worst
  for x in tostring(list or ""):gmatch("[%d%.]+") do local r = tonumber(x); if r and (not worst or r > worst) then worst = r end end
  return worst or 1
end
local function rate() return bg.rate_of(reaper.GetExtState(band.SECTION, "bg render rates")) end
local function learn(secs, took, passes) -- (a finished print: how fast this computer renders, for the next one's limit)
  if not secs or secs < 30 or not took or not passes or passes < 1 then return end -- (a short part is mostly its plug-ins loading: rates of 5 from a 6 s part. Review, 0.59.14)
  local r = math.max(0.01, (took - 10) / (secs * passes))
  local list = {}
  for x in reaper.GetExtState(band.SECTION, "bg render rates"):gmatch("[%d%.]+") do list[#list + 1] = x end
  list[#list + 1] = string.format("%.3f", r)
  while #list > 8 do table.remove(list, 1) end
  reaper.SetExtState(band.SECTION, "bg render rates", table.concat(list, " "), true)
end
-- Renders at once by this computer's cores: each is a whole REAPER with the part's plug-ins, and three on four cores slowed all of them.
local max_seen
function bg.max()
  if not max_seen then
    local n = tonumber(os.getenv("NUMBER_OF_PROCESSORS") or "")
    -- (through a script file, as everything else on a Mac: its ExecProcess has mangled quoted arguments. Asked in the background: until it
    -- answers, as many as 8 cores would allow)
    if not n and not WIN then n = tonumber((require("services").run_hidden("ncpu", "sysctl -n hw.ncpu 2>/dev/null || nproc", 3600) or ""):match("(%d+)")) end
    if not n and not WIN then return bg.MAX end
    max_seen = (n or 8) >= 8 and bg.MAX or (n or 8) >= 4 and 2 or 1
  end
  return max_seen
end
bg.SPACING = 0.5 -- seconds between starting them
local last_start, cancelled, ini_slot = -math.huge, 0, 0
local jobs = {} -- name -> { dir, started, sizes, at }
local done, failed = 0, 0
bg.GIVE_UP = 5
local retry_seen
local function publish(why)
  local st = band.ext_json(band.SECTION, "bg render state") or {}
  band.set_ext_json(band.SECTION, "bg render state", { failed = failed, done = done, why = why or st.why,
    gave_up = (failed >= bg.GIVE_UP and done == 0) or nil, at = os.time() }, false)
end

-- The Mac's helpers (lib/mac, built by tools/mac/build.sh, shipped by ReaPack to Macs only): the folder, or nil.
-- A second REAPER on a Mac took the keyboard for ~0.7 s and showed its windows, and there's no hidden desktop to put it
-- on, so it runs from a private copy of REAPER.app that macOS treats as background-only (no focus, no Dock icon), with
-- a library that keeps its windows transparent (tools/mac/hide.m): nothing seen in 6 of 6 runs (Mac, 2026-11-01).
local LIB = (debug.getinfo(1, "S").source or ""):match("^@?(.*)[/\\][^/\\]+$") or "."
function bg.helpers()
  local d = LIB .. "/mac"
  if require("band").MAC and reaper.file_exists(d .. "/bandsync-hide.dylib") and reaper.file_exists(d .. "/bandsync-launch") then return d end
end
-- Whether prints go to the background here (ExtState "bg render": "off" or "on" overrides this default).
function bg.default_on() return WIN or bg.helpers() ~= nil end
function bg.on()
  local set = reaper.GetExtState(band.SECTION, "bg render")
  if set == "off" or (not bg.default_on() and set ~= "on") then return false end
  -- (Linux too, when switched on: there it ran nowhere, Setup's tick box did nothing, and the binary is lowercase `reaper`. Off by default
  -- there, as on a Mac without the helpers: nothing keeps the second REAPER's window out of sight. Linux VM, 0.58.77)
  local r = reaper.GetExtState(band.SECTION, "bg render retry") -- (the panel's "Try in the background again")
  if r ~= "" and r ~= retry_seen then
    retry_seen = r
    if failed > 0 then failed = 0; publish("trying again"); band.log("prints: trying the background renderer again") end
  end
  return not (failed >= bg.GIVE_UP and done == 0)
end

-- The copy, ready for the second REAPER: the plug-ins of every track not in `keep` (REAPER track GUIDs) and the
-- master's switched offline (BYPASS <bypass> <offline> ...). A stem of the selected track (RENDER_STEMS 2: a
-- routed MIDI print, sync.print_routed) finds "Nothing to render!" from the command line (PC, 0.37.0), so that one
-- renders the master mix instead: every other track muted, no folders (a parent's plug-ins and fader stay out, as
-- in a stem), the kept tracks sent to the master, the master's fader at 0 dB. StudioSync's own project state goes
-- (<EXTSTATE>'s BANDSYNC blocks): the copy isn't the band's song, so opened from Recent projects it's just a project.
-- Pure.
function bg.prepare(text, keep)
  local mix = tonumber(text:match("\n%s*RENDER_STEMS (%d+)")) == 2
  local out, depth, inside, keeping, skip = {}, 0, nil, true, nil
  for raw in text:gmatch("[^\n]*\n?") do
    if raw == "" then break end
    local line = raw
    local s = line:match("^%s*(.-)%s*$")
    if not skip and depth == 2 and inside == "EXTSTATE" and s:match("^<BANDSYNC") then skip = depth end
    if depth == 1 and s:sub(1, 1) == "<" then
      local guid = s:match("^<TRACK%s+(%b{})")
      inside, keeping = s:match("^<(%S+)"), guid ~= nil and keep[guid:upper()] or false
    end
    if (inside == "TRACK" or inside == "MASTERFXLIST") and not keeping then
      line = line:gsub("^(%s*BYPASS %d+ )%d+", "%11")
    end
    if mix then
      if depth == 1 then
        line = line:gsub("^(%s*RENDER_STEMS )%d+", "%10"):gsub("^(%s*MASTER_VOLUME )%S+ %S+", "%11 0"):gsub("^(%s*MASTERMUTESOLO )%d+", "%10")
      elseif depth == 2 and inside == "TRACK" then
        line = line:gsub("^(%s*ISBUS )%S+ %S+", "%10 0")
        if keeping then line = line:gsub("^(%s*MAINSEND )%d+", "%11")
        else line = line:gsub("^(%s*MUTESOLO )%d+", "%11") end
      end
    end
    if s:sub(1, 1) == "<" then depth = depth + 1 elseif s == ">" then depth = depth - 1 end
    if depth == 1 and s == ">" then inside, keeping = nil, true end
    if skip then
      if depth == skip then skip = nil end -- (its closing line, left out too)
    else
      out[#out + 1] = line
    end
  end
  return table.concat(out)
end

-- Windows: the second REAPER starts on a Windows desktop of its own (CreateDesktop), so nothing it shows can be seen
-- or take the keyboard. Started plainly, its scan box, its window (maximised, as REAPER was last left) and the
-- render box covered the screen for ~1.5 s on every print and took the keys (laptop, 0.37.0): -noactivate and a
-- hidden .cmd don't stop that. The launcher stays until that REAPER quits (a desktop goes with its last handle),
-- writes its process id to pid.txt, and tidies empty job folders.
local LAUNCH = [==[
param($exe, $job, $res, $profile, $ini, $limit = 600)
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class StudioSyncDesk {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct SI { public int cb; public string reserved; public string desktop; public string title;
    public int x, y, w, h, xc, yc, fill, flags; public short show, reserved2; public IntPtr reserved3, stdin, stdout, stderr; }
  [StructLayout(LayoutKind.Sequential)] public struct PI { public IntPtr process, thread; public int pid, tid; }
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern IntPtr CreateDesktop(string name, IntPtr device, IntPtr mode, int flags, uint access, IntPtr sa);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, int flags, IntPtr env, string dir, ref SI si, out PI pi);
}
"@
$dir = Split-Path $job
# the render profile's links (bg.profile): this REAPER's Effects and Data, and its plug-ins (UserPlugins\FX) only
foreach ($d in "Effects", "Data") {
  $l = Join-Path $profile $d
  if (-not (Test-Path $l) -and (Test-Path (Join-Path $res $d))) { New-Item -ItemType Junction -Path $l -Target (Join-Path $res $d) | Out-Null }
}
New-Item -ItemType Directory -Force (Join-Path $profile "UserPlugins") | Out-Null
$fx = Join-Path $profile "UserPlugins\FX"
if (-not (Test-Path $fx) -and (Test-Path (Join-Path $res "UserPlugins\FX"))) { New-Item -ItemType Junction -Path $fx -Target (Join-Path $res "UserPlugins\FX") | Out-Null }
# job folders done with: empty ones, and any six hours old (its item went before its print was picked up: laptop, 0.40.0. An hour, till a long
# print could run that long: 0.59.11)
Get-ChildItem (Split-Path $dir) -Directory -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $dir -and $_.Name -ne "profile" -and -not $_.LinkType -and
  (-not (Get-ChildItem $_.FullName -Force) -or $_.LastWriteTime -lt (Get-Date).AddHours(-6)) } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
$desk = [StudioSyncDesk]::CreateDesktop("StudioSyncRender", [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
$si = New-Object StudioSyncDesk+SI
$si.cb = [Runtime.InteropServices.Marshal]::SizeOf($si)
$si.desktop = "StudioSyncRender"
$pi = New-Object StudioSyncDesk+PI
$cmd = '"' + $exe + '" -newinst -nosplash -ignoreerrors -noactivate -cfgfile "' + (Join-Path $profile $ini) + '" "' + $job + '"'
$env:BANDSYNC_RENDER = "1" # (inherited: Scripts/__startup.lua's guard skips the person's startup scripts in it)
# ([NullString]::Value, not $null: PowerShell passes $null to a string parameter as "", and CreateProcess refuses "")
if ($desk -ne [IntPtr]::Zero -and [StudioSyncDesk]::CreateProcess([NullString]::Value, $cmd, [IntPtr]::Zero, [IntPtr]::Zero, $false, 0, [IntPtr]::Zero, [NullString]::Value, [ref]$si, [ref]$pi)) {
  Set-Content (Join-Path $dir "pid.txt") $pi.pid
  # (still there past its limit (bg.time_limit, and a few minutes): stuck on something nobody can see. Ended, not left: a Live sync that
  # reloaded had forgotten it, its folder went after an hour with its pid.txt, and it stayed for good, hidden. 13 of them on the PC, 0.59.10)
  try { Wait-Process -Id $pi.pid -Timeout ([int]$limit) -ErrorAction Stop } catch { Stop-Process -Id $pi.pid -Force -ErrorAction SilentlyContinue }
  if (Test-Path $dir) { Set-Content (Join-Path $dir "done.txt") "1" }
} else { Set-Content (Join-Path $dir "pid.txt") "failed" }
]==]

-- ---- the render profile (0.40) ------------------------------------------------------------------------------------
-- The second REAPER runs with a settings folder of its own (-cfgfile, James, 2026-11-01): links to this REAPER's
-- Effects and Data and to its plug-ins (UserPlugins/FX), but none of its extensions: started plainly, the second REAPER
-- loaded all of them, ReaLearn, ReaBlink (Ableton Link), MCU Live, Komplete Kontrol..., and opened the MIDI devices
-- (PC, 0.39.3). Copies of the plug-in lists (no scan: an empty folder rescanned everything and hung past 60 s) and the
-- licence, and a reaper.ini of its own, which it writes instead of this REAPER's (it rewrote it on quitting, and put
-- each job in Recent projects). The launcher makes the links; the files are refreshed here every time.
local PROFILE = TMP .. "/profile"
local COPY = { "^reaper%-vstplugins.*%.ini$", "^reaper%-vstshells.*%.ini$", "^reaper%-clap.*%.ini$", "^reaper%-auplugins.*%.ini$",
  "^reaper%-jsfx%.ini$", "^reaper%-reginfo2%.ini$" }
-- This REAPER's reaper.ini for the render profile: no MIDI devices in or out, no control surfaces (the web interface's
-- port too), no splash, no recent or last project, the audio device closed while it's in the background. Pure.
function bg.profile_ini(text)
  local out, section = {}, ""
  for raw in (text or ""):gmatch("[^\r\n]+") do
    local line = raw
    local k = line:match("^([%w_]+)=")
    section = line:match("^%[(.-)%]$") or section
    -- (the video window shut: open in this REAPER, the hidden one would open it too for a project with video, a window and frames nobody
    -- sees. rt-video2)
    if section:lower() == "reaper_video" and (k == "visible" or k == "fullscreen") then line = k .. "=0"
    elseif k and (k:match("^midiins") or k:match("^midiouts")) and line:match("=%-?%d+$") then line = k .. "=0"
    elseif k == "csurf_cnt" then line = "csurf_cnt=0"
    elseif k and k:match("^csurf_%d+$") then line = nil
    elseif k == "splash" or k == "splash2" then line = k .. "=0"
    elseif k and (k:match("^recent%d+$") or k == "lastproject" or k == "lastprojuiref") then line = nil
    elseif k == "audiocloseinactive" or k == "renderclosewhendone" then line = nil end
    if line then
      out[#out + 1] = line
      -- (the Mac writes [reaper]: Mac, 0.40.2) (4: the render window closes whatever came out, a print that clips too,
      -- where nobody could click it: Mac, 0.42.2)
      if line:upper() == "[REAPER]" then out[#out + 1] = "audiocloseinactive=1"; out[#out + 1] = "renderclosewhendone=4" end
    end
  end
  return table.concat(out, "\n") .. "\n"
end
-- What the second REAPER does: its resource folder is the profile, so this is the __startup.lua it runs. -renderproject
-- renders the moment the project has loaded, and an instrument that loads its samples in the background isn't ready:
-- Superior Drummer's print came out almost silent, 17 KB against 541 KB in front, with no error (PC, 2026-11-01). So it
-- renders, and again, until two renders in a row come out about the same size, then keeps the last. A plug-in with nothing
-- to load costs one extra render. (Not the same bytes: some plug-ins never repeat exactly. Serum differed by 3%.)
bg.PASSES, bg.PASS_WAIT, bg.PASS_SAME = 10, 3, 0.10
local function pass_script()
  return string.format([==[
-- StudioSync's background render (written by lib/bgrender.lua; only the hidden REAPER runs this)
if not os.getenv("BANDSYNC_RENDER") then return end
local PASSES, WAIT, SAME = %d, %d, %.2f
local function max_passes(dir) -- (a part with no instrument, nothing to load: one render. bg.start writes it. 0.59.12)
  local f = dir and io.open(dir .. "/maxpasses.txt", "r")
  if not f then return PASSES end
  local n = tonumber(f:read("a")); f:close()
  return n or PASSES
end
local function flac_size(dir)
  for i = 0, 99 do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then return 0 end
    if f:lower():match("%%.flac$") then
      local h = io.open(dir .. "/" .. f, "rb")
      if h then local n = h:seek("end"); h:close(); return n end
    end
  end
  return 0
end
local function clear(dir, into)
  local names = {}
  for i = 0, 99 do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    names[#names + 1] = f
  end
  for _, f in ipairs(names) do
    if into then os.rename(dir .. "/" .. f, into .. "/" .. f) else os.remove(dir .. "/" .. f) end
  end
  os.remove(dir)
end
local started = reaper.time_precise()
local proj, dir, pass, last, at
local function step()
  if not dir then
    local p, path = reaper.EnumProjects(-1)
    if path and path:find("job.rpp", 1, true) then proj, dir = p, path:match("^(.*)[/\\]")
    elseif reaper.time_precise() - started > 60 then return reaper.Main_OnCommand(40004, 0) end
    return reaper.defer(step)
  end
  if at and reaper.time_precise() < at then return reaper.defer(step) end
  -- (selected items to render and none selected: REAPER's "Nothing to render!" box, where nobody sees it, until the job counted as stuck
  -- (3 minutes) and blamed a plug-in. Said at once instead: the print renders in front. Review, 0.59.19)
  local items = math.floor(reaper.GetSetProjectInfo(proj, "RENDER_SETTINGS", 0, false)) & 32 ~= 0 or reaper.GetSetProjectInfo(proj, "RENDER_BOUNDSFLAG", 0, false) == 4
  if not pass and items and reaper.CountSelectedMediaItems(proj) == 0 then
    local h = io.open(dir .. "/empty.txt", "w")
    if h then h:close() end
    return reaper.Main_OnCommand(40004, 0) -- File: Quit REAPER
  end
  pass = (pass or 0) + 1
  local out = dir .. "/pass" .. pass
  reaper.RecursiveCreateDirectory(out, 0)
  reaper.GetSetProjectInfo_String(proj, "RENDER_FILE", out, true)
  reaper.Main_OnCommand(42230, 0) -- File: Render project, most recent settings, auto-close dialog
  local size = flac_size(out)
  local same = last and last.size > 0 and math.abs(size - last.size) <= SAME * math.max(size, last.size)
    or last and last.size == size
  if same or pass >= max_passes(dir) then
    if last then clear(last.dir) end
    clear(out, dir)
    local h = io.open(dir .. "/passes.txt", "w") -- (its print is ready, whether or not anything stops it quitting)
    if h then h:write(pass, "\n"); h:close() end
    reaper.Main_SaveProject(proj, false)
    return reaper.Main_OnCommand(40004, 0) -- File: Quit REAPER
  end
  if last then clear(last.dir) end
  last = { dir = out, size = size }
  at = reaper.time_precise() + WAIT -- (the second pass waits too: two at once, a sampler still loading, came out equally silent. Review, 0.59.14)
  reaper.defer(step)
end
reaper.defer(step)
]==], bg.PASSES, bg.PASS_WAIT, bg.PASS_SAME)
end

-- A second REAPER rewrites its settings as it quits. One starting at that moment read half of them, lost its plug-in
-- folders, and began scanning the default one where nobody could see, holding its place until the time limit (PC, three
-- at once, 2026-11-01). So each job gets a reaper.ini of its own (a read-only one stops REAPER at a "Configuration Write
-- Error" box, waiting for an OK nobody can give), and the plug-in lists they share are read-only, rewritten only when
-- this REAPER's have changed.
local function read_only(on)
  if WIN then reaper.ExecProcess(string.format('cmd /c attrib %sR "%s\\reaper-*.ini"', on and "+" or "-", (PROFILE:gsub("/", "\\"))), 5000)
  else -- (a script file, not a quoted argument: macOS's ExecProcess mangles those. Mac review, 0.59.14)
    local sh = TMP .. "/bandsync-chmod.sh"
    band.write_atomic(sh, string.format("chmod %s '%s'/reaper-*.ini\n", on and "a-w" or "u+w", (PROFILE:gsub("'", "'\\''"))))
    reaper.ExecProcess("/bin/sh '" .. sh .. "'", 5000)
  end
end
local function profile()
  local res = reaper.GetResourcePath():gsub("\\", "/")
  reaper.RecursiveCreateDirectory(PROFILE, 0)
  local want = {} -- file name -> what it should hold
  for _, f in ipairs(band.files(res)) do
    for _, pat in ipairs(COPY) do
      if f:lower():match(pat) then want[f] = band.read(res .. "/" .. f); break end
    end
  end
  local stale = {}
  for f, text in pairs(want) do if text and band.read(PROFILE .. "/" .. f) ~= text then stale[#stale + 1] = f end end
  if #stale > 0 then
    read_only(false)
    for _, f in ipairs(stale) do band.write_atomic(PROFILE .. "/" .. f, want[f]) end
    read_only(true)
  end
  reaper.RecursiveCreateDirectory(PROFILE .. "/Scripts", 0)
  local script = pass_script()
  if band.read(PROFILE .. "/Scripts/__startup.lua") ~= script then band.write_atomic(PROFILE .. "/Scripts/__startup.lua", script) end
  return res
end
bg.PROFILE = PROFILE

-- What runs one job on a Mac. Pure (t: tmp, profile, res, exe, ini, job, helpers). Makes the private copy the first time
-- and again after REAPER or a helper changes (`built` says what it was made from), in a job's own script so this REAPER
-- never waits for it. pid.txt lets a job be ended; done.txt says its REAPER has quit, so its files are complete.
local MAC_JOB = [==[
find @TMP@ -mindepth 1 -maxdepth 1 -type d ! -name profile \( -empty -o -mmin +360 \) -exec rm -rf {} + 2>/dev/null
P=@PROFILE@; R=@RES@; X=@EXE@; J=@JOB@; H=@HELPERS@
D="${J%/*}"
for d in Effects Data; do [ -e "$P/$d" ] || [ ! -d "$R/$d" ] || ln -s "$R/$d" "$P/$d"; done
mkdir -p "$P/UserPlugins"; [ -e "$P/UserPlugins/FX" ] || [ ! -d "$R/UserPlugins/FX" ] || ln -s "$R/UserPlugins/FX" "$P/UserPlugins/FX"
export BANDSYNC_RENDER=1
[ -s "$P/reaper-jsfx.ini" ] || { echo failed > "$D/pid.txt"; exit 1; } # (the profile went just now: the next job makes it whole)
if [ -n "$H" ]; then
  C="$HOME/Library/Caches/StudioSync"; A="$C/REAPER-render.app"; S="${X%/Contents/MacOS/*}"; B="${X##*/}"
  W="$(stat -f '%m %z' "$X" "$H/bandsync-hide.dylib" "$H/bandsync-launch" | tr '\n' ' ')"
  mkdir -p "$C"
  find "$C/build.lock" -maxdepth 0 -mmin +5 -exec rmdir {} + 2>/dev/null
  # (the copy or a helper gone or emptied, as well as out of date: Mac, 0.42.2)
  [ -x "$A/Contents/MacOS/$B" ] && [ -s "$C/bandsync-hide.dylib" ] && [ -x "$C/bandsync-launch" ] || rm -f "$C/built"
  if [ "$(cat "$C/built" 2>/dev/null)" != "$W" ] && mkdir "$C/build.lock" 2>/dev/null; then
    rm -rf "$A" "$C/built"
    ditto "$S" "$A" && plutil -replace LSBackgroundOnly -bool YES "$A/Contents/Info.plist" && codesign --force --deep -s - "$A" &&
      cp "$H/bandsync-hide.dylib" "$H/bandsync-launch" "$C/" && xattr -c "$C/bandsync-hide.dylib" "$C/bandsync-launch" &&
      chmod +x "$C/bandsync-launch" && echo "$W" > "$C/built"
    rmdir "$C/build.lock"
  fi
  n=0
  while [ "$(cat "$C/built" 2>/dev/null)" != "$W" ] && [ -d "$C/build.lock" ] && [ "$n" -lt 240 ]; do sleep 0.5; n=$((n+1)); done
  if [ "$(cat "$C/built" 2>/dev/null)" != "$W" ]; then echo failed > "$D/pid.txt"; exit 1; fi
  nohup "$C/bandsync-launch" "$C/bandsync-hide.dylib" "$A/Contents/MacOS/$B" -newinst -nosplash -ignoreerrors -noactivate -cfgfile "$P/@INI@" "$J" >/dev/null 2>&1 &
else
  nohup "$X" -newinst -nosplash -ignoreerrors -noactivate -cfgfile "$P/@INI@" "$J" >/dev/null 2>&1 &
fi
p=$!
echo "$p" > "$D/pid.txt"
( sleep @LIMIT@; kill -9 "$p" 2>/dev/null ) & w=$! # (still there past its limit: stuck, ended, as on Windows. 0.59.10)
wait "$p"
echo "$?" > "$D/done.txt"
pkill -P "$w" 2>/dev/null; kill "$w" 2>/dev/null # (its sleep too: left, one per print. Mac review, 0.59.14)
]==]
function bg.mac_script(t)
  local function q(s) return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'" end
  local vals = { TMP = q(t.tmp), PROFILE = q(t.profile), RES = q(t.res), EXE = q(t.exe), JOB = q(t.job), HELPERS = q(t.helpers), INI = t.ini,
    LIMIT = tostring(math.floor(tonumber(t.limit) or 600)) }
  return (MAC_JOB:gsub("@(%u+)@", vals))
end

local function launch(exe, job, limit)
  -- (each time: only what's changed or gone is rewritten. A profile a temp clean-up took came back with a job out as
  -- settings and no plug-in lists, and that REAPER scanned every plug-in until its time ran out: laptop, 0.42.2)
  local res = profile()
  ini_slot = ini_slot % 12 + 1 -- (a few, in turn: never one a REAPER that's just finished may still be writing)
  local ini = "job" .. ini_slot .. ".ini"
  reaper.RecursiveCreateDirectory(PROFILE, 0)
  band.write_atomic(PROFILE .. "/" .. ini, bg.profile_ini(band.read(reaper.get_ini_file())))
  if WIN then
    local cmd, vbs, ps = job:gsub("%.rpp$", ".cmd"), TMP .. "/hidden.vbs", TMP .. "/launch.ps1"
    if band.read(ps) ~= LAUNCH then band.write_atomic(ps, LAUNCH) end
    local function pc(s) return (tostring(s):gsub("%%", "%%%%")) end -- (a % in a path is a variable to cmd: doubled. Review, 0.59.14)
    band.write_atomic(cmd, string.format('@chcp 65001 >nul\r\n@powershell -NoProfile -ExecutionPolicy Bypass -File "%s" "%s" "%s" "%s" "%s" "%s" %d\r\n', pc(ps), pc(exe), pc(job), pc(res), pc(PROFILE), pc(ini), math.floor(limit or 600))) -- (chcp: UTF-8 paths, as services.background. 0.58.78)
    if not reaper.file_exists(vbs) then band.write_atomic(vbs, 'CreateObject("WScript.Shell").Run """" & WScript.Arguments(0) & """", 0, False\r\n') end
    reaper.ExecProcess(string.format('wscript.exe //B //Nologo "%s" "%s"', vbs, cmd), -1)
  else
    local sh = job:gsub("%.rpp$", ".sh")
    band.write_atomic(sh, bg.mac_script({ tmp = TMP, profile = PROFILE, res = res, exe = exe, ini = ini, job = job, helpers = bg.helpers(), limit = limit }))
    reaper.ExecProcess("/bin/sh '" .. sh .. "'", -1)
  end
end
-- (on a Mac GetExePath() is the folder holding REAPER.app, "/Applications": Mac, 0.39.0)
local function exe_path()
  local d = reaper.GetExePath():gsub("\\", "/")
  if WIN then return d .. "/reaper.exe" end
  if band.LINUX then return d .. "/reaper" end -- (lowercase, beside its libSwell.so: Linux VM, 0.58.77)
  -- (one way with the start's hand-over, renamed bundles too: lib/startup.lua startup.reaper_exe. Round 1 review, 0.59.45)
  local found = require("startup").reaper_exe(reaper.GetOS(), d)
  if found then return found end
  if reaper.file_exists(d .. "/REAPER") then return d .. "/REAPER" end
  return d .. "/REAPER.app/Contents/MacOS/REAPER"
end

-- Render in the background, up to bg.MAX at once and one per item (`key`): `render(dir)` sets the project up and calls
-- band.render as it always does (which saves the copy into `dir` instead of rendering); `keep`: the tracks the
-- print goes through. Active tab only.
function bg.start(key, name, keep, render, secs, quick, where) -- secs: how long the part is; quick: one pass will do; where: its track
  local dir = TMP .. "/" .. name
  reaper.RecursiveCreateDirectory(dir, 0)
  for _, f in ipairs(band.files(dir)) do os.remove(dir .. "/" .. f) end
  -- (and its pass folders: one left by a job ended part-way held a print of this name, and the hidden REAPER stopped on REAPER's "files
  -- exist" box, out of sight, till it timed out and blamed a plug-in. Review, 0.59.14)
  for _, sub in ipairs(band.subdirs(dir)) do
    for _, f in ipairs(band.files(dir .. "/" .. sub)) do os.remove(dir .. "/" .. sub .. "/" .. f) end
    os.remove(dir .. "/" .. sub)
  end
  local job = dir .. "/job.rpp"
  pcall(require("tools").render_guard) -- (the person's startup scripts don't run in it)
  band.render_job = { dir = dir, copy = job }
  local ok, err = pcall(render, dir)
  band.render_job = nil
  if not ok or not reaper.file_exists(job) then return false, err end
  local set = {}
  for _, g in ipairs(keep) do set[g:upper()] = true end
  band.write_atomic(job, bg.prepare(band.read(job), set))
  if quick then band.write_atomic(dir .. "/maxpasses.txt", "1") end -- (twice through a long part for nothing: James, 0.59.12)
  local limit = bg.time_limit(secs, rate())
  launch(exe_path(), job, math.min(limit + 180, 32767)) -- (its launcher ends it a while after Live sync would; Wait-Process refuses more than 32767 s, and ended it at once. Review, 0.59.14)
  jobs[key] = { name = name, dir = dir, started = reaper.time_precise(), secs = secs, limit = limit, progress_at = reaper.time_precise(), sig = "", where = where }
  last_start = reaper.time_precise()
  return true
end

-- A job's output files once it has finished, else nil. Finished: on Windows, they can be renamed (REAPER holds
-- them open while it writes; each is renamed and back); on a Mac, its script says its REAPER has quit.
local function finished(j)
  local files = {}
  for _, f in ipairs(band.files(j.dir)) do
    local ext = f:match("%.(%a+)$")
    if ext == "flac" or ext == "opus" then files[#files + 1] = f end
  end
  if #files < 2 then return nil end
  if WIN then
    for _, f in ipairs(files) do
      local a = j.dir .. "/" .. f
      if not os.rename(a, a .. ".x") then return nil end
      os.rename(a .. ".x", a)
    end
    return files
  end
  if reaper.file_exists(j.dir .. "/done.txt") or reaper.file_exists(j.dir .. "/passes.txt") then return files end
  return nil
end
local function drop(key)
  local j = jobs[key]
  -- (the whole folder, its pass folders and REAPER's job .rpp-bak too: band.files skipped those, so every job left its folder behind. 2026-11-20)
  local function empty(dir)
    local names = {}
    for i = 0, 199 do local f = reaper.EnumerateFiles(dir, i); if not f then break end; names[#names + 1] = f end
    for _, f in ipairs(names) do os.remove(dir .. "/" .. f) end
    os.remove(dir)
  end
  for _, sub in ipairs(band.subdirs(j.dir)) do empty(j.dir .. "/" .. sub) end
  empty(j.dir)
  jobs[key] = nil
end
-- Still going: something new in its folder lately (a pass begun, its file growing), within the limit for its length. -> true / false
local function alive(j)
  local t = reaper.time_precise()
  local pass, size = 0, 0
  for _, d in ipairs(band.subdirs(j.dir)) do
    local n = tonumber(d:match("^pass(%d+)$"))
    if n and n > pass then pass = n end
  end
  local unread = false
  if pass > 0 then
    for _, f in ipairs(band.files(j.dir .. "/pass" .. pass)) do
      local n = band.size(j.dir .. "/pass" .. pass .. "/" .. f)
      if n then size = size + n else unread = true end
    end
  end
  local sig = pass .. ":" .. size
  -- (a file REAPER holds that can't be read for its size: going by its length's limit alone, not taken for stuck in the middle of a pass)
  if sig ~= j.sig or unread then j.sig, j.progress_at = sig, t end
  return t - (j.progress_at or j.started) <= bg.WAIT and t - j.started <= (j.limit or bg.WAIT)
end
local function launch_failed(j)
  if (band.read(j.dir .. "/pid.txt") or ""):match("^failed") or reaper.file_exists(j.dir .. "/empty.txt") then return true end
  -- (it quit with no print, or its folder's gone: known now, not at the time limit, with newer edits waiting: laptop, 0.42.2)
  if not reaper.file_exists(j.dir .. "/job.rpp") and not finished(j) then return true end
  return reaper.file_exists(j.dir .. "/done.txt") and not finished(j)
end
-- End a job's REAPER, if it's still there. -> whether that could be asked (once its process id is known).
local function end_job(j)
  local pid = tonumber((band.read(j.dir .. "/pid.txt") or ""):match("^%d+"))
  if not pid then return false end
  -- (only if that id is still a REAPER: it may have quit already, and ids come round again. Review, 0.58.92)
  if not WIN then require("services").run_hidden("endjob" .. pid, "ps -p " .. pid .. " -o comm= | grep -qi reaper && kill -9 " .. pid, 30); return true end
  local kill = TMP .. "/kill" .. pid .. ".cmd" -- (one each, deleting itself: jobs can end together)
  band.write_atomic(kill, "@taskkill /PID " .. pid .. ' /FI "IMAGENAME eq reaper.exe" /T /F\r\n@del "%~f0"\r\n')
  reaper.ExecProcess(string.format('wscript.exe //B //Nologo "%s" "%s"', TMP .. "/hidden.vbs", kill), -1)
  return true
end
-- A job that's gone wrong: its REAPER (if it's still there, stuck on something nobody can see) is ended. One that never
-- started renders in front instead. One that ran and never finished doesn't: it's a plug-in asking something nobody can
-- see, and in front it held this REAPER on that same question, and on every render after it (UAD with no hardware: Mac,
-- 0.42.2). That part goes without a new print until it changes again. -> "failed" or "stuck".
bg.stuck = {} -- print name -> true (this session)
local function timed_out(key)
  local j = jobs[key]
  local never = launch_failed(j)
  -- (read before drop empties its folder: after it, every one read as "quit without a print". 0.59.19)
  local no_start, empty = (band.read(j.dir .. "/pid.txt") or ""):match("^failed"), reaper.file_exists(j.dir .. "/empty.txt")
  end_job(j)
  drop(key)
  if empty then -- (not the background's fault: not counted toward giving up on it)
    band.log("a print's background copy had nothing selected to render: it renders here instead")
    return "failed"
  end
  if never then
    failed = failed + 1
    local why = no_start and "the second REAPER didn't start" or "the second REAPER quit without a print"
    publish(why)
    local gave_up = failed >= bg.GIVE_UP and done == 0
    local words = "a print stopped in the background before it finished (" .. why .. "): it renders here instead" ..
      (gave_up and (" (and so will the rest, after " .. failed .. " tries: Settings > Options can try the background again)") or (" (try " .. failed .. " of " .. bg.GIVE_UP .. ")"))
    if gave_up and failed == bg.GIVE_UP then -- (once, when it gives up: before then each still printed, in front)
      require("prints").problem("Prints can't render in the background here (" .. why .. "), so they render in front and REAPER holds still while they do. Settings > Options can try the background again.")
    else band.log(words) end
    return "failed"
  end
  bg.stuck[j.name] = true
  local long = reaper.time_precise() - j.started > (j.limit or bg.WAIT)
  require("prints").problem("The print of a part" .. (j.where and (" on " .. j.where) or "") .. (long and string.format(" took over %d s to render (its limit for its length on this computer) and was stopped", math.floor(j.limit or bg.WAIT))
    or (" stopped getting anywhere for " .. bg.WAIT .. " s and was stopped")) ..
    ": a plug-in may be waiting on a licence or setup window. Open the track's plug-ins, close any pop-up, then Try again. Collaborators keep the last print meanwhile.")
  return "stuck"
end

-- Whether another render has to wait: each is a whole REAPER, so bg.MAX at most, and starting one (saving the project's
-- copy) holds this REAPER up for a moment, so one at a time, spaced out.
function bg.busy()
  local running = 0
  for key, j in pairs(jobs) do
    if not finished(j) then
      if alive(j) and not launch_failed(j) then running = running + 1
      else timed_out(key) end
    end
  end
  return running >= bg.max() or reaper.time_precise() - last_start < bg.SPACING
end

-- The item's print `name`, moved into `out` once rendered: its .flac path. Else nil and "running", "failed", or
-- nothing (no job for it, or the job was for what the item was before: that one's dropped).
function bg.claim(key, name, out)
  local j = jobs[key]
  if not j then return nil end
  -- the item has changed since this job started: nobody wants its print, and it holds a place (a heavy instrument, for
  -- minutes). (Before its process id is known it runs on, and is dropped when it ends.)
  if j.name ~= name and end_job(j) then
    cancelled = cancelled + 1
    jobs[key] = nil -- (its folder goes with the others: it's empty of what we want, and its REAPER may still hold it)
    return nil
  end
  local files = finished(j)
  if not files then
    if alive(j) and not launch_failed(j) then return nil, "running" end
    return nil, timed_out(key)
  end
  end_job(j) -- (its print is done: if a question stops it quitting, it mustn't stay on, unseen)
  if not j.learned then j.learned = true; learn(j.secs, reaper.time_precise() - j.started, tonumber(band.read(j.dir .. "/passes.txt") or "")) end
  if j.name ~= name then drop(key); return nil end
  reaper.RecursiveCreateDirectory(out, 0)
  local flac
  for _, f in ipairs(files) do
    -- (whatever the render called it: a stem render may add the track's name, a leftover a "-2")
    local ext = f:match("%.(%a+)$")
    local to = out .. "/" .. name .. "." .. ext
    -- (put in place without deleting the old one first: a rename across drives fails, and the print was gone for everyone. A copy replaces it
    -- safely, band.copy_atomic. One REAPER still holds can't be replaced: it's the same print, made from the same, so that one stands. Review, 0.58.47)
    local src = j.dir .. "/" .. f
    local moved = os.rename(src, to) or (pcall(require("band").copy_atomic, src, to) and os.remove(src) ~= false)
    if (moved or reaper.file_exists(to)) and ext == "flac" then flac = to end
  end
  drop(key)
  if flac then done = done + 1; if done == 1 then publish() end end
  return flac, not flac and "failed" or nil
end

-- Whether any job is out (Live sync then looks every second, so a finished print goes in at once).
-- (a finished print nobody collected (its part undone to one already printed, or deleted) kept the tab "waiting" all session: Live sync
-- looked at full speed and Sync and exit never got past sending. Dropped half a minute after it's done. Review, 0.58.96)
function bg.waiting()
  local t = reaper.time_precise()
  for key, j in pairs(jobs) do
    if finished(j) then
      j.done_seen = j.done_seen or t
      if t - j.done_seen > 30 then drop(key) end
    end
  end
  return next(jobs) ~= nil
end

-- Prints done in the background this session, and jobs that failed (tests, Health).
function bg.counts() return done, failed, cancelled end

-- A copy set up elsewhere (lib/bounces.lua: a share of stems or a mix), `dir`/job.rpp, rendered by the same hidden REAPER as a print and
-- tracked by its caller (passes.txt, pid.txt, done.txt). limit: seconds before its launcher ends it.
bg.TMP = TMP
function bg.launch_job(dir, limit)
  pcall(require("tools").render_guard) -- (as bg.start: the person's startup scripts don't run in it)
  launch(exe_path(), dir .. "/job.rpp", limit)
end
function bg.end_job(dir) return end_job({ dir = dir }) end

return bg
