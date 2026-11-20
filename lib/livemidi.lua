-- Live MIDI view: while someone records MIDI, the notes they play show up on everyone else's timeline a few seconds
-- later (as fast as the shared folder syncs), growing as they play. You hear their instrument through Listen live;
-- this shows what's being recorded. The placeholder is muted (their sound comes over the audio stream) and goes as
-- soon as their real take arrives (live.retire: any take of theirs sent after they started).
--   rooms/<room>/live_midi/<user>/<since>-<nnnn>.json   { user, since = "YYYYMMDD-HHMMSSZ", time, at, done, notes = { {i, t, s, e, p, v} } }
-- Every second while recording the recorder writes what changed (new notes, notes that ended; i numbers each note)
-- as a NEW file, and receivers fold them together. One file rewritten twice a second never synced while it kept
-- changing (2026-10-28, laptop -> PC: nothing until the recording stopped). Syncthing brings them in batches every
-- few seconds, so the view grows in steps, a few seconds behind the player.
-- Over the direct link (James, rt): each change goes as a link message within ~50 ms of being played (<since>-L<n>, never a file), and while
-- the link reaches everyone here the 1-second files aren't written at all: only the last one at stop, the record. Files are the fallback.
local band = require("band")
local sync = require("sync")
local live = require("live")
local lm = {}

local function dir(cfg, b) return sync.room_dir(cfg, b.song, b.room) .. "/live_midi" end
local function safe(user) return (user:gsub("[^%w%-_ ]", "")) end

-- Which armed tracks take this MIDI event (device and channel as their record input says). Pure but for reaper reads.
-- Several at once (James, rt): only tracks that record MIDI (not record: none, nor output to a file: their sound streams as audio), and
-- each its own part: a second track of the same name is "<name> (<its number>)", or two "Synth" tracks' notes were one part and a note
-- held on both never ended.
local function armed_midi(proj)
  local out, seen = {}, {}
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    local input = reaper.GetMediaTrackInfo_Value(tr, "I_RECINPUT")
    if require("streams").records_midi(reaper.GetMediaTrackInfo_Value(tr, "I_RECARM"), input, reaper.GetMediaTrackInfo_Value(tr, "I_RECMODE")) then
      local name = sync.base_name(select(2, reaper.GetTrackName(tr)))
      if seen[name] then name = name .. " (" .. (t + 1) .. ")" end
      seen[name] = true
      out[#out + 1] = { tr = tr, name = name, dev = (input >> 5) & 63, chan = input & 31 }
    end
  end
  return out
end
function lm.takes(t, dev, status) -- t: one armed track; dev: the event's device index. Pure.
  return (t.dev == 63 or t.dev == (dev & 0xFFFF)) and (t.chan == 0 or t.chan == (status & 15) + 1)
end

-- ---- the recorder's side ----------------------------------------------------------------------------------
local rec -- { since, notes = { {t, s, e, p, v} }, dirty = { [index] = true }, open, tracks, last_seq, wrote_at, n, at }
local function latest_seq() return (reaper.MIDI_GetRecentInputEvent(0)) end

-- Call on every Live sync tick with whether we're recording now.
function lm.send_tick(proj, cfg, b, recording)
  if recording and rec == nil then
    local tracks = armed_midi(proj)
    if #tracks == 0 then rec = false; return end -- recording audio only: nothing to show
    rec = { since = os.date("!%Y%m%d-%H%M%SZ"), notes = {}, dirty = {}, open = {}, tracks = tracks, last_seq = latest_seq(), wrote_at = 0, n = 0,
      ldirty = {}, lsent_at = -math.huge, ln = 0 }
    local udir = dir(cfg, b) .. "/" .. safe(cfg.user) -- an earlier recording's files: not needed any more
    for _, f in ipairs(band.files(udir, ".json")) do os.remove(udir .. "/" .. f) end
    os.remove(dir(cfg, b) .. "/" .. safe(cfg.user) .. ".json") -- (0.15.1-0.15.2 kept one file per person)
  end
  if not rec then
    if not recording then rec = nil end -- (false: this recording had no MIDI track armed)
    return
  end
  -- new input since last look, oldest first
  local new, i = {}, 0
  local newest = latest_seq() -- (idx 0 latches the history)
  while i < 4000 do
    local seq, buf, _, dev, pos = reaper.MIDI_GetRecentInputEvent(i)
    if seq == 0 or seq == rec.last_seq then break end
    new[#new + 1] = { buf = buf, dev = dev, pos = pos }
    i = i + 1
  end
  rec.last_seq = newest
  for k = #new, 1, -1 do
    local e = new[k]
    local st, p, v = e.buf:byte(1) or 0, e.buf:byte(2) or 0, e.buf:byte(3) or 0
    local kind = st & 0xF0
    if e.pos >= 0 and (kind == 0x90 or kind == 0x80) then
      for _, t in ipairs(rec.tracks) do
        if lm.takes(t, e.dev, st) then
          local key = t.name .. "\0" .. (st & 15) .. ":" .. p
          if kind == 0x90 and v > 0 then
            rec.notes[#rec.notes + 1] = { t = t.name, s = e.pos, p = p, v = v }
            rec.dirty[#rec.notes], rec.ldirty[#rec.notes], rec.open[key] = true, true, #rec.notes
          elseif rec.open[key] then
            rec.notes[rec.open[key]].e, rec.dirty[rec.open[key]], rec.ldirty[rec.open[key]] = e.pos, true, true
            rec.open[key] = nil
          end
        end
      end
    end
  end
  if recording then -- (a track disarmed mid-take stops recording there: its held notes end now, nothing more goes to it. Several at once, James, rt)
    for k = #rec.tracks, 1, -1 do
      local t = rec.tracks[k]
      if t.tr and reaper.GetMediaTrackInfo_Value(t.tr, "I_RECARM") ~= 1 then
        table.remove(rec.tracks, k)
        local pre, at = t.name .. "\0", reaper.GetPlayPosition2Ex(proj)
        for key, idx in pairs(rec.open) do
          if key:sub(1, #pre) == pre then rec.notes[idx].e, rec.dirty[idx], rec.ldirty[idx], rec.open[key] = at, true, true, nil end
        end
      end
    end
  end
  if not recording then -- stopped (the last notes read above): notes still held end where we stopped; receivers
    -- keep showing them until our take arrives
    for _, k in pairs(rec.open) do rec.notes[k].e, rec.dirty[k] = rec.notes[k].e or rec.at, true end
    rec.done = true
    lm.write(cfg, b, rec.at)
    rec = nil
    return
  end
  rec.at = reaper.GetPlayPosition2Ex(proj)
  local now = reaper.time_precise()
  -- (over the link: a change within 50 ms, and "at" four times a second so a held note grows. James, rt)
  if (next(rec.ldirty) and now - rec.lsent_at >= 0.05) or now - rec.lsent_at >= 0.25 then lm.send_link(cfg, b) end
  -- every second, changed or not: a held note or a pause still moves "at", so their view keeps growing. Only while the link doesn't reach
  -- everyone here: the files are the fallback (dirty keeps piling up meanwhile, so the next file carries all of it)
  if now - rec.wrote_at >= 1 and not require("direct").reaches_all(cfg, b.song, b.room) then lm.write(cfg, b, rec.at) end
end
local function changed(dirty)
  local notes = {}
  for k in pairs(dirty) do
    local n = rec.notes[k]
    notes[#notes + 1] = { i = k, t = n.t, s = n.s, e = n.e, p = n.p, v = n.v }
  end
  table.sort(notes, function(x, y) return x.i < y.i end)
  return notes
end
-- What changed since the last link message, as one (named like a file, with an L: lm.from_msg folds it in as it does a file's).
function lm.send_link(cfg, b)
  rec.ln = rec.ln + 1
  local name = string.format("%s-L%d.json", rec.since, rec.ln)
  local c = { user = cfg.user, since = rec.since, time = os.date("!%Y-%m-%dT%H:%M:%SZ"), at = rec.at, notes = changed(rec.ldirty) }
  require("direct").send_live(cfg, "midi", { f = name, c = c }, b.song, b.room, safe(cfg.user) .. "/" .. name)
  rec.ldirty, rec.lsent_at = {}, reaper.time_precise()
end

-- One new file with what changed since the last one (new notes, notes that ended). Never removed while recording:
-- a file deleted a second after it was written was often gone before the other machine's Syncthing had fetched it
-- (2026-10-28: most pulls failed, leaving ~syncthing~*.tmp behind). The next recording clears them.
function lm.write(cfg, b, at)
  if not rec then return end
  local udir = dir(cfg, b) .. "/" .. safe(cfg.user)
  reaper.RecursiveCreateDirectory(udir, 0)
  rec.n = rec.n + 1
  local notes = changed(rec.dirty)
  local name = string.format("%s-%04d.json", rec.since, rec.n)
  local c = { user = cfg.user, since = rec.since, time = os.date("!%Y-%m-%dT%H:%M:%SZ"), at = at, done = rec.done or nil, notes = notes }
  band.write_json(udir .. "/" .. name, c)
  -- (and over the direct link, under the file's name, so the others see each note within a tick: lm.from_msg. James, 0.60.0-rt)
  require("direct").send_live(cfg, "midi", { f = name, c = c }, b.song, b.room, safe(cfg.user) .. "/" .. name)
  rec.wrote_at, rec.dirty = reaper.time_precise(), {}
end

-- ---- everyone else's side ---------------------------------------------------------------------------------
local streams = {} -- user -> { since, seen = { [file] = true }, notes = { [i] = note }, at, done, time }
local tidied_at = -math.huge

-- Placeholders go when their real take arrives (live.retire); one whose take never came (deleted, or REAPER closed
-- before sending) goes 15 minutes after its recording began.
local function tidy(proj)
  live.retire(proj)
  for i = reaper.CountMediaItems(proj) - 1, 0, -1 do
    local it = reaper.GetMediaItem(proj, i)
    local y, mo, d, H, M, S = band.item_ext(it, "band_live"):match("^midi:(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)Z")
    if y and band.age(string.format("%s-%s-%sT%s:%s:%sZ", y, mo, d, H, M, S)) > 900 then
      reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(it), it)
    end
  end
end

-- Fold a bandmate's new stream files into what we know of their recording. Returns it when something changed. Pure
-- but for the file reads (`read(name)` gives a file's table).
function lm.merge(st, files, read)
  local changed = false
  for _, f in ipairs(files) do -- sorted: by recording, then in order
    if not st.seen[f] then
      st.seen[f] = true
      local c = read(f)
      if type(c) == "table" and type(c.since) == "string" and c.since >= (st.since or "") then
        if c.since ~= st.since then st.since, st.notes, st.at, st.done = c.since, {}, nil, nil end
        for _, n in ipairs(type(c.notes) == "table" and c.notes or {}) do
          -- (a note that has ended stays ended: a 1-second file can arrive after the link's newer word on it. James, rt)
          local had = type(n) == "table" and tonumber(n.i) and st.notes[n.i]
          if type(n) == "table" and tonumber(n.i) and not (had and had.e and not n.e) then st.notes[n.i] = n end
        end
        st.at = math.max(st.at or 0, tonumber(c.at) or 0)
        st.done, st.time, st.user = st.done or c.done, c.time, c.user
        changed = true
      end
    end
  end
  return changed
end

local function draw_stream(proj, cfg, st)
  st.redraw = nil
  if not (type(st.user) == "string" and st.user ~= cfg.user and band.age(st.time) < 600
      and not (st.done and band.age(st.time) > 30)) then return end -- (a finished one seen only now, after a reload: its take came long ago)
  local parts = {}
  for _, n in pairs(st.notes) do
    if type(n.t) == "string" then parts[n.t] = parts[n.t] or {}; table.insert(parts[n.t], n) end
  end
  lm.draw(proj, { user = st.user, since = st.since, at = st.at, done = st.done, parts = parts })
end
-- Draw every bandmate's stream as a muted MIDI placeholder on their "(live)" track. Call every half second or so.
function lm.receive_tick(proj, cfg, b)
  if reaper.time_precise() - tidied_at > 2 then tidied_at = reaper.time_precise(); tidy(proj) end
  for _, u in ipairs(band.subdirs(dir(cfg, b))) do
    local udir = dir(cfg, b) .. "/" .. u
    streams[u] = streams[u] or { seen = {}, notes = {} }
    local st = streams[u]
    if lm.merge(st, band.files(udir, ".json"), function(f) return band.read_json(udir .. "/" .. f) end) or st.redraw then draw_stream(proj, cfg, st) end
  end
  for _, st in pairs(streams) do if st.redraw then draw_stream(proj, cfg, st) end end -- (a stream only the direct link has brought so far)
end
-- A stream file's worth over the direct link (lib/direct.lua; James, 0.60.0-rt): folded in under the file's own name, so the file itself is
-- skipped when Syncthing brings it (lm.merge's seen); drawn now, or by receive_tick while recording here. -> true when it was new.
function lm.from_msg(proj, cfg, b, d, recording)
  if type(d) ~= "table" or type(d.f) ~= "string" or not d.f:match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%dZ%-L?%d+%.json$") or type(d.c) ~= "table"
    or type(d.c.user) ~= "string" or d.c.user == cfg.user then return false end
  local u = safe(d.c.user)
  streams[u] = streams[u] or { seen = {}, notes = {} }
  local st = streams[u]
  if not lm.merge(st, { d.f }, function() return d.c end) then return false end
  st.redraw = true
  if not recording then draw_stream(proj, cfg, st) end
  return true
end

function lm.draw(proj, s)
  local name = s.user .. live.TRACK_SUFFIX
  local tr = band.find_track(proj, name) or band.new_track(proj, name)
  if not tr then return end
  reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_live_track", "1", true)
  for part, notes in pairs(s.parts) do
    if type(notes) == "table" and #notes > 0 then
      local tag = "midi:" .. s.since .. ":" .. part
      local it
      for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local x = reaper.GetTrackMediaItem(tr, j)
        if band.item_ext(x, "band_live") == tag then it = x end
      end
      local from, to = math.huge, tonumber(s.at) or 0
      for _, n in ipairs(notes) do from = math.min(from, n.s); to = math.max(to, n.e or n.s) end
      if not it then
        it = reaper.CreateNewMIDIItemInProj(tr, from, to + 0.5)
        if not it then return end
        band.set_item_ext(it, "band_live", tag) -- someone else's: never sent as ours (sync.own_takes)
        band.set_item_ext(it, "band_live_since", s.since) -- live.retire: goes when a take of theirs sent since arrives
        reaper.SetMediaItemInfo_Value(it, "B_MUTE", 1) -- you hear them over Listen live; this only shows the notes
      else
        reaper.SetMediaItemInfo_Value(it, "D_LENGTH", math.max(0.5, to + 0.5 - reaper.GetMediaItemInfo_Value(it, "D_POSITION")))
      end
      local tk = reaper.GetActiveTake(it)
      reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", part .. (s.done and " (recorded, take on its way)" or " (recording...)"), true)
      for k = select(2, reaper.MIDI_CountEvts(tk)) - 1, 0, -1 do reaper.MIDI_DeleteNote(tk, k) end
      for _, n in ipairs(notes) do
        local a = reaper.MIDI_GetPPQPosFromProjTime(tk, n.s)
        local z = reaper.MIDI_GetPPQPosFromProjTime(tk, n.e or math.max(n.s + 0.05, to))
        reaper.MIDI_InsertNote(tk, false, false, a, math.max(z, a + 1), 0, n.p, n.v, true)
      end
      reaper.MIDI_Sort(tk)
      reaper.UpdateItemInProject(it)
    end
  end
end

return lm
