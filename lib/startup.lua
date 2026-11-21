-- REAPER's start without its boxes. Reloading a band song stops at "Replace missing file..." and "Project Load Warning" for
-- anything a bandmate's machine has and this one lacks, on every start, before any script runs, so a machine nobody is at stays
-- out of the band. No preference covers the plug-ins, and scripts are paused while a box is up. So as REAPER quits, a song's tabs
-- are noted and REAPER told to open none; at its next start they're opened from here, and a small hidden helper answers those
-- two boxes for band songs only (never for a project of your own), leaving the files offline and changing nothing.
-- On a Mac a helper clicking another app's box would need an Accessibility permission, which StudioSync won't ask for. There each tab is handed
-- to the running REAPER with -ignoreerrors, its own "do not show errors on load" (0.56; proven on Windows, where a plain hand-over stops at the box).
local band = require("band")
local startup = {}

local DIR = band.home()
local FILE = DIR .. "/reopen.json"
local BAND_TAB, DONE, SAID = DIR .. "/reopen-band-tab", DIR .. "/reopen-done", DIR .. "/reopen-said.txt"
local function usable() return reaper.SNM_GetIntConfigVar ~= nil and reaper.BR_Win32_WritePrivateProfileString ~= nil end
local function windows() return reaper.GetOS():find("^Win") ~= nil end
-- In the file, not only in memory: REAPER has written its settings by the time a script's atexit runs, so a change there alone is lost.
local function set_open_mode(value)
  reaper.SNM_SetIntConfigVar("loadlastproj", value)
  reaper.BR_Win32_WritePrivateProfileString("REAPER", "loadlastproj", tostring(value), reaper.get_ini_file())
end

-- Tabs as of the last look: at quit they may be closing already.
local known = {}
-- The plan is kept on disk all the time, not only at quit: after a crash REAPER reopened the tabs itself, with its boxes up until
-- someone answered and the song catching up a little at a time behind them (PC, 2026-11-03: nearly 2 minutes against 20 s).
local kept, kept_was, kept_n, fewer_since
-- The choice as the plan on disk has it: keep_open_mode (another script's Lua state, Live sync's) rewrites it there, and this copy would write the old one back.
local function held()
  local plan = band.read_json(FILE)
  return type(plan) == "table" and tonumber(plan.loadlastproj) or kept_was
end
function startup.note()
  local tabs, front = {}, reaper.EnumProjects(-1)
  for i = 0, 512 do
    local p, fn = reaper.EnumProjects(i)
    if not p then break end
    if fn ~= "" then tabs[#tabs + 1] = { path = fn, band = band.binding(p) ~= nil or nil, front = p == front or nil } end
  end
  if not usable() then known = tabs; return end
  local sig = band.json_encode(tabs)
  if sig == kept then fewer_since = nil; return end
  -- (fewer tabs than noted: REAPER may be quitting, closing them one at a time with scripts still running in between. A Mac's plan was gone,
  -- and its loadlastproj put back, by the time REAPER had quit, so the tabs never came back. Mac test, 0.58.69. Noted once it's lasted 3 s)
  if kept_n and #tabs < kept_n then
    fewer_since = fewer_since or reaper.time_precise()
    if reaper.time_precise() - fewer_since < 3 then return end
  end
  known, fewer_since = tabs, nil
  kept, kept_n = sig, #tabs
  if startup.plan(tabs) then
    startup.last_band = { tabs = tabs, at = reaper.time_precise() } -- (for on_quit, if a quit that stalls outlasts the 3 s above)
    kept_was = held() or reaper.SNM_GetIntConfigVar("loadlastproj", 1)
    band.write_json(FILE, { tabs = tabs, loadlastproj = kept_was })
    set_open_mode(startup.no_open(kept_was))
  elseif kept_was then -- (no band song open any more: as you had it)
    set_open_mode(held())
    kept_was = nil
    os.remove(FILE)
  end
end

-- What to do at the next start, or nil: only a session with a band song in it is opened from here. Pure.
function startup.plan(tabs)
  for _, t in ipairs(tabs) do if t.band then return tabs end end
  return nil
end

-- REAPER's "Open project(s) on startup", in the low bits: 0 last active project, 1 last project tabs, 2 new project, 3 new
-- project without the default template, 4 prompt. Pure.
function startup.no_open(value) return value - value % 8 + 2 end

function startup.same_path(p) return (p:gsub("\\", "/"):lower()) end

-- What to reopen, as REAPER quits, when no plan is on disk: the tabs as last noted, or the band tabs of the last 2 minutes, which a quit
-- held up (a dialog in the way, ReaPack's report) had closed long enough for note() to take them as closed on purpose. Pure. Linux VM, 0.58.75
function startup.quit_tabs(known_tabs, last_band, now)
  if startup.plan(known_tabs) then return known_tabs end
  if last_band and now - last_band.at < 120 then return last_band.tabs end
end
function startup.on_quit()
  -- (once: Autostart reloaded on an update has asked twice, and the second time read "new project" as the person's own choice)
  if band.read_json(FILE) or not usable() then return end
  local tabs = startup.quit_tabs(known, startup.last_band, reaper.time_precise())
  if not tabs then return end
  local was = held() or reaper.SNM_GetIntConfigVar("loadlastproj", 1)
  band.write_json(FILE, { tabs = tabs, loadlastproj = was })
  set_open_mode(startup.no_open(was))
end

-- A plan kept, and REAPER's "open projects on startup" changed by something else meanwhile (a settings tool, a persona, a hand in
-- Preferences): REAPER would open the songs itself at its next start, with its boxes up. Their choice is kept in the plan for after, and the
-- setting held again. -> the value it found, or nil when all was as it should be. (lib/compat.lua's check. James, rt)
function startup.keep_open_mode()
  local plan = usable() and band.read_json(FILE)
  if type(plan) ~= "table" then return nil end
  local now = reaper.SNM_GetIntConfigVar("loadlastproj", -1)
  if now < 0 or now % 8 == 2 then return nil end
  plan.loadlastproj = now
  band.write_json(FILE, plan)
  set_open_mode(startup.no_open(now))
  return now
end

local HELPER = [==[
param([string]$BandTab, [string]$Done, [string]$Said)
Add-Type -Name W -Namespace StudioSync -MemberDefinition @"
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumChildWindows(System.IntPtr p, EnumProc f, System.IntPtr l);
[DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(System.IntPtr h, out int p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, int m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern System.IntPtr SendMessage(System.IntPtr h, int m, System.IntPtr w, System.Text.StringBuilder l);
"@
function T($h) { $b = New-Object System.Text.StringBuilder 4000; [void][StudioSync.W]::SendMessage($h, 0x000D, [IntPtr]4000, $b); "$b" }
$until = (Get-Date).AddSeconds(180)
while ((Get-Date) -lt $until -and -not (Test-Path -LiteralPath $Done)) {
  if (Test-Path -LiteralPath $BandTab) {
    $ids = @(Get-Process reaper -ErrorAction SilentlyContinue | ForEach-Object Id)
    $top = [StudioSync.W+EnumProc]{ param($h, $l)
      $p = 0; [void][StudioSync.W]::GetWindowThreadProcessId($h, [ref]$p)
      if ($ids -contains $p -and [StudioSync.W]::IsWindowVisible($h)) {
        $t = T $h
        if ($t -eq 'Replace missing file...' -or $t -eq 'Project Load Warning') {
          $want = if ($t -eq 'Project Load Warning') { 'OK' } else { 'Ignore all missing files' }
          $kid = [StudioSync.W+EnumProc]{ param($k, $m)
            $x = T $k
            if ($t -eq 'Project Load Warning' -and $x.Length -gt 40) { Add-Content -LiteralPath $Said -Value $x -Encoding UTF8 }
            if ($x -eq $want) { [void][StudioSync.W]::PostMessage($k, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) }
            $true
          }
          [void][StudioSync.W]::EnumChildWindows($h, $kid, [IntPtr]::Zero)
        }
      }
      $true
    }
    [void][StudioSync.W]::EnumWindows($top, [IntPtr]::Zero)
  }
  Start-Sleep -Milliseconds 400
}
]==]

local function start_helper()
  local tmp = (os.getenv("TEMP") or os.getenv("TMP") or DIR):gsub("\\", "/")
  local ps, cmd, vbs = tmp .. "/bandsync-answer-boxes.ps1", tmp .. "/bandsync-answer-boxes.cmd", tmp .. "/bandsync-hidden.vbs"
  band.write_atomic(ps, HELPER)
  band.write_atomic(cmd, string.format('@chcp 65001 >nul\r\n@powershell -NoProfile -ExecutionPolicy Bypass -File "%s" "%s" "%s" "%s"\r\n', ps, BAND_TAB, DONE, SAID)) -- (chcp: UTF-8 paths, as services.background. 0.58.78)
  if not reaper.file_exists(vbs) then band.write_atomic(vbs, 'CreateObject("WScript.Shell").Run """" & WScript.Arguments(0) & """", 0, False\r\n') end
  reaper.ExecProcess(string.format('wscript.exe //B //Nologo "%s" "%s"', vbs, cmd), -1)
end

-- What the load warning said, in a line for the Activity list: which plug-ins and how many files are missing here. Pure.
function startup.summary(text)
  local fx, seen = {}, {}
  for name in (text or ""):gmatch("Track %d+: ([^\r\n]+)") do
    if not seen[name] then seen[name] = true; fx[#fx + 1] = name end
  end
  local files = tonumber((text or ""):match("There were (%d+) files"))
  local bits = {}
  if #fx > 0 then bits[#bits + 1] = #fx .. " plug-in(s) this computer lacks (" .. table.concat(fx, ", ") .. "), so those parts play their prints" end
  if files then bits[#bits + 1] = files .. " file(s) missing, left offline" end
  return #bits > 0 and ("opening the studio's projects: " .. table.concat(bits, "; ")) or nil
end

-- Opening a group project while REAPER runs (Open project, a side room's square): its boxes are answered as at REAPER's start.
function startup.open_quietly(open)
  if not usable() or not windows() then return open() end -- (on a Mac a person just clicked this, and is there to answer)
  os.remove(DONE); os.remove(SAID)
  band.write_atomic(BAND_TAB, "1")
  start_helper()
  local ok, a, b = pcall(open)
  os.remove(BAND_TAB)
  band.write_atomic(DONE, "1")
  local line = startup.summary(band.read(SAID))
  if line then band.log(line) end
  if not ok then error(a) end
  return a, b
end

-- The command that hands a project to the REAPER that's running, with no boxes. Pure. exe_dir: reaper.GetExePath(); exe: the program, when
-- startup.reaper_exe found it.
function startup.hand_over(os_name, exe_dir, path, exe)
  local mac = os_name:find("^OSX") or os_name:find("^macOS")
  -- (Linux: the reaper binary sits in the folder GetExePath gives. 0.58.74)
  exe = exe or os_name:find("^Win") and (exe_dir .. "\\reaper.exe") or mac and (exe_dir .. "/REAPER.app/Contents/MacOS/REAPER") or (exe_dir .. "/reaper")
  return string.format('"%s" -nonewinst -ignoreerrors "%s"', exe, path)
end
-- The running REAPER's program on a Mac, where GetExePath() is the folder holding the app (or the app itself), whatever the bundle is called:
-- REAPER.app, REAPER64.app, "REAPER 7.app". The Mac hand-over and background prints each guessed REAPER.app, so a renamed bundle waited 20 s
-- per tab at every start and printed with the wrong REAPER, or none. (Round 1 review, 0.59.45) -> the path, or nil when none is there.
-- exists, subdirs: reaper.file_exists and a folder listing (for tests). Windows and Linux: the program beside GetExePath, as before.
local exe_found = {} -- (the Mac's answer per folder, kept: background prints listed the whole Applications folder for every print. Round 2 review, 0.59.46)
function startup.reaper_exe(os_name, exe_dir, exists, subdirs)
  local d = tostring(exe_dir or ""):gsub("\\", "/"):gsub("/+$", "")
  if os_name:find("^Win") then return d .. "/reaper.exe" end
  if not (os_name:find("^OSX") or os_name:find("^macOS")) then return d .. "/reaper" end
  if not exists and exe_found[d] ~= nil then return exe_found[d] or nil end
  local found = startup.find_exe(d, exists or reaper.file_exists, subdirs)
  if not exists then exe_found[d] = found or false end
  return found
end
function startup.find_exe(d, exists, subdirs)
  local list = { d .. "/Contents/MacOS/REAPER", d .. "/REAPER.app/Contents/MacOS/REAPER", d .. "/REAPER64.app/Contents/MacOS/REAPER" }
  for _, s in ipairs(subdirs and subdirs(d) or band.subdirs(d)) do
    if s:lower():match("^reaper.*%.app$") then list[#list + 1] = d .. "/" .. s .. "/Contents/MacOS/REAPER" end
  end
  for _, p in ipairs(list) do if exists(p) then return p end end
  return nil
end
startup.HAND_OVER_WAIT = 20 -- seconds for a project to arrive; after that it's opened the ordinary way, and its box waits for someone

-- The tabs one at a time, a pass at a time: REAPER opens a handed-over project between passes, so this can't wait in a loop.
local function hand_over_tabs(tabs, first, open, finish)
  local i, since = 0, nil
  local function front_is(path) return startup.same_path(select(2, reaper.EnumProjects(-1)) or "") == startup.same_path(path) end
  local function step()
    local t = tabs[i]
    if since then
      if not front_is(t.path) and reaper.time_precise() - since < startup.HAND_OVER_WAIT then return reaper.defer(step) end
      if not front_is(t.path) then
        band.log("REAPER didn't take " .. t.path .. " quietly: opening it the ordinary way")
        reaper.Main_openProject(t.path)
      end
      since = nil
      local here = reaper.EnumProjects(-1)
      local tb = t.band and band.binding(here)
      if tb then pcall(function() require("sync").preload(here, band.for_tab(band.settings(), tb), tb.song, tb.room) end) end
    end
    repeat i = i + 1; t = tabs[i] until not t or (reaper.file_exists(t.path) and not open[startup.same_path(t.path)])
    if not t then return finish() end
    open[startup.same_path(t.path)] = true
    if not first then reaper.Main_OnCommand(40859, 0) end -- New project tab
    first = false
    if t.band then
      -- (found once; none to hand it to, it opens the ordinary way now rather than after a 20 s wait. Round 1 review, 0.59.45)
      if startup.exe == nil then startup.exe = startup.reaper_exe(reaper.GetOS(), reaper.GetExePath()) or false end
      if startup.exe then
        since = reaper.time_precise()
        reaper.ExecProcess(startup.hand_over(reaper.GetOS(), reaper.GetExePath(), t.path, not windows() and startup.exe or nil), -1)
        return reaper.defer(step)
      end
    end
    reaper.Main_openProject(t.path) -- (a project of your own says what's wrong with it, as it always has)
    return reaper.defer(step)
  end
  step()
end

function startup.on_start(by_hand_over) -- (by_hand_over: what a Mac does, for testing it elsewhere)
  local plan = usable() and band.read_json(FILE)
  if not plan then return end
  os.remove(FILE)
  if plan.loadlastproj then set_open_mode(plan.loadlastproj) end
  os.remove(DONE); os.remove(BAND_TAB); os.remove(SAID)
  local quietly = by_hand_over or not windows()
  if not quietly then start_helper() end
  local first, front = reaper.EnumProjects(0) and select(2, reaper.EnumProjects(0)) == "" and reaper.CountTracks(reaper.EnumProjects(0)) == 0, nil
  local open = {} -- (REAPER's own reopening if the setting didn't take, or a song opened by double-clicking it: never a second tab)
  for i = 0, 512 do
    local p, fn = reaper.EnumProjects(i)
    if not p then break end
    open[startup.same_path(fn)] = true
  end
  local function back_in_front(front_path)
    for i = 0, 512 do -- (back on the tab that was in front)
      local p, fn = reaper.EnumProjects(i)
      if not p then break end
      if front_path and startup.same_path(fn) == front_path then reaper.SelectProjectInstance(p); break end
    end
  end
  if quietly then
    for _, t in ipairs(plan.tabs or {}) do if t.front then front = startup.same_path(t.path) end end
    return hand_over_tabs(plan.tabs or {}, first, open, function() back_in_front(front) end)
  end
  for _, t in ipairs(plan.tabs or {}) do
    if reaper.file_exists(t.path) and not open[startup.same_path(t.path)] then
      if t.band then band.write_atomic(BAND_TAB, "1") else os.remove(BAND_TAB) end
      if not first then reaper.Main_OnCommand(40859, 0) end -- New project tab
      first = false
      reaper.Main_openProject(t.path)
      -- (each one ready now: clicking a tab later finds it caught up, not loading while you wait)
      local here = reaper.EnumProjects(-1)
      local tb = t.band and band.binding(here)
      if tb then pcall(function() require("sync").preload(here, band.for_tab(band.settings(), tb), tb.song, tb.room) end) end
    end
    if t.front then front = startup.same_path(t.path) end
  end
  os.remove(BAND_TAB)
  band.write_atomic(DONE, "1")
  back_in_front(front)
  local line = startup.summary(band.read(SAID))
  if line then band.log(line) end
end

return startup
