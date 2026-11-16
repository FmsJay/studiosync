-- Update REAPER: the REAPER Update Utility's file, read from FTC Tools' ReaPack index (lib/tools.lua tools.updater_url, 0.58.73)
reaper = reaper or { GetResourcePath = function() return "res" end }
package.path = "lib/?.lua;" .. package.path
local tools = require("tools")
local xml = [[<index><category name="Various">
  <reapack name="Other.lua" type="script"><version name="1.0"><source main="main">https://example.com/other.lua</source></version></reapack>
  <reapack name="REAPER Update Utility.lua" type="script">
    <version name="3.0.0"><source main="main">https://github.com/iliaspoulakis/Reaper-Tools/raw/aaa/Various/REAPER%20Update%20Utility.lua</source></version>
    <version name="3.1.0"><source main="main">https://github.com/iliaspoulakis/Reaper-Tools/raw/bbb/Various/REAPER%20Update%20Utility.lua?a=1&amp;b=2</source></version>
  </reapack></category></index>]]
assert(tools.updater_url(xml) == "https://github.com/iliaspoulakis/Reaper-Tools/raw/bbb/Various/REAPER%20Update%20Utility.lua?a=1&b=2", "its newest version, not another package's")
assert(tools.updater_url("") == nil and tools.updater_url(nil) == nil, "nothing to read: nothing")
assert(tools.TESTED_REAPER:match("^%d+%.%d+$"), "a REAPER version")
print("ok")
