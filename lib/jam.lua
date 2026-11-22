-- Jam: classic NINJAM play-along, built into "In time (NINJAM style)" (James, 2026-11-20; docs/rt/rt-jam.md). Everyone plays at once and
-- hears the others one interval behind, each interval starting on its bar, with nothing recorded unless someone records.
--  - Sending (the tab in front, while the transport plays): live audio's Play feed (every armed track after its FX, after Mute me) goes into a
--    growing 16-bit stereo WAV on this computer (extension: StudioSync_JamStart, extension/direct_audio.cpp), which the direct link streams to
--    the others as it grows (lib/direct.lua stream_start). Each run from play to stop is one file. A "jam" message every second (and at once
--    when there's a new one) says where each stretch of it sits in the song: segments { file frame, song position }, a new one at every play,
--    seek, loop or dropped block, the position moved back by this computer's input + output latency (where the player heard the song).
--  - Hearing: each bandmate's file plays on a hidden track of this computer's own ("Jam: <name>", never sent), as short items: the audio they
--    played in interval k (bars k*N+1..(k+1)*N, N = the interval in bars, "bars behind" in Parts play) starts on the first bar of interval
--    k+1, by this project's own tempo map, so a tempo change keeps every interval on its bar (an interval longer than its slot is cut at the
--    slot's end). An item is made a little before its slot from what has arrived, and made again as the rest comes (REAPER reads a file's
--    length once). Their level and mute are live audio's cue mix (their Play level, the master, Deafen).
--  - Their live audio Play stream is silent here while they jam (liveaudio.ducks, as a screen share's sound does), so nobody is heard twice.
--  - Jam turns In time on and Play and stop together at 0 bars, so Play together and everyone's own play and stop start and stop everyone at once;
--    In time's lag for a take you follow is off while jamming, and a take someone records while jamming is heard through Jam (its streamed
--    placeholder stays muted): lib/streams.lua.
--  - Who gets it (rt-p12, backlog 1.15): each computer with Jam on says so every HEAR_EVERY s ("jam_hear"); a run streams only to those, and one
--    who says so mid-run joins the stream from its start (the link sends a peer added later from the beginning), so they hear the next
--    interval, not the next play. Over Opus (192 kbit/s, not 1.5 Mbit/s) when this device runs at 48 kHz and everyone it goes to can read it
--    (their extension's StudioSync_JamDecode turns the growing copy into a growing WAV, placed as before); else the 16-bit WAV.
-- Limits: play rates other than 1 aren't followed. GPL-3.0-or-later.
local band = require("band")
local direct = require("direct")
local jam = { TICK = 0.1, EVERY = 1, LEAD = 1.5, NEAR = 1.0, REFRESH = 0.25, DUCK = 3, QUIET = 5, SEGS = 16, HEADER = 44, BLOCK = 4,
  MIN_START = 0.05, RUN_MAX = 3600, TAG = "jam", HEAR_EVERY = 2, HEAR_FOR = 6 }

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
-- The interval a fractional bar (0-based: bar 1 starts at 0) is in, N bars each. (A hair over, so a boundary read back a hair short counts.)
function jam.interval_of(bar, n) return math.floor(bar / n + 1e-9) end
-- Whole sample frames a received copy holds: its bytes past the 44-byte header, 4 bytes a frame (16-bit stereo, as the extension writes).
function jam.frames(bytes) return math.max(0, math.floor(((tonumber(bytes) or 0) - jam.HEADER) / jam.BLOCK)) end
-- Where a bandmate's audio plays here. segs: { { n0 (file frame), p0 (song position) } } in file order; o = { sr, n (interval, bars),
-- bar_of(t) (fractional 0-based bar), time_of(bar), end_frame (the file's length once it's ended; nil while it grows), have (frames here so
-- far; nil: all), w0, w1 (the window: only chunks sounding in it) }. -> { { key, seg, k, dest, offs, len, f_a, f_b, nodata } } by dest:
-- interval k's audio (from file frame f_a to f_b, offs = f_a in seconds) at dest, the same place one interval on (a part interval, after a
-- seek or a start mid-interval, keeps its place in the bar), at most to the slot's end. Where two overlap (a loop back over the same bars)
-- the newer stretch wins, unless none of it is here yet (nodata: not played yet, so the older one is what was played an interval ago). Pure.
function jam.chunks(segs, o)
  local cands, out = { {}, {} }, {}
  local function free(a, b)
    for _, c in ipairs(out) do if a < c.dest + c.len - 1e-3 and b > c.dest + 1e-3 then return false end end
    return true
  end
  local kw = jam.interval_of(o.bar_of(math.max(0, o.w0)), o.n) - 2 -- (no chunk sounding in the window comes from before this interval)
  for si = #segs, 1, -1 do
    local s, nxt = segs[si], segs[si + 1]
    local n_end = nxt and nxt.n0 or o.end_frame
    local p_end = n_end and (s.p0 + (n_end - s.n0) / o.sr) or math.huge
    local k = math.max(jam.interval_of(o.bar_of(math.max(0, s.p0)), o.n), kw)
    for _ = 1, 256 do
      local b_a, b_b = o.time_of(k * o.n), o.time_of((k + 1) * o.n)
      if b_a >= p_end then break end
      local src_a, src_b = math.max(s.p0, b_a), math.min(p_end, b_b)
      if src_b > src_a + 1e-6 then
        local dest = src_a == b_a and b_b or o.time_of(o.bar_of(src_a) + o.n)
        if dest > o.w1 then break end
        local f_a = s.n0 + math.floor((src_a - s.p0) * o.sr + 0.5)
        local f_b = src_b == p_end and n_end or (s.n0 + math.floor((src_b - s.p0) * o.sr + 0.5))
        local len = math.min((f_b - f_a) / o.sr, o.time_of((k + 2) * o.n) - dest)
        if len > 1e-3 and dest + len > o.w0 then
          local nodata = o.have ~= nil and f_a >= o.have
          local list = cands[nodata and 2 or 1]
          list[#list + 1] = { key = (s.i or si) .. ":" .. k, seg = si, k = k, dest = dest, offs = f_a / o.sr, len = len, f_a = f_a, f_b = f_b, nodata = nodata or nil }
        end
      end
      k = k + 1
    end
  end
  for _, list in ipairs(cands) do for _, c in ipairs(list) do if free(c.dest, c.dest + c.len) then out[#out + 1] = c end end end
  table.sort(out, function(a, b) return a.dest < b.dest end)
  return out
end
-- A "jam" message checked, or nil: { run, user, file, rel, srate, bars, segs = { [index] = { n0, p0 } } }. Everything used as a name is
-- worked out here (lib/streams.lua stream_name: <room>~<user>~<file>). Pure.
function jam.valid(d, song, room, me)
  if type(d) ~= "table" or type(d.run) ~= "string" or #d.run > 120 or not d.run:match("^[%w%-_]+$") then return nil end
  if type(d.user) ~= "string" or d.user == me or not direct.plain(d.user) or #d.user > 60 then return nil end
  if type(d.file) ~= "string" or not direct.plain(d.file) or not (d.file:lower():match("%.wav$") or d.file:lower():match("%.opus$")) then return nil end
  local sr, bars = tonumber(d.srate), tonumber(d.bars)
  if not sr or sr < 1000 or sr > 384000 or not bars or bars ~= math.floor(bars) or bars < 1 or bars > 16 then return nil end
  if type(d.segs) ~= "table" or #d.segs > 32 then return nil end
  local segs = {}
  for _, s in ipairs(d.segs) do
    local i, n0, p0 = type(s) == "table" and tonumber(s[1]), type(s) == "table" and tonumber(s[2]), type(s) == "table" and tonumber(s[3])
    if not (i and n0 and p0) or i ~= math.floor(i) or i < 0 or i > 1e9 or n0 ~= math.floor(n0) or n0 < 0 or n0 > 2 ^ 40 or p0 ~= p0 or p0 < -60 or p0 > 1e6 then return nil end
    segs[i] = { n0 = n0, p0 = p0 }
  end
  local rel = direct.stream_rel(song, require("streams").stream_name(room, d.user, d.file))
  if not rel then return nil end
  return { run = d.run, user = d.user, file = d.file, rel = rel, srate = sr, bars = bars, segs = segs, opus = d.file:lower():match("%.opus$") ~= nil }
end
-- Who a run goes to (rt-p12): the peers here whose person said "Jam on" within HEAR_FOR s. users: peer -> person (none known: everyone, the
-- WAV, as before); listeners: person -> { at, opus }. -> the peers, peer -> reads Opus, and whether all of them do. Pure.
function jam.audience(peers, users, listeners, now)
  if type(users) ~= "table" or next(users) == nil then return peers, {}, false end
  local out, opus, all = {}, {}, true
  for _, p in ipairs(peers) do
    local l = users[p] and listeners[users[p]]
    if l and now - l.at < jam.HEAR_FOR then out[#out + 1] = p; opus[p] = l.opus == true; all = all and l.opus == true end
  end
  return out, opus, #out > 0 and all
end
-- An entry's segments in file order, each with its index (i: what a chunk's key goes by), one a later message left out kept. Pure.
function jam.seg_list(e)
  local idx, out = {}, {}
  for i in pairs(e.segs) do idx[#idx + 1] = i end
  table.sort(idx)
  for _, i in ipairs(idx) do out[#out + 1] = { i = i, n0 = e.segs[i].n0, p0 = e.segs[i].p0 } end
  return out
end
-- The segments to send: the newest SEGS, each { index, file frame, position less the latency }. raw: the extension's [[i, n0, p0], ...]. Pure.
function jam.out_segs(raw, latency)
  local out = {}
  for k = math.max(1, #raw - jam.SEGS + 1), #raw do
    local s = raw[k]
    out[#out + 1] = { s[1], s[2], math.floor((s[3] - latency) * 1e6 + 0.5) / 1e6 }
  end
  return out
end
-- Health's words. me: { on, sending, peers (how many get it), why (nothing goes out: why) }; heard: { { user, bars, heard, late, missed,
-- live } }; bars: this computer's interval; side: Play and stop together's bars ("" off). -> text, ok. Pure.
function jam.health_text(me, heard, bars, side)
  local parts, ok = {}, true
  local b = string.format("every %d bar%s", bars, bars == 1 and "" or "s")
  if me.why then parts[#parts + 1] = "you send nothing: " .. me.why; ok = false
  else parts[#parts + 1] = me.sending and string.format("you send your armed tracks to %d", me.peers) or "you send when the song plays" end
  local each = {}
  for _, h in ipairs(heard) do
    local w = h.user .. (h.heard > 0 and string.format(" (%d interval%s", h.heard, h.heard == 1 and "" or "s") or " (waiting for their audio")
    if h.late > 0 then w = w .. string.format(", %d late", h.late) end
    if h.missed > 0 then w = w .. string.format(", %d missed", h.missed) end
    w = w .. ")"
    if h.bars ~= bars then w = w .. string.format(" every %d bar%s, not %d", h.bars, h.bars == 1 and "" or "s", bars); ok = false end
    each[#each + 1] = w
  end
  parts[#parts + 1] = #each > 0 and ("you hear " .. table.concat(each, ", ") .. ", an interval late") or "nobody else is jamming"
  if side ~= "0" then parts[#parts + 1] = "Play and stop together isn't at 0 bars, so a press doesn't start everyone at once: switch Jam off and on"; ok = false end
  return "Jam (" .. b .. "): " .. table.concat(parts, "; "), ok
end

-- ---- settings (this computer's, beside Parts play) ---------------------------------------------------------------------------------------
local function px(proj, k) return select(2, reaper.GetProjExtState(proj, band.SECTION, k)) end
function jam.on() return reaper.GetExtState(band.SECTION, "stream jam") == "1" and require("streams").mode() == "in_time" end
function jam.available() return reaper.StudioSync_JamStart ~= nil and reaper.StudioSync_JamStatus ~= nil and direct.live_available() end
-- On: In time, Jam, and Play and stop together at 0 bars (its bars from before kept, and put back when it goes off).
function jam.set(proj, on)
  if on then
    reaper.SetExtState(band.SECTION, "stream listen", "in_time", true)
    reaper.SetExtState(band.SECTION, "stream jam", "1", true)
    if px(proj, "side before jam") == "" then reaper.SetProjExtState(proj, band.SECTION, "side before jam", px(proj, "side") ~= "" and px(proj, "side") or "none") end
    reaper.SetProjExtState(proj, band.SECTION, "side", "0")
    band.log(string.format("Jam on: everyone plays at once and hears the others %d bar%s late, on the bar; play and stop start and stop everyone",
      require("streams").bars(), require("streams").bars() == 1 and "" or "s"))
  else
    reaper.SetExtState(band.SECTION, "stream jam", "", true)
    local was = px(proj, "side before jam")
    if was ~= "" then
      reaper.SetProjExtState(proj, band.SECTION, "side", was == "none" and "" or was)
      reaper.SetProjExtState(proj, band.SECTION, "side before jam", "")
    end
    band.log("Jam off")
  end
end

-- ---- this computer's tracks for what it hears -------------------------------------------------------------------------------------------
jam.book = {} -- run -> entry (this tab's song and room)
local tracks = {} -- user -> track
local cleaned = false
local function jam_tracks(proj)
  local out = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if band.track_ext(tr, "band_local") == jam.TAG then out[#out + 1] = tr end
  end
  return out
end
local function track_for(proj, user)
  local tr = tracks[user]
  if tr and reaper.ValidatePtr2(proj, tr, "MediaTrack*") then return tr end
  for _, t in ipairs(jam_tracks(proj)) do if band.track_ext(t, "band_jam_user") == user then tracks[user] = t; return t end end
  reaper.PreventUIRefresh(1)
  tr = require("mirror").add_local_track(proj, "Jam: " .. user, jam.TAG)
  band.set_track_ext(tr, "band_jam_user", user)
  reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP", 0)
  reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", 0)
  reaper.TrackList_AdjustWindows(false)
  reaper.PreventUIRefresh(-1)
  tracks[user] = tr
  return tr
end
-- A run forgotten here: an Opus copy's decoder stops and its WAV goes (the stream's own copy is the link's inbox to prune).
local function forget(e)
  if e.opus and reaper.StudioSync_JamDecode then reaper.StudioSync_JamDecode(e.path, e.wav, 2) end
  if e.opus then os.remove(e.wav) end
end
-- Every Jam track goes (Jam off, Live sync ending, or a fresh start: items left from before nobody knows).
function jam.clear(proj)
  local ts = proj and jam_tracks(proj) or {}
  for _, e in pairs(jam.book) do e.items = {} end
  tracks = {}
  if #ts == 0 then return end
  reaper.PreventUIRefresh(1)
  for _, tr in ipairs(ts) do reaper.DeleteTrack(tr) end
  reaper.TrackList_AdjustWindows(false)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
end

local function bar_map(proj)
  return {
    bar_of = function(t)
      local beats, meas, cml = reaper.TimeMap2_timeToBeats(proj, t)
      return (meas or 0) + beats / math.max(1, cml or 4)
    end,
    time_of = function(m)
      local mi = math.floor(m)
      local t0 = reaper.TimeMap2_beatsToTime(proj, 0, mi)
      if m - mi < 1e-9 then return t0 end
      local q0, q1 = reaper.TimeMap2_timeToQN(proj, t0), reaper.TimeMap2_timeToQN(proj, reaper.TimeMap2_beatsToTime(proj, 0, mi + 1))
      return reaper.TimeMap2_QNToTime(proj, q0 + (m - mi) * (q1 - q0))
    end,
  }
end

-- ---- hearing ---------------------------------------------------------------------------------------------------------------------------
function jam.on_msg(cfg, b, d)
  if not jam.on() then return false end -- (not jamming here: their live Play is heard as ever)
  local v = jam.valid(d, b.song, b.room, cfg.user)
  if not v or (v.opus and not reaper.StudioSync_JamDecode) then return false end
  local now = reaper.time_precise()
  local e = jam.book[v.run]
  if not e then
    for _, o in pairs(jam.book) do if o.user == v.user then o.ended = true end end -- (their last run is over: a new one began)
    e = v
    e.path, e.items, e.heard, e.late, e.missed, e.missed_keys, e.frames = direct.stream_path(cfg, v.rel), {}, 0, 0, 0, {}, 0
    e.wav = e.opus and (e.path .. ".wav") or e.path -- (what's placed: an Opus copy's growing WAV beside it, rt-p12)
    jam.book[v.run] = e
  else
    for i, s in pairs(v.segs) do e.segs[i] = s end
    e.bars = v.bars
  end
  e.seen = now
  return true
end
function jam.on_end(d) local e = type(d) == "table" and jam.book[d.run]; if e then e.ended = true end end

local function drop_item(tr, it)
  if tr and it and reaper.ValidatePtr2(0, it, "MediaItem*") then reaper.DeleteTrackMediaItem(tr, it) end
end
local function new_source(path) return reaper.PCM_Source_CreateFromFile(path) end
-- One chunk's item, made or made again from what has arrived. -> the item's record { it, key, dest, len, covered, shown, at, final }.
local function place(tr, e, c, rec, now)
  local src = new_source(e.wav or e.path)
  if not src then return rec end
  local it, tk = rec and rec.it
  if it and reaper.ValidatePtr2(0, it, "MediaItem*") then
    tk = reaper.GetActiveTake(it)
    band.set_take_source(tk, src) -- (a fresh source sees the new length; the old one is destroyed)
  else
    it = reaper.AddMediaItemToTrack(tr)
    tk = reaper.AddTakeToMediaItem(it)
    band.set_take_source(tk, src)
    reaper.SetMediaItemInfo_Value(it, "B_LOOPSRC", 0) -- (a short source must never repeat)
    reaper.SetMediaItemInfo_Value(it, "D_POSITION", c.dest)
    reaper.SetMediaItemInfo_Value(it, "D_LENGTH", c.len)
    band.set_item_ext(it, "band_arriving", "1") -- (mirror.scan skips it: never sent)
    band.set_item_ext(it, "band_jam", e.run .. "/" .. c.key)
    e.heard = e.heard + 1
  end
  reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", c.offs)
  reaper.UpdateItemInProject(it)
  local covered = math.max(0, reaper.GetMediaSourceLength(src) - c.offs)
  return { it = it, key = c.key, dest = c.dest, len = c.len, covered = covered, shown = e.frames, at = now,
    final = covered >= c.len - 1e-3 or e.frames >= c.f_b, late = rec and rec.late }
end
-- Each tick: who's jamming here, their live Play silent, their intervals placed on the bar, the played ones gone.
function jam.receive_tick(proj, cfg, b, now)
  if not cleaned then cleaned = true; jam.clear(proj) end -- (items from before this script nobody knows)
  local la = require("liveaudio")
  la.ducks = la.ducks or {}
  local inn = {}
  for _, i in ipairs(direct.streams(cfg).inn) do inn[i.rel] = i end
  local playing = reaper.GetPlayStateEx(proj) & 1 == 1
  local pos = reaper.GetPlayPosition2Ex(proj)
  local map = playing and bar_map(proj)
  local mix, me, ducked = la.mix(), la.me(), false
  for run, e in pairs(jam.book) do
    local i = inn[e.rel]
    if i and e.opus then -- (rt-p12: the extension decodes the copy as it grows, and says when it's whole)
      if (tonumber(i.bytes) or 0) > 0 then
        local dj = band.json_decode(reaper.StudioSync_JamDecode(e.path, e.wav, (i.done and e.ended) and 1 or 0)) or {}
        local f = math.floor(tonumber(dj.frames) or 0)
        if f ~= e.frames then e.frames, e.grew_at = f, now end
        if dj.state == "done" then e.end_frame = e.frames end
        if dj.state == "failed" and not e.dec_said then e.dec_said = true; band.log("Jam: " .. e.user .. "'s copy can't be read here: " .. tostring(dj.error)) end
      end
    elseif i then
      local f = jam.frames(i.bytes)
      if f ~= e.frames then e.frames, e.grew_at = f, now end
      if i.done and e.ended then e.end_frame = e.frames end
    end
    local live = not e.ended and now - (e.seen or now) < jam.QUIET
    if live then
      if not ((la.ducks[e.user] or -math.huge) > now) then ducked = true end
      la.ducks[e.user] = now + jam.DUCK -- (their live Play is silent here while they jam: heard once, an interval late)
    end
    local tr = (next(e.items) or (playing and e.frames > 0)) and track_for(proj, e.user) or nil
    local want = {}
    if playing and tr and (live or e.end_frame) then
      for _, c in ipairs(jam.chunks(jam.seg_list(e), { sr = e.srate, n = e.bars, bar_of = map.bar_of, time_of = map.time_of, end_frame = e.end_frame,
        have = e.frames, w0 = pos - 0.05, w1 = pos + jam.LEAD })) do
        want[c.key] = true
        local rec = e.items[c.key]
        if not rec then
          if e.frames >= math.min(c.f_b, c.f_a + jam.MIN_START * e.srate) then e.items[c.key] = place(tr, e, c, nil, now)
          elseif pos > c.dest + jam.MIN_START and not e.missed_keys[c.key] then e.missed_keys[c.key], e.missed = true, e.missed + 1 end -- (its start hadn't come)
        else
          if math.abs(rec.len - c.len) > 1e-4 then -- (its stretch ended sooner: a seek or a loop mid-interval. The rest is the next stretch's)
            reaper.SetMediaItemInfo_Value(rec.it, "D_LENGTH", c.len)
            rec.len, rec.final = c.len, rec.final or rec.covered >= c.len - 1e-3
          end
        end
        if rec and not rec.final then
          if pos > rec.dest + rec.covered + 0.02 and not rec.late then rec.late, e.late = true, e.late + 1 end -- (heard a gap: the rest came late)
          if e.frames ~= rec.shown and now - rec.at >= jam.REFRESH and (e.frames >= c.f_b or pos + jam.NEAR >= rec.dest + rec.covered) then
            e.items[c.key] = place(tr, e, c, rec, now)
          end
        end
      end
    end
    for key, rec in pairs(e.items) do
      if not want[key] then drop_item(tr, rec.it); e.items[key] = nil end
    end
    if tr then -- (their level and mute: live audio's cue mix, their Play level times the master; Deafen and their mute silence it)
      local g, m = la.play_gain(mix[e.user], me), select(2, la.hear_plan(mix[e.user], me))
      if math.abs(reaper.GetMediaTrackInfo_Value(tr, "D_VOL") - g) > 1e-4 then reaper.SetMediaTrackInfo_Value(tr, "D_VOL", g) end
      if (reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") == 1) ~= m then reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", m and 1 or 0) end
    end
    if not live and not next(e.items) and (e.ended or now - (e.seen or now) > 60) then forget(e); jam.book[run] = nil end -- (over and played out)
  end
  if ducked then pcall(la.apply) end
end

-- ---- sending ---------------------------------------------------------------------------------------------------------------------------
local run -- { id, path, file, rel, seq, sent (segments sent), msg_at, peers, codec }
local S = { why = nil, peers = 0, hear_at = -math.huge }
jam.S = S
local function jam_status() return band.json_decode(reaper.StudioSync_JamStatus()) or {} end
local function jam_dir(cfg) return direct.inbox(cfg.root) .. "/.jam" end
local function latency(sr)
  local inl, outl = reaper.GetInputOutputLatency()
  return sr > 0 and ((tonumber(inl) or 0) + (tonumber(outl) or 0)) / sr or 0
end
local function say(cfg, b, st)
  local raw = type(st.segs) == "table" and st.segs or {}
  local sr = tonumber(st.srate) or 0
  run.seq = run.seq + 1
  run.sent, run.msg_at = #raw > 0 and raw[#raw][1] + 1 or 0, reaper.time_precise()
  direct.send_live(cfg, "jam", { run = run.id, user = cfg.user, file = run.file, srate = sr, bars = require("streams").bars(),
    segs = jam.out_segs(raw, latency(sr)) }, b.song, b.room, run.id .. "-" .. run.seq, run.peers)
end
local function stop_run(cfg, b)
  if not run then return end
  reaper.StudioSync_JamStop() -- (the rest written, the header's real sizes: then the link's last pass)
  if run.rel then
    direct.stream_end(cfg, run.rel)
    direct.send_live(cfg, "jam_end", { run = run.id }, b.song, b.room, run.id .. "-end", run.peers)
  end
  run = nil
end
-- This computer's earlier runs, once the link has finished sending them (or never streamed them).
local function tidy(cfg, keep)
  local going = {}
  for _, o in ipairs(direct.streams(cfg).out) do if not o.finished then going[tostring(o.rel):match("~([^~]+)$") or ""] = true end end
  local dir = jam_dir(cfg)
  for _, f in ipairs(band.files(dir)) do if f ~= keep and not going[f] then os.remove(dir .. "/" .. f) end end
end
-- Why nothing goes out now (nil: it can). listening: how many of the peers have Jam on (nil: all). Pure but for what it's handed.
function jam.why_not(available, sending_play, peers, listening)
  if not available then return "needs a newer StudioSync extension (Extensions > ReaPack > Synchronize packages)" end
  if not sending_play then return "live audio's Play isn't going (arm a track, and check Mute me and Deafen): Jam sends what Play would" end
  if peers == 0 then return "nobody is here on the direct link" end
  if listening == 0 then return "nobody here has Jam on (it goes only to those who do)" end
end
-- A bandmate's "Jam on" (rt-p12): runs go to them, and to a run already going they're added from its start. -> taken.
jam.listeners = {} -- person -> { at, opus }
function jam.on_hear(cfg, _, d)
  if type(d) ~= "table" or type(d.user) ~= "string" or d.user == cfg.user or #d.user > 60 or not direct.plain(d.user) then return false end
  jam.listeners[d.user] = { at = reaper.time_precise(), opus = d.opus == true }
  return true
end
local function device_rate() return tonumber((select(2, reaper.GetAudioDeviceInfo("SRATE", "")))) end
function jam.send_tick(proj, cfg, b, now)
  local la = require("liveaudio")
  local all, users = {}, nil
  if direct.live_available() then all, _, users = direct.peers(cfg, b.song, b.room) end
  local peers, opus_of, all_opus = jam.audience(all, users, jam.listeners, now)
  S.peers = #peers
  S.why = jam.why_not(jam.available(), la.S.sending and la.S.sending.play, #all, #peers)
  local playing = reaper.GetPlayStateEx(proj) & 1 == 1
  if S.why or not playing then stop_run(cfg, b); return end
  local st = jam_status()
  if run and run.codec == "opus" and st.state == "failed" then S.opus_off = true end -- (Opus refused here, a device not at 48 kHz: the WAV from now on)
  -- (a new run next tick: failed, another device rate, or an hour long: a WAV stays under 4 GB and nobody's inbox fills with one endless file)
  if run and (st.state == "failed" or st.rate_changed == true or st.on ~= true or (tonumber(st.frames) or 0) > (tonumber(st.srate) or 0) * jam.RUN_MAX) then stop_run(cfg, b); return end
  if not run then
    local stamp = os.date("!%Y%m%d-%H%M%SZ") .. string.format("-%03d", math.floor(now * 1000) % 1000)
    local id = (cfg.user:gsub("[^%w%-_]", "_")) .. "-" .. stamp
    local codec = all_opus and reaper.StudioSync_JamDecode and not S.opus_off and device_rate() == 48000 and "opus" or "wav"
    local file = "jam-" .. stamp .. "." .. codec
    reaper.RecursiveCreateDirectory(jam_dir(cfg), 0)
    tidy(cfg, nil)
    local path = jam_dir(cfg) .. "/" .. file
    if reaper.StudioSync_JamStart(path) ~= 1 then S.why = "the extension couldn't start Jam's capture"; return end
    run = { id = id, path = path, file = file, seq = 0, sent = 0, msg_at = -math.huge, peers = peers, codec = codec }
    return
  end
  local had, new = {}, {} -- (someone who turned Jam on mid-run: from the start of the run's copy, if they can read it)
  for _, p in ipairs(run.peers) do had[p] = true end
  for _, p in ipairs(peers) do if not had[p] and (run.codec ~= "opus" or opus_of[p]) then new[#new + 1] = p; run.peers[#run.peers + 1] = p end end
  if #new > 0 and run.rel then
    direct.stream_start(cfg, run.path, b.song, b.room, require("streams").INTERVAL_MS, require("streams").stream_name(b.room, cfg.user, run.file), new)
    run.msg_at = -math.huge -- (where its stretches sit, to them too, at once)
  end
  if not run.rel and (tonumber(st.frames) or 0) > 0 then -- (its header and first audio are on disk: the link can begin)
    run.rel = direct.stream_start(cfg, run.path, b.song, b.room, require("streams").INTERVAL_MS, require("streams").stream_name(b.room, cfg.user, run.file), run.peers)
    if not run.rel then stop_run(cfg, b); S.why = "the direct link didn't take the stream"; return end
  end
  if run.rel then
    local raw = type(st.segs) == "table" and st.segs or {}
    local newest = #raw > 0 and raw[#raw][1] + 1 or 0
    if newest ~= run.sent or now - run.msg_at >= jam.EVERY then say(cfg, b, st) end
  end
end

-- Live sync's call, each tick.
local tick_at = -math.huge
function jam.tick(proj, cfg, b, in_front)
  local now = reaper.time_precise()
  if now - tick_at < jam.TICK then return end
  tick_at = now
  if not jam.on() then
    if run then stop_run(cfg, b) end
    if next(tracks) or not cleaned then cleaned = true; jam.clear(proj) end
    for _, e in pairs(jam.book) do forget(e) end
    jam.book = {}
    return
  end
  if now - S.hear_at >= jam.HEAR_EVERY and direct.live_available() then -- ("Jam on" here: the others' runs come to this computer, rt-p12)
    S.hear_at = now
    local all = direct.peers(cfg, b.song, b.room)
    if #all > 0 then
      direct.send_live(cfg, "jam_hear", { user = cfg.user, opus = reaper.StudioSync_JamDecode ~= nil }, b.song, b.room,
        "jamhear-" .. (cfg.user:gsub("[^%w%-_]", "_")) .. "-" .. math.floor(now * 1000), all)
    end
  end
  if in_front then jam.send_tick(proj, cfg, b, now) elseif run then stop_run(cfg, b) end
  jam.receive_tick(proj, cfg, b, now)
end
function jam.on_exit(proj, cfg, b)
  if run then stop_run(cfg, b) end
  if proj and reaper.ValidatePtr2(0, proj, "ReaProject*") then jam.clear(proj) end
  for _, e in pairs(jam.book) do forget(e) end
end

-- ---- what it shows ---------------------------------------------------------------------------------------------------------------------
-- Who's heard: { { user, bars, heard, late, missed, live } }, by name.
function jam.heard()
  local now, by = reaper.time_precise(), {}
  for _, e in pairs(jam.book) do
    local h = by[e.user]
    if not h then h = { user = e.user, heard = 0, late = 0, missed = 0 }; by[e.user] = h end
    h.bars, h.live = e.bars, h.live or (not e.ended and now - (e.seen or now) < jam.QUIET)
    h.heard, h.late, h.missed = h.heard + e.heard, h.late + e.late, h.missed + e.missed
  end
  local out = {}
  for _, h in pairs(by) do out[#out + 1] = h end
  table.sort(out, function(a, c) return a.user < c.user end)
  return out
end
-- Health's row (lib/page_health.lua), nil while Jam is off.
function jam.health_rows(cfg, b, proj)
  if not jam.on() then return {} end
  local text, ok = jam.health_text({ sending = run ~= nil and run.rel ~= nil, peers = S.peers, why = S.why }, jam.heard(), require("streams").bars(),
    proj and px(proj, "side") or "0")
  return { { "jam", ok, ok and "grey" or "yellow", ok and text or "", text } }
end
-- The web UI's Beat page (lib/songsheet.lua's "beat" topic): the interval and who's heard, nil while Jam is off.
function jam.beat_info()
  if not jam.on() then return nil end
  local who = {}
  for _, h in ipairs(jam.heard()) do if h.live then who[#who + 1] = h.user end end
  return { bars = require("streams").bars(), who = who }
end
-- Settings > Options, under Parts play (StudioSync - Panel.lua): Jam or In time for takes, and who's heard.
function jam.options(ctx, ImGui)
  local proj = reaper.EnumProjects(-1)
  if not proj then return end
  local on = jam.on()
  local ch, v = ImGui.Checkbox(ctx, "Jam: everyone plays at once, nothing recorded##jamon", on)
  if ch then jam.set(proj, v) end
  ImGui.SetItemTooltip(ctx, "Classic NINJAM, built in: what each of you plays on your armed tracks reaches the others one interval (the bars\n" ..
    "behind, above) late, each interval starting on its bar, so you play along to each other. Nothing is recorded unless someone records.\n" ..
    "Turns In time on and Play and stop together at 0 bars, so play and stop start and stop everyone. Their live Play is silent while they jam,\n" ..
    "so you hear each part once. Each person's level is their Play level in Chat > Call. Needs live audio and the direct link.")
  if not on then
    if require("streams").mode() == "in_time" then ImGui.TextDisabled(ctx, "In time follows a take as it's recorded.") end
    return
  end
  local heard = jam.heard()
  local names = {}
  for _, h in ipairs(heard) do if h.live then names[#names + 1] = h.user end end
  ImGui.TextDisabled(ctx, S.why and ("You send nothing: " .. S.why) or (#names > 0 and ("Hearing " .. table.concat(names, ", ") .. ", an interval late") or "Nobody else is jamming yet"))
end

return jam
