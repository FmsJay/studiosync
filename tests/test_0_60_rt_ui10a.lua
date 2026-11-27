-- Plug-ins in the web UI (rt-ui10a: docs/rt/ui-web-plan.md Phase 10a; findings items 3, 4, 10 and the Try notification). Covers: This project's
-- rows (who lacks each plug-in, JSFX, the studio's stand-in), Find's rows (search, category, only what everyone has, the cap), the pack's
-- model, a drum map from a page (name cleaned, notes clamped, General MIDI where none came); every change refused from another device with
-- nothing run (stand-ins, drum maps, the folder, the installer, Add), and run from this computer's page through the panel's own functions;
-- the Try tab's asks a phone may and may not send; the topic built only while a page shows a sub; webui's wiring and the page files. No
-- REAPER: a stand-in. Lupa, repo root.
package.path = "lib/?.lua;" .. package.path
local clock = 1000
local TR = {
  { name = "Drums", ext = {}, fx = {} }, { name = "Bass", ext = {}, fx = {} }, master = { name = "MASTER", ext = {}, fx = {} },
}
local selected, added, shown = { TR[1] }, {}, {}
local installed = { "VST3: Superior Drummer 3 (Toontrack)", "VST3: ReaEQ (Cockos)", "VSTi: Surge XT (Surge Synth Team)", "JS: Utility/volume" }
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetResourcePath = function() return "C:/res" end,
  RecursiveCreateDirectory = function() return 1 end,
  CountSelectedTracks = function() return #selected end,
  GetSelectedTrack = function(_, i) return selected[i + 1] end,
  GetSelectedTrack2 = function(_, i) return selected[i + 1] end,
  GetMasterTrack = function() return TR.master end,
  GetTrackName = function(tr) return true, tr.name end,
  GetSetMediaTrackInfo_String = function(tr, key, v, set)
    local k = key:gsub("^P_EXT:", "")
    if set then tr.ext[k] = v end
    return true, tr.ext[k] or ""
  end,
  EnumInstalledFX = function(i) local n = installed[i + 1]; if n then return true, n, n:gsub("^%w+:%s*", "") .. ".dll" end return false end,
  TrackFX_AddByName = function(tr, name) added[#added + 1] = { tr = tr, name = name }; return 0 end,
  TrackFX_Show = function(tr, idx, flag) shown[#shown + 1] = { tr = tr, idx = idx, flag = flag } end,
}, { __index = function() return function() return "" end end })
local band = require("band")
local wrote, maps = {}, { "Superior.json" }
band.write_json = function(path, t) wrote[#wrote + 1] = { path = path, t = t } end
band.files = function(dir) return dir:find("drummaps$") and maps or {} end
package.loaded.mirror = { hash = function(s) return "H" .. #s end }
local applied, drum_applied = 0, {}
local TMAP = {}
package.loaded.page_plugins = {
  used = function() return {
    { key = "superior drummer 3 (toontrack)", name = "VST3: Superior Drummer 3 (Toontrack)", tracks = { "Drums" } },
    { key = "serum (xfer records)", name = "VST3: Serum (Xfer Records)", tracks = { "Bass", "Lead" } },
    { key = "utility/volume", name = "JS: Utility/volume", tracks = { "Master" } },
  } end,
  translations = function() return TMAP end,
  apply_here = function() applied = applied + 1; return 2 end,
  apply_drum_track = function(tr) drum_applied[#drum_applied + 1] = tr end,
}
local plugins = require("plugins")
local folder_runs = 0
plugins.lists = function() return { { user = "James", names = { "superior drummer 3 (toontrack)", "reaeq (cockos)" } }, { user = "Bo", names = { "serum (xfer records)", "reaeq (cockos)" } } } end
plugins.band = function() return { ["reaeq (cockos)"] = true }, { "James", "Bo" } end
plugins.publish = function() folder_runs = folder_runs + 1; return 3 end
plugins.update_folder = function() return 1, nil, { "James", "Bo" } end
local pack = require("pack")
local got = {}
pack.get = function(extras) got[#got + 1] = extras; return true end
pack.status = function() return { pack = { have = 10, total = 11, missing = { "Dexed" } }, extras = { have = 0, total = 8, missing = { "Odin 2" } },
  others = { Dexed = { "Bo" } }, here = { ["Surge XT"] = true } } end

local W = require("webplugins")
local cfg, b = { root = "S", user = "James" }, { song = "Song", room = "main" }

-- ---- 1. the models (pure) -----------------------------------------------------------------------------------------------------------------
local lists = { { user = "James", set = { a = true, ["x.jsfx"] = true } }, { user = "Bo", set = {} } }
local rows = W.project_model({ { key = "a", name = "VST3: A", tracks = { "T1" } }, { key = "x.jsfx", name = "JS: x.jsfx", tracks = {} }, { key = "c", name = "CLAP: C", tracks = {} } },
  lists, { c = { key = "c", to = "VST3: Close (Maker)", by = "Bo" } })
assert(rows[1].name == "A" and rows[1].missing[1] == "Bo" and #rows[1].missing == 1 and not rows[1].js, "who lacks it, the format prefix gone")
assert(rows[2].js and rows[3].standin.to == "Close (Maker)" and rows[3].standin.by == "Bo" and #rows[3].missing == 2, "JSFX, the stand-in and who set it")
local items = require("fxpick").list({ { name = "VST3: ReaEQ (Cockos)", ident = "reaeq.vst3" }, { name = "VSTi: Surge XT (Surge Synth Team)", ident = "surge.dll" },
  { name = "JS: Utility/volume", ident = "Utility/volume" } }, "", { ["reaeq (cockos)"] = true })
local r, n = W.find_rows(items, { q = "", cat = "All", only = true }, 10)
assert(n == 2 and r[1].label == "ReaEQ (Cockos)" and r[1].everyone and r[2].label == "Utility/volume", "only what everyone has: ReaEQ and the JSFX")
r, n = W.find_rows(items, { q = "", cat = "Instruments", only = false }, 10)
assert(n == 1 and r[1].label == "Surge XT (Surge Synth Team)" and not r[1].everyone and r[1].cats == "Instruments", "a category, all of mine")
r, n = W.find_rows(items, { q = "", cat = "All", only = false }, 1)
assert(#r == 1 and n == 3, "the cap, with how many matched")
local pm = W.pack_model(pack.status(), pack.ITEMS, true)
assert(pm.pack.have == 10 and pm.others[1].name == "Dexed" and pm.others[1].who[1] == "Bo", "the pack's counts and what others have")
local by = {}
for _, it in ipairs(pm.items) do by[it.name] = it end
assert(by["Surge XT"].here and by["Neural Amp Modeler"].none and by.sforzando.alt == "sfizz" and by["Odin 2"].extras, "here, no Linux version, its Linux stand-in, extras")
local name, notes = W.map_from({ name = "Superior / Drummer!", notes = { kick = 200, snare = "40", hihat_open = -3 } })
assert(name == "Superior  Drummer" and notes.kick == 127 and notes.snare == 40 and notes.hihat_open == 0 and notes.crash == require("drummap").GM.crash, "a map: name cleaned, notes clamped, GM where none came")
assert(not W.map_from({ name = "GM" }) and not W.map_from({ name = "!!" }) and not W.map_from({ name = "con" }) and not W.map_from("x"), "no name, gm, a Windows name: refused")
assert(W.try_refused({ try = { user = "Bo", key = "x" } }, false):find("refused", 1, true) and W.try_refused({ keep = 1 }, false) and W.try_refused({ print = 1 }, false)
  and W.try_refused({ stop = 1 }, false), "another device can't try, add to track, print or stop")
for _, a in ipairs({ { set = { id = 1, p = 0, v = 0.5 } }, { knobs = { id = 1, page = 1 } }, { allow = 5 }, { refuse = 5 }, { end_use = 5 }, { want = true }, { q = "ser" } }) do
  assert(W.try_refused(a, false) == nil, "a phone may turn knobs, search, and answer asks for your own plug-ins")
end
assert(W.try_refused({ try = { user = "Bo", key = "x" } }, true) == nil, "this computer's page may try")

-- ---- 2. from another device: refused, nothing runs ----------------------------------------------------------------------------------------
local REMOTE = { { apply = true }, { standin = { key = "serum (xfer records)", to = installed[3] } }, { unstandin = "serum (xfer records)" }, { drum = { from = "gm" } },
  { map = { name = "Kit", notes = {} } }, { folder = true }, { get = "pack" }, { add = "reaeq (cockos)" } }
local removed = {}
local real_remove = os.remove
os.remove = function(p) removed[#removed + 1] = p; return true end
for _, a in ipairs(REMOTE) do
  local said = W.action("P1", cfg, b, a, false)
  assert(said and said:find("refused: only from this computer's own page", 1, true), "refused from another device: " .. next(a))
end
assert(applied == 0 and #wrote == 0 and #removed == 0 and #drum_applied == 0 and folder_runs == 0 and #got == 0 and #added == 0 and TR[1].ext.band_drum_from == nil, "and nothing ran")
assert(W.action("P1", cfg, b, { find = { q = "eq", cat = "All", only = false } }, false) == nil and W.action("P1", cfg, b, { pick = "sur" }, false) == nil, "searching changes nothing: any page")

-- ---- 3. from this computer's page: the panel's own functions ---------------------------------------------------------------------------------
assert(W.action("P1", cfg, b, { apply = true }, true):find("2 stand-in", 1, true) and applied == 1, "Apply stand-ins here")
assert(W.action("P1", cfg, b, { standin = { key = "serum (xfer records)", to = installed[3] } }, true):find("Serum", 1, true), "a stand-in set")
local w = wrote[#wrote]
assert(w.path == "S/plugins/translations/H20.json" and w.t.key == "serum (xfer records)" and w.t.to == installed[3] and w.t.from == "VST3: Serum (Xfer Records)" and w.t.by == "James",
  "written where page_plugins reads it, as the panel writes it")
assert(W.action("P1", cfg, b, { standin = { key = "serum (xfer records)", to = "VST3: Not Installed" } }, true):find("not set", 1, true) and #wrote == 1, "only a plug-in installed here")
assert(W.action("P1", cfg, b, { standin = { key = "nothing here", to = installed[3] } }, true):find("not set", 1, true) and #wrote == 1, "only a plug-in in this project")
TMAP["serum (xfer records)"] = { key = "serum (xfer records)", from = "VST3: Serum (Xfer Records)", to = installed[3] }
assert(W.action("P1", cfg, b, { unstandin = "serum (xfer records)" }, true):find("removed the stand-in for Serum", 1, true) and removed[1] == "S/plugins/translations/H20.json", "a stand-in removed")
assert(W.action("P1", cfg, b, { unstandin = "nope" }, true):find("no stand-in", 1, true) and #removed == 1, "only a stand-in there is")
os.remove = real_remove
selected = { TR[1], TR[2] }
assert(W.action("P1", cfg, b, { drum = { from = "gm", to = "Superior" } }, true):find("2 tracks", 1, true), "drum maps on the selected tracks")
assert(TR[1].ext.band_drum_from == "gm" and TR[2].ext.band_drum_to == "Superior" and #drum_applied == 2, "set on each, and the effect made true")
assert(W.action("P1", cfg, b, { drum = { to = "../../evil" } }, true):find("no drum map", 1, true) and TR[1].ext.band_drum_to == "Superior", "only a map there is")
assert(W.action("P1", cfg, b, { drum = { to = "" } }, true) and TR[1].ext.band_drum_to == "" and TR[1].ext.band_drum_from == "gm", "not set again; the other choice kept")
selected = {}
assert(W.action("P1", cfg, b, { drum = { from = "gm" } }, true):find("Select a drum track", 1, true), "no track selected")
assert(W.action("P1", cfg, b, { map = { name = "Kit 2", notes = { kick = 24 } } }, true) == "drum map saved: Kit 2", "a map saved")
assert(wrote[#wrote].path == "S/drummaps/Kit 2.json" and wrote[#wrote].t.notes.kick == 24 and wrote[#wrote].t.by == "James", "in the studio's drummaps")
assert(W.action("P1", cfg, b, { map = { name = "gm" } }, true) == "Give it the plug-in's name.", "gm is built in")
assert(W.action("P1", cfg, b, { folder = true }, true):find("1 plug-ins everyone has (lists from James, Bo)", 1, true) and folder_runs == 1, "Update the folder now")
assert(W.action("P1", cfg, b, { get = "extras" }, true):find("installer opened", 1, true) and got[1] == true, "Get the extras")
assert(W.action("P1", cfg, b, { add = "reaeq (cockos)" }, true):find("Select a track first", 1, true) and #added == 0, "Add needs a track")
selected = { TR.master }
assert(W.action("P1", cfg, b, { add = "reaeq (cockos)" }, true) == "ReaEQ (Cockos) added to MASTER" and added[1].tr == TR.master and added[1].name == installed[2]
  and shown[1].flag == 3, "Add: on the selected track (the master too), its window open")
assert(W.action("P1", cfg, b, { add = "not here" }, true):find("isn't on this computer", 1, true) and #added == 1, "only one of this computer's")

-- ---- 4. the topic: only while a page shows a sub ----------------------------------------------------------------------------------------------
W._reset()
local published = {}
local function publish(t, v) published[t] = v end
W.tick("P1", cfg, b, publish, clock)
assert(published.plugins == nil, "nobody looking: nothing built")
W.action("P1", cfg, b, { want = true }, false)
W.tick("P1", cfg, b, publish, clock)
local m = published.plugins
assert(m and not m.error, "built while a page shows one: " .. tostring(m and m.error))
assert(#m.project == 3 and m.project[2].missing[1] == "James" and m.project[3].js and m.people[2] == "Bo", "This project")
assert(m.drums.n == 1 and m.drums.maps[1] == "gm" and m.drums.maps[2] == "Superior" and #m.drums.kit == #require("drummap").KIT, "drum maps: the selected track, the maps, the kit")
assert(m.find.master and m.find.target == "Master" and m.find.only == true and m.find.cats[1] == "All", "Find: the master selected, Only comes on")
assert(m.pack.extras.total == 8 and m.folder == plugins.FOLDER and m.pick == nil and m.os == "win", "the pack, the folder, no picker open")
W.action("P1", cfg, b, { pick = "surge" }, true)
published = {}
W.tick("P1", cfg, b, publish, clock + 1)
assert(published.plugins and published.plugins.pick.total == 1 and published.plugins.pick.names[1] == installed[3], "the stand-in picker's search")
published = {}
W.tick("P1", cfg, b, publish, clock + 2)
assert(published.plugins == nil, "at most every " .. W.EVERY .. " s")
W.tick("P1", cfg, b, publish, clock + 1 + W.WANT_FOR)
assert(published.plugins == nil, "the page stopped saying it shows: no more builds")
package.loaded.page_plugins.used = function() error("boom") end
clock = clock + 100
W.action("P1", cfg, b, { want = true }, true)
W.tick("P1", cfg, b, publish, clock)
assert(published.plugins and published.plugins.error:find("boom", 1, true), "a failure is said, not thrown")

-- ---- 5. the wiring and the page files -----------------------------------------------------------------------------------------------------
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end
local wl = read("lib/webui.lua")
assert(wl:find('webui.ACTIONS.plugins = true', 1, true) and wl:find('require("webplugins").action(proj, cfg, b, a, reaper.StudioSync_WebUIPollHere', 1, true)
  and wl:find('require("webplugins").try_refused(a, reaper.StudioSync_WebUIPollHere', 1, true) and wl:find('require("webplugins").tick(proj, cfg, b, publish, now)', 1, true),
  "webui: the topic the pages may send, its handler with whether the page is here, the Try gate, the tick")
local js = read("lib/webui/tryfx.js")
assert(not js:find("innerHTML") and not js:find("eval%(") and not js:find("https?://[%w]"), "tryfx.js: no HTML from data, no eval, nothing from elsewhere")
for _, s in ipairs({ "ssTabs.sub('plugins', 'project'", "ssTabs.sub('plugins', 'find'", "ssTabs.sub('plugins', 'pack'", "{ envs: HERE }", "ssTabs.act('plugins'",
    "E.pop === 'plugins'", "E.send('win:full')", "Show its window", "{ keep: t.id }" }) do
  assert(js:find(s, 1, true), "tryfx.js has " .. s)
end
assert(read("lib/webui/tryfx.css"):find("body.sspop.tfpoptab", 1, true), "the pop-out of the whole tab keeps its sub-tabs")
assert(read("lib/webui/tabs.js"):find("'plugins/project', 'plugins/find', 'plugins/pack'", 1, true), "the subs can pop out")
print("ok: Plug-ins in the web UI (This project, Find, pack; refused from other devices)")
