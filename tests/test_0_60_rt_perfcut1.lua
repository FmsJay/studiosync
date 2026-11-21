-- Per-lap totals in Live sync's perf stats (rt-perf's cut 3, rt-perfcut1; finished in rt-drive2): each lap's total, the ticks it ran in and
-- its worst over the 10 s, largest total first, and the "start" lap split into its sub-ticks while perf stats is on.
local f = assert(io.open("StudioSync - Live sync.lua", "rb"))
local src = f:read("a"):gsub("\r\n", "\n")
f:close()
local function check(cond, what) if not cond then error(what, 2) end end

-- laps_add and laps_table, as the file has them
local a = src:find("local function laps_add", 1, true)
local z = src:find("local last_session", a, true)
check(a and z, "laps_add and laps_table are in Live sync")
local chunk = assert(load(src:sub(a, z - 1) .. "\nreturn laps_add, laps_table", "laps", "t", { math = math, pairs = pairs, table = table }))
local laps_add, laps_table = chunk()
local sums = {}
laps_add(sums, { "start", 0.001, "receive", 0.004, "save, drive", 0.020 })
laps_add(sums, { "start", 0.002, "save, drive", 0.008 })
laps_add(sums, { "start", 0.0005 })
local t = laps_table(sums)
check(#t == 3 and t[1][1] == "save, drive" and t[1][2] == 28 and t[1][3] == 2 and t[1][4] == 20, "the largest total first, with its ticks and worst")
check(t[2][1] == "receive" and t[2][2] == 4 and t[2][3] == 1, "then the next")
check(t[3][1] == "start" and t[3][2] == 3.5 and t[3][3] == 3 and t[3][4] == 2, "ms to two places: " .. t[3][2] .. " " .. t[3][4])

-- every sub-lap in tick_body before lap("start"); the sums only while perf stats is on, and reset with each publish
local body = src:find("local function tick_body()", 1, true)
local start = src:find('\n  lap("start")', body, true)
check(body and start, "tick_body and its start lap")
local n = 0
for at in src:gmatch('()sub_lap%("start/') do
  n = n + 1
  check(at > body and at < start, "a sub-lap outside tick_body's start: at " .. at)
end
check(n >= 15, "the start lap's sub-ticks are marked: " .. n)
check(src:find("local function sub_lap(name) if perf.on then lap(name) end end", 1, true), "a sub-lap only while perf stats is on")
local calls = 0
for at in src:gmatch("()laps_add%(perf%.laps") do
  calls = calls + 1
  local before = src:sub(math.max(1, at - 300), at)
  check(before:find("if perf.on then", 1, true), "laps_add only inside if perf.on")
end
check(calls == 1, "the tick adds its laps once: " .. calls)
check(src:find("laps = laps_table(perf.laps),", 1, true) and src:find("perf.laps = {}", 1, true), "published in tick stats and reset after")
print("ok perf laps: totals, ticks and worst per lap, the start lap's sub-ticks, only while perf stats is on")
