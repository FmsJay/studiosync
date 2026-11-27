-- P7 (rt-p7): the audit's wording for the three "Follow"s, startup.keep_open_mode vs Autostart's own copy, and a script that leaves PreventUIRefresh on.
package.path = "lib/?.lua;" .. package.path
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end

-- ---- wording: "Play and stop together" (transport) and "Watch <name>" (view) ----
for _, p in ipairs({ "lib/webui/play.js", "lib/page_play.lua", "lib/webpages.lua" }) do
  local s = read(p)
  assert(not s:find("Follow each other:", 1, true) and not s:find("Follow each other was", 1, true), p .. " still says Follow each other")
end
-- (rt-follow, 2026-11-27: the three are one Follow now, a person, everyone or the driver; tests/test_0_60_rt_follow2.lua has its words)
local js = read("lib/webui/play.js")
assert(js:find("'Everyone (whoever plays)'", 1, true) and js:find("'Follow'", 1, true) and not js:find("'Watch a bandmate'", 1, true), "the web page's words")
assert(read("lib/page_play.lua"):find("Everyone (whoever plays)", 1, true), "the panel's words")

-- ---- keep_open_mode vs Autostart's copy: the plan on disk wins ----
local now, projects, plan, mode = 0, {}, nil, 1
reaper = {
  GetResourcePath = function() return "res" end, time_precise = function() return now end,
  EnumProjects = function(i) if i == -1 then return projects[1] and projects[1].p end local x = projects[i + 1]; if x then return x.p, x.fn end end,
  SNM_GetIntConfigVar = function() return mode end, SNM_SetIntConfigVar = function(_, v) mode = v end,
  BR_Win32_WritePrivateProfileString = function() end, get_ini_file = function() return "ini" end,
}
package.loaded.band = { home = function() return "home" end, binding = function() return {} end,
  json_encode = function(t) local s = {}; for _, x in ipairs(t) do s[#s + 1] = x.path end; return table.concat(s, "|") end,
  write_json = function(_, t) plan = t end, read_json = function() return plan end }
os.remove = function(f) if f == "home/reopen.json" then plan = nil end end
local startup = require("startup")
projects = { { p = "a", fn = "A.rpp" } }
startup.note()
assert(plan.loadlastproj == 1, "noted: their choice 1")
mode = 18; plan.loadlastproj = 17 -- (Live sync's keep_open_mode found 17, wrote it to the plan and held the setting)
projects = { { p = "a", fn = "A.rpp" }, { p = "b", fn = "B.rpp" } }; now = 10
startup.note()
assert(plan.loadlastproj == 17, "a tab change in Autostart kept the person's new choice, not its old copy (" .. tostring(plan.loadlastproj) .. ")")
plan.loadlastproj = 9
band_open = nil
package.loaded.band.binding = function() return nil end
projects = { { p = "a", fn = "A.rpp" } }; now = 20
startup.note(); now = 24; startup.note() -- (fewer tabs count once they last 3 s)
assert(mode == 9 and plan == nil, "no studio song open: the setting goes back as the plan had it (" .. tostring(mode) .. ")")

-- ---- PreventUIRefresh left on ----
package.loaded.band = nil
package.loaded.startup = nil
reaper = setmetatable({ GetResourcePath = function() return "res" end }, { __index = function() return function() end end })
local compat = require("compat")
assert(compat.scan_text("reaper.PreventUIRefresh(1)\nwork()\n").uirefresh, "a +1 with no -1")
assert(compat.scan_text("reaper.PreventUIRefresh( 1 )\nreaper.PreventUIRefresh(1)\nreaper.PreventUIRefresh(-1)\n").uirefresh, "two +1, one -1")
assert(next(compat.scan_text("reaper.PreventUIRefresh(1)\nwork()\nreaper.PreventUIRefresh(-1)\n")) == nil, "balanced: nothing")
assert(next(compat.scan_text("-- reaper.PreventUIRefresh(1)\n")) == nil, "a comment: nothing")
assert(compat.KINDS.uirefresh[1] and compat.KINDS.uirefresh[2], "it has its words for Health")
print("ok")
