-- Run inside REAPER (ReaScript). Automation items that change the sound travel whole (review, 0.58.89): a looped, rate-changed,
-- offset item; one on a send's volume; one on a plug-in knob's envelope, kept when the chain changes. Two scratch tabs "James" (A)
-- and "Bee" (B), compared by what each envelope plays at a handful of moments. Scratch folder and tabs only.
local D = reaper.GetResourcePath() .. "/StudioSync/tests" -- scratch: never the shared folder
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "json", "fxfiles" }) do package.loaded[m] = nil end
local band, sync, mirror = require("band"), require("sync"), require("mirror")
mirror.FX_SET_GAP = 0 -- (chains land back to back here, faster than any band: 0.59.14)
local stamp = os.time()
local root = D .. "/airoot_" .. stamp
local song, room = "AiLab", "main"
local A, B = { user = "James", root = root }, { user = "Bee", root = root }
reaper.RecursiveCreateDirectory(sync.room_dir(A, song, room) .. "/events", 0)
local yes = function() return true end
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local function settle() for _, f in pairs(mirror.fx_seen) do f.since = -math.huge end end
local function pass(p, cfg) reaper.SelectProjectInstance(p); local n = mirror.watch(p, cfg, song, room, { can = yes, mode = "claims" }); settle()
  return n + mirror.watch(p, cfg, song, room, { can = yes, mode = "claims" }) end
local function recv(p, cfg) reaper.SelectProjectInstance(p); local n = 0; for _ = 1, 3 do n = n + sync.receive(p, cfg, song, room, yes) end; return n end
local function same(ea, eb, what)
  if not (ea and eb) then check(false, what .. ": envelope missing on " .. (ea and "B" or "A")); return end
  local worst = 0
  for t = 0, 8, 0.137 do worst = math.max(worst, math.abs(select(2, reaper.Envelope_Evaluate(ea, t, 48000, 0)) - select(2, reaper.Envelope_Evaluate(eb, t, 48000, 0)))) end
  check(worst < 1e-4, what .. " plays the same on B (worst gap " .. string.format("%.3g", worst) .. ")")
end
local function points(env, a, list) for _ = 1, reaper.CountEnvelopePointsEx(env, a | 0x10000000) do reaper.DeleteEnvelopePointEx(env, a | 0x10000000, 0) end
  for _, p in ipairs(list) do reaper.InsertEnvelopePointEx(env, a | 0x10000000, p[1], p[2], 0, 0, false, true) end
  reaper.Envelope_SortPointsEx(env, a | 0x10000000) end
local front = reaper.EnumProjects(-1)
local pa, pb
local ok, err = pcall(function()
  reaper.Main_OnCommand(40859, 0); pa = reaper.EnumProjects(-1)
  reaper.Main_OnCommand(40859, 0); pb = reaper.EnumProjects(-1)
  reaper.SelectProjectInstance(pa)
  reaper.InsertTrackInProject(pa, 0, 0); reaper.InsertTrackInProject(pa, 1, 0)
  local tr, bus = reaper.GetTrack(pa, 0), reaper.GetTrack(pa, 1)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Synth", true)
  reaper.GetSetMediaTrackInfo_String(bus, "P_NAME", "Verb", true)
  sync.watch_timeline(pa, A, song, room, yes); sync.watch_timeline(pb, B, song, room, yes)
  pass(pa, A); recv(pb, B)
  local btr, bbus = mirror.find(pb, "track", mirror.track_oid(tr)), mirror.find(pb, "track", mirror.track_oid(bus))
  check(btr and bbus, "B has both tracks")

  -- 1. a looped item, its pool two beats long, played at double speed from a quarter second in
  reaper.SelectProjectInstance(pa)
  local _, tch = reaper.GetTrackStateChunk(tr, "", false)
  reaper.SetTrackStateChunk(tr, (tch:gsub("\n>%s*$", "\n<VOLENV2\nACT 1 -1\nVIS 1 1 1\nLANEHEIGHT 0 0\nARM 0\nDEFSHAPE 0 -1 -1\nPT 0 1 0\n>\n>\n")), false)
  local env = reaper.GetTrackEnvelopeByChunkName(tr, "<VOLENV2")
  local ai = reaper.InsertAutomationItem(env, -1, 1, 5)
  reaper.GetSetAutomationItemInfo(env, ai, "D_POOL_QNLEN", 2, true)
  reaper.GetSetAutomationItemInfo(env, ai, "D_LOOPSRC", 1, true)
  points(env, ai, { { 1.1, 0.3 }, { 1.6, 0.9 } })
  reaper.GetSetAutomationItemInfo(env, ai, "D_STARTOFFS", 0.25, true)
  reaper.GetSetAutomationItemInfo(env, ai, "D_PLAYRATE", 2, true)
  out[#out + 1] = "A sent " .. pass(pa, A); recv(pb, B)
  local benv = reaper.GetTrackEnvelopeByChunkName(btr, "<VOLENV2")
  check(benv and reaper.CountAutomationItems(benv) == 1, "B has the looped item")
  if benv and reaper.CountAutomationItems(benv) == 1 then
    check(math.abs(reaper.GetSetAutomationItemInfo(benv, 0, "D_POOL_QNLEN", 0, false) - 2) < 1e-6, "its pool two beats long")
    check(reaper.CountEnvelopePointsEx(benv, 0 | 0x10000000) == 2, "two points a pass (" .. reaper.CountEnvelopePointsEx(benv, 0 | 0x10000000) .. ")")
  end
  same(env, benv, "the looped item")
  check(pass(pb, B) == 0, "B sends nothing back")

  -- 2. an item on the send's volume
  reaper.SelectProjectInstance(pa)
  local s = reaper.CreateTrackSend(tr, bus)
  out[#out + 1] = "A sent " .. pass(pa, A); recv(pb, B)
  local senv = reaper.GetTrackSendInfo_Value(bus, -1, 0, "P_ENV:<VOLENV")
  if senv and senv ~= 0 then
    local _, sch = reaper.GetEnvelopeStateChunk(senv, "", false)
    reaper.SetEnvelopeStateChunk(senv, (sch:gsub("ACT 0", "ACT 1"):gsub("VIS 0", "VIS 1")), false)
    local sai = reaper.InsertAutomationItem(senv, -1, 2, 2)
    points(senv, sai, { { 2, 0.2 }, { 3.5, 1 } })
  end
  out[#out + 1] = "A sent " .. pass(pa, A); recv(pb, B)
  local bsenv = reaper.GetTrackNumSends(bbus, -1) > 0 and reaper.GetTrackSendInfo_Value(bbus, -1, 0, "P_ENV:<VOLENV") or nil
  check(bsenv and bsenv ~= 0 and reaper.CountAutomationItems(bsenv) == 1, "B's send has the item")
  same(senv, bsenv ~= 0 and bsenv or nil, "the send's item")
  check(pass(pb, B) == 0, "B sends nothing back")

  -- 3. an item on a plug-in knob's envelope, and it stays when the chain changes
  reaper.SelectProjectInstance(pa)
  local fx = reaper.TrackFX_AddByName(tr, "ReaEQ", false, -1)
  local fenv = reaper.GetFXEnvelope(tr, fx, 0, true)
  local fai = reaper.InsertAutomationItem(fenv, -1, 0.5, 3)
  points(fenv, fai, { { 0.5, 0.1 }, { 2, 0.7 }, { 3.4, 0.4 } })
  out[#out + 1] = "A sent " .. pass(pa, A); recv(pb, B); recv(pb, B)
  local bfenv = reaper.GetFXEnvelope(btr, 0, 0, false)
  check(bfenv and reaper.CountAutomationItems(bfenv) == 1, "B's plug-in envelope has the item")
  same(fenv, bfenv, "the plug-in envelope's item")
  local _, bch = reaper.GetTrackStateChunk(btr, "", false)
  local pooled = {}
  for id in bch:gmatch("POOLEDENVINST (%d+)") do pooled[#pooled + 1] = id end
  check(#pooled >= 2 and pooled[#pooled] ~= pooled[1], "B's items each have a pool of their own")
  check(pass(pb, B) == 0, "B sends nothing back")
  reaper.SelectProjectInstance(pa)
  reaper.TrackFX_AddByName(tr, "ReaComp", false, -1)
  out[#out + 1] = "A sent " .. pass(pa, A); recv(pb, B); recv(pb, B)
  check(reaper.TrackFX_GetCount(btr) == 2, "B has the new chain")
  bfenv = reaper.GetFXEnvelope(btr, 0, 0, false)
  check(bfenv and reaper.CountAutomationItems(bfenv) == 1, "the plug-in envelope's item stays through the chain change")
  same(fenv, bfenv, "after the chain change it")
  check(pass(pb, B) == 0, "B sends nothing back")

  -- 4. the master's FX button
  local ma, mb = reaper.GetMasterTrack(pa), reaper.GetMasterTrack(pb)
  reaper.SelectProjectInstance(pa)
  reaper.SetMediaTrackInfo_Value(ma, "I_FXEN", 0)
  out[#out + 1] = "A sent " .. pass(pa, A); recv(pb, B)
  check(reaper.GetMediaTrackInfo_Value(mb, "I_FXEN") == 0, "B's master plug-ins went off")
  check(pass(pb, B) == 0, "B sends nothing back")
  reaper.SelectProjectInstance(pa)
  reaper.SetMediaTrackInfo_Value(ma, "I_FXEN", 1)
  out[#out + 1] = "A sent " .. pass(pa, A); recv(pb, B)
  check(reaper.GetMediaTrackInfo_Value(mb, "I_FXEN") == 1, "and back on")
  check(pass(pb, B) == 0, "B sends nothing back")
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
for _, p in pairs({ pa, pb }) do
  if reaper.ValidatePtr2(0, p, "ReaProject*") then
    reaper.SelectProjectInstance(p)
    reaper.Main_SaveProjectEx(p, D .. "/ai_" .. stamp .. "_end.rpp", 8)
    reaper.Main_OnCommand(40860, 0)
  end
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or fails .. " FAILED") .. "\n" .. table.concat(out, "\n")
