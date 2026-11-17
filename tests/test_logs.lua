-- The log on disk (lib/band.lua, 0.58.86): which day files are old enough to go, and the Console's lines read back from a file (lupa or Lua 5.4)
reaper = setmetatable({}, { __index = function() return function() end end })
package.path = "lib/?.lua;" .. package.path
local band = require("band")
local today = os.time({ year = 2026, month = 11, day = 16, hour = 21 })
local old = band.old_logs({ "studiosync-2026-11-16.log", "studiosync-2026-11-02.log", "studiosync-2026-10-01.log", "notes.log", "studiosync-2026-11-03.log" }, today, 14)
table.sort(old)
assert(#old == 2 and old[1] == "studiosync-2026-10-01.log" and old[2] == "studiosync-2026-11-02.log", "older than 14 days go, nothing else: " .. table.concat(old, ","))
local text = "21:01:02 [panel] the panel opened (StudioSync 0.58.86)\n21:01:05 [live Nostalgia] ERROR in live sync: boom\n    stack traceback:\n    in tick_body\n" ..
  "21:02:00 [autostart] Live sync started\n"
local lines = band.console_lines(text, 80)
assert(#lines == 3 and lines[1] == "21:01 the panel opened (StudioSync 0.58.86)" and lines[2] == "21:01 ERROR in live sync: boom", "lines as the Console shows them, the traceback left out")
assert(#band.console_lines(text, 2) == 2 and band.console_lines(text, 2)[2] == "21:02 Live sync started", "the last n")
assert(#band.console_lines(nil, 5) == 0, "no file: nothing")
print("ok")
