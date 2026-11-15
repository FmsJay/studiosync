-- The panel's first-run checklist: which steps show, and when it goes (lupa or Lua 5.4, from the repo root)
reaper = setmetatable({}, { __index = function() return function() end end })
package.path = "lib/?.lua;" .. package.path
package.loaded.groups, package.loaded.chooser, package.loaded.theme = {}, {}, {}
local pg = require("page_groups")
local s = pg.checklist_steps({ starter = true })
assert(#s == 3 and not s[1][2] and s[2][1]:find("^Share"), "nothing yet: start or join, then the starter's steps")
s = pg.checklist_steps({ in_studio = true, starter = false, waiting = true })
assert(s[1][2] and not s[2][2] and s[2][1]:find("^Get let in"), "joined, waiting: the next step is being let in")
assert(not pg.checklist_steps({ in_studio = true, starter = false, waiting = true, others = true })[2][2], "still waiting: not let in yet")
assert(pg.checklist_steps({ in_studio = true, starter = true, projects = true, others = false })[3][1]:find("^Invite"), "shared, nobody invited yet")
assert(pg.checklist_steps({ in_studio = true, starter = true, projects = true, others = true }) == nil, "all done: it goes")
assert(pg.checklist_steps({ in_studio = true, starter = false, others = true, projects = true }) == nil, "a joiner let in, with projects: it goes")
print("ok")
