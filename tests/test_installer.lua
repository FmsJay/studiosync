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
os.remove(dir .. "/Scripts")
os.remove(dir)
print("ok")
