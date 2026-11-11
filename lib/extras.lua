-- The extras a band asks for around the work itself (research of other tools and what their users ask for, 0.58.47): stems for
-- whoever mixes, two mixes compared at matched loudness, a credits draft, a stage for each project, and what happened while you were
-- away. And a guest's own full-quality recording swapped in for what came over SonoBus, lined up by ear (cross-correlation).
local band = require("band")
local extras = {}

-- ---------------------------------------------------------------- stems
-- Every track the band shares, one file each, the whole song, into <Song>/stems/<date>/ (in the shared folder, for everyone), named for
-- its track. As your master hears it (each machine's master is its own), StudioSync's own and your local tracks left out, silent ones
-- skipped. Your render settings and selection are put back. -> the folder, and how many files; or nil + why.
function extras.stems(proj, cfg, b)
  if reaper.GetPlayStateEx(proj) & 4 == 4 then return nil, "Stop recording first." end
  local mirror = require("mirror")
  local out = band.song_dir(cfg, b.song) .. "/stems/" .. os.date("%Y-%m-%d %H%M") .. " " .. band.clean(cfg.user)
  reaper.RecursiveCreateDirectory(out, 0)
  local saved = {}
  for _, k in ipairs({ "RENDER_FILE", "RENDER_PATTERN" }) do saved[k] = select(2, reaper.GetSetProjectInfo_String(proj, k, "", false)) end
  for _, k in ipairs({ "RENDER_SETTINGS", "RENDER_BOUNDSFLAG", "RENDER_ADDTOPROJ" }) do saved[k] = reaper.GetSetProjectInfo(proj, k, 0, false) end
  local selected, n = {}, 0
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    selected[tr] = reaper.IsTrackSelected(tr)
    local share = not mirror.local_track(tr)
    reaper.SetTrackSelected(tr, share)
    if share then n = n + 1 end
  end
  if n == 0 then
    for tr, was in pairs(selected) do reaper.SetTrackSelected(tr, was) end
    return nil, "There are no shared tracks to render."
  end
  reaper.GetSetProjectInfo_String(proj, "RENDER_FILE", out, true)
  reaper.GetSetProjectInfo_String(proj, "RENDER_PATTERN", "$track", true)
  reaper.GetSetProjectInfo(proj, "RENDER_SETTINGS", 3, true) -- stems of the selected tracks (3, not 2: 2 rendered the master. FINDINGS F-0036)
  reaper.GetSetProjectInfo(proj, "RENDER_BOUNDSFLAG", 1, true) -- the entire project: every stem starts at the song's start, so they line up
  reaper.GetSetProjectInfo(proj, "RENDER_ADDTOPROJ", 2, true) -- (&2: silent stems skipped)
  reaper.Main_OnCommand(42230, 0) -- File: Render project, using the most recent render settings, auto-close render dialog
  for tr, was in pairs(selected) do if reaper.ValidatePtr2(proj, tr, "MediaTrack*") then reaper.SetTrackSelected(tr, was) end end
  for k, v in pairs(saved) do
    if type(v) == "string" then reaper.GetSetProjectInfo_String(proj, k, v, true) else reaper.GetSetProjectInfo(proj, k, v, true) end
  end
  local made = #band.files(out)
  if made == 0 then return nil, "The render made nothing (cancelled, or File > Render's format couldn't write)." end
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
  local function read_all(dir)
    local t = {}
    for _, f in ipairs(band.files(dir, ".json")) do local v = band.read_json(dir .. "/" .. f); if type(v) == "table" then t[#t + 1] = v end end
    return t
  end
  local rdir = band.song_dir(cfg, b.song) .. "/rooms/" .. b.room
  local takes = {}
  for _, m in ipairs(read_all(band.takes_dir(cfg, b.song, b.room))) do takes[#takes + 1] = { user = m.user, sent = (m.origin and m.origin.sent) or m.sent } end
  local chat = band.song_dir(cfg, b.song) .. "/chat"
  local parts = extras.away_counts(read_all(rdir .. "/events"), takes, read_all(chat .. "/msgs"), since, cfg.user)
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
  reaper.SetMediaItemTake_Source(take, src)
  reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "full quality: " .. path:match("[^/\\]+$"), true)
  local len = math.min(reaper.GetMediaItemInfo_Value(item, "D_LENGTH"), 30)
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
  reaper.SetActiveTake(take)
  reaper.UpdateItemInProject(item)
  return off
end

return extras
