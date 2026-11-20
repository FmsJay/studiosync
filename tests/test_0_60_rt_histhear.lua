-- Song history playback (lib/histhear.lua, lib/webui/histhear.js; rt-history): the copy rebuilt from History matches the song as it was at that
-- point (tracks back and gone, items where they were, plug-ins, automation, sends renumbered, this computer's own tracks out); the job's prep
-- sets lanes, takes, track settings and the render in the background REAPER; a render's whole life with a stand-in bgrender (queued, one at a
-- time, progress, done and kept, cached, cancelled, failed, stuck, waiting for a recording); nothing in the open project touched while
-- previewing; a restore asks first with what changes, needs the driver for the whole song, and goes as one act and one undo point that Undo
-- takes back. (James, rt)
package.path = "lib/?.lua;" .. package.path
local now = 1000
local calls = {} -- every reaper.* function called, by name (what the preview may touch)
local PLAY = 0
local vfs = {} -- path -> contents (a stand-in disk)
local api = {
  time_precise = function() return now end,
  GetOS = function() return "Win64" end,
  GetExtState = function() return "" end,
  SetExtState = function() end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
  GetPlayStateEx = function() return PLAY end,
  file_exists = function(p) return vfs[p] ~= nil end,
  RecursiveCreateDirectory = function() return 1 end,
  GetProjExtState = function() return 0, "" end,
  genGuid = function() return "{11111111-2222-3333-4444-555555555555}" end,
  IsProjectDirty = function() return 1 end,
  CountTracks = function() return 0 end,
}
reaper = setmetatable({}, { __index = function(_, k)
  local f = api[k]
  if f then return function(...) calls[k] = (calls[k] or 0) + 1; return f(...) end end
  if not tostring(k):find("^StudioSync_") then return function() calls[k] = (calls[k] or 0) + 1; return 0 end end
end })
local band = require("band")
local mirror = require("mirror")
local hh = require("histhear")
local wh = require("webhistory")

-- ---- the history: a few tracks and items over two sessions ----------------------------------------------------------------------------
local function item(oid, pos, file, extra) return "<ITEM\nPOSITION " .. pos .. "\nLENGTH 2\n<EXT\nband_oid " .. oid .. "\n>\nNAME x\n<SOURCE WAVE\nFILE \"{media}/" .. file .. "\"\n>\n" .. (extra or "") .. ">\n" end
local function track(name, after, more) local t = { name = name, after = after, vol = "0.500000", pan = "-0.2500", mute = 0, phase = 0, depth = 0, nchan = "2" }; for k, v in pairs(more or {}) do t[k] = v end; return t end
local FX1 = "<FXCHAIN\nBYPASS 0 0 0\n<JS \"utility/volume\" \"\"\n1 - - -\n>\nWAK 0 0\n>\n"
local FX2 = "<FXCHAIN\nBYPASS 0 0 0\n<VST \"VST: ReaComp (Cockos)\" reacomp.dll 0 \"\" 1\nAAAA\n>\nWAK 0 0\n>\n"
local ENV = "<VOLENV2\nEGUID {E}\nACT 1 -1\nPT 0 1 0\nPT 4 0.5 0\n>\n"
local entries, n = {}, 0
local function ev(time, e) n = n + 1; e.time, e.id, e.kind, e.type, e.user = "2026-11-10T" .. time .. "Z", "e" .. n, "obj", "obj", e.user or "James"; entries[#entries + 1] = e; return e end
ev("10:00:00", { obj = "track", oid = "T-A-1", rev = 1, name = "Drums", state = track("Drums", "") })
ev("10:00:10", { obj = "item", oid = "I-A-1", rev = 1, track = "T-A-1", state = item("I-A-1", 0, "kick.wav") })
ev("10:00:20", { obj = "track", oid = "T-A-2", rev = 1, name = "Bass", state = track("Bass", "T-A-1") })
ev("10:00:30", { obj = "fx", oid = "F-A-2", rev = 1, track = "T-A-2", state = FX1 })
ev("10:00:40", { obj = "item", oid = "I-A-2", rev = 1, track = "T-A-1", state = item("I-A-2", 4, "snare.wav") })
ev("10:00:50", { obj = "track", oid = "T-A-4", rev = 1, name = "Vox", state = track("Vox", "T-A-2", { freemode = 2, lanes = 2, plays = "1,0", vol = "0.700000" }) })
ev("10:01:00", { obj = "item", oid = "I-A-4", rev = 1, track = "T-A-4", state = item("I-A-4", 8, "vox.wav", "TAKE\nNAME wet\n<EXT\nband_m_print 1\n>\n<SOURCE WAVE\nFILE \"{media}/voxp.wav\"\n>\nTAKE\nNAME y\n<SOURCE WAVE\nFILE \"{media}/vox2.wav\"\n>\n") .. "BANDLANE 1\nBANDTAKE 1\n" })
ev("10:01:10", { obj = "item", oid = "I-A-3", rev = 1, track = "T-A-2", state = item("I-A-3", 2, "bass.wav") })
ev("10:01:20", { obj = "env", oid = "E-A-2", rev = 1, track = "T-A-2", state = ENV })
ev("10:01:30", { obj = "recv", oid = "R-A-2", rev = 1, track = "T-A-2", state = "AUXRECV T-A-1 0 0.8 0 0 0 0 0 0 -1:U 0 -1 ''\n" })
local POINT = wh.epoch("2026-11-10T10:01:30Z")
ev("11:00:00", { obj = "track", oid = "T-A-3", rev = 1, name = "Keys", state = track("Keys", "T-A-2") })
ev("11:00:10", { obj = "item", oid = "I-A-6", rev = 1, track = "T-A-3", state = item("I-A-6", 1, "keys.wav") })
ev("11:00:20", { obj = "fx", oid = "F-A-2", rev = 2, track = "T-A-2", state = FX2 })
ev("11:00:30", { obj = "item", oid = "I-A-2", rev = 2, track = "T-A-1", state = item("I-A-2", 10, "snare.wav") })
ev("11:00:40", { obj = "item", oid = "I-A-5", rev = 1, track = "T-A-2", state = item("I-A-5", 6, "bass2.wav") })
ev("11:00:50", { obj = "track", oid = "T-A-4", rev = 2, gone = true, name = "Vox" })
ev("11:01:00", { obj = "item", oid = "I-A-4", rev = 2, gone = true, track = "T-A-4" })
ev("11:01:10", { obj = "item", oid = "I-A-3", rev = 2, gone = true, track = "T-A-2" })
ev("11:01:20", { obj = "recv", oid = "R-A-2", rev = 2, track = "T-A-2", state = "AUXRECV T-A-1 0 0.8 0 0 0 0 0 0 -1:U 0 -1 ''\nAUXRECV T-A-3 0 1 0 0 0 0 0 0 -1:U 0 -1 ''\n" })
ev("11:01:30", { obj = "env", oid = "E-A-2", rev = 2, gone = true, track = "T-A-2" })
-- what this computer holds now (mirror.known's version ids): the unchanged ones' states must never be read
local held = { ["T-A-1"] = "e1", ["I-A-1"] = "e2", ["T-A-2"] = "e3", ["F-A-2"] = "e13", ["I-A-2"] = "e14", ["T-A-3"] = "e11", ["I-A-6"] = "e12", ["I-A-5"] = "e15", ["R-A-2"] = "e19" }
for _, e in ipairs(entries) do
  if held[e.oid] == e.id and (e.oid == "T-A-1" or e.oid == "I-A-1" or e.oid == "T-A-2") then
    local st = e.state
    e.state = nil
    setmetatable(e, { __index = function(_, k) if k == "state" then error("an object already at that version isn't read: " .. e.oid) end end })
    e.st_ = st
  end
end

-- the project now, as REAPER saves its copy
local NOW_RPP = table.concat({
  '<REAPER_PROJECT 0.1 "7.84/win64" 1',
  '  TEMPO 120 4 4',
  '  <MASTERFXLIST',
  '    BYPASS 0 0 0',
  '  >',
  '  <TRACK {G-DRUMS}',
  '    NAME Drums',
  '    <EXT',
  '      band_oid T-A-1',
  '    >',
  '    <ITEM',
  '      POSITION 0',
  '      LENGTH 2',
  '      <EXT',
  '        band_oid I-A-1',
  '      >',
  '      <SOURCE WAVE',
  '        FILE "J:/S/rooms/main/media/kick.wav"',
  '      >',
  '    >',
  '    <ITEM',
  '      POSITION 10',
  '      LENGTH 2',
  '      <EXT',
  '        band_oid I-A-2',
  '      >',
  '      <SOURCE MIDI',
  '        HASDATA 1 960 QN',
  '        E 0 90 3c 60',
  '        <X 0 0',
  '          8AA=',
  '        >',
  '      >',
  '    >',
  '  >',
  '  <TRACK {G-CLICK}',
  '    NAME Click',
  '    <EXT',
  '      band_local click',
  '    >',
  '  >',
  '  <TRACK {G-BASS}',
  '    NAME Bass',
  '    <EXT',
  '      band_oid T-A-2',
  '    >',
  '    AUXRECV 0 0 0.8 0 0 0 0 0 0 -1:U 0 -1 \'\'',
  '    AUXRECV 3 0 1 0 0 0 0 0 0 -1:U 0 -1 \'\'',
  '    <AUXVOLENV',
  '      ACT 1 -1',
  '    >',
  '    ' .. FX2:gsub("\n$", ""):gsub("\n", "\n    "),
  '    <ITEM',
  '      POSITION 6',
  '      LENGTH 2',
  '      <EXT',
  '        band_oid I-A-5',
  '      >',
  '    >',
  '  >',
  '  <TRACK {G-KEYS}',
  '    NAME Keys',
  '    <EXT',
  '      band_oid T-A-3',
  '    >',
  '    AUXRECV 1 0 1 0 0 0 0 0 0 -1:U 0 -1 \'\'',
  '    <ITEM',
  '      POSITION 1',
  '      LENGTH 2',
  '      <EXT',
  '        band_oid I-A-6',
  '      >',
  '    >',
  '  >',
  '  <EXTSTATE',
  '    <BANDSYNC.MIRROR',
  '      T-A-1 1|abc|e1|',
  '    >',
  '    <OTHER',
  '      K V',
  '    >',
  '  >',
  '>',
  '' }, "\n")

-- A rebuilt project, read back: tracks in order { guid, oid, lines }, items by oid { track, pos, file, lines }.
local function read_back(text)
  local L = {}
  for l in text:gmatch("[^\n]+") do L[#L + 1] = l:match("^%s*(.-)%s*$") end
  local tracks, items, cur, it, depth = {}, {}, nil, nil, 0
  for _, s in ipairs(L) do
    if depth == 1 and s:match("^<TRACK") then cur = { guid = s:match("(%b{})"), lines = {} }; tracks[#tracks + 1] = cur end
    if depth == 2 and cur and s == "<ITEM" then it = { track = cur, lines = {} } end
    if cur then cur.lines[#cur.lines + 1] = s end
    if it then
      it.lines[#it.lines + 1] = s
      it.pos = it.pos or tonumber(s:match("^POSITION (%S+)"))
      it.file = it.file or s:match('^FILE "(.-)"')
      local o = s:match("^band_oid (I%S+)")
      if o and not it.oid then it.oid = o; items[o] = it end
    elseif cur and depth == 3 then
      local o = s:match("^band_oid (T%S+)")
      if o then cur.oid = o end
    end
    if s:sub(1, 1) == "<" then depth = depth + 1 elseif s == ">" then depth = depth - 1 end
    if depth == 2 and it and s == ">" then it = nil end
    if depth == 1 and s == ">" then cur = nil end
  end
  return tracks, items, L
end

-- ---- 1. the copy as it was at the point -----------------------------------------------------------------------------------------------
local upto = hh.upto(entries, POINT)
assert(upto == 10 and hh.upto(entries, POINT - 1) == 9 and hh.upto(entries, 0) == 0 and hh.upto(entries, POINT + 1e6) == #entries, "the point: the last change at or before it")
local plan = mirror.plan_restore(entries, upto)
assert(plan["T-A-3"] == false and plan["I-A-6"] == false and plan["I-A-5"] == false and plan["T-A-4"].id == "e6", "the plan: what came since goes, what went comes back")
local exists = { ["J:/S/rooms/main/media/vox.wav"] = true, ["J:/S/rooms/main/media/voxp.wav"] = true, ["J:/S/rooms/main/media/vox2.wav"] = true, ["J:/S/rooms/main/media/snare.wav"] = true }
local out, info = hh.rebuild(NOW_RPP, plan, { media = "J:/S/rooms/main/media", now = held, exists = function(p) return exists[p] end,
  guid = function() return "{new-vox}" end })
local tracks, items, L = read_back(out)
local order = {}
for _, t in ipairs(tracks) do order[#order + 1] = t.oid or ("?" .. tostring(t.guid)) end
assert(table.concat(order, ",") == "T-A-1,T-A-2,T-A-4", "tracks then: Drums, Bass, Vox back under Bass; Keys (made since) and the click (this computer's) out: " .. table.concat(order, ","))
assert(tracks[3].guid == "{NEW-VOX}" and tracks[1].guid == "{G-DRUMS}", "the track back gets a new GUID, the others keep theirs")
assert(items["I-A-1"] and items["I-A-1"].file == "J:/S/rooms/main/media/kick.wav", "an item unchanged since stays as it is (its state never read)")
assert(items["I-A-2"].pos == 4 and items["I-A-2"].track.oid == "T-A-1" and items["I-A-2"].file == "J:/S/rooms/main/media/snare.wav", "a moved item where it was then, its media on this computer")
assert(items["I-A-3"].pos == 2 and items["I-A-3"].track.oid == "T-A-2", "an item deleted since: back")
assert(items["I-A-4"] and items["I-A-4"].track.oid == "T-A-4" and items["I-A-4"].pos == 8, "a deleted track's item: back on it")
assert(not items["I-A-5"] and not items["I-A-6"], "items made since: gone")
for _, it in pairs(items) do for _, l in ipairs(it.lines) do assert(not l:find("^BANDLANE") and not l:find("^BANDTAKE"), "StudioSync's own item lines stay out") end end
local bass = table.concat(tracks[2].lines, "\n")
assert(bass:find("utility/volume", 1, true) and not bass:find("ReaComp", 1, true), "Bass's plug-ins as they were")
assert(bass:find("<VOLENV2", 1, true) and bass:find("PT 4 0.5 0", 1, true), "Bass's automation, gone since, back")
local recvs = {}
for l in bass:gmatch("[^\n]+") do if l:find("^AUXRECV") then recvs[#recvs + 1] = l end end
assert(#recvs == 1 and recvs[1]:find("^AUXRECV 0 0 0%.8"), "Bass's sends as they were: from Drums (track 0); the one from Keys gone: " .. table.concat(recvs, " | "))
assert(not bass:find("AUXVOLENV", 1, true), "the gone send's envelope goes with it")
assert(not out:find("BANDSYNC.MIRROR", 1, true) and out:find("<OTHER", 1, true), "StudioSync's own project state goes, other extensions' stays")
assert(out:find("<MASTERFXLIST", 1, true) and L[#L] == ">" and L[1]:find("^<REAPER_PROJECT"), "the rest of the project as it is")
local depth = 0
for _, s in ipairs(L) do if s:sub(1, 1) == "<" then depth = depth + 1 elseif s == ">" then depth = depth - 1 end; assert(depth >= 0, "balanced") end
assert(depth == 0, "every block closed")
assert(info.tracks["T-A-4"] and info.tracks["T-A-4"].vol == "0.700000" and not info.tracks["T-A-1"], "the prep sets the settings of tracks that changed, by the band's id")
assert(info.items["I-A-4"].lane == 1 and info.items["I-A-4"].pick == 1 and info.items["I-A-4"].track == "T-A-4", "its lane and picked take for the prep")
assert(table.concat(tracks[3].lines, "\n"):find("\nTRACKID {NEW-VOX}\n", 1, true), "the track back says its GUID in a TRACKID line (REAPER makes a new one without it)")
assert(#info.missing == 1 and info.missing[1]:find("bass.wav", 1, true), "media not on this computer said (it plays silent)")
assert(info.len == 10 and info.locals == 1, "the song's length then (Vox's item ends at 10); one local track left out")

-- what sat on a track deleted before the point went with it (a track's deletion sends nothing for its items): not brought back, not counted
do
  local es, k = {}, 0
  local function e(time, x) k = k + 1; x.time, x.id, x.kind, x.user = "2026-11-12T" .. time .. "Z", "s" .. k, "obj", "Bo"; es[#es + 1] = x end
  e("09:00:00", { obj = "track", oid = "T-B-1", rev = 1, name = "Old take 1", state = track("Old take 1", "") })
  e("09:00:10", { obj = "item", oid = "I-B-1", rev = 1, track = "T-B-1", state = item("I-B-1", 0, "a.wav") })
  e("09:00:20", { obj = "fx", oid = "F-B-1", rev = 1, track = "T-B-1", state = FX1 })
  e("09:01:00", { obj = "track", oid = "T-B-1", rev = 2, gone = true, name = "Old take 1" }) -- (its item and plug-ins: no change of their own)
  e("09:02:00", { obj = "track", oid = "T-B-2", rev = 1, name = "Take 2", state = track("Take 2", "") })
  e("09:02:10", { obj = "item", oid = "I-B-2", rev = 1, track = "T-B-2", state = item("I-B-2", 0, "b.wav") })
  e("09:03:00", { obj = "item", oid = "I-B-9", rev = 1, track = "T-GONE-9", state = item("I-B-9", 0, "c.wav") }) -- (on a track History has nothing of, not here)
  local raw = mirror.plan_restore(es, #es)
  assert(raw["T-B-1"] == false and raw["I-B-1"] and raw["F-B-1"], "mirror's plan still names the deleted track's item and plug-ins")
  local pl = hh.settle(raw, function(oid) return false end)
  assert(pl["T-B-1"] == false and pl["I-B-1"] == false and pl["F-B-1"] == nil, "settled: the item went with its track, its plug-ins are left out")
  assert(pl["T-B-2"] and pl["I-B-2"] and pl["I-B-9"] == nil, "what was there stays in; an item on a track neither here nor coming back is left out")
  assert(hh.settle(raw)["I-B-9"], "(with nothing known of what's here, it's kept)")
  local words, cnt = hh.describe(pl, function() return "", nil end, function(oid) return oid == "T-B-2" and "Take 2" or nil end)
  assert(cnt == 2 and words:find("Brings back 1 track and 1 item.", 1, true), "the words count what the preview holds: " .. words)
  local txt = hh.rebuild('<REAPER_PROJECT 0.1 "7.86/win64" 1\n>\n', pl, { media = "J:/S/rooms/main/media", guid = function() return "{take-2}" end })
  local tr, its = read_back(txt)
  assert(#tr == 1 and tr[1].oid == "T-B-2" and its["I-B-2"] and not its["I-B-1"] and not its["I-B-9"], "and the preview holds exactly that")
end

-- the same moment for "now" (an empty plan): only this computer's tracks out, sends renumbered
local out2 = hh.rebuild(NOW_RPP, {}, {})
local t2 = read_back(out2)
assert(#t2 == 3 and t2[3].oid == "T-A-3", "now: Drums, Bass, Keys")
local b2 = table.concat(t2[2].lines, "\n")
assert(b2:find("AUXRECV 0 0 0.8", 1, true) and b2:find("AUXRECV 2 0 1", 1, true) and b2:find("AUXVOLENV", 1, true), "sends renumbered past the click (3 -> 2), envelope kept")
assert(not table.concat(t2[3].lines, "\n"):find("AUXRECV", 1, true), "a send from the click (this computer's) goes")
-- the master's plug-ins as they were
local mplan = { ["F-MASTER"] = { id = "m1", obj = "fx", track = "T-MASTER", state = "<FXCHAIN\nBYPASS 0 0 0\n<JS \"loudness\" \"\"\n>\n>\n" } }
local out3 = hh.rebuild(NOW_RPP, mplan, {})
assert(out3:find('<MASTERFXLIST\n%s*BYPASS 0 0 0\n%s*<JS "loudness"') or out3:find('<MASTERFXLIST\nBYPASS 0 0 0\n<JS "loudness"', 1, true), "the master's chain then")

-- ---- 2. the prep in the background REAPER ----------------------------------------------------------------------------------------------
local prep = hh.prep(info)
assert(load(prep), "prep compiles")
assert(not prep:find("GetTrackGUID", 1, true), "tracks are found by the band's id, never by GUID")
-- The job as REAPER loads it (7.86, measured on the desktop, 0.59.49.73): a track's GUID is its TRACKID line's, and one without that line
-- gets a new GUID whatever its "<TRACK {...}" says; P_EXT (its <EXT> block, an item's <EXT>/<EXTI>) is kept.
local made = 0
local function load_as_reaper(text)
  local tr, its = read_back(text)
  local P = { tracks = {}, items = {}, log = {} }
  for _, t in ipairs(tr) do
    local id, depth = nil, 0
    for _, l in ipairs(t.lines) do
      if depth == 1 then id = id or l:match("^TRACKID (%b{})") end
      if l:sub(1, 1) == "<" then depth = depth + 1 elseif l == ">" then depth = depth - 1 end
    end
    if not id then made = made + 1; id = "{REAPER-MADE-" .. made .. "}" end
    P.tracks[#P.tracks + 1] = { guid = id, oid = t.oid or "", v = {} }
  end
  for oid, it in pairs(its) do
    local takes = { {} }
    for _, l in ipairs(it.lines) do
      if l == "TAKE" or l:find("^TAKE ") then takes[#takes + 1] = {} end
      if l:find("^band_m_print") then takes[#takes].print = true end
    end
    P.items[#P.items + 1] = { oid = oid, takes = takes, v = {} }
  end
  table.sort(P.items, function(x, y) return x.oid < y.oid end)
  return P
end
local was = reaper
local function run_prep(P)
  local set = {}
  reaper = {
    GetSetProjectInfo_String = function(_, k, v) set[k] = v end, GetSetProjectInfo = function(_, k, v) set[k] = v end,
    CountTracks = function() return #P.tracks end, GetTrack = function(_, i) return P.tracks[i + 1] end,
    GetTrackGUID = function(t) return t.guid end,
    GetSetMediaTrackInfo_String = function(t, k, v, write) if write then t.v[k] = v; return true, v end return true, k == "P_EXT:band_oid" and t.oid or "" end,
    SetMediaTrackInfo_Value = function(t, k, v) t.v[k] = v; P.log[#P.log + 1] = k end,
    CountMediaItems = function() return #P.items end, GetMediaItem = function(_, i) return P.items[i + 1] end,
    GetSetMediaItemInfo_String = function(it) return true, it.oid end, SetMediaItemInfo_Value = function(it, k, v) it.v[k] = v; P.log[#P.log + 1] = k end,
    CountTakes = function(it) return #it.takes end, GetTake = function(it, k) return it.takes[k + 1] end,
    GetSetMediaItemTakeInfo_String = function(tk) return true, tk.print and "1" or "" end, UpdateTimeline = function() set.timeline = true end,
  }
  local ok, err = pcall(load(prep), {})
  reaper = was
  assert(ok, err)
  return set
end
for _, how in ipairs({ "as written", "its TRACKID lines taken out (the job as 0.59.49.73 wrote it)" }) do
  local P = load_as_reaper(how == "as written" and out or (out:gsub("TRACKID [^\n]*\n", "")))
  local set = run_prep(P)
  assert(set.RENDER_FORMAT == band.OPUS and set.RENDER_FORMAT2 == band.FLAC and set.RENDER_SETTINGS == 0 and set.RENDER_BOUNDSFLAG == 1 and set.RENDER_PATTERN == "preview", "the render: the master mix of the whole song, Opus with a FLAC beside it")
  local vox = P.tracks[3]
  assert(vox.oid == "T-A-4" and (vox.guid == "{NEW-VOX}") == (how == "as written"), how .. ": the restored track loads under " .. vox.guid)
  vox = vox.v
  assert(vox.P_NAME == "Vox" and vox.D_VOL == 0.7 and vox.D_PAN == -0.25 and vox.I_FREEMODE == 2 and vox.I_NUMFIXEDLANES == 2 and vox["C_LANEPLAYS:0"] == 1 and vox["C_LANEPLAYS:1"] == 0,
    how .. ": the track back gets its name, settings and which lanes play, whatever GUID it loaded under")
  assert(next(P.tracks[1].v) == nil and next(P.tracks[2].v) == nil, "tracks that didn't change aren't touched")
  local by = {}
  for _, it in ipairs(P.items) do by[it.oid] = it end
  assert(by["I-A-4"].v.I_FIXEDLANE == 1 and by["I-A-4"].v.I_CURTAKE == 2, "its lane, and its picked take counted past the print")
  assert(next(by["I-A-1"].v) == nil and set.timeline, "an item with nothing to set isn't touched")
  local lane_at, plays_at
  for i, k in ipairs(P.log) do if k == "I_FIXEDLANE" then lane_at = i end; if k:find("^C_LANEPLAYS") then plays_at = plays_at or i end end
  assert(lane_at and plays_at and plays_at > lane_at, "which lanes play is set once the items are on their lanes")
end
-- values go in as literals, never as code
local evil = hh.prep({ tracks = { ["T-X"] = { name = 'a"]] os.exit() --\n' } }, items = {} })
assert(load(evil), "a strange name still compiles")
local seen
reaper = setmetatable({ CountTracks = function() return 1 end, GetTrack = function() return {} end,
  GetSetMediaTrackInfo_String = function(_, _, v, write) if write then seen = v end return true, "t-x" end, CountMediaItems = function() return 0 end },
  { __index = function() return function() end end })
load(evil)({})
reaper = was
assert(seen == 'a"]] os.exit() --\n', "the name arrives as the name")
-- the background REAPER's pass script runs it before its first render
local bgsrc = (function() local f = assert(io.open("lib/bgrender.lua", "rb")); local s = f:read("a"); f:close(); return s end)()
assert(bgsrc:find('loadfile(dir .. "/prep.lua")', 1, true) and bgsrc:find("if not prepped then", 1, true), "bgrender's pass script runs a job's prep.lua first")

-- ---- 3. a render's life, with a stand-in bgrender and disk ---------------------------------------------------------------------------
local TMP = "C:/T/bandsync-render"
local launched, ended = {}, {}
package.loaded.bgrender = { TMP = TMP, time_limit = function(secs) return 180 + secs * 4 end,
  launch_job = function(dir, limit) launched[#launched + 1] = { dir = dir, limit = limit }; if not NO_PID then vfs[dir .. "/pid.txt"] = "4321" end end,
  end_job = function(dir) if not tonumber((vfs[dir .. "/pid.txt"] or ""):match("^%d+")) then return false end ended[#ended + 1] = dir; return true end }
package.loaded.recall = { entries = function() return entries end }
package.loaded.dawview = { shown = function() return true end }
package.loaded.sync = { room_dir = function() return "J:/S/rooms/main" end, authority = function() return function() return true end, { driver = "James", mode = "claims" } end,
  id_user = function(u) return u end, restore_timeline = function() package.loaded.sync.timeline = (package.loaded.sync.timeline or 0) + 1 end }
local function children(dir, want_dirs)
  local set, pre = {}, dir .. "/"
  for p in pairs(vfs) do
    if p:sub(1, #pre) == pre then
      local rest = p:sub(#pre + 1)
      local first, more = rest:match("^([^/]+)(/?)")
      if first and ((more == "/") == want_dirs) then set[first] = true end
    end
  end
  local out = {}
  for k in pairs(set) do out[#out + 1] = k end
  table.sort(out)
  return out
end
api.EnumerateFiles = function(dir, i) return children(dir, false)[i + 1] end
band.files = function(dir, ext) local o = {}; for _, f in ipairs(children(dir, false)) do if not ext or f:sub(-#ext) == ext then o[#o + 1] = f end end; return o end
band.subdirs = function(dir) return children(dir, true) end
band.read = function(p) return vfs[p] end
band.write_atomic = function(p, d) vfs[p] = d end
band.copy_atomic = function(a, z) vfs[z] = assert(vfs[a]) end
band.session_path = function() return "J:/S/session.json" end
band.log = function() end
local saved_with = {}
api.Main_SaveProjectEx = function(_, path, opt) saved_with[#saved_with + 1] = opt; vfs[path] = NOW_RPP end
local offers = {}
api.StudioSync_WebUIOffer = function(id, path) offers[id] = path ~= "" and path or nil; return 1 end
local real_os_remove, real_os_rename = os.remove, os.rename
os.remove = function(p) if vfs[p] ~= nil then vfs[p] = nil; return true end return nil end
os.rename = function(a, z) if vfs[a] == nil then return nil end vfs[z], vfs[a] = vfs[a], nil; return true end
local got = {}
local function publish(k, v) got[k] = v end
local proj, cfg, b = {}, { root = "J:/S", user = "James" }, { song = "Song", room = "main" }
local function tick(dt) now = now + (dt or 1); wh.tick(proj, cfg, b, publish, now) end
api.GetProjExtState = function(_, _, key) local v = held[key]; if v then return 1, "1|h|" .. v .. "|" end return 0, "" end
calls = {}

wh.action(proj, cfg, b, { topic = "history", hear = { t = POINT } })
tick()
assert(#launched == 1 and got.hhear["then"].state == "rendering" and got.hhear["then"].passes == 2, "Listen: the copy's job starts in the background")
local job = launched[1].dir
assert(job:sub(1, #TMP + 6) == TMP .. "/hear-" and vfs[job .. "/job.rpp"] and vfs[job .. "/prep.lua"] and vfs[job .. "/maxpasses.txt"] == "2", "its job folder: the rebuilt copy, the prep, two passes at most")
assert(not vfs[job .. "/copy.rpp"], "the saved copy itself doesn't stay")
local rt = read_back(vfs[job .. "/job.rpp"])
assert(#rt == 3 and rt[3].oid == "T-A-4", "the job renders the song as it was")
assert(saved_with[1] == 0, "saved as a copy: the open project isn't renamed (Main_SaveProjectEx options 0)")
assert(launched[1].limit == 180 + 10 * 2 * 4 + 180, "its time limit by the song's length then: " .. launched[1].limit)
vfs[job .. "/pass1/preview.flac"] = "x"
tick()
assert(got.hhear["then"].pass == 1 and got.hhear["then"].secs == 1, "progress: which pass, how long")
wh.action(proj, cfg, b, { topic = "history", hear = { now = true } })
tick(); tick()
assert(#launched == 1 and got.hhear.now.state == "queued", "one render at a time: now waits for then")
vfs[job .. "/pass1/preview.flac"] = nil
vfs[job .. "/preview.opus"], vfs[job .. "/preview.flac"], vfs[job .. "/passes.txt"] = "OPUS-THEN", "F", "2\n"
tick()
local th = got.hhear["then"]
assert(th.state == "ready" and th.file and #th.file == 32 and th.file:match("^%x+$"), "done: offered to the page by a 32-hex id")
local cache = offers[th.file]
assert(cache and vfs[cache] == "OPUS-THEN" and cache:find("/bandsync%-hear/") and not cache:find("bandsync-render", 1, true), "kept in this computer's own preview folder (not bgrender's, which it tidies)")
assert(not vfs[job .. "/job.rpp"] and not vfs[job .. "/preview.flac"] and ended[#ended] == job, "its job folder tidied, its REAPER told to end")
-- (that REAPER takes a moment to go: it saves its job.rpp again, and its launcher writes done.txt after it. Swept, not left for hours)
vfs[job .. "/job.rpp"], vfs[job .. "/job.rpp-bak"], vfs[job .. "/done.txt"] = "saved again", "bak", "1"
local n_ended = #ended
tick(); tick()
assert(#children(job, false) == 0 and #ended == n_ended, "what its REAPER wrote as it went is swept too, and nothing is ended twice")
tick(1)
assert(#launched == 2 and got.hhear.now.state == "rendering", "then the A/B's now")
assert(launched[2].dir ~= launched[1].dir, "a folder of its own for each start")
local job2 = launched[2].dir
assert(#read_back(vfs[job2 .. "/job.rpp"]) == 3 and read_back(vfs[job2 .. "/job.rpp"])[3].oid == "T-A-3", "now: the project as it is")
vfs[job2 .. "/preview.opus"], vfs[job2 .. "/passes.txt"] = "OPUS-NOW", "2\n"
tick()
assert(got.hhear.now.state == "ready" and vfs[offers[got.hhear.now.file]] == "OPUS-NOW" and offers[th.file], "both offered at once, for A/B")
-- the same point again: from the cache, nothing rendered
local nl = #launched
hh.S.slots["then"] = nil
wh.action(proj, cfg, b, { topic = "history", hear = { t = POINT + 5 } }) -- (a moment later, no change between: the same point)
tick(5)
assert(#launched == nl and got.hhear["then"].state == "ready" and got.hhear["then"].cached, "the same point again: straight from the kept preview")
-- before History: said, nothing started
wh.action(proj, cfg, b, { topic = "history", hear = { t = 1000 } })
tick(5)
assert(#launched == nl and got.hhear["then"].state == "failed" and got.hhear["then"].why:find("before anything", 1, true), "a point before History")
wh.action(proj, cfg, b, { topic = "history", hear = { t = "x" } })
wh.action(proj, cfg, b, { topic = "history", hear = { t = -5 } })
-- cancel
wh.action(proj, cfg, b, { topic = "history", hear = { t = wh.epoch("2026-11-10T10:00:45Z") } })
tick(5)
assert(#launched == nl + 1, "another point starts")
local job3 = launched[#launched].dir
wh.action(proj, cfg, b, { topic = "history", cancel = true })
tick()
assert(got.hhear["then"].state == "cancelled" and ended[#ended] == job3 and not vfs[job3 .. "/job.rpp"], "Cancel: its REAPER ended, its folder tidied")
vfs[job3 .. "/pass1/preview.opus"], vfs[job3 .. "/preview.flac"] = "late", "late" -- (a pass it was in the middle of)
tick(2)
assert(#children(job3, false) == 0 and #children(job3, true) == 0, "a cancelled job's files written after the tidy are swept")
-- cancelled before its process id was written: ended as soon as it is, never left rendering unseen
NO_PID = true
wh.action(proj, cfg, b, { topic = "history", hear = { t = wh.epoch("2026-11-10T10:00:42Z") } })
tick(5)
NO_PID = nil
local job3b = launched[#launched].dir
n_ended = #ended
wh.action(proj, cfg, b, { topic = "history", cancel = true })
tick()
assert(#ended == n_ended and vfs[job3b .. "/job.rpp"], "no process id yet: its folder waits")
vfs[job3b .. "/pid.txt"] = "777"
tick(2)
assert(ended[#ended] == job3b and not vfs[job3b .. "/job.rpp"] and not vfs[job3b .. "/pid.txt"], "its id written: ended, and its folder goes")
-- a new point while one renders replaces it
wh.action(proj, cfg, b, { topic = "history", hear = { t = wh.epoch("2026-11-10T10:00:15Z") } })
tick(5)
local job4 = launched[#launched].dir
wh.action(proj, cfg, b, { topic = "history", hear = { t = wh.epoch("2026-11-10T10:00:25Z") } })
assert(ended[#ended] == job4 and not vfs[job4 .. "/job.rpp"], "a new point ends the render going")
tick(5)
local job5 = launched[#launched].dir
-- failures: didn't start, quit without a print, stuck past its limit
vfs[job5 .. "/pid.txt"] = "failed"
tick()
assert(got.hhear["then"].state == "failed" and got.hhear["then"].why:find("didn't start", 1, true), "the background REAPER didn't start")
wh.action(proj, cfg, b, { topic = "history", hear = { t = wh.epoch("2026-11-10T10:00:35Z") } })
tick(5)
local job6 = launched[#launched].dir
vfs[job6 .. "/done.txt"] = "1"
tick()
assert(got.hhear["then"].state == "failed" and got.hhear["then"].why:find("quit without", 1, true), "it quit without a print")
assert(ended[#ended] ~= job6 and not vfs[job6 .. "/done.txt"], "a REAPER that has gone by itself isn't ended (its id may be something else's by now); its folder goes")
wh.action(proj, cfg, b, { topic = "history", hear = { t = wh.epoch("2026-11-10T10:00:55Z") } })
tick(5)
local job7 = launched[#launched].dir
tick(1000)
assert(got.hhear["then"].state == "failed" and got.hhear["then"].why:find("too long", 1, true) and ended[#ended] == job7, "stuck past its limit: ended")
-- recording: waits
PLAY = 5
wh.action(proj, cfg, b, { topic = "history", hear = { t = wh.epoch("2026-11-10T10:01:05Z") } })
local before = #launched
tick(5)
assert(#launched == before and got.hhear["then"].state == "queued" and got.hhear["then"].why:find("recording", 1, true), "never saved while recording")
PLAY = 0
tick(5)
assert(#launched == before + 1, "and starts once it stops")
tick(70); tick(3)
assert(next(hh.S.trash) == nil, "folders done with are forgotten after a minute of sweeping")
-- kept: KEEP newest
local idx = band.read_json(cache:match("^(.*)/") .. "/index.json")
assert(type(idx) == "table" and #idx == 2, "the kept previews listed")
-- nothing in the open project touched while previewing
for k in pairs(calls) do
  assert(not (k:find("^Set") or k:find("^Delete") or k:find("^Insert") or k:find("^Add") or k:find("^Undo") or k:find("^Main_On") or k:find("^Mark") or k:find("^Split") or k:find("^Move")),
    "previewing touched the project: " .. k)
end
assert(calls.Main_SaveProjectEx == #launched, "only ever saved as a copy, once a render: " .. tostring(calls.Main_SaveProjectEx))

-- ---- 4. restore: ask, then one act ---------------------------------------------------------------------------------------------------
local reverted
package.loaded.mirror.revert = function(p, c, song, room, pl, opts) reverted = { plan = pl, opts = opts }; return "3 change(s) brought back and sent to the others" end
api.GetProjExtState = function(_, _, key) local v = held[key]; if v then return 1, "1|h|" .. v .. "|" end return 0, "" end
api.CountTracks = function() return 2 end
api.GetTrack = function(_, i) return { i = i } end
api.GetTrackName = function(t) return true, t.i == 0 and "Drums" or "Bass" end
package.loaded.mirror.track_oid = function(t) return t.i == 0 and "T-A-1" or "T-A-2" end
package.loaded.mirror.local_track = function() return false end
hh.S.tracks_at = nil
wh.looking = function() return true end -- (History shown: the track list and who drives are read)
tick()
assert(got.hhear.driver and #got.hhear.tracks == 2 and got.hhear.tracks[2][1] == "T-A-2" and got.hhear.tracks[2][2] == "Bass", "the page gets the tracks to choose from, and that you drive")
wh.action(proj, cfg, b, { topic = "history", restore = { t = POINT } })
tick()
local ask = got.hhear.ask
assert(ask and ask.whole and ask.id and #ask.id == 16 and not reverted, "Restore first says what it would change; nothing done yet")
assert(ask.words:find("Brings back 1 track and 2 items", 1, true) and ask.words:find("takes away 1 track and 2 items", 1, true) and ask.words:find("Vox", 1, true)
  and ask.words:find("Undo", 1, true), "in words: " .. ask.words)
wh.action(proj, cfg, b, { topic = "history", restore = { id = "wrong", yes = true } })
assert(not reverted and got.hhear.ask, "a yes for another ask does nothing")
wh.action(proj, cfg, b, { topic = "history", restore = { id = ask.id, yes = true } })
assert(reverted and reverted.opts.at_once == true and type(reverted.opts.act) == "string" and reverted.opts.act:find("^James%-") and package.loaded.sync.timeline == 1,
  "yes: the whole song back as one act, one undo point, the tempo map too")
assert(reverted.plan["T-A-3"] == false and reverted.plan["T-A-4"].id == "e6", "the plan as the Restore page makes it")
tick()
assert(not got.hhear.ask and got.hhear.said:find("brought back", 1, true), "said what happened")
reverted = nil
wh.action(proj, cfg, b, { topic = "history", restore = { id = ask.id, yes = true } })
assert(not reverted, "a yes can't be used twice")
-- chosen tracks
wh.action(proj, cfg, b, { topic = "history", restore = { t = POINT, tracks = { "T-A-2" } } })
tick()
local ask2 = got.hhear.ask
assert(ask2 and not ask2.whole and not ask2.words:find("Vox", 1, true) and ask2.words:find("Bass", 1, true), "chosen tracks: only theirs: " .. ask2.words)
now = now + hh.ASK_FOR + 1
wh.action(proj, cfg, b, { topic = "history", restore = { id = ask2.id, yes = true } })
assert(not reverted, "an ask runs out")
wh.action(proj, cfg, b, { topic = "history", restore = { t = POINT, tracks = { "T-A-2" } } })
wh.action(proj, cfg, b, { topic = "history", restore = { id = hh.S.ask.id, yes = true } })
assert(reverted and reverted.plan["F-A-2"] and reverted.plan["I-A-3"] and reverted.plan["T-A-4"] == nil and reverted.plan["I-A-2"] == nil and package.loaded.sync.timeline == 1,
  "Bass only: its plug-ins and items, nothing of Drums or Vox, and the tempo map left")
wh.action(proj, cfg, b, { topic = "history", restore = { t = POINT, tracks = { "../x" } } })
wh.action(proj, cfg, b, { topic = "history", restore = { t = POINT, tracks = {} } })
-- not the driver: the whole song is refused, chosen tracks are fine
package.loaded.sync.authority = function() return function() return true end, { driver = "Bo", mode = "claims" } end
reverted = nil
wh.action(proj, cfg, b, { topic = "history", restore = { t = POINT } })
assert(not hh.S.ask and hh.S.said:find("Only the driver", 1, true), "only the driver restores the whole song")
wh.action(proj, cfg, b, { topic = "history", restore = { t = POINT, tracks = { "T-A-2" } } })
assert(hh.S.ask, "chosen tracks: asked")

-- the restore's events are one act: Undo this change on any of them takes all of it back, to how it was before
local acts = {}
for _, e in ipairs(entries) do acts[#acts + 1] = e end
local base = #acts
local function rev_of(oid) local r = 0; for _, e in ipairs(acts) do if e.oid == oid then r = math.max(r, e.rev or 0) end end; return r end
for _, x in ipairs({ { "T-A-4", "track" }, { "I-A-4", "item" }, { "I-A-3", "item" }, { "F-A-2", "fx" } }) do
  acts[#acts + 1] = { kind = "obj", type = "obj", obj = x[2], oid = x[1], rev = rev_of(x[1]) + 1, time = "2026-11-10T12:00:0" .. (#acts - base) .. "Z", id = "r" .. (#acts - base),
    user = "James", restored = "e?", act = "James-20261110120000-r1", track = x[2] == "item" and "T-A-2" or nil }
end
local moment = mirror.same_moment(acts, base + 2)
assert(#moment == 4, "one act in History, across seconds and kinds: " .. #moment)
local undo = mirror.plan_undo_moment(acts, base + 1)
assert(undo["T-A-4"] == false and undo["I-A-4"] == false and undo["I-A-3"] == false and undo["F-A-2"].id == "e13", "Undo takes the whole restore back to how it was before it")
local msrc = (function() local f = assert(io.open("lib/mirror.lua", "rb")); local s = f:read("a"); f:close(); return s end)()
local _, nact = msrc:gsub("act = opts%.act", "")
assert(nact == 3, "mirror.revert marks every event it sends with the act: " .. nact)

-- ---- 5. the page's wiring --------------------------------------------------------------------------------------------------------------
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end
local html, js = read("lib/webui/index.html"), read("lib/webui/histhear.js")
assert(html:find('src="histhear.js"', 1, true) and html:find("history.js", 1, true) < html:find("histhear.js", 1, true), "index.html loads the panel after the History page")
assert(js:find("hear:", 1, true) and js:find("restore:", 1, true) and js:find("cancel:", 1, true) and js:find("topics.hhear", 1, true), "the panel's asks and topic")
assert(js:find("api/file?id=", 1, true) and not js:find("innerHTML", 1, true), "plays the offered file; names go in as text")
assert(js:find("confirm", 1, true) or js:find("Restore now", 1, true), "a restore asks first")

os.remove, os.rename = real_os_remove, real_os_rename
print("ok")
