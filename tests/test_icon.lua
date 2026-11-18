-- 0.59.17 (lupa or Lua 5.4, from the repo root): a REAPER track icon is the same on every computer, wherever its REAPER is.
package.path = "lib/?.lua;" .. package.path
reaper = reaper or {}
reaper.GetOS = reaper.GetOS or function() return "Win64" end
reaper.GetExtState = reaper.GetExtState or function() return "" end
local mirror = require("mirror")
assert(mirror.icon_key("J:/Portable Workstation/DAW/REAPER\\Data\\track_icons\\bass4.png") == "track_icons/bass4.png", "the desktop's")
assert(mirror.icon_key("D:/Portable Workstation/DAW/REAPER\\Data\\track_icons\\bass4.png") == "track_icons/bass4.png", "the laptop's")
assert(mirror.icon_key("/Users/x/Library/Application Support/REAPER/Data/track_icons/sub/kick.png") == "track_icons/sub/kick.png", "a Mac's, in a folder")
assert(mirror.icon_key("C:/Pictures/me.png") == "C:/Pictures/me.png", "a picture of your own stays as it is")
assert(mirror.icon_key(nil) == "" and mirror.icon_key("") == "", "none")
local a = { name = "Bass", icon = "J:/Portable Workstation/DAW/REAPER\\Data\\track_icons\\bass4.png" }
local b = { name = "Bass", icon = "D:/Portable Workstation/DAW/REAPER\\Data\\track_icons\\bass4.png" }
assert(mirror.track_line(a, false, false) == mirror.track_line(b, false, false), "one track, the same line on both computers")
print("ok icon")
