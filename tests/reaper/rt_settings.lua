-- Run inside REAPER (ReaScript). The song's shared project settings (rt, commit d58afdf: lib/band.lua capture_settings / apply_settings,
-- band.PROJECT_CFG, band.FRONT_TOGGLES), checked against REAPER itself:
--   1. the metronome toggle (40364) changes projmetroen by exactly 1, the bit StudioSync keeps each computer's own (mask ~1);
--   2. whether the recording-over-items choice (41186 / 41330 / 42677) is global or per project: set on one tab, read on another (RESULT line;
--      per project on the desktop), and, as a shared project setting now (band.FRONT_TOGGLES rec_overlap), read/set in front, held behind;
--   3. a playrate set on a tab behind, through SWS's "playrate" project config, takes (and the tab in front keeps its own);
--   4. snap (1157) and preserve pitch (40671): captured and applied on the tab in front, held for a tab behind until it comes to the front;
--   5. capture_settings -> apply_settings onto a second tab: every band.PROJECT_CFG key, the render format/rate/channels and the grid arrive;
--      the record/render paths, the recording format, the project rate and the view stay the target's.
-- Two scratch tabs, closed at the end without saving (REAPER 7.75+ clears their changed flag; an older REAPER saves them into the scratch
-- folder first, as the other suites do, so closing doesn't ask). Needs SWS. Any OS. What a toggle does to the tab you had in front (if one
-- turns out to be global) is put back at the end, error or not.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "json" }) do package.loaded[m] = nil end
local band = require("band")
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
if not (reaper.SNM_GetIntConfigVarEx and reaper.SNM_SetIntConfigVarEx and reaper.GetToggleCommandStateEx) then return "SKIP: needs SWS (SNM_*ConfigVarEx)" end
local dir = D .. "/rtset_" .. os.time()
local function tog(id) return reaper.GetToggleCommandStateEx(0, id) end
local function near(a, b) return tonumber(a) and tonumber(b) and math.abs(a - b) < 1e-6 end
local REC = { 41186, 41330, 42677 } -- (sharedprefs.lua's rec_overlap radio)
local function rec_mode() for _, id in ipairs(REC) do if tog(id) == 1 then return id end end end
local function front(p) reaper.SelectProjectInstance(p) end
local function close_tab(p, name)
  if not (p and reaper.ValidatePtr2(0, p, "ReaProject*")) then return end
  front(p)
  pcall(reaper.GetSetProjectInfo, p, "DIRTY", 0, true) -- (7.75+: "allow scripts to query/clear project-modified state")
  if reaper.IsProjectDirty(p) ~= 0 then
    reaper.RecursiveCreateDirectory(dir, 0)
    reaper.Main_SaveProjectEx(p, dir .. "/" .. name .. ".rpp", 8)
    say("NOTE this REAPER couldn't clear the scratch tab's changed flag: saved it into " .. dir .. " to close it without a prompt")
  end
  reaper.Main_OnCommand(40860, 0)
end
local function section(name, fn)
  local ok, e = pcall(fn)
  if not ok then check(false, name .. ": ERROR " .. tostring(e)) end
end

-- the tab you had in front: its toggles as they are now (put back at the end if a scratch tab's change reached it)
local user = reaper.EnumProjects(-1)
local GUARD = { 1157, 40671, 40364 }
local user_tog, user_rec = {}, rec_mode()
for _, id in ipairs(GUARD) do user_tog[id] = tog(id) end

reaper.Main_OnCommand(40859, 0); local A = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local B = reaper.EnumProjects(-1)

-- ---- 1. the metronome toggle is bit 1 of projmetroen -------------------------------------------------------------------------------
section("1", function()
  front(A)
  local m0 = band.proj_cfg(A, "projmetroen", "i")
  if not m0 then return say("SKIP 1: SWS doesn't read projmetroen in this REAPER") end
  local c0 = band.capture_settings(A).cfg.projmetroen
  reaper.Main_OnCommand(40364, 0)
  local m1 = band.proj_cfg(A, "projmetroen", "i")
  check(m1 and (m0 ~ m1) == 1, string.format("1. Options: Toggle metronome (40364) changes projmetroen by exactly 1: %d -> %s", m0, tostring(m1)))
  check(m1 and tog(40364) == (m1 & 1), "and bit 1 is what the toggle shows: " .. tostring(tog(40364)))
  check(band.capture_settings(A).cfg.projmetroen == c0, "capture_settings leaves that bit out (the click on or off stays each computer's): " .. tostring(c0))
  -- a studio's value with the other click bit and bit 4 changed: only bit 4 arrives
  band.apply_settings(A, { cfg = { projmetroen = (m1 ~ 1) ~ 4 } })
  local m2 = band.proj_cfg(A, "projmetroen", "i")
  check(m2 == m1 ~ 4, string.format("apply_settings takes the shared bits and keeps this computer's click bit: %d -> %s (want %d)", m1, tostring(m2), m1 ~ 4))
  check(tog(40364) == (m1 & 1), "and the metronome toggle didn't move")
end)

-- ---- 2. the recording-over-items choice: global or per project? ---------------------------------------------------------------------
section("2", function()
  front(A); local a0 = rec_mode()
  front(B); local b0 = rec_mode()
  if not (a0 and b0) then return say("SKIP 2: none of 41186 / 41330 / 42677 reads as on in this REAPER") end
  if a0 ~= b0 then
    return say(string.format("RESULT 2: the recording-over-items choice is PER PROJECT (two scratch tabs already differ: %d and %d)", a0, b0))
  end
  local x
  for _, id in ipairs(REC) do if not x and id ~= a0 and tog(id) >= 0 then x = id end end
  if not x then return say("SKIP 2: only one of the three actions exists here") end
  front(A); reaper.Main_OnCommand(x, 0)
  check(rec_mode() == x, string.format("2. set to %d on tab A", x))
  front(B); local b1 = rec_mode()
  front(A); local a1 = rec_mode()
  check(a1 == x, "and tab A still says it after a switch away and back")
  say(string.format("RESULT 2: the recording-over-items choice is %s (set %d on tab A; tab B then read %s, had %d)",
    b1 == x and "GLOBAL (one for every tab)" or "PER PROJECT (each tab its own)", x, tostring(b1), b0))
  -- a shared project setting now (lib/band.lua FRONT_TOGGLES rec_overlap), as snap is: read and set in front, held for a tab behind
  local c = band.capture_settings(A).rec_overlap
  check(c == x, "capture_settings reads it on the tab in front: " .. tostring(c))
  band.apply_settings(A, { rec_overlap = a0 })
  check(rec_mode() == a0, "apply_settings sets it on the tab in front")
  band.apply_settings(B, { rec_overlap = x })
  local _, held = reaper.GetProjExtState(B, band.SECTION, "front 41186")
  check(held == x .. "!" and rec_mode() == a0, "for a tab behind it's held there ('" .. held .. "'), the tab in front untouched")
  front(B)
  check(rec_mode() == b1, "that tab in front: still its own until StudioSync looks")
  band.capture_settings(B)
  check(rec_mode() == x, "StudioSync's next look sets it: " .. tostring(rec_mode()))
  front(A)
  check(rec_mode() == a0, "and tab A keeps its own")
  band.apply_settings(A, { rec_overlap = 40000 })
  check(rec_mode() == a0, "a value that isn't one of the three choices is ignored")
end)

-- ---- 3. a playrate for a tab behind, through SWS --------------------------------------------------------------------------------------
section("3", function()
  front(A)
  if not band.proj_cfg(B, "playrate", "d") then return say("SKIP 3: SWS has no 'playrate' project config here, so a tab behind keeps its playrate") end
  local ra = reaper.Master_GetPlayRate(A)
  band.apply_settings(B, { playrate = 0.8 })
  check(near(reaper.Master_GetPlayRate(B), 0.8), "3. a playrate of 0.8 set on the tab behind takes: " .. reaper.Master_GetPlayRate(B))
  check(near(band.proj_cfg(B, "playrate", "d"), 0.8), "and SWS reads it back")
  check(near(reaper.Master_GetPlayRate(A), ra), "the tab in front keeps its own: " .. reaper.Master_GetPlayRate(A))
  front(B)
  check(near(reaper.Master_GetPlayRate(0), 0.8), "and once that tab is in front, its playrate (the transport's) is 0.8: " .. reaper.Master_GetPlayRate(0))
  band.apply_settings(B, { playrate = 1.25 }) -- (in front: REAPER's own call)
  check(near(reaper.Master_GetPlayRate(B), 1.25), "set while in front, through REAPER's call: " .. reaper.Master_GetPlayRate(B))
  front(A)
  check(near(reaper.Master_GetPlayRate(A), ra), "and the other tab still has its own")
end)

-- ---- 4. snap and preserve pitch: the tab in front only, held for one behind ---------------------------------------------------------
section("4", function()
  front(B); local bs, bp = tog(1157), tog(40671)
  front(A); local as, ap = tog(1157), tog(40671)
  if bs < 0 or bp < 0 or as < 0 then return say("SKIP 4: snap / preserve pitch don't report a toggle state here") end
  local s = band.capture_settings(A)
  check(s.snap == as and s.preserve_pitch == ap, string.format("4. captured on the tab in front: snap %s, preserve pitch %s", tostring(s.snap), tostring(s.preserve_pitch)))
  band.apply_settings(A, { snap = 1 - as, preserve_pitch = 1 - ap })
  check(tog(1157) == 1 - as and tog(40671) == 1 - ap, "applied on the tab in front: both flipped")
  local s2 = band.capture_settings(A)
  check(s2.snap == 1 - as and s2.preserve_pitch == 1 - ap, "and read back so")
  front(B)
  local bs2, bp2 = tog(1157), tog(40671)
  say(string.format("RESULT 4: snap is %s, preserve pitch is %s (flipped on tab A; tab B then read %d/%d, had %d/%d)",
    bs2 == bs and "per project" or "GLOBAL", bp2 == bp and "per project" or "GLOBAL", bs2, bp2, bs, bp))
  bs, bp = bs2, bp2
  front(A)
  band.apply_settings(B, { snap = 1 - bs, preserve_pitch = 1 - bp })
  local _, held = reaper.GetProjExtState(B, band.SECTION, "front 1157")
  local _, heldp = reaper.GetProjExtState(B, band.SECTION, "front 40671")
  check(held == (1 - bs) .. "!" and heldp == (1 - bp) .. "!", "for a tab behind it's held there: '" .. held .. "', '" .. heldp .. "'")
  check(tog(1157) == 1 - as and tog(40671) == 1 - ap, "and the tab in front isn't touched")
  local sb = band.capture_settings(B)
  check(sb.snap == 1 - bs and sb.preserve_pitch == 1 - bp, "a capture of the tab behind says the held values")
  front(B)
  check(tog(1157) == bs and tog(40671) == bp, "that tab comes to the front: still its own until StudioSync looks")
  band.capture_settings(B) -- (as Live sync's next look does: band.capture_project -> capture_settings)
  check(tog(1157) == 1 - bs and tog(40671) == 1 - bp, "StudioSync's next look sets them")
  _, held = reaper.GetProjExtState(B, band.SECTION, "front 1157")
  check(held == tostring(1 - bs), "and they're no longer held: '" .. held .. "'")
  front(A)
  check(tog(1157) == 1 - as and tog(40671) == 1 - ap, "tab A still has its own")
end)

-- ---- 5. capture -> apply onto a second tab: everything arrives, paths and view stay -------------------------------------------------
section("5", function()
  front(A)
  local gps, gp = reaper.GetSetProjectInfo_String, reaper.GetSetProjectInfo
  -- the target's own paths and formats, made distinct so "untouched" means something
  gps(B, "RECORD_PATH", dir .. "/b_rec", true); gps(B, "RENDER_FILE", dir .. "/b_render", true); gps(B, "RENDER_PATTERN", "b-$project", true)
  gps(A, "RECORD_PATH", dir .. "/a_rec", true); gps(A, "RENDER_FILE", dir .. "/a_render", true); gps(A, "RENDER_PATTERN", "a-$project", true)
  gp(A, "PROJECT_SRATE", 48000, true); gp(A, "PROJECT_SRATE_USE", 1, true); gp(B, "PROJECT_SRATE", 44100, true); gp(B, "PROJECT_SRATE_USE", 1, true)
  local keep = {}
  for _, k in ipairs({ "RECORD_PATH", "RECORD_PATH_SECONDARY", "RENDER_FILE", "RENDER_PATTERN", "RECORD_FORMAT", "PROJECT_TITLE" }) do keep[k] = select(2, gps(B, k, "", false)) end
  local keepn = { PROJECT_SRATE = gp(B, "PROJECT_SRATE", 0, false), PROJECT_SRATE_USE = gp(B, "PROJECT_SRATE_USE", 0, false) }
  local v0, v1 = reaper.GetSet_ArrangeView2(B, false, 0, 0, 0, 0)
  -- the source's settings: each unlike the target's
  local fmt = select(2, gps(B, "RENDER_FORMAT", "", false))
  gps(A, "RENDER_FORMAT", fmt == "Y2FsZhgAAAAFAAAA" and "ZXZhdxgAAQ==" or "Y2FsZhgAAAAFAAAA", true) -- (FLAC 24-bit, or WAV 24-bit)
  gp(A, "RENDER_SRATE", gp(B, "RENDER_SRATE", 0, false) == 48000 and 96000 or 48000, true)
  gp(A, "RENDER_CHANNELS", gp(B, "RENDER_CHANNELS", 0, false) == 1 and 2 or 1, true)
  reaper.GetSetProjectGrid(A, true, 0.0625, 1, 0.3)
  reaper.CSurf_OnPlayRateChange(0.9)
  local bmet = band.proj_cfg(B, "projmetroen", "i")
  local unproven = {}
  for _, c in ipairs(band.PROJECT_CFG) do
    local k, kind = c[1], c[2]
    local bv, av = band.proj_cfg(B, k, kind), band.proj_cfg(A, k, kind)
    if bv and av then
      local w
      if kind == "d" then w = bv + 2.5
      elseif k == "autoxfade" then w = bv ~ 1
      elseif k == "projrecmode" then w = (bv + 1) % 3
      elseif k == "projmetroen" then w = (bv ~ 6) ~ 1 -- (bits 2 and 4 to arrive; bit 1, the click, differs too and must not)
      elseif k == "projfrbase" then w = bv == 25 and 30 or 25
      elseif k == "projfrdrop" then w = bv == 0 and 1 or 0
      else w = bv + 1 end
      if kind == "d" then reaper.SNM_SetDoubleConfigVarEx(A, k, w) else reaper.SNM_SetIntConfigVarEx(A, k, math.tointeger(w)) end
      local got = band.proj_cfg(A, k, kind)
      if near(got, bv) then unproven[#unproven + 1] = k .. " (REAPER kept it at " .. tostring(got) .. ")" end
    else
      say("     " .. k .. ": not readable here (source " .. tostring(av) .. ", target " .. tostring(bv) .. "): left out, as apply_settings does")
    end
  end
  local s = band.capture_settings(A)
  check(type(s.grid) == "table" and near(s.grid[1], 0.0625) and s.grid[2] == 1 and near(s.grid[3], 0.3), "5. the source's grid is 1/16, swing on, 0.3")
  check(near(s.playrate, 0.9), "and its playrate 0.9")
  band.apply_settings(B, s)
  local t = band.capture_settings(B)
  local function same(x, y)
    if type(x) == "table" and type(y) == "table" then
      for i = 1, math.max(#x, #y) do if not (x[i] == y[i] or near(x[i], y[i])) then return false end end
      return true
    end
    return x == y or near(x, y)
  end
  for _, k in ipairs(band.PROJECT_STR) do check(same(s[k], t[k]), k .. " arrives: '" .. tostring(t[k]) .. "'") end
  for _, k in ipairs(band.PROJECT_NUM) do check(same(s[k], t[k]), k .. " arrives: " .. tostring(t[k])) end
  check(same(s.grid, t.grid), "the grid arrives: " .. band.json_encode(t.grid))
  if band.proj_cfg(B, "playrate", "d") then check(same(s.playrate, t.playrate), "the playrate arrives (tab behind, SWS): " .. tostring(t.playrate)) end
  for _, c in ipairs(band.PROJECT_CFG) do
    if s.cfg[c[1]] ~= nil and t.cfg[c[1]] ~= nil then check(same(s.cfg[c[1]], t.cfg[c[1]]), c[1] .. " arrives: " .. tostring(t.cfg[c[1]])) end
  end
  if #unproven > 0 then say("NOTE these were the same on both tabs before, so their arrival proves nothing: " .. table.concat(unproven, ", ")) end
  local bmet2 = band.proj_cfg(B, "projmetroen", "i")
  if bmet then check(bmet2 and (bmet2 & 1) == (bmet & 1), "the target's own click bit stayed: " .. tostring(bmet) .. " -> " .. tostring(bmet2)) end
  for k, v in pairs(keep) do check(select(2, gps(B, k, "", false)) == v, k .. " untouched: '" .. v .. "'") end
  for k, v in pairs(keepn) do check(gp(B, k, 0, false) == v, k .. " untouched: " .. v) end
  local w0, w1 = reaper.GetSet_ArrangeView2(B, false, 0, 0, 0, 0)
  check((w0 == nil and v0 == nil) or (near(w0, v0) and near(w1, v1)), "the target's view untouched")
  check(type(band.capture_project(A).settings) == "table", "capture_project carries them (p.settings), so they travel with the timeline")
  -- the target in front: the held toggles land, and the rest still match
  front(B)
  band.capture_settings(B)
  local t2 = band.capture_settings(B)
  check(t.rec_overlap == s.rec_overlap, "the recording-over-items choice is held for the target: " .. tostring(t.rec_overlap))
  check(t2.snap == s.snap and t2.preserve_pitch == s.preserve_pitch and t2.rec_overlap == s.rec_overlap and rec_mode() == s.rec_overlap,
    string.format("once in front, the target's snap / preserve pitch / recording choice match: %s/%s/%s", tostring(t2.snap), tostring(t2.preserve_pitch), tostring(t2.rec_overlap)))
  check(same(t2.grid, s.grid) and same(t2.RENDER_FORMAT, s.RENDER_FORMAT), "and the rest still does")
end)

close_tab(B, "rt_settings_b")
close_tab(A, "rt_settings_a")
-- your tab: anything a scratch tab's change reached (a toggle that proved global) put back
if user and reaper.ValidatePtr2(0, user, "ReaProject*") then
  front(user)
  for _, id in ipairs(GUARD) do
    if user_tog[id] >= 0 and tog(id) ~= user_tog[id] then reaper.Main_OnCommand(id, 0); say("     put back " .. id .. " on your tab") end
  end
  if user_rec and rec_mode() ~= user_rec then reaper.Main_OnCommand(user_rec, 0); say("     put back the recording-over-items choice " .. user_rec) end
  check(rec_mode() == user_rec and tog(1157) == user_tog[1157] and tog(40671) == user_tog[40671] and tog(40364) == user_tog[40364], "your tab's toggles are as they were")
end
for _, m in ipairs({ "band", "json" }) do package.loaded[m] = nil end
say(string.format("rt_settings: fails %d of %d", fails, #out))
return table.concat(out, "\n")
