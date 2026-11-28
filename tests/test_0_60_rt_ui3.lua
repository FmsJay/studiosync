-- rt-ui3 (docs/rt/ui-web-plan.md Phase 3, the History tab): History > Changes and Versions (lib/webrestore.lua: the rows and filters, the
-- ask -> confirm -> yes rule for every restore and undo, from a phone too; what only a page on this computer may do), Mixes (lib/webmixes.lua:
-- the lists, a file named only from the list, what's this-computer-only), Play through REAPER and Open this point in REAPER (lib/histhear.lua:
-- SWS's player against a stand-in, refused from another device), and webhistory's dispatch. The pages run in tests/rt_ui3_browser.mjs.
-- Lua 5.4, from the repo root.
package.path = "lib/?.lua;" .. package.path
local clock, here, ext = 1000, 0, {}
local calls = {} -- what reached REAPER or SWS
local function log(x) calls[#calls + 1] = x end
local guid = 0
reaper = setmetatable({
  time_precise = function() return clock end,
  genGuid = function() guid = guid + 1; return string.format("{%08X-0000-0000-0000-000000000000}", guid) end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  GetProjExtState = function(_, _, k) if k == "before_bandsync" then return 1, "C:/before.rpp" end return 0, "" end,
  file_exists = function(p) return p == "C:/before.rpp" end,
  StudioSync_WebUIPollHere = function() return here end,
  Main_OnCommand = function(id) log("cmd " .. id) end,
  Main_openProject = function(p) log("open " .. p) end,
  AddRemoveReaScript = function(_, _, p) log("script " .. p:match("[^/\\]+$")); return 777 end,
  CountTracks = function() return 0 end, EnumerateFiles = function() return nil end, EnumerateSubdirectories = function() return nil end,
  -- SWS's preview player, standing in
  PCM_Source_CreateFromFile = function(p) log("src " .. p); return { p = p } end,
  PCM_Source_Destroy = function(s) log("destroy " .. s.p) end,
  GetMediaSourceLength = function() return 100 end,
  CalculateNormalization = function() return 0.5 end,
  CF_CreatePreview = function(s) log("preview " .. s.p); return { s = s, pos = 0, live = true } end,
  CF_Preview_SetValue = function(pv, k, v) if k == "D_POSITION" then pv.pos = v end; if k == "D_VOLUME" then pv.vol = v end; return true end,
  CF_Preview_GetValue = function(pv, k) if not pv.live then return false, 0 end; if k == "D_POSITION" then return true, pv.pos end return true, 0 end,
  CF_Preview_Play = function(pv) log("play " .. pv.s.p .. " @" .. pv.pos) return true end,
  CF_Preview_Stop = function(pv) log("stop " .. pv.s.p); pv.live = false; return true end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") and not tostring(k):find("^CF_") then return function() return 0 end end end })
local band = require("band")
local logged = {}
band.log = function(s) logged[#logged + 1] = s end
band.read_json = function() return nil end
band.files = function() return {} end
band.subdirs = function() return {} end
band.open_url = function(u) log("url " .. u) end

-- ---- stand-ins for what webrestore drives (their own tests cover them) --------------------------------------------------------------------
local ENTRIES, VERSIONS, DRIVER = {}, {}, "James"
local function ev(id, time, user, x) x = x or {}; x.id, x.time, x.user = id, "2026-11-27T" .. time .. "Z", user; x.kind = x.kind or "obj"; return x end
package.loaded.recall = {
  entries = function() local out = {}; for i, e in ipairs(ENTRIES) do out[i] = e end; return out end,
  list = function() return VERSIONS end, warm = function() return true, #ENTRIES, #ENTRIES end,
  describe = function(e) return (e.words or "a change") end,
  save = function(_, _, _, _, label) log("save " .. tostring(label)) end, back_up = function(_, _, _, label) log("backup " .. tostring(label)) end,
}
package.loaded.sync = { authority = function() return function() return true end, { driver = DRIVER, mode = "open" } end,
  room_dir = function() return "C:/S/Song/rooms/main" end, timeline_sig = function() return "[]" end }
local moments = {} -- index -> its act's indices
package.loaded.mirror = {
  same_moment = function(_, i) return moments[i] or { i } end,
  lane_words = function() return "" end, known = function() return 0, "h", { id = "x" } end, find = function() return true end,
  apply = function() log("apply"); return true end, fnv = function(s) return "f" .. #s end,
}
local R = { test = {} }
for _, k in ipairs({ "undo_change", "restore_whole", "restore_tracks" }) do R.test[k] = function(i) log(k .. " " .. i); return k .. " said" end end
R.test.plan_for = function(i, point, scope) log("plan " .. i .. (point and " v" or "") .. (scope and " scoped" or "")); return {} end
R.test.entries = function() end
R.test.undo_plan = function(i) return {}, i == 1 and { "Bo", "James" } or {} end -- (who changed it after: lib/undo.lua undo.plan, its own tests)
R.init = function() end
R.show_change = function(_, e) log("show " .. e.id) end
package.loaded.page_restore = R
package.loaded.together = { bar_of = function(x) return tostring(x) end }
package.loaded.webui = { clean_text = function(t) t = t:gsub("%c", " "):match("^%s*(.-)%s*$"); return t ~= "" and t or nil end }
package.loaded.webhome = {
  mix_of = function(f) local y = f:match("(%d%d%d%d)%-") return y and f:match("%.wav$") and { name = f, user = f:match(" (%a+)%.wav$"), time = tonumber(f:match("(%d+)%-")) } or nil end,
  stems_of = function(d) return { name = d, user = "Bo", time = 5 } end,
}
package.loaded.extras = { credits = function() return "C:/S/Song/credits.txt" end, save_template = function(_, _, n) return "C:/t/" .. n .. ".rpp" end,
  stems = function(_, _, _, dry) log("stems " .. tostring(dry)); return nil, "Stop recording first." end }
package.loaded.bounces = { ask = function(_, what, sel) log("bounce " .. what .. " " .. tostring(sel)) end, panel_line = function() return nil end }
package.loaded.export = { ask = function() log("export ask") end }
package.loaded.page_chat = { post = function() end }

local hh = require("histhear")
hh.track_names = function() return { { "T-A", "Guitar" } } end
hh.describe = function() return "Brings back 1 item. Tracks: Guitar.", 1 end
hh.tempo_words = function(w, n) return w .. " (tempo too)", n end
hh.timeline_at = function() return nil end
hh.first_map = function() return nil end
local wr = require("webrestore")
local wm = require("webmixes")
local proj, cfg, b = "P1", { root = "C:/S", user = "James" }, { song = "Song", room = "main" }
local published = {}
local function pub(t, m) published[t] = m end

-- ---- pure: filters and rows --------------------------------------------------------------------------------------------------------------
do
  local f = wr.filter({ who = "Bo", kind = 99, track = string.rep("x", 200), text = "take", junk = 1 })
  assert(f.who == "Bo" and f.kind == 1 and f.track == "" and f.text == "take" and f.junk == nil, "a page's filter: checked, capped")
  local es = {
    ev("a1", "09:00:00", "Bo", { obj = "item", words = "Bo's take on Guitar", name = "Guitar" }),
    ev("a2", "09:01:00", "James", { obj = "track", gone = true, words = "deleted Bass", name = "Bass" }),
    ev("a3", "09:02:00", "James", { obj = "item", restored = "x", words = "brought back a take", name = "Guitar" }),
    ev("a4", "09:02:00", "James", { obj = "item", words = "moved it", name = "Guitar" }),
    ev("n1", "09:03:00", "Bo", { kind = "note", words = "a note" }),
    ev("p1", "09:04:00", "Bo", { obj = "item", auto = true, words = "a print" }),
  }
  local o = { describe = function(e) return e.words end, lane = function() return "" end, moment = function(i) return (i == 3 or i == 4) and { 3, 4 } or { i } end }
  local rows, more, users, tracks = wr.rows(es, wr.filter(), o)
  assert(#rows == 4 and more == 0, "every change but prints, one row for one act")
  assert(rows[1].id == "n1" and rows[1].undo == nil, "newest first; a note isn't undone on its own")
  assert(rows[2].id == "a4" and rows[2].n == 2 and rows[2].undo, "an act's row is its newest change, with how many were in it")
  assert(rows[3].id == "a2" and rows[3].tint == "gone" and rows[4].id == "a1" and rows[4].t, "a delete in red; times as seconds")
  assert(table.concat(users, ",") == "Bo,James" and table.concat(tracks, ",") == "Guitar,Bass", "the people and tracks to filter by")
  assert(#wr.rows(es, wr.filter({ who = "Bo" }), o) == 2, "one person's")
  assert(#wr.rows(es, wr.filter({ kind = 6 }), o) == 1, "deletes only")
  assert(#wr.rows(es, wr.filter({ track = "guitar" }), o) == 2, "one track's, any case")
  assert(#wr.rows(es, wr.filter({ text = "TAKE" }), o) == 1, "words in it (the act's newest row hides its older one)")
  local many = {}
  for i = 1, wr.ROWS_MAX + 5 do many[i] = ev("m" .. i, string.format("10:%02d:%02d", i // 60 % 60, i % 60), "Bo", { obj = "item", words = "w" }) end
  local r2, m2 = wr.rows(many, wr.filter(), { describe = o.describe, lane = o.lane, moment = function(i) return { i } end })
  assert(#r2 == wr.ROWS_MAX and m2 == 5, "at most ROWS_MAX rows, and how many more")
  assert(wr.find(es, "a2") == 2 and wr.find(es, "zz") == nil and wr.find(es, 5) == nil, "a change by its id")
  assert(wr.upto(es, { time = "2026-11-27T09:01:30Z" }) == 2 and wr.upto(es, { time = "2026-11-26T00:00:00Z" }) == 0, "where a saved version stands")
  local w = wr.undo_words(es, 1, "James", o.describe, { "Bo", "James" })
  assert(w:find("^Undo Bo's take on Guitar") and w:find("You, Bo changed it after this: undoing it takes their change back too", 1, true), "undo's words name who changed it after")
end

-- ---- asks, confirms, yes ------------------------------------------------------------------------------------------------------------------
ENTRIES = { ev("c1", "09:00:00", "Bo", { obj = "item", words = "Bo's take" }), ev("c2", "09:05:00", "James", { kind = "note", words = "a note" }) }
VERSIONS = { { file = "v1.json", time = "2026-11-27T09:01:00Z", label = "before solo", by = "Bo" }, { file = "v0.json", time = "2026-11-20T09:00:00Z", label = "old", by = "Bo" } }
local function act(a, h) here = h and 1 or 0; calls = {}; return require("webhistory").action(proj, cfg, b, { topic = "history", changes = a }) end
local function did(k) for _, c in ipairs(calls) do if c:find(k, 1, true) then return true end end end
do
  act({ undo = "c1" })
  local a = wr.S.ask
  assert(a and a.what == "undo" and a.words:find("Undo Bo's take", 1, true) and not did("undo_change"), "Undo asks first: nothing done on one message")
  act({ yes = a.id })
  assert(not did("undo_change") and wr.S.said:find("ran out", 1, true), "a yes without confirm = true is refused")
  act({ undo = "c1" }); a = wr.S.ask
  act({ yes = "nope", confirm = true })
  assert(not did("undo_change"), "a yes for another ask is refused")
  act({ undo = "c1" }); a = wr.S.ask
  clock = clock + wr.ASK_FOR + 1
  act({ yes = a.id, confirm = true })
  assert(not did("undo_change"), "a yes after the ask ran out is refused")
  act({ undo = "c1" }); a = wr.S.ask
  act({ yes = a.id, confirm = true }) -- (from another device, a phone: the same confirm is enough)
  assert(did("undo_change 1") and wr.S.ask == nil and wr.S.said == "undo_change said", "with its id and confirm: done, from a phone too")
  act({ yes = a.id, confirm = true })
  assert(not did("undo_change"), "an ask is used once")
  act({ undo = "c2" })
  assert(wr.S.ask == nil and wr.S.said:find("isn't undone on its own", 1, true), "a note can't be undone on its own")

  act({ restore = { to = "c1" } }); a = wr.S.ask
  assert(a.what == "whole" and a.words:find("Brings back 1 item", 1, true) and a.words:find("(tempo too)", 1, true) and did("plan 1"), "Restore the whole project: what changes, with the tempo map")
  DRIVER = "Bo"
  act({ yes = a.id, confirm = true })
  assert(not did("restore_whole") and wr.S.said:find("person in control", 1, true), "in control no longer: the yes is refused")
  act({ restore = { to = "c1" } })
  assert(wr.S.ask == nil, "not in control: no whole-project ask")
  act({ restore = { to = "c1", tracks = { "T-A" } } }); a = wr.S.ask
  assert(a.what == "tracks" and did("plan 1 scoped"), "chosen tracks: anyone, by each object's own rules")
  act({ yes = a.id, confirm = true })
  assert(did("restore_tracks 1"), "chosen tracks restored")
  for _, bad in ipairs({ {}, { "../x" }, { 5 }, { "T-" .. string.rep("a", 130) } }) do
    act({ restore = { to = "c1", tracks = bad } })
    assert(wr.S.ask == nil, "a track list that doesn't make sense is refused")
  end
  DRIVER = "James"
  act({ restore = { file = "v1.json" } }); a = wr.S.ask
  assert(a.what == "whole" and did("plan 1 v"), "a saved version: its own plan")
  act({ yes = a.id, confirm = true })
  assert(did("restore_whole 1"), "a saved version restored")
  act({ restore = { file = "v0.json" } })
  assert(wr.S.ask == nil and wr.S.said:find("older than every change", 1, true), "a version older than History can't be rebuilt")
  act({ restore = { file = "../../etc" } })
  assert(wr.S.ask == nil, "only a listed saved version")
end

-- ---- what's this computer only, saving, kept automation ---------------------------------------------------------------------------------
do
  act({ go = "c1" })
  assert(not did("show") and wr.S.said:find("studio's computer", 1, true), "Go to it from another device: refused")
  act({ go = "c1" }, true)
  assert(did("show c1"), "Go to it, here")
  act({ before = true })
  assert(not did("open"), "Open as before StudioSync from another device: refused")
  act({ before = true }, true)
  assert(did("cmd 40859") and did("open C:/before.rpp"), "here: a new tab with the copy")
  act({ save = { label = "chorus\nideas", keep = false } })
  assert(did("save chorus ideas"), "Save this version, its name cleaned (any device)")
  act({ save = { label = "", keep = true } })
  assert(did("backup nil"), "Save permanently")
  act({ letgo = "nope.json" })
  assert(wr.S.ask == nil, "Let it go: only kept automation that's there")
end

-- ---- the topic --------------------------------------------------------------------------------------------------------------------------
do
  clock = clock + 100
  act({ want = true, filter = { who = "Bo" } })
  wr.tick(proj, cfg, b, pub, clock)
  local m = published.hchanges
  assert(m and m.f.who == "Bo" and #m.rows == 1 and m.rows[1].id == "c1" and m.driver == true, "the topic: rows by the filter, in control")
  assert(#m.versions == 2 and m.versions[2].old == true and m.versions[1].old == nil and m.before == true, "saved versions, the old one marked; the copy from before StudioSync")
  assert(#m.kinds == #wr.KINDS and m.tracks_now[1][2] == "Guitar", "the kinds and the tracks now")
  published.hchanges = nil
  act({ want = false })
  wr.tick(proj, cfg, b, pub, clock + 10)
  assert(published.hchanges == nil, "nobody looking: nothing built")
end

-- ---- Mixes ------------------------------------------------------------------------------------------------------------------------------
do
  local list = wm.list({ "Song 2026-11-20 101010 Bo.wav", "notes.txt", "Song 2026-11-27 090000 James.wav" }, package.loaded.webhome.mix_of)
  assert(#list == 2 and list[1].name:find("2026%-11%-27") and list[1].who == "James", "mixes newest first, other files left out")
  assert(wm.pick(list, list[2].name) == list[2].name and wm.pick(list, "../x.wav") == nil and wm.pick(list, 3) == nil, "a file only from the list")
  local function mix(a, h) here = h and 1 or 0; calls = {}; return require("webhistory").action(proj, cfg, b, { topic = "history", mixes = a }) end
  for _, a in ipairs({ { render = true }, { stems = { dry = true } }, { copy = { wav = true } }, { ab = { play = "a" } } }) do
    mix(a)
    assert(#calls == 0 and wm.S.said:find("studio's computer", 1, true), "this computer only: " .. next(a))
  end
  mix({ render = true }, true)
  assert(did("script StudioSync - Final mix.lua") and did("cmd 777"), "Render current mix runs the panel's Final mix")
  mix({ stems = { dry = true } }, true)
  assert(did("stems true") and wm.S.said == "Stop recording first.", "stems: extras.stems, its words")
  mix({ bounce = { what = "folder", sel = true } })
  assert(did("bounce folder true"), "the idle computers, from any device")
  mix({ bounce = { what = "evil" } })
  assert(not did("bounce"), "only track, folder or mix")
  mix({ credits = true })
  assert(not did("url") and wm.S.said:find("credits.txt", 1, true), "credits from another device: written, not opened")
  mix({ credits = true }, true)
  assert(did("url C:/S/Song/credits.txt"), "here: opened too")
  mix({ template = { name = "" } })
  assert(wm.S.said:find("Give the template a name", 1, true), "a template needs a name")
  mix({ template = { name = string.rep("n", 81) } })
  assert(wm.S.said:find("Give the template a name", 1, true), "and not too long")
  mix({ template = { name = "Rock kit" } })
  assert(wm.S.said:find("Saved 'Rock kit'", 1, true), "Save as studio template")
  band.files = function() return { "Song 2026-11-20 101010 Bo.wav", "Song 2026-11-27 090000 James.wav" } end
  mix({ ab = { play = "a", a = "../../secret.wav", b = "Song 2026-11-27 090000 James.wav" } }, true)
  assert(not did("src") and wm.S.said:find("Pick the two mixes", 1, true), "A/B: a file not in the list is never played")
  mix({ ab = { play = "b", a = "Song 2026-11-20 101010 Bo.wav", b = "Song 2026-11-27 090000 James.wav" } }, true)
  assert(did("play C:/S/Song/mixes/Song 2026-11-27 090000 James.wav @0") and hh.P.gain == 0.5 and hh.P.key == "b", "A/B: B plays through REAPER, at the common loudness")
  hh.P.preview.pos = 42
  mix({ ab = { play = "a" } }, true)
  assert(did("stop C:/S/Song/mixes/Song 2026-11-27 090000 James.wav") and did("play C:/S/Song/mixes/Song 2026-11-20 101010 Bo.wav @42"), "switching keeps the place")
  wm.action(proj, cfg, b, { want = true }, true)
  wm.tick(proj, cfg, b, pub, clock + 20)
  local m = published.hmixes
  assert(m and #m.mixes == 2 and m.ab.play == "a" and m.ab.on and m.ab.pos == 42 and m.sws, "the topic: mixes, A/B playing where it is")
  mix({ ab = { stop = true } }, true)
  assert(hh.P.preview == nil and hh.P.pos == 42, "Stop keeps the place")
end

-- ---- Play through REAPER, Open this point in REAPER (histhear) ---------------------------------------------------------------------------
do
  local function hear(a, h) here = h and 1 or 0; calls = {}; return require("webhistory").action(proj, cfg, b, a) end
  hh.room(b)
  hh.S.slots["then"] = { state = "ready", path = "C:/tmp/then.opus", t = 5 }
  hear({ topic = "history", rplay = { slot = "then", pos = 3 } })
  assert(not did("preview") and hh.S.said:find("studio's computer", 1, true), "Play through REAPER from another device: refused (it'd play on the studio's speakers)")
  hear({ topic = "history", open = { t = 5 } })
  assert(not did("cmd"), "Open this point from another device: refused")
  hear({ topic = "history", rplay = { slot = "then", pos = 3 } }, true)
  assert(did("play C:/tmp/then.opus @3") and hh.P.key == "then", "here: the preview through SWS's player, from the place asked")
  local m = hh.rp_model()
  assert(m.key == "then" and m.pos == 3 and m.len == 100 and m.on, "its model for the page")
  hh.P.preview.pos = 99.99
  local _, on = hh.rp_pos()
  assert(not on and hh.P.pos == 0 and hh.P.preview == nil and did("destroy C:/tmp/then.opus"), "played to the end: stopped, freed, next play from the start")
  hear({ topic = "history", rplay = { slot = "now", pos = 0 } }, true)
  assert(not did("preview"), "a slot that isn't ready plays nothing")
  hear({ topic = "history", rplay = { slot = "then", pos = 500 } }, true)
  assert(did("play C:/tmp/then.opus @99.9"), "a place past the end: just before it")
  hear({ topic = "history", rstop = true })
  assert(hh.P.preview == nil and hh.P.path, "Stop: freed, place kept")
  local ok = pcall(function() hh.room({ song = "Other", room = "main" }) end)
  assert(ok and hh.P.path == nil, "another song: the player forgets")
  local cf = reaper.CF_CreatePreview
  rawset(reaper, "CF_CreatePreview", nil)
  assert(hh.rp_play("x", 0, "then") == "playing through REAPER needs SWS", "no SWS: said, nothing called")
  rawset(reaper, "CF_CreatePreview", cf)
end

-- ---- the page side, read as text ------------------------------------------------------------------------------------------------------------
do
  local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end
  local js = read("lib/webui/history.js")
  for _, s in ipairs({ "changes", "versions", "mixes" }) do assert(js:find("ssTabs.sub('history', '" .. s .. "'", 1, true), "History > " .. s .. " registered") end
  assert(js:find("yes: a.id, confirm: true", 1, true), "the page's yes carries the ask's id and confirm")
  assert(not js:find("innerHTML", 1, true) and not read("lib/webui/histhear.js"):find("innerHTML", 1, true), "names go in as text")
  assert(read("lib/webui/histhear.js"):find("rplay", 1, true), "histhear.js plays through REAPER")
  local wl = read("lib/webui.lua")
  assert(not wl:find("webrestore", 1, true), "webui.lua needs nothing new: History's actions and ticks go through webhistory")
end

print("ok")
