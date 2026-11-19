-- Run inside REAPER (ReaScript). Round 1 review engine fixes (0.59.45): a track one computer deleted, brought back there by a bandmate's later
-- change, comes back with its plug-in (S4); renaming your track to a name someone else has claimed is refused and put back (S13); going back
-- leaves an item changed here and not sent yet as it is (D3). Two scratch tabs, a scratch shared folder; both saved there and closed at the end.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "prints", "json" }) do package.loaded[m] = nil end
local band, sync, mirror = require("band"), require("sync"), require("mirror")
mirror.FX_SET_GAP = 0 -- (chains land back to back here)
local stamp = os.time()
local root = D .. "/eroot_" .. stamp
local song, room = "EngineLab", "main"
local A, B = { user = "James", root = root }, { user = "Bee", root = root }
reaper.RecursiveCreateDirectory(sync.room_dir(A, song, room) .. "/events", 0)
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local yes = function() return true end
local function hold(s) local w = reaper.time_precise(); while reaper.time_precise() - w < s do end end
local function settle() for _, f in pairs(mirror.fx_seen) do f.since = -math.huge end end
local function watch(p, cfg, opts)
  reaper.SelectProjectInstance(p)
  opts = opts or { can = yes, mode = "open" }
  local n = mirror.watch(p, cfg, song, room, opts); settle()
  return n + mirror.watch(p, cfg, song, room, opts)
end
local function recv(p, cfg) reaper.SelectProjectInstance(p); for _ = 1, 3 do sync.receive(p, cfg, song, room, yes) end end
local function track(p, name)
  for i = 0, reaper.CountTracks(p) - 1 do
    local t = reaper.GetTrack(p, i)
    if select(2, reaper.GetTrackName(t)) == name then return t end
  end
end
local front = reaper.EnumProjects(-1)
local pa, pb
local ok, err = pcall(function()
  reaper.Main_OnCommand(40859, 0); pa = reaper.EnumProjects(-1)
  reaper.Main_OnCommand(40859, 0); pb = reaper.EnumProjects(-1)
  sync.watch_timeline(pa, A, song, room, yes); sync.watch_timeline(pb, B, song, room, yes)

  -- S4: A makes Bass with ReaEQ; B has it. A deletes it; B, not having seen that, moves its fader later. B's change wins on A: Bass comes
  -- back there with its plug-in, not bare
  reaper.SelectProjectInstance(pa)
  reaper.InsertTrackInProject(pa, 0, 0)
  local bass = reaper.GetTrack(pa, 0)
  reaper.GetSetMediaTrackInfo_String(bass, "P_NAME", "Bass", true)
  reaper.TrackFX_AddByName(bass, "ReaEQ", false, -1)
  watch(pa, A); hold(3.2); watch(pa, A)
  recv(pb, B)
  local bb = track(pb, "Bass")
  check(bb and reaper.TrackFX_GetCount(bb) == 1, "B has Bass and its plug-in")
  reaper.SelectProjectInstance(pa)
  reaper.DeleteTrack(track(pa, "Bass"))
  watch(pa, A)
  reaper.SelectProjectInstance(pb)
  reaper.SetMediaTrackInfo_Value(bb, "D_VOL", 0.5)
  watch(pb, B)
  recv(pa, A)
  local back = track(pa, "Bass")
  check(back ~= nil, "Bass is back on A (B's later change won)")
  check(back and reaper.TrackFX_GetCount(back) == 1, "with its plug-in, not bare (" .. tostring(back and reaper.TrackFX_GetCount(back)) .. ")")

  -- S13: A claims Guitar; B renames its own Gtr to Guitar: refused, the name goes back, and it says whose claim it is
  sync.set_claims(A, song, room, { tracks = { "Guitar" }, regions = {}, times = {} })
  reaper.SelectProjectInstance(pb)
  reaper.InsertTrackInProject(pb, reaper.CountTracks(pb), 0)
  local gtr = reaper.GetTrack(pb, reaper.CountTracks(pb) - 1)
  reaper.GetSetMediaTrackInfo_String(gtr, "P_NAME", "Gtr", true)
  local can, who = sync.authority(B, song, room, nil)
  local bopts = { can = can, mode = who.mode, is_claimed = who.is_claimed, owner_of = who.owner_of }
  watch(pb, B, bopts)
  reaper.GetSetMediaTrackInfo_String(gtr, "P_NAME", "Guitar", true)
  watch(pb, B, bopts)
  check(select(2, reaper.GetTrackName(gtr)) == "Gtr", "the rename onto James's claim is put back (" .. select(2, reaper.GetTrackName(gtr)) .. ")")
  local said = false
  for _, l in ipairs(band.activity()) do said = said or tostring(l):find("James has claimed Guitar: pick another name", 1, true) ~= nil end
  check(said, "and it says whose claim it is")

  -- D3: A's item, sent, then moved here and not looked at yet: going back to its first version leaves it, and says so
  reaper.SelectProjectInstance(pa)
  local it = reaper.CreateNewMIDIItemInProj(back, 0, 2, false)
  watch(pa, A)
  local ioid = mirror.item_oid(it)
  local _, _, first = mirror.known(pa, ioid)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", 4)
  watch(pa, A)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", 8) -- (changed here, not sent yet)
  local ev = mirror.event_file(sync.room_dir(A, song, room), first)
  local msg = mirror.revert(pa, A, song, room, { [ioid] = ev }, { can = yes, mode = "open" })
  check(math.abs(reaper.GetMediaItemInfo_Value(it, "D_POSITION") - 8) < 1e-6, "the unsent move stays")
  check(tostring(msg):find("left as they are", 1, true) ~= nil, "and the result says so: " .. tostring(msg))
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
for _, p in pairs({ pa, pb }) do
  if p and reaper.ValidatePtr2(0, p, "ReaProject*") then
    reaper.SelectProjectInstance(p)
    reaper.Main_SaveProjectEx(p, D .. "/engine_" .. stamp .. "_end.rpp", 8)
    reaper.Main_OnCommand(40860, 0)
  end
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or fails .. " FAILED") .. "\n" .. table.concat(out, "\n")
