-- rt-nohold (James, 2026-11-20: "I think hold my changes might be working against us, might be better to just remove it. Someone can go into a
-- different room to test, especially now that changes come so fast now."). Hold my changes is gone:
--   1. a project opening with ProjExtState "hold" set ("1", or a colour try's "try"/"try1") has it cleared, says so once, and what it held goes
--      out in that look;
--   2. trying a colour look sends nothing while it's tried, and holds nothing else back (an edit elsewhere, an edit to a tried track, a marker
--      added); Keep sends the look; Put back sends nothing; REAPER stopping mid-try puts the look back on the next opening, nothing sent;
--   3. no code reads ProjExtState "hold" but the opening's clearing (mirror.on_open).
-- Two computers in the chunk-faithful stand-in REAPER (tests/fixtures/editreaper.lua), each with its own ExtState. Lua 5.4, from the repo root.
package.path = "lib/?.lua;tests/fixtures/?.lua;" .. package.path
local E = require("editreaper")
local f = E.f

local real_date, real_time = os.date, os.time
local now_t = real_time({ year = 2026, month = 11, day = 20, hour = 15, min = 0, sec = 0 })
os.date = function(fmt, t) return real_date(fmt, t or now_t) end
os.time = function(t) if t then return real_time(t) end; return now_t end
local function tick(n) now_t = now_t + (n or 2) end

local files, logged = {}, {}
local band = require("band")
local proxy = setmetatable({}, { __index = band })
proxy.read_json = function(path) local v = files[path]; if type(v) == "table" then return band.json_decode(band.json_encode(v)) end end
proxy.write_json = function(path, v) files[path] = band.json_decode(band.json_encode(v)); return true end
local function listing(dir, ext)
  local out = {}
  for p in pairs(files) do local d, fn = p:match("^(.*)/([^/]*)$"); if d == dir and (not ext or fn:sub(-#ext) == ext) then out[#out + 1] = fn end end
  table.sort(out)
  return out
end
proxy.listing = function(dir) return listing(dir) end
proxy.files = listing
proxy.log = function(t) logged[#logged + 1] = t end
proxy.size = function() return 960044 end
proxy.copy_atomic = function() return true end
proxy.session_path = function() return "SESSION" end
package.loaded.band = proxy
local mirror = require("mirror")
local sync = require("sync")
require("direct").send_live = function() return true end
require("prints").choose = function() end
mirror.FX_SET_GAP = 0
local colours = require("colours")
local ROOT = "C:/fake/StudioSync"
local song, room = "NoHold", "main"
local yes = function() return true end
local MEDIA = sync.room_dir({ root = ROOT }, song, room) .. "/media"
local SEC = band.SECTION

local A, B
local function computer(user, path) return { F = E.new(path), cfg = { user = user, root = ROOT } } end
local function as(c) reaper = c.F.reaper end
local function state(c)
  as(c)
  local out, order = {}, {}
  for _, o in ipairs(mirror.scan(c.F.proj, c.cfg.user, MEDIA, false)) do out[o.oid] = o.hash; if o.kind == "track" then order[#order + 1] = o.oid end end
  return out, table.concat(order, ",")
end
local function timeline(c) as(c); return band.json_encode({ band.capture_tempo(c.F.proj), band.capture_markers(c.F.proj) }) end
local function same(x, y, what)
  local sx, ox = state(x)
  local sy, oy = state(y)
  for oid, h in pairs(sx) do assert(sy[oid] == h, what .. ": " .. oid .. " reads the same on both") end
  for oid in pairs(sy) do assert(sx[oid], what .. ": nothing extra on " .. y.cfg.user) end
  assert(ox == oy, what .. ": the same track order")
  assert(timeline(x) == timeline(y), what .. ": the same markers\n" .. timeline(x) .. "\n" .. timeline(y))
  as(A) -- (the desktop acts next, in this test)
end
local seen_files = {}
local function new_events()
  local out = {}
  for p, v in pairs(files) do
    if not seen_files[p] then
      seen_files[p] = true
      if p:find("/events/", 1, true) and type(v) == "table" then out[#out + 1] = v end
    end
  end
  return out
end
-- a pass of Live sync: the look, then the timeline's look. -> events sent by oid ("timeline" for the timeline's), the list
local function look(c, quick)
  as(c)
  c.F.clock = c.F.clock + 1
  mirror.watch(c.F.proj, c.cfg, song, room, { can = yes, mode = "open", quick = quick })
  sync.watch_timeline(c.F.proj, c.cfg, song, room, yes)
  local sent, by = new_events(), {}
  for _, ev in ipairs(sent) do by[ev.oid or ev.type] = ev end
  return by, sent
end
local function settle(c)
  for _ = 1, 20 do
    local _, s = look(c, true)
    if #s == 0 and not mirror.more then return end
  end
  error("never settled")
end
local function recv(c)
  as(c)
  for _ = 1, 20 do
    c.F.clock = c.F.clock + 1
    local got = sync.receive(c.F.proj, c.cfg, song, room, yes)
    if (tonumber(got) or 0) == 0 and not sync.backlog and not sync.read_cut then break end
  end
  for _ = 1, 3 do
    local o = look(c, true)
    for oid in pairs(o) do error(c.cfg.user .. " sent back what landed: " .. oid) end
  end
  as(A)
end
local function audio(pos, len, file, name)
  return table.concat({ "<ITEM", "POSITION " .. f(pos), "SNAPOFFS 0", "LENGTH " .. f(len), "LOOP 1", "ALLTAKES 0", "FADEIN 1 0.01 0 1 0 0 0",
    "FADEOUT 1 0.01 0 1 0 0 0", "MUTE 0 0", "SEL 0", "IID 1", 'NAME "' .. name .. '"', "VOLPAN 1 0 1 -1", "SOFFS 0", "PLAYRATE 1 1 0 -1 0 0.0025",
    "CHANMODE 0", "GUID " .. E.guid(), "<SOURCE WAVE", 'FILE "' .. MEDIA .. "/" .. file .. '"', ">", ">" }, "\n") .. "\n"
end
local function said(text) local n = 0; for _, l in ipairs(logged) do if l == text then n = n + 1 end end; return n end
local function said_like(pat) for _, l in ipairs(logged) do if l:find(pat, 1, true) then return l end end end

-- the song: the desktop (James) shares it, the laptop (Bee) takes it in
A, B = computer("James", "C:/A/NoHold.rpp"), computer("Bee", "C:/B/NoHold.rpp")
local F = A.F
local drums, bass, keys = F.add_track("Drums"), F.add_track("Bass"), F.add_track("Keys")
for i = 0, 1 do F.add_item(drums, audio(i * 4, 3.5, "drums" .. i .. ".flac", "Drums " .. i)) end
local bass1 = F.add_item(bass, audio(0.5, 3, "bass1.flac", "Bass 1"))
for _, x in ipairs({ A.F, B.F }) do x.add_marker(true, 0, 8, "Verse", nil, 0x1000000 | 0x203040); x.add_marker(false, 4, 4, "Cue") end
settle(A)
A.F.clock = A.F.clock + 70
settle(A)
recv(B)
B.F.clock = B.F.clock + 70
settle(B)
same(A, B, "the song as shared")

-- ---- 1. the migration: each old value cleared on opening, said once, and what it held goes out ----
for i, v in ipairs({ "1", "try", "try1" }) do
  tick()
  as(B)
  local tr = B.F.tracks[2]
  tr.name = "Bass " .. v -- (changed while it was held: saved in the project, never sent)
  B.F.changed()
  reaper.SetProjExtState(B.F.proj, SEC, "hold", v)
  mirror.opened[tostring(B.F.proj)] = nil -- (the project opening again)
  logged = {}
  local by = look(B, true)
  assert(select(2, reaper.GetProjExtState(B.F.proj, SEC, "hold")) == "", "hold = " .. v .. ": cleared on opening")
  assert(said("Hold my changes was removed: this project's held changes go out now") == 1, "hold = " .. v .. ": said once")
  local sent_track = false
  for _, ev in pairs(by) do if type(ev.state) == "table" and ev.state.name == "Bass " .. v then sent_track = true end end
  assert(sent_track, "hold = " .. v .. ": what it held went out in that look")
  look(B, true)
  assert(said("Hold my changes was removed: this project's held changes go out now") == 1, "hold = " .. v .. ": not said again")
  recv(A)
  same(A, B, "hold = " .. v .. ": the desktop has it")
  assert(i > 0)
end
-- an opening without it says nothing
mirror.opened[tostring(B.F.proj)] = nil
logged = {}
look(B, true)
assert(not said_like("Hold my changes"), "no hold: nothing said")
print("rt-nohold: \"1\", \"try\" and \"try1\" are cleared on opening, said once, and what they held goes out")

-- ---- 2. a colour look tried on the desktop ----
as(A)
local P = A.F.proj
local function colours_of(c)
  as(c)
  local t = { c.F.reaper.GetMediaTrackInfo_Value(c.F.tracks[2], "I_CUSTOMCOLOR"), c.F.reaper.GetMediaTrackInfo_Value(c.F.tracks[3], "I_CUSTOMCOLOR"),
    c.F.reaper.GetMediaItemInfo_Value(c.F.tracks[2].items[1], "I_CUSTOMCOLOR") }
  for _, m in ipairs(c.F.markers) do if m.region then t[#t + 1] = m.color end end
  as(A) -- (the panel's calls below are the desktop's)
  return table.concat(t, ",")
end
local orig = colours_of(A)
assert(orig == colours_of(B), "both start alike")
local RED, BLUE, GREEN = 0x1000000 | 0x0000FF, 0x1000000 | 0xFF0000, 0x1000000 | 0x00FF00
local function paint(c1, c2)
  return function()
    reaper.SetMediaTrackInfo_Value(bass, "I_CUSTOMCOLOR", c1)
    reaper.SetMediaTrackInfo_Value(keys, "I_CUSTOMCOLOR", c2)
    reaper.SetMediaItemInfo_Value(bass1, "I_CUSTOMCOLOR", c1)
    for i, m in ipairs(A.F.markers) do if m.region then reaper.SetProjectMarkerByIndex2(P, i - 1, true, m.pos, m.rend, m.num, m.name, c2, 0) end end
  end
end
local function nothing_sent(by, what) for k, ev in pairs(by) do error(what .. ": " .. tostring(k) .. " went out (" .. tostring(ev.type) .. ")") end end

-- a. trying: nothing goes; everything else does
tick()
colours.try_first(P, paint(RED, BLUE))
assert(colours.trying(P) and colours_of(A) ~= orig, "the look shows here")
nothing_sent(look(A, true), "trying (quick look)")
nothing_sent(look(A, false), "trying (full look)")
same(A, B, "trying: the band's copy reads the same on both")
tick()
reaper.SetMediaItemInfo_Value(A.F.tracks[1].items[1], "D_POSITION", 0.25) -- (an edit elsewhere)
keys.name = "Keys 2"; A.F.changed() -- (an edit to a tried track)
A.F.add_marker(false, 12, 12, "Bridge") -- (a timeline edit)
local by = look(A, true)
local moved, renamed = false, nil
for _, ev in pairs(by) do
  if type(ev.state) == "string" and require("beats").write(P, "item", ev.state):find("POSITION 0.25", 1, true) then moved = true end -- (in beats as it travels: lib/beats.lua)
  if type(ev.state) == "table" and ev.state.name == "Keys 2" then renamed = ev.state end
end
assert(moved, "trying: an item moved elsewhere went out")
assert(renamed and renamed.color == band.color_out(0), "trying: the tried track's rename went out, with its colour from before (" .. tostring(renamed and renamed.color) .. ")")
assert(by.timeline, "trying: the marker went out")
for _, m in ipairs(by.timeline.markers) do
  if m.region then assert(m.color == band.color_out(0x1000000 | 0x203040), "trying: the region went with its colour from before") end
end
recv(B)
same(A, B, "trying, after other edits")
assert(colours_of(B) == orig, "the laptop never saw the look")

-- b. Keep: the look goes out
tick()
colours.keep(P)
assert(not colours.trying(P), "kept")
by = look(A, true)
assert(by.timeline, "kept: the region's colour went")
local track_colours, item_colour = 0, false
for _, ev in pairs(by) do
  if type(ev.state) == "table" and (ev.state.color == band.color_out(RED) or ev.state.color == band.color_out(BLUE)) then track_colours = track_colours + 1 end
  if type(ev.state) == "string" and ev.state:find("\nCOLOR " .. RED .. " R", 1, true) then item_colour = true end
end
assert(track_colours == 2 and item_colour, "kept: both tracks' colours and the item's went (" .. track_colours .. ", " .. tostring(item_colour) .. ")")
recv(B)
same(A, B, "kept")
assert(colours_of(B) == colours_of(A), "the laptop has the look")
local kept = colours_of(A)

-- c. Put back: nothing goes, the look is as it was
tick()
colours.try_first(P, paint(GREEN, GREEN))
nothing_sent(look(A, true), "trying again")
colours.put_back(P)
assert(colours_of(A) == kept, "put back: as it was")
nothing_sent(look(A, true), "put back (quick look)")
nothing_sent(look(A, false), "put back (full look)")
same(A, B, "put back")
assert(select(2, reaper.GetProjExtState(P, SEC, "colour try")) == "", "put back: nothing of it left in the project")

-- d. a bandmate's change to a tried track lands; Put back leaves it, and sends nothing
tick()
colours.try_first(P, paint(GREEN, GREEN))
as(B)
B.F.reaper.SetMediaTrackInfo_Value(B.F.tracks[2], "I_CUSTOMCOLOR", BLUE)
look(B, true)
recv(A)
as(A)
colours.put_back(P)
assert(reaper.GetMediaTrackInfo_Value(bass, "I_CUSTOMCOLOR") == BLUE, "the bandmate's colour stays")
nothing_sent(look(A, true), "put back after a bandmate's change")
same(A, B, "put back after a bandmate's change")
kept = colours_of(A)

-- e. REAPER stops mid-try (the project saved with the try in it): the next opening puts the look back, nothing sent
tick()
colours.try_first(P, paint(GREEN, RED))
nothing_sent(look(A, true), "trying before the stop")
assert(select(2, reaper.GetProjExtState(P, SEC, "colour try")) ~= "", "the try is in the project, as a save mid-try keeps it")
-- Live sync restarted while the panel still tries: the try stays
mirror.opened[tostring(P)] = nil
nothing_sent(look(A, true), "Live sync restarted mid-try")
assert(colours_of(A) ~= kept, "Live sync restarted mid-try: the look still shows")
-- REAPER restarted: this REAPER's ExtState and the panel's Lua are gone, the project (saved mid-try) opens again
for k in pairs(A.F.gext) do A.F.gext[k] = nil end
package.loaded.colours = nil
colours = require("colours")
mirror.opened[tostring(P)] = nil
logged = {}
nothing_sent(look(A, true), "the opening after REAPER stopped mid-try")
assert(colours_of(A) == kept, "the look is put back on opening: " .. colours_of(A) .. " vs " .. kept)
assert(said_like("a colour look was being tried when REAPER stopped: it's put back"), "and the log says so")
assert(select(2, reaper.GetProjExtState(P, SEC, "colour try")) == "", "nothing of it left in the project")
nothing_sent(look(A, false), "a full look after")
same(A, B, "after REAPER stopped mid-try")
print("rt-nohold: a colour try sends nothing and holds nothing else back; Keep sends it, Put back and a restart mid-try put it back with nothing sent")

-- ---- 3. no code reads ProjExtState "hold" but the opening's clearing ----
do
  local p = io.popen('git ls-files "*.lua"')
  local list = {}
  for l in p:lines() do list[#list + 1] = l end
  p:close()
  assert(#list > 100, "git listed the Lua files (" .. #list .. ")")
  local allowed = {
    ["lib/mirror.lua"] = { 'if select(2, reaper.GetProjExtState(proj, B.SECTION, "hold")) ~= "" then', 'reaper.SetProjExtState(proj, B.SECTION, "hold", "")' },
    ["lib/api.lua"] = { 'api.KINDS = {', 'api.VERBS = {' }, -- (the API's lists never lose a name)
    ["StudioSync - Panel.lua"] = { 'elseif want == "hold" then' }, -- (the old verb only says it's gone)
  }
  local found = {}
  for _, path in ipairs(list) do
    if not path:find("^tests/") then
      local h = io.open(path, "rb")
      local text = h and h:read("a") or ""
      if h then h:close() end
      for line in text:gmatch("[^\r\n]+") do
        line = line:match("^%s*%-%-") and "" or line:gsub("%-%-[%s%(].*$", "") -- (code, not comments)
        if line:find('"hold"', 1, true) or line:find("'hold'", 1, true) then
          local ok = false
          for _, a in ipairs(allowed[path] or {}) do if line:find(a, 1, true) then ok = true end end
          assert(ok, "\"hold\" is read outside the opening's clearing: " .. path .. ": " .. line:gsub("^%s+", ""))
          found[path] = (found[path] or 0) + 1
        end
      end
    end
  end
  assert(found["lib/mirror.lua"] == 2, "the opening's clearing is still there")
  assert(not io.open("StudioSync - Hold my changes.lua", "rb"), "the Hold my changes action is gone")
end
print("ok rt-nohold")
