-- Interval streaming: NINJAM built in (docs/realtime-roadmap.md step 2; James, rt). While someone records, their computer streams each
-- take's file over the direct link as REAPER writes it (lib/direct.lua stream_start, extension 1.0.8), and everyone else sees it grow on
-- the recorder's own track at its song position, through that track's plug-ins, and hears it:
--   - as it comes: plays as soon as it's there (watching a take, producing);
--   - in time (NINJAM style): following the recorder's transport, your playback runs one interval (N bars) behind theirs, from the same song
--     position on the studio's shared clock, so what they play lands on your grid;
--   - show only: drawn but muted (you hear them live through SonoBus or the call, say).
-- Fast first, lossless after: the placeholder is never the record. The real take still comes the normal way (its item event, its media
-- through the shared folder); once it has landed here with its audio, the placeholder goes and the streamed copy is deleted.
--
-- Messages (the direct link's, each with an id, once): "take" { id, user, track (oid), name, file (the recorder's file name), pos (where the
-- take starts in the song), at (the shared clock when the playhead was at pos), srate, nch, fmt } and "take_end" { id }. The stream's name
-- on the link is the receiver's own work from those (streams.stream_name): <song>/<room>~<user>~<file>.
--
-- Finding the files REAPER is writing (no API names them before stop): in the first seconds of a recording (after any count-in) the record
-- path (GetProjectPathEx) is listed, and an audio file made or written since the recording began (its time through the extension, 3 s
-- tolerance) is the take's; they're matched to the armed tracks by the track's name in the file name, then its number, then (same count
-- left) in order. Arming and pressing Record at once works: no listing beforehand. Limits: another audio file written into the record
-- folder in those seconds can be taken for a take's (matched only when it fits a track); a second record path, files renamed at stop
-- (REAPER's "rename recorded files" box) and recording formats REAPER writes elsewhere aren't followed; a bandmate who joins mid-take gets
-- no stream for it (the real take still comes). Those takes simply arrive the normal way.
local band = require("band")
local direct = require("direct")
local streams = { INTERVAL_MS = 100, FIND_SECS = 3, FILE_TOL = 3, END_DELAY = 0.5, MIN_BYTES = 4096, CHECK_EVERY = 1,
  DONE_KEEP = 900, STALL = 300, PRUNE_EVERY = 30, TICK = 0.1 }

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
local AUDIO = { wav = true, w64 = true, flac = true, aif = true, aiff = true, ogg = true, opus = true, mp3 = true }
function streams.audio_ext(name) local e = tostring(name or ""):match("%.(%w+)$"); return e ~= nil and AUDIO[e:lower()] == true end
-- Does an armed track record an audio file? (I_RECINPUT: >= 0 and not MIDI (4096); I_RECMODE: input, or output to a file: 0, 1, 3, 5, 6)
local FILE_MODES = { [0] = true, [1] = true, [3] = true, [5] = true, [6] = true }
function streams.records_audio(arm, input, mode)
  return arm == 1 and input >= 0 and input & 4096 == 0 and FILE_MODES[math.floor(mode)] == true
end
-- Is a file in the record folder one REAPER began for this recording? Its newest time (made or written, StudioSync_DirectFileTime: through
-- a handle, so current while REAPER writes it) at or after the recording began (`wall`, os.time's whole seconds), less FILE_TOL. Without
-- that function (an older extension): only files that appear after the first look (`first`: this is it).
function streams.made_since(t, wall, first)
  if tonumber(t) and t >= 0 then return t >= wall - streams.FILE_TOL end
  return not first
end
local function alnum(s) return (tostring(s or ""):lower():gsub("[^%w]", "")) end
-- tracks: { { name, num, ... } } (armed audio tracks, in track order); files: new file names. -> { { track, file } }, by the track's name in
-- the file's (longest names first, so "Gtr" doesn't take "Gtr 2"'s), then its number at the start ("02-..."), then in order when as many
-- files as tracks are left. Anything else isn't matched (not streamed: it comes the normal way).
function streams.match(tracks, files)
  local pairs_, used, done = {}, {}, {}
  local by_len = {}
  for i, t in ipairs(tracks) do by_len[#by_len + 1] = i end
  table.sort(by_len, function(a, b) return #alnum(tracks[a].name) > #alnum(tracks[b].name) end)
  local function take(ti, fi) pairs_[#pairs_ + 1] = { track = tracks[ti], file = files[fi] }; used[fi], done[ti] = true, true end
  for _, ti in ipairs(by_len) do
    local n = alnum(tracks[ti].name)
    if #n >= 2 then
      for fi, f in ipairs(files) do
        if not used[fi] and alnum(f):find(n, 1, true) then take(ti, fi); break end
      end
    end
  end
  for ti, t in ipairs(tracks) do
    if not done[ti] and t.num then
      for fi, f in ipairs(files) do
        local lead = f:match("^0*(%d+)%D")
        if not used[fi] and lead and tonumber(lead) == t.num then take(ti, fi); break end
      end
    end
  end
  local lt, lf = {}, {}
  for ti in ipairs(tracks) do if not done[ti] then lt[#lt + 1] = ti end end
  for fi in ipairs(files) do if not used[fi] then lf[#lf + 1] = fi end end
  if #lt == #lf then for k = 1, #lt do take(lt[k], lf[k]) end end
  return pairs_
end
-- Where the take starts: the edit cursor when recording began from it: the playhead a little past it, or still before it in a count-in or
-- pre-roll (the first real run read the playhead there: a bar early, 1.84 s for 3.69 s at 130 BPM). Else where the playhead is.
-- shortcut: an auto-punch range's start isn't read, the placeholder then sits at the cursor.
function streams.start_pos(cursor, play)
  if play - cursor < 5 then return cursor end
  return play
end
-- The stream's file name on the link: <room>~<user>~<file>, plain characters, at most 200 bytes (the file's start trimmed). nil if it can't be.
local function safe(s) return (tostring(s or ""):gsub("[^%w%-_. ]", "_")) end
function streams.stream_name(room, user, file)
  if not streams.audio_ext(file) then return nil end
  local prefix = safe(room) .. "~" .. safe(user) .. "~"
  if #prefix > 150 then return nil end
  local f = safe(file)
  if #prefix + #f > 200 then f = f:sub(-(200 - #prefix)) end
  return prefix .. f
end
-- A "take" message checked and made an entry for this song and room, or nil. Everything the receiver uses as a name it works out itself.
function streams.valid_take(d, song, room, me, now)
  if type(d) ~= "table" or type(d.id) ~= "string" or #d.id > 120 or not d.id:match("^[%w%-_]+$") then return nil end
  if type(d.user) ~= "string" or d.user == me or not direct.plain(d.user) then return nil end
  if type(d.track) ~= "string" or #d.track > 200 or d.track:sub(1, 2) ~= "T-" or d.track:find("%c") then return nil end
  if type(d.file) ~= "string" or not direct.plain(d.file) then return nil end
  local pos, at = tonumber(d.pos), tonumber(d.at)
  if not pos or pos ~= pos or pos < 0 or pos > 1e6 then return nil end
  local rel = direct.stream_rel(song, streams.stream_name(room, d.user, d.file))
  if not rel then return nil end
  return { id = d.id, user = d.user, track = d.track, name = type(d.name) == "string" and d.name:sub(1, 100) or "", file = d.file, rel = rel,
    pos = pos, at = at, made = now, progress_at = now, bytes = 0 }
end
-- An entry brought up to date from the extension's record of its stream ({ bytes, total, done, ok }). Pure.
function streams.update(e, inn, now)
  if type(inn) ~= "table" then return end
  local b = tonumber(inn.bytes) or 0
  if b ~= e.bytes then e.bytes, e.progress_at = b, now end
  e.total = tonumber(inn.total)
  if inn.done == true and not e.done then e.done, e.done_at = true, now end
  e.ok = inn.ok == true
end
-- The placeholder's length: the source's, once REAPER reads one; else (a growing FLAC whose header says "length unknown") the time since
-- the take began on the shared clock, less a little for the link. Never shorter than it was.
function streams.length(e, src_len, shared_now)
  local len = tonumber(src_len) or 0
  if e.done and len > 0 then return len end -- (the finished file says exactly)
  if len <= 0 and not e.done and e.at and shared_now then len = shared_now - e.at - 0.3 end
  return math.max(len, e.len or 0, 0.1)
end
-- How often a growing placeholder's source is made again: 4 times a second, less often as it gets long (REAPER reads the file and builds
-- its peaks again each time; a 10-minute take every 5 s).
function streams.refresh_every(len) return math.max(0.25, (len or 0) / 120) end
function streams.refresh_due(e, now)
  if e.final then return false end
  if e.done then return true end -- (once, at once: the whole file, the real header)
  return e.bytes ~= e.shown and now - (e.refreshed_at or -math.huge) >= streams.refresh_every(e.len)
end
-- The real take is here (`real`: { size } of its media, nil while it hasn't landed with its audio). -> "wait", "repoint" (the streamed copy
-- is the same file: the placeholder just goes, the real item plays the shared copy), or "swap" (the streamed copy wasn't complete or
-- didn't check out: the real take replaces it all the same; said in the log).
function streams.swap_decision(e, real)
  if not real then return "wait" end
  if e.done and e.ok and tonumber(real.size) and tonumber(e.total) == tonumber(real.size) then return "repoint" end
  return "swap"
end
-- Given up on: done long ago and no take came (deleted, or REAPER closed before sending), or no bytes for a long time. A stand-in for the
-- real take on its track (its event here, its audio still coming: e.held_at) keeps it.
function streams.expired(e, now)
  return (e.done_at ~= nil and now - math.max(e.done_at, e.held_at or -math.huge) > streams.DONE_KEEP) or (not e.done and now - (e.progress_at or now) > streams.STALL)
end
-- Files in <inbox>/.streams/<song> that can go: this room's, not an entry's, not still arriving. names: the folder's; book: id -> entry;
-- active: set of rel names still coming in.
function streams.prunable(names, book, active, room)
  local mine, out = {}, {}
  for _, e in pairs(book) do mine[e.rel:match("[^/]+$")] = true end
  local p = safe(room) .. "~"
  for _, f in ipairs(names) do
    local audio = f:gsub("%.reapeaks$", "") -- (a placeholder's peaks go with its file, not before)
    if f:sub(1, #p) == p and not mine[audio] and not active[audio] and not f:match("%.part$") then out[#out + 1] = f end
  end
  return out
end
-- In time (NINJAM style): the lag a cue from someone you follow gets here. A recording start of theirs: one interval behind (more if the
-- cue says more); their next stop: the same lag, so you hear the take to its end. Anything else: as the cue says. -> lag (nil: leave it), and
-- the new state ({ lead, lag } while in time with someone's take).
function streams.in_time_lag(ev, me, mode, interval, state)
  if mode ~= "in_time" or type(ev) ~= "table" or not ev.follow or type(ev.lead) ~= "string" or ev.lead == me or ev.remote then return nil, state end
  if ev.type == "start" and ev.rec then
    local lag = math.max(tonumber(ev.lag) or 0, interval or 0)
    return lag, { lead = ev.lead, lag = lag }
  end
  if ev.type == "stop" and state and state.lead == ev.lead then return math.max(tonumber(ev.lag) or 0, state.lag), nil end
  if ev.type == "start" then return nil, nil end -- (a plain play: not in time with a take)
  return nil, state
end
-- Health: what's streaming, from direct.streams (out, inn), each stream with its bytes so one that's stuck shows: on the recorder, how much
-- REAPER has written and how much each bandmate has; on theirs, how much has come. -> text, or nil when nothing is or was.
local function mb(n) return string.format("%.2f MB", (tonumber(n) or 0) / 1048576) end
local function take_name(rel)
  local n = tostring(rel or ""):match("[^/]+$") or ""
  if n:sub(1, 7) == "~media~" then return "media " .. (n:match("([^~]+)$") or n) end -- (a media file: lib/streams.lua media_name)
  return (n:gsub("^[^~]*~", ""):gsub("~", "'s ", 1))
end
function streams.health_text(s)
  local parts, bad = {}, 0
  for _, o in ipairs(s.out or {}) do
    local each = {}
    for peer, p in pairs(type(o.peers) == "table" and o.peers or {}) do
      local err = p.error or ""
      if not o.finished then each[#each + 1] = (tostring(peer):match("^([^%.:]+)") or peer) .. " has " .. mb(p.sent) .. (err ~= "" and (" (" .. err .. ")") or "")
      elseif err ~= "" then bad = bad + 1 end
    end
    table.sort(each)
    if not o.finished then
      parts[#parts + 1] = string.format("out %s: %s written%s%s", take_name(o.rel), mb(o.size), #each > 0 and (", " .. table.concat(each, ", ")) or "",
        (o.error or "") ~= "" and ("; " .. o.error) or "")
    end
  end
  for _, i in ipairs(s.inn or {}) do
    if not i.done then parts[#parts + 1] = string.format("in %s: %s so far", take_name(i.rel), mb(i.bytes))
    elseif i.ok ~= true then bad = bad + 1 end
  end
  if #parts + bad == 0 then return nil end
  return "Takes streaming: " .. (#parts > 0 and table.concat(parts, "; ") or "none now") ..
    (bad > 0 and string.format("; %d didn't get through whole (their real takes still come through the shared folder)", bad) or "")
end

-- ---- settings (this computer's: Settings > Options, "Parts play", beside the MIDI view)--------------------------------------------------------------
local MODES = { { "as_it_comes", "As it comes", "Bandmates' takes play as soon as they reach you: for watching a take, or producing." },
  { "in_time", "In time (NINJAM style)", "While you follow a bandmate's transport and they record, your playback runs one interval behind theirs, so\n" ..
    "what they play lands on your grid in time. Play along: your part streams back the same way." },
  { "show", "Show only (muted)", "Their takes show as they grow but stay muted: when you hear them live already (SonoBus, the call)." } }
function streams.mode()
  local m = reaper.GetExtState(band.SECTION, "stream listen")
  return (m == "in_time" or m == "show") and m or "as_it_comes"
end
function streams.bars() return math.max(1, math.min(16, math.floor(tonumber(reaper.GetExtState(band.SECTION, "stream bars")) or 1))) end
function streams.options(ctx, ImGui)
  ImGui.Text(ctx, "Bandmates' takes while they record:")
  for _, m in ipairs(MODES) do
    if ImGui.RadioButton(ctx, m[2] .. "##streamlisten", streams.mode() == m[1]) then reaper.SetExtState(band.SECTION, "stream listen", m[1], true) end
    ImGui.SetItemTooltip(ctx, m[3] .. "\nNeeds the direct link (Health). Only on this computer.")
  end
  if streams.mode() == "in_time" then
    ImGui.SetNextItemWidth(ctx, 118)
    local ch, v = ImGui.InputInt(ctx, "bars behind (the interval)##streambars", streams.bars())
    if ch then reaper.SetExtState(band.SECTION, "stream bars", tostring(math.max(1, math.min(16, v))), true) end
    ImGui.SetItemTooltip(ctx, "How far behind the one recording your playback runs. One bar is plenty over Tailscale (a take arrives in about 0.2 s).")
  end
end

-- ---- the recorder's side ---------------------------------------------------------------------------------------------------------------
-- A line in the stream trace (lib/direct.lua trace_path: ExtState "stream trace" = "1"), beside the extension's own.
function streams.trace(text)
  local p = direct.trace_path()
  if p == "" then return end
  local f = io.open(p, "a")
  if f then f:write(string.format("%.3f lua %s\n", os.time() + reaper.time_precise() % 1, text)); f:close() end
end
local rec -- this recording: { t0, wall, dir, tracks, pos, at, found = set, old = set, takes = { { id, rel } }, none, stopped_at, find_until }
local function record_dir(proj) return (reaper.GetProjectPathEx(proj, "")) end
local function armed_audio(proj)
  local mirror, out = require("mirror"), {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if streams.records_audio(reaper.GetMediaTrackInfo_Value(tr, "I_RECARM"), reaper.GetMediaTrackInfo_Value(tr, "I_RECINPUT"),
        reaper.GetMediaTrackInfo_Value(tr, "I_RECMODE")) and not mirror.local_track(tr) and mirror.track_oid(tr) ~= "" then
      local input = reaper.GetMediaTrackInfo_Value(tr, "I_RECINPUT")
      out[#out + 1] = { tr = tr, oid = mirror.track_oid(tr), name = select(2, reaper.GetTrackName(tr)), num = i + 1,
        nch = input & 1024 ~= 0 and 2 or (input & 2048 ~= 0 and 0 or 1) }
    end
  end
  return out
end
local function srate(proj)
  if reaper.GetSetProjectInfo(proj, "PROJECT_SRATE_USE", 0, false) == 1 then return reaper.GetSetProjectInfo(proj, "PROJECT_SRATE", 0, false) end
  return tonumber(select(2, reaper.GetAudioDeviceInfo("SRATE", ""))) or 0
end
-- Each tick of the tab in front (REAPER records only there), with whether it records now.
function streams.send_tick(proj, cfg, b, recording)
  if not direct.live_available() then return end
  local now = reaper.time_precise()
  if not recording then
    if rec and rec.takes and #rec.takes > 0 then
      rec.stopped_at = rec.stopped_at or now
      if now - rec.stopped_at < streams.END_DELAY then return end -- (REAPER writes the real header as it stops: the stream's last pass reads it)
      for _, t in ipairs(rec.takes) do
        streams.trace("stream_end " .. t.rel .. " -> " .. tostring(direct.stream_end(cfg, t.rel)))
        direct.send_live(cfg, "take_end", { id = t.id }, b.song, b.room, t.id)
      end
      band.log(string.format("your take%s went out to the others as you recorded", #rec.takes > 1 and "s" or ""))
    end
    rec = nil
    return
  end
  if not rec then
    rec = { t0 = now, wall = os.time(), dir = record_dir(proj), found = {}, old = {}, takes = {}, looked = -math.huge, first = true }
    rec.tracks = armed_audio(proj)
    if #rec.tracks == 0 or #direct.peers(cfg, b.song, b.room) == 0 then
      streams.trace(string.format("record start: %d armed audio tracks, %d peers: not streamed", #rec.tracks, #direct.peers(cfg, b.song, b.room)))
      rec.none = true
      return
    end
    local play = reaper.GetPlayPositionEx(proj)
    rec.pos = streams.start_pos(reaper.GetCursorPositionEx(proj), play)
    local sn = direct.shared_now()
    rec.at = sn and sn - (play - rec.pos) or nil -- (in a count-in, a moment still to come)
  end
  if rec.none then return end
  -- (looked for until FIND_SECS after the playhead reaches the take's start: a count-in or pre-roll comes first, and REAPER may make the file
  -- only as it ends)
  if not rec.find_until and reaper.GetPlayPositionEx(proj) >= rec.pos - 0.01 then rec.find_until = now + streams.FIND_SECS end
  if (rec.find_until and now > rec.find_until) or now - rec.t0 > 30 or now - rec.looked < streams.TICK then return end
  rec.looked = now
  local fresh, time_of = {}, reaper.StudioSync_DirectFileTime
  for _, f in ipairs(band.files(rec.dir)) do
    if streams.audio_ext(f) and not rec.found[f] and not rec.old[f] then
      local t = time_of and time_of(rec.dir .. "/" .. f)
      if streams.made_since(t, rec.wall, rec.first) then fresh[#fresh + 1] = f else rec.old[f] = true end
      if streams.made_since(t, rec.wall, rec.first) then streams.trace(string.format("look: %s/%s time %s (record began %d)", rec.dir, f, tostring(t), rec.wall)) end
    end
  end
  if rec.first then streams.trace(string.format("first look in %s: %d new of the audio files there", rec.dir, #fresh)) end
  rec.first = false
  if #fresh == 0 then return end
  local left = {}
  for _, t in ipairs(rec.tracks) do if not t.taken then left[#left + 1] = t end end
  for _, m in ipairs(streams.match(left, fresh)) do
    m.track.taken, rec.found[m.file] = true, true
    local id = string.format("%s-%s-%03d%d", (cfg.user:gsub("[^%w%-_]", "_")), os.date("!%Y%m%d-%H%M%SZ"), math.floor(rec.t0 * 1000) % 1000, #rec.takes + 1)
    local path = rec.dir .. "/" .. m.file
    local rel = direct.stream_start(cfg, path, b.song, b.room, streams.INTERVAL_MS, streams.stream_name(b.room, cfg.user, m.file))
    streams.trace("stream_start " .. path .. " for " .. m.track.name .. " -> " .. tostring(rel))
    if rel then
      rec.takes[#rec.takes + 1] = { id = id, rel = rel }
      direct.send_live(cfg, "take", { id = id, user = cfg.user, track = m.track.oid, name = m.track.name, file = m.file, pos = rec.pos, at = rec.at,
        srate = srate(proj), nch = m.track.nch, fmt = m.file:match("%.(%w+)$"):lower() }, b.song, b.room, id)
    end
  end
end

-- ---- everyone else's side --------------------------------------------------------------------------------------------------------------
streams.book = {} -- id -> entry (this tab's song and room)
local tick_at, pruned_at = -math.huge, -math.huge
function streams.on_take(cfg, b, d)
  local e = streams.valid_take(d, b.song, b.room, cfg.user, reaper.time_precise())
  if not e or streams.book[e.id] then return false end
  e.path = direct.stream_path(cfg, e.rel)
  streams.book[e.id] = e
  return true
end
function streams.on_take_end(d) local e = type(d) == "table" and streams.book[d.id]; if e then e.ended = true end end

local function find_item(proj, tr, guid)
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, i)
    if select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false)) == guid then return it end
  end
end
-- The real take on the track: an item of the band's (not ours, not a stand-in) over the placeholder's stretch, with a take playing the shared
-- copy of the recorder's file (lib/mirror.lua share_media names it <hash>-<file>). -> { size }, or nil; and true when mirror's grey stand-in
-- for an item is there instead (its audio still coming through the shared folder).
local function real_take(proj, tr, e, mine)
  local tail = "-" .. e.file:gsub("[^%w%-_.]", "_")
  local e_end, pending = e.pos + (e.len or 0), false
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, i)
    local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    if it ~= mine and band.item_ext(it, "band_stream") == "" and p < e_end + 1 and p + reaper.GetMediaItemInfo_Value(it, "D_LENGTH") > e.pos - 1 then
      for k = 0, reaper.CountTakes(it) - 1 do
        local tk = reaper.GetTake(it, k)
        local src = tk and reaper.GetMediaItemTake_Source(tk)
        if src and reaper.GetMediaSourceType(src, "") == "SECTION" then src = reaper.GetMediaSourceParent(src) end
        local f = src and reaper.GetMediaSourceFileName(src, "") or ""
        if f ~= "" and f:gsub("\\", "/"):match("[^/]+$"):sub(-#tail) == tail and reaper.file_exists(f) then return { size = band.size(f) } end
      end
      if band.item_ext(it, "band_arriving") ~= "" then pending = true end
    end
  end
  return nil, pending
end
local function remove(proj, e, why)
  local tr = e.guid and require("mirror").find(proj, "track", e.track)
  local it = tr and find_item(proj, tr, e.guid)
  if it then reaper.DeleteTrackMediaItem(tr, it); reaper.UpdateArrange() end
  os.remove(e.path)
  os.remove(e.path .. ".reapeaks")
  streams.book[e.id] = nil
  if why then band.log(why) end
end
local function label(e) return e.file .. (e.done and " (streamed, the take follows)" or e.ended and " (recorded, still arriving)" or " (" .. e.user .. " is recording...)") end

-- Each Live sync tick: placeholders made, grown, and replaced by the real takes; the inbox's streams tidied. `recording`: this computer records
-- (its armed tracks are left alone then: never a track while it records).
function streams.receive_tick(proj, cfg, b, recording)
  local now = reaper.time_precise()
  if now - tick_at < streams.TICK then return end
  tick_at = now
  if not next(streams.book) and now - pruned_at < streams.PRUNE_EVERY then return end
  local s = direct.streams(cfg)
  local inn, active = {}, {}
  for _, i in ipairs(s.inn) do
    inn[i.rel] = i
    if not i.done then active[tostring(i.rel):match("[^/]+$") or ""] = true end
  end
  local mirror, mode = require("mirror"), streams.mode()
  for _, e in pairs(streams.book) do
    streams.update(e, inn[e.rel], now)
    local tr = mirror.find(proj, "track", e.track)
    local busy = recording and tr and reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1
    local it = tr and e.guid and find_item(proj, tr, e.guid)
    if e.guid and not it and tr then -- (deleted here: left alone from now on, the file goes once it's complete)
      if e.done or streams.expired(e, now) then remove(proj, e) else e.dismissed = true end
    elseif streams.expired(e, now) then
      remove(proj, e, string.format("%s's streamed take on %s went: its real take didn't come (deleted, or not sent)", e.user, e.name))
    elseif tr and not busy and not e.dismissed then
      if not it and e.bytes >= streams.MIN_BYTES and reaper.file_exists(e.path) then
        local src_len = 0
        it = band.add_item(tr, e.path, e.pos, 0.1)
        if it then
          local tk = reaper.GetActiveTake(it)
          src_len = reaper.GetMediaSourceLength(reaper.GetMediaItemTake_Source(tk))
          e.guid = select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false))
          band.set_item_ext(it, "band_arriving", "1") -- (mirror.scan skips it: never sent, like a stand-in)
          band.set_item_ext(it, "band_stream", e.id)
          e.len, e.shown, e.refreshed_at = streams.length(e, src_len, direct.shared_now()), e.bytes, now
          reaper.SetMediaItemInfo_Value(it, "D_LENGTH", e.len)
        end
      elseif it and streams.refresh_due(e, now) then
        local src = reaper.PCM_Source_CreateFromFile(e.path)
        if src then
          local tk = reaper.GetActiveTake(it)
          band.set_take_source(tk, src) -- (a fresh source sees the new length; the old one is destroyed)
          e.len = streams.length(e, reaper.GetMediaSourceLength(src), direct.shared_now())
          reaper.SetMediaItemInfo_Value(it, "D_LENGTH", e.len)
          if e.done then
            e.final = true
            if reaper.PCM_Source_BuildPeaks(src, 0) ~= 0 then e.peaks = src end -- (0: its peaks are there already)
          end
        end
        e.shown, e.refreshed_at = e.bytes, now
      end
      if it then
        local mute = mode == "show" and 1 or 0
        if reaper.GetMediaItemInfo_Value(it, "B_MUTE") ~= mute then reaper.SetMediaItemInfo_Value(it, "B_MUTE", mute) end
        local tk = reaper.GetActiveTake(it)
        if tk and select(2, reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", "", false)) ~= label(e) then reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", label(e), true) end
        if e.peaks then -- (the finished take's waveform, a step each tick: PCM_Source_BuildPeaks 1 until it says 0, then 2)
          if reaper.PCM_Source_BuildPeaks(e.peaks, 1) == 0 then reaper.PCM_Source_BuildPeaks(e.peaks, 2); e.peaks = nil end
        end
        reaper.UpdateItemInProject(it)
      end
    end
    -- (with or without a placeholder: a take too short to have made one still has its streamed copy to go. Laptop, rt: 2-3 KB copies stayed)
    if tr and not busy and streams.book[e.id] and now - (e.checked_at or -math.huge) >= streams.CHECK_EVERY then
      e.checked_at = now
      local real, pending = real_take(proj, tr, e, it)
      if pending then e.held_at = now end
      local how = streams.swap_decision(e, real)
      if how ~= "wait" then
        if e.peaks then reaper.PCM_Source_BuildPeaks(e.peaks, 2); e.peaks = nil end
        remove(proj, e, how == "swap" and string.format("%s's take on %s: the streamed copy didn't come through whole, the real take replaced it", e.user, e.name) or nil)
      end
    end
  end
  if now - pruned_at >= streams.PRUNE_EVERY then
    pruned_at = now
    local folder = direct.inbox(cfg.root) .. "/.streams/" .. b.song
    for _, f in ipairs(streams.prunable(band.files(folder), streams.book, active, b.room)) do os.remove(folder .. "/" .. f) end
  end
end

-- ---- media over the link (roadmap step 3, the online half) -----------------------------------------------------------------------------
-- A media file this computer puts in a song's shared folder (an item's audio copied in by mirror.share_media, a print, a plug-in's file) goes
-- to the others here over the link as soon as the change that needs it goes out, so they don't wait seconds for Syncthing. It's a stream
-- begun and ended at once (resumable, hash-checked by the extension: the receiver's `ok` is its bytes' SHA-256 against the sender's), named
-- on the link ~media~<room>~<file> (a "plugin files/" copy: ~media~<room>~plugin files~<name>; never a take stream's <room>~ prefix), with a
-- "media" message { id, user, room, file, size } saying where it belongs. The receiver puts it where Syncthing would, only when nothing's there
-- yet, in one rename (a name Syncthing ignores first when it has to be copied from another disk), then the inbox copy goes. Without the link
-- (old extension, the setting off, nobody reachable) nothing here runs and Syncthing carries it as ever. (James, rt)
streams.MEDIA_FRESH, streams.MEDIA_GRACE, streams.MEDIA_INTERVAL_MS = 600, 60, 20
-- The {media...} files a version of an item names (FILE lines), keyed so two versions compare: room\0file ("" room: {media}, this room's).
local function media_refs(state)
  local out = {}
  if type(state) ~= "string" then return out end
  for room, rel in state:gmatch('FILE "{media:([^}]+)}/([^"]+)"') do out[room .. "\0" .. rel] = { room = room, file = rel } end
  for rel in state:gmatch('FILE "{media}/([^"]+)"') do out["\0" .. rel] = { file = rel } end
  return out
end
-- What a change names that the band's last version of it didn't: media files and plug-in file copies (ev.files: { path, copy }, copies in this
-- room's media). Only those can be new to the others: a file the item already played they have, or Syncthing is bringing. -> { { room, file } },
-- room nil for this room's. Pure.
function streams.media_new(state, last_state, files, last_files)
  local now, before = media_refs(state), media_refs(last_state)
  for _, f in ipairs(type(files) == "table" and files or {}) do if type(f) == "table" and type(f.copy) == "string" then now["\0" .. f.copy] = { file = f.copy } end end
  for _, f in ipairs(type(last_files) == "table" and last_files or {}) do if type(f) == "table" and type(f.copy) == "string" then before["\0" .. f.copy] = true end end
  local out = {}
  for k, m in pairs(now) do if not before[k] then out[#out + 1] = m end end
  table.sort(out, function(a, b) return (a.room or "") .. "\0" .. a.file < (b.room or "") .. "\0" .. b.file end)
  return out
end
-- The stream's name on the link for a room's media file, or nil when it can't go (not audio the link takes, a name the link won't take, a
-- folder other than "plugin files/"): Syncthing carries those. Both ends work it out, so nothing in a message ever names a path. Pure.
function streams.media_name(room, file)
  if not direct.plain(room) or type(file) ~= "string" then return nil end
  local sub, name = file:match("^(plugin files)/([^/]+)$")
  name = name or file
  if not direct.plain(name) or not streams.audio_ext(name) then return nil end
  local n = "~media~" .. room .. "~" .. (sub and (sub .. "~") or "") .. name
  return #n <= 200 and n or nil
end
-- A "media" message checked and made an entry for this song, or nil. Pure.
function streams.valid_media(d, song, me, now)
  if type(d) ~= "table" or type(d.id) ~= "string" or #d.id > 120 or not d.id:match("^[%w%-_]+$") then return nil end
  if type(d.user) ~= "string" or d.user == me or not direct.plain(d.user) then return nil end
  local size = tonumber(d.size)
  if not size or size <= 0 or size ~= math.floor(size) or size > 16 * 2 ^ 30 then return nil end
  local name = streams.media_name(d.room, d.file)
  local rel = name and direct.stream_rel(song, name)
  if not rel then return nil end
  return { id = d.id, user = d.user, room = d.room, file = d.file, size = size, rel = rel, key = song .. "/" .. d.room .. "/" .. d.file,
    made = now, progress_at = now, bytes = 0 }
end
-- What to do with an announced file now. target_size: the shared folder's file (nil: not there); inbox_size: the received copy's, once done.
-- -> "have" (something's there already: Syncthing's copy, or ours. Never written over), "place" (complete, hash-checked, the size announced),
-- "drop" (nothing came for DONE_KEEP: Syncthing brings it), "wait". Pure.
function streams.place_decision(e, target_size, inbox_size, now)
  if target_size then return "have" end
  if e.done and e.ok and tonumber(e.total) == e.size and inbox_size == e.size then return "place" end
  if now - (e.progress_at or e.made or now) > streams.DONE_KEEP then return "drop" end
  return "wait"
end
-- Media copies in <inbox>/.streams/<song> that can go: not an entry's, not still arriving, and not finished in the last MEDIA_GRACE seconds (its
-- message may still be on its way). names: the folder's; book: rel -> entry; inn: name -> the extension's record ({ done, at }); now: os.time().
function streams.media_prunable(names, book, inn, now)
  local mine, out = {}, {}
  for _, e in pairs(book) do mine[e.rel:match("[^/]+$")] = true end
  for _, f in ipairs(names) do
    local i = inn[f]
    local busy = i ~= nil and (i.done ~= true or now - (tonumber(i.at) or 0) < streams.MEDIA_GRACE)
    if f:sub(1, 7) == "~media~" and not mine[f] and not busy and not f:match("%.part$") then out[#out + 1] = f end
  end
  return out
end

-- The sender's side: after a change goes out (mirror's W.send, beside sync.post), its new media to the others here. Only a file made or written
-- in the last MEDIA_FRESH seconds (one copied in, rendered or printed now: an older one they have), once per script, and never one this script
-- put in place from the link. -> how many went. Never raises.
streams.sent_media, streams.placed = {}, {} -- song/room/file -> true
local media_seq = 0
function streams.offer_media(cfg, song, room, media_dir, ev, last)
  local ok, n = pcall(function()
    local time_of = reaper.StudioSync_DirectFileTime
    if not time_of or not direct.live_available() then return 0 end
    local list = streams.media_new(ev.state, last and last.state, ev.files, last and last.files)
    if #list == 0 then return 0 end
    local md = tostring(media_dir):gsub("\\", "/"):gsub("/+$", "")
    local here, rooms = md:match("([^/]+)/media$"), md:gsub("/[^/]+/media$", "")
    local sent = 0
    for _, m in ipairs(list) do
      local r = m.room or here
      local key, path, name = song .. "/" .. tostring(r) .. "/" .. m.file, rooms .. "/" .. tostring(r) .. "/media/" .. m.file, streams.media_name(r, m.file)
      local t = name and not streams.sent_media[key] and not streams.placed[key] and time_of(path) or -1
      local size = t >= 0 and os.time() - t <= streams.MEDIA_FRESH and band.size(path) or nil
      local rel = size and size > 0 and direct.stream_start(cfg, path, song, room, streams.MEDIA_INTERVAL_MS, name)
      if rel then
        direct.stream_end(cfg, rel) -- (it's complete: begun and ended at once, so the rest, its length and SHA-256 follow straight away)
        streams.sent_media[key], media_seq, sent = true, media_seq + 1, sent + 1
        local id = string.format("%s-%s-%d%04d", (cfg.user:gsub("[^%w%-_]", "_")), os.date("!%Y%m%d-%H%M%SZ"), media_seq, math.random(0, 9999))
        direct.send_live(cfg, "media", { id = id, user = cfg.user, room = r, file = m.file, size = size }, song, room, id)
        streams.trace("media out " .. rel .. " " .. size .. " bytes")
      end
    end
    return sent
  end)
  return ok and n or 0
end

-- Everyone else's side.
streams.media = {} -- rel -> entry (this tab's song)
streams.placed_at = {} -- { target, size, at }: files put in place from the link in the last TEMP_WATCH seconds
streams.TEMP_WATCH, streams.TEMP_IDLE = 900, 60
-- Syncthing's temp download of a file we put in place first (Windows "~syncthing~<name>.tmp", elsewhere ".syncthing.<name>.tmp"), removed once
-- it's the whole size and untouched for TEMP_IDLE seconds: a download still going is written to (and Windows holds it open). Syncthing would
-- keep it a day. size_of/time_of/remove passed in (tests). -> the placed list, entries older than TEMP_WATCH dropped.
function streams.tidy_syncthing_temps(list, now, wall, size_of, time_of, remove)
  local keep = {}
  for _, p in ipairs(list) do
    local dir, base = p.target:match("^(.*)/([^/]+)$")
    for _, t in ipairs({ dir .. "/~syncthing~" .. base .. ".tmp", dir .. "/.syncthing." .. base .. ".tmp" }) do
      local ft = time_of and time_of(t) or -1
      if ft >= 0 and wall - ft >= streams.TEMP_IDLE and size_of(t) == p.size and size_of(p.target) == p.size then remove(t) end
    end
    if now - p.at < streams.TEMP_WATCH then keep[#keep + 1] = p end
  end
  return keep
end
local media_at, media_pruned = -math.huge, -math.huge
function streams.on_media(cfg, b, d)
  local e = streams.valid_media(d, b.song, cfg.user, reaper.time_precise())
  if not e or streams.media[e.rel] then return false end
  local room_dir = cfg.root .. "/" .. b.song .. "/rooms/" .. e.room
  if #band.subdirs(room_dir) == 0 then return false end -- (a room this computer doesn't have: nothing written where Syncthing wouldn't)
  e.inbox, e.target = direct.stream_path(cfg, e.rel), room_dir .. "/media/" .. e.file
  local dir, base = e.target:match("^(.*)/([^/]+)$")
  e.tmp = dir .. "/.syncthing." .. base .. ".direct.tmp" -- (Syncthing ignores ".syncthing.*"; not its own download's name, .syncthing.<name>.tmp)
  streams.media[e.rel] = e
  return true
end
-- In place: one rename when the inbox is on the same disk (atomic; Windows' won't write over a file that appeared meanwhile, POSIX's would only
-- with these same bytes). Else copied in the background to e.tmp first (REAPER doesn't hold still for a big file), finished on a later tick.
local function place(e)
  reaper.RecursiveCreateDirectory(e.target:match("^(.*)/"), 0)
  if os.rename(e.inbox, e.target) then return true end
  if reaper.file_exists(e.target) then os.remove(e.inbox); return true end -- (Syncthing's landed this moment: left as it is)
  band.copy_background(e.inbox, e.tmp)
  e.copying = true
  return false
end
local function copied(e) -- -> true once the background copy is in place (or something else got there first)
  if band.size(e.tmp) ~= e.size then return false end
  if reaper.file_exists(e.target) then os.remove(e.tmp) elseif not os.rename(e.tmp, e.target) then return false end -- (held a moment: next tick)
  os.remove(e.inbox)
  return true
end
-- Each Live sync tick: announced files put in place once they're here and checked, the inbox's media copies tidied. -> how many were put in
-- place (Live sync then looks at once: the items waiting for them can land).
function streams.media_tick(cfg, b)
  local now = reaper.time_precise()
  if now - media_at < streams.TICK then return 0 end
  media_at = now
  if not next(streams.media) and now - media_pruned < streams.PRUNE_EVERY then return 0 end
  local inn, by_name = {}, {}
  for _, i in ipairs(direct.streams(cfg).inn) do inn[i.rel] = i; by_name[tostring(i.rel):match("[^/]+$") or ""] = i end
  local placed = 0
  for rel, e in pairs(streams.media) do
    streams.update(e, inn[rel], now)
    local done
    if e.copying then
      done = copied(e)
      if not done and now - e.progress_at > streams.DONE_KEEP then os.remove(e.tmp); streams.media[rel] = nil end
    else
      local how = streams.place_decision(e, band.size(e.target), e.done and band.size(e.inbox) or nil, now)
      if how == "place" then done = place(e)
      elseif how ~= "wait" then
        if how == "have" and e.done then os.remove(e.inbox) end -- (still arriving: the prune takes it once it's done)
        streams.media[rel] = nil
      end
    end
    if done then
      streams.media[rel], streams.placed[e.key], placed = nil, true, placed + 1
      streams.placed_at[#streams.placed_at + 1] = { target = e.target, size = e.size, at = now }
      -- (Syncthing told at once, so it indexes our copy before pulling its own: otherwise its download, a moment behind, found the file there,
      -- gave up and left its full-size temp for a day. 0.59.49.10 test, James, rt)
      local rel_in = e.target:sub(#cfg.root + 2)
      band.try("services.rescan", function() require("services").rescan(band.info(cfg.root).id, rel_in) end)
      streams.trace("media in " .. rel .. " -> " .. e.target)
    end
  end
  if now - media_pruned >= streams.PRUNE_EVERY then
    media_pruned = now
    streams.placed_at = streams.tidy_syncthing_temps(streams.placed_at, now, os.time(), band.size, reaper.StudioSync_DirectFileTime, os.remove)
    local folder = direct.inbox(cfg.root) .. "/.streams/" .. b.song
    for _, f in ipairs(streams.media_prunable(band.files(folder), streams.media, by_name, os.time())) do os.remove(folder .. "/" .. f) end
  end
  return placed
end

-- Live sync's call, every tick. -> how many media files were put in place.
function streams.tick(proj, cfg, b, recording, in_front)
  if in_front then streams.send_tick(proj, cfg, b, recording) end
  streams.receive_tick(proj, cfg, b, recording)
  return streams.media_tick(cfg, b)
end

-- Health's row (lib/direct.lua health_rows): nil when nothing streams.
function streams.health_row(cfg)
  local text = streams.health_text(direct.streams(cfg))
  return text and { "direct streams", true, "grey", text, text } or nil
end

return streams
