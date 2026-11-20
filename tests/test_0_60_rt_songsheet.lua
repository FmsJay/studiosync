-- The web UI's Sheet and Beat pages (lib/songsheet.lua): what a page may send, the per-section merge of everyone's files (the latest edit
-- wins, the losing version kept and shown, a link copy until its file arrives), the play position's line (one late tick moves nothing, the
-- same line isn't sent again), the beat map by REAPER's own tempo map, a count-in put on the link clock, building only while a page shows
-- them. Then a check of the page files. (James, rt)
package.path = "lib/?.lua;" .. package.path
local clock, ext, logged = 1000, {}, {}
local link = 1763500000 -- (the link clock: StudioSync_DirectNow)
local ps, playpos, cursor, rate, changes = 0, 0, 3, 1, 1
local markers = {
  { rgn = true, pos = 0, rend = 8, name = "Verse" },
  { rgn = true, pos = 8, rend = 16, name = "Chorus" },
  { rgn = false, pos = 9, rend = 9, name = "drop" },
  { rgn = true, pos = 4, rend = 6, name = "[claimed: Bee]" },
  { rgn = true, pos = 24, rend = 32, name = "Chorus" },
  { rgn = true, pos = 16, rend = 24, name = "" },
}
-- the tempo map: 4 bars of 4/4 at 120 (2 s a bar), then 3/4 at 120 (1.5 s a bar)
local function measure(m)
  if m < 4 then return m * 2, m * 4, nil, 4, 4 end
  return 8 + (m - 4) * 1.5, 16 + (m - 4) * 3, nil, 3, 4
end
reaper = setmetatable({
  time_precise = function() return clock end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  EnumProjectMarkers3 = function(_, i)
    local m = markers[i + 1]
    if not m then return 0 end
    return 1, m.rgn, m.pos, m.rend, m.name
  end,
  GetProjectLength = function() return 20 end,
  TimeMap_GetMeasureInfo = function(_, m) return measure(m) end,
  TimeMap2_QNToTime = function(_, qn) return qn <= 16 and qn / 2 or 8 + (qn - 16) / 2 end,
  format_timestr_pos = function(t)
    for m = 0, 1000 do local s = measure(m + 1); if s > t + 1e-9 then return (m + 1) .. ".1.00" end end
  end,
  GetProjectStateChangeCount = function() return changes end,
  GetPlayStateEx = function() return ps end,
  GetPlayPositionEx = function() return playpos end,
  GetCursorPositionEx = function() return cursor end,
  Master_GetPlayRate = function() return rate end,
  StudioSync_DirectNow = function() return link end,
  RecursiveCreateDirectory = function() return 1 end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
band.log = function(s) logged[#logged + 1] = s end
local fs = {}
band.write_json = function(path, t) fs[path] = band.json_decode(band.json_encode(t)) end
band.read_json = function(path) return fs[path] and band.json_decode(band.json_encode(fs[path])) end
band.files = function(dir, ext_)
  local out = {}
  for p in pairs(fs) do
    local d, f = p:match("^(.*)/([^/]+)$")
    if d == dir and f:sub(-#ext_) == ext_ then out[#out + 1] = f end
  end
  table.sort(out)
  return out
end
local sent = {}
package.loaded.direct = { send_live = function(_, kind, d, song, room, id) sent[#sent + 1] = { kind = kind, d = d, song = song, room = room, id = id } end }
local together = require("together")
local shared = 1763500000
together.start_at = function(lead) return shared + (lead or 0) end
together.now = function() return 5000 + clock end -- (another clock entirely: only differences are used)
local S = require("songsheet")

-- ---- what a page may send -------------------------------------------------------------------------------------------------------------
assert(S.id_ok("r:Chorus:2") and S.id_ok("r:a:b:1") and S.id_ok("h:k3x9") and not S.id_ok("h:../x") and not S.id_ok("x:1") and not S.id_ok("r:Chorus")
  and not S.id_ok("r:a\n:1") and not S.id_ok(5) and not S.id_ok("h:" .. ("a"):rep(200)), "ids: a region's or a hand-added one's, never anything else")
local v = S.clean({ id = "h:a1", name = "Bridge\nbit", text = "[Am]la\r\nla\1\tok", plays = "Bee: bass", bar = 9.7, ord = 2 })
assert(v.name == "Bridge bit" and v.text == "[Am]la\nla\tok" and v.plays == "Bee: bass" and v.bar == 9 and v.ord == 2 and not v.del, "cleaned: one-line name, newlines kept, controls gone, whole bar")
assert(S.clean({ id = "h:a1", text = ("x"):rep(S.TEXT_MAX + 1) }) == nil and S.clean({ id = "h:a1", text = 5 }) == nil and S.clean({ id = "nope" }) == nil
  and S.clean({ id = "h:a1", text = "\255\254" }) == nil, "too long, not text, not a section, not UTF-8: left out")
assert(S.clean({ id = "h:a1", bar = 0 / 0 }).bar == nil and S.clean({ id = "h:a1", bar = 1e9 }).bar == 9999 and S.clean({ id = "h:a1", del = true }).del, "bar NaN, clamped; delete")
assert(S.file_name("Bee Q/../x") == "Bee_Q____x.json", "a person's file name: only letters, digits, - and _")

-- ---- the regions and the merge ------------------------------------------------------------------------------------------------------------
local regions = S.read_regions("P")
local ids = {}
for _, r in ipairs(regions) do ids[#ids + 1] = r.id end
assert(table.concat(ids, ",") == "r:Verse:1,r:Chorus:1,r:Region 3:1,r:Chorus:2", "regions in order, claims and markers left out, the nth of a name, an unnamed one named: " .. table.concat(ids, ","))
local files = {
  James = { user = "James", sections = {
    ["r:Chorus:1"] = { name = "Chorus", text = "[C]James's words", plays = "", at = 100 },
    ["h:a"] = { name = "Outro", text = "fade", plays = "", bar = 12, at = 50 },
    ["h:gone"] = { name = "Old", text = "x", del = true, at = 60 },
    ["r:Intro:1"] = { name = "Intro", text = "a region that's gone", at = 40 },
  } },
  Bee = { user = "Bee", sections = {
    ["r:Chorus:1"] = { name = "Chorus", text = "Bee's words", plays = "Bee: bass", at = 120 },
    ["h:gone"] = { name = "Old", text = "y", at = 55 },
    ["h:b"] = { name = "Tag", text = "", at = 70, ord = 1 },
    ["h:c"] = { name = "Pre", text = "", at = 80, bar = 3 },
    ["bad id"] = { text = "ignored", at = 999 },
    ["r:Verse:1"] = "junk",
  } },
}
local m = S.merge(files, {}, regions)
local names = {}
for _, s in ipairs(m.sections) do names[#names + 1] = s.name end
assert(table.concat(names, ",") == "Verse,Chorus,Region 3,Chorus,Pre,Outro,Tag,Intro", "regions first in order (empty ones too), then the rest by start bar, then ord: " .. table.concat(names, ","))
local ch = m.sections[2]
assert(ch.id == "r:Chorus:1" and ch.region and ch.pos == 8 and ch.rend == 16 and ch.text == "Bee's words" and ch.by == "Bee" and ch.at == 120, "the latest edit wins the section")
assert(#ch.alts == 1 and ch.alts[1].by == "James" and ch.alts[1].text == "[C]James's words", "and the one it replaced is still there, with who wrote it")
assert(m.sections[1].text == "" and m.sections[1].by == nil and m.sections[1].alts == nil, "a region nobody wrote in")
for _, s in ipairs(m.sections) do assert(s.id ~= "h:gone", "deleted (the newest says so): gone, though an older version had words") end
assert(m.sections[8].id == "r:Intro:1" and m.sections[8].name == "Intro" and m.sections[8].text:find("gone"), "a region that's gone keeps its words, as a section of its own")
-- (a link copy, newer than the file: shown; an older one: not)
m = S.merge(files, { James = { ["r:Chorus:1"] = { name = "Chorus", text = "live", plays = "", at = 130 } }, Bee = { ["h:b"] = { text = "older", at = 10 } } }, regions)
assert(m.sections[2].text == "live" and m.sections[2].by == "James" and m.sections[2].alts[1].by == "Bee", "a newer link copy wins")
assert(m.sections[7].id == "h:b" and m.sections[7].text == "", "an older link copy doesn't")
assert(S.live_ok({ song = "S", user = "Bee", id = "h:b", v = { text = "hi", at = 5 } }, "James") == "Bee", "a bandmate's edit over the link")
assert(not S.live_ok({ song = "S", user = "James", id = "h:b", v = { text = "hi", at = 5 } }, "James") and not S.live_ok({ song = "S", user = "Bee", id = "../x", v = { at = 5 } }, "James")
  and not S.live_ok({ song = "S", user = "Bee", id = "h:b", v = { text = "hi" } }, "James") and not S.live_ok({ user = "Bee", id = "h:b", v = { at = 1 } }, "James"), "your own, a bad id, no stamp, no song: not")

-- ---- the play position's line --------------------------------------------------------------------------------------------------------
local phonerec = require("phonerec")
local list = {}
for i = 0, 9 do phonerec.add_reading(list, 100 + i * 0.03, 10 + i * 0.03 + (i == 4 and 0.02 or 0), 1, true) end
local fpos, frate = S.fit(list)
assert(math.abs(fpos - (10 + 0.27)) < 1e-9 and frate == 1, "fitted: one late tick moves nothing")
phonerec.add_reading(list, 101, 50, 1, true)
assert(math.abs(S.fit(list) - 50) < 1e-9, "a jump: a new stretch, only its own readings")
phonerec.add_reading(list, 101.1, 50, 1, false)
assert(S.fit(list) == nil, "stopped: no line")

-- ---- the tick: only while a page shows them ---------------------------------------------------------------------------------------
local cfg, b, P = { root = "R", user = "James" }, { song = "S", room = "main" }, "P1"
local pub, count = {}, {}
local function publish(topic, t)
  local s = band.json_encode(t)
  if pub[topic] ~= s then pub[topic] = s; count[topic] = (count[topic] or 0) + 1 end
end
local handlers = {}
S.reset()
S.tick(P, cfg, b, publish, handlers, clock)
assert(next(pub) == nil and handlers.sheet, "nobody showing them: nothing built (the link's handler is there)")
S.action(P, cfg, b, { topic = "sheet", want = true })
S.tick(P, cfg, b, publish, handlers, clock)
local bm = band.json_decode(pub.beatmap)
assert(#bm.b == 4 * 4 + 49 * 3 and bm.b[2] == 0.5 and bm.b[17] == 8 and bm.b[18] == 8.5, "every beat to the end and a minute on, by the map: " .. #bm.b)
assert(bm.bars[1][1] == 0 and bm.bars[1][2] == 1 and bm.bars[1][3] == 4 and bm.bars[5][1] == 16 and bm.bars[5][2] == 5 and bm.bars[5][3] == 3, "each bar's first beat, number, beats")
assert(#bm.regions == 4 and bm.regions[2].name == "Chorus" and bm.regions[2].pos == 8, "the regions, for the Beat page")
local beat = band.json_decode(pub.beat)
assert(not beat.playing and beat.pos == 3 and beat.at == link and beat.due == nil and beat.cin == nil, "stopped: the edit cursor")
assert(band.json_decode(pub.sheet).me == "James" and #band.json_decode(pub.sheet).sections == 4, "the sheet: the regions, nobody's words yet")

-- an edit: my file, sent to those here
clock = clock + 1
shared = shared + 1
local said = S.action(P, cfg, b, { topic = "sheet", set = { id = "r:Verse:1", text = "[G]Hello", plays = "Bee: bass" } })
assert(said == nil and fs["R/S/sheet/James.json"].user == "James" and fs["R/S/sheet/James.json"].sections["r:Verse:1"].text == "[G]Hello"
  and fs["R/S/sheet/James.json"].sections["r:Verse:1"].at == shared, "saved in your own file, stamped with the shared clock")
assert(#sent == 1 and sent[1].kind == "sheet" and sent[1].d.id == "r:Verse:1" and sent[1].d.user == "James" and sent[1].song == "S", "and sent over the link")
S.action(P, cfg, b, { topic = "sheet", set = { id = "h:x", name = "B", text = "y" } })
assert(fs["R/S/sheet/James.json"].sections["r:Verse:1"] and fs["R/S/sheet/James.json"].sections["h:x"], "another section: added to the same file")
assert(S.action(P, cfg, b, { topic = "sheet", set = { id = "../../x" } }):find("left out") and #sent == 2, "a made-up section: nothing written or sent")
S.tick(P, cfg, b, publish, handlers, clock)
local sh = band.json_decode(pub.sheet)
assert(sh.sections[1].text == "[G]Hello" and sh.sections[1].by == "James" and sh.sections[5].id == "h:x", "shown at once")
-- a bandmate's, over the link, then their file
handlers.sheet({ song = "S", user = "Bee", id = "r:Verse:1", v = { name = "Verse", text = "Bee live", at = shared + 5 } })
S.tick(P, cfg, b, publish, handlers, clock)
sh = band.json_decode(pub.sheet)
assert(sh.sections[1].text == "Bee live" and sh.sections[1].by == "Bee" and sh.sections[1].alts[1].text == "[G]Hello", "a bandmate's edit shows at once; yours kept under it")
fs["R/S/sheet/Bee.json"] = { user = "Bee", sections = { ["r:Verse:1"] = { name = "Verse", text = "Bee file", at = shared + 6 } } }
fs["R/S/sheet/Eve.json"] = { user = "Mallory", sections = { ["r:Verse:1"] = { text = "not hers", at = shared + 99 } } }
clock = clock + S.READ_EVERY
S.tick(P, cfg, b, publish, handlers, clock)
sh = band.json_decode(pub.sheet)
assert(sh.sections[1].text == "Bee file", "their file caught up: the link copy goes (and a file saying it's someone else's is ignored)")

-- the line: playing, sent again only when it moves off it
ps, playpos = 1, 20
local n0 = count.beat
for i = 1, 20 do
  clock, link, playpos = clock + 0.03, link + 0.03, playpos + 0.03 + (i == 10 and 0.04 or 0)
  S.tick(P, cfg, b, publish, handlers, clock)
end
beat = band.json_decode(pub.beat)
assert(beat.playing and beat.rate == 1 and math.abs(beat.pos + (link - beat.at) - playpos) < 0.002, "playing: the line puts the position where it is")
assert(count.beat - n0 <= 3, "the same line isn't sent again each tick: " .. (count.beat - n0))
-- a start together: its count-down and count-in on the link clock
clock, link = clock + 0.03, link + 0.03
ext[band.SECTION .. "/together_at P1"] = tostring(together.now() + 4)
ext[band.SECTION .. "/together_from P1"] = string.format("%.6f %.6f %.6f", 12, 2, together.now() + 4)
S.tick(P, cfg, b, publish, handlers, clock)
beat = band.json_decode(pub.beat)
assert(math.abs(beat.due - (link + 4)) < 1e-3 and beat.cin.to == 12 and beat.cin.len == 2 and math.abs(beat.cin.fire - (link + 4)) < 1e-3, "the start's moment, on the link clock")
local n1 = count.beat
clock, link, playpos = clock + 0.03, link + 0.03, playpos + 0.03
S.tick(P, cfg, b, publish, handlers, clock)
assert(count.beat == n1, "worked out once, not sent again each tick")
-- no longer shown
clock = clock + S.WANT_FOR + 1
local n2 = count.beat
S.tick(P, cfg, b, publish, handlers, clock + 1)
assert(count.beat == n2, "the page went: nothing built")
assert(require("webui").ACTIONS.sheet, "sheet: a topic the pages may send")

-- ---- the page files ---------------------------------------------------------------------------------------------------------------------
local function read(path) local f = assert(io.open(path, "rb")); local s = f:read("a"); f:close(); return s end
local index = read("lib/webui/index.html")
for _, f in ipairs({ "beat.js", "sheet.js", "visuals.js", "sheet.css" }) do
  assert(index:find('"' .. f .. '"', 1, true), "index.html links " .. f)
  local s = read("lib/webui/" .. f)
  assert(not s:find("innerHTML") and not s:find("eval%(") and not s:find("https?://[%w]"), f .. ": no HTML from data, no eval, nothing fetched from elsewhere")
end
assert(index:find('"tabs.js"', 1, true) < index:find('"beat.js"', 1, true) and index:find('"beat.js"', 1, true) < index:find('"sheet.js"', 1, true), "after tabs.js; beat.js before the pages")
assert(read("lib/webui/sheet.js"):find("ssTabs.act('sheet'", 1, true) and read("lib/webui/beat.js"):find("ssTabs.act('sheet'", 1, true), "the pages send on their own topic")
print("ok")
