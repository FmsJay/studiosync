-- @description StudioSync AI (optional add-on): mix feedback, and AI tools that ask before they run
-- A menu at the mouse. Mix feedback measures the mix with REAPER alone and gives notes by fixed rules: nothing leaves this computer and no
-- model runs. Asking an AI about those numbers (your AI hub, or Claude) and the model tools (stems, sections and tempo, transcription,
-- MIDI, chords, mastering) run in StudioSync AI's helper, a Python program of its own, and each run asks first: which model, where it
-- runs (this computer's GPU or CPU, or the cloud), roughly how long and how much graphics memory, and any download. Results come in as
-- tracks, regions, markers, tempo markers or project notes, one undo step each. See addons/ai/README.md.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
local core = dir .. "/../../lib"
if not reaper.file_exists(core .. "/band.lua") then
  return reaper.MB("StudioSync AI is an add-on to StudioSync: keep its folder at <StudioSync>/addons/ai, next to StudioSync's lib folder.", "StudioSync AI", 0)
end
package.path = dir .. "/lib/?.lua;" .. core .. "/?.lua;" .. package.path
local band = require("band")
band.WHO = "ai"
local jobs, mix, imp, run = require("ai_jobs"), require("ai_mix"), require("ai_import"), require("ai_run")
local proj = reaper.EnumProjects(-1)

local function say(t) reaper.MB(t, "StudioSync AI", 0) end
local function ask(t) return reaper.MB(t, "StudioSync AI", 4) == 6 end -- (4: Yes/No; 6: Yes)
local function dry() return run.get("dry_run") == "1" end
local function tidy(d) -- (renders are big: the run folder keeps only its JSON and notes once they're used)
  for _, f in ipairs(band.files(d)) do
    if f:lower():match("%.wav$") or f:lower():match("%.mid$") then os.remove(d .. "/" .. f) end
  end
end

-- The helper's Python folder, made once with your OK, then go().
local function with_helper(go)
  if run.venv_python() then return go() end
  local py = run.find_python()
  if not py then
    return say("StudioSync AI's tools need Python 3.11 or newer on this computer (python.org), or its path in StudioSync AI > Settings.")
  end
  if not ask("StudioSync AI runs its tools in a Python folder of its own:\n" .. run.venv_dir() .. "\n\nMake it now with " .. py ..
      "? Only Python's own files are copied there: nothing is downloaded, and no model is installed.") then return end
  run.make_venv(py)
  local t0 = reaper.time_precise()
  -- shortcut: ready once its python is there; pip lands a moment later, and only an install (minutes later, after its own OK) needs it
  local function tick()
    if run.venv_python() then band.log("StudioSync AI's Python folder is ready: " .. run.venv_dir()); return go() end
    if reaper.time_precise() - t0 > 180 then return say("The Python folder wasn't made within 3 minutes. Make it by hand: " .. py .. " -m venv \"" .. run.venv_dir() .. "\"") end
    reaper.defer(tick)
  end
  reaper.defer(tick)
end

-- ---------------------------------------------------------------- asking an AI about the numbers
local function ask_ai(stats)
  local ep = run.get("endpoint")
  local model = ep == "claude" and run.get("claude_model") or run.get("hub_model")
  with_helper(function()
    local r = run.new("feedback")
    band.write_json(r.dir .. "/stats.json", stats)
    run.consent(r, jobs.feedback_where(ep), false)
    run.start(r, r.dir .. "/stats.json", { endpoint = ep, hub_url = run.get("hub_url"), model = model, key_file = run.key_file() },
      { timeout = jobs.FEEDBACK.timeout })
    run.wait(r, function(res)
      if res.status == "ok" then
        band.log("StudioSync AI: " .. model .. " answered about the mix (" .. r.dir .. "/feedback.md)")
        say("Notes from " .. model .. (dry() and " (dry run)" or "") .. ":\n\n" .. tostring(res.data and res.data.reply))
      else
        band.log("StudioSync AI: asking " .. model .. " didn't work: " .. tostring(res.message))
        say("Asking " .. model .. " didn't work: " .. tostring(res.message))
      end
    end)
  end)
end

-- ---------------------------------------------------------------- mix feedback (no AI)
local function mix_feedback()
  if reaper.GetPlayStateEx(proj) & 4 == 4 then return say("Stop recording first.") end
  local r = run.new("mixstats")
  local start, stop = run.range(proj)
  local made = run.render(proj, r.dir, "mix", start, stop)
  if not made["master.wav"] then return say("The mix didn't render (cancelled, or nothing to render).") end
  local set, n = run.shared_tracks(proj)
  local queue = {}
  for f, tr in pairs(n > 0 and run.render(proj, r.dir, set, start, stop) or {}) do queue[#queue + 1] = { f = f, tr = tr } end
  local function idx(tr) return reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER") end
  table.sort(queue, function(a, b) return idx(a.tr) < idx(b.tr) end)
  local stats = { project = reaper.GetProjectName(proj), range = stop > start and string.format("%.1f-%.1f s", start, stop) or "the whole song",
    master = run.measure(r.dir .. "/master.wav", "Master"), tracks = {}, thresholds = mix.T }
  if not stats.master then tidy(r.dir); return say("The mix is silent: nothing to measure.") end
  local i = 0
  local function step() -- (a file per pass, so REAPER isn't held for the whole lot)
    i = i + 1
    local q = queue[i]
    if q then
      local row = reaper.ValidatePtr2(proj, q.tr, "MediaTrack*") and run.measure(r.dir .. "/" .. q.f, select(2, reaper.GetTrackName(q.tr)))
      if row then stats.tracks[#stats.tracks + 1] = row end
      return reaper.defer(step)
    end
    tidy(r.dir)
    stats.rule_notes = mix.notes(stats)
    band.write_json(r.dir .. "/stats.json", stats)
    local text = "Mix feedback for " .. stats.range .. " (by fixed rules; nothing left this computer):\n\n" .. mix.notes_text(stats)
    band.write_atomic(r.dir .. "/feedback.md", text .. "\n")
    band.log("StudioSync AI mix feedback: " .. #stats.rule_notes .. " notes, in " .. r.dir .. "/feedback.md")
    local ep = run.get("endpoint")
    if ep ~= "hub" and ep ~= "claude" then
      return say(text .. "\n\n(To ask an AI about these numbers too: StudioSync AI > Settings.)")
    end
    if ep == "claude" and not run.has_key() then return say(text .. "\n\n(Claude is set, but there's no API key: StudioSync AI > Settings.)") end
    local o = { endpoint = ep, model = ep == "claude" and run.get("claude_model") or run.get("hub_model"), hub_url = run.get("hub_url") }
    if ask(text .. "\n\n" .. string.rep("-", 40) .. "\n" .. jobs.consent_text(jobs.FEEDBACK, o)) then ask_ai(stats) end
  end
  reaper.defer(step)
end

-- ---------------------------------------------------------------- the model tools
local function bring_in(r, job, res, start)
  if res.status == "missing" then
    return say(job.label .. " needs " .. table.concat(res.packages or {}, ", ") .. " first: run it again and say yes to the install.")
  end
  if res.status ~= "ok" then
    band.log("StudioSync AI: " .. job.label .. " didn't finish: " .. tostring(res.message))
    return say(job.label .. " didn't finish: " .. tostring(res.message))
  end
  local opts, d = {}, type(res.data) == "table" and res.data or {}
  if job.id == "sections" and (d.bpm or d.downbeats) then
    opts.tempo = ask("It found a tempo of about " .. string.format("%.1f", tonumber(d.bpm) or 0) .. " BPM. Write a tempo map from its downbeats too?\n\n" ..
      "That changes the project's tempo (in a studio, for everyone), and these tools sometimes hear half or double the real tempo. No: regions only.")
  elseif job.id == "transcribe" then
    opts.regions = ask("The transcript goes into the project notes. Put each line in as a region too?")
  end
  local steps, why = imp.plan(res, start, opts)
  if not steps then return say(job.label .. ": " .. tostring(why)) end
  imp.apply(proj, steps, r.dir, job.label)
  tidy(r.dir)
  tidy(r.dir .. "/in")
  band.log("StudioSync AI: " .. job.label .. (dry() and " (dry run)" or "") .. ": " .. imp.describe(steps))
  say(job.label .. " is in: " .. imp.describe(steps) .. ". One undo takes it all back.")
end

local function model_job(job)
  if reaper.GetPlayStateEx(proj) & 4 == 4 then return say("Stop recording first.") end
  local tracks, ntr = {}, 0
  if job.input == "tracks" then
    for i = 0, reaper.CountSelectedTracks(proj) - 1 do tracks[reaper.GetSelectedTrack(proj, i)], ntr = true, ntr + 1 end
    if ntr == 0 then return say("Select the tracks first.") end
  end
  local reference
  if job.id == "master" then
    local ok, f = reaper.GetUserFileNameForRead("", "StudioSync AI: the reference track to match", "wav")
    if not ok then return end
    reference = f
  end
  with_helper(function()
    local c = run.new("check")
    run.start(c, nil, nil, { check = true, timeout = 60 })
    run.wait(c, function(chk)
      local info = chk.status == "ok" and type(chk.data) == "table" and type(chk.data.jobs) == "table" and chk.data.jobs[job.id]
      if not info then return say("StudioSync AI's helper didn't answer: " .. tostring(chk.message)) end
      local missing = dry() and {} or (info.missing or {})
      local text = jobs.consent_text(job, { missing = missing })
      if dry() then text = "DRY RUN (Settings): no model runs; the helper makes an example result, to try the import with.\n\n" .. text end
      if not ask(text) then return band.log("StudioSync AI: " .. job.label .. " not run (you said no)") end
      local r = run.new(job.id)
      local start, stop = run.range(proj)
      local input
      if job.input == "mix" then
        input = run.render(proj, r.dir, "mix", start, stop)["master.wav"] and (r.dir .. "/master.wav")
      else
        reaper.RecursiveCreateDirectory(r.dir .. "/in", 0)
        for f, tr in pairs(run.render(proj, r.dir .. "/in", tracks, start, stop)) do -- (named for their tracks: the MIDI tracks are named from them)
          os.rename(r.dir .. "/in/" .. f, r.dir .. "/in/" .. band.clean(select(2, reaper.GetTrackName(tr))) .. ".wav")
          input = r.dir .. "/in"
        end
      end
      if not input then return say("Nothing rendered to work from (cancelled, or silent).") end
      run.consent(r, job.where, #missing > 0)
      run.start(r, input, { reference = reference }, { install = #missing > 0, timeout = job.timeout + (#missing > 0 and 1800 or 0) })
      run.wait(r, function(res) bring_in(r, job, res, start) end)
    end)
  end)
end

-- ---------------------------------------------------------------- settings
local function settings()
  local fields = { "endpoint", "hub_url", "hub_model", "claude_model", "key", "python", "dry_run" }
  local cur = {}
  for i, k in ipairs(fields) do cur[i] = k == "key" and "" or run.get(k) end
  local ok, csv = reaper.GetUserInputs("StudioSync AI settings", #fields,
    "AI for feedback: none / hub / claude,AI hub address,AI hub model,Claude model,Claude API key (blank: keep),Python 3.11+ (blank: find it)," ..
    "Dry run: 1 = no models,separator=|,extrawidth=220", table.concat(cur, "|"))
  if not ok then return end
  local v, i = {}, 0
  for s in (csv .. "|"):gmatch("([^|]*)|") do i = i + 1; v[fields[i]] = s:match("^%s*(.-)%s*$") end
  if not ({ none = true, hub = true, claude = true })[v.endpoint] then return say("AI for feedback is none, hub or claude.") end
  for _, k in ipairs(fields) do
    if k == "key" then
      if v.key ~= "" then run.save_key(v.key); band.log("StudioSync AI: Claude API key saved") end -- (never the key itself)
    elseif k == "dry_run" then run.set(k, v[k] == "1" and "1" or "0")
    else run.set(k, v[k] or "") end
  end
end

-- ---------------------------------------------------------------- the menu
local items = { "#StudioSync AI" .. (dry() and " (dry run)" or ""), "Mix feedback (no AI; nothing leaves this computer)" }
local act = { [items[2]] = mix_feedback }
for _, j in ipairs(jobs.LIST) do
  local label = j.label .. " (" .. (j.where == "gpu" and "GPU" or "CPU") .. ")"
  items[#items + 1] = label
  act[label] = function() model_job(j) end
end
items[#items + 1] = "Settings..."
act["Settings..."] = settings
local pick = band.pick(items)
if act[pick] then band.try("StudioSync AI: " .. pick, act[pick]) end
