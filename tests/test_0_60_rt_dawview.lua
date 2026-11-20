-- The shared DAW view, stage 1, and its history (lib/dawview.lua, lib/webui/daw.js): peaks downsampling, track and item serialisation,
-- chunk diffing, the cursors, history, what a page may send, the reader against a stand-in REAPER, the tick's gating and actions, the
-- payload on a 40-track, 400-item song, and a link check of the page files. (James, rt)
package.path = "lib/?.lua;" .. package.path
local clock, ext, logged = 1000, {}, {}
local fake -- the stand-in project, below
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
band.log = function(s) logged[#logged + 1] = s end
local dawview = require("dawview")

-- ---- peaks ----------------------------------------------------------------------------------------------------------------------------
assert(dawview.peak_count(0) == dawview.PEAKS_MIN and dawview.peak_count(1) == 10 and dawview.peak_count(3600) == dawview.PEAKS_MAX, "columns: clamped")
local A = dawview.ALPHA
assert(#A == 64 and not A:find('["\\]'), "64 levels, nothing JSON escapes")
-- 8 peaks to 4 columns: each the loudest of its two, minimums counting by size
local s = dawview.peak_chars({ 0, 1, 0.5, 0, 0, 0, 0.2, 0.1 }, { 0, 0, -0.25, -1, 0, 0, 0, -0.3 }, 8, 4)
assert(s == A:sub(64, 64) .. A:sub(64, 64) .. A:sub(1, 1) .. A:sub(20, 20), "the loudest of each share: " .. s)
assert(dawview.peak_chars({ 2 }, { -3 }, 1, 3) == A:sub(64, 64):rep(3), "fewer peaks than columns: each column the one it falls on, clipped at full scale")
assert(dawview.peak_chars({}, {}, 0, 5) == "" and dawview.peak_chars({ 1 }, { 1 }, 1, 0) == "", "nothing to show")

-- ---- building and diffing -------------------------------------------------------------------------------------------------------------
local function raw_song(ntracks, nitems, opts)
  opts = opts or {}
  local raw = { key = "Song/main", len = 240, tracks = {}, markers = { { pos = 0, name = "Intro", rgb = "#ff0000" }, { pos = 30, rend = 60, name = "Chorus", region = true } },
    bars = { 0, 2, 4 }, sigs = { { 0, 4, 4 } }, tempo = { { 0, 120 } }, grid = 0.25 }
  for t = 1, ntracks do
    local tr = { name = "Track " .. t, rgb = t % 3 == 0 and "#336699" or nil, depth = t == 1 and 0 or 1, folder = t == 1, mute = t == 2, solo = t == 3, items = {} }
    for i = 1, nitems do
      local midi = opts.midi and t % 5 == 0
      local it = { pos = (i - 1) * 24.0004, len = 20, mute = false, name = "take " .. i, rgb = nil, midi = midi }
      if midi then
        it.notes, it.nh = {}, "h" .. t .. i
        for n = 0, 99 do it.notes[#it.notes + 1] = n * 200; it.notes[#it.notes + 1] = 150; it.notes[#it.notes + 1] = 36 + n % 24 end
      else it.peaks = ("0123456789ABCDEFGHIJ"):rep(10) end
      tr.items[i] = it
    end
    raw.tracks[t] = tr
  end
  return raw
end
local raw = raw_song(10, 2)
local head, chunks = dawview.build(raw)
assert(#head.tracks == 10 and head.tracks[1].n == "Track 1" and head.tracks[1].f == 1 and head.tracks[1].d == nil and head.tracks[2].d == 1, "tracks: names, folders, depth")
assert(head.tracks[2].m == 1 and head.tracks[3].s == 1 and head.tracks[3].c == "#336699" and head.tracks[1].c == nil, "mute, solo, colour (none: nil)")
assert(#head.markers == 2 and head.markers[1].e == nil and head.markers[2].e == 60 and head.markers[2].n == "Chorus", "markers and regions")
assert(#chunks == 3 and chunks[1].t.from == 0 and #chunks[1].t.tr == 4 and chunks[3].t.from == 8 and #chunks[3].t.tr == 2, "items in chunks of " .. dawview.CHUNK_TRACKS .. " tracks")
local it = chunks[1].t.tr[1][2]
assert(it.p == 24 and it.l == 20 and it.n == "take 2" and it.k and not it.x and not it.m, "an item: rounded to ms, its peaks: " .. band.json_encode(it))
local state = {}
local ch, gone = dawview.diff(state, chunks)
assert(#ch == 3 and #gone == 0, "first look: every chunk")
ch = dawview.diff(state, select(2, dawview.build(raw_song(10, 2))))
assert(#ch == 0, "the same song: nothing")
local raw2 = raw_song(10, 2)
raw2.tracks[6].items[1].pos = 1.5
ch = dawview.diff(state, select(2, dawview.build(raw2)))
assert(#ch == 1 and ch[1] == 1, "one item moved: only its chunk (0-based 1)")
raw2.tracks[9].items[2].mute = true
raw2.tracks[10].items[1].peaks = "zzzz"
ch = dawview.diff(state, select(2, dawview.build(raw2)))
assert(#ch == 1 and ch[1] == 2, "a mute and new peaks in the last chunk: that chunk")
ch, gone = dawview.diff(state, select(2, dawview.build(raw_song(5, 2))))
assert(#gone == 1 and gone[1] == 2 and #ch == 1 and ch[1] == 1, "fewer tracks: the changed chunk, and the one no longer there emptied once")
ch, gone = dawview.diff(state, select(2, dawview.build(raw_song(5, 2))))
assert(#ch == 0 and #gone == 0, "and not again")
local other = raw_song(5, 2)
other.key = "Other/main"
ch = dawview.diff(state, select(2, dawview.build(other)))
assert(#ch == 2, "another song (same shape): everything")

-- ---- permissions, actions a page may send --------------------------------------------------------------------------------------------
assert(dawview.may_transport("driver", "James", "James") and not dawview.may_transport("driver", "Chilio", "James"), "driver mode: only the driver")
assert(dawview.may_transport("admins", "Admin", "James", true) and not dawview.may_transport("admins", "M", "James", false), "admins mode: driver and admins")
assert(dawview.may_transport("claims", "M", "James") and dawview.may_transport("open", "M", "James"), "otherwise anyone, as the panel")
local p = dawview.parse({ want = true, history = true, play = "start", restore = "20261119-101010Z-James-saved_by_James.json" })
assert(p.want and p.history and p.play == "start" and p.restore, "a page's asks")
for _, bad in ipairs({ "../x.json", "a/b.json", "x.lua", ".hidden.json", "a..b.json", ("x"):rep(201) .. ".json", 5 }) do
  assert(dawview.parse({ restore = bad }).restore == nil, "refused restore name: " .. tostring(bad))
end
assert(dawview.parse({ play = "record" }).play == nil and dawview.parse("x") == nil, "only play/stop; only tables")

-- ---- cursors and history ---------------------------------------------------------------------------------------------------------------
local cm = dawview.cursor_model("S/main", { user = "James", playing = true, pos = 12.34567, cursor = 3, view = { 0, 60 }, rate = 1 },
  { { user = "zed", cursor = 5, view = { 10, 20 }, playing = true }, { user = "James" }, { user = "Andie", last_at = 7.5 }, { nope = 1 } }, { James = 0xFF8800, zed = 0x112233 })
assert(cm.play.on == 1 and cm.play.pos == 12.346 and cm.play.rate == nil and cm.me.cur == 3 and cm.me.col == "#ff8800" and cm.me.view[2] == 60, "mine")
assert(#cm.people == 2 and cm.people[1].user == "Andie" and cm.people[1].cur == nil and cm.people[1].last == 7.5 and cm.people[2].col == "#112233"
  and cm.people[2].view[1] == 10 and cm.people[2].on == 1, "theirs, by name, me left out, cursor only when sent")
local evs = {
  { type = "obj", kind = "obj", obj = "item", oid = "I1", track = "T2OID", rev = 1, pos = 4, user = "James", time = "2026-11-19T10:00:00Z", id = "a" },
  { kind = "obj", obj = "item", oid = "I1", track = "T2OID", rev = 2, pos = 5, user = "Chilio", time = "2026-11-19T10:05:00Z", id = "b" },
  { kind = "obj", obj = "track", oid = "T2OID", rev = 3, user = "James", time = "2026-11-19T10:01:00Z", id = "c" },
  { kind = "obj", obj = "item", oid = "I2", gone = true, name = "Bass", user = "James", time = "2026-11-19T10:02:00Z", id = "d" },
  { kind = "obj", obj = "fx", oid = "F", track = "nowhere", user = "Andie", time = "2026-11-19T10:03:00Z", id = "e" },
  { kind = "driver", user = "James", time = "2026-11-19T10:04:00Z", id = "f" },
  { kind = "note", text = "louder here", pos = 33, user = "Andie", time = "2026-11-19T10:06:00Z", id = "g" },
  { kind = "obj", obj = "item", auto = true, user = "James", time = "2026-11-19T10:07:00Z", id = "h" },
}
local places = { T2OID = 1, bass = 0 }
local function lane_of(e) return (e.obj == "track" and places[e.oid]) or places[e.track or ""] or (e.name and places[e.name:lower()]) end
local versions = { { file = "v2.json", label = "second", by = "Chilio", time = "2026-11-19T10:10:00Z", keep = true }, { file = "v1.json", label = "first", by = "James", time = "2026-11-19T09:00:00Z" } }
local h = dawview.history_model("S/main", evs, versions, lane_of, { James = 0xFF0000 })
assert(#h.dots == 5, "changes only: not handovers, notes or automatic ones: " .. #h.dots)
local kinds = {}
for _, d in ipairs(h.dots) do kinds[#kinds + 1] = d[4] .. d[2] end
assert(table.concat(kinds, ",") == "a1,t1,d0,f-1,c1", "in time order, kind and lane: " .. table.concat(kinds, ","))
assert(h.dots[1][5] == 4 and h.dots[2][5] == false and h.dots[1][1] == band.iso_time("2026-11-19T10:00:00Z"), "position (false: none) and time")
assert(h.users[h.dots[1][3] + 1] == "James" and h.cols[1] == "#ff0000" and h.cols[2] == false, "who, and their colour where known")
assert(#h.notes == 1 and h.notes[1].text == "louder here" and h.notes[1].pos == 33 and h.users[h.notes[1].u + 1] == "Andie", "notes at their spot")
assert(#h.versions == 2 and h.versions[1].f == "v1.json" and h.versions[2].keep == 1, "versions oldest first")
assert(#dawview.history_model("S", evs, {}, lane_of, {}, 2).dots == 2, "only the newest HIST_MAX")

-- ---- the reader, against a stand-in REAPER -------------------------------------------------------------------------------------------
-- fake = { tracks = { { name, oid, depth, hidden, ["local"], mute, solo, color, lanes = { [lane] = plays }, items = { { pos, len, lane, midi, notes, name } } } } }
local peaks_asked = 0
local function setup_fake(f)
  fake = f
  local T, I, K = {}, {}, {}
  for ti, t in ipairs(f.tracks) do
    T[ti - 1] = t
    t.ptr = { t = t }
    for _, item in ipairs(t.items) do item.track = t; item.take = { item = item } end
  end
  reaper.GetProjectLength = function() return f.len or 100 end
  reaper.CountTracks = function() return #f.tracks end
  reaper.GetTrack = function(_, i) return f.tracks[i + 1].ptr end
  reaper.GetMediaTrackInfo_Value = function(tr, k)
    local t = tr.t
    if k == "I_FOLDERDEPTH" then return t.depth or 0 elseif k == "B_SHOWINTCP" then return t.hidden and 0 or 1
    elseif k == "B_MUTE" then return t.mute and 1 or 0 elseif k == "I_SOLO" then return t.solo and 2 or 0
    elseif k == "I_CUSTOMCOLOR" then return t.color or 0 elseif k == "I_FREEMODE" then return t.lanes and 2 or 0
    elseif k:find("^C_LANEPLAYS:") then return t.lanes[tonumber(k:match("%d+"))] and 1 or 0 end
    return 0
  end
  reaper.GetSetMediaTrackInfo_String = function(tr, k)
    local t = tr.t
    if k == "P_NAME" then return true, t.name elseif k == "P_EXT:band_oid" then return true, t.oid or ""
    elseif k == "P_EXT:band_local" then return true, t["local"] and "1" or "" end
    return true, ""
  end
  reaper.CountTrackMediaItems = function(tr) return #tr.t.items end
  reaper.GetTrackMediaItem = function(tr, j) return tr.t.items[j + 1] end
  reaper.GetMediaItemInfo_Value = function(item, k)
    if k == "D_POSITION" then return item.pos elseif k == "D_LENGTH" then return item.len elseif k == "I_FIXEDLANE" then return item.lane or 0
    elseif k == "B_MUTE" then return item.mute and 1 or 0 end
    return 0
  end
  reaper.GetActiveTake = function(item) return item.take end
  reaper.GetTakeName = function(tk) return tk.item.name or "" end
  reaper.GetMediaItemTakeInfo_Value = function(tk, k) if k == "D_PLAYRATE" then return 1 end return 0 end
  reaper.TakeIsMIDI = function(tk) return tk.item.midi == true end
  reaper.GetMediaItemTake_Source = function(tk) return tk end
  reaper.GetMediaSourceFileName = function(src) return "file-" .. tostring(src.item.name) end
  reaper.new_array = function(n) local a = { n = n, d = {} }; a.table = function() local t = {}; for i = 1, n do t[i] = a.d[i] or 0 end; return t end; return a end
  reaper.GetMediaItemTake_Peaks = function(tk, rate, start, nch, n, extra, buf)
    -- (as REAPER 7.86 does inside a coroutine: no answer and a buffer of junk. The look's own coroutine has the tick make it: rt-phonefix)
    if select(2, coroutine.running()) == false then for i = 1, n * 2 do buf.d[i] = 9e281 end return end
    peaks_asked = peaks_asked + 1
    clock = clock + (fake.peak_cost or 0)
    if tk.item.unbuilt then return 0 end
    for i = 1, n do buf.d[i] = math.abs(math.sin(i / 7)) * 0.8; buf.d[n + i] = -math.abs(math.cos(i / 5)) * 0.6 end
    return n | 0x100000
  end
  reaper.MIDI_GetHash = function(tk) return true, "hash" .. #(tk.item.notes or {}) end
  reaper.MIDI_CountEvts = function(tk) return 1, #(tk.item.notes or {}), 0, 0 end
  reaper.MIDI_GetNote = function(tk, i) local n = tk.item.notes[i + 1]; return true, false, n.muted or false, n.s, n.e, 0, n.pitch, 100 end
  reaper.MIDI_GetProjTimeFromPPQPos = function(tk, ppq) return tk.item.pos + ppq / 960 end -- (960 ppq a second here)
  reaper.EnumProjectMarkers3 = function(_, i)
    local m = (f.markers or {})[i + 1]
    if not m then return 0 end
    return 1, m.region or false, m.pos, m.rend or 0, m.name, i, m.color or 0
  end
  reaper.TimeMap_GetMeasureInfo = function(_, m) return m * 2, m * 4, m * 4 + 4, m < 2 and 4 or 3, 4, 120 end
  reaper.CountTempoTimeSigMarkers = function() return 0 end
  reaper.TimeMap_GetTimeSigAtTime = function() return 4, 4, 120 end
  reaper.GetSetProjectGrid = function() return 0, 0.25, 0, 0 end
  reaper.ColorFromNative = function(c) return c & 255, (c >> 8) & 255, (c >> 16) & 255 end
end
package.loaded.mirror = {
  local_track = function(tr) return tr.t["local"] == true end,
  track_oid = function(tr) return (tr.t.oid or ""):upper() end,
}
setup_fake({ len = 10, tracks = {
  { name = "Drums", oid = "td", depth = 1, color = 0x1000000 | 0x0000FF, items = { { pos = 0, len = 4, name = "kit" } } },
  { name = "Kick", oid = "tk", depth = -1, lanes = { [0] = true }, items = { { pos = 1, len = 2, lane = 0, name = "a" }, { pos = 1, len = 2, lane = 1, name = "comp-b" } } },
  { name = "Mine", ["local"] = true, items = { { pos = 0, len = 1 } } },
  { name = "Hidden", hidden = true, items = {} },
  { name = "Keys", oid = "tq", items = { { pos = 2, len = 1, midi = true, name = "chords",
    notes = { { s = 0, e = 480, pitch = 60 }, { s = 480, e = 960, pitch = 64, muted = true }, { s = 900, e = 3000, pitch = 67 } } } } },
}, markers = { { pos = 1, name = "A" }, { pos = 2, rend = 6, name = "Verse", region = true, color = 0x1000000 | 0x00FF00 }, { pos = 3, name = "[ping] chilio" } } })
local rr, pending, pl = dawview.read("P1", "S/main", clock, clock + 1)
assert(not pending and #rr.tracks == 3, "the studio's tracks: not this computer's own, not hidden ones")
assert(rr.tracks[1].name == "Drums" and rr.tracks[1].folder and rr.tracks[1].depth == 0 and rr.tracks[1].rgb == "#ff0000", "folder parent, its colour")
assert(rr.tracks[2].depth == 1 and #rr.tracks[2].items == 1 and rr.tracks[2].items[1].name == "a", "inside the folder; only the lane that plays")
assert(pl.TD == 0 and pl.TK == 1 and pl.TQ == 2 and pl.keys == 2, "places by oid and name, for history")
local k1 = rr.tracks[1].items[1]
assert(k1.peaks and #k1.peaks == dawview.peak_count(4) and k1.peaks:match("^[%w%-_]+$"), "peaks read and downsampled: " .. tostring(k1.peaks))
local mk = rr.tracks[3].items[1]
assert(mk.midi and #mk.notes == 6 and mk.notes[1] == 0 and mk.notes[2] == 500 and mk.notes[3] == 60 and mk.notes[4] == 938 and mk.notes[5] == 63 and mk.notes[6] == 67,
  "MIDI notes: muted left out, cut at the item's end, ms from its start: " .. band.json_encode(mk.notes))
assert(#rr.markers == 2 and rr.markers[2].region and rr.markers[2].rgb == "#00ff00", "markers and regions, not pings")
assert(rr.bars[1] == 0 and rr.bars[2] == 2 and #rr.sigs == 2 and rr.sigs[2][1] == 2 and rr.sigs[2][2] == 3 and rr.grid == 0.25, "bars, time signatures, grid")
local asked = peaks_asked
dawview.read("P1", "S/main", clock, clock + 1)
assert(peaks_asked == asked, "peaks kept: not read again while the take is the same")
fake.tracks[1].items[1].len = 5
dawview.read("P1", "S/main", clock, clock + 1)
assert(peaks_asked == asked + 1, "the item trimmed: its peaks read again")
-- the time budget: one costly read a look, the rest next look
fake.tracks[1].items[1].len, fake.tracks[2].items[1].len, fake.peak_cost = 6, 3, 1
local rb, pend = dawview.read("P1", "S/main", clock, clock + 0.5)
assert(pend and rb.tracks[2].items[1].peaks == nil, "over budget: left for the next look")
fake.peak_cost = 0
assert(select(2, dawview.read("P1", "S/main", clock, clock + 1)) == false, "and read then")
fake.tracks[1].items[1].unbuilt, fake.tracks[1].items[1].len = true, 7
asked = peaks_asked
dawview.read("P1", "S/main", clock, clock + 1)
dawview.read("P1", "S/main", clock, clock + 1)
assert(peaks_asked == asked + 1, "peaks REAPER hasn't built: asked again only after PEAK_RETRY s")
clock = clock + dawview.PEAK_RETRY
dawview.read("P1", "S/main", clock, clock + 1)
assert(peaks_asked == asked + 2, "then asked again")
fake.tracks[1].items[1].unbuilt = nil

-- ---- the tick: only while a page looks; chunks on change; cursors; actions --------------------------------------------------------------
local pubs, published = {}, {}
local function publish(topic, t) -- (as lib/webui.lua's: only a changed topic goes)
  local js = band.json_encode(t)
  if published[topic] ~= js then published[topic] = js; pubs[#pubs + 1] = topic end
end
local cc, ps, playpos, cursor = 1, 0, 0, 2
reaper.GetProjectStateChangeCount = function() return cc end
reaper.GetPlayStateEx = function() return ps end
reaper.GetPlayPositionEx = function() return playpos end
reaper.GetCursorPositionEx = function() return cursor end
reaper.GetSet_ArrangeView2 = function() return 0, 30 end
reaper.Master_GetPlayRate = function() return 1 end
package.loaded.presence = { peers = function() return { { user = "Chilio", cursor = 4.5, view = { 1, 9 } } } end }
package.loaded.people = { colours = function() return { James = 0xFF0000, Chilio = 0x00FF00 } end }
package.loaded.groups = { may_manage = function() return false end }
local started_ev
local together = require("together") -- (its own start builds the event: only sending it and the tempo map stood in)
together.go, together.bars_before = function(_, _, _, ev) started_ev = ev end, function() return 2 end
local who_mode = "driver"
package.loaded.sync = { authority = function() return function() end, { mode = who_mode, driver = "James" } end }
local panel = {}
band.panel_do = function(dir, what) panel[#panel + 1] = { dir, what } end
local versions_now = { { file = "v1.json", label = "first", time = "2026-11-19T09:00:00Z" } }
local warmed = 0
package.loaded.recall = { list = function() return versions_now end, warm = function() warmed = warmed + 1; return true end, read_so_far = function() return evs end }
local cfg, b = { root = "R", user = "James" }, { song = "S", room = "main" }
local who = { mode = "driver", driver = "James" }
dawview.tick("P1", cfg, b, publish, who, clock)
assert(#pubs == 0, "nobody has the Song page open: nothing built")
assert(not dawview.watching(clock), "not watching")
dawview.action("P1", cfg, b, { topic = "daw", want = true })
assert(dawview.watching(clock), "a page said it's looking")
fake.tracks[1].items[1].len = 8 -- (its peaks read again, inside the tick's look)
dawview.tick("P1", cfg, b, publish, who, clock)
assert(table.concat(pubs, ",") == "dawc0,daw,dawcur", "chunks before the header, then the cursors: " .. table.concat(pubs, ","))
local k8 = band.json_decode(published.dawc0).tr[1][1].k
assert(type(k8) == "string" and #k8 == dawview.peak_count(8) and not k8:find("_", 1, true), "peaks read in the look are REAPER's, not a coroutine's junk: " .. tostring(k8))
local hd = band.json_decode(published.daw)
assert(hd.chunks == 1 and hd.may == true and hd.me == "James" and #hd.tracks == 3 and hd.key == "S/main", "the header: " .. published.daw)
local cj = band.json_decode(published.dawcur)
assert(cj.me.cur == 2 and cj.people[1].user == "Chilio" and cj.people[1].cur == 4.5 and cj.people[1].col == "#00ff00", "cursors")
pubs = {}
clock = clock + 0.3
dawview.tick("P1", cfg, b, publish, who, clock)
assert(#pubs == 0, "nothing changed: nothing published")
cc, fake.tracks[5].items[1].pos = 2, 2.5
clock = clock + 0.3
dawview.tick("P1", cfg, b, publish, who, clock)
assert(table.concat(pubs, ",") == "dawc0", "an edit: its chunk (the header the same): " .. table.concat(pubs, ","))
pubs, ps, playpos = {}, 1, 10
clock = clock + 0.3
dawview.tick("P1", cfg, b, publish, who, clock)
assert(table.concat(pubs, ",") == "dawcur" and band.json_decode(published.dawcur).play.on == 1, "play: the cursors")
pubs, playpos = {}, 10.5
clock = clock + 0.5
dawview.tick("P1", cfg, b, publish, who, clock)
assert(#pubs == 0, "playing on as expected: not sent again within CUR_EVERY s (the page moves it on)")
playpos = 40
clock = clock + 0.1
dawview.tick("P1", cfg, b, publish, who, clock)
assert(#pubs == 1, "a jump while playing: sent at once")
ps = 0
-- history: only while asked for
pubs = {}
clock = clock + 2
dawview.action("P1", cfg, b, { want = true, history = true })
dawview.tick("P1", cfg, b, publish, who, clock)
assert(pubs[#pubs] == "dawhist" and warmed == 1, "History on: recall's reading, then the history published")
local hj = band.json_decode(published.dawhist)
assert(#hj.dots == 5 and hj.versions[1].f == "v1.json", "history published: " .. #hj.dots)
pubs = {}
clock = clock + 1
dawview.tick("P1", cfg, b, publish, who, clock)
assert(#pubs == 0 and warmed == 2, "built again only every HIST_EVERY s")
dawview.action("P1", cfg, b, { want = true, history = false })
clock = clock + dawview.HIST_EVERY
dawview.tick("P1", cfg, b, publish, who, clock)
assert(warmed == 2, "History off: recall isn't read")
-- Play/Stop together
local said = dawview.action("P1", { root = "R", user = "Chilio" }, b, { play = "start" })
assert(started_ev == nil and said:find("refused"), "not the driver in a driver's room: refused")
said = dawview.action("P1", cfg, b, { play = "start" })
assert(started_ev and started_ev.type == "start" and started_ev.pos == 2 and started_ev.countin == 2 and started_ev.lead == "James", "the driver: Play together from the edit cursor")
dawview.action("P1", cfg, b, { play = "stop" })
assert(started_ev.type == "stop", "Stop together")
-- Restore: handed to the panel, never done here
said = dawview.action("P1", cfg, b, { restore = "nope.json" })
assert(#panel == 0 and said:find("isn't here"), "a version that isn't listed: nothing")
said = dawview.action("P1", cfg, b, { restore = "v1.json" })
assert(#panel == 1 and panel[1][2] == "restore v1.json" and said:find("Restore page"), "a listed one: the panel's Restore page opens on it")
-- after the page stops asking: nothing more built
clock = clock + dawview.WANT_FOR + 1
pubs, cc = {}, 9
dawview.tick("P1", cfg, b, publish, who, clock)
assert(#pubs == 0 and not dawview.watching(clock), "the page went: nothing built")

-- ---- payload: 40 tracks, 400 items (every fifth track MIDI), 20 s each ----------------------------------------------------------------
local big = { len = 480, tracks = {}, markers = {} }
for t = 1, 40 do
  local tr = { name = "Track " .. t, oid = "t" .. t, color = 0x1000000 | t * 999, items = {} }
  for i = 1, 10 do
    local item = { pos = (i - 1) * 24, len = 20, name = ("Track_%d-James-20261119-1200%02d.flac"):format(t, i) }
    if t % 5 == 0 then
      item.midi, item.notes = true, {}
      for n = 0, 79 do item.notes[#item.notes + 1] = { s = n * 240, e = n * 240 + 200, pitch = 36 + n % 24 } end
    end
    tr.items[i] = item
  end
  big.tracks[t] = tr
end
for m = 1, 12 do big.markers[m] = { pos = m * 40, rend = m * 40 + 30, name = "Section " .. m, region = true } end
setup_fake(big)
reaper.TimeMap_GetMeasureInfo = function(_, m) return m * 2, m * 4, m * 4 + 4, 4, 4, 120 end
dawview.reset()
pubs, published = {}, {}
local sizes = {}
local function size_publish(topic, t)
  local js = band.json_encode(t)
  if published[topic] ~= js then published[topic] = js; sizes[topic] = #js; pubs[#pubs + 1] = topic end
end
dawview.action("P1", cfg, b, { want = true })
local t0 = os.clock()
dawview.tick("P1", cfg, { song = "Big", room = "main" }, size_publish, who, clock)
local build_ms = (os.clock() - t0) * 1000
local total, nchunks = 0, 0
for topic, n in pairs(sizes) do total = total + n; if topic:find("^dawc%d") then nchunks = nchunks + 1 end end
local items = 0
for k = 0, nchunks - 1 do for _, l in ipairs(band.json_decode(published["dawc" .. k]).tr) do items = items + #l end end
assert(items == 400 and nchunks == 10, "all 400 items in 10 chunks: " .. items .. ", " .. nchunks)
sizes = {}
cc, big.tracks[17].items[3].pos = cc + 1, 100.25
clock = clock + 1
t0 = os.clock()
dawview.tick("P1", cfg, { song = "Big", room = "main" }, size_publish, who, clock)
local edit_ms = (os.clock() - t0) * 1000
local resent = 0
for _, n in pairs(sizes) do resent = resent + n end
local lo, hi = math.huge, 0
for k = 0, nchunks - 1 do local n = #published["dawc" .. k]; lo, hi = math.min(lo, n), math.max(hi, n) end
print(string.format("payload, 40 tracks / 400 items: whole song %d bytes (header %d, %d chunks of %d-%d, cursors %d); one item moved resends %d bytes;"
  .. " first build %.0f ms, look after an edit %.0f ms (plain Lua 5.4, stand-in REAPER)", total, #published.daw, nchunks, lo, hi, #published.dawcur, resent, build_ms, edit_ms))
assert(total < 400 * 1024, "the whole song under 400 KB: " .. total)
assert(resent > 0 and resent < total / 5, "an edit resends a fraction: " .. resent .. " of " .. total)

-- ---- the page files: there, linked, and talking to the topics above ---------------------------------------------------------------------
local function read(path) local f = assert(io.open(path, "rb"), path); local d = f:read("a"); f:close(); return d end
local html, app, js, css = read("lib/webui/index.html"), read("lib/webui/app.js"), read("lib/webui/daw.js"), read("lib/webui/daw.css")
assert(html:find('<link rel="stylesheet" href="daw.css">', 1, true) and html:find('<script src="daw.js" defer></script>', 1, true), "index.html links daw.css and daw.js")
assert(app:find("dispatchEvent(new CustomEvent('ss-state'", 1, true), "app.js hands the state on")
for _, want in ipairs({ "addEventListener('ss-state'", "fetch('api/state')", "'X-StudioSync': '1'", "topic: 'daw'", "T.daw", "'dawc' + k", "t.dawcur", "t.dawhist",
    "{ want: true, history: histOn }", "{ play: 'start' }", "{ play: 'stop' }", "{ restore: v.f }", "touch-action", "'wheel'", "pointerdown" }) do
  assert((js .. css):find(want, 1, true), "the Song page has " .. want)
end
assert(not js:find("innerHTML%s*=%s*[^'\n]*%+") , "no data put in as HTML")
assert(css:find("@media (max-width: 320px)", 1, true) and css:find("touch-action: none", 1, true), "a docker layout, and the canvas takes touches")
print("ok")
