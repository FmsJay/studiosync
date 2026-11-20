-- 0.60.0-rt, crash-safe sessions: REAPER killed or restarted without saving reopens an older save. Nothing of yours may be lost (what went out
-- comes back, what hadn't gone out is put back and sent once), and nothing stale goes to the band. Each block fails with its fix reverted:
--   1 sync.receive: your own tempo map / markers / settings newer than the reopened file came back as "already true here", and never landed
--   2 sync.watch_timeline: a reopened file whose settings read differently sent its stale timeline before its first catch-up was done
--   3 sync.watch_timeline: behind session.json, settings that differ were sent over the studio's newer map; its settings now land
--   4 mirror.stash_unsent / restore_unsent: changes seen and not yet sent (settling, playing, held) lived only in memory
--   5 sync.follow_claims: a claim followed the reopened file's old track name back before the rename came in again
-- Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local exts, gext, clock = {}, {}, 1000
local function sec_of(p, sec) exts[p] = exts[p] or {}; exts[p][sec] = exts[p][sec] or {}; return exts[p][sec] end
local open, fns = {}, {} -- open projects in tab order, and their files
reaper = setmetatable({
  GetProjExtState = function(p, sec, k) local v = sec_of(p, sec)[k] or ""; return v ~= "" and 1 or 0, v end,
  SetProjExtState = function(p, sec, k, v) sec_of(p, sec)[k] = v end,
  EnumProjExtState = function() return false end,
  GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
  SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
  DeleteExtState = function(s, k) gext[s .. "\0" .. k] = nil end,
  time_precise = function() return clock end,
  EnumProjects = function(i) local p = i >= 0 and open[i + 1]; if p then return p, fns[p] end end,
  GetPlayStateEx = function() return 0 end,
  ValidatePtr2 = function() return true end,
  GetMasterTrack = function(p) return "master of " .. tostring(p) end,
  CountTracks = function() return 0 end,
  CountMediaItems = function() return 0 end,
  file_exists = function() return true end,
}, { __index = function() return function() end end })

local files, written, logged = {}, {}, {}
local band = require("band")
local proxy = setmetatable({}, { __index = band })
proxy.read_json = function(path) local v = files[path]; if type(v) == "table" then local c = {}; for k, x in pairs(v) do c[k] = x end; return c end end
proxy.listing = function() return {} end
proxy.write_json = function(path, v) written[path] = (written[path] or 0) + 1; files[path] = v end
proxy.log = function(t) logged[#logged + 1] = t end
local tempo, markers, settings = {}, {}, {}
proxy.capture_tempo, proxy.capture_markers, proxy.capture_project = function() return tempo end, function() return markers end, function() return settings end
proxy.apply_tempo, proxy.apply_markers, proxy.apply_project = function(_, t) tempo = t end, function(_, m) markers = m end, function(_, s) settings = s or settings end
proxy.session_path = function() return "SESSION" end
package.loaded.band = proxy
local real_remove = os.remove
os.remove = function(path) files[path] = nil; return real_remove(path) end
local mirror = require("mirror")
local sync = require("sync")
sync.resnap, sync.audio_follow_tempo = function() end, function() end
local cfg = { user = "Me", root = "root" }
local can = function() return true end
local T120, T130 = { { time = 0, bpm = 120, num = 4, denom = 4, linear = false } }, { { time = 0, bpm = 130, num = 4, denom = 4, linear = false } }
local function bpm() return tempo[1] and tempo[1].bpm end
local function saved(p, t, newest) -- (a project as it was saved: its map, the newest it had applied, and what Live sync last saw, all as of the save)
  tempo, markers, settings = t, {}, {}
  reaper.SetProjExtState(p, sync.NEWEST, "timeline", newest)
  reaper.SetProjExtState(p, band.SECTION, "timeline", sync.timeline_sig(p))
  sync.timeline_looked[p] = nil
end

-- 1: your own newer map comes back to a reopened file (a side room: no session.json look there), and isn't applied twice in a normal session
do
  local edir = sync.room_dir(cfg, "S", "side") .. "/events"
  local id = "Me-20261119-180000Z-00001-0001"
  files[edir .. "/" .. id .. ".json"] = { id = id, time = "2026-11-19T18:00:00Z", user = "Me", type = "timeline", tempo = T120, markers = { { pos = 4, name = "Verse" } }, project = { grid = 0.5 } }
  proxy.listing = function(d) if d == edir then return { id .. ".json" } end; return {} end
  saved("P1", T130, "2026-11-19T17:00:00ZMe-old")
  sync.receive("P1", cfg, "S", "side", can)
  assert(bpm() == 120 and markers[1] and settings.grid == 0.5, "reopened behind your own map: it lands (bpm " .. tostring(bpm()) .. ")")
  assert(select(2, reaper.GetProjExtState("P1", sync.APPLIED, id)) == "1", "and is marked done")
  -- the session that made it: stamped with it as it went out, so it's already true here
  saved("P1b", T130, "2026-11-19T18:00:00Z" .. id)
  sync.receive("P1b", cfg, "S", "side", can)
  assert(bpm() == 130 and select(2, reaper.GetProjExtState("P1b", sync.APPLIED, id)) == "1", "made here this session: marked done, not applied again")
  proxy.listing = function() return {} end
end

-- 2: a reopened file whose project settings read differently: nothing goes out until its first catch-up is done; then a real change does
do
  local posted = 0
  local real_post = sync.post
  sync.post = function(_, _, _, ev) posted = posted + 1; ev.time, ev.id = "2026-11-19T19:00:00Z", "Me-x" end
  saved("P2", T120, "2026-11-19T17:00:00ZMe-old")
  settings = { grid = 0.25 } -- (another REAPER's defaults, or the tab not in front)
  sync.loading.P2 = true
  sync.watch_timeline("P2", cfg, "S", "side", can)
  assert(posted == 0, "still catching up: the settings wait (posted " .. posted .. ")")
  sync.watch_timeline("P2", cfg, "S", "side", can)
  assert(posted == 0, "every look while it catches up")
  sync.loading.P2 = nil
  sync.watch_timeline("P2", cfg, "S", "side", can)
  assert(posted == 1, "caught up and still different: yours, it goes out (posted " .. posted .. ")")
  -- a marker you added before the open is a real change: it isn't held back by the catch-up
  saved("P2m", T120, "2026-11-19T17:00:00ZMe-old")
  markers = { { pos = 8, name = "Chorus" } }
  sync.loading.P2m = true
  sync.watch_timeline("P2m", cfg, "S", "side", can)
  assert(posted == 2, "a marker of yours goes out at once")
  sync.loading.P2m = nil
  sync.post = real_post
end

-- 3: behind session.json in the main room, tempo and markers already as the studio's, settings different: the studio's settings land, nothing sent
do
  local posted = 0
  local real_post = sync.post
  sync.post = function(_, _, _, ev) posted = posted + 1; ev.time, ev.id = "2026-11-19T19:00:00Z", "Me-x" end
  local A1, A2 = "2026-11-19T17:30:00ZBo-A1", "2026-11-19T17:49:17ZBo-A2"
  saved("P3", T120, A1)
  settings = { grid = 0.25 }
  files.SESSION = { tempo = T120, markers = {}, timeline_order = A2, project = { grid = 0.5 } }
  sync.watch_timeline("P3", cfg, "S", "main", can)
  assert(posted == 0 and settings.grid == 0.5, "behind: the studio's settings, nothing sent (posted " .. posted .. ", grid " .. tostring(settings.grid) .. ")")
  -- a session.json from before it noted settings: nothing sent either, the studio's map in the folder lands through sync.receive
  saved("P3b", T120, A1)
  settings = { grid = 0.25 }
  files.SESSION = { tempo = T120, markers = {}, timeline_order = A2 }
  sync.watch_timeline("P3b", cfg, "S", "main", can)
  sync.watch_timeline("P3b", cfg, "S", "main", can)
  assert(posted == 0, "behind, older session.json: nothing sent (posted " .. posted .. ")")
  -- what goes out records its settings in session.json
  local real_session = sync.session_timeline
  local got
  sync.session_timeline = function(_, _, _, _, _, project) got = project end
  saved("P3c", T120, A2)
  sync.timeline_looked.P3c = true
  settings = { grid = 1 }
  sync.watch_timeline("P3c", cfg, "S", "main", can)
  assert(posted == 1 and got and got.grid == 1, "sent, with its settings for session.json")
  sync.session_timeline, sync.post = real_session, real_post
  files.SESSION = nil
end

-- 4: unsent changes kept beside the project, and put back once after REAPER stopped without sending them
do
  local FX0, FX2 = "<FXCHAIN\nKNOB 0\n>\n", "<FXCHAIN\nKNOB 2\n>\n"
  local PATH = "C:/s/Song.bandsync-unsent.json"
  open, fns = { "A1" }, { A1 = "C:\\s\\Song.RPP", U1 = "" }
  -- session one: a knob turned while playing (unsent), a held delete of an item the band has, and an item that couldn't go out yet
  reaper.SetProjExtState("A1", mirror.SEC, "F-ME-1-1", "3|h1|Bo-20261119-170000Z-00001-0001|t3")
  reaper.SetProjExtState("A1", mirror.SEC, "I-ME-1-9", "4|hi|Bo-20261119-170100Z-00001-0001|t4")
  local by_oid = { ["F-ME-1-1"] = { kind = "fx", oid = "F-ME-1-1", track = "T-ME-1-1", state = FX2, hash = "h2" },
    ["I-ME-1-5"] = { kind = "item", oid = "I-ME-1-5", track = "T-ME-1-1", state = "<ITEM\n>\n", hash = "hn", pos = 2 } }
  mirror.unsent["A1F-ME-1-1"], mirror.unsent["A1I-ME-1-9"] = true, true
  mirror.held_back.A1 = { ["I-ME-1-5"] = true }
  mirror.stash_unsent("A1", by_oid)
  local s = files[PATH]
  assert(s and s.objs["F-ME-1-1"].state == FX2 and s.objs["F-ME-1-1"].known == "3|h1|Bo-20261119-170000Z-00001-0001|t3", "the chain, with what it was made on")
  assert(s.objs["I-ME-1-9"].gone and s.objs["I-ME-1-9"].kind == "item" and s.objs["I-ME-1-5"].state == "<ITEM\n>\n", "the held delete, the held-back item")
  -- cheap: unchanged, nothing written; a knob turned again within STASH_SECS waits, then goes
  local n = written[PATH]
  mirror.stash_unsent("A1", by_oid)
  by_oid["F-ME-1-1"].hash, by_oid["F-ME-1-1"].state = "h3", "<FXCHAIN\nKNOB 3\n>\n"
  clock = clock + 0.5
  mirror.stash_unsent("A1", by_oid)
  assert(written[PATH] == n, "not rewritten every look")
  clock = clock + mirror.STASH_SECS
  mirror.stash_unsent("A1", by_oid)
  assert(written[PATH] == n + 1 and files[PATH].objs["F-ME-1-1"].hash == "h3", "rewritten once STASH_SECS have passed")
  -- an untitled project has nowhere to keep it
  mirror.unsent["U1F-X"] = true
  open = { "U1" }
  mirror.stash_unsent("U1", { ["F-X"] = { kind = "fx", state = "", hash = "x" } })
  mirror.unsent["U1F-X"] = nil

  -- REAPER killed. Reopened, the older save: the chain as it was two revisions ago, the deleted item still there, the held-back item never saved
  mirror.unsent, mirror.held_back.A1 = {}, nil
  open, fns.A2 = { "A2" }, "C:\\s\\Song.RPP"
  reaper.SetProjExtState("A2", mirror.SEC, "F-ME-1-1", "2|h0|Bo-20261119-165000Z-00001-0001|t2")
  reaper.SetProjExtState("A2", mirror.SEC, "I-ME-1-9", "4|hi|Bo-20261119-170100Z-00001-0001|t4")
  local now = { ["F-ME-1-1"] = { kind = "fx", oid = "F-ME-1-1", track = "T-ME-1-1", state = FX0, hash = "h0" },
    ["I-ME-1-9"] = { kind = "item", oid = "I-ME-1-9", track = "T-ME-1-1", state = "<ITEM\n>\n", hash = "hi" } }
  local applied = {}
  local real_apply = mirror.apply
  local playing = true
  mirror.apply = function(_, ev) if ev.obj == "fx" and playing then return false end; applied[#applied + 1] = ev; return true, "h" end
  mirror.reopened["A2F-ME-1-1"] = true
  mirror.fx_readback["A2F-ME-1-1"] = "h"
  assert(mirror.restore_unsent("A2", now, "M", false) == 2, "the item and the delete go back at once")
  assert(applied[1].oid == "I-ME-1-5" and applied[1].state == "<ITEM\n>\n" and applied[2].oid == "I-ME-1-9" and applied[2].gone, "in order: the item, then the delete")
  -- the chain waits for the stop (as the band's chains do), kept in the file, the band's change to it waiting for it
  mirror.stash_unsent("A2", now)
  assert(mirror.restoring.A2["F-ME-1-1"] and files[PATH].objs["F-ME-1-1"] and mirror.unsent["A2F-ME-1-1"], "the chain waits, kept, and holds the band's back")
  playing = false
  assert(mirror.restore_unsent("A2", now, "M", false) == 1 and applied[3].state == "<FXCHAIN\nKNOB 3\n>\n", "stopped: the chain is back")
  assert(mirror.known("A2", "F-ME-1-1") == 3, "built on what it was made on (rev 3), as it would have been")
  assert(not mirror.reopened["A2F-ME-1-1"] and not mirror.fx_readback["A2F-ME-1-1"], "not put back as an old save, nor taken for a plug-in loading")
  assert(mirror.restoring.A2 == nil and mirror.restore_unsent("A2", now, "M", false) == 0, "once only")
  -- sent by the next look: the file goes
  mirror.unsent = {}
  clock = clock + mirror.STASH_SECS
  mirror.stash_unsent("A2", now)
  assert(files[PATH] == nil, "nothing waits: the file is gone")

  -- what the reopened project already has, or holds newer than what it was made on, isn't put back
  files[PATH] = { objs = { ["F-ME-1-1"] = { kind = "fx", track = "T-ME-1-1", state = FX2, hash = "h2", known = "3|h1|e|t" },
    ["I-ME-1-7"] = { kind = "item", track = "T-ME-1-1", state = "<ITEM\nX\n>\n", hash = "h7", known = "1|h|e|t" } } }
  open, fns.A3 = { "A3" }, "C:\\s\\Song.RPP"
  reaper.SetProjExtState("A3", mirror.SEC, "I-ME-1-7", "2|h8|e2|t")
  applied = {}
  local n3 = mirror.restore_unsent("A3", { ["F-ME-1-1"] = { kind = "fx", state = FX2, hash = "h2" } }, "M", false)
  assert(n3 == 0 and #applied == 0 and mirror.restoring.A3 == nil, "saved with it, or older news: left as it is (" .. n3 .. ")")
  -- Live sync's clean stop takes the file away: REAPER asked about saving
  files[PATH] = { objs = {} }
  mirror.drop_stash("A3")
  assert(files[PATH] == nil, "a clean stop removes it")
  mirror.apply = real_apply
end

-- 5: a claim doesn't follow the reopened file's old track name while it catches up
do
  local track = { name = "Keys" } -- (renamed Piano and sent; the reopened save still says Keys)
  local real_find = mirror.find
  mirror.find = function(_, kind, oid) if kind == "track" and oid == "T-ME-1-2" then return track end end
  reaper.GetTrackName = function(tr) return true, tr.name end
  local path = sync.claims_path(cfg, "S", "main", "Me")
  files[path] = { user = "Me", time = "2026-11-19T18:00:00Z", tracks = { "Piano" }, oids = { piano = "T-ME-1-2" }, since = { ["tracks:piano"] = "2026-11-19T17:00:00Z" } }
  sync.loading.P5 = true
  sync.follow_claims("P5", cfg, "S", "main")
  assert(files[path].tracks[1] == "Piano", "still catching up: your claim keeps the name you gave it (" .. tostring(files[path].tracks[1]) .. ")")
  sync.loading.P5 = nil
  track.name = "Organ" -- (caught up, then renamed here: the claim goes with it, as before)
  sync.follow_claims("P5", cfg, "S", "main")
  assert(files[path].tracks[1] == "Organ", "caught up: a rename here takes the claim with it")
  mirror.find = real_find
end
print("ok")
