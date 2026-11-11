-- Run inside REAPER (ReaScript). Two people change one item at once (0.58.43, docs/clashes.md): what each changed comes together on both computers;
-- where both rewrote the same notes, the winner's play and the loser's are kept as another take; quick nudges are one edit; changes carry the
-- clock (hlc). Two scratch tabs, a scratch shared folder; both saved there and closed at the end.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "prints" }) do package.loaded[m] = nil end
require("prints").SETTLE = 0
local band, sync, mirror = require("band"), require("sync"), require("mirror")
local root = D .. "/mroot_" .. os.time()
local song, room = "MergeLab", "main"
local A, B = { user = "Laptop", root = root }, { user = "James", root = root }
reaper.RecursiveCreateDirectory(sync.room_dir(A, song, room) .. "/events", 0)
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local yes = function() return true end
local front = reaper.EnumProjects(-1)
local was_bg, was_put = reaper.GetExtState(band.SECTION, "bg render"), reaper.GetExtState(band.SECTION, "put back")
reaper.SetExtState(band.SECTION, "bg render", "off", false)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pb = reaper.EnumProjects(-1)
local was_driver = sync.driver_name
sync.driver_name = "nobody" -- (nobody owns anything here: the clash rule alone decides)
local function watch(p, cfg)
  reaper.SelectProjectInstance(p)
  local n = 0
  for _ = 1, 10 do n = n + mirror.watch(p, cfg, song, room, { can = yes, mode = "open" }); if not mirror.more then break end end
  return n
end
local function recv(p, cfg) reaper.SelectProjectInstance(p); for _ = 1, 4 do sync.receive(p, cfg, song, room, yes) end end
local function item(p) local tr = reaper.GetTrack(p, 0); return tr and reaper.GetTrackMediaItem(tr, 0) end
local function pitches(it)
  local out = {}
  for t = 0, reaper.CountTakes(it) - 1 do
    local tk = reaper.GetTake(it, t)
    if tk and reaper.TakeIsMIDI(tk) then
      local _, _, _, _, _, _, pitch = reaper.MIDI_GetNote(tk, 0)
      out[#out + 1] = pitch
    end
  end
  return out
end
local ok, err = pcall(function()
  reaper.SelectProjectInstance(pa)
  reaper.InsertTrackInProject(pa, 0, 0)
  local ta = reaper.GetTrack(pa, 0)
  reaper.GetSetMediaTrackInfo_String(ta, "P_NAME", "Keys", true)
  local it = reaper.CreateNewMIDIItemInProj(ta, 0, 4, false)
  local tk = reaper.GetActiveTake(it)
  reaper.MIDI_InsertNote(tk, false, false, 0, 960, 0, 60, 100, false)
  watch(pa, A); watch(pa, A)
  recv(pb, B)
  local ia, ib = item(pa), item(pb)
  check(ia and ib, "the other tab has the item")
  if not (ia and ib) then return end

  -- ---- different changes at once: one moves it, the other turns it down. Both stand, on both computers
  reaper.SelectProjectInstance(pa); reaper.SetMediaItemInfo_Value(ia, "D_POSITION", 8); watch(pa, A)
  reaper.SelectProjectInstance(pb); reaper.SetMediaItemInfo_Value(ib, "D_VOL", 0.5); watch(pb, B)
  recv(pb, B); recv(pa, A)
  ia, ib = item(pa), item(pb)
  check(math.abs(reaper.GetMediaItemInfo_Value(ia, "D_POSITION") - 8) < 1e-6 and math.abs(reaper.GetMediaItemInfo_Value(ia, "D_VOL") - 0.5) < 1e-6,
    "Laptop has its move and James's volume")
  check(math.abs(reaper.GetMediaItemInfo_Value(ib, "D_POSITION") - 8) < 1e-6 and math.abs(reaper.GetMediaItemInfo_Value(ib, "D_VOL") - 0.5) < 1e-6,
    "James has his volume and Laptop's move")
  local oid = mirror.item_oid(ia)
  local _, _, ka = mirror.known(pa, oid)
  local _, _, kb = mirror.known(pb, oid)
  check(ka == kb and mirror.split_merge(ka) ~= nil, "both hold the same merged version (" .. tostring(ka) .. ")")
  check(mirror.root(pa) == mirror.root(pb), "and the same project, by fingerprint")
  check(watch(pa, A) == 0 and watch(pb, B) == 0, "nothing more goes out: it's settled")

  -- ---- both rewrite the same notes: the winner's play; the loser's come along as another take, named for them
  reaper.SelectProjectInstance(pa)
  reaper.MIDI_SetNote(reaper.GetActiveTake(ia), 0, nil, nil, nil, nil, nil, 62, nil, false); watch(pa, A)
  reaper.SelectProjectInstance(pb)
  reaper.MIDI_SetNote(reaper.GetActiveTake(ib), 0, nil, nil, nil, nil, nil, 64, nil, false); watch(pb, B)
  reaper.DeleteExtState(band.SECTION, "put back", false)
  recv(pb, B); recv(pa, A)
  ia, ib = item(pa), item(pb)
  local pa_p, pb_p = pitches(ia), pitches(ib)
  check(#pa_p == 2 and #pb_p == 2, "two takes on both: " .. table.concat(pa_p, ",") .. " / " .. table.concat(pb_p, ","))
  local has = function(t, v) for _, x in ipairs(t) do if x == v then return true end end end
  check(has(pa_p, 62) and has(pa_p, 64) and has(pb_p, 62) and has(pb_p, 64), "both versions of the notes are there, on both")
  local named = false
  for t = 0, reaper.CountTakes(ia) - 1 do
    named = named or select(2, reaper.GetSetMediaItemTakeInfo_String(reaper.GetTake(ia, t), "P_NAME", "", false)):find("'s version", 1, true) ~= nil
  end
  check(named, "the extra take is named for whoever's version it is")
  local _, _, ka2 = mirror.known(pa, oid)
  local _, _, kb2 = mirror.known(pb, oid)
  check(ka2 == kb2 and mirror.root(pa) == mirror.root(pb), "the same version and project on both")
  local note = band.json_decode(reaper.GetExtState(band.SECTION, "put back")) or {}
  check(tostring(note.text):find("kept as another take", 1, true) ~= nil, "the loser hears where theirs went: " .. tostring(note.text))

  -- ---- quick nudges are one edit; changes carry the clock
  reaper.SelectProjectInstance(pa)
  local before = mirror.known(pa, oid)
  local sends = {}
  for k = 1, 3 do reaper.SetMediaItemInfo_Value(ia, "D_POSITION", 8 + k * 0.1); sends[#sends + 1] = watch(pa, A) end
  local after, _, evid = mirror.known(pa, oid)
  check(after == before + 1 and sends[1] >= 1 and sends[2] >= 1 and sends[3] >= 1, string.format("three nudges, each sent, one revision (%s -> %s; sent %s, the second with the takes made into lanes)",
    tostring(before), tostring(after), table.concat(sends, ",")))
  local ev = mirror.event_file(sync.room_dir(A, song, room), evid)
  check(ev and tonumber(ev.hlc) and ev.base_ev ~= nil, "a change carries its clock and the version it started from")
  -- (the item now has two takes: StudioSync makes takes into fixed lanes, by whoever made its newest change, so the loser's version becomes an item
  -- on a lane of its own. A few rounds both ways, then both computers hold the same items)
  for _ = 1, 4 do watch(pa, A); recv(pb, B); watch(pb, B); recv(pa, A) end
  local function list(p)
    local t = {}
    local tr = reaper.GetTrack(p, 0)
    for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local x = reaper.GetTrackMediaItem(tr, j)
      local tk = reaper.GetActiveTake(x)
      t[#t + 1] = string.format("%.2f %s L%d", reaper.GetMediaItemInfo_Value(x, "D_POSITION"),
        tk and select(2, reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", "", false)) or "-", math.floor(reaper.GetMediaItemInfo_Value(x, "I_FIXEDLANE")))
    end
    table.sort(t)
    return table.concat(t, " | ")
  end
  check(list(pa) == list(pb), "both computers end with the same items: " .. list(pa) .. "  //  " .. list(pb))
  check(list(pa):find("8.30", 1, true) ~= nil and list(pa):find("version", 1, true) ~= nil, "the last nudge, and the loser's version on a lane of its own")
  check(mirror.root(pa) == mirror.root(pb), "and the same project, by fingerprint")
end)
if not ok then fails = fails + 1; out[#out + 1] = "FAIL error: " .. tostring(err) end
sync.driver_name = was_driver
for _, p in ipairs({ pb, pa }) do
  reaper.SelectProjectInstance(p)
  reaper.Main_SaveProjectEx(p, root .. "/" .. tostring(p):gsub("%W", "") .. ".rpp", 8)
  reaper.Main_OnCommand(40860, 0)
end
if reaper.ValidatePtr(front, "ReaProject*") then reaper.SelectProjectInstance(front) end
reaper.SetExtState(band.SECTION, "bg render", was_bg, false)
if was_put ~= "" then reaper.SetExtState(band.SECTION, "put back", was_put, false) else reaper.DeleteExtState(band.SECTION, "put back", false) end
out[#out + 1] = string.format("merge_items: fails %d of %d", fails, #out)
return table.concat(out, "\n")
