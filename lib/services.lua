-- The background programs StudioSync leans on, started when a session needs them (never at login):
--   Syncthing   moves the shared folder; Live sync makes sure it runs on every machine
--   ninjamsrv   the NINJAM server: it ships in lib/ninjam, and the computer that needs it first runs it
-- Paths can be set in ExtState (section StudioSync: syncthing_path, ninjam_dir); otherwise the usual install
-- locations are tried.
local band = require("band")
local services = {}

local WIN = reaper.GetOS():match("^Win") ~= nil

local function q(s) return '"' .. s .. '"' end
-- Syncthing's settings folder when it isn't where Syncthing looks by itself (a snap, a portable SyncTrayzor, a --home, a Flatpak REAPER's own
-- XDG folders): the installer finds the one that runs and keeps it here, so every `syncthing cli`, the API key and a start reach that
-- Syncthing, never a second one with a second identity. (Installer review, 0.58.78)
local function st_home() local h = reaper.GetExtState(band.SECTION, "syncthing_home"); return h ~= "" and h or nil end
local function cli(st) return q(st) .. " cli" .. (st_home() and (" --home " .. q(st_home())) or "") end
-- A shell's single quotes (macOS, Linux): ' is written '\''. A user name like O'Brien broke the scripts.
local function sh_q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
-- A folder label on a command line: quotes and shell characters out (a studio name comes from the shared band.json). Review, 0.58.92
local function label_q(s) return q((tostring(s):gsub('["`$\\%%]', ""))) end
-- Syncthing's command line and API, with a back-off: when a call runs into its time limit, Syncthing is hung or still starting, and the
-- next dozen each waited out their own limit with REAPER frozen (a removal, at start: tens of seconds, again every 30 s). For a minute after,
-- they answer nothing at once. Review, 0.58.92
-- Only questions wait: a change (add, delete, set) always goes, or one slow look blocked pairing a new bandmate and the folder's settings. A
-- timeout is what REAPER hands back then: "259" (still running) on Windows, curl's own "28" for its -m, or simply the whole limit gone. Measured,
-- 0.58.93: the first version waited for an empty answer, which never came.
local stuck_until = {}
local function exec(cmd, ms, key)
  key = key or "cli"
  local t0 = reaper.time_precise()
  local change = cmd:find(" add ", 1, true) or cmd:find(" delete", 1, true) or cmd:find(" set ", 1, true)
  if not change and (stuck_until[key] or 0) > t0 then return nil end
  local r = reaper.ExecProcess(cmd, ms)
  local hung = ms > 0 and (reaper.time_precise() - t0 >= ms / 1000 * 0.9 or (type(r) == "string" and (r:match("^259\n") or r:match("^28\n"))))
  if hung then
    if (stuck_until[key] or 0) <= reaper.time_precise() then band.log("Syncthing didn't answer within " .. math.floor(ms / 1000) .. " s: StudioSync leaves it alone for a minute") end
    stuck_until[key] = reaper.time_precise() + 60
  end
  return r
end

-- Slow checks (tasklist ~150 ms, a curl call up to 3 s) run in the background: REAPER waiting on them froze
-- its UI for 0.3-0.4 s at every panel refresh (2026-10-28, laptop). Each call starts a fresh run at most every
-- `every` seconds, its output going to a file, and returns what the previous run wrote (nil before the first).
-- (macOS: the per-user TMPDIR, not the shared /tmp: the Syncthing check's script carries its API key. Linux: the per-user runtime folder, for
-- the same reason: the key sat in a /tmp file anyone could read. Linux stress test, 0.58.77)
local TMP = (WIN and (os.getenv("TEMP") or os.getenv("TMP")) or os.getenv("TMPDIR") or os.getenv("XDG_RUNTIME_DIR") or "/tmp"):gsub("\\", "/"):gsub("/+$", "")
local started, last = {}, {}
local function background(name, cmd, every)
  local file = TMP .. "/bandsync-" .. name .. ".txt"
  -- read before starting the next run: a run truncates its file as it starts, and read after that, every call that started one handed back an answer from
  -- long before (only port_open calls so seldom that each starts one: a closed server read as answering. Mac, 0.58.22)
  local out = band.read(file)
  if out and out:match("%S") then last[name] = out end
  if not started[name] or reaper.time_precise() - started[name] > every then
    started[name] = reaper.time_precise()
    -- shortcut: written in place (these outputs are a few hundred bytes); a half-written read just looks like "no answer" once
    if WIN then -- through a hidden-window runner: `cmd /c` without waiting flashes a console window (seen 0.9.7)
      local bat, vbs = TMP .. "/bandsync-" .. name .. ".cmd", TMP .. "/bandsync-hidden.vbs"
      -- (the script deletes itself once run: some hold Syncthing's API key, and after a crash tidy_temp never ran. Review, 0.58.53)
      -- (a batch file reads %2 as its argument: a rescan of "Sunset%20Drive" asked for the wrong folder. Cross-platform review, 0.58.76)
      -- (chcp 65001: cmd reads a batch file in the console's old code page, so a Windows user name like "Jürgen" in %TEMP% or Syncthing's
      -- path came out garbled and nothing ran. Cross-platform review, 0.58.78)
      pcall(band.write_atomic, bat, string.format('@chcp 65001 >nul\r\n@%s > "%s" 2>nul\r\n@(goto) 2>nul & del "%%~f0"\r\n', (cmd:gsub("%%", "%%%%")), file)) -- (its last run may still hold it, from another script: the same words are there already)
      if not reaper.file_exists(vbs) then band.write_atomic(vbs, 'CreateObject("WScript.Shell").Run """" & WScript.Arguments(0) & """", 0, False\r\n') end
      reaper.ExecProcess(string.format('wscript.exe //B //Nologo "%s" "%s"', vbs, bat), -1)
    else -- through a script file too: macOS's ExecProcess doesn't honour \" inside a quoted argument, so any command
      -- with quotes in it (the curl's -H "X-API-Key: ...") silently never ran (Mac, 2026-10-28). Grouped, so the
      -- whole command's output lands in the file, not only the part after a ||.
      local sh = TMP .. "/bandsync-" .. name .. ".sh"
      -- (TAILSCALE_BE_CLI: Tailscale's Mac app answers as its command line only when it can tell it was started from one. Mac review, 0.58.62)
      band.write_atomic(sh, "export TAILSCALE_BE_CLI=1\n{ " .. cmd .. "; } > '" .. file .. "' 2>/dev/null\nrm -f \"$0\"\n")
      reaper.ExecProcess("/bin/sh '" .. sh .. "'", -1)
    end
  end
  return last[name]
end
services.background, services.TMP = background, TMP -- (lib/alerts.lua sends through it)

-- When REAPER quits: the background scripts and config files StudioSync left in the temp folder go (some hold Syncthing's API key or a
-- Tailscale token: they stayed there for good. Review, 0.58.52). Each is made again when it's next needed.
function services.tidy_temp()
  for _, f in ipairs(band.files(TMP)) do
    if f:match("^bandsync%-.+%.[%a]+$") and (f:match("%.cmd$") or f:match("%.sh$") or f:match("%.cfg$") or f:match("%.txt$") or f:match("%.done$") or f:match("%.nobin$") or f:match("%.ps1$") or f:match("%.json$")) then os.remove(TMP .. "/" .. f) end -- (.done/.nobin/.ps1: the Recycle Bin moves; .json: alerts. Review, 0.58.62)
  end
end

-- Whether a process named `exe` (e.g. "syncthing") is running. Answers from the last background check
-- (at most ~15 s old); the very first time, it waits for one.
-- `fresh`: ask now and wait (the background answer can be up to 15 s old: before starting something, that's too old)
function services.running(exe, fresh)
  local out = not fresh and background("ps-" .. exe, WIN and ('tasklist /FI "IMAGENAME eq ' .. exe .. '.exe" /NH') or ("/usr/bin/pgrep -x " .. exe .. " || echo none"), 15)
  if not out then -- nothing yet: ask once and wait
    out = reaper.ExecProcess(WIN and ('tasklist /FI "IMAGENAME eq ' .. exe .. '.exe" /NH') or ("/usr/bin/pgrep -x " .. exe), 5000) or ""
    if not WIN then return out:match("^0\n") ~= nil end
  end
  if WIN then return out:lower():find(exe:lower() .. ".exe", 1, true) ~= nil end
  return out:match("%d") ~= nil -- pgrep prints the pids
end

local NC_WAIT = band.LINUX and "-w" or "-G" -- (netcat's connect timeout: -G on a Mac, -w on Linux, which has no -G)
-- Does something answer at "host:port"? In the background, for a loop (services.answers waits for it). True only once two runs in a row said so: a call
-- hands back the previous run's answer, and the first after a while was from before a server stopped, which pressed Connect at nothing (Mac, 0.58.21).
local runs = {}
function services.port_open(address)
  local host, port = address:match("^(.-):(%d+)$")
  if not host then return false end
  host = host:gsub("[^%w%.%-]", "") -- (and each address has its own answer: one file for all read a dead host as up)
  local name, open = "port-" .. host .. "-" .. port, nil
  if WIN then -- (as services.answers; %% is a batch file's %)
    open = (tonumber((background(name, 'curl -s -o NUL -m 3 -w %{time_connect} "http://' .. host .. ":" .. port .. '/"', 3) or ""):match("[%d%.]+")) or 0) > 0
  elseif band.LINUX then -- (curl, as on Windows: some distros have no netcat, and every live server read as gone. Cross-platform review, 0.58.76)
    open = (tonumber((background(name, "curl -s -o /dev/null -m 3 -w '%{time_connect}' 'http://" .. host .. ":" .. port .. "/'", 3) or ""):match("[%d%.]+")) or 0) > 0
  else
    open = (background(name, "/usr/bin/nc -z " .. NC_WAIT .. " 3 '" .. host .. "' " .. port .. " && echo open || echo shut", 3) or ""):find("open", 1, true) ~= nil
  end
  local r = runs[name] or {}
  runs[name] = r
  if r.run ~= started[name] then r.run, r.n = started[name], open and (r.n or 0) + 1 or 0 end
  return (r.n or 0) >= 2
end

-- The same, asked now and waited for (a second or so): for a button's press, not a loop.
function services.answers(address)
  local host, port = address:match("^(.-):(%d+)$")
  if not host then return false end
  host = host:gsub("[^%w%.%-]", "")
  -- (as http, though nothing here speaks it: telnet:// ignores curl's -m once connected, and REAPER waited on it for good. And by the time it connected, since
  -- its exit code can't tell: 28 is both "connected, and nothing came in a second" and "nobody there", which is what an offline Tailscale machine does)
  -- (3 s: Tailscale's first packets to a computer that's been quiet can take over 1, and a live host then read as gone and was taken over)
  if WIN then return (tonumber((reaper.ExecProcess('curl -s -o NUL -m 3 -w %{time_connect} "http://' .. host .. ":" .. port .. '/"', 5000) or ""):match("\n([%d%.]+)")) or 0) > 0 end
  if band.LINUX then return (tonumber((reaper.ExecProcess("/usr/bin/curl -s -o /dev/null -m 3 -w %{time_connect} http://" .. host .. ":" .. port .. "/", 5000) or ""):match("\n([%d%.]+)")) or 0) > 0 end
  return (reaper.ExecProcess("/usr/bin/nc -z " .. NC_WAIT .. " 3 " .. host .. " " .. port, 5000) or ""):match("^0\n") ~= nil
end

-- Start `path args...` in the background, hidden, in `cwd` (optional). Returns true if launched.
local function launch(path, args, cwd)
  if WIN then
    local function sq(s) return "'" .. s:gsub("'", "''") .. "'" end -- PowerShell single quotes: ' is written ''
    local list = {}
    for _, a in ipairs(args) do list[#list + 1] = sq(a) end
    local ps = string.format("Start-Process -FilePath %s%s%s -WindowStyle Hidden", sq(path),
      #list > 0 and (" -ArgumentList " .. table.concat(list, ",")) or "", cwd and (" -WorkingDirectory " .. sq(cwd)) or "")
    -- (a " inside, as in --home="C:\Users\Jürgen Müller\...", ended the outer quotes: Syncthing started without its home. Review, 0.58.92)
    return reaper.ExecProcess('powershell -NoProfile -WindowStyle Hidden -Command "' .. ps:gsub('"', '\\"') .. '"', -1) ~= nil
  end
  local cmd = (cwd and ("cd " .. sh_q(cwd) .. " && ") or "") .. "nohup " .. sh_q(path) .. " " .. table.concat(args, " ") .. " >/dev/null 2>&1 &"
  local sh = TMP .. "/bandsync-launch.sh" -- a script file, not sh -c "...": see background()
  band.write_atomic(sh, cmd .. "\n")
  return reaper.ExecProcess("/bin/sh '" .. sh .. "'", -1) ~= nil
end

local function first_existing(list)
  for _, p in ipairs(list) do if p and p ~= "" and reaper.file_exists(p) then return p end end
end

-- Where winget unpacked Syncthing when it made no shortcut in WinGet/Links (a fresh Windows without the right to make links, AgentBox 0.58.60:
-- the installer said "installed" and then couldn't find it): Packages/Syncthing.Syncthing_*/syncthing-windows-*-v<version>/, the newest. Or nil.
function services.winget_syncthing(lad)
  local pk = lad .. "/Microsoft/WinGet/Packages"
  local best, best_v
  for _, d in ipairs(band.subdirs(pk)) do
    if d:find("^Syncthing%.Syncthing_") then
      for _, s in ipairs(band.subdirs(pk .. "/" .. d)) do
        local v = s:match("^syncthing%-windows%-[%w]+%-v([%d%.]+)$")
        local exe = pk .. "/" .. d .. "/" .. s .. "/syncthing.exe"
        if v and reaper.file_exists(exe) and (not best_v or band.compare_versions(v, best_v) > 0) then best, best_v = exe, v end
      end
    end
  end
  return best
end
function services.syncthing_path()
  local set = reaper.GetExtState(band.SECTION, "syncthing_path")
  local lad = (os.getenv("LOCALAPPDATA") or ""):gsub("\\", "/")
  return first_existing({ set,
    lad .. "/Microsoft/WinGet/Links/syncthing.exe", "C:/Program Files/Syncthing/syncthing.exe", lad .. "/Programs/Syncthing/syncthing.exe",
    "/Applications/Syncthing.app/Contents/Resources/syncthing/syncthing", -- (the Mac app before a Homebrew copy: the installer's)
    "/opt/homebrew/bin/syncthing", "/usr/local/bin/syncthing", "/usr/bin/syncthing", "/snap/bin/syncthing",
    (os.getenv("HOME") or "~") .. "/.local/bin/syncthing" }) -- (Linux, where the installer puts the release build when the distro has none)
    or (lad ~= "" and services.winget_syncthing(lad) or nil)
end

-- Make sure Syncthing runs. Returns "running", "started", or nil + why.
function services.ensure_syncthing()
  if services.running("syncthing", true) then return "running" end
  local path = services.syncthing_path()
  if not path then return nil, "Syncthing isn't running and wasn't found (set its path: ExtState BandSync/syncthing_path)" end
  -- on a Mac with Syncthing.app: the app starts it (its own copy, started beside the app, found the database and
  -- ports taken when the app opened later, or at login)
  if path:find("/Syncthing.app/", 1, true) then
    os.execute("/usr/bin/open -gja Syncthing")
    return "started"
  end
  local args, h = { "serve", "--no-browser" }, st_home() -- (launch quotes nothing on a Mac or Linux, and Start-Process joins its list unquoted)
  if h then h = h:gsub("[/\\]+$", ""); args[#args + 1] = WIN and ('--home="' .. h .. '"') or ("'--home=" .. h:gsub("'", "'\\''") .. "'") end
  if not launch(path, args) then return nil, "couldn't start " .. path end
  return "started"
end

-- The band folder's Syncthing settings for live use: changes are picked up within a second and, while files keep
-- changing (a live MIDI stream writes one a second), offered to the others at least every 2 s; left at 0 (the
-- default), Syncthing held them back about 7 s at a time (2026-10-28, laptop -> PC). Checked once per Live sync
-- start; only what differs is set. Returns what it set ({} when nothing), or nil + why.
services.WATCH = { ["fswatcher-enabled"] = "true", ["fswatcher-delays"] = "1", ["fswatcher-timeouts"] = "2" }
function services.tune_band_folder(folder)
  folder = folder or "bandsync" -- (each band's own Syncthing folder: band.info)
  local st = services.syncthing_path()
  if not st then return nil, "Syncthing wasn't found" end
  local set = {}
  for key, want in pairs(services.WATCH) do
    local got = (exec(cli(st) .. " config folders " .. folder .. " " .. key .. " get", 8000) or ""):match("^0\n(.-)%s*$")
    if not got then return nil, "Syncthing didn't answer (is it running, with a folder called " .. folder .. "?)" end
    if tonumber(got) and tonumber(want) and tonumber(got) == tonumber(want) or got == want then -- (2 and 2.0 alike)
    else
      local r = exec(cli(st) .. " config folders " .. folder .. " " .. key .. " set " .. want, 8000) or ""
      if not r:match("^0\n") then return nil, "couldn't set " .. key .. ": " .. r:gsub("^%d+\n", "") end
      set[#set + 1] = key .. " " .. got .. " -> " .. want
    end
  end
  -- (and old versions kept, 30 days, staggered: without them a deletion anywhere, by a bug or a slip, reached every copy with nothing to
  -- go back to. Only where none is set: someone's own choice stays. Review, 0.58.47)
  local vtype = (exec(cli(st) .. " config folders " .. folder .. " versioning type get", 8000) or ""):match("^0\n(.-)%s*$")
  if vtype == "" then
    local ok = (exec(cli(st) .. " config folders " .. folder .. " versioning type set staggered", 8000) or ""):match("^0\n")
    if ok then
      exec(cli(st) .. " config folders " .. folder .. " versioning params set maxAge 2592000", 8000)
      exec(cli(st) .. " config folders " .. folder .. " versioning params set cleanInterval 3600", 8000)
      set[#set + 1] = "versioning none -> staggered (30 days)"
    end
  end
  -- (a joiner paired with whoever invited them with auto-accept: any folder that computer offered was added here unasked. Since 0.58.69
  -- nothing is: the studio's own folder is added by its join, and another studio's offer is asked about on the Studios page. Security review)
  -- (only computers in a studio: every device's was switched, the person's own phones and other computers too. Security review, 0.58.87)
  local peers = services.studio_peers(st)
  for id in ((exec(cli(st) .. " config devices list", 8000) or ""):match("^0\n(.*)$") or ""):gmatch("[%u%d%-]+") do
    if services.is_device_id(id) and peers[id] and (exec(cli(st) .. " config devices " .. id .. " auto-accept-folders get", 8000) or ""):lower():match("^0\ntrue") then -- (Syncthing 2 says "True": it never matched. 0.58.78)
      exec(cli(st) .. " config devices " .. id .. " auto-accept-folders set false", 8000)
      set[#set + 1] = "auto-accept-folders off for " .. id:sub(1, 7)
    end
  end
  -- (the first studio's folder was labelled "BandSync" in Syncthing's window, or just its ID where Syncthing added it by itself ("bandsync" on
  -- the Mac): the studio's own name there now, as a new one gets. 0.58.69-70)
  local label = (exec(cli(st) .. " config folders " .. folder .. " label get", 8000) or ""):match("^0\n(.-)%s*$")
  if label and (label:lower() == "bandsync" or label == folder or label == "") then
    for _, x in ipairs(band.bands()) do
      if x.id == folder then services.set_folder_label(folder, "StudioSync " .. x.name); set[#set + 1] = "label " .. label .. " -> StudioSync " .. x.name end
    end
  end
  table.sort(set)
  return set
end

-- A joiner pairs with whoever invited them as an introducer (services.join_band, the installers), so the others in the studio are added here
-- by themselves. Left on, that computer could go on adding any computer it liked to the folders it shares with this one, so it goes once this
-- one is let in (removal.tick): by then the others have been introduced, and anyone let in later is met through the studio (removal.known).
-- `keep`: the inviters of studios still waiting to be let in. -> true when Syncthing answered. Security review, 0.58.78.
-- The computers this one shares a StudioSync folder with (folder ids "bandsync..." or "studiosync-..."): the only ones StudioSync changes
-- Syncthing settings for. -> set of device ids.
function services.studio_peers(st)
  local peers = {}
  for f in ((exec(cli(st) .. " config folders list", 8000) or ""):match("^0\n(.*)$") or ""):gmatch("%S+") do
    if f:lower():find("^bandsync") or f:lower():find("^studiosync%-") then
      for id in ((exec(cli(st) .. " config folders " .. f .. " devices list", 8000) or ""):match("^0\n(.*)$") or ""):gmatch("[%u%d%-]+") do
        if services.is_device_id(id) then peers[id] = true end
      end
    end
  end
  -- (and whoever invited this computer to a studio, its folder not here yet: the very computer whose offers mustn't be taken unasked)
  for _, x in ipairs(band.bands()) do
    local inv = require("trust").inviter(x.root)
    if inv then peers[inv] = true end
  end
  return peers
end
function services.introducers_off(keep)
  local st = services.syncthing_path()
  if not st then return false end
  local r = exec(cli(st) .. " config devices list", 8000) or ""
  if not r:match("^0\n") then return false end
  local peers = services.studio_peers(st) -- (only computers in a studio: the person's own other devices keep their settings. Review, 0.58.87)
  for id in r:gsub("^0\n", ""):gmatch("[%u%d%-]+") do
    if services.is_device_id(id) and not keep[id] and peers[id] and (exec(cli(st) .. " config devices " .. id .. " introducer get", 8000) or ""):lower():match("^0\ntrue") then -- (Syncthing 2 says "True")
      if (exec(cli(st) .. " config devices " .. id .. " introducer set false", 8000) or ""):match("^0\n") then
        band.log("you're in: Syncthing no longer adds the computers " .. services.device_name(id) .. " introduces (the others in the studio are met through it)")
      end
    end
  end
  return true
end

-- How many of Syncthing's devices it's connected to right now: connected, total. nil + why if it can't tell.
-- Asks Syncthing's own API with the key from its config. "Running but connected to nobody" is what a second
-- identity looks like (2026-10-27: one started outside a sandboxed shell knew no other machine).
local peers_at, peers_on, peers_n, peers_why = -math.huge
function services.syncthing_peers()
  if reaper.time_precise() - peers_at < 5 then return peers_on, peers_n or peers_why end -- (the curl itself runs in the background)
  peers_at = reaper.time_precise()
  peers_on, peers_n = services.syncthing_peers_now()
  if not peers_on then peers_why, peers_n = peers_n, nil end
  return peers_on, peers_n or peers_why
end
-- Syncthing's API, from its own config: the start of a curl command for `path`, or nil + why.
local function st_api(path, method)
  local home = st_home()
  if not home then
    home = WIN and ((os.getenv("LOCALAPPDATA") or "") .. "/Syncthing")
      or first_existing({ (os.getenv("HOME") or "") .. "/Library/Application Support/Syncthing/config.xml",
        (os.getenv("HOME") or "") .. "/.local/state/syncthing/config.xml", (os.getenv("HOME") or "") .. "/.config/syncthing/config.xml" })
    if home and not WIN then home = home:gsub("/config.xml$", "") end
  end
  local f = home and io.open(home .. "/config.xml", "r")
  if not f then return nil, "no Syncthing config found" end
  local xml = f:read("a")
  f:close()
  local gui = xml:match("<gui(.-)</gui>") or ""
  local key, addr = gui:match("<apikey>(.-)</apikey>"), gui:match("<address>(.-)</address>")
  if not key or not addr then return nil, "Syncthing config has no API key" end
  local tls = gui:match('^[^>]*tls="true"') ~= nil
  -- (the key goes in a curl config file in this user's own temp folder, not on the command line, where any program listing processes read
  -- it. Review, 0.58.92)
  local kf = TMP .. "/bandsync-st.cfg"
  local line = 'header = "X-API-Key: ' .. key .. '"\n'
  if band.read(kf) ~= line then
    band.write_atomic(kf, line)
    if not WIN then os.execute("chmod 600 " .. sh_q(kf)) end -- (this user's only: Linux falls back to /tmp, which others can read. 0.58.93)
  end
  return string.format('curl -s -m 3 %s%s-K "%s" "%s://%s%s"', tls and "-k " or "", method and ("-X " .. method .. " ") or "",
    kf, tls and "https" or "http", addr, path)
end
-- Syncthing's REST answer, now: for what someone just asked for, not for every frame. -> the text, or nil.
local function run_now(cmd, secs)
  if not WIN then
    local sh = TMP .. "/bandsync-ask.sh"
    band.write_atomic(sh, "rm -f \"$0\"\nexport TAILSCALE_BE_CLI=1\n" .. cmd .. "\n") -- (gone once read: it holds the API key)
    cmd = "/bin/sh '" .. sh .. "'"
  end
  local r = exec(cmd, (secs + 1) * 1000, "api") or ""
  if not r:match("^0\n") then return nil end
  local out = r:gsub("^0\n", "")
  return out ~= "" and out or nil
end
function services.ask(path, secs)
  local cmd = st_api(path)
  if not cmd then return nil end
  return run_now((cmd:gsub("%-m 3 ", "-m " .. (secs or 3) .. " ", 1)), secs or 3)
end
-- Have Syncthing scan a folder now (it reads a changed .stignore then: lib/songsync.lua). In the background.
-- sub: one path inside it (a start or stop cue: Syncthing otherwise noticed it a second later, by its watcher, and the Mac had it 3.3 s after
-- it was written. Measured, 0.58.52)
function services.rescan(folder, sub)
  local q = sub and ("&sub=" .. sub:gsub("[^%w%-%._~/]", function(c) return string.format("%%%02X", c:byte()) end)) or ""
  local cmd = st_api("/rest/db/scan?folder=" .. folder .. q, "POST")
  if cmd then background(sub and "syncthing-rescan-cue" or "syncthing-rescan", cmd, 0) end
end
function services.syncthing_peers_now()
  local cmd, why = st_api("/rest/system/connections")
  if not cmd then return nil, why end
  local out = background("syncthing-connections", cmd, 20) or ""
  local data = band.json_decode(out)
  if type(data) ~= "table" or type(data.connections) ~= "table" then return nil, "Syncthing didn't answer" end
  local n, on, relayed = 0, 0, 0
  for _, c in pairs(data.connections) do
    n = n + 1
    if c.connected then on = on + 1; if tostring(c.type or ""):find("relay", 1, true) then relayed = relayed + 1 end end
  end
  services.peers_relayed = relayed -- (through Syncthing's public relays: a firewall in the way, and every take crawls. Band-test review, 0.58.67)
  return on, n
end

-- Machines asking Syncthing to connect that it doesn't know yet (a bandmate's installer pairs with the host):
-- { { id, name, address } }. Answers from a background check at most 20 s old ({} before the first).
function services.pending_devices()
  local st = services.syncthing_path()
  local data = st and band.json_decode(background("st-pending", cli(st) .. " show pending devices", 20) or "")
  local list = {}
  for id, d in pairs(type(data) == "table" and data or {}) do
    if type(d) == "table" and services.is_device_id(id) then list[#list + 1] = { id = id, name = tostring(d.name or ""), address = tostring(d.address or "") } end
  end
  table.sort(list, function(a, z) return a.id < z.id end)
  return list
end

-- Syncthing forgets a machine that asked: it's only listed again if it asks again. In the background.
function services.dismiss_pending(id)
  if not services.is_device_id(id) then return end
  local cmd = st_api("/rest/cluster/pending/devices?device=" .. id, "DELETE")
  if cmd then background("st-dismiss", cmd, 0) end
end

-- This machine's Syncthing device ID, or nil (Syncthing not running, or no answer yet: a background check).
function services.my_device_id()
  local st = services.syncthing_path()
  local data = st and band.json_decode(background("st-system", cli(st) .. " show system", 300) or "")
  local id = type(data) == "table" and data.myID
  return services.is_device_id(id) and id or nil
end

-- Which computer last changed a file in a shared folder, as Syncthing has it (modifiedBy: the first 7 characters of its ID); "" when Syncthing
-- holds no such folder or file (a studio it doesn't sync, or a file written here a moment ago); nil when it didn't answer (lib/trust.lua).
function services.parse_modified_by(out)
  out = tostring(out or "")
  local g = out:match('"global"%s*:%s*(%b{})')
  if g then return g:match('"modifiedBy"%s*:%s*"([%u%d]*)"') or nil end
  -- (Syncthing's REST answer for a file or folder it doesn't hold: the same as an empty modifiedBy)
  local low = out:lower() -- (Syncthing 1.27 says "No such object in the index")
  if low:find("no such object", 1, true) or low:find("no such folder", 1, true) or low:find("does not exist", 1, true) then return "" end
  return nil
end
-- Through Syncthing's REST database API (/rest/db/file), not `cli debug file`: that one is /rest/debug/file, refused ("Debugging disabled")
-- unless debugging is switched on, as on Ubuntu's Syncthing 1.27, so a removal or a change of roles was never believed there. Linux VM, 0.58.76
function services.modified_by(folder, rel)
  if not tostring(folder):match("^[%w%-]+$") then return nil end
  local enc = tostring(rel):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end)
  return services.parse_modified_by(services.ask("/rest/db/file?folder=" .. folder .. "&file=" .. enc, 5))
end

-- What a set-up bandmate sends someone new: one line to paste on a Mac and one on Windows, each running the
-- installer with this machine's ID already in it, so nobody types an ID (Mac, 2026-10-31: "2MOGZMD" + Return was
-- the first try). The ?<time> keeps GitHub's cache from handing out an installer from before the last release.
-- With the band (band.info): its folder id and name ride along, so the installer joins that band.
-- `key` (services.tailscale_guest_key): a guest's, whose installer signs Tailscale in to this network until their time is up with it.
function services.invite_text(id, info, key)
  info = info or { id = "bandsync", name = "the studio" }
  key = key and key:match("^tskey%-auth%-[%w%-]+$")
  -- (the installer of this very release, by its tag: from main, whatever was pushed there last ran on the newcomer's computer, and a line sent
  -- weeks ago ran something nobody had looked at. Every release has its tag. Security review, 0.58.78)
  local base = "https://raw.githubusercontent.com/FmsJay/studiosync/v" .. band.VERSION .. "/installer/"
  local q1 = function(s) return "'" .. tostring(s):gsub("'", "") .. "'" end -- (band names are plain: band.clean)
  -- (newcomers first, in plain steps: most people invited have nothing installed, and the old order led with a panel they didn't have. Beginner review, 0.58.62)
  return "Join " .. info.name .. " on StudioSync.\n\n" ..
    "New to StudioSync? It sets up everything for you (REAPER included), in about 15 minutes. Copy ONE line below, for your computer:\n\n" ..
    "Windows: press Start, type PowerShell, open it, paste this line and press Enter:\n" ..
    '$f="$env:TEMP\\studiosync_install.ps1"; iwr -UseBasicParsing "' .. base .. 'install_windows.ps1?$(Get-Random)" -OutFile $f; ' ..
    "powershell -NoProfile -ExecutionPolicy Bypass -File $f -HostId " .. id .. " -BandId " .. info.id .. " -BandName " .. q1(info.name) .. (key and (" -TsKey " .. key) or "") .. "\n\n" ..
    "Mac: press Cmd+Space, type Terminal, open it, paste this line and press Return:\n" ..
    'curl -fsSL "' .. base .. 'install_mac.sh?$(date +%s)" | BS_HOST_ID=' .. id .. " BS_BAND_ID=" .. info.id ..
    " BS_BAND_NAME=" .. q1(info.name) .. (key and (" BS_TS_KEY=" .. key) or "") .. " bash\n\n" ..
    "Linux: open a terminal, paste this line and press Enter:\n" ..
    'curl -fsSL "' .. base .. 'install_linux.sh?$(date +%s)" | BS_HOST_ID=' .. id .. " BS_BAND_ID=" .. info.id ..
    " BS_BAND_NAME=" .. q1(info.name) .. (key and (" BS_TS_KEY=" .. key) or "") .. " bash\n\n" ..
    "Answer its questions, and when it's done, tell me: I let you in from my StudioSync panel.\n\n" ..
    (key and "That works once, within a week: it puts your computer on my Tailscale network as a guest, for as long as I invited you (no account needed). If you use Tailscale for anything else, switch back from its menu afterwards.\n\n" or "") ..
    "Already have StudioSync? In its panel, open your studios, press Paste join code, and paste this message (or just this line):\n" ..
    services.join_code(id, info)
end

-- The line that gets someone with StudioSync into a studio, in an invitation.
function services.join_code(id, info) return "studiosync-join:" .. id .. ":" .. info.id .. ":" .. tostring(info.name):gsub("[\r\n]", "") end
-- What was pasted: the code, on its own or in the whole message, or an invitation from before there were codes (the installer's own lines). -> { id, band, name }, or nil. Pure.
function services.parse_join(text)
  text = tostring(text or "")
  local id, folder, name = text:match("studiosync%-join:([%u%d%-]+):([%w%-]+):([^\r\n]*)")
  if not id then id, folder, name = text:match("%-HostId%s+([%u%d%-]+)%s+%-BandId%s+([%w%-]+)%s+%-BandName%s+'([^'\r\n]*)'") end
  if not id then id, folder, name = text:match("BS_HOST_ID=([%u%d%-]+)%s+BS_BAND_ID=([%w%-]+)%s+BS_BAND_NAME='([^'\r\n]*)'") end
  if not id or not services.is_device_id(id) then return nil end
  -- (only a StudioSync studio's folder: one you already have, like Syncthing's "default", would be shared with whoever sent it. Security review, 0.58.76)
  folder = folder:lower()
  if not (folder == "bandsync" or folder:match("^bandsync%-") or folder:match("^studiosync%-")) then return nil end
  return { id = id, band = folder, name = (name:gsub("[^%w%-_ ]", ""):match("^%s*(.-)%s*$")), key = text:match("tskey%-auth%-[%w%-]+") }
end
-- Into a studio from a code, with StudioSync already here: what an invitation's installer does (the folder, the pairing), and nothing else to install. Whoever invited
-- you then sees Let them in. -> its folder, or nil + why.
function services.join_band(cfg, code)
  local st = services.syncthing_path()
  if not st then return nil, "Syncthing wasn't found" end
  if code.id == services.my_device_id() then return nil, "That's your own join code: send it to whoever you're inviting." end
  for _, x in ipairs(band.bands()) do
    if x.id == code.band and not require("groups").is_old(x.root) then band.use_band(x.root); return x.root, "already" end
  end
  -- (it comes from whoever sent the code, and goes into a folder's path and a command)
  local name = band.clean(code.name or "")
  if name == "" then name = code.band end
  local here = ((cfg.base or cfg).root or ""):gsub("[/\\]+$", "")
  local parent = here:match("^(.*)[/\\][^/\\]+$") or here
  local root, n = parent .. "/StudioSync " .. name, 1
  while band.subdirs(root)[1] and band.info(root).id ~= code.band do n = n + 1; root = parent .. "/StudioSync " .. name .. " " .. n end -- (strangers' studios can share a name)
  reaper.RecursiveCreateDirectory(root, 0)
  reaper.SetExtState(band.SECTION, "joining " .. root, band.json_encode({ name = name, id = code.band }), true) -- (who this folder is, until its own _band/band.json arrives)
  band.pin_id(root, code.band) -- (and for good: band.info. Security review, 0.58.78)
  require("trust").set_inviter(root, code.id) -- (the computer that sent the code: the roles on first use are believed only from it. lib/trust.lua)
  if not reaper.file_exists(root .. "/.stignore") then -- (each project in full once it's opened; the rest as a listing)
    band.write_atomic(root .. "/.stignore", table.concat(require("songsync").block({}), "\n") .. "\n")
  end
  local r = exec(cli(st) .. " config folders add --id " .. code.band .. " --label " .. label_q("StudioSync " .. name) .. " --path " .. q(root), 15000) or ""
  if not r:match("^0\n") and not (exec(cli(st) .. " config folders " .. code.band .. " label get", 8000) or ""):match("^0\n") then
    return nil, "Syncthing didn't add the studio's folder: " .. r:gsub("^%d+\n", "")
  end
  exec(cli(st) .. " config folders " .. code.band .. " order set smallestFirst", 8000)
  services.tune_band_folder(code.band)
  if not (exec(cli(st) .. " config devices " .. code.id .. " name get", 8000) or ""):match("^0\n") then
    r = exec(cli(st) .. " config devices add --device-id " .. code.id .. " --name " .. q("Collaborator") .. " --introducer", 15000) or ""
    if not r:match("^0\n") then return nil, "Syncthing didn't pair with them: " .. r:gsub("^%d+\n", "") end
  end
  exec(cli(st) .. " config folders " .. code.band .. " devices add --device-id " .. code.id, 15000)
  require("groups").forget_old(root) -- (back in one you'd left)
  band.use_band(root)
  return root
end

-- A bandmate already known here offering a band's folder: someone in one of your bands joining another of them (an
-- invitation's installer shares that band's folder with you). { { folder, id, name } }, from a background check at
-- most 20 s old. (A new machine is a pending device instead: pending_devices.)
function services.pending_folders()
  local st = services.syncthing_path()
  local data = st and band.json_decode(background("st-pending-folders", cli(st) .. " show pending folders", 20) or "")
  local list = {}
  for folder, f in pairs(type(data) == "table" and data or {}) do
    for id in pairs(type(f) == "table" and type(f.offeredBy) == "table" and f.offeredBy or {}) do
      if services.is_device_id(id) then list[#list + 1] = { folder = folder, id = id } end
    end
  end
  table.sort(list, function(a, z) return a.folder .. a.id < z.folder .. z.id end)
  return list
end
-- A device's name in Syncthing (what its owner called their computer), or its ID's first 7 characters.
function services.device_name(id)
  local st = services.syncthing_path()
  local r = st and exec(cli(st) .. " config devices " .. id .. " name get", 8000) or ""
  return r:match("^0\n(.-)%s*$") or id:sub(1, 7)
end
-- Share a band's folder with a machine Syncthing already knows. Returns true, or nil + why.
function services.share_folder(folder, id)
  local st = services.syncthing_path()
  if not st then return nil, "Syncthing wasn't found" end
  if not services.is_device_id(id) then return nil, "not a device ID: " .. tostring(id) end
  local r = exec(cli(st) .. " config folders " .. folder .. " devices add --device-id " .. id, 15000) or ""
  if not r:match("^0\n") then return nil, "Syncthing didn't share it: " .. r:gsub("^%d+\n", "") end
  return true
end

-- A Syncthing device ID: 8 groups of 7 letters/digits.
local ID_PATTERN = "^" .. ("[%u%d]"):rep(7) .. ("%-" .. ("[%u%d]"):rep(7)):rep(7) .. "$"
function services.is_device_id(id)
  return type(id) == "string" and id:match(ID_PATTERN) ~= nil
end

-- Whether an address ("100.97.1.2:22000", "[fd7a:115c:a1e0::1]:22000") is on Tailscale (100.64.0.0/10, or its
-- fd7a:115c:a1e0::/48): with the band on one Tailscale account, only the band's own machines are there.
function services.on_tailnet(address)
  local a, b = (address or ""):match("^%[?(%d+)%.(%d+)%.%d+%.%d+")
  if a then return tonumber(a) == 100 and tonumber(b) >= 64 and tonumber(b) <= 127 end
  return (address or ""):lower():match("^%[?fd7a:115c:a1e0:") ~= nil
end

-- A band's Syncthing folder id from its name: "bandsync-" and the name in lower case, letters, digits and dashes. Pure.
function services.band_id(name)
  local slug = (name or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  return "studiosync-" .. (slug ~= "" and slug or "band")
end

-- Start a band (docs/bands-design.md): its own shared folder beside this band's (<parent>/StudioSync <Name>), with
-- _band/band.json saying who it is, and its own Syncthing folder (shared with nobody yet: Invite a bandmate). This
-- computer then works in it. Returns its folder, or nil + why.
function services.new_band(cfg, name)
  name = band.clean(name or "")
  if name == "" then return nil, "Give the studio a name." end
  local st = services.syncthing_path()
  if not st then return nil, "Syncthing wasn't found" end
  -- (the end is random: two strangers' groups can have one name, and someone could be in both)
  local id = services.band_id(name) .. string.format("-%04x", (os.time() * 7 + math.floor(reaper.time_precise() * 1000)) % 65536)
  for _, x in ipairs(band.bands()) do
    if x.id == id or x.name:lower() == name:lower() then return nil, "You're already in a studio called " .. x.name .. "." end
  end
  local here = ((cfg.base or cfg).root or ""):gsub("[/\\]+$", "")
  local root = (here:match("^(.*)[/\\][^/\\]+$") or here) .. "/StudioSync " .. name
  if band.subdirs(root)[1] then return nil, root .. " is already there: pick another name, or remove that folder." end
  reaper.RecursiveCreateDirectory(root .. "/_band", 0)
  band.write_json(root .. "/_band/band.json", { name = name, id = id, drive = "StudioSync - " .. name, owner = (cfg.base or cfg).user })
  band.pin_id(root, id)
  local r = exec(cli(st) .. " config folders add --id " .. id .. " --label " .. label_q("StudioSync " .. name) .. " --path " .. q(root), 15000) or ""
  if not r:match("^0\n") then return nil, "Syncthing didn't add the studio's folder: " .. r:gsub("^%d+\n", "") end
  exec(cli(st) .. " config folders " .. id .. " order set smallestFirst", 8000)
  services.tune_band_folder(id)
  band.use_band(root)
  return root
end

-- How long since anyone else in a folder was online: days, from Syncthing's own stats (read in the background, at most every 5 minutes).
-- nil when it can't tell, or there's nobody yet, or they've never connected (someone waiting to be let in).
function services.quiet_days(stats, peers, now)
  local newest
  for _, id in ipairs(peers) do
    local d = type(stats) == "table" and stats[id]
    local y, mo, da, h, mi = tostring(type(d) == "table" and d.lastSeen or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+)")
    if y and tonumber(y) > 2000 then
      local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(da), hour = tonumber(h), min = tonumber(mi) })
      if not newest or t > newest then newest = t end
    end
  end
  return newest and math.floor((now - newest) / 86400) or nil
end
function services.days_quiet(id)
  local st = services.syncthing_path()
  local cmd = st_api("/rest/stats/device")
  if not (st and cmd) then return nil end
  local stats = band.json_decode(background("st-stats", cmd, 300) or "")
  local me, peers = services.my_device_id(), {}
  for d in (background("st-peers-" .. id, cli(st) .. " config folders " .. id .. " devices list", 300) or ""):gmatch("[^\r\n]+") do
    if d ~= me then peers[#peers + 1] = d end
  end
  return services.quiet_days(stats, peers, os.time())
end
function services.set_folder_label(id, label)
  local st = services.syncthing_path()
  if st then exec(cli(st) .. " config folders " .. id .. " label set " .. label_q(label), 8000) end
end
-- This computer stops syncing a group's folder, and forgets the computers only that folder had. Its files stay. -> true when it's gone.
function services.forget_folder(id)
  local st = services.syncthing_path()
  if not st then return false end
  local function lines(cmd)
    local r = exec(cli(st) .. " config " .. cmd, 8000) or ""
    local out = {}
    if r:match("^0\n") then for l in r:gsub("^0\n", ""):gmatch("[^\r\n]+") do out[#out + 1] = l end end
    return out, r:match("^0\n") ~= nil
  end
  local listed, ok = lines("folders list")
  if not ok then return false end
  local there = false
  for _, f in ipairs(listed) do there = there or f == id end
  if not there then return true end
  local peers = lines("folders " .. id .. " devices list")
  if not (exec(cli(st) .. " config folders " .. id .. " delete", 15000) or ""):match("^0\n") then return false end
  local me = services.my_device_id()
  for _, d in ipairs(peers) do
    local used = d == me or not me -- (who "me" is unknown: nobody is forgotten)
    for _, f in ipairs(listed) do
      if f ~= id and not used then
        for _, x in ipairs((lines("folders " .. f .. " devices list"))) do used = used or x == d end
      end
    end
    if not used then exec(cli(st) .. " config devices " .. d .. " delete", 15000) end
  end
  return true
end

-- Add a machine to Syncthing and share a band's folder (`folder`: its Syncthing id, "bandsync" for the first band)
-- with it, and only that one. Returns true, or nil + why.
-- Stop sharing a band's folder with a machine, and forget the machine if no other folder has it. Nothing is deleted on either side.
-- Returns true (also when it wasn't shared), or nil + why.
function services.unshare(folder, id)
  local st = services.syncthing_path()
  if not st then return nil, "Syncthing wasn't found" end
  if not services.is_device_id(id) then return nil, "not a device ID: " .. tostring(id) end
  -- (true, false, or nil when Syncthing didn't answer: taken as "not shared", a removal on a computer just started, before Syncthing was,
  -- was noted as done for good and never happened. Review, 0.58.47)
  local function has(f)
    local r = exec(cli(st) .. " config folders " .. f .. " devices list", 8000) or ""
    if not r:match("^0\n") then return nil end
    return r:find(id, 1, true) ~= nil
  end
  local shared = has(folder)
  if shared == nil then return nil, "Syncthing didn't answer (it may not be running yet)" end
  if shared then
    local r = exec(cli(st) .. " config folders " .. folder .. " devices " .. id .. " delete", 15000) or ""
    if not r:match("^0\n") then return nil, "Syncthing didn't stop sharing: " .. r:gsub("^%d+\n", "") end
  end
  local listed = exec(cli(st) .. " config folders list", 8000) or ""
  if not listed:match("^0\n") then return true end -- (the folder's done; a machine left known does no harm)
  for f in listed:gsub("^0\n", ""):gmatch("[^\r\n]+") do if has(f) then return true end end
  exec(cli(st) .. " config devices " .. id .. " delete", 15000)
  return true
end
function services.add_device(id, name, folder)
  local st = services.syncthing_path()
  if not st then return nil, "Syncthing wasn't found" end
  if not services.is_device_id(id) then return nil, "not a device ID: " .. tostring(id) end
  name = (name or ""):gsub("[^%w%-_ ]", "")
  local r1 = exec(cli(st) .. " config devices add --device-id " .. id .. (name ~= "" and (" --name " .. q(name)) or ""), 15000) or ""
  local r2 = folder and exec(cli(st) .. " config folders " .. folder .. " devices add --device-id " .. id, 15000) or "0\n"
  if not r1:match("^0\n") then return nil, "Syncthing didn't add it: " .. r1:gsub("^%d+\n", "") end
  if not r2:match("^0\n") then return nil, "added, but the studio folder wasn't shared with it: " .. r2:gsub("^%d+\n", "") end
  return true
end
-- Who's asking to join, among the studios `me` may let people into. A computer not known here yet can't say which studio it wants: Syncthing shows that
-- only once it's known, as a folder it offers. So letting one in adds just the computer, and the studio comes after. (It went into whichever studio the
-- tab in front was in, invited or not, and a person with no tab or a tab in a studio they don't run never saw the request: 0.52.4.)
local asker_names = {}
function services.join_asks(me)
  local groups = require("groups")
  local ask, mine, any = {}, {}, false
  for _, x in ipairs(band.bands()) do
    -- (not one still waiting to be let in: with no band.json yet it read as an "open" studio, and a joiner saw others' join requests. Review, 0.58.67)
    if not x.waiting and not groups.is_old(x.root) and groups.may_manage(x.root, me) then mine[x.id], any = x, true end
  end
  if any then for _, d in ipairs(services.pending_devices()) do ask[#ask + 1] = d end end
  for _, f in ipairs(services.pending_folders()) do
    local x = mine[f.folder]
    if x then
      asker_names[f.id] = asker_names[f.id] or services.device_name(f.id)
      ask[#ask + 1] = { id = f.id, name = asker_names[f.id], folder = f.folder, band = x.name, root = x.root }
    end
  end
  return ask
end

local function tailscale_exe()
  return first_existing({ "C:/Program Files/Tailscale/tailscale.exe", "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/usr/bin/tailscale" })
end
function services.tailscale_installed() return tailscale_exe() ~= nil end
services.tailscale_exe = tailscale_exe -- (lib/listen.lua shares the listening page with it)
-- Running and signed in? Asked at most every 20 s: it's for a Health row. Pure part: services.tailscale_running_in.
function services.tailscale_running_in(json) return json:find('"BackendState":%s*"Running"') ~= nil end
local ts_at, ts_up, ts_json = -math.huge, false, ""
function services.tailscale_up()
  local exe = tailscale_exe()
  if not exe then return false end
  -- (in the background, every 20 s: waited for, a hung Tailscale held REAPER up to 5 s each time. Review, 0.58.47)
  local out = background("ts-status", q(exe) .. " status --json --peers=false", 20)
  if out and out ~= ts_json then ts_json, ts_up = out, services.tailscale_running_in(out) end
  return ts_up
end
-- Will this computer stay signed in? -> true (it's tagged, or its key expiry's off), or the date it signs out on. From `tailscale status --json --peers=false`. Pure.
-- (What a tailnet's policy says can't be read from a computer: a computer that got its tag is the proof. Trying a tag to find out once logged a Mac out: installer, 2026-10-28.)
function services.tailscale_stays_in(json)
  local self = json:match('"Self":%s*(%b{})') or ""
  local tags = self:match('"Tags":%s*(%b[])')
  if tags and tags:find("tag:", 1, true) then return true end
  return self:match('"KeyExpiry":%s*"(%d%d%d%d%-%d%d%-%d%d)') or true
end
function services.tailscale_stays()
  return not services.tailscale_up() or services.tailscale_stays_in(ts_json)
end
-- From `tailscale status --json --peers=false`: this machine's name, if the tailnet's names work ("pc.tail1234.ts.net", no last dot).
function services.tailscale_name_in(json)
  if not json:find('"MagicDNSEnabled":%s*true') then return nil end
  return json:match('"Self":%s*{.-"DNSName":%s*"([^"]-)%.?"')
end
-- How others reach this machine over Tailscale: its name (a 100.x address changes: the PC's did), or that address if the
-- tailnet has names turned off; nil when Tailscale isn't installed or signed in.
-- Tailscale's command line, waited for: on a Mac through a script with TAILSCALE_BE_CLI set (started straight from REAPER, the app could
-- open its window instead of answering: Mac review, 0.58.62). -> ExecProcess's "<code>\n<output>", or "" without Tailscale.
function services.ts_exec(args, ms)
  local exe = tailscale_exe()
  if not exe then return "" end
  local cmd = q(exe) .. " " .. args
  if not WIN then
    local sh = TMP .. "/bandsync-ts.sh"
    band.write_atomic(sh, "rm -f \"$0\"\nexport TAILSCALE_BE_CLI=1\n" .. cmd .. "\n") -- (gone once read: a join carries its key)
    cmd = "/bin/sh '" .. sh .. "'"
  end
  return reaper.ExecProcess(cmd, ms) or ""
end
function services.tailscale_address()
  if not tailscale_exe() then return nil end
  local name = services.tailscale_name_in(services.ts_exec("status --json --peers=false", 5000))
  if name and name ~= "" then return name end
  local out = services.ts_exec("ip -4", 5000) -- "0\n100.97.210.49\n"
  return out:match("^0\n%s*(100%.%d+%.%d+%.%d+)")
end

-- Tailscale's API, optional: with an access token from whoever runs the Tailscale network (login.tailscale.com/admin/settings/keys, it lasts 1-90 days),
-- StudioSync can let a guest onto Tailscale until a day you pick and add the policy lines its tags need. The token reaches curl through a config file in the user's temp
-- folder: never on a command line, where any process can read it, or in the log. It's kept locked to this computer's account (0.58.69: it sat in
-- reaper-extstate.ini as it was, and a portable REAPER folder travels): Windows encrypts it for the account (DPAPI), a Mac keeps it in the Keychain.
-- shortcut: elsewhere (Linux) it stays in ExtState as it is; and on a Mac it's on security's command line for the moment it's saved.
local GUEST_TAG = "tag:bandsync-guest"
-- One token per Tailscale network (0.58.94: a studio on each of two networks needed a token each; one per computer meant swapping it by hand).
-- A token is kept under its network's name ending ("tail1234.ts.net"); "" is one saved before then, its network not known.
local token_cache = {}
local function net_ok(net) return net == "" or (type(net) == "string" and net:match("^[%w%-]+%.ts%.net$") ~= nil) end
local function slot_key(net) return "tailscale_token_dpapi" .. (net ~= "" and (" " .. net) or "") end
local function keychain(net) return "-a studiosync -s 'StudioSync Tailscale token" .. (net ~= "" and (" " .. net) or "") .. "'" end
-- The networks this computer has a token for (ExtState "tailscale_token_nets", their names only), "" first when there's an older one. Pure on its input.
function services.token_nets_in(list, has_old)
  local out, seen = {}, {}
  if has_old then out[1], seen[""] = "", true end
  for n in (list or ""):gmatch("%S+") do if net_ok(n) and not seen[n] then out[#out + 1], seen[n] = n, true end end
  return out
end
local function token_store(token, net) -- -> true when it's locked away
  local f = TMP .. "/bandsync-ts-token.txt"
  if WIN then
    if token == "" then reaper.DeleteExtState(band.SECTION, slot_key(net), true); return true end
    band.write_atomic(f, token)
    local out = run_now('powershell -NoProfile -NonInteractive -Command "(Get-Content -Raw -LiteralPath \'' .. f .. '\').Trim() | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString"', 15)
    os.remove(f)
    local blob = out and out:match("(%x%x%x%x%x%x%x%x+)%s*$") -- (the last line: PowerShell can complain about a drive first)
    if blob then reaper.SetExtState(band.SECTION, slot_key(net), blob, true) end
    return blob ~= nil
  elseif band.MAC then
    if token == "" then run_now("security delete-generic-password " .. keychain(net) .. " >/dev/null 2>&1; echo done", 10); return true end
    band.write_atomic(f, token)
    local out = run_now("security add-generic-password -U " .. keychain(net) .. " -w \"$(cat '" .. f .. "')\" && echo stored", 10)
    os.remove(f)
    return out ~= nil and out:match("stored") ~= nil
  end
  return false
end
local function token_load(net)
  if WIN then
    local blob = reaper.GetExtState(band.SECTION, slot_key(net))
    if not blob:match("^%x+$") then return "" end
    return (run_now('powershell -NoProfile -NonInteractive -Command "$s = ConvertTo-SecureString \'' .. blob ..
      '\'; [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))"', 15) or ""):match("tskey%-[%w%-]+") or ""
  elseif band.MAC then
    return (run_now("security find-generic-password " .. keychain(net) .. " -w", 10) or ""):match("tskey%-[%w%-]+") or ""
  end
  return ""
end
local function plain_key(net) return "tailscale_token" .. (net ~= "" and (" " .. net) or "") end
local function token_in(net)
  if token_cache[net] then return token_cache[net] end
  local plain = reaper.GetExtState(band.SECTION, plain_key(net))
  if plain ~= "" then -- (one saved before 0.58.69, or where nothing locks it away: locked away now if it can be, and taken out of the settings file)
    if WIN or band.MAC then if token_store(plain, net) then reaper.DeleteExtState(band.SECTION, plain_key(net), true) end end
    token_cache[net] = plain
  else token_cache[net] = token_load(net) end
  return token_cache[net]
end
function services.tailscale_token_nets()
  local old = token_in("") ~= ""
  return services.token_nets_in(reaper.GetExtState(band.SECTION, "tailscale_token_nets"), old)
end
-- The token for `net` (a network's name ending), or for the network this computer is on; an older one (network not known) when there's none for it.
function services.tailscale_token(net)
  net = net or select(2, services.tailnet_now())
  local t = net_ok(net) and net ~= "" and token_in(net) or ""
  if t ~= "" then return t end
  return token_in("")
end
function services.has_tailscale_token() return #services.tailscale_token_nets() > 0 end
local function sweep_cfg(net) return TMP .. "/bandsync-ts-sweep" .. (net ~= "" and ("-" .. net) or "") .. ".cfg" end
-- Saves `token` under `net` (nil or "": the older, network-not-known place); "" as the token forgets it. A name that isn't a network's: nothing saved.
function services.set_tailscale_token(token, net)
  net = net or ""
  if not net_ok(net) then return false end
  token_cache[net] = token
  if not token_store(token, net) and token ~= "" then reaper.SetExtState(band.SECTION, plain_key(net), token, true) -- (nowhere safer here)
  else reaper.DeleteExtState(band.SECTION, plain_key(net), true) end
  if net ~= "" then
    local list = {}
    for _, n in ipairs(services.token_nets_in(reaper.GetExtState(band.SECTION, "tailscale_token_nets"))) do if n ~= net then list[#list + 1] = n end end
    if token ~= "" then list[#list + 1] = net end
    reaper.SetExtState(band.SECTION, "tailscale_token_nets", table.concat(list, " "), true)
  end
  os.remove(sweep_cfg(net)) -- (tailscale_sweep_guests writes it again, with this one)
end
-- -> the HTTP status, the headers, the body; or nil + why
local function ts_call(token, method, path, body, headers)
  if not token:match("^tskey%-api%-[%w%-]+$") then return nil, "no Tailscale access token: add one under Settings > Advanced" end
  local cfgf, bodyf = TMP .. "/bandsync-ts.cfg", TMP .. "/bandsync-ts-body.txt"
  local lines = { 'header = "Authorization: Bearer ' .. token .. '"' }
  for _, h in ipairs(headers or {}) do lines[#lines + 1] = 'header = "' .. h:gsub('"', '\\"') .. '"' end
  band.write_atomic(cfgf, table.concat(lines, "\n") .. "\n")
  if body then band.write_atomic(bodyf, body) end
  local out = run_now(string.format('curl -s -i -m 15 -X %s -K "%s" %s"https://api.tailscale.com/api/v2%s"', method, cfgf,
    body and ('--data-binary "@' .. bodyf .. '" ') or "", path), 16)
  os.remove(cfgf); os.remove(bodyf)
  if not out then return nil, "no answer from Tailscale" end
  local head, rest = "", out
  repeat -- (a "100 Continue" block can come first)
    local h, r = rest:match("^(HTTP/.-)\r?\n\r?\n(.*)$")
    if h then head, rest = h, r end
  until not h or not rest:match("^HTTP/")
  local code = tonumber(head:match("^HTTP/%S+%s+(%d%d%d)"))
  if not code then return nil, "no answer from Tailscale" end
  if code >= 300 then
    local data = band.json_decode(rest)
    return nil, "Tailscale said " .. code .. ((type(data) == "table" and data.message) and (": " .. tostring(data.message)) or "")
  end
  return code, head, rest
end
local function ts_api(method, path, body, headers, net) return ts_call(services.tailscale_token(net), method, path, body, headers) end

-- A key that lets one computer onto the Tailscale network until `ends` (a time; a day from now without one), without an account: usable once, within a
-- week at most; the computer it signs in is a guest (tag:bandsync-guest), and services.tailscale_sweep_guests takes it off when its time is up. A day's
-- guest is ephemeral too (it drops off once it's been offline a while); a longer one isn't, or a night with the laptop shut ended it. -> the key, or nil + why.
function services.guest_key_request(ends, now)
  local left = math.max(3600, (ends or now + 86400) - now)
  -- (the key itself, to join with, lasts two days at most: it sits in the message in plain text. Security review, 0.58.87)
  return { keyType = "auth", description = "StudioSync guest", expirySeconds = math.floor(math.min(left, 2 * 86400)),
    capabilities = { devices = { create = { reusable = false, ephemeral = left <= 86400 + 60, preauthorized = true, tags = { GUEST_TAG } } } } }
end
-- Which Tailscale network a devices list (GET /tailnet/-/devices) is from: its devices' names end in it ("tail1234.ts.net"). Pure.
function services.devices_tailnet(json)
  return tostring(json or ""):match('"name"%s*:%s*"[^"]-%.([%w%-]+%.ts%.net)"')
end
-- Which Tailscale network the access token for `net` is for. -> the suffix, or nil.
function services.token_tailnet(net)
  local code, _, out = ts_api("GET", "/tailnet/-/devices", nil, nil, net)
  if not code then return nil end
  return services.devices_tailnet(out)
end
-- Saves a token under the network it's for (Tailscale says, from its devices; else the network this computer is on). -> that network, or nil + why.
function services.add_tailscale_token(token)
  local code, why, out = ts_call(token, "GET", "/tailnet/-/devices")
  local net = code and services.devices_tailnet(out) or nil
  if not net and code then net = select(2, services.tailnet_now()) end
  if not net then return nil, tostring(why or "Tailscale didn't say which network it's for") end
  services.set_tailscale_token(token, net)
  return net
end
function services.tailscale_guest_key(ends, net)
  local code, head, out = ts_api("POST", "/tailnet/-/keys", band.json_encode(services.guest_key_request(ends, os.time())), { "Content-Type: application/json" }, net)
  if not code then return nil, head end
  local key = (band.json_decode(out) or {}).key
  if type(key) == "string" and key:match("^tskey%-auth%-[%w%-]+$") then return key end
  return nil, "Tailscale didn't hand back a key"
end

services.GUEST_TIP = "A guest until the day you pick: let in when they've run the invitation, and every computer stops syncing with theirs when their time\n" ..
  "is up (their copy stays with them). You can end it early, or give them longer, under Guests in Who's here."
services.GUEST_TS_TIP = "\nWith a Tailscale access token (yours), their computer also joins your Tailscale network until then, without an account, so Play along and\n" ..
  "Jam reach them. While it's on, your Tailscale policy decides what it can reach: all your computers on Tailscale's starting policy, only StudioSync\nonce Set up the tags has limited guests."
-- What a guest could reach on the tailnet, from its policy (HuJSON): "limited" (Set up the tags' guest rule is in), "open" (Tailscale's starting
-- allow-all: every computer on it), "own rules" (someone wrote their own: they decide); and whether StudioSync's tags are there (without them
-- Tailscale won't make a guest's key). Pure. Security review, 0.58.78.
function services.guest_reach(text)
  local tags = services.policy_with_tags(text) == nil
  local limited, how = services.policy_with_guest_rule(services.policy_with_tags(text) or text)
  return limited and "open" or (how == "has it" and "limited" or how), tags
end
services.GUEST_WARN = {
  open = "A guest on your Tailscale network can reach every computer on it: Tailscale's starting policy lets everyone reach everything.\n\n" ..
    "Set up the tags first? Then guests reach only StudioSync's file sharing (Syncthing) and jams (NINJAM) on your computers, and your own " ..
    "computers and your collaborators' stay as they are.\n\nYes: set it up, then make the invitation.\nNo: make it anyway.\nCancel: no invitation.",
  ["own rules"] = "Your Tailscale policy has rules of its own, so StudioSync can't tell what a guest could reach: your rules decide.\n\nMake the guest invitation anyway?",
  unknown = "StudioSync couldn't read your Tailscale policy, so it can't tell what a guest could reach. On Tailscale's starting policy a guest " ..
    "reaches every computer on your network (Set up the tags, in Settings, limits that).\n\nMake the guest invitation anyway?",
  tags = "\n\n(StudioSync adds its tags to the policy first: Tailscale makes no guest key without them. They change nobody's reach.)",
}
-- The Tailscale network a studio uses (groups.tailnet), or the one this computer is on. -> its name ending, or nil.
function services.studio_net(root)
  local want = root and require("groups").tailnet(root)
  return want and want.suffix or select(2, services.tailnet_now())
end
function services.copy_guest_invite(my_id, info, ctx, ImGui, root, ends)
  local net = services.studio_net(root)
  if services.tailscale_token(net) == "" then
    band.msg("This computer has no Tailscale access token for this studio's network" .. (net and (" (" .. net .. ")") or "") .. ".\n\n" ..
      "Make a token on the studio's network (login.tailscale.com, signed in to that account) and add it under Settings > Advanced, or forget this computer's tokens to invite without Tailscale.")
    return
  end
  -- (a guest reaches the whole tailnet unless the policy limits them: checked first, as Set up the tags reads it, and said plainly. Security review, 0.58.78)
  local text, err = services.tailscale_policy(net)
  local reach, tags = "unknown", true
  if text then reach, tags = services.guest_reach(text) end
  if reach == "open" then
    local a = reaper.MB(services.GUEST_WARN.open, "StudioSync: guest invitation", 3)
    if a == 2 then return end
    if a == 6 then
      local ok, how = services.tailscale_add_tags(function() return true end, net)
      if not ok then band.log("couldn't set up the tags, so no guest invitation: " .. tostring(how)); return end
      band.log(how == "limited" and "guests reach only StudioSync's file sharing and jams on your computers now" or "Tailscale's policy has StudioSync's tags; guests still reach whatever it allows")
    end
  elseif reach == "own rules" or reach == "unknown" then
    if not text then band.log("couldn't read the Tailscale policy before a guest invitation: " .. tostring(err)) end
    if reaper.MB(services.GUEST_WARN[reach] .. (tags and "" or services.GUEST_WARN.tags), "StudioSync: guest invitation", 1) ~= 1 then return end
    -- (without StudioSync's tags Tailscale makes no guest key; they change nobody's reach)
    if not tags and not services.tailscale_add_tags(function() return false end, net) then band.log("couldn't add StudioSync's tags, so no guest invitation"); return end
  end
  -- (the token's network must be the studio's: one token per computer made every guest a guest of its network, so a guest invited to one
  -- studio landed on another's, a personal one. Security review, 0.58.87)
  local want_suffix = net
  local token_suffix = services.token_tailnet(net)
  if want_suffix and token_suffix and want_suffix ~= token_suffix then
    band.msg("This computer has no Tailscale access token for this studio's network (" .. want_suffix .. "), only for " .. token_suffix .. ".\n\n" ..
      "Make a token on the studio's network (login.tailscale.com, signed in to that account) and add it under Settings > Advanced, or invite without Tailscale.")
    return
  end
  local key, why = services.tailscale_guest_key(ends, net)
  if not key then band.log("couldn't make a guest invitation: " .. tostring(why)); return end
  if root then pcall(require("groups").set_tailnet, root) end -- (the network the guest joins is this studio's)
  require("tools").show_invite(services.invite_text(my_id, info, key), info, ctx, ImGui)
  band.log("a guest invitation is on your clipboard: it also puts their computer on your Tailscale network until " .. require("removal").when(ends or os.time() + 86400, os.time()) .. " (no account needed)")
  return true
end
-- ---- Tailscale accounts: someone in two studios can be on two Tailscale networks, but a computer is on one at a time (Tailscale keeps
-- the others signed in, and its menu, or `tailscale switch`, moves between them). Each studio says which network it uses (groups.tailnet);
-- Health says when this computer is on another one and offers the switch.
-- From `tailscale status --json`: the network this computer is on, as its name and its address ending ("tail1234.ts.net"). Pure.
function services.tailnet_in(json)
  local cur = (json or ""):match('"CurrentTailnet":%s*(%b{})')
  if not cur then return nil end
  return cur:match('"Name":%s*"([^"]+)"'), cur:match('"MagicDNSSuffix":%s*"([^"]+)"')
end
function services.tailnet_now()
  if not services.tailscale_up() then return nil end
  return services.tailnet_in(ts_json)
end
function services.my_tailscale_name() return services.tailscale_up() and services.tailscale_name_in(ts_json) or nil end -- (no waiting: from the last status)
-- From `tailscale switch --list`: { { id, tailnet, account, current } } for each account this computer is signed in to. Pure.
function services.profiles_in(text)
  local out = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    local id, tailnet, account = line:match("^(%x+)%s+(%S+)%s+(%S+)%s*$")
    if id then out[#out + 1] = { id = id, tailnet = tailnet, account = account:gsub("%*$", ""), current = account:sub(-1) == "*" } end
  end
  return out
end
function services.tailscale_profiles()
  local exe = tailscale_exe()
  return exe and services.profiles_in(background("ts-profiles", q(exe) .. " switch --list", 30)) or {}
end
function services.tailscale_profile_for(tailnet)
  for _, p in ipairs(services.tailscale_profiles()) do if p.tailnet == tailnet then return p end end
end
-- (a switch away is written down first, in <StudioSync home>/tailnet-switch.json: { by, from_id, from_tailnet, to_id, to_tailnet, at, until },
-- and the file goes once it switches back. A computer that others reach over Tailscale, like James's PC with its AI hub, can read it and put
-- itself back if it's been left on the other network: switched by mistake, or StudioSync gone before it switched back.)
services.SWITCH_HOURS = 4
function services.switch_marker() return band.home() .. "/tailnet-switch.json" end
-- What to write (or nil to remove the marker) for a switch to `to_id`. profiles: services.profiles_in's; old: the marker as it is. Pure.
function services.switch_note(profiles, to_id, old, now)
  local from, to
  for _, p in ipairs(profiles) do
    if p.current then from = p end
    if p.id == to_id then to = p end
  end
  if type(old) == "table" and old.from_id == to_id then return nil end -- (going back where it came from)
  if not (from and to) or from.id == to_id then return old end
  local function iso(t) return os.date("!%Y-%m-%dT%H:%M:%SZ", t) end
  return { by = "StudioSync", from_id = (type(old) == "table" and old.from_id) or from.id, from_tailnet = (type(old) == "table" and old.from_tailnet) or from.tailnet,
    to_id = to.id, to_tailnet = to.tailnet, at = iso(now), ["until"] = iso(now + services.SWITCH_HOURS * 3600) }
end
function services.tailscale_switch(id)
  if not (type(id) == "string" and id:match("^%x+$")) then return false end
  local exe = tailscale_exe()
  if not exe then return false end
  -- (asked now, not the list from the last look: that one can be from before the last switch, and then this one took itself for a stay put
  -- and wrote no note. Seen in the real switch test, 0.58.58. A click, so waiting the moment it takes is fine)
  local now_list = services.profiles_in(services.ts_exec("switch --list", 8000))
  local note = services.switch_note(now_list, id, band.read_json(services.switch_marker()), os.time())
  if note then pcall(band.write_json, services.switch_marker(), note) else os.remove(services.switch_marker()) end
  background("ts-switch", q(exe) .. " switch " .. id, 0)
  -- (and what's shown is asked again at once: the status and the accounts were up to 20-30 s behind the switch)
  for _, n in ipairs({ "ts-status", "ts-profiles" }) do started[n], last[n] = nil, nil; os.remove(TMP .. "/bandsync-" .. n .. ".txt") end
  ts_json = ""
  return true
end

-- ---- Syncing through each studio's own Tailscale network (James, 0.58.80: "the point is to have different tailscale accounts for different
-- studios that I can switch to"). A studio set to "Sync only through Tailscale" (groups.tailscale_only) syncs with each computer at its name on the
-- studio's network: each computer writes its own name there into its _band/devices file whenever it's on that network (removal.publish), and
-- every computer gives Syncthing only those names for it. A computer in two such studios has a name on each network; whichever network this one
-- is on now, that name answers, so a studio syncs while you're on its network. Until a computer's name on a studio's network is known, Syncthing
-- keeps finding it its own way ("dynamic"), so a newcomer still arrives and publishes it; so does a computer also in a studio that isn't set so.
-- (Syncthing checks every computer's certificate whatever address it's reached at: a wrong name only stops that sync, it can't stand in for it.)
-- studios: { { only, suffix, devices = { { device, ts = { [suffix] = name } } } } }. -> device -> its addresses. Pure.
services.SYNC_PORT = 22000
function services.tailnet_addresses(studios, me)
  local acc = {}
  for _, s in ipairs(studios) do
    for _, d in ipairs(s.devices or {}) do
      if type(d.device) == "string" and d.device ~= me then
        local a = acc[d.device] or { names = {}, dynamic = false }
        acc[d.device] = a
        local name = s.only and s.suffix and type(d.ts) == "table" and d.ts[s.suffix]
        if type(name) == "string" and name:match("^[%w%-%.]+$") and name:sub(-#s.suffix - 1) == "." .. s.suffix then
          a.names["tcp://" .. name .. ":" .. services.SYNC_PORT] = true
        else a.dynamic = true end
      end
    end
  end
  local out = {}
  for id, a in pairs(acc) do
    local list = {}
    for n in pairs(a.names) do list[#list + 1] = n end
    table.sort(list)
    if a.dynamic then list[#list + 1] = "dynamic" end
    out[id] = list
  end
  return out
end
local pinned, patched = {}, {} -- device -> its addresses as Syncthing has them; the change last asked for, and when (read in the background)
function services.pin_tailnet(me)
  if not (services.syncthing_path() and services.is_device_id(me)) then return end
  local studios = {}
  for _, g in ipairs(band.bands()) do
    if not g.waiting and not require("groups").is_old(g.root) then
      local t = require("groups").tailnet(g.root)
      local s = { only = require("groups").tailscale_only(g.root), suffix = t and t.suffix, devices = {} }
      for _, f in ipairs(band.files(g.root .. "/_band/devices", ".json")) do
        local d = band.read_json(g.root .. "/_band/devices/" .. f)
        if type(d) == "table" and services.is_device_id(d.device) then s.devices[#s.devices + 1] = d end
      end
      studios[#studios + 1] = s
    end
  end
  for id, list in pairs(services.tailnet_addresses(studios, me)) do
    local want = table.concat(list, " ")
    if pinned[id] ~= want then
      local get = st_api("/rest/config/devices/" .. id)
      local have = get and band.json_decode(background("st-addr-" .. id:sub(1, 7), get, 20) or "")
      if type(have) == "table" and type(have.addresses) == "table" then
        local cur = {}
        for _, a in ipairs(have.addresses) do cur[#cur + 1] = tostring(a) end
        local sorted = {}
        for _, a in ipairs(list) do sorted[#sorted + 1] = a end
        table.sort(cur); table.sort(sorted)
        if table.concat(cur, " ") == table.concat(sorted, " ") then pinned[id] = want
        elseif not (patched[id] and patched[id].want == want and os.time() - patched[id].at < 120) then -- (once: the next read can still be from before it)
          patched[id] = { want = want, at = os.time() }
          local body = TMP .. "/bandsync-addr-" .. id:sub(1, 7) .. ".json"
          band.write_atomic(body, band.json_encode({ addresses = list }))
          local patch = st_api("/rest/config/devices/" .. id, "PATCH")
          if patch then
            background("st-pin-" .. id:sub(1, 7), patch .. ' -H "Content-Type: application/json" --data-binary "@' .. body .. '"', 0)
            local names = {}
            for _, a in ipairs(list) do if a ~= "dynamic" then names[#names + 1] = (a:gsub("^tcp://", ""):gsub(":%d+$", "")) end end
            band.log(services.device_name(id) .. (#names == 0 and ": Syncthing finds it its own way again"
              or (": syncs through Tailscale, at " .. table.concat(names, " or ") .. (list[#list] == "dynamic" and " (and its own way, until every studio knows its name)" or ""))))
          end
          started["st-addr-" .. id:sub(1, 7)] = nil -- (read again next time, to see it took)
        end
      end
    end
  end
end

-- A guest's key from a pasted invitation (services.parse_join: only key characters): what the installers do with it. In the background: it can take a minute.
function services.tailscale_join(key)
  local exe = tailscale_exe()
  if exe then
    background("ts-guest", string.format('"%s" login --authkey=%s --timeout=120s', exe, key), 0)
    -- (the script it ran held the key in the temp folder for good: gone once sign-in has had its two minutes. Review, 0.58.47)
    local t0 = reaper.time_precise()
    local function tidy()
      if reaper.time_precise() - t0 < 150 then return reaper.defer(tidy) end
      os.remove(TMP .. "/bandsync-ts-guest." .. (WIN and "cmd" or "sh"))
    end
    reaper.defer(tidy)
  end
  return exe ~= nil
end

-- `text` with comments blanked out, same length: where to look for keys in a HuJSON policy. Strings stay.
local function code_only(text)
  local out, i, n = {}, 1, #text
  while i <= n do
    local c, two = text:sub(i, i), text:sub(i, i + 1)
    if c == '"' then
      local j = i + 1
      while j <= n and text:sub(j, j) ~= '"' do j = j + (text:sub(j, j) == "\\" and 2 or 1) end
      out[#out + 1] = text:sub(i, j); i = j + 1
    elseif two == "//" or two == "/*" then
      local j = two == "//" and (text:find("\n", i, true) or n + 1) - 1 or (select(2, text:find("*/", i + 2, true)) or n)
      out[#out + 1] = string.rep(" ", j - i + 1); i = j + 1
    else out[#out + 1] = c; i = i + 1 end
  end
  return table.concat(out)
end
-- A Tailscale policy (HuJSON) with the tagOwners lines StudioSync's tags need added, comments and all kept as written; nil when it has them. Pure.
function services.policy_with_tags(text)
  local code, add = code_only(text), {}
  for _, tag in ipairs({ "tag:bandsync", GUEST_TAG }) do
    if not code:find('"' .. tag:gsub("%-", "%%-") .. '"%s*:') then add[#add + 1] = '\n\t\t"' .. tag .. '": ["autogroup:member"],' end
  end
  if #add == 0 then return nil end
  local at = select(2, code:find('"tagOwners"%s*:%s*{'))
  if at then return text:sub(1, at) .. table.concat(add) .. text:sub(at + 1) end
  at = code:find("{", 1, true)
  if not at then return nil end
  return text:sub(1, at) .. '\n\t"tagOwners": {' .. table.concat(add) .. "\n\t}," .. text:sub(at + 1)
end
-- Tailscale's starting allow-all rule, as grants (new networks) or the older acls
local GRANT_ALL = '{%s*"src"%s*:%s*%[%s*"%*"%s*%]%s*,%s*"dst"%s*:%s*%[%s*"%*"%s*%]%s*,%s*"ip"%s*:%s*%[%s*"%*"%s*%]%s*}'
local ACL_ALL = '{%s*"action"%s*:%s*"accept"%s*,%s*"src"%s*:%s*%[%s*"%*"%s*%]%s*,%s*"dst"%s*:%s*%[%s*"%*:%*"%s*%]%s*}'
-- A policy whose only rule is that one, split in two: members and StudioSync's computers reach everything as before; guests reach only Syncthing
-- (22000) and NINJAM (2049) on them. Anything else in the policy (another tag, another rule from "*") means someone wrote their own rules: those
-- stay as they are. -> the new text; or nil + "has it" / "own rules". Pure.
-- shortcut: computers shared in from another network lose the reach "*" gave them; handle that if a studio ever relies on sharing.
function services.policy_with_guest_rule(text)
  local code = code_only(text)
  if code:find('"src"%s*:%s*%[%s*"tag:bandsync%-guest"%s*%]') then return nil, "has it" end
  for tag in code:gmatch('"(tag:[%w%-]+)"') do
    if tag ~= "tag:bandsync" and tag ~= GUEST_TAG then return nil, "own rules" end
  end
  local _, wild = code:gsub('"src"%s*:%s*%[[^%]]*"%*"', "")
  local s, e = code:find(GRANT_ALL)
  local acl = not s
  if acl then s, e = code:find(ACL_ALL) end
  if not s or wild ~= 1 then return nil, "own rules" end
  local ind = text:sub(1, s - 1):match("\n([ \t]*)$") or ""
  return text:sub(1, s - 1) .. (acl
    and '{"action": "accept", "src": ["autogroup:member", "tag:bandsync"], "dst": ["*:*"]},\n' .. ind ..
        '{"action": "accept", "src": ["tag:bandsync-guest"], "dst": ["autogroup:member:22000,2049", "tag:bandsync:22000,2049"]}'
    or '{"src": ["autogroup:member", "tag:bandsync"], "dst": ["*"], "ip": ["*"]},\n' .. ind ..
       '{"src": ["tag:bandsync-guest"], "dst": ["autogroup:member", "tag:bandsync"], "ip": ["tcp:22000", "udp:22000", "tcp:2049"]}') .. text:sub(e + 1)
end
-- The tailnet's policy as written (HuJSON), and the ETag that says which version it is. -> text, etag; or nil + why.
function services.tailscale_policy(net)
  local code, head, text = ts_api("GET", "/tailnet/-/acl", nil, { "Accept: application/hujson" }, net)
  if not code then return nil, head end
  return text, head:match("\n[Ee][Tt][Aa][Gg]:%s*([^\r\n]+)")
end
-- Adds the tags to the tailnet's policy, and the guest rule when `ok_to_limit()` says yes (only if nobody changed the policy meanwhile: its ETag).
-- -> true + "limited" / "has it" / "own rules" / nil (guests left as they were); or nil + why
function services.tailscale_add_tags(ok_to_limit, net)
  local text, etag = services.tailscale_policy(net)
  if not text then return nil, etag end
  local new = services.policy_with_tags(text) or text
  local limited, how = services.policy_with_guest_rule(new)
  if limited and ok_to_limit and ok_to_limit() then new, how = limited, "limited" end
  if new == text then return true, how end
  local code, head = ts_api("POST", "/tailnet/-/acl", new, { "Content-Type: application/hujson", "Accept: application/hujson", etag and ("If-Match: " .. etag) or nil }, net)
  if not code then return nil, head end
  band.log(how == "limited" and "set up StudioSync's tags and the guest rule in the Tailscale network's policy" or "added StudioSync's tags to the Tailscale network's policy")
  return true, how
end

-- Guests in `json` (GET /tailnet/-/devices) that came on more than a day before `now` (seconds, UTC): their ids. Pure.
-- Guests whose time is up: a guest device's time is its invitation's (`invites`: { made, ends } from the studios, lib/removal.lua: the newest
-- made before it joined, within the week a key lasts), else a day from when it joined. `now` and the invitations' times as UTC. Pure.
function services.old_guests(json, now, invites)
  local old = {}
  for _, d in ipairs((band.json_decode(json) or {}).devices or {}) do
    local guest = false
    for _, t in ipairs(type(d.tags) == "table" and d.tags or {}) do guest = guest or t == GUEST_TAG end
    local y, mo, da, h, mi, s = tostring(d.created or ""):match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
    if guest and y then
      local joined = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(da), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
      local ends, made = joined + 86400, nil
      for _, v in ipairs(invites or {}) do
        if v.made <= joined + 60 and joined - v.made <= 7 * 86400 and (not made or v.made > made) then made, ends = v.made, v.ends end
      end
      if now > ends then old[#old + 1] = tostring(d.id) end
    end
  end
  return old
end
local swept, sweep_at = {}, {}
-- Takes guests off when their time is up, on every network this computer has a token for. In the background every 15 min: its config file
-- stays in the user's temp folder meanwhile.
function services.tailscale_sweep_guests()
  for _, net in ipairs(services.tailscale_token_nets()) do
    local token = token_in(net)
    if token:match("^tskey%-api%-[%w%-]+$") then services.sweep_net(net, token) end
  end
end
function services.sweep_net(net, token)
  local cfgf = sweep_cfg(net)
  local curl = 'curl -s -m 10 -K "' .. cfgf .. '" '
  if not reaper.file_exists(cfgf) then band.write_atomic(cfgf, 'header = "Authorization: Bearer ' .. token .. '"\n') end
  local tag = net ~= "" and ("-" .. net:gsub("%W", "")) or ""
  local out = background("ts-devices" .. tag, curl .. '"https://api.tailscale.com/api/v2/tailnet/-/devices"', 900)
  if not out or reaper.time_precise() - (sweep_at[net] or -math.huge) < 60 then return end
  sweep_at[net] = reaper.time_precise()
  -- (os.time reads a table as local time: both sides that way, the difference is right. Invitations are kept in os.time(): moved to the same footing)
  local shift = os.time(os.date("!*t")) - os.time()
  local invites = {}
  for _, x in ipairs(band.bands()) do
    for _, v in ipairs(require("removal").invites(x.root)) do invites[#invites + 1] = { made = v.made + shift, ends = v.ends + shift } end
  end
  for _, id in ipairs(services.old_guests(out, os.time(os.date("!*t")), invites)) do
    if id:match("^%w+$") and not swept[id] then
      swept[id] = true
      background("ts-del-" .. id, curl .. '-X DELETE "https://api.tailscale.com/api/v2/device/' .. id .. '"', 3600)
      band.log("took a Tailscale guest off: their time was up")
    end
  end
end

-- The NINJAM server: the one that ships (lib/ninjam), or a folder of your own in ExtState ninjam_dir.
function services.ninjam_dir()
  local own = reaper.GetExtState(band.SECTION, "ninjam_dir")
  return own ~= "" and own or (debug.getinfo(1, "S").source:match("^@?(.*)[/\\]") .. "/ninjam")
end
-- One of the programs in lib/ninjam for this computer: Linux's are per processor (lib/ninjam/linux-x86_64/, linux-aarch64/: built by
-- .github/workflows/extension.yml), Windows' and the Mac's (universal) sit in lib/ninjam itself. 0.58.74
local arch
function services.ninjam_bin(name)
  if not band.LINUX then return services.ninjam_dir() .. "/" .. name end
  arch = arch or ((reaper.ExecProcess("/bin/uname -m", 3000) or ""):match("^0\n(%S+)") or "x86_64")
  return services.ninjam_dir() .. "/linux-" .. arch .. "/" .. name
end
-- It runs from a copy in StudioSync's own folder: a running program couldn't be replaced by the next update.
function services.ensure_ninjam()
  if services.running("ninjamsrv", true) then return "running" end
  local from, name = services.ninjam_dir(), WIN and "ninjamsrv.exe" or "ninjamsrv"
  local bin = services.ninjam_bin(name)
  if not reaper.file_exists(bin) then return nil, "there's no NINJAM server for this computer (" .. bin .. ")" end
  if not reaper.file_exists(from .. "/bandsync.cfg") then return nil, "no bandsync.cfg in " .. from end
  local dir = band.home():gsub("\\", "/") .. "/ninjam"
  reaper.RecursiveCreateDirectory(dir, 0)
  pcall(band.copy_atomic, bin, dir .. "/" .. name) -- (one just started may not show as running yet: it holds the file)
  pcall(band.copy_atomic, from .. "/bandsync.cfg", dir .. "/bandsync.cfg")
  if not WIN then
    local sh = TMP .. "/bandsync-ninjam.sh"
    band.write_atomic(sh, "chmod +x " .. sh_q(dir .. "/" .. name) .. (band.MAC and ("; xattr -c " .. sh_q(dir .. "/" .. name)) or "") .. "\n")
    reaper.ExecProcess("/bin/sh '" .. sh .. "'", 5000)
  end
  if not launch(dir .. "/" .. name, { "bandsync.cfg" }, dir) then return nil, "couldn't start " .. dir .. "/" .. name end
  band.log("started the NINJAM server on this computer" .. (WIN and ": if Windows asks whether it may accept connections, allow it, or nobody can reach it" or ""))
  return "started"
end
-- On a Mac ReaNINJAM connects through njrelay (lib/ninjam, source in tools/ninjam-relay). A server that just goes away brings up ReaNINJAM's "Disconnected from
-- host!", which there holds every script until someone presses OK; the relay keeps ReaNINJAM's connection open and quiet instead, and its status file says
-- "lost", so StudioSync disconnects as if by hand (live.relay_lost), which shows no alert. It reads its server from a file at each connection, so the
-- server can move without restarting it. -> the address to give ReaNINJAM: the relay's, or `server` itself where there's no relay (Windows, or none shipped).
-- shortcut: if something else holds the port, the relay can't listen and ReaNINJAM can't connect until the next start goes direct (status "cantlisten").
services.RELAY_PORT = 2098
local function relay_dir() return band.home():gsub("\\", "/") .. "/ninjam" end
-- (a relay that beats, 0.58.47 on, rewrites it every 3 s while a client is on: older than 15 s, it died with that word up, and nothing
-- reconnected. "cantlisten" is tried again after a minute: once, a busy port turned the relay off for good. Review, 0.58.47)
function services.relay_status()
  local line = band.read(relay_dir() .. "/njrelay.txt") or ""
  local word, t = line:match("^(%a+) (%d+)")
  if not word then return line:match("^(%a+)") end
  local age = os.time() - tonumber(t)
  if word == "cantlisten" then return age < 60 and word or nil end
  if line:find(" hb", 1, true) and age > 15 then return nil end
  return word
end
-- With nobody connected, the relay checks the server every 5 s itself: whether it answered, as of the last 15 s.
function services.relay_up()
  local word, up, t = (band.read(relay_dir() .. "/njrelay.txt") or ""):match("^(%a+) (%a+) (%d+)")
  return word == "idle" and up == "up" and os.time() - tonumber(t) < 15
end
-- An update's relay replaces the running one, but only between connections: stopping it under one is the alert this is for. Also at REAPER's
-- start (Autostart): a relay from before 0.58.47 doesn't leave when REAPER does, and stayed for days (the Mac, 0.58.68 test). -> true if it stopped one.
function services.stop_old_relay()
  if WIN or not services.running("njrelay", true) or services.relay_status() ~= "idle" then return false end
  local from = services.ninjam_bin("njrelay")
  if not reaper.file_exists(from) or band.read(from) == band.read(relay_dir() .. "/njrelay") then return false end
  local sh = TMP .. "/bandsync-njrelay-stop.sh"
  band.write_atomic(sh, "/usr/bin/pkill -x njrelay; sleep 1\n") -- (gone before the new one takes the port)
  reaper.ExecProcess("/bin/sh '" .. sh .. "'", 5000)
  return true
end
function services.relay_for(server)
  local from = services.ninjam_bin("njrelay")
  if WIN or not server:match("^.+:%d+$") or not reaper.file_exists(from) or services.relay_status() == "cantlisten" then return server end
  local dir = relay_dir()
  reaper.RecursiveCreateDirectory(dir, 0)
  if band.read(dir .. "/njrelay.target") ~= server then band.write_atomic(dir .. "/njrelay.target", server) end
  if not services.running("njrelay", true) or services.stop_old_relay() then
    pcall(band.copy_atomic, from, dir .. "/njrelay")
    local sh = TMP .. "/bandsync-njrelay.sh"
    band.write_atomic(sh, "chmod +x " .. sh_q(dir .. "/njrelay") .. (band.MAC and ("; xattr -c " .. sh_q(dir .. "/njrelay")) or "") .. "\n")
    reaper.ExecProcess("/bin/sh '" .. sh .. "'", 5000)
    os.remove(dir .. "/njrelay.txt")
    if not launch(dir .. "/njrelay", { tostring(services.RELAY_PORT), "njrelay.target", "njrelay.txt" }, dir) then return server end
  end
  return "127.0.0.1:" .. services.RELAY_PORT
end

-- Does Windows let it accept connections? Until it does it's up but nobody reaches it (the laptop, 0.58.11: Windows only asks once, on the host's screen). A check in the
-- background, for a Health row; a computer's own connection doesn't go through the firewall, so it can't simply try. A Block rule wins: Cancel at Windows' box makes one.
function services.firewall_knows_ninjam()
  if not WIN then return true end
  local out = background("fw", [[powershell -NoProfile -Command "Get-NetFirewallApplicationFilter | Where-Object Program -like '*ninjamsrv*' | Get-NetFirewallRule | ForEach-Object Action"]], 60)
  return out == nil or (out:find("Allow", 1, true) ~= nil and not out:find("Block", 1, true))
end
-- Nobody's using it, say: it otherwise runs until the computer restarts. Everyone on it is told first (live.json's `stopping`) and disconnects by hand, which shows
-- no box: a server just gone shows ReaNINJAM's, and on a Mac that held all of StudioSync until someone pressed OK (lib/live.lua). It stops 10 s later.
function services.stop_ninjam(lfile)
  local data = lfile and band.read_json(lfile)
  if data then data.stopping = os.time(); band.write_json(lfile, data) end
  require("live").disconnect()
  local t0 = reaper.time_precise()
  local function later()
    if reaper.time_precise() - t0 < 10 then return reaper.defer(later) end
    reaper.ExecProcess(WIN and "taskkill /F /IM ninjamsrv.exe" or "/usr/bin/pkill -x ninjamsrv", 5000)
    band.log("stopped the NINJAM server on this computer")
  end
  band.log("stopping the NINJAM server on this computer in 10 s: whoever's on it disconnects first")
  reaper.defer(later)
end

-- This song's NINJAM server, "name:port", or nil + why. One computer runs it: whichever needed it first and, if that one's gone, the next to ask for it.
-- may_host: someone pressed Produce or Connect. Not whoever's only being heard: both taking over at once, each would end up alone on a server of their own.
-- force: this computer takes it, whoever has it. shortcut: two people pressing within a sync of each other can still end up apart; pressing again settles it.
function services.ninjam_for(cfg, lfile, may_host, force)
  local data = band.read_json(lfile) or {}
  local server, mine = data.server or "", (data.server or "") ~= "" and data.by == cfg.user
  if mine then reaper.SetExtState(band.SECTION, "ninjam hosting", server, false) end -- (what this computer serves: other songs may use someone else's)
  if not force then
    if not may_host then -- (even if the file says it's mine: it may be old news, with the one who pressed taking over right now. See producer.lua, which follows it)
      if server ~= "" then return server end
      return nil, "nobody's started the NINJAM server for this song yet"
    end
    if not mine and server ~= "" and services.answers(server) then return server end
  end
  local addr = services.tailscale_address()
  if not addr then
    if server ~= "" and not force then return server end
    return nil, "Tailscale isn't on here, so nobody could reach a NINJAM server on this computer: open Tailscale and sign in."
  end
  local ok, why = services.ensure_ninjam()
  if not ok then return nil, "NINJAM server: " .. why end
  local now = addr .. ":2049"
  reaper.SetExtState(band.SECTION, "ninjam hosting", now, false)
  if server ~= now or not mine or data.stopping then -- (started again after a stop: it's not stopping now)
    data.server, data.by, data.stopping = now, cfg.user, nil
    band.write_json(lfile, data)
    band.log("this song's NINJAM server now runs on this computer: " .. now)
  end
  return now
end

return services
