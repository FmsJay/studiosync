-- rt-ui7 (Phase 7 of docs/rt/ui-web-plan.md): the Project page's View / Edit switch on Live sync's side, and what REAPER-likeness adds to
-- the daw topic. lib/dawedit.lua and lib/dawmidi.lua refuse every edit (items and markers; notes and controllers; envelope points and
-- automation items; sends) that doesn't carry the page's `edit = true`, before asking REAPER anything, and answer the page why; with it they
-- go on to their own checks. dawview.build's track heights, fixed-lane rows and the ruler's format; dawview.ruler_mode against a stand-in
-- format_timestr_pos. And a link check of the page files: daw.js's gate, the switch, the idle and the reopen; the piano roll's, the lanes'
-- and the Mixer's guards. (James, rt)
package.path = "lib/?.lua;" .. package.path
local ext, calls, stop = {}, {}, false
reaper = setmetatable({
  time_precise = function() return 1000 end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() calls[#calls + 1] = k; if stop then error("stand-in: asked") end return "" end end end })
local band = require("band")
band.log = function() end
local dawedit, dawmidi, dawview = require("dawedit"), require("dawmidi"), require("dawview")
local cfg, b = { root = "R", user = "James" }, { song = "S", room = "main" }

-- ---- no flag: refused, nothing asked of REAPER, the page told why ------------------------------------------------------------------------
local ITEM = { lane = 0, idx = 0, p = 4, l = 8 }
local edits = {
  { op = "move", lane = 1, idx = 0, p = 4, l = 2, to = 6 }, { op = "split", lane = 0, idx = 0, p = 0, l = 4 }, { op = "delete", lane = 0, idx = 0, p = 0, l = 4 },
  { op = "fade", lane = 0, idx = 0, p = 0, l = 4, side = "in", len = 1 }, { op = "add_marker", at = 3, name = "" }, { op = "delete_marker", i = 2, r = true, p = 3 },
}
for n, e in ipairs(edits) do
  e.id = "e" .. n
  assert(dawedit.parse(e), "a well-formed edit: #" .. n)
  calls = {}
  local said = dawedit.action("P", cfg, b, e)
  assert(#calls == 0, "no flag: REAPER not asked anything (" .. table.concat(calls, ",") .. ")")
  local r = dawedit.reply
  assert(r.id == "e" .. n and not r.ok and r.why == dawedit.VIEW_WHY and said:find("wasn't made", 1, true), "no flag: refused with why, for the page that sent it: #" .. n)
  e.edit = "true"
  calls = {}
  dawedit.action("P", cfg, b, e)
  assert(#calls == 0 and dawedit.reply.why == dawedit.VIEW_WHY, "only the boolean true counts: #" .. n)
end
local kinds = {
  { "note", { id = "n1", op = "add", item = ITEM, k = 72, a = 4.6, z = 4.9, v = 110, g = 0.5 } },
  { "auto", { id = "a1", op = "add", lane = 0, e = 1, name = "Pan", t = 3.2, v = 1 } },
  { "send", { id = "s1", op = "vol", lane = 0, to = 1, i = 0, v = 0.5 } },
}
for _, ke in ipairs(kinds) do
  local k, e = ke[1], ke[2]
  calls = {}
  local said = dawmidi.action("P", cfg, b, { [k] = e })
  assert(#calls == 0, k .. " without the flag: REAPER not asked anything (" .. table.concat(calls, ",") .. ")")
  assert(dawedit.reply.id == e.id and not dawedit.reply.ok and dawedit.reply.why == dawedit.VIEW_WHY and said:find("wasn't made", 1, true), k .. ": refused with why")
end
-- (a look isn't an edit: it needs no flag)
dawmidi.action("P", cfg, b, { look = { send = 1 } })
assert(dawedit.reply.id == "s1", "a look answers nothing")
-- (a bad edit is still refused for being bad, flag or not)
assert(select(2, dawedit.parse({ op = "nope" })) and not dawedit.edit_flag(nil) and not dawedit.edit_flag({}) and dawedit.edit_flag({ edit = true }), "the flag test")

-- ---- with the flag: on to the edit's own checks (here REAPER gets asked, and the stand-in stops it there; tests/test_0_60_rt_dawedit.lua and
-- test_0_60_rt_dawmidi.lua apply flagged edits to their stand-in projects) --------------------------------------------------------------
stop = true
for n, e in ipairs(edits) do
  e.edit = true
  calls = {}
  pcall(dawedit.action, "P", cfg, b, e)
  assert(#calls > 0, "with the flag: the edit goes on: #" .. n)
end
for _, ke in ipairs(kinds) do
  local k, e = ke[1], ke[2]
  e.edit = true
  calls = {}
  pcall(dawmidi.action, "P", cfg, b, { [k] = e })
  assert(#calls > 0, k .. " with the flag: the edit goes on")
end
stop = false

-- ---- REAPER-likeness in the topic: heights, fixed-lane rows, the ruler's format -------------------------------------------------------
assert(dawview.lane_rows({ { lane = 0 }, { lane = 0 } }) == nil and dawview.lane_rows({}) == nil and dawview.lane_rows({ { pos = 1 } }) == nil, "one row or none: a plain track")
local at, nl = dawview.lane_rows({ { lane = 3 }, { lane = 1 }, { lane = 3 } })
assert(nl == 2 and at[1] == 0 and at[3] == 1, "rows in REAPER's lane order")
local raw = { key = "S/main", len = 30, bars = {}, sigs = {}, tempo = {}, grid = 0.25, rf = 0, markers = {}, tracks = {
  { name = "Gtr", depth = 0, h = 120.4, items = { { pos = 0, len = 4, lane = 2, peaks = "00" }, { pos = 0, len = 4, lane = 0, peaks = "00" } } },
  { name = "Bass", depth = 0, h = 0, items = { { pos = 0, len = 4, peaks = "00" } } },
} }
local head, chunks = dawview.build(raw)
assert(head.tracks[1].h == 120 and head.tracks[2].h == nil, "a track's height in px; none when REAPER says 0 (a collapsed folder's)")
assert(head.tracks[1].nl == 2 and head.tracks[2].nl == nil, "rows on a track with two lanes shown")
local tr1 = chunks[1].t.tr[1]
assert(tr1[1].ln == 1 and tr1[2].ln == 0 and chunks[1].t.tr[2][1].ln == nil, "each item's row")
assert(head.rf == 0, "the ruler's format goes in the header")
local sig1 = chunks[1].sig
raw.tracks[1].items[1].lane = 1
assert(select(2, dawview.build(raw))[1].sig ~= sig1, "a lane change resends the chunk")
-- the ruler: REAPER's own format matched against the modes
local fmt = { [0] = "1:01.250", [1] = "31.1.00 / 1:01.250", [2] = "31.1.00", [3] = "61.250", [4] = "2940000", [5] = "0:01:01:07" }
for own = 0, 5 do
  reaper.format_timestr_pos = function(t, _, m) assert(t == 61.25); return m == -1 and fmt[own] or fmt[m] end
  assert(dawview.ruler_mode() == own, "the ruler in mode " .. own)
end
reaper.format_timestr_pos = function(_, _, m) return m == -1 and "1001" or "x" end
assert(dawview.ruler_mode() == nil, "a format it doesn't name (absolute frames): nil, the page's default")
reaper.format_timestr_pos = function() return nil end
assert(dawview.ruler_mode() == nil, "no answer: nil")
reaper.format_timestr_pos = nil

-- ---- the page files ---------------------------------------------------------------------------------------------------------------------
local function read(path) local f = assert(io.open(path, "rb"), path); local s = f:read("a"); f:close(); return s end
local daw, pr, al, mx, css, tabs = read("lib/webui/daw.js"), read("lib/webui/pianoroll.js"), read("lib/webui/autolanes.js"), read("lib/webui/mixer.js"), read("lib/webui/daw.css"), read("lib/webui/tabs.js")
for _, want in ipairs({ "const EDITS = ['edit', 'note', 'auto', 'send'];", "if (!editing) return Promise.reject(new Error('View'));", "{ edit: true }",
    "let editing = false", "q('.dbar').prepend(modeSwitch(page));", "addEventListener('ss-route'", "if (t !== 'project' || routeTab !== 'project') setEdit(false);",
    "window.ssDaw.EDIT_IDLE_MS", "EDIT_IDLE_MS: 5 * 60 * 1000", "'Back to View: 5 minutes without an edit.'", "if (!editing) return; // (View:", "if (pend || !editing) return;",
    "'Editing: changes go to everyone'", "Follow <select" }) do
  assert(daw:find(want, 1, true), "daw.js has " .. want)
end
assert(not daw:find(">View <select", 1, true), "the follow select is Follow, not View (the switch is View)")
assert(pr:find("if (!ssDaw.editing()) { say(ssDaw.VIEW_SAY); return; }", 1, true) and pr:find("ssDaw.onEdit(", 1, true) and pr:find("!M || !ssDaw.editing()", 1, true), "the piano roll is read only in View")
assert(al:find("if (!ssDaw.editing()) { ssDaw.say(ssDaw.VIEW_SAY); return; }", 1, true) and al:find("ssDaw.laneH", 1, true), "the lanes send nothing in View")
assert(mx:find("ssDaw.modeSwitch(page)", 1, true) and mx:find("{ edit: true }", 1, true) and mx:find("if (!editing())", 1, true), "the Mixer shows the switch and sends the flag")
assert(css:find(".ssediting", 1, true) and css:find(".song:not(.ssediting) .dedit .eonly", 1, true), "the orange frame, and the edit row's changing controls only in Edit")
assert(tabs:find("POP.add('project/arrange')", 1, true), "the arrange can pop out")
print("ok rt ui7")
