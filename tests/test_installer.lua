-- The installers and the panel agree on REAPER's startup file, and changing it never loses what else is in it (lupa or Lua 5.4,
-- from the repo root)
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end
local mark = read("lib/tools.lua"):match('local MARK_A, MARK_Z = "([^"]+)"')
assert(mark == "-- BandSync autostart", "the panel's marker: " .. tostring(mark))
-- (0.58.54: the Mac installer looked for "StudioSync autostart", never found it, and always took the route that can crash REAPER)
local mac = read("installer/install_mac.sh"):match('grep %-q "([^"]+)" "%$RES/Scripts/__startup%.lua"')
assert(mac and mark:find(mac, 1, true), "the Mac installer finds the panel's marker: " .. tostring(mac))
assert(read("installer/studiosync_setup.lua"):find(mark, 1, true), "and setup writes the same one")

-- tools.set_autostart against a real file in a scratch folder: the person's own lines stay, an old block is replaced, never two
local dir = ((os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/")) .. "/ss_inst_" .. os.time()
os.execute(package.config:sub(1, 1) == "\\" and ('mkdir "' .. (dir .. "/Scripts"):gsub("/", "\\") .. '"') or ("mkdir -p '" .. dir .. "/Scripts'"))
local startup = dir .. "/Scripts/__startup.lua"
local function exists(p) local f = io.open(p, "rb"); if f then f:close() end; return f ~= nil end
reaper = setmetatable({ GetResourcePath = function() return dir end, file_exists = exists, RecursiveCreateDirectory = function() return 1 end },
  { __index = function() return function() end end })
package.path = "lib/?.lua;" .. package.path
local tools = require("tools")
local band = require("band")
local function put(s) local f = assert(io.open(startup, "wb")); f:write(s); f:close() end
put("dofile('mine.lua')\n" .. mark .. "\ndofile([[/old/StudioSync - Autostart.lua]])\n-- /BandSync autostart\nprint('after')\n")
assert(tools.set_autostart(true, "/new"))
local s = read(startup)
assert(s:find("dofile('mine.lua')", 1, true) and s:find("print('after')", 1, true), "the person's own lines stay: " .. s)
assert(s:find("/new/StudioSync - Autostart.lua", 1, true) and not s:find("/old/", 1, true), "the old block is replaced")
local _, n = s:gsub(mark, "")
assert(n == 1, "one block, not two")
assert(tools.set_autostart(false))
assert(not read(startup):find(mark, 1, true) and read(startup):find("print('after')", 1, true), "turned off: ours goes, theirs stays")
-- the file is there but can't be read: left alone, not written over with only ours
local real = band.read
band.read = function() return nil end
local ok = tools.set_autostart(true, "/new")
band.read = real
assert(not ok and read(startup):find("print('after')", 1, true), "an unreadable startup file is left as it was")
os.remove(startup)

-- (0.58.78) lib/services.lua on Windows: its batch files switch cmd to UTF-8 first (a user name with accents in %TEMP%), and every
-- `syncthing cli`, and a start, carries the settings folder the installer found (SyncTrayzor's, a snap's), never Syncthing's own guess
local ext, calls, written = {}, {}, {}
reaper.GetOS = function() return "Win64" end
reaper.GetExtState = function(_, k) return ext[k] or "" end
reaper.ExecProcess = function(c) calls[#calls + 1] = c; return "0\n" end
reaper.file_exists = function() return true end
reaper.time_precise = os.clock
local real_write = band.write_atomic
band.write_atomic = function(p, s) written[p] = s; return true end
package.loaded.services = nil
local services = require("services")
services.background("probe", "echo hi", 0)
local bat
for p, s in pairs(written) do if p:match("bandsync%-probe%.cmd$") then bat = s end end
assert(bat and bat:find("^@chcp 65001 >nul\r\n@echo hi > "), "the batch file switches to UTF-8 first: " .. tostring(bat))
ext.syncthing_path = "C:/st/syncthing.exe"
services.device_name("ABCDEFG")
assert(calls[#calls]:find('"C:/st/syncthing.exe" cli config devices ABCDEFG name get', 1, true), "no home told: Syncthing's own: " .. calls[#calls])
ext.syncthing_home = "C:/Users/J\195\188rgen/SyncTrayzor/data/syncthing"
services.device_name("ABCDEFG")
assert(calls[#calls]:find(' cli --home "C:/Users/J\195\188rgen/SyncTrayzor/data/syncthing" config devices', 1, true), "the installer's home: " .. calls[#calls])
calls = {}
assert(services.ensure_syncthing() == "started")
local started = false
-- (its quotes escaped for the outer ones round the PowerShell command: unescaped, they ended them. 0.58.92)
for _, c in ipairs(calls) do started = started or c:find('--home=\\"C:/Users/J\195\188rgen/SyncTrayzor/data/syncthing\\"', 1, true) ~= nil end
assert(started, "and started on it: " .. table.concat(calls, " | "))
band.write_atomic = real_write
package.loaded.services = nil

-- (0.58.78) studiosync_setup.lua keeps which Syncthing the installer set up, and an invitation's studio by its name until its band.json
-- arrives (a joiner not let in yet saw "the studio": Windows Sandbox run); a folder that isn't a studio's is never named
os.execute(package.config:sub(1, 1) == "\\" and ('mkdir "' .. (dir .. "/installer"):gsub("/", "\\") .. '"') or ("mkdir -p '" .. dir .. "/installer'"))
local helper = dir .. "/installer/studiosync_setup.lua"
local hf = assert(io.open(helper, "wb")); hf:write(read("installer/studiosync_setup.lua")); hf:close()
local json = require("json")
reaper.GetAppVersion = function() return "7.86/win64" end
reaper.SetExtState = function(_, k, v) ext[k] = v end
reaper.DeleteExtState = function(_, k) ext[k] = nil end
reaper.file_exists = exists
local function setup(req)
  os.remove(dir .. "/installer/studiosync_setup_started"); os.remove(dir .. "/installer/studiosync_setup_result.json")
  req.sync_root, req.user, req.mode = dir, "Jurgen", "verify"
  local f = assert(io.open(dir .. "/installer/studiosync_setup.json", "wb")); f:write(json.encode(req)); f:close()
  dofile(helper)
  return json.decode(read(dir .. "/installer/studiosync_setup_result.json"))
end
ext = {}
local res = setup({ syncthing_path = "/snap/bin/syncthing", syncthing_home = "/home/j/snap/syncthing/current/.local/state/syncthing",
  band_id = "studiosync-sandbox-test-1a2b", band_name = "Sandbox Test" })
assert(res.steps[1] and ext.user == "Jurgen" and ext.sync_root == dir, "the helper ran: " .. json.encode(res))
assert(ext.syncthing_path == "/snap/bin/syncthing" and ext.syncthing_home == "/home/j/snap/syncthing/current/.local/state/syncthing", "Syncthing kept")
local j = json.decode(ext["joining " .. dir] or "null")
assert(j and j.name == "Sandbox Test" and j.id == "studiosync-sandbox-test-1a2b", "the studio's name until band.json: " .. tostring(ext["joining " .. dir]))
ext = { syncthing_home = "/old" }
setup({ syncthing_path = "", syncthing_home = "", band_id = "default", band_name = "Mine" })
assert(ext.syncthing_home == nil and ext.syncthing_path == nil, "an empty home clears the old one; an empty path sets nothing")
assert(ext["joining " .. dir] == nil, "Syncthing's own default folder is never named a studio")
for _, n in ipairs({ "studiosync_setup.lua", "studiosync_setup.json", "studiosync_setup_started", "studiosync_setup_result.json" }) do os.remove(dir .. "/installer/" .. n) end
os.remove(dir .. "/installer")

-- (0.58.78) what each installer must keep doing (each one's own review item): GitHub lookups kept and read from the release page at the
-- limit; the long first start waited for, and "carries on by itself" said instead of "run this again"; the Syncthing it set up and the
-- invitation's studio told to REAPER
for _, f in ipairs({ "installer/install_windows.ps1", "installer/install_mac.sh", "installer/install_linux.sh" }) do
  local s = read(f)
  for _, want in ipairs({ "X-RateLimit-Remaining", "expanded_assets", "studiosync_setup_started", "2700", "Run this again only if the panel never appears",
    "syncthing_home", "band_name", "upgrades.syncthing.net" }) do
    if not (want == "upgrades.syncthing.net" and f:find("mac")) then assert(s:find(want, 1, true), f .. " lost: " .. want) end
  end
end
local win = read("installer/install_windows.ps1")
assert(win:find("chcp 65001", 1, true) and not win:find("-Encoding ascii", 1, true), "the Windows installer's own batch file is UTF-8")
assert(not win:find("[\128-\255]"), "the Windows installer stays ASCII: Windows PowerShell reads it as ANSI")
assert(read("installer/install_mac.sh"):find("sw_vers -productVersion", 1, true), "the Mac installer says when macOS is too old")
assert(read("installer/install_linux.sh"):find("fm.reaper.Reaper", 1, true), "the Linux installer knows a Flatpak REAPER")
os.remove(dir .. "/Scripts")
os.remove(dir)
print("ok")
