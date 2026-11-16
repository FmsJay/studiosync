-- localcopy.trash_script is pure (lupa or Lua 5.4, from the repo root)
package.path = "lib/?.lua;" .. package.path
reaper = reaper or { GetOS = function() return "OSX64" end }
package.loaded.band = package.loaded.band or {}
local copy = require("localcopy")
local s = copy.trash_script({ "/m/QA/rooms/main/events", "/m/QA/rooms/main/media" }, "QA Trash Test", "2026-11-04 08.31.05")
assert(s:find("'StudioSync - QA Trash Test - 2026-11-04 08.31.05 - 1 events'", 1, true), "the project's name is in what the Trash shows")
assert(s:find("'StudioSync - QA Trash Test - 2026-11-04 08.31.05 - 2 media'; fi\n", 1, true), "each path has its own name")
assert(copy.trash_script({ "/m/Old Studio" }, nil, "T"):find("'StudioSync - T - 1 Old Studio'", 1, true), "a whole studio keeps its own name")
assert(copy.trash_script({ "/m/It's" }, "It's", "T"):find([[if [ -e '/m/It'\''s' ]; then mv '/m/It'\''s' "$HOME/.Trash/"'StudioSync - It'\''s - T - 1 It'\''s'; fi]], 1, true), "a quote in a name can't break out")
-- (0.58.63) a refused move is noted, so the message can say macOS refused it
assert(copy.trash_script({ "/m/A" }, "A", "T", "/tmp/x.notrash"):find(" || touch '/tmp/x.notrash'; fi\n", 1, true), "a refused move leaves its note")
-- (0.58.74) Linux: the desktop's Trash through gio, its quote-safety the same
assert(copy.trash_script({ "/m/It's" }, "x", "T", "/tmp/n", true) == [[if [ -e '/m/It'\''s' ]; then gio trash '/m/It'\''s' || touch '/tmp/n'; fi]] .. "\n", "Linux: gio trash")
print("ok")
