-- The History page's time lapse (lib/webhistory.lua, lib/webui/history.js): exact UTC times, an item's length and take-ness read from its
-- event file's text, the replay of a generated long history (thousands of events, four people, several sessions over days) into at most
-- FRAMES frames that rebuild the final arrangement exactly, the summary (who did what, takes, busiest days), its size and build time, the
-- tick (only while a page looks, item lengths read a few a tick, nothing ever changed), and the page's wiring. (James, rt)
package.path = "lib/?.lua;" .. package.path
local now = 1000
reaper = setmetatable({
  time_precise = function() return now end,
  GetOS = function() return "Win64" end,
  GetExtState = function() return "" end,
  SetExtState = function() end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return 0 end end end })
local band = require("band")
local wh = require("webhistory")

-- ---- exact UTC times -----------------------------------------------------------------------------------------------------------------
assert(wh.epoch("1970-01-01T00:00:00Z") == 0 and wh.epoch("2000-03-01T00:00:00Z") == 951868800, "epoch")
assert(wh.epoch("2026-11-20T12:34:56Z") == 1795178096, "epoch now-ish")
assert(wh.epoch("nope") == nil, "not a time")

-- ---- an item's details from its event file -----------------------------------------------------------------------------------------
local function item_state(len, name, file, midi)
  return "<ITEM\nPOSITION 1\nLENGTH " .. len .. "\nNAME \"" .. name .. "\"\nTAKE\nNAME \"" .. name .. "\"\n" ..
    (midi and "<SOURCE MIDI\nHASDATA 1 960 QN\n>\n" or ("<SOURCE WAVE\nFILE \"" .. file .. "\"\n>\n")) .. ">"
end
local ev1 = { type = "obj", obj = "item", rev = 1 }
local text = band.json_encode({ type = "obj", obj = "item", rev = 1, state = item_state(12.5, "05-Gtr-261119_1730.wav", "media/05-Gtr-261119_1730.wav") })
local d = wh.detail(text, ev1, band.json_decode)
assert(d.len == 12.5 and d.take and not d.midi, "a recording: REAPER's own file name")
d = wh.detail(band.json_encode({ state = item_state(3, "Verse - Bo - take 2", "x.wav") }), ev1, band.json_decode)
assert(d.take and d.len == 3, "a smart take name is a take")
d = wh.detail(band.json_encode({ state = item_state(4, "my loop", "loop.wav") }), ev1, band.json_decode)
assert(not d.take and d.len == 4, "a named item isn't a take")
d = wh.detail(band.json_encode({ state = item_state(2.25, "chords", nil, true) }), { type = "obj", obj = "item", rev = 3 }, function() error("only a new item is decoded") end)
assert(d.midi and d.len == 2.25 and not d.take, "MIDI; a changed item isn't decoded")
assert(wh.detail(nil, ev1, band.json_decode).len == nil, "no file: nothing known")

-- ---- a generated long history --------------------------------------------------------------------------------------------------------
local people = { "James", "Bo", "Chili", "Ana" }
local evs, info, seq = {}, {}, 0
local t = wh.epoch("2026-11-01T18:00:00Z")
local function iso(x) return os.date("!%Y-%m-%dT%H:%M:%SZ", x) end
local function post(e, user, dt)
  seq = seq + 1
  t = t + (dt or 7)
  e.user, e.time, e.id = user, iso(t), string.format("%s-%06d", user, seq)
  e.kind = e.type
  evs[#evs + 1] = e
  return e
end
local want = { tracks = {}, items = {} } -- (what the arrangement must be at the end)
local tracks, items, ntr, nit = {}, {}, 0, 0
local rnd = 12345
local function rand(n) rnd = (rnd * 1103515245 + 12345) % 2147483648; return rnd % n + 1 end
local takes_by = {}
for sess = 1, 16 do
  t = t + 86400 * (sess % 3 == 0 and 2 or 1) -- (a day or two between sessions)
  for step = 1, 500 do
    local who = people[rand(sess < 4 and 2 or 4)]
    local r = rand(100)
    if ntr < 3 or r <= 2 then
      ntr = ntr + 1
      local oid = "T-" .. who:upper() .. "-" .. ntr
      tracks[#tracks + 1] = oid
      post({ type = "obj", obj = "track", oid = oid, rev = 1, name = "Track " .. ntr }, who)
      want.tracks[oid] = true
    elseif r <= 25 then -- a new item: a take or a MIDI part or an edit (pasted)
      nit = nit + 1
      local oid = "I-" .. who:upper() .. "-" .. nit
      local tr = tracks[rand(#tracks)]
      if want.tracks[tr] then
        local e = post({ type = "obj", obj = "item", oid = oid, rev = 1, track = tr, name = "x", pos = rand(240) - 1 }, who)
        local kind = rand(3)
        info[e] = { len = rand(30), take = kind == 1 or nil, midi = kind == 2 or nil }
        if kind == 1 then takes_by[who] = (takes_by[who] or 0) + 1 end
        items[#items + 1] = oid
        want.items[oid] = { tr = tr, pos = e.pos, len = info[e].len }
      end
    elseif r <= 70 and #items > 0 then -- moved or trimmed
      local oid = items[rand(#items)]
      local w = want.items[oid]
      if w then
        local e = post({ type = "obj", obj = "item", oid = oid, rev = 2, track = w.tr, name = "x", pos = r <= 50 and rand(240) - 1 or w.pos }, who)
        info[e] = { len = r <= 50 and w.len or rand(30) }
        w.pos, w.len = e.pos, info[e].len
      end
    elseif r <= 75 and #items > 0 then
      local oid = items[rand(#items)]
      if want.items[oid] then post({ type = "obj", obj = "item", oid = oid, rev = 3, gone = true, track = want.items[oid].tr, pos = 0 }, who); want.items[oid] = nil end
    elseif r <= 90 then
      local tr = tracks[rand(#tracks)]
      if want.tracks[tr] then post({ type = "obj", obj = r % 2 == 0 and "fx" or "track", oid = (r % 2 == 0 and "F" or "T") .. tr:sub(2), track = tr, rev = 2, name = "Track" }, who) end
    elseif r <= 94 then
      post({ type = "timeline", markers = { { region = true, pos = 0, ["end"] = 30 + sess, name = "Intro" }, { pos = 40, name = "a marker" },
        { region = true, pos = 60, ["end"] = 120, name = "Verse" } }, tempo = { { bpm = 120, time = 0 } } }, who)
    elseif r <= 96 then post({ type = "note", text = "nice", pos = 3 }, who)
    elseif r <= 97 then post({ type = "start", pos = 0 }, who) -- (not a change)
    elseif r == 98 and #tracks > 4 then
      local tr = tracks[rand(#tracks)]
      if want.tracks[tr] then
        post({ type = "obj", obj = "track", oid = tr, rev = 9, gone = true, name = "Track" }, who)
        want.tracks[tr] = nil
        for oid, w in pairs(want.items) do if w.tr == tr then want.items[oid] = nil end end
      end
    else post({ type = "obj", obj = "item", oid = "I-AUTO-" .. seq, auto = true, track = tracks[1], pos = 1 }, who) end -- (auto: never shown)
  end
end
assert(#evs > 5000, "a long history: " .. #evs)
-- shuffled: the build sorts
for i = #evs, 2, -1 do local j = rand(i); evs[i], evs[j] = evs[j], evs[i] end

local c0 = os.clock()
local h = wh.build(evs, function(e) return info[e] or (e.obj == "track" and {} or nil) end, { places = { [tracks[1]] = 0 }, colours = { James = 0xd9822b }, frames = 360,
  versions = { { file = "a.json", label = "end of session", by = "Bo", time = iso(t - 100) } } })
local secs = os.clock() - c0
local js = band.json_encode(h)
assert(#h.frames <= 360 and #h.frames >= 300, "frames: " .. #h.frames)
assert(#h.sessions == 16, "a session a day: " .. #h.sessions)
assert(#js < 400 * 1024, "compact: " .. #js .. " bytes")
assert(secs < 2, "built in " .. secs .. " s") -- (lupa's Lua on a CI runner; REAPER's is faster)
assert(h.cols[1] == "#d9822b" and h.users[1] == "James", "colours by person")
assert(h.tracks[1][2] == 0, "a track's place now")
assert(h.versions[1][2] == "end of session", "saved versions on the strip")
assert(h.lengths.have == h.lengths.need, "every length known")

-- replayed as the page does: the end matches the arrangement
local tl, il, by_iid = {}, {}, {}
local regions
for _, f in ipairs(h.frames) do
  for _, x in ipairs(f.ta or {}) do tl[x] = true end
  for _, x in ipairs(f.tg or {}) do tl[x] = nil end
  for _, x in ipairs(f.g or {}) do il[x] = nil end
  for _, x in ipairs(f.i or {}) do il[x[1]] = x end
  if f.r then regions = f.r end
  assert(f.n >= 1 and f.t and f.s, "a frame's count, time and session")
end
local live_tracks, want_tracks = 0, 0
for _ in pairs(tl) do live_tracks = live_tracks + 1 end
for _ in pairs(want.tracks) do want_tracks = want_tracks + 1 end
assert(live_tracks == want_tracks, "tracks at the end: " .. live_tracks .. " vs " .. want_tracks)
local live_items, want_items = 0, 0
for _, x in pairs(il) do live_items = live_items + 1; by_iid[#by_iid + 1] = x end
for _ in pairs(want.items) do want_items = want_items + 1 end
assert(live_items == want_items, "items at the end: " .. live_items .. " vs " .. want_items)
local ends_got, ends_want = {}, {}
for _, x in ipairs(by_iid) do ends_got[#ends_got + 1] = string.format("%.3f+%.3f", x[3], x[4]) end
for _, w in pairs(want.items) do ends_want[#ends_want + 1] = string.format("%.3f+%.3f", w.pos, w.len) end
table.sort(ends_got); table.sort(ends_want)
assert(table.concat(ends_got, ",") == table.concat(ends_want, ","), "every item where it ended up, with its length")
assert(regions and #regions == 2 and regions[2][3] == "Verse", "regions as the last timeline left them")

-- the summary
local ix = {}
for i, n in ipairs(h.users) do ix[n] = i end
for who, n in pairs(takes_by) do assert(h.who[ix[who]][1] == n, who .. "'s takes") end
local total = 0
for _, w in ipairs(h.who) do total = total + w[1] + w[2] + w[3] + w[4] + w[5] end
assert(total == h.changes, "every change credited to someone")
local dsum = 0
for _, dd in ipairs(h.days) do dsum = dsum + dd[2] end
assert(dsum == h.changes and #h.days >= 16, "busiest days add up")
assert(h.who[ix.James][7] > 0, "notes counted")
assert(h.per * 360 >= h.changes, "per frame")

-- a short history: a frame per change, and a quiet hour starts a session
local short = {}
local base = wh.epoch("2026-11-02T10:00:00Z")
local function at(x) return os.date("!%Y-%m-%dT%H:%M:%SZ", x) end
short[1] = { type = "obj", kind = "obj", obj = "track", oid = "t-a-1", rev = 1, name = "Drums", user = "A", time = at(base), id = "1" }
short[2] = { type = "obj", kind = "obj", obj = "item", oid = "I-1", rev = 1, track = "T-A-1", pos = 2, user = "A", time = at(base + 5), id = "2" }
short[3] = { type = "obj", kind = "obj", obj = "item", oid = "I-1", rev = 2, track = "T-A-1", pos = 2, user = "B", time = at(base + 3605), id = "3" }
short[4] = { type = "obj", kind = "obj", obj = "item", oid = "I-1", rev = 3, gone = true, track = "T-A-1", user = "B", time = at(base + 3606), id = "4" }
local hs = wh.build(short, function(e) return e.id == "2" and { len = 4, midi = true } or e.id == "3" and { len = 4, midi = true } or nil end)
assert(#hs.frames == 4 and #hs.sessions == 2 and hs.sessions[2].f == 2, "a frame each; two sessions")
assert(hs.frames[2].i[1][4] == 4 and hs.frames[2].i[1][6] == 3, "a new MIDI item: MIDI")
assert(hs.frames[3].i[1][6] == 3 and hs.frames[3].i[1][5] == 1, "notes edited in place: MIDI, by B")
assert(hs.frames[4].g[1] == 0, "then deleted")
assert(hs.frames[1].ta[1] == 0 and hs.tracks[1][1] == "Drums", "the track appears (its oid's case doesn't matter)")
assert(#wh.build({}, nil).frames == 0, "nothing yet")

-- ---- a slice of a real room's formats (Cross Test, 2026-11-18 to 20): deletions, late edits, re-made tracks, fixed lanes ------------------
-- Event files as mirror sync writes them (a track's state is a table, an item's the chunk text with BANDLANE), read through wh.detail as the
-- tick reads them. What went wrong first: a bandmate's item edit stamped after its track's deletion brought the track back (28 tracks, 3 real).
local real, rtext = {}, {}
local function rev(o)
  local e = { type = "obj", obj = o.obj, oid = o.oid, rev = o.rev, base = o.rev - 1, name = o.name, user = o.user, time = o.time, hlc = o.hlc,
    track = o.track, pos = o.pos, gone = o.gone, id = o.user .. "-" .. o.time:gsub("[-:]", "") .. "-" .. #real }
  local full = { type = "obj", obj = o.obj, oid = o.oid, rev = o.rev, state = o.state, gone = o.gone }
  rtext[e] = band.json_encode(full)
  e.kind = e.type
  real[#real + 1] = e
end
local function istate(len, lane) return "<ITEM\nPOSITION 0\nLENGTH " .. len .. "\nNAME \"x\"\nTAKE\nNAME \"x\"\n<SOURCE WAVE\nFILE \"m.wav\"\n>\n>\n" .. (lane and ("BANDLANE " .. lane .. "\n") or "") end
local DR1, KC1, DR2, REC = "T-JAMES-20261118011057-15252", "T-CHILIO_MAC-20261118014513-12777", "T-JAMES-20261119215726-10590", "T-JAMES-20261120003033-10538"
rev({ obj = "track", oid = DR1, rev = 1, name = "XT Drums A", user = "James", time = "2026-11-18T01:10:57Z", hlc = 1795137057000, state = { name = "XT Drums A", freemode = 0 } })
rev({ obj = "item", oid = "I-JAMES-1", rev = 1, track = DR1, name = "XT Drums A", pos = 0, user = "James", time = "2026-11-18T01:10:57Z", hlc = 1795137057001, state = istate(3.6923) })
rev({ obj = "track", oid = KC1, rev = 1, name = "XT Keys C", user = "Chilio-Mac", time = "2026-11-18T01:45:13Z", hlc = 1795139113000, state = { name = "XT Keys C" } })
rev({ obj = "item", oid = "I-CHILIO-1", rev = 1, track = KC1, name = "XT Keys C", pos = 4, user = "Chilio-Mac", time = "2026-11-18T01:45:14Z", hlc = 1795139114000, state = istate(2) })
-- the drums track deleted with its item; Chilio's edit to that item, stamped a second later, can't bring either back
rev({ obj = "track", oid = DR1, rev = 2, gone = true, name = "XT Drums A", user = "James", time = "2026-11-19T17:25:58Z", hlc = 1795195558000 })
rev({ obj = "item", oid = "I-JAMES-1", rev = 2, gone = true, track = DR1, name = "XT Drums A", pos = 0, user = "James", time = "2026-11-19T17:25:58Z", hlc = 1795195558001 })
rev({ obj = "item", oid = "I-JAMES-1", rev = 5, track = DR1, name = "XT Drums A", pos = 1, user = "Chilio-Mac", time = "2026-11-19T17:25:59Z", hlc = 1795195559000, state = istate(3.6923) })
rev({ obj = "recv", oid = "R" .. DR1:sub(2), rev = 3, track = DR1, name = "XT Drums A", user = "Chilio-Mac", time = "2026-11-19T17:26:00Z", hlc = 1795195560000, state = "x" })
-- the keys item deleted (rev 3); a late rev 2 from the Mac, stamped after it, lost: the item stays deleted
rev({ obj = "item", oid = "I-CHILIO-1", rev = 3, gone = true, track = KC1, name = "XT Keys C", pos = 4, user = "James", time = "2026-11-19T17:30:00Z", hlc = 1795195800000 })
rev({ obj = "item", oid = "I-CHILIO-1", rev = 2, track = KC1, name = "XT Keys C", pos = 6, user = "Chilio-Mac", time = "2026-11-19T17:31:00Z", hlc = 1795195700000, state = istate(2) })
-- drums made again: a new oid, a new lane with the same name
rev({ obj = "track", oid = DR2, rev = 1, name = "XT Drums A", user = "James", time = "2026-11-19T21:57:26Z", hlc = 1795211846000, state = { name = "XT Drums A" } })
rev({ obj = "item", oid = "I-JAMES-2", rev = 1, track = DR2, name = "XT Drums A", pos = 2, user = "James", time = "2026-11-19T21:57:27Z", hlc = 1795211847000, state = istate(3.6923) })
-- a fixed-lanes track: two takes in lanes 0 and 1, then lane 1 picked to play (the track's plays move)
rev({ obj = "track", oid = REC, rev = 1, name = "XT Rec A", user = "James", time = "2026-11-20T00:30:33Z", hlc = 1795221033000, state = { name = "XT Rec A", freemode = 2, lanes = 2, plays = "1,0" } })
rev({ obj = "item", oid = "I-JAMES-3", rev = 1, track = REC, name = "XT Rec A", pos = 3.6923, user = "James", time = "2026-11-20T00:30:54Z", hlc = 1795221054000, state = istate(5.46, 0) })
rev({ obj = "item", oid = "I-JAMES-4", rev = 1, track = REC, name = "XT Rec A", pos = 3.6923, user = "James", time = "2026-11-20T00:34:08Z", hlc = 1795221248000, state = istate(19.06, 1) })
rev({ obj = "track", oid = REC, rev = 2, name = "XT Rec A", user = "James", time = "2026-11-20T02:48:21Z", hlc = 1795229301000, state = { name = "XT Rec A", freemode = 2, lanes = 2, plays = "0,1" } })
for i = #real, 2, -1 do local j = rand(i); real[i], real[j] = real[j], real[i] end
local rh = wh.build(real, function(e) return wh.detail(rtext[e], e, band.json_decode) end)
-- replayed as history.js does, an item hidden when its lane doesn't play
local tl, il, pl = {}, {}, {}
for _, f in ipairs(rh.frames) do
  for _, x in ipairs(f.ta or {}) do tl[x] = true end
  for _, x in ipairs(f.tg or {}) do tl[x] = nil end
  for _, x in ipairs(f.g or {}) do il[x] = nil end
  for _, x in ipairs(f.i or {}) do il[x[1]] = x end
  for _, x in ipairs(f.p or {}) do pl[x[1]] = x[2] ~= "" and x[2] or nil end
end
local names, shown = {}, {}
for x in pairs(tl) do names[#names + 1] = rh.tracks[x + 1][1] end
table.sort(names)
assert(table.concat(names, ",") == "XT Drums A,XT Keys C,XT Rec A", "today's tracks only: " .. table.concat(names, ","))
for _, x in pairs(il) do
  local bits = {}
  for c in (pl[x[2]] or ""):gmatch("%d+") do bits[#bits + 1] = c end
  if tl[x[2]] and not (pl[x[2]] and x[7] >= 0 and bits[x[7] + 1] == "0") then shown[#shown + 1] = rh.tracks[x[2] + 1][1] .. "@" .. x[3] .. "+" .. x[4] end
end
table.sort(shown)
assert(table.concat(shown, ",") == "XT Drums A@2.0+3.692,XT Rec A@3.692+19.06", "today's items only, the playing lane's: " .. table.concat(shown, ","))
assert(rh.lengths.have == rh.lengths.need, "tracks and items read")

-- ---- the tick: only while a page looks; lengths read a few at a time; read-only --------------------------------------------------------
local files = {}
local cached = {}
for i = 1, 40 do
  local e = { type = "obj", kind = "obj", obj = "item", oid = "I-" .. i, rev = 1, track = "T-A-1", pos = i, user = "A", time = at(base + i), id = tostring(i), path_ = "ev" .. i }
  files["ev" .. i] = band.json_encode({ state = item_state(i, "item " .. i, "f.wav") })
  cached[#cached + 1] = e
end
local reads, published = 0, {}
band.read = function(p) reads = reads + 1; now = now + 0.001; return files[p] end -- (each read takes a millisecond)
package.loaded.recall = {
  warm = function() return true, #cached, #cached end,
  read_so_far = function() local o = {}; for i, e in ipairs(cached) do o[i] = e end; return o end,
  list = function() return {} end,
}
package.loaded.people = { colours = function() return {} end }
package.loaded.dawview = { shown = function() return true end }
package.loaded.mirror = { track_oid = function() return "T-A-1" end }
package.loaded.histhear = { tick = function() end, action = function() end } -- (hearing a point and Restore: tests/test_0_60_rt_histhear.lua)
reaper.CountTracks = function() return 1 end
reaper.GetTrack = function() return {} end
reaper.GetTrackName = function() return true, "Drums" end
local proj, cfg, b = {}, { root = "R", user = "A" }, { song = "S", room = "main" }
local function publish(k, v) published[k] = (published[k] or 0) + 1; published[k .. ":v"] = v end
wh.tick(proj, cfg, b, publish, now)
assert(not published.hist, "nobody looking: nothing built")
wh.action(proj, cfg, b, { topic = "history", want = true })
wh.tick(proj, cfg, b, publish, now)
assert(published.hist == 1 and published["hist:v"].lengths.have == 0 and published["hist:v"].read.done, "looking: built at once, lengths still unknown")
for _ = 1, 20 do now = now + 0.03; wh.tick(proj, cfg, b, publish, now) end
assert(reads == 40, "lengths read a few a tick, each once: " .. reads)
assert(published.hist == 2 and published["hist:v"].lengths.have == 40, "built again as soon as they're all read")
assert(published["hist:v"].frames[#published["hist:v"].frames].i[1][4] == 40, "with their lengths")
for _ = 1, 5 do now = now + 1; wh.tick(proj, cfg, b, publish, now) end
assert(published.hist == 2 and reads == 40, "nothing new: no rebuild, nothing read again")
wh.action(proj, cfg, b, { topic = "history", want = false })
now = now + 20
wh.tick(proj, cfg, b, publish, now)
assert(published.hist == 2, "the page said it stopped")

-- ---- the page's wiring --------------------------------------------------------------------------------------------------------------
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end
local html, pjs, ui, src = read("lib/webui/index.html"), read("lib/webui/history.js"), read("lib/webui.lua"), read("lib/webhistory.lua")
assert(html:find('src="history.js"', 1, true) and html:find('href="history.css"', 1, true), "index.html loads the page")
assert(html:find("tabs.js", 1, true) < html:find("history.js", 1, true), "after tabs.js")
assert(ui:find("webui.ACTIONS.history = true", 1, true) and ui:find('require("webhistory").tick', 1, true) and ui:find('require("webhistory").action', 1, true), "webui.lua routes it")
assert(pjs:find("ssTabs.add('history'", 1, true) and pjs:find("T.hist", 1, true), "history.js makes its tab and reads hist")
assert(not pjs:find("innerHTML", 1, true), "names go in as text")
-- read-only: the page sends nothing but want, and the module changes nothing in REAPER
for call in pjs:gmatch("ssTabs%.act%(([^)]*)%)") do assert(call:find("want", 1, true), "the page only says it's looking: " .. call) end
for _, f in ipairs({ "SetMedia", "Set_", "SetProj", "SetTrack", "DeleteTrack", "Undo_", "Main_OnCommand", "SetEnvelope", "AddProjectMarker", "panel_do", "sync.post", "write_json" }) do
  assert(not src:find(f, 1, true), "webhistory changes nothing: " .. f)
end

print("ok")
