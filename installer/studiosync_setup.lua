-- @noindex
-- StudioSync installer step that runs INSIDE the live REAPER, with no dialogs, so an AI installer can drive it:
--   Windows: reaper.exe -nonewinst "<this file>"      macOS: open -a /Applications/REAPER.app "<this file>"
-- It reads studiosync_setup.json next to itself and writes studiosync_setup_result.json next to itself.
-- Request: { "sync_root": "...", "user": "...", "mode": "reapack" | "folder", "repo_url": "..." }
--   reapack: add the StudioSync repository and start a ReaPack sync (installs + registers actions)
--   folder:  register every "StudioSync - *.lua" in <sync_root>/_tools/studiosync (re-run after updates)
local here = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
-- The startup block, exactly as lib/tools.lua startup_block writes it (this step runs on its own, before StudioSync's lib can be loaded;
-- tests/test_0_59_46_trust.lua checks the two are the same). Round 2 review, 0.59.46
local MARK_A, MARK_Z, CURRENT = "-- BandSync autostart", "-- /BandSync autostart", "StudioSync didn't start: "
local function startup_block(dirs)
  local list = {}
  for _, d in ipairs(dirs) do list[#list + 1] = "[[" .. d .. "/StudioSync - Autostart.lua]]" end
  return MARK_A .. "\n" ..
    "do local was, path, finders, started, last = {}, package.path, { table.unpack(package.searchers) }, false, nil\n" ..
    "  for k in pairs(package.loaded) do was[k] = true end\n" ..
    "  for _, f in ipairs({ " .. table.concat(list, ", ") .. " }) do\n" ..
    "    if reaper.file_exists(f) then\n" ..
    "      local ok, err = pcall(dofile, f)\n" ..
    "      if ok then started = true break end\n" ..
    "      last = f .. \": \" .. tostring(err):sub(1, 300)\n" ..
    "      reaper.SetExtState(\"BandSync\", \"startup failed\", last, false)\n" ..
    "      for k in pairs(package.loaded) do if not was[k] then package.loaded[k] = nil end end\n" ..
    "      for i = #package.searchers, 1, -1 do package.searchers[i] = nil end\n" ..
    "      for i, s in ipairs(finders) do package.searchers[i] = s end\n" ..
    "      package.path = path\n" ..
    "    end\n" ..
    "  end\n" ..
    "  if not started and last then reaper.ShowConsoleMsg(\"" .. CURRENT .. "\" .. last .. \"\\n\") end\n" ..
    "end\n" .. MARK_Z .. "\n"
end

do -- first: the installer waits for this before handing the step over again (a REAPER already open sometimes misses the first)
  -- (and a second hand-off that arrives after all runs nothing: two copies would sync ReaPack twice. Review, 0.58.67)
  local was = io.open(here .. "/studiosync_setup_started", "r")
  local at = was and tonumber(was:read("a")); if was then was:close() end
  if at and os.time() - at < 600 then return end
  local s = io.open(here .. "/studiosync_setup_started", "w")
  if s then s:write(tostring(os.time())); s:close() end
end
-- chmaha's "DSP to JSFX": the effects and instruments REAPER 7.83 bundled and 7.84 removed (drum kits, MDA piano and
-- e-piano, organ, channel strip, tuner, limiter...), GPL-3.0 with MIT/AGPL parts; new in Oct 2026, still changing
local JSFX_REPOS = { { "Saike", "https://raw.githubusercontent.com/JoepVanlier/JSFX/master/index.xml" },
                     { "Chokehold", "https://github.com/chkhld/jsfx/raw/main/index.xml" },
                     { "DSP to JSFX (chmaha)", "https://github.com/chmaha/DSP-Ports-JSFX/raw/main/index.xml" } }
package.path = here .. "/../lib/?.lua;" .. package.path
local json = require("json")

local out = { ok = true, steps = {} }
local function step(name, ok, detail)
  out.steps[#out.steps + 1] = { name = name, ok = ok, detail = detail and tostring(detail) or "" }
  if not ok then out.ok = false end
end
local function finish()
  local f = io.open(here .. "/studiosync_setup_result.json", "w")
  if f then f:write(json.encode(out, true)); f:close() end
end

local f = io.open(here .. "/studiosync_setup.json", "r")
if not f then step("read request", false, here .. "/studiosync_setup.json missing"); return finish() end
local ok, req = pcall(json.decode, f:read("a"))
f:close()
if not ok or type(req) ~= "table" then step("read request", false, req); return finish() end

local ver = reaper.GetAppVersion()
local major, minor = ver:match("^(%d+)%.(%d+)")
step("REAPER 7.18 or newer", tonumber(major) > 7 or (tonumber(major) == 7 and tonumber(minor) >= 18), ver)

local root = (req.sync_root or ""):gsub("\\", "/"):gsub("/+$", "")
local probe = io.open(root .. "/.bandsync-write-test", "w")
if probe then probe:close(); os.remove(root .. "/.bandsync-write-test") end
step("shared folder writable", probe ~= nil, root)
local user = (req.user or ""):gsub("[^%w%-_ ]", "")
step("name", user ~= "", user)
-- (the studio registered here counted as one from before 0.58.47, and a first-day bandmate saw every advanced control. Onboarding review, 0.59.9)
if reaper.GetExtState("BandSync", "show advanced") == "" then reaper.SetExtState("BandSync", "show advanced", "0", true) end
if probe and user ~= "" then
  -- joining another band: the band this computer was in stays one of its bands (Setup > Options > Bands)
  local was, bands = reaper.GetExtState("BandSync", "sync_root"), reaper.GetExtState("BandSync", "bands")
  local list = {}
  for r in bands:gmatch("[^|]+") do list[#list + 1] = r end
  for _, r in ipairs({ was, root }) do
    local have = false
    for _, x in ipairs(list) do if x == r then have = true end end
    if r ~= "" and not have then list[#list + 1] = r end
  end
  reaper.SetExtState("BandSync", "bands", table.concat(list, "|"), true)
  reaper.SetExtState("BandSync", "sync_root", root, true)
  reaper.SetExtState("BandSync", "user", user, true)
  -- (an invitation's studio by its name until its own _band/band.json arrives, as services.join_band keeps it: a joiner not let in yet saw
  -- "the studio" instead of its name. Windows Sandbox run, 0.58.78)
  local bid = type(req.band_id) == "string" and req.band_id:lower() or ""
  if (bid == "bandsync" or bid:match("^bandsync%-[%w%-]+$") or bid:match("^studiosync%-[%w%-]+$")) and not reaper.file_exists(root .. "/_band/band.json") then
    local bname = (type(req.band_name) == "string" and req.band_name or ""):gsub("[^%w%-_ ]", "")
    reaper.SetExtState("BandSync", "joining " .. root, json.encode({ name = bname ~= "" and bname or nil, id = bid }), true)
  end
  -- (an invitation's studio: its Syncthing folder id, which lib/band.lua goes by whatever band.json later says, and the computer that sent it,
  -- the only one whose writing of the roles a first look believes (lib/trust.lua). The keys are the ones those modules read. Security review, 0.58.78)
  local ID = "^" .. ("[%u%d]"):rep(7) .. ("%-" .. ("[%u%d]"):rep(7)):rep(7) .. "$"
  if type(req.host_id) == "string" and req.host_id:match(ID) and type(req.band_id) == "string" and req.band_id:match("^[%w%-_.]+$") then
    reaper.SetExtState("BandSync", "invited by " .. root:lower(), req.host_id, true)
    reaper.SetExtState("BandSync", "band id " .. root:lower(), req.band_id, true)
  end
end
-- Which Syncthing the installer set up, and its settings folder when that isn't where Syncthing looks by itself (SyncTrayzor's, a snap's, a
-- Flatpak REAPER's sandbox looks elsewhere): lib/services.lua runs that one, never a second. An empty home clears an old one. (Installer review, 0.58.78)
if type(req.syncthing_path) == "string" and req.syncthing_path ~= "" then reaper.SetExtState("BandSync", "syncthing_path", req.syncthing_path, true) end
if type(req.syncthing_home) == "string" then
  if req.syncthing_home ~= "" then reaper.SetExtState("BandSync", "syncthing_home", req.syncthing_home, true) else reaper.DeleteExtState("BandSync", "syncthing_home", true) end
end
-- REAPER's "save recorded media?" box after each take (Preferences > Recording; on by default on some systems): a take waits there, unsent, and
-- "Delete all" loses it. Off, every take is kept and goes out as it stops. Band-test review, 0.58.67. (promptendrec, read 0 on the PC with SWS)
if reaper.SNM_GetIntConfigVar and reaper.SNM_GetIntConfigVar("promptendrec", 0) ~= 0 then
  step("REAPER keeps each take without asking (Preferences > Recording)", reaper.SNM_SetIntConfigVar("promptendrec", 0) == true, "it asked to save or delete every take")
end

-- The VERSION in a StudioSync lib/band.lua, or nil.
local function version_in(path)
  local vf = path and io.open(path, "r")
  local v = vf and vf:read("a"):match('VERSION%s*=%s*"([^"]+)"')
  if vf then vf:close() end
  return v
end
-- This installer's StudioSync (the copy it came in), and the one REAPER runs now (where its Live sync action points).
local WANT = version_in(here .. "/../lib/band.lua")
local function installed_version()
  local kb = io.open(reaper.GetResourcePath() .. "/reaper-kb.ini", "r")
  local text = kb and kb:read("a") or ""
  if kb then kb:close() end
  local live = text:match('"[^"]*StudioSync %- Live sync%.lua" "([^"]+)"')
  if not live then return nil end
  live = live:gsub("\\", "/")
  if not live:match("^/") and not live:match("^%a:") then live = reaper.GetResourcePath() .. "/Scripts/" .. live end
  return version_in(live:match("^(.*)/") .. "/lib/band.lua")
end

-- StudioSync already up to date through ReaPack (the repository set, this installer's version installed, and every
-- requested JSFX repository there)? Then ReaPack is left alone: starting a ReaPack sync while its Transaction report
-- window is open crashes REAPER on macOS (2026-10-28), and a re-run is exactly when that window may still be up.
-- (Until 0.34.4 any registered StudioSync counted: a Mac on 0.13.4 re-ran the installer, was told OK, and stayed on
-- 0.13.4 without the plug-in pack's JSFX.)
-- The other ReaPack repositories asked for: the plug-in pack's JSFX, and ReaPersona (REAPER set up to feel like the DAW you came from, by the
-- same people: github.com/FmsJay/ReaPersona, GPL) for someone moving from another DAW.
local function extra_repos()
  local t = {}
  if req.jsfx then for _, r in ipairs(JSFX_REPOS) do t[#t + 1] = r end end
  if req.reapersona then t[#t + 1] = { "ReaPersona", "https://raw.githubusercontent.com/FmsJay/ReaPersona/main/index.xml" } end
  return t
end
local function already_installed()
  if not reaper.APIExists("ReaPack_GetRepositoryInfo") then return false end
  local ok, url = reaper.ReaPack_GetRepositoryInfo("StudioSync")
  if not ok or url ~= req.repo_url then return false end
  if not WANT or installed_version() ~= WANT then return false end
  for _, r in ipairs(extra_repos()) do if not reaper.ReaPack_GetRepositoryInfo(r[1]) then return false end end
  return true
end

-- The plug-in pack's JSFX without StudioSync's own ReaPack sync to ride along with: a sync of their own, only when
-- one of them is missing (a re-run with all there leaves ReaPack alone, see above).
local function jsfx_only()
  if not (#extra_repos() > 0 and reaper.APIExists("ReaPack_AddSetRepository")) then return end
  local added = false
  for _, r in ipairs(extra_repos()) do
    local have = reaper.APIExists("ReaPack_GetRepositoryInfo") and reaper.ReaPack_GetRepositoryInfo(r[1])
    if not have then
      local ok_r, e = reaper.ReaPack_AddSetRepository(r[1], r[2], true, 1)
      step("add " .. r[1] .. " repository", ok_r, e ~= "" and e or r[2])
      added = added or ok_r
    end
  end
  if added then
    reaper.ReaPack_ProcessQueue(true)
    local sync = reaper.NamedCommandLookup("_REAPACK_SYNC")
    if sync ~= 0 then reaper.Main_OnCommand(sync, 0) end
  end
end
-- This version already runs here from somewhere other than ReaPack (the band folder's staged copy, a checkout): a
-- ReaPack copy beside it gave the laptop two of every action and two Live syncs to choose from (0.35.1).
local function runs_elsewhere()
  local ok = reaper.APIExists("ReaPack_GetRepositoryInfo") and reaper.ReaPack_GetRepositoryInfo("StudioSync")
  return not ok and WANT ~= nil and installed_version() == WANT
end

if req.mode == "reapack" then
  if not reaper.APIExists("ReaPack_AddSetRepository") then
    step("ReaPack installed", false, "install ReaPack (reapack.com) and restart REAPER first")
  elseif already_installed() then
    step("StudioSync " .. WANT .. " already installed through ReaPack", true, "left as it is")
    req.mode, req.open_panel = "verify", true -- nothing to wait for; land in the panel (it stayed shut, Mac 0.34.3)
  elseif runs_elsewhere() then
    step("StudioSync " .. WANT .. " already runs here", true, "left as it is: no second copy")
    jsfx_only()
    req.mode, req.open_panel = "verify", true
  else
    do -- (the same index under its old name would install everything twice. Its files stay until uninstalled in ReaPack's window)
      local had, old_url = reaper.ReaPack_GetRepositoryInfo("BandSync")
      if had then reaper.ReaPack_AddSetRepository("BandSync", old_url, false, 0) end
    end
    local added, err = reaper.ReaPack_AddSetRepository("StudioSync", req.repo_url or "", true, 1) -- 1: auto-install on sync
    step("add StudioSync repository", added, err ~= "" and err or req.repo_url)
    for _, r in ipairs(extra_repos()) do -- the plug-in pack's JSFX, ReaPersona: in this same ReaPack sync, never one of their own (see above)
      local ok_r, e = reaper.ReaPack_AddSetRepository(r[1], r[2], true, 1)
      step("add " .. r[1] .. " repository", ok_r, e ~= "" and e or r[2])
    end
    reaper.ReaPack_ProcessQueue(true)
    local sync = reaper.NamedCommandLookup("_REAPACK_SYNC")
    if added and sync ~= 0 then reaper.Main_OnCommand(sync, 0) end
    step("ReaPack sync started", sync ~= 0, "asynchronous: re-run with mode \"verify\" in a minute")
  end
elseif req.mode == "folder" then
  local dir, scripts, i = root .. "/_tools/studiosync", {}, 0
  reaper.EnumerateFiles(dir, -1)
  while true do
    local name = reaper.EnumerateFiles(dir, i)
    if not name then break end
    if name:match("^StudioSync %- .+%.lua$") then scripts[#scripts + 1] = dir .. "/" .. name end
    i = i + 1
  end
  for n, path in ipairs(scripts) do reaper.AddRemoveReaScript(true, 0, path, n == #scripts) end
  step("register actions from shared folder", #scripts > 0, #scripts .. " scripts in " .. dir)
  jsfx_only() -- (StudioSync came from the folder: no StudioSync ReaPack sync for the JSFX to ride along with)
end

-- What's registered now, autostart, the result file, and the panel. With ReaPack, run once its sync has brought the
-- scripts: this script waits for that INSIDE REAPER. The installer used to ask REAPER to run it again every 10 s,
-- and on macOS a request arriving while ReaPack's report window was open crashed REAPER (2026-10-28): now there's
-- one request per installer run.
local waiting = false

-- ReaPersona as the DAW picked in the installer, all in one go (James, 0.58.64: opting in should set it up and pick the right DAW). Its look,
-- mouse and toggles go on now, with the startup line that keeps them; its shortcut layers go into REAPER's keymap through its own
-- install_shortcuts.py, which needs REAPER closed: REAPER restarts once, about 10 seconds (persona_keys, after the result is written).
-- Without Python, ReaPersona's own staged install does the same (a cmd or sh step swaps the keymap in once REAPER has closed). -> the core, or nil.
local function persona_core()
  local base = reaper.GetResourcePath() .. "/Scripts/ReaPersona"
  for _, d in ipairs({ base .. "/Workflow", base, base .. "/ReaPersona" }) do
    if reaper.file_exists(d .. "/reapersona_core.lua") then
      local ok, core = pcall(dofile, d .. "/reapersona_core.lua")
      if ok and type(core) == "table" then return core end
    end
  end
end
-- ReaPersona comes in the same ReaPack sync, and often lands after StudioSync's actions: the setup looked, found nothing and said "hasn't
-- arrived yet" seconds before it did (Mac test, 0.58.68). With a DAW picked, `then_do` waits for it, up to two and a half minutes.
local function persona_wait(then_do)
  local want = type(req.persona) == "string" and req.persona:match("^[%w_]+$")
  local base, started = reaper.GetResourcePath() .. "/Scripts/ReaPersona", reaper.time_precise()
  local function here_now()
    for _, d in ipairs({ base .. "/Workflow", base, base .. "/ReaPersona" }) do if reaper.file_exists(d .. "/reapersona_core.lua") then return true end end
  end
  local function look()
    if not want or here_now() or reaper.time_precise() - started > 150 then return then_do() end
    reaper.defer(look)
  end
  look()
end
local function persona_apply(id)
  local core = persona_core()
  if not core then out.persona_note = "ReaPersona hasn't arrived yet: in REAPER, Extensions > ReaPack > Synchronize packages, then Actions > ReaPersona to pick your DAW."; return end
  local st = core.by_id(id)
  if not st then out.persona_note = "ReaPersona doesn't know '" .. id .. "': open it (Actions > ReaPersona) and pick your DAW."; return end
  local ok, err = pcall(function()
    if core.scripts_missing() > 0 then core.ensure_scripts() end -- (the scripts its keys run, registered before the keys go in)
    core.use(st)
    if not core.startup_on() then core.add_startup() end -- (REAPER forgets the shortcut layer at a restart: this brings it back)
    reaper.SetExtState(core.SECTION, "welcomed", "1", true) -- (its first-run "which DAW?" is answered)
  end)
  if not ok then out.persona_note = "ReaPersona couldn't switch to " .. st.name .. " (" .. tostring(err) .. "): open it (Actions > ReaPersona) and pick it there."; return end
  out.persona = st.name
  -- (on a Mac without the developer tools, /usr/bin/python3 is a stub that pops up an install offer: asked only where a real one is)
  local real_py = not core.IS_MAC or (reaper.ExecProcess("/bin/sh -c 'command -v python3 | grep -qv ^/usr/bin/ || xcode-select -p'", 5000) or ""):match("^0\n")
  local unsaved = false -- (REAPER was in use: quitting it asks about unsaved work, and a Cancel left the shortcuts waiting for good. Review, 0.58.67)
  for i = 0, 99 do local p, fn = reaper.EnumProjects(i); if not p then break end; if reaper.IsProjectDirty(p) ~= 0 and (fn ~= "" or reaper.CountTracks(p) > 0) then unsaved = true end end
  -- (without Python, ReaPersona 5.14+ plans the same install inside REAPER and a cmd/sh step swaps it in once REAPER has closed: core.stage_install)
  local py_ok = real_py and core.python()
  if not unsaved and (py_ok or core.stage_install) then
    out.persona_keys = py_ok and "restart" or "staged"
    out.persona_note = "ReaPersona: REAPER now looks and clicks like " .. st.name .. ". It restarts once, by itself, to load " .. st.name .. "'s shortcuts."
  else
    out.persona_note = "ReaPersona: REAPER now looks and clicks like " .. st.name .. ". For its shortcuts: open ReaPersona (Actions > ReaPersona), Home, Install (one step, it explains)."
  end
  return core
end
local function persona_keys(core)
  local here_p = core.here
  if not reaper.file_exists(here_p .. "/midi_defaults.json") then core.midi_defaults() end
  -- (on a Mac GetExePath() is the folder holding REAPER.app, "/Applications", not a path inside it: matching ".app" in it found nothing, REAPER
  -- quit and was never started again. Mac review, 0.58.67. install_shortcuts.py opens a .app with `open -a`)
  local d = reaper.GetExePath():gsub("\\", "/"):gsub("/+$", "")
  local exe = d .. (reaper.GetOS():find("^Win") and "/reaper.exe" or "/reaper") -- (Linux: the reaper binary beside it)
  if core.IS_MAC then
    exe = d:match("^(.-%.app)") or d .. "/REAPER.app"
    for _, a in ipairs({ d .. "/REAPER.app", d .. "/REAPER64.app" }) do if not d:match("%.app") and reaper.file_exists(a .. "/Contents/Info.plist") then exe = a; break end end
  end
  local cfg = reaper.get_ini_file():gsub("\\", "/") -- (a test REAPER with its own -cfgfile comes back on it)
  if out.persona_keys == "staged" then
    local step, why = core.stage_install({ pid = core.reaper_pid(), exe = exe, cfg = cfg, projects = {} })
    if not step then return end -- (persona_note already says how to install from ReaPersona's Home; nothing changes and REAPER stays open)
    if reaper.GetOS():find("^Win") then
      reaper.ExecProcess('cmd.exe /c ""' .. step:gsub("/", "\\") .. '""', -2) -- (-2: minimized, as ReaPersona runs it)
    else
      reaper.ExecProcess('/bin/sh "' .. step .. '"', -1) -- (it starts itself again detached from REAPER and returns)
    end
  else
    reaper.ExecProcess(core.py .. ' "' .. here_p .. '/install_shortcuts.py" --after-reaper-quits --relaunch "' .. exe .. '" --cfgfile "' .. cfg .. '"', -1) -- (-1: don't wait)
  end
  reaper.SetExtState("BandSync", "open panel at start", "1", true) -- (StudioSync - Autostart opens the panel when REAPER is back)
  reaper.Main_OnCommand(40004, 0) -- File: Quit (REAPER's own save prompt for anything unsaved); install_shortcuts.py starts it again
end

local function conclude()
  -- optional: the control panel needs ReaImGui (ReaTeam Extensions repository, which ReaPack has by default)
  out.reaimgui = reaper.APIExists("ImGui_GetBuiltinPath")

  -- verify: which StudioSync actions does REAPER have registered right now?
  local kb = io.open(reaper.GetResourcePath() .. "/reaper-kb.ini", "r")
  local count, text = 0, kb and kb:read("a") or ""
  if kb then kb:close() end
  for _ in text:gmatch('SCR %d+ %d+ %S+ "[^"]*StudioSync %- [^"]*"') do count = count + 1 end
  out.registered_actions = count
  out.version = installed_version()
  step("StudioSync actions registered", count >= 5, count)

  -- Live sync starts again with REAPER for a session where it was running (Scripts/__startup.lua runs StudioSync -
  -- Autostart, the panel's "Start Live sync with REAPER"). Without it, a REAPER restart (this installer does one)
  -- left Live sync off and changes silently stayed here (Mac, 2026-10-28). Same block as lib/tools.lua writes.
  local live = text:match('"[^"]*StudioSync %- Live sync%.lua" "([^"]+)"')
  if live and count >= 5 then
    live = live:gsub("\\", "/")
    if not live:match("^/") and not live:match("^%a:") then live = reaper.GetResourcePath() .. "/Scripts/" .. live end
    local sdir = live:match("^(.*)/")
    local startup = reaper.GetResourcePath() .. "/Scripts/__startup.lua"
    local sf = io.open(startup, "r")
    local cur = sf and sf:read("a") or (not reaper.file_exists(startup) and "" or nil) -- (there but unreadable: left alone, not written over with only ours)
    if sf then sf:close() end
    if cur and not cur:find(sdir .. "/StudioSync - Autostart.lua", 1, true) and reaper.file_exists(sdir .. "/StudioSync - Autostart.lua") then
      -- (a block from before the rename, or from another copy, makes way)
      -- (and the new block goes where it was, appended only when there was none: lib/tools.lua place_block. Round 3 review, 0.59.48)
      local a = cur:find("-- BandSync autostart", 1, true)
      local z = a and cur:find("-- /BandSync autostart", a, true)
      local after
      if z then cur, after = cur:sub(1, a - 1), cur:sub(z + #"-- /BandSync autostart" + 1):gsub("^\r?\n", "", 1) end
      -- (written beside it, then swapped in: cut off half way, the person's own startup scripts were gone)
      local tmp, old = startup .. ".studiosync.tmp", startup .. ".studiosync.old"
      local wf = io.open(tmp, "w")
      -- (the block lib/tools.lua startup_block writes, by a copy of it at the top of this file: each copy in a pcall, this one and then this
      -- computer's last-good copy, so a copy that fails to load doesn't stop what follows in __startup.lua. Round 1 review, 0.59.45)
      local res = reaper.GetResourcePath():gsub("\\", "/")
      local home = (reaper.EnumerateSubdirectories(res .. "/BandSync", 0) or reaper.EnumerateFiles(res .. "/BandSync", 0)) and (res .. "/BandSync") or (res .. "/StudioSync")
      local block = startup_block({ sdir, home .. "/last good" })
      local wrote = wf and wf:write(after and (cur .. block .. after) or (cur .. (cur ~= "" and not cur:match("\n$") and "\n" or "") .. block))
      if wf then wf:close() end
      local placed = wrote and os.rename(tmp, startup) -- (Windows won't rename over a file: the old one steps aside first)
      if wrote and not placed then
        os.remove(old)
        if os.rename(startup, old) then
          placed = os.rename(tmp, startup)
          if placed then os.remove(old) else os.rename(old, startup) end
        end
      end
      os.remove(tmp)
      if placed then dofile(sdir .. "/StudioSync - Autostart.lua") end -- and now, for this REAPER session (it just restarted without it)
    end
    local again = io.open(startup, "r")
    local on = again and again:read("a"):find("-- BandSync autostart", 1, true) ~= nil
    if again then again:close() end
    step("Live sync starts with REAPER", on, startup)
  end
  local persona = type(req.persona) == "string" and req.persona:match("^[%w_]+$") and persona_apply(req.persona)
  finish()
  if persona and (out.persona_keys == "restart" or out.persona_keys == "staged") then return reaper.defer(function() persona_keys(persona) end) end -- (the panel opens after the restart, from autostart)

  -- open_panel: land the musician in the panel, whose first screen offers to publish or open a session
  if (req.open_panel or waiting) and count >= 5 and out.reaimgui then
    local id = text:match('SCR %d+ %d+ (%S+) "[^"]*StudioSync %- Panel%.lua"')
    local cmd = id and reaper.NamedCommandLookup("_" .. id) or 0
    -- (not while ReaPack's Transaction report is up: a panel opened under it never finished a frame and grew REAPER to 7.4 GB, till Linux
    -- killed it. Linux stress test, 0.58.77)
    local function open_panel()
      if reaper.JS_Window_Find and reaper.JS_Window_Find("Transaction report", false) then return reaper.defer(open_panel) end
      if reaper.GetToggleCommandState(cmd) ~= 1 then reaper.Main_OnCommand(cmd, 0) end
    end
    if cmd ~= 0 then open_panel() end
  end
end

local function registered()
  local kb = io.open(reaper.GetResourcePath() .. "/reaper-kb.ini", "r")
  local n, text = 0, kb and kb:read("a") or ""
  if kb then kb:close() end
  for _ in text:gmatch('SCR %d+ %d+ %S+ "[^"]*StudioSync %- [^"]*"') do n = n + 1 end
  return n
end
if req.mode == "reapack" and out.ok then
  waiting = true
  local started, last, same, at = reaper.time_precise(), -1, 0, 0
  local function wait()
    if reaper.time_precise() - at < 2 then return reaper.defer(wait) end
    at = reaper.time_precise()
    local n = registered()
    -- arrived (this installer's version, when an older one was there: its actions were registered all along), and
    -- nothing more for a moment
    if n >= 5 and n == last and (not WANT or installed_version() == WANT) then same = same + 1 else same = 0 end
    last = n
    if same >= 2 or reaper.time_precise() - started > 240 then return persona_wait(conclude) end
    reaper.defer(wait)
  end
  reaper.defer(wait)
else
  persona_wait(conclude)
end
