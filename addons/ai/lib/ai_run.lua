-- StudioSync AI on REAPER's side: settings, the helper's Python, a run's folder and consent record, starting the helper in the background
-- (StudioSync's own hidden runner, lib/services.lua run_hidden) and waiting for its result.json, and the renders a run starts from.
-- Data lives in <StudioSync home>/ai/: venv/ (the helper's Python, made once with your OK), runs/<id>/ (one folder per run: its input,
-- consent.json, opts.json, result.json and whatever the helper made), claude_key.txt (only if you set a key here).
local band = require("band")
local run = {}

local WIN = reaper.GetOS():match("^Win") ~= nil
run.SECTION = "StudioSync AI"
run.DEFAULTS = { endpoint = "none", hub_url = "http://127.0.0.1:4000", hub_model = "qwen-auto", claude_model = "claude-opus-5-5",
  python = "", dry_run = "0" }

function run.get(k)
  local v = reaper.GetExtState(run.SECTION, k)
  return v ~= "" and v or run.DEFAULTS[k]
end
function run.set(k, v) reaper.SetExtState(run.SECTION, k, tostring(v), true) end

function run.data_dir() return band.home():gsub("\\", "/") .. "/ai" end
function run.key_file() return run.data_dir() .. "/claude_key.txt" end
-- shortcut: the key sits in a plain file in your own REAPER folder, never in ExtState or a log; move it to DPAPI/Keychain the way
-- lib/services.lua keeps the Tailscale token once StudioSync's security work resumes after testing.
function run.save_key(key)
  reaper.RecursiveCreateDirectory(run.data_dir(), 0)
  band.write_atomic(run.key_file(), key)
end
function run.has_key() return (band.read(run.key_file()) or ""):match("%S") ~= nil or (os.getenv("ANTHROPIC_API_KEY") or "") ~= "" end

-- A path or word on a command line: Windows double quotes, else a shell's single quotes.
function run.q(s)
  s = tostring(s)
  if WIN then return '"' .. s:gsub('"', "") .. '"' end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- ---------------------------------------------------------------- Python
function run.venv_dir() return run.data_dir() .. "/venv" end
function run.venv_python()
  local p = run.venv_dir() .. (WIN and "/Scripts/python.exe" or "/bin/python3")
  return reaper.file_exists(p) and p or nil
end

-- A Python 3.11 or newer on this computer, to make the venv with: the Python setting first, then the usual names. -> its command, or nil.
function run.find_python()
  local list = {}
  if run.get("python") ~= "" then list[1] = run.q(run.get("python")) end
  for _, c in ipairs(WIN and { "py -3", "python" } or { "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3", "python3" }) do list[#list + 1] = c end
  for _, c in ipairs(list) do
    local out = reaper.ExecProcess(c .. " --version", 5000) or ""
    local major, minor = out:match("Python (%d+)%.(%d+)")
    if major and (tonumber(major) > 3 or (tonumber(major) == 3 and tonumber(minor) >= 11)) then return c end
  end
end

-- Make the helper's own venv (nothing downloaded: Python's standard library only) in the background. -> true when started.
function run.make_venv(py)
  reaper.RecursiveCreateDirectory(run.data_dir(), 0)
  require("services").run_hidden("ai-venv-" .. os.time(), py .. " -m venv " .. run.q(run.venv_dir()), 1e9)
  return true
end

-- ---------------------------------------------------------------- a run
local function token()
  local t = {}
  for i = 1, 32 do t[i] = string.format("%x", math.random(0, 15)) end
  return table.concat(t)
end
math.randomseed(math.floor(reaper.time_precise() * 1000) ~ os.time())

-- A new run folder for `job`. -> { id, dir, job }
function run.new(job)
  local id = os.date("%Y%m%d-%H%M%S") .. "-" .. job .. "-" .. token():sub(1, 4)
  local dir = run.data_dir() .. "/runs/" .. id
  reaper.RecursiveCreateDirectory(dir, 0)
  return { id = id, dir = dir, job = job }
end

-- The consent record the helper checks (helper/jobs/common.py): written only once the person said yes, for this job, this place to
-- run and, when `install`, the download. -> the token to pass.
function run.consent(r, where, install)
  r.token = token()
  band.write_json(r.dir .. "/consent.json", { job = r.job, where = where, install = install == true, at = os.time(), token = r.token })
  return r.token
end

-- Start the helper on run r in the background: job, input path, opts table; flags { install, check }. -> true when started.
function run.start(r, input, opts, flags)
  local py = run.venv_python()
  if not py then return false end
  flags = flags or {}
  band.write_json(r.dir .. "/opts.json", opts or {})
  local helper = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]lib[/\\]") .. "/helper/ssai.py"
  local cmd = run.q(py) .. " " .. run.q(helper) .. " " .. (flags.check and "check" or r.job) .. " --out " .. run.q(r.dir)
  if not flags.check then
    cmd = cmd .. " --in " .. run.q(input) .. " --opts " .. run.q(r.dir .. "/opts.json") .. " --consent " .. r.token ..
      (flags.install and " --install" or "") .. (run.get("dry_run") == "1" and " --dry-run" or "")
  end
  r.started, r.timeout = reaper.time_precise(), flags.timeout or 600
  require("services").run_hidden("ai-" .. r.id, cmd, 1e9)
  band.log("StudioSync AI started " .. (flags.check and "a check" or r.job) .. (run.get("dry_run") == "1" and " (dry run)" or ""))
  return true
end

-- Its result.json once the helper has written it, or nil while it runs. Past the timeout, the helper is stopped and a result made up.
function run.poll(r)
  local res = band.read_json(r.dir .. "/result.json")
  if res then return res end
  if reaper.time_precise() - (r.started or 0) > (r.timeout or 600) then
    local pid = tonumber(band.read(r.dir .. "/pid.txt") or "")
    if pid then reaper.ExecProcess(WIN and ("taskkill /PID " .. pid .. " /T /F") or ("/bin/kill " .. pid), 5000) end
    return { status = "error", job = r.job, message = "it ran past " .. math.floor(r.timeout / 60) .. " minutes and was stopped" }
  end
end

-- Wait for run r without holding REAPER: done(result) once there is one.
function run.wait(r, done)
  local function tick()
    local res = run.poll(r)
    if res then return done(res) end
    reaper.defer(tick)
  end
  reaper.defer(tick)
end

-- ---------------------------------------------------------------- renders
-- What a run starts from: the time selection, or the whole song. -> start, stop (stop 0: the whole song)
function run.range(proj)
  local a, b = reaper.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
  if b > a then return a, b end
  return 0, 0
end

-- Render into dir, quietly, with your render settings put back after. what: "mix" (the master, named master.wav) or a set of tracks
-- (each its own file, named by track number). StudioSync's own tracks (the Real time return, live placeholders, tracks kept as yours)
-- are left out. 24-bit WAV at the project's rate, no limiter or normalizing (the numbers must be the mix's own).
-- -> the files made, as { [name] = track or "master" }
function run.render(proj, dir, what, start, stop)
  local extras, mirror = require("extras"), require("mirror")
  local saved, sel, muted = extras.save_render(proj), {}, {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    sel[tr] = reaper.IsTrackSelected(tr)
    if what == "mix" then
      if mirror.local_track(tr) and reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") == 0 then reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1); muted[#muted + 1] = tr end
    else
      reaper.SetTrackSelected(tr, what[tr] == true)
    end
  end
  extras.set_render(proj, extras.STANDARD(proj))
  extras.set_render(proj, { RENDER_FILE = dir, RENDER_PATTERN = what == "mix" and "master" or "$tracknumber", RENDER_SETTINGS = what == "mix" and 0 or 3,
    RENDER_BOUNDSFLAG = stop > start and 0 or 1, RENDER_STARTPOS = start, RENDER_ENDPOS = stop, RENDER_ADDTOPROJ = what == "mix" and 0 or 2,
    RENDER_TAILFLAG = 0 })
  local keep = reaper.SNM_GetIntConfigVar and reaper.SNM_GetIntConfigVar("renderclosewhendone", -1)
  if keep and keep >= 0 then reaper.SNM_SetIntConfigVar("renderclosewhendone", 4) end
  reaper.Main_OnCommand(42230, 0) -- File: Render project, most recent settings, auto-close dialog
  if keep and keep >= 0 then reaper.SNM_SetIntConfigVar("renderclosewhendone", keep) end
  for _, tr in ipairs(muted) do reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 0) end
  for tr, was in pairs(sel) do if reaper.ValidatePtr2(proj, tr, "MediaTrack*") then reaper.SetTrackSelected(tr, was) end end
  extras.set_render(proj, saved)
  local made = {}
  for _, f in ipairs(band.files(dir, ".wav")) do
    if what == "mix" then
      if f == "master.wav" then made[f] = "master" end
    else
      local n = tonumber(f:match("^(%d+)%.wav$"))
      local tr = n and reaper.GetTrack(proj, n - 1)
      if tr and what[tr] then made[f] = tr end
    end
  end
  return made
end

-- The shared tracks with something in them: what mix feedback measures one by one. -> { [track] = true }, how many
function run.shared_tracks(proj)
  local mirror, set, n = require("mirror"), {}, 0
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if not mirror.local_track(tr) and reaper.CountTrackMediaItems(tr) > 0 then set[tr], n = true, n + 1 end
  end
  return set, n
end

-- One rendered file's numbers: REAPER's loudness, RMS and peaks over the whole file, and the stereo/spectrum figures from samples.
-- -> a stats row, or nil for silence.
function run.measure(path, name)
  local mix = require("ai_mix")
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return nil end
  local g = {}
  for mode = 0, 3 do g[mode] = reaper.CalculateNormalization(src, mode, 0, 0, 0) end -- 0 LUFS-I, 1 RMS-I, 2 peak, 3 true peak
  reaper.PCM_Source_Destroy(src)
  if g[0] == 1 and g[2] == 1 then return nil end -- (silence: REAPER answers "no change" to both. Measured, lib/extras.lua 0.58.52)
  local row = { name = name, lufs_i = mix.gain_db(g[0]), rms_db = mix.gain_db(g[1]), peak_db = mix.gain_db(g[2]), true_peak_db = mix.gain_db(g[3]) }
  if row.peak_db and row.rms_db then row.crest_db = row.peak_db - row.rms_db end
  local LEN = 2048
  local w = mix.read_wav(path, 64, LEN)
  if w then
    for k, v in pairs(mix.analyze(w, LEN)) do row[k] = v end
  end
  for k, v in pairs(row) do if type(v) == "number" then row[k] = math.floor(v * 1000 + 0.5) / 1000 end end
  return row
end

return run
