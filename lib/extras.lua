-- The extras a band asks for around the work itself (research of other tools and what their users ask for, 0.58.47): stems for
-- whoever mixes, two mixes compared at matched loudness, a credits draft, a stage for each project, and what happened while you were
-- away. And a guest's own full-quality recording swapped in for what came over SonoBus, lined up by ear (cross-correlation).
local band = require("band")
local extras = {}

-- ---------------------------------------------------------------- stems
-- Every track the band shares, one file each, the whole song, into <Song>/stems/<date>/ (in the shared folder, for everyone), named for
-- its track. As your master hears it (each machine's master is its own), StudioSync's own and your local tracks left out, silent ones
-- skipped. Your render settings and selection are put back. -> the folder, and how many files; or nil + why.
-- dry: without the tracks' effects (their instruments still play), as a mixer wants them; put back after.
-- (0.58.98, James: "these buttons should bring up the render with preset settings so you can double check things", "industry standard
-- export settings", WAV: REAPER's Render window opens set up (extras.STANDARD: 24-bit WAV at the project's rate, stereo, no dither or
-- normalizing), you check it and press Render; your own render settings are back after it closes. Dry stems are only tracks with parts:
-- a bus or folder with its effects off passed its sources through again.)
extras.WAV24 = "ZXZhdxgAAQ==" -- (REAPER's WAV sink, 24-bit: the "Default" render preset on this rig)
function extras.STANDARD(proj)
  -- (no second format: one left on wrote an MP3 beside the WAV, and Final mix could pick either. Review, 0.58.98)
  return { RENDER_FORMAT = extras.WAV24, RENDER_FORMAT2 = "", RENDER_SRATE = band.srate(proj), RENDER_CHANNELS = 2, RENDER_DITHER = 0, RENDER_NORMALIZE = 0 }
end
-- (everything the Render window can change, so a preset picked there doesn't stay: review, 0.58.98)
extras.RENDER_KEYS_S = { "RENDER_FILE", "RENDER_PATTERN", "RENDER_FORMAT", "RENDER_FORMAT2" }
extras.RENDER_KEYS_N = { "RENDER_SETTINGS", "RENDER_BOUNDSFLAG", "RENDER_ADDTOPROJ", "RENDER_SRATE", "RENDER_CHANNELS", "RENDER_DITHER", "RENDER_NORMALIZE",
  "RENDER_BRICKWALL", "RENDER_TAILFLAG", "RENDER_TAILMS", "RENDER_STARTPOS", "RENDER_ENDPOS", "RENDER_FADEIN", "RENDER_FADEOUT", "RENDER_NORMALIZE_TARGET" }
function extras.save_render(proj)
  local saved = {}
  for _, k in ipairs(extras.RENDER_KEYS_S) do saved[k] = select(2, reaper.GetSetProjectInfo_String(proj, k, "", false)) end
  for _, k in ipairs(extras.RENDER_KEYS_N) do saved[k] = reaper.GetSetProjectInfo(proj, k, 0, false) end
  return saved
end
function extras.set_render(proj, t)
  for k, v in pairs(t) do
    if type(v) == "string" then reaper.GetSetProjectInfo_String(proj, k, v, true) else reaper.GetSetProjectInfo(proj, k, v, true) end
  end
end
-- REAPER's Render window, as set up: it's modal, so this returns once it's closed (rendered or cancelled).
function extras.render_window() reaper.Main_OnCommand(40015, 0) end -- File: Render project to disk...
function extras.stems(proj, cfg, b, dry)
  if reaper.GetPlayStateEx(proj) & 4 == 4 then return nil, "Stop recording first." end
  local mirror = require("mirror")
  local out = band.song_dir(cfg, b.song) .. "/stems/" .. os.date("%Y-%m-%d %H%M") .. " " .. band.clean(cfg.user) .. (dry and " dry" or "")
  reaper.RecursiveCreateDirectory(out, 0)
  local saved = extras.save_render(proj)
  local selected, n = {}, 0
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    selected[tr] = reaper.IsTrackSelected(tr)
    local share = not mirror.local_track(tr) and (not dry or reaper.CountTrackMediaItems(tr) > 0)
    reaper.SetTrackSelected(tr, share)
    if share then n = n + 1 end
  end
  if n == 0 then
    for tr, was in pairs(selected) do reaper.SetTrackSelected(tr, was) end
    return nil, "There are no shared tracks to render."
  end
  reaper.GetSetProjectInfo_String(proj, "RENDER_FILE", out, true)
  local bypassed = {} -- (dry: each shared track's effects off for the render; its instrument stays, so a MIDI part still sounds)
  if dry then
    for tr, _ in pairs(selected) do
      if not mirror.local_track(tr) then
        local inst = reaper.TrackFX_GetInstrument(tr)
        for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
          if i ~= inst and reaper.TrackFX_GetEnabled(tr, i) then reaper.TrackFX_SetEnabled(tr, i, false); bypassed[#bypassed + 1] = { tr, i } end
        end
      end
    end
  end
  reaper.GetSetProjectInfo_String(proj, "RENDER_PATTERN", dry and "$track (dry)" or "$track", true)
  reaper.GetSetProjectInfo(proj, "RENDER_SETTINGS", 3, true) -- stems of the selected tracks (3, not 2: 2 rendered the master. FINDINGS F-0036)
  reaper.GetSetProjectInfo(proj, "RENDER_BOUNDSFLAG", 1, true) -- the entire project: every stem starts at the song's start, so they line up
  reaper.GetSetProjectInfo(proj, "RENDER_ADDTOPROJ", 2, true) -- (&2: silent stems skipped)
  extras.set_render(proj, extras.STANDARD(proj))
  extras.render_window()
  for _, x in ipairs(bypassed) do if reaper.ValidatePtr2(proj, x[1], "MediaTrack*") then reaper.TrackFX_SetEnabled(x[1], x[2], true) end end
  for tr, was in pairs(selected) do if reaper.ValidatePtr2(proj, tr, "MediaTrack*") then reaper.SetTrackSelected(tr, was) end end
  for k, v in pairs(saved) do
    if type(v) == "string" then reaper.GetSetProjectInfo_String(proj, k, v, true) else reaper.GetSetProjectInfo(proj, k, v, true) end
  end
  -- (silent ones go: REAPER's "skip silent" only skips a track with no media at all, and an empty MIDI part made a silent file. Only files this
  -- render just made, in its own new folder)
  local made = 0
  for _, f in ipairs(band.files(out)) do
    local src = reaper.PCM_Source_CreateFromFile(out .. "/" .. f)
    -- (silent, REAPER answers "no change", 1.0, to both: to its peak at 0 dB, and to its loudness at -23 LUFS. A sound gives 1.0 to both
    -- only if it sits exactly at both, which doesn't happen. Measured, 0.58.52)
    local silent = src and reaper.CalculateNormalization(src, 2, 0, 0, 0) == 1 and reaper.CalculateNormalization(src, 0, -23, 0, 0) == 1
    if src then reaper.PCM_Source_Destroy(src) end
    if silent then os.remove(out .. "/" .. f) else made = made + 1 end
  end
  if made == 0 then -- (its own empty folder, not left in the shared folder: os.remove can't take a folder on Windows, so it stayed. Review, 0.58.62)
    if reaper.GetOS():match("^Win") then os.execute('rmdir "' .. out:gsub("/", "\\") .. '" 2>nul') else os.remove(out) end
  end
  if made == 0 then return nil, "No stems were made (the Render window was cancelled, its folder or names were changed, or every track was silent)." end
  return out, made
end

-- ---------------------------------------------------------------- A/B
-- Two renders from <Song>/mixes played in turn from the same place, each turned to the same loudness (-16 LUFS integrated), so the louder
-- one doesn't simply sound better. Needs SWS (its preview player).
local ab = { a = nil, b = nil, playing = nil, preview = nil, src = nil, gain = {} }
local function ab_stop()
  if ab.preview then reaper.CF_Preview_Stop(ab.preview) end
  if ab.src then reaper.PCM_Source_Destroy(ab.src) end
  ab.preview, ab.src, ab.playing = nil, nil, nil
end
local function ab_play(path, which)
  local pos = 0
  if ab.preview then pos = select(2, reaper.CF_Preview_GetValue(ab.preview, "D_POSITION")) or 0 end
  ab_stop()
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return band.log("couldn't read " .. path) end
  if not ab.gain[path] then -- (measured once per file: it reads the whole render)
    ab.gain[path] = reaper.CalculateNormalization(src, 0, -16, 0, 0)
  end
  ab.src, ab.preview, ab.playing = src, reaper.CF_CreatePreview(src), which
  reaper.CF_Preview_SetValue(ab.preview, "D_VOLUME", ab.gain[path] or 1)
  reaper.CF_Preview_SetValue(ab.preview, "D_POSITION", math.min(pos, reaper.GetMediaSourceLength(src) - 0.1))
  reaper.CF_Preview_Play(ab.preview)
end
function extras.ab_draw(ctx, ImGui, cfg, b)
  if not reaper.CF_CreatePreview then return ImGui.TextDisabled(ctx, "Comparing mixes needs SWS (Extensions > ReaPack, or sws-extension.org).") end
  local dir = band.song_dir(cfg, b.song) .. "/mixes"
  local files = band.files(dir)
  table.sort(files, function(x, y) return x > y end) -- (newest first: their names start with the date after the song's)
  if #files < 2 then return ImGui.TextDisabled(ctx, "Render the mix at least twice (Render current mix) to compare two.") end
  ab.a = ab.a or files[2]
  ab.b = ab.b or files[1]
  for _, side in ipairs({ "a", "b" }) do
    ImGui.SetNextItemWidth(ctx, -70)
    if ImGui.BeginCombo(ctx, side:upper() .. "##ab" .. side, ab[side]) then
      for _, f in ipairs(files) do if ImGui.Selectable(ctx, f, f == ab[side]) then ab[side] = f; if ab.playing == side then ab_stop() end end end
      ImGui.EndCombo(ctx)
    end
  end
  for _, side in ipairs({ "a", "b" }) do
    local on = ab.playing == side
    if ImGui.Button(ctx, (on and "Playing " or "Play ") .. side:upper() .. "##abplay") then ab_play(dir .. "/" .. ab[side], side) end
    ImGui.SetItemTooltip(ctx, "Switches to " .. side:upper() .. " from where you are, at the same loudness as the other.")
    ImGui.SameLine(ctx)
  end
  if ImGui.Button(ctx, "Stop##ab") then ab_stop() end
  if ab.preview then
    local pos = select(2, reaper.CF_Preview_GetValue(ab.preview, "D_POSITION")) or 0
    ImGui.SameLine(ctx)
    ImGui.TextDisabled(ctx, string.format("%d:%02d", math.floor(pos / 60), math.floor(pos % 60)))
  end
end
extras.ab_stop = ab_stop

-- ---------------------------------------------------------------- credits
-- Who did what on a song, from its history: tracks each started, takes each recorded, changes each made. A draft to agree the
-- splits on, written to <Song>/credits.txt for everyone; the percentages are left for the band to fill in. -> its path.
function extras.credits(cfg, b)
  local who, order = {}, {}
  local function person(u)
    u = tostring(u or "?")
    if not who[u] then who[u] = { tracks = 0, takes = 0, changes = 0 }; order[#order + 1] = u end
    return who[u]
  end
  local sdir = band.song_dir(cfg, b.song)
  for _, room in ipairs(band.subdirs(sdir .. "/rooms")) do
    local seen = {}
    local edir = sdir .. "/rooms/" .. room .. "/events"
    for _, f in ipairs(band.files(edir, ".json")) do
      local ev = band.read_json(edir .. "/" .. f)
      if type(ev) == "table" and ev.type == "obj" and ev.user and not ev.auto then
        local p = person(ev.user)
        p.changes = p.changes + 1
        if ev.obj == "track" and not seen[ev.oid] and not ev.base_ev and (ev.base or 0) == 0 then seen[ev.oid] = true; p.tracks = p.tracks + 1 end
      end
    end
    for _, f in ipairs(band.files(band.takes_dir(cfg, b.song, room), ".json")) do
      local m = band.read_json(band.takes_dir(cfg, b.song, room) .. "/" .. f)
      if type(m) == "table" and m.user then local p = person(m.user); p.takes = p.takes + 1 end
    end
  end
  table.sort(order)
  local lines = { "Credits draft: " .. b.song, "Made by StudioSync from the project's history on " .. os.date("%Y-%m-%d") .. ".",
    "It counts what each person did; it doesn't decide who wrote what. Agree the splits together, fill them in, and keep a signed copy.", "",
    string.format("%-24s %8s %8s %9s   %-20s %-10s %-10s", "Name", "Tracks", "Takes", "Changes", "Role", "Writing %", "Master %") }
  for _, u in ipairs(order) do
    local p = who[u]
    lines[#lines + 1] = string.format("%-24s %8d %8d %9d   %-20s %-10s %-10s", u, p.tracks, p.takes, p.changes, "________", "____", "____")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Signed: " .. string.rep("_", 40)
  local path = sdir .. "/credits.txt"
  band.write_atomic(path, table.concat(lines, "\n") .. "\n")
  return path
end

-- ---------------------------------------------------------------- stage
-- Where a project is: in its chat folder, which every computer in the studio has even for projects not downloaded in full.
extras.STAGES = { "Idea", "Writing", "Tracking", "Mixing", "Done" }
local stage_cache = {}
function extras.stage(root, song)
  local key = root .. "\0" .. song
  local c = stage_cache[key]
  if c and reaper.time_precise() - c.at < 5 then return c.stage end
  local s = band.read_json(root .. "/" .. song .. "/chat/stage.json")
  local v = type(s) == "table" and type(s.stage) == "string" and s.stage or nil
  stage_cache[key] = { at = reaper.time_precise(), stage = v }
  return v
end
function extras.set_stage(root, song, stage, user)
  reaper.RecursiveCreateDirectory(root .. "/" .. song .. "/chat", 0)
  band.write_json(root .. "/" .. song .. "/chat/stage.json", { stage = stage, by = user, time = os.date("!%Y-%m-%dT%H:%M:%SZ") })
  stage_cache[root .. "\0" .. song] = nil
end

-- ---------------------------------------------------------------- while you were away
-- What the others did in this room since you last had it open: changes and takes by each, new messages and notes. Counted once
-- per opening; the moment you were last here moves on when you dismiss it. Pure but for reading the folders it's given.
function extras.away_counts(events, takes, msgs, since, me)
  local by, order, new_msgs, new_notes = {}, {}, 0, 0
  local function p(u) if not by[u] then by[u] = { changes = 0, takes = 0 }; order[#order + 1] = u end return by[u] end
  for _, ev in ipairs(events) do
    if ev.type == "obj" and ev.user and ev.user ~= me and not ev.auto and (ev.time or "") > since then p(ev.user).changes = p(ev.user).changes + 1 end
    if ev.type == "note" and ev.user ~= me and (ev.time or "") > since then new_notes = new_notes + 1 end
  end
  for _, m in ipairs(takes) do if m.user and m.user ~= me and (m.sent or "") > since then p(m.user).takes = p(m.user).takes + 1 end end
  for _, m in ipairs(msgs) do if m.user ~= me and (m.time or "") > since then new_msgs = new_msgs + 1 end end
  table.sort(order)
  local parts = {}
  for _, u in ipairs(order) do
    local x, bits = by[u], {}
    if x.changes > 0 then bits[#bits + 1] = x.changes .. (x.changes == 1 and " change" or " changes") end
    if x.takes > 0 then bits[#bits + 1] = x.takes .. (x.takes == 1 and " take" or " takes") end
    parts[#parts + 1] = u .. ": " .. table.concat(bits, ", ")
  end
  if new_msgs > 0 then parts[#parts + 1] = new_msgs .. (new_msgs == 1 and " new message" or " new messages") end
  if new_notes > 0 then parts[#parts + 1] = new_notes .. (new_notes == 1 and " new note" or " new notes") end
  return parts
end
local away = {}
function extras.away(cfg, b)
  local key = b.song .. "/" .. b.room
  if away[key] then return away[key] end
  local since = reaper.GetExtState(band.SECTION, "last here " .. key)
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  if since == "" then reaper.SetExtState(band.SECTION, "last here " .. key, now, true); away[key] = {}; return away[key] end
  -- (changes only from files named since then: they carry their UTC stamp, so a week's history isn't read and decoded to count today's.
  -- Review, 0.58.91)
  local after = since:gsub("[-:]", ""):gsub("T", "-"):gsub("Z$", "")
  local function read_all(dir, by_name)
    local t = {}
    for _, f in ipairs(band.files(dir, ".json")) do
      local stamp = by_name and f:match("%-(%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d)Z%-")
      if not stamp or stamp >= after then local v = band.read_json(dir .. "/" .. f); if type(v) == "table" then t[#t + 1] = v end end
    end
    return t
  end
  local rdir = band.song_dir(cfg, b.song) .. "/rooms/" .. b.room
  local takes = {}
  for _, m in ipairs(read_all(band.takes_dir(cfg, b.song, b.room))) do takes[#takes + 1] = { user = m.user, sent = (m.origin and m.origin.sent) or m.sent } end
  local chat = band.song_dir(cfg, b.song) .. "/chat"
  local parts = extras.away_counts(read_all(rdir .. "/events", true), takes, read_all(chat .. "/msgs"), since, cfg.user)
  away[key] = { parts = parts, since = since, now = now }
  return away[key]
end
function extras.away_seen(b)
  local a = away[b.song .. "/" .. b.room]
  if a and a.now then reaper.SetExtState(band.SECTION, "last here " .. b.song .. "/" .. b.room, a.now, true) end
  away[b.song .. "/" .. b.room] = {}
end

-- ---------------------------------------------------------------- a guest's full-quality file
-- What came over SonoBus is compressed and late; the guest's own recording (SonoBus can record on their side, or any recorder) is the
-- real thing. Picked, it's added to the selected item as a new take, lined up with what's there by cross-correlation: first of the two
-- loudness envelopes (10 ms steps, up to 3 s either way), then of the sound itself at 8 kHz around that (to a sample at that rate).
-- Envelope, then fine: the whole search on raw samples would take minutes in Lua. -> seconds the file was moved by, or nil + why.
local function samples(take, from, secs, rate)
  local acc = reaper.CreateTakeAudioAccessor(take)
  local n = math.floor(secs * rate)
  local buf = reaper.new_array(n)
  buf.clear() -- (a new array isn't zeroed, and nothing is written past the take's end: leftover memory read as sound. Linux test, 0.58.78)
  reaper.GetAudioAccessorSamples(acc, rate, 1, from, n, buf)
  reaper.DestroyAudioAccessor(acc)
  return buf.table()
end
local function envelope(s, step)
  local e = {}
  for i = 1, #s - step + 1, step do
    local sum = 0
    for j = i, i + step - 1 do sum = sum + s[j] * s[j] end
    e[#e + 1] = math.sqrt(sum / step)
  end
  return e
end
-- The shift of b against a (in steps) where they match best, within `range` steps either way. Pure.
function extras.best_lag(a, b, range, from, to)
  local best, best_lag = -math.huge, 0
  from, to = from or -range, to or range
  for lag = from, to do
    local sum, n = 0, 0
    for i = 1, #a do
      local j = i + lag
      if j >= 1 and j <= #b then sum = sum + a[i] * b[j]; n = n + 1 end
    end
    local score = n > 0 and sum / n or -math.huge
    if score > best then best, best_lag = score, lag end
  end
  return best_lag
end
function extras.swap_in_file(item, path)
  local stream = reaper.GetActiveTake(item)
  if not stream or reaper.TakeIsMIDI(stream) then return nil, "Select the guest's recorded item (audio) first." end
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return nil, "Couldn't read that file." end
  local take = reaper.AddTakeToMediaItem(item)
  band.set_take_source(take, src)
  reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "full quality: " .. path:match("[^/\\]+$"), true)
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local len = math.min(item_len, 30)
  -- (a take is only read within its item: the search reads 6 s past it, so the item is that long while it reads, and back after)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", len + 6)
  -- envelopes at 100 per second: the stream's first `len` s, the file's from 3 s before to 3 s after
  local rate = 8000
  local a = envelope(samples(stream, 0, len, rate), 80)
  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", -3) -- (to read the file from 3 s "before" the item: silence where there's none)
  local b = envelope(samples(take, 0, len + 6, rate), 80)
  local coarse = extras.best_lag(a, b, 300, 0, 600) - 300 -- (b starts 3 s early: lag 300 there is no shift)
  -- fine, at 8 kHz, within 20 ms of it, over the item's loudest second (the opening may be silence)
  local loud, at = -1, 0
  for i = 1, #a - 100 do if a[i] > loud then loud, at = a[i], (i - 1) / 100 end end
  local start = math.max(0, math.min(at, len - 2))
  local fa = samples(stream, start, 2, rate)
  local off = coarse / 100 -- (the file's time at the item's start: both read through takes, so in the item's own time)
  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", off - 0.02)
  local fb = samples(take, start, 2.04, rate)
  off = off - 0.02 + extras.best_lag(fa, fb, 160, 0, 320) / rate
  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", off)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", item_len)
  reaper.SetActiveTake(take)
  reaper.UpdateItemInProject(item)
  return off
end

-- ---------------------------------------------------------------- stems in from anywhere
-- A bandmate on other software (or anyone without REAPER at hand) drops an audio file into <Song>/inbox/ in the shared folder: whoever
-- drives (or is alone) puts it in the song as an item on a track named for it, "<name> (stem)", and it goes to everyone like any change.
-- Where: "bar 17" in the name (from the start of bar 17), or "@1:23" (minutes:seconds), else the song's start. The file leaves the inbox.
-- (research of other tools, 0.58.53: the bassist on Logic couldn't join; Export stems went out and nothing came back)
extras.INBOX_EXT = { wav = true, flac = true, aif = true, aiff = true, mp3 = true, ogg = true }
-- "Bass @ bar 17.wav" -> "Bass", 17, nil; "Keys @1:23.flac" -> "Keys", nil, 83; "Pad.wav" -> "Pad". Pure.
function extras.inbox_name(file)
  local stem = file:gsub("%.[^.]+$", "")
  local bar = stem:lower():match("bar%s*(%d+)")
  local m, s = stem:match("@%s*(%d+):(%d%d)")
  local name = stem:gsub("[Bb][Aa][Rr]%s*%d+", ""):gsub("@%s*%d+:%d%d", ""):gsub("@", ""):gsub("^[%s%-_]+", ""):gsub("[%s%-_]+$", "")
  return name ~= "" and name or "Stem", bar and tonumber(bar), m and (tonumber(m) * 60 + tonumber(s))
end
local inbox_sizes = {} -- path -> size at the last look: a file still growing waits
local inbox_bad = {} -- path -> the size it had when REAPER couldn't read it: left alone until it changes
-- -> what was put in, as { "Bass (stem) at bar 17", ... }
function extras.inbox(proj, cfg, b)
  local dir = band.song_dir(cfg, b.song) .. "/inbox"
  local out = {}
  for _, f in ipairs(band.files(dir)) do
    local path = dir .. "/" .. f
    local size = band.size(path)
    local kind = (f:match("%.([^.]+)$") or ""):lower()
    local ready = extras.INBOX_EXT[kind] and not f:find("^%.") and size and size > 0 and inbox_sizes[path] == size and inbox_bad[path] ~= size
    inbox_sizes[path] = size
    if ready then
      local name, bar, secs = extras.inbox_name(f)
      local media = reaper.GetProjectPathEx(proj, ""):gsub("\\", "/")
      reaper.RecursiveCreateDirectory(media, 0)
      local dest = media .. "/" .. band.clean(name) .. " (inbox " .. os.date("%Y%m%d-%H%M%S") .. ")." .. kind
      local ok = pcall(band.copy_atomic, path, dest)
      local src = ok and reaper.PCM_Source_CreateFromFile(dest)
      if src then
        reaper.Undo_BeginBlock2(proj)
        local tname, tr = name .. " (stem)", nil
        for i = 0, reaper.CountTracks(proj) - 1 do
          local t = reaper.GetTrack(proj, i)
          if select(2, reaper.GetSetMediaTrackInfo_String(t, "P_NAME", "", false)) == tname then tr = t; break end
        end
        if not tr then
          reaper.InsertTrackInProject(proj, reaper.CountTracks(proj), 0)
          tr = reaper.GetTrack(proj, reaper.CountTracks(proj) - 1)
          reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", tname, true)
        end
        local pos = bar and reaper.TimeMap2_beatsToTime(proj, 0, bar - 1) or secs or 0
        local it = reaper.AddMediaItemToTrack(tr)
        local tk = reaper.AddTakeToMediaItem(it)
        band.set_take_source(tk, src)
        reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", name, true)
        reaper.SetMediaItemInfo_Value(it, "D_POSITION", pos)
        reaper.SetMediaItemInfo_Value(it, "D_LENGTH", (reaper.GetMediaSourceLength(src)))
        reaper.UpdateItemInProject(it)
        reaper.Undo_EndBlock2(proj, "StudioSync: " .. f .. " from the inbox", -1)
        os.remove(path)
        inbox_sizes[path] = nil
        out[#out + 1] = string.format("%s at %s", tname, bar and ("bar " .. bar) or string.format("%d:%02d", math.floor(pos / 60), math.floor(pos % 60)))
      else
        -- (a file REAPER can't read: copied again every 10 s, a new copy each time, until the disk filled. Review, 0.58.62. Left in the inbox, said once)
        if ok then os.remove(dest) end
        inbox_bad[path] = size -- (not tried again until the file changes, and its size with it)
        band.log("the song's inbox has " .. f .. ", which " .. (ok and "REAPER can't read as audio" or "couldn't be copied") .. ": left in the inbox")
      end
    end
  end
  if #out > 0 then reaper.UpdateArrange() end
  return out
end

-- ---------------------------------------------------------------- studio templates
-- Each studio keeps its own, in <studio>/_band/templates/<name>.rpp (everyone in the studio has them): the tracks, their routing, plug-ins,
-- colours, the tempo and markers of a song, without its items and without StudioSync's own marks, so a song started from one is a new song.
-- (research of other tools, 0.58.53: every new song made the same tracks and colours again)
function extras.template_dir(cfg) return cfg.root .. "/_band/templates" end
-- A saved project's text made into a template: no items, no StudioSync ids or project state, and none of the tracks that are this computer's
-- own (Real time mode's, talkback, your local tracks: band_local). Pure.
function extras.template_text(rpp)
  local lines = {}
  for line in (rpp .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
  local function block_end(i) -- the line closing the block opened at i
    local indent = #lines[i]:match("^%s*")
    for k = i + 1, #lines do if #lines[k]:match("^%s*") == indent and lines[k]:match("^%s*>%s*$") then return k end end
    return #lines
  end
  local function opens(line, tag) return line:match("^%s*<" .. tag .. "$") or line:match("^%s*<" .. tag .. "%s") end
  local out, i = {}, 1
  while i <= #lines do
    local line = lines[i]
    if opens(line, "ITEM") or opens(line, "EXTSTATE") then
      i = block_end(i) + 1
    elseif opens(line, "TRACK") and (function()
        local z = block_end(i)
        local own = #line:match("^%s*") + 4 -- (the track's own <EXT>, not an item's inside it)
        for k = i + 1, z do if #lines[k]:match("^%s*") == own and lines[k]:match("^%s*band_local%s") then return true end end
      end)() then
      i = block_end(i) + 1
    else
      if not line:match("^%s*band_") then out[#out + 1] = line end
      i = i + 1
    end
  end
  while out[#out] == "" do out[#out] = nil end
  return table.concat(out, "\n") .. "\n"
end
-- -> its path, or nil + why
function extras.save_template(proj, cfg, name)
  name = band.clean(name or "")
  if name == "" then return nil, "Give the template a name." end
  local dir = extras.template_dir(cfg)
  reaper.RecursiveCreateDirectory(dir, 0)
  local tmp = band.home() .. "/template-scratch.rpp"
  local _ = band.save_copy and band.save_copy(proj, tmp) or reaper.Main_SaveProjectEx(proj, tmp, 0) -- (a copy: the project stays where it is)
  local text = band.read(tmp)
  os.remove(tmp); os.remove(tmp .. ".bandsync-ids.json")
  if not text then return nil, "Couldn't save a copy of the project." end
  local path = dir .. "/" .. name .. ".rpp"
  band.write_atomic(path, extras.template_text(text))
  return path
end
function extras.templates(cfg)
  local t = {}
  for _, f in ipairs(band.files(extras.template_dir(cfg), ".rpp")) do t[#t + 1] = f:gsub("%.[Rr][Pp][Pp]$", "") end
  table.sort(t)
  return t
end
-- A new tab started from one, untitled: share it as usual (Share ... with the studio).
function extras.open_template(cfg, name)
  local path = extras.template_dir(cfg) .. "/" .. name .. ".rpp"
  if not reaper.file_exists(path) then return false end
  reaper.Main_OnCommand(40859, 0) -- new project tab
  reaper.Main_openProject("noprompt:template:" .. path) -- (that order: as the installed scripts use it)
  return true
end

return extras
