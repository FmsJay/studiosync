-- Run inside REAPER (ReaScript). Take comps (one recording's takes, split, a take picked in each piece) through takes becoming lanes
-- and through mirror sync (0.58.85, James: Nostalgia's take comps turned into lanes with the wrong takes and silences, "a BIG thing,
-- one person uses takes a lot instead of lanes"). What plays at every moment (the source file and where in it) is compared before and
-- after, away from the joins. A scratch tab and folder only; three test tones written here.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "mirror", "prints", "sync", "prep", "json" }) do package.loaded[m] = nil end
local band, mirror, prints = require("band"), require("mirror"), require("prints")
local dir = D .. "/takecomp_" .. os.time()
reaper.RecursiveCreateDirectory(dir, 0)
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end

-- three 16 s mono tones, one per take (16-bit, 8 kHz: small)
local function wav(path, hz)
  local rate, n = 8000, 8000 * 16
  local f = io.open(path, "wb")
  f:write("RIFF", string.pack("<I4", 36 + n * 2), "WAVEfmt ", string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, rate, rate * 2, 2, 16), "data", string.pack("<I4", n * 2))
  local parts = {}
  for i = 0, n - 1 do parts[#parts + 1] = string.pack("<i2", math.floor(math.sin(2 * math.pi * hz * i / rate) * 8000)) end
  f:write(table.concat(parts)); f:close()
  return path
end
local SRC = { wav(dir .. "/takeA.wav", 220), wav(dir .. "/takeB.wav", 330), wav(dir .. "/takeC.wav", 440) }

-- What plays at time t on a track: "file@position in it", or "-" for nothing (an empty take, or no item).
local function plays(tr, t)
  local lanes = reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") == 2
  local best, best_at
  for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, j)
    local a = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    local heard = not lanes or reaper.GetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. math.floor(reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE"))) > 0
    if heard and reaper.GetMediaItemInfo_Value(it, "B_MUTE") == 0 and t >= a and t < a + reaper.GetMediaItemInfo_Value(it, "D_LENGTH") and (not best_at or a > best_at) then
      best, best_at = it, a
    end
  end
  if not best then return "-" end
  local tk = reaper.GetActiveTake(best)
  if not tk then return "-" end
  local fn = reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(tk), ""):match("[^/\\]+$")
  local pos = (t - best_at) * reaper.GetMediaItemTakeInfo_Value(tk, "D_PLAYRATE") + reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS")
  return string.format("%s@%.2f", fn, pos)
end
-- The sample points: every 0.25 s, skipping 60 ms either side of a join.
local function points(from, to, joins)
  local list = {}
  for t = from + 0.05, to - 0.05, 0.25 do
    local near = false
    for _, j in ipairs(joins) do near = near or math.abs(t - j) < 0.06 end
    if not near then list[#list + 1] = t end
  end
  return list
end
local function snapshot(tr, pts) local s = {} for i, t in ipairs(pts) do s[i] = plays(tr, t) end return s end
local function same(a, b, pts)
  local bad = {}
  for i = 1, #pts do if a[i] ~= b[i] then bad[#bad + 1] = string.format("%.2f: %s -> %s", pts[i], a[i], b[i]) end end
  return #bad == 0, table.concat(bad, "; ", 1, math.min(#bad, 4))
end

-- One recording with three takes at `at`, `len` long, split at `cuts` with `picks` (take numbers from 0) per piece; pieces overlap by
-- 10 ms with fades where `xfade`.
local function recording(tr, at, len, cuts, picks, xfade)
  local it = reaper.AddMediaItemToTrack(tr)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", at); reaper.SetMediaItemInfo_Value(it, "D_LENGTH", len)
  for k, path in ipairs(SRC) do
    local tk = reaper.AddTakeToMediaItem(it)
    reaper.SetMediaItemTake_Source(tk, reaper.PCM_Source_CreateFromFile(path))
    reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", 1 + k * 0.1) -- (each take a little further in: offsets that differ show a wrong take)
  end
  local pieces, x = { it }, it
  for _, c in ipairs(cuts) do x = reaper.SplitMediaItem(x, c); pieces[#pieces + 1] = x end
  for i, p in ipairs(pieces) do
    reaper.SetMediaItemInfo_Value(p, "I_CURTAKE", picks[i])
    if xfade and i < #pieces then
      reaper.SetMediaItemInfo_Value(p, "D_LENGTH", reaper.GetMediaItemInfo_Value(p, "D_LENGTH") + 0.01)
      reaper.SetMediaItemInfo_Value(p, "D_FADEOUTLEN_AUTO", 0.01)
      reaper.SetMediaItemInfo_Value(pieces[i + 1], "D_FADEINLEN_AUTO", 0.01)
    end
  end
  return pieces
end

local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0)
local p = reaper.EnumProjects(-1)
local ok, err = pcall(function()
  local all = function() return true end
  -- 1. a plain track: a comp in four pieces with crossfades, and a print take left on one piece (an old version's)
  reaper.InsertTrackInProject(p, 0, 0)
  local t1 = reaper.GetTrack(p, 0)
  reaper.GetSetMediaTrackInfo_String(t1, "P_NAME", "Vox comp", true)
  local pieces = recording(t1, 2, 8, { 4, 6, 8 }, { 1, 0, 2, 1 }, true)
  local wet = reaper.AddTakeToMediaItem(pieces[3])
  reaper.SetMediaItemTake_Source(wet, reaper.PCM_Source_CreateFromFile(SRC[1]))
  reaper.GetSetMediaItemTakeInfo_String(wet, "P_EXT:" .. prints.KEY, "oldprint", true)
  reaper.SetMediaItemInfo_Value(pieces[3], "I_CURTAKE", 2) -- (still playing its third real take)
  local pts1 = points(2, 10, { 4, 6, 8 })
  local before1 = snapshot(t1, pts1)
  check(before1[1]:find("takeB", 1, true) and before1[#before1]:find("takeB", 1, true), "the comp plays B, A, C, B: " .. before1[1] .. " ... " .. before1[#before1])
  check(mirror.picked_take(pieces[3]) == 2 and #mirror.real_takes(pieces[3]) == 3, "the print take isn't one of the real takes")
  reaper.Undo_OnStateChange2(p, "take comps: the recording") -- (an undo point of its own, so Ctrl+Z below stops at the takes)
  prints.takes_to_lanes(p, all)
  local ok1, why1 = same(before1, snapshot(t1, pts1), pts1)
  check(ok1, "plain track: the lanes play exactly the comp (" .. (why1 ~= "" and why1 or "every point") .. ")")
  check(reaper.GetMediaTrackInfo_Value(t1, "I_FREEMODE") == 2, "and it's in lanes now")
  -- 1b. Ctrl+Z on it sticks: the next pass leaves the takes (0.58.91)
  local function takes_back()
    for j = 0, reaper.CountTrackMediaItems(t1) - 1 do if #mirror.real_takes(reaper.GetTrackMediaItem(t1, j)) > 1 then return true end end
    return false
  end
  reaper.Undo_DoUndo2(p)
  check(takes_back(), "Ctrl+Z puts the takes back")
  prints.takes_to_lanes(p, all)
  check(takes_back() and band.track_ext(t1, "band_keep_takes") ~= "", "and the next pass leaves them as takes")

  -- 2. like Nostalgia's Track 10 and 8: pieces holding empty takes (REAPER's "TAKE NULL"), playing a take that isn't the first,
  -- and one piece that picked an empty take (silence, on purpose)
  reaper.InsertTrackInProject(p, 1, 0)
  local t2 = reaper.GetTrack(p, 1)
  reaper.GetSetMediaTrackInfo_String(t2, "P_NAME", "Gtr comp", true)
  local three = recording(t2, 1, 10, { 3, 7 }, { 1, 1, 2 }, false)
  for i = 2, 3 do
    local x = three[i]
    local cur = reaper.GetMediaItemInfo_Value(x, "I_CURTAKE")
    local _, chunk = reaper.GetItemStateChunk(x, "", false)
    reaper.SetItemStateChunk(x, (chunk:gsub(">%s*$", "TAKE NULL\n>\n")), false)
    reaper.SetMediaItemInfo_Value(x, "I_CURTAKE", i == 3 and 3 or cur)
  end
  check(reaper.GetTake(three[3], 3) == nil and reaper.CountTakes(three[3]) == 4, "a piece with an empty take, playing it")
  local pts2 = points(1, 11, { 3, 7 })
  local before2 = snapshot(t2, pts2)
  prints.takes_to_lanes(p, all)
  local ok2, why2 = same(before2, snapshot(t2, pts2), pts2)
  check(ok2, "a piece with an empty take: no silence where the second take played (" .. (why2 ~= "" and why2 or "every point") .. ")")

  -- 3. a track already in lanes (C1 playing, an old pass below): a comp on C1 in five pieces
  reaper.InsertTrackInProject(p, 2, 0)
  local t3 = reaper.GetTrack(p, 2)
  reaper.GetSetMediaTrackInfo_String(t3, "P_NAME", "Keys comp", true)
  reaper.SetMediaTrackInfo_Value(t3, "I_FREEMODE", 2)
  local old = reaper.AddMediaItemToTrack(t3)
  reaper.SetMediaItemInfo_Value(old, "D_POSITION", 20); reaper.SetMediaItemInfo_Value(old, "D_LENGTH", 4)
  reaper.SetMediaItemTake_Source(reaper.AddTakeToMediaItem(old), reaper.PCM_Source_CreateFromFile(SRC[1]))
  reaper.SetMediaItemInfo_Value(old, "I_FIXEDLANE", 1)
  reaper.SetMediaTrackInfo_Value(t3, "C_LANEPLAYS:0", 1); reaper.SetMediaTrackInfo_Value(t3, "C_LANEPLAYS:1", 0)
  local five = recording(t3, 2, 10, { 4, 5, 7, 9 }, { 2, 0, 1, 2, 0 }, true)
  for _, x in ipairs(five) do reaper.SetMediaItemInfo_Value(x, "I_FIXEDLANE", 0) end
  local lanes0 = reaper.GetMediaTrackInfo_Value(t3, "I_NUMFIXEDLANES")
  local pts3 = points(2, 12, { 4, 5, 7, 9 })
  local before3 = snapshot(t3, pts3)
  prints.takes_to_lanes(p, all)
  local ok3, why3 = same(before3, snapshot(t3, pts3), pts3)
  check(ok3, "already in lanes: the playing lane plays the comp (" .. (why3 ~= "" and why3 or "every point") .. ")")
  local added = reaper.GetMediaTrackInfo_Value(t3, "I_NUMFIXEDLANES") - lanes0
  check(added == 3, "and each take gets one lane, shared by every piece (each take is some piece's other take): " .. added .. " lane(s) added for 3 takes in 5 pieces")
  check(reaper.GetMediaItemInfo_Value(old, "I_FIXEDLANE") ~= 0 or reaper.GetMediaTrackInfo_Value(t3, "C_LANEPLAYS:" .. reaper.GetMediaItemInfo_Value(old, "I_FIXEDLANE")) == 0,
    "the old pass still doesn't play")

  -- 4. mirror sync: which take plays travels (BANDTAKE), and lands on a fresh item as picked
  reaper.InsertTrackInProject(p, 3, 0)
  local t4 = reaper.GetTrack(p, 3)
  reaper.GetSetMediaTrackInfo_String(t4, "P_EXT:band_oid", "T-TEST-20261116000000-4", true)
  local src = recording(t4, 30, 4, {}, { 2 }, false)[1]
  local st = mirror.item_state(src, dir .. "/media")
  check(st:find("BANDTAKE 2\n", 1, true) ~= nil, "an item with takes says which one plays")
  reaper.SetMediaItemInfo_Value(src, "I_CURTAKE", 0)
  check(mirror.item_state(src, dir .. "/media"):find("BANDTAKE 0\n", 1, true) ~= nil, "and picking another changes what it says (so it goes out)")
  reaper.SetMediaItemInfo_Value(src, "I_CURTAKE", 2)
  local okA, h = mirror.apply(p, { obj = "item", oid = "I-TEST-20261116000000-9", track = "T-TEST-20261116000000-4", state = st }, dir .. "/media", false)
  local fresh = mirror.find(p, "item", "I-TEST-20261116000000-9")
  check(okA and fresh and reaper.GetMediaItemInfo_Value(fresh, "I_CURTAKE") == 2, "arriving new, it plays the sender's pick (it played the first)")
  local legacy = st:gsub("BANDTAKE %d+\n", "")
  reaper.SetMediaItemInfo_Value(fresh, "I_CURTAKE", 1)
  mirror.apply(p, { obj = "item", oid = "I-TEST-20261116000000-9", track = "T-TEST-20261116000000-4", state = legacy }, dir .. "/media", false)
  check(reaper.GetMediaItemInfo_Value(fresh, "I_CURTAKE") == 1, "a version from before 0.58.85 leaves this machine's pick alone")
  local here = mirror.item_state(fresh, dir .. "/media")
  check(mirror.only_pick_new("T-TEST-20261116000000-4", here, (here:gsub("BANDTAKE %d+\n", ""))), "and the same item from before reads as itself but for the pick (no flood of changes on updating)")
  check(not mirror.only_pick_new("T-TEST-20261116000000-4", here, (here:gsub("BANDTAKE %d+\n", ""):gsub("POSITION [^\n]*", "POSITION 31"))), "but not one that moved meanwhile")
  check(not mirror.only_pick_new("T-TEST-20261116000000-4", here, here), "nor a version that says its pick")
  -- (0.58.87, review) an item with an empty take ("TAKE NULL") playing a take after it: through mirror, the empty take stays empty and in its place
  local nul = recording(t4, 40, 4, {}, { 1 }, false)[1]
  do
    local _, chunk = reaper.GetItemStateChunk(nul, "", false)
    reaper.SetItemStateChunk(nul, (chunk:gsub(">%s*$", "TAKE NULL\n>\n")), false)
    reaper.SetMediaItemInfo_Value(nul, "I_CURTAKE", 2)
  end
  local nst = mirror.item_state(nul, dir .. "/media")
  mirror.apply(p, { obj = "item", oid = "I-TEST-20261116000000-10", track = "T-TEST-20261116000000-4", state = nst }, dir .. "/media", false)
  local nfresh = mirror.find(p, "item", "I-TEST-20261116000000-10")
  local okn = nfresh and reaper.CountTakes(nfresh) == reaper.CountTakes(nul) and reaper.GetTake(nfresh, 3) == nil and reaper.GetTake(nfresh, 2) ~= nil
    and reaper.GetMediaItemInfo_Value(nfresh, "I_CURTAKE") == 2
  check(okn, "an empty take arrives empty, in its place, and the pick plays the same take (" .. (nfresh and (reaper.CountTakes(nfresh) .. " takes, playing " ..
    reaper.GetMediaItemInfo_Value(nfresh, "I_CURTAKE") .. ", take 4 " .. tostring(reaper.GetTake(nfresh, 3))) or "none") .. ")")
  local function sans_id(s) return (s:gsub("<EXTI\n.->\n", "")) end -- (the arrival carries its id; the original here has none)
  check(nfresh and mirror.item_hash("T", sans_id(mirror.item_state(nfresh, dir .. "/media"))) == mirror.item_hash("T", sans_id(nst)), "and it reads back the same as it was sent")

  -- 5. sharing a song (Prepare's "lanes" step): a comp with a piece that plays an empty take on purpose, and its other takes kept
  reaper.InsertTrackInProject(p, 4, 0)
  local t5 = reaper.GetTrack(p, 4)
  reaper.GetSetMediaTrackInfo_String(t5, "P_NAME", "Bass comp", true)
  local four = recording(t5, 40, 8, { 42, 44, 46 }, { 2, 1, 0, 1 }, true)
  do
    local x = four[3]
    local _, chunk = reaper.GetItemStateChunk(x, "", false)
    reaper.SetItemStateChunk(x, (chunk:gsub(">%s*$", "TAKE NULL\n>\n")), false)
    reaper.SetMediaItemInfo_Value(x, "I_CURTAKE", 3) -- (silence here, on purpose)
  end
  local pts5 = points(40, 48, { 42, 44, 46 })
  local before5 = snapshot(t5, pts5)
  local prep = require("prep")
  local rows = prep.scan(p, nil, nil)
  local clutter_row
  for _, r in ipairs(rows) do
    if r.key == "clutter" then clutter_row = r end
    r.on = r.key == "lanes" or r.key == "clutter"
  end
  local listed = false
  for _, it in ipairs(clutter_row and clutter_row.todo or {}) do listed = listed or it == four[3] end
  check(not listed, "a piece playing an empty take, with real takes in it, isn't 'an empty item' to remove")
  prep.apply(p, nil, nil, rows, dir)
  local ok5, why5 = same(before5, snapshot(t5, pts5), pts5)
  check(ok5, "Prepare's lanes: what plays is the comp, the silent piece silent (" .. (why5 ~= "" and why5 or "every point") .. ")")
  local kept = 0
  for j = 0, reaper.CountTrackMediaItems(t5) - 1 do
    local tk = reaper.GetActiveTake(reaper.GetTrackMediaItem(t5, j))
    if tk and reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(tk), ""):find("take", 1, true) then kept = kept + 1 end
  end
  check(kept >= 9, "and the other takes are all still there, on lanes: " .. kept .. " parts")
  local _ = h
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
reaper.SelectProjectInstance(p)
reaper.Main_SaveProjectEx(p, dir .. "/take_comps.rpp", 8)
reaper.Main_OnCommand(40860, 0)
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
out[#out + 1] = fails == 0 and "ALL PASS" or (fails .. " FAILED")
return table.concat(out, "\n")
