-- The cloud copy's file work off REAPER's thread (rt-drivebg, lib/drivebg.lua). Four parts:
--  1. the plan/result protocol's pure parts (listings as each worker writes them, results, the plan text);
--  2. one room's pass through a stand-in worker (in memory) ends exactly as drive.mirror on REAPER's thread does, with not one cloud read or
--     write on REAPER's thread, the storage sweep's reads planned too, and a failed download never taken as a delete;
--  3. a stand-in slow drive (each cloud call 25 ms): the old pass holds REAPER that long per call, the planned one never touches it;
--  4. the real worker scripts (PowerShell on Windows, /bin/sh elsewhere; Git's sh here too when it's installed), started as Live sync starts
--     them: the protocol on real folders, a slow drive (main thread stays under 20 ms a tick), a worker stuck on a step, one killed part-way,
--     one that never starts, and three failures in a row putting passes back on REAPER's thread.
package.path = "lib/?.lua;" .. package.path
local json = require("json")

-- ---- a stand-in file system (parts 1-3) ----
local fs, mt, tick = {}, {}, 0 -- path -> contents; path -> modified stamp
local main_cloud, slow_ms = 0, 0 -- cloud calls made through REAPER's functions (the main thread), and what each costs
local function busy(ms) local t = os.clock() + ms / 1000; while os.clock() < t do end end
local function on_cloud(p)
  if type(p) == "string" and (p == "/C" or p:sub(1, 3) == "/C/") then main_cloud = main_cloud + 1; if slow_ms > 0 then busy(slow_ms) end end
end
local function put(p, v) fs[p] = v; tick = tick + 1; mt[p] = tick end
local function kids(dir, want_dirs)
  local out, seen = {}, {}
  for p in pairs(fs) do
    local rest = p:sub(1, #dir + 1) == dir .. "/" and p:sub(#dir + 2)
    if rest then
      local first, more = rest:match("^([^/]+)(/?)")
      if first and (more == "/") == want_dirs and not seen[first] then seen[first] = true; out[#out + 1] = first end
    end
  end
  table.sort(out)
  return out
end
local function conflict(f) return f:match(" %(%d+%)%.[^.]+$") ~= nil end
local logs, ext, clock = {}, {}, 1000
local band = {
  SECTION = "StudioSync", WIN = false,
  files = function(dir, e)
    on_cloud(dir)
    local out = {}
    for _, f in ipairs(kids(dir, false)) do if (not e or f:lower():sub(-#e) == e) and not conflict(f) then out[#out + 1] = f end end
    return out
  end,
  subdirs = function(dir) on_cloud(dir); return kids(dir, true) end,
  read = function(p) on_cloud(p); return fs[p] end,
  read_json = function(p) on_cloud(p); local s = fs[p]; if not s then return nil end; local ok, v = pcall(json.decode, s); return ok and type(v) == "table" and v or nil end,
  write_json = function(p, t) on_cloud(p); put(p, json.encode(t)) end,
  write_atomic = function(p, s) on_cloud(p); put(p, s) end,
  json_encode = function(t) return json.encode(t) end, json_decode = function(s) local ok, v = pcall(json.decode, s); return ok and v or nil end,
  size = function(p) on_cloud(p); return fs[p] and #fs[p] or nil end,
  copy_atomic = function(a, z) on_cloud(a); on_cloud(z); assert(fs[a], "copied from nowhere: " .. a); put(z, fs[a]) end,
  copy_background = function(a, z) on_cloud(a); on_cloud(z); put(z, fs[a]) end,
  log = function(s) logs[#logs + 1] = s end,
  home = function() return "/H" end,
  song_dir = function(cfg, song) return cfg.root .. "/" .. song end,
  studio_update_key = function() return nil end,
}
package.loaded.band = band
reaper = setmetatable({
  time_precise = function() return clock end,
  file_exists = function(p) on_cloud(p); return fs[p] ~= nil end,
  EnumerateFiles = function(dir, i) if i < 0 then return nil end; on_cloud(dir); return kids(dir, false)[i + 1] end, -- (every name, as REAPER's)
  EnumerateSubdirectories = function(dir, i) if i < 0 then return nil end; return band.subdirs(dir)[i + 1] end,
  RecursiveCreateDirectory = function(d) on_cloud(d); return 1 end,
  GetExtState = function(_, k) return ext[k] or "" end,
  SetExtState = function(_, k, v) ext[k] = v end,
  GetOS = function() return "Other" end,
}, { __index = function() return function() end end })
local real_remove, real_rename = os.remove, os.rename
os.remove = function(p) on_cloud(p); if fs[p] == nil then return nil, "no such file" end; fs[p], mt[p] = nil, nil; return true end
os.rename = function(a, z) on_cloud(a); on_cloud(z); if fs[a] == nil or fs[z] ~= nil then return nil, "can't" end; put(z, fs[a]); fs[a], mt[a] = nil, nil; return true end
local function check(cond, what) if not cond then os.remove, os.rename = real_remove, real_rename; error(what, 2) end end
package.loaded.songsync = { here = function() return { "Song" } end }
package.loaded.groups = { role = function() return "member" end, trusted = function() return {} end }
local function fresh() -- (each run from scratch: drive.lua keeps what it has read)
  for _, m in ipairs({ "drive", "drivebg", "cloudmodes" }) do package.loaded[m] = nil end
  local drive, bg, cm = require("drive"), require("drivebg"), require("cloudmodes")
  cm.settings_for = function() return cm.clean({ mode = "everything" }) end
  bg.tmp("/T")
  bg.spawn = function() end
  return drive, bg, cm
end

-- ---- 1. the protocol's pure parts ----
local drive, bg = fresh()
local l = bg.parse_listing("ok\nf\t12\t638000\ta.json\nd\t0\t0\tfx\nf\t3\t638001\tb (1).json\n")
check(l.exists and #l.names == 2 and l.names[1] == "a.json" and l.size["a.json"] == 12 and l.mtime["a.json"] == "638000" and l.dirs[1] == "fx",
  "the PowerShell worker's listing: files with sizes and times, folders apart")
l = bg.parse_listing("ok\nregular file\t5\t1700000000\t/c/x/rooms/main/events//e1.json\ndirectory\t0\t1700000000\t/c/x/rooms/main/events/sub\n" ..
  "Regular File\t7\t1700000001\t/Users/a/x/e2.json\nDirectory\t64\t1700000001\t/Users/a/x/fx\n")
check(#l.names == 2 and l.names[1] == "e1.json" and l.names[2] == "e2.json" and #l.dirs == 2 and l.size["e2.json"] == 7,
  "the sh worker's (GNU and BSD stat, whole paths): the same")
check(not bg.parse_listing("none\n").exists and #bg.parse_listing("none\n").names == 0, "a folder that isn't there")
local r, whole = bg.parse_result("1\tok\n2\tok\t10\t99\n3\tno\tit changed while it copied\nend\n")
check(whole and r[1][1] and r[2][2] == "10" and r[2][3] == "99" and not r[3][1] and r[3][2] == "it changed while it copied", "results")
check(not select(2, bg.parse_result("1\tok\n")), "a result without its end line isn't whole")
check(bg.hash("abc") == bg.hash("abc") and bg.hash("abc") ~= bg.hash("abd") and #bg.hash("x") == 16, "names for paths")

-- ---- 2. one room through a stand-in worker, against drive.mirror on REAPER's thread ----
local HERE, THERE = "/S/Song/rooms/main", "/C/Song/rooms/main"
local function ev(user, n, extra)
  local e = { type = "edit", id = string.format("%s-20261101-0%05dZ-%d", user, n, n), time = string.format("2026-11-01T00:%02d:00Z", n), user = user, oid = "O" .. n }
  for k, v in pairs(extra or {}) do e[k] = v end
  return e
end
local function setup()
  fs, mt = {}, {}
  for i = 1, 6 do local e = ev("James", i); put(HERE .. "/events/" .. e.id .. ".json", json.encode(e)) end
  local rec = ev("James", 7, { state = '<ITEM\n<SOURCE WAVE\nFILE "{media:main}/rec1.wav"\n>\n>' })
  put(HERE .. "/events/" .. rec.id .. ".json", json.encode(rec))
  put(HERE .. "/media/rec1.wav", ("a"):rep(500))
  put(HERE .. "/media/stray.wav", ("s"):rep(40)) -- (nobody's change plays it: not sent up)
  put(HERE .. "/midi/James-1.mid", "midi")
  put(HERE .. "/recall/James-20261101-010101Z.json", json.encode({ time = "2026-11-01T01:01:01Z" }))
  put(HERE .. "/fx/James/T1.RfxChain", "<chain>")
  put(HERE .. "/takes/James-20261028-032515Z-1.flac", "take1")
  put(HERE .. "/takes/James-20261028-032515Z-1.json", json.encode({ rev = 1 }))
  put(HERE .. "/takes/James-20261028-040000Z-2.flac", "take2") -- (deleted below: belongs in _trash)
  put(HERE .. "/takes/James-20261028-040000Z-2.json", json.encode({ rev = 1 }))
  local del = ev("James", 8, { type = "delete", take = "James-20261028-040000Z-2" })
  put(HERE .. "/events/" .. del.id .. ".json", json.encode(del))
  -- the cloud copy: a bandmate's work, and Google's clutter
  local bo = ev("Bo", 9, { state = '<ITEM\nFILE "{media:main}/bo.wav"\n>' })
  put(THERE .. "/events/" .. bo.id .. ".json", json.encode(bo))
  put(THERE .. "/events/" .. bo.id .. " (1).json", json.encode(bo)) -- (a conflict copy of the same size: tidied)
  put(THERE .. "/media/bo.wav", ("b"):rep(300))
  put(THERE .. "/fx/Bo/T2.RfxChain", "<bo chain>")
  put(THERE .. "/takes/Bo-20261028-050000Z-3.flac", "take3")
  put(THERE .. "/takes/Bo-20261028-050000Z-3.json", json.encode({ rev = 1 }))
  put(THERE .. "/events/Bo-20261101-000099Z-99.json", '{"type":"edit","id":"Bo-20261101-000099Z-99"') -- (still arriving: not whole, not brought)
end
local function snapshot()
  local out = {}
  for p, v in pairs(fs) do if p:sub(1, 3) == "/S/" or p:sub(1, 3) == "/C/" then out[p] = v end end
  return out
end
local function diff(a, z)
  for p, v in pairs(a) do if z[p] ~= v then return p end end
  for p in pairs(z) do if a[p] == nil then return p end end
  return nil
end

-- REAPER's thread, the old way
setup()
drive = fresh()
clock = clock + 60; drive.listed = {}
check(not select(2, drive.mirror(HERE, THERE, 5, "James")), "one pass")
local want1 = snapshot()
for _ = 1, 3 do clock = clock + 60; drive.listed = {}; drive.mirror(HERE, THERE, 5, "James") end -- (a take's manifest reaches the cloud's trash a pass later)
local want = snapshot()
check(want[THERE .. "/events/" .. ev("James", 1).id .. ".json"] and want[HERE .. "/media/bo.wav"] and want[THERE .. "/_trash/James-20261028-040000Z-2.flac"],
  "the old pass: ours up, the bandmate's down, the deleted take into the trash")
check(not want[THERE .. "/events/" .. ev("Bo", 9).id .. " (1).json"] and not want[HERE .. "/events/Bo-20261101-000099Z-99.json"], tostring(want[THERE .. "/events/" .. ev("Bo", 9).id .. " (1).json"] ~= nil) .. tostring(want[HERE .. "/events/Bo-20261101-000099Z-99.json"] ~= nil) ..
  "the conflict copy tidied; the half-written change left for later")

-- the worker's way: a stand-in that does each step on the stand-in drive (never through REAPER's functions)
local steps_done = 0
local function stand_in_worker(fail_paths)
  local plans = {}
  for p in pairs(fs) do plans[#plans + 1] = p end
  table.sort(plans)
  for _, p in ipairs(plans) do
    local name = p:match("^/T/bandsync%-drive%-%x+/(plan%-[^/]+)%.txt$")
    if name then
      local dir = p:match("^(.*)/")
      local out = {}
      local lines = {}
      for line in fs[p]:gmatch("[^\n]+") do lines[#lines + 1] = line end
      check(lines[1] == "studiosync-drive 1", "the plan's header")
      for i = 2, #lines do
        local op, a, b, c = lines[i]:match("^(%a)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
        check(op, "a step: " .. lines[i])
        local res
        if op == "L" then
          local files, dirs = kids(a, false), kids(a, true)
          local any = #files + #dirs > 0
          local t = { any and "ok" or "none" }
          for _, f in ipairs(files) do t[#t + 1] = "f\t" .. #fs[a .. "/" .. f] .. "\t" .. mt[a .. "/" .. f] .. "\t" .. f end
          for _, d in ipairs(dirs) do t[#t + 1] = "d\t0\t0\t" .. d end
          put(b, table.concat(t, "\n") .. "\n"); res = "ok"
        elseif op == "C" then
          local s = fs[a]
          if not s or (fail_paths and fail_paths[a]) then res = "no\tmissing"
          elseif c:find("j") and not (s:match("^%s*{") and s:match("}%s*$")) then res = "no\tnot whole yet"
          else put(b, s); res = "ok\t" .. #s .. "\t" .. mt[a] end
        elseif op == "M" then
          if not fs[a] then res = "no\tmissing"
          elseif fs[b] == nil then put(b, fs[a]); fs[a], mt[a] = nil, nil; res = "ok"
          elseif #fs[b] == #fs[a] then fs[a], mt[a] = nil, nil; res = "ok"
          else res = "no\tsomething else is there" end
        elseif op == "R" then
          if b ~= "" and not fs[b] then res = "no\tguard"
          elseif not fs[a] then res = "no\tmissing"
          else fs[a], mt[a] = nil, nil; res = "ok" end
        end
        out[#out + 1] = (i - 1) .. "\t" .. res
        steps_done = steps_done + 1
      end
      out[#out + 1] = "end"
      fs[p] = nil
      put(dir .. "/result-" .. name:sub(6) .. ".txt", table.concat(out, "\n") .. "\n")
    end
  end
end
local function bg_pass(fail_paths, max)
  local jobs, results = 0, {}
  for _ = 1, max or 200 do
    clock = clock + 2
    stand_in_worker(fail_paths)
    local before = main_cloud
    local t0 = os.clock()
    local moved, more, err = drive.bg_step({ root = "/S", user = "James" }, "/C", "Song", { { HERE, THERE } }, 0.5)
    results[#results + 1] = { took = os.clock() - t0, cloud = main_cloud - before }
    if require("drivebg").job() then jobs = jobs + 1 end
    if moved and not more then return moved, err, jobs, results end
  end
  error("the pass never finished")
end
setup()
local cm
drive, bg, cm = fresh()
main_cloud = 0
local moved, err, jobs, results = bg_pass()
local got = snapshot()
check(diff(want1, got) == nil, "the worker's pass ends exactly as the old one: " .. tostring(diff(want1, got)) .. " " .. tostring(want1[diff(want1, got) or ""]) ..
  " / " .. tostring(got[diff(want1, got) or ""]))
check(main_cloud == 0, "and REAPER's thread made no cloud call at all: " .. main_cloud)
check(not err and moved >= 10 and jobs >= 2, "files moved counted from the worker's results: " .. tostring(moved) .. " in " .. jobs .. " jobs")
local landed = {}
for _, p in ipairs(drive.landed) do landed[p] = true end
check(landed[HERE .. "/media/bo.wav"] and #drive.landed == 1, "the recording brought down is told (Syncthing rescans it) once the worker has it in place")
local sum0 = ext["cloud storage"] and json.decode(ext["cloud storage"])
check(sum0 and sum0.stored[1] > 10 and sum0.removed[1] == 0, "the storage sweep ran in the same pass, from the worker's listings, removing nothing")
-- and the next passes as the old ones, then nothing left to do, still with no cloud call here
for _ = 1, 3 do clock = clock + 200; bg_pass() end
check(diff(want, snapshot()) == nil, "settled as the old passes settle: " .. tostring(diff(want, snapshot())))
clock = clock + 200
main_cloud = 0
moved = bg_pass()
check(moved == 0 and main_cloud == 0 and diff(want, snapshot()) == nil, "a second pass changes nothing: " .. tostring(moved) .. " " .. main_cloud .. " " .. tostring(diff(want, snapshot())) .. " " .. tostring(want[diff(want, snapshot()) or ""]) .. " / " .. tostring(snapshot()[diff(want, snapshot()) or ""]))
-- the storage sweep's reads went through the worker too: it finished with what the cloud copy holds
local sum
for _ = 1, 100 do
  clock = clock + 2; stand_in_worker()
  if not drive.bg_busy() then clock = clock + 700 end
  drive.bg_step({ root = "/S", user = "James" }, "/C", "Song", { { HERE, THERE } }, 0.5)
  sum = ext["cloud storage"] and json.decode(ext["cloud storage"])
  if sum then break end
end
check(sum and sum.stored[1] > 10 and sum.removed[1] == 0, "the sweep counted the cloud copy from the worker's listings, removing nothing: " .. tostring(sum and sum.stored[1]))
check(main_cloud == 0, "with no cloud call here either: " .. main_cloud)

-- a download that fails is never taken as a delete (the old pass only counted what it had copied)
setup()
drive, bg = fresh()
local fail = { [THERE .. "/media/bo.wav"] = true }
bg_pass(fail)
check(not fs[HERE .. "/media/bo.wav"] and fs[THERE .. "/media/bo.wav"], "the failed download isn't here, and the cloud's copy is untouched")
clock = clock + 200
bg_pass(fail)
check(fs[THERE .. "/media/bo.wav"] and not fs[THERE .. "/_trash/media/bo.wav"] and #band.files(HERE .. "/deleted") == 0, "and no tombstone, nothing moved to the trash")
check(logs[#logs]:find("couldn't copy bo.wav", 1, true) or table.concat(logs, "\n"):find("couldn't copy bo.wav", 1, true), "said once")
clock = clock + 200
bg_pass()
check(fs[HERE .. "/media/bo.wav"], "it comes once it can be read")

-- the one-writer and safety rules hold in the plan: a bandmate's file isn't written by us, removals only with their guard
setup()
drive, bg = fresh()
bg.begin("/C")
local text = select(1, bg.plan_text({ ops = { { "R", THERE .. "/takes/x.flac", THERE .. "/_trash/x.flac", "" } }, list = {}, fetch = {}, bytes = 0, dirty = {} }, "/T/d"))
check(text == "studiosync-drive 1\nR\t" .. THERE .. "/takes/x.flac\t" .. THERE .. "/_trash/x.flac\t\n", "a removal carries its guard: " .. text)
bg.submit()
bg.reset()
bg.begin("/C")
local ok_tab = bg.planned.copy(HERE .. "/media/a\tb.wav", THERE .. "/media/a\tb.wav")
check(ok_tab == false and logs[#logs]:find("tab or line break", 1, true), "a name with a tab never goes into a plan")
bg.submit()

-- ---- 3. a stand-in slow drive: every cloud call 25 ms ----
setup()
drive = fresh()
slow_ms, main_cloud = 25, 0
local t0 = os.clock()
clock = clock + 60; drive.listed = {}; drive.mirror(HERE, THERE, 5, "James")
local old_took, old_calls = os.clock() - t0, main_cloud
check(old_took > 0.3 and old_calls > 12, string.format("the old pass held REAPER's thread %.0f ms (%d cloud calls)", old_took * 1000, old_calls))
setup()
drive = fresh()
main_cloud = 0
local _, _, _, res3 = bg_pass()
local worst = 0
for _, x in ipairs(res3) do worst = math.max(worst, x.took); check(x.cloud == 0, "no cloud call on REAPER's thread") end
check(worst < 0.02, string.format("the planned pass: no tick over 20 ms on the slow drive (worst %.1f ms)", worst * 1000))
slow_ms = 0
print(string.format("slow drive: old pass %.0f ms in one go (%d cloud calls); planned, worst tick %.1f ms, none on REAPER's thread", old_took * 1000, old_calls, worst * 1000))

-- ---- 3b. a room whose own folders take longer to read than a tick's budget (rt-perfcut1) ----
-- Live sync plans 8 ms a tick. Reading Cross Test's 2,489 changes here took longer, so every pass ran out of time before its first copy and
-- planned nothing, for good ("more" with 0 moved; 1,694 changes never went up). Stand-in: each listing of the room's own events costs 10 ms.
local CFG = { root = "/S", user = "James" }
setup()
for i = 10, 60 do local e = ev("James", i); put(HERE .. "/events/" .. e.id .. ".json", json.encode(e)) end
drive, bg = fresh()
local real_files = band.files
band.files = function(dir, e) if dir == HERE .. "/events" then clock = clock + 0.010 end; return real_files(dir, e) end
local big_moved
for _ = 1, 60 do
  clock = clock + 2
  stand_in_worker()
  local m, more = drive.bg_step(CFG, "/C", "Song", { { HERE, THERE } }, 0.008)
  if m and not more then big_moved = m; break end
end
band.files = real_files
local ups = 0
for i = 1, 60 do if fs[THERE .. "/events/" .. ev("James", i).id .. ".json"] then ups = ups + 1 end end
check(big_moved and ups == 59, "a room slower to read than the budget still goes up and the pass ends: " .. tostring(big_moved) .. " moved, " .. ups .. " of 59 changes")

-- ---- 3c. a round that answers "more" while nothing moves rests, and the next waits drive.EVERY (rt-perfcut1) ----
setup()
drive, bg, cm = fresh()
local plan_at = {}
drive.mirror = function() plan_at[#plan_at + 1] = clock; return 0, true end -- (never done, never moves anything)
drive.tools_pass = function() end
cm.tick, cm.sweeping = function() end, function() return false end
local rest_at, rest_ret
logs = {}
for _ = 1, 250 do
  clock = clock + 2
  stand_in_worker()
  local m, more = drive.bg_step(CFG, "/C", "Song", { { HERE, THERE } }, 0.008)
  if m and not rest_at then rest_at, rest_ret = clock, { m, more } end
end
check(rest_at and rest_ret[1] == 0 and rest_ret[2] == true, "it rested, saying 0 moved and more to do")
local first = #plan_at
for i, t in ipairs(plan_at) do if t > rest_at then first = i - 1; break end end
check(first == drive.STALL + 1, "planned " .. drive.STALL .. " times after its other units finished, then stopped: " .. first)
check(plan_at[first + 1] and plan_at[first + 1] - rest_at >= drive.EVERY, "no plan before drive.EVERY: the next one " .. tostring(plan_at[first + 1] and plan_at[first + 1] - rest_at) .. " s later")
check(#plan_at >= 2 * first, "and then it tries again: " .. #plan_at .. " plans")
local said = 0
for _, s in ipairs(logs) do if s:find("nothing is moving", 1, true) then said = said + 1 end end
check(said == 1, "said once, not each time it rests: " .. said)

-- ---- 4. the real worker scripts ----
os.remove, os.rename = real_remove, real_rename
local py = rawget(_G, "python")
if not py then print("ok drivebg (no python in this Lua: the real worker scripts weren't run)"); return end
local perf, sleep = py.eval("__import__('time').perf_counter"), py.eval("__import__('time').sleep")
local popen = py.eval([[(lambda os, sp, shlex: (lambda cmd, sh=None: sp.Popen(cmd if (os.name == 'nt' and not sh) else ([sh] + shlex.split(cmd)[1:] if sh else shlex.split(cmd)),
  stdout=sp.DEVNULL, stderr=sp.DEVNULL)))(__import__('os'), __import__('subprocess'), __import__('shlex'))]])
local is_win = package.config:sub(1, 1) == "\\"
local base = ((is_win and os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/"):gsub("/+$", "")) .. "/studiosync-drivebg-test-" .. tostring(math.random(100000, 999999))
local function mkdir(d)
  if is_win then os.execute('mkdir "' .. d:gsub("/", "\\") .. '" >nul 2>&1') else os.execute("mkdir -p '" .. d .. "'") end
end
local function rmtree(d)
  if is_win then os.execute('rmdir /s /q "' .. d:gsub("/", "\\") .. '" >nul 2>&1') else os.execute("rm -rf '" .. d .. "'") end
end
local function rd(p) local f = io.open(p, "rb"); if not f then return nil end; local s = f:read("a"); f:close(); return s end
local function wr(p, s) local f = assert(io.open(p, "wb")); f:write(s); f:close() end
local real = {
  SECTION = "StudioSync",
  read = rd,
  read_json = function(p) local s = rd(p); if not s then return nil end; local ok, v = pcall(json.decode, s); return ok and type(v) == "table" and v or nil end,
  write_atomic = function(p, s) wr(p .. ".tmp", s); real_remove(p); assert(real_rename(p .. ".tmp", p)) end,
  json_decode = function(s) local ok, v = pcall(json.decode, s); return ok and v or nil end,
  log = function(s) logs[#logs + 1] = s end,
  files = function() return {} end, subdirs = function() return {} end,
  size = function(p) local s = rd(p); return s and #s end,
}
package.loaded.band = real
reaper = setmetatable({
  time_precise = function() return perf() end,
  file_exists = function(p) local f = io.open(p, "rb"); if f then f:close(); return true end; return false end,
  RecursiveCreateDirectory = function(d) mkdir(d); return 1 end,
  GetExtState = function() return "" end,
  GetOS = function() return real.WIN and "Win64" or "Other" end,
}, { __index = function() return function() end end })

local function run_worker_suite(kind, sh_path)
  local root = base .. "/" .. kind
  local CL, LO = root .. "/cloud/Song/rooms/main", root .. "/local/Song/rooms/main"
  for _, d in ipairs({ CL .. "/events", CL .. "/media", LO .. "/events", root .. "/tmp" }) do mkdir(d) end
  wr(CL .. "/events/Bo-1.json", '{"id":"Bo-1"}')
  wr(CL .. "/events/Bo-2.json", '{"id":"Bo-2"') -- (half written)
  wr(CL .. "/media/bo.wav", ("b"):rep(1000))
  wr(LO .. "/events/James-1.json", '{"id":"James-1"}')
  package.loaded.drivebg = nil
  local B = require("drivebg")
  band.WIN, real.WIN = kind == "ps", kind == "ps"
  B.tmp(root .. "/tmp")
  local last
  B.spawn = function(cmd) last = popen(cmd, sh_path) end
  local function wait_job(limit)
    local worst, t_end = 0, perf() + (limit or 30) * (sh_path and 4 or 1)
    while perf() < t_end do
      local t = perf()
      local res = B.poll()
      worst = math.max(worst, perf() - t)
      if res or not B.job() then return res, worst end
      sleep(0.02)
    end
    error(kind .. ": the job never finished")
  end
  local function plan(fn)
    B.begin(root .. "/cloud")
    local ok, e = B.unit(fn)
    B.submit()
    return ok, e
  end
  -- the protocol on real folders: listed, read, copied both ways, moved, removed with and without its guard
  local ok, e = plan(function() return B.planned.files(CL .. "/events", ".json") end)
  check(not ok and B.is_need(e), kind .. ": a folder not listed yet asks for it")
  local res = wait_job(60)
  check(res and not res.err, kind .. ": the listing came back: " .. tostring(res and res.err))
  local names, content
  ok = plan(function()
    names = B.planned.files(CL .. "/events", ".json")
    content = B.planned.read(CL .. "/events/Bo-1.json")
  end)
  check(#names == 2 and names[1] == "Bo-1.json" and B.known_size(CL .. "/media/bo.wav") == nil, kind .. ": listed, and nothing asked of a folder it wasn't asked to list")
  check(not ok and content == nil, kind .. ": a cloud file is read through the worker's copy")
  wait_job(30)
  ok = plan(function()
    content = B.planned.read(CL .. "/events/Bo-1.json")
    B.planned.copy(CL .. "/events/Bo-1.json", LO .. "/events/Bo-1.json", true, "count")
    B.planned.copy(CL .. "/events/Bo-2.json", LO .. "/events/Bo-2.json", true, "count")
    B.planned.copy(LO .. "/events/James-1.json", CL .. "/events/James-1.json", true, "count")
    B.planned.rename(CL .. "/media/bo.wav", CL .. "/_trash/media/bo.wav")
    B.planned.remove(CL .. "/events/Bo-1.json", CL .. "/nothing-here", "count")
  end)
  check(ok and content == '{"id":"Bo-1"}', kind .. ": read: " .. tostring(content) .. " " .. tostring(ok))
  res = wait_job(30)
  check(res and res.moved == 3, kind .. ": three steps done (the half-written change and the unguarded removal weren't): " .. tostring(res and res.moved))
  check(rd(LO .. "/events/Bo-1.json") == '{"id":"Bo-1"}' and rd(CL .. "/events/James-1.json") == '{"id":"James-1"}', kind .. ": copied both ways")
  check(rd(LO .. "/events/Bo-2.json") == nil and rd(CL .. "/events/Bo-1.json") ~= nil, kind .. ": not the half-written one; not removed without its guard")
  check(rd(CL .. "/media/bo.wav") == nil and #(rd(CL .. "/_trash/media/bo.wav") or "") == 1000, kind .. ": moved")
  ok = plan(function() return B.planned.files(CL .. "/events", ".json") end)
  check(ok, kind .. ": the folders it wrote in were listed again with the job")
  local listed = B.planned.files(CL .. "/events")
  check(#listed == 3, kind .. ": and the new listing has the upload")
  if kind ~= "ps" and is_win then -- (Git's sh: the protocol is enough; the timing parts run with PowerShell here, and with sh on the Mac and Linux CI)
    wr(root .. "/tmp/bandsync-drive-" .. B.hash(root .. "/cloud") .. "/owner", "none")
    return
  end
  local jd = root .. "/tmp/bandsync-drive-" .. B.hash(root .. "/cloud")
  local function new_worker(slow)
    wr(jd .. "/owner", "none") -- (the running one stops)
    sleep(0.4)
    if slow then wr(jd .. "/slow", tostring(slow)) else real_remove(jd .. "/slow") end
    B.reset()
  end
  -- a slow drive: 0.25 s a step, eight steps; REAPER's thread only looks at a file a tick
  new_worker(0.25)
  plan(function()
    for i = 1, 8 do B.want(CL .. "/x" .. i) end
  end)
  local t_job = perf()
  res, worst = wait_job(60)
  t_job = perf() - t_job
  check(res and not res.err and t_job > 1.9, string.format("%s: the slow job took %.1f s", kind, t_job))
  check(worst < 0.02, string.format("%s: no look at it over 20 ms (worst %.1f ms)", kind, worst * 1000))
  print(string.format("%s worker, slow drive: job %.1f s, REAPER's worst tick looking at it %.2f ms", kind, t_job, worst * 1000))
  -- stuck on a step longer than it should take
  new_worker(3)
  B.OP_WAIT = 1
  plan(function() B.want(CL .. "/y1"); B.want(CL .. "/y2") end)
  res = wait_job(30)
  check(res and res.err and res.err:find("stopped answering", 1, true), kind .. ": a stuck worker is given up on: " .. tostring(res and res.err))
  check(rd(jd .. "/owner") == "none", kind .. ": and told to stop before its next step")
  -- killed part-way through a job
  new_worker(0.5)
  B.OP_WAIT = 3
  plan(function() for i = 1, 10 do B.want(CL .. "/z" .. i) end end)
  local t_end = perf() + 30
  while perf() < t_end do
    local s, own = rd(jd .. "/beat") or "", rd(jd .. "/owner") or "?"
    if s:find("plan%-") and s:sub(1, #own + 1) == own .. " " then break end -- (the new worker, on our job)
    B.poll(); sleep(0.05)
  end
  last:kill()
  res = wait_job(30)
  check(res and res.err and res.err:find("stopped answering", 1, true), kind .. ": a worker gone mid-job is noticed: " .. tostring(res and res.err))
  B.OP_WAIT = 30
  -- one that never starts; and three failures in a row put passes back on REAPER's thread
  new_worker()
  B.spawn = function() end
  B.START_WAIT, B.GAP = 0.3, 0
  for n = 1, 3 do
    check(B.on(), kind .. ": passes still go to the worker before failure " .. n)
    plan(function() B.want(CL .. "/w" .. n) end)
    res = wait_job(30)
    check(res and res.err and res.err:find("didn't start", 1, true), kind .. ": a worker that never starts: " .. tostring(res and res.err))
  end
  check(not B.on() and res.err:find("passes run in REAPER again", 1, true), kind .. ": after three, passes run on REAPER's thread for a while")
end

local ok_suite, why = pcall(function()
  if is_win then
    run_worker_suite("ps")
    -- (Git's sh too, asked for with DRIVEBG_SH=1: each fork costs ~50 ms on Windows, so its jobs take seconds; the Mac and Linux CI run it)
    local gsh = "C:/Program Files/Git/bin/sh.exe"
    if os.getenv("DRIVEBG_SH") and rd(gsh) then run_worker_suite("sh", gsh) end
  else
    run_worker_suite("sh")
  end
end)
rmtree(base)
check(ok_suite, tostring(why))
print("ok drivebg: protocol, stand-in worker same as the old pass with no cloud call on REAPER's thread, slow drive, real workers (stuck, killed, never started)")
