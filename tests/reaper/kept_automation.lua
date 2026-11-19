-- Run inside REAPER (ReaScript). Automation of yours that isn't yours to change is kept, not lost (0.59.39): "James" (A) shares Bass with a
-- volume envelope; "Bee" (B) draws a point on it, may not change Bass, and the band's envelope comes back; B's version is kept as a file,
-- and putting it back brings B's point back. Scratch folder and scratch tabs only; the kept file it makes is removed at the end.
local D = reaper.GetResourcePath() .. "/StudioSync/tests" -- scratch: never the shared folder
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "json" }) do package.loaded[m] = nil end
local band, sync, mirror = require("band"), require("sync"), require("mirror")
local stamp = os.time()
local root = D .. "/kroot_" .. stamp
local song, room = "KeptLab", "main"
local A, B = { user = "James", root = root }, { user = "Bee", root = root }
reaper.RecursiveCreateDirectory(sync.room_dir(A, song, room) .. "/events", 0)
local yes, no = function() return true end, function() return false end
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local function settle() for _, f in pairs(mirror.fx_seen) do f.since = -math.huge end end
local function pass(p, cfg, can) local mode = "claims" -- (refused: B didn't make Bass, so being its maker doesn't let B in either)
  local n = mirror.watch(p, cfg, song, room, { can = can or yes, mode = mode }); settle()
  return n + mirror.watch(p, cfg, song, room, { can = can or yes, mode = mode }) end
local function recv(p, cfg) reaper.SelectProjectInstance(p); local n = 0
  for _ = 1, 3 do n = n + sync.receive(p, cfg, song, room, yes) end; return n end
local function track(p, name)
  for i = 0, reaper.CountTracks(p) - 1 do
    local t = reaper.GetTrack(p, i)
    if select(2, reaper.GetTrackName(t)) == name then return t end
  end
end
local function vol_env(t) return t and reaper.GetTrackEnvelopeByChunkName(t, "<VOLENV2") end
local kdir = band.home() .. "/kept automation"
local had = {}
for _, f in ipairs(band.files(kdir, ".json")) do had[f] = true end
local made = {}
local front = reaper.EnumProjects(-1)
local pa, pb
local ok, err = pcall(function()
  reaper.Main_OnCommand(40859, 0); pa = reaper.EnumProjects(-1)
  reaper.Main_OnCommand(40859, 0); pb = reaper.EnumProjects(-1)
  reaper.InsertTrackInProject(pa, 0, 0)
  local bass = reaper.GetTrack(pa, 0)
  reaper.GetSetMediaTrackInfo_String(bass, "P_NAME", "Bass", true)
  sync.watch_timeline(pa, A, song, room, yes); sync.watch_timeline(pb, B, song, room, yes)
  local _, ch = reaper.GetTrackStateChunk(bass, "", false)
  ch = ch:gsub("\n>%s*$", "\n<VOLENV2\nACT 1 -1\nVIS 1 1 1\nLANEHEIGHT 0 0\nARM 0\nDEFSHAPE 0 -1 -1\nPT 0 1 0\nPT 2 0.5 0\n>\n>\n")
  reaper.SetTrackStateChunk(bass, ch, false)
  out[#out + 1] = "A sent " .. pass(pa, A)
  out[#out + 1] = "B applied " .. recv(pb, B)
  local bb = track(pb, "Bass")
  check(vol_env(bb) and reaper.CountEnvelopePoints(vol_env(bb)) == 2, "B: Bass came with its 2-point envelope")
  -- B draws a point, but Bass isn't B's to change
  reaper.SelectProjectInstance(pb)
  reaper.InsertEnvelopePoint(vol_env(bb), 3, 0.25, 0, 0, false, true); reaper.Envelope_SortPoints(vol_env(bb))
  mirror.tempo_changed(pb) -- (as just after a tempo change landed: a drawn point is still an edit, not REAPER following the tempo. 0.59.39)
  pass(pb, B, no)
  bb = track(pb, "Bass")
  check(vol_env(bb) and reaper.CountEnvelopePoints(vol_env(bb)) == 2, "B: the band's envelope is back (" .. tostring(vol_env(bb) and reaper.CountEnvelopePoints(vol_env(bb))) .. " points)")
  local kept
  for _, f in ipairs(band.files(kdir, ".json")) do
    if not had[f] then made[#made + 1] = kdir .. "/" .. f; local k = band.read_json(kdir .. "/" .. f); if k and k.name == "Bass" then kept = k end end
  end
  check(kept ~= nil, "B's automation is kept as a file")
  check(kept and kept.state:find("PT 3 0.25", 1, true) ~= nil, "with B's point in it")
  check(kept and kept.room == sync.room_dir(B, song, room), "named for this room")
  -- put back (Restore > Kept automation): B's point returns
  local back = kept and mirror.apply(pb, { obj = "env", oid = kept.oid, track = kept.track, name = kept.name, state = kept.state }, nil, false)
  bb = track(pb, "Bass")
  check(back and vol_env(bb) and reaper.CountEnvelopePoints(vol_env(bb)) == 3, "putting it back brings B's point back")
  -- and A never got it
  check(reaper.CountEnvelopePoints(vol_env(track(pa, "Bass"))) == 2, "A's Bass still has the band's 2 points")
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
for _, f in ipairs(made) do os.remove(f) end
for _, p in pairs({ pa, pb }) do
  if reaper.ValidatePtr2(0, p, "ReaProject*") then
    reaper.SelectProjectInstance(p)
    reaper.Main_SaveProjectEx(p, D .. "/kept_" .. stamp .. "_end.rpp", 8)
    reaper.Main_OnCommand(40860, 0)
  end
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or fails .. " FAILED") .. "\n" .. table.concat(out, "\n")
