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
check(src:find("local function sub_lap(name) if perf.on then if perf.skip then perf.skip = false else lap(name) end end end", 1, true), "a sub-lap only while perf stats is on (and not for a paced step skipped: rt-perfcut3)")
local calls = 0
for at in src:gmatch("()laps_add%(perf%.laps") do
  calls = calls + 1
  local before = src:sub(math.max(1, at - 300), at)
  check(before:find("if perf.on then", 1, true), "laps_add only inside if perf.on")
end
check(calls == 1, "the tick adds its laps once: " .. calls)
check(src:find("laps = laps_table(perf.laps),", 1, true) and src:find("perf.laps = {}", 1, true), "published in tick stats and reset after")
-- the "save, drive" lap in parts inside P.save_drive (rt-drive2, round 7), and every tick over 50 ms kept with its laps while perf stats is on
local sd = src:find("function P.save_drive(t)", 1, true)
local sd_end = sd and src:find("\nfunction P%.", sd + 10)
check(sd and sd_end, "P.save_drive found")
local dn = 0
for at in src:gmatch('()sub_lap%("drive/') do dn = dn + 1; check(at > sd and at < sd_end, "a drive sub-lap outside P.save_drive: at " .. at) end
check(dn >= 6, "the drive lap's parts are marked: " .. dn)
local ov = src:find("perf.over[#perf.over + 1]", 1, true)
check(ov and src:sub(math.max(1, ov - 400), ov):find("if perf.on then", 1, true), "ticks over 50 ms kept only while perf stats is on")
check(src:find("over = #perf.over > 0 and perf.over or nil", 1, true) and src:find("perf.laps, perf.over = {}, {}", 1, true), "published and reset")
print("ok perf laps: totals, ticks and worst per lap, the start lap's sub-ticks, the drive lap's parts, ticks over 50 ms, only while perf stats is on")
