-- lib/startup.lua's note at quit (0.58.69): REAPER on a Mac closes the tabs one at a time with scripts still running, and the plan
-- went with them. Fewer tabs count only once they've stayed fewer for 3 s.
package.path = "lib/?.lua;" .. package.path
local now, projects, written, removed, mode = 0, {}, nil, false, 1
reaper = {
  GetResourcePath = function() return "res" end,
  time_precise = function() return now end,
  EnumProjects = function(i) if i == -1 then return projects[1] and projects[1].p end local x = projects[i + 1]; if x then return x.p, x.fn end end,
  SNM_GetIntConfigVar = function() return mode end, SNM_SetIntConfigVar = function(_, v) mode = v end,
  BR_Win32_WritePrivateProfileString = function() end, get_ini_file = function() return "ini" end,
}
local json = function(t) local s = {}; for _, x in ipairs(t) do s[#s + 1] = x.path end; return table.concat(s, "|") end
package.loaded.band = { home = function() return "home" end, binding = function(p) return p ~= "own" and {} or nil end,
  json_encode = function(t) return json(t) end, write_json = function(_, t) written = t; removed = false end, read_json = function() return written end }
local _remove = os.remove
os.remove = function(f) if f == "home/reopen.json" then written, removed = nil, true end end
local startup = require("startup")

projects = { { p = "a", fn = "A.rpp" }, { p = "b", fn = "B.rpp" }, { p = "c", fn = "C.rpp" } }
startup.note()
assert(written and #written.tabs == 3, "three studio tabs noted")
projects = { { p = "a", fn = "A.rpp" } }; now = 0.5; startup.note()
projects = {}; now = 1; startup.note()
startup.on_quit()
assert(written and #written.tabs == 3 and not removed, "quitting closed them one by one: the plan still has all three")
-- closing one on purpose (REAPER didn't quit after all: all three are back first): noted once it's lasted
projects = { { p = "a", fn = "A.rpp" }, { p = "b", fn = "B.rpp" }, { p = "c", fn = "C.rpp" } }; now = 5; startup.note()
projects = { { p = "a", fn = "A.rpp" }, { p = "b", fn = "B.rpp" } }; now = 10; startup.note()
assert(#written.tabs == 3, "not at once")
now = 13.5; startup.note()
assert(#written.tabs == 2, "3 s later: two")
-- (0.58.75) a quit held up past the 3 s (a dialog in the way): the plan's gone, but the band tabs of the last 2 minutes come back
local band_tabs = { { path = "A.rpp", band = true } }
assert(startup.quit_tabs({}, { tabs = band_tabs, at = 100 }, 150) == band_tabs, "closed by a stalled quit a moment ago: reopened")
assert(startup.quit_tabs({}, { tabs = band_tabs, at = 100 }, 400) == nil, "closed on purpose minutes before quitting: not")
assert(startup.quit_tabs(band_tabs, nil, 0) == band_tabs and startup.quit_tabs({ { path = "own.rpp" } }, nil, 0) == nil, "the tabs as noted, when they hold a band song")
os.remove = _remove
print("ok")
