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
-- (REAPER's "rename recorded files" box) and recording formats REAPER writes elsewhere aren't followed. Those takes simply arrive the normal
-- way. A bandmate who joins mid-take gets it from its start (the same stream, the extension sends a peer added later from byte 0).
-- Punch-in assist: a recording with auto-punch or pre-roll tells the others where (a "punch" message), shown on their timeline till it ends.
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
-- punch_from: time selection auto-punch's start, when on: REAPER writes only from there, so a take that starts before it starts there.
function streams.start_pos(cursor, play, punch_from)
  local p = play - cursor < 5 and cursor or play
  if punch_from and punch_from > p then return punch_from end
  return p
end
-- Late joiners (James, rt): the peers here now that a take hasn't gone to yet (to: peer -> true). Pure.
function streams.newcomers(peers, to)
  local out = {}
  for _, p in ipairs(peers or {}) do if not to[p] then out[#out + 1] = p end end
  return out
end
-- Punch-in assist (James, rt: "go again from the bridge" unambiguous). What a recording tells the others: auto (time selection auto-punch
-- on), the time selection, the take's start, and the pre-roll in seconds (0: off). -> { start, stop (the punch out, nil without auto-punch),
-- preroll (nil: none) }, or nil when there's nothing to show beyond the take itself. Pure.
function streams.punch_info(auto, ts_s, ts_e, pos, preroll)
  local stop = auto and ts_s and ts_e and ts_e > ts_s and ts_e > pos and ts_e or nil
  local pre = (tonumber(preroll) or 0) > 0 and preroll or nil
  if not stop and not pre then return nil end
  return { start = stop and math.max(ts_s, pos) or pos, stop = stop, preroll = pre }
end
streams.PUNCH_MARK, streams.PUNCH_KEEP = "[punch] ", 1800 -- (a name band.is_local_mark keeps off the band's markers; dropped after 30 min with no end)
-- A "punch" message checked, or nil. Pure.
function streams.valid_punch(d, me)
  if type(d) ~= "table" or type(d.id) ~= "string" or #d.id > 120 or not d.id:match("^[%w%-_]+$") then return nil end
  if type(d.user) ~= "string" or d.user == me or not direct.plain(d.user) or #d.user > 60 then return nil end
  local s, e, pre = tonumber(d.start), tonumber(d.stop), tonumber(d.preroll)
  if not s or s ~= s or s < 0 or s > 1e6 then return nil end
  if d.stop ~= nil and not (e and e > s and e <= 1e6) then return nil end
  if d.preroll ~= nil and not (pre and pre > 0 and pre <= 600) then return nil end
  return { id = d.id, user = d.user, start = s, stop = e, preroll = pre }
end
-- The markers and regions a punch shows: { { region, pos, rend, name } }. Pure.
function streams.punch_marks(p)
  local who, out = streams.PUNCH_MARK .. p.user, {}
  if p.stop then out[1] = { region = true, pos = p.start, rend = p.stop, name = who .. " punches in-out" }
  else out[1] = { region = false, pos = p.start, rend = 0, name = who .. " records from here" } end
  if p.preroll then out[#out + 1] = { region = false, pos = math.max(0, p.start - p.preroll), rend = 0, name = who .. " pre-roll" } end
  return out
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
-- Producer listen (James, rt): bandmates' takes as they come play at this level here (the placeholder's item volume: never sent, mirror skips
-- the item), so a producer sets them against the mix on their own monitors without touching the track's fader, which is the band's.
function streams.listen_db() return math.max(-60, math.min(6, tonumber(reaper.GetExtState(band.SECTION, "stream listen db")) or 0)) end
function streams.listen_vol(db) return db <= -60 and 0 or 10 ^ (db / 20) end -- (pure)

-- The recording-format hint (James, rt; roadmap "Step 2 checked in REAPER"): REAPER writes a take in 256 KB blocks, so a FLAC take reaches
-- the link in steps of about 2-5 s (24-bit WAV: under 1 s), and "In time" one bar behind hears its newest seconds late.
streams.FLAC_STEP, streams.WAV24 = 5, "ZXZhdxgAAQ==" -- (seconds; REAPER's 24-bit WAV sink, as lib/extras.lua's)
-- A sink config (base64, as GetSetProjectInfo_String "RECORD_FORMAT" gives it) -> its kind: "flac", "wave", ... (REAPER stores the four
-- letters backwards: "calf", "evaw"). Pure.
function streams.fourcc(cfg_b64)
  local raw = require("fxfiles").unbase64(tostring(cfg_b64 or ""):sub(1, 8)):sub(1, 4)
  return #raw == 4 and raw:reverse() or ""
end
-- This computer records 24-bit WAV instead of the studio's FLAC, for in-time listening (its own choice: lib/prep.lua keep_format holds it).
function streams.record_wav() return reaper.GetExtState(band.SECTION, "record wav") == "1" end
function streams.record_want() return streams.record_wav() and streams.WAV24 or band.FLAC end
function streams.format_ok(fmt) if streams.record_wav() then return streams.fourcc(fmt) == "wave" end return fmt == band.FLAC end
-- Enough bars behind to cover a FLAC step, for a bar this many seconds long. Pure.
function streams.flac_bars(bar_secs) return math.min(16, math.max(2, math.ceil(streams.FLAC_STEP / math.max(0.1, bar_secs or 2)))) end
-- What to say (nil: nothing): this computer records FLAC, "In time" is chosen and the bars behind don't cover a FLAC step. Pure.
function streams.format_hint(kind, mode, bars, bar_secs)
  if mode ~= "in_time" or kind ~= "flac" or bars * (bar_secs or 2) >= streams.FLAC_STEP then return nil end
  return string.format("Takes recorded to FLAC (this computer's, and the studio's way) reach the others in steps of 2-5 s, so %d bar%s behind " ..
    "hears the newest seconds late. Use %d bars behind, or record WAV here (steps under a second; your takes are about twice the size in the " ..
    "shared folder).", bars, bars == 1 and "" or "s", streams.flac_bars(bar_secs))
end
local function format_state(proj)
  proj = proj or reaper.EnumProjects(-1)
  local fmt = proj and select(2, reaper.GetSetProjectInfo_String(proj, "RECORD_FORMAT", "", false)) or ""
  local bar = proj and require("together").bars_after(proj, reaper.GetCursorPositionEx(proj), 1) or 2
  return proj, streams.fourcc(fmt), bar
end
function streams.use_wav(proj, on)
  reaper.SetExtState(band.SECTION, "record wav", on and "1" or "", true)
  reaper.GetSetProjectInfo_String(proj, "RECORD_FORMAT", on and streams.WAV24 or band.FLAC, true)
  band.log(on and "this computer records 24-bit WAV now, so bandmates listening in time hear your takes under a second behind" or
    "this computer records the studio's 24-bit FLAC again")
end
-- Health's row for it (lib/page_health.lua), nil when there's nothing to say.
function streams.format_row(proj)
  local p, kind, bar = format_state(proj)
  local text = p and streams.format_hint(kind, streams.mode(), streams.bars(), bar)
  if not text then return nil end
  return { "stream format", false, "yellow", "", text, action = { "Record WAV here", function() streams.use_wav(p, true) end,
    "This computer records 24-bit WAV from now on (Settings > Options, Parts play, puts FLAC back)." } }
end
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
    ImGui.SetItemTooltip(ctx, "How far behind the one recording your playback runs. One bar is plenty for WAV takes over Tailscale; FLAC takes need more.")
    local proj, kind, bar = format_state()
    local hint = proj and streams.format_hint(kind, "in_time", streams.bars(), bar)
    if hint then
      ImGui.TextWrapped(ctx, hint)
      if ImGui.SmallButton(ctx, "Use " .. streams.flac_bars(bar) .. " bars##streamflacbars") then reaper.SetExtState(band.SECTION, "stream bars", tostring(streams.flac_bars(bar)), true) end
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Record WAV here##streamwav") then streams.use_wav(proj, true) end
      ImGui.SetItemTooltip(ctx, "This computer records 24-bit WAV from now on, in every studio project (the studio's way is FLAC).")
    end
  end
  if streams.mode() ~= "show" then
    ImGui.SetNextItemWidth(ctx, 160)
    local db = streams.listen_db()
    local ch, v = ImGui.SliderDouble(ctx, "their takes' level here##streamdb", db, -60, 6, db <= -60 and "off" or "%.1f dB")
    if ch then reaper.SetExtState(band.SECTION, "stream listen db", string.format("%.1f", v), true) end
    ImGui.SetItemTooltip(ctx, "How loud a bandmate's take plays here while they record (producing them, say): only on this computer, the track's\n" ..
      "fader and everyone else's mix stay as they are. The real take, once it lands, plays as the track has it.")
  end
  if streams.record_wav() then
    ImGui.TextDisabled(ctx, "This computer records 24-bit WAV (for in-time listening).")
    ImGui.SameLine(ctx)
    local proj = reaper.EnumProjects(-1)
    if proj and ImGui.SmallButton(ctx, "Back to FLAC##streamflac") then streams.use_wav(proj, false) end
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
    if rec and ((rec.takes and #rec.takes > 0) or rec.punch) then
      rec.stopped_at = rec.stopped_at or now
      if now - rec.stopped_at < streams.END_DELAY then return end -- (REAPER writes the real header as it stops: the stream's last pass reads it)
      for _, t in ipairs(rec.takes) do
        streams.trace("stream_end " .. t.rel .. " -> " .. tostring(direct.stream_end(cfg, t.rel)))
        direct.send_live(cfg, "take_end", { id = t.id }, b.song, b.room, t.id)
      end
      if #rec.takes > 0 then band.log(string.format("your take%s went out to the others as you recorded", #rec.takes > 1 and "s" or "")) end
      if rec.punch then direct.send_live(cfg, "punch_end", { id = rec.punch.id }, b.song, b.room, rec.punch.id) end
    end
    rec = nil
    return
  end
  if not rec then
    rec = { t0 = now, wall = os.time(), dir = record_dir(proj), found = {}, old = {}, takes = {}, looked = -math.huge, first = true }
    rec.tracks = armed_audio(proj)
    local peers = direct.peers(cfg, b.song, b.room)
    if #peers == 0 then
      streams.trace(string.format("record start: %d armed audio tracks, no peers: not streamed", #rec.tracks))
      rec.none = true
      return
    end
    local play = reaper.GetPlayPositionEx(proj)
    -- (where the punch is, read once as recording begins: time selection auto-punch is action 40076's state, pre-roll 41819's and
    -- "prerollmeas" bars before the take's start. James, rt)
    local auto = reaper.GetToggleCommandStateEx(0, 40076) == 1
    local ts_s, ts_e = reaper.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
    rec.pos = streams.start_pos(reaper.GetCursorPositionEx(proj), play, auto and ts_s and ts_e and ts_e > ts_s and ts_s or nil)
    local pre = 0
    if reaper.GetToggleCommandStateEx(0, 41819) == 1 then
      local ok, bars = reaper.get_config_var_string("prerollmeas")
      pre = ok and require("together").bars_before(proj, rec.pos, tonumber(bars) or 0) or 0
    end
    local punch = streams.punch_info(auto, ts_s, ts_e, rec.pos, pre)
    if punch then -- (MIDI and audio alike: sent whatever is armed)
      punch.id, punch.user = string.format("%s-%s-%03dp", (cfg.user:gsub("[^%w%-_]", "_")), os.date("!%Y%m%d-%H%M%SZ"), math.floor(now * 1000) % 1000), cfg.user
      rec.punch, rec.punch_to = punch, {}
      for _, p in ipairs(peers) do rec.punch_to[p] = true end
      direct.send_live(cfg, "punch", punch, b.song, b.room, punch.id, peers)
    end
    local sn = direct.shared_now()
    rec.at = sn and sn - (play - rec.pos) or nil -- (in a count-in, a moment still to come)
    rec.cap = 30 + math.max(0, rec.pos - play) -- (looked for at most this long: longer when a punch-in is still ahead)
    if #rec.tracks == 0 then
      streams.trace("record start: no armed audio tracks: not streamed")
      rec.none = true
    end
  end
  if rec.punch then -- (someone who arrives mid-take sees the punch too)
    for _, p in ipairs(streams.newcomers(direct.peers(cfg, b.song, b.room), rec.punch_to)) do
      rec.punch_to[p] = true
      direct.send_live(cfg, "punch", rec.punch, b.song, b.room, rec.punch.id, { p })
    end
  end
  if rec.none then return end
  -- Late-joiner catch-up (James, rt): a bandmate who appears here while a take streams gets it from its start. StudioSync_DirectStream again
  -- with the same name and file adds the peer to the running stream (extension/direct.cpp api_stream: "a peer added later starts from the
  -- beginning"); the others carry on where they are. Their "take" message makes their placeholder.
  if #rec.takes > 0 then
    local peers = direct.peers(cfg, b.song, b.room)
    for _, t in ipairs(rec.takes) do
      for _, p in ipairs(streams.newcomers(peers, t.to)) do
        t.to[p] = true
        local rel = direct.stream_start(cfg, t.path, b.song, b.room, streams.INTERVAL_MS, t.name, { p })
        streams.trace("late joiner " .. p .. ": " .. t.rel .. " from its start -> " .. tostring(rel))
        if rel then direct.send_live(cfg, "take", t.msg, b.song, b.room, t.id, { p }) end
      end
    end
  end
  -- (looked for until FIND_SECS after the playhead reaches the take's start: a count-in or pre-roll comes first, and REAPER may make the file
  -- only as it ends)
  if not rec.find_until and reaper.GetPlayPositionEx(proj) >= rec.pos - 0.01 then rec.find_until = now + streams.FIND_SECS end
  if (rec.find_until and now > rec.find_until) or now - rec.t0 > rec.cap or now - rec.looked < streams.TICK then return end
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
    local path, name, peers = rec.dir .. "/" .. m.file, streams.stream_name(b.room, cfg.user, m.file), direct.peers(cfg, b.song, b.room)
    local rel = direct.stream_start(cfg, path, b.song, b.room, streams.INTERVAL_MS, name, peers)
    streams.trace("stream_start " .. path .. " for " .. m.track.name .. " -> " .. tostring(rel))
    if rel then
      local msg = { id = id, user = cfg.user, track = m.track.oid, name = m.track.name, file = m.file, pos = rec.pos, at = rec.at,
        srate = srate(proj), nch = m.track.nch, fmt = m.file:match("%.(%w+)$"):lower() }
      local to = {}
      for _, p in ipairs(peers) do to[p] = true end
      rec.takes[#rec.takes + 1] = { id = id, rel = rel, path = path, name = name, msg = msg, to = to } -- (path, name, msg, to: for late joiners)
      streams.streamed[band.norm(path):lower()] = { file = m.file, rel = rel } -- (its shared copy then goes as "this stream": offer_media)
      direct.send_live(cfg, "take", msg, b.song, b.room, id, peers)
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

-- Punch-in assist, the others' side: a bandmate's punch range (a region) or start (a marker), and their pre-roll (a marker), in their colour,
-- named "[punch] <user> ..." so they're this computer's only (band.is_local_mark), gone when their recording ends.
streams.punches = {} -- id -> { user, marks, at }
local function drop_punch(proj, id)
  local p = streams.punches[id]
  streams.punches[id] = nil
  if not (p and proj) then return end
  for i = reaper.CountProjectMarkers(proj) - 1, 0, -1 do
    local _, rgn, pos, _, name = reaper.EnumProjectMarkers3(proj, i)
    for _, m in ipairs(p.marks) do
      if m.region == rgn and m.name == name and math.abs(m.pos - pos) < 1e-6 then reaper.DeleteProjectMarkerByIndex(proj, i); break end
    end
  end
  reaper.UpdateArrange()
end
function streams.on_punch(proj, cfg, b, d)
  local p = streams.valid_punch(d, cfg.user)
  if not p or streams.punches[p.id] or not proj then return false end
  for id, q in pairs(streams.punches) do if q.user == p.user then drop_punch(proj, id) end end -- (their last one, if its end never came)
  local rgb = require("people").colours(cfg.root, { p.user })[p.user]
  local col = rgb and (reaper.ColorToNative((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255) | 0x1000000) or 0
  p.marks, p.at = streams.punch_marks(p), reaper.time_precise()
  for _, m in ipairs(p.marks) do reaper.AddProjectMarker2(proj, m.region, m.pos, m.rend, m.name, -1, col) end
  streams.punches[p.id] = p
  reaper.UpdateArrange()
  return true
end
function streams.on_punch_end(proj, d) if type(d) == "table" and streams.punches[d.id] then drop_punch(proj, d.id) end end

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
  for id, p in pairs(streams.punches) do if now - p.at > streams.PUNCH_KEEP then drop_punch(proj, id) end end -- (its end never came)
  if not next(streams.book) and now - pruned_at < streams.PRUNE_EVERY then return end
  local s = direct.streams(cfg)
  local inn, active = {}, {}
  for _, i in ipairs(s.inn) do
    inn[i.rel] = i
    if not i.done then active[tostring(i.rel):match("[^/]+$") or ""] = true end
  end
  local mirror, mode, listen_db = require("mirror"), streams.mode(), streams.listen_db()
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
        local vol = streams.listen_vol(listen_db) -- (producer listen: this computer's level for takes as they come)
        if math.abs(reaper.GetMediaItemInfo_Value(it, "D_VOL") - vol) > 1e-6 then reaper.SetMediaItemInfo_Value(it, "D_VOL", vol) end
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
-- The stream's name on the link for a room's media file, or nil when it can't go (not a kind of file the link takes: direct.stream_ext, audio
-- and the vetted studio files since "send anything"; a name the link won't take; a folder other than "plugin files/"): Syncthing carries those.
-- Both ends work it out, so nothing in a message ever names a path. Pure.
function streams.media_name(room, file)
  if not direct.plain(room) or type(file) ~= "string" then return nil end
  local sub, name = file:match("^(plugin files)/([^/]+)$")
  name = name or file
  if not direct.plain(name) or not direct.stream_ext(name) then return nil end
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
streams.streamed = {} -- a take's file streamed as it was recorded (normalized, lower case) -> { file, rel }
-- The take stream a media file is a byte-for-byte copy of (mirror.share_media's record), while the extension still has that stream: { file, rel },
-- or nil. Not "finished": the change naming the copy goes out ~0.1 s after the stop, before the stream's last pass; each receiver places its
-- copy only once it's done, SHA-256 checked and the size announced, else Syncthing brings it. media_from, streamed, outs passed in. Pure.
function streams.streamed_copy(path, media_from, streamed, outs)
  local src = media_from[band.norm(path):lower()]
  local s = src and streamed[src:lower()]
  if not s then return nil end
  for _, o in ipairs(outs or {}) do if o.rel == s.rel then return s end end
end
local media_seq = 0
local function media_id(cfg) -- (a media message's id: who, when, and a count, as the receivers take each id once)
  media_seq = media_seq + 1
  return string.format("%s-%s-%d%04d", (cfg.user:gsub("[^%w%-_]", "_")), os.date("!%Y%m%d-%H%M%SZ"), media_seq, math.random(0, 9999))
end
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
      -- (a take already streamed as it was recorded: its bytes are there, checked; only which file they are goes. Takes went twice before. rt)
      local take = size and size > 0 and next(streams.streamed) and streams.streamed_copy(path, require("mirror").media_from, streams.streamed, direct.streams(cfg).out)
      local rel = not take and size and size > 0 and direct.stream_start(cfg, path, song, room, streams.MEDIA_INTERVAL_MS, name)
      if rel then direct.stream_end(cfg, rel) end -- (it's complete: begun and ended at once, so the rest, its length and SHA-256 follow straight away)
      if rel or take then
        streams.sent_media[key], sent = true, sent + 1
        local id = media_id(cfg)
        direct.send_live(cfg, "media", { id = id, user = cfg.user, room = r, file = m.file, size = size, take = take and take.file or nil }, song, room, id)
        streams.trace("media out " .. (rel or ("as the streamed take " .. take.rel)) .. " " .. size .. " bytes")
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
  if type(d.take) == "string" then -- (the shared copy of a take that streamed here as it was recorded: copied from that stream's copy, which stays
    -- for the take's own swap. The name is worked out here, as for the take itself)
    local name = streams.stream_name(e.room, e.user, d.take)
    local trel = name and direct.stream_rel(b.song, name)
    if not trel then return false end
    e.src_rel, e.inbox, e.keep_inbox = trel, direct.stream_path(cfg, trel), true
  end
  local dir, base = e.target:match("^(.*)/([^/]+)$")
  e.tmp = dir .. "/.syncthing." .. base .. ".direct.tmp" -- (Syncthing ignores ".syncthing.*"; not its own download's name, .syncthing.<name>.tmp)
  streams.media[e.rel] = e
  return true
end
-- In place: one rename when the inbox is on the same disk (atomic; Windows' won't write over a file that appeared meanwhile, POSIX's would only
-- with these same bytes). Else copied in the background to e.tmp first (REAPER doesn't hold still for a big file), finished on a later tick.
local function place(e)
  reaper.RecursiveCreateDirectory(e.target:match("^(.*)/"), 0)
  if not e.keep_inbox and os.rename(e.inbox, e.target) then return true end
  if reaper.file_exists(e.target) then if not e.keep_inbox then os.remove(e.inbox) end; return true end -- (Syncthing's landed this moment)
  band.copy_background(e.inbox, e.tmp)
  e.copying = true
  return false
end
local function copied(e) -- -> true once the background copy is in place (or something else got there first)
  if band.size(e.tmp) ~= e.size then return false end
  if reaper.file_exists(e.target) then os.remove(e.tmp) elseif not os.rename(e.tmp, e.target) then return false end -- (held a moment: next tick)
  if not e.keep_inbox then os.remove(e.inbox) end
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
    streams.update(e, inn[e.src_rel or rel], now)
    local done
    if e.copying then
      done = copied(e)
      if not done and now - e.progress_at > streams.DONE_KEEP then os.remove(e.tmp); streams.media[rel] = nil end
    else
      local how = streams.place_decision(e, band.size(e.target), e.done and band.size(e.inbox) or nil, now)
      if how == "place" then done = place(e)
      elseif how ~= "wait" then
        if how == "have" and e.done and not e.keep_inbox then os.remove(e.inbox) end -- (still arriving: the prune takes it once it's done)
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

-- ---- catch-up over the link (roadmap step 3, the second half, the light way) -------------------------------------------------------------
-- A computer that comes online or rejoins often waits minutes for Syncthing to pull the media it missed. Syncthing stays the judge of what's
-- missing (its own need list, GET /rest/db/need: services.need); the link only fetches those files faster. While a bandmate is here on the
-- link, this computer reads that list (Syncthing asked in the background at most every CATCHUP_EVERY s) and asks one present peer for each
-- audio file this song's rooms still need: "media_want" { id, user, dev (this computer's device id), room, file, size }, to that peer alone.
-- A peer with that very file (the same size) streams it back to the asker alone, as offer_media does, with the usual "media" message, and the
-- receiver's path above puts it in place (and has Syncthing rescan it). Each file goes once per asker per SERVE_EVERY, SERVE_MAX at a time,
-- and never a file outside a room's media folder (media_name). Without the link, the studio's direct setting or a peer, nothing here runs and
-- Syncthing carries everything as today. (James, rt)
streams.CATCHUP_EVERY, streams.CATCHUP_LOOK, streams.CATCHUP_BATCH, streams.WANT_EVERY = 30, 5, 4, 60
streams.SERVE_EVERY, streams.SERVE_MAX = 600, 3
-- Syncthing's need list (its JSON, decoded) -> the media this song still needs that the link takes: { { room, file, size, by, key } }, smallest
-- first (the most items land soonest). Deleted files, other songs, anything outside a room's media folder: Syncthing's. Pure.
function streams.catchup_wants(need, song)
  local out, seen = {}, {}
  if type(need) ~= "table" then return out end
  for _, part in ipairs({ "progress", "queued", "rest" }) do -- (by name: a list left out would end ipairs over the lists themselves)
    for _, f in ipairs(type(need[part]) == "table" and need[part] or {}) do
      if type(f) == "table" and type(f.name) == "string" and not f.deleted then
        -- (Windows' Syncthing may name it with backslashes)
        local s, room, file = f.name:gsub("\\", "/"):match("^([^/]+)/rooms/([^/]+)/media/(.+)$")
        local size, key = tonumber(f.size), s and (song .. "/" .. room .. "/" .. file)
        if s == song and streams.media_name(room, file) and size and size > 0 and size == math.floor(size) and not seen[key] then
          seen[key] = true
          out[#out + 1] = { room = room, file = file, size = size, by = type(f.modifiedBy) == "string" and f.modifiedBy or nil, key = key }
        end
      end
    end
  end
  table.sort(out, function(a, b) if a.size ~= b.size then return a.size < b.size end return a.key < b.key end)
  return out
end
-- The wants to ask for on this look: not skipped (skip(w): here already, or a room this computer doesn't have), not on their way (an entry in
-- book, the receiver's), each at most every WANT_EVERY s, CATCHUP_BATCH at most. asked: key -> { at, tries }. Pure.
function streams.catchup_due(wants, asked, skip, book, song, now)
  local out = {}
  for _, w in ipairs(wants) do
    if #out >= streams.CATCHUP_BATCH then break end
    local a, rel = asked[w.key], direct.stream_rel(song, streams.media_name(w.room, w.file))
    if not (a and now - a.at < streams.WANT_EVERY) and not (rel and book[rel]) and not skip(w) then out[#out + 1] = w end
  end
  return out
end
-- Which present peer to ask. Syncthing doesn't say who has a file, only who changed it last (modifiedBy: the first part of a device id): that
-- computer first, then the others in turn on each retry. -> a peer, or nil. Pure.
function streams.catchup_peer(peers, dev_of, by, tries)
  if #peers == 0 then return nil end
  tries = tries or 0
  if tries == 0 and type(by) == "string" and by ~= "" then
    for _, p in ipairs(peers) do local d = dev_of[p]; if type(d) == "string" and d:sub(1, #by) == by then return p end end
  end
  local sorted = { table.unpack(peers) }
  table.sort(sorted)
  return sorted[tries % #sorted + 1]
end
-- A "media_want" checked: { id, user, dev, room, file, size, name, key }, or nil. Never this computer's own, never a name the link won't take. Pure.
function streams.valid_want(d, song, my_dev)
  if type(d) ~= "table" or type(d.id) ~= "string" or #d.id > 120 or not d.id:match("^[%w%-_]+$") then return nil end
  if not require("services").is_device_id(d.dev) or d.dev == my_dev or not direct.plain(d.user) then return nil end
  local size = tonumber(d.size)
  if not size or size <= 0 or size ~= math.floor(size) or size > 16 * 2 ^ 30 then return nil end
  local name = streams.media_name(d.room, d.file)
  if not (name and direct.stream_rel(song, name)) then return nil end
  return { id = d.id, user = d.user, dev = d.dev, room = d.room, file = d.file, size = size, name = name, key = song .. "/" .. d.room .. "/" .. d.file }
end
-- Does this computer send an asked-for file now? have: its size here (nil: none); served: dev\0key -> when it last went to that asker; live:
-- media streams still going out. -> true, or false + why. Pure.
function streams.serve_decision(w, have, served, live, now)
  if have ~= w.size then return false, "not this version here" end
  local last = served[w.dev .. "\0" .. w.key]
  if last and now - last < streams.SERVE_EVERY then return false, "sent to it lately" end
  if live >= streams.SERVE_MAX then return false, "busy" end
  return true
end

-- The asker's side, from Live sync's tick (streams.tick). -> how many it asked for. Never raises (band.try around streams.tick).
streams.asked, streams.served = {}, {} -- key -> { at, tries }; dev\0key -> when
local look_at, need_text, need_song, need_wants, served_n = -math.huge, nil, nil, {}, 0
local cloud_asked_at = -math.huge
streams.CLOUD_EVERY = 60
streams.cloud_root, streams.cloud_due = nil, nil -- (Live sync's: the cloud copy's root here; a cloud pass wanted now)
function streams.catchup_tick(cfg, b)
  local now = reaper.time_precise()
  if now - look_at < streams.CATCHUP_LOOK then return 0 end
  look_at = now
  local peers, dev_of = {}, nil
  if direct.live_available() and direct.ensure(cfg) then peers, dev_of = direct.peers(cfg, b.song, b.room) end -- (ensure: false with the direct setting off)
  -- (nobody on the link: the cloud copy may have what Syncthing still needs, so Live sync's cloud pass is asked for, at most every CLOUD_EVERY
  -- s; drive.mirror brings what this song's rooms lack. With no cloud copy either, Syncthing isn't even asked. James, rt)
  local to_cloud = #peers == 0 and streams.cloud_root and now - cloud_asked_at >= streams.CLOUD_EVERY
  if #peers == 0 and not to_cloud then return 0 end
  local services = require("services")
  -- (the list is read every look but Syncthing asked only every CATCHUP_EVERY s; read again only when its answer changed)
  local text = services.need(band.info(cfg.root).id, streams.CATCHUP_EVERY)
  if text ~= need_text or b.song ~= need_song then need_text, need_song, need_wants = text, b.song, streams.catchup_wants(band.json_decode(text or ""), b.song) end
  local rooms = cfg.root .. "/" .. b.song .. "/rooms/"
  local function skip(w) return band.size(rooms .. w.room .. "/media/" .. w.file) ~= nil or #band.subdirs(rooms .. w.room) == 0 end -- (on_media would refuse it)
  if to_cloud then
    local cloud_rooms = streams.cloud_root .. "/" .. b.song .. "/rooms/"
    for k, w in ipairs(need_wants) do
      if k > streams.CATCHUP_BATCH then break end
      if not skip(w) and band.size(cloud_rooms .. w.room .. "/media/" .. w.file) == w.size then
        streams.cloud_due, cloud_asked_at = true, now
        streams.trace("cloud catch-up: " .. w.key .. " is in the cloud copy, nobody on the link: a cloud pass now")
        break
      end
    end
    return 0
  end
  local me = services.my_device_id()
  if not me then return 0 end
  local due = streams.catchup_due(need_wants, streams.asked, skip, streams.media, b.song, now)
  for _, w in ipairs(due) do
    local tries = (streams.asked[w.key] or {}).tries or 0
    local peer = streams.catchup_peer(peers, dev_of or {}, w.by, tries)
    streams.asked[w.key] = { at = now, tries = tries + 1 }
    local id = media_id(cfg)
    direct.send_live(cfg, "media_want", { id = id, user = cfg.user, dev = me, room = w.room, file = w.file, size = w.size }, b.song, b.room, id, { peer })
    streams.trace("media want " .. w.key .. " (" .. w.size .. " bytes) from " .. tostring(peer))
  end
  return #due
end
-- The side that has it: a "media_want" (Live sync's live_handlers). -> true when the file went.
function streams.on_media_want(cfg, b, d)
  local w = streams.valid_want(d, b.song, require("services").my_device_id())
  if not w then return false end
  local peers, dev_of = direct.peers(cfg, b.song, b.room)
  local to
  for _, p in ipairs(peers) do if (dev_of or {})[p] == w.dev then to = p end end
  if not to then return false end -- (only to a computer here the link knows and trusts, as everything else on it)
  local live = 0
  for _, o in ipairs(direct.streams(cfg).out) do if not o.finished and tostring(o.rel):find("/~media~", 1, true) then live = live + 1 end end
  local now, path = reaper.time_precise(), cfg.root .. "/" .. b.song .. "/rooms/" .. w.room .. "/media/" .. w.file
  local ok, why = streams.serve_decision(w, band.size(path), streams.served, live, now)
  if not ok then streams.trace("media want " .. w.key .. " from " .. w.user .. ": not sent, " .. why); return false end
  local rel = direct.stream_start(cfg, path, b.song, b.room, streams.MEDIA_INTERVAL_MS, w.name, { to })
  if not rel then return false end
  direct.stream_end(cfg, rel) -- (complete: begun and ended at once, as offer_media)
  if served_n > 5000 then streams.served, served_n = {}, 0 end -- shortcut: a whole flush past 5,000 sends; the asker's WANT_EVERY still paces it
  streams.served[w.dev .. "\0" .. w.key], served_n = now, served_n + 1
  local id = media_id(cfg)
  direct.send_live(cfg, "media", { id = id, user = cfg.user, room = w.room, file = w.file, size = w.size }, b.song, b.room, id, { to })
  streams.trace("media out (catch-up for " .. w.user .. ") " .. rel .. " " .. w.size .. " bytes")
  return true
end

-- Live sync's call, every tick. -> how many media files were put in place.
function streams.tick(proj, cfg, b, recording, in_front)
  if in_front then streams.send_tick(proj, cfg, b, recording) end
  streams.receive_tick(proj, cfg, b, recording)
  streams.catchup_tick(cfg, b)
  return streams.media_tick(cfg, b)
end

-- Health's row (lib/direct.lua health_rows): nil when nothing streams.
function streams.health_row(cfg)
  local text = streams.health_text(direct.streams(cfg))
  return text and { "direct streams", true, "grey", text, text } or nil
end

return streams
