-- The shared DAW view, stage 1 (docs/realtime-roadmap.md "What the web UI makes possible": Shared DAW view, Song history): what the web UI's
-- Song page draws (lib/webui/daw.js), built from the project in front and published by lib/webui.lua as topics:
--   daw      tracks (name, colour, folder depth, mute/solo), markers and regions, bars, tempo and grid, how many item chunks there are
--   dawc<k>  the items of DAW_CHUNK tracks each (position, length, colour, waveform peaks or MIDI notes): only a changed chunk goes again
--   dawcur   the play cursor and everyone's edit cursor and view (follow)
--   dawhist  the song's life (History): every change as a dot on its track, saved versions, notes
-- Built only while a page has the Song page open (it says so every few seconds, an action "want"); the project is looked at again only when
-- REAPER's change count moves (and every FLOOR s), peaks are read within a small time budget a tick and kept, history comes from recall.lua's
-- own cache. Everything is read-only, apart from Play/Stop together (only for whoever may), a version handed to the panel's own Restore page,
-- which asks as it always does, and stage 2's item and marker edits (lib/dawedit.lua, checked as this computer's own edits are). Stage 3's
-- piano roll and automation lanes (lib/dawmidi.lua) come through here too: their own topics, dawmidi and dawenv, and edits. (James, rt)
local band = require("band")
local dawview = {}
dawview.CHUNK_TRACKS = 4    -- tracks per item chunk: an edit resends its chunk only
dawview.PEAKS_PER_SEC = 10  -- waveform columns a second of item (a phone's fit-to-song view needs fewer; zoomed in it's still a shape)
dawview.PEAKS_MIN, dawview.PEAKS_MAX = 4, 600
dawview.NOTES_MAX = 400     -- notes drawn per MIDI item (the first ones)
dawview.NAME_MAX = 40       -- characters of an item's name
dawview.WANT_FOR = 30       -- seconds a page's "I'm looking at the Song page" lasts (pages say it every 10 s)
dawview.LOOK_EVERY = 0.25   -- seconds between looks at REAPER's change count
dawview.FLOOR = 10          -- a whole look at least this often (anything the change count misses)
dawview.PEAK_BUDGET = 0.006 -- seconds of peak reading a tick (a song opened with 400 items fills in over a second or two)
dawview.PEAK_RETRY = 5      -- seconds before asking again for peaks REAPER hasn't built yet
dawview.CUR_EVERY = 1       -- seconds between play cursor updates while playing (the page moves it on by itself between them)
dawview.CUR_MIN = 0.2       -- seconds between edit cursor / view updates while it's being dragged
dawview.HIST_EVERY = 10     -- seconds between history builds while History is showing
dawview.HIST_MAX = 2000     -- changes drawn (the newest)
dawview.NOTE_TEXT = 200     -- characters of a note shown
dawview.MAX_BARS = 2000
dawview.SLICE = 0.003       -- seconds of a look a tick: a big song's look (150 tracks, 4,000 items: ~50 ms) goes over several ticks

-- A look spread over ticks (bigger projects, James, rt: 4,000 items read and built in one tick held REAPER up ~50 ms each time the change
-- count moved, 4 times a second while editing). dawview.tick runs a look in a coroutine and sets `slice_end` while it resumes it; between
-- tracks, read and build hand the tick back once it's spent. Outside that coroutine (tests, a direct call) nothing pauses. Only between tracks:
-- no REAPER pointer is held across a pause (each track is asked for afresh by its index), and a look that saw the project change meanwhile is
-- followed by another, as the change count at its start was kept.
local slice_end
local function pause()
  if slice_end and coroutine.isyieldable() and reaper.time_precise() > slice_end then coroutine.yield(); return true end
  return false
end
-- A REAPER call that doesn't work inside a coroutine, made by the tick outside it: REAPER 7.86's GetMediaItemTake_Peaks called in one gives
-- back nothing and fills its buffer with junk (measured in REAPER; the look failed at every audio item, so the daw topic never went out and
-- the phone's Project view waited for it for ever. rt-phonefix). The tick sees OUTSIDE, makes the call and resumes the look with its answers.
local OUTSIDE = {}
local function outside(fn, ...)
  if slice_end and coroutine.isyieldable() then return coroutine.yield(OUTSIDE, fn, ...) end
  return fn(...)
end

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
local ALPHA = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_" -- (64 levels, one character each, nothing JSON escapes)
dawview.ALPHA = ALPHA
local function r3(x) return math.floor((tonumber(x) or 0) * 1000 + 0.5) / 1000 end
dawview.r3 = r3
function dawview.hex(r, g, b) return string.format("#%02x%02x%02x", r & 255, g & 255, b & 255) end
-- Columns for an item `len` seconds long.
function dawview.peak_count(len)
  return math.max(dawview.PEAKS_MIN, math.min(dawview.PEAKS_MAX, math.ceil((tonumber(len) or 0) * dawview.PEAKS_PER_SEC)))
end
-- REAPER's peaks (maximums and minimums, `got` of each, 1-based) -> `n` characters, each the loudest of its share, 0 to 63 of full scale.
-- Fewer peaks than columns: each column shows the one it falls on.
function dawview.peak_chars(maxs, mins, got, n)
  if (got or 0) <= 0 or (n or 0) <= 0 then return "" end
  local out = {}
  for i = 1, n do
    local a = math.floor((i - 1) * got / n) + 1
    local z = math.max(a, math.floor(i * got / n))
    local v = 0
    for j = a, z do
      local x = math.max(math.abs(tonumber(maxs[j]) or 0), math.abs(tonumber(mins[j]) or 0))
      if x > v then v = x end
    end
    local q = math.floor(math.min(v, 1) * 63 + 0.5)
    out[i] = ALPHA:sub(q + 1, q + 1)
  end
  return table.concat(out)
end

-- What may press Play/Stop together from a page (the page acts as this computer's user): a room run by the driver, only the driver; an
-- admins' room, the driver and whoever may manage; otherwise anyone, as the panel's own buttons. (James, rt)
function dawview.may_transport(mode, user, driver, may_manage)
  if mode == "driver" then return user == driver end
  if mode == "admins" then return user == driver or may_manage == true end
  return true
end
-- That rule for this computer's user in the room now (who: sync.authority's second answer; read here when nil). -> nil when they may, or why
-- not in words. The Song page's Play/Stop and the Play page's Play/Record/Stop together (lib/webpages.lua) both ask it.
function dawview.transport_refusal(cfg, b, who)
  who = who or select(2, require("sync").authority(cfg, b.song, b.room))
  if dawview.may_transport(who.mode, cfg.user, who.driver, require("groups").may_manage(cfg.root, cfg.user)) then return nil end
  return who.mode == "admins" and "only the driver and admins start and stop" or "only the driver starts and stops"
end

-- raw (the reader's, below): { key, len, tracks = { { name, rgb, depth, folder, mute, solo, items = { { pos, len, rgb, mute, name, midi,
-- peaks, notes, nh } } } }, markers = { { pos, rend, name, rgb, region } }, bars, sigs, tempo, grid }
-- -> the header (without its chunk count) and the chunks, each { sig, t } (sig: a cheap fingerprint, so a chunk is encoded only when it
-- changed: JSON-encoding a big song every look would stall REAPER for tens of ms).
local function item_out(it)
  local o = { p = r3(it.pos), l = r3(it.len), c = it.rgb, m = it.mute and 1 or nil, n = it.name ~= "" and it.name or nil }
  if it.midi then o.x = 1; o.nt = it.notes else o.k = it.peaks end
  o.v = it.vid -- (a video or picture item: which file, where in it, how fast; the page draws its frames. lib/video.lua, rt-video2)
  -- (its own fades, in and out: length and, when not linear, shape 0..6. Not the auto-crossfade's: those come from overlaps. rt-p14)
  if (it.fi or 0) > 0 then o.fi, o.fis = r3(it.fi), it.fis ~= 0 and it.fis or nil end
  if (it.fo or 0) > 0 then o.fo, o.fos = r3(it.fo), it.fos ~= 0 and it.fos or nil end
  return o
end
local function item_sig(it)
  return table.concat({ r3(it.pos), r3(it.len), it.rgb or "", it.mute and 1 or 0, it.name or "", it.midi and ("x" .. (it.nh or #(it.notes or {}))) or (it.peaks or ""),
    it.vid and (it.vid.id .. "@" .. it.vid.o .. "x" .. it.vid.r) or "", r3(it.fi or 0), it.fis or 0, r3(it.fo or 0), it.fos or 0 }, "|")
end
function dawview.build(raw, per)
  per = per or dawview.CHUNK_TRACKS
  local tracks, chunks = {}, {}
  for i, tr in ipairs(raw.tracks or {}) do
    pause()
    -- (e: how many envelopes it has, so the page offers its automation lanes: stage 3, lib/dawmidi.lua)
    tracks[i] = { n = tr.name, c = tr.rgb, d = tr.depth > 0 and tr.depth or nil, f = tr.folder and 1 or nil, m = tr.mute and 1 or nil, s = tr.solo and 1 or nil,
      e = (tr.envs or 0) > 0 and tr.envs or nil }
    local k = (i - 1) // per + 1
    local ch = chunks[k]
    if not ch then ch = { sig = {}, t = { key = raw.key, k = k - 1, from = i - 1, tr = {} } }; chunks[k] = ch end
    local list = {}
    for j, it in ipairs(tr.items or {}) do list[j] = item_out(it); ch.sig[#ch.sig + 1] = item_sig(it) end
    ch.t.tr[#ch.t.tr + 1] = list
    ch.sig[#ch.sig + 1] = "/"
  end
  for _, ch in ipairs(chunks) do ch.sig = (raw.key or "") .. "#" .. table.concat(ch.sig, ";") end
  local markers = {}
  -- (i: REAPER's own number for it, which an edit from the page names it by: lib/dawedit.lua)
  for i, m in ipairs(raw.markers or {}) do markers[i] = { p = r3(m.pos), e = m.region and r3(m.rend) or nil, n = m.name ~= "" and m.name or nil, c = m.rgb, i = m.num } end
  local header = { key = raw.key, len = r3(raw.len), tracks = tracks, markers = markers, bars = raw.bars or {}, sigs = raw.sigs or {},
    tempo = raw.tempo or {}, grid = raw.grid, per = per, snap = raw.snap and 1 or nil }
  return header, chunks
end
-- Which chunks to publish: the ones whose fingerprint moved since `state.sigs`, and the topics of chunks no longer there (published once as
-- empty, so a song that lost tracks doesn't keep the old ones' items on the server). Updates `state`. -> changed, gone (0-based numbers).
function dawview.diff(state, chunks)
  state.sigs = state.sigs or {}
  local changed, gone = {}, {}
  for k, ch in ipairs(chunks) do
    if state.sigs[k] ~= ch.sig then state.sigs[k] = ch.sig; changed[#changed + 1] = k - 1 end
  end
  for k = #chunks + 1, state.n or 0 do if state.sigs[k] then state.sigs[k] = nil; gone[#gone + 1] = k - 1 end end
  state.n = #chunks
  return changed, gone
end

-- The cursors: me = { user, playing, rec, pos, cursor, view = { a, z }, rate }; peers: presence's statuses (cursor and view only while someone
-- watches them, below); colours: user -> 0xRRGGBB; editing: user -> what they're editing right now (lib/follow.lua). -> the dawcur topic's table.
local function hexof(rgb) return rgb and dawview.hex(rgb >> 16, rgb >> 8, rgb) or nil end
function dawview.cursor_model(key, me, peers, colours, editing)
  colours = colours or {}
  local view = type(me.view) == "table" and { r3(me.view[1]), r3(me.view[2]) } or nil
  local out = { key = key, play = { on = me.playing and 1 or nil, rec = me.rec and 1 or nil, pos = r3(me.pos), rate = me.rate ~= 1 and me.rate or nil },
    me = { user = me.user, cur = r3(me.cursor), view = view, col = hexof(colours[me.user]) }, people = {} }
  local list = {}
  for _, st in ipairs(peers or {}) do
    if type(st) == "table" and type(st.user) == "string" and st.user ~= me.user then
      local v = type(st.view) == "table" and tonumber(st.view[1]) and tonumber(st.view[2]) and { r3(st.view[1]), r3(st.view[2]) } or nil
      list[#list + 1] = { user = st.user, cur = tonumber(st.cursor) and r3(st.cursor) or nil, view = v, on = st.playing and 1 or nil,
        rec = st.recording and 1 or nil, last = tonumber(st.last_at) and r3(st.last_at) or nil, col = hexof(colours[st.user]), ed = editing and editing[st.user] or nil }
    end
  end
  table.sort(list, function(a, z) return a.user:lower() < z.user:lower() end)
  out.people = list
  return out
end

-- History. evs: recall's events (cached), versions: recall.list's rows (newest first), lane_of(ev) -> a track's 0-based place or nil,
-- colours: user -> 0xRRGGBB. -> { key, users, cols, dots = { { t, lane, user#, kind, pos } }, notes, versions }, the newest HIST_MAX changes.
-- kind: a added, c changed, d deleted, r brought back, t track, f plug-ins, e automation/sends/settings, m tempo or markers.
local function kind_of(e)
  local k = e.kind or e.type
  if k == "obj" then
    if e.gone then return "d" end
    if e.restored then return "r" end
    if e.obj == "item" then return (e.rev or 1) == 1 and "a" or "c" end
    if e.obj == "track" then return "t" end
    if e.obj == "fx" then return "f" end
    return "e"
  end
  if k == "timeline" or k == "shift" then return "m" end
  if k == "edit" or k == "midi" then return "c" end
  if k == "delete" then return "d" end
  if k == "undelete" then return "r" end
  if k == "track" or k == "plays" then return "t" end
  return nil -- (handovers, play/stop together, likes: not changes to the song)
end
function dawview.history_model(key, evs, versions, lane_of, colours, max)
  max = max or dawview.HIST_MAX
  local list, notes = {}, {}
  for _, e in ipairs(evs or {}) do
    if type(e) == "table" and type(e.user) == "string" and type(e.time) == "string" and not e.auto then
      local k = e.kind or e.type
      if k == "note" and type(e.text) == "string" then notes[#notes + 1] = e
      elseif kind_of(e) then list[#list + 1] = e end
    end
  end
  local function older(a, z) return (a.time .. tostring(a.id)) < (z.time .. tostring(z.id)) end
  table.sort(list, older)
  table.sort(notes, older)
  local users, uix, cols = {}, {}, {}
  local function u(name)
    if not uix[name] then users[#users + 1] = name; uix[name] = #users - 1; cols[#users] = hexof(colours and colours[name]) or false end
    return uix[name]
  end
  local dots = {}
  for i = math.max(1, #list - max + 1), #list do
    local e = list[i]
    dots[#dots + 1] = { band.iso_time(e.time) or 0, lane_of(e) or -1, u(e.user), kind_of(e), tonumber(e.pos) and r3(e.pos) or false }
  end
  local nout = {}
  for i = math.max(1, #notes - 200 + 1), #notes do
    local e = notes[i]
    nout[#nout + 1] = { t = band.iso_time(e.time) or 0, u = u(e.user), pos = tonumber(e.pos) and r3(e.pos) or nil, lane = lane_of(e),
      text = e.text:sub(1, dawview.NOTE_TEXT), client = type(e.client) == "string" and e.client or nil }
  end
  local vout = {}
  for _, v in ipairs(versions or {}) do
    if type(v) == "table" and type(v.file) == "string" then
      vout[#vout + 1] = { f = v.file, label = tostring(v.label or v.file), by = type(v.by) == "string" and v.by or nil, t = band.iso_time(v.time) or 0,
        keep = v.keep and 1 or nil, behind = v.behind and 1 or nil }
      if type(v.by) == "string" then u(v.by) end
    end
  end
  table.sort(vout, function(a, z) return a.t < z.t end)
  return { key = key, users = users, cols = cols, dots = dots, notes = nout, versions = vout }
end

-- An action from a page ({ topic = "daw", ... }) -> what it asks for, checked: { want, history, play = "start"|"stop", restore = file }.
function dawview.parse(a)
  if type(a) ~= "table" then return nil end
  -- (nohistory: the Song page saying it's off; a want without either, the phone's, leaves the history as another page asked)
  local out = { want = a.want == true or nil, history = a.history == true or nil, nohistory = a.history == false or nil }
  if a.play == "start" or a.play == "stop" then out.play = a.play end
  out.skip = a.play == "start" and a.skip == true or nil -- (the Song page's "skip selection": lib/together.lua. James, 2026-11-21)
  -- (a saved version's file name, as recall names them: nothing that could point anywhere else)
  if type(a.restore) == "string" and #a.restore <= 200 and a.restore:match("^[%w][%w%-_ %.]*%.json$") and not a.restore:find("%.%.") then out.restore = a.restore end
  return out
end

-- ---- reading REAPER ---------------------------------------------------------------------------------------------------------------------
local function native_rgb(c)
  c = math.floor(tonumber(c) or 0)
  if c & 0x1000000 == 0 then return nil end -- (no colour of its own)
  local r, g, b = reaper.ColorFromNative(c & 0xFFFFFF)
  return dawview.hex(r, g, b)
end
dawview.native_rgb = native_rgb
-- What the page shows (dawview.read, and lib/dawedit.lua finding what an edit points at): the studio's tracks as everyone has them (not this
-- computer's own ones, stem prints or tracks hidden in the arrange view), and on a track with fixed lanes only the lanes that play (as REAPER's
-- collapsed view; the other takes are comps-in-waiting).
function dawview.shown(tr)
  return not require("mirror").local_track(tr) and band.track_ext(tr, "band_stem") == "" and reaper.GetMediaTrackInfo_Value(tr, "B_SHOWINTCP") ~= 0
end
function dawview.items_of(tr)
  local out, lanes = {}, reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") == 2
  for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, j)
    local lane = lanes and math.floor(reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE")) or nil
    if not lane or reaper.GetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. lane) ~= 0 then out[#out + 1] = it end
  end
  return out
end
local peak_cache, note_cache = {}, {} -- take pointer -> { sig, s / notes, at }
local function take_peaks(take, pos, len, now, budget_end)
  local key = tostring(take)
  local src = reaper.GetMediaItemTake_Source(take)
  local sig = table.concat({ src and reaper.GetMediaSourceFileName(src) or "", r3(reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")),
    reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"), r3(len) }, "|")
  local c = peak_cache[key]
  if c and c.sig == sig and (c.s or now - c.at < dawview.PEAK_RETRY) then c.seen = true; return c.s, false end
  if reaper.time_precise() > budget_end then return c and c.sig == sig and c.s or nil, true end -- (next tick)
  local n = dawview.peak_count(len)
  local want = n * 2 -- (twice the columns, each column the louder of two: REAPER's own reduction is a sample, not a maximum)
  local buf = reaper.new_array(want * 2)
  local rv = outside(reaper.GetMediaItemTake_Peaks, take, want / len, pos, 1, want, 0, buf)
  local got = math.floor(tonumber(rv) or 0) & 0xFFFFF -- (no answer: no peaks this time, asked again after PEAK_RETRY s, never the whole look lost)
  local s
  if got > 0 then
    local t = buf.table()
    local maxs, mins = {}, {}
    for i = 1, got do maxs[i] = t[i]; mins[i] = t[want + i] end
    s = dawview.peak_chars(maxs, mins, got, math.max(1, math.floor(n * got / want + 0.5)))
  end
  peak_cache[key] = { sig = sig, s = s, at = now, seen = true }
  return s, false
end
local function take_notes(take, pos, len)
  local key = tostring(take)
  local _, h = reaper.MIDI_GetHash(take, true)
  local sig = table.concat({ h or "", r3(pos), r3(len) }, "|")
  local c = note_cache[key]
  if c and c.sig == sig then c.seen = true; return c.notes, h end
  local notes = {}
  local _, n = reaper.MIDI_CountEvts(take)
  for i = 0, math.min(n or 0, dawview.NOTES_MAX) - 1 do
    local _, _, muted, s, e, _, pitch = reaper.MIDI_GetNote(take, i)
    if not muted then
      local a = reaper.MIDI_GetProjTimeFromPPQPos(take, s) - pos
      local z = reaper.MIDI_GetProjTimeFromPPQPos(take, e) - pos
      if z > 0 and a < len then
        notes[#notes + 1] = math.floor(math.max(0, a) * 1000 + 0.5)
        notes[#notes + 1] = math.max(1, math.floor((math.min(z, len) - math.max(0, a)) * 1000 + 0.5))
        notes[#notes + 1] = math.floor(pitch)
      end
    end
  end
  note_cache[key] = { sig = sig, notes = notes, seen = true }
  return notes, h
end
-- One track's items as the page draws them. -> the list, whether some peaks are still to read, whether to read this track again next look
-- (peaks REAPER hasn't built yet, or a video item, which the look offers again each time).
local function read_items(tr, now, budget_end)
  local items, pending, again = {}, false, false
  for _, it in ipairs(dawview.items_of(tr)) do
    local pos, len = reaper.GetMediaItemInfo_Value(it, "D_POSITION"), reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
    local take = reaper.GetActiveTake(it)
    local o = { pos = pos, len = len, mute = reaper.GetMediaItemInfo_Value(it, "B_MUTE") ~= 0, name = "",
      rgb = native_rgb(reaper.GetMediaItemInfo_Value(it, "I_CUSTOMCOLOR")),
      fi = reaper.GetMediaItemInfo_Value(it, "D_FADEINLEN"), fo = reaper.GetMediaItemInfo_Value(it, "D_FADEOUTLEN") }
    -- (the shapes only where there's a fade: two calls fewer an item on a song with none)
    if (o.fi or 0) > 0 then o.fis = math.floor(reaper.GetMediaItemInfo_Value(it, "C_FADEINSHAPE")) end
    if (o.fo or 0) > 0 then o.fos = math.floor(reaper.GetMediaItemInfo_Value(it, "C_FADEOUTSHAPE")) end
    if take then
      o.name = reaper.GetTakeName(take):sub(1, dawview.NAME_MAX)
      o.rgb = native_rgb(reaper.GetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR")) or o.rgb
      if reaper.TakeIsMIDI(take) then o.midi = true; o.notes, o.nh = take_notes(take, pos, len)
      elseif len > 0 then
        local more
        o.peaks, more = take_peaks(take, pos, len, now, budget_end)
        pending = pending or more
        o.vid = require("video").take(take, now)
        again = again or more or o.peaks == nil or o.vid ~= nil
      end
    end
    items[#items + 1] = o
  end
  return items, pending, again
end
-- A track's key in the partial look's memory: its pointer and its GUID (a pointer can be handed to a new track after a deletion).
local function tkey(tr) return tostring(tr) .. "\0" .. tostring(reaper.GetTrackGUID(tr)) end
-- What a track's items show that its own count, first and last item and lanes would move: a cheap line per track for the partial look (below).
local function items_fp(tr)
  local n = reaper.CountTrackMediaItems(tr)
  local f = { n, reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") }
  if n > 0 then
    local a, z = reaper.GetTrackMediaItem(tr, 0), reaper.GetTrackMediaItem(tr, n - 1)
    f[#f + 1] = reaper.GetMediaItemInfo_Value(a, "D_POSITION")
    f[#f + 1] = reaper.GetMediaItemInfo_Value(z, "D_POSITION")
    f[#f + 1] = reaper.GetMediaItemInfo_Value(z, "D_LENGTH")
  end
  return table.concat(f, " ")
end
-- The project as the page draws it. -> raw (dawview.build's), whether some peaks are still to read, and the tracks' oids and names to places.
-- tc (the tick's, nil: everything is read): the last look's items per track by GUID. With `full` not set, a track's items are read again only when
-- its fingerprint moved (items_fp), it's one an edit was most likely on (mirror.hinted: selected items and tracks, the MIDI editor's, the last
-- touched; also what the last look hinted, so a deselect straight after an edit doesn't hide it), or it's waiting on peaks or holds a video.
-- The track lines themselves (name, colour, mute, solo, folders, envelopes) are always read: they cost ~6 calls a track. A change the fingerprint
-- and the hints can't see (another script's edit of an unselected item in the middle of a track) shows at the next whole read, within FLOOR s.
-- (rt-perf cut 8: the whole read was 40-45 ms on a heavy song, up to four times a second while editing.)
function dawview.read(proj, key, now, budget_end, tc, full)
  local mirror = require("mirror")
  local partial = tc ~= nil and not full
  if not partial then
    for _, c in pairs(peak_cache) do c.seen = nil end
    for _, c in pairs(note_cache) do c.seen = nil end
  end
  local hint = tc and mirror.hinted and mirror.hinted(proj) or {}
  local was_hint, keep = tc and tc.hint or {}, {}
  local raw = { key = key, len = reaper.GetProjectLength(proj), tracks = {}, markers = {}, bars = {}, sigs = {}, tempo = {} }
  local places, pending, level = {}, false, 0
  local paused = false
  for i = 0, reaper.CountTracks(proj) - 1 do
    -- (tracks deleted, or the tab closed, while paused: the rest is left for the next look, which the moved change count makes. Every track
    -- after a pause, not only the one it paused at: resumed at track 40 with 50 left, track 50 was read as nil. rt-look)
    paused = pause() or paused
    if paused and not (reaper.ValidatePtr2(0, proj, "ReaProject*") and i < reaper.CountTracks(proj)) then break end
    local tr = reaper.GetTrack(proj, i)
    local fd = math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH"))
    local indent = level
    level = math.max(0, level + fd)
    if dawview.shown(tr) then
      local name = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false))
      local t = { name = name, rgb = native_rgb(band.track_colour(tr)), depth = indent, folder = fd == 1, mute = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") ~= 0,
        solo = reaper.GetMediaTrackInfo_Value(tr, "I_SOLO") ~= 0, items = {}, envs = tonumber(reaper.CountTrackEnvelopes(tr)) or 0 }
      raw.tracks[#raw.tracks + 1] = t
      local place = #raw.tracks - 1
      local oid = mirror.track_oid(tr)
      if oid ~= "" then places[oid] = place end
      if name ~= "" and not places[name:lower()] then places[name:lower()] = place end
      if tc then
        local g, fp = tkey(tr), items_fp(tr)
        local old = partial and tc.tracks[g]
        if old and old.fp == fp and not old.again and not hint[tr] and not hint[tostring(tr)] and not was_hint[g] then
          t.items = old.items
          keep[g] = old
        else
          local more, again
          t.items, more, again = read_items(tr, now, budget_end)
          pending = pending or more
          keep[g] = { fp = fp, items = t.items, again = again }
        end
      else
        local more
        t.items, more = read_items(tr, now, budget_end)
        pending = pending or more
      end
    end
  end
  if tc then
    tc.tracks = keep
    tc.hint = {}
    for tr in pairs(hint) do if type(tr) ~= "string" then tc.hint[tkey(tr)] = true end end
  end
  if not partial then -- (a partial look didn't touch the takes of the tracks it kept: theirs stay until the next whole one)
    for k, c in pairs(peak_cache) do if not c.seen then peak_cache[k] = nil end end -- (deleted items' and closed projects' go)
    for k, c in pairs(note_cache) do if not c.seen then note_cache[k] = nil end end
  end
  local i = 0
  while true do
    local n, rgn, pos, rend, name, num, color = reaper.EnumProjectMarkers3(proj, i)
    if n == 0 then break end
    if not band.is_local_mark(name) then raw.markers[#raw.markers + 1] = { pos = pos, rend = rend, name = name, rgb = native_rgb(color), region = rgn, num = num } end
    i = i + 1
  end
  local last_num, last_den
  local stop = math.max(raw.len, 1) + 30
  for m = 0, dawview.MAX_BARS - 1 do
    local t, _, _, num, den = reaper.TimeMap_GetMeasureInfo(proj, m)
    if t > stop then break end
    raw.bars[#raw.bars + 1] = r3(t)
    if num ~= last_num or den ~= last_den then raw.sigs[#raw.sigs + 1] = { m, num, den }; last_num, last_den = num, den end
  end
  for _, tm in ipairs(band.capture_tempo(proj)) do
    if #raw.tempo < 200 then raw.tempo[#raw.tempo + 1] = { r3(tm.time), math.floor(tm.bpm * 100 + 0.5) / 100 } end
  end
  raw.grid = select(2, reaper.GetSetProjectGrid(proj, false))
  raw.snap = reaper.GetToggleCommandStateEx(0, band.FRONT_TOGGLES.snap) == 1 -- (the page snaps a drag as REAPER would; dawedit snaps it again)
  return raw, pending, places
end

-- ---- Live sync's tick (through lib/webui.lua) -------------------------------------------------------------------------------------------
local S = { want_until = -math.huge, hist_until = -math.huge }
-- A page is looking at the Song page (lib/webui.lua puts it in this computer's status, so bandmates send their cursor and view meanwhile).
function dawview.watching(now) return (now or reaper.time_precise()) < S.want_until end
-- Everything goes again (the tab in front changed: another tab's topics may be on the server).
function dawview.reset()
  S = { want_until = S.want_until, hist_until = S.hist_until }
  if package.loaded.dawmidi then package.loaded.dawmidi.reset() end
end
local function scripts_dir() return (debug.getinfo(1, "S").source:match("^@?(.*)[/\\]lib[/\\][^/\\]+$")) end

-- An action a page sent. -> words for the log, or nil.
function dawview.action(proj, cfg, b, a)
  -- (stage 2: an item or marker edit, checked and applied by lib/dawedit.lua; its answer goes back as the dawedit topic, below)
  -- (an edit or a piano roll change from a page writes items nobody selected: the next look reads every track. rt-perfcut4)
  if type(a) == "table" and (type(a.edit) == "table" or type(a.look) == "table" or a.note ~= nil or a.auto ~= nil or a.send ~= nil) then S.dirty_all = true end
  if type(a) == "table" and type(a.edit) == "table" then return require("dawedit").action(proj, cfg, b, a.edit) end
  -- (stage 3: what the piano roll and the automation lanes show, and their note and envelope point edits: lib/dawmidi.lua)
  if type(a) == "table" and (type(a.look) == "table" or a.note ~= nil or a.auto ~= nil or a.send ~= nil) then return require("dawmidi").action(proj, cfg, b, a) end
  local d = dawview.parse(a)
  if not d then return end
  local now = reaper.time_precise()
  if d.want then S.want_until = now + dawview.WANT_FOR end
  if d.want and d.history then S.hist_until = now + dawview.WANT_FOR end
  if d.want and d.nohistory then S.hist_until = -math.huge end
  if d.play then
    local why = dawview.transport_refusal(cfg, b)
    if why then return "the web page's " .. (d.play == "start" and "Play" or "Stop") .. " together was refused: " .. why .. " in this room" end
    local together = require("together")
    if d.play == "start" then
      -- (as the panel's Play together with its defaults: from the edit cursor, a bar's count-in with the click)
      together.start(proj, cfg, b, reaper.GetCursorPositionEx(proj), false, 1, true, 0, d.skip)
      return "Play together, from the web page"
    end
    together.go(proj, cfg, b, { type = "stop" })
    return "Stop together, from the web page"
  end
  if d.restore then
    -- (never restored from here: the panel's Restore page opens on that version, and its own buttons ask as they always do)
    for _, v in ipairs(require("recall").list(cfg, b.song, b.room)) do
      if v.file == d.restore then
        band.panel_do(scripts_dir(), "restore " .. v.file)
        return "the web page asked to restore '" .. tostring(v.label) .. "': it's open on the panel's Restore page, to confirm there"
      end
    end
    return "the web page asked to restore a version that isn't here"
  end
end

-- Each tick in front, while a page looks. publish(topic, table) is lib/webui.lua's (sends only what changed); who: sync.authority's second
-- answer from webui's presence build (nil until it has one).
function dawview.tick(proj, cfg, b, publish, who, now)
  if now >= S.want_until then return end
  local de = package.loaded.dawedit -- (the last edit's answer: the page that sent it snaps back on a refusal, with the reason)
  if de and de.reply then publish("dawedit", de.reply) end
  local key = b.song .. "/" .. b.room
  if S.key ~= key then dawview.reset(); S.key = key end
  require("video").root = cfg.root -- (which files the page may have frames of: the studio's shared folder only. rt-video2)
  local cc = reaper.GetProjectStateChangeCount(proj)
  if not S.look and (S.pending or (now - (S.looked or -math.huge) >= dawview.LOOK_EVERY and (cc ~= S.cc or now - (S.full or -math.huge) >= dawview.FLOOR))) then
    S.looked, S.cc = now, cc
    if not S.pending then S.full = now end
    -- (a look reads only the tracks that may have changed, rt-perf cut 8, unless this one must see everything: the first, one each FLOOR s, after
    -- StudioSync wrote the project (a bandmate's change landing, a put-back), after a page's edit, and while an undo can be redone: Undo moves
    -- anything, selected or not)
    local f_redo = reaper.Undo_CanRedo2
    local redo = f_redo and f_redo(proj) or ""
    local applied = require("mirror").applied or 0
    local full = not S.tc or now - (S.whole or -math.huge) >= dawview.FLOOR or S.dirty_all or applied ~= S.applied or redo ~= "" or S.redo ~= ""
    S.tc = S.tc or { tracks = {}, hint = {} }
    if full then S.whole = now end
    S.dirty_all, S.applied, S.redo = false, applied, redo
    local tc = S.tc
    local budget_end = reaper.time_precise() + dawview.PEAK_BUDGET
    local st = S -- (a reset meanwhile starts a new S: this look's results go nowhere then)
    st.look = coroutine.create(function()
      local raw, pending, places = dawview.read(proj, key, now, budget_end, tc, full)
      st.pending, st.places, st.track_names = pending, places, nil
      local header, chunks = dawview.build(raw)
      local changed, gone = dawview.diff(st, chunks)
      -- (chunks before the header: a page that sees the header has its chunks already)
      for _, k in ipairs(changed) do publish("dawc" .. k, chunks[k + 1].t); pause() end
      for _, k in ipairs(gone) do publish("dawc" .. k, { key = key, k = k, gone = true }) end
      header.chunks, header.me = #chunks, cfg.user
      header.may = who and dawview.may_transport(who.mode, cfg.user, who.driver, require("groups").may_manage(cfg.root, cfg.user)) or nil
      publish("daw", header)
    end)
  end
  if S.look then -- (this tick's share of the look: all of it on a small song)
    local co = S.look
    slice_end = reaper.time_precise() + dawview.SLICE
    local r = table.pack(coroutine.resume(co))
    while r[1] and r[2] == OUTSIDE do -- (a call the look can't make itself: made here, its answers handed back)
      local c = table.pack(pcall(r[3], table.unpack(r, 4, r.n)))
      if not c[1] then r = { false, c[2] }; break end
      r = table.pack(coroutine.resume(co, table.unpack(c, 2, c.n)))
    end
    local ok, err = r[1], r[2]
    slice_end = nil
    if not ok or coroutine.status(co) == "dead" then S.look = nil end
    if not ok then error(debug.traceback(co, tostring(err)), 0) end
  end
  -- the piano roll's item and the open automation lanes, only while a page shows them (lib/dawmidi.lua)
  require("dawmidi").tick(proj, cfg, b, publish, now)
  -- cursors: on a change; while playing, every CUR_EVERY s (the page moves it on between) or at a jump
  local ps = reaper.GetPlayStateEx(proj)
  local playing = ps & 1 == 1
  local pos = playing and reaper.GetPlayPositionEx(proj) or reaper.GetCursorPositionEx(proj)
  local a, z = reaper.GetSet_ArrangeView2(proj, false, 0, 0, 0, 0)
  local cur = reaper.GetCursorPositionEx(proj)
  local rate = reaper.Master_GetPlayRate(proj)
  local was = S.cur
  local jumped = was and playing and was.playing and math.abs(pos - (was.pos + (now - was.at) * was.rate)) > 0.25
  local moved = not was or was.playing ~= playing or was.rec ~= (ps & 4 == 4) or jumped or (playing and now - was.at >= dawview.CUR_EVERY)
    or (now - was.at >= dawview.CUR_MIN and (math.abs(was.cursor - cur) > 1e-3 or math.abs(was.a - a) > 0.05 or math.abs(was.z - z) > 0.05))
    or now - (S.peers_at or -math.huge) >= 1
  if moved then
    local presence = require("presence")
    local peers = presence.peers(cfg, b.song, b.room)
    local names = { cfg.user }
    for _, st in ipairs(peers) do if type(st.user) == "string" then names[#names + 1] = st.user end end
    local colours = require("people").colours(cfg.root, names)
    S.cur = { playing = playing, rec = ps & 4 == 4, pos = pos, at = now, rate = rate, cursor = cur, a = a, z = z }
    S.peers_at = now
    publish("dawcur", dawview.cursor_model(key, { user = cfg.user, playing = playing, rec = ps & 4 == 4, pos = pos, cursor = cur, view = { a, z }, rate = rate },
      peers, colours, require("follow").words_by_user()))
  end
  -- history, while it's showing: recall's reading a little each tick (its cache, shared with the panel's Restore page), built every HIST_EVERY s
  if now < S.hist_until then
    local recall = require("recall")
    local done = recall.warm(cfg, b.song, b.room, 0.004, false)
    if now - (S.hist_at or -math.huge) >= dawview.HIST_EVERY or (done and not S.hist_done) then
      S.hist_at, S.hist_done = now, done
      local places = S.places or {}
      local function lane_of(e)
        local oid = type(e.oid) == "string" and e.oid:upper() or nil
        local t = type(e.track) == "string" and e.track or nil
        return (e.obj == "track" and oid and places[oid]) or (t and (places[t:upper()] or places[t:lower()]))
          or (type(e.name) == "string" and places[e.name:lower()]) or nil
      end
      local evs = recall.read_so_far(cfg, b.song, b.room)
      local names = {}
      for _, e in ipairs(evs) do if type(e.user) == "string" then names[e.user] = true end end
      local list = {}
      for n in pairs(names) do list[#list + 1] = n end
      publish("dawhist", dawview.history_model(key, evs, recall.list(cfg, b.song, b.room), lane_of, require("people").colours(cfg.root, list)))
    end
  end
end

return dawview
