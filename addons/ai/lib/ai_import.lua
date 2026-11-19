-- StudioSync AI: a helper result into the project. plan() is pure (result.json -> a list of steps, checked), apply() carries the steps
-- out as one undo point. The helper's output is checked here like anything from outside: file names must be plain names inside the run
-- folder, times numbers.
--   stems, master -> a new track each, with the file as an item from where the input started
--   sections      -> regions (and, only when asked, a tempo marker at each downbeat)
--   transcribe    -> the project notes (and regions named for each line, when asked)
--   midi          -> a new track each, with the MIDI file as an item
--   chords        -> markers named for each chord; the key into the project notes
local imp = {}

local function plain(f) return type(f) == "string" and f ~= "" and not f:find("[/\\:]") and not f:find("^%.") end
local function num(x)
  x = tonumber(x)
  return (x and x == x and x >= 0 and x < 1e7) and x or nil -- (not NaN, not negative, not absurd)
end
local function clock(s) return string.format("%d:%02d", math.floor(s / 60), math.floor(s % 60)) end
local function name_of(s, fallback)
  s = type(s) == "string" and s:gsub("[%c|]", " "):sub(1, 120) or ""
  return s ~= "" and s or fallback
end

-- res: the decoded result.json; start: where the input began in the project (s); opts: { tempo = true (write the tempo map),
-- regions = true (transcript lines as regions) }. -> steps, or nil + why.
function imp.plan(res, start, opts)
  opts, start = opts or {}, num(start) or 0
  if type(res) ~= "table" then return nil, "the helper's result couldn't be read" end
  if res.status ~= "ok" then return nil, tostring(res.message ~= "" and res.message or res.status) end
  local d, job, steps = type(res.data) == "table" and res.data or {}, res.job, {}
  local function files(list, op, suffix)
    for _, s in ipairs(type(list) == "table" and list or {}) do
      if type(s) == "table" and plain(s.file) then
        steps[#steps + 1] = { op = op, name = name_of(s.name, s.file) .. suffix, file = s.file, pos = start }
      end
    end
  end
  local function spans(list, fn)
    for _, s in ipairs(type(list) == "table" and list or {}) do
      local a, b = type(s) == "table" and num(s.start), type(s) == "table" and num(s["end"])
      if a and b and b >= a then fn(s, start + a, start + b) end
    end
  end
  if job == "stems" or job == "master" then
    files(d.stems, "track", " (AI)")
  elseif job == "midi" then
    files(d.midi, "midi", " (AI MIDI)")
  elseif job == "sections" then
    spans(d.segments, function(s, a, b) steps[#steps + 1] = { op = "region", pos = a, stop = b, name = name_of(s.label, "section") } end)
    if opts.tempo then
      local downs, bpb, bpm = {}, num(d.beats_per_bar) or 4, num(d.bpm)
      for _, t in ipairs(type(d.downbeats) == "table" and d.downbeats or {}) do downs[#downs + 1] = num(t) end
      for i = 1, #downs - 1 do -- (each bar's own tempo, from the gap to the next downbeat)
        local gap = downs[i + 1] - downs[i]
        if gap > 0 then steps[#steps + 1] = { op = "tempo", pos = start + downs[i], bpm = 60 * bpb / gap } end
      end
      if #downs < 2 and bpm and bpm > 0 then steps[#steps + 1] = { op = "tempo", pos = start + (downs[1] or 0), bpm = bpm } end
    end
  elseif job == "transcribe" then
    local lines = {}
    spans(d.segments, function(s, a, b)
      local who, text = name_of(s.speaker, ""), name_of(s.text, "")
      lines[#lines + 1] = "[" .. clock(a) .. "] " .. (who ~= "" and (who .. ": ") or "") .. text
      if opts.regions then steps[#steps + 1] = { op = "region", pos = a, stop = b, name = (who ~= "" and (who .. ": ") or "") .. text } end
    end)
    if #lines > 0 then table.insert(steps, 1, { op = "notes", text = "Transcript (StudioSync AI, " .. os.date("%Y-%m-%d %H:%M") .. ")\n" .. table.concat(lines, "\n") }) end
  elseif job == "chords" then
    if type(d.key) == "string" and d.key ~= "" then steps[#steps + 1] = { op = "notes", text = "Key (StudioSync AI): " .. name_of(d.key, "") } end
    spans(d.chords, function(s, a) steps[#steps + 1] = { op = "marker", pos = a, name = name_of(s.label, "?") } end)
  else
    return nil, "nothing to put in the project from a " .. tostring(job) .. " result"
  end
  if #steps == 0 then return nil, "the result had nothing to put in the project" end
  return steps
end

-- One line for the log and the message box: what a plan would do.
function imp.describe(steps)
  local n = {}
  for _, s in ipairs(steps) do n[s.op] = (n[s.op] or 0) + 1 end
  local words = { track = "new track", midi = "MIDI track", region = "region", marker = "marker", tempo = "tempo marker", notes = "project note" }
  local out = {}
  for _, op in ipairs({ "track", "midi", "region", "marker", "tempo", "notes" }) do
    if n[op] then out[#out + 1] = n[op] .. " " .. words[op] .. (n[op] > 1 and "s" or "") end
  end
  return table.concat(out, ", ")
end

-- Carry the steps out in `proj`, as one undo point. Files are copied from the run folder `dir` into the project's media folder first
-- (they go with the project, and to the band like any media). -> how many steps were done.
function imp.apply(proj, steps, dir, title)
  local band = require("band")
  local media = reaper.GetProjectPathEx(proj, ""):gsub("\\", "/")
  reaper.RecursiveCreateDirectory(media, 0)
  local done = 0
  reaper.Undo_BeginBlock2(proj)
  reaper.PreventUIRefresh(1)
  for _, s in ipairs(steps) do
    if s.op == "track" or s.op == "midi" then
      local ext = s.file:match("%.([^.]+)$") or "wav"
      local dest = media .. "/" .. band.clean(s.name) .. " " .. os.date("%Y%m%d-%H%M%S") .. "." .. ext
      local src = pcall(band.copy_atomic, dir .. "/" .. s.file, dest) and reaper.PCM_Source_CreateFromFile(dest)
      if src then
        local idx = reaper.CountTracks(proj)
        reaper.InsertTrackInProject(proj, idx, 0)
        local tr = reaper.GetTrack(proj, idx)
        reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", s.name, true)
        local it = reaper.AddMediaItemToTrack(tr)
        local tk = reaper.AddTakeToMediaItem(it)
        band.set_take_source(tk, src)
        reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", s.name, true)
        reaper.SetMediaItemInfo_Value(it, "D_POSITION", s.pos)
        reaper.SetMediaItemInfo_Value(it, "D_LENGTH", (reaper.GetMediaSourceLength(src)))
        reaper.UpdateItemInProject(it)
        done = done + 1
      else
        band.log("StudioSync AI couldn't put " .. s.file .. " in the project (REAPER can't read it, or it couldn't be copied)")
      end
    elseif s.op == "region" or s.op == "marker" then
      reaper.AddProjectMarker2(proj, s.op == "region", s.pos, s.stop or 0, s.name, -1, 0)
      done = done + 1
    elseif s.op == "tempo" then
      reaper.SetTempoTimeSigMarker(proj, -1, s.pos, -1, -1, s.bpm, 0, 0, false)
      done = done + 1
    elseif s.op == "notes" then -- (added under what's there; project notes aren't part of REAPER's undo)
      local old = reaper.GetSetProjectNotes(proj, false, "")
      reaper.GetSetProjectNotes(proj, true, (old ~= "" and (old .. "\n\n") or "") .. s.text)
      done = done + 1
    end
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.UpdateTimeline()
  reaper.Undo_EndBlock2(proj, "StudioSync AI: " .. title, -1)
  return done
end

return imp
