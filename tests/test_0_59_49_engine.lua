-- 0.59.49 (Round 4 review, sync engine, data safety, security, code health): each block fails with its fix reverted. Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local exts, gext, clock = {}, {}, 1000
local function sec_of(p, sec) exts[p] = exts[p] or {}; exts[p][sec] = exts[p][sec] or {}; return exts[p][sec] end
local pext = {} -- object -> { P_EXT key -> value }
local function getset(o, k, v, set)
  pext[o] = pext[o] or {}
  if set then pext[o][k] = v end
  return true, pext[o][k] or ""
end
reaper = setmetatable({
  GetProjExtState = function(p, sec, k) local v = sec_of(p, sec)[k] or ""; return v ~= "" and 1 or 0, v end,
  SetProjExtState = function(p, sec, k, v) sec_of(p, sec)[k] = v end,
  EnumProjExtState = function() return false end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  DeleteExtState = function(s, k) gext[s .. "\0" .. k] = nil end,
  time_precise = function() return clock end,
  EnumProjects = function() return nil end,
  GetPlayStateEx = function() return 0 end,
  ValidatePtr = function() return true end,
  ValidatePtr2 = function() return true end,
  GetSetMediaItemInfo_String = getset,
  GetSetMediaTrackInfo_String = getset,
  GetSetMediaItemTakeInfo_String = getset,
  GetMediaItemInfo_Value = function() return 0 end,
  GetMediaTrackInfo_Value = function() return 0 end,
  CountTakes = function() return 1 end,
  CountTracks = function() return 0 end,
  CountMediaItems = function() return 0 end,
  CountTrackMediaItems = function() return 0 end,
  CountSelectedMediaItems = function() return 0 end,
  TrackFX_GetCount = function() return 0 end,
  IsMediaItemSelected = function() return false end,
  GetTrackName = function() return true, "Keys" end,
  file_exists = function() return true end,
}, { __index = function() return function() end end })

local files, written, logged = {}, {}, {}
local band = require("band")
local proxy = setmetatable({}, { __index = band })
proxy.read_json = function(path) local v = files[path]; if type(v) == "table" then local c = {}; for k, x in pairs(v) do c[k] = x end; return c end end
proxy.listing = function() return {} end
proxy.write_json = function(path, v) written[path] = v; files[path] = v end
proxy.write_atomic = function(path, v) files[path] = v end
proxy.log = function(t) logged[#logged + 1] = t end
proxy.home = function() return "H" end
proxy.capture_tempo, proxy.capture_markers = function() return {} end, function() return {} end
package.loaded.band = proxy
local mirror = require("mirror")
local sync = require("sync")
local prints = require("prints")
local real = { find = mirror.find, apply = mirror.apply, keep_item_copy = mirror.keep_item_copy, choose = prints.choose }
prints.choose = function() end
require("fxfiles").fetch = function() end
local cfg = { user = "Me", root = "root" }
local can = function() return true end
local PATH64 = "QzovVXNlcnMvdi9wcml2YXRlLndhdg==" -- (C:/Users/v/private.wav)
local function theirs_has(o) return ((pext[o] or {})[mirror.THEIRS] or ""):find("c:/users/v/private.wav", 1, true) ~= nil end

-- M3: sync.begin_loading publishes "loading <proj>" at once, and marks the tab as Live sync's in this script
sync.begin_loading("PB")
assert(sync.loading.PB and sync.live_in.PB and gext[band.SECTION .. "\0loading PB"] == "1", "loading, and published at the start")
sync.loading.PB = nil

-- M3: a save from a tab Live sync doesn't run in counts what's still to come (it receives nothing, so it may be days behind)
local recall = require("recall")
local dir = recall.dir(cfg, "S", "main")
sync.pending_events = function() return 3 end
local f1 = recall.save("PN", cfg, "S", "main", "before Dee joined", true)
assert(written[dir .. "/" .. f1].behind == true and not written[dir .. "/known/" .. f1], "no Live sync there and changes to come: behind, no map")
sync.live_in.PN = true -- (Live sync's own saves: waiting changes don't mark them, 0.59.48)
local f2 = recall.save("PN", cfg, "S", "main", "end of session", true)
assert(not written[dir .. "/" .. f2].behind and written[dir .. "/known/" .. f2], "Live sync's tab: mapped")
sync.live_in.PN = nil
sync.pending_events = function() return 0 end
local f3 = recall.save("PN", cfg, "S", "main", "caught up", true)
assert(written[dir .. "/known/" .. f3], "no Live sync but nothing to come: mapped")

-- sync L2: no undo block for a bandmate's change that alters nothing here (play together, a note on a part not here)
local edir = sync.room_dir(cfg, "S", "main") .. "/events"
local blocks = 0
reaper.Undo_BeginBlock2 = function() blocks = blocks + 1 end
local IT = { name = "IT" }
mirror.find = function(_, kind, oid) if kind == "item" and oid == "I-HERE" then return IT end end
local marked = 0
local real_mark = sync.mark_item
sync.mark_item = function() marked = marked + 1 end
local function arrive(proj, ev)
  ev.time, ev.user = ev.time or "2026-11-19T12:00:00Z", ev.user or "Bo"
  files[edir .. "/" .. ev.id .. ".json"] = ev
  proxy.listing = function(d) if d == edir then return { ev.id .. ".json" } end; return {} end
  sync.receive(proj, cfg, "S", "main", can)
end
arrive("PS1", { id = "Bo-20261119-120000Z-00001-0001", type = "start", pos = 1 })
arrive("PS2", { id = "Bo-20261119-120001Z-00002-0001", type = "note", item = "I-GONE", text = "nice" })
assert(blocks == 0, "a play together and a note on nothing here open no undo block (" .. blocks .. ")")
arrive("PS3", { id = "Bo-20261119-120002Z-00003-0001", type = "note", item = "I-HERE", text = "nice" })
assert(blocks == 1 and marked == 1, "a note on a part here does")
sync.mark_item = real_mark
proxy.listing = function() return {} end

-- sync L2: a chain within FX_SET_GAP of the band's last one on that track waits, known before a block opens
local TR = { name = "TR" }
mirror.find = function(_, kind, oid) if kind == "track" and oid ~= "T-D" then return TR end end
reaper.EnumProjects = function(i) if i == -1 then return "PG" end end
local fxev = { obj = "fx", oid = "F-G", track = "T-G" }
assert(not mirror.will_wait("PG", fxev), "stopped and in front: lands")
mirror.fx_set_at["PGF-G"] = clock
assert(mirror.will_wait("PG", fxev), "within 5 s of the band's last chain there: waits")
clock = clock + mirror.FX_SET_GAP + 1
assert(not mirror.will_wait("PG", fxev), "after the gap: lands")
-- sync L3: not "waits" for a change on a track the band deleted (receive drops it before its unsent check)
reaper.SetProjExtState("PG", mirror.SEC, "T-D", "3||Bo-9|1")
gext[band.SECTION .. "\0unsent PG"] = "I-D"
assert(mirror.will_wait("PG", { obj = "item", oid = "I-D", track = "T-G" }), "an unsent edit of yours waits")
assert(not mirror.will_wait("PG", { obj = "item", oid = "I-D", track = "T-D" }), "on a track deleted by the band: it doesn't")
reaper.EnumProjects = function() return nil end

-- code 1: item_states rereads a track holding a GUID twice, every look; perf A: a lane line that changes shows
local T1 = { name = "T1" }
local A1, A2 = { name = "A1" }, { name = "A2" }
local chunk_of = { [A1] = "<ITEM\nPOSITION 1\n>\n", [A2] = "<ITEM\nPOSITION 2\n>\n" }
local reads = 0
reaper.GetItemStateChunk = function(it) reads = reads + 1; return true, chunk_of[it] end
reaper.GetMediaItem_Track = function() return T1 end
local twice = { { ptr = A1, tr = T1, guid = "{same}" }, { ptr = A2, tr = T1, guid = "{same}" } }
local tch = { [T1] = "<TRACK\n" .. chunk_of[A1] .. chunk_of[A2] .. ">\n" }
mirror.item_states("PI", twice, tch, "R/media", {})
reads = 0
mirror.item_states("PI", twice, tch, "R/media", {})
assert(reads == 2, "a GUID twice on a track: its items are read again (" .. reads .. ")")
local lane = 0
reaper.GetMediaTrackInfo_Value = function(_, k) if k == "I_FREEMODE" then return 2 end; if k == "I_NUMFIXEDLANES" then return 4 end; return 0 end
reaper.GetMediaItemInfo_Value = function(_, k) if k == "I_FIXEDLANE" then return lane end; return 0 end
local one = { { ptr = A1, tr = T1, guid = "{a1}" } }
local tone = { [T1] = "<TRACK\n" .. chunk_of[A1] .. ">\n" }
local s1 = mirror.item_states("PL2", one, tone, "R/media", {})
local s2 = mirror.item_states("PL2", one, tone, "R/media", {})
lane = 2
local s3 = mirror.item_states("PL2", one, tone, "R/media", {})
assert(s1[1]:find("BANDLANE", 1, true) and s1[1] == s2[1] and s3[1] ~= s1[1] and s3[1]:find("BANDLANE", 1, true), "a lane change shows; none, the same state")
reaper.GetMediaTrackInfo_Value = function() return 0 end
reaper.GetMediaItemInfo_Value = function() return 0 end

-- data L2: a held-back item stays held until the band's version lands, and an edit made while it waits gets its own copy
local IH = { name = "IH" }
chunk_of[IH] = "<ITEM\nNOTES v1\n>\n"
mirror.find = function(_, kind, oid) if kind == "item" and oid == "I-H" then return IH end end
local copies = 0
mirror.keep_item_copy = function() copies = copies + 1; return {} end
mirror.apply = function() return false end -- (the part open in the MIDI editor: it waits)
mirror.held_back.PD = { ["I-H"] = true }
local hev = { obj = "item", oid = "I-H", rev = 3, id = "Bo-20261119-100000Z-00001-0001", state = "<ITEM\n>\n" }
assert(mirror.receive("PD", hev, "R/media", false, "Me") == false and copies == 1 and mirror.held_back.PD["I-H"], "copied, waits, still held back")
mirror.receive("PD", hev, "R/media", false, "Me")
assert(copies == 1, "unchanged: no second copy")
chunk_of[IH] = "<ITEM\nNOTES v2\n>\n" -- (edited while it waits)
mirror.receive("PD", hev, "R/media", false, "Me")
assert(copies == 2, "the edit made meanwhile is copied too (" .. copies .. ")")
mirror.apply = function() return true, "h" end
local real_lanes = mirror.lanes_back
assert(mirror.receive("PD", hev, "R/media", false, "Me") and copies == 2 and not mirror.held_back.PD["I-H"], "landed: no longer held back")
mirror.lanes_back = real_lanes

-- sec L2: a kept suggestion's take plug-in paths are recorded as theirs
local KI = { name = "KI" }
local real_add = mirror.add_local_track
mirror.add_local_track = function() return { name = "kept track" } end
reaper.AddMediaItemToTrack = function() return KI end
reaper.SetItemStateChunk = function(it, ch) chunk_of[it] = ch; return true end
mirror.keep_suggested("PK", { obj = "item", oid = "I-S", rev = 2, name = "Keys", state = table.concat({ "<ITEM", "<TAKEFX", '<VST "VSTi: RS5K" r.dll 0', PATH64, ">", ">", ">", "" }, "\n") }, "R")
assert(theirs_has(KI), "the take FX's file is theirs: " .. tostring((pext[KI] or {})[mirror.THEIRS]))

mirror.add_local_track = real_add

-- sec L3 + M4: a landed chain's theirs record comes from REAPER's read-back too, the master's included
local MT, stored = { name = "master" }, nil
mirror.apply = real.apply
mirror.find = function(_, kind, oid) if kind == "track" and oid == mirror.MASTER then return MT end end
reaper.EnumProjects = function(i) if i == -1 then return "PM" end end
reaper.GetTrackStateChunk = function() return true, stored or "<TRACK\n<FXCHAIN\n>\n>\n" end
reaper.SetTrackStateChunk = function(_, ch) stored = ch:gsub("QzovV\nXNlc\nnMvd\ni9wc\nml2Y\nXRlL\nndhd\ng==", PATH64) end -- (REAPER writes its own base64 lines)
local real_ai, real_setai, real_params = mirror.ai_lines, mirror.set_ai, mirror.fx_params
mirror.ai_lines, mirror.set_ai, mirror.fx_params = function() return "" end, function() end, function() return {} end
local short = "QzovV\nXNlc\nnMvd\ni9wc\nml2Y\nXRlL\nndhd\ng=="
assert(#require("fxfiles").paths(short) == 0, "(the event's own text hides the path)")
assert(mirror.apply("PM", { obj = "fx", oid = "F-MASTER", track = mirror.MASTER, rev = 1, state = '<FXCHAIN\n<VST "VSTi: RS5K" r.dll 0\n' .. short .. "\n>\n>\n" }, "R/media", false),
  "the master's chain lands")
assert(theirs_has(MT), "read back: the master's chain's file is theirs: " .. tostring((pext[MT] or {})[mirror.THEIRS]))
mirror.ai_lines, mirror.set_ai, mirror.fx_params = real_ai, real_setai, real_params
reaper.EnumProjects = function() return nil end

-- M4: a template's master chain is stripped whatever its indent, and opening one records the master's chain (and each track's) as theirs
local extras = require("extras")
local planted = table.concat({ "<REAPER_PROJECT 0.1", "  <MASTERFXLIST", '  <JS volume ""', "  >", '    <VST "VSTi: RS5K" r.dll 0', "      " .. PATH64, "    >", "  >",
  "  <TRACK", "    NAME Keys", "  >", ">" }, "\n")
local t = extras.template_text(planted)
assert(not t:find("MASTERFXLIST", 1, true) and not t:find(PATH64, 1, true) and t:find("NAME Keys", 1, true), "a nested block at the master's indent doesn't end it: " .. t)
local TT, MT2 = { name = "TT" }, { name = "MT2" }
files["root/_band/templates/Demo.rpp"] = planted
proxy.read = function(p) return files[p] end
reaper.EnumProjects = function(i) if i == -1 then return "PO" end end
reaper.CountTracks = function() return 1 end
reaper.GetTrack = function() return TT end
reaper.GetMasterTrack = function() return MT2 end
local tchunk = { [TT] = '<TRACK\n<FXCHAIN\n<VST "VST: ReaVerb" rv.dll 0\n' .. PATH64 .. "\n>\n>\n>\n", [MT2] = '<TRACK\n<FXCHAIN\n<VST "VSTi: RS5K" r.dll 0\n' .. PATH64 .. "\n>\n>\n>\n" }
reaper.GetTrackStateChunk = function(tr) return true, tchunk[tr] end
assert(extras.open_template(cfg, "Demo"), "opened")
assert(theirs_has(TT) and theirs_has(MT2), "the track's and the master's chains are theirs")
reaper.CountTracks, reaper.EnumProjects = function() return 0 end, function() return nil end

-- code 1: merge_for treats a leaf too new for this version as missing
local real_m = { apart = mirror.apart, event_file = mirror.event_file, descends = mirror.descends, old = mirror.too_old_to_merge }
local held = { id = "Me-20261119-100000Z-00001-0001", type = "obj", obj = "item", oid = "I-F", rev = 2, state = "a", base_ev = "X-0", user = "Me" }
mirror.event_file = function(_, id) if id == held.id then return held end; return { id = id, type = "obj", obj = "item", oid = "I-F", state = "m" } end
mirror.apart, mirror.descends, mirror.too_old_to_merge = function() return true end, function() return false end, function() return false end
reaper.SetProjExtState("PF", mirror.SEC, "I-F", "2|h|" .. held.id .. "|1")
local theirs = { id = "Bo-20261119-100100Z-00002-0001", type = "obj", obj = "item", oid = "I-F", rev = 2, state = "b", base_ev = "X-0", user = "Bo", format = 1 }
assert(mirror.merge_for("PF", theirs, "RF") ~= nil, "(made apart: merged)")
theirs.format = band.FORMAT + 1
assert(mirror.merge_for("PF", theirs, "RF") == nil, "a leaf too new for this version: no merge")
mirror.apart, mirror.event_file, mirror.descends, mirror.too_old_to_merge = real_m.apart, real_m.event_file, real_m.descends, real_m.old

-- code 1: "yours before X's work done alone" is saved with its map (recall.save's 7th argument) even mid catch-up
local real_save, args = recall.save, nil
recall.save = function(...) args = { ... } end
reaper.SetProjExtState("PY", band.SECTION, "alone_last", "2026-11-19T09:00:00Z")
sync.loading.PY = true
arrive("PY", { id = "Bo-20261119-120003Z-00004-0001", type = "note", text = "hi", alone = true })
assert(args and tostring(args[5]):find("yours before Bo", 1, true) and args[7] == true, "saved mapped: " .. tostring(args and args[7]))
recall.save, sync.loading.PY = real_save, nil
proxy.listing = function() return {} end

-- code 1: suggest.accept counts a part that couldn't apply as failed (and refused, and left with its sender)
local suggest = require("suggest")
reaper.EnumProjects = function(i) if i == -1 then return "PA" end end
files["RA/suggestions/parts/s9/E-9.json"] = { obj = "env", oid = "E-9", rev = 0, name = "Keys", state = "x" }
mirror.apply = function() return false end
local did, stale, refused, left, failed = suggest.accept("PA", cfg, "RA", { id = "s9", oids = { "E-9" }, from = "Bo" }, function() return true end, false)
assert(did == 0 and stale == 0 and refused == 1 and left[1] == "E-9" and failed == 1, "failed: " .. tostring(failed) .. ", refused " .. tostring(refused))
reaper.EnumProjects = function() return nil end

-- 0.59.49 follow-up: a MIDI part that no longer prints, with a print of other notes, has the print taken off; a current one stays
prints.choose = real.choose
local MIDI, PRN, PI = { name = "midi", midi = true }, { name = "print" }, { name = "part" }
pext[PRN] = { ["P_EXT:" .. prints.KEY] = "OLD" }
reaper.CountTakes = function() return 2 end
reaper.GetTake = function(_, k) return k == 0 and MIDI or PRN end
reaper.TakeIsMIDI = function(tk) return tk.midi == true end
reaper.TrackFX_GetCount = function() return 1 end
local cmds = {}
reaper.Main_OnCommand = function(c) cmds[#cmds + 1] = c end
local real_p = { route = prints.route, plays = prints.track_plays, mp = prints.midi_prints, source = prints.source, choose = prints.choose }
local hashed = 0
prints.route, prints.track_plays, prints.midi_prints = function() return nil end, function() return true end, function() return false end
prints.source = function() hashed = hashed + 1; return "NEW", nil end
prints.choose = function() end
assert(prints.refresh("PP", PI, "R/media", "fx", nil, cfg) == true and cmds[1] == 40129, "a stale print comes off")
cmds = {}
pext[PRN]["P_EXT:" .. prints.KEY] = "NEW"
assert(prints.refresh("PP", PI, "R/media", "fx", nil, cfg) == false and #cmds == 0, "a current print stays")
reaper.CountTakes, hashed = function() return 1 end, 0
assert(prints.refresh("PP", PI, "R/media", "fx", nil, cfg) == false and hashed == 0, "no print: nothing to do, not even a hash")
prints.route, prints.track_plays, prints.midi_prints, prints.source, prints.choose = real_p.route, real_p.plays, real_p.mp, real_p.source, real_p.choose

mirror.find, mirror.apply, mirror.keep_item_copy = real.find, real.apply, real.keep_item_copy
print("ok")
