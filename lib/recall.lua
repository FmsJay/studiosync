-- Recall points: snapshots of the shared arrangement (which takes exist, where they sit, which take or lane
-- plays, track mute/solo/colour/icon), saved at every handover and whenever someone asks. Restoring one
-- makes the driver's project match it; Live sync then posts the differences as usual, so everyone follows.
-- Takes deleted since come back out of _trash. Restoring saves a "before restore" point first, so going
-- back and forth between options is always possible.
local band = require("band")
local sync = require("sync")
local recall = {}

function recall.dir(cfg, song, room) return sync.room_dir(cfg, song, room) .. "/recall" end

-- Lengths are the take's own, without the reverb tail its print carries (musical = true; points saved before
-- 0.16.1 included the tail, and restoring one added it a second time).
-- A take's notes as a fingerprint: each note's start, length, channel, pitch, velocity and mute, nothing else ("n2:"
-- first). REAPER's own MIDI hash changed with more than the notes (2026-10-29: every MIDI take looked "edited" in a
-- side room's preview, nobody had touched a note). Positions are the take's own, so moving the item doesn't change it.
local function notes_print(tk)
  local _, n = reaper.MIDI_CountEvts(tk)
  local parts = {}
  for i = 0, (n or 0) - 1 do
    local _, _, muted, s, e, ch, pitch, vel = reaper.MIDI_GetNote(tk, i)
    parts[#parts + 1] = string.format("%d:%d:%d:%d:%d:%d", math.floor(s + 0.5), math.floor(e - s + 0.5), ch, pitch, vel, muted and 1 or 0)
  end
  table.sort(parts)
  local h = 5381
  for c in table.concat(parts, ","):gmatch(".") do h = (h * 33 + c:byte()) % 4294967296 end
  return string.format("n2:%d:%08x", #parts, h)
end
recall.notes_print = notes_print

local function capture(proj)
  local st = { takes = {}, plays = {}, tracks = {}, musical = true }
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    local active = reaper.GetActiveTake(it)
    for k = 0, reaper.CountTakes(it) - 1 do
      local tk = reaper.GetTake(it, k)
      local id = band.take_id(tk)
      if id then
        st.takes[id] = { track = sync.track_name(it), pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION"),
          len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH") - (tonumber(sync.ext(proj, sync.TAILS, id)) or 0), lane = sync.lane_of(it), mute = reaper.GetMediaItemInfo_Value(it, "B_MUTE"),
          offs = reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS") - band.base_offs(tk), active = tk == active,
          rev = tonumber(sync.ext(proj, sync.REV, id)) } -- which print it was: a kept point's files are never cleaned up
        -- its notes (a MIDI take, or a bandmate's take's "(MIDI)" copy), so bringing a side room in can tell an edit
        local mtk = reaper.TakeIsMIDI(tk) and tk or select(2, band.find_midi(proj, id))
        if mtk then st.takes[id].notes = notes_print(mtk) end
      end
    end
  end
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    local any, ids = sync.audible(tr)
    if any and band.track_ext(tr, "band_stem") == "" and sync.speaks_for_name(proj, tr) then
      local name = sync.base_name(select(2, reaper.GetTrackName(tr)))
      local list = {}
      for id in ids:gmatch("[^,]+") do list[#list + 1] = id end
      st.plays[name] = list
      st.tracks[name] = { mute = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE"), solo = reaper.GetMediaTrackInfo_Value(tr, "I_SOLO"),
        color = band.color_out(band.track_colour(tr)),
        icon = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_ICON", "", false)) }
    end
  end
  return st
end

-- `keep`: kept for good (end of session): "Empty old trash" never removes the audio it needs.
-- The song as it stands, on purpose: a saved version kept for good, and the project on Drive where there is one (lib/sessionfile.lua).
function recall.back_up(proj, cfg, b, label)
  recall.save(proj, cfg, b.song, b.room, label or ("backup by " .. cfg.user), true)
  band.log("backed up: a saved version, kept for good (Restore > Saved versions)")
  local droot = require("drive").root(cfg)
  if droot then
    local ok, file, why = pcall(require("sessionfile").export, proj, cfg, b, droot, sync.room_dir(cfg, b.song, b.room))
    band.log(ok and file and ("project saved to Google Drive: " .. file:match("[^/]+$")) or ("couldn't save the project to Drive: " .. tostring(ok and why or file)))
  end
end

function recall.save(proj, cfg, song, room, label, keep)
  local st = capture(proj)
  st.label, st.by, st.time, st.keep = label, cfg.user, os.date("!%Y-%m-%dT%H:%M:%SZ"), keep or nil
  st.timeline = { tempo = band.capture_tempo(proj), markers = band.capture_markers(proj) } -- positions are in its seconds
  local dir = recall.dir(cfg, song, room)
  reaper.RecursiveCreateDirectory(dir, 0)
  local file = string.format("%s-%s-%s.json", os.date("!%Y%m%d-%H%M%SZ"), (cfg.user:gsub("[^%w%-_]", "_")),
    (label:gsub("[^%w%-_ ]", ""):gsub(" ", "_"):sub(1, 40)))
  band.write_json(dir .. "/" .. file, st)
  return file
end

-- Newest first: { file, label, by, time, takes = count }. The rows are shared between calls: never change them.
-- (0.59.14, review: the panel read and decoded every saved version, each up to 1 MB, every 1.5 s. A version's file never changes once
-- written, and its name carries its time, who and label: each is read once, and only new ones after that.)
local list_rows = {} -- versions folder -> { file name -> its row }
-- The rows for `files` (sorted, oldest first), newest first, reading (`read(name)` -> the decoded file or nil) only names not in `had`.
-- -> rows, and the name -> row map to pass as `had` next time (names gone drop out; one that didn't read is tried again). Pure.
function recall.rows(files, had, read)
  local out, now = {}, {}
  for i = #files, 1, -1 do
    local f = files[i]
    local row = had[f]
    if not row then
      local st = read(f)
      if st then
        local n = 0
        for _ in pairs(st.takes or {}) do n = n + 1 end
        row = { file = f, label = st.label or f, by = st.by, time = st.time, takes = n, keep = st.keep }
      end
    end
    if row then now[f] = row; out[#out + 1] = row end
  end
  return out, now
end
function recall.list(cfg, song, room)
  local dir = recall.dir(cfg, song, room)
  local out, rows = recall.rows(band.files(dir, ".json"), list_rows[dir] or {}, function(f) return band.read_json(dir .. "/" .. f) end)
  list_rows[dir] = rows
  return out
end

-- ---- history: every take and change, in order -----------------------------------------------------
-- Entries are { time, id, user, kind = "take" | event type, ... }: a take's arrival (from its manifest's
-- first placement) or an event as posted. Sorted by time, then id.

recall.ev_cache = {} -- event file path -> its event (files never change once written: read once per session)
-- Reads the room's changes a few at a time, for `secs` per call, so nothing has to read thousands at once when a page opens.
-- -> whether they've all been read, how many have, how many there are.
-- `idle`: nobody is looking at what it reads just now: the first read of everything carries on, but once that's done the folder isn't looked
-- at again every 5 s (0.59.14, review: a listing of 20,000 names and a pass over them, every 5 s on every page). Back on the page, the next
-- call looks again at once (it's been more than 5 s) and reads only what's new.
local warming = {}
function recall.warm(cfg, song, room, secs, idle)
  local rdir = sync.room_dir(cfg, song, room)
  local w, t0 = warming[rdir], reaper.time_precise()
  if not w or (w.i > #w.files and t0 - w.at > 5 and not idle) then
    w = { files = band.listing(rdir .. "/events", ".json", true), i = 1, at = t0, notes = w and w.notes or {}, noted = w and w.noted or {} }
    warming[rdir] = w
  end
  while w.i <= #w.files and reaper.time_precise() - t0 < secs do
    local path = rdir .. "/events/" .. w.files[w.i]
    local ev = recall.ev_cache[path]
    if not ev then
      ev = band.read_json(path)
      if ev and ev.id and ev.time then ev.kind = ev.type; recall.ev_cache[path] = ev end
    end
    if ev and (ev.kind == "note" or ev.kind == "like") and not w.noted[path] then w.noted[path] = true; w.notes[#w.notes + 1] = ev end
    w.i = w.i + 1
  end
  return w.i > #w.files, w.i - 1, #w.files
end
-- The notes and likes read so far, newest first.
function recall.notes(cfg, song, room)
  local w = warming[sync.room_dir(cfg, song, room)]
  if not w then return {} end
  table.sort(w.notes, function(a, x) return (a.time .. a.id) > (x.time .. x.id) end)
  return w.notes
end
function recall.entries(cfg, song, room)
  local out = {}
  local rdir = sync.room_dir(cfg, song, room)
  for _, d in ipairs({ band.takes_dir(cfg, song, room), rdir .. "/_trash" }) do -- deleted takes still have a past
    for _, f in ipairs(band.files(d, ".json")) do
      local m = band.read_json(d .. "/" .. f)
      if m and m.id and m.user then
        local o = m.origin or { pos = m.pos, len = m.len, track = sync.base_name(m.track), lane = m.lane, sent = m.sent }
        out[#out + 1] = { kind = "take", time = o.sent or m.sent or "", id = m.id, take = m.id, user = m.user,
          track = o.track, pos = o.pos, len = o.len, lane = o.lane, midi = m.midi and true or nil }
      end
    end
  end
  for _, f in ipairs(band.files(rdir .. "/events", ".json")) do
    local path = rdir .. "/events/" .. f
    local ev = recall.ev_cache[path]
    if not ev then
      ev = band.read_json(path)
      if ev and ev.id and ev.time then ev.kind = ev.type; recall.ev_cache[path] = ev end
    end
    if ev and ev.id and ev.time then out[#out + 1] = ev end
  end
  table.sort(out, function(a, x) return (a.time .. a.id) < (x.time .. x.id) end)
  return out
end

-- The arrangement after entries[1..upto], in recall-point form ({ takes, plays, tracks }). Pure: no REAPER calls.
function recall.replay(entries, upto)
  local st = { takes = {}, plays = {}, tracks = {} }
  local gone = {} -- deleted takes keep their last shape, for an undelete
  for i = 1, math.min(upto or #entries, #entries) do
    local e = entries[i]
    local id = e.take and e.take:lower()
    if e.kind == "take" then
      st.takes[id] = { id = e.take, track = e.track, pos = e.pos, len = e.len, lane = e.lane, mute = 0, offs = 0 }
    elseif e.kind == "delete" and st.takes[id] then
      gone[id], st.takes[id] = st.takes[id], nil
    elseif e.kind == "undelete" and gone[id] then
      st.takes[id], gone[id] = gone[id], nil
    elseif e.kind == "edit" and st.takes[id] then
      local t = st.takes[id]
      t.track, t.pos, t.len, t.lane = e.track or t.track, e.pos or t.pos, e.len or t.len, e.lane
      t.mute, t.offs = e.mute or t.mute, e.offs or t.offs
    elseif e.kind == "plays" then
      st.plays[e.track] = e.takes or {}
    elseif e.kind == "track" then
      if e.was and st.tracks[e.was] then st.tracks[e.was] = nil end
      st.tracks[e.track] = { mute = e.mute, solo = e.solo, color = e.color, icon = e.icon }
    elseif e.kind == "timeline" or (e.kind == "shift" and e.tempo) then -- an insert/remove carries the map it left
      st.timeline = { tempo = e.tempo, markers = e.markers }
    end
  end
  -- which takes play: the newest "plays" per track picks the active take of each item
  local active = {}
  for _, list in pairs(st.plays) do for _, id in ipairs(list) do active[id:lower()] = true end end
  local out = { takes = {}, plays = st.plays, tracks = st.tracks, timeline = st.timeline, musical = true }
  for lid, t in pairs(st.takes) do
    out.takes[t.id] = { track = t.track, pos = t.pos, len = t.len, lane = t.lane, mute = t.mute, offs = t.offs, active = active[lid] or nil }
  end
  return out
end

-- One line per entry, for the history list.
function recall.describe(e)
  local whose = e.take and ((e.take:match("^(.-)%-%d+%-%d+Z") or e.take) .. "'s take") or ""
  local on = e.track and (" on " .. e.track) or "" -- events from before 0.5 don't name the track
  if e.kind == "obj" then -- mirror sync: an item, a track or a track's plug-ins
    local where = (e.name or "") ~= "" and e.name or "an unnamed track"
    local part = require("mirror").PART[e.obj]
    local what = part and (part .. " on " .. where) or e.obj == "track" and ((e.name or "") ~= "" and ("track " .. where) or where) or ("an item on " .. where)
    if e.gone then return "deleted " .. what end
    if e.restored then return "brought back " .. what end
    return ((e.rev or 1) == 1 and "added " or "changed ") .. what .. ((e.obj == "item" and e.pos) and string.format(" at %.2f s", e.pos) or "")
  end
  if e.kind == "take" then
    return string.format("recorded %s%s at %.2f s%s", e.midi and "a MIDI take" or "a take", on, e.pos or 0, e.lane and (" (lane " .. (e.lane + 1) .. ")") or "")
  elseif e.kind == "edit" then
    -- what it did, when the shape before it came along (0.14.5+): "muted", "trimmed", "moved", not always "moved/trimmed"
    local b = type(e.before) == "table" and e.before or nil
    if b then
      local function differ(x, y) return x ~= nil and y ~= nil and math.abs(x - y) > 1e-4 end
      local moved = differ(b.pos, e.pos)
      local trimmed = differ(b.len, e.len) or differ(b.offs, e.offs)
      local muted = b.mute ~= nil and e.mute ~= nil and ((b.mute or 0) > 0) ~= ((e.mute or 0) > 0)
      local mute_note = muted and (((e.mute or 0) > 0) and ", muted" or ", unmuted") or ""
      if not moved and not trimmed and muted then return ((e.mute or 0) > 0 and "muted " or "unmuted ") .. whose .. on end
      if not moved and trimmed then return "trimmed " .. whose .. on .. mute_note end
      if moved and not trimmed then return string.format("moved %s%s to %.2f s%s", whose, on, e.pos or 0, mute_note) end
    end
    return string.format("moved/trimmed %s%s to %.2f s%s", whose, on, e.pos or 0, (e.mute or 0) > 0 and ", muted" or "")
  elseif e.kind == "delete" then return "deleted " .. whose .. on
  elseif e.kind == "undelete" then return "brought back " .. whose .. on
  elseif e.kind == "midi" then return "edited the notes of " .. whose .. on
  elseif e.kind == "plays" then return string.format("%s: now playing %d take(s)", tostring(e.track), #(e.takes or {}))
  elseif e.kind == "track" then
    if e.changed then -- 0.7.6+: only what changed
      local parts = {}
      for _, f in ipairs(e.changed) do
        parts[#parts + 1] = f == "mute" and ((e.mute or 0) > 0 and "muted" or "unmuted") or f == "solo" and ((e.solo or 0) > 0 and "soloed" or "unsoloed")
          or f == "color" and "colour changed" or f == "icon" and "icon changed" or f == "name" and "renamed"
          or f == "vol" and tonumber(e.vol) and string.format("volume %.1f dB", 20 * math.log(math.max(tonumber(e.vol), 1e-9), 10))
          or f == "pan" and e.pan and (tonumber(e.pan) == 0 and "pan centre" or string.format("pan %d%% %s", math.floor(math.abs(tonumber(e.pan)) * 100 + 0.5), tonumber(e.pan) < 0 and "left" or "right"))
          or f
      end
      return string.format("%s%s: %s", e.was and (e.was .. " renamed to ") or "", tostring(e.track), table.concat(parts, ", "))
    end
    return string.format("%s%s: %s%s", e.was and (e.was .. " renamed to ") or "", tostring(e.track),
      (e.mute or 0) > 0 and "muted" or "unmuted", (e.solo or 0) > 0 and ", soloed" or "")
  elseif e.kind == "driver" then return e.from == e.user and ("handed control to " .. tostring(e.driver)) or ("took control from " .. tostring(e.from))
  elseif e.kind == "start" then return string.format("%s together from %.2f s", e.rec and "recorded" or "played", e.pos or 0)
  elseif e.kind == "stop" then return "stopped together"
  elseif e.kind == "note" then return "note" .. (e.take and (" on " .. whose .. on) or string.format(" at %.2f s", e.pos or 0)) .. ": " .. tostring(e.text)
  elseif e.kind == "like" then return "liked " .. (whose ~= "" and whose or "a part") .. on -- (a part in mirror sync has no take id: 0.58.98)
  elseif e.kind == "shift" then
    return string.format("%s %.2f s at %.2f s (every track)", (e.len or 0) > 0 and "inserted" or "removed", math.abs(e.len or 0), e.at or 0)
  elseif e.kind == "solo" then return "Solo edit version" .. (e.note and (": " .. e.note) or "") .. string.format(" (%d change(s))", #(e.changes or {}))
  elseif e.kind == "timeline" then
    local t, changes = e.tempo or {}, {}
    for i, m in ipairs(t) do
      changes[#changes + 1] = string.format("%g bpm%s at %.2f s", m.bpm, (m.num or 0) > 0 and string.format(" %d/%d", m.num, m.denom) or "", m.time)
    end
    return string.format("changed the tempo or markers: now %s, %d marker(s)/region(s)", table.concat(changes, ", "), #(e.markers or {}))
  end
  return tostring(e.kind)
end

-- Consecutive entries by one person, while one driver drives and without a long pause, form a group:
-- { user, driver, first, last (entry indexes), from, to (times) }.
-- A pause of more than 3 minutes also starts a new group, so a long session doesn't become one restore point.
local function secs(iso)
  local y, mo, d, h, mi, s = (iso or ""):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  return y and os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s }) or 0
end
function recall.groups(entries, host)
  local groups, driver = {}, host
  for i, e in ipairs(entries) do
    if e.kind == "driver" then driver = e.driver or e.user end
    local g = groups[#groups]
    local solo = e.kind == "solo"
    if not g or g.user ~= e.user or g.driver ~= driver or secs(e.time) - secs(g.to) > 180 or (g.solo or false) ~= solo then
      g = { user = e.user, driver = driver, first = i, from = e.time, solo = solo or nil }
      groups[#groups + 1] = g
    end
    g.last, g.to = i, e.time
  end
  return groups
end

return recall
