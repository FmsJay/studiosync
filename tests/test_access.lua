-- Guests who see only some projects (lib/access.lua, 0.58.89), and the release's file list (lib/band.lua files_list). Lupa or Lua 5.4.
reaper = setmetatable({}, { __index = function() return function() end end })
package.path = "lib/?.lua;" .. package.path
local access = require("access")
local band = require("band")
assert(access.shows(nil, "Any") and access.shows({ Lantern = true }, "Lantern") and not access.shows({ Lantern = true }, "Nostalgia"), "no list: all; a list: only those")
local files = band.files_list("version 1.2\nlib/band.lua\t1200\r\nStudioSync - Panel.lua\t99\n")
assert(#files == 2 and files[1].path == "lib/band.lua" and files[1].len == 1200 and files[2].path == "StudioSync - Panel.lua", "path and length, a CR or a space in a name no matter")
assert(#band.files_list(nil) == 0, "no list: nothing")
print("ok")
