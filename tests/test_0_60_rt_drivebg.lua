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
  local jobs, results, total = 0, {}, 0
  for _ = 1, max or 200 do
    clock = clock + 2
    stand_in_worker(fail_paths)
    local before = main_cloud
    local t0 = os.clock()
    local moved, more, err = drive.bg_step({ root = "/S", user = "James" }, "/C", "Song", { { HERE, THERE } }, 0.5)
    results[#results + 1] = { took = os.clock() - t0, cloud = main_cloud - before }
    if require("drivebg").job() then jobs = jobs + 1 end
    -- (a result that says up to date carries the files moved since the last one did; the pass is over once its round is)
    if moved and not more then total = total + moved; if not drive.bg_busy() then return total, err, jobs, results end end
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
  if m and not more then big_moved = (big_moved or 0) + m; if not drive.bg_busy() then break end end
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
  local m, more, err = drive.bg_step(CFG, "/C", "Song", { { HERE, THERE } }, 0.008)
  if m and not rest_at then rest_at, rest_ret = clock, { m, more, err } end
end
-- (round 4: a rest is never "more", which Live sync logs as "bringing ... up to date"; not up to date, it says why as the pass's error)
check(rest_at and rest_ret[1] == 0 and rest_ret[2] == false and tostring(rest_ret[3]):find("nothing moved", 1, true), "it rested, saying 0 moved and why: " ..
  tostring(rest_ret[2]) .. " " .. tostring(rest_ret[3]))
local first = #plan_at
for i, t in ipairs(plan_at) do if t > rest_at then first = i - 1; break end end
check(first == drive.STALL + 1, "planned " .. drive.STALL .. " times after its other units finished, then stopped: " .. first)
check(plan_at[first + 1] and plan_at[first + 1] - rest_at >= drive.EVERY, "no plan before drive.EVERY: the next one " .. tostring(plan_at[first + 1] and plan_at[first + 1] - rest_at) .. " s later")
check(#plan_at >= 2 * first, "and then it tries again: " .. #plan_at .. " plans")
local said = 0
for _, s in ipairs(logs) do if s:find("nothing is moving", 1, true) then said = said + 1 end end
check(said == 1, "said once, not each time it rests: " .. said)

-- ---- 3d. the open song's rooms again while the round goes on (rt-drive2) ----
-- The desktop, 11-21: Cross Test's room was done at 03:54, then the round read another song's 2,406 changes for an hour (counted as something
-- happening, so it never rested) and nothing new of James's went up until the next round at 04:55.
setup()
drive, bg, cm = fresh()
drive.upkeep = function() return 0, true end -- (the other song: not done all this time)
local reads = 0
cm.progress = function() reads = reads + 1; return reads end -- (and something read every pass)
for _ = 1, 30 do clock = clock + 2; stand_in_worker(); drive.bg_step(CFG, "/C", "Song", { { HERE, THERE } }, 0.008) end
check(fs[THERE .. "/events/" .. ev("James", 1).id .. ".json"] and drive.bg_busy(), "the room went up; the round goes on")
local late = ev("James", 70)
put(HERE .. "/events/" .. late.id .. ".json", json.encode(late))
local put_at, late_up = clock, nil
for _ = 1, 60 do
  clock = clock + 2; stand_in_worker(); drive.bg_step(CFG, "/C", "Song", { { HERE, THERE } }, 0.008)
  if fs[THERE .. "/events/" .. late.id .. ".json"] then late_up = clock - put_at; break end
end
check(late_up and late_up <= drive.SOON + 10 and drive.bg_busy(), "a change made meanwhile goes up within SOON s, in the same round: " .. tostring(late_up))

-- ---- 3e. "up to date" once the copy is, while the storage sweep carries on; the round ends after it, without resting (rt-drive2) ----
-- The desktop since 04:52: the sweep (needed for the round to end) got a turn only in what the rooms left of a tick, and its reading wasn't
-- counted as something happening: every round rested after 10 plans, "still copying" for good, and the sweep never finished.
setup()
drive, bg, cm = fresh()
local steps = 0
cm.tick = function() steps = steps + 1 end
cm.sweeping = function() return steps < 40 end
cm.progress = function() return steps end
logs = {}
local told, told_moved, again, was_more, ended = 0, nil, 0, false, false
for _ = 1, 300 do
  clock = clock + 2; stand_in_worker()
  local m, more = drive.bg_step(CFG, "/C", "Song", { { HERE, THERE } }, 0.008)
  if m and not more and m > 0 and cm.sweeping() then told_moved = told_moved or m; told = told + 1 end
  if m then
    if more and not was_more and told_moved then again = again + 1 end -- (Live sync's "bringing ... up to date" after the first one)
    was_more = more
  end
  if not drive.bg_busy() then ended = true; break end
end
check(told_moved and told_moved >= 10, "up to date while the sweep goes on, with the files moved: " .. tostring(told_moved))
check(again <= told - 1, "and not taken back while the room is looked at again, only for files it then moves: " .. again .. " " .. told)
check(ended and steps >= 40 and drive.rest_until == -math.huge, "the round ends once the sweep is done, without resting: " .. steps)
for _, s in ipairs(logs) do check(not s:find("nothing is moving", 1, true), "and never said it rested") end

-- ---- 3f. the sweep a step at a time (rt-drive2) ----
-- One drive step took 331 ms on REAPER's thread (04:26:27): a room of the sweep judged (trim.plan, 80-200 ms each with saved versions, four a
-- room), sized (an open per file) and every end-of-session project parsed, all in one call. Stand-in costs: a trim plan 50 ms, a change read
-- 1 ms.
setup()
for i = 1, 3 do put(HERE .. "/recall/James-2026110" .. i .. "-010101Z.json", json.encode({ time = "2026-11-0" .. i .. "T01:01:01Z", keep = true })) end
drive, bg, cm = fresh()
for _ = 1, 3 do clock = clock + 200; bg_pass() end -- (settled first: the sweep then counts what stays)
local T = require("trim")
local real_plan, real_rj, plans = T.plan, band.read_json, 0
T.plan = function(...) clock, plans = clock + 0.05, plans + 1; return real_plan(...) end
band.read_json = function(p) clock = clock + 0.001; return real_rj(p) end
ext["cloud storage"] = nil
clock = clock + 700
local worst_step, calls = 0, 0
for _ = 1, 500 do
  clock = clock + 2; stand_in_worker()
  local before = clock
  drive.bg_step(CFG, "/C", "Song", { { HERE, THERE } }, 0.008)
  worst_step, calls = math.max(worst_step, clock - before), calls + 1
  if ext["cloud storage"] and not drive.bg_busy() then break end
end
T.plan, band.read_json = real_plan, real_rj
local planned_sum = ext["cloud storage"] and json.decode(ext["cloud storage"])
check(planned_sum and plans >= 2, "the sweep finished, with its trim plans: " .. plans)
check(worst_step <= 0.008 + 0.05 + 0.005, string.format("no pass over its budget plus one trim plan (worst %.0f ms in %d passes)", worst_step * 1000, calls))
drive, bg, cm = fresh() -- (the same sweep in one go on REAPER's thread, the old way: the same sums)
local direct_sum = cm.tick(CFG, "/C", clock + 10000, 100)
for _, k in ipairs({ "stored", "would", "drop", "kinds", "ess" }) do
  check(json.encode(direct_sum[k]) == json.encode(planned_sum[k]), "a step at a time counts as the whole sweep did: " .. k .. " " .. json.encode(direct_sum[k]) .. " / " .. json.encode(planned_sum[k]))
end
-- (each end-of-session project read for its recordings without rebuilding its text: the same paths as map_files finds)
local sf = require("sessionfile")
local rpp = '<REAPER_PROJECT\n  <SOURCE WAVE\n    FILE "media/James/a b.wav" 1\n  >\n  FILE media/Bo/c.flac\r\n\tFILE "../rooms/main/takes/x.flac"\nXFILE "no.wav"\n    <FILE\nFILE\n>'
local a1, a2 = {}, {}
sf.map_files(rpp, function(p) a1[#a1 + 1] = p end)
sf.each_file(rpp, function(p) a2[#a2 + 1] = p end)
check(#a1 == 3 and table.concat(a1, "|") == table.concat(a2, "|"), "each_file: " .. table.concat(a1, "|") .. " / " .. table.concat(a2, "|"))

-- ---- 3g. a round that rests after "up to date" doesn't say it isn't (rt-drive2, round 2) ----
-- The desktop, 05:34, 05:49 and 06:10: "nothing is moving though it isn't up to date" with the copy up to date (drive status {"moved":0}).
-- The round went on for the storage sweep, the sweep waited, and a rest that fell on the open room's 30 s look counted it as not up to date.
-- Every offset of the sweep's wait against that look: never said, and the rest says up to date. A copy that keeps failing: said, once.
local function rest_run(k, fail)
  setup()
  drive, bg, cm = fresh()
  for _ = 1, 3 do clock = clock + 200; bg_pass() end -- (settled: the cloud copy has everything, a deleted take's manifest included)
  if fail then local e = ev("James", 80); put(HERE .. "/events/" .. e.id .. ".json", json.encode(e)) end
  drive, bg, cm = fresh()
  local calls = 0
  cm.tick = function() calls = calls + 1 end
  cm.sweeping = function() return true end
  cm.progress = function() return math.min(calls, k + 6) end -- (the sweep moves on for a while, then waits)
  logs = {}
  local told, rest_more, said, rest_err = false, nil, 0, nil
  for _ = 1, 150 do
    clock = clock + 2; stand_in_worker(fail)
    local was = drive.bg_busy()
    local m, more, err = drive.bg_step(CFG, "/C", "Song", { { HERE, THERE } }, 0.008)
    if m and not more then told = true end
    if was and not drive.bg_busy() then rest_more, rest_err = more, err; break end
  end
  for _, s in ipairs(logs) do if s:find("nothing is moving", 1, true) then said = said + 1 end end
  return told, rest_more, said, rest_err
end
for k = 0, 20 do
  local told, rest_more, said, rest_err = rest_run(k)
  check(told and rest_more == false and rest_err == nil and said == 0, "rested after up to date, offset " .. k .. ": told " .. tostring(told) .. ", rest says more " ..
    tostring(rest_more) .. ", said " .. said)
end
local _, fail_more, fail_said, fail_err = rest_run(4, { [HERE .. "/events/" .. ev("James", 80).id .. ".json"] = true })
check(fail_more == false and tostring(fail_err):find(ev("James", 80).id .. ".json keeps failing", 1, true) and fail_said == 1,
  "a copy that keeps failing: said once, and as the pass's error naming it, never as more: " .. tostring(fail_more) .. " " .. tostring(fail_err) .. " " .. fail_said)
local fail_line = ""
for _, s in ipairs(logs) do if s:find("nothing is moving", 1, true) then fail_line = s end end
check(fail_line:find("keeps failing", 1, true), "and the log names it: " .. fail_line)

-- ---- 3h. "bringing the studio's copy ... up to date" only for a round with something to send (rt-drive2, round 2) ----
-- The desktop logged it at the first job of most rounds (every 30 s to 3 minutes), the round then sending nothing. Live sync logs it when a
-- result says more after one that didn't (drive_more); counted here the same way, over a whole round each.
-- Round 3 (the desktop, 07:50): a change copied in one job said only "up to date (1 file)", no "bringing" line: right, the line is for a copy
-- that carries on between passes. Before, it came or not by whether the plan followed a job's results (the stand-in's always did).
local function brings(add, count)
  for i = 1, add and (count or 1) or 0 do local e = ev("James", add + i - 1); put(HERE .. "/events/" .. e.id .. ".json", json.encode(e)) end
  clock = clock + 200 -- (a new round of the same Live sync)
  local n, was_more, moved, ups = 0, false, 0, 0
  for _ = 1, 100 do
    clock = clock + 2; stand_in_worker()
    local m, more = drive.bg_step(CFG, "/C", "Song", { { HERE, THERE } }, 0.008)
    if m then
      if more and not was_more then n = n + 1 end
      if not more and m > 0 then ups, moved = ups + 1, moved + m end -- (an up-to-date result carries the files since the last one)
      was_more = more
    end
    if not drive.bg_busy() then break end
  end
  return n, moved, ups
end
setup()
drive, bg, cm = fresh()
cm.tick, cm.sweeping = function() end, function() return false end
for _ = 1, 3 do clock = clock + 200; bg_pass() end -- (settled; the bandmate's half-written change found not whole, left for later)
local quiet = brings()
check(quiet == 0, "a round with nothing to send never says it's bringing the copy up to date: " .. quiet)
local busy, moved_up, ups = brings(90)
check(busy == 0 and moved_up == 1 and ups == 1, "one change copied in one job: only up to date (1 file): " .. busy .. " " .. moved_up .. " " .. ups)
busy, moved_up, ups = brings(100, 250)
check(busy == 1 and moved_up == 250 and ups == 1, "250, more than a job holds: bringing once, then up to date (250): " .. busy .. " " .. moved_up .. " " .. ups)
check(brings() == 0, "and the next quiet one doesn't")
check(not fs[HERE .. "/events/Bo-20261101-000099Z-99.json"], "the bandmate's half-written change isn't here yet")
put(THERE .. "/events/Bo-20261101-000099Z-99.json", '{"type":"edit","id":"Bo-20261101-000099Z-99"}') -- (it finished arriving)
brings()
check(fs[HERE .. "/events/Bo-20261101-000099Z-99.json"], "and comes once it's whole (not asked again only while it stays as it was)")

-- ---- 3i. "up to date" once this room's copies are back, not when the other songs and the sweep are done (rt-perfcut3) ----
-- The desktop, 06:59: a hub snapshot (2 files) was in the cloud at 07:00:23, "Google Drive copy up to date (2 files)" came at 07:03:19,
-- after the round had read another song's listings (and the sweep sent a job every plan). Stand-in: the other song wants 40 plans, the
-- sweep a listing every plan.
setup()
drive, bg, cm = fresh()
cm.tick, cm.sweeping = function() end, function() return false end
for _ = 1, 3 do clock = clock + 200; bg_pass() end -- (settled)
drive, bg, cm = fresh()
local other, sweeps = 0, 0
drive.upkeep = function() other = other + 1; return 0, other < 40 end
cm.tick = function() sweeps = sweeps + 1; if other < 40 then bg.want("/C/sweep" .. sweeps) end end -- (a new folder each plan: a job every time)
cm.sweeping = function() return other < 40 end
cm.progress = function() return sweeps end
local snap = { HERE .. "/recall/James-20261121-135904Z-hub_snapshot.json", HERE .. "/recall/known/James-20261121-135904Z-hub_snapshot.json" }
for _, p in ipairs(snap) do put(p, json.encode({ time = "2026-11-21T13:59:04Z" })) end
clock = clock + 200
local up_at, told_at, told_n, told_other, ended = nil, nil, nil, nil, false
for i = 1, 200 do
  clock = clock + 2; stand_in_worker()
  local m, more = drive.bg_step(CFG, "/C", "Song", { { HERE, THERE } }, 0.008)
  if not up_at and fs[snap[1]:gsub("^/S/", "/C/")] and fs[snap[2]:gsub("^/S/", "/C/")] then up_at = i end
  if m and not more and m > 0 and not told_at then told_at, told_n, told_other = i, m, other end
  if not drive.bg_busy() then ended = true; break end
end
check(up_at and told_at and told_n >= 2, "the snapshot went up and was told: " .. tostring(up_at) .. " " .. tostring(told_at) .. " " .. tostring(told_n))
check(told_at - up_at <= 2 and told_other < 40, "up to date within a plan or two of the files being there, while the other song still reads: " ..
  (told_at - up_at) .. " plans, other song at " .. told_other)
check(ended and other >= 40 and drive.rest_until == -math.huge, "and the round still ends once the other song and the sweep are done: " .. other)

-- ---- 3j. the update files' checks a step a plan (rt-drive2, round 3) ----
-- The desktop, 07:39:25, after a restart: "StudioSync 0.59.49.82 is in the Google Drive copy" and one drive step of 970 ms. Measured there
-- (read only): the extension's check of the studio's copy 77 ms, band.code_files' Lua hashes of its code 191 ms; the pass made three full
-- checks (the studio's copy, the cloud's, the one before copying) and read every file twice. Stand-in costs: the extension's check 77 ms,
-- one code file's hash 2 ms, 100 code files.
do
  setup()
  local HT, CT, KEY = "/S/_tools/studiosync", "/C/_tools/studiosync", ("ab"):rep(32)
  local function tools_copy(dir, v)
    local lines = { "version " .. v }
    put(dir .. "/lib/band.lua", 'band.VERSION = "' .. v .. '"'); lines[#lines + 1] = "sha256 " .. ("1"):rep(64) .. " lib/band.lua"
    for i = 1, 99 do
      local p = string.format("lib/m%02d.lua", i)
      put(dir .. "/" .. p, "-- module " .. i .. " of " .. v .. (i == 99 and ("x"):rep(5000) or "")); lines[#lines + 1] = "sha256 " .. ("2"):rep(64) .. " " .. p
    end
    put(dir .. "/lib/files.txt", table.concat(lines, "\n") .. "\n"); put(dir .. "/lib/files.txt.sig", "good " .. v)
  end
  tools_copy(HT, "0.60.5"); tools_copy(CT, "0.60.4")
  drive, bg, cm = fresh()
  cm.tick, cm.sweeping = function() end, function() return false end
  local saved = { band.studio_update_key, band.version_on_disk, band.signed_ok, band.code_hash, package.loaded.fromfolder, package.loaded.groups }
  band.studio_update_key = function() return KEY end
  band.version_on_disk = function(dir) return (fs[dir .. "/lib/band.lua"] or ""):match('VERSION = "([^"]+)"') end
  local function sig_ok(dir) return (fs[dir .. "/lib/files.txt.sig"] or ""):match("^good ") ~= nil end
  drive.verify = function(dir) clock = clock + 0.077; return sig_ok(dir) and ("ok " .. band.version_on_disk(dir) .. "\n") or "no" end
  band.code_hash = function(s) clock = clock + (#s > 1000 and 0.02 or 0.002); return tostring(#s) end -- (a big one, band.lua's size: 20 ms)
  band.signed_ok = function(dir, key, now) -- (as band.lua's: the extension's check, then every code file hashed unless given)
    clock = clock + 0.077
    if not now then for _, f in ipairs(band.files(dir .. "/lib", ".lua")) do band.code_hash(fs[dir .. "/lib/" .. f]) end end
    return sig_ok(dir) or nil, "not signed"
  end
  package.loaded.fromfolder = { target = function() return HT end, at_least = function(a, b) return tostring(a) >= tostring(b) end }
  package.loaded.groups = { role = function() return "owner" end, trusted = function() return {} end }
  -- (round 4: the room's look costs 30 ms in a plan, and reading an update file to compare 0.2 ms: the desktop's 118 and 176 ms steps were the
  -- 77 ms check after the room's look, and the check followed by reading 150 files twice)
  local real_mirror, real_read = drive.mirror, band.read
  drive.mirror = function(...) clock = clock + 0.03; return real_mirror(...) end
  band.read = function(p) if p:find("_tools/studiosync/", 1, true) or p:find("/stage/", 1, true) then clock = clock + 0.0002 end; return real_read(p) end
  logs = {}
  local worst, out_at = 0, nil
  for i = 1, 3000 do
    clock = clock + 2; stand_in_worker()
    local before = clock
    drive.bg_step(CFG, "/C", "Song", { { HERE, THERE } }, 0.008)
    worst = math.max(worst, clock - before)
    if (fs[CT .. "/lib/files.txt.sig"] or "") == "good 0.60.5" then out_at = i; break end
  end
  band.studio_update_key, band.version_on_disk, band.signed_ok, band.code_hash, package.loaded.fromfolder, package.loaded.groups = table.unpack(saved)
  drive.mirror, band.read = real_mirror, real_read
  local said = false
  for _, s in ipairs(logs) do if s:find("0.60.5 is in the ", 1, true) then said = true end end
  check(out_at and said and fs[CT .. "/lib/m42.lua"] == "-- module 42 of 0.60.5", "the owner's new version went out, whole: " .. tostring(out_at))
  check(worst <= 0.077 + 0.012, string.format("no plan over one extension check and a few ms (worst %.0f ms)", worst * 1000))
end

-- ---- 3k. each change read and parsed once after a start, for the copy and the storage sweep both (rt-drive2, round 3) ----
-- The desktop after its 07:33 restart: the first sweep took 17 minutes at 40-117 ms of every 10 s, both drive.lua and the sweep reading and
-- parsing every change of every song.
setup()
for i = 10, 40 do local e = ev("James", i); put(HERE .. "/events/" .. e.id .. ".json", json.encode(e)) end
drive, bg, cm = fresh()
local parsed, real_rj = {}, band.read_json
band.read_json = function(p) if p:find("^/S/Song/rooms/main/events/") then parsed[p] = (parsed[p] or 0) + 1 end; return real_rj(p) end
for _ = 1, 3 do clock = clock + 200; bg_pass() end
band.read_json = real_rj
local twice, n = 0, 0
for _, k in pairs(parsed) do n = n + 1; if k > 1 then twice = twice + 1 end end
check(n >= 39 and twice == 0 and ext["cloud storage"], "every change parsed once though the copy and the sweep both used it: " .. twice .. " of " .. n)

-- ---- 3l. the sweep steps on when the round's other units leave it almost no time (rt-drive2, round 4) ----
-- The desktop, 08:13-08:21: the sweep's turn came at the end of plans whose other units had used the time; a turn that stopped before its first
-- step (a saved version not read, a trim plan not started, a file not counted) made no progress, the round rested at 08:21:42 and the sweep
-- ended three minutes later. Stand-in: the other song uses 7.5 of the plan's 8 ms every plan while the sweep goes on, and listing the room's
-- saved versions here costs 1 ms.
setup()
for i = 1, 3 do put(HERE .. "/recall/James-2026110" .. i .. "-010101Z.json", json.encode({ time = "2026-11-0" .. i .. "T01:01:01Z", keep = true })) end
drive, bg, cm = fresh()
cm.settings_for = function() return cm.clean({ mode = "everything" }) end
drive.upkeep = function() clock = clock + 0.0075; return 0, cm.sweeping() end
local real_files = band.files
band.files = function(dir, e) if dir == HERE .. "/recall" then clock = clock + 0.001 end; return real_files(dir, e) end
local swept = false
for _ = 1, 400 do
  clock = clock + 2; stand_in_worker()
  drive.bg_step(CFG, "/C", "Song", { { HERE, THERE } }, 0.008)
  if ext["cloud storage"] and not drive.bg_busy() then swept = true; break end
end
band.files = real_files
check(swept and drive.rest_until == -math.huge, "the sweep finished in the round, never resting: " .. tostring(swept) .. " " .. tostring(drive.rest_until))

-- ---- 3m. a slow plan names its parts while perf stats is on (rt-drive2, round 4) ----
setup()
drive, bg, cm = fresh()
cm.tick, cm.sweeping = function() end, function() return false end
local real_mirror2 = drive.mirror
drive.mirror = function(...) clock = clock + 0.06; return real_mirror2(...) end
ext["perf stats"], ext["drive slow"] = "1", nil
for _ = 1, 3 do clock = clock + 2; stand_in_worker(); drive.bg_step(CFG, "/C", "Song", { { HERE, THERE } }, 0.008) end
ext["perf stats"] = nil
local ds = ext["drive slow"] and json.decode(ext["drive slow"])
check(ds and ds.total >= 60 and ds.ms.room >= 60, "ExtState drive slow: " .. tostring(ext["drive slow"]))

-- ---- 3n. the end-of-session project at a REAPER restart (rt-drive2, round 4) ----
-- The desktop, 08:07:58: "couldn't save the end-of-session project to Google Drive: the project has never been saved", of a saved project,
-- as REAPER closed it (the tab gave no file any more).
do
  setup()
  drive, bg, cm = fresh()
  package.loaded.sessionfile = nil
  local sf2 = require("sessionfile")
  put("/S/Song/Song.rpp", "<REAPER_PROJECT>")
  band.project_file = function(root, song) return root .. "/" .. song .. "/" .. song .. ".rpp" end
  local _, why = sf2.export({}, CFG, { song = "Song", room = "main" }, "/C", HERE)
  check(tostring(why):find("REAPER was closing the project", 1, true), "a saved project being closed: said so: " .. tostring(why))
  band.project_file = function() return "" end
  _, why = sf2.export({}, CFG, { song = "Song", room = "main" }, "/C", HERE)
  check(why == "the project has never been saved", "one never saved: as before: " .. tostring(why))
  band.project_file = nil
end

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
