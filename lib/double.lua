-- Keep a full-quality copy: the double-ender (docs/realtime-roadmap.md "More big ideas" 7; docs/rt/rt-double.md). While people jam
-- (Jam under Parts play, lib/jam.lua) or play live (live audio, lib/liveaudio.lua), each computer records its own armed tracks' inputs on its
-- own disk, raw and lossless, and when the jam stops each part lands in the shared project on that person's track, lined up as it was played.
-- What the others heard during the jam (Opus, or Jam's intervals) was never in the project; the lossless parts are what stays. (James, rt)
--  - Recording: the extension's own tap (StudioSync_KeepStart, extension/direct_audio.cpp), not a REAPER recording. It needs no transport (a
--    live jam often has none), changes nothing about the jam (REAPER's Record would start everyone's Record together, stream each take as it
--    grows and put items in the project at its own play position), and stamps every stretch in the audio thread with this computer's link
--    clock and REAPER's play position. One 32-bit float WAV per armed track (mono, or the stereo pair it records), its raw hardware input as
--    REAPER would record it, in "<record path>/StudioSync full quality/" (out of the record folder itself, where lib/streams.lua looks for a
--    take REAPER is writing). Tracks recording MIDI or their own output (instruments) aren't copied: REAPER's Record keeps those.
--  - When: Jam on, from play to stop; live audio otherwise (any transport), until the transport stops after playing, live audio stops, nobody
--    is left on the link for ALONE s (a dropped computer's part lands up to the drop), the copy is switched off, the panel's "Add my part now",
--    or Live sync ends. Nothing is written into the project before then; a file nearing 4 GB or a change of armed inputs only starts new files.
--  - Lining up, per stretch (a segment: { file frame, link clock, playing, play position }, a new one at every play, stop, seek, loop or
--    dropped block): played with the transport, at its song position less this computer's input + output latency and REAPER's input offset
--    (lib/calibrate.lua's measured one), as REAPER places a recording, so every part sits on the bars it was played to; without the transport,
--    by the studio's shared clock (lib/direct.lua shared_now): at the jam's anchor position plus the time since the anchor, less the input
--    latency and offset. The anchor { shared time, project position } is the earliest any computer in the jam started from (each sends theirs
--    every EVERY s and takes the earliest it hears), its position the song position it started at, or a bar past the project's end.
--  - Media: an ordinary new item on the person's track; Live sync's look sends it and lib/streams.lua offers its file over the link at once,
--    with Syncthing as the record. Where the track already has something there, the part goes on a new lane that doesn't play (the comp
--    stays), as lib/prints.lua takes_into_new_lanes does, while the studio's "Takes become lanes" is on; else beside it, as REAPER would.
--  - Said: "Recording your part in full quality" in the panel's top bar while it runs, then "3 parts added, lined up" (each computer's own
--    and those the others say they added). A Health row, and the switch in Settings > Options under Jam. GPL-3.0-or-later.
local band = require("band")
local direct = require("direct")
local double = { TICK = 0.1, EVERY = 2, QUIET = 10, ALONE = 10, MIN_LEN = 0.05, FILES = 16, CHANS = 32, FILE_BYTES = 3e9, SHOW_FOR = 60,
  DONE_WINDOW = 60, KEY = "keep full copy", STATE = "double state", CMD = "double land", DIR = "StudioSync full quality" }

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
-- tracks: { { guid, name, arm, input (I_RECINPUT), mode (I_RECMODE) } } -> what's copied { { guid, name, ch = { input[, input + 1] } } } and
-- what isn't { { name, why } }. An audio input recorded as input (mode 0, or forced mono/stereo 12/13): its hardware channel, the pair when
-- REAPER records it as stereo. Pure.
local IN_MODES = { [0] = true, [12] = true, [13] = true }
function double.inputs(tracks)
  local out, skipped, used = {}, {}, 0
  for _, t in ipairs(tracks) do
    if t.arm == 1 then
      local inp, mode = math.floor(tonumber(t.input) or -1), math.floor(tonumber(t.mode) or 0)
      local ch, why = inp >= 0 and inp & 1023 or -1, nil
      if not IN_MODES[mode] or inp < 0 or inp & 4096 ~= 0 then why = "records MIDI or its own sound (REAPER's Record keeps those)"
      elseif inp & 2048 ~= 0 then why = "records a multichannel input"
      elseif ch >= 512 then why = "records a ReaRoute or loopback input" end
      local need = not why and inp & 1024 ~= 0 and 2 or 1
      if not why and (#out >= double.FILES or used + need > double.CHANS) then why = "more than one copy takes (16 tracks)" end
      if why then skipped[#skipped + 1] = { name = t.name, why = why }
      else out[#out + 1] = { guid = t.guid, name = t.name, ch = need == 2 and { ch, ch + 1 } or { ch } }; used = used + need end
    end
  end
  return out, skipped
end
-- Which inputs, as one string (a change starts new files). Pure.
function double.inputs_key(list)
  local k = {}
  for _, t in ipairs(list) do k[#k + 1] = tostring(t.guid) .. "=" .. table.concat(t.ch, ",") end
  return table.concat(k, ";")
end
-- The extension's spec: a line per file, "ch[,ch2]\tpath". nil when a path can't go in it. Pure.
function double.spec(list, paths)
  local lines = {}
  for i, t in ipairs(list) do
    local p = paths[i]
    if type(p) ~= "string" or p == "" or p:find("[\t\r\n]") then return nil end
    lines[#lines + 1] = table.concat(t.ch, ",") .. "\t" .. p
  end
  return #lines > 0 and (table.concat(lines, "\n") .. "\n") or nil
end
-- Where each stretch of a file goes. segs: { { n0 (file frame), t0 (shared clock, s), playing, p0 (play position) } } in file order; o = { sr,
-- frames (in the file), rec (s: input + output latency + REAPER's input offset), inp (s: input latency + offset), anchor = { t, pos } }.
-- -> { { pos, offs (seconds into the file), len, playing } }: played with the transport at p0 - rec; without, at anchor.pos + (t0 - inp -
-- anchor.t); nothing before the project's start; stretches that follow on exactly in the file and in the project are one. Pure.
function double.place(segs, o)
  local out = {}
  for k, s in ipairs(segs) do
    local n1 = math.min(segs[k + 1] and segs[k + 1].n0 or o.frames, o.frames)
    local offs, len, pos = s.n0 / o.sr, (n1 - s.n0) / o.sr, nil
    if s.playing then pos = s.p0 - o.rec
    elseif o.anchor then pos = o.anchor.pos + (s.t0 - o.inp - o.anchor.t) end
    if pos and pos < 0 then offs, len, pos = offs - pos, len + pos, 0 end
    if pos and len >= double.MIN_LEN then
      local last = out[#out]
      if last and math.abs(last.pos + last.len - pos) < 1e-4 and math.abs(last.offs + last.len - offs) < 1e-4 then last.len = last.len + len
      else out[#out + 1] = { pos = pos, offs = offs, len = len, playing = s.playing } end
    end
  end
  return out
end
-- The jam's last stretch, when it's only the moment between a transport stop and the copy's end (its next tick): left out. -> segs, frames. Pure.
function double.cut_tail(segs, frames)
  local n = #segs
  if n >= 2 and not segs[n].playing and segs[n - 1].playing then
    local out = {}
    for i = 1, n - 1 do out[i] = segs[i] end
    return out, segs[n].n0
  end
  return segs, frames
end
-- The jam's anchor: the earlier start (the same moment: by name, so every computer picks the same). Pure.
function double.pick(a, b)
  if not a then return b end
  if not b then return a end
  if b.t < a.t - 1e-6 or (math.abs(b.t - a.t) <= 1e-6 and tostring(b.user) < tostring(a.user)) then return b end
  return a
end
-- Should a copy be recording now? -> yes, and why not (nil: nothing to say). Pure.
function double.wanted(on, available, in_front, inputs, peers_ok, jam_on, playing, live_running)
  if not on then return false end
  if not available then return false, "needs a newer StudioSync extension (Extensions > ReaPack > Synchronize packages)" end
  if not in_front then return false, "the song's tab isn't in front" end
  if inputs == 0 then return false, "arm a track with an audio input (MIDI and instrument tracks: use Record)" end
  if not peers_ok then return false, "nobody is here on the direct link" end
  if jam_on then return playing == true, not playing and "starts when the jam plays" or nil end
  if not live_running then return false, "starts when you jam (Jam, above) or live audio runs" end
  return true
end
-- A "double" message checked, or nil: { run, user, anchor = { t, pos, user }, tracks = { names }, done, parts }. Pure.
function double.valid(d, me)
  if type(d) ~= "table" or type(d.run) ~= "string" or #d.run > 120 or not d.run:match("^[%w%-_]+$") then return nil end
  if type(d.user) ~= "string" or d.user == me or #d.user > 60 or not direct.plain(d.user) then return nil end
  local anchor
  if d.anchor ~= nil then
    local a = d.anchor
    local t, pos = type(a) == "table" and tonumber(a.t), type(a) == "table" and tonumber(a.pos)
    if not (t and pos) or t ~= t or pos ~= pos or t < 1e9 or t > 1e10 or pos < 0 or pos > 1e6 or type(a.user) ~= "string" or #a.user > 60 then return nil end
    anchor = { t = t, pos = pos, user = a.user }
  end
  local tracks = {}
  if d.tracks ~= nil then
    if type(d.tracks) ~= "table" or #d.tracks > double.FILES then return nil end
    for _, n in ipairs(d.tracks) do
      if type(n) ~= "string" or #n > 120 then return nil end
      tracks[#tracks + 1] = n
    end
  end
  local parts = tonumber(d.parts)
  if d.parts ~= nil and (not parts or parts ~= math.floor(parts) or parts < 0 or parts > 1000) then return nil end
  return { run = d.run, user = d.user, anchor = anchor, tracks = tracks, done = d.done == true or nil, parts = parts }
end
local function names(list)
  if #list <= 1 then return list[1] or "" end
  return table.concat(list, ", ", 1, #list - 1) .. " and " .. list[#list]
end
-- While it runs: "Recording your part in full quality (Gtr, Vox) · 3:12 · Ann and Bob too". Pure.
function double.running_text(tracks, secs, others)
  secs = math.max(0, math.floor(secs or 0))
  local t = string.format("Recording your part in full quality (%s) · %d:%02d", table.concat(tracks, ", "), secs // 60, secs % 60)
  if others and #others > 0 then t = t .. " · " .. names(others) .. " too" end
  return t
end
-- Afterwards. parts: { { user, tracks = { names }, mine, count } }; missed: words for what didn't go in; unsynced: placed without the shared
-- clock. -> "3 parts added, lined up (yours: Gtr, Vox; Ann: Bass)". Pure.
function double.summary(parts, missed, unsynced)
  local n, each = 0, {}
  for _, p in ipairs(parts) do
    local c = p.count or #p.tracks
    n = n + c
    if c > 0 then each[#each + 1] = (p.mine and "yours" or p.user) .. ": " .. (#p.tracks > 0 and table.concat(p.tracks, ", ") or tostring(c)) end
  end
  local t
  if n == 0 then t = "No full-quality part added"
  else t = string.format("%d part%s added, lined up%s (%s)", n, n == 1 and "" or "s", unsynced and " by this computer's clock (no shared clock)" or "", table.concat(each, "; ")) end
  if missed and #missed > 0 then t = t .. "; not added: " .. table.concat(missed, "; ") end
  return t
end

-- ---- this computer -------------------------------------------------------------------------------------------------------------------
function double.on() return reaper.GetExtState(band.SECTION, double.KEY) == "1" end
function double.set(on)
  reaper.SetExtState(band.SECTION, double.KEY, on and "1" or "", true)
  band.log(on and "a full-quality copy of your armed tracks is kept while you jam or play live; it lands in the song when the jam stops" or "no full-quality copy from now on")
end
function double.available() return reaper.StudioSync_KeepStart ~= nil and reaper.StudioSync_KeepStop ~= nil and reaper.StudioSync_KeepStatus ~= nil end
local function armed(proj)
  local t, mirror = {}, require("mirror")
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1 and not mirror.local_track(tr) then
      t[#t + 1] = { guid = reaper.GetTrackGUID(tr), name = select(2, reaper.GetTrackName(tr)), arm = 1,
        input = reaper.GetMediaTrackInfo_Value(tr, "I_RECINPUT"), mode = reaper.GetMediaTrackInfo_Value(tr, "I_RECMODE") }
    end
  end
  return t
end
local function track_of(proj, guid)
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if reaper.GetTrackGUID(tr) == guid then return tr end
  end
end
-- (seconds: what REAPER takes off a recording, the driver's input + output and its input offset; and the input side alone)
local function latencies(sr)
  local inl, outl = reaper.GetInputOutputLatency()
  local man = tonumber(require("calibrate").offset()) or 0
  inl, outl = tonumber(inl) or 0, tonumber(outl) or 0
  return (inl + outl + man) / sr, (inl + man) / sr
end
local function clock_offset() -- (the shared clock less this computer's link clock; nil without one)
  local sn = direct.shared_now()
  local now = reaper.StudioSync_DirectNow and reaper.StudioSync_DirectNow()
  return sn and now and sn - now or nil
end
local function past_end(proj) -- (a bar past the project's end, on a bar line: where a jam with no transport goes)
  local len = reaper.GetProjectLength(proj)
  if len <= 0 then return 0 end
  local _, meas = reaper.TimeMap2_timeToBeats(proj, len)
  return reaper.TimeMap2_beatsToTime(proj, 0, (tonumber(meas) or 0) + 2)
end
local function status() return band.json_decode(reaper.StudioSync_KeepStatus()) or {} end
local function clean(s) return (tostring(s):gsub("[^%w%-_ ]", "_")) end

-- ---- a run: from the jam's start to its stop, one or more captures (chunks) -------------------------------------------------------------
local run -- { id, chunks, cur, started, played, peer_at, anchor, key, seq, msg_at, peers, unsynced }
double.book = {} -- user -> { run, anchor, tracks, seen, done_at, parts }
local S = { state = "off" } -- what the panel and Health are told (ExtState double.STATE)
local done -- the last jam's: { mine, missed, unsynced, when, till (os.time: shown until), song, text }
double.S = S
local function seg_list(c)
  local idx, out = {}, {}
  for i in pairs(c.segs) do idx[#idx + 1] = i end
  table.sort(idx)
  for _, i in ipairs(idx) do out[#out + 1] = c.segs[i] end
  return out
end
local function poll(proj)
  local c = run and run.cur
  if not c then return end
  local st = status()
  c.st = st
  c.frames, c.sr = math.max(c.frames, math.floor(tonumber(st.frames) or 0)), tonumber(st.srate) or c.sr
  if c.sr > 0 and not c.rec then c.rec, c.inp = latencies(c.sr) end
  local off = nil
  for _, s in ipairs(type(st.segs) == "table" and st.segs or {}) do
    local i = math.floor(tonumber(s[1]) or -1)
    if i >= 0 and not c.segs[i] and c.rec then
      if off == nil then off = clock_offset() or false end
      if not off then run.unsynced = true end
      local seg = { n0 = math.floor(tonumber(s[2]) or 0), t0 = (tonumber(s[3]) or 0) + (off or 0), playing = tonumber(s[4]) == 1, p0 = tonumber(s[5]) or 0 }
      c.segs[i] = seg
      if not run.own then -- (where this computer's jam began: its first sample, on the shared clock, and where in the project that goes)
        run.own = { t = seg.t0 - c.inp, pos = seg.playing and math.max(0, seg.p0 - c.rec) or past_end(proj), user = run.user }
        run.anchor = double.pick(run.anchor, run.own)
      end
    end
  end
end
local function take_dir(proj)
  local d = reaper.GetProjectPathEx(proj, "")
  return (d ~= "" and d or band.home()) .. "/" .. double.DIR
end
local function start_chunk(proj, cfg, b, list)
  local dir = take_dir(proj)
  reaper.RecursiveCreateDirectory(dir, 0)
  local stamp, files, paths, seen = os.date("%Y-%m-%d %H%M%S"), {}, {}, {}
  for i, t in ipairs(list) do
    local nm = t.name ~= "" and t.name or ("Track " .. i)
    seen[nm:lower()] = (seen[nm:lower()] or 0) + 1
    paths[i] = string.format("%s/%s - %s%s - %s %s%s.wav", dir, clean(b.song), clean(nm), seen[nm:lower()] > 1 and (" " .. seen[nm:lower()]) or "", clean(run.user), stamp,
      #run.chunks > 0 and (" part " .. (#run.chunks + 1)) or "") -- (a new file mid-jam: its own name, even in the same second)
    files[i] = { guid = t.guid, name = nm, path = paths[i] }
  end
  local spec = double.spec(list, paths)
  if not spec or reaper.StudioSync_KeepStart(spec) ~= 1 then return false end
  run.cur = { files = files, segs = {}, frames = 0, sr = 0, wide = 1 }
  for _, t in ipairs(list) do run.cur.wide = math.max(run.cur.wide, #t.ch) end
  run.chunks[#run.chunks + 1] = run.cur
  run.key = double.inputs_key(list)
  return true
end
local function finish_chunk(proj)
  if not (run and run.cur) then return end
  reaper.StudioSync_KeepStop() -- (the rest written, the headers' real sizes)
  poll(proj)
  run.cur = nil
end
local function say(cfg, b, extra)
  local tracks = {}
  for _, f in ipairs(run.cur and run.cur.files or run.chunks[#run.chunks] and run.chunks[#run.chunks].files or {}) do tracks[#tracks + 1] = f.name end
  local d = { run = run.id, user = cfg.user, anchor = run.anchor, tracks = tracks }
  for k, v in pairs(extra or {}) do d[k] = v end
  run.seq, run.msg_at = run.seq + 1, reaper.time_precise()
  direct.send_live(cfg, "double", d, b.song, b.room, run.id .. "-" .. run.seq, run.peers)
end
-- The new lane a part goes on where its track already has something there: at the bottom, not playing (lib/prints.lua takes_into_new_lanes).
local function new_lane(tr)
  if reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") ~= 2 then reaper.SetMediaTrackInfo_Value(tr, "I_FREEMODE", 2) end
  local n = math.max(1, math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES")))
  reaper.SetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES", n + 1)
  reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. n, 0)
  reaper.GetSetMediaTrackInfo_String(tr, "P_LANENAME:" .. n, "Jam " .. os.date("%H:%M"), true)
  return n
end
local function overlaps(tr, a, z)
  for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, j)
    local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    if p < z - 0.01 and p + reaper.GetMediaItemInfo_Value(it, "D_LENGTH") > a + 0.01 then return true end
  end
  return false
end
local function put(tr, path, p, lanes_on, label)
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return false end
  local lane = lanes_on and overlaps(tr, p.pos, p.pos + p.len) and new_lane(tr) or nil
  local it = reaper.AddMediaItemToTrack(tr)
  local tk = reaper.AddTakeToMediaItem(it)
  band.set_take_source(tk, src)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", p.pos)
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", p.len)
  reaper.SetMediaItemInfo_Value(it, "B_LOOPSRC", 0)
  reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", p.offs)
  reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", label, true)
  if lane then reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", lane) end
  reaper.UpdateItemInProject(it)
  return true
end
-- When the jam stops: every chunk's files placed on their tracks, one undo point, the look told. -> placed track names, words for what wasn't.
local function land(proj, cfg, b)
  local aok, can = pcall(function() return (require("sync").authority(cfg, b.song, b.room, band.read_json(band.session_path(cfg, b.song)))) end)
  if not aok or type(can) ~= "function" then can = function() return true end end -- (the claims unreadable: the look still holds back what isn't ours)
  local lanes_on = require("groups").takes_to_lanes(cfg.root)
  local label = "Jam " .. os.date("%H:%M") .. " - " .. run.user .. " (full quality)"
  local placed, missed, said = {}, {}, {}
  local function miss(w) if not said[w] then said[w] = true; missed[#missed + 1] = w end end
  reaper.Undo_BeginBlock2(proj)
  reaper.PreventUIRefresh(1)
  local ok, err = pcall(function()
    for ci, c in ipairs(run.chunks) do
      local segs, frames = seg_list(c), c.frames
      if ci == #run.chunks then segs, frames = double.cut_tail(segs, frames) end
      local plan = frames > 0 and c.rec and double.place(segs, { sr = c.sr, frames = frames, rec = c.rec, inp = c.inp, anchor = run.anchor }) or {}
      for _, f in ipairs(c.files) do
        local tr = track_of(proj, f.guid)
        if not tr then miss(f.name .. "'s track is gone (the file: " .. f.path .. ")")
        else
          local name, n = select(2, reaper.GetTrackName(tr)), 0
          for _, p in ipairs(plan) do
            if not can(cfg.user, name, p.pos) then miss(name .. " isn't yours to change here (the file: " .. f.path .. ")")
            elseif put(tr, f.path, p, lanes_on, label) then n = n + 1 end
          end
          if n > 0 then
            if not placed[name] then placed[#placed + 1], placed[name] = name, true end
            require("mirror").touch(proj, tr) -- (read at the next quick look: it goes out as any new item does)
          end
        end
      end
    end
  end)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock2(proj, "StudioSync: full-quality parts from the jam", -1)
  reaper.UpdateArrange()
  if not ok then miss("an error: " .. tostring(err)) end
  return placed, missed
end
local function publish(t)
  local s = band.json_encode(t)
  if s ~= S.json then S.json = s; reaper.SetExtState(band.SECTION, double.STATE, s, false) end
  for k in pairs(S) do if k ~= "json" then S[k] = nil end end
  for k, v in pairs(t) do S[k] = v end
end
local function show_done(now)
  local d = done
  if not d then return end
  local parts = { d.mine }
  for user, e in pairs(double.book) do
    if e.done_at and math.abs(e.done_at - d.when) <= double.DONE_WINDOW then parts[#parts + 1] = { user = user, tracks = e.tracks or {}, count = e.parts } end
  end
  table.sort(parts, function(x, y) if x.mine ~= y.mine then return x.mine == true end return tostring(x.user) < tostring(y.user) end)
  local text = double.summary(parts, d.missed, d.unsynced)
  if text ~= d.text then
    if d.text then band.log("full quality: " .. text) end
    d.text = text
  end
  publish({ state = "done", text = text, song = d.song, till = d.till, skipped = S.skipped })
end
local function end_run(proj, cfg, b, now)
  pcall(finish_chunk, proj)
  local lok, placed, missed = pcall(land, proj, cfg, b)
  if not lok then placed, missed = {}, { "an error: " .. tostring(placed) } end
  say(cfg, b, { done = true, parts = #placed, tracks = placed })
  band.log(#placed > 0 and ("full quality: your part is in, lined up (" .. table.concat(placed, ", ") .. ")") or "full quality: nothing of yours to add")
  done = { mine = { user = cfg.user, tracks = placed, mine = true }, missed = missed, unsynced = run.unsynced, when = now, till = os.time() + double.SHOW_FOR, song = b.song }
  run = nil
  show_done(now)
end
local function start_run(proj, cfg, b, list, peers, now)
  local stamp = os.date("!%Y%m%d-%H%M%SZ") .. string.format("-%03d", math.floor(now * 1000) % 1000)
  run = { id = clean(cfg.user):gsub(" ", "_") .. "-" .. stamp, user = cfg.user, chunks = {}, started = now, peer_at = now, seq = 0, msg_at = -math.huge, peers = peers }
  if not start_chunk(proj, cfg, b, list) then run = nil; return "the extension couldn't start the copy" end
  done = nil
  band.log("full quality: recording your part (" .. table.concat((function() local n = {}; for _, f in ipairs(run.cur.files) do n[#n + 1] = f.name end; return n end)(), ", ") .. ") on this computer")
end

-- Live sync's call, each tick (lib/jam.lua's beside it).
local tick_at = -math.huge
function double.tick(proj, cfg, b, in_front)
  local now = reaper.time_precise()
  if now - tick_at < double.TICK then return end
  tick_at = now
  local on = double.on()
  if not on and not run then
    if done then show_done(now) elseif S.state ~= "off" then publish({ state = "off" }) end
    return
  end
  local playing = reaper.GetPlayStateEx(proj) & 1 == 1
  local list = armed(proj)
  local inputs, skipped = double.inputs(list)
  local peers = direct.live_available() and direct.peers(cfg, b.song, b.room) or {}
  if #peers > 0 and run then run.peer_at, run.peers = now, peers end
  local la = require("liveaudio")
  local want, why = double.wanted(on, double.available(), in_front, #inputs, #peers > 0 or (run ~= nil and now - run.peer_at < double.ALONE),
    require("jam").on(), playing, la.S.sending ~= nil)
  if run then
    poll(proj)
    local c = run.cur
    local st = c and c.st or {}
    run.played = run.played or playing
    local asked = reaper.GetExtState(band.SECTION, double.CMD) ~= ""
    if asked then reaper.DeleteExtState(band.SECTION, double.CMD, false) end
    if not want or asked or (run.played and not playing) or not c then end_run(proj, cfg, b, now); return
    elseif st.state == "failed" or st.rate_changed == true or double.inputs_key(inputs) ~= run.key or c.frames * 4 * c.wide > double.FILE_BYTES then
      finish_chunk(proj) -- (new files, the same jam: they land together at its stop)
      if not start_chunk(proj, cfg, b, inputs) then end_run(proj, cfg, b, now); return end
    end
    if now - run.msg_at >= double.EVERY then say(cfg, b) end
  elseif want then
    why = start_run(proj, cfg, b, inputs, peers, now)
  end
  if run then
    local names_ = {}
    for _, f in ipairs(run.cur and run.cur.files or {}) do names_[#names_ + 1] = f.name end
    local others = {}
    for user, e in pairs(double.book) do if not e.done_at or e.done_at < e.seen then if now - e.seen < double.QUIET then others[#others + 1] = user end end end
    table.sort(others)
    local skip = {}
    for _, s in ipairs(skipped) do skip[#skip + 1] = s.name .. " " .. s.why end
    publish({ state = "recording", text = double.running_text(names_, now - run.started, others), skipped = skip, song = b.song })
  elseif done then show_done(now)
  else publish({ state = "waiting", why = why }) end
end
-- A bandmate's word: their jam's anchor (taken if it's earlier, while ours runs), and when they're done, what they added.
function double.on_msg(cfg, b, d)
  local v = double.valid(d, cfg.user)
  if not v then return false end
  local now = reaper.time_precise()
  local e = double.book[v.user] or {}
  e.run, e.seen = v.run, now
  if #v.tracks > 0 then e.tracks = v.tracks end
  if v.anchor and run then run.anchor = double.pick(run.anchor, v.anchor) end
  if v.done then e.done_at, e.parts = now, v.parts or #v.tracks end
  double.book[v.user] = e
  return true
end
function double.on_exit(proj, cfg, b)
  if run and proj and reaper.ValidatePtr2(0, proj, "ReaProject*") then pcall(end_run, proj, cfg, b, reaper.time_precise())
  elseif run then pcall(finish_chunk, proj) end
  run = nil
  reaper.DeleteExtState(band.SECTION, double.STATE, false)
end
function double.running() return run ~= nil end

-- ---- what the panel shows (its own script: what Live sync says, through ExtState) ----------------------------------------------------------
local function told() local t = band.ext_json(band.SECTION, double.STATE); return type(t) == "table" and t or {} end
local RED, BLUE = 0x8A2B2BFF, 0x2D5D8AFF
-- The top bar (StudioSync - Panel.lua F.top_bar, after live audio's): while it records, and the summary for a minute after.
function double.bar_ui(ctx, ImGui, at_row)
  local t = told()
  local label, colour, tip
  if t.state == "recording" then
    label, colour = "Recording your part in full quality##dblrec", RED
    tip = tostring(t.text) .. "\nOn this computer, lossless; it goes into the song, lined up, when the jam stops. Click: add it now."
  elseif t.state == "done" and os.time() < (tonumber(t.till) or 0) then
    label, colour = tostring(t.text):match("^[^(;]+"):gsub("%s+$", "") .. "##dbldone", BLUE
    tip = tostring(t.text) .. "\nClick: hide."
  else return end
  at_row((label:gsub("##.*", "")))
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, colour)
  local clicked = ImGui.SmallButton(ctx, label)
  ImGui.PopStyleColor(ctx)
  ImGui.SetItemTooltip(ctx, tip)
  if clicked and t.state == "recording" then reaper.SetExtState(band.SECTION, double.CMD, "1", false)
  elseif clicked then t.till = 0; reaper.SetExtState(band.SECTION, double.STATE, band.json_encode(t), false) end
end
-- Settings > Options, under Jam (StudioSync - Panel.lua).
function double.options(ctx, ImGui)
  local ch, v = ImGui.Checkbox(ctx, "Keep a full-quality copy of my part while we jam or play live##dblon", double.on())
  if ch then double.set(v) end
  ImGui.SetItemTooltip(ctx, "Each of you records your own armed tracks on your own computer, lossless (32-bit float, the raw input), while\n" ..
    "you jam or play live and hear each other as live audio or Jam's intervals. When the jam stops, each part goes into the song on its\n" ..
    "track, lined up as it was played (by the song's bars when the transport ran, else by the studio's shared clock, each computer's input\n" ..
    "latency taken off), and reaches everyone as any new recording does. Tracks recording MIDI or an instrument's sound aren't copied.")
  if not double.on() then return end
  local t = told()
  if t.state == "recording" then ImGui.TextDisabled(ctx, tostring(t.text))
  elseif t.state == "done" then ImGui.TextDisabled(ctx, "Last jam: " .. tostring(t.text))
  elseif t.why then ImGui.TextDisabled(ctx, "Not recording: " .. tostring(t.why)) end
  for _, s in ipairs(type(t.skipped) == "table" and t.skipped or {}) do ImGui.TextDisabled(ctx, "Not copied: " .. tostring(s)) end
end
-- Health's row (lib/page_health.lua), none while it's off.
function double.health_rows()
  if not double.on() then return {} end
  local t = told()
  local text, ok
  if t.state == "recording" then text, ok = tostring(t.text), true
  elseif t.state == "done" then text, ok = "Full-quality copy: last jam " .. tostring(t.text), true
  elseif t.why then text, ok = "Full-quality copy: " .. tostring(t.why), not tostring(t.why):find("extension")
  else text, ok = "Full-quality copy: on (Live sync isn't running)", true end
  if type(t.skipped) == "table" and #t.skipped > 0 then text = text .. "; not copied: " .. table.concat(t.skipped, "; ") end
  return { { "full quality", ok, ok and "grey" or "yellow", ok and text or "", text } }
end

return double
