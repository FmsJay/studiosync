-- rt (James, 2026-11-19): takes become lanes as a studio setting; a print for the picked take of an item with several; the song's other
-- project settings round-trip through capture/apply (and one this REAPER/SWS lacks is skipped); the studio's shared preferences go in and
-- come out again (a studio switch, exit, a crash, a change by hand); never-shared keys can't be included.
package.path = "lib/?.lua;" .. package.path
for _, m in ipairs({ "band", "groups", "prints", "mirror", "sharedprefs", "sync", "trust" }) do package.loaded[m] = nil end
local gext, pext, clock, front = {}, {}, 1000, nil
local gcfg = {} -- global prefs: name -> { kind, value }
local toggles = {} -- action id -> 0/1 (global, or the front project's: snap, preserve pitch, the recording-over-items choice)
local function px(p) pext[p] = pext[p] or {}; return pext[p] end
local stub = {
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  DeleteExtState = function(s, k) gext[s .. "\0" .. k] = nil end,
  GetProjExtState = function(p, s, k) local v = px(p)[s .. "\0" .. k] or ""; return v ~= "" and 1 or 0, v end,
  SetProjExtState = function(p, s, k, v) px(p)[s .. "\0" .. k] = v end,
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  EnumProjects = function(i) if i == -1 then return front end end,
  GetToggleCommandStateEx = function(_, id) return (front and front.toggles or toggles)[id] or -1 end,
  Main_OnCommand = function(id) -- (the recording-over-items choice is per project: measured, tests/reaper/rt_settings.lua)
    local t = front and front.toggles or toggles
    if id == 41186 or id == 41330 or id == 42677 then for _, x in ipairs({ 41186, 41330, 42677 }) do t[x] = x == id and 1 or 0 end
    elseif t[id] then t[id] = 1 - t[id] end
  end,
  SNM_GetIntConfigVar = function(k, err) local c = gcfg[k]; return c and c[1] == "i" and c[2] or err end,
  SNM_GetDoubleConfigVar = function(k, err) local c = gcfg[k]; return c and c[1] == "d" and c[2] or err end,
  SNM_SetIntConfigVar = function(k, v) local c = gcfg[k]; if c and c[1] == "i" then c[2] = v; return true end return false end,
  SNM_SetDoubleConfigVar = function(k, v) local c = gcfg[k]; if c and c[1] == "d" then c[2] = v; return true end return false end,
}
reaper = setmetatable(stub, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })
local band = require("band")

-- ---- 1. takes become lanes: a studio setting, on unless false ----------------------------------------------------------------------
package.loaded.trust = { pins = function() return nil end, from_manager_file = function() return nil end, inviter = function() return nil end,
  roles = function() return nil, {} end, held = function() return false end, pin = function() end, managers = function() return nil end,
  roles_of = function() return {} end }
local band_json = {}
band.read_json = function(path) return band_json[path] end
band.info = function(root) return { name = root, id = "id-" .. root } end
local groups = require("groups")
band_json["R/_band/band.json"] = { takes_to_lanes = false, shared_prefs = { deffadelen = 0.05 }, debug = true }
local t = groups.trusted("R")
assert(t.takes_to_lanes == false and t.shared_prefs and t.shared_prefs.deffadelen == 0.05, "both new settings come through the trusted settings")
assert(groups.takes_to_lanes("R") == false, "off when band.json says false")
band_json["S/_band/band.json"] = {}
assert(groups.takes_to_lanes("S") == true, "on by default")
local prints = require("prints")
local looked_at_tracks = 0
stub.CountTracks = function() looked_at_tracks = looked_at_tracks + 1; return 0 end
assert(prints.takes_to_lanes(0, function() return true end, "R") == 0 and looked_at_tracks == 0, "the studio's setting off: the pass doesn't run")
assert(prints.takes_to_lanes(0, function() return true end, "S") == 0 and looked_at_tracks == 1, "on: it runs")
assert(prints.takes_to_lanes(0, function() return true end) == 0 and looked_at_tracks == 2, "no studio given (the in-REAPER tests): it runs")
stub.CountTracks = nil

-- ---- 2. an item with several takes prints its picked take ------------------------------------------------------------------------
local mirror = require("mirror")
local tr = { fx = 1 }
local function take(file) return { ext = {}, file = file } end
local it = { takes = { take("a.wav"), take("b.wav") }, cur = 0, track = tr }
for _, tk in ipairs(it.takes) do tk.item = it end
local function idx(tk) for i, x in ipairs(tk.item.takes) do if x == tk then return i - 1 end end end
stub.CountTakes = function(i) return #i.takes end
stub.GetTake = function(i, k) return i.takes[k + 1] or nil end
stub.GetActiveTake = function(i) return i.takes[i.cur + 1] end
stub.SetActiveTake = function(tk) tk.item.cur = idx(tk) end
stub.GetMediaItemInfo_Value = function(i, k) if k == "I_CURTAKE" then return i.cur elseif k == "D_LENGTH" then return 2 end return 0 end
stub.SetMediaItemInfo_Value = function(i, k, v) if k == "I_CURTAKE" then i.cur = v end end
stub.GetSetMediaItemTakeInfo_String = function(tk, k, v, set)
  local key = k:gsub("^P_EXT:", "")
  if set then tk.ext[key] = v end
  return true, tk.ext[key] or ""
end
stub.GetSetMediaItemInfo_String = function() return true, "I-1" end
stub.TakeIsMIDI = function() return false end
stub.GetMediaItem_Track = function(i) return i.track end
stub.TrackFX_GetCount = function(x) return x.fx or 0 end
stub.TrackFX_GetFXName = function() return true, "VST: Amp (Nobody)" end
stub.TakeFX_GetCount = function() return 0 end
stub.GetMediaItemTake_Source = function(tk) return tk end
stub.GetMediaSourceFileName = function(src) return src.file end
stub.GetMediaItemTakeInfo_Value = function() return 0 end
stub.AddTakeToMediaItem = function(i) local tk = take("print.flac"); tk.item = i; i.takes[#i.takes + 1] = tk; return tk end
package.loaded.sync = {}
prints.track_plays = function() return true end
prints.lacking = function() return true end
prints.from_band = function() return false end
local rendered
prints.render = function(_, name) rendered = name; return nil end -- (what it would render, by name: the name carries the source hash)
assert(prints.audio_take(it) == it.takes[1], "several takes: the picked one is the one a print stands for (it was none)")
prints.refresh(0, it, "M", "fx", nil, {})
local first = rendered
it.cur = 1
assert(prints.audio_take(it) == it.takes[2], "the second picked")
prints.refresh(0, it, "M", "fx", nil, {})
assert(first and rendered and first ~= rendered, "picking another take makes another print: the pick is in its source")
assert(first == "print-I-1-" .. mirror.hash(prints.audio_source(it, it.takes[1], "fx") .. "|t0"), "take 1's print: its recording, and that it's take 1")
assert(rendered == "print-I-1-" .. mirror.hash(prints.audio_source(it, it.takes[2], "fx") .. "|t1"), "take 2's print")
-- a print made for take 2, attached; then the print playing still counts as take 2 for the band (BANDTAKE)
local ptk = stub.AddTakeToMediaItem(it)
ptk.ext[prints.KEY], ptk.ext[prints.FROM] = "h2", "1"
it.cur = 2
assert(mirror.picked_take(it) == 1, "a print playing counts as the take it was made from, not the first")
assert(#mirror.real_takes(it) == 2 and mirror.filled_takes(it) == 2, "the print isn't a real take")
-- choose: the print plays only for the take it's of, and only where the plug-ins don't load
prints.track_plays = function() return false end
it.cur = 1
prints.choose(it, true)
assert(it.cur == 2, "take 2 picked, its print here, a plug-in missing: the print plays")
prints.track_plays = function() return true end
prints.choose(it, true)
assert(it.cur == 1, "the plug-ins load here: the take plays itself")
prints.track_plays = function() return false end
it.cur = 0
prints.choose(it, true)
assert(it.cur == 0, "take 1 picked, the print is take 2's: take 1 plays itself until its own print lands")
-- an old print (made before, of the first take, with no FROM): never stands in on an item with several
ptk.ext[prints.FROM] = nil
it.cur = 1
prints.choose(it, true)
assert(it.cur == 1, "an old print with no take named isn't played")
-- one take: as before (no FROM written, no pick in the hash)
local one = { takes = { take("c.wav") }, cur = 0, track = tr }
one.takes[1].item = one
assert(prints.audio_take(one) == one.takes[1], "one take: that one")
prints.track_plays, rendered = function() return true end, nil -- (this computer has the plug-ins, so it prints)
prints.refresh(0, one, "M", "fx", nil, {})
assert(rendered == "print-I-1-" .. prints.audio_source(one, one.takes[1], "fx"), "one take: the print's source as before (prints made already stay current)")

-- ---- 3. the song's project settings round-trip -------------------------------------------------------------------------------------
local function project(o)
  local p = { info = { PROJECT_SRATE = o.sr, PROJECT_SRATE_USE = 1, RENDER_SRATE = 0, RENDER_CHANNELS = o.ch },
    str = { RECORD_FORMAT = o.rec, RENDER_FORMAT = o.fmt, RENDER_FORMAT2 = "", RECORD_PATH = "C:/mine", RENDER_FILE = "C:/renders" },
    grid = { o.div, 0, 0 }, rate = o.rate, cfg = o.cfg, toggles = { [1157] = o.snap, [40671] = o.pp, [41186] = o.rec_over == 41186 and 1 or 0, [41330] = o.rec_over == 41330 and 1 or 0, [42677] = o.rec_over == 42677 and 1 or 0 } }
  return p
end
stub.GetSetProjectInfo = function(p, k, v, set) if set then p.info[k] = v end return p.info[k] or 0 end
stub.GetSetProjectInfo_String = function(p, k, v, set) if set then p.str[k] = v end return p.str[k] ~= nil, p.str[k] or "" end
stub.GetSetProjectGrid = function(p, set, d, s, a) if set then p.grid = { d, s, a } end return 0, p.grid[1], p.grid[2], p.grid[3] end
stub.Master_GetPlayRate = function(p) return p.cfg.playrate[2] end -- (REAPER's playrate is the project's "playrate" value)
stub.CSurf_OnPlayRateChange = function(r) front.cfg.playrate[2] = r end
stub.SNM_GetIntConfigVarEx = function(p, k, err) local c = p.cfg[k]; return c and c[1] == "i" and c[2] or err end
stub.SNM_GetDoubleConfigVarEx = function(p, k, err) local c = p.cfg[k]; return c and c[1] == "d" and c[2] or err end
stub.SNM_SetIntConfigVarEx = function(p, k, v) local c = p.cfg[k]; if c and c[1] == "i" then c[2] = v; return true end return false end
stub.SNM_SetDoubleConfigVarEx = function(p, k, v) local c = p.cfg[k]; if c and c[1] == "d" then c[2] = v; return true end return false end
local A = project({ sr = 48000, ch = 2, rec = "ZmxhYw==", fmt = "Y2FsZhgAAAAFAAAA", div = 0.125, rate = 0.8, snap = 1, pp = 1, rec_over = 42677,
  cfg = { autoxfade = { "i", 393 }, projrecmode = { "i", 1 }, projmetroen = { "i", 7 }, projmetropattern = { "i", 169 }, projtimeoffs = { "d", 2.5 },
    projmeasoffs = { "i", -1 }, projfrbase = { "i", 25 }, projfrdrop = { "i", 0 }, playrate = { "d", 0.8 } } }) -- (no projmetrocountin: an older REAPER)
local B = project({ sr = 44100, ch = 1, rec = "ZXZhdw==", fmt = "ZXZhdw==", div = 0.25, rate = 1, snap = 0, pp = 0, rec_over = 41186,
  cfg = { autoxfade = { "i", 0 }, projrecmode = { "i", 0 }, projmetroen = { "i", 2 }, projmetropattern = { "i", 1 }, projtimeoffs = { "d", 0 },
    projmeasoffs = { "i", 0 }, projfrbase = { "i", 30 }, projmetrocountin = { "i", 2 }, playrate = { "d", 1 } } }) -- (no projfrdrop: SWS doesn't know it)
front = A
local sa = band.capture_settings(A)
assert(sa.cfg.projmetrocountin == nil and sa.cfg.autoxfade == 393 and sa.cfg.projtimeoffs == 2.5, "read where this REAPER has it, left out where not")
assert(sa.cfg.projmetroen == 6, "the click's on/off bit stays this computer's: not in what's shared")
assert(sa.snap == 1 and sa.preserve_pitch == 1 and sa.rec_overlap == 42677, "snap, preserve pitch and the recording-over-items choice, read while the tab is in front")
for k in pairs(sa) do assert(not k:find("PATH") and not k:find("FILE"), "never a path: " .. k) end
local ok = pcall(band.apply_settings, B, sa) -- (B behind: snap and preserve pitch wait for it to come in front)
assert(ok, "applying never errors on a setting the other side lacks")
assert(B.str.RENDER_FORMAT == "Y2FsZhgAAAAFAAAA" and B.info.RENDER_CHANNELS == 2, "the render format")
assert(B.info.PROJECT_SRATE == 44100 and B.str.RECORD_FORMAT == "ZXZhdw==" and sa.srate == nil and sa.RECORD_FORMAT == nil,
  "sample rate and recording format aren't sent with the timeline: prep.keep_format holds them to the session's")
assert(B.str.RECORD_PATH == "C:/mine" and B.str.RENDER_FILE == "C:/renders", "paths stay each computer's own")
assert(B.grid[1] == 0.125 and B.cfg.autoxfade[2] == 393 and B.cfg.projrecmode[2] == 1 and B.cfg.projtimeoffs[2] == 2.5 and B.cfg.projfrbase[2] == 25, "grid, crossfades, record mode, start, frame rate")
assert(B.cfg.projmetroen[2] == 6 and B.cfg.projmetrocountin[2] == 2, "metronome switches with B's own on/off bit (off); a count-in A didn't send stays")
assert(B.cfg.playrate[2] == 0.8, "a tab behind gets the playrate through SWS")
assert(B.toggles[1157] == 0 and B.toggles[41186] == 1 and B.toggles[42677] == 0, "snap and the recording choice wait for the tab behind to come in front")
front = B
local sb = band.capture_settings(B)
assert(B.toggles[1157] == 1 and B.toggles[40671] == 1, "in front: the waiting snap and preserve pitch are set")
assert(B.toggles[42677] == 1 and B.toggles[41186] == 0 and A.toggles[42677] == 1, "and the recording-over-items choice, on that tab only")
band.apply_settings(B, { rec_overlap = 40000 }) -- (an action that isn't one of the choices: never run)
assert(B.toggles[42677] == 1 and B.toggles[40000] == nil, "a recording choice that isn't one of the three is ignored")
sb.cfg.projmetrocountin, sa.cfg.projfrdrop = nil, nil -- (each side's own extra: the one the other lacks)
assert(band.json_encode(sa) == band.json_encode(sb), "round trip: B now captures as A did\n" .. band.json_encode(sa) .. "\n" .. band.json_encode(sb))
-- the playrate on the tab in front goes through REAPER's own call
local s2 = band.capture_settings(B)
s2.playrate = 1.5
band.apply_settings(B, s2)
assert(B.cfg.playrate[2] == 1.5, "in front: CSurf_OnPlayRateChange")
-- no SWS at all: what REAPER itself has still travels, nothing errors
local was = { stub.SNM_GetIntConfigVarEx, stub.SNM_GetDoubleConfigVarEx }
stub.SNM_GetIntConfigVarEx, stub.SNM_GetDoubleConfigVarEx = nil, nil
local s3 = band.capture_settings(A)
assert(next(s3.cfg) == nil and s3.RENDER_FORMAT == "Y2FsZhgAAAAFAAAA" and s3.grid[1] == 0.125, "no SWS: no config values, the rest as before")
assert(pcall(band.apply_settings, B, sa), "and applying them is skipped, not an error")
stub.SNM_GetIntConfigVarEx, stub.SNM_GetDoubleConfigVarEx = was[1], was[2]
-- apply_project with an older version's timeline (no settings): nothing changes, nothing errors
assert(pcall(band.apply_project, B, { title = "x" }), "an older version's project part: fine")

-- ---- 4. the studio's shared preferences -----------------------------------------------------------------------------------------
front = nil
local sp = require("sharedprefs")
local studios = {}
groups.trusted = function(root) return studios[root] or {} end
gcfg = { deffadelen = { "d", 0.01 }, deffadeshape = { "i", 1 }, defsplitxfadelen = { "d", 0.01 }, defxfadeshape = { "i", 0 }, splitautoxfade = { "i", 33 },
  audiobufsize = { "i", 512 } }
studios.A = { shared_prefs = { deffadelen = 0.05, rec_overlap = 42677, audiobufsize = 64, defrecpath = 1 } } -- (rec_overlap: per project now, not a preference)
studios.B = { shared_prefs = { deffadelen = 0.1, deffadeshape = 3 } }
local function live() return gcfg.deffadelen[2], gcfg.deffadeshape[2] end
sp.tick("A", true)
local f, s = live()
assert(f == 0.05 and s == 1, "studio A's song in front: its fade length")
assert(gcfg.audiobufsize[2] == 512, "a buffer size planted in band.json is never applied")
assert(sp.mine("deffadelen") == 0.01, "this computer's own, saved while the studio's is in")
assert(reaper.GetExtState(band.SECTION, sp.HELD) == ";deffadelen;", "the held list says which are the studio's (a recording choice left in band.json isn't one)")
sp.tick(nil, true)
f, s = live()
assert(f == 0.01 and s == 1, "no studio song in front: yours back")
assert(reaper.GetExtState(band.SECTION, sp.HELD) == "", "and nothing held")
-- a studio switch: what both share keeps your saved value; what only the old one shared comes back
sp.tick("A", true)
sp.tick("B", true)
f, s = live()
assert(f == 0.1 and s == 3, "studio B in front: its values")
assert(sp.mine("deffadelen") == 0.01, "your own fade length is still the one saved, not A's")
sp.tick(nil, true) -- (Live sync stopping, REAPER quitting: its atexit)
f, s = live()
assert(f == 0.01 and s == 1, "exit: all yours")
-- changed by hand while the studio's is in: yours stands, not fought, not put back
sp.tick("A", true)
gcfg.deffadelen[2] = 0.2
sp.tick("A", true)
assert(gcfg.deffadelen[2] == 0.2, "a change by hand isn't fought")
sp.tick(nil, true)
assert(gcfg.deffadelen[2] == 0.2, "nor put back")
gcfg.deffadelen[2] = 0.01
-- once a second at most (Live sync ticks often), at once when asked
sp.tick("A", true)
gcfg.deffadelen[2] = 0.3 -- (by hand)
studios.A.shared_prefs.deffadelen = 0.06
sp.tick("A")
assert(gcfg.deffadelen[2] == 0.3, "within the second: not looked at")
clock = clock + 2
sp.tick("A")
assert(gcfg.deffadelen[2] == 0.3, "a second on: your change stands")
studios.A.shared_prefs.deffadelen = 0.05
sp.tick(nil, true); gcfg.deffadelen[2] = 0.01
-- REAPER crashed (or quit before the put-back) with the studio's in: the next start puts yours back
sp.tick("A", true)
package.loaded.sharedprefs = nil
reaper.DeleteExtState(band.SECTION, "shared prefs session")
sp = require("sharedprefs")
sp.tick(nil, true)
f = live()
assert(f == 0.01, "next start, no studio song in front: yours back from the saved state")
-- ... unless something changed it since (ReaPersona's restart write): that's yours now
sp.tick("A", true)
package.loaded.sharedprefs = nil
reaper.DeleteExtState(band.SECTION, "shared prefs session")
gcfg.deffadelen[2] = 0.03
sp = require("sharedprefs")
sp.tick("A", true)
assert(gcfg.deffadelen[2] == 0.05 and sp.mine("deffadelen") == 0.03, "ReaPersona's value since the restart is yours: saved, the studio's on top")
sp.tick(nil, true)
assert(gcfg.deffadelen[2] == 0.03, "and it's what comes back")
-- a setting this REAPER or SWS doesn't have: left alone, no error
gcfg.deffadeshape = nil
studios.B.shared_prefs.deffadeshape = 3
assert(pcall(sp.tick, "B", true) and gcfg.deffadeshape == nil, "missing here: skipped")
sp.tick(nil, true)

-- ---- 5. never shared ------------------------------------------------------------------------------------------------------------
local c = sp.clean({ deffadelen = 0.02, audiobufsize = 64, asio_bsize = 128, defrecpath = "C:/x", zoommode = 1, uiscale = 2, colortheme = 1,
  rec_overlap = 40000, deffadeshape = "3", nonsense = 1 })
assert(c.deffadelen == 0.02 and c.deffadeshape == 3, "keys on the list, numbers")
local n = 0
for _ in pairs(c) do n = n + 1 end
assert(n == 2, "devices, buffers, paths, zoom, scale, theme, an action that isn't one of the choices, unknown keys: never")
for _, k in ipairs({ "asio_bsize", "audiobufsize", "defrecpath", "zoommode", "colortheme", "uiscale", "midiins_cs", "workthreads", "renderlatency" }) do
  assert(sp.never(k), "never shared: " .. k)
end
for _, x in ipairs(sp.PREFS) do assert(not sp.never(x[1]), "a key on the list isn't a never-shared one: " .. x[1]) end
-- groups.set_shared_prefs cleans what it writes
local wrote
band.write_json = function(path, j) if path:find("band.json", 1, true) then wrote = j end end
groups.set_shared_prefs("S", { deffadelen = 0.04, audiobufsize = 64 })
assert(wrote and wrote.shared_prefs and wrote.shared_prefs.deffadelen == 0.04 and wrote.shared_prefs.audiobufsize == nil, "the setter keeps only the list's keys")
print("ok")
