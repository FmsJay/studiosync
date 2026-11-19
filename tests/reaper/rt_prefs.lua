-- Run inside REAPER (ReaScript). The studio's shared REAPER preferences (rt, commit d58afdf: lib/sharedprefs.lua, groups.set_shared_prefs) on
-- this REAPER's real preferences, and the two new Settings > Studio cards:
--   6. the studio's set goes in while a scratch "studio" tab (bound to a scratch studio) is in front; your own values come back when a plain
--      tab is in front, and when another studio's song is (one that shares nothing); a change by hand while the studio's are in isn't
--      reverted, then or later; Live sync stopping puts yours back; after a simulated crash and restart (the module's memory gone, the
--      non-persisted "shared prefs session" ExtState gone, the persisted state kept) yours come back, and a value changed meanwhile (as
--      ReaPersona's restart write does) is yours and stays;
--   9. prints.lanes_ui and sharedprefs.studio_ui draw for one frame in a ReaImGui window of their own (as tests/reaper/page_modules.lua
--      does), as owner/admin and as a member, with the studio's set listed; the panel names both cards.
-- Live sync's decision (which studio's set, if any, for the tab in front) is in StudioSync - Live sync.lua's tick and atexit, which can't be
-- called from here: live_tick and live_exit below are copies of those few lines, so this tests lib/sharedprefs.lua under them.
-- Every preference on sharedprefs.PREFS is read before and written back after (error or not), as are the ExtState keys it keeps
-- ("shared prefs state" / "held" / "session") and the Activity lines. (The recording-over-items choice left this list: it's per project, so
-- it's tests/reaper/rt_settings.lua's now.) Best run with no Live sync running (a running one would see the studio's set in reaper.ini for the moment this runs). Scratch tabs
-- and a scratch studio folder; Syncthing isn't asked (lib/trust.lua stood in for). Needs SWS. Any OS (the cards need ReaImGui).
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
local MODS = { "band", "json", "groups", "trust", "sharedprefs", "prints", "mirror", "sync" }
for _, m in ipairs(MODS) do package.loaded[m] = nil end
if not (reaper.SNM_GetIntConfigVar and reaper.SNM_SetIntConfigVar and reaper.SNM_GetDoubleConfigVar) then return "SKIP: needs SWS (SNM_*ConfigVar)" end
-- (who wrote band.json is Syncthing's to say: here a studio from before owners, believed as written, as the offline tests do)
package.loaded.trust = { pins = function() return nil end, from_manager_file = function() return nil end, inviter = function() return nil end,
  roles = function() return nil, {} end, held = function() return false end, pin = function() end, managers = function() return nil end,
  roles_of = function() return {} end }
local band, groups = require("band"), require("groups")
local sp = require("sharedprefs")
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local base = D .. "/rtprefs_" .. os.time()
local R, R2 = base .. "/StudioSync PrefsLab", base .. "/StudioSync OtherLab"
local S = band.SECTION
local function front(p) reaper.SelectProjectInstance(p) end
local dir = base
local function close_tab(p, name)
  if not (p and reaper.ValidatePtr2(0, p, "ReaProject*")) then return end
  front(p)
  pcall(reaper.GetSetProjectInfo, p, "DIRTY", 0, true) -- (7.75+)
  if reaper.IsProjectDirty(p) ~= 0 then
    reaper.RecursiveCreateDirectory(dir, 0)
    reaper.Main_SaveProjectEx(p, dir .. "/" .. name .. ".rpp", 8)
    say("NOTE this REAPER couldn't clear the scratch tab's changed flag: saved it into " .. dir .. " to close it without a prompt")
  end
  reaper.Main_OnCommand(40860, 0)
end

-- ---- what's put back at the end ------------------------------------------------------------------------------------------------------
local NO = -2147480001
local raw = {} -- reaper.ini key -> { kind, value } as SWS reads it now
for _, x in ipairs(sp.PREFS) do
  if x[2] == "d" then local v = reaper.SNM_GetDoubleConfigVar(x[1], NO); if v ~= NO then raw[x[1]] = { "d", v } end
  elseif x[2] == "i" then local v = reaper.SNM_GetIntConfigVar(x[1], NO); if v ~= NO then raw[x[1]] = { "i", v } end end
end
local EXT = { [sp.STATE] = true, [sp.HELD] = true, ["shared prefs session"] = false, [band.LOG_KEY] = false } -- (true: persisted)
local ext = {}
for k in pairs(EXT) do ext[k] = reaper.GetExtState(S, k) end
local user = reaper.EnumProjects(-1)
local tabs = {}
local function new_tab(name, song, root)
  reaper.Main_OnCommand(40859, 0)
  local p = reaper.EnumProjects(-1)
  tabs[#tabs + 1] = { p, name }
  if song then reaper.SetProjExtState(p, S, "song", song); reaper.SetProjExtState(p, S, "room", "main"); reaper.SetProjExtState(p, S, "root", root) end
  return p
end

-- Live sync's lines for its song's tab `proj` of studio `root` (StudioSync - Live sync.lua, tick_body and atexit): copied, not called.
-- (now_too: the once-a-second limit is Live sync's pace, not what's tested)
local function live_tick(proj, root)
  local f = reaper.EnumProjects(-1)
  if f == proj then sp.tick(root, true)
  elseif not (f and band.binding(f)) then sp.tick(nil, true) end
end
local function live_exit(proj)
  local f = reaper.EnumProjects(-1)
  if f == proj or not (f and band.binding(f)) then sp.tick(nil, true) end
end

local ok, err = pcall(function()
  reaper.RecursiveCreateDirectory(R .. "/_band", 0); reaper.RecursiveCreateDirectory(R2 .. "/_band", 0)
  band.write_json(R .. "/_band/band.json", { name = "PrefsLab", id = "rtprefs-lab" })
  band.write_json(R2 .. "/_band/band.json", { name = "OtherLab", id = "rtprefs-other" })
  local song = new_tab("rt_prefs_studio", "PrefsLab", R)   -- (the studio's song)
  local other = new_tab("rt_prefs_other", "OtherLab", R2)  -- (another studio's song: its studio shares nothing)
  local plain = new_tab("rt_prefs_plain")                  -- (a project of your own)
  local function all_live() live_tick(song, R); live_tick(other, R2) end
  -- start from nothing held (what was is put back at the end)
  reaper.DeleteExtState(S, sp.STATE, true); reaper.DeleteExtState(S, sp.HELD, true); reaper.SetExtState(S, "shared prefs session", "1", false)
  front(song)
  local mine, set = {}, {}
  for _, x in ipairs(sp.PREFS) do mine[x[1]] = sp.read(x[1]) end
  if mine.deffadelen then set.deffadelen = mine.deffadelen + 0.0137 end
  if mine.defsplitxfadelen then set.defsplitxfadelen = mine.defsplitxfadelen + 0.0071 end
  if mine.deffadeshape then set.deffadeshape = mine.deffadeshape == 1 and 2 or 1 end
  if mine.defxfadeshape then set.defxfadeshape = mine.defxfadeshape == 1 and 2 or 1 end
  if not set.deffadelen then error("SWS doesn't read deffadelen here: nothing to test") end
  for k, v in pairs(mine) do say(string.format("     %s: yours %s, the studio's %s", k, tostring(v), tostring(set[k]))) end
  local keys = {}
  for k in pairs(set) do keys[#keys + 1] = k end
  table.sort(keys)
  -- the owner's panel saves the set: only keys on the list reach band.json
  local with_bad = {}
  for k, v in pairs(set) do with_bad[k] = v end
  with_bad.workthreads, with_bad.audio_buffer = 4, 256
  groups.set_shared_prefs(R, with_bad)
  local j = band.read_json(R .. "/_band/band.json") or {}
  check(type(j.shared_prefs) == "table" and j.shared_prefs.workthreads == nil and j.shared_prefs.audio_buffer == nil and j.shared_prefs.deffadelen ~= nil,
    "6. the studio's set is saved in band.json, never-shared keys dropped: " .. band.json_encode(j.shared_prefs))
  check(sp.studio(R).deffadelen ~= nil and next(sp.studio(R2)) == nil, "the studio's set reads back through the trusted settings; the other studio shares nothing")

  local function all(want_of, what)
    local bad = {}
    for _, k in ipairs(keys) do
      local now = sp.read(k)
      if not sp.same(now, want_of[k]) then bad[#bad + 1] = k .. " " .. tostring(now) .. " (want " .. tostring(want_of[k]) .. ")" end
    end
    check(#bad == 0, what .. (#bad > 0 and (": " .. table.concat(bad, ", ")) or ""))
  end
  local held_all = ";" .. table.concat(keys, ";") .. ";"

  -- a. the studio's song in front: the studio's in
  front(song); all_live()
  all(set, "the studio's song in front: the studio's values are in")
  check(reaper.GetExtState(S, sp.HELD) == held_all, "and listed as held: " .. reaper.GetExtState(S, sp.HELD))
  check(sp.same(sp.mine("deffadelen"), mine.deffadelen), "sp.mine gives yours meanwhile: " .. tostring(sp.mine("deffadelen")))
  all_live() -- (a second look changes nothing)
  all(set, "and stay in")
  -- b. a project of your own in front: yours back
  front(plain); all_live()
  all(mine, "a project of your own in front: your own values are back")
  check(reaper.GetExtState(S, sp.HELD) == "", "and nothing's held")
  -- c. another studio's song in front (it shares nothing): yours
  front(song); all_live()
  all(set, "the studio's song again: the studio's in")
  front(other); all_live()
  all(mine, "another studio's song in front (it shares nothing): yours back")
  -- d. a change by hand while the studio's are in: it stands
  front(song); all_live()
  local hand = mine.deffadelen + 0.031
  reaper.SNM_SetDoubleConfigVar("deffadelen", hand)
  all_live()
  check(sp.same(sp.read("deffadelen"), hand), "your change by hand while the studio's were in isn't reverted: " .. tostring(sp.read("deffadelen")))
  check(not reaper.GetExtState(S, sp.HELD):find(";deffadelen;", 1, true), "and it's no longer held as the studio's")
  local rest = {}
  for k, v in pairs(set) do rest[k] = v end
  rest.deffadelen = hand
  all(rest, "the others are still the studio's")
  front(plain); all_live()
  local back = {}
  for k, v in pairs(mine) do back[k] = v end
  back.deffadelen = hand
  all(back, "a project of your own in front: yours back, and your hand change stays (it isn't put back to before)")
  reaper.SNM_SetDoubleConfigVar("deffadelen", mine.deffadelen) -- (yours again, for what follows)
  -- e. Live sync stops with the studio's song in front: yours back
  front(song); all_live()
  all(set, "the studio's in again")
  live_exit(song)
  all(mine, "Live sync stopping (REAPER quitting too) puts yours back")
  check(reaper.GetExtState(S, sp.HELD) == "", "and nothing's held")
  -- f. a crash with the studio's in, and a restart
  front(song); all_live()
  all(set, "the studio's in, then REAPER crashes")
  local w = mine.defsplitxfadelen and mine.defsplitxfadelen + 0.0191
  if w then reaper.SNM_SetDoubleConfigVar("defsplitxfadelen", w) end -- (changed before the next start, as ReaPersona's restart write does)
  check(reaper.GetExtState(S, sp.STATE):find("applied", 1, true) ~= nil, "what's held is kept in the persisted ExtState")
  package.loaded.sharedprefs = nil; sp = require("sharedprefs") -- (a new REAPER: the module starts over)
  reaper.DeleteExtState(S, "shared prefs session", false)          -- (and the session marker, never persisted, is gone)
  front(plain); all_live()
  local after = {}
  for k, v in pairs(mine) do after[k] = v end
  if w then after.defsplitxfadelen = w end
  all(after, "after the restart, a project of your own in front: yours back" .. (w and ", and the value changed meanwhile is yours and stays" or ""))
  check(reaper.GetExtState(S, sp.HELD) == "" and reaper.GetExtState(S, "shared prefs session") ~= "", "nothing's held, and this session is marked")
  front(song); all_live()
  all(set, "the studio's song after the restart: the studio's in again")
  front(plain); all_live()
  all(after, "and out again to what's yours now")
  if w then reaper.SNM_SetDoubleConfigVar("defsplitxfadelen", mine.defsplitxfadelen) end

  -- ---- 9. the two Settings > Studio cards ------------------------------------------------------------------------------------------
  local panel = band.read(lib:gsub("lib/$", "") .. "StudioSync - Panel.lua") or ""
  check(panel:find('require("prints").lanes_ui(ctx, ImGui, cfg, studio_admin())', 1, true) and panel:find('require("sharedprefs").studio_ui(ctx, ImGui, cfg, studio_admin())', 1, true),
    "9. the panel's Settings > Studio has both cards")
  if not reaper.ImGui_GetBuiltinPath then return say("SKIP 9: ReaImGui isn't installed") end
  package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
  local ImGui = require "imgui" "0.10"
  local ctx = ImGui.CreateContext("StudioSync rt cards test")
  local cfg = { root = R, user = "James" }
  local broken = false
  local function draw(name, fn) -- (as page_modules.lua: one part in a child of its own, anything left open closed again)
    if broken then return check(false, name .. ": not drawn, an earlier part broke the frame") end
    ImGui.SetNextWindowSize(ctx, 600, 400)
    if not ImGui.Begin(ctx, "StudioSync rt cards test: " .. name, true) then return check(true, name .. " (window hidden)") end
    local open = ImGui.BeginChild(ctx, "part", 0, 0)
    local okd, e = true, nil
    if open then okd, e = pcall(fn) end
    if open then pcall(ImGui.EndChild, ctx) end
    if not okd then for _ = 1, 20 do if not pcall(ImGui.EndChild, ctx) then break end end end
    broken = not pcall(ImGui.End, ctx)
    check(okd and not broken, name .. " draws" .. (okd and "" or (": " .. tostring(e))) .. (broken and " (left something open: the frame broke)" or ""))
  end
  local prints = require("prints")
  local before = band.read(R .. "/_band/band.json")
  draw("lanes card, owner", function() prints.lanes_ui(ctx, ImGui, cfg, true) end)
  draw("lanes card, member", function() prints.lanes_ui(ctx, ImGui, cfg, false) end)
  draw("prefs card, owner", function() sp.studio_ui(ctx, ImGui, cfg, true) end)
  draw("prefs card, member", function() sp.studio_ui(ctx, ImGui, cfg, false) end)
  check(band.read(R .. "/_band/band.json") == before, "drawing them changed nothing in band.json")
  check(sp.words("deffadelen", 0.01) == "0.01 s" and sp.words("deffadeshape", 1) == "Shape 2", "the card's words: '" .. sp.words("deffadelen", 0.01) .. "', '" .. sp.words("deffadeshape", 1) .. "'")
end)
if not ok then check(false, "ERROR " .. tostring(err)) end

-- ---- put everything back ------------------------------------------------------------------------------------------------------------
for i = #tabs, 1, -1 do close_tab(tabs[i][1], tabs[i][2]) end
for k, c in pairs(raw) do
  if c[1] == "d" then reaper.SNM_SetDoubleConfigVar(k, c[2]) else reaper.SNM_SetIntConfigVar(k, c[2]) end
end
if user and reaper.ValidatePtr2(0, user, "ReaProject*") then front(user) end
for k, persist in pairs(EXT) do
  if ext[k] ~= "" then reaper.SetExtState(S, k, ext[k], persist) else reaper.DeleteExtState(S, k, persist) end
end
local restored = true
for k, c in pairs(raw) do
  local now = c[1] == "d" and reaper.SNM_GetDoubleConfigVar(k, NO) or reaper.SNM_GetIntConfigVar(k, NO)
  if now ~= c[2] then restored = false; say("     " .. k .. " is " .. tostring(now) .. ", was " .. tostring(c[2])) end
end
check(restored, "every preference is back as it was")
for _, m in ipairs(MODS) do package.loaded[m] = nil end
say(string.format("rt_prefs: fails %d of %d", fails, #out))
return table.concat(out, "\n")
