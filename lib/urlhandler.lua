-- studiosync:// links opened from a browser or a chat app (James, rt: "an invite link that opens their REAPER to the project and StudioSync").
-- This computer's handler for the scheme, installed only when the person ticks "Open StudioSync links on this computer" in Settings and taken
-- away when they untick it (lib/invite.lua studio_ui), or by the launcher itself once StudioSync's scripts are gone (uninstalled: no separate
-- uninstaller exists). The launcher never runs the link: it writes it, as plain text, to <home>/link/pending.txt and starts or wakes REAPER;
-- StudioSync reads that file within a second (lib/invite.lua tick, from Autostart and the panel) and checks it there like any other input.
--   Windows  HKCU\Software\Classes\studiosync (per user, no admin), its command wscript.exe running <home>/link/studiosync-link.js with the
--            link as its own argument (no cmd.exe, so nothing in a link is read as a command), then reaper.exe -nonewinst.
--   macOS    ~/Applications/StudioSync Link.app, an AppleScript applet (osacompile) with CFBundleURLTypes, registered with lsregister; its
--            `on open location` writes the file (quoted form of) and opens REAPER.
--   Linux    ~/.local/share/applications/studiosync-link.desktop (MimeType x-scheme-handler/studiosync, Exec the launcher with %u), made the
--            default with xdg-mime; the launcher is a /bin/sh script that printf's "$1" to the file.
-- Everything goes through an `io` table (write, remove, mkdir, run, read, exists) so tests run it on a stand-in file layer: nothing here ever
-- touches the registry or a real home folder in a test. GPL-3.0-or-later.
local urlhandler = {}
urlhandler.SCHEME = "studiosync"
urlhandler.WIN_KEY = [[HKCU\Software\Classes\studiosync]]
urlhandler.MAC_APP = "StudioSync Link.app"
urlhandler.DESKTOP = "studiosync-link.desktop"
urlhandler.LINK_MAX = 2048 -- (the launchers write nothing longer; lib/invite.lua refuses far less)

-- ---- pure: quoting -------------------------------------------------------------------------------------------------------------------
local function no_ctl(s) return type(s) == "string" and s ~= "" and not s:find("[%c]") end
function urlhandler.sh_q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end -- (POSIX single quotes: nothing inside is read)
function urlhandler.js_str(s) return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"' end
function urlhandler.as_str(s) return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"' end -- (an AppleScript string)
-- A .desktop Exec argument: in double quotes, with ", `, $ and \ escaped (the Desktop Entry spec), and % doubled.
function urlhandler.desktop_q(s) return '"' .. tostring(s):gsub('([\\"`$])', "\\%1"):gsub("%%", "%%%%") .. '"' end
local function win(p) return (tostring(p):gsub("/", "\\")) end

-- Where everything goes, from what REAPER and the environment say. o: { os = "win"|"mac"|"linux", home (StudioSync's home folder),
-- scripts (StudioSync's scripts folder), exe (REAPER's program: reaper.exe, the .app, or reaper), user_home, data_home (Linux, optional),
-- system_root (Windows, optional) }. -> the paths, or nil + why when one is missing or holds a control character.
function urlhandler.paths(o)
  if type(o) ~= "table" or not (o.os == "win" or o.os == "mac" or o.os == "linux") then return nil, "not a system StudioSync knows" end
  for _, k in ipairs({ "home", "scripts", "exe" }) do if not no_ctl(o[k]) then return nil, "no " .. k end end
  local p = { os = o.os, dir = o.home .. "/link", scripts = o.scripts, exe = o.exe }
  p.pending = p.dir .. "/pending.txt"
  if o.os == "win" then
    p.launcher = p.dir .. "/studiosync-link.js"
    p.wscript = win((no_ctl(o.system_root) and o.system_root or "C:\\Windows") .. "\\System32\\wscript.exe")
  else
    if not no_ctl(o.user_home) then return nil, "no home folder" end
    if o.os == "mac" then
      p.source = p.dir .. "/StudioSync Link.applescript"
      p.app = o.user_home .. "/Applications/" .. urlhandler.MAC_APP
      p.script = p.dir .. "/install.sh"
    else
      p.launcher = p.dir .. "/studiosync-link.sh"
      p.apps = (no_ctl(o.data_home) and o.data_home or (o.user_home .. "/.local/share")) .. "/applications"
      p.desktop = p.apps .. "/" .. urlhandler.DESKTOP
      p.script = p.dir .. "/install.sh"
    end
  end
  return p
end

-- ---- pure: what each system's files say ------------------------------------------------------------------------------------------------
function urlhandler.win_launcher(p)
  return table.concat({
    "// StudioSync link launcher, written by lib/urlhandler.lua (Settings > Open StudioSync links on this computer). GPL-3.0-or-later.",
    "// It only writes the link it was given to a file StudioSync reads and checks, then starts or wakes REAPER: the link is never run.",
    "var fso = new ActiveXObject(\"Scripting.FileSystemObject\"), sh = new ActiveXObject(\"WScript.Shell\");",
    "var PENDING = " .. urlhandler.js_str(win(p.pending)) .. ", SCRIPTS = " .. urlhandler.js_str(win(p.scripts)) .. ", EXE = " .. urlhandler.js_str(win(p.exe)) .. ";",
    "if (!fso.FolderExists(SCRIPTS)) { // (StudioSync is gone: so is its link handler)",
    "  try { sh.Run('reg.exe delete \"" .. urlhandler.WIN_KEY .. "\" /f', 0, true); fso.DeleteFile(WScript.ScriptFullName); } catch (e) {}",
    "  WScript.Quit(0);",
    "}",
    "var url = WScript.Arguments.length > 0 ? String(WScript.Arguments(0)) : \"\";",
    "if (url.length > 0 && url.length <= " .. urlhandler.LINK_MAX .. " && url.toLowerCase().indexOf(\"studiosync:\") === 0 && /^[\\x21-\\x7e]+$/.test(url)) {",
    "  try {",
    "    var f = fso.CreateTextFile(PENDING + \".tmp\", true, false); f.Write(url); f.Close();",
    "    if (fso.FileExists(PENDING)) fso.DeleteFile(PENDING);",
    "    fso.MoveFile(PENDING + \".tmp\", PENDING);",
    "    sh.Run('\"' + EXE + '\" -nonewinst', 1, false);",
    "  } catch (e) {}",
    "}",
    "" }, "\r\n")
end
-- The registry command's value: wscript.exe, the launcher, the link as one argument.
function urlhandler.win_command(p)
  return '"' .. p.wscript .. '" //B //Nologo "' .. win(p.launcher) .. '" "%1"'
end
-- reg.exe's /d value: quotes inside escaped as \".
local function reg_d(s) return '"' .. s:gsub('"', '\\"') .. '"' end

function urlhandler.mac_source(p)
  local q = urlhandler.as_str
  return table.concat({
    "-- StudioSync link launcher, written by lib/urlhandler.lua (Settings > Open StudioSync links on this computer). GPL-3.0-or-later.",
    "-- It only writes the link it was given to a file StudioSync reads and checks, then opens REAPER: the link is never run.",
    "on open location theURL",
    "  try",
    "    do shell script \"test -d \" & quoted form of " .. q(p.scripts),
    "  on error -- (StudioSync is gone: so is its link handler)",
    "    do shell script \"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u \" & quoted form of " .. q(p.app) .. " & \"; rm -rf \" & quoted form of " .. q(p.app),
    "    return",
    "  end try",
    "  if theURL does not start with \"studiosync:\" or (length of theURL) > " .. urlhandler.LINK_MAX .. " then return",
    "  set pending to " .. q(p.pending),
    "  do shell script \"printf '%s' \" & quoted form of theURL & \" > \" & quoted form of (pending & \".tmp\") & \" && mv -f \" & quoted form of (pending & \".tmp\") & \" \" & quoted form of pending",
    "  do shell script \"open \" & quoted form of " .. q(p.exe),
    "end open location",
    "" }, "\n")
end
local LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
function urlhandler.mac_script(p)
  local q, plist = urlhandler.sh_q, p.app .. "/Contents/Info.plist"
  local pb = "/usr/libexec/PlistBuddy -c "
  return table.concat({
    "#!/bin/sh",
    "# StudioSync's link handler for this Mac (lib/urlhandler.lua). Run once, from Settings.",
    "set -e",
    "mkdir -p " .. q(p.app:match("^(.*)/[^/]+$")),
    "rm -rf " .. q(p.app),
    "osacompile -o " .. q(p.app) .. " " .. q(p.source),
    pb .. q("Add :CFBundleIdentifier string com.studiosync.link") .. " " .. q(plist) .. " 2>/dev/null || " .. pb .. q("Set :CFBundleIdentifier com.studiosync.link") .. " " .. q(plist),
    pb .. q("Add :LSUIElement bool true") .. " " .. q(plist) .. " 2>/dev/null || true",
    pb .. q("Add :CFBundleURLTypes array") .. " " .. q(plist),
    pb .. q("Add :CFBundleURLTypes:0 dict") .. " " .. q(plist),
    pb .. q("Add :CFBundleURLTypes:0:CFBundleURLName string StudioSync link") .. " " .. q(plist),
    pb .. q("Add :CFBundleURLTypes:0:CFBundleURLSchemes array") .. " " .. q(plist),
    pb .. q("Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string studiosync") .. " " .. q(plist),
    LSREGISTER .. " -f " .. q(p.app),
    "" }, "\n")
end
function urlhandler.mac_unscript(p)
  local q = urlhandler.sh_q
  return table.concat({ "#!/bin/sh", "# StudioSync's link handler taken away (lib/urlhandler.lua).",
    LSREGISTER .. " -u " .. q(p.app) .. " 2>/dev/null", "rm -rf " .. q(p.app), "" }, "\n")
end

function urlhandler.linux_launcher(p)
  local q = urlhandler.sh_q
  return table.concat({
    "#!/bin/sh",
    "# StudioSync link launcher, written by lib/urlhandler.lua (Settings > Open StudioSync links on this computer). GPL-3.0-or-later.",
    "# It only writes the link it was given to a file StudioSync reads and checks, then starts or wakes REAPER: the link is never run.",
    "PENDING=" .. q(p.pending) .. "; SCRIPTS=" .. q(p.scripts) .. "; EXE=" .. q(p.exe) .. "; DESKTOP=" .. q(p.desktop),
    "if [ ! -d \"$SCRIPTS\" ]; then # (StudioSync is gone: so is its link handler)",
    "  rm -f \"$DESKTOP\" \"$0\"; update-desktop-database \"$(dirname \"$DESKTOP\")\" >/dev/null 2>&1; exit 0",
    "fi",
    "case \"$1\" in [Ss][Tt][Uu][Dd][Ii][Oo][Ss][Yy][Nn][Cc]:*) ;; *) exit 0 ;; esac",
    "[ \"${#1}\" -le " .. urlhandler.LINK_MAX .. " ] || exit 0",
    "printf '%s' \"$1\" > \"$PENDING.tmp\" && mv -f \"$PENDING.tmp\" \"$PENDING\"",
    "\"$EXE\" -nonewinst >/dev/null 2>&1 &",
    "" }, "\n")
end
function urlhandler.linux_desktop(p)
  return table.concat({
    "[Desktop Entry]",
    "Type=Application",
    "Name=StudioSync link",
    "Comment=Opens studiosync:// links in REAPER (StudioSync)",
    "Exec=/bin/sh " .. urlhandler.desktop_q(p.launcher) .. " %u",
    "NoDisplay=true",
    "Terminal=false",
    "MimeType=x-scheme-handler/studiosync;",
    "" }, "\n")
end
function urlhandler.linux_script(p)
  local q = urlhandler.sh_q
  return table.concat({ "#!/bin/sh", "# StudioSync's link handler for this computer (lib/urlhandler.lua). Run once, from Settings.",
    "chmod 755 " .. q(p.launcher),
    "xdg-mime default " .. urlhandler.DESKTOP .. " x-scheme-handler/studiosync",
    "update-desktop-database " .. q(p.apps) .. " >/dev/null 2>&1 || true", "" }, "\n")
end

-- ---- the steps ---------------------------------------------------------------------------------------------------------------------------
-- -> { { mkdir = dir } | { write = path, text } | { run = command } | { remove = path } }, or nil + why. Pure.
function urlhandler.install_steps(o)
  local p, why = urlhandler.paths(o)
  if not p then return nil, why end
  local s = { { mkdir = p.dir } }
  if p.os == "win" then
    s[#s + 1] = { write = p.launcher, text = urlhandler.win_launcher(p) }
    local k = urlhandler.WIN_KEY
    s[#s + 1] = { run = 'reg.exe add "' .. k .. '" /ve /d "URL:StudioSync link" /f' }
    s[#s + 1] = { run = 'reg.exe add "' .. k .. '" /v "URL Protocol" /d "" /f' }
    s[#s + 1] = { run = 'reg.exe add "' .. k .. '\\DefaultIcon" /ve /d ' .. reg_d('"' .. win(p.exe) .. '",0') .. ' /f' }
    s[#s + 1] = { run = 'reg.exe add "' .. k .. '\\shell\\open\\command" /ve /d ' .. reg_d(urlhandler.win_command(p)) .. ' /f' }
  elseif p.os == "mac" then
    s[#s + 1] = { write = p.source, text = urlhandler.mac_source(p) }
    s[#s + 1] = { write = p.script, text = urlhandler.mac_script(p) }
    s[#s + 1] = { run = "/bin/sh " .. urlhandler.sh_q(p.script) }
    s[#s + 1] = { remove = p.script }
  else
    s[#s + 1] = { write = p.launcher, text = urlhandler.linux_launcher(p) }
    s[#s + 1] = { mkdir = p.apps }
    s[#s + 1] = { write = p.desktop, text = urlhandler.linux_desktop(p) }
    s[#s + 1] = { write = p.script, text = urlhandler.linux_script(p) }
    s[#s + 1] = { run = "/bin/sh " .. urlhandler.sh_q(p.script) }
    s[#s + 1] = { remove = p.script }
  end
  return s, nil, p
end
-- Taking it away: only what's ours (the registry key while its command names our launcher; the .desktop file while it names it; the app at
-- its own path). io.read / io.run are asked to tell. -> steps, or nil + why. `io` may be nil (then everything that would be ours goes).
function urlhandler.uninstall_steps(o, io)
  local p, why = urlhandler.paths(o)
  if not p then return nil, why end
  local s = {}
  if p.os == "win" then
    local ours = true
    if io and io.run then
      local out = tostring(io.run('reg.exe query "' .. urlhandler.WIN_KEY .. '\\shell\\open\\command" /ve') or "")
      ours = out:lower():find(win(p.launcher):lower(), 1, true) ~= nil
    end
    if ours then s[#s + 1] = { run = 'reg.exe delete "' .. urlhandler.WIN_KEY .. '" /f' } end
    s[#s + 1] = { remove = p.launcher }
  elseif p.os == "mac" then
    s[#s + 1] = { mkdir = p.dir }
    s[#s + 1] = { write = p.script, text = urlhandler.mac_unscript(p) }
    s[#s + 1] = { run = "/bin/sh " .. urlhandler.sh_q(p.script) }
    s[#s + 1] = { remove = p.script }
    s[#s + 1] = { remove = p.source }
  else
    local text = io and io.read and io.read(p.desktop)
    if text == nil or tostring(text):find(urlhandler.desktop_q(p.launcher), 1, true) then s[#s + 1] = { remove = p.desktop } end -- (as its Exec line quotes it)
    s[#s + 1] = { remove = p.launcher }
    s[#s + 1] = { run = "update-desktop-database " .. urlhandler.sh_q(p.apps) }
  end
  s[#s + 1] = { remove = p.pending }
  return s, nil, p
end
-- Is it there, as ours? (Windows: the registry's command names our launcher; elsewhere the files are there.) -> true/false.
function urlhandler.installed(o, io)
  local p = urlhandler.paths(o)
  if not (p and io) then return false end
  if p.os == "win" then
    local out = tostring(io.run and io.run('reg.exe query "' .. urlhandler.WIN_KEY .. '\\shell\\open\\command" /ve') or "")
    return out:lower():find(win(p.launcher):lower(), 1, true) ~= nil
  elseif p.os == "mac" then return io.exists(p.app .. "/Contents/Info.plist") == true
  else return io.exists(p.desktop) == true and io.exists(p.launcher) == true end
end
-- Run the steps through `io` (stop at the first that fails). -> true, or false + what failed.
function urlhandler.apply(steps, io)
  for _, st in ipairs(steps or {}) do
    if st.mkdir then io.mkdir(st.mkdir)
    elseif st.write then if not io.write(st.write, st.text) then return false, "couldn't write " .. st.write end
    elseif st.remove then io.remove(st.remove)
    elseif st.run then
      local out = tostring(io.run(st.run) or "")
      local code = tonumber(out:match("^(%-?%d+)\n"))
      if code and code ~= 0 then return false, st.run:match("^(%S+)") .. " said: " .. (out:gsub("^%-?%d+\n", ""):gsub("%s+$", "")) end
    end
  end
  return true
end

-- ---- on this computer ----------------------------------------------------------------------------------------------------------------
-- What REAPER says, for paths(). scripts: StudioSync's own folder (the one holding lib/).
function urlhandler.here(scripts)
  local band = require("band")
  local os_ = reaper.GetOS()
  local kind = os_:match("^Win") and "win" or (os_:match("^OSX") or os_:match("^macOS")) and "mac" or "linux"
  local exe_dir = (reaper.GetExePath() or ""):gsub("\\", "/")
  local exe = kind == "win" and (exe_dir .. "/reaper.exe") or kind == "mac" and (exe_dir:match("^(.-%.app)") or "/Applications/REAPER.app") or (exe_dir .. "/reaper")
  return { os = kind, home = band.home(), scripts = scripts, exe = exe, user_home = os.getenv("HOME"), data_home = os.getenv("XDG_DATA_HOME"),
    system_root = os.getenv("SystemRoot") }
end
-- The real file layer: StudioSync's own writes, REAPER's ExecProcess (no shell on Windows: CreateProcess reads the quotes).
function urlhandler.real_io()
  local band = require("band")
  return {
    mkdir = function(d) reaper.RecursiveCreateDirectory(d, 0) end,
    write = function(p, t) return pcall(band.write_atomic, p, t) end,
    remove = function(p) os.remove(p) end,
    run = function(c) return reaper.ExecProcess(c, 20000) end,
    read = function(p) return band.read(p) end,
    exists = function(p) return reaper.file_exists(p) end,
  }
end
function urlhandler.install(o, io)
  local steps, why = urlhandler.install_steps(o)
  if not steps then return false, why end
  return urlhandler.apply(steps, io)
end
function urlhandler.uninstall(o, io)
  local steps, why = urlhandler.uninstall_steps(o, io)
  if not steps then return false, why end
  return urlhandler.apply(steps, io)
end

return urlhandler
